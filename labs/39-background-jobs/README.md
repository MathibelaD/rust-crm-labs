# Lab 39 — Background Jobs

> **Phase:** 11 — Production-Ready · **Builds on:** Lab 38 · **Time:** ~6 hours
> **Your repo before this lab:** tag `lab-38` · **After:** tag `lab-39`

## 🎯 Goal
Give the CRM work that runs **without a request**: a daily *stale deal* scan that creates a
follow-up for the deal's owner when nothing has happened for 14 days, and reminder emails for
follow-ups that are due. The work goes through a **durable job queue in Postgres** that survives
crashes, retries with backoff, never hands the same job to two workers, and shuts down cleanly.

## 🧠 What You'll Learn
- Why `tokio::spawn` is not a job queue (and what "fire and forget" forgets)
- A Postgres-backed queue: a `jobs` table, a status state machine, and `SELECT … FOR UPDATE SKIP LOCKED`
- **At-least-once** delivery, and why it forces every job handler to be **idempotent**
- Idempotency keys enforced by a **partial unique index**
- Exponential backoff, and why "retry forever, immediately" is a bug
- `tokio_util::sync::CancellationToken` + `tokio::select!` for cooperative shutdown, and
  **cancellation safety**: which futures you may drop halfway and which you must not
- A periodic scheduler with `tokio::time::interval`
- A `Mailer` trait whose method returns `impl Future + Send`: why `async fn` in a public trait
  isn't enough when generic code needs `Send`
- A concurrency test that proves two workers never get the same job

## 🔨 What We're Building

```text
rust-crm/
├── migrations/
│   ├── <ts>_create_jobs.sql            ← NEW: the queue
│   └── <ts>_follow_up_activities.sql   ← NEW: index for open follow-ups
├── config/default.toml, development.toml   ← + [jobs]
├── src/
│   ├── jobs/
│   │   ├── mod.rs        ← Job enum (serde-tagged), JobId, idempotency keys
│   │   ├── queue.rs      ← enqueue, claim_next (SKIP LOCKED), complete, fail, 🔵 backoff, 🔵 requeue_stuck
│   │   ├── handlers.rs   ← stale_deal_scan, send_reminder
│   │   ├── worker.rs     ← run_worker: claim → handle → record, until cancelled
│   │   └── scheduler.rs  ← run_scheduler: enqueue a scan every N seconds
│   ├── notifications/mod.rs  ← Mailer trait + LogMailer
│   ├── activities/model.rs   ← ActivityKind::FollowUp { due_at, done }
│   ├── http/activities.rs    ← 🔵 POST /activities/{id}/complete
│   ├── config/mod.rs         ← + JobSettings
│   └── startup.rs            ← spawns worker + scheduler; cancels them on shutdown
└── tests/
    ├── jobs.rs               ← queue + handler DB tests (🔵 concurrency test)
    └── api/follow_ups.rs     ← 🔵 API tests for completing follow-ups
```

Sales reps forget deals. A deal that nobody has touched for two weeks is usually a deal that's
quietly dying. The CRM should notice, put a follow-up task on the owner's list, and remind them
by email when it's due. Nobody sends an HTTP request for that: the CRM has to do it **on its
own**, on a schedule, reliably.

Written against **tokio-util 0.7**, **tokio 1**, **sqlx 0.9** (with `query!` macros, as in Labs
30–36) and **serde 1**. Your database must be running (`docker compose up -d db`) because the
`query!` macros check SQL against it at compile time.

---

## Step 1 — Why not just `tokio::spawn`?

You already know how to run something in the background (Lab 26). The tempting version of
"remind the owner" looks like this, inside a handler:

```rust
// DON'T: fire and forget
tokio::spawn(async move {
    tokio::time::sleep(Duration::from_secs(24 * 3600)).await;
    mailer.send(&owner_email, "Follow-up due", &body).await.ok();
});
```

It compiles, it even works on your laptop. Now list what it forgets:

| Event | What happens to the spawned task |
|---|---|
| You **deploy** (Lab 40: every deploy stops the old process) | Gone. The reminder is never sent. |
| The process **crashes** or is OOM-killed | Gone. Nobody knows it existed. |
| The SMTP server is down for a minute | `.ok()` swallows the error. No retry. |
| You run **two** API instances | Each instance runs its own copy of every periodic task. |
| "Did the reminder for deal 7 go out?" | No record anywhere. |

The root problem: the **only** copy of the work is a future in one process's memory. The fix
is to write the work down somewhere durable *first*, and have workers pick it up from there.
That's a job queue.

You could use a dedicated system (Redis, RabbitMQ, SQS) or a crate (`apalis`, `sqlxmq`). We'll
build a small one on **Postgres**, because:

- you already run it, back it up and monitor it: no new infrastructure;
- a job can be enqueued **in the same transaction** as the data that caused it (you'll do this
  in the stale-deal scan): either both happen or neither does;
- Postgres has exactly the locking primitive a queue needs, `SKIP LOCKED`, and understanding it
  is worth more than any library.

## Step 2 — The `jobs` table

```bash
cargo add tokio-util
sqlx migrate add create_jobs
```

> 🟢 **FOLLOW ALONG**: fill in the new `migrations/<timestamp>_create_jobs.sql`:

```sql
CREATE TABLE jobs (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind         TEXT        NOT NULL,
    payload      JSONB       NOT NULL DEFAULT '{}',
    status       TEXT        NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued', 'running', 'done', 'failed')),
    attempts     INT         NOT NULL DEFAULT 0,
    max_attempts INT         NOT NULL DEFAULT 5,
    run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at    TIMESTAMPTZ,
    last_error   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The worker's query: "oldest runnable queued job". Partial = only queued rows are indexed.
CREATE INDEX jobs_runnable ON jobs (run_at, id) WHERE status = 'queued';

-- Idempotency: at most ONE queued-or-running job per (kind, key).
CREATE UNIQUE INDEX jobs_idempotency_key ON jobs (kind, (payload->>'key'))
    WHERE status IN ('queued', 'running');
```

```bash
sqlx migrate run
```

Every job moves through this state machine:

```text
                 claim_next                 complete
   ┌────────┐  ───────────────▶  ┌─────────┐ ───────────▶ ┌──────┐
   │ queued │                    │ running │              │ done │
   └────────┘  ◀───────────────  └─────────┘              └──────┘
       ▲         fail (attempts < max):  │
       │         run_at = now + backoff  │ fail (attempts = max)    ┌────────┐
       │                                 └────────────────────────▶ │ failed │
       └──── requeue_stuck (worker vanished, locked_at too old)     └────────┘
```

| Column | Why it exists |
|---|---|
| `kind` | Which handler runs it. Duplicated from the payload so SQL can filter on it cheaply. |
| `payload` | The job's data as JSON (a serialized Rust `Job`, Step 3). |
| `attempts` / `max_attempts` | Retry accounting. A job that fails 5 times stops being retried. |
| `run_at` | "Not before". Used for scheduling *and* for backoff after a failure. |
| `locked_at` | When a worker claimed it. Lets us detect workers that died mid-job. |
| `last_error` | The latest failure, for humans: `SELECT * FROM jobs WHERE status = 'failed'`. |

**The partial unique index** is how we stop duplicate work. `(kind, payload->>'key')` must be
unique **among queued and running jobs only**. Finished jobs (`done`, `failed`) don't count,
so the same key can be enqueued again *after* the previous run finished. Two schedulers racing
to enqueue "today's scan" can't both succeed; tomorrow's scan has a different key.

## Step 3 — The `Job` type

> 🟢 **FOLLOW ALONG**: create `src/jobs/mod.rs` (and `pub mod jobs;` in `src/lib.rs`):

```rust
//! Background jobs: a Postgres-backed queue, a worker that drains it, and a scheduler that fills it.

pub mod handlers;
pub mod queue;
pub mod scheduler;
pub mod worker;

use crate::activities::ActivityId;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type,
)]
#[sqlx(transparent)]
pub struct JobId(pub i64);

/// Every kind of background work the CRM knows how to do.
/// Stored as JSON in `jobs.payload`, e.g. `{"kind":"send_reminder","activity_id":42,"key":"..."}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Job {
    /// Find deals with no recent activity and create follow-ups for their owners.
    StaleDealScan,
    /// Email the owner of a follow-up that is due soon.
    SendReminder { activity_id: ActivityId },
}

impl Job {
    /// The value stored in `jobs.kind` (same as the serde tag).
    pub fn kind(&self) -> &'static str {
        match self {
            Job::StaleDealScan => "stale_deal_scan",
            Job::SendReminder { .. } => "send_reminder",
        }
    }

    /// Two jobs with the same kind and key are "the same work".
    /// While one is queued or running, enqueuing the other is a no-op.
    pub fn idempotency_key(&self, run_at: DateTime<Utc>) -> String {
        match self {
            Job::StaleDealScan => format!("stale_deal_scan:{}", run_at.date_naive()),
            Job::SendReminder { activity_id } => format!("send_reminder:{}", activity_id.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jobs_serialize_with_a_kind_tag() {
        let job = Job::SendReminder {
            activity_id: ActivityId(42),
        };
        let json = serde_json::to_value(&job).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "kind": "send_reminder", "activity_id": 42 })
        );
        assert_eq!(job.kind(), json["kind"]);
    }

    #[test]
    fn extra_fields_in_the_payload_are_ignored() {
        let payload =
            serde_json::json!({ "kind": "stale_deal_scan", "key": "stale_deal_scan:2026-10-05" });
        assert_eq!(
            serde_json::from_value::<Job>(payload).unwrap(),
            Job::StaleDealScan
        );
    }
}
```

(Create empty `handlers.rs`, `queue.rs`, `scheduler.rs` and `worker.rs` files for now so the
module compiles.)

Design notes:

- **An enum, not strings.** The queue stores text and JSON, but the rest of the code only sees
  `Job`. Adding a job kind is adding a variant, and every `match` on `Job` (the `kind()` method,
  the handler dispatch) becomes a compile error until you handle it. Same trick as Lab 11.
- **`#[serde(tag = "kind")]`** produces *internally tagged* JSON: `{"kind":"send_reminder",
  "activity_id":42}`. `ActivityId` derives `Serialize`, and a newtype struct serializes as its
  inner value, so the id is a plain number. Lab 21 used the same attribute for `ActivityKind`.
- **The payload stores ids, not data.** `SendReminder` carries an `ActivityId`, not the email
  address or the text of the reminder. By the time the job runs, the follow-up may have been
  completed, or the owner's email changed. Jobs should re-read the current truth.
- **The idempotency key is derived from the job.** `send_reminder:42` means "at most one pending
  reminder for follow-up 42". `stale_deal_scan:2026-10-05` means "at most one pending scan per
  day".
- Add a third test yourself: `stale_deal_scan_key_is_per_day` (8:00 and 20:00 on the same
  day give the same key; the next day gives a different one).
- `extra_fields_in_the_payload_are_ignored` documents something we rely on: the stored payload
  also contains `"key"`, and serde ignores unknown fields unless told otherwise.

## Step 4 — Enqueue

> 🟢 **FOLLOW ALONG**: start `src/jobs/queue.rs`:

```rust
//! The queue itself: plain SQL over the `jobs` table.

use super::{Job, JobId};
use chrono::{DateTime, TimeDelta, Utc};
use sqlx::{PgExecutor, PgPool};

/// Adds a job to the queue. Returns `None` if the same work (same kind + idempotency key)
/// is already queued or running.
pub async fn enqueue(
    db: impl PgExecutor<'_>,
    job: &Job,
    run_at: DateTime<Utc>,
) -> Result<Option<JobId>, sqlx::Error> {
    let mut payload = serde_json::to_value(job).map_err(|e| sqlx::Error::Encode(e.into()))?;
    payload["key"] = job.idempotency_key(run_at).into();

    sqlx::query_scalar!(
        r#"INSERT INTO jobs (kind, payload, run_at)
           VALUES ($1, $2, $3)
           ON CONFLICT DO NOTHING
           RETURNING id AS "id: JobId""#,
        job.kind(),
        payload,
        run_at,
    )
    .fetch_optional(db)
    .await
}
```

- **`ON CONFLICT DO NOTHING`** without a conflict target catches a violation of *any* unique
  index, including our partial expression index. No row inserted → `RETURNING` returns no row →
  `fetch_optional` gives `None`. A duplicate isn't an error; it's "already taken care of".
- **`"id: JobId"`** is a `query!` type override (Lab 31): decode this column straight into
  our newtype.
- **`impl PgExecutor<'_>`**: like every repository function since Lab 31, `enqueue` works with
  `&PgPool` *and* with `&mut *tx`. You'll use the transaction form in Step 9.
- `payload["key"] = …`: `serde_json::Value` implements `IndexMut<&str>`; on an object it
  inserts or replaces that key.

## Step 5 — Claim: `FOR UPDATE SKIP LOCKED`

Several workers (one per API instance in production, maybe several per instance) will ask the
same question at the same time: *"give me the next job"*. The answer must never be the same job
for two of them.

> 🟢 **FOLLOW ALONG**: add to `queue.rs`:

```rust
/// A job this worker now owns (its row has status = 'running').
#[derive(Debug)]
pub struct ClaimedJob {
    pub id: JobId,
    pub job: Job,
    /// Attempts so far, INCLUDING this one (claiming increments it).
    pub attempts: i32,
    pub max_attempts: i32,
}

/// Claims the oldest runnable job, or returns `None` when there's nothing to do.
///
/// `FOR UPDATE SKIP LOCKED`: concurrent workers skip rows another transaction has
/// locked instead of waiting for them, so two workers never claim the same job.
pub async fn claim_next(pool: &PgPool) -> Result<Option<ClaimedJob>, sqlx::Error> {
    loop {
        let Some(row) = sqlx::query!(
            r#"UPDATE jobs
               SET status = 'running', attempts = attempts + 1, locked_at = now()
               WHERE id = (
                   SELECT id FROM jobs
                   WHERE status = 'queued' AND run_at <= now()
                   ORDER BY run_at, id
                   FOR UPDATE SKIP LOCKED
                   LIMIT 1
               )
               RETURNING id AS "id: JobId", payload, attempts, max_attempts"#
        )
        .fetch_optional(pool)
        .await?
        else {
            return Ok(None);
        };

        match serde_json::from_value::<Job>(row.payload) {
            Ok(job) => {
                return Ok(Some(ClaimedJob {
                    id: row.id,
                    job,
                    attempts: row.attempts,
                    max_attempts: row.max_attempts,
                }));
            }
            Err(err) => {
                // A payload we can't read will never succeed. Fail it now and look again.
                tracing::error!(job_id = row.id.0, error = %err, "unreadable job payload");
                mark_failed(pool, row.id, &format!("unreadable payload: {err}")).await?;
            }
        }
    }
}
```

(`mark_failed` comes in Step 6; `cargo check` will complain until then.)

### What `FOR UPDATE SKIP LOCKED` does, as a timeline

`SELECT … FOR UPDATE` **locks** the rows it returns until the transaction ends. Here the
transaction is the single `UPDATE` statement (autocommit), so the lock lives exactly as long
as it takes to flip the row to `running`. `SKIP LOCKED` changes what *other* transactions do
when they meet a locked row: instead of **waiting**, they **skip** it and take the next one.

Two workers, A and B, three queued jobs:

```text
time   worker A                                   worker B
────   ─────────────────────────────────────────  ─────────────────────────────────────────
 t0    SELECT … FOR UPDATE SKIP LOCKED LIMIT 1
       → finds job 1, LOCKS row 1
 t1                                               SELECT … FOR UPDATE SKIP LOCKED LIMIT 1
                                                  → row 1 is locked: SKIP it
                                                  → finds job 2, LOCKS row 2
 t2    UPDATE job 1 SET status='running'
       COMMIT → row 1 unlocked, status=running
 t3                                               UPDATE job 2 SET status='running'
                                                  COMMIT
 t4    next claim: job 1 is 'running' (filtered
       by WHERE status='queued'), job 2 too
       → finds job 3
```

Without `SKIP LOCKED` (plain `FOR UPDATE`), B would **block** at t1 until A commits, then
re-check row 1, see it's no longer `queued`, and move on. Still correct, but every worker
queues up behind every other one. We measured this with two `psql` sessions where A held its
transaction open for 2 s: with plain `FOR UPDATE`, B got job 2 after **2 seconds**; with
`SKIP LOCKED`, **immediately**.

And without any `FOR UPDATE` at all? Both workers' subqueries can read job 1 from their
snapshot, both `UPDATE … WHERE id = 1` (the second waits for the first, then re-checks
`id = 1`, which is still true), and **both get job 1**. The experiments make you watch that
happen.

Three more details:

- **One statement, not "SELECT then UPDATE".** If you selected an id in one query and updated
  it in another, a second worker could select the same id in between. The subquery + `UPDATE`
  is atomic.
- **`attempts + 1` happens at claim time**, not when the job fails. If a worker crashes
  mid-job, the attempt still counts, so a job that crashes the worker every time ("poison
  job") eventually stops being retried.
- **`let … else`** (Lab 11): if the query returns no row, the queue is empty: return `None`.

## Step 6 — Complete or fail: at-least-once delivery

Here's the uncomfortable truth about every job queue:

```text
worker: claim job 7 ──▶ send the email ──▶ ✉️ sent ──▶ 💥 crash ──▶ (complete(7) never runs)
later:  job 7 is 'running' forever… until it is requeued ──▶ the email is sent AGAIN
```

There is no ordering of "do the work" and "record that it's done" that survives a crash at
every point. Record first, then crash → the work is lost (*at-most-once*). Work first, then
crash → the work is repeated (*at-least-once*). For a CRM, a duplicate reminder is annoying; a
missing one is a lost deal. We choose **at-least-once**, and accept the consequence:

> **Every job handler must be idempotent**: running it twice must have the same effect as
> running it once (or at least an acceptable one).

You'll design the handlers that way in Step 9. Now the bookkeeping:

> 🟢 **FOLLOW ALONG**: add to `queue.rs`:

```rust
/// The job succeeded.
pub async fn complete(db: impl PgExecutor<'_>, id: JobId) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobs SET status = 'done', locked_at = NULL, last_error = NULL WHERE id = $1",
        id.0,
    )
    .execute(db)
    .await?;
    Ok(())
}

/// What happened to a job after a failed attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailOutcome {
    RetryAt(DateTime<Utc>),
    GaveUp,
}

/// The job failed: schedule a retry with exponential backoff, or give up for good
/// once `max_attempts` is reached.
pub async fn fail(
    db: impl PgExecutor<'_>,
    job: &ClaimedJob,
    error: &str,
) -> Result<FailOutcome, sqlx::Error> {
    if job.attempts >= job.max_attempts {
        mark_failed(db, job.id, error).await?;
        return Ok(FailOutcome::GaveUp);
    }
    let retry_at = Utc::now() + backoff(job.attempts);
    sqlx::query!(
        "UPDATE jobs SET status = 'queued', run_at = $2, locked_at = NULL, last_error = $3
         WHERE id = $1",
        job.id.0,
        retry_at,
        error,
    )
    .execute(db)
    .await?;
    Ok(FailOutcome::RetryAt(retry_at))
}

async fn mark_failed(db: impl PgExecutor<'_>, id: JobId, error: &str) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobs SET status = 'failed', locked_at = NULL, last_error = $2 WHERE id = $1",
        id.0,
        error,
    )
    .execute(db)
    .await?;
    Ok(())
}
```

`fail` returns *what it decided* (`FailOutcome`) instead of `()`, so the caller can log
"will retry at 14:58:11" or "gave up". Returning information instead of logging it inside the
queue keeps logging decisions in one place (Lab 37's rule).

### Backoff

Why not retry immediately? If the SMTP server is down, retrying 5 times in 5 milliseconds burns
every attempt before it has any chance of coming back, and hammers a struggling service.
**Exponential backoff** waits longer after each failure: 20 s, 40 s, 80 s, 160 s, … The total
wait grows fast, which is what you want for outages that last minutes.

You'll write it (🔵 Your Turn 1). Add the signature now with a temporary body so everything
compiles:

```rust
/// Delay before the next attempt: 10 s × 2^attempts, capped at one hour.
/// 1 → 20 s, 2 → 40 s, 3 → 80 s, 4 → 160 s, … Never panics, whatever `attempts` is.
pub fn backoff(_attempts: i32) -> TimeDelta {
    todo!("Your Turn 1")
}
```

(The leading underscore silences "unused variable" until you implement it; rename it back to
`attempts` then.)

## Step 7 — The `Mailer` trait

Reminders send email. We don't want SMTP in development or tests, so we hide sending behind a
trait with a logging implementation now, and a real one later.

The natural first draft:

```rust
pub trait Mailer: Send + Sync + 'static {
    async fn send(&self, to: &Email, subject: &str, body: &str) -> Result<(), MailError>;
}
```

`cargo check` accepts it, but warns:

```text
warning: use of `async fn` in public traits is discouraged as auto trait bounds cannot be specified
  --> src/notifications/mod.rs:11:5
   |
11 |     async fn send(&self, to: &Email, subject: &str, body: &str) -> Result<(), MailError>;
   |     ^^^^^
   = note: `#[warn(async_fn_in_trait)]` on by default
help: you can alternatively desugar to a normal `fn` that returns `impl Future` and add any desired bounds such as `Send`, but these cannot be relaxed without a breaking API change
```

> 🟡 **EXPERIMENT**: keep the `async fn` version and add this to the same file. It's exactly
> what our worker will do: generic code that calls `send` and gets spawned. Predict, then
> `cargo check`.

```rust
async fn remind<M: Mailer>(mailer: Arc<M>, to: Email) {
    let _ = mailer.send(&to, "Follow-up due", "...").await;
}

pub fn spawn_reminder<M: Mailer>(mailer: Arc<M>, to: Email) {
    tokio::spawn(remind(mailer, to));
}
```

```text
error: future cannot be sent between threads safely
   --> src/notifications/mod.rs:28:18
    |
 28 |     tokio::spawn(remind(mailer, to));
    |                  ^^^^^^^^^^^^^^^^^^ future returned by `remind` is not `Send`
    |
    = help: within `impl Future<Output = ()>`, the trait `Send` is not implemented for `impl Future<Output = Result<(), MailError>>`
note: future is not `Send` as it awaits another future which is not `Send`
   --> src/notifications/mod.rs:24:13
    |
 24 |     let _ = mailer.send(&to, "Follow-up due", "...").await;
    |             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ await occurs here on type `impl Future<Output = Result<(), MailError>>`, which is not `Send`
note: required by a bound in `tokio::spawn`
   --> …/tokio-1.53.2/src/task/spawn.rs:176:21
    |
174 |     pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
    |            ----- required by a bound in this function
175 |     where
176 |         F: Future + Send + 'static,
    |                     ^^^^ required by this bound in `spawn`
help: `Send` can be made part of the associated future's guarantees for all implementations of `Mailer::send`
    |
 11 -     async fn send(&self, to: &Email, subject: &str, body: &str) -> Result<(), MailError>;
 11 +     fn send(&self, to: &Email, subject: &str, body: &str) -> impl std::future::Future<Output = Result<(), MailError>> + Send;
    |
```

**Read the error.** `tokio::spawn` may move a task to another thread, so the task's future
must be `Send` (Lab 26). The `remind` future *contains* the future returned by `send` (it's
held across the `.await`). So `remind` is `Send` only if `send`'s future is `Send`.

What is "`send`'s future"? `async fn send(...) -> T` in a trait is sugar for
`fn send(...) -> impl Future<Output = T>`: **each implementation** returns its own anonymous
future type. In `remind<M: Mailer>`, `M` could be *any* implementation, including one written
next year whose future holds an `Rc` or a `std::sync::MutexGuard` across an `.await` (not
`Send`). The trait never promised `Send`, so the compiler can't assume it. Note that
`Mailer: Send + Sync` doesn't help: that's about the *mailer value*, not the futures its
methods return.

The fix is to put the promise **in the trait**, where every implementation must keep it:

```rust
fn send(&self, to: &Email, subject: &str, body: &str)
    -> impl Future<Output = Result<(), MailError>> + Send;
```

This is "return-position `impl Trait` in traits". Now *every* implementation must return a
`Send` future (checked when the impl is compiled), and *every* generic caller may assume it.
That's what the lint means by "auto trait bounds cannot be specified" with plain `async fn`.
(With a concrete type, e.g. `LogMailer` directly, the compiler can see the actual future and
check it. The problem only appears in generic code, which is exactly how our worker is written.)

> 🟢 **FOLLOW ALONG**: delete the experiment and write `src/notifications/mod.rs` (and
> `pub mod notifications;` in `lib.rs`):

```rust
//! Sending notifications. Today: a mailer that only logs. Tomorrow: SMTP or an email API.

use crate::contacts::Email;
use std::future::Future;

#[derive(Debug, thiserror::Error)]
pub enum MailError {
    #[error("mail transport failed: {0}")]
    Transport(String),
}

/// Something that can deliver an email.
///
/// `send` is written as "a fn returning `impl Future + Send`" instead of `async fn`
/// so that EVERY implementation must return a `Send` future, which lets generic
/// code (`M: Mailer`) run inside `tokio::spawn`.
pub trait Mailer: Send + Sync + 'static {
    fn send(
        &self,
        to: &Email,
        subject: &str,
        body: &str,
    ) -> impl Future<Output = Result<(), MailError>> + Send;
}

/// Development mailer: writes the email to the log instead of sending it.
#[derive(Debug, Clone, Copy, Default)]
pub struct LogMailer;

impl Mailer for LogMailer {
    // An impl may still use `async fn`: the compiler checks that this future is `Send`.
    async fn send(&self, to: &Email, subject: &str, body: &str) -> Result<(), MailError> {
        tracing::info!(
            to = to.as_str(),
            subject,
            body_len = body.len(),
            "email logged, not sent"
        );
        tracing::debug!(body, "email body");
        Ok(())
    }
}
```

The implementation is allowed to write `async fn`: it's checked against the trait's signature,
so if `LogMailer::send` ever held something non-`Send` across an `.await`, *this impl* would
fail to compile, with the error pointing at the culprit.

(`LogMailer` logs the recipient address. That's acceptable for a development-only mailer whose
whole job is to show you what would have been sent. A real mailer would log a message id.)

Add a test at the bottom of the same file, with a hand-written **test double**:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// A test double that remembers what it was asked to send.
    #[derive(Default)]
    struct RecordingMailer {
        sent: Mutex<Vec<(String, String)>>,
    }

    impl Mailer for RecordingMailer {
        async fn send(&self, to: &Email, subject: &str, _body: &str) -> Result<(), MailError> {
            self.sent
                .lock()
                .unwrap()
                .push((to.as_str().to_string(), subject.to_string()));
            Ok(())
        }
    }

    async fn notify<M: Mailer>(mailer: Arc<M>) -> Result<(), MailError> {
        let to = Email::parse("rep@example.com").unwrap();
        mailer.send(&to, "Follow-up due", "Call Acme").await
    }

    #[tokio::test]
    async fn generic_mailer_futures_can_be_spawned() {
        let mailer = Arc::new(RecordingMailer::default());
        // This line only compiles because `send`'s future is declared `Send`.
        tokio::spawn(notify(mailer.clone())).await.unwrap().unwrap();
        assert_eq!(
            mailer.sent.lock().unwrap().as_slice(),
            &[("rep@example.com".to_string(), "Follow-up due".to_string())]
        );
    }
}
```

`std::sync::Mutex` is fine here: the guard is taken and dropped inside one synchronous
statement, never held across an `.await` (Lab 26).

### Why generic and not `Arc<dyn Mailer>`?

Try `fn boxed() -> Box<dyn Mailer> { Box::new(LogMailer) }`:

```text
error[E0038]: the trait `Mailer` is not dyn compatible
   |
17 | pub trait Mailer: Send + Sync + 'static {
   |           ------ this trait is not dyn compatible...
...
23 |     ) -> impl Future<Output = Result<(), MailError>> + Send;
   |          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ...because method `send` references an `impl Trait` type in its return type
```

Same wall as Lab 31's async repository trait: a vtable needs one concrete return type per
method, and each implementation returns a different future type. We don't need `dyn` here: the
worker is generic over `M: Mailer` (monomorphised, zero-cost, Lab 16), and the application
picks `LogMailer` at one place, in `startup.rs`. When a second mailer appears, you choose the
type there. (If you ever truly needed runtime choice, you'd write an `enum AnyMailer { Log(..),
Smtp(..) }` that implements `Mailer` by matching, or box the future by hand.)

## Step 8 — `ActivityKind::FollowUp`

A follow-up is an activity (it belongs to a deal and appears in its history), with a due date
and a done flag.

> 🟢 **FOLLOW ALONG**: add the variant in `src/activities/model.rs`:

```rust
pub enum ActivityKind {
    // ... Call, Email, Meeting: whatever yours has ...
    FollowUp {
        due_at: DateTime<Utc>,
        done: bool,
    },
}
```

and run `cargo check`. Every exhaustive `match` on `ActivityKind` now fails, for example:

```text
error[E0004]: non-exhaustive patterns: `&ActivityKind::FollowUp { .. }` not covered
  --> src/activities/model.rs:50:15
   |
50 |         match self {
   |               ^^^^ pattern `&ActivityKind::FollowUp { .. }` not covered
   |
note: `ActivityKind` defined here
  --> src/activities/model.rs:31:10
   |
31 | pub enum ActivityKind {
   |          ^^^^^^^^^^^^
...
42 |     FollowUp {
   |     -------- not covered
```

Fix each one. Where your code maps a kind to the `activities.kind` column, the new value is
`"follow_up"` (the `snake_case` serde tag). Where you `Display` activities, show something like
`follow-up due 2026-10-06 (open)`. The compiler is your to-do list (Lab 11).

**Storage.** In Lab 31 you stored `activities.kind` as the tag (`'call'`, `'email'`,
`'meeting'`) and `activities.details` as `Json(&kind)`, the serde JSON of the whole
`ActivityKind`. A follow-up therefore looks like this in the table:

```text
 kind      | details
-----------+-------------------------------------------------------------------------------
 follow_up | {"done": false, "type": "follow_up", "due_at": "2026-10-06T14:57:28.449575Z"}
```

Lab 31 also put a `CHECK (kind IN ('call', 'email', 'meeting'))` on that column, so the
database would reject `'follow_up'`. The migration fixes that.

> 🟢 **FOLLOW ALONG**: `sqlx migrate add follow_up_activities`:

```sql
-- A follow-up is a new kind of activity: allow it in Lab 31's CHECK constraint.
ALTER TABLE activities
    DROP CONSTRAINT activities_kind_check,
    ADD CONSTRAINT activities_kind_check
        CHECK (kind IN ('call', 'email', 'meeting', 'follow_up'));

-- Open follow-ups are looked up by the stale-deal scan and the reminder query.
CREATE INDEX activities_open_follow_ups ON activities (subject_type, subject_id)
    WHERE kind = 'follow_up' AND (details->>'done') = 'false';
```

```bash
sqlx migrate run
```

`activities_kind_check` is the name Postgres generated for Lab 31's inline `CHECK`
(`<table>_<column>_check`). If `sqlx migrate run` says the constraint doesn't exist, look up
yours with `\d activities` in `psql`. Constraints can't be edited in place, which is why we
drop and re-add it in one `ALTER TABLE` (one statement, so there's no moment without a check).

If your `details` JSON has a different shape from Lab 31's, the handler in Step 9 must build
the same shape your `activities::db` reads. The test in Step 13 reads the follow-up back
through your normal repository to catch any mismatch.

`details->>'done'` extracts the JSON value as **text** (`'false'`), which is why the queries
below compare with the string `'false'`: a partial index is only used when the query's `WHERE`
implies the index's predicate.

## Step 9 — The job handlers

Two handlers, each designed to be **safe to run twice**.

> 🟢 **FOLLOW ALONG**: `src/jobs/handlers.rs`:

```rust
//! What each job does. Every handler must be safe to run more than once.

use super::{Job, queue};
use crate::{
    activities::{ActivityId, ActivityKind},
    config::JobSettings,
    contacts::Email,
    notifications::Mailer,
};
use anyhow::Context;
use chrono::{DateTime, TimeDelta, Utc};
use sqlx::PgPool;

/// Runs one job.
pub async fn handle<M: Mailer>(
    pool: &PgPool,
    mailer: &M,
    settings: &JobSettings,
    job: &Job,
) -> anyhow::Result<()> {
    match job {
        Job::StaleDealScan => {
            let report = stale_deal_scan(pool, settings.stale_after_days, Utc::now()).await?;
            tracing::info!(
                follow_ups_created = report.follow_ups_created,
                reminders_enqueued = report.reminders_enqueued,
                "stale deal scan finished"
            );
            Ok(())
        }
        Job::SendReminder { activity_id } => send_reminder(pool, mailer, *activity_id).await,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScanReport {
    pub follow_ups_created: u64,
    pub reminders_enqueued: u64,
}

/// 1. Every open deal older than `stale_after_days`, with no activity in that window and
///    no open follow-up, gets a FollowUp activity (due tomorrow) owned by the deal's owner.
/// 2. Every open follow-up due within 24 hours gets ONE SendReminder job.
///
/// `now` is a parameter (Lab 20's lesson) so tests control time.
pub async fn stale_deal_scan(
    pool: &PgPool,
    stale_after_days: i64,
    now: DateTime<Utc>,
) -> anyhow::Result<ScanReport> {
    let cutoff = now - TimeDelta::days(stale_after_days);
    let follow_up = ActivityKind::FollowUp {
        due_at: now + TimeDelta::days(1),
        done: false,
    };
    let details = serde_json::to_value(&follow_up).context("serializing follow-up")?;
    let summary = format!("No activity for {stale_after_days} days: follow up on this deal");

    let mut tx = pool.begin().await.context("starting transaction")?;

    let follow_ups_created = sqlx::query!(
        "INSERT INTO activities
             (subject_type, subject_id, kind, details, summary, occurred_at, created_by)
         SELECT 'deal', d.id, 'follow_up', $1, $2, $3, d.owner_id
         FROM deals d
         WHERE d.stage NOT IN ('won', 'lost')
           AND d.created_at < $4
           AND NOT EXISTS (
               SELECT 1 FROM activities a
               WHERE a.subject_type = 'deal' AND a.subject_id = d.id
                 AND a.occurred_at >= $4)
           AND NOT EXISTS (
               SELECT 1 FROM activities a
               WHERE a.subject_type = 'deal' AND a.subject_id = d.id
                 AND a.kind = 'follow_up' AND a.details->>'done' = 'false')",
        details,
        summary,
        now,
        cutoff,
    )
    .execute(&mut *tx)
    .await
    .context("creating follow-ups")?
    .rows_affected();

    let due = sqlx::query_scalar!(
        r#"SELECT a.id AS "id: ActivityId"
           FROM activities a
           WHERE a.kind = 'follow_up' AND a.details->>'done' = 'false'
             AND (a.details->>'due_at')::timestamptz <= $1
             AND NOT EXISTS (
                 SELECT 1 FROM jobs j
                 WHERE j.kind = 'send_reminder'
                   AND j.payload->>'key' = 'send_reminder:' || a.id)"#,
        now + TimeDelta::hours(24),
    )
    .fetch_all(&mut *tx)
    .await
    .context("finding follow-ups due soon")?;

    let mut reminders_enqueued = 0;
    for activity_id in due {
        let job = Job::SendReminder { activity_id };
        if queue::enqueue(&mut *tx, &job, now)
            .await
            .context("enqueuing reminder")?
            .is_some()
        {
            reminders_enqueued += 1;
        }
    }

    tx.commit().await.context("committing stale deal scan")?;
    Ok(ScanReport {
        follow_ups_created,
        reminders_enqueued,
    })
}

/// Emails the owner of a follow-up. Does nothing if it's gone or already done.
pub async fn send_reminder<M: Mailer>(
    pool: &PgPool,
    mailer: &M,
    activity_id: ActivityId,
) -> anyhow::Result<()> {
    let row = sqlx::query!(
        "SELECT a.details, a.summary, a.subject_id, u.email
         FROM activities a JOIN users u ON u.id = a.created_by
         WHERE a.id = $1 AND a.kind = 'follow_up'",
        activity_id.0,
    )
    .fetch_optional(pool)
    .await
    .context("loading follow-up")?;

    let Some(row) = row else {
        tracing::info!(
            activity_id = activity_id.0,
            "follow-up is gone, nothing to send"
        );
        return Ok(());
    };
    let ActivityKind::FollowUp { due_at, done } =
        serde_json::from_value(row.details).context("reading follow-up details")?
    else {
        anyhow::bail!("activity {} is not a follow-up", activity_id.0);
    };
    if done {
        tracing::info!(
            activity_id = activity_id.0,
            "follow-up already done, nothing to send"
        );
        return Ok(());
    }

    let to = Email::parse(&row.email).context("owner has an invalid email")?;
    let subject = format!("Follow-up due {}", due_at.format("%Y-%m-%d %H:%M UTC"));
    let body = format!("{}\n\nDeal #{}", row.summary, row.subject_id);
    mailer
        .send(&to, &subject, &body)
        .await
        .context("sending reminder email")?;
    Ok(())
}
```

`JobSettings` doesn't exist yet: Step 12 adds it. Let's look at why each handler is idempotent.

**`stale_deal_scan`, run twice:** the second run finds the open follow-up created by the first
(`NOT EXISTS … follow_up … done = 'false'`) and creates nothing. Reminders: `NOT EXISTS (jobs
with key send_reminder:<id>)` skips follow-ups that already have a reminder job *in any
status*, so a done reminder isn't re-sent by the next day's scan either. The whole scan runs in
**one transaction**: follow-ups and their reminder jobs are committed together, or not at all.
That's the "enqueue in the same transaction as the data" benefit from Step 1.

The follow-up itself is inserted with a single `INSERT … SELECT`: the database finds the stale
deals and inserts the follow-ups in one statement, with no rows travelling to Rust and back.
Its `created_by` is the deal's `owner_id`, so the follow-up lands on the right person's list.
The follow-up is also an *activity on the deal*, so once created, the deal is no longer
"without activity".

**`send_reminder`, run twice:** it sends twice. That's the at-least-once trade-off made
concrete. What it does guarantee is that it re-reads the follow-up: if it was completed or
deleted since the job was enqueued, nothing is sent. (Truly exactly-once email needs the
provider's cooperation, e.g. an idempotency key on their API.)

Other details worth noticing:

- **`anyhow::Result`** for handlers: they're application-level code, and the worker only needs
  "it failed, here's why" (Lab 22's library vs application errors).
- **`let ActivityKind::FollowUp { due_at, done } = … else { bail!(…) }`**: let-else on an enum
  pattern. We already filtered `kind = 'follow_up'` in SQL, but the Rust types don't know that,
  so we handle the impossible case explicitly instead of `unreachable!()`.
- **`(a.details->>'due_at')::timestamptz`**: chrono serializes `DateTime<Utc>` as RFC 3339
  text, which Postgres parses back into a timestamp.
- **The key string `'send_reminder:' || a.id`** must match `Job::idempotency_key` exactly.
  That's a duplicated format, so the DB test in Step 13 covers it.

## Step 10 — The worker

> 🟢 **FOLLOW ALONG**: `src/jobs/worker.rs`:

```rust
//! The worker: claim a job, run it, record the outcome. Repeat until cancelled.

use super::{
    handlers,
    queue::{self, ClaimedJob, FailOutcome},
};
use crate::{config::JobSettings, http::error::error_chain, notifications::Mailer};
use sqlx::PgPool;
use std::{sync::Arc, time::Duration};
use tokio_util::sync::CancellationToken;

/// How long to wait when the queue is empty.
const IDLE_DELAY: Duration = Duration::from_secs(1);
/// How long to wait after the queue itself failed (e.g. database down).
const ERROR_DELAY: Duration = Duration::from_secs(5);

pub async fn run_worker<M: Mailer>(
    pool: PgPool,
    mailer: Arc<M>,
    settings: JobSettings,
    token: CancellationToken,
) {
    tracing::info!("job worker started");
    while !token.is_cancelled() {
        match queue::claim_next(&pool).await {
            // NOT inside select!: once we own a job we finish it, even during shutdown.
            Ok(Some(job)) => process(&pool, mailer.as_ref(), &settings, job).await,
            Ok(None) => pause(&token, IDLE_DELAY).await,
            Err(err) => {
                tracing::error!(error = %error_chain(&err), "could not claim a job");
                pause(&token, ERROR_DELAY).await;
            }
        }
    }
    tracing::info!("job worker stopped");
}

/// Sleeps for `delay`, but wakes up immediately if shutdown is requested.
async fn pause(token: &CancellationToken, delay: Duration) {
    tokio::select! {
        () = token.cancelled() => {}
        () = tokio::time::sleep(delay) => {}
    }
}

#[tracing::instrument(skip_all, fields(job_id = job.id.0, kind = job.job.kind(), attempt = job.attempts))]
async fn process<M: Mailer>(pool: &PgPool, mailer: &M, settings: &JobSettings, job: ClaimedJob) {
    match handlers::handle(pool, mailer, settings, &job.job).await {
        Ok(()) => match queue::complete(pool, job.id).await {
            Ok(()) => tracing::info!("job done"),
            Err(err) => {
                tracing::error!(error = %error_chain(&err), "job ran but could not be marked done")
            }
        },
        Err(err) => {
            let message = format!("{err:#}");
            match queue::fail(pool, &job, &message).await {
                Ok(FailOutcome::RetryAt(at)) => {
                    tracing::warn!(error = %message, retry_at = %at, "job failed, will retry")
                }
                Ok(FailOutcome::GaveUp) => {
                    tracing::error!(error = %message, "job failed for the last time")
                }
                Err(db_err) => {
                    tracing::error!(error = %message, db_error = %error_chain(&db_err), "job failed and could not be rescheduled")
                }
            }
        }
    }
}
```

### `CancellationToken`: asking politely

A `CancellationToken` (from `tokio-util`) is a cheap, cloneable flag with an async side:

| Call | Meaning |
|---|---|
| `token.clone()` | Another handle to the **same** token (an `Arc` inside) |
| `token.cancel()` | Set the flag; wake everyone waiting. Idempotent. |
| `token.is_cancelled()` | Check the flag without waiting |
| `token.cancelled().await` | A future that completes when someone cancels |

It's *cooperative*: nothing is killed. Each task checks the token at points where stopping is
safe. Compared with Lab 26's `watch`/`oneshot` channels, a token can be cloned to any number of
tasks and cancelled from anywhere, and there's no "sender dropped" case to handle.

### Cancellation safety: where may we `select!`?

`tokio::select!` decides by **dropping** the losing future. That's only OK if dropping it at
any `.await` point leaves nothing half-done. Go through the worker's futures:

| Future | Dropped halfway, what happens? | In `select!`? |
|---|---|---|
| `tokio::time::sleep(delay)` | Nothing. A timer stops. | ✅ yes (`pause`) |
| `queue::claim_next(&pool)` | The `UPDATE` may already have committed in Postgres when we drop the future that would have *returned* the row. The job is now `running`, owned by nobody, until `requeue_stuck` rescues it 15 minutes later. | ❌ no |
| `process(...)` | An email half-sent, a scan transaction rolled back (Lab 31's drop-rollback), the outcome never recorded. | ❌ no |

So the worker checks `is_cancelled()` **between** jobs, and races only the idle sleep against
the token. Shutdown therefore waits for the current job to finish: that's the "graceful" in
graceful shutdown. (Keep handlers short; the platform's grace period is seconds, Lab 40.)

Also note the error branch: if Postgres is down, `claim_next` fails every time. Without
`ERROR_DELAY` the loop would spin at 100% CPU logging errors as fast as it can.

**`mailer: Arc<M>`** because the worker owns its mailer for its whole life (`'static`, it's
spawned), while the application may share the same mailer with other tasks.
`mailer.as_ref()` lends a `&M` to `process`; handlers don't need ownership.

**`error_chain`** is your Lab 37 helper (`pub(crate)` in `http::error`). The worker is the
place that *handles* job errors, so it's the one place they're logged (Lab 37's rule), with
the job's span (`job_id`, `kind`, `attempt`) attached to every line.

## Step 11 — The scheduler

The worker only runs jobs that exist. Something has to create "today's scan".

> 🟢 **FOLLOW ALONG**: `src/jobs/scheduler.rs`:

```rust
//! The scheduler: puts periodic work into the queue. It never does the work itself.

use super::{Job, queue};
use crate::{config::JobSettings, http::error::error_chain};
use chrono::Utc;
use sqlx::PgPool;
use std::time::Duration;
use tokio::time::MissedTickBehavior;
use tokio_util::sync::CancellationToken;

pub async fn run_scheduler(pool: PgPool, settings: JobSettings, token: CancellationToken) {
    let mut ticker = tokio::time::interval(Duration::from_secs(settings.scan_interval_secs));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    tracing::info!(
        every_secs = settings.scan_interval_secs,
        "job scheduler started"
    );

    loop {
        tokio::select! {
            () = token.cancelled() => break,
            _ = ticker.tick() => tick(&pool).await,
        }
    }
    tracing::info!("job scheduler stopped");
}

async fn tick(pool: &PgPool) {
    match queue::enqueue(pool, &Job::StaleDealScan, Utc::now()).await {
        Ok(Some(id)) => tracing::info!(job_id = id.0, "stale deal scan enqueued"),
        Ok(None) => tracing::debug!("stale deal scan already queued"),
        Err(err) => {
            tracing::error!(error = %error_chain(&err), "could not enqueue stale deal scan")
        }
    }
}
```

- **The scheduler only enqueues.** The actual scan runs on the worker, with retries, backoff
  and a record in `jobs`. If you run three API instances, three schedulers tick, but the
  idempotency key lets only one scan per day be pending at a time, and `SKIP LOCKED` lets only
  one worker run it.
- **`interval`'s first tick completes immediately**, so a scan is enqueued at startup. That's
  convenient in development and harmless in production thanks to the key.
- **`MissedTickBehavior::Skip`**: if a tick is late (the process was suspended, a tick body
  ran long), don't fire a burst of catch-up ticks; just wait for the next one.
- **Here `select!` is safe**: the two raced futures are `cancelled()` and `tick()`, both
  harmless to drop. The **body** of the winning branch (`tick(&pool).await`) is not raced
  against anything: `select!` only cancels the futures in the branch *patterns*. Once a branch
  wins, its body runs to completion. So shutdown never interrupts an enqueue halfway.

## Step 12 — Settings and wiring it into `Application`

> 🟢 **FOLLOW ALONG**: in `src/config/mod.rs`, add the section and the field:

```rust
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JobSettings {
    /// Run the job worker and scheduler inside this process?
    pub enabled: bool,
    /// A deal with no activity for this many days is "stale".
    pub stale_after_days: i64,
    /// How often the scheduler enqueues a stale-deal scan.
    pub scan_interval_secs: u64,
}

pub struct Settings {
    // ... app, server, database, auth ...
    pub jobs: JobSettings,
}
```

And two rules in `validate()`:

```rust
if self.jobs.stale_after_days < 1 {
    problems.push("jobs.stale_after_days must be at least 1".to_string());
}
if self.jobs.scan_interval_secs == 0 {
    problems.push("jobs.scan_interval_secs must be at least 1".to_string());
}
```

(`tokio::time::interval` **panics** on a zero duration. `validate()` turns that future panic
into a startup error with a clear message.)

`config/default.toml`:

```toml
[jobs]
enabled = true
stale_after_days = 14
scan_interval_secs = 86400   # once a day
```

`config/development.toml`:

```toml
[jobs]
scan_interval_secs = 60      # every minute, so you can watch it happen
```

> 🟢 **FOLLOW ALONG**: in `src/startup.rs`, store the job settings in `Application`
> (`jobs: JobSettings`, filled with `settings.jobs.clone()` in `build`) and replace
> `run_until_stopped` with:

```rust
/// Serves requests and runs the background jobs until `shutdown` completes.
/// Then: stop accepting requests, finish in-flight ones, let the worker finish its
/// current job, and close the database pool.
pub async fn run_until_stopped<F>(self, shutdown: F) -> anyhow::Result<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    tracing::info!(address = %self.listener.local_addr()?, "listening");

    // One token for all background tasks. Cancelling it asks every one of them to stop.
    let token = CancellationToken::new();
    let mut tasks = Vec::new();
    if self.jobs.enabled {
        let mailer = Arc::new(LogMailer);
        tasks.push(tokio::spawn(worker::run_worker(
            self.pool.clone(),
            mailer,
            self.jobs.clone(),
            token.clone(),
        )));
        tasks.push(tokio::spawn(scheduler::run_scheduler(
            self.pool.clone(),
            self.jobs.clone(),
            token.clone(),
        )));
    }

    // When the signal arrives: axum stops accepting connections, AND we cancel the token.
    let signal_token = token.clone();
    let served = axum::serve(self.listener, self.router)
        .with_graceful_shutdown(async move {
            shutdown.await;
            signal_token.cancel();
        })
        .await
        .context("server error");

    // However the server stopped (signal or error), stop the background tasks and wait.
    token.cancel();
    for task in tasks {
        if let Err(err) = task.await {
            tracing::error!(error = %err, "background task panicked");
        }
    }
    served?;

    tracing::info!("server stopped, closing database pool");
    self.pool.close().await;
    tracing::info!("shutdown complete");
    Ok(())
}
```

(New imports: `crate::config::JobSettings`, `crate::jobs::{scheduler, worker}`,
`crate::notifications::LogMailer`, `std::sync::Arc`, `tokio_util::sync::CancellationToken`.)

The shutdown order is the whole design:

```text
SIGTERM ─▶ shutdown future completes ─▶ token.cancel()
             │                              ├─▶ worker: finishes current job, loop sees is_cancelled → returns
             │                              └─▶ scheduler: select! picks cancelled() → returns
             └─▶ axum: stop accepting, finish in-flight requests ─▶ serve(...).await returns
                                                                     │
                                       await every JoinHandle ◀──────┘
                                                 │
                                       pool.close().await  ← nobody is using the pool any more
```

- **Wrapping the shutdown future** (`async move { shutdown.await; signal_token.cancel(); }`)
  makes the signal do two things at once: HTTP drains and jobs stop *in parallel*.
- **`token.cancel()` again after `serve` returns** covers the other way out: if `serve` failed
  with an error, the jobs must still be stopped before we return. Cancelling twice is fine.
- **We `await` the `JoinHandle`s before `pool.close()`.** Closing the pool while the worker is
  mid-job would make its `complete()` fail. `task.await` returns `Err(JoinError)` only if the
  task panicked; we log it rather than abort the shutdown.
- **`served?` after the cleanup**, so a server error doesn't skip stopping the jobs.

Last wiring detail: `tests/server.rs` starts the real app. Its `test_settings()` should not run
background jobs (they'd poll a database the smoke test doesn't use). Add
`("APP__JOBS__ENABLED", "false")` to its variables.

## Step 13 — Database tests

> 🟢 **FOLLOW ALONG**: create `tests/jobs.rs`. Fixtures are inserted with plain SQL (the
> function form `sqlx::query`, which needs no `.sqlx` data): we need things the API doesn't
> allow, like a deal created 20 days ago.

```rust
//! Database tests for the job queue and the job handlers. Each test gets a fresh database.

use chrono::Utc;
use rust_crm::{
    activities::{self, ActivityKind},
    deals::DealId,
    jobs::{
        Job,
        handlers::{self, ScanReport},
        queue,
    },
    subject::Subject,
};
use sqlx::PgPool;

async fn insert_user(pool: &PgPool, email: &str) -> i64 {
    sqlx::query_scalar(
        "INSERT INTO users (email, name, password_hash) VALUES ($1, 'Rep', 'not-a-real-hash') RETURNING id",
    )
    .bind(email)
    .fetch_one(pool)
    .await
    .unwrap()
}

/// A deal created `age_days` ago, owned by `owner`.
async fn insert_deal(pool: &PgPool, owner: i64, stage: &str, age_days: i64) -> i64 {
    let company: i64 =
        sqlx::query_scalar("INSERT INTO companies (name) VALUES ('Acme') RETURNING id")
            .fetch_one(pool)
            .await
            .unwrap();
    sqlx::query_scalar(
        "INSERT INTO deals (company_id, title, value_cents, stage, owner_id, created_at) \
         VALUES ($1, 'Big deal', 100000, $2, $3, now() - make_interval(days => $4::int)) RETURNING id",
    )
    .bind(company)
    .bind(stage)
    .bind(owner)
    .bind(age_days as i32)
    .fetch_one(pool)
    .await
    .unwrap()
}

#[sqlx::test]
async fn enqueue_is_idempotent_while_the_job_is_pending(pool: PgPool) {
    let now = Utc::now();
    let first = queue::enqueue(&pool, &Job::StaleDealScan, now)
        .await
        .unwrap();
    let second = queue::enqueue(&pool, &Job::StaleDealScan, now)
        .await
        .unwrap();

    assert!(first.is_some());
    assert_eq!(
        second, None,
        "same kind + same key while queued = no new job"
    );
}

#[sqlx::test]
async fn stale_deal_scan_creates_one_follow_up_per_stale_deal(pool: PgPool) {
    let rep = insert_user(&pool, "rep@example.com").await;
    let stale = insert_deal(&pool, rep, "proposal", 20).await;
    let _young = insert_deal(&pool, rep, "proposal", 3).await;
    let _closed = insert_deal(&pool, rep, "won", 40).await;
    let now = Utc::now();

    let first = handlers::stale_deal_scan(&pool, 14, now).await.unwrap();
    let second = handlers::stale_deal_scan(&pool, 14, now).await.unwrap();

    assert_eq!(
        first,
        ScanReport {
            follow_ups_created: 1,
            reminders_enqueued: 1
        }
    );
    assert_eq!(
        second,
        ScanReport {
            follow_ups_created: 0,
            reminders_enqueued: 0
        },
        "running twice is harmless"
    );

    // Read it back through the normal repository: proves the JSON shape matches what the app reads.
    let history = activities::db::list_for_subject(&pool, Subject::Deal(DealId(stale)))
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert!(matches!(
        history[0].kind,
        ActivityKind::FollowUp { done: false, .. }
    ));
    assert_eq!(history[0].created_by.0, rep);
}
```

Use whatever function your Lab 31 `activities::db` has for "activities of a subject" (the
name may differ), and adjust the column lists in the fixtures to your schema (e.g. if
`users.role` or `deals.stage` need values).

Add three tests of your own in the same style (they're short; compare with `solutions.md`):
- `a_claimed_job_is_not_claimed_again`: after one claim, the job is `running` with
  `attempts == 1`, and a second `claim_next` returns `None`. (A small
  `async fn job_status(pool, id: JobId) -> String` helper is handy here and in the Your Turns.)
- `jobs_scheduled_in_the_future_are_not_claimed_yet`: `run_at` one hour ahead → `None`.
- `deals_with_recent_activity_are_not_stale`: a 30-day-old deal with a `call` activity 2 days
  ago gets no follow-up.

Then regenerate the offline query data (Lab 30), since you added `query!` calls:

```bash
cargo sqlx prepare
git add .sqlx
```

Lab 33's CI runs `cargo sqlx prepare --check`; forgetting this step fails CI, not your laptop.

```bash
cargo test --test jobs
```

```text
running 5 tests
test jobs_scheduled_in_the_future_are_not_claimed_yet ... ok
test enqueue_is_idempotent_while_the_job_is_pending ... ok
test a_claimed_job_is_not_claimed_again ... ok
test deals_with_recent_activity_are_not_stale ... ok
test stale_deal_scan_creates_one_follow_up_per_stale_deal ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.31s
```

(The `todo!()` in `backoff` doesn't break these tests: it only runs when a job *fails*. Your
Turn 1 replaces it, and adds the test that exercises it.)

Commit: `git commit -am "Add Postgres job queue"` (after `git add` for the new files).

---

## ▶️ Run It

Make one of your deals look stale (pick an id that exists and isn't won/lost):

```bash
docker compose exec db psql -U crm -d crm \
  -c "UPDATE deals SET created_at = now() - interval '20 days' WHERE id = 1;"
cargo run
```

Watch the log for a few seconds, then in another terminal look at the queue:

```bash
docker compose exec db psql -U crm -d crm \
  -c "SELECT id, kind, payload, status, attempts FROM jobs ORDER BY id;"
```

Stop the server with Ctrl+C.

## ✅ Expected Result

```text
2026-10-05T14:57:27.424281Z  INFO rust_crm: starting rust-crm env=development
2026-10-05T14:57:27.437942Z  INFO rust_crm::startup: listening address=127.0.0.1:3000
2026-10-05T14:57:27.438036Z  INFO rust_crm::jobs::worker: job worker started
2026-10-05T14:57:27.438086Z  INFO rust_crm::jobs::scheduler: job scheduler started every_secs=60
2026-10-05T14:57:27.443255Z  INFO rust_crm::jobs::scheduler: stale deal scan enqueued job_id=1
2026-10-05T14:57:28.460547Z  INFO process{job_id=1 kind="stale_deal_scan" attempt=1}: rust_crm::jobs::handlers: stale deal scan finished follow_ups_created=1 reminders_enqueued=1
2026-10-05T14:57:28.461376Z  INFO process{job_id=1 kind="stale_deal_scan" attempt=1}: rust_crm::jobs::worker: job done
2026-10-05T14:57:28.463424Z  INFO process{job_id=2 kind="send_reminder" attempt=1}: rust_crm::notifications: email logged, not sent to="bob@example.com" subject="Follow-up due 2026-10-06 14:57 UTC" body_len=56
2026-10-05T14:57:28.464130Z  INFO process{job_id=2 kind="send_reminder" attempt=1}: rust_crm::jobs::worker: job done
^C2026-10-05T14:57:31.094993Z  INFO rust_crm::shutdown: received Ctrl+C, shutting down
2026-10-05T14:57:31.095054Z  INFO rust_crm::jobs::worker: job worker stopped
2026-10-05T14:57:31.095058Z  INFO rust_crm::jobs::scheduler: job scheduler stopped
2026-10-05T14:57:31.095199Z  INFO rust_crm::startup: server stopped, closing database pool
2026-10-05T14:57:31.095307Z  INFO rust_crm::startup: shutdown complete
```

```text
 id |      kind       |                                payload                                | status | attempts
----+-----------------+-----------------------------------------------------------------------+--------+----------
  1 | stale_deal_scan | {"key": "stale_deal_scan:2026-10-05", "kind": "stale_deal_scan"}      | done   |        1
  2 | send_reminder   | {"key": "send_reminder:1", "kind": "send_reminder", "activity_id": 1} | done   |        1
```

`GET /activities?subject=deal:1` (with a token) now includes the follow-up. The scan job
created the reminder job (inside its transaction), and the worker picked it up a millisecond
later. Restart the server: a new scan is enqueued (yesterday's is `done`, so the key is free),
and it creates nothing new (`follow_ups_created=0 reminders_enqueued=0`).

## 🧠 Understand It

**The queue is just a table plus three rules**: claim atomically (`UPDATE … WHERE id =
(SELECT … FOR UPDATE SKIP LOCKED)`), never lose work (rows outlive processes), and record every
outcome (`done`, `failed` with `last_error`, or `queued` again with a later `run_at`). Your job
queue is queryable with SQL you already know: "how many reminders failed this week?" is one
`SELECT`.

**At-least-once is a contract between the queue and the handlers.** The queue promises "every
job runs, maybe more than once". Each handler promises "running me again is OK". Idempotency
keys reduce duplicates *in the queue*; idempotent handlers make the remaining duplicates
harmless. You need both, because neither can do the other's job.

**Durability, observed.** In the verification run for this lab, a reminder job failed twice
(the mailer was broken on purpose), the server was stopped while the job was waiting for its
40 s backoff, and on the next start the worker picked it up as `attempt=3` and completed it.
No code was needed for that: the job was a row, not a future.

**Where Rust helped.**
- `Job` is an enum: the dispatch in `handlers::handle` is an exhaustive `match`, so a new job
  kind can't be enqueued without a handler.
- The `Mailer` trait states its concurrency contract (`+ Send`) in its signature, and the
  compiler enforces it on every implementation.
- `CancellationToken` + ownership: each spawned task owns its clone of the pool, settings and
  token (`'static`), and `run_until_stopped` owns the `JoinHandle`s, so "wait for everyone
  before closing the pool" is ordinary sequential code.

**What we didn't build** (and libraries do): priorities, per-kind concurrency limits, job
dependencies, a dashboard, `LISTEN/NOTIFY` to wake workers instantly instead of polling every
second, and archiving old `done` rows. Each is a few lines of SQL once you understand the core.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 (retries)**: make `LogMailer::send` return
> `Err(MailError::Transport("SMTP server unreachable".into()))` after logging. Reset the
> follow-up and its reminder (`DELETE FROM jobs; UPDATE activities SET details =
> jsonb_set(details, '{done}', 'false') WHERE kind = 'follow_up';`), run the server for ~25 s
> and watch. Predict the times of the attempts.

```text
… INFO  process{job_id=5 kind="send_reminder" attempt=1}: rust_crm::notifications: email logged, not sent to="bob@example.com" subject="Follow-up due 2026-10-06 14:57 UTC" body_len=56
… WARN  process{job_id=5 kind="send_reminder" attempt=1}: rust_crm::jobs::worker: job failed, will retry error=sending reminder email: mail transport failed: SMTP server unreachable retry_at=2026-10-05 14:58:11.001769 UTC
… INFO  process{job_id=5 kind="send_reminder" attempt=2}: rust_crm::notifications: email logged, not sent …
… WARN  process{job_id=5 kind="send_reminder" attempt=2}: rust_crm::jobs::worker: job failed, will retry error=sending reminder email: mail transport failed: SMTP server unreachable retry_at=2026-10-05 14:58:51.081776 UTC
```

```text
 id |     kind      | status | attempts | max_attempts |  run_at  |                               last_error
----+---------------+--------+----------+--------------+----------+------------------------------------------------------------------------
  5 | send_reminder | queued |        2 |            5 | 16:58:51 | sending reminder email: mail transport failed: SMTP server unreachable
```

20 s, then 40 s (requires Your Turn 1). The error chain from `anyhow`'s `.context(...)` ends up
in `last_error`. Now stop the server, revert the mailer, start it again before or after
`run_at`: what happens to job 5?

> 🟡 **EXPERIMENT 2 (remove `SKIP LOCKED`)**: after Your Turn 4, delete the line
> `FOR UPDATE SKIP LOCKED` from `claim_next` entirely and run
> `cargo test --test jobs concurrent`. Then put back only `FOR UPDATE` and run it again.

Without any lock clause, the verification run printed:

```text
assertion `left == right` failed: every job claimed
  left: 88
 right: 50
```

88 claims for 50 jobs: dozens of jobs were handed to two workers. With plain `FOR UPDATE` the
test passes again (correct, but workers wait for each other). Explain both results using the
timeline in Step 5. Restore `FOR UPDATE SKIP LOCKED`.

> 🟡 **EXPERIMENT 3 (cancellation)**: temporarily move the job processing into the `select!`:
> `tokio::select! { () = token.cancelled() => break, result = queue::claim_next(&pool) => … }`.
> Which row state can be left behind if Ctrl+C arrives at the wrong moment? (You probably
> can't reproduce it by hand, which is exactly why it's dangerous.) Revert.

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `backoff`.** Replace the `todo!()` in `queue::backoff(attempts: i32) ->
> TimeDelta`:
>
> - `10 s × 2^attempts`: 1 → 20 s, 2 → 40 s, 3 → 80 s, 4 → 160 s.
> - Capped at **1 hour**.
> - `attempts <= 0` → 10 s.
> - **Never panics** and never overflows, for *any* `i32` (including `i32::MAX`). `2_i64.pow(64)`
>   panics in debug builds; `TimeDelta::seconds` panics on huge values. Think about the order of
>   clamping and multiplying.
>
> Acceptance:
> - [ ] Unit tests in `queue.rs` for 1, 2, 3, 4, the cap (9, 1000, `i32::MAX`), and 0 / negative.
> - [ ] A DB test `a_failed_job_is_retried_later_then_given_up`: with `max_attempts = 2`,
>       the first `fail` returns `RetryAt(t)` with `t` in the future and the job is `queued` but
>       not claimable yet; after setting `run_at = now()`, the second claim has `attempts == 2`
>       and `fail` returns `GaveUp`, leaving the job `failed`.

> 🔵 **YOUR TURN 2: rescue stuck jobs.** A worker that is `kill -9`ed (or loses its database
> connection) mid-job leaves the row `running` forever.
>
> - Write `pub async fn requeue_stuck(db: impl PgExecutor<'_>, older_than: TimeDelta) ->
>   Result<u64, sqlx::Error>` in `queue.rs`: every job that has been `running` for longer than
>   `older_than` (use `locked_at`) goes back to `queued` with `run_at = now()`, `locked_at`
>   cleared and a `last_error` saying the worker was lost. Jobs that already used all their
>   attempts become `failed` instead. Returns how many rows changed.
> - Call it from the scheduler's `tick` with a `const STUCK_AFTER: TimeDelta` of 15 minutes.
>   Log a `warn!` with the count when it's not zero.
>
> Acceptance:
> - [ ] DB test `stuck_running_jobs_are_requeued`: claim a job, set its `locked_at` to 20 minutes
>       ago, call `requeue_stuck(&pool, TimeDelta::minutes(15))` → returns 1, status is `queued`,
>       and `claim_next` returns it again.
> - [ ] A job claimed 1 minute ago is **not** touched.
> - [ ] In one sentence (code comment): why does this make idempotent handlers even more
>       important?

> 🔵 **YOUR TURN 3: `POST /activities/{id}/complete`.** Let users close a follow-up.
>
> - Marks the follow-up done (`details.done = true`) and returns the updated activity as JSON
>   (`200`).
> - **404** if the activity doesn't exist **or is not a follow-up**.
> - Authorization, using Lab 36's policy: the follow-up's owner (`created_by`) can complete it;
>   managers and admins can complete anyone's; another sales rep gets **404** (not 403, same
>   reasoning as deals).
> - Completing an already-completed follow-up is fine (`200`): idempotent.
> - After completion, `send_reminder` for it sends nothing.
>
> Acceptance (API tests in `tests/api/follow_ups.rs`, using your Lab 35/36 helpers):
> - [ ] owner completes → 200 and `kind.done == true`; completes again → 200
> - [ ] other rep → 404; manager → 200
> - [ ] a `call` activity id → 404; a non-existent id → 404
> - [ ] `cargo sqlx prepare` re-run and `.sqlx/` committed

> 🔵 **YOUR TURN 4: prove it: two claims never get the same job.** In `tests/jobs.rs`, write
> `concurrent_workers_never_claim_the_same_job`:
>
> - Enqueue 50 distinct jobs (hint: `SendReminder` with 50 different `ActivityId`s; the jobs
>   don't have to be runnable, only claimable).
> - Spawn 8 tasks that each loop on `claim_next` until it returns `None`, collecting the
>   `JobId`s they got.
> - Assert: the total number of claims is exactly 50, and there are no duplicates.
>
> Acceptance:
> - [ ] The test passes reliably (run it 10 times: `for i in $(seq 10); do cargo test -q --test jobs concurrent; done`).
> - [ ] It **fails** when you remove `FOR UPDATE SKIP LOCKED` (Experiment 2). A test that
>       can't fail proves nothing.

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: clamp `attempts` into a small range *first* (so `2^attempts`
> fits easily in an `i64`), then multiply with `saturating_mul`, then `.min(3600)`.

<details><summary>Hint 2 (Your Turn 2)</summary>

One `UPDATE` with a `CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'queued' END` for
the status. Compute the threshold in Rust (`Utc::now() - older_than`) and bind it, or use
`now() - $1` with an interval. `result.rows_affected()` is the count.

</details>

<details><summary>Hint 3 (Your Turn 3)</summary>

Two small db functions keep the handler simple: one that returns the follow-up's owner
(`SELECT created_by … WHERE id = $1 AND kind = 'follow_up'` → `Option<UserId>`), and one that
does `UPDATE activities SET details = jsonb_set(details, '{done}', 'true') WHERE id = $1 AND
kind = 'follow_up' RETURNING …`. For the policy, `policy::can(&user, Action::EditDeal,
Some(owner))` expresses "owner, or manager/admin". To create a follow-up in a test, `POST
/activities` with `"kind": {"type": "follow_up", "due_at": "2030-01-01T09:00:00Z", "done": false}`.

</details>

<details><summary>Hint 4 (Your Turn 4)</summary>

`#[sqlx::test]` gives you a `PgPool`; clone it into each `tokio::spawn(async move { … })`.
Each task returns its `Vec<JobId>`; `await` the `JoinHandle`s and `extend` one big `Vec`.
Compare `vec.len()` with a `HashSet` built from it (`JobId` needs `Hash`).

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Name three ways a `tokio::spawn`ed "background job" can silently disappear.
2. Walk through what `FOR UPDATE SKIP LOCKED` does when two workers claim at the same moment.
   What would plain `FOR UPDATE` do? And no lock clause at all?
3. Why does this queue deliver jobs *at least* once, and what does that require from handlers?
   Is `stale_deal_scan` idempotent? Is `send_reminder`?
4. What does the partial unique index on `(kind, payload->>'key')` prevent, and why does it
   only cover `queued` and `running`?
5. Why is `claim_next` not raced against `token.cancelled()` in a `select!`, while the idle
   `sleep` is?
6. Why does `Mailer::send` return `impl Future<…> + Send` instead of being an `async fn`? Why
   can't the worker hold an `Arc<dyn Mailer>`?
7. In what order do the HTTP server, the worker, the scheduler and the pool stop?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cargo sqlx prepare --check`

## Git Commit
```bash
git add .
git commit -m "Add Postgres job queue"
# ... Your Turns ...
git add .
git commit -m "Add stale deal and reminder jobs"
git tag lab-39
git push && git push --tags
```

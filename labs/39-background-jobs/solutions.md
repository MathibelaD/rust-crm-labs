# Lab 39 — Solutions

> 🔴 **SOLUTION**: read these after a genuine attempt. Your version can differ and still be
> correct if it meets the acceptance criteria.

All tests below were run against a real PostgreSQL server while this lab was written. The
fixtures (`insert_user`, `insert_deal`) are the ones from Step 13. A small helper used by
several tests:

```rust
use rust_crm::jobs::JobId;

async fn job_status(pool: &PgPool, id: JobId) -> String {
    sqlx::query_scalar("SELECT status FROM jobs WHERE id = $1")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
}
```

---

## Your Turn 1 — `backoff`

```rust
const BASE_DELAY_SECS: i64 = 10;
const MAX_DELAY_SECS: i64 = 60 * 60;

/// Delay before the next attempt: 10 s × 2^attempts, capped at one hour.
/// 1 → 20 s, 2 → 40 s, 3 → 80 s, 4 → 160 s, … Never panics, whatever `attempts` is.
pub fn backoff(attempts: i32) -> TimeDelta {
    let exponent = attempts.clamp(0, 30) as u32;
    let secs = BASE_DELAY_SECS
        .saturating_mul(2_i64.pow(exponent))
        .min(MAX_DELAY_SECS);
    TimeDelta::seconds(secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_from_twenty_seconds() {
        assert_eq!(backoff(1), TimeDelta::seconds(20));
        assert_eq!(backoff(2), TimeDelta::seconds(40));
        assert_eq!(backoff(3), TimeDelta::seconds(80));
        assert_eq!(backoff(4), TimeDelta::seconds(160));
    }

    #[test]
    fn backoff_is_capped_at_one_hour() {
        assert_eq!(backoff(9), TimeDelta::hours(1)); // 10 × 512 = 5120 s > 3600 s
        assert_eq!(backoff(1_000), TimeDelta::hours(1));
        assert_eq!(backoff(i32::MAX), TimeDelta::hours(1));
    }

    #[test]
    fn backoff_never_goes_below_the_base_delay() {
        assert_eq!(backoff(0), TimeDelta::seconds(10));
        assert_eq!(backoff(-5), TimeDelta::seconds(10));
    }
}
```

DB test in `tests/jobs.rs` (add `FailOutcome` to the `queue` import):

```rust
#[sqlx::test]
async fn a_failed_job_is_retried_later_then_given_up(pool: PgPool) {
    let id = queue::enqueue(&pool, &Job::StaleDealScan, Utc::now())
        .await
        .unwrap()
        .unwrap();
    sqlx::query("UPDATE jobs SET max_attempts = 2 WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();

    // Attempt 1 fails → back to 'queued', in the future.
    let job = queue::claim_next(&pool).await.unwrap().unwrap();
    let outcome = queue::fail(&pool, &job, "boom").await.unwrap();
    assert!(matches!(outcome, FailOutcome::RetryAt(at) if at > Utc::now()));
    assert_eq!(job_status(&pool, id).await, "queued");
    assert!(
        queue::claim_next(&pool).await.unwrap().is_none(),
        "not runnable yet"
    );

    // Pretend the backoff has passed. Attempt 2 fails → 'failed' for good.
    sqlx::query("UPDATE jobs SET run_at = now() WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    let job = queue::claim_next(&pool).await.unwrap().unwrap();
    assert_eq!(job.attempts, 2);
    assert_eq!(
        queue::fail(&pool, &job, "boom again").await.unwrap(),
        FailOutcome::GaveUp
    );
    assert_eq!(job_status(&pool, id).await, "failed");
}
```

**Why it's written this way**

- **Clamp first, then multiply.** `2_i64.pow(64)` overflows (a panic in debug builds, silent
  wrap-around in release). Clamping the exponent to `0..=30` makes `2^exponent` at most about a
  billion, so it always fits. `saturating_mul` is belt-and-braces: if someone later raises the
  base delay, the multiplication sticks at `i64::MAX` instead of overflowing, and `.min` caps it.
- **`TimeDelta::seconds` panics** for values beyond roughly ±292 billion years' worth of
  milliseconds. After `.min(3600)` the value is tiny, so this call can't panic.
- **`attempts.clamp(0, 30) as u32`**: the `as` cast is safe *because* of the clamp (no negative
  numbers left). Casting a negative `i32` to `u32` would wrap to a huge number.
- **Why the test sets `run_at = now()` by hand** instead of sleeping 20 seconds: tests that
  sleep are slow and flaky. We test the *decision* (the row is `queued` with a future
  `run_at`), not the clock.
- **Jitter (optional).** With many jobs failing at the same moment (say, the SMTP server went
  down), they all retry at the same moment too: a "thundering herd". Production queues add a
  random jitter (`rand`, e.g. ±20 %) to `retry_at`. Not needed at CRM scale; worth knowing.

---

## Your Turn 2 — rescuing stuck jobs

`src/jobs/queue.rs`:

```rust
/// Puts jobs whose worker disappeared (crash, `kill -9`, lost connection) back in the queue.
/// A job is "stuck" when it has been 'running' for longer than `older_than`.
/// Jobs that already used all their attempts are failed instead.
pub async fn requeue_stuck(
    db: impl PgExecutor<'_>,
    older_than: TimeDelta,
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query!(
        "UPDATE jobs
         SET status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'queued' END,
             run_at = now(),
             locked_at = NULL,
             last_error = 'worker lost while running the job'
         WHERE status = 'running' AND locked_at < $1",
        Utc::now() - older_than,
    )
    .execute(db)
    .await?;
    Ok(result.rows_affected())
}
```

`src/jobs/scheduler.rs`:

```rust
use chrono::{TimeDelta, Utc};

/// A job 'running' for longer than this is assumed to have lost its worker.
/// Requeuing means it may run twice, which is safe only because every handler is idempotent.
const STUCK_AFTER: TimeDelta = TimeDelta::minutes(15);

async fn tick(pool: &PgPool) {
    // ... enqueue StaleDealScan as before ...
    match queue::requeue_stuck(pool, STUCK_AFTER).await {
        Ok(0) => {}
        Ok(n) => tracing::warn!(jobs = n, "requeued stuck jobs"),
        Err(err) => tracing::error!(error = %error_chain(&err), "could not requeue stuck jobs"),
    }
}
```

Tests:

```rust
#[sqlx::test]
async fn stuck_running_jobs_are_requeued(pool: PgPool) {
    let id = queue::enqueue(&pool, &Job::StaleDealScan, Utc::now())
        .await
        .unwrap()
        .unwrap();
    queue::claim_next(&pool).await.unwrap().unwrap();
    // Simulate a worker that died 20 minutes ago.
    sqlx::query("UPDATE jobs SET locked_at = now() - interval '20 minutes' WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();

    let requeued = queue::requeue_stuck(&pool, TimeDelta::minutes(15))
        .await
        .unwrap();

    assert_eq!(requeued, 1);
    assert_eq!(job_status(&pool, id).await, "queued");
    assert!(queue::claim_next(&pool).await.unwrap().is_some());
}

#[sqlx::test]
async fn recently_claimed_jobs_are_left_alone(pool: PgPool) {
    let id = queue::enqueue(&pool, &Job::StaleDealScan, Utc::now())
        .await
        .unwrap()
        .unwrap();
    queue::claim_next(&pool).await.unwrap().unwrap();

    let requeued = queue::requeue_stuck(&pool, TimeDelta::minutes(15))
        .await
        .unwrap();

    assert_eq!(requeued, 0);
    assert_eq!(job_status(&pool, id).await, "running");
}
```

(`TimeDelta` joins the `chrono` import in `tests/jobs.rs`.)

**Why it's written this way**

- **Time-based ownership is a lease.** `locked_at` says "I took this at 14:57". There's no way
  for the database to know whether a worker is slow or dead, so we pick a timeout and declare
  the lease expired. Pick it longer than any job should ever take.
- **Requeuing is exactly the "crash after doing the work" scenario from Step 6**: maybe the
  worker sent the email and died before `complete()`. The job runs again. That's
  at-least-once, and it's why idempotent handlers aren't optional.
- **The `CASE`** keeps the poison-job protection: a job that kills its worker every time
  burns one attempt per crash (attempts are counted at claim time) and ends as `failed`
  instead of looping forever.
- **The scheduler is the natural home**: it already runs periodically on every instance, and
  the `UPDATE` is idempotent (running it on three instances at once is harmless).
- **`const STUCK_AFTER: TimeDelta = TimeDelta::minutes(15)`** works because
  `TimeDelta::minutes` is a `const fn`. A `JobSettings` field would also be fine.

---

## Your Turn 3 — `POST /activities/{id}/complete`

`src/activities/db.rs`, in the same style as the rest of your activities repository. The
`RETURNING` list must match your `ActivityRow` exactly: `details` needs its override,
`details AS "details: Json<ActivityKind>"`, and from Lab 35 on the row also has `created_by`.

```rust
/// Marks a follow-up as done and returns it. `NotFound` if the activity doesn't exist
/// or isn't a follow-up. Completing an already-completed follow-up is fine (idempotent).
#[tracing::instrument(skip(db))]
pub async fn complete_follow_up(
    db: impl PgExecutor<'_>,
    id: ActivityId,
) -> Result<Activity, CrmError> {
    let row = sqlx::query_as!(
        ActivityRow,
        r#"UPDATE activities SET details = jsonb_set(details, '{done}', 'true')
           WHERE id = $1 AND kind = 'follow_up'
           RETURNING id, subject_type, subject_id,
                     details AS "details: Json<ActivityKind>", summary, occurred_at, created_by"#,
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(CrmError::NotFound {
        entity: "follow-up",
        id: id.0,
    })?;
    Ok(row.try_into()?)
}

/// Who created a follow-up (`None` if there is no follow-up with that id).
pub async fn follow_up_owner(
    db: impl PgExecutor<'_>,
    id: ActivityId,
) -> Result<Option<UserId>, CrmError> {
    let owner = sqlx::query_scalar!(
        r#"SELECT created_by AS "created_by: UserId" FROM activities
           WHERE id = $1 AND kind = 'follow_up'"#,
        id.0,
    )
    .fetch_optional(db)
    .await?;
    Ok(owner)
}
```

`src/http/activities.rs` (new imports: `axum::routing::post`, `super::extract::AppPath`,
`crate::activities::ActivityId`, `crate::auth::policy::{self, Action}`, `crate::errors::CrmError`):

```rust
// routes():
Router::new()
    .route("/activities", get(list_activities).post(log_activity))
    .route("/activities/{id}/complete", post(complete_follow_up))
```

```rust
/// POST /activities/{id}/complete: the follow-up's owner (or a manager/admin) marks it done.
#[tracing::instrument(skip(state, user))]
async fn complete_follow_up(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<ActivityResponse>, ApiError> {
    let id = ActivityId(id);
    let not_found = || {
        ApiError::from(CrmError::NotFound {
            entity: "follow-up",
            id: id.0,
        })
    };

    let owner = activities::db::follow_up_owner(&state.pool, id)
        .await?
        .ok_or_else(not_found)?;
    // Same rule as deals (Lab 36): reps only see their own work; anything else "doesn't exist".
    if !policy::can(&user, Action::EditDeal, Some(owner)) {
        return Err(not_found());
    }

    let activity = activities::db::complete_follow_up(&state.pool, id).await?;
    tracing::info!("follow-up completed");
    Ok(Json(ActivityResponse::from(&activity)))
}
```

It returns the same `ActivityResponse` DTO as `log_activity` and `list_activities`. The tests
below only look at `kind.done`.

`tests/api/follow_ups.rs` (add `mod follow_ups;` to `tests/api/main.rs`). It uses the Lab
35/36 helpers from `tests/api/helpers.rs`: `post_json` for a JSON body and `post` for a POST
without one:

```rust
use crate::helpers::{
    app, create_deal, login_as, post, post_json, register_and_login, send_authed,
};
use axum::http::StatusCode;
use rust_crm::users::Role;
use serde_json::json;
use sqlx::PgPool;

/// Creates a follow-up on a new deal owned by the caller; returns its id.
async fn create_follow_up(app: &axum::Router, token: &str) -> i64 {
    let deal_id = create_deal(app, token).await;
    let (status, body) = send_authed(
        app,
        token,
        post_json(
            "/activities",
            json!({
                "subject": format!("deal:{deal_id}"),
                "kind": { "type": "follow_up", "due_at": "2030-01-01T09:00:00Z", "done": false },
                "summary": "Call them back",
            }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_i64().unwrap()
}

#[sqlx::test]
async fn owner_can_complete_a_follow_up_twice(pool: PgPool) {
    let app = app(pool);
    let rep = register_and_login(&app, "rep@example.com").await;
    let id = create_follow_up(&app, &rep).await;
    let uri = format!("/activities/{id}/complete");

    let (status, body) = send_authed(&app, &rep, post(&uri)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["kind"]["done"], true);

    let (status, _) = send_authed(&app, &rep, post(&uri)).await;
    assert_eq!(status, StatusCode::OK, "completing twice is fine");
}

#[sqlx::test]
async fn another_rep_gets_404_but_a_manager_can_complete(pool: PgPool) {
    let app = app(pool.clone());
    let owner = register_and_login(&app, "owner@example.com").await;
    let other = register_and_login(&app, "other@example.com").await;
    let manager = login_as(&app, &pool, "boss@example.com", Role::Manager).await;
    let id = create_follow_up(&app, &owner).await;
    let uri = format!("/activities/{id}/complete");

    let (status, _) = send_authed(&app, &other, post(&uri)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = send_authed(&app, &manager, post(&uri)).await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test]
async fn completing_something_that_is_not_a_follow_up_is_404(pool: PgPool) {
    let app = app(pool);
    let rep = register_and_login(&app, "rep@example.com").await;
    let deal_id = create_deal(&app, &rep).await;
    let (_, call) = send_authed(
        &app,
        &rep,
        post_json(
            "/activities",
            json!({
                "subject": format!("deal:{deal_id}"),
                "kind": { "type": "call", "minutes": 5 },
                "summary": "Quick call",
            }),
        ),
    )
    .await;
    let uri = format!("/activities/{}/complete", call["id"]);

    let (status, _) = send_authed(&app, &rep, post(&uri)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = send_authed(&app, &rep, post("/activities/999999/complete")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
```

Then `cargo sqlx prepare` and commit `.sqlx/`.

**Why it's written this way**

- **`jsonb_set(details, '{done}', 'true')`** changes one key inside the JSON document in place.
  `'{done}'` is a Postgres *path* (an array of keys), `'true'` is JSON text. Doing it in SQL
  avoids read-modify-write in Rust, where two concurrent completions could race.
- **`WHERE … AND kind = 'follow_up'`** makes "not a follow-up" and "doesn't exist" the same
  outcome (no row), so both become 404 with no extra query. A call activity has no `done`
  field and must never get one.
- **Owner lookup first, then authorize, then update.** Checking authorization *before* the
  write means a rep can't modify someone else's follow-up even for a moment. 404 rather than
  403 for another rep's follow-up: Lab 36's rule, so ids don't leak what exists.
- **Reusing `Action::EditDeal`** expresses "owner, or manager/admin" without a new policy rule.
  If your policy grows, a dedicated `Action::CompleteFollowUp` would be clearer; then add its
  rows to Lab 36's table-driven policy tests.
- **Idempotent by construction**: setting `done = true` twice leaves the same row. The HTTP
  layer inherits that property for free.
- **Interaction with reminders**: `send_reminder` re-reads `done` before sending, so
  completing a follow-up cancels its pending reminder without touching the `jobs` table.

---

## Your Turn 4 — two claims never get the same job

```rust
use std::collections::HashSet;

#[sqlx::test]
async fn concurrent_workers_never_claim_the_same_job(pool: PgPool) {
    const JOBS: i64 = 50;
    const WORKERS: usize = 8;

    for i in 0..JOBS {
        let job = Job::SendReminder {
            activity_id: rust_crm::activities::ActivityId(i),
        };
        queue::enqueue(&pool, &job, Utc::now())
            .await
            .unwrap()
            .unwrap();
    }

    let mut workers = Vec::new();
    for _ in 0..WORKERS {
        let pool = pool.clone();
        workers.push(tokio::spawn(async move {
            let mut mine = Vec::new();
            while let Some(job) = queue::claim_next(&pool).await.unwrap() {
                mine.push(job.id);
            }
            mine
        }));
    }

    let mut all = Vec::new();
    for worker in workers {
        all.extend(worker.await.unwrap());
    }
    let unique: HashSet<_> = all.iter().copied().collect();

    assert_eq!(all.len(), JOBS as usize, "every job claimed");
    assert_eq!(unique.len(), all.len(), "no job claimed twice");
}
```

Verified: 10 runs out of 10 pass with `FOR UPDATE SKIP LOCKED`. With the lock clause removed,
every run failed with between 71 and 88 claims for 50 jobs.

**Why it's written this way**

- **Different `ActivityId`s → different idempotency keys.** Fifty identical
  `StaleDealScan`s would collapse into one job (that's the unique index doing its job), and
  `.unwrap()` on the second `enqueue` would panic on `None`.
- **Real concurrency.** `#[sqlx::test]`'s pool allows several connections, and each spawned
  task uses its own connection from it, so the eight `UPDATE`s genuinely race inside Postgres.
  The multi-threaded part on the Rust side doesn't matter much; the database is where the race
  happens.
- **`let pool = pool.clone();` before `async move`**: each task must *own* a pool handle
  (`tokio::spawn` needs `'static`, Lab 26). Cloning a `PgPool` is an `Arc` increment.
- **Two assertions, two different bugs.** `all.len() == 50` catches double claims *and* lost
  jobs (a claim that returned nothing while jobs remained). `unique.len() == all.len()` names
  the specific failure. With the lock clause removed, the first assertion fails first, with
  `left: 88` telling you how bad it is.
- **A test that can fail.** Experiment 2 is part of the acceptance criteria because a
  concurrency test that passes with or without the protection proves nothing.

---

## The three extra tests from Step 13

`jobs_scheduled_in_the_future_are_not_claimed_yet` needs `TimeDelta`: change the `chrono`
import in `tests/jobs.rs` to `use chrono::{TimeDelta, Utc};`.

```rust
#[sqlx::test]
async fn a_claimed_job_is_not_claimed_again(pool: PgPool) {
    let id = queue::enqueue(&pool, &Job::StaleDealScan, Utc::now())
        .await
        .unwrap()
        .unwrap();

    let claimed = queue::claim_next(&pool)
        .await
        .unwrap()
        .expect("a job to claim");
    assert_eq!(claimed.id, id);
    assert_eq!(claimed.job, Job::StaleDealScan);
    assert_eq!(claimed.attempts, 1);
    assert_eq!(job_status(&pool, id).await, "running");

    assert!(queue::claim_next(&pool).await.unwrap().is_none());
}

#[sqlx::test]
async fn jobs_scheduled_in_the_future_are_not_claimed_yet(pool: PgPool) {
    queue::enqueue(&pool, &Job::StaleDealScan, Utc::now() + TimeDelta::hours(1))
        .await
        .unwrap();
    assert!(queue::claim_next(&pool).await.unwrap().is_none());
}

#[sqlx::test]
async fn deals_with_recent_activity_are_not_stale(pool: PgPool) {
    let rep = insert_user(&pool, "rep@example.com").await;
    let deal = insert_deal(&pool, rep, "negotiation", 30).await;
    sqlx::query(
        "INSERT INTO activities (subject_type, subject_id, kind, details, summary, occurred_at, created_by) \
         VALUES ('deal', $1, 'call', '{\"type\":\"call\",\"minutes\":5}', 'Quick call', now() - interval '2 days', $2)",
    )
    .bind(deal)
    .bind(rep)
    .execute(&pool)
    .await
    .unwrap();

    let report = handlers::stale_deal_scan(&pool, 14, Utc::now())
        .await
        .unwrap();

    assert_eq!(report.follow_ups_created, 0);
}
```

And in `src/jobs/mod.rs`:

```rust
#[test]
fn stale_deal_scan_key_is_per_day() {
    use chrono::TimeZone;
    let morning = Utc.with_ymd_and_hms(2026, 10, 5, 8, 0, 0).unwrap();
    let evening = Utc.with_ymd_and_hms(2026, 10, 5, 20, 0, 0).unwrap();
    let next_day = Utc.with_ymd_and_hms(2026, 10, 6, 8, 0, 0).unwrap();
    let job = Job::StaleDealScan;
    assert_eq!(job.idempotency_key(morning), job.idempotency_key(evening));
    assert_ne!(job.idempotency_key(morning), job.idempotency_key(next_day));
}
```

`Utc.with_ymd_and_hms` needs the `TimeZone` trait in scope (it's a trait method), hence the
`use` inside the test.

---

## Experiment answers

**Experiment 1 (retries).** Attempt 1 runs immediately; attempt 2 about **20 s** later
(`backoff(1)`); attempt 3 would be **40 s** after that. If you stop the server while job 5
waits and start it again later, nothing is lost: in the verification run the restarted worker
picked it up as `process{job_id=5 kind="send_reminder" attempt=3}` and, with the mailer
reverted, logged `job done`. If you restart *before* `run_at`, the job simply waits until then.

**Experiment 2 (no `SKIP LOCKED`).** With no lock clause, both workers' subqueries read the
same "first queued job" from their snapshots. Both `UPDATE … WHERE id = 1`; the second waits
for the first's row lock, then re-checks its `WHERE` clause, which only says `id = 1`, still
true, and updates the row again. Both return job 1. With
plain `FOR UPDATE`, the *subquery* waits for the lock, then re-checks `status = 'queued'`
against the committed row, rejects job 1 and returns the next one: correct, but every claim
waits behind the one before it. `SKIP LOCKED` keeps the correctness and drops the waiting.

**Experiment 3 (cancellation).** If the token is cancelled after Postgres has executed the
`UPDATE` (the job is now `running`) but before `claim_next`'s future returns the row, the
future is dropped and the claim is lost: a `running` job owned by nobody. Nothing would run it
until `requeue_stuck` (Your Turn 2) rescued it 15 minutes later. The window is tiny, which is
exactly why such bugs survive testing and appear in production. Rule of thumb: only race
futures in `select!` that are **cancellation safe** (sleeping, receiving from a channel,
`cancelled()`), never ones that perform a side effect and then report it.

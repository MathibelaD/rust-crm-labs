# Lab 41 — Capstone: Customer Activity Timeline

> **Phase:** Capstone · **Builds on:** Lab 40 · **Time:** ~12–20 hours (spread it out)
> **Your repo before this lab:** tag `lab-40` (and `v1.0.0`) · **After:** tag `lab-41` (and, if you like, `v1.1.0`)

## 🎯 Goal

Design and build one complete feature on your own: a **unified, paginated, authorization-aware
activity timeline** for a company, plus the event recording it needs. There are no
step-by-step instructions in this lab. You get the requirements, the contract and the
acceptance criteria. The design and the code are yours.

## 🧠 What You'll Learn

Nothing new, on purpose. This lab tests whether you can **combine** what you already know into a
design you can defend: schema changes, transactions, a non-trivial SQL read path, cursors,
authorization, validation, tests at three levels, and observability.

## 🔨 What We're Building

### Context

A sales rep opening a company in the CRM today has to stitch the story together by hand:
`GET /history?subject=company:1`, then the same for every contact, then for every deal. Even
then, some of the most important moments **aren't recorded anywhere**. When did this deal move
from *Proposal* to *Negotiation*? Who converted the lead that created this company? The
`deals.stage` column only knows the *current* stage, and a converted lead only knows its status.

You'll build **one chronological feed per company** that answers "what's been happening with
Acme?" in a single request, and the **event recording** that makes the missing history exist
from now on.

> This lab assumes your repo is at `lab-40`: Postgres repositories with `impl PgExecutor<'_>`
> (Lab 31), transactional lead conversion (Lab 31), keyset `Cursor` (Lab 32), `#[sqlx::test]`
> helpers (Lab 33), `AuthUser` + `policy::can` (Labs 35–36), tracing (Lab 37), and the Docker/CI
> pipeline (Lab 40). Challenges A–E are **not** required. If you did Challenge E (Teams), you
> may extend the authorization rules to teams, but that's optional.

---

## User stories

1. *As a sales rep*, I open a company and see everything that happened with it, its people and
   my deals, newest first, so I can prepare for a call in two minutes.
2. *As a sales rep*, I can narrow the feed to just notes, or just stage changes, or just last
   month.
3. *As a sales manager*, I see the full story of every deal at the company, including deals owned
   by other reps, so I can coach and forecast.
4. *As a sales rep*, I must **not** learn anything about deals I don't own, not even that they
   exist (consistent with Lab 36's 404-not-403 rule).
5. *As anyone*, I can scroll back through years of history page by page, and the list never
   duplicates or skips an item, even while new activity is being logged.
6. *As an operator*, I can see in the logs how long a timeline request took, for whom and for
   which company, without seeing anyone's note text.

---

## Functional requirements

### FR1 — What belongs in a company's timeline

The timeline for company **C** contains exactly these **item types**:

| `type` | Source | Included when |
|---|---|---|
| `activity` | `activities` (calls, emails, meetings, follow-ups) | subject is `company:C`, **or** `contact:X` where contact X *currently* belongs to C, **or** `deal:D` where deal D belongs to C |
| `note` | `notes` | same subject rule as activities |
| `deal_stage_changed` | **new**: recorded by you (FR3) | the deal belongs to C |
| `lead_converted` | **new**: recorded by you (FR3) | the conversion created company C |

Records of other companies never appear. A contact who **moved** from company C to company K
shows up under K's timeline from then on. Membership is evaluated at read time (document this
decision in your README; FR-stretch: historical membership).

### FR2 — Ordering and timestamps

- Items are ordered **newest first** by their timestamp: `activities.occurred_at`,
  `notes.created_at`, and the event's own time for the two event types.
- Two items can share a timestamp, and in this CRM they *will* (see Pitfalls in the hints).
  Ordering must be a **total, deterministic order**: the same data always produces the same
  sequence. You choose the tie-breaker and document it.

### FR3 — Event recording

- **`POST /deals/{id}/stage`** (Lab 29/31): when (and only when) the stage actually changes,
  record a `deal_stage_changed` event with `deal_id`, `from`, `to`, the acting user, and the
  time. It is written **in the same database transaction** as the stage update. If the stage
  update fails (invalid transition, optimistic-check conflict, any DB error), **no event
  exists** afterwards.
- **`POST /leads/{id}/convert`** (Lab 29/31): record a `lead_converted` event with `lead_id`,
  the created `company_id`, `contact_id`, the `deal_id` (or none), the acting user, and the
  time, **inside the existing conversion transaction**. If the conversion rolls back, so does
  the event.
- Events are **append-only**: no endpoint updates or deletes them.
- Events are recorded **from this lab onwards**. Backfilling history for existing deals is
  *not* required, but your migration must be additive and safe to run on the live database you
  deployed in Lab 40 (expand, don't break).

### FR4 — Filters

- `type`: a comma-separated subset of `activity,note,deal_stage_changed,lead_converted`.
  Absent means all types.
- `from` (inclusive) and `to` (exclusive): RFC 3339 timestamps, each optional.
- Filters combine with AND, and they combine with pagination: every page of a filtered feed
  applies the same filters.

### FR5 — Pagination

- Cursor-based, newest to oldest: `limit` (default **20**, allowed **1–100**) and an opaque
  `cursor` taken from the previous response's `next_cursor`.
- `next_cursor` is `null` **exactly** when there are no more items.
- Paging through the whole feed with *any* `limit` returns **every item exactly once**, in the
  same order as one big page would.
- Items inserted *newer* than the first page while a client is paging don't cause duplicates
  or gaps in the pages that follow.

### FR6 — Authorization

Rules mirror Lab 36. They must be decided through your existing `policy` module (`can(...)`,
the actions you already have, or a new action you justify). Don't re-implement role checks in
the handler.

| Viewer | Sees |
|---|---|
| Unauthenticated | `401` (existing `require_auth` + `AuthUser`) |
| `admin`, `manager` | Every item in FR1 |
| `sales_rep` | All company- and contact-subject items. Deal-subject items (`activity`/`note` on `deal:D`, and `deal_stage_changed` for D) **only for deals D they own** |
| `sales_rep`, `lead_converted` | Always visible (it's a company-level fact), but `data.deal_id` is `null` unless the rep owns that deal |

- A company that doesn't exist → `404 not_found`. A company that exists but has nothing
  visible → `200` with `"items": []`.
- Authorization is applied **before** pagination: a rep asking for `limit=5` gets 5 *visible*
  items when 5 or more exist.

### FR7 — Observability

- One tracing span per request (your Lab 37 `TraceLayer` already provides the HTTP span) plus an
  `#[instrument]`ed span around the timeline query, recording `company_id`, the viewer's
  `user_id`, the requested `limit`, and the **number of items returned** (record it after the
  query, as an empty field filled in later).
- No note bodies, activity summaries, emails or tokens in logs.

---

## API contract

### Request

```http
GET /companies/{id}/timeline?type=note,deal_stage_changed&from=2026-09-01T00:00:00Z&to=2026-10-01T00:00:00Z&limit=20&cursor=<opaque>
Authorization: Bearer <access token>
```

### Response `200 OK`

```json
{
  "items": [
    {
      "id": "deal_stage_changed:118",
      "type": "deal_stage_changed",
      "occurred_at": "2026-09-30T14:03:11.204518Z",
      "subject": "deal:7",
      "actor": { "id": 3, "name": "Ada Lovelace" },
      "summary": "Acme renewal moved from proposal to negotiation",
      "data": { "deal_id": 7, "deal_title": "Acme renewal", "from": "proposal", "to": "negotiation" }
    },
    {
      "id": "note:52",
      "type": "note",
      "occurred_at": "2026-09-29T08:15:00Z",
      "subject": "contact:12",
      "actor": { "id": 3, "name": "Ada Lovelace" },
      "summary": "Prefers email; travelling until the 10th",
      "data": { "note_id": 52, "body": "Prefers email; travelling until the 10th. Ask about Q4 budget." }
    }
  ],
  "next_cursor": "djF8MjAyNi0wOS0yOVQwODoxNTowMC4wMDAwMDBafDJ8NTI"
}
```

| Field | Rules |
|---|---|
| `id` | `"<type-or-source>:<numeric id>"`, unique within the feed. Clients use it as a React-style key. |
| `type` | One of the four types |
| `occurred_at` | RFC 3339, UTC, **full precision as stored** (microseconds) |
| `subject` | Lab 20's `Subject` format: `company:N`, `contact:N`, `deal:N`. For `lead_converted`: `company:C` |
| `actor` | The user who performed it (`created_by` / event actor), or `null` for system-created items (e.g. Lab 39's stale-deal follow-ups, if you created those without a user) |
| `summary` | Human-readable, at most 120 characters (truncate on a **char boundary**, Lab 09) |
| `data` | Type-specific, exactly: `activity` → `{activity_id, kind, details}` (same `kind`/`details` shape as `GET /activities`); `note` → `{note_id, body}`; `deal_stage_changed` → `{deal_id, deal_title, from, to}`; `lead_converted` → `{lead_id, contact_id, deal_id}` (`deal_id` may be `null`) |
| `next_cursor` | Opaque string, or `null` on the last page |

Money (if you include deal values anywhere) stays integer `value_cents`, as everywhere else.

### Errors (Lab 28's error body)

| Situation | Status | `code` | `fields[].field` |
|---|---|---|---|
| No or invalid token | 401 | `unauthorized` | |
| Company doesn't exist | 404 | `not_found` | |
| Unknown value in `type`, or `type=` empty | 422 | `validation_failed` | `type` |
| `from`/`to` not RFC 3339 | 422 | `validation_failed` | `from` / `to` |
| `from >= to` | 422 | `validation_failed` | `to` |
| `limit` not an integer in 1–100 | 422 | `validation_failed` | `limit` |
| `cursor` can't be decoded | 422 | `validation_failed` | `cursor` |

**All** invalid query fields are reported in one response (Lab 28's "collect all field errors"
rule), not just the first. That means you can't let axum's `Query<T>` reject a bad timestamp
with its own 400. Think about where parsing should happen.

---

## Data & event requirements

- A new migration (or several) that you design. It must:
  - store the two new event types with enough information to render FR1/the contract **without
    joining to tables that might change later** (a deal's title can change; decide whether the
    event stores a snapshot or joins, and justify it),
  - enforce what it can with **constraints** (allowed kinds, required columns per kind,
    foreign keys with deliberate `ON DELETE` behaviour),
  - include the **indexes** your read query needs, justified with `EXPLAIN` output on seeded
    data (Lab 32's `scripts/seed.sql` plus your own events/notes seed).
- Event writes go through a **repository function that takes `impl PgExecutor<'_>`** (Lab 31),
  so the same function can run on `&mut *tx` inside the stage-change and conversion
  transactions.
- `.sqlx/` is regenerated and committed. CI's `cargo sqlx prepare --check` passes.

---

## Authorization rules (summary for your tests)

Using four users (`admin`, `manager`, `rep_a`, `rep_b`), one company **Acme** with contacts
Ada and Bob, deal **A1** owned by `rep_a` and deal **B1** owned by `rep_b`:

| Item | admin | manager | rep_a | rep_b |
|---|---|---|---|---|
| Note on `company:Acme` | ✅ | ✅ | ✅ | ✅ |
| Activity on `contact:Ada` | ✅ | ✅ | ✅ | ✅ |
| Activity on `deal:A1` | ✅ | ✅ | ✅ | ❌ |
| Note on `deal:B1` | ✅ | ✅ | ❌ | ✅ |
| `deal_stage_changed` A1 | ✅ | ✅ | ✅ | ❌ |
| `lead_converted` (created Acme + A1) | ✅ `deal_id: A1` | ✅ `deal_id: A1` | ✅ `deal_id: A1` | ✅ `deal_id: null` |
| Any item of company **Other** | ❌ | ❌ | ❌ | ❌ |

---

## ✅ Acceptance criteria

### Checklist

- [ ] `GET /companies/{id}/timeline` exists, behind authentication, and matches the contract exactly
- [ ] Stage changes and conversions write events in the **same transaction** as the change
- [ ] A failed stage change or a rolled-back conversion leaves **no** event
- [ ] All four types appear, with correct `subject`, `actor`, `summary` and `data`
- [ ] Ordering is newest-first and deterministic with timestamp ties
- [ ] Paging with `limit` 1, 2, 3 and 100 yields identical sequences, with no duplicates or gaps
- [ ] `type`, `from`, `to` filters work alone and combined, across pages
- [ ] Every row of the authorization table above has a test
- [ ] All invalid query fields are reported together as `422 validation_failed`
- [ ] One page is served by a **bounded number of queries**, independent of `limit` and of how
      many contacts/deals the company has (no N+1)
- [ ] `EXPLAIN (ANALYZE)` on seeded data shows your indexes in use. The output is pasted into your
      PR description or design notes
- [ ] Tracing span with `company_id`, `user_id`, `limit`, `items`. No bodies in logs
- [ ] Unit tests (pure logic), DB tests (`#[sqlx::test]`), API tests (`tower::oneshot`), all green in CI
- [ ] `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo sqlx prepare --check` pass
- [ ] No new crates, or each new crate is justified in your design notes
- [ ] Deployed through your Lab 40 pipeline. The migration ran on the live database

### Given / When / Then

```gherkin
Scenario: merged feed, newest first
  Given Acme has a note on the company at 10:00, a call with contact Ada at 11:00,
    and deal A1 moved from qualification to proposal at 12:00
  When the admin requests GET /companies/{acme}/timeline
  Then the items are deal_stage_changed (12:00), activity (11:00), note (10:00)
  And next_cursor is null

Scenario: stage change is atomic with its event
  Given deal A1 is in stage "won"
  When rep_a posts {"stage": "proposal"} to /deals/{a1}/stage
  Then the response is 409 invalid_transition
  And the timeline contains no new deal_stage_changed item

Scenario: conversion rollback leaves no event
  Given a qualified lead whose conversion will fail when inserting the deal
  When the conversion is attempted
  Then no company, contact, deal or lead_converted event exists afterwards

Scenario: ties don't break pagination
  Given 7 timeline items for Acme that all share the same timestamp
  When a client pages with limit=2 until next_cursor is null
  Then it receives 4 pages and 7 distinct items, in the same order as with limit=100

Scenario: concurrent inserts while paging
  Given a client fetched page 1 with limit=5 and holds next_cursor
  When a new note is added to Acme
  And the client fetches the next page with that cursor
  Then the new note is not in that page, and no item from page 1 is repeated

Scenario: rep can't see another rep's deal history
  Given deal B1 at Acme is owned by rep_b and has a note and a stage change
  When rep_a requests Acme's timeline
  Then neither the note on deal:B1 nor B1's stage change is present
  And the lead_converted item that created B1 has data.deal_id = null

Scenario: authorization is applied before the limit
  Given Acme has 10 items on deal:B1 (newest) and 5 company-level notes (older)
  When rep_a requests limit=5
  Then rep_a receives the 5 company-level notes

Scenario: filters
  When the manager requests type=note,lead_converted&from=2026-09-01T00:00:00Z&to=2026-10-01T00:00:00Z
  Then only notes and lead conversions with 2026-09-01 <= occurred_at < 2026-10-01 are returned

Scenario: all validation errors at once
  When a user requests type=note,banana&from=yesterday&limit=0
  Then the response is 422 validation_failed with field errors for type, from and limit

Scenario: unknown company
  When the admin requests the timeline of a company id that doesn't exist
  Then the response is 404 not_found
```

---

## Constraints

- **Postgres is the source of truth.** No in-memory caches of timeline data.
- **No new crates without written justification.** You already have serde, chrono, base64,
  sqlx, tracing, axum. That's enough for a complete solution.
- **No `unwrap`/`expect` on anything derived from user input or the database** in non-test
  code. Errors map to Lab 28's `ApiError`.
- **Don't filter in Rust after fetching a page.** Visibility and filters must be in the query,
  or pagination breaks (see FR6).
- **Reuse, don't fork.** `Subject`, `Cursor` (adapt it if you must, and explain the change),
  `ApiError`, `FieldError`, `AuthUser`, `policy`, the `PgExecutor` pattern.
- **The existing API stays backwards-compatible.** `/history`, `/activities`, `/notes` and
  their tests are unchanged and still pass.
- **Migrations are additive** (Lab 40: expand, then contract).

## Concepts you're expected to use

| Concept | Where you learned it | Where it shows up here |
|---|---|---|
| Enums with data, exhaustive `match` | Labs 11, 20 | `TimelineKind`, type-specific `data` |
| Newtypes, `FromStr`/`Display`/`TryFrom` | Labs 12, 15 | Parsing `type`, `Subject`, IDs |
| Collecting **all** validation errors | Lab 28 | Query-string validation |
| Iterators, `collect::<Result<…>>`, closures | Lab 17 | Parsing `type=a,b,c`, mapping rows |
| Borrowing vs owning in function signatures | Labs 06–10 | `&TimelineQuery`, `&mut *tx` reborrows |
| serde rename/tagging | Lab 21 | JSON shape of items and `data` |
| Error layering (`thiserror`, `?`) | Lab 22 | Row → domain conversions |
| `impl PgExecutor<'_>`, transactions, rollback-on-drop | Lab 31 | Writing events inside existing transactions |
| Keyset pagination, `QueryBuilder`/binds, indexes, `EXPLAIN` | Lab 32 | The read query |
| `#[sqlx::test]`, fixtures | Lab 33 | DB and API tests |
| `AuthUser`, `policy::can`, 404-vs-403 | Labs 35–36 | Visibility |
| `#[instrument]`, `Span::current().record` | Lab 37 | Observability |
| Migrations in CI and on deploy | Labs 33, 40 | Shipping it |

## Suggested milestones

These are **checkpoints, not steps**. Commit (and push) at each one.

1. **Design notes.** A short `docs/timeline.md` (or a section in your README): the schema, the
   read strategy, the cursor format, the tie-breaker, the authorization approach, and **one
   alternative you rejected and why**. Writing it first will save you hours.
2. **Events exist.** The migration, the event repository function, and both write paths wired
   into their transactions, with DB tests proving commit and rollback behaviour.
3. **The read query, unpaginated.** Correct membership and ordering for an admin, proven by DB tests.
4. **Cursor and filters.** The pagination property test (all limits give the same sequence) passes, ties included.
5. **Authorization.** The table above, as tests.
6. **The endpoint.** Query validation, response DTOs, API tests including all `422` cases.
7. **Ship it.** Tracing, `EXPLAIN` evidence, README/API docs updated, CI green, deployed.

## Definition of done

- Every acceptance checkbox is ticked, honestly.
- A teammate could read your design notes and the PR and understand **why**, not just what.
- You can demo it on your **deployed** instance: log in as a rep and as a manager, open the same
  company, and show the difference.
- `git diff lab-40 lab-41 --stat` contains no unrelated changes.

## Self-review rubric

Score yourself honestly (1 = needs work, 2 = solid, 3 = excellent):

| Area | 1 | 2 | 3 |
|---|---|---|---|
| **Correctness** | Some acceptance scenarios fail | All pass | All pass, plus edge cases you found yourself are tested |
| **Data design** | Events stored, few constraints | Constraints + FKs + indexes with reasons | Constraints make invalid events *unrepresentable*; `ON DELETE` behaviour argued |
| **Transactions** | Events written after commit | In the same transaction | Rollback behaviour proven by tests that force a failure |
| **Query** | N+1 or Rust-side filtering | Single bounded query, correct | Single query, `EXPLAIN` evidence, trade-offs documented |
| **Pagination** | Offset or breaks on ties | Keyset, tie-safe | Property-style test over many limits; cursor validated and versioned |
| **Authorization** | Checks in handler code | Through `policy`, enforced in SQL | Every table row tested; zero information leakage (ids, counts, timing of 404s) |
| **Rust quality** | Stringly-typed, `unwrap`s | Enums/newtypes, `?`, clean clippy | Illegal states unrepresentable; small pure functions with unit tests |
| **API** | Shape differs from contract | Exact contract, consistent errors | All errors collected; docs in README with a curl session |
| **Observability** | `println!` / none | Span with fields | Fields recorded post-query; no PII; useful at `info` level |
| **Communication** | No notes | Design notes | Notes include a rejected alternative and how you'd evolve it |

A total of **20+** is excellent work. Anything scored 1 is your next commit.

---

## 💡 Hints

Use them in order, and only after a genuine attempt. Each tier gives away more.

### Schema

<details><summary>Tier 1 — direction</summary>

Ask what you're missing. Activities and notes **already exist** as rows with timestamps.
Stage changes and conversions **don't exist anywhere** once they've happened. Only the second
kind needs new storage.

</details>

<details><summary>Tier 2 — design</summary>

One `events` table with a `kind` column handles both new types. Give it a `company_id` (it makes
the read trivial: the company is fixed at write time and never changes for these two kinds),
nullable typed columns for references you want FKs on (`deal_id`, `lead_id`, `actor_id`), and
a JSONB column for the kind-specific payload (`from`, `to`, `contact_id`, a title snapshot).
`CHECK` constraints can require `deal_id` when `kind = 'deal_stage_changed'`.

</details>

<details><summary>Tier 3 — near-solution</summary>

Index `events (company_id, occurred_at DESC, id DESC)`. Use `DEFAULT clock_timestamp()` rather
than `now()` for `occurred_at`, or pass the time in from Rust. `now()` is frozen at the start
of the transaction, and a conversion that records an event *after* inserting rows would
otherwise share a timestamp with everything else in that transaction. Ties are handled anyway
(see Pagination), but distinct timestamps make the feed read more naturally.

</details>

### Writing events inside existing transactions

<details><summary>Tier 1 — direction</summary>

You already wrote a function that works with both a pool and a transaction in Lab 31. What did
its signature look like?

</details>

<details><summary>Tier 2 — design</summary>

`pub async fn record(db: impl PgExecutor<'_>, event: &NewEvent) -> Result<EventId, CrmError>`.
Call it with `&mut *tx` *before* `tx.commit()`. If your Lab 31 stage-change code didn't use a
transaction (an `UPDATE … WHERE stage = $old` is atomic on its own), it needs one now: two
statements, one atomic unit.

</details>

<details><summary>Tier 3 — near-solution</summary>

Stage change: `let mut tx = pool.begin().await?;` → `SELECT stage, title FROM deals WHERE id = $1 FOR UPDATE`
→ check `can_transition_to` in Rust → `UPDATE … WHERE id = $1 AND stage = $old` (check
`rows_affected() == 1`) → `events::record(&mut *tx, &NewEvent::stage_changed(...))` →
`tx.commit()`. Any `?` before `commit` drops `tx`, which rolls back, so there's no event
without a change and no change without an event.

</details>

### Merging sources

<details><summary>Tier 1 — direction</summary>

Four sources, one ordered page. You can merge in SQL or in Rust. Only one of those works with a
`LIMIT` and a cursor without fetching everything.

</details>

<details><summary>Tier 2 — design</summary>

`UNION ALL` of three `SELECT`s (activities, notes, events), each projecting the **same column
list**, then an outer `ORDER BY … LIMIT`. Push the filters, the cursor predicate and a `LIMIT`
into **each** branch so each can use its index and stop early. A rep's visibility is a CTE of
"deal ids I can see", which each branch references.

</details>

<details><summary>Tier 3 — near-solution</summary>

Map rows into a `TimelineRow { source: i16, id: i64, occurred_at, type_: String, subject_type,
subject_id, actor_id, summary, data: serde_json::Value }` with `query_as::<_, TimelineRow>()` or
`query_as!`. Ask for `limit + 1` rows. If you get more than `limit`, there's a next page, and its
cursor is built from the **last row you return**, not the extra one.

</details>

### Pagination and ties

<details><summary>Tier 1 — direction</summary>

Lab 32's cursor was `occurred_at|id`. Why isn't `id` enough of a tie-breaker when rows come
from three different tables?

</details>

<details><summary>Tier 2 — design</summary>

`activities.id = 5` and `notes.id = 5` can coexist. Add a per-source rank so the sort key is
unique: `(occurred_at, source, id)`. Postgres compares row values lexicographically:
`(occurred_at, source, id) < ($1, $2, $3)`.

</details>

<details><summary>Tier 3 — near-solution</summary>

Encode the cursor with **microsecond** precision (what Postgres stores). If you encode
milliseconds, two items 400 µs apart compare "equal" and one is skipped or repeated. Prefix the
encoded cursor with a version (`v1|…`) so you can change the format later and reject old
cursors with a clear `422`.

</details>

### Authorization

<details><summary>Tier 1 — direction</summary>

You already decided in Lab 36 that list endpoints enforce visibility **in SQL**. This is a list endpoint.

</details>

<details><summary>Tier 2 — design</summary>

Turn the `AuthUser` into a small enum before you query, e.g. `DealVisibility::All` or
`DealVisibility::OwnedBy(UserId)`, using `policy::can(user, Action::ViewAllDeals, None)`. Pass
it to the repository function, which turns it into one nullable bind parameter.

</details>

<details><summary>Tier 3 — near-solution</summary>

`visible_deals AS (SELECT id FROM deals WHERE company_id = $1 AND ($2::bigint IS NULL OR owner_id = $2))`.
For `lead_converted`, project `CASE WHEN e.deal_id IN (SELECT id FROM visible_deals) THEN e.deal_id END`.

</details>

### Testing

<details><summary>Tier 1 — direction</summary>

Three levels: pure functions (cursor, query parsing, summary truncation), repository functions
with a real DB, and the HTTP contract.

</details>

<details><summary>Tier 2 — design</summary>

The most valuable single test: seed items with **identical timestamps** across all sources,
page with `limit` in `1..=n`, and assert each run equals the `limit = 100` run. To force a
conversion rollback, make the deal insert fail with a constraint (e.g. a negative value that
violates `CHECK (value_cents >= 0)`) and assert that no event exists.

</details>

<details><summary>Tier 3 — near-solution</summary>

Write fixtures (`tests/fixtures/timeline.sql`) with explicit timestamps rather than `now()`,
so tests are deterministic. Use `helpers::register_and_login` from Lab 35 for each role, and
promote users with a direct `UPDATE users SET role = …` in the test setup.

</details>

---

## 🚀 Stretch goals

Pick any. Each is a mini-capstone with the same expectations: design notes, tests, no N+1, authorization.

1. **Audit log.** Record *every* mutating API call (who, what, when, before/after for changed
   fields) in an `audit_log` table, written in the same transaction as the change.
   `GET /admin/audit?entity=deal:7` for admins only. Think about where to hook it in without
   copy-pasting into every handler, and why "in the same transaction" rules out pure middleware.
2. **Contact merge.** `POST /contacts/{id}/merge {"into": other_id}` moves activities, notes and
   events from one contact to another and deletes the duplicate, atomically, with `FOR UPDATE`
   on both rows in a **consistent lock order** to avoid deadlocks. Who may merge? What happens
   to timelines of two different companies?
3. **CSV export job.** `POST /companies/{id}/timeline/export` enqueues a Lab 39 job that writes
   the full (authorization-filtered) timeline as CSV and "mails" a link via your `Mailer`.
   Stream rows instead of loading everything (`fetch` returns a `Stream`). Idempotency: two
   clicks, one job.
4. **Rate limiting.** Limit timeline requests per user (e.g. 60/minute) with a `429` and a
   `Retry-After` header. Compare an in-process token bucket (and why it's wrong with two Fly
   machines) with a Postgres-backed counter, and justify any crate you add (e.g. `tower_governor`).

---

## Git Commit

Suggested commits at the milestones (adapt them to what you actually did):

```bash
git commit -m "Add timeline design notes"
git commit -m "Record deal stage and lead conversion events"
git commit -m "Add company timeline query with cursor pagination"
git commit -m "Add company timeline endpoint with authorization"
git commit -m "Add timeline tests"
```

Then:

```bash
git tag lab-41
git tag -a v1.1.0 -m "Rust CRM 1.1.0: company activity timeline"
git push && git push --tags
```

`v1.1.0` (a new feature, no breaking changes) triggers your Lab 40 image build. Deploy it.

## 🆘 Reference design

> 🔴 [`solutions.md`](solutions.md) contains **one** reference design: a schema sketch, the
> event-writing strategy, a query approach with trade-offs, the cursor design, key signatures,
> a test list and pitfalls. It's not a drop-in implementation. **Read it after you've
> finished**, and compare designs instead of copying.

---

## 🎉 You built this

Stop for a moment. Then do these three things in your `rust-crm` repo.

### 1. Look at the whole journey

```bash
git log --oneline --reverse | head -20     # where you started
git log --oneline | wc -l                  # how many commits it took
git tag --list 'lab-*' | sort -V           # 41 checkpoints
git diff lab-01 lab-41 --stat | tail -1    # everything, in one line
```

The last line will say something like *"N files changed, M insertions(+)"*. Lab 01 was **one**
file with **three** lines. Now pick some refactors and look again:

```bash
git diff lab-12 lab-13 --stat     # one file became a library
git diff lab-13 lab-14 --stat     # Customer split into Company + Contact
git diff lab-29 lab-31 --stat     # JSON and the in-memory repo retired; the domain survived
```

In each one, find a file that **didn't** change much. That's the part you designed well.

### 2. Write "What I built"

Add a section near the top of your CRM's `README.md`, in your own words:

```markdown
## What I built

I built this CRM from `cargo new` to a deployed, authenticated, Postgres-backed API while
learning Rust. Highlights:

- …the feature I'm proudest of, and why…
- …the bug that taught me the most…
- …a design decision I'd make differently next time…

From the first commit to v1.1.0: <N> commits, 41 tagged stages (`git tag --list 'lab-*'`).
```

### 3. Reflect (write the answers down; they're for you)

1. Which compiler error did you hate most in Phase 2? Which one would you now explain to a
   colleague in one sentence?
2. Where did **ownership** shape a design decision rather than block you (Lab 14's IDs, Lab
   19's `convert(self)`, Lab 25's `Arc`…)?
3. Which refactor (♻️) felt pointless at the time and obviously right later?
4. What would you build differently if you started `rust-crm-2` tomorrow?
5. What will you build next in Rust, now that you can?

In Lab 01 the compiler was something to get past. You can now read what it's telling you,
and you just shipped a feature with no step-by-step help. Well done. 🦀

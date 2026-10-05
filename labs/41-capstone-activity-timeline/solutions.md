# Lab 41 — Reference Design

> 🔴 **Read this after you've built your own.** This is *one* defensible design, not the
> answer. If yours differs, write down why, because that comparison is the most valuable part
> of the capstone. It's deliberately **not** a drop-in implementation: signatures, sketches
> and reasoning, not files to paste.

---

## 1. The key decision: what goes in the `events` table?

There are three ways to build a merged feed:

| Approach | Writes | Reads | Verdict |
|---|---|---|---|
| **A. Read-time `UNION ALL`** over `activities`, `notes`, `events`. `events` holds **only** the facts that don't exist anywhere else (stage changes, conversions) | Two new write points | One query with three branches | ✅ **Chosen** |
| **B. Everything is an event.** Also write an `events` row for every activity/note (a projection/outbox) | Every write path touches two tables. Edits/deletes of notes must update the projection | Trivial single-table query | Good at large scale; premature here |
| **C. Merge in Rust.** Query each source separately, then k-way merge sorted vectors | Same as A | Three queries, each needing its own `LIMIT n+1`, then merge and trim | Works, but more code for the same result, and easy to get pagination subtly wrong |

**Why A:** activities and notes are already the source of truth with their own timestamps.
Copying them into `events` (B) creates a second source of truth that can drift: a note edited
or deleted in one place but not the other. B starts to pay off when the timeline needs data
from many tables or services, or when reads massively outnumber writes. Then you'd write
events through an outbox in the same transaction and treat `events` as the read model. That's
a great "how would you evolve it?" paragraph for your design notes.

**Why not C:** C is correct if each source query applies the cursor predicate and `LIMIT n+1`,
and you merge by the full `(occurred_at, source, id)` key. It costs three round trips and a
merge you have to test. SQL already does exactly that merge in `UNION ALL … ORDER BY … LIMIT`.

---

## 2. Schema sketch

```sql
CREATE TABLE events (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind        TEXT NOT NULL CHECK (kind IN ('deal_stage_changed', 'lead_converted')),
    company_id  BIGINT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    deal_id     BIGINT REFERENCES deals(id) ON DELETE CASCADE,
    lead_id     BIGINT REFERENCES leads(id) ON DELETE SET NULL,
    actor_id    BIGINT REFERENCES users(id) ON DELETE SET NULL,
    data        JSONB NOT NULL DEFAULT '{}',
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK (kind <> 'deal_stage_changed' OR deal_id IS NOT NULL)
);

CREATE INDEX events_company_timeline ON events (company_id, occurred_at DESC, id DESC);
```

**Reasoning, column by column**

- **`company_id` stored, not derived.** For both event kinds the company is known at write
  time and can never change (deals don't move between companies, and a conversion created
  exactly one company). Storing it makes the events branch of the query a single index range scan.
- **Typed FK columns + JSONB payload.** Things you want referential integrity on (`deal_id`,
  `lead_id`, `actor_id`) get real columns. The kind-specific payload (`from`, `to`,
  `contact_id`, `deal_title` snapshot) goes in `data`. An alternative is fully typed nullable
  columns (`from_stage`, `to_stage`, `contact_id`) with more `CHECK`s. That's stricter, but every
  new event kind needs a migration. Both are defensible. Say which you picked and why.
- **`ON DELETE`**: `CASCADE` from company and deal, because events *about* a deleted thing have no
  timeline to appear in. `SET NULL` for `lead_id` and `actor_id`: deleting a user must not erase
  history, and the item shows `actor: null`. (Today's API can't delete deals or users, but
  your schema shouldn't depend on that staying true.)
- **`CHECK (kind <> 'deal_stage_changed' OR deal_id IS NOT NULL)`** is "if stage change, then
  deal_id" in boolean form. Make invalid events unrepresentable, as you did with Rust enums.
- **`clock_timestamp()` instead of `now()`**: `now()` is the **transaction start** time. A
  conversion transaction that inserts a company, a contact and a deal and then an event would
  stamp all its `now()` defaults identically. `clock_timestamp()` is the wall-clock time of the
  statement. Better still: pass `occurred_at` from Rust (the `now` parameter you've injected
  since Lab 20), which keeps tests deterministic.
- **Deal title snapshot in `data`**: "moved *Acme renewal* to negotiation" should read the
  same in two years, even if the deal is renamed. Snapshot what the event *meant at the time*,
  and join for what must be current.
- **No index on `activities` needed.** Lab 32's `activities (subject_type, subject_id,
  occurred_at DESC)` already serves the activity branch. `notes` has no equivalent index yet. Add
  `notes (subject_type, subject_id, created_at DESC)` and show the `EXPLAIN` before and after.

---

## 3. Writing events inside existing transactions

```rust
// src/events/mod.rs (+ model.rs, db.rs)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type)]
#[sqlx(transparent)]
pub struct EventId(pub i64);

pub enum NewEvent<'a> {
    DealStageChanged { company: CompanyId, deal: DealId, title: &'a str, from: DealStage, to: DealStage },
    LeadConverted    { company: CompanyId, lead: LeadId, contact: ContactId, deal: Option<DealId> },
}

pub async fn record(
    db: impl PgExecutor<'_>,
    event: &NewEvent<'_>,
    actor: UserId,
    at: DateTime<Utc>,
) -> Result<EventId, CrmError>;
```

- `NewEvent` is an **enum with data**, so you can't build a stage-change event without a deal or
  with a missing `to`. The function `match`es it into column values plus a `serde_json::json!`
  payload.
- `title: &'a str` **borrows** the title the stage-change code already holds. The event
  doesn't need to own it, because it's only serialised into the insert and the borrow ends
  when `record` returns. This is Lab 10's "borrowed input, owned output" heuristic.
- `impl PgExecutor<'_>` takes `&PgPool` **or** `&mut *tx` (Lab 31). Inside a transaction you
  pass `&mut *tx`, a **reborrow** of the connection. `tx` itself stays usable afterwards for
  `tx.commit()`.

**Stage change** (`deals::service::move_stage`, or wherever Lab 31 put it):

```text
begin tx
  SELECT stage, title, company_id, owner_id FROM deals WHERE id = $1 FOR UPDATE   → 404 if none
  authorize(EditDeal, owner)                                                      → 404/403 per Lab 36
  current.can_transition_to(next)?                                                → 409 invalid_transition
  if current == next → commit, return (no event: nothing changed)
  UPDATE deals SET stage = $2 WHERE id = $1 AND stage = $current                 → rows_affected must be 1
  events::record(&mut *tx, &NewEvent::DealStageChanged{..}, user.id, now)
commit
```

`FOR UPDATE` makes the optimistic `AND stage = $current` redundant but harmless. Keep one and
explain which. Every `?` before `commit()` drops `tx`, and **`Transaction`'s `Drop` rolls
back**. That's the whole atomicity argument, and it's RAII again.

**Lead conversion**: add one `events::record(&mut *tx, &NewEvent::LeadConverted{..}, …)`
call after the deal insert and before `commit()` in Lab 31's `convert_lead`. Nothing else changes.

---

## 4. Query approach

One query, three branches, a shared visibility CTE. This sketch was run against Postgres 18
with ties across all sources, and paging with limits 1–4 reproduced the single-page order
exactly:

```sql
WITH
visible_deals AS (
    SELECT id FROM deals
    WHERE company_id = $1 AND ($2::bigint IS NULL OR owner_id = $2)   -- $2 NULL = sees all deals
),
company_contacts AS (SELECT id FROM contacts WHERE company_id = $1),
items AS (
    (SELECT 1::smallint AS source, a.id, a.occurred_at, 'activity' AS type,
            a.subject_type || ':' || a.subject_id AS subject, a.created_by AS actor_id,
            a.summary, jsonb_build_object('activity_id', a.id, 'kind', a.kind, 'details', a.details) AS data
     FROM activities a
     WHERE 'activity' = ANY($3)
       AND (   (a.subject_type = 'company' AND a.subject_id = $1)
            OR (a.subject_type = 'contact' AND a.subject_id IN (SELECT id FROM company_contacts))
            OR (a.subject_type = 'deal'    AND a.subject_id IN (SELECT id FROM visible_deals)))
       AND ($4::timestamptz IS NULL OR a.occurred_at >= $4)
       AND ($5::timestamptz IS NULL OR a.occurred_at <  $5)
       AND ($6::timestamptz IS NULL OR (a.occurred_at, 1::smallint, a.id) < ($6, $7, $8))
     ORDER BY a.occurred_at DESC, a.id DESC
     LIMIT $9)
    UNION ALL
    (/* notes: same shape, source 2, created_at */)
    UNION ALL
    (/* events: source 3, WHERE e.company_id = $1 AND e.kind = ANY($3)
        AND (e.kind <> 'deal_stage_changed' OR e.deal_id IN (SELECT id FROM visible_deals)),
        and for lead_converted: CASE WHEN e.deal_id IN (SELECT id FROM visible_deals)
                                     THEN e.deal_id END AS the exposed deal_id */)
)
SELECT * FROM items
ORDER BY occurred_at DESC, source DESC, id DESC
LIMIT $9;          -- $9 = limit + 1
```

**Why it's shaped like this**

- **Each branch has its own filters, cursor predicate, `ORDER BY` and `LIMIT`.** Postgres can
  then read each source from an index in order and stop after `limit + 1` rows. Without the inner
  limits, the outer `ORDER BY` must sort *every* matching row of a company with years of history.
- **The cursor predicate uses the branch's constant `source`**, so the row-value comparison
  `(ts, source, id) < ($6, $7, $8)` means the same thing in every branch: for a row in a
  *higher* source than the cursor at the same timestamp, it's already been served, and for a
  lower one it hasn't.
- **Visibility is a CTE parameterised by one nullable bind (`$2`)**, derived from
  `policy::can(user, Action::ViewAllDeals, None)`. The policy stays the single source of truth,
  and SQL only receives "all" or "owned by X".
- **The `OR` across subject types** can stop Postgres from using the
  `(subject_type, subject_id, occurred_at)` index as one ordered scan. On seeded data, check
  `EXPLAIN (ANALYZE, BUFFERS)`. If you see a big sort, split each source into per-subject-type
  branches (company / contact / deal), each a clean index range scan. More SQL, but each piece is
  simple. That's a good measured optimisation to document.
- **`$3` is `text[]`.** Bind a `Vec<&str>` built from your `TimelineKind`s. sqlx encodes it as
  a Postgres array.
- `query_as!` works with this query once it's in `.sqlx/`. Nullable-ness inference through
  `UNION ALL` is conservative, so you may need `as "actor_id?"`-style overrides. The function form
  `query_as::<_, TimelineRow>(include_str!("timeline.sql"))` plus `#[derive(FromRow)]` is a fine
  alternative. Name the trade-off (compile-time checking vs. simpler typing).

---

## 5. Cursor design

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimelineCursor { pub occurred_at: DateTime<Utc>, pub source: i16, pub id: i64 }

impl TimelineCursor {
    pub fn encode(&self) -> String;                 // base64url("v1|<rfc3339 micros>|<source>|<id>")
    pub fn decode(s: &str) -> Option<Self>;         // None → 422 field "cursor"
}
```

- **Sort key = `(occurred_at, source, id)`**, unique across the merged feed. Lab 32's
  `occurred_at|id` isn't unique once two tables are involved.
- **Microsecond precision** (`to_rfc3339_opts(SecondsFormat::Micros, true)`): Postgres stores
  µs. Encoding milliseconds would make distinct rows compare equal and silently skip one.
- **A version prefix** lets you change the format later and reject stale cursors cleanly.
- **Validate `source` is in range** when decoding. A forged cursor should be a `422`, not a
  weird query.
- **The cursor doesn't encode filters.** Re-using it with different filters is well-defined
  ("items before this position that match the new filters"). If you'd rather forbid it,
  include a hash of the filters and reject mismatches. Either way, document it.
- Building it: the **last returned** row, never the `limit + 1` probe row.

---

## 6. Key type signatures

```rust
// Parsing: all fields as Strings so validation collects every error (Lab 28)
#[derive(Deserialize, Default)]
pub struct TimelineParams { #[serde(rename = "type")] pub types: Option<String>,
                            pub from: Option<String>, pub to: Option<String>,
                            pub limit: Option<String>, pub cursor: Option<String> }

pub enum TimelineKind { Activity, Note, DealStageChanged, LeadConverted }   // FromStr, as_str, ALL

pub struct TimelineQuery { pub kinds: Vec<TimelineKind>, pub from: Option<DateTime<Utc>>,
                           pub to: Option<DateTime<Utc>>, pub limit: i64, pub cursor: Option<TimelineCursor> }
impl TryFrom<TimelineParams> for TimelineQuery { type Error = Vec<FieldError>; /* … */ }

pub enum DealVisibility { All, OwnedBy(UserId) }
impl DealVisibility { pub fn for_user(user: &AuthUser) -> Self /* via policy::can */ ;
                      fn owner_filter(&self) -> Option<UserId> }

#[derive(sqlx::FromRow)]
pub struct TimelineRow { source: i16, id: i64, occurred_at: DateTime<Utc>, #[sqlx(rename = "type")] kind: String,
                         subject: String, actor_id: Option<i64>, summary: String, data: serde_json::Value }

pub async fn company_timeline(db: impl PgExecutor<'_>, company: CompanyId, q: &TimelineQuery,
                              vis: &DealVisibility) -> Result<Vec<TimelineRow>, CrmError>;

#[derive(Serialize)] pub struct TimelineItem { id: String, #[serde(rename = "type")] kind: TimelineKind /* snake_case */,
                     occurred_at: DateTime<Utc>, subject: String /* Subject's Display: "deal:7" */, actor: Option<ActorRef>, summary: String,
                     data: serde_json::Value }
#[derive(Serialize)] pub struct TimelinePage { items: Vec<TimelineItem>, next_cursor: Option<String> }

#[instrument(skip(state, params), fields(company_id = %id, user_id = %user.id, limit, items))]
pub async fn get_timeline(State(state): State<AppState>, user: AuthUser, Path(id): Path<CompanyId>,
                          Query(params): Query<TimelineParams>) -> Result<Json<TimelinePage>, ApiError>;
```

Notes:
- **`TimelineParams` → `TimelineQuery` via `TryFrom`** is Lab 28's DTO → domain boundary.
  `type=note,banana&from=yesterday&limit=0` produces three `FieldError`s in one pass.
- **Parsing `type`**: `list.split(',').map(str::trim).map(TimelineKind::from_str).collect::<Result<Vec<_>, _>>()`.
  `collect` into `Result` short-circuits on the first unknown kind. That's fine, since that's one
  field and one error.
- **`ActorRef { id, name }`**: either join `users` in each branch (one more `LEFT JOIN`) or collect the
  distinct `actor_id`s from the page and fetch names in **one** `WHERE id = ANY($1)` query.
  That's two queries per page, bounded and independent of page size. Both satisfy "no N+1".
- **Record `items` after the query**: `tracing::Span::current().record("items", page.items.len())`.
  The field must be declared (empty) in `#[instrument(fields(…))]` for `record` to work.
- **Company existence**: check it first (`companies::db::get`) to return `404` vs an empty `200`. Fold
  it into the same transaction or accept the tiny race and document it.
- **Summary truncation** must respect char boundaries: `s.chars().take(120).collect::<String>()`
  or `char_indices().nth(120)`. Byte slicing `&s[..120]` panics on multi-byte text (Lab 09).

---

## 7. Test list

**Unit (no DB)**
- `TimelineKind` round-trips `from_str`/`as_str` for all four. Unknown → error.
- Cursor: encode/decode round trip with µs. Garbage, wrong version, extra fields and an
  out-of-range source → `None`.
- `TryFrom<TimelineParams>`: defaults; each invalid field alone; all invalid fields together
  (asserts the exact list of `field`s); `from >= to`; `limit` 0, 101, `"abc"`, 1, 100.
- `DealVisibility::for_user` for each role (table-driven, like Lab 36's policy tests).
- Summary truncation with multi-byte text (`"Zoë…"`).

**DB (`#[sqlx::test(fixtures("timeline"))]`)**
- Stage change writes exactly one event with correct `from`/`to`/actor. A no-op "change" writes none.
- An invalid transition leaves **no** event, and the deal's stage is unchanged.
- Conversion writes `lead_converted`. A forced deal-insert failure leaves no company, contact,
  deal **or** event (the strongest test in the suite).
- Membership: items of another company never appear; a contact moved to another company
  disappears from the old timeline.
- Ordering with **all-equal timestamps across all three sources**.
- **Pagination property:** for `limit` in `1..=n`, the concatenated pages equal the `limit = 100` page.
- Each filter alone, and combined with a cursor.
- `CHECK` constraint: inserting a `deal_stage_changed` row without `deal_id` fails.

**API (`tower::oneshot`)**
- `401` without a token; `404` for an unknown company; `200` with `items: []` for an empty one.
- Exact JSON shape of each item type (assert on keys, not only values).
- Every row of the README's authorization table, for each role.
- "Authorization before limit": rep with `limit=5` gets 5 visible items.
- The `422` cases, including the all-at-once one.
- `next_cursor` is `null` on the last page (including when the item count is an exact multiple of `limit`).

---

## 8. Pitfalls

1. **Filtering after the `LIMIT`** (in Rust or an outer query) makes pages short, empty, or
   wrong. Visibility belongs inside each branch.
2. **`id` alone as a tie-breaker** across tables. `note:5` and `activity:5` collide, and one gets skipped.
3. **`now()` inside a transaction** stamps every row identically. Use `clock_timestamp()` or
   pass `at` from Rust.
4. **Millisecond cursors** skip rows that differ by microseconds.
5. **Building `next_cursor` from the probe row** (the `limit + 1`th) skips that row on the next page.
6. **Writing the event after `commit()`** (or on the pool instead of `&mut *tx`). A crash between
   the two leaves a change with no history. A test that forces a failure is the only proof.
7. **`Query<TimelineQuery>` with typed fields** lets axum reject bad input with its own plain-text
   `400`, one error at a time. Parse Strings, then validate.
8. **Leaking through `lead_converted`**: exposing `deal_id`, a deal title or a value in the
   summary for a deal the rep can't see. Also check the `summary` text, not just `data`.
9. **Forgetting `cargo sqlx prepare`** after adding queries. CI's `--check` and the Docker build
   (`SQLX_OFFLINE`) both fail. That's what they're for.
10. **A non-additive migration** (e.g. making a new column `NOT NULL` without a default) fails
    on the live database you deployed in Lab 40, which has rows.
11. **Logging bodies.** `#[instrument]` records all arguments by default. `skip` the params
    and the state.

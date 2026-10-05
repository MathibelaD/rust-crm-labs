# Lab 32 — Search, Filtering & Pagination in SQL

> **Phase:** 9 — PostgreSQL · **Builds on:** Lab 31 · **Time:** ~6 hours
> **Your repo before this lab:** tag `lab-31` · **After:** tag `lab-32`

This lab assumes you completed Your Turns 1–3 in Lab 31 (notes on Postgres, `history::merge`,
`deals::pipeline_report`). If not, see Lab 31's `solutions.md`.

## 🎯 Goal
Make the CRM fast at 100,000 rows: build dynamic filters safely with `QueryBuilder`, add the
right indexes (including trigram indexes for `ILIKE '%term%'`), add a cross-entity
`GET /search`, switch activity and history feeds to **keyset** pagination, fix an N+1 query, and
move the pipeline report into SQL.

## 🧠 What You'll Learn
- Reading `EXPLAIN ANALYZE`: sequential scans, index scans, sorts, buffers
- Indexes: B-tree, composite and GIN trigram (`pg_trgm`), and why foreign keys need their own
- SQL injection, demonstrated on your own API, and sqlx 0.9's `SqlSafeStr` speed bump
- `QueryBuilder` + `push_bind`: dynamic SQL where values are never pasted into the text
- Offset vs keyset pagination, and an opaque, encoded `Cursor` type
- The N+1 query problem, measured
- Aggregation in SQL (`GROUP BY`) vs in Rust (iterators), and when each wins
- Running independent queries concurrently with `tokio::try_join!`

## 🔨 What We're Building
- `scripts/seed.sql`: 10k companies, 100k contacts, 30k deals, 100k activities
- a migration with indexes and `pg_trgm`
- `companies::db::list` and `contacts::db::list` rewritten with `QueryBuilder`
- `GET /search?q=term&limit=10` → `{ companies, contacts, deals }`
- `GET /activities?subject=deal:3&limit=20&cursor=…` and `GET /history?...` → `{ items, next_cursor }`
- `GET /companies/overview` with per-company counts in one query
- `GET /pipeline` computed by Postgres

Everything you measure here, you measure on your own machine. Your timings will differ from the
ones shown. Compare the **shape** of the numbers (ms vs µs, thousands of rows vs dozens), not the
digits.

---

## Step 1 — Seed 100,000 rows

Performance problems hide behind small data. Generate realistic volume with Postgres's
`generate_series`, which produces rows in the database without any round trips.

> 🟢 **FOLLOW ALONG**: create `scripts/seed.sql` in your repo.

```sql
-- Development seed: 10,000 companies, 100,000 contacts, 30,000 deals,
-- 100,000 activities. Safe to run more than once (it only adds rows).
-- Usage: docker compose exec -T db psql -U crm -d crm < scripts/seed.sql

\timing on
BEGIN;

INSERT INTO companies (name, website, lifecycle)
SELECT (ARRAY['Acme', 'Globex', 'Initech', 'Umbrella', 'Hooli', 'Stark', 'Wayne', 'Tyrell'])[1 + g % 8]
       || ' ' || (ARRAY['Labs', 'Systems', 'Holdings', 'Analytics', 'Foods'])[1 + g % 5]
       || ' ' || g,
       'https://company' || g || '.test',
       (ARRAY['prospect', 'customer', 'churned'])[1 + g % 3]
FROM generate_series(1, 10000) AS g;

-- The 10,000 companies we just inserted have consecutive ids ending at max(id).
INSERT INTO contacts (name, email, company_id)
SELECT (ARRAY['Ada', 'Grace', 'Alan', 'Barbara', 'Edsger', 'Margaret', 'Linus', 'Ken'])[1 + g % 8]
       || ' ' || (ARRAY['Lovelace', 'Hopper', 'Turing', 'Liskov', 'Dijkstra', 'Hamilton', 'Torvalds', 'Thompson'])[1 + (g / 8) % 8]
       || ' ' || g,
       'seed' || g || '.' || md5(random()::text) || '@example.test',
       (SELECT max(id) FROM companies) - 9999 + g % 10000
FROM generate_series(1, 100000) AS g;

INSERT INTO deals (company_id, title, value_cents, stage)
SELECT (SELECT max(id) FROM companies) - 9999 + g % 10000,
       'Seeded deal ' || g,
       (random() * 5000000)::bigint,
       (ARRAY['qualification', 'proposal', 'negotiation', 'won', 'lost'])[1 + g % 5]
FROM generate_series(1, 30000) AS g;

-- Most activities are spread out; 5,000 pile up on one "hot" deal so that
-- paginating its history is interesting.
INSERT INTO activities (subject_type, subject_id, kind, details, summary, occurred_at)
SELECT 'deal',
       CASE WHEN g <= 5000 THEN (SELECT max(id) FROM deals)
            ELSE (SELECT max(id) FROM deals) - 29999 + g % 30000 END,
       'call',
       jsonb_build_object('type', 'call', 'minutes', 5 + g % 55),
       'Seeded call ' || g,
       now() - (g || ' minutes')::interval
FROM generate_series(1, 100000) AS g;

COMMIT;
ANALYZE;
```

```bash
docker compose exec -T db psql -U crm -d crm < scripts/seed.sql
```

```text
Timing is on.
BEGIN
INSERT 0 10000
Time: 13.607 ms
INSERT 0 100000
Time: 733.485 ms
INSERT 0 30000
Time: 99.418 ms
INSERT 0 100000
Time: 210.089 ms
COMMIT
ANALYZE
```

- `-T` stops `docker compose exec` from allocating a terminal, so `<` can pipe the file in.
- The `(SELECT max(id) FROM companies)` subqueries don't depend on `g`, so Postgres evaluates
  each **once** (an "InitPlan"), not 100,000 times.
- Emails get an `md5(random())` part so the script can run twice without breaking the `UNIQUE`
  constraint.
- `ANALYZE` refreshes the table statistics the query planner uses to choose plans.
- Note your "hot deal" id: `docker compose exec db psql -U crm -d crm -c 'select max(id) from deals'`.
  Below it's `30001`.

Seed data is for development only. Never point this at a real database.

## Step 2 — Read a query plan

`EXPLAIN ANALYZE` *runs* a query and reports how Postgres executed it. Open psql
(`docker compose exec db psql -U crm -d crm`) and try the three queries your API runs most:
contacts of a company, a name search, and a subject's newest activities.

```sql
EXPLAIN ANALYZE SELECT id, name, email FROM contacts WHERE company_id = 4242;
```

```text
 Seq Scan on contacts  (cost=0.00..2887.01 rows=10 width=83) (actual time=0.206..4.769 rows=10.00 loops=1)
   Filter: (company_id = 4242)
   Rows Removed by Filter: 99991
   Buffers: shared hit=1637
 Planning Time: 0.207 ms
 Execution Time: 4.784 ms
```

How to read it:

- **`Seq Scan`**: read the whole table, row by row.
- **`Rows Removed by Filter: 99991`**: it looked at 100,001 rows to return 10. That ratio is the
  smell.
- **`Buffers: shared hit=1637`**: 8 KB pages touched (from memory). That's 13 MB read to find 10
  rows.
- `cost=` is the planner's *estimate*, in arbitrary units. `actual time=` is what happened.

(Postgres 17 prints `rows=10`; 18, used to verify this lab, prints `rows=10.00` and some extra
`Index Searches:` lines. Same information.)

```sql
EXPLAIN ANALYZE SELECT id, name, email FROM contacts
WHERE name ILIKE '%turing 4242%' OR email ILIKE '%turing 4242%' ORDER BY id LIMIT 20;
```

```text
 Limit  (cost=3137.45..3137.50 rows=20 width=83) (actual time=32.972..32.972 rows=1.00 loops=1)
   ->  Sort  (cost=3137.45..3137.50 rows=20 width=83) (actual time=32.971..32.971 rows=1.00 loops=1)
         Sort Key: id
         ->  Seq Scan on contacts  (cost=0.00..3137.01 rows=20 width=83) (actual time=1.459..32.964 rows=1.00 loops=1)
               Filter: ((name ~~* '%turing 4242%'::text) OR (email ~~* '%turing 4242%'::text))
               Rows Removed by Filter: 100000
 Execution Time: 32.983 ms
```

`~~*` is `ILIKE`. 33 ms per search, growing linearly with the table.

```sql
EXPLAIN ANALYZE SELECT id, summary, occurred_at FROM activities
WHERE subject_type = 'deal' AND subject_id = 30001
ORDER BY occurred_at DESC, id DESC LIMIT 20;
```

```text
 Limit  (actual time=5.509..5.510 rows=20.00 loops=1)
   ->  Sort  (actual time=5.509..5.509 rows=20.00 loops=1)
         Sort Key: occurred_at DESC, id DESC
         Sort Method: top-N heapsort  Memory: 26kB
         ->  Seq Scan on activities  (actual time=0.006..5.206 rows=5003.00 loops=1)
               Filter: ((subject_type = 'deal'::text) AND (subject_id = 30001))
               Rows Removed by Filter: 94998
```

Scan everything, keep 5,003 rows, sort them, return 20.

## Step 3 — Indexes

An index is a separate, sorted data structure that maps column values to rows, a bit like a
`BTreeMap<value, Vec<row location>>` the database keeps up to date on every write. Reads get
faster, writes get slightly slower, and indexes take disk space. You add the ones your queries
need.

> 🟢 **FOLLOW ALONG**: `sqlx migrate add add_indexes`

```sql
-- Foreign keys are NOT indexed automatically in Postgres.
CREATE INDEX contacts_company_id_idx ON contacts (company_id);
CREATE INDEX deals_company_id_idx    ON deals (company_id);
CREATE INDEX deals_stage_idx         ON deals (stage);

-- Serves "activities for a subject, newest first" and its keyset pagination.
CREATE INDEX activities_subject_idx
    ON activities (subject_type, subject_id, occurred_at DESC, id DESC);
CREATE INDEX notes_subject_idx
    ON notes (subject_type, subject_id, created_at DESC, id DESC);

-- Trigram indexes make ILIKE '%term%' searches indexable.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX companies_name_trgm_idx ON companies USING gin (name gin_trgm_ops);
CREATE INDEX contacts_name_trgm_idx  ON contacts  USING gin (name gin_trgm_ops);
CREATE INDEX contacts_email_trgm_idx ON contacts  USING gin (email gin_trgm_ops);
CREATE INDEX deals_title_trgm_idx    ON deals     USING gin (title gin_trgm_ops);
```

```bash
sqlx migrate run
```

- **Foreign-key indexes.** Postgres indexes primary keys and `UNIQUE` columns automatically,
  but *not* the referencing side of a foreign key. `contacts.company_id` needs its own index for
  "contacts of company X", and it also speeds up `ON DELETE RESTRICT` checks.
- **Composite index, column order matters.** `(subject_type, subject_id, occurred_at DESC, id DESC)`
  is sorted exactly the way the query filters and orders, so Postgres can jump to the subject and
  read the first 20 entries in order. No sort needed. Reversing the column order would make it
  useless for this query.
- **Trigrams.** A B-tree can only help `LIKE 'abc%'` (a prefix). `'%abc%'` can match anywhere.
  `pg_trgm` splits text into three-character pieces (`"ada"` → `"  a"`, `" ad"`, `"ada"`, `"da "`),
  and a **GIN** index maps each trigram to the rows containing it. A search for `turing 4242`
  intersects the rows of its trigrams. `pg_trgm` ships with Postgres. `CREATE EXTENSION` just
  enables it for this database.

Re-run the three `EXPLAIN ANALYZE` queries:

```text
 Bitmap Heap Scan on contacts  (actual time=0.016..0.021 rows=10.00 loops=1)
   Recheck Cond: (company_id = 4242)
   ->  Bitmap Index Scan on contacts_company_id_idx  (actual time=0.013..0.013 rows=10.00 loops=1)
         Index Cond: (company_id = 4242)
 Execution Time: 0.037 ms
```

```text
 Limit  (actual time=0.302..0.303 rows=1.00 loops=1)
   ->  Sort  (actual time=0.302..0.302 rows=1.00 loops=1)
         ->  Bitmap Heap Scan on contacts  (actual time=0.298..0.299 rows=1.00 loops=1)
               Recheck Cond: ((name ~~* '%turing 4242%'::text) OR (email ~~* '%turing 4242%'::text))
               ->  BitmapOr
                     ->  Bitmap Index Scan on contacts_name_trgm_idx  (actual time=0.258..0.258 rows=1.00 loops=1)
                     ->  Bitmap Index Scan on contacts_email_trgm_idx  (actual time=0.038..0.038 rows=0.00 loops=1)
 Execution Time: 0.335 ms
```

```text
 Limit  (actual time=0.014..0.016 rows=20.00 loops=1)
   ->  Index Scan using activities_subject_idx on activities  (actual time=0.014..0.015 rows=20.00 loops=1)
         Index Cond: ((subject_type = 'deal'::text) AND (subject_id = 30001))
 Execution Time: 0.019 ms
```

4.8 ms → 0.04 ms, 33 ms → 0.3 ms, 5.5 ms → 0.02 ms. The `OR` search uses **two** indexes and
combines them (`BitmapOr`). The activities query has no `Sort` node at all.

> 🟡 **EXPERIMENT**: Postgres DDL is **transactional**, so you can try "what if this index
> didn't exist?" safely:

```sql
BEGIN;
DROP INDEX contacts_name_trgm_idx, contacts_email_trgm_idx;
EXPLAIN ANALYZE SELECT id FROM contacts WHERE name ILIKE '%turing 4242%';
ROLLBACK;   -- the indexes are back, as if nothing happened
```

Then try a *two-letter* search (`'%tu%'`). The planner ignores the trigram index and walks the
primary key instead, because so many rows match that the index wouldn't help. That's why
`/search` will insist on at least 2 characters, and why very short terms are never fast.

## Step 4 — Dynamic filters without SQL injection

Lab 30's `list` used static SQL with `($1::text IS NULL OR ...)`. Every new filter makes every
query longer, and *sorting* by a chosen column needs `CASE` tricks. The tempting shortcut is to
build the SQL string. Do it once, deliberately, to see why you must not.

> 🟡 **EXPERIMENT 1 (never ship this)**: replace the body of `companies::db::list` with:

```rust
    let search = filter.search.clone().unwrap_or_default();
    let sql = format!(
        "SELECT id, name, website, lifecycle FROM companies
         WHERE name ILIKE '%{search}%' ORDER BY id LIMIT {limit} OFFSET {offset}"
    );
    let rows: Vec<CompanyRow> = sqlx::query_as(&sql).fetch_all(pool).await?;
    let companies = rows.into_iter().map(Company::try_from).collect::<Result<Vec<_>, _>>()?;
    let total = companies.len() as i64;
    Ok((companies, total))
```

`sqlx::query_as` (no `!`) is the *runtime* version: no compile-time check, and it needs
`#[derive(sqlx::FromRow)]` on `CompanyRow` to map columns by name. Add that derive (you'll keep
it). Then `cargo check`:

```text
error[E0277]: dynamic SQL strings should be audited for possible injections
   --> src/companies/db.rs:77:48
    |
 77 |     let rows: Vec<CompanyRow> = sqlx::query_as(&sql).fetch_all(pool).await?;
    |                                 -------------- ^^^^ dynamic SQL string
    |                                 |
    |                                 required by a bound introduced by this call
    |
    = help: the trait `SqlSafeStr` is not implemented for `&std::string::String`
    = note: prefer literal SQL strings with bind parameters or `QueryBuilder` to add dynamic data to a query.

            To bypass this error, manually audit for potential injection vulnerabilities and wrap with `AssertSqlSafe()`.
            For details, see the docs for `SqlSafeStr`.

    = note: this trait is only implemented for `&'static str`, not all `&str` like the compiler error may suggest
help: consider dereferencing here
    |
 77 |     let rows: Vec<CompanyRow> = sqlx::query_as(&*sql).fetch_all(pool).await?;
    |                                                 +
```

Since sqlx 0.9, query functions accept `impl SqlSafeStr`, a trait implemented only for
`&'static str` (string literals) and for strings you explicitly wrap in `AssertSqlSafe`. It's a
speed bump against exactly this code. Try the compiler's `&*sql` suggestion anyway:

```text
error[E0597]: `sql` does not live long enough
   --> src/companies/db.rs:77:50
    |
 73 |     let sql = format!(
    |         --- binding `sql` declared here
...
 77 |     let rows: Vec<CompanyRow> = sqlx::query_as(&*sql).fetch_all(pool).await?;
    |                                 -----------------^^^-
    |                                 |                |
    |                                 |                borrowed value does not live long enough
    |                                 argument requires that `sql` is borrowed for `'static`
```

Lifetimes, Lab 10: the trait is implemented for `&'static str`, so a `&str` borrowed from a
local `String` doesn't qualify. A literal lives for the whole program, and a `format!` result
doesn't. The type system is telling apart "SQL the programmer wrote" from "SQL built at runtime".

Now override it: `sqlx::query_as(sqlx::AssertSqlSafe(sql))`. It compiles. Run the server and
attack your own API:

```bash
curl -s -G localhost:3000/companies \
  --data-urlencode "search=nothing' UNION SELECT id, email, NULL, 'prospect' FROM contacts --"
```

```text
{"items":[{"id":1,"name":"grace@navy.test","website":null,"lifecycle":"prospect"},{"id":3,"name":"seed1.c6492ad02579a22e71b164eb28ef5da9@example.test",...
```

Every contact's email, served as "company names". The `'` ended the string literal, `UNION`
appended a second query of the attacker's choosing, and `--` commented out the rest (including
your `LIMIT`). `search='; DROP TABLE contacts; --` fails here only by luck: SQLx sends this as a
prepared statement, and Postgres refuses several statements in one
(`cannot insert multiple commands into a prepared statement`). Don't rely on that.

**Restore your code** (`git checkout src/companies/db.rs`, then re-add `#[derive(sqlx::FromRow)]`).

### `QueryBuilder`: dynamic structure, bound values

The fix isn't escaping quotes. It's never letting data become SQL text. A **bind parameter**
(`$1`) is sent to Postgres *separately* from the SQL. Postgres parses the SQL first and only then
looks at the values, so a value can never change the query's structure. `QueryBuilder` lets you
build the *structure* dynamically while every *value* goes through `push_bind`, which appends `$n`
and stores the value.

> 🟢 **FOLLOW ALONG**: `src/companies/db.rs`
> (`use sqlx::{PgExecutor, PgPool, Postgres, QueryBuilder};`)

```rust
/// Appends ` WHERE ...` for every filter that is set. Values are always
/// bound (`push_bind`), never pasted into the SQL text.
fn push_filters(query: &mut QueryBuilder<Postgres>, filter: &CompanyFilter) {
    let mut keyword = " WHERE ";
    if let Some(lifecycle) = filter.lifecycle {
        query
            .push(keyword)
            .push("lifecycle = ")
            .push_bind(lifecycle.to_string());
        keyword = " AND ";
    }
    if let Some(search) = &filter.search {
        query
            .push(keyword)
            .push("name ILIKE ")
            .push_bind(format!("%{search}%"));
    }
}

/// How many companies match the filter (ignoring pagination).
pub async fn count(db: impl PgExecutor<'_>, filter: &CompanyFilter) -> Result<i64, CrmError> {
    let mut query = QueryBuilder::new("SELECT COUNT(*) FROM companies");
    push_filters(&mut query, filter);
    Ok(query.build_query_scalar().fetch_one(db).await?)
}

/// Returns one page of companies plus the total number that match the filter.
pub async fn list(
    pool: &PgPool,
    filter: &CompanyFilter,
    limit: i64,
    offset: i64,
) -> Result<(Vec<Company>, i64), CrmError> {
    let mut query = QueryBuilder::new("SELECT id, name, website, lifecycle FROM companies");
    push_filters(&mut query, filter);
    query.push(" ORDER BY id LIMIT ").push_bind(limit);
    query.push(" OFFSET ").push_bind(offset);
    let rows: Vec<CompanyRow> = query.build_query_as().fetch_all(pool).await?;

    let total = count(pool, filter).await?;

    let companies = rows
        .into_iter()
        .map(Company::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok((companies, total))
}
```

- **`push` vs `push_bind`.** `push` appends SQL text, and you only ever pass it **string literals
  you wrote**. `push_bind` appends a placeholder. If you ever `push` something derived from input,
  you've rebuilt Experiment 1.
- **`push_filters` is shared** by the page query and the count, so they can't disagree about
  which rows match. That was a real risk with two hand-written SQL strings in Lab 30.
- **`&mut QueryBuilder<Postgres>`**: the builder is mutated in place, and each `push` returns
  `&mut Self` so calls chain.
- **The price.** `QueryBuilder` queries are checked at **runtime**, not compile time: a typo is
  now an HTTP 500, not a build error. Prefer `query!` when the SQL is static, and use `QueryBuilder`
  only for the parts that are truly dynamic. That's why Step 5's search stays a macro.
- `count` is new: `GET /companies/overview` (Step 7) needs it.

Because building SQL is pure, you can **unit-test it without a database**. Add to the bottom of
`src/companies/db.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::companies::Lifecycle;

    #[test]
    fn filters_become_placeholders_not_text() {
        let filter = CompanyFilter {
            lifecycle: Some(Lifecycle::Customer),
            search: Some("x' OR '1'='1".into()),
        };
        let mut query = QueryBuilder::new("SELECT id FROM companies");
        push_filters(&mut query, &filter);
        assert_eq!(
            query.sql().as_str(),
            "SELECT id FROM companies WHERE lifecycle = $1 AND name ILIKE $2"
        );
    }

    #[test]
    fn no_filters_no_where() {
        let mut query = QueryBuilder::new("SELECT id FROM companies");
        push_filters(&mut query, &CompanyFilter::default());
        assert_eq!(query.sql().as_str(), "SELECT id FROM companies");
    }
}
```

The hostile string is nowhere in the SQL. It's just `$2`.

## Step 5 — `GET /search`

> 🟢 **FOLLOW ALONG**: add to `src/companies/db.rs`

```rust
/// Search by name, best matches first (pg_trgm's `similarity`).
pub async fn search(
    db: impl PgExecutor<'_>,
    term: &str,
    limit: i64,
) -> Result<Vec<Company>, CrmError> {
    let rows = sqlx::query_as!(
        CompanyRow,
        "SELECT id, name, website, lifecycle
         FROM companies
         WHERE name ILIKE '%' || $1 || '%'
         ORDER BY similarity(name, $1) DESC, id
         LIMIT $2",
        term,
        limit,
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Company::try_from)
        .collect::<Result<_, _>>()?)
}
```

`'%' || $1 || '%'` builds the pattern **inside Postgres**, from a bound value, so it's still
injection-safe. `similarity(a, b)` (from `pg_trgm`) scores 0–1 by shared trigrams, so "Acme" ranks
above "Acme Analytics 9123" for `acme`. The query is static, so it stays a `query_as!` macro and is
checked at compile time.

> 🔵 **Mini-task**: write `contacts::db::search` (match name **or** email, rank by the better of
> the two similarities, which `greatest(a, b)` gives you) and `deals::db::search` (match `title`),
> with the same signature shape. Solution in `solutions.md`.

> 🟢 **FOLLOW ALONG**: `src/http/search.rs` (add `pub mod search;` and
> `.merge(search::routes())` in `src/http/mod.rs`)

```rust
use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::companies::CompanyResponse;
use super::contacts::ContactResponse;
use super::deals::DealResponse;
use super::extract::AppQuery;
use super::{ApiError, AppState, FieldError};
use crate::{companies, contacts, deals};

pub fn routes() -> Router<AppState> {
    Router::new().route("/search", get(search))
}

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    #[serde(default = "default_limit")]
    pub limit: u32,
}

fn default_limit() -> u32 {
    10
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub companies: Vec<CompanyResponse>,
    pub contacts: Vec<ContactResponse>,
    pub deals: Vec<DealResponse>,
}

async fn search(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<SearchQuery>,
) -> Result<Json<SearchResponse>, ApiError> {
    let term = q.q.trim();
    if term.chars().count() < 2 {
        return Err(ApiError::Validation(vec![FieldError {
            field: "q",
            message: "must be at least 2 characters".into(),
        }]));
    }
    let limit = i64::from(q.limit.clamp(1, 50));

    // Three independent queries, run concurrently on three pooled connections.
    let (companies, contacts, deals) = tokio::try_join!(
        companies::db::search(&state.pool, term, limit),
        contacts::db::search(&state.pool, term, limit),
        deals::db::search(&state.pool, term, limit),
    )?;

    Ok(Json(SearchResponse {
        companies: companies.iter().map(CompanyResponse::from).collect(),
        contacts: contacts.iter().map(ContactResponse::from).collect(),
        deals: deals.iter().map(DealResponse::from).collect(),
    }))
}
```

**`tokio::try_join!`** polls the three futures *concurrently* (Lab 26: futures do nothing until
polled, and `join` polls several at once). Each takes its own connection from the pool, so the
three queries run in parallel in Postgres, and the response takes about as long as the *slowest*
one, not the sum. `try_` means the first `Err` cancels the others and is returned. Here `&PgPool`
being an executor that can be used concurrently pays off. With a single `&mut PgConnection` you
couldn't do this, which is the borrow checker's "one `&mut` at a time" again.

`term.chars().count()` counts characters, not bytes (Lab 09): `"zö"` is two characters, three bytes.

**Full-text search** (`tsvector`, `to_tsquery`, ranking, stemming "meetings" → "meet") is
Postgres's other search tool, better for prose (notes bodies) than for names and emails. It's an
optional extension task below.

## Step 6 — Offset vs keyset pagination

`?page=500&per_page=20` becomes `OFFSET 9980 LIMIT 20`. Postgres can't jump to row 9,980. It
produces and **discards** 9,980 rows first. Compare a deep page of the hot deal's activities:

```sql
EXPLAIN ANALYZE SELECT id, summary, occurred_at FROM activities
WHERE subject_type = 'deal' AND subject_id = 30001
ORDER BY occurred_at DESC, id DESC LIMIT 20 OFFSET 4980;
```

```text
 Limit  (actual time=1.046..1.048 rows=20.00 loops=1)
   Buffers: shared hit=132
   ->  Sort  (actual time=0.850..0.951 rows=5000.00 loops=1)
         Sort Method: quicksort  Memory: 544kB
         ->  Bitmap Heap Scan on activities  (actual time=0.123..0.509 rows=5003.00 loops=1)
```

with the **keyset** version ("rows *after* the last one I saw"):

```sql
EXPLAIN ANALYZE SELECT id, summary, occurred_at FROM activities
WHERE subject_type = 'deal' AND subject_id = 30001
  AND (occurred_at, id) < ((SELECT occurred_at FROM activities WHERE id = 4980), 4980)
ORDER BY occurred_at DESC, id DESC LIMIT 20;
```

```text
 Limit  (actual time=0.009..0.011 rows=20.00 loops=1)
   Buffers: shared hit=8
   ->  Index Scan using activities_subject_idx on activities  (actual time=0.008..0.010 rows=20.00 loops=1)
         Index Cond: ((subject_type = 'deal'::text) AND (subject_id = 30001) AND (ROW(occurred_at, id) < ROW((InitPlan 1).col1, 4980)))
```

132 buffers and a 5,000-row sort vs 8 buffers. Keyset cost doesn't grow with depth. There's also a
**correctness** difference: if a new activity is logged while a user pages with offsets, every row
shifts by one, and page 2 repeats the last item of page 1. A keyset continues from a *position*
and never repeats or skips.

| | Offset (`page`, `per_page`) | Keyset (`cursor`) |
|---|---|---|
| Jump to page 37 | ✅ | ❌ only "next" |
| Total count / page numbers | ✅ | ❌ (would cost a `COUNT`) |
| Cost of deep pages | grows with offset | constant |
| Stable under inserts | ❌ duplicates / skips | ✅ |
| Good for | admin tables (`/companies`, `/contacts`) | feeds (`/activities`, `/history`) |

So `/companies` and `/contacts` keep `Pagination`, and the time-ordered feeds switch to keyset.

**The `(occurred_at, id)` pair.** Timestamps aren't unique, and seeded or imported data has many
ties. The order needs a **unique** tiebreaker, so the position is the pair. `(a, b) < (x, y)` is a
row-value comparison ("a < x, or a = x and b < y"), and it matches the index's column order, which
is why the plan shows it as an `Index Cond`.

> 🟢 **FOLLOW ALONG**: `cargo add base64` (written against base64 0.23). In
> `src/http/pagination.rs` (with `use base64::Engine as _;`,
> `use base64::engine::general_purpose::URL_SAFE_NO_PAD;`,
> `use chrono::{DateTime, SecondsFormat, Utc};` and `use super::{ApiError, FieldError};`):

```rust
/// Keyset position: "the last item you saw was at `at` with id `id`".
/// Clients treat the encoded form as an opaque token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub at: DateTime<Utc>,
    pub id: i64,
}

impl Cursor {
    pub fn encode(&self) -> String {
        let raw = format!(
            "{}|{}",
            self.at.to_rfc3339_opts(SecondsFormat::Micros, true),
            self.id
        );
        URL_SAFE_NO_PAD.encode(raw)
    }

    pub fn decode(token: &str) -> Option<Cursor> {
        let bytes = URL_SAFE_NO_PAD.decode(token).ok()?;
        let raw = String::from_utf8(bytes).ok()?;
        let (at, id) = raw.split_once('|')?;
        Some(Cursor {
            at: DateTime::parse_from_rfc3339(at).ok()?.with_timezone(&Utc),
            id: id.parse().ok()?,
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct CursorQuery {
    pub cursor: Option<String>,
    pub limit: u32,
}

impl Default for CursorQuery {
    fn default() -> Self {
        CursorQuery {
            cursor: None,
            limit: 20,
        }
    }
}

impl CursorQuery {
    pub fn limit(&self) -> i64 {
        i64::from(self.limit.clamp(1, 100))
    }

    /// `None` = first page. A malformed token is the client's mistake: 422.
    pub fn cursor(&self) -> Result<Option<Cursor>, ApiError> {
        match &self.cursor {
            None => Ok(None),
            Some(token) => Cursor::decode(token).map(Some).ok_or_else(|| {
                ApiError::Validation(vec![FieldError {
                    field: "cursor",
                    message: "invalid cursor".into(),
                }])
            }),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct CursorPage<T> {
    pub items: Vec<T>,
    pub next_cursor: Option<String>,
}
```

- **Why encode?** An opaque token tells clients "don't construct or edit this". You're then free
  to change what's inside (add a field, switch format) without breaking anyone who follows the
  rules. URL-safe base64 without padding avoids `+`, `/` and `=` in query strings.
- **Microseconds.** Postgres stores `TIMESTAMPTZ` with microsecond precision. Serialising the
  cursor with fewer digits would make `(at, id) <` skip or repeat rows at the boundary.
  `SecondsFormat::Micros` keeps exactly what the database has.
- **`decode` returns `Option`** and uses `?` on every `Option`/`ok()` step (Lab 12). Any failure
  means "not a cursor", and the HTTP layer makes that a 422.

Write two unit tests for `Cursor` in that file: one that round-trips a timestamp **with
microseconds**, and one that checks `"not base64!"` and a base64 string without a `|` both decode
to `None`.

> 🟢 **FOLLOW ALONG**: `src/activities/db.rs`. Two static queries instead of one with
> `$3 IS NULL OR`, so each one is plain enough for the planner to use the index directly.

```rust
/// One keyset page, newest first. `before` is the (occurred_at, id) of the
/// last activity the client already has; `None` means "start at the top".
pub async fn page_for_subject(
    db: impl PgExecutor<'_>,
    subject: Subject,
    before: Option<(DateTime<Utc>, i64)>,
    limit: i64,
) -> Result<Vec<Activity>, CrmError> {
    let rows = match before {
        None => {
            sqlx::query_as!(
                ActivityRow,
                r#"SELECT id, subject_type, subject_id,
                          details AS "details: Json<ActivityKind>", summary, occurred_at
                   FROM activities
                   WHERE subject_type = $1 AND subject_id = $2
                   ORDER BY occurred_at DESC, id DESC
                   LIMIT $3"#,
                subject.kind(),
                subject.id(),
                limit,
            )
            .fetch_all(db)
            .await?
        }
        Some((at, id)) => {
            sqlx::query_as!(
                ActivityRow,
                r#"SELECT id, subject_type, subject_id,
                          details AS "details: Json<ActivityKind>", summary, occurred_at
                   FROM activities
                   WHERE subject_type = $1 AND subject_id = $2
                     AND (occurred_at, id) < ($3, $4)
                   ORDER BY occurred_at DESC, id DESC
                   LIMIT $5"#,
                subject.kind(),
                subject.id(),
                at,
                id,
                limit,
            )
            .fetch_all(db)
            .await?
        }
    };
    Ok(rows
        .into_iter()
        .map(Activity::try_from)
        .collect::<Result<_, _>>()?)
}
```

The repository takes a plain `(DateTime<Utc>, i64)`, not `Cursor`. Encoding is an HTTP concern,
and `activities::db` shouldn't depend on `crate::http`.

And the handler in `src/http/activities.rs`:

```rust
async fn list_activities(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<SubjectQuery>,
    AppQuery(page): AppQuery<CursorQuery>,
) -> Result<Json<CursorPage<ActivityResponse>>, ApiError> {
    let subject = q.parse()?;
    let before = page.cursor()?.map(|c| (c.at, c.id));
    let limit = page.limit();

    // Ask for one extra row: if it exists, there is a next page.
    let mut activities =
        activities::db::page_for_subject(&state.pool, subject, before, limit + 1).await?;
    let next_cursor = if activities.len() as i64 > limit {
        activities.truncate(limit as usize);
        activities.last().map(|a| {
            Cursor {
                at: a.occurred_at,
                id: a.id.0,
            }
            .encode()
        })
    } else {
        None
    };
    let items = activities.iter().map(ActivityResponse::from).collect();
    Ok(Json(CursorPage { items, next_cursor }))
}
```

**The `limit + 1` trick**: ask for one more row than the page size. If it arrives there's a next
page, and you drop it before responding. It costs one extra row instead of a `COUNT`.

**This changes the `/activities` response shape** from a JSON array to
`{ "items": [...], "next_cursor": ... }`. That's a breaking change for clients. Since you have
none, just update any test that reads `/activities` to use `body["items"]`. In a public API you'd version it
(`/v2/activities`) or design the envelope in from the start, which is a good reason to always
return an object, never a bare array.

## Step 7 — The N+1 query

A dashboard wants companies with their contact counts. The natural first version reuses what
exists.

> 🟡 **EXPERIMENT**: add this to `src/http/companies.rs` with the route
> `.route("/companies/overview", get(overview))`:

```rust
#[derive(Debug, Serialize)]
pub struct CompanyOverviewResponse {
    #[serde(flatten)]
    pub company: CompanyResponse,
    pub contact_count: i64,
}

/// N+1 on purpose: 1 query for the page + 1 per company.
async fn overview(
    State(state): State<AppState>,
    AppQuery(p): AppQuery<Pagination>,
) -> Result<Json<Page<CompanyOverviewResponse>>, ApiError> {
    let p = p.normalized();
    let (companies, total) =
        companies::db::list(&state.pool, &CompanyFilter::default(), p.limit(), p.offset()).await?;
    let mut items = Vec::new();
    for company in &companies {
        let contacts = contacts::db::list_for_company(&state.pool, company.id).await?;
        items.push(CompanyOverviewResponse {
            company: CompanyResponse::from(company),
            contact_count: contacts.len() as i64,
        });
    }
    Ok(Json(Page { items, page: p.page, per_page: p.per_page, total }))
}
```

`/companies/overview` and `/companies/{id}` both match that URL. axum's router prefers the static
segment, so this works. Then measure:

```bash
for i in 1 2 3; do curl -s -o /dev/null -w "%{time_total}s\n" "localhost:3000/companies/overview?per_page=100"; done
```

```text
0.038954s
0.018023s
0.014131s
```

For 100 companies that's **102 queries** (page + count + one per company), each a network round
trip, each fetching whole contact rows only to count them. On localhost it's ~15 ms. With a
database 1 ms away over a network it's at least 100 ms, and it grows with `per_page`. That's
**N+1**: one query for the list, plus N for the details.

> 🟢 **FOLLOW ALONG**: one query instead, in `src/companies/db.rs`

```rust
/// A company plus aggregate numbers about it.
#[derive(Debug, Clone, PartialEq)]
pub struct CompanyOverview {
    pub company: Company,
    pub contact_count: i64,
}

struct OverviewRow {
    id: i64,
    name: String,
    website: Option<String>,
    lifecycle: String,
    contact_count: i64,
}

/// One query for the whole page, however many companies it has.
pub async fn overview(
    db: impl PgExecutor<'_>,
    limit: i64,
    offset: i64,
) -> Result<Vec<CompanyOverview>, CrmError> {
    let rows = sqlx::query_as!(
        OverviewRow,
        r#"SELECT c.id, c.name, c.website, c.lifecycle,
                  COUNT(ct.id) AS "contact_count!"
           FROM companies c
           LEFT JOIN contacts ct ON ct.company_id = c.id
           GROUP BY c.id
           ORDER BY c.id
           LIMIT $1 OFFSET $2"#,
        limit,
        offset,
    )
    .fetch_all(db)
    .await?;
    rows.into_iter()
        .map(|row| {
            let company = Company::try_from(CompanyRow {
                id: row.id,
                name: row.name,
                website: row.website,
                lifecycle: row.lifecycle,
            })?;
            Ok(CompanyOverview { company, contact_count: row.contact_count })
        })
        .collect()
}
```

and the handler becomes:

```rust
async fn overview(
    State(state): State<AppState>,
    AppQuery(p): AppQuery<Pagination>,
) -> Result<Json<Page<CompanyOverviewResponse>>, ApiError> {
    let p = p.normalized();
    let rows = companies::db::overview(&state.pool, p.limit(), p.offset()).await?;
    let total = companies::db::count(&state.pool, &CompanyFilter::default()).await?;
    let items = rows
        .iter()
        .map(|row| CompanyOverviewResponse {
            company: CompanyResponse::from(&row.company),
            contact_count: row.contact_count,
        })
        .collect();
    Ok(Json(Page { items, page: p.page, per_page: p.per_page, total }))
}
```

```text
0.005539s
0.002051s
0.002128s
```

- **`LEFT JOIN`**, not `JOIN`: a company with no contacts must still appear (with 0). `COUNT(ct.id)`
  counts non-NULL contact ids, so it's 0 for those companies. `COUNT(*)` would count the NULL-padded
  row and say 1.
- **`GROUP BY c.id` while selecting `c.name`**: allowed because `id` is the primary key. Postgres
  knows every other column of `c` is determined by it ("functional dependency").
- **`.collect()` into `Result<Vec<_>, CrmError>`**: the closure returns
  `Result<CompanyOverview, CrmError>`, and the `?` inside converts `sqlx::Error` into `CrmError`
  via `From`.
- `#[serde(flatten)]` inlines `CompanyResponse`'s fields into the overview object rather than
  nesting them.

## Step 8 — The pipeline report in SQL

Lab 31's `/pipeline` loads **every deal** into Rust and folds them. With 30,000 deals:

```bash
for i in 1 2 3; do curl -s -o /dev/null -w "%{time_total}s\n" localhost:3000/pipeline; done
```

```text
0.101078s
0.095697s
0.099943s
```

(Debug build. Release is faster, but the ratio holds.) The answer is 5 rows. Let the database
aggregate where the data is.

> 🟢 **FOLLOW ALONG**: add to `src/deals/db.rs` (import `PipelineRow`):

```rust
/// The pipeline report, aggregated by Postgres: 5 rows cross the wire
/// instead of every deal.
pub async fn pipeline(db: impl PgExecutor<'_>) -> Result<Vec<PipelineRow>, CrmError> {
    let rows = sqlx::query!(
        r#"SELECT stage, COUNT(*) AS "count!", SUM(value_cents) AS "total_cents!"
           FROM deals
           GROUP BY stage"#
    )
    .fetch_all(db)
    .await?;

    // GROUP BY only returns stages that have deals; the report shows all five.
    let mut report: Vec<PipelineRow> = DealStage::ALL
        .into_iter()
        .map(|stage| PipelineRow { stage, count: 0, total: Money::default() })
        .collect();
    for row in rows {
        let stage: DealStage = row.stage.parse().map_err(corrupt)?;
        let slot = report
            .iter_mut()
            .find(|r| r.stage == stage)
            .expect("DealStage::ALL lists every stage");
        slot.count = usize::try_from(row.count).map_err(corrupt)?;
        slot.total = Money::from_cents(row.total_cents);
    }
    Ok(report)
}
```

`cargo check`:

```text
error: SQLx feature `bigdecimal` required for type NUMERIC of column #3 ("total_cents!")
   --> src/deals/db.rs:140:16
    |
140 |       let rows = sqlx::query!(
    |  ________________^
141 | |         r#"SELECT stage, COUNT(*) AS "count!", SUM(value_cents) AS "total_cents!"
```

The macro just told you something about Postgres: `SUM` over `BIGINT` returns **`NUMERIC`**
(arbitrary precision), so the sum of many big values can't overflow. Rust's `i64` can't hold
every `NUMERIC`. Your sums fit comfortably, so say so explicitly: `SUM(value_cents)::bigint`. If a
sum ever exceeded `i64::MAX`, the cast would fail loudly in Postgres instead of wrapping silently.

Point the handler at it: `let rows = deals::db::pipeline(&state.pool).await?;`

```text
0.004970s
0.003477s
0.003417s
```

Same JSON, ~30× faster here, and the gap grows with the table. Look at Postgres's side:

```text
 HashAggregate  (actual time=3.400..3.401 rows=5.00 loops=1)
   Group Key: stage
   ->  Seq Scan on deals  (actual time=0.004..0.872 rows=30001.00 loops=1)
```

It still reads every deal. Aggregation is a full scan either way. What changed is that 30,000
rows no longer cross the network, get decoded, validated and turned into `Deal`s.

**Keep `deals::pipeline_report`.** The Rust version is now the *specification*: obviously correct,
unit-tested, with no database. Lab 33 has a test asserting the SQL version returns exactly what
the Rust version computes over the same deals. Two implementations that must agree is a cheap,
strong test.

| Aggregate in SQL when… | Aggregate in Rust when… |
|---|---|
| input is large and output small | data is already in memory |
| it's a standard aggregate (`COUNT`, `SUM`, `GROUP BY`) | logic is intricate or domain-heavy |
| you'd otherwise ship rows just to summarise them | you want it unit-testable without a DB |

---

## ▶️ Run It
```bash
cargo sqlx prepare
cargo run
```

```bash
curl -s 'localhost:3000/search?q=hopper%2073&limit=2'
curl -s 'localhost:3000/search?q=pilot&limit=3'
curl -s -i 'localhost:3000/search?q=a'
curl -s 'localhost:3000/activities?subject=deal:30001&limit=2'
curl -s 'localhost:3000/activities?subject=deal:30001&limit=2&cursor=<next_cursor from above>'
curl -s -i 'localhost:3000/activities?subject=deal:30001&cursor=nope'
curl -s 'localhost:3000/companies/overview?per_page=2'
curl -s 'localhost:3000/companies?lifecycle=customer&search=hooli&per_page=1'
```

## ✅ Expected Result
Ids, emails and timestamps depend on your seed run. The shapes:

```text
{"companies":[],"contacts":[{"id":75,"name":"Grace Hopper 73","email":"seed73.7f1370e082fd2690f1ca6a7b11037d90@example.test","phone":null,"company_id":77},{"id":7306,"name":"Ada Hopper 7304","email":"seed7304.b2aa9a5fafc5c096ceb41e4d4d550ac7@example.test","phone":null,"company_id":7308}],"deals":[]}

{"companies":[],"contacts":[],"deals":[{"id":1,"company_id":1,"title":"Compiler pilot","value_cents":2500000,"stage":"proposal"}]}

HTTP/1.1 422 Unprocessable Entity
{"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"q","message":"must be at least 2 characters"}]}}

{"items":[{"id":2,"subject":"deal:30001","kind":{"type":"call","minutes":6},"summary":"Seeded call 1","occurred_at":"2026-10-05T14:43:12.885315Z"},{"id":3,"subject":"deal:30001","kind":{"type":"call","minutes":7},"summary":"Seeded call 2","occurred_at":"2026-10-05T14:42:12.885315Z"}],"next_cursor":"MjAyNi0xMC0wNVQxNDo0MjoxMi44ODUzMTVafDM"}

{"items":[{"id":4,"subject":"deal:30001",...,"summary":"Seeded call 3",...},{"id":5,...,"summary":"Seeded call 4",...}],"next_cursor":"MjAyNi0xMC0wNVQxNDo0MDoxMi44ODUzMTVafDU"}

HTTP/1.1 422 Unprocessable Entity
{"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"cursor","message":"invalid cursor"}]}}

{"items":[{"id":1,"name":"US Navy","website":null,"lifecycle":"prospect","contact_count":1},{"id":3,"name":"Initech","website":null,"lifecycle":"prospect","contact_count":0}],"page":1,"per_page":2,"total":10002}

{"items":[{"id":...,"name":"Hooli ... ","website":"https://company....test","lifecycle":"customer"}],"page":1,"per_page":1,"total":...}
```

Decode a cursor to see it's not magic:
`echo MjAyNi0xMC0wNVQxNDo0MjoxMi44ODUzMTVafDM | base64 -d` prints
`2026-10-05T14:42:12.885315Z|3` (it may complain about missing padding; that's the "no pad" part).

## 🧠 Understand It

**Three ways to put a value into SQL, ranked.**
1. `query!` with `$1`: static SQL, bound values, checked at compile time. The default.
2. `QueryBuilder` with `push_bind`: dynamic *structure*, bound values, checked at runtime. Use it
   for optional filters, dynamic `ORDER BY` from a whitelist, and `IN (...)` lists.
3. `format!` + `AssertSqlSafe`: dynamic everything. Only for things that can't be parameters
   (identifiers you control), and only after an audit. Never with user input.

**The planner decides, you inform it.** You never told Postgres to use an index. You created it,
and the planner chose it when the statistics said it was cheaper. That's why `ANALYZE` (statistics)
and `EXPLAIN ANALYZE` (evidence) matter more than intuition.

**Pagination is an API design decision.** Offset gives page numbers and totals. Keyset gives
stability and constant cost. You chose per endpoint, based on how each is used.

**Concurrency inside a request.** `try_join!` runs three queries at once because each borrows the
pool *shared* (`&PgPool`) and gets its own connection. A transaction (`&mut *tx`) is one connection
and can only run one statement at a time. That's ownership, not a SQLx limitation.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: search for `100%`. What comes back, and why? (`%` is a wildcard inside
> `ILIKE`.) How would you escape `%`, `_` and `\` in `term` before binding it, and which tests
> would you write?

> 🟡 **EXPERIMENT 2**: page through the hot deal with `limit=100` while, in another terminal,
> you `POST /activities` for that deal with the current time. Do you see duplicates? Now try the
> same with an offset-paginated endpoint (`/companies?page=` while creating companies with low
> sort keys). Explain the difference.

> 🟡 **EXPERIMENT 3**: in psql, `EXPLAIN ANALYZE` the overview SQL with `LIMIT 100` and with
> `LIMIT 1000`. Where does the time go? Then call the API with `per_page=1000`. What does it
> return, and why is that a good thing?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `contacts::db::list` with `QueryBuilder`.** Replace Lab 30's
> `CASE`-based static query. Same signature, same behaviour.

- [ ] a private `push_filters(query: &mut QueryBuilder<Postgres>, filter: &ContactFilter)` shared
      by the page query and the count; `company` is bound **as a `CompanyId`** (no `.0`; the
      `sqlx::Type` derive from Lab 30 makes this work)
- [ ] search matches name **or** email. Watch the operator precedence of `AND` / `OR` when the
      company filter is also set
- [ ] sorting comes from a `fn order_by(sort: ContactSort) -> &'static str` that returns one of
      three literal `ORDER BY` clauses, each ending with a unique tiebreaker
- [ ] a unit test (no database) asserting the exact SQL for company + search + email sort is
      `SELECT id FROM contacts WHERE company_id = $1 AND (name ILIKE $2 OR email ILIKE $3) ORDER BY email, id`
- [ ] `GET /contacts?company_id=..&search=..&sort=name` behaves exactly as in Lab 30

> 🔵 **YOUR TURN 2: keyset pagination for `/history`.** Activities and notes come from two tables,
> and their ids can collide (activity #5 and note #5), so `(at, id)` is **not** a unique position
> in the merged stream.

- [ ] in `src/history.rs`: `pub struct HistoryPosition { pub at: DateTime<Utc>, pub item_type: String, pub id: i64 }`,
      `pub struct HistoryEntry { pub item_type: String, pub id: i64, pub at: DateTime<Utc>, pub text: String }`
      and `pub async fn page(db: impl PgExecutor<'_>, subject: Subject, before: Option<&HistoryPosition>, limit: i64) -> Result<Vec<HistoryEntry>, CrmError>`
- [ ] Postgres merges the two tables (`UNION ALL`) and orders by `at DESC, item_type DESC, id DESC`.
      The cursor compares all three
- [ ] the HTTP layer encodes/decodes the position as base64 of `"at|item_type|id"`, rejecting
      unknown types with 422 (`field: "cursor"`)
- [ ] `GET /history?subject=&limit=&cursor=` returns `{ items, next_cursor }`. Each item becomes
      `{"type":"note","id":1,"at":"...","text":"..."}`: Lab 29's `HistoryItemResponse` wrapped the
      whole activity or note, but a `UNION ALL` only returns the columns both tables share. Like
      `/activities` in Step 6, that's a breaking change you'd version in a public API
- [ ] proof: create an activity whose `occurred_at` equals a note's `created_at` exactly (psql
      helps), page with `limit=1`, and every item appears exactly once
- [ ] decide what happens to Lab 31's `history::merge` and explain why in your commit message

> 🔵 **YOUR TURN 3: more numbers in the overview.** Add `open_deal_count` (deals not `won`/`lost`)
> to `GET /companies/overview`, still in **one** query.

- [ ] `CompanyOverview` and the response gain `open_deal_count: i64`
- [ ] for a seeded company with 10 contacts and 3 open deals, the API says 10 and 3. Find one with
      `select company_id, array_agg(stage) from deals group by 1 limit 10;`
- [ ] explain, in a code comment, why adding `LEFT JOIN deals` to the existing query gives wrong
      numbers

> 🔵 **OPTIONAL: full-text search on notes.** Add `GET /notes/search?q=`, using
> `to_tsvector('english', body) @@ websearch_to_tsquery('english', $1)`, a GIN index on the
> expression, and `ts_rank` ordering. Compare it with `ILIKE` for "meeting" vs "meetings".

Finally: `cargo sqlx prepare`, `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test`.

## 💡 Hint
> 💡 **HINT**: Your Turn 1: `(name ILIKE $2 OR email ILIKE $3)` needs its parentheses, because
> `AND` binds tighter than `OR`. Your Turn 3: count what `LEFT JOIN contacts LEFT JOIN deals`
> produces for one company with 10 contacts and 3 deals *before* grouping.

<details><summary>Hint 2 (more specific)</summary>

- Your Turn 1: bind the search pattern twice (`pattern.clone()`, then `pattern`). Each
  `push_bind` creates a new placeholder.
- Your Turn 2: the inner query is
  `SELECT 'activity' AS item_type, id, occurred_at AS at, summary AS text FROM activities WHERE ... UNION ALL SELECT 'note', id, created_at, body FROM notes WHERE ...`.
  Wrap it in `SELECT ... FROM ( ... ) AS history WHERE ($3::timestamptz IS NULL OR (at, item_type, id) < ($3, $4, $5))`.
  The macro can't infer nullability through a `UNION`, so alias the outer columns with `!`
  (`item_type AS "item_type!"`). `query_as!` can then fill `HistoryEntry` directly.
- Your Turn 3: a join multiplies rows: 10 contacts × 3 deals = 30 rows for that company. Either
  count `DISTINCT` ids, or (simpler and cheaper here) use two scalar subqueries in the `SELECT`
  list, each answered by an index from Step 3.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why can a bind parameter never change the structure of a query, while `format!` can?
2. What does `SqlSafeStr` accept, and how does it use the `'static` lifetime to tell
   "written by the programmer" apart from "built at runtime"?
3. Why doesn't Postgres index `contacts.company_id` by itself? What does
   `(subject_type, subject_id, occurred_at DESC, id DESC)` serve that `(occurred_at)` wouldn't?
4. Give two reasons keyset beats offset for an activity feed, and one thing offset can do that
   keyset can't.
5. What is the N+1 problem, and what did you replace it with?
6. When would you keep an aggregation in Rust even though SQL could do it?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
(and `SQLX_OFFLINE=true cargo check`).

## Git Commit
```bash
git add .
git commit -m "Add SQL search, filtering and pagination"
git tag lab-32
git push && git push --tags
```

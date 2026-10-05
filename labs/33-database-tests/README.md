# Lab 33 — Database Integration Tests

> **Phase:** 9 — PostgreSQL · **Builds on:** Lab 32 · **Time:** ~5 hours
> **Your repo before this lab:** tag `lab-32` · **After:** tag `lab-33`

This lab assumes you completed Lab 32's Your Turn 1 (`contacts::db::list` with `QueryBuilder`) and
the `/search` mini-task. Your Turns 2–3 aren't required. If you skipped Lab 32's `/history` keyset
task, your history endpoint simply returns the Lab 31 shape. See Lab 32's `solutions.md` if
needed.

## 🎯 Goal
Bring back every test you `#[ignore]`d in Labs 30–31, against a **real, fresh Postgres database
per test**. Add repository-level tests for constraint errors and transaction rollback, and run all
of it in GitHub Actions with a Postgres service and an up-to-date `.sqlx/` check.

## 🧠 What You'll Learn
- `#[sqlx::test]`: a new database per test, migrations applied automatically, cleaned up after
- Fixtures: SQL files that put known rows in place (`fixtures(path = ..., scripts(...))`)
- Choosing ids in fixtures for `GENERATED ALWAYS` columns, and fixing the sequence afterwards
- Testing **failure**: constraint violations as domain errors, and proving a rollback happened
- Two integration-test binaries (`tests/api/`, `tests/db/`) and what each layer is for
- Debugging a failed test by opening the database it left behind
- CI: a Postgres service container, `SQLX_OFFLINE`, and `cargo sqlx prepare --check`

## 🔨 What We're Building
```text
tests/
├── api/                    HTTP in, JSON out, through the real router
│   ├── main.rs             mod activities; mod companies; mod contacts; mod deals; mod helpers; mod leads;
│   ├── helpers.rs          app(pool) -> Router, send(...), get/post/post_json/put_json/delete, ...
│   └── companies.rs, contacts.rs, deals.rs, leads.rs, activities.rs
├── db/                     repository and service functions, no HTTP
│   ├── main.rs             mod companies; mod contacts; mod deals; mod leads;
│   └── companies.rs, contacts.rs, deals.rs, leads.rs
├── fixtures/               companies.sql, contacts.sql, deals.sql, leads.sql
└── validation.rs           (from Lab 24, unchanged)
.github/workflows/ci.yml    Postgres service + offline build + cache check + tests
```

No new production code. This lab is about **evidence**: after it, a green CI run means the
SQL, the constraints, the transactions and the HTTP layer work together on a real Postgres.

---

## Step 1 — `#[sqlx::test]`: a database per test

Why not just point the tests at your dev database? Because tests then share state: one test's
company appears in another test's `GET /companies`, results depend on the order tests run in (and
`cargo test` runs them **in parallel**), and leftover rows from a crashed run break the next one.
You need **isolation**.

`#[sqlx::test]` provides it. For each test function that takes a `PgPool`, it:

1. connects to `DATABASE_URL` (from the environment or `.env`) as a user that can create databases,
2. creates a brand-new database with a random name (`_sqlx_test_...`),
3. applies every migration in `./migrations` (because the `migrate` feature is on),
4. applies the fixtures you name, if any,
5. passes your test a pool connected to that database,
6. drops the database if the test passed, and **keeps it** if it failed, for debugging.

The Docker `crm` user is a superuser (Lab 30, Step 3), so step 1 just works locally.

> 🟢 **FOLLOW ALONG**: `tests/api/helpers.rs`. The lazy-pool `app()` from Labs 30–31 becomes:

```rust
use sqlx::PgPool;

/// Every test gets its own freshly migrated database from #[sqlx::test];
/// we just wrap its pool in the real router.
pub fn app(pool: PgPool) -> Router {
    router(AppState { pool })
}
```

Remove the `PgPoolOptions` import. Every other helper (`send`, `get`, `post`, `post_json`,
`put_json`, `delete`, `create_company`, `error_code`) stays as it is.

Now restore one test. In `tests/api/contacts.rs`:

```rust
use axum::http::StatusCode;
use serde_json::json;
use sqlx::PgPool;

use crate::helpers::{app, post_json, send};

#[sqlx::test]
async fn duplicate_email_is_409(pool: PgPool) {
    let app = app(pool);
    let body = json!({ "name": "Ada", "email": "ada@example.com" });
    send(&app, post_json("/contacts", body.clone())).await;
    let (status, body) = send(&app, post_json("/contacts", body)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"]["code"], "conflict");
}
```

Three changes: `#[tokio::test]` → `#[sqlx::test]`, the `#[ignore]` line is gone, and the function
takes `pool: PgPool`, which the macro supplies. `#[sqlx::test]` also sets up the Tokio runtime, so
you don't need both attributes.

```bash
docker compose up -d
cargo test --test api duplicate_email
```

```text
running 1 test
test contacts::duplicate_email_is_409 ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 13 filtered out; finished in 0.21s
```

A whole database was created, migrated, used and dropped in a fraction of a second. Postgres
creates databases by copying a template, and your migrations are small.

> 🔵 **Mini-task**: convert **every** API test the same way: remove each `#[ignore = "needs database; restored in Lab 33"]`,
> switch to `#[sqlx::test]`, add `pool: PgPool`, and call `app(pool)`. Then:

```bash
grep -rn "ignore" tests/    # should print nothing
cargo test
```

Tests that fail now are telling you something real: they haven't run since Lab 30, and Labs 31–32
changed things (for example, `/activities` now returns `{ items, next_cursor }`). Decide each time
whether the test or the code is wrong. Usually it's the test's expectation that is out of date.

> ⚠️ **If every DB test fails after ~30 seconds** with
> `failed to connect to setup test database: PoolTimedOut`, Postgres isn't reachable.
> Is `docker compose up -d` running, and does `.env` have the right `DATABASE_URL`?

## Step 2 — Fixtures: known data, by name

Many tests need existing rows: "a company with contacts can't be deleted" needs a company and
contacts. Creating them through the API in every test is slow to write and hides what the test is
about. A **fixture** is a SQL file that runs after migrations, before your test.

> 🟢 **FOLLOW ALONG**: `tests/fixtures/companies.sql`

```sql
-- Two companies with known ids. OVERRIDING SYSTEM VALUE lets us choose ids for
-- a GENERATED ALWAYS column; setval moves the sequence past them so the next
-- INSERT made by a test doesn't collide with id 1 or 2.
INSERT INTO companies (id, name, website, lifecycle) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Acme Corp', 'https://acme.test', 'customer'),
    (2, 'Globex', NULL, 'prospect');

SELECT setval(pg_get_serial_sequence('companies', 'id'), (SELECT max(id) FROM companies));
```

- **Why choose ids?** So tests can say `DELETE /companies/1` and mean "Acme". In a fresh database
  generated ids would *probably* be 1 and 2 as well, but "probably" is a bad thing to build tests on.
- **`OVERRIDING SYSTEM VALUE`.** `GENERATED ALWAYS` (Lab 30) refuses explicit ids unless you say
  so. That's the point of `ALWAYS`: application code can't fake ids by accident.
- **`setval`.** The identity sequence doesn't know you used 1 and 2. Without this line, the first
  `POST /companies` in a test would get id 1 and fail with a primary-key violation.

> 🟢 **FOLLOW ALONG**: `tests/fixtures/contacts.sql` (needs `companies` first) and
> `tests/fixtures/leads.sql`

```sql
-- Needs the "companies" fixture first.
INSERT INTO contacts (id, name, email, phone, company_id) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Ada Lovelace', 'ada@acme.test', '555-0100', 1),
    (2, 'Bob Byte', 'bob@acme.test', NULL, 1),
    (3, 'Cy Globex', 'cy@globex.test', NULL, 2);

SELECT setval(pg_get_serial_sequence('contacts', 'id'), (SELECT max(id) FROM contacts));
```

```sql
INSERT INTO leads (id, name, email, company_name, source, status) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Dee Initech', 'dee@initech.test', 'Initech', 'referral', 'qualified'),
    (2, 'Eve New', 'eve@new.test', NULL, 'website', 'new');

SELECT setval(pg_get_serial_sequence('leads', 'id'), (SELECT max(id) FROM leads));
```

And `tests/fixtures/deals.sql`, which Your Turn 2 and 3 use:

```sql
-- Needs the "companies" fixture first.
INSERT INTO deals (id, company_id, title, value_cents, stage) OVERRIDING SYSTEM VALUE VALUES
    (1, 1, 'Rockets', 100000, 'qualification'),
    (2, 1, 'Anvils', 25050, 'proposal'),
    (3, 2, 'Widgets', 50000, 'won');

SELECT setval(pg_get_serial_sequence('deals', 'id'), (SELECT max(id) FROM deals));
```

Fixtures are applied **in the order you list them**, and they don't know about each other, so
`contacts` needs `companies` listed first or the foreign key rejects them.

> 🟢 **FOLLOW ALONG**: use them in `tests/api/companies.rs`:

```rust
#[sqlx::test(fixtures(path = "../fixtures", scripts("companies")))]
async fn list_filters_by_lifecycle_and_search(pool: PgPool) {
    let app = app(pool);
    let (status, body) = send(&app, get("/companies?lifecycle=customer")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["total"], 1);
    assert_eq!(body["items"][0]["name"], "Acme Corp");

    let (_, body) = send(&app, get("/companies?search=GLOB")).await;
    assert_eq!(body["items"][0]["id"], 2);
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "contacts")))]
async fn company_with_contacts_cannot_be_deleted(pool: PgPool) {
    let (status, body) = send(&app(pool), delete("/companies/1")).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"]["message"], "company #1 still has contacts");
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies")))]
async fn pagination_reports_total_and_page(pool: PgPool) {
    let (_, body) = send(&app(pool), get("/companies?per_page=1&page=2")).await;
    assert_eq!(body["total"], 2);
    assert_eq!(body["page"], 2);
    assert_eq!(body["items"].as_array().unwrap().len(), 1);
    assert_eq!(body["items"][0]["name"], "Globex");
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies")))]
async fn update_replaces_fields_and_validates(pool: PgPool) {
    let app = app(pool);
    let body = json!({ "name": "Globex Corp", "website": null, "lifecycle": "customer" });
    let (status, updated) = send(&app, put_json("/companies/2", body)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["lifecycle"], "customer");

    let blank = json!({ "name": " ", "website": null, "lifecycle": "customer" });
    let (status, body) = send(&app, put_json("/companies/2", blank)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error_code(&body), "validation_failed");
}
```

**The path.** The macro embeds each fixture with `include_str!`, which resolves paths relative to
**the file containing the test**. From `tests/api/companies.rs`, `../fixtures` is `tests/fixtures`.
The shorter form `fixtures("companies")` looks in a `fixtures/` folder *next to* the test file.
We share one folder between `tests/api/` and `tests/db/`, so we spell out the path.

> 🟡 **EXPERIMENT**: remove the `setval` line from `companies.sql`, and add a test using the
> `companies` fixture that does `POST /companies`. Predict the status code, then run it. Read the
> server-side error your `ApiError::Internal` logs. Which constraint was violated? Put the line back.

## Step 3 — Repository tests: `tests/db/`

API tests answer "does the product behave?". Some questions are easier and more precise one layer
down, by calling `companies::db::*` and `leads::service::*` directly:

- does a constraint violation become the *right* `CrmError`?
- does a failed conversion leave **nothing** behind?

A second integration-test binary keeps them separate. Each directory under `tests/` with a
`main.rs` is compiled as one test crate, so `cargo test --test db` runs only these.

> 🟢 **FOLLOW ALONG**: `tests/db/main.rs`

```rust
//! Repository-level tests: call the `db` functions directly, no HTTP.
mod companies;
mod contacts;
mod deals;
mod leads;
```

Create `tests/db/contacts.rs` and `tests/db/deals.rs` empty for now (they're Your Turns).

`tests/db/companies.rs`:

```rust
use rust_crm::companies::{self, CompanyFilter, CompanyId, Lifecycle, NewCompany};
use rust_crm::errors::CrmError;
use sqlx::PgPool;

#[sqlx::test]
async fn insert_then_get_round_trips(pool: PgPool) {
    let new = NewCompany {
        name: "Acme".into(),
        website: Some("https://acme.test".into()),
    };
    let inserted = companies::db::insert(&pool, &new).await.unwrap();
    let fetched = companies::db::get(&pool, inserted.id).await.unwrap();
    assert_eq!(fetched, inserted);
    assert_eq!(fetched.lifecycle, Lifecycle::Prospect); // the column DEFAULT
}

#[sqlx::test]
async fn missing_company_is_not_found(pool: PgPool) {
    let err = companies::db::get(&pool, CompanyId(42)).await.unwrap_err();
    assert!(matches!(
        err,
        CrmError::NotFound {
            entity: "company",
            id: 42
        }
    ));
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies")))]
async fn hostile_search_text_is_just_text(pool: PgPool) {
    let filter = CompanyFilter {
        lifecycle: None,
        search: Some("x' OR '1'='1".into()),
    };
    let (items, total) = companies::db::list(&pool, &filter, 20, 0).await.unwrap();
    assert!(items.is_empty());
    assert_eq!(total, 0);
}

#[sqlx::test]
async fn blank_name_is_rejected_by_the_database_too(pool: PgPool) {
    // Bypass Rust validation on purpose: the CHECK constraint is the last line of defence.
    let new = NewCompany {
        name: "   ".into(),
        website: None,
    };
    let err = companies::db::insert(&pool, &new).await.unwrap_err();
    match err {
        CrmError::Database(sqlx::Error::Database(db)) => {
            assert_eq!(db.constraint(), Some("companies_name_check"));
        }
        other => panic!("expected a CHECK violation, got {other:?}"),
    }
}
```

- `matches!` with a nested struct pattern (`NotFound { entity: "company", id: 42 }`): `CrmError`
  can't derive `PartialEq` (it holds a `sqlx::Error`), the same situation as Lab 21 with
  `io::Error`. Patterns don't need `PartialEq`.
- The CHECK test builds a `NewCompany` that the HTTP layer would never produce. Repository tests
  can do that: they test the *database's* rules, independent of the Rust validation in front of them.
- `hostile_search_text_is_just_text` is the Lab 32 injection attempt as a regression test, against
  the real database this time.

## Step 4 — Proving a rollback

Lab 31 claimed lead conversion is all-or-nothing. Prove it. To test a rollback you have to make a
**later** step fail **after** earlier steps succeeded, then show the earlier steps left no trace.

> 🟢 **FOLLOW ALONG**: `tests/db/leads.rs`

```rust
use rust_crm::deals::NewDealInput;
use rust_crm::errors::CrmError;
use rust_crm::leads::{self, LeadId, LeadStatus};
use rust_crm::money::Money;
use sqlx::PgPool;

async fn count(pool: &PgPool, table: &'static str) -> i64 {
    let sql = match table {
        "companies" => "SELECT COUNT(*) FROM companies",
        "contacts" => "SELECT COUNT(*) FROM contacts",
        "deals" => "SELECT COUNT(*) FROM deals",
        other => panic!("unknown table {other}"),
    };
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

fn pilot() -> Option<NewDealInput> {
    Some(NewDealInput {
        title: "Pilot".into(),
        value: Money::from_cents(500_000),
    })
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("leads")))]
async fn conversion_creates_everything_and_marks_the_lead(pool: PgPool) {
    let summary = leads::service::convert_lead(&pool, LeadId(1), pilot())
        .await
        .unwrap();

    assert!(summary.deal_id.is_some());
    assert_eq!(count(&pool, "companies").await, 1);
    assert_eq!(count(&pool, "contacts").await, 1);
    assert_eq!(count(&pool, "deals").await, 1);
    let lead = leads::db::get(&pool, LeadId(1)).await.unwrap();
    assert_eq!(lead.status, LeadStatus::Converted);
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("leads")))]
async fn a_lead_converts_only_once(pool: PgPool) {
    leads::service::convert_lead(&pool, LeadId(1), None)
        .await
        .unwrap();
    let err = leads::service::convert_lead(&pool, LeadId(1), None)
        .await
        .unwrap_err();
    assert!(matches!(err, CrmError::LeadNotQualified(LeadId(1))));
    assert_eq!(count(&pool, "companies").await, 1);
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "leads")))]
async fn failed_contact_insert_rolls_back_the_company(pool: PgPool) {
    // Someone already has the lead's email: the contact INSERT (2nd write) fails.
    sqlx::query("INSERT INTO contacts (name, email) VALUES ('Squatter', 'dee@initech.test')")
        .execute(&pool)
        .await
        .unwrap();

    let err = leads::service::convert_lead(&pool, LeadId(1), None)
        .await
        .unwrap_err();

    assert!(matches!(err, CrmError::DuplicateEmail(_)));
    assert_eq!(count(&pool, "companies").await, 2, "Initech must not exist");
    let lead = leads::db::get(&pool, LeadId(1)).await.unwrap();
    assert_eq!(lead.status, LeadStatus::Qualified, "the lead is untouched");
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("leads")))]
async fn failed_deal_insert_rolls_back_company_and_contact(pool: PgPool) {
    // Sabotage the schema of THIS test's private database so the deal INSERT
    // (the 3rd write) fails after the company and contact were written.
    sqlx::query("ALTER TABLE deals ADD CONSTRAINT no_pilots CHECK (title <> 'Pilot')")
        .execute(&pool)
        .await
        .unwrap();

    let err = leads::service::convert_lead(&pool, LeadId(1), pilot())
        .await
        .unwrap_err();

    assert!(matches!(err, CrmError::Database(_)));
    assert_eq!(count(&pool, "companies").await, 0);
    assert_eq!(count(&pool, "contacts").await, 0);
    assert_eq!(count(&pool, "deals").await, 0);
    let lead = leads::db::get(&pool, LeadId(1)).await.unwrap();
    assert_eq!(lead.status, LeadStatus::Qualified);
}
```

- **The first test is Lab 31's Experiment 2 as a test.** A forgotten `tx.commit()` returns `Ok`
  and saves nothing. The compiler can't see that bug. This test does.
- **Making the deal insert fail.** `plan_conversion` validates the deal *before* any write, so
  with honest input the third `INSERT` can't fail. We need a fault, and per-test databases let you
  inject one **into the schema**: an extra `CHECK` that rejects the title `Pilot`. Altering a shared
  dev database in a test would be reckless. Altering your own throwaway one is a precise tool.
- **`count`'s `match`.** `sqlx::query_scalar` (the runtime function) takes `impl SqlSafeStr`
  (Lab 32). Each arm is a string literal, so it's a `&'static str`. Building the SQL with
  `format!("SELECT COUNT(*) FROM {table}")` would hit the same compile error as Lab 32's
  experiment. Test code follows the same rules.
- These tests use the runtime `sqlx::query*` functions, not the macros, so they need no `.sqlx/`
  entries. If you do use `query!` in tests, run `cargo sqlx prepare -- --all-targets` so the
  cache includes test targets.

```bash
cargo test --test db leads
```

```text
running 4 tests
test leads::a_lead_converts_only_once ... ok
test leads::failed_deal_insert_rolls_back_company_and_contact ... ok
test leads::conversion_creates_everything_and_marks_the_lead ... ok
test leads::failed_contact_insert_rolls_back_the_company ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 11 filtered out; finished in 0.31s
```

## Step 5 — When a database test fails, open its database

> 🟡 **EXPERIMENT**: predict, then break the transaction on purpose. In
> `src/leads/service.rs`, delete `let mut tx = pool.begin().await?;` and `tx.commit().await?;`, and
> replace every `&mut *tx` with `pool`. It still compiles. (Why? What do `pool` and `&mut *tx` have
> in common?) Run the rollback test:

```bash
cargo test --test db failed_deal
```

```text
running 1 test
test leads::failed_deal_insert_rolls_back_company_and_contact ... FAILED

failures:

---- leads::failed_deal_insert_rolls_back_company_and_contact stdout ----

thread 'leads::failed_deal_insert_rolls_back_company_and_contact' panicked at tests/db/leads.rs:82:5:
assertion `left == right` failed
  left: 1
 right: 0
```

A company was left behind. Because the test **failed**, its database still exists. Find and open it:

```bash
docker compose exec db psql -U crm -d crm -c 'select db_name, test_path from _sqlx_test.databases'
```

```text
                             db_name                             |                          test_path
-----------------------------------------------------------------+--------------------------------------------------------------
 _sqlx_test__PjJIP2iGf3my1mJVLc8nV2oDFSY6SorRIfvE1kosnZIwunODX8N | db::leads::failed_deal_insert_rolls_back_company_and_contact
```

```bash
docker compose exec db psql -U crm -d <db_name from above> \
  -c 'select id, name from companies' -c 'select id, name, email from contacts'
```

```text
 id |  name
----+---------
  1 | Initech
(1 row)

 id |    name     |      email
----+-------------+------------------
  1 | Dee Initech | dee@initech.test
```

There's the orphaned "Initech" and its contact: exactly what a half-finished conversion looks like
in production. **Restore the transaction** (`git checkout src/leads/service.rs`) and run the tests
again. The next run of the test binary also cleans up databases left by earlier runs.

## Step 6 — CI with a real Postgres

Your Lab 24 workflow (patched with `SQLX_OFFLINE` in Lab 30) can't run database tests. GitHub
Actions can start **service containers** next to a job, which is the CI equivalent of your
`docker-compose.yml`.

> 🟢 **FOLLOW ALONG**: replace `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
  pull_request:

env:
  CARGO_TERM_COLOR: always
  # Compile query! macros from the committed .sqlx/ cache...
  SQLX_OFFLINE: "true"
  # ...but let #[sqlx::test] and sqlx-cli talk to the service below.
  DATABASE_URL: postgres://crm:crm@localhost:5432/crm

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_USER: crm
          POSTGRES_PASSWORD: crm
          POSTGRES_DB: crm
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U crm -d crm"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10

    steps:
      - uses: actions/checkout@v5

      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - uses: Swatinem/rust-cache@v2

      - name: Format
        run: cargo fmt --check

      - name: Clippy
        run: cargo clippy --all-targets -- -D warnings

      - name: Install sqlx-cli
        run: cargo install sqlx-cli --no-default-features --features rustls,postgres

      - name: Apply migrations
        run: sqlx migrate run

      - name: Check the .sqlx query cache is up to date
        run: cargo sqlx prepare --check -- --all-targets

      - name: Test
        run: cargo test
```

Line by line, the parts that are new:

- **`services.postgres`** starts `postgres:17` before the steps run, with the same user, password
  and database as your compose file, so one `DATABASE_URL` works in both places. The
  `--health-*` options make the job **wait until Postgres accepts connections**. Without them the
  first steps can race a database that's still starting.
- **Both `SQLX_OFFLINE` and `DATABASE_URL`?** They answer different questions. `SQLX_OFFLINE=true`
  tells the **macros, at compile time**, to use `.sqlx/` and never connect. That keeps builds
  reproducible: what CI compiles is what you committed. `DATABASE_URL` is read **at runtime** by
  `#[sqlx::test]` and by `sqlx-cli`.
- **`sqlx migrate run`**, then **`cargo sqlx prepare --check`**: this re-derives the query metadata
  from the migrated database and fails if it differs from the committed `.sqlx/`. It catches
  "changed a query, forgot `cargo sqlx prepare`" *and* "added a migration that changes a query's
  result type, forgot to re-prepare". (The tests don't need the migrate step, since every
  `#[sqlx::test]` database is migrated on its own, but the check does.)
- **`-- --all-targets`** passes `--all-targets` to the underlying `cargo check`, so queries in
  tests and examples are checked too.
- **`cargo install sqlx-cli`** compiles the CLI on every run where the cache misses (a minute or
  two). `Swatinem/rust-cache` caches `~/.cargo/bin` so later runs reuse it. sqlx 0.9 doesn't ship
  a lockfile for `cargo install --locked`, so don't add `--locked`.

Simulate it locally before pushing:

```bash
SQLX_OFFLINE=true cargo clippy --all-targets -- -D warnings
SQLX_OFFLINE=true cargo sqlx prepare --check -- --all-targets
SQLX_OFFLINE=true cargo test
```

> 🟡 **EXPERIMENT**: change the `ORDER BY` of any `query!` slightly, **don't** run
> `cargo sqlx prepare`, and run the `--check` command:

```text
error: prepare check failed: .sqlx is missing one or more queries; you should re-run sqlx prepare
```

That's the failure CI will show you. Undo the change.

Push, and watch the Actions tab. The CI badge from Lab 24 now means "the whole stack works
against a real Postgres".

---

## ▶️ Run It
```bash
docker compose up -d
cargo test
```

## ✅ Expected Result
Your test names and counts depend on what you wrote in Labs 24–33. The shape after this lab,
including the Your Turn tests:

```text
     Running unittests src/lib.rs
test result: ok. 19 passed; 0 failed; 0 ignored; ...

     Running tests/api/main.rs
running 14 tests
test activities::keyset_pages_walk_the_whole_history_once ... ok
test activities::a_tampered_cursor_is_rejected ... ok
test activities::activity_for_a_missing_subject_is_404 ... ok
test companies::create_then_get_company ... ok
test companies::company_with_contacts_cannot_be_deleted ... ok
test companies::list_filters_by_lifecycle_and_search ... ok
test companies::pagination_reports_total_and_page ... ok
test companies::unknown_company_is_404 ... ok
test companies::update_replaces_fields_and_validates ... ok
test contacts::duplicate_email_is_409 ... ok
test contacts::invalid_contact_reports_every_field ... ok
test deals::deal_cannot_skip_stages ... ok
test leads::qualified_lead_converts_with_deal ... ok
test leads::unqualified_lead_cannot_convert ... ok
test result: ok. 14 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.80s

     Running tests/db/main.rs
running 15 tests
test companies::blank_name_is_rejected_by_the_database_too ... ok
test companies::hostile_search_text_is_just_text ... ok
test companies::insert_then_get_round_trips ... ok
test companies::missing_company_is_not_found ... ok
test contacts::company_with_contacts_cannot_be_deleted ... ok
test contacts::duplicate_email_on_insert_is_a_domain_error ... ok
test contacts::duplicate_email_on_update_is_a_domain_error ... ok
test contacts::unknown_company_is_not_found ... ok
test deals::closed_deals_stay_closed ... ok
test deals::sql_pipeline_matches_the_rust_pipeline ... ok
test deals::sql_pipeline_on_an_empty_database_lists_every_stage ... ok
test leads::a_lead_converts_only_once ... ok
test leads::conversion_creates_everything_and_marks_the_lead ... ok
test leads::failed_contact_insert_rolls_back_the_company ... ok
test leads::failed_deal_insert_rolls_back_company_and_contact ... ok
test result: ok. 15 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.72s

     Running tests/validation.rs
test result: ok. 1 passed; ...
   Doc-tests rust_crm
test result: ok. ...
```

(Parallel tests finish in any order, so your list won't be sorted like this.) The key facts:
**0 ignored**, and no `_sqlx_test` databases left behind:

```bash
docker compose exec db psql -U crm -d crm -Atc \
  "select count(*) from pg_database where datname like '_sqlx_test%'"
```

```text
0
```

## 🧠 Understand It

**The testing pyramid of this CRM.**

| Layer | Where | Needs a DB | Proves |
|---|---|---|---|
| Unit | `src/**` `#[cfg(test)]` | no | domain rules: emails, money, transitions, conversion plan, SQL text from `QueryBuilder` |
| Repository | `tests/db/` | yes | SQL is right; constraints map to the right `CrmError`; transactions are atomic |
| API | `tests/api/` | yes | routing, extractors, validation, status codes, JSON shapes, end to end |
| CI | `.github/workflows/ci.yml` | service | all of the above on a clean machine, plus `.sqlx/` freshness |

Unit tests are the fastest and most numerous. Most *rules* are tested there. Database tests prove
the integration. API tests prove the product. When an API test fails, a lower layer should usually
tell you why.

**Why not mock the database?** In Lab 31 you chose functions over a repository trait, giving up
easy mocking. This lab is the other half of that trade: a real Postgres per test costs a few
milliseconds and tests what a mock can't: your SQL, your constraints, your transactions,
`FOR UPDATE`, and the error codes Postgres actually returns (Lab 30's 23001 surprise would never
have shown up in a mock).

**Isolation through ownership of a database.** Each test owns its database like a value owns its
heap allocation: created for it, never shared, dropped when it's done. Kept if it failed is the one
deliberate leak, and it's for you to debug with.

**`SQLX_OFFLINE` in CI is about reproducibility.** Online macros in CI would compile against
whatever schema the CI database happens to have. Offline macros compile against what you
committed, and `prepare --check` independently verifies that what you committed matches the
migrations.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: in `failed_contact_insert_rolls_back_the_company`, why do we expect **2**
> companies at the end? Change the fixture list to only `scripts("leads")` and adjust the assertion.
> Which version tells a clearer story?

> 🟡 **EXPERIMENT 2**: run `cargo test -- --test-threads=1` and compare the time with a normal
> `cargo test`. Each test has its own database, so parallelism is safe. What would break if they
> shared one?

> 🟡 **EXPERIMENT 3**: give a test **both** a fixture and an API call that inserts a company, then
> assert on `GET /companies`'s `total`. Delete the `setval` from the fixture again: where exactly
> does the failure appear, and what HTTP status does your API return?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: contact constraint tests** in `tests/db/contacts.rs`. Use the fixtures, call
> `contacts::db` / `companies::db` directly, and assert on `CrmError` variants with `matches!`.

- [ ] inserting `ADA@acme.test` when the fixture has `ada@acme.test` gives
      `CrmError::DuplicateEmail` **with the normalised email** in it
- [ ] updating contact 2 to contact 1's email gives `DuplicateEmail`
- [ ] inserting a contact for company 99 gives `NotFound { entity: "company", id: 99 }`
- [ ] `companies::db::delete` on a company with contacts gives `HasContacts(CompanyId(1))` **and**
      the company still exists afterwards

> 🔵 **YOUR TURN 2: the SQL pipeline agrees with the Rust pipeline** in `tests/db/deals.rs`.

- [ ] on an empty database, `deals::db::pipeline` equals `deals::pipeline_report(&[])`, which
      lists all five stages with zeros
- [ ] with the `companies` + `deals` fixtures, `deals::db::pipeline(&pool)` equals
      `deals::pipeline_report(&deals::db::list(&pool).await?)`, plus one concrete assertion
      (qualification: 1 deal, $1,000.00)
- [ ] `deals::db::move_stage` on the `won` deal to `lost` gives
      `InvalidTransition { from: Won, to: Lost }`

> 🔵 **YOUR TURN 3: keyset pagination over HTTP** in a new `tests/api/activities.rs` (add
> `mod activities;` to `tests/api/main.rs`).

- [ ] log 5 calls on `deal:1` (fixtures `companies` + `deals`) with distinct `occurred_at` values,
      then walk `GET /activities?subject=deal:1&limit=2` page by page using `next_cursor`: you see
      `Call 4, Call 3`, then `Call 2, Call 1`, then `Call 0` with `next_cursor: null`
- [ ] a tampered cursor gives 422 with `fields[0].field == "cursor"`
- [ ] `POST /activities` for `deal:99` gives 404

> 🔵 **OPTIONAL**: if you did Lab 32's Your Turn 2, write a DB test that inserts an activity and a
> note with the **same** timestamp and checks `history::page` with `limit = 1` returns each exactly
> once across pages.

## 💡 Hint
> 💡 **HINT**: For error assertions, `assert!(matches!(err, CrmError::DuplicateEmail(email) if email == "ada@acme.test"))`
> works: `matches!` accepts the same guards as `match`.

<details><summary>Hint 2 (more specific)</summary>

- Your Turn 1: build `NewContact` with `Email::parse("ADA@acme.test").unwrap()`. Parsing
  lowercases, which is why the error mentions the lowercase address.
- Your Turn 2: `PipelineRow` needs `PartialEq` for `assert_eq!` on whole vectors (Lab 31 Your
  Turn 3 added it). The fixture's qualification deal is 100000 cents.
- Your Turn 3: a small `async fn log_calls(app: &Router, n: u32)` helper keeps the test readable.
  Use `format!("2026-01-01T09:{minute:02}:00Z")` for distinct, ordered timestamps. Read
  `body["next_cursor"].as_str().unwrap()` and pass it back as `&cursor=...`. The cursor alphabet
  is URL-safe, so no extra encoding is needed.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. List the six things `#[sqlx::test]` does for a test that takes a `PgPool`.
2. Why does a fixture that sets explicit ids need `OVERRIDING SYSTEM VALUE` *and* `setval`?
3. How do you prove a transaction rolled back? Why was the `ALTER TABLE` trick safe here and
   unthinkable on a shared database?
4. Where do you look when a database test fails, and why does that database still exist?
5. In CI, what does `SQLX_OFFLINE=true` control and what does `DATABASE_URL` control? What does
   `cargo sqlx prepare --check` catch that `cargo test` wouldn't?
6. Which bug from Lab 31's experiments can only a test catch, not the compiler?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`, and
that a push turns the CI badge green.

## Git Commit
```bash
git add tests
git commit -m "Add database integration tests"

git add .github/workflows/ci.yml
git commit -m "Run Postgres in CI"
git tag lab-33
git push && git push --tags
```

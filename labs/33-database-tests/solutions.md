# Lab 33 — Solutions

> 🔴 One good answer per task, with the reasoning. Every test below passed against Postgres when
> this lab was written.

---

## 🔵 Your Turn 1 — `tests/db/contacts.rs`

```rust
use rust_crm::companies::{self, CompanyId};
use rust_crm::contacts::{self, ContactId, Email, NewContact};
use rust_crm::errors::CrmError;
use sqlx::PgPool;

fn new_contact(email: &str, company: Option<i64>) -> NewContact {
    NewContact {
        name: "Test Person".into(),
        email: Email::parse(email).unwrap(),
        phone: None,
        company_id: company.map(CompanyId),
    }
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "contacts")))]
async fn duplicate_email_on_insert_is_a_domain_error(pool: PgPool) {
    let err = contacts::db::insert(&pool, &new_contact("ADA@acme.test", None))
        .await
        .unwrap_err();
    assert!(matches!(err, CrmError::DuplicateEmail(email) if email == "ada@acme.test"));
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "contacts")))]
async fn duplicate_email_on_update_is_a_domain_error(pool: PgPool) {
    let err = contacts::db::update(&pool, ContactId(2), &new_contact("ada@acme.test", Some(1)))
        .await
        .unwrap_err();
    assert!(matches!(err, CrmError::DuplicateEmail(_)));
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies")))]
async fn unknown_company_is_not_found(pool: PgPool) {
    let err = contacts::db::insert(&pool, &new_contact("new@x.test", Some(99)))
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        CrmError::NotFound {
            entity: "company",
            id: 99
        }
    ));
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "contacts")))]
async fn company_with_contacts_cannot_be_deleted(pool: PgPool) {
    let err = companies::db::delete(&pool, CompanyId(1))
        .await
        .unwrap_err();
    assert!(matches!(err, CrmError::HasContacts(CompanyId(1))));
    // ...and nothing was deleted.
    assert!(companies::db::get(&pool, CompanyId(1)).await.is_ok());
}
```

**Reasoning**

- **`ADA@acme.test`** tests two things at once: `Email::parse` normalises (Lab 12), and the
  plain `UNIQUE` constraint is then enough (Lab 30). If someone "optimises" `Email` to keep the
  original casing, this test fails, and points at the right decision.
- **`matches!(err, CrmError::DuplicateEmail(email) if email == "...")`**: the guard binds
  `email` by reference inside `matches!`, so `err` isn't moved.
- **"And nothing was deleted."** An error *and* an unchanged state is what a failure test should
  check. "Returned an error but deleted the row anyway" is a real bug class.
- The `update` test proves `write_error` is used on *both* code paths. A shared helper is only
  shared if both callers use it.

---

## 🔵 Your Turn 2 — `tests/db/deals.rs`

```rust
use rust_crm::deals::{self, DealId, DealStage};
use rust_crm::errors::CrmError;
use rust_crm::money::Money;
use sqlx::PgPool;

#[sqlx::test]
async fn sql_pipeline_on_an_empty_database_lists_every_stage(pool: PgPool) {
    let rows = deals::db::pipeline(&pool).await.unwrap();
    assert_eq!(rows, deals::pipeline_report(&[]));
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "deals")))]
async fn sql_pipeline_matches_the_rust_pipeline(pool: PgPool) {
    let all = deals::db::list(&pool).await.unwrap();
    let from_sql = deals::db::pipeline(&pool).await.unwrap();
    assert_eq!(from_sql, deals::pipeline_report(&all));

    let qualification = &from_sql[0];
    assert_eq!(qualification.stage, DealStage::Qualification);
    assert_eq!(
        (qualification.count, qualification.total),
        (1, Money::from_cents(100_000))
    );
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "deals")))]
async fn closed_deals_stay_closed(pool: PgPool) {
    let err = deals::db::move_stage(&pool, DealId(3), DealStage::Lost)
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        CrmError::InvalidTransition {
            from: DealStage::Won,
            to: DealStage::Lost
        }
    ));
}
```

**Reasoning**

- **A test oracle.** `pipeline_report` (Rust) is easy to trust: it's short and has its own unit
  tests. `pipeline` (SQL) is fast but trickier: `GROUP BY` drops empty stages, `SUM` returns
  `NUMERIC`, and the ordering is done in Rust. Comparing them on the same data checks *every*
  stage's count and total in one assertion.
- **The empty-database case** is the one most likely to break: `GROUP BY` returns no rows at all,
  and the "fill in missing stages" loop has to do all the work.
- **One concrete assertion as well**, so the test can't pass if *both* implementations were wrong
  in the same way (for example, both returning all zeros).
- `closed_deals_stay_closed` goes through `move_stage`, which reads from Postgres and then asks
  `Deal::move_to`. It proves the database round-trip feeds the domain rule correctly. The rule
  itself is unit-tested in `src/deals/model.rs`.

---

## 🔵 Your Turn 3 — `tests/api/activities.rs`

```rust
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

use crate::helpers::{app, get, post_json, send};

async fn log_calls(app: &axum::Router, n: u32) {
    for minute in 0..n {
        let body = json!({
            "subject": "deal:1",
            "kind": { "type": "call", "minutes": 5 },
            "summary": format!("Call {minute}"),
            "occurred_at": format!("2026-01-01T09:{minute:02}:00Z"),
        });
        let (status, _) = send(app, post_json("/activities", body)).await;
        assert_eq!(status, StatusCode::CREATED);
    }
}

fn summaries(page: &Value) -> Vec<&str> {
    page["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["summary"].as_str().unwrap())
        .collect()
}

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "deals")))]
async fn keyset_pages_walk_the_whole_history_once(pool: PgPool) {
    let app = app(pool);
    log_calls(&app, 5).await;

    let (_, first) = send(&app, get("/activities?subject=deal:1&limit=2")).await;
    assert_eq!(summaries(&first), ["Call 4", "Call 3"]);

    let cursor = first["next_cursor"].as_str().unwrap();
    let (_, second) = send(
        &app,
        get(&format!(
            "/activities?subject=deal:1&limit=2&cursor={cursor}"
        )),
    )
    .await;
    assert_eq!(summaries(&second), ["Call 2", "Call 1"]);

    let cursor = second["next_cursor"].as_str().unwrap();
    let (_, last) = send(
        &app,
        get(&format!(
            "/activities?subject=deal:1&limit=2&cursor={cursor}"
        )),
    )
    .await;
    assert_eq!(summaries(&last), ["Call 0"]);
    assert!(last["next_cursor"].is_null());
}

#[sqlx::test]
async fn a_tampered_cursor_is_rejected(pool: PgPool) {
    let (status, body) = send(&app(pool), get("/activities?subject=deal:1&cursor=bm9wZQ")).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["fields"][0]["field"], "cursor");
}

#[sqlx::test]
async fn activity_for_a_missing_subject_is_404(pool: PgPool) {
    let body =
        json!({ "subject": "deal:99", "kind": { "type": "call", "minutes": 1 }, "summary": "?" });
    let (status, _) = send(&app(pool), post_json("/activities", body)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
```

Add `mod activities;` to `tests/api/main.rs`.

**Reasoning**

- **`summaries(&first)` returns `Vec<&str>` borrowing from `first`.** That's elision (Lab 10):
  one reference in, so the output borrows from it. Comparing a `Vec<&str>` with an array
  `["Call 4", "Call 3"]` works because `Vec<A>: PartialEq<[B; N]>` exists when `A: PartialEq<B>`.
- **`let cursor = first["next_cursor"].as_str().unwrap();`** borrows from `first`, which is still
  alive. Shadowing `cursor` for the second page borrows from `second`. Each borrow ends after use.
- **Testing the last page** (`next_cursor` is `null`) matters as much as the middle: an off-by-one
  in the `limit + 1` trick would show up as a final page with a cursor that leads to an empty page.
- **`bm9wZQ`** is base64 for `nope`: valid base64, invalid cursor. That tests the *parsing* path,
  not just the base64 path. (`Cursor::decode`'s unit tests cover the "not base64" case.)
- The fixtures give the test a real `deal:1`. Without them, the activity insert answers 404,
  which the third test pins down on purpose.

---

## 🔵 Optional — history tie test (if you did Lab 32's Your Turn 2)

```rust
// tests/db/history.rs  (add `mod history;` to tests/db/main.rs)
use rust_crm::deals::DealId;
use rust_crm::history::{self, HistoryPosition};
use rust_crm::subject::Subject;
use sqlx::PgPool;

#[sqlx::test(fixtures(path = "../fixtures", scripts("companies", "deals")))]
async fn equal_timestamps_are_paged_exactly_once(pool: PgPool) {
    sqlx::query(
        "INSERT INTO notes (subject_type, subject_id, body, created_at)
         VALUES ('deal', 1, 'note', '2026-01-01T09:00:00Z')",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO activities (subject_type, subject_id, kind, details, summary, occurred_at)
         VALUES ('deal', 1, 'call', '{\"type\":\"call\",\"minutes\":1}', 'call', '2026-01-01T09:00:00Z')",
    )
    .execute(&pool)
    .await
    .unwrap();

    let subject = Subject::Deal(DealId(1));
    let first = history::page(&pool, subject, None, 1).await.unwrap();
    let after = HistoryPosition {
        at: first[0].at,
        item_type: first[0].item_type.clone(),
        id: first[0].id,
    };
    let second = history::page(&pool, subject, Some(&after), 1)
        .await
        .unwrap();
    let third = history::page(
        &pool,
        subject,
        Some(&HistoryPosition {
            at: second[0].at,
            item_type: second[0].item_type.clone(),
            id: second[0].id,
        }),
        1,
    )
    .await
    .unwrap();

    assert_eq!(
        (first[0].item_type.as_str(), second[0].item_type.as_str()),
        ("note", "activity")
    );
    assert!(third.is_empty());
}
```

Both rows get id 1 in a fresh database: a collision on `(at, id)` *and* on `at`, so only
`item_type` keeps them apart. That's the case the composite cursor exists for.

---

## 🧪 Experiment answers

**Step 2 (no `setval`).** `POST /companies` answers **500**. The identity sequence still starts at
1, so the `INSERT` gets id 1, which the fixture already used. That's a `companies_pkey` unique
violation, which isn't one of the constraints you map to a domain error, so it's
`CrmError::Database` and becomes a 500.

**Step 5.** It compiles because both `pool` (`&PgPool`) and `&mut *tx` (`&mut PgConnection`)
implement `PgExecutor`. The functions were written to accept either, which is exactly what made
the transaction possible, and also what makes removing it type-check. Only the test notices.

**Experiment 1.** The `companies` fixture adds Acme and Globex, so 2 companies means "Initech was
never created". With only `leads`, assert 0. That's clearer for this test because the number
doesn't need explaining, though you then need the squatting contact without a company (which
works, since `company_id` is nullable).

**Experiment 2.** Single-threaded takes several times longer. Sharing one database would make
tests depend on each other's rows: totals, "not found" ids and unique emails would all collide,
in an order that changes between runs. Flaky tests.

**Experiment 3.** The fixture's `INSERT` succeeds. The *API's* insert fails with a primary-key
violation and becomes a 500, so the failure shows up in your HTTP assertion, far from its cause
(the fixture). A good reason to keep the `setval` line in every fixture that sets ids.

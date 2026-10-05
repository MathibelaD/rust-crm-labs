# Lab 31 — Repositories on Postgres

> **Phase:** 9 — PostgreSQL · **Builds on:** Lab 30 · **Time:** ~7 hours
> **Your repo before this lab:** tag `lab-30` · **After:** tag `lab-31`

This lab assumes you completed Your Turns 1–3 in Lab 30 (`src/contacts/db.rs`, the contacts
handlers, and `HasContacts` from the database). If not, see Lab 30's `solutions.md`.

## 🎯 Goal
Finish the strangler migration: deals, leads, activities and notes move to Postgres, lead
conversion becomes **one atomic transaction**, and the JSON storage, `InMemoryRepo` and `Crm` are
deleted. Your domain types and their unit tests stay.

## 🧠 What You'll Learn
- `async fn` in traits, and why `Arc<dyn Repository>` doesn't compile (dyn compatibility, E0038)
- The options (generics, `async_trait`, boxed futures, enums, plain functions) and how to choose
- `impl PgExecutor<'_>`: one function that runs on a pool *or* inside a transaction
- The executor's lifetime parameter, and **reborrowing** with `&mut *tx`
- Transactions: `begin`, `commit`, and **rollback on `Drop`**, RAII paying off again
- `SELECT ... FOR UPDATE` row locks, and an optimistic check for deal stage moves
- JSONB columns with `sqlx::types::Json<T>` and macro type overrides
- What survives a storage rewrite when the domain was kept pure

## 🔨 What We're Building
```text
lab-30                                         lab-31
AppState { pool, crm, storage }                AppState { pool }
  companies, contacts ─► Postgres                companies, contacts, deals,
  deals, leads, activities, notes                leads, activities, notes ─► Postgres
      ─► Crm ─► crm-data.json
                                               POST /leads/{id}/convert
                                                 BEGIN
                                                   SELECT lead ... FOR UPDATE
                                                   INSERT company, contact, (deal)
                                                   UPDATE lead SET status = 'converted'
                                                 COMMIT   (or ROLLBACK, all of it)
```

Every endpoint keeps its URL and JSON shape. Clients won't notice anything changed, and that's the
point of having an API.

---

## Step 1 — Should repositories be a trait?

In Lab 23 you put storage behind `trait Storage` and used `Arc<dyn Storage>`. The obvious move
now is the same thing for Postgres. Try it before deciding.

> 🟡 **EXPERIMENT**: predict first. Create `examples/repository_trait.rs`:

```rust
//! Lab 31 experiment: can we put Postgres behind a trait object?
use std::sync::Arc;

use rust_crm::companies::{Company, CompanyId, NewCompany};
use rust_crm::errors::CrmError;
use sqlx::PgPool;

trait CompanyRepository {
    async fn insert(&self, new: &NewCompany) -> Result<Company, CrmError>;
    async fn get(&self, id: CompanyId) -> Result<Company, CrmError>;
}

struct PgCompanyRepository {
    pool: PgPool,
}

impl CompanyRepository for PgCompanyRepository {
    async fn insert(&self, new: &NewCompany) -> Result<Company, CrmError> {
        rust_crm::companies::db::insert(&self.pool, new).await
    }
    async fn get(&self, id: CompanyId) -> Result<Company, CrmError> {
        rust_crm::companies::db::get(&self.pool, id).await
    }
}

struct AppState {
    companies: Arc<dyn CompanyRepository>,
}

fn main() {}
```

```bash
cargo check --example repository_trait
```

```text
error[E0038]: the trait `CompanyRepository` is not dyn compatible
  --> examples/repository_trait.rs:27:20
   |
27 |     companies: Arc<dyn CompanyRepository>,
   |                    ^^^^^^^^^^^^^^^^^^^^^ `CompanyRepository` is not dyn compatible
   |
note: for a trait to be dyn compatible it needs to allow building a vtable
      for more information, visit <https://doc.rust-lang.org/reference/items/traits.html#dyn-compatibility>
  --> examples/repository_trait.rs:9:14
   |
 8 | trait CompanyRepository {
   |       ----------------- this trait is not dyn compatible...
 9 |     async fn insert(&self, new: &NewCompany) -> Result<Company, CrmError>;
   |              ^^^^^^ ...because method `insert` is `async`
10 |     async fn get(&self, id: CompanyId) -> Result<Company, CrmError>;
   |              ^^^ ...because method `get` is `async`
   = help: consider moving `insert` to another trait
   = help: consider moving `get` to another trait
   = help: only type `PgCompanyRepository` implements `CompanyRepository`; consider using it directly instead.
```

### Why: the vtable has no slot for "some future"

Recall Lab 23. A `dyn Trait` is a data pointer plus a **vtable**, a table of function pointers,
one per method, each with *one* fixed signature. Now desugar an `async fn` (Lab 26):

```rust
async fn get(&self, id: CompanyId) -> Result<Company, CrmError>
// is really
fn get(&self, id: CompanyId) -> impl Future<Output = Result<Company, CrmError>>
```

`impl Future` means "one specific, compiler-generated state-machine type **per implementation**".
`PgCompanyRepository::get` returns one type, a mock's `get` would return another, of a different
size. A vtable slot must have a single return type that the caller can allocate space for without
knowing which implementation it called. There isn't one, so the trait can't be made into `dyn`.
Lab 23 showed the same rule with a generic method. Same cause, different trigger.

### What about generics instead of `dyn`?

Generics don't need a vtable: `AppState<R: CompanyRepository>` monomorphises (Lab 16). It
compiles, until a handler uses it:

```rust
async fn get_company<R: CompanyRepository + Send + Sync + 'static>(
    axum::extract::State(state): axum::extract::State<AppState<R>>,
    axum::extract::Path(id): axum::extract::Path<i64>,
) -> String {
    match state.companies.get(CompanyId(id)).await {
        Ok(c) => c.name,
        Err(e) => e.to_string(),
    }
}
// ... .route("/companies/{id}", axum::routing::get(get_company::<R>))
```

```text
error[E0277]: the trait bound `fn(State<_>, Path<i64>) -> _ {get_company::<R>}: Handler<_, _>` is not satisfied
   --> examples/repository_trait.rs:48:54
    |
 48 |         .route("/companies/{id}", axum::routing::get(get_company::<R>))
    |                                   ------------------ ^^^^^^^^^^^^^^^^ the trait `Handler<_, _>` is not implemented for fn item `fn(State<AppState<R>>, Path<i64>) -> _ {get_company::<R>}`
    = note: Consider using `#[axum::debug_handler]` to improve the error message
```

The real cause is hidden. An `async fn` in a trait promises an `impl Future`, but **not** that the
future is `Send`. axum runs handlers on a multi-threaded runtime, so it requires `Send` futures
(the same bound as `tokio::spawn`, Lab 26). The fix is to spell the method out and *promise*
`Send`:

```rust
trait CompanyRepository {
    fn get(&self, id: CompanyId) -> impl Future<Output = Result<Company, CrmError>> + Send;
}
```

That compiles. Implementations may still write `async fn`. You'll use exactly this shape in
Lab 39 for a `Mailer` trait. But look at the cost: a type parameter on `AppState`, on every handler
and on `router()`, and still no `dyn`.

### The options

| Option | How | Cost |
|---|---|---|
| Generics + `-> impl Future + Send` | as above | type parameter everywhere; no `dyn` |
| `async_trait` crate | macro rewrites to `Pin<Box<dyn Future + Send>>` | a heap allocation per call; macro magic |
| Boxed futures by hand | `fn get(..) -> Pin<Box<dyn Future<..> + Send + '_>>` | what `async_trait` writes, in public |
| Enum dispatch | `enum Repo { Pg(..), Memory(..) }` + `match` | closed set of backends |
| **Plain async functions** | `companies::db::get(db, id)` | no polymorphism at all |

**The choice: plain functions.** The compiler's last `help` line says it: *only one type
implements this trait*. A trait earns its place when there are **two** real implementations.
`Storage` had two (memory and JSON). Postgres repositories have one. The usual argument for a
trait here is mocking in tests, and Lab 33 answers it differently: a real, throwaway database per
test is fast enough, and it tests the SQL, which a mock never would. If a second backend ever
shows up, extract the trait then, when you know what it needs to abstract.

Delete `examples/repository_trait.rs` (it doesn't compile, on purpose).

## Step 2 — `impl PgExecutor<'_>`: one function, pool or transaction

Lead conversion must insert a company, a contact and a deal **in one transaction**.
`companies::db::insert` takes `&PgPool` today, and a pool runs each statement on whichever
connection is free, outside any transaction. We want the *same* function to run inside one.

SQLx's answer is the `Executor` trait: "something you can run a query on". `PgExecutor<'c>` is
its Postgres-only alias. The implementations that matter:

```text
impl<'c> Executor<'c> for &'c mut PgConnection      // one connection, borrowed for 'c
impl<'p> Executor<'p> for &'_ Pool<Postgres>        // a pool: borrows a connection internally
```

- **`'c` is how long the executor borrows a connection.** A `&'c mut PgConnection` is an
  exclusive borrow (Lab 07) of one connection for `'c`. Queries run on it, in order, inside
  whatever transaction that connection is in.
- **`&PgPool` works for any lifetime.** It doesn't lend you a connection. It checks one out per
  query and returns it.
- **`impl PgExecutor<'_>` in argument position** means "any type implementing it, for some
  lifetime I don't need to name". `'_` is a fresh anonymous lifetime parameter (the elision of
  Lab 10, applied to a trait bound).

> 🟢 **FOLLOW ALONG**: in `src/companies/db.rs` and `src/contacts/db.rs`, change every
> *single-statement* function. Shown for `get`:

```rust
use sqlx::{PgExecutor, PgPool};

pub async fn get(db: impl PgExecutor<'_>, id: CompanyId) -> Result<Company, CrmError> {
    let row = sqlx::query_as!(
        CompanyRow,
        "SELECT id, name, website, lifecycle FROM companies WHERE id = $1",
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

Do the same for `insert`, `update`, `delete` and `list_for_company`. Handlers don't change at
all: `&state.pool` is a `PgExecutor`.

> 🟡 **EXPERIMENT**: do it to `list` too (`db: impl PgExecutor<'_>`, and `.fetch_all(db)` /
> `.fetch_one(db)`). Predict the error before you run `cargo check`.

```text
error[E0382]: use of moved value: `db`
  --> src/companies/db.rs:98:16
   |
66 |     db: impl PgExecutor<'_>,
   |     -- move occurs because `db` has type `impl PgExecutor<'_>`, which does not implement the `Copy` trait
...
87 |     .fetch_all(db)
   |                -- value moved here
...
98 |     .fetch_one(db)
   |                ^^ value used here after move
   |
help: consider restricting opaque type `impl PgExecutor<'_>` with trait `Copy`
   |
66 |     db: impl PgExecutor<'_> + Copy,
   |                             ++++++
```

Ownership, Lab 06 style. `fetch_all(db)` takes the executor **by value**, because a
`&mut PgConnection` can't be shared, so passing it is a move. `list` runs **two** statements (rows,
then the count), so it needs the executor twice.

The compiler's suggestion (`+ Copy`) would compile and is **wrong for us**: `&PgPool` is `Copy`,
but `&mut PgConnection` never is (two copies of an exclusive borrow would break aliasing XOR
mutation). Adding `+ Copy` silently makes the function unusable inside a transaction. That's the
one thing we wanted.

**The rule this course uses:** a function running *one* statement takes `impl PgExecutor<'_>`.
A function running *several* statements that never needs a transaction (like `list`) takes
`&PgPool`, and each statement gets its own connection. (The alternative is `&mut PgConnection` and
writing `&mut *conn` for each statement, which forces every caller to acquire a connection first.)
Undo the experiment.

## Step 3 — Four more tables

> 🟢 **FOLLOW ALONG**: one migration at a time (Lab 30's same-second warning applies).

```bash
sqlx migrate add create_deals
```

```sql
CREATE TABLE deals (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id  BIGINT      NOT NULL REFERENCES companies (id) ON DELETE RESTRICT,
    title       TEXT        NOT NULL CHECK (btrim(title) <> ''),
    value_cents BIGINT      NOT NULL CHECK (value_cents >= 0),
    stage       TEXT        NOT NULL DEFAULT 'qualification'
                            CHECK (stage IN ('qualification', 'proposal', 'negotiation', 'won', 'lost')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`Money { cents: i64 }` (Lab 18) maps straight onto `BIGINT`. You chose integer cents to avoid
`0.1 + 0.2`, and now there's nothing to convert.

```bash
sqlx migrate add create_leads
```

```sql
CREATE TABLE leads (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         TEXT        NOT NULL CHECK (btrim(name) <> ''),
    email        TEXT        NOT NULL,
    company_name TEXT,
    source       TEXT        NOT NULL DEFAULT 'other'
                             CHECK (source IN ('website', 'referral', 'event', 'cold_outreach', 'other')),
    status       TEXT        NOT NULL DEFAULT 'new'
                             CHECK (status IN ('new', 'qualified', 'disqualified', 'converted')),
    notes        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

No `UNIQUE` on `leads.email`: the same person can come in as a lead twice. Note the new status,
`converted`. Step 5 explains it.

```bash
sqlx migrate add create_activities
```

```sql
-- A "subject" is polymorphic (company, contact or deal), so subject_id can't
-- be a foreign key. The application checks that the subject exists.
CREATE TABLE activities (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject_type TEXT        NOT NULL CHECK (subject_type IN ('company', 'contact', 'deal')),
    subject_id   BIGINT      NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN ('call', 'email', 'meeting')),
    details      JSONB       NOT NULL,
    summary      TEXT        NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Two modelling decisions:

- **`Subject` (Lab 20) becomes two columns.** A foreign key must point at *one* table, so
  `subject_id` can't have one. The alternative is three nullable FK columns
  (`company_id`, `contact_id`, `deal_id`) plus a `CHECK` that exactly one is set. That gives
  integrity at the cost of a wider table. We take the simpler shape and check existence in Rust.
- **`ActivityKind` becomes `kind` + `details JSONB`.** Each variant has different fields
  (`minutes`, an email `subject`, `starts_at` + `attendees`). JSONB stores structured data that
  Postgres can still index and query. `kind` is duplicated in a plain column so you can filter
  with ordinary SQL.

The `notes` table is part of Your Turn 1. Run `sqlx migrate run`.

## Step 4 — Deals

> 🟢 **FOLLOW ALONG**: domain inputs in `src/deals/model.rs`. These replace Lab 29's private
> `DealInput` in `http/deals.rs` (delete it), because the lead conversion needs them too.

```rust
/// What a client supplies to open a deal (the company comes from elsewhere,
/// e.g. the URL or a lead conversion).
#[derive(Debug, Clone, PartialEq)]
pub struct NewDealInput {
    pub title: String,
    pub value: Money,
}

impl NewDealInput {
    pub fn for_company(self, company_id: CompanyId) -> NewDeal {
        NewDeal { company_id, title: self.title, value: self.value }
    }
}

/// A deal that hasn't been saved yet. New deals always start in Qualification.
#[derive(Debug, Clone, PartialEq)]
pub struct NewDeal {
    pub company_id: CompanyId,
    pub title: String,
    pub value: Money,
}

impl Validate for NewDealInput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.title.trim().is_empty() {
            return Err(ValidationError::EmptyName);
        }
        if self.value.cents() < 0 {
            return Err(ValidationError::InvalidMoney(self.value.to_string()));
        }
        Ok(())
    }
}
```

(Use whichever `ValidationError` variants your Lab 29 `DealInput` produced.) Export both from
`src/deals/mod.rs` and add `pub mod db;`.

Two new `CrmError` variants:

```rust
    #[error("company {0} still has deals")]
    HasDeals(CompanyId),
    #[error("{entity} #{id} was changed by someone else; reload and try again")]
    ConcurrentUpdate { entity: &'static str, id: i64 },
```

Map both to `409 conflict` in `status_and_code` (the compiler will remind you). In
`companies::db::delete`, add a second arm next to your Lab 30 `HasContacts` one for the
`deals_company_id_fkey` constraint, mapping to `HasDeals(id)`.

> 🟢 **FOLLOW ALONG**: `src/deals/db.rs`

```rust
//! Deal persistence.

use sqlx::{PgExecutor, PgPool};

use super::{Deal, DealId, DealStage, NewDeal};
use crate::companies::CompanyId;
use crate::database::corrupt;
use crate::errors::CrmError;
use crate::money::Money;

struct DealRow {
    id: i64,
    company_id: i64,
    title: String,
    value_cents: i64,
    stage: String,
}

impl TryFrom<DealRow> for Deal {
    type Error = sqlx::Error;

    fn try_from(row: DealRow) -> Result<Self, Self::Error> {
        Ok(Deal {
            id: DealId(row.id),
            company_id: CompanyId(row.company_id),
            title: row.title,
            value: Money::from_cents(row.value_cents),
            stage: row.stage.parse().map_err(corrupt)?,
        })
    }
}

fn not_found(id: DealId) -> CrmError {
    CrmError::NotFound {
        entity: "deal",
        id: id.0,
    }
}

pub async fn insert(db: impl PgExecutor<'_>, new: &NewDeal) -> Result<Deal, CrmError> {
    let row = sqlx::query_as!(
        DealRow,
        "INSERT INTO deals (company_id, title, value_cents)
         VALUES ($1, $2, $3)
         RETURNING id, company_id, title, value_cents, stage",
        new.company_id.0,
        new.title,
        new.value.cents(),
    )
    .fetch_one(db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_foreign_key_violation() => CrmError::NotFound {
            entity: "company",
            id: new.company_id.0,
        },
        other => CrmError::Database(other),
    })?;
    Ok(row.try_into()?)
}

pub async fn get(db: impl PgExecutor<'_>, id: DealId) -> Result<Deal, CrmError> {
    let row = sqlx::query_as!(
        DealRow,
        "SELECT id, company_id, title, value_cents, stage FROM deals WHERE id = $1",
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

pub async fn list(db: impl PgExecutor<'_>) -> Result<Vec<Deal>, CrmError> {
    let rows = sqlx::query_as!(
        DealRow,
        "SELECT id, company_id, title, value_cents, stage FROM deals ORDER BY id"
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Deal::try_from)
        .collect::<Result<_, _>>()?)
}

/// Moves a deal to `next`, enforcing the domain's transition rules.
///
/// Two statements, so it takes the pool: read the deal, let `Deal::move_to`
/// decide, then write - but only if nobody changed the stage in between.
pub async fn move_stage(pool: &PgPool, id: DealId, next: DealStage) -> Result<Deal, CrmError> {
    let mut deal = get(pool, id).await?;
    let previous = deal.stage;
    deal.move_to(next)?; // pure domain rule from Lab 18

    let row = sqlx::query_as!(
        DealRow,
        "UPDATE deals SET stage = $3
         WHERE id = $1 AND stage = $2
         RETURNING id, company_id, title, value_cents, stage",
        id.0,
        previous.to_string(),
        deal.stage.to_string(),
    )
    .fetch_optional(pool)
    .await?
    .ok_or(CrmError::ConcurrentUpdate {
        entity: "deal",
        id: id.0,
    })?;
    Ok(row.try_into()?)
}
```

**`move_stage` is the interesting one.** The transition rules live in `Deal::move_to` and
`DealStage::can_transition_to` from Lab 18, pure Rust with unit tests. SQL can't call them. So:

1. read the deal,
2. let the **domain** decide (`move_to` returns `InvalidTransition` or mutates `deal.stage`),
3. write *only if the stage is still what we read*: `WHERE id = $1 AND stage = $2`.

Between 1 and 3 another request could move the same deal. Without the `AND stage = $2`, our
write would overwrite theirs based on stale data, the lost update from Lab 30, one row at a
time. With it, the `UPDATE` matches zero rows, `fetch_optional` returns `None`, and we answer
`ConcurrentUpdate` (409). This is **optimistic concurrency control**: no locks, just "write
only if nothing changed", and retrying is up to the client. The lead conversion below uses the
*pessimistic* kind (a lock). You'll see both.

## Step 5 — Leads: `Converted`, and a builder without ids

In memory, `Crm::convert_lead` **removed** the lead from the repository. With a database you'd
lose history ("which lead did this customer come from?"). Converted leads stay as rows with a new
status.

> 🟢 **FOLLOW ALONG** in `src/leads/model.rs`:

```rust
pub enum LeadStatus {
    New,
    Qualified,
    Disqualified,
    /// Kept for history: the lead became a company + contact (+ deal).
    Converted,
}
```

Give `LeadStatus` a `Display` (`"new"`, `"qualified"`, `"disqualified"`, `"converted"`) and a
matching `FromStr`, the same pattern as `LeadSource` and `DealStage`. Your exhaustive `match`es
will show you where else `Converted` needs handling.

`Lead::builder(id, name, email)` takes an **id**, which only made sense when `InMemoryRepo`
handed them out. Change the builder to produce an id-less `NewLead` (this replaces Lab 29's
private `LeadInput`):

```rust
/// A lead that hasn't been saved yet. New leads always start as `New`.
#[derive(Debug, Clone, PartialEq)]
pub struct NewLead {
    pub name: String,
    pub email: Email,
    pub company_name: Option<String>,
    pub source: LeadSource,
    pub notes: Option<String>,
}

impl NewLead {
    pub fn builder(name: impl Into<String>, email: Email) -> LeadBuilder {
        LeadBuilder {
            name: name.into(),
            email,
            company_name: None,
            source: LeadSource::Other,
            notes: None,
        }
    }
}
```

Remove the `id` field from `LeadBuilder`, and make `build(self) -> Result<NewLead, ValidationError>`.
The builder's *logic* (validation, defaults, `mem::take` tricks) doesn't change.

> 🟢 **FOLLOW ALONG**: `src/leads/db.rs` (add `pub mod db;` to `src/leads/mod.rs`)

```rust
//! Lead persistence.

use sqlx::PgExecutor;

use super::{Lead, LeadId, LeadStatus, NewLead};
use crate::contacts::Email;
use crate::database::corrupt;
use crate::errors::CrmError;

struct LeadRow {
    id: i64,
    name: String,
    email: String,
    company_name: Option<String>,
    source: String,
    status: String,
    notes: Option<String>,
}

impl TryFrom<LeadRow> for Lead {
    type Error = sqlx::Error;

    fn try_from(row: LeadRow) -> Result<Self, Self::Error> {
        Ok(Lead {
            id: LeadId(row.id),
            name: row.name,
            email: Email::try_from(row.email).map_err(corrupt)?,
            company_name: row.company_name,
            source: row.source.parse().map_err(corrupt)?,
            status: row.status.parse().map_err(corrupt)?,
            notes: row.notes,
        })
    }
}

fn not_found(id: LeadId) -> CrmError {
    CrmError::NotFound { entity: "lead", id: id.0 }
}

pub async fn insert(db: impl PgExecutor<'_>, new: &NewLead) -> Result<Lead, CrmError> {
    let row = sqlx::query_as!(
        LeadRow,
        "INSERT INTO leads (name, email, company_name, source, notes)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, name, email, company_name, source, status, notes",
        new.name,
        new.email.as_str(),
        new.company_name,
        new.source.to_string(),
        new.notes,
    )
    .fetch_one(db)
    .await?;
    Ok(row.try_into()?)
}

pub async fn get(db: impl PgExecutor<'_>, id: LeadId) -> Result<Lead, CrmError> {
    let row = sqlx::query_as!(
        LeadRow,
        "SELECT id, name, email, company_name, source, status, notes
         FROM leads WHERE id = $1",
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

/// Like `get`, but locks the row until the surrounding transaction ends.
/// Only meaningful inside a transaction (`&mut *tx`).
pub async fn get_for_update(db: impl PgExecutor<'_>, id: LeadId) -> Result<Lead, CrmError> {
    let row = sqlx::query_as!(
        LeadRow,
        "SELECT id, name, email, company_name, source, status, notes
         FROM leads WHERE id = $1
         FOR UPDATE",
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

pub async fn list(db: impl PgExecutor<'_>) -> Result<Vec<Lead>, CrmError> {
    let rows = sqlx::query_as!(
        LeadRow,
        "SELECT id, name, email, company_name, source, status, notes
         FROM leads ORDER BY id"
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(Lead::try_from).collect::<Result<_, _>>()?)
}

pub async fn set_status(
    db: impl PgExecutor<'_>,
    id: LeadId,
    status: LeadStatus,
) -> Result<Lead, CrmError> {
    let row = sqlx::query_as!(
        LeadRow,
        "UPDATE leads SET status = $2 WHERE id = $1
         RETURNING id, name, email, company_name, source, status, notes",
        id.0,
        status.to_string(),
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

## Step 6 — Lead conversion in one transaction

### First, the domain: deciding without ids

Lab 19's `Lead::convert(self, ids: ConversionIds, deal)` needed the three new ids **before**
building anything, and `InMemoryRepo::next_id` could hand them out. Postgres hands out ids *during*
the `INSERT`s, inside the transaction. So split "decide" from "write": the pure part becomes a
**plan**.

> 🟢 **FOLLOW ALONG**: in `src/leads/model.rs`, replace `convert`, `ConversionIds`,
> `Conversion` and `ConvertError` with:

```rust
/// Everything a conversion will create, decided up front and without ids:
/// the database hands out ids inside the conversion transaction.
#[derive(Debug, Clone, PartialEq)]
pub struct ConversionPlan {
    pub company: NewCompany,
    pub contact_name: String,
    pub contact_email: Email,
    pub deal: Option<NewDealInput>,
}

impl ConversionPlan {
    pub fn contact(&self, company_id: CompanyId) -> NewContact {
        NewContact {
            name: self.contact_name.clone(),
            email: self.contact_email.clone(),
            phone: None,
            company_id: Some(company_id),
        }
    }
}

impl Lead {
    /// The business rules of conversion, with no storage involved.
    pub fn plan_conversion(&self, deal: Option<NewDealInput>) -> Result<ConversionPlan, CrmError> {
        if self.status != LeadStatus::Qualified {
            return Err(CrmError::LeadNotQualified(self.id));
        }
        if let Some(d) = &deal {
            d.validate()?;
        }
        let company_name = self
            .company_name
            .clone()
            .unwrap_or_else(|| format!("{} (individual)", self.name));
        Ok(ConversionPlan {
            company: NewCompany {
                name: company_name,
                website: None,
            },
            contact_name: self.name.clone(),
            contact_email: self.email.clone(),
            deal,
        })
    }
}
```

Port your Lab 19 unit tests: "unqualified lead is rejected", "missing company name becomes
`<name> (individual)`" and the rest. The *assertions* barely change. The rules were never about
storage.

And what happened to `ConvertError { lead, reason }`, the type that **handed the lead back** on
failure (Lab 19's ownership lesson)? `convert(self)` consumed the lead because it had been
*removed* from the repository, so failure had to return it or it was gone. Now the lead row stays
in the table the whole time. If anything fails, the **transaction** puts everything back. The
transaction does the job `ConvertError` did, for every row involved, not just the lead.

### Then the service: a transaction

> 🟢 **FOLLOW ALONG**: `src/leads/service.rs` (add `pub mod service;` and
> `pub use service::ConversionSummary;` to `src/leads/mod.rs`)

```rust
//! Lead conversion: several writes that must happen together or not at all.

use serde::Serialize;
use sqlx::PgPool;

use super::{LeadId, LeadStatus};
use crate::companies::{self, CompanyId};
use crate::contacts::{self, ContactId};
use crate::deals::{self, DealId, NewDealInput};
use crate::errors::CrmError;
use crate::leads;

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct ConversionSummary {
    pub company_id: CompanyId,
    pub contact_id: ContactId,
    pub deal_id: Option<DealId>,
}

pub async fn convert_lead(
    pool: &PgPool,
    id: LeadId,
    deal: Option<NewDealInput>,
) -> Result<ConversionSummary, CrmError> {
    let mut tx = pool.begin().await?;

    // Lock the lead: a second, concurrent conversion waits here.
    let lead = leads::db::get_for_update(&mut *tx, id).await?;
    let plan = lead.plan_conversion(deal)?; // pure domain rules

    let company = companies::db::insert(&mut *tx, &plan.company).await?;
    let contact = contacts::db::insert(&mut *tx, &plan.contact(company.id)).await?;
    let deal_id = match plan.deal {
        Some(input) => {
            let deal = deals::db::insert(&mut *tx, &input.for_company(company.id)).await?;
            Some(deal.id)
        }
        None => None,
    };
    leads::db::set_status(&mut *tx, id, LeadStatus::Converted).await?;

    tx.commit().await?;
    Ok(ConversionSummary {
        company_id: company.id,
        contact_id: contact.id,
        deal_id,
    })
}
```

(`ConversionSummary` used to live in `crm.rs`. It moves here before `crm.rs` is deleted.)

### `&mut *tx`: a reborrow

`pool.begin()` checks out **one** connection and sends `BEGIN`. You get a
`Transaction<'static, Postgres>` that owns that connection. Everything that should be part of the
transaction must run **on that connection**.

> 🟡 **EXPERIMENT**: change the first call to `get_for_update(&mut tx, id)` (no `*`). Predict.

```text
error[E0277]: the trait bound `&mut Transaction<'_, Postgres>: PgExecutor<'_>` is not satisfied
   --> src/leads/service.rs:28:42
    |
 28 |     let lead = leads::db::get_for_update(&mut tx, id).await?;
    |                ------------------------- ^^^^^^^ the trait `Executor<'_>` is not implemented for `&mut Transaction<'_, Postgres>`
    |                |
    |                required by a bound introduced by this call
    |
help: the following other types implement trait `Executor<'c>`
    ...
379 |   impl<'c> Executor<'c> for &'c mut PgConnection {
    |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `&'c mut PgConnection` implements `Executor<'c>`
    ...
 12 | / impl<'p, DB: Database> Executor<'p> for &'_ Pool<DB>
```

The compiler lists exactly the two implementations from Step 2. A `Transaction` isn't one of them,
but it **derefs** to `PgConnection` (it implements `DerefMut<Target = PgConnection>`). So:

```text
tx             : Transaction<'static, Postgres>      (owns the connection)
*tx            : PgConnection                         (through DerefMut)
&mut *tx       : &'a mut PgConnection                 (a fresh exclusive borrow, for 'a)
```

`&mut *tx` is a **reborrow**: a new `&mut` to the connection, valid only for the duration of the
call (`'a`), after which `tx` is usable again. That's why you can write `&mut *tx` five times in a
row. Each borrow ends before the next begins, which is exactly what the borrow checker allows
(Lab 07). Passing `tx` itself would *move* it into the first call, and there'd be nothing left to
`commit`.

### Rollback is a `Drop`

Look at the error paths. Every `?` returns early, and `tx.commit()` is never reached. Nothing
calls "rollback". It doesn't need to: when `tx` goes out of scope uncommitted, its `Drop`
implementation rolls the transaction back. RAII again: in Lab 25 dropping a `MutexGuard` released a
lock. Here dropping a `Transaction` releases a transaction. You **can't** forget to roll back on
an error path, because there's no code to forget.

`commit(self)` takes `self` by value: after committing, `tx` is moved and can't be used by
accident. The type system encodes "a transaction ends exactly once".

### `FOR UPDATE`: the pessimistic lock

Two concurrent requests convert lead 7. Without a lock, both read `status = 'qualified'`, both
create a company, and lead 7 now has two customers. `SELECT ... FOR UPDATE` locks the lead's row
until this transaction ends. The second request **waits** at `get_for_update`, then reads the
*committed* status (`converted`) and `plan_conversion` refuses with `LeadNotQualified`. The
Experiment section lets you watch it block.

## Step 7 — Activities: subjects and JSONB

> 🟢 **FOLLOW ALONG**: give `Subject` (in `src/subject.rs`) a way in and out of its two columns,
> and reuse it in `FromStr`/`Display`:

```rust
impl Subject {
    /// The `subject_type` column value.
    pub fn kind(&self) -> &'static str {
        match self {
            Subject::Company(_) => "company",
            Subject::Contact(_) => "contact",
            Subject::Deal(_) => "deal",
        }
    }

    /// The `subject_id` column value.
    pub fn id(&self) -> i64 {
        match self {
            Subject::Company(id) => id.0,
            Subject::Contact(id) => id.0,
            Subject::Deal(id) => id.0,
        }
    }

    /// Rebuilds a subject from its two columns.
    pub fn from_parts(kind: &str, id: i64) -> Result<Subject, String> {
        match kind {
            "company" => Ok(Subject::Company(CompanyId(id))),
            "contact" => Ok(Subject::Contact(ContactId(id))),
            "deal" => Ok(Subject::Deal(DealId(id))),
            other => Err(format!("unknown subject type: {other}")),
        }
    }
}
```

The database can't check that a subject exists, so `src/database/mod.rs` does. It needs
`use crate::errors::CrmError;`, `use crate::subject::Subject;` and `PgExecutor`:

```rust
/// Activities and notes point at a polymorphic subject, which the database
/// can't enforce with a foreign key - so we check it ourselves.
pub async fn ensure_subject_exists(
    db: impl PgExecutor<'_>,
    subject: Subject,
) -> Result<(), CrmError> {
    let exists = match subject {
        Subject::Company(id) => {
            sqlx::query_scalar!(
                r#"SELECT EXISTS (SELECT 1 FROM companies WHERE id = $1) AS "exists!""#,
                id.0
            )
            .fetch_one(db)
            .await?
        }
        Subject::Contact(id) => {
            sqlx::query_scalar!(
                r#"SELECT EXISTS (SELECT 1 FROM contacts WHERE id = $1) AS "exists!""#,
                id.0
            )
            .fetch_one(db)
            .await?
        }
        Subject::Deal(id) => {
            sqlx::query_scalar!(
                r#"SELECT EXISTS (SELECT 1 FROM deals WHERE id = $1) AS "exists!""#,
                id.0
            )
            .fetch_one(db)
            .await?
        }
    };
    if exists {
        Ok(())
    } else {
        Err(CrmError::NotFound {
            entity: subject.kind(),
            id: subject.id(),
        })
    }
}
```

`db` is *moved* in each arm, and the compiler accepts that because only one arm ever runs. Moves
are tracked per control-flow path. Three static queries, not one built with `format!`: table
names can't be bind parameters, and Lab 32 shows what happens when people build SQL with
`format!`.

In `src/activities/model.rs`, add the id-less input and the `kind` column value:

```rust
impl ActivityKind {
    /// The `kind` column value (same spelling as the serde tag).
    pub fn name(&self) -> &'static str {
        match self {
            ActivityKind::Call { .. } => "call",
            ActivityKind::Email { .. } => "email",
            ActivityKind::Meeting { .. } => "meeting",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewActivity {
    pub subject: Subject,
    pub kind: ActivityKind,
    pub summary: String,
    pub occurred_at: DateTime<Utc>,
}
```

> 🟢 **FOLLOW ALONG**: `src/activities/db.rs`. SQLx's `json` feature is on by default, which
> gives you `sqlx::types::Json<T>`.

```rust
//! Activity persistence. `kind` + `details` (JSONB) store the ActivityKind enum.

use chrono::{DateTime, Utc};
use sqlx::types::Json;
use sqlx::{PgExecutor, PgPool};

use super::{Activity, ActivityId, ActivityKind, NewActivity};
use crate::database::{corrupt, ensure_subject_exists};
use crate::errors::CrmError;
use crate::subject::Subject;

struct ActivityRow {
    id: i64,
    subject_type: String,
    subject_id: i64,
    details: Json<ActivityKind>,
    summary: String,
    occurred_at: DateTime<Utc>,
}

impl TryFrom<ActivityRow> for Activity {
    type Error = sqlx::Error;

    fn try_from(row: ActivityRow) -> Result<Self, Self::Error> {
        Ok(Activity {
            id: ActivityId(row.id),
            subject: Subject::from_parts(&row.subject_type, row.subject_id).map_err(corrupt)?,
            kind: row.details.0,
            summary: row.summary,
            occurred_at: row.occurred_at,
        })
    }
}

/// Checks the subject, then inserts: two statements, so it takes the pool.
pub async fn insert(pool: &PgPool, new: &NewActivity) -> Result<Activity, CrmError> {
    ensure_subject_exists(pool, new.subject).await?;
    let row = sqlx::query_as!(
        ActivityRow,
        r#"INSERT INTO activities (subject_type, subject_id, kind, details, summary, occurred_at)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING id, subject_type, subject_id,
                     details AS "details: Json<ActivityKind>", summary, occurred_at"#,
        new.subject.kind(),
        new.subject.id(),
        new.kind.name(),
        Json(&new.kind) as _,
        new.summary,
        new.occurred_at,
    )
    .fetch_one(pool)
    .await?;
    Ok(row.try_into()?)
}

/// Newest first.
pub async fn list_for_subject(
    db: impl PgExecutor<'_>,
    subject: Subject,
) -> Result<Vec<Activity>, CrmError> {
    let rows = sqlx::query_as!(
        ActivityRow,
        r#"SELECT id, subject_type, subject_id,
                  details AS "details: Json<ActivityKind>", summary, occurred_at
           FROM activities
           WHERE subject_type = $1 AND subject_id = $2
           ORDER BY occurred_at DESC, id DESC"#,
        subject.kind(),
        subject.id(),
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Activity::try_from)
        .collect::<Result<_, _>>()?)
}
```

- **`Json<T>`** is a wrapper meaning "encode/decode this through serde as JSON". Your Lab 21
  `#[serde(tag = "type", rename_all = "snake_case")]` on `ActivityKind` decides the JSON shape:
  `{"type":"call","minutes":25}`.
- **`details AS "details: Json<ActivityKind>"`** overrides the output type. Without it the macro
  would decode JSONB as a generic `serde_json::Value`.
- **`Json(&new.kind) as _`** is the matching input override: "bind this, and trust that it
  encodes as `$4`'s type". It borrows: `Json<&ActivityKind>` serialises without cloning.
- **`TIMESTAMPTZ` ↔ `DateTime<Utc>`** comes from the `chrono` feature you enabled in Lab 30.
- `ensure_subject_exists` then `INSERT` is check-then-act: a subject deleted between the two
  leaves a dangling activity. That's the price of the polymorphic-subject choice in Step 3. For a
  CRM's activity log it's acceptable. For money it wouldn't be.

## Step 8 — Handlers on the pool, `AppState { pool }`

> 🟢 **FOLLOW ALONG**: `src/http/state.rs` becomes tiny:

```rust
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
}
```

The handlers follow the pattern you know from Lab 30: validate, one repository (or service) call,
map to the response. The interesting ones:

```rust
// src/http/leads.rs
async fn qualify_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<LeadResponse>, ApiError> {
    let mut lead = leads::db::get(&state.pool, LeadId(id)).await?;
    lead.qualify()?; // the domain decides; the database records
    let lead = leads::db::set_status(&state.pool, lead.id, lead.status).await?;
    Ok(Json(LeadResponse::from(&lead)))
}

async fn convert_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<ConvertLeadRequest>,
) -> Result<(StatusCode, Json<ConversionResponse>), ApiError> {
    let deal = req.deal.map(|d| NewDealInput {
        title: d.title,
        value: Money::from_cents(d.value_cents),
    });
    let summary = leads::service::convert_lead(&state.pool, LeadId(id), deal).await?;
    Ok((StatusCode::CREATED, Json(ConversionResponse::from(summary))))
}

// src/http/deals.rs
async fn create_deal(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateDealRequest>,
) -> Result<(StatusCode, Json<DealResponse>), ApiError> {
    let input = NewDealInput {
        title: req.title.trim().to_string(),
        value: Money::from_cents(req.value_cents),
    };
    input.validate().map_err(CrmError::from)?;
    let deal =
        deals::db::insert(&state.pool, &input.for_company(CompanyId(req.company_id))).await?;
    Ok((StatusCode::CREATED, Json(DealResponse::from(&deal))))
}

async fn move_deal(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<MoveDealRequest>,
) -> Result<Json<DealResponse>, ApiError> {
    let deal = deals::db::move_stage(&state.pool, DealId(id), req.stage).await?;
    Ok(Json(DealResponse::from(&deal)))
}

// src/http/activities.rs
async fn create_activity(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateActivityRequest>,
) -> Result<(StatusCode, Json<ActivityResponse>), ApiError> {
    let new = NewActivity {
        subject: parse_subject(&req.subject)?,
        kind: req.kind,
        summary: req.summary,
        occurred_at: req.occurred_at.unwrap_or_else(Utc::now),
    };
    let activity = activities::db::insert(&state.pool, &new).await?;
    Ok((StatusCode::CREATED, Json(ActivityResponse::from(&activity))))
}
```

Adapt the rest yourself (they're mechanical): `list_leads`, `create_lead` (keep your Lab 28
validation, which now ends in `NewLead::builder(...)...build()` and `leads::db::insert`),
`get_lead`, `disqualify_lead`, `list_deals`, `get_deal`, `list_activities`
(`activities::db::list_for_subject`). `ConversionResponse` (Lab 29) gets a
`From<ConversionSummary>` that unwraps the three ids. `parse_subject` stands for however your
Lab 29 code turns `"deal:3"` into a `Subject` with a 422 on failure (e.g. `SubjectQuery::parse`).
For `/pipeline`, notes and `/history`, leave the old bodies in place until the Your Turn tasks.

`main.rs` loses the JSON storage: build `AppState { pool }` right after `database::migrate`.

```bash
git add .
git commit -m "Move deals, leads, activities and notes to Postgres"
```

(Commit once Your Turns 1–3 compile. Until then `state.crm` still exists for them.)

## Step 9 — Retire the JSON storage

> 🟢 **FOLLOW ALONG**

```bash
git rm -r src/storage src/crm.rs src/repo.rs
```

Remove `pub mod storage;`, `pub mod crm;` and `pub mod repo;` from `src/lib.rs`, delete
`From<StorageError> for ApiError` and `AppState::persist`, drop `crm-data.json` from `.gitignore`
(and from disk), and run `cargo check`. Each error points at a leftover reference.

**The `Entity` trait.** It existed so that `InMemoryRepo<T: Entity>` could ask any entity for its
id. With `InMemoryRepo` gone, nothing is generic over `Entity` any more. A trait with no generic
consumer is dead weight (Step 1's rule again), so delete it and its six `impl`s. If your `Display`
impls called `.label()`, inline what it did. `Validate` stays: handlers call it.

**Integration tests.** `tests/common/mod.rs`, `tests/lead_conversion.rs`, `tests/pipeline.rs` and
`tests/persistence.rs` all built a `Crm`. Delete them. The behaviour they protected comes back as
database tests in Lab 33, and lead conversion gets *better* tests there (including rollback).
`tests/validation.rs` only touches domain types and stays. `cargo remove --dev tempfile` (nothing
writes temporary files any more).

**If you did Challenge D (tags)**, porting it is optional: a `tags` table plus
`company_tags` / `contact_tags` join tables with composite primary keys. No later lab depends on it.

### What survived

```bash
cargo test --lib
```

Look at the list: `Email` parsing, `Money` parsing and formatting, `DealStage` transitions,
`Deal::move_to`, `Lifecycle` round-trips, the conversion rules... all still passing,
**unmodified** except for the conversion tests you ported. You replaced the entire storage layer
(in-memory → JSON → Postgres) and the business rules didn't notice. That's the payoff of Lab 14's
rule ("business logic lives in the domain, not in the interface") and of Lab 20's "pass `now` in
as a parameter". Pure functions don't care where data comes from.

## Step 10 — Tests: almost everything needs a database now

`tests/api/helpers.rs` gets simpler:

```rust
/// A *lazy* pool parses the URL but doesn't connect until the first query
/// runs. Since Lab 31 almost every test reaches the database, so they're
/// #[ignore]d until Lab 33 gives each test a real database.
pub fn app() -> Router {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://crm:crm@localhost:5432/crm")
        .expect("valid database URL");
    router(AppState { pool })
}
```

Mark the lead and deal API tests `#[ignore = "needs database; restored in Lab 33"]`. Only
validation-failure tests still run. That's uncomfortable, and it should be. Lab 33 fixes it
properly.

---

## ▶️ Run It
With the Your Turns done:

```bash
sqlx database reset -y    # fresh dev database; replays every migration
cargo run
```

```bash
curl -s -X POST localhost:3000/leads -H 'content-type: application/json' \
  -d '{"name":"Grace Hopper","email":"grace@navy.test","company_name":"US Navy","source":"referral"}'
curl -s -i -X POST localhost:3000/leads/1/convert -H 'content-type: application/json' -d '{}'
curl -s -X POST localhost:3000/leads/1/qualify
curl -s -X POST localhost:3000/leads/1/convert -H 'content-type: application/json' \
  -d '{"deal":{"title":"Compiler pilot","value_cents":2500000}}'
curl -s localhost:3000/leads/1
curl -s -X POST localhost:3000/deals/1/stage -H 'content-type: application/json' -d '{"stage":"proposal"}'
curl -s -i -X POST localhost:3000/deals/1/stage -H 'content-type: application/json' -d '{"stage":"qualification"}'
curl -s localhost:3000/pipeline
curl -s -X POST localhost:3000/activities -H 'content-type: application/json' \
  -d '{"subject":"deal:1","kind":{"type":"call","minutes":25},"summary":"Discovery call","occurred_at":"2026-10-05T09:30:00Z"}'
curl -s -X POST localhost:3000/notes -H 'content-type: application/json' \
  -d '{"subject":"deal:1","body":"Wants a pilot before Q1"}'
curl -s 'localhost:3000/history?subject=deal:1'
curl -s -i -X DELETE localhost:3000/companies/1
```

## ✅ Expected Result
```text
{"id":1,"name":"Grace Hopper","email":"grace@navy.test","company_name":"US Navy","source":"referral","status":"new","notes":null}

HTTP/1.1 409 Conflict
{"error":{"code":"conflict","message":"lead #1 is not qualified"}}

{"id":1,"name":"Grace Hopper","email":"grace@navy.test","company_name":"US Navy","source":"referral","status":"qualified","notes":null}

{"company_id":1,"contact_id":1,"deal_id":1}

{"id":1,"name":"Grace Hopper","email":"grace@navy.test","company_name":"US Navy","source":"referral","status":"converted","notes":null}

{"id":1,"company_id":1,"title":"Compiler pilot","value_cents":2500000,"stage":"proposal"}

HTTP/1.1 409 Conflict
{"error":{"code":"invalid_transition","message":"cannot move a deal from proposal to qualification"}}

[{"stage":"qualification","count":0,"total_cents":0},{"stage":"proposal","count":1,"total_cents":2500000},{"stage":"negotiation","count":0,"total_cents":0},{"stage":"won","count":0,"total_cents":0},{"stage":"lost","count":0,"total_cents":0}]

{"id":1,"subject":"deal:1","kind":{"type":"call","minutes":25},"summary":"Discovery call","occurred_at":"2026-10-05T09:30:00Z"}

{"id":1,"subject":"deal:1","body":"Wants a pilot before Q1","created_at":"2026-10-05T14:43:09.046606Z"}

[{"type":"note","id":1,"at":"2026-10-05T14:43:09.046606Z","text":"Wants a pilot before Q1"},{"type":"activity","id":1,"at":"2026-10-05T09:30:00Z","text":"Discovery call"}]

HTTP/1.1 409 Conflict
{"error":{"code":"conflict","message":"company #1 still has contacts"}}
```

The conversion answers `201 Created` (Lab 29's status). Timestamps and the exact message wording
depend on your Lab 18/29 code. Restart the server: everything is still there.

## 🧠 Understand It

**Two kinds of concurrency control.** `move_stage` is *optimistic*: no lock, and the write is
conditional (`WHERE stage = $old`). It's cheap and good when conflicts are rare and retrying is
fine. `convert_lead` is *pessimistic*: `FOR UPDATE` locks the row so the conflict can't happen. It
costs waiting, and it's good when the operation is expensive and must not run twice.

**Where each rule lives now.**

| Rule | Lives in | Why there |
|---|---|---|
| Only qualified leads convert | `Lead::plan_conversion` (Rust) | business rule; unit-tested without a DB |
| Conversion is all-or-nothing | transaction (`begin`/`commit`/`Drop`) | only the database can make several writes atomic |
| Two conversions don't both win | `FOR UPDATE` | only the database sees both requests |
| Deal stages move legally | `DealStage::can_transition_to` (Rust) | business rule |
| No lost stage updates | `WHERE stage = $old` | concurrency, so the database |
| Deal's company exists | foreign key | integrity, so the database |
| Activity's subject exists | `ensure_subject_exists` (Rust) | the schema can't express it (Step 3) |

**Lifetimes you didn't write.** `impl PgExecutor<'_>` hides a lifetime parameter.
`fn get(db: impl PgExecutor<'_>, ...)` is shorthand for
`fn get<'c, E: PgExecutor<'c>>(db: E, ...)`. The returned future borrows `db` for `'c`. When you
pass `&mut *tx`, `'c` is the short reborrow, and the future must finish (`.await`) before `tx` can
be used again. Try holding two un-awaited futures that both reborrow `tx` and the borrow checker
will refuse, for the same reason as two `&mut` to one `Vec`.

**Why `Transaction<'static, Postgres>`?** The `'c` on `Transaction<'c, DB>` is how long it
borrows its connection. `pool.begin()` gives a transaction that *owns* a pooled connection, so it
borrows nothing (`'static`). `conn.begin()` on a `&mut PgConnection` you already hold gives a
shorter one.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: watch a rollback.** Create a contact with `grace2@navy.test`, then a
> *qualified* lead with that same email and `"company_name":"Ghost Corp"`, and convert it.
> Predict the response, then check `GET /companies?search=ghost` and `GET /leads/<id>`.

```text
HTTP/1.1 409 Conflict
{"error":{"code":"conflict","message":"a contact with email grace2@navy.test already exists"}}
{"items":[],"page":1,"per_page":20,"total":0}
... "status":"qualified" ...
```

The company **was** inserted (the contact insert came after it), then rolled back when `?`
dropped `tx`. Now create any company: its id skips one. Identity sequences are deliberately
**not** transactional (otherwise every inserting transaction would block the others), so
rolled-back inserts leave gaps. Never use ids to count things.

> 🟡 **EXPERIMENT 2: forget to commit.** Comment out `tx.commit().await?;` and convert a lead.
> What does the HTTP response say? What's in the database? Which kind of bug is this: one the
> compiler can catch, or one only a test can catch? (Lab 33 writes that test.) Restore the line.

> 🟡 **EXPERIMENT 3: watch `FOR UPDATE` block.** Open two psql sessions
> (`docker compose exec db psql -U crm -d crm`, twice). In session A:

```sql
BEGIN;
SELECT id, status FROM leads WHERE id = 2 FOR UPDATE;
```

In session B run the same `SELECT ... FOR UPDATE`. It **hangs**. In A run
`UPDATE leads SET status = 'disqualified' WHERE id = 2; COMMIT;` and B immediately returns, showing
`disqualified`, the committed value, not the one it would have read before. That wait is what
makes a second concurrent `convert_lead` see `converted` and refuse. (`ROLLBACK;` in B when done.)

> 🟡 **EXPERIMENT 4: optimistic conflict by hand.** Put a `tokio::time::sleep(Duration::from_secs(5)).await`
> between `deal.move_to(next)?` and the `UPDATE` in `move_stage`, start a move with curl, and
> during the sleep change the stage in psql. What does curl get? Remove the sleep.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: notes on Postgres.**

- [ ] a migration `create_notes`: `notes(id, subject_type, subject_id, body, created_at)` with the
      same `subject_type` `CHECK` as activities, and a `CHECK` that `body` isn't blank
- [ ] `pub struct NewNote { pub subject: Subject, pub body: String }` in `src/notes/model.rs`
- [ ] `src/notes/db.rs` with
      `pub async fn insert(pool: &PgPool, new: &NewNote) -> Result<Note, CrmError>` (checks the
      subject exists, so 404 for `deal:99`) and
      `pub async fn list_for_subject(db: impl PgExecutor<'_>, subject: Subject) -> Result<Vec<Note>, CrmError>`
      (newest first, ties broken by id)
- [ ] `created_at` comes from the database (`DEFAULT now()`), not from the request
- [ ] `POST /notes` and `GET /notes?subject=` work as in Lab 29, with no `state.crm`

> 🔵 **YOUR TURN 2: history from the database.** `HistoryItem<'a>` lived in `crm.rs`, which is
> gone. Move it to a new `src/history.rs` (`pub mod history;` in `lib.rs`) with a pure function:
> ```rust
> pub fn merge<'a>(activities: &'a [Activity], notes: &'a [Note]) -> Vec<HistoryItem<'a>>
> ```

- [ ] newest first. `GET /history?subject=` uses the two `list_for_subject` functions + `merge`,
      and returns the same JSON as in Lab 29
- [ ] a unit test for `merge` with hand-built `Activity`/`Note` values (no database)
- [ ] be ready to explain the `'a` in the signature: why can the result not outlive either slice?

> 🔵 **YOUR TURN 3: the pipeline report without `Crm`.** `impl Crm { fn pipeline_report }` is gone.

- [ ] `pub fn pipeline_report(deals: &[Deal]) -> Vec<PipelineRow>` in `src/deals/report.rs`,
      re-exported as `deals::pipeline_report`: every stage, in stage order, even with no deals
- [ ] its Lab 18/24 tests ported to call the free function (add `PartialEq` to `PipelineRow`'s
      derives if it lacks it)
- [ ] `GET /pipeline` = `deals::db::list` + `pipeline_report`

Then: `cargo sqlx prepare`, `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test`.

## 💡 Hint
> 💡 **HINT**: Your Turns 1 and 2 are mostly Step 7 again. For Your Turn 3, start by asking what
> `pipeline_report` actually needed from `Crm`. Only the deals.

<details><summary>Hint 2 (more specific)</summary>

- Notes have no `kind`/`details`, so `NoteRow` is plain: `id, subject_type, subject_id, body,
  created_at` with `Subject::from_parts` in `TryFrom`.
- `merge`: `activities.iter().map(HistoryItem::Activity).chain(notes.iter().map(HistoryItem::Note))`,
  collect, then `sort_by_key(|i| std::cmp::Reverse(i.at()))`. A variant name like
  `HistoryItem::Activity` *is* a function `fn(&'a Activity) -> HistoryItem<'a>`.
- In the handler, the two `Vec`s must outlive the `Vec<HistoryItem<'_>>` that borrows from them:
  bind them to local variables before calling `merge`.
- `pipeline_report`: the Lab 18 `BTreeMap<DealStage, (usize, Money)>` pre-filled from
  `DealStage::ALL` (or however you listed every stage) still works. Only the input changed.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why is a trait with an `async fn` not dyn compatible? What would `#[async_trait]` change, and
   at what cost?
2. Why did this course choose plain functions over a repository trait? What would make you
   change that decision?
3. What do `&PgPool` and `&mut PgConnection` have in common, and why does `&mut tx` not compile
   where `&mut *tx` does?
4. In `convert_lead`, where exactly does the rollback happen if the contact insert fails? Which
   line of *your* code performs it?
5. What does `FOR UPDATE` prevent in `convert_lead`? What does `WHERE stage = $2` prevent in
   `move_stage`? Why use a lock in one and a conditional write in the other?
6. Name five pieces of code that survived the storage rewrite unchanged, and explain why they could.

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
(and `SQLX_OFFLINE=true cargo check`).

## Git Commit
You made the first commit at the end of Step 8.

```bash
git add .
git commit -m "Retire JSON storage"
git tag lab-31
git push && git push --tags
```

`git diff lab-30 lab-31 --stat` is worth a look: count how many lines of domain code changed
compared with storage and handler code.

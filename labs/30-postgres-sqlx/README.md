# Lab 30 — PostgreSQL & SQLx

> **Phase:** 9 — PostgreSQL · **Builds on:** Lab 29 · **Time:** ~6 hours
> **Your repo before this lab:** tag `lab-29` · **After:** tag `lab-30`

## 🎯 Goal
Retire the terminal CLI, start a real PostgreSQL database in Docker, describe the schema with
versioned migrations, and move **companies and contacts** out of the JSON file and into Postgres,
using SQLx's compile-time checked queries.

## 🧠 What You'll Learn
- Why a server application outgrows "load the whole JSON file, save the whole JSON file"
- Docker Compose for a development database, `DATABASE_URL`, `.env` and `dotenvy`
- `sqlx-cli`: creating databases and writing **migrations** (and why you never edit an old one)
- Designing a schema *from your domain types*: `Option` ↔ `NULL`, enums ↔ `TEXT` + `CHECK`, IDs ↔ foreign keys
- Why every ID newtype becomes `i64`, and what `#[derive(sqlx::Type)] #[sqlx(transparent)]` does
- Connection pools (`PgPool`): what they are and why they're cheap to clone
- `query!` / `query_as!`: what the macros do **while your code compiles**, and the errors they give you
- Offline mode: the `.sqlx/` query cache and `SQLX_OFFLINE=true`
- Row structs + `TryFrom<Row>` so data coming *out* of the database is re-validated
- Turning a unique-constraint violation into `CrmError::DuplicateEmail`
- A deliberate **strangler migration**: half the app on Postgres, half still on JSON, for one lab

## 🔨 What We're Building
At the end of Lab 29 you had one binary serving a REST API, plus a second binary (`crm-cli`), both
reading and writing the same `crm-data.json`. In this lab:

```text
BEFORE (lab-29)                              AFTER (lab-30)

crm-cli ──┐                                  curl / HTTP clients
          ├─► Crm (in memory) ─► crm-data.json        │
server  ──┘                                       axum server
                                              ┌───────┴──────────────┐
                                              │ companies, contacts  │ deals, leads,
                                              ▼                      ▼ activities, notes
                                          PostgreSQL           Crm + crm-data.json
                                                                (until Lab 31)
```

The CLI is deleted. Companies and contacts live in Postgres. Everything else keeps working on the
old JSON storage for one more lab. That split is on purpose, and Step 9 explains why.

> **About your Lab 29 code.** This lab uses the names from Labs 27–29:
> `ApiError::{Domain, Validation, BadRequest, Internal}` with its `status_and_code()` method,
> `FieldError { field: &'static str, message }`, the `AppJson` / `AppPath` / `AppQuery` extractors
> from `src/http/extract.rs`, `Pagination { page, per_page }` with `normalized()`,
> `Page<T> { items, page, per_page, total }`, the domain inputs `NewCompany`, `CompanyUpdate` and
> `NewContact`, and the test helpers in `tests/api/helpers.rs`. If you named something
> differently, keep your name. Only the *bodies* shown here matter.

---

## Step 1 — Why a database? Write it down first

You're about to delete working code: a whole binary and a storage layer you built over five
labs. Before deleting anything, write down **why**. Engineers who can explain why they changed an
architecture make better decisions than engineers who just follow fashion.

Here's what's wrong with `crm-data.json` now that the CRM is a server.

1. **Concurrent writers lose data.** The server and `crm-cli` each load the file at startup, keep
   their own copy in memory and write the **whole snapshot** back. Whoever saves last wins and
   silently erases the other's changes. That's a *lost update*. Two server instances behind a
   load balancer would have exactly the same problem.
2. **Every change rewrites everything.** Adding one note serialises every company, contact, deal
   and activity. That's O(size of the CRM) for an O(1) change.
3. **No querying.** "Contacts at company 3 whose name contains 'ada'" means loading *everything*
   into memory and filtering with iterators. That works for 50 contacts. It doesn't work for 100,000.
4. **Integrity lives only in our code.** "A contact's company must exist" and "emails are unique"
   are enforced by `Crm`'s methods. Anything else that touches the file (a script, a bug, a manual
   edit) can break those rules.
5. **Atomicity is per file, not per business operation.** Lab 21's write-then-rename protects
   the file from half-written saves. It can't make "create company + contact + deal" one
   all-or-nothing operation across concurrent requests.
6. **Memory.** The whole CRM must fit in RAM, in every process.

A relational database solves exactly these problems: concurrent access with transactions,
row-level writes, a query language with indexes, and constraints the database itself enforces.

And why retire the CLI instead of porting it?

- The product is now the **HTTP API**. `curl` (and later a web front-end) replaces the REPL.
- Two front-ends means every feature is built twice, for no new learning.
- Nothing valuable is lost. In Lab 14 you made a rule that `cli/commands.rs` only parses, prompts
  and prints, and that business logic lives in the domain. The domain is staying. Only the
  printing goes.

> 🟡 **EXPERIMENT** (optional, *before* deleting the CLI): predict first. Start the server
> (`cargo run`), then in a second terminal start `cargo run --bin crm-cli` and add a company there.
> Now `POST /companies` with curl, then quit the CLI. Which company is still in `crm-data.json`?
> Restart the server and `GET /companies`. You've just reproduced reason 1.

> 🔵 **YOUR TURN** (writing, not code): add a `## Why PostgreSQL?` section to **your** repo's
> `README.md`, with 3–6 bullet points in your own words. You'll come back to it in Lab 40.

## Step 2 — Retire the terminal CLI

> 🟢 **FOLLOW ALONG**

```bash
git rm -r src/bin/crm-cli.rs src/cli
cargo remove clap
```

Remove `pub mod cli;` from `src/lib.rs`. In `Cargo.toml`, delete the `default-run = "rust-crm"`
line from Lab 27: with one binary there's nothing to choose between.

`CrmError::UnknownCommand` and `CrmError::Usage` only existed for the REPL. Delete both variants
from `src/errors.rs`. (If you moved them into a `cli::CliError` in Lab 22, they've already gone
with `src/cli/`.) Then ask the compiler what else knew about them:

```bash
cargo check
```

```text
error[E0599]: no variant, associated function, or constant named `UnknownCommand` found for enum `CrmError` in the current scope
  --> src/http/error.rs:58:31
   |
58 |                     CrmError::UnknownCommand(_) | CrmError::Usage(_) => {
   |                               ^^^^^^^^^^^^^^ variant, associated function, or constant not found in `CrmError`
   |
  ::: src/errors.rs:18:1
   |
18 | pub enum CrmError {
   | ----------------- variant, associated function, or constant `UnknownCommand` not found for this enum
```

The only place is the `match` in `ApiError::status_and_code` (your line numbers will differ).
Delete that arm. This is the payoff of exhaustive matching: deleting a variant gives you a complete to-do list.

```bash
cargo clippy --all-targets && cargo test
git add .
git commit -m "Retire terminal CLI

The HTTP API is now the only interface. The CLI and the server shared
crm-data.json and overwrote each other's changes (lost updates); a
database fixes that properly. Domain logic is unchanged."
```

That commit message is part of the exercise: future-you will read it in `git log`.

## Step 3 — PostgreSQL in Docker Compose

Make sure Docker Desktop is running. You'll run Postgres in a container **for development
only**. Production databases are a deployment concern (Lab 40).

> 🟢 **FOLLOW ALONG**: create `docker-compose.yml` in your repo root.

```yaml
services:
  db:
    image: postgres:17
    environment:
      POSTGRES_USER: crm
      POSTGRES_PASSWORD: crm
      POSTGRES_DB: crm
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U crm -d crm"]
      interval: 2s
      timeout: 5s
      retries: 10

volumes:
  pgdata:
```

- `image: postgres:17` pins a major version so everyone (and CI in Lab 33) runs the same one.
- `POSTGRES_*` create a user and a database on first start. The user is a superuser in the
  container. That's fine for a dev box and it matters in Lab 33.
- `pgdata` is a **named volume**: your data survives `docker compose down`/`up`.
  `docker compose down -v` deletes it.

```bash
docker compose up -d
docker compose ps
docker compose exec db psql -U crm -d crm -c 'select version();'
```

Docker's output varies by version. You're looking for the `db` service to be `running (healthy)`
and for `psql` to print a `PostgreSQL 17.x` version string.

Now tell your code where the database is. Create **two** files:

`.env.example` (committed, documents what's needed):
```text
DATABASE_URL=postgres://crm:crm@localhost:5432/crm
```

`.env` (your local copy, **not** committed):
```bash
cp .env.example .env
echo ".env" >> .gitignore
```

`DATABASE_URL` is read by three different things in this lab: `sqlx-cli`, the `query!` macros
**at compile time**, and your server at runtime. All three also read `.env`.

## Step 4 — `sqlx-cli` and migrations

> 🟢 **FOLLOW ALONG**

```bash
cargo install sqlx-cli --no-default-features --features rustls,postgres
sqlx --version
sqlx database create
```

`--no-default-features --features rustls,postgres` builds the CLI with only the Postgres driver
and a pure-Rust TLS stack. That's faster to compile and has no OpenSSL headaches. This lab was
written against **sqlx 0.9** and **sqlx-cli 0.9**. If an API looks different, check docs.rs for
your version.

### Migrations are versioned history

A **migration** is a SQL file with a version number. `sqlx migrate run` applies, in order, every
migration the database hasn't seen yet, and records each one (with a checksum) in a table called
`_sqlx_migrations`. Your schema stops being "whatever's in the database right now" and becomes
**code with a history**, reviewed in pull requests and replayed identically on every machine.

```bash
sqlx migrate add create_companies
```

```text
Creating migrations/20261005143132_create_companies.sql
```

Your timestamp will differ. Open the file and replace its content.

### Designing the table from the domain type

Put `Company` (from `src/companies/model.rs`) next to the SQL and translate field by field:

| Rust | SQL | Why |
|---|---|---|
| `id: CompanyId` | `id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY` | the **database** hands out ids now (replaces `InMemoryRepo::next_id`) |
| `name: String` (non-empty, `Validate`) | `name TEXT NOT NULL CHECK (btrim(name) <> '')` | `String` → `NOT NULL`; the validation rule is repeated as a constraint |
| `website: Option<String>` | `website TEXT` (nullable) | `Option<T>` ↔ `NULL` |
| `lifecycle: Lifecycle` | `lifecycle TEXT NOT NULL DEFAULT 'prospect' CHECK (lifecycle IN (...))` | an enum becomes text with a closed set of values |
| (not in the domain) | `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` | bookkeeping the domain doesn't need |

```sql
-- Companies: one row per Company (src/companies/model.rs).
CREATE TABLE companies (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT        NOT NULL CHECK (btrim(name) <> ''),
    website    TEXT,
    lifecycle  TEXT        NOT NULL DEFAULT 'prospect'
                           CHECK (lifecycle IN ('prospect', 'customer', 'churned')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

> Why `TEXT` + `CHECK` rather than a Postgres `ENUM` type? Adding a value to a Postgres enum is a
> special migration, and SQLx would need a custom type mapping. `TEXT` + `CHECK` is easy to evolve
> and maps straight onto `String` → `FromStr`. Both are defensible; this course picks the simpler one.

```bash
sqlx migrate run
sqlx migrate info
docker compose exec db psql -U crm -d crm -c '\d companies'
```

```text
Applied 20261005143132/migrate create companies (1.420916ms)
20261005143132/installed create companies
                                  Table "public.companies"
   Column   |           Type           | Collation | Nullable |           Default
------------+--------------------------+-----------+----------+------------------------------
 id         | bigint                   |           | not null | generated always as identity
 name       | text                     |           | not null |
 website    | text                     |           |          |
 lifecycle  | text                     |           | not null | 'prospect'::text
 created_at | timestamp with time zone |           | not null | now()
Indexes:
    "companies_pkey" PRIMARY KEY, btree (id)
Check constraints:
    "companies_lifecycle_check" CHECK (lifecycle = ANY (ARRAY['prospect'::text, 'customer'::text, 'churned'::text]))
    "companies_name_check" CHECK (btrim(name) <> ''::text)
```

> 🟡 **EXPERIMENT**: predict first. Add a comment line (`-- hello`) at the end of the migration
> you just applied, then run `sqlx migrate run` again.

```text
error: migration 20261005143132 was previously applied but has been modified
```

`sqlx migrate info` shows `installed (different checksum)`. An applied migration is a historical
fact: it already ran on your machine, and later on CI and production. Editing it means those
databases and a fresh one would end up different. **Never edit an applied migration. Add a new
one.** Undo your edit and `sqlx migrate run` is happy again. (During *local* development, before
pushing, `sqlx database reset` drops the database and replays everything. That's the honest way
to "edit history" while it's still only yours.)

### The contacts table

> ⚠️ Create migrations **one at a time**, as you need them. Versions are timestamps with
> one-second resolution, so two `sqlx migrate add` commands in the same second produce the same
> version and `migrate run` fails with
> `duplicate key value violates unique constraint "_sqlx_migrations_pkey"`.

```bash
sqlx migrate add create_contacts
```

```sql
-- Contacts: one row per Contact (src/contacts/model.rs).
CREATE TABLE contacts (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT        NOT NULL CHECK (btrim(name) <> ''),
    email      TEXT        NOT NULL UNIQUE,
    phone      TEXT,
    company_id BIGINT      REFERENCES companies (id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Look at what the schema says now:

- `company_id BIGINT REFERENCES companies (id)`: the `Option<CompanyId>` you chose in Lab 14
  becomes a **foreign key**, and nullable because the `Option` was. The Lab 14 decision to relate
  entities by ID rather than by `&Company` or `Rc<RefCell<Company>>` is exactly how relational
  databases relate rows. You were designing a schema then without knowing it.
- `ON DELETE RESTRICT`: Postgres refuses to delete a company that contacts still point at. That's
  `CrmError::HasContacts`, now enforced by the database.
- `email TEXT NOT NULL UNIQUE`: a *plain* unique constraint is enough because `Email::parse`
  always lowercases. `Ada@X.com` and `ada@x.com` can't both reach the database. Your Lab 12
  newtype just saved you a case-insensitive index.

```bash
sqlx migrate run
docker compose exec db psql -U crm -d crm -c '\d contacts'
```

```text
Indexes:
    "contacts_pkey" PRIMARY KEY, btree (id)
    "contacts_email_key" UNIQUE CONSTRAINT, btree (email)
Check constraints:
    "contacts_name_check" CHECK (btrim(name) <> ''::text)
Foreign-key constraints:
    "contacts_company_id_fkey" FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE RESTRICT
```

Note the constraint names Postgres generated: `contacts_email_key`, `contacts_company_id_fkey`.
You'll match on them in Rust.

```bash
git add migrations docker-compose.yml .env.example .gitignore
git commit -m "Add Postgres with migrations"
```

## Step 5 — Every ID becomes `i64`

Postgres has no unsigned integers. `BIGINT` is a signed 64-bit integer, which is Rust's `i64`. Your
ids have been `u64` since Lab 14. You could convert at the boundary, but then every `u64` above
`i64::MAX` would be a value your type allows and your database can't store. A type should describe
the values that can really exist, so the ids change type, **all of them** (companies, contacts,
deals, leads, activities, notes), even though only two tables exist yet. One refactor now beats
six later.

> 🟢 **FOLLOW ALONG**: in each `model.rs`, change the id newtype like this (shown for `CompanyId`):

```rust
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type,
)]
#[sqlx(transparent)]
pub struct CompanyId(pub i64);

impl From<i64> for CompanyId {
    fn from(id: i64) -> Self {
        CompanyId(id)
    }
}
```

`#[derive(sqlx::Type)] #[sqlx(transparent)]` says "in the database, a `CompanyId` is exactly its
inner `i64`". It lets SQLx encode and decode the newtype directly. You'll use that in Lab 32. To
derive it you need SQLx in `Cargo.toml`:

```bash
cargo add sqlx --features runtime-tokio,tls-rustls,postgres,macros,migrate,chrono
cargo add dotenvy
cargo check
```

Then let the compiler drive the rest. You'll get a few dozen errors. Two kinds matter:

```text
error[E0599]: the method `next_id` exists for struct `InMemoryRepo<Company>`, but its trait bounds were not satisfied
  --> src/crm.rs:59:32
   |
59 |             id: self.companies.next_id(),
   |                                ^^^^^^^ private field, not a method
   |
  ::: src/companies/model.rs:13:1
   |
13 | pub struct CompanyId(pub i64);
   | -------------------- doesn't satisfy `CompanyId: From<u64>`
...
note: trait bound `CompanyId: From<u64>` was not satisfied
  --> src/repo.rs:22:12
   |
20 | impl<T: Entity> InMemoryRepo<T>
   |                 ---------------
21 | where
22 |     T::Id: From<u64>,
   |            ^^^^^^^^^ unsatisfied trait bound introduced here
```

Read it the Lab 16 way. `next_id` lives in an `impl` block that only exists **where**
`T::Id: From<u64>`. You just replaced `From<u64>` with `From<i64>`, so for `InMemoryRepo<Company>`
that block (and the method) no longer exists. The fix isn't at the call site. It's the bound:
`next_id: i64` and `T::Id: From<i64>` in `src/repo.rs`. (`InMemoryRepo` still has a job until Lab 31.)

```text
error[E0308]: mismatched types
   --> src/http/companies.rs:110:41
    |
110 |     let c = crm.companies.get(CompanyId(id)).ok_or(not_found(id))?;
    |                               --------- ^^ expected `i64`, found `u64`
...
help: you can convert a `u64` to an `i64` and panic if the converted value doesn't fit
    |
110 |     let c = crm.companies.get(CompanyId(id.try_into().unwrap())).ok_or(not_found(id))?;
```

**Don't take that suggestion.** The id came from the path extractor (`AppPath<u64>` in your
code). Change the *source* to `AppPath<i64>`, and let the extractor reject garbage with a 400
before your code runs. Work through the list:

- `CrmError::NotFound { entity, id: i64 }` in `src/errors.rs`
- every `AppPath<u64>` → `AppPath<i64>`, every response DTO `id: u64` → `id: i64`, every request
  or query field like `company_id: Option<u64>` → `Option<i64>` (including `ContactQuery`)
- `Subject`'s `FromStr` parses an `i64`
- in `tests/api/helpers.rs`, `create_company` now returns `i64` (`body["id"].as_i64()`)

```bash
cargo check && cargo test
```

All green, still entirely on JSON. A refactor that only changes types and passes every test is
the safest kind there is.

## Step 6 — Connecting: a pool, migrations on startup

> 🟢 **FOLLOW ALONG**: create `src/database/mod.rs` and add `pub mod database;` to `src/lib.rs`.

```rust
//! Connecting to Postgres and running migrations.

use sqlx::PgPool;
use sqlx::migrate::MigrateError;
use sqlx::postgres::PgPoolOptions;

/// Opens a pool of up to 5 connections to `url`.
pub async fn connect(url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new().max_connections(5).connect(url).await
}

/// Applies every migration in `./migrations` that hasn't been applied yet.
pub async fn migrate(pool: &PgPool) -> Result<(), MigrateError> {
    sqlx::migrate!().run(pool).await
}

/// Wraps "this row can't become a domain value" as a decode error.
pub(crate) fn corrupt(e: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> sqlx::Error {
    sqlx::Error::Decode(e.into())
}
```

**What a pool is.** Opening a Postgres connection costs a TCP handshake, TLS, authentication and
a server process. You don't want that per request. A `PgPool` keeps up to `max_connections` open
connections. A query *borrows* one, uses it and gives it back. If all five are busy, the next
query waits (asynchronously, so no thread is blocked). Five is plenty for development. Lab 38
makes it configurable.

**Why `PgPool` goes in state by value.** `PgPool` is a handle around an `Arc`, so `clone()` copies
a pointer and bumps a reference count, the same idea as your `Arc<RwLock<Crm>>` from Lab 27. Every
clone shares the same connections.

**`sqlx::migrate!()`** reads `./migrations` **at compile time** and embeds the SQL in your binary.
The server can migrate a database on startup with no files next to it, which matters in Lab 40. It
also means a *new* migration file must trigger a rebuild. sqlx-cli generates the tiny build script
for that:

```bash
sqlx migrate build-script
```

```rust
// generated by `sqlx migrate build-script`
fn main() {
    // trigger recompilation when a new migration is added
    println!("cargo:rerun-if-changed=migrations");
}
```

**`corrupt`** is used in Step 8. It turns any error (a `String`, or a type implementing `Error`)
into `sqlx::Error::Decode`, which is SQLx's own "a value came back that I couldn't decode" error.
The `impl Into<Box<dyn Error + Send + Sync>>` parameter accepts both `String` and real error types
because the standard library provides `From` impls for both.

## Step 7 — A database error is a 500

> 🟢 **FOLLOW ALONG**: add a variant to `CrmError` in `src/errors.rs`.

```rust
    #[error("database error")]
    Database(#[from] sqlx::Error),
```

`#[from]` generates `impl From<sqlx::Error> for CrmError`, so `?` on any SQLx call inside a function
returning `Result<_, CrmError>` just works. `cargo check`:

```text
error[E0004]: non-exhaustive patterns: `&CrmError::Database(_)` not covered
  --> src/http/error.rs:47:44
   |
47 |                 let (status, code) = match &e {
   |                                            ^^ pattern `&CrmError::Database(_)` not covered
```

(In your code the `match` is inside `ApiError::status_and_code`. It has no wildcard arm, which is
exactly why this error appears.) Exhaustiveness again: a new error case can't be forgotten. But don't just map it to 500 inside
`Domain`. A database failure is **our** problem: the details belong in the log, and the client
gets a generic 500. That's exactly `ApiError::Internal` from Lab 28, so route it there when
converting:

```rust
impl From<CrmError> for ApiError {
    fn from(e: CrmError) -> Self {
        match e {
            // A database failure is our problem, not the client's: log it, answer 500.
            CrmError::Database(source) => ApiError::Internal(source.into()),
            other => ApiError::Domain(other),
        }
    }
}
```

The match in `status_and_code` still needs an arm to be exhaustive. Make it honest rather than
`unreachable!()`:

```rust
                    CrmError::Database(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
```

## Step 8 — Row structs and compile-time checked queries

Lab 28 already gave you the validated, id-less inputs the repository needs:
`NewCompany { name, website }` for creating and `CompanyUpdate { name, website, lifecycle }` for
`PUT`. That design pays off now: they're exactly the shape of an `INSERT` and an `UPDATE`.

Now the repository. Every SQL statement that touches `companies` lives in **one** file.

> 🟢 **FOLLOW ALONG**: create `src/companies/db.rs` and add `pub mod db;` to `src/companies/mod.rs`.

```rust
//! Company persistence: every SQL statement that touches `companies` lives here.

use sqlx::PgPool;

use super::{Company, CompanyFilter, CompanyId, CompanyUpdate, NewCompany};
use crate::database::corrupt;
use crate::errors::CrmError;

/// One row of `companies`, exactly as Postgres returns it.
/// Plain database types only: no newtypes, no enums, no validation.
struct CompanyRow {
    id: i64,
    name: String,
    website: Option<String>,
    lifecycle: String,
}

impl TryFrom<CompanyRow> for Company {
    type Error = sqlx::Error;

    fn try_from(row: CompanyRow) -> Result<Self, Self::Error> {
        Ok(Company {
            id: CompanyId(row.id),
            name: row.name,
            website: row.website,
            lifecycle: row.lifecycle.parse().map_err(corrupt)?,
        })
    }
}

fn not_found(id: CompanyId) -> CrmError {
    CrmError::NotFound {
        entity: "company",
        id: id.0,
    }
}

pub async fn insert(pool: &PgPool, new: &NewCompany) -> Result<Company, CrmError> {
    let row = sqlx::query_as!(
        CompanyRow,
        "INSERT INTO companies (name, website)
         VALUES ($1, $2)
         RETURNING id, name, website, lifecycle",
        new.name,
        new.website,
    )
    .fetch_one(pool)
    .await?;
    Ok(row.try_into()?)
}

pub async fn get(pool: &PgPool, id: CompanyId) -> Result<Company, CrmError> {
    let row = sqlx::query_as!(
        CompanyRow,
        "SELECT id, name, website, lifecycle FROM companies WHERE id = $1",
        id.0,
    )
    .fetch_optional(pool)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

Run `cargo check` **with Postgres running**. It compiles. Something unusual just happened.

### What `query_as!` does while you compile

`sqlx::query_as!` is a procedural macro: Rust code that runs **inside the compiler** and writes
code for you. For this macro, "running" means:

```text
cargo check
  └─ expands sqlx::query_as!(CompanyRow, "SELECT ... WHERE id = $1", id.0)
       1. reads DATABASE_URL (environment or .env)
       2. connects to Postgres and asks it to PREPARE the statement
          → Postgres parses it against the REAL schema and answers:
            parameter $1: INT8
            columns: id INT8 not null, name TEXT not null,
                     website TEXT nullable, lifecycle TEXT not null
       3. generates Rust code that binds `id.0` as an i64 and builds a CompanyRow
          from the row, field by field, BY NAME
       4. the generated code is type-checked like any other Rust code
```

So typos, missing columns, wrong parameter types and wrong nullability are **compile errors**.
Try it.

> 🟡 **EXPERIMENT 1**: predict, then `cargo check`. In `get`, misspell `name` as `nmae`.

```text
error: error returned from database: column "nmae" does not exist at line 3838
  --> src/companies/db.rs:50:15
   |
50 |       let row = sqlx::query_as!(
   |  _______________^
51 | |         CompanyRow,
52 | |         "SELECT id, nmae, website, lifecycle FROM companies WHERE id = $1",
53 | |         id.0,
54 | |     )
   | |_____^
```

That's **Postgres's** error message, delivered by the Rust compiler. (`at line 3838` is a line in
*Postgres's* C source, not your file. Your number may differ.) You'll also see some follow-on errors
because the macro produced no code. Fix the first error and they disappear.

> 🟡 **EXPERIMENT 2**: undo that. Now change `CompanyRow`'s field to `website: String` (not
> `Option`). Predict which line errors.

```text
error[E0277]: the trait bound `std::string::String: From<std::option::Option<std::string::String>>` is not satisfied
  --> src/companies/db.rs:36:15
   |
36 |       let row = sqlx::query_as!(
   |  _______________^
37 | |         CompanyRow,
38 | |         "INSERT INTO companies (name, website)
...  |
42 | |         new.website,
43 | |     )
   | |_____^ the trait `From<std::option::Option<std::string::String>>` is not implemented for `std::string::String`
```

The macro knows `website` is a nullable column, so the value it produces is an
`Option<String>`, and there's no way to turn that into a `String`. In the JSON world, a `null`
where you expected a string was a runtime error. Here it's a compile error. Every
`query_as!` in the file reports it.

> 🟡 **EXPERIMENT 3**: undo that. In `get`, pass `id` instead of `id.0`.

```text
error[E0308]: mismatched types
  --> src/companies/db.rs:53:9
   |
53 |         id,
   |         ^^
   |         |
   |         expected `i64`, found `CompanyId`
   |         expected due to the type of this binding
```

The macro checks **parameter** types too: `$1` is compared with `id` (an `INT8`), so it wants an
`i64`. `id.0` is the plain way. Because `CompanyId` derives `sqlx::Type` as `transparent`, you
may also write `id as CompanyId` inside the macro, which is SQLx's explicit "trust me, this type
encodes as `$1`'s type" override. There's a matching override for output columns
(`SELECT id AS "id: CompanyId"`). This course keeps rows plain and converts in `TryFrom`, for the
reason below.

### Why a row struct and `TryFrom`, instead of decoding straight into `Company`?

The database promises **types**, not **meaning**. `lifecycle` is guaranteed to be text, and
our `CHECK` happens to guarantee one of three values. But `contacts.email` is only guaranteed to
be *some* text, while your `Email` type promises much more (Lab 12). Rows can be written by
`psql`, by a future migration, by a bug, or by another service. So:

```text
database row ──► CompanyRow (plain types, decoded by SQLx)
             ──► TryFrom    (re-validate: FromStr, Email::try_from, ...)
             ──► Company    (a value that upholds every domain invariant)
```

`type Error = sqlx::Error` with `corrupt(...)` is a deliberate choice. If a row can't become a
domain value, that's **corrupt data on our side**, not bad input from the client. It must become
a 500 (via `CrmError::Database`), never a 422. If you used `ValidationError` there, `?` would turn
it into `CrmError::Validation` and you'd tell the client *their* request was invalid. That would
be wrong.

### The rest of the companies repository

> 🟢 **FOLLOW ALONG**: add `list`, `update` and `delete` to `src/companies/db.rs`.

```rust
/// Returns one page of companies plus the total number that match the filter.
pub async fn list(
    pool: &PgPool,
    filter: &CompanyFilter,
    limit: i64,
    offset: i64,
) -> Result<(Vec<Company>, i64), CrmError> {
    let lifecycle = filter.lifecycle.map(|l| l.to_string());
    let search = filter.search.as_deref();

    let rows = sqlx::query_as!(
        CompanyRow,
        "SELECT id, name, website, lifecycle
         FROM companies
         WHERE ($1::text IS NULL OR lifecycle = $1)
           AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%')
         ORDER BY id
         LIMIT $3 OFFSET $4",
        lifecycle,
        search,
        limit,
        offset,
    )
    .fetch_all(pool)
    .await?;

    let total = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "total!"
           FROM companies
           WHERE ($1::text IS NULL OR lifecycle = $1)
             AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%')"#,
        lifecycle,
        search,
    )
    .fetch_one(pool)
    .await?;

    let companies = rows
        .into_iter()
        .map(Company::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok((companies, total))
}

pub async fn update(
    pool: &PgPool,
    id: CompanyId,
    changes: &CompanyUpdate,
) -> Result<Company, CrmError> {
    let row = sqlx::query_as!(
        CompanyRow,
        "UPDATE companies
         SET name = $2, website = $3, lifecycle = $4
         WHERE id = $1
         RETURNING id, name, website, lifecycle",
        id.0,
        changes.name,
        changes.website,
        changes.lifecycle.to_string(),
    )
    .fetch_optional(pool)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

pub async fn delete(pool: &PgPool, id: CompanyId) -> Result<(), CrmError> {
    let result = sqlx::query!("DELETE FROM companies WHERE id = $1", id.0)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(not_found(id));
    }
    Ok(())
}
```

Things worth slowing down for:

- **`$1::text IS NULL OR lifecycle = $1`** is the "optional filter" trick: pass `None` and the
  condition is true for every row. It works, and it keeps the SQL static so the macro can check
  it. It gets clumsy fast (you'll feel it in the contacts version with three filters and a sort),
  and Lab 32 replaces it with a query *builder*.
- **`AS "total!"`**: Postgres can't prove `COUNT(*)` is never NULL, so the macro would type it
  `Option<i64>`. The `!` suffix in the column alias is SQLx's override: "trust me, not null".
  (`?` forces nullable, and `"name: Type"` overrides the type.) The raw string `r#"..."#` is only
  needed because the SQL contains `"`.
- **The macros take arguments by reference.** That's why `lifecycle` and `search` can be passed to
  *both* queries without being moved.
- **`.collect::<Result<Vec<_>, _>>()`** turns an iterator of `Result`s into a `Result` of a `Vec`,
  stopping at the first error. It's the iterator version of `?`.
- **`fetch_one` / `fetch_optional` / `fetch_all` / `execute`**: exactly one row (error otherwise),
  zero-or-one (`Option`), all rows, or no rows wanted (you get `rows_affected()`).
- **`ILIKE`** is Postgres's case-insensitive `LIKE`. (A user searching for `%` gets every row,
  because `%` is a wildcard. Escaping it is a nice extra if you want one.)

### Constraint violations become domain errors

What happens when an `INSERT` breaks the `UNIQUE` constraint on `contacts.email`? Ask Postgres
directly, with verbose errors on:

```bash
docker compose exec db psql -U crm -d crm \
  -c "INSERT INTO contacts (name, email) VALUES ('A', 'dup@x.test')" \
  -c "\set VERBOSITY verbose" \
  -c "INSERT INTO contacts (name, email) VALUES ('B', 'dup@x.test')"
```

```text
ERROR:  23505: duplicate key value violates unique constraint "contacts_email_key"
DETAIL:  Key (email)=(dup@x.test) already exists.
SCHEMA NAME:  public
TABLE NAME:  contacts
CONSTRAINT NAME:  contacts_email_key
```

(`docker compose exec db psql -U crm -d crm -c "DELETE FROM contacts"` cleans up afterwards.)

`23505` is the SQLSTATE code for `unique_violation`. SQLx gives you this as
`sqlx::Error::Database(db_error)`, and the `db_error` can answer questions about itself:

```rust
// The shape you'll use in Your Turn 1 (not a complete function):
.map_err(|e| match e {
    sqlx::Error::Database(db) if db.is_unique_violation() => {
        CrmError::DuplicateEmail(new.email.to_string())
    }
    other => CrmError::Database(other),
})?;
```

That's a `match` with a **guard** (`if ...`, Lab 11) on an enum variant that holds a
`Box<dyn DatabaseError>` (a trait object, Lab 23). If a table had two unique constraints, you'd
check *which one*: `db.constraint() == Some("contacts_email_key")`. The Lab 12 duplicate check
(scan for the email, then insert) is gone, and good riddance: between the scan and the insert
another request could insert the same email. The constraint has no such gap.

## Step 9 — A deliberate half-way state: the strangler migration

You could move all six entities to Postgres in one go. You won't. A **strangler migration**
(named after the strangler fig, which grows around a tree until it replaces it) moves a system
one piece at a time, with the old and new parts running side by side, so every step is small,
tested and shippable.

> 🟢 **FOLLOW ALONG**: `src/http/state.rs`

```rust
use std::sync::{Arc, RwLock};

use sqlx::PgPool;

use crate::crm::Crm;
use crate::storage::{Storage, StorageError};

/// TRANSITIONAL (Lab 30 only): companies and contacts live in Postgres (`pool`);
/// deals, leads, activities and notes still live in the JSON-backed `Crm`.
/// Lab 31 migrates the rest and deletes `crm` and `storage`.
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub crm: Arc<RwLock<Crm>>,
    pub storage: Arc<dyn Storage>,
}

impl AppState {
    pub fn new(pool: PgPool, crm: Crm, storage: Arc<dyn Storage>) -> Self {
        AppState { pool, crm: Arc::new(RwLock::new(crm)), storage }
    }

    // keep your Lab 27 `persist()` exactly as it is
}
```

Delete `AppState::in_memory()`: there's no way to build this state without a pool now. Step 12
deals with the tests that used it.

`src/main.rs` connects, migrates, and still loads the JSON file for the other half:

```rust
use std::env;
use std::sync::Arc;

use anyhow::Context;
use rust_crm::database;
use rust_crm::http::{AppState, router};
use rust_crm::storage::{JsonFileStorage, Storage};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // In development, read DATABASE_URL (and friends) from .env. Real env vars win.
    dotenvy::dotenv().ok();

    let database_url =
        env::var("DATABASE_URL").context("DATABASE_URL must be set (see .env.example)")?;
    let pool = database::connect(&database_url)
        .await
        .context("could not connect to Postgres - is `docker compose up -d` running?")?;
    database::migrate(&pool)
        .await
        .context("could not run database migrations")?;

    // Still JSON until Lab 31: deals, leads, activities, notes.
    let data_file = env::var("CRM_DATA_FILE").unwrap_or_else(|_| "crm-data.json".to_string());
    let storage: Arc<dyn Storage> = Arc::new(JsonFileStorage::new(&data_file));
    let crm = storage
        .load()
        .with_context(|| format!("could not load {data_file}"))?;

    let state = AppState::new(pool, crm, storage);

    let port: u16 = env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(3000);
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    println!("Listening on http://{}", listener.local_addr()?);
    axum::serve(listener, router(state)).await?;
    Ok(())
}
```

`dotenvy::dotenv().ok()`: `.ok()` turns "no `.env` file" from an error into "fine". In production
there's no `.env`; real environment variables are used and win over the file.

**Be honest about the seam.** For the length of this lab there are two sources of truth:

- `POST /deals` validates the company through `Crm` (JSON), which doesn't know about companies
  created in Postgres. You'll *see* this in the Experiment section.
- Lead conversion still creates its company and contact in the JSON world.

That's the price of a strangler migration, and it's acceptable here because Lab 31 removes it
right away. In a production system you'd keep the seam working with a backfill (copy old data
into the new store) and/or dual writes. We don't need that: the JSON data is development data.

## Step 10 — Companies handlers on the pool

> 🟢 **FOLLOW ALONG**: rewrite the handler bodies in `src/http/companies.rs`. Request and response
> types stay, and so do your Lab 28 `TryFrom<CreateCompanyRequest> for NewCompany` and
> `TryFrom<UpdateCompanyRequest> for CompanyUpdate` impls. Only the line that used to call `Crm`
> changes.

```rust
async fn list_companies(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<CompanyQuery>,
    AppQuery(p): AppQuery<Pagination>,
) -> Result<Json<Page<CompanyResponse>>, ApiError> {
    let p = p.normalized();
    let filter = CompanyFilter {
        lifecycle: q.lifecycle,
        search: q.search,
    };
    let (companies, total) =
        companies::db::list(&state.pool, &filter, p.limit(), p.offset()).await?;
    let items = companies.iter().map(CompanyResponse::from).collect();
    Ok(Json(Page {
        items,
        page: p.page,
        per_page: p.per_page,
        total,
    }))
}

async fn create_company(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateCompanyRequest>,
) -> Result<(StatusCode, Json<CompanyResponse>), ApiError> {
    let new = NewCompany::try_from(req).map_err(ApiError::Validation)?;
    let company = companies::db::insert(&state.pool, &new).await?;
    Ok((StatusCode::CREATED, Json(CompanyResponse::from(&company))))
}

async fn get_company(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<CompanyResponse>, ApiError> {
    let company = companies::db::get(&state.pool, CompanyId(id)).await?;
    Ok(Json(CompanyResponse::from(&company)))
}

async fn update_company(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<UpdateCompanyRequest>,
) -> Result<Json<CompanyResponse>, ApiError> {
    let changes = CompanyUpdate::try_from(req).map_err(ApiError::Validation)?;
    let company = companies::db::update(&state.pool, CompanyId(id), &changes).await?;
    Ok(Json(CompanyResponse::from(&company)))
}

async fn delete_company(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<StatusCode, ApiError> {
    companies::db::delete(&state.pool, CompanyId(id)).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn company_contacts(
    State(_state): State<AppState>,
    AppPath(_id): AppPath<i64>,
) -> Result<Json<Vec<ContactResponse>>, ApiError> {
    todo!("Lab 30, Your Turn 2")
}
```

Add the two helpers the handlers use to `impl Pagination` in `src/http/pagination.rs`, and make
`Page::total` an `i64` if it isn't one already (it now comes straight from `COUNT(*)`):

```rust
    /// SQL `LIMIT`.
    pub fn limit(&self) -> i64 {
        i64::from(self.normalized().per_page)
    }
    /// SQL `OFFSET`: how many rows to skip before this page.
    pub fn offset(&self) -> i64 {
        i64::from(self.normalized().page - 1) * self.limit()
    }
```

`Page::paginate` (which sliced a `Vec` in memory) has no caller for companies any more. The
database does the slicing now. Keep it while other handlers still use it.

Notice what's **gone**: the read/write lock, the "drop the guard before `.await`" care from
Lab 27, and the `persist().await` after every mutation. Concurrency control is now the
database's job. Every handler is "validate, one repository call, map to a response".

`todo!()` has type `!` (never), which fits any return type, so the file compiles while
`GET /companies/{id}/contacts` is unfinished. The contacts handlers still use `state.crm` until
you do Your Turn 2. That's part of the strangler state too.

## Step 11 — Offline mode: building without a database

Your code now *only compiles when Postgres is running*. That's fine on your laptop and a problem
in CI (no database there until Lab 33), in Docker builds (Lab 40), and for a teammate who just
cloned the repo. SQLx's answer is a **query cache**:

```bash
cargo sqlx prepare
```

```text
query data written to .sqlx in the current directory; please check this into version control
```

`.sqlx/` holds one JSON file per query: the SQL text, its parameter types and its result columns
with nullability. That's everything the macro learned from Postgres. When `DATABASE_URL` isn't
set, or `SQLX_OFFLINE=true` is, the macros read these files instead of connecting.

> 🟡 **EXPERIMENT**: predict, then run each.

```bash
SQLX_OFFLINE=true cargo check     # uses .sqlx/, no database needed
```

Now change any query slightly (e.g. `ORDER BY id` → `ORDER BY name, id` in `list`) and run
`SQLX_OFFLINE=true cargo check` again:

```text
error: `SQLX_OFFLINE=true` but there is no cached data for this query, run `cargo sqlx prepare` to update the query cache or unset `SQLX_OFFLINE`
```

The cache is keyed by a hash of the query text. A changed query is a *new* query. And with no
`.env`, no `DATABASE_URL` and no `.sqlx/` at all:

```text
error: set `DATABASE_URL` to use query macros online, or run `cargo sqlx prepare` to update the query cache
```

Undo the change. The rule from now on: **whenever you add or change a query, run
`cargo sqlx prepare` and commit `.sqlx/` with the code.** Lab 33 adds a CI check that fails if
you forget.

**Your Lab 24 CI workflow will break now**: it builds without a database. Add this at the top
level of `.github/workflows/ci.yml` (Lab 33 rewrites the file properly):

```yaml
env:
  SQLX_OFFLINE: "true"
```

## Step 12 — Tests that need a database (for now: ignore them)

`tests/api/helpers.rs` built `AppState::in_memory()`, which no longer exists. You need a
`PgPool` to build an `AppState`, but you don't want every test run to need Postgres yet (that's
Lab 33). The trick is a **lazy** pool:

```rust
/// Lab 30: a *lazy* pool parses the URL but doesn't connect until the first
/// query runs. Tests that never touch companies/contacts never need Postgres.
pub fn app() -> Router {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://crm:crm@localhost:5432/crm")
        .expect("valid database URL");
    router(AppState::new(
        pool,
        Crm::default(),
        Arc::new(InMemoryStorage),
    ))
}
```

(Imports: `std::sync::Arc`, `sqlx::postgres::PgPoolOptions`, `rust_crm::crm::Crm`,
`rust_crm::storage::InMemoryStorage`. Your other helpers (`send`, `get`, `post_json`,
`create_company`, `error_code`, ...) stay as they are.) `sqlx` is already a normal dependency, so integration tests
can use it.

Every test that would **reach the database** gets marked:

```rust
#[tokio::test]
#[ignore = "needs database; restored in Lab 33"]
async fn duplicate_email_is_409() {
```

That covers your company tests, the contact tests that insert, and any **deal** test that creates
its company through `POST /companies` (it would also hit the strangler seam).

> 🟡 **EXPERIMENT**: before ignoring a contacts test, ask: does it reach the database? A test that
> posts `{"name": "", "email": "nope"}` fails validation in `TryFrom` *before* any repository
> call, so it passes with a lazy pool. Keep tests like that running. An ignored test doesn't
> protect anything.

```bash
cargo test
```

```text
test companies::create_then_get_company ... ignored, needs database; restored in Lab 33
test companies::unknown_company_is_404 ... ignored, needs database; restored in Lab 33
test contacts::duplicate_email_is_409 ... ignored, needs database; restored in Lab 33
...
test result: ok. 2 passed; 0 failed; 5 ignored; 0 measured; 0 filtered out
```

(Your counts depend on your Lab 29 tests.) `cargo test -- --ignored` runs *only* the ignored ones,
which is handy once Postgres is up.

---

## ▶️ Run It
After finishing the Your Turn tasks below:

```bash
docker compose up -d
cargo run
```

In a second terminal:

```bash
curl -i -X POST localhost:3000/companies -H 'content-type: application/json' \
  -d '{"name":"Acme Corp","website":"https://acme.test"}'
curl -s localhost:3000/companies?search=acme
curl -s -X POST localhost:3000/contacts -H 'content-type: application/json' \
  -d '{"name":"Ada Lovelace","email":"Ada@Example.com","company_id":1}'
curl -i -X POST localhost:3000/contacts -H 'content-type: application/json' \
  -d '{"name":"Ada Again","email":"ada@example.com"}'
curl -i -X POST localhost:3000/contacts -H 'content-type: application/json' \
  -d '{"name":"Bob","email":"bob@example.com","company_id":99}'
curl -i -X DELETE localhost:3000/companies/1
curl -s localhost:3000/companies/1/contacts
docker compose exec db psql -U crm -d crm -c 'select id, name, email, company_id from contacts'
```

## ✅ Expected Result
```text
Listening on http://127.0.0.1:3000
```

```text
HTTP/1.1 201 Created
content-type: application/json

{"id":1,"name":"Acme Corp","website":"https://acme.test","lifecycle":"prospect"}

{"items":[{"id":1,"name":"Acme Corp","website":"https://acme.test","lifecycle":"prospect"}],"page":1,"per_page":20,"total":1}

{"id":1,"name":"Ada Lovelace","email":"ada@example.com","phone":null,"company_id":1}

HTTP/1.1 409 Conflict
{"error":{"code":"conflict","message":"a contact with email ada@example.com already exists"}}

HTTP/1.1 404 Not Found
{"error":{"code":"not_found","message":"company #99 not found"}}

HTTP/1.1 409 Conflict
{"error":{"code":"conflict","message":"company #1 still has contacts"}}

[{"id":1,"name":"Ada Lovelace","email":"ada@example.com","phone":null,"company_id":1}]

 id |     name     |      email      | company_id
----+--------------+-----------------+------------
  1 | Ada Lovelace | ada@example.com |          1
(1 row)
```

Your ids will be higher if you created rows during the experiments. Stop the server and start it
again: the data is still there, because it's in Postgres, not in your process.

## 🧠 Understand It

**Where the rules live now.** The same invariant is often enforced twice: in Rust (fast,
precise error messages, testable without a database) and in SQL (the last line of defence,
covering every writer, not just this app). Name non-empty: `TryFrom<CreateCompanyRequest>` *and*
`CHECK`. Email unique: the `UNIQUE` constraint only, because a Rust pre-check would be racy. Company
exists for a contact: the foreign key only, for the same reason. The rule of thumb: **validate
shape in Rust, enforce relationships and uniqueness in the database.**

**Compile time vs runtime, again.** In Lab 11 the compiler checked that you handled every
command. Here a proc macro extends that to the database: the SQL text, its parameters and the
shape of its result are checked against the real schema before your program exists. The
trade-off is that compiling needs either a live database or an up-to-date `.sqlx/`. That's why
offline mode exists.

**Extractor rejections still work.** `curl localhost:3000/companies/abc` answers
`400 {"error":{"code":"bad_request","message":"Invalid URL: Cannot parse `abc` to a `i64`"}}`.
Your `AppPath` turned axum's rejection into an `ApiError` before the handler ran.

**Why `&PgPool`?** `fetch_one(pool)` takes anything implementing SQLx's `Executor` trait.
`&PgPool` is one; a single connection or a transaction is another. In Lab 31 you'll want the
same `insert` to run inside a transaction, and these signatures will change for exactly that
reason.

**`created_at` exists only in SQL.** The domain doesn't need it, so `CompanyRow` doesn't select
it. Your Rust types describe what *your code* needs, not everything that's stored.

**Errors as data, end to end.** A unique violation travels: Postgres SQLSTATE `23505` →
`sqlx::Error::Database` → your `match` guard → `CrmError::DuplicateEmail` → `ApiError::Domain` →
409 JSON. Anything unexpected travels a different path: `CrmError::Database` →
`ApiError::Internal` → logged with its full chain → generic 500.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: see the strangler seam.** With the server running:

```bash
curl -s -X POST localhost:3000/companies -H 'content-type: application/json' -d '{"name":"Seam Ltd"}'
curl -i -X POST localhost:3000/deals -H 'content-type: application/json' \
  -d '{"company_id":<the id you just got>,"title":"Rockets","value_cents":100000}'
```

```text
HTTP/1.1 404 Not Found
{"error":{"code":"not_found","message":"company #2 not found"}}
```

The company exists in Postgres, but deals still look in the JSON `Crm`. Explain in one sentence
why this is *acceptable for one lab* and what would make it unacceptable in production.

> 🟡 **EXPERIMENT 2: a 500 worth reading.** Do this *before* Your Turn 3. Create a company and a
> contact attached to it, then `DELETE` the company. You get a 500. Read the server's log line:

```text
internal error: error returned from database: update or delete on table "companies" violates RESTRICT setting of foreign key constraint "contacts_company_id_fkey" on table "contacts" ...
```

Now ask Postgres directly with `\set VERBOSITY verbose`, as in Step 8. What's the SQLSTATE? It is
**not** `23503` (`foreign_key_violation`), so `db.is_foreign_key_violation()` would be `false`
here. Keep that in mind for Your Turn 3.

> 🟡 **EXPERIMENT 3: where's the data?** Run `docker compose down`, then `docker compose up -d`.
> Is your data still there? Now `docker compose down -v` and `up -d` again, then restart the server.
> What happened, and which line of `main.rs` rebuilt the tables?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `src/contacts/db.rs`.** Write the contacts repository, using
> `companies/db.rs` as your model but **without copying it blindly**: contacts have different
> failure modes. Add `pub mod db;` to `src/contacts/mod.rs`.
>
> Required public functions (exact signatures):
> ```rust
> pub async fn insert(pool: &PgPool, new: &NewContact) -> Result<Contact, CrmError>
> pub async fn get(pool: &PgPool, id: ContactId) -> Result<Contact, CrmError>
> pub async fn list(pool: &PgPool, filter: &ContactFilter, limit: i64, offset: i64)
>     -> Result<(Vec<Contact>, i64), CrmError>
> pub async fn list_for_company(pool: &PgPool, company_id: CompanyId) -> Result<Vec<Contact>, CrmError>
> pub async fn update(pool: &PgPool, id: ContactId, changes: &NewContact) -> Result<Contact, CrmError>
> pub async fn delete(pool: &PgPool, id: ContactId) -> Result<(), CrmError>
> ```

- [ ] a private `ContactRow` and `impl TryFrom<ContactRow> for Contact` that **re-validates the
      email** with `Email::try_from` (corrupt → `sqlx::Error::Decode` via `corrupt`)
- [ ] `insert` **and** `update` map the `contacts_email_key` unique violation to
      `CrmError::DuplicateEmail(email)` and a foreign-key violation on `company_id` to
      `CrmError::NotFound { entity: "company", id }`
- [ ] `list` honours `ContactFilter { company, search, sort }`: search matches name **or** email
      (case-insensitive), sort by id / name / email, plus `total`. All in SQL, with static
      `query_as!` queries (no string building)
- [ ] `list_for_company` orders by name, then id
- [ ] `get`, `update`, `delete` return `NotFound { entity: "contact", .. }` for missing ids
- [ ] `cargo check` passes against the live database

> 🔵 **YOUR TURN 2: contacts handlers.** Switch every handler in `src/http/contacts.rs` from
> `state.crm` to your new repository, and implement `company_contacts` in `companies.rs`.

- [ ] `POST /contacts` returns 201, 409 for a duplicate email (whatever its casing), 404 for an
      unknown `company_id`, and 422 listing **all** invalid fields
- [ ] `GET /contacts?company_id=&search=&sort=&page=&per_page=` returns a `Page`
- [ ] `PUT /contacts/{id}` gives the same errors as create; `DELETE /contacts/{id}` gives 204,
      then 404
- [ ] `GET /companies/{id}/contacts` returns 404 for an unknown company and `[]` for a company
      without contacts
- [ ] no handler in `contacts.rs` mentions `state.crm` any more (`Crm::add_contact` /
      `update_contact` have no HTTP caller now; leave them, Lab 31 deletes `Crm`)

> 🔵 **YOUR TURN 3: deleting a company that has contacts.** Make
> `DELETE /companies/{id}` answer **409** with `CrmError::HasContacts(id)` when contacts still
> reference the company, instead of the 500 from Experiment 2.

- [ ] the mapping lives in `companies::db::delete`, not in the handler
- [ ] it's precise: only *that* constraint maps to `HasContacts`, and anything else stays
      `CrmError::Database`
- [ ] `DELETE` on a company with no contacts still answers 204, and on a missing id 404

Then regenerate the cache and finish:

```bash
cargo sqlx prepare
cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
```

## 💡 Hint
> 💡 **HINT**: For `list`, extend the companies trick: `$1::bigint IS NULL OR company_id = $1`.
> A *column name* can't be a bind parameter, so `ORDER BY $3` won't sort by a column. Think about
> `CASE WHEN ... THEN ... END` expressions in the `ORDER BY`.

<details><summary>Hint 2 (more specific)</summary>

- Write one private `fn write_error(e: sqlx::Error, new: &NewContact) -> CrmError` and use it in
  both `insert` and `update` with `.map_err(|e| write_error(e, new))`.
- `ORDER BY CASE WHEN $3 = 'name' THEN name END, CASE WHEN $3 = 'email' THEN email END, id`
  where `$3` is a `&str` you produce with a `match` on `ContactSort`. Rows where the `CASE` is
  NULL all tie, so the next key decides.
- Edition 2024 lets you chain `if db.is_foreign_key_violation() && let Some(c) = new.company_id`
  (clippy will suggest it if you nest the `if`s).
- Your Turn 3: you saw the SQLSTATE in Experiment 2. Which `DatabaseError` method tells you the
  constraint's *name*?

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Name three concrete problems with the JSON file that a database solves, and one new problem
   the database introduces.
2. What does `sqlx::query_as!` do at compile time, step by step? What does it do instead when
   `SQLX_OFFLINE=true`?
3. Why did every id become `i64`, and why fix `AppPath<u64>` instead of taking the compiler's
   `try_into().unwrap()` suggestion?
4. Why does `TryFrom<ContactRow> for Contact` re-validate the email even though only valid emails
   are ever inserted? Why is its error a `sqlx::Error` and not a `ValidationError`?
5. Why is the unique constraint better than "check whether the email exists, then insert"?
6. What is a strangler migration, and where exactly is the seam in your code right now?
7. Why must you never edit a migration that has been applied?

Then verify (with Postgres running): `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`,
and `SQLX_OFFLINE=true cargo check` (proves `.sqlx/` is complete).

## Git Commit
You committed "Retire terminal CLI" (Step 2) and "Add Postgres with migrations" (Step 4) already.

```bash
git add .
git commit -m "Store companies and contacts in Postgres"
git tag lab-30
git push && git push --tags
```

Check that `.sqlx/`, `migrations/`, `build.rs`, `docker-compose.yml` and `.env.example` are
committed, and that `.env` is **not** (`git status --ignored` shows it as ignored).

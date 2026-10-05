# Lab 29 — The Full REST Surface 🧪

> **Phase:** 8 — The CRM Becomes a Web API · **Builds on:** Lab 28 · **Time:** ~6–8 hours
> **Your repo before this lab:** tag `lab-28` · **After:** tag `lab-29`

## 🎯 Goal
Put the **whole CRM** behind HTTP (contacts, leads, deals, the pipeline, activities, notes and
history) with filtering and pagination, and back it with an **API test suite** that drives the
real router in-process, with no network and no files.

## 🧠 What You'll Learn
- **Router composition**: each module owns its routes (`fn routes() -> Router<AppState>`), and
  `merge`/`nest` assemble them. What the `S` in `Router<S>` means.
- **Query parameters** as typed structs, with serde defaults (`#[serde(default = "...")]`), and
  why `#[serde(flatten)]` breaks them
- A **generic response type** `Page<T>` with a `map` that turns `Page<&Company>` into
  `Page<CompanyResponse>` (generics, closures and borrowing together)
- **Modelling actions**: why `POST /deals/{id}/stage` instead of `PATCH /deals/{id}`
- **Money and time on the wire**: integer cents, RFC 3339 timestamps
- Integer overflow in "harmless" arithmetic, and `saturating_mul`
- **API tests** with `tower::ServiceExt::oneshot`: what a `Service` is, why `oneshot` consumes the
  router (E0507), why cloning a `Router` is cheap, and how a `tests/api/` directory becomes one
  test binary with a `helpers` module
- Writing tests **from a behaviour list**, the way you'd turn a ticket into a test plan

## 🔨 What We're Building
Lab 28 gave us a reliable error model and CRUD for companies and contacts. The rest of the CRM
(everything you built in Labs 18–20) is still only reachable from the terminal. After this lab:

```text
GET    /health
GET    /companies?lifecycle=&search=&page=&per_page=       → Page<CompanyResponse>
POST   /companies      GET/PUT/DELETE /companies/{id}
GET    /companies/{id}/contacts                            ← Your Turn 1
GET    /contacts?company_id=&search=&sort=&page=&per_page= ← Your Turn 1
POST   /contacts       GET/PUT/DELETE /contacts/{id}

POST   /leads          GET /leads?page=&per_page=          GET /leads/{id}
POST   /leads/{id}/qualify      POST /leads/{id}/disqualify
POST   /leads/{id}/convert   {"deal": {"title", "value_cents"}}?  → ConversionResponse

POST   /deals          GET /deals?stage=&company_id=&page=&per_page=     ← Your Turn 2
GET    /deals/{id}     POST /deals/{id}/stage {"stage"}                   ← Your Turn 2
GET    /pipeline                                                          ← Your Turn 2

POST   /activities     GET /activities?subject=deal:3                     ← Your Turn 3
POST   /notes          GET /notes?subject=contact:5                       ← Your Turn 3
GET    /history?subject=company:1   (newest first)                        ← Your Turn 3
```

Plus a test suite:

```text
tests/api/
├── main.rs        mod helpers; mod companies; mod contacts; mod leads; mod deals;
├── helpers.rs     app(), send(), get(), post(), post_json(), put_json(), delete(), ...
├── companies.rs   ← written in this lab
├── contacts.rs    ← Your Turn 4
├── leads.rs       ← Your Turn 4
└── deals.rs       ← Your Turn 4
```

> This lab assumes you completed **all three Your Turn tasks in Lab 28** (`NewContact`, contact
> CRUD, and the `AppPath` extractor). See [Lab 28's solutions.md](../28-api-errors-validation/solutions.md)
> if not.

> Written against **axum 0.8** (0.8.9), **tower 0.5** (0.5.3), **http-body-util 0.1** (0.1.5)
> and **chrono 0.4**. If an API moved, check docs.rs for the version in your `Cargo.lock`.

---

## Step 1 — Each module owns its routes

Right now `src/http/mod.rs` lists every route of every resource. With seven resources that
function becomes a 60-line wall, and adding an endpoint means editing two files. Let each module
declare its own routes and let `mod.rs` assemble them.

> 🟢 **FOLLOW ALONG**: at the top of `src/http/companies.rs` (the two `use` lines replace `use axum::Json;`)

```rust
use axum::routing::get;
use axum::{Json, Router};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/companies", get(list_companies).post(create_company))
        .route(
            "/companies/{id}",
            get(get_company).put(update_company).delete(delete_company),
        )
}
```

Do the same for `contacts.rs` (`/contacts`, `/contacts/{id}`) and `health.rs`:

```rust
// src/http/health.rs
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{Value, json};

use super::AppState;

pub fn routes() -> Router<AppState> {
    Router::new().route("/health", get(health))
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}
```

Then `src/http/mod.rs` shrinks to an assembly line:

```rust
pub fn router(state: AppState) -> Router {
    Router::new()
        .merge(health::routes())
        .merge(companies::routes())
        .merge(contacts::routes())
        .with_state(state)
}
```

`mod.rs` no longer calls `get` itself, so delete its `use axum::routing::get;` (the compiler
warns about it otherwise).

Handlers that are only referenced from their module's `routes()` no longer need to be `pub`.
Making them private (`async fn health()`) shrinks the module's public surface. Keep the
DTOs `pub`: tests and other modules may use them.

### What is the `S` in `Router<S>`?

`Router<S>` reads as **"a router that still needs a state of type `S`"**. Handlers that take
`State<AppState>` can only be added to a `Router<AppState>`. `.with_state(state)` supplies the
value and returns a `Router<()>`, a router that needs nothing more, which is what `axum::serve`
and our tests accept. (`Router` with no parameter means `Router<()>`.) That's why each module
returns `Router<AppState>`. They're incomplete on purpose, and `router()` completes them once.

### `merge` vs `nest`

- `a.merge(b)` puts `b`'s routes into `a` **unchanged**. Each module writes full paths
  (`/companies/{id}`), so you can grep for a URL and find its handler.
- `a.nest("/leads", b)` **prefixes** every route in `b`. `b` would write `/` and `/{id}`. That's
  useful for mounting a whole sub-API (`/api/v1`, `/admin`) or a router from another crate.

We use `merge`: our modules map to resources whose paths sometimes cross
(`/companies/{id}/contacts` lives in `companies.rs`), and full paths are easier to read in a
diff. You'll try `nest` in the Experiment section.

> 🟡 **EXPERIMENT**: in `contacts::routes()`, add a second `.route("/companies", get(list_contacts))`.
> Predict: compile error, runtime error, or does one silently win? Then run `cargo run`.

It compiles fine. Then the server dies **while building the router**:

```text
thread 'main' (641046) panicked at src/http/mod.rs:20:10:
Overlapping method route. Handler for `GET /companies` already exists
```

Route tables are built at runtime, so the type system can't see conflicts. Axum checks when you
merge and **panics at startup**, which is the next best thing: you can't deploy a router with two
handlers for the same route. (In the test suite, every test that builds the router fails the same
way.) Remove the line.

---

## Step 2 — Pagination: one struct for every list

Every list endpoint will accept `?page=2&per_page=50` and answer with the same envelope:

```json
{ "items": [ ... ], "page": 2, "per_page": 50, "total": 137 }
```

> 🟢 **FOLLOW ALONG**: create `src/http/pagination.rs` (and `pub mod pagination;` in `mod.rs`)

```rust
//! Offset pagination shared by every list endpoint.

use serde::{Deserialize, Serialize};

pub const DEFAULT_PER_PAGE: usize = 20;
pub const MAX_PER_PAGE: usize = 100;

/// `?page=2&per_page=50`. Both are optional.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct Pagination {
    #[serde(default = "default_page")]
    pub page: usize,
    #[serde(default = "default_per_page")]
    pub per_page: usize,
}

fn default_page() -> usize {
    1
}

fn default_per_page() -> usize {
    DEFAULT_PER_PAGE
}

impl Default for Pagination {
    fn default() -> Self {
        Self {
            page: default_page(),
            per_page: default_per_page(),
        }
    }
}

impl Pagination {
    /// Clamp client input into the range we are willing to serve.
    pub fn normalized(self) -> Self {
        Self {
            page: self.page.max(1),
            per_page: self.per_page.clamp(1, MAX_PER_PAGE),
        }
    }

    fn offset(&self) -> usize {
        (self.page - 1) * self.per_page
    }
}

/// One page of results plus what a client needs to ask for the next one.
#[derive(Debug, Serialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub page: usize,
    pub per_page: usize,
    pub total: usize,
}

impl<T> Page<T> {
    /// Cut one page out of the full (already filtered and sorted) result.
    pub fn paginate(all: Vec<T>, pagination: Pagination) -> Self {
        let p = pagination.normalized();
        let total = all.len();
        let items = all.into_iter().skip(p.offset()).take(p.per_page).collect();
        Page {
            items,
            page: p.page,
            per_page: p.per_page,
            total,
        }
    }

    /// Turn a `Page<T>` into a `Page<U>`, keeping the paging numbers.
    pub fn map<U, F>(self, f: F) -> Page<U>
    where
        F: FnMut(T) -> U,
    {
        Page {
            items: self.items.into_iter().map(f).collect(),
            page: self.page,
            per_page: self.per_page,
            total: self.total,
        }
    }
}
```

Points to notice:

- **`#[serde(default = "default_page")]` takes a *path to a function*, as a string.** Attributes
  can't contain arbitrary expressions, so serde calls the function you name whenever the key is
  missing. Plain `#[serde(default)]` would call `usize::default()`, which is `0`, the wrong
  default for a page number.
- **`normalized` clamps instead of rejecting.** `per_page=1000` quietly becomes 100 and `page=0`
  becomes 1, and the response tells the client what it actually got (`"per_page": 100`). The
  alternative, a 422 for out-of-range values, is equally valid. Clamping is friendlier to quick
  scripts.
- **`#[derive(Serialize)]` on a generic struct** generates
  `impl<T: Serialize> Serialize for Page<T>`. The derive adds the bound for you, so `Page<T>`
  is serializable exactly when `T` is.
- **`paginate` takes `Vec<T>` by value** and `into_iter()` moves the selected items into the
  page. Because `T` is generic, the same function paginates `Vec<&Company>` (borrowed references)
  and `Vec<CompanyResponse>` (owned DTOs) with no copying. `skip` past the end yields nothing,
  so an out-of-range page is an empty list, not a panic. That's the same rule as Lab 09's
  `CustomerStore::page`.
- **`map` is a generic method on a generic type**: `T` comes from the `impl<T>`, and `U`/`F` are
  chosen per call. `F: FnMut(T) -> U` (Lab 17), because the closure is called once per item and is
  allowed to mutate captured state.

`offset()` has a bug. Leave it exactly as written: you'll find it at the end of Step 3, when an
endpoint actually uses `Pagination`.

> 🟢 **FOLLOW ALONG**: unit tests at the bottom of `pagination.rs`

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn pagination(page: usize, per_page: usize) -> Pagination {
        Pagination { page, per_page }
    }

    #[test]
    fn second_page_skips_the_first() {
        let page = Page::paginate((1..=5).collect(), pagination(2, 2));
        assert_eq!(page.items, vec![3, 4]);
        assert_eq!(page.total, 5);
    }

    #[test]
    fn out_of_range_page_is_empty_not_a_panic() {
        let page = Page::paginate((1..=5).collect::<Vec<i32>>(), pagination(99, 10));
        assert!(page.items.is_empty());
        assert_eq!(page.total, 5);
    }

    #[test]
    fn per_page_is_clamped() {
        let page = Page::paginate(vec![1], pagination(0, 1000));
        assert_eq!((page.page, page.per_page), (1, MAX_PER_PAGE));
    }
}
```

In the first test, `(1..=5).collect()` has no type annotation, yet it compiles. The compiler
infers `Vec<i32>` from `paginate`'s `Vec<T>` parameter and the `vec![3, 4]` comparison. In the
second, nothing pins `T` down, so we write `collect::<Vec<i32>>()` (the "turbofish").

---

## Step 3 — Query parameters as typed structs

Query strings fail too (`?page=abc`, `?lifecycle=vip`), and axum's `Query` extractor rejects
them with plain text, exactly like `Path` did. You know the fix: this is the third time.

> 🟢 **FOLLOW ALONG**: `src/http/extract.rs`

```rust
/// Like `axum::extract::Query`, but a bad query string becomes our JSON 400.
#[derive(FromRequestParts)]
#[from_request(via(axum::extract::Query), rejection(ApiError))]
pub struct AppQuery<T>(pub T);
```

`src/http/error.rs`:

```rust
use axum::extract::rejection::{JsonRejection, PathRejection, QueryRejection};

impl From<QueryRejection> for ApiError {
    fn from(rejection: QueryRejection) -> Self {
        ApiError::BadRequest(rejection.body_text())
    }
}
```

Now the company list. The filter type already exists. It's Lab 17's `CompanyFilter`. The query
struct is its HTTP twin, and a `From` impl connects them:

> 🟢 **FOLLOW ALONG**: `src/http/companies.rs`

```rust
use super::extract::{AppJson, AppPath, AppQuery};
use super::pagination::{Page, Pagination};

#[derive(Debug, Default, Deserialize)]
pub struct CompanyQuery {
    pub lifecycle: Option<Lifecycle>,
    pub search: Option<String>,
}

impl From<CompanyQuery> for CompanyFilter {
    fn from(q: CompanyQuery) -> Self {
        CompanyFilter {
            lifecycle: q.lifecycle,
            search: q.search,
        }
    }
}

pub async fn list_companies(
    State(state): State<AppState>,
    AppQuery(query): AppQuery<CompanyQuery>,
    AppQuery(pagination): AppQuery<Pagination>,
) -> Json<Page<CompanyResponse>> {
    let filter = CompanyFilter::from(query);
    let crm = state.crm.read().expect("crm lock poisoned");
    let page = Page::paginate(crm.list_companies(&filter), pagination);
    Json(page.map(CompanyResponse::from))
}
```

(If your `CompanyFilter` has more fields, fill them from the query or with `..Default::default()`.)

Three things worth slowing down for.

**Two `AppQuery` extractors in one handler.** Each one deserializes the *whole* query string into
its own type, and serde **ignores keys it doesn't know**. `CompanyQuery` takes `lifecycle` and
`search`, ignores `page`/`per_page`, and `Pagination` does the opposite. That keeps pagination
reusable across every list endpoint.

**Borrowed page, owned response.** `crm.list_companies(&filter)` returns `Vec<&Company>`, borrowed
from the `Crm` inside the read guard. `Page::paginate` turns it into a `Page<&Company>` (still
borrowed), and `.map(CompanyResponse::from)` turns that into a `Page<CompanyResponse>` that owns
its data. Only the owned page leaves the function. The guard `crm` is dropped at the closing
brace, *after* the `Json(...)` value has been built. That's fine here because there is no
`.await` in between. Note the sequence: paginate **before** converting, so we clone only the 20
companies we'll actually send, not all 10,000.

**`CompanyResponse::from` as a function value.** `From::from` is just a function
`fn(&Company) -> CompanyResponse`, so it can be passed to `map` like a closure.

> 🟡 **EXPERIMENT**: why two extractors? It's tempting to embed `Pagination` inside `CompanyQuery`
> with `#[serde(flatten)]`, and use one extractor. Try it: add
> `#[serde(flatten)] pub pagination: Pagination,` to `CompanyQuery`, remove the second extractor,
> read `query.pagination` instead, and call `?page=2`:

```text
{"error":{"code":"bad_request","message":"Failed to deserialize query string: invalid type: string \"2\", expected usize"}}
```

A query string has no types. Everything in it is text. `serde_urlencoded` (what `Query` uses
underneath) can still produce a `usize` because it asks serde what type the *field* wants, and
then parses the text. With `flatten`, serde first collects the unknown keys into a generic,
untyped buffer and hands that to `Pagination` later. By then the "this should be a number" hint is
gone, and `"2"` stays a string. It's a long-standing serde limitation, not an axum bug. Two
extractors avoid it entirely. Undo the experiment.

> 🟡 **EXPERIMENT**: overflow. With `offset()` still written as `(self.page - 1) * self.per_page`,
> run the server and call `curl -i 'localhost:3000/companies?page=18446744073709551615'`.
> Predict what happens.

```text
$ curl -i 'localhost:3000/companies?page=18446744073709551615'
curl: (52) Empty reply from server
```

…and in the server terminal:

```text
thread 'tokio-rt-worker' (513169) panicked at src/http/pagination.rs:44:9:
attempt to multiply with overflow
```

`page` was parsed fine (it's `usize::MAX` on a 64-bit machine), and then `(page - 1) * per_page`
overflowed. In debug builds Rust **panics** on integer overflow (Lab 02). Tokio caught the panic
in that request's task, so the server survives, but the client got a dropped connection. In
release builds the multiplication would silently **wrap around** to a small number, and the client
would get a page of real data for a nonsensical page number. Neither is acceptable for input
that came off the network. Fix it:

```rust
fn offset(&self) -> usize {
    (self.page - 1).saturating_mul(self.per_page)
}
```

`saturating_mul` stops at `usize::MAX` instead of overflowing. `skip(usize::MAX)` then yields an
empty page. (`self.page - 1` can't underflow because `normalized()` guarantees `page >= 1`, and
`offset` is private, so only `paginate` can call it, after normalizing.)

---

## Step 4 — Actions, not field updates: leads

A lead moves `new → qualified` or `new → disqualified`, and a qualified lead can be **converted**
into a company, a contact and optionally a deal (Lab 19). How should that look over HTTP?

The "generic REST" instinct is `PATCH /leads/1 {"status": "qualified"}`. Consider what that
endpoint would have to do:

- `PATCH` means "change these fields". A client could just as well send
  `{"status": "converted"}` or `{"status": "new"}` for a disqualified lead. Every field becomes
  a potential state-machine bypass, and the handler has to reverse-engineer which *operation* the
  client meant from a diff.
- Conversion isn't a field change at all. It consumes the lead (`Lead::convert(self)`) and creates
  three other records.

Your domain already has the right vocabulary: `qualify`, `disqualify`, `convert`, each with its own
rules and errors. So expose **operations**, one endpoint per domain method:

```text
POST /leads/{id}/qualify      → Crm::qualify_lead
POST /leads/{id}/disqualify   → Crm::disqualify_lead
POST /leads/{id}/convert      → Crm::convert_lead
```

`POST`, because these are not idempotent "put this state" requests. They ask the server to *do*
something, and the server decides whether that's allowed (`409 conflict` if not). Deals get the
same treatment in Your Turn 2: `POST /deals/{id}/stage {"stage": "won"}` runs
`DealStage::can_transition_to` and returns `409 invalid_transition` when the rules say no.

Contrast with companies: Lab 28's `PUT /companies/{id}` lets you set `lifecycle` to anything,
because `Lifecycle` has **no transition rules**. It's plain data. Rules → action endpoint.
No rules → it's just a field.

> ⚠️ **Signature check.** This step assumes your `Crm` from Lab 19 has
> `add_lead(&mut self, name: String, email: Email, company_name: Option<String>, source: LeadSource, notes: Option<String>) -> Result<LeadId, CrmError>`,
> `qualify_lead(&mut self, id: LeadId) -> Result<(), CrmError>` and
> `convert_lead(&mut self, id: LeadId, deal: Option<(String, Money)>) -> Result<ConversionSummary, CrmError>`.
> If your `add_lead` takes its arguments differently (e.g. a builder), adapt the one call in
> `create_lead`. If you don't have `disqualify_lead`, add it to `Crm`: look the lead up
> (`NotFound` if missing), call `Lead::disqualify`, return `Ok(())`. Also make sure
> `LeadSource` and `LeadStatus` derive `Serialize`/`Deserialize` with
> `#[serde(rename_all = "snake_case")]` (Lab 21 did this for all enums).

> 🟢 **FOLLOW ALONG**: create `src/http/leads.rs`

```rust
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::{ApiError, FieldError};
use super::extract::{AppJson, AppPath, AppQuery};
use super::pagination::{Page, Pagination};
use crate::contacts::Email;
use crate::errors::CrmError;
use crate::leads::{Lead, LeadId, LeadSource, LeadStatus};
use crate::money::Money;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/leads", get(list_leads).post(create_lead))
        .route("/leads/{id}", get(get_lead))
        .route("/leads/{id}/qualify", post(qualify_lead))
        .route("/leads/{id}/disqualify", post(disqualify_lead))
        .route("/leads/{id}/convert", post(convert_lead))
}

// ---------- DTOs ----------

#[derive(Debug, Deserialize)]
pub struct CreateLeadRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub email: String,
    pub company_name: Option<String>,
    pub source: Option<LeadSource>,
    pub notes: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct LeadResponse {
    pub id: u64,
    pub name: String,
    pub email: String,
    pub company_name: Option<String>,
    pub source: LeadSource,
    pub status: LeadStatus,
    pub notes: Option<String>,
}

impl From<&Lead> for LeadResponse {
    fn from(lead: &Lead) -> Self {
        Self {
            id: lead.id.0,
            name: lead.name.clone(),
            email: lead.email.as_str().to_string(),
            company_name: lead.company_name.clone(),
            source: lead.source,
            status: lead.status,
            notes: lead.notes.clone(),
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct ConvertLeadRequest {
    pub deal: Option<ConvertDeal>,
}

#[derive(Debug, Deserialize)]
pub struct ConvertDeal {
    #[serde(default)]
    pub title: String,
    pub value_cents: i64,
}

#[derive(Debug, Serialize)]
pub struct ConversionResponse {
    pub company_id: u64,
    pub contact_id: u64,
    pub deal_id: Option<u64>,
}
```

(`source: lead.source` works without `.clone()` if `LeadSource` is `Copy`. If yours isn't,
add `Clone, Copy` to its derives. It's a fieldless enum, so copying is free.)

Validation follows Lab 28's pattern. `Crm::add_lead` takes separate arguments rather than a
`NewLead`, so we validate into a small **private** struct that only this module sees:

```rust
// ---------- validation ----------

/// The validated pieces `Crm::add_lead` needs.
struct LeadInput {
    name: String,
    email: Email,
    company_name: Option<String>,
    source: LeadSource,
    notes: Option<String>,
}

fn non_blank(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

impl TryFrom<CreateLeadRequest> for LeadInput {
    type Error = Vec<FieldError>;

    fn try_from(req: CreateLeadRequest) -> Result<Self, Self::Error> {
        let name = match req.name.trim() {
            "" => Err(FieldError::new("name", "must not be empty")),
            name => Ok(name.to_string()),
        };
        let email = Email::try_from(req.email.as_str())
            .map_err(|e| FieldError::new("email", e.to_string()));

        match (name, email) {
            (Ok(name), Ok(email)) => Ok(LeadInput {
                name,
                email,
                company_name: non_blank(req.company_name),
                source: req.source.unwrap_or(LeadSource::Other),
                notes: non_blank(req.notes),
            }),
            (name, email) => Err([name.err(), email.err()].into_iter().flatten().collect()),
        }
    }
}

fn validate_deal(deal: ConvertDeal) -> Result<(String, Money), Vec<FieldError>> {
    let title = match deal.title.trim() {
        "" => Err(FieldError::new("deal.title", "must not be empty")),
        title => Ok(title.to_string()),
    };
    let value = match deal.value_cents {
        cents if cents < 0 => Err(FieldError::new("deal.value_cents", "must not be negative")),
        cents => Ok(Money::from_cents(cents)),
    };
    match (title, value) {
        (Ok(title), Ok(value)) => Ok((title, value)),
        (title, value) => Err([title.err(), value.err()].into_iter().flatten().collect()),
    }
}

fn lead_not_found(id: u64) -> CrmError {
    CrmError::NotFound { entity: "lead", id }
}
```

`match req.name.trim() { "" => ..., name => ... }` matches a `&str` against a literal pattern,
and the second arm binds whatever else it is. Field names for nested objects use a dot
(`"deal.title"`), so a client can map errors back to nested form fields.

And the handlers:

```rust
// ---------- handlers ----------

async fn create_lead(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateLeadRequest>,
) -> Result<(StatusCode, Json<LeadResponse>), ApiError> {
    let input = LeadInput::try_from(req)?;
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let id = crm.add_lead(
            input.name,
            input.email,
            input.company_name,
            input.source,
            input.notes,
        )?;
        LeadResponse::from(crm.leads.get(id).expect("lead was just inserted"))
    };
    state.persist().await?;
    Ok((StatusCode::CREATED, Json(response)))
}

async fn list_leads(
    State(state): State<AppState>,
    AppQuery(pagination): AppQuery<Pagination>,
) -> Json<Page<LeadResponse>> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let leads: Vec<&Lead> = crm.leads.iter().collect();
    Json(Page::paginate(leads, pagination).map(LeadResponse::from))
}

async fn get_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<LeadResponse>, ApiError> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let lead = crm.leads.get(LeadId(id)).ok_or(lead_not_found(id))?;
    Ok(Json(LeadResponse::from(lead)))
}

async fn qualify_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<LeadResponse>, ApiError> {
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        crm.qualify_lead(LeadId(id))?;
        LeadResponse::from(crm.leads.get(LeadId(id)).ok_or(lead_not_found(id))?)
    };
    state.persist().await?;
    Ok(Json(response))
}

async fn disqualify_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<LeadResponse>, ApiError> {
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        crm.disqualify_lead(LeadId(id))?;
        LeadResponse::from(crm.leads.get(LeadId(id)).ok_or(lead_not_found(id))?)
    };
    state.persist().await?;
    Ok(Json(response))
}

async fn convert_lead(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
    AppJson(req): AppJson<ConvertLeadRequest>,
) -> Result<(StatusCode, Json<ConversionResponse>), ApiError> {
    let deal = req.deal.map(validate_deal).transpose()?;
    let summary = state
        .crm
        .write()
        .expect("crm lock poisoned")
        .convert_lead(LeadId(id), deal)?;
    state.persist().await?;
    Ok((
        StatusCode::CREATED,
        Json(ConversionResponse {
            company_id: summary.company_id.0,
            contact_id: summary.contact_id.0,
            deal_id: summary.deal_id.map(|id| id.0),
        }),
    ))
}
```

Finally `pub mod leads;` and `.merge(leads::routes())` in `src/http/mod.rs`.

**`req.deal.map(validate_deal).transpose()?`** packs a lot into one line:

```text
req.deal                     : Option<ConvertDeal>
  .map(validate_deal)        : Option<Result<(String, Money), Vec<FieldError>>>
  .transpose()               : Result<Option<(String, Money)>, Vec<FieldError>>
  ?                          : Option<(String, Money)>   (or return 422)
```

"No deal" is fine (`None` → `Ok(None)`); "a deal with bad fields" is a 422; "a valid deal" is
`Some`. `transpose` swaps the two wrappers so `?` can act on the `Result`.

**Why `201 Created` for convert?** The request created new resources (a company, a contact,
maybe a deal). The body tells the client their IDs, so it can fetch them.

**Convert always takes a JSON body**, even if it's just `{}`, because `AppJson` requires one.
A bodiless `POST /leads/1/convert` is a 400 that names the missing content type. That's a
deliberate, documented contract: the client states "no deal" explicitly instead of by omission.

---

## Step 5 — Money and time on the wire

**Money is integer cents: `"value_cents": 1250000`.** Lab 18 showed `0.1 + 0.2 != 0.3`. JSON is
worse: the spec says numbers are just "numbers", and JavaScript (most of your clients) parses
every JSON number into an `f64`. A JSON field named `value: 12500.10` would be a float the moment
a browser touches it. Cents as an integer are exact. An `f64` represents every integer up to 2⁵³
exactly, which in cents is about 90 trillion dollars, so the integer stays exact on the client
too. The `_cents` suffix in the field *name* makes the unit impossible to miss. Formatting
(`$12,500.00`) is the client's job. It knows the user's locale.

`Money`'s own `Serialize` (from Lab 21) produced whatever shape suited the JSON *file*. The API
doesn't depend on it: response DTOs read `money.cents()` explicitly. That decoupling is the point
of DTOs. You can change the file format without breaking API clients, and vice versa.

**Timestamps are RFC 3339 strings**, which is what chrono's `serde` feature produces for
`DateTime<Utc>`: `"2026-10-01T09:30:00Z"`. On input, any offset is accepted and converted to
UTC: `"2026-10-01T11:30:00+02:00"` comes back as `"2026-10-01T09:30:00Z"`. Not-a-date
(`"yesterday"`) is a 400 from the JSON extractor. You get all of that from the type
`DateTime<Utc>` in your DTO, with no parsing code.

---

## Step 6 — API tests with `oneshot`

Until now, testing the API meant starting a server and typing `curl`. We want the opposite:
`cargo test`, no ports, no files, run in CI on every push (Lab 24's workflow already runs
`cargo test`).

### The idea: a router is a function from request to response

Axum's `Router` implements tower's `Service` trait. Simplified:

```rust
pub trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;
    fn call(&mut self, req: Request) -> Self::Future;   // (+ poll_ready, for back-pressure)
}
```

A `Service` is an async function from a request to a response. That's what `axum::serve`
calls for each request that arrives over TCP. A test can call it **directly**: build an
`http::Request` in memory, hand it to the router, await the `Response`. Everything runs:
routing, extractors, handlers, `IntoResponse`, `persist()` (into `InMemoryStorage`). Only the TCP
socket and hyper's HTTP parsing are skipped.

`tower::ServiceExt::oneshot(self, req)` is the convenience for "wait until ready, call once,
await the result".

```bash
cargo add --dev tower --features util
cargo add --dev http-body-util
```

`tower` is already in your dependency tree (axum uses it), but you need it as a **direct**
dev-dependency to `use` it, with the `util` feature that contains `ServiceExt`. `http-body-util`
gives `BodyExt::collect()`, which reads a streaming response body into bytes. The resolver
unifies versions with axum's own `tower`; check `cargo tree -i tower` if you're curious.

### One test binary: `tests/api/`

Each file directly in `tests/` is compiled as a **separate** crate. Lab 24 handled shared code
with the `tests/common/mod.rs` trick. A directory with a `main.rs` is a tidier option: Cargo
compiles `tests/api/main.rs` as **one** test binary named `api`, and the other files in the
folder are ordinary modules of it.

> 🟢 **FOLLOW ALONG**: create `tests/api/main.rs`

```rust
//! API tests: the whole router, driven in-process with `oneshot`. No network, no files.

mod companies;
mod helpers;
```

(You'll add `mod contacts; mod deals; mod leads;` in Your Turn 4.)

> 🟢 **FOLLOW ALONG**: create `tests/api/helpers.rs`

```rust
//! Shared plumbing for API tests.

use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use http_body_util::BodyExt;
use rust_crm::http::{self, AppState};
use serde_json::Value;
use tower::ServiceExt;

/// A fresh API backed by an empty, in-memory CRM. Every test gets its own.
pub fn app() -> Router {
    http::router(AppState::in_memory())
}

/// Send one request through the router and return the status and JSON body.
/// An empty body (e.g. 204 No Content) comes back as `Value::Null`.
pub async fn send(app: &Router, request: Request<Body>) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request)
        .await
        .expect("the router itself never fails");
    let status = response.status();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("reading the body")
        .to_bytes();
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).expect("response body is JSON")
    };
    (status, body)
}

pub fn get(uri: &str) -> Request<Body> {
    Request::builder().uri(uri).body(Body::empty()).unwrap()
}

pub fn delete(uri: &str) -> Request<Body> {
    empty_request(Method::DELETE, uri)
}

/// A POST without a body, for action endpoints like `/leads/{id}/qualify`.
pub fn post(uri: &str) -> Request<Body> {
    empty_request(Method::POST, uri)
}

fn empty_request(method: Method, uri: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .body(Body::empty())
        .unwrap()
}

pub fn post_json(uri: &str, body: Value) -> Request<Body> {
    json_request(Method::POST, uri, body)
}

pub fn put_json(uri: &str, body: Value) -> Request<Body> {
    json_request(Method::PUT, uri, body)
}

fn json_request(method: Method, uri: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// Create a company and return its id. Panics if the API refuses.
pub async fn create_company(app: &Router, name: &str) -> u64 {
    let (status, body) = send(app, post_json("/companies", serde_json::json!({ "name": name }))).await;
    assert_eq!(status, StatusCode::CREATED, "creating company failed: {body}");
    body["id"].as_u64().unwrap()
}

/// The `error.code` of an error response, e.g. `"not_found"`.
pub fn error_code(body: &Value) -> &str {
    body["error"]["code"].as_str().unwrap_or("<no error code>")
}
```

(`rust_crm::http::AppState` must be reachable from outside the crate. Lab 27 re-exported it
with `pub use state::AppState;`. If your `state` module is `pub mod state`, use
`rust_crm::http::state::AppState` instead.)

Until Your Turn 4 uses it, you'll see `warning: function post is never used`. A test target is
its own little crate, and `pub` inside one of its private modules doesn't export anything, so
the compiler knows nobody else can call it. The warning disappears once `leads.rs` uses `post`.

Before reading on, let the compiler explain two lines of `send`.

> 🟡 **EXPERIMENT 1**: delete `use tower::ServiceExt;` and run `cargo test --test api`.

```text
error[E0599]: no method named `oneshot` found for struct `Router<S>` in the current scope
   --> tests/api/helpers.rs:20:10
    |
 18 |       let response = app
    |  ____________________-
 19 | |         .clone()
 20 | |         .oneshot(request)
    | |_________-^^^^^^^
    |
    = help: items from traits can only be used if the trait is in scope
help: trait `ServiceExt` which provides `oneshot` is implemented but not in scope; perhaps you want to import it
```

`oneshot` isn't a method of `Router`. It's a method of the **extension trait** `ServiceExt`,
implemented for every `Service`. Trait methods are only callable when the trait is in scope (Lab
15). Same pattern as `BodyExt::collect` and `std::io::Write::flush`. Put the `use` back.

> 🟡 **EXPERIMENT 2**: remove `.clone()` (so it's `app.oneshot(request)`) and run again.

```text
error[E0507]: cannot move out of `*app` which is behind a shared reference
  --> tests/api/helpers.rs:19:20
   |
19 |     let response = app
   |                    ^^^ move occurs because `*app` has type `Router`, which does not implement the `Copy` trait
20 |         .oneshot(request)
   |          ---------------- `*app` moved due to this method call
   |
note: `tower::ServiceExt::oneshot` takes ownership of the receiver `self`, which moves `*app`
```

Ownership questions. Who owns the router? The test, and `send` only **borrows** it (`&Router`).
What does `oneshot` want? `self`, ownership: it consumes the service. You can't move a value out
from behind a shared reference (E0507, Lab 08). So we hand `oneshot` its **own** router:
`app.clone()`.

Isn't cloning the whole API for every request expensive? No. A `Router` is internally a few
`Arc`s (Lab 25): cloning bumps reference counts. And `AppState` is `Clone` because it's
`Arc<RwLock<Crm>>` + `Arc<dyn Storage>`, so **every clone shares the same `Crm`**. That's why a
test can `POST` with one clone and `GET` with another and see the data. Put `.clone()` back.

Why did `send` take `&Router` rather than `Router`? Taking ownership would force every test to
write `send(app.clone(), ...)`. Borrowing keeps the tests tidy and puts the clone in one place.

### The first tests

> 🟢 **FOLLOW ALONG**: `tests/api/companies.rs`

```rust
use axum::http::StatusCode;
use serde_json::json;

use crate::helpers::{app, create_company, delete, error_code, get, post_json, put_json, send};

#[tokio::test]
async fn create_then_get_company() {
    let app = app();

    let (status, created) = send(&app, post_json("/companies", json!({ "name": "Acme" }))).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["name"], "Acme");
    assert_eq!(created["lifecycle"], "prospect");

    let id = created["id"].as_u64().unwrap();
    let (status, fetched) = send(&app, get(&format!("/companies/{id}"))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(fetched, created);
}

#[tokio::test]
async fn invalid_company_reports_every_field() {
    let app = app();
    let (status, body) = send(
        &app,
        post_json("/companies", json!({ "name": " ", "website": "acme.test" })),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error_code(&body), "validation_failed");
    let fields: Vec<&str> = body["error"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["field"].as_str().unwrap())
        .collect();
    assert_eq!(fields, ["name", "website"]);
}

#[tokio::test]
async fn malformed_json_is_a_400() {
    let app = app();
    let request = axum::http::Request::builder()
        .method("POST")
        .uri("/companies")
        .header("content-type", "application/json")
        .body(axum::body::Body::from("{\"name\": "))
        .unwrap();
    let (status, body) = send(&app, request).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&body), "bad_request");
}

#[tokio::test]
async fn unknown_company_is_404() {
    let (status, body) = send(&app(), get("/companies/999")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error_code(&body), "not_found");
}

#[tokio::test]
async fn update_replaces_fields() {
    let app = app();
    let id = create_company(&app, "Acme").await;
    let (status, body) = send(
        &app,
        put_json(
            &format!("/companies/{id}"),
            json!({ "name": "Acme Corp", "website": "https://acme.test", "lifecycle": "customer" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "Acme Corp");
    assert_eq!(body["lifecycle"], "customer");
}

#[tokio::test]
async fn delete_company_then_it_is_gone() {
    let app = app();
    let id = create_company(&app, "Acme").await;
    let (status, body) = send(&app, delete(&format!("/companies/{id}"))).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(body.is_null());
    let (status, _) = send(&app, get(&format!("/companies/{id}"))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn list_filters_and_paginates() {
    let app = app();
    for name in ["Acme", "Globex", "Acme Labs", "Initech"] {
        create_company(&app, name).await;
    }

    let (status, body) = send(&app, get("/companies?search=acme")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["total"], 2);

    let (_, body) = send(&app, get("/companies?page=2&per_page=3")).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 1);
    assert_eq!(body["items"][0]["name"], "Initech");
    assert_eq!(body["total"], 4);
    assert_eq!(body["page"], 2);
}

#[tokio::test]
async fn bad_query_parameter_is_a_400() {
    let (status, body) = send(&app(), get("/companies?lifecycle=vip")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&body), "bad_request");
}
```

Notes on style:

- **Every test calls `app()`**, so every test has its own empty `Crm`. Tests don't share
  state, so cargo can (and does) run them in parallel, in any order.
- **`#[tokio::test]`** builds a runtime per test, so the test body can `.await`.
- **`serde_json::Value` indexing** (`body["error"]["code"]`) never panics. A missing key gives
  `Value::Null`, so a wrong path fails the *assertion* with a readable diff instead of crashing.
  `assert_eq!(created["name"], "Acme")` works because `Value` implements `PartialEq<&str>`.
- **Test names are sentences** describing the behaviour (Lab 24's convention). When one fails,
  the name is the bug report.
- **We assert on `status` and `code`, not on full message strings**, except where the exact text
  *is* the contract. Messages get reworded; codes are what clients branch on.

---

## ▶️ Run It

```bash
cargo test --test api
```

Then the whole suite and the linters:

```bash
cargo fmt --check && cargo clippy --all-targets && cargo test
```

And by hand, against a fresh file:

```bash
CRM_DATA_FILE=lab29-demo.json cargo run
```

```bash
J='content-type: application/json'
for n in "Acme Corp" "Globex" "Initech" "Umbrella" "Acme Labs"; do
  curl -s localhost:3000/companies -H "$J" -d "{\"name\":\"$n\"}" > /dev/null
done
curl -s -X PUT localhost:3000/companies/2 -H "$J" -d '{"name":"Globex","lifecycle":"customer"}' > /dev/null

curl -s 'localhost:3000/companies?page=2&per_page=2'
curl -s 'localhost:3000/companies?search=acme'
curl -s 'localhost:3000/companies?lifecycle=customer'
curl -s 'localhost:3000/companies?lifecycle=vip'
curl -s 'localhost:3000/companies?page=abc'

curl -s localhost:3000/leads -H "$J" \
  -d '{"name":"Grace Hopper","email":"grace@navy.example","company_name":"US Navy","source":"referral"}'
curl -s -X POST localhost:3000/leads/1/qualify
curl -s -X POST localhost:3000/leads/1/convert -H "$J" \
  -d '{"deal":{"title":"Compiler licences","value_cents":1250000}}'
curl -s localhost:3000/leads/1
curl -s localhost:3000/leads -H "$J" -d '{"name":"Alan Turing","email":"alan@bletchley.example"}'
curl -s -X POST localhost:3000/leads/2/convert -H "$J" -d '{}'
curl -s -X POST localhost:3000/leads/2/convert
```

## ✅ Expected Result

```text
running 8 tests
test companies::unknown_company_is_404 ... ok
test companies::bad_query_parameter_is_a_400 ... ok
test companies::malformed_json_is_a_400 ... ok
test companies::invalid_company_reports_every_field ... ok
test companies::create_then_get_company ... ok
test companies::update_replaces_fields ... ok
test companies::delete_company_then_it_is_gone ... ok
test companies::list_filters_and_paginates ... ok

test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

(The order varies between runs. The tests run in parallel.)

The `curl` session (IDs assume a fresh data file):

```text
{"items":[{"id":3,"name":"Initech","website":null,"lifecycle":"prospect"},{"id":4,"name":"Umbrella","website":null,"lifecycle":"prospect"}],"page":2,"per_page":2,"total":5}
{"items":[{"id":1,"name":"Acme Corp","website":null,"lifecycle":"prospect"},{"id":5,"name":"Acme Labs","website":null,"lifecycle":"prospect"}],"page":1,"per_page":20,"total":2}
{"items":[{"id":2,"name":"Globex","website":null,"lifecycle":"customer"}],"page":1,"per_page":20,"total":1}
{"error":{"code":"bad_request","message":"Failed to deserialize query string: lifecycle: unknown variant `vip`, expected one of `prospect`, `customer`, `churned`"}}
{"error":{"code":"bad_request","message":"Failed to deserialize query string: page: invalid digit found in string"}}

{"id":1,"name":"Grace Hopper","email":"grace@navy.example","company_name":"US Navy","source":"referral","status":"new","notes":null}
{"id":1,"name":"Grace Hopper","email":"grace@navy.example","company_name":"US Navy","source":"referral","status":"qualified","notes":null}
{"company_id":6,"contact_id":1,"deal_id":1}
{"error":{"code":"not_found","message":"no lead with id 1"}}
{"id":2,"name":"Alan Turing","email":"alan@bletchley.example","company_name":null,"source":"other","status":"new","notes":null}
{"error":{"code":"conflict","message":"lead #2 must be qualified before it can be converted"}}
{"error":{"code":"bad_request","message":"Expected request with `Content-Type: application/json`"}}
```

The converted lead is **gone** (`404`). Lab 19's `convert(self)` consumed it, and the API inherits
that rule for free. The failed conversion of lead 2 handed the lead back (Lab 19's
`ConvertError { lead, .. }`), so lead 2 still exists. Your Turn 4 has a test for exactly that.

## 🧠 Understand It

**What the tests cover, and what they don't.** `oneshot` exercises everything from routing to
`IntoResponse`. It skips `main.rs`: binding the port, the real `JsonFileStorage`, and hyper's
HTTP/1 parsing. Those are thin and change rarely. Lab 38 adds one smoke test that starts the
real server on port 0. The trade-off is the usual one: in-process tests are fast and
deterministic, so you write many of them. End-to-end tests are slow and realistic, so you write
few.

**Why `AppState::in_memory()` is the key to testability.** Lab 23's `Storage` trait let the CLI
choose JSON or memory. Here it lets every test get a CRM whose `persist()` is a no-op, with no
temp files and no cleanup. In Lab 33, the same seam becomes a fresh Postgres database per test
(`#[sqlx::test]`), and the `helpers::app()` / `helpers::send()` shape stays the same.

**Action endpoints, one more time.** Look at what each layer does for `POST /deals/{id}/stage`:
the DTO says *which* operation (`{"stage": "won"}`), the handler calls exactly one domain method
(`Crm::move_deal`), the domain enforces the rule (`can_transition_to`), and `ApiError` turns the
domain's `InvalidTransition` into `409 invalid_transition`. No layer duplicates another's job.
That's also why Lab 31 can move the rule enforcement into a SQL `UPDATE ... WHERE stage = $old`
without changing the URL.

**Two instantiations of one generic in one line.**
`Page::paginate(crm.list_companies(&filter), pagination).map(CompanyResponse::from)`:
`Page<T>` is first `Page<&Company>`, a borrowed type whose lifetime is tied to the read guard,
then `map` produces `Page<CompanyResponse>`, which owns its data. The compiler makes sure the
borrowed version never outlives the guard. Try skipping the `map`: change the return type to
`Json<Page<&Company>>` and return `Json(page)`. First you get E0106 ("this function's return type
contains a borrowed value, but there is no value for it to be borrowed from"). Follow its
suggestion and write `&'static Company`, and you get the real answer:

```text
error[E0515]: cannot return value referencing local variable `crm`
  --> src/http/companies.rs:86:5
   |
85 |     let page = Page::paginate(crm.list_companies(&filter), pagination);
   |                               --- `crm` is borrowed here
86 |     Json(page)
   |     ^^^^^^^^^^ returns a value referencing data owned by the current function
```

The companies live inside the `Crm`, which is only reachable through the guard `crm`, and the
guard is dropped when the handler returns. Who owns the data? The `Crm` behind the lock. How long
must the reference live? Until axum serializes the response, which is after the function returns.
Those don't fit, so we copy into owned DTOs. (Lab 10's E0515/E0597 lessons, in a web handler.)

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: `nest`.** Rewrite `leads::routes()` with relative paths (`"/"`, `"/{id}"`,
> `"/{id}/qualify"`, …) and in `router()` replace `.merge(leads::routes())` with
> `.nest("/leads", leads::routes())`. Run the tests (they still pass), then
> `curl -i localhost:3000/leads` and `curl -i localhost:3000/leads/` (trailing slash).
> In axum 0.8 the first is 200 and the second is **404**: a nested `/` matches the prefix
> exactly. Which style do you find easier to read in `leads.rs`? Revert or keep it, but be
> consistent across modules.

> 🟡 **EXPERIMENT 2: clamping.** Predict the response to `GET /companies?page=0&per_page=1000`
> before you run it. Then write a test for it in `tests/api/companies.rs`.

> 🟡 **EXPERIMENT 3: break a test on purpose.** In `create_then_get_company`, change `"Acme"` to
> `"Acme Inc"` in the first `assert_eq!`. Run `cargo test --test api create_then` (a filter, Lab
> 24). Read the failure output: `left: String("Acme")`, `right: "Acme Inc"`. `assert_eq!`
> prints both sides with `Debug`, so you see the actual JSON value, including its type. Undo it.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: contact listing with filters**
>
> - `GET /contacts` returns a `Page<ContactResponse>` and accepts `company_id`, `search`, and
>   `sort` (`id` | `name` | `email`, default `id`) plus the usual `page`/`per_page`. Map the query
>   onto your Lab 17 `ContactFilter` with a `ContactQuery` struct and a `From` impl, as companies
>   do. Make `ContactSort` deserializable (snake_case). An unknown sort value is a **400**.
> - `GET /companies/{id}/contacts` returns a **plain JSON array** of that company's contacts
>   (`Crm::contacts_of`), or **404** if the company doesn't exist (an empty array would hide a
>   typo in the id).
> - The nested route belongs in `companies::routes()` (its URL starts with `/companies`).
>
> - [ ] `GET /contacts?company_id=6&sort=name` after the Run It session →
>       `{"items":[{"id":1,"name":"Grace Hopper","email":"grace@navy.example","phone":null,"company_id":6}],"page":1,"per_page":20,"total":1}`
> - [ ] `GET /contacts?sort=age` → 400 `bad_request`
> - [ ] `GET /companies/99/contacts` → 404 `not_found`

> 🔵 **YOUR TURN 2: deals and the pipeline**
>
> Create `src/http/deals.rs` with `pub fn routes() -> Router<AppState>`:
>
> | Route | Body / query | Success | Notes |
> |---|---|---|---|
> | `POST /deals` | `{"company_id": 2, "title": "Renewal", "value_cents": 250050}` | **201** `DealResponse` | blank title / negative value → 422 with **both** field errors; unknown company → 404 |
> | `GET /deals` | `?stage=&company_id=&page=&per_page=` | **200** `Page<DealResponse>` | unknown stage → 400 |
> | `GET /deals/{id}` | | **200** `DealResponse` | 404 |
> | `POST /deals/{id}/stage` | `{"stage": "won"}` | **200** `DealResponse` (after the move) | rule violation → **409 `invalid_transition`**; unknown stage name → 400 |
> | `GET /pipeline` | | **200** `[{"stage","count","total_cents"}, …]` | all five stages, in order |
>
> `DealResponse` is `{"id", "company_id", "title", "value_cents", "stage"}`. Use your Lab 18
> `Crm::add_deal`, `Crm::move_deal` and `Crm::pipeline_report`. The response DTOs read
> `Money::cents()`. No floats anywhere.
>
> Against the Run It data:

```text
GET  /deals/1                         → 200 {"id":1,"company_id":6,"title":"Compiler licences","value_cents":1250000,"stage":"qualification"}
POST /deals/1/stage {"stage":"negotiation"}
  → 409 {"error":{"code":"invalid_transition","message":"cannot move a deal from qualification to negotiation"}}
POST /deals/1/stage {"stage":"proposal"}   → 200 {..., "stage":"proposal"}
POST /deals/1/stage {"stage":"won"}        → 200 {..., "stage":"won"}
POST /deals/1/stage {"stage":"lost"}
  → 409 {"error":{"code":"invalid_transition","message":"cannot move a deal from won to lost"}}
POST /deals {"company_id":2,"title":"","value_cents":-5}
  → 422 {"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"title","message":"must not be empty"},{"field":"value_cents","message":"must not be negative"}]}}
POST /deals {"company_id":2,"title":"Renewal","value_cents":250050}
  → 201 {"id":<n>,"company_id":2,"title":"Renewal","value_cents":250050,"stage":"qualification"}
GET  /pipeline
  → [{"stage":"qualification","count":1,"total_cents":250050},{"stage":"proposal","count":0,"total_cents":0},{"stage":"negotiation","count":0,"total_cents":0},{"stage":"won","count":1,"total_cents":1250000},{"stage":"lost","count":0,"total_cents":0}]
```

> (The new deal's id may be 2 or 3, depending on whether your Lab 19 `convert_lead` reserved
> ids before the failed conversion of lead 2. Either is correct.)

> 🔵 **YOUR TURN 3: activities, notes and history**
>
> Create `src/http/activities.rs`, `src/http/notes.rs` and `src/http/history.rs`, each with
> `routes()`.
>
> - `POST /activities` body:
>   `{"subject": "deal:1", "kind": {"type": "call", "minutes": 15}, "summary": "Intro call", "occurred_at": "2026-10-01T09:30:00Z"}`.
>   `subject` uses Lab 20's `Subject` text format (`FromStr`). `kind` is your `ActivityKind`
>   (internally tagged since Lab 21). `occurred_at` is optional and defaults to now. Invalid
>   subject text and a blank summary are **422** field errors (`subject`, `summary`). A subject
>   that doesn't exist is **404** (from `Crm::log_activity`). → **201** `ActivityResponse`
>   `{"id", "subject": "deal:1", "kind": {...}, "summary", "occurred_at"}`.
> - `GET /activities?subject=deal:1` → that subject's activities, **newest first**. A
>   missing or unparseable `subject` query parameter is a **400** (`bad_request`).
> - `POST /notes` `{"subject": "deal:1", "body": "Wants annual billing"}` → **201**
>   `{"id", "subject", "body", "created_at"}` (`created_at` = now; field errors for subject/body).
>   `GET /notes?subject=...` like activities.
> - `GET /history?subject=deal:1` → `Crm::history` as a JSON array, newest first, each item
>   tagged with its type and otherwise identical to the activity/note responses:

```json
[
  {"type":"note","id":1,"subject":"deal:1","body":"Wants annual billing","created_at":"2026-10-05T14:35:05.136072Z"},
  {"type":"activity","id":2,"subject":"deal:1","kind":{"type":"meeting","starts_at":"2026-10-02T14:00:00Z","attendees":[1]},"summary":"Demo","occurred_at":"2026-10-02T14:00:00Z"},
  {"type":"activity","id":1,"subject":"deal:1","kind":{"type":"call","minutes":15},"summary":"Intro call","occurred_at":"2026-10-01T09:30:00Z"}
]
```

> - [ ] `GET /history?subject=banana` → 400 `bad_request` whose message says what a subject looks like
> - [ ] `POST /notes {"subject":"deal-1","body":""}` → 422 with fields `subject` and `body`
> - [ ] `POST /activities` with `"kind": {"type": "fax"}` → 400
> - [ ] `"occurred_at": "2026-10-01T11:30:00+02:00"` is stored and returned as `"2026-10-01T09:30:00Z"`
> - [ ] The parsing of `?subject=` is written **once** and shared by the three list endpoints

> 🔵 **YOUR TURN 4: write the tests from behaviour lists**
>
> Turn each list into tests. One behaviour → at least one `#[tokio::test]`. Add the modules to
> `tests/api/main.rs`. Use only the helpers (add more helpers if a pattern repeats, e.g.
> `create_deal`).
>
> **`tests/api/contacts.rs`**
> 1. Creating a contact lowercases the email; `company_id` is `null` when not given.
> 2. A contact with blank name, bad email and bad phone gets one 422 listing **three** fields.
> 3. A second contact with the same email (any case) is 409 `conflict`.
> 4. A contact for a company that doesn't exist is 404.
> 5. A company with contacts can't be deleted (409 `conflict`).
> 6. `GET /contacts?company_id=X&sort=name` returns only that company's contacts, sorted;
>    `GET /companies/X/contacts` returns the same people.
> 7. Changing a contact's email to another contact's email is 409.
> 8. `GET /contacts/abc` is a JSON 400.
>
> **`tests/api/leads.rs`**
> 1. A new lead has status `new` and keeps the given source.
> 2. Converting an unqualified lead is 409, **and the lead still exists afterwards**.
> 3. A qualified lead converts with a deal: 201, the deal exists with the given `value_cents`
>    and belongs to the new company, and the lead is gone (404).
> 4. Converting with a deal whose title is blank *and* value negative is 422 with two fields.
> 5. Disqualifying a lead that doesn't exist is 404.
>
> **`tests/api/deals.rs`**
> 1. A new deal starts in `qualification` and returns the exact `value_cents` sent.
> 2. A deal for a missing company is 404.
> 3. A negative value is 422 and names the field `value_cents`.
> 4. Skipping a stage (qualification → negotiation) is 409 `invalid_transition`.
> 5. A won deal can't be moved to lost (409 `invalid_transition`).
> 6. An unknown stage name is 400.
> 7. The pipeline has five rows, and sums `total_cents` per stage correctly for a mix of
>    deals (e.g. two open deals of 10,000 and 2,550 cents plus a won deal of 5,000).
>
> - [ ] At least 20 new tests, all passing; `cargo test --test api` runs them all
> - [ ] Each test builds its own `app()`, so no test depends on another
> - [ ] `cargo clippy --all-targets` is clean (clippy also checks test code)

## 💡 Hint

> 💡 **HINT**: For every new module, copy the *shape* of `leads.rs`: `routes()`, request DTOs,
> response DTOs with `From<&Domain>`, a private validated-input type with `TryFrom`, then
> handlers that validate → lock → call one `Crm` method → convert → drop the lock → `persist`.

<details><summary>Hint 2 (filters for deals)</summary>

You don't need a `DealFilter` type. `InMemoryRepo::find_where` (Lab 17) takes a closure, and
`Option::is_none_or` reads nicely for "no filter, or the filter matches":
`query.stage.is_none_or(|stage| d.stage == stage)`.

</details>

<details><summary>Hint 3 (history response shape)</summary>

An enum with `#[serde(tag = "type", rename_all = "snake_case")]` whose variants wrap your two
response structs, `Activity(ActivityResponse)` and `Note(NoteResponse)`, serializes exactly like
the example: the struct's fields plus a `"type"` key. Implement `From<HistoryItem<'_>>` for it.
The nested `kind` object has its own `"type"` key, but it's nested, so there's no clash.

</details>

<details><summary>Hint 4 (sharing the subject query)</summary>

A small `#[derive(Deserialize)] pub struct SubjectQuery { pub subject: String }` with a method
`fn parse(&self) -> Result<Subject, ApiError>` that maps a parse failure to
`ApiError::BadRequest(...)`. Put it in one module and `use super::that_module::SubjectQuery` from
the others. Why a `String` and not `Subject` directly? Lab 21 serializes `Subject` as
`{"deal": 3}` for the JSON file. Its `Deserialize` doesn't understand `deal:3`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. What does the `S` in `Router<S>` mean, and what does `.with_state` change about the type?
2. Why do two `Query` extractors work in one handler, and why does `#[serde(flatten)]` fail for
   numeric query parameters?
3. Why is `POST /deals/{id}/stage` better than `PATCH /deals/{id}` for this domain? When *is* a
   plain field update the right design?
4. Why is money `value_cents: i64` in JSON?
5. Why does `oneshot` need `app.clone()`, and why is that clone cheap? Why does data written via
   one clone show up in another?
6. What does an in-process API test skip, compared with `curl` against `cargo run`?
7. What happens in debug vs release when `(page - 1) * per_page` overflows?

Then verify: `cargo fmt --check && cargo clippy --all-targets && cargo test`

## Git Commit
Delete `lab29-demo.json` first (or add it to `.gitignore`), so `git add .` doesn't commit it.

```bash
git add .
git commit -m "Add remaining REST endpoints"
```

After Your Turn 4:

```bash
git add .
git commit -m "Add API tests"
git tag lab-29
git push && git push --tags
```

> 🏁 **Phase 8 is done.** Next up is [Challenge D: Tags](../../challenges/D-tags/README.md):
> many-to-many tags on companies and contacts, with no step-by-step instructions.

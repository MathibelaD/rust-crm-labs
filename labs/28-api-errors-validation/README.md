# Lab 28 — API Errors & Validation

> **Phase:** 8 — The CRM Becomes a Web API · **Builds on:** Lab 27 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-27` · **After:** tag `lab-28`

## 🎯 Goal
Make the API **predictable**. Every failure gets the right status code and the same JSON shape,
invalid input is rejected *at the boundary* with **every** problem listed at once, and internal
errors never leak to clients. Then use that machinery to finish full CRUD for companies and
contacts.

## 🧠 What You'll Learn
- That `IntoResponse` is **just a trait**: turning an error into an HTTP response is one
  `impl` block, not framework magic
- How `Result<T, E>` becomes a response, and why that means a handler can use `?`
- What `?` really does (`From::from` on the error) and how `From` impls let one error type
  absorb many others
- The **orphan rule** (E0117), and why you can implement `IntoResponse` for your own `ApiError`
  but not for `serde_json::Error`
- Exhaustive `match` as a design tool: adding an error variant forces you to decide its status code
- Extractor **rejections**: what axum does when `Json<T>` or `Path<T>` can't parse the request,
  and how to replace its plain-text answers with your own JSON
- `TryFrom<Request> for NewX`: validation at the boundary that **collects all field errors**
  instead of stopping at the first
- `#[axum::debug_handler]` for readable handler errors

## 🔨 What We're Building
After Lab 27, your API "works", but try a few bad requests against the tag `lab-27` server:

```text
$ curl -i localhost:3000/companies/99
HTTP/1.1 404 Not Found
content-length: 0

$ curl -i localhost:3000/companies -H 'content-type: application/json' -d '{"name": "Acme",'
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
content-length: 87

Failed to parse the request body as JSON: EOF while parsing a value at line 1 column 16

$ curl -i localhost:3000/companies -H 'content-type: application/json' -d '{"name": "   "}'
HTTP/1.1 201 Created
content-type: application/json
content-length: 59

{"id":1,"name":"   ","website":null,"lifecycle":"prospect"}
```

An empty body, a plain-text body, and a company called `"   "` that was happily created. A
frontend developer would have to special-case every endpoint. By the end of this lab every error
looks like this:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "request has invalid fields",
    "fields": [
      { "field": "name", "message": "must not be empty" },
      { "field": "website", "message": "must be an http:// or https:// URL" }
    ]
  }
}
```

…with one status-code policy for the whole API:

| Situation | Status | `code` |
|---|---|---|
| Request can't be read: malformed JSON, wrong JSON types, wrong content type, bad path or query parameter | **400** | `bad_request` |
| Entity doesn't exist (`CrmError::NotFound`) | **404** | `not_found` |
| Business rule conflict: duplicate email, company still has contacts, lead not qualified | **409** | `conflict` |
| Deal stage move not allowed (`CrmError::InvalidTransition`) | **409** | `invalid_transition` |
| Request was readable but its fields are invalid | **422** | `validation_failed` (+ `fields`) |
| Anything that is *our* fault (disk full, bug) | **500** | `internal`, with a generic message |

The routes after this lab:

```text
GET    /health
GET    /companies            POST /companies
GET    /companies/{id}       PUT  /companies/{id}    DELETE /companies/{id}
GET    /contacts             POST /contacts                                   ← Your Turn
GET    /contacts/{id}        PUT  /contacts/{id}     DELETE /contacts/{id}    ← Your Turn
```

> This lab assumes you completed the Your Turn in **Lab 27** (`GET /contacts` and
> `GET /contacts/{id}` with a `ContactResponse` DTO). See
> [Lab 27's solutions.md](../27-axum-basics/solutions.md) if not.

> Written against **axum 0.8** (0.8.9), **serde 1**, **anyhow 1** and **thiserror 2**. Axum
> changes more between minor versions than most crates. If an API looks different, check
> [docs.rs/axum](https://docs.rs/axum) for the version in your `Cargo.lock`.

---

## Step 1 — `IntoResponse` is just a trait

In Lab 27 your handlers returned things like `Json<Vec<CompanyResponse>>`,
`(StatusCode, Json<CompanyResponse>)` and `Result<Json<CompanyResponse>, StatusCode>`. Axum
accepted all of them. That's not because axum special-cases those types. It's because every one
of them implements this trait from `axum::response` (simplified):

```rust
pub trait IntoResponse {
    fn into_response(self) -> Response;
}
```

That's the whole contract. After your handler's future finishes, axum calls `.into_response()`
on whatever it returned, and sends the resulting `Response` (status, headers, body) to the client.

Some implementations axum ships, and what they produce:

| Your handler returns | `into_response()` produces |
|---|---|
| `StatusCode` | that status, empty body |
| `String` / `&'static str` | 200, `text/plain` body |
| `Json<T>` where `T: Serialize` | 200, `application/json` body |
| `(StatusCode, R)` where `R: IntoResponse` | `R`'s response, with the status replaced |
| `Result<T, E>` where **both** `T` and `E` implement `IntoResponse` | `Ok(t)` → `t.into_response()`, `Err(e)` → `e.into_response()` |

The last row is the important one. Axum has no idea what an "error" is. A `Result` is a value that
is one of two responses. So if we write our own error type and implement `IntoResponse` for it,
handlers can return `Result<Json<CompanyResponse>, ApiError>`, and since the return type is a
`Result`, they can use `?`.

> 🧠 **Mental model.** If you've used Express, think of `IntoResponse` as the job of the
> error-handling middleware `(err, req, res, next) => ...`. The difference is *when* it's checked.
> In Express, nothing guarantees that an error object you throw can be rendered. In Rust, a
> handler whose return type can't become a response **does not compile**. You'll see that error in
> Step 3.

---

## Step 2 — The error type: `ApiError`

First enable axum's `macros` feature. You'll use two of its macros in this lab
(`#[axum::debug_handler]` and `#[derive(FromRequest)]`):

```bash
cargo add axum --features macros
```

Now design the type. Every handler failure belongs to one of four groups:

1. **A business rule said no.** We already have a type for that: `CrmError` (`NotFound`,
   `DuplicateEmail`, `InvalidTransition`, …).
2. **The client sent invalid fields.** We need a *list* of problems, each tied to a field name.
3. **The client sent something we can't even read** (broken JSON, a string where a number goes).
4. **We failed** (I/O error while saving, a bug). The client can't fix it and must not see the details.

> 🟢 **FOLLOW ALONG**: create `src/http/error.rs`

```rust
//! The one place where errors become HTTP responses.

use axum::Json;
use axum::extract::rejection::JsonRejection;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;

use crate::errors::CrmError;
use crate::storage::StorageError;

/// One problem with one field of a request body.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FieldError {
    pub field: &'static str,
    pub message: String,
}

impl FieldError {
    pub fn new(field: &'static str, message: impl Into<String>) -> Self {
        Self {
            field,
            message: message.into(),
        }
    }
}

/// Everything a handler can fail with.
#[derive(Debug)]
pub enum ApiError {
    /// A business rule said no (not found, duplicate, invalid transition, ...).
    Domain(CrmError),
    /// The request was readable but its fields were invalid (422).
    Validation(Vec<FieldError>),
    /// The request could not even be read: malformed JSON, wrong types, bad path (400).
    BadRequest(String),
    /// Our fault. Logged in full, never shown to the client (500).
    Internal(anyhow::Error),
}
```

Register it in `src/http/mod.rs` next to your other modules, and re-export the two public types
so other code can write `crate::http::ApiError`:

```rust
pub mod error;

pub use error::{ApiError, FieldError};
```

(`JsonRejection`, `StorageError` and `IntoResponse` will show "unused import" warnings until
later steps. That's fine.)

A few design decisions to notice:

- **`field: &'static str`**. Field names are always literals we write in code (`"name"`,
  `"email"`), never user input, so a `&'static str` is enough. It's a borrow that lives for the
  whole program, so `FieldError` doesn't need a lifetime parameter. The message is a `String`
  because some messages are built at runtime (`format!`, `e.to_string()`).
- **`Domain(CrmError)` wraps the domain error instead of copying its variants.** The domain
  doesn't know about HTTP, and shouldn't. `ApiError` is the adapter between the two worlds. In
  Lab 30 `CrmError` gains a database variant, and this enum barely changes.
- **`Internal(anyhow::Error)`**. For "our fault" errors we don't care about the *type*, only
  the message chain, for the logs. `anyhow::Error` (Lab 22) is exactly that: any error, plus context.

**Why not just `impl IntoResponse for CrmError`?** You *could*: both the trait's crate and your
type's crate are fine with it (more on that rule in Step 5). But `CrmError` can't express "these
three fields are invalid" or "your JSON is broken", and your domain module would start importing
axum. Keep the domain HTTP-free and put all the HTTP knowledge in one adapter type.

---

## Step 3 — Use it before it works

Let's let the compiler tell us what's missing. Change `get_company` in
`src/http/companies.rs` so that a missing company is an `ApiError` instead of a bare
`StatusCode`:

> 🟡 **EXPERIMENT**: predict first, then run `cargo check`.

```rust
use super::error::ApiError;
use crate::errors::CrmError;

pub async fn get_company(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<Json<CompanyResponse>, ApiError> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let company = crm.companies.get(CompanyId(id)).ok_or(CrmError::NotFound {
        entity: "company",
        id,
    })?;
    Ok(Json(CompanyResponse::from(company)))
}
```

(Your Lab 27 code may use `.unwrap()` instead of `.expect(...)`. Either is fine for now; see
"Understand It" for what a poisoned lock means.)

You get **two** errors. Look at the one that points at the router first:

```text
error[E0277]: the trait bound `fn(State<AppState>, Path<u64>) -> _ {get_company}: Handler<_, _>` is not satisfied
   --> src/http/mod.rs:23:17
    |
 23 |             get(companies::get_company)
    |             --- ^^^^^^^^^^^^^^^^^^^^^^ the trait `Handler<_, _>` is not implemented for fn item `fn(State<AppState>, Path<u64>) -> _ {get_company}`
    |             |
    |             required by a bound introduced by this call
    |
    = note: Consider using `#[axum::debug_handler]` to improve the error message
```

This is the classic axum error, and it's not very helpful. "Your function isn't a handler",
but *why*? A function is a `Handler` only if every argument is an extractor **and** the return
type implements `IntoResponse`. The trait system can't tell you which part failed, because the
impl it's looking for is generic over all of them at once.

Take the note's advice. Put `#[axum::debug_handler]` on the line above `pub async fn get_company`
and run `cargo check` again:

```text
error[E0277]: the trait bound `ApiError: IntoResponse` is not satisfied
   --> src/http/companies.rs:137:6
    |
137 | ) -> Result<Json<CompanyResponse>, ApiError> {
    |      ^^^^^^ unsatisfied trait bound
    |
help: the trait `IntoResponse` is not implemented for `ApiError`
   --> src/http/error.rs:27:1
    |
 27 | pub enum ApiError {
    | ^^^^^^^^^^^^^^^^^
    = note: required for `Result<Json<CompanyResponse>, ApiError>` to implement `IntoResponse`
```

(Line numbers will differ.) Now it's precise: `Result<T, E>` is a response only if `E` is, and
`ApiError` isn't one yet. `debug_handler` generates a few extra compile-time checks, one per
argument plus one for the return type, so the error points at the exact part that failed. It
costs nothing at runtime. Reach for it whenever you see `Handler<_, _> is not satisfied`.

You'll also see "`?` couldn't convert the error to `ApiError`". Leave it; Step 5 explains and
fixes it. Remove the `#[axum::debug_handler]` line once Step 4 compiles. Keeping it is harmless,
but it's a debugging aid, not documentation.

---

## Step 4 — Implement `IntoResponse`: the one place

> 🟢 **FOLLOW ALONG**: add to `src/http/error.rs`

```rust
#[derive(Serialize)]
struct ErrorBody {
    error: ErrorDetail,
}

#[derive(Serialize)]
struct ErrorDetail {
    code: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    fields: Vec<FieldError>,
}

impl ApiError {
    fn status_and_code(&self) -> (StatusCode, &'static str) {
        match self {
            ApiError::Domain(err) => match err {
                CrmError::NotFound { .. } => (StatusCode::NOT_FOUND, "not_found"),
                CrmError::DuplicateEmail(_)
                | CrmError::HasContacts(_)
                | CrmError::LeadNotQualified(_) => (StatusCode::CONFLICT, "conflict"),
                CrmError::InvalidTransition { .. } => (StatusCode::CONFLICT, "invalid_transition"),
                CrmError::Validation(_) => (StatusCode::UNPROCESSABLE_ENTITY, "validation_failed"),
                // CLI-only variants: if one reaches HTTP, that's a bug on our side.
                CrmError::UnknownCommand(_) | CrmError::Usage(_) => {
                    (StatusCode::INTERNAL_SERVER_ERROR, "internal")
                }
            },
            ApiError::Validation(_) => (StatusCode::UNPROCESSABLE_ENTITY, "validation_failed"),
            ApiError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            ApiError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = self.status_and_code();
        let (message, fields) = match self {
            ApiError::Domain(err) => (err.to_string(), Vec::new()),
            ApiError::Validation(fields) => ("request has invalid fields".to_string(), fields),
            ApiError::BadRequest(message) => (message, Vec::new()),
            ApiError::Internal(err) => (format!("{err:#}"), Vec::new()),
        };

        // The rule that keeps internals private: a 5xx body never contains details.
        let message = if status.is_server_error() {
            eprintln!("internal error: {message}");
            "internal server error".to_string()
        } else {
            message
        };

        let body = ErrorBody {
            error: ErrorDetail {
                code,
                message,
                fields,
            },
        };
        (status, Json(body)).into_response()
    }
}
```

> ⚠️ **Your `CrmError` variants may differ slightly.** Lab 22 allowed you to move
> `UnknownCommand` and `Usage` into a `cli::CliError`. If you did, delete that arm. If your
> `CrmError` has variants this match doesn't list, the compiler will tell you (that's the
> point; see the Experiment section). Decide a status for each.

Read it slowly. Everything about "error → HTTP" is in these ~50 lines:

- **`status_and_code` takes `&self`**, and returns `Copy` data (`StatusCode` and a
  `&'static str`). We need the status *before* we take `self` apart in the next `match`, which
  moves the `Vec<FieldError>` and `String`s out of it. Ask the ownership question: the
  `match self` in `into_response` **consumes** the error, so anything we want from it afterwards
  must be read first or moved out in that match.
- **The nested `match err` has no `_ =>` arm.** That's on purpose. A wildcard would quietly turn a
  future `CrmError::Archived` into whatever the wildcard says. Without one, adding a variant is a
  compile error **right here**, in the one place that decides status codes.
- **`(status, Json(body)).into_response()`**: we don't build a `Response` by hand. We reuse two
  existing `IntoResponse` impls (`(StatusCode, R)` and `Json<T>`), and get correct
  `content-type` and serialization for free.
- **`skip_serializing_if = "Vec::is_empty"`**: the `fields` key only appears on validation errors.
  Clients can rely on "if `fields` exists, it's a list of `{field, message}`".
- **`{err:#}`**: the alternate `Display` of `anyhow::Error` prints the whole chain on one line
  (`could not write crm-data.json: No such file or directory`), which is what you want in a log.

---

## Step 5 — `?`, `From`, and the orphan rule

`get_company` uses `?` on a `Result<_, CrmError>` inside a function that returns
`Result<_, ApiError>`. Here's roughly what `?` expands to:

```rust
// let company = expr?;
let company = match expr {
    Ok(value) => value,
    Err(e) => return Err(From::from(e)),   // CrmError -> ApiError, via From
};
```

So `?` works across error types as long as there is a `From` impl. Add the conversions.

> 🟢 **FOLLOW ALONG**: append to `src/http/error.rs`

```rust
impl From<CrmError> for ApiError {
    fn from(err: CrmError) -> Self {
        ApiError::Domain(err)
    }
}

impl From<Vec<FieldError>> for ApiError {
    fn from(fields: Vec<FieldError>) -> Self {
        ApiError::Validation(fields)
    }
}

impl From<StorageError> for ApiError {
    fn from(err: StorageError) -> Self {
        ApiError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(err: anyhow::Error) -> Self {
        ApiError::Internal(err)
    }
}
```

`err.into()` in the `StorageError` impl works because anyhow implements
`From<E> for anyhow::Error` for every `E: std::error::Error + Send + Sync + 'static`, and
`StorageError` (a `thiserror` type from Lab 22) qualifies.

`cargo check` should now be clean apart from unused-import warnings.

> 🟡 **EXPERIMENT**: comment out the `impl From<CrmError> for ApiError` block and run
> `cargo check`.

```text
error[E0277]: `?` couldn't convert the error to `ApiError`
   --> src/http/companies.rs:145:7
    |
142 |       let company = crm.companies.get(CompanyId(id)).ok_or(CrmError::NotFound {
    |  ____________________________________________________-
143 | |         entity: "company",
144 | |         id,
145 | |     })?;
    | |      -^ the trait `From<CrmError>` is not implemented for `ApiError`
    | |______|
    |        this can't be annotated with `?` because it has type `Result<_, CrmError>`
    |
note: `ApiError` needs to implement `From<CrmError>`
   --> src/http/error.rs:30:1
    |
 30 | pub enum ApiError {
    | ^^^^^^^^^^^^^^^^^
    = note: the question mark operation (`?`) implicitly performs a conversion on the error value using the `From` trait
    = help: `ApiError` implements trait `From<T>`:
              From<StorageError>
              From<Vec<FieldError>>
              From<anyhow::Error>
```

The compiler even tells you the desugaring: "`?` implicitly performs a conversion using the
`From` trait". Put the block back.

### Why can't we implement `IntoResponse` for *any* type?

> 🟡 **EXPERIMENT**: add this to `error.rs`, predict, run `cargo check`, then delete it.

```rust
impl IntoResponse for serde_json::Error {
    fn into_response(self) -> Response {
        (StatusCode::BAD_REQUEST, self.to_string()).into_response()
    }
}
```

```text
error[E0117]: only traits defined in the current crate can be implemented for types defined outside of the crate
   --> src/http/error.rs:126:1
    |
126 | impl IntoResponse for serde_json::Error {
    | ^^^^^^^^^^^^^^^^^^^^^^-----------------
    |                       |
    |                       `serde_json::Error` is not defined in the current crate
    |
    = note: impl doesn't have any local type before any uncovered type parameters
    = note: for more information see https://doc.rust-lang.org/reference/items/implementations.html#orphan-rules
    = note: define and implement a trait or new type instead
```

This is the **orphan rule** (Lab 15 mentioned it). `IntoResponse` belongs to axum and
`serde_json::Error` belongs to serde_json. Neither is yours. If this were allowed, axum, serde_json
and your crate could each write a *different* impl for the same pair, and the compiler would have
no way to choose. So the rule is: **for an `impl Trait for Type`, the trait or the type must be
local to your crate** (with some precise extra rules for generics). `impl IntoResponse for ApiError`
is fine because `ApiError` is yours. That's the "new type instead" the note suggests, and it's
exactly what `ApiError` is: a local type wrapping foreign errors.

---

## Step 6 — Never leak internals on 500

Every mutating handler ends with `state.persist().await`. That's the call that can fail for
reasons the client has nothing to do with. Check your `AppState::persist` from Lab 27. For `?`
to work in handlers, its error type must be one `ApiError` can absorb. This lab assumes:

```rust
// src/http/state.rs
pub async fn persist(&self) -> anyhow::Result<()> {
    let snapshot = self.crm.read().expect("crm lock poisoned").clone();
    let storage = Arc::clone(&self.storage);
    tokio::task::spawn_blocking(move || storage.save(&snapshot)).await??;
    Ok(())
}
```

If yours returns `Result<(), StorageError>`, that also works thanks to the `From<StorageError>`
impl. If it returns something else, change it to `anyhow::Result<()>`. The `.await??` unwraps two
layers: `spawn_blocking` gives `Result<Result<(), StorageError>, JoinError>`. The first `?` handles
a panicked save task (`JoinError`), the second the storage error. Both convert into
`anyhow::Error`.

Now look again at the rule in `into_response`:

```rust
let message = if status.is_server_error() {
    eprintln!("internal error: {message}");
    "internal server error".to_string()
} else {
    message
};
```

It's keyed on the **status**, not the variant. Any path that ends up as a 5xx (an
`Internal`, or a CLI-only `CrmError` that should never reach HTTP) gets a generic message. The
full message goes to the server's stderr instead. (In Lab 37 `eprintln!` becomes
`tracing::error!` with a request ID, so you can match a user's complaint to a log line.)

You'll prove it works in "Run It" by pointing the server at a directory that doesn't exist.

---

## Step 7 — Malformed JSON: extractor rejections

The parse error you saw at the start (`text/plain`, axum's wording) didn't come from your
handler. **Your handler never ran.** `Json<T>` is an *extractor*: before calling the handler,
axum runs `Json::<CreateCompanyRequest>::from_request(...)`, and if that fails, it returns the
extractor's **rejection** as the response. For `Json`, the rejection type is
`axum::extract::rejection::JsonRejection`, and it implements `IntoResponse` with plain text.

`JsonRejection` covers several failures, each with its own default status:

| Request | axum's default |
|---|---|
| No `content-type: application/json` header | 415 Unsupported Media Type |
| Body isn't valid JSON (`{"name": "Acme",`) | 400 Bad Request |
| Valid JSON, wrong shape (`{"name": 42}`) | 422 Unprocessable Entity |

We want our JSON format, and we'll use **one** rule for all three: *if we couldn't turn the body
into the request type, it's a 400 `bad_request`.* 422 is reserved for "we read your request,
and these fields break our rules", and it always comes with a `fields` list. A client can then
treat 400 as "my code is broken" and 422 as "show these messages next to the form fields".

There are three idiomatic ways to plug your error type in (all documented in axum's
`customize-extractor-error` example):

1. Take `Result<Json<T>, JsonRejection>` as the handler argument and convert by hand in every
   handler. Explicit, but repetitive.
2. Use `axum_extra::extract::WithRejection<Json<T>, ApiError>`. Needs the `axum-extra` crate.
3. **Define your own extractor that wraps `Json` and swaps the rejection.** With the `macros`
   feature this is three lines. We use this one.

> 🟢 **FOLLOW ALONG**: create `src/http/extract.rs`

```rust
//! Our own extractors: axum's, but failing with `ApiError` instead of plain text.

use axum::extract::FromRequest;

use super::error::ApiError;

/// Like `axum::Json`, but a bad body becomes our JSON error format.
#[derive(FromRequest)]
#[from_request(via(axum::Json), rejection(ApiError))]
pub struct AppJson<T>(pub T);
```

…add `pub mod extract;` to `src/http/mod.rs`, and add the conversion to `error.rs`:

```rust
impl From<JsonRejection> for ApiError {
    fn from(rejection: JsonRejection) -> Self {
        ApiError::BadRequest(rejection.body_text())
    }
}
```

The derive generates an `impl FromRequest for AppJson<T>` that runs `axum::Json::<T>`'s
extractor (`via`), and on failure converts its rejection into `ApiError` using your `From` impl
(`rejection`). Because `ApiError: IntoResponse`, axum can send it. Handlers change from
`Json(req): Json<CreateCompanyRequest>` to `AppJson(req): AppJson<CreateCompanyRequest>`.
Responses still use plain `Json(...)`: `AppJson` is only an extractor.

`rejection.body_text()` is axum's human-readable explanation, e.g.
`Failed to parse the request body as JSON: EOF while parsing a value at line 1 column 16`.
Showing it is fine: it describes the client's own input, not our internals.

---

## Step 8 — Validation at the boundary: `TryFrom<CreateCompanyRequest> for NewCompany`

`serde` checked the *shape* of the body. Now the *rules*: a name that isn't blank, a website
that looks like a URL. Where should those rules run?

```text
 HTTP JSON ──serde──► CreateCompanyRequest ──TryFrom──► NewCompany ──Crm::add_company──► Company
           (shape)     "whatever the client sent"  (rules)  "valid, but no id yet"            (stored)
```

The **request DTO** holds raw client data, so any combination of values is possible. The
**domain input type** `NewCompany` can only be obtained through validation (by convention:
`Crm` only accepts `NewCompany`, and the only code that builds one from client data is the
`TryFrom`). That's the boundary. Once you're past it, nothing downstream re-checks.

> 🟢 **FOLLOW ALONG**: add to `src/companies/model.rs` (and re-export both from
> `src/companies/mod.rs`: `pub use model::{..., CompanyUpdate, NewCompany};`)

```rust
/// A company that passed validation but has no id yet.
#[derive(Debug, Clone, PartialEq)]
pub struct NewCompany {
    pub name: String,
    pub website: Option<String>,
}

/// The full, validated replacement for a company's editable fields (PUT).
#[derive(Debug, Clone, PartialEq)]
pub struct CompanyUpdate {
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
}
```

### Collect every error, not just the first

If a form has three bad fields, the client should learn about all three in **one** round trip.
The natural Rust instinct (`?` after each check) stops at the first. Let's see why it doesn't
even compile here, and what to do instead.

> 🟢 **FOLLOW ALONG**: in `src/http/companies.rs`, give the request DTO a default for `name`
> and add the validation. Keep the DTOs, handlers and this validation together in this file.
> (If Lab 27 put the DTOs in a separate `src/http/dto.rs`, move the company ones here now.)

```rust
use super::error::{ApiError, FieldError};
use crate::companies::{Company, CompanyFilter, CompanyId, CompanyUpdate, Lifecycle, NewCompany};

#[derive(Debug, Deserialize)]
pub struct CreateCompanyRequest {
    #[serde(default)]
    pub name: String,
    pub website: Option<String>,
}

fn validate_name(raw: &str) -> Result<String, FieldError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(FieldError::new("name", "must not be empty"));
    }
    if name.chars().count() > 200 {
        return Err(FieldError::new("name", "must be at most 200 characters"));
    }
    Ok(name.to_string())
}

fn validate_website(raw: Option<String>) -> Result<Option<String>, FieldError> {
    let Some(website) = raw else { return Ok(None) };
    let website = website.trim();
    if website.is_empty() {
        return Ok(None);
    }
    let has_scheme = website.starts_with("http://") || website.starts_with("https://");
    if !has_scheme || website.contains(char::is_whitespace) {
        return Err(FieldError::new(
            "website",
            "must be an http:// or https:// URL",
        ));
    }
    Ok(Some(website.to_string()))
}
```

Each field gets its own small function returning `Result<CleanValue, FieldError>`. Notice the
types: `validate_name` **borrows** (`&str`) and returns a new owned, trimmed `String`.
`validate_website` **takes ownership** of the `Option<String>` because we may hand back part of it.

> 🟡 **EXPERIMENT**: write the obvious version first, then run `cargo check`.

```rust
impl TryFrom<CreateCompanyRequest> for NewCompany {
    type Error = Vec<FieldError>;

    fn try_from(req: CreateCompanyRequest) -> Result<Self, Self::Error> {
        let name = validate_name(&req.name)?;
        let website = validate_website(req.website)?;
        Ok(NewCompany { name, website })
    }
}
```

```text
error[E0277]: `?` couldn't convert the error to `Vec<FieldError>`
  --> src/http/companies.rs:83:44
   |
83 |         let name = validate_name(&req.name)?;
   |                    ------------------------^ the trait `From<FieldError>` is not implemented for `Vec<FieldError>`
   |                    |
   |                    this can't be annotated with `?` because it has type `Result<_, FieldError>`
   |
note: `FieldError` needs to implement `Into<Vec<FieldError>>`
```

Same lesson as Step 5: `?` needs a `From`. You *could* write
`impl From<FieldError> for Vec<FieldError>` (the orphan rule allows it, because `FieldError` is
local and appears as the trait's type parameter). It would compile, and it would be **wrong**:
`?` returns at the first error, so a request with a blank name and a bad website would only
report the name. The compiler error is pointing at a design problem, not just a missing impl.

Instead, run **every** check, then combine:

> 🟢 **FOLLOW ALONG**: replace the experiment with

```rust
impl TryFrom<CreateCompanyRequest> for NewCompany {
    type Error = Vec<FieldError>;

    fn try_from(req: CreateCompanyRequest) -> Result<Self, Self::Error> {
        let name = validate_name(&req.name);
        let website = validate_website(req.website);

        match (name, website) {
            (Ok(name), Ok(website)) => Ok(NewCompany { name, website }),
            (name, website) => Err([name.err(), website.err()].into_iter().flatten().collect()),
        }
    }
}

impl TryFrom<UpdateCompanyRequest> for CompanyUpdate {
    type Error = Vec<FieldError>;

    fn try_from(req: UpdateCompanyRequest) -> Result<Self, Self::Error> {
        let new = NewCompany::try_from(CreateCompanyRequest {
            name: req.name,
            website: req.website,
        })?;
        Ok(CompanyUpdate {
            name: new.name,
            website: new.website,
            lifecycle: req.lifecycle,
        })
    }
}
```

And the update DTO, next to `CreateCompanyRequest`:

```rust
#[derive(Debug, Deserialize)]
pub struct UpdateCompanyRequest {
    #[serde(default)]
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
}
```

How the combine works:

- `match (name, website)` matches a **tuple of results**. The first arm only matches when both
  are `Ok`, and *moves* the clean values out into the new struct.
- The second arm catches every other combination. `name.err()` turns a
  `Result<String, FieldError>` into an `Option<FieldError>` (`Some` if it was an error). An
  array of `Option`s, `.into_iter().flatten()`, keeps only the `Some`s, and `.collect()` builds the
  `Vec<FieldError>`, because the return type says so.
- The `?` in `CompanyUpdate`'s impl is fine: the error types already match
  (`Vec<FieldError>` → `Vec<FieldError>`), so no conversion is needed.

Why `#[serde(default)]` on `name`? Without it, a body with no `name` key fails in serde with
`missing field name`, which by our policy is a 400. With it, a missing name becomes `""` and
reaches validation, which reports it as a **field error**, the same as a blank name. Missing and
blank are the same problem to the client, so they should get the same answer.

Why is `lifecycle` *not* defaulted in the update? `PUT` means "here is the complete new state".
Forgetting the lifecycle is a client bug, and a 400 says so.

> 🟢 **FOLLOW ALONG**: add unit tests at the bottom of `src/http/companies.rs`. Validation is
> plain functions over plain data, so no server is needed.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn request(name: &str, website: Option<&str>) -> CreateCompanyRequest {
        CreateCompanyRequest {
            name: name.to_string(),
            website: website.map(str::to_string),
        }
    }

    #[test]
    fn valid_request_is_trimmed_into_new_company() {
        let new = NewCompany::try_from(request("  Acme  ", Some(" https://acme.example "))).unwrap();
        assert_eq!(new.name, "Acme");
        assert_eq!(new.website.as_deref(), Some("https://acme.example"));
    }

    #[test]
    fn blank_website_means_no_website() {
        let new = NewCompany::try_from(request("Acme", Some("   "))).unwrap();
        assert_eq!(new.website, None);
    }

    #[test]
    fn reports_every_invalid_field_at_once() {
        let errors = NewCompany::try_from(request("", Some("acme.example"))).unwrap_err();
        let fields: Vec<&str> = errors.iter().map(|e| e.field).collect();
        assert_eq!(fields, ["name", "website"]);
    }
}
```

---

## Step 9 — `Crm` accepts only validated input (and the compiler finds every caller)

Make the domain API say what it needs. In `src/crm.rs`, change `add_company` to take a
`NewCompany`, and add `update_company`:

> 🟢 **FOLLOW ALONG**

```rust
use crate::companies::{Company, CompanyFilter, CompanyId, CompanyUpdate, Lifecycle, NewCompany};

    pub fn add_company(&mut self, new: NewCompany) -> Result<CompanyId, CrmError> {
        let id = self.companies.next_id();
        let company = Company {
            id,
            name: new.name,
            website: new.website,
            lifecycle: Lifecycle::Prospect,
        };
        Ok(self.companies.insert(company))
    }

    pub fn update_company(
        &mut self,
        id: CompanyId,
        update: CompanyUpdate,
    ) -> Result<&Company, CrmError> {
        let company = self
            .companies
            .get_mut(id)
            .ok_or(CrmError::NotFound { entity: "company", id: id.0 })?;
        company.name = update.name;
        company.website = update.website;
        company.lifecycle = update.lifecycle;
        Ok(company)
    }
```

(Adapt the `Company { .. }` literal to your struct if Lab 27 left it different. The point is the
signature.)

> ✍️ **This is an allowed signature change** to the `Crm` API from Lab 14. From now on
> `Crm::add_company(&mut self, new: NewCompany)`. Lab 30 builds on this: the Postgres insert
> takes `&NewCompany` too.

Now run `cargo check --all-targets` (`--all-targets` includes `tests/` and the `crm-cli`
binary). Every old call site breaks:

```text
error[E0061]: this method takes 1 argument but 2 arguments were supplied
  --> src/cli/commands.rs:9:26
   |
 9 |             let id = crm.add_company(name.to_string(), None)?;
   |                          ^^^^^^^^^^^ ----------------  ---- unexpected argument #2 of type `std::option::Option<_>`
   |                                      |
   |                                      expected `NewCompany`, found `String`
   |
note: method defined here
  --> src/crm.rs:60:12
   |
60 |     pub fn add_company(&mut self, new: NewCompany) -> Result<CompanyId, CrmError> {
   |            ^^^^^^^^^^^            ---------------
```

This is the compiler doing your refactoring checklist. Fix each one by building the struct, e.g.
`crm.add_company(NewCompany { name, website })`. Expect hits in your CLI command code and in
`tests/common/mod.rs` (`sample_crm`). Don't touch the CLI's own validation: it still goes through
whatever prompts and checks Lab 14 gave it. The CLI is retired in Lab 30, so don't polish it.

> 💡 `NewCompany`'s fields are `pub`, so nothing *forces* callers through `TryFrom`. The CLI and
> tests build it directly. That's the same trade-off Lab 18 made for `Deal::stage`: public fields
> plus a convention. The invariant that really matters for data integrity, a valid `Email`, is
> enforced by a type with a private field, and no convention can bypass that.

`update_company` returns `Result<&Company, CrmError>`, a **borrow out of `&mut self`**. Lifetime
elision ties the returned reference to the `&mut self` borrow, so as long as you hold the
`&Company`, the `Crm` is still mutably borrowed. In a handler that's exactly what we want: convert
it to a DTO immediately, inside the block that holds the lock guard.

---

## Step 10 — Full CRUD for companies

> 🟢 **FOLLOW ALONG**: update the handlers in `src/http/companies.rs`

```rust
use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::{ApiError, FieldError};
use super::extract::AppJson;
use crate::companies::{Company, CompanyFilter, CompanyId, CompanyUpdate, Lifecycle, NewCompany};
use crate::errors::CrmError;

// (DTOs, From<&Company> for CompanyResponse, validation and TryFrom impls as above)

pub async fn create_company(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateCompanyRequest>,
) -> Result<(StatusCode, Json<CompanyResponse>), ApiError> {
    let new = NewCompany::try_from(req)?;

    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let id = crm.add_company(new)?;
        CompanyResponse::from(crm.companies.get(id).expect("company was just inserted"))
    };

    state.persist().await?;
    Ok((StatusCode::CREATED, Json(response)))
}

// get_company: as in Step 3 (keep the `Path` extractor for now)

pub async fn update_company(
    State(state): State<AppState>,
    Path(id): Path<u64>,
    AppJson(req): AppJson<UpdateCompanyRequest>,
) -> Result<Json<CompanyResponse>, ApiError> {
    let update = CompanyUpdate::try_from(req)?;

    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let company = crm.update_company(CompanyId(id), update)?;
        CompanyResponse::from(company)
    };

    state.persist().await?;
    Ok(Json(response))
}

pub async fn delete_company(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<StatusCode, ApiError> {
    state
        .crm
        .write()
        .expect("crm lock poisoned")
        .remove_company(CompanyId(id))?;

    state.persist().await?;
    Ok(StatusCode::NO_CONTENT)
}
```

`list_companies` doesn't change in this lab (it can't fail). Your Lab 14 `remove_company`
returns an error when the company still has contacts (`CrmError::HasContacts`). If your version
returns the removed `Company`, the `?` just discards it.

Two patterns to notice:

- **`?` on a validation `Vec<FieldError>`** works because of `From<Vec<FieldError>> for ApiError`.
  Validation runs **before** taking the lock: no point blocking other requests while we check a
  string.
- **The lock guard lives inside a block `{ ... }`** that ends *before* `.await`. Lab 27 explained
  why: a `std::sync::RwLockWriteGuard` held across an `.await` would make the handler's future
  `!Send`, and axum would refuse it. In `delete_company` the guard is a **temporary**. It's dropped
  at the end of the statement (the `;`), so it's also gone before `.await`.

Register the new methods on the existing route in `src/http/mod.rs`:

```rust
.route(
    "/companies/{id}",
    get(companies::get_company)
        .put(companies::update_company)
        .delete(companies::delete_company),
)
```

(`MethodRouter`s chain: one path, several methods.)

---

## ▶️ Run It

Start from a clean data file, so the IDs below match:

```bash
CRM_DATA_FILE=lab28-demo.json cargo run
```

In a second terminal, run each request:

```bash
curl -i localhost:3000/companies -H 'content-type: application/json' \
  -d '{"name":"Acme Corp","website":"https://acme.example"}'
curl -i localhost:3000/companies -H 'content-type: application/json' \
  -d '{"name":"  ","website":"acme.example"}'
curl -i localhost:3000/companies -H 'content-type: application/json' -d '{"name": "Acme",'
curl -i localhost:3000/companies -H 'content-type: application/json' -d '{"name": 42}'
curl -i localhost:3000/companies -d '{"name":"Acme"}'
curl -i localhost:3000/companies/99
curl -i -X PUT localhost:3000/companies/1 -H 'content-type: application/json' \
  -d '{"name":"Acme Corporation","website":null,"lifecycle":"customer"}'
curl -i -X PUT localhost:3000/companies/1 -H 'content-type: application/json' \
  -d '{"name":"Acme","lifecycle":"vip"}'
curl -i -X DELETE localhost:3000/companies/1
curl -i -X DELETE localhost:3000/companies/1
curl -i localhost:3000/companies/abc
```

Then stop the server and prove the 500 rule. Point it at a directory that doesn't exist, so
the save fails:

```bash
CRM_DATA_FILE=/no/such/dir/crm-data.json cargo run
# second terminal:
curl -i localhost:3000/companies -H 'content-type: application/json' -d '{"name":"Initech"}'
```

Delete `lab28-demo.json` when you're done (or add it to `.gitignore`).

## ✅ Expected Result

(`date:` headers removed. Your messages for domain errors come from your `CrmError`'s
`#[error(...)]` attributes, so the exact wording may differ. The **status** and **code** must
match.)

```text
HTTP/1.1 201 Created
content-type: application/json
content-length: 83

{"id":1,"name":"Acme Corp","website":"https://acme.example","lifecycle":"prospect"}

HTTP/1.1 422 Unprocessable Entity
content-type: application/json
content-length: 202

{"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"name","message":"must not be empty"},{"field":"website","message":"must be an http:// or https:// URL"}]}}

HTTP/1.1 400 Bad Request
content-type: application/json
content-length: 132

{"error":{"code":"bad_request","message":"Failed to parse the request body as JSON: EOF while parsing a value at line 1 column 16"}}

HTTP/1.1 400 Bad Request
content-type: application/json
content-length: 174

{"error":{"code":"bad_request","message":"Failed to deserialize the JSON body into the target type: name: invalid type: integer `42`, expected a string at line 1 column 11"}}

HTTP/1.1 400 Bad Request
content-type: application/json
content-length: 99

{"error":{"code":"bad_request","message":"Expected request with `Content-Type: application/json`"}}

HTTP/1.1 404 Not Found
content-type: application/json
content-length: 64

{"error":{"code":"not_found","message":"company #99 not found"}}

HTTP/1.1 200 OK
content-type: application/json
content-length: 72

{"id":1,"name":"Acme Corporation","website":null,"lifecycle":"customer"}

HTTP/1.1 400 Bad Request
content-type: application/json
content-length: 206

{"error":{"code":"bad_request","message":"Failed to deserialize the JSON body into the target type: lifecycle: unknown variant `vip`, expected one of `prospect`, `customer`, `churned` at line 1 column 32"}}

HTTP/1.1 204 No Content

HTTP/1.1 404 Not Found
content-type: application/json
content-length: 63

{"error":{"code":"not_found","message":"company #1 not found"}}

HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
content-length: 42

Invalid URL: Cannot parse `abc` to a `u64`
```

The last one is still **plain text**: the `Path` extractor has its own rejection. Your Turn 3
fixes it.

The 500 run:

```text
HTTP/1.1 500 Internal Server Error
content-type: application/json
content-length: 63

{"error":{"code":"internal","message":"internal server error"}}
```

…while the **server's** terminal shows the real cause:

```text
Listening on http://127.0.0.1:3000
internal error: could not write /no/such/dir/crm-data.json: No such file or directory (os error 2)
```

`cargo test` passes, including the three new validation tests.

## 🧠 Understand It

**Follow one failing request all the way through.** `POST /companies` with `{"name":" "}`:

```text
1. axum routes POST /companies → create_company
2. extractors run:  State ✔   AppJson<CreateCompanyRequest> ✔ (shape is fine)
3. handler body:    NewCompany::try_from(req)  → Err(vec![FieldError{name, ..}])
4. `?`:             From<Vec<FieldError>> for ApiError → return Err(ApiError::Validation(..))
5. axum:            Result<_, ApiError>::into_response() → ApiError::into_response()
6. status_and_code: (422, "validation_failed") → JSON body → client
```

And `{"name": 42}` stops at step 2: `axum::Json` fails, the derived `AppJson` extractor converts
the `JsonRejection` with `From<JsonRejection> for ApiError`, and axum sends that response
**without calling the handler**. Each layer only knows about its neighbour. The domain knows
nothing about HTTP. The handler knows the domain's error types and nothing about status codes.
`error.rs` is the only file that knows both.

**Why 404 when the URL names a missing company, but also 404 for `company_id: 42` in a contact's
body?** Purists argue a missing referenced entity inside a valid URL is a 422 ("your *body* is
wrong"), not a 404 ("this *URL* doesn't exist"). Both views are defensible. We map
`CrmError::NotFound` → 404 everywhere because it keeps the policy to one line and the message
says exactly what's missing. If you want the 422 version, the place to change it is the
contact-creation handler, not `status_and_code`. Know the trade-off and be consistent.

**Why does a 500 still leave the company in memory?** In the 500 run, `add_company` succeeded and
only `persist()` failed. The API said "error", but the company exists until the server restarts.
That's a **partial failure**: two steps that should succeed or fail together, without a mechanism
to make them. A JSON snapshot can't offer one. A database **transaction** can (Lab 31).

**What is `.expect("crm lock poisoned")` protecting?** If a thread panics *while holding* a
`std::sync` lock, the lock becomes **poisoned**: the data may be half-updated, and every later
`read()`/`write()` returns `Err`. With `.expect`, every later request would then panic too, and
the client gets a dropped connection, not a 500. For this course that's acceptable, because
handlers don't panic while holding the lock. A production API might map poisoning to
`ApiError::Internal` instead. `tokio::sync::RwLock` doesn't poison at all.

**`IntoResponse` vs `Display`.** `CrmError`'s `Display` (from `#[error("...")]`) is the human
sentence. `IntoResponse` is the HTTP representation. We reuse the first inside the second for
4xx errors, because domain messages like "a contact with email x already exists" are written for
users. Internal errors' `Display` is written for operators, which is why it goes to the log.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: the compiler as a policy checklist.** Add a variant to `CrmError` in
> `src/errors.rs`, for example `#[error("company {0} is archived")] Archived(CompanyId),`.
> Predict which files fail. Run `cargo check`.

```text
error[E0004]: non-exhaustive patterns: `&CrmError::Archived(_)` not covered
  --> src/http/error.rs:57:44
   |
57 |             ApiError::Domain(err) => match err {
   |                                            ^^^ pattern `&CrmError::Archived(_)` not covered
```

The HTTP layer *cannot forget* to choose a status code for a new business error. Would a
`_ => (StatusCode::INTERNAL_SERVER_ERROR, "internal")` arm be "safer"? It compiles today, but
then every future domain error silently becomes a 500 that hides its message. Remove the variant
when you're done.

> 🟡 **EXPERIMENT 2: typos are silently ignored.** Send
> `{"name":"Acme","webiste":"https://acme.example"}` (note the typo). What comes back, and what
> is `website`? Now add `#[serde(deny_unknown_fields)]` above `CreateCompanyRequest` and try
> again:

```text
{"error":{"code":"bad_request","message":"Failed to deserialize the JSON body into the target type: webiste: unknown field `webiste`, expected `name` or `website` at line 1 column 24"}}
```

Stricter is friendlier to developers who make typos. It's also less friendly to clients that
send extra fields on purpose (an older or newer frontend). Neither choice is universally right.
Decide whether to keep it, and write a one-line comment explaining why.

> 🟡 **EXPERIMENT 3: what leaks without the rule?** In `into_response`, change
> `if status.is_server_error()` to `if false && status.is_server_error()` and repeat the 500 run:

```text
{"error":{"code":"internal","message":"could not write /no/such/dir/crm-data.json: No such file or directory (os error 2)"}}
```

A file-system path from your server, handed to anyone who sends a request. Swap in a database
error and it might include a hostname, a table name or a fragment of SQL. Restore the condition.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `NewContact` and validation that collects every error**
>
> 1. In `src/contacts/model.rs` add (and re-export from `contacts/mod.rs`):
>    ```rust
>    #[derive(Debug, Clone, PartialEq)]
>    pub struct NewContact {
>        pub name: String,
>        pub email: Email,
>        pub phone: Option<String>,
>        pub company_id: Option<CompanyId>,
>    }
>    ```
> 2. Change `Crm::add_contact` to `pub fn add_contact(&mut self, new: NewContact) -> Result<ContactId, CrmError>`
>    (same rules as before: company must exist → `NotFound`, email must be unique →
>    `DuplicateEmail`). Fix every call site the compiler shows you.
> 3. In `src/http/contacts.rs` define
>    ```rust
>    #[derive(Debug, Deserialize)]
>    pub struct CreateContactRequest {
>        #[serde(default)] pub name: String,
>        #[serde(default)] pub email: String,
>        pub phone: Option<String>,
>        pub company_id: Option<u64>,
>    }
>    ```
>    and `impl TryFrom<CreateContactRequest> for NewContact` with `type Error = Vec<FieldError>`.
>
> Rules (field name in **bold**):
> - **name**: trimmed, must not be empty.
> - **email**: must pass `Email::try_from` (your Lab 15 rules); the message is the
>   `ValidationError`'s `Display`.
> - **phone**: missing or blank → `None`. Otherwise it may contain only digits, spaces and
>   `+ - ( ) .`, and must contain at least 7 digits. Keep it trimmed.
> - `company_id` is passed through (`CompanyId`); whether it exists is the domain's job.
>
> Acceptance criteria:
> - [ ] All errors are reported together, in the order name, email, phone
> - [ ] At least three unit tests in `src/http/contacts.rs`: a valid request (email comes out
>       lowercased), a blank phone becoming `None`, and one request with all three fields
>       invalid producing exactly `["name", "email", "phone"]`
> - [ ] `cargo test` passes

> 🔵 **YOUR TURN 2: full CRUD for contacts**
>
> Add `POST /contacts`, `PUT /contacts/{id}` and `DELETE /contacts/{id}` (and convert
> `GET /contacts/{id}` to `ApiError`), following the company handlers' shape:
> - `POST` → **201** with the `ContactResponse`.
> - `PUT` replaces name, email, phone and company. Its body has exactly the create shape (name
>   the type `UpdateContactRequest`; how you define it is up to you). Add
>   `Crm::update_contact(&mut self, id: ContactId, update: NewContact) -> Result<&Contact, CrmError>`:
>   `NotFound` for an unknown contact or company, `DuplicateEmail` if **another** contact has the
>   email (keeping your own email is fine).
> - `DELETE` → **204** (use your existing `remove_contact`).
>
> With a fresh data file and one company created (`{"name":"Acme Corp"}` → id 1), these must
> hold:

```text
POST /contacts {"name":"Ada Lovelace","email":"ADA@Acme.example","phone":"+1 555 0100","company_id":1}
→ 201 {"id":1,"name":"Ada Lovelace","email":"ada@acme.example","phone":"+1 555 0100","company_id":1}

POST /contacts {"name":"","email":"not-an-email","phone":"call me"}
→ 422 {"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"name","message":"must not be empty"},{"field":"email","message":"invalid email address: not-an-email"},{"field":"phone","message":"must contain at least 7 digits and only digits, spaces and + - ( ) ."}]}}

POST /contacts {"name":"Ada Again","email":"ada@acme.example"}
→ 409 {"error":{"code":"conflict","message":"a contact with email ada@acme.example already exists"}}

POST /contacts {"name":"Bob","email":"bob@acme.example","company_id":42}
→ 404 {"error":{"code":"not_found","message":"company #42 not found"}}

DELETE /companies/1
→ 409 {"error":{"code":"conflict","message":"company #1 still has contacts"}}

PUT /contacts/1 {"name":"Ada King","email":"ada@acme.example","phone":null,"company_id":1}
→ 200 {"id":1,"name":"Ada King","email":"ada@acme.example","phone":null,"company_id":1}

GET /contacts/7
→ 404 {"error":{"code":"not_found","message":"contact #7 not found"}}
```

> - [ ] Plus: after creating `bob@acme.example` as contact 2, `PUT /contacts/2` with Ada's
>       email → **409**; `DELETE /contacts/2` → **204**; a second `DELETE` → **404**
> - [ ] (Message wording follows your `CrmError`/`ValidationError` `Display`; statuses and codes must match.)

> 🔵 **YOUR TURN 3: a JSON 400 for bad path parameters**
>
> `GET /companies/abc` still answers in plain text. Write `AppPath<T>`, the `Path` equivalent
> of `AppJson<T>`, in `src/http/extract.rs`, and use it in **every** handler that takes an id.
> - [ ] `curl -i localhost:3000/contacts/abc` →
>       `400` `{"error":{"code":"bad_request","message":"Invalid URL: Cannot parse `abc` to a `u64`"}}`
> - [ ] No handler in `src/http/` uses `axum::extract::Path` directly any more
> - [ ] `cargo clippy` is clean

## 💡 Hint

> 💡 **HINT**: Your Turn 1 is the company `TryFrom` with three fields instead of two. A tuple of
> three `Result`s matches the same way.

<details><summary>Hint 2 (Your Turn 2, the duplicate check on update)</summary>

`email_exists` can't tell "someone else has this email" from "*I* already have this email".
Check "any contact whose id is **not** `id` has this email" with
`self.contacts.iter().any(|c| ...)`. Do all checks **before** taking `get_mut`: once you hold a
`&mut Contact` from `self.contacts`, you can't also iterate `self.contacts` (E0502, Lab 07).

</details>

<details><summary>Hint 3 (Your Turn 3)</summary>

`Path` doesn't read the body, so it's a `FromRequestParts` extractor, not `FromRequest`. The
derive has the same name pattern: `#[derive(FromRequestParts)]` with the same
`#[from_request(via(...), rejection(...))]` attribute. The rejection type you need a `From` impl
for lives next to `JsonRejection`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. What exactly does axum do with the value your handler returns? Why does
   `Result<Json<T>, ApiError>` compile only after `impl IntoResponse for ApiError`?
2. Write out what `let x = f()?;` expands to. Where does `From` come in?
3. Why can you write `impl IntoResponse for ApiError` but not `impl IntoResponse for serde_json::Error`?
4. Your handler never ran, yet the client got a 400. Where did that response come from?
5. Why does `TryFrom<CreateCompanyRequest> for NewCompany` not use `?` on each field?
6. Why is the 5xx rule keyed on `status.is_server_error()` instead of on `ApiError::Internal`?
7. Why is there no `_ =>` arm in `status_and_code`?

Then verify: `cargo fmt --check && cargo clippy --all-targets && cargo test`

## Git Commit
Commit the error machinery once the companies part works, then the rest:

```bash
git add .
git commit -m "Add ApiError with JSON error responses"
```

After the Your Turn tasks:

```bash
git add .
git commit -m "Add API error handling and validation"
git tag lab-28
git push && git push --tags
```

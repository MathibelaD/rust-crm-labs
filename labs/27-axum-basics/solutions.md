# Lab 27 — Solutions

> 🔴 One good answer per task, with the reasoning. Field names in the DTOs are part of the API
> contract, so if you chose different ones, that's a design decision, not a mistake. Just keep them
> consistent, because Labs 28–29 build on these endpoints.

---

## Your Turn 1 & 2 — `src/http/contacts.rs`

```rust
//! `/contacts` endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use serde::Serialize;

use super::AppState;
use crate::contacts::{Contact, ContactId};

#[derive(Debug, Serialize)]
pub struct ContactResponse {
    pub id: u64,
    pub name: String,
    pub email: String,
    pub phone: Option<String>,
    pub company_id: Option<u64>,
}

impl From<&Contact> for ContactResponse {
    fn from(c: &Contact) -> Self {
        Self {
            id: c.id.0,
            name: c.name.clone(),
            email: c.email.as_str().to_string(),
            phone: c.phone.clone(),
            company_id: c.company_id.map(|id| id.0),
        }
    }
}

/// `GET /contacts`
pub async fn list_contacts(State(state): State<AppState>) -> Json<Vec<ContactResponse>> {
    let crm = state.crm.read().expect("CRM lock poisoned");
    Json(crm.contacts.iter().map(ContactResponse::from).collect())
}

/// `GET /contacts/{id}`
pub async fn get_contact(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<Json<ContactResponse>, StatusCode> {
    let crm = state.crm.read().expect("CRM lock poisoned");
    crm.contacts
        .get(ContactId(id))
        .map(|c| Json(ContactResponse::from(c)))
        .ok_or(StatusCode::NOT_FOUND)
}
```

In `src/http/mod.rs`:

```rust
pub mod companies;
pub mod contacts;
mod health;
mod state;
```

```rust
        .route("/contacts", get(contacts::list_contacts))
        .route("/contacts/{id}", get(contacts::get_contact))
```

### Reasoning

- **`email: String`, not `Email`.** `Email` serializes as a string already (Lab 21's
  `#[serde(into = "String")]`), so `email: Email` would produce the same JSON. Using `String` in
  the DTO makes the contract explicit: the response type says "a string", and changing how `Email`
  is serialized internally can't silently change the API. The cost is one clone per contact, which
  we pay anyway because the response must own its data.
- **`company_id: Option<u64>`.** `Option` maps to `null`/a value in JSON. `.map(|id| id.0)` gets
  inside the `Option` without `match`, which is Lab 12's combinator lesson.
- **Holding a read guard in a handler with no `.await`** is fine. The guard is a local that's
  dropped when the function returns, and nothing suspends in between. Clippy and the `Handler`
  bound both accept it. Compare `create_company`, which needed the block because of its `.await`.
- **Why not reuse `list_contacts(&ContactFilter)` from Lab 17?** You can, and Lab 29 will (query
  parameters → `ContactFilter`). Here "all contacts in id order" is what `repo.iter()` gives.

---

## Your Turn 3 — `DELETE /companies/{id}`

```rust
use crate::errors::CrmError;
```

```rust
/// `DELETE /companies/{id}`
pub async fn delete_company(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<StatusCode, StatusCode> {
    {
        let mut crm = state.crm.write().expect("CRM lock poisoned");
        crm.remove_company(CompanyId(id)).map_err(|e| match e {
            CrmError::NotFound { .. } => StatusCode::NOT_FOUND,
            CrmError::HasContacts(_) => StatusCode::CONFLICT,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        })?;
    } // write guard dropped

    state.persist().await.map_err(|e| {
        eprintln!("Error: {:#}", anyhow::Error::from(e));
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    Ok(StatusCode::NO_CONTENT)
}
```

```rust
        .route(
            "/companies/{id}",
            get(companies::get_company).delete(companies::delete_company),
        )
```

### Reasoning

- **`204 No Content`**: the deletion succeeded and there's nothing to return. Some APIs return the
  deleted object with `200`. Either is defensible. Pick one and use it consistently (Lab 28 does).
- **`409 Conflict` for `HasContacts`**: the request is well-formed and the company exists, but it
  conflicts with the current state of the data. That's the textbook meaning. (`400` would wrongly
  say the request itself is malformed.)
- **The `match` lists the variants `remove_company` can actually return**, and the `_` arm is a
  deliberate "this would be a bug" fallback to 500. If you later add a variant to `CrmError`,
  nothing here forces a decision, and that's the weakness Lab 28's central
  `impl From<CrmError> for ApiError` fixes: one exhaustive `match` for the whole API.
- **The returned `Company` is dropped at the end of the block.** `remove_company` hands back the
  owned company (Lab 08's "return what you removed"). We don't need it, so it's dropped together
  with the guard.
- **What if two clients `DELETE` the same company at once?** The write lock serializes them: one
  gets `204`, the other sees `NotFound` and gets `404`. The lock makes the check and the removal
  one atomic step.

---

## Experiment answers

**Experiment 1 (no `Clone`).** Covered in the README. The surprising part is E0521: without
`#[derive(Clone)]`, `self.clone()` resolves to `<&AppState as Clone>::clone`, which copies the
reference. Method resolution tries `AppState: Clone` first, fails, then tries auto-ref and finds
`&AppState: Clone`. That's legal and almost never what you meant, and a confusing lifetime
error like this one is usually how you find out.

**Experiment 2 (lost update).** In the reference run: the REPL loaded the 2 companies from the
file and added Umbrella as `#3`. The server, which had loaded the file before Umbrella existed,
created Hooli and **also** gave it `#3`, then wrote its snapshot, so Umbrella vanished. Both
`next_id` counters were right for their own process. The bug lives *between* processes, where
Rust's guarantees stop. A database fixes it by being the single owner of the data that every
process talks to, using transactions and constraints (`UNIQUE`, `GENERATED ALWAYS AS IDENTITY`)
instead of in-memory counters.

**Experiment 3 (`/:id`).** A runtime panic when the router is built, not a compile error. Route
paths are plain strings to the compiler. Axum 0.8 added this check because silently treating
`:id` as a literal segment would make every request 404, which is much harder to debug.

**Experiment 4 (extractor order).** Without `debug_handler` you get the usual unhelpful
`Handler<_, _> is not satisfied`. With it:

```text
error: `Json<_>` consumes the request body and thus must be the last argument to the handler function
  --> src/http/companies.rs:60:20
   |
60 |     Json(request): Json<CreateCompanyRequest>,
   |                    ^^^^
```

The traits explain why: only the **last** argument may implement `FromRequest` (which receives the
`Request` by value, body included). All the others must implement `FromRequestParts` (which only
borrows the parts). The body is a stream that can be consumed once. Axum encodes "once" in the
type signatures, and the compiler enforces it.

---

## Checkpoint notes

- **Q4 (`std` vs `tokio` `RwLock`):** switch to `tokio::sync::RwLock` only if a handler genuinely
  needs to hold the lock across an `.await`, e.g. if `Storage::save` became `async` and you
  insisted on saving under the write lock. Even then, prefer restructuring (snapshot under the
  lock, save outside) before reaching for the async lock.
- **Q5 (runtime behaviour):** a deadlock. `persist()` takes a read lock on the blocking pool and
  waits for the handler's write lock to be released. The handler waits for `persist()` to finish.
  With `tokio::sync::RwLock` it would compile and then hang that request forever, while every other
  request that touches the CRM queues up behind it.

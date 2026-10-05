# Lab 28 — Solutions

> 🔴 Read this only after a genuine attempt. Your code may differ and still be right: compare
> the *reasoning*, then the code.

---

## Your Turn 1 — `NewContact` and validation that collects every error

### The domain type and the `Crm` signature

`src/contacts/model.rs`:

```rust
/// A contact that passed validation but has no id yet.
#[derive(Debug, Clone, PartialEq)]
pub struct NewContact {
    pub name: String,
    pub email: Email,
    pub phone: Option<String>,
    pub company_id: Option<CompanyId>,
}
```

`src/contacts/mod.rs`: `pub use model::{Contact, ContactId, NewContact};`

`src/crm.rs`:

```rust
/// Adds a contact. The email must be unused and the company (if any) must exist.
pub fn add_contact(&mut self, new: NewContact) -> Result<ContactId, CrmError> {
    if let Some(company_id) = new.company_id {
        self.company(company_id)?;
    }
    if self.contacts.email_exists(&new.email) {
        return Err(CrmError::DuplicateEmail(new.email.as_str().to_string()));
    }
    let NewContact {
        name,
        email,
        phone,
        company_id,
    } = new;
    let contact = Contact::new(self.contacts.next_id(), name, email, phone, company_id);
    contact.validate()?;
    Ok(self.contacts.insert(contact))
}
```

Only the signature and the field accesses changed. The body is your Lab 14/15 version.

**Why destructure with `let NewContact { .. } = new;`?** It moves each field out of `new` into
its own variable in one statement, ready to hand to `Contact::new`. If someone later adds a field to `NewContact`, the destructuring pattern stops
compiling (it has no `..`), which reminds you to carry the new field into `Contact`.

**Why keep `contact.validate()?`** The HTTP boundary now checks name, email and phone first, but
the CLI and the tests build `NewContact` directly. The domain still guards its own invariants
(Lab 15), so a blank name can't sneak in through a path that skips `TryFrom`.

Call sites the compiler showed you: the CLI's `contact add` (inside its `write_crm` closure:
`crm.add_contact(NewContact { name, email, phone, company_id })`), the unit tests in `crm.rs`,
`history.rs`, `stats.rs`, `contacts/queries.rs` and the round-trip test in
`src/storage/json_file.rs`, `sample_crm` in `tests/common/mod.rs`, and
`duplicate_contact_email_is_rejected` / `contact_for_a_missing_company_is_rejected` in
`tests/validation.rs`. Each needs `NewContact` imported. Writing the struct literal at every call
site works fine; if you prefer, a tiny helper keeps `sample_crm` readable:

```rust
fn contact(name: &str, email: &str, company: CompanyId) -> NewContact {
    NewContact {
        name: name.into(),
        email: Email::parse(email).unwrap(),
        phone: None,
        company_id: Some(company),
    }
}
```

### The validation

`src/http/contacts.rs`:

```rust
#[derive(Debug, Deserialize)]
pub struct CreateContactRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub email: String,
    pub phone: Option<String>,
    pub company_id: Option<u64>,
}

fn validate_name(raw: &str) -> Result<String, FieldError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(FieldError::new("name", "must not be empty"));
    }
    Ok(name.to_string())
}

fn validate_email(raw: &str) -> Result<Email, FieldError> {
    Email::try_from(raw).map_err(|e| FieldError::new("email", e.to_string()))
}

fn validate_phone(raw: Option<String>) -> Result<Option<String>, FieldError> {
    let Some(phone) = raw else { return Ok(None) };
    parse_phone(&phone).map_err(|e| FieldError::new("phone", e.to_string()))
}

impl TryFrom<CreateContactRequest> for NewContact {
    type Error = Vec<FieldError>;

    fn try_from(req: CreateContactRequest) -> Result<Self, Self::Error> {
        let name = validate_name(&req.name);
        let email = validate_email(&req.email);
        let phone = validate_phone(req.phone);

        match (name, email, phone) {
            (Ok(name), Ok(email), Ok(phone)) => Ok(NewContact {
                name,
                email,
                phone,
                company_id: req.company_id.map(CompanyId),
            }),
            (name, email, phone) => Err([name.err(), email.err(), phone.err()]
                .into_iter()
                .flatten()
                .collect()),
        }
    }
}
```

Reasoning worth checking against yours:

- **`validate_email` reuses `Email::try_from`, and `validate_phone` reuses `parse_phone`.** Don't
  write a second email or phone check for HTTP. The domain *is* the rule. The boundary only
  translates its `ValidationError` into a `FieldError` with a field name attached. (A separate
  HTTP phone rule that, say, also allowed dots would accept `555.0100`, and then
  `contact.validate()` would reject it with a 422 that has no `fields`: two rules drift apart.)
- **`req.company_id.map(CompanyId)`**: a tuple-struct name is also a function
  (`fn(u64) -> CompanyId`), so it can be passed to `map` directly.
- **Partial moves.** `validate_phone(req.phone)` moves `phone` out of `req`, but then the match
  arm still uses `req.company_id`. That compiles because Rust tracks moves *per field*: `req` is
  partially moved, and its other fields are still usable. (Try using `req` as a whole after
  that line, e.g. `dbg!(&req)`, and you'll get E0382.)
- **The imports**: `use crate::contacts::{Contact, ContactId, Email, NewContact, parse_phone};`
  and `use crate::companies::CompanyId;`.

Tests (bottom of `src/http/contacts.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn request(name: &str, email: &str, phone: Option<&str>) -> CreateContactRequest {
        CreateContactRequest {
            name: name.to_string(),
            email: email.to_string(),
            phone: phone.map(str::to_string),
            company_id: None,
        }
    }

    #[test]
    fn valid_request_becomes_new_contact() {
        let new =
            NewContact::try_from(request(" Ada ", "ADA@Example.com", Some("+1 555 0100"))).unwrap();
        assert_eq!(new.name, "Ada");
        assert_eq!(new.email.as_str(), "ada@example.com");
        assert_eq!(new.phone.as_deref(), Some("+1 555 0100"));
    }

    #[test]
    fn blank_phone_becomes_none() {
        let new = NewContact::try_from(request("Ada", "ada@example.com", Some("  "))).unwrap();
        assert_eq!(new.phone, None);
    }

    #[test]
    fn collects_all_field_errors() {
        let errors = NewContact::try_from(request("", "nope", Some("call me"))).unwrap_err();
        let fields: Vec<&str> = errors.iter().map(|e| e.field).collect();
        assert_eq!(fields, ["name", "email", "phone"]);
    }
}
```

`assert_eq!(fields, ["name", "email", "phone"])` compares a `Vec<&str>` with an array. That works
because the standard library implements `PartialEq<[U; N]> for Vec<T>`.

---

## Your Turn 2 — Full CRUD for contacts

### `Crm::replace_contact`

```rust
/// Replaces every field of a contact (HTTP `PUT`). The company (if any) must
/// exist, and no *other* contact may already have the email.
pub fn replace_contact(
    &mut self,
    id: ContactId,
    update: NewContact,
) -> Result<&Contact, CrmError> {
    self.contact(id)?;
    if let Some(company_id) = update.company_id {
        self.company(company_id)?;
    }
    let taken = self
        .contacts
        .iter()
        .any(|c| c.id != id && c.email == update.email);
    if taken {
        return Err(CrmError::DuplicateEmail(update.email.as_str().to_string()));
    }
    let NewContact {
        name,
        email,
        phone,
        company_id,
    } = update;
    let replacement = Contact::new(id, name, email, phone, company_id);
    replacement.validate()?;
    let contact = self.contacts.get_mut(id).expect("existence checked above");
    *contact = replacement;
    Ok(contact)
}
```

**Why a new method instead of changing `update_contact`?** Lab 14's `update_contact(id, name,
email, phone)` takes `Option`s, where `None` means "keep": the CLI's `contact update` relies on
that (and so do its Lab 14 tests). `PUT` means "here is the complete new contact", which is a
different operation, so it gets its own name. Same domain rules, different shape.

**Why build a `Contact` and `validate()` it before touching the stored one?** Same pattern as
Lab 14's `update_contact`: if validation fails, the stored contact is untouched.

**Why check existence first and call `get_mut` last?** The duplicate check iterates
`self.contacts` with a shared borrow. If we took `let contact = self.contacts.get_mut(id)` at the
top, that `&mut` would be alive during the iteration, which is E0502 (shared borrow while a
mutable one exists). Doing all the reading first and the single mutable borrow at the end keeps
the borrows sequential. The `expect` documents an invariant we just checked. It can't fire,
because nothing between the check and `get_mut` removes contacts.

**`c.id != id && c.email == update.email`**: "someone *else* has it". Re-saving a contact with
its own unchanged email must succeed.

### DTO for PUT

```rust
/// PUT replaces the whole contact, so the body has exactly the create shape.
pub type UpdateContactRequest = CreateContactRequest;
```

A type alias gives the name the lab asked for and documents intent, without duplicating the
struct *or its validation*: `NewContact::try_from(req)` works for both. If create and update ever
diverge (say, email becomes immutable), turn the alias into its own struct. The compiler will then
show you every place that relied on them being the same.

A separate struct with identical fields would also be correct. You'd need either a second
`TryFrom` impl or a `From<UpdateContactRequest> for CreateContactRequest` to reuse the first one.

### Handlers

```rust
pub async fn create_contact(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateContactRequest>,
) -> Result<(StatusCode, Json<ContactResponse>), ApiError> {
    let new = NewContact::try_from(req)?;
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let id = crm.add_contact(new)?;
        ContactResponse::from(crm.contacts.get(id).expect("contact was just inserted"))
    };
    state.persist().await?;
    Ok((StatusCode::CREATED, Json(response)))
}

pub async fn get_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<ContactResponse>, ApiError> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let contact = crm.contacts.get(ContactId(id)).ok_or(CrmError::NotFound {
        entity: "contact",
        id,
    })?;
    Ok(Json(ContactResponse::from(contact)))
}

pub async fn update_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
    AppJson(req): AppJson<UpdateContactRequest>,
) -> Result<Json<ContactResponse>, ApiError> {
    let update = NewContact::try_from(req)?;
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        ContactResponse::from(crm.replace_contact(ContactId(id), update)?)
    };
    state.persist().await?;
    Ok(Json(response))
}

pub async fn delete_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<StatusCode, ApiError> {
    state
        .crm
        .write()
        .expect("crm lock poisoned")
        .remove_contact(ContactId(id))?;
    state.persist().await?;
    Ok(StatusCode::NO_CONTENT)
}
```

(`AppPath` is Your Turn 3. With plain `Path(id): Path<u64>` everything else is identical.)

Your Lab 14 `remove_contact` returns `Result<Contact, CrmError>` (`NotFound` for an unknown id),
so `?` is all it needs.

**Is `ContactResponse::from(crm.replace_contact(..)?)` borrow-safe?** `replace_contact` returns
`&Contact` borrowed from `crm` (really from the write guard). `ContactResponse::from` copies what
it needs into owned `String`s, then the borrow ends, and the guard is dropped at the end of the
block. Nothing borrowed escapes past the `.await`.

Routes in `src/http/mod.rs`:

```rust
.route(
    "/contacts",
    get(contacts::list_contacts).post(contacts::create_contact),
)
.route(
    "/contacts/{id}",
    get(contacts::get_contact)
        .put(contacts::update_contact)
        .delete(contacts::delete_contact),
)
```

---

## Your Turn 3 — `AppPath<T>`

`src/http/extract.rs`:

```rust
use axum::extract::{FromRequest, FromRequestParts};

/// Like `axum::extract::Path`, but a bad path parameter becomes our JSON 400.
#[derive(FromRequestParts)]
#[from_request(via(axum::extract::Path), rejection(ApiError))]
pub struct AppPath<T>(pub T);
```

`src/http/error.rs`:

```rust
use axum::extract::rejection::{JsonRejection, PathRejection};

impl From<PathRejection> for ApiError {
    fn from(rejection: PathRejection) -> Self {
        ApiError::BadRequest(rejection.body_text())
    }
}
```

Then replace `Path(id): Path<u64>` with `AppPath(id): AppPath<u64>` in every handler, and remove
`Path` from the `use axum::extract::{...}` lines (clippy and rustc will flag the unused import).

**Why `FromRequestParts` and not `FromRequest`?** An HTTP request body is a *stream* that can
only be read once. Axum encodes that in the types: extractors that only look at the method, URI
and headers implement `FromRequestParts` and can appear anywhere in the argument list. The one
extractor that consumes the body implements `FromRequest` and must be **last**. That's why
`AppJson(req)` is always the final handler argument. `Path` reads the URI, so `AppPath` is a parts
extractor too.

---

## Experiment answers

**Experiment 1.** Only `src/http/error.rs` fails (plus any other `match` on `CrmError` without a
wildcard, e.g. in your CLI). That's the payoff of keeping the status policy in one exhaustive
match: the compiler produces a to-do list containing exactly the places where a decision is
required.

**Experiment 2.** Without `deny_unknown_fields` the request returns **201** with
`"website": null`: serde ignores unknown keys by default, so the typo silently loses data. With
the attribute you get the 400 shown in the lab. A reasonable policy: deny unknown fields on
*request* DTOs (we control both sides during development), never on data we load from disk (an
older file shouldn't fail because a field was removed). Either way, write the reason down.

**Experiment 3.** The path leaked. The general rule: a client should get enough information
to fix *their* mistake (4xx) and nothing about *ours* (5xx). Keying the rule on the status
rather than the variant means a future "internal" path can't forget it.

## Checkpoint answers (short)

1. It calls `IntoResponse::into_response` on it. `Result<T, E>` implements `IntoResponse` only
   when both `T` and `E` do.
2. `match f() { Ok(v) => v, Err(e) => return Err(From::from(e)) }`. `From` converts the inner
   error type into the function's error type.
3. Orphan rule: for `impl Trait for Type`, the trait or the type must be local. `ApiError` is
   local; neither `IntoResponse` nor `serde_json::Error` is.
4. From the extractor's rejection. Extractors run before the handler, and a failing one
   short-circuits with its `Rejection` (converted to `ApiError` by `AppJson`).
5. `?` returns on the first error; we want every field's error in one response. Also
   `Vec<FieldError>: From<FieldError>` doesn't exist, which is the compiler noticing.
6. So that *any* error that ends up as a 5xx, including future variants (say, a database
   error you map to 500 in Lab 30), is redacted. The rule protects a property (no internals in
   5xx), not one variant.
7. So that adding a `CrmError` variant forces an explicit HTTP decision at compile time.

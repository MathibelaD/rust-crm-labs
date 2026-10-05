# Lab 30 — Solutions

> 🔴 These are *one* good answer to each task, with the reasoning. If yours differs but meets every
> acceptance criterion and you can explain your choices, it's a good answer too.

---

## Step 1 — "Why PostgreSQL?" (writing)

An example section for your repo's `README.md`:

```markdown
## Why PostgreSQL?

- The server and the CLI both rewrote `crm-data.json` from their own in-memory copy, so whoever
  saved last silently erased the other's changes (lost updates).
- Every change rewrote the whole file; a database writes one row.
- Filtering meant loading everything into memory; SQL + indexes query 100k rows directly.
- Rules like "emails are unique" and "a contact's company exists" are now enforced by the
  database for every writer, not only by our Rust code.
- Several writes can be made atomic with a transaction (needed for lead conversion).
```

The part people usually miss is the *new* cost: you now run and migrate a database, and
compiling needs either a live database or the `.sqlx/` cache.

---

## 🔵 Your Turn 1 — `src/contacts/db.rs`

```rust
//! Contact persistence.

use sqlx::PgPool;

use super::{Contact, ContactFilter, ContactId, ContactSort, Email, NewContact};
use crate::companies::CompanyId;
use crate::database::corrupt;
use crate::errors::CrmError;

struct ContactRow {
    id: i64,
    name: String,
    email: String,
    phone: Option<String>,
    company_id: Option<i64>,
}

impl TryFrom<ContactRow> for Contact {
    type Error = sqlx::Error;

    fn try_from(row: ContactRow) -> Result<Self, Self::Error> {
        Ok(Contact {
            id: ContactId(row.id),
            name: row.name,
            // Re-validate: the database only promises "some text".
            email: Email::try_from(row.email).map_err(corrupt)?,
            phone: row.phone,
            company_id: row.company_id.map(CompanyId),
        })
    }
}

fn not_found(id: ContactId) -> CrmError {
    CrmError::NotFound {
        entity: "contact",
        id: id.0,
    }
}

/// Turns constraint violations caused by `new` into domain errors.
fn write_error(e: sqlx::Error, new: &NewContact) -> CrmError {
    if let sqlx::Error::Database(db) = &e {
        if db.is_unique_violation() && db.constraint() == Some("contacts_email_key") {
            return CrmError::DuplicateEmail(new.email.to_string());
        }
        if db.is_foreign_key_violation()
            && let Some(company) = new.company_id
        {
            return CrmError::NotFound {
                entity: "company",
                id: company.0,
            };
        }
    }
    CrmError::Database(e)
}

pub async fn insert(pool: &PgPool, new: &NewContact) -> Result<Contact, CrmError> {
    let row = sqlx::query_as!(
        ContactRow,
        "INSERT INTO contacts (name, email, phone, company_id)
         VALUES ($1, $2, $3, $4)
         RETURNING id, name, email, phone, company_id",
        new.name,
        new.email.as_str(),
        new.phone,
        new.company_id.map(|c| c.0),
    )
    .fetch_one(pool)
    .await
    .map_err(|e| write_error(e, new))?;
    Ok(row.try_into()?)
}

pub async fn get(pool: &PgPool, id: ContactId) -> Result<Contact, CrmError> {
    let row = sqlx::query_as!(
        ContactRow,
        "SELECT id, name, email, phone, company_id FROM contacts WHERE id = $1",
        id.0,
    )
    .fetch_optional(pool)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

pub async fn list(
    pool: &PgPool,
    filter: &ContactFilter,
    limit: i64,
    offset: i64,
) -> Result<(Vec<Contact>, i64), CrmError> {
    let company = filter.company.map(|c| c.0);
    let search = filter.search.as_deref();
    let sort = match filter.sort {
        ContactSort::Id => "id",
        ContactSort::Name => "name",
        ContactSort::Email => "email",
    };

    let rows = sqlx::query_as!(
        ContactRow,
        "SELECT id, name, email, phone, company_id
         FROM contacts
         WHERE ($1::bigint IS NULL OR company_id = $1)
           AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%' OR email ILIKE '%' || $2 || '%')
         ORDER BY CASE WHEN $3 = 'name' THEN name END,
                  CASE WHEN $3 = 'email' THEN email END,
                  id
         LIMIT $4 OFFSET $5",
        company,
        search,
        sort,
        limit,
        offset,
    )
    .fetch_all(pool)
    .await?;

    let total = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "total!"
           FROM contacts
           WHERE ($1::bigint IS NULL OR company_id = $1)
             AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%' OR email ILIKE '%' || $2 || '%')"#,
        company,
        search,
    )
    .fetch_one(pool)
    .await?;

    let contacts = rows
        .into_iter()
        .map(Contact::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok((contacts, total))
}

pub async fn list_for_company(
    pool: &PgPool,
    company_id: CompanyId,
) -> Result<Vec<Contact>, CrmError> {
    let rows = sqlx::query_as!(
        ContactRow,
        "SELECT id, name, email, phone, company_id
         FROM contacts WHERE company_id = $1 ORDER BY name, id",
        company_id.0,
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(Contact::try_from)
        .collect::<Result<_, _>>()?)
}

pub async fn update(
    pool: &PgPool,
    id: ContactId,
    changes: &NewContact,
) -> Result<Contact, CrmError> {
    let row = sqlx::query_as!(
        ContactRow,
        "UPDATE contacts
         SET name = $2, email = $3, phone = $4, company_id = $5
         WHERE id = $1
         RETURNING id, name, email, phone, company_id",
        id.0,
        changes.name,
        changes.email.as_str(),
        changes.phone,
        changes.company_id.map(|c| c.0),
    )
    .fetch_optional(pool)
    .await
    .map_err(|e| write_error(e, changes))?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}

pub async fn delete(pool: &PgPool, id: ContactId) -> Result<(), CrmError> {
    let result = sqlx::query!("DELETE FROM contacts WHERE id = $1", id.0)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(not_found(id));
    }
    Ok(())
}
```

**Reasoning**

- **One `write_error` for `insert` and `update`.** Both statements can break the same two
  constraints, so the translation lives in one place. It takes the `sqlx::Error` **by value**
  (to wrap it in `CrmError::Database` when nothing matches) and only *borrows* inside the
  `if let` (`&e`). That's why `e` can still be moved at the end.
- **Checking the constraint name**, not just "some unique violation". Today there's one unique
  constraint on `contacts`. When a second one arrives, a check on the kind of violation alone would
  quietly report the wrong error.
- **The foreign-key branch needs `new.company_id`** to build `NotFound`, so the edition 2024
  `&& let Some(company) = ...` let-chain reads naturally. A FK violation with no company id can't
  happen. If it somehow did, it falls through to `Database`.
- **`new.email.as_str()`**: the macro wants something that encodes as `TEXT`. `&str` does,
  `Email` doesn't (it has no `sqlx::Type`, and that's deliberate: emails go *in* as text and come
  *out* through `Email::try_from`).
- **Sorting with `CASE`.** `ORDER BY $3` would sort by a constant string (every row equal),
  because a bind parameter is always a *value*, never an identifier. The two `CASE` expressions
  are NULL for every row unless their sort is selected, so they tie and `id` decides. It works,
  but you can see why Lab 32 switches to a query builder for this.
- **`update` returns `NotFound` via `fetch_optional` + `ok_or`.** `UPDATE ... RETURNING` with no
  matching row returns zero rows. No separate "does it exist?" query is needed, and no race.

---

## 🔵 Your Turn 2 — contacts handlers

`src/http/contacts.rs`. The request/response types and `TryFrom<CreateContactRequest> for
NewContact` stay from Lab 28.

```rust
async fn list_contacts(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<ContactQuery>,
    AppQuery(p): AppQuery<Pagination>,
) -> Result<Json<Page<ContactResponse>>, ApiError> {
    let p = p.normalized();
    let filter = ContactFilter {
        company: q.company_id.map(CompanyId),
        search: q.search,
        sort: q.sort,
    };
    let (contacts, total) =
        contacts::db::list(&state.pool, &filter, p.limit(), p.offset()).await?;
    let items = contacts.iter().map(ContactResponse::from).collect();
    Ok(Json(Page {
        items,
        page: p.page,
        per_page: p.per_page,
        total,
    }))
}

async fn create_contact(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateContactRequest>,
) -> Result<(StatusCode, Json<ContactResponse>), ApiError> {
    let new = NewContact::try_from(req).map_err(ApiError::Validation)?;
    let contact = contacts::db::insert(&state.pool, &new).await?;
    Ok((StatusCode::CREATED, Json(ContactResponse::from(&contact))))
}

async fn get_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<ContactResponse>, ApiError> {
    let contact = contacts::db::get(&state.pool, ContactId(id)).await?;
    Ok(Json(ContactResponse::from(&contact)))
}

async fn update_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<UpdateContactRequest>,
) -> Result<Json<ContactResponse>, ApiError> {
    let changes = NewContact::try_from(req).map_err(ApiError::Validation)?;
    let contact = contacts::db::update(&state.pool, ContactId(id), &changes).await?;
    Ok(Json(ContactResponse::from(&contact)))
}

async fn delete_contact(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<StatusCode, ApiError> {
    contacts::db::delete(&state.pool, ContactId(id)).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

If your `UpdateContactRequest` validates into something other than `NewContact`, convert into
whatever `Crm::update_contact` took in Lab 29. The repository signature from the task fixes the
input type as `&NewContact`.

And in `src/http/companies.rs`:

```rust
async fn company_contacts(
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<Vec<ContactResponse>>, ApiError> {
    let company = companies::db::get(&state.pool, CompanyId(id)).await?;
    let contacts = contacts::db::list_for_company(&state.pool, company.id).await?;
    Ok(Json(contacts.iter().map(ContactResponse::from).collect()))
}
```

**Reasoning**: `companies::db::get` first is what turns "unknown company" into a 404 instead of
an empty list. An empty list would be a lie: it says "this company has no contacts", not "there
is no such company". It costs one extra query. Lab 32 discusses when such round trips matter.

---

## 🔵 Your Turn 3 — `HasContacts` from the database

```rust
pub async fn delete(pool: &PgPool, id: CompanyId) -> Result<(), CrmError> {
    let result = sqlx::query!("DELETE FROM companies WHERE id = $1", id.0)
        .execute(pool)
        .await
        .map_err(|e| match e {
            // ON DELETE RESTRICT: contacts still point at this company.
            sqlx::Error::Database(db) if db.constraint() == Some("contacts_company_id_fkey") => {
                CrmError::HasContacts(id)
            }
            other => CrmError::Database(other),
        })?;
    if result.rows_affected() == 0 {
        return Err(not_found(id));
    }
    Ok(())
}
```

**Reasoning**: Experiment 2 showed SQLSTATE **23001** (`restrict_violation`), raised because the
foreign key says `ON DELETE RESTRICT`. SQLx's `is_foreign_key_violation()` only recognises
**23503**, the code you get for `NO ACTION` (the default) and for inserting a row that points
nowhere. Matching on the **constraint name** sidesteps that subtlety and is more precise anyway.
In Lab 31 `deals.company_id` gets its own foreign key, and you'll want a *different* error for it.

The pattern `sqlx::Error::Database(db) if ... =>` moves the boxed error into `db` only when
the guard is true. Otherwise matching continues and `other` gets the whole value.

---

## 🧪 Experiment answers

**Lost update (Step 1).** The server and the CLI each hold a full copy of the CRM. The one that
saves last writes *its* copy, so the other's company vanishes from the file. After a restart the
server shows whatever the last writer saved.

**Experiment 1 (the seam).** It's acceptable because it lasts one lab, the data is disposable
development data, and every request still gets a correct, *explicit* error (404), not corrupted
data. In production with real customers, the two stores disagreeing would be a data-integrity
incident. You'd backfill first or keep both sides in sync until the cut-over.

**Experiment 2.** `23001 restrict_violation`. See Your Turn 3.

**Experiment 3.** `down` keeps the named volume, so the data survives. `down -v` deletes the
volume, so Postgres starts empty. `database::migrate(&pool)` in `main.rs` recreates the tables on
startup, because `_sqlx_migrations` is empty too and every migration counts as "not applied yet".

**Step 12 (which tests need the DB).** Any test whose request passes validation and reaches a
repository function. A pure validation-failure test returns 422 before the pool is used, and a
lazy pool never connects if nobody asks it for a connection.

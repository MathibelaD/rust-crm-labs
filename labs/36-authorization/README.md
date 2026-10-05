# Lab 36 — Authorization

> **Phase:** 10 — Users, Authentication & Authorization · **Builds on:** Lab 35 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-35` · **After:** tag `lab-36`

## 🎯 Goal
Decide **what each user may do**. Sales reps see and edit only their own deals, managers see
everything and reassign deals, admins also manage users. Every rule is written once, as a
**pure function**, enforced in the right place (SQL for lists, Rust for single records), and
**covered by a test**.

## 🧠 What You'll Learn
- Authorization as **data + a pure function**: `can(user, action, owner) -> bool`
- Exhaustive `match` on `(Role, Action)` as a **policy review tool**: adding an action forces a decision for every role (E0004)
- **Table-driven tests**: one test, every row of the rules table
- **Where** to enforce: in SQL `WHERE` for **lists** (so pagination and counts stay correct)
  and in Rust for **single records** (so you can choose the status code)
- **403 vs 404**: when "forbidden" itself leaks information, and the rule *"if you can't see it, it doesn't exist"*
- Nullable SQL parameters: `WHERE ($1::BIGINT IS NULL OR owner_id = $1)`
- Finding the **side doors**: every endpoint that returns deal data must apply the same rule
- Writing an **API test for every rule**

## 🔨 What We're Building

The rules (this table *is* the specification, and your tests will check every line):

| Action | Admin | Manager | Sales rep |
|---|---|---|---|
| `ViewDeal` (one deal) | ✅ | ✅ | ✅ own only, others are **404** |
| `EditDeal` (move stage, …) | ✅ | ✅ | ✅ own only, others are **404** |
| `ReassignDeal` | ✅ | ✅ | ❌ **403** on own deals, **404** on others |
| `ViewAllDeals` (lists) | ✅ | ✅ | ❌ lists contain only their own deals |
| `DeleteCompany` | ✅ | ✅ | ❌ **403** |
| `ManageUsers` | ✅ | ❌ **403** | ❌ **403** |

New endpoints:

```text
PUT /deals/{id}/owner          { "owner_id": 3 }          manager, admin
GET /admin/users                                           admin
PUT /admin/users/{id}/role     { "role": "manager" }      admin (not on yourself)
```

New and changed files:

```text
src/auth/policy.rs       Action, can(), authorize()           ← pure, unit-tested
src/http/error.rs        ApiError::Forbidden (403)
src/errors.rs            CrmError::OwnRoleChange (409)
src/deals/db.rs          DealFilter { owner }, list(db, &filter), set_owner()
src/users/db.rs          list(), set_role()
src/http/deals.rs        load_deal_for(); every handler checks; PUT /deals/{id}/owner
src/http/companies.rs    DELETE checks DeleteCompany
src/http/admin.rs        /admin/users endpoints
tests/api/authz.rs       one test per rule
```

---

## Step 1 — The mental model

Every authorization question has three parts:

```text
WHO is asking?         AuthUser { id, role }                    ← Lab 35 gives us this
WHAT do they want?     Action::EditDeal                         ← an enum, this lab
ON WHICH record?       the deal's owner_id (or nothing)         ← from the database
                       ─────────────────────────────────────
                       can(who, what, owner) -> bool
```

Three design principles drive this lab:

1. **The policy is a pure function.** No database, no HTTP, no clock. It takes plain values
   and returns `bool`. That makes it trivial to test exhaustively (Step 3) and easy to read: the
   whole policy of the CRM fits on one screen. JS/TS backends often scatter `if (user.role === 'admin')`
   through handlers. Pulling it into one function is the difference between *having* a policy and
   *hoping* you have one.
2. **Deny by default.** Anything the policy doesn't explicitly allow is refused. A sales rep
   asking about a deal with *no* owner gets `false`, not "well, nobody owns it".
3. **Check at the boundary, once per request.** Handlers load what they need, ask `can`, then
   act. Repositories stay ignorant of users and roles, except where the *query itself* must
   change (lists, Step 5).

---

## Step 2 — `Action` and `can`

> 🟢 **FOLLOW ALONG**: `src/auth/policy.rs`

```rust
use super::AuthUser;
use crate::http::ApiError;
use crate::users::{Role, UserId};

/// Everything the CRM checks permission for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    ViewDeal,
    EditDeal,
    ReassignDeal,
    DeleteCompany,
    ManageUsers,
    ViewAllDeals,
}

/// The whole authorization policy. Pure: no database, no HTTP, no clock.
/// `owner` is the owner of the record the action targets, if there is one.
pub fn can(user: &AuthUser, action: Action, owner: Option<UserId>) -> bool {
    use Action::*;
    match (user.role, action) {
        (Role::Admin, _) => true,

        (Role::Manager, ViewDeal | EditDeal | ReassignDeal | ViewAllDeals | DeleteCompany) => true,
        (Role::Manager, ManageUsers) => false,

        (Role::SalesRep, ViewDeal | EditDeal) => owner == Some(user.id),
        (Role::SalesRep, ReassignDeal | ViewAllDeals | DeleteCompany | ManageUsers) => false,
    }
}
```

> 🟢 **FOLLOW ALONG**: `src/auth/mod.rs`: add `pub mod policy;`

Things to notice:

- **Matching on a tuple** `(user.role, action)` turns the rules table into code almost line for
  line. Both are `Copy`, so building the tuple copies two small values. Nothing is moved out of `user`.
- **`owner == Some(user.id)`**: `Option<UserId>` implements `PartialEq` because `UserId` does.
  This one comparison is "own only" *and* deny-by-default: `None == Some(me)` is `false`.
- **Only one wildcard, and only for Admin.** Every other role lists every action
  explicitly, *including the `false` ones*. That looks redundant. It isn't. Watch:

> 🟡 **EXPERIMENT**: predict first. Add a variant `ExportDeals,` to `Action` and `cargo check`.

```text
error[E0004]: non-exhaustive patterns: `(Role::Manager, Action::ExportDeals)` and `(Role::SalesRep, Action::ExportDeals)` not covered
  --> src/auth/policy.rs:21:11
   |
21 |     match (user.role, action) {
   |           ^^^^^^^^^^^^^^^^^^^ patterns `(Role::Manager, Action::ExportDeals)` and `(Role::SalesRep, Action::ExportDeals)` not covered
   |
   = note: the matched value is of type `(Role, Action)`
help: ensure that all possible cases are being handled by adding a match arm with a wildcard pattern, a match arm with multiple or-patterns as shown, or multiple match arms
```

The compiler just ran a **policy review**: "you added a capability, and you haven't decided
whether managers and reps get it." Admins are covered by their wildcard, which is the one
place a wildcard is a *decision* ("admins can do everything, including future actions"), not
laziness. If you'd written `_ => false` at the end, the new action would silently be
denied to everyone but admins. Maybe right, maybe a bug, and nobody would have been asked.
This is Lab 11's exhaustiveness check doing security work. Remove `ExportDeals`.

### `authorize`: the `?`-friendly version

Most call sites want "allowed, or stop with a 403". Add the response first:

> 🟢 **FOLLOW ALONG**: `src/http/error.rs`

```rust
pub enum ApiError {
    // ... Domain, Validation, BadRequest, Unauthorized, Internal ...
    /// Authenticated, but the policy says no (403).
    Forbidden,
}
```

`cargo check` points at the two `match`es in `IntoResponse` again. In `status_and_code`:

```rust
            ApiError::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
```

and in `into_response`:

```rust
            ApiError::Forbidden => ("you are not allowed to do this".to_string(), Vec::new()),
```

A fixed message on purpose: it doesn't say *which* rule refused you. Rules are for your
logs (Lab 37), not for probing clients.

> 🟢 **FOLLOW ALONG**: bottom of `src/auth/policy.rs`

```rust
/// `can`, as a `Result` you can `?`. Fails with 403 Forbidden.
pub fn authorize(user: &AuthUser, action: Action, owner: Option<UserId>) -> Result<(), ApiError> {
    if can(user, action, owner) {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}
```

**401 vs 403, once more:** 401 = "I don't know who you are" (no or invalid token, and logging in
might help). 403 = "I know exactly who you are, and the answer is no" (logging in again won't help).

---

## Step 3 — Table-driven tests for `can`

`can` is a function of three small inputs. You could write one `#[test]` per combination: 6
actions × 3 roles × a few ownership cases = dozens of near-identical functions. Instead, put the
rules in a **table** and loop over it:

> 🟢 **FOLLOW ALONG**: the *shape* of the test. You'll fill in the table in Your Turn 1.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use Action::*;

    const ME: UserId = UserId(1);
    const OTHER: UserId = UserId(2);

    #[derive(Debug, Clone, Copy)]
    enum Target {
        Mine,
        Theirs,
        Nobody,
    }

    fn owner(target: Target) -> Option<UserId> {
        match target {
            Target::Mine => Some(ME),
            Target::Theirs => Some(OTHER),
            Target::Nobody => None,
        }
    }

    #[test]
    fn policy_table() {
        use Role::*;
        use Target::*;
        #[rustfmt::skip]
        let table = [
            // role      action         target  allowed
            (Admin,    ViewDeal,      Theirs, true),
            (SalesRep, ViewDeal,      Theirs, false),
            // ... Your Turn 1: every remaining row ...
        ];

        for (role, action, target, expected) in table {
            let user = AuthUser { id: ME, role };
            assert_eq!(
                can(&user, action, owner(target)),
                expected,
                "{role:?} {action:?} on {target:?}"
            );
        }
    }
}
```

- **`const ME: UserId = UserId(1);`**: a tuple-struct constructor is allowed in a `const`
  because it's just building a value. No function call happens at runtime.
- **`Target` instead of raw `Option<UserId>`** makes each row read like the spec: "rep, view, *theirs*, false".
- **`#[rustfmt::skip]`** keeps the columns aligned. `cargo fmt` would otherwise reflow the table.
- **The assertion message** names the failing row. Without it, a failure inside a loop just says
  `left: true, right: false`, and you'd have to work out which of 23 rows that was.
- `for (role, action, target, expected) in table` **destructures** each tuple (Lab 11
  patterns) and consumes the array by value (`into_iter`, Lab 17). Everything in it is `Copy`.

Add a test for `authorize` too:

> 🟢 **FOLLOW ALONG**

```rust
    #[test]
    fn authorize_maps_false_to_forbidden() {
        let rep = AuthUser { id: ME, role: Role::SalesRep };
        assert!(matches!(authorize(&rep, ManageUsers, None), Err(ApiError::Forbidden)));
        assert!(authorize(&rep, ViewDeal, Some(ME)).is_ok());
    }
```

```bash
cargo test --lib policy
```

This is a good moment for the first commit:

```bash
git add .
git commit -m "Add role-based policies"
```

---

## Step 4 — Lists: enforce in SQL

What's wrong with this?

```rust
// ❌ tempting, and wrong
let deals = deals::db::list(&state.pool).await?;
let visible: Vec<_> = deals.into_iter().filter(|d| policy::can(&user, Action::ViewDeal, Some(d.owner_id))).collect();
```

It *returns* the right deals, but:

- it **loads every deal in the company** to show a rep their 12, so it gets slower as the business grows;
- **pagination breaks**: "page 1, 20 per page" fetches 20 rows *then* filters them, so a rep gets 3
  results and a confusing "next page" link;
- **counts leak**: a `total` computed before filtering tells a rep how many deals exist company-wide;
- one forgotten `.filter` in some other endpoint leaks everything.

**For lists, the rule belongs in the query.** The database only ever returns rows the user may see.

> 🟢 **FOLLOW ALONG**: `src/deals/db.rs`

```rust
use crate::users::UserId;

/// Which deals to list. `owner: None` means "everyone's".
#[derive(Debug, Clone, Default)]
pub struct DealFilter {
    pub owner: Option<UserId>,
}

pub async fn list(db: impl PgExecutor<'_>, filter: &DealFilter) -> Result<Vec<Deal>, CrmError> {
    let rows = sqlx::query_as!(
        DealRow,
        "SELECT id, company_id, title, value_cents, stage, owner_id
         FROM deals
         WHERE ($1::BIGINT IS NULL OR owner_id = $1)
         ORDER BY id",
        filter.owner.map(|owner| owner.0),
    )
    .fetch_all(db)
    .await?;
    let deals = rows
        .into_iter()
        .map(Deal::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(deals)
}
```

And `pub use db::DealFilter;` in `src/deals/mod.rs`.

`list` has one other caller: the Lab 33 repository test `sql_pipeline_matches_the_rust_pipeline`
in `tests/db/deals.rs`. Give it `deals::db::list(&pool, &deals::DealFilter::default())`.

- **`($1::BIGINT IS NULL OR owner_id = $1)`** is a **nullable filter**: bind `NULL` and the
  condition is always true (no filter). Bind an id and it's `owner_id = id`. One static
  query, no string building. The `::BIGINT` cast tells Postgres (and SQLx's type checker) what type
  `$1` is when it's `NULL`.
- **`filter.owner.map(|owner| owner.0)`** turns `Option<UserId>` into `Option<i64>`, which SQLx
  binds as a nullable `BIGINT`. `Option` ↔ `NULL` (Lab 31).
- **The repository doesn't know about roles.** It takes a filter that says *what* to return.
  *Why* (the user is a rep) is the handler's decision. This keeps `deals::db` reusable, for
  example by Lab 39's background jobs, which have no user at all.
- **If your Lab 29/32 `list` already takes filter/pagination parameters** (company, stage, page…),
  add `owner` to that struct and one more `AND ($n::BIGINT IS NULL OR owner_id = $n)`, or a
  `push_bind` if you built it with `QueryBuilder` in Lab 32. The `COUNT(*)` for `total`
  needs the **same** condition, or the count leaks.
- The `deals_owner_id_idx` index from Lab 35 is what keeps `owner_id = $1` fast.

> 🟢 **FOLLOW ALONG**: `src/http/deals.rs`: the list handler

```rust
// `AuthUser` is already imported (Lab 35's create_deal uses it). Add:
use crate::auth::policy::{self, Action};
use crate::deals::DealFilter;

async fn list_deals(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<DealResponse>>, ApiError> {
    let filter = DealFilter {
        owner: if policy::can(&user, Action::ViewAllDeals, None) {
            None
        } else {
            Some(user.id)
        },
    };
    let deals = deals::db::list(&state.pool, &filter).await?;
    Ok(Json(deals.iter().map(DealResponse::from).collect()))
}
```

The policy decides, and the filter carries the decision into SQL. A rep doesn't get a 403 for
`GET /deals`. They get *their* list. Listing is allowed for everyone; what changes is the scope.

> If `GET /deals` also accepts `?owner_id=` (or you add it), a rep must not be able to use it
> to widen their scope: ignore it, or overwrite it with `Some(user.id)` whenever
> `ViewAllDeals` is denied. The policy wins over the query string.

---

## Step 5 — Single records: enforce in Rust, choose 403 or 404

For `GET /deals/{id}` you *could* also push the rule into SQL:
`SELECT ... WHERE id = $1 AND ($2::BIGINT IS NULL OR owner_id = $2)`. A rep asking for a
colleague's deal gets no row, so 404. That works for viewing.

But look at **reassign**. A rep asking to reassign *their own* deal should get **403** ("you
can see this, but you may not do that"). To tell 403 from 404 you need the row, so for
single records we **load first, then decide in Rust**.

### 403 or 404? The leakage argument

Suppose rep Bob requests `GET /deals/1`, which belongs to Ada.

```text
403 Forbidden  →  "deal 1 exists, you just can't see it"
404 Not Found  →  "there is no deal 1 (for you)"
```

With 403, Bob can **enumerate**: request ids 1…10000 and learn how many deals exist, which
ones are new this week, how fast the company is growing. In a CRM, that's competitive
intelligence. So the rule is:

> **If you can't *see* it, it doesn't exist → 404.**
> **If you *can* see it but can't do *this* to it → 403.**

A 403 is only honest when the caller already knows the record exists (because they're allowed to see it).

### `load_deal_for`: the rule in one place

> 🟢 **FOLLOW ALONG**: `src/http/deals.rs`

```rust
// `CrmError` is already imported in this file (create_deal uses it since Lab 29).

/// Loads a deal and checks `action` on it.
/// - can't even see it  -> 404, exactly as if it didn't exist
/// - can see it, but not do `action` -> 403
async fn load_deal_for(
    state: &AppState,
    user: &AuthUser,
    id: DealId,
    action: Action,
) -> Result<Deal, ApiError> {
    let deal = deals::db::get(&state.pool, id).await?;
    if !policy::can(user, Action::ViewDeal, Some(deal.owner_id)) {
        return Err(CrmError::NotFound { entity: "deal", id: id.0 }.into());
    }
    policy::authorize(user, action, Some(deal.owner_id))?;
    Ok(deal)
}
```

- The 404 is built **exactly** like the one `deals::db::get` returns for a missing id, so the
  two responses are identical (except for the id you asked for, which you already knew).
- The `ViewDeal` check happens **before** the requested action, for every action. That ordering *is*
  the 403/404 rule.
- It takes `&AppState` and `&AuthUser`: it only needs to read them. Handlers own them (extracted
  per request) and lend them out.

Now every single-deal handler goes through it:

> 🟢 **FOLLOW ALONG**

```rust
async fn get_deal(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<DealResponse>, ApiError> {
    let deal = load_deal_for(&state, &user, DealId(id), Action::ViewDeal).await?;
    Ok(Json(DealResponse::from(&deal)))
}

async fn move_deal(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<MoveDealRequest>,
) -> Result<Json<DealResponse>, ApiError> {
    let deal = load_deal_for(&state, &user, DealId(id), Action::EditDeal).await?;
    // Lab 31's optimistic move, unchanged: it re-reads the deal and only updates
    // if nobody changed the stage in between.
    let deal = deals::db::move_stage(&state.pool, deal.id, req.stage).await?;
    Ok(Json(DealResponse::from(&deal)))
}
```

`load_deal_for` reads the deal once for the *policy*, and `move_stage` reads it again for the
*transition*. One extra primary-key lookup buys a handler where the authorization check can't be
skipped. (Making `load_deal_for` `pub(crate)` now saves an edit in Your Turn 5.)

`create_deal` doesn't need a policy check: everyone may create deals, and they own what they
create (Lab 35). If you have `PUT`/`DELETE /deals/{id}`, route them through `load_deal_for`
with `EditDeal` too.

### Companies

Companies aren't owned. They're shared reference data, so the only rule is `DeleteCompany`:

> 🟢 **FOLLOW ALONG**: `src/http/companies.rs`

```rust
use crate::auth::AuthUser;
use crate::auth::policy::{Action, authorize};

async fn delete_company(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<StatusCode, ApiError> {
    authorize(&user, Action::DeleteCompany, None)?;
    // ... your existing delete (with the HasContacts check) ...
}
```

Here **403 is right**: every user can see every company, so "you may not delete it" leaks nothing.

This breaks one Lab 33 test: `company_with_contacts_cannot_be_deleted` in `tests/api/companies.rs`
deletes as the `rep@example.com` user Lab 35 gave it, and now gets 403 instead of 409. Once you
have `login_as` (Step 7), log in as a manager there (`login_as(&app, &pool, "meg@example.com",
Role::Manager)`, with `app(pool.clone())`) and add a comment saying why.

**Order matters:** authorize *before* touching the database. A rep's `DELETE` is refused
without even finding out whether the company exists, so it doesn't reveal that either.

---

## Step 6 — The admin's escape hatch: `OwnRoleChange`

Admins will be able to change roles (Your Turn 3). One rule needs a new domain error: **an admin
can't change their own role.** Otherwise the last admin can demote themselves, and then nobody can
manage users without going into `psql`.

> 🟢 **FOLLOW ALONG**: `src/errors.rs`: add to `CrmError`

```rust
    #[error("you cannot change your own role")]
    OwnRoleChange,
```

`cargo check` now points at your `ApiError` mapping (non-exhaustive `match` on `CrmError`).
Map it to **409 `conflict`**: the request is well-formed and allowed in general, but it
conflicts with the current state ("you are the actor"). Like `HasContacts`.

---

## Step 7 — Test helpers for many users

Each authorization test needs *several* users with *different* roles. Registration always gives
`sales_rep` (Lab 34), so tests promote users directly in the database, and then log in, because
**the role is baked into the token at login** (Lab 35):

> 🟢 **FOLLOW ALONG**: `tests/api/helpers.rs`

```rust
use rust_crm::users::Role;

/// Registers `email`, gives it `role` directly in the database, then logs in.
/// The order matters: the role is baked into the token at login time.
pub async fn login_as(app: &Router, pool: &PgPool, email: &str, role: Role) -> String {
    register_and_login(app, email).await;
    sqlx::query("UPDATE users SET role = $1 WHERE email = $2")
        .bind(role.as_str())
        .bind(email)
        .execute(pool)
        .await
        .unwrap();
    login(app, email).await
}

pub async fn user_id(app: &Router, token: &str) -> i64 {
    let (_, me) = send_authed(app, token, get("/me")).await;
    me["id"].as_i64().unwrap()
}

/// Creates a company and a deal owned by the caller; returns the deal id.
pub async fn create_deal(app: &Router, token: &str) -> i64 {
    let (status, company) =
        send_authed(app, token, post_json("/companies", json!({ "name": "Acme" }))).await;
    assert_eq!(status, StatusCode::CREATED, "{company}");
    let (status, deal) = send_authed(
        app,
        token,
        post_json(
            "/deals",
            json!({ "company_id": company["id"], "title": "Big deal", "value_cents": 100_000 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{deal}");
    deal["id"].as_i64().unwrap()
}
```

- `login_as` registers and logs in first (and throws that token away), then logs in again after
  the `UPDATE`. That first token would carry the *old* role. You'll write a test that proves this matters.
- The `UPDATE` uses the **function** form `sqlx::query(...)`: test-only SQL doesn't need to be in
  `.sqlx/`, and it's obvious at a glance that this is a test shortcut, not app code.
- `user_id` gets ids from `/me` instead of assuming `1, 2, 3` (identity gaps, Lab 34).

And the first rule test, in a new file:

> 🟢 **FOLLOW ALONG**: `tests/api/authz.rs` (and `mod authz;` in `tests/api/main.rs`)

```rust
use crate::helpers::{app, create_deal, error_code, get, login_as, send_authed};
use axum::http::StatusCode;
use rust_crm::users::Role;
use sqlx::PgPool;

#[sqlx::test]
async fn rep_cannot_see_another_reps_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let deal = create_deal(&app, &alice).await;

    let (status, body) = send_authed(&app, &bob, get(&format!("/deals/{deal}"))).await;
    let (_, missing) = send_authed(&app, &bob, get("/deals/999999")).await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error_code(&body), "not_found");
    // Indistinguishable from a deal that really doesn't exist (apart from the id)
    assert_eq!(error_code(&body), error_code(&missing));
}
```

```bash
cargo test --test api authz
```

---

## Step 8 — Offline query data

`deals::db::list` changed and Your Turns 2, 3 and 5 add more `query_as!` calls, so refresh `.sqlx/`
once they compile, or CI's `cargo sqlx prepare --check` (Lab 33) fails:

```bash
cargo sqlx prepare -- --all-targets
git add .sqlx
```

---

## ▶️ Run It

Do Your Turn 2 (reassign) first, then:

```bash
cargo run
```

Register Bob and Meg (Ada exists from Lab 35), make Meg a manager, and get three tokens:

```bash
for who in bob meg; do
  curl -s -o /dev/null -X POST localhost:3000/auth/register -H 'content-type: application/json' \
    -d "{\"email\":\"$who@example.com\",\"name\":\"$who\",\"password\":\"correct horse battery staple\"}"
done
docker compose exec db psql -U crm -d crm -c "UPDATE users SET role = 'manager' WHERE email = 'meg@example.com'"

tok() { curl -s -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d "{\"email\":\"$1\",\"password\":\"correct horse battery staple\"}" | jq -r .access_token; }
ADA=$(tok ada@example.com); BOB=$(tok bob@example.com); MEG=$(tok meg@example.com)
BOB_ID=$(curl -s localhost:3000/me -H "Authorization: Bearer $BOB" | jq .id)
```

Deal 1 is Ada's (created in Lab 35's ▶️ Run It):

```bash
curl -s localhost:3000/deals -H "Authorization: Bearer $BOB"; echo
curl -s -w " %{http_code}\n" localhost:3000/deals/1   -H "Authorization: Bearer $BOB"
curl -s -w " %{http_code}\n" localhost:3000/deals/999 -H "Authorization: Bearer $BOB"
curl -s -w " %{http_code}\n" -X PUT localhost:3000/deals/1/owner -H 'content-type: application/json' \
  -H "Authorization: Bearer $ADA" -d "{\"owner_id\":$BOB_ID}"
curl -s localhost:3000/deals -H "Authorization: Bearer $MEG"; echo
curl -s -w " %{http_code}\n" -X PUT localhost:3000/deals/1/owner -H 'content-type: application/json' \
  -H "Authorization: Bearer $MEG" -d "{\"owner_id\":$BOB_ID}"
curl -s localhost:3000/deals -H "Authorization: Bearer $BOB"; echo
curl -s -w " %{http_code}\n" localhost:3000/deals/1 -H "Authorization: Bearer $ADA"
curl -s -w " %{http_code}\n" localhost:3000/admin/users -H "Authorization: Bearer $MEG"
```

## ✅ Expected Result

```text
[]
{"error":{"code":"not_found","message":"deal #1 not found"}} 404
{"error":{"code":"not_found","message":"deal #999 not found"}} 404
{"error":{"code":"forbidden","message":"you are not allowed to do this"}} 403
[{"id":1,"company_id":1,"title":"Annual licence","value_cents":1200000,"stage":"qualification","owner_id":1}]
{"id":1,"company_id":1,"title":"Annual licence","value_cents":1200000,"stage":"qualification","owner_id":3} 200
[{"id":1,"company_id":1,"title":"Annual licence","value_cents":1200000,"stage":"qualification","owner_id":3}]
{"error":{"code":"not_found","message":"deal #1 not found"}} 404
{"error":{"code":"forbidden","message":"you are not allowed to do this"}} 403
```

Read it as a story:

1. Bob's list is empty. The deal exists, but not *for him*.
2. Bob asking for deal 1 and deal 999 gets the same answer: no leak.
3. Ada can see deal 1 but may not reassign it: **403** (she already knows it exists).
4. Meg (manager) sees everything, reassigns deal 1 to Bob (`owner_id` 3 here, yours may differ)…
5. …so now Bob sees it, and Ada gets a **404** for a deal she created. It's not hers any more.
6. Managers can't manage users: 403.

Then: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## 🧠 Understand It

**Three enforcement points, one policy:**

```text
                     ┌──────────────────────────────┐
                     │ can(user, action, owner)     │  ← src/auth/policy.rs (pure, table-tested)
                     └──────┬──────────┬────────────┘
        lists               │          │             single records / actions
  can(ViewAllDeals)?        │          │   load_deal_for: can(ViewDeal)? else 404
  → DealFilter{owner}       │          │                  authorize(action)? else 403
  → SQL WHERE owner_id = $1 ▼          ▼   authorize(DeleteCompany / ManageUsers)? else 403
```

Every decision goes through `can`. The handlers decide *how* to enforce it (a filter, a 404 or
a 403), but none of them re-implements the rule. If the rules change, say "managers can only see
their team's deals" (that's Challenge E), you change `can` and the filter construction, and the
tests tell you everything else that has to change.

**Why isn't `can` async, or given the database?** If the policy could query, it would be slow
to test, and soon it would be querying *differently* from the handlers. Keeping it pure forces
handlers to load the facts (the owner) and pass them in. The facts are visible at the call site,
and the policy stays a total function of its inputs.

**The stale-role problem, revisited.** The role comes from the token. Promote Bob to manager and
his *current* token still says `sales_rep` for up to 15 minutes. Demote an admin and they stay admin
for up to 15 minutes. That's the revocation trade-off from Lab 35, Step 1, now with real
consequences, and Your Turn 4 has a test that pins the behaviour down so nobody is surprised by
it. Alternatives: load the role from the DB in the extractor (one indexed query per request), or
add a `token_version` that the role-change endpoint increments.

**Why does `reassign` check the *new* owner exists?** `deals.owner_id` has a foreign key, so
the database would reject it anyway. But a foreign-key violation surfaces as a `sqlx::Error`,
which your `ApiError` turns into a 500. Checking first lets you answer with a precise **422**
on the `owner_id` field. (A rare race remains: the user is deleted between check and update.
The FK still protects the data, and the client gets a 500 in that one case. Good enough.)

**Why does `GET /admin/users` with no token give 401, not 403?** The middleware and extractor
run before the handler's `authorize`. Authentication always comes before authorization.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: the leaky version.** In `load_deal_for`, swap the two checks so that
> `authorize(user, action, ..)?` runs **first**. Which of your tests fail, and what would Bob
> now learn from `PUT /deals/1/owner`? Swap them back.

> 🟡 **EXPERIMENT 2: filter in Rust.** Change `list_deals` to call `deals::db::list` with
> `DealFilter::default()` and filter with `.into_iter().filter(|d| policy::can(...))`. Do the
> tests still pass? (They should!) So why is it still wrong? Write down two concrete failures it
> causes once pagination exists. Revert.

> 🟡 **EXPERIMENT 3: the wildcard trap.** Replace the two `SalesRep` arms with
> `(Role::SalesRep, ViewDeal | EditDeal) => owner == Some(user.id), _ => false,` (remove the
> Manager `false` arm too). Add `ExportDeals` to `Action` again. Does it compile now? Who can
> export deals? Was anyone asked? Revert.

> 🟡 **EXPERIMENT 4: stale role, by hand.** With the server running: log in as Bob, promote him
> to manager in `psql`, and call `GET /deals` with his **old** token, then with a new one. Then
> answer: if you fired Bob right now, how long could he keep reading his deals?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: the full policy table** (`src/auth/policy.rs`)
>
> - [ ] `policy_table` covers **every** `(role, action)` pair: 6 actions × 3 roles
> - [ ] For `ViewDeal` and `EditDeal`, the `SalesRep` rows cover `Mine`, `Theirs` **and** `Nobody`
> - [ ] For `ReassignDeal`, there's a `SalesRep, Mine` row (that's the 403 case)
> - [ ] The table matches the rules table in 🔨 What We're Building exactly. Read them side by side.
> - [ ] Temporarily break `can` (e.g. let reps `ReassignDeal`) and confirm the failure message names the row

> 🔵 **YOUR TURN 2: `PUT /deals/{id}/owner`**
>
> ```rust
> // src/deals/db.rs
> pub async fn set_owner(db: impl PgExecutor<'_>, id: DealId, owner: UserId) -> Result<Deal, CrmError>;
> ```
>
> | Situation | Response |
> |---|---|
> | manager/admin, deal exists, new owner exists | **200** + the updated `DealResponse` |
> | sales rep, **own** deal | **403** `forbidden` |
> | sales rep, someone else's deal | **404** (same as a missing deal) |
> | deal doesn't exist | **404** |
> | `owner_id` isn't a user | **422** `validation_failed`, `fields[0].field == "owner_id"` |
>
> - [ ] Body: `{ "owner_id": <i64> }` (a `ReassignDealRequest` DTO)
> - [ ] Uses `load_deal_for(.., Action::ReassignDeal)`, so no new 403/404 logic
> - [ ] `set_owner` uses `UPDATE ... RETURNING` (one round trip) and returns `NotFound` if no row
> - [ ] The ▶️ Run It sequence produces ✅ Expected Result

> 🔵 **YOUR TURN 3: admin endpoints** (new `src/http/admin.rs`, merged into the **protected** router)
>
> ```rust
> // src/users/db.rs
> pub async fn list(db: impl PgExecutor<'_>) -> Result<Vec<User>, CrmError>;              // ORDER BY id
> pub async fn set_role(db: impl PgExecutor<'_>, id: UserId, role: Role) -> Result<User, CrmError>; // NotFound if missing
> ```
>
> | Endpoint | Rule | Responses |
> |---|---|---|
> | `GET /admin/users` | `ManageUsers` | 200 `[UserResponse]` · 403 for managers and reps |
> | `PUT /admin/users/{id}/role` body `{ "role": "manager" }` | `ManageUsers`; not on yourself | 200 `UserResponse` · 403 · 404 unknown user · 409 `conflict` on yourself |
>
> - [ ] Reuses `UserResponse` from `http/auth.rs`, so there's still no way to return a hash
> - [ ] `role` deserializes straight into `Role` (`"sales_rep"`, `"manager"`, `"admin"`). An unknown
>       string like `"boss"` is rejected by `AppJson` with **400** `bad_request` (Lab 28), not by hand-written code:
>       ``{"error":{"code":"bad_request","message":"Failed to deserialize the JSON body into the target type: role: unknown variant `boss`, expected one of `admin`, `manager`, `sales_rep` at line 1 column 14"}}``
> - [ ] `authorize(&user, Action::ManageUsers, None)?` is the **first** line of both handlers

> 🔵 **YOUR TURN 4: an API test for every rule** (`tests/api/authz.rs`)
>
> One `#[sqlx::test]` per row. Names are suggestions. The *assertions* are the spec.
>
> | # | Test | Assert |
> |---|---|---|
> | 1 | `rep_lists_only_own_deals` | Alice and Bob each create a deal; Alice's `GET /deals` ids == `[hers]` |
> | 2 | `rep_can_view_and_move_own_deal` | 200 on `GET`; `POST /deals/{id}/stage {"stage":"proposal"}` → 200, stage `proposal` |
> | 3 | `rep_cannot_see_another_reps_deal` | ✅ done in Step 7 |
> | 4 | `rep_cannot_move_another_reps_deal` | 404 |
> | 5 | `rep_cannot_reassign_own_deal` | 403, `error.code == "forbidden"` |
> | 6 | `rep_reassigning_someone_elses_deal_gets_404` | 404 |
> | 7 | `manager_sees_all_deals` | list has both reps' deals; `GET` of a rep's deal → 200 |
> | 8 | `manager_can_move_a_reps_deal` | 200 |
> | 9 | `manager_reassigns_and_the_new_owner_sees_the_deal` | 200 with new `owner_id`; new owner `GET` → 200; old owner → 404 |
> | 10 | `reassigning_to_an_unknown_user_is_422` | 422, `fields[0].field == "owner_id"` |
> | 11 | `rep_cannot_delete_a_company` | 403 |
> | 12 | `manager_can_delete_a_company` | 204 |
> | 13 | `only_admins_list_users` | rep 403, manager 403, admin 200 with 3 users |
> | 14 | `role_change_applies_from_the_next_login` | admin promotes a rep to manager → 200; the rep's **old** token still gets 403 deleting a company; a **fresh** login gets 204 |
> | 15 | `manager_cannot_change_roles` | 403 |
> | 16 | `admin_cannot_change_own_role` | 409, `error.code == "conflict"` |
> | 17 | `unauthenticated_admin_request_is_401_not_403` | no token on `GET /admin/users` → 401 |
>
> - [ ] All 17 pass: `cargo test --test api authz`
> - [ ] Each test creates its own users. No test depends on another's data.

> 🔵 **YOUR TURN 5: close the side doors**
>
> `GET /deals/{id}` is protected now. But deal data also leaves the API through other endpoints
> you built in Labs 29–32. Find every one and apply the same rule:
>
> - [ ] `GET /search?q=` (Lab 32): the `deals` part of the result contains only deals the caller
>       may view (same nullable owner filter, in SQL: `deals::db::search` gains a `&DealFilter`)
> - [ ] `GET /history?subject=deal:N`, `GET /activities?subject=deal:N`, `GET /notes?subject=deal:N`:
>       a rep asking about a deal they can't view gets the deal's **404**
> - [ ] `POST /activities` / `POST /notes` with `subject: "deal:N"` for a deal the caller can't view: **404**
>       (otherwise reps can write into colleagues' deals and find out which ids exist from the error)
> - [ ] One API test per endpoint above
> - [ ] Two Lab 33 tests in `tests/api/activities.rs` change, because deal subjects are now looked up
>       before anything else: `keyset_pages_walk_the_whole_history_once` logs calls on fixture deal 1,
>       which belongs to the fixture user, so its token must be a manager's; and
>       `a_tampered_cursor_is_rejected` asks about `deal:1` with no fixtures, which is now a 404
>       before the cursor is read, so point it at `company:1`. Add a comment to each saying what changed.
> - [ ] Write down (a comment in `policy.rs` is fine) what you decided for `GET /pipeline` and the
>       `open_deal_count` in `GET /companies/overview` (Lab 32): are org-wide deal totals sensitive for
>       reps? There's no single right answer, but there must be a decision.

## 💡 Hint

> 💡 **HINT (Your Turn 2)**: the handler is `load_deal_for`, then "does the new owner exist?",
> then `set_owner`. Use `users::db::get` from Lab 34 for the existence check and `match` on its
> result: `Ok(_)`, `Err(CrmError::NotFound { .. })`, any other `Err`.

<details><summary>Hint 2 (Your Turn 3: own-role check)</summary>

`AppPath(id): AppPath<i64>` (Lab 28's extractor) gives you the target. Compare `UserId(id) == user.id` **after**
`authorize` (a manager trying to change their own role should get the 403 like any other manager
request, not a hint about self-changes).

</details>

<details><summary>Hint 3 (Your Turn 4: test setup)</summary>

Most tests follow: `let app = app(pool.clone());` → one `login_as` per person → `create_deal`
→ one request → asserts. For #14 you need two companies (one per delete attempt) and the
`login` helper from Lab 35. For #13, remember that `login_as` *registers*, so three
`login_as` calls = three users.

</details>

<details><summary>Hint 4 (Your Turn 5: subject=deal:N)</summary>

`Subject` (Lab 20) tells you what kind of record is referenced. Write one helper, e.g.
`async fn ensure_subject_visible(state, user, subject) -> Result<(), ApiError>`, that for
`Subject::Deal(id)` calls `load_deal_for(state, user, id, Action::ViewDeal)` and ignores the
deal, and for companies and contacts does nothing (they're shared). Call it first in each of
those handlers.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why is `can` a pure function, and what has to happen *before* a handler can call it?
2. Why does the `Manager` arm list `ManageUsers => false` explicitly instead of ending with `_ => false`?
3. Give three reasons list filtering belongs in SQL and not in a Rust `.filter()`.
4. A rep requests a colleague's deal. Why 404 and not 403? When *is* 403 the right answer?
5. In `load_deal_for`, why does the `ViewDeal` check come before the requested action?
6. Why does `DELETE /companies/{id}` authorize *before* querying the database?
7. A manager is demoted to sales rep. When does it take effect, and why?
8. Name two endpoints besides `/deals/{id}` that could leak deal data.

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit
```bash
git add .
git commit -m "Enforce deal ownership"
git tag lab-36
git push && git push --tags
```

(The first commit, "Add role-based policies", was made at the end of Step 3.)

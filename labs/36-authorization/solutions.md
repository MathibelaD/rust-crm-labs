# Lab 36 — Solutions

> 🔴 One good answer per task, with the reasoning. Your code can differ. The rules table and
> the tests are what must agree.

---

## Your Turn 1 — the full policy table

```rust
    #[test]
    fn policy_table() {
        use Role::*;
        use Target::*;
        #[rustfmt::skip]
        let table = [
            // role      action         target  allowed
            (Admin,    ViewDeal,      Theirs, true),
            (Admin,    EditDeal,      Theirs, true),
            (Admin,    ReassignDeal,  Theirs, true),
            (Admin,    ViewAllDeals,  Nobody, true),
            (Admin,    DeleteCompany, Nobody, true),
            (Admin,    ManageUsers,   Nobody, true),

            (Manager,  ViewDeal,      Theirs, true),
            (Manager,  EditDeal,      Theirs, true),
            (Manager,  ReassignDeal,  Theirs, true),
            (Manager,  ViewAllDeals,  Nobody, true),
            (Manager,  DeleteCompany, Nobody, true),
            (Manager,  ManageUsers,   Nobody, false),

            (SalesRep, ViewDeal,      Mine,   true),
            (SalesRep, ViewDeal,      Theirs, false),
            (SalesRep, ViewDeal,      Nobody, false),
            (SalesRep, EditDeal,      Mine,   true),
            (SalesRep, EditDeal,      Theirs, false),
            (SalesRep, EditDeal,      Nobody, false),
            (SalesRep, ReassignDeal,  Mine,   false),
            (SalesRep, ReassignDeal,  Theirs, false),
            (SalesRep, ViewAllDeals,  Nobody, false),
            (SalesRep, DeleteCompany, Nobody, false),
            (SalesRep, ManageUsers,   Nobody, false),
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
```

**Reasoning**

- **23 rows**: 6 actions × 3 roles = 18 pairs, plus the extra ownership cases for the two
  "own only" actions and `ReassignDeal, Mine`. That last row is the one people forget, and
  it's exactly the case that produces a 403 in the API.
- **`Nobody` rows for reps**: deny-by-default must be *tested*, not just intended.
- Breaking `can` (letting reps reassign) fails with
  `SalesRep ReassignDeal on Mine` in the panic message. That's why the message argument is there.
- Could you generate the table from the enum? You could iterate over all variants with a crate
  like `strum`, but then the *expected* column would have to come from somewhere, which means a
  second copy of the policy. A hand-written table is a deliberate second, independent statement
  of the rules. When it disagrees with `can`, one of them is wrong, and a human has to look.

(Verified: `cargo test --lib policy`, 2 passed.)

---

## Your Turn 2 — `PUT /deals/{id}/owner`

```rust
// src/deals/db.rs
pub async fn set_owner(
    db: impl PgExecutor<'_>,
    id: DealId,
    owner: UserId,
) -> Result<Deal, CrmError> {
    let row = sqlx::query_as!(
        DealRow,
        "UPDATE deals SET owner_id = $2 WHERE id = $1
         RETURNING id, company_id, title, value_cents, stage, owner_id",
        id.0,
        owner.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

```rust
// src/http/deals.rs (AppJson, AppPath, CrmError and AuthUser are already imported)
use super::error::FieldError;
use crate::users::{self, UserId};
use axum::routing::{get, post, put}; // was {get, post}

// in routes():
//     .route("/deals/{id}/owner", put(reassign_deal))

#[derive(Debug, Deserialize)]
pub struct ReassignDealRequest {
    pub owner_id: i64,
}

async fn reassign_deal(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<ReassignDealRequest>,
) -> Result<Json<DealResponse>, ApiError> {
    let deal = load_deal_for(&state, &user, DealId(id), Action::ReassignDeal).await?;

    let new_owner = UserId(req.owner_id);
    match users::db::get(&state.pool, new_owner).await {
        Ok(_) => {}
        Err(CrmError::NotFound { .. }) => {
            return Err(ApiError::Validation(vec![FieldError {
                field: "owner_id",
                message: format!("user {} does not exist", req.owner_id),
            }]));
        }
        Err(e) => return Err(e.into()),
    }

    let deal = deals::db::set_owner(&state.pool, deal.id, new_owner).await?;
    Ok(Json(DealResponse::from(&deal)))
}
```

**Reasoning**

- **All the 403/404 logic is one line**: `load_deal_for(.., Action::ReassignDeal)`. The rep-own-deal
  case passes `ViewDeal` and fails `ReassignDeal` → 403. The rep-other-deal case fails `ViewDeal` → 404.
  Nothing new to get wrong.
- **`match` with three arms** instead of `?`: a missing user here isn't "the resource you asked
  for doesn't exist" (that would be a 404 about the *deal*). It's "a field in your body points
  at nothing" → 422 on `owner_id`. Every other error (database down…) still propagates through `e.into()`.
- **`Ok(_)`**: we only need existence, so the `User` is dropped immediately. If you added a rule
  like "deals can only be owned by sales reps or managers", you'd bind it and check `user.role`.
- **`UPDATE ... RETURNING`**: one round trip, and the response reflects what's *actually* in the
  database. `fetch_optional` + `NotFound` covers the case where the deal was deleted between
  `load_deal_for` and the update.
- **Shadowing `deal`** (the loaded one → the updated one) says "this is the new truth".
- Should reassigning to the *same* owner be an error? It's harmless and idempotent, so we return 200.

---

## Your Turn 3 — admin endpoints

```rust
// src/users/db.rs
pub async fn list(db: impl PgExecutor<'_>) -> Result<Vec<User>, CrmError> {
    let rows = sqlx::query_as!(
        UserRow,
        "SELECT id, email, name, role, created_at FROM users ORDER BY id"
    )
    .fetch_all(db)
    .await?;
    let users = rows
        .into_iter()
        .map(User::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(users)
}

pub async fn set_role(db: impl PgExecutor<'_>, id: UserId, role: Role) -> Result<User, CrmError> {
    let row = sqlx::query_as!(
        UserRow,
        "UPDATE users SET role = $2 WHERE id = $1
         RETURNING id, email, name, role, created_at",
        id.0,
        role.as_str(),
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

`.map(User::try_from).collect::<Result<Vec<_>, _>>()?`: collecting an iterator of `Result`s
into a `Result<Vec<_>, _>` stops at the first error (Lab 17). One corrupt row fails the whole
list (as a 500) instead of silently disappearing from it. The turbofish is needed because the
`?` right after it hides the target type from inference. `not_found(id)` is the helper from Lab 34's `users::db`.

```rust
// src/http/admin.rs
use super::auth::UserResponse;
use super::extract::{AppJson, AppPath};
use super::{ApiError, AppState};
use crate::auth::AuthUser;
use crate::auth::policy::{Action, authorize};
use crate::errors::CrmError;
use crate::users::{self, Role, UserId};
use axum::{
    Json, Router,
    extract::State,
    routing::{get, put},
};
use serde::Deserialize;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/admin/users", get(list_users))
        .route("/admin/users/{id}/role", put(change_role))
}

#[derive(Deserialize)]
pub struct ChangeRoleRequest {
    pub role: Role,
}

async fn list_users(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserResponse>>, ApiError> {
    authorize(&user, Action::ManageUsers, None)?;
    let users = users::db::list(&state.pool).await?;
    Ok(Json(users.iter().map(UserResponse::from).collect()))
}

async fn change_role(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
    AppJson(req): AppJson<ChangeRoleRequest>,
) -> Result<Json<UserResponse>, ApiError> {
    authorize(&user, Action::ManageUsers, None)?;
    let target = UserId(id);
    if target == user.id {
        return Err(CrmError::OwnRoleChange.into());
    }
    let updated = users::db::set_role(&state.pool, target, req.role).await?;
    Ok(Json(UserResponse::from(&updated)))
}
```

Wire it in `src/http/mod.rs`: `mod admin;` and `.merge(admin::routes())` **inside** the
`protected` router (before `.route_layer`).

**Reasoning**

- **`super::auth::UserResponse`**: `http::auth` is a private module, but `UserResponse` is
  `pub` inside it, and `admin` is a sibling inside `http`, so it can reach it (Lab 13 visibility:
  privacy is about *where you are*, and `admin` is inside `http`).
- **`role: Role` in the DTO**: serde's `rename_all = "snake_case"` from Lab 34 means
  `"sales_rep"` deserializes and `"boss"` is rejected before the handler runs: `AppJson` turns
  serde's "unknown variant `boss`, expected one of …" into a 400 `bad_request` (verified).
  No string matching in the handler.
- **`authorize` first, own-role check second**: a manager calling this on themselves gets the
  same 403 as any other manager call, because the self-change rule only matters for people allowed to change roles.
- **Why not a separate `/admin` middleware?** You could add a `route_layer` to an `admin`
  sub-router that requires `Role::Admin`, as defence in depth like `require_auth`. It's a good
  addition. The `authorize` call in each handler should stay anyway, because it's next to the
  code it protects, and it's what the tests exercise.

---

## Your Turn 4 — an API test for every rule

Shared imports and two request builders (rule #3 is the Step 7 test, not repeated here):

```rust
use crate::helpers::{
    app, create_deal, delete, error_code, get, login, login_as, post_json, put_json, send,
    send_authed, user_id,
};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use rust_crm::users::Role;
use serde_json::json;
use sqlx::PgPool;

fn stage(deal: i64, stage: &str) -> Request<Body> {
    post_json(&format!("/deals/{deal}/stage"), json!({ "stage": stage }))
}

fn reassign(deal: i64, owner: i64) -> Request<Body> {
    put_json(
        &format!("/deals/{deal}/owner"),
        json!({ "owner_id": owner }),
    )
}

#[sqlx::test]
async fn rep_lists_only_own_deals(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let mine = create_deal(&app, &alice).await;
    create_deal(&app, &bob).await;

    let (status, body) = send_authed(&app, &alice, get("/deals")).await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<i64> = body["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, [mine]);
}

#[sqlx::test]
async fn rep_can_view_and_move_own_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let deal = create_deal(&app, &alice).await;

    assert_eq!(
        send_authed(&app, &alice, get(&format!("/deals/{deal}")))
            .await
            .0,
        StatusCode::OK
    );
    let (status, body) = send_authed(&app, &alice, stage(deal, "proposal")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["stage"], "proposal");
}

#[sqlx::test]
async fn rep_cannot_move_another_reps_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let deal = create_deal(&app, &alice).await;

    assert_eq!(
        send_authed(&app, &bob, stage(deal, "proposal")).await.0,
        StatusCode::NOT_FOUND
    );
}

#[sqlx::test]
async fn rep_cannot_reassign_own_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let bob_id = user_id(&app, &bob).await;
    let deal = create_deal(&app, &alice).await;

    let (status, body) = send_authed(&app, &alice, reassign(deal, bob_id)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body), "forbidden");
}

#[sqlx::test]
async fn rep_reassigning_someone_elses_deal_gets_404(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let bob_id = user_id(&app, &bob).await;
    let deal = create_deal(&app, &alice).await;

    assert_eq!(
        send_authed(&app, &bob, reassign(deal, bob_id)).await.0,
        StatusCode::NOT_FOUND
    );
}

#[sqlx::test]
async fn manager_sees_all_deals(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    create_deal(&app, &alice).await;
    let bobs = create_deal(&app, &bob).await;

    let (_, body) = send_authed(&app, &manager, get("/deals")).await;
    assert_eq!(body["items"].as_array().unwrap().len(), 2);
    assert_eq!(
        send_authed(&app, &manager, get(&format!("/deals/{bobs}")))
            .await
            .0,
        StatusCode::OK
    );
}

#[sqlx::test]
async fn manager_can_move_a_reps_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let deal = create_deal(&app, &alice).await;

    assert_eq!(
        send_authed(&app, &manager, stage(deal, "lost")).await.0,
        StatusCode::OK
    );
}

#[sqlx::test]
async fn manager_reassigns_and_the_new_owner_sees_the_deal(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let bob_id = user_id(&app, &bob).await;
    let deal = create_deal(&app, &alice).await;

    let (status, body) = send_authed(&app, &manager, reassign(deal, bob_id)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["owner_id"], bob_id);
    assert_eq!(
        send_authed(&app, &bob, get(&format!("/deals/{deal}")))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        send_authed(&app, &alice, get(&format!("/deals/{deal}")))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
}

#[sqlx::test]
async fn reassigning_to_an_unknown_user_is_422(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let deal = create_deal(&app, &alice).await;

    let (status, body) = send_authed(&app, &manager, reassign(deal, 999_999)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["fields"][0]["field"], "owner_id");
}

#[sqlx::test]
async fn rep_cannot_delete_a_company(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let (_, company) = send_authed(
        &app,
        &alice,
        post_json("/companies", json!({ "name": "Acme" })),
    )
    .await;

    let uri = format!("/companies/{}", company["id"]);
    assert_eq!(
        send_authed(&app, &alice, delete(&uri)).await.0,
        StatusCode::FORBIDDEN
    );
}

#[sqlx::test]
async fn manager_can_delete_a_company(pool: PgPool) {
    let app = app(pool.clone());
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let (_, company) = send_authed(
        &app,
        &manager,
        post_json("/companies", json!({ "name": "Acme" })),
    )
    .await;

    let uri = format!("/companies/{}", company["id"]);
    assert_eq!(
        send_authed(&app, &manager, delete(&uri)).await.0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test]
async fn only_admins_list_users(pool: PgPool) {
    let app = app(pool.clone());
    let rep = login_as(&app, &pool, "rep@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let admin = login_as(&app, &pool, "root@example.com", Role::Admin).await;

    assert_eq!(
        send_authed(&app, &rep, get("/admin/users")).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send_authed(&app, &manager, get("/admin/users")).await.0,
        StatusCode::FORBIDDEN
    );
    let (status, body) = send_authed(&app, &admin, get("/admin/users")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body.as_array().unwrap().len(), 3);
}

#[sqlx::test]
async fn role_change_applies_from_the_next_login(pool: PgPool) {
    let app = app(pool.clone());
    let rep = login_as(&app, &pool, "rep@example.com", Role::SalesRep).await;
    let admin = login_as(&app, &pool, "root@example.com", Role::Admin).await;
    let rep_id = user_id(&app, &rep).await;

    let (status, body) = send_authed(
        &app,
        &admin,
        put_json(
            &format!("/admin/users/{rep_id}/role"),
            json!({ "role": "manager" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["role"], "manager");

    let (_, first) = send_authed(
        &app,
        &admin,
        post_json("/companies", json!({ "name": "A" })),
    )
    .await;
    let (_, second) = send_authed(
        &app,
        &admin,
        post_json("/companies", json!({ "name": "B" })),
    )
    .await;

    // The OLD token still says sales_rep...
    let uri = format!("/companies/{}", first["id"]);
    assert_eq!(
        send_authed(&app, &rep, delete(&uri)).await.0,
        StatusCode::FORBIDDEN
    );
    // ...a fresh login carries the new role.
    let fresh = login(&app, "rep@example.com").await;
    let uri = format!("/companies/{}", second["id"]);
    assert_eq!(
        send_authed(&app, &fresh, delete(&uri)).await.0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test]
async fn manager_cannot_change_roles(pool: PgPool) {
    let app = app(pool.clone());
    let rep = login_as(&app, &pool, "rep@example.com", Role::SalesRep).await;
    let manager = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let rep_id = user_id(&app, &rep).await;

    let req = put_json(
        &format!("/admin/users/{rep_id}/role"),
        json!({ "role": "admin" }),
    );
    assert_eq!(
        send_authed(&app, &manager, req).await.0,
        StatusCode::FORBIDDEN
    );
}

#[sqlx::test]
async fn admin_cannot_change_own_role(pool: PgPool) {
    let app = app(pool.clone());
    let admin = login_as(&app, &pool, "root@example.com", Role::Admin).await;
    let admin_id = user_id(&app, &admin).await;

    let req = put_json(
        &format!("/admin/users/{admin_id}/role"),
        json!({ "role": "sales_rep" }),
    );
    let (status, body) = send_authed(&app, &admin, req).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&body), "conflict");
}

#[sqlx::test]
async fn unauthenticated_admin_request_is_401_not_403(pool: PgPool) {
    let app = app(pool);
    assert_eq!(
        send(&app, get("/admin/users")).await.0,
        StatusCode::UNAUTHORIZED
    );
}
```

**Notes**

- These 17 tests ran green against a real Postgres on top of the Lab 33 suite, with Labs 34–35
  applied: `test result: ok. 44 passed` for the whole `tests/api` suite (Labs 29–35's tests, these 17,
  and the two Your Turn 5 tests below).
- **`stage` / `reassign` request builders** keep each test focused on *who* does *what*. If you
  find yourself repeating a request shape three times, give it a name. (`get`, `delete`,
  `post_json`, `put_json` and `error_code` are your Lab 29 helpers.)
- **#14 is the most valuable test in the file.** It documents a security-relevant limitation
  (stale roles for up to 15 minutes) as *executable* behaviour. If someone later switches the
  extractor to load roles from the database, this test fails, and the failure tells them to
  update the documentation and the test together.
- **Why not one big test that walks through everything?** When it fails, you learn "something about
  authorization broke". Seventeen small tests tell you *which rule*.

---

## Your Turn 5 — closing the side doors

**Two helpers next to `load_deal_for`** in `src/http/deals.rs`, so the decision lives in one place:

```rust
use crate::subject::Subject;

/// The deals a list may return for `user`: everyone's, or only their own.
pub(crate) fn deal_scope(user: &AuthUser) -> DealFilter {
    DealFilter {
        owner: if policy::can(user, Action::ViewAllDeals, None) {
            None
        } else {
            Some(user.id)
        },
    }
}

/// 404 if the subject is a deal the caller may not view. Companies and contacts are shared.
pub(crate) async fn ensure_subject_visible(
    state: &AppState,
    user: &AuthUser,
    subject: Subject,
) -> Result<(), ApiError> {
    match subject {
        Subject::Deal(id) => {
            load_deal_for(state, user, id, Action::ViewDeal).await?;
            Ok(())
        }
        Subject::Company(_) | Subject::Contact(_) => Ok(()),
    }
}
```

`list_deals`'s `let filter = DealFilter { .. };` becomes `let filter = deal_scope(&user);`, and
`load_deal_for` must be `pub(crate)`.
The exhaustive `match` on `Subject` means that when someone adds `Subject::Lead`, they're forced
to decide whether leads are shared.

**Search: in SQL, like `GET /deals`.** `deals::db::search` takes the same filter:

```rust
pub async fn search(
    db: impl PgExecutor<'_>,
    term: &str,
    limit: i64,
    filter: &DealFilter,
) -> Result<Vec<Deal>, CrmError> {
    let rows = sqlx::query_as!(
        DealRow,
        "SELECT id, company_id, title, value_cents, stage, owner_id
         FROM deals
         WHERE title ILIKE '%' || $1 || '%'
           AND ($3::BIGINT IS NULL OR owner_id = $3)
         ORDER BY similarity(title, $1) DESC, id
         LIMIT $2",
        term,
        limit,
        filter.owner.map(|owner| owner.0),
    )
    // ... unchanged ...
}
```

and the `search` handler takes `user: AuthUser`, computes `let scope = deal_scope(&user);` before
the `try_join!`, and passes `&scope` to `deals::db::search`.

**Subject-based endpoints: in Rust, like `GET /deals/{id}`.** In `list_activities`,
`list_notes` and `history`, add `user: AuthUser` and call
`ensure_subject_visible(&state, &user, subject).await?;` right after `let subject = q.parse()?;`.
In `log_activity` and `add_note`, check the subject right after Lab 28's validation has parsed
it, before anything is written:

```rust
// add_note
let (subject, body) = validate(req)?;
ensure_subject_visible(&state, &user, subject).await?;
let note = notes::db::insert(&state.pool, &NewNote { subject, body }, user.id).await?;

// log_activity
let input = ActivityInput::validate(req, Utc::now())?;
ensure_subject_visible(&state, &user, input.subject).await?;
```

**Tests** (in `tests/api/authz.rs`; verified):

```rust
#[sqlx::test]
async fn search_only_returns_visible_deals(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let mine = create_deal(&app, &alice).await;
    create_deal(&app, &bob).await;

    let (status, body) = send_authed(&app, &alice, get("/search?q=Big")).await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<i64> = body["deals"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, [mine]);
}

#[sqlx::test]
async fn subject_endpoints_hide_other_reps_deals(pool: PgPool) {
    let app = app(pool.clone());
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    let deal = create_deal(&app, &alice).await;
    let subject = format!("deal:{deal}");

    for uri in [
        format!("/history?subject={subject}"),
        format!("/activities?subject={subject}"),
        format!("/notes?subject={subject}"),
    ] {
        assert_eq!(send_authed(&app, &bob, get(&uri)).await.0, StatusCode::NOT_FOUND, "{uri}");
        assert_eq!(send_authed(&app, &alice, get(&uri)).await.0, StatusCode::OK, "{uri}");
    }
    let note = json!({ "subject": subject, "body": "psst" });
    assert_eq!(
        send_authed(&app, &bob, post_json("/notes", note)).await.0,
        StatusCode::NOT_FOUND
    );
    let call = json!({ "subject": subject, "kind": { "type": "call", "minutes": 5 }, "summary": "hi" });
    assert_eq!(
        send_authed(&app, &bob, post_json("/activities", call)).await.0,
        StatusCode::NOT_FOUND
    );
}
```

The two Lab 33 activity tests that change (see the Your Turn 5 checklist):

```rust
// keyset_pages_walk_the_whole_history_once
// Lab 36: deal 1 belongs to the fixture user, so only a manager (or its owner) sees it.
let app = app(pool.clone());
let token = login_as(&app, &pool, "meg@example.com", Role::Manager).await;

// a_tampered_cursor_is_rejected
// Lab 36: a deal subject is now looked up (404) before the cursor is read; companies aren't.
get("/activities?subject=company:1&cursor=bm9wZQ")
```

**History of a company** in this course's `/history` only covers items whose subject *is* that
company (Lab 32), so it doesn't show activity on the company's deals. If you extended it to do
so, a rep viewing a company's history would see activity on colleagues' deals: filter those in
the SQL (`subject_type <> 'deal' OR subject_id IN (SELECT id FROM deals WHERE owner_id = $n)`)
or decide explicitly that company-level history is shared, and write the decision down.

**Pipeline and company overview**: `GET /pipeline` (totals per stage) and the `open_deal_count`
in `GET /companies/overview` reveal no individual deal. Many teams consider that fine for reps,
others don't (it reveals company revenue). If you restrict them, `deals::db::pipeline` and the
overview's deal sub-query get the same `owner` filter as `list`.

---

## Experiment answers

**1. Swapped checks.** `rep_cannot_move_another_reps_deal` and
`rep_reassigning_someone_elses_deal_gets_404` fail: they now get 403. Bob learns "deal 1 exists"
by trying to reassign it, and can enumerate every deal id.

**2. Rust-side filtering.** The tests pass because they have two deals. It's still wrong
because (a) `?page=1&per_page=20` would fetch 20 company-wide deals and show the rep the 0–20
that are theirs, with page sizes varying randomly, and (b) any `total` count is the company-wide
count, which leaks volume. And (c) it reads every row from Postgres on every request.

**3. The wildcard trap.** It compiles, and `ExportDeals` is granted to admins only, silently. Maybe
that's what you wanted, but nobody decided. In the explicit version, the compiler would have
stopped and asked about managers and reps.

**4. Stale role.** The old token keeps the old role until it expires (≤ 15 minutes, + 60 s
leeway). A fired employee keeps reading their deals for the same window, unless you disable
the account in a way the token check notices (`token_version`, or a per-request DB lookup).

---

## Checkpoint answers (short)

1. So it can be tested exhaustively and read as the policy. Handlers must first load the facts
   it needs (the record's owner).
2. So adding an `Action` forces a decision for managers (E0004) instead of silently denying.
3. Pagination stays correct, counts don't leak, and you don't load everyone's rows.
4. 403 confirms existence, which enables enumeration. 403 is right when the caller can already
   see the record (rep reassigning own deal) or when existence isn't secret (companies).
5. That ordering *is* the 403/404 rule. Checking the action first would 403 on invisible deals.
6. So a refused rep learns nothing (not even whether the id exists), and no work is wasted.
7. At their next login, up to 15 minutes later, because the role is a claim in the signed token.
8. `/search`, `/history?subject=deal:N`, `/activities` and `/notes` filtered by a deal subject, and maybe `/pipeline`.

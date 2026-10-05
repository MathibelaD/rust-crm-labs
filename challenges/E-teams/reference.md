# Challenge E — Reference design

> Read this **after** you've finished. It's *one* reasonable design, not the answer. If yours
> differs and passes the acceptance tests, compare the trade-offs rather than switching.
>
> Everything below was built and tested against Postgres while this challenge was written: the
> policy unit tests and eight of the API acceptance tests passed. It isn't a full drop-in: handler bodies
> that are just "authorize, call db, map to DTO" are summarised.

---

## 1. The shape of the solution

```text
token ──▶ AuthUser {id, role}                     (Lab 35, stale for ≤15 min, no DB)
              │ + users.team_id  (one PK lookup)
              ▼
          Viewer {id, role, team}                 (new extractor, fresh every request)
              │
   ┌──────────┴───────────────────────┐
   │ lists                            │ single records
   ▼                                  ▼
deal_scope(&viewer) -> DealScope      deals::db::get_with_owner(id) -> (Deal, Owner{id, team})
   │ (pure)                           │
   ▼                                  ▼
SQL WHERE built from the enum         can(&viewer, action, Some(owner))   (pure)
                                      404 if !ViewDeal, 403 if !action
```

The two key decisions:

1. **Role from the token, team from the database.** The requirement "membership changes apply
   on the next request" rules out a `team` claim. Roles stay in the token (Lab 36 behaviour,
   documented as stale). Teams cost one indexed lookup per policy-relevant request.
2. **The policy stays pure; its inputs get richer.** `Option<UserId>` becomes `Option<Owner>`,
   and `AuthUser` becomes `Viewer`. Handlers gather the facts, and `can` decides.

---

## 2. Schema

```sql
CREATE TABLE teams (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT NOT NULL CHECK (btrim(name) <> ''),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- "Sales EMEA" and "sales emea" are the same team.
CREATE UNIQUE INDEX teams_name_lower_key ON teams (lower(name));

-- Nullable: existing users simply have no team. No reset needed this time.
ALTER TABLE users ADD COLUMN team_id BIGINT REFERENCES teams(id);  -- default NO ACTION
CREATE INDEX users_team_id_idx ON users (team_id);
```

**Reasoning**

- **Expression index** for case-insensitive uniqueness. The `CHECK (btrim(name) <> '')` backs up
  the handler's validation for anyone writing SQL by hand.
- **Nullable `team_id`**: adding a nullable column without a default doesn't rewrite or
  invalidate existing rows, so the migration runs on your existing dev DB. Lab 35 needed
  a reset because `NOT NULL` had no correct value for old rows. Here `NULL` *is* the correct
  value: "not in a team yet".
- **`NO ACTION` rather than `RESTRICT`**: both block deleting a team that has members. But they
  report different SQLSTATEs (`23503` vs `23001`), and only `23503` is what
  `DatabaseError::is_foreign_key_violation()` checks for. With `RESTRICT`, the reference build
  returned **500** instead of 409. With the default, the mapping below works.
- **No `deals.team_id`**: a deal's team is derived from its owner's *current* team. Copying it
  onto deals would need updating every time someone changes team, and that copy would drift.

---

## 3. Domain types

```rust
// src/teams/model.rs
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type)]
#[sqlx(transparent)]
pub struct TeamId(pub i64);

pub struct Team { pub id: TeamId, pub name: String }

// src/users/model.rs: User gains
pub team_id: Option<TeamId>,

// src/errors.rs: CrmError gains (both mapped to 409 "conflict")
#[error("a team named {0} already exists")]
DuplicateTeam(String),
#[error("team {} still has members", .0.0)]
TeamHasMembers(TeamId),
```

`User` gaining a field breaks every `User { .. }` literal (test helpers, the JWT unit tests)
and every `SELECT` list in `users::db`. Let the compiler walk you through them.

---

## 4. The policy

```rust
// src/auth/policy.rs
/// Who is asking, with the facts the policy needs. Built once per request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Viewer { pub id: UserId, pub role: Role, pub team: Option<TeamId> }

/// The user a record belongs to (a deal's owner, or a reassignment target).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Owner { pub id: UserId, pub team: Option<TeamId> }

impl Viewer {
    /// A manager's scope: themselves plus the members of their team.
    fn manages(&self, owner: Owner) -> bool {
        owner.id == self.id || (self.team.is_some() && owner.team == self.team)
    }
}

pub fn can(viewer: &Viewer, action: Action, owner: Option<Owner>) -> bool {
    use Action::*;
    match (viewer.role, action) {
        (Role::Admin, _) => true,

        (Role::Manager, ViewDeal | EditDeal | ReassignDeal) => {
            owner.is_some_and(|o| viewer.manages(o))
        }
        (Role::Manager, DeleteCompany) => true,
        (Role::Manager, ViewAllDeals | ManageUsers) => false,

        (Role::SalesRep, ViewDeal | EditDeal) => owner.is_some_and(|o| o.id == viewer.id),
        (Role::SalesRep, ReassignDeal | ViewAllDeals | DeleteCompany | ManageUsers) => false,
    }
}

/// Which deals a list query may return for this viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DealScope { All, Team { me: UserId, team: TeamId }, Own(UserId) }

pub fn deal_scope(viewer: &Viewer) -> DealScope {
    match (viewer.role, viewer.team) {
        (Role::Admin, _) => DealScope::All,
        (Role::Manager, Some(team)) => DealScope::Team { me: viewer.id, team },
        (Role::Manager, None) | (Role::SalesRep, _) => DealScope::Own(viewer.id),
    }
}
```

**Reasoning**

- **`self.team.is_some() && owner.team == self.team`**: without the `is_some()`, a teamless
  manager would "manage" every teamless user, because `None == None` is `true`. This is the
  subtle bug in this challenge, and the table test has a row for it.
- **`Option::is_some_and`** reads like the rule: "there is an owner, and I manage them". A missing
  owner stays deny-by-default.
- **`deal_scope` is a second pure function** with its own exhaustive `match`. Lists and single
  records now share one definition of "scope" (`manages` and `DealScope` agree by construction:
  same team, or me).
- **`ViewAllDeals` is now admin-only.** That's the Lab 36 rule that changed, and it was caught by
  the four Lab 36 API tests that failed after the change, not by the compiler. Exhaustiveness
  catches *missing* decisions. Tests catch *changed* ones.

### Unit tests (table-driven, as in Lab 36)

```rust
#[rustfmt::skip]
let table = [
    // viewer team  action        owner                  allowed
    (Some(T1), ViewDeal,      owned_by(2, Some(T1)), true),   // teammate
    (Some(T1), ViewDeal,      owned_by(2, Some(T2)), false),  // other team
    (Some(T1), ViewDeal,      owned_by(2, None),     false),  // teamless owner
    (Some(T1), ViewDeal,      owned_by(1, None),     true),   // own deal
    (None,     ViewDeal,      owned_by(2, None),     false),  // None == None is NOT a team
    (None,     ViewDeal,      owned_by(1, None),     true),
    (Some(T1), ReassignDeal,  owned_by(2, Some(T1)), true),
    (Some(T1), ReassignDeal,  owned_by(2, Some(T2)), false),
    (Some(T1), EditDeal,      None,                  false),
    (Some(T1), ViewAllDeals,  None,                  false),
    (Some(T1), DeleteCompany, None,                  true),
    (Some(T1), ManageUsers,   None,                  false),
];
for (team, action, owner, expected) in table {
    assert_eq!(can(&viewer(Manager, team), action, owner), expected, "{team:?} {action:?} {owner:?}");
}
```

---

## 5. The `Viewer` extractor

```rust
// src/auth/viewer.rs
/// `AuthUser` (from the token) + the caller's team (from the database, *now*).
impl FromRequestParts<AppState> for Viewer {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let user = AuthUser::from_request_parts(parts, state).await?;
        let team = users::db::team_of(&state.pool, user.id).await?;
        Ok(Viewer { id: user.id, role: user.role, team })
    }
}

// src/users/db.rs
pub async fn team_of(db: impl PgExecutor<'_>, id: UserId) -> Result<Option<TeamId>, CrmError> {
    let team = sqlx::query_scalar!("SELECT team_id FROM users WHERE id = $1", id.0)
        .fetch_optional(db)
        .await?
        .flatten();
    Ok(team.map(TeamId))
}
```

- An extractor calling another extractor's `from_request_parts` is ordinary trait-method use,
  and `AuthUser`'s extensions cache means the token is still verified only once per request.
- **`.flatten()`**: `fetch_optional` gives `Option<row>`, and the column is nullable, so the macro
  gives `Option<Option<i64>>`. "No such user" and "user without team" both become `None`.
- A handler can't forget to load the team, because it can't get a `Viewer` any other way. (A
  `From<AuthUser> for Viewer` with `team: None` would be a tempting shortcut, and a silent
  downgrade for managers. The reference deliberately doesn't have one.)
- **Deleted users** still have valid tokens for ≤15 minutes, and `team_of` returns `None` for
  them, so they keep only "own" scope. Turning that into a 401 would mean making `team_of`
  distinguish "no row" from "no team", a reasonable extension.

---

## 6. Queries

```rust
// src/deals/db.rs
/// One deal plus the facts about its owner the policy needs.
pub async fn get_with_owner(db: impl PgExecutor<'_>, id: DealId) -> Result<(Deal, Owner), CrmError>
//   SELECT d.id, d.company_id, d.title, d.value_cents, d.stage, d.owner_id, u.team_id
//   FROM deals d JOIN users u ON u.id = d.owner_id WHERE d.id = $1

pub async fn list(db: impl PgExecutor<'_>, scope: DealScope) -> Result<Vec<Deal>, CrmError> {
    let (all, own, team) = match scope {
        DealScope::All => (true, None, None),
        DealScope::Team { me, team } => (false, Some(me.0), Some(team.0)),
        DealScope::Own(me) => (false, Some(me.0), None),
    };
    let rows = sqlx::query_as!(
        DealRow,
        "SELECT d.id, d.company_id, d.title, d.value_cents, d.stage, d.owner_id
         FROM deals d JOIN users u ON u.id = d.owner_id
         WHERE $1::BOOLEAN OR d.owner_id = $2 OR u.team_id = $3
         ORDER BY d.id",
        all, own, team,
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(Deal::try_from).collect::<Result<Vec<_>, _>>()?)
}
```

- **One static query, three behaviours.** `x = NULL` is never true, so unused parameters drop
  out. Postgres plans `OR`s like this reasonably at CRM scale. If `EXPLAIN ANALYZE` (Lab 32) shows a
  problem with 100k deals, switch to a `QueryBuilder` that only emits the needed branch.
- `list` takes `DealScope`, not `Viewer`: the repository still doesn't know about roles. It
  executes a scope that someone else decided. `DealScope` replaces Lab 36's `DealFilter`, so
  `deals::db::search` (secured in Lab 36 Your Turn 5) takes a `DealScope` too and gets the same
  join and `WHERE`, and Lab 36's `http::deals::deal_scope(&AuthUser) -> DealFilter` helper is
  replaced by `policy::deal_scope(&viewer)`. The repository test that calls
  `deals::db::list(&pool, &DealFilter::default())` becomes `deals::db::list(&pool, DealScope::All)`.
- **Team deletion → 409** via `is_foreign_key_violation()` on the `DELETE`, mirroring how
  Lab 31 maps unique violations. Duplicate names → `is_unique_violation()` → `DuplicateTeam`.
- **`list_with_counts`** uses `LEFT JOIN users ... GROUP BY t.id` with `COUNT(u.id) AS "members!"`.
  The `!` tells SQLx the count is never NULL. One query instead of one count per team (Lab 32's N+1 lesson).

---

## 7. Handlers: what changed

```rust
async fn load_deal_for(state: &AppState, viewer: &Viewer, id: DealId, action: Action)
    -> Result<Deal, ApiError>
{
    let (deal, owner) = deals::db::get_with_owner(&state.pool, id).await?;
    if !policy::can(viewer, Action::ViewDeal, Some(owner)) {
        return Err(CrmError::NotFound { entity: "deal", id: id.0 }.into());
    }
    policy::authorize(viewer, action, Some(owner))?;
    Ok(deal)
}

async fn reassign_deal(viewer: Viewer, State(state): State<AppState>, AppPath(id): AppPath<i64>,
                       AppJson(req): AppJson<ReassignDealRequest>) -> Result<Json<DealResponse>, ApiError> {
    // 1. the deal: 404 if invisible, 403 if visible but not reassignable
    let deal = load_deal_for(&state, &viewer, DealId(id), Action::ReassignDeal).await?;
    // 2. the target: must exist (422) and be inside the viewer's scope (403)
    let target = match users::db::get(&state.pool, UserId(req.owner_id)).await {
        Ok(user) => Owner { id: user.id, team: user.team_id },
        Err(CrmError::NotFound { .. }) => return Err(/* 422 on owner_id, as in Lab 36 */),
        Err(e) => return Err(e.into()),
    };
    policy::authorize(&viewer, Action::ReassignDeal, Some(target))?;
    let deal = deals::db::set_owner(&state.pool, deal.id, target.id).await?;
    Ok(Json(DealResponse::from(&deal)))
}
```

- **Why is a target outside the team a 403 and not a 404?** The *deal* is visible to the
  manager, so nothing about it leaks. What a 403 reveals is that the target user exists, and
  in a company CRM, colleagues' existence usually isn't the sensitive fact. "You may not assign
  to that person" is the honest, actionable answer. If your user directory is confidential,
  422 "no such user in your team" (same answer for unknown and out-of-team ids) is a defensible
  alternative. Write down which one you chose and why.
- `create_deal` keeps `AuthUser` (it only needs the id), so it saves the extra query.
- `GET /teams/mine` uses `viewer.team.ok_or(NotFound)` and then two queries (team, members).
- Admin endpoints: `authorize(&viewer, Action::ManageUsers, None)?` first, as in Lab 36.
  `PUT /admin/users/{id}/team` checks the team exists (404) before `UPDATE users SET team_id = $2 ... RETURNING`.

---

## 8. Tests

The reference used a `World` fixture built through the real API (admin, manager Meg + rep Alice
in Team A, rep Bob in Team B). Each test is then one or two requests. The one most worth
studying:

```rust
#[sqlx::test]
async fn moving_a_rep_out_of_the_team_takes_effect_immediately(pool: PgPool) {
    let w = world(pool).await;
    let alices = create_deal(&w.app, &w.alice).await;
    assert_eq!(send_authed(&w.app, &w.meg, get(&format!("/deals/{alices}"))).await.0, StatusCode::OK);
    assert_eq!(join(&w.app, &w.admin, w.alice_id, None).await, StatusCode::OK);
    // same manager token, no re-login
    assert_eq!(send_authed(&w.app, &w.meg, get(&format!("/deals/{alices}"))).await.0, StatusCode::NOT_FOUND);
}
```

Compare it with Lab 36's `role_change_applies_from_the_next_login`. Together the two tests
document exactly which facts are fresh (team) and which can be stale for up to 15 minutes (role),
which a reader of the code would otherwise have to work out from the extractor implementations.

---

## 9. Trade-offs you might have chosen differently

| Choice here | Alternative | When the alternative wins |
|---|---|---|
| Team read per request | `team` claim in the JWT | Membership rarely changes and an extra query per request matters |
| Scope as an enum → SQL params | `QueryBuilder` per scope | Big tables where the `OR` plan is poor |
| Derived deal team (via owner) | `deals.team_id` column | Deals should stay with a team when the owner moves (e.g. commission rules) |
| 403 for out-of-team target | 422 / 404 | Your user directory is confidential |
| Teamless manager = own only | Teamless manager = no deals, or = all deals | Org policy says so. It's a business decision, so make it explicit |

# Challenge E — Hints

Use these in order, and only after a genuine attempt. Each tier gives away more.

---

## 1. Schema

<details><summary>Tier 1: direction</summary>

Two schema changes: a new table, and a new column on an existing one. Ask yourself which of
them can be `NOT NULL`, and what that means for the rows already in `users`.

</details>

<details><summary>Tier 2: design</summary>

- "Unique ignoring case" isn't a column constraint. It's a **unique index on an expression**.
- A nullable `ADD COLUMN` without a default is a metadata-only change for existing rows (they
  simply hold `NULL`), which is why there's no reset this time. Compare with Lab 35's `NOT NULL owner_id`.
- Rejecting the deletion of a team with members is the foreign key's job. Pick the `ON DELETE`
  behaviour deliberately.

</details>

<details><summary>Tier 3: near-solution</summary>

```sql
CREATE TABLE teams (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT NOT NULL CHECK (btrim(name) <> ''),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX teams_name_lower_key ON teams (lower(name));
ALTER TABLE users ADD COLUMN team_id BIGINT REFERENCES teams(id);
CREATE INDEX users_team_id_idx ON users (team_id);
```

**Watch out**: `ON DELETE RESTRICT` and the default `NO ACTION` both block the delete, but
they raise **different SQLSTATEs**. `NO ACTION` raises `23503` (`foreign_key_violation`),
which `sqlx`'s `is_foreign_key_violation()` recognises. `RESTRICT` raises `23001`
(`restrict_violation`), which it doesn't, so your 409 turns into a 500. (This was found while
building the reference solution.)

</details>

---

## 2. Growing the policy

<details><summary>Tier 1: direction</summary>

`can(user, action, owner: Option<UserId>)` doesn't have enough information any more. To
decide "is this deal's owner in my team?" the policy needs *the caller's team* and *the
owner's team*. Both are facts the handler can load. Neither requires the policy to be async.

</details>

<details><summary>Tier 2: design</summary>

Replace the two inputs with slightly richer value types:

- the caller: id, role **and team** (one struct, built once per request)
- the record's owner: id **and team** (one small struct, `Copy`)

Then a manager's rule becomes a one-line helper: "owner is me, or we share a (non-null) team".
Be careful with `None == None`: two users *without* a team are **not** teammates.

For reassignment, two owners are involved: the deal's current owner and the new one. You can
check the same action against both: "may I reassign *from* this person?" and "may I reassign
*to* this person?". The first failing check decides between 404 and 403.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
pub struct Viewer { pub id: UserId, pub role: Role, pub team: Option<TeamId> }
pub struct Owner  { pub id: UserId, pub team: Option<TeamId> }

impl Viewer {
    fn manages(&self, owner: Owner) -> bool {
        owner.id == self.id || (self.team.is_some() && owner.team == self.team)
    }
}

// in can():
(Role::Manager, ViewDeal | EditDeal | ReassignDeal) => owner.is_some_and(|o| viewer.manages(o)),
(Role::Manager, DeleteCompany) => true,
(Role::Manager, ViewAllDeals | ManageUsers) => false,
```

Notice `ViewAllDeals` moved to `false` for managers. That's the Lab 36 rule that changed, and the
compiler won't tell you about it, but your tests will.

</details>

---

## 3. Where does the caller's team come from?

<details><summary>Tier 1: direction</summary>

Requirement 1 says membership changes must apply on the *next request*. What does that rule
out, given what you learned about JWTs in Lab 35?

</details>

<details><summary>Tier 2: design</summary>

Putting `team` in the token would make it stale for up to 15 minutes, which breaks the
requirement. So the team has to be read from the database per request: one indexed primary-key
lookup. Where should that read live so that no handler can forget it? Think about how
`AuthUser` made authentication impossible to forget.

</details>

<details><summary>Tier 3: near-solution</summary>

A second extractor that builds on the first:

```rust
impl FromRequestParts<AppState> for Viewer {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let user = AuthUser::from_request_parts(parts, state).await?;
        let team = users::db::team_of(&state.pool, user.id).await?;
        Ok(Viewer { id: user.id, role: user.role, team })
    }
}
```

Handlers that make policy decisions take `Viewer` instead of `AuthUser`. Handlers that only
need the id (creating a deal) can keep `AuthUser` and skip the query.

</details>

---

## 4. Listing deals in one query

<details><summary>Tier 1: direction</summary>

Lab 36 described "which deals" as an `Option<UserId>`. There are now three shapes of answer:
*everything*, *me plus my team*, *only me*. That's an enum.

</details>

<details><summary>Tier 2: design</summary>

Compute the scope in Rust (pure, testable), then translate it into SQL parameters. The deal's
team is its owner's team, so the query needs `deals JOIN users ON users.id = deals.owner_id`
and a `WHERE` that can express all three shapes with **one static query**. Boolean and nullable
parameters (`$1::BOOLEAN OR ...`, `= $2` where `$2` may be `NULL`) let you do that without
string building.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
pub enum DealScope { All, Team { me: UserId, team: TeamId }, Own(UserId) }

let (all, own, team) = match scope {
    DealScope::All => (true, None, None),
    DealScope::Team { me, team } => (false, Some(me.0), Some(team.0)),
    DealScope::Own(me) => (false, Some(me.0), None),
};
```

```sql
SELECT d.id, d.company_id, d.title, d.value_cents, d.stage, d.owner_id
FROM deals d JOIN users u ON u.id = d.owner_id
WHERE $1::BOOLEAN OR d.owner_id = $2 OR u.team_id = $3
ORDER BY d.id
```

`x = NULL` is `NULL` (not true) in SQL, so an unused `$2`/`$3` simply never matches.

</details>

---

## 5. Single deals: loading the owner's team

<details><summary>Tier 1: direction</summary>

`load_deal_for` used `deal.owner_id`. The policy now needs the owner's *team* too. Avoid a
second round trip.

</details>

<details><summary>Tier 2: design</summary>

Fetch the deal *and* its owner's `team_id` in one query (a join), and return them together:
`(Deal, Owner)`. The `Deal` domain type doesn't need a team field. The owner's team is a fact for
the policy, not part of the deal.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
pub async fn get_with_owner(db: impl PgExecutor<'_>, id: DealId) -> Result<(Deal, Owner), CrmError>
// SELECT d.*, u.team_id FROM deals d JOIN users u ON u.id = d.owner_id WHERE d.id = $1
```

Reassign: `load_deal_for(.., ReassignDeal)` (404/403 about the deal) → load the target user
(422 if unknown) → `authorize(&viewer, ReassignDeal, Some(target_owner))?` (403 if outside scope) → `set_owner`.

</details>

---

## 6. Tests

<details><summary>Tier 1: direction</summary>

Nearly every API test needs the same cast: an admin, a manager in team A, a rep in team A, a
rep in team B, and two teams. Build it once.

</details>

<details><summary>Tier 2: design</summary>

A `world(pool) -> World` helper that returns a struct with the router, every token and the
interesting ids keeps each test down to "create a deal, make one request, assert". Membership
is set through the real admin API, so the setup itself tests the team endpoints.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
struct World { app: Router, admin: String, meg: String, alice: String, bob: String,
               alice_id: i64, bob_id: i64, team_a: i64 }

async fn world(pool: PgPool) -> World {
    let app = app(pool.clone());
    let admin = login_as(&app, &pool, "root@example.com", Role::Admin).await;
    let meg = login_as(&app, &pool, "meg@example.com", Role::Manager).await;
    let alice = login_as(&app, &pool, "alice@example.com", Role::SalesRep).await;
    let bob = login_as(&app, &pool, "bob@example.com", Role::SalesRep).await;
    // create Team A and Team B via POST /admin/teams,
    // PUT /admin/users/{id}/team: meg + alice → A, bob → B
    // ...
}
```

The four Lab 36 tests that assumed "managers see everything"
(`manager_sees_all_deals`, `manager_can_move_a_reps_deal`,
`manager_reassigns_and_the_new_owner_sees_the_deal`, `reassigning_to_an_unknown_user_is_422`)
fail after your change. Put the manager and the reps in one team in those tests, and add a
comment explaining why.

One more test relied on it: Lab 36 Your Turn 5 made `keyset_pages_walk_the_whole_history_once`
(`tests/api/activities.rs`) log in as a manager to reach fixture deal 1, which belongs to the
teamless fixture user. A teamless manager now only sees their own deals, so that test needs an
**admin** token (`login_as(.., Role::Admin)`) instead.

</details>

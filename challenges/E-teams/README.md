# 🏁 Challenge E — Teams

> **After:** Lab 36 · **Covers:** Phases 9–10 (Postgres, migrations, authentication, authorization)
> **Time:** ~5–8 hours · **Your repo before:** tag `lab-36`

There are no step-by-step instructions here. You get a specification, constraints, the
authorization rules and the tests that must pass. How you get there is up to you.
[`hints.md`](hints.md) has tiered hints if you get stuck. [`reference.md`](reference.md) shows
one possible design: read it **after** you've finished, and compare.

> Work on a branch: `git switch -c challenge-e`. Later labs don't depend on this challenge,
> and they're written against the Lab 36 rules. Merging it is fine. Nothing in Labs 37–41 conflicts
> with teams, but where a later lab says "managers see all deals", your version says "managers see their
> team's deals". That's your design now, so keep it consistent.

---

## The problem

Lab 36's managers see **every** deal in the company. That was fine with one sales team. Now the
company has grown: a *Team EMEA* and a *Team Americas*, each with its own manager. Managers
should run **their** team and not see the other team's pipeline.

## Feature specification

### Teams

- An **admin** can create teams, list them (with member counts), and delete empty teams.
- An **admin** can put a user into a team, move them to another team, or remove them from any team.
- A user belongs to **at most one** team. Users without a team are allowed (new hires, admins).
- Any logged-in user can see **their own** team and its members.

### Team-scoped management

- A **manager's scope** is: *themselves* + *every member of their team*.
- Managers can view, edit and reassign deals **owned by someone in their scope**, and only
  reassign them **to someone in their scope**.
- A manager **without a team** has a scope of just themselves.
- Admins and sales reps behave exactly as in Lab 36.

### API contract

| Method & path | Body | Success | Notes |
|---|---|---|---|
| `POST /admin/teams` | `{ "name": "Team EMEA" }` | **201** `{ "id", "name", "member_count": 0 }` | 422 blank name · 409 duplicate name (case-insensitive) |
| `GET /admin/teams` | — | **200** `[{ "id", "name", "member_count" }]` ordered by id | |
| `DELETE /admin/teams/{id}` | — | **204** | 409 if the team has members · 404 unknown |
| `PUT /admin/users/{id}/team` | `{ "team_id": 3 }` or `{ "team_id": null }` | **200** `UserResponse` | 404 unknown user or team |
| `GET /teams/mine` | — | **200** `{ "id", "name", "members": [UserResponse…] }` members ordered by name | 404 if the caller has no team |

`UserResponse` gains `"team_id": <id or null>`. All error bodies use the Lab 28 JSON shape.

## Authorization rules (binding)

| Action | Admin | Manager **in team T** | Manager **without team** | Sales rep |
|---|---|---|---|---|
| List deals (`GET /deals`) | all | deals owned by anyone in T, plus own | own | own |
| View / edit one deal | ✅ | owner ∈ T or self, otherwise **404** | own, otherwise **404** | own, otherwise **404** |
| Reassign a deal | ✅ any → any | deal owner ∈ scope (else **404**) **and** new owner ∈ scope (else **403**) | own deals, to self | ❌ own **403**, others **404** |
| Delete a company | ✅ | ✅ | ✅ | ❌ 403 |
| Manage users & teams (`/admin/*`) | ✅ | ❌ 403 | ❌ 403 | ❌ 403 |
| `GET /teams/mine` | ✅ | ✅ | 404 | ✅ / 404 |

Plus these behavioural requirements:

1. **Membership changes take effect on the next request**, with no re-login. If an admin moves a
   rep out of a manager's team, that manager's very next request no longer sees the rep's
   deals. (Roles may stay stale for the token lifetime, as in Lab 36. Team membership may not.)
2. Every endpoint that returns deal data (`/deals`, `/deals/{id}`, `/search`, and the
   subject-based endpoints you secured in Lab 36 Your Turn 5) applies the **same** scope.
3. "Cannot see" is always **404**, identical to a missing record. "Can see but cannot do" is **403**.

## Data-model constraints

- New table `teams` with an identity `BIGINT` primary key, a non-blank `name`, `created_at`.
- Team names are unique **ignoring case**, enforced **by the database**.
- `users.team_id` is a **nullable** foreign key to `teams`. Deleting a team that still has members
  must be rejected **by the database** (and surface as 409, not 500).
- `users.team_id` is indexed. Listing a manager's team deals must not scan all users.
- The migration must apply cleanly to your **existing** dev database. No `sqlx database reset`
  this time. Think about why that's possible here when it wasn't in Lab 35.
- No denormalised copy of the team on `deals`. A deal's team is its owner's *current* team.

## Constraints

- `can` (or whatever replaces it) stays a **pure, synchronous** function: no database, no
  `async`, no HTTP types. Handlers load facts and pass them in.
- The `match` in the policy stays **exhaustive without a catch-all** for non-admin roles.
- List scoping happens **in SQL**, in **one query** per list (no N+1, no Rust-side filtering).
- No new crates.
- `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test` pass,
  `.sqlx/` is up to date, and CI is green.

## Acceptance tests

Unit tests (policy, no database):

- [ ] A table-driven test covering, for managers: teammate's deal, other team's deal, teamless
      owner, own deal, manager-without-team, every non-deal action
- [ ] The scope a list query gets for: admin, manager with team, manager without team, sales rep

API tests (`#[sqlx::test]`), each in its own test:

- [ ] `manager_lists_only_team_deals`
- [ ] `manager_can_view_and_move_a_teammates_deal`
- [ ] `manager_gets_404_for_other_team_deal` (body identical in shape to a missing deal)
- [ ] `manager_reassigns_within_team`: 200, and the new owner sees it
- [ ] `manager_cannot_reassign_into_another_team`: 403
- [ ] `manager_cannot_reassign_another_teams_deal`: 404
- [ ] `manager_without_team_sees_only_own_deals`
- [ ] `moving_a_rep_out_of_the_team_takes_effect_immediately`: same manager token, before → 200, after → 404
- [ ] `admin_still_sees_everything`
- [ ] `rep_rules_unchanged` (at least: rep sees only own deals; rep can't reassign)
- [ ] `team_names_are_unique_ignoring_case`: 409
- [ ] `blank_team_name_is_422`
- [ ] `deleting_a_team_with_members_is_409` and `deleting_an_empty_team_is_204`
- [ ] `assigning_to_an_unknown_team_is_404`
- [ ] `my_team_lists_members` and `my_team_without_team_is_404`
- [ ] `managers_and_reps_cannot_manage_teams`: 403 on every `/admin/teams*` and `/admin/users/{id}/team`
- [ ] `search_respects_team_scope`: a manager's `/search` doesn't return other teams' deals
- [ ] The Lab 36 tests whose rule **changed** are updated, not deleted, and each has a comment saying what changed

## Concepts you're expected to use

- **Schema design**: nullable foreign keys, expression (functional) unique indexes, `FK` + `ON DELETE` behaviour, indexing for a query you know you'll run
- **Mapping database errors to domain errors** (which SQLSTATE does your delete raise?)
- **Policy design**: growing a pure policy function's inputs without making it impure, and keeping the exhaustive `match`
- **Request-scoped facts**: what comes from the token (fast, possibly stale) vs the database (fresh, one query)
- **Custom extractors** composing other extractors (`FromRequestParts`)
- **SQL scoping**: joins or subqueries driven by a Rust enum, nullable/boolean parameters, one query per list
- **403 vs 404** reasoning in a new situation (two records involved in one request)
- **Table-driven tests** and API tests for every rule
- **Migrations against existing data**, and the expand-only change that needs no reset

## Definition of done

- [ ] All acceptance tests pass locally and in CI
- [ ] The policy fits on one screen and reads like the rules table above
- [ ] You can explain, for each endpoint, where the team rule is enforced (SQL or Rust) and why
- [ ] A short "Teams" section in your CRM's README explains the rules and the stale-role/fresh-team trade-off
- [ ] Commit, tag `challenge-e`, push

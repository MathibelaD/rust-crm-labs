# Lab 35 — Solutions

> 🔴 One good answer per task, with the reasoning. Different code that meets the acceptance
> criteria (and that you can explain) is just as correct.

---

## Your Turn 1 — `bearer_token`

```rust
use axum::http::{HeaderMap, header::AUTHORIZATION};

pub fn bearer_token(headers: &HeaderMap) -> Result<&str, AuthError> {
    let value = headers.get(AUTHORIZATION).ok_or(AuthError::MissingToken)?;
    let value = value.to_str().map_err(|_| AuthError::InvalidToken)?;
    let (scheme, token) = value.split_once(' ').ok_or(AuthError::InvalidToken)?;
    let token = token.trim();
    if !scheme.eq_ignore_ascii_case("bearer") || token.is_empty() {
        return Err(AuthError::InvalidToken);
    }
    Ok(token)
}
```

**Reasoning**

- **Lifetimes, without writing any.** The signature is `fn(&HeaderMap) -> Result<&str, _>`.
  With a single reference input, elision (Lab 10) ties the output to it:
  `fn<'a>(&'a HeaderMap) -> Result<&'a str, _>`. Every step (`get`, `to_str`, `split_once`,
  `trim`) returns a sub-slice of the same header bytes, so no `String` is ever allocated, and the
  borrow checker guarantees the token can't outlive the request headers it points into.
- **Shadowing `value`** (Lab 02) twice: `&HeaderValue` → `&str`. Each line narrows the type.
  Nothing needs the old binding.
- **`split_once(' ')`**, not `strip_prefix("Bearer ")`: it handles every letter case of the scheme
  (`bearer`, `BEARER`), which HTTP requires (auth schemes are case-insensitive).
- **Two different errors.** No header at all (`MissingToken`) is the normal state for an
  anonymous client. A header that's there but malformed (`InvalidToken`) is a broken client. Both are
  401, but the messages help whoever is debugging the client.

### Tests (every row of the table)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn headers(value: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Some(v) = value {
            headers.insert(AUTHORIZATION, HeaderValue::from_str(v).unwrap());
        }
        headers
    }

    #[test]
    fn extracts_the_token() {
        assert_eq!(bearer_token(&headers(Some("Bearer abc.def.ghi"))).unwrap(), "abc.def.ghi");
    }

    #[test]
    fn scheme_is_case_insensitive() {
        assert_eq!(bearer_token(&headers(Some("bearer abc"))).unwrap(), "abc");
    }

    #[test]
    fn missing_header_is_missing_token() {
        assert!(matches!(bearer_token(&headers(None)), Err(AuthError::MissingToken)));
    }

    #[test]
    fn other_schemes_and_empty_tokens_are_invalid() {
        for value in ["Basic dXNlcjpwYXNz", "Bearer", "Bearer   ", "abc.def.ghi"] {
            assert!(
                matches!(bearer_token(&headers(Some(value))), Err(AuthError::InvalidToken)),
                "{value}"
            );
        }
    }

    #[test]
    fn non_visible_ascii_is_invalid() {
        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, HeaderValue::from_bytes(b"Bearer \xff").unwrap());
        assert!(matches!(bearer_token(&headers), Err(AuthError::InvalidToken)));
    }
}
```

The loop with a message argument (`"{value}"`) is a small table-driven test: when it fails,
the message tells you *which* row. Lab 36 builds a whole policy test this way.

> Note `"Bearer   "`: `HeaderValue::from_str` accepts trailing spaces in tests, but real HTTP
> parsers strip surrounding whitespace from header values. The `trim()` covers both.

---

## Your Turn 2 — `verify_in_background`

```rust
/// Runs `verify_password` on Tokio's blocking thread pool.
///
/// Both arguments are owned: `spawn_blocking` requires a `'static` closure, because the
/// blocking thread may keep running after the awaiting future is dropped. A `&str` hash
/// borrowed from the caller can't be proven to live that long (E0521).
pub async fn verify_in_background(password: SecretString, hash: String) -> Result<bool, AuthError> {
    tokio::task::spawn_blocking(move || verify_password(&password, &hash)).await?
}
```

Same structure as `hash_in_background`: `.await` gives
`Result<Result<bool, AuthError>, JoinError>`, `?` converts the outer error through
`#[from] JoinError`, and the inner `Result` is the return value. The `move` closure owns both
values. When the thread finishes, the `SecretString` is dropped (and zeroed) there.

Why does login pass `String` and not `&str` in the first place? `find_by_email` returned an
owned `String` inside the tuple, and `dummy_hash()` returns an owned clone. Both arms give the
`match` the same type, so `hash` can be moved into the thread on either path.

---

## Your Turn 3 — owners for leads and activities

The code below is the Lab 31–33 code with the owner added. If your modules differ, apply the
*same deltas* to yours.

### Leads

```rust
// src/leads/db.rs: LeadRow gains `owner_id: i64`, TryFrom<LeadRow> sets
// `owner_id: UserId(row.owner_id)`, every SELECT/RETURNING lists owner_id,
// and insert gains the owner:
pub async fn insert(
    db: impl PgExecutor<'_>,
    new: &NewLead,
    owner_id: UserId,
) -> Result<Lead, CrmError> {
    let row = sqlx::query_as!(
        LeadRow,
        "INSERT INTO leads (name, email, company_name, source, notes, owner_id)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, name, email, company_name, source, status, notes, owner_id",
        new.name,
        new.email.as_str(),
        new.company_name,
        new.source.to_string(),
        new.notes,
        owner_id.0,
    )
    .fetch_one(db)
    .await?;
    Ok(row.try_into()?)
}
```

- `Lead` (the saved record) gains `pub owner_id: UserId`, and `LeadResponse::from(&Lead)` copies
  `owner_id.0`.
- `NewLead` and `LeadBuilder` (Lab 31) **don't** change. Like `notes::db::insert`, the owner is
  a separate argument to `insert`: it isn't something the client described, it's who is asking.
  That keeps the builder's job (validate what the client sent) separate from the server's job
  (decide the owner).
- Handler: one new parameter, one new argument.

```rust
async fn create_lead(
    user: AuthUser,
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateLeadRequest>,
) -> Result<(StatusCode, Json<LeadResponse>), ApiError> {
    // ... email parsing and the NewLead::builder(..) chain exactly as in Lab 31 ...
    let new = builder.build().map_err(CrmError::from)?;
    let lead = leads::db::insert(&state.pool, &new, user.id).await?;
    Ok((StatusCode::CREATED, Json(LeadResponse::from(&lead))))
}
```

### Conversion: the deal belongs to the lead's owner

```rust
// src/leads/model.rs
pub struct ConversionPlan {
    pub company: NewCompany,
    pub contact_name: String,
    pub contact_email: Email,
    pub deal: Option<NewDealInput>,
    /// Who will own the records the conversion creates: the lead's owner.
    pub owner_id: UserId, // NEW
}

// at the end of Lead::plan_conversion:
Ok(ConversionPlan {
    company: NewCompany { name: company_name, website: None },
    contact_name: self.name.clone(),
    contact_email: self.email.clone(),
    deal,
    owner_id: self.owner_id, // NEW
})
```

```rust
// src/leads/service.rs: convert_lead, the deal insert
let deal_id = match plan.deal {
    Some(input) => {
        let new = input.for_company(company.id, plan.owner_id);
        let deal = deals::db::insert(&mut *tx, &new).await?;
        Some(deal.id)
    }
    None => None,
};
```

Nothing else in `convert_lead` changes: `leads::db::get_for_update` already returns a `Lead`
built from `LeadRow`, and its `SELECT ... FOR UPDATE` now lists `owner_id`. The `lead()` helper
in the `leads/model.rs` unit tests gets `owner_id: UserId(1)`.

A repository test pins the rule down (`tests/db/leads.rs`, `deals` imported as
`rust_crm::deals::{self, NewDealInput}`):

```rust
#[sqlx::test(fixtures(path = "../fixtures", scripts("users", "leads")))]
async fn converted_deal_belongs_to_the_leads_owner(pool: PgPool) {
    let summary = leads::service::convert_lead(&pool, LeadId(1), pilot())
        .await
        .unwrap();
    let deal = deals::db::get(&pool, summary.deal_id.unwrap()).await.unwrap();
    let lead = leads::db::get(&pool, LeadId(1)).await.unwrap();
    assert_eq!(deal.owner_id, lead.owner_id);
}
```

**Why the lead's owner and not the caller?** "A rep's lead becomes that rep's opportunity" is how
sales teams think about it: commission and pipeline reporting follow the owner. If a manager
clicks "convert" for a rep, the deal should still land in the rep's pipeline. Both are valid
business rules. The point is that it's a *decision*, written down and tested, not an accident of
which variable was in scope.

**Why does the owner go into `ConversionPlan`?** `plan_conversion` is the pure, unit-tested
place (Lab 31) that decides *everything* a conversion will create. If `convert_lead` read
`lead.owner_id` itself, the rule "the lead's owner owns the deal" would live in the
transaction code, where no unit test sees it. In the plan, a two-line unit test can check it.

### Activities

```rust
// src/activities/model.rs: Activity gains
pub created_by: UserId,

// src/activities/db.rs: ActivityRow gains `created_by: i64`, TryFrom sets
// `created_by: UserId(row.created_by)`, every SELECT/RETURNING on activities lists created_by
// (insert, list_for_subject, both queries in page_for_subject), and insert gains the author:
pub async fn insert(
    pool: &PgPool,
    new: &NewActivity,
    created_by: UserId,
) -> Result<Activity, CrmError>
// SQL: INSERT INTO activities (subject_type, subject_id, kind, details, summary, occurred_at, created_by)
//      VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ..., created_by
```

```rust
async fn log_activity(
    user: AuthUser,
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateActivityRequest>,
) -> Result<(StatusCode, Json<ActivityResponse>), ApiError> {
    let input = ActivityInput::validate(req, Utc::now())?;
    let new = NewActivity {
        subject: input.subject,
        kind: input.kind,
        summary: input.summary,
        occurred_at: input.occurred_at,
    };
    let activity = activities::db::insert(&state.pool, &new, user.id).await?;
    Ok((StatusCode::CREATED, Json(ActivityResponse::from(&activity))))
}
```

(All of the above, with Steps 10–12, ran green against Postgres on top of the Lab 33 code:
`cargo clippy --all-targets -- -D warnings` clean, and every unit, `tests/api` and `tests/db` test passing.)

### The "no owner in DTOs" rule

Check with grep: `grep -rn "owner_id\|created_by" src/http/` should only show **response**
structs and `user.id` arguments, never a field on a `*Request` struct. If a request DTO had
`owner_id`, any rep could create deals in a colleague's name, or (worse, after Lab 36) hide deals
from them.

---

## Your Turn 4 — authentication API tests

```rust
use crate::helpers::{
    TEST_PASSWORD, app, error_code, get, post_json, register_and_login, send, send_authed,
};
use axum::http::StatusCode;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test]
async fn login_returns_a_bearer_token(pool: PgPool) {
    let app = app(pool);
    register_and_login(&app, "ada@example.com").await;
    let (status, body) = send(
        &app,
        post_json("/auth/login", json!({"email": "ada@example.com", "password": TEST_PASSWORD})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["token_type"], "Bearer");
    assert_eq!(body["expires_in"], 900);
}

#[sqlx::test]
async fn me_returns_the_logged_in_user(pool: PgPool) {
    let app = app(pool);
    let token = register_and_login(&app, "ada@example.com").await;
    let (status, body) = send_authed(&app, &token, get("/me")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["email"], "ada@example.com");
}

#[sqlx::test]
async fn protected_routes_require_a_token(pool: PgPool) {
    let app = app(pool);
    for uri in ["/me", "/deals", "/companies/1"] {
        let response = tower::ServiceExt::oneshot(app.clone(), get(uri)).await.unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{uri}");
        assert_eq!(response.headers()["www-authenticate"], "Bearer");
    }
}

#[sqlx::test]
async fn garbage_token_is_401(pool: PgPool) {
    let app = app(pool);
    let (status, body) = send_authed(&app, "not.a.jwt", get("/me")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&body), "unauthorized");
}

#[sqlx::test]
async fn created_deal_is_owned_by_the_caller(pool: PgPool) {
    let app = app(pool);
    let token = register_and_login(&app, "rep@example.com").await;
    let (_, company) =
        send_authed(&app, &token, post_json("/companies", json!({"name": "Acme"}))).await;
    let (status, deal) = send_authed(
        &app,
        &token,
        post_json(
            "/deals",
            json!({"company_id": company["id"], "title": "Big", "value_cents": 100}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (_, me) = send_authed(&app, &token, get("/me")).await;
    assert_eq!(deal["owner_id"], me["id"]);
}
```

`created_lead_is_owned_by_the_caller` is the same shape against `POST /leads` with your lead
request body.

**Notes**

- **`/companies/1` doesn't exist**, and we still expect 401, not 404. Authentication comes before
  routing to the handler, so an anonymous caller learns nothing about which ids exist.
  (Contrast with an unknown *path*, which gives 404 because of `route_layer`.)
- **`tower::ServiceExt::oneshot(app.clone(), ...)`**: `oneshot` consumes the service, so we
  clone the `Router` (cheap: it's `Arc`s inside). Calling it as a fully qualified function avoids
  needing `use tower::ServiceExt` in this file.
- **`deal["owner_id"] == me["id"]`** compares two `serde_json::Value`s, so no number conversions are needed.

All of these passed against a real Postgres while this lab was written (with `sqlx::test`
creating a fresh database per test).

---

## Experiment answers

**1. Signed, not encrypted.** Anyone holding the token can read `sub`, `role`, `iat`, `exp`.
Adding the email would reveal it to anything that logs or intercepts the header: proxies,
browser extensions, error trackers. Phone numbers or anything personal: no. Claims should be the
*minimum* the server needs to authorise a request without a lookup.

**2. Forged admin.** `verify` returns `Err(AuthError::InvalidToken)`. The signature covers
header **and** payload, so changing a single byte of the payload invalidates it. To forge a token
the attacker needs `JWT_SECRET`, which is why it's random, at least 32 bytes, kept out of git, and
(Lab 38) loaded as a secret.

**3. Timing.** Without the dummy hash, unknown emails answer ~15× faster, which an attacker can
easily measure. The first unknown-email login with the dummy hash in place is slower because
`LazyLock` computes the dummy hash *on first use*: that request pays for two Argon2 operations
(create + verify). Later ones reuse it.

**4. Expiry.** `-30` seconds works and `-120` doesn't. `Validation` allows 60 seconds of
`leeway` for clock differences between the server that issued the token and the one that
checks it. Lower it (`validation.leeway = 5`) if all your servers have good clocks.

**5. Forgetting the extractor.** Still 401, from the `require_auth` middleware. If the route
had been put in `public_routes()` by mistake, *nothing* would protect it, and the handler would
happily create a deal owned by user 1. That's why handlers that need the user must take
`AuthUser`: the type then makes the dependency impossible to drop silently (it's part of the
signature, and `owner_id: user.id` won't compile without it).

---

## Checkpoint answers (short)

1. Until `exp`, up to 15 minutes. Close the window with refresh tokens + short access tokens
   (server state for refresh), a `jti` denylist, or a `token_version` check (a lookup per request).
2. Header, claims, signature. The HMAC signature, keyed with the server secret, stops tampering.
   The payload is only base64, so anyone can read it.
3. A token's header is attacker-controlled. Trusting it enables `alg: none` and algorithm-confusion attacks.
4. Different messages → user enumeration: fixed by one message. Different timings: fixed by
   always running exactly one Argon2 verify (dummy hash for unknown users).
5. `async fn handler(user: AuthUser, ...)`: the handler can only run with a verified user. On
   failure, the rejection (`ApiError::Unauthorized` → 401 JSON + `WWW-Authenticate`) is the response.
6. The middleware is a safety net for handlers that don't ask for the user. The extractor is
   the source of truth for handlers that use it, and its type guarantees they can't run unauthenticated.
7. Existing rows would get `NULL`, which violates `NOT NULL`. In production: add nullable →
   backfill with a business-decided owner → `SET NOT NULL` once all code writes it.
8. Ownership drives authorization (Lab 36). If the client chose it, they could assign work to
   anyone, or create records outside the access rules.

# Lab 35 — Authentication

> **Phase:** 10 — Users, Authentication & Authorization · **Builds on:** Lab 34 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-34` · **After:** tag `lab-35`

## 🎯 Goal
Let users **log in** and make every CRM route require it. `POST /auth/login` checks the password
and returns a short-lived **JWT access token**. A custom `AuthUser` extractor turns that token back into
"who is calling" for every request, and new deals, leads, activities and notes record **which user**
created them.

## 🧠 What You'll Learn
- **Authentication vs authorization**, and the honest trade-offs between **JWTs and server sessions**
  (especially *revocation*), and why a **15-minute** token lifetime is the compromise we choose
- **JWT anatomy**: header, claims (`sub`, `role`, `iat`, `exp`), signature. *Signed, not encrypted.*
- `jsonwebtoken` 11: keys, `encode`/`decode`, `Validation`, and choosing its crypto backend
- **`FromRequestParts`**: writing your own Axum extractor. This is where the traits from Lab 15 pay off.
- **401 Unauthorized** done properly: one JSON error shape plus a `WWW-Authenticate: Bearer` header
- **Login without leaking**: the same response for "unknown email" and "wrong password", and a
  **dummy hash** so both take the same time
- `axum::middleware::from_fn_with_state` + `route_layer` vs an extractor: **two layers of defence**,
  and which one is the source of truth
- `std::sync::LazyLock` for a value computed once, on first use
- Adding `NOT NULL` foreign keys to tables that already have data: why the migration fails on
  your dev DB, `sqlx database reset`, and what you'd do in production instead
- Test helpers for authenticated requests: `register_and_login`, `send_authed`

## 🔨 What We're Building

```text
POST /auth/register   (Lab 34)        public
POST /auth/login      → { access_token, token_type: "Bearer", expires_in: 900 }   public
GET  /health                                                                         public
GET  /me              → the logged-in user                                           🔒
everything else       (companies, contacts, deals, leads, activities, notes, ...)    🔒
```

🔒 = needs `Authorization: Bearer <token>`, otherwise **401**.

New and changed files:

```text
src/auth/mod.rs          AuthError grows; re-exports
src/auth/jwt.rs          Claims, JwtKeys, ACCESS_TOKEN_TTL, issue, verify
src/auth/extractor.rs    AuthUser + impl FromRequestParts<AppState>, bearer_token()
src/auth/middleware.rs   require_auth
src/auth/password.rs     + dummy_hash(), verify_in_background()
src/http/state.rs        AppState { pool, jwt }
src/http/error.rs        ApiError::Unauthorized (401 + WWW-Authenticate)
src/http/auth.rs         login, me; routes split into public/protected
src/http/mod.rs          protected router with route_layer
src/main.rs              reads JWT_SECRET, fails fast
migrations/<ts>_add_owners.sql   deals.owner_id, leads.owner_id, activities.created_by, notes.created_by
tests/api/helpers.rs     app() with a test secret, register_and_login, login, with_token, send_authed
tests/fixtures/users.sql a fixture owner; deals.sql and leads.sql gain owner_id
```

> Written against **jsonwebtoken 11**, axum 0.8, sqlx 0.9, chrono 0.4.

---

## Step 1 — Authentication, sessions and tokens: the honest version

**Authentication** answers *"who are you?"*. **Authorization** answers *"are you allowed to do
this?"* (Lab 36). This lab is only the first one.

After a successful login, the server has to recognise the same user on every following request
without asking for the password again. There are two mainstream ways to do that:

| | **Server-side session** | **Stateless JWT access token** |
|---|---|---|
| What the client holds | a random session id (usually a cookie) | a signed token containing the user id, role and expiry |
| What the server stores | a `sessions` row: id → user, expiry | **nothing** |
| Per request | look the session up (DB/Redis) | verify an HMAC signature (microseconds, no I/O) |
| **Logout / revoke** | delete the row → **instantly** invalid | **can't.** The token stays valid until `exp`. |
| Role change / user disabled | effective on the next request | effective when the token **expires** |
| Scaling across servers | all servers need the session store | any server with the secret can verify |
| Typical use | server-rendered web apps, browsers | APIs, mobile apps, service-to-service |

Don't let anyone tell you JWTs are simply "better". The big cost is **revocation**: a JWT is a
signed promise that's valid until it expires, and the server has no list to cross things off.
If a token is stolen, or you fire someone, or demote an admin, every token already issued keeps
working until its `exp`.

The usual ways to live with that:

1. **Short lifetimes.** If a token lives 15 minutes, the damage window is 15 minutes. ← **what we do**
2. **Refresh tokens**: a long-lived, *server-stored, revocable* token used only to get new
   short access tokens. That's sessions again for the refresh step, which is the point. (A good
   extension after this phase. We don't build it, so users log in again every 15 minutes.)
3. **A denylist** of revoked token ids (`jti`) checked on every request. That's a lookup per
   request again, so most of the "stateless" benefit is gone.
4. **A `token_version` column** on users, copied into the token, compared on each request. Same trade-off as 3.

The roadmap chose short-lived JWTs (15 minutes), and that's a reasonable choice for an API. Just
know what you're giving up. You'll **see** the role-change delay happen in a Lab 36 test.

---

## Step 2 — JWT anatomy

Here's a real token produced by this lab's code:

```text
eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOjcsInJvbGUiOiJzYWxlc19yZXAiLCJpYXQiOjE3OTEyMTA3MzgsImV4cCI6MTc5MTIxMTYzOH0.Jy24c9mKrKIo2A8KQBK6DaWmzXlk7R7Ha_NgIO6CY40
└──────────── header ───────────────┘ └─────────────────────────────── claims (payload) ────────────────────────────────┘ └──────────── signature ────────────────┘
```

Three base64url segments separated by dots. Decode the first two (they're just base64):

```json
{"typ":"JWT","alg":"HS256"}
{"sub":7,"role":"sales_rep","iat":1791210738,"exp":1791211638}
```

| Claim | Meaning | Ours |
|---|---|---|
| `sub` | **subject**: who the token is about | the user id |
| `role` | a custom claim | `admin` / `manager` / `sales_rep` |
| `iat` | **issued at**, seconds since 1970 | now |
| `exp` | **expires**, seconds since 1970 | now + 900 |

The third segment is `HMAC-SHA256(secret, header + "." + payload)`. Anyone can **read** the
payload. Only someone with the **secret** can produce a valid signature for it. So:

- ✅ a client can't change `"role":"sales_rep"` to `"admin"`, because the signature would no longer match
- ❌ **never put secrets in claims** (no emails you'd mind leaking, no internal data). JWTs are signed, **not encrypted**.

> 💡 RFC 7519 says `sub` should be a string. Using a number is common and `jsonwebtoken` accepts
> it (it only validates `sub` if you ask it to). If you integrate with a third-party identity
> provider later, you'd switch to `sub: String`.

---

## Step 3 — Add `jsonwebtoken` and a secret

```bash
cargo add jsonwebtoken --features rust_crypto
```

**Why the feature?** Since version 10, `jsonwebtoken` doesn't pick a cryptography library for
you. You must enable **exactly one** backend:

| Feature | Library | Notes |
|---|---|---|
| `rust_crypto` | RustCrypto (pure Rust) | builds anywhere `cargo` does. **We use this.** |
| `aws_lc_rs` | AWS-LC (C/assembly) | faster, FIPS options, needs a C compiler + CMake to build |

Without either, the crate compiles, but signing fails at runtime with a "no crypto provider"
error. So if you ever see that, check this feature first.

### `JWT_SECRET`

HS256 is only as strong as its secret. Generate 48 random bytes:

```bash
openssl rand -base64 48
```

Add it to `.env` (gitignored since Lab 30) and a **placeholder** to `.env.example` (committed):

```bash
# .env
JWT_SECRET=<paste the openssl output here>
```

```bash
# .env.example
JWT_SECRET=change-me-to-at-least-32-random-bytes-openssl-rand-base64-48
```

Rules we'll enforce in code: the variable must exist, and it must be **at least 32 bytes**. The
server refuses to start otherwise. A server that starts with a weak or missing secret is worse
than one that doesn't start: it *looks* fine.

---

## Step 4 — `AuthError` grows

> 🟢 **FOLLOW ALONG**: `src/auth/mod.rs` (replace)

```rust
mod extractor;
pub mod jwt;
mod middleware;
pub mod password;

pub use extractor::{AuthUser, bearer_token};
pub use jwt::{Claims, JwtKeys};
pub use middleware::require_auth;

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("password hashing failed: {0}")]
    Hash(#[from] argon2::password_hash::Error),
    #[error("background task failed")]
    Task(#[from] tokio::task::JoinError),
    #[error("invalid email or password")]
    InvalidCredentials,
    #[error("missing bearer token")]
    MissingToken,
    #[error("invalid access token")]
    InvalidToken,
    #[error("access token expired")]
    TokenExpired,
    #[error("JWT secret must be at least 32 bytes")]
    WeakSecret,
    #[error("could not create token")]
    TokenCreation(#[source] jsonwebtoken::errors::Error),
}
```

Create empty `src/auth/jwt.rs`, `src/auth/extractor.rs` and `src/auth/middleware.rs` for now, and
put `//` in front of the three `pub use` lines that point at them: `pub use jwt::…` comes back in
Step 5, `pub use extractor::…` in Step 8, `pub use middleware::…` in Step 9. With that, `cargo check` passes. It will after **every** step
of this lab: each step that refers to a Your Turn function gives you a `todo!()` stub to use until
you write it. (Expect "never used" warnings for the new handlers until Step 9 routes them.)

Two groups of variants:

```text
the CLIENT's problem → 401         InvalidCredentials, MissingToken, InvalidToken, TokenExpired
OUR problem          → 500         Hash, Task, WeakSecret, TokenCreation
```

---

## Step 5 — `src/auth/jwt.rs`

> 🟢 **FOLLOW ALONG**: `src/auth/jwt.rs`

```rust
use super::AuthError;
use crate::users::{Role, User};
use chrono::{TimeDelta, Utc};
use jsonwebtoken::{
    Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode, errors::ErrorKind,
};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};

/// Access tokens live for 15 minutes.
pub const ACCESS_TOKEN_TTL: TimeDelta = TimeDelta::minutes(15);

const MIN_SECRET_BYTES: usize = 32;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Claims {
    /// Subject: the user's id.
    pub sub: i64,
    pub role: Role,
    /// Issued at (seconds since the Unix epoch).
    pub iat: i64,
    /// Expires at (seconds since the Unix epoch).
    pub exp: i64,
}

#[derive(Clone)]
pub struct JwtKeys {
    encoding: EncodingKey,
    decoding: DecodingKey,
}

impl JwtKeys {
    pub fn new(secret: &SecretString) -> Result<Self, AuthError> {
        let bytes = secret.expose_secret().as_bytes();
        if bytes.len() < MIN_SECRET_BYTES {
            return Err(AuthError::WeakSecret);
        }
        Ok(JwtKeys {
            encoding: EncodingKey::from_secret(bytes),
            decoding: DecodingKey::from_secret(bytes),
        })
    }
}

pub fn issue(user: &User, keys: &JwtKeys, ttl: TimeDelta) -> Result<String, AuthError> {
    let now = Utc::now();
    let claims = Claims {
        sub: user.id.0,
        role: user.role,
        iat: now.timestamp(),
        exp: (now + ttl).timestamp(),
    };
    encode(&Header::new(Algorithm::HS256), &claims, &keys.encoding)
        .map_err(AuthError::TokenCreation)
}

pub fn verify(token: &str, keys: &JwtKeys) -> Result<Claims, AuthError> {
    let validation = Validation::new(Algorithm::HS256);
    match decode::<Claims>(token, &keys.decoding, &validation) {
        Ok(data) => Ok(data.claims),
        Err(e) if matches!(e.kind(), ErrorKind::ExpiredSignature) => Err(AuthError::TokenExpired),
        Err(_) => Err(AuthError::InvalidToken),
    }
}
```

Then remove the `//` from `pub use jwt::{Claims, JwtKeys};` in `src/auth/mod.rs`.

The important lines:

- **`pub const ACCESS_TOKEN_TTL: TimeDelta = TimeDelta::minutes(15);`**. `TimeDelta::minutes` is a
  `const fn`, so this is computed at compile time. (`chrono::Duration` is an alias of `TimeDelta`.)
  Lab 38 moves this into configuration.
- **`JwtKeys` is `Clone` but not `Debug`.** `EncodingKey` deliberately doesn't implement `Debug`,
  so key material can't be printed. That also means `AppState` can't derive `Debug`, which is fine.
- **`JwtKeys::new` validates the secret** and returns `Result`. The rule "a key is at least 32
  bytes" lives in the type that uses the key, so no caller can skip it.
- **`Validation::new(Algorithm::HS256)` pins the algorithm.** A token's header *claims* an
  algorithm. Historically, libraries that trusted the header were fooled by `"alg":"none"` or by
  RSA/HMAC confusion. We accept HS256 and nothing else.
- **`exp` is checked by `decode`** (`Validation` requires and validates it by default) with a
  default **leeway of 60 seconds** for clock skew between machines. A token is rejected once
  `exp` is more than a minute in the past.
- **`verify` collapses errors**: expired → `TokenExpired`, anything else (bad signature, garbage,
  wrong algorithm, missing claim) → `InvalidToken`. The client doesn't need to know *how* a forged
  token was wrong. It's useful for a legitimate client to know its token *expired*, so it can log in again.

> 🟢 **FOLLOW ALONG**: unit tests at the bottom of `jwt.rs`. These run without a database.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::contacts::Email;
    use crate::users::UserId;

    const SECRET: &str = "an-example-secret-that-is-32-bytes-or-more";

    fn keys(secret: &str) -> JwtKeys {
        JwtKeys::new(&SecretString::from(secret)).unwrap()
    }

    fn user(role: Role) -> User {
        User {
            id: UserId(7),
            email: Email::parse("rep@example.com").unwrap(),
            name: "Rep".into(),
            role,
            created_at: Utc::now(),
        }
    }

    #[test]
    fn issued_token_verifies_and_carries_claims() {
        let keys = keys(SECRET);
        let token = issue(&user(Role::Manager), &keys, ACCESS_TOKEN_TTL).unwrap();
        let claims = verify(&token, &keys).unwrap();
        assert_eq!(claims.sub, 7);
        assert_eq!(claims.role, Role::Manager);
        assert_eq!(claims.exp - claims.iat, 15 * 60);
    }

    #[test]
    fn expired_token_is_rejected() {
        let keys = keys(SECRET);
        // A negative lifetime: expired 5 minutes ago (well past the 60 s leeway).
        let token = issue(&user(Role::SalesRep), &keys, TimeDelta::minutes(-5)).unwrap();
        assert!(matches!(verify(&token, &keys), Err(AuthError::TokenExpired)));
    }

    #[test]
    fn token_signed_with_another_secret_is_rejected() {
        let token = issue(&user(Role::Admin), &keys(SECRET), ACCESS_TOKEN_TTL).unwrap();
        let other = keys("a-completely-different-secret-of-32-bytes!");
        assert!(matches!(verify(&token, &other), Err(AuthError::InvalidToken)));
    }

    #[test]
    fn short_secret_is_refused() {
        let result = JwtKeys::new(&SecretString::from("too-short"));
        assert!(matches!(result, Err(AuthError::WeakSecret)));
    }
}
```

The negative TTL trick is the Lab 20 "pass time in" lesson in a different form: rather than
waiting 15 minutes in a test, we create a token that's *already* expired.

```bash
cargo test --lib jwt
```

```text
running 4 tests
test auth::jwt::tests::short_secret_is_refused ... ok
test auth::jwt::tests::token_signed_with_another_secret_is_rejected ... ok
test auth::jwt::tests::expired_token_is_rejected ... ok
test auth::jwt::tests::issued_token_verifies_and_carries_claims ... ok
```

---

## Step 6 — `AppState` gets the keys, `main` fails fast

> 🟢 **FOLLOW ALONG**: `src/http/state.rs`

```rust
use crate::auth::JwtKeys;
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub jwt: JwtKeys,
}
```

`AppState` must be `Clone` (Lab 27: Axum clones it for each request). `PgPool` is an `Arc`
inside. `JwtKeys` clones a few dozen bytes of key material, which is cheap enough. If you want
it to be a pointer copy too, wrap it: `jwt: Arc<JwtKeys>`.

> 🟢 **FOLLOW ALONG**: `src/main.rs`: where you build the state

```rust
// `anyhow::Context` is already imported. Add:
use rust_crm::auth::JwtKeys;
use secrecy::SecretString;

// ... after dotenvy and DATABASE_URL:
let jwt_secret = SecretString::from(
    std::env::var("JWT_SECRET").context("JWT_SECRET must be set (at least 32 bytes)")?,
);
let jwt = JwtKeys::new(&jwt_secret).context("invalid JWT_SECRET")?;
// ...
let state = AppState { pool, jwt };
```

`.context(...)` (Lab 22) turns "environment variable not found" into a message that says
*which* variable and *why it matters*. `main` returns `anyhow::Result`, so the server exits with
that message and a non-zero code. Try it: `JWT_SECRET=short cargo run`.

Your tests construct `AppState` too. Update `helpers::app` now so the suite compiles:

> 🟢 **FOLLOW ALONG**: `tests/api/helpers.rs` (it already imports `rust_crm::http::{AppState, router}` from Lab 33)

```rust
use rust_crm::auth::JwtKeys;
use secrecy::SecretString;

const TEST_JWT_SECRET: &str = "test-only-secret-that-is-at-least-32-bytes";

pub fn app(pool: PgPool) -> Router {
    let jwt = JwtKeys::new(&SecretString::from(TEST_JWT_SECRET)).unwrap();
    router(AppState { pool, jwt })
}
```

---

## Step 7 — `POST /auth/login`, without leaking anything

### What can a login endpoint leak?

1. **Which emails have accounts.** If "unknown email" gives *"no such user"* and a wrong
   password gives *"wrong password"*, anyone can test a list of emails against your CRM. That's
   called **user enumeration**, and for a CRM it reveals who your staff are. → **One message for both.**
2. **The same thing, through timing.** Even with identical messages, look at the work done:

```text
unknown email:   SELECT … → no row → return 401                              ~1 ms
wrong password:  SELECT … → row → Argon2 verify (~15–20 ms) → return 401     ~16 ms
```

An attacker with a stopwatch can still tell them apart. → **Always run exactly one Argon2
verification.** When there's no user, verify against a **dummy hash** with the same parameters
and throw the answer away.

### The dummy hash, computed once

> 🟢 **FOLLOW ALONG**: `src/auth/password.rs`

```rust
use std::sync::LazyLock;

/// A real Argon2id hash of a password nobody knows, computed once.
/// Login verifies against it when the email is unknown, so both paths cost the same.
static DUMMY_HASH: LazyLock<String> = LazyLock::new(|| {
    hash_password(&SecretString::from("dummy password used to equalise login timing"))
        .expect("hashing a constant password cannot fail")
});

pub fn dummy_hash() -> String {
    DUMMY_HASH.clone()
}
```

- **`static` + `LazyLock`** (std since Rust 1.80): a global initialised **on first access**, exactly
  once, even if many threads hit it at the same moment. A plain `static` can't run
  `hash_password` (statics need compile-time values). `LazyLock` runs the closure at runtime.
- It must be a **real** hash made by the same `hash_password`, so verifying against it costs
  exactly what verifying a real user costs. A hard-coded string with *different* parameters
  would take a different amount of time and bring the leak back.
- **`expect` is acceptable here** (Lab 12): hashing a constant can only fail if the system is out
  of memory, and then nothing works anyway.
- `dummy_hash()` returns an owned `String` because the next function moves the hash into a
  blocking thread.

### The handler

> 🟢 **FOLLOW ALONG**: `src/http/auth.rs`: add the DTOs and the handler

```rust
use crate::auth::{AuthError, jwt};

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: SecretString,
}

#[derive(Debug, Serialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_in: i64,
}

async fn login(
    State(state): State<AppState>,
    AppJson(req): AppJson<LoginRequest>,
) -> Result<Json<TokenResponse>, ApiError> {
    // 1. Look the user up. A malformed email is treated exactly like an unknown one.
    let found = match Email::parse(&req.email) {
        Ok(email) => users::db::find_by_email(&state.pool, &email).await?,
        Err(_) => None,
    };

    // 2. ALWAYS run one Argon2 verification, so both paths take the same time.
    let (user, hash) = match found {
        Some((user, hash)) => (Some(user), hash),
        None => (None, password::dummy_hash()),
    };
    let password_ok = password::verify_in_background(req.password, hash).await?;

    // 3. One error for every failure.
    let user = match user {
        Some(user) if password_ok => user,
        _ => return Err(AuthError::InvalidCredentials.into()),
    };

    let access_token = jwt::issue(&user, &state.jwt, jwt::ACCESS_TOKEN_TTL)?;
    Ok(Json(TokenResponse {
        access_token,
        token_type: "Bearer",
        expires_in: jwt::ACCESS_TOKEN_TTL.num_seconds(),
    }))
}
```

Walk through the types:

- `found: Option<(User, String)>`, the tuple you designed in Lab 34.
- After step 2, `user: Option<User>` and `hash: String`: **the code path is now the same no matter
  what.** There's a single `verify_in_background` call site.
- In step 3, `Some(user) if password_ok` is the *only* success. "No user" and "wrong password" both
  fall into `_`. The pattern match itself guarantees there's no third way out.
- **No `Validation` error for a malformed email.** Registration reports bad input precisely. Login
  doesn't, because "your email is malformed" vs "invalid credentials" is a small leak of its own.

`password::verify_in_background(password: SecretString, hash: String) -> Result<bool, AuthError>`
is **Your Turn 2**. It's the `verify_password` twin of Lab 34's `hash_in_background`. Until you
write it, stub it in `src/auth/password.rs` so the project compiles:

```rust
pub async fn verify_in_background(_password: SecretString, _hash: String) -> Result<bool, AuthError> {
    todo!("Your Turn 2")
}
```

`login` isn't routed until Step 9, so nothing can reach the `todo!()` yet. Do Your Turn 2 before ▶️ Run It.

### The 401 response

`AuthError::InvalidCredentials.into()` needs `ApiError` to know about 401s. Add a variant and
split the `From<AuthError>` mapping you wrote in Lab 34:

> 🟢 **FOLLOW ALONG**: `src/http/error.rs`

```rust
#[derive(Debug)]
pub enum ApiError {
    Domain(CrmError),
    Validation(Vec<FieldError>),
    BadRequest(String),
    /// No or invalid credentials (401). The message is fixed text, never client input.
    Unauthorized(&'static str),
    Internal(anyhow::Error),
}

impl From<AuthError> for ApiError {
    fn from(e: AuthError) -> Self {
        match e {
            AuthError::InvalidCredentials => ApiError::Unauthorized("invalid email or password"),
            AuthError::MissingToken => ApiError::Unauthorized("missing bearer token"),
            AuthError::InvalidToken => ApiError::Unauthorized("invalid access token"),
            AuthError::TokenExpired => ApiError::Unauthorized("access token expired"),
            AuthError::Hash(_)
            | AuthError::Task(_)
            | AuthError::WeakSecret
            | AuthError::TokenCreation(_) => ApiError::Internal(e.into()),
        }
    }
}
```

**No `_ =>` arm.** When someone adds an `AuthError` variant next year, this `match` stops
compiling until they decide whether it's a 401 or a 500. A wildcard would quietly pick for them.

`cargo check` now shows you the two `match`es in Lab 28's `IntoResponse` that need an arm (E0004).
That's the same exhaustiveness check that made you map `CrmError::Database` in Lab 30:

> 🟢 **FOLLOW ALONG**: in `status_and_code`

```rust
            ApiError::Unauthorized(_) => (StatusCode::UNAUTHORIZED, "unauthorized"),
```

> 🟢 **FOLLOW ALONG**: in `into_response`'s `match self`

```rust
            ApiError::Unauthorized(message) => (message.to_string(), Vec::new()),
```

A 401 must also carry a `WWW-Authenticate` header (RFC 9110: it tells the client *which*
scheme to use). Change the last line of `into_response` from returning the response directly to:

> 🟢 **FOLLOW ALONG**

```rust
use axum::http::{HeaderValue, header};

        let mut response = (status, Json(body)).into_response();
        if status == StatusCode::UNAUTHORIZED {
            response
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        }
        response
```

- `(status, Json(body)).into_response()` is still Lab 28's one place that builds error responses.
  We only add a header to the finished `Response`. `let mut` because `headers_mut()` borrows
  it mutably (Lab 07).
- **`HeaderValue::from_static`** checks the value at compile time and costs nothing at runtime. `from_str`
  would need error handling for a value you know is valid.
- The check is on the **status**, not the variant: `self` was consumed by the `match` above
  (Lab 28 explained why `status_and_code` runs first), but `status` is a `Copy` value we still have.

---

## Step 8 — `AuthUser`: your own extractor

Every extractor you've used (`State`, `Path`, `Query`, `Json`) is just a type that implements
one of two traits:

```rust
// from axum (simplified)
pub trait FromRequestParts<S>: Sized {
    type Rejection: IntoResponse;
    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection>;
}
pub trait FromRequest<S>: Sized { /* same, but consumes the body */ }
```

When you write `async fn handler(Path(id): Path<i64>, AppJson(req): AppJson<X>)`, Axum calls
`Path::from_request_parts`, then `AppJson::from_request`, and if any of them returns `Err`, it
sends the **rejection** as the response and *never calls your handler*. That's Lab 15 traits
plus Lab 16 generics doing all the plumbing. You've already written one extractor: Lab 28's
`#[derive(FromRequest)]` generated a `FromRequest` impl for `AppJson`. This time you write the impl by hand.

So "this handler needs a logged-in user" can be **a parameter type**:

> 🟢 **FOLLOW ALONG**: `src/auth/extractor.rs`

```rust
use super::{AuthError, jwt};
use crate::http::{ApiError, AppState};
use crate::users::{Role, UserId};
use axum::extract::FromRequestParts;
use axum::http::{HeaderMap, request::Parts};

/// The authenticated caller, taken from a verified access token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthUser {
    pub id: UserId,
    pub role: Role,
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        // Already verified earlier in this request (e.g. by `require_auth`)?
        if let Some(user) = parts.extensions.get::<AuthUser>() {
            return Ok(*user);
        }

        let token = bearer_token(&parts.headers)?;
        let claims = jwt::verify(token, &state.jwt)?;
        let user = AuthUser { id: UserId(claims.sub), role: claims.role };

        parts.extensions.insert(user);
        Ok(user)
    }
}
```

Line by line:

- **`FromRequestParts`, not `FromRequest`**: we only need headers, not the body. That's what lets
  `AuthUser` sit *before* `AppJson(...)` in a handler's parameters. (The body extractor must
  always be last, since only one extractor can consume the body.)
- **`impl FromRequestParts<AppState>`**: we implement it for *our* state type, because we need
  `state.jwt`. Axum's own extractors are generic over any `S`. Ours doesn't need to be.
  (The generic version uses `S: Send + Sync, JwtKeys: FromRef<S>`. Nice for libraries,
  unnecessary for an app.)
- **`async fn` in a trait impl** is native Rust (since 1.75). Axum 0.8 dropped the
  `#[async_trait]` macro you'll see in older tutorials.
- **`type Rejection = ApiError`**: a failed extraction becomes *our* 401 JSON with the header,
  through the `From<AuthError>` you just wrote. Each `?` converts `AuthError → ApiError`.
- **`AuthUser` is `Copy`**: two `Copy` fields (`UserId(i64)` and a fieldless enum), 16 bytes.
  Handlers can pass it around by value freely, like an integer.
- **`parts.extensions`** is a per-request type map (`TypeId → value`). We store the verified
  user there, so a second extraction in the *same request* (the middleware in Step 9 *and* the
  handler) verifies the token once. Verification is only microseconds, but the pattern of
  computing a request-scoped value once and caching it in extensions is worth knowing.
- **What it does *not* do: hit the database.** The token says who you are and what your role
  is, and we trust the signature. That's the "stateless" in stateless JWT, and the reason a role
  change waits for token expiry (Step 1).

`bearer_token(&HeaderMap) -> Result<&str, AuthError>` is **Your Turn 1**. Note its lifetime:
the returned `&str` borrows from the header map (elided lifetime, Lab 10), so no allocation is
needed to get the token out. Until you write it, stub it at the bottom of `extractor.rs`:

```rust
pub fn bearer_token(_headers: &HeaderMap) -> Result<&str, AuthError> {
    todo!("Your Turn 1")
}
```

Now the type exists, so bring it into the crate's API: in `src/auth/mod.rs`, remove the `//` from
`pub use extractor::{AuthUser, bearer_token};`.

### `GET /me`

> 🟢 **FOLLOW ALONG**: `src/http/auth.rs`: add `AuthUser` to Step 7's import
> (`use crate::auth::{AuthError, AuthUser, jwt};`), then the handler

```rust
async fn me(user: AuthUser, State(state): State<AppState>) -> Result<Json<UserResponse>, ApiError> {
    let user = users::db::get(&state.pool, user.id).await?;
    Ok(Json(UserResponse::from(&user)))
}
```

The handler is three lines because the extractor did the authentication. If the token is
missing or bad, `me` never runs. `let user = ...` **shadows** the `AuthUser` with the full `User`
from the database (Lab 02 shadowing), which is the right move since we don't need the token
version any more.

---

## Step 9 — Protecting every route: middleware *and* extractor

Adding `user: AuthUser` to every handler protects every handler, **as long as nobody forgets**.
The CRM has dozens of handlers, and the one somebody forgets will be the one that leaks.

So we add a second layer: a **middleware** in front of the whole protected router, which rejects
any request without a valid token *before routing to any handler*.

> 🟢 **FOLLOW ALONG**: `src/auth/middleware.rs`

```rust
use super::AuthUser;
use axum::{extract::Request, middleware::Next, response::Response};

/// Rejects any request without a valid access token, before routing to the handler.
/// The `AuthUser` argument does all the work: if extraction fails, the
/// rejection (401) is returned and `next` is never called.
pub async fn require_auth(_user: AuthUser, request: Request, next: Next) -> Response {
    next.run(request).await
}
```

That's the entire middleware. `axum::middleware::from_fn` accepts an async function whose
arguments are **extractors**, then the `Request`, then `Next`. Since `AuthUser` *is* an
extractor, the middleware gets authentication for free, and on success it stores the user in
the request's extensions, where the handler's own `AuthUser` finds it.

Now split the router. Public routes stay outside. Everything else goes into a `protected` router
with the middleware applied:

> 🟢 **FOLLOW ALONG**: `src/http/auth.rs`: split the routes

```rust
pub fn public_routes() -> Router<AppState> {
    Router::new()
        .route("/auth/register", post(register))
        .route("/auth/login", post(login))
}

pub fn protected_routes() -> Router<AppState> {
    Router::new().route("/me", get(me))
}
```

(Import `routing::{get, post}`. The Lab 34 `routes()` function is gone: `public_routes()` replaces it.)

> 🟢 **FOLLOW ALONG**: `src/http/mod.rs`

```rust
use axum::{Router, middleware};

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .merge(auth::protected_routes())
        .merge(companies::routes())
        .merge(contacts::routes())
        .merge(leads::routes())
        .merge(deals::routes())
        .merge(activities::routes())
        .merge(notes::routes())
        .merge(history::routes())
        .merge(search::routes())
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::auth::require_auth,
        ));

    Router::new()
        .merge(health::routes())
        .merge(auth::public_routes())
        .merge(protected)
        .with_state(state)
}
```

`crate::auth::require_auth` only resolves once it's re-exported: in `src/auth/mod.rs`, remove the
`//` from `pub use middleware::require_auth;` (the last commented line). Every route but
`/health`, `/auth/register` and `/auth/login` now answers 401 without a token. Do Your Turn 1
before you send requests with one.

> 🟡 **EXPERIMENT**: predict first. Replace `from_fn_with_state(state.clone(), crate::auth::require_auth)`
> with `from_fn(crate::auth::require_auth)` and `cargo check`.

```text
error[E0277]: the trait bound `FromFn<fn(_, _, Next) -> _ {require_auth}, (), Route, _>: Service<_>` is not satisfied
   --> src/http/mod.rs:20:22
    |
 20 |         .route_layer(middleware::from_fn(crate::auth::require_auth));
    |          ----------- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ unsatisfied trait bound
    |          |
    |          required by a bound introduced by this call
    |
    = help: the trait `tower_service::Service<axum::http::Request<Body>>` is not implemented for `FromFn<fn(AuthUser, _, Next) -> _ {require_auth}, (), Route, _>`
    = help: the following other types implement trait `tower_service::Service<Request>`:
              axum::middleware::FromFn<F, S, I, (T1, T2)>
              axum::middleware::FromFn<F, S, I, (T1, T2, T3)>
    ...
```

Generic-heavy errors are long, so look for the **one concrete thing**: `FromFn<fn(AuthUser, _, Next) …, (), …>`.
That `()` is the **state type**. `from_fn` gives the middleware's extractors the state `()`,
and `AuthUser` only implements `FromRequestParts<AppState>`, not `FromRequestParts<()>`. So
the generated type doesn't implement `Service`. `from_fn_with_state(state, ...)` supplies the
`AppState` that `AuthUser` needs. Put it back.

> 🟡 **EXPERIMENT**: now drop the `.clone()`: `from_fn_with_state(state, crate::auth::require_auth)`.

```text
error[E0382]: use of moved value: `state`
  --> src/http/mod.rs:31:21
   |
15 | pub fn router(state: AppState) -> Router {
   |               ----- move occurs because `state` has type `AppState`, which does not implement the `Copy` trait
...
23 |             state,
   |             ----- value moved here
...
31 |         .with_state(state)
   |                     ^^^^^ value used here after move
```

**Who owns** `state`? The `router` function. Was it **moved**? Yes, into the middleware layer,
which keeps it for as long as the router lives. `.with_state` then needs its own. Two owners
need two values, and `AppState` is designed to be cheap to clone (Lab 27): two `Arc` bumps and a
small key copy. Here `.clone()` is the correct fix, not a workaround.

### `route_layer` vs `layer`

`route_layer` runs the middleware **only when a route matched**. `layer` runs it for everything
that reaches this router, including requests that will end up as 404.

> 🟡 **EXPERIMENT** (after ▶️ Run It works): change `.route_layer(` to `.layer(` and request a
> path that doesn't exist, with no token: `curl -i localhost:3000/nope`. Verified results:
>
> ```text
> .route_layer(...)   →  404 Not Found
> .layer(...)         →  401 Unauthorized  {"error":{"code":"unauthorized","message":"missing bearer token"}}
> ```
>
> Which is more correct for an unknown path? Which reveals less about your API to an anonymous
> caller? (Both are defensible. We pick `route_layer` so typos give the honest 404.) Put it back.

### Which one is the source of truth?

```text
request ──▶ route matched? ──▶ require_auth (middleware) ──▶ handler(user: AuthUser, ...)
                                   │ no/invalid token → 401        │ reads the cached AuthUser
```

- The **extractor** is the source of truth. A handler that needs the user *asks for it in its
  signature*, and the type guarantees it can't run without one. That's what you'll rely on in Lab 36
  (`can(&user, ...)`).
- The **middleware** is the safety net: a handler that doesn't need the user (say, `list_companies`)
  is *still* protected. Forgetting the parameter doesn't turn into a public endpoint.

Neither replaces the other. Defence in depth means a single mistake isn't enough to cause a breach.

---

## Step 10 — Who owns what: the ownership migration

From now on every deal and lead has an **owner**, and every activity and note records **who
wrote it**. That's the data Lab 36's authorization rules will use.

```bash
sqlx migrate add add_owners
```

> 🟢 **FOLLOW ALONG**: `migrations/<timestamp>_add_owners.sql`

```sql
-- Every deal and lead belongs to a user; every activity and note records who wrote it.
ALTER TABLE deals      ADD COLUMN owner_id   BIGINT NOT NULL REFERENCES users(id);
ALTER TABLE leads      ADD COLUMN owner_id   BIGINT NOT NULL REFERENCES users(id);
ALTER TABLE activities ADD COLUMN created_by BIGINT NOT NULL REFERENCES users(id);
ALTER TABLE notes      ADD COLUMN created_by BIGINT NOT NULL REFERENCES users(id);

-- Postgres does not index foreign keys automatically. Lab 36 filters deals by owner.
CREATE INDEX deals_owner_id_idx ON deals (owner_id);
CREATE INDEX leads_owner_id_idx ON leads (owner_id);
```

> 🟡 **EXPERIMENT**: predict first. Your dev database has deals in it from earlier labs (and maybe
> 100k seeded rows from Lab 32). Run:

```bash
sqlx migrate run
```

```text
error: while executing migration 20261005143916: error returned from database: column "owner_id" of relation "deals" contains null values
```

**Why?** `ADD COLUMN ... NOT NULL` without a `DEFAULT` gives every *existing* row a `NULL`
and then checks the constraint, so it fails. And what default could there be? There's no
"correct" owner for a deal created before users existed. The migration runs inside a
transaction, so nothing was half-applied, and SQLx didn't record it as done.

**In development**, the data is disposable. Throw the database away and rebuild it from the migrations:

```bash
sqlx database reset -y      # drop, create, run every migration from scratch
```

```text
Applied 20261005143132/migrate create companies (1.172334ms)
...
Applied 20261005143916/migrate add owners (1.001458ms)
```

(Your migration timestamps differ. All of them run.) Then re-register a user, and re-run
`scripts/seed.sql` from Lab 32 if you use it. That seed inserts **deals** and **activities**,
so it now needs an owner and an author. Right after `BEGIN;` add

```sql
-- Since Lab 35 every deal needs an owner and every activity an author.
INSERT INTO users (email, name, password_hash)
VALUES ('seed@example.test', 'Seed Owner', 'not-a-real-hash')
ON CONFLICT (email) DO NOTHING;
```

then add `owner_id` to the deals `INSERT` column list and `created_by` to the activities one,
with `(SELECT id FROM users WHERE email = 'seed@example.test')` as the extra `SELECT` value in each.

**In production** you'd never reset. You'd do it in three migrations, with a deploy between them:

```text
1. ADD COLUMN owner_id BIGINT REFERENCES users(id)         -- nullable: succeeds instantly
2. UPDATE deals SET owner_id = <a decided owner> WHERE owner_id IS NULL   -- backfill (maybe in batches)
3. ALTER TABLE deals ALTER COLUMN owner_id SET NOT NULL    -- only after code always sets it
```

That's the **expand → migrate → contract** pattern. The lesson to remember: *"which user owns the
old rows?"* is a **business** question, and a migration can't answer it for you.

> Why `created_by` and not `owner_id` for activities and notes? A deal is *owned*: it can be
> reassigned, and ownership drives access. A note is *authored*: who wrote it never changes.
> Different words for different rules.

---

## Step 11 — Filling in the owner from `AuthUser`

The pattern for every create path: the **handler** takes `user: AuthUser`, and the **domain/DB
layer** takes a `UserId`. The repository never sees HTTP types (the Lab 14 rule: business logic
doesn't know about the interface).

### Deals

> 🟢 **FOLLOW ALONG**: `src/deals/model.rs`

```rust
use crate::users::UserId;

pub struct Deal {
    // ... id, company_id, title, value, stage ...
    pub owner_id: UserId,
}

pub struct NewDeal {
    // ... company_id, title, value ...
    pub owner_id: UserId,
}
```

`cargo check` now lists every place that builds a `Deal` or `NewDeal`, and that list *is* your
to-do list. With the Lab 31–33 code it is:

- **`NewDealInput::for_company`** (the only place a `NewDeal` is built) takes the owner too:

```rust
impl NewDealInput {
    pub fn for_company(self, company_id: CompanyId, owner_id: UserId) -> NewDeal {
        NewDeal {
            company_id,
            title: self.title,
            value: self.value,
            owner_id,
        }
    }
}
```

- **`deals::db`**: `DealRow` gains `owner_id: i64`, every `SELECT`/`RETURNING` list gains
  `owner_id` (in `insert`, `get`, `list`, `move_stage` and `search`), the `INSERT` gains `$4`,
  and `TryFrom<DealRow>` sets `owner_id: UserId(row.owner_id)`. Keep Lab 31's foreign-key
  mapping in `insert`:

```rust
pub async fn insert(db: impl PgExecutor<'_>, new: &NewDeal) -> Result<Deal, CrmError> {
    let row = sqlx::query_as!(
        DealRow,
        "INSERT INTO deals (company_id, title, value_cents, owner_id)
         VALUES ($1, $2, $3, $4)
         RETURNING id, company_id, title, value_cents, stage, owner_id",
        new.company_id.0,
        new.title,
        new.value.cents(),
        new.owner_id.0,
    )
    .fetch_one(db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_foreign_key_violation() => CrmError::NotFound {
            entity: "company",
            id: new.company_id.0,
        },
        other => CrmError::Database(other),
    })?;
    Ok(row.try_into()?)
}
```

  (`owner_id` always comes from a verified token or from an existing lead, so in practice
  the foreign-key violation can only be the company's.)

- **Two unit-test helpers** build a `Deal` literal: the `move_to_rejects_invalid_transition`
  test in `deals/model.rs` and `deal()` in `deals/report.rs`. Give them `owner_id: UserId(1)`.
- **`DealResponse`** gains `pub owner_id: i64`, so clients can see who owns a deal.
- **The create handler** takes the user and passes it to `for_company`:

```rust
async fn create_deal(
    user: AuthUser,
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateDealRequest>,
) -> Result<(StatusCode, Json<DealResponse>), ApiError> {
    let input = NewDealInput {
        title: req.title.trim().to_string(),
        value: Money::from_cents(req.value_cents),
    };
    input.validate().map_err(CrmError::from)?;
    let new = input.for_company(CompanyId(req.company_id), user.id);
    let deal = deals::db::insert(&state.pool, &new).await?;
    Ok((StatusCode::CREATED, Json(DealResponse::from(&deal))))
}
```

  `CreateDealRequest` does **not** get an `owner_id`: a client must never choose who owns
  what they create. The owner comes from the token, as an argument, next to the validated input.

- **Lead conversion** (Lab 31's `leads::service::convert_lead`) also calls
  `input.for_company(company.id)`, so it needs an owner too. The lead's owner should own the deal
  it turns into. `Lead::plan_conversion` is pure (Lab 31): it decides *everything* a conversion
  will create, so the owner belongs in its `ConversionPlan`, copied from the lead. That's part of
  **Your Turn 3**.

### Notes

> 🟢 **FOLLOW ALONG**: `notes::db::insert` takes the author, the handler passes `user.id`

```rust
// src/notes/db.rs: one more parameter, one more column
pub async fn insert(pool: &PgPool, new: &NewNote, created_by: UserId) -> Result<Note, CrmError>
// SQL: INSERT INTO notes (subject_type, subject_id, body, created_by) VALUES ($1, $2, $3, $4) ...
//      (bind created_by.0 as the 4th value)

// src/http/notes.rs
async fn create_note(
    user: AuthUser,
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateNoteRequest>,
) -> Result<(StatusCode, Json<NoteResponse>), ApiError> {
    let new = NewNote {
        subject: parse_subject(&req.subject)?,
        body: req.body,
    };
    let note = notes::db::insert(&state.pool, &new, user.id).await?;
    Ok((StatusCode::CREATED, Json(NoteResponse::from(&note))))
}
```

Whether `Note` (the domain struct) gets a `created_by: UserId` field is up to you. Add it if your
`NoteResponse` should show the author (it's useful in a timeline, and Lab 41 will want it).

**Leads** and **activities** follow exactly the same pattern. That's **Your Turn 3**.

---

## Step 12 — Tests that log in

Every CRM route now returns 401 without a token, so most of your Lab 29–33 API tests just went
red. That's the middleware working. Give the tests a way to log in.

> 🟢 **FOLLOW ALONG**: add to `tests/api/helpers.rs` (next to Lab 29's `send`, `get`, `post_json`, …)

```rust
// extend the existing imports:
use axum::http::{HeaderValue, Request, StatusCode, header};
use serde_json::{Value, json};

pub const TEST_PASSWORD: &str = "correct horse battery staple";

/// Registers `email` with TEST_PASSWORD, logs in, returns the access token.
pub async fn register_and_login(app: &Router, email: &str) -> String {
    let (status, body) = send(
        app,
        post_json(
            "/auth/register",
            json!({ "email": email, "name": email, "password": TEST_PASSWORD }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "register {email}: {body}");
    login(app, email).await
}

pub async fn login(app: &Router, email: &str) -> String {
    let (status, body) = send(
        app,
        post_json("/auth/login", json!({ "email": email, "password": TEST_PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login {email}: {body}");
    body["access_token"].as_str().unwrap().to_string()
}

pub fn with_token(mut request: Request<Body>, token: &str) -> Request<Body> {
    let value = HeaderValue::from_str(&format!("Bearer {token}")).unwrap();
    request.headers_mut().insert(header::AUTHORIZATION, value);
    request
}

pub async fn send_authed(app: &Router, token: &str, request: Request<Body>) -> (StatusCode, Value) {
    send(app, with_token(request, token)).await
}
```

- **`with_token` takes `mut request` by value and returns it**: it *consumes* the request, changes
  it, and hands it back. Ownership in, ownership out (Lab 06), so the call site reads
  `send(app, with_token(request, &token))` with no `&mut` noise. It composes with every Lab 29
  builder: `with_token(get("/me"), &token)`, `with_token(post_json(...), &token)`.
- **Assertions inside helpers** (`assert_eq!(status, CREATED, ...)`) give you a precise failure
  message ("register alice@example.com: {…body…}") instead of a confusing one three lines later.

### Fixing the existing suite

For each existing API test that calls a protected route:

```rust
// before
let app = app(pool);
let (status, body) = send(&app, post_json("/companies", json!({ "name": "Acme" }))).await;

// after
let app = app(pool);
let token = register_and_login(&app, "rep@example.com").await;
let (status, body) =
    send_authed(&app, &token, post_json("/companies", json!({ "name": "Acme" }))).await;
```

It's mechanical. A search-and-replace of `send(&app, ` → `send_authed(&app, &token, ` plus one
`let token = ...` line per test does most of it. Tests written as `send(&app(pool), ...)` need
the `let app = app(pool);` line first. Helpers that call protected routes need a token parameter
too: Lab 29's `create_company(app, name)` becomes `create_company(app, &token, name)`, and
`log_calls` in `tests/api/activities.rs` gains a `token: &str`. Leave `tests/api/auth.rs` alone:
`/auth/register` is public.

**Fixtures** (`tests/fixtures/*.sql`, Lab 33) that insert deals or leads need an owner now. Add a
`users` fixture in the same style as the others (a known id via `OVERRIDING SYSTEM VALUE`, then
`setval` so users registered *during* the test get ids after it):

```sql
-- tests/fixtures/users.sql
-- One user to own fixture deals and leads. The hash is never checked: nobody
-- logs in as a fixture user.
INSERT INTO users (id, email, name, password_hash, role) OVERRIDING SYSTEM VALUE VALUES
    (1, 'owner@example.com', 'Fixture Owner', 'not-a-real-hash', 'sales_rep');

SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users));
```

Then give every row in `deals.sql` and `leads.sql` an owner:

```sql
-- tests/fixtures/deals.sql
-- Needs the "users" and "companies" fixtures first.
INSERT INTO deals (id, company_id, title, value_cents, stage, owner_id) OVERRIDING SYSTEM VALUE VALUES
    (1, 1, 'Rockets', 100000, 'qualification', 1),
    (2, 1, 'Anvils', 25050, 'proposal', 1),
    (3, 2, 'Widgets', 50000, 'won', 1);
-- (setval line unchanged)
```

```sql
-- tests/fixtures/leads.sql
-- Needs the "users" fixture first.
INSERT INTO leads (id, name, email, company_name, source, status, owner_id) OVERRIDING SYSTEM VALUE VALUES
    (1, 'Dee Initech', 'dee@initech.test', 'Initech', 'referral', 'qualified', 1),
    (2, 'Eve New', 'eve@new.test', NULL, 'website', 'new', 1);
-- (setval line unchanged)
```

…and put `"users"` first in every test that loads `deals` or `leads`:
`#[sqlx::test(fixtures(path = "../fixtures", scripts("users", "companies", "deals")))]`,
`scripts("users", "leads")`, `scripts("users", "companies", "leads")`. (`'not-a-real-hash'` is fine:
nobody logs in as a fixture user, and the column is plain `TEXT`.)

**Raw SQL in tests.** `tests/db/history.rs` (Lab 33) inserts a note and an activity with plain
`INSERT`s. Both tables now have a `NOT NULL created_by`, so add the column with the fixture
user's id: `INSERT INTO notes (subject_type, subject_id, body, created_at, created_by) VALUES (..., 1)`,
and the same for `activities`.

**Repository tests** (`tests/db/`) that call `deals::db::insert` (or `leads::db::insert`)
directly need a real `UserId`. Use the fixture user (`UserId(1)`), or a small helper:

```rust
async fn any_user(pool: &PgPool) -> UserId {
    let new = NewUser { email: Email::parse("owner@example.com").unwrap(), name: "Owner".into() };
    users::db::insert(pool, &new, "not-a-real-hash").await.unwrap().id
}
```

### One test, followed along

> 🟢 **FOLLOW ALONG**: `tests/api/login.rs` (and `mod login;` in `tests/api/main.rs`)

```rust
use crate::helpers::{TEST_PASSWORD, app, post_json, register_and_login, send};
use axum::http::StatusCode;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test]
async fn wrong_password_and_unknown_email_look_identical(pool: PgPool) {
    let app = app(pool);
    register_and_login(&app, "ada@example.com").await;

    let wrong_password = send(
        &app,
        post_json("/auth/login", json!({"email": "ada@example.com", "password": "not the password"})),
    )
    .await;
    let unknown_email = send(
        &app,
        post_json("/auth/login", json!({"email": "nobody@example.com", "password": TEST_PASSWORD})),
    )
    .await;

    assert_eq!(wrong_password.0, StatusCode::UNAUTHORIZED);
    assert_eq!(wrong_password, unknown_email); // status AND body, byte for byte
}
```

Comparing the whole `(StatusCode, Value)` tuples is the strongest form of "these must look the
same": any difference in status, code or message fails the test.

---

## Step 13 — Offline query data

```bash
cargo sqlx prepare -- --all-targets
git add .sqlx
```

---

## ▶️ Run It

```bash
cargo run
```

```bash
# log in (Ada was registered in Lab 34; after `sqlx database reset`, register her again first)
curl -s -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","password":"correct horse battery staple"}'

# wrong password, then unknown email
curl -i -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","password":"wrong password!!"}'
curl -s -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d '{"email":"nobody@example.com","password":"correct horse battery staple"}'

# no token
curl -i localhost:3000/me

# with a token
TOKEN=$(curl -s -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","password":"correct horse battery staple"}' | jq -r .access_token)
curl -s localhost:3000/me -H "Authorization: Bearer $TOKEN"
curl -s -X POST localhost:3000/companies -H 'content-type: application/json' \
  -H "Authorization: Bearer $TOKEN" -d '{"name":"Acme"}'
curl -s -X POST localhost:3000/deals -H 'content-type: application/json' \
  -H "Authorization: Bearer $TOKEN" -d '{"company_id":1,"title":"Annual licence","value_cents":1200000}'

# still public
curl -s localhost:3000/health
```

(No `jq`? `brew install jq`, or copy the token by hand.)

## ✅ Expected Result

```json
{"access_token":"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOjEsInJvbGUiOiJzYWxlc19yZXAiLCJpYXQiOjE3OTEyMTEwMjYsImV4cCI6MTc5MTIxMTkyNn0.7VI_QSSmQUY903_clUCCB2y_3JA3xdTZeObrI1bUG7g","token_type":"Bearer","expires_in":900}
```

```text
HTTP/1.1 401 Unauthorized
content-type: application/json
www-authenticate: Bearer

{"error":{"code":"unauthorized","message":"invalid email or password"}}
```

```json
{"error":{"code":"unauthorized","message":"invalid email or password"}}
```

```text
HTTP/1.1 401 Unauthorized
content-type: application/json
www-authenticate: Bearer

{"error":{"code":"unauthorized","message":"missing bearer token"}}
```

```json
{"id":1,"email":"ada@example.com","name":"Ada Lovelace","role":"sales_rep","created_at":"2026-10-05T14:36:46.714144Z"}
{"id":1,"name":"Acme","website":null,"lifecycle":"prospect"}
{"id":1,"company_id":1,"title":"Annual licence","value_cents":1200000,"stage":"qualification","owner_id":1}
{"status":"ok"}
```

Your token, ids and timestamps will differ. What must match: the **401s** with `www-authenticate: Bearer`, the
**identical** bodies for wrong password vs unknown email, `expires_in: 900`, and `owner_id` on
the deal being *your* user id.

```bash
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

## 🧠 Understand It

**The request's journey, now:**

```text
Authorization: Bearer eyJ…
      │
      ▼
Router: path matched → protected router → route_layer(require_auth)
      │   AuthUser::from_request_parts
      │     bearer_token(headers)?        → MissingToken / InvalidToken → 401
      │     jwt::verify(token, keys)?     → InvalidToken / TokenExpired → 401
      │     extensions.insert(user)
      ▼
handler(user: AuthUser, State(..), Json(..))
      │   AuthUser::from_request_parts → found in extensions, returned immediately
      ▼
create_deal sets owner_id = user.id
```

**Why `Rejection = ApiError` and not a custom rejection type?** Every error in this API has
one JSON shape (Lab 28). Reusing `ApiError` means a 401 from the extractor looks exactly like a
401 from login, and a client only has to parse one shape.

**Why is the extractor cheap enough to run on every request?** HMAC-SHA256 over a ~150-byte
string, plus JSON parsing of a tiny payload: microseconds, no I/O. That's the real
benefit of stateless tokens, and it's why we accepted the revocation cost.

**Why does login *not* use `spawn_blocking` for `jwt::issue`?** Signing is microseconds of
work, well below anything that blocks the runtime noticeably. Argon2 is milliseconds, *by design*.
The rule isn't "crypto goes on the blocking pool". It's "anything that takes long without awaiting does".

**`LazyLock` vs computing the dummy hash in `main`:** you could compute it at startup and put it in
`AppState`. `LazyLock` keeps it out of the state (handlers don't need to know about it) and
costs nothing until the first login. Either is fine. The thing that matters is that the
parameters match real hashes.

**Is timing equalisation perfect?** No. The database query for an existing user returns a row
and an unknown one doesn't, which is a sub-millisecond difference compared with Argon2's ~15 ms. Rate
limiting logins per IP/email (a Lab 41 stretch goal) is the other half of the defence.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: signed, not encrypted.** Decode your token's middle segment:
>
> ```bash
> echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
> ```
>
> (`base64` may complain about missing padding. The JSON still prints.) What can anyone who
> intercepts a token learn? Would it be OK to add the user's email as a claim? A phone number?

> 🟡 **EXPERIMENT 2: forge an admin.** Write a unit test in `jwt.rs`: issue a token for a
> `SalesRep`, issue another for an `Admin`, and splice the *admin* payload (segment 2) between
> the *rep's* header and signature. Predict what `verify` returns before you run it. What would
> an attacker need to make the forgery work?

> 🟡 **EXPERIMENT 3: hear the timing leak.** Temporarily replace the dummy-hash arm in `login` with
> `None => return Err(AuthError::InvalidCredentials.into()),`, run the server, and time both
> kinds of failure:
>
> ```bash
> for i in 1 2 3; do
>   curl -s -o /dev/null -w "wrong password: %{time_total}s\n" -X POST localhost:3000/auth/login \
>     -H 'content-type: application/json' -d '{"email":"ada@example.com","password":"wrong password!!"}'
>   curl -s -o /dev/null -w "unknown email:  %{time_total}s\n" -X POST localhost:3000/auth/login \
>     -H 'content-type: application/json' -d '{"email":"nobody@example.com","password":"wrong password!!"}'
> done
> ```
>
> Measured while writing this lab:
>
> ```text
> with the dummy hash                 without it
> wrong password: 0.014096s           wrong password: 0.016053s
> unknown email:  0.014599s           unknown email:  0.001022s
> ```
>
> Restore the dummy hash. Why was the *first* unknown-email login slower than later ones with
> the dummy hash in place? (Think `LazyLock`.)

> 🟡 **EXPERIMENT 4: expiry.** In `login`, issue with `TimeDelta::seconds(-120)` instead of
> `ACCESS_TOKEN_TTL`. Log in and call `/me` with the token. Then try `TimeDelta::seconds(-30)`.
> One of them works. Which, and why? (Find `leeway` in Step 5.) Restore `ACCESS_TOKEN_TTL`.

> 🟡 **EXPERIMENT 5: forget the extractor.** Remove `user: AuthUser` from `create_deal` and
> pass `UserId(1)` to `for_company` instead of `user.id`. Call `POST /deals` without a token. Is it still
> protected? By which layer? Now imagine the route had been registered in `public_routes()` by
> mistake. What would protect it then? Restore the extractor.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `bearer_token`** (`src/auth/extractor.rs`)
>
> ```rust
> pub fn bearer_token(headers: &HeaderMap) -> Result<&str, AuthError>;
> ```
>
> | `Authorization` header | Result |
> |---|---|
> | absent | `Err(AuthError::MissingToken)` |
> | `Bearer abc.def.ghi` | `Ok("abc.def.ghi")` |
> | `bearer abc` (scheme in any letter case, RFC 9110) | `Ok("abc")` |
> | `Basic dXNlcjpwYXNz`, `Bearer`, `Bearer   `, `abc.def.ghi` (no scheme) | `Err(AuthError::InvalidToken)` |
> | not valid visible ASCII (`to_str()` fails) | `Err(AuthError::InvalidToken)` |
>
> - [ ] No allocation: the returned `&str` borrows from `headers`
> - [ ] Unit tests for **every row** of the table (build a `HeaderMap` with `HeaderValue::from_str`)
> - [ ] `curl -i localhost:3000/me -H 'Authorization: Basic xyz'` → 401 `invalid access token`

> 🔵 **YOUR TURN 2: `verify_in_background`** (`src/auth/password.rs`)
>
> ```rust
> pub async fn verify_in_background(password: SecretString, hash: String) -> Result<bool, AuthError>;
> ```
>
> - [ ] Runs `verify_password` on the blocking pool. A `JoinError` becomes `AuthError::Task`.
> - [ ] Takes both arguments **by value**. In a comment, explain why `&str` for `hash` wouldn't compile.
> - [ ] Login works end to end (▶️ Run It)

> 🔵 **YOUR TURN 3: owners for leads and activities**
>
> - [ ] `POST /leads` stores `owner_id` = the caller: `leads::db::insert(db, &new, owner_id: UserId)`.
>       `Lead` gains `pub owner_id: UserId` and `LeadResponse` exposes `owner_id`.
> - [ ] `POST /activities` stores `created_by` = the caller:
>       `activities::db::insert(pool, &new, created_by: UserId)`. `Activity` gains
>       `pub created_by: UserId` (Lab 39 reads it), so every `SELECT`/`RETURNING` on `activities` lists it.
> - [ ] Converting a lead creates a deal **owned by the lead's owner** (not necessarily the
>       caller): `ConversionPlan` gains `pub owner_id: UserId`, `Lead::plan_conversion` copies it
>       from the lead, and `convert_lead` passes `plan.owner_id` to `for_company`. The lead row it
>       locks with `get_for_update` already carries `owner_id` once `LeadRow` does. Update the
>       `lead()` helper in the `leads/model.rs` unit tests (it builds a `Lead` literal).
> - [ ] A repository test in `tests/db/leads.rs`: after `convert_lead`, the new deal's `owner_id`
>       equals the lead's
> - [ ] No request DTO has an `owner_id` / `created_by` field. Clients can't choose.
> - [ ] `cargo sqlx prepare -- --all-targets` and the whole suite green

> 🔵 **YOUR TURN 4: authentication API tests** (`tests/api/login.rs`)
>
> - [ ] `login_returns_a_bearer_token`: 200, `token_type == "Bearer"`, `expires_in == 900`
> - [ ] `me_returns_the_logged_in_user`: `/me` with the token returns the registered email
> - [ ] `protected_routes_require_a_token`: for `/me`, `/deals` and `/companies/1` with **no**
>       header: 401 **and** the `www-authenticate` header equals `Bearer` (you'll need the raw
>       response, since `send` drops headers, so call `tower::ServiceExt::oneshot` directly)
> - [ ] `garbage_token_is_401`: `Bearer not.a.jwt` → 401 with `error.code == "unauthorized"`
> - [ ] `created_deal_is_owned_by_the_caller`: `owner_id` in the `POST /deals` response equals `/me`'s `id`
> - [ ] `created_lead_is_owned_by_the_caller` (from Your Turn 3)

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `headers.get(AUTHORIZATION)` → `Option<&HeaderValue>`;
> `.to_str()` → `Result<&str, _>`; then split *once* on the first space.

<details><summary>Hint 2 (more specific)</summary>

- `.ok_or(AuthError::MissingToken)?` turns the `Option` into your error.
- `value.split_once(' ')` returns `Option<(&str, &str)>`. `None` means there was no space at all.
- `scheme.eq_ignore_ascii_case("bearer")` handles `Bearer`/`bearer`/`BEARER`.
- `token.trim().is_empty()` catches `"Bearer   "`.
- All of these return slices of the original header bytes, so no `String` is ever created.

</details>

<details><summary>Hint 3 (Your Turn 2)</summary>

It's Lab 34's `hash_in_background` with one more captured variable. With `hash: &str`, the
`move` closure would capture a *reference*, and `spawn_blocking` needs `'static`. You'd get the
same E0521 as in Lab 34, Step 5.

</details>

<details><summary>Hint 4 (Your Turn 4: reading a header in a test)</summary>

```rust
let response = tower::ServiceExt::oneshot(app.clone(), get("/me")).await.unwrap();
assert_eq!(response.headers()["www-authenticate"], "Bearer");
```

`get(uri)` is your Lab 29 helper.

</details>

<details><summary>Hint 5 (Your Turn 3: the conversion's owner)</summary>

`Lead::plan_conversion` is pure (Lab 31) and must stay pure: it doesn't look anything up. It
already decides the company, the contact and the deal input from the lead's own fields. The
owner is one more of those facts (`self.owner_id`), so it belongs in the `ConversionPlan`. In
`convert_lead`, `leads::db::get_for_update` returns a `Lead` built from `LeadRow`, so once the
row's `SELECT ... FOR UPDATE` lists `owner_id`, the plan has everything `for_company` needs.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. A user clicks "log out" and you delete nothing on the server. For how long can their stolen
   token still be used? Name two ways to shorten or close that window, and what each costs.
2. What are the three parts of a JWT? Which part stops a client from changing its own role, and why
   doesn't that make the payload secret?
3. Why does `verify` pin `Algorithm::HS256` instead of trusting the token's header?
4. Explain both leaks a naive login endpoint has (message and timing), and how the handler closes each.
5. What does implementing `FromRequestParts<AppState>` for `AuthUser` let you write in a handler?
   What happens if extraction fails?
6. Why do we have *both* `require_auth` and `user: AuthUser` in handlers? Which is the source of truth?
7. Why did `ADD COLUMN owner_id BIGINT NOT NULL` fail on your dev database, and how would you ship
   the same change to production?
8. Why must a client never send `owner_id` when creating a deal?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit
```bash
git add .
git commit -m "Add JWT authentication"
git tag lab-35
git push && git push --tags
```

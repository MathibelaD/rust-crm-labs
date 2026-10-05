# Lab 34 — Solutions

> 🔴 These are *one* good answer each, with the reasoning. If yours differs but meets the
> acceptance criteria and you can explain your choices, it's correct.

---

## Your Turn 1 — `validate_registration`

```rust
fn validate_registration(req: RegisterRequest) -> Result<(NewUser, SecretString), Vec<FieldError>> {
    let mut errors = Vec::new();

    let email = match Email::parse(&req.email) {
        Ok(email) => Some(email),
        Err(e) => {
            errors.push(FieldError::new("email", e.to_string()));
            None
        }
    };

    let name = req.name.trim().to_string();
    if name.is_empty() {
        errors.push(FieldError::new("name", "must not be empty"));
    }

    let length = req.password.expose_secret().chars().count();
    if !(MIN_PASSWORD_CHARS..=MAX_PASSWORD_CHARS).contains(&length) {
        errors.push(FieldError::new(
            "password",
            format!("must be between {MIN_PASSWORD_CHARS} and {MAX_PASSWORD_CHARS} characters"),
        ));
    }

    match email {
        Some(email) if errors.is_empty() => Ok((NewUser { email, name }, req.password)),
        _ => Err(errors),
    }
}
```

**Why it's shaped like this**

- **`Option<Email>` + one final `match`.** The success case needs *both* "the email parsed"
  and "no errors at all". A `match` with a guard (`Some(email) if errors.is_empty()`) says
  exactly that, and the compiler makes us handle every other combination with `_ => Err(errors)`.
  You never get a `NewUser` built from a half-valid request.
- **`req.password` is moved out at the very end.** `req` is owned by this function, so we can
  move a field out of it (a *partial move*, Lab 06). We read `req.email`, `req.name` and
  `req.password` (through `expose_secret()`, a borrow) *before* the move, and nothing touches
  `req` after it. If you moved the password first and then read `req.name`, you'd still be fine
  (different fields), but `&req` as a whole would be rejected. Moving last is the habit that
  avoids surprises.
- **No `.clone()` of the secret.** Cloning a `SecretString` is possible but would create a
  second copy of the plaintext in memory. Moving keeps exactly one.
- **`chars().count()`** counts Unicode scalar values, which is close enough to "characters" for
  a length rule (Lab 09 talks about grapheme clusters if you want to go further).

### Unit tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn request(email: &str, name: &str, password: &str) -> RegisterRequest {
        RegisterRequest {
            email: email.into(),
            name: name.into(),
            password: SecretString::from(password),
        }
    }

    #[test]
    fn valid_registration_passes() {
        let (user, _) =
            validate_registration(request(" Ada@Example.com ", "Ada", "correct horse battery"))
                .unwrap();
        assert_eq!(user.email.as_str(), "ada@example.com");
    }

    #[test]
    fn all_errors_are_collected() {
        let errors = validate_registration(request("nope", "  ", "short")).unwrap_err();
        let fields: Vec<_> = errors.iter().map(|e| e.field).collect();
        assert_eq!(fields, ["email", "name", "password"]);
    }

    #[test]
    fn password_length_counts_characters_not_bytes() {
        // 12 characters, but 24 bytes
        assert!(validate_registration(request("a@b.co", "A", "éééééééééééé")).is_ok());
    }

    #[test]
    fn request_debug_does_not_leak_password() {
        let printed = format!("{:?}", request("a@b.co", "A", "hunter2hunter2"));
        println!("{printed}");
        assert!(!printed.contains("hunter2"));
    }
}
```

Running the last one with `--nocapture` prints (verified):

```text
RegisterRequest { email: "a@b.co", name: "A", password: SecretBox<str>([REDACTED]) }
```

> Can `validate_registration` be private and still be tested? Yes. The `tests` module is a
> *child* of `http::auth`, and child modules can see their parent's private items (Lab 13).

> `.unwrap()` / `.unwrap_err()` in tests are fine (Lab 12): a panic *is* the failure report.
> `unwrap_err()` requires the `Ok` type to be `Debug`. `(NewUser, SecretString)` is, thanks to
> `#[derive(Debug)]` on `NewUser` and secrecy's redacting `Debug`.

---

## Your Turn 2 — `find_by_email` and `get`

```rust
pub async fn find_by_email(
    db: impl PgExecutor<'_>,
    email: &Email,
) -> Result<Option<(User, String)>, CrmError> {
    let Some(row) = sqlx::query!(
        "SELECT id, email, name, role, created_at, password_hash
         FROM users WHERE email = $1",
        email.as_str(),
    )
    .fetch_optional(db)
    .await?
    else {
        return Ok(None);
    };

    let user = User::try_from(UserRow {
        id: row.id,
        email: row.email,
        name: row.name,
        role: row.role,
        created_at: row.created_at,
    })?;
    Ok(Some((user, row.password_hash)))
}

pub async fn get(db: impl PgExecutor<'_>, id: UserId) -> Result<User, CrmError> {
    let row = sqlx::query_as!(
        UserRow,
        "SELECT id, email, name, role, created_at FROM users WHERE id = $1",
        id.0,
    )
    .fetch_optional(db)
    .await?
    .ok_or(not_found(id))?;
    Ok(row.try_into()?)
}
```

**Reasoning**

- **`query!` (anonymous record) instead of a second row struct.** The record has one extra
  field, `password_hash`. We *move* the other fields into a `UserRow` so the existing
  `TryFrom` does the validation, and keep `row.password_hash` for the tuple. Moving fields out
  of `row` one by one is a partial move again. It's fine because we never use `row` as a whole afterwards.
  (A second struct `UserWithHashRow` + `query_as!` is equally good.)
- **`let ... else`** keeps the "not found" exit at the top and the happy path flat.
- **`Option<(User, String)>`**, not `Result<(User, String), NotFound>`. For login, "no such
  user" is an expected outcome, and it must be handled *without* revealing anything (Lab 35's
  dummy hash). An `Option` makes the caller decide. `get`, in contrast, is used when the id came
  from somewhere trustworthy (a token, an admin URL), so a missing row really is `NotFound`.
- **`get`, type by type**: `fetch_optional` → `Option<UserRow>`, `.ok_or(not_found(id))?` →
  `UserRow`, `row.try_into()` → `Result<User, sqlx::Error>`, and the final `?` inside `Ok(...)`
  converts a corrupt-row error into `CrmError::Database`. You can't simply *return*
  `row.try_into()`: its error type is `sqlx::Error`, not `CrmError`, and only `?` applies the `From`.
- **`?` on `User::try_from(...)` in `find_by_email`** converts the same way.
- **`id.0`**: the macros check parameter types against Postgres types, and they know `BIGINT ↔ i64`, not your newtype.
- After adding these: `cargo sqlx prepare -- --all-targets`.

> If your `CrmError::NotFound` still has `id: u64` from before Lab 30, use `id.0 as u64`, or
> better, finish the i64 switch Lab 30 asked for.

---

## Your Turn 3 — registration API tests

`tests/api/main.rs` gains `mod auth;`. Then `tests/api/auth.rs`:

```rust
use crate::helpers::{app, error_code, post_json, send};
use axum::http::StatusCode;
use serde_json::json;
use sqlx::PgPool;

fn register_body(email: &str) -> serde_json::Value {
    json!({ "email": email, "name": "Ada Lovelace", "password": "correct horse battery staple" })
}

#[sqlx::test]
async fn register_returns_201_and_never_the_password(pool: PgPool) {
    let app = app(pool);
    let (status, body) =
        send(&app, post_json("/auth/register", register_body("ada@example.com"))).await;

    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["email"], "ada@example.com");
    assert_eq!(body["role"], "sales_rep");
    assert!(body.get("password").is_none());
    assert!(body.get("password_hash").is_none());
}

#[sqlx::test]
async fn register_stores_an_argon2id_hash_not_the_password(pool: PgPool) {
    let app = app(pool.clone());
    send(&app, post_json("/auth/register", register_body("ada@example.com"))).await;

    let hash: String =
        sqlx::query_scalar("SELECT password_hash FROM users WHERE email = 'ada@example.com'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(hash.starts_with("$argon2id$"));
    assert!(!hash.contains("correct horse"));
}

#[sqlx::test]
async fn duplicate_email_is_409_even_with_different_case(pool: PgPool) {
    let app = app(pool);
    send(&app, post_json("/auth/register", register_body("ada@example.com"))).await;
    let (status, body) =
        send(&app, post_json("/auth/register", register_body("ADA@example.com"))).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&body), "conflict");
}

#[sqlx::test]
async fn invalid_registration_reports_every_field(pool: PgPool) {
    let app = app(pool);
    let (status, body) = send(
        &app,
        post_json("/auth/register", json!({ "email": "nope", "name": "", "password": "short" })),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let fields: Vec<&str> = body["error"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["field"].as_str().unwrap())
        .collect();
    assert_eq!(fields, ["email", "name", "password"]);
}
```

**Notes**

- `post_json`, `send` and `error_code` are your Lab 29 helpers. `app(pool)` is the Lab 33 version.
  If yours differ slightly, adapt the calls. The assertions are what matter.
- **`body.get("password").is_none()`** rather than `body["password"] == Value::Null`: indexing
  a missing key in `serde_json` returns `Null`, so the second form can't tell "absent" from
  "present but null". `get` can.
- **`pool.clone()`**: the test needs the pool *and* the app needs one. `PgPool` is an `Arc`
  inside, so cloning is a reference-count bump, not a new connection pool.
- **The second test reads the database directly.** API tests normally only use the public
  API, but "the password is not stored in plaintext" is a property *of the storage*, so this is
  the right place to break that rule.

---

## Your Turn 4 — the missing password tests

```rust
    #[test]
    fn wrong_password_is_ok_false() {
        let hash = hash_password(&secret("correct horse battery staple")).unwrap();
        assert!(!verify_password(&secret("Correct horse battery staple"), &hash).unwrap());
    }

    #[test]
    fn malformed_hash_is_an_error() {
        // A wrong password is a normal outcome -> Ok(false) -> 401 in Lab 35.
        // A hash we can't parse means our DATA is broken -> Err -> 500 + a log line,
        // because no password could ever log this user in and someone must fix the row.
        let result = verify_password(&secret("whatever-password"), "not-a-phc-string");
        assert!(matches!(result, Err(AuthError::Hash(_))));
    }
}
```

`matches!` (Lab 11) because `AuthError` isn't `PartialEq`, and can't easily be: the wrapped
`JoinError` isn't comparable.

---

## Experiment answers

**Experiment 1 (parameters in the hash).** The new row's PHC string reads `m=65536,t=3,p=1`
while Ada's still reads `m=19456,t=2,p=1`. Both verify, because `verify_password` builds its
`PasswordHash` from the stored string and **uses the parameters and salt found there**
(the argon2 docs say this explicitly). The `Argon2` instance's own params are only used for
*new* hashes. That's how you raise costs over time: new hashes get the new cost, and you can
re-hash each user on their next successful login if you want everyone upgraded.

**Experiment 2 (same password, two users).** The hashes share only the `$argon2id$v=19$m=…`
prefix. Salt and output are completely different. If they were equal, an attacker would know
the two users share a password: crack one, get both. And with unsalted hashes one guess is
checked against *every* user at once, which is exactly what salting prevents.

**Experiment 3 (forgetting `spawn_blocking`).** It compiles, and that's bad news. The type
system knows about ownership, lifetimes, `Send` and `'static`, which is why it caught the
borrowed closure. It knows nothing about how long a function *runs*: a 20 ms CPU-bound call and
a 20 ns one have the same type. Blocking the runtime is a *performance* bug, invisible to
the type checker. You catch it with review, the rule "no CPU-heavy or blocking calls in async
fns", and tools like `tokio-console` that show tasks being starved.

**Experiment 4 (try to leak).** `println!("{req:?}")` compiles and prints
`RegisterRequest { email: "...", name: "...", password: SecretBox<str>([REDACTED]) }`:
harmless. `println!("{}", req.password)` doesn't compile (E0277, no `Display`). The two
safety nets work together: the dangerous form is impossible, and the easy form is safe.

---

## Checkpoint answers (short)

1. A GPU does billions of SHA-256/s, so dictionary guessing is nearly free. Argon2id costs
   ~20 ms *and* ~19 MiB per guess, which cuts the attacker's rate by many orders of magnitude and
   takes away most of the GPU advantage.
2. `algorithm $ version $ params $ salt $ hash`. Because verification reads the parameters
   from the string, you can raise cost later without breaking old hashes.
3. It's ~20 ms of CPU with no `.await`, so it would block a Tokio worker thread. The closure
   must be `'static` (it may outlive the awaiting future), so it has to own its data. A borrow
   from the caller can't be proven to live long enough.
4. `Display` is what you'd use to put a value in user-visible or logged text, so leaving it out
   makes the dangerous use a compile error. `Debug` is derived everywhere (structs containing the
   secret need it), so it exists but prints `[REDACTED]`.
5. So no code path that serializes, logs or returns a `User` *can* include it. The hash only
   appears in `find_by_email`'s tuple, used by login.
6. Only the database sees all concurrent transactions. A check in Rust races with itself.
7. A wrong password is an expected user outcome (401). An `Err` means the stored data or the
   system is broken (500). Mixing them hides real failures behind "invalid credentials".

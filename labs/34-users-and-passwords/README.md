# Lab 34 — Users & Password Hashing

> **Phase:** 10 — Users, Authentication & Authorization · **Builds on:** Lab 33 · **Time:** ~3–4 hours
> **Your repo before this lab:** tag `lab-33` · **After:** tag `lab-34`

## 🎯 Goal
Give the CRM **users**. Add a `users` table, hash passwords with Argon2id, and expose
`POST /auth/register`. Nobody can log in yet (that's Lab 35), but by the end of this lab a
password can enter your system, and it will never be stored, logged or returned in plaintext.

## 🧠 What You'll Learn
- The **mental model of password hashing**: why it must be *slow*, *salted* and *memory-hard*,
  and why SHA-256 is the wrong tool
- The **PHC string format** (`$argon2id$v=19$m=19456,t=2,p=1$…`) and why the hash carries its own settings
- `argon2` 0.6: `hash_password`, `verify_password`, and turning its errors into **your** error type
- **CPU-heavy work in async code**: why hashing belongs on `tokio::task::spawn_blocking`
  (the Lab 26 lesson, applied to CPU instead of disk), and why the closure must own its data
- The `secrecy` crate: `SecretString` makes leaking a password into a log a **compile error**
  (`Display`) or harmless (`Debug` prints `[REDACTED]`)
- **Types encode policy**: a `User` struct with *no password field*, so no handler can return a hash by accident
- Uniqueness and allowed values enforced **in the database** (`UNIQUE`, `CHECK`), not only in Rust

## 🔨 What We're Building
Until now the CRM has had no idea *who* is calling it. Phase 10 fixes that in three steps:

```text
Lab 34  users + password hashing     POST /auth/register      ← you are here
Lab 35  authentication (JWT)         POST /auth/login, GET /me, every route needs a token
Lab 36  authorization (roles)        reps only see their deals, managers reassign, admins manage users
```

This lab adds:

```text
migrations/<ts>_create_users.sql   users(id, email UNIQUE, name, password_hash, role CHECK, created_at)
src/auth/mod.rs                    AuthError
src/auth/password.rs               hash_password, verify_password, hash_in_background
src/users/mod.rs, model.rs, db.rs  UserId, Role, User (no password!), NewUser, insert/find_by_email/get
src/http/auth.rs                   POST /auth/register
scripts/make_admin.sql             how the first admin is created
tests/api/auth.rs                  registration tests
```

> Written against **argon2 0.6**, **secrecy 0.10**, axum 0.8 and sqlx 0.9. If a newer version
> moved an API, check docs.rs for that crate. The *ideas* in this lab don't change between versions.

---

## Step 0 — Start from a clean `lab-33`

```bash
git status                 # nothing to commit, working tree clean
git describe --tags        # lab-33
docker compose up -d       # Postgres from Lab 30
cargo test                 # the Lab 33 suite is green before you change anything
```

If a test is red *before* you start, fix that first. Otherwise you won't know whether this lab
broke it.

---

## Step 1 — The mental model: what is a password hash *for*?

Start with the threat, not the code. **Assume your database leaks.** A backup ends up in the
wrong S3 bucket, someone runs a SQL injection you missed, an ex-employee keeps a dump. It happens
to well-run companies every year.

Now ask: *what does the attacker get?*

| You store… | The attacker gets… |
|---|---|
| the password | every password, instantly. And people reuse passwords, so their email and bank too. |
| `sha256(password)` | almost every password, within hours (see below) |
| `sha256(salt + password)` | the same, just per-user instead of all at once |
| `argon2id(salt, password)` with sane parameters | a very expensive guessing job for **each** user. Strong passwords survive. |

### Why not SHA-256?

SHA-256 is a superb hash, and that's exactly the problem. It was designed to be **fast**: a
single modern GPU computes billions of SHA-256 hashes per second. Real passwords are not random.
They come from a small, well-known space (dictionaries, leaked-password lists, `Summer2024!`). An
attacker doesn't need to "reverse" the hash. They **guess**, hash the guess, and compare.
At billions of guesses per second, most human-chosen passwords fall in minutes.

So a password hash needs three properties a normal hash doesn't:

```text
1. SALTED       a random value per password, stored next to the hash.
                → the same password gives different hashes for different users,
                  so one guess can't be checked against everyone at once,
                  and precomputed "rainbow tables" are useless.

2. SLOW         deliberately costs ~10–50 ms of CPU per hash.
                → you pay that once per login. The attacker pays it per GUESS.
                  10 ms × a billion guesses = ~4 months of CPU, per user.

3. MEMORY-HARD  each hash also needs a chunk of RAM (here ~19 MiB).
                → GPUs and custom chips have thousands of cores but little memory per core,
                  so they lose most of their advantage.
```

**Argon2id** has all three. It won the Password Hashing Competition in 2015 and is the current
OWASP recommendation. (bcrypt and scrypt are older acceptable choices. Plain SHA-*/MD5 are not.)

> 💡 **Pepper**: some systems also mix in a secret key (a "pepper") kept *outside* the
> database, so a DB-only leak is useless. `argon2` supports this (`Argon2::new_with_secret`). We
> skip it to keep the lab focused, and it's a good extension once Lab 38 gives you real secrets management.

### The PHC string: a hash that describes itself

Argon2 doesn't give you raw bytes to store in three columns. It produces one string in the
**PHC format** that contains everything needed to verify a password later:

```text
$argon2id$v=19$m=19456,t=2,p=1$YJhDJHuN578odkdmXm4pUw$jiwLUYsrGWrtdRJMSup7TINkX4s629qB2D1QM3g095w
 ───┬─── ──┬─ ───────┬─────── ───────────┬────────── ───────────────────┬────────────────────────
 algorithm version  parameters        salt (base64)              hash output (base64)
                   m = memory in KiB (19456 KiB = 19 MiB)
                   t = iterations (time cost)
                   p = parallelism (lanes)
```

That's a real hash from this lab. Because the parameters travel *with* the hash, you can raise
the cost next year and old hashes still verify with the parameters they were created with.
Verification reads `m`, `t`, `p` and the salt from the string. This is why our column is a
single `password_hash TEXT`.

---

## Step 2 — Add the crates

```bash
cargo add argon2
cargo add secrecy --features serde
```

- **`argon2`** (RustCrypto): Argon2id with sensible defaults. Its default features already
  include a secure random-number source for salts.
- **`secrecy`**: wrapper types for secrets. The `serde` feature lets a request DTO deserialize
  a password **straight into** a `SecretString`, so the plaintext is never sitting in a plain `String` field.

### Make hashing fast in debug builds

Argon2 is *designed* to be expensive, and unoptimised debug builds make it much worse. Measured
for this lab on an Apple-silicon laptop (one hash, default parameters):

```text
cargo run            (debug, everything unoptimised)   took 430.055792ms
cargo run --release                                    took 13.749333ms
```

430 ms per hash makes every registration test crawl. Cargo lets you optimise **one dependency**
even in debug builds. Add this to the bottom of `Cargo.toml`:

> 🟢 **FOLLOW ALONG**: `Cargo.toml`

```toml
# Argon2 is deliberately expensive; unoptimised it is ~30x slower.
# Optimise just this crate in dev/test builds. Your own code stays fast to compile and debug.
[profile.dev.package.argon2]
opt-level = 3
```

With that line the same debug hash took ~17–26 ms. Your numbers will differ. The *ratio* is the
point.

---

## Step 3 — `SecretString`: let the type system guard the password

What's wrong with this?

```rust
#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub email: String,
    pub name: String,
    pub password: String,
}
// ... and somewhere, months later, someone adds:
tracing::debug!(?req, "register request");   // 💥 every password, in plaintext, in your logs
```

Nothing, as far as the compiler can tell. Logs get shipped to third-party services, kept for
months, and read by many people. "Be careful" doesn't hold up over the years, so we let the
type system do the remembering.

`secrecy::SecretString` (an alias for `SecretBox<str>`) is a box around the string that:

- implements `Debug` as **`SecretBox<str>([REDACTED])`**
- does **not** implement `Display`, so you can't `{}`-format it at all
- only gives the value back through `.expose_secret()`, a method name you can `grep` for in code review
- **zeroes its memory on drop**, so the plaintext doesn't linger in freed heap memory

> 🟡 **EXPERIMENT**: predict first, then `cargo check`. Put this temporarily at the bottom of
> `src/lib.rs` and delete it afterwards:

```rust
pub fn leak(password: &secrecy::SecretString) {
    println!("registering with password {password}");
}
```

```text
error[E0277]: `SecretBox<str>` doesn't implement `std::fmt::Display`
  --> src/lib.rs:12:41
   |
12 |     println!("registering with password {password}");
   |                                         ^^^^^^^^^^ `SecretBox<str>` cannot be formatted with the default formatter
   |
   = help: the trait `std::fmt::Display` is not implemented for `SecretBox<str>`
   = note: in format strings you may be able to use `{:?}` (or `{:#?}` for pretty-print) instead
```

(Your line number will differ.) This is the trait system from Lab 15 working *for* you. `println!("{x}")` needs `x: Display`.
The authors of `secrecy` simply didn't implement it. The compiler suggests `{:?}`. Try it:

```rust
println!("registering with password {password:?}");
```

It compiles and prints `SecretBox<str>([REDACTED])`. That's the *safe* failure mode: a
careless `Debug` print leaks nothing.

**Ownership questions:** `leak` takes `&SecretString`, a shared borrow. Could it get at the
plaintext? Only with `password.expose_secret()`, which returns a `&str` borrowed from the box.
That `&str` can't outlive the `SecretString`, which is the borrow checker from Lab 07 limiting
how long the plaintext can be seen.

Delete `leak` before moving on.

---

## Step 4 — `src/auth/`: errors and the hashing functions

Create the `auth` module. It will grow a lot in Lab 35, so it starts as a folder.

> 🟢 **FOLLOW ALONG**: `src/lib.rs`: add the two new modules next to the others

```rust
pub mod auth;
pub mod users;
```

> 🟢 **FOLLOW ALONG**: `src/auth/mod.rs`

```rust
pub mod password;

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("password hashing failed: {0}")]
    Hash(#[from] argon2::password_hash::Error),
    #[error("background task failed")]
    Task(#[from] tokio::task::JoinError),
}
```

Two failure modes so far:

- `Hash`: argon2 itself failed. In practice that means a **corrupt stored hash** (it can't be
  parsed) or an out-of-memory condition. It never means "wrong password". We'll handle that separately.
- `Task`: the background thread we run hashing on panicked or was cancelled (Step 5).

Neither is the *client's* fault, so both will become a 500 response.

> 🟢 **FOLLOW ALONG**: `src/auth/password.rs`

```rust
use super::AuthError;
use argon2::{
    Argon2,
    password_hash::{self, PasswordHasher, PasswordVerifier, phc::PasswordHash},
};
use secrecy::{ExposeSecret, SecretString};

pub const MIN_PASSWORD_CHARS: usize = 12;
pub const MAX_PASSWORD_CHARS: usize = 128;

/// Hash a password with Argon2id and a fresh random salt.
/// Returns a PHC string: `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`.
pub fn hash_password(password: &SecretString) -> Result<String, AuthError> {
    let hash = Argon2::default().hash_password(password.expose_secret().as_bytes())?;
    Ok(hash.to_string())
}

/// `Ok(true)` = matches, `Ok(false)` = wrong password, `Err` = the stored hash is broken.
pub fn verify_password(password: &SecretString, hash: &str) -> Result<bool, AuthError> {
    let parsed = PasswordHash::new(hash).map_err(password_hash::Error::from)?;
    match Argon2::default().verify_password(password.expose_secret().as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(password_hash::Error::PasswordInvalid) => Ok(false),
        Err(e) => Err(e.into()),
    }
}
```

Read it slowly:

- **`Argon2::default()`** = Argon2id, version 19, `m=19456 (19 MiB), t=2, p=1`. Those are the
  OWASP-recommended minimums. You'll tune them in an experiment.
- **`hash_password(&[u8])`** in argon2 0.6 generates the random salt for you. (Older tutorials
  for 0.5 call `SaltString::generate(&mut OsRng)` first. Same idea, older API.)
- **`.expose_secret()`** is the *only* place the plaintext leaves its box, and only as a
  short-lived `&str`. `grep -rn expose_secret src/` gives you a complete list of the places that
  touch plaintext. Keep it short.
- **`verify_password` returns `Result<bool, _>`**, not `Result<(), _>`. Argon2 reports "wrong
  password" as an *error* (`PasswordInvalid`), but for us a wrong password is a normal,
  expected outcome, not a failure of the system. So we pull that one case out into `Ok(false)` and
  keep `Err` for "something is broken". This distinction pays off in Lab 35: a wrong password is a
  401, a corrupt hash is a 500 you want an alert for.
- **`PasswordHash::new(hash)`** parses the PHC string. Its error type comes from the `phc` crate,
  so `.map_err(password_hash::Error::from)` converts it before `?` wraps it into `AuthError::Hash`.
- **Why `MAX_PASSWORD_CHARS`?** Argon2 accepts enormous inputs, but there's no reason to let a
  client POST a 10 MB "password" and make you hash it. 128 is generous for passphrases and password managers.

Notice what *isn't* here: no comparison like `computed == stored`. `verify_password` recomputes
the hash with the stored salt and parameters and compares in **constant time**, so how long the
comparison takes doesn't reveal how many leading bytes matched.

Now the tests. These are pure functions, so they're fast unit tests and need no database.

> 🟢 **FOLLOW ALONG**: bottom of `src/auth/password.rs`

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn secret(s: &str) -> SecretString {
        SecretString::from(s)
    }

    #[test]
    fn hash_is_a_phc_string_for_argon2id() {
        let hash = hash_password(&secret("correct horse battery staple")).unwrap();
        assert!(hash.starts_with("$argon2id$v=19$"), "{hash}");
    }

    #[test]
    fn same_password_hashes_differently_because_of_the_salt() {
        let a = hash_password(&secret("correct horse battery staple")).unwrap();
        let b = hash_password(&secret("correct horse battery staple")).unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn correct_password_verifies() {
        let hash = hash_password(&secret("correct horse battery staple")).unwrap();
        assert!(verify_password(&secret("correct horse battery staple"), &hash).unwrap());
    }

    #[test]
    fn debug_output_is_redacted() {
        let password = secret("hunter2hunter2");
        let printed = format!("{password:?}");
        assert!(!printed.contains("hunter2"));
        println!("{printed}");
    }
}
```

```bash
cargo test --lib password -- --nocapture
```

```text
running 4 tests
SecretBox<str>([REDACTED])
test auth::password::tests::debug_output_is_redacted ... ok
test auth::password::tests::hash_is_a_phc_string_for_argon2id ... ok
test auth::password::tests::correct_password_verifies ... ok
test auth::password::tests::same_password_hashes_differently_because_of_the_salt ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 9 filtered out; finished in 0.06s
```

(The "filtered out" count depends on how many other unit tests you have.)

There are two obvious tests missing: a *wrong* password and a *broken* hash. You'll write them
in **Your Turn 4**.

---

## Step 5 — Hashing in an async server: `spawn_blocking`

The register handler will be an `async fn`. Can it just call `hash_password`?

It would *compile*. That's what makes this dangerous. Recall Lab 26: Tokio runs many tasks
on a **small number of worker threads** (one per CPU core by default). A task only gives its
thread back at an `.await`. `hash_password` has no `.await` in it. It's ~15–25 ms of pure CPU
work, and for that whole time the worker thread can't run *anything else*: no other request,
no DB result being processed, no `/health` check.

```text
worker thread 1:  [req A ][req B][██████ hash for register ██████][req C]...
                                  ↑ 20 ms where every task queued on this thread waits
```

Ten simultaneous registrations on an 8-core machine will stall the whole server for tens of
milliseconds. A login storm (Lab 35) is worse. This is the same lesson as Lab 26's
blocking file I/O: **anything that doesn't `.await` for a long time goes to the blocking pool.**
The only difference is that this time the CPU is busy, not the disk.

`tokio::task::spawn_blocking(closure)` runs the closure on a separate pool of threads made for
this, and gives you a future you can `.await` for the result.

> 🟡 **EXPERIMENT**: predict first. Add this to `src/auth/password.rs` and `cargo check`:

```rust
pub async fn hash_in_background(password: &SecretString) -> Result<String, AuthError> {
    tokio::task::spawn_blocking(|| hash_password(password)).await?
}
```

```text
error[E0521]: borrowed data escapes outside of function
  --> src/auth/password.rs:43:5
   |
42 | pub async fn hash_in_background(password: &SecretString) -> Result<String, AuthError> {
   |                                 --------  - let's call the lifetime of this reference `'1`
   |                                 |
   |                                 `password` is a reference that is only valid in the function body
43 |     tokio::task::spawn_blocking(|| hash_password(password)).await?
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |     |
   |     `password` escapes the function body here
   |     argument requires that `'1` must outlive `'static`
```

(Your line numbers will differ.)

**Read the error:**

1. **Who owns** the `SecretString`? The *caller*. We only hold `&SecretString`, a borrow.
2. **How long must it live?** `spawn_blocking` requires its closure to be `'static`: the
   blocking thread could keep running even if the future we `.await` is dropped (say the
   client disconnects and Axum cancels the handler). Tokio can't prove the caller's
   `SecretString` outlives that thread, so it won't accept a borrow at all.
3. **The fix is not `.clone()` or `&`-juggling.** It's to **move ownership into the thread**.
   The function takes `SecretString` by value, and the closure is a `move` closure:

> 🟢 **FOLLOW ALONG**: replace the experiment with this in `src/auth/password.rs`

```rust
/// Runs `hash_password` on Tokio's blocking thread pool.
pub async fn hash_in_background(password: SecretString) -> Result<String, AuthError> {
    tokio::task::spawn_blocking(move || hash_password(&password)).await?
}
```

Look at the types on the last line:

```text
spawn_blocking(...)                 : JoinHandle<Result<String, AuthError>>
spawn_blocking(...).await           : Result<Result<String, AuthError>, JoinError>
spawn_blocking(...).await?          : Result<String, AuthError>     (? turned JoinError into AuthError::Task)
```

The outer `Result` says whether the *thread* finished. The inner one says whether *hashing*
worked. One `?` strips the outer layer, and returning the inner `Result` as the function's value
finishes the job.

**Bonus:** because the closure now *owns* the `SecretString`, it's dropped (and zeroed) on the
blocking thread as soon as hashing finishes. Ownership tells you exactly when the plaintext
stops existing.

---

## Step 6 — The `users` table

```bash
sqlx migrate add create_users
```

> 🟢 **FOLLOW ALONG**: `migrations/<timestamp>_create_users.sql`

```sql
CREATE TABLE users (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'sales_rep'
                  CHECK (role IN ('admin', 'manager', 'sales_rep')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

```bash
sqlx migrate run
```

Two constraints here do real work:

- **`email ... UNIQUE`**. "Check if the email exists, then insert" in Rust is a **race**: two
  registrations for the same email arriving within the same millisecond both pass the check, and
  both insert. Only the database sees all transactions, so only the database can enforce uniqueness.
  You met this in Lab 31 with `contacts.email`. We'll turn the violation into a 409 the same way.
  Because our `Email` type lowercases (Lab 12), `ADA@example.com` and `ada@example.com`
  collide too, which is what we want.
- **`CHECK (role IN (...))`**. Rust's `Role` enum already makes invalid roles impossible *in
  Rust*. But people also touch the database with `psql`, scripts and migrations. The CHECK makes
  `UPDATE users SET role = 'boss'` fail:

```text
ERROR:  new row for relation "users" violates check constraint "users_role_check"
```

Why `TEXT` + `CHECK` and not a Postgres `ENUM` type? Same reasoning as `lifecycle` and `stage`
in Labs 30–31: adding a value to a TEXT/CHECK is a one-line migration, and SQLx maps it to a
plain `String` you parse with `FromStr`.

---

## Step 7 — The `users` module: types that encode policy

> 🟢 **FOLLOW ALONG**: `src/users/mod.rs`

```rust
pub mod db;
mod model;

pub use model::{NewUser, Role, User, UserId};
```

> 🟢 **FOLLOW ALONG**: `src/users/model.rs`

```rust
use crate::contacts::Email;
use crate::errors::ValidationError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type,
)]
#[sqlx(transparent)]
pub struct UserId(pub i64);

impl From<i64> for UserId {
    fn from(id: i64) -> Self {
        UserId(id)
    }
}

impl fmt::Display for UserId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{}", self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Admin,
    Manager,
    SalesRep,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Manager => "manager",
            Role::SalesRep => "sales_rep",
        }
    }
}

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Role {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "admin" => Ok(Role::Admin),
            "manager" => Ok(Role::Manager),
            "sales_rep" => Ok(Role::SalesRep),
            other => Err(ValidationError::InvalidRole(other.to_string())),
        }
    }
}

/// A user of the CRM. Note what is NOT here: the password hash.
#[derive(Debug, Clone, PartialEq)]
pub struct User {
    pub id: UserId,
    pub email: Email,
    pub name: String,
    pub role: Role,
    pub created_at: DateTime<Utc>,
}

/// What registration needs, after validation. Also no password.
#[derive(Debug, Clone)]
pub struct NewUser {
    pub email: Email,
    pub name: String,
}
```

And the new validation variant used by `Role::from_str`:

> 🟢 **FOLLOW ALONG**: `src/errors.rs`: add to `ValidationError`

```rust
    #[error("invalid role: {0}")]
    InvalidRole(String),
```

If your `ApiError` from Lab 28 matches on `ValidationError` variants to produce field names,
the compiler will now point at that `match` (E0004, non-exhaustive). Add an arm. That's the
compiler doing a review for you.

### "Types encode policy": why `User` has no `password_hash`

This is the most important design decision in the lab, and it's easy to miss because it's
about what's **not** there.

If `User` had a `password_hash` field, every function that loads a user would carry the hash
around. Then `UserResponse::from(&user)` is one careless `..` or `#[derive(Serialize)]` away
from sending hashes to the browser, and any `{:?}` of a user puts a hash in a log.

Instead:

- `User` has no hash, so `GET /me`, the admin user list (Lab 36), logs and error messages
  **can't** include one. There's nothing to include.
- The hash only appears where it's needed, **login**, and there it comes back *next to* the
  user: `find_by_email` returns `Option<(User, String)>`. The tuple is a reminder that these are
  two different things you have to handle on purpose.

Same idea as Lab 12's `Email`: instead of remembering a rule ("never return the hash"), make
the wrong thing impossible to write.

Quick unit tests for `Role`, at the bottom of `model.rs`:

> 🟢 **FOLLOW ALONG**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn role_round_trips_through_str() {
        for role in [Role::Admin, Role::Manager, Role::SalesRep] {
            assert_eq!(role.as_str().parse::<Role>(), Ok(role));
        }
    }

    #[test]
    fn unknown_role_is_a_validation_error() {
        assert_eq!(
            "superuser".parse::<Role>(),
            Err(ValidationError::InvalidRole("superuser".into()))
        );
    }

    #[test]
    fn role_serializes_as_snake_case() {
        assert_eq!(serde_json::to_string(&Role::SalesRep).unwrap(), "\"sales_rep\"");
    }
}
```

> If your `ValidationError` doesn't derive `PartialEq` (it did from Lab 12), use
> `assert!(matches!(..., Err(ValidationError::InvalidRole(r)) if r == "superuser"))` instead.

---

## Step 8 — `users::db`

Same pattern as every repository since Lab 31: a private row struct that mirrors the table, a
`TryFrom<Row>` into the domain type (re-validating on the way in), and free async functions
taking `impl PgExecutor<'_>`.

> 🟢 **FOLLOW ALONG**: `src/users/db.rs`

```rust
use super::{NewUser, Role, User, UserId};
use crate::contacts::Email;
use crate::database::corrupt;
use crate::errors::CrmError;
use chrono::{DateTime, Utc};
use sqlx::PgExecutor;

/// One row of `users` (without the hash), exactly as Postgres returns it.
struct UserRow {
    id: i64,
    email: String,
    name: String,
    role: String,
    created_at: DateTime<Utc>,
}

impl TryFrom<UserRow> for User {
    type Error = sqlx::Error;

    fn try_from(row: UserRow) -> Result<Self, Self::Error> {
        Ok(User {
            id: UserId(row.id),
            email: Email::parse(&row.email).map_err(corrupt)?,
            name: row.name,
            role: row.role.parse::<Role>().map_err(corrupt)?,
            created_at: row.created_at,
        })
    }
}

fn not_found(id: UserId) -> CrmError {
    CrmError::NotFound { entity: "user", id: id.0 }
}

pub async fn insert(
    db: impl PgExecutor<'_>,
    new: &NewUser,
    password_hash: &str,
) -> Result<User, CrmError> {
    let row = sqlx::query_as!(
        UserRow,
        "INSERT INTO users (email, name, password_hash)
         VALUES ($1, $2, $3)
         RETURNING id, email, name, role, created_at",
        new.email.as_str(),
        &new.name,
        password_hash,
    )
    .fetch_one(db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db_err) if db_err.is_unique_violation() => {
            CrmError::DuplicateEmail(new.email.to_string())
        }
        other => CrmError::Database(other),
    })?;
    Ok(row.try_into()?)
}
```

Notes:

- **`insert` takes the hash as a separate `&str`**, not inside `NewUser`. Keeping the two apart
  means a hash never ends up in a `Debug` print of the request data.
- **`RETURNING ... role, created_at`**: the database fills in the default role and timestamp.
  Ask for them back so the `User` you return is the truth, not a guess.
- **Unique violation → `CrmError::DuplicateEmail`**, which your Lab 28 `ApiError` already maps
  to **409**. Reusing the variant is fine: it means "this email is taken", whichever table it's in.
  (If your variant's message says "contact", make it neutral.)
- **`type Error = sqlx::Error` with `corrupt(...)`**: the same decision as `CompanyRow` in Lab 30.
  A row that can't become a `User` (an email that no longer parses, a role the CHECK should have
  stopped) is **corrupt data on our side**, so it becomes a 500 via `CrmError::Database`, never a 422
  telling the client *their* input was wrong. `Ok(row.try_into()?)`: the `?` converts
  `sqlx::Error → CrmError` through Lab 30's `#[from]`.
- **`DuplicateEmail`'s message.** Lab 22 wrote it as `"a contact with email {0} already exists"`.
  It now covers users too, so make it neutral in `src/errors.rs`:
  `#[error("email {0} is already in use")]`. (If a Lab 29–33 test asserts the old text, update it.
  Tests that check `error.code` are unaffected.)

`find_by_email` and `get` are **Your Turn 2**. Their signatures are fixed, because Lab 35 calls them:

```rust
pub async fn find_by_email(db: impl PgExecutor<'_>, email: &Email)
    -> Result<Option<(User, String)>, CrmError>;               // String = the PHC hash
pub async fn get(db: impl PgExecutor<'_>, id: UserId) -> Result<User, CrmError>;   // NotFound if missing
```

> 💡 SQLx macros and `query_as!`: `id.0` is passed instead of `id` because the macro checks
> parameter types against the table, and it knows `BIGINT ↔ i64`, not your newtype. The
> `not_found(id)` helper is there for `get` (Lab 30 used the same trick for companies).

---

## Step 9 — `POST /auth/register`

### The request and response DTOs

> 🟢 **FOLLOW ALONG**: create `src/http/auth.rs`

```rust
use super::error::FieldError;
use super::extract::AppJson;
use super::{ApiError, AppState};
use crate::auth::password::{self, MAX_PASSWORD_CHARS, MIN_PASSWORD_CHARS};
use crate::contacts::Email;
use crate::users::{self, NewUser, Role, User};
use axum::{Json, Router, extract::State, http::StatusCode, routing::post};
use chrono::{DateTime, Utc};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};

pub fn routes() -> Router<AppState> {
    Router::new().route("/auth/register", post(register))
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub email: String,
    pub name: String,
    pub password: SecretString,
}

#[derive(Debug, Serialize)]
pub struct UserResponse {
    pub id: i64,
    pub email: String,
    pub name: String,
    pub role: Role,
    pub created_at: DateTime<Utc>,
}

impl From<&User> for UserResponse {
    fn from(user: &User) -> Self {
        UserResponse {
            id: user.id.0,
            email: user.email.to_string(),
            name: user.name.clone(),
            role: user.role,
            created_at: user.created_at,
        }
    }
}
```

- `password: SecretString` with `#[derive(Deserialize)]` works because of secrecy's `serde`
  feature. From the moment serde parses the JSON body, the plaintext lives in a redacting box.
  `#[derive(Debug)]` on the whole request is now **safe**. You'll prove that in a test.
- `UserResponse` is built *from* `User`, which has no hash. There's nothing to leak.

> `FieldError` (pub fields `field: &'static str, message: String`, plus Lab 28's
> `FieldError::new(field, message)` helper) and the `AppJson` extractor are the ones you built in
> Lab 28. The solutions write `FieldError { field, message }` literals; `FieldError::new` is equivalent.

### The handler

> 🟢 **FOLLOW ALONG**: still in `src/http/auth.rs`

```rust
async fn register(
    State(state): State<AppState>,
    AppJson(req): AppJson<RegisterRequest>,
) -> Result<(StatusCode, Json<UserResponse>), ApiError> {
    let (new_user, password) = validate_registration(req).map_err(ApiError::Validation)?;
    let hash = password::hash_in_background(password).await?;
    let user = users::db::insert(&state.pool, &new_user, &hash).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(&user))))
}
```

Follow the password's **ownership** through those three lines:

```text
JSON body ──serde──▶ req.password: SecretString         (owned by req)
validate_registration(req)                               req MOVED in
   └─▶ returns (NewUser, SecretString)                  password MOVED out, back to us
hash_in_background(password)                             password MOVED into the blocking thread
   └─▶ dropped + zeroed there after hashing             the plaintext no longer exists anywhere
```

After line 2, the handler can't touch the plaintext again. The compiler would reject any
attempt with E0382 (use after move). Ownership makes "the password is used once, then gone"
something the compiler checks.

`validate_registration` is **Your Turn 1**. Its signature is fixed:

```rust
fn validate_registration(req: RegisterRequest) -> Result<(NewUser, SecretString), Vec<FieldError>>;
```

Until you write it, stub it so the project compiles:

```rust
fn validate_registration(_req: RegisterRequest) -> Result<(NewUser, SecretString), Vec<FieldError>> {
    todo!("Your Turn 1")
}
```

`cargo check` will warn about unused imports (`Email`, `ExposeSecret`, the two constants) until
Your Turn 1 uses them. Those warnings are your to-do list. Until then, any registration
request panics inside the handler and Axum turns that into a dropped connection, so do Your Turn 1
before ▶️ Run It.

### `AuthError` → `ApiError`

`hash_in_background(...).await?` needs a way to turn `AuthError` into `ApiError`. For now every
`AuthError` is an internal failure:

> 🟢 **FOLLOW ALONG**: `src/http/error.rs`

```rust
use crate::auth::AuthError;

impl From<AuthError> for ApiError {
    fn from(e: AuthError) -> Self {
        ApiError::Internal(e.into())
    }
}
```

`e.into()` builds an `anyhow::Error`, which works because `thiserror` gave `AuthError` a
`std::error::Error` impl and it's `Send + Sync + 'static`. Your Lab 28 `Internal` branch logs the
details and sends the client a generic 500. That's correct for "argon2 ran out of memory".

### Wire the route

> 🟢 **FOLLOW ALONG**: `src/http/mod.rs`

```rust
mod auth;
// ...
pub fn router(state: AppState) -> Router {
    Router::new()
        .merge(health::routes())
        .merge(auth::routes())
        // ... your existing .merge(...) / .nest(...) calls ...
        .with_state(state)
}
```

---

## Step 10 — Who is the first admin?

Everyone who registers becomes a `sales_rep` (the column default). There's deliberately **no**
API to self-promote. So where do admins come from?

Common answers:

| Approach | Problem |
|---|---|
| "The first user to register is admin" | Whoever finds your fresh deployment first owns it. A real attack. |
| An `ADMIN_EMAIL` env var promoted on startup | Workable. Adds config + startup logic. |
| **A one-off SQL statement run by an operator** | Simple, explicit, auditable, needs DB access (which operators have) |

We use the last one. Create the script:

> 🟢 **FOLLOW ALONG**: `scripts/make_admin.sql`

```sql
-- Promote an existing user to admin.
-- Usage: docker compose exec -T db psql -U crm -d crm -v email=you@example.com < scripts/make_admin.sql
UPDATE users SET role = 'admin' WHERE email = lower(:'email') RETURNING id, email, role;
```

`:'email'` is a **psql variable**, quoted safely by psql itself (no string concatenation, no
injection). Lab 36 builds the admin endpoints that make this script mostly unnecessary after the
first admin exists.

---

## Step 11 — Keep the offline query data current

You added `query_as!` calls, so refresh `.sqlx/` (Lab 30), or CI's `cargo sqlx prepare --check` (Lab 33) will fail:

```bash
cargo sqlx prepare -- --all-targets
git add .sqlx
```

---

## ▶️ Run It

```bash
cargo run
```

In a second terminal:

```bash
curl -i -X POST localhost:3000/auth/register \
  -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","name":"Ada Lovelace","password":"correct horse battery staple"}'

# the same email again, different case
curl -i -X POST localhost:3000/auth/register \
  -H 'content-type: application/json' \
  -d '{"email":"ADA@example.com","name":"Ada Lovelace","password":"correct horse battery staple"}'

# everything wrong at once (after Your Turn 1)
curl -X POST localhost:3000/auth/register \
  -H 'content-type: application/json' \
  -d '{"email":"nope","name":"","password":"short"}'

# what is actually stored?
docker compose exec db psql -U crm -d crm -c "SELECT id, email, role, password_hash FROM users"
```

## ✅ Expected Result

```text
HTTP/1.1 201 Created
content-type: application/json

{"id":1,"email":"ada@example.com","name":"Ada Lovelace","role":"sales_rep","created_at":"2026-10-05T15:01:49.456304Z"}
```

```text
HTTP/1.1 409 Conflict
content-type: application/json

{"error":{"code":"conflict","message":"email ada@example.com is already in use"}}
```

```json
{"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"email","message":"'nope' is not a valid email address"},{"field":"name","message":"must not be empty"},{"field":"password","message":"must be between 12 and 128 characters"}]}}
```

```text
 id |      email      |   role    |                                           password_hash
----+-----------------+-----------+---------------------------------------------------------------------------------------------------
  1 | ada@example.com | sales_rep | $argon2id$v=19$m=19456,t=2,p=1$YJhDJHuN578odkdmXm4pUw$jiwLUYsrGWrtdRJMSup7TINkX4s629qB2D1QM3g095w
```

Your ids, timestamps, salts and hashes will differ. The *messages* depend on your Lab 22/28
`Display` texts. The **status codes and shapes** must match.

Then the whole suite:

```bash
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

## 🧠 Understand It

**Why does the duplicate registration still cost a hash?** The handler hashes *before*
inserting, so a duplicate email burns ~20 ms of CPU and then fails on the UNIQUE constraint. You
could check `find_by_email` first, but that's the race from Step 6 again, plus an extra query on
the happy path. Registration is rare, so we accept the wasted hash and let the database decide.

**Why did the 409 response consume an id?** Look closely at your next registration: it gets
`id = 3`, not 2. Postgres identity columns hand out the next value *before* the insert is
checked, and a failed insert doesn't give it back. Gaps in ids are normal and harmless. Never
build logic that assumes ids are consecutive.

**`Result<(NewUser, SecretString), Vec<FieldError>>`** is the Lab 28 "parse, don't validate"
pattern again: the function *consumes* the unvalidated request and either hands back values
whose types prove they're valid (an `Email`, a non-empty name) or **all** the problems at once.
The handler never sees a half-valid user.

**Why count `chars()` and not `len()`?** `"éééééééééééé"` is 12 characters but 24 bytes
(Lab 09). A user typing 12 characters expects to meet a "12 characters" rule.

**Where does the plaintext exist?** In the request body buffer Axum read (dropped once serde
finishes), inside `SecretString` (zeroed on drop), and briefly as a `&[u8]` inside argon2. Not
in a `String` field, not in a log, not in the database, not in a response. Rust can't
make a program perfectly secret (the OS can still swap memory to disk, for example), but it can
make the *easy* mistakes impossible, and those are the ones that cause most breaches.

**Why `AuthError::Hash(#[from] argon2::password_hash::Error)`?** `thiserror`'s `#[from]`
generates `impl From<password_hash::Error> for AuthError`, which is what lets `?` convert
inside `hash_password`. Same mechanism as `CrmError::Validation(#[from] ValidationError)` in Lab 22.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: cost parameters live in the hash.** Predict: if you change the hashing
> parameters, do *existing* users' passwords still verify?
>
> Temporarily replace `Argon2::default()` in `hash_password` (only there, not in `verify_password`) with:
>
> ```rust
> Argon2::new(
>     argon2::Algorithm::Argon2id,
>     argon2::Version::V0x13,
>     argon2::Params::new(65536, 3, 1, None).unwrap(), // 64 MiB, 3 passes
> )
> ```
>
> Register a new user and compare the two rows in `psql`. What changed in the PHC string?
> Write a quick unit test: hash with the *default* parameters, verify with the code as it is
> now. Does it pass? Why doesn't `verify_password` need to know which parameters were used?
> Put `Argon2::default()` back afterwards.

> 🟡 **EXPERIMENT 2: same password, two users.** Register `bob@example.com` with *exactly*
> Ada's password. Are the two `password_hash` values related in any visible way? What would an
> attacker learn if they were equal?

> 🟡 **EXPERIMENT 3: what if you forget `spawn_blocking`?** In `register`, replace
> `password::hash_in_background(password).await?` with `password::hash_password(&password)?`.
> It compiles. Is that good news? Why can't the compiler catch this mistake when it caught the
> borrowed-closure one in Step 5? (Hint: what does the type system know about *how long* a
> function runs?) Undo the change.

> 🟡 **EXPERIMENT 4: try to leak.** In `register`, add `println!("{req:?}");` as the first
> line. Run the server and register. What appears in the server terminal? Now try
> `println!("{}", req.password);`. Which of the two did the compiler stop, and which one did
> `secrecy` make harmless? Remove both.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `validate_registration`** (in `src/http/auth.rs`, replacing the `todo!()`)
>
> ```rust
> fn validate_registration(req: RegisterRequest) -> Result<(NewUser, SecretString), Vec<FieldError>>;
> ```
>
> Rules:
>
> | Field | Rule | `FieldError.field` | Message (exactly) |
> |---|---|---|---|
> | `email` | `Email::parse` succeeds (it trims and lowercases) | `"email"` | the `ValidationError`'s `Display` text |
> | `name` | not empty after trimming. Store the **trimmed** name. | `"name"` | `must not be empty` |
> | `password` | between `MIN_PASSWORD_CHARS` and `MAX_PASSWORD_CHARS` **characters** (inclusive) | `"password"` | `must be between 12 and 128 characters` |
>
> - [ ] Collects **all** errors, in the order email, name, password. It doesn't stop at the first.
> - [ ] On success, returns the request's `SecretString` **without** cloning it
> - [ ] Unit tests in `src/http/auth.rs`: a valid request passes and its email comes back lowercased;
>       `("nope", "  ", "short")` yields exactly the fields `["email", "name", "password"]`;
>       a 12-character, 24-byte password (`"éééééééééééé"`) is accepted
> - [ ] A unit test that `format!("{:?}", request)` of a `RegisterRequest` doesn't contain the password
> - [ ] The third `curl` in ▶️ Run It returns the response in ✅ Expected Result

> 🔵 **YOUR TURN 2: `users::db::find_by_email` and `users::db::get`** (signatures in Step 8)
>
> - [ ] `find_by_email` returns `Ok(None)` for an unknown email and `Ok(Some((user, hash)))` otherwise
> - [ ] It reuses `TryFrom<UserRow>`. There's still no hash in `User`.
> - [ ] `get` returns `CrmError::NotFound { entity: "user", id }` for an unknown id
> - [ ] Uses `query!`/`query_as!` macros (and you re-run `cargo sqlx prepare -- --all-targets`)
> - [ ] Nothing calls them yet: `cargo check` must pass with **no** dead-code warnings (they're `pub`, so it will)

> 🔵 **YOUR TURN 3: registration API tests** (`tests/api/auth.rs`, add `mod auth;` to `tests/api/main.rs`)
>
> Using your Lab 33 helpers (`helpers::app(pool)`, `helpers::send`) and `#[sqlx::test]`:
>
> - [ ] `register_returns_201_and_never_the_password`: 201, `role == "sales_rep"`, the body has
>       **no** `password` and **no** `password_hash` key
> - [ ] `register_stores_an_argon2id_hash_not_the_password`: read `password_hash` straight from
>       the pool with `sqlx::query_scalar`. It starts with `$argon2id$` and doesn't contain the plaintext.
> - [ ] `duplicate_email_is_409_even_with_different_case`: `error.code == "conflict"`
> - [ ] `invalid_registration_reports_every_field`: 422 and the `fields` array names exactly `email`, `name`, `password`
> - [ ] `cargo test --test api auth` is green

> 🔵 **YOUR TURN 4: the two missing password tests** (`src/auth/password.rs`)
>
> - [ ] `wrong_password_is_ok_false`: a password differing only in letter case verifies as `Ok(false)`, **not** `Err`
> - [ ] `malformed_hash_is_an_error`: `verify_password(.., "not-a-phc-string")` is `Err(AuthError::Hash(_))`
> - [ ] Explain in a comment why these two outcomes **must** be different (think about Lab 35's status codes)

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: start with `let mut errors = Vec::new();`. Check each field and
> push. Keep the parsed email as an `Option<Email>`. At the end, `match` on
> `(email, errors.is_empty())`. Only one combination is a success.

<details><summary>Hint 2 (more specific)</summary>

- `Email::parse(&req.email)` returns `Result<Email, ValidationError>`. In the `Err(e)` arm,
  `e.to_string()` is your message (thanks to `thiserror`'s `Display`).
- `req.password.expose_secret().chars().count()` gives you the length without copying the secret out.
- `(MIN..=MAX).contains(&n)` reads better than two comparisons.
- Returning `req.password` moves the `SecretString` out of `req`. That's allowed because
  you own `req` and you've finished borrowing its other fields by then. If the compiler
  says "borrow of partially moved value", move the password **last**.

</details>

<details><summary>Hint 3 (Your Turn 2: the tuple)</summary>

`query_as!` needs a struct whose fields match the columns *exactly*, and `UserRow` has no
`password_hash`. Either make a second row struct, or use `query!` (anonymous record) and build
a `UserRow` from its fields plus keep `row.password_hash` aside. `let Some(row) = ... else { return Ok(None) };`
(Lab 11's let-else) keeps the happy path unindented.

</details>

<details><summary>Hint 4 (Your Turn 3: reading the hash in a test)</summary>

`#[sqlx::test]` hands you the `PgPool`. Clone it before giving it to `app(...)`, since `PgPool`
is a cheap `Arc` handle (Lab 27). Then:
`sqlx::query_scalar::<_, String>("SELECT password_hash FROM users WHERE email = $1").bind("ada@example.com").fetch_one(&pool)`.
The function form doesn't need `.sqlx` data, which keeps test-only queries simple.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. An attacker has your `users` table. Explain, in terms of *guesses per second*, why
   `sha256(password)` is a disaster and Argon2id isn't.
2. What does each of the five `$`-separated parts of a PHC string mean, and why does storing the
   parameters in the string matter in five years?
3. Why must `hash_password` run on `spawn_blocking`, and why does the closure have to *own* the
   `SecretString` rather than borrow it?
4. `SecretString` implements `Debug` but not `Display`. Why is that combination the right
   design?
5. Why doesn't `User` have a `password_hash` field, and where *does* the hash appear?
6. Why is the email uniqueness check in the database and not in Rust?
7. Why is "wrong password" `Ok(false)` and not an `Err`?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit
```bash
git add .
git commit -m "Add users and password hashing"
git tag lab-34
git push && git push --tags
```

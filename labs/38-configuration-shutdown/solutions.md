# Lab 38 — Solutions

> 🔴 **SOLUTION**: read these after a genuine attempt. Your version can differ and still be
> correct if it meets the acceptance criteria.

---

## Your Turn 1 — the complete `Settings::validate`

```rust
impl Settings {
    pub fn validate(&self) -> Result<(), InvalidSettings> {
        let mut problems = Vec::new();

        if self.auth.jwt_secret.expose_secret().len() < 32 {
            problems.push("auth.jwt_secret must be at least 32 bytes".to_string());
        }
        if !(1..=1440).contains(&self.auth.token_ttl_minutes) {
            problems.push(format!(
                "auth.token_ttl_minutes must be between 1 and 1440 (got {})",
                self.auth.token_ttl_minutes
            ));
        }
        if self.database.max_connections == 0 {
            problems.push("database.max_connections must be at least 1".to_string());
        }
        let url = self.database.url.expose_secret();
        if !(url.starts_with("postgres://") || url.starts_with("postgresql://")) {
            problems.push("database.url must start with postgres:// or postgresql://".to_string());
        }
        if self.server.host.trim().is_empty() {
            problems.push("server.host must not be empty".to_string());
        }
        if self.app.env == Environment::Production && self.app.log_format != LogFormat::Json {
            problems.push("app.log_format must be \"json\" in production".to_string());
        }

        if problems.is_empty() {
            Ok(())
        } else {
            Err(InvalidSettings(problems))
        }
    }
}
```

Tests, added to the existing `mod tests` (they reuse `load_with` and `SECRET` from Step 7):

```rust
#[test]
fn valid_development_settings_pass_validation() {
    assert!(load_with(&[SECRET]).unwrap().validate().is_ok());
}

#[test]
fn validate_reports_every_problem() {
    let s = load_with(&[
        ("APP__AUTH__JWT_SECRET", "short"),
        ("APP__AUTH__TOKEN_TTL_MINUTES", "0"),
        ("APP__DATABASE__MAX_CONNECTIONS", "0"),
    ])
    .unwrap();
    let err = s.validate().unwrap_err();
    assert_eq!(err.0.len(), 3, "{err}");
}

#[test]
fn production_requires_json_logs() {
    let s = load_with(&[
        ("APP_ENV", "production"),
        SECRET,
        ("APP__DATABASE__URL", "postgres://x@db/crm"),
        ("APP__APP__LOG_FORMAT", "pretty"),
    ])
    .unwrap();
    let err = s.validate().unwrap_err();
    assert!(err.to_string().contains("log_format"), "{err}");
}

#[test]
fn unknown_app_env_is_rejected() {
    let err = load_with(&[SECRET, ("APP_ENV", "staging")]).unwrap_err();
    assert!(err.to_string().contains("staging"), "{err}");
}
```

Verified output:

```text
$ APP__AUTH__JWT_SECRET=short APP__AUTH__TOKEN_TTL_MINUTES=0 cargo run
Error: invalid configuration:
  - auth.jwt_secret must be at least 32 bytes
  - auth.token_ttl_minutes must be between 1 and 1440 (got 0)
```

**Why it's written this way**

- **No early `return`.** Each rule pushes onto `problems` and moves on; the decision is made
  once at the end. Same reasoning as Lab 28's field errors: report everything in one go.
- **The URL is never in a message.** `database.url` contains the database password. Error
  messages end up in logs, CI output and Slack screenshots. We say *what's* wrong with it
  ("must start with postgres://"), not *what it is*.
- **`expose_secret()` twice, both deliberate.** The only way to read a `SecretString` is to
  call a method whose name says what you're doing. `grep expose_secret` lists every place the
  app looks at a secret.
- **Why is `APP__APP__LOG_FORMAT` double `APP`?** The first `APP` is the prefix, the second is
  the `[app]` section. It reads oddly, but it follows the rule exactly.
- **Why not reject port 0?** Because the smoke tests rely on it. A rule that breaks your own
  tests is usually a rule about the wrong thing. (A production-only rule "port ≠ 0" would be
  reasonable.)

---

## Your Turn 2 — token lifetime from configuration

`src/http/state.rs`:

```rust
use crate::auth::JwtKeys;
use chrono::TimeDelta;
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub jwt: JwtKeys,
    /// How long access tokens live (`auth.token_ttl_minutes`).
    pub token_ttl: TimeDelta,
}
```

`src/startup.rs`: add `use chrono::TimeDelta;` to the imports, then in `Application::build`:

```rust
let state = AppState {
    pool: pool.clone(),
    jwt: JwtKeys::new(&settings.auth.jwt_secret).context("invalid auth.jwt_secret")?,
    token_ttl: TimeDelta::minutes(settings.auth.token_ttl_minutes),
};
```

`src/http/auth.rs`, in `login`:

```rust
let access_token = jwt::issue(&user, &state.jwt, state.token_ttl)?;
Ok(Json(TokenResponse {
    access_token,
    token_type: "Bearer",
    expires_in: state.token_ttl.num_seconds(),
}))
```

`tests/api/helpers.rs`:

```rust
pub fn app(pool: PgPool) -> Router {
    let jwt = JwtKeys::new(&SecretString::from(TEST_JWT_SECRET)).unwrap();
    router(AppState {
        pool,
        jwt,
        token_ttl: rust_crm::auth::jwt::ACCESS_TOKEN_TTL,
    })
}
```

Verified: `APP__AUTH__TOKEN_TTL_MINUTES=60 cargo run` → login returns `"expires_in":3600`.

**Why it's written this way**

- **Convert at the edge, once.** `Settings` stores what a human writes (`token_ttl_minutes =
  15`, an integer in a TOML file). `AppState` stores what the code needs (a `TimeDelta`). The
  conversion happens in `build`, so no handler ever multiplies minutes by 60.
- **`TimeDelta` is `Copy`**, so `state.token_ttl` is read without moving anything out of the
  shared state. (`AppState` is behind `State<AppState>`, a clone per request; reading a `Copy`
  field from it is free.)
- **Adding a field broke the test helper on purpose.** Struct literals must name every field,
  so the compiler found every place `AppState` is built. If you'd used `..Default::default()`
  somewhere, this safety net would be gone.
- **`ACCESS_TOKEN_TTL` can stay** as the value tests use (and as documentation of the default).
  If you'd rather delete it, use `chrono::TimeDelta::minutes(15)` in the helper.
- `validate()` already guarantees 1–1440 minutes, so `TimeDelta::minutes` can't overflow.

---

## Your Turn 3 — shutdown test

Add to `tests/server.rs`:

```rust
#[tokio::test]
async fn server_stops_when_the_shutdown_future_completes() {
    let app = Application::build(&test_settings()).await.unwrap();
    let port = app.port();
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(app.run_until_stopped(async {
        rx.await.ok();
    }));

    // Up...
    assert!(
        reqwest::get(format!("http://127.0.0.1:{port}/health"))
            .await
            .is_ok()
    );

    // ...then down, promptly and cleanly.
    tx.send(()).unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(5), server)
        .await
        .expect("server should stop within 5 seconds")
        .expect("server task should not panic");
    assert!(result.is_ok(), "{result:?}");

    // The listener is gone: new connections are refused.
    assert!(
        reqwest::get(format!("http://127.0.0.1:{port}/health"))
            .await
            .is_err()
    );
}
```

```text
running 2 tests
test server_stops_when_the_shutdown_future_completes ... ok
test health_check_works_against_the_real_server ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```

**Why it's written this way**

- **`rx.await.ok()`**: `rx.await` is `Result<(), RecvError>`. It's `Err` if the sender is
  dropped without sending. Either way we want to shut down, so `.ok()` turns both into "done".
  That's also why, if you forget `tx.send(())`, the test *still* stops when `tx` is dropped at
  the end of the function... except the `timeout` fires first, because `tx` lives until after
  the `timeout` line. Good: the test fails in 5 s instead of hanging.
- **Three layers of `Result`**, peeled with three different meanings: `timeout` → "did it
  finish in time?", `JoinHandle` → "did the task panic?", `anyhow::Result` → "did the server
  report an error?". Writing each `expect` message forces you to say which failure you mean.
- **`is_err()` on the last request** proves the *listener* was dropped (connection refused),
  not merely that requests start failing. Port 0 plus the OS's port allocation makes it very
  unlikely another test grabs the same port in that instant.
- **Why `#[tokio::test]` and not `#[sqlx::test]`?** Nothing touches the database
  (`run_migrations = false`, lazy pool). This test runs with Docker stopped, which makes it a
  good canary in CI.

---

## Experiment answers

**Experiment 1 (port 0).** The log shows a random high port (e.g. `127.0.0.1:52817`), different
every run. Great for tests (no collisions, nothing to configure); useless for production,
because clients, load balancers and health checks need to know the port in advance.

**Experiment 2 (`kill -9`).** No "received SIGTERM", no "server stopped", no "shutdown
complete": the process vanishes. `SIGKILL` (and `SIGSTOP`) can't be caught, blocked or ignored
by any program; the kernel just removes the process. In-flight requests are cut, and Postgres
only notices the dead connections when TCP gives up. That's why your graceful shutdown must
finish inside the platform's grace period (Lab 40 tunes this for Fly.io).

**Experiment 3 (which secret wins).** The shell variable wins: `dotenvy` never overwrites a
variable that's already set. You can tell without printing anything secret: a token issued by
a server using one secret is rejected (`401 invalid access token`) by a server using the other.
`RUST_LOG=rust_crm=debug` shows `jwt_secret: SecretBox<str>([REDACTED])` either way, which is
the point.

# Lab 38 — Configuration & Graceful Shutdown

> **Phase:** 11 — Production-Ready · **Builds on:** Lab 37 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-37` · **After:** tag `lab-38`

## 🎯 Goal
Replace the scattered `std::env::var` calls with **one typed `Settings` struct**, loaded in
layers (defaults → environment file → environment variables) and validated **before the server
starts**. Then make the server **shut down cleanly** on Ctrl+C or `SIGTERM`, and restructure
startup so a test can boot the real server on a random port.

## 🧠 What You'll Learn
- Typed configuration with serde: **deserialization is validation**
- Layered config with the `config` crate, and the `APP__SECTION__KEY` naming convention
- `SecretString` inside config, and why `Debug`-printing your whole config is now safe
- Fail-fast validation that reports **every** problem at once
- Why `std::env::set_var` is `unsafe` in Rust 2024, and how to design around it
- Name collisions between your modules and crates (`::config`, `use … as …`)
- A library-level `Application` (build → port → run) so tests can start the real server on port 0
- Unix signals, `tokio::signal`, `tokio::select!`, and `axum::serve(...).with_graceful_shutdown`
- Why containers need graceful shutdown, and what `pool.close()` is for

## 🔨 What We're Building

```text
rust-crm/
├── config/
│   ├── default.toml        ← NEW: defaults for every environment (no secrets)
│   ├── development.toml    ← NEW: local overrides (APP_ENV=development, the default)
│   └── production.toml     ← NEW: production overrides (APP_ENV=production)
├── .env / .env.example     ← APP__AUTH__JWT_SECRET replaces JWT_SECRET
├── src/
│   ├── config/mod.rs       ← NEW: Settings, load(), load_from(), validate()
│   ├── startup.rs          ← NEW: Application { build, port, run_until_stopped }
│   ├── shutdown.rs         ← NEW: shutdown_signal() (Ctrl+C + SIGTERM)
│   ├── lib.rs              ← pub async fn run(settings)
│   ├── main.rs             ← 10 lines: load → validate → run
│   ├── database/mod.rs     ← + connect_lazy(&DatabaseSettings)
│   ├── telemetry.rs        ← LogFormat becomes Deserialize; from_env() deleted
│   └── http/state.rs       ← 🔵 + token_ttl
└── tests/server.rs         ← NEW: the real server on port 0
```

Look at how your CRM is configured today. `main.rs` reads `DATABASE_URL` and `JWT_SECRET`;
`telemetry.rs` reads `LOG_FORMAT`; the port is `PORT` or a hard-coded 3000; the token
lifetime is a `const` in `jwt.rs`; `max_connections(5)` is buried in `database/mod.rs`. Each
was a reasonable decision when it was made. Together they're a problem, and Lab 40 (Docker +
deployment) will need to change most of them **without recompiling**.

And when you stop the server today, it just dies: whatever requests were in flight get their
connections cut. That's about to matter, because a container platform stops your app every time
you deploy.

Written against **config 0.15**, **secrecy 0.10**, **tokio 1**, **axum 0.8** and **reqwest 0.13**
(dev-dependency).

---

## Step 1 — What's wrong with `env::var` everywhere?

```bash
grep -rn "env::var\|const .*TTL\|max_connections\|127.0.0.1:3000" src/
```

Take `JWT_SECRET` as an example of what happens today:

| Problem | Today |
|---|---|
| **Where** is the config? | Spread across three files. To learn what the app needs, you read all the code. |
| **Types** | Everything is a `String`. Parsing happens wherever someone remembered to parse. |
| **When** do errors appear? | Whenever that line runs. A typo in a rarely-used variable explodes at 3 a.m., not at deploy time. |
| **Defaults** | Ad hoc: some vars have them (`unwrap_or(3000)`), some don't. |
| **Testing** | A test that wants a different port has to mutate the *process* environment. |

The fix is a pattern you already know from Lab 28: **parse at the boundary into a type that
can't be invalid**. There, the boundary was an HTTP request and the type was `NewContact`.
Here, the boundary is process startup and the type is `Settings`.

## Step 2 — The design

```text
               lowest priority                                   highest priority
  config/default.toml  ──▶  config/{APP_ENV}.toml  ──▶  APP__* environment variables
  (committed, defaults)     (committed, per env)        (deployment-specific, secrets)
                                       │
                                       ▼
                         serde deserializes into Settings  ──▶  Settings::validate()
                                                                      │
                                                     Err: print every problem, exit 1
                                                     Ok:  start the server
```

- **Files** hold *non-secret* values that you're happy to commit and review in a PR.
- **Environment variables** hold anything that differs per deployment, and **all secrets**.
  That's the [12-factor app](https://12factor.net/config) rule, and every container platform
  (Docker, Fly.io, Kubernetes, Railway…) is built around it.
- `APP_ENV` (`development` by default, or `production`) picks the middle file.

**Naming.** A nested key like `auth.jwt_secret` becomes `APP__AUTH__JWT_SECRET`: a prefix
(`APP`), then the path, with **double** underscores as separators. Why double? Because key names
themselves contain single underscores (`jwt_secret`, `max_connections`). With a single `_` as
separator, `APP_AUTH_JWT_SECRET` would be ambiguous: `auth.jwt.secret`? `auth_jwt.secret`?

## Step 3 — Add the crates

```bash
cargo add config --no-default-features --features toml
cargo add secrecy --features serde
```

- `config` (0.15) merges sources and hands the result to serde. Its default features enable
  six file formats (TOML, JSON, YAML, INI, RON, JSON5). We only need TOML, so we opt out of the
  rest: fewer dependencies, faster builds.
- `secrecy`'s `serde` feature implements `Deserialize` for `SecretString`. If you enabled it in
  Lab 34 (for `LoginRequest`), this command changes nothing, and that's fine.

## Step 4 — The `Settings` types

> 🟢 **FOLLOW ALONG**: create `src/config/mod.rs`, and add `pub mod config;` to `src/lib.rs`.

```rust
//! Typed, layered configuration.
//!
//! Layers (later wins): `config/default.toml` → `config/{APP_ENV}.toml` → `APP__...` env vars.

use crate::telemetry::LogFormat;
use ::config::{Config, ConfigError, Environment as EnvVars, File};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use std::{collections::HashMap, fmt, path::Path, str::FromStr};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub app: AppSettings,
    pub server: ServerSettings,
    pub database: DatabaseSettings,
    pub auth: AuthSettings,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppSettings {
    pub env: Environment,
    pub log_format: LogFormat,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServerSettings {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DatabaseSettings {
    pub url: SecretString,
    pub max_connections: u32,
    pub run_migrations: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthSettings {
    pub jwt_secret: SecretString,
    pub token_ttl_minutes: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    Development,
    Production,
}

impl Environment {
    pub fn as_str(self) -> &'static str {
        match self {
            Environment::Development => "development",
            Environment::Production => "production",
        }
    }
}

impl fmt::Display for Environment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Environment {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "development" | "dev" => Ok(Environment::Development),
            "production" | "prod" => Ok(Environment::Production),
            other => Err(format!(
                "unknown APP_ENV '{other}' (expected 'development' or 'production')"
            )),
        }
    }
}

impl ServerSettings {
    pub fn address(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}
```

`LogFormat` lives in `telemetry.rs` and now needs to be deserializable. Update it, and delete
`LogFormat::from_env()` (Settings replaces it):

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogFormat {
    #[default]
    Pretty,
    Json,
}
```

### Deserialization *is* validation

Notice what's **not** in this code: no `parse::<u16>()`, no "is the port in range?", no "is
`log_format` one of pretty/json?", no "is `run_migrations` a bool?". The **types** say it:

| Field type | What serde guarantees by the time you have a `Settings` |
|---|---|
| `port: u16` | A number from 0 to 65535. `"http"` and `70000` are rejected. |
| `env: Environment` | Exactly `development` or `production` |
| `log_format: LogFormat` | Exactly `pretty` or `json` |
| `url: SecretString` | Present (no `Option`), and it will never be printed by `Debug` |
| `#[serde(deny_unknown_fields)]` | A key that matches no field is an **error**, not silently ignored. `max_conections = 10` (typo) fails loudly. |

This is the "parse, don't validate" idea again: once a `Settings` value exists, the rest of the
program never re-checks these things.

### Two names called `config`

Our module is `crate::config`, and the crate we depend on is also called `config`. Inside
`src/config/mod.rs`, `use config::Config;` would actually work (there's no item named `config`
*inside* this module), but it reads ambiguously. The leading `::` in `use ::config::…` means
"the **crate** named `config`, not anything in my module tree". It costs two characters and
removes all doubt.

> 🟡 **EXPERIMENT**: change the import to `use ::config::{Config, ConfigError, Environment, File};`
> (without `as EnvVars`). Predict, then `cargo check`.

```text
error[E0255]: the name `Environment` is defined multiple times
  --> src/config/mod.rs:51:1
   |
 6 | use ::config::{Config, ConfigError, Environment, File};
   |                                     ----------- previous import of the type `Environment` here
...
51 | pub enum Environment {
   | ^^^^^^^^^^^^^^^^^^^^ `Environment` redefined here
   |
   = note: `Environment` must be defined only once in the type namespace of this module
help: you can use `as` to change the binding name of the import
   |
 6 | use ::config::{Config, ConfigError, Environment as OtherEnvironment, File};
   |                                                 +++++++++++++++++++
```

The `config` crate has a type called `Environment` (an environment-variable *source*); we have
an enum called `Environment` (development/production). A module has one namespace for types,
so both can't be called `Environment` there. `use … as EnvVars` renames the import locally,
which also documents what it *is*. (You'll also see an E0117 follow-on error: the derive now
thinks it's implementing traits for the crate's type. Fix the first error and it disappears.
Always read compiler errors top-down.) Put the `as EnvVars` back.

## Step 5 — Loading: `load()` and `load_from()`

> 🟢 **FOLLOW ALONG**: add to `src/config/mod.rs`:

```rust
/// Loads settings from `./config` and the real process environment.
pub fn load() -> Result<Settings, ConfigError> {
    load_from(Path::new("config"), std::env::vars().collect())
}

/// Same as [`load`], but with the directory and the environment variables passed in.
/// Tests use this so they never have to touch the real (global, shared) environment.
pub fn load_from(dir: &Path, vars: HashMap<String, String>) -> Result<Settings, ConfigError> {
    let env: Environment = match vars.get("APP_ENV") {
        Some(value) => value.parse().map_err(ConfigError::Message)?,
        None => Environment::Development,
    };

    Config::builder()
        .add_source(File::from(dir.join("default.toml")))
        .add_source(File::from(dir.join(format!("{env}.toml"))))
        .add_source(
            EnvVars::with_prefix("APP")
                .prefix_separator("__")
                .separator("__")
                .source(Some(vars)),
        )
        .set_override("app.env", env.as_str())?
        .build()?
        .try_deserialize()
}
```

Line by line:

- **`APP_ENV` is read first**, because it decides which file to load. It's parsed into our
  `Environment` enum immediately: `APP_ENV=staging` fails here, with our own message, wrapped
  in `ConfigError::Message`.
- **`add_source` order is priority order.** Later sources override earlier ones, key by key.
  `File::from(PathBuf)` infers the format from the `.toml` extension. Both files are
  **required**: a missing `config/production.toml` in a Docker image should stop startup, not
  silently fall back to development defaults.
- **`EnvVars::with_prefix("APP")`** only looks at variables starting with `APP__`
  (`prefix_separator`), strips that prefix, lowercases the rest, and turns `__` into `.`:
  `APP__AUTH__JWT_SECRET` → `auth.jwt_secret`.
- **`.source(Some(vars))`** makes the environment source read from *our map* instead of the
  real process environment. `load()` passes the real environment; tests pass a hand-made map.
- **`set_override("app.env", …)`**: `app.env` always equals the `APP_ENV` we used to pick the
  file, so the two can never disagree.
- **`try_deserialize()`** hands the merged tree to serde. Every type check from Step 4 happens
  here.

### Why not just `std::env::set_var` in tests?

> 🟡 **EXPERIMENT**: add this test to `src/config/mod.rs` and run `cargo test --no-run`.

```rust
#[cfg(test)]
mod set_var_demo {
    #[test]
    fn port_from_env() {
        std::env::set_var("APP__SERVER__PORT", "9000");
    }
}
```

```text
error[E0133]: call to unsafe function `set_var` is unsafe and requires unsafe block
   --> src/config/mod.rs:121:9
    |
121 |         std::env::set_var("APP__SERVER__PORT", "9000");
    |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ call to unsafe function
    |
    = note: consult the function's documentation for information on how to avoid undefined behavior
```

In edition 2024, `set_var` and `remove_var` are `unsafe`. The process environment is **one
global, mutable table shared by every thread**, and on most platforms reading it while another
thread writes it is undefined behaviour (it can crash inside libc). `cargo test` runs tests on
many threads at once, so "test A sets a variable while test B reads the environment" is exactly
that situation. Wrapping it in `unsafe { }` would only be you promising the compiler something
you can't guarantee.

The design answer is to **not need global state**: `load_from` takes the variables as a plain
`HashMap` that each test owns. Delete the demo test.

## Step 6 — The config files and `.env`

> 🟢 **FOLLOW ALONG**: create the `config/` directory **at the repository root** (next to
> `Cargo.toml`, not in `src/`).

`config/default.toml`:

```toml
# Defaults for every environment. Never put secrets in this file.
# Layering (later wins): default.toml -> {APP_ENV}.toml -> APP__SECTION__KEY env vars.

[app]
log_format = "pretty"

[server]
host = "127.0.0.1"
port = 3000

[database]
# url: no default on purpose. development.toml or APP__DATABASE__URL must provide it.
max_connections = 5
run_migrations = true

[auth]
# jwt_secret: no default on purpose. Comes from APP__AUTH__JWT_SECRET (.env in development).
token_ttl_minutes = 15
```

`config/development.toml`:

```toml
# Overrides for APP_ENV=development (the default when APP_ENV is unset).

[database]
# The docker compose database from Lab 30. Only valid on your laptop, so not a secret.
url = "postgres://crm:crm@localhost:5432/crm"
```

`config/production.toml`:

```toml
# Overrides for APP_ENV=production. Secrets come from APP__... environment variables.

[app]
log_format = "json"

[server]
host = "0.0.0.0"
port = 8080

[database]
run_migrations = true
```

(`0.0.0.0` means "every network interface". You need it inside a container; Lab 40 explains
why. On your laptop, `127.0.0.1` keeps the CRM off the café Wi-Fi.)

Now `.env`. It currently holds `DATABASE_URL` and `JWT_SECRET`. Change it to:

```bash
# Used by tools only (sqlx-cli, sqlx::query! at compile time, #[sqlx::test]). The app ignores it.
DATABASE_URL=postgres://crm:crm@localhost:5432/crm

# Read by the app through config::load(): APP__<SECTION>__<KEY>
APP__AUTH__JWT_SECRET=<your existing JWT_SECRET value>
```

Make the same change to `.env.example` (with a placeholder secret). Check `.env` is still in
`.gitignore`.

Two subtleties:

- **`DATABASE_URL` stays**, but only for *tools*. `sqlx::query!` connects to it at compile
  time, `cargo sqlx prepare` and `sqlx migrate` use it, and `#[sqlx::test]` creates its test
  databases on that server. The *application* now gets its URL from `database.url`.
- **`dotenvy` never overrides a variable that's already set.** So the effective order is:
  real environment > `.env` > `{APP_ENV}.toml` > `default.toml`. That's what you want:
  `APP__SERVER__PORT=4000 cargo run` beats anything in `.env`.

## Step 7 — Test the loading rules

> 🟢 **FOLLOW ALONG**: add a test module at the bottom of `src/config/mod.rs`. (Unit tests run
> with the package root as the current directory, so `Path::new("config")` finds your files.)

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: (&str, &str) = (
        "APP__AUTH__JWT_SECRET",
        "test-secret-that-is-at-least-32-bytes!",
    );

    fn load_with(pairs: &[(&str, &str)]) -> Result<Settings, ConfigError> {
        let vars = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        load_from(Path::new("config"), vars)
    }

    #[test]
    fn development_defaults_load() {
        let s = load_with(&[SECRET]).expect("settings should load");
        assert_eq!(s.app.env, Environment::Development);
        assert_eq!(s.server.port, 3000);
        assert_eq!(s.app.log_format, LogFormat::Pretty);
    }

    #[test]
    fn production_file_overrides_defaults() {
        let s = load_with(&[
            ("APP_ENV", "production"),
            SECRET,
            ("APP__DATABASE__URL", "postgres://x@db/crm"),
        ])
        .unwrap();
        assert_eq!(s.server.port, 8080);
        assert_eq!(s.server.host, "0.0.0.0");
        assert_eq!(s.app.log_format, LogFormat::Json);
    }

    #[test]
    fn env_vars_override_files() {
        let s = load_with(&[
            SECRET,
            ("APP__SERVER__PORT", "9000"),
            ("APP__DATABASE__RUN_MIGRATIONS", "false"),
        ])
        .unwrap();
        assert_eq!(s.server.port, 9000);
        assert!(!s.database.run_migrations);
    }

    #[test]
    fn missing_secret_is_an_error() {
        let err = load_with(&[]).unwrap_err();
        assert!(err.to_string().contains("jwt_secret"), "{err}");
    }

    #[test]
    fn invalid_port_is_rejected_by_deserialization() {
        let err = load_with(&[SECRET, ("APP__SERVER__PORT", "99999")]).unwrap_err();
        assert!(err.to_string().contains("port"), "{err}");
    }

    #[test]
    fn typo_in_key_is_rejected() {
        let err = load_with(&[SECRET, ("APP__DATABASE__MAX_CONECTIONS", "10")]).unwrap_err();
        assert!(err.to_string().contains("max_conections"), "{err}");
    }

    #[test]
    fn secrets_are_redacted_in_debug_output() {
        let s = load_with(&[SECRET]).unwrap();
        let debug = format!("{s:?}");
        assert!(!debug.contains("test-secret"), "{debug}");
        assert!(!debug.contains("crm:crm"), "{debug}");
    }
}
```

```bash
cargo test --lib config
```

```text
running 7 tests
test config::tests::missing_secret_is_an_error ... ok
test config::tests::typo_in_key_is_rejected ... ok
test config::tests::env_vars_override_files ... ok
test config::tests::invalid_port_is_rejected_by_deserialization ... ok
test config::tests::development_defaults_load ... ok
test config::tests::production_file_overrides_defaults ... ok
test config::tests::secrets_are_redacted_in_debug_output ... ok

test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; … filtered out; finished in 0.00s
```

Every test builds its own `HashMap`, so they can run in parallel without interfering. Notice
`"9000"` and `"false"`: environment variables are always strings, and `config` converts them
to the field's type during deserialization.

The last test is worth a second look: `database.url` contains a password (`crm:crm@…`), and
`SecretString`'s `Debug` prints `[REDACTED]`. So **logging the entire `Settings` is safe**,
which you'll do in a moment.

## Step 8 — Fail fast: `validate()`

Some rules can't be expressed as a type, or involve several fields at once: "the JWT secret
must be at least 32 bytes", "in production, logs must be JSON". Those go in a separate
`validate` step that runs right after loading.

Two design choices, both from Lab 28:

1. **Report every problem, not just the first.** If a deployment has three wrong variables, you
   want three lines in the first failed deploy, not three failed deploys.
2. **Stop before doing anything.** No database connection, no port bound, no half-started
   server.

> 🟢 **FOLLOW ALONG**: add the error type and the method (with ONE rule for now) to
> `src/config/mod.rs`:

```rust
/// Every problem found by [`Settings::validate`], not just the first.
#[derive(Debug, thiserror::Error)]
#[error("invalid configuration:\n  - {}", .0.join("\n  - "))]
pub struct InvalidSettings(pub Vec<String>);

impl Settings {
    pub fn validate(&self) -> Result<(), InvalidSettings> {
        let mut problems = Vec::new();

        if self.auth.jwt_secret.expose_secret().len() < 32 {
            problems.push("auth.jwt_secret must be at least 32 bytes".to_string());
        }
        // 🔵 Your Turn 1 adds the other rules here.

        if problems.is_empty() {
            Ok(())
        } else {
            Err(InvalidSettings(problems))
        }
    }
}
```

`#[error("…{}", .0.join(…))]`: thiserror's format string can call methods on fields. `.0` is
the `Vec<String>`. `expose_secret()` is the one deliberate, greppable place where we look at the
secret's bytes.

> Yes, Lab 35's `JwtKeys::new` already refuses short secrets. Keep that check: it protects the
> type wherever it's constructed. `validate()` is about *reporting*: it puts the problem in the
> same list as every other configuration mistake, before anything starts.

Commit this milestone once the crate compiles again: you'll need Step 9's `main.rs`, and Step
10's `src/shutdown.rs` (Step 9's `run` already calls it).

## Step 9 — One place that builds the app: `Application`

Today `main` does everything: read env vars, connect, migrate, build state, bind, serve. That
makes it impossible to test the *real* startup path: a test can call `http::router(state)`
(Lab 29's `oneshot` tests), but not the listener, the middleware stack as served, or shutdown.

We'll split startup into **build** (everything that can fail: pool, migrations, port) and
**run** (serve until told to stop), as a library type the tests can use.

> 🟢 **FOLLOW ALONG**: first, a lazily-connected pool in `src/database/mod.rs` (keep `connect`
> as it is):

```rust
use crate::config::DatabaseSettings;
use secrecy::ExposeSecret;

/// Builds the pool WITHOUT connecting. The first query opens the first connection.
/// Only fails if the URL can't be parsed.
pub fn connect_lazy(settings: &DatabaseSettings) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(settings.max_connections)
        .connect_lazy(settings.url.expose_secret())
}
```

> 🟢 **FOLLOW ALONG**: create `src/startup.rs`:

```rust
//! Building and running the whole application. `main.rs` and the tests both use this.

use crate::{
    auth::JwtKeys,
    config::Settings,
    database,
    http::{self, AppState},
};
use anyhow::Context;
use axum::Router;
use sqlx::PgPool;
use std::future::Future;
use tokio::net::TcpListener;

pub struct Application {
    listener: TcpListener,
    router: Router,
    pool: PgPool,
    port: u16,
}

impl Application {
    /// Everything that can fail at startup happens here, before we accept a single request.
    pub async fn build(settings: &Settings) -> anyhow::Result<Self> {
        let pool =
            database::connect_lazy(&settings.database).context("invalid database settings")?;
        if settings.database.run_migrations {
            database::migrate(&pool)
                .await
                .context("running database migrations")?;
        }

        let state = AppState {
            pool: pool.clone(),
            jwt: JwtKeys::new(&settings.auth.jwt_secret).context("invalid auth.jwt_secret")?,
        };

        let address = settings.server.address();
        let listener = TcpListener::bind(&address)
            .await
            .with_context(|| format!("could not bind to {address}"))?;
        let port = listener.local_addr()?.port();

        Ok(Application {
            listener,
            router: http::router(state),
            pool,
            port,
        })
    }

    /// The port we actually bound to. With `port = 0` the OS picks a free one.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Serves requests until `shutdown` completes, waits for in-flight requests,
    /// then closes the database pool.
    pub async fn run_until_stopped<F>(self, shutdown: F) -> anyhow::Result<()>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        tracing::info!(address = %self.listener.local_addr()?, "listening");

        axum::serve(self.listener, self.router)
            .with_graceful_shutdown(shutdown)
            .await
            .context("server error")?;

        tracing::info!("server stopped, closing database pool");
        self.pool.close().await;
        tracing::info!("shutdown complete");
        Ok(())
    }
}
```

(If your `JwtKeys::new` returns `Self` rather than a `Result`, drop the `.context(…)?`.)

Ownership notes, because they're the point of the design:

- **`run_until_stopped(self, …)` takes `self` by value.** Serving *consumes* the listener and
  router, and once it returns the application is finished. After calling it, you can't call
  `port()` or run it twice: the compiler enforces the lifecycle. That's why tests read
  `app.port()` **before** calling `run_until_stopped`.
- **`pool.clone()`** into `AppState`: a `PgPool` is an `Arc` inside (Lab 27). Cloning is a
  reference-count increment. Both the router and `Application` hold a handle to the same pool.
- **`F: Future<Output = ()> + Send + 'static`**: the caller decides *what* "stop" means. `main`
  passes the OS-signal future (Step 10); a test passes a channel. `Send + 'static` because
  axum may move it to another thread and it must not borrow anything from our stack (Lab 26).

### Why a *lazy* pool?

`connect` (Lab 30) opens a connection immediately and fails if Postgres is down. `connect_lazy`
only validates the URL; connections are opened on first use. Combined with `run_migrations`:

- **`run_migrations = true`** (development and production): `migrate` needs a connection, so
  startup still fails fast if the database is unreachable.
- **`run_migrations = false`**: the server starts without touching the database. `/health`
  answers; a route that needs the DB returns a 500 until Postgres is back. That's the right
  behaviour for a liveness check (Lab 40), and it lets the smoke test in Step 11 run without
  Postgres at all.

> 🟢 **FOLLOW ALONG**: register the module and add the top-level `run` in `src/lib.rs`:

```rust
pub mod shutdown; // you'll write it in Step 10
mod startup;

pub use startup::Application;

/// Runs the whole CRM until Ctrl+C / SIGTERM: telemetry, database, HTTP server.
pub async fn run(settings: config::Settings) -> anyhow::Result<()> {
    telemetry::init(settings.app.log_format);
    tracing::info!(env = %settings.app.env, "starting rust-crm");
    tracing::debug!(?settings, "effective settings");

    let app = Application::build(&settings).await?;
    app.run_until_stopped(shutdown::shutdown_signal()).await
}
```

`startup` is private: the public API is `rust_crm::Application` (re-exported) and
`rust_crm::run`. And `tracing::debug!(?settings, …)` logs the **entire** configuration,
safely, because of `SecretString`. When a deployment misbehaves, "what config did it actually
run with?" is the first question; now it's answered in the log at DEBUG level.

And `src/main.rs` shrinks to:

```rust
use anyhow::Context;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Development convenience: copy the variables in .env into the process environment.
    // A missing .env (production, CI, Docker) is not an error.
    dotenvy::dotenv().ok();

    let settings = rust_crm::config::load().context("failed to load configuration")?;
    settings.validate()?;

    rust_crm::run(settings).await
}
```

Notice `telemetry::init` now happens **after** configuration loads (the log format *is*
configuration). Configuration errors therefore go through `anyhow`'s `main` error printing on
stderr, not through `tracing`. That's fine: if config is broken, there's no log format to
honour yet. (`RUST_LOG` stays an environment variable on purpose: it's a universal Rust
convention that tools and people expect.)

Finally, remove the leftovers: `grep -rn "env::var" src/` should now find only `config::load`
(`std::env::vars()`). Delete the `ACCESS_TOKEN_TTL` usage only after Your Turn 2.

## Step 10 — Graceful shutdown

### What "stopping a server" looks like in production

You deploy a new version. The platform (Docker, Kubernetes, Fly.io…) starts the new container
and then stops the old one, like this:

```text
platform ──SIGTERM──▶ your process        "please stop"
          … waits a grace period (10 s in Docker, 5 s on Fly by default) …
platform ──SIGKILL──▶ your process        "you're dead", cannot be caught
```

If your process ignores `SIGTERM`, every deploy kills it mid-request after the grace period: a
user's "save deal" gets a connection reset. A well-behaved server, on `SIGTERM`:

1. **stops accepting** new connections (the load balancer is already sending them elsewhere),
2. **finishes** the requests it's already handling,
3. **releases resources**: closes database connections cleanly (Postgres doesn't have to wait
   for TCP timeouts to notice), flushes logs,
4. exits with status 0, well before the grace period ends.

On your laptop, Ctrl+C sends `SIGINT`, which should get the same treatment.

> 🟢 **FOLLOW ALONG**: create `src/shutdown.rs`:

```rust
//! Turning OS signals into a future that completes when we should stop.

/// Completes when the process receives Ctrl+C (SIGINT) or, on Unix, SIGTERM.
pub async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to listen for Ctrl+C");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to listen for SIGTERM")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => tracing::info!("received Ctrl+C, shutting down"),
        () = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}
```

- **Two futures, raced.** `tokio::select!` polls both and runs the branch of whichever finishes
  first, then **drops** the other. You met `select!` with autosave in Lab 26.
- **`async { … }` blocks** create futures without running anything (futures are lazy). The
  signal handlers are installed the first time each block is polled, inside `select!`.
- **`#[cfg(unix)]`**: `SIGTERM` is a Unix concept. On Windows the `terminate` future is
  `pending()`, a future that never completes, so only Ctrl+C can win. Both arms have type
  `impl Future<Output = ()>`, so the `select!` compiles on every platform.
- **`.expect(...)`**: failing to install a signal handler happens at startup and means the
  process can't be stopped cleanly. Crashing loudly is the right call; this is one of the few
  places an `expect` in server code is justified.

`axum::serve(...).with_graceful_shutdown(signal)` (already in `run_until_stopped`) does steps 1
and 2: when `signal` completes, axum stops accepting, lets in-flight requests finish, then
`.await` returns. Step 3 is `self.pool.close().await`, which waits for checked-out connections
to be returned and closes them all.

```bash
cargo run
# Ctrl+C
```

```text
2026-10-05T14:52:57.844225Z  INFO rust_crm: starting rust-crm env=development
2026-10-05T14:52:57.844429Z DEBUG rust_crm: effective settings settings=Settings { app: AppSettings { env: Development, log_format: Pretty }, server: ServerSettings { host: "127.0.0.1", port: 3000 }, database: DatabaseSettings { url: SecretBox<str>([REDACTED]), max_connections: 5, run_migrations: true }, auth: AuthSettings { jwt_secret: SecretBox<str>([REDACTED]), token_ttl_minutes: 15 } }
2026-10-05T14:52:57.857564Z  INFO rust_crm::startup: listening address=127.0.0.1:3000
^C2026-10-05T14:52:58.989186Z  INFO rust_crm::shutdown: received Ctrl+C, shutting down
2026-10-05T14:52:58.989417Z  INFO rust_crm::startup: server stopped, closing database pool
2026-10-05T14:52:58.989504Z  INFO rust_crm::startup: shutdown complete
```

### Prove that in-flight requests survive

> 🟡 **EXPERIMENT**: make `/health` slow on purpose. In `src/http/health.rs`, add
> `tokio::time::sleep(std::time::Duration::from_secs(5)).await;` as the first line of the
> handler. Start the server, then in a second terminal:
>
> ```bash
> curl -s -w ' %{http_code} after %{time_total}s\n' localhost:3000/health &
> sleep 1; kill -TERM $(pgrep -x rust-crm)
> sleep 0.3; curl -s localhost:3000/health; echo "new request: curl exit=$?"
> ```
>
> Predict: does the first request get an answer? Does the second?

```text
new request: curl exit=7
{"status":"ok"} 200 after 5.004880s
```

And the server log:

```text
2026-10-05T14:53:17.982385Z  INFO rust_crm::startup: listening address=127.0.0.1:3000
2026-10-05T14:53:19.794055Z  INFO rust_crm::shutdown: received SIGTERM, shutting down
2026-10-05T14:53:23.763741Z  WARN request{method=GET path=/health request_id=256355c3-e574-423f-9d24-1622a855d8b9}: rust_crm::http: slow request status=200 latency_ms=5003
2026-10-05T14:53:23.765305Z  INFO rust_crm::startup: server stopped, closing database pool
2026-10-05T14:53:23.765666Z  INFO rust_crm::startup: shutdown complete
```

The in-flight request finished (4 seconds *after* the signal); the new one was refused
(`curl` exit 7 = couldn't connect) because the listener was already closed.

> 🟡 **EXPERIMENT (continued)**: now delete the `.with_graceful_shutdown(shutdown)` line, rebuild
> and repeat. What does the first `curl` get?

```text
 000 after 1.032444s
new request: curl exit=7
```

`000` means no HTTP response at all, after ~1 s instead of 5: the first `curl` itself exits
with code `52`, "empty reply from server" (add `; echo $?` after it to see). `SIGTERM`'s default
action killed the process instantly, mid-request, with no log line at all. That's what every deploy did to your users until now.
Restore the line and remove the `sleep` from `/health`.

## Step 11 — Start the real server in a test

> 🟢 **FOLLOW ALONG**:

```bash
cargo add --dev reqwest --no-default-features --features json
```

(`--no-default-features` skips TLS: we only talk plain HTTP to `127.0.0.1`, and reqwest's
default TLS backend needs a C toolchain to build.)

Create `tests/server.rs`:

```rust
//! Starts the REAL server (TCP listener, router, middleware) on a random port.

use rust_crm::{Application, config};
use std::{collections::HashMap, path::Path};

fn test_settings() -> config::Settings {
    let vars: HashMap<String, String> = [
        ("APP__SERVER__PORT", "0"),
        ("APP__DATABASE__RUN_MIGRATIONS", "false"),
        (
            "APP__AUTH__JWT_SECRET",
            "test-secret-that-is-at-least-32-bytes!",
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    let settings = config::load_from(Path::new("config"), vars).expect("test settings should load");
    settings.validate().expect("test settings should be valid");
    settings
}

#[tokio::test]
async fn health_check_works_against_the_real_server() {
    let app = Application::build(&test_settings())
        .await
        .expect("app should build");
    let port = app.port();
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(app.run_until_stopped(async {
        rx.await.ok();
    }));

    let response = reqwest::get(format!("http://127.0.0.1:{port}/health"))
        .await
        .expect("request should succeed");

    assert_eq!(response.status(), 200);
    assert!(response.headers().contains_key("x-request-id"));
    let body: serde_json::Value = response.json().await.unwrap();
    assert_eq!(body, serde_json::json!({ "status": "ok" }));

    tx.send(()).unwrap();
    server.await.unwrap().unwrap();
}
```

- **Port 0** asks the OS for any free port. Tests can run in parallel without fighting over
  3000, and the test asks the `Application` which port it got.
- **The shutdown future is a oneshot channel.** `rx.await` completes when the test calls
  `tx.send(())`. Same `run_until_stopped`, different trigger: that's the payoff of taking the
  shutdown condition as a parameter.
- **`tokio::spawn(app.run_until_stopped(...))`** runs the server as a task while the test acts
  as the client. `server.await.unwrap().unwrap()`: the first `unwrap` is "the task didn't
  panic" (`JoinError`), the second is "the server returned `Ok`".
- **No database needed**: `run_migrations = false` plus the lazy pool means nothing connects.
  This test passes even with Docker stopped.
- No `telemetry::init` here: only `main` (via `run`) installs the global subscriber.

```bash
cargo test --test server
```

```text
running 1 test
test health_check_works_against_the_real_server ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```

---

## ▶️ Run It

```bash
docker compose up -d db
cargo run                                     # development, pretty logs, port 3000
APP__SERVER__PORT=4000 cargo run              # env var beats the files
APP_ENV=production APP__DATABASE__URL=postgres://crm:crm@localhost:5432/crm cargo run
```

Stop each with Ctrl+C. Then try to break it:

```bash
APP__SERVER__PROT=4000 cargo run              # typo
APP__SERVER__PORT=70000 cargo run             # out of range
APP_ENV=staging cargo run                     # unknown environment
mv .env .env.bak && cargo run; mv .env.bak .env     # no secret
```

## ✅ Expected Result

The production run logs JSON on port 8080:

```text
{"timestamp":"2026-10-05T15:07:21.630628Z","level":"INFO","message":"starting rust-crm","env":"production","target":"rust_crm"}
{"timestamp":"2026-10-05T15:07:21.631150Z","level":"DEBUG","message":"effective settings","settings":"Settings { app: AppSettings { env: Production, log_format: Json }, server: ServerSettings { host: \"0.0.0.0\", port: 8080 }, database: DatabaseSettings { url: SecretBox<str>([REDACTED]), max_connections: 5, run_migrations: true }, auth: AuthSettings { jwt_secret: SecretBox<str>([REDACTED]), token_ttl_minutes: 15 } }","target":"rust_crm"}
{"timestamp":"2026-10-05T15:07:21.644801Z","level":"INFO","message":"listening","address":"0.0.0.0:8080","target":"rust_crm::startup"}
```

Each broken run exits with status 1 **before** binding a port or touching the database:

```text
Error: failed to load configuration

Caused by:
    unknown field `prot`, expected `host` or `port` for key `server`
```

```text
Error: failed to load configuration

Caused by:
    invalid type: 64-bit unsigned integer `70000`, expected an unsigned 16 bit integer for key `server.port`
```

```text
Error: failed to load configuration

Caused by:
    unknown APP_ENV 'staging' (expected 'development' or 'production')
```

```text
Error: failed to load configuration

Caused by:
    missing configuration field "auth.jwt_secret"
```

And `cargo test` passes: your config tests, the `server` smoke test, and every API/DB test
from Labs 33–36.

## 🧠 Understand It

**Two kinds of validation.** `Deserialize` checks **shape and type** (is it a `u16`? one of
these enum values? present?). `validate()` checks **rules** that need logic or several fields.
Keep as much as possible in the types: a rule in a type can't be forgotten; a rule in
`validate()` only runs if someone calls it (here: `main` and the test helper, and nowhere else
needs to).

**Why `Settings` isn't passed around everywhere.** `Application::build` *reads* settings and
turns them into the things the app actually uses: a pool sized by `max_connections`, `JwtKeys`
from the secret, a bound listener. Handlers never see `Settings`. They get exactly what they
need through `AppState` (Your Turn 2 adds the token lifetime). That keeps the knowledge of
"where values come from" in one module.

**The shutdown sequence, as ownership:**

```text
main ──owns──▶ Settings ──&──▶ Application::build ──▶ Application { listener, router, pool }
                                                            │ run_until_stopped(self, signal)
                                                            ▼
                     axum::serve(listener, router) ── owns both until signal completes
                                                            │ in-flight requests finish
                                                            ▼
                                       pool.close().await ── connections closed
                                                            ▼
                                       Application dropped, Ok(()) returned, exit 0
```

Nothing is closed "somewhere, eventually" by a garbage collector. Each resource is released
at a point you can read in the code.

**`select!` cancels by dropping.** When `ctrl_c` wins, the `terminate` future is dropped
mid-wait. For a signal listener that's harmless. Lab 39 will ask a sharper question: what if
the losing future was in the middle of a database update?

**Exit codes matter.** `main` returning `Err` makes the process exit with status 1. Container
platforms treat non-zero as "crashed" (restart, alert, fail the deploy). Bad config is exactly
the kind of failure you want the platform to notice immediately.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: `APP__SERVER__PORT=0 cargo run`. Which port does the log say? Run it
> twice. Why is port 0 great for tests and useless for production?

> 🟡 **EXPERIMENT 2**: with the server running, run `kill -9 $(pgrep -x rust-crm)`. Which log
> lines are missing compared to `kill -TERM`? Can any program handle `SIGKILL`? (This is what
> the platform does when your graceful shutdown takes longer than the grace period.)

> 🟡 **EXPERIMENT 3**: set `APP__AUTH__JWT_SECRET` in your shell to a different value than the
> one in `.env`, and run `RUST_LOG=rust_crm=debug cargo run`. Which one wins, and how can you
> tell without printing the secret? (Hint: log in with a token issued by the other one.)

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: complete `Settings::validate`.** Add these rules, collecting **all**
> problems (never return early):
>
> | Rule | Message (exact wording is up to you) |
> |---|---|
> | `auth.jwt_secret` ≥ 32 bytes | (already there) |
> | `auth.token_ttl_minutes` between 1 and 1440 | include the bad value |
> | `database.max_connections` ≥ 1 | |
> | `database.url` starts with `postgres://` or `postgresql://` | **never** include the URL itself in the message (why?) |
> | `server.host` not empty or whitespace | |
> | in `Environment::Production`, `app.log_format` must be `json` | |
>
> Acceptance:
> - [ ] Unit tests in `src/config/mod.rs`: valid development settings pass; a settings value
>       with three broken fields returns an `InvalidSettings` with **three** entries; production
>       with `APP__APP__LOG_FORMAT=pretty` fails with a message mentioning `log_format`.
> - [ ] `APP__AUTH__JWT_SECRET=short APP__AUTH__TOKEN_TTL_MINUTES=0 cargo run` prints both
>       problems and exits 1:
>       ```text
>       Error: invalid configuration:
>         - auth.jwt_secret must be at least 32 bytes
>         - auth.token_ttl_minutes must be between 1 and 1440 (got 0)
>       ```

> 🔵 **YOUR TURN 2: the token lifetime comes from config.** `auth.token_ttl_minutes` is
> loaded but nothing uses it: login still uses the `ACCESS_TOKEN_TTL` constant from Lab 35.
>
> - Add `pub token_ttl: chrono::TimeDelta` to `AppState` and fill it in `Application::build`.
> - `login` issues tokens with `state.token_ttl`, and `expires_in` reflects it.
> - Fix every place that constructs `AppState` (the compiler will list them, including
>   `tests/api/helpers.rs`).
>
> Acceptance:
> - [ ] `APP__AUTH__TOKEN_TTL_MINUTES=60 cargo run`, then `POST /auth/login` → `"expires_in":3600`.
> - [ ] Default config → `"expires_in":900`.
> - [ ] All API tests still pass.

> 🔵 **YOUR TURN 3: test graceful shutdown.** In `tests/server.rs`, write
> `server_stops_when_the_shutdown_future_completes`:
>
> - Start the app on port 0 with a oneshot-channel shutdown, and check `/health` answers.
> - Send the shutdown signal. The server task must finish **within 5 seconds** and return
>   `Ok(())`. (A shutdown that hangs must fail the test, not hang the test suite.)
> - Afterwards, a new request to the same port must **fail** (the listener is gone).
>
> Acceptance:
> - [ ] `cargo test --test server` runs 2 tests, both pass, in well under a second.
> - [ ] Temporarily remove `tx.send(())` from your test: it fails after ~5 s instead of hanging
>       forever. Put it back.

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `(1..=1440).contains(&value)` reads better than two comparisons.
> To test "three problems", load settings with three bad `APP__…` values through `load_with`;
> they all deserialize fine (they're valid *types*), and then `validate()` rejects them.

<details><summary>Hint 2 (Your Turn 2)</summary>

`chrono::TimeDelta::minutes(i64)`. `issue(&user, &state.jwt, state.token_ttl)` and
`state.token_ttl.num_seconds()`. In the test helper you can keep using
`rust_crm::auth::jwt::ACCESS_TOKEN_TTL` as the value: tests don't need to read config.

</details>

<details><summary>Hint 3 (Your Turn 3)</summary>

`tokio::time::timeout(Duration::from_secs(5), server)` wraps the `JoinHandle` (which is itself
a future). It returns `Err(Elapsed)` if the time runs out. Three nested results come back:
timeout → join → your `anyhow::Result`. A failed connection shows up as
`reqwest::get(...).await.is_err()`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Name three mistakes that `Deserialize` alone catches in `Settings`, and one that only
   `validate()` can catch.
2. Why are environment variables named `APP__AUTH__JWT_SECRET` and not `APP_AUTH_JWT_SECRET`?
3. Why is `std::env::set_var` `unsafe` in Rust 2024, and how does `load_from` avoid needing it?
4. In what order do `SIGTERM`, "stop accepting", "in-flight requests finish" and
   `pool.close()` happen? What happens to a request that arrives after the signal?
5. Why does `run_until_stopped` take `self` by value, and the shutdown condition as a
   parameter?
6. What does `DATABASE_URL` in `.env` do now that the app reads `database.url`?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit

Two commits: one once Steps 9–10 compile (configuration works), one at the end.

```bash
git add .
git commit -m "Add layered configuration"
# ... Step 11 and Your Turns ...
git add .
git commit -m "Add graceful shutdown"
git tag lab-38
git push && git push --tags
```

# Lab 40 — Solutions

> 🔴 **SOLUTION**: read these after a genuine attempt. Each one explains *why* it's written
> this way. Your version can differ and still be correct if it meets the acceptance criteria.

---

## Mini-task 1 — `GET /ready`

Add to `src/http/health.rs`, next to your Lab 27 `/health` handler:

```rust
use std::time::Duration;

use axum::{Json, extract::State, http::StatusCode};
use serde_json::{Value, json};

use super::AppState; // or crate::http::AppState, depending on your module layout

const READY_TIMEOUT: Duration = Duration::from_secs(2);

/// Readiness: "can this instance do useful work right now?"
pub async fn ready(State(state): State<AppState>) -> (StatusCode, Json<Value>) {
    let check = sqlx::query("SELECT 1").execute(&state.pool);

    match tokio::time::timeout(READY_TIMEOUT, check).await {
        Ok(Ok(_)) => (StatusCode::OK, Json(json!({ "status": "ready" }))),
        Ok(Err(error)) => {
            tracing::warn!(%error, "readiness check failed: database error");
            unavailable()
        }
        Err(_elapsed) => {
            tracing::warn!(timeout = ?READY_TIMEOUT, "readiness check failed: database timed out");
            unavailable()
        }
    }
}

fn unavailable() -> (StatusCode, Json<Value>) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({ "status": "unavailable" })),
    )
}
```

Register it wherever `/health` is registered, on the **public** router (outside the
`route_layer(require_auth)` from Lab 35):

```rust
.route("/health", get(health::health))
.route("/ready", get(health::ready))
```

**Why it's written this way**

- **`sqlx::query("SELECT 1")`, not `query!`**: there's nothing to type-check, and the function
  form doesn't need a `.sqlx/` entry. (`query!` would work too after `cargo sqlx prepare`.)
- **`execute(&state.pool)`**: `&PgPool` implements `PgExecutor`, so we borrow the pool and
  don't clone it. The query only needs the pool for the duration of the call.
- **The future isn't run until it's awaited.** `check` is just a value (Lab 26: futures are
  lazy). `timeout` takes ownership of it and polls it, and if 2 s pass first, it **drops** the
  future, which cancels the acquire/query. Cancellation by drop is the async version of RAII.
- **Why the timeout is essential:** a `PgPool` that can't reach Postgres keeps retrying until
  `acquire_timeout`, which is **30 s** by default in sqlx. We measured this while verifying the
  lab: with a pool pointed at a dead port, a bare `.execute(&pool)` returned `PoolTimedOut`
  after 30.0 s. With the timeout, `/ready` answers `503` in 2.0 s. A readiness probe that hangs
  longer than the platform's check timeout is reported as "failed" anyway, so you'd only be
  tying up a connection slot and a task.
- **Return type `(StatusCode, Json<Value>)`**: both arms produce the same concrete type, so no
  `impl IntoResponse` gymnastics are needed. It isn't routed through `ApiError` because a 503
  here is the *correct answer to the question*, not an error in handling the request.
- **The error is logged, not returned.** `/ready` is public. A `sqlx::Error` can include host
  names, database names or user names. Logs are for operators. Response bodies are for anyone
  on the internet.

### Tests (in `tests/api/`, e.g. a new `health.rs` registered in `tests/api/main.rs`)

```rust
use axum::{body::Body, http::{Request, StatusCode}};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::time::Duration;

use crate::helpers;

#[sqlx::test]
async fn health_is_ok(pool: PgPool) {
    let app = helpers::app(pool);
    let req = Request::get("/health").body(Body::empty()).unwrap();
    let (status, body) = helpers::send(app, req).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");
}

#[sqlx::test]
async fn ready_is_ok_with_a_healthy_database(pool: PgPool) {
    let app = helpers::app(pool);
    let req = Request::get("/ready").body(Body::empty()).unwrap();
    let (status, body) = helpers::send(app, req).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ready");
}

#[tokio::test]
async fn ready_is_503_and_health_still_ok_when_database_is_unreachable() {
    // Nothing listens on port 1: connections are refused. connect_lazy never connects up front.
    let dead = PgPoolOptions::new()
        .acquire_timeout(Duration::from_secs(5))
        .connect_lazy("postgres://crm:crm@127.0.0.1:1/crm")
        .unwrap();

    let req = Request::get("/ready").body(Body::empty()).unwrap();
    let (status, body) = helpers::send(helpers::app(dead.clone()), req).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["status"], "unavailable");

    let req = Request::get("/health").body(Body::empty()).unwrap();
    let (status, _) = helpers::send(helpers::app(dead), req).await;
    assert_eq!(status, StatusCode::OK);
}
```

The third test is a plain `#[tokio::test]` because it deliberately has *no* working database.
It takes about 2 s (the readiness timeout). If your `helpers::app` builds `AppState` with
settings or JWT keys, it works unchanged, since `connect_lazy` gives a perfectly valid `PgPool`
value that just can't connect.

---

## Mini-task 2 — `.dockerignore`

```text
# Build output: huge, and rebuilt inside the image anyway
target/

# VCS and CI metadata: large, and change constantly (cache busting)
.git/
.github/

# Secrets and local environment: NEVER in the build context
.env
.env.*
!.env.example

# Local noise
*.log
.DS_Store
.vscode/

# Files about the image, not inputs to it
Dockerfile
.dockerignore
docker-compose.yml
fly.toml
```

**Why**

- `target/` is the big one: it's often 2–10 GB, and sending it makes every build start with a
  long "transferring context". It's useless anyway, because macOS build artefacts can't run on
  Linux.
- `.env*`: the context is sent to the builder in full. Even if no `COPY` line picks the file
  up, a future `COPY . .` (and we have two!) **would copy it into a layer**. In our Dockerfile
  the planner and builder stages both `COPY . .`, so without this line `.env` would be in the
  builder images. Those don't ship, but they live in your local cache and in CI caches.
  Exclude it at the source.
- `.git/` changes on every commit. Because the planner does `COPY . .`, any change in the
  context invalidates that layer. The planner is cheap, but there's no reason to make it
  re-run for a commit that changed nothing in the build.
- **Not excluded, on purpose:** `.sqlx/` (needed by `SQLX_OFFLINE`), `migrations/` (read by
  `migrate!()` at compile time), `config/` (copied into the runtime image), `Cargo.lock`
  (reproducible builds), and `src/`/`tests/`/`examples/`/`benches/` if they're declared
  targets (cargo-chef's recipe includes them, so they must exist).
- Excluding `Dockerfile` from the context is fine: the builder reads the Dockerfile
  separately from the context.

---

## Mini-task 3 — compose `api` service

```yaml
  api:
    build: .
    image: rust-crm:local
    depends_on:
      db:
        condition: service_healthy
    environment:
      APP__DATABASE__URL: postgres://crm:crm@db:5432/crm
      APP__AUTH__JWT_SECRET: ${JWT_SECRET:?Set JWT_SECRET in .env (at least 32 characters)}
      RUST_LOG: ${RUST_LOG:-rust_crm=info,tower_http=info,sqlx=warn}
    ports:
      - "8080:8080"
    restart: unless-stopped
```

and in `.env` (gitignored) / `.env.example` (committed, empty value):

```dotenv
JWT_SECRET=
```

**Why**

- **`db:5432`**: compose registers each service under its name in the project network's DNS.
  From inside `api`, `localhost` is the `api` container itself. `ports: "5432:5432"` on `db`
  is only for *your Mac*. Container-to-container traffic doesn't need it.
- **`condition: service_healthy`** waits for `pg_isready` to pass. Plain `depends_on: [db]`
  only waits for the container process to *start*.
- **`${JWT_SECRET:?msg}`** makes a missing secret a **startup error in compose itself**,
  before any container exists. This error was verified with `docker compose config`:
  `required variable JWT_SECRET is missing a value: …`. Lab 38's `Settings::validate()` is the
  second line of defence (for example, it rejects a secret that's too short).
- **`${RUST_LOG:-default}`** supplies an overridable default. **`image:`** + `build:` names the built image.
- **`restart: unless-stopped`**: if the API exits (say Postgres was mid-restart and fail-fast
  kicked in), compose restarts it, but it respects an explicit `docker compose stop`.
- The DB password `crm` in this file is a **local development** value, the same one as in Lab
  30. It isn't a secret, and it must never be your production password.

---

## Your Turn 1 — CI `docker` job

Add at the top level of `ci.yml` (if not already there):

```yaml
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
```

and the job (the `needs:` value must match your existing test job's id; ours is `test`):

```yaml
  docker:
    name: Docker image
    runs-on: ubuntu-latest
    needs: test
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v4

      - name: Image name and tags
        id: meta
        uses: docker/metadata-action@v6
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=sha
            type=raw,value=latest,enable={{is_default_branch}}
            type=semver,pattern={{version}}

      - name: Log in to GitHub Container Registry
        if: github.event_name == 'push'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build (and push on main / tags)
        uses: docker/build-push-action@v7
        with:
          context: .
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

(Passes `actionlint` together with a Lab-33-style `test` job. Not executed on GitHub while authoring.)

**Why**

- **`needs: test`**: never publish an image whose tests failed.
- **`permissions`**: by default `GITHUB_TOKEN` may get broad permissions, depending on repo
  settings. Declaring them per job is least privilege: this job can read code and write packages.
- **Push only on `push` events.** Pull requests from forks don't get a write-capable token,
  and you don't want unreviewed code published anyway. They still *build*, which catches a
  broken Dockerfile or stale `.sqlx/` before merge.
- **`metadata-action`** maps git refs to tags (`sha-1a2b3c4`, `latest` on the default branch,
  `1.0.0` from tag `v1.0.0`) and lowercases the image name. GHCR rejects uppercase, and
  `github.repository` keeps your username's casing.
- **`cache-from/to: type=gha`** stores BuildKit layers in the Actions cache. Combined with
  cargo-chef, a CI build after a source-only change reuses the `cook` layer. `mode=max`
  caches the layers of intermediate stages (planner, builder) too, which is exactly where the
  expensive dependency layer lives. The default `min` only caches the final image's layers.
- The `test` job keeps `SQLX_OFFLINE=true` (Lab 33). The Dockerfile sets it itself, so the
  docker job needs no database service.
- GHCR packages start **private**. Make the package public if you want anonymous pulls.

---

## Your Turn 2 — README skeleton

Yours should be in your own words. This is the shape, plus an example architecture diagram:

````markdown
# Rust CRM

A B2B CRM backend written in Rust: companies, contacts, leads, a deals pipeline, activities
and notes, behind a JWT-authenticated REST API on PostgreSQL, with background jobs.

[![CI](https://github.com/<you>/rust-crm/actions/workflows/ci.yml/badge.svg)](https://github.com/<you>/rust-crm/actions/workflows/ci.yml)
**Live:** https://rust-crm-<you>.fly.dev (`/health`, `/ready`)

## Features
- …
## Architecture

```text
            HTTPS
client ──────────────▶ axum Router ── TraceLayer + request id
                          │
             public: /health /ready /auth/*
             protected: require_auth ─▶ AuthUser extractor ─▶ policy::can()
                          │
                     handlers (src/http/*)      DTO ⇄ domain (TryFrom)
                          │
                     domain (models, Email, Money, DealStage, Lead::convert)
                          │
                     db modules (src/*/db.rs, impl PgExecutor) ──▶ PostgreSQL
                                                                      ▲
scheduler ── enqueue ──▶ jobs table ── SKIP LOCKED ──▶ worker ─────────┘
                                                         └──▶ Mailer (LogMailer)
```

<!-- then: a short tour of src/, and the sections Running locally · Configuration ·
     API overview · Testing · Deployment · Design decisions -->
````

A good test of your README: clone the repo into a temp directory, follow the README **only**,
and fix every place you had to "just know" something.

---

## Experiment answers

**Step 2 (a): why did a profile change rebuild every dependency?** The profile is part of
every crate's build fingerprint. `codegen-units` and `lto` change how *each* crate is compiled
(with LTO, crates are emitted as LLVM bitcode for the linker to optimise), so every cached
artefact in `target/release` is invalid.

**Step 2 (b): why are incremental release builds slower?** With `codegen-units = 1` your crate
can't be split across CPU cores, and thin LTO runs an optimisation pass across *all* crates at
link time, on every build, even if only one file changed. That's why we use these settings for
release builds only. Your everyday `cargo build`/`cargo test` uses the `dev` profile.

**Step 4: is `.env` in the image?** Without `.dockerignore`: `.env` is sent in the context,
and `COPY . .` in the planner and builder stages copies it into **those** stages' layers. The
runtime stage copies only the binary and `config/`, so it's not in the final image. But it
*is* in intermediate images in your build cache, and in any CI cache exported with
`mode=max`. "Not in the final image" is not the same as "not leaked".

**Step 5: `cargo add uuid`.** `Cargo.toml`/`Cargo.lock` changed, so `recipe.json` changed, so
`COPY --from=planner … recipe.json` is a cache miss, and everything after it (including
`cook`) re-runs. Dependency changes are rare. Source changes are constant. The layer order
puts the expensive step behind the input that changes least often.

**Step 5: trixie builder + bookworm runtime.** The binary fails at startup with an error like
`rust-crm: /lib/…/libc.so.6: version 'GLIBC_2.39' not found (required by rust-crm)` (the
exact version depends on which newer symbols the linker picked). The image *builds* fine. It
only fails when it runs, which is why the base images are pinned as a pair.

**Step 5: `id`.** `uid=10001(crm) gid=10001(crm) groups=10001(crm)` (the system user gets a
matching group). `touch /usr/local/bin/x` fails with `Permission denied`: the process can't
modify its own binary.

**Step 6: shell-form `CMD`.** `sh` is PID 1 and doesn't forward `SIGTERM`, so your app never
learns it should stop. Docker waits the full 10 s grace period, then sends `SIGKILL` to
everything. No shutdown logs, no drain, and a job in progress is abandoned mid-way (it'll be
retried after its lock expires, thanks to Lab 39's design, but it shouldn't have to be).

**Step 7c: do migrations run again on restart?** No. sqlx records each applied migration
(version + checksum) in `_sqlx_migrations` and applies only the missing ones. If you *edit* an
already-applied migration file, the checksum no longer matches and startup fails, which is
deliberate: applied migrations are history, so you add a new one instead.

**Experiment 1 (kill the database).** `/ready` flips to `503` within one probe. The process
**doesn't** restart, and it shouldn't: nothing is wrong with it. When Postgres comes back, the
pool reconnects on demand, and `/ready` returns `200` on the next probe after the DB accepts
connections. Requests that needed the DB during the outage got `500`s (Lab 28's `Internal`);
on a real platform, readiness would have steered traffic to healthy instances, if there were any.

**Experiment 2 (secrets in layers).** `docker history` shows the full `ENV` instruction with the
value. Removing the line and rebuilding produces a *new* image, but the old image, and every
copy pushed to a registry or pulled by a server, still contains it. The only real fix is to
**rotate the secret**. Deleting tags is hygiene, not remediation.

**Experiment 3 (`strip`).** With `strip = true`, backtrace frames show as `<unknown>`. With
`strip = "debuginfo"`, you get function names (`rust_crm::http::…`) but no file/line numbers.
Many teams choose `"debuginfo"` for services: a slightly bigger binary is a fair price for
readable incident logs.

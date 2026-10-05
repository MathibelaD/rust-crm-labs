# Lab 40 — Docker & Deployment

> **Phase:** 11 — Production-Ready · **Builds on:** Lab 39 · **Time:** ~5–6 hours (plus image build time)
> **Your repo before this lab:** tag `lab-39` · **After:** tags `lab-40` and `v1.0.0`

## 🎯 Goal

Package the CRM as a small, secure container image, run the whole stack (API + Postgres) with
one `docker compose up`, build the image in CI, and deploy it to the internet. Then write the
README your CRM deserves and tag **v1.0.0**.

## 🧠 What You'll Learn

- What `cargo build --release` actually produces: what's **statically** linked into a Rust
  binary, what's **dynamically** linked (glibc), and why that decides your runtime image
- Release profile settings (`lto`, `codegen-units`, `strip`) and what each one costs you
- Multi-stage Dockerfiles, layer caching, and why **`cargo-chef`** matters so much for Rust
- Building `sqlx` query macros with **no database** (`SQLX_OFFLINE` + `.sqlx/`)
- Running as a **non-root** user; PID 1 and signals (why `CMD ["rust-crm"]` and not `CMD rust-crm`)
- **Liveness vs readiness**: `/health` vs `/ready`
- Migrations on startup vs a separate release step, and why both can be correct
- Compose healthchecks and `depends_on: condition: service_healthy`
- A CI job that builds (and publishes) the image
- Deploying to a container host (worked example: **Fly.io**) and managing secrets

## 🔨 What We're Building

```text
rust-crm/
├── Cargo.toml               ← [profile.release] tuned, version = "1.0.0"
├── Dockerfile               ← NEW: chef → planner → builder → runtime
├── .dockerignore            ← NEW (🔵 you write it)
├── docker-compose.yml       ← db gets a healthcheck; NEW api service (🔵 you write it)
├── fly.toml                 ← NEW (Fly.io only; generated, then edited)
├── config/production.toml   ← listens on 0.0.0.0:8080, JSON logs, migrations on
├── src/http/health.rs       ← /health stays; NEW /ready (🔵 you write it)
├── .github/workflows/ci.yml ← NEW docker job (🔵 you write it)
└── README.md                ← rewritten as a real project README (🔵 you write it)
```

Up to now the CRM runs on *your* machine, with *your* toolchain, *your* `.env` and a Postgres
you started by hand. A deployment target has none of those. This lab is about making every one
of those hidden assumptions explicit.

> This lab assumes your repo is at `lab-39`: typed `Settings` loaded from `config/*.toml` +
> `APP__…` environment variables (Lab 38), `database.run_migrations`, graceful shutdown on
> SIGINT/SIGTERM (Lab 38), the job worker and scheduler (Lab 39), and committed `.sqlx/` query
> data (Lab 30, kept fresh in Lab 33's CI check). If something is missing, see those labs'
> `solutions.md`.

**Docker Desktop must be running** for Steps 4–7 (you've used it since Lab 30 for Postgres).
The Fly.io section (Step 9) needs a Fly.io account with a payment method on file; there are
alternatives in Step 9 if you'd rather not.

---

## Step 1 — What does `cargo build --release` actually produce?

Before writing a Dockerfile, you need a clear picture of the thing you're shipping.

When you run `cargo build --release`, Cargo compiles **every crate in `Cargo.lock`** (axum,
tokio, sqlx, serde, argon2, …) and your own code into machine code, and the linker glues all of
it into **one executable file**: `target/release/rust-crm`. Rust crates are linked
**statically**. No `node_modules`, no `.jar` files, no Rust runtime has to exist on the server.

That's not the whole story, though. On Linux, the default target (`x86_64-unknown-linux-gnu`
or `aarch64-unknown-linux-gnu`) links the **C standard library, glibc, dynamically**. Rust's
`std` calls into libc for threads, sockets, files, DNS resolution and memory allocation. So
the binary says "I need `libc.so.6`, version X or newer" and the operating system's dynamic
loader has to supply it at startup.

> 🟢 **FOLLOW ALONG**: look at your own binary's dynamic dependencies.

```bash
cargo build --release
ls -lh target/release/rust-crm
otool -L target/release/rust-crm      # macOS
# ldd target/release/rust-crm         # Linux
```

On macOS you'll see something like this (from an axum + sqlx build, verified on macOS arm64):

```text
target/release/rust-crm:
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (...)
	/usr/lib/libiconv.2.dylib (...)
	/usr/lib/libSystem.B.dylib (...)
```

`libSystem` is macOS's libc. Inside a Linux container `ldd` shows the same idea:

```text
	linux-vdso.so.1
	libgcc_s.so.1 => /lib/aarch64-linux-gnu/libgcc_s.so.1
	libm.so.6 => /lib/aarch64-linux-gnu/libm.so.6
	libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6
	/lib/ld-linux-aarch64.so.1
```

(On x86-64 the paths say `x86_64-linux-gnu`. You'll run this for real in Step 5's experiment.)

Every crate you've ever `cargo add`-ed is gone from that list. It's all inside the one file.
What's left is the operating system's C runtime. That has three consequences, and they shape
the whole Dockerfile:

1. **You can't use an empty (`scratch`) image** for a `-gnu` binary. There's no `libc.so.6`
   in it, and the binary won't even start.
2. **glibc is backwards compatible, not forwards compatible.** A binary built against glibc
   2.36 runs on 2.36 or newer. A binary built against 2.41 may *refuse to start* on 2.36 with
   `version 'GLIBC_2.39' not found`. So **build on the same distro release you run on** (or an older one).
3. **TLS needs trust roots.** To talk TLS to a managed Postgres (or to an email API later), a
   program needs CA certificates. Some crates bundle them, and others read the OS store at
   `/etc/ssl/certs`. You'll see which is which in Step 4.

**Why not a fully static binary?** You can build for `x86_64-unknown-linux-musl` and get a
binary with no dynamic dependencies at all, which runs in `scratch`. It's a legitimate choice.
The costs: musl's memory allocator is noticeably slower under multi-threaded load (people
often swap in `mimalloc` or `jemalloc`), DNS behaves slightly differently, and cross-compiling
crates with C code gets fiddly. For a web service the few megabytes you'd save over
`debian:bookworm-slim` aren't worth it. Know that the option exists.

## Step 2 — Tune the release profile

`--release` already turns on optimisations (`opt-level = 3`). Three more knobs trade
**build time** for **binary quality**.

> 🟢 **FOLLOW ALONG**: add to `Cargo.toml`:

```toml
[profile.release]
lto = "thin"         # link-time optimisation across crates
codegen-units = 1    # optimise each crate as one unit
strip = true         # remove symbols and debug info from the binary
```

While you're in `Cargo.toml`, this is the release you'll tag at the end of the lab:

```toml
[package]
name = "rust-crm"
version = "1.0.0"
```

| Setting | What it does | What you gain | What you pay |
|---|---|---|---|
| `lto = "thin"` | Lets the optimiser inline and drop dead code **across crate boundaries** (your code + tokio + sqlx…) | Smaller, often faster binary | Longer link step. `"fat"` gains a little more for a lot more time |
| `codegen-units = 1` | Compiles each crate as one unit instead of splitting it into 16 parallel chunks | Better optimisation | Less parallelism, so slower release builds |
| `strip = true` | Removes the symbol table and debug info | Much smaller file | **Panics and backtraces lose function names.** `strip = "debuginfo"` keeps names and drops only line info |

Two settings you might see in blog posts and that we deliberately **don't** use:

- `panic = "abort"`: a panic kills the **whole process** instead of unwinding. Right now a panic
  inside one request's task is caught by Tokio, that connection fails, and the server keeps
  serving everyone else. With `abort`, one bad request takes the CRM down.
- `opt-level = "z"`: optimise for size. Useful for embedded and WASM, but a slower server is a
  bad trade for a few megabytes.

> 🟡 **EXPERIMENT**: predict first, then measure.
>
> 1. Before adding the profile, `cargo build --release` and note the size of
>    `target/release/rust-crm` and roughly how long the build took.
> 2. Add the profile, `touch src/main.rs`, build again, and compare.
>
> For reference, a small axum + sqlx skeleton went from **5.8 MB to 3.6 MB** on macOS arm64
> with these settings, and the full release build took about a minute. Your CRM is larger,
> but the ratio should be similar.
>
> **Questions:** (a) Changing `[profile.release]` recompiled **every dependency**, not just
> your crate. Why? (b) After that, `touch src/main.rs` and build once more, with and without
> the profile. Why is an incremental release build slower with `lto = "thin"` +
> `codegen-units = 1`, even though only one file changed? (Answers in `solutions.md`.)

## Step 3 — Make the server container-shaped

Two things work on your laptop and silently break in a container.

### 3a. Listen on `0.0.0.0`, not `127.0.0.1`

`127.0.0.1` means "only connections from *this* network namespace". Inside a container that
is the container itself. Docker's port publishing (`-p 8080:8080`) forwards traffic into the
container's network interface, *not* its loopback, so a server bound to `127.0.0.1` inside a
container is unreachable from outside. Nothing crashes. You just get `connection reset`.

> 🟢 **FOLLOW ALONG**: open `config/production.toml` (from Lab 38) and check that it contains
> these values. If you followed Lab 38, it already does, so there's nothing to change:

```toml
[app]
log_format = "json"

[server]
host = "0.0.0.0"
port = 8080

[database]
run_migrations = true
```

`config/development.toml` should keep `host = "127.0.0.1"`. On your laptop you don't want the
CRM reachable from the café Wi-Fi. That's exactly what layered config is for.

**Secrets are not in this file.** `database.url` and `auth.jwt_secret` stay out of every
committed TOML file. In production they come from `APP__DATABASE__URL` and
`APP__AUTH__JWT_SECRET`, and your Lab 38 `Settings::validate()` already refuses to start
without them. You'll rely on that fail-fast behaviour in Step 7.

### 3b. `/health` vs `/ready`

You've had `GET /health` since Lab 27. Platforms ask your service two different questions:

| | **Liveness**: `/health` | **Readiness**: `/ready` |
|---|---|---|
| Question | "Is the process alive and able to answer HTTP?" | "Can this instance do useful work *right now*?" |
| Checks | Nothing external | Its critical dependencies (here: Postgres) |
| If it fails | The orchestrator **restarts** the container | The load balancer **stops sending traffic** to it, but doesn't restart it |
| Must be | Cheap, and never touches the DB | Fast, and has a **timeout** |

Why must liveness *not* check the database? Imagine Postgres is down for 30 seconds. If
`/health` checked the DB, every API instance would fail liveness, get restarted, and come back
into the same outage, possibly all at once and hammering Postgres as it recovers. The API
processes were fine. Their dependency wasn't. That's a readiness problem, and the right
response is "stop routing traffic to me for a moment".

> 🔵 **YOUR TURN (mini-task 1)**: add `GET /ready` to `src/http/health.rs`.
>
> Requirements:
> - It runs `SELECT 1` against the pool in `AppState`.
> - It responds `200 {"status":"ready"}` if that succeeds, and `503 {"status":"unavailable"}`
>   if it fails **or takes longer than 2 seconds**.
> - On failure it logs a `tracing::warn!` with the reason. The **response body must not
>   contain the error**. (Why? Think about who can call `/ready`.)
> - It's on the **public** router next to `/health`. Load balancers don't have JWTs.
> - `/health` is unchanged and still never touches the database.
> - Add API tests: `/health` → 200 and `/ready` → 200 with a healthy pool (your
>   `#[sqlx::test]` helpers from Lab 33 make this a few lines).
>
> 💡 Why the explicit timeout? A `PgPool` that can't connect doesn't fail immediately. It
> **retries until `acquire_timeout`**, which defaults to **30 seconds** in sqlx. We measured it:
> without our own timeout, a `/ready` call during a DB outage hangs for 30 s. Look at
> `tokio::time::timeout`.
>
> Solution: [`solutions.md` → Mini-task 1](solutions.md#mini-task-1--get-ready).

Run it locally against your compose Postgres:

```bash
docker compose up -d db
cargo run
# in another terminal
curl -i localhost:3000/ready      # or whatever port development.toml uses
docker compose stop db
curl -i localhost:3000/ready      # takes ~2 s, then 503
docker compose start db
```

## Step 4 — The Dockerfile, one stage at a time

### Why a naïve Dockerfile hurts

The "obvious" Dockerfile is:

```dockerfile
FROM rust:1
COPY . .
RUN cargo build --release
CMD ["./target/release/rust-crm"]
```

It has three problems:

1. **The image is huge.** The full Rust toolchain plus `target/` is over a gigabyte, all to
   ship one binary of a few dozen megabytes. It's also a big attack surface: a compiler and
   your source code end up on the production server.
2. **Every code change rebuilds every dependency.** Docker caches layers, and a layer is
   reused only if its inputs are unchanged. `COPY . .` copies `src/`, so *any* edit
   invalidates that layer and the `cargo build` after it. That means recompiling tokio, axum,
   sqlx, argon2 and ~300 other crates from scratch: **several minutes, every time**. Your own
   code is a tiny fraction of that build.
3. **`sqlx::query!` needs a database at compile time**, and there isn't one inside `docker build`.

The fix for 1 is **multi-stage builds**: compile in a big image, then copy just the binary
into a small one. The fix for 2 is to build the dependencies in their own layer, keyed only on
`Cargo.toml` + `Cargo.lock`. Cargo has no built-in "build only my deps" command, and that's
the gap **[cargo-chef](https://github.com/LukeMathWalker/cargo-chef)** fills. The fix for 3 is
`SQLX_OFFLINE`.

### How cargo-chef works

```text
planner stage:  cargo chef prepare  →  recipe.json
                (a "skeleton" of your workspace: manifests, lockfile, and
                 *empty* main.rs/lib.rs files. No real source.)

builder stage:  COPY recipe.json
                cargo chef cook     →  builds ALL dependencies       ← cached layer!
                COPY . .
                cargo build         →  builds only YOUR crate        ← fast
```

The trick: `recipe.json` only changes when your dependency graph changes. Docker compares the
*content* of `recipe.json` when deciding whether the `COPY --from=planner` layer is still
valid. Edit a handler and the planner stage re-runs (it's cheap) and produces a byte-identical
recipe, so the expensive `cook` layer comes straight from cache.

> 🟢 **FOLLOW ALONG**: create `Dockerfile` in the repo root.

```dockerfile
# syntax=docker/dockerfile:1

# ---- Stage 0: a Rust toolchain with cargo-chef preinstalled ------------------
# Pin the Debian release so it matches the runtime stage below (glibc!).
FROM lukemathwalker/cargo-chef:latest-rust-1-bookworm AS chef
WORKDIR /app

# ---- Stage 1: planner — compute the dependency "recipe" -----------------------
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ---- Stage 2: builder — build deps (cached), then our code --------------------
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# This layer only changes when Cargo.toml / Cargo.lock change.
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
# sqlx macros: use the committed .sqlx/ query data, never a live database.
ENV SQLX_OFFLINE=true
RUN cargo build --release --bin rust-crm

# ---- Stage 3: runtime — small image, no compiler, no source -------------------
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin crm
WORKDIR /app
COPY --from=builder /app/target/release/rust-crm /usr/local/bin/rust-crm
COPY config ./config
ENV APP_ENV=production
USER crm
EXPOSE 8080
CMD ["rust-crm"]
```

### Line by line: the decisions that matter

**`lukemathwalker/cargo-chef:latest-rust-1-bookworm`**: the cargo-chef image is the official
`rust` image with `cargo-chef` preinstalled. The tag means "latest cargo-chef, latest Rust
1.x, Debian **bookworm**". We pin `-bookworm` on purpose. Since Debian 13 (trixie) shipped,
the plain `rust:1` and `cargo-chef:latest-rust-1` tags are **trixie**-based. Building on
trixie and running on `bookworm-slim` is exactly the glibc mismatch from Step 1. The
alternative is to use trixie for both stages (`latest-rust-1-trixie` + `debian:trixie-slim`).
Either works, as long as **the two match**. (Tag names checked October 2026. If they've
moved, see the tag list on Docker Hub for `lukemathwalker/cargo-chef`.)

Your `Cargo.toml` says `edition = "2024"`, which needs Rust ≥ 1.85. The `rust-1` tag always
tracks the latest stable, so that's fine. For fully reproducible builds you can pin a version,
e.g. `latest-rust-1.99-bookworm`.

**`ENV SQLX_OFFLINE=true`**: since Lab 30 your `query!`/`query_as!` macros check SQL against
a real database at compile time, or against the JSON files in `.sqlx/` that
`cargo sqlx prepare` generated. With `SQLX_OFFLINE=true` the macros use **only** `.sqlx/`. If
`.sqlx/` is stale (you changed a query and didn't re-run `cargo sqlx prepare`), the build fails
here, in the image build, which is much better than at runtime. Lab 33's
`cargo sqlx prepare --check` in CI is what keeps this honest.

Notice what you **don't** need to copy into the runtime image: `migrations/`.
`sqlx::migrate!()` embeds the migration files into the binary at compile time.

**`debian:bookworm-slim`**: a minimal Debian userland with glibc, about 75 MB unpacked. It
has `libc.so.6`, `libgcc_s.so.1` and a shell for debugging (`docker exec -it … sh`).
Alternatives: `gcr.io/distroless/cc-debian12` (glibc but no shell or package manager, smaller,
harder to debug) or musl + `scratch` (see Step 1).

**`ca-certificates`**: here's the honest version. Your sqlx is built with the `tls-rustls`
feature, which (in sqlx 0.8/0.9) means `rustls` with **`webpki-roots` compiled in**. sqlx
carries its own copy of Mozilla's CA list and doesn't need the OS store. But plenty of crates
*do* read `/etc/ssl/certs`: `reqwest` with native roots, anything built on OpenSSL, and the
real email-sending `Mailer` you might write to replace Lab 39's `LogMailer`. Without the
package you get `certificate verify failed` / `UnknownIssuer` at the worst possible moment.
It costs ~200 KB. Keep it.

**`rm -rf /var/lib/apt/lists/*` in the same `RUN`**: every `RUN` creates a layer. Deleting
files in a *later* layer hides them but doesn't shrink the image. Clean up in the same
command that created the mess.

**`useradd … crm` + `USER crm`**: by default a container process runs as **root**. Container
isolation is good but not perfect. If someone finds a remote-code-execution bug in your
service, you want them to land as an unprivileged user that can't write to the binary, install
packages, or exploit a kernel bug that needs root. A fixed UID (`10001`) makes file
permissions predictable across hosts. Our server needs no root privileges at all: port 8080 is
above 1024.

**`COPY config ./config` + `WORKDIR /app`**: Lab 38's `Settings::load()` reads
`config/default.toml` and `config/{APP_ENV}.toml` **relative to the working directory**. The
binary alone isn't enough. `ENV APP_ENV=production` picks `production.toml`, and the platform
injects the secrets as `APP__…` variables at runtime.

**`EXPOSE 8080`** is documentation only. It doesn't publish anything. `-p` / `ports:` does.

**`CMD ["rust-crm"]` (exec form) vs `CMD rust-crm` (shell form)**: the shell form runs
`/bin/sh -c "rust-crm"`. Then **`sh` is PID 1**, and `sh` does not forward `SIGTERM` to its
child. On `docker stop`, your Lab 38 graceful-shutdown code never sees the signal. Docker
waits 10 s and then `SIGKILL`s everything: in-flight requests are cut and running jobs are
abandoned mid-way. With the exec form, **your binary is PID 1** and receives the signal
directly. (PID 1 is also special in Linux: it gets *no default signal handlers*. A PID-1
program that doesn't explicitly handle `SIGTERM` ignores it. Yours handles it since Lab 38.)

### The build context and `.dockerignore`

`COPY . .` copies the **build context**: everything Docker sends to the builder. By default
that's your whole repo directory, including `target/` (often several GB), `.git/` and `.env`.

> 🟡 **EXPERIMENT**: before writing `.dockerignore`, run
> `docker build -t rust-crm:dev .` and watch the first lines of output. How big is
> `transferring context`? Then answer: if `.env` is in the context, does it end up in the
> **final** image? In *any* image layer? (Answers in `solutions.md`.)

> 🔵 **YOUR TURN (mini-task 2)**: write `.dockerignore`.
>
> Requirements:
> - Excludes `target/`, `.git/` and **every** `.env*` file (but you may keep `.env.example`).
> - Must **not** exclude anything the build needs: `Cargo.toml`, `Cargo.lock`, `src/`,
>   `migrations/`, **`.sqlx/`**, `config/`.
> - Excludes things that would needlessly bust the cache (CI config, editor folders, logs, the
>   Dockerfile and compose file themselves).
> - Acceptance: the `transferring context` line drops to well under 1 MB, and a build still
>   succeeds with **no** database running.
>
> Solution: [`solutions.md` → Mini-task 2](solutions.md#mini-task-2--dockerignore).

## Step 5 — Build and run the image

> 🟢 **FOLLOW ALONG**

```bash
docker build -t rust-crm:dev .
```

The first build is slow. It compiles every dependency in release mode with thin LTO, so
expect several minutes (more on an older laptop). Watch the stages: `planner`, then `builder`
and its `cargo chef cook` line, then `runtime`.

Now feel the cache:

```bash
# change a log message or a comment in any src/ file, then:
docker build -t rust-crm:dev .
```

This time the `cargo chef cook` step prints `CACHED`, and only your crate compiles. That's the
whole point of cargo-chef.

> 🟡 **EXPERIMENT**: `cargo add uuid` (or any small crate), rebuild, and watch which steps
> are no longer `CACHED`. Then `git checkout Cargo.toml Cargo.lock` to undo it. Explain the
> result in terms of `recipe.json`.

Check the size:

```bash
docker image ls rust-crm
```

Expect something on the order of **100 MB** (the `bookworm-slim` base is most of that; your
binary is a few tens of MB). Compare with `docker image ls rust` if you have the toolchain
image locally.

Now run it against your compose Postgres. A container's `localhost` is the container itself,
so to reach Postgres on your Mac use Docker Desktop's special hostname `host.docker.internal`:

```bash
docker compose up -d db
docker run --rm -p 8080:8080 \
  -e APP__DATABASE__URL=postgres://crm:crm@host.docker.internal:5432/crm \
  -e APP__AUTH__JWT_SECRET="$(openssl rand -base64 48)" \
  rust-crm:dev
```

> 🟡 **EXPERIMENT** (glibc, the real thing): open a shell in the builder stage and look at
> the binary's dynamic dependencies:
>
> ```bash
> docker build --target builder -t rust-crm:builder .
> docker run --rm rust-crm:builder ldd target/release/rust-crm
> ```
>
> Compare with Step 1. Optional: change the first `FROM` to
> `lukemathwalker/cargo-chef:latest-rust-1-trixie` (keep `bookworm-slim` for runtime), build,
> run, and read the error. Then change it back.

> 🟡 **EXPERIMENT** (non-root): `docker run --rm --entrypoint id rust-crm:dev`. What does it
> print? Now try `docker run --rm --entrypoint sh rust-crm:dev -c 'touch /usr/local/bin/x'`.

## Step 6 — Graceful shutdown inside a container

> 🟢 **FOLLOW ALONG**: with the container from Step 5 running, in another terminal:

```bash
docker ps                         # find the container id
docker stop <id>                  # sends SIGTERM, waits up to 10 s, then SIGKILL
```

Watch the container's logs. You should see your Lab 38/39 shutdown sequence: the server
stops accepting connections, the worker's `CancellationToken` is cancelled, tasks are
awaited, the pool is closed, and the process **exits well under 10 seconds**. `docker stop`
returns quickly.

> 🟡 **EXPERIMENT**: temporarily change the last line to the shell form `CMD rust-crm`,
> rebuild, run, `docker stop` it, and time it (`time docker stop <id>`). Where did the 10
> seconds go, and why didn't your shutdown logs appear? Revert afterwards.

Commit this milestone:

```bash
git add .
git commit -m "Add Dockerfile"
```

## Step 7 — The compose stack

Since Lab 30, `docker-compose.yml` has had one service: `db`. Now the API joins it, so one
command starts a production-like stack on any machine with Docker.

### 7a. A healthcheck for Postgres

`depends_on: [db]` only waits for the db **container to start**, not for Postgres to accept
connections. Postgres takes a few seconds to initialise (much longer on the first run, when it
creates the data directory). Without a healthcheck, the API starts, fails to connect, and
exits. That's why you need a healthcheck, and your `db` service has had one since Lab 30
(it's what made `docker compose ps` say `running (healthy)`). Until now nothing waited on it.

> 🟢 **FOLLOW ALONG**: give the healthcheck a cold-start allowance: slower polling and a
> `start_period` (keep the rest of your Lab 30 service as it is):

```yaml
services:
  db:
    image: postgres:17
    environment:
      POSTGRES_USER: crm
      POSTGRES_PASSWORD: crm
      POSTGRES_DB: crm
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U crm -d crm"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s

volumes:
  pgdata:
```

`pg_isready` ships inside the Postgres image and exits `0` once the server accepts
connections. `start_period` gives a grace period during which failures don't count.

> ⚠️ Keep `postgres:17` pinned. The `postgres:18` image moved its data directory, so a
> volume mounted at `/var/lib/postgresql/data` behaves differently. Major-version upgrades of
> Postgres are a deliberate operation (`pg_upgrade` or dump/restore), never a tag bump.

### 7b. The API service

> 🔵 **YOUR TURN (mini-task 3)**: add an `api` service to `docker-compose.yml`.
>
> Requirements:
> - Builds from the local `Dockerfile` and tags the image `rust-crm:local`.
> - Starts only after `db` is **healthy**.
> - Gets its database URL through `APP__DATABASE__URL`. Think carefully about the **host
>   name**: from inside the compose network, what is Postgres called? (It's not `localhost`.)
> - Gets `APP__AUTH__JWT_SECRET` from a `JWT_SECRET` variable in your **gitignored `.env`**,
>   using compose interpolation. If the variable is missing, `docker compose` must **refuse to
>   start** with a clear message (look up the `${VAR:?message}` syntax).
> - Publishes port 8080 and restarts automatically unless you stopped it.
> - Add `JWT_SECRET=` (empty) to `.env.example` so the next person knows it exists.
>
> Acceptance:
> - With `JWT_SECRET` unset, `docker compose up` fails before starting anything:
>   ```text
>   error while interpolating services.api.environment.APP__AUTH__JWT_SECRET: required variable JWT_SECRET is missing a value: Set JWT_SECRET in .env (at least 32 characters)
>   ```
>   (the text after the last colon is your own message)
> - With it set, `docker compose up --build` brings up both services, the API logs JSON
>   lines, and `curl localhost:8080/ready` returns `{"status":"ready"}`.
>
> Solution: [`solutions.md` → Mini-task 3](solutions.md#mini-task-3--compose-api-service).

> 💡 Compose reads `.env` in the project directory **for interpolation** (`${…}` in the YAML).
> That's different from Lab 38's `dotenvy`, which loads `.env` **inside your program**. Inside
> the container there's no `.env` (you excluded it in mini-task 2), so `dotenvy` finds nothing,
> which is fine as long as your Lab 38 code treats a missing `.env` as "not an error".

**Why no healthcheck on `api`?** `bookworm-slim` has no `curl` or `wget`, and installing one
just for a healthcheck adds size and attack surface. Options are to install `curl` anyway, to
add a tiny `rust-crm healthcheck` subcommand that requests `/health` and exits 0/1, or to
leave it to the platform. Fly.io (Step 9) does its own HTTP checks, so we leave compose
without one. Know the trade-off.

### 7c. Migrations: on startup, or as a release step?

With `database.run_migrations = true` in `production.toml`, the API applies pending
migrations every time it starts. On a fresh compose stack, the first `up` creates all your
tables.

| | **Migrate on startup** (what we do) | **Separate release step** |
|---|---|---|
| How | App calls `sqlx::migrate!().run(&pool)` before serving | A one-off command runs migrations, *then* new instances start |
| Pros | Zero extra moving parts, impossible to forget | Migration failures block the deploy cleanly. App doesn't need DDL rights. Long migrations don't delay boot or trip health checks |
| Cons | Several instances starting at once all try to migrate. A slow migration delays readiness. App's DB user needs `CREATE`/`ALTER` | One more step to wire up; you need a `migrate` subcommand or `sqlx-cli` in an image |
| Concurrency | sqlx takes a Postgres **advisory lock** (`pg_advisory_lock`) around migrations, so concurrent instances wait their turn | Single runner by construction |

Migrate-on-startup is a perfectly good choice for a small service. The thing to internalise is
that **either way, old code and new schema overlap for a while** during a rolling deploy. So
migrations must be backwards-compatible: add a nullable column first, deploy code that uses
it, and only then tighten constraints or drop the old one ("expand, then contract").

> 🟡 **EXPERIMENT**:
> ```bash
> docker compose down -v          # -v deletes the pgdata volume: a brand-new database
> docker compose up --build
> ```
> The API doesn't log individual migrations (sqlx's own lines are below the `sqlx=warn`
> filter), so ask the database: `SELECT version, description, installed_on FROM _sqlx_migrations;`
> via `docker compose exec db psql -U crm`. Every migration was applied when the API started.
> Then `docker compose restart api` and run the query again. Do they run again? Why not?
> (Hint: look at `installed_on`.)

Try the whole stack end to end:

```bash
curl -s localhost:8080/health
curl -s -X POST localhost:8080/auth/register \
  -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","name":"Ada","password":"correct horse battery"}'
TOKEN=$(curl -s -X POST localhost:8080/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","password":"correct horse battery"}' | jq -r .access_token)
curl -s localhost:8080/companies -H "authorization: Bearer $TOKEN"
```

(`brew install jq` if you don't have it.)

```bash
git add .
git commit -m "Add compose stack"
```

## Step 8 — Secrets: where they live, where they must never be

Your CRM has two real secrets: the **database URL** (it contains a password) and the **JWT
secret** (anyone holding it can mint admin tokens). Rules:

| Place | Secrets allowed? | Why |
|---|---|---|
| Git (any file, any branch, any commit) | ❌ never | History is forever; rotating is the only fix |
| `Dockerfile` `ENV`/`ARG` | ❌ never | Baked into image layers; `docker history` shows them |
| `config/*.toml` | ❌ never | Committed |
| `fly.toml` `[env]` | ❌ never | Committed, and shown in the dashboard |
| Logs | ❌ never | `SecretString` (Lab 34) + `skip` in `#[instrument]` (Lab 37) protect you |
| Local `.env` (gitignored, dockerignored) | ✅ dev only | Your machine, your throwaway values |
| Platform secret store (`fly secrets`, GitHub Actions secrets, …) | ✅ | Encrypted at rest, injected as env vars at runtime |

Generate real secrets; don't type them:

```bash
openssl rand -base64 48      # 64 characters: comfortably over Lab 38's 32-byte minimum
```

**Rotation.** Changing `APP__AUTH__JWT_SECRET` invalidates every issued token. With a
15-minute TTL (Lab 35), users just log in again. That's one of the quiet benefits of short
TTLs.

## Step 9 — Deploy (worked example: Fly.io)

Everything up to here is provider-agnostic: an OCI image configured by environment variables
that listens on `$host:8080`, exposes `/health` and `/ready`, and shuts down on `SIGTERM`. Any
container platform can run that. We'll use **Fly.io** as the worked example because it builds
from a Dockerfile, supports Postgres, and handles TLS for you.

> ⚠️ **PROVIDER-SPECIFIC (Fly.io)**: commands below were checked against Fly's docs in
> October 2026. Platforms change their CLIs. If a command fails, check
> <https://fly.io/docs/> and `fly <command> --help`. Fly requires a payment method, and
> **Fly Managed Postgres is a paid product** (the smallest plan was about $38/month when
> this lab was written). See the cheaper options in 9c.

### 9a. Install and log in

```bash
brew install flyctl            # or: curl -L https://fly.io/install.sh | sh
fly auth login
```

### 9b. Create the app (without deploying yet)

From your repo root:

```bash
fly launch --no-deploy --no-db --name rust-crm-<yourname>
```

`--no-deploy` lets you review the config before anything goes live. `--no-db` stops the
wizard from provisioning a database. We'll do that deliberately in 9c. `fly launch` detects
your `Dockerfile` and writes a `fly.toml`. Open it and make it look like this (keep the
`app` and `primary_region` it generated):

```toml
app = "rust-crm-<yourname>"
primary_region = "<generated>"

# Top-level keys MUST come before the first [table] in TOML,
# otherwise they silently become part of that table.
kill_signal = "SIGTERM"
kill_timeout = 30

[build]
  dockerfile = "Dockerfile"

[env]
  APP_ENV = "production"
  RUST_LOG = "rust_crm=info,tower_http=info,sqlx=warn"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

  [[http_service.checks]]
    grace_period = "20s"
    interval = "15s"
    method = "GET"
    path = "/ready"
    timeout = "3s"

[[vm]]
  memory = "512mb"
  cpu_kind = "shared"
  cpus = 1
```

Why each non-default matters:

- **`kill_signal = "SIGTERM"`, `kill_timeout = 30`**: Fly sends `SIGINT` by default and waits
  only **5 seconds** before killing. Your Lab 38 code handles both signals, but 5 s may not be
  enough to finish a running job and close the pool. Make the platform's patience match your
  shutdown design.
- **`auto_stop_machines = "off"`, `min_machines_running = 1`**: Fly can stop idle machines to
  save money and start them again on the next request. Great for a pure request/response API,
  but **your CRM is not one**. Since Lab 39 it runs a job worker and a scheduler. A stopped
  machine runs no stale-deal scans and sends no reminders.
- **`path = "/ready"`**: Fly uses these checks to decide whether a machine should receive
  traffic and whether a deploy succeeded. That's a readiness question, so it gets the
  readiness endpoint.
- **Secrets are absent on purpose.** See Step 8.

### 9c. A Postgres database

Pick **one**:

**Option A: Fly Managed Postgres** (paid, same network as your app):

```bash
fly mpg create                 # choose a name, region (same as your app) and plan
fly mpg list                   # note the cluster ID
fly mpg attach <CLUSTER_ID> --app rust-crm-<yourname> --variable-name APP__DATABASE__URL
```

`fly mpg attach` stores the connection string as a **secret** on your app. By default it's
called `DATABASE_URL`, which your app ignores (Lab 38 reads only `APP__…`), so we name it with
`--variable-name`. The attached URL points at Fly's PgBouncer pooler, which runs in **session
mode** by default, so sqlx's prepared statements and the migration advisory lock work. (If you
ever switch the pooler to *transaction* mode, prepared statements and advisory locks break, and
you'd point the app, or at least migrations, at the cluster's *direct* URL instead.)

**Option B: any external Postgres** (Neon, Supabase, Crunchy Bridge, RDS, …; several have free
tiers). Create a Postgres 16+ database, copy its connection string (it will usually end in
`?sslmode=require`), and:

```bash
fly secrets set --stage APP__DATABASE__URL='postgres://user:pass@host:5432/db?sslmode=require'
```

Single quotes keep your shell away from `&`, `?` and `$` in the URL. `--stage` stores the
secret without restarting anything, since there's nothing running yet. This is where Step 4's
TLS discussion becomes real: the connection is encrypted, and rustls verifies the server's
certificate against the CA roots compiled into your binary.

### 9d. The JWT secret

```bash
fly secrets set --stage APP__AUTH__JWT_SECRET="$(openssl rand -base64 48)"
fly secrets list               # shows names and digests, never values
```

### 9e. Deploy

```bash
fly deploy
```

`fly deploy` sends your build context (filtered by `.dockerignore`) to a **remote builder**,
builds the Dockerfile there, pushes the image to Fly's registry, starts the machine(s), and
waits for `/ready` to pass. You don't need Docker running locally for this step.

```bash
fly status
fly logs                       # JSON lines from Lab 37's telemetry
curl -s https://rust-crm-<yourname>.fly.dev/health
curl -s https://rust-crm-<yourname>.fly.dev/ready
```

If the deploy fails, `fly logs` almost always says why, and your Lab 38 fail-fast validation
should name the missing or invalid setting.

> 💡 **How many machines?** `fly launch` may give you **two** machines for availability. That's
> safe for this CRM, and it's worth pausing on *why*. Two instances run migrations at boot:
> sqlx's advisory lock serialises them. Two job workers claim jobs: `FOR UPDATE SKIP LOCKED`
> (Lab 39) guarantees a job is claimed once. Two schedulers enqueue the daily scan: the
> idempotency key's unique index (Lab 39) rejects the duplicate. You designed for this before
> you needed it. To save money while learning: `fly scale count 1`.

### 9f. Your first admin

Every account registers as `sales_rep` (Lab 34). Register yourself through the API, then
promote yourself with SQL, the same way you did locally with `scripts/make_admin.sql`:

```bash
fly mpg connect                # Option A. For Option B, use your provider's SQL console.
```

```sql
UPDATE users SET role = 'admin' WHERE email = 'you@example.com';
```

### Other platforms (same image, different buttons)

| Platform | What changes |
|---|---|
| **Railway** | "Deploy from GitHub repo" detects the Dockerfile. Add a Postgres plugin and *reference* its URL in a variable named `APP__DATABASE__URL`. Set `APP__AUTH__JWT_SECRET` in Variables. Railway injects `PORT`, so either set `APP__SERVER__PORT` to match or set the service port to 8080. |
| **Render** | New "Web Service" → Docker runtime. Health check path `/ready`. Render Postgres gives you an internal URL; copy it into `APP__DATABASE__URL`. Check whether your plan sleeps idle services (bad for the job worker). |
| **Any VM** (Hetzner, DigitalOcean, EC2…) | Install Docker, copy `docker-compose.yml`, put real secrets in a root-only `.env`, `docker compose up -d`. Add a reverse proxy for TLS (Caddy is the shortest path) and **back up the Postgres volume**. You now own patching and backups. |

> 🔵 **Optional**: if you deploy elsewhere, write down the equivalent of each 9a–9f step for
> your platform in your README's deploy section.

---

## ▶️ Run It

Locally, the whole production-shaped stack:

```bash
docker compose down -v
docker compose up --build
```

And the deployed one:

```bash
curl -i https://rust-crm-<yourname>.fly.dev/ready
```

## ✅ Expected Result

`docker compose up --build`: both services start, `db` becomes `healthy` **before** `api`
starts, and the API logs JSON lines (`starting rust-crm` with `"env":"production"`,
`listening` on `0.0.0.0:8080`, `job worker started`, `job scheduler started`). The exact fields
depend on your Lab 37 setup.

Health and readiness (verified against a real Postgres; request ids and dates will differ):

```text
$ curl -i localhost:8080/health
HTTP/1.1 200 OK
content-type: application/json
x-request-id: eaeba0f2-82a2-4e5a-98aa-e42d2a136a04
content-length: 15
date: Mon, 05 Oct 2026 17:50:26 GMT

{"status":"ok"}

$ curl -i localhost:8080/ready
HTTP/1.1 200 OK
content-type: application/json
x-request-id: d55efd80-498d-44ef-a738-a073e845201e
content-length: 18
date: Mon, 05 Oct 2026 17:50:26 GMT

{"status":"ready"}
```

With the database stopped (`docker compose stop db`), `/health` is still `200`, and `/ready`
answers after ~2 seconds with:

```text
HTTP/1.1 503 Service Unavailable
content-type: application/json
x-request-id: 5b0c66b6-ca1d-410e-b4db-7b0cec607350
content-length: 24
date: Mon, 05 Oct 2026 17:49:04 GMT

{"status":"unavailable"}
```

`docker image ls rust-crm` shows an image of roughly 100 MB. A source-only change rebuilds in
well under a minute because `cargo chef cook` is `CACHED`. `docker stop` returns in seconds,
not 10. On Fly, `fly status` shows your machine(s) as `started` with passing checks, and the
`https://…fly.dev/ready` URL returns `{"status":"ready"}`.

## 🧠 Understand It

**The image is a function of three inputs.** The base images (pinned by tag), `recipe.json`
(your dependency graph), and your source. The stages are ordered from *least* to *most*
frequently changing. That's the general rule of layer caching, in any language. Rust just
punishes you harder for getting it wrong, because its dependency builds are expensive. It
compiles everything from source, monomorphises generics, and optimises across the whole crate
graph. In exchange you ship one self-contained binary.

**The runtime image contains only what the binary needs at runtime.** That's glibc (dynamic
linking, Step 1), CA certificates (TLS for anything using the OS store), `config/` (read at
startup) and the binary. There's no compiler, no source, no `.sqlx/` and no `migrations/`
(embedded by `migrate!()`). Ask "what does this process open, link or read at runtime?" and
you've derived the runtime stage.

**Configuration flows from least to most specific**, exactly as designed in Lab 38:
`default.toml` → `production.toml` (chosen by `APP_ENV`, set in the image) → `APP__…` env vars
(injected by compose or the platform). The image is identical in every environment. Only the
environment differs. That's the "build once, deploy many" property, and it's why secrets must
never be baked in.

**Health endpoints are a contract with the platform.** `/health` says "don't kill me".
`/ready` says "don't route to me". Mixing them up causes outages to cascade (restart loops)
or causes traffic to hit instances that can't serve it.

**Signals are part of your API, too.** `SIGTERM` → stop accepting → drain → cancel workers →
close pool → exit 0. The exec-form `CMD` and `kill_timeout` exist so that sequence actually
gets to run.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 — Kill the database under load.** With the compose stack up, run
> `while true; do curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/ready; sleep 1; done`
> and `docker compose stop db` in another terminal. Watch the codes, then `start db` again. How
> long until `200` returns? Does the API process ever restart? Should it?

> 🟡 **EXPERIMENT 2 — Secrets in layers.** Temporarily add
> `ENV APP__AUTH__JWT_SECRET=super-secret-value-that-is-long-enough` to the runtime stage,
> build, then run `docker history --no-trunc rust-crm:dev | grep JWT`. Remove it, and think
> about what "remove it" means for an image you'd already pushed.

> 🟡 **EXPERIMENT 3 — `strip` vs backtraces.** Add a temporary route that panics, run the
> image with `-e RUST_BACKTRACE=1`, hit the route, and look at the backtrace. Switch to
> `strip = "debuginfo"`, rebuild, and compare. Which would you rather read during an incident?
> (Remove the route afterwards!)

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — Build the image in CI.**
>
> Add a `docker` job to `.github/workflows/ci.yml` (the workflow from Labs 24/33).
>
> Requirements:
> - Runs **after** your existing test job succeeds (`needs:`).
> - Builds the image from the repo's `Dockerfile` using Docker Buildx, with the **GitHub
>   Actions cache** as the layer cache (otherwise every CI run rebuilds all dependencies).
> - On **pull requests**: build only, never push.
> - On **pushes to `main`** and on **tags matching `v*`**: push to the GitHub Container
>   Registry at `ghcr.io/<owner>/<repo>`, authenticating with the built-in `GITHUB_TOKEN` (no
>   personal tokens, no new secrets).
> - Tags: the commit SHA always, `latest` for the default branch, and `1.0.0` when you push
>   the `v1.0.0` git tag.
> - The job requests only the permissions it needs.
> - The workflow must trigger on `v*` tag pushes (check your `on:` block).
>
> Acceptance:
> - A PR shows a green "Docker image" job and nothing appears in GitHub Packages.
> - After merging/pushing to `main`, your repo's **Packages** sidebar shows `rust-crm` with
>   `latest` and `sha-…` tags.
> - `docker pull ghcr.io/<owner>/rust-crm:latest` works (after you make the package public, or
>   `docker login ghcr.io`).
>
> (Current action majors when this lab was written: `actions/checkout@v7`,
> `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/metadata-action@v6`,
> `docker/build-push-action@v7`. Check their READMEs for newer majors.)

> 🔵 **YOUR TURN 2 — The README your CRM deserves.**
>
> Rewrite your `rust-crm` repo's `README.md` (the one with the CI badge from Lab 24) as a real
> project README. A stranger should be able to understand, run, test and deploy the project
> without reading any lab. Required sections:
>
> - [ ] Name, one-paragraph description, CI badge, and a **live URL**
> - [ ] **Features**: companies/contacts, leads → conversion, deals pipeline, activities and
>       notes, search, auth + roles, background jobs (in your own words)
> - [ ] **Architecture**: an ASCII diagram of the request path and the background path (client
>       → axum router → auth → handlers → domain → db modules → Postgres; scheduler → jobs
>       table → worker → mailer), plus a short tour of `src/`
> - [ ] **Running locally**: prerequisites, `.env` from `.env.example`, `docker compose up --build`,
>       and the `cargo run` dev loop with `docker compose up -d db`
> - [ ] **Configuration**: the layering rule and a table of the important `APP__…` variables
>       (mark the secrets)
> - [ ] **API overview**: a table of endpoints grouped by resource, auth requirements, and one
>       complete curl session (register → login → create company)
> - [ ] **Testing**: how to run unit/DB/API tests, and what `SQLX_OFFLINE` / `cargo sqlx prepare` are for
> - [ ] **Deployment**: image build, required secrets, your platform's steps, migrations policy
> - [ ] **Design decisions**: at least four short "we chose X because Y" entries (IDs instead of
>       references, `i64` IDs, JWT TTL, SKIP LOCKED queue, …)
> - [ ] It contains **no secrets** and every command in it actually works when you paste it
>
> A skeleton with an example architecture diagram is in `solutions.md`, but write yours first.
> Describing the architecture *you* built is the best review of this course you'll ever do.

## 💡 Hint

> 💡 **HINT (mini-task 1)**: `tokio::time::timeout(dur, fut).await` gives you
> `Result<T, Elapsed>`, and here `T` is itself a `Result<_, sqlx::Error>`. A single `match`
> with three arms (`Ok(Ok(_))`, `Ok(Err(e))`, `Err(_)`) reads better than nested `if let`s.

<details><summary>Hint 2 (mini-task 3)</summary>

Inside a compose network, each service is reachable by its **service name**. And
`${JWT_SECRET:?some message}` is compose's "required variable" syntax.

</details>

<details><summary>Hint 3 (Your Turn 1)</summary>

`docker/metadata-action` turns git refs into image tags. It understands `type=sha`,
`type=raw,value=latest,enable={{is_default_branch}}` and `type=semver,pattern={{version}}`,
and it lowercases the image name (GHCR requires lowercase, and `github.repository` might not
be). Pushing to GHCR needs `permissions: packages: write`. Make the login step and `push:`
conditional on `github.event_name == 'push'`. For the cache, look up `cache-from: type=gha`.

</details>

<details><summary>Hint 4 (Your Turn 2)</summary>

Write the architecture section by starting at `src/main.rs` and following the calls from top
to bottom: settings (`config::load` + `validate`) → `run()` in `src/lib.rs` (telemetry) →
`Application::build` in `src/startup.rs` (pool → migrations → state + router) →
`run_until_stopped` (worker + scheduler → serve → shutdown). That *is* your architecture.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). It covers the `/ready`
> handler and tests, `.dockerignore`, the compose `api` service, the CI `docker` job, a README
> skeleton, and answers to the experiment questions. Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Which parts of your program are statically linked into `rust-crm`, and which are loaded at
   runtime? Why does that rule out `FROM scratch` for this binary?
2. You build with `rust:1` (trixie) and run on `debian:bookworm-slim`. What can go wrong, and
   why does the reverse (build on bookworm, run on trixie) work?
3. Explain, in terms of layers and `recipe.json`, why editing a handler doesn't recompile tokio.
4. What would happen during `docker build` without `SQLX_OFFLINE=true`? And with it, but with
   a stale `.sqlx/`?
5. Why does `/health` not touch the database? Describe the failure mode if it did.
6. Why must the `CMD` use exec form, and what does `kill_timeout` have to do with Lab 38?
7. Two machines start at once and both run migrations. Why is that safe here? Why do
   migrations still need to be backwards-compatible?
8. Name three places a secret must never appear, and explain how one leaked into git would be fixed.
9. Why is `auto_stop_machines` turned off for *this* service, when it's great for many others?

Then verify:

```bash
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
docker build -t rust-crm:dev .
docker compose up --build        # Ctrl-C to stop
```

## Git Commit

You committed `Add Dockerfile` (Step 6) and `Add compose stack` (Step 7). Now the deployment
pieces: `fly.toml` (if you used Fly), the CI job and the README.

```bash
git add .
git commit -m "Add deployment"
git tag lab-40
git tag -a v1.0.0 -m "Rust CRM 1.0.0: first deployed release"
git push && git push --tags
```

`v1.0.0` is an **annotated** tag (`-a`). Unlike a lightweight `lab-NN` tag, it stores who
tagged it, when, and a message, which is what release tooling expects. Pushing it triggers your
CI's `docker` job, which publishes `ghcr.io/<owner>/rust-crm:1.0.0`. Optionally, turn it into
a GitHub Release: `gh release create v1.0.0 --generate-notes`.

**It's live.** In Lab 01 you printed `Rust CRM v0.1.0`. Today, a stranger anywhere on the
internet can register, log in and run a sales pipeline on software you wrote, in a language
you didn't know when you started. Take a minute with that before the capstone.

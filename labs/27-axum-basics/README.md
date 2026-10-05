# Lab 27 — HTTP & Axum Basics

> **Phase:** 8 — The CRM Becomes a Web API · **Builds on:** Lab 26 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-26` · **After:** tag `lab-27`

## 🎯 Goal

The CRM speaks HTTP. `cargo run` now starts a web server on `http://127.0.0.1:3000` with
`GET /health`, `GET /companies`, `POST /companies` and `GET /companies/{id}`, all JSON. The
terminal REPL keeps working as a second binary, `crm-cli`.

## 🧠 What You'll Learn

- One package, **two binaries**, one library: `src/bin/`, `cargo run --bin`, `default-run`
- Axum's building blocks: `Router`, routes, method routers (`get(...).post(...)`)
- **Handlers are plain `async fn`s.** Axum accepts them because of traits it implements for
  them (`Handler`)
- **Extractors are types that implement `FromRequestParts` or `FromRequest`**: `State`, `Path`,
  `Json`. This is where your trait work in Labs 15 and 23 pays off
- Return types that implement `IntoResponse`: `Json<T>`, `StatusCode`, tuples, `Result`
- Shared state with `State<AppState>`, and why `AppState` must be `Clone` (and why that's cheap)
- **DTOs vs domain models**: why `CompanyResponse` is not `Company`
- `std::sync::RwLock` in async handlers: drop the guard before `.await` (and what happens if you
  don't)
- Why two programs writing one JSON file is a bug that no type system can catch

## 🔨 What We're Building

```text
rust-crm (package)
├── src/lib.rs            ← library crate `rust_crm`: domain, storage, cli, http
├── src/main.rs           ← binary `rust-crm`: the HTTP server        (cargo run)
└── src/bin/crm-cli.rs    ← binary `crm-cli`: the terminal REPL       (cargo run --bin crm-cli)

HTTP request ─► axum::serve ─► Router ─► handler(State, Path, Json) ─► domain (Crm) ─► JSON response
                                               │
                                               └─ AppState { crm: Arc<RwLock<Crm>>, storage: Arc<dyn Storage> }
```

| Method & path | Handler | Success | Failure (for now) |
|---|---|---|---|
| `GET /health` | `health` | `200 {"status":"ok"}` | — |
| `GET /companies` | `list_companies` | `200 [CompanyResponse…]` | — |
| `POST /companies` | `create_company` | `201 CompanyResponse` | `422` (invalid), `500` (save failed) |
| `GET /companies/{id}` | `get_company` | `200 CompanyResponse` | `404` (empty body) |

Errors are bare status codes in this lab. **Lab 28** gives them consistent JSON bodies.

This lab was written against **axum 0.8** (`/{id}` path syntax) and **tokio 1.53**. If you're on
a newer axum, check its changelog on docs.rs.

---

## Step 1 — Two binaries, one library

Since Lab 13 the CRM has been a **library crate** (`src/lib.rs`) plus a thin **binary crate**
(`src/main.rs`). That split now pays off: a package can have *many* binaries, all using the same
library.

Cargo finds binaries by convention:

| File | Binary name |
|---|---|
| `src/main.rs` | the package name: `rust-crm` |
| `src/bin/<name>.rs` | `<name>` |

> 🟢 **FOLLOW ALONG**: move the REPL's `main` into its own binary. Use `git mv` so Git records a
> rename, not a delete plus an add:

```bash
mkdir -p src/bin
git mv src/main.rs src/bin/crm-cli.rs
```

Nothing inside `crm-cli.rs` changes. It still parses `Args` with clap, builds the storage with
`build_storage`, and calls `rust_crm::cli::run(storage, autosave_every).await`. Its
`#[cfg(test)] mod tests` (the clap tests from Lab 23/24) moves with it, and `cargo test` keeps
running them as the `crm-cli` binary's unit tests. A binary in `src/bin/` reaches the library the
same way `main.rs` did, through `rust_crm::…`, because it's a separate crate that depends on the
library.

Now create a placeholder `src/main.rs` (it becomes the server in Step 6):

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("Rust CRM API v{}: coming soon", env!("CARGO_PKG_VERSION"));
    Ok(())
}
```

> 🟡 **EXPERIMENT**: run `cargo run`. Predict what Cargo does with two binaries.

```text
error: `cargo run` could not determine which binary to run. Use the `--bin` option to specify a binary, or the `default-run` manifest key.
available binaries: crm-cli, rust-crm
```

Cargo doesn't guess. Tell it which binary is the default, in `Cargo.toml`:

```toml
[package]
name = "rust-crm"
version = "0.1.0"
edition = "2024"
default-run = "rust-crm"
```

```bash
cargo run                                   # → the server (placeholder for now)
cargo run --bin crm-cli                     # → the REPL
cargo run --bin crm-cli -- --storage memory # flags after `--` go to the program
```

```text
$ cargo run -q
Rust CRM API v0.1.0: coming soon
$ cargo run -q --bin crm-cli -- --help
A terminal CRM, written while learning Rust

Usage: crm-cli [OPTIONS]
…
```

`cargo build` now produces both `target/debug/rust-crm` and `target/debug/crm-cli`. Clap picks up
the new binary name in its usage line automatically.

Commit this step on its own. It's a refactor that changes no behaviour, and a separate commit
makes that obvious in `git log`:

```bash
git add .
git commit -m "Move REPL to crm-cli binary"
```

---

## Step 2 — The HTTP mental model in Axum

```bash
cargo add axum
```

(Default features include HTTP/1, JSON, query strings and Tokio integration. Tokio and serde you
already have.)

Axum is a thin layer on top of three crates you'll see in error messages: **hyper** (HTTP
protocol), **tower** (a `Service` trait: "request in, future of response out") and **tokio**
(the runtime from Lab 26). A request flows like this:

```text
TcpListener ── accept ──► one Tokio task per connection (hyper)
                              │  parse bytes into http::Request<Body>
                              ▼
                          Router: match method + path ──► 404 / 405 if no match
                              │
                              ▼
                          handler: extract arguments → run your async fn → IntoResponse
                              │
                              ▼
                          http::Response<Body> ── bytes ──► client
```

Two facts follow from Lab 26:

- **Every connection is a spawned task**, and handlers run inside those tasks. So a handler's
  future must be **`Send + 'static`**. Everything you learned about guards and `.await` applies
  directly.
- Many requests run **at the same time** on different worker threads. The CRM must be shared,
  like in Lab 25, but by many more parties.

---

## Step 3 — `AppState`: what every request shares

> 🟢 **FOLLOW ALONG**: create `src/http/state.rs`:

```rust
use std::sync::{Arc, RwLock};

use tokio::task;

use crate::crm::Crm;
use crate::storage::{InMemoryStorage, Storage, StorageError};

/// Shared by every request. Cloning it clones two `Arc`s: two counter bumps, no data copied.
#[derive(Clone)]
pub struct AppState {
    pub crm: Arc<RwLock<Crm>>,
    pub storage: Arc<dyn Storage>,
}

impl AppState {
    pub fn new(crm: Crm, storage: Arc<dyn Storage>) -> Self {
        Self {
            crm: Arc::new(RwLock::new(crm)),
            storage,
        }
    }

    /// An empty CRM that is never written anywhere (for tests and experiments).
    pub fn in_memory() -> Self {
        Self::new(Crm::default(), Arc::new(InMemoryStorage))
    }

    /// Write the current CRM to storage.
    ///
    /// Saving is blocking file I/O, so it runs on the blocking thread pool.
    /// The read lock is taken *inside* that blocking task: other readers
    /// carry on, writers wait until the snapshot is on disk.
    pub async fn persist(&self) -> Result<(), StorageError> {
        let state = self.clone();
        task::spawn_blocking(move || {
            let crm = state.crm.read().expect("CRM lock poisoned");
            state.storage.save(&crm)
        })
        .await
        .expect("persist task panicked")
    }
}
```

### Why `RwLock` here, when Lab 25 chose `Mutex`?

The REPL had two parties, and both wrote. A web server has many concurrent requests, and most of
them are `GET`s that only **read**. `RwLock` lets every reader in at once and makes writers wait
for exclusive access. It's the runtime version of `&Crm` vs `&mut Crm`:

```text
GET /companies  ─┐
GET /companies/2 ├── crm.read()  ── many RwLockReadGuards at once ──┐
GET /companies  ─┘                                                   ├─► Crm
POST /companies ──── crm.write() ── one RwLockWriteGuard, no readers ┘
```

And why **`std::sync::RwLock`**, not `tokio::sync::RwLock`? It's the Lab 26 rule: our handlers
never hold the guard across an `.await`. Every critical section is a short block of synchronous
code. The `std` lock is faster, and its non-`Send` guard means **the compiler will tell us** if
we ever get that wrong. (You'll see it in Step 5.)

### No `AppData`, no dirty flag

The server **persists right after each successful write** instead of autosaving. Each `POST`
returns only after its data is on disk, so a client that got `201 Created` knows the data
survives a crash. The REPL keeps its own `AppData` + autosave. Different front ends, different
trade-offs, same domain underneath.

### `persist()`: the lock goes where the blocking work is

`persist` clones the state (two `Arc` bumps) and moves the clone into `spawn_blocking`, for the
`'static` reason from Lab 26. The **read lock is taken inside the blocking closure**, so no async
code holds it at all. While the snapshot is being written, other `GET`s keep reading. Only
writers wait.

`.expect("persist task panicked")`: a `JoinError` here means the save code panicked, which is a
bug, not an expected failure. Re-panicking in the handler is acceptable: Tokio catches panics per
task, so only that one request's connection is dropped and the server keeps running.

### Why `Clone`, and why it's cheap

Axum hands the state to every handler **by value**: `State<AppState>` holds an `AppState`, not
a reference. Each request runs in its own `'static` task, so it can't borrow from `main`. Lab 25
again. Axum clones the state for each request, so `AppState` must be `Clone`, and that clone must
be cheap. Ours is: `#[derive(Clone)]` clones each field, and each field is an `Arc`.

```text
request 1: State(AppState { crm: Arc ─┐, storage: Arc ─┐ })
request 2: State(AppState { crm: Arc ─┤, storage: Arc ─┤ })   strong counts: N+1
main:      AppState        { crm: Arc ─┤, storage: Arc ─┤ }
                                       ▼                 ▼
                               RwLock<Crm> (one)   JsonFileStorage (one)
```

If `AppState` held a `Crm` directly, every request would deep-copy the entire CRM, and the
copies would diverge. Wrapping shared things in `Arc` is the standard Axum pattern.

---

## Step 4 — DTOs: the API's contract is not your domain model

Your `Company` already derives `Serialize` (Lab 21). Why not just return it? Because the JSON your
API returns is a **public contract** with clients (a frontend, a mobile app, other teams). Your
domain model is an **internal design** that you'll keep changing. If they're the same type,
every internal refactor is a breaking API change:

| If you serialized `Company` directly… | With a separate `CompanyResponse`… |
|---|---|
| renaming a field silently breaks clients | rename freely; the `From` impl absorbs it |
| `CompanyId(1)` serializes however serde derives it today | you choose: a plain `"id": 1` |
| new internal fields (audit data, a `password_hash` on `User` in Lab 34!) leak automatically | only fields you list are exposed |
| request and response must have the same shape | create requests don't have an `id` or `lifecycle`; responses do |

The usual names: **DTO** (data transfer object) for these boundary types, or "request/response
models". The direction of dependency matters: the `http` module knows about the domain, and the
domain knows nothing about HTTP.

> 🟢 **FOLLOW ALONG**: create `src/http/companies.rs` with the DTOs:

```rust
//! `/companies` endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};

use super::AppState;
use crate::companies::{Company, CompanyId, Lifecycle};

/// What a client sends to create a company.
#[derive(Debug, Deserialize)]
pub struct CreateCompanyRequest {
    pub name: String,
    pub website: Option<String>,
}

/// What a client gets back. Not the domain `Company`: this is the public contract.
#[derive(Debug, Serialize)]
pub struct CompanyResponse {
    pub id: u64,
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
}

impl From<&Company> for CompanyResponse {
    fn from(c: &Company) -> Self {
        Self {
            id: c.id.0,
            name: c.name.clone(),
            website: c.website.clone(),
            lifecycle: c.lifecycle,
        }
    }
}
```

- `From<&Company>`, not `From<Company>`: the company stays in the CRM. We only **borrow** it to
  build a response. That means cloning the `String`s, and it's the right cost: the response must
  own its data, because it outlives the read lock.
- `lifecycle: Lifecycle` reuses the domain enum. Its `#[serde(rename_all = "snake_case")]` from
  Lab 21 gives `"prospect"`, so the wire format is already what we want. (If the domain enum
  ever changes, this is the line where you'd decouple them.)
- `website: Option<String>` in a `Deserialize` struct means the field may be **missing or
  `null`**. `name: String` means it's required. Serde enforces that before your code runs.

---

## Step 5 — Handlers and extractors

> 🟢 **FOLLOW ALONG**: add the three handlers to `src/http/companies.rs`:

```rust
/// `GET /companies`
pub async fn list_companies(State(state): State<AppState>) -> Json<Vec<CompanyResponse>> {
    let crm = state.crm.read().expect("CRM lock poisoned");
    Json(crm.companies.iter().map(CompanyResponse::from).collect())
}

/// `GET /companies/{id}`
pub async fn get_company(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<Json<CompanyResponse>, StatusCode> {
    let crm = state.crm.read().expect("CRM lock poisoned");
    crm.companies
        .get(CompanyId(id))
        .map(|c| Json(CompanyResponse::from(c)))
        .ok_or(StatusCode::NOT_FOUND)
}

/// `POST /companies`
pub async fn create_company(
    State(state): State<AppState>,
    Json(request): Json<CreateCompanyRequest>,
) -> Result<(StatusCode, Json<CompanyResponse>), StatusCode> {
    let response = {
        let mut crm = state.crm.write().expect("CRM lock poisoned");
        let id = crm
            .add_company(request.name, request.website)
            .map_err(|_| StatusCode::UNPROCESSABLE_ENTITY)?;
        CompanyResponse::from(crm.companies.get(id).expect("just inserted"))
    }; // <- write guard dropped here, BEFORE the .await below

    state.persist().await.map_err(|e| {
        eprintln!("Error: {:#}", anyhow::Error::from(e));
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    Ok((StatusCode::CREATED, Json(response)))
}
```

### How can Axum call a function with *any* arguments?

There's no reflection in Rust, and no runtime parameter inspection. Axum uses **traits**,
the same tool you've used since Lab 15.

**Extractors** are types that know how to build themselves from a request. Simplified, the two
traits are:

```rust
// For things that only need the request "head" (method, URI, headers, state):
pub trait FromRequestParts<S>: Sized {
    type Rejection: IntoResponse;
    fn from_request_parts(parts: &mut Parts, state: &S)
        -> impl Future<Output = Result<Self, Self::Rejection>> + Send;
}

// For things that need the body (consume the whole request):
pub trait FromRequest<S>: Sized {
    type Rejection: IntoResponse;
    fn from_request(req: Request, state: &S)
        -> impl Future<Output = Result<Self, Self::Rejection>> + Send;
}
```

| Extractor | Trait | Builds itself from | Rejection if it can't |
|---|---|---|---|
| `State<AppState>` | `FromRequestParts` | a **clone** of the router's state | — (can't fail) |
| `Path<u64>` | `FromRequestParts` | the `{id}` segment, parsed with serde | `400 Bad Request` |
| `Json<CreateCompanyRequest>` | `FromRequest` | the body, as JSON | `415`, `400` or `422` |

Then axum has a `Handler` trait, and implements it (with a macro) for every `async fn` whose
arguments are **all extractors** and whose return type implements **`IntoResponse`**: for
`fn(T1)`, `fn(T1, T2)`, and so on up to 16 arguments. When you write
`.route("/companies", get(list_companies))`, the compiler checks that `list_companies`
implements `Handler`. Generic code plus trait bounds, checked at compile time.

Notice the **ownership rule** baked into the traits: `FromRequestParts` gets `&mut Parts`
(borrowed, so several extractors can each look), but `FromRequest` gets the `Request` **by
value**, because reading the body consumes it. A body can only be read once. That's why the
body-consuming extractor (`Json`) must be the **last** argument. Put it first and the handler no
longer implements `Handler`.

`State(state): State<AppState>` is **pattern matching in the parameter list** (Lab 11). `State`
is a tuple struct `pub struct State<S>(pub S)`, and the pattern destructures it, so the body gets
`state: AppState` directly. Same for `Path(id)` and `Json(request)`.

### Return types: `IntoResponse`

| You return | Response |
|---|---|
| `Json<T>` where `T: Serialize` | `200`, `content-type: application/json` |
| `StatusCode` | that status, empty body |
| `(StatusCode, Json<T>)` | that status + JSON body (tuples combine parts) |
| `Result<T, E>` where both are `IntoResponse` | whichever variant you return |

So `?` works in handlers exactly as in any function: `.map_err(|_| StatusCode::UNPROCESSABLE_ENTITY)?`
returns early with a 422. In this lab we squash every domain error into a status code and lose
the message. Lab 28 replaces `StatusCode` with a real `ApiError` type that implements
`IntoResponse`.

### The guard-before-await rule, in practice

Look at `create_company` again: the write guard lives inside a **block** that produces the
`response` value, and it's dropped at the `}`, **before** `state.persist().await`. That's the
Lab 26 rule. And here it's not only about `Send`: `persist()` takes a **read** lock. If our handler
still held the **write** lock while awaiting `persist()`, the save would wait for us, and we'd
wait for the save. That's a deadlock, even with an async-aware lock.

> 🟡 **EXPERIMENT**: rewrite `create_company`'s body the "obvious" way, keeping the guard for the
> whole handler, and run `cargo check`:
>
> ```rust
>     // 🟡 keep the guard for the whole handler
>     let mut crm = state.crm.write().expect("CRM lock poisoned");
>     let id = crm
>         .add_company(request.name, request.website)
>         .map_err(|_| StatusCode::UNPROCESSABLE_ENTITY)?;
>
>     state.persist().await.map_err(|e| {
>         eprintln!("Error: {:#}", anyhow::Error::from(e));
>         StatusCode::INTERNAL_SERVER_ERROR
>     })?;
>     let response = CompanyResponse::from(crm.companies.get(id).expect("just inserted"));
>     Ok((StatusCode::CREATED, Json(response)))
> ```

(Do Step 6 first if `router` doesn't exist yet. The error appears where the handler is
registered.)

```text
error[E0277]: the trait bound `fn(State<AppState>, Json<_>) -> _ {create_company}: Handler<_, _>` is not satisfied
   --> src/http/mod.rs:18:49
    |
 18 |             get(companies::list_companies).post(companies::create_company),
    |                                            ---- ^^^^^^^^^^^^^^^^^^^^^^^^^ the trait `Handler<_, AppState>` is not implemented for fn item `fn(State<AppState>, Json<CreateCompanyRequest>) -> _ {create_company}`
    |                                            |
    |                                            required by a bound introduced by this call
    |
    = note: Consider using `#[axum::debug_handler]` to improve the error message
note: required by a bound in `MethodRouter::<S>::post`
```

This is the most infamous error in Axum. It says the function doesn't implement `Handler`, but
not *why*. Take the hint: add the macros feature and annotate the handler.

```bash
cargo add axum --features macros
```

```rust
/// `POST /companies`
#[axum::debug_handler]
pub async fn create_company(
```

```text
error: future cannot be sent between threads safely
  --> src/http/companies.rs:57:1
   |
57 | #[axum::debug_handler]
   | ^^^^^^^^^^^^^^^^^^^^^^ future returned by `create_company` is not `Send`
   |
   = help: within `impl Future<Output = Result<(StatusCode, Json<CompanyResponse>), StatusCode>>`, the trait `Send` is not implemented for `std::sync::RwLockWriteGuard<'_, Crm>`
note: future is not `Send` as this value is used across an await
  --> src/http/companies.rs:68:21
   |
63 |     let mut crm = state.crm.write().expect("CRM lock poisoned");
   |         ------- has type `std::sync::RwLockWriteGuard<'_, Crm>` which is not `Send`
...
68 |     state.persist().await.map_err(|e| {
   |                     ^^^^^ await occurs here, with `mut crm` maybe used later
```

Now it's the error you know from Lab 26. `Handler` is only implemented for functions whose
future is `Send`. The guard lives across `.await`, so the future isn't `Send`, so there's no
`Handler`.

Restore the block version. You can keep the `macros` feature. `#[axum::debug_handler]` is worth
reaching for whenever you see a `Handler<_, _>` error. Remove the attribute itself once the
handler compiles (it only adds checks; it's harmless to leave, but noisy).

---

## Step 6 — The router and the server

> 🟢 **FOLLOW ALONG**: `src/http/health.rs`:

```rust
use axum::Json;
use serde_json::{Value, json};

/// `GET /health`: is the process up?
pub async fn health() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}
```

`health` takes **no** extractors. Zero arguments is a valid handler too. `serde_json::json!`
builds an ad-hoc `Value`. That's fine for a fixed two-field body. For real resources we use typed
DTOs.

`src/http/mod.rs`:

```rust
//! The HTTP API.

use axum::Router;
use axum::routing::get;

pub mod companies;
mod health;
mod state;

pub use state::AppState;

/// Every route the API serves, with the shared state attached.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route(
            "/companies",
            get(companies::list_companies).post(companies::create_company),
        )
        .route("/companies/{id}", get(companies::get_company))
        .with_state(state)
}
```

and register the module in `src/lib.rs`: `pub mod http;`.

- `get(a).post(b)` builds a **method router**: one path, a handler per HTTP method. A request
  with any other method gets `405 Method Not Allowed` with an `allow` header for free.
- `/{id}` is a **path parameter** (axum 0.8 syntax; 0.7 and older used `/:id`). Its value goes to
  the `Path` extractor.
- **`.with_state(state)`**: before this call, the router has type `Router<AppState>`, a router
  that still *needs* an `AppState`. Every handler wanting `State<AppState>` is checked against
  that type parameter. `.with_state` supplies the state and returns `Router<()>` (written
  `Router`), which is ready to serve. If a handler asks for `State<SomethingElse>`, you get a
  compile error, not a runtime surprise.
- `router` lives in the **library**, not in `main.rs`. In Lab 29 your tests will call
  `rust_crm::http::router(AppState::in_memory())` and send requests to it without opening a
  socket. Same reasoning as Lab 13 → Lab 24.
- `AppState` is re-exported, so its public path is `rust_crm::http::AppState`.

> 🟢 **FOLLOW ALONG**: replace the placeholder `src/main.rs` with the server:

```rust
//! The CRM HTTP server.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use rust_crm::http::{self, AppState};
use rust_crm::storage::{JsonFileStorage, Storage};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let data_file: PathBuf = std::env::var("CRM_DATA_FILE")
        .unwrap_or_else(|_| "crm-data.json".to_string())
        .into();
    let port: u16 = match std::env::var("PORT") {
        Ok(port) => port
            .parse()
            .context("PORT must be a number between 0 and 65535")?,
        Err(_) => 3000,
    };

    let storage: Arc<dyn Storage> = Arc::new(JsonFileStorage::new(&data_file));
    let crm = storage
        .load()
        .with_context(|| format!("could not load {}", data_file.display()))?;
    println!(
        "Loaded {} companies and {} contacts from {}",
        crm.companies.len(),
        crm.contacts.len(),
        data_file.display()
    );

    let app = http::router(AppState::new(crm, storage));

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("could not listen on {addr}"))?;
    println!(
        "Rust CRM API v{} listening on http://{addr}",
        env!("CARGO_PKG_VERSION")
    );
    axum::serve(listener, app).await?;
    Ok(())
}
```

(If your `JsonFileStorage::new` takes a `PathBuf` rather than `impl Into<PathBuf>`, pass
`data_file.clone()`.)

- **Configuration from environment variables**: the same `CRM_DATA_FILE` that `crm-cli` reads
  (via clap's `env`), plus `PORT`. Clap would be overkill for two values. In Lab 38 all of this
  moves into one typed `Settings` struct.
- **`127.0.0.1`, not `0.0.0.0`**: only programs on your machine can connect. An unauthenticated
  CRM shouldn't listen on your Wi-Fi. (Docker in Lab 40 needs `0.0.0.0`, and by then there's auth.)
- **`axum::serve(listener, app).await`** runs forever: accept a connection, spawn a task,
  repeat. Ctrl-C kills the process. That's safe here because every write was persisted before its
  response was sent. Graceful shutdown arrives in Lab 38.

```bash
cargo clippy --all-targets -- -D warnings
```

---

## ▶️ Run It

Use a throwaway data file so the outputs match:

```bash
rm -f demo.json
CRM_DATA_FILE=demo.json cargo run
```

In a second terminal:

```bash
curl http://127.0.0.1:3000/health
curl -X POST http://127.0.0.1:3000/companies \
     -H 'content-type: application/json' \
     -d '{"name": "Acme Corp", "website": "https://acme.example"}'
curl -X POST http://127.0.0.1:3000/companies \
     -H 'content-type: application/json' \
     -d '{"name": "Globex"}'
curl http://127.0.0.1:3000/companies
curl http://127.0.0.1:3000/companies/2
curl -i http://127.0.0.1:3000/companies/99
```

(`-i` prints the status line and headers. `| jq` pretty-prints JSON if you have `jq`.)

## ✅ Expected Result

Server terminal:

```text
Loaded 0 companies and 0 contacts from demo.json
Rust CRM API v0.1.0 listening on http://127.0.0.1:3000
```

Client terminal:

```text
$ curl http://127.0.0.1:3000/health
{"status":"ok"}
$ curl -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"name": "Acme Corp", "website": "https://acme.example"}'
{"id":1,"name":"Acme Corp","website":"https://acme.example","lifecycle":"prospect"}
$ curl -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"name": "Globex"}'
{"id":2,"name":"Globex","website":null,"lifecycle":"prospect"}
$ curl http://127.0.0.1:3000/companies
[{"id":1,"name":"Acme Corp","website":"https://acme.example","lifecycle":"prospect"},{"id":2,"name":"Globex","website":null,"lifecycle":"prospect"}]
$ curl http://127.0.0.1:3000/companies/2
{"id":2,"name":"Globex","website":null,"lifecycle":"prospect"}
$ curl -i http://127.0.0.1:3000/companies/99
HTTP/1.1 404 Not Found
content-length: 0
date: Mon, 05 Oct 2026 14:41:27 GMT

```

`demo.json` now contains both companies, written by `persist()` after each `POST`. Stop the
server (Ctrl-C), start it again, and `GET /companies` still returns both.

The REPL still works on the same file:

```bash
CRM_DATA_FILE=demo.json cargo run --bin crm-cli
```

---

## 🧠 Understand It

### The life of `POST /companies`

```text
1. hyper task: parse request ─► Router matches POST /companies ─► create_company's Handler impl
2. extract State<AppState>      ← clone of the router's AppState (two Arc bumps)
3. extract Json<CreateCompanyRequest>  ← consumes the body; serde validates the shape
      ├─ no content-type: application/json → 415, handler never runs
      ├─ not JSON at all                   → 400, handler never runs
      └─ JSON, but missing "name"          → 422, handler never runs
4. your code:
      { write lock ── add_company ── build CompanyResponse (owned) } ← lock released
      persist().await  ─► blocking pool: read lock ── save ── unlock
5. (StatusCode::CREATED, Json(response)).into_response() ─► 201 + JSON bytes
6. the request's AppState clone is dropped (two Arc decrements)
```

### Ownership per request

| Value | Who owns it during the request | Why |
|---|---|---|
| `AppState` | the handler (a clone) | `'static` task: can't borrow from `main` |
| `Crm` | the `RwLock` in the shared `ArcInner` | one CRM, many requests |
| `CreateCompanyRequest` | the handler, then **moved** into `add_company` | its `String`s become the company's: no copy |
| `CompanyResponse` | the handler, then moved into `Json`, then into the response | must outlive the lock guard |

Look at the third row: `request.name` is a `String` deserialized from the body. We **move** it
into `add_company(request.name, request.website)`, which moves it into the new `Company` in the
repo. The bytes the client sent end up stored in the CRM, and nothing is cloned. It's Lab 06's
ownership model at work in a web handler.

### Rejections: what happens before your handler runs

Try a few broken requests and look at what you get. These responses come from axum's extractors
(their `Rejection` types), not from your code:

```text
$ curl -i http://127.0.0.1:3000/companies/abc
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8

Invalid URL: Cannot parse `abc` to a `u64`

$ curl -i -X POST http://127.0.0.1:3000/companies -d '{"name":"No header"}'
HTTP/1.1 415 Unsupported Media Type
content-type: text/plain; charset=utf-8

Expected request with `Content-Type: application/json`

$ curl -i -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"website":"x"}'
HTTP/1.1 422 Unprocessable Entity
content-type: text/plain; charset=utf-8

Failed to deserialize the JSON body into the target type: missing field `name` at line 1 column 15

$ curl -i -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"name": '
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8

Failed to parse the request body as JSON: name: EOF while parsing a value at line 1 column 9

$ curl -i -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"name": "  "}'
HTTP/1.1 422 Unprocessable Entity

$ curl -i -X DELETE http://127.0.0.1:3000/companies/1
HTTP/1.1 405 Method Not Allowed
allow: GET,HEAD
```

(`content-length` and `date` headers omitted.) Notice the inconsistency: axum's rejections are
**plain text** with helpful messages, while our own errors are **empty bodies**. A frontend
developer would have to handle three formats. Fixing that is exactly Lab 28's job.

### Domain errors, for now

`create_company` maps *every* `CrmError` to `422`. For `add_company` that's honest, because the
only failure is validation (`EmptyName`). But we throw away the message. Lab 28 introduces
`ApiError` with `impl From<CrmError>` and `impl IntoResponse`, so handlers can just use `?`, and
each error maps to the right status with a JSON body. You've already got all the pieces from Labs
12, 15 and 22.

### ⚠️ Two binaries, one JSON file

`crm-cli` and the server can now both point at the same `crm-data.json`. **Never run them at the
same time against the same file.** Each process loads the file **once** into its own memory and
then writes its **whole** in-memory snapshot back. Neither knows the other exists, so the last
writer silently erases the other's changes. 🧪 Experiment 2 shows it happening.

No type system can catch this. `Arc`, `RwLock` and `Send` protect memory *inside one process*.
Two processes share nothing but a file. You could add a lock file, re-read the file before every
write, or merge changes… and you'd be building a bad database. The real answer is a real one:
**PostgreSQL in Lab 30**, which handles concurrent writers, constraints and queries. That lab
also retires `crm-cli`, and this problem is a big part of why.

---

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 — Remove `#[derive(Clone)]` from `AppState`.** Predict where the errors will
> appear, then `cargo check`.

You'll get errors in two very different places:

```text
error[E0521]: borrowed data escapes outside of method
  --> src/http/state.rs:35:9
   |
33 |       pub async fn persist(&self) -> Result<(), StorageError> {
   |                            -----
   |                            |
   |                            `self` is a reference that is only valid in the method body
   |                            let's call the lifetime of this reference `'1`
34 |           let state = self.clone();
35 | /         task::spawn_blocking(move || {
...
   | |__________`self` escapes the method body here
   |            argument requires that `'1` must outlive `'static`

error[E0277]: the trait bound `fn(State<AppState>) -> _ {list_companies}: Handler<_, _>` is not satisfied
```

The second one is "`State<AppState>` needs `AppState: Clone`" in disguise. The first is a
classic Rust trap: without `Clone` on `AppState`, `self.clone()` still compiles, because
`&AppState` is `Clone` (every shared reference is `Copy`). So `state` is just another
**reference**, and moving a reference into `spawn_blocking` breaks `'static`. If `.clone()` gives
you a confusing lifetime error, check *what* is being cloned. Put the derive back.

> 🟡 **EXPERIMENT 2 — Lose an update between the two binaries.** With `demo.json` from Run It
> (two companies):
>
> 1. Start the server: `CRM_DATA_FILE=demo.json cargo run`
> 2. In another terminal, add a company with the REPL and quit:
>    `CRM_DATA_FILE=demo.json cargo run -q --bin crm-cli`, then `company add`, `Umbrella`,
>    Enter, `quit`
> 3. Create a company through the API:
>    `curl -X POST http://127.0.0.1:3000/companies -H 'content-type: application/json' -d '{"name":"Hooli"}'`
> 4. List with the REPL again: `company list`

```text
crm> company add
Name: Umbrella
Website (optional):
Added company #3
crm> quit
…
$ curl -X POST … -d '{"name":"Hooli"}'
{"id":3,"name":"Hooli","website":null,"lifecycle":"prospect"}
…
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  https://acme.example
#2   Globex               prospect  -
#3   Hooli                prospect  -
```

(Start a **fresh** server in step 1, as written. A server that has been running since Run It may
have used up id 3 already: `add_company` hands out an id before it validates the name, so the
`{"name": "  "}` request from the rejections list above burns one.)

Umbrella is **gone**, and both programs handed out id `#3` to different companies. The server
never saw the REPL's write, and its `persist()` overwrote the file with its own stale snapshot
plus Hooli. Each program is correct on its own, and together they lose data. Remember this when
someone asks why you need a database server.

> 🟡 **EXPERIMENT 3 — Old path syntax.** Change `"/companies/{id}"` to `"/companies/:id"` and run
> the server. Does it compile? What happens at startup?

```text
thread 'main' (665512) panicked at src/http/mod.rs:20:10:
Path segments must not start with `:`. For capture groups, use `{capture}`. If you meant to literally match a segment starting with a colon, call `without_v07_checks` on the router.
```

It compiles (a path is just a `&str` to the compiler) and panics as soon as the router is built.
Axum 0.8 checks on purpose for the 0.7 syntax you'll still find in older blog posts. Put `{id}`
back.

> 🟡 **EXPERIMENT 4 — Swap extractor order.** In `create_company`, put the `Json` parameter
> first and `State` second. What does the compiler say? Add `#[axum::debug_handler]` and compare.
> Why must the body extractor be last?

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — `GET /contacts`**
>
> Create `src/http/contacts.rs` (`pub mod contacts;` in `http/mod.rs`) with a `ContactResponse`
> DTO and a `list_contacts` handler.

- [ ] `ContactResponse { id: u64, name: String, email: String, phone: Option<String>, company_id: Option<u64> }`
      derives `Serialize`, with `impl From<&Contact> for ContactResponse`
- [ ] `email` is a plain JSON string (`"ada@acme.example"`), and `company_id` is a number or `null`
- [ ] `GET /contacts` → `200` with a JSON array of all contacts
- [ ] the handler holds only a **read** lock

> 🔵 **YOUR TURN 2 — `GET /contacts/{id}`**

- [ ] `get_contact` returns the contact as JSON, or `404` with an empty body if it doesn't exist
- [ ] `GET /contacts/abc` is rejected by the extractor with `400` (you write no code for that)

> 🔵 **YOUR TURN 3 — `DELETE /companies/{id}`**
>
> Use `Crm::remove_company` (Lab 14), which refuses to delete a company that still has contacts.

- [ ] success → `204 No Content`, empty body; the deletion is persisted
- [ ] unknown id → `404`; company with contacts → `409 Conflict`
- [ ] map the `CrmError` variants explicitly with a `match` (no `_ =>` that turns everything
      into one status, except for a deliberate fallback to `500`)
- [ ] the write guard is dropped **before** `persist().await`
- [ ] registered on the existing `/companies/{id}` route (one path, two methods)

### Acceptance run

Add a contact with the REPL **while the server is stopped** (one writer at a time!), then start
the server:

```bash
CRM_DATA_FILE=demo.json cargo run -q --bin crm-cli
#   contact add → Ada Lovelace / ada@acme.example / 555-0100 / 1 (the company id) → quit
CRM_DATA_FILE=demo.json cargo run
```

```text
$ curl http://127.0.0.1:3000/contacts
[{"id":1,"name":"Ada Lovelace","email":"ada@acme.example","phone":"555-0100","company_id":1}]
$ curl http://127.0.0.1:3000/contacts/1
{"id":1,"name":"Ada Lovelace","email":"ada@acme.example","phone":"555-0100","company_id":1}
$ curl -i http://127.0.0.1:3000/contacts/42
HTTP/1.1 404 Not Found
$ curl -i -X DELETE http://127.0.0.1:3000/companies/1
HTTP/1.1 409 Conflict
$ curl -i -X DELETE http://127.0.0.1:3000/companies/2
HTTP/1.1 204 No Content
$ curl -i -X DELETE http://127.0.0.1:3000/companies/2
HTTP/1.1 404 Not Found
```

(Header lines other than the status omitted. If you did Experiment 2, your ids will differ.
Start from a fresh `demo.json` for exact output.)

- [ ] `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` passes

---

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `companies.rs` is your template. What's different is converting the
> *types* inside `From<&Contact>`: `Email` → `String`, `Option<CompanyId>` → `Option<u64>`.

<details><summary>Hint 2 (more specific)</summary>

`c.email.as_str().to_string()` (or your `From<Email> for String` from Lab 21, applied to a
clone). `c.company_id.map(|id| id.0)`: `Option::map` from Lab 12 reaches inside the option.

</details>

> 💡 **HINT (Your Turn 2)**: copy `get_company`'s shape. Which ID newtype do you wrap the `u64` in?

> 💡 **HINT (Your Turn 3)**: copy `create_company`'s block structure: `{ write lock; do the domain
> operation; }` then `persist().await`. The handler's return type can be
> `Result<StatusCode, StatusCode>`.

<details><summary>Hint 2 (more specific)</summary>

```text
crm.remove_company(CompanyId(id)).map_err(|e| match e {
    CrmError::NotFound { .. } => …,
    CrmError::HasContacts(_)  => …,
    _ => StatusCode::INTERNAL_SERVER_ERROR, // not expected from remove_company
})?;
```

In the router: `get(companies::get_company).delete(companies::delete_company)`.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. How does Axum know how to call `get_company(State(state), Path(id))`? Name the traits
   involved.
2. Why must `Json<T>` be the last argument of a handler? Answer in terms of ownership.
3. Why does `AppState` derive `Clone`, and why is cloning it cheap? What would go wrong if it
   held a `Crm` directly?
4. Why `std::sync::RwLock` and not `tokio::sync::RwLock`? Under what change would you switch?
5. In `create_company`, besides the `Send` error, what would happen at runtime if the write guard
   were still alive during `persist().await`?
6. Give three reasons the API returns `CompanyResponse` instead of serializing `Company`.
7. Why can't Rust's type system prevent the lost update in Experiment 2?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit

You committed Step 1 already. Now the server:

```bash
rm -f demo.json
git add .
git commit -m "Add HTTP server with company endpoints"
git tag lab-27
git push && git push --tags
```

`git log --oneline lab-26..lab-27` shows the two commits: first the refactor, then the feature.

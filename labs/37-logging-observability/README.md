# Lab 37 — Logging & Observability

> **Phase:** 11 — Production-Ready · **Builds on:** Lab 36 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-36` · **After:** tag `lab-37`

## 🎯 Goal
Replace every `println!`/`eprintln!` with **structured, request-scoped logs**: every request
gets an ID, every log line knows which request (and which user) it belongs to, and you can
follow one request from the HTTP layer down to the SQL it ran.

## 🧠 What You'll Learn
- Why `println!` is not logging, and what "structured" logging means
- The `tracing` mental model: **events** (points in time) vs **spans** (context with a duration)
- Subscribers and **layers**: filter → format → output, and how `tracing-subscriber` composes them
- `RUST_LOG` / `EnvFilter` directives (`rust_crm=debug,sqlx=warn`)
- `#[instrument]`, and why `skip` / `skip_all` is a **security** feature, not a convenience
- `tower-http`'s `TraceLayer` and request IDs (`x-request-id`) end to end
- Middleware ordering with `tower::ServiceBuilder` (the onion)
- Logging the **cause chain** of a 500 **exactly once**
- Pretty logs for humans in development, JSON logs for machines in production

## 🔨 What We're Building

```text
rust-crm/
├── Cargo.toml              ← + tracing, tracing-subscriber, tower-http, tower
├── src/
│   ├── telemetry.rs        ← NEW: LogFormat + telemetry::init()
│   ├── main.rs             ← init telemetry first; println! → tracing::info!
│   ├── http/mod.rs         ← request-id + TraceLayer middleware, one span per request
│   ├── http/error.rs       ← 500s logged with their cause chain (eprintln! is gone)
│   ├── auth/middleware.rs  ← 🔵 records user_id on the request span
│   ├── http/deals.rs       ← #[instrument] on handlers
│   └── deals/db.rs         ← #[instrument] on queries
```

Since Lab 27 your CRM has printed one line at startup and the odd `eprintln!` when something
broke. That was fine on your laptop with one user. Now imagine three sales reps using it at
once and one of them says *"I got an internal error around 10:15"*. With what you have today you
can't answer *which* request failed, *for whom*, or *why*. After this lab you can.

> This lab starts from the end of Lab 36. If you did the optional **Challenge E** (teams), keep
> it: nothing here depends on it, and everything here applies to your team routes too.

Written against **tracing 0.1**, **tracing-subscriber 0.3**, **tower-http 0.7**, **tower 0.5**,
**axum 0.8** and **sqlx 0.9**. If an API looks different in your version, check docs.rs for the
major version you have.

---

## Step 1 — Why `println!` isn't logging

Find every place your CRM currently "logs":

```bash
grep -rn "println!\|eprintln!" src/
```

You should find at least two (your exact lines may differ):

```text
src/main.rs:36:    println!("Listening on http://{}", listener.local_addr()?);
src/http/error.rs:98:            eprintln!("internal error: {message}");
```

Now picture the server handling 50 requests a second, and that `eprintln!` firing once:

```text
internal error: pool timed out while waiting for an open connection
```

Ask the questions an on-call engineer would ask:

| Question | Can `eprintln!` answer it? |
|---|---|
| **When** did it happen? | No timestamp |
| **How bad** is it? | No level (is this an error? a debug note?) |
| **Which request** was it? | No: 50 requests a second are interleaved on the same stderr |
| **Which user**? Which deal? | Only if you remembered to format them into the string |
| Can I **filter** to "only errors from the deals module"? | No |
| Can a log platform **parse** it? | Only with a fragile regex |

The fix isn't "add a timestamp to the format string". It's a different model:

- **Levels** (`ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE`) so you can filter by severity.
- **Targets** (the module path, e.g. `rust_crm::http::deals`) so you can filter by *where*.
- **Fields**: `deal_id=7 user_id=3` as *data*, not as text glued into a sentence.
- **Context**: a log line emitted deep inside a SQL helper should automatically carry the
  request ID of the HTTP request that caused it, without you passing the ID down by hand.

That last point is what the `tracing` crate is built around.

## Step 2 — The `tracing` mental model

If you've used a structured logger like pino in Node, events will feel familiar. Spans are
the part Node logging usually doesn't have (it's closer to OpenTelemetry tracing).

### Events: something happened, at one point in time

```rust
tracing::info!(deal_id = 7, "deal created");
tracing::warn!(reason = "wrong_password", "login failed");
tracing::error!(error = %err, "internal server error");
```

An event has a **level**, a **target** (the module it came from, filled in automatically), a
**message**, and any number of **fields**. Two sigils matter:

| Syntax | Records the value using | Example |
|---|---|---|
| `field = %value` | `Display` | `error = %err` → `error=pool timed out` |
| `field = ?value` | `Debug` | `id = ?deal.id` → `id=DealId(7)` |
| `field = value` | the value itself (numbers, bools, `&str`) | `status = 200` |
| `value` (shorthand) | same as `value = value` | `status` |

### Spans: a period of time with context

A span **starts**, may be **entered and exited** many times, and **ends**. While a span is
entered, every event "happens inside it" and inherits its fields:

```text
span: request{method=GET path=/deals/7 request_id=1f3…}          ← created by TraceLayer
 └─ span: get_deal{id=7}                                         ← #[instrument] on the handler
     └─ span: get{id=DealId(7)}                                  ← #[instrument] on the db fn
         └─ event: DEBUG sqlx::query  "SELECT … FROM deals …"   ← inherits ALL of the above
```

Why "entered and exited many times"? Because of async. A handler that awaits a database query
is **suspended** while Postgres works, and the thread runs other requests' futures meanwhile
(Lab 26: futures are state machines that get polled). A span must be entered every time its
future is polled and exited every time the future returns `Pending`, otherwise request A's
context would leak onto request B's log lines. `#[instrument]` and `TraceLayer` do exactly this
for you. (Hold that thought: it's why you must never hold a span's `.enter()` guard across an
`.await`. More in 🧠 Understand It.)

### Subscribers and layers: where events go

`tracing::info!` doesn't print anything by itself. It hands the event to the **subscriber**,
the one global object that decides what to do with spans and events. `tracing-subscriber` lets
you build a subscriber from **layers**, like middleware:

```text
 info!(...) ──▶ Registry (keeps track of which spans are open, and their fields)
                  │
                  ├──▶ EnvFilter layer   "is rust_crm::http::deals at DEBUG enabled?"  (drop if not)
                  │
                  └──▶ fmt layer         format as pretty text OR as JSON → stdout
```

Your code only ever talks to `tracing` (the facade). Which layers exist is decided **once**, in
`main`. Libraries like `sqlx` and `tower-http` emit `tracing` events too, so your subscriber
sees their events, nested inside your spans.

> **`log` vs `tracing`.** The older `log` crate has levels and targets but no spans and no
> structured fields. `tracing` is a superset, and `tracing-subscriber` also captures `log`
> records from crates that still use `log` (that's the `tracing-log` feature, on by default).

## Step 3 — Add the crates

```bash
cargo add tracing
cargo add tracing-subscriber --features env-filter,json
cargo add tower-http --features trace,request-id
cargo add tower
```

- `tracing`: the macros (`info!`, `#[instrument]`, …). Every crate that wants to log uses it.
- `tracing-subscriber`: the layers. `env-filter` gives `RUST_LOG` support, `json` the JSON format.
- `tower-http`: ready-made HTTP middleware. `trace` = `TraceLayer`, `request-id` = request IDs
  (it pulls in `uuid` for you).
- `tower`: you already have it as a **dev**-dependency with `util` (Lab 29's `oneshot`). Now the
  app itself needs `tower::ServiceBuilder`, so it becomes a normal dependency too. Cargo is fine
  with a crate appearing in both tables.

## Step 4 — `src/telemetry.rs`

> 🟢 **FOLLOW ALONG**: create `src/telemetry.rs` and add `pub mod telemetry;` to `src/lib.rs`.

```rust
//! Logging and tracing setup. Call [`init`] exactly once, at the top of `main`.

use std::str::FromStr;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

/// Used when `RUST_LOG` is not set.
const DEFAULT_FILTER: &str = "rust_crm=debug,tower_http=info,sqlx=warn";

/// How log lines are written to stdout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LogFormat {
    /// Human-readable, coloured, one line per event. For your terminal.
    #[default]
    Pretty,
    /// One JSON object per line. For machines (log shippers, Loki, Datadog...).
    Json,
}

impl FromStr for LogFormat {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "pretty" => Ok(LogFormat::Pretty),
            "json" => Ok(LogFormat::Json),
            other => Err(format!(
                "unknown log format '{other}' (expected 'pretty' or 'json')"
            )),
        }
    }
}

impl LogFormat {
    /// Reads `LOG_FORMAT`; missing → Pretty. (Lab 38 moves this into `Settings`.)
    pub fn from_env() -> Result<Self, String> {
        match std::env::var("LOG_FORMAT") {
            Ok(value) => value.parse(),
            Err(_) => Ok(LogFormat::default()),
        }
    }
}

/// Installs the global subscriber: an `EnvFilter` plus ONE formatting layer.
///
/// # Panics
/// If a global subscriber is already installed (i.e. if called twice).
pub fn init(format: LogFormat) {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));

    let (pretty, json) = match format {
        LogFormat::Pretty => (Some(fmt::layer()), None),
        LogFormat::Json => (None, Some(fmt::layer().json().flatten_event(true))),
    };

    tracing_subscriber::registry()
        .with(filter)
        .with(pretty)
        .with(json)
        .init();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_log_formats_case_insensitively() {
        assert_eq!("json".parse::<LogFormat>(), Ok(LogFormat::Json));
        assert_eq!(" Pretty ".parse::<LogFormat>(), Ok(LogFormat::Pretty));
        assert!("xml".parse::<LogFormat>().is_err());
    }
}
```

Three things deserve a closer look.

**1. The filter directives.** `EnvFilter` reads `RUST_LOG` (falling back to `DEFAULT_FILTER`).
The syntax is a comma-separated list of `target=level`:

| Directive | Meaning |
|---|---|
| `rust_crm=debug` | Our crate (lib **and** binary are both called `rust_crm`): DEBUG and above |
| `tower_http=info` | One INFO line per request from `TraceLayer` |
| `sqlx=warn` | Only sqlx warnings (e.g. slow connection acquisition). At `debug` it logs **every query** |
| `rust_crm::http=trace` | A more specific target wins over a less specific one |
| `warn` (no `=`) | The default for every target not mentioned |

Targets not matched by any directive are **off**. That's why `DEFAULT_FILTER` lists the three
targets we care about and nothing else.

**2. Why `Option<Layer>`?** You might try:

```rust
let layer = match format {
    LogFormat::Pretty => fmt::layer(),
    LogFormat::Json => fmt::layer().json(),
};
```

That doesn't compile: the two arms have **different types** (the JSON layer is a different
generic instantiation of `fmt::Layer`), and a `match` must produce one type. You met this in
Lab 23 and chose between `Box<dyn Trait>` and generics. `tracing-subscriber` offers a third way:
`Option<L>` implements `Layer` whenever `L` does, and `None` is a layer that does nothing. So we
build *both* slots and fill exactly one. Same type every time, zero dynamic dispatch.

**3. `init()` can only happen once.** There is one global subscriber per process. A second call
panics. That's why only `main` calls it, never library code and never a test helper that runs
in parallel with other tests.

## Step 5 — Initialise it first in `main`

> 🟢 **FOLLOW ALONG**: in `src/main.rs`, call `telemetry::init` right after loading `.env`, and
> replace the `println!`.

```rust
use rust_crm::telemetry::{self, LogFormat};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let log_format = LogFormat::from_env().map_err(anyhow::Error::msg)?;
    telemetry::init(log_format);

    // ... everything you already have: DATABASE_URL, JWT_SECRET, pool, migrations, state,
    //     PORT and the TcpListener::bind(("127.0.0.1", port)) ...

    tracing::info!(address = %listener.local_addr()?, "listening"); // was println!
    axum::serve(listener, router(state)).await?;
    Ok(())
}
```

Why first? Anything logged **before** `init` goes nowhere: there's no subscriber yet. You
want the migration and connection steps to be able to log.

`map_err(anyhow::Error::msg)`: our `from_env` returns `Result<_, String>`, and `String` doesn't
implement `std::error::Error`, so `?` can't convert it into `anyhow::Error` automatically.
`anyhow::Error::msg` builds one from any `Display` value.

```bash
docker compose up -d db
cargo run
```

```text
2026-10-05T14:46:38.813719Z  INFO rust_crm: listening address=127.0.0.1:3000
```

Timestamp, level, target, message, and `address` as a **field**. Stop the server with Ctrl+C.

## Step 6 — One span per request, with a request ID

Now the important part: every request should get its own span, and that span should carry an
ID that the **client also sees**, so a user can send you "request id `1f3…`" in a bug report.

`tower-http` gives us three middlewares:

| Layer | Job |
|---|---|
| `SetRequestIdLayer::x_request_id(MakeRequestUuid)` | If the request has no `x-request-id` header, generate a UUID v4 and **insert the header** |
| `TraceLayer::new_for_http()` | Create a span per request, log when the response is ready |
| `PropagateRequestIdLayer::x_request_id()` | Copy `x-request-id` from the request onto the **response** |

> 🟢 **FOLLOW ALONG**: in `src/http/mod.rs`, add the layers at the end of `router` and a
> function that builds the request span.

```rust
use axum::{Router, body::Body, http::Request, middleware};
use tower::ServiceBuilder;
use tower_http::{
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    trace::{DefaultOnResponse, TraceLayer},
};
use tracing::{Level, Span};

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        // ... your merges and route_layer(require_auth) from Labs 35–36, unchanged ...
        ;

    Router::new()
        .merge(health::routes())
        .merge(auth::public_routes())
        .merge(protected)
        .with_state(state)
        .layer(
            // Listed outermost first: a request travels DOWN this list, the response UP.
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
                .layer(
                    TraceLayer::new_for_http()
                        .make_span_with(make_request_span)
                        .on_response(DefaultOnResponse::new().level(Level::INFO)),
                )
                .layer(PropagateRequestIdLayer::x_request_id()),
        )
}

/// Creates the span that wraps everything that happens while handling one request.
fn make_request_span(request: &Request<Body>) -> Span {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("-");

    tracing::info_span!(
        "request",
        method = %request.method(),
        path = %request.uri().path(),
        request_id = %request_id,
    )
}
```

### The onion: why the order matters

`.layer()` on a `Router` wraps everything added *before* it. `ServiceBuilder` lets you list
several layers in one place, **outermost first**:

```text
request ──▶ SetRequestId ──▶ TraceLayer ──▶ PropagateRequestId ──▶ router ──▶ handler
            (adds header)    (reads header,                         │
                              opens span)                           ▼
response ◀── SetRequestId ◀── TraceLayer ◀── PropagateRequestId ◀── response
                              (logs status,  (copies header
                               latency)       onto response)
```

`TraceLayer` builds the span from the request **as it receives it**. If `SetRequestId` were
*inside* `TraceLayer`, the header wouldn't exist yet when the span is created. You'll prove that
in the experiments.

A few more decisions in `make_request_span`:

- **`path`, not the full `uri`.** The URI includes the query string, e.g.
  `/search?q=jane.doe@client.com`. Query strings carry search terms, emails and sometimes
  tokens. The path is enough to identify the route.
- **`info_span!`**: spans have levels too. An INFO span is enabled whenever INFO events of its
  target are enabled.
- **`.unwrap_or("-")`**: a header value can contain bytes that aren't valid text. We never
  `unwrap()` on data a client controls.
- `make_span_with` accepts any `Fn(&Request<B>) -> Span`. A plain `fn` is the clearest choice.

```bash
cargo run
# in another terminal
curl -i localhost:3000/health
```

```text
HTTP/1.1 200 OK
x-request-id: cf7df8f8-bb1e-4bb2-8294-b251e52a89d3
...
```

And in the server terminal:

```text
2026-10-05T14:46:39.939860Z  INFO request{method=GET path=/health request_id=cf7df8f8-bb1e-4bb2-8294-b251e52a89d3}: tower_http::trace::on_response: finished processing request latency=0 ms status=200
```

The same ID is in the response header and in the log line. That's the whole point.

> 🟡 **EXPERIMENT**: send your own ID: `curl -i -H 'x-request-id: my-trace-123' localhost:3000/health`.
> Predict first: does the server replace it? Look at both the response header and the log.

It keeps yours (`request_id=my-trace-123`). `SetRequestIdLayer` only generates an ID when the
header is missing. This is how IDs flow across services: a frontend or another API generates
one ID and every service logs it. The flip side: a client controls this value, so treat it as
untrusted text (never use it as a database key, never trust its format).

## Step 7 — `#[instrument]`: spans for your own functions

The request span tells you *which request*. Inside it, you often want to know *which function*
and *with which arguments*. `#[tracing::instrument]` wraps a function (sync or async) in a span
named after the function, and records its arguments as fields.

> 🟢 **FOLLOW ALONG**: add `#[instrument]` to the deal handler and the db function it calls.

`src/http/deals.rs`:

```rust
#[tracing::instrument(skip(state, user), fields(user_id = user.id.0))]
async fn get_deal(
    user: AuthUser,
    State(state): State<AppState>,
    AppPath(id): AppPath<i64>,
) -> Result<Json<DealResponse>, ApiError> {
    // unchanged
}
```

`src/deals/db.rs`:

```rust
#[tracing::instrument(skip(db))]
pub async fn get(db: impl PgExecutor<'_>, id: DealId) -> Result<Deal, CrmError> {
    // unchanged
}
```

- `skip(state, user)`: don't record those arguments. `id` (from `AppPath(id)`) is still recorded.
- `fields(user_id = user.id.0)`: add a field computed from an argument.
- `skip(db)`: an executor isn't interesting, and isn't `Debug` anyway.

To see the nesting, temporarily turn on sqlx's per-query logging and fetch a deal (use a token
from `POST /auth/login` and a deal id you own):

```bash
RUST_LOG=rust_crm=debug,tower_http=info,sqlx=debug cargo run
# other terminal
curl -s localhost:3000/deals/1 -H "authorization: Bearer $TOKEN"
```

```text
2026-10-05T14:50:25.287412Z DEBUG request{method=GET path=/deals/1 request_id=c93aba58-ae52-429c-a412-300fb76d740a}:get_deal{id=1 user_id=1}:get{id=DealId(1)}: sqlx::query: summary="SELECT id, company_id, title, …" db.statement="\n\nSELECT id, company_id, title, value_cents, stage, owner_id FROM deals WHERE id = $1\n" rows_affected=1 rows_returned=1 elapsed=1.173916ms elapsed_secs=0.001173916
2026-10-05T14:50:25.287668Z  INFO request{method=GET path=/deals/1 request_id=c93aba58-ae52-429c-a412-300fb76d740a}: tower_http::trace::on_response: finished processing request latency=2 ms status=200
```

Read the prefix of the first line from left to right: **request → handler → db function →
SQL**. sqlx emitted that event; it knows nothing about HTTP, yet the line carries the request
ID. That's span inheritance. You'll also see a few `sqlx::query` lines from the migration
check at startup; they have no request span because no request caused them.

### `skip` is a security feature

> 🟡 **EXPERIMENT**: put a bare `#[tracing::instrument]` on your `login` handler in
> `src/http/auth.rs`. Predict: will it compile? Then run `cargo check`.

```text
error[E0277]: `AppState` doesn't implement `std::fmt::Debug`
   --> src/http/auth.rs:41:1
    |
 41 | #[tracing::instrument]
    | ^^^^^^^^^^^^^^^^^^^^^^ unsatisfied trait bound
    |
help: the trait `std::fmt::Debug` is not implemented for `AppState`
   --> src/http/state.rs:5:1
    |
  5 | pub struct AppState {
    | ^^^^^^^^^^^^^^^^^^^
    = note: add `#[derive(Debug)]` to `AppState` or manually `impl std::fmt::Debug for AppState`
    = note: required for `&AppState` to implement `std::fmt::Debug`
note: required by a bound in `debug`
   --> …/tracing-core-0.1.36/src/field.rs:379:8
    |
377 | pub fn debug<T>(t: T) -> DebugValue<T>
    |        ----- required by a bound in this function
378 | where
379 |     T: fmt::Debug,
    |        ^^^^^^^^^^ required by this bound in `debug`
    = note: this error originates in the attribute macro `tracing::instrument` (in Nightly builds, run with -Z macro-backtrace for more info)
```

**Read the error.** `#[instrument]` records *every* argument with `Debug` unless told otherwise,
so it generates `tracing::field::debug(&state)`. That function requires `T: Debug`. `AppState`
holds a pool and JWT **keys**; it deliberately doesn't derive `Debug`. The compiler stopped you
from logging your signing keys. Do **not** "fix" this by adding `#[derive(Debug)]` to
`AppState`.

> 🟡 **EXPERIMENT (continued)**: change it to `#[tracing::instrument(skip(state))]`, run with
> `RUST_LOG=rust_crm=debug,tower_http=info,sqlx=debug cargo run`, and log in. Look at the
> `sqlx::query` line.

```text
2026-10-05T14:50:36.778905Z DEBUG request{method=POST path=/auth/login request_id=12b503ba-…}:login{req=LoginRequest { email: "ada@example.com", password: SecretBox<str>([REDACTED]) }}: sqlx::query: summary="SELECT id, email, name, …" …
```

Two lessons in one line:

1. **The password is safe** only because Lab 34 made it a `SecretString`, whose `Debug` prints
   `[REDACTED]`. If `password` were a `String`, it would be in your logs right now, on every
   line inside the login span, at whatever log platform you ship to.
2. **The email is not safe.** It's personal data, and it's now attached to every event in the
   span. That may break your privacy policy, and it's searchable by anyone with log access.

So the rule for this course:

> **Use `skip_all` and list the fields you want** (`fields(...)`): an *allowlist*. `skip(a, b)`
> is a *denylist*: every argument you add later is logged by default.

Remove the `#[instrument]` from `login` again. You'll instrument it properly in 🔵 Your Turn 3.

## Step 8 — Log 500s with their cause chain, exactly once

Here's what an internal error looks like today. With the server running, **stop the
database** and request a deal:

```bash
docker compose stop db
curl -s localhost:3000/deals/1 -H "authorization: Bearer $TOKEN"     # takes ~30 s
docker compose start db
```

```text
internal error: pool timed out while waiting for an open connection
2026-10-05T14:47:20.399967Z  INFO request{method=GET path=/deals/1 request_id=5e760c97-…}: tower_http::trace::on_response: finished processing request latency=30004 ms status=500
2026-10-05T14:47:20.400096Z ERROR request{method=GET path=/deals/1 request_id=5e760c97-…}: tower_http::trace::on_failure: response failed classification=Status code: 500 Internal Server Error latency=30004 ms
```

(Why 30 s? sqlx's pool keeps retrying until its `acquire_timeout`, 30 s by default. Lab 40
deals with timeouts for health checks.)

Look at the first line: the only line that says **why** the request failed is the one with **no
timestamp, no level, no request ID**. In production, with JSON logs, it wouldn't even be valid
JSON. And the `ERROR` line that *is* structured doesn't say why.

### Where should an error be logged?

An error travels **up** the call stack via `?`: `deals::db::get` → `load_deal_for` →
`get_deal` → `ApiError` → `IntoResponse`. If every layer logged it ("log and rethrow"), one
failure would produce four ERROR lines, your alerting would count four incidents, and nobody
could tell which lines belong together.

The rule: **log an error once, at the place that handles it (stops propagating it).** In our
API that place is `ApiError::into_response`, specifically the `Internal` arm: that's where a
failure turns into a `500` and is never seen again. Domain errors (404, 409, 422) are *expected
outcomes*, not failures, so they're not logged as errors at all. `TraceLayer` already records
their status.

What to log? Not just the top-level message. An `anyhow::Error` (and any `std::error::Error`)
can have a **chain of causes** via `.source()`: `"issuing token"` caused by `"invalid key"`
caused by … You want the whole chain, on one line, as one field.

> 🔵 **YOUR TURN (mini-task)**: in `src/http/error.rs`, write
>
> ```rust
> /// Renders an error and all of its sources: "outer: cause: root cause".
> pub(crate) fn error_chain(err: &(dyn std::error::Error + 'static)) -> String
> ```
>
> - It starts with `err.to_string()`, then appends `": "` + each source, following
>   `.source()` until there are no more.
> - Add a `#[cfg(test)] mod tests` in `error.rs` with at least two tests: an error with no
>   source returns just its message (e.g. `CrmError::NotFound { .. }`), and an `anyhow` error
>   built with two `.context(...)` calls on top of an `std::io::Error` returns all three
>   messages in order.
>
> (`pub(crate)` because Lab 39's background worker will reuse it.) Solution:
> [`solutions.md` → Mini-task](solutions.md#mini-task--error_chain).

> 🟢 **FOLLOW ALONG**: once `error_chain` passes its tests, move the logging into the
> `Internal` arm of `into_response`. In Lab 28's version the `eprintln!` sits in the
> `if status.is_server_error()` block below the `match`: delete that `eprintln!` line (keep the
> block, it still swaps in the generic message), and log in the arm instead:

```rust
ApiError::Internal(e) => {
    // The ONE place a 500 is logged: full cause chain to the log,
    // a generic message to the client (the is_server_error block below replaces it).
    tracing::error!(error = %error_chain(e.as_ref()), "internal server error");
    (format!("{e:#}"), Vec::new())
}
```

`e.as_ref()`: `anyhow::Error` implements `AsRef<dyn std::error::Error + Send + Sync>`, and a
`&(dyn Error + Send + Sync)` coerces to `&(dyn Error + 'static)` (dropping auto traits is
allowed). If your `ApiError` has other arms that produce a 500 (for example a
`Domain(CrmError::Database(_))` arm), route them through the same log line. If your
`From<CrmError> for ApiError` already turns `CrmError::Database` into `ApiError::Internal`
(yours has since Lab 30), the `Internal` arm sees every database failure.

Run the stop-the-database experiment again:

```text
2026-10-05T14:49:56.418993Z ERROR request{method=GET path=/deals/1 request_id=7c281b3e-6329-469c-b81c-f672d39785fd}: rust_crm::http::error: internal server error error=pool timed out while waiting for an open connection
2026-10-05T14:49:56.419092Z  INFO request{method=GET path=/deals/1 request_id=7c281b3e-6329-469c-b81c-f672d39785fd}: tower_http::trace::on_response: finished processing request latency=30003 ms status=500
2026-10-05T14:49:56.419119Z ERROR request{method=GET path=/deals/1 request_id=7c281b3e-6329-469c-b81c-f672d39785fd}: tower_http::trace::on_failure: response failed classification=Status code: 500 Internal Server Error latency=30003 ms
```

Better: the cause is now structured and carries the request ID. But there are still **two
ERROR lines** for one failure. The second comes from `TraceLayer`'s default `on_failure`
callback, which logs every 5xx. Since `ApiError` owns 500 logging (and `on_response` already
records `status=500`), turn it off:

> 🟢 **FOLLOW ALONG**: in `src/http/mod.rs`:

```rust
TraceLayer::new_for_http()
    .make_span_with(make_request_span)
    .on_response(DefaultOnResponse::new().level(Level::INFO))
    // ApiError already logs every 500 with its cause chain: don't log it twice.
    .on_failure(()),
```

`()` implements tower-http's `OnFailure` trait as "do nothing". The same trick works for every
`TraceLayer` callback.

Finally, check you've caught every stray print:

```bash
grep -rn "println!\|eprintln!" src/
```

Only matches inside `#[cfg(test)]` code are acceptable (test output is captured by `cargo test`),
plus the `// was println!` comment in `main.rs` if you kept it.

---

## ▶️ Run It

```bash
docker compose up -d db
cargo run
```

In another terminal (adjust the email/password to a user you registered in Lab 35):

```bash
curl -s -i localhost:3000/health | grep -i x-request-id
TOKEN=$(curl -s -X POST localhost:3000/auth/login -H 'content-type: application/json' \
  -d '{"email":"ada@example.com","password":"correct horse battery staple"}' | jq -r .access_token)
curl -s localhost:3000/deals/999 -H "authorization: Bearer $TOKEN"
curl -s localhost:3000/deals
```

Then stop the server, and run it again with JSON output:

```bash
LOG_FORMAT=json cargo run
```

## ✅ Expected Result

Pretty format (IDs, timestamps and latencies will differ):

```text
2026-10-05T14:46:38.813719Z  INFO rust_crm: listening address=127.0.0.1:3000
2026-10-05T14:46:39.939860Z  INFO request{method=GET path=/health request_id=cf7df8f8-bb1e-4bb2-8294-b251e52a89d3}: tower_http::trace::on_response: finished processing request latency=0 ms status=200
2026-10-05T14:46:39.993281Z  INFO request{method=POST path=/auth/login request_id=a529c91a-8f37-4ef6-bf95-1c087a7a3093}: tower_http::trace::on_response: finished processing request latency=15 ms status=200
2026-10-05T14:46:40.004423Z  INFO request{method=GET path=/deals/999 request_id=f1fc8d96-35ff-4e93-b742-e151cd8dc7d9}: tower_http::trace::on_response: finished processing request latency=0 ms status=404
2026-10-05T14:46:40.009681Z  INFO request{method=GET path=/deals request_id=c56a370a-ddb0-47b4-a4a8-5be9f5ff3373}: tower_http::trace::on_response: finished processing request latency=0 ms status=401
```

JSON format, one object per line (pipe through `jq` to read it):

```json
{"timestamp":"2026-10-05T15:02:20.109216Z","level":"INFO","message":"listening","address":"127.0.0.1:3000","target":"rust_crm"}
{"timestamp":"2026-10-05T15:02:21.239107Z","level":"INFO","message":"finished processing request","latency":"0 ms","status":200,"target":"tower_http::trace::on_response","span":{"method":"GET","path":"/health","request_id":"a6588f8a-4447-4902-986c-f1d9f34308ac","name":"request"},"spans":[{"method":"GET","path":"/health","request_id":"a6588f8a-4447-4902-986c-f1d9f34308ac","name":"request"}]}
```

- `span` is the innermost span; `spans` is the whole stack, outermost first.
- `flatten_event(true)` put the event's fields (`status`, `latency`) at the top level instead
  of under a nested `"fields"` object, which makes queries like `status >= 500` simpler.
- `cargo test` passes, including your `error_chain` tests and the `LogFormat` test.

## 🧠 Understand It

**Events vs spans, one more time.** An event is a *fact* ("deal created", "login failed"). A
span is a *context* ("while handling request X, while running `get_deal` for id 7"). Facts get
logged; contexts get *attached* to the facts that happen inside them. You never write the
request ID into a message. You open a span once, and the subscriber does the rest.

**Why `TraceLayer` and `#[instrument]` instead of `span.enter()`?** You can create a span by
hand and call `let _guard = span.enter();`. In synchronous code that's fine. In async code it's
a bug if the guard lives across an `.await`: when the future is suspended, the guard is still
"entered" on that thread, and whatever other task the thread polls next appears to be inside
your span. `#[instrument]` on an `async fn` (and `TraceLayer`) instead wrap the future in
`tracing::Instrumented`, which enters the span on **every poll** and exits when the poll
returns. Same idea as Lab 26: an async function is a state machine that's polled many times.

**`time.busy` vs `time.idle`.** Those are the two durations of an async span (you'll see them in
the experiment below). *Busy* is time spent actually running (being polled). *Idle* is time
spent waiting (`Pending`, e.g. waiting for Postgres or for a pool connection). A request that
takes 500 ms with `time.busy=2ms` isn't slow Rust code. It's waiting on something.

**Why log 500s in `IntoResponse` and not in the handler?** Because `IntoResponse` is the single
funnel every handler's error passes through. Notice it runs **outside** the handler's span (the
handler has returned by then) but **inside** the request span. That's why the request span is
where request-wide fields like `request_id` (and, after Your Turn 1, `user_id`) belong.

**Cost.** A disabled `debug!` costs a few nanoseconds: `tracing` checks a cached "is this
callsite enabled?" flag before evaluating any fields. So you can leave `debug!` lines in hot
code and enable them in production for a single module (`RUST_LOG=rust_crm::jobs=debug`) when
you need them.

**Never log:** passwords, tokens (JWTs are bearer credentials: anyone who reads one from a log
can use it for 15 minutes), `SecretString`s, `Authorization` headers, full query strings,
request bodies. Be deliberate about personal data (emails, names). `skip_all` + `fields(...)`
makes "deliberate" the default.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 (layer order)**: in `router`, move `SetRequestIdLayer` from the top of the
> `ServiceBuilder` to just above `PropagateRequestIdLayer`. Predict the `request_id` in the log
> and in the response header, then `curl -i localhost:3000/health`.

You'll get a UUID in the response header but `request_id=-` in the log:

```text
2026-10-05T14:50:12.056132Z  INFO request{method=GET path=/health request_id=-}: tower_http::trace::on_response: finished processing request latency=0 ms status=200
```

The ID is now generated *after* `TraceLayer` has created the span. Put it back.

> 🟡 **EXPERIMENT 2 (span durations)**: in `telemetry::init`, change the pretty layer to
> `fmt::layer().with_span_events(fmt::format::FmtSpan::CLOSE)`. Fetch a deal. Which span closes
> first, and what are `time.busy` and `time.idle`? Stop the DB and try again: which number
> explodes? Revert afterwards (close events are noisy).

> 🟡 **EXPERIMENT 3 (filters)**: predict what each prints, then run it:
> `RUST_LOG=warn cargo run` (then hit `/health`), `RUST_LOG=rust_crm=trace,tower_http=debug cargo run`,
> `RUST_LOG=rust_crm::http=debug cargo run`. Which one shows `started processing request`? Why
> does the first one print nothing at all, not even `listening`?

> 🟡 **EXPERIMENT 4 (`err`)**: `#[instrument]` has an `err` option that logs an `ERROR` event
> whenever the function returns `Err`. Add `err` to `deals::db::get`
> (`#[tracing::instrument(skip(db), err)]`) and request a deal id that doesn't exist. How many
> ERROR lines do you get for a perfectly normal 404? Remove it again, and write down in one
> sentence why `err` belongs only on functions that *handle* errors.

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: put `user_id` on the request span.** Right now only `get_deal` knows the
> user (via its own `fields(user_id = ...)`). Every line inside an authenticated request should
> carry `user_id`, including the `ERROR` line from `ApiError` and the response line.
>
> - In `make_request_span`, declare the field **without a value**:
>   `user_id = tracing::field::Empty`.
> - Fill it in once authentication has succeeded, using `tracing::Span::current().record(...)`.
>   Choose *where* deliberately: think about which code runs exactly once per authenticated
>   request, and what happens if a field is recorded twice.
> - Remove the now-redundant `fields(user_id = ...)` from `get_deal`.
>
> Acceptance:
> - [ ] `GET /deals/1` with a token logs `request{… user_id=1}` on the response line.
> - [ ] A request **without** a token has no `user_id` at all (not `user_id=0`, not `user_id=-`).
> - [ ] `user_id` appears **once** per line, not `user_id=1 user_id=1`.
> - [ ] In JSON format, `user_id` is a **number**, not a string.

> 🔵 **YOUR TURN 2: slow-request warnings.** Replace `DefaultOnResponse` with your own
> `on_response` callback.
>
> - Write `fn log_response(response: &Response<Body>, latency: Duration, span: &Span)` in
>   `src/http/mod.rs` and pass it to `.on_response(...)`.
> - Requests slower than a `const SLOW_REQUEST: Duration` of 500 ms are logged at **WARN** with
>   the message `slow request`; all others at **INFO** with `request completed`.
> - Both log `status` (a number) and `latency_ms` (a number).
>
> Acceptance:
> - [ ] `curl localhost:3000/health` logs `INFO … request completed status=200 latency_ms=0`.
> - [ ] With the database stopped, the 500 from Step 8 logs `WARN … slow request status=500 latency_ms=30003` (or similar).
> - [ ] The default `tower_http::trace::on_response` line is gone.

> 🔵 **YOUR TURN 3: instrument the deals and auth modules, safely.**
>
> - `#[tracing::instrument]` on **every** handler in `src/http/deals.rs` and **every** function
>   in `src/deals/db.rs`. Rule: never log a whole request body or `AppState`. Prefer `skip_all`
>   plus explicit `fields(...)` for ids that help debugging (`company_id`, the target stage,
>   the new owner id…).
> - `create_deal` logs `info!` **"deal created"** with `deal_id`. `reassign_deal` logs
>   **"deal reassigned"** with `deal_id`.
> - `register` and `login` get `#[instrument(skip_all)]`.
> - `login` logs a `warn!` **"login failed"** with a `reason` field: `"unknown_email"` or
>   `"wrong_password"` (with `user_id` in the second case), and an `info!` **"login succeeded"**
>   with `user_id`. The **HTTP response must not change**: still the same 401 and message for
>   both failure cases (Lab 35's timing and enumeration rules still apply).
> - `register` logs **"user registered"** with `user_id`.
>
> Acceptance:
> - [ ] A failed login logs `WARN request{…}:login: rust_crm::http::auth: login failed user_id=1 reason="wrong_password"`.
> - [ ] Run `RUST_LOG=trace cargo run > trace.log 2>&1`, register a new user, log in (once
>       wrong, once right) and create a deal. Then `grep -c` the log for the password, the
>       email and a chunk of the token: all three counts are `0`. (`trace.log` is not committed.)
> - [ ] `cargo test` still passes (Lab 35/36 API tests didn't change).

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: Lab 35's `require_auth` middleware runs once per protected request,
> after the token is verified. Handlers' `AuthUser` extractor may run *again*.

<details><summary>Hint 2 (more specific)</summary>

`Span::current()` inside middleware or an extractor is the request span: `TraceLayer` entered
it before calling the inner service. `record` only works for fields the span **declared**
(that's why `Empty` exists). If you record in the extractor and the middleware *also* extracts,
the pretty formatter shows the field twice. If your `require_auth` takes `_user: AuthUser`,
just drop the underscore.

</details>

<details><summary>Hint 3 (Your Turn 2)</summary>

`on_response` accepts any `Fn(&Response<B>, Duration, &Span)`. The body type is
`axum::body::Body`. The callback runs with the request span entered, so your `warn!`/`info!`
automatically get `request_id` and `user_id`.

</details>

<details><summary>Hint 4 (Your Turn 3)</summary>

Inside `login`, the existing `match user { Some(user) if password_ok => user, _ => return Err(...) }`
has one catch-all arm. Split `_` into `Some(user)` (wrong password) and `None` (unknown email):
the compiler's exhaustiveness check guarantees you covered both. `fields(...)` expressions can
use the function's arguments: `fields(company_id = req.company_id)`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. What's the difference between a span and an event? Give one CRM example of each.
2. Why does an event emitted by `sqlx` carry your `request_id`, even though sqlx has never heard
   of HTTP?
3. Why must `SetRequestIdLayer` be *outside* `TraceLayer`?
4. What exactly did the compiler prevent when `#[instrument]` failed on `login`? Why is
   `skip_all` + `fields` safer than `skip(...)`?
5. Where is a 500 logged, why there, and why only there?
6. What do `time.busy` and `time.idle` tell you about an async span?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit
```bash
git add .
git commit -m "Add structured logging and request tracing"
git tag lab-37
git push && git push --tags
```

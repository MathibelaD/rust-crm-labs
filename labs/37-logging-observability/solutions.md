# Lab 37 — Solutions

> 🔴 **SOLUTION**: read these after a genuine attempt. Your version can differ and still be
> correct if it meets the acceptance criteria. What matters is that you can explain *why*.

---

## Mini-task — `error_chain`

`src/http/error.rs`:

```rust
/// Renders an error and all of its sources: "outer: cause: root cause".
pub(crate) fn error_chain(err: &(dyn std::error::Error + 'static)) -> String {
    let mut chain = err.to_string();
    let mut source = err.source();
    while let Some(cause) = source {
        chain.push_str(": ");
        chain.push_str(&cause.to_string());
        source = cause.source();
    }
    chain
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Context;

    #[test]
    fn error_chain_includes_every_source() {
        let io = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "connection refused");
        let err = Err::<(), _>(io)
            .context("connecting to Postgres")
            .context("loading deal 7")
            .unwrap_err();
        assert_eq!(
            error_chain(err.as_ref()),
            "loading deal 7: connecting to Postgres: connection refused"
        );
    }

    #[test]
    fn error_chain_of_an_error_without_sources_is_its_message() {
        let err = CrmError::NotFound {
            entity: "deal",
            id: 3,
        };
        assert_eq!(error_chain(&err), "no deal with id 3");
    }

    #[test]
    fn error_chain_follows_thiserror_sources() {
        let err = CrmError::Database(sqlx::Error::PoolTimedOut);
        assert_eq!(
            error_chain(&err),
            "database error: pool timed out while waiting for an open connection"
        );
    }
}
```

(Adjust the expected strings to your own `#[error("...")]` messages.)

**Why it's written this way**

- **`&(dyn Error + 'static)`, not a generic `T: Error`.** `Error::source()` returns
  `Option<&(dyn Error + 'static)>`, so after the first step you're dealing with trait objects
  anyway. Taking one from the start means a single loop variable type. The `'static` bound
  means "the error type doesn't borrow anything short-lived" (it's what makes downcasting
  possible). Every error you own (`CrmError`, `sqlx::Error`, `anyhow::Error`'s contents) is
  `'static`.
- **`while let Some(cause) = source`** walks a linked list of borrowed references. Nothing is
  cloned or moved: every `cause` borrows from `err`, and they all live as long as `err` does.
- **Why not just `format!("{err:#}")`?** For `anyhow::Error`, the alternate `Display` (`{:#}`)
  prints exactly this chain, and that's what Lab 28's `eprintln!` printed. But `{:#}` on a plain
  `thiserror` enum prints only the top-level message (thiserror ignores `#`). `error_chain`
  works for **any** error, which Lab 39's worker needs (`sqlx::Error`, `anyhow::Error`).
- **`anyhow` and `.source()`.** `err.as_ref()` gives the `dyn Error` view of an
  `anyhow::Error`. Its `to_string()` is the outermost context, and `.source()` continues through
  each `.context(...)` layer down to the original `io::Error`.

---

## Your Turn 1 — `user_id` on the request span

`src/http/mod.rs`: declare the field when the span is created.

```rust
tracing::info_span!(
    "request",
    method = %request.method(),
    path = %request.uri().path(),
    request_id = %request_id,
    user_id = tracing::field::Empty, // filled in by require_auth
)
```

`src/auth/middleware.rs`: record it once authentication has succeeded.

```rust
pub async fn require_auth(user: AuthUser, request: Request, next: Next) -> Response {
    // Fill in the `user_id` field the request span declared as Empty.
    // Every log line from here on (handler, SQL, errors) carries it.
    tracing::Span::current().record("user_id", user.id.0);
    next.run(request).await
}
```

And `get_deal` goes back to `#[tracing::instrument(skip(state, user))]`.

If your Lab 35 `require_auth` has a different shape (e.g. `State(state)` + `request` and calls
`AuthUser::from_request_parts` itself), the idea is identical: after you have the `AuthUser`,
call `Span::current().record("user_id", user.id.0)`.

**Why it's written this way**

- **Spans have a fixed set of fields, declared up front.** `record` can only *fill in* a
  field that was declared. `tracing::field::Empty` declares "this field exists but has no value
  yet". A field that is never recorded is simply not printed, which is exactly what you want
  for unauthenticated requests (no fake `user_id=0`).
- **Why the middleware and not the `AuthUser` extractor?** Both run during an authenticated
  request: `require_auth` takes an `AuthUser`, and so does every handler. Recording in the
  extractor means recording **twice** per request, and the pretty formatter appends rather
  than replaces: you'd see `user_id=1 user_id=1`. (We hit exactly that while writing this
  lab.) The middleware is the one place that runs once per protected request.
- **`Span::current()` is the request span** because `TraceLayer` entered it before calling the
  inner service, and `route_layer` middleware runs inside that call.
- **`user.id.0`, an `i64`**, not `%user.id`. Numbers stay numbers in JSON (`"user_id":1`), which
  lets a log platform filter `user_id = 1` without string matching.

---

## Your Turn 2 — slow-request warnings

`src/http/mod.rs`:

```rust
use axum::{
    Router,
    body::Body,
    http::{Request, Response},
    middleware,
};
use std::time::Duration;
use tracing::Span;

/// Requests slower than this are logged at WARN.
const SLOW_REQUEST: Duration = Duration::from_millis(500);

// in router():
TraceLayer::new_for_http()
    .make_span_with(make_request_span)
    .on_response(log_response)
    // ApiError already logs every 500 with its cause chain: don't log it twice.
    .on_failure(()),

/// One line per response, inside the request span. Slow responses are a WARN.
fn log_response(response: &Response<Body>, latency: Duration, _span: &Span) {
    let status = response.status().as_u16();
    let latency_ms = latency.as_millis() as u64;
    if latency > SLOW_REQUEST {
        tracing::warn!(status, latency_ms, "slow request");
    } else {
        tracing::info!(status, latency_ms, "request completed");
    }
}
```

`DefaultOnResponse` and `Level` are no longer used: remove them from the imports (clippy and
rustc will tell you).

**Why it's written this way**

- **A plain `fn`** works because tower-http implements its `OnResponse<B>` trait for any
  `Fn(&Response<B>, Duration, &Span)`. Same trick as `make_span_with`. A closure would work
  too, but a named function is easier to read and to test.
- **Fields are numbers.** `status` as `u16` and `latency_ms` as `u64`, not a `"503 ms"` string
  (which is what `DefaultOnResponse` emits). Numbers let you query `latency_ms > 1000`.
- **`as_millis() as u64`**: `as_millis` returns `u128`, which `tracing` can't record as a
  number field. A request would need to run for 584 million years to overflow `u64`
  milliseconds, so this `as` is safe.
- **We didn't call `span.record(...)`**. The callback runs with the span entered, so a normal
  event inherits `request_id` and `user_id`.

Verified output: a 5-second request during Lab 38's shutdown experiment logged
`WARN request{…}: rust_crm::http: slow request status=200 latency_ms=5003`.

---

## Your Turn 3 — instrumenting deals and auth

`src/deals/db.rs`:

```rust
#[tracing::instrument(skip_all, fields(company_id = new.company_id.0, owner_id = new.owner_id.0))]
pub async fn insert(db: impl PgExecutor<'_>, new: &NewDeal) -> Result<Deal, CrmError> { … }

#[tracing::instrument(skip(db))]
pub async fn get(db: impl PgExecutor<'_>, id: DealId) -> Result<Deal, CrmError> { … }

#[tracing::instrument(skip(db))]
pub async fn list(db: impl PgExecutor<'_>, filter: &DealFilter) -> Result<Vec<Deal>, CrmError> { … }

#[tracing::instrument(skip(pool))]
pub async fn move_stage(pool: &PgPool, id: DealId, next: DealStage) -> Result<Deal, CrmError> { … }

#[tracing::instrument(skip(db))]
pub async fn search(db: impl PgExecutor<'_>, term: &str, limit: i64, filter: &DealFilter) -> … { … }

#[tracing::instrument(skip(db))]
pub async fn pipeline(db: impl PgExecutor<'_>) -> Result<Vec<PipelineRow>, CrmError> { … }

#[tracing::instrument(skip(db))]
pub async fn set_owner(db: impl PgExecutor<'_>, id: DealId, owner: UserId) -> … { … }
```

`src/http/deals.rs`:

```rust
#[tracing::instrument(skip_all, fields(company_id = req.company_id))]
async fn create_deal(user: AuthUser, State(state): State<AppState>, AppJson(req): AppJson<CreateDealRequest>)
    -> Result<(StatusCode, Json<DealResponse>), ApiError>
{
    // ...
    let deal = deals::db::insert(&state.pool, &new).await?;
    tracing::info!(deal_id = deal.id.0, "deal created");
    Ok((StatusCode::CREATED, Json(DealResponse::from(&deal))))
}

#[tracing::instrument(skip_all)]
async fn list_deals(…) { … }

#[tracing::instrument(skip(state, user))]
async fn get_deal(…) { … }

#[tracing::instrument(skip(state, user, req), fields(to = %req.stage))]
async fn move_deal(…) { … }

#[tracing::instrument(skip(state, user, req), fields(new_owner = req.owner_id))]
async fn reassign_deal(…) {
    // ...
    let deal = deals::db::set_owner(&state.pool, deal.id, new_owner).await?;
    tracing::info!(deal_id = deal.id.0, "deal reassigned");
    Ok(Json(DealResponse::from(&deal)))
}
```

`src/http/auth.rs`:

```rust
#[tracing::instrument(skip_all)]
async fn register(…) -> … {
    // ...
    let user = users::db::insert(&state.pool, &new_user, &hash).await?;
    tracing::info!(user_id = user.id.0, "user registered");
    Ok((StatusCode::CREATED, Json(UserResponse::from(&user))))
}

#[tracing::instrument(skip_all)]
async fn login(…) -> … {
    // 1. and 2. unchanged (lookup + ALWAYS one Argon2 verification)

    // 3. One error for every failure (to the client). Different reasons in the log.
    let user = match user {
        Some(user) if password_ok => user,
        Some(user) => {
            tracing::warn!(
                user_id = user.id.0,
                reason = "wrong_password",
                "login failed"
            );
            return Err(AuthError::InvalidCredentials.into());
        }
        None => {
            tracing::warn!(reason = "unknown_email", "login failed");
            return Err(AuthError::InvalidCredentials.into());
        }
    };
    tracing::info!(user_id = user.id.0, "login succeeded");
    // token issuing unchanged
}
```

Verified output (failed login, then a deal created):

```text
WARN request{method=POST path=/auth/login request_id=…}:login: rust_crm::http::auth: login failed user_id=1 reason="wrong_password"
INFO request{method=POST path=/deals request_id=… user_id=1}:create_deal{company_id=1}: rust_crm::http::deals: deal created deal_id=1
```

With `RUST_LOG=trace`, a register + two logins + a deal produced 33 log lines and **zero**
occurrences of the password, the email or the token.

**Why it's written this way**

- **`skip_all` where a request body is involved.** `create_deal`'s `req` would be safe today
  (title, company, value), but the moment someone adds a `notes` field with customer details,
  a `skip(state, user)` version starts logging it silently. `skip_all` + `fields(...)` fails
  *closed*.
- **`skip(db)` on repository functions is fine** because their other arguments are ids and
  small enums (`DealId`, `DealStage`, `UserId`, `DealFilter`) that you *want* to see, and
  `Debug` on them can't leak anything.
- **`to = %req.stage`**: `%` uses `Display` (`"proposal"`), which reads better than `Debug`
  (`Proposal`) and matches the API's wire format.
- **The login log distinguishes the cases; the response doesn't.** Lab 35 made unknown-email
  and wrong-password indistinguishable *to clients* (same status, same message, same timing)
  to prevent account enumeration. Logs are for operators: "50 `wrong_password` for user 3 in a
  minute" is a brute-force attack you want to see. Splitting the `_` arm into `Some(user)` and
  `None` lets the compiler check you covered every case.
- **No email in the `unknown_email` event.** Tempting for debugging, but it records whatever
  strangers type into your login form (often typos of real addresses, sometimes passwords
  typed into the wrong field). The request ID is enough to correlate.
- **Not `#[instrument(err)]`.** Every `Err` here is either an expected outcome (404, 401) or is
  logged by `ApiError` already (500).

---

## Experiment answers

**Experiment 2 (span durations).** The innermost span (`get` in `deals::db`) closes first,
then `get_deal`, then `request`: spans close in reverse order of opening, like stack frames.
With a healthy DB you'll see something like
`get{id=DealId(1)}: rust_crm::deals::db: close time.busy=185µs time.idle=473µs` (even a fast
query is mostly *idle*: the future waits on the network round-trip to Postgres). With the DB stopped,
`time.idle` jumps to ~30 s while `time.busy` stays tiny: the future spent the whole time
`Pending`, waiting for a pool connection. That's how you tell "slow code" from "waiting on a
dependency" in production.

**Experiment 3 (filters).**
- `RUST_LOG=warn`: only WARN/ERROR from every crate. `listening` is INFO, so nothing prints
  until something goes wrong. `RUST_LOG` **replaces** `DEFAULT_FILTER`; it doesn't add to it.
- `RUST_LOG=rust_crm=trace,tower_http=debug`: you now see `started processing request` (a
  DEBUG event from `TraceLayer`'s `on_request`) before each response line.
- `RUST_LOG=rust_crm::http=debug`: only events whose target starts with `rust_crm::http`.
  `listening` (target `rust_crm`) disappears; tower-http's events disappear too, but your
  `log_response` events stay, because the callback function lives in `rust_crm::http`.

**Experiment 4 (`err`).** One normal 404 produces
`ERROR request{…}:get_deal{id=999}:get{id=DealId(999)}: rust_crm::deals::db: error=no deal with id 999`
from the instrumented `get`, plus the response line. A not-found deal is a client mistake, not
a server failure, yet it would page someone at 3 a.m. `err` belongs on functions that are the
*last* to see an error (a background job's top-level function, for example), where logging is
the handling.

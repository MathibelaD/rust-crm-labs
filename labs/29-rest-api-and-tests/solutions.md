# Lab 29 — Solutions

> 🔴 Read this only after a genuine attempt. The shapes below repeat Step 4's `leads.rs`
> deliberately. If yours look similar, that consistency is the point.

---

## Your Turn 1 — Contact listing with filters

`ContactSort` needs to come out of a query string, so give it `Deserialize`
(`src/contacts/filter.rs`):

```rust
use serde::Deserialize;

#[derive(Debug, Clone, Copy, Default, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContactSort {
    #[default]
    Id,
    Name,
    Email,
}
```

A domain type deriving `Deserialize` for the API's sake is acceptable here: the variant names
*are* the public vocabulary (`sort=name`). If the API ever needed different names, you'd add a
separate `ContactSortParam` enum in `http/contacts.rs` and a `From` impl.

`src/http/contacts.rs`:

```rust
use super::extract::{AppJson, AppPath, AppQuery};
use super::pagination::{Page, Pagination};
use crate::contacts::{
    Contact, ContactFilter, ContactId, ContactSort, Email, NewContact, parse_phone,
};

#[derive(Debug, Default, Deserialize)]
pub struct ContactQuery {
    pub company_id: Option<u64>,
    pub search: Option<String>,
    #[serde(default)]
    pub sort: ContactSort,
}

impl From<ContactQuery> for ContactFilter {
    fn from(q: ContactQuery) -> Self {
        ContactFilter {
            company: q.company_id.map(CompanyId),
            search: q.search,
            sort: q.sort,
        }
    }
}

pub async fn list_contacts(
    State(state): State<AppState>,
    AppQuery(query): AppQuery<ContactQuery>,
    AppQuery(pagination): AppQuery<Pagination>,
) -> Json<Page<ContactResponse>> {
    let filter = ContactFilter::from(query);
    let crm = state.crm.read().expect("crm lock poisoned");
    let page = Page::paginate(crm.list_contacts(&filter), pagination);
    Json(page.map(ContactResponse::from))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/contacts", get(list_contacts).post(create_contact))
        .route(
            "/contacts/{id}",
            get(get_contact).put(update_contact).delete(delete_contact),
        )
}
```

`#[serde(default)]` on `sort` uses `ContactSort::default()`, i.e. `Id`, the `#[default]`
variant. An unknown value (`sort=age`) fails deserialization, and `AppQuery` turns that into a
400. Sorting happens in `Crm::list_contacts` (Lab 17), and paginating happens **after** sorting,
otherwise page 2 would be "the second 20 by id, sorted by name".

The nested route lives in `companies.rs`, because its URL starts with `/companies/{id}`:

```rust
use super::contacts::ContactResponse;

pub async fn list_company_contacts(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<Vec<ContactResponse>>, ApiError> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let company_id = CompanyId(id);
    if crm.companies.get(company_id).is_none() {
        return Err(CrmError::NotFound { entity: "company", id }.into());
    }
    let contacts = crm.contacts_of(company_id);
    Ok(Json(contacts.into_iter().map(ContactResponse::from).collect()))
}
// in companies::routes():
//     .route("/companies/{id}/contacts", get(list_company_contacts))
```

`.into()` is needed here because there's no `?` doing the conversion for us: we're building the
`Err` ourselves, so we convert `CrmError` → `ApiError` explicitly (same `From` impl).

---

## Your Turn 2 — Deals and the pipeline

`src/http/deals.rs` (imports omitted; they mirror `leads.rs`, plus
`crate::deals::{Deal, DealId, DealStage, PipelineRow}` and `crate::companies::CompanyId`):

```rust
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/deals", get(list_deals).post(create_deal))
        .route("/deals/{id}", get(get_deal))
        .route("/deals/{id}/stage", post(move_deal))
        .route("/pipeline", get(pipeline))
}

#[derive(Debug, Deserialize)]
pub struct CreateDealRequest {
    pub company_id: u64,
    #[serde(default)]
    pub title: String,
    pub value_cents: i64,
}

#[derive(Debug, Deserialize)]
pub struct MoveDealRequest {
    pub stage: DealStage,
}

#[derive(Debug, Default, Deserialize)]
pub struct DealQuery {
    pub stage: Option<DealStage>,
    pub company_id: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct DealResponse {
    pub id: u64,
    pub company_id: u64,
    pub title: String,
    pub value_cents: i64,
    pub stage: DealStage,
}

impl From<&Deal> for DealResponse {
    fn from(d: &Deal) -> Self {
        Self {
            id: d.id.0,
            company_id: d.company_id.0,
            title: d.title.clone(),
            value_cents: d.value.cents(),
            stage: d.stage,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct PipelineRowResponse {
    pub stage: DealStage,
    pub count: usize,
    pub total_cents: i64,
}

impl From<PipelineRow> for PipelineRowResponse {
    fn from(row: PipelineRow) -> Self {
        Self { stage: row.stage, count: row.count, total_cents: row.total.cents() }
    }
}

/// Validated input for `Crm::add_deal`.
struct DealInput {
    company_id: CompanyId,
    title: String,
    value: Money,
}

impl TryFrom<CreateDealRequest> for DealInput {
    type Error = Vec<FieldError>;

    fn try_from(req: CreateDealRequest) -> Result<Self, Self::Error> {
        let title = match req.title.trim() {
            "" => Err(FieldError::new("title", "must not be empty")),
            title => Ok(title.to_string()),
        };
        let value = if req.value_cents < 0 {
            Err(FieldError::new("value_cents", "must not be negative"))
        } else {
            Ok(Money::from_cents(req.value_cents))
        };
        match (title, value) {
            (Ok(title), Ok(value)) => Ok(DealInput {
                company_id: CompanyId(req.company_id),
                title,
                value,
            }),
            (title, value) => Err([title.err(), value.err()].into_iter().flatten().collect()),
        }
    }
}

async fn create_deal(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateDealRequest>,
) -> Result<(StatusCode, Json<DealResponse>), ApiError> {
    let input = DealInput::try_from(req)?;
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let id = crm.add_deal(input.company_id, input.title, input.value)?;
        DealResponse::from(crm.deals.get(id).expect("deal was just inserted"))
    };
    state.persist().await?;
    Ok((StatusCode::CREATED, Json(response)))
}

async fn list_deals(
    State(state): State<AppState>,
    AppQuery(query): AppQuery<DealQuery>,
    AppQuery(pagination): AppQuery<Pagination>,
) -> Json<Page<DealResponse>> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let deals = crm.deals.find_where(|d| {
        query.stage.is_none_or(|stage| d.stage == stage)
            && query.company_id.is_none_or(|id| d.company_id == CompanyId(id))
    });
    Json(Page::paginate(deals, pagination).map(DealResponse::from))
}

async fn get_deal(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
) -> Result<Json<DealResponse>, ApiError> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let deal = crm.deals.get(DealId(id)).ok_or(CrmError::NotFound { entity: "deal", id })?;
    Ok(Json(DealResponse::from(deal)))
}

async fn move_deal(
    State(state): State<AppState>,
    AppPath(id): AppPath<u64>,
    AppJson(req): AppJson<MoveDealRequest>,
) -> Result<Json<DealResponse>, ApiError> {
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        crm.move_deal(DealId(id), req.stage)?;
        DealResponse::from(crm.deals.get(DealId(id)).expect("deal exists after a move"))
    };
    state.persist().await?;
    Ok(Json(response))
}

async fn pipeline(State(state): State<AppState>) -> Json<Vec<PipelineRowResponse>> {
    let crm = state.crm.read().expect("crm lock poisoned");
    let rows = crm.pipeline_report();
    Json(rows.into_iter().map(PipelineRowResponse::from).collect())
}
```

And `.merge(deals::routes())` in `router()`.

Reasoning:

- **Why is `value_cents` validated here and not only in `Money`?** `Money::from_cents` accepts any
  `i64`, since a refund or an adjustment might legitimately be negative *somewhere*. "A deal's
  value can't be negative" is a rule about deals, so it lives at the deal boundary. (If your Lab 18
  `Deal::validate` already rejects negative values, calling it would be equally good. The point is
  that the rule exists exactly once in the request path.)
- **`company_id` without `#[serde(default)]`**: there's no sensible default for "which company",
  so a missing `company_id` is a 400 from serde, not a field error. A nonexistent one is a 404 from
  `Crm::add_deal`.
- **`move_deal` returns the deal after the move.** Clients almost always want to re-render it.
  Returning it saves a round trip and proves which stage is now stored.
- **The closure in `find_where`** borrows `query` (captured by reference; `Fn`). `is_none_or`
  takes its closure by value and calls it at most once, which is fine for `Copy` data like
  `DealStage`.
- **`PipelineRow` is converted by value** (`From<PipelineRow>`, not `From<&PipelineRow>`),
  because `pipeline_report()` returns owned rows we don't need afterwards. Moving is free.

---

## Your Turn 3 — Activities, notes and history

The shared piece goes first. `src/http/history.rs`:

```rust
use crate::history::HistoryItem; // Lab 20's borrowed history entry

pub fn routes() -> Router<AppState> {
    Router::new().route("/history", get(history))
}

/// `?subject=deal:3`, shared by /activities, /notes and /history.
#[derive(Debug, Deserialize)]
pub struct SubjectQuery {
    pub subject: String,
}

impl SubjectQuery {
    pub fn parse(&self) -> Result<Subject, ApiError> {
        self.subject.parse().map_err(|_| {
            ApiError::BadRequest(format!(
                "invalid subject `{}`: expected company:<id>, contact:<id> or deal:<id>",
                self.subject
            ))
        })
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HistoryItemResponse {
    Activity(ActivityResponse),
    Note(NoteResponse),
}

impl From<HistoryItem<'_>> for HistoryItemResponse {
    fn from(item: HistoryItem<'_>) -> Self {
        match item {
            HistoryItem::Activity(a) => HistoryItemResponse::Activity(a.into()),
            HistoryItem::Note(n) => HistoryItemResponse::Note(n.into()),
        }
    }
}

async fn history(
    State(state): State<AppState>,
    AppQuery(query): AppQuery<SubjectQuery>,
) -> Result<Json<Vec<HistoryItemResponse>>, ApiError> {
    let subject = query.parse()?;
    let crm = state.crm.read().expect("crm lock poisoned");
    let items = crm.history(subject);
    Ok(Json(items.into_iter().map(HistoryItemResponse::from).collect()))
}
```

- **`.map_err(|_| ...)` ignores the parse error's type.** Whatever error type your Lab 20
  `FromStr for Subject` uses (`String`, `ValidationError`, …), this compiles. The message we send
  is written for API clients, not copied from the CLI.
- **`self.subject.parse()` with no turbofish**: the return type `Result<Subject, _>` tells
  `parse` which `FromStr` impl to use.
- **`From<HistoryItem<'_>>`**: `HistoryItem<'a>` borrows from the `Crm`, `'_` says "any lifetime",
  and `a.into()` uses `From<&Activity> for ActivityResponse` to copy out owned data. When the
  conversion is done, nothing borrowed remains.
- **History for a subject that doesn't exist** returns `[]`, not 404. `Crm::history` doesn't
  check existence, and arguably "no history" is a true answer. If you prefer a 404, check the
  subject first with `crm.check_subject(subject)?` (Lab 20's existence check, the one
  `log_activity` uses). Either is fine if it's deliberate and tested.

`src/http/activities.rs` (the interesting parts):

```rust
#[derive(Debug, Deserialize)]
pub struct CreateActivityRequest {
    #[serde(default)]
    pub subject: String,
    pub kind: ActivityKind,
    #[serde(default)]
    pub summary: String,
    pub occurred_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct ActivityResponse {
    pub id: u64,
    pub subject: String,
    pub kind: ActivityKind,
    pub summary: String,
    pub occurred_at: DateTime<Utc>,
}

impl From<&Activity> for ActivityResponse {
    fn from(a: &Activity) -> Self {
        Self {
            id: a.id.0,
            subject: a.subject.to_string(),
            kind: a.kind.clone(),
            summary: a.summary.clone(),
            occurred_at: a.occurred_at,
        }
    }
}

struct ActivityInput {
    subject: Subject,
    kind: ActivityKind,
    summary: String,
    occurred_at: DateTime<Utc>,
}

impl ActivityInput {
    fn validate(req: CreateActivityRequest, now: DateTime<Utc>) -> Result<Self, Vec<FieldError>> {
        let subject = req.subject.parse::<Subject>().map_err(|_| {
            FieldError::new("subject", "must look like company:1, contact:2 or deal:3")
        });
        let summary = match req.summary.trim() {
            "" => Err(FieldError::new("summary", "must not be empty")),
            s => Ok(s.to_string()),
        };
        match (subject, summary) {
            (Ok(subject), Ok(summary)) => Ok(ActivityInput {
                subject,
                kind: req.kind,
                summary,
                occurred_at: req.occurred_at.unwrap_or(now),
            }),
            (subject, summary) => Err([subject.err(), summary.err()].into_iter().flatten().collect()),
        }
    }
}

async fn log_activity(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateActivityRequest>,
) -> Result<(StatusCode, Json<ActivityResponse>), ApiError> {
    let input = ActivityInput::validate(req, Utc::now())?;
    let response = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let id = crm.log_activity(input.subject, input.kind, input.summary, input.occurred_at)?;
        ActivityResponse::from(crm.activities.get(id).expect("activity was just inserted"))
    };
    state.persist().await?;
    Ok((StatusCode::CREATED, Json(response)))
}

async fn list_activities(
    State(state): State<AppState>,
    AppQuery(query): AppQuery<SubjectQuery>,
) -> Result<Json<Vec<ActivityResponse>>, ApiError> {
    let subject = query.parse()?;
    let crm = state.crm.read().expect("crm lock poisoned");
    let mut activities = crm.activities.find_where(|a| a.subject == subject);
    activities.sort_by_key(|a| std::cmp::Reverse(a.occurred_at));
    Ok(Json(activities.into_iter().map(ActivityResponse::from).collect()))
}
```

Design notes:

- **`now` is a parameter of `validate`** (Lab 20's testability lesson). The handler passes
  `Utc::now()`, and a unit test could pass a fixed time.
- **`kind: ActivityKind` reuses the domain enum on the wire.** It's already internally tagged
  (`{"type": "call", "minutes": 15}`), which is a fine API shape. The cost is coupling: renaming a
  variant now changes the API *and* the JSON file format. A stricter design would mirror it with an
  `ActivityKindDto`. For this course, reusing it and *knowing* the trade-off is the right call.
- **`Reverse(a.occurred_at)`** sorts newest first without a custom comparator. `Reverse<T>`
  flips `Ord`.
- **`a.subject.to_string()`** renders `deal:1` via Lab 20's `Display`, the same text format the
  client sends. Symmetric input and output.

`src/http/notes.rs` is the same pattern with `{subject, body}`. Validation returns a plain tuple
because there are only two values, and `add_note` gets `Utc::now()` from the handler:

```rust
fn validate(req: CreateNoteRequest) -> Result<(Subject, String), Vec<FieldError>> {
    let subject = req.subject.parse::<Subject>().map_err(|_| {
        FieldError::new("subject", "must look like company:1, contact:2 or deal:3")
    });
    let body = match req.body.trim() {
        "" => Err(FieldError::new("body", "must not be empty")),
        b => Ok(b.to_string()),
    };
    match (subject, body) {
        (Ok(subject), Ok(body)) => Ok((subject, body)),
        (subject, body) => Err([subject.err(), body.err()].into_iter().flatten().collect()),
    }
}
```

`NoteResponse` is `{id, subject: String, body, created_at}`, and `list_notes` sorts by
`Reverse(n.created_at)`. Finally `router()` merges `activities::routes()`, `notes::routes()` and
`history::routes()`.

---

## Your Turn 4 — Tests from behaviour lists

`tests/api/main.rs`:

```rust
mod companies;
mod contacts;
mod deals;
mod helpers;
mod leads;
```

A few representative tests per file. The rest follow the same shape. Compare the *assertions*
with yours: what does each test prove?

```rust
// tests/api/contacts.rs
#[tokio::test]
async fn company_with_contacts_cannot_be_deleted() {
    let app = app();
    let company = create_company(&app, "Acme").await;
    send(
        &app,
        post_json("/contacts", json!({ "name": "Ada", "email": "ada@acme.test", "company_id": company })),
    )
    .await;
    let (status, body) = send(&app, delete(&format!("/companies/{company}"))).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&body), "conflict");
}

#[tokio::test]
async fn update_to_taken_email_is_a_conflict() {
    let app = app();
    send(&app, post_json("/contacts", json!({ "name": "Ada", "email": "ada@x.test" }))).await;
    let (_, bob) = send(&app, post_json("/contacts", json!({ "name": "Bob", "email": "bob@x.test" }))).await;
    let id = bob["id"].as_u64().unwrap();
    let (status, _) = send(
        &app,
        put_json(&format!("/contacts/{id}"), json!({ "name": "Bob", "email": "ada@x.test" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}
```

```rust
// tests/api/leads.rs
#[tokio::test]
async fn unqualified_lead_cannot_be_converted() {
    let app = app();
    let id = create_lead(&app, "Grace", "grace@navy.test").await;   // local helper
    let (status, body) = send(&app, post_json(&format!("/leads/{id}/convert"), json!({}))).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&body), "conflict");

    // The failed conversion handed the lead back: it still exists.
    let (status, _) = send(&app, get(&format!("/leads/{id}"))).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn qualified_lead_converts_with_a_deal() {
    let app = app();
    let id = create_lead(&app, "Grace", "grace@navy.test").await;
    let (status, body) = send(&app, post(&format!("/leads/{id}/qualify"))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "qualified");

    let (status, summary) = send(
        &app,
        post_json(
            &format!("/leads/{id}/convert"),
            json!({ "deal": { "title": "Licences", "value_cents": 1_250_000 } }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let deal_id = summary["deal_id"].as_u64().unwrap();
    let (_, deal) = send(&app, get(&format!("/deals/{deal_id}"))).await;
    assert_eq!(deal["value_cents"], 1_250_000);
    assert_eq!(deal["company_id"], summary["company_id"]);

    let (status, _) = send(&app, get(&format!("/leads/{id}"))).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a converted lead is consumed");
}
```

```rust
// tests/api/deals.rs
async fn move_to(app: &Router, deal: u64, stage: &str) -> (StatusCode, Value) {
    send(app, post_json(&format!("/deals/{deal}/stage"), json!({ "stage": stage }))).await
}

#[tokio::test]
async fn closed_deals_are_final() {
    let app = app();
    let acme = create_company(&app, "Acme").await;
    let id = create_deal(&app, acme, 100).await;            // local helper, asserts 201
    assert_eq!(move_to(&app, id, "won").await.0, StatusCode::OK);
    let (status, body) = move_to(&app, id, "lost").await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error_code(&body), "invalid_transition");
}

#[tokio::test]
async fn pipeline_sums_cents_per_stage() {
    let app = app();
    let acme = create_company(&app, "Acme").await;
    create_deal(&app, acme, 10_000).await;
    let won = create_deal(&app, acme, 5_000).await;
    move_to(&app, won, "won").await;
    create_deal(&app, acme, 2_550).await;

    let (status, rows) = send(&app, get("/pipeline")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(rows.as_array().unwrap().len(), 5);
    assert_eq!(rows[0], json!({ "stage": "qualification", "count": 2, "total_cents": 12_550 }));
    assert_eq!(rows[3], json!({ "stage": "won", "count": 1, "total_cents": 5_000 }));
}
```

What makes these good tests:

- **They test behaviour through the public contract** (status, `code`, JSON fields), not
  internals. You could rewrite every handler and they'd still be valid. In Lab 33 they'll run
  against Postgres nearly unchanged.
- **Each "negative" test checks the state *after* the failure** where it matters (the lead still
  exists, the deal is still `won`). A 409 is only half the contract; "and nothing changed" is the
  other half.
- **Local helpers (`create_lead`, `create_deal`, `move_to`) assert their own success**, so when
  setup breaks the failure points at setup, not at a confusing assertion three lines later.
- **`assert_eq!(rows[0], json!({...}))`** compares whole objects. It's stricter than checking
  fields one by one, and the failure output shows both objects.
- **Integer literals with `_` separators** (`1_250_000`, `12_550`) read as money. Clippy's
  `inconsistent_digit_grouping` will complain about `100_00`-style "cents" grouping. Group by
  thousands.

The reference run of the full suite:

```text
running 28 tests
...
test result: ok. 28 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

(8 company tests + 8 contacts + 5 leads + 7 deals. Your count will differ if you wrote more,
which is good.)

---

## Experiment answers

**Experiment 1 (`nest`).** Both styles work. `nest` reads well when a module is a self-contained
sub-API and its paths never leave its prefix. `leads.rs` qualifies, `companies.rs` doesn't
(`/companies/{id}/contacts`, and Challenge D adds `/companies/{id}/tags/{tag}`). Mixed styles
make grepping for a URL harder, which is why the lab standardises on `merge`.

**Experiment 2 (clamping).** `{"items":[...],"page":1,"per_page":100,"total":N}`. The response
reports the values actually used, so a client can see its request was adjusted. A test:

```rust
#[tokio::test]
async fn out_of_range_pagination_is_clamped() {
    let app = app();
    create_company(&app, "Acme").await;
    let (_, body) = send(&app, get("/companies?page=0&per_page=1000")).await;
    assert_eq!((body["page"].as_u64(), body["per_page"].as_u64()), (Some(1), Some(100)));
}
```

**Experiment 3.** The failure prints `left` and `right` as full `Value`s (`String("Acme")` vs
`"Acme Inc"`), so you can see exactly what came back.

# Lab 31 — Solutions

> 🔴 One good answer per task, with the reasoning. Yours may differ and still be right.

---

## 🔵 Your Turn 1 — notes on Postgres

**Migration** (`sqlx migrate add create_notes`):

```sql
CREATE TABLE notes (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject_type TEXT        NOT NULL CHECK (subject_type IN ('company', 'contact', 'deal')),
    subject_id   BIGINT      NOT NULL,
    body         TEXT        NOT NULL CHECK (btrim(body) <> ''),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Domain input** (`src/notes/model.rs`, exported from `src/notes/mod.rs` with `pub mod db;`):

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct NewNote {
    pub subject: Subject,
    pub body: String,
}
```

**Repository** (`src/notes/db.rs`):

```rust
//! Note persistence.

use chrono::{DateTime, Utc};
use sqlx::{PgExecutor, PgPool};

use super::{NewNote, Note, NoteId};
use crate::database::{corrupt, ensure_subject_exists};
use crate::errors::CrmError;
use crate::subject::Subject;

struct NoteRow {
    id: i64,
    subject_type: String,
    subject_id: i64,
    body: String,
    created_at: DateTime<Utc>,
}

impl TryFrom<NoteRow> for Note {
    type Error = sqlx::Error;

    fn try_from(row: NoteRow) -> Result<Self, Self::Error> {
        Ok(Note {
            id: NoteId(row.id),
            subject: Subject::from_parts(&row.subject_type, row.subject_id).map_err(corrupt)?,
            body: row.body,
            created_at: row.created_at,
        })
    }
}

pub async fn insert(pool: &PgPool, new: &NewNote) -> Result<Note, CrmError> {
    ensure_subject_exists(pool, new.subject).await?;
    let row = sqlx::query_as!(
        NoteRow,
        "INSERT INTO notes (subject_type, subject_id, body)
         VALUES ($1, $2, $3)
         RETURNING id, subject_type, subject_id, body, created_at",
        new.subject.kind(),
        new.subject.id(),
        new.body,
    )
    .fetch_one(pool)
    .await?;
    Ok(row.try_into()?)
}

/// Newest first.
pub async fn list_for_subject(
    db: impl PgExecutor<'_>,
    subject: Subject,
) -> Result<Vec<Note>, CrmError> {
    let rows = sqlx::query_as!(
        NoteRow,
        "SELECT id, subject_type, subject_id, body, created_at
         FROM notes
         WHERE subject_type = $1 AND subject_id = $2
         ORDER BY created_at DESC, id DESC",
        subject.kind(),
        subject.id(),
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Note::try_from)
        .collect::<Result<_, _>>()?)
}
```

**Handlers** (`src/http/notes.rs`):

```rust
async fn list_notes(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<SubjectQuery>,
) -> Result<Json<Vec<NoteResponse>>, ApiError> {
    let subject = q.parse()?;
    let notes = notes::db::list_for_subject(&state.pool, subject).await?;
    Ok(Json(notes.iter().map(NoteResponse::from).collect()))
}

async fn add_note(
    State(state): State<AppState>,
    AppJson(req): AppJson<CreateNoteRequest>,
) -> Result<(StatusCode, Json<NoteResponse>), ApiError> {
    let (subject, body) = validate(req)?; // Lab 28's 422s, unchanged
    let note = notes::db::insert(&state.pool, &NewNote { subject, body }).await?;
    Ok((StatusCode::CREATED, Json(NoteResponse::from(&note))))
}
```

(Imports: `crate::notes::{self, NewNote, Note}`.)

**Reasoning**

- `insert` runs two statements (existence check, then insert), so by the Step 2 rule it takes
  `&PgPool`. `list_for_subject` is one statement and takes `impl PgExecutor<'_>`.
- Lab 20 passed `now` *into* `Crm::add_note` for testability. Now the database stamps
  `created_at`, so the clock moves to Postgres. Tests that need fixed times can insert rows with
  explicit timestamps (Lab 33 fixtures do).
- A blank body: Lab 28's `validate` rejects it with a 422 before the database. Without that, the
  `CHECK` would make it a 500. That's why both layers exist.

---

## 🔵 Your Turn 2 — history from the database

`src/history.rs`:

```rust
//! A subject's history: activities and notes, merged, newest first.

use chrono::{DateTime, Utc};

use crate::activities::Activity;
use crate::notes::Note;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HistoryItem<'a> {
    Activity(&'a Activity),
    Note(&'a Note),
}

impl HistoryItem<'_> {
    pub fn at(&self) -> DateTime<Utc> {
        match self {
            HistoryItem::Activity(a) => a.occurred_at,
            HistoryItem::Note(n) => n.created_at,
        }
    }
}

/// Borrows from both slices: the result can't outlive either of them.
pub fn merge<'a>(activities: &'a [Activity], notes: &'a [Note]) -> Vec<HistoryItem<'a>> {
    let mut items: Vec<HistoryItem<'a>> = activities
        .iter()
        .map(HistoryItem::Activity)
        .chain(notes.iter().map(HistoryItem::Note))
        .collect();
    items.sort_by_key(|item| std::cmp::Reverse(item.at()));
    items
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;
    use crate::activities::{ActivityId, ActivityKind};
    use crate::deals::DealId;
    use crate::notes::NoteId;
    use crate::subject::Subject;

    fn at(hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 1, hour, 0, 0).unwrap()
    }

    #[test]
    fn merges_newest_first() {
        let subject = Subject::Deal(DealId(1));
        let activities = vec![Activity {
            id: ActivityId(1),
            subject,
            kind: ActivityKind::Call { minutes: 5 },
            summary: "call".into(),
            occurred_at: at(10),
        }];
        let notes = vec![
            Note { id: NoteId(1), subject, body: "early".into(), created_at: at(9) },
            Note { id: NoteId(2), subject, body: "late".into(), created_at: at(11) },
        ];
        let merged = merge(&activities, &notes);
        let times: Vec<_> = merged.iter().map(HistoryItem::at).collect();
        assert_eq!(times, vec![at(11), at(10), at(9)]);
    }
}
```

This replaces the whole Lab 20 file: `merge_history`, `impl Crm { fn history }` and their
`Crm`-based tests go. (Lab 20's `Display for HistoryItem` was for the CLI; keep it if you like.)

Handler (`src/http/history.rs`, importing `crate::history::{self, HistoryItem}` and
`crate::{activities, notes}`). Your Lab 29 `HistoryItemResponse` conversion from
`HistoryItem<'_>` stays as it was:

```rust
async fn history(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<SubjectQuery>,
) -> Result<Json<Vec<HistoryItemResponse>>, ApiError> {
    let subject = q.parse()?;
    let activities = activities::db::list_for_subject(&state.pool, subject).await?;
    let notes = notes::db::list_for_subject(&state.pool, subject).await?;
    let items = history::merge(&activities, &notes);
    Ok(Json(items.into_iter().map(Into::into).collect()))
}
```

**The `'a`.** `merge` returns references *into* the two slices, and both inputs have the same
lifetime `'a`, so the output is valid only while **both** are alive. In the handler,
`activities` and `notes` are locals that live until the end of the function. `items` borrows
from them and is consumed (`into_iter().map(Into::into)`) into owned responses *before* the
locals drop. Try `let items = history::merge(&activities::db::list_for_subject(..).await?, &notes);`
(a temporary) and you'll meet Lab 10's E0716, "temporary value dropped while borrowed".

The same function worked on `Crm`'s `InMemoryRepo` vectors in Lab 20 and works on query results
now. It never knew where the data came from.

---

## 🔵 Your Turn 3 — `pipeline_report` as a free function

`src/deals/report.rs` keeps Lab 18's body and `open_total`. Only the input changes, from
`&self` (a `Crm`) to a slice of deals:

```rust
use std::collections::BTreeMap;

use super::{Deal, DealStage};
use crate::money::Money;

/// One line of the pipeline report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PipelineRow {
    pub stage: DealStage,
    pub count: usize,
    pub total: Money,
}

/// Number of deals and their total value per stage, in pipeline order.
/// Every stage appears, even when it has no deals.
pub fn pipeline_report(deals: &[Deal]) -> Vec<PipelineRow> {
    let mut by_stage: BTreeMap<DealStage, (usize, Money)> = DealStage::ALL
        .iter()
        .map(|&stage| (stage, (0, Money::ZERO)))
        .collect();

    for deal in deals {
        let (count, total) = by_stage.entry(deal.stage).or_default();
        *count += 1;
        *total += deal.value;
    }

    by_stage
        .into_iter()
        .map(|(stage, (count, total))| PipelineRow {
            stage,
            count,
            total,
        })
        .collect()
}

/// Number and total value of deals in open (not closed) stages.
pub fn open_total(rows: &[PipelineRow]) -> (usize, Money) {
    let open = rows.iter().filter(|row| !row.stage.is_closed());
    open.fold((0, Money::ZERO), |(count, total), row| {
        (count + row.count, total + row.total)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companies::CompanyId;
    use crate::deals::DealId;

    fn deal(id: i64, stage: DealStage, cents: i64) -> Deal {
        Deal {
            id: DealId(id),
            company_id: CompanyId(1),
            title: format!("Deal {id}"),
            value: Money::from_cents(cents),
            stage,
        }
    }

    /// The same three deals Lab 18's `crm_with_deals()` built through `Crm`.
    fn deals() -> Vec<Deal> {
        vec![
            deal(1, DealStage::Proposal, 1_000),
            deal(2, DealStage::Qualification, 2_500),
            deal(3, DealStage::Won, 400),
        ]
    }

    #[test]
    fn pipeline_report_lists_every_stage_in_order() {
        let stages: Vec<DealStage> = pipeline_report(&deals()).iter().map(|r| r.stage).collect();
        assert_eq!(stages, DealStage::ALL);
    }

    #[test]
    fn every_stage_appears_even_without_deals() {
        let rows = pipeline_report(&[]);
        assert_eq!(rows.len(), DealStage::ALL.len());
        assert!(rows.iter().all(|r| r.count == 0 && r.total == Money::ZERO));
    }

    #[test]
    fn pipeline_report_counts_and_sums_per_stage() {
        let report = pipeline_report(&deals());
        assert_eq!(
            report[0],
            PipelineRow {
                stage: DealStage::Qualification,
                count: 1,
                total: Money::from_cents(2_500)
            }
        );
        assert_eq!(report[1].count, 1);
        assert_eq!(report[2].total, Money::ZERO);
        assert_eq!(report[3].total, Money::from_cents(400));
    }

    #[test]
    fn open_total_ignores_closed_stages() {
        let report = pipeline_report(&deals());
        assert_eq!(open_total(&report), (2, Money::from_cents(3_500)));
    }
}
```

(`DealStage::ALL` is Lab 18's `pub const ALL: [DealStage; 5]` on `DealStage`.) In
`src/deals/mod.rs`: `pub use report::{PipelineRow, open_total, pipeline_report};`. Lab 18's
`deal_for_unknown_company_is_rejected` test called `Crm::add_deal`; it goes, because the
`deals_company_id_fkey` foreign key does that job now.

Handler:

```rust
async fn pipeline(
    State(state): State<AppState>,
) -> Result<Json<Vec<PipelineRowResponse>>, ApiError> {
    let deals = deals::db::list(&state.pool).await?;
    let rows = deals::pipeline_report(&deals);
    Ok(Json(rows.into_iter().map(Into::into).collect()))
}
```

**Reasoning**: taking `&[Deal]` instead of `&Crm` is the smallest honest input. It also makes
the function trivial to test and reusable. Lab 32 moves the aggregation into SQL, and Lab 33 uses
this function as the *reference* the SQL version must agree with. Pure functions make good oracles.

---

## 🧪 Experiment answers

**1.** See the README. The gap in ids comes from `GENERATED ... AS IDENTITY` drawing from a
sequence, and `nextval` is never rolled back.

**2.** The response is a cheerful `201` with three ids, and the database has none of those rows
(the lead is still `qualified`). Dropping an uncommitted `Transaction` rolls back, which is
exactly what makes error paths safe, and also what makes a forgotten `commit` silent. The
compiler can't know you *meant* to commit, so only a test that reads the data back catches it.
Lab 33's `conversion_creates_everything_and_marks_the_lead` is that test.

**3.** Covered in the README. The important observation is that session B reads the
**committed** value after the wait, not a stale one.

**4.** `409 {"error":{"code":"conflict","message":"deal #1 was changed by someone else; reload and try again"}}`
(or `invalid_transition` if your manual change made the move illegal *and* your timing was
different). The `UPDATE ... WHERE stage = $2` matched zero rows because the stage was no longer
the one you read.

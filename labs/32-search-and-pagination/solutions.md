# Lab 32 — Solutions

> 🔴 One good answer per task, with the reasoning.

---

## Mini-task — `contacts::db::search` and `deals::db::search`

```rust
// src/contacts/db.rs
pub async fn search(
    db: impl PgExecutor<'_>,
    term: &str,
    limit: i64,
) -> Result<Vec<Contact>, CrmError> {
    let rows = sqlx::query_as!(
        ContactRow,
        "SELECT id, name, email, phone, company_id
         FROM contacts
         WHERE name ILIKE '%' || $1 || '%' OR email ILIKE '%' || $1 || '%'
         ORDER BY greatest(similarity(name, $1), similarity(email, $1)) DESC, id
         LIMIT $2",
        term,
        limit,
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Contact::try_from)
        .collect::<Result<_, _>>()?)
}

// src/deals/db.rs
pub async fn search(
    db: impl PgExecutor<'_>,
    term: &str,
    limit: i64,
) -> Result<Vec<Deal>, CrmError> {
    let rows = sqlx::query_as!(
        DealRow,
        "SELECT id, company_id, title, value_cents, stage
         FROM deals
         WHERE title ILIKE '%' || $1 || '%'
         ORDER BY similarity(title, $1) DESC, id
         LIMIT $2",
        term,
        limit,
    )
    .fetch_all(db)
    .await?;
    Ok(rows
        .into_iter()
        .map(Deal::try_from)
        .collect::<Result<_, _>>()?)
}
```

`$1` appears several times but is bound **once**: a numbered placeholder can be reused in the SQL.
(That's different from `QueryBuilder`, where every `push_bind` makes a new number.) The trailing
`id` in `ORDER BY` makes the order deterministic when scores tie.

---

## 🔵 Your Turn 1 — `contacts::db::list` with `QueryBuilder`

Add `#[derive(sqlx::FromRow)]` to `ContactRow` and `use sqlx::{PgExecutor, PgPool, Postgres, QueryBuilder};`.

```rust
fn push_filters(query: &mut QueryBuilder<Postgres>, filter: &ContactFilter) {
    let mut keyword = " WHERE ";
    if let Some(company) = filter.company {
        query.push(keyword).push("company_id = ").push_bind(company);
        keyword = " AND ";
    }
    if let Some(search) = &filter.search {
        let pattern = format!("%{search}%");
        query.push(keyword).push("(name ILIKE ").push_bind(pattern.clone());
        query.push(" OR email ILIKE ").push_bind(pattern).push(")");
    }
}

/// Column names can't be bind parameters, so they come from a closed set.
fn order_by(sort: ContactSort) -> &'static str {
    match sort {
        ContactSort::Id => " ORDER BY id",
        ContactSort::Name => " ORDER BY name, id",
        ContactSort::Email => " ORDER BY email, id",
    }
}

pub async fn list(
    pool: &PgPool,
    filter: &ContactFilter,
    limit: i64,
    offset: i64,
) -> Result<(Vec<Contact>, i64), CrmError> {
    let mut query = QueryBuilder::new("SELECT id, name, email, phone, company_id FROM contacts");
    push_filters(&mut query, filter);
    query.push(order_by(filter.sort));
    query.push(" LIMIT ").push_bind(limit).push(" OFFSET ").push_bind(offset);
    let rows: Vec<ContactRow> = query.build_query_as().fetch_all(pool).await?;

    let mut count = QueryBuilder::new("SELECT COUNT(*) FROM contacts");
    push_filters(&mut count, filter);
    let total: i64 = count.build_query_scalar().fetch_one(pool).await?;

    let contacts = rows
        .into_iter()
        .map(Contact::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok((contacts, total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_is_bound_twice_and_sort_is_whitelisted() {
        let filter = ContactFilter {
            company: Some(CompanyId(3)),
            search: Some("ada".into()),
            sort: ContactSort::Email,
        };
        let mut query = QueryBuilder::new("SELECT id FROM contacts");
        push_filters(&mut query, &filter);
        query.push(order_by(filter.sort));
        assert_eq!(
            query.sql().as_str(),
            "SELECT id FROM contacts WHERE company_id = $1 AND (name ILIKE $2 OR email ILIKE $3) ORDER BY email, id"
        );
    }
}
```

**Reasoning**

- **`push_bind(company)`** with a `CompanyId`: `#[derive(sqlx::Type)] #[sqlx(transparent)]`
  (Lab 30) implements `Encode` + `Type` as an `i64`. That's the first time the derive pays for
  itself.
- **The parentheses.** Without them, `company_id = $1 AND name ILIKE $2 OR email ILIKE $3` parses
  as `(company AND name) OR email`, and an email match at *any* company slips through the company
  filter. The unit test pins the exact SQL so this can't regress.
- **`order_by` returns `&'static str`**. The only strings that reach `push` here are literals in
  your source code. Even if `ContactSort` were parsed from a query string, the user picks
  *which* literal, never its text. That's what "whitelist" means.
- **`, id` in every `ORDER BY`**: names and emails can tie (emails can't, but the rule costs
  nothing). Without a unique last key, `OFFSET` pagination can show a row on two pages.
- `pattern.clone()`: the first `push_bind` takes ownership of the `String`, so the second needs
  its own copy (Lab 06). Binding `&pattern` twice also works, since `&str` is `Encode` too.

---

## 🔵 Your Turn 2 — keyset pagination for `/history`

`src/history.rs` (replaces Lab 31's `HistoryItem`/`merge`; see the end of this section):

```rust
//! A subject's history: activities and notes, newest first, merged by Postgres.

use chrono::{DateTime, Utc};
use sqlx::PgExecutor;

use crate::errors::CrmError;
use crate::subject::Subject;

/// One line of history. `item_type` is "activity" or "note".
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryEntry {
    pub item_type: String,
    pub id: i64,
    pub at: DateTime<Utc>,
    pub text: String,
}

/// Position in the merged stream. Ids are only unique *per table*, so the
/// type is part of the key: (at, item_type, id) is unique.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPosition {
    pub at: DateTime<Utc>,
    pub item_type: String,
    pub id: i64,
}

pub async fn page(
    db: impl PgExecutor<'_>,
    subject: Subject,
    before: Option<&HistoryPosition>,
    limit: i64,
) -> Result<Vec<HistoryEntry>, CrmError> {
    let at = before.map(|p| p.at);
    let item_type = before.map(|p| p.item_type.as_str());
    let id = before.map(|p| p.id);
    let entries = sqlx::query_as!(
        HistoryEntry,
        r#"SELECT item_type AS "item_type!", id AS "id!", at AS "at!", text AS "text!"
           FROM (
               SELECT 'activity' AS item_type, id, occurred_at AS at, summary AS text
               FROM activities WHERE subject_type = $1 AND subject_id = $2
               UNION ALL
               SELECT 'note', id, created_at, body
               FROM notes WHERE subject_type = $1 AND subject_id = $2
           ) AS history
           WHERE $3::timestamptz IS NULL OR (at, item_type, id) < ($3, $4, $5)
           ORDER BY at DESC, item_type DESC, id DESC
           LIMIT $6"#,
        subject.kind(),
        subject.id(),
        at,
        item_type,
        id,
        limit,
    )
    .fetch_all(db)
    .await?;
    Ok(entries)
}
```

In `src/http/pagination.rs`:

```rust
/// Opaque token for `HistoryPosition`: base64 of "at|item_type|id".
pub fn encode_history_cursor(p: &HistoryPosition) -> String {
    let raw = format!(
        "{}|{}|{}",
        p.at.to_rfc3339_opts(SecondsFormat::Micros, true),
        p.item_type,
        p.id
    );
    URL_SAFE_NO_PAD.encode(raw)
}

pub fn decode_history_cursor(token: &str) -> Option<HistoryPosition> {
    let raw = String::from_utf8(URL_SAFE_NO_PAD.decode(token).ok()?).ok()?;
    let mut parts = raw.split('|');
    let (at, item_type, id) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || !matches!(item_type, "activity" | "note") {
        return None;
    }
    Some(HistoryPosition {
        at: DateTime::parse_from_rfc3339(at).ok()?.with_timezone(&Utc),
        item_type: item_type.to_string(),
        id: id.parse().ok()?,
    })
}
```

The handler (`src/http/history.rs`). Lab 29's `HistoryItemResponse` enum wrapped a whole
`ActivityResponse` / `NoteResponse`, which a `HistoryEntry` can't fill, so it becomes a struct
with the four fields, keeping the `"type"` key:

```rust
#[derive(Debug, Serialize)]
pub struct HistoryItemResponse {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: i64,
    pub at: DateTime<Utc>,
    pub text: String,
}

impl From<HistoryEntry> for HistoryItemResponse {
    fn from(e: HistoryEntry) -> Self {
        Self {
            item_type: e.item_type,
            id: e.id,
            at: e.at,
            text: e.text,
        }
    }
}

async fn history(
    State(state): State<AppState>,
    AppQuery(q): AppQuery<SubjectQuery>,
    AppQuery(page): AppQuery<CursorQuery>,
) -> Result<Json<CursorPage<HistoryItemResponse>>, ApiError> {
    let subject = q.parse()?;
    let before = match &page.cursor {
        None => None,
        Some(token) => Some(decode_history_cursor(token).ok_or_else(|| {
            ApiError::Validation(vec![FieldError {
                field: "cursor",
                message: "invalid cursor".into(),
            }])
        })?),
    };
    let limit = page.limit();

    let mut entries = history::page(&state.pool, subject, before.as_ref(), limit + 1).await?;
    let next_cursor = if entries.len() as i64 > limit {
        entries.truncate(limit as usize);
        entries.last().map(|e| {
            encode_history_cursor(&HistoryPosition {
                at: e.at,
                item_type: e.item_type.clone(),
                id: e.id,
            })
        })
    } else {
        None
    };
    Ok(Json(CursorPage {
        items: entries.into_iter().map(Into::into).collect(),
        next_cursor,
    }))
}
```

**The tie proof** (verified while writing this lab): a note and an activity with the *same*
microsecond timestamp, paged with `limit=2`:

```text
{"items":[{"type":"note","id":3,...},{"type":"note","id":2,...}],"next_cursor":"..."}
{"items":[{"type":"note","id":1,"at":"2026-10-05T14:43:09.046606Z",...},{"type":"activity","id":100002,"at":"2026-10-05T14:43:09.046606Z",...}],"next_cursor":"..."}
{"items":[{"type":"activity","id":1,...}],"next_cursor":null}
```

**Reasoning**

- **Why the type is in the key.** `ORDER BY at DESC, id DESC` alone could put activity #5 and
  note #5 with equal timestamps in either order, and a cursor `(at, 5)` would skip one of them.
  `'note' > 'activity'` alphabetically, so `item_type DESC` gives a fixed order. Any unique,
  stable tiebreaker works.
- **`UNION ALL`, not `UNION`**: `UNION` removes duplicate rows, which needs a sort or hash over
  everything. We know there are no duplicates.
- **The `!` overrides.** Postgres can't report nullability through a `UNION`'s output, so the
  macro would make every field an `Option`. All four are `NOT NULL` in both tables, so `!` is honest.
- **`$3::timestamptz IS NULL OR ...`** (one query with optional parameters) rather than two
  queries as in `/activities`: per-subject history is small, and the planner still pushes the
  subject filter into both halves of the `UNION ALL`, where the Step 3 indexes serve them.
  `/activities` gets the two-query treatment because it's the one with 5,000-row subjects.
- **Imports.** `history.rs` (HTTP) now needs `chrono::{DateTime, Utc}`, `FieldError`,
  `super::pagination::{CursorPage, CursorQuery, decode_history_cursor, encode_history_cursor}` and
  `crate::history::{self, HistoryEntry, HistoryPosition}`, and no longer uses `ActivityResponse`,
  `NoteResponse` or `crate::{activities, notes}`. `pagination.rs` imports
  `crate::history::HistoryPosition`.
- **What about `merge`?** Postgres now does the merge (a "Merge Append" of two sorted index scans
  is literally your `merge` algorithm). Keeping an unused function "in case" is a liability:
  delete `HistoryItem` and `merge`, and say so in the commit message. Their unit test goes with
  them. The behaviour is now covered by the tie proof above, and by a DB test you can add in Lab 33.
  (Keeping `merge` and paginating each table separately with a two-part cursor is also correct.
  It's just more code.)

---

## 🔵 Your Turn 3 — `open_deal_count` without fan-out

```rust
/// A company plus aggregate numbers about it.
#[derive(Debug, Clone, PartialEq)]
pub struct CompanyOverview {
    pub company: Company,
    pub contact_count: i64,
    pub open_deal_count: i64,
}

struct OverviewRow {
    id: i64,
    name: String,
    website: Option<String>,
    lifecycle: String,
    contact_count: i64,
    open_deal_count: i64,
}

/// One query for the whole page, however many companies it has.
///
/// Not `LEFT JOIN contacts LEFT JOIN deals ... GROUP BY`: joining two
/// one-to-many tables multiplies rows (10 contacts x 3 deals = 30 rows per
/// company), so both counts would come out as 30. Each scalar subquery counts
/// one table, using contacts_company_id_idx / deals_company_id_idx.
pub async fn overview(
    db: impl PgExecutor<'_>,
    limit: i64,
    offset: i64,
) -> Result<Vec<CompanyOverview>, CrmError> {
    let rows = sqlx::query_as!(
        OverviewRow,
        r#"SELECT c.id, c.name, c.website, c.lifecycle,
                  (SELECT COUNT(*) FROM contacts ct WHERE ct.company_id = c.id) AS "contact_count!",
                  (SELECT COUNT(*) FROM deals d
                    WHERE d.company_id = c.id AND d.stage NOT IN ('won', 'lost')) AS "open_deal_count!"
           FROM companies c
           ORDER BY c.id
           LIMIT $1 OFFSET $2"#,
        limit,
        offset,
    )
    .fetch_all(db)
    .await?;
    rows.into_iter()
        .map(|row| {
            let company = Company::try_from(CompanyRow {
                id: row.id,
                name: row.name,
                website: row.website,
                lifecycle: row.lifecycle,
            })?;
            Ok(CompanyOverview {
                company,
                contact_count: row.contact_count,
                open_deal_count: row.open_deal_count,
            })
        })
        .collect()
}
```

Add `pub open_deal_count: i64` to `CompanyOverviewResponse` and copy it across in the handler.

**The fan-out, measured** on seeded company 80 (10 contacts, 3 deals in `proposal`):

```text
-- LEFT JOIN contacts LEFT JOIN deals ... GROUP BY c.id
 id | contact_count | open_deal_count
 80 |            30 |              30
-- scalar subqueries
 id | contact_count | open_deal_count
 80 |            10 |               3
```

`COUNT(DISTINCT ct.id)` and `COUNT(DISTINCT d.id) FILTER (WHERE ...)` would also give 10 and 3,
but only after building the 30-row product and de-duplicating it. Scalar subqueries do two small
index lookups per company on the page. Note `COUNT(*)` is right *inside* a subquery: no row means
0, with no NULL-padded row to worry about.

---

## 🔵 Optional — full-text search on notes

Migration:

```sql
CREATE INDEX notes_body_fts_idx ON notes USING gin (to_tsvector('english', body));
```

Query (the expression must match the index's expression *exactly* for the index to be used):

```sql
SELECT id, subject_type, subject_id, body, created_at
FROM notes
WHERE to_tsvector('english', body) @@ websearch_to_tsquery('english', $1)
ORDER BY ts_rank(to_tsvector('english', body), websearch_to_tsquery('english', $1)) DESC, id DESC
LIMIT $2
```

`to_tsvector('english', ...)` *stems* words: "meetings", "meeting" and "meet" all become `meet`.
A search for `meetings` finds a note that says "meeting", which `ILIKE '%meetings%'` doesn't.
`websearch_to_tsquery` accepts Google-like input (`"exact phrase" -excluded or`) without raising
syntax errors. The trade-off: FTS works on words, so a substring like `ovel` (from "Lovelace")
finds nothing. Use trigrams for names and emails, full text for prose.

---

## 🧪 Experiment answers

**1.** `100%` becomes the pattern `%100%%`, and the trailing `%` is a wildcard, so it matches
anything containing "100". Escape before wrapping:
`term.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")` (backslash is `ILIKE`'s
default escape character). Tests: `50%` doesn't match `500`, `a_b` doesn't match `axb`, and a
literal backslash still matches.

**2.** Keyset: no duplicates. New rows are *newer* than your cursor and don't affect "older than
X". Offset: inserting a row that sorts before your position shifts everything by one, so the
first item of the next page is the last item of the previous one.

**3.** Mostly in the subquery/join work per company and in transferring rows. `per_page` is
capped at 100 by `Pagination::normalized()` for exactly this reason. An unbounded page size is
an easy way for one client to hurt everyone.

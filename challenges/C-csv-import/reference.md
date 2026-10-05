# Challenge C — Reference Design

> Read this **after** you've built your own. It's *one* reasonable design, not *the* answer.
> Compare decisions, not line counts. All snippets were compiled and tested against the Lab 24
> end state, with csv 1.4.

---

## Overview

```text
src/import.rs              (pub mod import; in lib.rs)
  struct ContactRow              private, #[derive(Deserialize)], one CSV row
  enum ImportError               pub, file-level: Open, Header, MissingColumn
  enum RowProblem                pub, row-level:  Malformed(csv::Error), Rejected(CrmError)
  struct RowError { line, problem }
  struct ImportReport { imported, created_companies, skipped } + summary()
  impl Crm { pub fn import_contacts<R: Read>(&mut self, R) -> Result<ImportReport, ImportError>
             fn import_row(&mut self, ContactRow, &mut Vec<CompanyId>) -> Result<ContactId, RowProblem> }
  pub fn import_contacts_file(&mut Crm, &Path) -> Result<ImportReport, ImportError>

src/cli/parser.rs          Command::Import { path: &'a str }, is_mutating → true
src/cli/commands.rs        call import_contacts_file, print summary + skipped lines
src/cli/error.rs           CliError::Import(#[source] ImportError)

tests/import.rs            9 integration tests (string input + one real temp file)
```

---

## 1. Two levels of failure, two error types

The central design decision is that there are **two different kinds of failure**, and they get
different types:

| | File-level: `ImportError` | Row-level: `RowProblem` |
|---|---|---|
| Example | file missing, no `email` column | invalid email in line 5 |
| Effect | nothing imported, nothing changed | that row skipped, import continues |
| Where it appears | the `Err` of the function | **inside** the `Ok(ImportReport)` |

```rust
/// The whole file could not be imported. Nothing was changed.
#[derive(Debug, Error)]
pub enum ImportError {
    #[error("could not open {}", path.display())]
    Open {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("could not read the CSV header")]
    Header(#[source] csv::Error),
    #[error("missing required column '{0}'")]
    MissingColumn(&'static str),
}

/// Why one row was skipped.
#[derive(Debug, Error)]
pub enum RowProblem {
    #[error("malformed row")]
    Malformed(#[source] csv::Error),
    #[error(transparent)]
    Rejected(#[from] CrmError),
}

impl From<ValidationError> for RowProblem {
    fn from(e: ValidationError) -> Self {
        RowProblem::Rejected(e.into())
    }
}
```

**Why `Result<ImportReport, ImportError>` and not `Vec<Result<ContactId, RowError>>`?** The
signature tells the caller the truth: an import either *happened* (possibly with skipped rows) or
*didn't happen at all*. A partially failed import is still a successful *operation*.

**Why keep `RowProblem` as an error value instead of a `String`?** Tests can `matches!` on it
(`RowProblem::Rejected(CrmError::DuplicateEmail(_))`), and a future HTTP endpoint (Lab 29) could
turn each one into a JSON object with a code. Formatting is the CLI's job, done at the last moment
with `error_chain`.

**`Rejected` is transparent**, because "a contact with email … already exists" needs no prefix.
**`Malformed` is not**, because "CSV error: record 1 (line: 2, …)" alone doesn't say the row was
skipped. Its message is just `"malformed row"`, and the csv error is the **source**, never both
(Lab 22's rule; my first draft got this wrong and printed the csv message twice).

---

## 2. Reading: headers once, then records

```rust
impl Crm {
    pub fn import_contacts<R: io::Read>(&mut self, input: R) -> Result<ImportReport, ImportError> {
        let mut reader = csv::ReaderBuilder::new()
            .trim(csv::Trim::All)
            .from_reader(input);

        let headers = reader.headers().map_err(ImportError::Header)?.clone();
        for required in ["name", "email"] {
            if !headers.iter().any(|h| h == required) {
                return Err(ImportError::MissingColumn(required));
            }
        }

        let mut report = ImportReport::default();
        for result in reader.records() {
            let (line, outcome) = match result {
                Err(e) => {
                    let line = e.position().map_or(0, |p| p.line());
                    (line, Err(RowProblem::Malformed(e)))
                }
                Ok(record) => {
                    let line = record.position().map_or(0, |p| p.line());
                    let outcome = record
                        .deserialize::<ContactRow>(Some(&headers))
                        .map_err(RowProblem::Malformed)
                        .and_then(|row| self.import_row(row, &mut report.created_companies));
                    (line, outcome)
                }
            };
            match outcome {
                Ok(id) => report.imported.push(id),
                Err(problem) => report.skipped.push(RowError { line, problem }),
            }
        }
        Ok(report)
    }
}
```

Decisions:

- **`R: io::Read`, generic.** It's called with a `File` from the CLI and a `&[u8]` from tests.
  Generic (static dispatch) rather than `&mut dyn Read`, because there's no runtime choice to make
  here. Lab 23's table: compile-time choice → generics.
- **Required columns are checked up front.** Without that, a file missing `email` would "succeed"
  with every row skipped. That's technically per-row correct, but it hides a file-level mistake
  behind 200 identical messages.
- **`.clone()` on the headers** ends the borrow of `reader`, which `records()` needs mutably. It's
  one small record, cloned once.
- **`records()` + `record.deserialize(Some(&headers))`** instead of `reader.deserialize()`: we get
  the record's **position** (line number) whether or not deserialization succeeds.
- **`.and_then(|row| self.import_row(...))`**: deserialization and import form one chain of
  `Result`s, with `RowProblem` as the common error type. The closure borrows `self` mutably, and
  the borrow ends with the closure call.
- **`map_or(0, ...)`**: positions are `Option`. No `unwrap`, so no input can panic this code.
  (A malformed binary file produces a `Header` error or `Malformed` rows. It was tried.)
- **`trim(csv::Trim::All)`** handles `" Ada "` and `"ada@x.test "` once, at the reader, instead
  of in every field.

The row struct:

```rust
/// One data row, exactly as it appears in the file (after trimming).
#[derive(Debug, Deserialize)]
struct ContactRow {
    name: String,
    email: String,
    phone: Option<String>,
    company: Option<String>,
}
```

It's **private** and holds raw `String`s, not an `Email`. Validation happens in `import_row` so the
error can be a domain error (`InvalidEmail`) with a clean message, rather than a serde error
wrapped in a csv error.

---

## 3. One row: check, change, compensate

```rust
/// Imports one row. Either the whole row succeeds, or nothing changes.
fn import_row(
    &mut self,
    row: ContactRow,
    created: &mut Vec<CompanyId>,
) -> Result<ContactId, RowProblem> {
    // 1. Everything that can be checked without changing anything.
    let email = Email::parse(&row.email)?;
    if row.name.is_empty() {
        return Err(ValidationError::EmptyName.into());
    }
    if self.contacts.email_exists(&email) {
        return Err(CrmError::DuplicateEmail(email.to_string()).into());
    }

    // 2. Find or create the company (remember whether *this row* created it).
    let mut new_company = None;
    let company_id = match non_blank(row.company) {
        None => None,
        Some(name) => {
            // Copy the id out, so the shared borrow of self.companies ends here.
            let existing = self.companies.iter().find(|c| c.name == name).map(|c| c.id);
            match existing {
                Some(id) => Some(id),
                None => {
                    let id = self.add_company(name, None)?;
                    new_company = Some(id);
                    Some(id)
                }
            }
        }
    };

    // 3. The contact. If it fails, undo the company this row created.
    match self.add_contact(row.name, email, non_blank(row.phone), company_id) {
        Ok(id) => {
            created.extend(new_company);
            Ok(id)
        }
        Err(e) => {
            if let Some(id) = new_company {
                self.remove_company(id)?;
            }
            Err(e.into())
        }
    }
}
```

Reasoning:

- **Duplicates within the file come for free.** Each successful row is added to the CRM
  immediately, so `email_exists` sees it when line 9 arrives. No separate `HashSet` of seen emails,
  and no second definition of "duplicate".
- **`add_contact` stays the single source of the rules** (phone format, company exists,
  duplicates). The early checks in step 1 aren't a second copy of the rules: they *order* the work
  so that most rejections happen before anything changes. The duplicate check is repeated inside
  `add_contact`, which is harmless.
- **Compensation** handles the rest: if `add_contact` rejects the row after we created a company,
  we remove it again. `remove_company` can't fail with `HasContacts` here (the company is brand new
  and the contact wasn't added), but `?` keeps it honest instead of `unwrap()`. The cost: the
  company's id was consumed, so ids may have gaps. That's fine, because ids are identifiers, not
  counters. In Lab 31 a database **transaction** gives you this all-or-nothing behaviour without
  hand-written undo code (and Postgres sequences have gaps too).
- **The E0502 you probably met**: `match self.companies.iter().find(...) { None => self.add_company(...) }`
  keeps the shared borrow alive across the `match`. `.map(|c| c.id)` copies the `Copy` id out,
  so the borrow ends before the mutation. That's Lab 08's find-then-mutate, verbatim.
- **`created.extend(new_company)`**: an `Option` is an iterator of zero or one items, so this
  pushes only if a company was created.

`non_blank` is a two-liner: `value.filter(|v| !v.is_empty())`.

---

## 4. The CLI is three small changes

```rust
// parser.rs, inside parse_command's match
"import" => match args {
    [path] => Command::Import { path },
    _ => return Err(CliError::Usage("import <path.csv>")),
},
```

Slice patterns (`[path]`) match "exactly one argument" in one arm. Lab 09's slices meet Lab 11's
patterns.

```rust
// commands.rs, inside execute
Command::Import { path } => {
    let report = import::import_contacts_file(crm, Path::new(path))
        .map_err(CliError::Import)?;
    println!("{}", report.summary());
    for skipped in &report.skipped {
        println!("  line {}: {}", skipped.line, error_chain(&skipped.problem));
    }
}
```

```rust
// cli/error.rs
#[error("import failed")]
Import(#[source] crate::import::ImportError),
```

`is_mutating` returns `true` for `Command::Import { .. }`, and because Lab 21's `is_mutating`
has no catch-all arm, the compiler **forced** this decision the moment the variant was added.

One subtlety: an import that imports 0 rows still triggers a save. That's harmless (the
snapshot is identical). If you care, return `Outcome::Unchanged` from `execute` instead. Lab 21's
solution discusses that alternative.

---

## 5. Tests

`tests/import.rs`, all through the public API:

| Test | Checks |
|---|---|
| `sample_file_imports_eight_and_skips_two` | real file in a tempdir; summary; skipped lines `[5, 9]`; 8 contacts, 6 companies |
| `quoted_fields_keep_their_commas` | `Apollo, MIT` and `Hamilton, Margaret` |
| `existing_company_is_reused_by_exact_name` | uses `sample_crm()`; no company created; Acme gains a contact |
| `a_skipped_row_creates_no_company` | new company + invalid phone → `crm.companies` empty |
| `malformed_row_is_reported_and_import_continues` | `Only,two` → line 2, `RowProblem::Malformed(_)`, next row imported |
| `duplicate_of_an_existing_contact_is_skipped` | `ADA@acme.test` vs `sample_crm()` → `Rejected(CrmError::DuplicateEmail(_))` |
| `columns_can_come_in_any_order_and_extras_are_ignored` | header `email,notes,name` |
| `missing_email_column_rejects_the_whole_file` | `Err(ImportError::MissingColumn("email"))`, nothing changed |
| `missing_file_is_an_open_error` | `Err(ImportError::Open { .. })` |

The sample file lives in the test as a constant:

```rust
const SAMPLE: &str = "\
name,email,phone,company
Ada Lovelace,ada@analytical.test,555-0100,Analytical Engines
...
\"Hamilton, Margaret\",margaret@apollo.test,,\"Apollo, MIT\"
...
";
```

Eight of the nine tests pass a string (`SAMPLE.as_bytes()`) straight to `import_contacts`, with no
disk. Only the file-path entry point needs `tempfile`. That's the payoff of taking `R: Read`.

---

## Alternatives considered

- **Validate everything first, then apply** (two passes). This makes "a skipped row changes
  nothing" true by construction, and it's the natural base for `--dry-run`. But checking "is this
  email a duplicate?" in pass 1 must also account for rows *earlier in the file*, so you'd rebuild
  some of `Crm`'s rules in a side structure. Compensation was simpler here.
- **Dry run by cloning the CRM** (`let mut copy = crm.clone(); copy.import_contacts(...)`). It's
  clean and obviously side-effect free, but it needs `Clone` on `Crm` and every model, and copies
  everything. A reasonable choice for a stretch goal. Think about the cost if the CRM were large.
- **A `HashMap<String, CompanyId>` cache of company names** for the duration of the import. Faster
  for 100k rows (no linear scan per row). Not worth the extra state at this size, and the linear
  `find` also sees companies created by earlier rows without any bookkeeping.
- **Case-insensitive company matching.** Deliberately not done: the spec says *exact*. "ACME" vs
  "Acme" is a data-quality question, and silently merging is the kind of "helpful" behaviour users
  later have to undo. (Stretch goal: report it instead.)

## Pitfalls seen in practice

- Splitting lines on `,` by hand, which breaks on `"Hamilton, Margaret"`.
- Returning `Err` from the whole import on the first bad row (a `?` in the loop body).
- Counting line numbers with `enumerate() + 2`, which is wrong for quoted fields that contain
  newlines.
- Creating the company before validating the email, which leaves orphan companies behind.
- Printing only `{e}` for skipped rows, so "malformed row" appears without the reason.
- Putting the logic in `cli/commands.rs`, where it can't be integration-tested.

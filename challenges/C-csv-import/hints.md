# Challenge C — Hints

Open one tier at a time, and only after you've been stuck for a while. Tier 1 points a
direction, Tier 2 suggests a design, and Tier 3 is close to a solution.

---

## 1. Where does the code go?

<details><summary>Tier 1: direction</summary>

Re-read the constraints: the logic must be testable from `tests/` without a terminal, and must
accept any `std::io::Read`. That rules out putting it in `cli/commands.rs`. Think about which type
already owns "adding contacts while enforcing the rules".

</details>

<details><summary>Tier 2: design</summary>

A new library module (e.g. `src/import.rs`, `pub mod import;` in `lib.rs`) with:

- a method on `Crm` that takes a reader and returns a report: something like
  `pub fn import_contacts<R: std::io::Read>(&mut self, input: R) -> Result<ImportReport, ImportError>`
- a thin convenience function that opens a path and calls it
- the CLI: a new `Command` variant holding the path (`&'a str` is fine; Lab 11 already has
  borrowed command arguments), `is_mutating` → `true`, and an `execute` arm that calls the library
  and prints the report

The outer `Result` is for file-level failures. Row failures live **inside** the `Ok(report)`.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
pub struct ImportReport {
    pub imported: Vec<ContactId>,
    pub created_companies: Vec<CompanyId>,
    pub skipped: Vec<RowError>,
}

pub struct RowError {
    pub line: u64,
    pub problem: RowProblem, // an error enum, not a String
}

impl ImportReport {
    pub fn summary(&self) -> String // "Imported 8, skipped 2"
}

pub fn import_contacts_file(crm: &mut Crm, path: &Path) -> Result<ImportReport, ImportError>
```

In a test, `crm.import_contacts("name,email\nAda,ada@x.test\n".as_bytes())` works because `&[u8]`
implements `Read`.

</details>

---

## 2. Reading CSV with the `csv` crate

<details><summary>Tier 1: direction</summary>

The `csv` crate has a `Reader` that can deserialize each record straight into a struct with
`#[derive(Deserialize)]`, the same serde you used in Lab 21. Look at `csv::ReaderBuilder` on
docs.rs for options (whitespace trimming, for one).

</details>

<details><summary>Tier 2: design</summary>

- A private `#[derive(Deserialize)] struct ContactRow { name: String, email: String, phone: Option<String>, company: Option<String> }`.
  With headers, serde matches columns **by name**, so order doesn't matter, extra columns are
  ignored, and a *missing* `Option` column becomes `None`.
- Check the required columns yourself, once, from `reader.headers()`, before reading any row.
  Otherwise every single row would fail with "missing field" and the import would "succeed" with
  0 imported.
- Loop over `reader.records()`, not `reader.deserialize()`: you want the **raw record** first so
  you can ask for its position (line number), then deserialize it with
  `record.deserialize(Some(&headers))`.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
let mut reader = csv::ReaderBuilder::new()
    .trim(csv::Trim::All)
    .from_reader(input);

let headers = reader.headers().map_err(ImportError::Header)?.clone();
for required in ["name", "email"] {
    if !headers.iter().any(|h| h == required) {
        return Err(ImportError::MissingColumn(required));
    }
}

for result in reader.records() {
    match result {
        Err(e) => { /* malformed: e.position().map_or(0, |p| p.line()) */ }
        Ok(record) => {
            let line = record.position().map_or(0, |p| p.line());
            let row: Result<ContactRow, csv::Error> = record.deserialize(Some(&headers));
            // ...
        }
    }
}
```

`.clone()` on the headers: `reader.headers()` returns a borrow of the reader, and you need the
reader mutably for `records()`. Cloning one small header record ends that borrow.

An empty field deserializes to `None` for an `Option<String>`, but keep a small
`fn non_blank(v: Option<String>) -> Option<String>` as a guard. It makes the rule explicit.

</details>

---

## 3. "A bad row never aborts the import"

<details><summary>Tier 1: direction</summary>

Inside the loop, `?` would return from the whole import function on the first bad row. You need
each row to produce its **own** `Result`, which you then *record* instead of propagating.

</details>

<details><summary>Tier 2: design</summary>

Write a helper that imports **one** row and returns `Result<ContactId, RowProblem>`. Inside *it*,
`?` is exactly right: it stops that row only. The loop then does:

```rust
match self.import_row(row, ...) {
    Ok(id) => report.imported.push(id),
    Err(problem) => report.skipped.push(RowError { line, problem }),
}
```

`RowProblem` is a `thiserror` enum with (at least) a variant for malformed CSV and one wrapping
your `CrmError`. `#[from]` / a manual `From<ValidationError>` make `?` work inside `import_row`
(remember Lab 22: `?` does **one** `From` hop).

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
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

Note `"malformed row"` **without** `{0}`: the csv error is the source, and the chain printer adds
it. Putting it in the message as well prints it twice (Lab 22, Step 7).

Print each reason with your `error_chain` from Lab 22.

</details>

---

## 4. Find the company, or create it

<details><summary>Tier 1: direction</summary>

You'll probably write "search `self.companies` for the name; if not found, `self.add_company(...)`".
If the compiler complains, it's Lab 08's find-then-mutate problem. Ask: *what* do you actually
need from the found company?

</details>

<details><summary>Tier 2: design</summary>

You only need its **id**, and `CompanyId` is `Copy`. Map the search result to the id
(`.map(|c| c.id)`), which ends the shared borrow of `self.companies` before you call a `&mut self`
method. Same for any other lookup-then-change.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
let existing = self.companies.iter().find(|c| c.name == name).map(|c| c.id);
let company_id = match existing {
    Some(id) => id,
    None => self.add_company(name, None)?,
};
```

(The real error you'd hit without `.map(|c| c.id)` is `E0502: cannot borrow *self as mutable
because it is also borrowed as immutable`.)

</details>

---

## 5. "A skipped row changes nothing"

<details><summary>Tier 1: direction</summary>

Order matters. Some checks don't change anything (parse the email, check the name, check for a
duplicate). Some steps change the CRM (create a company, add the contact). What if the *last* step
fails after an earlier step already changed something?

</details>

<details><summary>Tier 2: design</summary>

Two strategies, and both are fine:

1. **Check first, change later.** Do every check that can fail *before* the first change. The
   catch: `add_contact` may enforce rules (like phone format) you'd have to duplicate to check
   beforehand, and the constraints say don't duplicate rules.
2. **Compensate.** Remember whether *this row* created the company. If `add_contact` then fails,
   remove that company again before returning the error.

The reference does cheap checks first (email, name, duplicate), then uses compensation for what's
left. Lab 31 replaces "compensate by hand" with a database transaction that does it for you.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
let mut new_company = None;
// ... when you create one: new_company = Some(id);

match self.add_contact(row.name, email, phone, company_id) {
    Ok(id) => {
        created.extend(new_company); // Option is an iterator of 0 or 1 items
        Ok(id)
    }
    Err(e) => {
        if let Some(id) = new_company {
            self.remove_company(id)?; // it has no contacts, so this succeeds
        }
        Err(e.into())
    }
}
```

Test it with a row like `Eve,eve@x.test,call me maybe!,Evil Corp` (invalid phone, new company).
Afterwards `crm.companies` must be empty.

</details>

---

## 6. Line numbers

<details><summary>Tier 1: direction</summary>

Don't count lines yourself: a quoted field can contain a newline, so "row number + 1" is not
always the file line. The csv crate tracks positions for you.

</details>

<details><summary>Tier 2: design</summary>

`StringRecord::position()` returns `Option<&Position>`, and `Position::line()` is the line where
the record **starts** (1-based, so the header is line 1). Errors from `records()` have
`csv::Error::position()` too. `Option`, because not every error has a position. Use
`map_or(0, |p| p.line())` rather than `unwrap()`.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
let line = record.position().map_or(0, |p| p.line());
```

For the sample file this yields 5 and 9 for the two bad rows.

</details>

---

## 7. Testing

<details><summary>Tier 1: direction</summary>

Most tests don't need a file: pass `"…csv text…".as_bytes()` to the reader-based method. Keep **one
or two** tests that go through a real file in a `tempfile::tempdir()` to cover the path-based entry
point.

</details>

<details><summary>Tier 2: design</summary>

Put the sample file in a `const SAMPLE: &str = "\ ... ";` in `tests/import.rs`. A trailing `\`
at the end of a string line skips the newline and the leading whitespace of the next line, so the
CSV starts cleanly at `name,email,...`. Inside the string, quotes are escaped as `\"`.

Assert on: `report.summary()`, the skipped line numbers (`Vec<u64>`), counts in `crm.contacts` and
`crm.companies`, and error *shapes* with `matches!(report.skipped[0].problem, RowProblem::Malformed(_))`.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
#[test]
fn sample_file_imports_eight_and_skips_two() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("contacts.csv");
    fs::write(&path, SAMPLE).unwrap();
    let mut crm = Crm::new();

    let report = import_contacts_file(&mut crm, &path).unwrap();

    assert_eq!(report.summary(), "Imported 8, skipped 2");
    let lines: Vec<u64> = report.skipped.iter().map(|s| s.line).collect();
    assert_eq!(lines, [5, 9]);
    assert_eq!(crm.contacts.len(), 8);
    assert_eq!(crm.companies.len(), 6);
}
```

</details>

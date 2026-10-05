# 🏁 Challenge C — CSV Contact Import

> **After:** Lab 24 (end of Phase 6) · **Uses:** Phases 1–6 · **Time:** ~4–6 hours
> **Your repo before:** tag `lab-24` · **Suggested tag after:** `challenge-c`

No step-by-step instructions this time. You get a specification, constraints and acceptance
criteria. How you build it is up to you. Tiered hints are in [`hints.md`](hints.md). One possible
design is in [`reference.md`](reference.md). Read it **after** you've finished, and compare.

> Later labs never depend on this challenge. Do it on a branch (`git switch -c challenge-c`) and
> merge it when you're happy.

---

## The feature

Sales just came back from a conference with a spreadsheet of people they met. Typing 200 contacts
into `contact add` isn't an option. Add an `import` command that reads contacts from a CSV file:

```text
crm> import contacts.csv
Imported 8, skipped 2
  line 5: 'bob(at)example.test' is not a valid email address
  line 9: a contact with email ada@analytical.test already exists
```

Real-world files are messy. **A bad row must never abort the import.** The good rows are imported,
the bad rows are skipped, and the user gets a report that says exactly which lines to fix and why.

---

## Specification

### The command

- `import <path>` reads the CSV file at `<path>` (paths without spaces are fine).
- `import` with no or too many arguments prints a usage error, like every other command.
- After an import that changed anything, the CRM is saved (it's a mutating command).

### The file format

- The first line is a **header**. Columns are identified **by name**, not by position:

  | Column | Required? | Meaning |
  |---|---|---|
  | `name` | **yes** | contact name, must not be empty |
  | `email` | **yes** | validated with your `Email` rules (lower-cased, etc.) |
  | `phone` | no | empty → no phone |
  | `company` | no | empty → no company |

- Columns may appear in **any order**. Unknown extra columns (e.g. `notes`) are **ignored**.
- Standard CSV quoting applies: `"Hamilton, Margaret"` is one field containing a comma.
- Leading and trailing whitespace around fields is ignored.

### Per-row rules

For each data row, in file order:

1. The email must be valid (your `Email` type decides).
2. The name must not be empty.
3. The email must not already exist in the CRM. That includes contacts imported **earlier in
   the same file**, so a file containing the same person twice imports them once.
4. If `company` is not empty, the contact is linked to the company with **exactly** that name. If
   no such company exists, it's **created** (lifecycle Prospect), and later rows with the same
   company name reuse it.
5. Any other rule your `Crm::add_contact` / `Validate for Contact` enforces (e.g. phone format)
   still applies.

A row that breaks any rule is **skipped**. A skipped row changes **nothing**: in particular, it
must not leave behind a company it would have created.

A row that isn't valid CSV for this file (for example, it has a different number of fields than
the header) is also skipped and reported. It doesn't stop the import.

### File-level errors

These abort the import **before anything is changed** and are printed like any other error:

- the file can't be opened (`Error: … could not open nope.csv: No such file or directory …`)
- the header is missing a required column (`… missing required column 'email'`)

### The report

- First line: `Imported <n>, skipped <m>`
- Then one line per skipped row, in file order: `  line <L>: <reason>`, where `<L>` is the
  line number **in the file** (the header is line 1) and `<reason>` is the full error message,
  causes included (Lab 22's chain).

---

## Sample file

Save as `contacts.csv` in your `rust-crm` folder. Rows 5 and 9 are bad on purpose.

```csv
name,email,phone,company
Ada Lovelace,ada@analytical.test,555-0100,Analytical Engines
Charles Babbage,charles@analytical.test,,Analytical Engines
Grace Hopper,grace@navy.test,555-0199,US Navy
Bob Broken,bob(at)example.test,,US Navy
"Hamilton, Margaret",margaret@apollo.test,,"Apollo, MIT"
Katherine Johnson,katherine@nasa.test,555-0142,
Linus Torvalds,linus@kernel.test,,Linux Foundation
ADA LOVELACE,ADA@analytical.test,,Analytical Engines
Alan Turing,alan@bletchley.test,,Bletchley Park
Tim Berners-Lee,tim@cern.test,,CERN
```

| Line | What it tests |
|---|---|
| 2–3 | a new company created once, then reused |
| 4 | phone present |
| 5 | ❌ invalid email: skipped. `US Navy` already exists from line 4, so nothing to undo here |
| 6 | quoted fields containing commas (name **and** company) |
| 7 | empty company, so no company |
| 9 | ❌ same email as line 2 after normalisation: skipped |
| 10–11 | ordinary rows |

Expected, starting from an **empty** CRM (`cargo run -- --storage memory`):

```text
crm> import contacts.csv
Imported 8, skipped 2
  line 5: 'bob(at)example.test' is not a valid email address
  line 9: a contact with email ada@analytical.test already exists
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Analytical Engines   prospect  -
#2   US Navy              prospect  -
#3   Apollo, MIT          prospect  -
#4   Linux Foundation     prospect  -
#5   Bletchley Park       prospect  -
#6   CERN                 prospect  -
```

(Your messages and table formatting come from your own `Display` impls and may differ. The
**counts and line numbers** must match.)

And a malformed row, for example a file whose line 2 is just `Only,two`:

```text
Imported 1, skipped 1
  line 2: malformed row: CSV error: record 1 (line: 2, byte: 25): found record with 2 fields, but the previous record has 4 fields
```

---

## Acceptance criteria

- [ ] `import contacts.csv` on the sample file reports `Imported 8, skipped 2` with lines 5 and 9
- [ ] after the import, the CRM has 8 contacts and 6 companies, and Ada and Charles share one company
- [ ] `Apollo, MIT` and `Hamilton, Margaret` keep their commas
- [ ] a duplicate of a contact that **already existed before the import** is skipped
- [ ] an existing company is reused by exact name, not duplicated
- [ ] a skipped row never leaves behind a newly created company (test it with a row that has a new
      company name but an invalid phone, or whatever your rules reject *after* the email check)
- [ ] a malformed row is reported with its line number and the rest of the file is still imported
- [ ] columns in a different order, and extra columns, work
- [ ] a missing `name` or `email` column rejects the whole file and changes nothing
- [ ] a missing file is reported as an error. The REPL keeps running.
- [ ] `import` with a wrong number of arguments prints a usage message
- [ ] the import is saved by your storage (it counts as a mutating command)
- [ ] no `unwrap`/`expect`/indexing that could panic on **any** file content (try an empty file,
      a header-only file, a binary file)
- [ ] tests (see below); `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`,
      `cargo test` all pass

### Tests required

- [ ] **integration tests** in `tests/` (e.g. `tests/import.rs`), using `tests/common` where useful
- [ ] at least one test imports a **real file** written into a `tempfile::tempdir()`
- [ ] every acceptance criterion above that can be checked without a terminal has a test
- [ ] errors are checked by shape (`matches!`), not by comparing full message strings

---

## Constraints

- Use the [`csv`](https://docs.rs/csv) crate (`cargo add csv`, written against csv 1). Don't
  split lines on commas yourself: quoting, escaping and embedded newlines are exactly what a real
  CSV parser is for.
- **The import logic lives in the library, not in `cli/`.** `cli/commands.rs` only calls it and
  prints the report (the Lab 14 rule). The logic must be testable from `tests/` without a terminal.
- **Reuse your domain rules.** Email validation, duplicate detection and contact validation must
  go through the same code paths as `contact add` (`Email`, `Crm::add_contact`, …), not a
  second copy of the rules.
- Errors are **typed** (`thiserror`), separated by level: "the file can't be imported" vs "this row
  was skipped". The report keeps the **structured** reason for each skipped row (an error value),
  not just a pre-formatted string.
- The core import function should not require a file on disk: it should accept any
  `std::io::Read` source (a `File`, a `&[u8]` in a test, …).
- No new crates besides `csv`.

---

## Concepts you're expected to use

| Concept | From |
|---|---|
| `serde::Deserialize` for a row struct, `Option<String>` for optional columns | Lab 21 |
| `thiserror` error enums, `#[source]`, `#[from]`, transparent, error chains | Lab 22 |
| Generics with trait bounds (`R: std::io::Read`) | Labs 16, 23 |
| `Result` and `?` per row, collecting outcomes instead of returning early | Lab 12 |
| Borrowing while looking up then mutating (find-then-insert) | Labs 07–08 |
| Iterators over records | Lab 17 |
| `Crm` business methods, validation, `Email` | Labs 12, 14, 15 |
| Integration tests, `tempfile`, test helpers | Lab 24 |
| Thin CLI, mutating commands and saving | Labs 21, 23 |

---

## Stretch goals (optional)

- `import --dry-run <path>`: produce the same report but change **nothing**. (How do you make
  "nothing changes" true by construction rather than by care?)
- Match companies case-insensitively and with surrounding whitespace ignored, but **report** when a
  row's spelling differs from the existing company's.
- Write the skipped rows to `<path>.rejected.csv`, with an extra `error` column, so the user can fix
  and re-import just those.
- An `export <path>` command that writes all contacts as CSV with the same columns, and a test that
  `export` followed by `import` into an empty CRM reproduces the contacts.

When you're done: commit, tag `challenge-c`, push, and only then open [`reference.md`](reference.md).

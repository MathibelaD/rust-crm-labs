# Lab 24 — Solutions

> 🔴 **SOLUTION**: make a genuine attempt first. Your tests may be shaped differently and still be
> right. Check that each one tests the *behaviour* named in its title, through the public API.

---

## 🔵 Your Turn 1: `tests/lead_conversion.rs`

The imports grow to:

```rust
mod common;

use common::{MARGARET, sample_crm};
use rust_crm::crm::Crm;
use rust_crm::deals::DealStage;
use rust_crm::errors::CrmError;
use rust_crm::leads::{LeadId, LeadSource};
use rust_crm::money::Money;
```

The four new tests and the helper:

```rust
#[test]
fn converting_with_a_deal_creates_the_deal_in_qualification() {
    let mut crm = sample_crm();
    let deal = Some(("Apollo guidance".to_string(), Money::from_cents(990_000)));

    let summary = crm.convert_lead(MARGARET, deal).unwrap();

    let deal_id = summary.deal_id.expect("a deal was requested");
    let deal = crm.deals.get(deal_id).unwrap();
    assert_eq!(deal.company_id, summary.company_id);
    assert_eq!(deal.stage, DealStage::Qualification);
    assert_eq!(deal.value, Money::from_cents(990_000));
}

#[test]
fn converted_lead_is_removed_from_leads() {
    let mut crm = sample_crm();
    crm.convert_lead(MARGARET, None).unwrap();
    assert!(crm.leads.get(MARGARET).is_none());
    assert!(crm.leads.is_empty());
}

#[test]
fn unqualified_lead_cannot_be_converted_and_stays() {
    let mut crm = sample_crm();
    let id = add_new_lead(&mut crm, "Katherine Johnson", "kj@nasa.test", None);
    let companies_before = crm.companies.len();

    let result = crm.convert_lead(id, None);

    assert!(matches!(result, Err(CrmError::LeadNotQualified(lead)) if lead == id));
    assert!(crm.leads.get(id).is_some(), "the lead must be handed back");
    assert_eq!(crm.companies.len(), companies_before, "nothing was created");
}

#[test]
fn lead_without_company_name_becomes_individual_company() {
    let mut crm = sample_crm();
    let id = add_new_lead(&mut crm, "Katherine Johnson", "kj@nasa.test", None);
    crm.qualify_lead(id).unwrap();

    let summary = crm.convert_lead(id, None).unwrap();

    let company = crm.companies.get(summary.company_id).unwrap();
    assert_eq!(company.name, "Katherine Johnson (individual)");
}

/// Adds a lead with status New and returns its id.
fn add_new_lead(crm: &mut Crm, name: &str, email: &str, company: Option<&str>) -> LeadId {
    crm.add_lead(
        name.into(),
        common::email(email),
        company.map(String::from),
        LeadSource::Website,
        None,
    )
    .unwrap()
}
```

**Reasoning**

- **`unqualified_lead_cannot_be_converted_and_stays` tests three things on purpose.** The error is
  the obvious one. "The lead is still there" is the ownership lesson from Lab 19: `convert(self)`
  consumed the lead, and `ConvertError` handed it back. If someone breaks that path, the lead
  silently disappears, the worst kind of bug. "No company was created" checks there's no
  half-finished conversion. In Lab 31 this becomes a database transaction, and this test describes
  exactly what the transaction must guarantee.
- **Assertion messages** (`"the lead must be handed back"`) turn a bare `assertion failed` into
  an explanation. Add them wherever the assertion alone doesn't say *why* it matters.
- **`add_new_lead` lives in this file, not in `common`.** Only this file needs it. Helpers move to
  `common` once a second file wants them.
- **`expect("a deal was requested")`** instead of `unwrap()` on `deal_id`: if it's `None`, the
  panic message says what we expected.
- `name.into()` and `company.map(String::from)`: the helper takes `&str`s for convenient calls,
  while `add_lead` wants owned `String`s. `Option::map` converts the inside only if it's `Some`.

---

## 🔵 Your Turn 2: `tests/pipeline.rs`

```rust
mod common;

use common::{PILOT, ROLLOUT, sample_crm};
use rust_crm::deals::{DealStage, PipelineRow};
use rust_crm::errors::CrmError;
use rust_crm::money::Money;

fn row(report: &[PipelineRow], stage: DealStage) -> &PipelineRow {
    report
        .iter()
        .find(|r| r.stage == stage)
        .expect("every stage has a row")
}

#[test]
fn pipeline_lists_every_stage_in_order() {
    let report = sample_crm().pipeline_report();
    let stages: Vec<DealStage> = report.iter().map(|r| r.stage).collect();
    assert_eq!(
        stages,
        [
            DealStage::Qualification,
            DealStage::Proposal,
            DealStage::Negotiation,
            DealStage::Won,
            DealStage::Lost,
        ]
    );
}

#[test]
fn pipeline_counts_and_sums_deals_per_stage() {
    let report = sample_crm().pipeline_report();

    assert_eq!(row(&report, DealStage::Qualification).count, 1);
    assert_eq!(
        row(&report, DealStage::Qualification).total,
        Money::from_cents(400_000)
    );
    assert_eq!(row(&report, DealStage::Proposal).count, 1);
    assert_eq!(
        row(&report, DealStage::Proposal).total,
        Money::from_cents(1_250_000)
    );
    assert_eq!(row(&report, DealStage::Won).count, 0);
    assert_eq!(row(&report, DealStage::Won).total, Money::default());
}

#[test]
fn moving_a_deal_moves_its_value_between_stages() {
    let mut crm = sample_crm();
    crm.move_deal(ROLLOUT, DealStage::Won).unwrap();

    let report = crm.pipeline_report();
    assert_eq!(row(&report, DealStage::Proposal).count, 0);
    assert_eq!(
        row(&report, DealStage::Won).total,
        Money::from_cents(1_250_000)
    );
}

#[test]
fn total_pipeline_value_is_unchanged_by_moves() {
    let mut crm = sample_crm();
    let before: Money = crm.pipeline_report().iter().map(|r| r.total).sum();
    crm.move_deal(PILOT, DealStage::Lost).unwrap();
    let after: Money = crm.pipeline_report().iter().map(|r| r.total).sum();
    assert_eq!(before, after);
}

#[test]
fn closed_deals_cannot_move() {
    let mut crm = sample_crm();
    crm.move_deal(ROLLOUT, DealStage::Won).unwrap();

    let result = crm.move_deal(ROLLOUT, DealStage::Negotiation);

    assert!(matches!(
        result,
        Err(CrmError::InvalidTransition {
            from: DealStage::Won,
            to: DealStage::Negotiation
        })
    ));
}
```

**Reasoning**

- **Why `row` compiles without `'a`:** it has exactly one reference parameter (`report`;
  `stage` is a `Copy` value), so elision rule 2 from Lab 10 gives the output the same lifetime:
  `fn row<'a>(report: &'a [PipelineRow], stage: DealStage) -> &'a PipelineRow`. The returned row
  borrows from the report, which is exactly the truth.
- **Looking rows up by stage**, instead of `report[1]`, keeps the counting test independent of the
  ordering. The ordering has its own test (`pipeline_lists_every_stage_in_order`). One reason to
  fail per test.
- **`assert_eq!(stages, [...])`** compares a `Vec<DealStage>` with an array. `Vec<T>` implements
  `PartialEq<[T; N]>`, so no `vec![]` is needed.
- **`total_pipeline_value_is_unchanged_by_moves`** is an *invariant* (property) test: instead of
  checking specific numbers, it checks a rule that must hold for any move. It uses Lab 18's
  `impl Sum for Money` through `.sum()`. The type annotation `let before: Money` tells `sum`
  what to produce.
- **`matches!` with literal enum values inside a struct variant** checks the exact transition
  without needing `PartialEq` on `CrmError`.

---

## 🔵 Your Turn 3: `tests/persistence.rs`

```rust
mod common;

use std::cell::RefCell;
use std::fs;

use common::{ACME, sample_crm};
use rust_crm::companies::CompanyId;
use rust_crm::crm::Crm;
use rust_crm::storage::{JsonFileStorage, Storage, StorageError};
use tempfile::TempDir;

/// A fresh temporary directory and a JsonFileStorage pointing into it.
/// Keep the TempDir alive: dropping it deletes the directory.
fn json_storage() -> (TempDir, JsonFileStorage) {
    let dir = tempfile::tempdir().unwrap();
    let storage = JsonFileStorage::new(dir.path().join("crm.json"));
    (dir, storage)
}

/// Two CRMs are equal if they serialize to the same JSON.
fn same_data(a: &Crm, b: &Crm) -> bool {
    serde_json::to_value(a).unwrap() == serde_json::to_value(b).unwrap()
}

#[test]
fn missing_file_loads_an_empty_crm() {
    let (_dir, storage) = json_storage();
    let crm = storage.load().unwrap();
    assert!(crm.companies.is_empty());
}

#[test]
fn json_round_trip_preserves_everything() {
    let (_dir, storage) = json_storage();
    let original = sample_crm();

    storage.save(&original).unwrap();
    let loaded = storage.load().unwrap();

    assert!(same_data(&original, &loaded));
}

#[test]
fn ids_continue_after_reload() {
    let (_dir, storage) = json_storage();
    storage.save(&sample_crm()).unwrap();

    let mut loaded = storage.load().unwrap();
    let id = loaded.add_company("Initech".into(), None).unwrap();

    assert_eq!(id, CompanyId(3));
    assert_eq!(loaded.contacts_of(ACME).len(), 2);
}

#[test]
fn corrupt_file_is_a_parse_error() {
    let (_dir, storage) = json_storage();
    fs::write(storage.path(), "{ this is not json").unwrap();

    let result = storage.load();

    assert!(matches!(result, Err(StorageError::Parse { .. })));
}

#[test]
fn save_leaves_only_the_data_file() {
    let (dir, storage) = json_storage();
    storage.save(&sample_crm()).unwrap();

    let names: Vec<String> = fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["crm.json"]);
}

/// A storage implemented *outside* the crate: it keeps the last saved
/// snapshot as a JSON string in memory.
#[derive(Debug, Default)]
struct RecordingStorage {
    snapshot: RefCell<Option<String>>,
}

impl Storage for RecordingStorage {
    fn load(&self) -> Result<Crm, StorageError> {
        match &*self.snapshot.borrow() {
            Some(json) => Ok(serde_json::from_str(json).expect("we wrote this JSON ourselves")),
            None => Ok(Crm::default()),
        }
    }

    fn save(&self, crm: &Crm) -> Result<(), StorageError> {
        let json = serde_json::to_string(crm).expect("a Crm always serializes");
        *self.snapshot.borrow_mut() = Some(json);
        Ok(())
    }
}

/// What every *persistent* storage must do, whatever it's built on.
/// (InMemoryStorage is deliberately not persistent, so it isn't checked here:
/// "load returns what was saved" is exactly the promise it doesn't make.)
fn check_storage_contract(storage: &dyn Storage) {
    let empty = storage.load().unwrap();
    assert!(empty.companies.is_empty(), "a new storage starts empty");

    let crm = sample_crm();
    storage.save(&crm).unwrap();
    assert!(
        same_data(&crm, &storage.load().unwrap()),
        "load returns what was saved"
    );

    storage.save(&Crm::new()).unwrap();
    assert!(
        storage.load().unwrap().companies.is_empty(),
        "the latest save wins"
    );
}

#[test]
fn json_file_storage_fulfils_the_contract() {
    let (_dir, storage) = json_storage();
    check_storage_contract(&storage);
}

#[test]
fn recording_storage_fulfils_the_contract() {
    check_storage_contract(&RecordingStorage::default());
}
```

**Reasoning**

- **`let (_dir, storage) = json_storage();`** The name `_dir` (with an underscore) keeps the
  `TempDir` alive until the end of the test while saying "I don't use it directly". A bare `_`
  would be a **different thing**: `let (_, storage) = ...` drops the value immediately, so the
  directory would be deleted before the test runs. `_name` binds, `_` doesn't.
- **`same_data` through `serde_json::Value`** compares *everything that's persisted*, including
  `next_id` in every repository, without adding `PartialEq` to every domain type just for tests.
  It's also exactly the right definition of "equal" for a persistence test: equal on disk.
- **`ids_continue_after_reload`** is the integration-level version of Lab 21's unit test. If
  someone later changes the JSON format (or in Lab 30 the storage entirely), this says what must
  still be true.
- **`save_leaves_only_the_data_file`** checks the atomic-write implementation from the outside: no
  `.tmp` debris. A fresh temp dir per test makes "exactly one file" a meaningful assertion.
- **`RefCell` in `RecordingStorage`:** `Storage::save` takes `&self`, but saving must change the
  snapshot. `RefCell` moves the borrow check to runtime (Lab 14). `match &*self.snapshot.borrow()`
  borrows the `Option<String>` inside without cloning: `borrow()` gives a `Ref`, `*` derefs it to
  the `Option`, and `&` borrows it again so the `match` doesn't try to move out.
- **The contract function takes `&dyn Storage`** so one function checks every implementation,
  including types it has never heard of. Shared contract tests are how you keep several
  implementations of one trait honest. When Lab 31 discusses a Postgres repository trait, this is
  the testing pattern you'd use.
- **Why `InMemoryStorage` isn't checked:** it doesn't persist. "Load returns what was saved" is the
  promise it deliberately doesn't make (Lab 23's `save_keeps_nothing` test documents that). Running
  it through this contract would fail, correctly. If you want, write a smaller contract for "any
  storage" (a new storage loads without error, save succeeds) and run all three through it.

> ⚠️ **Heads-up for Lab 25:** `RecordingStorage` uses `RefCell`, which is not `Sync`. When Lab 25
> makes `Storage: Send + Sync`, this test double stops compiling, and you'll switch it to a
> `Mutex<Option<String>>`. That's a good preview of exactly what Lab 25 teaches.

---

## 🔵 Your Turn 4: `tests/validation.rs`

```rust
mod common;

use common::{ACME, email, sample_crm};
use rust_crm::companies::CompanyId;
use rust_crm::contacts::Email;
use rust_crm::errors::{CrmError, ValidationError};
use rust_crm::money::Money;

#[test]
fn valid_emails_are_normalised() {
    let cases = [
        ("ada@example.com", "ada@example.com"),
        ("  Ada@Example.COM  ", "ada@example.com"),
        (
            "first.last+tag@sub.example.org",
            "first.last+tag@sub.example.org",
        ),
    ];
    for (input, expected) in cases {
        let parsed =
            Email::parse(input).unwrap_or_else(|e| panic!("{input:?} should be valid: {e}"));
        assert_eq!(parsed.as_str(), expected, "input: {input:?}");
    }
}

#[test]
fn invalid_emails_are_rejected() {
    for input in [
        "",
        "ada",
        "ada@",
        "@example.com",
        "ada@example",
        "a b@example.com",
        "a@b@example.com",
    ] {
        assert!(
            matches!(Email::parse(input), Err(ValidationError::InvalidEmail(_))),
            "{input:?} should be rejected"
        );
    }
}

#[test]
fn money_parses_whole_and_fractional_amounts() {
    let cases = [
        ("1250", 125_000),
        ("1250.5", 125_050),
        ("1250.50", 125_050),
        ("0.07", 7),
        ("$1,250.50", 125_050),
    ];
    for (input, cents) in cases {
        assert_eq!(
            Money::parse(input),
            Ok(Money::from_cents(cents)),
            "input: {input:?}"
        );
    }
}

#[test]
fn money_rejects_malformed_amounts() {
    for input in ["", "abc", "12.345", "12.", "1.2.3"] {
        assert!(Money::parse(input).is_err(), "{input:?} should be rejected");
    }
}

#[test]
fn duplicate_contact_email_is_rejected() {
    let mut crm = sample_crm();
    let result = crm.add_contact("Imposter".into(), email("ada@acme.test"), None, None);
    assert!(matches!(result, Err(CrmError::DuplicateEmail(_))));
}

#[test]
fn contact_for_a_missing_company_is_rejected() {
    let mut crm = sample_crm();
    let result = crm.add_contact(
        "Nobody".into(),
        email("nobody@x.test"),
        None,
        Some(CompanyId(99)),
    );
    assert!(matches!(
        result,
        Err(CrmError::NotFound {
            entity: "company",
            id: 99
        })
    ));
}

#[test]
fn company_with_contacts_cannot_be_deleted() {
    let mut crm = sample_crm();
    let result = crm.remove_company(ACME);
    assert!(matches!(result, Err(CrmError::HasContacts(id)) if id == ACME));
    assert!(crm.companies.get(ACME).is_some());
}

#[test]
fn deal_with_empty_title_is_rejected() {
    let mut crm = sample_crm();
    let result = crm.add_deal(ACME, "   ".into(), Money::from_cents(100));
    assert!(matches!(
        result,
        Err(CrmError::Validation(ValidationError::EmptyTitle))
    ));
}
```

**Reasoning**

- **Table-driven tests** keep each case to one line, so adding a case costs nothing, and the
  table *is* the specification. The catch: the test stops at the first failing case. That's why
  every assertion message includes `{input:?}`: you immediately know *which* row failed.
- **`unwrap_or_else(|e| panic!(...))`** instead of `unwrap()`: the closure only runs on error and
  puts both the input and the validation message in the failure.
- **Are these duplicating unit tests from Lab 12?** Partly, and that's OK. Unit tests in
  `email.rs` may check internal helpers. These check the *public* contract, and they'll keep
  passing if `Email`'s internals are rewritten. If you'd rather not duplicate, keep the tables
  here and trim the unit tests.
- `"$1,250.50"` is accepted because Lab 18's parser strips the `$` and thousands separators, so
  what `Display` prints can be typed back in. That round trip is worth one table row. If you
  changed the parsing rules (negative amounts, for example), the tables should describe *your*
  rules.
- **`NotFound { entity: "company", id: 99 }`** in a pattern: string literals and integer literals
  are valid patterns, so the test checks exactly which entity and id were reported.

---

## 🔵 Your Turn 5: doc tests

On the `Money` struct (keep your existing doc lines, add the example below them):

```rust
/// An amount of money, stored as a whole number of cents.
///
/// The field is private: the only ways in are `from_cents` and `parse`.
///
/// ```
/// use rust_crm::money::Money;
///
/// let price = Money::from_cents(125_050);
/// assert_eq!(price.to_string(), "$1,250.50");
/// assert_eq!((price + Money::from_cents(50)).cents(), 125_100);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Money {
```

On `Money::parse`:

```rust
    /// Parses user input such as `1250`, `1250.5`, `1250.50`, `$1,250.50`.
    ///
    /// ```
    /// use rust_crm::money::Money;
    ///
    /// assert_eq!(Money::parse("1250.5"), Ok(Money::from_cents(125_050)));
    /// assert_eq!(Money::parse("7"), Ok(Money::from_cents(700)));
    /// assert!(Money::parse("12.345").is_err()); // no fractions of a cent
    /// ```
    pub fn parse(input: &str) -> Result<Money, ValidationError> {
```

`Email::parse` already ends with `assert!(Email::parse("not-an-email").is_err());` from Lab 13.
If yours doesn't, add that line before the closing fence.

`cargo test --doc`:

```text
test src/money.rs - money::Money (line 14) ... ok
test src/contacts/email.rs - contacts::email::Email::parse (line 36) ... ok
test src/money.rs - money::Money::parse (line 40) ... ok
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test src/contacts/email.rs - contacts::email::Email (line 23) - compile fail ... ok
test src/leads/conversion.rs - leads::conversion::Lead::convert (line 66) - compile fail ... ok
test src/contacts/email.rs - contacts::email::Email (line 15) - compile fail ... ok
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.06s
```

**Reasoning**

- **Doc examples should be short and show the *typical* use**, one surprising case at most. The
  exhaustive tables live in `tests/validation.rs`. Docs are for readers; tests are for coverage.
- **`use rust_crm::money::Money;`** is needed because each doc test is compiled as a small
  external program. That's also why doc tests can only use the public API.
- **Two `test result` lines**: recent Cargo versions merge ordinary doc tests into one binary
  for speed, while `compile_fail` tests still have to be compiled one by one. Same tests, just
  reported in two groups.
- **`cargo doc --open`** now shows these examples in your generated documentation, guaranteed to
  compile and pass.

---

## 🧪 Experiment answers

**Experiment 1 (badly formatted code in a PR).** The **Formatting** step fails within seconds
(after checkout, toolchain and cache restore). Clippy and Tests never run. Cheap checks first
means fast feedback, and no CI minutes spent compiling code that would be rejected anyway.

**Experiment 2 (allow `Won → Negotiation`).** Lab 18's unit tests fail first:
`deals::model::tests::transition_table_is_exactly_as_specified` (`won -> negotiation`) and
`rejected_move_leaves_stage_unchanged`. `cargo test` stops after the first failing test binary
(`error: test failed, to rerun pass --lib`), so you don't see the integration tests yet. Run
`cargo test --no-fail-fast` and `closed_deals_cannot_move` in `tests/pipeline.rs` fails too, with
`assertion failed: matches!(result, Err(CrmError::InvalidTransition { .. }))`. Both kinds caught it,
and the names alone say which business rule broke. That's the payoff of naming tests as
sentences.

**Experiment 3 (`tempfile::tempdir().unwrap().path().join(...)`).** The `TempDir` is a
**temporary value**: it's never bound to a variable, so it's dropped at the end of the `let`
statement, and its `Drop` deletes the directory. `path` (an owned `PathBuf`, so the borrow checker
is satisfied) now points into a directory that no longer exists. `save` fails with
`could not write …: No such file or directory`. Ownership answers it: *who owns the `TempDir`?*
Nobody, so it dies immediately. Bind it: `let dir = tempfile::tempdir()?;`.

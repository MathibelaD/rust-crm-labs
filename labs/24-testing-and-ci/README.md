# Lab 24 — Testing Properly + Continuous Integration 🧪

> **Phase:** 6 — Persistence & Quality · **Builds on:** Lab 23 · **Time:** ~4.5 hours
> **Your repo before this lab:** tag `lab-23` · **After:** tag `lab-24`

## 🎯 Goal
Give the CRM a real test suite: integration tests in `tests/` that use the CRM exactly as an
outside user would (lead conversion, the pipeline report, persistence, validation), doc tests that
keep your examples honest, and a GitHub Actions workflow that runs formatting, Clippy and every
test on every push. A green badge on your README proves it.

## 🧠 What You'll Learn
- **Unit vs integration tests**: why `tests/` can only see your **public** API, and why that's
  exactly what Lab 13's module work was for
- How `cargo test` builds *several* test binaries, and what each one is
- The shared-helpers pattern: `tests/common/mod.rs`, and the `dead_code` trap it sets
- `[dev-dependencies]` and the `tempfile` crate (RAII clean-up that survives panics)
- **Doc tests**, including `compile_fail` tests that prove an invariant
- Running a subset: `cargo test <filter>`, `--test <file>`, `-- --nocapture`, `--doc`, `#[ignore]`
- `#[should_panic]`: when it's appropriate, and a trap with debug vs release builds
- **Contract tests**: one test function every `Storage` must pass, plus a test double written
  outside the crate
- A **GitHub Actions** workflow: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`,
  with caching, and a CI badge

## 🔨 What We're Building
You've written unit tests since Lab 05, inside `src/`, next to the code. They're great for small
pieces (`Money::parse`, the parser, `error_chain`) and they can see private details.

They can't answer a different question: **does the CRM work when used from outside, through its
public API only?** That's the question that matters for what's coming:

| Lab | Big change | What protects you |
|---|---|---|
| 25 | REPL + background thread share the CRM | tests that the public API still behaves |
| 26 | everything becomes async | same |
| 27–29 | an HTTP server drives the same domain | same, plus API tests (Lab 29) |
| 30–31 | Postgres replaces JSON | the *behaviour* tests you write today describe what must survive |

A refactor is only safe if something checks you didn't change behaviour by accident. Today you
build that something, and a robot (CI) that runs it on every push.

```text
rust-crm/
├── src/...                       ← unit tests live here (#[cfg(test)] mod tests)
├── tests/                        ← NEW: integration tests
│   ├── common/mod.rs             ← shared helpers (sample_crm)
│   ├── lead_conversion.rs
│   ├── pipeline.rs
│   ├── persistence.rs
│   └── validation.rs
├── .github/workflows/ci.yml      ← NEW: CI
└── README.md                     ← NEW: with a CI badge
```

> This lab assumes you completed Lab 23's Your Turn 1 (`InMemoryStorage`) and Your Turn 2
> (`Storage::describe`). See [Lab 23's solutions.md](../23-storage-trait/solutions.md) if not.

---

## Step 1 — Integration tests are a different crate

Every `.rs` file directly inside `tests/` is compiled as **its own crate**, a separate little
program that depends on your library exactly like someone else's project would:

```text
            your package "rust-crm"
 ┌──────────────────────────────────────────────────────────┐
 │ library crate rust_crm (src/lib.rs)                       │
 │   + its unit tests (#[cfg(test)], see private items)      │
 │                                                          │
 │ binary crate rust-crm (src/main.rs)                       │
 │   + its unit tests (Lab 23's clap tests)                  │
 └───────────▲───────────────▲───────────────▲──────────────┘
             │ use rust_crm::…  (public API only)
   tests/pipeline.rs   tests/persistence.rs   tests/validation.rs …
   (each one = its own crate = its own test binary)
```

Let's prove "public API only" to ourselves.

> 🟡 **EXPERIMENT**: create `tests/peek.rs`, then run `cargo test --test peek`

```rust
use rust_crm::cli::parser::parse_command;

#[test]
fn parses_help() {
    assert!(parse_command("help").is_ok());
}
```

```text
error[E0603]: module `parser` is private
 --> tests/peek.rs:1:20
  |
1 | use rust_crm::cli::parser::parse_command;
  |                    ^^^^^^ private module
  |
note: the module `parser` is defined here
 --> src/cli/mod.rs:5:1
  |
5 | mod parser;
  | ^^^^^^^^^^
```

Exactly as it should be. The parser is an implementation detail of the CLI (Lab 13 made it
private on purpose), so its tests belong **inside** `src/cli/parser.rs` as unit tests, where they
already are. Delete `tests/peek.rs`.

So what *can* an integration test use? Everything you made `pub` and reachable from `lib.rs`:
`Crm` and its methods, the models and their `pub` fields, `InMemoryRepo`'s methods, `Email`,
`Money`, `DealStage`, `Lead::builder`, the `Storage` trait, `JsonFileStorage`, `InMemoryStorage`,
`StorageError`, `CrmError`, `ValidationError`. That's a rich API, and it exists because Lab 13 split
the CRM into a library with a deliberately chosen public surface, and Lab 14 put the business rules
in `Crm` instead of in the CLI. Both decisions pay off today.

**And the binary?** `src/main.rs` has no public API: nothing can `use` a binary. That's why it
should stay tiny (parse args, build storage, call the library) and why its few tests live inside it.

| | Unit tests | Integration tests |
|---|---|---|
| Where | `#[cfg(test)] mod tests` inside `src/…` | `tests/*.rs` |
| Sees | everything in its module, private items too | `pub` API only |
| Compiled as | part of your crate (only under `cargo test`) | separate crates |
| Good for | one function or type, edge cases, private helpers | behaviour across modules, as a user sees it |
| Breaks when | you change internals | you change **behaviour** (or the public API) |

That last row is the key. A good integration test survives a total rewrite of the internals.
That's precisely what you'll do in Labs 25–31.

---

## Step 2 — `tempfile`, a dev-dependency

```bash
cargo add --dev tempfile
```

> Written against **tempfile 3**.

Look at `Cargo.toml`: a new `[dev-dependencies]` section appeared. Dev-dependencies are
available to tests, examples and benchmarks, but they are **not** compiled into your program or
seen by anyone depending on your library. A testing tool has no reason to be in the shipped
binary.

What `tempfile::tempdir()` gives you, compared to Lab 21's hand-made `temp_file` helper:

```rust
let dir = tempfile::tempdir().unwrap();         // a fresh, uniquely named directory
let path = dir.path().join("crm.json");         // put whatever you like inside
// ... use it ...
// `dir` is dropped at the end of scope → the directory and everything in it is deleted
```

`TempDir` cleans up in its **`Drop`** impl. Rust runs destructors while a panic unwinds the stack,
so the directory disappears **even when an `assert!` fails**. That's RAII (Lab 06's ownership
rules), applied to test hygiene. In Lab 21 you had to remember "clean up before asserting".

The one trap: the directory lives exactly as long as the `TempDir` value.
`let path = tempfile::tempdir().unwrap().path().join("x.json");` creates the `TempDir`, borrows
its path, and **drops it at the end of the statement**, so the directory is already deleted
when you use `path`. Always bind the `TempDir` to a variable that lives for the whole test.

---

## Step 3 — Shared helpers: `tests/common/mod.rs`

Most tests need "a CRM with some realistic data in it". Writing that in every test file would be
copy-paste; put it in one place.

**Why `tests/common/mod.rs` and not `tests/common.rs`?** Remember: every `.rs` file *directly* in
`tests/` becomes a test crate. `tests/common.rs` would be compiled as a test binary with zero
tests, and you'd see an empty `Running tests/common.rs` section in every test run. Files in
**subdirectories** of `tests/` are not test crates, so `tests/common/mod.rs` is just a module
that test files include with `mod common;`.

> 🟢 **FOLLOW ALONG**: create `tests/common/mod.rs`

```rust
//! Shared helpers for the integration tests. Each file in tests/ is its own
//! crate and includes this module with `mod common;`.

use rust_crm::companies::CompanyId;
use rust_crm::contacts::{ContactId, Email};
use rust_crm::crm::Crm;
use rust_crm::deals::{DealId, DealStage};
use rust_crm::leads::{LeadId, LeadSource};
use rust_crm::money::Money;

/// Parses an email that the test author knows is valid.
pub fn email(s: &str) -> Email {
    Email::parse(s).expect("test emails must be valid")
}

/// A small, realistic CRM:
///
/// | id | company  | contacts       | deals                                   |
/// |----|----------|----------------|-----------------------------------------|
/// | 1  | Acme Ltd | Ada, Grace     | #1 "Acme rollout" $12,500.00 (proposal) |
/// | 2  | Globex   | Linus          | #2 "Globex pilot"  $4,000.00 (qualif.)  |
///
/// plus lead #1, Margaret Hamilton (company "Apollo"), already qualified.
pub fn sample_crm() -> Crm {
    let mut crm = Crm::new();

    let acme = crm
        .add_company("Acme Ltd".into(), Some("https://acme.test".into()))
        .unwrap();
    let globex = crm.add_company("Globex".into(), None).unwrap();

    crm.add_contact(
        "Ada Lovelace".into(),
        email("ada@acme.test"),
        Some("555-0100".into()),
        Some(acme),
    )
    .unwrap();
    crm.add_contact(
        "Grace Hopper".into(),
        email("grace@acme.test"),
        None,
        Some(acme),
    )
    .unwrap();
    crm.add_contact(
        "Linus Torvalds".into(),
        email("linus@globex.test"),
        None,
        Some(globex),
    )
    .unwrap();

    let rollout = crm
        .add_deal(acme, "Acme rollout".into(), Money::from_cents(1_250_000))
        .unwrap();
    crm.move_deal(rollout, DealStage::Proposal).unwrap();
    crm.add_deal(globex, "Globex pilot".into(), Money::from_cents(400_000))
        .unwrap();

    let lead_id = crm
        .add_lead(
            "Margaret Hamilton".into(),
            email("margaret@apollo.test"),
            Some("Apollo".into()),
            LeadSource::Referral,
            None,
        )
        .unwrap();
    crm.qualify_lead(lead_id).unwrap();

    crm
}

// Ids in sample_crm, so tests don't use magic numbers.
pub const ACME: CompanyId = CompanyId(1);
pub const GLOBEX: CompanyId = CompanyId(2);
pub const ADA: ContactId = ContactId(1);
pub const ROLLOUT: DealId = DealId(1);
pub const PILOT: DealId = DealId(2);
pub const MARGARET: LeadId = LeadId(1);
```

If a signature differs slightly in your code (say, a method takes `&str` where this one passes a
`String`), adapt the call. Keep the *data* the same, because the Your Turn tasks below refer to it.

Notes on the design:

- **Built only through public methods** (`add_company`, `add_contact`, `move_deal`, …), never
  by pushing structs into repositories directly. Then the sample data is guaranteed to satisfy
  every business rule, exactly like real data.
- **`unwrap()` is fine in test helpers.** If the fixture can't be built, the test should fail
  loudly, and `expect("...")` says why.
- **Named constants** (`ACME`, `ROLLOUT`) instead of `CompanyId(1)` scattered through tests. When
  the fixture changes, you change one line.
- **A doc comment with a table** describing the data. Whoever reads a failing test needs to know
  what was in the CRM.

---

## Step 4 — Your first integration test

> 🟢 **FOLLOW ALONG**: create `tests/lead_conversion.rs`

```rust
mod common;

use common::{MARGARET, sample_crm};

#[test]
fn converting_a_qualified_lead_creates_company_and_contact() {
    let mut crm = sample_crm();

    let summary = crm.convert_lead(MARGARET, None).unwrap();

    let company = crm.companies.get(summary.company_id).unwrap();
    assert_eq!(company.name, "Apollo");
    let contact = crm.contacts.get(summary.contact_id).unwrap();
    assert_eq!(contact.email.as_str(), "margaret@apollo.test");
    assert_eq!(contact.company_id, Some(summary.company_id));
    assert_eq!(summary.deal_id, None);
}
```

The shape of a good test is **Arrange, Act, Assert**, separated by blank lines: build the
situation, do *one* thing, check the outcome. The name says what behaviour is being promised, as
a sentence: `converting_a_qualified_lead_creates_company_and_contact`. When it fails in CI six
months from now, the name alone should tell you what broke.

```bash
cargo test --test lead_conversion
```

```text
warning: constant `ACME` is never used
  --> tests/common/mod.rs:76:11
   |
76 | pub const ACME: CompanyId = CompanyId(1);
   |           ^^^^
...
warning: `rust-crm` (test "lead_conversion") generated 5 warnings
     Running tests/lead_conversion.rs (target/debug/deps/lead_conversion-9fdd1dd3f31096ed)

running 1 test
test converting_a_qualified_lead_creates_company_and_contact ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

The test passes, but look at the warnings. **Who owns `common`?** Every test crate that writes
`mod common;` compiles its *own copy* of the module, and each copy is checked for unused items
separately. `lead_conversion` doesn't use `ACME`, so in *that* crate it's dead code. With CI's
`-D warnings` (Step 8) those warnings become errors:

```text
error: constant `ACME` is never used
  --> tests/common/mod.rs:76:11
   |
   = note: `-D dead-code` implied by `-D warnings`
```

This is the one place where silencing the lint is the right call, because "unused in *this*
test file" is expected. Add at the very top of `tests/common/mod.rs`, after the `//!` comment:

```rust
// Every test crate compiles its own copy of this module and uses only some of
// it, so "never used" warnings here are noise, not bugs.
#![allow(dead_code)]
```

`#![...]` (with `!`) is an **inner attribute**: it applies to the module it's written in, here
the whole `common` module.

---

## Step 5 — Running exactly the tests you want

Run `cargo test` once and read the section headers:

```text
     Running unittests src/lib.rs (target/debug/deps/rust_crm-…)
     Running unittests src/main.rs (target/debug/deps/rust_crm-…)
     Running tests/lead_conversion.rs (target/debug/deps/lead_conversion-…)
   Doc-tests rust_crm
```

One binary per crate: the library's unit tests, the binary's unit tests, one per file in
`tests/`, and the doc tests. They run one after another, and the tests *inside* each binary run
in parallel on several threads.

The tools for running a subset:

| Command | Runs |
|---|---|
| `cargo test convert` | every test whose **name** (full path) contains `convert`, in **all** binaries |
| `cargo test --test lead_conversion` | only the binary built from `tests/lead_conversion.rs` |
| `cargo test --lib` | only the library's unit tests |
| `cargo test --doc` | only doc tests |
| `cargo test storage::` | unit tests in the `storage` module (the path is part of the name) |
| `cargo test -- --exact some_test_name` | one test, exact name match |
| `cargo test -- --nocapture` | show `println!` output from passing tests too |
| `cargo test -- --test-threads=1` | run tests one at a time (to debug a suspected interference) |
| `cargo test -- --ignored` | run only tests marked `#[ignore = "reason"]` |

Arguments **before** `--` go to cargo (which binaries to build and run). Arguments **after** `--`
go to the test harness inside each binary.

> 🟡 **EXPERIMENT**: predict, then run `cargo test conversion`. Which tests run? Is
> `converting_a_qualified_lead_creates_company_and_contact` among them? Now try `cargo test convert`.

```text
     Running unittests src/lib.rs (target/debug/deps/rust_crm-…)
test leads::conversion::tests::converts_a_qualified_lead_with_a_deal ... ok
test leads::conversion::tests::an_unqualified_lead_is_handed_back ... ok
test leads::conversion::tests::a_lead_without_company_becomes_an_individual ... ok
test crm::lead_tests::duplicate_email_blocks_conversion_and_keeps_the_lead ... ok
test crm::lead_tests::invalid_deal_blocks_conversion_and_keeps_the_lead ... ok
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 116 filtered out; …
…
     Running tests/lead_conversion.rs (target/debug/deps/lead_conversion-…)
running 0 tests
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out; …
```

The filter matches test *names*, and a unit test's name is its **full module path**:
`leads::conversion::tests::…` contains "conversion" because the *module* `leads/conversion.rs`
does. The file `tests/lead_conversion.rs` is a different matter: an integration test's name has no
file name in it, so `converting_a_qualified_lead_creates_company_and_contact` doesn't match.
`convert` matches it (and a few unit tests). To run one file, use `--test lead_conversion`.

> 🟡 **EXPERIMENT**: add `println!("company = {company:?}");` to the test, then run it with and
> without `-- --nocapture`. By default the harness *captures* output and only shows it for
> **failing** tests, so passing tests stay quiet. Remove the `println!` afterwards.

---

## Step 6 — Doc tests: examples that can't go stale

You've had doc tests for a while: the example on `Email::parse`, and the `compile_fail` examples
from Labs 13 and 19. Every ```` ``` ```` code block in a `///` comment on a public item is compiled
and run by `cargo test`, **as if it were a separate crate using your library**, exactly like an
integration test. (That's why the example starts with
`use rust_crm::...`.)

Why that matters: documentation examples are the first code people copy. An example that no longer
compiles is worse than none. Doc tests make stale examples a test failure.

Doc tests can do something no other test can: prove that code **doesn't** compile. You wrote
two of those in Lab 13's Your Turn.

> 🟢 **FOLLOW ALONG**: open `src/contacts/email.rs` and read the doc comment on the struct

```rust
/// An email address that has passed validation.
///
/// The field is private, so the only way to get an `Email` is through
/// [`Email::parse`]. If you hold an `Email`, it is valid: trimmed,
/// lowercase, with exactly one `@` and a dot in the domain.
///
/// Code outside the `customers` module cannot build one directly:
///
/// ```compile_fail
/// use rust_crm::contacts::Email;
///
/// let email = Email(String::from("definitely not an email"));
/// ```
///
/// ...and cannot reach inside one to change it:
///
/// ```compile_fail
/// use rust_crm::contacts::Email;
///
/// let mut email = Email::parse("ada@example.com").unwrap();
/// email.0.push_str(" oops");
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Email(String);
```

(Your wording may differ. The comment still says `customers`: Lab 14 renamed that module to
`contacts`. Stale prose is exactly what doc tests *can't* catch; only the code blocks are
checked. Fix the word while you're here.)

```bash
cargo test --doc
```

```text
test src/contacts/email.rs - contacts::email::Email::parse (line 36) ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test src/contacts/email.rs - contacts::email::Email (line 23) - compile fail ... ok
test src/leads/conversion.rs - leads::conversion::Lead::convert (line 66) - compile fail ... ok
test src/contacts/email.rs - contacts::email::Email (line 15) - compile fail ... ok
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.06s
```

A `compile_fail` test **passes because the code fails to compile**. If someone ever makes
`Email`'s field `pub`, this test fails, and the invariant from Labs 12–13 ("an `Email` is always
valid") is protected by the test suite instead of by memory. (A `compile_fail` test passes for
*any* compile error, typos included. Keep these examples tiny and check them by hand once.)

`[`Email::parse`]` in the comment is an **intra-doc link**: `cargo doc` turns it into a clickable
link and warns you if the target ever disappears.

---

## Step 7 — `#[should_panic]`, and why you'll rarely use it

`#[should_panic]` marks a test that passes only if the code panics. It's for code whose
**documented contract** is to panic, like indexing out of bounds or a function documented with
`# Panics`. Your CRM is designed **not** to panic on bad input. It returns `Result`. So most of
your "this should fail" tests are `matches!(result, Err(...))`, not `should_panic`.

> 🟡 **EXPERIMENT**: a tempting `should_panic` that's actually a trap. Create
> `tests/overflow.rs`:

```rust
use rust_crm::money::Money;

#[test]
#[should_panic(expected = "attempt to add with overflow")]
fn adding_past_i64_max_panics() {
    let _ = Money::from_cents(i64::MAX) + Money::from_cents(1);
}
```

```bash
cargo test --test overflow
cargo test --release --test overflow
```

```text
test adding_past_i64_max_panics - should panic ... ok
...
test adding_past_i64_max_panics - should panic ... FAILED
note: test did not panic as expected at tests/overflow.rs:5:4
```

(This assumes your Lab 18 `Add` impl is a plain `self.cents + rhs.cents`. If you used
`checked_add(...).expect(...)`, it panics in both profiles with your own message, and you've already
made the decision this experiment is about.)

In debug builds, integer overflow panics. In **release** builds it silently wraps around (to a
hugely negative amount of money!). The test documented behaviour that only exists in one build
profile. The real lesson is about `Money`, not about tests: if overflow matters (for money it
does), make it explicit with `checked_add` and a `Result`, or decide to `panic!` deliberately with
a message. Then a test can pin down *that* behaviour. Delete `tests/overflow.rs`. You'll revisit
`Money`'s arithmetic in Challenge B or later if you choose to.

`expected = "..."` checks that the panic message *contains* that text. Without it, any panic, even
an unrelated `unwrap()` on `None`, would make the test pass.

---

## Step 8 — Continuous Integration with GitHub Actions

Tests only protect you if they run. **CI** runs them on a fresh machine for every push and pull
request, so "works on my machine" and "I forgot to run clippy" stop being possible.

> 🟢 **FOLLOW ALONG**: create `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

env:
  CARGO_TERM_COLOR: always

jobs:
  check:
    name: fmt, clippy, test
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v7

      - name: Install Rust (stable)
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - name: Cache cargo registry and target/
        uses: Swatinem/rust-cache@v2

      - name: Formatting
        run: cargo fmt --all --check

      - name: Clippy
        run: cargo clippy --all-targets -- -D warnings

      - name: Tests
        run: cargo test
```

What each part does:

- **`on`**: run for every push to `main` and every pull request. (If your default branch is
  called `master`, change it.)
- **`runs-on: ubuntu-latest`**: a fresh Linux virtual machine every time. Nothing from your
  laptop exists there: no `crm-data.json`, no `CRM_DATA_FILE`, no cached `target/`. That's the
  point. It catches anything your tests depend on by accident.
- **`actions/checkout`**: clones your repo into the VM.
- **`dtolnay/rust-toolchain@stable`**: installs the current stable Rust, plus `rustfmt` and
  `clippy`. (The `@stable` is the *toolchain*, chosen by the action's version tag.)
- **`Swatinem/rust-cache`**: saves `~/.cargo` and `target/` between runs, keyed on `Cargo.lock`.
  The first run compiles every dependency (slow); later runs reuse them.
- **`cargo fmt --all --check`**: fails if any file isn't formatted. It never changes files in CI.
- **`cargo clippy --all-targets -- -D warnings`**: `--all-targets` lints tests, examples and the
  binary too (otherwise `tests/` isn't linted). `-D warnings` turns every warning into an error.
  Warnings that are allowed to pile up get ignored. In CI, the rule is zero.
- **`cargo test`**: everything, including doc tests.

Steps run in order and stop at the first failure. The cheap checks go first, so you hear about
formatting in seconds, not after a full test run.

> Action versions (`@v7`, `@v2`) move over time. If GitHub warns that one is deprecated, check its
> README for the current major version.

### Run the same checks locally first

```bash
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test
```

Fix anything it reports **before** pushing. Code from earlier labs that you never ran Clippy on
with `--all-targets -D warnings` may produce a few findings. Read each one: Clippy explains why,
and links to the lint's documentation. If one is a deliberate design decision, allow it **on that
one item** with a reason, never crate-wide. You've seen the pattern in Lab 19: `Lead::convert`
carries `#[expect(clippy::result_large_err, reason = "ConvertError carries the whole Lead back to
the caller on purpose")]`.

### A README with a badge

Your repository doesn't have a README yet. Create `README.md` in the **root of your `rust-crm`
repo** (not in this course repo):

```markdown
# Rust CRM

[![CI](https://github.com/YOUR-USERNAME/rust-crm/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR-USERNAME/rust-crm/actions/workflows/ci.yml)

A terminal CRM (companies, contacts, deals, leads, activities and notes), built while learning Rust.

## Run

    cargo run                              # data in ./crm-data.json
    cargo run -- --storage memory          # nothing is saved
    CRM_DATA_FILE=demo.json cargo run      # another data file
    cargo run -- --help

## Test

    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
    cargo test
```

Replace `YOUR-USERNAME`. The badge URL is
`https://github.com/<user>/<repo>/actions/workflows/<workflow file>/badge.svg`, and it shows the
status of the latest run on the default branch.

---

## ▶️ Run It

After finishing the Your Turn tasks below:

```bash
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test
git push
```

Then open your repo on GitHub → **Actions** tab and watch the run.

## ✅ Expected Result

Locally, `cargo test` shows one section per binary (your unit-test counts depend on how many unit
tests you wrote in earlier labs):

```text
     Running unittests src/lib.rs (target/debug/deps/rust_crm-…)
test result: ok. 121 passed; 0 failed; …
     Running unittests src/main.rs (target/debug/deps/rust_crm-…)
test result: ok. 6 passed; 0 failed; …
     Running tests/lead_conversion.rs (target/debug/deps/lead_conversion-…)
test result: ok. 5 passed; 0 failed; …
     Running tests/persistence.rs (target/debug/deps/persistence-…)
test result: ok. 7 passed; 0 failed; …
     Running tests/pipeline.rs (target/debug/deps/pipeline-…)
test result: ok. 5 passed; 0 failed; …
     Running tests/validation.rs (target/debug/deps/validation-…)
test result: ok. 8 passed; 0 failed; …
   Doc-tests rust_crm
test result: ok. 3 passed; 0 failed; …
test result: ok. 3 passed; 0 failed; …
```

On GitHub: a green ✅ next to your commit, a passing **CI / fmt, clippy, test** job, and a green
"CI passing" badge on your repository's front page.

## 🧠 Understand It

**Integration tests test behaviour; unit tests test parts.** `tests/` files are separate crates
that see only your public API, so they keep passing through internal rewrites and fail only when
*behaviour* changes. That's the safety net for Labs 25–31.

**Your public API is what's testable from outside.** Lab 13 (privacy) and Lab 14 (business logic
in `Crm`, not in the CLI) are why the CRM is testable without a terminal. Code that only exists
inside `cli/commands.rs` can't be integration-tested. That's one more reason to keep the CLI thin.

**`tests/common/mod.rs` is a module, not a test crate.** Each test crate compiles its own copy,
which is why `dead_code` must be allowed there.

**RAII makes test clean-up reliable.** `TempDir` deletes its directory in `Drop`, which runs even
when a test panics.

**Doc tests are integration tests in your documentation.** They use the public API, and
`compile_fail` can pin down what must *not* compile.

**A test double proves the abstraction.** Your persistence tests (Your Turn 3) run one contract
against `JsonFileStorage` and against a `RecordingStorage` defined *outside* the crate. If a type
your library has never seen can plug in, the `Storage` boundary really is a boundary.

**CI turns your local checklist into a rule.** Formatting, Clippy with `-D warnings`, and all tests
run on a clean machine for every push.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: watch CI fail.** On a branch, break the formatting (indent a line badly),
> commit and push, and open a pull request. Which step fails? How long did it take compared to a
> full test run? Fix it with `cargo fmt` and push again.

> 🟡 **EXPERIMENT 2: break behaviour, not code.** In `DealStage::can_transition_to`, allow
> `Won → Negotiation`. Run `cargo test`. Which tests fail: unit, integration or both? Read the
> failure output. Does the test name tell you what broke? Revert.

> 🟡 **EXPERIMENT 3: the temp-dir trap.** In a persistence test, write
> `let path = tempfile::tempdir().unwrap().path().join("crm.json");` and use `path`. What
> happens, and why? (Who owns the `TempDir`, and when is it dropped?)

## 👩🏽‍💻 Your Turn

You'll write most of the suite yourself. Each task gives the **test names** and the **behaviour**
each must check. Use `sample_crm()` and the constants from `common`. Every test follows
Arrange / Act / Assert. Errors are checked with `matches!`, not `assert_eq!`.

> 🔵 **YOUR TURN 1: `tests/lead_conversion.rs`.** Add four tests next to the one from Step 4:
>
> - [ ] `converting_with_a_deal_creates_the_deal_in_qualification`: converting Margaret with
>   `Some(("Apollo guidance".to_string(), Money::from_cents(990_000)))` returns a `deal_id`. That
>   deal belongs to the new company, is in `DealStage::Qualification`, and has the given value.
> - [ ] `converted_lead_is_removed_from_leads`: afterwards `crm.leads.get(MARGARET)` is `None`.
> - [ ] `unqualified_lead_cannot_be_converted_and_stays`: a **new** (not qualified) lead fails with
>   `CrmError::LeadNotQualified` carrying its id. The lead is **still** in `crm.leads` (Lab 19's
>   "hand the lead back" rule), and no company was created.
> - [ ] `lead_without_company_name_becomes_individual_company`: a qualified lead named
>   "Katherine Johnson" with no company name produces a company named
>   `"Katherine Johnson (individual)"`.
> - [ ] the last two need a lead that isn't in `sample_crm`: write a small helper **in this file**
>   (on top of `Crm::add_lead`),
>   `fn add_new_lead(crm: &mut Crm, name: &str, email: &str, company: Option<&str>) -> LeadId`

> 🔵 **YOUR TURN 2: `tests/pipeline.rs`**
>
> - [ ] `pipeline_lists_every_stage_in_order`: the report's stages are exactly Qualification,
>   Proposal, Negotiation, Won, Lost, in that order, even though only two stages have deals
> - [ ] `pipeline_counts_and_sums_deals_per_stage`: Qualification has 1 deal worth $4,000.00,
>   Proposal 1 deal worth $12,500.00, Won 0 deals worth $0.00
> - [ ] `moving_a_deal_moves_its_value_between_stages`: after moving `ROLLOUT` to Won, Proposal
>   has 0 deals and Won totals $12,500.00
> - [ ] `total_pipeline_value_is_unchanged_by_moves`: the sum of all rows' totals is the same
>   before and after moving `PILOT` to Lost (use `Money`'s `Sum` impl from Lab 18)
> - [ ] `closed_deals_cannot_move`: after Won, moving to Negotiation fails with
>   `CrmError::InvalidTransition { from: Won, to: Negotiation }`
> - [ ] a private helper `fn row(report: &[PipelineRow], stage: DealStage) -> &PipelineRow` keeps
>   the assertions short (think about the lifetime elision here: why does it compile without `'a`?)

> 🔵 **YOUR TURN 3: `tests/persistence.rs`: round trips and a storage contract**
>
> - [ ] helper `fn json_storage() -> (TempDir, JsonFileStorage)`, a storage pointing at
>   `crm.json` inside a fresh temp dir. Return the `TempDir` too, so the caller keeps it alive.
> - [ ] helper `fn same_data(a: &Crm, b: &Crm) -> bool`. `Crm` has no `PartialEq`, but two CRMs
>   that serialize to the same `serde_json::Value` hold the same data.
> - [ ] `missing_file_loads_an_empty_crm`
> - [ ] `json_round_trip_preserves_everything`: save `sample_crm()`, load, `same_data`
> - [ ] `ids_continue_after_reload`: after a reload, `add_company` returns `CompanyId(3)`, and
>   `contacts_of(ACME)` still has 2 contacts
> - [ ] `corrupt_file_is_a_parse_error`: write `"{ this is not json"` to `storage.path()` →
>   `Err(StorageError::Parse { .. })`
> - [ ] `save_leaves_only_the_data_file`: after a save, the temp dir contains exactly `crm.json`
>   (no `.tmp` left behind)
> - [ ] **the test double**: in this file, define `struct RecordingStorage` that implements
>   `rust_crm::storage::Storage` by keeping the last saved CRM as a JSON `String` in a
>   `RefCell<Option<String>>`. (`save` takes `&self`, so you need interior mutability: Lab 14's
>   `RefCell`.)
> - [ ] **the contract**: `fn check_storage_contract(storage: &dyn Storage)` asserts what every
>   *persistent* storage must do: a new one loads empty; load returns what was saved; the latest
>   save wins
> - [ ] `json_file_storage_fulfils_the_contract` and `recording_storage_fulfils_the_contract`
> - [ ] Question to answer in a comment: why is `InMemoryStorage` **not** run through this contract?

> 🔵 **YOUR TURN 4: `tests/validation.rs`: table-driven tests**
>
> - [ ] `valid_emails_are_normalised`: a table (array of `(input, expected)` tuples) with at
>   least 3 cases, including surrounding spaces and upper case. Loop over it; the assertion message
>   names the failing input.
> - [ ] `invalid_emails_are_rejected`: at least 6 bad inputs (empty, no `@`, nothing before `@`,
>   no dot in domain, whitespace inside, two `@`), each `Err(ValidationError::InvalidEmail(_))`
> - [ ] `money_parses_whole_and_fractional_amounts`: `"1250"`, `"1250.5"`, `"1250.50"`, `"0.07"`
>   and the formatted form `"$1,250.50"` your Lab 18 parser accepts
> - [ ] `money_rejects_malformed_amounts`: at least `""`, `"abc"`, `"12.345"`, `"12."`, `"1.2.3"`
> - [ ] `duplicate_contact_email_is_rejected`: `ada@acme.test` again → `DuplicateEmail`
> - [ ] `contact_for_a_missing_company_is_rejected` → `NotFound { entity: "company", id: 99 }`
> - [ ] `company_with_contacts_cannot_be_deleted` → `HasContacts(ACME)`, and Acme still exists
> - [ ] `deal_with_empty_title_is_rejected` → `CrmError::Validation(ValidationError::EmptyTitle)`

> 🔵 **YOUR TURN 5: doc tests for `Money`**
>
> - [ ] on the `Money` struct: an example showing `Display` (`$1,250.50`) and addition
> - [ ] on `Money::parse`: examples for a fractional amount, a whole amount, and one rejected input
> - [ ] on `Email::parse`: check that the example also shows an invalid input being rejected
>   (Lab 13's version already does; add the line if yours doesn't)
> - [ ] `cargo test --doc` shows all of them (plus the `compile_fail` tests from Step 6) passing

Then commit the tests (first commit below), add the workflow and README, run the local CI command,
commit and push (second commit).

## 💡 Hint

> 💡 **HINT** (Your Turn 1): `matches!(result, Err(CrmError::LeadNotQualified(lead)) if lead == id)`
> binds the id inside the pattern and compares it in the guard. `LeadId` is `Copy`, so binding it
> by value is fine.

> 💡 **HINT** (Your Turn 3): reading back a `RefCell<Option<String>>` without cloning:
> `match &*self.snapshot.borrow() { Some(json) => ..., None => ... }`. Writing:
> `*self.snapshot.borrow_mut() = Some(json);`.

<details><summary>Hint 2 (more specific)</summary>

- `serde_json::to_value(&crm)` returns a `serde_json::Value`, which implements `PartialEq`.
  Integration tests may use any of your package's normal dependencies, so `serde_json` is available.
- `RecordingStorage::load` returns `Result<Crm, StorageError>`, but `StorageError` has no variant
  for "my in-memory JSON was bad". Since the test double wrote that JSON itself, `expect(...)` is
  honest there.
- `fs::read_dir(dir.path())` yields `io::Result<DirEntry>`. `entry.file_name()` is an `OsString`;
  `.to_string_lossy().into_owned()` makes it a `String` you can compare.
- Lifetime in `row`: one reference input (`report`) and one reference output. Lab 10's elision
  rule ties them together. (`stage` is `Copy`, not a reference.)
- For table-driven tests, `unwrap_or_else(|e| panic!("{input:?} should be valid: {e}"))` gives a
  far better failure message than `unwrap()`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why can't `tests/lead_conversion.rs` call `cli::parser::parse_command`? Where do its tests
   belong instead?
2. How many test binaries does `cargo test` build for your project now? Name them.
3. Why is the helpers file `tests/common/mod.rs` and not `tests/common.rs`? Why does it need
   `#![allow(dead_code)]`?
4. What happens to a `TempDir` when an assertion fails halfway through a test? Why?
5. `cargo test conversion` ran zero tests. Why? How do you run one test file?
6. When is `#[should_panic]` the right tool, and why was the overflow test misleading?
7. What does `compile_fail` prove about `Email`, and what's its weakness?
8. List the CI steps in order and say why the cheap ones go first.
9. Which earlier lab decisions made these integration tests possible?

Then verify: `cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit

Two commits, so the history separates "tests" from "automation":

```bash
git add tests Cargo.toml Cargo.lock src
git commit -m "Add integration tests"

git add .github README.md
git commit -m "Add CI workflow"
git tag lab-24
git push && git push --tags
```

Check the **Actions** tab: the push to `main` started a run. (Pushing the tag doesn't start
another one: the workflow's `branches: [main]` filter only matches branch pushes.) From now on,
every lab ends with a green check, or you know about it immediately.

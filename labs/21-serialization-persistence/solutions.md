# Lab 21 — Solutions

> 🔴 **SOLUTION**: make a genuine attempt first. These are *one* good answer each, with the
> reasoning. Your variant names may differ from mine (for example if your `Command` enum is
> shaped a little differently). What matters is the idea.

---

## Quick check (Step 5): can a derived `Deserialize` bypass an invariant on `Money`?

No, not today. `Money { cents: i64 }` accepts **every** `i64` through `Money::from_cents`, so
there's no rule a deserialized value could break. The derive builds exactly what `from_cents`
would. The rule "a deal's value isn't negative" lives on `Deal::validate`, not on `Money`, so it's
a cross-field rule that serde never checks (see "Understand It").

If you ever decided that `Money` itself must be non-negative, you'd do what we did for `Email`:
`#[serde(try_from = "i64", into = "i64")]` plus `TryFrom<i64> for Money`. The test is simple:
**if a type has a constructor that can fail, its `Deserialize` must go through that constructor.**

---

## 🔵 Your Turn 1: `Command::is_mutating`

```rust
impl Command<'_> {
    /// Does running this command change the CRM (and therefore need a save)?
    pub(crate) fn is_mutating(&self) -> bool {
        match self {
            Command::Help
            | Command::Version
            | Command::Quit
            | Command::Stats
            | Command::Pipeline
            | Command::History { .. } => false,
            Command::LogActivity { .. } | Command::AddNote { .. } => true,
            Command::Company(c) => match c {
                CompanyCommand::List { .. } | CompanyCommand::Show { .. } => false,
                CompanyCommand::Add
                | CompanyCommand::Stage { .. }
                | CompanyCommand::Delete { .. } => true,
            },
            Command::Contact(c) => match c {
                ContactCommand::List { .. }
                | ContactCommand::Show { .. }
                | ContactCommand::Search { .. } => false,
                ContactCommand::Add
                | ContactCommand::Update { .. }
                | ContactCommand::Delete { .. } => true,
            },
            Command::Deal(c) => match c {
                DealCommand::List | DealCommand::Show { .. } => false,
                DealCommand::Add | DealCommand::Move { .. } => true,
            },
            Command::Lead(c) => match c {
                LeadCommand::List => false,
                LeadCommand::Add
                | LeadCommand::Qualify { .. }
                | LeadCommand::Disqualify { .. }
                | LeadCommand::Convert { .. } => true,
            },
        }
    }
}
```

And in the parser's test module:

```rust
#[test]
fn only_commands_that_change_data_are_mutating() {
    let mutating = |input| parse_command(input).unwrap().unwrap().is_mutating();
    assert!(!mutating("contact list"));
    assert!(!mutating("history deal:1"));
    assert!(mutating("deal move 1 won"));
    assert!(mutating("note add company:1 called them"));
}
```

**Why it's written this way**

- **`&self`.** We only need to *look* at the command. The REPL still has to move it into
  `execute` afterwards.
- **Every variant is named.** `matches!(c, DealCommand::Add | DealCommand::Move { .. })` would be
  shorter, but `matches!` hides a `_ => false`. Add a `deal delete` command in a later lab and the
  compiler would say nothing, and `deal delete` would silently never save. With an explicit
  `match`, adding a variant makes this function fail to compile (E0004, non-exhaustive patterns)
  until you decide. That's Lab 11's exhaustiveness used as a safety net.
- **The asymmetry.** A wrong `true` costs one unnecessary save. A wrong `false` loses data when
  the user quits. When in doubt, mutating.
- `|input| ...` is a closure used as a tiny local helper to keep the test readable.

*Alternative:* return the info from `execute` instead (`Result<Outcome, CrmError>` where
`Outcome::Changed | Outcome::Unchanged`). That's more precise (a `contact update` where the user
keeps every field unchanged wouldn't save) but spreads the bookkeeping across every command arm.
For a snapshot that takes milliseconds to write, the simple classification wins.

---

## 🔵 Your Turn 2: storage tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::companies::CompanyId;
    use crate::contacts::Email;
    use crate::money::Money;

    /// A path in the OS temp dir that no other test (or test run) uses.
    fn temp_file(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("rust-crm-{}-{name}.json", std::process::id()))
    }

    #[test]
    fn load_missing_file_gives_empty_crm() {
        let crm = load(&temp_file("does-not-exist")).unwrap();
        assert!(crm.companies.is_empty());
        assert!(crm.contacts.is_empty());
    }

    #[test]
    fn save_then_load_round_trips() {
        let path = temp_file("round-trip");
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".into(), None).unwrap();
        let email = Email::parse("ada@acme.test").unwrap();
        crm.add_contact("Ada".into(), email, None, Some(acme))
            .unwrap();
        crm.add_deal(acme, "Big deal".into(), Money::from_cents(500_000))
            .unwrap();

        save(&crm, &path).unwrap();
        let mut loaded = load(&path).unwrap();
        fs::remove_file(&path).unwrap();

        assert_eq!(loaded.companies.len(), 1);
        assert_eq!(loaded.contacts.all()[0].email.as_str(), "ada@acme.test");
        assert_eq!(loaded.deals.all()[0].value, Money::from_cents(500_000));
        // next_id survived the trip, so ids keep counting up instead of restarting at 1.
        let next = loaded.add_company("Globex".into(), None).unwrap();
        assert_eq!(next, CompanyId(2));
    }

    #[test]
    fn save_leaves_no_tmp_file_behind() {
        let path = temp_file("no-tmp");
        save(&Crm::new(), &path).unwrap();
        assert!(path.exists());
        assert!(!tmp_path(&path).exists());
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn load_rejects_an_invalid_email() {
        let path = temp_file("bad-email");
        let json = r#"{ "contacts": { "items": [ { "id": 1, "name": "Ada", "email": "nope",
                        "phone": null, "company_id": null } ], "next_id": 2 } }"#;
        fs::write(&path, json).unwrap();
        let result = load(&path);
        fs::remove_file(&path).unwrap();
        assert!(matches!(result, Err(CrmError::Json(_))));
    }
}
```

**Reasoning**

- **Why `use super::*`?** The test module is a child of `storage`, so it can use `load`, `save`
  and even the private `tmp_path`. Unit tests (inside `src/`) can test private details.
  Integration tests in `tests/` (Lab 24) can't, and that's on purpose.
- **Why unique file names?** `cargo test` runs tests on several threads at once. Two tests writing
  `/tmp/test.json` would overwrite each other's file and fail *sometimes*: the worst kind of
  failure. The test name makes paths unique within a run, and the process id makes them unique
  across runs.
- **Clean up before asserting.** `assert!` panics on failure, and a panic skips the rest of the
  function, so the cleanup line would never run. (Lab 24's `tempfile` solves this properly: its
  directory is deleted in `Drop`, which runs even during a panic.)
- **Testing `next_id`.** This is the bug a "save only the items" design would have. Asserting
  `CompanyId(2)` is a precise, cheap guard against it. `CompanyId` derives `PartialEq` + `Debug`,
  so `assert_eq!` works.
- **`matches!(result, Err(CrmError::Json(_)))`**. We can't `assert_eq!` against a
  `serde_json::Error`, and we don't care about its exact text, only that loading failed *as a
  data problem* rather than an I/O problem.
- With **missing sections** the invalid-email file would also fail before Your Turn 3 (with
  "missing field"). That's why this test must still pass *after* Your Turn 3: then it proves the
  failure really comes from the email.

---

## 🔵 Your Turn 3: loading older files

The test:

```rust
#[test]
fn load_accepts_a_file_without_newer_sections() {
    let path = temp_file("old-format");
    fs::write(&path, r#"{ "companies": { "items": [], "next_id": 1 } }"#).unwrap();
    let result = load(&path);
    fs::remove_file(&path).unwrap();
    assert!(result.unwrap().leads.is_empty());
}
```

Before the fix it fails with:

```text
called `Result::unwrap()` on an `Err` value: Json(Error("missing field `contacts`", line: 1, column: 46))
```

The fix, in `src/crm.rs`:

```rust
/// The whole CRM: every repository plus the business operations that span them.
///
/// `#[serde(default)]`: a section missing from the file (e.g. a file saved before
/// activities existed) becomes an empty repository, which is exactly the truth:
/// that file had no activities.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Crm {
```

**Why this works:** as a *container* attribute, `#[serde(default)]` means "for any field missing
from the input, take that field's value from `Crm::default()`". `Crm::default()` is all empty
repositories with `next_id: 1`, which is correct for a section that didn't exist.

**Why it's safe:** it only fills in **absent** fields. A **present but invalid** field (the bad
email) still fails. That's why `load_rejects_an_invalid_email` keeps passing.

**What it's not:** a migration system. If you *rename* a field, `default` would silently give you
an empty value and the old data would be ignored. For renames, serde has `#[serde(alias = "old_name")]`.
For bigger changes you'd add a `"version": 2` field and convert explicitly. In Lab 30 the database
gets real migrations.

---

## 🧪 Experiment answers

**Experiment 1: who wrote which part of the message?**
`Error: could not load crm-data.json: ` is your REPL. `data file is not valid: ` is your `Display`
for `CrmError::Json`. `invalid email address 'ada at acme'` is your `ValidationError`, which serde
took from the `TryFrom<String>` error via `Display`. `at line 18 column 31` is serde_json adding
the position. Four layers, one line. Lab 22 makes this layering explicit.

**Experiment 2: why can't the atomic save produce a torn file?** `crm-data.json` is never opened
for writing. Its content changes only by `rename`, and rename swaps a complete file in one step.
A crash leaves at worst a torn `crm-data.json.tmp`, which `load` never reads and the next `save`
overwrites (`File::create` truncates it).

**Experiment 3: adding `FollowUp` later.**
- Old file, new program: ✅ loads. Every variant in the old file still exists.
- New file (containing a `"follow_up"`), old program: ❌ `unknown variant`. This is *forward*
  compatibility, and serde won't give it to you for free. (`#[serde(other)]` on a unit variant can
  catch unknown tags, but only for unit variants.) That's a normal limit: old software can't
  understand new data. Just know which direction you're promising.

**`Subject` with `tag = "type"`: why not a compile error?** The derive only sees the enum
definition. Whether "newtype variant holding X" works depends on whether X serializes as a map,
which depends on X's `Serialize` impl, which could be anywhere and could even differ per format.
serde chose to check it when the value is serialized. It's one of the few places serde trades
compile-time safety for flexibility.

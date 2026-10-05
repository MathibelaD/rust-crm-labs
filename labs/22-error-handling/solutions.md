# Lab 22 — Solutions

> 🔴 **SOLUTION**: make a genuine attempt first. Your messages and some variant names will
> differ. What matters is *which layer* each error lives in, and why.

---

## 🔵 Your Turn 1: keep CLI errors out of the domain, and prove it

### The CLI's unit tests

In `src/cli/parser.rs`'s test module, import both domain types and move each expected error to the
right layer:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::{CrmError, ValidationError};

    // ...
    #[test]
    fn company_list_bad_stage_is_a_validation_error() {
        assert!(matches!(
            parse_command("company list --stage won"),
            Err(CliError::Domain(CrmError::Validation(
                ValidationError::InvalidLifecycle(_)
            )))
        ));
        assert!(matches!(
            parse_command("company list --stage"),
            Err(CliError::Usage(_))
        ));
    }
    // ... every other `CrmError::Usage(_)` becomes `CliError::Usage(_)`,
    // `CrmError::UnknownCommand(name)` becomes `CliError::UnknownCommand(name)`, and
    // `Err(CrmError::Validation(_))` becomes `Err(CliError::Domain(CrmError::Validation(_)))`.
}
```

And in `src/cli/commands.rs`'s `unknown_ids_are_not_found`:

```rust
            assert!(matches!(
                execute(&mut crm, command),
                Err(CliError::Domain(CrmError::NotFound { id: 42, .. }))
            ));
```

### `Subject`: already a domain error

Lab 20 wrote `Subject`'s `FromStr` with `type Err = ValidationError;` and a small closure that
builds `ValidationError::InvalidValue { field: "subject (expected e.g. …)", value }`. So `grep`
finds nothing outside `src/cli/`, and `history deal:x` prints the domain's message:

```text
crm> history deal:x
Error: invalid subject (expected e.g. company:3, contact:5 or deal:2): 'deal:x'
```

The test, in `src/subject.rs`'s existing test module:

```rust
    #[test]
    fn malformed_subject_is_a_validation_error() {
        assert_eq!(
            "deal:x".parse::<Subject>(),
            Err(ValidationError::InvalidValue {
                field: "subject (expected e.g. company:3, contact:5 or deal:2)",
                value: "deal:x".to_string(),
            })
        );
    }
```

**Reasoning**

- **Why `ValidationError`?** "This text isn't a valid subject" is the same *kind* of problem as
  "this text isn't a valid email": input that doesn't satisfy a type's rules. In Lab 28 that maps
  to HTTP 422 along with the other validation errors, so a bad subject in an HTTP request gets a
  sensible response for free.
- **Why `assert_eq!` works here but not for `CrmError`:** `ValidationError` only contains
  `String`s and `&'static str`s, so it derives `PartialEq`. `CrmError` *could* derive it again
  right now, but we chose not to (Step 4's experiment).
- **The nested patterns** in the parser tests are the layering made visible: a typing mistake is
  `CliError::Usage`, a broken business rule is `CliError::Domain(CrmError::…)`. A test that only
  checked `is_err()` couldn't tell them apart.
- **`InvalidValue` vs a dedicated `InvalidSubject(String)` variant:** the generic variant keeps
  `ValidationError` small; a dedicated one could carry a more specific message. Both are fine, so
  there's no reason to change working code here.

**If your domain *did* use `Usage`:** give the domain its own variant named after the **rule**, the
way Lab 19 already did with `LeadDisqualified`:

```rust
// a rule, not a typing mistake: it gets its own variant
#[error("lead {0} has been disqualified")]
LeadDisqualified(LeadId),
```

"A disqualified lead can't be qualified" is a **business rule**: Lab 31 enforces the same rule
against Postgres, and Lab 28 turns it into a 409 Conflict. A `Usage` message in domain code is a
rule smuggled out through the wrong door. The test for "is this a domain error?" is: *would it
still make sense if the request came over HTTP?*

---

## 🔵 Your Turn 2: `error_chain`

```rust
/// Formats an error and all of its causes on one line:
/// `outer message: cause: root cause`.
pub fn error_chain(err: &dyn std::error::Error) -> String {
    let mut message = err.to_string();
    let mut current = err.source();
    while let Some(cause) = current {
        message.push_str(": ");
        message.push_str(&cause.to_string());
        current = cause.source();
    }
    message
}

// Added to the existing `mod tests` from Lab 12:
#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::StorageError;

    // ... validation_errors_convert_into_crm_errors from Lab 12 ...

    #[test]
    fn error_chain_of_an_error_without_cause_is_its_message() {
        assert_eq!(
            error_chain(&ValidationError::EmptyName),
            "name cannot be empty"
        );
    }

    #[test]
    fn error_chain_includes_the_io_cause() {
        let err = StorageError::Write {
            path: "data.json".into(),
            source: std::io::Error::other("disk full"),
        };
        assert_eq!(error_chain(&err), "could not write data.json: disk full");
    }

    #[test]
    fn transparent_validation_error_is_not_repeated() {
        let err = CrmError::from(ValidationError::EmptyName);
        assert_eq!(error_chain(&err), "name cannot be empty");
    }
}
```

**Reasoning**

- **`&dyn std::error::Error`** accepts a reference to *any* error type: `&CliError`,
  `&StorageError`, `&io::Error`. One function, no generics. Each call site's `&e` is coerced to
  a trait object automatically.
- **The loop** is a linked-list walk. `current` has type `Option<&(dyn Error + 'static)>`. Each
  iteration borrows the next link from the previous one. Nothing is cloned or moved; we only read
  messages.
- **`to_string()`** comes from `Display` (every `Error` is `Display`). `push_str` appends in place
  to one `String` instead of creating a new string per link with `format!`.
- **The `transparent` test** is the important one: if `Validation` were `#[error("validation
  failed")]`, the chain would be `"validation failed: name cannot be empty"`. If it were
  `#[error("invalid: {0}")]` *and* `#[from]`, it would be
  `"invalid: name cannot be empty: name cannot be empty"`. This test pins down the design.
- `"data.json".into()` turns a `&str` into a `PathBuf` (there's a `From<&str> for PathBuf`).

*Alternative:* `anyhow::Error` already does this with `{:#}`. You could write
`println!("Error: {:#}", anyhow::Error::from(e))`. That's fine, but it would make the library's
`errors` module depend on how anyhow formats. Writing the loop once is short, and you now know
exactly what anyhow does internally.

---

## 🔵 Your Turn 3: test the storage errors

Inside the existing `mod tests` of `src/storage.rs` (it already has the `temp_file` helper):

```rust
#[test]
fn parse_error_names_the_file_and_keeps_the_cause() {
    let path = temp_file("parse-error");
    fs::write(&path, r#"{ "contacts": { "items": [ { "id": 1, "name": "Ada", "email": "nope", "phone": null, "company_id": null } ], "next_id": 2 } }"#).unwrap();
    let err = load(&path).unwrap_err();
    fs::remove_file(&path).unwrap();

    assert!(err.to_string().contains(&*path.to_string_lossy()));
    let cause = std::error::Error::source(&err).expect("a parse error has a cause");
    let json_error = cause
        .downcast_ref::<serde_json::Error>()
        .expect("the cause is a serde_json::Error");
    assert_eq!(json_error.line(), 1);
}

#[test]
fn error_chain_joins_every_cause() {
    let path = temp_file("chain");
    fs::write(&path, r#"{ "contacts": { "items": [ { "id": 1, "name": "Ada", "email": "nope", "phone": null, "company_id": null } ], "next_id": 2 } }"#).unwrap();
    let err = load(&path).unwrap_err();
    fs::remove_file(&path).unwrap();

    let chain = crate::errors::error_chain(&err);
    assert!(chain.starts_with(&format!(
        "{} does not contain valid CRM data: ",
        path.display()
    )));
    assert!(chain.contains("'nope' is not a valid email address"));
}
```

**Reasoning**

- **`unwrap_err()`** is the mirror of `unwrap()`: it panics if the result is `Ok`. It needs the
  `Ok` type to be `Debug` (to print it in the panic message), which `Crm` is.
- **`downcast_ref`** is how you get a concrete type back from a `dyn Error`. `source()` erased the
  type ("some error"); `downcast_ref::<serde_json::Error>()` asks "is it actually this type?" and
  returns `Option<&serde_json::Error>`. It works by comparing type ids at runtime, which is why
  `source()` returns `dyn Error + 'static`: only `'static` types have a type id.
- **Why `std::error::Error::source(&err)`** instead of `err.source()`? Without
  `use std::error::Error;` the method isn't in scope. Calling it through the trait path avoids an
  import that's only needed by one test.
- **Testing `line()`** checks that the cause is the real serde_json error with its position, not a
  re-created string. If someone "simplifies" `Parse` to `Parse { path, message: String }`, this test
  fails, and that's the point: callers lose the structured cause.
- We don't assert the **exact** chain string: serde_json's wording ("at line 1 column 73") is not
  ours to pin down. `starts_with` + `contains` checks our parts precisely and theirs loosely.

---

## 🧪 Experiment answers

**Experiment 1 (`eprintln!("{e:#}")` + `exit(2)`).** Output becomes one line:
`refusing to start, so the data file is not overwritten: crm-data.json does not contain valid CRM data: 'ada at acme' is not a valid email address at line 18 column 31`,
and `echo $?` prints `2`. Different exit codes let a calling script tell failure *kinds* apart
(e.g. `2` = "bad data, a human must fix it" vs `1` = generic). Note `process::exit` skips
destructors of everything still alive. That's OK at the very end of `main`, but never call it
deep inside your program.

**Experiment 2 (`{e}` for save errors).** You get `Error: could not write crm-data.json`, and the
*reason* (permission denied? disk full?) is gone. The user can't fix what they can't see.

**Experiment 3 (`RUST_BACKTRACE=1`).** anyhow captures a backtrace when an `anyhow::Error` is
first created (here, in `.context(...)` inside `cli::run`), so you'll find `rust_crm::cli::run`
in it, but not `storage::load`: the `StorageError` itself was created as a plain enum, without a
backtrace. Backtraces show *where in the code* something failed. That's valuable for bugs and
useless for "your file is corrupt". It also costs time to capture, which is why it's opt-in.

**Step 4 experiment: re-deriving `PartialEq` on `CrmError`.** It compiles, because every field is
comparable again. We don't keep it: Lab 30 adds `Database(sqlx::Error)`, and tests written with
`matches!` don't depend on it anyway.

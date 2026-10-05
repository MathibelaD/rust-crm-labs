# Lab 22 — Professional Error Handling ♻️

> **Phase:** 6 — Persistence & Quality · **Builds on:** Lab 21 · **Time:** ~3.5 hours
> **Your repo before this lab:** tag `lab-21` · **After:** tag `lab-22`

## 🎯 Goal
Refactor every error path in the CRM into clear **layers**: domain errors that describe business
rules, storage errors that say *which file* failed and *why*, CLI errors for typing mistakes,
and an application edge that turns all of them into readable messages and a correct exit code.

## 🧠 What You'll Learn
- The difference between **library errors** (for code to match on) and **application errors**
  (for humans to read), and why Rust uses different tools for each
- `thiserror`: what `#[derive(Error)]`, `#[error("...")]`, `#[from]`, `#[source]` and
  `#[error(transparent)]` generate
- **Error source chains**: `Error::source()`, and the rule "display it *or* expose it as a source,
  never both"
- `Box<dyn Error>`: what it is, what it's good for, and where it falls short
- `anyhow`: a type-erased error with **context**, and its three output formats
- Why `?` performs exactly **one** `From` conversion
- How `main` returning `Result` sets the **process exit code**
- `downcast_ref`: getting a concrete error back out of a `dyn Error`

## 🔨 What We're Building
Lab 21 left the error handling in an awkward state. `CrmError`, the type that describes your
*business rules*, now also contains `Io(std::io::Error)` and `Json(serde_json::Error)`. It also
holds `UnknownCommand` and `Usage`, which only make sense for a terminal. Every concern is in one
enum. When the CRM refuses to start, it still exits with code `0` ("success").

When Lab 27 puts an HTTP API on top of the same domain, it will need to map each `CrmError` to a
status code: `NotFound` → 404, `DuplicateEmail` → 409. What's the status code for
`UnknownCommand`? For a JSON parse error *in your data file*? There isn't a sensible one, because
those errors belong to other layers.

After this lab:

```text
              ┌──────────────────────────────────────────────────────────────┐
 main.rs      │ anyhow::Result<()>   → prints the chain, exit code 1          │  application edge
              └───────────────▲──────────────────────────────▲───────────────┘
                              │ .context("refusing to start…")│
              ┌───────────────┴───────────────┐  ┌────────────┴───────────────┐
 cli/         │ CliError                       │  │ StorageError                │ storage.rs
              │  UnknownCommand, Usage,        │  │  Read  { path, source: io } │
              │  Domain(CrmError) transparent  │  │  Write { path, source: io } │
              └───────────────▲───────────────┘  │  Parse { path, source: json}│
                              │ #[from]           └─────────────────────────────┘
              ┌───────────────┴───────────────┐
 errors.rs    │ CrmError (domain only)         │
              │  NotFound, DuplicateEmail,     │
              │  Validation(ValidationError),  │
              │  HasContacts, InvalidTransition│
              │  LeadNotQualified, …           │
              └───────────────────────────────┘
```

And the user sees things like:

```text
Error: refusing to start, so the data file is not overwritten

Caused by:
    0: could not read crm-data.json
    1: Permission denied (os error 13)
```

---

## Step 1 — Inventory: who produces an error, and who reads it?

Before touching code, list every place an error is born in your CRM, and ask two questions about
each: **who needs to react to it**, and **who needs to read it**?

| Error | Born in | Code that reacts to it | Human who reads it |
|---|---|---|---|
| Invalid email, empty name, bad money | `Email`, `Money`, `Validate` impls | REPL (Lab 27: HTTP 422) | User typing data |
| Not found, duplicate email, has contacts, bad deal transition, lead not qualified | `Crm` methods, `Deal`, `Lead` | REPL (Lab 27: 404 / 409) | User |
| Unknown command, wrong arguments | `cli/parser.rs` | REPL only | User |
| Can't read / write / parse `crm-data.json` | `storage.rs` | REPL: refuse to start, or warn on save | User, or whoever runs the program |
| Can't write to stdout | `read_line` | Nobody can (`expect`) | Nobody, the terminal is gone |

Two kinds of consumer appear:

1. **Code** that needs to *decide* something: "is this a not-found? Then 404". Code needs a type
   it can `match` on, with **variants**. That's a **library error**: an enum, one variant per
   situation a caller might handle differently.
2. **Humans** who need to *understand* something: "what failed, and why". Humans need a good
   message with its causes. The program usually can't fix the problem anyway, so it just needs to
   carry the error up to the edge and print it. That's an **application error**.

The Rust ecosystem has a standard tool for each:

| | `thiserror` | `anyhow` |
|---|---|---|
| For | library errors (callers match on them) | application errors (humans read them) |
| What you get | your own `enum`, with `Display`, `Error` and `From` impls generated | one type, `anyhow::Error`, that holds *any* error |
| Callers can `match` on variants? | ✅ | ❌ (only `downcast`) |
| Add context ("while doing X")? | by designing variants | `.context("...")` anywhere |
| Use in | `errors.rs`, `storage.rs` | `main.rs`, `cli::run` |

"Library" and "application" describe the *role* of the code, not the crate it lives in. Your
`cli` module is in the library crate (`src/lib.rs`), but it's application code: nothing calls
it except `main`. So it may use `anyhow`.

```bash
cargo add thiserror anyhow
```

> Written against **thiserror 2** and **anyhow 1**.

---

## Step 2 — `thiserror`: what the derive writes for you

Look at your current `src/errors.rs`. For each enum you hand-wrote three things: the enum, a
`Display` impl with one `match` arm per variant, an empty `impl std::error::Error`, and one
`From` impl per wrapped error. That's a lot of mechanical code, and the message for a variant
lives far away from the variant.

> 🟢 **FOLLOW ALONG**: rewrite `ValidationError`. Delete its `impl fmt::Display` and
> `impl std::error::Error` blocks.

```rust
use thiserror::Error;

#[derive(Debug, PartialEq, Error)]
pub enum ValidationError {
    #[error("name must not be empty")]
    EmptyName,
    #[error("invalid email address '{0}'")]
    InvalidEmail(String),
    #[error("invalid phone number '{0}'")]
    InvalidPhone(String),
    #[error("invalid amount '{0}'")]
    InvalidMoney(String),
    #[error("invalid {field}: '{value}'")]
    InvalidValue { field: &'static str, value: String },
    #[error("title must not be empty")]
    EmptyTitle,
    // ... InvalidWebsite, InvalidLifecycle, EmptyNote and any others you have ...
}
```

Convert **every** variant you have, and keep **your** existing messages. The ones above are
examples. Struct variants name their fields in the message (`{field}`, `{value}`).

What does `#[derive(Error)]` generate? Almost exactly what you wrote by hand in Lab 12:

```rust
// Roughly what thiserror generates
impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ValidationError::EmptyName => write!(f, "name must not be empty"),
            ValidationError::InvalidEmail(_0) => write!(f, "invalid email address '{}'", _0),
            // ...
        }
    }
}

impl std::error::Error for ValidationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        None // no field is marked as a source
    }
}
```

Two important properties:

- **thiserror is invisible to your callers.** The generated code is ordinary trait impls. Nobody
  using `ValidationError` can tell whether you used the macro or wrote them by hand, and
  `thiserror` never appears in your public API. That's what makes it right for library code.
- `{0}` refers to the first tuple field and `{entity}` to a named field. Any expression works
  with the extra-argument syntax: `#[error("could not read {}", path.display())]`.

Run `cargo test`. Nothing should change.

### `Error::source()`: errors have causes

The `std::error::Error` trait has one important method besides `Display`:

```rust
pub trait Error: Debug + Display {
    fn source(&self) -> Option<&(dyn Error + 'static)> { None }
}
```

`source()` returns **the error that caused this one**, if any. It forms a linked list:

```text
StorageError::Read { path: "crm-data.json" }      Display: "could not read crm-data.json"
        │ .source()
        ▼
std::io::Error (PermissionDenied)                  Display: "Permission denied (os error 13)"
        │ .source()
        ▼
      None
```

Each link's `Display` describes **only its own layer**. The full story is the whole chain.
That's how the outer error can say *what we were doing* ("reading crm-data.json") while the inner
one says *what went wrong* ("permission denied"), without either one needing to know about the
other.

---

## Step 3 — `CrmError` becomes domain-only

> 🟢 **FOLLOW ALONG**: rewrite `CrmError` with thiserror. Delete its manual `Display`,
> `Error` and **all** `From` impls. Leave `Io`, `Json`, `UnknownCommand` and `Usage` in for now.
> We'll move them out one at a time.

```rust
#[derive(Debug, Error)]
pub enum CrmError {
    #[error("{entity} #{id} not found")]
    NotFound { entity: &'static str, id: u64 },
    #[error("a contact with email {0} already exists")]
    DuplicateEmail(String),
    #[error("validation failed")]
    Validation(#[from] ValidationError),
    #[error("company {0} still has contacts")]
    HasContacts(CompanyId),
    #[error("a deal cannot move from {from} to {to}")]
    InvalidTransition { from: DealStage, to: DealStage },
    #[error("lead {0} is not qualified")]
    LeadNotQualified(LeadId),
    #[error("lead {0} was disqualified and cannot be qualified")]
    LeadDisqualified(LeadId),
    #[error("Unknown command: {0}. Type 'help' for a list of commands.")]
    UnknownCommand(String),
    #[error("Usage: {0}")]
    Usage(&'static str),
    #[error("file error")]
    Io(#[from] std::io::Error),
    #[error("data file is not valid")]
    Json(#[from] serde_json::Error),
}
```

`#[from]` does two jobs. It generates `impl From<ValidationError> for CrmError` (so `?` keeps
working), and it marks the field as the **source**, so `source()` returns it.

> 🟡 **EXPERIMENT**: predict, then try it. `cargo run`, then `contact add` with the email `nope`.

```text
crm> contact add
Name: X
Email: nope
Error: validation failed
```

The REPL prints `{e}`, which is only the **top** of the chain. "invalid email address 'nope'" is
still there, one `source()` down, but nobody prints it. You have two honest options:

1. The wrapper **adds information** ("validation failed" while doing *what*?). Then keep it as a
   separate link, and make sure every printer shows the full chain.
2. The wrapper **adds nothing**. It only exists so a `ValidationError` can travel as a `CrmError`.
   Then make it invisible: `#[error(transparent)]` forwards both `Display` *and* `source()` to the
   inner error.

`Validation` is case 2. Change it:

```rust
    #[error(transparent)]
    Validation(#[from] ValidationError),
```

Run the experiment again: `Error: invalid email address 'nope'`.

---

## Step 4 — `StorageError`: errors that say *where*

Now delete the `Io` and `Json` variants from `CrmError` and run `cargo check`:

```text
error[E0277]: the trait bound `CrmError: From<std::io::Error>` is not satisfied
  --> src/storage.rs:17:32
   |
17 |         Err(e) => return Err(e.into()),
   |                                ^^^^ unsatisfied trait bound
   |
help: the trait `From<std::io::Error>` is not implemented for `CrmError`
      but trait `From<ValidationError>` is implemented for it

error[E0277]: `?` couldn't convert the error to `CrmError`
  --> src/storage.rs:20:46
   |
13 | pub fn load(path: &Path) -> Result<Crm, CrmError> {
   |                             --------------------- expected `CrmError` because of this
...
20 |     let crm = serde_json::from_reader(reader)?;
   |               -------------------------------^ the trait `From<serde_json::Error>` is not implemented for `CrmError`
   |               |
   |               this can't be annotated with `?` because it has type `Result<_, serde_json::Error>`
   |
note: `CrmError` needs to implement `From<serde_json::Error>`
```

Good. The compiler just listed every place where a storage concern leaked into the domain type.

Notice also what the old design **lost**: an `io::Error` says "Permission denied" but **not which
file**. `io::Error` doesn't store paths. If the CRM ever touches two files, "Permission denied"
alone is useless. The layer that knows the path is `storage.rs`, so that's where the context
belongs.

> 🟢 **FOLLOW ALONG**: at the top of `src/storage.rs`

```rust
use thiserror::Error;

/// Everything that can go wrong while loading or saving the CRM.
#[derive(Debug, Error)]
pub enum StorageError {
    #[error("could not read {}", path.display())]
    Read {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("could not write {}", path.display())]
    Write {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("{} does not contain valid CRM data", path.display())]
    Parse {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
}
```

Design decisions, one by one:

- **Variants by *operation*** (read / write / parse), not by underlying error type. A caller
  (Lab 23's `--storage json`, Lab 28's API) wants to know "was the data corrupt, or could we not
  reach the disk?". It doesn't care that `serde_json` was involved.
- **`path: PathBuf`, owned.** The error must outlive the function that created it (it's
  returned), so it can't borrow the caller's `&Path`. `path.to_path_buf()` makes an owned copy.
  Errors are the rare path; one small allocation there is fine.
- **`#[source]`, no `#[from]`.** We do **not** want `impl From<io::Error> for StorageError`. With
  it, `?` would happily convert any `io::Error` with no path. Without it, the compiler forces
  every call site to say *which* operation failed and *on which path*. (A field literally named
  `source` is treated as the source even without the attribute. Writing `#[source]` anyway makes
  the intent obvious.)
- **The message doesn't include the source.** `"could not read {path}"`, not
  `"could not read {path}: {source}"`. The chain printer will add the cause. See the experiment
  in Step 7 for what happens otherwise.

Now `load` and `save`:

> 🟢 **FOLLOW ALONG**

```rust
pub fn load(path: &Path) -> Result<Crm, StorageError> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Crm::default()),
        Err(source) => {
            return Err(StorageError::Read { path: path.to_path_buf(), source });
        }
    };
    let reader = BufReader::new(file);
    serde_json::from_reader(reader).map_err(|source| StorageError::Parse {
        path: path.to_path_buf(),
        source,
    })
}

pub fn save(crm: &Crm, path: &Path) -> Result<(), StorageError> {
    write_atomically(crm, path).map_err(|source| StorageError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn write_atomically(crm: &Crm, path: &Path) -> io::Result<()> {
    let tmp = tmp_path(path);
    let mut writer = BufWriter::new(File::create(&tmp)?);
    serde_json::to_writer_pretty(&mut writer, crm)?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    fs::rename(&tmp, path)
}
```

Look closely at `write_atomically`:

- It returns plain **`io::Result<()>`** (an alias for `Result<(), io::Error>`). All five fallible
  steps are "writing", so one private function collects them and `save` wraps the result **once**
  with the path. Without the helper, you'd repeat `map_err(|source| StorageError::Write {...})`
  five times.
- `serde_json::to_writer_pretty(...)?` returns a `serde_json::Error`, yet `?` accepts it in a
  function returning `io::Error`. That's because `serde_json` provides
  `impl From<serde_json::Error> for io::Error`. When *writing*, a serde_json failure is almost
  always an I/O failure underneath.
- `map_err(|source| StorageError::Parse { path: path.to_path_buf(), source })` uses field init
  shorthand: `source` means `source: source`.

Fix your storage tests from Lab 21: `Err(CrmError::Json(_))` becomes
`Err(StorageError::Parse { .. })`. `{ .. }` matches a struct variant regardless of its fields.

`cargo check` passes again, because the REPL only prints `{e}`. Corrupt your data file (Lab 21,
Experiment 1) and run:

```text
Error: could not load crm-data.json: crm-data.json does not contain valid CRM data
Refusing to start, so the file is not overwritten. Fix or move it and try again.
```

The path is now in the error, so the REPL's "could not load crm-data.json" is redundant. And the
actual reason (*which* email, *which* line) has disappeared, because it's one `source()` down
and the REPL only prints the top. We'll fix both by giving the REPL a real error edge in Steps 6–7.

> 🟡 **EXPERIMENT**: `CrmError` no longer contains `io::Error` or `serde_json::Error`. Could it
> derive `PartialEq` again? Try it. It compiles. **Don't keep it.** In Lab 30 a
> `Database(sqlx::Error)` variant arrives and you'd lose it again. More importantly, Lab 21
> showed that tests which match on an error's *shape* (`matches!`) are better tests than tests
> that compare whole values. Remove the `PartialEq` again.

---

## Step 5 — `CliError`: typing mistakes aren't business rules

`UnknownCommand` and `Usage` describe mistakes **typed into a terminal**. The domain doesn't know
there is a terminal: in Lab 27 the same `Crm` will be driven by HTTP requests, and Lab 30 retires
the terminal completely. These errors belong to the `cli` module.

> 🟢 **FOLLOW ALONG**: create `src/cli/error.rs` and add `mod error;` to `src/cli/mod.rs`.

```rust
use thiserror::Error;

use crate::errors::CrmError;

/// Errors that only exist because there is a terminal UI.
#[derive(Debug, Error)]
pub(crate) enum CliError {
    #[error("Unknown command: {0}. Type 'help' for a list of commands.")]
    UnknownCommand(String),
    #[error("Usage: {0}")]
    Usage(&'static str),
    #[error(transparent)]
    Domain(#[from] CrmError),
}
```

- `pub(crate)`. Nothing outside the crate needs it (Lab 13's visibility rules at work).
- `Domain(#[from] CrmError)` with `transparent`. A command can fail because of the user's typing
  (`Usage`) **or** because of a business rule (`NotFound`). `#[from]` lets `?` lift any
  `CrmError` into a `CliError`, and `transparent` keeps the message exactly as the domain wrote it.

Now move the two variants. Delete `UnknownCommand` and `Usage` from `CrmError`. Then:

- in `cli/parser.rs`, `parse_command` (and its helpers) return `Result<_, CliError>` and build
  `CliError::Usage` / `CliError::UnknownCommand`;
- in `cli/commands.rs`, `execute` (and its helpers) return `Result<(), CliError>`.

Run `cargo check`. Three new kinds of error appear. Each one teaches something.

**1. `?` performs exactly one conversion.**

```text
error[E0277]: `?` couldn't convert the error to `CliError`
   --> src/cli/commands.rs:166:57
    |
162 | fn contact(crm: &mut Crm, command: ContactCommand) -> Result<(), CliError> {
    |                                                       -------------------- expected `CliError` because of this
...
166 |             let email = Email::parse(&prompt("Email: "))?;
    |                         --------------------------------^ the trait `From<ValidationError>` is not implemented for `CliError`
    |                         |
    |                         this can't be annotated with `?` because it has type `Result<_, ValidationError>`
    |
note: `CliError` needs to implement `From<ValidationError>`
    = note: the question mark operation (`?`) implicitly performs a conversion on the error value using the `From` trait
```

`ValidationError → CrmError` exists, and `CrmError → CliError` exists. But `?` calls
`From::from` **once**. It never searches for a path through several conversions. (If it did, adding
one `From` impl anywhere could silently change which path is taken somewhere else.) You make the
two-step journey explicit, once, in `src/cli/error.rs`:

```rust
/// `?` performs exactly one `From` conversion, so ValidationError -> CliError
/// needs its own impl (it goes through CrmError on the way).
impl From<ValidationError> for CliError {
    fn from(e: ValidationError) -> Self {
        CliError::Domain(CrmError::from(e))
    }
}
```

**2. Returning a domain error by hand.**

```text
error[E0308]: mismatched types
   --> src/cli/commands.rs:217:28
    |
217 |                 return Err(CrmError::DuplicateEmail(e.to_string()));
    |                        --- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ expected `CliError`, found `CrmError`
```

`?` converts for you, but `return Err(...)` doesn't. Add `.into()`:
`return Err(CrmError::DuplicateEmail(e.to_string()).into());`

**3. The domain was using CLI errors.**

```text
error[E0599]: no variant, associated function, or constant named `Usage` found for enum `CrmError` in the current scope
  --> src/subject.rs:23:31
   |
23 |         let usage = CrmError::Usage("<company|contact|deal>:<id>");
   |                               ^^^^^ variant, associated function, or constant not found in `CrmError`
```

This is the refactor paying off. Somewhere in Labs 19–20, domain code borrowed a CLI error because
it was handy. (Your hits depend on how you wrote Labs 19–20. A typical one is `Subject`'s
`FromStr` reporting a bad `deal:x` as `Usage`.) The compiler has just found every one of them.

> 🔵 **YOUR TURN 1: evict CLI errors from the domain**
>
> Fix every `E0599` outside `src/cli/` by giving the domain its **own** error for that situation.
> Don't move `Usage` back.
>
> - [ ] `Subject`'s `FromStr` uses `type Err = ValidationError;` and a new variant
>   `ValidationError::InvalidSubject(String)` holding the rejected input, with a message such as
>   `invalid subject 'deal:x' (expected company:<id>, contact:<id> or deal:<id>)`
>   (If you prefer, reuse your generic `ValidationError::InvalidValue { field: "subject", value }`
>   instead of a new variant. Either is fine; pick one and say why in a comment.)
> - [ ] any other domain code that used `Usage` or `UnknownCommand` gets a fitting **domain**
>   variant. (Notice that `LeadDisqualified` already exists: Lab 19 gave that business rule its own
>   variant. That's the pattern to follow.)
> - [ ] the CLI still prints a helpful usage line when the user types `history deal:x`
>   (the parser can `map_err` the domain error into `CliError::Usage`)
> - [ ] `grep -rnE "Usage|UnknownCommand" src | grep -v "src/cli/"` prints **nothing**
> - [ ] a unit test: `"deal:x".parse::<Subject>()` returns
>   `Err(ValidationError::InvalidSubject("deal:x".to_string()))`. (`assert_eq!` works here.
>   Why does it work for `ValidationError` but not for `CrmError`?)
> - [ ] `cargo test` passes

**Why bother?** Lab 28 maps `CrmError` and `ValidationError` onto HTTP status codes with a
`match`. If `Usage` were still in there, you'd have to invent a status code for "the user typed
the wrong thing into a terminal that doesn't exist". With domain-only errors, every variant has a
real meaning.

---

## Step 6 — The application edge: `Box<dyn Error>` first

The REPL decides by itself what to print and quietly returns on a fatal error, so the exit code
says "success". Let's give the program a real edge: `main` returns a `Result`.

Rust's `main` may return `Result<(), E>` for any `E: Debug`. If it returns `Err(e)`, the
runtime prints `Error: {e:?}` to stderr and exits with code **1**. (The `Termination` trait does
this.) Scripts, CI and process supervisors look at exit codes. `0` means success, and anything
else means failure.

What should `E` be? `cli::run` can fail with a `StorageError`, and later maybe something else.
The classic answer is a **trait object**: `Box<dyn std::error::Error>`, "some heap-allocated
value whose type I don't know, but which implements `Error`". (Lab 23 is all about trait objects.
For now, read it as "any error".)

> 🟡 **EXPERIMENT**: change `run` and `main`

```rust
// src/cli/mod.rs
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    // ...
    let mut crm = storage::load(path)?;   // replaces the whole `match storage::load(path) { … }`
    // ...
    println!("Goodbye! ({commands_run} commands this session)");
    Ok(())
}
```

```rust
// src/main.rs
use std::error::Error;

fn main() -> Result<(), Box<dyn Error>> {
    rust_crm::cli::run()
}
```

`storage::load(path)?` compiles even though `run` doesn't mention `StorageError`. The standard
library has `impl<E: Error> From<E> for Box<dyn Error>`, so **any** error converts. Corrupt the
data file again and run:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Error: Parse { path: "crm-data.json", source: Error("invalid email address 'ada at acme'", line: 18, column: 31) }
```

```bash
echo $?
```

```text
1
```

The exit code is right. The message is a **debug dump**, because `main` prints with `{:?}`. And
we've lost the friendly "refusing to start" explanation, because `?` can't add a sentence to an
error on its way up.

`Box<dyn Error>` is fine for small tools and examples. For an application edge you want two more
things: **context** added while an error travels upward, and **readable output from `main`**.
That's exactly what `anyhow` adds.

---

## Step 7 — `anyhow`: context and readable chains

`anyhow::Error` is like `Box<dyn Error + Send + Sync + 'static>`, with a few upgrades:

- `.context("...")` / `.with_context(|| ...)` on any `Result` wrap the error in **a new link of the
  chain** with your message on top. (It's an extension trait, so `use anyhow::Context;`.)
- Its `Debug` output (what `main` prints) is a readable **"Caused by:"** list, not a struct dump.
- It's one pointer wide. A `Result<T, anyhow::Error>` stays small.
- It can capture a backtrace (`RUST_BACKTRACE=1`), and you can `downcast_ref::<StorageError>()`
  to get the concrete error back if you ever need it.

`anyhow::Result<T>` is shorthand for `Result<T, anyhow::Error>`.

> 🟢 **FOLLOW ALONG**

```rust
// src/main.rs
fn main() -> anyhow::Result<()> {
    rust_crm::cli::run()
}
```

```rust
// src/cli/mod.rs
use anyhow::Context;

pub fn run() -> anyhow::Result<()> {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    let path = Path::new(DATA_FILE);
    let mut crm = storage::load(path)
        .context("refusing to start, so the data file is not overwritten")?;
    // ... "Loaded …" line and the loop, see below ...
    println!("Goodbye! ({commands_run} commands this session)");
    Ok(())
}
```

Corrupt the file and run:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Error: refusing to start, so the data file is not overwritten

Caused by:
    0: crm-data.json does not contain valid CRM data
    1: invalid email address 'ada at acme' at line 18 column 31
```

Exit code `1`. Every layer said one thing, in order: the **application** (what it decided), the
**storage** layer (which file, which operation), and the **root cause** (your `ValidationError`,
reported through serde_json with a position).

Now make the file unreadable: `chmod 000 crm-data.json`, run, then `chmod 644 crm-data.json`.

```text
Error: refusing to start, so the data file is not overwritten

Caused by:
    0: could not read crm-data.json
    1: Permission denied (os error 13)
```

`.context(msg)` vs `.with_context(|| format!(...))`: `context` takes the message *eagerly*. If
building it costs something (a `format!` allocates), use `with_context` with a closure. It only
runs if there actually is an error.

### anyhow's three formats

| Format | Output for the error above |
|---|---|
| `{}` | `refusing to start, so the data file is not overwritten` (top only) |
| `{:#}` | `refusing to start, so the data file is not overwritten: could not read crm-data.json: Permission denied (os error 13)` (whole chain, one line) |
| `{:?}` | the multi-line "Caused by:" report (what `main` prints) |

> 🟡 **EXPERIMENT: saying it twice.** Change `Read`'s message to
> `#[error("could not read {}: {source}", path.display())]`, then run with `chmod 000` again:

```text
Caused by:
    0: could not read crm-data.json: Permission denied (os error 13)
    1: Permission denied (os error 13)
```

The cause is printed by your message **and** by the chain walker. This is the most common
error-design mistake in Rust. The rule:

> **An error either includes its cause in its message, or returns it from `source()`. Never both.**

`#[error(transparent)]` is the "include" option done properly. `#[source]` + a message that
describes only your own layer is the "return it" option. Revert the message.

---

## Step 8 — The REPL prints chains too

Inside the REPL, errors aren't fatal. A typo, a missing contact or a failed save gets printed and
the loop continues. `main`'s pretty report never sees them, so the REPL must print whole chains
itself.

The standard library gives you `source()`. Walking it is a loop you'll write once and use forever.

> 🔵 **YOUR TURN 2: `error_chain`**
>
> In `src/errors.rs`, implement:
>
> ```rust
> /// Formats an error and all of its causes on one line:
> /// `outer message: cause: root cause`.
> pub fn error_chain(err: &dyn std::error::Error) -> String
> ```
>
> - [ ] an error without a cause prints only its own message
> - [ ] each cause is appended with `": "` until `source()` returns `None`
> - [ ] unit tests in `errors.rs`, with these names:
>   - `error_chain_of_an_error_without_cause_is_its_message` (use `ValidationError::EmptyName`)
>   - `error_chain_includes_the_io_cause`: a
>     `StorageError::Write { path: "data.json".into(), source: std::io::Error::other("disk full") }`
>     gives exactly `"could not write data.json: disk full"`
>   - `transparent_validation_error_is_not_repeated`: `CrmError::from(ValidationError::EmptyName)`
>     gives exactly `"name must not be empty"` (this proves `transparent` forwards `source()` too)
> - [ ] no `unwrap`, no recursion needed (a `while let` loop is enough)

Then use it in the REPL loop, for **both** kinds of non-fatal error:

```rust
        let command = match parser::parse_command(&line) {
            Ok(Some(command)) => command,
            Ok(None) => continue,
            Err(e) => {
                println!("Error: {}", error_chain(&e));
                continue;
            }
        };
        // ...
        let mutating = command.is_mutating();
        match commands::execute(&mut crm, command) {
            Ok(()) if mutating => {
                if let Err(e) = storage::save(&crm, path) {
                    println!("Error: {}", error_chain(&e));
                    println!("(The change is kept in memory and will be saved with your next change.)");
                }
            }
            Ok(()) => {}
            Err(e) => println!("Error: {}", error_chain(&e)),
        }
```

`&e` is a `&CliError` or a `&StorageError`, yet the function takes `&dyn Error`. Rust
**coerces** a reference to a concrete type into a reference to a trait object automatically,
because both types implement `Error`. Lab 23 shows what's inside such a reference.

Why does a failed save keep running instead of exiting? The change *is* applied in memory. The
user might fix the permission problem and the next save succeeds. Exiting would lose more data,
not less. (Lab 25 makes this more robust with a dirty flag and a background saver.)

### The last error path: `expect` in `read_line`

`read_line` still contains `io::stdout().flush().expect("stdout should be writable")`. Is that OK
in "professional" error handling? Yes. `expect` is for **"if this fails, the program has no
sensible way to continue and nobody to report to"**. If the terminal itself is gone, there is no
one to print an error message to. Keep it, and keep the message explaining *why* it's expected to
succeed.

---

## ▶️ Run It

```bash
cargo run
```

Try a typo, a missing record, an invalid email and a bad subject. Then make the directory
read-only (`chmod a-w .`), add a company, and restore it (`chmod u+w .`).

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Loaded 1 company, 1 contact, 0 deals, 0 leads from crm-data.json
crm> dance
Error: Unknown command: dance. Type 'help' for a list of commands.
crm> note add deal:9 hi
Error: deal #9 not found
crm> contact add
Name: A
Email: bad
Error: invalid email address 'bad'
crm> history deal:x
Error: Usage: history <subject>
crm> quit
Goodbye! (3 commands this session)
```

With the directory read-only (the temp file can't be created):

```text
crm> company add
Name: Globex
Website (blank for none):
Added company #2
Error: could not write crm-data.json: Permission denied (os error 13)
(The change is kept in memory and will be saved with your next change.)
```

With a corrupt or unreadable file, the "Caused by:" reports from Step 7, and `echo $?` prints `1`.

## 🧠 Understand It

**Two audiences, two tools.** Code that must *decide* needs variants (`thiserror` enums). Humans
who must *understand* need messages with causes (`anyhow` at the edge). Most real Rust
applications use both: `thiserror` in the inner layers, `anyhow` at the outermost layer.

**Layers own their context.** `storage.rs` knows the path, so `StorageError` carries it. The
REPL knows *why* it was loading, so it adds "refusing to start" with `.context`. The domain knows
the business rule, so `CrmError` names it. Nobody has to know about anybody else's details.

**A chain is a linked list through `source()`.** Each link's `Display` describes its own layer
only. Printing an error properly means walking the list: anyhow's `{:#}` and `{:?}`, or your
`error_chain`.

**`#[from]` vs `#[source]` vs `transparent`:**

| Attribute | Generates `From`? | Is the source? | Message |
|---|---|---|---|
| `#[source]` | no | yes | yours |
| `#[from]` | yes | yes | yours |
| `#[error(transparent)]` + `#[from]` | yes | forwards the inner `source()` | the inner error's |

Leave out `From` on purpose when the *call site* must supply context (like a path).

**`?` = one `From::from` + early return.** No chains of conversions. Multi-hop conversions are
explicit impls.

**`main` returning `Result`** gives you a correct exit code for free, and prints `Error: {:?}`.
That's why the `Debug` format of the error type matters at the edge, and why anyhow's is a report.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: in `main.rs`, temporarily replace the body with
> `if let Err(e) = rust_crm::cli::run() { eprintln!("{e:#}"); std::process::exit(2); } Ok(())`.
> Corrupt the file and run. What changed in the output, and what is `echo $?` now? When would a
> program want different non-zero exit codes? Revert afterwards.

> 🟡 **EXPERIMENT 2**: in the REPL loop, replace `error_chain(&e)` for save errors with plain
> `{e}`. Make the directory read-only and add something. What information is lost? Revert.

> 🟡 **EXPERIMENT 3**: run with `RUST_BACKTRACE=1` and a corrupt file. anyhow captures a
> backtrace when the error is created. Can you find `storage::load` in it? Why are backtraces
> usually turned off for errors users are *expected* to hit?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1** (evict CLI errors from the domain) is in Step 5.
> 🔵 **YOUR TURN 2** (`error_chain`) is in Step 8.

> 🔵 **YOUR TURN 3: test the storage errors.** Add to the tests in `src/storage.rs`:
>
> - [ ] `parse_error_names_the_file_and_keeps_the_cause`: write a file with an invalid email,
>   `load` it, and assert:
>   - the error's `Display` contains the file's path
>   - `source()` is `Some`, and that source **downcasts** to a `serde_json::Error`
>   - that `serde_json::Error` reports the right line (`.line()`)
> - [ ] `error_chain_joins_every_cause`: for the same kind of file, `error_chain(&err)` starts with
>   `"<path> does not contain valid CRM data: "` and contains `"invalid email address 'nope'"`
> - [ ] no `PartialEq` on `StorageError`
> - [ ] `cargo test storage` passes

## 💡 Hint

> 💡 **HINT** (Your Turn 1): `Subject::from_str` currently builds the same error in three
> places. A small closure, `let invalid = || ValidationError::InvalidSubject(s.to_string());`,
> lets you write `.ok_or_else(invalid)?` and `.map_err(|_| invalid())?`.

> 💡 **HINT** (Your Turn 2): `err.source()` returns `Option<&(dyn Error + 'static)>`. Keep a
> variable `current` of that type and loop with `while let Some(cause) = current { ...; current = cause.source(); }`.

<details><summary>Hint 2 (more specific)</summary>

- `std::io::Error::other("disk full")` builds an `io::Error` whose `Display` is exactly
  `disk full`. Handy for tests.
- `std::error::Error::source(&err)` calls the trait method explicitly. Writing `err.source()`
  works too if `std::error::Error` is imported.
- `downcast_ref::<T>()` is a method on `dyn Error + 'static`. It returns `Option<&T>`: `Some` if the
  value behind the trait object really is a `T`.
- `path.to_string_lossy()` gives a `Cow<str>` you can search for in a message. `&*` turns it into
  a `&str`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Give one error from your CRM that belongs in a `thiserror` enum and one that only ever needs to
   be read by a human. What's the deciding question?
2. What exactly does `#[from]` generate? Why does `StorageError` deliberately **not** use it?
3. Why did `?` refuse to turn a `ValidationError` into a `CliError` when both `From` steps existed?
4. What is the rule about `Display` and `source()`, and what goes wrong if you break it?
5. Why is `Validation` transparent while `StorageError::Read` is not?
6. What decides the exit code of your program now, and why does that matter outside the terminal?
7. Why does a failed save in the REPL *not* end the program?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit
```bash
git add .
git commit -m "Layer errors with thiserror and anyhow"
git tag lab-22
git push && git push --tags
```

Try `git diff lab-21 lab-22 -- src/errors.rs`. Most of the diff is code you **deleted**.

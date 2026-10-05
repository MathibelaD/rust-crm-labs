# Lab 13 — Modules, Crates & Visibility ♻️ (first restructure)

> **Phase:** 3 — Modelling the Domain · **Builds on:** Lab 12 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-12` · **After:** tag `lab-13`

> This lab assumes you completed **Your Turns 1 and 2 in Lab 12** (`parse_phone`,
> `colleague_note`). If you skipped them, copy them from
> [Lab 12's solutions.md](../12-option-result-errors/solutions.md) first. Your Turn 4
> (`Email::domain`) is optional; where it matters, this lab says what to do either way.

## 🎯 Goal

Split the single `main.rs` into a **library crate** organised in modules (`errors`, `customers`,
`cli`) plus a three-line binary. Make `Email`'s field truly private, so the **only** way to get
an `Email` is through `Email::parse`.

## 🧠 What You'll Learn

- Packages, crates and modules, and how they relate
- The **module tree** (what the compiler sees) vs the **file tree** (what you see)
- `mod`, `pub`, `pub(crate)`, private-by-default, and the rule for who can see what
- Paths: `crate::`, `super::`, `self::`, and `use`
- Re-exports with `pub use`: a public API that's different from your file layout
- `mod.rs` vs `name.rs` + `name/` (and why this course uses `mod.rs`)
- A **library crate + binary crate** in one package, and why Labs 24 and 27 need it
- Doc comments (`///`, `//!`), `cargo doc --open`, and doc tests

## 🔨 What We're Building

No new features. Same commands, same output. This is a **restructure**: a change in shape that
makes the next twenty labs possible. Before:

```text
src/
└── main.rs        ~950 lines: errors, Email, Customer, store, parser, commands, REPL, tests
```

After:

```text
src/
├── main.rs              fn main() { rust_crm::cli::run(); }
├── lib.rs               the library crate's root: declares the modules
├── errors.rs            CrmError, ValidationError
├── customers/
│   ├── mod.rs           declares the submodules, re-exports the public API
│   ├── email.rs         Email (field private!)
│   ├── model.rs         Customer, CustomerStatus, parse_name, parse_phone, initials
│   └── store.rs         CustomerStore
└── cli/
    ├── mod.rs           pub fn run(): the REPL loop, prompt()
    ├── parser.rs        Command, parse_command
    └── commands.rs      execute, print_help
```

Why now and not in Lab 01? Because now the pain is real, and you'll recognise every problem a
module solves. Restructuring before you feel the need just means guessing.

---

## Step 1 — Feel the pain

```bash
wc -l src/main.rs
```

Around 950 lines, depending on how many tests you wrote. Two problems hide in there, and only
one of them is length.

**Problem 1: there's no privacy.** Add this anywhere in `main`, and run `cargo check`:

```rust
    let fake = Email(String::from("definitely not an email"));
    println!("{}", fake.as_str());
```

It compiles. In Lab 12, `Email::parse` was supposed to be the only way to build an `Email`, and
the compiler even *suggested* `Email(email)` when you changed `update_email`. The field
`struct Email(String)` is private, but Rust's privacy is **per module**: private means "visible
inside the module where it's defined (and its child modules)". Everything in `main.rs` is one
module, so nothing is private from anything. Delete the two lines.

**Problem 2: nothing can reuse the code.** In Lab 24 you'll write integration tests in a
`tests/` folder, and in Lab 27 a web server that serves the same customers over HTTP. Both are
separate programs that need `Customer`, `Email`, `CustomerStore` and `CrmError`. A **binary**
crate (a program with a `main`) can't be imported by anyone. A **library** crate can.

Length makes the code hard to navigate. The missing privacy makes it hard to **trust**. The
missing library makes it hard to **reuse**. Modules fix all three.

---

## Step 2 — The mental model: packages, crates, modules

Three words that are easy to blur:

- A **package** is what `cargo new` made: a folder with a `Cargo.toml`. Yours is called
  `rust-crm`. A package contains one or more crates.
- A **crate** is one unit of compilation: the compiler turns one crate into one library or one
  executable. Each crate has a **root file**. By convention:
  - `src/main.rs` is the root of a **binary crate** named after the package (`rust-crm`).
  - `src/lib.rs` is the root of a **library crate** with the same name, except hyphens become
    underscores: `rust_crm`, because `-` isn't allowed in Rust identifiers.
  A package can have both. Cargo builds the library first, then the binary, which uses the
  library like any external crate.
- A **module** is a named scope inside a crate, for organising code and controlling privacy.
  Modules nest, forming a tree whose root is the crate root.

### The module tree is not the file tree

This is the part that confuses everyone coming from JavaScript, where every file *is* a module.

**In Rust, a file does nothing until a `mod` declaration includes it.** The compiler starts at the
crate root (`lib.rs`), and builds the module tree from `mod` declarations:

```text
          file tree                               module tree (what the compiler sees)

src/lib.rs          pub mod errors;     ──▶  crate                    (src/lib.rs)
                    pub mod customers;         ├── errors              (src/errors.rs)
                    pub mod cli;               ├── customers           (src/customers/mod.rs)
src/errors.rs                                  │   ├── email           (src/customers/email.rs)
src/customers/mod.rs  mod email;               │   ├── model           (src/customers/model.rs)
                      mod model;               │   └── store           (src/customers/store.rs)
                      mod store;               └── cli                 (src/cli/mod.rs)
src/customers/email.rs                             ├── parser          (src/cli/parser.rs)
...                                                └── commands        (src/cli/commands.rs)
```

`mod errors;` (with a semicolon) means "there's a module called `errors`; its contents are in
`errors.rs` next to me, or in `errors/mod.rs`". If you create `src/oops.rs` and never write
`mod oops;`, the compiler never even opens it.

You can also write a module **inline**: `mod errors { ... }` with braces. The `#[cfg(test)] mod tests { ... }`
blocks you've been writing since Lab 05 are exactly that: an inline child module. That's why
they start with `use super::*;`.

### `mod.rs` vs `name.rs`

For a module with children, like `customers`, Rust accepts two layouts:

```text
src/customers/mod.rs        ← "mod.rs style"
src/customers/email.rs

src/customers.rs            ← "name.rs style" (Rust 2018+)
src/customers/email.rs
```

Both mean the same thing. The newer style avoids having many editor tabs called `mod.rs`; the
older one keeps everything about a module inside its own folder. **This course uses `mod.rs`
consistently**, so a module and all its files always live in one directory you can see at a
glance. Pick one style per project and stick to it.

### Paths and the privacy rule

You name an item by its **path** through the module tree:

| Path | Means |
|---|---|
| `crate::errors::CrmError` | from the root of the **current** crate |
| `super::Email` | from the parent module |
| `self::model::Customer` | from the current module (rarely needed) |
| `rust_crm::customers::Email` | from **another** crate, by name (how `main.rs` sees the library) |

`use` creates a shortcut, so you don't repeat long paths.

And the one rule for privacy:

> **Everything is private by default. A private item is visible in the module that defines it,
> and in that module's descendants. `pub` makes it visible to the parent too, and so on up, as
> far as the parents are themselves visible.**

The variants on `pub`:

| Visibility | Who can see it |
|---|---|
| (nothing) | this module and its children |
| `pub(super)` | also the parent module |
| `pub(crate)` | anywhere in this crate, but not other crates |
| `pub` | anyone who can reach the module, including other crates |

Two special cases: **struct fields** are private by default even when the struct is `pub` (you
mark each field); **enum variants** are always as public as the enum.

---

## Step 3 — Create the library crate, starting with `errors`

Work in small steps and run `cargo check` after each. Start with the module everything else
depends on.

> 🟢 **FOLLOW ALONG**: create `src/lib.rs`:

```rust
//! Rust CRM: the library behind the `rust-crm` binary.

pub mod errors;
```

`//!` is a doc comment for the enclosing item, here the whole crate. Now create `src/errors.rs`
and **move** (cut, don't copy) `ValidationError`, `CrmError`, their `Display` and `Error` impls,
and `impl From<ValidationError> for CrmError` out of `main.rs` into it. Add `pub` to the two
enums:

```rust
//! Error types shared by the whole CRM.

use std::fmt;

/// Why a piece of user input was rejected.
#[derive(Debug, PartialEq)]
pub enum ValidationError {
    EmptyName,
    InvalidEmail(String),
    InvalidPhone(String),
}

// impl fmt::Display for ValidationError { ... }   (unchanged)
// impl std::error::Error for ValidationError {}

/// Everything that can go wrong while running a CRM command.
#[derive(Debug)]
pub enum CrmError {
    NotFound(u32),
    DuplicateEmail(String),
    Validation(ValidationError),
    UnknownCommand(String),
    Usage(&'static str),
}

// impl fmt::Display for CrmError { ... }          (unchanged)
// impl std::error::Error for CrmError {}
// impl From<ValidationError> for CrmError { ... } (unchanged)
```

Variants don't need `pub`: they're as visible as their enum. Trait impls don't need `pub`
either: an `impl` is visible wherever both the trait and the type are.

Move the `validation_errors_convert_into_crm_errors` test too, into a `#[cfg(test)] mod tests`
at the bottom of `errors.rs` (with `use super::*;`). **Tests travel with the code they test.**

In `main.rs`, the binary now needs to import from the library, **by crate name**:

```rust
use std::io::{self, Write};

use rust_crm::errors::{CrmError, ValidationError};
```

(Remove `use std::fmt;` from `main.rs` if nothing there uses it any more.) Run `cargo test`.
Everything passes, and the output now has an extra section: the library's own unit tests run
separately from the binary's.

Notice what just happened: `main.rs` and `lib.rs` are two different crates. From inside the
library, the errors are `crate::errors::CrmError`. From the binary, they're
`rust_crm::errors::CrmError`. Same type, two vantage points.

---

## Step 4 — The `customers` module

Create the folder and its root:

> 🟢 **FOLLOW ALONG**: `src/customers/mod.rs`

```rust
//! Customers: who they are, how they're validated and where they're kept.

mod email;
mod model;
mod store;

pub use email::Email;
pub use model::{Customer, CustomerStatus, initials, parse_name, parse_phone};
pub use store::CustomerStore;
```

and add `pub mod customers;` to `lib.rs`.

Read this carefully, because it's the most important design move in the lab:

- `mod email;`, `mod model;`, `mod store;` are **private**. Outside `customers`, nobody can write
  `customers::model::Customer`. The file layout is an implementation detail.
- `pub use` **re-exports** chosen items, so the public paths are `customers::Customer`,
  `customers::Email`, and so on. If you later move `Customer` to another file, its public path
  doesn't change, and nothing outside `customers` breaks.

Think of `mod.rs` as the module's front desk: it decides what visitors see.

### `email.rs`: privacy that means something

> 🟢 **FOLLOW ALONG**: move `Email` into `src/customers/email.rs`.

```rust
use crate::errors::ValidationError;

/// An email address that has passed validation.
///
/// The field is private, so the only way to get an `Email` is through
/// [`Email::parse`]. If you hold an `Email`, it is valid: trimmed,
/// lowercase, with exactly one `@` and a dot in the domain.
#[derive(Debug, Clone, PartialEq)]
pub struct Email(String);

impl Email {
    /// Validates `input` and turns it into an `Email`.
    pub fn parse(input: &str) -> Result<Email, ValidationError> {
        // body unchanged from Lab 12
    }

    /// The address as text.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    // If you did Lab 12's Your Turn 4: `pub fn domain(&self) -> &str`, unchanged.
}
```

`pub struct Email(String);` makes the **type** public but leaves the **field** private: `String`
has no `pub` in front of it. Only code inside `customers::email` can touch `.0` or write
`Email(...)`. Move the `Email` tests into a `mod tests` at the bottom of this file.

`use crate::errors::ValidationError;` is a path from the root of the library crate. (`super::`
would mean `customers`, which doesn't have it.)

### `model.rs` and `store.rs`: your turn

> 🔵 **YOUR TURN** (mini-task): move the rest of the customer code yourself.

- [ ] `src/customers/model.rs` gets `CustomerStatus`, `Customer`, `parse_name`, `parse_phone`,
      `initials` (and `email_domain`, if you skipped Lab 12's Your Turn 4), plus their tests
- [ ] `src/customers/store.rs` gets `CustomerStore`, the `next_id` helper (keep it private), and
      their tests
- [ ] Add `use` lines at the top of each file for what it needs: siblings through the parent's
      re-exports (`use super::{Customer, Email};`), errors through `crate::errors`
- [ ] **Don't add any `pub` yet.** Remove the moved code from `main.rs`, and import from the library
      instead: `use rust_crm::customers::{...};`

Then run `cargo check`. You'll see something like this, many times:

```text
error[E0624]: method `summary` is private
  --> src/main.rs:...
   |
   |                 println!("{}", customer.summary());
   |                                         ^^^^^^^ private method
   |
  ::: src/customers/model.rs:56:5
   |
56 |     fn summary(&self) -> String {
   |     --------------------------- private method defined here

error[E0616]: field `name` of struct `Customer` is private
   |
   |             println!("  Initials: {}", initials(&customer.name));
   |                                                           ^^^^ private field
```

This is the privacy rule working. `main.rs` is another crate; it can only use what the library
makes `pub`. Each error is a question: **should this be part of the public API?** Decide, don't
just add `pub` everywhere:

| Item | `pub`? | Why |
|---|---|---|
| `CustomerStatus`, `parse`, `label` | yes | callers need to read and parse statuses |
| `Customer` and its methods | yes | it's the thing the CRM is about |
| `Customer`'s **fields** | yes | none of them has an invariant the struct must protect: `email` is an `Email` (already valid), `status` is an enum (already valid), `name` and `phone` have no rules once stored |
| `parse_name`, `parse_phone`, `initials` | yes | the CLI uses them |
| `CustomerStore` and its methods | yes | |
| `CustomerStore`'s **fields** | **no** | the store promises unique emails and sequential ids. With `pub customers`, anyone could `push` a duplicate or with `pub next_id`, reset the counter |
| `next_id` (the helper fn) | no | an implementation detail of `add` |

The rule of thumb: **make a field public when every possible value of it is valid. Make it
private when the struct has to protect a relationship between values** (like "no two customers
in `customers` share an email").

After adding the `pub`s, run `cargo clippy`. Making things public woke up two lints:

```text
warning: you should consider adding a `Default` implementation for `CustomerStore`
   --> src/customers/store.rs:12:5
    |
 12 | /     pub fn new() -> Self {
...
    = note: `#[warn(clippy::new_without_default)]` on by default

warning: struct `CustomerStore` has a public `len` method, but no `is_empty` method
  --> src/customers/store.rs:62:5
   |
62 |     pub fn len(&self) -> usize {
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^
   = note: `#[warn(clippy::len_without_is_empty)]` on by default
```

Clippy holds public APIs to a higher standard, because other code will rely on them. Follow its
advice:

```rust
impl CustomerStore {
    // ...
    pub fn is_empty(&self) -> bool {
        self.customers.is_empty()
    }
}

impl Default for CustomerStore {
    fn default() -> Self {
        Self::new()
    }
}
```

`Default` is the standard trait for "a sensible empty value"; generic code (Lab 16) and
`#[derive(Default)]` on structs that contain a store rely on it. Once `is_empty` exists, Clippy
also suggests using it instead of `store.len() == 0` in the `List` arm. Do that too.

> 🟡 **EXPERIMENT**: now try the forgery from Step 1 again, in `main.rs`:
>
> ```rust
>     let fake = Email(String::from("definitely not an email"));
> ```

```text
error[E0423]: cannot initialize a tuple struct which contains private fields
  --> src/main.rs:4:16
   |
 4 |     let fake = Email(String::from("definitely not an email"));
   |                ^^^^^
   |
   = note: a struct named `Email` exists in another namespace
note: constructor is not visible here due to private fields
  --> src/customers/email.rs:26:18
   |
26 | pub struct Email(String);
   |                  ^^^^^^ private field
```

The hole is closed. `Email(...)` is a constructor, and a constructor is only usable where all
the fields are visible. Try the same line later from inside the library (say in
`cli/commands.rs`, after Step 5) and the error gains a `help:` line suggesting
`pub struct Email(pub String);`. That would compile, and it would throw away the whole point of
`Email`. Now you know why not. Remove the line.

---

## Step 5 — The `cli` module

Everything left in `main.rs` is about the terminal: reading lines, parsing commands, running
them, printing. That's the `cli` module.

> 🟢 **FOLLOW ALONG**: `src/cli/parser.rs`. Move `Command`, `STATUS_USAGE`, `parse_command`,
> `parse_id`, `parse_page` and the parser tests here. The top of the file:

```rust
use crate::customers::CustomerStatus;
use crate::errors::CrmError;

/// A command typed at the `crm>` prompt, already checked and converted to real types.
#[derive(Debug, PartialEq)]
pub(crate) enum Command<'a> {
    // variants unchanged
}

const STATUS_USAGE: &str = "status <id> <prospect|active|churned>";

/// Turns one input line into a `Command`.
/// `Ok(None)` means a blank line; `Err` means the line made no sense.
pub(crate) fn parse_command(input: &str) -> Result<Option<Command<'_>>, CrmError> {
    // body unchanged
}

fn parse_id(args: &[&str]) -> Option<u32> { /* unchanged */ }
fn parse_page(args: &[&str]) -> Option<usize> { /* unchanged */ }
```

`pub(crate)` means "the rest of this crate may use it, other crates may not". The `Command` enum
is how the CLI talks to itself. It's not something the web server or the tests should depend
on, so it doesn't belong in the library's public API. `parse_id` and `parse_page` stay fully
private: only the parser uses them.

> 🟢 **FOLLOW ALONG**: `src/cli/commands.rs`. Move `execute`, `colleague_note` and `print_help`
> here, plus the `execute`/`colleague_note` tests. The top of the file:

```rust
use super::parser::Command;
use super::{APP_NAME, PAGE_SIZE, prompt};
use crate::customers::{CustomerStatus, CustomerStore, Email, initials, parse_name, parse_phone};
use crate::errors::CrmError;

/// Runs one command against the store. Printing happens here; errors are returned.
pub(crate) fn execute(store: &mut CustomerStore, command: Command) -> Result<(), CrmError> {
    // body unchanged
}
```

(Adjust the `crate::customers` import to what your `execute` actually uses; the compiler will
tell you about anything missing or unused.)

> 🟢 **FOLLOW ALONG**: `src/cli/mod.rs`. The REPL loop becomes `pub fn run()`.

```rust
//! The interactive terminal interface: the `crm>` prompt.

mod commands;
mod parser;

use std::io::{self, Write};

use crate::customers::CustomerStore;
use parser::Command;

const APP_NAME: &str = "Rust CRM";
const PAGE_SIZE: usize = 5;

/// Runs the interactive CRM until the user quits (or stdin closes).
pub fn run() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    let mut store = CustomerStore::new();
    let mut count = 0;

    let commands_run = loop {
        // ... the loop body from main, unchanged, except:
        let result = match parser::parse_command(&input) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break count,
            Ok(Some(command)) => commands::execute(&mut store, command),
            Err(e) => Err(e),
        };
        // ...
    };

    println!("Goodbye! ({commands_run} commands this session)");
}

/// Prints `label`, reads one line and returns it trimmed.
fn prompt(label: &str) -> String {
    // unchanged
}
```

Look at `prompt`, `APP_NAME` and `PAGE_SIZE`: they're **private** to `cli`, yet `commands.rs`
uses them through `use super::{APP_NAME, PAGE_SIZE, prompt};`. That's the privacy rule's second
half: **children can see their parent's private items.** `commands` is a child of `cli`, so it's
"inside" `cli`'s privacy boundary. `customers` isn't, so it can't call `prompt`, which is
exactly right: the domain code shouldn't be doing terminal I/O.

Add `pub mod cli;` to `lib.rs`. The finished crate root:

```rust
//! Rust CRM: the library behind the `rust-crm` binary.

pub mod cli;
pub mod customers;
pub mod errors;
```

And `main.rs`, the whole file:

```rust
fn main() {
    rust_crm::cli::run();
}
```

The binary is now a thin shell around the library. In Lab 27 you'll have a second binary, a
web server, that calls different library functions, and the two will share every line of
domain code.

Run `cargo fmt`, `cargo clippy`, `cargo test`. Fix whatever the compiler points at: usually a
missing `use`, a missing `pub`, or a test helper that stayed behind in the wrong file.

---

## Step 6 — Documentation is part of the API

You've been writing `///` comments here and there. Now that there's a public API, they become
real documentation.

- `///` documents the item **after** it.
- `//!` documents the item it's **inside** (a module or crate), at the top of the file.
- Doc comments are Markdown: backticks for code, `[`Email::parse`]` for links to other items.

> 🟢 **FOLLOW ALONG**: generate and open the docs.

```bash
cargo doc --no-deps --open
```

Your browser shows `rust_crm` the way docs.rs shows any crate: modules `cli`, `customers`,
`errors`; in `customers`, the re-exported types. Notice what's **not** there: `model`, `store`,
`email` (private modules), `Command` and `execute` (`pub(crate)`), `prompt` (private). The docs
are a picture of your public API. If something shows up that shouldn't, it's too visible.

### Doc tests

Code blocks in doc comments are compiled and run by `cargo test`. Add an example to
`Email::parse`:

> 🟢 **FOLLOW ALONG**

```rust
    /// Validates `input` and turns it into an `Email`.
    ///
    /// ```
    /// use rust_crm::customers::Email;
    ///
    /// let email = Email::parse("  Ada@Example.COM ").unwrap();
    /// assert_eq!(email.as_str(), "ada@example.com");
    ///
    /// assert!(Email::parse("not-an-email").is_err());
    /// ```
    pub fn parse(input: &str) -> Result<Email, ValidationError> {
```

A doc test is compiled as **a separate crate that depends on yours**, so it must `use` the item
by its public path, and it can only use public items. It's documentation that can't go out of
date, and a free check that the public path works. (`unwrap` is fine here: it's a test.)

Doc tests only exist for **library** crates. That's one more thing you couldn't do before
today.

---

## ▶️ Run It

```bash
cargo run
cargo test
```

## ✅ Expected Result

The CRM behaves exactly as at the end of Lab 12:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone (optional): 555-0100
Added customer #1
crm> add
Name: Charles Babbage
Email: charles@example.com
Phone (optional):
Added customer #2
Note: #1 Ada Lovelace also uses example.com.
crm> show 2
#2 Charles Babbage <charles@example.com> [prospect]
(no phone on file)
  Domain:   example.com
  Initials: CB
crm> bogus
Error: unknown command 'bogus' (type 'help' for a list of commands)
crm> quit
Goodbye! (4 commands this session)
```

And `cargo test` now runs three groups:

```text
     Running unittests src/lib.rs (target/debug/deps/rust_crm-...)
test result: ok. 29 passed; 0 failed; ...

     Running unittests src/main.rs (target/debug/deps/rust_crm-...)
test result: ok. 0 passed; 0 failed; ...

   Doc-tests rust_crm
test result: ok. 1 passed; 0 failed; ...
```

(Your unit-test count depends on how many tests you wrote in earlier labs.) The binary has no
tests left, because it has no logic left. `cargo clippy` is clean, including the `dead_code`
warnings you may have had about `has_phone` or `all`: `pub` items in a library are never
"dead", because another crate might use them.

## 🧠 Understand It

### Privacy protects invariants, not secrets

Rust's privacy isn't about hiding code from other developers; they can read your source. It's
about **who is allowed to break which promise**:

- `Email`'s field is private → only `customers::email` can create or change an `Email` → every
  `Email` in the program went through `parse` → every `Email` is valid. One module to audit
  instead of the whole program.
- `CustomerStore`'s fields are private → only `store.rs` can touch the `Vec` → ids are unique and
  emails don't repeat, as long as `store.rs` is correct.
- `Customer`'s fields are public → anyone can change a name. That's fine, because no promise
  depends on names.

There's one gap worth noticing. `find_mut` hands out a `&mut Customer`, and `email` is a public
field, so a caller could do `store.find_mut(1).unwrap().email = other_customers_email` and create
a duplicate. The `Email` type guarantees each email is *valid*; it can't guarantee they're
*unique*, because uniqueness is about the whole collection. Today, `execute`'s `Update` arm
checks it, but that's the CLI enforcing a business rule. Lab 14 moves rules like this into one
place, a `Crm` type, and says why.

### `pub` vs `pub(crate)` vs private: choosing

Ask "who **needs** this?":

- Another crate (tests in `tests/`, the server, examples) → `pub`, and reachable through a
  `pub` path.
- Other modules in this crate, but it's an internal detail → `pub(crate)`.
- Only this module (and its children) → private, the default.

Start private and open things up when the compiler tells you someone needs them. The reverse,
making things private later, breaks code that started depending on them.

### Why the library/binary split matters

```text
               rust_crm (library)
             ┌────────────────────┐
             │ errors  customers  │
             │ cli                │
             └─────────▲──────────┘
        ┌──────────────┼───────────────┬─────────────────┐
   src/main.rs     tests/*.rs      examples/*.rs     (Lab 27) the server
   (the REPL)      (Lab 24)        (Lab 14, YT 3)
```

Each consumer is a separate crate that sees only the library's `pub` API. That's also why
integration tests in Lab 24 will be **better** tests: they can only do what a real user of your
library can do.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: a module declared twice.** Add `mod customers;` at the top of `main.rs`
> and run `cargo check`.

```text
error[E0432]: unresolved import `crate::errors`
 --> src/customers/email.rs:1:12
  |
1 | use crate::errors::ValidationError;
  |            ^^^^^^ could not find `errors` in the crate root

error[E0432]: unresolved import `crate::errors`
 --> src/customers/model.rs:2:12
  |
2 | use crate::errors::ValidationError;
  |            ^^^^^^ could not find `errors` in the crate root
...
warning: unused imports: `initials`, `parse_name`, and `parse_phone`
```

`mod customers;` in `main.rs` makes the **binary** crate compile the `customers` files a second
time, as its own module. Inside that copy, `crate::` means the binary crate, which has no
`errors` module. Lesson: **a file belongs to exactly one place in one module tree.** The binary
reaches library code through `rust_crm::`, never with `mod`. Remove the line.

> 🟡 **EXPERIMENT 2: reaching past the front desk.** In `cli/commands.rs`, add
> `use crate::customers::model::Customer;` and `cargo check`.

```text
error[E0603]: module `model` is private
 --> src/cli/commands.rs:5:23
  |
5 | use crate::customers::model::Customer;
  |                       ^^^^^ private module
  |
note: the module `model` is defined here
 --> src/customers/mod.rs:4:1
  |
4 | mod model;
  | ^^^^^^^^^^
help: consider importing this struct through its public re-export instead
  |
5 - use crate::customers::model::Customer;
5 + use crate::customers::Customer;
```

The compiler knows about your re-export and points you to it. Remove the line.

> 🟡 **EXPERIMENT 3: forget a `pub`.** Change `pub fn run()` in `cli/mod.rs` to `fn run()`.
> Predict the errors, then run `cargo check`.

```text
error[E0603]: function `run` is private
  --> src/main.rs:2:20
   |
 2 |     rust_crm::cli::run();
   |                    ^^^ private function
```

You'll also get `dead_code` warnings for `run`, `prompt`, `execute` and more: with `run`
private, nothing outside the library can reach them, and nothing inside calls them. Put the
`pub` back.

> 🟡 **EXPERIMENT 4:** in `customers/mod.rs`, change `mod store;` to `pub mod store;`. Run
> `cargo doc --no-deps --open`. What new item appears in the docs? Is there any reason to want
> both `customers::CustomerStore` and `customers::store::CustomerStore` as public paths? Undo it.

## 👩🏽‍💻 Your Turn

### Your Turn 1 — Prove the privacy with a `compile_fail` doc test

> 🔵 **YOUR TURN**: a doc test marked ` ```compile_fail ` passes only if the code **fails** to
> compile. Use that to write a test that proves `Email` can't be forged.

- [ ] In `Email`'s doc comment (on the struct), add a `compile_fail` example that tries to build
      an `Email` directly from a `String`
- [ ] Add a second `compile_fail` example that tries to modify the inside of a parsed `Email`
- [ ] Add a normal doc test to `CustomerStatus::parse` showing one accepted and one rejected input
- [ ] `cargo test` shows all of them under `Doc-tests rust_crm`
- [ ] Check that the `compile_fail` tests really guard something: temporarily make the field
      `pub String` and watch them fail. Then undo it

### Your Turn 2 — One function per command

> 🔵 **YOUR TURN**: `execute` in `cli/commands.rs` is one long `match`. Turn it into a
> dispatcher.

- [ ] Each arm of `execute` becomes a single call: `Command::Add => add(store)?`,
      `Command::Show { id } => show(store, id)?`, and so on
- [ ] Each private handler function takes the **least** access it needs: `&CustomerStore` for
      commands that only read, `&mut CustomerStore` for those that write
- [ ] Handlers that can't fail return `()`; those that can return `Result<(), CrmError>`
- [ ] Behaviour and output are unchanged; existing tests pass

### Your Turn 3 — The library's first other user

> 🔵 **YOUR TURN**: create `examples/seed.rs`, a program that uses the library **only through
> its public API**, and run it with `cargo run --example seed`.

```text
$ cargo run --example seed
#1 Ada Lovelace <ada@example.com> 555-0100 [active]
#2 Grace Hopper <grace@example.com> [prospect]
rejected: 'nope' is not a valid email address
```

- [ ] Creates a `CustomerStore`, adds two customers, makes Ada active, and prints every
      customer's summary
- [ ] Shows that `Email::parse("nope")` is rejected, printing the error with `{}`
- [ ] `fn main() -> Result<(), CrmError>`, using `?` for the calls that can fail
- [ ] No `unwrap` or `expect`
- [ ] `cargo clippy --all-targets` is clean (`--all-targets` includes examples and tests)

## 💡 Hint

> 💡 **HINT**: for Your Turn 1, a doc test is a separate crate, so each example needs its own
> `use rust_crm::customers::Email;` line, exactly like the `parse` example.

<details><summary>Hint 2: Your Turn 2</summary>

`fn list(store: &CustomerStore, page: usize)`, `fn show(store: &CustomerStore, id: u32) -> Result<(), CrmError>`,
`fn update(store: &mut CustomerStore, id: u32) -> Result<(), CrmError>`. Inside `execute`,
`store` is a `&mut CustomerStore`; passing it to a function that wants `&CustomerStore` works
(it's reborrowed as shared for the call). The status rules make a nice
`fn change_status(store: &mut CustomerStore, id: u32, status: CustomerStatus) -> Result<(), CrmError>`.

</details>

<details><summary>Hint 3: Your Turn 3</summary>

`examples/` is a folder at the **package** root, next to `src/`, not inside it. Each file there
is its own binary crate that can `use rust_crm::...`. With `main` returning `Result`, `?` works
in `main` too. Be careful with `Email::parse("nope")?`: what would `?` do with that error?
Try it and see what `main` prints when it returns `Err`.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. What's the difference between a package, a crate and a module? How many crates does your
   package have now?
2. You create `src/customers/notes.rs`. What else must happen before the compiler reads it?
3. State the privacy rule in one sentence. Why can `cli/commands.rs` call the private `prompt`
   in `cli/mod.rs`, while `customers` can't?
4. Why is `Email`'s field private but `Customer`'s fields public?
5. What does `pub use model::Customer;` in `customers/mod.rs` buy you?
6. Inside the library, `crate::errors::CrmError`; inside `main.rs`, `rust_crm::errors::CrmError`.
   Why two different paths for the same type?
7. Why did making `CustomerStore` public produce new Clippy warnings?
8. Which two later labs need the library crate, and why can't they use a binary crate?

Then verify:

```bash
cargo fmt --check && cargo clippy --all-targets && cargo test
```

## Git Commit

```bash
git add .
git commit -m "Split CRM into library modules"
git tag lab-13
git push && git push --tags
```

Try `git diff --stat lab-12 lab-13`. Almost every line of `main.rs` was deleted and re-added
somewhere else. Git may show it as a huge diff, but `git log --follow src/customers/email.rs`
can still trace where the code came from.

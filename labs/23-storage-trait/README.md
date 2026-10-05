# Lab 23 — Traits as Boundaries: The Storage Layer ♻️

> **Phase:** 6 — Persistence & Quality · **Builds on:** Lab 22 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-22` · **After:** tag `lab-23`

## 🎯 Goal
Hide *where* the CRM's data lives behind a `Storage` trait with two implementations,
`InMemoryStorage` and `JsonFileStorage`. The user picks one at start-up with
`--storage memory|json`, and the REPL never knows which one it got.

## 🧠 What You'll Learn
- **Trait objects** (`dyn Storage`): what's actually in memory. Fat pointers and vtables, with
  real sizes measured.
- **Static vs dynamic dispatch**: generics (`S: Storage`) vs `Box<dyn Storage>`, and why a choice
  made at runtime forces the second
- **Dyn compatibility** (formerly "object safety"): which traits can become `dyn Trait`, and why.
  You'll trigger a real E0038.
- `&dyn` vs `Box<dyn>` vs generics vs enums: a decision table
- **Dependency injection** in Rust: pass the dependency in, decide it in one place
- **Provided (default) methods** in traits
- `clap` derive for command-line arguments, including `ValueEnum`, defaults and **environment
  variables** (`CRM_DATA_FILE`)
- Why `std::env::set_var` is `unsafe` in edition 2024, and how that shapes your tests

## 🔨 What We're Building
Look at `cli::run` from Lab 22. It calls `storage::load(path)` and `storage::save(&crm, path)`
directly, with a hard-coded `DATA_FILE`. The REPL **knows** it's talking to a JSON file. That has
costs right now:

- You can't try the CRM without touching (or creating) `crm-data.json`.
- You can't point it at a different file without recompiling.
- Lab 24 wants to test code that saves data, without a disk.

And bigger costs later: Lab 27 adds an HTTP server that needs the same storage, and Lab 30 brings
PostgreSQL. If every caller knows about JSON files, every caller has to change.

The fix is a **boundary**: a trait that says *what* storage can do (load a `Crm`, save a `Crm`),
and implementations that decide *how*:

```text
                 main.rs  ── the only place that knows which one ──┐
                                                                   │ Box<dyn Storage>
 ┌───────────────────┐        ┌───────────────────────────┐        ▼
 │ cli::run          │ ─────► │ trait Storage             │ ◄── impl ── JsonFileStorage { path }
 │ (REPL)            │ uses   │   load(&self) -> Crm      │ ◄── impl ── InMemoryStorage
 └───────────────────┘        │   save(&self, &Crm)       │ ◄── impl ── (Lab 24: test doubles)
                              └───────────────────────────┘
```

> 📌 **About the shape of this trait.** `Storage` loads and saves the **whole CRM** as one
> snapshot. That's right for a JSON file. It is *wrong* for PostgreSQL: you don't load every row
> to change one email. In Labs 30–31 the boundary idea carries forward but its **shape** changes
> (per-entity async queries instead of whole-snapshot load/save), and you'll see exactly why. A
> trait is a promise about behaviour, so design it around what your callers really do.

---

## Step 1 — Dependency injection, in one sentence

> **Code shouldn't create the things it depends on. It should receive them.**

Today `cli::run` *creates* its storage (it picks the file name and calls the functions). After
this lab, `cli::run` *receives* a storage as a parameter, and `main` creates it. That's all
"dependency injection" means: no framework, no container, just a parameter.

In TypeScript you'd write an `interface Storage { load(): Crm; save(crm: Crm): void }` and pass any
object that fits. Rust's version is a **trait**, with two important differences:

1. **Implementations are explicit.** A type implements `Storage` only if someone writes
   `impl Storage for X`. TypeScript accepts anything with the right shape. Rust checks the impl.
2. **You choose how calls are dispatched.** A trait can be used *statically* (generics: the
   compiler knows the exact type and generates code for it) or *dynamically* (`dyn Storage`: the
   type is looked up at runtime). TypeScript only has the dynamic version. Most of this lab is
   about that choice.

---

## Step 2 — `storage.rs` becomes a module with a trait

The storage code is about to have three parts (trait, JSON backend, memory backend). Lab 13's
rule: when a file grows parts, it becomes a directory.

```bash
mkdir src/storage
git mv src/storage.rs src/storage/json_file.rs
```

`git mv` tells git it's the same file, renamed, so `git log --follow` keeps its history.

> 🟢 **FOLLOW ALONG**: create `src/storage/mod.rs`

```rust
//! Where the CRM's data lives. The rest of the program only sees the
//! `Storage` trait, never a concrete backend.

mod json_file;
mod memory;

use std::io;
use std::path::PathBuf;

use thiserror::Error;

use crate::crm::Crm;

pub use json_file::JsonFileStorage;
pub use memory::InMemoryStorage;

/// Loads and saves a whole snapshot of the CRM.
pub trait Storage {
    fn load(&self) -> Result<Crm, StorageError>;
    fn save(&self, crm: &Crm) -> Result<(), StorageError>;
}

// Move `StorageError` here, unchanged, from json_file.rs
#[derive(Debug, Error)]
pub enum StorageError {
    // ... Read, Write, Parse exactly as in Lab 22 ...
}
```

- **`StorageError` belongs to the trait, not to one backend.** Every implementation returns it.
  Later backends might add variants. (Lab 30's Postgres code gets its own error type anyway.)
- **`mod json_file;` is private, `pub use json_file::JsonFileStorage;` is public.** Callers write
  `rust_crm::storage::JsonFileStorage`. The file layout is an internal detail you can change
  later without breaking anyone (Lab 13's re-export pattern).
- **`&self` on both methods, even `save`.** Saving doesn't change the *storage object*. It changes
  the file. The storage object is just a handle (here: a path). Keeping both methods `&self` will
  matter in Lab 25, where a background thread and the REPL share one storage.

Now turn the free functions in `src/storage/json_file.rs` into a type:

> 🟢 **FOLLOW ALONG**: top of `src/storage/json_file.rs` (delete the `StorageError` definition
> from this file; you moved it)

```rust
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use super::{Storage, StorageError};
use crate::crm::Crm;

/// Stores the whole CRM as one pretty-printed JSON document.
#[derive(Debug, Clone)]
pub struct JsonFileStorage {
    path: PathBuf,
}

impl JsonFileStorage {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        JsonFileStorage { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Storage for JsonFileStorage {
    fn load(&self) -> Result<Crm, StorageError> {
        load(&self.path)
    }

    fn save(&self, crm: &Crm) -> Result<(), StorageError> {
        save(crm, &self.path)
    }
}
```

Then change `pub fn load` and `pub fn save` below it to plain `fn load` / `fn save`. They're now
private helpers. Keep `write_atomically`, `tmp_path` and the tests exactly as they are. The tests
are a child module, so they can still call the private functions.

- **`new(path: impl Into<PathBuf>)`** accepts a `&str`, a `String`, a `PathBuf` or a `&Path`.
  Inside, `.into()` converts to the owned `PathBuf` the struct stores. Callers get convenience,
  and the struct owns its data (no lifetime parameter needed).
- **`path(&self) -> &Path`** hands out a *borrowed view* of the owned `PathBuf`, the same pattern
  as `as_str()` on `Email`.
- **Inside `impl Storage`, `load(&self.path)` calls the free function `load`,** not the method:
  a plain `load(...)` call (no receiver) resolves to the function in scope. If that reads
  confusingly to you, rename the helpers `read_file` / `write_file`.

`cargo check` now complains that `cli/mod.rs` can't find `storage::load`. Good. We'll fix `cli`
in Step 4.

---

## Step 3 — The second implementation

> 🔵 **YOUR TURN 1: `InMemoryStorage`**
>
> In `src/storage/memory.rs`, write a storage that **keeps nothing**:
>
> - [ ] `pub struct InMemoryStorage;`, a unit struct (no fields), deriving at least `Debug`,
>   `Default`, `Clone` and `Copy`
> - [ ] `impl Storage for InMemoryStorage`: `load` returns an empty `Crm`, `save` succeeds and does
>   nothing
> - [ ] a doc comment that says what it's for, so nobody is surprised that data disappears
> - [ ] two unit tests in the same file: `load_starts_empty` and `save_keeps_nothing` (save a CRM
>   with one company, then `load` again: still empty)
> - [ ] no compiler warning about an unused parameter

Why build a storage that doesn't store? It's the **simplest possible implementation**, and it
proves the trait isn't secretly JSON-shaped. It's genuinely useful too: `--storage memory` lets
you demo or experiment without touching your real data. (In Lab 24 you'll write a test double
that remembers what was saved.)

---

## Step 4 — First attempt: generics

You already know one way to accept "any type that implements a trait": generics (Lab 16).

> 🟢 **FOLLOW ALONG**: in `src/cli/mod.rs`

```rust
use crate::storage::Storage;

pub fn run<S: Storage>(storage: S) -> anyhow::Result<()> {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    let mut crm = storage
        .load()
        .context("refusing to start, so the data file is not overwritten")?;
    println!(
        "Loaded {}, {}, {}, {}",
        count(crm.companies.len(), "company", "companies"),
        count(crm.contacts.len(), "contact", "contacts"),
        count(crm.deals.len(), "deal", "deals"),
        count(crm.leads.len(), "lead", "leads"),
    );
    // ... loop unchanged, except the save:
    //             if let Err(e) = storage.save(&crm) {
```

Delete `DATA_FILE` and `use std::path::Path;` from this file. `cli` no longer knows about files.

Now `main` must choose. Let's pretend for a moment that a `--memory` flag selects the memory
backend:

> 🟡 **EXPERIMENT**: predict, then `cargo check`.

```rust
// src/main.rs
use rust_crm::storage::{InMemoryStorage, JsonFileStorage};

fn main() -> anyhow::Result<()> {
    let use_memory = std::env::args().any(|arg| arg == "--memory");
    let storage = if use_memory {
        InMemoryStorage
    } else {
        JsonFileStorage::new("crm-data.json")
    };
    rust_crm::cli::run(storage)
}
```

```text
error[E0308]: `if` and `else` have incompatible types
 --> src/main.rs:8:9
  |
5 |       let storage = if use_memory {
  |  ___________________-
6 | |         InMemoryStorage
  | |         --------------- expected because of this
7 | |     } else {
8 | |         JsonFileStorage::new("crm-data.json")
  | |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ expected `InMemoryStorage`, found `JsonFileStorage`
9 | |     };
  | |_____- `if` and `else` have incompatible types
```

**Read the error.** Every variable has exactly **one** type, fixed at compile time, and it decides
the variable's size on the stack. `InMemoryStorage` is 0 bytes and `JsonFileStorage` is 24 bytes
(a `PathBuf`: pointer, length, capacity). Which one should `storage` be? Both implement the same
trait, but a trait isn't a type. It's a *set of types*.

Generics work by **monomorphization** (Lab 16): the compiler stamps out a separate copy of
`run::<InMemoryStorage>` and `run::<JsonFileStorage>`. The choice happens *at compile time, per
call site*. Here the choice depends on a command-line argument, which only exists at runtime.

One fix keeps generics: call `run` in each branch.

```rust
if use_memory {
    rust_crm::cli::run(InMemoryStorage)
} else {
    rust_crm::cli::run(JsonFileStorage::new("crm-data.json"))
}
```

That compiles, and it's legitimate. Your binary simply contains two copies of the whole REPL. With
two backends that's fine. With five, plus wrappers (Lab 25 adds threads), the branching gets
silly. What we really want is a single value that says "some storage, decided at runtime".

---

## Step 5 — Trait objects: `Box<dyn Storage>`

`dyn Storage` means "a value of *some* type that implements `Storage`; which type is known only at
runtime". It has no fixed size (it could be 0 bytes or 24), so it can only live **behind a
pointer**: `&dyn Storage`, `Box<dyn Storage>`, `Arc<dyn Storage>`.

> 🟢 **FOLLOW ALONG**

```rust
// src/cli/mod.rs
pub fn run(storage: Box<dyn Storage>) -> anyhow::Result<()> {
```

```rust
// src/main.rs
use rust_crm::storage::{InMemoryStorage, JsonFileStorage, Storage};

fn main() -> anyhow::Result<()> {
    let use_memory = std::env::args().any(|arg| arg == "--memory");
    let storage: Box<dyn Storage> = if use_memory {
        Box::new(InMemoryStorage)
    } else {
        Box::new(JsonFileStorage::new("crm-data.json"))
    };
    rust_crm::cli::run(storage)
}
```

It compiles: both branches now have the **same type**, `Box<dyn Storage>`. `Box::new(...)` first
creates a `Box<InMemoryStorage>`, and the annotation on `storage` makes Rust **coerce** it into a
`Box<dyn Storage>`. (That's the same "unsizing" coercion as `&e` → `&dyn Error` in Lab 22's
`error_chain`.)

### What is a `Box<dyn Storage>`, physically?

A normal `Box<JsonFileStorage>` is one pointer: 8 bytes on a 64-bit machine. A
`Box<dyn Storage>` is **two** pointers. Here are real numbers (from `std::mem::size_of`):

```text
JsonFileStorage:        24 bytes
InMemoryStorage:         0 bytes
&JsonFileStorage:        8 bytes
&dyn Storage:           16 bytes
Box<JsonFileStorage>:    8 bytes
Box<dyn Storage>:       16 bytes
```

> 🟡 **EXPERIMENT**: reproduce that table. Create `examples/sizes.rs` that prints
> `std::mem::size_of::<T>()` for each type above, and run `cargo run --example sizes`. Delete the
> file afterwards.

The two pointers are a **fat pointer**:

```text
 storage: Box<dyn Storage>             (16 bytes on the stack)
 ┌──────────────────────┬──────────────────────┐
 │ data pointer         │ vtable pointer       │
 └──────────┬───────────┴──────────┬───────────┘
            │                      │
            ▼  heap                ▼  static memory (one per impl, built by the compiler)
 ┌────────────────────────┐   ┌──────────────────────────────────────────────┐
 │ JsonFileStorage        │   │ vtable for <JsonFileStorage as Storage>       │
 │  path: PathBuf ────────┼─► │  drop_in_place: fn(*mut JsonFileStorage)      │
 │  (ptr, len, cap)       │   │  size: 24, align: 8                           │
 └────────────────────────┘   │  load:  <JsonFileStorage as Storage>::load    │
   "crm-data.json"            │  save:  <JsonFileStorage as Storage>::save    │
                              └──────────────────────────────────────────────┘
```

- The **data pointer** points at the concrete value. Its type has been *erased*: from here on,
  nobody knows it's a `JsonFileStorage`.
- The **vtable** ("virtual method table") is a small static table the compiler generates **once
  per (type, trait) pair**. It holds a function pointer for every method of the trait, plus what's
  needed to drop and deallocate the value (drop function, size, alignment).
- `storage.load()` compiles to: *read the vtable pointer, load the `load` entry, call it, passing
  the data pointer as `&self`.* That's **dynamic dispatch**: one indirect call.

Compare with generics: `run::<JsonFileStorage>` calls `JsonFileStorage::load` *directly*. The
compiler can even inline it. That's **static dispatch**.

Is dynamic dispatch slow? It costs one pointer lookup and prevents inlining. `load` then reads a
file from disk, which is about a million times slower. Dispatch cost only matters in tight loops
running millions of times. Choose by **design** (do you need runtime choice? a single type for
mixed values?), not by imagined speed.

> 🟡 **EXPERIMENT**: remove the word `dyn`: `pub fn run(storage: Box<Storage>)`.

```text
error[E0782]: expected a type, found a trait
  --> src/cli/mod.rs:34:25
   |
34 | pub fn run(storage: Box<Storage>) -> anyhow::Result<()> {
   |                         ^^^^^^^
   |
help: you can add the `dyn` keyword if you want a trait object
```

Old Rust allowed a bare trait name here. Modern editions require `dyn`, so the cost (a fat pointer
and an indirect call) is always visible in the code. Put it back.

---

## Step 6 — Dyn compatibility: not every trait can be `dyn`

A vtable has a fixed list of function pointers, built at compile time. Some kinds of method can't
be put in such a list. A trait with such a method is **not dyn compatible** (the older name is
"object safe").

> 🟡 **EXPERIMENT**: add an "export to any writer" method to the trait. It looks perfectly
> reasonable. Predict, then `cargo check`.

```rust
pub trait Storage {
    fn load(&self) -> Result<Crm, StorageError>;
    fn save(&self, crm: &Crm) -> Result<(), StorageError>;

    /// Writes the CRM to any writer (a file, stdout, a Vec<u8>...).
    fn export<W: std::io::Write>(&self, crm: &Crm, out: W) -> Result<(), StorageError>;
}
```

```text
error[E0038]: the trait `Storage` is not dyn compatible
  --> src/cli/mod.rs:34:25
   |
34 | pub fn run(storage: Box<dyn Storage>) -> anyhow::Result<()> {
   |                         ^^^^^^^^^^^ `Storage` is not dyn compatible
   |
note: for a trait to be dyn compatible it needs to allow building a vtable
      for more information, visit <https://doc.rust-lang.org/reference/items/traits.html#dyn-compatibility>
  --> src/storage/mod.rs:23:8
   |
18 | pub trait Storage {
   |           ------- this trait is not dyn compatible...
...
23 |     fn export<W: std::io::Write>(&self, crm: &Crm, out: W) -> Result<(), StorageError>;
   |        ^^^^^^ ...because method `export` has generic type parameters
   = help: consider moving `export` to another trait
   = help: the following types implement `Storage`:
             storage::json_file::JsonFileStorage
             storage::memory::InMemoryStorage
           consider defining an enum where each variant holds one of these types,
           implementing `Storage` for this new enum and using it instead
```

(You'll also get E0046, "missing `export` in implementation", for both impls. Ignore those.)

**Read the error.** *"it needs to allow building a vtable"*. How many entries would the vtable
need for `export`? A generic method isn't one function. It's a **template** for a separate function
per `W`: `export::<File>`, `export::<Vec<u8>>`, `export::<Stdout>`, … infinitely many. The
compiler only generates the ones that are actually called *with a known concrete type*. Through a
`dyn Storage`, the concrete storage type is erased, so the compiler can't know which
`(storage type, W)` combinations to generate. A vtable has room for a fixed number of pointers,
not a family.

The other common culprit is **`Self` by value**:

```rust
    fn duplicate(&self) -> Self;
```

```text
error[E0038]: the trait `Storage` is not dyn compatible
...
22 |     fn duplicate(&self) -> Self;
   |                            ^^^^ ...because method `duplicate` references the `Self` type in its return type
```

Through `dyn Storage`, what is `Self`? Some type of unknown size. The caller can't reserve stack
space for a return value of unknown size.

The rules, simplified: a trait is dyn compatible if its methods take `self` behind a pointer
(`&self`, `&mut self`, `Box<Self>`…), have **no generic type parameters**, and don't return or take
`Self` by value. The trait also can't require `Self: Sized`. (Lab 31 will hit a third case:
`async fn` in traits.)

Your options when you hit E0038:

| Fix | Example | Trade-off |
|---|---|---|
| Take a trait object instead of a generic | `fn export(&self, crm: &Crm, out: &mut dyn Write)` | One more dynamic call. Usually fine. |
| Exclude the method from the vtable | `fn export<W: Write>(...) where Self: Sized { ... }` | Compiles, but you **can't call it** through `dyn Storage` |
| Move it to a separate trait | `trait Export { fn export<W: Write>(...); }` | Callers that need it use generics |
| Use an enum instead of `dyn` | `enum AnyStorage { Memory(..), Json(..) }` | Closed set of backends, but no vtable at all |

**Remove `export` and `duplicate` again.** Our trait doesn't need them. What you should remember is
the reasoning: *dyn = one vtable = a fixed list of concrete functions.*

---

## Step 7 — Choosing: `&dyn`, `Box<dyn>`, generics or an enum

| | Generics `S: Storage` | `&dyn Storage` | `Box<dyn Storage>` | `enum` of backends |
|---|---|---|---|---|
| Choice made | compile time | runtime | runtime | runtime |
| Ownership | owns or borrows (your choice) | **borrows** | **owns** (heap) | owns |
| Dispatch | static (inlinable) | dynamic | dynamic | `match` |
| Code size | one copy per type | one copy | one copy | one copy |
| Open to new impls (Lab 24 test doubles, other crates)? | ✅ | ✅ | ✅ | ❌ (edit the enum) |
| Needs dyn compatibility? | no | yes | yes | no |
| In this course | `InMemoryRepo<T>` (Lab 16) | `error_chain(&dyn Error)` (Lab 22) | `cli::run(storage)` (this lab) | `ActivityKind` (Lab 20) |

Why does `run` take `Box<dyn Storage>` and not `&dyn Storage`?

- `run` uses the storage **for the whole session**. It must outlive every save. Taking ownership
  makes that trivially true: `run` owns it, and it's dropped when `run` returns.
- `&dyn Storage` would also work here, because `main` outlives `run`. But in Lab 25 the storage
  moves into a background thread, and a borrow can't do that (you'll see E0373). Owning is the
  more honest signature. (Lab 25 changes `Box` to `Arc`, so two threads can own it together.)

And why not an enum, which Lab 20 preferred for `ActivityKind`? The set of *activity kinds* is
part of your domain: closed, and every `match` should handle all of them. The set of *storage
backends* is open: tests will add fakes (Lab 24), and the program should work with backends it
has never heard of. **Closed set → enum. Open set → trait.**

---

## Step 8 — Command-line arguments with `clap`

`std::env::args().any(|arg| arg == "--memory")` was a placeholder. Real CLIs need `--help`,
errors for typos, defaults and environment variables. `clap` generates all of that from a struct.

```bash
cargo add clap --features derive,env
```

> Written against **clap 4**. The `derive` feature enables `#[derive(Parser)]`. The `env` feature
> enables reading arguments from environment variables.

> 🟢 **FOLLOW ALONG**: replace `src/main.rs`

```rust
use std::path::PathBuf;

use clap::{Parser, ValueEnum};
use rust_crm::storage::{InMemoryStorage, JsonFileStorage, Storage};

/// A terminal CRM, written while learning Rust.
#[derive(Debug, Parser)]
#[command(version, about)]
struct Args {
    /// Where to keep the CRM's data
    #[arg(long, value_enum, default_value_t = StorageKind::Json)]
    storage: StorageKind,

    /// JSON data file (used with --storage json)
    #[arg(long, env = "CRM_DATA_FILE", default_value = "crm-data.json")]
    data_file: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum StorageKind {
    /// Keep nothing; every run starts empty
    Memory,
    /// Load from and save to a JSON file
    Json,
}

/// The one place that decides which concrete storage the program uses.
fn build_storage(args: Args) -> Box<dyn Storage> {
    match args.storage {
        StorageKind::Memory => Box::new(InMemoryStorage),
        StorageKind::Json => Box::new(JsonFileStorage::new(args.data_file)),
    }
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let storage = build_storage(args);
    rust_crm::cli::run(storage)
}
```

How `clap` reads this struct:

- **`#[derive(Parser)]`** generates `Args::parse()`, which reads `std::env::args()`, fills the
  struct, and on `--help` or an error prints a message and **exits the process** (it never
  returns in those cases).
- **Doc comments become help text.** `/// Where to keep...` is the help for `--storage`. The doc
  comment on the struct becomes the `about` line.
- **`#[arg(long)]`** makes a `--storage` flag. The field name is converted to kebab-case, so
  `data_file` becomes `--data-file`.
- **`value_enum` + `#[derive(ValueEnum)]`** turn the enum's variants into the allowed values
  `memory` and `json`. A typo is rejected *before your code runs*, the same "parse, don't validate"
  idea as `Email`.
- **`default_value_t = StorageKind::Json`** takes a typed Rust value. `default_value = "..."`
  takes a string that clap parses.
- **`env = "CRM_DATA_FILE"`**: if the flag isn't given, clap checks this environment variable
  before falling back to the default. Precedence: **flag > env var > default**.
- **`data_file: PathBuf`**, not `String`. clap parses straight into the type you need.
- **`#[command(version)]`** gives you `--version` from `Cargo.toml`.

**`build_storage` is the composition root**: the single place where concrete types are chosen
and wired together. Everything else receives abstractions. When Postgres arrives, *this* is the
function that changes.

---

## ▶️ Run It

Arguments for *your* program go after `--`, so cargo doesn't try to interpret them:

```bash
cargo run -- --help
cargo run -- --storage sqlite
cargo run
cargo run -- --storage memory
CRM_DATA_FILE=other.json cargo run
CRM_DATA_FILE=other.json cargo run -- --data-file third.json
```

## ✅ Expected Result

`cargo run -- --help`:

```text
A terminal CRM, written while learning Rust

Usage: rust-crm [OPTIONS]

Options:
      --storage <STORAGE>
          Where to keep the CRM's data

          Possible values:
          - memory: Keep nothing; every run starts empty
          - json:   Load from and save to a JSON file

          [default: json]

      --data-file <DATA_FILE>
          JSON data file (used with --storage json)

          [env: CRM_DATA_FILE=]
          [default: crm-data.json]

  -h, --help
          Print help (see a summary with '-h')

  -V, --version
          Print version
```

`cargo run -- --storage sqlite` (exit code `2`, clap's code for usage errors):

```text
error: invalid value 'sqlite' for '--storage <STORAGE>'
  [possible values: memory, json]

For more information, try '--help'.
```

`cargo run -- --storage memory`, after finishing Your Turn 2:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Storage: in memory (nothing will be saved)
Loaded 0 companies, 0 contacts, 0 deals, 0 leads
crm> company list
No companies found.
crm> quit
Goodbye! (2 commands this session)
```

`cargo run` loads your existing `crm-data.json` exactly as before, with
`Storage: JSON file crm-data.json`. With `CRM_DATA_FILE=other.json` the banner says
`Storage: JSON file other.json`, and with the flag as well it says `third.json`: the flag wins.

## 🧠 Understand It

**A trait is a boundary.** `cli::run` depends only on "something that can load and save a CRM".
It compiles without knowing any backend exists. That's what lets Lab 24 test it, Lab 25 move it
to a thread and Lab 27 share it with an HTTP server.

**Generics = one type, chosen at compile time. `dyn` = any type, chosen at runtime.** Generics
generate specialised copies (fast, inlinable, more code). `dyn` erases the type behind a fat
pointer (data + vtable) and calls through the vtable (one indirection, one copy of the code).

**A vtable is a fixed list of function pointers.** Everything about dyn compatibility follows
from that: no generic methods (that's a family, not a function), no `Self` by value (unknown size).

**Ownership still applies to trait objects.** `Box<dyn Storage>` owns, `&dyn Storage` borrows,
and `Arc<dyn Storage>` (Lab 25) shares. Choosing between them is the same question as always:
who owns this, and for how long?

**Closed sets → enums, open sets → traits.**

**Configuration enters at the edge.** clap parses arguments and environment variables in `main`,
and from there on everything is typed values: `StorageKind`, `PathBuf`, `Box<dyn Storage>`.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: add `println!("{:?}", storage);` at the top of `cli::run`. Why doesn't it
> compile, even though both `JsonFileStorage` and `InMemoryStorage` derive `Debug`? (Hint: what
> does the vtable contain?) How would you change the **trait** to make it compile? Revert
> afterwards.

> 🟡 **EXPERIMENT 2**: in `main`, try to keep using `args` after `build_storage(args)`, for
> example `println!("{:?}", args.data_file);`. Read the error. Why does `build_storage` take
> `Args` by value? Would `&Args` be better? (Hint: what does `JsonFileStorage::new` need to own?)

> 🟡 **EXPERIMENT 3**: run `CRM_DATA_FILE= cargo run` (set but empty). What does clap do with an
> empty environment variable? Is that what you'd want?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1** (`InMemoryStorage`) is in Step 3.

> 🔵 **YOUR TURN 2: a provided method.** Users should see which storage they're using, but `cli`
> mustn't know the concrete types. Add a method to the trait:
>
> ```rust
> /// A short human description, shown in the banner.
> fn describe(&self) -> String
> ```
>
> - [ ] it has a **default body** in the trait (returning something generic like
>   `"custom storage"`), so a new backend compiles without implementing it
> - [ ] `JsonFileStorage` overrides it: `JSON file <path>`
> - [ ] `InMemoryStorage` overrides it: `in memory (nothing will be saved)`
> - [ ] `cli::run` prints `Storage: <description>` right after the banner
> - [ ] the trait is still dyn compatible (it is, but explain to yourself *why* a method with a
>   body still gets a vtable entry)

> 🔵 **YOUR TURN 3: test the command line.** clap can parse from any list of strings with
> `Args::try_parse_from([...])`, which returns a `Result` instead of exiting. Add a
> `#[cfg(test)] mod tests` to `src/main.rs` with:
>
> - [ ] `args_definition_is_valid`: clap's own self-check, `Args::command().debug_assert()` (needs
>   `use clap::CommandFactory;`)
> - [ ] `defaults_to_json_storage_and_crm_data_json`
> - [ ] `storage_memory_is_accepted`
> - [ ] `unknown_storage_is_rejected`: the error's `kind()` is `clap::error::ErrorKind::InvalidValue`
> - [ ] `data_file_flag_is_used_by_json_storage`: `--data-file other.json` →
>   `build_storage(args).describe() == "JSON file other.json"`
> - [ ] `memory_storage_describes_itself`
> - [ ] **no** test sets environment variables (see the hint for why)
> - [ ] `cargo test` runs them (yes, a binary crate can have unit tests too)

## 💡 Hint

> 💡 **HINT** (Your Turn 1): a parameter you don't use can be named `_crm`. The underscore tells
> the compiler (and readers) it's intentionally unused.

> 💡 **HINT** (Your Turn 2): a provided method is written in the trait with a body, exactly like
> a normal method. Implementations may override it by defining a method with the same signature.

> 💡 **HINT** (Your Turn 3): why no environment variables? Try writing
> `std::env::set_var("CRM_DATA_FILE", "env.json");` in a test:

```text
error[E0133]: call to unsafe function `set_var` is unsafe and requires unsafe block
  --> src/main.rs:73:9
   |
73 |         std::env::set_var("CRM_DATA_FILE", "env.json");
   |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ call to unsafe function
```

<details><summary>Hint 2 (more specific)</summary>

- In edition 2024, `set_var` is `unsafe`: the environment is process-global, and changing it while
  another thread reads it is undefined behaviour on some platforms. `cargo test` runs tests on
  many threads. Even with `unsafe`, one test's variable would leak into the others.
- The consequence for `defaults_to_json_storage_and_crm_data_json`: it passes only if
  `CRM_DATA_FILE` is **not** set in your shell. Try `CRM_DATA_FILE=x.json cargo test` and watch it
  fail. That's acceptable (CI won't set it), but write a comment in the test saying so.
- `assert_eq!(args.storage, StorageKind::Json)` needs `PartialEq` and `Debug` on `StorageKind`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why did `let storage = if … { InMemoryStorage } else { JsonFileStorage::new(…) };` fail to
   compile? Give two different fixes.
2. Draw a `Box<dyn Storage>` holding a `JsonFileStorage`: what's on the stack, on the heap, and in
   static memory? How big is each part?
3. What happens, step by step, when `storage.save(&crm)` runs through a `Box<dyn Storage>`?
4. Why can't a trait with `fn export<W: Write>(&self, out: W)` be used as `dyn`? Name two fixes.
5. When would you choose `&dyn Trait` over `Box<dyn Trait>`? Generics over both? An enum over all
   three?
6. What's the precedence between `--data-file`, `CRM_DATA_FILE` and the default?
7. What is the composition root of your program, and why is it good that there's only one?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit
```bash
git add .
git commit -m "Introduce Storage trait with memory and JSON backends"
git tag lab-23
git push && git push --tags
```

`git log --follow --oneline src/storage/json_file.rs` still shows the Lab 21 and 22 commits.
That's `git mv` at work.

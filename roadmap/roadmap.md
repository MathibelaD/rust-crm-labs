# Rust CRM Labs — Complete Roadmap

> **Teach me how to build the CRM. Don't build the CRM for me.**

This roadmap is the whole curriculum on one page. For every lab, it answers:

> *"I'm learning **X** because we're going to use it for **Y** in the CRM."*

There are **41 labs in 12 phases**, plus **5 phase challenges** and a **capstone**. Every lab
builds on the same `rust-crm` repository you created in Lab 01. Nothing is thrown away. Some of
it gets **refactored on purpose** when your Rust knowledge outgrows it.

---

## Contents

1. [How the CRM evolves (the big picture)](#1-how-the-crm-evolves-the-big-picture)
2. [Roadmap at a glance](#2-roadmap-at-a-glance)
3. [Lab-by-lab detail](#3-lab-by-lab-detail)
4. [Threads that run through the whole course](#4-threads-that-run-through-the-whole-course)
5. [How the architecture emerges](#5-how-the-architecture-emerges)
6. [Design decisions (and why)](#6-design-decisions-and-why)

---

## 1. How the CRM evolves (the big picture)

```text
Phase 0   An empty repo that compiles and runs
            ↓
Phase 1   An interactive terminal CRM:  crm> add / list
            ↓
Phase 2   Same CRM, rewritten with correct ownership and borrowing
            ↓
Phase 3   Real domain modelling: enums, validation, errors, modules,
          and the Customer → Company + Contact refactor
            ↓
Phase 4   Traits, generics and iterators: a generic repository and a search engine
            ↓
Phase 5   The sales pipeline: Deals, Leads → conversion, Activities, Notes
            ↓
Phase 6   Persistence and quality: JSON storage, real error types, a storage trait,
          integration tests, CI
            ↓
Phase 7   Concurrency and async: threads, Arc/Mutex, Tokio
            ↓
Phase 8   The CRM becomes a REST API (Axum)
            ↓
Phase 9   PostgreSQL (SQLx), migrations, transactions, DB tests
            ↓
Phase 10  Users, authentication and authorization
            ↓
Phase 11  Production: logging, config, background jobs, Docker, deployment
            ↓
Capstone  You design and build a feature with no step-by-step instructions
```

**The interface changes twice, and that's on purpose:**

| Stage | Interface | Storage | Why |
|---|---|---|---|
| Labs 01–25 | Interactive terminal (REPL) | In memory, then JSON file | A REPL gives instant feedback while you learn ownership. No HTTP or DB noise. |
| Labs 26–29 | HTTP API (Axum) | JSON file behind a trait | Async and HTTP are big enough topics on their own. You change one thing at a time. |
| Labs 30–41 | HTTP API | PostgreSQL | Real backend. The CLI is retired; you learn why. |

---

## 2. Roadmap at a glance

Legend: ♻️ = deliberate refactor lab · 🧪 = introduces a new kind of testing · 🏁 = phase challenge

| # | Lab | Rust concepts | CRM feature | Outcome |
|---|---|---|---|---|
| **Phase 0** | **Toolchain & Workflow** | | | |
| 01 | Getting Started | rustup, cargo, check/build/run, fmt, clippy, git | `rust-crm` repo on GitHub, prints a banner | First commit pushed |
| **Phase 1** | **Rust Foundations** | | | |
| 02 | Variables, Types & Functions | let/mut, shadowing, scalar types, tuples, functions, expressions | A hard-coded customer, `format_customer()` | A customer printed from a function |
| 03 | Control Flow & the Command Loop | if/loop/while/for, `match` on `&str`, stdin | `crm>` prompt with `help`, `version`, `quit` | An interactive shell to grow into |
| 04 | Structs & Methods | struct, impl, associated fns, `#[derive(Debug)]` | `Customer` struct | Customers are real types |
| 05 | Collections & First Tests 🧪 | `Vec`, `HashMap`, `#[test]`, `cargo test` | `add`, `list`, `count` commands | An in-memory CRM with tests |
| **Phase 2** | **Ownership & Borrowing** (slow down here) | | | |
| 06 | Ownership: Moves, Clones & Drops | stack/heap, moves, `Copy`, `Clone`, `Drop` | `create_customer()` → store | You can explain every E0382 |
| 07 | Borrowing: `&` and `&mut` | shared/mutable refs, aliasing XOR mutation | `CustomerStore`, `show`, `update` | A store with a deliberate borrowing API |
| 08 | The Borrow Checker in Practice ♻️ | NLL, find-then-mutate, iterate-while-mutate, `retain` | `delete`, bulk email normalisation | An ownership review of all your code |
| 09 | Slices & Strings Properly | `&str` vs `String`, UTF-8, `&[T]` | Command parser, email domain, paginated `list` | A zero-copy command parser |
| 10 | Lifetimes | elision, annotations, structs with refs, `'static` | `search` returning borrowed results | You can explain every lifetime you write |
| 🏁 A | Challenge: Duplicate Detection | everything in Phase 2 | `duplicates` command | Solved without step-by-step help |
| **Phase 3** | **Modelling the Domain** | | | |
| 11 | Enums & Pattern Matching ♻️ | enums with data, exhaustive `match`, `if let`, `let else` | `Command` enum, `CustomerStatus` | No more stringly-typed commands |
| 12 | Option, Result & Errors ♻️ 🧪 | combinators, `?`, custom errors, newtypes | Validated `Email`, optional phone, `CrmError` | Invalid data can't get in, and nothing panics |
| 13 | Modules, Crates & Visibility ♻️ | `mod`, `pub`, lib + bin crates, `cargo doc` | First restructure: `lib.rs` + modules | main.rs is thin, and privacy protects invariants |
| 14 | Companies & Contacts: Relationships ♻️ | `Box`, `Rc`, `RefCell`, `Weak`, newtype IDs | Customer → Company + Contact | You know why Rust apps use IDs, not pointers |
| **Phase 4** | **Abstraction** | | | |
| 15 | Traits | traits, derive, `Display`, `From`/`TryFrom`, `dyn` intro | `Entity`, `Validate`, table output | Shared behaviour across entities |
| 16 | Generics: One Repository for Everything ♻️ | generic structs, bounds, `where`, monomorphization | `InMemoryRepo<T: Entity>` | Copy-pasted stores deleted |
| 17 | Iterators & Closures | adapters, consumers, `iter`/`iter_mut`/`into_iter`, `Fn*` | `filter`/`sort` commands, search engine | Powerful queries in a few lines |
| **Phase 5** | **The Sales Pipeline** | | | |
| 18 | Deals & the Pipeline | operator traits, `Money` newtype, state machines, `BTreeMap`, entry API | Deals, `DealStage`, `pipeline` report | A working sales pipeline |
| 19 | Leads & Conversion | consuming `self`, builder pattern, `Option::take` | Leads, `lead convert` | The compiler stops you using a converted lead |
| 20 | Activities, Notes & Time | external crates, `chrono`, enum vs `Box<dyn Trait>` | Calls/emails/meetings, notes | Every record has a history |
| 🏁 B | Challenge: Sales Forecast | Phases 3–5 | `forecast` command | Solved without step-by-step help |
| **Phase 6** | **Persistence & Quality** | | | |
| 21 | Serialization & File Persistence | `serde`, `serde_json`, `std::fs`, atomic writes | Data survives restarts | A CRM you can actually use |
| 22 | Professional Error Handling ♻️ | `thiserror`, `anyhow`, error layering, context | Every error has a clear message | Library vs application errors |
| 23 | Traits as Boundaries: Storage ♻️ | trait objects, `Box<dyn>`, dyn compatibility, DI, `clap`, env vars | `--storage memory\|json` | Storage you can swap, the key to everything after |
| 24 | Testing Properly + CI 🧪 | `tests/` integration tests, fixtures, `tempfile`, doc tests, GitHub Actions | Test suite, CI badge | Every push is checked |
| 🏁 C | Challenge: CSV Import | Phases 1–6 | `import contacts.csv` | Solved without step-by-step help |
| **Phase 7** | **Concurrency & Async** | | | |
| 25 | Threads & Shared State | `thread::spawn`, `move`, `Arc`, `Mutex`, `RwLock`, `Send`/`Sync`, channels | Background autosave thread | You know why the server will need `Arc` |
| 26 | Async Rust & Tokio ♻️ | futures, `async`/`await`, runtime, `tokio::spawn`, `select!`, `spawn_blocking` | Async REPL + autosave task; file I/O via `spawn_blocking` | Ready to serve HTTP |
| **Phase 8** | **The CRM Becomes a Web API** | | | |
| 27 | HTTP & Axum Basics | Router, handlers, extractors, `State`, DTOs | `/health`, `/companies` | The CRM speaks HTTP |
| 28 | API Errors & Validation | `IntoResponse`, error → status mapping, `TryFrom` DTO → domain | Consistent JSON errors, 422s | A predictable API |
| 29 | The Full REST Surface 🧪 | nested routers, query params, `tower` `oneshot` tests | All entities over HTTP, API tests | Complete API with a test suite |
| 🏁 D | Challenge: Tags | Phases 7–8 | Tag companies/contacts, filter by tag | Solved without step-by-step help |
| **Phase 9** | **PostgreSQL** | | | |
| 30 | PostgreSQL & SQLx ♻️ | Docker Compose, migrations, pools, `query!` macros | Companies & contacts in Postgres, CLI retired | A real database |
| 31 | Repositories on Postgres | async traits, `FromRow`, `sqlx::Type`, transactions | All entities in Postgres, atomic lead conversion | JSON storage retired |
| 32 | Search, Filtering & Pagination in SQL | `QueryBuilder`, `ILIKE`/full-text, keyset pagination, indexes | `/search`, SQL pipeline report | Fast queries at scale |
| 33 | Database Integration Tests 🧪 | `#[sqlx::test]`, fixtures, CI Postgres service | DB-backed test suite | Tests against a real DB, in CI |
| **Phase 10** | **Users, Authentication & Authorization** | | | |
| 34 | Users & Password Hashing | `argon2`, `secrecy`, uniqueness | `/auth/register` | Passwords stored safely |
| 35 | Authentication | JWT, `FromRequestParts` extractor, middleware | `/auth/login`, protected routes, `/me` | Only logged-in users can use the CRM |
| 36 | Authorization 🧪 | role enums, policy functions, 403 vs 404 | Admin / Manager / Sales Rep, deal ownership | Users only see and change what they should |
| 🏁 E | Challenge: Teams | Phases 9–10 | Teams; managers see their team's deals | Solved without step-by-step help |
| **Phase 11** | **Production-Ready** | | | |
| 37 | Logging & Observability | `tracing`, spans, `#[instrument]`, `TraceLayer`, request IDs | Structured logs | You can debug production |
| 38 | Configuration & Graceful Shutdown | typed `Settings`, layered config, fail-fast, signals | One config system, clean shutdown | 12-factor ready |
| 39 | Background Jobs | job queue table, `SKIP LOCKED`, retries, `CancellationToken` | Stale-deal detection, follow-up reminders | Work that runs without a request |
| 40 | Docker & Deployment | multi-stage builds, `cargo-chef`, offline SQLx, release profile | Dockerfile, compose stack, deployed API | It's live |
| **Capstone** | | | | |
| 41 | Capstone: Customer Activity Timeline | everything | Unified timeline API (spec only) | **"I built this."** |

**Estimated time:** about 90–130 hours in total. Phase 2 deliberately takes longer than its lab
count suggests.

---

## 3. Lab-by-lab detail

Each entry gives the concepts, the CRM work, the expected outcome, and **why it matters**: how the lab feeds the final CRM.
Compiler errors you're *meant* to hit are listed as 💥.

---

### Phase 0 — Toolchain & Workflow

#### Lab 01 — Getting Started
- **Rust concepts:** installing with `rustup`, toolchains (stable/nightly), `rustc --version`,
  `cargo new`, `Cargo.toml` and `Cargo.lock`, `target/`, `cargo check` vs `cargo build` vs
  `cargo run`, debug vs `--release`, `cargo fmt`, `cargo clippy`, rust-analyzer in VS Code.
- **CRM feature:** you run `cargo new rust-crm` yourself, create the GitHub repo, and make
  `main.rs` print a banner that reads the version from `Cargo.toml` (`env!("CARGO_PKG_VERSION")`).
- **Outcome:** an empty but real project pushed to GitHub.
- **Why it matters:** `cargo check` is the command you'll run hundreds of times. It's your
  conversation with the compiler. Clippy becomes your code reviewer.
- **Commit:** `Initialize Rust CRM`

---

### Phase 1 — Rust Foundations

#### Lab 02 — Variables, Types & Functions
- **Rust concepts:** `let`, `mut`, shadowing, integer types (`u32` vs `i64`: why IDs are
  unsigned), `bool`, `char`, tuples, `const`, functions, parameters and return types,
  **expressions vs statements** (the missing semicolon that returns a value).
- **CRM feature:** a hard-coded customer held in variables; `format_customer(...) -> String`;
  `next_id(current: u32) -> u32`.
- 💥 **Errors:** assign to an immutable variable (E0384); type mismatch from a stray semicolon (E0308).
- **Outcome:** customer details printed through functions you wrote.
- **Why it matters:** expression-oriented thinking is how `match`, `if` and blocks return values
  throughout the CRM.
- **Commit:** `Add customer formatting function`

#### Lab 03 — Control Flow & the Command Loop
- **Rust concepts:** `if` as an expression, `loop` / `while` / `for`, `break` with a value,
  `match` on string input, reading stdin with `read_line`, `.trim()`, a first look at
  `String` vs `&str` (fully explained in Lab 09).
- **CRM feature:** the `crm>` prompt with `help`, `version`, `quit`, and "unknown command" handling.
- **Outcome:** an interactive shell. This REPL hosts the CRM until Lab 27.
- **Why it matters:** every feature from Labs 03–26 is a new command in this loop.
- **Commit:** `Add interactive command loop`

#### Lab 04 — Structs & Methods
- **Rust concepts:** defining structs, field init shorthand, struct update syntax, `impl`
  blocks, associated functions (`Customer::new`), methods with `&self`, `#[derive(Debug)]`,
  `{:?}` and `{:#?}`.
- **CRM feature:** `Customer { id, name, email, phone }` replaces the loose variables from Lab 02.
- **Outcome:** customers are a real type with behaviour.
- **Why it matters:** every CRM entity (Company, Contact, Deal, Lead, Activity, Note, User)
  starts out this way.
- **Commit:** `Add Customer struct`

#### Lab 05 — Collections & Your First Tests 🧪
- **Rust concepts:** `Vec<T>`, `push`, iterating with `for`, `len`, indexing vs `.get()`
  (panic vs `Option`), `HashMap` basics, `#[cfg(test)]`, `#[test]`, `assert_eq!`, `cargo test`.
- **CRM feature:** `add` (prompts for each field), `list`, `count`, all held in memory.
- **Outcome:** a CRM you can use for one session, plus your first passing tests.
- **Why it matters:** tests start here, not at the end. From now on every lab adds tests.
- **Commit:** `Add in-memory customer list`

---

### Phase 2 — Ownership & Borrowing

> This is the most important phase in the course. Five labs and a challenge, all on the CRM code
> you already wrote. Each lab follows the same pattern: **predict → `cargo check` → read the error
> → reason about it (who owns it? was it moved? is it a borrow? is it mutable? how long must it
> live?) → choose a fix *and justify it*.**

#### Lab 06 — Ownership: Moves, Clones & Drops
- **Rust concepts:** stack vs heap, what a `String` really is (pointer, length, capacity),
  the three ownership rules, moves on assignment and function calls, `Copy` types (why `u32`
  copies and `String` moves), `.clone()` as a visible cost, scope and `Drop`.
- **CRM feature:** extract `create_customer(...) -> Customer` and push its result into the
  list. Then try to print the customer after pushing it. Implement `Drop` on `Customer` so you
  can *watch* values die.
- 💥 **Errors:** E0382 *use of moved value*, met in three different places.
- **Outcome:** you can predict, before compiling, whether a line moves or copies.
- **Why it matters:** every function signature in the CRM is an ownership decision.

#### Lab 07 — Borrowing: Shared and Mutable References
- **Rust concepts:** `&T` and `&mut T`, the rule *many readers XOR one writer*, **why** the
  rule exists (iterator invalidation: a `Vec` reallocating under a reference, drawn out
  step by step), method receivers `self` / `&self` / `&mut self`, auto-deref.
- **CRM feature:** a `CustomerStore` struct; `show <id>` using `find(&self) -> Option<&Customer>`,
  `update <id>` using `find_mut(&mut self) -> Option<&mut Customer>`.
- 💥 **Errors:** E0502 (immutable borrow, then mutable), E0499 (two mutable borrows),
  E0596 (borrowing a non-`mut` binding mutably).
- **Outcome:** a store whose API reads like a contract: who can read, who can write.
- **Why it matters:** the same `&self` / `&mut self` split becomes `RwLock` read/write locks
  in the web server (Lab 25) and repository methods (Lab 31).

#### Lab 08 — The Borrow Checker in Practice ♻️
- **Rust concepts:** non-lexical lifetimes (where a borrow actually ends), the
  *find-then-mutate* problem, iterating while mutating, holding a reference across a `push`,
  moving out of a borrow, fix strategies (IDs/indices, two-phase "collect then mutate",
  `retain`, `iter_mut`, split borrows of struct fields, cloning as a *deliberate* choice).
- **CRM feature:** `delete <id>`; bulk "normalise all emails to lowercase"; a full
  **ownership review** of every function you've written. For each one, why does it take `T`,
  `&T` or `&mut T`?
- 💥 **Errors:** E0502 inside loops, E0505 (move out while borrowed), E0507 (move out of a
  borrowed `Customer`).
- **Outcome:** a refactored store that doesn't fight the borrow checker.
- **Why it matters:** these exact patterns come back in relationships (Lab 14), lead
  conversion (Lab 19) and shared server state (Lab 25).

#### Lab 09 — Slices & Strings Properly
- **Rust concepts:** `String` vs `&str` (owned vs borrowed view), string slices, UTF-8 and
  why `name[0..1]` can panic (try "Zoë" or "Søren"), `.chars()`, `&[T]` slices, deref
  coercion (`&String` → `&str`), why good APIs take `&str` and `&[T]`.
- **CRM feature:** a command parser that splits input into a command and arguments
  without allocating; `email_domain(&str) -> Option<&str>`; customer initials;
  `list --page 2` using `&customers[start..end]`.
- 💥 **Errors:** a runtime panic on a non-char boundary. A good lesson that not every bug is
  a compile error.
- **Outcome:** a parser that borrows the input instead of copying it.
- **Why it matters:** slices are how Rust avoids needless copying. The same parser gets
  lifetimes in the next lab.

#### Lab 10 — Lifetimes
- **Rust concepts:** what a lifetime *is* (a constraint, not a timer), dangling references
  (E0597), elision rules (why you rarely write `'a`), explicit annotations when a function
  returns a reference that could come from several inputs (E0106), structs holding references
  (`ParsedCommand<'a>`), `'static` and string literals, a practical rule for choosing owned vs
  borrowed data.
- **CRM feature:** `search <term>` with
  `fn search<'a>(&'a self, term: &str) -> Vec<&'a Customer>`. Why does `term` *not* need `'a`?
  `ParsedCommand<'a>` borrows the input line.
- 💥 **Errors:** E0106 (missing lifetime specifier), E0597 (borrowed value does not live long
  enough), E0716 (temporary dropped while borrowed).
- **Outcome:** you can explain every lifetime annotation in your code, and why most code
  needs none.
- **Why it matters:** when lifetimes show up later (Axum extractors, `'static` bounds on
  `tokio::spawn`), you'll recognise them.

#### 🏁 Challenge A — Duplicate Detection
Add a `duplicates` command that finds customers sharing an email (case-insensitive) or a
phone number, returning borrowed pairs. You get a spec, constraints ("no `.clone()` of
customers") and acceptance tests, but no instructions.

---

### Phase 3 — Modelling the Domain

#### Lab 11 — Enums & Pattern Matching ♻️
- **Rust concepts:** enums with and without data, exhaustive `match`, `if let`, `let ... else`,
  `matches!`, match guards, `@` bindings, *making illegal states unrepresentable*.
- **CRM feature:** refactor string commands into
  `enum Command { Add, List { page }, Search { term }, Show { id }, Update { id }, Delete { id }, Help, Quit }`;
  add `CustomerStatus { Prospect, Active, Churned }`.
- 🟡 **Experiment:** add a new enum variant and let the compiler list every place you need
  to update.
- **Outcome:** the parser produces a typed `Command`. Typos become compile errors.
- **Why it matters:** `DealStage`, `LeadSource`, `ActivityKind` and `Role` are all enums
  later on.

#### Lab 12 — Option, Result & Error Handling ♻️ 🧪
- **Rust concepts:** `Option` and its combinators (`map`, `and_then`, `unwrap_or`,
  `ok_or`), `Result`, `panic!` vs recoverable errors, why `unwrap()` is a TODO, the `?`
  operator, a custom `CrmError` enum, implementing `Display` and `std::error::Error`,
  `str::parse`, the **newtype pattern** for validated values.
- **CRM feature:** `Email::parse(&str) -> Result<Email, ValidationError>` (an `Email`
  can't be invalid once constructed). `phone: String` becomes `Option<String>` (a refactor:
  "no phone" is not `""`). Bad input prints a friendly message instead of panicking.
- 🧪 **Testing:** tests for *error cases*: invalid emails, unknown IDs, malformed commands.
- **Outcome:** invalid data can't get into the CRM.
- **Why it matters:** this error type grows into the API's HTTP error responses (Lab 28).

#### Lab 13 — Modules, Crates & Visibility ♻️ (first restructure)
- **Rust concepts:** packages vs crates, binary crate + library crate in one package
  (`main.rs` + `lib.rs`), `mod`, file and folder modules, `pub`, `pub(crate)`, private fields,
  `use`, re-exports, `crate::` / `super::`, doc comments, `cargo doc --open`.
- **CRM feature:** `main.rs` (300+ lines by now) splits into `lib.rs`, `customers/`, `cli/`
  and `errors.rs`. `Email`'s inner field becomes private, so **the only way to build an `Email`
  is through validation**.
- **Outcome:** a thin `main.rs` and a library crate the rest of the course builds on.
- **Why it matters:** integration tests (Lab 24) and the web server (Lab 27) both depend on
  having a library crate. We restructure *now* because the pain is real now, not
  earlier.

#### Lab 14 — Companies & Contacts: Relationships in Rust ♻️
- **Rust concepts:** three attempts at modelling "a contact works at a company":
  1. `Contact { company: &Company }`: lifetimes spread everywhere (you'll feel it).
  2. `Rc<RefCell<Company>>`: it works, but brings runtime borrow panics (`BorrowMutError`),
     reference cycles and `Weak`.
  3. **IDs plus lookups**: idiomatic, mirrors a database, and the approach we keep.
  Plus `Box<T>`, newtype IDs (`CompanyId(u64)`, `ContactId(u64)`) so IDs can't be mixed up.
- **CRM feature:** **domain refactor.** In B2B, "customer" means an *organisation* with
  several people, so `Customer` becomes `Contact` (a person) and a new `Company` (an
  organisation with a lifecycle: Prospect → Customer → Churned) is added.
  Commands: `company add/list/show`, `contact add --company <id>`.
- **Outcome:** companies with contacts, linked by typed IDs.
- **Why it matters:** this is the data model all later entities use, and it maps 1:1 onto
  database foreign keys in Lab 30.

---

### Phase 4 — Abstraction

#### Lab 15 — Traits
- **Rust concepts:** defining traits, implementing them, default methods, derivable traits
  (`Clone`, `PartialEq`, `Eq`, `Hash`, `Default`, `PartialOrd`/`Ord`), `Display`,
  `From`/`Into`, `TryFrom` (replaces `Email::parse`), trait bounds, `impl Trait` in argument
  position, a first look at `dyn Trait`, orphan rules.
- **CRM feature:** `trait Entity { fn id(&self) -> ...; fn label(&self) -> String; }`,
  `trait Validate`, `Display` for table-formatted output.
- **Outcome:** shared behaviour across Company and Contact.
- **Why it matters:** traits are how the generic repository (Lab 16), the storage layer
  (Lab 23), Axum extractors (Lab 35) and error responses (Lab 28) work.

#### Lab 16 — Generics: One Repository for Everything ♻️
- **Rust concepts:** generic functions and structs, trait bounds, `where` clauses,
  monomorphization (generics cost nothing at runtime), generics vs trait objects,
  optionally `PhantomData` for a typed `Id<T>`.
- **CRM feature:** you now have two almost identical stores (Company, Contact). Replace both with
  `InMemoryRepo<T: Entity>` and delete the duplication.
- **Outcome:** adding a new entity costs a struct and a trait impl, nothing more.
- **Why it matters:** Deals, Leads, Activities and Notes (Phase 5) reuse this repository
  for free.

#### Lab 17 — Iterators & Closures
- **Rust concepts:** the `Iterator` trait, laziness, adapters (`filter`, `map`, `filter_map`,
  `enumerate`, `skip`/`take`, `chain`, `flat_map`), consumers (`collect`, `sum`, `count`,
  `fold`, `any`, `find`, `max_by_key`), `iter()` vs `iter_mut()` vs `into_iter()` (ownership
  again), closures and captures, `Fn` / `FnMut` / `FnOnce`, `move`, returning `impl Iterator`.
- **CRM feature:** a search and filter engine:
  `contacts --company 3 --sort name`, `companies --status customer --search acme`.
- **Outcome:** expressive queries without hand-written loops.
- **Why it matters:** iterator pipelines power reports (Lab 18) and API query handling
  (Lab 29).

---

### Phase 5 — The Sales Pipeline

#### Lab 18 — Deals & the Pipeline
- **Rust concepts:** why money is never `f64` (`0.1 + 0.2`), a `Money` newtype in cents,
  operator traits (`Add`, `Sum`), state machines with enums (only valid stage transitions),
  `BTreeMap`, the entry API.
- **CRM feature:** `Deal { company_id, title, value: Money, stage: DealStage }`
  (`Qualification → Proposal → Negotiation → Won | Lost`), `deal add / move / list`, and a
  `pipeline` report showing count and value per stage.
- **Outcome:** a working sales pipeline.
- **Why it matters:** the stage-transition rules carry over unchanged into the API and DB.

#### Lab 19 — Leads & Conversion
- **Rust concepts:** methods that **consume `self`**, ownership as a business rule, the
  builder pattern, `Option::take`, `std::mem::take`.
- **CRM feature:** `Lead` (an unqualified prospect, with `LeadSource`), `lead add / qualify / convert`.
  `Lead::convert(self) -> Conversion { company, contact, deal }`. After converting, the
  compiler won't let you touch the lead again.
- 💥 **Errors:** E0382 used *as a feature*: the compiler enforces your business rule.
- **Outcome:** a complete lead → customer flow.
- **Why it matters:** in Lab 31 this conversion becomes a single DB transaction. Because Postgres
  hands out IDs *inside* the transaction, `convert(self, ids)` is redesigned there into
  `plan_conversion(&self)`, and rollback takes over the "hand the lead back" job.

#### Lab 20 — Activities, Notes & Time
- **Rust concepts:** adding external crates (`cargo add`), semver and `Cargo.lock`, crate
  features, `chrono` dates and times, enums with rich data, **closed vs open polymorphism:
  enum vs `Box<dyn Trait>`** (with an experiment trying both).
- **CRM feature:** `Activity` with
  `ActivityKind::{Call { minutes }, Email { subject }, Meeting { starts_at, attendees }}`,
  attached to a `Subject::{Company, Contact, Deal}`; notes; `show deal 3` lists recent history.
- **Outcome:** every record has a history.
- **Why it matters:** this is the raw material for the capstone timeline.

#### 🏁 Challenge B — Sales Forecast
A `forecast` command: weighted pipeline value by stage probability, grouped by expected close
month. Spec and acceptance tests only.

---

### Phase 6 — Persistence & Quality

#### Lab 21 — Serialization & File Persistence
- **Rust concepts:** `serde` derive, `serde_json`, enum representations
  (`#[serde(tag = "...")]`), `#[serde(rename_all)]`, `std::fs`, `BufReader`/`BufWriter`,
  `std::io::Error`, atomic writes (write to a temp file, then rename).
- **CRM feature:** load the CRM from `crm-data.json` on start and save it on every change.
- **Outcome:** a CRM you could genuinely use day to day.
- **Why it matters:** the same `serde` derives become your HTTP JSON in Lab 27.

#### Lab 22 — Professional Error Handling ♻️
- **Rust concepts:** `thiserror` for library errors, `anyhow` for the application edge,
  error layering (domain → storage → app), `#[from]`, adding context, `Box<dyn Error>`, process
  exit codes. CLI-only errors (`UnknownCommand`, `Usage`) move out of the domain `CrmError` into
  a `CliError`: the library-vs-application split made concrete.
- **CRM feature:** refactor every error path. Users see "Could not save data to
  crm-data.json: permission denied", not a debug dump.
- **Outcome:** clean, layered errors.
- **Why it matters:** the domain error enum maps directly onto HTTP status codes in Lab 28.

#### Lab 23 — Traits as Boundaries: The Storage Layer ♻️
- **Rust concepts:** trait objects (`Box<dyn Storage>`), dyn compatibility (formerly "object
  safety"), dependency injection, `&dyn` vs generics trade-offs, command-line args with
  `clap`, environment variables (`CRM_DATA_FILE`).
- **CRM feature:** a `Storage` trait with `InMemoryStorage` and `JsonFileStorage`,
  selected with `--storage memory|json`.
- **Outcome:** business logic no longer knows where data lives.
- **Why it matters:** business logic not knowing where data lives is what makes the move to
  PostgreSQL (Labs 30–31) possible without rewriting the domain. The *shape* of the boundary
  (whole-snapshot load/save) will change for a database, and you'll see why.

#### Lab 24 — Testing Properly + Continuous Integration 🧪
- **Rust concepts:** unit vs integration tests (`tests/` only sees your public API, which is
  why Lab 13 mattered), shared test helpers, `tempfile`, testing with in-memory storage,
  doc tests, `cargo test <filter>`, `--nocapture`, a GitHub Actions workflow running
  `fmt --check`, `clippy -D warnings` and `test`.
- **CRM feature:** integration tests for lead conversion, the pipeline report and the
  persistence round trip; a CI badge on your README.
- **Outcome:** every push is automatically checked.
- **Why it matters:** the big refactors ahead (async, HTTP, Postgres) are safe because these
  tests exist.

#### 🏁 Challenge C — CSV Import
`import contacts.csv` using the `csv` crate. Bad rows don't abort the import; you get a
per-row error report. Spec, constraints and sample files only.

---

### Phase 7 — Concurrency & Async

#### Lab 25 — Threads & Shared State
- **Rust concepts:** `std::thread::spawn`, `move` closures, `JoinHandle`, `Arc`, `Mutex`,
  `RwLock`, `Send` and `Sync` (why `Rc` can't cross threads), channels (`mpsc`), deadlocks.
- **CRM feature:** a background autosave thread that shares the CRM with the REPL through
  `Arc<Mutex<Crm>>`, plus a shutdown signal over a channel.
- 💥 **Errors:** E0373 (closure may outlive the current function), E0277 (`Rc` is not `Send`).
- **Outcome:** two threads safely sharing CRM data. The compiler proves there are no data races.
- **Why it matters:** a web server handles requests concurrently. This is the same problem.

#### Lab 26 — Async Rust & Tokio ♻️
- **Rust concepts:** what a `Future` is (lazy, polled), `async`/`await`, why a runtime is
  needed, `#[tokio::main]`, `tokio::spawn` and its `'static + Send` bounds, `tokio::time`,
  `select!`, blocking vs non-blocking (`spawn_blocking`), `tokio::sync::Mutex` vs
  `std::sync::Mutex`.
- **CRM feature:** the REPL and autosave run on Tokio. The storage trait deliberately stays
  synchronous (file I/O is blocking) and is called through `spawn_blocking`; async traits come in Lab 31.
- **Outcome:** an async-ready codebase.
- **Why it matters:** Axum, SQLx and background jobs are all built on Tokio.

---

### Phase 8 — The CRM Becomes a Web API

#### Lab 27 — HTTP & Axum Basics
- **Rust concepts:** `Router`, handlers as async functions, extractors (`Path`, `Query`,
  `Json`, `State`), shared state with `Arc`, **request/response DTOs vs domain models** (and why
  to keep them separate), status codes.
- **CRM feature:** `GET /health`, `GET /companies`, `POST /companies`, `GET /companies/{id}`.
  The REPL moves to `src/bin/crm-cli.rs`; `main.rs` becomes the server.
- **Outcome:** `curl` talks to your CRM.
- **Why it matters:** from here on, the API is the product.

#### Lab 28 — API Error Handling & Validation
- **Rust concepts:** implementing `IntoResponse` for `AppError`, mapping domain errors to
  status codes (400/404/409/422/500), a consistent JSON error body, `TryFrom<CreateCompanyRequest>`
  for validation at the boundary, never leaking internal errors to clients.
- **CRM feature:** full CRUD for companies and contacts with predictable errors.
- **Outcome:** an API a frontend developer would enjoy using.

#### Lab 29 — The Full REST Surface 🧪
- **Rust concepts:** nested and merged routers, query params for filtering, sorting and
  pagination, modelling actions (`POST /deals/{id}/stage` vs `PATCH`), API tests with
  `tower::ServiceExt::oneshot` (no network needed).
- **CRM feature:** endpoints for contacts, leads (`POST /leads/{id}/convert`), deals,
  activities and notes, plus an API test suite.
- **Outcome:** the whole CRM over HTTP, fully tested.

#### 🏁 Challenge D — Tags
Many-to-many tags on companies and contacts, with `?tag=enterprise` filtering. Spec and API
contract only.

---

### Phase 9 — PostgreSQL

#### Lab 30 — PostgreSQL & SQLx ♻️
- **Rust concepts:** Postgres in Docker Compose (dev only), `DATABASE_URL` and `.env`,
  `sqlx-cli`, migrations, designing a schema from your domain types (foreign keys = the IDs from
  Lab 14), connection pools (`PgPool` in `State`), compile-time-checked `query!` /
  `query_as!`, offline mode (`.sqlx/`).
- **CRM feature:** companies and contacts stored in Postgres. All ID newtypes become `i64`
  (Postgres has no unsigned integers). **The terminal CLI is retired.** You'll write down *why*
  (concurrent writers, querying, integrity) before deleting it. Deals, leads, activities and
  notes stay on JSON storage for one more lab: a deliberate step-by-step ("strangler") migration.
- **Outcome:** a real database behind your API.

#### Lab 31 — Repositories on Postgres
- **Rust concepts:** `async fn` in traits and its dyn-compatibility limits (generics vs
  `async_trait`), `FromRow`, `sqlx::Type` for newtype IDs and enums, `Option` ↔ `NULL`,
  **transactions**, turning unique-constraint violations into domain errors (duplicate email → 409).
- **CRM feature:** all entities in Postgres; lead conversion is now atomic in a single
  transaction. Repositories end up as plain async functions taking `impl PgExecutor` (after you
  see the dyn-compatibility error for yourself). The `Entity` trait, `InMemoryRepo`, `Crm` and the
  storage layer are retired; the domain types and their unit tests survive unchanged.
- **Outcome:** the whole CRM persists in Postgres.

#### Lab 32 — Search, Filtering & Pagination in SQL
- **Rust concepts:** `QueryBuilder` for dynamic filters (and avoiding SQL injection),
  `ILIKE` vs Postgres full-text search, offset vs keyset pagination, indexes, the N+1 problem.
- **CRM feature:** `GET /search?q=` across companies, contacts and deals; the pipeline
  report moves from Rust iterators to SQL `GROUP BY` (with a comparison of both).
- **Outcome:** queries that stay fast with 100k rows (you'll seed them and measure).

#### Lab 33 — Database Integration Tests 🧪
- **Rust concepts:** `#[sqlx::test]` (a fresh database per test), fixtures, testing
  constraint errors and transaction rollback, organising `tests/api/`, a Postgres service
  container in GitHub Actions.
- **CRM feature:** a DB-backed test suite running in CI.
- **Outcome:** confidence that the real stack works, not just mocks.

---

### Phase 10 — Users, Authentication & Authorization

#### Lab 34 — Users & Password Hashing
- **Rust concepts:** the `User` model, `argon2` hashing and salts, why you never store or log
  plaintext, the `secrecy` crate (`SecretString` hides itself from `Debug`), uniqueness at the DB
  level.
- **CRM feature:** `users` table, `POST /auth/register`.

#### Lab 35 — Authentication
- **Rust concepts:** JWT access tokens (`jsonwebtoken`) and the trade-offs against server sessions, a
  custom `AuthUser` extractor via `FromRequestParts`, `axum::middleware::from_fn`, 401 handling,
  token expiry.
- **CRM feature:** `POST /auth/login`, `GET /me`; every CRM route requires auth; `owner_id` /
  `created_by` are filled in from the logged-in user.

#### Lab 36 — Authorization 🧪
- **Rust concepts:** `Role` enum (`Admin`, `Manager`, `SalesRep`), policy functions
  (`fn can(user, action, resource) -> bool`), enforcing in Rust vs in SQL `WHERE`, 403 vs 404
  (not leaking that a record exists).
- **CRM feature:** sales reps edit only their own deals; managers reassign; admins manage
  users. **Every rule has a test.**
- **Outcome:** a multi-user CRM with real access control.

#### 🏁 Challenge E — Teams
Teams of sales reps; managers can see and reassign deals within their team only. Spec, data
model constraints and authz acceptance tests.

---

### Phase 11 — Production-Ready

#### Lab 37 — Logging & Observability
- **Rust concepts:** `tracing` vs `log`, spans and events, `#[instrument]`, `tower-http`
  `TraceLayer`, request IDs, pretty logs in dev vs JSON in prod, `RUST_LOG`, keeping secrets out
  of logs.
- **CRM feature:** every request is traceable from HTTP to SQL.

#### Lab 38 — Configuration & Graceful Shutdown
- **Rust concepts:** a typed `Settings` struct, layered config (defaults → file → env),
  fail-fast validation at startup, secrets from the environment, signal handling, graceful
  shutdown in Axum.
- **CRM feature:** one config system replacing scattered `env::var` calls; clean shutdown.

#### Lab 39 — Background Jobs
- **Rust concepts:** a Postgres-backed job queue, `SELECT ... FOR UPDATE SKIP LOCKED`,
  worker tasks, retries with backoff, idempotency, `CancellationToken` for shutdown, a `Mailer`
  trait with a logging implementation.
- **CRM feature:** a nightly *stale deal* job (no activity in 14 days → follow-up task for
  the owner) and due-reminder notifications.
- **Outcome:** the CRM does work on its own, not only in response to requests.

#### Lab 40 — Docker & Deployment
- **Rust concepts:** multi-stage Dockerfile, `cargo-chef` layer caching, a small runtime image,
  `SQLX_OFFLINE`, running migrations at deploy time, release profile tuning, health and readiness
  checks, building the image in CI, deploying to a container host.
- **CRM feature:** `Dockerfile`, `docker-compose.yml` (API + Postgres), a live deployment,
  and a proper README for your CRM.
- **Outcome:** a deployed, production-style Rust backend.

---

### Capstone

#### Lab 41 — Customer Activity Timeline (spec only)
You get **requirements, acceptance criteria, constraints and the list of concepts you're
expected to use**, with no implementation steps. In outline:

- `GET /companies/{id}/timeline`: one chronological feed merging activities, notes,
  deal stage changes and lead conversions for the company and all its contacts and deals.
- Stage changes and conversions must be **recorded as events** (a schema change you design).
- Cursor pagination; filters by event type and date range.
- Respects authorization (no events from records the user can't see).
- Unit, DB and API tests; tracing spans; no new crates without justification.

Hints come in tiers (direction → design → near-solution), and a reference design is
available *after* you submit your own. Optional extension briefs: audit log, contact merge
(transactions + ownership), CSV export job, rate limiting.

---

## 4. Threads that run through the whole course

### Ownership never stops being taught
| Where | Ownership lesson in context |
|---|---|
| Labs 06–10 | Core rules, using customers |
| Lab 14 | Why relationships use IDs instead of references |
| Lab 17 | `iter` vs `iter_mut` vs `into_iter` |
| Lab 19 | Consuming `self` as a business rule |
| Lab 25 | `move` closures, `Arc`, `Send`/`Sync` |
| Lab 26 | `'static` bounds on spawned tasks |
| Lab 27 | Why Axum state must be `Clone` (and cheap: `Arc`) |

### Testing grows with the CRM
`Lab 05` unit tests → `Lab 12` error-case tests → `Lab 24` integration tests + CI →
`Lab 29` API tests → `Lab 33` database tests → `Lab 36` authorization tests → `Lab 41` all of the above.

### Deliberate refactors ♻️
| Lab | What changes | Why now |
|---|---|---|
| 08 | Store API reworked | You've hit the borrow checker enough to understand it |
| 11 | Strings → `Command` enum | Typos in commands were runtime bugs |
| 12 | `phone: String` → `Option<String>` | `""` was lying about "no phone" |
| 13 | One file → modules + `lib.rs` | `main.rs` is unmanageable, and you need privacy |
| 14 | Customer → Company + Contact | The domain was wrong for B2B |
| 16 | Duplicate stores → generic repo | You've copy-pasted twice: rule of three |
| 22 | Ad-hoc errors → layered errors | Errors now cross layers (storage, domain, UI) |
| 23 | Concrete storage → trait | You're about to need two (then three) backends |
| 26 | Sync → async | The web server needs it |
| 30 | CLI retired, IDs become `i64` | A real backend needs concurrency, integrity and queries |
| 31 | JSON storage and in-memory repo retired | Every entity now lives in Postgres; the domain logic survives untouched |

### Git history tells your learning story
Every lab ends with at least one meaningful commit, and every lab ends with a tag:

```bash
git tag lab-07
git push --tags
```

Later you can run `git diff lab-07 lab-08` and see exactly what the refactor changed.

---

## 5. How the architecture emerges

You will **not** start with this. Each shape below appears only when the previous one hurts.

**After Lab 05**: everything in one file. That's correct at this size.
```text
rust-crm/
├── Cargo.toml
└── src/main.rs
```

**After Lab 13**: `main.rs` passed 300 lines, and privacy is needed to protect `Email`.
```text
src/
├── main.rs          # just runs the REPL
├── lib.rs
├── errors.rs
├── cli/{mod.rs, parser.rs, commands.rs}
└── customers/{mod.rs, model.rs, store.rs, email.rs}
```

**After Lab 24**: more entities, a storage boundary, real tests.
```text
src/
├── main.rs
├── lib.rs
├── cli/
├── companies/  contacts/  deals/  leads/  activities/  notes/
├── storage/{mod.rs, memory.rs, json_file.rs}
└── errors.rs
tests/
.github/workflows/ci.yml
```

**After Lab 40**: a production backend. The domain from Labs 14–20 survives almost unchanged.
```text
rust-crm/
├── src/
│   ├── main.rs
│   ├── lib.rs
│   ├── config/
│   ├── http/            # router, middleware, error responses
│   ├── auth/
│   ├── users/
│   ├── companies/
│   ├── contacts/
│   ├── leads/
│   ├── deals/
│   ├── activities/
│   ├── notes/
│   ├── jobs/
│   ├── database/
│   └── errors/
├── tests/
├── migrations/
├── .sqlx/
├── Cargo.toml
├── Dockerfile
├── docker-compose.yml
└── README.md
```

> Note: there's no `customers/` folder at the end. In Lab 14 you'll discover that "customer" is
> a **lifecycle stage of a Company**, not a separate entity. Finding that out is part of the lesson.

---

## 6. Design decisions (and why)

| Decision | Choice | Reason |
|---|---|---|
| Interface for Labs 03–26 | Terminal REPL | Fast feedback loop while learning the language |
| Web framework | Axum | Built on Tokio and Tower; extractors teach traits well |
| Database | PostgreSQL + SQLx | Real SQL, compile-time-checked queries, no ORM hiding things |
| Error crates | `thiserror` + `anyhow` | The community standard split between library and application errors |
| Auth | Argon2 + short-lived JWT | Common in APIs; sessions are discussed as an alternative |
| Dates | `chrono` | Most widely used; `time` and `jiff` mentioned as alternatives |
| Rust edition | 2024 | Current stable edition |
| Solutions | In a separate `solutions.md` per lab | You only see them if you choose to |

The labs were written and verified against Rust 1.99 (edition 2024), axum 0.8, sqlx 0.9,
tokio 1.x, jsonwebtoken 11, argon2 0.6 and tower-http 0.7. Each lab names the versions it was
written against; if an API has moved on, check docs.rs for that crate.

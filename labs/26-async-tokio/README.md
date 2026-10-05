# Lab 26 — Async Rust & Tokio ♻️

> **Phase:** 7 — Concurrency & Async · **Builds on:** Lab 25 · **Time:** ~5–6 hours
> **Your repo before this lab:** tag `lab-25` · **After:** tag `lab-26`

> **This lab assumes you completed Your Turn 1 (`save` command) and Your Turn 3 (the
> poison-tolerant `lock` helper) in Lab 25.** If you didn't, copy them from Lab 25's
> [`solutions.md`](../25-threads-shared-state/solutions.md) first.

## 🎯 Goal

Move the CRM onto **Tokio**, Rust's most widely used async runtime. The autosave thread becomes
an async **task**. The REPL reads input through a new async `Input` type. Ctrl-C quits cleanly
with a final save. And no lock is held while a human is typing, which fixes the bug you found in
Lab 25's Experiment 3.

## 🧠 What You'll Learn

- What a `Future` really is: **a value, a state machine, that does nothing until polled**
- How `async fn` and `.await` compile into that state machine
- The runtime: an **executor** that polls tasks plus a **reactor** that knows when to poll again
- `#[tokio::main]`, `tokio::spawn`, and why spawned futures must be `Send + 'static`
- The famous error: *a `std::sync::MutexGuard` held across `.await` makes a future not `Send`*
- When to use `std::sync::Mutex` and when to use `tokio::sync::Mutex`
- Blocking vs non-blocking work: `spawn_blocking`, and a dedicated thread for stdin
- `tokio::time::interval`, `tokio::select!`, cancellation (and cancel-safety), `oneshot` channels
- `tokio::signal::ctrl_c` for a graceful exit
- An honest comparison with JavaScript Promises and the event loop

## 🔨 What We're Building

```text
Lab 25 (threads)                              Lab 26 (Tokio)
────────────────                              ──────────────
main thread:  blocking REPL                   main thread:   block_on(run())  ← REPL is a future
              holds lock while you type       stdin thread:  reads lines → channel → Input
autosave:     OS thread,                      autosave:      a Tokio *task*: interval + select!
              recv_timeout ticker                            saves on the blocking pool
stop:         mpsc + join                     stop:          oneshot + await JoinHandle
Ctrl-C:       kills the process (no save!)    Ctrl-C:        "Interrupted." → final save → exit
```

Why now? Axum (Lab 27), SQLx (Lab 30) and background jobs (Lab 39) are all async and all run on
Tokio. A web server spends almost all its time **waiting**: for the network, the database, the
disk. Async lets one thread wait for thousands of things at once. Before HTTP shows up, you'll
learn the model on code you already understand.

The roadmap said "the storage trait goes async" here. **We deliberately don't do that yet.** You
can't put `async fn` in a trait and still use it as `dyn Storage` without extra machinery, and
that's the main topic of Lab 31. Here the trait stays synchronous, and we learn to call
blocking code correctly from async code, which you'll need anyway.

---

## Step 1 — The mental model: a future is a value

Before writing any code, get this picture right. Everything else in this lab follows from it.

### A `Future` is a state machine

Here's the trait (simplified only by removing a `Pin` detail you don't need yet):

```rust
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> {
    Ready(T),
    Pending,
}
```

A future is **a value with a `poll` method**. Each call to `poll` asks: *"can you make progress
now?"* The future either finishes (`Ready(value)`) or says "not yet" (`Pending`). Before returning
`Pending` it hands the `Waker` from `cx` to whatever it's waiting on (a socket, a timer, a
channel). Later that thing calls `waker.wake()` to say "poll me again, I can make progress."

An `async fn` is turned into such a value by the compiler. Take this flow, which you'll write in
Step 5:

```rust
async fn add_company(input: &mut Input, state: &Mutex<AppData>) -> anyhow::Result<CompanyId> {
    let name = input.prompt("Name: ").await?;
    let website = input.prompt("Website: ").await?;
    Ok(write_crm(state, |crm| crm.add_company(name, optional(website)))?)
}
```

Calling `add_company(&mut input, &state)` **runs none of this code**. It returns a value of an
anonymous type that's roughly this enum:

```rust
enum AddCompanyFuture<'a> {
    Start        { input: &'a mut Input, state: &'a Mutex<AppData> },
    WaitingName  { input: &'a mut Input, state: &'a Mutex<AppData>, prompt: PromptFuture<'a> },
    WaitingSite  { input: &'a mut Input, state: &'a Mutex<AppData>, name: String,
                   prompt: PromptFuture<'a> },
    Done,
}
```

Each `.await` is a **possible suspension point**. Any local variable that is still alive across
an `.await` (like `name` above) becomes a **field of the state machine**, because the function's
stack frame is gone while it's suspended. The future value *is* the saved stack frame.

```text
poll #1:  Start → run until the first .await → inner prompt future is Pending
          → save `input`, `state` in WaitingName → return Pending
          … the user types; the stdin thread sends a line; the Waker fires …
poll #2:  WaitingName → inner prompt is Ready("Acme Corp") → name = "Acme Corp"
          → run to the next .await → Pending → save `name` in WaitingSite → return Pending
poll #3:  WaitingSite → Ready("https://…") → lock, add, unlock → return Ready(Ok(CompanyId(1)))
```

Keep two facts from this picture:

1. **Futures are lazy.** Nothing happens until someone polls. A future you never `.await` (or
   spawn) never runs.
2. **Whatever is alive across an `.await` is stored inside the future.** If that's a `String`,
   fine. If it's a `MutexGuard`… you'll find out in Step 6.

### Who calls `poll`? The runtime

Rust ships the `Future` trait but **no runtime**. You choose one. Tokio is two things:

```text
            ┌──────────────────────── Tokio runtime ─────────────────────────┐
            │                                                                │
 tasks ───► │  EXECUTOR: worker threads (one per CPU core by default)        │
 (spawned   │    each pops a ready task, calls poll() until it is Pending,   │
  futures)  │    then picks the next one. Idle workers steal from busy ones. │
            │                                       ▲  wake()                │
            │  REACTOR: OS event APIs (kqueue/epoll) │  "this socket is      │
            │    + timer wheel. Holds Wakers. When  │   readable", "500 ms   │
            │    an event happens, wakes the task.  │   elapsed"             │
            │                                                                │
            │  BLOCKING POOL: extra threads for spawn_blocking (up to 512)   │
            └────────────────────────────────────────────────────────────────┘
```

A **task** is a top-level future handed to the executor (`tokio::spawn`). `.await` *inside* a task
is not a new task: it's the same state machine, one level deeper.

### `.await` is a yield point, not a wait

When a future returns `Pending`, the worker thread **doesn't wait**. It goes and polls another
task. That's the whole trick: 10,000 open HTTP connections can share 8 threads, because a
connection waiting for bytes costs one small state-machine value, not one thread.

It also means **a task that never reaches an `.await` never gives the thread back**. If your code
blocks (sleeps, reads a file, waits on a `std` lock, runs a long loop) the worker thread is stuck,
and every other task scheduled on it is stuck too. Most of the rules in this lab exist to prevent
exactly that.

### Honest comparison: JavaScript Promises

You've written plenty of `async`/`await` in JS. The syntax is nearly the same, but the semantics
differ in ways that matter:

| | JavaScript `Promise` | Rust `Future` |
|---|---|---|
| Starts running | **Eagerly**, as soon as it's created | **Lazily**, only when polled (`.await`/spawn) |
| Who drives it | the engine's built-in event loop | a runtime library you pick (Tokio) |
| Threads | one thread; callbacks never run in parallel | Tokio: a pool of worker threads; tasks can **move between threads** at each `.await` |
| Shared data | no data races possible (one thread) | `Send`/`Sync` rules apply to tasks |
| Blocking | a `while(true)` freezes the whole page | a blocking call freezes *one worker* (or all, on a single-thread runtime) |
| Cancellation | none built in (`AbortController` is a convention) | **drop the future**: it simply never gets polled again |
| Result | can be awaited many times | `.await` consumes the future (takes it by value) |
| Representation | heap object + callback list | a plain value; size known at compile time; no allocation unless you box/spawn it |

The multi-threaded executor is the key difference. In Node, a `let x` captured by an async
callback is safe because nothing else runs at the same time. In Tokio, the rest of your task may
run on a **different thread** after any `.await`. That's why everything held across an `.await` in
a spawned task must be `Send`.

---

## Step 2 — Add Tokio; make `run` async

```bash
cargo add tokio --features full
```

(`full` turns on the runtime, timers, I/O, signals, sync primitives and macros. That's fine for an
application. Libraries usually pick only the features they need. Written against **tokio 1.53**.)

In `src/cli/mod.rs`, put `async` in front of `run`. Change nothing else yet:

```rust
pub async fn run(storage: Arc<dyn Storage>, autosave_every: Duration) -> anyhow::Result<()> {
```

In `src/main.rs`:

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let autosave_every = Duration::from_secs(args.autosave_secs);
    let storage = build_storage(args);
    rust_crm::cli::run(storage, autosave_every);
    Ok(())
}
```

> 🟡 **EXPERIMENT**: notice there's no `.await` after `run(…)`. Predict what `cargo run` prints.

```text
warning: unused implementer of `Future` that must be used
  --> src/main.rs:46:5
   |
46 |     rust_crm::cli::run(storage, autosave_every);
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |
   = note: futures do nothing unless you `.await` or poll them
   = note: `#[warn(unused_must_use)]` (part of `#[warn(unused)]`) on by default
```

And the program prints **nothing**: no banner, no prompt. It exits immediately. `run(…)` built a
state machine and returned it. We dropped it without polling, so not one line of `run` ever
executed. In JavaScript, calling an `async function` without `await` still runs it (and you get a
floating promise). In Rust it does nothing at all.

Now make the laziness visible, then fix it:

```rust
    let future = rust_crm::cli::run(storage, autosave_every);
    println!("(future created; nothing has run yet)");
    future.await
```

```text
(future created; nothing has run yet)
Rust CRM v0.1.0
Type 'help' for a list of commands.
Storage: JSON file crm-data.json
Loaded 0 companies, 0 contacts, 0 deals, 0 leads
crm>
```

The banner comes **after** our message, even though `run` was called first. Once you've seen
it, simplify to the line you'll keep:

```rust
    rust_crm::cli::run(storage, autosave_every).await
```

### What `#[tokio::main]` does

`main` itself can't be async. The OS calls it, and the OS doesn't poll futures. The attribute
rewrites your function into roughly:

```rust
fn main() -> anyhow::Result<()> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed building the Runtime")
        .block_on(async {
            // your async main body
        })
}
```

`block_on` is the bridge from the blocking world to the async world. It polls one future on
the **current** thread, parking the thread while it's `Pending`, until it's `Ready`.

### It compiles… but nothing is async yet

`run` is `async`, but `repl` (Lab 25) and the `prompt`/`prompt_optional` helpers still call
`io::stdin().read_line`, which **blocks**. So far we have only *wrapped* blocking code in a
future. The autosave is still an OS thread. The next steps replace every blocking piece, one at a
time.

---

## Step 3 — `Input`: one owner of standard input

The REPL (`repl`) and every `prompt(...)`/`prompt_optional(...)` call read stdin with the blocking
`io::stdin().read_line` in `src/cli/mod.rs`. We need an async version: "give me the next line;
until it arrives, let other tasks run."

### Why not `tokio::io::stdin()`?

Tokio has an async `stdin()`, and wrapping it is the obvious choice. It has a catch, and Tokio's
docs say so: there's no portable non-blocking API for a terminal, so `tokio::io::stdin()` does
a **blocking read on a hidden blocking-pool thread**. When your program wants to exit, the
runtime waits for its blocking threads to finish, and that one is stuck in `read()` until the
user presses Enter. You'll reproduce this in 🧪 Experiment 2: after Ctrl-C the CRM says "Goodbye!"
and then hangs.

Tokio's docs recommend a **dedicated OS thread** for interactive input, so that's what we do.
It's a nice reunion with Lab 25: a thread does the blocking work and a **channel** carries each
line to async code.

> 🟢 **FOLLOW ALONG**: create `src/cli/input.rs`:

```rust
//! Asynchronous line input for the REPL.

use std::io::{self, BufRead, Write};
use std::thread;

use anyhow::Context;
use tokio::sync::mpsc;

/// The one and only reader of standard input.
///
/// A plain OS thread does the blocking reads and hands each line to async
/// code through a channel. Because it is *not* a Tokio task, the runtime never
/// waits for it at shutdown: when `main` returns, the process exits.
pub(crate) struct Input {
    lines: mpsc::Receiver<io::Result<String>>,
}

impl Input {
    pub(crate) fn new() -> Self {
        let (tx, rx) = mpsc::channel(1);
        thread::spawn(move || {
            for line in io::stdin().lock().lines() {
                // `blocking_send` waits until the REPL has taken the previous line.
                if tx.blocking_send(line).is_err() {
                    break; // the REPL is gone
                }
            }
            // Dropping `tx` here tells the receiver: end of input.
        });
        Self { lines: rx }
    }

    /// Print `label` and wait for one line. `Ok(None)` means end of input (Ctrl-D).
    pub(crate) async fn read_line(&mut self, label: &str) -> anyhow::Result<Option<String>> {
        print!("{label}");
        io::stdout().flush()?;
        match self.lines.recv().await {
            Some(line) => Ok(Some(line?.trim().to_string())),
            None => Ok(None),
        }
    }

    /// Like `read_line`, but end of input is an error: we're in the middle of a command.
    pub(crate) async fn prompt(&mut self, label: &str) -> anyhow::Result<String> {
        self.read_line(label)
            .await?
            .context("input ended in the middle of a command")
    }
}
```

And in `src/cli/mod.rs`: `mod input;` and `use input::Input;`.

Things to notice:

- **`tokio::sync::mpsc`, not `std::sync::mpsc`.** The receiving side is async: `recv().await`
  returns `Pending` while the channel is empty, so the worker thread is free. The sending side is
  in a plain thread, so it uses `blocking_send` (never call that from async code: it would block
  a worker). This channel is the bridge between the two worlds.
- **Capacity `1`.** The reader thread stays at most a line or two ahead. That's backpressure: a
  bounded channel makes a fast producer wait for a slow consumer.
- **Exactly one `Input`.** Only one thing may read stdin. `io::stdin().lock()` gives the reader
  thread exclusive access, and every prompt in the program borrows the same `Input`
  (`&mut Input`). If two readers raced for stdin, each would grab random lines from the other,
  and with buffering one can swallow lines meant for the other. Ownership turns "one reader" from
  a convention into a rule.
- **`read_line` vs `prompt`.** At `crm>`, end of input means "quit", so it's `Ok(None)`. In the
  middle of `company add` it's an error. Two methods, two meanings, and the types say which.
- `print!` + `flush` are blocking calls on stdout. Writing a short line to a terminal takes
  microseconds, so we accept it. Reading is different: a read waits on a *human*.

---

## Step 4 — Prompt first, lock second

Now the commands. In Lab 25 the REPL did this:

```rust
let mut data = lock(state);                             // lock …
let result = commands::execute(&mut data.crm, command); // … while execute PROMPTS the user
```

So the lock was held while you typed (Experiment 3). With async prompts it gets worse. Let's see
why with a 🟡 experiment. It's the most common mistake people make when moving to async Rust.

> 🟡 **EXPERIMENT**: imagine the most direct port of `company add`: take the lock, then prompt
> with `.await`:
>
> ```rust
>         CompanyCommand::Add => {
>             // 🟡 lock first, then prompt
>             let mut data = state.lock().unwrap();
>             let name = input.prompt("Name: ").await?;
>             let website = optional(input.prompt("Website (optional): ").await?);
>             let id = data.crm.add_company(name, website)?;
>             data.dirty = true;
>             println!("Added company {id}");
>         }
> ```

`cargo check` accepts this! The REPL future isn't spawned (it's polled by `block_on`), so nothing
requires it to be `Send`. But `cargo clippy` catches it:

```text
warning: this `MutexGuard` is held across an await point
  --> src/cli/commands.rs:90:17
   |
90 |             let mut data = state.lock().unwrap();
   |                 ^^^^^^^^
   |
   = help: consider using an async-aware `Mutex` type or ensuring the `MutexGuard` is dropped before calling `await`
note: these are all the await points this lock is held through
  --> src/cli/commands.rs:91:47
   |
91 |             let name = input.prompt("Name: ").await?;
   |                                               ^^^^^
92 |             let website = optional(input.prompt("Website (optional): ").await?);
   |                                                                         ^^^^^
   = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.99.0/index.html#await_holding_lock
   = note: `#[warn(clippy::await_holding_lock)]` on by default
```

Your CI runs `clippy -D warnings` (Lab 24), so this would fail the build. That's good, because
it's a real bug. While this future is suspended waiting for the user, it holds the `std` lock.
The autosave task (Step 6) then calls `lock()` and **blocks its thread** until you finish typing.
On a single-threaded runtime it's worse: the blocked thread is the one that would have to resume
the REPL, so it **deadlocks**.

The fix is structural, not a different lock: **talk to the human first, touch the data second.**
Gather all input with `.await`, then take the lock for a short synchronous moment.

### Make the rule hard to break: closure-scoped locks

> 🟢 **FOLLOW ALONG**: add two helpers to `src/cli/autosave.rs`, next to `lock`:

```rust
/// Run `f` with read access to the CRM. The lock is held only while `f` runs.
pub(crate) fn read_crm<R>(state: &Mutex<AppData>, f: impl FnOnce(&Crm) -> R) -> R {
    let data = lock(state);
    f(&data.crm)
}

/// Run `f` with write access to the CRM and mark the data as dirty.
/// The lock is held only while `f` runs.
pub(crate) fn write_crm<R>(state: &Mutex<AppData>, f: impl FnOnce(&mut Crm) -> R) -> R {
    let mut data = lock(state);
    data.dirty = true;
    f(&mut data.crm)
}
```

These are generic over the closure's return type `R`, so they work for "print a list" (`R = ()`)
and for "add and give me the id" (`R = Result<CompanyId, CrmError>`). `FnOnce` (Lab 17) because
each closure is called exactly once, so it may move captured `String`s into the `Crm`.

The important part: **the closure is a normal, synchronous function, so you cannot `.await`
inside it.** Try:

> 🟡 **EXPERIMENT**: put the prompts *inside* the `write_crm` closure and `cargo check`.
>
> ```rust
>             // 🟡 prompt *inside* the locked section
>             let id = write_crm(state, |crm| {
>                 let name = input.prompt("Name: ").await?;
>                 let website = optional(input.prompt("Website (optional): ").await?);
>                 crm.add_company(name, website)
>             })?;
> ```

```text
error[E0728]: `await` is only allowed inside `async` functions and blocks
  --> src/cli/commands.rs:91:51
   |
90 |             let id = write_crm(state, |crm| {
   |                                       ----- this is not `async`
91 |                 let name = input.prompt("Name: ").await?;
   |                                                   ^^^^^ only allowed inside `async` functions and blocks
```

(and the same for the second `.await`). That's the design working. "Never hold the lock across
an `.await`" is now enforced by the compiler, with no reviewer or lint needed. The guard can't escape the helper (it's a local
there), and nothing inside can suspend.

`write_crm` marks the data dirty even if the closure returns an `Err`. That might cause an
unnecessary save. That's harmless, and it keeps the helper simple. (`Command::is_mutating()` is
no longer needed: delete it, the whole `impl Command<'_>` block in `parser.rs`, when the compiler
tells you it's unused.)

---

## Step 5 — An async `execute`

> 🟢 **FOLLOW ALONG**: in `src/cli/commands.rs`, `execute` becomes `async` and receives the shared
> state and the `Input` instead of `&mut Crm`:

```rust
use std::fmt::Display;
use std::sync::Mutex;

use chrono::{DateTime, NaiveDateTime, Utc};

use super::autosave::{AppData, read_crm, write_crm};
use super::error::CliError;
use super::input::Input;
// ... the other imports unchanged
```

```rust
/// Runs one command. Printing happens here; errors are returned.
pub(crate) async fn execute(
    state: &Mutex<AppData>,
    input: &mut Input,
    command: Command<'_>,
) -> anyhow::Result<()> {
    match command {
        Command::Help => print_help(),
        Command::Version => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
        Command::Quit | Command::Save => {} // handled by the REPL loop
        Command::Stats => read_crm(state, print_stats),
        Command::Company(command) => company(state, input, command).await?,
        // Not converted yet: that's Your Turn 1.
        Command::Contact(_) | Command::Deal(_) | Command::Lead(_) | Command::LogActivity { .. } => {
            anyhow::bail!("this command is being converted to async (Lab 26, Your Turn 1)")
        }
        Command::Pipeline => read_crm(state, print_pipeline),
        Command::AddNote { subject, body } => {
            let id = write_crm(state, |crm| crm.add_note(subject, body, Utc::now()))?;
            println!("Added note {id} to {subject}");
        }
        Command::History { subject } => read_crm(state, |crm| {
            crm.check_subject(subject)?;
            let history = crm.history(subject);
            if history.is_empty() {
                println!("No history for {subject} yet.");
            }
            for item in &history {
                println!("{item}");
            }
            Ok::<(), CrmError>(())
        })?,
    }
    Ok(())
}
```

`print_stats` and `print_pipeline` already take a `&Crm`, so they can be handed to `read_crm`
as they are: a function item is a closure too. The note and history code is Lab 20's, moved
into `write_crm`/`read_crm`.

Why `anyhow::Result<()>` now, instead of Lab 22's `Result<(), CliError>`? `execute` can now fail
in a third way. Besides a usage error (`CliError::Usage`) and a domain error (`CrmError`, which
`CliError::Domain` wraps), there's an input error from `Input::prompt` (end of input, I/O).
`anyhow` holds any of them, and `?` converts each one: a `CliError`, a `CrmError` or a
`ValidationError` all go straight into `anyhow::Error`. `CliError` doesn't go away: the parser
still returns it, and handlers still build `CliError::Usage(…)` for bad input. The REPL prints
`Error: {e:#}`: the `#` makes `anyhow` print the whole cause chain, `outer: cause: root`, exactly
like Lab 22's `error_chain`, so every message is the same as before.

The company commands, converted:

```rust
async fn company(
    state: &Mutex<AppData>,
    input: &mut Input,
    command: CompanyCommand,
) -> anyhow::Result<()> {
    match command {
        CompanyCommand::Add => {
            // 1. Talk to the human. No lock held: this can take minutes.
            let name = input.prompt("Name: ").await?;
            let website = optional(input.prompt("Website (optional): ").await?);
            // 2. Touch the CRM. Lock held for microseconds.
            let id = write_crm(state, |crm| crm.add_company(name, website))?;
            println!("Added company {id}");
        }
        CompanyCommand::List { filter } => read_crm(state, |crm| {
            let companies = crm.list_companies(&filter);
            if companies.is_empty() {
                println!("No companies match.");
            } else {
                print_table(COMPANY_HEADER, &companies);
            }
        }),
        CompanyCommand::Show { id } => read_crm(state, |crm| {
            let company = crm.company(id)?;
            print_table(COMPANY_HEADER, &[company]);
            println!();
            let contacts = crm.contacts_of(id);
            if contacts.is_empty() {
                println!("No contacts yet.");
            } else {
                print_table(CONTACT_HEADER, &contacts);
            }
            print_recent_history(crm, Subject::Company(id));
            Ok::<(), CrmError>(())
        })?,
        CompanyCommand::Stage { id, lifecycle } => {
            write_crm(state, |crm| crm.set_lifecycle(id, lifecycle))?;
            println!("Company {id} is now {lifecycle}.");
        }
        CompanyCommand::Delete { id } => {
            let company = write_crm(state, |crm| crm.remove_company(id))?;
            print_deleted("company", &company);
        }
    }
    Ok(())
}

/// Blank means `None`. (`prompt_optional` did the reading too; now `Input` reads.)
fn optional(answer: String) -> Option<String> {
    Some(answer).filter(|s| !s.is_empty())
}
```

The bodies are your Lab 14–20 code: the same prompts, `print_table`, `print_deleted` and
`print_recent_history`. Only *where* the CRM comes from changed. `optional` is new: Lab 20's
`prompt_optional` both read the line and turned blank into `None`, and now `Input` does the
reading.

Two details:

- **`Ok::<(), CrmError>(())`.** Inside `Show`, the closure uses `?`, so it must return a `Result`.
  But nothing tells the compiler *which* error type. `?` can convert into many types. The
  turbofish on the final `Ok` pins it down, so `R = Result<(), CrmError>`, and the outer `?`
  turns it into `anyhow::Error`.
- **Printing inside `read_crm`** happens while the lock is held. Printing a list takes
  microseconds and needs no `.await`, so that's fine. The rule isn't "hold the lock as briefly
  as humanly possible". It's "**never across a wait whose length you don't control**".

### The compiler's to-do list

Your old blocking command handlers (contacts, deals, leads, activity logging, and their helpers)
and the old blocking `prompt`/`prompt_optional` helpers in `mod.rs` are now unused. Once `run` is
rewired (Step 7), `cargo check` lists them:

```text
warning: function `prompt_optional` is never used
   --> src/cli/mod.rs:118:4
warning: function `prompt` is never used
   --> src/cli/mod.rs:123:4
warning: function `contact` is never used
   --> src/cli/commands.rs:134:4
warning: function `deal` is never used
   --> src/cli/commands.rs:182:4
warning: function `lead` is never used
   --> src/cli/commands.rs:218:4
warning: function `log_activity` is never used
   --> src/cli/commands.rs:274:4
warning: function `parse_datetime` is never used
   --> src/cli/commands.rs:317:4
warning: function `parse_contact_ids` is never used
   --> src/cli/commands.rs:330:4
warning: function `update_contact` is never used
   --> src/cli/commands.rs:366:4
warning: function `read_company_id` is never used
   --> src/cli/commands.rs:384:4
warning: method `is_mutating` is never used
  --> src/cli/parser.rs:65:19
```

Delete `is_mutating` now (Step 4). The rest is your Your Turn 1 checklist. Leave them for now.
(`cargo test` won't build yet either: the unit test `unknown_ids_are_not_found` at the bottom of
`commands.rs` still calls the old `execute(&mut crm, command)`. That's Your Turn 1 too.)

---

## Step 6 — Autosave becomes a task

The Lab 25 thread used `recv_timeout` as "tick or stop". The async version uses two tools:

- `tokio::time::interval`: a timer that yields a tick every period. Waiting on it costs no
  thread.
- `tokio::select!`: **wait for several futures, run the branch of whichever finishes first, and
  drop (cancel) the others.**

And a `tokio::sync::oneshot` channel for "stop": one message, one sender, one receiver.

### First attempt

> 🟡 **EXPERIMENT**: here's a natural first version, "check and save, then wait for the next
> tick". Replace `spawn_autosave` in `src/cli/autosave.rs` with it, update the imports, and run
> `cargo check`. (Also update `run` as shown in Step 7, or temporarily ignore the errors there.)

```rust
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::sync::oneshot;
use tokio::task::{self, JoinHandle};
use tokio::time::{self, Instant, MissedTickBehavior};
```

```rust
pub(crate) fn spawn_autosave(
    state: Arc<Mutex<AppData>>,
    storage: Arc<dyn Storage>,
    every: Duration,
    mut shutdown: oneshot::Receiver<()>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = time::interval_at(Instant::now() + every, every);
        loop {
            // 🟡 first attempt: check-and-save, then wait for the next tick
            let mut data = state.lock().unwrap();
            if data.dirty {
                report(storage.save(&data.crm).map(|()| true));
                data.dirty = false;
            }
            tokio::select! {
                _ = ticker.tick() => {}
                _ = &mut shutdown => break,
            }
        }
    })
}
```

```text
error: future cannot be sent between threads safely
   --> src/cli/autosave.rs:69:5
    |
 69 | /     tokio::spawn(async move {
 70 | |         let mut ticker = time::interval_at(Instant::now() + every, every);
 71 | |         loop {
...   |
 83 | |     })
    | |______^ future created by async block is not `Send`
    |
    = help: within `{async block@src/cli/autosave.rs:69:18: 69:28}`, the trait `Send` is not implemented for `std::sync::MutexGuard<'_, AppData>`
note: future is not `Send` as this value is used across an await
   --> src/cli/autosave.rs:78:13
    |
 73 |               let mut data = state.lock().unwrap();
    |                   -------- has type `std::sync::MutexGuard<'_, AppData>` which is not `Send`
...
 78 | /             tokio::select! {
 79 | |                 _ = ticker.tick() => {}
 80 | |                 _ = &mut shutdown => break,
 81 | |             }
    | |_____________^ await occurs here, with `mut data` maybe used later
note: required by a bound in `tokio::spawn`
   --> ~/.cargo/registry/src/index.crates.io-…/tokio-1.53.2/src/task/spawn.rs:176:21
    |
174 |     pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
    |            ----- required by a bound in this function
175 |     where
176 |         F: Future + Send + 'static,
    |                     ^^^^ required by this bound in `spawn`
    = note: this error originates in the macro `$crate::select` which comes from the expansion of the macro `tokio::select` (in Nightly builds, run with -Z macro-backtrace for more info)
```

**Read the error with the Step 1 picture in mind.**

- `tokio::spawn` requires `F: Future + Send + 'static`. Tokio's executor is multi-threaded and
  **work-stealing**: after any `.await`, the task may be resumed by a *different* worker thread.
  So the whole future must be safe to move between threads.
- What's in the future? Every local alive across an `.await` (Step 1). `data` is declared in
  the loop body and lives until the end of the body, which is *after* the `select!`, so it's
  alive at that `.await`. The `MutexGuard` becomes a field of the state machine.
- `MutexGuard` is **not `Send`** (Lab 25's table). Some operating systems require a mutex to be
  unlocked by the same thread that locked it. A guard that travels to another thread and unlocks
  there would break that rule.
- So the future isn't `Send`, and `spawn` refuses it.

The compiler caught three bugs for the price of one: the thread-hopping problem, the "lock held
while sleeping for 30 seconds" problem, and the deadlock you'd get when the REPL tries to lock
while this task sleeps holding it.

> 🟡 **EXPERIMENT**: add `drop(data);` just before `tokio::select!` and `cargo check` again.

Still the same error, *"with `mut data` maybe used later"*. The analysis of what's alive across
an `.await` is conservative. In current Rust an explicit `drop` sometimes satisfies it and
sometimes doesn't (here it doesn't). **Don't rely on `drop()` for this.** Use one of the two
reliable fixes:

1. a **block** that ends before the `.await`: `{ let mut data = …; … } // dropped here`
2. a **synchronous function** that takes the lock and returns, like `save_if_dirty`, which you
   already have.

### The real version

Option 2 is better for another reason too: `storage.save(…)` is **blocking file I/O**. Called
directly inside a task, it would block a worker thread for as long as the disk takes. That's what
`spawn_blocking` is for: run a closure on Tokio's **blocking pool**, a separate set of threads
where blocking is allowed, and `.await` its result.

> 🟢 **FOLLOW ALONG**: the final `spawn_autosave`, plus a helper:

```rust
/// Start the autosave task. It saves every `every` if the CRM is dirty,
/// and does one final save when `shutdown` fires (or its sender is dropped).
pub(crate) fn spawn_autosave(
    state: Arc<Mutex<AppData>>,
    storage: Arc<dyn Storage>,
    every: Duration,
    mut shutdown: oneshot::Receiver<()>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        // `interval` ticks immediately the first time; start one period from now instead.
        let mut ticker = time::interval_at(Instant::now() + every, every);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = ticker.tick() => save_in_background(&state, &storage).await,
                _ = &mut shutdown => break,
            }
        }
        save_in_background(&state, &storage).await; // final save
    })
}

/// File I/O blocks, so it runs on Tokio's blocking thread pool, not on a worker thread.
async fn save_in_background(state: &Arc<Mutex<AppData>>, storage: &Arc<dyn Storage>) {
    let state = Arc::clone(state);
    let storage = Arc::clone(storage);
    let result = task::spawn_blocking(move || save_if_dirty(&state, &*storage)).await;
    match result {
        Ok(saved) => report(saved),
        Err(join_error) => eprintln!("Error: autosave task failed: {join_error}"),
    }
}
```

Update the module comment and the `AppData` doc comment from "thread" to "task". Then walk
through it:

- **`save_if_dirty` is unchanged from Lab 25.** It's synchronous: it locks, saves, unlocks. It
  runs entirely on a blocking-pool thread, and the guard never sees an `.await`. Code you wrote
  for threads works unchanged inside async code, as long as you call it from the right place.
- **`spawn_blocking` has the same `'static` requirement as `thread::spawn`**, for the same
  reason: the closure runs on another thread and might outlive the caller. So
  `save_in_background` clones the two `Arc`s and **moves** them in. Two atomic increments, no data
  copied. (🧪 Experiment 3 shows what happens if you try to borrow instead.)
- **`.await` on a `JoinHandle`** gives `Result<T, JoinError>`. `Err` means the closure panicked
  (or the runtime is shutting down). We report it instead of crashing the autosave task.
- **`&mut shutdown` in `select!`.** `select!` *drops* the futures of the branches that lose. If
  we wrote `shutdown` instead of `&mut shutdown`, the receiver itself would be moved into the
  first `select!` and dropped after the first tick. By polling a **mutable reference**, the
  receiver survives across loop iterations.
- **`ticker.tick()` is safe to cancel.** If `shutdown` wins, the in-progress `tick()` future is
  dropped. Tokio documents `tick()` as *cancel-safe*: dropping it loses nothing. When you put a
  future in `select!`, always check this. (A future that had read half a message and is then
  dropped would lose the half.)
- **`interval_at(now + every, every)`** because a plain `interval` fires its first tick
  immediately. **`MissedTickBehavior::Delay`**: if a save takes longer than the period, don't
  fire a burst of catch-up ticks afterwards.
- When `shutdown`'s sender is dropped without sending, `&mut shutdown` completes with an `Err`,
  and `_ =` matches that too. Same "disconnected means stop" behaviour as Lab 25.

### Your Lab 25 tests

The three `spawn_autosave` tests from Lab 25 (Your Turn 2) used `std::sync::mpsc` and
`JoinHandle::join`. They don't compile anymore. **Delete them and `CountingStorage` for now.**
They're in Lab 25's solutions.md, and Your Turn 3 brings them back as async tests. Keep
`lock_recovers_from_a_poisoned_mutex` and the small `state(dirty)` helper it uses. The test needs
`use std::thread;` inside `mod tests`, now that the module no longer imports `thread` at the top.

---

## Step 7 — The async REPL, with Ctrl-C

> 🟢 **FOLLOW ALONG**: the new `run` and `repl` in `src/cli/mod.rs` (`APP_NAME`, `PAGE_SIZE`,
> `count` and, until Your Turn 1, the old `prompt`/`prompt_optional` helpers stay as they are):

```rust
mod autosave;
mod commands;
mod error;
mod input;
mod parser;

use std::io::{self, Write}; // only for the old prompt helpers; goes away in Your Turn 1
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Context;
use tokio::sync::oneshot;
use tokio::task;

use crate::errors::error_chain;
use crate::storage::Storage;
use autosave::{AppData, save_if_dirty, spawn_autosave};
use input::Input;
use parser::Command;

/// Runs the interactive CRM until the user quits (or stdin closes).
pub async fn run(storage: Arc<dyn Storage>, autosave_every: Duration) -> anyhow::Result<()> {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");
    println!("Storage: {}", storage.describe());

    let crm = storage
        .load()
        .context("refusing to start, so the data file is not overwritten")?;
    println!(
        "Loaded {}, {}, {}, {}",
        count(crm.companies.len(), "company", "companies"),
        count(crm.contacts.len(), "contact", "contacts"),
        count(crm.deals.len(), "deal", "deals"),
        count(crm.leads.len(), "lead", "leads"),
    );

    let state = Arc::new(Mutex::new(AppData { crm, dirty: false }));
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let autosave = spawn_autosave(
        Arc::clone(&state),
        Arc::clone(&storage),
        autosave_every,
        shutdown_rx,
    );

    let mut input = Input::new();
    let result = repl(&state, &storage, &mut input).await;

    // Whatever happened in the REPL, stop the autosave task cleanly.
    let _ = shutdown_tx.send(());
    autosave.await.context("autosave task panicked")?;

    let commands_run = result?;
    println!("Goodbye! ({commands_run} commands this session)");
    Ok(())
}

/// The read-eval-print loop. Returns how many commands were run.
async fn repl(
    state: &Arc<Mutex<AppData>>,
    storage: &Arc<dyn Storage>,
    input: &mut Input,
) -> anyhow::Result<usize> {
    let mut count = 0;

    loop {
        let line = tokio::select! {
            line = input.read_line("crm> ") => line?,
            _ = tokio::signal::ctrl_c() => {
                println!();
                println!("Interrupted.");
                break;
            }
        };
        let Some(line) = line else {
            println!();
            break; // Ctrl-D / end of input
        };

        let result = match parser::parse_command(&line) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break,
            Ok(Some(Command::Save)) => {
                let state = Arc::clone(state);
                let storage = Arc::clone(storage);
                match task::spawn_blocking(move || save_if_dirty(&state, &*storage)).await? {
                    Ok(true) => println!("Saved."),
                    Ok(false) => println!("Nothing to save."),
                    Err(e) => println!("Error: {}", error_chain(&e)),
                }
                Ok(())
            }
            Ok(Some(command)) => commands::execute(state, input, command).await,
            Err(e) => Err(e.into()),
        };
        count += 1;

        if let Err(e) = result {
            // `{:#}` prints the whole cause chain, like `error_chain`.
            println!("Error: {e:#}");
        }
    }
    Ok(count)
}
```

What changed, and why:

- **`oneshot::channel()`** replaces `mpsc::channel()`. "Stop" is sent once, and `oneshot` says so
  in the type. `send` consumes the sender, so you can't send twice.
- **`autosave.await`** replaces `join()`. A Tokio `JoinHandle` is itself a future. Awaiting it
  yields the worker thread instead of blocking it.
- **`select!` between a line and Ctrl-C.** Once `ctrl_c()` has been called, Tokio installs a
  handler for SIGINT, so Ctrl-C no longer kills the process. It completes this future instead,
  and we break out, stop autosave (which does its final save), and say goodbye. In Lab 25,
  Ctrl-C killed the process and lost everything since the last tick.
- **Is `read_line` cancel-safe?** If Ctrl-C wins, the `read_line` future is dropped. It may
  already have printed `crm> `, but it has only been *waiting* on `recv()`, which is cancel-safe
  (Tokio's docs say so): no line is lost. This is exactly why the line comes through a channel.
- **`repl` takes `&Arc<…>` now, not `&Mutex<…>`**: the `Save` arm has to *clone* the `Arc`s
  to move them into `spawn_blocking`. A `&Mutex` can't be turned back into an `Arc`.
- `commands::execute(state, input, command)`: `state` is `&Arc<Mutex<AppData>>`, and deref
  coercion turns it into the `&Mutex<AppData>` that `execute` wants.
- **The `match` keeps Lab 25's shape**: one `result` per command, counted, and printed if it's an
  `Err`. A parse error (`CliError`) becomes an `anyhow::Error` with `e.into()`, so both kinds of
  error are printed by the same `{e:#}`.
- **`repl` returns `anyhow::Result<usize>` now.** Reading a line can fail (`line?`), and so can
  the `Save` arm's `.await?` on the blocking task. Lab 25's structure pays off: `?` only leaves
  `repl`, and `run` still stops the autosave task before it looks at `result`.

`src/main.rs` keeps `#[tokio::main]` and ends with:

```rust
    rust_crm::cli::run(storage, autosave_every).await
```

```bash
cargo check     # only the dead-code warnings from Step 5 remain
```

---

## ▶️ Run It

```bash
rm -f lab26-demo.json
cargo run -- --data-file lab26-demo.json --autosave-secs 2
```

Type, in this order: `company add`, `Acme Corp`, `https://acme.example`, `company add`,
`Globex`, (Enter), `company list`, then `contact add` (not converted yet), then
`company stage 1 customer`, `company show 1`, `save`, and finally press **Ctrl-C**.

Then: `grep -c '"name"' lab26-demo.json`

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Storage: JSON file lab26-demo.json
Loaded 0 companies, 0 contacts, 0 deals, 0 leads
crm> company add
Name: Acme Corp
Website (optional): https://acme.example
Added company #1
crm> company add
Name: Globex
Website (optional):
Added company #2
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  https://acme.example
#2   Globex               prospect  -
crm> contact add
Error: this command is being converted to async (Lab 26, Your Turn 1)
crm> company stage 1 customer
Company #1 is now customer.
crm> company show 1
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            customer  https://acme.example

No contacts yet.
  No history yet.
crm> save
Saved.
crm> ^C
Interrupted.
Goodbye! (7 commands this session)
```

```text
$ grep -c '"name"' lab26-demo.json
2
```

The `^C` is your terminal echoing the keypress. The program exits **immediately** after
"Goodbye!". (The banner lines and the table formatting come from your own Lab 24 banner and
`Display` impls, so wording and spacing may differ.)
Whether `save` prints `Saved.` or `Nothing to save.` depends on whether a 2-second tick got
there first. Both are correct. Try the `save` command right after a change to see `Saved.`.

---

## 🧠 Understand It

### Where everything runs now

```text
OS threads in the process
─────────────────────────
main thread        block_on(run()) ── polls the REPL future (run → repl → execute → company …)
tokio-runtime-worker × N   poll spawned tasks: the autosave task
blocking pool (on demand)  save_if_dirty → storage.save(...)   (from autosave or `save`)
stdin reader thread        io::stdin().lock().lines() → blocking_send → channel

shared: Arc<Mutex<AppData>>  ── locked only inside read_crm / write_crm / save_if_dirty,
                                all synchronous: no guard ever crosses an .await
```

The REPL future is **not** spawned. It's the one future `block_on` drives on the main thread.
That's why it didn't need to be `Send` and the clippy lint was the only thing that caught the
guard-across-await. The autosave task **is** spawned, so the compiler checked it for real.

### `std::sync::Mutex` or `tokio::sync::Mutex`?

| | `std::sync::Mutex` | `tokio::sync::Mutex` |
|---|---|---|
| `lock()` | blocks the thread until free | `lock().await`: **yields** until free |
| guard is `Send` | no | yes |
| can hold guard across `.await` | **never** | yes (that's its purpose) |
| cost | very cheap | more expensive (it's an async queue) |
| use when | the critical section is short and synchronous (almost always) | you *must* hold the lock across an `.await`, e.g. a shared connection you write to asynchronously |

Tokio's own documentation recommends the `std` mutex for data like our `Crm`. With the
"prompt first, lock second" design we never need to hold it across an `.await`. The tokio
mutex isn't a fix for slow critical sections. It just lets them be slow without freezing a thread.
If you'd used it in Step 4's bad version, the autosave task would have **waited politely for a
whole minute** while you typed. No error, no lint, just a quieter version of the same bug.

### Blocking vs non-blocking, at a glance

| Work | Where it belongs | Why |
|---|---|---|
| waiting on a channel, timer, socket | `.await` in a task | costs no thread while waiting |
| short CPU work, quick `std` lock | inline in a task | microseconds; fine |
| file I/O, slow CPU work (hashing, big JSON) | `spawn_blocking` | would stall a worker thread |
| blocking forever / interactively (stdin) | a dedicated `std::thread` | must not delay runtime shutdown |

### Why `Storage` stays synchronous

`trait Storage` still has plain `fn load`/`fn save`. Making them `async fn` is legal in today's
Rust, but then `dyn Storage` stops working: an `async fn` returns a different, unnamed future type
for every implementation, and a vtable can't hold "some future type". There are workarounds
(boxing the futures, the `async-trait` crate, enum dispatch). In **Lab 31**, with a real async
database, you'll weigh them. For a JSON file, honest blocking I/O on the blocking pool is the
right answer.

### Cancellation is just `Drop`

In Lab 06 you watched values drop at the end of a scope. Cancellation in async Rust is the same
thing: `select!` drops the losing future, and its state machine, with every local stored in it,
is dropped field by field. Nothing more runs. That's powerful (no "cancel tokens" needed for
simple cases) and dangerous (code after an `.await` might never run). That's why "is this future
cancel-safe?" is a question to ask every time you write `select!`.

---

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 — Block the runtime.** Make two temporary changes. In `main.rs`, use a
> single-threaded runtime: `#[tokio::main(flavor = "current_thread")]`. In `save_in_background`,
> replace the `spawn_blocking` lines with a direct, slow, blocking call:
>
> ```rust
>     // 🟡 call the blocking function directly on the async worker thread
>     std::thread::sleep(Duration::from_secs(3)); // pretend the disk is slow
>     report(save_if_dirty(&state, &*storage));
> ```
>
> Run with `--autosave-secs 1 --storage memory`. Add a company, wait a second, then type
> `company list`. How long does the list take to appear?

Up to **three seconds**. With `current_thread` there's exactly one thread polling futures. The
autosave task is sitting in `std::thread::sleep` on that thread without ever returning
`Pending`, so the REPL future can't be polled, even though your line is already waiting in the
channel. On the default multi-threaded runtime the effect is smaller (another worker picks up
the slack), but you've still taken a worker out of service. In a web server under load, that's
how you get mysterious latency spikes. Revert both changes.

> 🟡 **EXPERIMENT 2 — Why not `tokio::io::stdin()`?** Temporarily rewrite `Input` on top of
> Tokio's stdin:
>
> ```rust
> use tokio::io::{AsyncBufReadExt, BufReader, Lines, Stdin};
>
> pub(crate) struct Input {
>     lines: Lines<BufReader<Stdin>>,
> }
> // new():        Self { lines: BufReader::new(tokio::io::stdin()).lines() }
> // read_line():  let line = self.lines.next_line().await?;
> //               Ok(line.map(|l| l.trim().to_string()))
> ```
>
> Run the CRM, type a command, then press **Ctrl-C** at the `crm>` prompt.

You'll see `Interrupted.` and `Goodbye! …`, and then the program **doesn't exit** until you press
Enter. `main` has returned, but dropping the runtime waits for its blocking threads, and one of
them is stuck in a blocking `read()` on the terminal. (In the reference run, with input from a
pipe that stayed open, it took 8 seconds to exit instead of 1.) Restore the thread-based `Input`.

> 🟡 **EXPERIMENT 3 — Borrow into `spawn_blocking`.** In `repl`'s `Save` arm, skip the clones:
>
> ```rust
>                 // 🟡 no clones: just borrow
>                 match task::spawn_blocking(|| save_if_dirty(state, &**storage)).await? {
> ```

```text
error[E0521]: borrowed data escapes outside of function
  --> src/cli/mod.rs:95:23
   |
70 |     state: &Arc<Mutex<AppData>>,
   |     -----  - let's call the lifetime of this reference `'1`
   |     |
   |     `state` is a reference that is only valid in the function body
71 |     storage: &Arc<dyn Storage>,
   |     ------- `storage` declared here, outside of the function body
...
95 |                 match task::spawn_blocking(|| save_if_dirty(state, &**storage)).await? {
   |                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |                       |
   |                       `state` escapes the function body here
   |                       argument requires that `'1` must outlive `'static`
```

(and the same for `storage`). *"But I `.await` it right there!"* Think about cancellation: if
this `repl` future were dropped during that `.await` (say, by a `select!` one level up), the
closure would keep running on the blocking pool with references into a stack frame that no longer
exists. The `'static` bound on `spawn_blocking` and `tokio::spawn` rules that out, for the same
reason as `thread::spawn` in Lab 25. Async doesn't relax the rules; it adds cancellation as
another reason for them. Put the clones back.

> 🟡 **EXPERIMENT 4 — Which thread am I on?** In the autosave task, before `select!`, add
> `eprintln!("[autosave] on {:?}", std::thread::current().id());` and run with
> `--autosave-secs 1` for a few seconds. Does the thread id stay the same? What does that tell
> you about why the future must be `Send`? Remove it afterwards.

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — finish the conversion**
>
> Convert the remaining commands (contacts, deals, leads, activity logging) to the async,
> "prompt first, lock second" style, and delete the old blocking code.

- [ ] every command works again; the `bail!` arm in `execute` is gone
- [ ] each converted handler has the shape `async fn contact(state: &Mutex<AppData>, input: &mut Input, cmd: ContactCommand<'_>) -> anyhow::Result<()>`
      (same for `deal`, `lead`, and an `async fn log_activity(state, input, subject)`)
- [ ] all prompting happens **outside** `read_crm`/`write_crm`
- [ ] `contact update <id>` still reports `Error: no contact with id <id>` **before** asking any
      questions if the contact doesn't exist (your Lab 14 version did that with its
      `Editing …` line; keep it), *and* still copes if the contact disappears while the user is
      typing (think about what can happen between two lock acquisitions). Lab 14's
      `Crm::update_contact` already looks the contact up again and checks for a duplicate email:
      call it inside **one** `write_crm`, where nothing can change between the check and the
      update
- [ ] the old blocking `prompt`/`prompt_optional` helpers in `mod.rs` are deleted (with the
      `std::io` import); no dead-code warnings remain
- [ ] the unit test `unknown_ids_are_not_found` in `commands.rs` compiles and passes again, as a
      `#[tokio::test]` (it needs an `Input` that never touches the real stdin: see the hint)
- [ ] `cargo clippy --all-targets -- -D warnings` is clean (so no `await_holding_lock`)
- [ ] this script produces the output below:
      `printf 'company add\nAcme Corp\nhttps://acme.example\ncontact add\nAda Lovelace\nada@acme.example\n555-0100\n1\ncontact update 1\n\nada.lovelace@acme.example\n\ndeal add\n1\nAnnual licence\n12000\ndeal move 1 proposal\nlead add\nLinus\nlinus@example.org\nInitech\nreferral\n\nlead qualify 1\nlead convert 1\ny\nPilot\n2500\nactivity log deal:1\ncall\n15\nIntro call\n\ncontact list\nquit\n' | cargo run -q -- --storage memory`

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Storage: in memory (nothing will be saved)
Loaded 0 companies, 0 contacts, 0 deals, 0 leads
crm> Name: Website (optional): Added company #1
crm> Name: Email: Phone (optional): Company id (blank for none): Added contact #1
crm> Editing Ada Lovelace <ada@acme.example>
Name (blank to keep): Email (blank to keep): Phone (blank to keep): Updated contact #1
crm> Company id: Title: Value (e.g. 1250.50): Added deal #1
crm> Deal #1 moved to proposal
crm> Name: Email: Company name (blank for none): Source (website/referral/event/cold_outreach/other, blank for other): Notes (blank for none): Added lead #1
crm> Lead #1 is qualified
crm> Create a deal? (y/n): Deal title: Deal value (e.g. 1250.50): Converted lead #1: company #2, contact #2, deal #2
crm> Kind (call/email/meeting): Duration in minutes: Summary: When (YYYY-MM-DD HH:MM, UTC; blank for now): Logged activity #1 on deal:1
crm> ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada.lovelace@acme.example 555-0100       #1
#2   Linus                linus@example.org        -              #2
Page 1 of 1 (2 matching)
crm> Goodbye! (10 commands this session)
```

(The prompts and messages are the ones your earlier labs wrote; converting to async changes none
of them. The input is piped, so what you type doesn't appear after the prompts.)

> 🔵 **YOUR TURN 2 — Ctrl-C cancels the command, not the program**
>
> Right now Ctrl-C at the `crm>` prompt quits, but Ctrl-C in the middle of `company add` is
> ignored (Tokio replaced the default SIGINT behaviour, and nobody is listening at that moment).
> Make Ctrl-C during **any prompt inside a command** abort just that command.

- [ ] the change lives in `Input::prompt` only. No command handler changes
- [ ] Ctrl-C at `Name:` prints a newline and then `Error: cancelled`, and you're back at `crm>`
      with nothing added
- [ ] Ctrl-C at `crm>` still quits as before (with the final save)
- [ ] explain in a comment why it's safe to abandon the pending line read (cancel-safety)

```text
crm> company add
Name: ^C
Error: cancelled
crm> company list
No companies match.
```

> 🔵 **YOUR TURN 3 — async tests for the autosave task**
>
> Bring back Lab 25's autosave tests, rewritten for Tokio, in `src/cli/autosave.rs`.

- [ ] use `#[tokio::test]` and `tokio::sync::oneshot`; await the `JoinHandle` instead of joining
- [ ] the four tests: `clean_state_is_never_saved`, `dirty_state_is_saved_once_on_shutdown`,
      `dropping_the_sender_also_stops_the_task`, and a new one,
      `dirty_state_is_saved_on_a_tick` (20 ms interval, wait ~100 ms: exactly one save happened
      *before* shutdown, `dirty` is false, and shutdown adds no second save)
- [ ] no `std::thread::sleep` in async tests (why not? write the answer in a comment)
- [ ] `lock_recovers_from_a_poisoned_mutex` still passes
- [ ] `cargo test` passes 10 times in a row (`for i in $(seq 10); do cargo test -q || break; done`)

---

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: convert one command at a time, re-running the compiler after each.
> The pattern is always: (1) `input.prompt(…).await?` for every question, (2) parse/validate into
> owned values, (3) **one** `write_crm`/`read_crm` call, (4) print.

<details><summary>Hint 2 (more specific)</summary>

For `contact update`, use **two** short critical sections: `read_crm` first to check that the
contact exists (fail fast, and get the label for `Editing …`), then the prompts, then
`write_crm(state, |crm| crm.update_contact(id, name, email, phone))`. `Crm::update_contact` looks
the contact up **again** and returns `NotFound` if it's gone. Between the two locks, the autosave
task may run, and in Lab 27 another HTTP request could delete the contact. "Check, release,
then act" always needs a re-check inside the second lock.

For the test: give `Input` a second constructor, only for tests, that fills the channel with
canned lines instead of starting the stdin thread:
`#[cfg(test)] pub(crate) fn from_lines(lines: &[&str]) -> Self`. A `tokio::sync::mpsc::Sender`
has a non-async `try_send`. Then `execute(&state, &mut input, command).await.unwrap_err()`, and
`err.downcast_ref::<CrmError>()` gets the domain error back out of the `anyhow::Error`.

</details>

> 💡 **HINT (Your Turn 2)**: you already wrote the same `select!` in `repl`.

<details><summary>Hint 2 (more specific)</summary>

```text
select! {
    line = self.read_line(label) => { /* same as before */ }
    _ = tokio::signal::ctrl_c() => { println!(); /* return an anyhow error "cancelled" */ }
}
```

`anyhow::bail!("cancelled")` returns early with that error. Why is dropping `read_line` safe?
Look at what it was awaiting when it was dropped.

</details>

> 💡 **HINT (Your Turn 3)**: `#[tokio::test]` builds a fresh single-threaded runtime per test. In
> that world, `std::thread::sleep` blocks the only thread, so the autosave task you're testing
> could never run while the test sleeps.

<details><summary>Hint 2 (more specific)</summary>

`tokio::time::sleep(Duration::from_millis(50)).await`. `tx.send(())` on a oneshot returns
`Result<(), ()>`, so `.unwrap()` it. `handle.await.unwrap()` turns a panic inside the task into a
test failure. For the poison test you still need a real OS thread (`std::thread::spawn`).
Poisoning is about threads, not tasks.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. What does calling an `async fn` do, and what doesn't it do? How is that different from
   calling an `async function` in JavaScript?
2. In the state-machine picture, where do local variables go when a future is suspended at
   `.await`? Use that to explain why a `MutexGuard` held across `.await` makes the future
   not `Send`.
3. Why does `tokio::spawn` require `Send`, while the future passed to `block_on` doesn't?
4. Give one situation where `tokio::sync::Mutex` is the right choice, and explain why our `Crm`
   isn't one of them.
5. What's the difference between `.await`-ing a slow future and calling a blocking function
   inside an async fn? What does each one do to the worker thread?
6. What does `select!` do to the futures of branches that don't win? What does
   "cancel-safe" mean?
7. Why does `Input` use a dedicated OS thread rather than a Tokio task for reading stdin?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit

```bash
rm -f lab26-demo.json
git add .
git commit -m "Move REPL and autosave to Tokio"
git tag lab-26
git push && git push --tags
```

`git diff lab-25 lab-26 -- src/cli/autosave.rs` is worth reading slowly: the thread version and
the task version side by side.

# Lab 25 — Threads & Shared State

> **Phase:** 7 — Concurrency & Async · **Builds on:** Lab 24 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-24` · **After:** tag `lab-25`

## 🎯 Goal

Add a **background autosave thread** to the CRM. Instead of writing the whole JSON file after
every command, the REPL marks the data as *dirty*. A second thread wakes up every 30 seconds and
saves only if something changed. On `quit`, the REPL tells the thread to stop. The thread then
does one last save and exits.

## 🧠 What You'll Learn

- What a thread is: a second call stack sharing the same heap
- `std::thread::spawn`, `JoinHandle`, and why `spawn` demands `'static` closures (E0373)
- `move` closures: moving ownership *into* a thread
- `Send` and `Sync`: **auto traits** that let the compiler prove there are no data races (E0277)
- Why `Rc` can't cross threads and `Arc` can (atomic reference counts)
- Why `Arc` alone can't give you mutation (E0596)
- `Mutex<T>`: a lock that **owns the data**, and `MutexGuard` as an RAII "permission slip"
- Lock poisoning, and a deadlock you'll cause on purpose
- `RwLock<T>`: many readers or one writer, at runtime
- Channels (`std::sync::mpsc`) and `recv_timeout` as a ticker with an off switch
- Supertraits: `trait Storage: Send + Sync`

## 🔨 What We're Building

Today the REPL owns the `Crm`, and it saves after every mutating command:

```text
Lab 24                                 Lab 25
──────                                 ──────
main thread                            main thread (REPL)          autosave thread
  owns Crm                               │                            │
  loop:                                  │  lock → execute → dirty    │ every 30 s:
    read command                         │  unlock                    │   lock → save if dirty
    execute(&mut crm)                    │                            │   unlock
    storage.save(&crm)  ← every time     │  quit ──── shutdown ─────► │ final save, exit
                                         │  join ◄─────────────────── ┘
                                         ▼
                                Arc<Mutex<AppData { crm, dirty }>>  shared by both
```

Why bother, for a terminal app? Saving after every command is fine for a few hundred records.
The real reason is that **this is exactly the web server's problem**. In Lab 27 many requests
will touch the same `Crm` at once. Here you meet the same questions with only two threads,
and you can see each one fail. Who owns the CRM? How do two threads share it? Who may write,
and when?

> **About your starting code.** Labs 21–24 were yours to write, so your messages and helper
> names may differ slightly from the ones shown here. This lab relies only on these shapes from
> Lab 24:
> `cli::run(storage: Box<dyn Storage>) -> anyhow::Result<()>` (built by `build_storage` in
> `main.rs`), a `Crm` you load at start, an
> `execute(&mut Crm, Command) -> Result<(), CliError>` function in `cli/commands.rs` (with
> `CliError` in `cli/error.rs` from Lab 22), the REPL loop inside `run` (Lab 14's
> `loop { … break count … }` that reads stdin itself), the `prompt`/`prompt_optional` helpers and
> `error_chain`, `Command::is_mutating()`, the `Storage::describe()` banner line, and Lab 24's
> `tests/persistence.rs` with its `RecordingStorage` test double.

---

## Step 0 — Where we start

Open `src/cli/mod.rs`. Lab 24's `run` looks like this:

```rust
pub fn run(storage: Box<dyn Storage>) -> anyhow::Result<()> {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");
    println!("Storage: {}", storage.describe());

    let mut crm = storage
        .load()
        .context("refusing to start, so the data file is not overwritten")?;
    println!("Loaded {}, {}, {}, {}", /* count(…) for companies, contacts, deals, leads */);
    let mut count = 0;

    let commands_run = loop {
        print!("crm> ");
        io::stdout().flush().expect("failed to flush stdout");

        let mut input = String::new();
        let bytes = io::stdin()
            .read_line(&mut input)
            .expect("failed to read line");
        if bytes == 0 {
            println!();
            break count;
        }

        let result = match parser::parse_command(&input) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break count,
            Ok(Some(command)) => {
                let mutating = command.is_mutating();
                let result = commands::execute(&mut crm, command);
                if result.is_ok()
                    && mutating
                    && let Err(e) = storage.save(&crm)
                {
                    println!("Error: {}", error_chain(&e));
                    println!(
                        "(The change is kept in memory and will be saved with your next change.)"
                    );
                }
                result
            }
            Err(e) => Err(e),
        };
        count += 1;

        if let Err(e) = result {
            println!("Error: {}", error_chain(&e));
        }
    };

    println!("Goodbye! ({commands_run} commands this session)");
    Ok(())
}
```

One owner (`crm`, a local variable in `run`), one thread, no sharing. Every borrow is easy to
check: `execute` gets `&mut crm` for the length of the call, then `save` gets `&crm`. Keep this
picture in mind. It's about to get harder.

---

## Step 1 — The mental model: what a thread is

A **thread** is a second, independent call stack that the operating system schedules alongside
the first. Each thread has its **own stack** (its own local variables). All threads in a process
share **one heap**.

```text
            main thread stack            new thread stack
           ┌──────────────────┐         ┌──────────────────┐
  run()    │ crm: Crm ────────┼──┐      │ closure's        │
           │ storage: Box ────┼─┐│      │ captured values  │
           │ count            │ ││      │                  │
           └──────────────────┘ ││      └──────────────────┘
                                ▼▼
                   ┌─────────────────────────────┐
                   │ HEAP: Vec<Company>, Strings │   ← both threads *could* reach this
                   └─────────────────────────────┘
```

Two consequences matter for Rust:

1. **A thread can outlive the function that started it.** `thread::spawn` returns right away.
   The new thread keeps running even after the function that spawned it has returned and its
   stack frame (with all its locals) is gone.
2. **Two threads touching the same heap memory at the same time, with at least one writing, is
   a data race.** In C or C++ that's undefined behaviour. In JavaScript, you never had threads
   sharing memory (Web Workers copy messages), so you've never had to think about it.

Rust turns both problems into **compile errors**. Here's the signature that does it:

```rust
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
```

Keep this open in another tab: `rustup doc --std` → search `thread::spawn`. Every error in this
lab comes from one of those three bounds: `FnOnce`, `Send`, `'static`.

---

## Step 2 — First attempt: a thread that borrows (E0373)

Let's start small: a thread that wakes up every 30 seconds and reports how many companies it
*would* save. No saving yet.

> 🟡 **EXPERIMENT**: predict first, then run `cargo check`.

In `src/cli/mod.rs`, add the imports (below `use std::io::{self, Write};`) and, in `run`, just
after the "Loaded …" line:

```rust
use std::thread;
use std::time::Duration;
```

```rust
    // 🟡 first attempt: a background thread that reports on the CRM
    thread::spawn(|| {
        loop {
            thread::sleep(Duration::from_secs(30));
            println!("[autosave] would save {} companies", crm.companies.len());
        }
    });
```

```text
error[E0373]: closure may outlive the current function, but it borrows `crm.companies`, which is owned by the current function
  --> src/cli/mod.rs:43:19
   |
43 |     thread::spawn(|| {
   |                   ^^ may outlive borrowed value `crm.companies`
...
46 |             println!("[autosave] would save {} companies", crm.companies.len());
   |                                                            ------------- `crm.companies` is borrowed here
   |
note: function requires argument type to outlive `'static`
  --> src/cli/mod.rs:43:5
   |
43 | /     thread::spawn(|| {
44 | |         loop {
45 | |             thread::sleep(Duration::from_secs(30));
46 | |             println!("[autosave] would save {} companies", crm.companies.len());
47 | |         }
48 | |     });
   | |______^
help: to force the closure to take ownership of `crm.companies` (and any other referenced variables), use the `move` keyword
   |
43 |     thread::spawn(move || {
   |                   ++++

error[E0502]: cannot borrow `crm` as mutable because it is also borrowed as immutable
  --> src/cli/mod.rs:70:48
   |
43 |       thread::spawn(|| {
   |       -             -- immutable borrow occurs here
   |  _____|
   | |
44 | |         loop {
45 | |             thread::sleep(Duration::from_secs(30));
46 | |             println!("[autosave] would save {} companies", crm.companies.len());
   | |                                                            ------------- first borrow occurs due to use of `crm.companies` in closure
47 | |         }
48 | |     });
   | |______- argument requires that `crm.companies` is borrowed for `'static`
...
70 |                   let result = commands::execute(&mut crm, command);
   |                                                  ^^^^^^^^ mutable borrow occurs here
   |
note: requirement that the value outlives `'static` introduced here
  --> /rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/std/src/thread/functions.rs:128:14
```

**Read the errors.** Work through the four questions:

- **Who owns `crm`?** The local variable `crm` in `run`. It lives on the main thread's stack
  and is dropped when `run` returns.
- **Was it moved?** No. The closure only *uses* `crm.companies.len()`, which needs `&`. So the
  closure captures a **shared reference**. (Since edition 2021 a closure captures the precise
  *path* it uses, `crm.companies`, not the whole `crm`. That's why the error names the field.)
- **Is it a borrow?** Yes, a `&InMemoryRepo<Company>` pointing into `run`'s stack frame.
- **How long must it live?** `spawn` says `F: 'static`. A closure is `'static` only if
  everything it captures is valid *for as long as anyone might hold it*. The thread could hold
  it forever. Our borrow is only valid until `run` returns.

> 💡 **`'static` doesn't mean "lives forever".** `T: 'static` means "`T` contains no borrows
> that could expire." An owned `String` is `'static`. So is a `Crm`. A `&Crm` pointing at a
> local variable is not. Read the bound as **"the closure must own what it uses"** (or only
> borrow things that truly live forever, like string literals).

The second error, E0502, is the borrow checker doing its normal job. The thread holds a shared
borrow of `crm.companies` "for `'static`", and the REPL wants `&mut crm` to run a command. Without
threads this is Lab 07's *aliasing XOR mutation* rule. **With** threads, it's the rule that
prevents a data race: the REPL mutating the `Vec` while the other thread reads it. Same rule,
new reason.

Why can't the compiler just see that `run` outlives the thread? Because it doesn't. Nothing
joins the thread before `run` returns. And even with a `join()` at the end, `spawn`'s signature
can't express "until someone joins me". (Scoped threads can. You'll see them in
🧠 Understand It.)

---

## Step 3 — `move`: give the thread its own data (E0382)

The compiler suggested `move`. A `move` closure takes **ownership** of everything it captures.
Let's see what that costs.

> 🟡 **EXPERIMENT**: change `thread::spawn(|| {` to `thread::spawn(move || {`. Predict, then
> `cargo check`.

```text
error[E0382]: borrow of partially moved value: `crm`
  --> src/cli/mod.rs:70:48
   |
43 |     thread::spawn(move || {
   |                   ------- value partially moved into closure here
...
46 |             println!("[autosave] would save {} companies", crm.companies.len());
   |                                                            ------------- variable partially moved due to use in closure
...
70 |                 let result = commands::execute(&mut crm, command);
   |                                                ^^^^^^^^ value borrowed here after partial move
   |
   = note: partial move occurs because `crm.companies` has type `InMemoryRepo<Company>`, which does not implement the `Copy` trait
```

It's our old friend from Lab 06. `crm.companies` (the whole repo, with its `Vec`) **moved** into
the closure, and then onto the new thread. The REPL no longer owns it.

```text
before spawn                          after spawn(move || …)
main stack: crm { companies ─┐ }      main stack: crm { companies: <moved> }   ✗ unusable
                             ▼        thread:     companies ──► Vec<Company> on heap
                         Vec<Company>
```

Now the problem is clear. We need **two owners** of one `Crm`: the REPL and the autosave thread.
Single ownership was the right default for 24 labs, but here it doesn't fit.

---

## Step 4 — Two owners: `Rc` fails, and why (E0277)

You've solved "two owners" before. In Lab 14 you used `Rc<RefCell<…>>`. Let's try it.

> 🟡 **EXPERIMENT**: replace the experiment block with this version and `cargo check`.

```rust
use std::cell::RefCell;
use std::rc::Rc;
```

```rust
    // 🟡 attempt 2: share the CRM with Rc<RefCell<..>> (it worked in Lab 14!)
    let shared = Rc::new(RefCell::new(crm));
    let for_thread = Rc::clone(&shared);
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(30));
            let crm = for_thread.borrow();
            println!("[autosave] would save {} companies", crm.companies.len());
        }
    });
    let mut crm = shared.borrow_mut();
```

```text
error[E0277]: `Rc<RefCell<Crm>>` cannot be sent between threads safely
  --> src/cli/mod.rs:47:19
   |
47 |       thread::spawn(move || {
   |       ------------- ^------
   |       |             |
   |  _____|_____________within this `{closure@src/cli/mod.rs:47:19: 47:26}`
   | |     |
   | |     required by a bound introduced by this call
48 | |         loop {
49 | |             thread::sleep(Duration::from_secs(30));
50 | |             let crm = for_thread.borrow();
...  |
53 | |     });
   | |_____^ `Rc<RefCell<Crm>>` cannot be sent between threads safely
   |
   = help: within `{closure@src/cli/mod.rs:47:19: 47:26}`, the trait `Send` is not implemented for `Rc<RefCell<Crm>>`
note: required because it's used within this closure
  --> src/cli/mod.rs:47:19
   |
47 |     thread::spawn(move || {
   |                   ^^^^^^^
note: required by a bound in `spawn`
  --> /rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/std/src/thread/functions.rs:125:0
```

This time it's not a lifetime problem. `for_thread` is owned, so the closure is `'static`. It's
the **`Send`** bound.

### Why `Rc` must not cross threads

An `Rc` is a pointer to a heap block holding `(strong count, weak count, value)`. `Rc::clone`
does `count += 1` and dropping does `count -= 1`, with **ordinary, non-atomic** arithmetic. That's
why `Rc` is cheap. Now imagine two threads dropping their `Rc` clones at the same moment:

```text
count = 2
thread A: load count (2)                thread B: load count (2)
thread A: store 2 - 1 = 1               thread B: store 2 - 1 = 1
                     → count is 1, but there are 0 owners → memory leaked
(the mirror race on clone/drop can free the value while someone still uses it → use-after-free)
```

So the Rust authors marked `Rc` as **not `Send`**: "you may not move this to another thread."
The compiler checks that rule every time you call `spawn`.

### `Send` and `Sync`: auto traits

You've implemented traits by hand since Lab 15. `Send` and `Sync` are different: they're
**auto traits**. The compiler implements them for your types automatically, field by field:

| Trait | Meaning | Rule |
|---|---|---|
| `Send` | It's safe to **move** a `T` to another thread | A struct is `Send` if all its fields are `Send` |
| `Sync` | It's safe to **share** `&T` between threads | `T: Sync` exactly when `&T: Send` |

Your `Crm`, `Company`, `Email`, `Money` and `InMemoryRepo<T>` are all `Send + Sync`. You never
wrote a line for that: `String`, `Vec`, `u64` and `Option` are, so everything built from them is
too. A few std types **opt out** because they'd be unsafe to share:

| Type | `Send` | `Sync` | Why |
|---|---|---|---|
| `Rc<T>` | ✗ | ✗ | non-atomic refcount |
| `RefCell<T>`, `Cell<T>` | ✓ (if `T: Send`) | ✗ | borrow flag / interior mutation is not thread-safe |
| `Arc<T>` | if `T: Send + Sync` | if `T: Send + Sync` | atomic refcount, shared `&T` |
| `Mutex<T>` | if `T: Send` | if `T: Send` | the lock makes sharing safe |
| `MutexGuard<'_, T>` | ✗ | if `T: Sync` | must be unlocked by the thread that locked it |
| `Box<dyn Trait>` | only if `dyn Trait: Send` | only if `dyn Trait: Sync` | the compiler can't know the hidden type… |

That last row will matter in Step 7.

### Attempt 3: `Arc<RefCell<Crm>>`

`Arc` ("**A**tomically **R**eference **C**ounted") is `Rc` with atomic increments and decrements.
The CPU guarantees that two threads updating the count can't interleave as above. It costs a few
nanoseconds more per clone/drop, which is why `Rc` still exists.

> 🟡 **EXPERIMENT**: change `Rc::new` → `Arc::new`, `Rc::clone` → `Arc::clone`, and the import to
> `use std::sync::Arc;`. Keep the `RefCell`. Predict!

```text
error[E0277]: `RefCell<Crm>` cannot be shared between threads safely
  --> src/cli/mod.rs:47:19
   |
47 |       thread::spawn(move || {
   |  _____-------------_^
   | |     |
   | |     required by a bound introduced by this call
48 | |         loop {
49 | |             thread::sleep(Duration::from_secs(30));
50 | |             let crm = for_thread.borrow();
...  |
53 | |     });
   | |_____^ `RefCell<Crm>` cannot be shared between threads safely
   |
   = help: the trait `Sync` is not implemented for `RefCell<Crm>`
   = note: if you want to do aliasing and mutation between multiple threads, use `std::sync::RwLock` instead
   = note: required for `Arc<RefCell<Crm>>` to implement `Send`
note: required because it's used within this closure
  --> src/cli/mod.rs:47:19
   |
47 |     thread::spawn(move || {
   |                   ^^^^^^^
note: required by a bound in `spawn`
  --> /rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/std/src/thread/functions.rs:125:0
```

Read the chain of `note:`s from bottom to top. That's how the compiler reasons about auto traits:

1. `spawn` needs the closure to be `Send`.
2. The closure contains an `Arc<RefCell<Crm>>`, so that must be `Send`.
3. `Arc<T>` is `Send` only if `T` is `Send + **Sync**`, because an `Arc` lets *both* threads
   reach the same `T` through `&T`.
4. `RefCell<Crm>` is not `Sync`. Its runtime borrow counter (Lab 14) is a plain integer, with the
   same race as `Rc`'s count.

The compiler even tells you the fix: *use `RwLock` instead*. We'll get there.

---

## Step 5 — `Arc<Crm>`: sharing is not mutation (E0596)

What if we drop `RefCell` altogether?

> 🟡 **EXPERIMENT**: predict the error *before* compiling.

```rust
    // 🟡 attempt 3: Arc instead of Rc, no RefCell
    let crm = Arc::new(crm);
    let for_thread = Arc::clone(&crm);
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(30));
            println!("[autosave] would save {} companies", for_thread.companies.len());
        }
    });
```

(Also change `let mut crm = storage.load()…` to `let crm = …` and
`commands::execute(&mut crm, command)` to `commands::execute(&mut *crm, command)`.)

```text
error[E0596]: cannot borrow data in an `Arc` as mutable
  --> src/cli/mod.rs:73:48
   |
73 |                 let result = commands::execute(&mut *crm, command);
   |                                                ^^^^^^^^^ cannot borrow as mutable
   |
   = help: trait `DerefMut` is required to modify through a dereference, but it is not implemented for `Arc<Crm>`
```

The thread part compiles now. `Arc<Crm>` is `Send` because `Crm` is `Send + Sync`. But the REPL
can't mutate.

This is the most important idea in this step: **`Arc` gives you shared ownership, and shared
ownership only ever hands out shared references (`&T`).** If two owners could each get a
`&mut T`, the *one writer XOR many readers* rule would be broken. `Arc` implements `Deref` but
not `DerefMut`, and the help line says exactly that.

So we need something that:
- is `Sync` (can be shared through an `Arc`), and
- gives out `&mut Crm`, but **one thread at a time**, checked at **runtime**.

That's a lock.

> Now delete all the experiment code from `run` (back to the Lab 24 version) before Step 6.

---

## Step 6 — `Mutex`: a lock that owns the data

In many languages a mutex protects a *section of code*. You lock, touch some variables you
promise are protected, then unlock, and nothing stops you touching them *without* locking. Rust's
`Mutex<T>` is different: **the mutex owns the data**. The only way to reach the `T` inside is to
call `.lock()`, which gives you a **guard**:

```text
Arc<Mutex<AppData>>
 │
 ▼  (heap)
┌──────────────────────────────────────────────┐
│ strong: 2 (atomic)                           │
│ Mutex { locked: bool (atomic), poisoned,     │
│         data: AppData { crm: Crm, dirty } }  │ ← unreachable except via lock()
└──────────────────────────────────────────────┘
      ▲                                ▲
 REPL's Arc                       autosave thread's Arc

let mut data = state.lock().unwrap();   // waits until no one else holds it
                                        // data: MutexGuard<'_, AppData>
data.dirty = true;                      // DerefMut → &mut AppData
data.crm.add_company(…);
drop(data);                             // ← unlock happens HERE, in MutexGuard's Drop
```

`MutexGuard` is **RAII**, like the `Drop` you watched in Lab 06. You don't call `unlock()`
because there isn't one. The lock is released when the guard goes out of scope. You can't forget
to unlock, and you can't touch the data after unlocking, because the reference came *from* the
guard. The borrow checker won't let it outlive the guard.

It's the borrow rules again, enforced at runtime instead of compile time:

| | compile time (Lab 07) | runtime, one thread (Lab 14) | runtime, many threads |
|---|---|---|---|
| exclusive access | `&mut T` | `RefCell::borrow_mut` | `Mutex::lock` |
| conflict means | compile error | panic (`BorrowMutError`) | **wait** (block until free) |

### 🟢 Create `src/cli/autosave.rs`

> 🟢 **FOLLOW ALONG**

```rust
//! Background autosave: a second thread that shares the CRM with the REPL.

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::crm::Crm;
use crate::storage::{Storage, StorageError};

/// Everything the REPL and the autosave thread share.
pub(crate) struct AppData {
    pub crm: Crm,
    /// `true` when the CRM has changes that are not on disk yet.
    pub dirty: bool,
}

/// Save if there are unsaved changes. Returns `Ok(true)` if it saved.
pub(crate) fn save_if_dirty(
    state: &Mutex<AppData>,
    storage: &dyn Storage,
) -> Result<bool, StorageError> {
    let mut data = state.lock().unwrap();
    if !data.dirty {
        return Ok(false);
    }
    storage.save(&data.crm)?;
    data.dirty = false;
    Ok(true)
} // <- `data` (the MutexGuard) is dropped here: the lock is released
```

Look at what's locked together. The `crm` and the `dirty` flag live in **one** `Mutex`, so they
can never disagree. Nobody can change the CRM without also being able to set `dirty`, and the
saver can't clear `dirty` while someone is halfway through a change. If they were in two
separate locks, you'd have to reason about the gap between them. Rule of thumb: **data that must
stay consistent goes behind the same lock.**

`save_if_dirty` takes `&Mutex<AppData>`, not `Arc<…>`. It doesn't need to *own* a share, only to
use the mutex for the length of the call. Same reasoning as "take `&str`, not `String`" (Lab 09).

Also notice we **save while holding the lock**. That's a deliberate trade-off: the REPL waits for
the few milliseconds the write takes, but what lands on disk is a consistent snapshot. (The
alternative, clone the `Crm` under the lock and save the clone afterwards, trades memory and a
`Clone` derive for shorter lock times. Lab 27 uses a third option.)

Why `.unwrap()` on `lock()`? Because `lock()` returns a `Result`, and the error case is
**poisoning**. You'll trigger it in 🧪 Experiment and handle it properly in Your Turn 3.

Register the module in `src/cli/mod.rs`:

```rust
mod autosave;
mod commands;
mod error;
mod parser;
```

---

## Step 7 — The storage has to cross threads too (`Send + Sync` supertraits)

The autosave thread needs the storage as well as the data. In Lab 23 `run` received a
`Box<dyn Storage>`. Can a box go to another thread?

> 🟡 **EXPERIMENT**: temporarily add this inside `run`, right after the `Storage: …` line, then
> `cargo check`, then delete it. (Ignore the "unused import" warnings from the half-written
> `autosave.rs`.)

```rust
    // 🟡 can the storage itself go to another thread?
    let handle = std::thread::spawn(move || storage.load());
    let _ = handle.join();
```

```text
error[E0277]: `dyn Storage` cannot be sent between threads safely
  --> src/cli/mod.rs:30:37
   |
30 |     let handle = std::thread::spawn(move || storage.load());
   |                  ------------------ ^^^^^^^^^^^^^^^^^^^^^^ `dyn Storage` cannot be sent between threads safely
   |                  |
   |                  required by a bound introduced by this call
   |
   = help: the trait `Send` is not implemented for `dyn Storage`
   = note: required for `std::ptr::Unique<dyn Storage>` to implement `Send`
note: required because it appears within the type `Box<dyn Storage>`
  --> /rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/alloc/src/boxed.rs:236:11
note: required because it's used within this closure
  --> src/cli/mod.rs:30:37
   |
30 |     let handle = std::thread::spawn(move || storage.load());
   |                                     ^^^^^^^
note: required by a bound in `spawn`
  --> /rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/std/src/thread/functions.rs:125:0
```

But `JsonFileStorage` is just a `PathBuf`, and `PathBuf` is `Send`. So why does it fail?

Because **`dyn Storage` erased the concrete type** (Lab 23: a fat pointer = data pointer +
vtable). The compiler no longer knows *which* type is behind the box. It might be
`JsonFileStorage`, or some future `RcCachedStorage` holding an `Rc`. Auto traits are worked out
from the concrete type, and that type is gone. So `dyn Storage` is `Send` only if you **promise
it in the trait**:

> 🟢 **FOLLOW ALONG**: in `src/storage/mod.rs`:

```rust
/// Loads and saves a whole snapshot of the CRM.
///
/// `Send + Sync` because the autosave thread uses the storage too.
pub trait Storage: Send + Sync {
    fn load(&self) -> Result<Crm, StorageError>;
    fn save(&self, crm: &Crm) -> Result<(), StorageError>;

    /// A short human description, shown in the banner.
    fn describe(&self) -> String {
        String::from("custom storage")
    }
}
```

`Storage: Send + Sync` is a **supertrait** bound: "to implement `Storage`, a type must also be
`Send + Sync`." The promise is now checked in two places:

- at each `impl Storage for X`: `X` must really be `Send + Sync` (you'll see this check fire in
  Your Turn 2's hint), and
- at use sites: any `dyn Storage` is now known to be `Send + Sync`.

`InMemoryStorage` (a unit struct) and `JsonFileStorage` (a `PathBuf`) satisfy it automatically.
`cargo check` is happy. But `cargo check` doesn't build your integration tests. Run the tests:

```bash
cargo test
```

```text
error[E0277]: `RefCell<Option<std::string::String>>` cannot be shared between threads safely
  --> tests/persistence.rs:84:18
   |
84 | impl Storage for RecordingStorage {
   |                  ^^^^^^^^^^^^^^^^ `RefCell<Option<std::string::String>>` cannot be shared between threads safely
   |
   = help: within `RecordingStorage`, the trait `Sync` is not implemented for `RefCell<Option<std::string::String>>`
   = note: if you want to do aliasing and mutation between multiple threads, use `std::sync::RwLock` instead
note: required because it appears within the type `RecordingStorage`
  --> tests/persistence.rs:80:8
   |
80 | struct RecordingStorage {
   |        ^^^^^^^^^^^^^^^^
note: required by a bound in `Storage`
  --> src/storage/mod.rs:20:27
   |
20 | pub trait Storage: Send + Sync {
   |                           ^^^^ required by this bound in `Storage`
```

That's the first check from the list above, firing on a storage *you* wrote. Lab 24's test double
keeps its snapshot in a `RefCell<Option<String>>` (if you used a `Cell` or `RefCell` of something
else, you'll see the same error with your type). `RefCell` was the right tool on one thread, but
it isn't `Sync`, so `RecordingStorage` can no longer promise what `Storage` now demands. Note that
the error points at the `impl` line in `tests/`, not at some distant `thread::spawn`: the
supertrait makes every backend prove it's thread-safe *where it's defined*.

> 🟢 **FOLLOW ALONG**: in `tests/persistence.rs`, swap the `RefCell` for its thread-safe twin,
> the `Mutex` from Step 6. `lock().unwrap()` plays the role of both `borrow()` and
> `borrow_mut()`:

```rust
use std::fs;
use std::sync::Mutex; // was: use std::cell::RefCell;
```

```rust
#[derive(Debug, Default)]
struct RecordingStorage {
    snapshot: Mutex<Option<String>>,
}

impl Storage for RecordingStorage {
    fn load(&self) -> Result<Crm, StorageError> {
        match &*self.snapshot.lock().unwrap() {
            Some(json) => Ok(serde_json::from_str(json).expect("we wrote this JSON ourselves")),
            None => Ok(Crm::default()),
        }
    }

    fn save(&self, crm: &Crm) -> Result<(), StorageError> {
        let json = serde_json::to_string(crm).expect("a Crm always serializes");
        *self.snapshot.lock().unwrap() = Some(json);
        Ok(())
    }
}
```

`check_storage_contract(&dyn Storage)` doesn't change. `cargo test` is green again.

### `Box` → `Arc`

The REPL and the thread both need the storage (the REPL will need it again in Your Turn 1). Two
owners again, so `Arc`. Update `build_storage` in `src/main.rs`:

```rust
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
```

```rust
/// The one place that decides which concrete storage the program uses.
fn build_storage(args: Args) -> Arc<dyn Storage> {
    match args.storage {
        StorageKind::Memory => Arc::new(InMemoryStorage),
        StorageKind::Json => Arc::new(JsonFileStorage::new(args.data_file)),
    }
}
```

Your `main.rs` tests (`build_storage(args).describe()`) keep working unchanged: `describe`
takes `&self`, and an `Arc` derefs to the storage just like a `Box` did.

`Arc::new(InMemoryStorage)` creates an `Arc<InMemoryStorage>`. Assigning it to an
`Arc<dyn Storage>` is an **unsizing coercion**: the pointer grows a vtable pointer. It's the same
coercion as `Box<T>` → `Box<dyn Trait>` in Lab 23.

While you're in `Args`, add the flag the thread needs:

```rust
    /// Seconds between background autosaves
    #[arg(long, default_value_t = 30, value_parser = clap::value_parser!(u64).range(1..))]
    autosave_secs: u64,
```

The `range(1..)` is a real safety check: `0` would make the thread wake up continuously and burn
a CPU core. `build_storage` takes `args` by value, so read the interval *before* handing `args`
over. `main` becomes:

```rust
fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let autosave_every = Duration::from_secs(args.autosave_secs);
    let storage = build_storage(args);
    rust_crm::cli::run(storage, autosave_every)
}
```

(It won't compile until Step 9 changes `run`'s signature.)

---

## Step 8 — Channels: telling the thread to stop

The autosave thread needs two signals: **"30 seconds passed"** and **"stop now"**. A channel gives
you both.

`std::sync::mpsc` is a **m**ulti-**p**roducer, **s**ingle-**c**onsumer queue between threads:
`let (tx, rx) = mpsc::channel();`. The `Sender` (`tx`) and `Receiver` (`rx`) are separate
values you can move to different threads. A channel moves **ownership** of each message from
sender to receiver. That's the other way to share across threads: don't share at all, send.

The trick is `Receiver::recv_timeout(duration)`:

| Returns | Meaning for us |
|---|---|
| `Ok(())` | the REPL sent "stop" |
| `Err(RecvTimeoutError::Timeout)` | nothing arrived for `duration`: **that's our tick** |
| `Err(RecvTimeoutError::Disconnected)` | every `Sender` was dropped: the REPL is gone, stop too |

So one blocking call is both the timer and the off switch. A plain `thread::sleep(30s)` couldn't
be interrupted. You'd wait up to 30 seconds after `quit`.

> 🟢 **FOLLOW ALONG**: add to `src/cli/autosave.rs`:

```rust
/// Start the autosave thread. It saves every `every` if the CRM is dirty,
/// and does one final save when it receives a message on `shutdown`
/// (or when the sending side is dropped).
pub(crate) fn spawn_autosave(
    state: Arc<Mutex<AppData>>,
    storage: Arc<dyn Storage>,
    every: Duration,
    shutdown: Receiver<()>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        loop {
            match shutdown.recv_timeout(every) {
                // Nobody sent anything for `every`: that's our tick.
                Err(RecvTimeoutError::Timeout) => report(save_if_dirty(&state, &*storage)),
                // Asked to stop, or the REPL is gone: last save, then exit.
                Ok(()) | Err(RecvTimeoutError::Disconnected) => {
                    report(save_if_dirty(&state, &*storage));
                    break;
                }
            }
        }
    })
}

fn report(result: Result<bool, StorageError>) {
    if let Err(e) = result {
        eprintln!("Error: autosave failed: {:#}", anyhow::Error::from(e));
    }
}
```

Ownership check, line by line:

- `spawn_autosave` takes `state`, `storage` and `shutdown` **by value**. The caller hands over one
  `Arc` clone each and the receiver. The `move` closure then takes them, so the thread owns them.
  The closure owns everything it uses, so it's `'static`, and every captured value is `Send`.
  `spawn` is satisfied.
- `&*storage`: `storage` is `Arc<dyn Storage>`, `*storage` is the `dyn Storage` inside, and `&` of
  that is the `&dyn Storage` that `save_if_dirty` wants. The `Arc` keeps ownership. We only lend.
- `&state` is `&Arc<Mutex<AppData>>`, and deref coercion turns it into `&Mutex<AppData>`.
- `JoinHandle<()>` is the "receipt" for the thread. Calling `.join()` on it waits for the thread
  to finish and returns `Err` if the thread panicked.

---

## Step 9 — Rewire the REPL

> 🟢 **FOLLOW ALONG**: replace `run` in `src/cli/mod.rs` and add a `repl` helper. Keep
> `APP_NAME`, `PAGE_SIZE`, `count`, `prompt` and `prompt_optional` as they are.

```rust
mod autosave;
mod commands;
mod error;
mod parser;

use std::io::{self, Write};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use anyhow::Context;

use crate::errors::error_chain;
use crate::storage::Storage;
use autosave::{AppData, spawn_autosave};
use parser::Command;
```

```rust
/// Runs the interactive CRM until the user quits (or stdin closes).
pub fn run(storage: Arc<dyn Storage>, autosave_every: Duration) -> anyhow::Result<()> {
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
    let (shutdown_tx, shutdown_rx) = mpsc::channel();
    let autosave = spawn_autosave(
        Arc::clone(&state),
        Arc::clone(&storage),
        autosave_every,
        shutdown_rx,
    );

    let commands_run = repl(&state);

    // However the REPL ended, stop the autosave thread cleanly.
    let _ = shutdown_tx.send(());
    autosave.join().expect("autosave thread panicked");

    println!("Goodbye! ({commands_run} commands this session)");
    Ok(())
}

/// The read-eval-print loop. Returns how many commands were run.
fn repl(state: &Mutex<AppData>) -> usize {
    let mut count = 0;

    loop {
        print!("crm> ");
        io::stdout().flush().expect("failed to flush stdout");

        let mut input = String::new();
        let bytes = io::stdin()
            .read_line(&mut input)
            .expect("failed to read line");
        if bytes == 0 {
            println!();
            break count;
        }

        let result = match parser::parse_command(&input) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break count,
            Ok(Some(command)) => {
                let mutating = command.is_mutating();
                let mut data = state.lock().unwrap();
                let result = commands::execute(&mut data.crm, command);
                if result.is_ok() && mutating {
                    data.dirty = true;
                }
                drop(data); // unlock *before* printing errors and reading the next line
                result
            }
            Err(e) => Err(e),
        };
        count += 1;

        if let Err(e) = result {
            println!("Error: {}", error_chain(&e));
        }
    }
}
```

The banner is unchanged from Lab 24: `Storage: …` (from `describe()`, now called through the
`Arc`), then the load, then `Loaded …`. `repl` is Lab 24's loop moved into its own function: the
`loop` is the function's last expression, so `break count` is its return value. What changed is
the middle of the `Ok(Some(command))` arm, and everything after the loop.

Three design decisions to notice:

1. **`Arc::clone(&state)` instead of `state.clone()`.** They do the same thing. Writing
   `Arc::clone` tells the reader "this bumps a reference count; it does *not* deep-copy the CRM."
   That matters, because `.clone()` on a big struct usually *is* expensive.
2. **The REPL loop moved into its own function, `repl(&state)`.** However the loop ends (`quit`,
   Ctrl-D), control comes back to `run`, which *always* reaches `send` and `join`. If `run`
   could return straight out of the loop, the `JoinHandle` would be dropped, which **detaches**
   the thread, and the process could exit in the middle of a save. (In Lab 26 reading input can
   fail, `repl` will return a `Result`, and this structure is what guarantees the clean stop.)
3. **`commands::execute(&mut data.crm, …)`**: `data` is a `MutexGuard<AppData>`, and `data.crm`
   goes through `DerefMut` to the real `Crm` inside the mutex. `execute` didn't change at all. It
   still takes `&mut Crm` and returns `Result<(), CliError>`, and it has no idea a lock exists.
   Your Lab 14 decision to keep business logic out of the CLI is paying off.

Why `let _ = shutdown_tx.send(())`? `send` fails only if the receiver is gone, which means the
thread already exited. There's nothing useful to do about that, so we ignore it on purpose.
Dropping `shutdown_tx` would *also* stop the thread (the `Disconnected` arm). The explicit `send`
is clearer.

The `storage.save(&crm)` after each mutating command, and its "(The change is kept in memory…)"
message, are gone now. The dirty flag replaces them: a failed autosave is reported by the
autosave thread and simply retried on the next tick, because `dirty` stays `true`.

```bash
cargo check
cargo clippy --all-targets
cargo test
```

All three should be clean.

---

## ▶️ Run It

Use a separate data file so the experiment doesn't touch your real data, and a short interval so
you don't wait 30 seconds:

```bash
rm -f lab25-demo.json
cargo run -- --data-file lab25-demo.json --autosave-secs 5
```

Then:

1. Type `company add`, then `Acme Corp`, then `https://acme.example`.
2. **Immediately**, in a second terminal: `ls lab25-demo.json`
3. Wait 5 seconds, run `ls -l lab25-demo.json` again.
4. Back in the CRM: `company add`, `Globex`, Enter (no website), then `quit`.
5. Check the file contains both companies: `grep '"name"' lab25-demo.json`

## ✅ Expected Result

The REPL looks like before. The difference is *when* the file is written:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Storage: JSON file lab25-demo.json
Loaded 0 companies, 0 contacts, 0 deals, 0 leads
crm> company add
Name: Acme Corp
Website (optional): https://acme.example
Added company #1
crm> company add
Name: Globex
Website (optional):
Added company #2
crm> quit
Goodbye! (2 commands this session)
```

In the second terminal:

```text
$ ls lab25-demo.json
ls: lab25-demo.json: No such file or directory          ← right after the add: not saved yet
$ ls -l lab25-demo.json
-rw-r--r--  1 you  staff  468 Oct  5 16:29 lab25-demo.json   ← after the autosave tick
$ grep '"name"' lab25-demo.json                          ← after quit
        "name": "Acme Corp",
        "name": "Globex",
```

Globex was added *after* the last tick. It's on disk only because `quit` triggered the final
save. The banner lines and file size are from the reference implementation; your Lab 24
wording and byte count may differ.

Also check the flag validation:

```text
$ cargo run -q -- --autosave-secs 0
error: invalid value '0' for '--autosave-secs <AUTOSAVE_SECS>': 0 is not in 1..18446744073709551615

For more information, try '--help'.
```

---

## 🧠 Understand It

### The ownership map

Here is every value that crosses a thread boundary, who owns it, and how the other side gets to
it:

```text
                main thread                              autosave thread
                ───────────                              ───────────────
run():  state ─────────┐                     ┌───────── state   (Arc clone, moved in)
        storage ─────┐ │                     │ ┌─────── storage (Arc clone, moved in)
        shutdown_tx  │ │                     │ │  ┌──── shutdown_rx (moved in; channel's
             │       │ │                     │ │  │      other end)
             │       ▼ ▼                     ▼ ▼  │
             │   ┌──────────────────────────────────────┐
             │   │ heap: ArcInner { strong: 2,           │
             │   │   Mutex { AppData { crm, dirty } } }  │◄── reached ONLY via lock()
             │   │ heap: ArcInner { strong: 2,           │
             │   │   JsonFileStorage { path } }          │◄── &self methods; Sync
             │   └──────────────────────────────────────┘
             └──────── send(()) ─────── channel ────────► recv_timeout
repl(&state): borrows the main thread's Arc for the loop
autosave:     JoinHandle<()> ── join() waits for the thread to finish
```

| Value | Owner(s) | Shared how | Accessed how | Why it's allowed |
|---|---|---|---|---|
| `Crm` + `dirty` | the `Mutex`, inside an `ArcInner` | `Arc<Mutex<AppData>>`, strong count 2 | `lock()` → `MutexGuard` → `&mut` | `Mutex<AppData>: Sync` because `AppData: Send` |
| storage | the `ArcInner` | `Arc<dyn Storage>` | `&self` methods | `dyn Storage: Send + Sync` (supertraits) |
| `shutdown_tx` | main thread only | not shared | `send` | — |
| `shutdown_rx` | autosave thread only | moved in | `recv_timeout` | `Receiver<()>: Send` |
| thread | the OS | `JoinHandle` | `join` | — |

The heap blocks are freed when the **last** `Arc` is dropped. That's the thread's clones when it
exits, then `run`'s at the end of the function. Nobody had to decide "who frees this". The
reference count decides.

### Why the compiler can prove "no data races"

A data race needs two threads, the same memory, at least one write, and no synchronization. To
reach the `Crm` from two threads, you need a `&Crm` or `&mut Crm` on each. The rules close every
route:

- `&mut` from two threads at once: impossible. `&mut` is unique, and `Arc` only gives `&`.
- `&T` from two threads while one writes through interior mutability: only if `T: Sync`, and
  `Cell`/`RefCell` aren't.
- `Mutex`: `Sync`, but it only hands out `&mut` via a guard, one at a time.

You didn't write any `unsafe` or annotate anything. Rust's own docs call this *fearless
concurrency*.

### `RwLock`: many readers or one writer

`std::sync::RwLock<T>` is the runtime version of `&T`/`&mut T`: `read()` gives a
`RwLockReadGuard` (many at once) and `write()` gives a `RwLockWriteGuard` (exclusive).

Why didn't we use it here? Both of our threads **write**. The REPL changes the CRM, and the
autosave thread clears `dirty`. With only two threads that both write, `RwLock` buys nothing
and costs a bit more bookkeeping. In **Lab 27** the web server has many concurrent `GET`
requests that only read, and there `RwLock<Crm>` is exactly right.

| | `Mutex<T>` | `RwLock<T>` |
|---|---|---|
| readers at once | 1 | many |
| writers at once | 1 | 1 (and no readers) |
| `Sync` requires | `T: Send` | `T: Send + Sync` |
| use when | writes are common, or critical sections are tiny | reads dominate |

### Scoped threads: borrowing *is* possible when the scope is visible

`thread::scope` (stable since Rust 1.63) gives you threads that are guaranteed to be joined
before the scope ends. So they **may borrow** local data, and there's no `'static`:

```rust
let crm = rust_crm::crm::Crm::default();
let (companies, contacts) = thread::scope(|s| {
    let a = s.spawn(|| crm.companies.len());   // borrows crm: fine!
    let b = s.spawn(|| crm.contacts.len());
    (a.join().unwrap(), b.join().unwrap())
});
```

That's the same E0373 situation from Step 2, fixed by making the lifetime visible to the
compiler instead of by moving ownership. It doesn't fit autosave, because that thread lives
for the whole session while the REPL does other work. But it's the right tool for "split this
calculation across cores, then continue."

### JavaScript comparison (briefly)

Node runs your JS on one thread. Workers communicate by **copying** messages (`postMessage`),
or by sharing raw bytes through `SharedArrayBuffer` + `Atomics`, with no protection for
structured data. Rust gives you real shared memory, and the type system makes it safe. A channel
in Rust is closest to `postMessage`, except it moves ownership instead of copying.

---

## 🧪 Experiment

> 🟡 **EXPERIMENT 1 — Deadlock.** In `repl`, right after `let mut data = state.lock().unwrap();`,
> add:
>
> ```rust
>         let peek = state.lock().unwrap(); // 🟡 lock a second time
>         println!("(dirty before command: {})", peek.dirty);
> ```
>
> Predict: compile error, panic, or something else? Then run `cargo run -- --storage memory` and
> type `company list`.

It compiles, because the borrow checker can't see locks. When you run it, the prompt appears,
you type `company list`… and **nothing happens. Forever.** The main thread is waiting for a lock
that it holds itself. (The std docs say a second `lock()` on the same thread "might panic or
deadlock". On macOS and Linux today, it hangs.) Press Ctrl-C to kill it. Remove the two lines.

The lesson: a `Mutex` is not reentrant. **Never call a function that locks while you hold the
same lock.** You'll need this in Your Turn 1.

> 🟡 **EXPERIMENT 2 — Poisoning.** In `save_if_dirty`, just before `storage.save(...)`, add:
>
> ```rust
>     if data.crm.companies.len() > 1 {
>         panic!("simulated bug in autosave"); // 🟡 panic while holding the lock
>     }
> ```
>
> Run with `--autosave-secs 2`, add two companies, wait 3 seconds, then type `company list`.

```text
crm> company add
Name: Acme Corp
Website (optional):
Added company #1
crm> company add
Name: Globex
Website (optional):
Added company #2
crm>
thread '<unnamed>' (480149) panicked at src/cli/autosave.rs:28:9:
simulated bug in autosave
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
company list

thread 'main' (480144) panicked at src/cli/mod.rs:85:45:
called `Result::unwrap()` on an `Err` value: PoisonError { .. }
```

The autosave thread panicked **while holding the guard**. The guard's `Drop` still ran (panics
unwind the stack and drop everything on it), so the lock was released. But first the guard
marked the mutex as **poisoned**: *"someone died halfway through changing this data; it may be
inconsistent."* Every later `lock()` returns `Err(PoisonError)`, and our `.unwrap()` turned that
into a second panic on the main thread.

Is that right for the CRM? Your Turn 3 decides. Remove the `panic!`.

> 🟡 **EXPERIMENT 3 — Holding a lock while a human types.** In `spawn_autosave`, change the
> `Timeout` arm to log what it's doing:
>
> ```rust
>                 Err(RecvTimeoutError::Timeout) => {
>                     eprintln!("[autosave] tick: waiting for the lock...");
>                     report(save_if_dirty(&state, &*storage));
>                     eprintln!("[autosave] done");
>                 }
> ```
>
> Run with `--autosave-secs 2`. Wait for one tick, then type `company add` and **wait about six
> seconds** at the `Name:` prompt before answering.

```text
crm> [autosave] tick: waiting for the lock...
[autosave] done
company add
Name: [autosave] tick: waiting for the lock...
Acme Corp
Website (optional):
Added company #1
crm> [autosave] done
```

The tick that fired while you sat at `Name:` printed "waiting…" and then **nothing**, until you
finished the command. While it waits it can't tick at all, so with a slow typist no autosave
happens for as long as the prompt is open.

Why? In `repl` we lock *before* `execute`, and `execute` prompts for input *inside* the
command. So the lock is held for as long as a human takes to type. A lock should be held for
microseconds, not for "as long as someone takes to answer". Hold that thought: in Lab 26 the
compiler will help you catch exactly this mistake, and you'll fix it properly.

Remove the logging when you're done (or keep it while you work through Your Turn 2).

> 🟡 **EXPERIMENT 4 — Remove the supertrait.** Delete `: Send + Sync` from `trait Storage` and run
> `cargo check`. Where does the error appear now: at `thread::spawn`, at `Arc::new(...)` in
> `main.rs`, or in both? Put it back.

---

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — a `save` command**
>
> Add a `save` command that writes the CRM to storage *now*, without waiting for the next tick.

- [ ] `save` is parsed into a new `Command::Save` variant and listed in `help`
- [ ] if there are unsaved changes, it saves and prints `Saved.`; otherwise it prints
      `Nothing to save.`; on failure it prints `Error: …` and the REPL keeps going
- [ ] it reuses `save_if_dirty` (don't copy its body)
- [ ] `save` itself is not a mutating command (it must not set `dirty`)
- [ ] it does **not** deadlock (re-read Experiment 1 before you write it)
- [ ] after `company add` → `save` → `save`, you see `Saved.` then `Nothing to save.`

> 🔵 **YOUR TURN 2 — test the autosave thread**
>
> Write unit tests for `spawn_autosave` in a `#[cfg(test)] mod tests` at the bottom of
> `src/cli/autosave.rs`. You need a fake storage, `CountingStorage`, that implements `Storage` and
> counts how many times `save` was called.

- [ ] `clean_state_is_never_saved`: `dirty: false`, interval 10 ms, wait ~50 ms, send shutdown,
      join → 0 saves
- [ ] `dirty_state_is_saved_once_on_shutdown`: `dirty: true`, interval of one hour, send
      shutdown immediately, join → exactly 1 save, and `dirty` is `false` afterwards
- [ ] `dropping_the_sender_also_stops_the_thread`: like the previous test, but `drop` the sender
      instead of sending
- [ ] you can read the counter *after* handing the storage to `spawn_autosave` (think about who
      owns the `CountingStorage`)
- [ ] `cargo test` passes, repeatedly (run it a few times)

> 🔵 **YOUR TURN 3 — survive a poisoned lock**
>
> Write `pub(crate) fn lock(state: &Mutex<AppData>) -> MutexGuard<'_, AppData>` in
> `autosave.rs` and use it **everywhere** you currently call `state.lock().unwrap()`.

- [ ] on a poisoned mutex, it prints `Warning: a thread panicked while using the CRM data; continuing anyway.`
      to stderr and returns the guard anyway
- [ ] after recovering, the mutex is no longer poisoned (so the warning appears once, not on
      every command)
- [ ] a test `lock_recovers_from_a_poisoned_mutex` poisons the mutex on purpose (a thread that
      panics while holding the guard), checks `is_poisoned()`, calls your `lock`, and checks that
      the data is still there and the poison is cleared
- [ ] in a comment above the function, one or two sentences: *why* is continuing reasonable for
      this CRM, and when would it **not** be?
- [ ] `cargo clippy --all-targets -- -D warnings` is clean

---

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: the REPL loop doesn't have the storage. Who could lend it one?
> And `save_if_dirty` takes the lock itself, so where in the loop must `save` be handled?

<details><summary>Hint 2 (more specific)</summary>

Handle `Command::Save` the same way you handle `Command::Quit`: with its own `match` arm in
`repl`, *before* the arm that calls `state.lock()…`. Give `repl` a second parameter `storage: &dyn Storage` and call
it with `repl(&state, &*storage)`. `execute` never sees `Save`, so give it an arm that does
nothing (`Command::Quit | Command::Save => {}`) to keep the `match` exhaustive.

</details>

> 💡 **HINT (Your Turn 2)**: a first attempt usually looks like `struct CountingStorage { saves: Cell<usize> }`.
> Try it and read the error. It's the supertrait from Step 7 doing its job, exactly as it did
> for `RecordingStorage`:

```text
error[E0277]: `Cell<usize>` cannot be shared between threads safely
  --> src/cli/autosave.rs:76:22
   |
76 |     impl Storage for CountingStorage {
   |                      ^^^^^^^^^^^^^^^ `Cell<usize>` cannot be shared between threads safely
   |
   = help: within `CountingStorage`, the trait `Sync` is not implemented for `Cell<usize>`
   = note: if you want to do aliasing and mutation between multiple threads, use `std::sync::RwLock` or `std::sync::atomic::AtomicUsize` instead
note: required because it appears within the type `CountingStorage`
  --> src/cli/autosave.rs:72:12
   |
72 |     struct CountingStorage {
   |            ^^^^^^^^^^^^^^^
note: required by a bound in `storage::Storage`
  --> src/storage/mod.rs:20:27
   |
20 | pub trait Storage: Send + Sync {
   |                           ^^^^ required by this bound in `Storage`
```

<details><summary>Hint 2 (more specific)</summary>

Use `std::sync::atomic::AtomicUsize` with `fetch_add(1, Ordering::SeqCst)` and
`load(Ordering::SeqCst)`. (`SeqCst` is the simplest, strictest ordering. It's fine for tests.)
Keep **your own** `Arc<CountingStorage>` and pass `storage.clone()` to `spawn_autosave`: the
`Arc<CountingStorage>` coerces to `Arc<dyn Storage>` at the call, and you still hold a typed
handle to read the counter after `join()`.

</details>

> 💡 **HINT (Your Turn 3)**: read the docs for `PoisonError` (`rustup doc --std`, search
> `PoisonError`). It has a method that gives you the guard back. `Mutex` also has a method that
> clears the flag.

<details><summary>Hint 2 (more specific)</summary>

`state.lock().unwrap_or_else(|poisoned| { …; state.clear_poison(); poisoned.into_inner() })`.
The return type `MutexGuard<'_, AppData>` borrows from `state`. That's lifetime elision from Lab
10: one reference parameter in, so the output borrows from it.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. `thread::spawn` requires `F: 'static`. Explain what that means for a closure, and why an owned
   `Crm` satisfies it while `&Crm` doesn't.
2. Why is `Rc<T>` not `Send`? What exactly would go wrong?
3. `Arc<RefCell<Crm>>` failed with "`RefCell<Crm>` cannot be **shared**". Why does *sending* an
   `Arc` require the inside to be *shareable* (`Sync`)?
4. Why can't you get a `&mut Crm` out of an `Arc<Crm>`? Which trait is missing?
5. Where is the `Mutex` unlocked in `save_if_dirty`? What happens to the lock if code inside
   panics?
6. Why does `dyn Storage` need `Send + Sync` written into the trait, when `JsonFileStorage` is
   `Send + Sync` automatically?
7. In Experiment 3, why did the autosave thread wait for you to finish typing? How long should
   a lock be held?

Then verify: `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`

## Git Commit

```bash
rm -f lab25-demo.json
git add .
git commit -m "Add background autosave thread"
git tag lab-25
git push && git push --tags
```

`git diff lab-24 lab-25 --stat` shows how small the change was: one new module and a rewired
`run`. The business logic didn't change at all.

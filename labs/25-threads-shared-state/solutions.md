# Lab 25 — Solutions

> 🔴 These are *one* good answer each, with the reasoning. If yours differs but meets the
> acceptance criteria and you can explain your choices, it's correct.

---

## Your Turn 1 — the `save` command

### The trap

The obvious place to add `save` is inside `execute`, next to the other commands. But `execute`
receives `&mut Crm`, which already comes **from inside the lock**:

```rust
let mut data = state.lock().unwrap();       // lock held…
let result = execute(&mut data.crm, command); // …while execute runs
```

`execute` has no storage, and even if you passed it in, calling `save_if_dirty(state, …)` from
there would call `lock()` a second time on the same thread. That's Experiment 1's deadlock.
`save` has to be handled **before** the REPL takes the lock, like `quit`.

### `src/cli/parser.rs`

```rust
pub(crate) enum Command<'a> {
    Help,
    Version,
    Quit,
    Save,
    // … the rest unchanged
}
```

```rust
        ("quit" | "exit", _) => Command::Quit,
        ("save", _) => Command::Save,
```

In `is_mutating`, `Save` joins the non-mutating group:

```rust
            Command::Help
            | Command::Version
            | Command::Quit
            | Command::Save
            | Command::Pipeline
            | Command::History { .. } => false,
```

### `src/cli/commands.rs`

```rust
        Command::Quit | Command::Save => {} // handled by the REPL loop
```

and add `save` to `print_help`.

### `src/cli/mod.rs`

```rust
use autosave::{AppData, save_if_dirty, spawn_autosave};
```

```rust
    let result = repl(&state, &*storage);
```

```rust
fn repl(state: &Mutex<AppData>, storage: &dyn Storage) -> anyhow::Result<usize> {
    // …
        if command == Command::Quit {
            break;
        }
        if command == Command::Save {
            // No lock here: save_if_dirty takes it itself.
            match save_if_dirty(state, storage) {
                Ok(true) => println!("Saved."),
                Ok(false) => println!("Nothing to save."),
                Err(e) => println!("Error: {:#}", anyhow::Error::from(e)),
            }
            continue;
        }
        let mutating = command.is_mutating();
        // … unchanged
```

**Why `&dyn Storage` and not `Arc<dyn Storage>` for `repl`?** `repl` only *uses* the storage
while it runs. It doesn't need to keep a share alive after it returns, and it never sends it to
another thread. Borrowing is enough, so it borrows. `&*storage` turns the `Arc<dyn Storage>` into
a `&dyn Storage` that lives as long as `run`'s `storage` variable.

Result:

```text
crm> save
Nothing to save.
crm> company add
Name: Acme Corp
Website (blank for none): https://acme.example
Added company #1
crm> save
Saved.
crm> save
Nothing to save.
```

---

## Your Turn 2 — testing the autosave thread

```rust
#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;

    use super::*;

    /// A fake storage that only counts how often it was asked to save.
    #[derive(Default)]
    struct CountingStorage {
        saves: AtomicUsize,
    }

    impl Storage for CountingStorage {
        fn load(&self) -> Result<Crm, StorageError> {
            Ok(Crm::default())
        }
        fn save(&self, _crm: &Crm) -> Result<(), StorageError> {
            self.saves.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    fn state(dirty: bool) -> Arc<Mutex<AppData>> {
        Arc::new(Mutex::new(AppData { crm: Crm::default(), dirty }))
    }

    #[test]
    fn clean_state_is_never_saved() {
        let storage = Arc::new(CountingStorage::default());
        let (tx, rx) = mpsc::channel();
        let handle = spawn_autosave(state(false), storage.clone(), Duration::from_millis(10), rx);
        thread::sleep(Duration::from_millis(50));
        tx.send(()).unwrap();
        handle.join().unwrap();
        assert_eq!(storage.saves.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn dirty_state_is_saved_once_on_shutdown() {
        let storage = Arc::new(CountingStorage::default());
        let shared = state(true);
        let (tx, rx) = mpsc::channel();
        let handle = spawn_autosave(shared.clone(), storage.clone(), Duration::from_secs(3600), rx);
        tx.send(()).unwrap();
        handle.join().unwrap();
        assert_eq!(storage.saves.load(Ordering::SeqCst), 1);
        assert!(!shared.lock().unwrap().dirty);
    }

    #[test]
    fn dropping_the_sender_also_stops_the_thread() {
        let storage = Arc::new(CountingStorage::default());
        let (tx, rx) = mpsc::channel::<()>();
        let handle = spawn_autosave(state(true), storage.clone(), Duration::from_secs(3600), rx);
        drop(tx);
        handle.join().unwrap();
        assert_eq!(storage.saves.load(Ordering::SeqCst), 1);
    }
}
```

### The reasoning

- **Why `AtomicUsize`, not `Cell<usize>`?** `save(&self)` takes a *shared* reference, so counting
  needs interior mutability. And because `Storage: Send + Sync`, the counter has to be safe to
  mutate through `&self` **from another thread**. `Cell` isn't `Sync`. An atomic is: `fetch_add`
  is a single, indivisible CPU operation. (A `Mutex<usize>` would also work. It's just heavier
  than needed for one number.)
- **Who owns the `CountingStorage`?** An `ArcInner` on the heap, with two owners: the test's
  `storage` and the clone moved into the thread. `storage.clone()` is an `Arc<CountingStorage>`
  that coerces to `Arc<dyn Storage>` at the call. The test keeps its **typed** `Arc` so it can
  still reach the `saves` field, which isn't part of the trait. After `join()` the thread's
  clone has been dropped and the test is the only owner left.
- **Why an interval of one hour in the shutdown tests?** So the *only* way a save can happen is
  the shutdown path. Each test checks one behaviour, and none of them depends on timing.
- **`clean_state_is_never_saved` does depend on timing.** It waits 50 ms with a 10 ms tick,
  so about four ticks run. If the clock is slow, fewer ticks run, but the assertion (0 saves)
  still holds. Write timing-based tests so that slowness can't make them fail.
- **`mpsc::channel::<()>()`**: in the drop test nothing is ever sent, so the compiler can't
  infer the message type from a `send` call. The turbofish names it.

---

## Your Turn 3 — a poison-tolerant `lock`

```rust
use std::sync::{Arc, Mutex, MutexGuard};

/// Lock the shared state, recovering if another thread panicked while holding it.
///
/// Continuing is reasonable here: every CRM operation either completes or returns an error
/// before changing anything, so a panic elsewhere (e.g. in the save code) can't leave
/// half-applied changes, and losing the user's session would be worse. It would NOT be
/// reasonable if a panic could interrupt a multi-step change, like a transfer between two
/// records, halfway through.
pub(crate) fn lock(state: &Mutex<AppData>) -> MutexGuard<'_, AppData> {
    state.lock().unwrap_or_else(|poisoned| {
        eprintln!("Warning: a thread panicked while using the CRM data; continuing anyway.");
        state.clear_poison();
        poisoned.into_inner()
    })
}
```

Use it in `save_if_dirty` (`let mut data = lock(state);`) and in `repl`
(`let mut data = lock(state);`), and import it in `mod.rs`.

The test:

```rust
    #[test]
    fn lock_recovers_from_a_poisoned_mutex() {
        let shared = state(true);
        let for_thread = Arc::clone(&shared);
        let result = thread::spawn(move || {
            let _guard = for_thread.lock().unwrap();
            panic!("simulated bug while holding the lock");
        })
        .join();
        assert!(result.is_err());
        assert!(shared.is_poisoned());

        let data = lock(&shared);
        assert!(data.dirty);
        drop(data);
        assert!(!shared.is_poisoned());
    }
```

### The reasoning

- **What's in a `PoisonError`?** The guard itself. Poisoning doesn't *prevent* access. It
  *warns* you, and `into_inner()` is how you say "I've read the warning, give me the data." Rust
  makes ignoring it an explicit decision instead of the default.
- **Why `clear_poison()`?** Without it the flag stays set, and every later `lock()` takes the
  error path and prints the warning again. Clearing is a statement: "I've checked; the data is
  fine to use."
- **The return type `MutexGuard<'_, AppData>`** borrows from `state`. Elision rule 2 from Lab 10:
  one reference parameter, so the output borrows from it. The guard can't outlive the mutex it
  locks, which is exactly the guarantee you want.
- **Why `let _guard`, not `let _`, in the test?** `let _ = x.lock().unwrap();` drops the guard
  *immediately*, so the panic would happen after unlocking and nothing would be poisoned.
  `_guard` is a real binding that lives until the end of the closure, so the panic happens
  while it's held. (The same detail will matter a lot in Lab 26.)
- `cargo test` prints the panic message from the spawned thread. That's expected: the panic is
  real, it's just contained in a thread that the test joins.

---

## Experiment answers

**Experiment 1 (deadlock).** It compiles because the borrow checker only tracks *references*.
`state.lock()` borrows `state` immutably (`&self`), and two shared borrows are fine. The second
`lock()` waits for the lock to be released, which can only happen when `data` is dropped, which
can only happen after the second `lock()` returns. Neither can happen first. In Lab 26 the tools
will catch a cousin of this bug (a lock held across a wait), but plain re-locking is your
responsibility.

**Experiment 2 (poisoning).** The panic unwound the autosave thread's stack. Unwinding runs
`Drop` for every value on it, including the `MutexGuard`, so the lock **was** released, and
nothing hung. The guard noticed it was being dropped during a panic (`std::thread::panicking()`)
and set the poison flag. Then `join()` in `run` would also return `Err` and our `expect` would
report "autosave thread panicked".

**Experiment 3 (contention).** Covered in the README. The structural fix, "talk to the human
first, take the lock second", is the heart of Lab 26.

**Experiment 4 (removing the supertrait).** The error appears **only** at the `thread::spawn`
inside `spawn_autosave` (four E0277 errors, for `Send` and `Sync`, in the lib and the test
build). `main.rs` still compiles: coercing `Arc<InMemoryStorage>` to `Arc<dyn Storage>` doesn't
need `Send`. That's why the supertrait is the better design. Without it, the requirement is
discovered deep inside the CLI. With it, the trait states the requirement up front, and a
non-thread-safe backend is rejected at its own `impl Storage for …` line, where its author can
fix it.

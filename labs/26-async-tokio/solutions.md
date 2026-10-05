# Lab 26 — Solutions

> 🔴 One good answer per task, with the reasoning. Your prompts and messages come from your
> earlier labs. What matters is the *shape*: prompt first, lock second, no guard across `.await`.

---

## Your Turn 1 — finish the conversion

`execute` now dispatches every command to an async handler:

```rust
        Command::Company(cmd) => company(state, input, cmd).await?,
        Command::Contact(cmd) => contact(state, input, cmd).await?,
        Command::Deal(cmd) => deal(state, input, cmd).await?,
        Command::Lead(cmd) => lead(state, input, cmd).await?,
        Command::LogActivity { subject } => log_activity(state, input, subject).await?,
```

### Contacts

```rust
async fn contact(
    state: &Mutex<AppData>,
    input: &mut Input,
    cmd: ContactCommand<'_>,
) -> anyhow::Result<()> {
    match cmd {
        ContactCommand::Add => {
            let name = input.prompt("Name: ").await?;
            let email = Email::parse(&input.prompt("Email: ").await?)?;
            let phone = optional(input.prompt("Phone (blank for none): ").await?);
            let company_id = match input.prompt("Company id (blank for none): ").await?.as_str() {
                "" => None,
                s => Some(CompanyId(
                    s.parse()
                        .map_err(|_| CrmError::Usage("company id must be a number"))?,
                )),
            };
            let id = write_crm(state, |crm| crm.add_contact(name, email, phone, company_id))?;
            println!("Added contact {id}");
        }
        ContactCommand::List { page } => read_crm(state, |crm| {
            let all = crm.list_contacts(&ContactFilter::default());
            if all.is_empty() {
                println!("No contacts yet.");
            }
            for c in all.iter().skip((page.max(1) - 1) * PAGE_SIZE).take(PAGE_SIZE) {
                println!("{c}");
            }
        }),
        ContactCommand::Show { id } => read_crm(state, |crm| {
            let c = crm
                .contacts
                .get(id)
                .ok_or(CrmError::NotFound { entity: "contact", id: id.0 })?;
            println!("{c}");
            print_history(crm, Subject::Contact(id), 5);
            Ok::<(), CrmError>(())
        })?,
        ContactCommand::Update { id } => {
            // Fail fast, before asking three questions about a contact that doesn't exist.
            read_crm(state, |crm| {
                crm.contacts
                    .get(id)
                    .map(|_| ())
                    .ok_or(CrmError::NotFound { entity: "contact", id: id.0 })
            })?;
            let name = input.prompt("New name (blank to keep): ").await?;
            let email = input.prompt("New email (blank to keep): ").await?;
            let phone = input.prompt("New phone (blank to keep): ").await?;
            let email = if email.is_empty() { None } else { Some(Email::parse(&email)?) };
            write_crm(state, |crm| {
                // Look it up again: it may have been deleted while we were prompting.
                let contact = crm
                    .contacts
                    .get_mut(id)
                    .ok_or(CrmError::NotFound { entity: "contact", id: id.0 })?;
                if !name.is_empty() {
                    contact.name = name;
                }
                if let Some(e) = email {
                    contact.email = e;
                }
                if !phone.is_empty() {
                    contact.phone = Some(phone);
                }
                Ok::<(), CrmError>(())
            })?;
            println!("Updated contact {id}");
        }
        ContactCommand::Delete { id } => {
            let removed = write_crm(state, |crm| crm.remove_contact(id))?;
            println!("Deleted contact {id} ({})", removed.name);
        }
        ContactCommand::Search { term } => read_crm(state, |crm| {
            for c in crm.contacts.search(term) {
                println!("{c}");
            }
        }),
    }
    Ok(())
}
```

**Why validate the email *before* `write_crm`?** `Email::parse` doesn't need the CRM, so it
belongs outside the lock. As a bonus, an invalid email fails before the lock is taken and before
`dirty` is set.

**Why two critical sections in `update`?** In Lab 24 your update probably called `find_mut`
once and then prompted while holding the `&mut Contact`. That was fine with one owner and no
other threads. Now the prompts must happen *outside* the lock, so there's a gap between the
existence check and the write. In this CLI the only other party is the autosave task, which
never deletes anything. But Lab 27 adds HTTP handlers that can `DELETE` a contact during that
gap. The second lookup inside `write_crm` turns a potential `unwrap()` panic into a clean
`NotFound`. This is the classic **check-then-act** race, and the cure is always to re-check
under the lock that you act under.

### Deals

```rust
async fn deal(state: &Mutex<AppData>, input: &mut Input, cmd: DealCommand) -> anyhow::Result<()> {
    match cmd {
        DealCommand::Add => {
            let company_id = input
                .prompt("Company id: ")
                .await?
                .parse()
                .map(CompanyId)
                .map_err(|_| CrmError::Usage("company id must be a number"))?;
            let title = input.prompt("Title: ").await?;
            let value = Money::parse(&input.prompt("Value: ").await?)?;
            let id = write_crm(state, |crm| crm.add_deal(company_id, title, value))?;
            println!("Added deal {id}");
        }
        DealCommand::List => read_crm(state, |crm| {
            for d in crm.deals.iter() {
                println!("{d}");
            }
        }),
        DealCommand::Show { id } => read_crm(state, |crm| {
            let d = crm
                .deals
                .get(id)
                .ok_or(CrmError::NotFound { entity: "deal", id: id.0 })?;
            println!("{d}");
            print_history(crm, Subject::Deal(id), 5);
            Ok::<(), CrmError>(())
        })?,
        DealCommand::Move { id, stage } => {
            write_crm(state, |crm| crm.move_deal(id, stage))?;
            println!("Deal {id} moved to {stage}");
        }
    }
    Ok(())
}
```

### Leads

```rust
async fn lead(state: &Mutex<AppData>, input: &mut Input, cmd: LeadCommand) -> anyhow::Result<()> {
    match cmd {
        LeadCommand::Add => {
            let name = input.prompt("Name: ").await?;
            let email = Email::parse(&input.prompt("Email: ").await?)?;
            let company_name = optional(input.prompt("Company name (blank for none): ").await?);
            let source = input
                .prompt("Source (website/referral/event/cold_outreach/other): ")
                .await?
                .parse()
                .map_err(|_| CrmError::Usage("unknown lead source"))?;
            let id = write_crm(state, |crm| crm.add_lead(name, email, company_name, source))?;
            println!("Added lead {id}");
        }
        LeadCommand::List => read_crm(state, |crm| {
            for l in crm.leads.iter() {
                println!("{l}");
            }
        }),
        LeadCommand::Qualify { id } => {
            write_crm(state, |crm| crm.qualify_lead(id))?;
            println!("Lead {id} qualified");
        }
        LeadCommand::Disqualify { id } => {
            write_crm(state, |crm| crm.disqualify_lead(id))?;
            println!("Lead {id} disqualified");
        }
        LeadCommand::Convert { id } => {
            let deal = if input.prompt("Create a deal? (y/n): ").await? == "y" {
                let title = input.prompt("Deal title: ").await?;
                let value = Money::parse(&input.prompt("Deal value: ").await?)?;
                Some((title, value))
            } else {
                None
            };
            let s = write_crm(state, |crm| crm.convert_lead(id, deal))?;
            match s.deal_id {
                Some(d) => println!(
                    "Converted lead {id}: company {}, contact {}, deal {d}",
                    s.company_id, s.contact_id
                ),
                None => println!(
                    "Converted lead {id}: company {}, contact {}",
                    s.company_id, s.contact_id
                ),
            }
        }
    }
    Ok(())
}
```

Note `lead convert`: the whole conversion (remove the lead, insert company/contact/deal, or hand
the lead back on failure) happens inside **one** `write_crm`. Nobody can ever observe a
half-converted lead. In Lab 31 the same guarantee comes from a database transaction.

### Activity logging

```rust
async fn log_activity(
    state: &Mutex<AppData>,
    input: &mut Input,
    subject: Subject,
) -> anyhow::Result<()> {
    let kind = match input.prompt("Kind (call/email/meeting): ").await?.as_str() {
        "call" => {
            let minutes = input
                .prompt("Minutes: ")
                .await?
                .parse()
                .map_err(|_| CrmError::Usage("minutes must be a number"))?;
            ActivityKind::Call { minutes }
        }
        "email" => ActivityKind::Email {
            subject: input.prompt("Email subject: ").await?,
        },
        "meeting" => {
            let starts = input.prompt("Starts at (YYYY-MM-DD HH:MM): ").await?;
            let starts_at = NaiveDateTime::parse_from_str(&starts, "%Y-%m-%d %H:%M")
                .map_err(|_| CrmError::Usage("date format is YYYY-MM-DD HH:MM"))?
                .and_utc();
            let attendees = input
                .prompt("Attendee contact ids (comma separated): ")
                .await?
                .split(',')
                .filter_map(|s| s.trim().parse().ok())
                .map(ContactId)
                .collect();
            ActivityKind::Meeting { starts_at, attendees }
        }
        _ => return Err(CrmError::Usage("kind must be call, email or meeting").into()),
    };
    let summary = input.prompt("Summary: ").await?;
    let id = write_crm(state, |crm| crm.log_activity(subject, kind, summary, Utc::now()))?;
    println!("Logged activity {id}");
    Ok(())
}
```

`return Err(CrmError::Usage(…).into())`: `?` does the conversion to `anyhow::Error` for you, but
a bare `return Err(…)` doesn't, so `.into()` does it by hand.

Finally, delete the old blocking `prompt` function from `cli/mod.rs` (and its now-unused
`std::io` import) and the `is_mutating` method if you still have it. `cargo clippy --all-targets
-- -D warnings` is clean, which also proves there's no `await_holding_lock` anywhere.

---

## Your Turn 2 — Ctrl-C cancels the current command

```rust
    /// Like `read_line`, but end of input is an error: we're in the middle of a command.
    /// Ctrl-C cancels the command (not the whole program).
    pub(crate) async fn prompt(&mut self, label: &str) -> anyhow::Result<String> {
        tokio::select! {
            line = self.read_line(label) => {
                line?.context("input ended in the middle of a command")
            }
            // Dropping the read_line future is safe: it was only waiting on
            // `mpsc::Receiver::recv`, which is cancel-safe — no line is lost.
            _ = tokio::signal::ctrl_c() => {
                println!();
                anyhow::bail!("cancelled")
            }
        }
    }
```

Every handler already does `input.prompt(…).await?`, so the `Err("cancelled")` travels up
through `?` to `repl`, which prints `Error: cancelled` and loops. Nothing was written to the CRM,
because every handler only calls `write_crm` **after** its last prompt. "Prompt first, lock
second" gives you cancellation for free: an aborted command has nothing to undo.

The `crm>` prompt uses `read_line` (not `prompt`) inside `repl`'s own `select!`, so Ctrl-C there
still means "quit".

One subtlety: `tokio::signal::ctrl_c()` only *listens* while a future created by it is being
polled. A Ctrl-C pressed while a command is running *between* prompts (say, during the
microseconds inside `write_crm`) has no listener and is ignored. That's fine for us.

---

## Your Turn 3 — async autosave tests

```rust
#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

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

    impl CountingStorage {
        fn saves(&self) -> usize {
            self.saves.load(Ordering::SeqCst)
        }
    }

    fn state(dirty: bool) -> Arc<Mutex<AppData>> {
        Arc::new(Mutex::new(AppData { crm: Crm::default(), dirty }))
    }

    // These are #[tokio::test]s: each gets its own single-threaded runtime. A blocking
    // std::thread::sleep would freeze that one thread, so the task under test could never
    // run while we wait; tokio::time::sleep yields instead.

    #[tokio::test]
    async fn clean_state_is_never_saved() {
        let storage = Arc::new(CountingStorage::default());
        let (tx, rx) = oneshot::channel();
        let handle = spawn_autosave(state(false), storage.clone(), Duration::from_millis(10), rx);
        tokio::time::sleep(Duration::from_millis(50)).await;
        tx.send(()).unwrap();
        handle.await.unwrap();
        assert_eq!(storage.saves(), 0);
    }

    #[tokio::test]
    async fn dirty_state_is_saved_on_a_tick() {
        let storage = Arc::new(CountingStorage::default());
        let shared = state(true);
        let (tx, rx) = oneshot::channel();
        let handle = spawn_autosave(shared.clone(), storage.clone(), Duration::from_millis(20), rx);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(storage.saves(), 1, "saved once, then clean");
        assert!(!lock(&shared).dirty);
        tx.send(()).unwrap();
        handle.await.unwrap();
        assert_eq!(storage.saves(), 1, "nothing left to save at shutdown");
    }

    #[tokio::test]
    async fn dirty_state_is_saved_once_on_shutdown() {
        let storage = Arc::new(CountingStorage::default());
        let (tx, rx) = oneshot::channel();
        let handle = spawn_autosave(state(true), storage.clone(), Duration::from_secs(3600), rx);
        tx.send(()).unwrap();
        handle.await.unwrap();
        assert_eq!(storage.saves(), 1);
    }

    #[tokio::test]
    async fn dropping_the_sender_also_stops_the_task() {
        let storage = Arc::new(CountingStorage::default());
        let (tx, rx) = oneshot::channel::<()>();
        let handle = spawn_autosave(state(true), storage.clone(), Duration::from_secs(3600), rx);
        drop(tx);
        handle.await.unwrap();
        assert_eq!(storage.saves(), 1);
    }

    #[test]
    fn lock_recovers_from_a_poisoned_mutex() {
        // unchanged from Lab 25 — poisoning is about OS threads, so this stays a plain #[test]
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
}
```

### Reasoning

- **Why does `dirty_state_is_saved_on_a_tick` see exactly 1 save?** The first tick (after 20 ms)
  saves and clears `dirty`. The later ticks (40, 60, 80 ms) find a clean state and do nothing.
  The test checks *behaviour* ("saves when dirty, not otherwise"), not tick counts, so it isn't
  sensitive to timing. In the reference run it passed 15/15 times.
- **`spawn_blocking` inside a `#[tokio::test]` works**, even on the single-threaded test
  runtime. The blocking pool is separate from the (one) worker thread.
- **`assert!(!lock(&shared).dirty)` inside an async fn.** `lock(...)` returns a guard, we read
  one field, and the guard is a temporary that's dropped at the end of the statement. No
  `.await` happens while it's alive, so this is fine. (Clippy agrees.)
- For fully deterministic timer tests, Tokio has a paused virtual clock
  (`#[tokio::test(start_paused = true)]`, behind the `test-util` feature, which `full` doesn't
  include). Worth knowing; not needed here.

---

## Experiment answers

**Experiment 1 (blocking the runtime).** With `current_thread`, the executor is one thread
running one task at a time. Each task runs until its next `Pending`. `std::thread::sleep` never
returns `Pending`, it just stops the thread, so the REPL couldn't be polled for 3 seconds. In the
reference run, `company list` was typed at second 51 and its output appeared at second 54. Moral:
**async code is cooperative.** Every task must keep reaching `.await` points.

**Experiment 2 (`tokio::io::stdin`).** Covered in the README. In the reference test (stdin was a
pipe kept open for 8 seconds, SIGINT sent after 1.5 s), the thread-based `Input` exited after 1 s.
The `tokio::io::stdin` version printed "Goodbye!" at the same moment but only exited at 8 s, when
the pipe closed and the hidden blocking read returned.

**Experiment 3 (borrowing into `spawn_blocking`).** E0521, "borrowed data escapes outside of
function". The bound `F: FnOnce() -> R + Send + 'static` is the same as `thread::spawn`'s. Even
though *we* await the handle immediately, the closure's lifetime isn't tied to our stack frame:
if the `repl` future is dropped (cancelled) mid-await, the blocking closure keeps running. The
compiler can't know you won't cancel, so it needs owned data.

**Experiment 4 (thread ids).** The id changes between ticks. In the reference run the autosave
task printed `ThreadId(9)`, `ThreadId(6)`, `ThreadId(11)`, `ThreadId(6)`, … Tokio's work-stealing
scheduler resumes a task on whichever worker is free. That's concrete proof that everything the
task holds across an `.await` really does cross threads, which is why `tokio::spawn` requires
`Send`.

**`drop(data)` before `select!` (Step 6).** It didn't fix the `Send` error in Rust 1.99. The check
for "is this value alive across the `.await`?" is conservative, and a variable that was mutably
borrowed earlier in the scope may still count. A block `{ … }` that ends before the `.await`, or a
synchronous helper function, always works, and also makes the short critical section visible
to anyone reading the code.

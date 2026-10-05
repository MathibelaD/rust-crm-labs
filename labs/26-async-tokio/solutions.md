# Lab 26 — Solutions

> 🔴 One good answer per task, with the reasoning. Your prompts and messages come from your
> earlier labs. What matters is the *shape*: prompt first, lock second, no guard across `.await`.

---

## Your Turn 1 — finish the conversion

`execute` now dispatches every command to an async handler:

```rust
        Command::Company(command) => company(state, input, command).await?,
        Command::Contact(command) => contact(state, input, command).await?,
        Command::Deal(cmd) => deal(state, input, cmd).await?,
        Command::Pipeline => read_crm(state, print_pipeline),
        Command::Lead(cmd) => lead(state, input, cmd).await?,
        Command::LogActivity { subject } => log_activity(state, input, subject).await?,
```

Each handler below is your Lab 14–20 handler with the same prompts and the same printing. Only
the plumbing changed: `prompt(…)` became `input.prompt(…).await?`, `prompt_optional(…)` became
`optional(input.prompt(…).await?)`, and every use of the CRM moved into one `read_crm` or
`write_crm` call **after** the last prompt.

### Contacts

```rust
async fn contact(
    state: &Mutex<AppData>,
    input: &mut Input,
    command: ContactCommand<'_>,
) -> anyhow::Result<()> {
    match command {
        ContactCommand::Add => {
            let name = input.prompt("Name: ").await?;
            let email = Email::parse(&input.prompt("Email: ").await?)?;
            let phone = optional(input.prompt("Phone (optional): ").await?);
            let company_id = read_company_id(input).await?;
            let id = write_crm(state, |crm| crm.add_contact(name, email, phone, company_id))?;
            println!("Added contact {id}");
        }
        ContactCommand::List { filter, page } => read_crm(state, |crm| {
            let contacts = crm.list_contacts(&filter);
            let pages = contacts.len().div_ceil(PAGE_SIZE).max(1);
            match contacts.chunks(PAGE_SIZE).nth(page - 1) {
                Some(rows) => {
                    print_table(CONTACT_HEADER, rows);
                    println!("Page {page} of {pages} ({} matching)", contacts.len());
                }
                None if contacts.is_empty() => println!("No contacts match."),
                None => println!("No page {page}: there are only {pages}."),
            }
        }),
        ContactCommand::Show { id } => read_crm(state, |crm| {
            let contact = crm.contact(id)?;
            print_table(CONTACT_HEADER, &[contact]);
            if !contact.has_phone() {
                println!("(no phone on file)");
            }
            println!("  Domain:   {}", contact.email.domain());
            println!("  Initials: {}", initials(&contact.name));
            Ok::<(), CrmError>(())
        })?,
        ContactCommand::Update { id } => update_contact(state, input, id).await?,
        ContactCommand::Delete { id } => {
            let contact = write_crm(state, |crm| crm.remove_contact(id))?;
            print_deleted("contact", &contact);
        }
        ContactCommand::Search { term } => read_crm(state, |crm| {
            let results = crm.contacts.search(term);
            if results.is_empty() {
                println!("No contacts match '{term}'.");
            } else {
                print_table(CONTACT_HEADER, &results);
            }
        }),
    }
    Ok(())
}
```

```rust
async fn update_contact(
    state: &Mutex<AppData>,
    input: &mut Input,
    id: ContactId,
) -> anyhow::Result<()> {
    // Fail fast, before asking about a contact that doesn't exist.
    let label = read_crm(state, |crm| crm.contact(id).map(|c| c.label()))?;
    println!("Editing {label}");

    let name = optional(input.prompt("Name (blank to keep): ").await?);
    let answer = input.prompt("Email (blank to keep): ").await?;
    let email = if answer.is_empty() {
        None
    } else {
        Some(Email::parse(&answer)?)
    };
    let phone = optional(input.prompt("Phone (blank to keep): ").await?);

    // `update_contact` looks the contact up again and checks for a duplicate email,
    // all under this one lock: the contact may have changed while we were prompting.
    write_crm(state, |crm| crm.update_contact(id, name, email, phone))?;
    println!("Updated contact {id}");
    Ok(())
}

/// Blank means "no company"; anything else must be a number.
async fn read_company_id(input: &mut Input) -> anyhow::Result<Option<CompanyId>> {
    let answer = input.prompt("Company id (blank for none): ").await?;
    if answer.is_empty() {
        return Ok(None);
    }
    let id: u64 = answer
        .parse()
        .map_err(|_| CliError::Usage("company id must be a number (or blank for none)"))?;
    Ok(Some(CompanyId::from(id)))
}
```

**Why validate the email *before* `write_crm`?** `Email::parse` doesn't need the CRM, so it
belongs outside the lock. As a bonus, an invalid email fails before the lock is taken and before
`dirty` is set.

**Why two critical sections in `update`?** The prompts must happen *outside* the lock, and we
also want to fail fast (your Lab 14 version printed `Editing …` before asking anything), so there's
a gap between the existence check and the write. In this CLI the only other party is the
autosave task, which never deletes anything. But Lab 27 adds HTTP handlers that can `DELETE` a
contact during that gap. `Crm::update_contact` looks the contact up **again** (returning
`NotFound` if it's gone) and checks the new email for duplicates, all inside the one
`write_crm`, under the lock that the update happens under. Checked in a separate `read_crm`,
another party could add a contact with that email in the gap. This is the classic
**check-then-act** race, and the cure is always to re-check under the lock that you act under.
Lab 14 put that logic in `Crm`, so the CLI only has to call it in the right place.

**`read_company_id` stays a helper**, now `async` because it prompts. Its error is still a
`CliError::Usage`: `?` turns it into an `anyhow::Error`.

### Deals

```rust
async fn deal(state: &Mutex<AppData>, input: &mut Input, cmd: DealCommand) -> anyhow::Result<()> {
    match cmd {
        DealCommand::Add => {
            let company_id = input
                .prompt("Company id: ")
                .await?
                .parse()
                .map_err(|_| CliError::Usage("company id must be a number"))?;
            let title = input.prompt("Title: ").await?;
            let value = Money::parse(&input.prompt("Value (e.g. 1250.50): ").await?)?;
            let id = write_crm(state, |crm| {
                crm.add_deal(CompanyId(company_id), title, value)
            })?;
            println!("Added deal {id}");
        }
        DealCommand::List => read_crm(state, |crm| {
            if crm.deals.is_empty() {
                println!("No deals yet.");
            }
            for deal in crm.deals.iter() {
                println!("{deal}");
            }
        }),
        DealCommand::Show { id } => read_crm(state, |crm| {
            let deal = crm.deal(id)?;
            let company = crm.company(deal.company_id)?;
            println!("Deal {}: {}", deal.id, deal.title);
            println!("  Company: {} {}", company.id, company.name);
            println!("  Value:   {}", deal.value);
            println!("  Stage:   {}", deal.stage);
            print_recent_history(crm, Subject::Deal(id));
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
            let source = match optional(
                input
                    .prompt(
                        "Source (website/referral/event/cold_outreach/other, blank for other): ",
                    )
                    .await?,
            ) {
                Some(raw) => raw.parse()?,
                None => LeadSource::Other,
            };
            let notes = optional(input.prompt("Notes (blank for none): ").await?);
            let id = write_crm(state, |crm| {
                crm.add_lead(name, email, company_name, source, notes)
            })?;
            println!("Added lead {id}");
        }
        LeadCommand::List(filter) => read_crm(state, |crm| {
            let leads = crm.list_leads(&filter);
            if leads.is_empty() {
                println!("No leads found.");
            }
            for lead in leads {
                println!("{lead}");
            }
        }),
        LeadCommand::Qualify { id } => {
            write_crm(state, |crm| crm.qualify_lead(id))?;
            println!("Lead {id} is qualified");
        }
        LeadCommand::Disqualify { id } => {
            write_crm(state, |crm| crm.disqualify_lead(id))?;
            println!("Lead {id} is disqualified");
        }
        LeadCommand::Convert { id } => {
            read_crm(state, |crm| crm.lead(id).map(|_| ()))?; // fail fast before asking questions
            let deal = if input
                .prompt("Create a deal? (y/n): ")
                .await?
                .eq_ignore_ascii_case("y")
            {
                let title = input.prompt("Deal title: ").await?;
                let value = Money::parse(&input.prompt("Deal value (e.g. 1250.50): ").await?)?;
                Some((title, value))
            } else {
                None
            };
            // The whole conversion happens under one lock: nobody sees a half-converted lead.
            let summary = write_crm(state, |crm| crm.convert_lead(id, deal))?;
            print!(
                "Converted lead {id}: company {}, contact {}",
                summary.company_id, summary.contact_id
            );
            match summary.deal_id {
                Some(deal_id) => println!(", deal {deal_id}"),
                None => println!(),
            }
        }
    }
    Ok(())
}
```

Note `lead convert`: the whole conversion (remove the lead, insert company/contact/deal, or hand
the lead back on failure) happens inside **one** `write_crm`. Nobody can ever observe a
half-converted lead. In Lab 31 the same guarantee comes from a database transaction. The quick
`read_crm` before the questions keeps Lab 19's "fail fast before asking" behaviour.

### Activity logging

```rust
async fn log_activity(
    state: &Mutex<AppData>,
    input: &mut Input,
    subject: Subject,
) -> anyhow::Result<()> {
    read_crm(state, |crm| crm.check_subject(subject))?; // fail fast, before asking questions
    let kind_input = input.prompt("Kind (call/email/meeting): ").await?;
    let kind = match kind_input.to_lowercase().as_str() {
        "call" => {
            let raw = input.prompt("Duration in minutes: ").await?;
            let minutes = raw.parse().map_err(|_| ValidationError::InvalidValue {
                field: "duration in minutes",
                value: raw,
            })?;
            ActivityKind::Call { minutes }
        }
        "email" => ActivityKind::Email {
            subject: input.prompt("Email subject: ").await?,
        },
        "meeting" => {
            let starts_at =
                parse_datetime(&input.prompt("Starts at (YYYY-MM-DD HH:MM, UTC): ").await?)?;
            let attendees = parse_contact_ids(
                &input
                    .prompt("Attendee contact ids (e.g. 3,5; blank for none): ")
                    .await?,
            )?;
            ActivityKind::Meeting {
                starts_at,
                attendees,
            }
        }
        _ => {
            return Err(ValidationError::InvalidValue {
                field: "activity kind",
                value: kind_input,
            }
            .into());
        }
    };
    let summary = input.prompt("Summary: ").await?;
    let occurred_at = match optional(
        input
            .prompt("When (YYYY-MM-DD HH:MM, UTC; blank for now): ")
            .await?,
    ) {
        Some(raw) => parse_datetime(&raw)?,
        None => Utc::now(),
    };
    let id = write_crm(state, |crm| {
        crm.log_activity(subject, kind, summary, occurred_at)
    })?;
    println!("Logged activity {id} on {subject}");
    Ok(())
}
```

`return Err(ValidationError::InvalidValue { … }.into())`: `?` does the conversion to
`anyhow::Error` for you, but a bare `return Err(…)` doesn't, so `.into()` does it by hand.
`parse_datetime` and `parse_contact_ids` are unchanged: they never prompted, they only parse.

### The unit test

`unknown_ids_are_not_found` called `execute(&mut crm, command)`. Now `execute` needs the shared
state and an `Input`, and a test must not read the real stdin. A test-only constructor in
`src/cli/input.rs` fills the channel with canned answers:

```rust
    /// Test helper: an `Input` that answers with `lines`, then reports end of input.
    #[cfg(test)]
    pub(crate) fn from_lines(lines: &[&str]) -> Self {
        let (tx, rx) = mpsc::channel(lines.len().max(1));
        for line in lines {
            tx.try_send(Ok(line.to_string()))
                .expect("the channel has room for every line");
        }
        Self { lines: rx } // `tx` is dropped here: end of input after the last line
    }
```

```rust
    #[tokio::test]
    async fn unknown_ids_are_not_found() {
        let state = Mutex::new(AppData {
            crm: Crm::new(),
            dirty: false,
        });
        let mut input = Input::from_lines(&[]); // no command below may prompt
        let commands = [
            Command::Company(CompanyCommand::Show { id: CompanyId(42) }),
            Command::Company(CompanyCommand::Delete { id: CompanyId(42) }),
            Command::Contact(ContactCommand::Show { id: ContactId(42) }),
            Command::Contact(ContactCommand::Update { id: ContactId(42) }),
            Command::Contact(ContactCommand::Delete { id: ContactId(42) }),
        ];
        for command in commands {
            let err = execute(&state, &mut input, command).await.unwrap_err();
            assert!(
                matches!(
                    err.downcast_ref::<CrmError>(),
                    Some(CrmError::NotFound { id: 42, .. })
                ),
                "unexpected error: {err:#}"
            );
        }
    }
```

`#[tokio::test]` gives the test its own runtime so it can `.await`. The command errors arrive as
`anyhow::Error`; `downcast_ref::<CrmError>()` asks "is the error inside really a `CrmError`?",
the same `downcast_ref` you used on `dyn Error` in Lab 22. `Input::from_lines(&[])` is end of
input straight away: if a handler did prompt, the test would fail with "input ended in the
middle of a command", which is exactly the regression it guards against for `contact update`.

Finally, delete the old blocking `prompt` and `prompt_optional` helpers from `cli/mod.rs` (and
the now-unused `std::io` import), and the `is_mutating` method if you still have it.
`cargo clippy --all-targets -- -D warnings` is clean, which also proves there's no
`await_holding_lock` anywhere.

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
        Arc::new(Mutex::new(AppData {
            crm: Crm::default(),
            dirty,
        }))
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
        let handle = spawn_autosave(
            shared.clone(),
            storage.clone(),
            Duration::from_millis(20),
            rx,
        );
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

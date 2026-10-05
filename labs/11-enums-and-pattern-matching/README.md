# Lab 11 — Enums & Pattern Matching ♻️

> **Phase:** 3 — Modelling the Domain · **Builds on:** Lab 10 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-10` · **After:** tag `lab-11`

> This lab assumes you completed **Your Turns 1–3 in Lab 10** (`ParsedCommand::arg`,
> `display_name`, `first_by_domain` with the colleague note on `add`). If you skipped any, copy
> them from [Lab 10's solutions.md](../10-lifetimes/solutions.md) first. The code below shows
> those pieces as they appear in the reference solutions.
>
> **Did Challenge A?** If you kept the `duplicates` command, you'll add a `Duplicates` variant
> to the new `Command` enum yourself as you go. Nothing later depends on it.

## 🎯 Goal

Replace the string-matching in the main loop with a typed `Command` enum, and give every
customer a `CustomerStatus` (prospect, active or churned). After this lab, a typo in a command
name is a **compile error**, not a silent runtime bug.

## 🧠 What You'll Learn

- Why "stringly-typed" code hides bugs, and the idea of **making illegal states unrepresentable**
- Enums with and without data: unit variants, tuple variants, struct variants
- An enum that borrows: `Command<'a>` (the lifetime from Lab 10 moves in)
- Exhaustive `match`, and how E0004 turns the compiler into a to-do list
- The pattern toolbox: tuple patterns, slice patterns (`[]`, `[x]`, `[x, ..]`), or-patterns
  (`"quit" | "exit"`), `@` bindings, match guards (`if ...`), `if let`, `let ... else`, `matches!`
- Why a `_ =>` wildcard arm can be a trap
- How enums are laid out in memory (a tag plus the biggest payload)

## 🔨 What We're Building

Today the main loop matches on `&str`:

```rust
match parsed.name {
    "add" => { ... }
    "delete" => { ... }
    other => println!("Unknown command: {other}. ..."),
}
```

By the end of this lab, parsing and running are two separate steps:

```text
"status 2 active"  ──parse_command──▶  Command::Status { id: 2, status: CustomerStatus::Active }
                                                     │
                                                 main loop
                                              match command { ... }
```

The parser is the only place that deals with text. Everything after it works with real types:
`u32` ids, `usize` pages, a `CustomerStatus`, never "a string that we hope says `active`".

And customers get a status:

```text
crm> status 1 active
Customer #1 is now active.
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100 [active]
#2 Grace Hopper <grace@example.com> 555-0199 [prospect]
Page 1 of 1
```

`DealStage`, `LeadSource`, `ActivityKind` and `Role` will all be enums later in the course.
This lab is where you learn to think in them.

---

## Step 1 — What's wrong with strings?

Open `src/main.rs` and look at the `match parsed.name { ... }` in `main`. It works. Here's what it
can't protect you from.

> 🟡 **EXPERIMENT**: predict first. In the `match parsed.name` block, change the pattern
> `"delete" =>` to `"delte" =>`. Will `cargo check` complain?

```rust
            "delte" => match parse_id(&parsed.args) {
```

Run `cargo check`. It's perfectly happy. Run the CRM and type `delete 1`:

```text
crm> delete 1
Unknown command: delete. Type 'help' for a list of commands.
```

The compiler can't help, because as far as it knows `"delte"` is a perfectly good string. Every
string is. The bug only shows up when a user tries the command, and only if they notice. Put
`"delete"` back.

That's what **stringly-typed** means: using `String`/`&str` for things that are really a small,
fixed set of choices. Two more examples hiding in the CRM:

- The usage messages (`"Usage: show <id>"`) and the parsing (`parse_id(&parsed.args)`) are
  scattered across six arms of `main`. Checking that `show` got exactly one numeric argument is
  mixed in with *doing* the `show`.
- A customer's status. We don't have one yet. Imagine adding it with booleans:

```rust
// A tempting design. Don't type this.
struct Customer {
    // ...
    is_active: bool,
    is_churned: bool,
}
```

Two booleans give **four** combinations. Only three make sense (prospect = neither, active,
churned). `is_active: true, is_churned: true` is nonsense, but the type allows it, so somewhere,
someday, some code will produce it, and every function that reads a customer has to wonder
about it.

### The principle: make illegal states unrepresentable

Design your types so that **every value the type can hold is a valid state of the business**.
Then nobody has to check for invalid ones, because they can't exist.

Rust's main tool for this is the `enum`. A struct says "**all** of these fields, together". An
enum says "**exactly one** of these variants". (Type theorists call them *product* and *sum*
types.)

```rust
enum CustomerStatus {
    Prospect,
    Active,
    Churned,
}
```

Three variants, three possible values, all of them valid. There's nothing to check.

> **Coming from TypeScript?** A Rust enum with data is a *discriminated union* like
> `type Command = { kind: "show"; id: number } | { kind: "search"; term: string }`, except the
> compiler forces every `match` to handle every variant, and there's no way to make up a `kind`
> that isn't in the list.

---

## Step 2 — An enum with data: `Command<'a>`

An enum variant can carry data, and each variant can carry different data:

- **unit variants**: `Help`, no data
- **tuple variants**: `Unknown(&'a str)`, positional fields
- **struct variants**: `Show { id: u32 }`, named fields

Add this above `parse_command`:

> 🟢 **FOLLOW ALONG**

```rust
/// A command typed at the `crm>` prompt, already checked and converted to real types.
#[derive(Debug, PartialEq)]
enum Command<'a> {
    Help,
    Version,
    Quit,
    Add,
    Count,
    Normalize,
    List { page: usize },
    Show { id: u32 },
    Update { id: u32 },
    Delete { id: u32 },
    Search { term: &'a str },
    Unknown(&'a str),
    Invalid(String),
}
```

Read it as a list of everything a user can ask the CRM to do, with exactly the data each request
needs:

- `Show { id: u32 }` can't exist without an id, and the id is already a number. If you hold a
  `Command::Show`, parsing already succeeded.
- `List { page: usize }` always has a page. "No page given" was turned into `1` by the parser.
- `Search { term: &'a str }` **borrows** the search term from the input line, just like
  `ParsedCommand<'a>` did in Lab 10. The enum needs the lifetime parameter for the same reason
  the struct did: one of its variants holds a reference. `Help` doesn't use `'a`, and that's
  fine. The lifetime belongs to the type as a whole.
- `Unknown(&'a str)` is the command word the user typed that we didn't recognise (borrowed too).
- `Invalid(String)` carries a usage message such as `Usage: show <id>`. It's **owned**, because we
  build it with `format!`. (In Lab 12, `Unknown` and `Invalid` disappear: errors get their own type.)

`#[derive(Debug, PartialEq)]` lets us print a `Command` with `{:?}` and compare two commands
with `==`, which the tests will want.

### What an enum looks like in memory

A value of an enum type is a **tag** (which variant is it?) plus enough space for the
**largest** variant's data. `Command::Help` and `Command::Invalid(String)` take the same number of
bytes. Only the tag differs, and the unused space is ignored. That's why a `Vec<Command>` can
store any mix of variants side by side: every element is the same size.

```text
Command::Show { id: 7 }        [ tag=Show | 7 | ...unused... ]
Command::Invalid("Usage: …")   [ tag=Invalid | ptr | len | cap ]   ← the biggest variant
```

### `Option` is just an enum

You've used it since Lab 05. Here's its whole definition (from the standard library):

```rust
enum Option<T> {
    None,
    Some(T),
}
```

`Some(customer)` and `None` are its variants. Everything you learn in this lab about matching on
your own enums applies to `Option` and `Result`. Lab 12 makes full use of that.

---

## Step 3 — Parse once, into a `Command`

Now rewrite `parse_command`. It used to split the line and return a `ParsedCommand`. It now does
**all** the parsing and returns a finished `Command`, or `None` for a blank line.

Delete `struct ParsedCommand<'a>`, its `impl` block (the `arg` method), and the old
`parse_command`. Then add:

> 🟢 **FOLLOW ALONG**

```rust
/// Turns one input line into a `Command`. Returns `None` for a blank line.
fn parse_command(input: &str) -> Option<Command<'_>> {
    let mut words = input.split_whitespace();
    let name = words.next()?;
    let args: Vec<&str> = words.collect();

    let command = match (name, args.as_slice()) {
        ("help", _) => Command::Help,
        ("version", _) => Command::Version,
        ("quit" | "exit", _) => Command::Quit,
        ("add", _) => Command::Add,
        ("count", _) => Command::Count,
        ("normalize", _) => Command::Normalize,
        ("list", args) => match parse_page(args) {
            Some(page) => Command::List { page },
            None => usage("list [page]"),
        },
        ("show", args) => match parse_id(args) {
            Some(id) => Command::Show { id },
            None => usage("show <id>"),
        },
        ("update", args) => match parse_id(args) {
            Some(id) => Command::Update { id },
            None => usage("update <id>"),
        },
        ("delete", args) => match parse_id(args) {
            Some(id) => Command::Delete { id },
            None => usage("delete <id>"),
        },
        ("search", [term, ..]) => Command::Search { term },
        ("search", []) => usage("search <term>"),
        (other, _) => Command::Unknown(other),
    };
    Some(command)
}

/// A `Command::Invalid` carrying the usual "Usage: ..." message.
fn usage(text: &str) -> Command<'static> {
    Command::Invalid(format!("Usage: {text}"))
}
```

`parse_id` and `parse_page` are your helpers from Lab 09; they don't change.

There's a lot of pattern syntax in there. Line by line:

| Pattern | Matches | Binds |
|---|---|---|
| `("help", _)` | a tuple whose first part is `"help"`; `_` matches any args and ignores them | nothing |
| `("quit" \| "exit", _)` | an **or-pattern**: either word | nothing |
| `("list", args)` | first part is `"list"`, any args | `args: &[&str]` (shadows the outer `args`) |
| `("search", [term, ..])` | a **slice pattern**: at least one arg; `..` means "and any number more" | `term`, the first arg |
| `("search", [])` | exactly zero args | nothing |
| `(other, _)` | anything at all | `other`, the command word |

Why match on a tuple `(name, args.as_slice())`? Because the decision depends on **both** the
command word and the shape of the arguments. A tuple pattern checks both at once, top to bottom.
`args.as_slice()` turns the `Vec<&str>` into a `&[&str]`, because slice patterns like `[term, ..]`
work on slices, not on `Vec`s.

Three more details worth noticing:

- `let name = words.next()?;` uses `?` on an `Option`: inside a function that returns `Option`,
  `?` means "if this is `None`, return `None` right now". A blank line has no first word, so
  `parse_command` returns `None`. (Lab 12 explains `?` properly.)
- `("search", [term, ..]) => Command::Search { term }`: `term` is a `&&str` here (a reference to
  an element of the slice), and the field wants a `&str`. Rust **auto-derefs** it for you in a
  struct field position. The `&str` inside still points into the **input line**, so `Command<'_>`
  carries the input's lifetime, exactly as the signature says.
- **Order matters.** Arms are tried top to bottom, and the first match wins. `(other, _)` matches
  everything, so it must come last.

> 🟡 **EXPERIMENT**: move the `(other, _)` arm to the top of the `match` and run `cargo check`.
> You'll get one `unreachable pattern` warning per arm below it. The compiler knows those arms
> can never run. Move it back.

### Why delete `ParsedCommand`?

`ParsedCommand<'a>` was a stepping stone: "a name and some words". `Command<'a>` is what those
words *mean*. Its `Search { term: &'a str }` variant inherits the borrowing job, and `arg(0)` is
replaced by the slice pattern `[term, ..]`. Keeping both types would mean two descriptions of the
same thing. Delete the Lab 10 tests that used `ParsedCommand` too; you'll write better ones in
Your Turn 1. Keep one idea from Lab 10's `arg_outlives_the_parsed_command` test, though: the
search term must outlive the `Command`. Rewrite that test like this:

> 🟢 **FOLLOW ALONG**

```rust
    #[test]
    fn search_term_outlives_the_command() {
        let line = String::from("search ada");
        let term = match parse_command(&line) {
            Some(Command::Search { term }) => term,
            other => panic!("expected a search, got {other:?}"),
        }; // the Command is gone here; `line` is still alive
        assert_eq!(term, "ada");
    }
```

### Let the compiler list the work

Run `cargo check` now. `main` still treats `parse_command`'s result as a `ParsedCommand`:

```text
error[E0609]: no field `name` on type `Option<Command<'_>>`
   --> src/main.rs:301:22
    |
301 |         match parsed.name {
    |                      ^^^^ unknown field

error[E0609]: no field `args` on type `Option<Command<'_>>`
   --> src/main.rs:331:48
    |
331 |             "list" => match parse_page(&parsed.args) {
    |                                                ^^^^ unknown field

error[E0599]: no method named `arg` found for enum `Option<T>` in the current scope
   --> src/main.rs:348:38
    |
348 |             "search" => match parsed.arg(0) {
    |                                      ^^^ method not found in `Option<Command<'_>>`
...
error: could not compile `rust-crm` (bin "rust-crm") due to 6 previous errors
```

(Your line numbers will differ.) Six errors, and each one is a place in `main` that still thinks
in strings. That's a feature: when you change a type, the compiler hands you the complete list
of code that depended on the old one. You don't have to search for it.

---

## Step 4 — Match on the `Command`

Replace everything from `let parsed = parse_command(&input);` down to (not including)
`count += 1;` with this. The **bodies** of the arms are the ones you already have; only the
patterns change, and the arms no longer parse anything themselves.

> 🟢 **FOLLOW ALONG**

```rust
        let Some(command) = parse_command(&input) else {
            continue; // blank line
        };

        match command {
            Command::Help => print_help(),
            Command::Version => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
            Command::Quit => break count,
            Command::Add => {
                let name = prompt("Name: ");
                let email = prompt("Email: ");
                let phone = prompt("Phone: ");
                if store.email_exists(&email) {
                    println!("A customer with email {email} already exists.");
                } else {
                    // Look first, while we only need a shared borrow of the store.
                    // The note is an owned String, so it holds no borrow of `store`.
                    let mut note = None;
                    if let Some(domain) = email_domain(&email)
                        && let Some(other) = store.first_by_domain(domain)
                    {
                        note = Some(format!(
                            "Note: #{} {} also uses {domain}.",
                            other.id, other.name
                        ));
                    }
                    let id = store.add(name, email, phone);
                    println!("Added customer #{id}");
                    if let Some(note) = note {
                        println!("{note}");
                    }
                }
            }
            Command::List { page } => {
                let customers = store.page(page, PAGE_SIZE);
                if store.len() == 0 {
                    println!("No customers yet.");
                } else if customers.is_empty() {
                    println!("No customers on page {page}.");
                } else {
                    for customer in customers {
                        println!("{}", customer.summary());
                    }
                    let pages = store.len().div_ceil(PAGE_SIZE);
                    println!("Page {page} of {pages}");
                }
            }
            Command::Search { term } => {
                let results = store.search(term);
                if results.is_empty() {
                    println!("No customers match '{term}'.");
                }
                for customer in results {
                    println!("{}", customer.summary());
                }
            }
            Command::Count => {
                let n = store.len();
                if n == 1 {
                    println!("1 customer");
                } else {
                    println!("{n} customers");
                }
            }
            Command::Show { id } => match store.find(id) {
                Some(customer) => {
                    println!("{}", customer.summary());
                    if !customer.has_phone() {
                        println!("(no phone on file)");
                    }
                    let domain = email_domain(&customer.email).unwrap_or("(none)");
                    println!("  Domain:   {domain}");
                    println!("  Initials: {}", initials(&customer.name));
                }
                None => println!("No customer with id {id}."),
            },
            Command::Update { id } => {
                if let Some(customer) = store.find_mut(id) {
                    let name = prompt("Name (blank to keep): ");
                    if !name.is_empty() {
                        customer.name = name;
                    }
                    let email = prompt("Email (blank to keep): ");
                    if !email.is_empty() {
                        customer.update_email(email);
                    }
                    let phone = prompt("Phone (blank to keep): ");
                    if !phone.is_empty() {
                        customer.phone = phone;
                    }
                    println!("Updated customer #{id}");
                } else {
                    println!("No customer with id {id}.");
                }
            }
            Command::Delete { id } => match store.remove(id) {
                Some(customer) => println!(
                    "Deleted customer #{} ({})",
                    customer.id,
                    display_name(&customer.name, &customer.email)
                ),
                None => println!("No customer with id {id}."),
            },
            Command::Normalize => {
                let changed = store.normalize_emails();
                println!("Normalised {changed} email(s).");
            }
            Command::Unknown(name) => {
                println!("Unknown command: {name}. Type 'help' for a list of commands.")
            }
            Command::Invalid(usage) => println!("{usage}"),
        }
```

`count += 1;` and everything after it stay as they were. If your `update` or `show` bodies differ
from these (for example you print things in a different order), keep yours: only the pattern on
the left of `=>` matters in this step.

What changed, and why:

- **`let ... else`.** `let Some(command) = parse_command(&input) else { continue; };` says: "this
  pattern must match; if it doesn't, run the `else` block, which **must** leave the current
  scope" (`continue`, `break`, `return`, or a panic). After the statement, `command` is a plain
  `Command`, not an `Option`. Use `let ... else` when the "no" case is an early exit and the "yes"
  case is the rest of the function.
- **Destructuring in arms.** `Command::Show { id } => ...` matches the `Show` variant and binds
  its field to a local variable `id`. The arm doesn't parse anything: `id` is already a `u32`.
- **`if let`** in the `Update` arm: `if let Some(customer) = store.find_mut(id) { ... } else { ... }`
  is a `match` with exactly one interesting pattern. Use it when you care about one case. (A
  `match` with two arms is just as correct; pick whichever reads better.)
- **No `"" => continue` arm.** The parser returns `None` for blank input, and `let ... else`
  handles it.
- **No `_ =>` arm**, and no `other =>` catch-all. Every variant is listed by name. That's on
  purpose; see Step 5.

Run it:

```bash
cargo run
```

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> show
Usage: show <id>
crm> list two
Usage: list [page]
crm> delte 1
Unknown command: delte. Type 'help' for a list of commands.
crm> quit
Goodbye! (3 commands this session)
```

Then run `cargo test`. The tests from Labs 05–10 for `summary`, `parse_id`, `parse_page`,
`initials`, `page`, `search` and so on still pass: you changed how commands are **dispatched**,
not what they do.

---

## Step 5 — Exhaustiveness: the compiler as your to-do list

Try the typo again, now that commands are an enum.

> 🟡 **EXPERIMENT**: predict first. In `main`, change `Command::Delete { id } =>` to
> `Command::Delte { id } =>` and run `cargo check`.

```text
error[E0599]: no variant named `Delte` found for enum `Command<'_>`
   --> src/main.rs:391:22
    |
145 | enum Command<'a> {
    | ---------------- variant `Delte` not found here
...
391 |             Command::Delte { id } => match store.remove(id) {
    |                      ^^^^^
    |
help: there is a variant with a similar name
    |
391 |             Command::Delete { id } => match store.remove(id) {
    |                         +
```

The bug that was invisible in Step 1 is now a compile error, with a suggested fix. Put it back.

Now the more important direction: **adding** something.

> 🟡 **EXPERIMENT**: imagine we're adding an `export` command. Add a variant `Export,` to the
> enum (anywhere, say after `Normalize`). Don't touch anything else. Predict: will it compile?

```text
error[E0004]: non-exhaustive patterns: `Command::Export` not covered
   --> src/main.rs:304:15
    |
304 |         match command {
    |               ^^^^^^^ pattern `Command::Export` not covered
    |
note: `Command<'_>` defined here
   --> src/main.rs:145:6
    |
145 | enum Command<'a> {
    |      ^^^^^^^
...
152 |     Export,
    |     ------ not covered
    = note: the matched value is of type `Command<'_>`
help: ensure that all possible cases are being handled by adding a match arm with a wildcard pattern or an explicit pattern as shown
    |
407 ~             Command::Invalid(usage) => println!("{usage}"),
408 ~             Command::Export => todo!(),
    |
```

**Read the error.** The compiler found every `match` on `Command` that doesn't say what to do with
`Export`, and pointed at each one. In a bigger program there'd be several, in several files, and
you'd get one error per place. That's the experiment in this lab's title: *add a variant and let
the compiler list every place you need to update.*

Notice what it did **not** complain about: the parser. `parse_command` **produces** commands; it
doesn't match on them. The compiler can't know that you meant to add an `"export"` arm there. So
the rule of thumb is: *exhaustiveness checks the consumers of an enum; you still have to wire up
the producer.*

> 🟡 **EXPERIMENT**: now see the trap. Keep `Export` in the enum, and in `main` replace the
> `Command::Invalid(usage) => println!("{usage}"),` arm with a catch-all:
>
> ```rust
>             _ => println!("Something went wrong."),
> ```
>
> Run `cargo check`. It compiles. The wildcard swallowed `Export` **and** `Invalid`, silently. The
> next variant someone adds will be swallowed too.

Undo both changes (remove `Export`, restore the `Invalid` arm) and run `cargo check` again.

That's why this course avoids `_ =>` when matching on its **own** enums: a wildcard turns "the
compiler tells me what I forgot" into "the program quietly does the wrong thing". Wildcards are
fine when the set really is open-ended: strings, numbers, or other people's enums.

Commit this milestone:

```bash
git add .
git commit -m "Replace string commands with Command enum"
```

---

## Step 6 — The pattern toolbox

You've already used most of the pattern syntax Rust has. Here's the rest, applied to the CRM.

### `@` bindings: test a value *and* keep it

Your `parse_page` from Lab 09 looks something like this:

```rust
        [raw] => match raw.parse::<usize>() {
            Ok(0) | Err(_) => None,
            Ok(page) => Some(page),
        },
```

It works, but it says what pages *aren't*. With an `@` binding you can say what they **are**:

> 🟢 **FOLLOW ALONG**: update `parse_page`.

```rust
fn parse_page(args: &[&str]) -> Option<usize> {
    match args {
        [] => Some(1),
        [raw] => match raw.parse::<usize>() {
            Ok(page @ 1..) => Some(page),
            _ => None,
        },
        _ => None,
    }
}
```

`page @ 1..` means "match a number in the range `1..` (1 or more), **and** bind it to `page`".
Without the `@`, a range pattern like `Ok(1..)` would check the value but not give you a name for
it. Run `cargo test`: the `parse_page` tests from Lab 09 still pass.

### Match guards: patterns plus a condition

A guard is an `if` after a pattern. The arm only matches if the pattern matches **and** the
condition is true:

```rust
match store.find(id) {
    Some(customer) if !customer.has_phone() => println!("{} has no phone.", customer.name),
    Some(customer) => println!("{}", customer.summary()),
    None => println!("No customer with id {id}."),
}
```

Guards are the tool when the condition compares two bindings, calls a method, or anything else a
pattern can't express. The compiler doesn't look inside guards when checking exhaustiveness, so
an arm with a guard never counts as "covering" its pattern.

### `matches!`: a pattern as a `bool`

`matches!(value, pattern)` is `true` if the value matches the pattern. It's handy in tests and in
`if` conditions:

```rust
assert!(matches!(parse_command("show abc"), Some(Command::Invalid(_))));

if matches!(command, Command::Add | Command::Update { .. } | Command::Delete { .. }) {
    // a command that changes data
}
```

`Command::Update { .. }` means "the `Update` variant, whatever its fields". `..` in a struct
pattern ignores the remaining fields.

### Which one when?

| You want to… | Use |
|---|---|
| handle every case of an enum | `match` (no wildcard for your own enums) |
| do something in one case, nothing (or something simple) otherwise | `if let ... else` |
| get a value out or leave the function/loop early | `let ... else` |
| combine several conditions that each might not match | `if let ... && let ...` (let chains, edition 2024; you used one in Lab 10) |
| get a `bool` | `matches!` |

---

## Step 7 — `CustomerStatus`

Now the domain change. Add this above `struct Customer`:

> 🟢 **FOLLOW ALONG**

```rust
/// Where a customer is in their relationship with us.
#[derive(Debug, Clone, Copy, PartialEq)]
enum CustomerStatus {
    Prospect,
    Active,
    Churned,
}

impl CustomerStatus {
    /// Accepts "prospect", "active" or "churned" (any letter case).
    fn parse(s: &str) -> Option<CustomerStatus> {
        match s.to_lowercase().as_str() {
            "prospect" => Some(CustomerStatus::Prospect),
            "active" => Some(CustomerStatus::Active),
            "churned" => Some(CustomerStatus::Churned),
            _ => None,
        }
    }

    fn label(&self) -> &'static str {
        match self {
            CustomerStatus::Prospect => "prospect",
            CustomerStatus::Active => "active",
            CustomerStatus::Churned => "churned",
        }
    }
}
```

The interesting decisions:

- **`Clone, Copy`.** A `CustomerStatus` is just a tag, one byte. Like a `u32`, copying it is
  cheaper than borrowing it, so we let it be `Copy`. That means `customer.status` can be read,
  passed and compared without any move errors (Lab 06). A type can only be `Copy` if all its
  data is `Copy`, which is why `Command` can't be (it has a `String` inside `Invalid`).
- **`parse` returns `Option`.** Text from the user might not be a status. The `_ => None` arm is
  fine here: we're matching on a **string**, an open-ended set.
- **`label` has no wildcard.** It matches on our own enum, so it lists every variant. Add a
  variant and this function will refuse to compile until you give it a label.
- **`&'static str`** (Lab 10): the labels are string literals baked into the program, so they
  live for the whole run. Returning a borrowed literal costs nothing.
- `match self` where `self` is `&CustomerStatus`: you can write the patterns without `&`. Rust's
  *match ergonomics* see that you're matching a reference against non-reference patterns and
  handle it.

Now give `Customer` a status. Every new customer starts as a prospect:

> 🟢 **FOLLOW ALONG**

```rust
#[derive(Debug)]
struct Customer {
    id: u32,
    name: String,
    email: String,
    phone: String,
    status: CustomerStatus,
}

impl Customer {
    fn new(id: u32, name: String, email: String, phone: String) -> Self {
        Self {
            id,
            name,
            email,
            phone,
            status: CustomerStatus::Prospect,
        }
    }

    fn summary(&self) -> String {
        format!(
            "#{} {} <{}> {} [{}]",
            self.id,
            self.name,
            self.email,
            self.phone,
            self.status.label()
        )
    }

    // has_phone and update_email unchanged
}
```

`new` keeps its signature, so nothing that calls it changes. Run `cargo test`:

```text
---- tests::summary_includes_all_fields stdout ----

thread 'tests::summary_includes_all_fields' (593739) panicked at src/main.rs:481:9:
assertion `left == right` failed
  left: "#1 Ada Lovelace <ada@example.com> 555-0100 [prospect]"
 right: "#1 Ada Lovelace <ada@example.com> 555-0100"
```

(The number in brackets after the test name is a thread id, and your line number will differ.)
This failure is **correct**: the summary format changed on purpose, and the test from Lab 05 is
doing its job by noticing. Update the expected string in the test to end with ` [prospect]`.

### The `status` command

Add the variant to `Command`:

```rust
    Search { term: &'a str },
    Status { id: u32, status: CustomerStatus },
    Unknown(&'a str),
```

Run `cargo check` before going further. You'll get E0004 for the `match command` in `main`, the
same list-of-places behaviour as Step 5. Now teach the parser, just above the `(other, _)` arm:

> 🟢 **FOLLOW ALONG**

```rust
        ("status", [id, status]) => match (id.parse::<u32>(), CustomerStatus::parse(status)) {
            (Ok(id), Some(status)) => Command::Status { id, status },
            _ => usage("status <id> <prospect|active|churned>"),
        },
        ("status", _) => usage("status <id> <prospect|active|churned>"),
```

Two things can go wrong (the id isn't a number, the status isn't a status), so we compute both
and match on the **pair**: `(Ok(id), Some(status))` is the only arm where everything worked. The
names `id` and `status` inside the arm are new bindings that shadow the `&str` arguments of the
same names. Inside the arm they're a `u32` and a `CustomerStatus`.

And handle it in `main`, just above `Command::Unknown(name)`:

> 🟢 **FOLLOW ALONG**

```rust
            Command::Status { id, status } => match store.find_mut(id) {
                Some(customer) => {
                    customer.status = status;
                    println!("Customer #{id} is now {}.", status.label());
                }
                None => println!("No customer with id {id}."),
            },
```

`customer.status = status;` copies the status in (it's `Copy`), so we can still use `status` on
the next line.

Finally, add the command to `print_help`, after `delete`:

```rust
    println!("  status <id> <prospect|active|churned>");
    println!("                 change a customer's status");
```

---

## ▶️ Run It

```bash
cargo run
```

Add two customers, then play with statuses:

```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@example.com
Phone: 555-0199
Added customer #2
Note: #1 Ada Lovelace also uses example.com.
crm> status 1 active
crm> status 2 churned
crm> status 2 vip
crm> status 9 active
crm> list
crm> quit
```

## ✅ Expected Result

```text
crm> status 1 active
Customer #1 is now active.
crm> status 2 churned
Customer #2 is now churned.
crm> status 2 vip
Usage: status <id> <prospect|active|churned>
crm> status 9 active
No customer with id 9.
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100 [active]
#2 Grace Hopper <grace@example.com> 555-0199 [churned]
Page 1 of 1
crm> quit
Goodbye! (7 commands this session)
```

`cargo test` passes, and `cargo clippy` shows no new warnings.

## 🧠 Understand It

### Two steps instead of one

Before this lab, each arm of `main` did three jobs: recognise the command, check its arguments,
and run it. Now the jobs are split:

1. `parse_command` turns **text** into a **`Command`**. It's the only code that knows about
   spelling, argument counts, `"Usage: …"` messages, or that `exit` is an alias for `quit`.
2. `main` turns a **`Command`** into **behaviour**. It never sees a string it has to interpret.

Each half can be tested on its own (your parser tests in Your Turn 1 don't need a store or a
terminal). And in Lab 13 they'll literally live in different files: `cli/parser.rs` and
`cli/commands.rs`.

### Illegal states, revisited

Look at what can't happen any more:

- `Command::Show` without an id, or with a non-numeric id.
- `Command::List { page: 0 }` (the parser only produces pages from `1..`).
- A customer whose status is both active and churned, or "actve".
- A new command that `main` forgets to handle.

None of these are checked at runtime anywhere. They're ruled out by the **types**. That's the
payoff of "make illegal states unrepresentable": fewer `if`s, fewer tests, fewer bugs.

### Why `Command<'a>` borrows

`Search { term: &'a str }` points into the line the user typed. That's the same zero-copy idea as
Lab 09–10, and the same rule applies: a `Command` can't outlive the `input` `String` it was parsed
from. In our loop that's never a problem. `input` is created at the top of each iteration and the
command is used and gone before the next one. The Experiment section shows what happens if you
break that.

### Enums and `match` are a pair

An enum is only as useful as the code that consumes it, and `match` is how you consume it.
Exhaustive matching is the reason enums in Rust feel so much safer than string constants or
integer codes: the set of variants is closed, so the compiler can check that you handled all of
them, every time, in every place.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: outliving the input.** Right after the `let Some(command) = ... else { ... };`
> statement, add `input.clear();`. Predict the error before you run `cargo check`.

```text
error[E0502]: cannot borrow `input` as mutable because it is also borrowed as immutable
   --> src/main.rs:302:9
    |
299 |         let Some(command) = parse_command(&input) else {
    |                                           ------ immutable borrow occurs here
...
302 |         input.clear();
    |         ^^^^^^^^^^^^^ mutable borrow occurs here
303 |
304 |         match command {
    |               ------- immutable borrow later used here
```

Who owns the text? `input`. Is `command` a borrow? Yes: `parse_command(&input)` returns a
`Command<'_>` tied to `input`, and it's used later by `match command`. `clear()` needs `&mut input`
while the shared borrow is still alive. That's aliasing XOR mutation from Lab 07. The signature
`fn parse_command(input: &str) -> Option<Command<'_>>` is what told the compiler the command
borrows the input. Remove the line.

> 🟡 **EXPERIMENT 2: how many places?** Add a variant `Lead,` to `CustomerStatus`. Before you run
> `cargo check`, write down every place you think will fail. Then compare.

You should get exactly one E0004, in `label`:

```text
error[E0004]: non-exhaustive patterns: `&CustomerStatus::Lead` not covered
  --> src/main.rs:27:15
   |
27 |         match self {
   |               ^^^^ pattern `&CustomerStatus::Lead` not covered
```

Why not `parse` (it has a wildcard over strings, so it compiles, but now nobody can *type*
`lead`)? Why not the `status` command? Answer for yourself, then remove `Lead`. If you've done
Your Turn 3, try again afterwards: does the count change?

> 🟡 **EXPERIMENT 3: how big is a `Command`?** Add this test and run `cargo test -- --nocapture size`:
>
> ```rust
>     #[test]
>     fn size_of_things() {
>         println!("Command:        {} bytes", std::mem::size_of::<Command>());
>         println!("CustomerStatus: {} bytes", std::mem::size_of::<CustomerStatus>());
>         println!("Option<&Customer>: {} bytes", std::mem::size_of::<Option<&Customer>>());
>         println!("&Customer:      {} bytes", std::mem::size_of::<&Customer>());
>     }
> ```
>
> Which variant decides the size of `Command`? Why is `CustomerStatus` a single byte? Why is
> `Option<&Customer>` the **same** size as `&Customer`? (Hint: a reference can never be null, so
> Rust uses the all-zero bit pattern to mean `None`. Keep that in mind for Lab 12.) Delete the
> test when you're done.

## 👩🏽‍💻 Your Turn

Three tasks. None of their code appears above.

### Your Turn 1 — Parser tests

> 🔵 **YOUR TURN**: the parser is now a pure function from `&str` to `Option<Command>`, which
> makes it easy to test. Write tests for it.

- [ ] `help`, `version`, `exit` and `quit` (with extra spaces and a trailing `\n`) parse to the
      right unit variants; an empty line parses to `None`
- [ ] `list` parses to `List { page: 1 }`; `list 3` to `List { page: 3 }`
- [ ] Each of these produces `Some(Command::Invalid(_))`: `list 0`, `list two`, `show`,
      `show abc`, `status 1 vip`, `status x active`. Use **one** test with a loop over an array
      of inputs, and `matches!`. Make the assertion message say which input failed
- [ ] `status 2 ACTIVE` parses to `Status { id: 2, status: CustomerStatus::Active }`
- [ ] `delte 1` parses to `Unknown("delte")`
- [ ] Use `assert_eq!` wherever you compare whole commands (that's what `PartialEq` is for)

### Your Turn 2 — `count` by status

> 🔵 **YOUR TURN**: make `count` show the breakdown.

```text
crm> count
2 customers (0 prospect, 1 active, 1 churned)
```

- [ ] Add `fn count_by_status(&self, status: CustomerStatus) -> usize` to `CustomerStore`
- [ ] `count` prints `<n> customer(s) (<p> prospect, <a> active, <c> churned)`, using
      `customer` for exactly 1 and `customers` otherwise (`0 customers (0 prospect, 0 active, 0 churned)`)
- [ ] A test that adds customers, changes one's status through `find_mut`, and checks all three counts
- [ ] Think: why does `count_by_status` take `CustomerStatus` and not `&CustomerStatus`?

### Your Turn 3 — Status rules with a tuple match

> 🔵 **YOUR TURN**: not every status change makes sense. Change the `Status` arm in `main` so
> that it follows these rules:

```text
crm> status 1 active
Customer #1 is now active.
crm> status 1 active
Customer #1 is already active.
crm> status 2 churned
Customer #2 is now churned.
crm> status 2 prospect
A churned customer can't go back to prospect. Use 'active' to win them back.
```

- [ ] Same status as now → `Customer #<id> is already <status>.` and nothing changes
- [ ] Churned → prospect is refused with exactly the message above; nothing changes
- [ ] Every other change is applied and prints `Customer #<id> is now <status>.`
- [ ] Unknown id still prints `No customer with id <id>.`
- [ ] Use **one** `match` on the tuple `(current_status, new_status)`, with at least one match
      guard. No `if`/`else` chains for the rules
- [ ] `cargo clippy` is clean

(Lab 12 keeps these rules when it moves the code into an `execute` function, so finish this one.)

## 💡 Hint

> 💡 **HINT**: for Your Turn 1, a test can compare `parse_command("list")` with
> `Some(Command::List { page: 1 })` directly, because both `Option` and `Command` implement
> `PartialEq`. For the invalid inputs, `matches!(value, Some(Command::Invalid(_)))` ignores the
> exact message.

<details><summary>Hint 2: Your Turn 2</summary>

Loop over `&self.customers` with a counter, comparing `customer.status == status`. `==` works
because `CustomerStatus` derives `PartialEq`. For the noun, `if n == 1 { "customer" } else { "customers" }`
is an *expression*: you can put it on the right of a `let`.

</details>

<details><summary>Hint 3: Your Turn 3</summary>

Inside `Some(customer) => ...`, match on `(customer.status, status)`. Both are `Copy`, so building
the tuple copies them and doesn't borrow `customer`, which means you can still assign
`customer.status = new` inside an arm. Arm order matters: put the "same status" arm (pattern
`(current, new)` with guard `if current == new`) first, then the specific
`(CustomerStatus::Churned, CustomerStatus::Prospect)` arm, then a catch-all `(_, new)`. Is a
catch-all OK here? It's matching on a *tuple of statuses*, and it means "every other
combination" on purpose. Think about whether adding a variant would still be caught somewhere.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. What does "make illegal states unrepresentable" mean? Give one example from the CRM where an
   enum replaced something that could hold invalid values.
2. What's the difference between what a struct expresses and what an enum expresses?
3. Why does `Command` need a lifetime parameter? Which variant needs it?
4. You add a variant to `Command`. Which code does the compiler force you to update, and which
   code can you forget without any error?
5. Why is a `_ =>` arm risky when matching on your own enum, and when is a wildcard fine?
6. When would you use `let ... else` instead of `if let`?
7. What does `page @ 1..` do that `1..` alone doesn't?
8. Why can `CustomerStatus` be `Copy` but `Command` can't?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo test
```

## Git Commit

```bash
git add .
git commit -m "Add customer status"
git tag lab-11
git push && git push --tags
```

You committed the `Command` refactor separately in Step 5, so `git log --oneline` shows two
steps, and `git diff lab-10 lab-11 -- src/main.rs` shows how much of `main` turned from string
handling into plain, typed `match` arms.

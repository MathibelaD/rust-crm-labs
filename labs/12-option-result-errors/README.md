# Lab 12 — Option, Result & Error Handling ♻️ 🧪

> **Phase:** 3 — Modelling the Domain · **Builds on:** Lab 11 · **Time:** ~5–6 hours
> **Your repo before this lab:** tag `lab-11` · **After:** tag `lab-12`

> This lab assumes you completed **Your Turns 2 and 3 in Lab 11** (`count_by_status` and the
> status rules). If you skipped them, copy them from
> [Lab 11's solutions.md](../11-enums-and-pattern-matching/solutions.md) first.

## 🎯 Goal

Make invalid data impossible to store and make every failure a value instead of a crash. You'll
add a validated `Email` type, turn `phone: String` into `phone: Option<String>`, and give the CRM
a real error type, `CrmError`, that every command returns and the main loop prints.

## 🧠 What You'll Learn

- `Option<T>` as **"the null you can't forget"**, and how to get values out of it
- `Result<T, E>` as **errors as values**, and why that beats exceptions you can't see
- `panic!` vs `Result`, and why `unwrap()` in application code is a **TODO**, not a solution
- Option and Result **combinators** (`map`, `and_then`, `unwrap_or`, `ok_or`, `map_err`,
  `filter`, `as_deref`) on real CRM code
- The `?` operator: exactly what it expands to, including the hidden `From` conversion
- Custom error enums with `Display` and `std::error::Error`, and `impl From<A> for B`
- The **newtype** pattern and the principle **"parse, don't validate"**
- Writing tests for the **error** cases, not just the happy path

## 🔨 What We're Building

Right now the CRM trusts everything it's given:

```text
crm> add
Name:
Email: not an email
Phone:
Added customer #1
crm> list
#1  <not an email>  [prospect]
```

A blank name, an "email" with no `@`, and a phone of `""` that the summary prints as an extra
space. By the end of this lab:

```text
crm> add
Name:
Error: name cannot be empty
crm> add
Name: Grace Hopper
Email: grace@example
Error: 'grace@example' is not a valid email address
crm> show 9
Error: no customer with id 9
crm> frobnicate
Error: unknown command 'frobnicate' (type 'help' for a list of commands)
```

Every one of those is a **value** of type `CrmError`, returned by a function, printed by the main
loop, and covered by a test. Nothing panics. This error type grows into the HTTP API's error
responses in Lab 28.

---

## Step 1 — `Option`: the null you can't forget

You've used `Option` since Lab 05 (`store.find(id)` returns one). Time to understand it properly.

In JavaScript, any value might be `null` or `undefined`, and the type system (even TypeScript's,
unless you're very strict) lets you forget to check. Tony Hoare, who invented null references,
called them his "billion-dollar mistake".

Rust has no null. When a value might be absent, the **type** says so:

```rust
enum Option<T> {
    None,
    Some(T),
}
```

`Option<&Customer>` is not "a `&Customer` that might be null". It's a **different type** from
`&Customer`, and you can't use one where the other is expected. The compiler makes you deal with
`None` before you get to the `Customer`.

> 🟡 **EXPERIMENT**: predict first. In `main`, temporarily change the `Show` arm to:
>
> ```rust
>             Command::Show { id } => {
>                 let customer = store.find(id);
>                 println!("{}", customer.name);
>             }
> ```
>
> Run `cargo check`.

```text
error[E0609]: no field `name` on type `Option<&Customer>`
   --> src/main.rs:347:41
    |
347 |                 println!("{}", customer.name);
    |                                         ^^^^ unknown field
    |
help: one of the expressions' fields has a field of the same name
    |
347 |                 println!("{}", customer.unwrap().name);
    |                                         +++++++++
```

**Read the error.** `customer` is an `Option<&Customer>`, a box that may or may not hold a
reference. Boxes don't have a `name`. That's the "null you can't forget": the check is not
optional, because the type won't let you skip it.

Look at the compiler's suggestion: `.unwrap()`. It compiles. It also **crashes the CRM** the first
time someone types `show 99`. Keep that in mind for Step 2. Undo the change.

### Ways to get a value out of an `Option`

You already know three:

```rust
match store.find(id) {                    // 1. handle both cases
    Some(customer) => println!("{}", customer.summary()),
    None => println!("No customer with id {id}."),
}

if let Some(customer) = store.find(id) {  // 2. only care about Some
    println!("{}", customer.summary());
}

let Some(customer) = store.find(id) else { // 3. bail out on None
    return;
};
```

The fourth is **combinators**: methods on `Option` that transform it without unpacking it. You've
even used one already, in the `Show` arm: `email_domain(&customer.email).unwrap_or("(none)")`.

| Combinator | What it does | CRM example |
|---|---|---|
| `map(f)` | `Some(x)` → `Some(f(x))`, `None` → `None` | `store.find(id).map(|c| c.summary())` → `Option<String>` |
| `and_then(f)` | like `map`, but `f` itself returns an `Option` (no `Some(Some(..))`) | `store.find(id).and_then(|c| email_domain(&c.email))` → the customer's domain, if both exist |
| `unwrap_or(v)` | the value, or a fallback | `email_domain(email).unwrap_or("(none)")` |
| `unwrap_or_default()` | the value, or the type's default (`""`, `0`, …) | `maybe_note.unwrap_or_default()` |
| `filter(pred)` | keep `Some(x)` only if `pred(&x)` is true | `Some(input).filter(|s| !s.is_empty())` |
| `as_deref()` | `&Option<String>` → `Option<&str>` | `customer.phone.as_deref()` |
| `is_some()` / `is_none()` | just ask | `customer.phone.is_some()` |
| `ok_or(err)` | `Option` → `Result`: `None` becomes `Err(err)` | Step 7 |

The `|c| c.summary()` part is a **closure**, a small anonymous function (like `c => c.summary()`
in JS). You've written a few in `find` and `position` calls since Lab 07; Lab 17 covers them in
depth.

How to choose: if both cases do real work, `match`. If you're turning an `Option` into another
`Option` or a value, a combinator usually reads best. If it gets clever, go back to `match`.
Readable beats short.

---

## Step 2 — `Result`: errors as values

`Option` says "there might be nothing". `Result` says "this might have **failed**, and here's why":

```rust
enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

You met it in Lab 07: `"42".parse::<u32>()` returns `Result<u32, ParseIntError>`.

In JavaScript, a function that can fail usually `throw`s. The signature doesn't tell you, so you
find out at runtime, often in production. In Rust, a function that can fail returns `Result`, so
the possibility of failure is **in the signature**, and the caller has to do something with it.
(Ignoring a `Result` gives a warning: it's marked `#[must_use]`.)

### `panic!` vs `Result`

Rust has two ways to fail:

- **`panic!`** stops the current thread (in our CRM, the whole program). It's for **bugs**:
  situations that "can't happen" if the code is correct. You don't handle panics; you fix the code.
- **`Result`** is for things that **can** happen in a correct program: the user typed `abc` as an
  id, the email has no `@`, the customer doesn't exist. You handle these, usually by telling the
  user.

`unwrap()` converts the second kind into the first: "if this is `Err`/`None`, panic".

> 🟡 **EXPERIMENT**: see what that means for a user. In `parse_command`, temporarily replace the
> `("show", args)` arm with:
>
> ```rust
>         ("show", [id]) => Command::Show {
>             id: id.parse().unwrap(),
>         },
> ```
>
> Run the CRM, add a customer, then type `show 1`, then `show one`, then `list`.

```text
crm> show 1
#1 Ada <ada@example.com> 555-0100 [prospect]
  Domain:   example.com
  Initials: A
crm> show one

thread 'main' (445980) panicked at src/main.rs:206:28:
called `Result::unwrap()` on an `Err` value: ParseIntError { kind: InvalidDigit }
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

(Your thread id and line number will differ.) The `list` never runs. The CRM is gone, and so is
every customer you'd entered, because they only lived in memory. One typo, all data lost. Undo
the change.

That's why this course treats `unwrap()` in application code as a **TODO**: a marker that says
"I haven't decided what should happen when this fails". It's useful while you're sketching. It's
a bug once a user can reach it.

There are two places `unwrap` (and its sibling `expect("message")`) **are** fine:

- **Tests.** If the value is missing, the test *should* fail, and a panic is how a test fails.
- **Real invariants.** When the code around it *guarantees* the value is there, a panic would
  mean your own code is wrong, which is exactly what panics are for. Use `expect` with a message
  that states the invariant. You'll write one in Your Turn 4.

---

## Step 3 — A type for "why the input was rejected"

When validation fails, the caller needs to know **what** was wrong. A `String` message would
work, but then code can't tell the cases apart. An enum can:

> 🟢 **FOLLOW ALONG**: add this near the top of `src/main.rs`, and `use std::fmt;` next to your
> other `use` line.

```rust
use std::fmt;

/// Why a piece of user input was rejected.
#[derive(Debug, PartialEq)]
enum ValidationError {
    EmptyName,
    InvalidEmail(String),
    InvalidPhone(String),
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ValidationError::EmptyName => write!(f, "name cannot be empty"),
            ValidationError::InvalidEmail(input) => {
                write!(f, "'{input}' is not a valid email address")
            }
            ValidationError::InvalidPhone(input) => {
                write!(f, "'{input}' is not a valid phone number")
            }
        }
    }
}

impl std::error::Error for ValidationError {}
```

New syntax: `impl Trait for Type`. A **trait** is a set of methods a type promises to provide
(roughly an interface; Lab 15 covers traits fully). Two standard ones matter here:

- **`fmt::Display`** is what `{}` in `println!`/`format!` uses. Implementing it means
  `println!("{e}")` prints a sentence for humans. (`#[derive(Debug)]` gives you `{:?}`, which is
  for programmers.) `write!(f, ...)` is `format!` that writes into the formatter instead of
  making a new `String`.
- **`std::error::Error`** marks the type as a proper error. It requires `Debug` and `Display`,
  which we have, so the `impl` body is empty. It lets our errors work with the wider ecosystem
  (`Box<dyn Error>`, `anyhow` in Lab 22).

Messages are lowercase with no trailing full stop. That's the Rust convention for error
messages, because they often get embedded in longer ones (`"could not add customer: name cannot be empty"`).

`cargo check` will warn that the variants are never constructed. They will be.

---

## Step 4 — `Email`: parse, don't validate

Here's the problem with a `String` email: even if `add` checks it, nothing stops some other code
(an `update`, a future import, a test) from storing an unchecked one. Every function that
receives an email has to wonder "has this been validated?", and the honest answer is "probably".

The fix is a **newtype**: a struct with one field, whose only job is to give a value a new type.

> 🟢 **FOLLOW ALONG**

```rust
/// An email address that has passed validation. Always trimmed and lowercase.
#[derive(Debug, Clone, PartialEq)]
struct Email(String);

impl Email {
    fn parse(input: &str) -> Result<Email, ValidationError> {
        let candidate = input.trim().to_lowercase();

        let valid = match candidate.split_once('@') {
            Some((local, domain)) => {
                !local.is_empty()
                    && !domain.contains('@')
                    && domain.contains('.')
                    && !candidate.contains(char::is_whitespace)
            }
            None => false,
        };

        if valid {
            Ok(Email(candidate))
        } else {
            Err(ValidationError::InvalidEmail(input.trim().to_string()))
        }
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}
```

`struct Email(String);` is a **tuple struct**: like a struct, but its field has no name, only a
position, accessed as `self.0`.

The rules: trimmed, lowercased, exactly one `@` (`split_once` splits at the first one; then the
domain must not contain another), a non-empty part before it, a `.` in the domain, no whitespace
anywhere. `char::is_whitespace` is a function passed by name to `contains`, which accepts "a
character, or a function that decides".

This is the principle **"parse, don't validate"**:

- **Validating** checks a value and throws the knowledge away: `fn is_valid_email(s: &str) -> bool`
  returns `true`, and you're still holding a plain `&str`. Everyone downstream has to trust that
  someone, somewhere, called the check.
- **Parsing** checks a value and **keeps the proof in the type**: `Email::parse` returns an
  `Email`, and an `Email` can only come from `parse`. A function that takes `email: Email` never
  needs to re-check anything.

Because `Email::parse` lowercases, two emails that differ only in case are now **equal**. That's
why the `normalize` command is about to become obsolete.

> **One honest caveat.** In a single-file program, `main` can still write `Email(some_string)`
> directly and skip `parse`, because the field is only private *outside the module*, and right
> now everything is one module. Lab 13 closes that hole. Until then, `Email::parse` is the only
> way in by convention.

`as_str` lends out the inside as a `&str`, for printing and searching. It doesn't hand out a
`&mut String`, so nobody can change an `Email` after it's been parsed.

### Use it, and let the compiler find every place

Change `Customer`'s field to `email: Email`, and update the signatures that take an email:

```rust
    email: Email,                                        // in struct Customer
fn new(id: u32, name: String, email: Email, phone: String) -> Self
fn update_email(&mut self, email: Email)
fn add(&mut self, name: String, email: Email, phone: String) -> u32
fn find_by_email(&self, email: &Email) -> Option<&Customer>
fn email_exists(&self, email: &Email) -> bool
```

In the `Add` arm of `main`, parse the email the user types. For now, an invalid email prints an
error and skips the rest of the command (Step 10 replaces this with something better):

```rust
                let email = match Email::parse(&prompt("Email: ")) {
                    Ok(email) => email,
                    Err(e) => {
                        println!("Error: {e}");
                        continue;
                    }
                };
```

`println!("Error: {e}")` uses the `Display` impl from Step 3. Now run `cargo check`:

```text
error[E0277]: `Email` doesn't implement `std::fmt::Display`
   --> src/main.rs:114:13
    |
114 |             self.email,
    |             ^^^^^^^^^^ `Email` cannot be formatted with the default formatter

error[E0599]: no method named `to_lowercase` found for struct `Email` in the current scope
   --> src/main.rs:173:35
    |
173 |                 || customer.email.to_lowercase().contains(&needle)
    |                                   ^^^^^^^^^^^^ method not found in `Email`
    |
help: one of the expressions' fields has a method of the same name
    |
173 |                 || customer.email.0.to_lowercase().contains(&needle)
    |                                   ++

error[E0308]: mismatched types
   --> src/main.rs:184:43
    |
184 |             if let Some(d) = email_domain(&customer.email)
    |                              ------------ ^^^^^^^^^^^^^^^ expected `&str`, found `&Email`
...
error[E0308]: mismatched types
   --> src/main.rs:498:47
    |
498 |                         customer.update_email(email);
    |                                  ------------ ^^^^^ expected `Email`, found `String`
    |
help: try wrapping the expression in `Email`
    |
498 |                         customer.update_email(Email(email));
    |                                               ++++++     +
...
error: could not compile `rust-crm` (bin "rust-crm") due to 10 previous errors
```

Ten errors: every place that treated an email as text. This is the compiler doing what it did
with `Command` in Lab 11, but for a **type change** instead of a new variant.

**Don't take two of its suggestions.** `customer.email.0.to_lowercase()` reaches inside the
newtype, and `Email(email)` builds one *without validation*. Both compile, and both defeat the
point of `Email`. (The compiler is suggesting what makes the types line up, not what's right for
your design.) Fix each error properly:

| Where | Fix |
|---|---|
| `summary` (`self.email`) | `self.email.as_str()` |
| `search` (`customer.email.to_lowercase()`) | `customer.email.as_str()`: it's already lowercase |
| `find_by_email` (`c.email == email`) | `c.email == *email`: compare an `Email` with an `Email` |
| `first_by_domain`, `Show` arm, colleague note in `Add` (`email_domain(&...)`) | `email_domain(customer.email.as_str())` / `email_domain(email.as_str())` |
| `Add` arm's duplicate message (`{email}`) | `email.as_str()` |
| `Delete` arm (`display_name(&customer.name, &customer.email)`) | `customer.email.as_str()` |
| `Update` arm (`customer.update_email(email)`) | parse it: see below |
| `normalize_emails` (`customer.email.to_lowercase()`) | delete the method: see below |

For `Update`, parse the new email the same way as in `Add`:

```rust
                    let input = prompt("Email (blank to keep): ");
                    if !input.is_empty() {
                        match Email::parse(&input) {
                            Ok(email) => customer.update_email(email),
                            Err(e) => {
                                println!("Error: {e}");
                                continue;
                            }
                        }
                    }
```

### The type made `normalize` obsolete

`normalize` lowercased every stored email. But every `Email` is lowercase by construction, so
there's nothing left to normalise. Delete `normalize_emails` from `CustomerStore`, and run
`cargo check`. It points at the `Normalize` arm in `main`. Delete the `Normalize` **variant** from
`Command`, and it points at the rest:

```text
error[E0599]: no variant, associated function, or constant named `Normalize` found for enum `Command<'a>` in the current scope
   --> src/main.rs:263:38
    |
263 |         ("normalize", _) => Command::Normalize,
...
error[E0599]: no variant, associated function, or constant named `Normalize` found for enum `Command<'a>` in the current scope
   --> src/main.rs:510:22
    |
510 |             Command::Normalize => {
```

Delete the parser arm, the `main` arm, and the `normalize` line in `print_help`. A feature
removed by a type, with the compiler checking you got every piece.

### Fix the tests

`cargo test` now fails where tests pass `String::from("ada@example.com")` as an email. Add a
helper at the top of `mod tests`:

```rust
    fn email(s: &str) -> Email {
        Email::parse(s).unwrap()
    }
```

and replace each email `String::from("...")` with `email("...")` (in `store_with` it's
`email(&format!("c{i}@example.com"))`; in the `email_exists` test it's
`store.email_exists(&email("ada@example.com"))`). The `unwrap` here is the test kind: if a
hard-coded email in a test is invalid, the test should blow up. Then add two tests of your own:

> 🟢 **FOLLOW ALONG**

```rust
    #[test]
    fn email_is_trimmed_and_lowercased() {
        assert_eq!(email("  Ada@Example.COM ").as_str(), "ada@example.com");
    }

    #[test]
    fn email_without_at_is_rejected() {
        assert_eq!(
            Email::parse("ada.example.com"),
            Err(ValidationError::InvalidEmail(String::from("ada.example.com")))
        );
    }
```

`assert_eq!` on a `Result` works because `Email` and `ValidationError` both derive `PartialEq`.

`cargo test` passes. Commit:

```bash
git add .
git commit -m "Add validated Email type"
```

---

## Step 5 — `phone: Option<String>`: `""` was lying

Since Lab 04, a customer with no phone has `phone: ""`. That empty string pretends to be a phone
number:

- `summary` prints it, so you get `#2 Grace Hopper <grace@example.com>  [prospect]`, with two
  spaces where a phone number "is".
- `has_phone` has to know that `""` means "none". What about `"   "`? It's non-empty, so
  `has_phone` says yes.
- Every new function that reads `phone` has to remember the convention, and the compiler can't
  remind it.

"No phone" is not a kind of phone number. It's the **absence** of one, and Rust has a type for
that. Change the field and the two signatures:

```rust
    phone: Option<String>,                                                // in struct Customer
fn new(id: u32, name: String, email: Email, phone: Option<String>) -> Self
fn add(&mut self, name: String, email: Email, phone: Option<String>) -> u32
```

`cargo check`:

```text
error[E0277]: `Option<String>` doesn't implement `std::fmt::Display`
   --> src/main.rs:115:13
    |
115 |             self.phone,
    |             ^^^^^^^^^^ `Option<String>` cannot be formatted with the default formatter

error[E0599]: no method named `is_empty` found for enum `Option<T>` in the current scope
   --> src/main.rs:121:21
    |
121 |         !self.phone.is_empty()
    |                     ^^^^^^^^ method not found in `Option<String>`
    |
help: consider using `Option::expect` to unwrap the `String` value, panicking if the value is an `Option::None`
    |
121 |         !self.phone.expect("REASON").is_empty()
    |                    +++++++++++++++++

error[E0308]: mismatched types
   --> src/main.rs:426:53
    |
426 |                     let id = store.add(name, email, phone);
    |                                    ---              ^^^^^ expected `Option<String>`, found `String`
    |
help: try wrapping the expression in `Some`
    |
426 |                     let id = store.add(name, email, Some(phone));
    |                                                     +++++     +

error[E0308]: mismatched types
   --> src/main.rs:493:42
    |
493 |                         customer.phone = phone;
    |                                          ^^^^^ expected `Option<String>`, found `String`
```

Four places. Again, look at what the compiler suggests and **don't** take it blindly:

- `self.phone.expect("REASON")` would panic for every customer without a phone.
- `Some(phone)` in `Add` would store `Some("")` when the user just presses Enter. The lie would
  survive the refactor, now wearing a `Some`.

The right fixes:

> 🟢 **FOLLOW ALONG**

```rust
    fn summary(&self) -> String {
        let phone = self
            .phone
            .as_deref()
            .map(|p| format!(" {p}"))
            .unwrap_or_default();
        format!(
            "#{} {} <{}>{} [{}]",
            self.id,
            self.name,
            self.email.as_str(),
            phone,
            self.status.label()
        )
    }

    fn has_phone(&self) -> bool {
        self.phone.is_some()
    }
```

Read the `phone` chain one step at a time:

1. `self.phone` is an `Option<String>`, owned by the customer. We only have `&self`, so we can't
   move it.
2. `.as_deref()` gives `Option<&str>`: a borrowed view, no move, no copy.
3. `.map(|p| format!(" {p}"))` turns `Some("555-0100")` into `Some(" 555-0100")` (with the space)
   and leaves `None` alone.
4. `.unwrap_or_default()` gives the string, or `""` for `None`.

So the format string has `<{}>{}` with no space between: a customer without a phone prints
`#2 Grace Hopper <grace@example.com> [prospect]`, with exactly one space.

In the `Add` arm, turn blank input into `None`:

```rust
                let phone = Some(prompt("Phone (optional): ")).filter(|p| !p.is_empty());
```

`Some(...)` wraps the typed text, and `filter` keeps it only if it's non-empty. (Your Turn 1
replaces this with real phone validation.) In the `Update` arm, the existing
`if !phone.is_empty()` check already guarantees a real value, so `customer.phone = Some(phone);`
is correct there.

Fix the tests: the sample customer's phone becomes `Some(String::from("555-0100"))`,
`c.phone = String::new()` becomes `c.phone = None`, and `String::new()` passed as a phone becomes
`None`. Add one test:

```rust
    #[test]
    fn summary_without_phone() {
        let mut c = ada(); // your sample-customer helper from Lab 05
        c.phone = None;
        assert_eq!(c.summary(), "#1 Ada Lovelace <ada@example.com> [prospect]");
    }
```

`cargo test` passes. Commit:

```bash
git add .
git commit -m "Make phone optional"
```

---

## Step 6 — One error type for the whole CRM: `CrmError`

So far an error is printed where it happens, then the code `continue`s. That spreads error
handling all over `main`, and it means nothing can be tested without reading the terminal. The
better shape: **functions return errors; one place prints them.**

That needs a type that can describe *every* way a command can fail:

> 🟢 **FOLLOW ALONG**: add this below `ValidationError`.

```rust
/// Everything that can go wrong while running a CRM command.
#[derive(Debug)]
enum CrmError {
    NotFound(u32),
    DuplicateEmail(String),
    Validation(ValidationError),
    UnknownCommand(String),
    Usage(&'static str),
}

impl fmt::Display for CrmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CrmError::NotFound(id) => write!(f, "no customer with id {id}"),
            CrmError::DuplicateEmail(email) => {
                write!(f, "a customer with email {email} already exists")
            }
            CrmError::Validation(e) => write!(f, "{e}"),
            CrmError::UnknownCommand(name) => {
                write!(f, "unknown command '{name}' (type 'help' for a list of commands)")
            }
            CrmError::Usage(usage) => write!(f, "usage: {usage}"),
        }
    }
}

impl std::error::Error for CrmError {}

impl From<ValidationError> for CrmError {
    fn from(e: ValidationError) -> Self {
        CrmError::Validation(e)
    }
}
```

Design notes:

- **`Validation(ValidationError)` wraps** the smaller error instead of copying its variants. A
  validation failure stays a `ValidationError` inside, so code (and tests) can still ask exactly
  which rule failed. `Display` just delegates to the inner message.
- **`Usage(&'static str)`**: usage strings are literals in our code (`"show <id>"`), so the
  variant borrows them for `'static` (Lab 10). No allocation.
- **No `PartialEq`.** We could derive it today, but in Lab 21 `CrmError` will wrap I/O errors,
  which can't be compared. Tests use `matches!` instead, which works either way.
- **`impl From<ValidationError> for CrmError`** says "a `ValidationError` can always be turned
  into a `CrmError`, like this". It's what makes `?` convert errors automatically (Step 7). Once
  you have `From`, you also get `.into()` for free: `let e: CrmError = ValidationError::EmptyName.into();`.

Names need validating too. Add:

```rust
/// A name must contain something other than whitespace. Returns it trimmed.
fn parse_name(input: &str) -> Result<String, ValidationError> {
    let name = input.trim();
    if name.is_empty() {
        Err(ValidationError::EmptyName)
    } else {
        Ok(name.to_string())
    }
}
```

It returns the **trimmed** name, parsed rather than merely checked, same idea as `Email::parse`.

---

## Step 7 — The `?` operator, exactly

You'll use `?` on almost every line from now on, so it's worth knowing precisely what it does.

```rust
let email = Email::parse(&input)?;
```

inside a function that returns `Result<_, CrmError>` means:

```rust
let email = match Email::parse(&input) {
    Ok(email) => email,
    Err(e) => return Err(From::from(e)),
};
```

Three things happen:

1. If it's `Ok`, unwrap the value and keep going.
2. If it's `Err`, **return early** from the enclosing function.
3. On the way out, convert the error with `From::from`. Here that's
   `<CrmError as From<ValidationError>>::from(e)`, the `impl` you just wrote. That's how a
   `ValidationError` from `Email::parse` comes out of a function that returns `CrmError`.

(The real expansion goes through a trait called `Try`, so that `?` also works on `Option` and
other types. The `match` above is exactly what it does for `Result`.)

On an `Option`, in a function that returns `Option`, `?` means "if `None`, return `None`". You
used that in Lab 11: `let name = words.next()?;`.

> 🟡 **EXPERIMENT**: predict, then verify each, once you've written `execute` in Step 10.
>
> 1. Delete the `impl From<ValidationError> for CrmError` block and run `cargo check`.
> 2. Put it back. In the `Show` arm, replace `.ok_or(CrmError::NotFound(id))?` with just `?`.
> 3. Undo. In the `Add` arm, write the `match` expansion by hand instead of `?`. Then change
>    `return Err(From::from(e))` to `return Err(e)`.

You'll find the output under 🧪 Experiment, with an explanation. Do it before you look.

### Moving between `Option` and `Result`

- `option.ok_or(err)` turns `None` into `Err(err)` and `Some(x)` into `Ok(x)`. Use it when
  "missing" is an error **for this caller**: `store.find(id).ok_or(CrmError::NotFound(id))?`.
  `find` itself still returns `Option`, because for `find`, "not there" is a normal answer.
- `result.map_err(f)` changes the error type: `id.parse().map_err(|_| CrmError::Usage(...))` turns
  a `ParseIntError` into our usage error.
- `result.ok()` goes the other way, `Result` → `Option`, throwing the error away. Your `parse_id`
  uses it.

---

## Step 8 — The parser returns errors

`Command::Unknown` and `Command::Invalid` were errors pretending to be commands. Now that we
have an error type, they can go. Remove both variants (and the `usage` helper), then rewrite
`parse_command`:

> 🟢 **FOLLOW ALONG**

```rust
const STATUS_USAGE: &str = "status <id> <prospect|active|churned>";

/// Turns one input line into a `Command`.
/// `Ok(None)` means a blank line; `Err` means the line made no sense.
fn parse_command(input: &str) -> Result<Option<Command<'_>>, CrmError> {
    let mut words = input.split_whitespace();
    let Some(name) = words.next() else {
        return Ok(None);
    };
    let args: Vec<&str> = words.collect();

    let command = match (name, args.as_slice()) {
        ("help", _) => Command::Help,
        ("version", _) => Command::Version,
        ("quit" | "exit", _) => Command::Quit,
        ("add", _) => Command::Add,
        ("count", _) => Command::Count,
        ("list", args) => Command::List {
            page: parse_page(args).ok_or(CrmError::Usage("list [page]"))?,
        },
        ("show", args) => Command::Show {
            id: parse_id(args).ok_or(CrmError::Usage("show <id>"))?,
        },
        ("update", args) => Command::Update {
            id: parse_id(args).ok_or(CrmError::Usage("update <id>"))?,
        },
        ("delete", args) => Command::Delete {
            id: parse_id(args).ok_or(CrmError::Usage("delete <id>"))?,
        },
        ("search", [term, ..]) => Command::Search { term },
        ("search", []) => return Err(CrmError::Usage("search <term>")),
        ("status", [id, status]) => Command::Status {
            id: id.parse().map_err(|_| CrmError::Usage(STATUS_USAGE))?,
            status: CustomerStatus::parse(status).ok_or(CrmError::Usage(STATUS_USAGE))?,
        },
        ("status", _) => return Err(CrmError::Usage(STATUS_USAGE)),
        (other, _) => return Err(CrmError::UnknownCommand(other.to_string())),
    };
    Ok(Some(command))
}
```

Look at the return type: `Result<Option<Command>, CrmError>`. Three outcomes, each with its own
meaning:

| Value | Meaning |
|---|---|
| `Ok(Some(command))` | a valid command |
| `Ok(None)` | a blank line: not an error, just nothing to do |
| `Err(error)` | the line made no sense, and here's why |

Nesting `Option` inside `Result` is normal Rust. Each layer answers one question.

The `status` arm shows both conversions from Step 7: `map_err` for the `Result` from `parse`, and
`ok_or` for the `Option` from `CustomerStatus::parse`. Compare it with Lab 11's version, which
built a tuple and matched it: same logic, fewer moving parts. The `?` inside a struct literal is
fine. It returns from `parse_command` if either field fails.

`UnknownCommand(other.to_string())` **owns** the command word. Why not borrow it like
`Command::Unknown(&'a str)` did? Because then `CrmError` would need a lifetime, and every
function returning `CrmError` would be tied to the input line. Errors travel far (to the main
loop, later to HTTP responses), so owned data is the right choice. That's the owned-vs-borrowed
rule from Lab 10.

---

## Step 9 — The store enforces its own rule

"No two customers share an email" is a rule about the **store**, so the store should enforce it.
Today the `Add` arm checks `email_exists` and then calls `add`. Anyone who calls `add` without
checking breaks the rule.

> 🟢 **FOLLOW ALONG**

```rust
    fn add(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
    ) -> Result<u32, CrmError> {
        if self.email_exists(&email) {
            return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
        }
        let id = self.next_id;
        self.customers.push(Customer::new(id, name, email, phone));
        self.next_id = next_id(id);
        Ok(id)
    }
```

Now it's impossible to add a duplicate, no matter who calls `add`. Callers that ignore the result
get an `unused_must_use` warning, and the ones in your tests that did `let id = store.add(...)`
now get a `Result` instead of a `u32`. Add `.unwrap()` to every `store.add(...)` call in `mod tests`.

---

## Step 10 — `execute`: commands return `Result`, the loop prints

Move the big `match command { ... }` out of `main` into its own function, which returns
`Result<(), CrmError>` so every arm can use `?`:

> 🟢 **FOLLOW ALONG**: add this above `fn main`.

```rust
/// Runs one command against the store. Printing happens here; errors are returned.
fn execute(store: &mut CustomerStore, command: Command) -> Result<(), CrmError> {
    match command {
        Command::Help => print_help(),
        Command::Version => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
        Command::Quit => {} // the loop in main handles Quit before calling execute
        Command::Add => {
            let name = parse_name(&prompt("Name: "))?;
            let email = Email::parse(&prompt("Email: "))?;
            let phone = Some(prompt("Phone (optional): ")).filter(|p| !p.is_empty());

            // Look before adding (Lab 10): the note is owned, so it holds no borrow of `store`.
            let mut note = None;
            if let Some(domain) = email_domain(email.as_str())
                && let Some(other) = store.first_by_domain(domain)
            {
                note = Some(format!(
                    "Note: #{} {} also uses {domain}.",
                    other.id, other.name
                ));
            }

            let id = store.add(name, email, phone)?;
            println!("Added customer #{id}");
            if let Some(note) = note {
                println!("{note}");
            }
        }
        Command::List { page } => {
            // unchanged from Lab 11
        }
        Command::Search { term } => {
            // unchanged from Lab 11
        }
        Command::Count => {
            // unchanged from Lab 11 (Your Turn 2)
        }
        Command::Show { id } => {
            let customer = store.find(id).ok_or(CrmError::NotFound(id))?;
            println!("{}", customer.summary());
            if !customer.has_phone() {
                println!("(no phone on file)");
            }
            let domain = email_domain(customer.email.as_str()).unwrap_or("(none)");
            println!("  Domain:   {domain}");
            println!("  Initials: {}", initials(&customer.name));
        }
        Command::Update { id } => {
            // Fail fast: don't ask questions about a customer that doesn't exist.
            store.find(id).ok_or(CrmError::NotFound(id))?;

            let input = prompt("Name (blank to keep): ");
            let name = if input.is_empty() {
                None
            } else {
                Some(parse_name(&input)?)
            };

            let input = prompt("Email (blank to keep): ");
            let email = if input.is_empty() {
                None
            } else {
                Some(Email::parse(&input)?)
            };

            let phone = Some(prompt("Phone (blank to keep): ")).filter(|p| !p.is_empty());

            // Check the rules first, with shared borrows only...
            if let Some(email) = &email
                && let Some(owner) = store.find_by_email(email)
                && owner.id != id
            {
                return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
            }

            // ...then take the one exclusive borrow and change everything.
            let customer = store.find_mut(id).ok_or(CrmError::NotFound(id))?;
            if let Some(name) = name {
                customer.name = name;
            }
            if let Some(email) = email {
                customer.update_email(email);
            }
            if phone.is_some() {
                customer.phone = phone;
            }
            println!("Updated customer #{id}");
        }
        Command::Delete { id } => {
            let customer = store.remove(id).ok_or(CrmError::NotFound(id))?;
            println!("Deleted customer #{} ({})", customer.id, customer.name);
        }
        Command::Status { id, status } => {
            let customer = store.find_mut(id).ok_or(CrmError::NotFound(id))?;
            match (customer.status, status) {
                // your three rules from Lab 11's Your Turn 3, unchanged
            }
        }
    }
    Ok(())
}
```

Copy the bodies marked "unchanged" from your current `main`. Then replace the loop body in
`main`, from `let Some(command) = ...` to the end of the loop:

> 🟢 **FOLLOW ALONG**

```rust
        let result = match parse_command(&input) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break count,
            Ok(Some(command)) => execute(&mut store, command),
            Err(e) => Err(e),
        };
        count += 1;

        if let Err(e) = result {
            println!("Error: {e}");
        }
    };
```

The `match` there is pattern matching through **two layers**: `Ok(Some(Command::Quit))` looks
inside the `Result`, then inside the `Option`, then checks the variant. Arms are tried in order,
so `Quit` is caught before the general `Ok(Some(command))` arm. Every error, from the parser or
from a command, ends up in `result` and is printed **once**, in **one** place.

Now walk through what changed in the arms, because each one shows a different tool:

- **`Add`**: three `?`s, three different error sources. `parse_name` and `Email::parse` return
  `ValidationError` (converted by `From`), `store.add` returns `CrmError` (no conversion
  needed). If the name is blank, the email prompt never appears: `?` returned already.
- **`Show`, `Delete`, `Status`**: `find(...)` returns `Option`, and `ok_or` says "for this
  command, missing means `NotFound`". One line replaces each `None => println!(...)` arm.
- **`Delete`**: `display_name` existed because a customer's name could be blank. `parse_name`
  makes that impossible now, so its fallback can never run. Delete `display_name` and its two
  tests. *Parse, don't validate*, again: once the type guarantees something, the code that
  defended against its absence becomes dead weight.
- **`Quit`** is an empty arm: `execute` has to be exhaustive, but `main` never sends it a `Quit`.
  A no-op is safer than `unreachable!()`, which would panic if that assumption ever broke.
- **`Update`** checks everything first and changes things last, so a bad email can't leave the
  customer half-updated. And the order of the borrows matters:

> 🟡 **EXPERIMENT**: in the `Update` arm, move the line
> `let customer = store.find_mut(id).ok_or(CrmError::NotFound(id))?;` up, **above** the
> duplicate-email check. Predict, then `cargo check`.

```text
error[E0502]: cannot borrow `*store` as immutable because it is also borrowed as mutable
   --> src/main.rs:511:38
    |
509 |             let customer = store.find_mut(id).ok_or(CrmError::NotFound(id))?;
    |                            ----- mutable borrow occurs here
510 |             if let Some(email) = &email
511 |                 && let Some(owner) = store.find_by_email(email)
    |                                      ^^^^^ immutable borrow occurs here
...
517 |                 customer.name = name;
    |                 ------------- mutable borrow later used here
```

The find-then-mutate problem from Lab 08. `customer` is an exclusive borrow of `store` that's
still needed later, so `store` can't be read in between. The fix is the order you started with:
**check with shared borrows, then mutate with one exclusive borrow.** Move the line back.

Run `cargo check`. You'll get one warning, `variant InvalidPhone is never constructed`. Your
Turn 1 constructs it.

---

## Step 11 — Testing the error cases

Happy-path tests prove the CRM works when everything goes right. **Error-case tests** prove it
fails *correctly*: the right error, nothing changed, no panic. They're often more valuable,
because error paths are the code that runs least often by hand.

First, fix what Step 8 broke. Tests that compared `parse_command(...)` with `Some(...)` now get a
`Result` and fail with E0369 (`==` can't compare a `Result` with an `Option`). Add a helper to
`mod tests` and use it in those `assert_eq!`s:

```rust
    /// Parses a line that is expected to be valid.
    fn parse(input: &str) -> Option<Command<'_>> {
        parse_command(input).expect("input should parse")
    }
```

In Lab 11's `parse_rejects_bad_arguments` test, `Some(Command::Invalid(_))` becomes
`Err(CrmError::Usage(_))`, and the `Unknown("delte")` test becomes a check for
`Err(CrmError::UnknownCommand(...))`.

Then add these three. They show the main techniques:

> 🟢 **FOLLOW ALONG**

```rust
    #[test]
    fn duplicate_email_is_rejected() {
        let mut store = CustomerStore::new();
        store.add(String::from("Ada"), email("ada@example.com"), None).unwrap();

        let result = store.add(String::from("Imposter"), email("ADA@example.com"), None);

        assert!(matches!(result, Err(CrmError::DuplicateEmail(e)) if e == "ada@example.com"));
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn unknown_ids_are_not_found() {
        let mut store = CustomerStore::new();
        for command in [
            Command::Show { id: 42 },
            Command::Update { id: 42 },
            Command::Delete { id: 42 },
            Command::Status {
                id: 42,
                status: CustomerStatus::Active,
            },
        ] {
            assert!(matches!(
                execute(&mut store, command),
                Err(CrmError::NotFound(42))
            ));
        }
    }

    #[test]
    fn validation_errors_convert_into_crm_errors() {
        let error: CrmError = ValidationError::EmptyName.into();
        assert!(matches!(
            error,
            CrmError::Validation(ValidationError::EmptyName)
        ));
        assert_eq!(error.to_string(), "name cannot be empty");
    }
```

- **`matches!` with a guard** (`if e == "ada@example.com"`) checks the variant *and* its data,
  without needing `PartialEq` on `CrmError`.
- **Check that nothing changed**: `store.len()` is still 1 after the failed add.
- **Test through `execute`**: because commands now *return* errors, you can test a whole
  command without a terminal. (`Update` is safe to test this way because it fails *before*
  prompting.)
- **`.to_string()`** comes free with `Display`, so you can test the user-facing message too.

`cargo test` passes.

---

## ▶️ Run It

```bash
cargo run
```

```text
crm> add
Name: Ada Lovelace
Email:   ADA@Example.com
Phone (optional): 555-0100
crm> add
Name: Grace Hopper
Email: grace@example
crm> add
Name:
crm> add
Name: Grace Hopper
Email: grace@EXAMPLE.com
Phone (optional):
crm> add
Name: Ada Again
Email: ada@example.com
Phone (optional):
crm> list
crm> show 2
crm> show 9
crm> show x
crm> status 2 vip
crm> frobnicate
crm> update 2
Name (blank to keep):
Email (blank to keep): ada@example.com
Phone (blank to keep):
crm> delete 1
crm> quit
```

## ✅ Expected Result

```text
crm> add
Name: Ada Lovelace
Email:   ADA@Example.com
Phone (optional): 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@example
Error: 'grace@example' is not a valid email address
crm> add
Name:
Error: name cannot be empty
crm> add
Name: Grace Hopper
Email: grace@EXAMPLE.com
Phone (optional):
Added customer #2
Note: #1 Ada Lovelace also uses example.com.
crm> add
Name: Ada Again
Email: ada@example.com
Phone (optional):
Error: a customer with email ada@example.com already exists
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100 [prospect]
#2 Grace Hopper <grace@example.com> [prospect]
Page 1 of 1
crm> show 2
#2 Grace Hopper <grace@example.com> [prospect]
(no phone on file)
  Domain:   example.com
  Initials: GH
crm> show 9
Error: no customer with id 9
crm> show x
Error: usage: show <id>
crm> status 2 vip
Error: usage: status <id> <prospect|active|churned>
crm> frobnicate
Error: unknown command 'frobnicate' (type 'help' for a list of commands)
crm> update 2
Name (blank to keep):
Email (blank to keep): ada@example.com
Phone (blank to keep):
Error: a customer with email ada@example.com already exists
crm> delete 1
Deleted customer #1 (Ada Lovelace)
crm> quit
Goodbye! (13 commands this session)
```

The email typed as `  ADA@Example.com ` is stored as `ada@example.com`. The domain in the
colleague note is now lowercase, because it comes from a parsed `Email`. `cargo test` passes;
`cargo clippy` only warns about `InvalidPhone` until you do Your Turn 1.

## 🧠 Understand It

### The mental models, side by side

| | Meaning | You must… | The compiler checks… |
|---|---|---|---|
| `T` | definitely a value | nothing | — |
| `Option<T>` | a value, or nothing, and nothing is **normal** | decide what "nothing" means here | you never use a `T` that might not be there |
| `Result<T, E>` | a value, or a reason it failed | decide what to do with the failure | you never use a `T` that failed to be produced |
| `panic!` | the program has a bug | fix the code | nothing: it happens at runtime |

### Where each error is created, converted and handled

```text
Email::parse ──Err(ValidationError)──┐
parse_name   ──Err(ValidationError)──┤ ? + From      ┌──────────────────┐
store.add    ──Err(CrmError)─────────┼──────────────▶│ execute → Result │──┐
find().ok_or ──Err(CrmError)─────────┘               └──────────────────┘  │
parse_command ──Err(CrmError)──────────────────────────────────────────────┤
                                                                           ▼
                                                main loop: println!("Error: {e}")
```

Errors are **created** where the knowledge is (only `Email::parse` knows the email rules),
**converted** at boundaries (`From`, `ok_or`, `map_err`), and **handled** in one place that knows
what to do with them (the main loop prints and carries on). In Lab 28 the same `CrmError` reaches
an HTTP handler instead, which turns `NotFound` into a 404 and `DuplicateEmail` into a 409. The
functions that *create* the errors won't change at all.

### Why `Email` is a struct and not a function

`fn is_valid_email(&str) -> bool` and `Email::parse` run the same checks. The difference is what
you hold afterwards. A `bool` evaporates; an `Email` carries the proof wherever it goes. Notice
what got simpler: `search` no longer lowercases emails, the `normalize` command and method are
gone, `find_by_email` compares values directly, and `display_name` disappeared thanks to
`parse_name`. Types that carry guarantees **delete** code.

### Why `Option<String>` beats `""`

With `""`, "no phone" was a *convention* every function had to know. With `Option<String>`, it's
a *type*, and the compiler makes every function that reads the phone handle `None`. The four
errors in Step 5 were the four places that had been silently relying on the convention.

## 🧪 Experiment

Here are the results of the three `?` experiments from Step 7, plus two more.

**1. Without `From`.** One error per `?` that needs a conversion:

```text
error[E0277]: `?` couldn't convert the error to `CrmError`
   --> src/main.rs:421:53
    |
415 | fn execute(store: &mut CustomerStore, command: Command) -> Result<(), CrmError> {
    |                                                            -------------------- expected `CrmError` because of this
...
421 |             let name = parse_name(&prompt("Name: "))?;
    |                        -----------------------------^ the trait `From<ValidationError>` is not implemented for `CrmError`
    |                        |
    |                        this can't be annotated with `?` because it has type `Result<_, ValidationError>`
    |
note: `CrmError` needs to implement `From<ValidationError>`
    = note: the question mark operation (`?`) implicitly performs a conversion on the error value using the `From` trait
```

The last note says it in plain words: `?` calls `From`.

**2. `?` on an `Option` in a `Result` function:**

```text
error[E0277]: the `?` operator can only be used on `Result`s, not `Option`s, in a function that returns `Result`
   --> src/main.rs:480:42
    |
480 |             let customer = store.find(id)?;
    |                                          ^ use `.ok_or(...)?` to provide an error compatible with `Result<(), CrmError>`
```

`?` can't invent an error out of `None`. You have to say which error "missing" means, and
`ok_or` is how.

**3. The hand-written expansion.** With `Err(e) => return Err(From::from(e)),` it compiles and
behaves exactly like `?`. With `Err(e) => return Err(e),`:

```text
error[E0308]: mismatched types
   --> src/main.rs:384:38
    |
384 |                 Err(e) => return Err(e),
    |                                  --- ^ expected `CrmError`, found `ValidationError`
```

That's the conversion `?` does for you, made visible.

> 🟡 **EXPERIMENT 4**: in `parse_command`, change `("search", []) => return Err(...)` to
> `("search", []) => Err(CrmError::Usage("search <term>"))?` and run the tests. It still
> works. Why? (What does `?` do with an `Err` it's given directly?) Which version do you find
> clearer? Put the original back.

> 🟡 **EXPERIMENT 5**: in the `Add` arm, type an invalid email for a customer whose *name* is
> also blank. Which error do you see, and why only one? What would you have to change to report
> both? (Lab 28 does exactly this for the HTTP API, collecting all field errors.)

## 👩🏽‍💻 Your Turn

Four tasks. None of their code appears above.

### Your Turn 1 — Validated phone numbers

> 🔵 **YOUR TURN**: write
>
> ```rust
> fn parse_phone(input: &str) -> Result<Option<String>, ValidationError>
> ```

The return type is the lesson: two independent questions, nested.

- [ ] Blank input (after trimming) → `Ok(None)`: no phone is fine
- [ ] A valid phone → `Ok(Some(trimmed))`
- [ ] Valid means: only digits, spaces and `+ - ( )`, and **at least 7 digits**
      (`555-0100` ✅, `+1 (555) 010-0100` ✅, `12345` ❌, `call me` ❌, `555-01x0` ❌)
- [ ] Anything else → `Err(ValidationError::InvalidPhone(trimmed_input))`
- [ ] `add` uses it with `?` (prompt stays `Phone (optional): `)
- [ ] `update` uses it with `?` too, where `Ok(None)` means "keep the current phone"
- [ ] Tests: blank, valid with surrounding spaces, and a loop over invalid inputs
- [ ] The `InvalidPhone is never constructed` warning is gone

### Your Turn 2 — A colleague note with combinators

> 🔵 **YOUR TURN**: the colleague-note code in the `Add` arm is an `if let` chain filling a
> `mut note`. Replace it with a function
>
> ```rust
> fn colleague_note(store: &CustomerStore, email: &Email) -> Option<String>
> ```

- [ ] Returns `Some("Note: #1 Ada Lovelace also uses example.com.")` when another customer
      has the same email domain, `None` otherwise
- [ ] The body uses **no** `match`, `if let` or `if`: only `?` and `Option` combinators
- [ ] The `Add` arm becomes `let note = colleague_note(store, &email);` (still computed
      **before** `store.add`. Why?)
- [ ] A test with one match and one non-match

### Your Turn 3 — The error-case test suite

> 🔵 **YOUR TURN**: cover every way the CRM can reject input.

- [ ] **Every email rule**, in one table-driven test: empty, no `@`, nothing before `@`, two
      `@`s, no `.` in the domain, whitespace inside. Each must return
      `Err(ValidationError::InvalidEmail(input))`, and the failure message must name the input
- [ ] `parse_name("   ")` is `Err(EmptyName)`, and `parse_name("  Ada ")` is `Ok("Ada")`
- [ ] Every malformed command returns the **right** usage error: `list 0`, `show`,
      `delete abc`, `status 1 vip` (match on the exact `Usage("...")` string for at least two)
- [ ] `DuplicateEmail` also fires for an `update` that tries to take another customer's email,
      but **not** when a customer re-enters their own (hint: you can't test `Update` through
      `execute`, because it prompts. Test the rule some other way, or explain why this one is
      checked by hand)
- [ ] `cargo test` passes with no warnings

### Your Turn 4 (stretch) — `Email::domain`

> 🔵 **YOUR TURN**: a parsed `Email` always has a domain, so asking for it shouldn't return an
> `Option`. Add `fn domain(&self) -> &str` to `Email`.

- [ ] Uses `split_once('@')`; the impossible `None` case documents the invariant (with
      `expect("...")` or `unreachable!("...")` and a message saying why it can't happen)
- [ ] `first_by_domain`, the `Show` arm and `colleague_note` use `email.domain()`; the
      `unwrap_or("(none)")` in `Show` disappears
- [ ] `email_domain` (and its tests) can then be deleted: nothing uses it
- [ ] A test for `domain()`
- [ ] You can explain why this `expect`/`unreachable!` is not a "TODO" in the sense of Step 2

## 💡 Hint

> 💡 **HINT**: for Your Turn 1, the order of checks gives you the nesting. Answer "is there a
> phone at all?" first (blank → return `Ok(None)` early), then "is it a valid one?".

<details><summary>Hint 2: Your Turn 1</summary>

`phone.chars().all(|c| c.is_ascii_digit() || matches!(c, ' ' | '+' | '-' | '(' | ')'))` checks
the characters. `phone.chars().filter(|c| c.is_ascii_digit()).count()` counts digits. In `update`,
`let phone = parse_phone(&prompt("Phone (blank to keep): "))?;` gives an `Option<String>`, and the
existing `if phone.is_some() { customer.phone = phone; }` does the rest.

</details>

<details><summary>Hint 3: Your Turn 2</summary>

Get the domain with `?` (`email_domain(email.as_str())?`, or `email.domain()` if you did Your Turn
4). Then `store.first_by_domain(domain)` gives an `Option<&Customer>`, and `.map(|other| format!(...))`
turns it into the `Option<String>` you return. The note must be built before `store.add` because
afterwards the new customer would be its own colleague. And because the `String` is owned, it
holds no borrow of `store` while `add` needs `&mut store`.

</details>

<details><summary>Hint 4: Your Turn 3, the update rule</summary>

The duplicate rule in `Update` uses `store.find_by_email(email)` and compares `owner.id != id`.
You can test that logic directly on the store: add two customers, and check what
`find_by_email` returns for each email. Or pull the rule into a small function
(`fn email_taken_by_other(store, email, id) -> bool`) and test that.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Why is `Option<&Customer>` safer than a nullable pointer? What does the compiler stop you doing?
2. Write out what `let email = Email::parse(&input)?;` expands to, inside a function returning
   `Result<(), CrmError>`. Where does the `From` conversion happen?
3. When is `unwrap()` acceptable, and when is it a bug waiting for a user?
4. What's the difference between validating and parsing? Name two pieces of code that
   disappeared because of `Email` or `parse_name`.
5. Why does `find` return `Option` while the `Show` command turns that into
   `Err(CrmError::NotFound)`?
6. `parse_command` returns `Result<Option<Command>, CrmError>`. What does each of the three
   possible outcomes mean?
7. Why does `CrmError::UnknownCommand` hold a `String` rather than a `&str`?
8. The compiler suggested `Email(email)` and `Some(phone)` as fixes. Why were both wrong?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo test
```

## Git Commit

```bash
git add .
git commit -m "Add CrmError and ? propagation"
git tag lab-12
git push && git push --tags
```

`git log --oneline lab-11..lab-12` shows the three steps: the `Email` type, the optional phone,
and the error type. `main.rs` is now well past 800 lines, about half of them tests. Hold that
thought for Lab 13.

# Lab 13 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't have to match line for
> line. If your tests pass and you can explain your choices, you're done.

---

## Step 4 mini-task — `model.rs` and `store.rs`

The tops of the two files, which is where the interesting decisions are:

```rust
// src/customers/model.rs
use super::Email;
use crate::errors::ValidationError;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CustomerStatus { Prospect, Active, Churned }

impl CustomerStatus {
    pub fn parse(s: &str) -> Option<CustomerStatus> { /* unchanged */ }
    pub fn label(&self) -> &'static str { /* unchanged */ }
}

#[derive(Debug)]
pub struct Customer {
    pub id: u32,
    pub name: String,
    pub email: Email,
    pub phone: Option<String>,
    pub status: CustomerStatus,
}

impl Customer {
    pub fn new(id: u32, name: String, email: Email, phone: Option<String>) -> Self { /* unchanged */ }
    pub fn summary(&self) -> String { /* unchanged */ }
    pub fn has_phone(&self) -> bool { /* unchanged */ }
    pub fn update_email(&mut self, email: Email) { /* unchanged */ }
}

pub fn parse_name(input: &str) -> Result<String, ValidationError> { /* unchanged */ }
pub fn parse_phone(input: &str) -> Result<Option<String>, ValidationError> { /* unchanged */ }
pub fn initials(name: &str) -> String { /* unchanged */ }
```

```rust
// src/customers/store.rs
use super::{Customer, CustomerStatus, Email};
use crate::errors::CrmError;

/// All customers, in memory. The fields are private: the store decides
/// how ids are handed out and that no two customers share an email.
pub struct CustomerStore {
    customers: Vec<Customer>,
    next_id: u32,
}

impl CustomerStore {
    pub fn new() -> Self { /* unchanged */ }
    pub fn add(&mut self, name: String, email: Email, phone: Option<String>) -> Result<u32, CrmError> { /* unchanged */ }
    pub fn all(&self) -> &[Customer] { /* ... */ }
    pub fn page(&self, page: usize, per_page: usize) -> &[Customer] { /* ... */ }
    pub fn find(&self, id: u32) -> Option<&Customer> { /* ... */ }
    pub fn find_mut(&mut self, id: u32) -> Option<&mut Customer> { /* ... */ }
    pub fn find_by_email(&self, email: &Email) -> Option<&Customer> { /* ... */ }
    pub fn email_exists(&self, email: &Email) -> bool { /* ... */ }
    pub fn first_by_domain<'a>(&'a self, domain: &str) -> Option<&'a Customer> { /* ... */ }
    pub fn len(&self) -> usize { /* ... */ }
    pub fn is_empty(&self) -> bool { self.customers.is_empty() }
    pub fn count_by_status(&self, status: CustomerStatus) -> usize { /* ... */ }
    pub fn remove(&mut self, id: u32) -> Option<Customer> { /* ... */ }
    pub fn search<'a>(&'a self, term: &str) -> Vec<&'a Customer> { /* ... */ }
}

fn next_id(current: u32) -> u32 {
    current + 1
}

impl Default for CustomerStore {
    fn default() -> Self {
        Self::new()
    }
}
```

**Reasoning:**

- **`use super::{Customer, Email}` vs `use super::model::Customer`.** Both work from inside
  `customers`, because a child can see its parent's private modules. Going through the parent's
  re-exports means `store.rs` doesn't care which file `Customer` lives in, the same benefit the
  re-exports give outside callers.
- **`use crate::errors::...`**: `errors` hangs off the crate root, so the path starts at `crate`.
  `super::super::errors` would also work, but `crate::` survives files moving around.
- **`next_id` stays private.** It's not part of what a store *does*, only how. (Some people
  inline it as `self.next_id += 1`, which is equally fine.)
- The `Customer` fields being `pub` makes `update_email` redundant (`customer.email = e` does the
  same). Keeping it is harmless; Lab 14 replaces `Customer` anyway.

---

## Your Turn 1 — `compile_fail` doc tests

```rust
/// An email address that has passed validation.
///
/// The field is private, so the only way to get an `Email` is through
/// [`Email::parse`]. If you hold an `Email`, it is valid: trimmed,
/// lowercase, with exactly one `@` and a dot in the domain.
///
/// Code outside the `customers` module cannot build one directly:
///
/// ```compile_fail
/// use rust_crm::customers::Email;
///
/// let email = Email(String::from("definitely not an email"));
/// ```
///
/// ...and cannot reach inside one to change it:
///
/// ```compile_fail
/// use rust_crm::customers::Email;
///
/// let mut email = Email::parse("ada@example.com").unwrap();
/// email.0.push_str(" oops");
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct Email(String);
```

```rust
    /// Accepts "prospect", "active" or "churned" (any letter case).
    ///
    /// ```
    /// use rust_crm::customers::CustomerStatus;
    ///
    /// assert_eq!(CustomerStatus::parse("Active"), Some(CustomerStatus::Active));
    /// assert_eq!(CustomerStatus::parse("vip"), None);
    /// ```
    pub fn parse(s: &str) -> Option<CustomerStatus> {
```

`cargo test` output:

```text
   Doc-tests rust_crm

running 2 tests
test src/customers/model.rs - customers::model::CustomerStatus::parse (line 15) ... ok
test src/customers/email.rs - customers::email::Email::parse (line 31) ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...

running 2 tests
test src/customers/email.rs - customers::email::Email (line 19) - compile fail ... ok
test src/customers/email.rs - customers::email::Email (line 11) - compile fail ... ok
```

**Reasoning:**

- A `compile_fail` test is a regression test for your **API design**: if someone makes the field
  `pub` one day ("it's just easier"), `cargo test` fails and the doc explains why it mustn't.
- Its weakness: it passes if the code fails to compile for **any** reason, including a typo. That's
  why the last checkbox asked you to make the field `pub` temporarily and watch the tests turn
  red: it proves they fail for the right reason. (On nightly Rust you can write
  `compile_fail,E0423` to pin the error code; on stable, the code is ignored.)
- `.unwrap()` inside the second example is fine: it's test code, and the line that's *supposed* to
  fail is the next one.
- Notice the test names: `customers::model::CustomerStatus::parse`. Rustdoc names tests by the
  **file** location, even though the public path is `customers::CustomerStatus`.

---

## Your Turn 2 — One function per command

```rust
pub(crate) fn execute(store: &mut CustomerStore, command: Command) -> Result<(), CrmError> {
    match command {
        Command::Help => print_help(),
        Command::Version => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
        Command::Quit => {} // the REPL loop handles Quit before calling execute
        Command::Add => add(store)?,
        Command::List { page } => list(store, page),
        Command::Count => count(store),
        Command::Show { id } => show(store, id)?,
        Command::Update { id } => update(store, id)?,
        Command::Delete { id } => delete(store, id)?,
        Command::Search { term } => search(store, term),
        Command::Status { id, status } => change_status(store, id, status)?,
    }
    Ok(())
}

fn add(store: &mut CustomerStore) -> Result<(), CrmError> {
    let name = parse_name(&prompt("Name: "))?;
    let email = Email::parse(&prompt("Email: "))?;
    let phone = parse_phone(&prompt("Phone (optional): "))?;

    // Look before adding (Lab 10): the note is owned, so it holds no borrow of `store`.
    let note = colleague_note(store, &email);
    let id = store.add(name, email, phone)?;
    println!("Added customer #{id}");
    if let Some(note) = note {
        println!("{note}");
    }
    Ok(())
}

fn list(store: &CustomerStore, page: usize) {
    let customers = store.page(page, PAGE_SIZE);
    if store.is_empty() {
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

fn show(store: &CustomerStore, id: u32) -> Result<(), CrmError> {
    let customer = store.find(id).ok_or(CrmError::NotFound(id))?;
    println!("{}", customer.summary());
    if !customer.has_phone() {
        println!("(no phone on file)");
    }
    println!("  Domain:   {}", customer.email.domain());
    println!("  Initials: {}", initials(&customer.name));
    Ok(())
}

fn delete(store: &mut CustomerStore, id: u32) -> Result<(), CrmError> {
    let customer = store.remove(id).ok_or(CrmError::NotFound(id))?;
    println!("Deleted customer #{} ({})", customer.id, customer.name);
    Ok(())
}

fn change_status(
    store: &mut CustomerStore,
    id: u32,
    status: CustomerStatus,
) -> Result<(), CrmError> {
    let customer = store.find_mut(id).ok_or(CrmError::NotFound(id))?;
    match (customer.status, status) {
        (current, new) if current == new => {
            println!("Customer #{id} is already {}.", current.label());
        }
        (CustomerStatus::Churned, CustomerStatus::Prospect) => {
            println!("A churned customer can't go back to prospect. Use 'active' to win them back.");
        }
        (_, new) => {
            customer.status = new;
            println!("Customer #{id} is now {}.", new.label());
        }
    }
    Ok(())
}

// count, search and update follow the same pattern: the arm's body, moved into a function.
```

**Reasoning:**

- **Signatures document intent.** `fn list(store: &CustomerStore, ...)` tells a reader, without
  reading the body, that listing can't change anything. Inside the one big `match`, every arm had
  `&mut` access whether it needed it or not.
- **Reborrowing.** `execute` holds a `&mut CustomerStore`; calling `list(store, page)` passes it
  where `&CustomerStore` is expected, and Rust creates a temporary shared reborrow for the call.
  After the call, the mutable reference is usable again.
- **`()` vs `Result`.** `list`, `count` and `search` can't fail, so they return `()`, and their
  arms don't need `?`. Don't add `Result` "just in case": it forces every caller to handle an
  error that can't happen.
- The `?` on each arm and the `Ok(())` at the end of `execute` stay. `execute`'s job is now only
  to route.

---

## Your Turn 3 — `examples/seed.rs`

```rust
//! Builds a small CRM using only the library's public API.
//! Run with: cargo run --example seed

use rust_crm::customers::{CustomerStatus, CustomerStore, Email};
use rust_crm::errors::CrmError;

fn main() -> Result<(), CrmError> {
    let mut store = CustomerStore::new();

    let ada = store.add(
        "Ada Lovelace".to_string(),
        Email::parse("ada@example.com")?,
        Some("555-0100".to_string()),
    )?;
    store.add(
        "Grace Hopper".to_string(),
        Email::parse("grace@example.com")?,
        None,
    )?;

    if let Some(customer) = store.find_mut(ada) {
        customer.status = CustomerStatus::Active;
    }

    for customer in store.all() {
        println!("{}", customer.summary());
    }

    match Email::parse("nope") {
        Ok(email) => println!("unexpected: {} is valid", email.as_str()),
        Err(e) => println!("rejected: {e}"),
    }
    Ok(())
}
```

**Reasoning:**

- `Email::parse(...)?` in `main` converts a `ValidationError` into `CrmError` through the same
  `From` impl as everywhere else. `main` may return `Result<(), E>` for any `E: Debug`.
- **Why `match` for the last one, not `?`.** If you write `store.add("Bad".into(), Email::parse("nope")?, None)`,
  the `?` returns from `main` with the error, and the program ends like this:

  ```text
  Error: Validation(InvalidEmail("nope"))
  ```

  with exit code 1. That's `main`'s built-in behaviour for `Err`: it prints the error with
  **`Debug`**, not `Display`. Useful for quick tools, but here we wanted to *show* the rejection
  and carry on, so we handle it.
- `store.find_mut(ada)` works because `Customer.status` is `pub`. Try writing
  `Email(String::from("x"))` here: E0423, the same protection as in `main.rs`. Examples are
  separate crates, so they see exactly what `tests/` and the server will see.
- `cargo test` **compiles** examples (without running them), so a broken example fails CI later.
  Keep that in mind: Lab 14 deletes `customers`, and this file will have to go too.

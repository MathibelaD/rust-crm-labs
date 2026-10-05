# Lab 16 — Generics: One Repository for Everything ♻️

> **Phase:** 4 — Abstraction · **Builds on:** Lab 15 · **Time:** ~5 hours
> **Your repo before this lab:** tag `lab-15` · **After:** tag `lab-16`

> This lab assumes you completed **Your Turns 1–3 in Lab 15** (`Validate` for `Contact`,
> `Display` for `Contact`, generic `parse_id`). If you skipped any, copy them from
> [Lab 15's solutions.md](../15-traits/solutions.md) first.

## 🎯 Goal

Delete `CompanyStore` and `ContactStore` and replace both with **one** generic type,
`InMemoryRepo<T: Entity>`. After this lab, adding a new kind of record to the CRM (deals in
Lab 18, leads in Lab 19, activities and notes in Lab 20) costs a struct and an `impl Entity`,
and nothing else.

## 🧠 What You'll Learn

- Generic structs and `impl` blocks: `struct InMemoryRepo<T>`, `impl<T> InMemoryRepo<T>`
- **Bounds as permissions**: a bound lists what the body is allowed to do with `T`
- Reading the errors you get from a missing bound: E0599 and E0277, and when the compiler's
  suggestion is wrong
- `where` clauses, bounds on **associated types** (`T::Id: From<u64>`), and where to put a bound
  (method, impl block, struct, or trait)
- Why `#[derive(Default)]` on a generic struct can add bounds you didn't want
- **Inherent impls on one instantiation**: `impl InMemoryRepo<Contact> { ... }`
- **Monomorphization**: what code the compiler actually generates for a generic, and how to see it
- Generics vs trait objects, revisited
- `PhantomData` and a typed `Id<T>`, as an experiment (and why we don't adopt it)
- `todo!()` and the never type, as a placeholder that type-checks

## 🔨 What We're Building

Open the two store files side by side. They're the same code with different nouns: a `Vec` of
items, a `next_id` counter, `find`, `find_mut`, `remove`, `all`, `len`. Lab 18 will need
a third copy for deals. Lab 19 a fourth for leads. Lab 20 a fifth and sixth. Every bug fix would
have to be made six times.

You *could* have written a generic store in Lab 14. Doing it now is deliberate. The
**rule of three**: the first time you write something, just write it; the second time, notice
the duplication; the third time, abstract. With two real examples in front of you, you know
exactly what varies (the item type, the id type) and what doesn't (everything else). Abstracting
from one example means guessing.

After this lab:

```rust
pub struct Crm {
    pub companies: InMemoryRepo<Company>,
    pub contacts: InMemoryRepo<Contact>,
}
```

The CRM behaves exactly as before (that's what makes it a refactor), with one visible difference
you'll understand by the end: ids are handed out *before* validation, so a rejected record
leaves a gap.

---

## Step 1 — See the duplication

> 🟢 **FOLLOW ALONG**: from your repo root:

```bash
git diff --no-index --stat src/companies/store.rs src/contacts/store.rs
git diff --no-index src/companies/store.rs src/contacts/store.rs
```

```text
 src/{companies => contacts}/store.rs | 84 +++++++++++++++++++++++++-----------
 1 file changed, 59 insertions(+), 25 deletions(-)
```

Scroll through the full diff. Most hunks are renames: `CompanyStore`→`ContactStore`,
`companies`→`contacts`, `Company`→`Contact`. Make a list of what **actually** differs. You
should end up with something like:

| Differs | Same in both |
|---|---|
| The item type (`Company` / `Contact`) | A `Vec` of items plus a `next_id: u64` counter |
| The id type (`CompanyId` / `ContactId`) | Look up by id, look up mutably, remove by id, list all, count |
| How to turn the counter into an id (`CompanyId(n)` / `ContactId(n)`) | Ids are never reused |
| Contact-only queries: `email_exists`, `search`, `page` | |
| What `add` checks (website vs duplicate email) | |

The left column is the design. The item type becomes a **type parameter** `T`. "Read the id of
an item" is `Entity::id`, from Lab 15. "Turn a counter into an id" is the `From<u64>` you added
to both id types in Lab 15. Contact-only queries need somewhere to live (Step 8). And `add`'s
*validation* moves out of the storage layer entirely: storing things and deciding what's
allowed are different jobs.

---

## Step 2 — A generic struct that asks for nothing

> 🟢 **FOLLOW ALONG**: create `src/repo.rs`:

```rust
//! A generic in-memory repository: one implementation for every entity.

pub struct InMemoryRepo<T> {
    items: Vec<T>,
    next_id: u64,
}

impl<T> InMemoryRepo<T> {
    pub fn new() -> Self {
        InMemoryRepo {
            items: Vec::new(),
            next_id: 1,
        }
    }

    pub fn all(&self) -> &[T] {
        &self.items
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}
```

and add `pub mod repo;` to `src/lib.rs`. Run `cargo clippy`. It compiles, with two warnings
(`next_id` is never read; "consider adding a `Default` implementation"). Both get fixed below.

Read the syntax carefully, because the two `<T>`s in `impl<T> InMemoryRepo<T>` mean different
things:

- `impl<T>` **declares** a type parameter named `T` for this block: "for any type `T`...".
- `InMemoryRepo<T>` **uses** it: "...here are methods for `InMemoryRepo` of that `T`".

`InMemoryRepo` on its own isn't a type. `InMemoryRepo<Company>` is a type. `InMemoryRepo` is
more like a function from types to types.

**Why does this compile with no bounds at all?** Look at what the bodies do with `T`: put it in a
`Vec`, hand out `&[T]`, count it. **Every** type can be moved, stored, borrowed and dropped, so
the compiler needs no promises. A generic body is checked **once**, against the bounds, not
against each type you later use it with. If the body tries to do anything that isn't true of
*every possible* `T`, it fails right here.

Which is exactly what happens next.

---

## Step 3 — Bounds are permissions

> 🟡 **EXPERIMENT**: add a lookup, written the way both stores do it (by id). Predict the error,
> then `cargo check`.

```rust
    pub fn get(&self, id: u64) -> Option<&T> {
        self.items.iter().find(|item| item.id() == id)
    }
```

```text
error[E0599]: no method named `id` found for reference `&&T` in the current scope
  --> src/repo.rs:21:44
   |
21 |         self.items.iter().find(|item| item.id() == id)
   |                                            ^^ method not found in `&&T`
   |
   = help: items from traits can only be used if the trait is implemented and in scope
note: `Entity` defines an item `id`, perhaps you need to implement it
  --> src/entity.rs:9:1
   |
 9 | pub trait Entity {
   | ^^^^^^^^^^^^^^^^
```

(`&&T`: `iter()` yields `&T`, and `find` hands its closure a *reference to* each item, so
`&&T`. Method calls auto-dereference through both, so it doesn't matter here. Lab 17 explains
why `find` works that way.)

`T` could be `String`, `u8`, `Vec<bool>`. Most types have no `id()` method, so the compiler
won't let you call one. The fix is to **narrow** `T` to types that do: the types that implement
`Entity`.

```rust
use crate::entity::Entity;   // at the top of repo.rs

impl<T: Entity> InMemoryRepo<T> {
```

Run `cargo check` again:

```text
error[E0308]: mismatched types
  --> src/repo.rs:23:52
   |
23 |         self.items.iter().find(|item| item.id() == id)
   |                                       ---------    ^^ expected associated type, found `u64`
   |                                       |
   |                                       expected because this is `<T as Entity>::Id`
   |
   = note: expected associated type `<T as Entity>::Id`
                         found type `u64`
   = help: consider constraining the associated type `<T as Entity>::Id` to `u64`
```

Progress: `item.id()` now exists. But it returns `T::Id` (spelled `<T as Entity>::Id` in errors:
"the `Id` that `T` chose when it implemented `Entity`"), and you can't compare a `CompanyId` with
a raw `u64`. That's the newtype from Lab 14 protecting you.

The compiler's `help` is a trap. "Constrain `Id` to `u64`" means `impl<T: Entity<Id = u64>>`,
which would only accept entities whose id *is* a plain `u64`, i.e. none of yours. Compiler
suggestions make the error go away; they don't know your design. The right fix is to accept the
entity's own id type. And `find_by_id` from Lab 15 already does exactly this:

```rust
use crate::entity::{Entity, find_by_id};   // at the top

    pub fn get(&self, id: T::Id) -> Option<&T> {
        find_by_id(&self.items, id)
    }
```

**The mental model.** A bound is a **permission slip**. `T: Entity` permits the body to call
`id()` and `label()` on a `T`, and to use whatever `Entity` promises about `T::Id` (`Copy`,
`==`, hashing, `{:?}`). Nothing more. Conversely, a bound is a **requirement** on callers: you can
only make an `InMemoryRepo<X>` with these methods if `X: Entity`. Bounds are the contract between
the generic code and the code that uses it, checked on both sides at compile time.

---

## Step 4 — `insert`, `get_mut`, `remove`

> 🟢 **FOLLOW ALONG**: add `insert` to the `impl<T: Entity>` block:

```rust
    /// Stores an item and returns its id.
    pub fn insert(&mut self, item: T) -> T::Id {
        let id = item.id();
        self.items.push(item);
        id
    }
```

Same move-ordering lesson as Lab 15's `add`: read the id (a `Copy`) *before* `push` moves the item
into the vector. Note what `insert` *doesn't* do: it doesn't create the id. The caller builds a
complete `T` (with an id from `next_id`, Step 5) and hands over ownership.

> 🔵 **YOUR TURN (in-step)**: write `get_mut` and `remove` yourself. Signatures:
>
> ```rust
> pub fn get_mut(&mut self, id: T::Id) -> Option<&mut T>
> pub fn remove(&mut self, id: T::Id) -> Option<T>
> ```
>
> - `get_mut` returns an exclusive borrow of the matching item, or `None`.
> - `remove` takes the matching item **out** of the repo and returns it, owned (the caller prints
>   `Deleted contact #3 (...)` from it). `None` if there's no such id. Order of the remaining
>   items must be preserved.
>
> Your old stores' `find_mut` and `remove` are a good starting point; what changes is the type
> names. You'll test both in Your Turn 2.

💡 `iter_mut()` is to `iter()` what `&mut` is to `&`. For `remove`, find the *position* first
(`Iterator::position`), then `Vec::remove(index)`. The `?` operator works on `Option` too.

---

## Step 5 — `next_id` and the `where` clause

Ids come from the repo's counter, and the repo needs to turn a `u64` into "whatever `T`'s id
type is". Lab 15 gave every id type `From<u64>`. Try it:

> 🟡 **EXPERIMENT**: add to the `impl<T: Entity>` block, then `cargo check`.

```rust
    /// Hands out the next free id. Ids are never reused.
    pub fn next_id(&mut self) -> T::Id {
        let raw = self.next_id;
        self.next_id += 1;
        raw.into()
    }
```

```text
error[E0277]: the trait bound `<T as Entity>::Id: From<u64>` is not satisfied
  --> src/repo.rs:22:13
   |
22 |         raw.into()
   |             ^^^^ the trait `From<u64>` is not implemented for `<T as Entity>::Id`
   |
   = note: required for `u64` to implement `Into<<T as Entity>::Id>`
help: consider further restricting the associated type
   |
19 |     pub fn next_id(&mut self) -> T::Id where <T as Entity>::Id: From<u64> {
   |                                        ++++++++++++++++++++++++++++++++++
```

Read the `note`: the compiler is reasoning through the blanket impl from Lab 15
(`impl<T, U: From<T>> Into<U> for T`). "`u64: Into<X>` would hold if `X: From<u64>`... and
nothing says `T::Id: From<u64>`." `Entity` promises `Copy + Eq + Hash + Debug` about ids,
nothing about `u64`. Every id you have *happens* to implement `From<u64>`, but generic code
can't rely on what happens to be true; it can only rely on bounds.

(If you'd written `T::Id::from(raw)` instead, you'd get a confusing E0308 "expected associated
type, found `u64`". Every type implements `From<Self>` (the reflexive impl in `std`), so that's
the only `from` the compiler could find for `T::Id`. The `into()` spelling gives the clearer
error.)

This time the suggestion is right in spirit: add the bound. It's a bound on an **associated
type**, which you can only write in a `where` clause. Where you put it is a design decision:

| Where | Syntax | Effect |
|---|---|---|
| On the **trait** | `type Id: Copy + Eq + Hash + Debug + From<u64>;` | Every `Entity`, forever, must be constructible from a `u64`. Even entities you'll never store in this repo. |
| On a whole **impl block** | `impl<T: Entity> InMemoryRepo<T> where T::Id: From<u64> { ... }` | Every method in that block requires it. |
| On **one method** | `pub fn next_id(&mut self) -> T::Id where T::Id: From<u64>` | Only that method requires it. |

Only `next_id` needs the conversion; `get`, `insert`, `remove` work for any entity. Put
`next_id` in its own impl block:

> 🟢 **FOLLOW ALONG**: remove `next_id` from the first block, and add below it:

```rust
impl<T: Entity> InMemoryRepo<T>
where
    T::Id: From<u64>,
{
    /// Hands out the next free id. Ids are never reused.
    pub fn next_id(&mut self) -> T::Id {
        let raw = self.next_id;
        self.next_id += 1;
        T::Id::from(raw)
    }
}
```

A type can have as many inherent `impl` blocks as you like; their methods merge. Separate blocks
with different bounds is the idiomatic way to say "these methods need more than those". (A
method-level `where` clause is equivalent here; pick whichever reads better to you.) Why not on the
trait? Keep traits minimal: in Lab 30 your ids become `i64` and a database will mint them; a trait
that insists on `From<u64>` would be in the way.

> 🟡 **EXPERIMENT**: to see why the split matters, put `next_id` back into the *first* block (so
> every method shares the bound), then temporarily delete `impl From<u64> for ContactId`. Run
> `cargo check` *after* Step 7 (once `Crm` uses the repo) and read which methods become
> unavailable. You'll find this error in the 🧪 Experiment section.

---

## Step 6 — A bound on the struct, and `Default`

`InMemoryRepo<String>` is meaningless: a repository only makes sense for entities. Say so on the
struct itself:

> 🟢 **FOLLOW ALONG**

```rust
pub struct InMemoryRepo<T: Entity> {
    items: Vec<T>,
    next_id: u64,
}
```

Now clippy's `new_without_default` warning: a type with a no-argument `new()` should implement
`Default` (so it works with `#[derive(Default)]` on structs containing it, `..Default::default()`,
`Option::unwrap_or_default`, ...). Write the impl:

> 🟡 **EXPERIMENT**: type it *without* a bound first. Predict, then `cargo check`.

```rust
impl<T> Default for InMemoryRepo<T> {
    fn default() -> Self {
        InMemoryRepo {
            items: Vec::new(),
            next_id: 1,
        }
    }
}
```

```text
error[E0277]: the trait bound `T: Entity` is not satisfied
  --> src/repo.rs:61:21
   |
61 | impl<T> Default for InMemoryRepo<T> {
   |                     ^^^^^^^^^^^^^^^ the trait `Entity` is not implemented for `T`
   |
note: required by a bound in `InMemoryRepo`
  --> src/repo.rs:5:28
   |
 5 | pub struct InMemoryRepo<T: Entity> {
   |                            ^^^^^^ required by this bound in `InMemoryRepo`
help: consider restricting type parameter `T` with trait `Entity`
   |
61 | impl<T: entity::Entity> Default for InMemoryRepo<T> {
   |       ++++++++++++++++
```

A bound on a struct is a promise *every* use must keep: `InMemoryRepo<T>` isn't even a valid type
unless `T: Entity`, so **every** `impl` block has to repeat the bound, even ones (like this one)
whose bodies don't need it. That's the cost, and it's why a lot of Rust code keeps bounds off struct
definitions and only puts them on the impls that need them. Here the self-documenting struct is
worth a few repeated `T: Entity`s. Fix it:

```rust
impl<T: Entity> Default for InMemoryRepo<T> {
```

(Why not `#[derive(Default)]`? Two reasons; you'll discover both in the 🧪 Experiment section.)

---

## Step 7 — Contact-only queries: an inherent impl on one instantiation

`ContactStore` had queries that only make sense for contacts: `email_exists` and `search`. They
can't live in `impl<T: Entity> InMemoryRepo<T>`: a `T` has no `email`. But you can write an
`impl` block for **one specific instantiation**:

> 🟢 **FOLLOW ALONG**: create `src/contacts/queries.rs`:

```rust
//! Queries that only make sense for contacts.
//!
//! This is an inherent `impl` on ONE instantiation of the generic repo:
//! `InMemoryRepo<Contact>` gets these methods, `InMemoryRepo<Company>` does not.

use super::email::Email;
use super::model::Contact;
use crate::repo::InMemoryRepo;

impl InMemoryRepo<Contact> {
    pub fn email_exists(&self, email: &Email) -> bool {
        self.all().iter().any(|c| &c.email == email)
    }

    pub fn search(&self, term: &str) -> Vec<&Contact> {
        todo!("Your Turn 1")
    }
}
```

and declare it in `src/contacts/mod.rs` (just `mod`, no `pub use`):

```rust
mod email;
mod model;
mod queries;
mod store;      // still here until Step 8

pub use email::Email;
pub use model::{Contact, ContactId};
pub use store::ContactStore;
```

Things to notice:

- **No type parameter** after `impl`: `impl InMemoryRepo<Contact>`, not `impl<T>`. This block is
  about exactly one type.
- **It lives in `contacts/`, not in `repo.rs`.** Inherent impls must be in the same *crate* as the
  type, but any module will do. Contact knowledge stays in the contacts module; `repo.rs` stays
  ignorant of every entity.
- **No `pub use` needed.** Inherent methods belong to the type. Anyone who has an
  `InMemoryRepo<Contact>` can call `.email_exists(...)`, no import required. (Trait methods are
  different: you must have the trait in scope.)
- **`todo!()`** is a placeholder macro. It panics at runtime with "not yet implemented", and it
  type-checks anywhere because its type is `!`, the **never type**: an expression that never
  produces a value can stand in for a value of any type. You'll replace it in Your Turn 1. Until
  then, `cargo check` warns `unused variable: term`, and running `contact search` panics.

> 🟡 **EXPERIMENT**: why `self.all().iter()` and not `self.items.iter()`? Try it.

```text
error[E0616]: field `items` of struct `InMemoryRepo` is private
  --> src/contacts/queries.rs:12:14
   |
12 |         self.items.iter().any(|c| &c.email == email)
   |              ^^^^^ private field
```

Privacy in Rust is per **module**, not per type (Lab 13). This `impl` block is *for*
`InMemoryRepo`, but it's written in `contacts::queries`, and `items` is private to `repo`. The
public API (`all`, `get`, `insert`, ...) is all the contacts module gets. That's a feature: the
repo's invariants (ids unique, `next_id` only grows) can only be broken by code inside `repo.rs`.

---

## Step 8 — Swap the stores out

Now the actual refactor.

> 🟢 **FOLLOW ALONG**: rewrite the top of `src/crm.rs`:

```rust
use crate::companies::{Company, CompanyId, Lifecycle};
use crate::contacts::{Contact, ContactId, Email};
use crate::entity::Validate;
use crate::errors::CrmError;
use crate::repo::InMemoryRepo;

#[derive(Default)]
pub struct Crm {
    pub companies: InMemoryRepo<Company>,
    pub contacts: InMemoryRepo<Contact>,
}

impl Crm {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_company(
        &mut self,
        name: String,
        website: Option<String>,
    ) -> Result<CompanyId, CrmError> {
        let company = Company::new(self.companies.next_id(), name, website);
        company.validate()?;
        Ok(self.companies.insert(company))
    }

    pub fn add_contact(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> Result<ContactId, CrmError> {
        if let Some(company_id) = company_id
            && self.companies.get(company_id).is_none()
        {
            return Err(CrmError::NotFound {
                entity: "company",
                id: company_id.0,
            });
        }
        if self.contacts.email_exists(&email) {
            return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
        }
        let contact = Contact {
            id: self.contacts.next_id(),
            name,
            email,
            phone,
            company_id,
        };
        contact.validate()?;
        Ok(self.contacts.insert(contact))
    }
```

Then, in the rest of `impl Crm`, rename the store calls: `self.companies.find(..)` →
`self.companies.get(..)`, `find_mut` → `get_mut`. `remove`, `all` keep their names. (If your
`impl Default for Crm` was hand-written, delete it: `#[derive(Default)]` now works because both
fields implement `Default`.)

`#[derive(Default)]` on `Crm` generates `Crm { companies: Default::default(), contacts:
Default::default() }`, which calls *your* `impl<T: Entity> Default for InMemoryRepo<T>` twice,
once with `T = Company` and once with `T = Contact`.

Now delete the old stores:

```bash
git rm src/companies/store.rs src/contacts/store.rs
```

and remove the `mod store;` / `pub use store::...;` lines from both `mod.rs` files. Then
`cargo check`, and let the compiler drive:

```text
error[E0599]: no method named `find` found for struct `InMemoryRepo<T>` in the current scope
  --> src/cli/commands.rs:74:41
   |
74 |             let company = crm.companies.find(id).ok_or(CrmError::NotFound {
   |                                         ^^^^ method not found in `InMemoryRepo<Company>`

error[E0599]: no method named `page` found for struct `InMemoryRepo<T>` in the current scope
   --> src/cli/commands.rs:117:41
    |
117 |             let contacts = crm.contacts.page(page, PAGE_SIZE);
    |                                         ^^^^ method not found in `InMemoryRepo<Contact>`
```

`find` → `get` in `commands.rs`. For `page`: the paging logic doesn't depend on contacts at all,
so it belongs in the generic block. Move it from your deleted `ContactStore` into
`impl<T: Entity> InMemoryRepo<T>`:

```rust
    /// One page of items (1-based). Out-of-range pages are empty, never a panic.
    pub fn page(&self, page: usize, per_page: usize) -> &[T] {
        let start = page.saturating_sub(1) * per_page;
        if start >= self.items.len() {
            return &[];
        }
        let end = (start + per_page).min(self.items.len());
        &self.items[start..end]
    }
```

Keep going until `cargo check` shows only the `unused variable: term` warning from `todo!()`.
Notice how few lines in `commands.rs` changed: the CLI talks to `Crm` and its public fields,
and the method names barely moved. That's Lab 14's "CLI only parses, prompts and prints" rule
paying off.

### Where did validation go, and what is that gap?

`CompanyStore::add` used to validate *before* using up an id. Now `Crm::add_company` asks the repo
for an id first (it needs a complete `Company` to call `validate` on), then validates. A rejected
company has consumed an id. You'll see `#1`, then a failed add, then `#3`.

Is that a bug? Consider the alternatives: peek at the counter without consuming (a second method,
and a race once there are threads in Lab 25), or validate fields before building the struct
(duplicating `Validate`). Real databases make the same trade: a Postgres identity column hands out
numbers that are **never** reused, even when the inserting transaction rolls back, and gaps are
normal (Lab 30). Ids identify; they don't count. We accept the gap.

---

## Step 9 — What the compiler generates: monomorphization

You've written `InMemoryRepo<T>` once. How does one piece of code work for `Company` (which
contains a `String`, an `Option<String>` and an enum) and `Contact` (a different size, different
fields)?

It doesn't. The compiler writes **a separate copy for each `T` you actually use**. This is
**monomorphization** ("making single-form"). Conceptually, after type checking, your program
contains:

```rust
// generated by the compiler — you never see this source
struct InMemoryRepo__Company { items: Vec<Company>, next_id: u64 }

impl InMemoryRepo__Company {
    fn get(&self, id: CompanyId) -> Option<&Company> {
        find_by_id__Company(&self.items, id)          // calls Company's `id()` directly
    }
    fn next_id(&mut self) -> CompanyId {
        let raw = self.next_id;
        self.next_id += 1;
        <CompanyId as From<u64>>::from(raw)           // a direct call: CompanyId(raw)
    }
    // ...
}

struct InMemoryRepo__Contact { items: Vec<Contact>, next_id: u64 }

impl InMemoryRepo__Contact {
    fn get(&self, id: ContactId) -> Option<&Contact> {
        find_by_id__Contact(&self.items, id)
    }
    // ...
}
```

Each copy knows its exact types: the size of each `Vec` element, which `id()` to call, how to
compare ids (an integer compare). There's no lookup at runtime and nothing to stop the optimiser
inlining everything. It's as fast as the hand-written stores were, because in the binary it *is*
the hand-written stores, written by the compiler.

> 🟢 **FOLLOW ALONG**: see the copies for yourself. Build, then list the symbols in your binary
> (macOS and Linux; `-C` demangles Rust names):

```bash
cargo build
nm -C target/debug/rust-crm | grep -E 'InMemoryRepo<.*>>::(get|insert|next_id|page)$'
```

```text
00000001000140e4 T <rust_crm::repo::InMemoryRepo<rust_crm::contacts::model::Contact>>::get
0000000100014118 T <rust_crm::repo::InMemoryRepo<rust_crm::contacts::model::Contact>>::page
0000000100014220 T <rust_crm::repo::InMemoryRepo<rust_crm::contacts::model::Contact>>::insert
00000001000143f8 T <rust_crm::repo::InMemoryRepo<rust_crm::companies::model::Company>>::get
000000010001442c T <rust_crm::repo::InMemoryRepo<rust_crm::companies::model::Company>>::insert
0000000100014604 T <rust_crm::repo::InMemoryRepo<rust_crm::contacts::model::Contact>>::next_id
000000010001466c T <rust_crm::repo::InMemoryRepo<rust_crm::companies::model::Company>>::next_id
```

(Addresses will differ.) Two `get`s, two `insert`s, two `next_id`s at different addresses:
real, separate machine code. And look at what's **missing**: there's no
`InMemoryRepo<Company>>::page`. The CRM never pages companies, so that copy was never generated.
**The compiler only instantiates what you use.** Lab 15's `find_by_id` shows up twice too:

```bash
nm -C target/debug/rust-crm | grep -E 'find_by_id::<'
```

```text
0000000100005928 T rust_crm::entity::find_by_id::<rust_crm::contacts::model::Contact>
0000000100005978 T rust_crm::entity::find_by_id::<rust_crm::companies::model::Company>
...
```

The trade-off, honestly:

| | Generics (monomorphization) | Trait objects (`dyn`, Lab 15 Step 9) |
|---|---|---|
| Runtime cost | None: direct calls, inlinable | A vtable lookup per call, no inlining across it |
| Compile time / binary size | Grows with each new `T` (one copy per type) | One copy, shared |
| Mixed types in one collection | No: an `InMemoryRepo<Company>` holds only companies | Yes: `Vec<Box<dyn Trait>>` |
| Type chosen | At compile time | At runtime |
| Restrictions | None beyond the bounds | The trait must be dyn compatible (Lab 23) |

For a repository whose item type is known everywhere in the code, generics win easily. You'll
pick `dyn` in Lab 23 for the storage backend, where the choice (memory or JSON file) is made at
runtime from a command-line flag.

---

## Step 10 — Experiment: a typed `Id<T>` with `PhantomData`

`CompanyId` and `ContactId` are the same code twice, much like the stores were. Could generics
remove *that* duplication too? One `Id<T>` where `Id<Company>` and `Id<Contact>` are different
types? Let's find out, in a scratch example so the CRM isn't touched. (Lab 14 introduced
`examples/`; files there are separate small programs that can use your library.)

> 🟡 **EXPERIMENT**: create `examples/typed_id.rs`:

```rust
//! Experiment (Lab 16): one generic Id<T> instead of CompanyId/ContactId.
//! Run with: cargo run --example typed_id

use rust_crm::companies::Company;
use rust_crm::contacts::Contact;

struct Id<T> {
    raw: u64,
}

fn main() {
    let company_id: Id<Company> = Id { raw: 1 };
    println!("company {}", company_id.raw);
}
```

```bash
cargo check --example typed_id
```

```text
error[E0392]: type parameter `T` is never used
 --> examples/typed_id.rs:7:11
  |
7 | struct Id<T> {
  |           ^ unused type parameter
  |
  = help: consider removing `T`, referring to it in a field, or using a marker such as `PhantomData`
```

The compiler refuses a type parameter that no field uses. It needs to know how `Id<T>` relates to
`T` (does it own a `T`? borrow one?) for drop checking and variance, and with no field it can't
tell. `std::marker::PhantomData<T>` is a **zero-sized** field that says "act as if I own a `T`"
without storing one. Replace the file with:

```rust
//! Experiment (Lab 16): one generic Id<T> instead of CompanyId/ContactId.
//! Run with: cargo run --example typed_id

use std::marker::PhantomData;

use rust_crm::companies::Company;
use rust_crm::contacts::Contact;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Id<T> {
    raw: u64,
    _entity: PhantomData<T>,
}

impl<T> Id<T> {
    fn new(raw: u64) -> Self {
        Id {
            raw,
            _entity: PhantomData,
        }
    }
}

fn delete_contact(id: Id<Contact>) {
    println!("deleting contact {}", id.raw);
}

fn main() {
    let company_id: Id<Company> = Id::new(1);
    let copy = company_id;
    println!("{} {}", company_id.raw, copy.raw);
    // delete_contact(company_id);
}
```

Predict: `Id<T>` derives `Copy`, so `let copy = company_id;` copies, right?

```text
error[E0382]: borrow of moved value: `company_id`
  --> examples/typed_id.rs:31:23
   |
29 |     let company_id: Id<Company> = Id::new(1);
   |         ---------- move occurs because `company_id` has type `Id<Company>`, which does not implement the `Copy` trait
30 |     let copy = company_id;
   |                ---------- value moved here
31 |     println!("{} {}", company_id.raw, copy.raw);
   |                       ^^^^^^^^^^^^^^ value borrowed here after move
```

`#[derive(Copy)]` on a generic struct generates `impl<T: Copy> Copy for Id<T>`. It adds a bound
on **every type parameter**, whether or not a field actually needs it. `Company` isn't `Copy` (it
owns `String`s), so `Id<Company>` isn't either, even though an `Id` contains only a `u64`.
Derives are mechanical; they can't see that `PhantomData<T>` doesn't really hold a `T`. Write the
two impls by hand, which is what crates that do this for real (and the standard library) do:

```rust
#[derive(Debug, PartialEq, Eq)]
struct Id<T> {
    raw: u64,
    _entity: PhantomData<T>,
}

// Written by hand: #[derive(Clone, Copy)] would demand `T: Copy`.
impl<T> Clone for Id<T> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<T> Copy for Id<T> {}
```

Now it runs. Uncomment `delete_contact(company_id);`:

```text
error[E0308]: mismatched types
  --> examples/typed_id.rs:32:20
   |
32 |     delete_contact(company_id);
   |     -------------- ^^^^^^^^^^ expected `Id<Contact>`, found `Id<Company>`
   |     |
   |     arguments to this function are incorrect
   |
   = note: expected struct `Id<Contact>`
              found struct `Id<Company>`
```

The type safety works: same layout, different types. Add
`println!("size of Id<Company>: {} bytes", std::mem::size_of::<Id<Company>>());` and run it: `8
bytes`. `PhantomData` costs nothing.

**So why don't we adopt it?** Count the friction you just hit: E0392, hand-written `Clone`/`Copy`,
and the same story for `PartialEq`, `Hash`, `Ord` (the derives above still require `T: PartialEq`
etc.; `Company` isn't `PartialEq`, so `Id<Company> == Id<Company>` wouldn't compile). Then serde
in Lab 21 and SQLx in Lab 30 would each need extra attributes to see through the marker. The
newtypes give you the *same* safety for two short `#[derive]` lines per entity. It's a real
technique, and worth knowing when you meet it in a crate, but here it costs more than it saves.
Keep `examples/typed_id.rs` as a record of the experiment (it's not part of the library), or
delete it.

---

## ▶️ Run It

```bash
cargo fmt && cargo clippy && cargo test
cargo run
```

(Don't run `contact search` yet: it's still `todo!()`.)

## ✅ Expected Result

`cargo clippy` shows a single warning, `unused variable: term`, until Your Turn 1. Then:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> company add
Name: Acme Corp
Website (blank for none): acme.io
Added company #1
crm> company add
Name: Globex
Website (blank for none): globex com
Error: invalid website: globex com
crm> company add
Name: Globex
Website (blank for none): globex.com
Added company #3
crm> contact add
Name: Ada Lovelace
Email: ada@acme.io
Phone (blank for none): 555-0100
Company id (blank for none): 1
Added contact #1
crm> contact add
Name: Ada Clone
Email: ADA@acme.io
Phone (blank for none):
Company id (blank for none):
Error: a contact with email ada@acme.io already exists
crm> contact add
Name: Grace Hopper
Email: grace@navy.mil
Phone (blank for none):
Company id (blank for none): 3
Added contact #2
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  acme.io
#3   Globex               prospect  globex.com
crm> quit
Goodbye! (8 commands this session)
```

Same behaviour as Lab 15, except Globex is `#3`: the rejected attempt consumed `#2` (Step 8).
The duplicate-email contact did **not** consume an id: `add_contact` checks duplicates before
calling `next_id`. Only validation failures leave gaps.

## 🧠 Understand It

**What varies became a parameter; what's assumed became a bound.** `T` is the item type. Each
thing the generic code needs from `T` is written down as a bound: `T: Entity` (read an id, a
label), `T::Id: From<u64>` (mint an id). The compiler checks the generic body against the bounds
*once*, and each use site against the bounds *each time*. Neither side can surprise the other.

**Bounds can live in four places** (trait, struct, impl block, method), from "everyone, always" to
"this one method". Put a bound as close as possible to the code that needs it. We made two
deliberate exceptions: `T: Entity` on the struct, because an `InMemoryRepo` of non-entities is
nonsense and the struct definition should say so, and the trait's own `Id` bounds, which every
implementor needs.

**An inherent impl on an instantiation** (`impl InMemoryRepo<Contact>`) adds methods to one
concrete type. It's how you get "generic code plus specialised extras" without the generic code
knowing about the extras. Lab 18's `pipeline_report` uses the same trick on `Crm` from another
module.

**Monomorphization** is why generics are free at runtime: the compiler stamps out a copy per type
used, and you saw the copies with `nm`. You pay in compile time and binary size, roughly per
`(function, type)` pair.

**The refactor's shape.** You added one file (`repo.rs`, ~80 lines), one small file
(`queries.rs`), and deleted two (~150 lines). Every future entity reuses `repo.rs` for free.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: `#[derive(Default)]` instead of the hand-written impl.** Delete your
> `impl<T: Entity> Default for InMemoryRepo<T>` and put `#[derive(Default)]` on the struct
> instead. Predict where the error appears, then run `cargo check`.

```text
error[E0277]: the trait bound `Company: Default` is not satisfied
  --> src/crm.rs:9:5
   |
 7 | #[derive(Default)]
   |          ------- in this derive macro expansion
 8 | pub struct Crm {
 9 |     pub companies: InMemoryRepo<Company>,
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ unsatisfied trait bound
   |
help: the trait `Default` is not implemented for `Company`
  --> src/companies/model.rs:54:1
   |
54 | pub struct Company {
   | ^^^^^^^^^^^^^^^^^^
help: the trait `Default` is conditionally implemented for `InMemoryRepo<T>`
  --> src/repo.rs:5:10
   |
 5 | #[derive(Default)]
   |          ^^^^^^^
 6 | pub struct InMemoryRepo<T: Entity> {
   |                         - unsatisfied requirement introduced here: `Company: Default`
...
   = help: consider manually implementing `Default` to avoid undesired bounds caused by "imperfect derives"
```

Same "imperfect derive" as `Copy` on `Id<T>` in Step 10: the derive generated
`impl<T: Entity + Default> Default for InMemoryRepo<T>`, demanding `Company: Default` although an
empty `Vec<Company>` needs no default `Company`. And there's a second, silent reason to avoid it
here: a derived `Default` would set `next_id` to `u64::default()`, which is **0**, so the first
entity would get `#0`. Which question would you ask yourself next time before deriving `Default`
on a generic type? Restore the manual impl.

> 🟡 **EXPERIMENT 2: a method on the wrong instantiation.** In `contact search`, add
> `let oops = crm.companies.search(term);`.

```text
error[E0599]: no method named `search` found for struct `InMemoryRepo<Company>` in the current scope
   --> src/cli/commands.rs:147:38
    |
147 |             let oops = crm.companies.search(term);
    |                                      ^^^^^^ method not found in `InMemoryRepo<Company>`
    |
   ::: src/repo.rs:5:1
    |
  5 | pub struct InMemoryRepo<T: Entity> {
    | ---------------------------------- method `search` not found for this struct
    |
    = note: the method was found for `InMemoryRepo<Contact>`
```

`InMemoryRepo<Company>` and `InMemoryRepo<Contact>` are **different types** that share some
methods. The last note is the compiler telling you where the method does exist.

> 🟡 **EXPERIMENT 3: bounds are checked where you use them.** Move `next_id` back into the first
> impl block (so the whole block has `where T::Id: From<u64>`), then delete
> `impl From<u64> for ContactId`. Run `cargo check`:

```text
error[E0599]: the method `get` exists for struct `InMemoryRepo<Contact>`, but its trait bounds were not satisfied
   --> src/cli/commands.rs:125:40
    |
125 |             let contact = crm.contacts.get(id).ok_or(CrmError::NotFound {
    |                                        ^^^ method cannot be called on `InMemoryRepo<Contact>` due to unsatisfied trait bounds
    |
   ::: src/contacts/model.rs:9:1
    |
  9 | pub struct ContactId(pub u64);
    | -------------------- doesn't satisfy `ContactId: From<u64>`
...
note: trait bound `ContactId: From<u64>` was not satisfied
   --> src/repo.rs:12:12
    |
 10 | impl<T: Entity> InMemoryRepo<T>
    |                 ---------------
 11 | where
 12 |     T::Id: From<u64>,
    |            ^^^^^^^^^ unsatisfied trait bound introduced here
```

(You'll also get E0277s from `parse_id` in the parser: your Lab 15 Your Turn 3 made it require
`Id: From<u64>` too. Same bound, different place.)

`get` doesn't need `From<u64>`, but it sits in a block that demands it, so it disappeared for
contacts. `InMemoryRepo<Company>` is unaffected: bounds are checked per instantiation. Now put
`next_id` back in its own block (keep `From<u64>` deleted): which errors remain? That's the case
for keeping bounds as narrow as possible. Restore everything.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `search` on `InMemoryRepo<Contact>`**
>
> Replace the `todo!()` in `src/contacts/queries.rs` with a real implementation.
>
> `pub fn search(&self, term: &str) -> Vec<&Contact>` returns every contact whose **name or
> email** contains `term`, **case-insensitively**, in insertion order. The results are borrowed
> from the repo (no cloning contacts).

- [ ] `contact search ADA` finds `Ada Lovelace`
- [ ] `contact search navy` finds the contact with email `grace@navy.mil`
- [ ] a term that matches nothing prints `No contacts match '...'.`
- [ ] no `todo!()` left, and `cargo clippy` shows no warnings
- [ ] a test in `queries.rs` covers name match, email match and no match (build the data with
      `Crm::new()` + `add_contact`)

> 🔵 **YOUR TURN 2: prove the repo is generic**
>
> Write a `#[cfg(test)] mod tests` at the bottom of `src/repo.rs` that tests `InMemoryRepo`
> **without using `Company` or `Contact`**. Define a tiny test-only entity inside the test module
> (for example, a `Note` with a `NoteId(u64)` and a `text: String`), implement whatever it needs,
> and test:
>
> - `next_id` starts at 1 and increases (both via `new()` and via `default()`)
> - `insert` then `get` finds the item; `get` of an unknown id is `None`
> - `get_mut` changes the stored item
> - `remove` returns the owned item, a second `remove` of the same id is `None`, and ids are not
>   reused after a removal
> - `page` returns a short last page and an empty slice when out of range; a new repo `is_empty()`

- [ ] the test module compiles with no `use` of `crate::companies` or `crate::contacts`
- [ ] all the behaviours above are asserted
- [ ] `cargo test repo` passes

Lab 17 adds tests to this module and assumes a helper like
`fn repo_with(texts: &[&str]) -> InMemoryRepo<Note>` exists (one note per text, ids from
`next_id`). Write one.

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: lowercase the term once, outside the loop. Email addresses are
> already lowercase (Lab 12's `Email` guarantees it). Start from `self.all().iter()`.

<details><summary>Hint 2 (more specific)</summary>

`.filter(|c| ...)` keeps the contacts you want; `.collect()` turns the iterator into the
`Vec<&Contact>` the signature promises. Inside the filter: `c.name.to_lowercase().contains(&term)`
`||` the same for `c.email.as_str()`. Lab 17 explains every piece of that line.

</details>

> 💡 **HINT (Your Turn 2)**: to put a type in an `InMemoryRepo`, it must be `Entity`. To call
> `next_id`, its id must be `From<u64>`. And the trait's bounds on `Id` list four more derives.

<details><summary>Hint 2 (more specific)</summary>

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct NoteId(u64);
```

plus `impl From<u64> for NoteId`, a `struct Note { id: NoteId, text: String }`, and
`impl Entity for Note`. `assert_eq!(repo.next_id(), NoteId(1))` needs `NoteId: PartialEq + Debug`,
which you derived.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Why did `impl<T> InMemoryRepo<T>` with `new`, `all` and `len` compile with no bounds, while
   `get` didn't?
2. The compiler suggested `T: Entity<Id = u64>` to fix E0308. Why was that the wrong fix?
3. What does `where T::Id: From<u64>` permit the body to do? Why is it on its own impl block and
   not on the `Entity` trait?
4. Why does every `impl` for `InMemoryRepo` have to repeat `T: Entity`?
5. Why couldn't `#[derive(Default)]` work for `InMemoryRepo<T>`? Give both reasons.
6. `impl InMemoryRepo<Contact>` lives in `src/contacts/queries.rs`. Why can it call `self.all()`
   but not touch `self.items`? Why don't callers need to import anything to use `search`?
7. You wrote `get` once. How many compiled versions of it are in your binary, and how could you
   check? Why is there no `InMemoryRepo<Company>::page`?
8. A rejected company leaves a gap in the ids now. Why is that acceptable?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

```bash
git add .
git commit -m "Replace entity stores with generic InMemoryRepo"
git tag lab-16
git push && git push --tags
```

`git diff lab-15 lab-16 --stat` should show two `store.rs` files deleted and `repo.rs` added. That
negative line count is the point of this lab.

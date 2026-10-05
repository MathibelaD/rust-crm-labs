# Lab 15 — Traits

> **Phase:** 4 — Abstraction · **Builds on:** Lab 14 · **Time:** ~5–6 hours
> **Your repo before this lab:** tag `lab-14` · **After:** tag `lab-15`

## 🎯 Goal

Give `Company` and `Contact` **shared behaviour**. They both get an id and a label (`Entity`),
they both enforce their own business rules (`Validate`), and they both print themselves as one
row of a table (`Display`). Along the way you'll swap hand-written helpers like
`Lifecycle::parse` and `Email::parse`'s body for the standard library's conversion traits,
which means `.parse()`, `?` and `.into()` start working on *your* types.

## 🧠 What You'll Learn

- What a trait **is**: a named contract that a type opts into, checked at compile time
- How Rust traits differ from TypeScript interfaces: **nominal, not structural**, implemented
  in separate `impl` blocks, and addable to types that already exist
- The **orphan rule**, and the E0117 you get when you break it
- **Associated types** (`type Id`) vs generic parameters, and why `Entity::Id` is associated
- **Default methods**: behaviour every implementor gets for free
- What each common `#[derive]` actually generates: `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`,
  `Hash`, `PartialOrd`, `Ord`
- `Display` vs `Debug`, and `Formatter::pad` so your types respect `{:<20}`
- The conversion traits `From`/`Into`, `TryFrom`, `FromStr`, and the payoff: `?` calls `From`,
  `.parse()` calls `FromStr`
- Trait bounds and `impl Trait` in argument position (your first generic functions)
- A first look at `dyn Trait`: trait objects, fat pointers and vtables

## 🔨 What We're Building

Right now each type has its own ad-hoc helpers: `Company::summary()`, `Contact::summary()`,
`Lifecycle::label()`, `Lifecycle::parse()`, and validation checks scattered through
`Crm::add_company` and `Crm::add_contact`. Every new entity (deals in Lab 18, leads in Lab 19)
would copy that pattern again.

After this lab, list commands print real tables:

```text
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  acme.io
#2   Globex               customer  globex.com
crm> contact list
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
#2   Grace Hopper         grace@navy.mil           -              -
Page 1 of 1
```

Bad input is rejected by the types themselves:

```text
crm> company stage 2 won
Error: invalid lifecycle 'won' (expected prospect, customer or churned)
```

And you'll have the trait that makes Lab 16 possible: `Entity`. The generic repository needs
*some* way to ask "what's your id?" of a type it knows nothing about. That's what a trait is for.

> **Starting point.** This lab assumes you completed **Your Turn 1 in Lab 14**
> (`Crm::remove_contact` / `Crm::remove_company` and the `company delete` / `contact delete`
> commands; see [Lab 14's solutions.md](../14-companies-and-contacts/solutions.md) if not). It
> also assumes the Lab 14 layout: `src/companies/{mod.rs, model.rs, store.rs}`,
> `src/contacts/{mod.rs, model.rs, store.rs, email.rs}`, `src/crm.rs`, `src/errors.rs`,
> `src/cli/{mod.rs, parser.rs, commands.rs}`. The pieces this lab touches: `Company::summary()`,
> `Contact::summary()`, `Lifecycle::parse` / `Lifecycle::label`, the `clean_name` / `clean_phone`
> helpers in `crm.rs` (`Crm::add_contact` checks the name, phone, company and duplicate email;
> `ContactStore::add` checks nothing), and in `commands.rs` the `company` / `contact` handlers,
> `update_contact`, `read_company_id` and `print_contact_line`. The parser matches on slices
> (`("show", [id]) => ...`) and has `fn parse_id(raw: &str) -> Result<u64, CrmError>`.

---

## Step 1 — The mental model: a trait is a contract plus a capability

You have used traits since Lab 04 without writing one. `#[derive(Debug)]` implemented the
`Debug` trait. `{}` in `println!` needs the `Display` trait. `for x in v` uses `IntoIterator`.
`.clone()` is the `Clone` trait.

A trait is two things at once:

1. **A contract.** "Any type that implements `Display` has a method
   `fn fmt(&self, f: &mut Formatter) -> fmt::Result`." The trait lists method signatures, and
   optionally default bodies.
2. **A capability the compiler can check.** A function can say "give me anything that
   implements `Display`" and the compiler refuses, at compile time, every call that passes
   something that doesn't. There's no runtime check and no runtime cost.

If you've written TypeScript, the closest thing is an `interface`. The comparison helps, but
it's not exact, and the differences matter:

| | TypeScript `interface` | Rust `trait` |
|---|---|---|
| How a type satisfies it | **Structurally**: any object with the right shape fits, whether or not it mentions the interface | **Nominally**: a type implements a trait only if someone writes `impl Trait for Type`. Having methods with the right names isn't enough. |
| Where the implementation lives | Inside the class (`class A implements I { ... }`) | In a separate `impl Trait for Type { ... }` block, which can be in a different file from the type |
| Can you add it to a type you didn't write? | No (you'd write a wrapper) | **Yes**: `impl MyTrait for String` is allowed. Within limits: see the orphan rule in Step 6. |
| Can it hold data? | Properties, yes | No fields. Methods, associated types and constants only. |
| Exists at runtime? | Erased (types disappear after compiling) | Usually also erased: generic code is compiled per type (Lab 16). `dyn Trait` keeps a small table of function pointers (Step 9). |

"Nominal" sounds like a limitation. In practice it's a feature: implementing a trait is a
deliberate **promise**. `Eq` promises that equality is reflexive; `Ord` promises a total
order; a `HashMap` *relies* on `Hash` agreeing with `Eq`. A type that merely happens to have a
method called `eq` doesn't make those promises.

---

## Step 2 — Your first trait: `Entity`

Every record the CRM stores has an id and a human-readable label. Create `src/entity.rs`:

> 🟢 **FOLLOW ALONG**

```rust
//! Behaviour shared by every record the CRM stores.

use std::fmt::Debug;
use std::hash::Hash;

/// Something the CRM stores and refers to by id.
pub trait Entity {
    /// The id type of this entity, e.g. `CompanyId` for `Company`.
    type Id: Copy + Eq + Hash + Debug;

    fn id(&self) -> Self::Id;

    /// A short human-readable name, used in messages like "Deleted company #1 (Acme)".
    fn label(&self) -> String;
}
```

And register the module in `src/lib.rs`:

```rust
pub mod cli;
pub mod companies;
pub mod contacts;
pub mod crm;
pub mod entity;
pub mod errors;
```

Read the trait line by line.

**`type Id: Copy + Eq + Hash + Debug;`** is an **associated type**. Each implementor picks one
concrete type for it: `Company` will say `type Id = CompanyId;`. The part after the colon is a
list of **bounds**: whatever type an implementor picks *must* implement those four traits.
Each bound is there because the code we're about to write needs it:

| Bound | Why `Entity::Id` needs it |
|---|---|
| `Copy` | `id()` returns the id **by value**. Ids are small numbers; copying is cheaper and simpler than borrowing. |
| `Eq` | "Find the entity whose id equals this one." Without `Eq`, `==` doesn't compile on a generic id. |
| `Hash` | Ids will be `HashMap` keys (Lab 17's `stats`, later relationships). `HashMap<K, V>` requires `K: Hash + Eq`. |
| `Debug` | Error messages and `assert_eq!` failures can print the id. |

**`fn id(&self) -> Self::Id;`** has no body, so every implementor must provide one.
`Self::Id` means "whatever `Id` the implementing type chose".

### Why an associated type and not a generic parameter?

You could write the trait as `trait Entity<Id> { fn id(&self) -> Id; }`. The difference is
about **how many implementations one type can have**:

- `trait Entity<Id>` is really a *family* of traits: `Entity<CompanyId>`, `Entity<u64>`,
  `Entity<String>`... A type could implement several of them at once.
- `trait Entity { type Id; }` is one trait, and each type implements it **once**, so it picks
  **exactly one** id type.

A contact has exactly one kind of id. With a generic parameter, nothing stops someone writing
both `impl Entity<ContactId> for Contact` and `impl Entity<u64> for Contact`, and then every
call to `contact.id()` becomes ambiguous. Here's what the compiler says in that world (a tiny
standalone file, not your CRM; don't type it in):

```text
error[E0283]: type annotations needed
  --> assoc.rs:11:9
   |
11 |     let id = c.id();
   |         ^^     -- type must be known at this point
   |
note: multiple `impl`s satisfying `Contact: EntityG<_>` found
  --> assoc.rs:6:1
   |
 6 | impl EntityG<ContactId> for Contact { fn id(&self) -> ContactId { self.id } }
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 7 | impl EntityG<u64> for Contact { fn id(&self) -> u64 { self.id.0 } }
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

**Rule of thumb:** if the *implementing type determines* the other type (one entity has one id
type; one iterator has one item type), use an **associated type**. If it makes sense for one type
to implement the trait **several times** with different parameters (`From<u64>`, `From<&str>`,
`From<String>` for the same target type), use a **generic parameter**. You'll meet both forms
again in this lab: `Iterator` has `type Item`, while `From<T>` takes a parameter.

---

## Step 3 — Implementing `Entity`, and your first generic function

> 🟢 **FOLLOW ALONG**: at the bottom of `src/companies/model.rs`:

```rust
use crate::entity::Entity;   // at the top of the file

impl Entity for Company {
    type Id = CompanyId;

    fn id(&self) -> CompanyId {
        self.id
    }

    fn label(&self) -> String {
        self.name.clone()
    }
}
```

And in `src/contacts/model.rs`:

```rust
use crate::entity::Entity;   // at the top of the file

impl Entity for Contact {
    type Id = ContactId;

    fn id(&self) -> ContactId {
        self.id
    }

    fn label(&self) -> String {
        format!("{} <{}>", self.name, self.email.as_str())
    }
}
```

Two things to notice:

- In the impl you can write the concrete type (`-> CompanyId`) instead of `-> Self::Id`. They
  mean the same thing here, and the concrete one reads better.
- `self.id` is a `CompanyId`. Returning it by value **copies** it (it's `Copy`). Returning
  `self.name` by value would *move* the `String` out of `&self`, which is impossible through a
  shared borrow (that's E0507 from Lab 08), hence `.clone()` in `label`.

Now the payoff. Both stores have a `find` method with the same body:
`self.companies.iter().find(|c| c.id == id)`. With the trait you can write that once. Add to
`src/entity.rs`:

```rust
/// Finds the entity with the given id in a slice.
pub fn find_by_id<E: Entity>(items: &[E], id: E::Id) -> Option<&E> {
    items.iter().find(|item| item.id() == id)
}
```

This is a **generic function**. Read `<E: Entity>` as "for any type `E` that implements
`Entity`". Inside the body you may use *only* what the bounds promise: `item.id()` exists
because `E: Entity`; `==` works on `E::Id` because the trait requires `Id: Eq`. Lab 16 is all
about this idea. For now, use it. In `src/companies/store.rs`:

```rust
use crate::entity::find_by_id;   // at the top

    pub fn find(&self, id: CompanyId) -> Option<&Company> {
        find_by_id(&self.companies, id)
    }
```

Do the same in `src/contacts/store.rs` with `&self.contacts`. Run `cargo check`.

It fails, and not where you might expect:

```text
error[E0277]: the trait bound `CompanyId: Hash` is not satisfied
error[E0277]: the trait bound `ContactId: Hash` is not satisfied
```

Lab 14's ids derive `Debug, Clone, Copy, PartialEq, Eq`, but the trait demands
`Id: Copy + Eq + Hash + Debug`. The compiler checks those bounds **at the impl**, so the trait
is already enforcing its rules. Step 4 looks at this error in full. For now, add `Hash` to the
`#[derive(...)]` on both `CompanyId` and `ContactId`, and `cargo check` is clean.

### Nominal typing, demonstrated

> 🟡 **EXPERIMENT**: comment out the whole `impl Entity for Contact { ... }` block. `Contact`
> still has an `id` field of exactly the right type. Predict: does `find_by_id(&self.contacts, id)`
> still compile? Then run `cargo check`.

```text
error[E0277]: the trait bound `Contact: Entity` is not satisfied
  --> src/contacts/store.rs:53:20
   |
53 |         find_by_id(&self.contacts, id)
   |         ---------- ^^^^^^^^^^^^^^ unsatisfied trait bound
   |         |
   |         required by a bound introduced by this call
   |
help: the trait `Entity` is not implemented for `Contact`
  --> src/contacts/model.rs:12:1
   |
12 | pub struct Contact {
   | ^^^^^^^^^^^^^^^^^^
help: the trait `Entity` is implemented for `Company`
  --> src/companies/model.rs:73:1
   |
73 | impl Entity for Company {
   | ^^^^^^^^^^^^^^^^^^^^^^^
note: required by a bound in `find_by_id`
  --> src/entity.rs:18:22
   |
18 | pub fn find_by_id<E: Entity>(items: &[E], id: E::Id) -> Option<&E> {
   |                      ^^^^^^ required by this bound in `find_by_id`
```

(The same error appears a second time, pointing at `id`. Your line numbers may differ. That's
true of every error in this lab.)

Read it as a chain: `find_by_id` **requires** `E: Entity` (the `note`), the call made
`E = Contact` (the first arrow), and nobody wrote `impl Entity for Contact` (the first `help`).
The shape of `Contact` is irrelevant. In TypeScript this would compile; in Rust the
implementation *is* the opt-in. Put the impl back.

---

## Step 4 — Derive: code the compiler writes for you

`#[derive(...)]` is a macro that **writes an `impl` block** for you, field by field. It only
works for traits with an obvious, mechanical implementation. Here's what each one generates and
what it means for the CRM:

| Derive | What it generates | What it promises / allows |
|---|---|---|
| `Debug` | `fmt` that prints `CompanyId(3)` / `Company { id: .., name: .. }` | `{:?}`, `dbg!`, `assert_eq!` output. For developers. |
| `Clone` | `.clone()` calling `.clone()` on every field | An explicit, possibly expensive copy. |
| `Copy` | Nothing new to call: it's a **marker** saying "a bitwise copy is a valid copy" | Assignment and passing by value **copy** instead of move. Only allowed if every field is `Copy` (no `String`, no `Vec`). Requires `Clone`. |
| `PartialEq` | `==` comparing every field | Equality might not be reflexive (`f64::NAN != f64::NAN`). |
| `Eq` | Nothing to call: a **marker** on top of `PartialEq` | "`a == a` is always true." Required by `HashMap` keys. |
| `Hash` | Hashes every field | Must agree with `Eq`: equal values hash equally. Derive both and you get that for free. |
| `PartialOrd` | `<`, `>`, `partial_cmp`, comparing fields **in declaration order** (for enums: **variant order**) | Some pairs may be incomparable (again, `NAN`). |
| `Ord` | `cmp`: a **total** order | Required by `sort()`, `sort_by_key`, `BTreeMap` keys, `.max()`. |
| `Default` | `default()` calling `Default::default()` on every field (enums: `#[default]` variant) | `..Default::default()` struct updates. You'll derive it in Lab 17. |

> 🟢 **FOLLOW ALONG**: update the id derives in both model files:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CompanyId(pub u64);
```

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ContactId(pub u64);
```

And let `Lifecycle` be compared fully and used as a map key (you'll count companies per stage in
Lab 17):

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lifecycle {
    Prospect,
    Customer,
    Churned,
}
```

`Ord` on ids means "sort contacts by id" is just `sort_by_key(|c| c.id)` (Lab 17). Ordering
`Lifecycle` alphabetically or by pipeline position is a *business* decision, so we don't derive
`Ord` on it.

> 🟡 **EXPERIMENT**: remove `Hash` from `CompanyId`'s derive list. Where do you expect the error:
> on the struct, at a `HashMap`, or somewhere else? Run `cargo check`.

```text
error[E0277]: the trait bound `CompanyId: Hash` is not satisfied
  --> src/companies/model.rs:74:15
   |
74 |     type Id = CompanyId;
   |               ^^^^^^^^^ the trait `Hash` is not implemented for `CompanyId`
   |
note: required by a bound in `Entity::Id`
  --> src/entity.rs:9:26
   |
 9 |     type Id: Copy + Eq + Hash + Debug;
   |                          ^^^^ required by this bound in `Entity::Id`
help: consider annotating `CompanyId` with `#[derive(Hash)]`
   |
 5 + #[derive(Hash)]
 6 | pub struct CompanyId(pub u64);
   |
```

The bounds on the associated type are checked **at the impl**: `Company` can't be an `Entity`
whose id isn't hashable. The trait author (you) set a rule and the compiler enforces it for every
implementor, forever. Put `Hash` back.

---

## Step 5 — `Display` vs `Debug`

Both are formatting traits. They answer different questions:

| | `Debug` (`{:?}`) | `Display` (`{}`) |
|---|---|---|
| Audience | Developers: logs, test failures, `dbg!` | Users: the CRM's output |
| Derivable? | Yes | **No.** There is no mechanical "right" way to show a value to a human, so you must decide. |
| Example | `CompanyId(3)` | `#3` |

Ids first. Add to `src/companies/model.rs` (and the same for `ContactId` in
`src/contacts/model.rs`):

> 🟢 **FOLLOW ALONG**

```rust
use std::fmt;   // at the top

impl fmt::Display for CompanyId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad(&format!("#{}", self.0))
    }
}
```

Then replace `Lifecycle::label` with `Display`. Delete the whole `label` method and add:

```rust
impl fmt::Display for Lifecycle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            Lifecycle::Prospect => "prospect",
            Lifecycle::Customer => "customer",
            Lifecycle::Churned => "churned",
        };
        f.pad(text)
    }
}
```

And replace `Company::summary` with a `Display` impl that prints one table row. Delete
`summary` and add:

```rust
impl fmt::Display for Company {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let website = self.website.as_deref().unwrap_or("-");
        write!(
            f,
            "{:<4} {:<20} {:<9} {}",
            self.id, self.name, self.lifecycle, website
        )
    }
}
```

Now run `cargo check`. You've deleted two methods, so the compiler hands you a **to-do list**:

```text
error[E0599]: no method named `summary` found for reference `&Company` in the current scope
  --> src/cli/commands.rs:36:40
   |
36 |                 println!("{}", company.summary());
   |                                        ^^^^^^^ method not found in `&Company`

error[E0599]: no method named `summary` found for reference `&Company` in the current scope
  --> src/cli/commands.rs:41:36
   |
41 |             println!("{}", company.summary());
   |                                    ^^^^^^^ method not found in `&Company`

error[E0599]: no method named `label` found for enum `Lifecycle` in the current scope
  --> src/cli/commands.rs:52:64
   |
52 |             println!("Company #{} is now {}.", id.0, lifecycle.label());
   |                                                                ^^^^^ method not found in `Lifecycle`
   |
  ::: src/companies/model.rs:17:1
   |
17 | pub enum Lifecycle {
   | ------------------ method `label` not found for this enum
   |
   = help: items from traits can only be used if the trait is implemented and in scope
note: `Entity` defines an item `label`, perhaps you need to implement it
  --> src/entity.rs:7:1
   |
 7 | pub trait Entity {
   | ^^^^^^^^^^^^^^^^
```

(The last `note` is the compiler noticing that *a trait* has a `label` method. Not what we want
here, but it shows the compiler searches traits in scope when a method is missing.)

Work through it: `company.summary()` becomes just `company` (`println!("{company}")`, in both
`company list` and `company show`), and the stage message becomes:

```rust
println!("Company {id} is now {lifecycle}.");
```

(`id` now displays itself as `#2`.) While you're there, change the other `#{}` + `id.0`
messages (`Added company #{}`, `Added contact #{}`, `Updated contact #{}`) to use `{id}`
directly. In `src/errors.rs`, `HasContacts` can now say
`write!(f, "company {id} still has contacts; delete them first")`. (While you're in
`errors.rs`: `DuplicateEmail` still says "a customer with email ..." from Lab 12. Make it
`"a contact with email {email} already exists"`.) Keep going until
`cargo check` is clean. Lifecycle's `parse` is still there; Step 7 replaces it.

`cargo check` doesn't compile tests, but `cargo test` does, and the Lab 14 tests in
`src/companies/model.rs` still call `summary()` and `label()`. Delete the
`summary_shows_website_when_present` and `lifecycle_parse_and_label_round_trip` tests (Step 7
writes a better round-trip test), and remove the `summary()` assertion from
`new_companies_are_prospects`.

### Why `f.pad` and not `write!`?

`{:<4}` means "left-align in a column 4 characters wide". That instruction travels to your
`fmt` method **inside the `Formatter`**. `write!(f, ...)` ignores it and writes straight
through; `f.pad(s)` reads the width, alignment and fill from the formatter and applies them to
`s`.

> 🟡 **EXPERIMENT**: change `CompanyId`'s body to `write!(f, "#{}", self.0)`, add two
> companies, and run `company list` (after Step 6, or with `println!("{company}")` now). Predict
> what the table looks like.

```text
ID   NAME                 STAGE     WEBSITE
#1 Acme Corp            prospect  acme.io
#2 Globex               prospect  globex.com
```

The id column collapsed: `{:<4}` was silently ignored. It's not a compile error; nothing
checks that your `Display` honours padding. This is exactly the kind of thing to pin down with a
test. Restore `f.pad` and add to the existing `tests` module in `src/companies/model.rs`:

```rust
    #[test]
    fn company_id_displays_with_hash() {
        assert_eq!(CompanyId(3).to_string(), "#3");
        assert_eq!(format!("[{:<4}]", CompanyId(3)), "[#3  ]");
    }
```

`.to_string()` comes free with `Display`: the standard library has
`impl<T: Display + ?Sized> ToString for T`, a **blanket implementation** covering every type
that implements `Display`. You implement one trait and receive another.

---

## Step 6 — Trait bounds in your own functions: `print_table`

Printing a list as a table means "print a header, then each row". It doesn't care whether rows
are companies or contacts, only that each row can be displayed. That's a trait bound.

> 🟢 **FOLLOW ALONG**: in `src/cli/commands.rs`:

```rust
use std::fmt::Display;   // at the top

const COMPANY_HEADER: &str = "ID   NAME                 STAGE     WEBSITE";

/// Prints a header line followed by one line per row.
/// Works for any slice whose elements implement `Display`.
fn print_table(header: &str, rows: &[impl Display]) {
    println!("{header}");
    for row in rows {
        println!("{row}");
    }
}
```

`rows: &[impl Display]` is **`impl Trait` in argument position**. It's shorthand for a generic
parameter: `fn print_table<R: Display>(header: &str, rows: &[R])`. Same meaning, same compiled
code. The shorthand is nice when you'd only mention the type once; the named form is
needed when you'd mention it twice or want callers to be able to name it.

Use it in `company list`:

```rust
        CompanyCommand::List => {
            if crm.companies.is_empty() {
                println!("No companies yet.");
            } else {
                print_table(COMPANY_HEADER, crm.companies.all());
            }
        }
```

and in `company show`, printing the company as a one-row table followed by a blank line. Leave
the contact lines as they are (still `contact.summary()`) for now:

```rust
            let company = crm.company(id)?;
            print_table(COMPANY_HEADER, &[company]);
            println!();
            let contacts = crm.contacts_of(id);
```

Note `&[company]`: `company` is a `&Company`, so `[company]` is an array of one `&Company`.
Does `&Company` implement `Display`? Yes, through another blanket impl:
`impl<T: Display + ?Sized> Display for &T`. References display as whatever they point at.

> 🟡 **EXPERIMENT**: in `company show`, replace the contact `for` loop with
> `print_table("contacts", &contacts);`. `contacts` is a `Vec<&Contact>`. Predict the error, then
> `cargo check`.

```text
error[E0277]: `Contact` doesn't implement `std::fmt::Display`
  --> src/cli/commands.rs:59:38
   |
59 |             print_table("contacts", &contacts);
   |             -----------              ^^^^^^^^ unsatisfied trait bound
   |             |
   |             required by a bound introduced by this call
   |
help: the trait `std::fmt::Display` is not implemented for `Contact`
  --> src/contacts/model.rs:20:1
   |
20 | pub struct Contact {
   | ^^^^^^^^^^^^^^^^^^
   = note: required for `&Contact` to implement `std::fmt::Display`
note: required by a bound in `print_table`
  --> src/cli/commands.rs:18:43
   |
18 | fn print_table(header: &str, rows: &[impl Display]) {
   |                                           ^^^^^^^ required by this bound in `print_table`
```

Look at the `note`: "required for `&Contact` to implement `Display`". The compiler tried the
blanket `impl Display for &T`, which needs `T = Contact` to be `Display`, and it isn't. That's
**Your Turn 2**. Undo the experiment for now.

### A bound on an associated type: `print_deleted`

Delete confirmations look the same for every entity: `Deleted company #1 (Acme Corp)`. Add:

```rust
use crate::entity::Entity;   // at the top

/// Prints "Deleted company #1 (Acme Corp)" for any entity whose id can be displayed.
fn print_deleted<E>(kind: &str, entity: &E)
where
    E: Entity,
    E::Id: Display,
{
    println!("Deleted {kind} {} ({})", entity.id(), entity.label());
}
```

`Entity` only promises `Id: Copy + Eq + Hash + Debug`, not `Display`. This function needs
more, so it **asks for more**, on the associated type, in a `where` clause. `where` is just a
roomier place to write bounds; Lab 16 uses it a lot. Use it in both delete commands:

```rust
            let company = crm.remove_company(id)?;
            print_deleted("company", &company);
```

```rust
            let contact = crm.remove_contact(id)?;
            print_deleted("contact", &contact);
```

### The orphan rule

Contacts have `company_id: Option<CompanyId>`. It would be convenient to write
`println!("{}", contact.company_id)` and get `#1` or `-`.

> 🟡 **EXPERIMENT**: add this to `src/contacts/model.rs` and run `cargo check`.

```rust
impl fmt::Display for Option<CompanyId> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Some(id) => write!(f, "{id}"),
            None => write!(f, "-"),
        }
    }
}
```

```text
error[E0117]: only traits defined in the current crate can be implemented for types defined outside of the crate
   --> src/contacts/model.rs:168:1
    |
168 | impl fmt::Display for Option<CompanyId> {
    | ^^^^^^^^^^^^^^^^^^^^^^-----------------
    |                       |
    |                       `Option` is not defined in the current crate
    |
    = note: impl doesn't have any local type before any uncovered type parameters
    = note: for more information see https://doc.rust-lang.org/reference/items/implementations.html#orphan-rules
    = note: define and implement a trait or new type instead
```

**The orphan rule:** to write `impl Trait for Type`, either the trait or the type must be
defined in your crate. `Display` belongs to `std`, `Option` belongs to `std`, so this impl would
be an "orphan" with no home crate. Why the rule exists: if your crate and some other crate
*both* implemented `Display for Option<CompanyId>`, the compiler couldn't pick one; worse, the
standard library could add such an impl in a future release and break your code. The rule
guarantees there is at most **one** impl of a trait for a type, anywhere.

What *is* allowed:

| impl | Allowed? | Why |
|---|---|---|
| `impl Display for CompanyId` | ✅ | Local type |
| `impl Entity for Company` | ✅ | Local trait and type |
| `impl Validate for String` | ✅ | Local trait (you'll write `Validate` in Step 8) |
| `impl Display for Option<CompanyId>` | ❌ | Foreign trait, foreign type (`Option`). Wrapping a local type inside doesn't make `Option` local. |

The fixes the compiler suggests: a **new type** (a local wrapper struct) or a **local trait**.
Here neither is worth it. A `match` where you format the row is simplest; you'll write it in
Your Turn 2. Delete the experiment.

---

## Step 7 — Conversion traits: `From`, `TryFrom`, `FromStr`

The standard library defines a handful of conversion traits. Implementing them isn't about
saving keystrokes: **other code is written against them**, so implementing them plugs your types
into that code.

| Trait | Signature | Use when | What you get for free |
|---|---|---|---|
| `From<T>` | `fn from(T) -> Self` | Conversion **can't fail** | `Into<Self> for T` (blanket impl), and `?` uses it to convert errors |
| `TryFrom<T>` | `fn try_from(T) -> Result<Self, Self::Error>` | Conversion **can fail** | `TryInto<Self> for T` |
| `FromStr` | `fn from_str(&str) -> Result<Self, Self::Err>` | Parsing **text** | `"...".parse::<Self>()` |

### `From<u64>` for the ids

> 🟢 **FOLLOW ALONG**: in `src/companies/model.rs` (and the same for `ContactId`):

```rust
impl From<u64> for CompanyId {
    fn from(raw: u64) -> Self {
        CompanyId(raw)
    }
}
```

Now `CompanyId::from(3)` works, **and so does** `let id: CompanyId = 3.into();`. You never
implemented `Into`. The standard library contains:

```rust
impl<T, U> Into<U> for T where U: From<T> {
    fn into(self) -> U { U::from(self) }
}
```

"For any `T` and `U`: if `U` can be made `From` a `T`, then `T` can be turned `Into` a `U`." So
the rule is: **implement `From`, use `Into`** (in function arguments: `fn f(x: impl Into<CompanyId>)`).

This impl looks trivial now, since `CompanyId(3)` already works. It becomes essential in Lab 16:
a generic repository that knows nothing about `CompanyId` will need a way to turn its `u64`
counter into "whatever the id type is". It'll ask for `T::Id: From<u64>`.

In `src/cli/commands.rs`, `read_company_id` (used by `contact add`) builds a company id from
user input. Make it use the conversion:

```rust
    let id: u64 = input
        .parse()
        .map_err(|_| CrmError::Usage("company id must be a number (or blank for none)"))?;
    Ok(Some(CompanyId::from(id)))
```

Notice the new `: u64` annotation. Before, `CompanyId(id)` told the compiler that `id` is a `u64`
(that's the field's type). `CompanyId::from(id)` doesn't: as far as inference knows, *any* `T`
with a `From<T> for CompanyId` impl would do (there are two: yours, and the standard library's
`From<CompanyId> for CompanyId`). Leave the annotation out and you get a confusing E0277 about
`From<!>`. When a conversion is generic, tell the compiler the source type.

### `TryFrom<&str>` for `Email`

Email parsing can fail, so it's `TryFrom`, not `From`. Move the body of `Email::parse` into the
trait impl, and keep `parse` as a thin, readable wrapper (other code calls `Email::parse`, and
it reads well). Leave the rest of the file alone: the doc comments and their `compile_fail`
doc tests, `as_str`, `domain` and the existing tests all stay.

> 🟢 **FOLLOW ALONG**: `src/contacts/email.rs`. Change the derive line, the body of `parse`, and
> add two impls below `impl Email`:

```rust
use std::fmt;   // at the top

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Email(String);

impl Email {
    // ...doc comment with the doc test stays as it is...
    pub fn parse(input: &str) -> Result<Email, ValidationError> {
        Email::try_from(input)
    }

    // ...as_str and domain stay as they are...
}

impl TryFrom<&str> for Email {
    type Error = ValidationError;

    fn try_from(input: &str) -> Result<Self, Self::Error> {
        // ↓ your existing Email::parse body goes here, unchanged ↓
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
}

impl fmt::Display for Email {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad(&self.0)
    }
}
```

(Only the *location* of the validation moves. The rules are the Lab 12 ones.)

Three small decisions in there:

- `type Error = ValidationError;` is an associated type again: one conversion, one error type.
- `Email` also derives `Eq, Hash` now. Emails are natural lookup keys.
- `Display` for `Email` uses `f.pad`, so a contact row can put the email in a `{:<24}` column.

Add a test to the existing `tests` module in `email.rs` that both spellings agree:

```rust
    #[test]
    fn try_from_and_try_into_agree() {
        let a = Email::try_from("Ada@Example.com").unwrap();
        let b: Email = "ada@example.com".try_into().unwrap();
        assert_eq!(a, b);
        assert_eq!(a.to_string(), "ada@example.com");
    }
```

### `FromStr` for `Lifecycle`

First, `Lifecycle` needs an error for "that's not a stage". Add two variants to
`ValidationError` in `src/errors.rs` (the second one is for Step 8):

```rust
#[derive(Debug, PartialEq)]
pub enum ValidationError {
    EmptyName,
    InvalidEmail(String),
    InvalidPhone(String),
    InvalidWebsite(String),
    InvalidLifecycle(String),
}
```

and their messages in `impl fmt::Display for ValidationError`:

```rust
            ValidationError::InvalidWebsite(w) => write!(f, "invalid website: {w}"),
            ValidationError::InvalidLifecycle(s) => write!(
                f,
                "invalid lifecycle '{s}' (expected prospect, customer or churned)"
            ),
```

Then, in `src/companies/model.rs`, **delete `Lifecycle::parse`** and add:

```rust
use std::str::FromStr;                     // at the top
use crate::errors::ValidationError;        // at the top

impl FromStr for Lifecycle {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_lowercase().as_str() {
            "prospect" => Ok(Lifecycle::Prospect),
            "customer" => Ok(Lifecycle::Customer),
            "churned" => Ok(Lifecycle::Churned),
            _ => Err(ValidationError::InvalidLifecycle(s.to_string())),
        }
    }
}
```

Now the parser. In `parse_company`, the `company stage` arm used `Lifecycle::parse`:

```rust
        ("stage", [id, stage]) => CompanyCommand::Stage {
            id: CompanyId(parse_id(id)?),
            lifecycle: Lifecycle::parse(stage).ok_or(CrmError::Usage(COMPANY_USAGE))?,
        },
```

Replace the `lifecycle` line with:

```rust
            lifecycle: stage.parse()?,
```

That one short line uses **both** payoffs:

1. **`.parse()` uses `FromStr`.** `str::parse` is defined as
   `fn parse<F: FromStr>(&self) -> Result<F, F::Err>`. The field it's assigned to,
   `lifecycle: Lifecycle` in `CompanyCommand::Stage`, tells it which `F`, and your impl is what
   runs.
2. **`?` uses `From`.** `parse()` returns `Result<Lifecycle, ValidationError>`, but
   `parse_command` returns `Result<_, CrmError>`. On an `Err(e)`, `?` doesn't return `e`, it
   returns `From::from(e)`. Your Lab 12 `impl From<ValidationError> for CrmError` is what makes
   this compile.

A user who types `company stage 2 won` now gets a precise message instead of a generic usage
line, and you wrote no code to connect the two error types here.

That change of behaviour breaks one Lab 14 test: `malformed_commands_return_usage_errors` in
`src/cli/parser.rs` lists `"company stage 1 vip"` as a usage error, and it's now a validation
error. Remove that line from the list and pin the new behaviour with its own test (add
`use crate::errors::ValidationError;` inside the `tests` module):

```rust
    #[test]
    fn unknown_stage_is_a_validation_error() {
        assert!(matches!(
            parse_command("company stage 1 vip"),
            Err(CrmError::Validation(ValidationError::InvalidLifecycle(_)))
        ));
    }
```

Add a round-trip test to the `tests` module in `src/companies/model.rs`: every lifecycle, shown
with `Display` and parsed back with `FromStr`, should come back unchanged.

```rust
    #[test]
    fn lifecycle_round_trips_through_display_and_from_str() {
        for lifecycle in [Lifecycle::Prospect, Lifecycle::Customer, Lifecycle::Churned] {
            let text = lifecycle.to_string();
            assert_eq!(text.parse::<Lifecycle>(), Ok(lifecycle));
        }
    }

    #[test]
    fn lifecycle_parse_rejects_unknown_stage() {
        assert_eq!(
            "won".parse::<Lifecycle>(),
            Err(ValidationError::InvalidLifecycle("won".to_string()))
        );
    }
```

### Break the payoff on purpose

> 🟡 **EXPERIMENT 1**: temporarily delete `impl From<ValidationError> for CrmError` from
> `src/errors.rs`. How many places do you think break? Run `cargo check`.

```text
error[E0277]: `?` couldn't convert the error to `CrmError`
  --> src/cli/commands.rs:89:57
   |
85 | fn contact(crm: &mut Crm, command: ContactCommand) -> Result<(), CrmError> {
   |                                                       -------------------- expected `CrmError` because of this
...
89 |             let email = Email::parse(&prompt("Email: "))?;
   |                         --------------------------------^ the trait `From<ValidationError>` is not implemented for `CrmError`
   |                         |
   |                         this can't be annotated with `?` because it has type `Result<_, ValidationError>`
   |
note: `CrmError` needs to implement `From<ValidationError>`
  --> src/errors.rs:40:1
   |
40 | pub enum CrmError {
   | ^^^^^^^^^^^^^^^^^
   = note: the question mark operation (`?`) implicitly performs a conversion on the error value using the `From` trait
```

…and seven more: the other `Email::parse(...)?` in `update_contact`, every `clean_name(..)?` and
`clean_phone(..)?` in `crm.rs`, and a strange one on the `.parse()?` line:

```text
error[E0271]: type mismatch resolving `<Lifecycle as FromStr>::Err == CrmError`
  --> src/cli/parser.rs:67:30
   |
67 |             lifecycle: stage.parse()?,
   |                              ^^^^^ type mismatch resolving `<Lifecycle as FromStr>::Err == CrmError`
```

That's type inference working backwards: without a `From` conversion available, the only way
`?` could work is if `parse()` already produced a `CrmError`, so the compiler went looking for a
`FromStr` impl whose `Err` is `CrmError` and didn't find one. The last `note` of the first error
is the sentence to remember: **`?` performs a conversion using the `From` trait.** Restore the impl.

> 🟡 **EXPERIMENT 2**: temporarily comment out `impl FromStr for Lifecycle`.

```text
error[E0277]: the trait bound `Lifecycle: FromStr` is not satisfied
  --> src/cli/parser.rs:67:30
   |
67 |             lifecycle: stage.parse()?,
   |                              ^^^^^ unsatisfied trait bound
   |
help: the trait `FromStr` is not implemented for `Lifecycle`
  --> src/companies/model.rs:25:1
   |
25 | pub enum Lifecycle {
   | ^^^^^^^^^^^^^^^^^^
   = help: the following other types implement trait `FromStr`:
             ByteString
             CString
             IpAddr
             Ipv4Addr
             Ipv6Addr
             NonZero<i128>
             NonZero<i16>
             NonZero<i32>
           and 32 others
```

`parse` is a generic method with an `F: FromStr` bound, and the compiler helpfully lists the
types that *do* qualify. Your type joins that list the moment you implement the trait. Restore it.

---

## Step 8 — `Validate`: a trait with a default method

Right now the "name cannot be empty" check (`clean_name`) is called from `Crm::add_company`, and
the contact checks (`clean_name`, `clean_phone`) from `Crm::add_contact` and
`Crm::update_contact`. Business rules belong to the **type**, so that every path that
creates or changes a company (CLI today, HTTP in Lab 28, CSV import in Challenge C) applies the
same rules.

> 🟢 **FOLLOW ALONG**: add to `src/entity.rs`:

```rust
use crate::errors::ValidationError;   // at the top

/// Business rules a value must satisfy before the CRM accepts it.
pub trait Validate {
    fn validate(&self) -> Result<(), ValidationError>;

    /// A default method: every implementor gets it for free.
    fn is_valid(&self) -> bool {
        self.validate().is_ok()
    }
}
```

`is_valid` has a body, so implementors don't have to write it (they *may* override it). Default
methods can call the trait's required methods: the trait knows `validate` will exist on every
implementor. This is how `Iterator` gives you seventy-odd methods (`map`, `filter`, `sum`, ...)
in exchange for implementing one, `next`. You'll see that in Lab 17.

Now `Company`. In `src/companies/model.rs`:

```rust
use crate::entity::{Entity, Validate};   // replaces the earlier `use crate::entity::Entity;`

impl Validate for Company {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.name.trim().is_empty() {
            return Err(ValidationError::EmptyName);
        }
        if let Some(website) = &self.website
            && (website.chars().any(char::is_whitespace) || !website.contains('.'))
        {
            return Err(ValidationError::InvalidWebsite(website.clone()));
        }
        Ok(())
    }
}
```

The website rule is deliberately loose ("no spaces, has a dot"): `acme.io` passes,
`globex com` doesn't.

Where should `validate` be called? Before a company is stored, so in `CompanyStore::add`. Change
it to build the company, validate it, and only then use up the id and store it:

```rust
use crate::entity::{Validate, find_by_id};   // at the top
use crate::errors::ValidationError;

    pub fn add(
        &mut self,
        name: String,
        website: Option<String>,
    ) -> Result<CompanyId, ValidationError> {
        let company = Company::new(CompanyId(self.next_id), name, website);
        company.validate()?;
        self.next_id += 1;
        let id = company.id;
        self.companies.push(company);
        Ok(id)
    }
```

`let id = company.id;` **before** the push: `push` moves `company` into the vector, and you can't
read a field of a moved value. `CompanyId` is `Copy`, so `id` is an independent copy that
survives the move.

The store returns `ValidationError` (it knows nothing about duplicates or "not found").
`Crm::add_company` returns `CrmError`. Replace its body, including the old `clean_name` call:

```rust
    pub fn add_company(
        &mut self,
        name: String,
        website: Option<String>,
    ) -> Result<CompanyId, CrmError> {
        let id = self.companies.add(name, website)?;
        Ok(id)
    }
```

`?` converts again. (`clean_name` is still used by the contact methods; Your Turn 1 retires it.)
The `CompanyStore` tests now get a `Result` back from `add`: in `src/companies/store.rs`,
compare against `Ok(CompanyId(1))` / `Ok(CompanyId(2))` in `ids_start_at_one_and_increase`, and
add `.unwrap()` after `store.add(...)` in `remove_returns_the_company`. Add a test to
`src/companies/model.rs`:

```rust
    fn company(name: &str, website: Option<&str>) -> Company {
        Company::new(CompanyId(1), name.to_string(), website.map(String::from))
    }

    #[test]
    fn company_validation() {
        assert!(company("Acme", Some("acme.io")).validate().is_ok());
        assert!(company("Acme", None).is_valid());
        assert_eq!(company("   ", None).validate(), Err(ValidationError::EmptyName));
        assert_eq!(
            company("Acme", Some("not a site")).validate(),
            Err(ValidationError::InvalidWebsite("not a site".to_string()))
        );
    }
```

`is_valid()` works on `Company` even though you never wrote it for `Company`. That's the
default method.

---

## Step 9 — A first look at `dyn Trait`

So far every trait use has been **static**: `print_table(COMPANY_HEADER, crm.companies.all())`
compiles to a version of `print_table` specialised for `Company`. The compiler knows the exact
type at every call. (Lab 16 shows you that machinery.) Sometimes you don't know the type at
compile time, or you want *different* types in one collection.

> 🟡 **EXPERIMENT**: in `company show`, after the existing code, try to put the company and its
> contacts into **one** list:

```rust
            let mut rows = vec![company];
            for contact in crm.contacts_of(id) {
                rows.push(contact);
            }
            print_table("-- everything --", &rows);
```

```text
error[E0308]: mismatched types
  --> src/cli/commands.rs:74:27
   |
74 |                 rows.push(contact);
   |                      ---- ^^^^^^^ expected `&Company`, found `&Contact`
   |                      |
   |                      arguments to this method are incorrect
   |
   = note: expected reference `&Company`
              found reference `&Contact`
```

A `Vec<T>` holds values of **one** type `T`, all the same size, side by side in memory. The
first element fixed `T = &Company`.

Now say what you actually mean: "a list of things that can be displayed".

```rust
            let mut rows: Vec<&dyn Display> = vec![company];
```

(This only compiles once `Contact` implements `Display`, which is Your Turn 2. Do this experiment
after Your Turn 2, or just read the output.) With `Display` for `Contact` in place, it compiles
and prints:

```text
-- everything --
#1   Acme Corp            prospect  acme.io
#1   Ada Lovelace         ada@acme.io              555-0100       #1
```

### What `&dyn Display` is in memory

`&Company` is one pointer. `&dyn Display` is **two** pointers, a "fat pointer":

```text
 rows: Vec<&dyn Display>
 ┌─────────────────────────┬─────────────────────────┐
 │ data ptr │ vtable ptr   │ data ptr │ vtable ptr   │
 └────┬─────┴──────┬───────┴────┬─────┴──────┬───────┘
      │            │            │            │
      ▼            ▼            ▼            ▼
  ┌─────────┐  ┌──────────────────┐  ┌─────────┐  ┌──────────────────┐
  │ Company │  │ vtable for       │  │ Contact │  │ vtable for       │
  │ {id,..} │  │ Company: Display │  │ {id,..} │  │ Contact: Display │
  └─────────┘  │  size, align     │  └─────────┘  │  size, align     │
               │  drop            │               │  drop            │
               │  fmt ──► <Company│               │  fmt ──► <Contact│
               │   as Display>::fmt               │   as Display>::fmt
               └──────────────────┘               └──────────────────┘
```

- `vec![company]` with the annotation **coerces** `&Company` into `&dyn Display`: Rust pairs the
  pointer with the address of a **vtable**, a small static table the compiler generated for
  "`Company` as `Display`".
- `println!("{row}")` on a `&dyn Display` reads the `fmt` entry from the vtable and calls through
  it. That's **dynamic dispatch**: one extra pointer lookup per call, and the compiler can't
  inline across it.
- Every element is the same size (two pointers), so a `Vec` can hold them. That's the whole trick.

Note that `print_table(..., &rows)` still compiles: `rows` is a `&[&dyn Display]`, and
`&dyn Display` implements `Display` (the same `&T` blanket impl as before, which allows unsized
`T` thanks to `?Sized`). Generic code and trait objects mix.

### Not every trait can be used this way yet

> 🟡 **EXPERIMENT**: print the label of the company and each contact through `&dyn Entity`:

```rust
            let mut labelled: Vec<&dyn Entity> = vec![company];
            for contact in crm.contacts_of(id) {
                labelled.push(contact);
            }
            for entity in &labelled {
                println!("{}", entity.label());
            }
```

```text
error[E0191]: the value of the associated type `Id` in `Entity` must be specified
  --> src/cli/commands.rs:72:40
   |
72 |             let mut labelled: Vec<&dyn Entity> = vec![company];
   |                                        ^^^^^^
   |
  ::: src/entity.rs:11:5
   |
11 |     type Id: Copy + Eq + Hash + Debug;
   |     --------------------------------- `Id` defined here
   |
help: specify the associated type
   |
72 |             let mut labelled: Vec<&dyn Entity<Id = /* Type */>> = vec![company];
   |                                              +++++++++++++++++
```

A vtable has one `id` function, and that function must return *one* type. So `dyn Entity` alone
isn't a complete type. Try the suggestion with `Entity<Id = CompanyId>`:

```text
error[E0271]: type mismatch resolving `<Contact as Entity>::Id == CompanyId`
  --> src/cli/commands.rs:74:31
   |
74 |                 labelled.push(contact);
   |                               ^^^^^^^ type mismatch resolving `<Contact as Entity>::Id == CompanyId`
   |
note: expected this to be `CompanyId`
  --> src/contacts/model.rs:73:15
   |
73 |     type Id = ContactId;
   |               ^^^^^^^^^
   = note: required for the cast from `&Contact` to `&dyn Entity<Id = CompanyId>`
```

Companies and contacts are different kinds of `Entity`, because they have different id types.
That's the associated type doing its job. Remove the experiments from `company show`.

When to use which:

| You want | Use | Cost |
|---|---|---|
| A function that works for many types, each call with one known type | Generics / `impl Trait` (`print_table`, `find_by_id`) | None at runtime; one compiled copy per type |
| One collection or variable holding *different* types, decided at runtime | `dyn Trait` (`Vec<&dyn Display>`, `Box<dyn Storage>`) | A vtable lookup per call; the trait must be "dyn compatible" |

You'll use generics heavily in Lab 16, compare `enum` vs `Box<dyn Trait>` in Lab 20, and build
the storage layer on `Box<dyn Storage>` in Lab 23, where "dyn compatibility" gets its full
explanation.

---

## ▶️ Run It

```bash
cargo fmt && cargo clippy && cargo test
cargo run
```

Then type the session below. (Contacts still print with `summary()` until Your Turn 2.)

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> company add
Name: Acme Corp
Website (optional): acme.io
Added company #1
crm> company add
Name: Globex
Website (optional): globex com
Error: invalid website: globex com
crm> company add
Name: Globex
Website (optional): globex.com
Added company #2
crm> company stage 2 customer
Company #2 is now customer.
crm> company stage 2 won
Error: invalid lifecycle 'won' (expected prospect, customer or churned)
crm> contact add
Name: Ada Lovelace
Email: ada@acme.io
Phone (optional): 555-0100
Company id (blank for none): 1
Added contact #1
crm> contact add
Name: Grace Hopper
Email: grace@navy.mil
Phone (optional): call me
Company id (blank for none):
Error: 'call me' is not a valid phone number
crm> contact add
Name: Grace Hopper
Email: grace@navy.mil
Phone (optional):
Company id (blank for none):
Added contact #2
crm> company list
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  acme.io
#2   Globex               customer  globex.com
crm> contact list
#1 Ada Lovelace <ada@acme.io> 555-0100 @ Acme Corp
#2 Grace Hopper <grace@navy.mil>
Page 1 of 1
crm> company show 1
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  acme.io

  #1 Ada Lovelace <ada@acme.io> 555-0100
crm> contact delete 2
Deleted contact #2 (Grace Hopper <grace@navy.mil>)
crm> company delete 1
Error: company #1 still has contacts; delete them first
crm> quit
Goodbye! (13 commands this session)
```

Notice that the failed `Globex` didn't use up id `#2`: `CompanyStore::add` validates *before*
incrementing `next_id`. Keep that in mind; it changes in Lab 16. The contact lines still come
from Lab 14's `summary()` and `print_contact_line`; Your Turn 2 replaces them with a table.
The phone is still checked by Lab 14's `clean_phone` in `Crm::add_contact` (that's why the
company id prompt still appears after a bad phone); Your Turn 1 moves that rule onto `Contact`.

## 🧠 Understand It

**The traits you wrote and the traits you implemented.** You *defined* two traits (`Entity`,
`Validate`) and *implemented* five standard ones (`Display`, `From`, `TryFrom`, `FromStr`, and
derived several more). The standard ones matter because **other code is generic over them**:
`println!` over `Display`, `str::parse` over `FromStr`, `?` over `From`, `HashMap` over
`Hash + Eq`, `sort` over `Ord`. Implementing a standard trait is like publishing an API that
the whole ecosystem already knows how to call.

**Blanket impls give you traits you never wrote.** `ToString` (from `Display`), `Into` (from
`From`), `TryInto` (from `TryFrom`), `Display for &T` (from `Display for T`). They're all written
once in `std` as `impl<T: X> Y for T`. That's why implementing `From` is preferred over `Into`:
one impl, two traits.

**Bounds are permissions.** In `find_by_id<E: Entity>`, the bound is what *allows* the body to
call `item.id()` and to compare ids with `==`. In `print_deleted`, `E::Id: Display` is what
allows `{}` on the id. A generic function can do only what its bounds permit. Lab 16 builds on
this.

**Associated vs generic.** `Entity::Id`, `TryFrom::Error`, `FromStr::Err`, `Iterator::Item`: one
per implementation, chosen by the implementor. `From<T>`: many per type, chosen by the caller.

**Static vs dynamic dispatch.** `rows: &[impl Display]` is resolved at compile time. A
`Vec<&dyn Display>` is resolved at runtime through a vtable. Default to generics; reach for
`dyn` when you need a mixed collection or a runtime choice.

**The orphan rule** keeps the trait system *coherent*: for any trait and type, there's at most
one impl in the whole program, so adding a crate can never make your code ambiguous.

## 🧪 Experiment

> 🟡 **EXPERIMENT**: remove `Copy` (keep `Clone`) from `ContactId`'s derive list. Predict which
> line fails first: the `Entity` impl, `find_by_id`, or a command that uses an id twice? Run
> `cargo check`, read the error, then explain in one sentence why the trait author decided ids
> must be `Copy`.

> 🟡 **EXPERIMENT**: in `Lifecycle`'s `Display`, replace `f.pad(text)` with
> `write!(f, "{text}")`. Which test catches it? If none does, write one (hint: format a lifecycle
> into a `{:<9}` column and compare against a string with trailing spaces).

> 🟡 **EXPERIMENT**: override the default method. In `impl Validate for Company`, add your own
> `fn is_valid(&self) -> bool { true }`. Does it compile? Does `company_validation` still pass?
> What does that tell you about who controls a default method? Remove the override afterwards.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `Validate` for `Contact`**
>
> Implement `Validate` for `Contact` in `src/contacts/model.rs`, then make the stores and `Crm`
> use it instead of the ad-hoc checks.
>
> Rules, checked in this order (the same rules Lab 12's `parse_phone` enforces):
> 1. `name.trim()` empty → `ValidationError::EmptyName`
> 2. `phone` is `Some(p)` and `p` contains any character other than ASCII digits, space, `+`,
>    `-`, `(`, `)` → `ValidationError::InvalidPhone(p)` (the phone as typed)
> 3. `phone` is `Some(p)` and `p` contains **fewer than 7** digits (e.g. `"12345"`, `"---"`) →
>    `ValidationError::InvalidPhone(p)`
>
> Wiring:
> - `ContactStore::add` builds the `Contact`, calls `validate()?`, and only then increments
>   `next_id` and pushes (same pattern as `CompanyStore::add`). It returns
>   `Result<ContactId, ValidationError>`.
> - Delete the `clean_name` / `clean_phone` calls from `Crm::add_contact`. The company-exists and
>   duplicate-email checks stay in `Crm` (a contact can't know about other records).
> - `Crm::update_contact` must validate the **result** of the update *before* changing the stored
>   contact: if the new phone is invalid, the stored contact is left completely unchanged.
> - When nothing calls `clean_name` and `clean_phone` any more, delete them. (`parse_phone` in
>   `contacts/model.rs` can stay; nothing in the CRM needs it after this.)

- [ ] `contact add` with phone `call me` prints `Error: 'call me' is not a valid phone number`
- [ ] `contact add` with a blank name prints `Error: name cannot be empty`
- [ ] `contact update 1` with new phone `???` prints the error, and `contact show 1` shows the
      old phone
- [ ] tests: a valid contact passes; a blank name fails; `"call me"`, `"12345"`, `"---"` and
      `""` all fail with `InvalidPhone`
- [ ] `cargo test` passes (the Lab 14 `Crm` tests, including `blank_names_are_rejected`, still
      pass unchanged)

> 🔵 **YOUR TURN 2: `Display` for `Contact`**
>
> Implement `fmt::Display for Contact` so a contact prints as one row that lines up under this
> header (add it as a constant next to `COMPANY_HEADER`):
>
> ```rust
> const CONTACT_HEADER: &str =
>     "ID   NAME                 EMAIL                    PHONE          COMPANY";
> ```
>
> Columns: id left-aligned width 4, name width 20, email width 24, phone width 14 (`-` when
> there's none), then the company id as `#2` or `-` when there's none. One space between
> columns, no trailing spaces after the last column.
>
> Then use `print_table(CONTACT_HEADER, ...)` in `contact list` (keep the `Page 1 of 1` footer),
> `contact show` (keep the phone / domain / initials lines under the table), `contact search`
> and `company show`, and **delete `Contact::summary`** and `print_contact_line` (the COMPANY
> column replaces its `@ Acme Corp`). `update_contact`'s `Editing ...` line can use the
> contact's `label()`.

- [ ] `Contact { id: ContactId(1), name: "Ada Lovelace", email: "ada@example.com", phone: Some("555-0100"), company_id: Some(CompanyId(2)) }`
      displays exactly as
      `#1   Ada Lovelace         ada@example.com          555-0100       #2`
- [ ] with no phone and no company:
      `#1   Ada Lovelace         ada@example.com          -              -`
- [ ] `contact list` prints the header and one row per contact
- [ ] `Contact::summary` no longer exists (fix the Lab 14 tests in `contacts/model.rs` that
      used it); `cargo clippy` shows no warnings
- [ ] a test asserts both strings above

> 🔵 **YOUR TURN 3: one `parse_id` for every id type**
>
> Your parser has a helper that parses a `u64` and the call sites wrap it:
> `id: CompanyId(parse_id(id)?)`. Make the helper **generic over the id type** so call sites
> become `id: parse_id(id)?` and the compiler works out which id type to build from the enum
> field it's assigned to.
>
> Keep the helper's argument (`raw: &str`) and its usage message. Change only the type
> parameter, bound, return type and body.

- [ ] no call site in `parser.rs` mentions `CompanyId(` or `ContactId(` any more (the tests
      still do, and that's fine)
- [ ] `company show abc` still prints the usage error
- [ ] the existing parser tests pass unchanged

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `Validate for Company` is your template. For the phone, iterate
> over `phone.chars()` and use `.all(...)` for rule 2 and `.filter(...).count()` for rule 3.

<details><summary>Hint 2 (more specific)</summary>

For `update_contact`: get a `&mut Contact` with `find_mut`, `.clone()` it into a local `updated`, apply the
changes to `updated`, call `updated.validate()?`, and only then write it back with
`*contact = updated;`. If `validate` fails, `?` returns early and the stored contact was never
touched. Cloning one contact is cheap; a half-applied update is not.

</details>

> 💡 **HINT (Your Turn 2)**: copy the shape of `Display for Company`. You'll need a value for the
> company column that is either `#2` or `-`. You found out in Step 6 that you can't implement
> `Display` for `Option<CompanyId>`.

<details><summary>Hint 2 (more specific)</summary>

A `match self.company_id { Some(id) => id.to_string(), None => String::from("-") }` gives you a
`String` for the last column. `self.phone.as_deref().unwrap_or("-")` turns an
`Option<String>` into a `&str`. `self.email` can go straight into `{:<24}` because `Email`'s
`Display` uses `f.pad`.

</details>

> 💡 **HINT (Your Turn 3)**: the conversion you need is the `From<u64>` you implemented in Step 7.
> Which bound lets a generic function call `Id::from(n)`?

<details><summary>Hint 2 (more specific)</summary>

`fn parse_id<Id: From<u64>>(raw: &str) -> Result<Id, CrmError>`.
In the body, `Result::map` can apply `Id::from` to the parsed number.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Your `Contact` has a public `id: ContactId` field. Why doesn't that make it an `Entity`?
   What would TypeScript do differently?
2. Why is `Entity::Id` an associated type, while `From<T>` takes a type parameter? Give a CRM
   example where a type parameter is clearly right.
3. Every bound on `type Id` (`Copy + Eq + Hash + Debug`) exists for a reason. Pick two and say
   which code would fail to compile without them.
4. You never implemented `Into<CompanyId> for u64`, yet `let id: CompanyId = 3.into();` compiles.
   Explain the mechanism.
5. In `let lifecycle: Lifecycle = arg.parse()?;`, which trait does `.parse()` use, and which trait
   does `?` use? Which `impl`s did *you* write to make each one work?
6. Why can't you `impl Display for Option<CompanyId>`, but you can `impl Display for CompanyId`?
7. What are the two pointers inside a `&dyn Display`? Why can a `Vec<&dyn Display>` hold a
   company and a contact when a `Vec<&Company>` can't?
8. Why does `Display` use `f.pad` while `write!` would compile just as well?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

```bash
git add .
git commit -m "Add Entity and Validate traits"
git tag lab-15
git push && git push --tags
```

Look at what changed: `git diff lab-14 lab-15 --stat`. Most of the diff is *additions* in model
files and *deletions* in `crm.rs` and `commands.rs`. Behaviour moved onto the types.

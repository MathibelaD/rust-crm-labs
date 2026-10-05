# Lab 14 — Companies & Contacts: Relationships in Rust ♻️

> **Phase:** 3 — Modelling the Domain · **Builds on:** Lab 13 · **Time:** ~6–7 hours
> **Your repo before this lab:** tag `lab-13` · **After:** tag `lab-14`

> This lab rewrites the CLI's commands, so it doesn't depend on Lab 13's Your Turns. If you did
> Lab 13's Your Turn 3 (`examples/seed.rs`), you'll delete that file in Step 13.

## 🎯 Goal

Fix the CRM's data model. "Customer" becomes two entities: a **Company** (an organisation with a
lifecycle: prospect → customer → churned) and a **Contact** (a person, who may work at a
company). Along the way, try the three ways Rust can express "this contact works at that
company", and learn why real Rust applications almost always pick the third.

## 🧠 What You'll Learn

- Why a relationship between two values is an **ownership** question in Rust
- Attempt 1, references: `Contact<'a> { company: &'a Company }`, and how lifetimes spread
- `Box<T>`: single ownership on the heap, recursive types, and why it doesn't help here
- Attempt 2, shared ownership: `Rc<T>`, `RefCell<T>`, runtime borrow checking, a real
  `BorrowMutError` panic, reference cycles and memory leaks, `Weak<T>`
- Attempt 3, **IDs and lookups**: the design databases use, and the one we keep
- **Newtype IDs** (`CompanyId(u64)`, `ContactId(u64)`) and the bug class they eliminate
- A `Crm` type that owns all the data and all the business rules, and the rule
  *"the CLI only parses, prompts and prints"*

## 🔨 What We're Building

Ask a B2B sales team who their "customer" is and they'll name an organisation, Acme Corp, not
Ada. Ada is a **contact** at Acme: one of several people you email and call. And "customer" isn't
even a kind of thing. It's a **stage** a company reaches: first a prospect, then a customer
(once they buy), maybe later churned.

Our `Customer` struct mixes all of that up. It has a person's name and email *and* a status that
really belongs to an organisation. This lab is a deliberate **domain refactor**:

```text
Before (Labs 04–13)                  After (this lab onwards)

Customer                             Company                     Contact
  id: u32                              id: CompanyId               id: ContactId
  name          (a person)             name   (an organisation)    name, email, phone
  email, phone                         website: Option<String>     company_id: Option<CompanyId>
  status: Prospect/Active/Churned      lifecycle: Prospect/        ────────────────▶ points at a Company
                                                  Customer/Churned
```

There will be **no `customers/` folder** at the end. "Customer" survives only as
`Lifecycle::Customer`, a stage of a company. That isn't a renaming exercise; it's what the
business actually means, and every later entity (deals, leads, activities) builds on it.

The CLI gets two-word commands:

```text
crm> company add
Name: Acme Corp
Website (optional): https://acme.example
Added company #1
crm> contact add
Name: Ada Lovelace
Email: ada@acme.example
Phone (optional): 555-0100
Company id (blank for none): 1
Added contact #1
crm> company show 1
#1 Acme Corp [prospect] https://acme.example
  #1 Ada Lovelace <ada@acme.example> 555-0100
```

The interesting question is that arrow from `Contact` to `Company`. In JavaScript you'd write
`contact.company = acme` and move on: the garbage collector keeps Acme alive as long as anything
points at it. Rust has no garbage collector. Every value has exactly one owner. So: **who owns
Acme, and what does Ada hold?** Part A tries three answers.

---

## Part A — Three ways to link a contact to a company

We'll experiment in a scratch program that lives in your repo but outside the CRM:
`examples/relationships.rs`. Each file in `examples/` is a small program of its own, run with
`cargo run --example <name>`. It's the right place for exploring designs without disturbing
`src/`.

## Step 1 — Attempt 1: the contact holds a reference

The most direct translation of `contact.company = acme`: Ada **borrows** Acme.

> 🟢 **FOLLOW ALONG**: create `examples/relationships.rs`.

```rust
//! Lab 14: three ways to say "a contact works at a company".
//!
//! Run with: cargo run --example relationships

// ---------------------------------------------------------------------
// Attempt 1: the contact holds a reference to its company.
// ---------------------------------------------------------------------

#[derive(Debug)]
struct Company {
    name: String,
}

#[derive(Debug)]
struct Contact<'a> {
    name: String,
    company: &'a Company,
}

fn attempt_1_references() {
    println!("--- Attempt 1: references ---");
    let mut companies = vec![Company {
        name: String::from("Acme"),
    }];
    companies.push(Company {
        name: String::from("Globex"),
    }); // fine: nobody is borrowing `companies` yet

    let ada = Contact {
        name: String::from("Ada"),
        company: &companies[0],
    };

    // From here until `ada` is last used, `companies` is frozen.
    println!("{} works at {}", ada.name, ada.company.name);
}

fn main() {
    attempt_1_references();
}
```

```bash
cargo run --example relationships
```

```text
--- Attempt 1: references ---
Ada works at Acme
```

It works. `Contact<'a>` is a struct holding a reference, so it needs a lifetime parameter
(Lab 10): "a `Contact` can't outlive the `Company` it points at". Now use it like a CRM would.

> 🟡 **EXPERIMENT**: a new company signs up while Ada exists. Move the `companies.push(...)` for
> Globex to **after** `let ada = ...`. Predict, then run `cargo check --example relationships`.

```text
error[E0502]: cannot borrow `companies` as mutable because it is also borrowed as immutable
  --> examples/relationships.rs:26:5
   |
23 |           company: &companies[0],
   |                     --------- immutable borrow occurs here
...
26 | /     companies.push(Company {
27 | |         name: String::from("Globex"),
28 | |     });
   | |______^ mutable borrow occurs here
29 |
30 |       println!("{} works at {}", ada.name, ada.company.name);
   |                                  -------- immutable borrow later used here
```

Who owns Acme? The `Vec`. What does Ada hold? A shared borrow into the `Vec`. Can the `Vec` be
mutated while that borrow is alive? No. And for a very good reason you met in Lab 07: `push` may
reallocate, which would leave `ada.company` pointing at freed memory.

> 🟡 **EXPERIMENT**: put the push back where it was. Instead, after `let ada = ...`, rename the
> company: `companies[0].name = String::from("Acme Corporation");`

```text
error[E0502]: cannot borrow `companies` as mutable because it is also borrowed as immutable
  --> examples/relationships.rs:26:5
   |
23 |         company: &companies[0],
   |                   --------- immutable borrow occurs here
...
26 |     companies[0].name = String::from("Acme Corporation");
   |     ^^^^^^^^^ mutable borrow occurs here
27 |
28 |     println!("{} works at {}", ada.name, ada.company.name);
   |                                -------- immutable borrow later used here
```

So as long as **any** contact exists, no company can be added, renamed or removed. A CRM where
nothing can change while anyone is looking at it is not much of a CRM. Undo the change.

### And it gets worse: putting it in a struct

A real CRM keeps both lists in one place. Try it (don't keep this code; it's for the errors):

> 🟡 **EXPERIMENT**: add this to the file and call nothing yet.

```rust
struct Directory<'a> {
    companies: Vec<Company>,
    contacts: Vec<Contact<'a>>,
}

impl<'a> Directory<'a> {
    fn add_contact(&mut self, name: &str, company_index: usize) {
        let company = &self.companies[company_index];
        self.contacts.push(Contact {
            name: name.to_string(),
            company,
        });
    }
}
```

```text
error: lifetime may not live long enough
  --> examples/relationships.rs:20:9
   |
17 |   impl<'a> Directory<'a> {
   |        -- lifetime `'a` defined here
18 |       fn add_contact(&mut self, name: &str, company_index: usize) {
   |                      - let's call the lifetime of this reference `'1`
19 |           let company = &self.companies[company_index];
20 | /         self.contacts.push(Contact {
21 | |             name: name.to_string(),
22 | |             company,
23 | |         });
   | |__________^ argument requires that `'1` must outlive `'a`
```

**Read it with the Lab 10 questions.** `company` borrows from `self` for `'1`, the length of this
method call. But `self.contacts` holds `Contact<'a>`, which must stay valid for `'a`, the
lifetime of the whole `Directory`. A borrow that lasts one call can't be stored somewhere that
lasts longer. The "obvious" fix is to promise the borrow lasts for `'a`: change the receiver to
`&'a mut self`. That compiles. Now call it twice:

```rust
    let mut directory = Directory {
        companies: vec![Company { name: String::from("Acme") }],
        contacts: Vec::new(),
    };
    directory.add_contact("Ada", 0);
    directory.add_contact("Grace", 0);
```

```text
error[E0499]: cannot borrow `directory` as mutable more than once at a time
  --> examples/relationships.rs:35:5
   |
34 |     directory.add_contact("Ada", 0);
   |     --------- first mutable borrow occurs here
35 |     directory.add_contact("Grace", 0);
   |     ^^^^^^^^^
   |     |
   |     second mutable borrow occurs here
   |     first borrow later used here
```

`&'a mut self` means "borrow the directory **mutably, for the rest of its life**". After one call
it's locked forever. This is the famous **self-referential struct** problem: a struct can't
safely hold references into itself, because moving or mutating the struct would invalidate them.
Rust doesn't let you express it with plain references at all. Delete the `Directory` experiment.

**Verdict on references:** perfect for *short-lived* views (your `search` returns
`Vec<&Customer>`, and that's exactly right), unusable for *stored* relationships. Every type that
holds a `Contact` would need `<'a>`, and everything that holds *that* would need it too.
Lifetimes spread, and the data freezes.

## Step 2 — A side quest: `Box<T>`

`Box<T>` puts a value on the heap and gives it **one owner**: the box. It's the simplest smart
pointer. It's not obviously relevant yet, but it shows up whenever a type refers to itself.

Say a company can have a parent company (Acme EMEA belongs to Acme Holdings):

```rust
struct OrgUnit {
    name: String,
    parent: Option<OrgUnit>,
}
```

```text
error[E0072]: recursive type `OrgUnit` has infinite size
   --> examples/relationships.rs:200:1
    |
200 | struct OrgUnit {
    | ^^^^^^^^^^^^^^
201 |     name: String,
202 |     parent: Option<OrgUnit>,
    |                    ------- recursive without indirection
    |
help: insert some indirection (e.g., a `Box`, `Rc`, or `&`) to break the cycle
    |
202 |     parent: Option<Box<OrgUnit>>,
    |                    ++++       +
```

To know an `OrgUnit`'s size, the compiler needs the size of an `OrgUnit` inside it, which needs
the size of an `OrgUnit` inside that... `Box<OrgUnit>` is just a pointer (8 bytes), so the size
becomes known. Add the working version to `examples/relationships.rs`:

> 🟢 **FOLLOW ALONG**

```rust
// ---------------------------------------------------------------------
// Side quest: Box gives a value one owner, on the heap.
// ---------------------------------------------------------------------

struct OrgUnit {
    name: String,
    parent: Option<Box<OrgUnit>>,
}

fn box_parent_company() {
    println!("--- Box: parent companies ---");
    let emea = OrgUnit {
        name: String::from("Acme EMEA"),
        parent: Some(Box::new(OrgUnit {
            name: String::from("Acme Holdings"),
            parent: None,
        })),
    };
    let apac = OrgUnit {
        name: String::from("Acme APAC"),
        parent: Some(Box::new(OrgUnit {
            name: String::from("Acme Holdings"),
            parent: None,
        })),
    };
    for unit in [&emea, &apac] {
        if let Some(parent) = &unit.parent {
            println!("{} belongs to {}", unit.name, parent.name);
        }
    }
    println!("(two separate 'Acme Holdings' values: Box owns, it doesn't share)");
}
```

and call `box_parent_company();` from `main`. Notice the punchline: each subsidiary **owns its
own copy** of Acme Holdings. Rename one and the other doesn't change. A `Box` has exactly one
owner, just like any other value. It solves "this type contains itself", not "several things
point at one thing". For sharing, we need something else.

## Step 3 — Attempt 2: shared ownership with `Rc<RefCell<T>>`

Two standard-library types, each solving half the problem:

- **`Rc<T>`** ("reference counted") lets a value have **several owners**. `Rc::clone(&acme)`
  doesn't copy Acme; it makes another handle and increments a counter. When the last handle is
  dropped, the counter hits zero and Acme is dropped. It's the closest thing Rust has to a
  garbage-collected reference. But an `Rc<T>` only gives **shared** (`&T`) access, because with
  several owners, any of them mutating would break aliasing-XOR-mutation.
- **`RefCell<T>`** moves the borrow rules from **compile time** to **runtime**. `.borrow()`
  hands out a shared borrow, `.borrow_mut()` an exclusive one, and the `RefCell` counts them as
  the program runs. Break the rule and it **panics**. This is called *interior mutability*:
  mutation through a shared handle.

Together, `Rc<RefCell<Company>>` means "a company with several owners, any of whom may change it,
one at a time, checked at runtime".

> 🟢 **FOLLOW ALONG**: add to `examples/relationships.rs` (the `use` lines go at the top).

```rust
use std::cell::RefCell;
use std::rc::Rc;

// ---------------------------------------------------------------------
// Attempt 2: shared ownership (Rc) plus runtime-checked mutation (RefCell).
// ---------------------------------------------------------------------

#[derive(Debug)]
struct SharedCompany {
    name: String,
    lifecycle: &'static str,
}

struct SharedContact {
    name: String,
    company: Rc<RefCell<SharedCompany>>,
}

fn attempt_2_rc_refcell() {
    println!("--- Attempt 2: Rc<RefCell<_>> ---");
    let acme = Rc::new(RefCell::new(SharedCompany {
        name: String::from("Acme"),
        lifecycle: "prospect",
    }));

    let ada = SharedContact {
        name: String::from("Ada"),
        company: Rc::clone(&acme),
    };
    let grace = SharedContact {
        name: String::from("Grace"),
        company: Rc::clone(&acme),
    };
    println!("owners of Acme: {}", Rc::strong_count(&acme));

    // Rename once, through any handle; everyone sees it.
    acme.borrow_mut().name = String::from("Acme Corporation");
    for contact in [&ada, &grace] {
        let company = contact.company.borrow();
        println!(
            "{} works at {} ({})",
            contact.name, company.name, company.lifecycle
        );
    }

    let company = ada.company.borrow();
    println!("try_borrow_mut while borrowed: {:?}", ada.company.try_borrow_mut().map(|_| ()));
    drop(company);

    if std::env::args().any(|arg| arg == "--panic") {
        promote_prospects(&[ada, grace]);
    }
}

/// Looks innocent. Panics at runtime.
fn promote_prospects(contacts: &[SharedContact]) {
    for contact in contacts {
        let company = contact.company.borrow();
        if company.lifecycle == "prospect" {
            contact.company.borrow_mut().lifecycle = "customer";
        }
    }
}
```

Call `attempt_2_rc_refcell();` from `main` and run it:

```text
--- Attempt 2: Rc<RefCell<_>> ---
owners of Acme: 3
Ada works at Acme Corporation (prospect)
Grace works at Acme Corporation (prospect)
try_borrow_mut while borrowed: Err(BorrowMutError)
```

This **works**, and it does what the references couldn't: three owners (`acme`, Ada's handle,
Grace's handle), and a rename that everyone sees. If you've used objects in JavaScript, this is
what they feel like.

Now look at `try_borrow_mut`. While `company` (a shared borrow from `.borrow()`) is alive, asking
for an exclusive borrow returns `Err(BorrowMutError)`. That's aliasing-XOR-mutation again, the
same rule as Lab 07. The difference is *when* it's checked.

> 🟡 **EXPERIMENT**: predict what `promote_prospects` will do. Read it carefully: does it
> look wrong? Then run it.

```bash
cargo run --example relationships -- --panic
```

```text
thread 'main' (531253) panicked at examples/relationships.rs:96:29:
RefCell already borrowed
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Run it again with `RUST_BACKTRACE=1` in front, and in the backtrace you'll find
`core::cell::panic_already_borrowed` called from `RefCell<…SharedCompany>::borrow_mut`, called
from `promote_prospects`. The `company` guard from `.borrow()` lives until the end of the loop
body, so `.borrow_mut()` on the next line finds an active shared borrow and panics. That's the
`BorrowMutError` you just saw from `try_borrow_mut`, except `borrow_mut` doesn't hand it back to
you: it panics.

**The plain-reference version of this code would not compile** (E0502, with a helpful message
pointing at both borrows). With `RefCell`, the identical mistake compiles fine and crashes in
production, possibly months later, when some combination of data happens to take that path.
`RefCell` doesn't remove the borrow rules. It **postpones** them to runtime and turns errors into
panics.

## Step 4 — Attempt 2b: links in both directions

A company page wants its contacts; a contact page wants its company. With `Rc`, the natural move
is to link both ways.

> 🟢 **FOLLOW ALONG**

```rust
// ---------------------------------------------------------------------
// Attempt 2b: links in both directions create a reference cycle.
// ---------------------------------------------------------------------

struct CompanyNode {
    name: String,
    contacts: RefCell<Vec<Rc<ContactNode>>>,
}

struct ContactNode {
    name: String,
    company: RefCell<Option<Rc<CompanyNode>>>,
}

impl Drop for CompanyNode {
    fn drop(&mut self) {
        println!("  dropped company {}", self.name);
    }
}

impl Drop for ContactNode {
    fn drop(&mut self) {
        println!("  dropped contact {}", self.name);
    }
}

fn attempt_2b_cycle() {
    println!("--- Attempt 2b: a cycle ---");
    let globex = Rc::new(CompanyNode {
        name: String::from("Globex"),
        contacts: RefCell::new(Vec::new()),
    });
    let hank = Rc::new(ContactNode {
        name: String::from("Hank"),
        company: RefCell::new(None),
    });

    *hank.company.borrow_mut() = Some(Rc::clone(&globex));
    globex.contacts.borrow_mut().push(Rc::clone(&hank));

    println!(
        "Globex owners: {}, Hank owners: {}",
        Rc::strong_count(&globex),
        Rc::strong_count(&hank)
    );
    println!("end of attempt_2b_cycle: watch for 'dropped' lines...");
}
```

In `main`, call `attempt_2b_cycle();` and then `println!("(back in main)");`. The `Drop` impls
print when each value is freed (you watched drops like this in Lab 06).

```text
--- Attempt 2b: a cycle ---
Globex owners: 2, Hank owners: 2
end of attempt_2b_cycle: watch for 'dropped' lines...
(back in main)
```

**No `dropped` lines.** At the end of the function, the local `globex` and `hank` handles are
dropped, so each count goes from 2 to 1. But Globex is still owned by Hank, and Hank is still
owned by Globex. Neither count ever reaches zero. Both are **leaked**: unreachable, never freed,
for the rest of the program. Rust's memory safety doesn't promise "no leaks"; `Rc` cycles are
the classic way to make one in safe code.

The standard fix is `Weak<T>`: a handle that **doesn't** count as an owner. One direction of
the link must be weak. That's Your Turn 3.

## Step 5 — Attempt 3: ids and lookups

Now drop pointers altogether. A contact stores the company's **id**; when you need the company,
you look it up.

> 🟢 **FOLLOW ALONG**

```rust
// ---------------------------------------------------------------------
// Attempt 3: ids and lookups.
// ---------------------------------------------------------------------

struct IdCompany {
    id: u64,
    name: String,
}

struct IdContact {
    name: String,
    company_id: u64,
}

fn attempt_3_ids() {
    println!("--- Attempt 3: ids ---");
    let mut companies = vec![IdCompany {
        id: 1,
        name: String::from("Acme"),
    }];
    let contacts = vec![IdContact {
        name: String::from("Ada"),
        company_id: 1,
    }];

    // Both of these were compile errors in attempt 1:
    companies.push(IdCompany {
        id: 2,
        name: String::from("Globex"),
    });
    companies[0].name = String::from("Acme Corporation");

    for contact in &contacts {
        // The price: a lookup, which can fail.
        match companies.iter().find(|c| c.id == contact.company_id) {
            Some(company) => println!("{} works at {}", contact.name, company.name),
            None => println!("{} works at a company that no longer exists", contact.name),
        }
    }
}
```

Call it from `main` and run:

```text
--- Attempt 3: ids ---
Ada works at Acme Corporation
```

Who owns Acme? The `companies` `Vec`, and only it. What does Ada hold? A `u64`, which is `Copy`,
borrows nothing, and can't dangle in the memory-safety sense. Companies can be added, renamed and
removed freely. Contacts and companies have no lifetimes and no `Rc`.

The price is visible in the `match`: following the link is a **lookup**, and it returns an
`Option`, because the id might refer to a company that's been deleted. That's not a flaw; it's
the truth about the data, made explicit. Keeping ids valid becomes a **business rule** (for
example, "you can't delete a company that still has contacts"), enforced in one place. That's
Part B.

### Comparing the three

| | References | `Rc<RefCell<T>>` | IDs |
|---|---|---|---|
| Who owns a company | the collection | everyone holding an `Rc` | the collection |
| Can companies change while contacts exist? | ❌ (compile error) | ✅ | ✅ |
| Borrow mistakes caught… | at compile time | at **runtime** (panic) | at compile time |
| Cycles | impossible | leak unless you use `Weak` | impossible |
| Following a link | free | `.borrow()` | a lookup that returns `Option` |
| Lifetimes on your types | everywhere | none | none |
| Saving to JSON / a database | ❌ | awkward | ✅ it's what a foreign key **is** |

That last row decides it for a CRM. In Lab 21 you'll save everything to JSON, and in Lab 30 to
Postgres, where `contacts.company_id REFERENCES companies(id)` is literally this design. The
`Rc` graph would need to be converted to ids for storage anyway.

`Rc<RefCell<T>>` isn't bad; it's for genuinely shared, graph-shaped, in-memory structures (GUI
widget trees, some caches). For **records**, Rust programs use ids. Finish `main` so it calls
all five functions in order (`attempt_1_references`, `box_parent_company`,
`attempt_2_rc_refcell`, `attempt_2b_cycle` followed by the `println!`, `attempt_3_ids`), run
`cargo clippy --all-targets`, and commit the exploration:

```bash
git add examples/relationships.rs
git commit -m "Explore relationship designs"
```

---

## Part B — The real refactor

## Step 6 — Newtype IDs: `CompanyId` and `ContactId`

With ids, a company id and a contact id are both "a `u64`". Here's what that allows:

```rust
// Imagine these signatures used plain u64 ids:
fn set_lifecycle(&mut self, company_id: u64, lifecycle: Lifecycle) -> Result<(), CrmError>
fn remove_contact(&mut self, contact_id: u64) -> Result<Contact, CrmError>

// ...and somewhere in the CLI, a slip:
crm.set_lifecycle(contact.id, Lifecycle::Customer)?;
```

It compiles. It runs. If contact #3 and company #3 both exist, it silently changes **the wrong
company**. No error, no crash, just wrong data, discovered weeks later. (Swapped arguments in
a function taking `(company_id: u64, contact_id: u64)` are the same bug.)

The fix is the newtype pattern from `Email`, used for identity instead of validation:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompanyId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContactId(pub u64);
```

Now `CompanyId` and `ContactId` are different types, and the slip is a compile error. (You'll
produce this exact error yourself in the 🧪 Experiment section.)

```text
error[E0308]: mismatched types
   --> src/cli/commands.rs:81:31
    |
 81 |             crm.set_lifecycle(id, crate::companies::Lifecycle::Customer)?;
    |                 ------------- ^^ expected `CompanyId`, found `ContactId`
    |                 |
    |                 arguments to this method are incorrect
    |
note: method defined here
   --> src/crm.rs:113:12
    |
113 |     pub fn set_lifecycle(&mut self, id: CompanyId, lifecycle: Lifecycle) -> Result<(), CrmError> {
    |            ^^^^^^^^^^^^^            -------------
```

Notes on the design:

- **Zero cost.** A struct with one `u64` field *is* a `u64` in memory. The distinction exists only
  at compile time.
- **`Copy`**, like the `u64` inside: ids are passed around constantly, and copying 8 bytes beats
  borrowing them.
- **`PartialEq, Eq`**: ids are compared (`c.id == id`). `Eq` says equality is a proper equivalence
  (no `NaN`-like weirdness), which hash maps will need later.
- **The field is `pub`**, unlike `Email`'s. Every `u64` is a valid id (whether a record *exists*
  with that id is a question for the store, not the type), so there's no invariant to protect.
  The point here is *distinguishing* ids, not validating them.

## Step 7 — The `companies` module

> 🟢 **FOLLOW ALONG**: `src/companies/model.rs`

```rust
/// Identifies a company. A `CompanyId` can't be mixed up with a `ContactId`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompanyId(pub u64);

/// Where a company is in its relationship with us.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Lifecycle {
    Prospect,
    Customer,
    Churned,
}

impl Lifecycle {
    /// Accepts "prospect", "customer" or "churned" (any letter case).
    pub fn parse(s: &str) -> Option<Lifecycle> {
        match s.to_lowercase().as_str() {
            "prospect" => Some(Lifecycle::Prospect),
            "customer" => Some(Lifecycle::Customer),
            "churned" => Some(Lifecycle::Churned),
            _ => None,
        }
    }

    /// The lowercase name used in commands and summaries.
    pub fn label(&self) -> &'static str {
        match self {
            Lifecycle::Prospect => "prospect",
            Lifecycle::Customer => "customer",
            Lifecycle::Churned => "churned",
        }
    }
}

/// An organisation we sell to.
#[derive(Debug, Clone)]
pub struct Company {
    pub id: CompanyId,
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
}

impl Company {
    /// New companies always start as prospects.
    pub fn new(id: CompanyId, name: String, website: Option<String>) -> Self {
        Self {
            id,
            name,
            website,
            lifecycle: Lifecycle::Prospect,
        }
    }

    /// One line: `#1 Acme Corp [prospect] https://acme.example`.
    pub fn summary(&self) -> String {
        let website = self
            .website
            .as_deref()
            .map(|w| format!(" {w}"))
            .unwrap_or_default();
        format!(
            "#{} {} [{}]{}",
            self.id.0,
            self.name,
            self.lifecycle.label(),
            website
        )
    }
}
```

`Lifecycle` is `CustomerStatus` with its middle variant renamed. "Active" was always a word for
"a company that buys from us", which is what `Customer` now says. (Lab 11's status rules don't
come along; Lab 18 does lifecycle rules properly, as a state machine for deals.) Add tests at
the bottom: a new company is a prospect, `summary` with and without a website, and `parse`/`label`
round-tripping for every variant.

> 🟢 **FOLLOW ALONG**: `src/companies/store.rs`

```rust
use super::{Company, CompanyId};

/// All companies, in memory. Hands out ids; enforces no business rules
/// (those live in `Crm`).
pub struct CompanyStore {
    companies: Vec<Company>,
    next_id: u64,
}

impl CompanyStore {
    pub fn new() -> Self {
        Self {
            companies: Vec::new(),
            next_id: 1,
        }
    }

    /// Stores a new company and returns its id.
    pub fn add(&mut self, name: String, website: Option<String>) -> CompanyId {
        let id = CompanyId(self.next_id);
        self.next_id += 1;
        self.companies.push(Company::new(id, name, website));
        id
    }

    pub fn all(&self) -> &[Company] {
        &self.companies
    }

    pub fn find(&self, id: CompanyId) -> Option<&Company> {
        self.companies.iter().find(|c| c.id == id)
    }

    pub fn find_mut(&mut self, id: CompanyId) -> Option<&mut Company> {
        self.companies.iter_mut().find(|c| c.id == id)
    }

    /// Removes a company and hands it back to the caller.
    pub fn remove(&mut self, id: CompanyId) -> Option<Company> {
        let index = self.companies.iter().position(|c| c.id == id)?;
        Some(self.companies.remove(index))
    }

    pub fn len(&self) -> usize {
        self.companies.len()
    }

    pub fn is_empty(&self) -> bool {
        self.companies.is_empty()
    }
}

impl Default for CompanyStore {
    fn default() -> Self {
        Self::new()
    }
}
```

Notice what's **missing**: `add` returns a plain `CompanyId`, not a `Result`. The store is a
**collection**: it hands out ids and keeps things in order. Rules like "names can't be blank" or
"no duplicate emails" are business rules, and they're about to get their own home. Write tests:
ids start at 1 and increase; `remove` returns the company and a second `remove` returns `None`.

> 🟢 **FOLLOW ALONG**: `src/companies/mod.rs`, and add `pub mod companies;` to `lib.rs`.

```rust
//! Companies: the organisations we sell to.

mod model;
mod store;

pub use model::{Company, CompanyId, Lifecycle};
pub use store::CompanyStore;
```

`cargo check`. It compiles, alongside the old `customers` module: nothing uses `companies` yet,
but `pub` items in a library are never "unused".

## Step 8 — The `contacts` module

`Email` belongs to contacts now (companies don't have one). Move the file with git, so history
follows it:

```bash
mkdir src/contacts
git mv src/customers/email.rs src/contacts/email.rs
```

In `contacts/email.rs`, fix the doc tests' paths: `use rust_crm::customers::Email;` becomes
`use rust_crm::contacts::Email;`. Until `customers` is deleted in Step 13, let it borrow the type
from its new home. In `customers/mod.rs`, replace `mod email;` and `pub use email::Email;` with:

```rust
pub use crate::contacts::Email;
```

A re-export can point anywhere in the crate. Old code that says `customers::Email` keeps
working while you migrate.

> 🟢 **FOLLOW ALONG**: `src/contacts/model.rs`

```rust
use super::Email;
use crate::companies::CompanyId;
use crate::errors::ValidationError;

/// Identifies a contact. A `ContactId` can't be mixed up with a `CompanyId`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContactId(pub u64);

/// A person we talk to, optionally working at a company.
#[derive(Debug, Clone)]
pub struct Contact {
    pub id: ContactId,
    pub name: String,
    pub email: Email,
    pub phone: Option<String>,
    pub company_id: Option<CompanyId>,
}

impl Contact {
    pub fn new(
        id: ContactId,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> Self {
        Self {
            id,
            name,
            email,
            phone,
            company_id,
        }
    }

    /// One line: `#1 Ada Lovelace <ada@acme.example> 555-0100`.
    pub fn summary(&self) -> String {
        let phone = self
            .phone
            .as_deref()
            .map(|p| format!(" {p}"))
            .unwrap_or_default();
        format!(
            "#{} {} <{}>{}",
            self.id.0,
            self.name,
            self.email.as_str(),
            phone
        )
    }

    pub fn has_phone(&self) -> bool {
        self.phone.is_some()
    }
}

// parse_phone and initials: moved here unchanged from customers/model.rs (with their tests)
```

`company_id: Option<CompanyId>`: the link from Attempt 3, typed, and optional, because a
freelancer or an individual buyer doesn't work at a company we track. Copy `parse_phone` and
`initials` here (leave the originals in `customers` for now; that module is deleted in Step 13).

> 🔵 **YOUR TURN** (mini-task): write `src/contacts/store.rs` yourself. It mirrors
> `CompanyStore`:

- [ ] `pub struct ContactStore { contacts: Vec<Contact>, next_id: u64 }`, fields private
- [ ] `new`, `Default`, `all`, `find`, `find_mut`, `remove`, `len`, `is_empty`: same shapes as
      `CompanyStore`, with `ContactId`
- [ ] `pub fn add(&mut self, name: String, email: Email, phone: Option<String>, company_id: Option<CompanyId>) -> ContactId`
      (no checks)
- [ ] `page`, `email_exists(&self, email: &Email) -> bool` and
      `search<'a>(&'a self, term: &str) -> Vec<&'a Contact>`, ported from `CustomerStore`
- [ ] Tests: sequential ids, case-insensitive search, out-of-range page

Then `src/contacts/mod.rs`, and `pub mod contacts;` in `lib.rs`:

```rust
//! Contacts: the people we talk to.

mod email;
mod model;
mod store;

pub use email::Email;
pub use model::{Contact, ContactId, initials, parse_phone};
pub use store::ContactStore;
```

## Step 9 — Errors that say *what* wasn't found

`NotFound(u32)` printed "no customer with id 7". Now there are companies and contacts, with
`u64` ids. Change the variant to carry the kind of entity, and add one for a rule you'll
enforce in Your Turn 1:

> 🟢 **FOLLOW ALONG**: in `src/errors.rs`

```rust
use crate::companies::CompanyId;

#[derive(Debug)]
pub enum CrmError {
    NotFound { entity: &'static str, id: u64 },
    DuplicateEmail(String),
    Validation(ValidationError),
    HasContacts(CompanyId),
    UnknownCommand(String),
    Usage(&'static str),
}

// in impl fmt::Display for CrmError:
            CrmError::NotFound { entity, id } => write!(f, "no {entity} with id {id}"),
            CrmError::HasContacts(id) => write!(
                f,
                "company #{} still has contacts; delete them first",
                id.0
            ),
```

`NotFound { entity, id }` is a **struct variant**, so call sites read
`CrmError::NotFound { entity: "company", id: 7 }`, which is self-explanatory. Run `cargo check`,
and the compiler lists every old call site:

```text
error[E0533]: expected value, found struct variant `CrmError::NotFound`
  --> src/cli/commands.rs:54:41
   |
54 |     let customer = store.find(id).ok_or(CrmError::NotFound(id))?;
   |                                         ^^^^^^^^^^^^^^^^^^ not a value
   |
help: you might have meant to create a new value of the struct
   |
54 -     let customer = store.find(id).ok_or(CrmError::NotFound(id))?;
54 +     let customer = store.find(id).ok_or(CrmError::NotFound { entity: /* value */, id: /* value */ })?;
```

The old customer commands are about to be replaced, so just keep them compiling for now: write
`CrmError::NotFound { entity: "customer", id: id.into() }` at each one. (`id.into()` turns the
`u32` into a `u64`; `From<u32> for u64` exists because it can never lose information.) In
tests that matched `Err(CrmError::NotFound(42))`, use `Err(CrmError::NotFound { id: 42, .. })`.

`cargo test` passes. Commit:

```bash
git add .
git commit -m "Add Company and Contact with typed ids"
```

## Step 10 — `Crm`: one owner for the data, one home for the rules

Look at where the rules lived at the end of Lab 13: "no duplicate emails" was inside
`CustomerStore::add`, but the same rule for **updates** was in the CLI's `update` command. "Names
can't be blank" was `parse_name`, called by the CLI. Now add a rule that spans **two** stores:
"a contact's company must exist". Which store owns that? Neither.

So the CRM gets a type that owns **all** the data and **all** the rules:

> 🟢 **FOLLOW ALONG**: `src/crm.rs`, and `pub mod crm;` in `lib.rs`.

```rust
//! The CRM's business rules. The CLI (and later the web server) talk to
//! `Crm`; `Crm` talks to the stores.

use crate::companies::{Company, CompanyId, CompanyStore, Lifecycle};
use crate::contacts::{Contact, ContactId, ContactStore, Email, parse_phone};
use crate::errors::{CrmError, ValidationError};

/// Everything the CRM knows, plus the rules for changing it.
pub struct Crm {
    pub companies: CompanyStore,
    pub contacts: ContactStore,
}

impl Crm {
    pub fn new() -> Self {
        Self {
            companies: CompanyStore::new(),
            contacts: ContactStore::new(),
        }
    }

    /// Looks up a company, turning "not there" into a `CrmError`.
    pub fn company(&self, id: CompanyId) -> Result<&Company, CrmError> {
        self.companies.find(id).ok_or(CrmError::NotFound {
            entity: "company",
            id: id.0,
        })
    }

    /// Looks up a contact, turning "not there" into a `CrmError`.
    pub fn contact(&self, id: ContactId) -> Result<&Contact, CrmError> {
        self.contacts.find(id).ok_or(CrmError::NotFound {
            entity: "contact",
            id: id.0,
        })
    }

    pub fn add_company(
        &mut self,
        name: String,
        website: Option<String>,
    ) -> Result<CompanyId, CrmError> {
        let name = clean_name(&name)?;
        Ok(self.companies.add(name, website))
    }

    /// Adds a contact. The email must be unused and the company (if any) must exist.
    pub fn add_contact(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> Result<ContactId, CrmError> {
        let name = clean_name(&name)?;
        let phone = clean_phone(phone)?;
        if let Some(company_id) = company_id {
            self.company(company_id)?;
        }
        if self.contacts.email_exists(&email) {
            return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
        }
        Ok(self.contacts.add(name, email, phone, company_id))
    }

    /// Changes the fields that are `Some`; leaves the others alone.
    pub fn update_contact(
        &mut self,
        id: ContactId,
        name: Option<String>,
        email: Option<Email>,
        phone: Option<String>,
    ) -> Result<(), CrmError> {
        let name = match name {
            Some(name) => Some(clean_name(&name)?),
            None => None,
        };
        let phone = clean_phone(phone)?;
        if let Some(email) = &email {
            let current = self.contact(id)?;
            if current.email != *email && self.contacts.email_exists(email) {
                return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
            }
        }

        let contact = self.contacts.find_mut(id).ok_or(CrmError::NotFound {
            entity: "contact",
            id: id.0,
        })?;
        if let Some(name) = name {
            contact.name = name;
        }
        if let Some(email) = email {
            contact.email = email;
        }
        if phone.is_some() {
            contact.phone = phone;
        }
        Ok(())
    }

    /// All contacts who work at `company_id`.
    pub fn contacts_of(&self, company_id: CompanyId) -> Vec<&Contact> {
        let mut result = Vec::new();
        for contact in self.contacts.all() {
            if contact.company_id == Some(company_id) {
                result.push(contact);
            }
        }
        result
    }

    pub fn set_lifecycle(&mut self, id: CompanyId, lifecycle: Lifecycle) -> Result<(), CrmError> {
        let company = self.companies.find_mut(id).ok_or(CrmError::NotFound {
            entity: "company",
            id: id.0,
        })?;
        company.lifecycle = lifecycle;
        Ok(())
    }
}

impl Default for Crm {
    fn default() -> Self {
        Self::new()
    }
}

/// Names are trimmed and must not be blank.
fn clean_name(name: &str) -> Result<String, ValidationError> {
    let name = name.trim();
    if name.is_empty() {
        Err(ValidationError::EmptyName)
    } else {
        Ok(name.to_string())
    }
}

/// `Some("")` counts as no phone; anything else must be a valid phone number.
fn clean_phone(phone: Option<String>) -> Result<Option<String>, ValidationError> {
    match phone {
        Some(raw) => parse_phone(&raw),
        None => Ok(None),
    }
}
```

Read it as a list of promises:

- **`Crm` owns everything.** `companies` and `contacts` are fields, so the `Crm` value owns both
  stores, which own every company and contact. Relationships between them are plain data
  (`company_id`), not borrows. That's Attempt 3, for real.
- **Every write goes through a method that checks the rules first**, then changes data. The same
  "check with shared borrows, mutate with one exclusive borrow" order as Lab 12's `update`, now in
  the one place it belongs.
- **`company()` and `contact()`** wrap the stores' `Option`-returning `find` into the
  `NotFound` errors every caller wants. That's why there's no `ok_or(...)` scattered through the CLI
  any more.
- **Validation of raw input happens here**: names (`clean_name`, which replaces `parse_name`) and
  phones (`clean_phone`, built on `parse_phone`). Emails arrive as `Email`, already parsed. The
  rule of thumb: *types that carry proof don't need re-checking; plain `String`s get checked at
  the `Crm` boundary.*
- **The stores' fields are `pub`.** Reading is harmless, so the CLI can still write
  `crm.contacts.search(term)` or `crm.companies.all()`. But because `CompanyStore`'s and
  `ContactStore`'s own fields are private, the only way to *change* data is through store methods,
  and by convention, the CLI only uses `Crm`'s methods for that. Lab 16 tightens this further.
- `contacts_of` returns `Vec<&Contact>`: borrowed results, like `search` in Lab 10. Elision ties
  them to `&self`.

> **The rule from here on: the CLI only parses, prompts and prints. Business logic lives in
> `Crm`.** Why insist? Because in Lab 24 you'll write integration tests against `Crm`, with no
> terminal involved, and in Lab 27 a web server will call the very same methods. Any rule left in
> `cli/commands.rs` would have to be copied into the server, and the copies would drift apart.
> A rule that lives in `Crm` is enforced for every front end, for free.

Add a few tests at the bottom of `crm.rs`:

> 🟢 **FOLLOW ALONG**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn email(s: &str) -> Email {
        Email::parse(s).unwrap()
    }

    /// A CRM with one company (Acme) and one contact (Ada) working there.
    fn crm_with_acme_and_ada() -> (Crm, CompanyId, ContactId) {
        let mut crm = Crm::new();
        let acme = crm.add_company(String::from("Acme"), None).unwrap();
        let ada = crm
            .add_contact(String::from("Ada"), email("ada@acme.example"), None, Some(acme))
            .unwrap();
        (crm, acme, ada)
    }

    #[test]
    fn add_contact_links_to_existing_company() {
        let (crm, acme, ada) = crm_with_acme_and_ada();
        assert_eq!(crm.contact(ada).unwrap().company_id, Some(acme));
    }

    #[test]
    fn add_contact_rejects_unknown_company() {
        let mut crm = Crm::new();
        let result = crm.add_contact(
            String::from("Ada"),
            email("ada@acme.example"),
            None,
            Some(CompanyId(99)),
        );
        assert!(matches!(
            result,
            Err(CrmError::NotFound { entity: "company", id: 99 })
        ));
        assert!(crm.contacts.is_empty());
    }
}
```

The helper returns a **tuple** `(Crm, CompanyId, ContactId)`, and the test destructures it with
`let (crm, acme, ada) = ...`. Ids are `Copy`, so they're easy to hand back. The second test checks
the rule *and* that nothing was stored. Your Turn 2 adds the rest.

`cargo test` passes. Commit:

```bash
git add .
git commit -m "Add Crm to own business rules"
```

## Step 11 — Commands for companies and contacts

The command language changes shape: a **noun**, then a **verb**. That maps naturally onto
**nested enums**.

> 🟢 **FOLLOW ALONG**: replace the contents of `src/cli/parser.rs` above the tests.

```rust
use crate::companies::{CompanyId, Lifecycle};
use crate::contacts::ContactId;
use crate::errors::CrmError;

/// A command typed at the `crm>` prompt, already checked and converted to real types.
#[derive(Debug, PartialEq)]
pub(crate) enum Command<'a> {
    Help,
    Version,
    Quit,
    Company(CompanyCommand),
    Contact(ContactCommand<'a>),
}

#[derive(Debug, PartialEq)]
pub(crate) enum CompanyCommand {
    Add,
    List,
    Show { id: CompanyId },
    Stage { id: CompanyId, lifecycle: Lifecycle },
    Delete { id: CompanyId },
}

#[derive(Debug, PartialEq)]
pub(crate) enum ContactCommand<'a> {
    Add,
    List { page: usize },
    Show { id: ContactId },
    Update { id: ContactId },
    Delete { id: ContactId },
    Search { term: &'a str },
}

const COMPANY_USAGE: &str =
    "company add | list | show <id> | stage <id> <prospect|customer|churned> | delete <id>";
const CONTACT_USAGE: &str =
    "contact add | list [page] | show <id> | update <id> | delete <id> | search <term>";

/// Turns one input line into a `Command`.
/// `Ok(None)` means a blank line; `Err` means the line made no sense.
pub(crate) fn parse_command(input: &str) -> Result<Option<Command<'_>>, CrmError> {
    let words: Vec<&str> = input.split_whitespace().collect();

    let command = match words.as_slice() {
        [] => return Ok(None),
        ["help", ..] => Command::Help,
        ["version", ..] => Command::Version,
        ["quit" | "exit", ..] => Command::Quit,
        ["company", sub, args @ ..] => Command::Company(parse_company(sub, args)?),
        ["company"] => return Err(CrmError::Usage(COMPANY_USAGE)),
        ["contact", sub, args @ ..] => Command::Contact(parse_contact(sub, args)?),
        ["contact"] => return Err(CrmError::Usage(CONTACT_USAGE)),
        [other, ..] => return Err(CrmError::UnknownCommand(other.to_string())),
    };
    Ok(Some(command))
}

fn parse_company(sub: &str, args: &[&str]) -> Result<CompanyCommand, CrmError> {
    let command = match (sub, args) {
        ("add", []) => CompanyCommand::Add,
        ("list", []) => CompanyCommand::List,
        ("show", [id]) => CompanyCommand::Show {
            id: CompanyId(parse_id(id)?),
        },
        ("stage", [id, stage]) => CompanyCommand::Stage {
            id: CompanyId(parse_id(id)?),
            lifecycle: Lifecycle::parse(stage).ok_or(CrmError::Usage(COMPANY_USAGE))?,
        },
        ("delete", [id]) => CompanyCommand::Delete {
            id: CompanyId(parse_id(id)?),
        },
        _ => return Err(CrmError::Usage(COMPANY_USAGE)),
    };
    Ok(command)
}

fn parse_contact<'a>(sub: &str, args: &[&'a str]) -> Result<ContactCommand<'a>, CrmError> {
    let command = match (sub, args) {
        ("add", []) => ContactCommand::Add,
        ("list", []) => ContactCommand::List { page: 1 },
        ("list", [page]) => match page.parse::<usize>() {
            Ok(page @ 1..) => ContactCommand::List { page },
            _ => return Err(CrmError::Usage(CONTACT_USAGE)),
        },
        ("show", [id]) => ContactCommand::Show {
            id: ContactId(parse_id(id)?),
        },
        ("update", [id]) => ContactCommand::Update {
            id: ContactId(parse_id(id)?),
        },
        ("delete", [id]) => ContactCommand::Delete {
            id: ContactId(parse_id(id)?),
        },
        ("search", [term, ..]) => ContactCommand::Search { term },
        _ => return Err(CrmError::Usage(CONTACT_USAGE)),
    };
    Ok(command)
}

/// Ids are typed as plain numbers; the caller wraps them in the right newtype.
fn parse_id(raw: &str) -> Result<u64, CrmError> {
    raw.parse()
        .map_err(|_| CrmError::Usage("ids are positive whole numbers, e.g. 3"))
}
```

Pattern notes:

- The top-level match is now on the **whole word slice**. `["company", sub, args @ ..]` means
  "first word `company`, a second word bound to `sub`, and the rest, possibly none, bound to
  `args`". `args @ ..` is an `@` binding (Lab 11) on a rest pattern: it captures the remaining
  sub-slice as a `&[&str]`.
- `Command::Company(CompanyCommand)` is an enum **inside** an enum. Matching on it later looks
  like `Command::Company(CompanyCommand::Show { id })`, or you hand the inner enum to its own
  function. The nesting mirrors the noun-verb shape of the commands.
- `CompanyCommand` has **no** lifetime: none of its variants borrow. `ContactCommand<'a>` does,
  because `Search { term }` borrows from the input. `Command<'a>` passes its `'a` to
  `ContactCommand<'a>`.
- The parser wraps raw numbers in `CompanyId(...)` or `ContactId(...)`. That's the one place the
  CLI decides which kind of id a number is; from there on, the types carry it.

### The lifetime on `parse_contact`

> 🟡 **EXPERIMENT**: remove the lifetimes from `parse_contact`:
> `fn parse_contact(sub: &str, args: &[&str]) -> Result<ContactCommand, CrmError>`.

```text
error[E0106]: missing lifetime specifier
  --> src/cli/parser.rs:77:54
   |
77 | fn parse_contact(sub: &str, args: &[&str]) -> Result<ContactCommand, CrmError> {
   |                       ----        -------            ^^^^^^^^^^^^^^ expected named lifetime parameter
   |
   = help: this function's return type contains a borrowed value, but the signature does not say whether it is borrowed from `sub` or one of `args`'s 2 lifetimes
help: consider introducing a named lifetime parameter
   |
77 | fn parse_contact<'a>(sub: &'a str, args: &'a [&'a str]) -> Result<ContactCommand<'a>, CrmError> {
   |                 ++++       ++             ++   ++                               ++++
```

Three input references (`sub`, the slice `args`, and the `&str`s inside it), so no elision rule
applies (Lab 10). Now try the compiler's suggestion exactly as written:

```text
error[E0515]: cannot return value referencing local variable `words`
  --> src/cli/parser.rs:55:5
   |
44 |     let command = match words.as_slice() {
   |                         ----- `words` is borrowed here
...
55 |     Ok(Some(command))
   |     ^^^^^^^^^^^^^^^^^ returns a value referencing data owned by the current function
```

The suggestion compiles *inside* `parse_contact`, but it over-promises. `&'a [&'a str]` says the
**slice itself** lives as long as the result. The slice is borrowed from `words`, a local `Vec` in
`parse_command` that dies when it returns. Only the **strings inside** come from the input line.
So the precise answer, `args: &[&'a str]`, ties `'a` to the inner `&str`s and nothing else.
Ask *"which owner does the returned reference point into?"* (the input line, through the inner
`&str`s), and annotate exactly that. Put the lifetimes back.

Update the parser tests (the old customer commands are gone). Your Turn 2 in Lab 11 showed the
pattern; at minimum, check `company show 3`, `company stage 3 Customer`, `contact list`,
`contact search lovelace`, a few usage errors, and that the old `add` is now an unknown command.

## Step 12 — The CLI handlers

> 🟢 **FOLLOW ALONG**: replace `src/cli/commands.rs` (keep `print_help` at the bottom, but
> rewrite its text; see below).

```rust
//! Command handlers. The rule for this file: parse, prompt, print.
//! Every decision about the data is made by `Crm`.

use super::parser::{Command, CompanyCommand, ContactCommand};
use super::{APP_NAME, PAGE_SIZE, prompt};
use crate::companies::CompanyId;
use crate::contacts::{Contact, ContactId, Email, initials};
use crate::crm::Crm;
use crate::errors::CrmError;

/// Runs one command. Printing happens here; errors are returned.
pub(crate) fn execute(crm: &mut Crm, command: Command) -> Result<(), CrmError> {
    match command {
        Command::Help => print_help(),
        Command::Version => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
        Command::Quit => {} // the REPL loop handles Quit before calling execute
        Command::Company(command) => company(crm, command)?,
        Command::Contact(command) => contact(crm, command)?,
    }
    Ok(())
}

fn company(crm: &mut Crm, command: CompanyCommand) -> Result<(), CrmError> {
    match command {
        CompanyCommand::Add => {
            let name = prompt("Name: ");
            let website = Some(prompt("Website (optional): ")).filter(|w| !w.is_empty());
            let id = crm.add_company(name, website)?;
            println!("Added company #{}", id.0);
        }
        CompanyCommand::List => {
            if crm.companies.is_empty() {
                println!("No companies yet.");
            }
            for company in crm.companies.all() {
                println!("{}", company.summary());
            }
        }
        CompanyCommand::Show { id } => {
            let company = crm.company(id)?;
            println!("{}", company.summary());
            let contacts = crm.contacts_of(id);
            if contacts.is_empty() {
                println!("  No contacts yet.");
            }
            for contact in contacts {
                println!("  {}", contact.summary());
            }
        }
        CompanyCommand::Stage { id, lifecycle } => {
            crm.set_lifecycle(id, lifecycle)?;
            println!("Company #{} is now {}.", id.0, lifecycle.label());
        }
        CompanyCommand::Delete { id } => todo!("Your Turn 1: delete company #{}", id.0),
    }
    Ok(())
}

fn contact(crm: &mut Crm, command: ContactCommand) -> Result<(), CrmError> {
    match command {
        ContactCommand::Add => {
            let name = prompt("Name: ");
            let email = Email::parse(&prompt("Email: "))?;
            let phone = Some(prompt("Phone (optional): ")).filter(|p| !p.is_empty());
            let company_id = read_company_id()?;
            let id = crm.add_contact(name, email, phone, company_id)?;
            println!("Added contact #{}", id.0);
        }
        ContactCommand::List { page } => {
            let contacts = crm.contacts.page(page, PAGE_SIZE);
            if crm.contacts.is_empty() {
                println!("No contacts yet.");
            } else if contacts.is_empty() {
                println!("No contacts on page {page}.");
            } else {
                for contact in contacts {
                    print_contact_line(crm, contact);
                }
                let pages = crm.contacts.len().div_ceil(PAGE_SIZE);
                println!("Page {page} of {pages}");
            }
        }
        ContactCommand::Show { id } => {
            let contact = crm.contact(id)?;
            print_contact_line(crm, contact);
            if !contact.has_phone() {
                println!("(no phone on file)");
            }
            println!("  Domain:   {}", contact.email.domain());
            println!("  Initials: {}", initials(&contact.name));
        }
        ContactCommand::Update { id } => update_contact(crm, id)?,
        ContactCommand::Delete { id } => todo!("Your Turn 1: delete contact #{}", id.0),
        ContactCommand::Search { term } => {
            let results = crm.contacts.search(term);
            if results.is_empty() {
                println!("No contacts match '{term}'.");
            }
            for contact in results {
                print_contact_line(crm, contact);
            }
        }
    }
    Ok(())
}

fn update_contact(crm: &mut Crm, id: ContactId) -> Result<(), CrmError> {
    println!("Editing {}", crm.contact(id)?.summary());

    let name = Some(prompt("Name (blank to keep): ")).filter(|s| !s.is_empty());
    let input = prompt("Email (blank to keep): ");
    let email = if input.is_empty() {
        None
    } else {
        Some(Email::parse(&input)?)
    };
    let phone = Some(prompt("Phone (blank to keep): ")).filter(|s| !s.is_empty());

    crm.update_contact(id, name, email, phone)?;
    println!("Updated contact #{}", id.0);
    Ok(())
}

/// Blank means "no company"; anything else must be a number.
fn read_company_id() -> Result<Option<CompanyId>, CrmError> {
    let input = prompt("Company id (blank for none): ");
    if input.is_empty() {
        return Ok(None);
    }
    let id = input
        .parse()
        .map_err(|_| CrmError::Usage("company id must be a number (or blank for none)"))?;
    Ok(Some(CompanyId(id)))
}

/// `#1 Ada Lovelace <ada@acme.example> 555-0100 @ Acme Corp`
fn print_contact_line(crm: &Crm, contact: &Contact) {
    match contact.company_id.and_then(|id| crm.companies.find(id)) {
        Some(company) => println!("{} @ {}", contact.summary(), company.name),
        None => println!("{}", contact.summary()),
    }
}
```

(`contact.email.domain()` is Lab 12's Your Turn 4. If you skipped it, keep using your
`email_domain` function, moved into `contacts/model.rs`.)

Check the rule against this file. Every handler **parses** (`Email::parse`, `read_company_id`),
**prompts**, calls **one** `Crm` method or reads a store, and **prints**. There's no `if` that
decides whether data is allowed. Even `update_contact` here just collects what the user typed
and hands it over.

Three details:

- **`print_contact_line` follows the link.** `contact.company_id.and_then(|id| crm.companies.find(id))`:
  the `Option<CompanyId>` (does Ada have a company?) is chained into `find`'s
  `Option<&Company>` (does it still exist?). That's Attempt 3's lookup, written with
  `and_then` from Lab 12.
- **`todo!("...")`** is how you leave a hole that compiles: it has the type of whatever is
  expected, and panics with your message if it ever runs. It's honest about being unfinished,
  which makes it a perfect placeholder for Your Turn 1, and a bug if you ever ship it.
- **Borrowing `crm`**: in `Show`, `contact` borrows from `crm` and `print_contact_line(crm, contact)`
  borrows it again, shared. Two shared borrows are fine. Try to call a `&mut self` method of
  `crm` in between, and you'll meet Attempt 1's problem in the real code (🧪 Experiment).

Rewrite `print_help`:

```rust
fn print_help() {
    println!("Companies:");
    println!("  company add                 add a company");
    println!("  company list                list all companies");
    println!("  company show <id>           show a company and its contacts");
    println!("  company stage <id> <prospect|customer|churned>");
    println!("                              move a company through its lifecycle");
    println!("  company delete <id>         delete a company with no contacts");
    println!("Contacts:");
    println!("  contact add                 add a contact");
    println!("  contact list [page]         list contacts, {PAGE_SIZE} per page");
    println!("  contact show <id>           show one contact");
    println!("  contact update <id>         change a contact's details");
    println!("  contact delete <id>         delete a contact");
    println!("  contact search <term>       find contacts by name or email");
    println!("Other:");
    println!("  version                     show the version");
    println!("  help                        show this help");
    println!("  quit                        exit the CRM");
}
```

Replace the test in `commands.rs` with one that runs `Show` and `Update` for unknown company and
contact ids through `execute`, expecting `Err(CrmError::NotFound { id: 42, .. })` each time
(Your Turn 1 adds the deletes).

In `src/cli/mod.rs`, the REPL now owns a `Crm`:

```rust
use crate::crm::Crm;          // instead of `use crate::customers::CustomerStore;`
// ...
    let mut crm = Crm::new();  // instead of `let mut store = CustomerStore::new();`
// ...
            Ok(Some(command)) => commands::execute(&mut crm, command),
```

## Step 13 — Delete `customers`

Nothing uses it any more:

```bash
git rm -r src/customers
git rm examples/seed.rs     # only if you did Lab 13's Your Turn 3
```

Remove `pub mod customers;` from `lib.rs`. The final crate root:

```rust
//! Rust CRM: the library behind the `rust-crm` binary.

pub mod cli;
pub mod companies;
pub mod contacts;
pub mod crm;
pub mod errors;
```

Run `cargo fmt`, `cargo clippy --all-targets`, `cargo test`, and fix whatever the compiler
points at.

### Why there's no `customers/` folder

You might expect one next to `companies/` and `contacts/`. There isn't one because there isn't a
"customer" **thing**. A customer is a company in the `Customer` stage of its lifecycle:

```rust
crm.companies.all().iter().filter(|c| c.lifecycle == Lifecycle::Customer)
```

If we kept a `Customer` entity, we'd have to keep it in sync with the company: copy data across
when a prospect signs, decide which one owns the contacts, and so on. Modelling it as a state
makes all of that disappear. The general lesson: **when a noun in the business describes a phase
something passes through, it's probably an enum on that something, not an entity of its own.**
You'll see it again with leads in Lab 19, which *convert* into companies and contacts.

---

## ▶️ Run It

```bash
cargo run
```

```text
crm> company add
Name: Acme Corp
Website (optional): https://acme.example
crm> company add
Name: Globex
Website (optional):
crm> contact add
Name: Ada Lovelace
Email: ada@acme.example
Phone (optional): 555-0100
Company id (blank for none): 1
crm> contact add
Name: Grace Hopper
Email: grace@example.com
Phone (optional):
Company id (blank for none):
crm> contact add
Name: Hank Scorpio
Email: hank@globex.example
Phone (optional):
Company id (blank for none): 7
crm> company list
crm> company stage 1 customer
crm> company show 1
crm> company show 2
crm> contact list
crm> contact show 2
crm> add
crm> company
crm> contact show x
crm> quit
```

## ✅ Expected Result

```text
crm> company add
Name: Acme Corp
Website (optional): https://acme.example
Added company #1
crm> company add
Name: Globex
Website (optional):
Added company #2
crm> contact add
Name: Ada Lovelace
Email: ada@acme.example
Phone (optional): 555-0100
Company id (blank for none): 1
Added contact #1
crm> contact add
Name: Grace Hopper
Email: grace@example.com
Phone (optional):
Company id (blank for none):
Added contact #2
crm> contact add
Name: Hank Scorpio
Email: hank@globex.example
Phone (optional):
Company id (blank for none): 7
Error: no company with id 7
crm> company list
#1 Acme Corp [prospect] https://acme.example
#2 Globex [prospect]
crm> company stage 1 customer
Company #1 is now customer.
crm> company show 1
#1 Acme Corp [customer] https://acme.example
  #1 Ada Lovelace <ada@acme.example> 555-0100
crm> company show 2
#2 Globex [prospect]
  No contacts yet.
crm> contact list
#1 Ada Lovelace <ada@acme.example> 555-0100 @ Acme Corp
#2 Grace Hopper <grace@example.com>
Page 1 of 1
crm> contact show 2
#2 Grace Hopper <grace@example.com>
(no phone on file)
  Domain:   example.com
  Initials: GH
crm> add
Error: unknown command 'add' (type 'help' for a list of commands)
crm> company
Error: usage: company add | list | show <id> | stage <id> <prospect|customer|churned> | delete <id>
crm> contact show x
Error: usage: ids are positive whole numbers, e.g. 3
crm> quit
Goodbye! (14 commands this session)
```

And `cargo run --example relationships` prints all five sections, ending with
`Ada works at Acme Corporation`. `cargo test` and `cargo clippy --all-targets` are clean.

## 🧠 Understand It

### The ownership picture

```text
Crm  (owned by the REPL loop in cli::run)
├── companies: CompanyStore ── owns ── Vec<Company> ── owns ── [Acme, Globex]
└── contacts:  ContactStore ── owns ── Vec<Contact> ── owns ── [Ada, Grace]
                                                                 │
                                                  company_id: Some(CompanyId(1))   ← just a number
```

One owner at the top, a strict tree below it, and relationships as **values**. Nothing borrows
across the tree, so nothing gets frozen, and nothing is shared, so nothing needs `Rc` or runtime
checks. Borrowing still happens, but only briefly: `contacts_of` returns `Vec<&Contact>` for the
length of one command, like `search` did. Long-lived structure is owned; short-lived views are
borrowed. That's the shape of almost every Rust application that manages records.

### Where each kind of check lives now

| Check | Where | How |
|---|---|---|
| Is this text a number / a known command / a stage? | `cli/parser.rs` | parse into `Command`, `CompanyId`, `Lifecycle` |
| Is this a valid email? | `contacts/email.rs` | `Email::parse`, enforced by privacy |
| Is the name blank? Is the phone valid? | `crm.rs` | `clean_name`, `clean_phone` |
| Does the company exist? Is the email taken? | `crm.rs` | `Crm` methods, before any write |
| Can a `ContactId` be used as a `CompanyId`? | nowhere: the **compiler** | newtype ids |

### IDs are not a step backwards

Coming from garbage-collected languages, ids can feel primitive: "I had real object references,
now I have numbers and lookups?" But you've traded a hidden assumption (the pointer is valid,
the object is still the one you think it is) for an explicit one (`find` returns `Option`). The
"dangling pointer" problem doesn't vanish; it becomes "dangling id", which is a **business
rule** you can see, test, and enforce in one place. Databases made exactly this choice decades
ago, for the same reasons.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: the mix-up.** In the `ContactCommand::Show` arm, before `let contact = ...`,
> add `crm.set_lifecycle(id, crate::companies::Lifecycle::Customer)?;`. `id` is a `ContactId`
> there. Run `cargo check` and compare the error with Step 6. Now imagine the ids were plain
> `u64`: which customer would have been "promoted"? Remove the line.

> 🟡 **EXPERIMENT 2: Attempt 1, in the real code.** In the `CompanyCommand::Show` arm, add a line
> right after `let company = crm.company(id)?;`:
>
> ```rust
>             crm.add_company(format!("{} (copy)", company.name), None)?;
> ```

```text
error[E0502]: cannot borrow `*crm` as mutable because it is also borrowed as immutable
  --> src/cli/commands.rs:41:13
   |
40 |             let company = crm.company(id)?;
   |                           --- immutable borrow occurs here
41 |             crm.add_company(format!("{} (copy)", company.name), None)?;
   |             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
42 |             println!("{}", company.summary());
   |                            ------- immutable borrow later used here
```

`company` is a `&Company` into the store, so the store is frozen while it's alive. The same
rule as Attempt 1, but it's harmless here because the borrow lasts three lines. That's the
difference between a *view* (fine to borrow) and a *relationship* (must not borrow). How would you
write it so it compiles, keeping the "(copy)" behaviour? (Hint: build the new name as an owned
`String` and call `add_company` *before* taking the `&Company` the rest of the arm uses.) Then
remove the experiment.

> 🟡 **EXPERIMENT 3: dangling ids.** Until Your Turn 1, nothing deletes a company. But
> `CompanyStore::remove` exists. In a test, add a company and a contact at it, then call
> `crm.companies.remove(acme)` **directly** (bypassing `Crm`). What does `print_contact_line`'s
> lookup return for that contact now? What would `crm.contacts_of(acme)` return? Which method
> in `Crm` should exist to prevent this, and why should the CLI never call the store's `remove`
> itself?

> 🟡 **EXPERIMENT 4: `Rc` counts.** In `attempt_2_rc_refcell`, temporarily comment out the
> `if std::env::args()...` block (it moves `ada` and `grace`). At the end of the function, add
> `drop(ada);`, print `Rc::strong_count(&acme)`, then `drop(grace);` and print it again. Predict
> the numbers first. (Leave the block in, and you'll get E0382 instead: why?) Undo afterwards.

## 👩🏽‍💻 Your Turn

### Your Turn 1 — Deleting, safely

> 🔵 **YOUR TURN**: replace the two `todo!()`s.

Add to `Crm`:

```rust
pub fn remove_contact(&mut self, id: ContactId) -> Result<Contact, CrmError>
pub fn remove_company(&mut self, id: CompanyId) -> Result<Company, CrmError>
```

- [ ] `remove_contact` removes the contact and returns it (owned), or
      `NotFound { entity: "contact", .. }`
- [ ] `remove_company` refuses with `CrmError::HasContacts(id)` if any contact still works there,
      and nothing is removed; unknown id → `NotFound { entity: "company", .. }`
- [ ] Otherwise the company is removed and returned
- [ ] `contact delete <id>` prints `Deleted contact #2 (Grace Hopper)`
- [ ] `company delete <id>` prints `Deleted company #2 (Globex)` or
      `Error: company #1 still has contacts; delete them first`
- [ ] No `todo!()` left; the `execute` test in `commands.rs` also covers both deletes with
      unknown ids
- [ ] Explain in a comment why the check lives in `Crm` and not in `CompanyStore::remove`

### Your Turn 2 — Test the rules

> 🔵 **YOUR TURN**: `Crm` is where the rules are, so that's where the tests matter most. Using the
> `crm_with_acme_and_ada` helper, add tests for:

- [ ] `add_contact` with an email already used (in a different case) → `DuplicateEmail`
- [ ] Blank names (`"   "`) rejected by **both** `add_company` and `add_contact`, as
      `CrmError::Validation(ValidationError::EmptyName)`
- [ ] `contacts_of` returns only that company's contacts (add a second company with its own
      contact, and a contact with no company)
- [ ] `set_lifecycle` changes the company; on an unknown id it's `NotFound { entity: "company", id }`
- [ ] `update_contact` with `None` everywhere except phone changes only the phone
- [ ] `update_contact` allows a contact to "change" to their own email, but not to someone else's
- [ ] Your Turn 1's rules: `HasContacts` while Ada is there, success after removing Ada, and
      `NotFound` for both removals with unknown ids

### Your Turn 3 — Break the cycle with `Weak`

> 🔵 **YOUR TURN**: fix the leak in `attempt_2b_cycle` (in `examples/relationships.rs`).

- [ ] Change **one** direction of the link to `std::rc::Weak`. Decide which one, and write a
      comment explaining why that direction
- [ ] Hank can still print the name of his company (look at `Weak::upgrade`, and what it returns)
- [ ] Print the strong **and** weak counts for Globex
- [ ] Running the example prints `dropped company Globex` and `dropped contact Hank` **before**
      `(back in main)`
- [ ] Rename the section's heading to say the cycle is broken

## 💡 Hint

> 💡 **HINT**: for Your Turn 1, `remove_company` has three outcomes and they must be checked in
> order: does it exist? does it have contacts? only then remove. You've already got a method
> that answers each question.

<details><summary>Hint 2: Your Turn 1</summary>

`self.company(id)?;` handles "does it exist" (the result is discarded; only the `?` matters).
`self.contacts_of(id).is_empty()` answers the second. Then `self.companies.remove(id)` returns
an `Option<Company>`, and `ok_or(...)` turns it into the `Result`. In the CLI, the returned owned
`Company` is what lets you print its name *after* it's gone from the store (the same trick as
`delete` in Lab 08).

</details>

<details><summary>Hint 3: Your Turn 3</summary>

Ask "who should keep whom alive?". A company's contact list is the owning direction; a
contact's "my company" is a back-reference. Make the back-reference weak:
`company: RefCell<Weak<CompanyNode>>`, starting as `Weak::new()` and set with
`Rc::downgrade(&globex)`. `hank.company.borrow().upgrade()` gives an `Option<Rc<CompanyNode>>`:
`None` if the company has already been dropped. `Rc::weak_count` counts the weak handles.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Why couldn't companies be added or renamed in Attempt 1 while a contact existed? Which rule
   from Lab 07 is at work?
2. Why is a struct that holds both a `Vec<Company>` and references into it impossible to use?
3. What does `Box<T>` solve, and why doesn't it help with "several contacts at one company"?
4. What's the difference between `Rc<T>` and `RefCell<T>`? Which one gives shared ownership,
   which one gives mutation through a shared handle?
5. The same borrow mistake is a compile error with references and a panic with `RefCell`. Explain.
6. How do `Rc` cycles leak memory, and how does `Weak` prevent it?
7. What bug do `CompanyId` and `ContactId` prevent? What do they cost at runtime?
8. State the rule for `cli/commands.rs`. Which two later labs depend on it, and why?
9. Why is there no `customers/` module any more?

Then verify:

```bash
cargo fmt --check && cargo clippy --all-targets && cargo test
```

## Git Commit

You already committed three steps: the exploration, the new modules, and `Crm`. Finish with:

```bash
git add .
git commit -m "Split Customer into Company and Contact"
git tag lab-14
git push && git push --tags
```

`git log --oneline lab-13..lab-14` tells the story of the refactor in four commits. And
`git diff lab-13 lab-14 --stat` shows the shape change: `customers/` gone, `companies/`,
`contacts/` and `crm.rs` in its place.

> 🏁 **Phase 3 is done.** Your CRM has a real domain model, validated data, typed errors, a
> library with privacy, and relationships that will map straight onto database tables. Phase 4
> starts by noticing how similar `CompanyStore` and `ContactStore` are.

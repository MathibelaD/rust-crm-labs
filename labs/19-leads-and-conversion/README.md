# Lab 19 — Leads & Conversion

> **Phase:** 5 — The Sales Pipeline · **Builds on:** Lab 18 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-18` · **After:** tag `lab-19`

> This lab assumes you completed **Your Turn 1 in Lab 18** (`impl Validate for Deal` and
> `ValidationError::EmptyTitle`). If you skipped it, copy it from
> [Lab 18's solutions.md](../18-deals-and-pipeline/solutions.md#your-turn-1--validate-for-deal) first.

## 🎯 Goal
Add **leads**: people who *might* become customers. A qualified lead can be **converted** into a
company, a contact and (optionally) a deal in one step. After conversion the lead is gone, and
the compiler, not your discipline, makes sure you can't use it again.

## 🧠 What You'll Learn
- Methods that take **`self` by value**: ownership as a business rule
- E0382 **as a feature**: a compile error that enforces "a converted lead no longer exists"
- The **ownership round-trip**: an error type that hands the moved value *back* (`ConvertError { lead, .. }`)
- Destructuring a struct to move its fields out, and **partial moves**
- The **builder pattern**, by-value style (`fn x(mut self, ..) -> Self`), and why not `&mut self`
- Moving out from behind `&mut`: `std::mem::take`, `std::mem::replace`, `Option::take`, and why
  the compiler's "derive `Default`" suggestion can be the wrong fix
- `impl Into<String>` parameters
- `compile_fail` doc tests: documenting what *must not* compile
- `#[expect(lint, reason = "...")]` for deliberate clippy exceptions
- Why "remove, try, put back on failure" isn't a transaction (preview of Lab 31)

## 🔨 What We're Building
Sales teams don't start with companies. They start with **leads**: a name and an email from a
web form, a referral or a conference badge scan. Most leads go nowhere. Some get **qualified**
("real budget, real need"). A qualified lead is **converted**: it becomes a `Company`, a
`Contact` at that company, and often a first `Deal`.

```text
crm> lead add
Name: Grace Hopper
Email: grace@navy.example
Company name (blank for none): Navy Labs
Source (website/referral/event/cold_outreach/other, blank for other): referral
Notes (blank for none): Met at the compiler meetup
Added lead #1
crm> lead qualify 1
Lead #1 is qualified
crm> lead convert 1
Create a deal? (y/n): y
Deal title: COBOL modernisation
Deal value (e.g. 1250.50): 25000
Converted lead #1: company #2, contact #2, deal #1
```

The interesting part isn't the feature. It's the **rule**: *after converting, the lead must not
be used*. Not edited, not converted twice, not left lying around. In most languages that's a
comment and a code review. In Rust you'll make it a type-system fact.

New files by the end:

```text
src/leads/
├── mod.rs
├── model.rs        ← LeadId, LeadSource, LeadStatus, Lead
├── builder.rs      ← LeadBuilder
└── conversion.rs   ← ConversionIds, Conversion, ConvertError, ConversionSummary, Lead::convert
```

---

## Step 1 — The lead types

> 🟢 **FOLLOW ALONG**: create `src/leads/model.rs`.

```rust
use std::fmt;
use std::str::FromStr;

use super::LeadBuilder;
use crate::contacts::Email;
use crate::entity::Entity;
use crate::errors::{CrmError, ValidationError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LeadId(pub u64);

impl From<u64> for LeadId {
    fn from(id: u64) -> Self {
        LeadId(id)
    }
}

impl fmt::Display for LeadId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// Where a lead came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LeadSource {
    Website,
    Referral,
    Event,
    ColdOutreach,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LeadStatus {
    New,
    Qualified,
    Disqualified,
}

impl fmt::Display for LeadStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            LeadStatus::New => "new",
            LeadStatus::Qualified => "qualified",
            LeadStatus::Disqualified => "disqualified",
        };
        f.pad(label)
    }
}

/// Someone who might become a customer, but isn't one yet.
#[derive(Debug, Clone, PartialEq)]
pub struct Lead {
    pub id: LeadId,
    pub name: String,
    pub email: Email,
    pub company_name: Option<String>,
    pub source: LeadSource,
    pub status: LeadStatus,
    pub notes: Option<String>,
}

impl Entity for Lead {
    type Id = LeadId;

    fn id(&self) -> LeadId {
        self.id
    }

    fn label(&self) -> String {
        format!("Lead {} {}", self.id, self.name)
    }
}

impl fmt::Display for Lead {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:<5} {:<20} {:<28} {:<18} {:<14} {}",
            self.id.to_string(),
            self.name,
            self.email.as_str(),
            self.company_name.as_deref().unwrap_or("-"),
            self.source,
            self.status
        )
    }
}
```

Nothing here is new: an id newtype (`From<u64>` so `InMemoryRepo` can mint it), two `Copy` enums,
a struct with `Option`s for the optional parts, and an `Entity` impl. `company_name` is a
`String`, not a `CompanyId`, because a lead's company doesn't exist in the CRM *yet*. That's
the point of a lead.

`Lead` derives `Clone`. Hold that thought: you'll come back to whether cloning undermines
today's ownership rule in Step 6.

> 🔵 **Mini-task: `Display` and `FromStr` for `LeadSource`.**
> Write both impls in `model.rs` (code not shown here, see [solutions.md](solutions.md#mini-task-leadsource-display-and-fromstr)).
> - `Display` prints `website`, `referral`, `event`, `cold_outreach`, `other`, using `f.pad`
>   so it can be aligned in columns.
> - `FromStr` (`type Err = ValidationError`) accepts those words **case-insensitively**, and
>   also accepts `cold-outreach` with a dash. Anything else is
>   `ValidationError::InvalidValue { field: "lead source", value: <the input> }` (the variant
>   you added in Lab 18).
> - Add a round-trip test in the style of Lab 18's `stages_round_trip_through_strings`.
>   You'll need a list of all sources for it, either a `const ALL` or an inline array.

Create `src/leads/mod.rs`:

```rust
mod builder;
mod conversion;
mod model;

pub use builder::LeadBuilder;
pub use conversion::{Conversion, ConversionIds, ConversionSummary, ConvertError};
pub use model::{Lead, LeadId, LeadSource, LeadStatus};
```

…and add `pub mod leads;` to `src/lib.rs`. To make the module compile while you work, create
`src/leads/builder.rs` and `src/leads/conversion.rs` with placeholders:

```rust
// builder.rs (temporary)
pub struct LeadBuilder;
```

```rust
// conversion.rs (temporary)
pub struct Conversion;
pub struct ConversionIds;
pub struct ConversionSummary;
pub struct ConvertError;
```

Two new `CrmError` variants in `src/errors.rs`:

```rust
use crate::leads::LeadId;

// in enum CrmError:
    LeadNotQualified(LeadId),
    LeadDisqualified(LeadId),

// in impl Display for CrmError:
            CrmError::LeadNotQualified(id) => {
                write!(f, "lead {id} must be qualified before it can be converted")
            }
            CrmError::LeadDisqualified(id) => write!(f, "lead {id} has been disqualified"),
```

```bash
cargo check
```

You'll get "unused" warnings for the placeholders, which is fine for now.

## Step 2 — The builder pattern

A lead has seven fields. Two are required (`name`, `email`), three are optional
(`company_name`, `source`, `notes`), and two are *not the caller's business* (`id` is minted by
the repo, `status` always starts as `New`).

In TypeScript you'd write `createLead({ name, email, source: "referral" })`: an options object
with named, optional properties and defaults. Rust has **no named arguments and no default
arguments**. The alternatives:

| Option | Problem |
|---|---|
| `Lead::new(id, name, email, None, LeadSource::Other, None)` | Which `None` is which? Swap two `Option<String>`s and it still compiles. |
| Struct literal `Lead { .. }` | The caller must set `status`, so nothing stops `status: Qualified` on creation. No validation hook. |
| `#[derive(Default)]` + `..Default::default()` | `Lead` can't be `Default`: there's no default `Email` (more on that in Step 3). |
| **Builder** | Required parts up front, optional parts as named methods, validation in `build()`. |

> 🟢 **FOLLOW ALONG**: replace the placeholder in `src/leads/builder.rs`.

```rust
use super::{Lead, LeadId, LeadSource, LeadStatus};
use crate::contacts::Email;
use crate::errors::ValidationError;

/// Builds a [`Lead`] step by step. Every setter takes `self` by value and
/// returns it, so calls chain: `Lead::builder(..).source(..).notes(..).build()`.
#[derive(Debug)]
pub struct LeadBuilder {
    id: LeadId,
    name: String,
    email: Email,
    company_name: Option<String>,
    source: LeadSource,
    notes: Option<String>,
}

impl LeadBuilder {
    pub(super) fn new(id: LeadId, name: String, email: Email) -> Self {
        LeadBuilder {
            id,
            name,
            email,
            company_name: None,
            source: LeadSource::Other,
            notes: None,
        }
    }

    pub fn company_name(mut self, company_name: impl Into<String>) -> Self {
        self.company_name = Some(company_name.into());
        self
    }

    pub fn source(mut self, source: LeadSource) -> Self {
        self.source = source;
        self
    }

    pub fn notes(mut self, notes: impl Into<String>) -> Self {
        self.notes = Some(notes.into());
        self
    }

    /// Validates and produces the lead. Consumes the builder.
    pub fn build(self) -> Result<Lead, ValidationError> {
        let name = self.name.trim();
        if name.is_empty() {
            return Err(ValidationError::EmptyName);
        }
        Ok(Lead {
            id: self.id,
            name: name.to_string(),
            email: self.email,
            company_name: non_blank(self.company_name),
            source: self.source,
            status: LeadStatus::New,
            notes: non_blank(self.notes),
        })
    }
}

/// `Some("  ")` is not a company name: treat blank text as absent.
fn non_blank(value: Option<String>) -> Option<String> {
    value
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}
```

And the entry point, in `impl Lead` in `model.rs`:

```rust
impl Lead {
    /// Starts building a lead. `name` and `email` are required; everything else is optional.
    pub fn builder(id: LeadId, name: impl Into<String>, email: Email) -> LeadBuilder {
        LeadBuilder::new(id, name.into(), email)
    }
}
```

Now it reads like named arguments:

```rust
let lead = Lead::builder(LeadId(1), "Grace Hopper", email)
    .company_name("Navy Labs")
    .source(LeadSource::Referral)
    .build()?;
```

**Read the setter signature: `fn source(mut self, source: LeadSource) -> Self`.**

- `self` (not `&mut self`): the setter **takes ownership** of the builder…
- `mut self`: …binds it mutably (just like `let mut b = b;`)…
- `-> Self`: …and **gives ownership back** as the return value.

So `Lead::builder(..).company_name(..)` moves the builder into `company_name`, which moves it
back out, into `.source(..)`, and so on. The builder is a value passed hand to hand. No
borrows, no lifetimes, no clones. At the end, `build(self)` consumes it for good. A builder is
single-use, and **the type system knows it**: after `.build()`, the builder is moved.

**`impl Into<String>`** means "anything that can become a `String`". Callers can pass `"Navy
Labs"` (a `&str`), a `String` they already own (moved, with no copy), or anything else with
`From<..> for String`. The function calls `.into()` once. It's the polite way to accept owned
text.

**Encapsulation:** the builder's fields are private and `new` is `pub(super)` (visible in
`leads` only). Outside the module, the *only* way to make a `LeadBuilder` is `Lead::builder`,
and the only way out is `build()`, which validates. `status` isn't settable at all: every lead
starts `New`.

**`non_blank`** chains `Option` combinators from Lab 12. `map` transforms the `String` if
present, and `filter` turns `Some("")` into `None`. Blank prompt answers become `None`
naturally.

Add tests at the bottom of `builder.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn email() -> Email {
        Email::parse("grace@navy.example").unwrap()
    }

    #[test]
    fn builder_sets_defaults() {
        let lead = Lead::builder(LeadId(1), "Grace Hopper", email()).build().unwrap();
        assert_eq!(lead.source, LeadSource::Other);
        assert_eq!(lead.status, LeadStatus::New);
        assert_eq!(lead.company_name, None);
    }

    #[test]
    fn builder_chains_optional_fields() {
        let lead = Lead::builder(LeadId(1), "Grace Hopper", email())
            .company_name("Navy Labs")
            .source(LeadSource::Referral)
            .notes("Met at the compiler meetup")
            .build()
            .unwrap();
        assert_eq!(lead.company_name.as_deref(), Some("Navy Labs"));
        assert_eq!(lead.source, LeadSource::Referral);
        assert_eq!(lead.notes.as_deref(), Some("Met at the compiler meetup"));
    }

    #[test]
    fn builder_rejects_blank_name_and_drops_blank_options() {
        let result = Lead::builder(LeadId(1), "   ", email()).build();
        assert_eq!(result, Err(ValidationError::EmptyName));

        let lead = Lead::builder(LeadId(1), "Grace", email())
            .company_name("  ")
            .build()
            .unwrap();
        assert_eq!(lead.company_name, None);
    }
}
```

```bash
cargo test leads
```

### The cost of by-value: conditional chaining

There's one awkward case. When an optional value is itself an `Option` (from a prompt), you
can't write `.company_name(maybe_name)`. You **rebind**:

```rust
let mut builder = Lead::builder(id, name, email).source(source);
if let Some(company_name) = company_name {
    builder = builder.company_name(company_name);   // move out, move back in
}
```

`builder = builder.company_name(..)` reads strangely at first. It moves the builder *out of*
the variable into the method, and assigns the returned builder *back into* the variable. You'll
write exactly this in `Crm::add_lead` in Step 6.

## Step 3 — 🟡 Why not a `&mut self` builder?

Plenty of builders in the wild use `fn source(&mut self, ..) -> &mut Self`. Why did we choose
by-value? Let the compiler explain.

> 🟡 **EXPERIMENT**: add this method to `builder.rs` (a builder that only *borrows* itself
> when building), then run `cargo check`. Predict the error first.

```rust
impl LeadBuilder {
    /// Experiment: a builder that only borrows itself.
    pub fn build_in_place(&mut self) -> Lead {
        Lead {
            id: self.id,
            name: self.name,
            email: self.email,
            company_name: self.company_name,
            source: self.source,
            status: LeadStatus::New,
            notes: self.notes,
        }
    }
}
```

```text
error[E0507]: cannot move out of `self.name` which is behind a mutable reference
  --> src/leads/builder.rs:67:19
   |
67 |             name: self.name,
   |                   ^^^^^^^^^ move occurs because `self.name` has type `String`, which does not implement the `Copy` trait
   |
help: consider cloning the value if the performance cost is acceptable
   |
67 |             name: self.name.clone(),
   |                            ++++++++

error[E0507]: cannot move out of `self.email` which is behind a mutable reference
  --> src/leads/builder.rs:68:20
   |
68 |             email: self.email,
   |                    ^^^^^^^^^^ move occurs because `self.email` has type `Email`, which does not implement the `Copy` trait

error[E0507]: cannot move out of `self.company_name` which is behind a mutable reference
...
error[E0507]: cannot move out of `self.notes` which is behind a mutable reference
...
```

**Read the error.** Ask the four questions:

- **Who owns** the builder? The *caller*. We only have `&mut self`, a mutable **borrow**.
- **Was something moved?** We're *trying* to move `self.name` (a `String`) into the new `Lead`.
- **Is it a borrow?** Yes, a mutable one. `&mut` lets you *change* the value. It doesn't let
  you *take it away*. When the borrow ends, the owner gets the builder back and may read
  `builder.name`. If we'd moved the `String` out, that field would be a dangling,
  already-moved hole. Rust's rule: **a value behind a reference must always be complete and
  valid.**
- `id` and `source` aren't reported: they're `Copy`, so "moving" them just copies.

The compiler suggests `.clone()`. That works, but it copies every string, and the builder keeps
its own copies, which could then build a *second* identical lead. Not what we want.

### Moving out of `&mut`: leave something valid behind

The standard library has three tools for exactly this situation. They all follow one rule:
**you may take a value out from behind `&mut` if you put a valid value back in the same
operation.**

| Tool | What it does | Requires |
|---|---|---|
| `std::mem::take(&mut x)` | Returns `x`, leaves `T::default()` in its place | `T: Default` |
| `std::mem::replace(&mut x, new)` | Returns `x`, leaves `new` in its place | a replacement value you supply |
| `opt.take()` on `Option<T>` | Returns the `Option`, leaves `None` | nothing (it's `mem::replace(opt, None)`) |

> 🟡 **EXPERIMENT (continued)**: change the body to use them, then `cargo check` again.

```rust
            name: std::mem::take(&mut self.name),        // leaves ""
            email: std::mem::take(&mut self.email),      // leaves ...?
            company_name: self.company_name.take(),      // leaves None
            source: self.source,
            status: LeadStatus::New,
            notes: self.notes.take(),                    // leaves None
```

```text
error[E0277]: the trait bound `Email: Default` is not satisfied
  --> src/leads/builder.rs:68:35
   |
68 |             email: std::mem::take(&mut self.email),
   |                    -------------- ^^^^^^^^^^^^^^^ the trait `Default` is not implemented for `Email`
   |                    |
   |                    required by a bound introduced by this call
   |
note: required by a bound in `std::mem::take`
help: consider annotating `Email` with `#[derive(Default)]`
  --> src/contacts/email.rs:7:1
   |
 7 + #[derive(Default)]
 8 | pub struct Email(String);
   |
```

`String`, `Option<String>`: fine. `Email`: no default. **And the compiler's suggestion is
wrong for us.** `#[derive(Default)]` on `Email` would create `Email("")`, an email that
never went through validation. That breaks the invariant you built in Lab 12 and protected
with privacy in Lab 13: *every `Email` value is a valid address*. Compiler suggestions fix the
*type error*, but only you know your *invariants*. Read every `help:` line critically.

`mem::replace` doesn't help either: what valid `Email` would you put back? A fake one? The
honest options are to change the field to `Option<Email>` (and then `build` must handle
`None`), or `clone`. Both are worse than the design we already have.

**The by-value builder sidesteps the whole problem.** `build(self)` *owns* the builder, so it
can move every field out freely, with no placeholders, defaults or clones. The builder is
consumed, so nobody can observe the half-empty remains.

> 💡 **Where `take`/`replace` *are* the right tool:** whenever you genuinely only have `&mut`
> access and must extract an owned value, e.g. inside `impl Drop for X` (you only get
> `&mut self`), taking a `JoinHandle` out of an `Option<JoinHandle<()>>` field to `.join()` it,
> or swapping a buffer out of a struct to process it: `let batch = std::mem::take(&mut
> self.pending);`. Recognise the shape "I have `&mut`, I need ownership", and reach for these.

Delete `build_in_place`. It was only there to make the point.

## Step 4 — Qualifying a lead

Leads move `New → Qualified`, and either can become `Disqualified`. Qualifying is *idempotent*
(qualifying twice is fine), but a disqualified lead can't be qualified again. (Sales teams
usually create a fresh lead when someone comes back.)

> 🟢 **FOLLOW ALONG**: add to `impl Lead` in `model.rs`:

```rust
    pub fn qualify(&mut self) -> Result<(), CrmError> {
        match self.status {
            LeadStatus::New | LeadStatus::Qualified => {
                self.status = LeadStatus::Qualified;
                Ok(())
            }
            LeadStatus::Disqualified => Err(CrmError::LeadDisqualified(self.id)),
        }
    }
```

No wildcard this time. If someone adds a `LeadStatus` variant, this `match` must be revisited
(Lab 18, Experiment 3). `disqualify` is yours in Your Turn 2.

## Step 5 — Conversion: consuming `self`

Here's the core of the lab. First the data types. Replace the placeholders in
`src/leads/conversion.rs`:

> 🟢 **FOLLOW ALONG**

```rust
use std::fmt;

use super::{Lead, LeadStatus};
use crate::companies::{Company, CompanyId, Lifecycle};
use crate::contacts::{Contact, ContactId};
use crate::deals::{Deal, DealId, DealStage};
use crate::entity::Validate;
use crate::errors::CrmError;
use crate::money::Money;

/// The ids the new records will get. The caller (the `Crm`) owns the id
/// counters, so it mints them and hands them in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConversionIds {
    pub company: CompanyId,
    pub contact: ContactId,
    pub deal: DealId,
}

/// Everything a converted lead turns into.
#[derive(Debug, Clone, PartialEq)]
pub struct Conversion {
    pub company: Company,
    pub contact: Contact,
    pub deal: Option<Deal>,
}

/// A failed conversion. The lead was moved into `convert`, so the error
/// hands it back: the caller gets ownership again and decides what to do.
#[derive(Debug)]
pub struct ConvertError {
    pub lead: Lead,
    pub reason: CrmError,
}

impl fmt::Display for ConvertError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "could not convert lead {}: {}", self.lead.id, self.reason)
    }
}

impl std::error::Error for ConvertError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.reason)
    }
}

/// What `Crm::convert_lead` reports back: just the new ids.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConversionSummary {
    pub company_id: CompanyId,
    pub contact_id: ContactId,
    pub deal_id: Option<DealId>,
}
```

(`Company` and `Contact` need `PartialEq` for `Conversion` to derive it. They have it if you
followed Lab 14/15. If not, add it to their derives.)

Why does `convert` take **ids** instead of a `&mut Crm`? Because `Lead::convert` is *pure domain
logic*. It decides **what** records a lead becomes. The `Crm` owns the id counters and the
repositories, so it decides **where** they go. Keeping `convert` free of the `Crm` makes it
testable with plain values, and in Lab 31 the same function is reused unchanged with ids that
come from Postgres.

Now the method. Add it to `conversion.rs`:

```rust
impl Lead {
    /// Turns a qualified lead into a company, a contact and (optionally) a deal.
    ///
    /// Takes `self` by value: after a successful conversion the lead no
    /// longer exists, and the compiler won't let you use it.
    pub fn convert(
        self,
        ids: ConversionIds,
        deal: Option<(String, Money)>,
    ) -> Result<Conversion, ConvertError> {
        if self.status != LeadStatus::Qualified {
            let reason = CrmError::LeadNotQualified(self.id);
            return Err(ConvertError { lead: self, reason });
        }

        let deal = deal.map(|(title, value)| Deal {
            id: ids.deal,
            company_id: ids.company,
            title,
            value,
            stage: DealStage::Qualification,
        });
        if let Some(deal) = &deal
            && let Err(e) = deal.validate()
        {
            return Err(ConvertError {
                lead: self,
                reason: e.into(),
            });
        }

        // Point of no return: from here on, `self` is taken apart.
        let Lead {
            name,
            email,
            company_name,
            ..
        } = self;

        let company = Company {
            id: ids.company,
            name: company_name.unwrap_or_else(|| format!("{name} (individual)")),
            website: None,
            lifecycle: Lifecycle::Prospect,
        };
        let contact = Contact {
            id: ids.contact,
            name,
            email,
            phone: None,
            company_id: Some(ids.company),
        };
        Ok(Conversion {
            company,
            contact,
            deal,
        })
    }
}
```

Read it as an **ownership story**:

1. **`self`** by value: the caller hands over the whole lead. From the caller's point of view,
   the lead is gone the moment they call `convert`, whatever happens next.
2. **Failure path 1**: not qualified. We still own `self` completely, so we **put it inside the
   error** and return it: `ConvertError { lead: self, reason }`. Ownership travels back out
   through the `Err`. This is the *ownership round-trip*.
3. **Failure path 2**: the optional deal is invalid (the `Validate for Deal` you wrote in
   Lab 18). Same move: the lead goes back inside the error. (`if let ... && let ...` is a
   **let chain**, new in edition 2024: both patterns must match.)
4. **The point of no return.** `let Lead { name, email, company_name, .. } = self;`
   **destructures** the lead, moving three fields out into local variables. `..` ignores the
   rest (`id`, `source`, `status` and `notes` are dropped here). After this line, `self` no
   longer exists as a whole value, so we can't hand it back anymore. That's why **every
   check that might fail happens before this line**.
5. **Success**: the moved-out `String`s and `Email` go straight into the new `Company` and
   `Contact`. No clones anywhere. The lead's name literally *becomes* the contact's name: the
   same heap allocation, a new owner.

`company_name.unwrap_or_else(|| format!("{name} (individual)"))`: a lead without a company is a
person buying for themselves, so the company is named after them. The closure *borrows* `name`
(it only runs if needed), and `name` is moved into `contact` afterwards. The borrow has ended by
then, so the borrow checker is happy with this order.

> 💡 **Precedent in the standard library.** This "error hands the input back" shape is common:
> `String::from_utf8(bytes)` fails with a `FromUtf8Error` that has `.into_bytes()` to recover
> your `Vec<u8>`. `mpsc::Sender::send(value)` fails with `SendError(value)`. When a function
> *consumes* something and might fail, returning it in the error is the courteous design.

> 🟡 **EXPERIMENT: partial moves.** Cut the `if let Some(deal) = &deal && ...` block and paste
> it **below** the `let Lead { .. } = self;` line. Predict, then `cargo check`.

```text
error[E0382]: use of partially moved value: `self`
  --> src/leads/conversion.rs:99:23
   |
91 |             company_name,
   |             ------------ value partially moved here
...
99 |                 lead: self,
   |                       ^^^^ value used here after partial move
   |
   = note: partial move occurs because `self.company_name` has type `Option<String>`, which does not implement the `Copy` trait
help: borrow this binding in the pattern to avoid moving the value
   |
91 |             ref company_name,
   |             +++
```

**Read the error.** *Who owns* `company_name` now? The local variable. *Was `self` moved?*
**Partially**: some fields left, so `self` as a whole can't be used, though its remaining
fields (`self.source`, say) still could be. The `help` suggests `ref company_name`, which would
*borrow* instead of move, and then we'd have to clone it into the `Company` later. That's the
wrong fix again. The right fix is the **order**: validate while you still own the whole thing.
Put the block back above the destructuring.

### A clippy note: `result_large_err`

Run `cargo clippy`:

```text
warning: the `Err`-variant returned from this function is very large
  --> src/leads/conversion.rs:77:10
   |
77 |     ) -> Result<Conversion, ConvertError> {
   |          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ the `Err`-variant is at least 152 bytes
   |
   = help: try reducing the size of `leads::conversion::ConvertError`, for example by boxing large elements or replacing it with `Box<leads::conversion::ConvertError>`
```

Clippy's reasoning: errors are usually *rare*, and a big `Err` makes *every* `Result` of that type
big. That means more bytes copied on every return, even on the happy path. Usually you'd
`Box` the large part. Here, though, the large error is **the point**: it carries the lead home.
And `Conversion` (the `Ok` side) is even bigger, so boxing the error would save nothing.

When you disagree with a lint, say so **in code, with a reason**. Put this right above
`pub fn convert`:

```rust
    #[expect(
        clippy::result_large_err,
        reason = "ConvertError carries the whole Lead back to the caller on purpose"
    )]
```

`#[expect]` is stricter than `#[allow]`: if the lint ever *stops* firing (say you box something
later), you get a warning that the expectation is unfulfilled, so stale exceptions don't pile up.

### Tests for the domain logic

Add to the bottom of `conversion.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::contacts::Email;
    use crate::leads::LeadId;

    fn qualified_lead() -> Lead {
        let mut lead = Lead::builder(LeadId(1), "Grace Hopper", Email::parse("grace@navy.example").unwrap())
            .company_name("Navy Labs")
            .build()
            .unwrap();
        lead.qualify().unwrap();
        lead
    }

    fn ids() -> ConversionIds {
        ConversionIds { company: CompanyId(10), contact: ContactId(20), deal: DealId(30) }
    }

    #[test]
    fn converts_a_qualified_lead_with_a_deal() {
        let deal = Some(("COBOL modernisation".to_string(), Money::from_cents(2_500_000)));
        let conversion = qualified_lead().convert(ids(), deal).unwrap();

        assert_eq!(conversion.company.id, CompanyId(10));
        assert_eq!(conversion.company.name, "Navy Labs");
        assert_eq!(conversion.company.lifecycle, Lifecycle::Prospect);
        assert_eq!(conversion.contact.name, "Grace Hopper");
        assert_eq!(conversion.contact.company_id, Some(CompanyId(10)));
        let deal = conversion.deal.unwrap();
        assert_eq!((deal.id, deal.company_id), (DealId(30), CompanyId(10)));
        assert_eq!(deal.stage, DealStage::Qualification);
    }

    #[test]
    fn a_lead_without_company_becomes_an_individual() {
        let mut lead = qualified_lead();
        lead.company_name = None;
        let conversion = lead.convert(ids(), None).unwrap();
        assert_eq!(conversion.company.name, "Grace Hopper (individual)");
        assert_eq!(conversion.deal, None);
    }

    #[test]
    fn an_unqualified_lead_is_handed_back() {
        let lead = Lead::builder(LeadId(1), "Grace", Email::parse("g@navy.example").unwrap())
            .build()
            .unwrap();
        let original = lead.clone();

        let err = lead.convert(ids(), None).unwrap_err();

        assert!(matches!(err.reason, CrmError::LeadNotQualified(LeadId(1))));
        assert_eq!(err.lead, original);
    }
}
```

`an_unqualified_lead_is_handed_back` checks the round-trip: what comes back in the error is
*equal to* what went in. Note that the test needs a `clone()` to have something to compare
against: once `lead` is moved into `convert`, the test can't look at it anymore.

### Documenting what must *not* compile

The best documentation of "you can't use a lead after converting it" is a snippet that **fails to
compile**. Rustdoc supports exactly that. Add these lines to the doc comment on `convert`, after
the existing ones:

```rust
    ///
    /// ```compile_fail
    /// # use rust_crm::leads::*;
    /// # fn demo(lead: Lead, ids: ConversionIds) {
    /// let conversion = lead.convert(ids, None);
    /// println!("{}", lead.name); // error[E0382]: borrow of moved value: `lead`
    /// # }
    /// ```
```

```bash
cargo test --doc
```

```text
test src/leads/conversion.rs - leads::conversion::Lead::convert (line 66) - compile fail ... ok
```

A `compile_fail` doc test **passes when the snippet fails to compile**. Lines starting with `# `
are compiled but hidden from the rendered docs (`cargo doc --open` shows only the two
meaningful lines). One catch: on stable Rust, rustdoc does *not* check *which* error occurs. A
typo would also "pass". So keep the snippet tiny, and do a **positive control** once: delete
the `println!` line and confirm the test now *fails* ("Test compiled successfully, but it's
marked `compile_fail`"). Then restore it.

## Step 6 — `Crm::convert_lead`: removing, converting, putting back

> 🟢 **FOLLOW ALONG**: in `src/crm.rs`, add the repo and the methods.

```rust
use crate::leads::{
    Conversion, ConversionIds, ConversionSummary, ConvertError, Lead, LeadId, LeadSource,
};

pub struct Crm {
    pub companies: InMemoryRepo<Company>,
    pub contacts: InMemoryRepo<Contact>,
    pub deals: InMemoryRepo<Deal>,
    pub leads: InMemoryRepo<Lead>,
}
```

```rust
    pub fn add_lead(
        &mut self,
        name: String,
        email: Email,
        company_name: Option<String>,
        source: LeadSource,
        notes: Option<String>,
    ) -> Result<LeadId, CrmError> {
        let mut builder = Lead::builder(LeadId(0), name, email).source(source);
        if let Some(company_name) = company_name {
            builder = builder.company_name(company_name);
        }
        if let Some(notes) = notes {
            builder = builder.notes(notes);
        }
        let mut lead = builder.build()?;
        lead.id = self.leads.next_id();
        Ok(self.leads.insert(lead))
    }

    pub fn lead(&self, id: LeadId) -> Result<&Lead, CrmError> {
        self.leads.get(id).ok_or(CrmError::NotFound {
            entity: "lead",
            id: id.0,
        })
    }

    fn lead_mut(&mut self, id: LeadId) -> Result<&mut Lead, CrmError> {
        self.leads.get_mut(id).ok_or(CrmError::NotFound {
            entity: "lead",
            id: id.0,
        })
    }

    pub fn qualify_lead(&mut self, id: LeadId) -> Result<(), CrmError> {
        self.lead_mut(id)?.qualify()
    }
```

`add_lead` uses the placeholder-id trick from Lab 18's Your Turn 1: build and validate with
`LeadId(0)`, and only mint a real id once the lead is valid. `self.lead_mut(id)?.qualify()`
chains a lookup and a mutation through `?`. The `&mut Lead` lives only for that one expression.

Now the conversion:

```rust
    /// Converts a qualified lead into a company, a contact and optionally a deal.
    /// On failure the lead stays in the CRM, untouched.
    pub fn convert_lead(
        &mut self,
        id: LeadId,
        deal: Option<(String, Money)>,
    ) -> Result<ConversionSummary, CrmError> {
        // 1. Checks that need the rest of the CRM: done while we only *borrow* the lead.
        let lead = self.lead(id)?;
        if self.contacts.email_exists(&lead.email) {
            return Err(CrmError::DuplicateEmail(lead.email.as_str().to_string()));
        }

        // 2. Take ownership: the lead leaves the repo.
        let lead = self.leads.remove(id).ok_or(CrmError::NotFound {
            entity: "lead",
            id: id.0,
        })?;
        let ids = ConversionIds {
            company: self.companies.next_id(),
            contact: self.contacts.next_id(),
            deal: self.deals.next_id(),
        };

        // 3. Convert. On failure, the error hands the lead back and we put it back.
        match lead.convert(ids, deal) {
            Ok(Conversion {
                company,
                contact,
                deal,
            }) => {
                let company_id = self.companies.insert(company);
                let contact_id = self.contacts.insert(contact);
                let deal_id = deal.map(|deal| self.deals.insert(deal));
                Ok(ConversionSummary {
                    company_id,
                    contact_id,
                    deal_id,
                })
            }
            Err(ConvertError { lead, reason }) => {
                self.leads.insert(lead);
                Err(reason)
            }
        }
    }
```

(If your `CrmError::DuplicateEmail` holds something other than a `String`, adapt that line.)

Three phases, three ownership modes:

1. **Borrow.** `let lead = self.lead(id)?` gives a `&Lead`. We need *other* repos (`contacts`)
   to check uniqueness, and a contact's email must be unique (Lab 12). Checks that need the
   whole CRM happen here, while the lead is safely in its repo. If they fail, there's nothing
   to undo. The borrow ends after the `if`, which is what lets us call `self.leads.remove`
   next. (Non-lexical lifetimes, Lab 08.)
2. **Own.** `self.leads.remove(id)` returns `Option<Lead>`: the repo gives up ownership.
   Then we mint the three ids.
3. **Hand over, maybe get back.** `lead.convert(ids, deal)` moves the lead in. On `Ok`, the
   `Conversion` is destructured and each part is moved into its repo. On `Err`, the pattern
   `ConvertError { lead, reason }` **destructures the error**: `lead` is ours again, and we
   re-insert it.

`deal.map(|deal| self.deals.insert(deal))` turns `Option<Deal>` into `Option<DealId>`. The
closure captures `self.deals` mutably, and only that field: closures capture *disjoint fields*
since edition 2021, so this doesn't conflict with anything else.

> 🟡 **EXPERIMENT: E0382, the error you *want*.** Inside the `Ok(..)` arm, before inserting
> the company, add a friendly log line:
> ```rust
>                 println!("Converting {}", lead.name);
> ```
> Predict, then `cargo check`.

```text
error[E0382]: borrow of moved value: `lead`
   --> src/crm.rs:234:43
    |
217 |         let lead = self.leads.remove(id).ok_or(CrmError::NotFound {
    |             ---- move occurs because `lead` has type `Lead`, which does not implement the `Copy` trait
...
228 |         match lead.convert(ids, deal) {
    |                    ------------------ `lead` moved due to this method call
...
234 |                 println!("Converting {}", lead.name);
    |                                           ^^^^^^^^^ value borrowed here after move
    |
note: `leads::conversion::<impl leads::model::Lead>::convert` takes ownership of the receiver `self`, which moves `lead`
   --> src/leads/conversion.rs:70:9
    |
 70 |         self,
    |         ^^^^
help: you can `clone` the value and consume it, but this might not be your desired behavior
    |
228 |         match lead.clone().convert(ids, deal) {
    |                   ++++++++
```

In Lab 06, E0382 was an obstacle. Here it's **your business rule, enforced by the compiler**.
The note says it in plain words: `convert` *takes ownership of the receiver `self`*. After a
successful conversion, no code path anywhere in the program can read, modify, qualify or
re-convert that lead. Nobody had to remember a rule.

**Who owns the data now?** The contact owns the name. Fix the experiment by asking the right
owner: `println!("Converting {}", contact.name);`. Or better, delete the `println!`, because
domain code shouldn't print. The CLI will.

**And the `clone()` suggestion?** "This might not be your desired behavior" is the
compiler being honest. `lead.clone().convert(..)` would convert a *copy* and keep the
original: a converted lead that still exists, still says `Qualified`, and can be converted
again into a *second* company. That's precisely the bug the move prevents. This is also why
deriving `Clone` on `Lead` (Step 1) is fine: cloning is always **explicit and visible**. The
compiler stops *accidental* reuse, and a deliberate `.clone()` stands out in code review.
(Later labs snapshot the whole CRM, which needs `Clone`.)

### Is this a transaction?

"Remove the lead, try, put it back on failure" *looks* like a rollback. It isn't one, and it's
worth seeing exactly why:

- **The re-insert isn't a perfect undo.** `InMemoryRepo::insert` pushes to the end of its
  `Vec`. A failed conversion moves the lead to the *end* of `lead list`. Try it in the
  🧪 Experiment section.
- **Ids are burned.** `next_id()` ran three times before `convert` failed. The next company
  gets a higher number than you'd expect. (Postgres sequences do the same thing on a rolled-back
  insert. Gaps are normal. Don't build features that depend on contiguous ids.)
- **The success path is atomic only by accident.** Inserting into an `InMemoryRepo` can't fail,
  so company + contact + deal always land together. But suppose a future version validated on
  insert, or wrote each insert to disk (Lab 21 saves the CRM *after* each command, so we're safe
  there), and the contact insert failed after the company was stored. You'd have an orphan
  company *and* a lost lead. The code above has no way to undo the company insert.

In memory, single-threaded, the shortcuts hold. In **Lab 31** this exact operation moves to
PostgreSQL inside a **database transaction**: `BEGIN`, lock the lead row, insert company,
contact and deal, mark the lead converted, `COMMIT`. If anything fails, *everything* is rolled
back, and Rust will roll back automatically when the transaction value is **dropped** without
being committed. `Lead::convert` itself survives unchanged. It's pure, so it doesn't care where
the ids come from.

## Step 7 — Commands: `lead …`

> 🟢 **FOLLOW ALONG**: in `src/cli/parser.rs`:

```rust
use crate::leads::LeadId;

pub(crate) enum Command<'a> {
    // ...existing variants...
    Lead(LeadCommand),
}

#[derive(Debug, PartialEq)]
pub(crate) enum LeadCommand {
    Add,
    List,
    Qualify { id: LeadId },
    Convert { id: LeadId },
}
```

Dispatch arm: `"lead" => Command::Lead(parse_lead(&args)?),`, and the sub-parser:

```rust
fn parse_lead(args: &[&str]) -> Result<LeadCommand, CrmError> {
    const USAGE: &str = "lead add|list|qualify <id>|convert <id>";

    let id = |raw: &str| raw.parse().map(LeadId).map_err(|_| CrmError::Usage(USAGE));
    match args {
        ["add"] => Ok(LeadCommand::Add),
        ["list"] => Ok(LeadCommand::List),
        ["qualify", raw] => Ok(LeadCommand::Qualify { id: id(raw)? }),
        ["convert", raw] => Ok(LeadCommand::Convert { id: id(raw)? }),
        _ => Err(CrmError::Usage(USAGE)),
    }
}
```

`raw.parse().map(LeadId)` uses a **tuple-struct constructor as a function**: `LeadId` has
type `fn(u64) -> LeadId`, so it can be passed straight to `map`. The local closure `id`
removes the repetition. It captures nothing but the `USAGE` constant, so it's a plain `Fn`.

Add a test next to your other parser tests:

```rust
    #[test]
    fn parses_lead_commands() {
        assert_eq!(
            parse_command("lead convert 7").unwrap(),
            Some(Command::Lead(LeadCommand::Convert { id: LeadId(7) }))
        );
        assert!(matches!(parse_command("lead convert x"), Err(CrmError::Usage(_))));
    }
```

In `src/cli/commands.rs`, route `Command::Lead(cmd) => lead(crm, cmd)?,` and add the handler.
Like Lab 17, `prompt_optional` is a small helper that returns `None` for blank input. Use
yours, or write it now:

```rust
use crate::leads::LeadSource;

fn lead(crm: &mut Crm, cmd: LeadCommand) -> Result<(), CrmError> {
    match cmd {
        LeadCommand::Add => {
            let name = prompt("Name: ");
            let email = Email::parse(&prompt("Email: "))?;
            let company_name = prompt_optional("Company name (blank for none): ");
            let source = match prompt_optional(
                "Source (website/referral/event/cold_outreach/other, blank for other): ",
            ) {
                Some(raw) => raw.parse()?,
                None => LeadSource::Other,
            };
            let notes = prompt_optional("Notes (blank for none): ");
            let id = crm.add_lead(name, email, company_name, source, notes)?;
            println!("Added lead {id}");
        }
        LeadCommand::List => {
            if crm.leads.is_empty() {
                println!("No leads yet.");
            }
            for lead in crm.leads.iter() {
                println!("{lead}");
            }
        }
        LeadCommand::Qualify { id } => {
            crm.qualify_lead(id)?;
            println!("Lead {id} is qualified");
        }
        LeadCommand::Convert { id } => {
            crm.lead(id)?; // fail fast before asking questions
            let deal = if prompt("Create a deal? (y/n): ").eq_ignore_ascii_case("y") {
                let title = prompt("Deal title: ");
                let value = Money::parse(&prompt("Deal value (e.g. 1250.50): "))?;
                Some((title, value))
            } else {
                None
            };
            let summary = crm.convert_lead(id, deal)?;
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

`raw.parse()?` relies on your `FromStr for LeadSource` (Step 1 mini-task), so the type is
inferred from the `match`'s other arm (`LeadSource::Other`). Add `lead …` to `print_help`.

---

## ▶️ Run It

```bash
cargo run
```

```text
company add
Acme Corp

contact add
Ada Lovelace
ada@acme.example

1
lead add
Grace Hopper
grace@navy.example
Navy Labs
referral
Met at the compiler meetup
lead add
Linus
linus@kernel.example



lead add
Ada Again
ADA@acme.example

event

lead list
lead convert 1
n
lead qualify 1
lead convert 1
y
COBOL modernisation
25000
lead qualify 3
lead convert 3
n
lead qualify 2
lead convert 2
n
lead list
company list
contact list
deal list
quit
```

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> Name: Website (blank for none): Added company #1
crm> Name: Email: Phone (blank for none): Company id (blank for none): Added contact #1
crm> Name: Email: Company name (blank for none): Source (website/referral/event/cold_outreach/other, blank for other): Notes (blank for none): Added lead #1
crm> Name: Email: Company name (blank for none): Source (website/referral/event/cold_outreach/other, blank for other): Notes (blank for none): Added lead #2
crm> Name: Email: Company name (blank for none): Source (website/referral/event/cold_outreach/other, blank for other): Notes (blank for none): Added lead #3
crm> #1    Grace Hopper         grace@navy.example           Navy Labs          referral       new
#2    Linus                linus@kernel.example         -                  other          new
#3    Ada Again            ada@acme.example             -                  event          new
crm> Create a deal? (y/n): Error: lead #1 must be qualified before it can be converted
crm> Lead #1 is qualified
crm> Create a deal? (y/n): Deal title: Deal value (e.g. 1250.50): Converted lead #1: company #3, contact #3, deal #2
crm> Lead #3 is qualified
crm> Create a deal? (y/n): Error: a contact with email ada@acme.example already exists
crm> Lead #2 is qualified
crm> Create a deal? (y/n): Converted lead #2: company #4, contact #4
crm> #3    Ada Again            ada@acme.example             -                  event          qualified
crm> #1    Acme Corp                prospect   -
#3    Navy Labs                prospect   -
#4    Linus (individual)       prospect   -
crm> #1    Ada Lovelace         ada@acme.example             -            #1
#3    Grace Hopper         grace@navy.example           -            #3
#4    Linus                linus@kernel.example         -            #4
crm> #2    COBOL modernisation        $25,000.00  qualification  company #3
crm> Goodbye! (18 commands this session)
```

(Your company/contact row formats come from your own Lab 15 `Display` impls.)

Check each behaviour against the code:

- **Converting an unqualified lead failed**, and lead #1 was still there to qualify. The
  round-trip worked.
- **Grace became company #3, contact #3, deal #2**, not #2/#2/#1. The failed attempt burned
  one id from each counter. That's the "ids are burned" bullet from Step 6, in real output.
- **"Ada Again" was blocked** by the duplicate-email check (her email was normalised to
  lowercase by `Email`, Lab 12). The check ran while the lead was only borrowed, so lead #3
  is still listed and still `qualified`.
- **Linus became "Linus (individual)"**, and no deal was created.
- **Converted leads are gone** from `lead list`. Only #3 remains.

## 🧠 Understand It

**`self` vs `&self` vs `&mut self` is an API decision about the *business*.**

| Receiver | Meaning for the caller | Used for |
|---|---|---|
| `&self` | "I'll look at it" | `Display`, `label`, filters |
| `&mut self` | "I'll change it, you keep it" | `qualify`, `move_to` |
| `self` | "Give it to me. It won't exist as it was" | `convert`, `build` |

Choosing `self` for `convert` encodes "conversion is a one-way door" in the signature. Every
caller, now and in a year, gets that rule from the type checker.

**The ownership round-trip:**

```text
   Crm (owns leads repo)
     │ leads.remove(id)  → Lead (owned by convert_lead)
     ▼
   lead.convert(ids, deal)   — moved in
     ├── Ok(Conversion { company, contact, deal })  → moved into repos
     └── Err(ConvertError { lead, reason })         → lead moved back out → leads.insert(lead)
```

Ownership never gets *lost* by accident. On every path, some variable owns every value, and
the compiler tracks it. A version that "forgot" to re-insert on failure would still compile:
the lead would simply be *dropped* at the end of the `Err` arm. Your only clue is an
`unused variable` warning (🧪 Experiment 3). Read your warnings.

**Builders, consumed.** `LeadBuilder` uses the same ownership idea at a smaller scale. Each
setter moves the builder through, `build()` consumes it, and a builder can't be reused by
accident.

**Domain vs orchestration.** `Lead::convert` (domain) knows the *rules*: qualified only, valid
deal, how a lead maps onto company/contact/deal. `Crm::convert_lead` (orchestration) knows
the *storage*: which repos, which ids, what to undo. In Lab 31 the orchestration is rewritten
for Postgres, and the domain function and its tests don't change.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: the re-insert isn't a perfect undo.** Start a fresh session. Add two
> leads, then try to convert lead #1 *without* qualifying it, then list:

```text
crm> #1    Grace Hopper         grace@navy.example           Navy Labs          referral       new
#2    Linus                linus@kernel.example         -                  website        new
crm> Create a deal? (y/n): Error: lead #1 must be qualified before it can be converted
crm> #2    Linus                linus@kernel.example         -                  website        new
#1    Grace Hopper         grace@navy.example           Navy Labs          referral       new
```

Lead #1 moved to the bottom. **Question:** name two ways to fix this. (Hint: one changes where
the lead is put back, one changes how the list is displayed.) Which one would you choose, and
why might neither matter once the data lives in Postgres?

> 🟡 **EXPERIMENT 2: what if `convert` took `&self`?** Change the receiver to `&self` (don't
> fix everything, just read the errors). Which lines fail? How would `convert` have to build
> `contact.name` and `contact.email` now? After a successful conversion, what would
> `convert_lead` have to remember to do with the lead? Revert.

> 🟡 **EXPERIMENT 3: forget to put it back.** In `convert_lead`'s `Err` arm, replace
> `self.leads.insert(lead);` with nothing. Run `cargo check`. What warning do you get? Run
> the CRM, convert an unqualified lead, then `lead list`. Where did the lead go, and at
> which line was it dropped? Revert.

```text
warning: unused variable: `lead`
   --> src/crm.rs:248:32
    |
248 |             Err(ConvertError { lead, reason }) => {
    |                                ^^^^ help: try ignoring the field: `lead: _`
```

Notice the `help:`. Following it (`lead: _`) silences the warning *and* silently throws the
lead away. A warning about an unused **owned** value often means "you're about to drop
something you meant to keep".

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: test the conversion paths of `Crm::convert_lead`.**
> Write tests (in `src/crm.rs` under `#[cfg(test)]`, or wherever your `Crm` tests live) for:
> 1. **Success:** a qualified lead with a deal → the lead is gone from `crm.leads`; the company,
>    contact and deal exist; the contact and deal point at the new company.
> 2. **Not qualified:** `Err(LeadNotQualified(id))`; the lead is still there **and equal to
>    what it was before**; no company/contact/deal was created.
> 3. **Duplicate email:** an existing contact has the lead's email (different case!) →
>    `Err(DuplicateEmail(_))`; the lead is still there, still `Qualified`.
> 4. **Invalid deal** (blank title) → `Err(Validation(_))`; the lead is still there; no deal.

- [ ] A small helper builds the common setup (one company, one contact, one lead) and returns
      `(Crm, LeadId)`
- [ ] Failure tests check the repo **sizes** before vs after, not just the error
- [ ] `cargo test` passes

> 🔵 **YOUR TURN 2: disqualifying leads.**
> Implement:
> - `Lead::disqualify(&mut self)`: sets the status to `Disqualified` (from any status; doing it
>   twice is fine).
> - `Crm::disqualify_lead(&mut self, id: LeadId) -> Result<(), CrmError>` (`NotFound` for an
>   unknown id).
> - The command `lead disqualify <id>` printing `Lead #2 is disqualified`.

- [ ] A test proves a disqualified lead can be neither qualified (`LeadDisqualified`) nor
      converted (`LeadNotQualified`), and is still in the CRM afterwards
- [ ] A test for `NotFound { entity: "lead", .. }` on an unknown id
- [ ] `help` lists the new command

> 🔵 **YOUR TURN 3: `lead list` filters.**
> Support `lead list [--status <status>] [--source <source>]` in the style of Lab 17's
> filters:
> - `pub struct LeadFilter { pub status: Option<LeadStatus>, pub source: Option<LeadSource> }`
>   in a new `src/leads/filter.rs`, deriving `Default` (among others), with
>   `pub fn matches(&self, lead: &Lead) -> bool`. Re-export it from `leads`.
> - `impl FromStr for LeadStatus` (same error style as `LeadSource`).
> - `pub fn list_leads(&self, filter: &LeadFilter) -> Vec<&Lead>` on `Crm`.
> - `LeadCommand::List` becomes `LeadCommand::List(LeadFilter)`.
> - A flag without a value (`lead list --status`) is a usage error. An unknown value
>   (`--status hot`) is a validation error: `Error: invalid lead status: 'hot'`.

- [ ] `lead list --status qualified --source referral` combines both filters (AND)
- [ ] Tests for `list_leads` (no filter, each filter, both) and for the parser
- [ ] `cargo clippy` is clean

## 💡 Hint

> 💡 **HINT (Your Turn 1):** for "equal to what it was before", clone the lead *before*
> calling `convert_lead`: `let before = crm.lead(id).unwrap().clone();`. Why do you need the
> clone, rather than holding the `&Lead`?

<details><summary>Hint 2 (more specific)</summary>

Holding `let before = crm.lead(id).unwrap();` (a `&Lead` borrowing `crm`) and then calling
`crm.convert_lead(..)` (which needs `&mut crm`) is E0502. Clone to end the borrow. For "repo
sizes", a tuple keeps it to one assertion:
`assert_eq!((crm.companies.len(), crm.contacts.len(), crm.deals.len()), (1, 1, 0));`

</details>

> 💡 **HINT (Your Turn 2):** `disqualify_lead` is `qualify_lead`'s twin, except `disqualify()`
> can't fail, so you'll need an explicit `Ok(())`.

> 💡 **HINT (Your Turn 3):** `Option::is_none_or` (stable since Rust 1.82) reads well in
> `matches`: "no filter, or it matches". For the flags, a slice pattern like
> `["list", flags @ ..]` binds the rest of the args, and `flags.chunks(2)` hands you
> `[flag, value]` pairs.

<details><summary>Hint 2 (more specific)</summary>

Inside the loop over `chunks(2)`, match the chunk itself: `["--status", value] => ...`,
`["--source", value] => ...`, `_ => usage error`. A trailing `--status` with no value is a
chunk of length 1, which falls through to `_`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:

1. What does `fn convert(self, ..)` promise the caller that `fn convert(&self, ..)` doesn't?
2. In `Lead::convert`, why must every fallible check come *before* `let Lead { .. } = self;`?
   What is a partial move?
3. How does the caller get its lead back after a failed conversion? Name a standard-library
   type that uses the same pattern.
4. Why can't a `&mut self` builder simply move `self.name` into the `Lead`? What do
   `mem::take`, `mem::replace` and `Option::take` have in common?
5. The compiler suggested `#[derive(Default)]` for `Email`. Why would that have been a bug?
6. Why does a builder setter take `mut self` and return `Self`? What does that cost when a
   value is conditional?
7. Name three ways in which "remove the lead, put it back on failure" is *not* a real
   transaction.
8. What does a `compile_fail` doc test prove, and what doesn't it prove on stable Rust?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

```bash
git add .
git commit -m "Add leads and lead conversion"
git tag lab-19
git push && git push --tags
```

> 💡 Committing more than once is encouraged: e.g. one commit after Step 2 ("Add Lead and
> LeadBuilder"), one at the end. The final commit message above is what later labs refer to.

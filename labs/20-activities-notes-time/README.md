# Lab 20 — Activities, Notes & Time

> **Phase:** 5 — The Sales Pipeline · **Builds on:** Lab 19 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-19` · **After:** tag `lab-20`

## 🎯 Goal
Give every company, contact and deal a **history**: calls, emails and meetings you've logged,
plus free-text notes, merged into one newest-first timeline. Along the way you'll add your
**first external crate**, `chrono`, and learn to handle time without making your tests
depend on the clock.

## 🧠 What You'll Learn
- crates.io, `cargo add`, **semantic versioning** and the caret rule (with its special case for `0.x`)
- What `Cargo.lock` is for, why you commit it, and how to read `cargo tree`
- **Crate features**: default features, optional ones, and how to see what's switched on
- `chrono`'s model of time: `DateTime<Utc>` vs `DateTime<Local>` vs `NaiveDateTime` vs `NaiveDate`
- Enums that carry **different data per variant** (`ActivityKind`), and parsing a mini-syntax with `FromStr` (`deal:3`)
- **Lifetimes paying off**: `HistoryItem<'a>` borrows from two repositories at once, with zero copies
- When elision fails (E0106 with two reference inputs) and what `'b: 'a` means
- **Passing `now` in** instead of calling the clock: time as a dependency
- **Closed vs open polymorphism**: an `enum` vs `Vec<Box<dyn Trait>>`, tried both ways

## 🔨 What We're Building
A CRM that only stores *current state* can't answer the questions salespeople actually ask:
*When did we last speak to Acme? What did they say about pricing? Who was in that demo?*

```text
crm> activity log deal:1
Kind (call/email/meeting): call
Duration in minutes: 25
Summary: Discovery call, budget confirmed
When (YYYY-MM-DD HH:MM, UTC; blank for now): 2026-10-05 09:30
Logged activity #1 on deal:1
crm> note add deal:1 Wants a demo before signing
Added note #1 to deal:1
crm> history deal:1
2026-10-05 14:48  note: Wants a demo before signing
2026-10-05 09:30  call (25 min): Discovery call, budget confirmed
```

Activities and notes attach to a **subject**, any one of a company, a contact or a deal,
written `company:3`, `contact:5`, `deal:2`. This history is the raw material for the
capstone's activity timeline (Lab 41).

New files by the end:

```text
src/
├── subject.rs          ← Subject: what a record is about
├── history.rs          ← HistoryItem<'a>, Crm::history
├── activities/
│   ├── mod.rs
│   └── model.rs        ← ActivityId, ActivityKind, Activity
└── notes/
    ├── mod.rs
    └── model.rs        ← NoteId, Note
examples/
└── time_types.rs       ← a tour of chrono's types
```

---

## Step 1 — Your first dependency

So far, everything came from Rust's standard library. The standard library is deliberately
small: it has no date/time *calendar* support, no JSON, no HTTP. Those live in **crates**
published on [crates.io](https://crates.io), the package registry (npm, for Rust).

For dates and times the most widely used crate is `chrono`. (Alternatives you'll hear about:
`time`, and the newer `jiff`. All three are good. `chrono` has the largest ecosystem, and SQLx
supports it, which you'll need in Lab 30.)

> 🟢 **FOLLOW ALONG**

```bash
cargo add chrono
```

```text
    Updating crates.io index
      Adding chrono v0.4.45 to dependencies
             Features:
             + alloc
             + clock
             + iana-time-zone
             + js-sys
             + now
             + oldtime
             + std
             + wasm-bindgen
             + wasmbind
             + winapi
             + windows-link
             - __internal_bench
             - arbitrary
             - core-error
             - defmt
             - libc
             - pure-rust-locales
             - rkyv
             ...
             - serde
             - unstable-locales
```

(This lab was written against **chrono 0.4.45**. A newer 0.4.x is fine. If you're reading this
when chrono 0.5 exists, either use `cargo add chrono@0.4` or check
[docs.rs/chrono](https://docs.rs/chrono) for renamed APIs.)

Open `Cargo.toml`:

```toml
[dependencies]
chrono = "0.4.45"
```

### Semantic versioning and the caret

`"0.4.45"` doesn't mean "exactly 0.4.45". Cargo reads it as **`^0.4.45`**: "any version that
is *semver-compatible* with 0.4.45". Semver says `MAJOR.MINOR.PATCH`:

- **PATCH** bump (0.4.45 → 0.4.46): bug fixes only.
- **MINOR** bump (1.2 → 1.3): new features, nothing removed.
- **MAJOR** bump (1.x → 2.0): breaking changes allowed.

For versions **below 1.0**, Cargo shifts the rule one place to the right: the first non-zero
number acts as the major. So `^0.4.45` allows `0.4.46`, `0.4.99`, but **not `0.5.0`**, which
counts as a breaking change. (`chrono` has been on 0.4 for years. "0.x" in Rust does *not*
mean "experimental". Many core crates are mature at 0.x.)

> TypeScript comparison: npm's `^` works exactly the same way, including the 0.x rule. The
> difference is cultural. Rust crates take semver very seriously, and tools like
> `cargo-semver-checks` exist to catch accidental breaking changes.

### `Cargo.lock`: the versions you actually got

`Cargo.toml` states what you *accept*. `Cargo.lock` records what you *got*: the exact version
and a checksum of every crate in the build, including dependencies of dependencies.

```bash
grep -A3 'name = "chrono"' Cargo.lock
```

```text
name = "chrono"
version = "0.4.45"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1aa79e62e7697b8e29b513a68abacf485adcd1fe8284a4316c5ae868e6633327"
```

**Commit `Cargo.lock`.** For an application (and your CRM is one), the lock file makes every
build reproducible: your laptop, CI (Lab 24) and the Docker image (Lab 40) all compile exactly
the same code. `cargo update` is the deliberate act of moving to newer compatible versions.

### `cargo tree`: what came along

```bash
cargo build
cargo tree
```

```text
rust-crm v0.1.0 (/path/to/rust-crm)
└── chrono v0.4.45
    ├── iana-time-zone v0.1.65
    │   └── core-foundation-sys v0.8.7
    └── num-traits v0.2.19
        [build-dependencies]
        └── autocfg v1.5.1
```

(That's the macOS tree. On Linux you won't see `core-foundation-sys`. On Windows you'll see
`windows-*` crates.) One `cargo add` brought in four more crates: **transitive dependencies**.
Here's a surprise: `cargo add` printed "Locking 37 packages", but only 5 compiled. `Cargo.lock`
lists dependencies for **every** platform (Windows, WebAssembly, Android, …), so the lock
file works on all of them, but Cargo only *builds* what your target needs.

Every dependency is code you're trusting. Four small, widely used crates is fine. Make a habit
of glancing at `cargo tree` after each `cargo add`. (`cargo audit` and `cargo deny` automate
the trust questions. They're worth knowing about, though not needed in this course.)

### Features: optional parts of a crate

The `+`/`-` list that `cargo add` printed is the crate's **features**: compile-time switches
that turn optional code (and optional dependencies) on or off. `+` means enabled. Those are
chrono's **default features**. To see *why* each one is on:

```bash
cargo tree -e features
```

```text
rust-crm v0.1.0 (/path/to/rust-crm)
└── chrono feature "default"
    ├── chrono v0.4.45
    ...
    ├── chrono feature "clock"
    │   ├── chrono v0.4.45 (*)
    │   ├── chrono feature "iana-time-zone"
    │   ├── chrono feature "now"
    │   │   └── chrono feature "std"
    ...
```

`default` turns on `clock`, `clock` turns on `now` and `iana-time-zone`, and so on. Notice
**`- serde`**: chrono can serialize its types to JSON, but that code isn't compiled until you
ask for it. In Lab 21 you'll run `cargo add chrono --features serde`, and the `-` becomes
`+`. Features are how crates stay small by default yet capable on demand.

> 🟡 **EXPERIMENT**: run `cargo doc --open`. Your crate's docs now link to chrono's. Click
> through to `DateTime`. Every crate's documentation is also published at
> `https://docs.rs/<crate>`, built from the same doc comments you've been writing since Lab 13.

Commit the dependency on its own. It's a meaningful step, and it makes `git log` tell the
story:

```bash
git add Cargo.toml Cargo.lock
git commit -m "Add chrono"
```

## Step 2 — A mental model for time

JavaScript has one `Date` type. It holds a UTC instant, but half its methods silently use the
machine's time zone. chrono splits time into separate **types**, so the compiler can tell
them apart:

| Type | What it is | Example | Use in the CRM |
|---|---|---|---|
| `DateTime<Utc>` | An **instant**, in UTC | `2026-10-05 09:30:00 UTC` | Everything we store |
| `DateTime<Local>` | The same kind of instant, in the machine's zone | `2026-10-05 11:30:00 +02:00` | Display only (if at all) |
| `NaiveDateTime` | A wall-clock date + time with **no zone** | `2026-10-07 14:00:00` | Parsing user input, *before* we decide its zone |
| `NaiveDate` | A calendar date | `2026-12-31` | "Expected close date" (Challenge B) |

"Naive" means "doesn't know its time zone", so it's *not yet an instant*. 14:00 in Cape Town
and 14:00 in Chicago are different moments.

**The rule used by most backends: store and compute in UTC, convert at the edges** (when
reading user input and when displaying). Our CLI keeps it simple: users type UTC times, and we
label every prompt "UTC".

> 🟢 **FOLLOW ALONG**: create `examples/time_types.rs`.

```rust
//! A tour of chrono's main types. Run with: cargo run --example time_types

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};

fn main() {
    // An instant in time, in UTC. This is what the CRM stores.
    let now: DateTime<Utc> = Utc::now();
    println!("Utc::now()        = {now}");

    // The same instant, shown in this machine's time zone.
    let local: DateTime<Local> = now.with_timezone(&Local);
    println!("in local time     = {local}");
    println!("same instant?       {}", local == now);

    // A wall-clock date and time with NO time zone: not an instant yet.
    let naive = NaiveDateTime::parse_from_str("2026-10-07 14:00", "%Y-%m-%d %H:%M").unwrap();
    println!("naive             = {naive}");
    println!("naive, as UTC     = {}", naive.and_utc());

    // A calendar date: no time, no zone. Good for "expected close date".
    let close: NaiveDate = NaiveDate::from_ymd_opt(2026, 12, 31).unwrap();
    println!("a date            = {close}");

    // Building a fixed instant, the way tests do.
    let fixed = Utc.with_ymd_and_hms(2026, 10, 5, 9, 30, 0).unwrap();
    println!("fixed             = {fixed}");
    println!("formatted         = {}", fixed.format("%a %d %b %Y, %H:%M"));
    println!("RFC 3339          = {}", fixed.to_rfc3339());
    println!("fixed < now?        {}", fixed < now);
}
```

```bash
cargo run --example time_types
```

```text
Utc::now()        = 2026-10-05 14:48:57.469811 UTC
in local time     = 2026-10-05 16:48:57.469811 +02:00
same instant?       true
naive             = 2026-10-07 14:00:00
naive, as UTC     = 2026-10-07 14:00:00 UTC
a date            = 2026-12-31
fixed             = 2026-10-05 09:30:00 UTC
formatted         = Mon 05 Oct 2026, 09:30
RFC 3339          = 2026-10-05T09:30:00+00:00
fixed < now?        true
```

(Your first two lines show *your* current time and zone.) Things to notice:

- `local == now` is **true**: different display, same instant. `DateTime<Tz>` compares
  instants, whatever the zone.
- `parse_from_str` gives a `NaiveDateTime`, and `.and_utc()` *declares* it to be UTC,
  making it an instant.
- `from_ymd_opt` and `with_ymd_and_hms` don't return the value directly. February 30 doesn't
  exist (`Option`), and in time zones with daylight saving, some local times happen twice or
  never (chrono's `LocalResult`). In UTC neither problem exists, so `.unwrap()` is safe here
  with literal, valid dates.
- `format` uses `strftime`-style specifiers (`%Y`, `%m`, `%d`, `%H`, `%M`, `%a`, `%b`).
  RFC 3339 is the format JSON APIs use (Lab 29).

> 🟡 **EXPERIMENT**: add `println!("naive < now? {}", naive < now);` and `cargo run --example time_types`.

```text
error[E0308]: mismatched types
  --> examples/time_types.rs:30:48
   |
30 |     println!("naive < now?        {}", naive < now);
   |                                        -----   ^^^ expected `NaiveDateTime`, found `DateTime<Utc>`
   |                                        |
   |                                        expected because this is `NaiveDateTime`
```

In JavaScript, comparing a "local" date with a UTC date compiles and silently gives a wrong
answer depending on where the server runs. Here it's a type error. You must say which zone the
naive value is in (`naive.and_utc() < now`). Remove the line. (You can keep the example file:
`examples/` is your scratch space.)

## Step 3 — `Subject`: what a record is about

An activity or note belongs to **exactly one** of: a company, a contact, a deal. In
TypeScript you might write `{ type: "deal", id: 3 }` or a discriminated union. In Rust that's
an enum whose variants wrap the *typed* ids from Labs 14 and 18:

> 🟢 **FOLLOW ALONG**: create `src/subject.rs` and add `pub mod subject;` to `lib.rs`.

```rust
//! What an activity or note is *about*.

use std::fmt;
use std::str::FromStr;

use crate::companies::CompanyId;
use crate::contacts::ContactId;
use crate::deals::DealId;
use crate::errors::ValidationError;

/// A reference to one record in the CRM, written `company:3`, `contact:5` or `deal:2`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Subject {
    Company(CompanyId),
    Contact(ContactId),
    Deal(DealId),
}

impl fmt::Display for Subject {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Subject::Company(id) => write!(f, "company:{}", id.0),
            Subject::Contact(id) => write!(f, "contact:{}", id.0),
            Subject::Deal(id) => write!(f, "deal:{}", id.0),
        }
    }
}

impl FromStr for Subject {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || ValidationError::InvalidValue {
            field: "subject (expected e.g. company:3, contact:5 or deal:2)",
            value: s.to_string(),
        };
        let (kind, id) = s.trim().split_once(':').ok_or_else(invalid)?;
        let id: u64 = id.parse().map_err(|_| invalid())?;
        match kind.to_lowercase().as_str() {
            "company" => Ok(Subject::Company(CompanyId(id))),
            "contact" => Ok(Subject::Contact(ContactId(id))),
            "deal" => Ok(Subject::Deal(DealId(id))),
            _ => Err(invalid()),
        }
    }
}
```

Why an enum and not `(String, u64)`?

- **`Subject::Deal(DealId(3))` can't be confused with `Subject::Company(CompanyId(3))`**, and the
  id inside has the right type. When you later look the record up, `match subject` gives you a
  `DealId` you can pass straight to `crm.deals.get(..)`.
- It's **`Copy`**: two words of data, no heap. Pass it around freely.
- It's **`Eq + Hash`**: usable as a map key (e.g. "activities per subject").
- `FromStr` + `Display` make a **round-trippable text form**. The parser is the same
  `split_once` technique as `Money::parse`, using the `InvalidValue` variant from Lab 18.

Tests at the bottom of `subject.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_each_kind() {
        assert_eq!("company:3".parse(), Ok(Subject::Company(CompanyId(3))));
        assert_eq!("Contact:5".parse(), Ok(Subject::Contact(ContactId(5))));
        assert_eq!(" deal:2 ".parse(), Ok(Subject::Deal(DealId(2))));
    }

    #[test]
    fn rejects_malformed_subjects() {
        for bad in ["company", "company:", "company:x", "lead:1", ":3", "company:-1"] {
            assert!(bad.parse::<Subject>().is_err(), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn display_round_trips() {
        let subject = Subject::Deal(DealId(7));
        assert_eq!(subject.to_string(), "deal:7");
        assert_eq!(subject.to_string().parse(), Ok(subject));
    }
}
```

`"company:3".parse()` with no turbofish works because `assert_eq!` compares it with an
`Ok(Subject::..)`, so inference figures out the target type. `"company:-1"` fails because
`u64::from_str` rejects a minus sign. Unsigned ids pay off.

> 🔵 **Mini-task:** why can't a lead be a subject (`lead:1`)? Think about Lab 19: what happens
> to a lead, and its id, when it's converted? Write your answer in a comment above `Subject`.
> (Discussion in [solutions.md](solutions.md#mini-task-why-no-lead-subject).)

## Step 4 — `ActivityKind`: an enum with different data per variant

A call has a duration. An email has a subject line. A meeting has a start time and a list of
attendees. One type, three shapes:

> 🟢 **FOLLOW ALONG**: create `src/activities/model.rs`.

```rust
use std::fmt;

use chrono::{DateTime, Utc};

use crate::contacts::ContactId;
use crate::entity::Entity;
use crate::subject::Subject;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ActivityId(pub u64);

impl From<u64> for ActivityId {
    fn from(id: u64) -> Self {
        ActivityId(id)
    }
}

impl fmt::Display for ActivityId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// What kind of interaction happened. Each kind carries its own data.
#[derive(Debug, Clone, PartialEq)]
pub enum ActivityKind {
    Call { minutes: u32 },
    Email { subject: String },
    Meeting { starts_at: DateTime<Utc>, attendees: Vec<ContactId> },
}

impl fmt::Display for ActivityKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ActivityKind::Call { minutes } => write!(f, "call ({minutes} min)"),
            ActivityKind::Email { subject } => write!(f, "email \"{subject}\""),
            ActivityKind::Meeting { starts_at, attendees } => write!(
                f,
                "meeting at {} ({} attendees)",
                starts_at.format("%Y-%m-%d %H:%M UTC"),
                attendees.len()
            ),
        }
    }
}

/// Something that happened with a company, contact or deal.
#[derive(Debug, Clone, PartialEq)]
pub struct Activity {
    pub id: ActivityId,
    pub subject: Subject,
    pub kind: ActivityKind,
    pub summary: String,
    pub occurred_at: DateTime<Utc>,
}

impl Entity for Activity {
    type Id = ActivityId;

    fn id(&self) -> ActivityId {
        self.id
    }

    fn label(&self) -> String {
        format!("Activity {} on {}", self.id, self.subject)
    }
}
```

And `src/activities/mod.rs`:

```rust
mod model;

pub use model::{Activity, ActivityId, ActivityKind};
```

Add `pub mod activities;` to `lib.rs`.

**Struct-like variants.** `Call { minutes: u32 }` is a variant with *named* fields, the enum
equivalent of a struct. Compare with `Subject::Deal(DealId)`, a *tuple-like* variant. Use
names when a variant has several fields, or when a bare value would be ambiguous (`Call(u32)`:
u32 *what*? minutes? seconds?).

**Matching destructures.** In `ActivityKind::Meeting { starts_at, attendees } => ...`, the
pattern binds both fields. Because we matched on `self` (a `&ActivityKind`), they're bound as
**references** (`&DateTime<Utc>`, `&Vec<ContactId>`) through default binding modes (Lab 18,
Step 9). Nothing is moved out of the activity.

**Memory layout.** An enum is as large as its largest variant plus a tag: here `Meeting`
(a 12-byte `DateTime` plus a 24-byte `Vec`) sets the size, and a `Call` wastes the difference.
That's fine. The alternative (a `Box` per activity) costs a heap allocation each, which is
worse. You'll compare against that design in the 🧪 Experiment.

(Yes, `ActivityKind::Email { subject }` uses the word "subject" for the email's subject line,
while `Activity::subject` is the record it's about. Different things in different types, so
the compiler never confuses them. If it confuses *you*, rename the field to `subject_line`.)

## Step 5 — Notes

Notes are simpler: free text with a timestamp.

> 🟢 **FOLLOW ALONG**: create `src/notes/model.rs` and `src/notes/mod.rs` (same shape as
> `activities`), and add `pub mod notes;` to `lib.rs`.

```rust
use std::fmt;

use chrono::{DateTime, Utc};

use crate::entity::Entity;
use crate::subject::Subject;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NoteId(pub u64);

impl From<u64> for NoteId {
    fn from(id: u64) -> Self {
        NoteId(id)
    }
}

impl fmt::Display for NoteId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// Free text attached to a company, contact or deal.
#[derive(Debug, Clone, PartialEq)]
pub struct Note {
    pub id: NoteId,
    pub subject: Subject,
    pub body: String,
    pub created_at: DateTime<Utc>,
}

impl Entity for Note {
    type Id = NoteId;

    fn id(&self) -> NoteId {
        self.id
    }

    fn label(&self) -> String {
        format!("Note {} on {}", self.id, self.subject)
    }
}
```

```rust
// src/notes/mod.rs
mod model;

pub use model::{Note, NoteId};
```

Add one more `ValidationError` variant (`EmptyNote`, displayed as `note must not be empty`) in
`errors.rs`.

## Step 6 — Recording activities and notes: pass `now` in

> 🟢 **FOLLOW ALONG**: in `src/crm.rs`, add the repos and three methods.

```rust
use chrono::{DateTime, Utc};

use crate::activities::{Activity, ActivityId, ActivityKind};
use crate::notes::{Note, NoteId};
use crate::subject::Subject;
// and make sure ValidationError is imported from crate::errors

pub struct Crm {
    // ...companies, contacts, deals, leads...
    pub activities: InMemoryRepo<Activity>,
    pub notes: InMemoryRepo<Note>,
}
```

```rust
    /// Fails with `NotFound` unless the record `subject` points to exists.
    pub fn check_subject(&self, subject: Subject) -> Result<(), CrmError> {
        let (entity, id, exists) = match subject {
            Subject::Company(id) => ("company", id.0, self.companies.get(id).is_some()),
            Subject::Contact(id) => ("contact", id.0, self.contacts.get(id).is_some()),
            Subject::Deal(id) => ("deal", id.0, self.deals.get(id).is_some()),
        };
        if exists {
            Ok(())
        } else {
            Err(CrmError::NotFound { entity, id })
        }
    }

    pub fn log_activity(
        &mut self,
        subject: Subject,
        kind: ActivityKind,
        summary: String,
        occurred_at: DateTime<Utc>,
    ) -> Result<ActivityId, CrmError> {
        self.check_subject(subject)?;
        // Your Turn 1 adds a rule here.
        let activity = Activity {
            id: self.activities.next_id(),
            subject,
            kind,
            summary,
            occurred_at,
        };
        Ok(self.activities.insert(activity))
    }

    pub fn add_note(
        &mut self,
        subject: Subject,
        body: String,
        now: DateTime<Utc>,
    ) -> Result<NoteId, CrmError> {
        self.check_subject(subject)?;
        if body.trim().is_empty() {
            return Err(ValidationError::EmptyNote.into());
        }
        let note = Note {
            id: self.notes.next_id(),
            subject,
            body,
            created_at: now,
        };
        Ok(self.notes.insert(note))
    }
```

**`check_subject`** is one `match` that turns each variant into the three facts we need.
Every arm has a *different* id type (`CompanyId`, `ContactId`, `DealId`), but each arm's
result is the same tuple type `(&'static str, u64, bool)`, so the `match` type-checks. This
is the "typed ids, one lookup per kind" payoff of Lab 14's design.

**Why does `add_note` take `now` as a parameter?** It would be easier to call `Utc::now()`
inside. But then:

- A test can't say *"the note was created at 09:00"*. The value is whatever the clock said.
- A test of "newest first" depends on two calls being at least a microsecond apart. It will
  probably pass on your laptop. Will it pass on a fast CI machine? On a VM whose clock gets
  adjusted? You can't know.
- `Utc::now()` is a **hidden input**. The function's result depends on something the
  signature doesn't mention.

Passing `now` in turns the clock into an **explicit dependency**. The CLI passes `Utc::now()`
(the real world), and tests pass fixed instants (a controlled world). It's the cheapest form of
dependency injection there is, and you'll see the same idea scale up into the `Storage` trait
in Lab 23. `log_activity` takes `occurred_at` for a second reason: activities are often logged
*after the fact* ("I called them this morning").

## Step 7 — History: borrowing from two repositories at once

Now the payoff for Labs 07–10. A subject's history is its activities *and* notes, merged and
sorted newest first. The obvious design copies everything into a new list of owned records.
But the history is only *displayed*. Copying every summary and body just to print it and throw
it away is wasteful.

Instead, each history entry **borrows** the record it shows:

> 🟢 **FOLLOW ALONG**: create `src/history.rs` and add `pub mod history;` to `lib.rs`.

```rust
//! A merged, newest-first view over activities and notes.

use std::cmp::Reverse;
use std::fmt;

use chrono::{DateTime, Utc};

use crate::activities::Activity;
use crate::crm::Crm;
use crate::notes::Note;
use crate::repo::InMemoryRepo;
use crate::subject::Subject;

/// One entry in a subject's history. It *borrows* the record it shows.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HistoryItem<'a> {
    Activity(&'a Activity),
    Note(&'a Note),
}

impl HistoryItem<'_> {
    /// When this item happened.
    pub fn at(&self) -> DateTime<Utc> {
        match self {
            HistoryItem::Activity(activity) => activity.occurred_at,
            HistoryItem::Note(note) => note.created_at,
        }
    }
}

impl fmt::Display for HistoryItem<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let at = self.at().format("%Y-%m-%d %H:%M");
        match self {
            HistoryItem::Activity(activity) => {
                write!(f, "{at}  {}: {}", activity.kind, activity.summary)
            }
            HistoryItem::Note(note) => write!(f, "{at}  note: {}", note.body),
        }
    }
}
```

`HistoryItem<'a>` is an enum of two **references**. It's 16 bytes (a tag plus a pointer),
whatever the size of the records. It's `Copy`, because shared references are `Copy`.
`'a` says "this item is only valid while the record it points to is". `at()` returns a
`DateTime<Utc>` *by value*. That's fine because `DateTime<Utc>` is `Copy`: we copy 12 bytes,
not the record.

`impl HistoryItem<'_>`: the impl doesn't care *which* lifetime, so `'_` lets you avoid naming
it (Lab 10).

Now the merge. Write it as a **free function** first, taking the two repos separately:

> 🟡 **EXPERIMENT**: add this function (no lifetime annotations) and `cargo check`. Predict
> the error code before you look.

```rust
/// Everything recorded about `subject`, newest first.
fn merge_history(
    activities: &InMemoryRepo<Activity>,
    notes: &InMemoryRepo<Note>,
    subject: Subject,
) -> Vec<HistoryItem> {
    let activities = activities
        .iter()
        .filter(|activity| activity.subject == subject)
        .map(HistoryItem::Activity);
    let notes = notes
        .iter()
        .filter(|note| note.subject == subject)
        .map(HistoryItem::Note);
    let mut items: Vec<HistoryItem> = activities.chain(notes).collect();
    items.sort_by_key(|item| Reverse(item.at()));
    items
}
```

```text
error[E0106]: missing lifetime specifier
  --> src/history.rs:34:10
   |
31 |     activities: &InMemoryRepo<Activity>,
   |                 -----------------------
32 |     notes: &InMemoryRepo<Note>,
   |            -------------------
33 |     subject: Subject,
34 | ) -> Vec<HistoryItem> {
   |          ^^^^^^^^^^^ expected named lifetime parameter
   |
   = help: this function's return type contains a borrowed value, but the signature does not say whether it is borrowed from `activities` or `notes`
help: consider introducing a named lifetime parameter
   |
30 ~ pub fn merge_history<'a>(
31 ~     activities: &'a InMemoryRepo<Activity>,
32 ~     notes: &'a InMemoryRepo<Note>,
33 |     subject: Subject,
34 ~ ) -> Vec<HistoryItem<'a>> {
   |
```

**Read the error with Lab 10's elision rules.** The output contains a borrow (`HistoryItem`
holds references). Rule 2 ("one reference input → output borrows from it") doesn't apply:
there are **two** reference inputs. Rule 3 ("`&self` → output borrows from self") doesn't
apply: it's not a method. So the compiler refuses to guess. The help text says it exactly:
*the signature does not say whether it is borrowed from `activities` or `notes`*.

The true answer is **both**: activity items point into `activities`, and note items point
into `notes`, all in one `Vec`. So both inputs must live at least as long as the result:

```rust
fn merge_history<'a>(
    activities: &'a InMemoryRepo<Activity>,
    notes: &'a InMemoryRepo<Note>,
    subject: Subject,
) -> Vec<HistoryItem<'a>> {
    // ...same body, with `Vec<HistoryItem<'a>>` on the `items` line...
}
```

Read `'a` as a *contract*: "give me two repos that both stay alive (and unmodified) for some
region `'a`, and I'll give you items valid for that same region".

> 🟡 **EXPERIMENT: two lifetimes.** What if you're more "precise" and give each input its own
> lifetime, `<'a, 'b>`, with `notes: &'b ...` and the result as `Vec<HistoryItem<'a>>`?

```text
error: lifetime may not live long enough
  --> src/history.rs:43:20
   |
30 | pub fn merge_history<'a, 'b>(
   |                      --  -- lifetime `'b` defined here
   |                      |
   |                      lifetime `'a` defined here
...
43 |     let mut items: Vec<HistoryItem<'a>> = activities.chain(notes).collect();
   |                    ^^^^^^^^^^^^^^^^^^^^ type annotation requires that `'b` must outlive `'a`
   |
   = help: consider adding the following bound: `'b: 'a`
```

The function puts `&'b Note`s into a `Vec<HistoryItem<'a>>`. That's only sound if the notes
live **at least as long as** `'a`. `'b: 'a` (read: "`'b` outlives `'a`") is the bound that
says so, and adding it would compile. But it says nothing the single-`'a` version doesn't:
when you call the function, the compiler picks `'a` as the *overlap* of both borrows. One
lifetime is the simpler, idiomatic answer. Go back to it.

Now the line-by-line of the body:

- **`.map(HistoryItem::Activity)`**: an enum's tuple variant is also a **function**
  (`fn(&'a Activity) -> HistoryItem<'a>`), just like `LeadId` in Lab 19. No closure needed.
- **`activities.chain(notes)`**: one iterator after the other (Lab 17). Both yield
  `HistoryItem<'a>`, so they can be chained. Nothing has run yet: iterators are lazy.
  `collect()` drives both filters and maps in one pass.
- **`sort_by_key(|item| Reverse(item.at()))`**: `std::cmp::Reverse` is a wrapper whose
  `Ord` is backwards, so sorting by `Reverse(time)` is newest first. The sort is
  **stable**: items with *equal* times keep their relative order (activities before notes).

And the public API, as a method:

```rust
impl Crm {
    /// Activities and notes about `subject`, newest first.
    pub fn history(&self, subject: Subject) -> Vec<HistoryItem<'_>> {
        merge_history(&self.activities, &self.notes, subject)
    }
}
```

**No explicit lifetime here.** It's a method with `&self`, so elision rule 3 applies: the
output borrows from `self`. `'_` just makes the borrow visible to readers. Inside, `&self.activities`
and `&self.notes` are both borrows *of parts of* `self`, so they share `self`'s lifetime, and
`merge_history`'s single `'a` fits exactly. This is Lab 10 paying off. Once you know the
rules, you know why one signature needs annotations and the other doesn't.

### What the borrow means for callers

> 🟡 **EXPERIMENT**: in a test, hold the history and add a note before using it:
> ```rust
> let history = crm.history(acme);
> crm.add_note(acme, "New note".to_string(), at(12, 0)).unwrap();
> println!("{} items", history.len());
> ```

```text
error[E0502]: cannot borrow `crm` as mutable because it is also borrowed as immutable
   --> src/history.rs:132:9
    |
131 |         let history = crm.history(acme);
    |                       --- immutable borrow occurs here
132 |         crm.add_note(acme, "New note".to_string(), at(12, 0)).unwrap();
    |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
133 |         println!("{} items", history.len());
    |                              ------- immutable borrow later used here
```

`history` holds references into `crm.notes`. `add_note` pushes onto the `Vec` inside
`crm.notes`, which might **reallocate** and move every note in memory (Lab 07's picture).
Every `&Note` in `history` would then dangle. The borrow checker refuses. The fix depends on
intent: use the history *before* mutating, or call `history()` again afterwards to get a fresh
view. A borrowed view is a **snapshot you must finish with** before changing the data. That's
the price of zero copies, and it's almost always worth paying for read-only displays.

### Tests with a fixed clock

> 🟢 **FOLLOW ALONG**: add to `history.rs`:

```rust
#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;
    use crate::activities::ActivityKind;
    use crate::companies::CompanyId;
    use crate::errors::{CrmError, ValidationError};

    /// A fixed point in time on 5 October 2026: tests never call `Utc::now()`.
    fn at(hour: u32, minute: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 5, hour, minute, 0).unwrap()
    }

    fn crm_with_company() -> (Crm, Subject) {
        let mut crm = Crm::new();
        let id = crm.add_company("Acme".to_string(), None).unwrap();
        (crm, Subject::Company(id))
    }

    #[test]
    fn history_is_newest_first_across_activities_and_notes() {
        let (mut crm, acme) = crm_with_company();
        let call = ActivityKind::Call { minutes: 15 };
        crm.log_activity(acme, call, "Intro call".to_string(), at(9, 0)).unwrap();
        crm.add_note(acme, "Wants a demo".to_string(), at(11, 30)).unwrap();
        let email = ActivityKind::Email { subject: "Demo slots".to_string() };
        crm.log_activity(acme, email, "Sent slots".to_string(), at(10, 15)).unwrap();

        let times: Vec<DateTime<Utc>> = crm.history(acme).iter().map(|item| item.at()).collect();

        assert_eq!(times, [at(11, 30), at(10, 15), at(9, 0)]);
        assert!(matches!(crm.history(acme)[0], HistoryItem::Note(_)));
    }

    #[test]
    fn history_only_contains_the_requested_subject() {
        let (mut crm, acme) = crm_with_company();
        let globex = Subject::Company(crm.add_company("Globex".to_string(), None).unwrap());
        crm.add_note(acme, "About Acme".to_string(), at(9, 0)).unwrap();
        crm.add_note(globex, "About Globex".to_string(), at(9, 5)).unwrap();

        let history = crm.history(acme);

        assert_eq!(history.len(), 1);
        assert_eq!(history[0].to_string(), "2026-10-05 09:00  note: About Acme");
    }

    #[test]
    fn notes_and_activities_need_an_existing_subject() {
        let mut crm = Crm::new();
        let ghost = Subject::Company(CompanyId(42));
        let result = crm.add_note(ghost, "Hello?".to_string(), at(9, 0));
        assert!(matches!(result, Err(CrmError::NotFound { entity: "company", id: 42 })));
        let call = ActivityKind::Call { minutes: 5 };
        let result = crm.log_activity(ghost, call, String::new(), at(9, 0));
        assert!(matches!(result, Err(CrmError::NotFound { .. })));
    }

    #[test]
    fn blank_notes_are_rejected() {
        let (mut crm, acme) = crm_with_company();
        let result = crm.add_note(acme, "   ".to_string(), at(9, 0));
        assert!(matches!(result, Err(CrmError::Validation(ValidationError::EmptyNote))));
    }
}
```

Look at what the fixed clock buys you: activities are inserted **out of time order** (09:00,
then 11:30, then 10:15), and the test asserts the exact sorted result. It even asserts the
exact *display string*, including the time. None of that is possible with `Utc::now()` buried
inside `add_note`.

`use chrono::TimeZone;` is needed for `Utc.with_ymd_and_hms`: that method belongs to the
`TimeZone` **trait**, and trait methods are only callable when the trait is in scope (Lab 15).

```bash
cargo test history
```

## Step 8 — Commands: `activity log`, `note add`, `history`

> 🟢 **FOLLOW ALONG**: in `src/cli/parser.rs`, add three variants to `Command`:

```rust
use crate::subject::Subject;

    // in enum Command<'a>:
    LogActivity { subject: Subject },
    AddNote { subject: Subject, body: String },
    History { subject: Subject },
```

and three dispatch arms in `parse_command` (where `args` is your `Vec<&str>` of the words
after the command name):

```rust
        "activity" => match args.as_slice() {
            ["log", subject] => Command::LogActivity {
                subject: subject.parse()?,
            },
            _ => return Err(CrmError::Usage("activity log <subject>")),
        },
        "note" => match args.as_slice() {
            ["add", subject, words @ ..] if !words.is_empty() => Command::AddNote {
                subject: subject.parse()?,
                body: words.join(" "),
            },
            _ => return Err(CrmError::Usage("note add <subject> <text...>")),
        },
        "history" => match args.as_slice() {
            [subject] => Command::History {
                subject: subject.parse()?,
            },
            _ => return Err(CrmError::Usage("history <subject>")),
        },
```

- `["add", subject, words @ ..] if !words.is_empty()`: a slice pattern with a **rest
  binding** and a **guard**. `words` is a `&[&str]` of everything after the subject.
- `words.join(" ")` allocates a new `String`. The body isn't one contiguous slice of the input
  anymore (we split on whitespace, so `"a   demo"` becomes `"a demo"`). That's why `AddNote`
  holds an owned `String` rather than a `&'a str`.

Parser test:

```rust
    #[test]
    fn parses_note_add_with_multi_word_body() {
        assert_eq!(
            parse_command("note add deal:2 Wants a   demo next week").unwrap(),
            Some(Command::AddNote {
                subject: Subject::Deal(DealId(2)),
                body: "Wants a demo next week".to_string(),
            })
        );
        assert!(matches!(parse_command("note add deal:2"), Err(CrmError::Usage(_))));
        assert!(matches!(parse_command("history lead:1"), Err(CrmError::Validation(_))));
    }
```

> 🟢 **FOLLOW ALONG**: in `src/cli/commands.rs`, route the commands in `execute`:

```rust
use chrono::{DateTime, NaiveDateTime, Utc};

use crate::activities::ActivityKind;
use crate::errors::ValidationError;
use crate::subject::Subject;

        Command::LogActivity { subject } => log_activity(crm, subject)?,
        Command::AddNote { subject, body } => {
            let id = crm.add_note(subject, body, Utc::now())?;
            println!("Added note {id} to {subject}");
        }
        Command::History { subject } => {
            crm.check_subject(subject)?;
            let history = crm.history(subject);
            if history.is_empty() {
                println!("No history for {subject} yet.");
            }
            for item in &history {
                println!("{item}");
            }
        }
```

`Utc::now()` appears **here**, in the CLI, at the edge of the program, and nowhere in the
domain. And the helpers:

```rust
fn log_activity(crm: &mut Crm, subject: Subject) -> Result<(), CrmError> {
    crm.check_subject(subject)?; // fail fast, before asking questions
    let kind_input = prompt("Kind (call/email/meeting): ");
    let kind = match kind_input.to_lowercase().as_str() {
        "call" => {
            let raw = prompt("Duration in minutes: ");
            let minutes = raw.parse().map_err(|_| ValidationError::InvalidValue {
                field: "duration in minutes",
                value: raw,
            })?;
            ActivityKind::Call { minutes }
        }
        "email" => ActivityKind::Email {
            subject: prompt("Email subject: "),
        },
        // Your Turn 3 adds "meeting".
        _ => {
            return Err(ValidationError::InvalidValue {
                field: "activity kind",
                value: kind_input,
            }
            .into());
        }
    };
    let summary = prompt("Summary: ");
    let occurred_at = match prompt_optional("When (YYYY-MM-DD HH:MM, UTC; blank for now): ") {
        Some(raw) => parse_datetime(&raw)?,
        None => Utc::now(),
    };
    let id = crm.log_activity(subject, kind, summary, occurred_at)?;
    println!("Logged activity {id} on {subject}");
    Ok(())
}

/// Parses `2026-10-05 14:30` as a UTC timestamp.
fn parse_datetime(input: &str) -> Result<DateTime<Utc>, CrmError> {
    NaiveDateTime::parse_from_str(input.trim(), "%Y-%m-%d %H:%M")
        .map(|naive| naive.and_utc())
        .map_err(|_| {
            ValidationError::InvalidValue {
                field: "date/time (expected YYYY-MM-DD HH:MM)",
                value: input.to_string(),
            }
            .into()
        })
}
```

Ownership details worth a second look:

- `match kind_input.to_lowercase().as_str()` matches on a **temporary** lowercase `String`.
  That temporary doesn't borrow `kind_input`, so the `_` arm can **move** `kind_input` into
  the error.
- In the `"call"` arm, `raw.parse()` borrows `raw` only during the call. The `map_err`
  closure then **moves** `raw` into the error (it's an `FnOnce`, Lab 17). No clone needed.
- `"email" => ActivityKind::Email { subject: prompt(..) }`: the `String` returned by `prompt`
  moves straight into the enum.
- The prompt already offers `meeting`. That's a promise you keep in Your Turn 3. Until then,
  `meeting` falls into `_` and is rejected.

Add the three commands to `print_help`:

```rust
    println!("  activity log <subject>          subject = company:<id> | contact:<id> | deal:<id>");
    println!("  note add <subject> <text...>");
    println!("  history <subject>               activities and notes, newest first");
```

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
deal add
1
Website redesign
12000
activity log deal:1
call
25
Discovery call, budget confirmed
2026-10-05 09:30
activity log deal:1
email
Proposal v1
Sent the proposal
2026-10-05 15:10
activity log deal:9
activity log company:1
fax
activity log contact:1
call
half an hour
note add deal:1 Wants a demo before signing
note add company:1
history deal:1
history contact:1
history lead:1
quit
```

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> Name: Website (blank for none): Added company #1
crm> Name: Email: Phone (blank for none): Company id (blank for none): Added contact #1
crm> Company id: Title: Value (e.g. 1250.50): Added deal #1
crm> Kind (call/email/meeting): Duration in minutes: Summary: When (YYYY-MM-DD HH:MM, UTC; blank for now): Logged activity #1 on deal:1
crm> Kind (call/email/meeting): Email subject: Summary: When (YYYY-MM-DD HH:MM, UTC; blank for now): Logged activity #2 on deal:1
crm> Error: deal #9 not found
crm> Kind (call/email/meeting): Error: invalid activity kind: 'fax'
crm> Kind (call/email/meeting): Duration in minutes: Error: invalid duration in minutes: 'half an hour'
crm> Added note #1 to deal:1
crm> Error: Usage: note add <subject> <text...>
crm> 2026-10-05 15:10  email "Proposal v1": Sent the proposal
2026-10-05 14:48  note: Wants a demo before signing
2026-10-05 09:30  call (25 min): Discovery call, budget confirmed
crm> No history for contact:1 yet.
crm> Error: invalid subject (expected e.g. company:3, contact:5 or deal:2): 'lead:1'
crm> Goodbye! (12 commands this session)
```

The note's time is **your current UTC time**, so it lands wherever "now" falls relative to
09:30 and 15:10. Everything else should match exactly (your `Usage` wording may differ
slightly, depending on your Lab 12 `Display`).

Check:

- `activity log deal:9` failed **before** any prompts (`check_subject` in the CLI: fail fast).
- A history merges both repositories and sorts across them.
- `lead:1` is rejected by the parser. Leads aren't subjects (see the Step 3 mini-task).

## 🧠 Understand It

**The borrow graph of `history deal:1`:**

```text
crm (owned by the REPL loop)
├── activities: InMemoryRepo<Activity> ── Vec ──▶ [Activity#1, Activity#2]
│                                                    ▲            ▲
└── notes: InMemoryRepo<Note> ── Vec ──▶ [Note#1]    │            │
                                            ▲         │            │
history: Vec<HistoryItem<'_>> ─────────────[Note(&), Activity(&), Activity(&)]
         (16 bytes per item, no strings copied)
```

`history` owns its `Vec`, but every element *points into* `crm`. While `history` is alive,
`crm` is shared-borrowed: you can read anything, but you can't mutate (E0502). When `history`
goes out of scope, the borrow ends. That's the whole lifetime story, and in this lab the
compiler checked it without a single annotation at the call site.

**Time is an input.** `add_note(.., now)` and `log_activity(.., occurred_at)` don't *read* the
clock. They're *told* the time. The rule of thumb: **the domain never asks the world for
anything** (clock, files, network, randomness). The edges (CLI now, HTTP handlers in Lab 27)
gather those inputs and pass them in. Domain code stays deterministic and testable. Later you'll
see this rule as "functional core, imperative shell".

**An enum is a closed set, and that's a feature here.** `ActivityKind` lists every kind of
activity the CRM supports. Every `match` on it is checked for exhaustiveness, `Clone`/`PartialEq`
are derived, and in Lab 21 `serde` will serialize it with one attribute. The 🧪 Experiment
shows the alternative, and why we're not taking it.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: closed vs open, an enum vs `Box<dyn Trait>`.**
> Rust has two ways to say "one of several kinds of activity". You've used the enum. Now try
> **trait objects** (a first taste of Lab 23). Create `examples/activity_dyn.rs`:

```rust
//! Experiment: activities as trait objects instead of an enum.
//! Run with: cargo run --example activity_dyn

trait Describe {
    fn describe(&self) -> String;
}

struct Call {
    minutes: u32,
}

struct Email {
    subject: String,
}

struct Meeting {
    attendees: usize,
}

impl Describe for Call {
    fn describe(&self) -> String {
        format!("call ({} min)", self.minutes)
    }
}

impl Describe for Email {
    fn describe(&self) -> String {
        format!("email \"{}\"", self.subject)
    }
}

impl Describe for Meeting {
    fn describe(&self) -> String {
        format!("meeting ({} attendees)", self.attendees)
    }
}

// A brand-new kind: no existing code had to change.
struct Sms {
    text: String,
}

impl Describe for Sms {
    fn describe(&self) -> String {
        format!("sms: {}", self.text)
    }
}

fn main() {
    let activities: Vec<Box<dyn Describe>> = vec![
        Box::new(Call { minutes: 25 }),
        Box::new(Email { subject: "Proposal v1".to_string() }),
        Box::new(Meeting { attendees: 3 }),
        Box::new(Sms { text: "Running 5 min late".to_string() }),
        Box::new(Call { minutes: 10 }),
    ];

    for activity in &activities {
        println!("{}", activity.describe());
    }

    // A new *question*: how many minutes did we spend on calls?
    let total: u32 = activities.iter().map(|a| a.minutes).sum();
    println!("total call minutes: {total}");
}
```

**Part A: adding a new kind.** Notice `Sms`: a whole new kind of activity, and *no existing
code changed*. In a `Vec<Box<dyn Describe>>`, each element is a pointer to a heap value plus a
pointer to that type's **vtable** (its table of `describe` implementations). Anyone, even
another crate, can add a type. The set of kinds is **open**.

Now do the same with the enum: add `Sms { text: String },` to `ActivityKind` and `cargo check`:

```text
error[E0004]: non-exhaustive patterns: `&ActivityKind::Sms { .. }` not covered
  --> src/activities/model.rs:42:15
   |
42 |         match self {
   |               ^^^^ pattern `&ActivityKind::Sms { .. }` not covered
```

With the enum, a new kind means **visiting every `match`**, and the compiler hands you the
list. The set is **closed**: only this crate can add variants. Remove `Sms` from the enum.

**Part B: asking a new question.** Run `cargo run --example activity_dyn`:

```text
error[E0609]: no field `minutes` on type `&Box<dyn Describe>`
  --> examples/activity_dyn.rs:67:50
   |
67 |     let total: u32 = activities.iter().map(|a| a.minutes).sum();
   |                                                  ^^^^^^^ unknown field
```

Through a `dyn Describe`, you can only call what the **trait** declares. The concrete type
(and its fields) is erased. To answer "total call minutes", you have to change the trait for
*everyone*:

```rust
trait Describe {
    fn describe(&self) -> String;

    /// Added for the "total call minutes" question. Every kind gets it.
    fn call_minutes(&self) -> Option<u32> {
        None
    }
}

// in impl Describe for Call:
    fn call_minutes(&self) -> Option<u32> {
        Some(self.minutes)
    }

// in main:
    let total: u32 = activities.iter().filter_map(|a| a.call_minutes()).sum();
```

```text
call (25 min)
email "Proposal v1"
meeting (3 attendees)
sms: Running 5 min late
call (10 min)
total call minutes: 35
```

It works, but every new question grows the trait. With the enum, a new question is just a new
function with a `match`, and no type has to change:

> 🔵 **Mini-task:** write the enum version of "total call minutes" over `crm.activities`, as a
> one-line iterator chain (no new method on any type). Solution in [solutions.md](solutions.md#mini-task-total-call-minutes-with-the-enum).

**The trade-off** (known as the *expression problem*):

| | `enum ActivityKind` (closed) | `Box<dyn Describe>` (open) |
|---|---|---|
| Add a new **kind** | Edit the enum + every `match` (compiler lists them) | Add a type + impl, nothing else changes |
| Add a new **operation** | Write a function with a `match` | Add a trait method to *every* impl |
| Access a kind's data | Pattern match | Only through trait methods |
| Who can extend it | Only this crate | Anyone |
| Memory | Inline, one allocation for the whole `Vec` | One heap allocation per item + vtable pointer |
| `derive(Clone, PartialEq)`, serde (Lab 21) | Just works | Not derivable for `dyn Trait` |
| Mapping to a database (Lab 31) | `kind` column + details | You'd invent an enum anyway |

**Decision: keep the enum.** We own the full list of activity kinds, we'll ask many
questions of it (display, totals, JSON, SQL), and a new kind *should* force us to visit every
place that handles kinds. Trait objects shine when the set is genuinely **open**: plugins, or
"any storage backend" (Lab 23), where the CRM shouldn't know or care about every implementation.

Delete `examples/activity_dyn.rs` when you're done (your git history keeps it if you commit
first).

> 🟡 **EXPERIMENT 2: hidden clock.** Temporarily change `add_note` to ignore its `now`
> parameter and use `created_at: Utc::now()`. Run `cargo test history`. Which tests fail, and
> why? Which test *still passes*, and is that reassuring or worrying? Revert.

> 🟡 **EXPERIMENT 3: ties.** In `history_is_newest_first_across_activities_and_notes`, give the
> note the *same* time as the email (`at(10, 15)`). Which comes first in the history, and which
> line of code decides that? Would `sort_unstable_by_key` guarantee the same answer?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: meetings need real attendees.**
> In `Crm::log_activity` (where the `// Your Turn 1` comment is), reject a `Meeting` whose
> attendee list contains a contact id that doesn't exist, returning
> `CrmError::NotFound { entity: "contact", id }` for the **first** missing one. Nothing is
> stored on failure.

- [ ] Calls and emails are unaffected
- [ ] Use `if let` to look inside the `Meeting` variant **without moving** `kind` (it still
      needs to go into the `Activity` afterwards)
- [ ] A test logs one valid meeting and one with a missing attendee, and asserts there's exactly
      one activity at the end
- [ ] `cargo test` passes

> 🔵 **YOUR TURN 2: recent history in `deal show` and `company show`.**
> Both commands end with the **5 most recent** history items for that record, indented:
>
> ```text
>   Recent history:
>     2026-10-05 15:10  email "Proposal v1": Sent the proposal
>     2026-10-05 14:48  note: Wants a demo before signing
> ```
>
> or `  No history yet.` when there's none.

- [ ] One shared helper `fn print_recent_history(crm: &Crm, subject: Subject)` in
      `commands.rs`, used by both commands
- [ ] Uses `.take(5)`, with no manual counter
- [ ] `company show` shows only the company's *own* history (not its contacts' or deals'. That's
      the capstone's job)

> 🔵 **YOUR TURN 3: logging meetings from the CLI.**
> Add the `"meeting"` arm to `log_activity` in `commands.rs`:
>
> ```text
> Kind (call/email/meeting): meeting
> Starts at (YYYY-MM-DD HH:MM, UTC): 2026-10-07 14:00
> Attendee contact ids (e.g. 3,5; blank for none): 1, 2
> Summary: On-site demo
> When (YYYY-MM-DD HH:MM, UTC; blank for now): 2026-10-07 15:30
> Logged activity #1 on company:1
> ```
>
> - Reuse `parse_datetime` for the start time.
> - Write `fn parse_contact_ids(input: &str) -> Result<Vec<ContactId>, CrmError>`: accepts
>   `3,5`, `3, 5`, ` 3 ,5 `, and blank (→ empty `Vec`). Any non-number fails with
>   `ValidationError::InvalidValue { field: "contact id", value: <the bad part> }`.
> - Implement it as **one iterator chain** that ends in `.collect()`, with no `for` loop and
>   no `mut`.

- [ ] Unit tests for `parse_contact_ids` (valid list, blank, one bad part) and for `parse_datetime`
- [ ] Logging a meeting with attendee `7` (nonexistent) prints `Error: contact #7 not found`
      (that's Your Turn 1 at work)
- [ ] `history company:1` shows `meeting at 2026-10-07 14:00 UTC (2 attendees): On-site demo`

## 💡 Hint

> 💡 **HINT (Your Turn 1):** `if let ActivityKind::Meeting { attendees, .. } = &kind`
> matches on a *reference*, so `attendees` is a `&Vec<ContactId>`. Then `iter().find(..)`
> looks for an id that's missing from `self.contacts`.

<details><summary>Hint 2 (more specific)</summary>

Edition 2024 let chains let you combine both conditions:
`if let ActivityKind::Meeting { attendees, .. } = &kind && let Some(missing) = attendees.iter().find(|&&id| self.contacts.get(id).is_none()) { return Err(...) }`.
`|&&id|` destructures the `&&ContactId` that `find` hands the closure. A `for` loop with an
early `return` is equally correct.

</details>

> 💡 **HINT (Your Turn 2):** `crm.history(subject)` returns a `Vec`. Check `is_empty()` first,
> then iterate `history.iter().take(5)`.

> 💡 **HINT (Your Turn 3):** `collect()` can build a `Result<Vec<T>, E>` from an iterator of
> `Result<T, E>`. It stops at the first `Err`. Split on `,`, `map(str::trim)`, `filter` out
> empty parts, then `map` each part to a `Result<ContactId, CrmError>`.

<details><summary>Hint 2 (more specific)</summary>

`part.parse().map(ContactId)` gives `Result<ContactId, ParseIntError>`. `map_err` it into a
`CrmError` built from `ValidationError::InvalidValue { .. }`. The final `.collect()` needs the
function's return type to know it's collecting into `Result<Vec<ContactId>, CrmError>`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:

1. What does `chrono = "0.4.45"` in `Cargo.toml` allow Cargo to pick? Would it pick `0.5.0`? Why not?
2. What's the difference between `Cargo.toml` and `Cargo.lock`, and why do you commit the lock file?
3. What is a crate feature? How do you find out which features of a dependency are enabled?
4. When do you use `DateTime<Utc>`, `NaiveDateTime` and `NaiveDate`? Why can't you compare a
   `NaiveDateTime` with a `DateTime<Utc>`?
5. Why does `merge_history` need an explicit `'a` but `Crm::history` doesn't?
6. Why can't you call `crm.add_note(..)` while holding the result of `crm.history(..)`? What
   could go wrong at runtime if Rust allowed it?
7. Why does `add_note` take `now` as a parameter? Where in the program is `Utc::now()` called?
8. Enum vs `Box<dyn Trait>`: which one makes adding a new *kind* easy, and which one makes adding
   a new *operation* easy? Why did we keep the enum for activities?

Then verify: `cargo fmt --check && cargo clippy --all-targets && cargo test`

## Git Commit

You committed "Add chrono" in Step 1. Now the feature:

```bash
git add .
git commit -m "Add activities and notes"
git tag lab-20
git push && git push --tags
```

🎉 That's the end of **Phase 5**. Your CRM tracks companies, contacts, a deal pipeline, leads
with conversion, and a full activity history, all in memory. Before Phase 6 makes it
persistent, try [🏁 Challenge B: Sales Forecast](../../challenges/B-sales-forecast/README.md).

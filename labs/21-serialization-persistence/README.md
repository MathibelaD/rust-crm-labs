# Lab 21 — Serialization & File Persistence

> **Phase:** 6 — Persistence & Quality · **Builds on:** Lab 20 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-20` · **After:** tag `lab-21`

## 🎯 Goal
Make the CRM remember things. On start it loads everything from `crm-data.json`, and after every
command that changes data it saves again. A crash halfway through a save must never destroy the
file.

## 🧠 What You'll Learn
- What `#[derive(Serialize, Deserialize)]` actually generates, and serde's **data model**: the
  layer between your types and a format like JSON
- Why Rust needs derives where JavaScript has `JSON.stringify` (no runtime reflection)
- serde attributes: `rename_all`, `transparent`, `tag`, `default`, `try_from`/`into`, `bound`
- That **`Deserialize` is a constructor**, so it can bypass your validation, and how to make
  loading go through `Email`'s rules
- The four ways serde can represent an enum, side by side as JSON
- How derive handles generic types like `InMemoryRepo<T>`, and when it guesses the bounds wrong
- `std::fs`, `BufReader`/`BufWriter`, `std::io::Error` and `io::ErrorKind`
- **Atomic writes**: write a temp file, then rename it over the original. Why it's needed and why it
  works.
- Why `CrmError` can never derive `PartialEq` once it holds an `io::Error`, and why `matches!` is the better test anyway

## 🔨 What We're Building
Right now every session starts empty. You've built companies, contacts, deals, leads, activities
and notes, and all of it disappears when you type `quit`. That makes the CRM a toy.

The simplest real persistence is a **snapshot**: turn the entire `Crm` into one JSON document and
write it to a file. On start, read the file and turn it back into a `Crm`.

```text
            ┌──────────────── memory ───────────────┐
 start ───► │  Crm { companies, contacts, deals, … } │ ───► every mutating command
   ▲        └────────────────────────────────────────┘          │
   │ load (deserialize)                                save (serialize)
   │                                                            ▼
   └──────────────────────── crm-data.json ◄───────────────────┘
```

This is a good design for a single-user terminal app with a few thousand records. It is **not**
how a multi-user server should store data. You'll feel exactly why in Labs 25–29, and replace it
with PostgreSQL in Lab 30. The `serde` derives you add today don't get thrown away: in Lab 27 the
same machinery turns your types into HTTP JSON.

> This lab assumes you finished Lab 20, including its Your Turn tasks
> (see [Lab 20's solutions.md](../20-activities-notes-time/solutions.md) if not).

---

## Step 1 — Add serde and serde_json

```bash
cargo add serde --features derive
cargo add serde_json
```

> Written against **serde 1.0** and **serde_json 1.0** (chrono **0.4**). These are some of the
> most stable crates in the ecosystem, but if something looks different, check docs.rs.

Two crates, two jobs:

| Crate | Job |
|---|---|
| `serde` | Defines the traits `Serialize` and `Deserialize`, plus the **data model** both sides agree on. The `derive` feature adds the `#[derive(...)]` macros. |
| `serde_json` | One **format**. It knows how to turn the data model into JSON text, and JSON text back into it. |

There are dozens of other format crates (TOML, YAML, MessagePack, CSV, Postgres JSONB…). They all
work with the same derives. You'll use a second one (`csv`) in Challenge C and a third (`toml`,
through `config`) in Lab 38.

### The mental model: three layers

```text
  your type                 serde data model                 a format
 ───────────              ────────────────────              ──────────────
  Company   ──Serialize──►  struct "Company" {   ──Serializer──►  {"id":1,"name":"Acme",…}
                              id: newtype(u64),     (serde_json)
                              name: string, … }

  Company   ◄─Deserialize─  same data model       ◄─Deserializer──  {"id":1,"name":"Acme",…}
```

The data model has about 29 kinds of value: `bool`, the integer and float types, `char`,
`string`, `bytes`, `option`, `unit`, `seq` (lists), `map`, `struct`, `newtype_struct`, `unit_variant`,
`struct_variant`, and a few more. Your types never talk to JSON directly. They only say "I am a
struct called `Company` with these four fields". `serde_json` decides that a struct becomes a JSON
object.

**Why this matters to you:** when JSON looks wrong, ask which layer decided it. Field names and
enum shapes are decided by **your type's `Serialize` impl** (and you control that with
attributes). Quoting, escaping and pretty-printing are decided by **the format**.

### Why Rust needs a derive at all

In JavaScript, `JSON.stringify(obj)` walks any object at runtime. It can do that because objects
are dictionaries and the runtime can list their keys. Rust has no runtime reflection: once
compiled, a `Company` is just bytes in memory with no field names attached. So the code that
knows "`Company` has a field called `name`" has to be **generated at compile time**. That's what
`#[derive(Serialize)]` does.

Two consequences you'll feel today:
1. A type is serializable **only if it opted in**. If `Company` contains a `CompanyId`, then
   `CompanyId` must implement `Serialize` too, all the way down.
2. Mistakes are compile errors, not `undefined` at runtime.

---

## Step 2 — Your first derive, and the error it causes

Start with a single type. In `src/companies/model.rs`:

> 🟢 **FOLLOW ALONG**

```rust
use serde::{Deserialize, Serialize};

// ...

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Company {
    pub id: CompanyId,
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
}
```

> 🟡 **EXPERIMENT**: before you run it, predict. Will this compile? Run `cargo check`.

```text
error[E0277]: the trait bound `CompanyId: serde::Serialize` is not satisfied
    --> src/companies/model.rs:63:35
     |
  63 | #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
     |                                   ^^^^^^^^^ unsatisfied trait bound
  64 | pub struct Company {
  65 |     pub id: CompanyId,
     |     --- required by a bound introduced by this call
     |
help: the trait `Serialize` is not implemented for `CompanyId`
    --> src/companies/model.rs:11:1
     |
  11 | pub struct CompanyId(pub u64);
     | ^^^^^^^^^^^^^^^^^^^^
     = note: for local types consider adding `#[derive(serde::Serialize)]` to your `CompanyId` type
     = note: for types from other crates check whether the crate offers a `serde` feature flag
     ...
note: required by a bound in `companies::model::_::_serde::ser::SerializeStruct::serialize_field`
    --> .../serde_core-1.0.229/src/ser/mod.rs:1917:21
     |
1915 |     fn serialize_field<T>(&mut self, key: &'static str, value: &T) -> Result<(), Self::Error>
     |        --------------- required by a bound in this associated function
1916 |     where
1917 |         T: ?Sized + Serialize;
     |                     ^^^^^^^^^ required by this bound in `SerializeStruct::serialize_field`

error[E0277]: the trait bound `Lifecycle: serde::Serialize` is not satisfied
...
```

**Read the error.** It's not about ownership this time. It's about traits, but read it the same
careful way:

- *Where* is the problem? Line 63, inside the derive. The derive generated code that we can't see.
- *What* did that code call? `SerializeStruct::serialize_field`, once per field. Its signature
  requires `T: Serialize` for the value. So the generated code is roughly "for each field, call
  `serialize_field(name, &self.field)`", and that only works if every field type is `Serialize`.
- *Who* is missing the impl? `CompanyId` and `Lifecycle`: your own types. The compiler even
  suggests deriving on them.

Here is roughly what the derive wrote for you. You never type this, but you should be able to
picture it:

```rust
// Roughly what #[derive(Serialize)] generates (simplified)
impl Serialize for Company {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut state = serializer.serialize_struct("Company", 4)?;
        state.serialize_field("id", &self.id)?;          // needs CompanyId: Serialize
        state.serialize_field("name", &self.name)?;
        state.serialize_field("website", &self.website)?;
        state.serialize_field("lifecycle", &self.lifecycle)?; // needs Lifecycle: Serialize
        state.end()
    }
}

impl Serialize for CompanyId {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_newtype_struct("CompanyId", &self.0)
    }
}
```

Notice `serialize` is **generic over the serializer** `S`. The same impl works for JSON, TOML and
every other format, and monomorphization (Lab 16) produces a specialised copy for each format you
actually use.

The `Deserialize` derive is longer. It generates a "visitor" that receives keys and values from
the format, checks that every required field arrived exactly once, and then **builds the struct**.
Keep that last part in mind for Step 6.

Fix it by deriving on the field types:

> 🟢 **FOLLOW ALONG**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CompanyId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    Prospect,
    Customer,
    Churned,
}
```

`cargo check` is clean again.

### Look at the JSON

Seeing the output beats guessing. Create a throwaway example (you'll delete it at the end of the
lab):

> 🟢 **FOLLOW ALONG**: `examples/json_peek.rs`

```rust
use rust_crm::crm::Crm;

fn main() {
    let mut crm = Crm::new();
    let id = crm
        .add_company("Acme Ltd".into(), Some("https://acme.test".into()))
        .unwrap();
    let company = crm.companies.get(id).unwrap();
    println!("{}", serde_json::to_string_pretty(company).unwrap());
}
```

```bash
cargo run --example json_peek
```

```text
{
  "id": 1,
  "name": "Acme Ltd",
  "website": "https://acme.test",
  "lifecycle": "prospect"
}
```

Three things to notice:

1. **`"id": 1`, not `{"0": 1}` or `[1]`.** `CompanyId(u64)` is a *newtype struct*, and
   `serde_json` writes newtypes as their inner value. Your type safety stays in Rust and the JSON
   stays clean.
2. **`Option<String>`** became the string, or `null` when it's `None`.
3. **`"prospect"`** is lowercase because of `rename_all = "snake_case"`. Without it you'd get
   `"Prospect"`, the Rust variant name. We choose snake_case on purpose: it matches your
   `Display`/`FromStr` strings, it's what JSON APIs conventionally use (Lab 27), and it's exactly the
   value Postgres will store in a `TEXT` column with a `CHECK` constraint (Lab 30). A variant like
   `ColdOutreach` becomes `"cold_outreach"`.

> 🟡 **EXPERIMENT**: remove `#[serde(rename_all = "snake_case")]` from `Lifecycle`, run the
> example, then put it back. The attribute only changes the generated `Serialize`/`Deserialize`
> code. Your `Display` impl is untouched.

---

## Step 3 — Derive across the whole domain

Now do the same for everything that lives inside `Crm`. Add `Serialize, Deserialize` to the
**end** of the existing derive list of each of these (keep every derive that's already there) (and `use serde::{Deserialize, Serialize};` at the top of each file):

| File | Types |
|---|---|
| `companies/model.rs` | `CompanyId`, `Lifecycle` (snake_case), `Company` ✔️ done |
| `contacts/model.rs` | `ContactId`, `Contact` |
| `deals/model.rs` | `DealId`, `DealStage` (snake_case), `Deal` |
| `leads/model.rs` | `LeadId`, `LeadSource` (snake_case), `LeadStatus` (snake_case), `Lead` |
| `activities/model.rs` | `ActivityId`, `ActivityKind` (wait for Step 6 for its attribute), `Activity` |
| `notes/model.rs` | `NoteId`, `Note` |
| `subject.rs` | `Subject` (snake_case) |

Don't touch `Email`, `Money`, `InMemoryRepo` or `Crm` yet. They each teach something.

Leave `LeadBuilder`, `ConversionIds`, `Conversion`, `ConvertError`, `PipelineRow` and
`HistoryItem` (in `src/history.rs`) alone too, along with the `stats` types from Lab 17. They're
never stored. `HistoryItem<'a>` *can't* even derive `Deserialize` sensibly: it holds borrowed
references into the `Crm`, and a deserializer has no `Crm` to borrow from. **Only derive what you need**: every derive is
generated code to compile, and every serializable type is a format you've promised to keep
loading in the future.

> If you did **Challenge B**, `Deal` has `expected_close: Option<NaiveDate>`. `NaiveDate` needs the
> same chrono `serde` feature you're about to add. Mark the field `#[serde(default)]` too: a missing
> `Option` field already loads as `None`, but the attribute makes the "older files don't have this"
> intent explicit.

Run `cargo check`. You'll get a wall of errors, but there are only three distinct ones:

```text
error[E0277]: the trait bound `DateTime<Utc>: serde::Serialize` is not satisfied
    --> src/activities/model.rs:34:9
     |
  34 |         starts_at: DateTime<Utc>,
     |         ^^^^^^^^^ the trait `Serialize` is not implemented for `DateTime<Utc>`
     |
     = note: for local types consider adding `#[derive(serde::Serialize)]` to your `DateTime<Utc>` type
     = note: for types from other crates check whether the crate offers a `serde` feature flag
...
error[E0277]: the trait bound `Email: serde::Deserialize<'de>` is not satisfied
...
error[E0277]: the trait bound `Money: serde::Serialize` is not satisfied
...
```

### Fixing `DateTime<Utc>`: crate features

You can't add a derive to `chrono`'s types. They aren't yours. (Rust's *orphan rule* says you
may only implement a trait for a type if you own the trait or the type. You own neither
`Serialize` nor `DateTime`.) The crate that owns the type has to provide the impl, and the second
note in the error tells you where to look: *"check whether the crate offers a `serde` feature
flag"*.

`chrono` does. It's off by default so that people who don't use serde don't pay to compile it:

```bash
cargo add chrono --features serde
```

Open `Cargo.toml`. `chrono`'s line now lists `features = ["serde"]`. Features are **conditional
compilation**: inside chrono there's code like `#[cfg(feature = "serde")] impl Serialize for
DateTime<Utc> { … }`, and it only exists when you ask for it. `cargo tree -e features -i chrono`
shows which features are active and who enabled them.

Run `cargo check` again. The `DateTime` errors are gone. In JSON, a `DateTime<Utc>` becomes an
RFC 3339 string like `"2026-10-05T14:29:34.228488Z"`: unambiguous, sortable as text, and
understood by every language.

---

## Step 4 — `Money`: choosing a representation on purpose

> 🟢 **FOLLOW ALONG**: in `src/money.rs`, add the derive the obvious way first.

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize)]
pub struct Money {
    cents: i64,
}
```

Add one line to `examples/json_peek.rs` and run it:

```rust
println!("{}", serde_json::to_string(&rust_crm::money::Money::from_cents(125050)).unwrap());
```

```text
{"cents":125050}
```

That works, but every deal value in the file will be wrapped in a pointless object. `Money` is a
struct with one field, so we can tell serde to treat it as that field:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Money {
    cents: i64,
}
```

```text
125050
```

Why not store `"1250.50"` or `1250.5`? A float can't represent most decimal fractions exactly
(Lab 18's `0.1 + 0.2` experiment), and a formatted string needs parsing rules. **Integer cents**
are exact, and every language can read them. When the HTTP API arrives (Lab 29), you'll name the
JSON field `value_cents` to make the unit obvious.

Note that `cents` is a **private** field, yet the derive could read it. The generated impl lives in
the same module as the struct, so privacy doesn't stop it. That's a feature, not a loophole: you
opted in by writing the derive.

---

## Step 5 — `Email`: deserializing is constructing

`Email` is a newtype with a private field, and `Email::parse` is the only way to make one. That's
the invariant from Labs 12–13: *if you're holding an `Email`, it's valid.*

> 🟡 **EXPERIMENT**: derive the obvious way, then try to smuggle in a bad email.

```rust
// src/contacts/email.rs
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Email(String);
```

Add to `examples/json_peek.rs`:

```rust
let bad: rust_crm::contacts::Email = serde_json::from_str("\"NOT AN EMAIL\"").unwrap();
println!("{bad:?}");
```

Predict what happens, then run it.

```text
Email("NOT AN EMAIL")
```

That's a real `Email` value holding something your rules would have rejected: not lowercased, no
`@`, contains spaces. **The derived `Deserialize` is a constructor.** It builds the struct directly
from its fields, exactly like writing `Email(s)` inside the module would. It doesn't know
`Email::parse` exists. Every invariant you protect with a private field plus a validating
constructor, a derived `Deserialize` quietly goes around.

This is the most important idea in the lab: **a data file is input**. It can be hand-edited,
written by an older version of your program, or corrupted. It deserves the same validation as
anything the user types.

serde has a precise tool for this. "To deserialize an `Email`, first deserialize a `String`, then
convert it with `TryFrom`; to serialize, convert into a `String`":

> 🟢 **FOLLOW ALONG**

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Email(String);
```

`cargo check`:

```text
error[E0277]: the trait bound `String: From<Email>` is not satisfied
  --> src/contacts/email.rs:29:45
   |
29 | #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
   |                                             ^^^^^^^^^ the trait `From<Email>` is not implemented for `String`
   |
   = note: required for `Email` to implement `Into<String>`

error[E0277]: the trait bound `Email: TryFrom<String>` is not satisfied
  --> src/contacts/email.rs:29:56
   |
29 | #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
   |                                                        ^^^^^^^^^^^ unsatisfied trait bound
   |
help: the trait `TryFrom<String>` is not implemented for `Email`
      but trait `TryFrom<&str>` is implemented for it
  --> src/contacts/email.rs:62:1
   |
62 | impl TryFrom<&str> for Email {
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = help: for that trait implementation, expected `&str`, found `String`
```

(Both errors also list a few extra `note:` lines; the ones above are the ones to read.)

The attribute is a promise that two conversions exist. Read the second error closely: you have
`TryFrom<&str>` from Lab 15, but serde asked for `TryFrom<String>`. Why `String`? Because
serde deserializes an **owned** `String` first (the JSON text may contain escapes like `\n`, so
a borrowed slice of the input isn't always possible), then hands it to you by value.

> 🟢 **FOLLOW ALONG**: add both impls to `src/contacts/email.rs`.

```rust
impl TryFrom<String> for Email {
    type Error = ValidationError;

    fn try_from(input: String) -> Result<Self, Self::Error> {
        Email::try_from(input.as_str())
    }
}

impl From<Email> for String {
    fn from(email: Email) -> String {
        email.0
    }
}
```

- `TryFrom<String>` borrows the owned string as `&str` and reuses the rules you already have.
  One source of truth for validation.
- `From<Email> for String` **consumes** the `Email` and moves its inner `String` out. No copy.
  (serde clones the `Email` first, because serializing only has `&self`. That's why `into`
  requires `Clone`, and `Email` already derives it.)
- serde needs the `TryFrom` error type to implement `Display` so it can put it in the
  deserialization error. `ValidationError` already does.

Run the example again:

```text
called `Result::unwrap()` on an `Err` value: Error("'NOT AN EMAIL' is not a valid email address", line: 0, column: 0)
```

Your validation message, inside serde_json's error. Loading now goes **through** the front door.

> 🔵 **Quick check (no code)**: `Money` has a private field too. Is there an invariant a derived
> `Deserialize` could bypass there? (Answer in solutions.md.)

---

## Step 6 — Enum representations: one enum, four JSON shapes

JSON has no "enum". serde has to *encode* "which variant is this" somehow, and there are four
standard ways. Here is `ActivityKind::Call { minutes: 15 }` under each one (real output):

| Attribute on the enum | Name | JSON for `Call { minutes: 15 }` |
|---|---|---|
| *(none)* | externally tagged (default) | `{"Call":{"minutes":15}}` |
| `#[serde(tag = "type")]` | internally tagged | `{"type":"call","minutes":15}` |
| `#[serde(tag = "type", content = "data")]` | adjacently tagged | `{"type":"call","data":{"minutes":15}}` |
| `#[serde(untagged)]` | untagged | `{"minutes":15}` |

(The last three rows also use `rename_all = "snake_case"`.)

How to choose:

- **Externally tagged** works for every kind of variant, but `{"Call": {...}}` is awkward for
  other languages to consume.
- **Internally tagged** gives the flattest, most "normal" JSON: one object with a `type` field.
  This is what most JSON APIs look like, and it's what we want for `ActivityKind`. Its limit:
  every variant must be a struct-like variant (or a newtype holding a struct).
- **Adjacently tagged** works for every variant shape and is still easy to consume.
- **Untagged** carries no tag at all. On the way back in, serde tries each variant in order and
  takes the first that fits. Ambiguous and slow to fail; avoid it for data you own.

> 🟢 **FOLLOW ALONG**: in `src/activities/model.rs`

```rust
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ActivityKind {
    Call { minutes: u32 },
    Email { subject: String },
    Meeting { starts_at: DateTime<Utc>, attendees: Vec<ContactId> },
}
```

### Why `Subject` stays externally tagged

`Subject` is `Company(CompanyId) | Contact(ContactId) | Deal(DealId)`: *newtype variants holding
a number*. An internal tag needs an object to put the `"type"` key into, and a bare number isn't
an object. serde can't detect that at compile time, so it fails **at runtime**:

```text
Error("cannot serialize tagged newtype variant Subject::Contact containing an integer", line: 0, column: 0)
```

So `Subject` keeps the default (externally tagged) representation. Without attributes that's
`{"Contact": 1}`. We add `rename_all = "snake_case"` like every other enum, so it's:

```json
"subject": { "contact": 1 }
```

**Design choice, documented:** a third option would be to store `Subject` as the same string the
CLI uses, `"contact:1"`, with `#[serde(try_from = "String", into = "String")]` plus
`TryFrom<String>` / `From<Subject> for String` built on your existing `FromStr`/`Display` (the
exact technique from Step 5). That's compact and human-friendly. We stay with the derived form
because it needs no extra code, and because every other enum in the file uses the same shape. Both
are reasonable; what matters is choosing once and keeping old files loadable.

> 🟡 **EXPERIMENT**: put `#[serde(tag = "type")]` on `Subject`, then make the CRM save an
> activity (Step 10 onwards) or serialize one in `json_peek`. Watch the runtime error, then
> remove the attribute. Question: why could the compiler not catch this one for you?

---

## Step 7 — Generic types: `InMemoryRepo<T>` and `Crm`

> 🟢 **FOLLOW ALONG**: in `src/repo.rs` and `src/crm.rs`

```rust
// src/repo.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct InMemoryRepo<T: Entity> {
    items: Vec<T>,
    next_id: u64,
}
```

```rust
// src/crm.rs (`Debug` is new on `Crm` too; it works now that `InMemoryRepo` derives it)
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Crm {
    pub companies: InMemoryRepo<Company>,
    // ... unchanged
}
```

`cargo check` passes. Think about what the derive had to generate for a generic struct. It can't
be `impl Serialize for InMemoryRepo<T>` for *every* `T`, since some `T` might not be serializable.
So it **infers bounds** from the field types:

```rust
// roughly what the derive produced
impl<T: Entity + Serialize> Serialize for InMemoryRepo<T> { … }
impl<'de, T: Entity + Deserialize<'de>> Deserialize<'de> for InMemoryRepo<T> { … }
```

`Crm` is serializable because `InMemoryRepo<Company>` is, because `Company` is. The trait
system checks the whole chain at compile time.

Two details worth seeing:

- **`next_id` is saved too.** It's a private field, and it's essential: if you loaded the
  companies but restarted `next_id` at 1, the next `company add` would reuse id 1. Saving the
  repo as a whole keeps its invariant intact.
- `#[derive(Default)]` on `Crm` uses `InMemoryRepo<T>: Default` from Lab 16. You'll lean on that
  again in the Your Turn.

### When the inferred bounds are wrong

The inference is a heuristic: it looks at type parameters that appear in fields. It handles `T`
and `Vec<T>`. It does **not** see through an associated type like `T::Id` nested inside another
type.

> 🟡 **EXPERIMENT**: imagine the repo remembered recently deleted ids. Add a field, and initialise
> it as `recently_deleted: Vec::new()` in both `new()` and `default()`:

```rust
pub struct InMemoryRepo<T: Entity> {
    items: Vec<T>,
    next_id: u64,
    recently_deleted: Vec<T::Id>,
}
```

```text
error[E0277]: the trait bound `<T as Entity>::Id: serde::Serialize` is not satisfied
    --> src/repo.rs:6:17
     |
   6 | #[derive(Debug, Serialize, Deserialize)]
     |                 ^^^^^^^^^ the trait `Serialize` is not implemented for `<T as Entity>::Id`
...
  10 |     recently_deleted: Vec<T::Id>,
     |     ---------------- required by a bound introduced by this call

error[E0277]: the trait bound `<T as Entity>::Id: serde::Deserialize<'de>` is not satisfied
```

The derive wrote `T: Serialize` but the generated code also needs `T::Id: Serialize`. Every one of
*your* id types is serializable, but the generic impl has to work for **any** `T: Entity`, and
`Entity` doesn't promise a serializable id. When the guess is wrong, you write the bounds
yourself:

```rust
#[derive(Debug, Serialize, Deserialize)]
#[serde(bound(
    serialize = "T: Serialize, T::Id: Serialize",
    deserialize = "T: Deserialize<'de>, T::Id: Deserialize<'de>"
))]
pub struct InMemoryRepo<T: Entity> {
```

That compiles. (The other fix is to add `Serialize + DeserializeOwned` to `Entity::Id`'s bounds,
but that would tie your domain trait to one serialization library.)

**Now remove the `recently_deleted` field and the `bound` attribute again.** We don't need either.
The lesson is how to read the error: *the derive generated a generic impl, and the bounds it chose
don't cover what the body needs.*

---

## Step 8 — Errors that come from the outside world

Loading and saving can fail in two new ways: the **file system** (`std::io::Error`: permission
denied, disk full, not found) and the **format** (`serde_json::Error`: broken JSON, missing field,
invalid email). `CrmError` needs to be able to carry both.

> 🟡 **EXPERIMENT**: add the variants and `Display` arms in `src/errors.rs`. Predict whether it
> compiles first.

```rust
pub enum CrmError {
    // ... existing variants ...
    Io(std::io::Error),
    Json(serde_json::Error),
}

// in impl fmt::Display for CrmError:
CrmError::Io(e) => write!(f, "file error: {e}"),
CrmError::Json(e) => write!(f, "data file is not valid: {e}"),
```

That compiles. Since Lab 12 your `CrmError` has derived only `Debug`, and your tests check errors
with `matches!` instead of `assert_eq!`. Now you'll see why that was more than a style choice.

> 🟡 **EXPERIMENT**: add `PartialEq` to `CrmError`'s derive list, as if you wanted
> `assert_eq!(result, Err(CrmError::NotFound { .. }))` in a test. Run `cargo check`.

```text
error[E0369]: binary operation `==` cannot be applied to type `&std::io::Error`
  --> src/errors.rs:64:8
   |
53 | #[derive(Debug, PartialEq)]
   |                 --------- in this derive macro expansion
...
64 |     Io(std::io::Error),
   |        ^^^^^^^^^^^^^^
   |
note: `std::io::Error` does not implement `PartialEq`

error[E0369]: binary operation `==` cannot be applied to type `&serde_json::Error`
  --> src/errors.rs:65:10
   |
65 |     Json(serde_json::Error),
   |          ^^^^^^^^^^^^^^^^^
   |
note: `serde_json::Error` does not implement `PartialEq`
```

`#[derive(PartialEq)]` on an enum generates "two values are equal if they're the same variant and
their fields are equal". That needs `==` on every field type. Why doesn't `io::Error` have it?
Because there's no sensible answer: an `io::Error` can wrap an OS error code, a static message, or
a **boxed arbitrary error** from someone else's code (`Box<dyn Error + Send + Sync>`), and there's
no general way to compare two arbitrary trait objects. The standard library chose not to pretend.
For the same reason, error types in the ecosystem usually don't implement `PartialEq`.

Remove `PartialEq` again. From now on it's not a choice: `CrmError` **can't** be compared with `==`.
(`ValidationError` keeps its `PartialEq`, since all its fields are strings and `&'static str`s.) If
any of your tests still compares a `Result<_, CrmError>` with `assert_eq!`, it now fails with E0369
"an implementation of `PartialEq` might be missing for `errors::CrmError`". Rewrite it with one of
the two patterns you already know:

> 🟢 **FOLLOW ALONG**

```rust
// 1. Testing an error: assert on the *shape* with matches!
let result = parse_command("dance");
assert!(matches!(result, Err(CrmError::UnknownCommand(ref c)) if c == "dance"));

// 2. Testing success: unwrap first, then compare the Ok value (which still has PartialEq)
let command = parse_command("deal move 2 won").unwrap();
assert_eq!(command, Some(Command::Deal(DealCommand::Move { id: DealId(2), stage: DealStage::Won })));
```

`matches!(value, pattern if guard)` is `match value { pattern if guard => true, _ => false }` in
one line. `ref c` borrows the `String` inside the pattern instead of moving it out of `result`.
For `NotFound { entity: "company", id: 7 }`, the pattern can contain the literals directly:
`matches!(r, Err(CrmError::NotFound { entity: "company", id: 7 }))`.

Those tests are also *better* tests: they compare exactly what they care about, not every field of
an error. If a `matches!` assertion fails in an unhelpful way, `unwrap_err()` plus `assert!(matches!(...), "got {err:?}")` gives a better
message.

### `From` impls so `?` works

Finally, teach `?` to convert the outside-world errors. Add to `src/errors.rs`:

```rust
impl From<std::io::Error> for CrmError {
    fn from(e: std::io::Error) -> Self {
        CrmError::Io(e)
    }
}

impl From<serde_json::Error> for CrmError {
    fn from(e: serde_json::Error) -> Self {
        CrmError::Json(e)
    }
}
```

`?` on a `Result<T, io::Error>` inside a function returning `Result<_, CrmError>` now calls
`CrmError::from(e)` for you. In Lab 22 a macro will write these impls, and you'll also ask
whether file errors even *belong* in a domain error type. (Spoiler: they don't.)

---

## Step 9 — Loading: `src/storage.rs`

Create `src/storage.rs` and add `pub mod storage;` to `src/lib.rs`.

> 🟢 **FOLLOW ALONG**

```rust
//! Loading and saving the whole CRM as one JSON document.

use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use crate::crm::Crm;
use crate::errors::CrmError;

/// Loads the CRM from `path`. A missing file is not an error: it means
/// "first run", so you get an empty CRM.
pub fn load(path: &Path) -> Result<Crm, CrmError> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Crm::default()),
        Err(e) => return Err(e.into()),
    };
    let reader = BufReader::new(file);
    let crm = serde_json::from_reader(reader)?;
    Ok(crm)
}
```

Line by line:

- **`path: &Path`**. `Path` is to `PathBuf` what `str` is to `String`: a borrowed view of an
  owned path. Paths aren't `str` because operating systems allow file names that aren't valid UTF-8.
  Taking `&Path` means callers can pass `Path::new("crm-data.json")`, a `&PathBuf`, or anything
  that derefs to `Path`.
- **`match File::open(path)` with a guard.** We only want to treat *one* error kind as "fine":
  `NotFound`. `io::Error::kind()` returns an `io::ErrorKind` enum you can compare, with no string
  matching on messages. Permission denied, or "it's a directory", still fail loudly.
- **`e.into()`** is the `From<io::Error>` you just wrote, called explicitly. (`?` does the same thing
  implicitly.)
- **`BufReader`**. A `File` read goes straight to the OS with a system call. A deserializer asks
  for input in tiny pieces, so `BufReader` reads 8 KiB at a time into memory and serves the small
  reads from there. *(`fs::read` + `serde_json::from_slice` is another good option and often
  faster for files that fit in memory. We use the reader version because the pattern recurs
  everywhere in Rust I/O.)*
- **`serde_json::from_reader(reader)?`** returns `Result<T, serde_json::Error>`. How does it know
  `T` is `Crm`? From the return type: `crm` flows into `Ok(crm)`, and the function returns
  `Result<Crm, _>`. Type inference runs backwards from usage.

---

## Step 10 — Saving atomically

The naive save is three lines:

```rust
// ❌ Don't do this
let file = File::create(path)?;                  // truncates the file to 0 bytes immediately
serde_json::to_writer_pretty(file, crm)?;        // writes, piece by piece
```

What happens if the process dies in the middle? The laptop runs out of battery, the user hits
Ctrl-C, the disk fills up halfway, or a bug panics while serializing:

```text
time ─────────────────────────────────────────────────────────────►
         File::create         write…write…write…  💥 crash
crm-data.json:  [old, good data] → [empty] → [half of new JSON] → stays like this forever
```

`File::create` destroyed the old data **before** the new data existed. After a crash, the file
holds neither version. Your users' whole CRM is gone.

The fix is a classic: **write somewhere else, then swap.**

```text
1. write the full new JSON to crm-data.json.tmp     (crm-data.json untouched)
2. flush + fsync crm-data.json.tmp                   (bytes are really on disk)
3. rename crm-data.json.tmp → crm-data.json          (one atomic step)
```

A crash during 1 or 2 leaves a half-written `.tmp` and an intact original. A crash after 3 means
the new version is complete. On the same file system, `rename` replaces the directory entry in a
single operation: any reader sees either the old file or the new file, never a mix. (On Windows,
`std::fs::rename` also replaces an existing file. The guarantees are a little weaker there, but
it's still far safer than truncating in place.)

> 🟢 **FOLLOW ALONG**: add to `src/storage.rs`

```rust
/// Saves the CRM to `path` atomically: write a temporary file next to it,
/// then rename it over the real one.
pub fn save(crm: &Crm, path: &Path) -> Result<(), CrmError> {
    let tmp = tmp_path(path);
    let file = File::create(&tmp)?;
    let mut writer = BufWriter::new(file);
    serde_json::to_writer_pretty(&mut writer, crm)?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    fs::rename(&tmp, path)?;
    Ok(())
}

/// `crm-data.json` -> `crm-data.json.tmp`
fn tmp_path(path: &Path) -> PathBuf {
    let mut name: OsString = path.as_os_str().to_owned();
    name.push(".tmp");
    PathBuf::from(name)
}
```

Why each line is there:

- **The temp file is next to the target** (same directory), not in `/tmp`. `rename` is only
  atomic within one file system, and `/tmp` is often a different one.
- **`tmp_path`** works on `OsString`, the owned, not-necessarily-UTF-8 string type behind paths.
  `path.with_extension("tmp")` would give `crm-data.tmp` and lose the `.json` part. Appending keeps
  the name obvious.
- **`to_writer_pretty(&mut writer, crm)`** passes `&mut writer`, not `writer`. `to_writer` takes any
  `W: Write`, and `&mut BufWriter` implements `Write` too. If we passed `writer` by value it would be
  **moved** into the function and we couldn't call `flush()` afterwards. (Try it and read the
  E0382.)
- **`writer.flush()?`**. `BufWriter` holds up to 8 KiB in memory. Dropping it would flush
  automatically, **but `Drop` can't return an error**, so a failed final write would be silently
  ignored. Flushing explicitly turns that failure into an `Err` you can see.
- **`writer.get_ref().sync_all()?`**. `flush` hands bytes to the OS. The OS may still keep them in
  its own cache for a while. `sync_all` (fsync) waits until they're on the disk. `get_ref()`
  borrows the inner `File` without taking it out of the `BufWriter`.
- **`fs::rename`**. The atomic swap.

Pretty-printed JSON is bigger, but you'll read this file with your own eyes in the experiments.
It's the right trade for now.

---

## Step 11 — Wire it into the REPL

Open `src/cli/mod.rs`. The REPL should:

1. load `crm-data.json` at start, and **refuse to start** if the file exists but can't be loaded,
2. print what it loaded,
3. save after every command that **changes** data.

> 🟢 **FOLLOW ALONG**: adapt your Lab 14 `run()`. The parts marked `NEW` are the changes; the
> rest is the loop you already have. (The helper is called `count`, and so is the loop's
> counter. That's fine: the counter is declared after the last call to the helper, and shadows
> it from there on.)

```rust
use std::path::Path;

use crate::storage;

const DATA_FILE: &str = "crm-data.json";

/// `count(1, "deal", "deals")` -> "1 deal"
fn count(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

pub fn run() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    // NEW: load, or refuse to start (this replaces `let mut crm = Crm::new();`)
    let path = Path::new(DATA_FILE);
    let mut crm = match storage::load(path) {
        Ok(crm) => crm,
        Err(e) => {
            println!("Error: could not load {DATA_FILE}: {e}");
            println!(
                "Refusing to start, so the file is not overwritten. Fix or move it and try again."
            );
            return;
        }
    };
    println!(
        "Loaded {}, {}, {}, {} from {DATA_FILE}",
        count(crm.companies.len(), "company", "companies"),
        count(crm.contacts.len(), "contact", "contacts"),
        count(crm.deals.len(), "deal", "deals"),
        count(crm.leads.len(), "lead", "leads"),
    );
    let mut count = 0;

    let commands_run = loop {
        print!("crm> ");
        io::stdout().flush().expect("failed to flush stdout");

        let mut input = String::new();
        let bytes = io::stdin()
            .read_line(&mut input)
            .expect("failed to read line");
        if bytes == 0 {
            println!();
            break count;
        }

        let result = match parser::parse_command(&input) {
            Ok(None) => continue,
            Ok(Some(Command::Quit)) => break count,
            Ok(Some(command)) => {
                // NEW: ask before `execute` takes the command, save after it succeeds
                let mutating = command.is_mutating();
                let result = commands::execute(&mut crm, command);
                if result.is_ok()
                    && mutating
                    && let Err(e) = storage::save(&crm, path)
                {
                    println!("Error: could not save {DATA_FILE}: {e}");
                }
                result
            }
            Err(e) => Err(e),
        };
        count += 1;

        if let Err(e) = result {
            println!("Error: {e}");
        }
    };

    println!("Goodbye! ({commands_run} commands this session)");
}
```

`use crate::crm::Crm;` is no longer needed in `cli/mod.rs` (the compiler will tell you). The
`if ... && let Err(e) = ...` is an edition 2024 **let chain**: "if the command succeeded, and it
mutates, and saving fails, then report it". (`cargo clippy` suggests exactly this shape if you
write it as two nested `if`s.)

**Why refuse to start?** If the file is corrupt and we shrugged and started with an empty `Crm`,
the very next `company add` would *save*, overwriting the user's (repairable) data with one
company. Failing loudly is the kind option.

**Why compute `mutating` before `execute`?**

> 🟡 **EXPERIMENT**: replace `mutating` in the `if` with `command.is_mutating()` and run
> `cargo check`.

```text
error[E0382]: borrow of moved value: `command`
  --> src/cli/mod.rs:68:24
   |
63 |             Ok(Some(command)) => {
   |                     ------- move occurs because `command` has type `parser::Command<'_>`, which does not implement the `Copy` trait
...
66 |                 let result = commands::execute(&mut crm, command);
   |                                                          ------- value moved here
67 |                 if result.is_ok()
68 |                     && command.is_mutating()
   |                        ^^^^^^^ value borrowed here after move
   |
note: consider changing this parameter type in function `execute` to borrow instead if owning the value isn't necessary
```

Who owns `command`? The loop body, until it's **moved** into `execute` (which takes `Command` by
value, because it destructures the command and moves strings like a note's body out of it).
After the move, `command` is gone, so you can't borrow it to ask a question. Asking *before*
handing it over, and keeping the answer in a `bool` (`Copy`), is the natural fix. Cloning the
command, or changing `execute` to borrow just to ask one question, would both be the wrong fix.
Revert to the `let mutating = ...` version.

> 🔵 **YOUR TURN 1: `Command::is_mutating`**
>
> Implement, in `src/cli/parser.rs`:
>
> ```rust
> impl Command<'_> {
>     /// Does running this command change the CRM (and therefore need a save)?
>     pub(crate) fn is_mutating(&self) -> bool
> }
> ```
>
> - [ ] `true` for: `company add|stage|delete`, `contact add|update|delete`, `deal add|move`,
>   `lead add|qualify|disqualify|convert`, `activity log`, `note add`
> - [ ] `false` for everything that only reads: `help`, `version`, `quit`, `stats`, `pipeline`,
>   `history`, every `list`, `show` and `search`
> - [ ] **No `_ =>` catch-all arm.** When you add a command in a later lab, the compiler must force
>   you to decide whether it mutates. (Why is a forgotten `true` merely slow, but a forgotten
>   `false` a data-loss bug?)
> - [ ] A unit test in `parser.rs`: `contact list` is not mutating, `deal move 1 won` is.

Finally, the data file is *your* data, not source code. Add it (and the temp file) to
`.gitignore`:

```text
/target
crm-data.json
crm-data.json.tmp
```

---

## ▶️ Run It

```bash
rm -f crm-data.json      # start clean
cargo run
```

Add a company and a contact, log a call, quit. Then run again and list.

## ✅ Expected Result

First session:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Loaded 0 companies, 0 contacts, 0 deals, 0 leads from crm-data.json
crm> company add
Name: Acme Ltd
Website (optional): https://acme.test
Added company #1
crm> contact add
Name: Ada Lovelace
Email: ada@acme.test
Phone (optional): 555-0100
Company id (blank for none): 1
Added contact #1
crm> activity log contact:1
Kind (call/email/meeting): call
Duration in minutes: 15
Summary: Intro call
When (YYYY-MM-DD HH:MM, UTC; blank for now):
Logged activity #1 on contact:1
crm> quit
Goodbye! (3 commands this session)
```

`cat crm-data.json` (abridged):

```json
{
  "companies": {
    "items": [
      {
        "id": 1,
        "name": "Acme Ltd",
        "website": "https://acme.test",
        "lifecycle": "prospect"
      }
    ],
    "next_id": 2
  },
  "contacts": {
    "items": [
      {
        "id": 1,
        "name": "Ada Lovelace",
        "email": "ada@acme.test",
        "phone": "555-0100",
        "company_id": 1
      }
    ],
    "next_id": 2
  },
  "deals": { "items": [], "next_id": 1 },
  "leads": { "items": [], "next_id": 1 },
  "activities": {
    "items": [
      {
        "id": 1,
        "subject": { "contact": 1 },
        "kind": { "type": "call", "minutes": 15 },
        "summary": "Intro call",
        "occurred_at": "2026-10-05T14:29:34.228488Z"
      }
    ],
    "next_id": 2
  },
  "notes": { "items": [], "next_id": 1 }
}
```

Second session:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Loaded 1 company, 1 contact, 0 deals, 0 leads from crm-data.json
crm> contact list
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.test            555-0100       #1
Page 1 of 1 (1 matching)
crm> quit
Goodbye! (1 commands this session)
```

And `ls` shows no `crm-data.json.tmp` left behind.

## 🧠 Understand It

**Serde is two traits and a data model.** `Serialize` says "here's how to describe me".
`Deserialize` says "here's how to build me from a description". Formats (`serde_json`) translate
descriptions to and from bytes. A derive writes your half at compile time, because Rust has no
runtime reflection to do it on the fly.

**Attributes change the generated code, not your type.** `rename_all`, `transparent`, `tag`,
`try_from`, `bound`: each one tweaks what the derive generates. Your Rust type and its
`Display`/`FromStr` impls are unaffected.

**Deserialize is a constructor, so it's a trust boundary.** Anything with an invariant
(`Email`) must deserialize through its validating constructor (`try_from`). What serde **can't**
check for you are rules *across* records: a contact whose `company_id` points to a deleted company
will load without complaint. Types protect values; relationships need code (and in Lab 30, a
database foreign key).

**Errors from the outside world aren't comparable.** That's why `CrmError` can never have `PartialEq` now,
and why `matches!` is the idiomatic way to test errors.

**`?` is `match` + `From::from` + early return.** That's why adding two `From` impls made every
`?` in `storage.rs` work.

**Atomic save = never destroy the old version before the new one is complete.** Write to a
sibling temp file, flush and fsync, then rename. Explicit `flush` exists because `Drop` can't
report errors.

**Refusing to start on a bad file** protects the user's data from your own autosave.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: a hand-edited file.** Run the CRM once so `crm-data.json` has a contact. Back
> it up (`cp crm-data.json backup.json`), edit the email in the file to `"ada at acme"`, then
> `cargo run`:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
Error: could not load crm-data.json: data file is not valid: 'ada at acme' is not a valid email address at line 18 column 31
Refusing to start, so the file is not overwritten. Fix or move it and try again.
```

Your own `ValidationError` message, with a line and column from serde_json. Which code produced
which part of that line?

> 🟡 **EXPERIMENT 2: a torn write.** Simulate what a crash during a *non-atomic* save leaves
> behind: `head -c 300 backup.json > crm-data.json`, then `cargo run`.

```text
Error: could not load crm-data.json: data file is not valid: EOF while parsing a value at line 18 column 16
```

That's the file a naive `File::create` + crash would leave you with. Now explain to yourself why
the temp-file-and-rename version can never produce it.

> 🟡 **EXPERIMENT 3: an unknown variant.** Restore the backup, then change `"type": "call"` to
> `"type": "phone_call"`:

```text
Error: could not load crm-data.json: data file is not valid: unknown variant `phone_call`, expected one of `call`, `email`, `meeting` at line 41 column 30
```

serde knows the full list of variants because the derive generated it. Question: if Lab 39 adds an
`ActivityKind::FollowUp` variant, can **old** files still be loaded by the **new** program? Can
**new** files be loaded by the **old** program? (Answer in solutions.md.)

Restore `backup.json` to `crm-data.json` when you're done.

> 🟡 **EXPERIMENT 4: what does exit code say?** After experiment 1, run `echo $?`. It prints `0`
> ("success") even though the CRM refused to start. A script running your CRM couldn't tell
> anything went wrong. Lab 22 fixes this.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1** is in Step 11 (`Command::is_mutating`). Do it first: the REPL needs it.

> 🔵 **YOUR TURN 2: storage tests.** Add a `#[cfg(test)] mod tests` at the bottom of
> `src/storage.rs` with these tests. Each test that touches the disk must use **its own file** in
> `std::env::temp_dir()` (tests run in parallel; two tests sharing a path will randomly break each
> other) and must delete it afterwards. Write a small helper `fn temp_file(name: &str) -> PathBuf`
> for that. Include `std::process::id()` in the file name so two `cargo test` runs don't collide.
> (Lab 24 replaces this helper with the `tempfile` crate.)
>
> - [ ] `load_missing_file_gives_empty_crm`
> - [ ] `save_then_load_round_trips`: build a `Crm` with a company, a contact (with company) and a
>   deal; save; load; check the counts, the contact's email and the deal's value survived
> - [ ] the same test (or a second one) proves **`next_id` survived**: after loading a CRM with one
>   company, `add_company` returns `CompanyId(2)`, not `CompanyId(1)`
> - [ ] `save_leaves_no_tmp_file_behind`
> - [ ] `load_rejects_an_invalid_email`: write a JSON document containing a contact with email
>   `"nope"` and assert the result is `Err(CrmError::Json(_))` (with `matches!`)
> - [ ] `cargo test storage` runs exactly these tests and they pass

> 🔵 **YOUR TURN 3: loading older files.** Your app's data format will change: Lab 20 added
> activities and notes, and someone may have a file saved before that. Write this test first and
> watch it fail:
>
> - [ ] `load_accepts_a_file_without_newer_sections`: a file containing **only**
>   `{ "companies": { "items": [], "next_id": 1 } }` loads successfully, with empty contacts,
>   deals, leads, activities and notes
>
> Then make it pass with **one serde attribute**, without hand-writing a `Deserialize` impl.
>
> - [ ] Explain in a code comment why the attribute is safe here (what does a missing section
>   become, and why is that a correct value?)
> - [ ] `load_rejects_an_invalid_email` still passes. Leniency about *missing* data must not become
>   leniency about *invalid* data.

## 💡 Hint

> 💡 **HINT** (Your Turn 1): match on `self`. For the nested commands, a second `match` (or
> `matches!`) on the inner enum keeps each arm readable. `Command::History { .. }` matches a struct
> variant regardless of its fields.

> 💡 **HINT** (Your Turn 2): you can `fs::write(&path, r#"{ ... }"#)` to create a test file
> from a raw string literal. `r#"..."#` lets you write `"` inside without escaping.

<details><summary>Hint 2 (more specific)</summary>

- For `temp_file`: `std::env::temp_dir().join(format!("rust-crm-{}-{name}.json", std::process::id()))`.
- To check the tmp file is gone you need `tmp_path`. It's private, but a `mod tests` *inside*
  `storage.rs` is a child module, and child modules can see their parent's private items.
- Clean up **before** asserting (`let result = load(&path); fs::remove_file(&path)...; assert!(...)`).
  Otherwise a failing assert panics and the file is never deleted.
- Your Turn 3: the attribute goes on the `Crm` struct and only works because `Crm: Default`.
  Look up "container attributes" on serde.rs.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Draw the three layers (your type, data model, format). Which layer decides that a
   `CompanyId(3)` is written as `3`? Which one decides the quotes around strings?
2. Why does `#[derive(Deserialize)]` on a type with a private field and a validating constructor
   weaken that type's guarantee? How does `try_from = "String"` restore it?
3. Why can't `Subject` be internally tagged, and why was that a *runtime* error?
4. What bound did the derive infer for `InMemoryRepo<T>`, and when would you need
   `#[serde(bound)]`?
5. Why can't `CrmError` implement `PartialEq` any more? What do you use in tests instead?
6. Walk through a crash at each step of `save`. What's on disk in each case?
7. Why does `save` call `flush()` explicitly when `BufWriter` flushes on drop?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

Delete the scaffolding example first. It did its job.

```bash
rm examples/json_peek.rs
git add .
git commit -m "Persist CRM data to JSON"
git tag lab-21
git push && git push --tags
```

`git status` should **not** list `crm-data.json`. If it does, check your `.gitignore`.

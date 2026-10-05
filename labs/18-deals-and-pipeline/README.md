# Lab 18 — Deals & the Pipeline

> **Phase:** 5 — The Sales Pipeline · **Builds on:** Lab 17 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-17` · **After:** tag `lab-18`

## 🎯 Goal
Give the CRM something to sell. You'll add a `Money` type that can't lose cents, `Deal`s that
move through a sales pipeline under strict rules, and a `pipeline` report that shows how many
deals (and how much money) sit in every stage.

## 🧠 What You'll Learn
- Why money is never `f64`, and what to use instead (integer cents in a newtype)
- Operator overloading with traits: `Add`, `AddAssign`, and `Sum`, including **why you need both
  `Sum<Money>` and `Sum<&'a Money>`**
- Implementing `Display` properly: `Formatter::pad` so `{:>12}` works on your own types
- Modelling a **state machine** with an enum and a transition table (`match` on a tuple)
- How `derive(PartialOrd, Ord)` orders enum variants, and why that makes declaration order load-bearing
- `BTreeMap` vs `HashMap`: sorted vs unordered, and when that difference matters
- The **entry API** mental model: one lookup, one `&mut` to the slot
- Slice patterns (`["move", id, stage]`) for parsing commands
- Inherent `impl` blocks in a different module from the type

## 🔨 What We're Building
Companies and contacts are just a phone book. A CRM exists to track **deals**: "Acme might buy a
website redesign for $12,000, and we're at the proposal stage". After this lab you'll be able to:

```text
crm> deal add
Company id: 1
Title: Website redesign
Value (e.g. 1250.50): 12000
Added deal #1
crm> deal move 1 proposal
Deal #1 moved to proposal
crm> deal move 1 qualification
Error: cannot move a deal from proposal to qualification
crm> pipeline
Stage          Deals          Value
qualification      0          $0.00
proposal           1     $12,000.00
...
```

The stage-transition rules you write today are pure domain logic. They'll carry over unchanged
into the HTTP API (Lab 29) and the PostgreSQL version (Lab 31).

New files by the end:

```text
src/
├── money.rs            ← new: Money
├── deals/
│   ├── mod.rs          ← new
│   ├── model.rs        ← new: DealId, DealStage, Deal
│   └── report.rs       ← new: PipelineRow, Crm::pipeline_report
examples/
└── float_money.rs      ← new: a tiny demo of why floats fail
```

---

## Step 1 — Why money is never a float

You've probably written `price: number` in TypeScript. JavaScript's `number` is an IEEE-754
`f64`, and so is Rust's `f64`. Floats are binary fractions. They can represent `0.5` and `0.25`
exactly, but **not** `0.1`, just as decimal can't write ⅓ exactly. Every money calculation then
carries a tiny error, and those errors compound.

Don't take this on trust. Create a throwaway example program. Cargo builds every file in
`examples/` as a separate little binary that can use your crate. (You may already have one from
Lab 14.)

> 🟡 **EXPERIMENT**: before running it, predict each line of output.

Create `examples/float_money.rs`:

```rust
//! Why money is never a float. Run with: cargo run --example float_money

fn main() {
    // 1. The classic.
    let sum = 0.1 + 0.2;
    println!("0.1 + 0.2        = {sum}");
    println!("0.1 + 0.2 == 0.3 ? {}", sum == 0.3);

    // 2. Ten line items at $0.10 each.
    let mut total = 0.0;
    for _ in 0..10 {
        total += 0.10;
    }
    println!("10 x $0.10       = {total}");
    println!("equals $1.00     ? {}", total == 1.00);

    // 3. Rounding for display hides the error... until it doesn't.
    println!("$1.005 to cents  = {:.2}", 1.005);

    // 4. f32 runs out of digits quickly.
    let big: f32 = 16_777_216.0;
    println!("$16,777,216 + $1 = {}", big + 1.0);
}
```

```bash
cargo run --example float_money
```

```text
0.1 + 0.2        = 0.30000000000000004
0.1 + 0.2 == 0.3 ? false
10 x $0.10       = 0.9999999999999999
equals $1.00     ? false
$1.005 to cents  = 1.00
$16,777,216 + $1 = 16777216
```

Every line is a real bug that has shipped in real billing systems:

1. Equality checks on totals fail. "Is the invoice fully paid?" says no.
2. Summing line items drifts. With thousands of items, the drift reaches whole cents.
3. `1.005` is actually stored as `1.00499999999999989...`, so "round to cents" rounds **down**.
4. `f32` has only 24 bits of precision. Above ~16.7 million, it can't even represent every
   whole dollar. Adding $1 does nothing.

**The fix the whole industry uses:** store money as an **integer number of the smallest unit**
(cents). Integer addition is exact. You only convert to "dollars and cents" when you display it.

> 💡 Real systems also track the currency (`USD`, `EUR`). Our CRM is single-currency on
> purpose: one concept at a time. A multi-currency `Money { cents, currency }` is a good
> exercise once you've finished the course.

## Step 2 — A `Money` newtype

You could write `value: i64` on `Deal` and be done. But then nothing stops this:

```rust
let total = deal.value + contact_count;   // i64 + i64: compiles, means nothing
let value = 1250;                          // dollars? cents? nobody knows
```

A **newtype** (a one-field tuple or struct wrapping a primitive) gives the number a meaning the
compiler checks. You did this for `CompanyId` in Lab 14 and `Email` in Lab 12. Same idea here.

> 🟢 **FOLLOW ALONG**

Create `src/money.rs`:

```rust
//! Money as an integer number of cents.

use crate::errors::ValidationError;

/// An amount of money, stored as a whole number of cents.
///
/// The field is private: the only ways in are `from_cents` and `parse`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Money {
    cents: i64,
}

impl Money {
    pub const ZERO: Money = Money { cents: 0 };

    pub fn from_cents(cents: i64) -> Self {
        Money { cents }
    }

    pub fn cents(&self) -> i64 {
        self.cents
    }
}
```

And register it in `src/lib.rs` (keep your other modules as they are):

```rust
pub mod money;
```

Every choice here is deliberate:

| Choice | Why |
|---|---|
| `i64`, not `u64` | Money can be negative: refunds, discounts, the *difference* between two amounts. `i64` cents still holds ±92 quadrillion dollars. |
| Named field `cents`, **private** | Outside `money.rs`, nobody can write `Money { cents: .. }` or read `.cents` directly. The unit is spelled out at every entry point: `Money::from_cents(1250)` can't be misread as dollars. |
| `Copy` | It's 8 bytes, like an `i64`. Passing it by value is cheaper than passing a reference, and you'll never need to write `.clone()`. |
| `PartialEq, Eq, PartialOrd, Ord` | Compare amounts (`value < Money::ZERO`) and sort deals by value. Integers have a total order, so `Ord` is honest. (`f64` can't be `Ord`, because `NaN` isn't comparable to anything.) |
| `Default` | Gives `Money::default() == $0.00`. You'll see in Step 9 why the entry API loves `Default`. |
| `const ZERO` | An associated constant: a readable name for "no money", usable in `const` contexts. |

## Step 3 — Parsing what users type

Users type `1250`, `1250.5`, `1250.50`, maybe `$1,250.50`. We need to turn that text into cents
**without ever going through a float**. (`"1250.50".parse::<f64>()` then `* 100.0` brings back
every bug from Step 1.)

First, a new error variant. In `src/errors.rs`, add to `ValidationError`:

```rust
    InvalidMoney(String),
```

and its arm in `impl fmt::Display for ValidationError`:

```rust
            ValidationError::InvalidMoney(m) => {
                write!(f, "invalid amount: '{m}' (expected e.g. 1250 or 1250.50)")
            }
```

> 🟢 **FOLLOW ALONG**: add `parse` inside `impl Money`.

```rust
    /// Parses user input such as `1250`, `1250.5`, `1250.50`, `$1,250.50`.
    pub fn parse(input: &str) -> Result<Money, ValidationError> {
        let invalid = || ValidationError::InvalidMoney(input.to_string());

        let trimmed = input.trim();
        let without_symbol = trimmed.strip_prefix('$').unwrap_or(trimmed);
        let digits = without_symbol.replace(',', "");

        let (whole, fraction) = match digits.split_once('.') {
            Some((_, "")) => return Err(invalid()), // "12." is a typo, not a number
            Some((whole, fraction)) => (whole, fraction),
            None => (digits.as_str(), ""),
        };

        let all_digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
        if whole.is_empty() || !all_digits(whole) || !all_digits(fraction) || fraction.len() > 2 {
            return Err(invalid());
        }

        let whole: i64 = whole.parse().map_err(|_| invalid())?;
        let fraction: i64 = match fraction.len() {
            0 => 0,
            1 => fraction.parse::<i64>().map_err(|_| invalid())? * 10, // "1250.5" = 50 cents
            _ => fraction.parse().map_err(|_| invalid())?,
        };

        whole
            .checked_mul(100)
            .and_then(|cents| cents.checked_add(fraction))
            .map(Money::from_cents)
            .ok_or_else(invalid)
    }
```

Walk through it with Lab 17 eyes:

- **`let invalid = || ...`** is a closure that captures `input` by reference. Every failure path
  calls `invalid()` and gets a fresh `ValidationError`. Because it only *reads* what it captured,
  it's `Fn`, so you can call it as many times as you like. `.ok_or_else(invalid)` passes the
  closure itself, which is lazy: it's called only on the error path.
- **`strip_prefix('$').unwrap_or(trimmed)`**: `strip_prefix` returns `Option<&str>`, a borrowed
  slice of `trimmed` with no allocation.
- **`replace(',', "")`** allocates a new `String`, because removing characters from the middle
  can't be a slice of the original. From here on, `whole` and `fraction` are `&str` slices
  **borrowing `digits`**. That's why `digits` is a named local: the slices need an owner that
  outlives them (Lab 10).
- **`match digits.split_once('.')`** is pattern matching on `Option<(&str, &str)>`. Arms are
  tried in order. `Some((_, ""))` matches a string literal *inside* a tuple *inside* an
  `Option`, so it must come before the general `Some((whole, fraction))` arm.
- **Why check digits by hand** when `"-5".parse::<i64>()` would work? Because `parse` accepts a
  leading `+` or `-`. We want `-5` rejected, since a deal can't be worth minus five dollars.
- **`checked_mul` / `checked_add`** return `None` on overflow instead of panicking (debug) or
  silently wrapping (release). Lab 02 promised that overflow would come back. Here it is,
  attached to user input.

Add tests at the bottom of `src/money.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_whole_amounts() {
        assert_eq!(Money::parse("1250"), Ok(Money::from_cents(125_000)));
    }

    #[test]
    fn parses_one_and_two_decimal_places() {
        assert_eq!(Money::parse("1250.5"), Ok(Money::from_cents(125_050)));
        assert_eq!(Money::parse("1250.50"), Ok(Money::from_cents(125_050)));
        assert_eq!(Money::parse("0.07"), Ok(Money::from_cents(7)));
    }

    #[test]
    fn accepts_dollar_sign_commas_and_whitespace() {
        assert_eq!(Money::parse("  $1,250.50 "), Ok(Money::from_cents(125_050)));
    }

    #[test]
    fn rejects_garbage() {
        for bad in ["", "abc", "12.345", "-5", "1.2.3", "12.", ".50", "1e3", "99999999999999999999"] {
            assert_eq!(
                Money::parse(bad),
                Err(ValidationError::InvalidMoney(bad.to_string())),
                "{bad:?} should be rejected"
            );
        }
    }
}
```

```bash
cargo test money
```

All four pass. Note the table-style `rejects_garbage` test: a loop over inputs, with the third
`assert_eq!` argument naming the failing case. You'll use this pattern a lot today.

> 🔵 **Mini-task:** `"1.2.3"` is rejected, but which check rejects it? Trace it by hand:
> what do `whole` and `fraction` hold after `split_once`?

## Step 4 — Displaying money (and the `pad` trap)

We want `Money::from_cents(125_050)` to print as `$1,250.50`.

> 🟢 **FOLLOW ALONG**: add `use std::fmt;` at the top of `money.rs`, then:

```rust
impl fmt::Display for Money {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sign = if self.cents < 0 { "-" } else { "" };
        let abs = self.cents.unsigned_abs(); // u64: works even for i64::MIN
        let dollars = (abs / 100).to_string();
        let cents = abs % 100;

        // Insert a comma before every group of three digits, counting from the right.
        let mut grouped = String::with_capacity(dollars.len() + dollars.len() / 3);
        for (i, digit) in dollars.chars().enumerate() {
            if i > 0 && (dollars.len() - i).is_multiple_of(3) {
                grouped.push(',');
            }
            grouped.push(digit);
        }

        // `pad` (not `write!`) so that `{:>12}` and friends work on Money.
        f.pad(&format!("{sign}${grouped}.{cents:02}"))
    }
}
```

Two details deserve attention:

- **`unsigned_abs()`**, not `abs()`. `i64::MIN.abs()` overflows, because there's one more
  negative `i64` than positive. `unsigned_abs` returns a `u64`, which always fits. An edge case
  that will never happen in a CRM? Probably. The point is that Rust's standard library makes
  the correct version just as easy to write.
- **`{cents:02}`** pads to two digits: 7 cents prints as `07`.

Now the trap. Add these tests to the `tests` module:

```rust
    #[test]
    fn displays_with_thousands_separators() {
        assert_eq!(Money::from_cents(125_050).to_string(), "$1,250.50");
        assert_eq!(Money::from_cents(7).to_string(), "$0.07");
        assert_eq!(Money::from_cents(100_000_000).to_string(), "$1,000,000.00");
        assert_eq!(Money::from_cents(-1999).to_string(), "-$19.99");
    }

    #[test]
    fn display_respects_width() {
        assert_eq!(format!("[{:>10}]", Money::from_cents(500)), "[     $5.00]");
    }
```

> 🟡 **EXPERIMENT**: replace the last line of `fmt` with the "obvious" version:
> ```rust
>         write!(f, "{sign}${grouped}.{cents:02}")
> ```
> Predict which test fails, then run `cargo test money`.

```text
---- money::tests::display_respects_width stdout ----

thread 'money::tests::display_respects_width' panicked at src/money.rs:166:9:
assertion `left == right` failed
  left: "[$5.00]"
 right: "[     $5.00]"
```

**Why?** `{:>10}` doesn't pad anything by itself. It stores "width 10, align right" inside the
`Formatter` and calls your `fmt`. Your `fmt` decides whether to honour it. `write!(f, ...)`
writes straight through and ignores the width. `f.pad(s)` reads the width, fill and alignment
from the formatter and applies them to `s`. The standard library's `impl Display for str` is
essentially `f.pad(self)`.

**Rule of thumb:** if your `Display` produces one piece of text that people might want to
align in a table, build the string and call `f.pad`. You're about to print a pipeline table,
so you need it. Put `f.pad` back.

## Step 5 — Operator traits: `+`, `+=` and `.sum()`

How do you add two `Money` values? Try it first.

> 🟡 **EXPERIMENT**: add this test and run `cargo test money`. Predict the error code.

```rust
    #[test]
    fn adds_money() {
        let a = Money::from_cents(100);
        let b = Money::from_cents(200);
        assert_eq!(a + b, Money::from_cents(300));
    }
```

```text
error[E0369]: cannot add `money::Money` to `money::Money`
  --> src/money.rs:96:22
   |
96 |         assert_eq!(a + b, Money::from_cents(300));
   |                    - ^ - money::Money
   |                    |
   |                    money::Money
   |
note: an implementation of `Add` might be missing for `money::Money`
  --> src/money.rs:11:1
   |
11 | pub struct Money {
   | ^^^^^^^^^^^^^^^^ must implement `Add`
note: the trait `Add` must be implemented
```

**Read the error.** In Rust, `a + b` is *syntax sugar* for `std::ops::Add::add(a, b)`. There's
no magic list of "types that support `+`". Integers support it because the standard library
contains `impl Add for i64`. Your type supports it as soon as you write the impl. Operators are
traits. (This is the same mechanism as `==` → `PartialEq` and `<` → `PartialOrd`, which you've
been deriving since Lab 15.)

Notice the ownership in the signature: `fn add(self, rhs: Self)` takes **both operands by
value**. For a `Copy` type like `Money` that costs nothing, and `a` and `b` stay usable. For a
non-`Copy` type such as `String`, `s1 + &s2` really does *consume* `s1`. You can now read that
signature and understand why.

> 🟢 **FOLLOW ALONG**: add to the top of `money.rs`:

```rust
use std::iter::Sum;
use std::ops::{Add, AddAssign};
```

and below the `Display` impl:

```rust
impl Add for Money {
    type Output = Money;

    fn add(self, rhs: Money) -> Money {
        Money::from_cents(self.cents + rhs.cents)
    }
}

impl AddAssign for Money {
    fn add_assign(&mut self, rhs: Money) {
        self.cents += rhs.cents;
    }
}

impl Sum for Money {
    fn sum<I: Iterator<Item = Money>>(iter: I) -> Money {
        iter.fold(Money::ZERO, |total, m| total + m)
    }
}
```

- **`type Output = Money`**: `Add` has an associated type for the result, because adding two
  things doesn't have to produce the same type. (`Instant + Duration = Instant`.) For money,
  `Money + Money = Money`.
- **`AddAssign`** is a separate trait, so `+=` isn't derived from `+`. It takes `&mut self`
  because it modifies the left side in place.
- **`Sum`** is what `Iterator::sum()` calls. `impl Sum for Money` is short for
  `impl Sum<Money> for Money`: "a `Money` can be made by summing an iterator of `Money`s".
  The body is a `fold` (Lab 17) starting from `ZERO`.

> 💡 **Overflow note.** `self.cents + rhs.cents` panics on overflow in debug builds and wraps in
> release builds. At ±92 quadrillion dollars we accept that. A banking system would add
> `fn checked_add(self, rhs) -> Option<Money>` and use it everywhere. Knowing that the choice
> exists is the important part.

Now add a test that sums both ways:

```rust
    #[test]
    fn add_assign_accumulates() {
        let mut total = Money::ZERO;
        total += Money::from_cents(250);
        total += Money::from_cents(250);
        assert_eq!(total, Money::from_cents(500));
    }

    #[test]
    fn sums_owned_and_borrowed_values() {
        let values = vec![Money::from_cents(100), Money::from_cents(250)];
        let by_ref: Money = values.iter().sum();
        let by_value: Money = values.into_iter().sum();
        assert_eq!(by_ref, Money::from_cents(350));
        assert_eq!(by_value, by_ref);
    }
```

> 🟡 **EXPERIMENT**: run `cargo test money` and read the error *before* fixing anything.

```text
error[E0277]: a value of type `money::Money` cannot be made by summing an iterator over elements of type `&money::Money`
   --> src/money.rs:166:43
    |
166 |         let by_ref: Money = values.iter().sum();
    |                                           ^^^ value of type `money::Money` cannot be made by summing a `std::iter::Iterator<Item=&money::Money>`
    |
help: the trait `Sum<&Money>` is not implemented for `money::Money`
      but trait `Sum<Money>` is implemented for it
   --> src/money.rs:97:1
    |
 97 | impl Sum for Money {
    | ^^^^^^^^^^^^^^^^^^
    = help: for that trait implementation, expected `money::Money`, found `&money::Money`
note: the method call chain might not have had the expected associated types
   --> src/money.rs:166:36
    |
165 |         let values = vec![Money::from_cents(100), Money::from_cents(250)];
    |                      ---------------------------------------------------- this expression has type `Vec<Money>`
166 |         let by_ref: Money = values.iter().sum();
    |                                    ^^^^^^ `Iterator::Item` is `&Money` here
```

This is Lab 17's `iter()` vs `into_iter()` again, now with traits involved:

- `values.into_iter()` **consumes** the `Vec` and yields owned `Money` values.
  `Sum<Money>` handles that.
- `values.iter()` **borrows** the `Vec` and yields `&Money`, references into it. That's a
  *different type*, and traits are implemented per type. `Sum<Money>` says nothing about
  `&Money`.

The compiler's note points at exactly that: "`Iterator::Item` is `&Money` here".

You could make the caller write `values.iter().copied().sum()`. But summing borrowed values is
the *common* case: you'll usually have a `&[Deal]` or a `Vec<&Deal>`, not owned values you're
happy to consume. The standard library implements both `Sum<i64>` and `Sum<&'a i64>` for
`i64` for exactly this reason. Do the same:

> 🟢 **FOLLOW ALONG**

```rust
impl<'a> Sum<&'a Money> for Money {
    fn sum<I: Iterator<Item = &'a Money>>(iter: I) -> Money {
        iter.copied().sum()
    }
}
```

**Read the signature slowly.** `impl<'a> Sum<&'a Money> for Money`: "for *any* lifetime `'a`,
a `Money` can be made by summing references to `Money` that live for `'a`". The lifetime has
to be named because it appears in a type parameter (`Sum<&'a Money>`), and elision only works
in function signatures (Lab 10). The body re-uses the first impl: `.copied()` turns each
`&Money` into a `Money` (allowed because `Money: Copy`) and then calls `Sum<Money>`.

```bash
cargo test money
```

Nine tests pass.

### Commit the Money type

This is a natural checkpoint: `Money` is complete, tested and used by nothing yet.

```bash
cargo fmt && cargo clippy && cargo test
git add .
git commit -m "Add Money type"
```

## Step 6 — `DealStage`: a state machine as an enum

A deal moves through stages:

```text
Qualification ──▶ Proposal ──▶ Negotiation
      │               │              │
      └───────────────┴──────────────┴──▶ Won | Lost   (final)
```

The business rules:

1. Open stages move **forward one step at a time**: Qualification → Proposal → Negotiation.
2. **Any open stage** can close as **Won** or **Lost** (deals do get signed at the first meeting).
3. **Closed stages are final.** A lost deal that comes back is a *new* deal.
4. **No backwards moves**, and no skipping (Qualification → Negotiation is not allowed).

In TypeScript you might write `stage: string` and scatter `if (stage === "won")` checks around.
In Rust the stage is an enum, so a typo is a compile error. The **rules** live in one function
that answers a single question: *can I go from here to there?*

> 🟢 **FOLLOW ALONG**: create `src/deals/model.rs`.

```rust
use std::fmt;
use std::str::FromStr;

use crate::companies::CompanyId;
use crate::entity::Entity;
use crate::errors::{CrmError, ValidationError};
use crate::money::Money;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DealId(pub u64);

impl From<u64> for DealId {
    fn from(id: u64) -> Self {
        DealId(id)
    }
}

impl fmt::Display for DealId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// Where a deal is in the sales process. The declaration order IS the
/// pipeline order: `derive(PartialOrd, Ord)` compares variants by position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum DealStage {
    Qualification,
    Proposal,
    Negotiation,
    Won,
    Lost,
}

impl DealStage {
    /// Every stage, in pipeline order.
    pub const ALL: [DealStage; 5] = [
        DealStage::Qualification,
        DealStage::Proposal,
        DealStage::Negotiation,
        DealStage::Won,
        DealStage::Lost,
    ];

    pub fn is_closed(self) -> bool {
        matches!(self, DealStage::Won | DealStage::Lost)
    }

    /// The transition table. Anything not listed is forbidden.
    pub fn can_transition_to(self, next: DealStage) -> bool {
        use DealStage::*;
        match (self, next) {
            // forward, one step at a time
            (Qualification, Proposal) | (Proposal, Negotiation) => true,
            // any open stage can be closed, either way
            (Qualification | Proposal | Negotiation, Won | Lost) => true,
            // backwards, skipping, staying put, re-opening a closed deal
            _ => false,
        }
    }
}
```

`DealId` is a copy of your `CompanyId`: same derives, `From<u64>` so `InMemoryRepo` can mint
ids (Lab 16), and `Display` as `#3` (Lab 15).

Now the interesting part.

**`match (self, next)`: a transition table as a pattern.** Building the tuple `(self, next)`
lets one `match` look at *both* stages at once. Each arm is a row of the table:

- `(Qualification, Proposal) | (Proposal, Negotiation)`: two specific transitions, joined with `|`.
- `(Qualification | Proposal | Negotiation, Won | Lost)`: **or-patterns nested inside the tuple**.
  That single arm covers 3 × 2 = 6 transitions.
- `_ => false`: everything else. The rules say "anything not explicitly allowed is forbidden",
  so a deny-by-default wildcard is the honest encoding.

`use DealStage::*;` inside the function lets you write `Proposal` instead of
`DealStage::Proposal`. It's scoped to the function body, so it can't leak into the rest of the
module.

**Why `self` and not `&self`?** `DealStage` is `Copy` and one byte in size. Taking it by value
is free, and callers can write `stage.can_transition_to(next)` without thinking about borrows.
For small `Copy` types, `self` is idiomatic (clippy's pedantic lint `trivially_copy_pass_by_ref`
exists to suggest exactly this).

**Why derive `PartialOrd, Ord`?** For enums, the derived ordering is **declaration order**:
`Qualification < Proposal < … < Lost`. You'll use that in Step 9 to get the pipeline report in
the right order for free. That makes the order of the variants in the source code
*load-bearing*. You'll see that matter in the 🧪 Experiment section.

**Why `const ALL`?** Rust has no built-in "iterate all variants of an enum" (crates like
`strum` add one). A const array is the simple, dependency-free way to do it.

Now `Display` and `FromStr`, as you did for `Lifecycle` in Lab 15. First, a reusable error
variant. Add to `ValidationError` in `src/errors.rs`:

```rust
    InvalidValue { field: &'static str, value: String },
```

```rust
            ValidationError::InvalidValue { field, value } => {
                write!(f, "invalid {field}: '{value}'")
            }
```

You'll reuse this variant for every "not one of the allowed words" error: deal stages today,
lead sources and subjects in the next two labs.

Back in `src/deals/model.rs`:

```rust
impl fmt::Display for DealStage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            DealStage::Qualification => "qualification",
            DealStage::Proposal => "proposal",
            DealStage::Negotiation => "negotiation",
            DealStage::Won => "won",
            DealStage::Lost => "lost",
        };
        f.pad(label)
    }
}

impl FromStr for DealStage {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_lowercase().as_str() {
            "qualification" => Ok(DealStage::Qualification),
            "proposal" => Ok(DealStage::Proposal),
            "negotiation" => Ok(DealStage::Negotiation),
            "won" => Ok(DealStage::Won),
            "lost" => Ok(DealStage::Lost),
            _ => Err(ValidationError::InvalidValue {
                field: "deal stage",
                value: s.to_string(),
            }),
        }
    }
}
```

`f.pad(label)` again: you'll print stages in a column with `{:<14}`, so it has to honour the width.

## Step 7 — `Deal` and its one mutating method

Add the struct and its methods to `src/deals/model.rs`:

> 🟢 **FOLLOW ALONG**

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct Deal {
    pub id: DealId,
    pub company_id: CompanyId,
    pub title: String,
    pub value: Money,
    pub stage: DealStage,
}

impl Deal {
    /// Moves the deal to `next`, if the transition table allows it.
    pub fn move_to(&mut self, next: DealStage) -> Result<(), CrmError> {
        if !self.stage.can_transition_to(next) {
            return Err(CrmError::InvalidTransition {
                from: self.stage,
                to: next,
            });
        }
        self.stage = next;
        Ok(())
    }
}

impl Entity for Deal {
    type Id = DealId;

    fn id(&self) -> DealId {
        self.id
    }

    fn label(&self) -> String {
        format!("Deal {} {}", self.id, self.title)
    }
}

impl fmt::Display for Deal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:<5} {:<24} {:>12}  {:<14} company {}",
            self.id.to_string(),
            self.title,
            self.value,
            self.stage,
            self.company_id
        )
    }
}
```

The new error goes in `src/errors.rs`. `CrmError` gains a variant with **named fields**:

```rust
use crate::deals::DealStage;

// in enum CrmError:
    InvalidTransition { from: DealStage, to: DealStage },

// in impl Display for CrmError:
            CrmError::InvalidTransition { from, to } => {
                write!(f, "cannot move a deal from {from} to {to}")
            }
```

> 💡 `errors.rs` now imports from `deals`, and `deals` imports from `errors`. Modules inside one
> crate can refer to each other in a cycle. The crate is compiled as one unit. (Crates can't
> depend on each other cyclically, but modules can.)

**Why does the stage change go through a method?** `stage` is a `pub` field, so code *could*
write `deal.stage = DealStage::Won` directly and skip the rules. We keep fields public in this
course for readability, and rely on a convention: **all business mutations go through domain
methods** (`move_to`), and the CLI only calls `Crm` methods (Lab 14's rule). In Lab 31 the
database enforces it (`UPDATE ... WHERE stage = $old`). A stricter design would make `stage`
private and expose `fn stage(&self) -> DealStage`, the same way `Email` hides its `String`.
That trade-off is up to you, but be able to explain it.

**Validate before mutating.** `move_to` checks first and assigns second, so a rejected move leaves
the deal **unchanged**. That sounds obvious. It's also the property that makes the method
safe to call from anywhere, and you'll write a test for it in Your Turn 2.

Wire up the module. Create `src/deals/mod.rs`:

```rust
mod model;
mod report;

pub use model::{Deal, DealId, DealStage};
pub use report::PipelineRow;
```

Add `pub mod deals;` to `src/lib.rs`, and create `src/deals/report.rs` with just a placeholder
for now so the module compiles:

```rust
pub struct PipelineRow;
```

(You'll replace that in Step 9.) Then add your first deal tests at the bottom of `model.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn deal(stage: DealStage) -> Deal {
        Deal {
            id: DealId(1),
            company_id: CompanyId(1),
            title: "Website redesign".to_string(),
            value: Money::from_cents(1_200_000),
            stage,
        }
    }

    #[test]
    fn deal_moves_forward_one_step() {
        let mut d = deal(DealStage::Qualification);
        assert!(d.move_to(DealStage::Proposal).is_ok());
        assert_eq!(d.stage, DealStage::Proposal);
    }

    #[test]
    fn stages_round_trip_through_strings() {
        for stage in DealStage::ALL {
            assert_eq!(stage.to_string().parse::<DealStage>(), Ok(stage));
        }
        assert!("closed".parse::<DealStage>().is_err());
    }
}
```

`stages_round_trip_through_strings` is a **round-trip test**: `parse(display(x)) == x` for every
value. It catches the classic bug of adding a variant to `Display` but forgetting `FromStr`.
It's also why `ALL` is useful.

```bash
cargo test deals
```

## Step 8 — Deals in the `Crm`

Lab 16's promise was that "adding a new entity costs a struct and a trait impl". Here it is.

> 🟢 **FOLLOW ALONG**: in `src/crm.rs`, add the field (`#[derive(Default)]` on `Crm` keeps
> working, because `InMemoryRepo<T>` implements `Default`):

```rust
use crate::deals::{Deal, DealId, DealStage};
use crate::money::Money;

pub struct Crm {
    pub companies: InMemoryRepo<Company>,
    pub contacts: InMemoryRepo<Contact>,
    pub deals: InMemoryRepo<Deal>,
}
```

(If you wrote `Crm::new()` / `impl Default for Crm` by hand instead of deriving, add
`deals: InMemoryRepo::new()` there.)

Then the methods, inside `impl Crm`:

```rust
    pub fn add_deal(
        &mut self,
        company_id: CompanyId,
        title: String,
        value: Money,
    ) -> Result<DealId, CrmError> {
        if self.companies.get(company_id).is_none() {
            return Err(CrmError::NotFound {
                entity: "company",
                id: company_id.0,
            });
        }
        let deal = Deal {
            id: self.deals.next_id(),
            company_id,
            title,
            value,
            stage: DealStage::Qualification,
        };
        // Your Turn 1 adds validation here.
        Ok(self.deals.insert(deal))
    }

    pub fn deal(&self, id: DealId) -> Result<&Deal, CrmError> {
        self.deals.get(id).ok_or(CrmError::NotFound {
            entity: "deal",
            id: id.0,
        })
    }

    pub fn move_deal(&mut self, id: DealId, stage: DealStage) -> Result<(), CrmError> {
        let deal = self.deals.get_mut(id).ok_or(CrmError::NotFound {
            entity: "deal",
            id: id.0,
        })?;
        deal.move_to(stage)
    }
```

Things to notice:

- **New deals always start in `Qualification`.** The caller can't choose the stage, because
  `add_deal` has no `stage` parameter. The only way to reach `Won` is through `move_to`, one
  legal step at a time. *The API shape enforces the rule.*
- **`add_deal` checks the company first, then mints an id.** Do it the other way round and
  every failed attempt burns an id. (Harmless, but untidy. In Lab 19 you'll meet a case where
  burning ids is unavoidable.)
- **`move_deal` is find-then-mutate (Lab 08).** `get_mut` returns `Option<&mut Deal>`.
  `ok_or(...)?` turns `None` into an early `Err` return. After that line, `deal: &mut Deal`
  is a mutable borrow *of `self.deals`*, and `deal.move_to(stage)` is the last use of it.
  Its `Result` *is* our return value.
- **`deal()`** is a small lookup helper returning `Result<&Deal, CrmError>`. The returned
  reference borrows from `&self` (elision rule 3 from Lab 10: methods with `&self` give their
  output `self`'s lifetime).

## Step 9 — The pipeline report: `BTreeMap` and the entry API

The report has one row per stage: how many deals, and their total value.

The tempting design: "for each stage, filter the deals and sum them". That's 5 passes over all
deals, and the number of passes grows with every stage you add. The better design is a single
pass that drops each deal into its stage's bucket. That's a **group-by**, and in Rust a group-by
means a map from *key* to *accumulator*.

**Which map?**

| | `HashMap<K, V>` | `BTreeMap<K, V>` |
|---|---|---|
| Key must be | `Eq + Hash` | `Ord` |
| Lookup | O(1) average | O(log n) |
| Iteration order | **Unspecified** (and randomised per process) | **Sorted by key** |
| Use when | You only look things up | You need ordered output, ranges, or deterministic output |

A report is *displayed*, in pipeline order. `DealStage: Ord` sorts in declaration order. With a
`BTreeMap`, the right order comes for free. With 5 keys, O(log n) vs O(1) is irrelevant.

> 🟢 **FOLLOW ALONG**: replace the placeholder in `src/deals/report.rs`.

```rust
use std::collections::BTreeMap;

use super::DealStage;
use crate::crm::Crm;
use crate::money::Money;

/// One line of the pipeline report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PipelineRow {
    pub stage: DealStage,
    pub count: usize,
    pub total: Money,
}

impl Crm {
    /// Number of deals and their total value per stage, in pipeline order.
    /// Every stage appears, even when it has no deals.
    pub fn pipeline_report(&self) -> Vec<PipelineRow> {
        let mut by_stage: BTreeMap<DealStage, (usize, Money)> = DealStage::ALL
            .iter()
            .map(|&stage| (stage, (0, Money::ZERO)))
            .collect();

        for deal in self.deals.iter() {
            let (count, total) = by_stage.entry(deal.stage).or_default();
            *count += 1;
            *total += deal.value;
        }

        by_stage
            .into_iter()
            .map(|(stage, (count, total))| PipelineRow { stage, count, total })
            .collect()
    }
}
```

**`impl Crm` in `deals/report.rs`?** Yes. Inherent `impl` blocks for a type can live in *any*
module of the same crate (Lab 16 did the same with `impl InMemoryRepo<Contact>`). The report
logic belongs with the deals, so it lives there. `Crm` is unaware of where its methods are
defined.

**Line by line:**

1. **Seeding.** `DealStage::ALL.iter().map(|&stage| (stage, (0, Money::ZERO))).collect()`
   builds a `BTreeMap` from an iterator of `(key, value)` tuples, the same `collect` you used in
   Lab 17 with a different target type. `|&stage|` is a pattern in the closure parameter: the
   iterator yields `&DealStage`, and `&stage` destructures the reference, so `stage` is a
   `DealStage` (allowed because it's `Copy`). Seeding is why "every stage appears, even when
   empty".
2. **The entry API.** `by_stage.entry(deal.stage)` looks the key up **once** and returns an
   `Entry`, an enum that is either `Occupied` (key present) or `Vacant` (key absent, with the
   slot already located). `.or_default()` says "if vacant, insert `V::default()`", and in both
   cases returns **`&mut V`**: a mutable reference to the value *inside the map*.
3. **Destructuring through `&mut`.** `let (count, total) = <&mut (usize, Money)>` binds `count:
   &mut usize` and `total: &mut Money` (Rust's "default binding modes" push the `&mut` down into
   the fields). Then `*count += 1` and `*total += deal.value` modify the map in place. That
   `+=` is the `AddAssign` you wrote in Step 5.
4. **`into_iter()` on the map** consumes it and yields `(key, value)` pairs **in key order**.
   Each pair becomes a `PipelineRow`.

### The entry API mental model

Without `entry`, "insert if missing, then update" looks like this:

```rust
if !map.contains_key(&k) {          // lookup #1
    map.insert(k, V::default());    // lookup #2
}
let v = map.get_mut(&k).unwrap();   // lookup #3 (and an unwrap that "can't fail")
```

Three lookups and an `unwrap` that relies on your reasoning being right. `entry` does it with
one lookup and no `unwrap`, and the `&mut V` it hands back is **checked by the borrow
checker**: while you hold it, nobody else can touch the map. Think of `entry` as "give me
exclusive access to the slot for this key, creating it if necessary".

Here, because we seeded every stage, the entry is always `Occupied`. So why not
`by_stage.get_mut(&deal.stage).unwrap()`? Because that `unwrap` would encode an assumption
("every stage was seeded") that someone might break later (see the 🧪 Experiment). `entry().
or_default()` is correct either way. That's where `Money: Default` pays off: `(usize, Money)`
is `Default` because both halves are.

> 🔵 **Mini-task:** You may have used `*counts.entry(x).or_insert(0) += 1` in Lab 17's `stats`.
> What's the difference between `or_insert(v)`, `or_insert_with(|| v)` and `or_default()`?
> When would `or_insert_with` matter? (Answer in [solutions.md](solutions.md#mini-task-answers).)

Add tests at the bottom of `report.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::companies::CompanyId;
    use crate::errors::CrmError;

    fn crm_with_deals() -> Crm {
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".to_string(), None).unwrap();
        let a = crm.add_deal(acme, "A".to_string(), Money::from_cents(1_000)).unwrap();
        crm.add_deal(acme, "B".to_string(), Money::from_cents(2_500)).unwrap();
        let c = crm.add_deal(acme, "C".to_string(), Money::from_cents(400)).unwrap();
        crm.move_deal(a, DealStage::Proposal).unwrap();
        crm.move_deal(c, DealStage::Won).unwrap();
        crm
    }

    #[test]
    fn pipeline_report_lists_every_stage_in_order() {
        let crm = crm_with_deals();
        let stages: Vec<DealStage> = crm.pipeline_report().iter().map(|r| r.stage).collect();
        assert_eq!(stages, DealStage::ALL);
    }

    #[test]
    fn pipeline_report_counts_and_sums_per_stage() {
        let report = crm_with_deals().pipeline_report();
        assert_eq!(
            report[0],
            PipelineRow { stage: DealStage::Qualification, count: 1, total: Money::from_cents(2_500) }
        );
        assert_eq!(report[1].count, 1);
        assert_eq!(report[2].total, Money::ZERO);
        assert_eq!(report[3].total, Money::from_cents(400));
    }

    #[test]
    fn deal_for_unknown_company_is_rejected() {
        let mut crm = Crm::new();
        let result = crm.add_deal(CompanyId(42), "X".to_string(), Money::ZERO);
        assert!(matches!(result, Err(CrmError::NotFound { entity: "company", id: 42 })));
    }
}
```

> 💡 `matches!` instead of `assert_eq!` on `CrmError`: it checks the *shape* of the error
> without needing `CrmError: PartialEq`. That will matter in Lab 21, when `CrmError` gains a
> variant that wraps `std::io::Error`, which isn't `PartialEq`.

## Step 10 — Commands: `deal …` and `pipeline`

The CLI only parses, prompts and prints. Every decision lives in `Crm` and `Deal` (Lab 14's
rule). The snippets below slot into the Lab 14 parser and handlers as you extended them in
Labs 15–17.

> 🟢 **FOLLOW ALONG**: in `src/cli/parser.rs`, add two variants to `Command` and a new enum:

```rust
use crate::deals::{DealId, DealStage};

pub(crate) enum Command<'a> {
    // ...existing variants...
    Deal(DealCommand),
    Pipeline,
}

#[derive(Debug, PartialEq)]
pub(crate) enum DealCommand {
    Add,
    List,
    Show { id: DealId },
    Move { id: DealId, stage: DealStage },
}
```

Add the dispatch arms to the slice match in `parse_command`, next to the `company` and
`contact` arms:

```rust
        ["deal", rest @ ..] => Command::Deal(parse_deal(rest)?),
        ["pipeline", ..] => Command::Pipeline,
```

`rest @ ..` binds everything after `deal` (possibly nothing) as a `&[&str]`. Then the
sub-parser. Your `parse_company` matches on a `(sub, args)` pair; this one matches the **whole
slice** in one pattern, which fits commands with a fixed shape well:

```rust
fn parse_deal(args: &[&str]) -> Result<DealCommand, CrmError> {
    const USAGE: &str = "deal add|list|show <id>|move <id> <stage>";
    const SHOW_USAGE: &str = "deal show <id>";
    const MOVE_USAGE: &str = "deal move <id> <qualification|proposal|negotiation|won|lost>";

    match args {
        ["add"] => Ok(DealCommand::Add),
        ["list"] => Ok(DealCommand::List),
        ["show", id] => {
            let id = id.parse().map_err(|_| CrmError::Usage(SHOW_USAGE))?;
            Ok(DealCommand::Show { id: DealId(id) })
        }
        ["move", id, stage] => {
            let id = id.parse().map_err(|_| CrmError::Usage(MOVE_USAGE))?;
            let stage: DealStage = stage.parse()?;
            Ok(DealCommand::Move { id: DealId(id), stage })
        }
        ["show", ..] => Err(CrmError::Usage(SHOW_USAGE)),
        ["move", ..] => Err(CrmError::Usage(MOVE_USAGE)),
        _ => Err(CrmError::Usage(USAGE)),
    }
}
```

**Slice patterns:** `["move", id, stage]` matches a slice of **exactly three** elements whose
first element equals `"move"`, and binds the other two (`id: &&str`, `stage: &&str`; method calls
auto-deref through both `&`s). `["show", ..]` matches `"show"` followed by *anything*, here used
for the "wrong number of arguments" usage message. Arms are tried in order, so the exact shapes
go first. Compare that with `args.get(1).and_then(...)` chains: the slice pattern shows the
whole command at a glance. (A bare `deal` reaches `parse_deal` with an empty slice and falls
through to the `USAGE` arm.)

`stage.parse()?` uses `FromStr for DealStage`. Its `ValidationError` converts into `CrmError`
through the `From` impl from Lab 12, so a typo like `deal move 3 closed` reports
`invalid deal stage: 'closed'`, which is more useful than a generic usage line.

(The ids are parsed by hand here so each command can report its own usage line. Your Lab 15
generic `parse_id` would work too, once `DealId` has its `From<u64>`, with its generic message.)

Add parser tests to the existing `tests` module in `parser.rs`:

```rust
    #[test]
    fn parses_deal_move() {
        assert_eq!(
            parse_command("deal move 3 won").unwrap(),
            Some(Command::Deal(DealCommand::Move { id: DealId(3), stage: DealStage::Won }))
        );
    }

    #[test]
    fn deal_move_with_unknown_stage_is_a_validation_error() {
        assert!(matches!(parse_command("deal move 3 closed"), Err(CrmError::Validation(_))));
    }
```

> 🟢 **FOLLOW ALONG**: in `src/cli/commands.rs`, route the new commands in `execute`:

```rust
        Command::Deal(cmd) => deal(crm, cmd)?,
        Command::Pipeline => print_pipeline(crm),
```

and add the handlers (`prompt` is already imported from `super`):

```rust
use crate::money::Money;
// plus DealCommand in your `use super::parser::{...}` line

fn deal(crm: &mut Crm, cmd: DealCommand) -> Result<(), CrmError> {
    match cmd {
        DealCommand::Add => {
            let company_id = prompt("Company id: ")
                .parse()
                .map_err(|_| CrmError::Usage("company id must be a number"))?;
            let title = prompt("Title: ");
            let value = Money::parse(&prompt("Value (e.g. 1250.50): "))?;
            let id = crm.add_deal(CompanyId(company_id), title, value)?;
            println!("Added deal {id}");
        }
        DealCommand::List => {
            if crm.deals.is_empty() {
                println!("No deals yet.");
            }
            for deal in crm.deals.iter() {
                println!("{deal}");
            }
        }
        DealCommand::Show { id } => {
            let deal = crm.deal(id)?;
            let company = crm.company(deal.company_id)?;
            println!("Deal {}: {}", deal.id, deal.title);
            println!("  Company: {} {}", company.id, company.name);
            println!("  Value:   {}", deal.value);
            println!("  Stage:   {}", deal.stage);
        }
        DealCommand::Move { id, stage } => {
            crm.move_deal(id, stage)?;
            println!("Deal {id} moved to {stage}");
        }
    }
    Ok(())
}

fn print_pipeline(crm: &Crm) {
    println!("{:<14} {:>5} {:>14}", "Stage", "Deals", "Value");
    for row in crm.pipeline_report() {
        println!("{:<14} {:>5} {:>14}", row.stage, row.count, row.total);
    }
}
```

`crm.company(id)` is Lab 14's lookup helper returning `Result<&Company, CrmError>`; `Crm::deal`
has the same shape.

`{:>14}` on `row.total` works **only because** `Display for Money` uses `f.pad`. Step 4 was for
this line.

Finally, add a `Deals:` block to `print_help`, just before `Other:`:

```rust
    println!("Deals:");
    println!("  deal add | list | show <id> | move <id> <stage>");
    println!("  pipeline                    deals and value per stage");
```

---

## ▶️ Run It

```bash
cargo run
```

Then type this session (blank lines are where you just press Enter):

```text
company add
Acme Corp
acme.example
company add
Globex

deal add
1
Website redesign
12000
deal add
2
Support contract
4,500.5
deal add
1
Mobile app
8250.50
deal add
9
Ghost deal
100
deal add
1
Free lunch
12.345
deal list
deal move 1 proposal
deal move 3 won
deal move 3 negotiation
deal move 2 closed
deal show 1
pipeline
quit
```

## ✅ Expected Result

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> Name: Website (optional): Added company #1
crm> Name: Website (optional): Added company #2
crm> Company id: Title: Value (e.g. 1250.50): Added deal #1
crm> Company id: Title: Value (e.g. 1250.50): Added deal #2
crm> Company id: Title: Value (e.g. 1250.50): Added deal #3
crm> Company id: Title: Value (e.g. 1250.50): Error: no company with id 9
crm> Company id: Title: Value (e.g. 1250.50): Error: invalid amount: '12.345' (expected e.g. 1250 or 1250.50)
crm> #1    Website redesign           $12,000.00  qualification  company #1
#2    Support contract            $4,500.50  qualification  company #2
#3    Mobile app                  $8,250.50  qualification  company #1
crm> Deal #1 moved to proposal
crm> Deal #3 moved to won
crm> Error: cannot move a deal from won to negotiation
crm> Error: invalid deal stage: 'closed'
crm> Deal #1: Website redesign
  Company: #1 Acme Corp
  Value:   $12,000.00
  Stage:   proposal
crm> Stage          Deals          Value
qualification      1      $4,500.50
proposal           1     $12,000.00
negotiation        0          $0.00
won                1      $8,250.50
lost               0          $0.00
crm> Goodbye! (14 commands this session)
```

(When you pipe input in, the prompts and the output end up on one line, as above. Typed
interactively, each answer appears after its prompt. Exact column widths and the wording of
company/contact lines depend on your Lab 15 `Display` impls.)

Check the important parts:

- `4,500.5` became `$4,500.50`: commas accepted, one decimal place meant 50 cents.
- `12.345` was rejected **before** a deal was created: `Money::parse` failed at the boundary.
- `deal move 3 negotiation` after `won` was refused, and deal #3 is still `won` in the report.
- `negotiation` and `lost` appear with zero deals, in pipeline order.

## 🧠 Understand It

**Three layers, three jobs.** Look at what happened to `deal move 3 negotiation`:

1. `parse_deal` turned text into `DealCommand::Move { id: DealId(3), stage: Negotiation }`.
   *Syntax* errors (`closed`) stop here.
2. `Crm::move_deal` found the deal. *Existence* errors (`deal move 99 won`) stop here.
3. `Deal::move_to` asked `DealStage::can_transition_to`. *Business-rule* errors stop here.

Each layer only knows its own job. The transition table is a pure function of two `Copy` enums:
no `Crm`, no I/O, no `&mut`. That's why it's trivially testable, and why it survives the move to
an HTTP API and a database untouched.

**Operators are traits, so they follow the ownership rules.** `Add::add(self, rhs)` takes both
sides by value. `AddAssign::add_assign(&mut self, rhs)` mutates the left side in place.
`Sum<A>` is implemented separately for each item type `A`, which is why `Sum<Money>` (for
`into_iter()`) and `Sum<&'a Money>` (for `iter()`) are two impls. Nothing in Rust's operator
system works outside the trait system, so everything you've learned about traits applies.

**Newtypes cost nothing and prevent a lot.** At runtime a `Money` is exactly an `i64`, with the
same size and the same machine instructions. At compile time it's a different type: you can't
add it to a contact count, pass it where a `CompanyId` is expected, or build one without saying
"cents". The private field means `Money::parse` is the only way user text gets in, so every
`Money` in the system came through validation or through an explicit `from_cents`.

**The derive list is a design document.** `DealStage` derives `Copy` (it's a tag; pass it
around freely), `Eq + Hash` (usable as a `HashMap` key), `Ord` (usable as a `BTreeMap` key, in
pipeline order). `Deal` derives `Clone` but **not** `Copy` (it owns a `String`) and not `Eq`
(no need, so far). Every derive is a promise to future readers about how a type may be used.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: `HashMap` instead of `BTreeMap`.** In `report.rs`, change both
> `BTreeMap`s to `HashMap` (`use std::collections::HashMap;`). It compiles, because
> `DealStage: Hash + Eq`. Predict the output, then run the CRM twice with one deal and type
> `pipeline` each time.

Two real runs:

```text
Stage          Deals          Value
proposal           0          $0.00
lost               0          $0.00
qualification      1        $100.00
negotiation        0          $0.00
won                0          $0.00
```

```text
Stage          Deals          Value
negotiation        0          $0.00
lost               0          $0.00
proposal           0          $0.00
qualification      1        $100.00
won                0          $0.00
```

Your order will differ again. Rust's `HashMap` seeds its hasher randomly **per process**
(protection against hash-flooding attacks), so the iteration order changes from run to run.
`cargo test` also fails: `pipeline_report_lists_every_stage_in_order` catches it. **Question:**
if you *had* to use a `HashMap` here, how would you restore the order? (Two answers: sort the
`Vec<PipelineRow>` by stage afterwards, or iterate `DealStage::ALL` and look each stage up.)
Change it back.

> 🟡 **EXPERIMENT 2: declaration order is load-bearing.** In `DealStage`, swap `Won` and `Lost`
> (so `Lost` is declared first). Nothing else. Predict: does it compile? Do the tests pass?

It compiles. Two tests fail:

```text
---- deals::report::tests::pipeline_report_lists_every_stage_in_order stdout ----
assertion `left == right` failed
  left: [Qualification, Proposal, Negotiation, Lost, Won]
 right: [Qualification, Proposal, Negotiation, Won, Lost]
```

`derive(Ord)` silently changed meaning, and the `BTreeMap` followed it. Only a test noticed.
**Question:** is this a reason not to rely on derived `Ord`? (A reasonable answer: it's fine,
*as long as* the doc comment says so, which ours does, and a test pins the order down, which
ours does.) Swap it back.

> 🟡 **EXPERIMENT 3: what does the compiler catch when the state machine grows?** Add a new
> first variant `Discovery,` to `DealStage`. Before running `cargo check`, list every place
> you think *should* change. Then compare with what the compiler reports.

```text
error[E0004]: non-exhaustive patterns: `&DealStage::Discovery` not covered
  --> src/deals/model.rs:66:27
   |
66 |         let label = match self {
   |                           ^^^^ pattern `&DealStage::Discovery` not covered
```

Only `Display` is reported. Which places should have changed but were **not** reported?

- `can_transition_to`: the `_ => false` wildcard absorbed `Discovery`. A new stage that can
  never be entered or left, and no error.
- `const ALL: [DealStage; 5]` still lists five stages. The pipeline report would silently skip
  `Discovery` deals in the seeding step, though the entry API would still add them, at the
  start of the map.
- `FromStr` matches on *strings*, so it has nothing to be exhaustive about.

This is the **wildcard trade-off**. `_` is convenient and correct for "deny by default", but it
switches off exhaustiveness checking for that `match`. The alternative is to list all 25 pairs
explicitly (or match `(Won | Lost, _)` and `(_, Qualification)` explicitly so that only
"genuinely forbidden" combinations reach `_`). This lab keeps `_` and relies on the
**exhaustive table test you write in Your Turn 2**. Tests and types guard different things.
Remove `Discovery`.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `Validate` for `Deal`.**
> Implement the `Validate` trait (Lab 15) for `Deal`, and call it from `Crm::add_deal` before
> inserting (where the `// Your Turn 1` comment is).
>
> Rules:
> - The title must not be blank (whitespace-only counts as blank) →
>   `ValidationError::EmptyTitle`, a **new variant** you add, displayed as `title must not be empty`.
> - The value must not be negative → `ValidationError::InvalidMoney(<the value as displayed>)`,
>   e.g. `InvalidMoney("-$0.01".to_string())`.

- [ ] `impl Validate for Deal` lives in `src/deals/model.rs`
- [ ] `deal add` with a blank title prints `Error: title must not be empty` and creates no deal
- [ ] `add_deal` doesn't burn a deal id when validation fails (the next successful deal gets the
      next number). Hint: think about *when* `next_id()` is called.
- [ ] A unit test covers both rules
- [ ] `cargo test` passes

> 🔵 **YOUR TURN 2: test every transition rule.**
> Write tests in `src/deals/model.rs` that pin down the state machine completely:
> - **One** table-driven test that checks `can_transition_to` for **all 25** `(from, to)` pairs
>   against the rules in Step 6. It must fail if *any* single pair changes. Its failure message
>   must name the pair (e.g. `negotiation -> proposal`).
> - A test that exactly `Won` and `Lost` are closed.
> - A test that a **rejected** `move_to` returns `InvalidTransition { from, to }` with the right
>   stages *and leaves the deal's stage unchanged*.

- [ ] Writing the expected values doesn't involve calling `can_transition_to` (otherwise the
      test checks the function against itself)
- [ ] Temporarily change one arm of `can_transition_to` (e.g. allow `(Won, Lost)`), check that
      your table test fails with a readable message, then revert
- [ ] `cargo test deals` passes

> 🔵 **YOUR TURN 3: pipeline totals.**
> Under the table, `pipeline` should print a blank line and two summary lines:
>
> ```text
> Open: 2 deals worth $16,500.50
> Won:  $8,250.50
> ```
>
> Requirements:
> - Add `pub fn open_total(rows: &[PipelineRow]) -> (usize, Money)` in `src/deals/report.rs`
>   (re-export it from `deals/mod.rs`). It returns the number and total value of deals in
>   **open** stages, computed from the rows (don't walk the deals again).
> - Use iterator adapters, not a `for` loop with mutable counters.
> - `1 deal` vs `2 deals`: get the plural right.
> - The CLI computes the report **once** and passes it to both the table and the totals.

- [ ] A unit test for `open_total` that includes a `Won` deal (which must not be counted)
- [ ] `pipeline` with no deals prints `Open: 0 deals worth $0.00`
- [ ] `cargo clippy` is clean

## 💡 Hint

> 💡 **HINT (Your Turn 1):** look at `Validate for Company` from Lab 15. For the id: the
> `Deal` value needs an id *before* you can validate it... or does it? Could you validate
> with a placeholder id, or validate the inputs instead of the struct?

<details><summary>Hint 2 (more specific)</summary>

One clean approach: build the `Deal` with `id: DealId(0)`, validate it, then set
`deal.id = self.deals.next_id()` and insert. Another: keep the current order and accept the
gap, but write down why. Either is fine if you can justify it.

</details>

> 💡 **HINT (Your Turn 2):** write down the 8 *allowed* pairs as an array of tuples. Then
> loop over `DealStage::ALL` twice (nested `for`). For each pair, the expected answer is
> "is this pair in my array?".

<details><summary>Hint 2 (more specific)</summary>

`allowed.contains(&(from, to))` works because tuples of `PartialEq` types are `PartialEq`.
The third argument of `assert_eq!` is a format string: `"{from} -> {to}"`.

</details>

> 💡 **HINT (Your Turn 3):** you need two numbers from one pass, so think `fold` with a tuple
> accumulator, starting from `(0, Money::ZERO)`.

<details><summary>Hint 2 (more specific)</summary>

`rows.iter().filter(|row| !row.stage.is_closed()).fold((0, Money::ZERO), |(count, total), row| ...)`.
For the won line, `rows.iter().find(|r| r.stage == DealStage::Won)` returns an
`Option<&PipelineRow>`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:

1. Why does `$1.005` round to `1.00` with `{:.2}`, and why can't that happen with `Money`?
2. `a + b` on two `Money` values compiles to a call of which function? What does it take by
   value, and why is that fine for `Money` but significant for `String`?
3. Why does `values.iter().sum::<Money>()` need a different impl from
   `values.into_iter().sum::<Money>()`? What would you have to write without `Sum<&'a Money>`?
4. What does `Formatter::pad` do that `write!` doesn't?
5. Name the four transition rules. Which single line of code enforces "closed stages are final"?
6. Why does `BTreeMap<DealStage, _>` iterate in pipeline order? What would break the order
   without a compiler error?
7. Describe the entry API in one sentence: what does `entry(k)` return, and what does
   `or_default()` give you back?
8. Why can't a new deal start in the `Won` stage? (It's not a validation rule.)

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

You already committed "Add Money type" after Step 5. Now the deals:

```bash
git add .
git commit -m "Add deals and pipeline report"
git tag lab-18
git push && git push --tags
```

Check the two-commit story: `git log --oneline lab-17..lab-18`.

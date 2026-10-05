# Lab 18 — Solutions

> 🔴 **SOLUTION**: read these *after* a genuine attempt. Each solution explains why it's
> written that way. If your version differs but meets the acceptance criteria, it's probably fine.
> Compare the reasoning, not the characters.

---

## Mini-task answers

### Which check rejects `"1.2.3"`?

`split_once('.')` splits at the **first** dot only, so `whole = "1"` and `fraction = "2.3"`.
`all_digits("2.3")` is `false` because `.` isn't an ASCII digit, so we return `Err(invalid())`.
(`fraction.len() > 2` would also be true here, but `||` short-circuits on the first `true`.)

### `or_insert(v)` vs `or_insert_with(|| v)` vs `or_default()`

All three return `&mut V`. They differ in **when the default value is built**:

- `or_insert(v)`: `v` is an argument, so it's evaluated **every time**, even when the key already
  exists and `v` is thrown away. Fine for `0` or `Money::ZERO`.
- `or_insert_with(|| v)`: takes a closure (`FnOnce`, called at most once), which only runs if the
  entry is vacant. Use it when building the default is expensive or allocates, e.g.
  `or_insert_with(Vec::new)` or `or_insert_with(|| expensive_lookup(k))`.
- `or_default()`: shorthand for `or_insert_with(V::default)`. Requires `V: Default`.

`entry(k).or_insert(String::from("x"))` allocates a `String` on every call, including the
calls where it's discarded. That's the case `or_insert_with` exists for.

---

## Your Turn 1 — `Validate` for `Deal`

In `src/errors.rs`:

```rust
// in enum ValidationError
    EmptyTitle,

// in impl Display for ValidationError
            ValidationError::EmptyTitle => write!(f, "title must not be empty"),
```

In `src/deals/model.rs` (add `Validate` to the `use crate::entity::...` line):

```rust
impl Validate for Deal {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.title.trim().is_empty() {
            return Err(ValidationError::EmptyTitle);
        }
        if self.value < Money::ZERO {
            return Err(ValidationError::InvalidMoney(self.value.to_string()));
        }
        Ok(())
    }
}
```

`self.value < Money::ZERO` works because `Money: PartialOrd`, which you derived in Step 2.
You can't write `self.value.cents < 0` here: the field is private to `money.rs`. You could
write `self.value.cents() < 0`, but comparing against `Money::ZERO` keeps the code in money
terms.

In `src/crm.rs` (add `use crate::entity::Validate;` if it isn't imported yet):

```rust
        let mut deal = Deal {
            id: DealId(0), // placeholder: only mint a real id once the deal is valid
            company_id,
            title,
            value,
            stage: DealStage::Qualification,
        };
        deal.validate()?;
        deal.id = self.deals.next_id();
        Ok(self.deals.insert(deal))
```

**Why the placeholder id?** `InMemoryRepo::next_id()` *increments a counter*. If you call it
before `validate()` and validation fails, that number is gone, and the next deal skips one.
Validating with a placeholder and assigning the real id afterwards avoids the gap. The
placeholder never escapes the function, because the `?` returns before the deal is stored.

The alternative is to validate the inputs (`title`, `value`) before building the struct.
That duplicates the rules from `validate()`, and duplicated rules drift apart. The
placeholder approach keeps **one** definition of "valid deal".

(Postgres sequences burn values on failed inserts too. Gaps in ids are normal in real systems,
and nothing should depend on ids being contiguous. Still, it's worth knowing *why* a gap would
appear.)

Test, in `model.rs`'s `tests` module:

```rust
    #[test]
    fn validate_rejects_empty_title_and_negative_value() {
        let mut d = deal(DealStage::Qualification);
        d.title = "   ".to_string();
        assert_eq!(d.validate(), Err(ValidationError::EmptyTitle));

        let mut d = deal(DealStage::Qualification);
        d.value = Money::from_cents(-1);
        assert_eq!(d.validate(), Err(ValidationError::InvalidMoney("-$0.01".to_string())));
    }
```

`assert_eq!` works here because `ValidationError: PartialEq` (Lab 12). Shadowing `d` with a
fresh deal makes sure the second assertion tests *only* the value rule.

---

## Your Turn 2 — Test every transition rule

```rust
    #[test]
    fn transition_table_is_exactly_as_specified() {
        use DealStage::*;
        let allowed = [
            (Qualification, Proposal),
            (Qualification, Won),
            (Qualification, Lost),
            (Proposal, Negotiation),
            (Proposal, Won),
            (Proposal, Lost),
            (Negotiation, Won),
            (Negotiation, Lost),
        ];
        for from in DealStage::ALL {
            for to in DealStage::ALL {
                let expected = allowed.contains(&(from, to));
                assert_eq!(from.can_transition_to(to), expected, "{from} -> {to}");
            }
        }
    }

    #[test]
    fn only_won_and_lost_are_closed() {
        let closed: Vec<DealStage> =
            DealStage::ALL.into_iter().filter(|s| s.is_closed()).collect();
        assert_eq!(closed, [DealStage::Won, DealStage::Lost]);
    }

    #[test]
    fn rejected_move_leaves_stage_unchanged() {
        let mut d = deal(DealStage::Won);
        let result = d.move_to(DealStage::Negotiation);
        assert!(matches!(
            result,
            Err(CrmError::InvalidTransition { from: DealStage::Won, to: DealStage::Negotiation })
        ));
        assert_eq!(d.stage, DealStage::Won);
    }
```

**Why this design:**

- The test lists the **8 allowed pairs**, written straight from the business rules, not derived
  from the code. The other 17 are implicitly forbidden. That's 25 assertions from 8 lines of data.
- It's an **independent oracle**. If the expected values came from calling
  `can_transition_to`, the test would check the function against itself and could never fail.
- Iterating `ALL × ALL` means a new variant is automatically included, *if* you remember to add
  it to `ALL`. (That's why Experiment 3 matters.)
- The message `"{from} -> {to}"` turns a failure into
  `assertion failed ... : won -> lost`, which you can act on immediately.
- `matches!` with **nested patterns** checks the variant *and* both fields in one expression,
  without needing `CrmError: PartialEq`.

Sabotage check: changing the first arm to `(Qualification, Proposal) | (Proposal, Negotiation) | (Won, Lost) => true` produces:

```text
assertion `left == right` failed: won -> lost
  left: true
 right: false
```

---

## Your Turn 3 — Pipeline totals

In `src/deals/report.rs`:

```rust
/// Number and total value of deals in open (not closed) stages.
pub fn open_total(rows: &[PipelineRow]) -> (usize, Money) {
    let open = rows.iter().filter(|row| !row.stage.is_closed());
    open.fold((0, Money::ZERO), |(count, total), row| {
        (count + row.count, total + row.total)
    })
}
```

and in `src/deals/mod.rs`: `pub use report::{PipelineRow, open_total};`

- **`fold` with a tuple accumulator** computes two results in one pass. The closure
  destructures the accumulator in its parameter list, `|(count, total), row|`, the same pattern
  syntax as `let (a, b) = ...`.
- `total + row.total` uses your `Add` impl. Both are `Money`, and both are `Copy`, so nothing
  is moved out of the borrowed rows.
- It's a **free function**, not a `Crm` method: it needs only the rows, not the CRM. A function
  that takes exactly what it needs is easier to test.

Why not `.map(|r| r.total).sum()` plus a separate `.map(|r| r.count).sum()`? That works and is
arguably more readable. The cost is two passes and a repeated filter. With 5 rows, either is fine.
Choose the one you find clearer. The fold version is shown because it's the general pattern
for "several aggregates at once".

In `src/cli/commands.rs`:

```rust
use crate::deals::{DealStage, open_total};

fn print_pipeline(crm: &Crm) {
    let rows = crm.pipeline_report();
    println!("{:<14} {:>5} {:>14}", "Stage", "Deals", "Value");
    for row in &rows {
        println!("{:<14} {:>5} {:>14}", row.stage, row.count, row.total);
    }

    let (open_count, open_value) = open_total(&rows);
    let won = rows
        .iter()
        .find(|r| r.stage == DealStage::Won)
        .map(|r| r.total)
        .unwrap_or_default();
    println!();
    println!("Open: {} worth {open_value}", plural(open_count, "deal"));
    println!("Won:  {won}");
}

fn plural(count: usize, word: &str) -> String {
    if count == 1 { format!("1 {word}") } else { format!("{count} {word}s") }
}
```

- **`for row in &rows`**, not `for row in rows`. The plain version calls `into_iter()` and
  **moves** `rows` into the loop, and `open_total(&rows)` afterwards would fail with E0382
  (borrow of moved value). Lab 06's loop move, one more time.
- `.unwrap_or_default()` on `Option<Money>` works because `Money: Default`. The report always
  contains a `Won` row, so this never actually defaults. It just avoids a panicking `unwrap`.
  Another quiet benefit of deriving `Default`.

Test:

```rust
    #[test]
    fn open_total_ignores_closed_stages() {
        let report = crm_with_deals().pipeline_report();
        // A (proposal, $10.00) + B (qualification, $25.00); C is won and excluded
        assert_eq!(open_total(&report), (2, Money::from_cents(3_500)));
    }
```

---

## Experiment answers

**Experiment 1:** to keep a `HashMap` and still print in order, either sort afterwards
(`rows.sort_by_key(|r| r.stage)`, which works because `DealStage: Ord`) or drive the output from
`DealStage::ALL` and look each stage up in the map. Both work. The `BTreeMap` just makes ordering
a property of the data structure instead of an extra step someone could forget.

**Experiment 2:** relying on derived `Ord` is fine when (a) the order is documented next to the
enum, and (b) a test pins it down. If the order is a *business* concept that might change
independently of the declaration order, implement `Ord` by hand or give the enum an explicit
`fn position(self) -> u8`.

**Experiment 3:** the compiler only flagged `Display`. `can_transition_to` (wildcard), `ALL`
(a hand-maintained list) and `FromStr` (matches strings) all stayed silent. The table test from
Your Turn 2 doesn't catch it either, unless `Discovery` is added to `ALL`. **Lesson:**
exhaustiveness checking protects `match`es without wildcards. Everything else needs a test, or
a design that keeps the variants in one place.

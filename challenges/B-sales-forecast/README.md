# 🏁 Challenge B — Sales Forecast

> **After:** Lab 20 (end of Phase 5) · **Time:** ~3–5 hours
> **Your repo before:** tag `lab-20` · **Uses:** Phases 3–5 (enums, errors, traits, generics, iterators, `Money`, `DealStage`, `chrono`)

This is a challenge, not a lab. There are no steps. You get a specification, constraints and
acceptance criteria. How you build it is up to you.

- Stuck? Use [`hints.md`](hints.md), one tier at a time.
- Done? Compare with [`reference.md`](reference.md). It shows *one* design, not *the* design.

Nothing in later labs depends on this challenge. Do it on a branch if you like (see [Git](#git)).

---

## The problem

The `pipeline` report (Lab 18) answers *"what's in the pipeline right now?"*. Sales managers
ask a different question: *"how much money do we expect to close, and when?"*

Two ideas answer it:

1. **Expected close date.** Each deal can carry the date the salesperson expects it to close.
2. **Weighting by stage.** A $10,000 deal in Qualification isn't worth $10,000 to the
   forecast, because most deals at that stage never close. Multiply each deal's value by the
   probability of winning at its stage:

| Stage | Win probability |
|---|---|
| Qualification | 10% |
| Proposal | 30% |
| Negotiation | 60% |
| Won | 100% |
| Lost | 0% (excluded from the forecast) |

Your job: let users set expected close dates, and add a `forecast` command that groups deals by
**expected close month** and shows, per month, the deal count, the raw pipeline value and the
**weighted** value.

---

## Specification

### 1. Expected close dates

- A deal has **zero or one** expected close date: a calendar date with no time and no zone.
- New deals have **no** expected close date.
- New command:

```text
deal close-date <id> <YYYY-MM-DD|none>
```

```text
crm> deal close-date 1 2026-11-15
Deal #1 is expected to close on 2026-11-15
crm> deal close-date 1 none
Deal #1 has no expected close date
crm> deal close-date 1 2027-02-30
Error: invalid date (expected YYYY-MM-DD): '2027-02-30'
crm> deal close-date 99 2026-11-15
Error: deal #99 not found
```

- Dates in the past are allowed (deals slip, and won deals record when they actually closed).
- Any stage can have a date, including `won` and `lost`.
- `deal show <id>` also prints the expected close date, or `-` when there is none.
- How and where you store the date is **your design decision** (see Constraints).

### 2. Weighted value of one deal

```text
weighted = value × win_probability(stage), rounded to the nearest cent, half up
```

"Half up" means an exact half cent rounds **up**: 0.5¢ → 1¢, 30001.5¢ → 30002¢, while
0.49¢ → 0¢. Values are never negative in this CRM (deal validation, Lab 18), but your rounding
function must still give a sensible, documented answer for negative amounts (half *away from
zero* is the usual choice: −0.5¢ → −1¢).

**Rounding happens per deal**, *before* summing. This matters, and the acceptance scenario
checks it.

### 3. The `forecast` command

```text
crm> forecast
Month        Deals       Pipeline       Weighted
2026-10          1      $2,500.00      $2,500.00
2026-11          2      $1,000.10        $300.03
2026-12          1     $10,000.00      $6,000.00
2027-01          1        $500.00         $50.00
Unscheduled      1      $1,234.56        $123.46
Total            6     $15,234.66      $8,973.49
```

- **Rows** are expected-close months (`YYYY-MM`), **ascending chronologically** (so `2026-12`
  comes before `2027-01`), followed by one `Unscheduled` row for deals without a date.
- Only months that contain at least one deal appear. No empty months are filled in.
- The `Unscheduled` row appears only if at least one deal has no date.
- **Lost deals are excluded entirely**: not counted, not in the pipeline column.
- **Won deals are included** at 100%.
- **Deals** = number of deals in the row. **Pipeline** = sum of their raw values.
  **Weighted** = sum of their *individually rounded* weighted values.
- A final `Total` row sums each column over all rows.
- With no forecastable deals at all, print only the header and `Total 0 $0.00 $0.00`.
- Money columns are right-aligned. Exact column widths are up to you.

---

## Acceptance criteria

Build this exact scenario (a unit test is the best place for it, plus once by hand in the CLI):

| Deal | Value | Stage | Expected close |
|---|---|---|---|
| A | $1,000.05 | proposal | 2026-11-15 |
| B | $0.05 | qualification | 2026-11-30 |
| C | $10,000.00 | negotiation | 2026-12-01 |
| D | $2,500.00 | won | 2026-10-20 |
| E | $9,999.00 | lost | 2026-11-01 |
| F | $1,234.56 | qualification | *(none)* |
| G | $500.00 | qualification | 2027-01-05 |

- [ ] `forecast` produces the rows shown in the Specification above, in that order, with those values
- [ ] **Per-deal rounding:** November's weighted value is **$300.03** (A: 30001.5¢ → 30002¢,
      B: 0.5¢ → 1¢). Rounding the *sum* instead would give $300.02. Your test must check this.
- [ ] Deal E (lost) appears nowhere, and the total count is 6, not 7
- [ ] `2026-12` is listed before `2027-01`, and `Unscheduled` is listed last
- [ ] Unit tests for the rounding function cover: an exact half (rounds up), just below a half
      (rounds down), 0%, 100%, and a negative amount
- [ ] A unit test for every stage's probability (or a table-driven test covering all five)
- [ ] `deal close-date` with an invalid date (`2027-02-30`, `2026-13-01`, `tomorrow`) prints an
      error and changes nothing
- [ ] `deal close-date <id> none` clears a date. That deal moves to `Unscheduled`
- [ ] Moving a deal to `lost` removes it from the forecast. Moving it to `won` shows it at 100%
- [ ] `cargo fmt --check && cargo clippy --all-targets && cargo test` pass

---

## Constraints

1. **No floating point.** `f32`/`f64` must not appear anywhere in the forecast or rounding
   code. (Lab 18 showed why. Search your diff for `f64` before you call it done.)
2. **One rounding implementation**, living with `Money` (a method or a function in
   `money.rs`), unit-tested on its own. The forecast calls it and never rounds by itself.
3. **No overflow surprises.** `value × percent` must not be able to overflow silently. Either
   prove it can't for any `i64` value, or handle it (wider intermediate type, `checked_*`, …)
   and document the choice in a comment.
4. **Don't change existing public signatures.** `Crm::add_deal`, `Crm::move_deal`,
   `Crm::pipeline_report`, `Lead::convert` etc. keep their exact signatures, because later labs
   call them. *Add* new methods instead.
5. **Domain vs CLI.** The forecast is computed in domain code (e.g. a `Crm` method or a function
   in `src/deals/`) returning data, not strings. The CLI only formats and prints. Parsing
   `YYYY-MM-DD` from user input belongs in the CLI layer (or a `FromStr`), not in the forecast.
6. **Deterministic output.** No `HashMap` iteration order may leak into what's printed.
7. **No new crates.** `chrono` (already added in Lab 20) and `std` are enough.

> 💡 **About storing the date.** The obvious design adds a field to `Deal`. That's a fine
> choice, but every place that builds a `Deal { .. }` literal will need the new field, including
> code you'll write in later labs, whose snippets won't mention it. (You'll just add
> `expected_close: None` where needed. The compiler will point at every spot.) The alternative,
> a separate map from `DealId` to date inside `Crm`, avoids that, at the cost of keeping two
> things in sync. Pick one and be able to defend it. The reference discusses both.

---

## Concepts you're expected to use

- **Newtypes and operator traits**: `Money`, `Add`/`AddAssign`/`Sum` (Lab 18)
- **Integer arithmetic done right**: rounding with integers, overflow (`i128` or `checked_*`)
- **Enums as ordered keys**: derived `Ord` and declaration order (Lab 18). Think carefully about
  how "Unscheduled sorts last" can be made true **by construction**.
- **`BTreeMap` + entry API** for grouping (Lab 18), or sort explicitly
- **`Option`** for "maybe a date", and the combinators (`map`, `map_or`)
- **`chrono::NaiveDate`** and the `Datelike` trait (`year()`, `month()`) (Lab 20)
- **`FromStr` / parsing at the boundary**, with `ValidationError` (Labs 12, 15)
- **Iterator consumers**: `filter`, `map`, `sum`, `fold` (Lab 17)
- **Table-driven tests** (Lab 18, Your Turn 2)

---

## Stretch goals (optional)

- `forecast --from 2026-11 --to 2027-03`: only months in that range (inclusive). Decide, and
  document, whether `Unscheduled` is shown when a range is given.
- `forecast --fill`: include empty months between the first and last month, with zeros.
- `forecast --by quarter`: group by `2026-Q4` instead of month.
- Show a `Won` column separately from the weighted open pipeline (managers like seeing
  "committed" vs "expected").

---

## Git

```bash
git switch -c challenge-b
# ...work, commit as you go...
git commit -m "Add sales forecast"
git switch main
git merge challenge-b      # if you want it in your main line
git push && git push --tags
```

If you merge it, later labs still work, and you'll simply have a richer `Deal`. If you added a
field to `Deal`, expect to add `expected_close: None` to a few `Deal { .. }` literals in later
labs (Lab 21 will also need chrono's `serde` feature for `NaiveDate`, which it turns on anyway).

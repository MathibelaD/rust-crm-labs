# Challenge B — Reference Design

> Read this **after** you've finished (or after a serious attempt). It's *one* design that
> passes every acceptance criterion, with the reasoning behind each choice. It isn't a
> drop-in implementation, and yours doesn't need to look like it.

---

## Overview

```text
src/money.rs            + Money::percent(self, pct: u32) -> Money        (rounding, once)
src/deals/model.rs      + Deal.expected_close: Option<NaiveDate>
                        + DealStage::win_probability(self) -> u32
src/deals/forecast.rs   new: YearMonth, Bucket, ForecastRow, Crm::forecast()
src/crm.rs              + Crm::set_expected_close(id, Option<NaiveDate>)
src/cli/parser.rs       + DealCommand::CloseDate { id, date }, Command::Forecast
src/cli/commands.rs     + print_forecast, close-date handler, "Close:" line in deal show
```

About 150 lines of code plus tests. The interesting decisions are all in the types.

---

## 1. Rounding lives in `Money`

```rust
impl Money {
    /// `pct` percent of this amount, rounded half up to the cent
    /// (for negative amounts: half away from zero).
    pub fn percent(self, pct: u32) -> Money {
        let scaled = i128::from(self.cents) * i128::from(pct); // in hundredths of a cent
        let rounded = if scaled >= 0 { (scaled + 50) / 100 } else { (scaled - 50) / 100 };
        Money::from_cents(i64::try_from(rounded).expect("percentage of Money overflowed i64"))
    }
}
```

**Why `i128`.** `i64::MAX × 100` doesn't fit in an `i64`. `i128::from(i64)` is a lossless
widening, so the product can never overflow (`i64::MAX × u32::MAX` is still far below
`i128::MAX`). Coming back down, `i64::try_from` *can* fail in principle (e.g. 200% of
`i64::MAX`), so it's a `try_from`, and the `expect` message says what happened. For
`pct <= 100`, the magnitude never grows, so it can't fail in this CRM. The alternative,
`checked_mul` returning `Option<Money>`, pushes an impossible error onto every caller. With
`i128` we can be infallible honestly for the inputs we use.

**Why `+ 50` / `- 50`.** Integer division truncates toward zero. Adding half the divisor first
shifts the boundary, so `.5` and above go up. For negatives, subtracting turns
truncate-toward-zero into round-half-away-from-zero. Integer-only, exact, no `f64` anywhere.

**Why a method on `Money`.** Rounding rules are a property of the money type, not of the
forecast. Next month someone writes "commission = 7% of won deals", and they should find
`percent` waiting, already tested.

Tests worth having:

```rust
    #[test]
    fn percent_rounds_half_up_to_the_cent() {
        assert_eq!(Money::from_cents(100_005).percent(30), Money::from_cents(30_002)); // 30001.5
        assert_eq!(Money::from_cents(5).percent(10), Money::from_cents(1)); // 0.5
        assert_eq!(Money::from_cents(4).percent(10), Money::ZERO); // 0.4
        assert_eq!(Money::from_cents(149).percent(1), Money::from_cents(1)); // 1.49
        assert_eq!(Money::from_cents(1_000).percent(100), Money::from_cents(1_000));
        assert_eq!(Money::from_cents(-5).percent(10), Money::from_cents(-1));
        assert_eq!(Money::from_cents(i64::MAX).percent(0), Money::ZERO);
    }
```

The comment on each line shows the exact intermediate value. When a rounding test fails, you
want to see the arithmetic, not reverse-engineer it.

---

## 2. Probability lives in `DealStage`

```rust
    /// Chance of winning a deal in this stage, in percent.
    pub fn win_probability(self) -> u32 {
        match self {
            DealStage::Qualification => 10,
            DealStage::Proposal => 30,
            DealStage::Negotiation => 60,
            DealStage::Won => 100,
            DealStage::Lost => 0,
        }
    }
```

**No wildcard.** If a stage is ever added, this `match` stops compiling, which is exactly where
someone must decide the new probability. (Compare Lab 18's `_ => false` in the transition table,
where deny-by-default made a wildcard defensible. Here no default is safe.)

`u32` rather than a `Percent` newtype is a judgment call. A newtype would stop someone passing
`0.3` or `3000`, but with one producer (`win_probability`) and one consumer (`percent`), it's
more ceremony than protection. If probabilities became user-editable, a `Percent(u8)` with a
validating constructor would earn its place.

---

## 3. The date: a field on `Deal`

```rust
pub struct Deal {
    pub id: DealId,
    pub company_id: CompanyId,
    pub title: String,
    pub value: Money,
    pub stage: DealStage,
    pub expected_close: Option<NaiveDate>,
}
```

```rust
    pub fn set_expected_close(
        &mut self,
        id: DealId,
        date: Option<NaiveDate>,
    ) -> Result<(), CrmError> {
        let deal = self.deals.get_mut(id).ok_or(CrmError::NotFound {
            entity: "deal",
            id: id.0,
        })?;
        deal.expected_close = date;
        Ok(())
    }
```

**Why a field.** The date is a fact *about the deal*. It should travel with it: into JSON
(Lab 21), into the `deals` table as a nullable `DATE` column (Lab 31), into API responses
(Lab 29). A side map would have to be persisted, migrated and kept in sync separately. Deleting
a deal would need a matching delete in the map, and that kind of bookkeeping eventually gets
forgotten.

**The cost, paid once:** `Crm::add_deal` and `Lead::convert` build `Deal { .. }` literals,
and both gained `expected_close: None`. The compiler found both (E0063, missing field). Note
that `add_deal`'s **signature didn't change** (constraint 4). New deals start without a date,
and a separate method sets it, the same way `move_deal` is separate from `add_deal`.

**`Option<NaiveDate>` in one `set_` method** handles both "set" and "clear". The CLI's `none`
maps to `None`. One method, no `clear_expected_close` twin.

---

## 4. Buckets: make the order true by construction

```rust
/// A calendar month, ordered chronologically (year first, then month).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct YearMonth {
    pub year: i32,
    pub month: u32,
}

impl From<NaiveDate> for YearMonth {
    fn from(date: NaiveDate) -> Self {
        YearMonth { year: date.year(), month: date.month() }   // needs `use chrono::Datelike;`
    }
}

/// Where a deal lands in the forecast. Variant order = display order:
/// every month (chronologically) first, then `Unscheduled`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Bucket {
    Month(YearMonth),
    Unscheduled,
}
```

Two derived orderings do all the work:

- **Structs** derive `Ord` **lexicographically by field, in declaration order**. `year` before
  `month` means 2026-12 < 2027-01. Swap the fields and December 2026 would sort *after*
  January 2027 (month 12 > month 1). Declaration order is load-bearing again, as in Lab 18.
- **Enums** derive `Ord` by **variant order**. `Month(_)` is declared first, so *every* month
  sorts before `Unscheduled`, whatever the date.

Why not `Option<YearMonth>`? Its derived order puts `None` **first**. You'd need
`sort_by(|a, b| match (a, b) { (None, Some(_)) => Greater, ... })` or a special case in the
printer. Both are rules a reader must discover. `Bucket` *names* the concept and makes the
required order a property of the type:

```rust
    #[test]
    fn unscheduled_sorts_after_every_month() {
        let late = Bucket::Month(YearMonth { year: 9999, month: 12 });
        assert!(late < Bucket::Unscheduled);
    }
```

`Display` for both uses `f.pad` (Lab 18, Step 4) so `{:<12}` aligns the column:

```rust
impl fmt::Display for YearMonth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad(&format!("{}-{:02}", self.year, self.month))
    }
}
```

`Bucket`'s `Display` delegates with `Bucket::Month(month) => fmt::Display::fmt(month, f)`,
passing the *same* formatter on, so the caller's width applies to the inner value.
`write!(f, "{month}")` would format `month` with a fresh, default spec, and the padding would
be lost.

---

## 5. Grouping: `BTreeMap` + entry, one pass

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForecastRow {
    pub bucket: Bucket,
    pub count: usize,
    pub pipeline: Money,
    pub weighted: Money,
}

impl Crm {
    pub fn forecast(&self) -> Vec<ForecastRow> {
        let mut rows: BTreeMap<Bucket, ForecastRow> = BTreeMap::new();
        for deal in self.deals.iter().filter(|d| d.stage != DealStage::Lost) {
            let bucket = deal
                .expected_close
                .map_or(Bucket::Unscheduled, |date| Bucket::Month(date.into()));
            let row = rows.entry(bucket).or_insert(ForecastRow {
                bucket,
                count: 0,
                pipeline: Money::ZERO,
                weighted: Money::ZERO,
            });
            row.count += 1;
            row.pipeline += deal.value;
            row.weighted += deal.value.percent(deal.stage.win_probability());
        }
        rows.into_values().collect()
    }
}
```

- **Lost is filtered explicitly**, even though its probability is 0%. "Excluded" also means
  *not counted and not in the pipeline column*. A 0% weight alone would still count the deal.
- **Rounding per deal** happens naturally: `percent` is called once per deal, and the rounded
  `Money` values are summed with `AddAssign`. Rounding per month would mean accumulating
  unrounded hundredths-of-cents and rounding at the end. That's a *different* (also defensible)
  business rule, and the acceptance scenario is built so that the two give different answers
  ($300.03 vs $300.02). Specs must say which. This one does.
- **No seeding** (unlike Lab 18's pipeline): only months with deals appear, which is exactly
  what `entry().or_insert(..)` gives you.
- **`into_values()`** consumes the map and yields rows in **key order**, already the display
  order. No sort step.
- `ForecastRow` repeats `bucket` (it's also the key). That's a small duplication that makes each
  row self-contained for the caller.

---

## 6. CLI

Totals are computed by the printer from the rows, using `Sum` (Lab 18):

```rust
fn print_forecast(crm: &Crm) {
    let rows = crm.forecast();
    println!("{:<12} {:>5} {:>14} {:>14}", "Month", "Deals", "Pipeline", "Weighted");
    for row in &rows {
        println!("{:<12} {:>5} {:>14} {:>14}", row.bucket, row.count, row.pipeline, row.weighted);
    }
    let count: usize = rows.iter().map(|r| r.count).sum();
    let pipeline: Money = rows.iter().map(|r| r.pipeline).sum();
    let weighted: Money = rows.iter().map(|r| r.weighted).sum();
    println!("{:<12} {:>5} {:>14} {:>14}", "Total", count, pipeline, weighted);
}
```

Is "Total" domain logic that leaked into the CLI? Arguably. It's a trivial sum over data the
domain already returned, and it's the same in every presentation. If a second consumer appeared
(the HTTP API in Lab 29), moving totals into a `Forecast { rows, total }` struct would be the
next refactor.

`deal close-date` parsing is shown in Tier 3 of the hints: `NaiveDate`'s `FromStr` does the
calendar validation (`2027-02-30` and `2026-13-01` both fail), and the error becomes a
`ValidationError::InvalidValue` at the boundary.

---

## 7. The acceptance test

```rust
    fn acceptance_crm() -> Crm {
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".to_string(), None).unwrap();
        let mut add = |title: &str, cents: i64, stages: &[DealStage], close: Option<&str>| {
            let id = crm.add_deal(acme, title.to_string(), Money::from_cents(cents)).unwrap();
            for &stage in stages {
                crm.move_deal(id, stage).unwrap();
            }
            crm.set_expected_close(id, close.map(date)).unwrap();
        };
        use DealStage::*;
        add("A", 100_005, &[Proposal], Some("2026-11-15"));
        add("B", 5, &[], Some("2026-11-30"));
        add("C", 1_000_000, &[Proposal, Negotiation], Some("2026-12-01"));
        add("D", 250_000, &[Won], Some("2026-10-20"));
        add("E", 999_900, &[Lost], Some("2026-11-01"));
        add("F", 123_456, &[], None);
        add("G", 50_000, &[], Some("2027-01-05"));
        crm
    }

    #[test]
    fn forecast_matches_the_acceptance_scenario() {
        let rows = acceptance_crm().forecast();
        let shown: Vec<(String, usize, i64, i64)> = rows
            .iter()
            .map(|r| (r.bucket.to_string(), r.count, r.pipeline.cents(), r.weighted.cents()))
            .collect();
        assert_eq!(
            shown,
            [
                ("2026-10".to_string(), 1, 250_000, 250_000),
                ("2026-11".to_string(), 2, 100_010, 30_003),
                ("2026-12".to_string(), 1, 1_000_000, 600_000),
                ("2027-01".to_string(), 1, 50_000, 5_000),
                ("Unscheduled".to_string(), 1, 123_456, 12_346),
            ]
        );
    }
```

Deals reach their stage through `move_deal`, the **real** transition rules, not by
assigning `deal.stage` directly. Going through the public API means the test exercises the
same path the CLI uses. (`date` is a tiny helper: `fn date(s: &str) -> NaiveDate { s.parse().unwrap() }`.)

Comparing `(String, usize, i64, i64)` tuples gives one assertion for the whole table, with a
readable diff on failure, without needing `PartialEq` between `Bucket` and string literals.

---

## Common pitfalls

- **`f64` anywhere in the calculation** reintroduces Lab 18's bugs. In dollars, `1000.05 * 0.3`
  is stored as just under `300.015`, so `format!("{:.2}", ..)` prints `300.01` (half up says
  `300.02`). `1.15 * 0.1` is `0.11499999999999999` and prints `0.11` (should be `0.12`). Some
  inputs happen to come out right, which is what makes the bug hard to spot.
- **`Option<YearMonth>` keys**: `Unscheduled` appears *first*.
- **`(month, year)` field order**: 2027-01 sorts before 2026-12.
- **Rounding the monthly sum** instead of each deal: November shows $300.02.
- **Treating `Lost` as "0% weight"** instead of excluding it: the count says 7, and the pipeline
  column includes $9,999.00.
- **Changing `add_deal` to take a date**: breaks every later lab's call sites. Add a method instead.
- **`HashMap` for grouping**, then printing in iteration order: different order every run.

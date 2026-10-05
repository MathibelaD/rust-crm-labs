# Challenge B — Hints

Open one tier at a time, and only after you've been stuck for a while. Each tier gives away more
than the previous one.

---

## Tier 1 — Direction

<details><summary>Where do I start?</summary>

Split the problem into pieces that each have their own tests:

1. **Rounding**: "x percent of this `Money`, rounded half up". A pure function of two
   numbers. Do it first, with tests, before anything else exists.
2. **Probability**: a pure function of a `DealStage`.
3. **The date**: storing it, the `deal close-date` command, `deal show`.
4. **Grouping**: deals → rows. Pure, given a list of deals.
5. **Printing**: the easy part. Last.

Write the acceptance scenario as a unit test early (it'll fail), and let it drive the rest.

</details>

<details><summary>How do I round without floats?</summary>

Work in **hundredths of a cent**. `value_cents × percent` is an exact integer, and the result
is 100× too big. Turning "100× too big" back into cents is a division by 100, and integer
division *truncates*. How could you nudge the number before dividing so that truncation
behaves like rounding?

</details>

<details><summary>Which chrono type is "a date"?</summary>

A close date has no time and no zone, so it's `NaiveDate` (Lab 20's table). It implements
`FromStr` for `YYYY-MM-DD`, so `"2026-11-15".parse::<NaiveDate>()` works. To get the year and
month out, look at the `Datelike` trait. (Remember: trait methods need the trait in scope.)

</details>

<details><summary>How do I make "Unscheduled" sort after every month?</summary>

Think back to Lab 18's Experiment 2: what decides the order of a derived `Ord` on an enum?
And what's the derived order of `Option<T>`? Does `None` come before or after `Some(_)`?
(Try `assert!(None < Some(1));`.)

</details>

---

## Tier 2 — Design

<details><summary>Where should the date live?</summary>

Two reasonable designs:

- **A field** `expected_close: Option<NaiveDate>` on `Deal`. Natural to read (`deal.expected_close`),
  and it moves with the deal everywhere (JSON in Lab 21, the database in Lab 31). The cost:
  every `Deal { .. }` literal must mention it. The compiler finds them all (E0063
  "missing field").
- **A side table** `BTreeMap<DealId, NaiveDate>` in `Crm`. No change to `Deal`, but now
  removing a deal must also remove its date, and every reader must know to look in two
  places.

Either passes the acceptance criteria. The field is closer to how a real schema would look.

</details>

<details><summary>What should the rounding function look like?</summary>

A method on `Money`, e.g. `pub fn percent(self, pct: u32) -> Money`. Taking `self` by value is
fine because `Money: Copy`. Inside, multiply in a type wide enough that `i64::MAX × 100` can't
overflow. Which integer type is twice as wide as `i64`? `From` converts losslessly *up* to
it, and `TryFrom` brings the result back *down* (can that fail here?).

</details>

<details><summary>What should a forecast row contain?</summary>

Return data, not strings: something like

```rust
pub struct ForecastRow {
    pub bucket: /* a month, or "unscheduled" */,
    pub count: usize,
    pub pipeline: Money,
    pub weighted: Money,
}
```

and a `Crm::forecast(&self) -> Vec<ForecastRow>`. Totals can be computed by the CLI from the
rows with `sum()`. You implemented `Sum` for `Money` in Lab 18.

</details>

<details><summary>How should I represent the "bucket"?</summary>

You need something that (a) is either "a specific month" or "unscheduled", (b) sorts months
chronologically, and (c) puts "unscheduled" **last**. An enum with two variants, declared in
the right order, gives you (a) and (c) through derived `Ord`. For (b): a small
`YearMonth { year, month }` struct with derived `Ord` compares fields **in declaration order**.
Which field must come first?

`Option<YearMonth>` gives you (a) and (b) but not (c). `None` sorts first. You'd have to
special-case it when printing, which is exactly the kind of rule that gets forgotten.

</details>

---

## Tier 3 — Near-solution

<details><summary>The rounding function</summary>

```rust
pub fn percent(self, pct: u32) -> Money {
    let scaled = i128::from(self.cents) * i128::from(pct); // hundredths of a cent
    let rounded = if scaled >= 0 { (scaled + 50) / 100 } else { (scaled - 50) / 100 };
    Money::from_cents(i64::try_from(rounded).expect("..."))
}
```

Why `+ 50`? Adding half of the divisor before truncating division turns truncation into
round-half-up for non-negative numbers. For negatives, Rust's `/` truncates toward zero, so
subtracting 50 rounds half *away* from zero. With `pct <= 100` the result's magnitude is at most
`|cents|`, so the `try_from` can't fail. Say so in the `expect` message.

</details>

<details><summary>The grouping loop</summary>

```rust
let mut rows: BTreeMap<Bucket, ForecastRow> = BTreeMap::new();
for deal in self.deals.iter().filter(|d| d.stage != DealStage::Lost) {
    let bucket = /* from deal.expected_close */;
    let row = rows.entry(bucket).or_insert(ForecastRow { bucket, count: 0, /* zeros */ });
    row.count += 1;
    row.pipeline += deal.value;
    row.weighted += deal.value.percent(deal.stage.win_probability());
}
rows.into_values().collect()
```

`Option::map_or(default, f)` turns `Option<NaiveDate>` into a `Bucket` in one expression.
`into_values()` yields the rows in key order, which is the display order.

</details>

<details><summary>Parsing the command</summary>

With Lab 18's slice patterns:

```rust
["close-date", id, date] => {
    let id = /* parse id, Usage error on failure */;
    let date = match *date {
        "none" => None,
        raw => Some(raw.parse().map_err(|_| ValidationError::InvalidValue {
            field: "date (expected YYYY-MM-DD)",
            value: raw.to_string(),
        })?),
    };
    Ok(DealCommand::CloseDate { id: DealId(id), date })
}
```

`match *date` dereferences the `&&str` once so the arms can be string literals.

</details>

<details><summary>Testing the scenario without the CLI</summary>

Build the seven deals in a test helper. A closure keeps it short:

```rust
let mut add = |title: &str, cents: i64, stages: &[DealStage], close: Option<&str>| {
    let id = crm.add_deal(acme, title.to_string(), Money::from_cents(cents)).unwrap();
    for &stage in stages {
        crm.move_deal(id, stage).unwrap();   // e.g. &[Proposal, Negotiation]
    }
    crm.set_expected_close(id, close.map(|s| s.parse().unwrap())).unwrap();
};
```

The closure captures `crm` **mutably** (`FnMut`), so it must be declared `let mut add`, and
you can't use `crm` elsewhere until the closure's last call. Then compare the rows with a
`Vec` of tuples `(bucket.to_string(), count, pipeline.cents(), weighted.cents())`. That's one
`assert_eq!` for the whole table, with a readable diff when it fails.

</details>

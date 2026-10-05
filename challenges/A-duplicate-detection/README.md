# 🏁 Challenge A — Duplicate Detection

> **After:** Lab 10 (end of Phase 2) · **Time:** ~2–4 hours
> **Your repo before:** tag `lab-10` · **Uses:** everything from Labs 06–10

This is a challenge, not a lab. There are no steps. You get a specification, constraints and
acceptance criteria. How you build it is up to you.

- Stuck? Use [`hints.md`](hints.md), one tier at a time.
- Done? Compare with [`reference.md`](reference.md). It shows *one* design, not *the* design.

Nothing in later labs depends on this challenge. Do it on a branch if you like (see
[Git](#git) below).

---

## The problem

Your CRM rejects a new customer whose email exactly matches an existing one (Lab 05). But real
data is messier than that:

```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: A. Lovelace
Email: ADA@example.com        ← same person, different capitalisation: accepted
Phone: 
Added customer #3
```

Sales teams hate duplicates: two people call the same customer, histories get split, reports
double-count. Your job is a `duplicates` command that **finds** likely duplicates so a human can
decide what to do. It doesn't delete or merge anything.

---

## Specification

### Store method

Add to `impl CustomerStore`:

```rust
fn duplicates(&self) -> Vec<(&Customer, &Customer)>
```

Each element is a pair of customers that **look like the same person**. Two customers look like
the same person when **at least one** of these holds:

1. **Same email, ignoring case.** `ada@example.com` and `ADA@Example.COM` match. (ASCII
   case-insensitivity is enough.)
2. **Same phone, and it's not empty.** `555-0100` and `555-0100` match. Two customers with *no*
   phone (`""`) do **not** match on phone.

Rules for the returned pairs:

- **Each pair appears exactly once.** If #1 and #3 match, return `(#1, #3)` but not `(#3, #1)`.
  A pair that matches on both email *and* phone still appears once.
- **Lower id first** within each pair: `(#1, #3)`, never `(#3, #1)`.
- **Ordered** by the first id, then by the second id: `(#1, #3), (#1, #4), (#2, #5)`.
- A customer is never paired with itself.
- If three customers share an email, that's three pairs: `(#1, #2), (#1, #3), (#2, #3)`.
- An empty store, or a store with one customer, has no duplicates.

### `duplicates` command

```text
crm> duplicates
#1 Ada Lovelace <-> #3 A. Lovelace (same email)
#1 Ada Lovelace <-> #4 Countess of Lovelace (same phone)
Found 2 possible duplicates.
```

- One line per pair: `#<id> <name> <-> #<id> <name> (<reason>)`, where `<reason>` is
  `same email`, `same phone` or `same email and phone`
- Then `Found 1 possible duplicate.` or `Found <n> possible duplicates.`
- If there are none: `No duplicates found.`
- With any argument (e.g. `duplicates now`): `Usage: duplicates`
- `help` lists it: `  duplicates     find customers that look like duplicates`

---

## Constraints

- **No cloning customers.** No `.clone()` of a `Customer` and no clone of any of its `String`
  fields, anywhere in your solution (tests included). The pairs must **borrow** from the store.
  (Temporary strings such as a lowercased email are allowed but not needed. Bonus if you avoid
  them.)
- `duplicates` takes `&self`. It must not change the store.
- The signature is exactly `fn duplicates(&self) -> Vec<(&Customer, &Customer)>`. Be ready to
  explain why it compiles **without** any lifetime annotation, and what lifetime the references in
  the result have.
- No new crates. No changes to existing commands' behaviour.
- `cargo clippy` adds no new warnings. `cargo test` passes.

---

## Acceptance criteria

### Automated

Paste these into your `tests` module. They use only `CustomerStore::new`, `add`, `remove` and
your new `duplicates`. You may add the two helpers as they are, or write your own.

```rust
    /// (id, id) for each pair, so tests can compare plain numbers.
    fn pair_ids(pairs: &[(&Customer, &Customer)]) -> Vec<(u32, u32)> {
        let mut out = Vec::new();
        for (a, b) in pairs {
            out.push((a.id, b.id));
        }
        out
    }

    /// A store built from (name, email, phone) rows. Ids are 1, 2, 3, ...
    fn store_of(rows: &[(&str, &str, &str)]) -> CustomerStore {
        let mut store = CustomerStore::new();
        for (name, email, phone) in rows {
            store.add(name.to_string(), email.to_string(), phone.to_string());
        }
        store
    }

    #[test]
    fn a01_empty_store_has_no_duplicates() {
        assert!(CustomerStore::new().duplicates().is_empty());
    }

    #[test]
    fn a02_distinct_customers_are_not_duplicates() {
        let store = store_of(&[
            ("Ada", "ada@example.com", "555-0100"),
            ("Grace", "grace@navy.mil", "555-0199"),
        ]);
        assert!(store.duplicates().is_empty());
    }

    #[test]
    fn a03_email_match_ignores_case() {
        let store = store_of(&[
            ("Ada", "ada@example.com", ""),
            ("A. Lovelace", "ADA@Example.com", ""),
        ]);
        assert_eq!(pair_ids(&store.duplicates()), vec![(1, 2)]);
    }

    #[test]
    fn a04_empty_phones_do_not_match() {
        let store = store_of(&[
            ("Ada", "ada@example.com", ""),
            ("Grace", "grace@navy.mil", ""),
        ]);
        assert!(store.duplicates().is_empty());
    }

    #[test]
    fn a05_same_phone_matches() {
        let store = store_of(&[
            ("Ada", "ada@example.com", "555-0100"),
            ("Grace", "grace@navy.mil", "555-0199"),
            ("Countess", "countess@example.org", "555-0100"),
        ]);
        assert_eq!(pair_ids(&store.duplicates()), vec![(1, 3)]);
    }

    #[test]
    fn a06_three_way_duplicate_gives_three_pairs_in_order() {
        let store = store_of(&[
            ("A", "x@example.com", ""),
            ("B", "X@example.com", ""),
            ("C", "x@EXAMPLE.com", ""),
        ]);
        assert_eq!(pair_ids(&store.duplicates()), vec![(1, 2), (1, 3), (2, 3)]);
    }

    #[test]
    fn a07_email_and_phone_match_is_one_pair() {
        let store = store_of(&[
            ("Ada", "ada@example.com", "555-0100"),
            ("Ada L", "ada@example.com", "555-0100"),
        ]);
        assert_eq!(pair_ids(&store.duplicates()), vec![(1, 2)]);
    }

    #[test]
    fn a08_mixed_reasons_are_ordered_by_ids() {
        let store = store_of(&[
            ("Ada", "ada@example.com", "555-0100"),
            ("Grace", "grace@navy.mil", "555-0199"),
            ("A. Lovelace", "ADA@example.com", ""),
            ("Countess", "countess@example.org", "555-0100"),
            ("G. Hopper", "hopper@navy.mil", "555-0199"),
        ]);
        assert_eq!(pair_ids(&store.duplicates()), vec![(1, 3), (1, 4), (2, 5)]);
    }

    #[test]
    fn a09_deleted_customers_are_not_reported() {
        let mut store = store_of(&[
            ("A", "x@example.com", ""),
            ("B", "y@example.com", ""),
            ("C", "X@example.com", ""),
        ]);
        store.remove(1);
        assert!(store.duplicates().is_empty());
    }

    #[test]
    fn a10_results_borrow_from_the_store() {
        let store = store_of(&[("Ada", "ada@example.com", ""), ("Ada", "ADA@example.com", "")]);
        let pairs = store.duplicates();
        // The pair points at the store's own customers: same address, not a copy.
        assert!(std::ptr::eq(pairs[0].0, &store.all()[0]));
        assert!(std::ptr::eq(pairs[0].1, &store.all()[1]));
    }
```

`a10` uses `std::ptr::eq`, which checks whether two references point at the **same memory**.
It passes only if your pairs borrow the customers inside the store rather than copies of them.

Add tests of your own for anything you decide that the spec leaves open (for example, how you
compute the reason).

### Manual

Run the CRM and reproduce this exact session:

```text
crm> duplicates
No duplicates found.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@navy.mil
Phone: 555-0199
Added customer #2
crm> add
Name: A. Lovelace
Email: ADA@example.com
Phone: 
Added customer #3
crm> add
Name: Countess of Lovelace
Email: countess@example.org
Phone: 555-0100
Added customer #4
crm> duplicates
#1 Ada Lovelace <-> #3 A. Lovelace (same email)
#1 Ada Lovelace <-> #4 Countess of Lovelace (same phone)
Found 2 possible duplicates.
crm> duplicates now
Usage: duplicates
```

(If you did Lab 10's Your Turn 3, you'll also see a `Note: #1 Ada Lovelace also uses example.com.`
line after adding #3. That's expected.)

### Explain it

Write a short comment above `duplicates` (or in your commit message) answering:

1. What lifetime do the references in the returned pairs have, and which elision rule gives it?
2. Why can't the caller run `normalize` (or `add`, or `delete`) while still holding the result?
3. Why is "no cloning" possible here, but would *not* be possible if `duplicates` had to return
   pairs that outlive the store?

---

## Concepts you're expected to use

- Shared borrows of the store, and returning references from `&self` methods (Labs 07, 10)
- Slices: `&[Customer]`, sub-slices such as `&customers[i + 1..]`, slice patterns (Lab 09)
- Comparing strings without allocating: `eq_ignore_ascii_case` (Labs 09, 10)
- Lifetime elision rule 3, and the owned-vs-borrowed decision (Lab 10)
- `&'static str` for fixed text such as a reason label (Lab 10)
- Tuples (Lab 02), `Vec` (Lab 05), `Option` (Labs 05, 07)
- Tests that prove borrowing behaviour, not just values

## Stretch goals (optional)

- **Phone normalisation.** `555-0100`, `(555) 0100` and `5550100` are the same number. Compare
  only the digits, without allocating a new `String` per comparison.
  (Hint: you can compare two `char` iterators.)
- **Faster than O(n²).** For 10,000 customers, comparing every pair means ~50 million
  comparisons. Can you group customers first (e.g. with a `HashMap` keyed by lowercased email)
  and only compare within groups, while still reporting each pair once and in order?
- **Show the reasons in a test.** Make the reason a value your tests can check, not just text
  printed by the command.

## Git

```bash
git switch -c challenge-a        # optional: keep it off main
# ... work ...
git add .
git commit -m "Add duplicate detection"
git tag challenge-a
git push -u origin challenge-a --tags
```

> **Looking ahead:** in Lab 11 the commands become a `Command` enum, and that enum won't have a
> `Duplicates` variant. If you merged this into `main` and want to keep it, add a
> `Duplicates` variant yourself when you get there (the compiler will show you every `match` that
> needs updating). In Lab 14, `Customer` becomes `Contact`. Porting `duplicates` then is optional.

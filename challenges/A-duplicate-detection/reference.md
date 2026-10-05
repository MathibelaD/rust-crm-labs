# Challenge A — Reference Design

> Read this **after** you've finished (or truly given up). This is one reasonable design with
> the reasoning behind it, not the only correct answer. If your version passes the acceptance
> tests, respects the constraints and you can explain it, it's correct.

---

## Shape of the solution

Three pieces, each with one job:

| Piece | Signature | Job |
|---|---|---|
| Pair test | `fn duplicate_reason(a: &Customer, b: &Customer) -> Option<&'static str>` | Do these two look like one person, and why? |
| Pair search | `fn duplicates(&self) -> Vec<(&Customer, &Customer)>` on `CustomerStore` | Visit every unordered pair once, keep the matches |
| Command | `"duplicates"` arm in `main` | Print pairs + reasons, count, usage |

Keeping "is this a duplicate?" separate from "visit all pairs" means each can be tested and
changed alone. The phone-normalisation stretch goal only touches `duplicate_reason`, and the
O(n) stretch goal only touches `duplicates`.

---

## The pair test

```rust
/// Why two customers look like duplicates, or None if they don't.
fn duplicate_reason(a: &Customer, b: &Customer) -> Option<&'static str> {
    let same_email = a.email.eq_ignore_ascii_case(&b.email);
    let same_phone = a.has_phone() && a.phone == b.phone;
    match (same_email, same_phone) {
        (true, true) => Some("same email and phone"),
        (true, false) => Some("same email"),
        (false, true) => Some("same phone"),
        (false, false) => None,
    }
}
```

Design decisions:

- **`Option<&'static str>` instead of `bool`.** The caller gets the reason for free. Because the
  reasons are string literals, the return type is `'static` and **doesn't borrow from `a` or
  `b`**. If it returned `Option<&str>`, elision would fail (two input references, no `self`) and
  you'd be asked for a lifetime, for text that has nothing to do with either input. Writing
  `'static` says exactly the truth: this text lives in the binary.
- **`eq_ignore_ascii_case`** compares without allocating. `a.email.to_lowercase() == b.email.to_lowercase()`
  is also correct, but it allocates two `String`s for every pair, so for n customers that's about
  n² allocations. (Fully Unicode-aware case folding would need `to_lowercase`; ASCII is what the
  spec asks for, and email domains are case-insensitive ASCII in practice.)
- **`a.has_phone() && a.phone == b.phone`** encodes "same *non-empty* phone". Only `a` needs the
  emptiness check: if `a.phone` is non-empty and equal to `b.phone`, then `b.phone` is non-empty
  too. It also finally gives Lab 04's `has_phone` a caller.
- **Matching on `(bool, bool)`** lists all four cases. The compiler checks exhaustiveness, so you
  can't forget one. (In Lab 11 this becomes an enum, `DuplicateReason`, which is better than
  text. See the stretch goal.)

It's a free function, not a method on `CustomerStore`, because it doesn't need the store. It
compares two customers. A method on `Customer` (`a.duplicate_reason(b)`) would be just as good.

---

## The pair search

```rust
impl CustomerStore {
    /// Every pair of customers that look like the same person, each pair once,
    /// lower id first. Borrows from the store; copies nothing.
    fn duplicates(&self) -> Vec<(&Customer, &Customer)> {
        let customers = self.all();
        let mut pairs = Vec::new();
        for (i, a) in customers.iter().enumerate() {
            for b in &customers[i + 1..] {
                if duplicate_reason(a, b).is_some() {
                    pairs.push((a, b));
                }
            }
        }
        pairs
    }
}
```

### Why each pair appears once, in order

```text
customers:  [ #1 ][ #2 ][ #3 ][ #4 ]
i = 0, a = #1      └─────────────────┘  &customers[1..]  → compare #1 with #2, #3, #4
i = 1, a = #2            └───────────┘  &customers[2..]  → compare #2 with #3, #4
i = 2, a = #3                  └─────┘  &customers[3..]  → compare #3 with #4
i = 3, a = #4                        ┘  &customers[4..]  → empty slice (not a panic: 4 == len)
```

Every unordered pair is visited exactly once, the first element always comes earlier in the
store, and store order is id order (ids only grow; `Vec::remove` keeps the order of the rest).
So "lower id first" and "ordered by first id, then second id" come out of the loop shape, with no
sorting.

`&customers[i + 1..]` is Lab 09's sub-slicing. A range starting **at** `len` is valid and
empty. Only a start *past* `len` panics, and `i + 1 <= len` always holds here.

### Lifetimes: what you're not writing

After elision (rule 3), the signature is:

```rust
fn duplicates<'a>(&'a self) -> Vec<(&'a Customer, &'a Customer)>
```

Read it as: "the pairs point into the store, and the store stays borrowed while you use them".
That's precisely what makes "no cloning" possible. The `Customer`s already exist in the store, and
the result is just a list of `(ptr, ptr)` pairs pointing at them (16 bytes per pair on a 64-bit
machine, however long the names and emails are).

Inside the body: `customers` is `&'a [Customer]` (from `self.all()`), so `a` and `b` are
`&'a Customer`. They're borrowed from the store, not from the loop variables, so pushing them
is fine. If you'd written `pairs.push((&a, &b))` you'd have `&&Customer`s pointing at the loop
variables themselves. That's the wrong type, and they'd dangle at the end of each iteration
anyway.

### What the caller can't do

```rust
let pairs = store.duplicates();
store.normalize_emails();      // E0502: store is still borrowed by `pairs`
for (a, b) in &pairs { ... }
```

This is the right behaviour, not a limitation. `normalize_emails` mutates customers that `pairs`
points to (and in general, mutation may reallocate the `Vec`). If you needed results that survive
mutations, you'd return **ids**: `Vec<(u32, u32)>`. That's owned data, has no lifetime, and lets
you look the customers up again later. That's the same idea Lab 14 builds the whole data model
on.

### Complexity

O(n²) comparisons, O(k) memory for k pairs. For a CRM REPL with hundreds of customers this is
instant. See the stretch goal for the grouping approach.

---

## The command

```rust
            "duplicates" if !parsed.args.is_empty() => println!("Usage: duplicates"),
            "duplicates" => {
                let pairs = store.duplicates();
                if pairs.is_empty() {
                    println!("No duplicates found.");
                } else {
                    for (a, b) in &pairs {
                        let reason = duplicate_reason(a, b).unwrap_or("unknown");
                        println!("#{} {} <-> #{} {} ({reason})", a.id, a.name, b.id, b.name);
                    }
                    let noun = if pairs.len() == 1 { "duplicate" } else { "duplicates" };
                    println!("Found {} possible {noun}.", pairs.len());
                }
            }
```

- The `if` after the pattern is a **match guard** (Lab 11 covers it). A nested
  `if parsed.args.is_empty() { ... } else { ... }` inside a single arm is equally fine.
- `duplicate_reason` is called twice per reported pair (once in `duplicates`, once here). That's
  a deliberate trade: the store method keeps the exact signature from the spec, and the extra
  comparison is trivial. An alternative is a richer store method returning
  `Vec<(&Customer, &Customer, &'static str)>` (or a struct), with `duplicates` built on top of it.
- `unwrap_or("unknown")` can't actually happen (every returned pair has a reason), but it avoids an
  `unwrap()`. Lab 12 discusses when `expect` with a message is the more honest choice.

Help line:

```rust
    println!("  duplicates     find customers that look like duplicates");
```

---

## Tests beyond the acceptance suite

The acceptance tests cover `duplicates`. The reason function deserves its own:

```rust
    #[test]
    fn reason_reports_both_matches() {
        let store = store_of(&[("Ada", "ada@example.com", "555-0100"), ("Ada L", "ADA@example.com", "555-0100")]);
        let pairs = store.duplicates();
        assert_eq!(duplicate_reason(pairs[0].0, pairs[0].1), Some("same email and phone"));
    }
```

(Write `same email` / `same phone` / `None` cases the same way.)

---

## Stretch goals: design notes

**Phone digits only, without allocating.** Compare the two digit sequences lazily:

```rust
fn same_digits(a: &str, b: &str) -> bool {
    a.chars().filter(|c| c.is_ascii_digit()).eq(b.chars().filter(|c| c.is_ascii_digit()))
}
```

`Iterator::eq` walks both sequences in step and stops at the first difference. No `String` is
built. (Check that at least one digit exists, or two phones made only of punctuation will match.)

**A reason enum instead of text.** `enum DuplicateReason { Email, Phone, EmailAndPhone }` with a
`fn label(&self) -> &'static str`. Tests can then compare variants instead of strings. This is
exactly the refactor Lab 11 makes for commands.

**Grouping for O(n).** Build a `HashMap<String, Vec<&Customer>>` keyed by lowercased email (and a
second one keyed by phone), then emit pairs within each group. The tricky part is the spec's
"each pair once": a pair can appear in an email group *and* a phone group. Collect pairs as
`(id, id)` into a `BTreeSet` (which sorts and de-duplicates), then map back to references. Note
that the keys are owned `String`s (lowercasing allocates), while the values stay borrowed: that's
owned and borrowed data in one structure, each where it belongs.

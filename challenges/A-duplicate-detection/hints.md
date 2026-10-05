# Challenge A — Hints

Open one tier at a time, and only after you've been stuck for a while. Each tier gives away more
than the previous one.

---

## Tier 1 — Direction

<details><summary>Where do I even start?</summary>

Break it into three pieces you can test separately:

1. "Do these **two** customers look like the same person?" A small function taking two
   `&Customer`s.
2. "Visit every **pair** of customers exactly once." That's a loop shape question, independent of
   what a duplicate is.
3. Printing. It's the easy part, so leave it for last.

Get the acceptance tests compiling first (an empty `Vec::new()` body is enough), then make them
pass one at a time.

</details>

<details><summary>The signature has no lifetimes. Is that allowed?</summary>

Yes. Ask Lab 10's question: which elision rule applies to a method with `&self` and a reference in
its output? Every `&Customer` in the result gets `self`'s lifetime, which is exactly right, because
they all point into the store.

</details>

<details><summary>How do I compare emails ignoring case without cloning?</summary>

You met a `str` method in Lab 10's Your Turn 3 that compares two strings ignoring ASCII case,
without allocating anything.

</details>

<details><summary>How do I avoid reporting (#3, #1) as well as (#1, #3)?</summary>

If you compare every customer with *every* customer, you'll see each pair twice (and each
customer paired with itself). Only compare each customer with the ones **after** it.

</details>

---

## Tier 2 — Design

<details><summary>The "same person?" function</summary>

Something like:

```rust
fn duplicate_reason(a: &Customer, b: &Customer) -> Option<&'static str>
```

Returning *why* (or `None`) instead of a `bool` gives you the reason text for the command for
free, and `duplicates` can simply check `.is_some()`. The reason strings are literals, so they're
`&'static str`: they don't borrow from `a` or `b` at all, which keeps the signature simple.

For the phone rule, remember the "not empty" part. You may already have a method on `Customer`
that answers exactly that (Lab 04).

</details>

<details><summary>The pair loop</summary>

Two shapes work:

- **Indices:** an outer index `i` over `0..len`, and an inner index `j` over `i + 1..len`.
- **Slices (more Lab 09 in spirit):** an outer loop over the customers with their position, and an
  inner loop over the *sub-slice after* that position, `&customers[i + 1..]`. A sub-slice starting
  at `len` is empty, not a panic, so the last customer is handled automatically.

Either way, the order of the store gives you "lower id first" and the required ordering for free,
because ids only ever increase and `remove` keeps the order of the rest.

</details>

<details><summary>Why does my `push` complain about types?</summary>

If you loop with `for a in customers` where `customers: &[Customer]`, then `a` is already a
`&Customer`. Push `(a, b)`, not `(&a, &b)`. The second one is `(&&Customer, &&Customer)`, and it
points at your loop variables, which die at the end of each iteration.

</details>

<details><summary>The command</summary>

Get the pairs, then print each one using your reason function. `for (a, b) in &pairs` gives you
two `&&Customer`s. Field access and method calls auto-deref, so `a.id` and `a.name` work.

For `Usage: duplicates`, check whether `parsed.args` is empty.

</details>

---

## Tier 3 — Near-solution

<details><summary>Skeleton of `duplicates`</summary>

```rust
    fn duplicates(&self) -> Vec<(&Customer, &Customer)> {
        let customers = self.all();
        let mut pairs = Vec::new();
        for (i, a) in customers.iter().enumerate() {
            for b in &customers[i + 1..] {
                // if a and b look like the same person, push (a, b)
            }
        }
        pairs
    }
```

`customers.iter().enumerate()` yields `(position, &Customer)`. (Iterators get their own lab,
Lab 17. A plain `for i in 0..customers.len()` with `let a = &customers[i];` works just as well.)

</details>

<details><summary>Skeleton of the reason function</summary>

```rust
fn duplicate_reason(a: &Customer, b: &Customer) -> Option<&'static str> {
    let same_email = /* compare a.email and b.email ignoring ASCII case */;
    let same_phone = /* a has a phone, and it equals b's */;
    match (same_email, same_phone) {
        (true, true) => Some("same email and phone"),
        // three more arms
    }
}
```

Matching on a **tuple of bools** makes all four combinations visible, and the compiler checks
you've covered every one of them.

</details>

<details><summary>Test a10 fails</summary>

`std::ptr::eq(pairs[0].0, &store.all()[0])` is false when your pair points at something
*other than* the customer inside the store: a copy, or a local variable. Check that you
push references you got from iterating `self.customers` / `self.all()` directly, and that
nothing in your code builds new `Customer` values.

</details>

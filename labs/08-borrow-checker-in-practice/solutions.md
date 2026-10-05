# Lab 08 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. In this lab more than any other, the
> code is the small part. What matters is being able to name **which strategy** you used and
> **what conflict** it removed.

---

## Mini-task (Step 5): fix the re-add test without cloning

```rust
#[test]
fn re_adding_a_deleted_customer_gives_a_new_id() {
    let mut store = store_with_ada_and_grace();
    let removed = store.remove(1).unwrap();
    let new_id = store.add(removed.name, removed.email, removed.phone);
    assert_eq!(new_id, 3);
    assert_eq!(store.find(new_id).unwrap().name, "Ada Lovelace");
}
```

The borrow `old_name` existed only to remember a value **we already know**. Removing it
removes the conflict (strategy 1: no borrow survives the move). If the expected name weren't a
known constant (say, it came from user input), the honest options would be to compare
*before* moving, or to clone it deliberately (`let old_name = removed.name.clone();`),
which is strategy 9, a snapshot that must survive the move.

Note what the test also shows: `removed` is an **owned** `Customer`, so moving its three
fields out one by one is fine (a partial move of something you own). `removed` is never
used afterwards. And `Customer` no longer implements `Drop`, which is why this is allowed
(Lab 06, `E0509`).

---

## Your Turn 1: `normalize_emails` and the `normalize` command

```rust
// Strategy 6 (iter_mut): every customer may change and nothing else needs the
// store during the loop, so we hold exclusive access to each customer in turn and
// mutate in place. "Collect, then mutate" would walk the list twice and look each
// customer up again by id: two passes and n lookups to reach things we already held.
fn normalize_emails(&mut self) -> usize {
    let mut changed = 0;
    for customer in self.customers.iter_mut() {
        let lowercase = customer.email.to_lowercase();
        if lowercase != customer.email {
            customer.update_email(lowercase);
            changed += 1;
        }
    }
    changed
}
```

```rust
"normalize" => {
    let changed = store.normalize_emails();
    println!("Normalized emails: {changed} changed.");
}
```

**Reasoning:**

- `self.customers.iter_mut()` borrows **only the `customers` field** mutably (which is why
  `self.next_id` stays readable inside the loop: the split-borrow experiment). Each
  `customer` is a `&mut Customer`, and only one of them is alive at a time.
- `to_lowercase()` always allocates a new `String`. We keep it only if it differs: on the
  equal path, `lowercase` is dropped at the end of the iteration.
- `customer.update_email(lowercase)` **moves** the new string in and drops the old one. No
  clone anywhere.
- The method returns a `usize` (Copy), so the command gets its own number and holds no borrow
  of the store.

For comparison, the "collect, then mutate" version, which is correct but worse here:

```rust
fn normalize_emails(&mut self) -> usize {
    let mut ids = Vec::new();
    for customer in &self.customers {               // phase 1: shared borrow
        if customer.email.to_lowercase() != customer.email {
            ids.push(customer.id);                   // collect Copy ids, not references
        }
    }                                                // shared borrow ends here
    for id in &ids {                                 // phase 2: exclusive borrows, one at a time
        if let Some(customer) = self.find_mut(*id) {
            customer.update_email(customer.email.to_lowercase());
        }
    }
    ids.len()
}
```

It lowercases each changed email twice and does a linear `find_mut` per id (O(n²) in the
worst case). Collect-then-mutate shines when phase 2 needs **the whole collection** (e.g. to
check something across all customers before changing one), which `iter_mut` can't give you.

---

## Your Turn 2: tests

```rust
#[test]
fn remove_returns_the_owned_customer() {
    let mut store = store_with_ada_and_grace();
    match store.remove(1) {
        Some(customer) => assert_eq!(customer.name, "Ada Lovelace"),
        None => panic!("customer 1 should have been removed"),
    }
    assert_eq!(store.len(), 1);
    assert!(store.find(1).is_none());
}

#[test]
fn remove_unknown_id_returns_none_and_changes_nothing() {
    let mut store = store_with_ada_and_grace();
    assert!(store.remove(99).is_none());
    assert_eq!(store.len(), 2);
}

#[test]
fn remove_does_not_renumber_the_others() {
    let mut store = store_with_ada_and_grace();
    store.remove(1);
    assert_eq!(store.all()[0].id, 2);
    assert_eq!(store.find(2).unwrap().name, "Grace Hopper");
}

// re_adding_a_deleted_customer_gives_a_new_id: see the mini-task above.

#[test]
fn normalize_emails_lowercases_and_counts_changes() {
    let mut store = store_with_ada_and_grace();
    store.add(
        String::from("Alan Turing"),
        String::from("Alan@Example.COM"),
        String::new(),
    );
    assert_eq!(store.normalize_emails(), 1);
    assert_eq!(store.find(3).unwrap().email, "alan@example.com");
    assert_eq!(store.normalize_emails(), 0);
}
```

**Why these tests?** `remove_does_not_renumber_the_others` pins down the property that makes
ids safe handles: removing a customer shifts *positions* in the `Vec`, but never changes
*ids*. If someone "optimised" `remove` into something that renumbered, every id held
elsewhere (strategy 3) would silently point at the wrong customer. In `remove_returns_the_owned_customer`,
the `match` arm *owns* the removed customer: it's dropped at the end of that arm, while the
store has already moved on.

---

## Your Turn 3: the ownership review (one complete version)

| Function | Receiver / parameters | Returns | Why this access? | What if it were different? |
|---|---|---|---|---|
| `main` | none | `()` | owns the store (`let mut store`), the root of the whole ownership tree | n/a |
| `print_help` | none | `()` | reads only constants | n/a |
| `prompt` | `label: &str` | `String` | only *looks at* the label; returns **new** text the caller must own | returning `&str` → would point into a local that's dropped (Lab 10: E0106/E0515) |
| `customer_count_label` | `count: usize` | `String` | `usize` is `Copy`; builds new text | n/a |
| `next_id` | `current: u32` | `u32` | `Copy` in, `Copy` out | n/a |
| `update_customer` | `store: &mut CustomerStore`, `id: u32` | `()` | changes the store but must not consume it: `main` needs it for the next command | `store: CustomerStore` → **E0382** "moved … in previous iteration of loop" |
| `Customer::new` | `id: u32`, `name/email/phone: String` | `Self` | the customer must **own** its text, so take ownership; callers that already have `String`s hand them over for free | `&str` params → **E0308** at every caller; after fixing callers, it costs an extra allocation + copy per field (`to_string()` inside `new`) |
| `Customer::summary` | `&self` | `String` | only reads; returns new text | `self` → **E0507** "cannot move out of `*customer` which is behind a shared reference" in `list`/`show` |
| `Customer::has_phone` | `&self` | `bool` | only reads | — |
| `Customer::matches_email` | `&self`, `email: &str` | `bool` | only reads both sides | `email: String` → callers would have to give away (or clone) their string just to compare |
| `Customer::update_email` | `&mut self`, `email: String` | `()` | changes the customer; **keeps** the new email | `&self` → **E0594**; `email: &str` → would have to allocate a copy inside |
| `CustomerStore::new` | none | `Self` | creates and gives ownership away | — |
| `CustomerStore::add` | `&mut self`, three `String`s | `u32` | changes the store; keeps the strings; returns a `Copy` id, not a reference | returning `&Customer` → the caller's borrow would block the next mutation (strategy 3 says return the id) |
| `CustomerStore::all` | `&self` | `&Vec<Customer>` | lends a view of everything | `Vec<Customer>` → **E0507** (Lab 07 Experiment 1). Lab 09 changes this to `&[Customer]` |
| `CustomerStore::find` | `&self`, `id: u32` | `Option<&Customer>` | reads; lends one customer | `&mut self` → **E0596** in read-only tests (`let store`); callers couldn't hold two found customers at once |
| `CustomerStore::find_mut` | `&mut self`, `id: u32` | `Option<&mut Customer>` | hands out exclusive access to a part, so needs exclusive access to the whole | `&self` → impossible to produce a `&mut Customer` from a shared borrow |
| `CustomerStore::find_by_email` | `&self`, `email: &str` | `Option<&Customer>` | reads; result borrows from `self`, not from `email` | — |
| `CustomerStore::email_exists` | `&self`, `email: &str` | `bool` | reads; only looks at the email | `email: String` → **E0308** at `store.email_exists(&email)` and in tests; callers would have to give the email away |
| `CustomerStore::len` | `&self` | `usize` | reads; returns a `Copy` number | `self` → **E0382** (Lab 07 Experiment 2): counting would destroy the store |
| `CustomerStore::remove` | `&mut self`, `id: u32` | `Option<Customer>` | changes the store; **gives the removed customer away** | `bool` → caller can't print the name; `Option<&Customer>` → nothing left to point at |
| `CustomerStore::normalize_emails` | `&mut self` | `usize` | changes customers in place; returns a `Copy` count | — |

(The **E0xxx** codes in the last column are the real results of trying each alternative
against the Lab 08 code.)

**1. Which function takes ownership of the whole store?** None. `main` *creates* and owns it,
and everything else borrows it: `&mut` for `update_customer` and the mutating methods, `&`
for the readers. A function that took `CustomerStore` by value would consume the CRM's data.
You'll meet a legitimate version of that in Lab 25, when the CRM's state is moved *into* a
shared container that several threads hold.

**2. Signatures worth changing:**
- `all(&self) -> &Vec<Customer>` → `&[Customer]` (Lab 09). A `&Vec` exposes *how* the store
  keeps customers. A slice says "some customers, contiguous", so the same return type works
  for "page 2 of the customers", which Lab 09's `list [page]` needs.
- `update_customer(store: &mut CustomerStore, id: u32)` mixes I/O (prompts) with store logic.
  Later (Lab 12's `execute`, Lab 13's modules) that split gets cleaner: prompts in the CLI,
  rules in the store.

**3. `String` vs `&str` parameters:** `update_email(email: String)` is right because the
customer **keeps** the value; `matches_email(email: &str)` and `email_exists(email: &str)` are
right because they only **look**. The rule: *take `String` when you'll store it, `&str` when
you'll only read it.* `Customer::new` taking `&str` (alternative tried above) would force an
allocation in `new` even when the caller already had an owned `String` to give.

---

## 🧪 Experiment answers

**Experiment 1 (`retain`):** `retain(|c| c.id != id)` would delete the customer correctly, but
it **drops** the removed customer inside `retain`. Nothing is returned. `delete` would have to
look up the name *before* removing (an extra lookup plus a borrow to manage), and couldn't tell
"deleted" from "there was nothing to delete" without comparing lengths. `remove → Option<Customer>`
answers both questions with one value. `retain` is the right tool when you want to delete
*many* customers by a rule and don't need them back.

**Experiment 2 (index loop):** compiles, then panics at runtime. The compiler checks
references, not the meaning of numbers. That's why indices (and ids) trade compile-time
guarantees for flexibility, and why you use an index immediately (`remove` does) or prefer
`retain`.

**Experiment 3 (collision):** a domain bug, not a memory bug. Lab 12's `Email` type fixes it at
the source.

---

## ✅ Checkpoint answers

1. A reference's borrow lasts from where it's created to its **last use**, not to the end of
   the block (NLL). Example: Lab 07 Experiment 3, or Step 1's tests A vs B: same code, and
   only the position of the last use of `ada` decides whether the `add` overlaps it.
2. The `for` loop holds a shared borrow of `store` for the whole loop, and `remove` needs an
   exclusive one inside it (E0502). At runtime, `Vec::remove` shifts the later customers left:
   `customer` would refer to the *next* customer (printing the wrong name), and the iterator
   would skip an element and misjudge where the vec ends.
3. The caller needs the customer's data *after* the store has changed. Returning it **owned**
   means no borrow into the store is needed. `bool` throws the data away, and
   `Option<&Customer>` would point at something that's no longer in the store.
4. **E0507**: you only have a *borrow* and tried to move the value out. **E0505**: you *own* the
   value, but tried to move it while a borrow of it is still going to be used.
5. Holding a `&mut` to an element (find) while asking the collection a question (`&self`
   method), then mutating. Two-phase fix: do all the reading (lookups, validation, user input)
   with short shared borrows first; then take one exclusive borrow and write; connect the
   phases with an id.
6. An id is a `Copy` number. It borrows nothing, so it never blocks a mutation and can't
   dangle. What it *can't* guarantee: that the customer still exists when you use it, so every
   lookup by id returns `Option`.
7. Inside a function body the compiler tracks borrows **per field**: `iter_mut()` borrows
   `self.customers`, and `self.next_id` is a different field. `self.len()` is a method call
   with `&self`, which borrows the **whole** struct, including `customers`.
8. **Doesn't compile** (E0502): `first` is an `Option<&Customer>` borrowed from the store and
   used after `normalize_emails` (`&mut self`). Fix with strategy 2 (copy the id out first:
   `let first_id = store.all().first().map(|c| c.id);`) or strategy 1 (print before
   normalising).
9. **Compiles.** `remove` returned an **owned** `Option<Customer>`. `removed` borrows nothing
   from the store, so the `add` is free to mutate it. (`.map(|c| c.name)` consumes the customer
   and moves its name out, since `removed` is owned.)

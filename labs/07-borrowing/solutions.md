# Lab 07 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. For each solution, the important
> part is the **reasoning about access**: who reads, who writes, and for how long.

---

## Mini-task: `find_mut`

```rust
fn find_mut(&mut self, id: u32) -> Option<&mut Customer> {
    self.customers.iter_mut().find(|customer| customer.id == id)
}
```

`iter_mut()` borrows the vec **exclusively** and yields one `&mut Customer` per element.
`find` returns the first one that matches. Because the method borrowed `&mut self`, the
returned `&mut Customer` keeps the whole store exclusively borrowed for as long as the
caller uses it. That's what guarantees nobody else can read or write that customer (or
reallocate the vec under it) in the meantime.

If you wrote the `for customer in &mut self.customers { if … { return Some(customer); } } None`
version, it's correct, and Clippy's `manual_find` will point you to the one-liner.

---

## Your Turn 1: `update` changes name, email and phone

```rust
"update" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => match store.find_mut(id) {
            Some(customer) => {
                // Direct field assignment: these fields have no rules yet. Email gets a
                // method because it will get validation rules (Lab 12).
                let name = prompt("Name (blank to keep): ");
                if !name.is_empty() {
                    customer.name = name;
                }
                let email = prompt("Email (blank to keep): ");
                if !email.is_empty() {
                    customer.update_email(email);
                }
                let phone = prompt("Phone (blank to keep): ");
                if !phone.is_empty() {
                    customer.phone = phone;
                }
                println!("Updated customer #{id}");
            }
            None => println!("No customer with id {id}."),
        },
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

**Reasoning:**

- `customer` is a `&mut Customer` for the whole `Some` arm. The three `prompt` calls don't
  touch `store`, so holding the exclusive borrow across them is fine.
- `customer.name = name;` **moves** the new `String` into the field. The old name is dropped
  at that moment (assignment drops the previous value). No clone, no leak.
- If the input is blank, the new `String` (empty, so no heap allocation) simply goes out of
  scope at the end of the `if`.
- **Methods vs fields:** both are fine at this size, since `main` is in the same module and
  can see private fields. A method is worth having when the change has *rules*: today
  `update_email` is trivial, but it marks the one place where email changes happen. (In
  Lab 12 the email becomes a validated `Email` type, so the type itself enforces the rule,
  and in Lab 13 the *store's* fields become private, so its methods become the only way in.)

One subtle thing to notice (Lab 08 deals with it): this `update` doesn't check whether the
new email already belongs to another customer. Try adding `store.email_exists(&email)` inside
the `Some(customer)` arm and you'll meet the *find-then-mutate* problem.

---

## Your Turn 2: tests for the store

```rust
fn store_with_ada_and_grace() -> CustomerStore {
    let mut store = CustomerStore::new();
    store.add(
        String::from("Ada Lovelace"),
        String::from("ada@example.com"),
        String::from("555-0100"),
    );
    store.add(
        String::from("Grace Hopper"),
        String::from("grace@example.com"),
        String::new(),
    );
    store
}

#[test]
fn add_assigns_sequential_ids() {
    let mut store = store_with_ada_and_grace();
    let id = store.add(
        String::from("Alan Turing"),
        String::from("alan@example.com"),
        String::new(),
    );
    assert_eq!(id, 3);
    assert_eq!(store.len(), 3);
}

#[test]
fn find_returns_none_for_unknown_id() {
    let store = store_with_ada_and_grace();
    assert!(store.find(99).is_none());
}

#[test]
fn find_returns_the_matching_customer() {
    let store = store_with_ada_and_grace();
    match store.find(2) {
        Some(customer) => assert_eq!(customer.name, "Grace Hopper"),
        None => panic!("customer 2 should exist"),
    }
}

#[test]
fn find_mut_changes_are_visible_through_find() {
    let mut store = store_with_ada_and_grace();
    match store.find_mut(1) {
        Some(customer) => customer.update_email(String::from("ada@lovelace.dev")),
        None => panic!("customer 1 should exist"),
    }
    assert_eq!(store.find(1).unwrap().email, "ada@lovelace.dev");
}

#[test]
fn email_exists_matches_exact_email() {
    let store = store_with_ada_and_grace();
    assert!(store.email_exists("ada@example.com"));
    assert!(!store.email_exists("nobody@example.com"));
}
```

**`mut` or not?** You can read it straight off the signatures: a test that only calls `&self`
methods (`find`, `email_exists`, `len`) uses `let store`. A test that calls `add` or
`find_mut` (`&mut self`) needs `let mut store`. The compiler would tell you (E0596 one way, an
`unused_mut` warning the other way), but you shouldn't need it to.

**Two borrows, one after the other:** in `find_mut_changes_are_visible_through_find`, the
`&mut Customer` from `find_mut` is last used inside the `match`. By the time
`store.find(1)` runs, the exclusive borrow is over, so a shared borrow is allowed.
Sequential borrows are always fine; *overlapping* ones are what the rule forbids.

---

## Your Turn 3: `find_by_email`

```rust
// The returned &Customer borrows from `self` (the store), not from `email`.
// So the caller may drop or reuse the email string straight away, while still
// holding the customer, but may not modify the store while holding it.
fn find_by_email(&self, email: &str) -> Option<&Customer> {
    self.customers
        .iter()
        .find(|customer| customer.matches_email(email))
}

fn email_exists(&self, email: &str) -> bool {
    self.find_by_email(email).is_some()
}
```

```rust
#[test]
fn find_by_email_returns_the_owner_of_the_email() {
    let store = store_with_ada_and_grace();
    match store.find_by_email("grace@example.com") {
        Some(customer) => assert_eq!(customer.id, 2),
        None => panic!("grace should be found"),
    }
    assert!(store.find_by_email("nobody@example.com").is_none());
}
```

**Which input does the result borrow from?** From `self`. It's a reference to a customer that
lives in the store, and it has nothing to do with the `email` argument after the search is
done. The compiler applies a rule here: when a method takes `&self`, any reference it returns
is assumed to borrow from `self`. (That's one of the *lifetime elision rules*, Lab 10.) For
the caller this means:

```rust
let found = {
    let typed = prompt("Email: ");   // a temporary String
    store.find_by_email(&typed)      // borrows the STORE, not `typed`
};                                   // `typed` is dropped here, and `found` is still valid
```

**Why build `email_exists` on top?** One definition of "is there a customer with this email?"
in one place, which itself relies on one definition of "same email" (`Customer::matches_email`).
When the rules for comparing emails change (they will, in Lab 12), there's only one line to
change. `is_some()` turns "maybe a customer" into "is there a customer?".

---

## 🧪 Experiment answers

**Experiment 1** (`all` returning `Vec<Customer>`): `E0507`. A `&self` method has *borrowed*
the store. Returning `self.customers` by value would move the vec out of something you
don't own. The options are to return a borrow (what we do), clone the whole vec (expensive),
or take `self` by value (which consumes the store).

**Experiment 2** (`len(self)`): `E0382` at the *next* use of `store`, "moved due to this
method call, in previous iteration of loop". A `self` receiver consumes the store, so
counting would destroy it.

**Experiment 3** (`store.len()` while holding the `&mut Customer`):

```text
error[E0502]: cannot borrow `store` as immutable because it is also borrowed as mutable
   --> src/main.rs:168:64
    |
165 |                     Ok(id) => match store.find_mut(id) {
    |                                     ----- mutable borrow occurs here
...
168 |                             println!("Store has {} customers", store.len());
    |                                                                ^^^^^ immutable borrow occurs here
169 |                             customer.update_email(email);
    |                             -------- mutable borrow later used here
```

Moving the `println!` **after** `customer.update_email(email);` makes it compile, even though
it's still textually inside the `match store.find_mut(id)` block. A borrow lasts until its
**last use**, not until the closing brace. After `update_email`, `customer` is never used
again, so the exclusive borrow of `store` is already over and `store.len()` can take a shared
one. This is *non-lexical lifetimes* (NLL), the first topic of Lab 08.

---

## ✅ Checkpoint answers

1. An address (8 bytes on 64-bit). At compile time: the customer outlives every use of the
   reference, and nobody mutates it (or moves it, or reallocates the vec holding it) while the
   reference is still to be used.
2. *Any number of shared references or exactly one mutable reference, never both at once.*
   `add` pushes into the vec. If the vec is full, `push` **reallocates**: it copies every
   customer to a new buffer and frees the old one. A `&Customer` held across that would point
   into freed memory, so the compiler forbids any `&mut` use of the store while a shared
   borrow from it is still going to be used.
3. Because it hands out a `&mut Customer` that points *into* the store. Exclusive access to a
   part requires exclusive access to the whole. Otherwise two `&CustomerStore` holders could
   each get a `&mut` to the same customer.
4. `E0502`: a shared and a mutable borrow overlap (holding `&store.all()[0]` across
   `store.add(...)`). `E0499`: two mutable borrows overlap (`find_mut(1)` and `find_mut(2)`
   both alive).
5. (a) `let store` without `mut`, then calling a `&mut self` method: the **owner** wasn't
   declared mutable. (b) Calling `update_email` (`&mut self`) through the `&Customer` that
   `find` returned: you **only had a shared borrow** and can't upgrade it.
6. `len` ✅, `find` ✅, `email_exists` ✅ (all `&self`). `find_mut` ❌ and `add` ❌ (both need
   `&mut self`).
7. **Compiles.** `len()` returns a `usize`, which is `Copy`. `count` is an independent number
   and borrows nothing, so the `add` is free to mutate.
8. **Doesn't compile:** `E0502`. `all` is a `&Vec<Customer>` borrowed from `store`, and it's
   used after the `add`. Moving the `println!` above the `add` fixes it.

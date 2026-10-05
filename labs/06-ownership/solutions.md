# Lab 06 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't need to match
> character for character. What matters is that you can explain **who owns what** at
> every line. Each solution explains the reasoning, not just the code.

---

## Mini-task: `impl Drop for Customer`

```rust
// TEMPORARY (Lab 06): remove before committing
impl Drop for Customer {
    fn drop(&mut self) {
        println!("[drop] #{} {}", self.id, self.name);
    }
}
```

**Why `&mut self` and not `self`?** If `drop` took `self` by value, then `self` would go out
of scope at the end of `drop`… which would call `drop` again, forever. Rust calls `drop` on
a value that's *about to be destroyed*, lets you look at (or tidy up) its fields through
`&mut self`, and then frees the fields itself. You never call `x.drop()` directly; the
compiler forbids it (E0040). To destroy something early, use `drop(x)`, which moves `x` into
a function that does nothing with it.

---

## Your Turn 1: duplicate check around the owned `Customer`

```rust
"add" => {
    let customer = read_new_customer(next_customer_id);

    let mut duplicate = false;
    for existing in &customers {
        if existing.matches_email(&customer.email) {
            duplicate = true;
            break;
        }
    }
    if duplicate {
        println!("A customer with email {} already exists.", customer.email);
        // `customer` was never moved, so it is dropped right here.
        continue;
    }

    println!("Added customer #{}", customer.id);
    customers.push(customer);
    next_customer_id = next_id(next_customer_id);
}
```

**Reasoning, line by line:**

- `for existing in &customers` iterates over **borrowed** customers. Checking an email doesn't
  need to own anything, and taking ownership (`for existing in customers`) would consume the
  list (Step 8's bug).
- `existing.matches_email(&customer.email)` lends the new customer's email to a `&self` method
  that takes `email: &str`. It only *looks*: nothing moves, and both customers stay intact.
  (`&customer.email` is a `&String`. Rust converts it to the `&str` the method wants. Lab 09
  explains that conversion.) And `matches_email` has a caller again, so its "never used"
  warning from Step 4 disappears.
- On the reject path, `continue` leaves the `add` arm early. `customer` is still the owner at
  that moment, so it's dropped right there, which is why `[drop] #2 Ada Again` prints straight
  after the message. Nothing leaks, and there's nothing to clean up by hand. The same thing
  happens if you write it with `if … else` instead of `continue`.
- `next_customer_id` advances **only** on the success path, so the rejected customer's id is
  reused. The rejected `Customer` *did* carry id 2 for a moment, but it never escaped the arm.
- `println!` comes before `push` (Step 6, Fix A), so `customer.id` is still readable.

**The `HashSet` question** (only if you used one in Lab 05). If you kept
`emails: HashSet<String>` alongside the `Vec`, each email would need **two owners**: the
`Customer` (in `customer.email`) and the set. One `String` can't have two owners, so you'd
write `emails.insert(customer.email.clone())`, an extra allocation per customer, plus two copies
that can drift apart (update one email later and forget the other). Scanning the `Vec` is O(n),
but with one source of truth. For a few thousand customers in memory, that's the right trade.
(Indexes come back later in the course, when they actually earn their place, and the database
gives you real ones.)

---

## Your Turn 2: `sample_customers()` and ownership tests

```rust
fn sample_customers() -> Vec<Customer> {
    vec![
        Customer::new(
            1,
            String::from("Ada Lovelace"),
            String::from("ada@example.com"),
            String::from("555-0100"),
        ),
        Customer::new(
            2,
            String::from("Grace Hopper"),
            String::from("grace@example.com"),
            String::new(),
        ),
        Customer::new(
            3,
            String::from("Alan Turing"),
            String::from("alan@example.com"),
            String::from("555-0300"),
        ),
    ]
}

#[test]
fn sample_customers_has_three_customers_in_order() {
    let customers = sample_customers();
    assert_eq!(customers.len(), 3);
    assert_eq!(customers[0].id, 1);
    assert_eq!(customers[1].id, 2);
    assert_eq!(customers[2].id, 3);
}

#[test]
fn pop_gives_ownership_back() {
    let mut customers = sample_customers();
    let last = customers.pop();
    match last {
        Some(customer) => assert_eq!(customer.name, "Alan Turing"),
        None => panic!("expected a customer"),
    }
    assert_eq!(customers.len(), 2);
}

#[test]
fn moving_a_customer_into_another_vec() {
    let mut active = sample_customers();
    let mut archived = Vec::new();
    let grace = active.remove(1);
    archived.push(grace);
    assert_eq!(active.len(), 2);
    assert_eq!(archived.len(), 1);
    assert_eq!(archived[0].name, "Grace Hopper");
}
```

**Why aren't the strings dropped when `sample_customers` returns?** Because they aren't owned
by a *local variable* of `sample_customers` when it ends. They're owned by the `Customer`s,
which are owned by the `Vec`, which is the **return value**. Returning moves the `Vec`'s
24-byte handle to the caller, and the whole ownership tree comes with it. Nothing on the
heap moves.

**`pop` and `remove` return `T`, not `&T`.** Both *take an element out* of the collection,
so the caller must become its owner. That's ownership leaving a collection. `pop` returns
`Option<Customer>` because the vec might be empty; `remove(index)` returns `Customer` directly
and **panics** if the index is out of range. In Lab 08 your store's `remove(id)` follows the
same idea but returns `Option<Customer>`, because "no customer with that id" is a normal
situation in a CRM, not a bug.

**What `--nocapture` showed (with `Drop` still in):** in `moving_a_customer_into_another_vec`,
Grace is dropped when `archived` goes out of scope, not when she left `active`. Moving her
out of one vec and into another never destroyed her.

> Note: `vec![...]` instead of `Vec::new()` + three `push`es is also what Clippy suggests
> (`vec_init_then_push`) if you run `cargo clippy --all-targets`, which checks test code too.

---

## Your Turn 3: `into_names` and `E0509`

```rust
// Consumes the list: the caller gives us the customers and gets their names back.
// With `impl Drop for Customer` this fails with E0509: Drop::drop must receive a
// *complete* Customer, so Rust won't let us move a field out of one.
fn into_names(customers: Vec<Customer>) -> Vec<String> {
    let mut names = Vec::new();
    for customer in customers {
        names.push(customer.name);
    }
    names
}

#[test]
fn into_names_consumes_the_list() {
    let names = into_names(sample_customers());
    assert_eq!(names, vec!["Ada Lovelace", "Grace Hopper", "Alan Turing"]);
}
```

**How it works without `Drop`:**

- `for customer in customers` consumes the `Vec`: each iteration *moves* one `Customer` into
  the loop variable. You own it.
- `customer.name` is a **partial move**: you take the `name` field out. The rest of the
  customer (`email`, `phone`) is dropped at the end of the iteration. The moved-out name
  isn't, because it now belongs to `names`.
- No clone: each name's heap buffer is reused as is. The 24-byte handle just moves into a
  different vec.

**Why `E0509` with `Drop`:** when a type implements `Drop`, Rust promises that `drop(&mut self)`
will be called on a **whole, valid value**. Your `drop` reads `self.name`! If you could move
`name` out first, `drop` would read a string that now belongs to someone else (or has already
been freed). So for `Drop` types, partial moves out are forbidden. You can still *borrow*
fields, or clone them. This is also why types that implement `Drop` can never be `Copy`.

**`Vec<Customer>` vs `&Vec<Customer>` in the signature:** `into_names(customers: Vec<Customer>)`
says "give me the list; you won't have it afterwards, but you get the names". That's honest,
because it really does dismantle the customers. A `names(customers: &Vec<Customer>)` version
would promise to *leave the list intact*, so it could only return borrowed names (Lab 10) or
clones. The signature tells the caller what they're giving up. Rust calls this naming
pattern `into_*`: `into_iter`, `into_bytes`, `into_names`.

---

## 🧪 Experiment answers

### Experiment 1

**(a) compiles.** `let id = customer.id;` copies a `u32` (Copy). Then `customer` is moved into
the vec, and printing `id` uses the independent copy. This is Fix B from Step 6.

**(b) fails.** `let name = customer.name;` *moves* the `String` out of the customer (a
partial move). With your `Drop` impl still in place you get `E0509`:

```text
error[E0509]: cannot move out of type `Customer`, which implements the `Drop` trait
  --> src/main.rs:84:28
   |
84 |                 let name = customer.name;
   |                            ^^^^^^^^^^^^^
   |                            |
   |                            cannot move out of here
   |                            move occurs because `customer.name` has type `String`, which does not implement the `Copy` trait
   |
help: consider borrowing here
   |
84 |                 let name = &customer.name;
   |                            +
```

Without `Drop`, the partial move itself is allowed, but then pushing the incomplete customer
isn't:

```text
error[E0382]: use of partially moved value: `customer`
  --> src/main.rs:80:32
   |
78 |                 let name = customer.name;
   |                            ------------- value partially moved here
79 |                 println!("Adding {name}");
80 |                 customers.push(customer);
   |                                ^^^^^^^^ value used here after partial move
   |
   = note: partial move occurs because `customer.name` has type `String`, which does not implement the `Copy` trait
```

Four questions: `customer` owns the name → `let name = …` moved it → the push needs the
*whole* customer → the customer is incomplete, so it can't be stored. Fix: print
`customer.name` directly (`println!` only borrows), or borrow it: `let name = &customer.name;`.
That's Lab 07, and it works as long as you're done with `name` before the push.

**(c) compiles.** `id` is a `u32` copy of `next_customer_id`; passing it to
`read_new_customer` and to `next_id` copies it again each time.

### Experiment 2

```text
error[E0382]: borrow of moved value: `name`
   --> src/main.rs:138:24
    |
134 |     let name = prompt("Name: ");
    |         ---- move occurs because `name` has type `String`, which does not implement the `Copy` trait
...
137 |     let customer = Customer::new(id, name, email, phone);
    |                                      ---- value moved here
138 |     println!("Created {name}");
    |                        ^^^^ value borrowed here after move
    |
note: consider changing this parameter type in method `new` to borrow instead if owning the value isn't necessary
   --> src/main.rs:14:27
    |
 14 |     fn new(id: u32, name: String, email: String, phone: String) -> Self {
    |        --- in this method ^^^^^^ this parameter takes ownership of the value
```

`name` was moved into `Customer::new`'s `name: String` parameter on line 137. The note
suggests making `new` borrow, but **owning is necessary here**: a `Customer` must own its
name, or it would be pointing at text owned by someone else. So the note doesn't apply.
The right fixes are to print `customer.name` (borrowing it through its new owner) or print
before constructing.

---

## ✅ Checkpoint answers

1. **Stack:** one 24-byte `Vec` handle (ptr, len 2, cap ≥ 2). **Heap:** one buffer holding two
   80-byte `Customer`s side by side, plus three string buffers per customer. That's
   **1 + 2 × 3 = 7 heap allocations**. (One subtlety: an empty `String::new()` doesn't allocate
   at all, so a customer with no phone needs one fewer.)
2. `push` copies the customer's **80 stack bytes** (id + three string handles) into the next
   free slot of the vec's buffer (reallocating the buffer first if it's full) and increments
   `len`. The string **contents** on the heap are not copied, and the old `customer` variable
   becomes unusable.
3. Both would hold the same three heap pointers, both would be dropped at the end of the
   scope, and each heap buffer would be freed twice: a double free, which means memory
   corruption. Invalidating the source is a zero-cost, compile-time guarantee of one owner,
   one free.
4. A `u32` owns no other memory, so a bitwise copy is a complete, independent value. A `String`'s
   bitwise copy would share its heap buffer. `Customer` can only be `Copy` if all its fields
   are, so not while it contains a `String`.
5. `for c in customers` calls `into_iter()`, which **consumes** the vec: each `c` is an owned
   `Customer`, and the list is gone afterwards. `for c in &customers` borrows the vec: each
   `c` is a `&Customer`, and the list is untouched.
6. "Do you actually need **two independent copies**, or did you just need to *look* at it /
   use it before moving it?" and "What does the clone cost (how many allocations), and how
   often does this code run?"
7. **Compiles.** `summary()` borrows `customer` just long enough to build a **new, owned**
   `String`. `summary` doesn't depend on `customer` afterwards, so moving `customer` into the
   vec is fine.
8. Locals are dropped in reverse declaration order: `c` first, then `list` (which drops `b`
   inside it), then `a`. With the `Drop` impl that prints `[drop] #3 C`, `[drop] #2 B`,
   `[drop] #1 A`. Note that `b` was moved into `list`, so the variable `b` owns nothing when
   the scope ends. It's dropped as part of `list`.

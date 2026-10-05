# Lab 05 — Solutions

> 🔴 **SOLUTION**. Only read this after a genuine attempt.

---

## 🔵 Your Turn 1 — The `count` command, test-first

### 1. The test (written first)

Inside `mod tests`:

```rust
    #[test]
    fn customer_count_label_uses_singular_only_for_one() {
        assert_eq!(customer_count_label(0), "0 customers");
        assert_eq!(customer_count_label(1), "1 customer");
        assert_eq!(customer_count_label(3), "3 customers");
    }
```

`cargo test` before the function exists:

```text
error[E0425]: cannot find function `customer_count_label` in this scope
   --> src/main.rs:179:20
    |
179 |         assert_eq!(customer_count_label(0), "0 customers");
    |                    ^^^^^^^^^^^^^^^^^^^^ not found in this scope
```

(…three times.) That's the "red" step of *red → green → refactor*. In a compiled language,
"red" is often a compile error rather than a failing assertion. The test has already done a
job: it fixed the function's **name, parameter type and return type** before you wrote it.

### 2. The function (below `prompt`)

```rust
fn customer_count_label(count: usize) -> String {
    if count == 1 {
        String::from("1 customer")
    } else {
        format!("{count} customers")
    }
}
```

### 3. The command and help row

```rust
            "count" => println!("{}", customer_count_label(customers.len())),
```

```rust
        ("count", "Show how many customers there are"),
```

### Why it's written this way

- **`usize`** because `customers.len()` returns `usize`, the type Rust uses for sizes and
  indexes. Rust **never converts integer types implicitly**. A `u32` parameter would force
  `customers.len() as u32` at the call site, a conversion that could silently truncate on some
  platforms. Matching the type the data already has is the honest choice.
- **`if` as the whole body**: both branches are `String`. The singular branch can't be
  `"1 customer"` alone, because that's a `&str`, and the branches must have the same type
  (Lab 03's `if`/`else` error again).
- **Why a separate function at all?** You could write the `if` directly inside the `count` arm.
  But then you couldn't test it without typing into the REPL. Pulling the decision into a
  pure function made it testable in three lines. Keep that habit: **logic in functions, I/O in
  the loop.**
- `0 customers` is plural in English, and the test pins that down. Edge cases like `0` and `1`
  are exactly what tests are for.

---

## 🔵 Your Turn 2 — Reject duplicate emails

### Scanning the `Vec` (recommended)

The `add` arm becomes:

```rust
            "add" => {
                let name = prompt("Name: ");
                let email = prompt("Email: ");

                // Scan the Vec rather than keeping a HashSet: one source of truth, and at
                // CRM-in-a-terminal sizes a linear scan is instant.
                let mut duplicate = false;
                for customer in &customers {
                    if customer.matches_email(&email) {
                        duplicate = true;
                        break;
                    }
                }
                if duplicate {
                    println!("A customer with email {email} already exists.");
                    continue;
                }

                let phone = prompt("Phone: ");

                let customer = Customer::new(next_customer_id, name, email, phone);
                customers.push(customer);
                println!("Added customer #{next_customer_id}");
                next_customer_id = next_id(next_customer_id);
            }
```

### Why it's written this way

- **Check after the email, before the phone**: don't make people type data you're going to
  throw away.
- **`break` inside the `for`** stops scanning at the first match. A `break` leaves the
  **innermost** loop, so this one leaves the `for`, not the REPL's `loop`. That's why we need
  the `duplicate` flag to carry the answer out.
- **`continue`** in the `if duplicate` block skips straight to the next prompt. Because it jumps
  over `count += 1` at the bottom of the REPL loop, a rejected `add` isn't counted, and
  because it jumps over `next_id`, no ID is used up. That's the Lab 03 lesson, *control flow as
  specification*, at work again.
- **`&email`**: `email` is a `String`, and `matches_email` wants `&str`. `&email` is a
  `&String`, and Rust automatically treats a `&String` as a `&str` where one is needed
  (*deref coercion*, covered in Lab 09). We **borrow** `email` for the check, so we still own
  it afterwards, ready to move into `Customer::new`.
- **Why the Vec scan wins (for now)**: the CRM holds dozens of customers, and scanning them
  takes microseconds. A `HashSet` would be a second copy of every email that must stay in sync.
  Lab 07 adds `update` (emails can change) and Lab 08 adds `delete`, and each would need to
  remember to update the set. Choose the design with **one source of truth** until measurements
  say otherwise. (In Lab 07 this scan moves into a store method, `email_exists`, so the rule
  lives in one place.)

### Shorter version, for later

```rust
                if customers.iter().any(|c| c.matches_email(&email)) {
                    println!("A customer with email {email} already exists.");
                    continue;
                }
```

`iter().any(...)` with a **closure** (`|c| ...`) is idiomatic Rust, and it compiles and is
Clippy-clean here. It's exactly the loop above in one line. Iterators and closures are Lab 17's
topic, so it's fine (even good) to have written the explicit loop first. You'll appreciate what
`any` does for you once you've written it by hand.

### The `HashSet` alternative, and its cost

```rust
use std::collections::HashSet;
// ...
    let mut known_emails: HashSet<String> = HashSet::new();
// ... in add:
                if known_emails.contains(&email) {
                    println!("A customer with email {email} already exists.");
                    continue;
                }
                // ...
                known_emails.insert(email.clone());
                let customer = Customer::new(next_customer_id, name, email, phone);
```

This works and is faster for huge lists, but notice what it costs:

- **`email.clone()`**: the set needs its own copy, because the customer is going to *own*
  `email`. One value can't have two owners (Lab 06), so you pay for a second allocation.
- **Two sources of truth**: every future change to emails must touch both collections.
- **`matches_email` becomes unused again**, so you'd get a dead-code warning (the acceptance
  criteria asked you to use it).

If you chose the set and justified it, that's a valid engineering decision. Just be ready to
keep it in sync in Labs 07–08, or to switch to the scan when the store arrives.

---

## 🔵 Your Turn 3 — Test the methods you wrote in Lab 04

```rust
    #[test]
    fn has_phone_is_true_when_phone_is_present() {
        assert!(ada().has_phone());
    }

    #[test]
    fn has_phone_is_false_when_phone_is_empty() {
        let customer = Customer::new(
            2,
            String::from("Alan Turing"),
            String::from("alan@example.com"),
            String::new(),
        );
        assert!(!customer.has_phone());
    }

    #[test]
    fn matches_email_compares_exactly() {
        let customer = ada();
        assert!(customer.matches_email("ada@example.com"));
        assert!(!customer.matches_email("grace@example.com"));
        assert!(!customer.matches_email("ADA@example.com"));
    }
```

```text
running 7 tests
test tests::customer_count_label_uses_singular_only_for_one ... ok
test tests::has_phone_is_false_when_phone_is_empty ... ok
test tests::matches_email_compares_exactly ... ok
test tests::has_phone_is_true_when_phone_is_present ... ok
test tests::next_id_adds_one ... ok
test tests::summary_leaves_out_a_missing_phone ... ok
test tests::summary_shows_id_name_email_and_phone ... ok

test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

### Why it's written this way

- **`assert!` for booleans**: `assert_eq!(customer.has_phone(), true)` works, but Clippy flags it
  (`bool_assert_comparison`). `assert!(x)` / `assert!(!x)` reads as the claim itself.
- **The `ADA@example.com` case documents a decision.** Right now emails are case-sensitive.
  In Lab 12 the `Email` type lowercases addresses, and this test will need to change. That's the
  point: when behaviour changes *on purpose*, a test forces you to notice and update the record.
  When it changes *by accident*, the test catches it.
- **Several asserts in one test vs one per test**: both are fine. Group asserts that describe
  *one* behaviour ("compares exactly"). Split when they're different behaviours, so a failure
  name tells you which one broke.
- The two "Alan" customers (here and in `summary_leaves_out_a_missing_phone`) are a hint that a
  second helper (`fn no_phone_customer() -> Customer`) might be worth it. Two copies is fine,
  but at three, extract.

---

## 🧪 Experiment answers

### Step 7 and Step 8 experiments

Covered in the lab text. The key takeaways: `v[i]` panics on a missing index, while `.get(i)` /
`.first()` return an `Option` you must handle. A test that only passes in debug builds (the
`should_panic` overflow test) is testing the build profile, not your code.

### Experiment 1 — a test with no assertions

It passes. A test fails only if it **panics**. A test that builds `ada()` and checks nothing
proves only that `Customer::new` doesn't crash. "All tests pass" is only as meaningful as the
assertions inside them. That's why the lab had you *watch a test fail* before trusting it.

### Experiment 2 — `println!` before `push`, and `customer.id` after `push`

Moving the `println!("Added customer #{next_customer_id}")` above the `push` changes nothing:
it uses `next_customer_id`, which `push` never touches.

Printing `customer.id` **after** `customers.push(customer)` fails:

```text
error[E0382]: borrow of moved value: `customer`
  --> src/main.rs:83:48
   |
81 |                 let customer = Customer::new(next_customer_id, name, email, phone);
   |                     -------- move occurs because `customer` has type `Customer`, which does not implement the `Copy` trait
82 |                 customers.push(customer);
   |                                -------- value moved here
83 |                 println!("Added customer #{}", customer.id);
   |                                                ^^^^^^^^^^^ value borrowed here after move
```

A reasonable guess at this point: *"`push` took the customer. The vector owns it now, so the
variable `customer` is empty and can't be used."* That's essentially right. Lab 06 opens with
this exact error, explains **move** semantics properly, and compares three fixes (and why
"just `.clone()` it", which the compiler's note suggests, is the most expensive one).

### Experiment 3 — an empty name

The CRM happily adds `#3  <x@example.com>` (note the double space). Nothing checks the input.
It's a bug, yes, but a *validation* bug, and validation gets a whole design in **Lab 12**:
a `ValidationError` type, `Result`, and an `Email` type that can't hold an invalid address.
Until then, the CRM trusts its user.

---

## ✅ Checkpoint answers

1. `customers` and `next_customer_id` must survive across commands for the whole session, so
   they live outside the loop. `input` must be fresh each iteration (`read_line` appends), so
   it lives inside.
2. `customers[0]` **panics** (index out of bounds) and `customers.get(0)` returns `None`. For
   anything a user typed, use `.get()`: a missing customer is a normal situation, not a reason
   to crash the program.
3. `line.trim()` is a `&str` view into `line`, which is destroyed when `prompt` returns. The
   view can't outlive what it points into, so we copy the trimmed text into a new owned
   `String` with `.to_string()` and return that.
4. It compiles the module only for `cargo test`, keeping test code out of the real binary. The
   test module is a separate (child) module, and `use super::*;` brings the parent module's
   items (`Customer`, `next_id`, …) into scope.
5. A test passes when it **returns without panicking**, and fails when it **panics** (which is
   what a failed `assert!`/`assert_eq!` does).
6. Faster: "is this email taken?" no longer scans every customer. Risk: a second source of truth
   that must be kept in sync on every add, update and delete. (It also costs a cloned `String`
   per customer.)

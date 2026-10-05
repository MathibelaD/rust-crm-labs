# Lab 08 — The Borrow Checker in Practice ♻️

> **Phase:** 2 — Ownership & Borrowing · **Builds on:** Lab 07 · **Time:** ~4 hours
> **Your repo before this lab:** tag `lab-07` · **After:** tag `lab-08`

> This lab assumes you completed **Your Turn 1** (`update` with name/email/phone and
> "blank to keep") and **Your Turn 3** (`find_by_email`) in Lab 07. See its `solutions.md` if not.

## 🎯 Goal
Add the two features that fight the borrow checker hardest, `delete <customer>` and "normalise
every email to lowercase", and rework `update` so it refuses an email that belongs to someone
else. Then step back and review **every function you've written** and the ownership
decision in its signature.

## 🧠 What You'll Learn
- Non-lexical lifetimes (NLL): where a borrow *actually* ends
- Iterating while mutating: `E0502` inside loops, and what would go wrong at runtime
- Returning **owned** values out of a `&mut self` method (`remove → Option<Customer>`)
- Moving out of a borrow (`E0507`) and moving while borrowed (`E0505`)
- The *find-then-mutate* problem, and the two-phase "read, then write" fix
- `iter_mut`, `retain`, split borrows of struct fields, and when cloning is the honest answer
- Why indices are "references the compiler can't check"
- A catalogue of fix strategies you'll reuse for the rest of the course

## 🔨 What We're Building

```text
crm> delete
Customer id: 1
Deleted customer #1 (Ada Lovelace)
crm> normalize
Normalized emails: 2 changed.
```

```rust
impl CustomerStore {
    fn remove(&mut self, id: u32) -> Option<Customer>   // hands back the owned customer
    fn normalize_emails(&mut self) -> usize            // lowercases emails, returns how many changed
}
```

Plus a reworked `update` that checks for duplicate emails, and an **ownership review**
document in your repo.

Labs 06 and 07 introduced the rules one at a time. This lab is about real code, where
several borrows interact, and where the first design that comes to mind (the one you'd
write in JavaScript) is the one the compiler rejects. Every time, the rejection points at a
real bug or a real design problem. Your job is to work out which.

---

## Step 1 — Where a borrow really ends

In Lab 07's Experiment 3 you moved one line, and an `E0502` vanished, even though the line
was still inside the `match store.find_mut(id)` block. That's because a borrow doesn't last
until the closing `}`. It lasts **until its last use**. The compiler computes, for every
reference, the region of code where it's still *live* (could still be used later), and
only checks for conflicts inside that region. This is called **non-lexical lifetimes (NLL)**,
because the borrow's lifetime doesn't follow the lexical `{ }` structure. Rust has worked
this way since 2018. Older Stack Overflow answers may predate it.

> 🟡 **EXPERIMENT**: predict, for each test, **compiles or not**? Write down A/B/C answers
> first. Then add all three to `mod tests` (you have `store_with_ada_and_grace()` from
> Lab 07) and run `cargo test`.

```rust
#[test]
fn nll_a() {
    let mut store = store_with_ada_and_grace();
    let ada = store.find(1).unwrap();
    println!("{}", ada.name);
    store.add(
        String::from("Alan Turing"),
        String::from("alan@example.com"),
        String::new(),
    );
}

#[test]
fn nll_b() {
    let mut store = store_with_ada_and_grace();
    let ada = store.find(1).unwrap();
    store.add(
        String::from("Alan Turing"),
        String::from("alan@example.com"),
        String::new(),
    );
    println!("{}", ada.name);
}

#[test]
fn nll_c() {
    let mut store = store_with_ada_and_grace();
    let name_length = store.find(1).unwrap().name.len();
    store.add(
        String::from("Alan Turing"),
        String::from("alan@example.com"),
        String::new(),
    );
    println!("{name_length}");
}
```

<details><summary>What really happens</summary>

Only **B** fails:

```text
error[E0502]: cannot borrow `store` as mutable because it is also borrowed as immutable
   --> src/main.rs:415:9
    |
414 |           let ada = store.find(1).unwrap();
    |                     ----- immutable borrow occurs here
415 | /         store.add(
416 | |             String::from("Alan Turing"),
417 | |             String::from("alan@example.com"),
418 | |             String::new(),
419 | |         );
    | |_________^ mutable borrow occurs here
420 |           println!("{}", ada.name);
    |                          -------- immutable borrow later used here
```

Draw each test as a timeline of borrows:

```text
 A:  let ada = store.find(1)…   ●━━━━━━━┓  shared borrow of `store` (live)
     println!(ada.name)                 ┃  ← last use of `ada`: borrow ENDS here
     store.add(…)               ◆          exclusive borrow: no overlap ✅

 B:  let ada = store.find(1)…   ●━━━━━━━━━━━━━━━━━━┓
     store.add(…)               ◆ ← overlaps!       ┃  💥 E0502
     println!(ada.name)                             ┃  ← last use is AFTER the add

 C:  let name_length = …len()   ● (borrow lives only inside this expression)
                                   name_length is a usize (Copy): it borrows nothing
     store.add(…)               ◆  ✅
     println!(name_length)
```

`ada` in A and B is the **same code**. Only the position of the last use differs. In C, you
copied out the one number you needed, so no borrow survives the statement at all.

</details>

Delete the three tests. The lesson to keep: **when you get a borrow error, look for the
"later used here" label**. Often the fix is to finish with a reference before you mutate,
or to copy out what you need.

---

## Step 2 — `delete`, first draft: iterating while mutating

Here's `delete` written the way it would be in many languages: walk the list, find the
customer, remove it, print a confirmation.

> 🟡 **EXPERIMENT**: add this arm to the command `match`, just before the `"quit" | "exit"` arm (and keep reading. `store.remove`
> doesn't exist yet, so first add a placeholder to `impl CustomerStore`):
>
> ```rust
> // placeholder, replaced in Step 3
> fn remove(&mut self, id: u32) -> Option<Customer> {
>     let _ = id;
>     None
> }
> ```

```rust
"delete" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => {
            for customer in store.all() {
                if customer.id == id {
                    store.remove(id);
                    println!("Deleted customer #{} ({})", customer.id, customer.name);
                }
            }
        }
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

Predict: will this compile? If not, *which* rule does it break?

```text
error[E0502]: cannot borrow `store` as mutable because it is also borrowed as immutable
   --> src/main.rs:199:33
    |
197 |                           for customer in store.all() {
    |                           -               -----------
    |                           |               |
    |                           |               immutable borrow occurs here
    |  _________________________|               immutable borrow later used here
    | |
198 | |                             if customer.id == id {
199 | |                                 store.remove(id);
    | |                                 ^^^^^^^^^^^^^^^^ mutable borrow occurs here
200 | |                                 println!("Deleted customer #{} ({})", customer.id, customer.name);
201 | |                             }
202 | |                         }
    | |_________________________- this for loop borrows `store` immutably, preventing mutation within its body
    |
    = help: consider using an index-based loop instead, or collecting modifications into a separate collection
```

**Reasoning script:**

1. **Who owns it?** The store owns every customer.
2. **Moved?** No.
3. **Borrows?** `store.all()` creates a shared borrow that the `for` loop keeps alive for the
   **whole loop**: the iterator needs it to fetch the next element on every pass ("immutable
   borrow later used here" points at the loop itself). `customer` is a `&Customer` into the
   vec. `store.remove(id)` needs `&mut store` *inside* that loop.
4. **How long must the shared borrow live?** Until the loop finishes. The mutable borrow is
   in the middle of it. Overlap.

### What would actually happen if this compiled?

`Vec::remove(index)` takes the element out and **shifts everything after it one slot left**.
Say we delete Ada (#1) from `[Ada, Grace, Alan]`:

```text
 before remove                          after remove(0)
 ┌──────────┬──────────┬──────────┐     ┌──────────┬──────────┬──────────┐
 │ #1 Ada   │ #2 Grace │ #3 Alan  │     │ #2 Grace │ #3 Alan  │ (stale)  │   len 3 → 2
 └──────────┴──────────┴──────────┘     └──────────┴──────────┴──────────┘
   ▲                                      ▲
 customer (&Customer)                   customer: SAME address, now pointing at Grace
 iterator: "next is slot 1"             iterator: "next is slot 1" → Alan. Grace is skipped,
                                        and the iterator's idea of the end is now wrong.
```

- The confirmation would print **`Deleted customer #2 (Grace Hopper)`**: right slot,
  wrong customer.
- And Ada herself? `remove` returned her, and we ignored the return value, so she was dropped
  before we printed anything. The reference we print from points at a customer who no
  longer exists in that place.

JavaScript developers know a cousin of this bug: calling `array.splice(i, 1)` inside a
`forEach`/index loop skips the next element. In JS it's a logic bug you find in production.
In Rust it doesn't compile.

The compiler's `help:` lists two general strategies (index-based loop, or collect first).
But step back and ask what `delete` actually **needs**: 1) find where the customer is,
2) take it out of the store, 3) print its id and name. The awkward part is step 3, which
needs to read the customer *after* the store has changed. **What if taking it out gave it
to us?** Then we wouldn't need to borrow anything from the store to print it. We'd *own* it.

Delete the draft arm (keep the placeholder for one more minute).

---

## Step 3 — `remove(&mut self, id) -> Option<Customer>`: return what you take

> 🟡 **EXPERIMENT**: predict first. Does this version of `remove` compile? It iterates over
> `self.customers` and calls `self.customers.remove(index)` *inside* the loop, which
> looks just like Step 2.

```rust
fn remove(&mut self, id: u32) -> Option<Customer> {
    for (index, customer) in self.customers.iter().enumerate() {
        if customer.id == id {
            return Some(self.customers.remove(index));
        }
    }
    None
}
```

<details><summary>Answer</summary>

**It compiles.** The difference is the `return`. After `self.customers.remove(index)` the
function returns immediately, so neither the iterator nor `customer` is ever used again. Their
borrows end *before* the mutable borrow begins. That's NLL working per path. In Step 2, the
loop kept going after the removal (the iterator was needed for the next pass), so the borrow
was still live.

This is correct, but it's subtle: someone adding a line after the `remove` (logging, say)
would break it, and would get an error pointing at a line they didn't touch.

</details>

We'll write it in a way that makes the two phases **visible**:

> 🟢 **FOLLOW ALONG**: replace the placeholder with:

```rust
fn remove(&mut self, id: u32) -> Option<Customer> {
    let position = self.customers.iter().position(|customer| customer.id == id);
    match position {
        Some(index) => Some(self.customers.remove(index)),
        None => None,
    }
}
```

- **Phase 1, read:** `iter().position(...)` walks the customers with a *shared* borrow and
  returns the index of the first match, as `Option<usize>`. A `usize` is `Copy` and points at
  nothing. When the statement ends, the shared borrow is over.
- **Phase 2, write:** `self.customers.remove(index)` takes the exclusive borrow, shifts the
  others left, and **returns the `Customer` by value**. We wrap it in `Some` and move it out to
  our caller.

The signature now tells the full story: `&mut self` (I change the store) → `Option<Customer>`
(maybe you get the customer, **and it's yours now**). Compare it with `find` and `find_mut`:

| Method | Returns | Meaning for the caller |
|---|---|---|
| `find(&self, id)` | `Option<&Customer>` | you may *look* at it while it stays in the store |
| `find_mut(&mut self, id)` | `Option<&mut Customer>` | you may *change* it while it stays in the store |
| `remove(&mut self, id)` | `Option<Customer>` | it has **left** the store, and you own it |

(`Vec::remove` is O(n) because it shifts. `Vec::swap_remove` is O(1): it moves the *last*
customer into the gap, which changes the list order. In a CRM, `list` order is something users
notice, so we pay the shift.)

> 🟢 **FOLLOW ALONG**: the `delete` command.

```rust
"delete" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => match store.remove(id) {
            Some(customer) => {
                println!("Deleted customer #{} ({})", customer.id, customer.name)
            }
            None => println!("No customer with id {id}."),
        },
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

`customer` here is an owned `Customer`. Nothing is borrowed from `store`, so there's
nothing to conflict with. After the `println!`, `customer` goes out of scope and is dropped:
**that's** the moment the customer's memory is freed. Add `("delete", "Delete a customer")` to the table in `print_help()`.

```text
crm> delete
Customer id: 1
Deleted customer #1 (Ada Lovelace)
crm> delete
Customer id: 1
No customer with id 1.
crm> delete
Customer id: xyz
Invalid id: xyz
```

Commit:

```bash
git add .
git commit -m "Add delete command"
```

---

## Step 4 — `E0507`: moving out of something you only borrowed

> 🟡 **EXPERIMENT**: you want customer 1's name as a `String`. Predict first:

```rust
#[test]
fn take_the_name() {
    let store = store_with_ada_and_grace();
    let name = store.find(1).unwrap().name;
    assert_eq!(name, "Ada Lovelace");
}
```

```text
error[E0507]: cannot move out of a shared reference
   --> src/main.rs:435:20
    |
435 |         let name = store.find(1).unwrap().name;
    |                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ move occurs because value has type `String`, which does not implement the `Copy` trait
    |
help: consider borrowing here
    |
435 |         let name = &store.find(1).unwrap().name;
    |                    +
help: consider cloning the value if the performance cost is acceptable
    |
435 |         let name = store.find(1).unwrap().name.clone();
    |                                               ++++++++
```

**Reasoning script:**

1. **Who owns the name?** Customer #1, which is owned by the store.
2. **Moved?** `let name = <a String>` *tries* to move it into `name`.
3. **Borrow?** `store.find(1).unwrap()` is a `&Customer`, a **shared borrow**. You're
   trying to take something out of a thing you were only allowed to look at.
4. If this were allowed, the customer inside the store would be left with a "moved-out" name
   that the store would later drop, a dangling, double-freed string. So it's forbidden.

The compiler offers two fixes. There's a third, and choosing between them is a **design**
question: *do you need to look at the name, have your own copy, or actually take it?*

| You need… | Write | Cost / consequence |
|---|---|---|
| to **look** at it | `let name = &store.find(1).unwrap().name;` | free. `name: &String` borrows from the store, so no mutating the store while you use it |
| an **independent copy** (to keep after the store changes, or send elsewhere) | `.name.clone()` | one allocation. Honest when you really need a snapshot |
| to **take** it (the customer is leaving the store anyway) | `let customer = store.remove(1).unwrap(); let name = customer.name;` | free. You own the customer, so you can move its fields out |

(There's also `std::mem::take(&mut customer.name)` through `find_mut`, which moves the name out
and leaves an empty `String` in its place. That's useful when "empty" is a valid state, and
you'll see it in Lab 19. For a customer's name, an empty name isn't a valid state.)

For this test, **looking** is all it needs: add the `&` (and compare with `*name` or
`name.as_str()` if you like). Then delete the test, or keep the fixed version.

---

## Step 5 — `E0505`: moving something while it's borrowed

Now the opposite direction: you **own** a value, but you lent it out, and you try to give it
away while the loan is still active.

> 🟡 **EXPERIMENT**: a test that checks "if you delete a customer and add them back, they get a
> new id". Predict first:

```rust
#[test]
fn re_adding_a_deleted_customer_gives_a_new_id() {
    let mut store = store_with_ada_and_grace();
    let removed = store.remove(1).unwrap();
    let old_name = &removed.name;
    let new_id = store.add(removed.name, removed.email, removed.phone);
    assert_eq!(new_id, 3);
    assert_eq!(store.find(new_id).unwrap().name, *old_name);
}
```

```text
error[E0505]: cannot move out of `removed.name` because it is borrowed
   --> src/main.rs:444:32
    |
442 |         let removed = store.remove(1).unwrap();
    |             ------- binding `removed` declared here
443 |         let old_name = &removed.name;
    |                        ------------- borrow of `removed.name` occurs here
444 |         let new_id = store.add(removed.name, removed.email, removed.phone);
    |                                ^^^^^^^^^^^^ move out of `removed.name` occurs here
445 |         assert_eq!(new_id, 3);
446 |         assert_eq!(store.find(new_id).unwrap().name, *old_name);
    |         ------------------------------------------------------- borrow later used here
    |
help: consider cloning the value if the performance cost is acceptable
    |
443 |         let old_name = &removed.name.clone();
    |                                     ++++++++
```

**Reasoning script:**

1. **Who owns it?** `removed` owns the customer (thanks to `remove`), and its name.
2. **Moved? Where?** Line 444 moves `removed.name` into `store.add`.
3. **Borrow?** `old_name` borrows `removed.name` (line 443), and is used on line 446.
4. **How long must the borrow live?** Until line 446, after the move. A reference can't
   outlive (or survive the moving away of) the thing it points at. If it could, `old_name`
   would point at the `removed` variable's stale bytes while the string's real owner is now
   inside the store. That's rule 2 from Lab 07: *references must never outlive what they
   point to*.

| Error | You have | You try to |
|---|---|---|
| `E0507` | only a **borrow** | move the value out |
| `E0505` | **ownership**, but the value is currently lent out | move the value away while the loan is still used |

Notice the compiler's suggestion, `&removed.name.clone()`: clone the string and then
borrow the clone. It compiles, but it's a strange way to say "make a copy". If you *do*
want a copy, write `let old_name = removed.name.clone();`.

> 🔵 **YOUR TURN** (mini-task): fix this test **without cloning**. You know what the name is,
> so there's a simpler assertion. It becomes one of your tests in Your Turn 2.

---

## Step 6 — The find-then-mutate problem: duplicate emails on `update`

Your `update` from Lab 07 has a hole: you can change Grace's email to Ada's. The obvious fix
is to check `email_exists` before calling `update_email`.

> 🟡 **EXPERIMENT**: in your `update` arm, change the email part to:

```rust
let email = prompt("Email (blank to keep): ");
if !email.is_empty() {
    if store.email_exists(&email) {
        println!("A customer with email {email} already exists.");
    } else {
        customer.update_email(email);
    }
}
```

```text
error[E0502]: cannot borrow `store` as immutable because it is also borrowed as mutable
   --> src/main.rs:182:36
    |
174 |                     Ok(id) => match store.find_mut(id) {
    |                                     ----- mutable borrow occurs here
...
182 |                                 if store.email_exists(&email) {
    |                                    ^^^^^ immutable borrow occurs here
...
185 |                                     customer.update_email(email);
    |                                     -------- mutable borrow later used here
```

This is the **find-then-mutate** problem, and it's everywhere in real code: *find* a thing
(and hold on to it, mutably), then *ask the collection a question*, then *mutate* the thing.

**Reasoning script:** owner: the store. Borrows: `find_mut` → exclusive borrow of the
whole store, still needed on line 185. `email_exists` → shared borrow of the whole store,
on line 182, in between. Shared + exclusive overlap → rejected.

*But `email_exists` only reads!* Yes, and `customer` might be one of the customers it
reads. You're holding a writer and a reader on the same data at the same time. Here it's
harmless. But the compiler can't distinguish "harmless read" from "read while a half-finished
write is in progress" (or a push that reallocates the vec under `customer`), so it rejects both.

### The fix: two phases, and ids as handles

Restructure the work so the reads and the write **don't overlap**:

```text
 Phase 1: READ   — does the customer exist? gather input, validate it.
                   Only short, shared borrows of `store`. Each one ends immediately.
 Phase 2: WRITE  — take ONE exclusive borrow (find_mut), apply the changes, done.
                   Nothing else touches `store` while it's held.
```

Between the phases, what connects them is the **id**, a `u32`. It's `Copy`, borrows nothing,
and can't dangle. Holding an id instead of a reference, and looking the thing up again when
you need it, is the most important borrow-checker pattern in this course. Lab 14 builds
company↔contact relationships on it, and in Lab 19 lead conversion relies on it.

The `update` arm is getting long, and phase 1 wants to **bail out early** in several places.
That's a good reason for a function.

> 🟢 **FOLLOW ALONG**: add this function below `main`, next to `prompt`.

```rust
fn update_customer(store: &mut CustomerStore, id: u32) {
    if store.find(id).is_none() {
        println!("No customer with id {id}.");
        return;
    }

    // Phase 1: read. Prompts, plus short shared borrows of the store.
    let name = prompt("Name (blank to keep): ");
    let email = prompt("Email (blank to keep): ");
    let phone = prompt("Phone (blank to keep): ");
    let email_taken = match store.find_by_email(&email) {
        Some(other) => !email.is_empty() && other.id != id,
        None => false,
    };
    if email_taken {
        println!("A customer with email {email} already exists.");
        return;
    }

    // Phase 2: write. One mutable borrow; nothing else touches the store.
    if let Some(customer) = store.find_mut(id) {
        if !name.is_empty() {
            customer.name = name;
        }
        if !email.is_empty() {
            customer.update_email(email);
        }
        if !phone.is_empty() {
            customer.phone = phone;
        }
        println!("Updated customer #{id}");
    }
}
```

and replace the `update` arm with:

```rust
"update" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => update_customer(&mut store, id),
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

Read it carefully. Every line is a decision:

- **`store: &mut CustomerStore`**: the function changes the store, so it borrows it
  exclusively. `main` still owns it. Inside, `store.find(id)` borrows the store *shared*,
  briefly, through the `&mut` (a **reborrow**: an exclusive borrow can lend out a temporary
  shared one, as long as you don't use the `&mut` meanwhile).
- **`find_by_email`, not `email_exists`** (you wrote it in Lab 07's Your Turn 3): typing a
  customer's *own* email again must be allowed. So we need *who* owns the email, not just
  whether someone does. `other.id != id` compares ids (Copy values), not references.
- **`!email.is_empty() &&`**: blank means "keep", so a blank input must never count as taken.
- **`if let Some(customer) = store.find_mut(id)`**: `if let` is a `match` with one interesting
  arm (Lab 11 covers it properly). We checked existence in phase 1, so in this single-threaded
  program it's always `Some`. But we don't `unwrap()` it: if the code ever changes so that
  the customer can disappear in between, this degrades to "do nothing" instead of crashing.
- `name`, `email`, `phone` are owned `String`s gathered in phase 1 and **moved** into the
  customer in phase 2. Nothing is cloned.

> 💬 **Why not just clone the customer at the start?** You could copy the customer, edit the
> copy, and write it back. That's a third valid strategy ("copy, modify, replace"), and
> in some designs it's the natural one (when the CRM moves to a database, "load the row,
> change it, save it" has exactly this shape). Here it
> would cost a clone of every field, and we'd need a "replace" method we don't have. Two
> phases is cheaper and clearer.

Add the `update` rejection to your manual test:

```text
crm> update
Customer id: 2
Name (blank to keep):
Email (blank to keep): ada@example.com
Phone (blank to keep):
A customer with email ada@example.com already exists.
```

---

## Step 7 — Bulk updates: the loop that looks up what it already has

Next feature: `normalize`. Emails were typed by humans, so `Ada@Example.com` and
`ada@example.com` both exist. We want one method that lowercases every email and reports
how many changed.

Here's a first draft that reuses what we have. It's tempting, and wrong:

```rust
fn normalize_emails(&mut self) -> usize {
    let mut changed = 0;
    for customer in &self.customers {
        let lowercase = customer.email.to_lowercase();
        if lowercase != customer.email {
            match self.find_mut(customer.id) {
                Some(target) => target.update_email(lowercase),
                None => {}
            }
            changed += 1;
        }
    }
    changed
}
```

```text
error[E0502]: cannot borrow `*self` as mutable because it is also borrowed as immutable
   --> src/main.rs:100:23
    |
 97 |           for customer in &self.customers {
    |           -               ---------------
    |           |               |
    |           |               immutable borrow occurs here
    |  _________|               immutable borrow later used here
    | |
 98 | |             let lowercase = customer.email.to_lowercase();
 99 | |             if lowercase != customer.email {
100 | |                 match self.find_mut(customer.id) {
    | |                       ^^^^^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
...   |
106 | |         }
    | |_________- this for loop borrows `*self` immutably, preventing mutation within its body
    |
    = help: consider using an index-based loop instead, or collecting modifications into a separate collection
```

This is the same shape as Step 2: a loop holds a shared borrow, and the body wants a
mutable one. Read the code again, though. Inside the loop **you already have the customer**.
`find_mut(customer.id)` goes looking for something you're holding in your hand, just because
you're holding it through the wrong kind of reference.

Two fixes would work, and you'll implement one of them in Your Turn 1:

- **Collect, then mutate** (the compiler's second suggestion): loop once with shared
  borrows to collect the ids that need changing into a `Vec<u32>`, then loop over those ids and
  `find_mut` each one. Correct, but it does every lookup twice.
- **Borrow mutably from the start**: if the loop itself hands you `&mut Customer`s, you can
  change each customer in place as you go. Nothing else touches the store during the loop.

Don't fix it yet. That's Your Turn 1. Delete the draft (or leave it commented out) so
everything compiles.

---

## Step 8 — The fix-strategy catalogue

You've now seen every common borrow-checker conflict in the CRM. Here are the strategies
in one place, with where you've used each one. When you hit a borrow error, **run the four
questions first**, then come here and pick the cheapest strategy that matches what the code
*means*:

| # | Strategy | Use when… | In your CRM |
|---|---|---|---|
| 1 | **End the borrow sooner** (reorder; NLL) | you're done reading before the mutation | print before push (Lab 06); Step 1 test A |
| 2 | **Copy out what you need** | you need a small `Copy` value (id, count, flag) after a mutation | `let id = customer.id;` (Lab 06); `name.len()` in Step 1 C |
| 3 | **Hold an id, look it up again** | you need the *thing* again after something changed | `update_customer` phase 2; Lab 14 relationships |
| 4 | **Two phases: read/collect, then write** | you must inspect many things, then change some | `remove` (position, then remove); `update_customer` |
| 5 | **Return owned values from the mutation** | the mutation takes something out, and the caller needs it | `remove → Option<Customer>` in `delete` |
| 6 | **Mutate in place with `iter_mut`** | every element might change, nothing else needs the collection meanwhile | `normalize_emails` (Your Turn 1) |
| 7 | **`retain`** | delete everything matching a condition, in one pass | the Experiment below |
| 8 | **Split borrows** (borrow different *fields*) | a method needs one field mutably and another field at the same time | the Your Turn 1 follow-up experiment |
| 9 | **Clone, deliberately** | you need an *independent snapshot* that must survive changes | a test that compares "before" and "after"; never just to silence an error |

What's **not** on the list: "add `&`", "add `mut`", or "clone until it compiles" without being
able to say *which* of these strategies you just applied, and why.

---

## ▶️ Run It
```bash
cargo run
```

## ✅ Expected Result
(After completing Your Turn 1, which adds `normalize`.)

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> add
Name: Ada Lovelace
Email: Ada@Example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@example.com
Phone:
Added customer #2
crm> add
Name: Alan Turing
Email: ALAN@example.com
Phone: 555-0300
Added customer #3
crm> update
Customer id: 2
Name (blank to keep):
Email (blank to keep): Ada@Example.com
Phone (blank to keep):
A customer with email Ada@Example.com already exists.
crm> update
Customer id: 2
Name (blank to keep):
Email (blank to keep):
Phone (blank to keep): 555-0199
Updated customer #2
crm> normalize
Normalized emails: 2 changed.
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
#3 Alan Turing <alan@example.com> 555-0300
crm> delete
Customer id: 1
Deleted customer #1 (Ada Lovelace)
crm> delete
Customer id: 1
No customer with id 1.
crm> list
#2 Grace Hopper <grace@example.com> 555-0199
#3 Alan Turing <alan@example.com> 555-0300
crm> quit
Goodbye! (10 commands this session)
```

## 🧠 Understand It

**The borrow checker is checking your design, not your syntax.** Every error in this lab
was the compiler noticing that two parts of the code wanted incompatible access to the
same data at the same time. The fixes weren't syntax tricks. Each one changed the
*design* so the overlap went away:

- `delete` stopped *referring to* a customer it was destroying and started *receiving* it.
- `update` stopped holding a writer while asking questions, and separated reading from writing.
- `normalize` (Your Turn 1) stops looking up what it already holds.

Those designs would be better in any language. Rust is the one that makes you notice.

**Ownership moves you've used, from cheapest to most expensive:**

```text
 &T  (look)          free, many at once, no mutation meanwhile
 &mut T (change)     free, exclusive, nothing else meanwhile
 T  (take/give)      free (a memcpy of the handle), the giver loses access
 T.clone() (copy)    allocations, two independent values that can drift apart
```

**Indices are references the compiler can't check.** Strategy 3 (ids) and the `position`
index in `remove` are *plain numbers*. They can't dangle in the memory-safety sense: the
worst a stale index can do is panic or pick the wrong element. Rust stays memory-safe,
but correctness is up to you. The Experiment below shows a stale-index bug the compiler
can't catch. That's why we look things up **by id** (stable) rather than by index
(which shifts on every removal), and why `remove` uses its index immediately and then
forgets it.

**`&mut self` methods that return owned values** are a pattern you'll see constantly:
`Vec::pop`, `Vec::remove`, `HashMap::remove`, `Option::take`, and your `CustomerStore::remove`.
Whenever a mutation *takes something out*, give it to the caller, so they don't need to
keep a borrow into a collection that just changed.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: `retain`, the bulk-delete strategy. Add this test (tests in the same file
> can see the store's private `customers` field):
>
> ```rust
> #[test]
> fn retain_keeps_only_customers_with_a_phone() {
>     let mut store = store_with_ada_and_grace();
>     store.customers.retain(|customer| customer.has_phone());
>     assert_eq!(store.len(), 1);
> }
> ```
>
> It passes. `retain` keeps every element for which the closure returns `true`, drops the
> rest, and does it in **one pass** with no stale indices. Question: why didn't we implement
> `remove(id)` with `retain(|c| c.id != id)`? What would `delete` lose? (Answer in `solutions.md`.)

> 🟡 **EXPERIMENT 2**: the bug the compiler can't see. Predict what happens: compile error,
> wrong result, or panic?
>
> ```rust
> #[test]
> fn delete_by_index_in_a_loop() {
>     let mut store = store_with_ada_and_grace();
>     for index in 0..store.customers.len() {
>         if store.customers[index].has_phone() {
>             store.customers.remove(index);
>         }
>     }
>     assert_eq!(store.len(), 1);
> }
> ```

<details><summary>Real output</summary>

```text
---- tests::delete_by_index_in_a_loop stdout ----

thread 'tests::delete_by_index_in_a_loop' panicked at src/main.rs:507:31:
index out of bounds: the len is 1 but the index is 1
```

It **compiles**: there are no references here, only numbers. The range `0..2` was computed
once, when the length was 2. After removing Ada at index 0, Grace slides to index 0 and the
length becomes 1, but the loop carries on to index 1 anyway. This is the "index-based loop"
the compiler suggested in Step 2. It's a valid strategy, but **you** now have to reason
about shifting indices. `retain`, or `remove` with an index used immediately, avoids the
whole problem. Delete both experiment tests.

</details>

> 🟡 **EXPERIMENT 3**: after Your Turn 1, predict the output of this session. Look closely
> at the emails:
>
> ```text
> crm> add            (Ada Lovelace / ada@example.com / 555-0100)
> crm> add            (Grace Hopper / grace@example.com / blank)
> crm> add            (Alan Turing / Alan@Example.com / 555-0300)
> crm> update         (id 2, blank name, email alan@Example.com, blank phone)
> crm> normalize
> crm> list
> ```

<details><summary>Real output</summary>

```text
crm> update
Customer id: 2
Name (blank to keep):
Email (blank to keep): alan@Example.com
Phone (blank to keep):
Updated customer #2
crm> normalize
Normalized emails: 2 changed.
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <alan@example.com>
#3 Alan Turing <alan@example.com> 555-0300
```

Two customers now share an email. The duplicate check compares emails **exactly**, so
`alan@Example.com` and `Alan@Example.com` looked different, and normalising made them equal.
The borrow checker can't help here; it's a **domain** bug. The real fix is to make sure an
email is *always* stored lowercase, so that no un-normalised email can exist. In Lab 12 you'll
create an `Email` type that guarantees exactly that, and `normalize` will become unnecessary.
That's the next big idea after ownership: **make invalid states unrepresentable**.

</details>

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1**: `normalize_emails` and the `normalize` command.

- [ ] Add `fn normalize_emails(&mut self) -> usize` to `CustomerStore`.
- [ ] It lowercases every customer's email **in place**, using `iter_mut()` (strategy 6).
- [ ] It returns how many emails actually **changed** (an email that's already lowercase
      doesn't count).
- [ ] No `.clone()`, and no calls to `find` / `find_mut` inside the method.
- [ ] Add a `normalize` command that calls it and prints `Normalized emails: N changed.`
      Add `("normalize", "Lowercase every email address")` to the table in `print_help()`.
- [ ] Running `normalize` twice in a row prints `0 changed.` the second time.
- [ ] Add a comment above the method saying which strategy from Step 8 you used, and why
      "collect, then mutate" would be worse here.

When it works, try this follow-up:

> 🟡 **EXPERIMENT** (split borrows): inside your `normalize_emails` loop, add a debugging line
> that uses `self` while the loop holds `&mut` customers. Try each, predict first:
>
> ```rust
> println!("checking #{} of {}", customer.id, self.len());              // (a)
> println!("checking #{} (next id: {})", customer.id, self.next_id);   // (b)
> ```

<details><summary>Real output</summary>

(a) fails:

```text
error[E0502]: cannot borrow `*self` as immutable because it is also borrowed as mutable
  --> src/main.rs:99:57
   |
98 |         for customer in self.customers.iter_mut() {
   |                         -------------------------
   |                         |
   |                         mutable borrow occurs here
   |                         mutable borrow later used here
99 |             println!("checking #{} of {}", customer.id, self.len());
   |                                                         ^^^^ immutable borrow occurs here
```

(b) compiles.

The loop holds an exclusive borrow of **one field**, `self.customers`. Reading a
**different** field, `self.next_id`, doesn't overlap, and the compiler tracks borrows per
field inside a function body. That's a *split borrow*. But `self.len()` is a method call,
and a `&self` method borrows **all** of `self`, including `customers`, so it conflicts.
The compiler checks borrows against signatures, and it doesn't look inside `len` to see that
it only reads one field. (If you need a value like the length, compute it *before* the loop:
strategy 2.) Remove the debugging line.

</details>

---

> 🔵 **YOUR TURN 2**: tests for the new behaviour.

Add these tests to `mod tests` (use `store_with_ada_and_grace()`):

- [ ] `remove_returns_the_owned_customer`: removing id 1 gives you Ada; afterwards `len()` is 1
      and `find(1)` is `None`.
- [ ] `remove_unknown_id_returns_none_and_changes_nothing`
- [ ] `remove_does_not_renumber_the_others`: after removing 1, Grace is first in `all()` and
      still has id 2.
- [ ] `re_adding_a_deleted_customer_gives_a_new_id`: the Step 5 test, fixed **without** a clone.
- [ ] `normalize_emails_lowercases_and_counts_changes`: add a customer with `Alan@Example.COM`,
      normalise (returns 1), check the stored email, normalise again (returns 0).
- [ ] `cargo test` passes, and `cargo clippy --all-targets` shows no warnings.

---

> 🔵 **YOUR TURN 3**: the ownership review.

You've written about twenty functions. For **each one**, decide whether every parameter and
receiver is the right one of `T`, `&T` or `&mut T`, and **say why**. This is the exercise that
turns rules into judgement.

- [ ] In **your** `rust-crm` repo, create `notes/ownership-review.md`.
- [ ] Fill in this table for every function and method in `src/main.rs` (including `main`,
      `prompt`, `print_help`, `customer_count_label`, `next_id`, every `Customer` method
      including `matches_email`, every `CustomerStore` method, and `update_customer`):

      | Function | Receiver / parameters | Returns | Why this access? | What if it were different? |
      |---|---|---|---|---|
      | `CustomerStore::find` | `&self`, `id: u32` | `Option<&Customer>` | only reads; lends a view, no copy | `&mut self`: callers couldn't hold two customers at once, and read-only tests would need `let mut`. `Option<Customer>`: impossible without removing or cloning |
      | … | | | | |

- [ ] For the **"What if it were different?"** column, actually try at least **three** of your
      alternatives in code, run `cargo check`, and note the error code you got (or that it
      compiled, but with a cost you can name).
- [ ] Answer, at the end of the file:
  1. Which function is the only one that takes ownership of the whole store? (Careful.
     Is there one?)
  2. Which signatures would you change, now that you know more? (There's at least one that
     Lab 09 changes. Can you guess which and why?)
  3. Find one place where a `String` parameter could have been `&str`, or vice versa. Which is
     right, and why?
- [ ] Commit the file along with your code.

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `for customer in self.customers.iter_mut()` gives you a
> `&mut Customer` per element. Compute the lowercase version, compare it with the current
> one, and only assign (and count) when they differ.

<details><summary>Hint 2 for Your Turn 1</summary>

`String::to_lowercase()` returns a **new** `String`. Comparing `lowercase != customer.email`
compares contents. If they differ, move `lowercase` into the customer (`update_email` takes a
`String`). The old email is dropped by the assignment. If they're equal, `lowercase` is simply
dropped at the end of the iteration.

</details>

> 💡 **HINT (Your Turn 2)**: for the re-add test: you **know** the name is `"Ada Lovelace"`.
> Compare against the literal instead of keeping a borrow of the moved-out name.

> 💡 **HINT (Your Turn 3)**: for each function, ask in this order: *does it need to keep or
> consume the value?* → `T`. *Does it need to change it?* → `&mut T`. *Otherwise* → `&T`, or
> plain `T` if the type is `Copy` (like `u32`). Then check the signature against that answer.

<details><summary>Hint 2 for Your Turn 3</summary>

Good candidates for experiments: `summary(self)` instead of `&self`; `find(&mut self, …)`;
`Customer::new` taking `&str` instead of `String`; `update_customer(store: CustomerStore, …)`;
`email_exists(&self, email: String)`. For each one, predict the error before running
`cargo check`. And for question 2: what does `all()` return, and what would a caller who only
wants *some* customers (say, page 2) prefer?

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code (answers in `solutions.md`):

1. What does "a borrow lasts until its last use" mean? Give an example from this lab where
   moving one line fixed an error.
2. Why does the first-draft `delete` loop fail to compile, and what *runtime* bug would it
   have had if it compiled?
3. Why does `remove` return `Option<Customer>` instead of `bool` or `Option<&Customer>`?
4. `E0507` vs `E0505`: what's the difference, in one sentence each?
5. What is the find-then-mutate problem? Describe the two-phase fix in your own words.
6. Why is holding a customer's **id** safer than holding a **reference** to it? What's the
   one thing an id *can't* guarantee?
7. Why does `self.next_id` work inside an `iter_mut()` loop over `self.customers`, but
   `self.len()` doesn't?
8. **Predict:** does this compile? If not, which strategy fixes it?

   ```rust
   let first = store.all().first();
   store.normalize_emails();
   println!("{:?}", first.map(|c| c.id));
   ```

9. **Predict:** does this compile?

   ```rust
   let removed = store.remove(2);
   store.add(String::from("Linus"), String::from("linus@example.com"), String::new());
   println!("{:?}", removed.map(|c| c.name));
   ```

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit
```bash
git add .
git commit -m "Add delete and email normalisation; ownership review"
git tag lab-08
git push && git push --tags
```

Now try `git diff lab-07 lab-08 -- src/main.rs`. That's the refactor this lab was about,
and you can explain every changed line.

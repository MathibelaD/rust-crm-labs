# Lab 07 — Borrowing: Shared and Mutable References

> **Phase:** 2 — Ownership & Borrowing · **Builds on:** Lab 06 · **Time:** ~3–4 hours
> **Your repo before this lab:** tag `lab-06` · **After:** tag `lab-07`

## 🎯 Goal
Wrap the customer list in a `CustomerStore` whose methods say, **in their signatures**, who
may read and who may write. Then add two commands that need exactly that distinction:
`show` (look at one customer) and `update` (change one customer).

## 🧠 What You'll Learn
- What a reference (`&T`, `&mut T`) physically is, and what it promises
- The borrowing rule: **many readers XOR one writer** (aliasing XOR mutation)
- **Why** that rule exists: a `Vec` reallocating under a reference, step by step, plus a
  preview of data races
- Method receivers `self` / `&self` / `&mut self` as **API contracts**
- Auto-referencing and auto-dereferencing in method calls
- Returning references from methods: `Option<&Customer>`, `Option<&mut Customer>`
- Errors: `E0502`, `E0499`, `E0596`, `E0594`
- A first, light look at `Result` (`"42".parse::<u32>()` gives you `Ok` or `Err`)

## 🔨 What We're Building

```text
crm> show
Customer id: 2
#2 Grace Hopper <grace@example.com>
(no phone on file)
crm> update
Customer id: 1
New email: ada@lovelace.dev
Updated customer #1
```

Behind those commands is a new type:

```rust
struct CustomerStore { customers: Vec<Customer>, next_id: u32 }
// new, add, all, find, find_mut, email_exists, len
```

The store **owns** every customer. Commands get **borrowed** access to them, read-only or
read-write, and the compiler checks that those two kinds of access never overlap.

At the end of Lab 06 you saw the problem: a function that only wanted to *look* at the
list had to take ownership and give it back (`customers = print_list(customers)`). This lab
is about the better way.

---

## Step 1 — A reference is a pointer with a promise

You've been writing `&` since Lab 02 (`label: &str`) and Lab 05 (`for customer in &customers`).
Here's what it actually is.

```rust
let first: &Customer = &customers[0];
```

```text
 STACK                                     HEAP: the Vec's buffer
 customers: Vec<Customer>                  ┌────────────────────┬────────────────────┐
 ┌────────────────┐                        │ Customer #1        │ Customer #2        │
 │ ptr ───────────┼───────────────────────►│ name ──► "Ada…"    │ name ──► "Grace…"  │
 │ len = 2        │                        │ ...                │ ...                │
 │ cap = 4        │                        └────────────────────┴────────────────────┘
 └────────────────┘                          ▲
 first: &Customer                            │
 ┌────────────────┐                          │
 │ address ───────┼──────────────────────────┘    8 bytes. Owns nothing.
 └────────────────┘
```

At runtime a reference is **just an address**, 8 bytes, like a pointer in C. Making one is
free, and dropping one frees nothing (it doesn't own what it points at). Everything
interesting about references happens at **compile time**, where each one comes with a
promise that the compiler enforces:

| Type | Read as | The compiler guarantees… |
|---|---|---|
| `&Customer` | "shared reference", "borrow" | …the customer **stays alive and doesn't change** for as long as this reference is used |
| `&mut Customer` | "mutable reference", "exclusive borrow" | …**nobody else can read or write** the customer for as long as this reference is used |

That's why `&mut` is better read as "**exclusive**" than "mutable". Mutation is just the
thing exclusivity makes safe.

Compared with JavaScript: every JS object variable is already a kind of shared, mutable
reference. Any code holding it can change the object at any time, and the garbage collector
keeps the object alive while anyone can reach it. Rust splits that into two kinds of reference
with opposite guarantees, and keeps the target alive by **checking** instead of by GC.

---

## Step 2 — The rules

1. At any moment, a value can have **either**
   - any number of shared references `&T`, **or**
   - exactly one mutable reference `&mut T`,

   **but not both.** (This is *aliasing XOR mutation*: you can have many aliases, or
   mutation, never both at once.)
2. A reference must **never outlive** the value it points to.
3. While a value is borrowed, its **owner** is restricted too: no moving it, no mutating it
   while `&` borrows exist, and not even reading it while a `&mut` exists.

"At any moment" means **while the reference is still going to be used**, not "until the end
of the block". A borrow ends at its last use. Lab 08 explores that in depth.

Rule 2 is the dangling-pointer rule from Lab 06 (`prompt` can't return a `&str` into its
own local). Rule 1 is the new one, and it looks strict. Why can't you hold a `&Customer`
into the list and also push to the list? Let's find out what would go wrong.

---

## Step 3 — Why: the `Vec` that moves under your feet

Suppose the CRM has 4 customers, and the `Vec`'s capacity is exactly 4 (that's really
what you get; you'll measure it in a minute).

```text
 ① let first = &customers[0];

 customers ┌ptr─┐     buffer A (cap 4)
           │len 4│──►┌──────────┬──────────┬──────────┬──────────┐
           │cap 4│   │ #1 Ada   │ #2 Grace │ #3 Alan  │ #4 Linus │
           └─────┘   └──────────┴──────────┴──────────┴──────────┘
                       ▲
 first ────────────────┘
```

Now `customers.push(customer_5)`. The buffer is full, so `push` has to **reallocate**:

```text
 ② push: allocate a bigger buffer B, copy the 4 customers over, write #5

           buffer A (old)                                    buffer B (new, cap 8)
           ┌──────────┬──────────┬──────────┬──────────┐     ┌──────┬──────┬──────┬──────┬──────┬───┬───┬───┐
           │ #1 Ada   │ #2 Grace │ #3 Alan  │ #4 Linus │ ──► │ #1   │ #2   │ #3   │ #4   │ #5   │   │   │   │
           └──────────┴──────────┴──────────┴──────────┘     └──────┴──────┴──────┴──────┴──────┴───┴───┴───┘
 customers.ptr now points at B ───────────────────────────────►▲

 ③ free buffer A

           ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░       (returned to the allocator,
           ░ freed memory, may be reused for anything ░        soon reused by something else)
           ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
             ▲
 first ──────┘   💥 DANGLING: still points at buffer A
```

```text
 ④ println!("{}", first.name);   → reads freed memory: garbage, a crash, or a security hole
```

This is **iterator invalidation**, one of the most common memory bugs in C++. The
reference itself didn't change; the thing it pointed into moved away. And the bug is
intermittent: with 3 customers (spare capacity), the push *doesn't* reallocate and
everything "works". It only breaks on the push that crosses the capacity.

Rust's rule makes this unrepresentable. `push` takes `&mut self` (exclusive access), and
`first` is a shared borrow that's still going to be used, so the two can't overlap. The
compiler doesn't know or care what the capacity is. **Any** `&mut` access *might*
reallocate, so **no** shared reference may survive across it.

> 🟡 **EXPERIMENT**: catch the reallocation in the act. You'll build `CustomerStore` in Step 4,
> so come back to this experiment after Step 4 if you prefer. Add this **temporary** test:
>
> ```rust
> #[test]
> fn watch_the_buffer_move() {
>     let mut store = CustomerStore::new();
>     for n in 1..=5 {
>         store.add(format!("Customer {n}"), format!("c{n}@example.com"), String::new());
>         println!(
>             "len={} capacity={} buffer at {:p}",
>             store.len(),
>             store.all().capacity(),
>             store.all().as_ptr()
>         );
>     }
> }
> ```
>
> Predict: on which line does the address change? Then run
> `cargo test watch_the_buffer -- --nocapture`. Real output (your addresses will differ):
>
> ```text
> len=1 capacity=4 buffer at 0x1207042c0
> len=2 capacity=4 buffer at 0x1207042c0
> len=3 capacity=4 buffer at 0x1207042c0
> len=4 capacity=4 buffer at 0x1207042c0
> len=5 capacity=8 buffer at 0x120704500
> ```
>
> The fifth push moved every customer to a new address. Any `&Customer` taken before it would
> have pointed at freed memory. Delete the test afterwards.

### The same rule prevents data races

A **data race** is two threads touching the same memory at the same time, at least one of
them writing, with no synchronisation. Then the result depends on timing, and it's
undefined behaviour. Look at the ingredients: *shared* (aliasing) + *writing* (mutation) +
*at the same time*. Rust's rule forbids aliasing and mutation together, so a thread can't
hold a `&mut CustomerStore` while another holds a `&CustomerStore`. The rule that stops the
`Vec` bug in one thread is the same rule that makes threads safe. In Lab 25 you'll share the
CRM between threads behind a lock, which hands out the same exclusive `&mut` access, just
checked at runtime instead of compile time.

---

## Step 4 — Build `CustomerStore`, and design its contract

Right now `main` owns a loose `Vec<Customer>` and a loose `next_customer_id`, and every
command reaches into them directly. We'll give them one owner with a small API, and the
**receiver** of each method will say what kind of access it needs.

> 🟢 **FOLLOW ALONG**: add this below `impl Customer` (and keep `next_id`, which the store now uses).

```rust
struct CustomerStore {
    customers: Vec<Customer>,
    next_id: u32,
}

impl CustomerStore {
    fn new() -> Self {
        CustomerStore {
            customers: Vec::new(),
            next_id: 1,
        }
    }

    fn add(&mut self, name: String, email: String, phone: String) -> u32 {
        let id = self.next_id;
        let customer = Customer::new(id, name, email, phone);
        self.customers.push(customer);
        self.next_id = next_id(self.next_id);
        id
    }

    fn all(&self) -> &Vec<Customer> {
        &self.customers
    }

    fn email_exists(&self, email: &str) -> bool {
        for customer in &self.customers {
            if customer.matches_email(email) {
                return true;
            }
        }
        false
    }

    fn len(&self) -> usize {
        self.customers.len()
    }
}
```

Read each signature as a contract with the caller:

| Method | Receiver | The contract |
|---|---|---|
| `new()` | none | "I create a store and **give it to you**" (returns an owned `Self`) |
| `add(&mut self, name: String, …)` | `&mut self` | "I need **exclusive** access to the store to change it. And give me those three `String`s **to keep**: they become part of the customer." |
| `all(&self) -> &Vec<Customer>` | `&self` | "I only read. Here's a **view** of the list. You can look at it, but it still belongs to me." |
| `email_exists(&self, email: &str)` | `&self` | "I only read, and I only need to *look at* the email you're asking about." |
| `len(&self)` | `&self` | "I only read. Here's a number (`usize` is `Copy`, so it's yours)." |

And the third receiver, which we don't use here:

| Receiver | Meaning | Real examples |
|---|---|---|
| `self` | "I **consume** this value. You won't have it afterwards." | `Vec::into_iter(self)`, your `into_names(customers: Vec<Customer>)` from Lab 06, and in Lab 19 `Lead::convert(self)`, where a lead that has been converted *must not* be usable any more |

Notice what the store **doesn't** offer: there's no way to get a `&mut Vec<Customer>` and
push a customer with a duplicate id or skip the id counter. The store owns the customers
*and* the rules about them. That's the start of a real domain type.

### What `store.add(...)` really means

```rust
store.add(name, email, phone);
// is sugar for:
CustomerStore::add(&mut store, name, email, phone);
```

The `.` operator **auto-references**: it sees that `add` wants `&mut self`, so it borrows
`store` mutably for you, just for the duration of the call. Same with `store.len()`, which
becomes `CustomerStore::len(&store)`. It also **auto-dereferences**: if `c` is a
`&Customer`, then `c.summary()` and `c.name` work without writing `(*c).name`. That's why
references feel invisible in method calls, and why it's worth knowing they're there.

---

## Step 5 — Move `main` onto the store

> 🟢 **FOLLOW ALONG**

1. In `main`, replace

   ```rust
   let mut customers: Vec<Customer> = Vec::new();
   let mut next_customer_id: u32 = 1;
   ```

   with

   ```rust
   let mut store = CustomerStore::new();
   ```

2. **Delete `read_new_customer`.** The store now owns the id counter and is the only place
   that builds `Customer`s. The command's job is just to collect input.

3. Replace the `add`, `list` and `count` arms:

```rust
"add" => {
    let name = prompt("Name: ");
    let email = prompt("Email: ");
    if store.email_exists(&email) {
        println!("A customer with email {email} already exists.");
        continue;
    }
    let phone = prompt("Phone: ");
    let id = store.add(name, email, phone);
    println!("Added customer #{id}");
}
"list" => {
    if store.all().is_empty() {
        println!("No customers yet.");
    } else {
        for customer in store.all() {
            println!("{}", customer.summary());
        }
    }
}
"count" => println!("{}", customer_count_label(store.len())),
```

(`email_exists` uses your `matches_email` from Lab 05, so the definition of "same email" still
lives in exactly one place: on `Customer`.)

Look at what borrowing bought you in `add`:

- `store.email_exists(&email)` **lends** the email to the store for the length of the call.
  You still own it afterwards, so you can pass it to `store.add` a moment later.
- That means the duplicate check runs **before** asking for the phone again, as it did in
  Lab 05. The UX regression from Lab 06 is gone, and so is the throwaway `Customer` you had
  to build just to reject it.
- `store.add(name, email, phone)` then **moves** the strings in. The store keeps them.

(`&email` is a `&String`, but `email_exists` asks for a `&str`. Rust converts automatically.
That's *deref coercion*, explained properly in Lab 09.)

> 🟡 **EXPERIMENT**: predict first. Remove the `mut` from `let mut store`.

```text
error[E0596]: cannot borrow `store` as mutable, as it is not declared as mutable
   --> src/main.rs:126:26
    |
126 |                 let id = store.add(name, email, phone);
    |                          ^^^^^ cannot borrow as mutable
    |
help: consider changing this to be mutable
    |
 87 |     let mut store = CustomerStore::new();
    |         +++
```

**Reasoning script.** *Who owns it?* `main`'s `store` variable. *Moved?* No. *Borrow?* Yes:
`add` takes `&mut self`, so the `.` operator tries to create a `&mut store`. *Mutable?* That's
the problem: a `&mut` borrow requires that the **owner** was declared `mut`. `let` without `mut`
means "this binding will never be changed, nor lent out for changing". The fix really is to
add `mut`, because the store *is* going to change. (Try this experiment again at the end of
the lab: once `update` uses `find_mut`, the error lists *every* place that needs `&mut`.)

Run the CRM and check that `add`, `list` and `count` behave as before. Then commit:

```bash
git add .
git commit -m "Introduce CustomerStore"
```

---

## Step 6 — `find(&self, id) -> Option<&Customer>` and the `show` command

To show one customer we need to **look it up and look at it**. Not take it out of the store,
and not copy it. So `find` returns a reference into the store, wrapped in `Option` because the
id might not exist.

> 🟢 **FOLLOW ALONG**: a first version, written the way you'd write it in any language:

```rust
fn find(&self, id: u32) -> Option<&Customer> {
    for customer in &self.customers {
        if customer.id == id {
            return Some(customer);
        }
    }
    None
}
```

`for customer in &self.customers` gives you `&Customer`s pointing into the vec's buffer.
`return Some(customer)` hands one of those references to the caller.

Now ask your code reviewer (it will also say `method 'find' is never used`, which the `show`
command below fixes; the part that matters is this one):

```bash
cargo clippy
```

```text
warning: manual implementation of `Iterator::find`
  --> src/main.rs:70:9
   |
70 | /         for customer in &self.customers {
71 | |             if customer.id == id {
72 | |                 return Some(customer);
...  |
75 | |         None
   | |____________^ help: replace with an iterator: `self.customers.iter().find(|&customer| customer.id == id).map(|v| v as _)`
   |
   = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.99.0/index.html#manual_find
   = note: `#[warn(clippy::manual_find)]` on by default
```

Clippy recognises the pattern: "walk a collection, return the first match". The standard
library has that as a method. Its suggested text is mechanical (the `.map(|v| v as _)` isn't
needed here). The clean version is:

```rust
fn find(&self, id: u32) -> Option<&Customer> {
    self.customers.iter().find(|customer| customer.id == id)
}
```

- `self.customers.iter()` walks the vec, producing a `&Customer` for each element. It's the
  same thing `for customer in &self.customers` does.
- `.find(...)` takes a **closure**. `|customer| customer.id == id` is an inline function
  with one parameter. It's called on each item until it returns `true`, and then `find`
  returns `Some(that item)`, or `None` if it never does. (Closures and iterators get a whole lab,
  Lab 17. For now, read `|x| expr` as "a function of `x` returning `expr`".)
- `id` inside the closure is the method's `id` parameter. Closures can use variables around
  them.

**Why `Option<&Customer>`, and not the alternatives?**

| Return type | What it would mean | Problem |
|---|---|---|
| `Option<Customer>` | "Here's the customer, it's yours now" | You can't get an owned customer out of `&self` without removing it from the store (which needs `&mut self`) or cloning it |
| `&Customer` | "Here's the customer" | What if there's no customer with that id? You'd have to panic |
| `Option<&Customer>` ✅ | "Maybe a customer; if so, you may **look** at it while it's still in the store" | No copies, no panics, no ownership change |

How long may the caller keep that `&Customer`? Rust has inferred that the returned reference
**borrows from `self`**: it's valid only while the store is borrowed and unchanged. You didn't
write that down; the compiler works it out from the signature (Lab 10 shows you how, and when
you *do* have to write it down).

> 🟢 **FOLLOW ALONG**: add the `show` command.

```rust
"show" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => match store.find(id) {
            Some(customer) => {
                println!("{}", customer.summary());
                if !customer.has_phone() {
                    println!("(no phone on file)");
                }
            }
            None => println!("No customer with id {id}."),
        },
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

- `input.parse::<u32>()` tries to turn text into a `u32`. It can fail ("abc", "-1", ""), so
  it returns a `Result`: `Ok(number)` or `Err(reason)`. You match on it just like `Option`.
  (`Result` is Lab 12's main topic; this is a preview.)
- Inside `Some(customer) =>`, `customer` is a `&Customer`. `customer.summary()` and
  `customer.has_phone()` work through auto-deref. (`summary` already leaves out a missing
  phone. `show` is the detailed view, so it says so explicitly.)
- Add `("show", "Show one customer")` to the command table in `print_help()`.

---

## Step 7 — `find_mut`, `update_email` and the `update` command

`update` needs to **change** a customer that lives inside the store. So it needs a reference
that grants exclusive access: `&mut Customer`. And to hand one out, the store itself must be
borrowed exclusively.

> 🔵 **YOUR TURN** (mini-task): write `find_mut`.
>
> ```rust
> fn find_mut(&mut self, id: u32) -> Option<&mut Customer>
> ```
>
> - Same behaviour as `find`, but hands out exclusive access.
> - Hint: `find` used `iter()`, which yields `&Customer`. There's a sibling method that yields
>   `&mut Customer`.
> - `cargo clippy` shows no warnings for it.

Ask yourself: **why must `find_mut` take `&mut self` rather than `&self`?** If it took
`&self`, two callers could each hold a `&CustomerStore` at the same time, and each get a
`&mut Customer` to the *same* customer. That's two writers. The receiver `&mut self` is
what makes the returned `&mut Customer` exclusive.

> 🟢 **FOLLOW ALONG**: add a method to `impl Customer`. We'll deliberately get it wrong first.

```rust
fn update_email(&self, email: String) {
    self.email = email;
}
```

```text
error[E0594]: cannot assign to `self.email`, which is behind a `&` reference
  --> src/main.rs:40:9
   |
40 |         self.email = email;
   |         ^^^^^^^^^^ `self` is a `&` reference, so it cannot be written to
   |
help: consider changing this to be a mutable reference
   |
39 |     fn update_email(&mut self, email: String) {
   |                      +++
```

The receiver is part of the method's **promise**. `&self` promised callers "I won't change
the customer", and the body broke that promise. Fix the receiver, which also changes what the
method promises:

```rust
fn update_email(&mut self, email: String) {
    self.email = email;
}
```

`email: String` (owned) is right here: the customer is going to **keep** the new email. If
the parameter were `&str`, `update_email` would have to allocate a copy anyway
(`email.to_string()`). Taking `String` lets a caller who already has one hand it over for free.

Note what happens to the **old** email string: assigning to `self.email` drops the previous
value first. No leak, no manual free.

> 🟢 **FOLLOW ALONG**: the `update` command.

```rust
"update" => {
    let input = prompt("Customer id: ");
    match input.parse::<u32>() {
        Ok(id) => match store.find_mut(id) {
            Some(customer) => {
                let email = prompt("New email: ");
                customer.update_email(email);
                println!("Updated customer #{id}");
            }
            None => println!("No customer with id {id}."),
        },
        Err(_) => println!("Invalid id: {input}"),
    }
}
```

Inside `Some(customer) =>`, `customer` is a `&mut Customer`: an exclusive borrow of one
customer inside the store, which in turn is an exclusive borrow of `store`. While it's
alive, nothing else may touch `store`. Here nothing does: `prompt` doesn't touch the store.
Add `("update", "Change a customer's details")` to the table in `print_help()`.

> 🟡 **EXPERIMENT**: predict first. In the `update` arm, call `store.find(id)` instead of
> `store.find_mut(id)`.

```text
error[E0596]: cannot borrow `*customer` as mutable, as it is behind a `&` reference
   --> src/main.rs:168:29
    |
166 |                         Some(customer) => {
    |                              -------- consider changing this binding's type to be: `&mut Customer`
167 |                             let email = prompt("New email: ");
168 |                             customer.update_email(email);
    |                             ^^^^^^^^ `customer` is a `&` reference, so it cannot be borrowed as mutable
```

**Reasoning script:** *Who owns it?* The store (inside its `Vec`). *Borrow?* `find` gave us
a **shared** `&Customer`. *Mutable?* `update_email` needs `&mut Customer`, and you can't turn a
shared borrow into an exclusive one. That would break the promise made to every other
holder of a `&`. The fix isn't to "add `mut` somewhere". It's to **ask for the right kind
of access from the start**: `find_mut`. Put it back.

---

## Step 8 — When borrows collide: `E0502` and `E0499`

Time to meet the two core borrowing errors on purpose. We'll use tests, because they let
you build the exact situation.

> 🟡 **EXPERIMENT 1**: this is Step 3's diagram as code. Predict the error code, then add it to
> `mod tests` and run `cargo test`.

```rust
#[test]
fn reference_survives_push() {
    let mut store = CustomerStore::new();
    store.add(
        String::from("Ada Lovelace"),
        String::from("ada@example.com"),
        String::new(),
    );
    let ada = &store.all()[0];
    store.add(
        String::from("Grace Hopper"),
        String::from("grace@example.com"),
        String::new(),
    );
    assert_eq!(ada.name, "Ada Lovelace");
}
```

```text
error[E0502]: cannot borrow `store` as mutable because it is also borrowed as immutable
   --> src/main.rs:340:9
    |
339 |           let ada = &store.all()[0];
    |                      ----- immutable borrow occurs here
340 | /         store.add(
341 | |             String::from("Grace Hopper"),
342 | |             String::from("grace@example.com"),
343 | |             String::new(),
344 | |         );
    | |_________^ mutable borrow occurs here
345 |           assert_eq!(ada.name, "Ada Lovelace");
    |           ------------------------------------ immutable borrow later used here
```

Read the three labels in order. They tell a story:

1. **immutable borrow occurs here**: `ada` borrows from `store` (through `all()`).
2. **mutable borrow occurs here**: `add` needs `&mut store`, and it might reallocate.
3. **immutable borrow later used here**: `ada` is still needed *after* the mutation. This
   is what makes it an error. Without label 3, the first borrow would already be over.

Four questions: *owner:* `store` → *moved:* no → *borrows:* a shared one (`ada`) and then a
mutable one (`add`) → *how long must `ada` live:* until the `assert_eq!`, which is past the
`add`. Overlap → rejected. With only one customer, this exact code wouldn't even
reallocate. But the compiler reasons about **what could happen**, not what happens to
happen today.

Fixes, priced:

- **Shorten the borrow:** do the assertion before the second `add`. Zero cost. Right when
  the order doesn't matter.
- **Hold an id, not a reference:** `let ada_id = 1;` … `store.add(...)` …
  `store.find(ada_id)`. Look it up again *after* the mutation. An id is a `u32` (Copy),
  owns nothing, and can't dangle. **This is the pattern the rest of the course is built on**
  (Lab 14 builds relationships out of ids for exactly this reason).
- **Clone the customer:** works, costs allocations, and you're now asserting on a *copy*.
  Wrong tool here.

Delete the test.

> 🟡 **EXPERIMENT 2**: a data-entry mistake swapped Ada's and Grace's emails. Fix both at once?
> Predict first.

```rust
#[test]
fn swap_emails() {
    let mut store = CustomerStore::new();
    store.add(
        String::from("Ada Lovelace"),
        String::from("grace@example.com"),
        String::new(),
    );
    store.add(
        String::from("Grace Hopper"),
        String::from("ada@example.com"),
        String::new(),
    );
    let ada = store.find_mut(1).unwrap();
    let grace = store.find_mut(2).unwrap();
    ada.update_email(String::from("ada@example.com"));
    grace.update_email(String::from("grace@example.com"));
}
```

(`unwrap()` means "give me what's inside the `Some`, or crash". That's acceptable in tests,
and Lab 12 discusses when it's acceptable elsewhere.)

```text
error[E0499]: cannot borrow `store` as mutable more than once at a time
   --> src/main.rs:362:21
    |
361 |         let ada = store.find_mut(1).unwrap();
    |                   ----- first mutable borrow occurs here
362 |         let grace = store.find_mut(2).unwrap();
    |                     ^^^^^ second mutable borrow occurs here
363 |         ada.update_email(String::from("ada@example.com"));
    |         --- first borrow later used here
```

*But they're different customers!* True, and you know that. The compiler only sees two
calls that each borrow **the whole store** exclusively. `find_mut(1)` and `find_mut(2)` could
return the same customer as far as the signature is concerned (imagine an id lookup bug).
Two `&mut` to the same value would be two writers. Rule 1 forbids it, so it forbids anything
that *might* be it.

**Fix: one exclusive borrow at a time.** Each borrow ends as soon as it's last used:

```rust
store.find_mut(1).unwrap().update_email(String::from("ada@example.com"));
store.find_mut(2).unwrap().update_email(String::from("grace@example.com"));
```

Each line borrows, mutates and releases. This compiles. (For the rare case where you
really need two `&mut` into one `Vec` at once, there are tools like `split_at_mut` and
`get_disjoint_mut` that check for overlap. You won't need them in this course.) Delete the test.

---

## ▶️ Run It
```bash
cargo run
```

## ✅ Expected Result
```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@example.com
Phone:
Added customer #2
crm> add
Name: Ada Again
Email: ada@example.com
A customer with email ada@example.com already exists.
crm> show
Customer id: 2
#2 Grace Hopper <grace@example.com>
(no phone on file)
crm> show
Customer id: 7
No customer with id 7.
crm> show
Customer id: abc
Invalid id: abc
crm> update
Customer id: 1
New email: ada@lovelace.dev
Updated customer #1
crm> list
#1 Ada Lovelace <ada@lovelace.dev> 555-0100
#2 Grace Hopper <grace@example.com>
crm> quit
Goodbye! (7 commands this session)
```

Notice the duplicate `add` no longer asks for a phone number. (It also isn't counted in
"Goodbye!", because of the `continue`, just as in Lab 05.)

## 🧠 Understand It

**References are compile-time read/write locks.** Every `&` is a read lock and every `&mut`
is a write lock on a value, and the compiler checks them *before the program runs*. That
costs nothing at runtime: the lock exists only in the compiler's analysis. A read lock
can be shared; a write lock can't coexist with anything. The standard library's `RwLock`
("many readers or one writer") is literally the runtime version of this rule, for data shared
between threads. You'll recognise it when locks appear in Lab 25.

**Your store's API is now a contract you can read without reading the code:**

```text
fn new() -> Self                                   creates, gives you ownership
fn add(&mut self, String, String, String) -> u32   changes the store; keeps your strings
fn all(&self) -> &Vec<Customer>                    reads; lends you a view
fn find(&self, u32) -> Option<&Customer>           reads; maybe lends you one customer
fn find_mut(&mut self, u32) -> Option<&mut Customer>  maybe lends you exclusive access to one
fn email_exists(&self, &str) -> bool               reads; only looks at your email
fn len(&self) -> usize                             reads; gives you a number
```

A caller holding only a `&CustomerStore` **cannot** add, update or delete. The type system
won't let them. That becomes very valuable once the store is shared between parts of a
program (a web server's request handlers, Lab 27).

**How to choose a receiver or parameter type.** Ask what the function needs to do with the
value:

| Needs to… | Take | CRM example |
|---|---|---|
| only look | `&T` | `find(&self)`, `summary(&self)`, `email_exists(…, email: &str)` |
| change it in place | `&mut T` | `add(&mut self, …)`, `update_email(&mut self, …)` |
| keep it, or destroy/convert it | `T` | `add(…, name: String, …)`, `update_email(…, email: String)`, `into_names(Vec<Customer>)` |

Start from `&T`. Move up to `&mut T` or `T` only when the function genuinely needs to. That
keeps the caller's options open: they can still use, change, or give away their value afterwards.

**Why `all()` returns `&Vec<Customer>`.** It lends out a view of the store's internals without
copying. In Lab 09 you'll change it to `&[Customer]`, which is a more flexible "view of some
customers" type, and see why that's the better contract.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: what if `all` tried to give the list away? Predict, then try:
>
> ```rust
> fn all(&self) -> Vec<Customer> {
>     self.customers
> }
> ```

<details><summary>Real output</summary>

```text
error[E0507]: cannot move out of `self.customers` which is behind a shared reference
  --> src/main.rs:66:9
   |
66 |         self.customers
   |         ^^^^^^^^^^^^^^ move occurs because `self.customers` has type `Vec<Customer>`, which does not implement the `Copy` trait
```

`&self` means the method **borrowed** the store. You can't give away something you only
borrowed, just as you can't sell a library book. Lab 08 meets this error (E0507) again in
the CRM.

</details>

> 🟡 **EXPERIMENT 2**: what if `len` took `self` instead of `&self`? It compiles on its own.
> Predict where the error appears and why.
>
> ```rust
> fn len(self) -> usize {
>     self.customers.len()
> }
> ```

<details><summary>Real output (trimmed)</summary>

```text
error[E0382]: borrow of moved value: `store`
   --> src/main.rs:129:20
    |
 95 |     let mut store = CustomerStore::new();
    |         --------- move occurs because `store` has type `CustomerStore`, which does not implement the `Copy` trait
...
 98 |     let commands_run = loop {
    |                        ---- inside of this loop
...
129 |                 if store.email_exists(&email) {
    |                    ^^^^^ value borrowed here after move
...
146 |             "count" => println!("{}", customer_count_label(store.len())),
    |                                                                  ----- `store` moved due to this method call, in previous iteration of loop
    |
note: `CustomerStore::len` takes ownership of the receiver `self`, which moves `store`
   --> src/main.rs:86:12
    |
 86 |     fn len(self) -> usize {
    |            ^^^^
```

A `self` receiver **consumes** the store. Counting the customers would destroy them all.
That's Lab 06's `for c in customers` bug again, now caused by a method signature. Receivers
are ownership decisions.

</details>

> 🟡 **EXPERIMENT 3**: in the `update` arm, try to print the customer list *while* holding the
> `&mut Customer`:
>
> ```rust
> Some(customer) => {
>     let email = prompt("New email: ");
>     println!("Store has {} customers", store.len());
>     customer.update_email(email);
>     println!("Updated customer #{id}");
> }
> ```
>
> Predict the error code. Then move the `store.len()` line to **after**
> `customer.update_email(email);`. Does it compile now? Why? (Answer in `solutions.md`. Lab 08
> builds on this.)

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1**: let `update` change name and phone too.

- [ ] `update` prompts for the id exactly as now (`Customer id: `), with the same
      `Invalid id: …` and `No customer with id N.` messages.
- [ ] Then it prompts, in this order: `Name (blank to keep): `, `Email (blank to keep): `,
      `Phone (blank to keep): `.
- [ ] Blank input keeps the current value. Non-blank input replaces it.
- [ ] Prints `Updated customer #N` at the end.
- [ ] No `.clone()`. Each new value is **moved** into the customer.
- [ ] You decide whether to add methods like `update_name` / `update_phone` on `Customer` or to
      assign fields directly. Write a one-line comment explaining your choice.

```text
crm> update
Customer id: 1
Name (blank to keep):
Email (blank to keep): ada@lovelace.dev
Phone (blank to keep):
Updated customer #1
crm> show
Customer id: 1
#1 Ada Lovelace <ada@lovelace.dev> 555-0100
```

> Lab 08 builds on this exact version of `update` (with these three prompts).

---

> 🔵 **YOUR TURN 2**: test the store's contract.

In `mod tests`, write a helper `fn store_with_ada_and_grace() -> CustomerStore` (Ada with
phone `555-0100`, Grace with an empty phone, added in that order), and these tests:

- [ ] `add_assigns_sequential_ids`: adding a third customer returns id `3`, and `len()` is 3.
- [ ] `find_returns_none_for_unknown_id`: `find(99)` is `None`.
- [ ] `find_returns_the_matching_customer`: `find(2)` is Grace.
- [ ] `find_mut_changes_are_visible_through_find`: change customer 1's email through
      `find_mut`, then check it through `find`.
- [ ] `email_exists_matches_exact_email`: true for `ada@example.com`, false for an unknown email.
- [ ] Notice which tests need `let mut store` and which can use `let store`. Can you predict it
      from the method signatures alone?
- [ ] `cargo test` passes.

---

> 🔵 **YOUR TURN 3**: `find_by_email`, and `email_exists` built on top of it.

- [ ] Add `fn find_by_email(&self, email: &str) -> Option<&Customer>` to `CustomerStore`. It
      returns the customer whose email matches (use `Customer::matches_email`), if any.
- [ ] Rewrite `email_exists` as a one-liner that calls `find_by_email`. (Look at the methods
      `Option` has for asking "is there something in here?")
- [ ] Add a test `find_by_email_returns_the_owner_of_the_email` (Grace's email → id 2; unknown → `None`).
- [ ] No new warnings from `cargo clippy`.
- [ ] Answer in a comment above `find_by_email`: the signature has **two** reference inputs
      (`&self` and `email: &str`). Which one does the returned `&Customer` borrow from, and
      why does that matter for the caller? (Lab 10 explains exactly how the compiler decides.
      Make your best guess now.)

> Lab 08 uses `find_by_email`, so don't skip this one.

## 💡 Hint

> 💡 **HINT (`find_mut` mini-task)**: `Vec` has `iter()` → `&T` and `iter_mut()` → `&mut T`.
> Everything else stays the same.

> 💡 **HINT (Your Turn 1)**: you already hold `customer: &mut Customer`. Through it you can
> assign a field (`customer.name = name;`) or call a `&mut self` method. Both move the new
> `String` in, and both drop the old one.

<details><summary>Hint 2 for Your Turn 1</summary>

`String` has an `is_empty()` method. Prompt for a value, then `if !value.is_empty() { … }`.
Three prompts, three `if`s. Because `prompt` doesn't touch `store`, it's fine to call it while
you hold the `&mut Customer`.

</details>

> 💡 **HINT (Your Turn 2)**: a test that only calls `&self` methods never needs `mut`. A
> helper that returns `CustomerStore` returns **ownership** of the whole store, so the test
> can decide for itself whether its binding is `mut`.

> 💡 **HINT (Your Turn 3)**: `find_by_email` is `find` with a different condition. Comparing
> `customer.matches_email(email)` is the comparison you already have. For the one-liner,
> look for `is_some` in the `Option` docs.

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code (answers in `solutions.md`):

1. What is a `&Customer` at runtime? What does it guarantee at compile time?
2. State the borrowing rule in one sentence. Then explain, using the word *reallocate*, why
   you can't hold a `&Customer` from the store across `store.add(...)`.
3. Why does `find_mut` need `&mut self`, when it doesn't change the store itself?
4. What's the difference between `E0502` and `E0499`? Give a CRM example of each.
5. `E0596` appeared twice in this lab, for two different reasons. What were they?
6. For each signature, would a caller with only a `&CustomerStore` be able to call it?
   `len`, `find`, `find_mut`, `add`, `email_exists`.
7. **Predict:** does this compile?

   ```rust
   let count = store.len();
   store.add(String::from("Alan"), String::from("alan@example.com"), String::new());
   println!("{count}");
   ```

8. **Predict:** does this compile?

   ```rust
   let all = store.all();
   store.add(String::from("Alan"), String::from("alan@example.com"), String::new());
   println!("{}", all.len());
   ```

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit
```bash
git add .
git commit -m "Add CustomerStore with borrowing API"
git tag lab-07
git push && git push --tags
```

# Lab 06 — Ownership: Moves, Clones & Drops

> **Phase:** 2 — Ownership & Borrowing · **Builds on:** Lab 05 · **Time:** ~3–4 hours
> **Your repo before this lab:** tag `lab-05` · **After:** tag `lab-06`

> This lab assumes you completed **Your Turn 2** (reject duplicate emails) and **Your Turn 3**
> (`matches_email` and its tests) in Lab 05. See its `solutions.md` if not. Your `add` command
> should already refuse an email that's in the list.

## 🎯 Goal
Refactor how the CRM creates customers so that **every value has one clear owner**. You'll
extract `read_new_customer(id) -> Customer`, push the result into the list, and along the way
deliberately break the code to see **why** Rust moves values instead of copying or sharing them.

## 🧠 What You'll Learn
- Stack vs heap, and what a `String`, a `Customer` and a `Vec<Customer>` look like in memory
- The three ownership rules
- What a **move** physically is: a bitwise copy of a few bytes, plus invalidating the source
- **Why** moves exist: they make double-frees impossible, without a garbage collector
- Moves on assignment, on function calls, on return, and into `for` loops
- `Copy` vs `Clone`: why `u32` copies, why `String` moves, and why `.clone()` is a visible cost
- Scope and `Drop`: watching values die
- A reasoning script for every ownership error (you'll use it for the rest of the course)

## 🔨 What We're Building
Right now the `add` command reads three `String`s and builds a `Customer` in-line. We'll move
that into a function that **returns an owned `Customer`**, then push it into the list. It's a
small refactor. What matters is everything you'll learn by getting it wrong first:
`E0382 use of moved value` in three different places, `E0204`, `E0599` and `E0509`.

You'll also add a temporary `Drop` implementation that prints a line whenever a `Customer`
is destroyed. This lets you *see* ownership happen. It gets removed at the end of the lab.

> 💬 **How to work through this lab.** It's long on purpose. Every 🟡 block asks you to
> **predict** first. Write your prediction down (a comment, a notebook, anything) *before* you
> run `cargo check`. Being wrong and finding out why is how this part of Rust sticks.

---

## Step 1 — Where we're starting

Open `src/main.rs`. After Lab 05 you have this (bodies elided; your wording may differ a
little, and that's fine):

```rust
#[derive(Debug)]
struct Customer {
    id: u32,
    name: String,
    email: String,
    phone: String,
}

impl Customer {
    fn new(id: u32, name: String, email: String, phone: String) -> Self { /* ... */ }
    fn summary(&self) -> String { /* ... */ }      // uses has_phone()
    fn has_phone(&self) -> bool { /* ... */ }
    fn matches_email(&self, email: &str) -> bool { /* ... */ }
}

// below main:
fn print_help() { /* ... */ }
fn prompt(label: &str) -> String { /* ... */ }
fn customer_count_label(count: usize) -> String { /* ... */ }
fn next_id(current: u32) -> u32 { /* ... */ }
```

and inside the command loop in `main`:

```rust
let mut customers: Vec<Customer> = Vec::new();
let mut next_customer_id: u32 = 1;
// ...
"add" => {
    let name = prompt("Name: ");
    let email = prompt("Email: ");

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

Remember Lab 05's Experiment 2? You changed that `println!` to print `customer.id` after the
`push`, got an error, and were told not to fix it yet. This lab is where you find out what
that error means, and why the code above prints `next_customer_id` instead.

This works. But look at it with new eyes and ask one question about every value:
**who is responsible for it right now?**

- `name` is created by `prompt`. Then it's in a local variable in the `add` arm. Then it's
  inside a `Customer`. Then that `Customer` is inside `customers`. Who's responsible at the end?
- What happens to the memory behind `name` when the user types `quit`?

In JavaScript you never ask this. A garbage collector notices when nobody can reach an
object any more, and frees it *eventually*. Rust has no garbage collector. Instead, the
compiler tracks **who owns each value**, and frees memory at the exact moment its owner
goes away. To understand how, we need to look at memory.

> ℹ️ Your line numbers will differ from the ones in the error outputs shown in this lab.
> Read the labels and the arrows, not the numbers.

---

## Step 2 — Stack and heap: what a `String` really is

A running program has two main places to keep data:

| | **Stack** | **Heap** |
|---|---|---|
| What lives there | Local variables, function arguments | Data whose size is only known at runtime, or that must outlive a function call |
| Size | Fixed, known at compile time | Any size, can grow |
| Allocation | Free: move a pointer | Ask the allocator (costs time) |
| Freed when | The function returns | **Someone frees it explicitly**. In Rust: the owner, automatically |

A `u32` is 4 bytes, always. It lives directly on the stack. But a customer's name could be
`"Al"` or `"Maria José Fernández-Ålund"`, so the *text* has to live on the heap. The `String`
variable itself is a small, fixed-size **handle** to that heap memory:

```text
 let name = String::from("Ada Lovelace");

 STACK (fixed size)                         HEAP (allocated at runtime)
 name: String
 ┌───────────────────┐                      ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
 │ ptr ──────────────┼─────────────────────►│ A │ d │ a │   │ L │ o │ v │ e │ l │ a │ c │ e │
 │ len = 12          │  bytes in use        └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
 │ cap = 12          │  bytes allocated      ▲
 └───────────────────┘                       └── `name` is responsible for freeing this
   24 bytes (3 × 8)
```

Three machine words: a **pointer** to the heap buffer, the **length** in use, and the
**capacity** allocated. That's all a `String` is. The text itself is somewhere else.

Compare that with a string *literal*:

```text
 let label = "Name: ";           // type &str

 STACK                                       READ-ONLY DATA IN YOUR BINARY
 label: &str                                 ┌───┬───┬───┬───┬───┬───┐
 ┌───────────────────┐                       │ N │ a │ m │ e │ : │   │   baked in at compile time,
 │ ptr ──────────────┼──────────────────────►└───┴───┴───┴───┴───┴───┘   never freed, owned by nobody
 │ len = 6           │
 └───────────────────┘
```

So `String::from("Ada Lovelace")` (and `"Ada Lovelace".to_string()`, which does the same thing)
**allocates a heap buffer and copies the literal's bytes into it**. That's why Lab 04 had you
write `String::from(...)` to build a `Customer`. The struct needs text it *owns*, not a view
of text baked into the binary. (`&str` gets the full treatment in Lab 09.)

Now a whole `Customer`:

```text
 STACK: customer: Customer (80 bytes)              HEAP
 ┌───────────────────────────────────┐
 │ name:  ptr ───────────────────────┼──────────► "Ada Lovelace"      (12 bytes)
 │        len 12, cap 12             │
 │ email: ptr ───────────────────────┼──────────► "ada@example.com"   (15 bytes)
 │        len 15, cap 15             │
 │ phone: ptr ───────────────────────┼──────────► "555-0100"          (8 bytes)
 │        len 8,  cap 8              │
 │ id:    1                          │  (4 bytes + 4 bytes of padding)
 └───────────────────────────────────┘
```

And your list, `Vec<Customer>`, is the same idea one level up. The `Vec` is a (ptr, len, cap)
handle to a heap buffer, and that buffer holds `Customer`s *side by side*:

```text
 STACK                     HEAP: Vec's buffer (capacity 4 × 80 bytes)
 customers: Vec<Customer>  ┌────────────────────┬────────────────────┬──────────┬──────────┐
 ┌────────────────┐        │ Customer #1        │ Customer #2        │ (unused) │ (unused) │
 │ ptr ───────────┼───────►│ name ──► "Ada…"    │ name ──► "Grace…"  │          │          │
 │ len = 2        │        │ email ─► "ada@…"   │ email ─► "grace@…" │          │          │
 │ cap = 4        │        │ phone ─► "555…"    │ phone ─► "555…"    │          │          │
 └────────────────┘        └────────────────────┴────────────────────┴──────────┴──────────┘
```

Notice the shape: a **tree**. `customers` owns the buffer. The buffer holds the customers.
Each customer owns three heap strings. When `customers` is destroyed, the whole tree goes
with it, top-down. No leaks, no garbage collector. Keep this picture in mind for the
rest of Phase 2.

> 🟡 **EXPERIMENT**: predict, then measure.
>
> On a 64-bit machine, how many bytes is a `String`? A `Customer`? A `Vec<Customer>` that
> holds 1,000 customers? Write your three numbers down.
>
> Then add this **temporary** test inside your existing `mod tests`:
>
> ```rust
> #[test]
> fn sizes() {
>     println!("u32:           {} bytes", std::mem::size_of::<u32>());
>     println!("String:        {} bytes", std::mem::size_of::<String>());
>     println!("Customer:      {} bytes", std::mem::size_of::<Customer>());
>     println!("Vec<Customer>: {} bytes", std::mem::size_of::<Vec<Customer>>());
> }
> ```
>
> Run it with output visible (tests normally hide `println!`):
>
> ```bash
> cargo test sizes -- --nocapture
> ```
>
> ```text
> running 1 test
> u32:           4 bytes
> String:        24 bytes
> Customer:      80 bytes
> Vec<Customer>: 24 bytes
> test tests::sizes ... ok
> ```
>
> A `Vec<Customer>` is 24 bytes **no matter how many customers it holds**: `size_of`
> measures only the stack part. The customers live in the heap buffer. Delete the `sizes`
> test when you're done.

---

## Step 3 — The three ownership rules

Everything in this lab follows from three rules:

1. **Each value has exactly one owner** (a variable, a struct field, a slot in a `Vec`, …).
2. **There can only be one owner at a time.** Ownership can be *transferred* (moved), but not shared.
3. **When the owner goes out of scope, the value is dropped** (its heap memory is freed).

In CRM terms:

| Rule | In your CRM |
|---|---|
| One owner | The `String` holding `"Ada Lovelace"` is owned by the `name` field of one `Customer` |
| One at a time | When you `push` a customer, the `Vec` becomes its owner, and your local variable stops being one |
| Dropped with the owner | When `main` ends, `customers` goes out of scope → every `Customer` → every `String` is freed |

Rule 2 is the surprising one. Let's watch it in action.

---

## Step 4 — Extract `read_new_customer`

The `add` arm does two jobs: *ask the user for data* and *store a customer*. Let's split
out the first job into a function that **creates a customer and gives it to the caller**.

> 🟢 **FOLLOW ALONG**: add this function next to `prompt` (below `main`).

```rust
fn read_new_customer(id: u32) -> Customer {
    let name = prompt("Name: ");
    let email = prompt("Email: ");
    let phone = prompt("Phone: ");
    Customer::new(id, name, email, phone)
}
```

Now replace your whole `add` arm with this. Yes, your duplicate-email check disappears for
now. You'll rebuild it around the new design in **Your Turn 1**, and the redesign is the
point.

```rust
"add" => {
    let customer = read_new_customer(next_customer_id);
    println!("Added customer #{}", customer.id);
    customers.push(customer);
    next_customer_id = next_id(next_customer_id);
}
```

Run `cargo check`. It compiles, with one warning:

```text
warning: method `matches_email` is never used
```

That's honest: the duplicate check was its only caller. Leave the warning for now. It goes
away when you finish Your Turn 1.

Now trace **one** value, the name, through its whole life.
This is the habit the whole phase is trying to build:

```text
 1. prompt():          let mut line = String::new();        `line` owns an empty String (no heap buffer yet)
                       read_line(&mut line)                 `line`'s buffer now holds "Ada Lovelace\n"
                       line.trim().to_string()              a NEW String "Ada Lovelace" is allocated
                       (function returns)                   the new String is MOVED OUT to the caller;
                                                            `line` goes out of scope → its buffer is FREED
 2. read_new_customer: let name = prompt("Name: ");         `name` owns "Ada Lovelace"
                       Customer::new(id, name, ...)         `name` is MOVED into the parameter of new()
 3. Customer::new:     Self { id, name, ... }               the parameter is MOVED into the struct field
                       (function returns)                   the Customer is MOVED OUT to the caller
 4. read_new_customer: (returns the Customer)               MOVED OUT again, to the add arm
 5. add arm:           let customer = ...                   `customer` owns it (and through it, the name)
                       customers.push(customer)             MOVED into the Vec's buffer
 6. end of main:       customers dropped                    Vec drops each Customer → each String freed
```

The heap bytes `"Ada Lovelace"` were written **once**, in step 1, and never copied again.
Every "move" above only shuffled the 24-byte handle (or the 80-byte struct holding it).

> 💬 **Why does `prompt` return `String` and not `&str`?** The text it read lives in
> `line`, a local variable that's destroyed when `prompt` returns. A `&str` pointing into it
> would point at freed memory. Returning the owned `String` hands responsibility for the
> heap buffer to the caller. That's a *move out of a function*, and it's how Rust functions
> hand you new data. (Lab 10 explains how the compiler stops you from returning that
> dangling `&str`.)

Commit this working refactor before you start breaking things:

```bash
git add .
git commit -m "Extract read_new_customer"
```

---

## Step 5 — First `E0382`: a move on assignment

> 🟡 **EXPERIMENT**: predict first. Does this compile? If not, which line fails?

Change the `add` arm to give the customer a "nicer name" before using it:

```rust
"add" => {
    let customer = read_new_customer(next_customer_id);
    let newest = customer;
    println!("Added customer #{}", customer.id);
    customers.push(newest);
    next_customer_id = next_id(next_customer_id);
}
```

```bash
cargo check
```

```text
error[E0382]: borrow of moved value: `customer`
  --> src/main.rs:79:48
   |
77 |                 let customer = read_new_customer(next_customer_id);
   |                     -------- move occurs because `customer` has type `Customer`, which does not implement the `Copy` trait
78 |                 let newest = customer;
   |                              -------- value moved here
79 |                 println!("Added customer #{}", customer.id);
   |                                                ^^^^^^^^^^^ value borrowed here after move
   |
note: if `Customer` implemented `Clone`, you could clone the value
  --> src/main.rs:6:1
   |
 6 | struct Customer {
   | ^^^^^^^^^^^^^^^ consider implementing `Clone` for this type
...
78 |                 let newest = customer;
   |                              -------- you could clone this value

For more information about this error, try `rustc --explain E0382`.
```

**Read the error** with the reasoning script. You'll use these four questions for every
ownership error in the course:

| Question | Answer here |
|---|---|
| **1. Who owns it?** | `customer` owned the `Customer` (line 77). |
| **2. Was it moved? Where?** | Yes, on line 78: `let newest = customer;` transferred ownership to `newest`. |
| **3. Is this a borrow? Shared or mutable?** | `println!` *borrows* its arguments (shared), hence "**borrow** of moved value". It wants to read `customer.id`, but `customer` no longer owns anything. |
| **4. How long must it live?** | Only for the `println!`. But it's already gone. |

### What a move physically is

In JavaScript, `const newest = customer` makes a second *reference* to the same object: two
names, one object, and the garbage collector sorts it out later. In Rust, `let newest = customer;`
does this:

```text
 BEFORE  let newest = customer;              AFTER
 customer ┌─────────────────┐                customer ┌ ─ ─ ─ ─ ─ ─ ─ ─ ┐
          │ id: 1           │                         │ (moved-from)      compiler forbids
          │ name:  ptr ─────┼──► "Ada…"               │                   any further use
          │ email: ptr ─────┼──► "ada@…"              └ ─ ─ ─ ─ ─ ─ ─ ─ ┘
          │ phone: ptr ─────┼──► "555…"      newest   ┌─────────────────┐
          └─────────────────┘                         │ id: 1           │
                                                      │ name:  ptr ─────┼──► "Ada…"   ← the SAME heap
                                                      │ email: ptr ─────┼──► "ada@…"     bytes; nothing
                                                      │ phone: ptr ─────┼──► "555…"      on the heap moved
                                                      └─────────────────┘
```

A move is:
1. a **bitwise copy of the 80 stack bytes** (cheap, like copying a few numbers), and
2. the compiler **marking the source as unusable** from that point on.

No heap data is copied. No code runs. There's no runtime "invalid" flag either: step 2 is
pure compile-time bookkeeping.

### Why Rust does this: the double free

Imagine Rust *didn't* invalidate `customer`. Both variables now hold pointers to the same
three heap buffers. At the end of the scope, rule 3 says each owner drops its value:

```text
 end of scope:  drop(newest)    → free("Ada…"), free("ada@…"), free("555…")   ✅
                drop(customer)  → free("Ada…"), free("ada@…"), free("555…")   💥 DOUBLE FREE
```

Freeing the same memory twice corrupts the allocator. It's a classic security hole in C and
C++. Rust's options were:

- **Deep-copy on every assignment** (slow and surprising: every `=` would allocate),
- **Reference counting / garbage collection** (runtime cost, and that's what JS does), or
- **Transfer ownership and forbid using the old name** ✅ zero cost, checked at compile time.

So `E0382` isn't Rust being fussy. It's the compiler proving that every heap buffer has
exactly one owner who frees it exactly once.

**Fix:** there was no reason for the second name. Delete `let newest = customer;` and go
back to the Step 4 version.

---

## Step 6 — Second `E0382`: a move into a function call

This is the error from Lab 05's Experiment 2, the one you were told not to fix yet.

Moving into a function parameter works exactly like moving into a variable, because a
parameter *is* a variable, owned by the function.

> 🟡 **EXPERIMENT**: predict first. Swap two lines so the customer is stored first and the
> confirmation is printed afterwards. That seems like the more natural order:

```rust
"add" => {
    let customer = read_new_customer(next_customer_id);
    customers.push(customer);
    println!("Added customer #{}", customer.id);
    next_customer_id = next_id(next_customer_id);
}
```

```text
error[E0382]: borrow of moved value: `customer`
  --> src/main.rs:79:48
   |
77 |                 let customer = read_new_customer(next_customer_id);
   |                     -------- move occurs because `customer` has type `Customer`, which does not implement the `Copy` trait
78 |                 customers.push(customer);
   |                                -------- value moved here
79 |                 println!("Added customer #{}", customer.id);
   |                                                ^^^^^^^^^^^ value borrowed here after move
   |
note: if `Customer` implemented `Clone`, you could clone the value
  --> src/main.rs:6:1
   |
 6 | struct Customer {
   | ^^^^^^^^^^^^^^^ consider implementing `Clone` for this type
...
78 |                 customers.push(customer);
   |                                -------- you could clone this value
```

**Reasoning script:**

1. **Who owns it?** `customer`, until line 78.
2. **Moved? Where?** Into `push`. Look at its signature in the docs:
   `pub fn push(&mut self, value: T)`. The parameter is `value: T`, not `&T`. `push`
   *takes ownership*, and has to: it moves the 80 bytes into the `Vec`'s heap buffer, and from
   then on the `Vec` is responsible for dropping it.
3. **Borrow?** `println!` wants a shared borrow of `customer.id`.
4. **How long?** Just for the print. But `customer` stopped owning anything on line 78.

### Choosing a fix (there are several, and they aren't equal)

**Fix A: print before you push** (reorder).

```rust
println!("Added customer #{}", customer.id);
customers.push(customer);
```

Cost: zero. Read everything you need from a value *before* you give it away.

**Fix B: copy out the piece you need, then move the rest.**

```rust
let id = customer.id;          // u32 is Copy: `id` is an independent copy
customers.push(customer);
println!("Added customer #{id}");
```

Cost: copying 4 bytes. Useful when the "after" code is far from the move, or when you need the
data *after* the move for some other reason.

**Fix C: do what the compiler's note suggests, and clone.**

> 🟡 **EXPERIMENT**: try `customers.push(customer.clone());` and predict the error.

```text
error[E0599]: no method named `clone` found for struct `Customer` in the current scope
  --> src/main.rs:78:41
   |
 6 | struct Customer {
   | --------------- method `clone` not found for this struct
...
78 |                 customers.push(customer.clone());
   |                                         ^^^^^ method not found in `Customer`
   |
   = help: items from traits can only be used if the trait is implemented and in scope
   = note: the following trait defines an item `clone`, perhaps you need to implement it:
           candidate #1: `Clone`
```

`Customer` can't be cloned until you opt in with `#[derive(Debug, Clone)]`. If you do,
it compiles, but look at what you've paid for:

```text
 customer.clone()  →  allocate "Ada Lovelace"     (new heap buffer + copy 12 bytes)
                      allocate "ada@example.com"  (new heap buffer + copy 15 bytes)
                      allocate "555-0100"         (new heap buffer + copy  8 bytes)
                      ... all of it to print a 4-byte number, and then `customer` is dropped
                      (3 more frees) at the end of the arm.
```

Worse, for a moment there are **two** customer #1s in your program. That's harmless here,
but in a CRM "two copies of the same customer that can drift apart" is a real bug class.

**Fix D (preview): borrow it back from the list.** After the push, the `Vec` owns the customer,
but you can still *look* at it through the `Vec`: `customers.last()`. That's borrowing, and
it's Lab 07.

**Which is right?** Fix A. The id is ready before the push, printing first costs nothing, and
the code reads in the order things happen: build → announce → store. Fix B is equally correct
when reordering isn't possible. Clone is a legitimate tool, but it should be a **decision you
can justify** ("I need two independent copies"), never a way to silence the compiler. Remove
the `.clone()` and `Clone` derive if you added them.

> 🧭 **Rule of thumb:** when the compiler suggests `.clone()`, read that as "here's *one* way
> to make this compile". It doesn't mean "this is what you meant".

---

## Step 7 — `Copy` vs `Clone`: why `next_customer_id` never moves

Look at this line from the `add` arm:

```rust
let customer = read_new_customer(next_customer_id);
// ...
next_customer_id = next_id(next_customer_id);
```

`next_customer_id` is passed *by value* to two functions, yet it's still usable afterwards.
Why doesn't it get moved?

Because `u32` is **`Copy`**. For a `Copy` type, "move" and "copy" are physically identical
(a bitwise copy of the bytes), but the compiler **doesn't invalidate the source**. That's
only safe because a `u32` owns nothing else: copying its 4 bytes produces a completely
independent value, so nothing can be freed twice.

| | `Copy` | `Clone` |
|---|---|---|
| How it happens | Implicitly, on every assignment / call | Explicitly: you write `.clone()` |
| What it does | Bitwise copy of the stack bytes | Whatever the type defines. For `String`: allocate + copy the heap bytes |
| Cost | Tiny, always | Can be large (allocations), and **visible in the code** |
| Which types | Integers, floats, `bool`, `char`, shared references `&T`, tuples/arrays of `Copy` types | Almost everything, including `String`, `Vec<T>`, your structs (if derived) |
| Can it own heap memory? | **No.** That's the whole point | Yes |

`String` *can't* be `Copy`: a bitwise copy of a `String` is the (ptr, len, cap) handle,
which would give you two owners of one heap buffer. That's the double free from Step 5.
So Rust makes you choose explicitly: **move** it (cheap, old name unusable) or **clone** it
(expensive, two independent strings).

> 🟡 **EXPERIMENT**: predict first. What happens if you make `Customer` `Copy`?
>
> ```rust
> #[derive(Debug, Clone, Copy)]
> struct Customer {
> ```

```text
error[E0204]: the trait `Copy` cannot be implemented for this type
 --> src/main.rs:6:8
  |
5 | #[derive(Debug, Clone, Copy)]
  |                        ---- in this derive macro expansion
6 | struct Customer {
  |        ^^^^^^^^
7 |     id: u32,
8 |     name: String,
  |     ------------ this field does not implement `Copy`
```

A struct can only be `Copy` if **every field** is `Copy`. One `String` field is enough to rule
it out, and the compiler points straight at it. Put the derive back to `#[derive(Debug)]`.

> 💬 **Design note.** Later in the course, small types that own nothing *will* be `Copy` on
> purpose: `CustomerStatus` (Lab 11), `CompanyId` (Lab 14), `Money` (Lab 18). When a type is
> just "a few numbers with a meaning", `Copy` makes it pleasant to pass around. When it owns
> heap data, moves are the honest default.

---

## Step 8 — Third `E0382`: the `for` loop that eats your list

> 🟡 **EXPERIMENT**: predict first. In the `list` arm, change `for customer in &customers` to
> iterate over `customers` directly (no `&`). Will it compile? If not, which line will the
> error point at? (Hint: it may not be in the `list` arm.)

```rust
"list" => {
    if customers.is_empty() {
        println!("No customers yet.");
    } else {
        for customer in customers {
            println!("{}", customer.summary());
        }
    }
}
```

```text
error[E0382]: borrow of moved value: `customers`
  --> src/main.rs:79:17
   |
44 |     let mut customers: Vec<Customer> = Vec::new();
   |         ------------- move occurs because `customers` has type `Vec<Customer>`, which does not implement the `Copy` trait
...
48 |     let commands_run = loop {
   |                        ---- inside of this loop
...
79 |                 customers.push(customer);
   |                 ^^^^^^^^^ value borrowed here after move
...
86 |                     for customer in customers {
   |                                     --------- `customers` moved due to this implicit call to `.into_iter()`, in previous iteration of loop
   |
note: the `for` loop is desugared into a call to `std::iter::IntoIterator::into_iter`, which takes ownership of the receiver `self`, which moves `customers`
  --> /rustc/.../library/core/src/iter/traits/collect.rs:312:17
help: consider iterating over a slice of the `Vec<Customer>`'s content to avoid moving into the `for` loop
   |
86 |                     for customer in &customers {
   |                                     +
```

This one rewards careful reading.

1. **Who owns it?** `customers`, declared on line 44, *outside* the command loop.
2. **Moved? Where?** On line 86: `for customer in customers` calls `customers.into_iter()`,
   which takes the `Vec` **by value**. The loop *consumes* the list: each iteration moves one
   `Customer` out into `customer`, and drops it at the end of that iteration.
3. **Why is the error on line 79, in `add`?** Because of "**in previous iteration of loop**".
   The compiler considers every path: type `list` once, the `Vec` is consumed; then type
   `add`, and `customers.push(...)` touches a `Vec` that no longer exists. It reports the
   *use*, and points back at the *move*.
4. **How long must it live?** `customers` must survive across every iteration of the command
   loop, until `main` ends. So nothing inside the loop may take ownership of it.

What would "consume the list" even mean in a CRM? `list` would print every customer
and then **delete them all**. The compiler just stopped a data-loss bug.

**Fix:** put the `&` back: `for customer in &customers`. That iterates over **borrowed**
customers, so the loop can *look* at each one without taking it. You've been writing that `&`
since Lab 05. Now you know what it prevents. The full story of `&` is Lab 07.

### The same thing, through a function

> 🟡 **EXPERIMENT**: what if `list` called a helper function?

```rust
fn print_list(customers: Vec<Customer>) {
    if customers.is_empty() {
        println!("No customers yet.");
    } else {
        for customer in &customers {
            println!("{}", customer.summary());
        }
    }
}
```

```rust
"list" => print_list(customers),
```

```text
error[E0382]: borrow of moved value: `customers`
   --> src/main.rs:79:17
    |
 44 |     let mut customers: Vec<Customer> = Vec::new();
    |         ------------- move occurs because `customers` has type `Vec<Customer>`, which does not implement the `Copy` trait
...
 48 |     let commands_run = loop {
    |                        ---- inside of this loop
...
 79 |                 customers.push(customer);
    |                 ^^^^^^^^^ value borrowed here after move
...
 82 |             "list" => print_list(customers),
    |                                  --------- value moved here, in previous iteration of loop
    |
note: consider changing this parameter type in function `print_list` to borrow instead if owning the value isn't necessary
   --> src/main.rs:132:26
    |
132 | fn print_list(customers: Vec<Customer>) {
    |    ----------            ^^^^^^^^^^^^^ this parameter takes ownership of the value
    |    |
    |    in this function
note: if `Customer` implemented `Clone`, you could clone the value
...
help: consider moving the expression out of the loop so it is only moved once
    |
 48 ~     let commands_run = let mut value = print_list(customers);
 49 ~     loop {
 50 |         print!("crm> ");
...
 82 |             }
 83 ~             "list" => value,
    |
```

(As before, the error is reported at the *next use* of `customers`, which is the push in `add`.)

Two lessons:

- The parameter type **is the ownership decision**. `customers: Vec<Customer>` says "give me
  the list, I'm keeping it". When `print_list` returns, its parameter goes out of scope, so the
  whole list is **dropped**.
- The last `help:` is nonsense (it suggests moving the call out of the loop, which would
  print the list once at startup). Compiler suggestions are mechanical. *You* decide what
  the code means.

The ownership-only way to fix this is to **give the list back**:

```rust
fn print_list(customers: Vec<Customer>) -> Vec<Customer> {
    // ...same body...
    customers
}
```

```rust
"list" => customers = print_list(customers),
```

This compiles. Ownership goes into the function and comes back out. But imagine doing that
for every function that only wants to *look* at something. Lab 07's borrowing exists to solve
exactly this. The note in the error already told you: "consider changing this parameter type
… to borrow instead".

Undo the experiment: delete `print_list` and restore the original `list` arm with `&customers`.

---

## Step 9 — Scope and `Drop`: watching values die

Rule 3 says values are dropped when their owner goes out of scope. To *see* that, implement
the `Drop` trait for `Customer`. `Drop` has one method, `drop(&mut self)`, which Rust calls
automatically just before the value's memory is freed. You never call it yourself.

> 🔵 **YOUR TURN** (mini-task): implement `Drop` for `Customer`.
>
> - Put an `impl Drop for Customer { ... }` block after `impl Customer`.
> - Its `drop` method prints exactly `[drop] #<id> <name>`, e.g. `[drop] #1 Ada Lovelace`.
> - Mark it as temporary: `// TEMPORARY (Lab 06): remove before committing`.
> - `cargo check` passes.
>
> The syntax is the same as any `impl Trait for Type` block. The method signature is
> `fn drop(&mut self)`. If you're stuck, see the hint section.

Now watch a session:

```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@example.com
Phone: 555-0199
Added customer #2
crm> quit
Goodbye! (2 commands this session)
[drop] #1 Ada Lovelace
[drop] #2 Grace Hopper
```

Nothing is dropped while you work, because each customer was *moved* into the `Vec`,
and the `Vec` is still alive. Only when `main` finishes (after "Goodbye!") does `customers`
go out of scope. The `Vec` drops its elements **in order**, first to last, then frees its
buffer.

> 🟡 **EXPERIMENT**: predict first. Temporarily comment out the push:
>
> ```rust
> println!("Added customer #{}", customer.id);
> // customers.push(customer);
> ```
>
> Add one customer, then `list`, then `quit`. When does the `[drop]` line appear?

```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
[drop] #1 Ada Lovelace
crm> list
No customers yet.
crm> quit
Goodbye! (2 commands this session)
```

Without the move into the `Vec`, `customer` is still the owner when the `add` arm's block
ends at its closing `}`, so the customer dies right there. (You'll also see
`warning: variable does not need to be mutable` because nothing changes `customers` any more.)
Same value, same code. The only difference is **who owns it when a scope ends**. Restore the push.

> 🟡 **EXPERIMENT**: predict the exact output order, then run it. Add this temporary test:
>
> ```rust
> #[test]
> fn watch_drops() {
>     let ada = Customer::new(1, String::from("Ada"), String::new(), String::new());
>     let grace = Customer::new(2, String::from("Grace"), String::new(), String::new());
>     println!("created both");
>     {
>         let _alan = Customer::new(3, String::from("Alan"), String::new(), String::new());
>         println!("inner scope ends");
>     }
>     let _kept = ada;
>     drop(grace);
>     println!("end of test");
> }
> ```
>
> ```bash
> cargo test watch_drops -- --nocapture
> ```

<details><summary>Real output (check your prediction first)</summary>

```text
running 1 test
created both
inner scope ends
[drop] #3 Alan
[drop] #2 Grace
end of test
[drop] #1 Ada
test tests::watch_drops ... ok
```

- **Alan** dies at the inner `}`, the end of the scope that owns him.
- **Grace** dies at `drop(grace)`. Look up `std::mem::drop` in the docs: its entire body is
  `pub fn drop<T>(_x: T) {}`. It isn't magic. It's an ordinary function that **takes
  ownership** and then does nothing, so its parameter goes out of scope immediately. You now
  understand ownership well enough to have written it yourself.
- **Ada** was moved into `_kept`. Moving doesn't drop anything. The new owner drops her
  at the end of the test.

</details>

> 🟡 **EXPERIMENT**: shadowing is **not** dropping. Predict when Ada is dropped here:
>
> ```rust
> #[test]
> fn shadowing_is_not_dropping() {
>     let customer = Customer::new(1, String::from("Ada"), String::new(), String::new());
>     println!("created {}", customer.name);
>     let customer = Customer::new(2, String::from("Grace"), String::new(), String::new());
>     println!("created {}", customer.name);
> }
> ```

<details><summary>Real output</summary>

```text
created Ada
created Grace
[drop] #2 Grace
[drop] #1 Ada
```

The second `let customer` creates a **new** variable that hides the first one's *name*. The
first variable still owns Ada until the end of the scope. Then locals are dropped in
**reverse order of declaration**: Grace (declared last) first, then Ada.

</details>

Delete the `watch_drops` and `shadowing_is_not_dropping` tests. **Keep the `Drop` impl for
now.** You'll use it in Your Turn 1 and remove it in Your Turn 3.

---

## ▶️ Run It
```bash
cargo run
```

## ✅ Expected Result
With the `Drop` impl still in place:

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
Phone: 555-0199
Added customer #2
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
crm> count
2 customers
crm> quit
Goodbye! (4 commands this session)
[drop] #1 Ada Lovelace
[drop] #2 Grace Hopper
```

(The number in "Goodbye!" depends on how you counted commands in Lab 03.)

## 🧠 Understand It

**Ownership is a tree, and moves re-parent branches.** At any moment, every heap allocation in
your CRM has exactly one path of owners leading to a variable on the stack:
`customers → buffer slot 0 → Customer #1 → name → "Ada Lovelace"`. A move cuts a branch from
one owner and attaches it to another. The heap bytes stay where they are; only the handle
moves. When a root (a local variable) goes out of scope, its whole subtree is dropped,
deepest values last.

**The cost model you can now read straight off the code:**

| You write | What happens at runtime |
|---|---|
| `let b = a;` / `f(a)` / `return a` (a is not `Copy`) | memcpy of the stack part (24 bytes for a `String`, 80 for a `Customer`); no heap work |
| `let b = a;` (a is `Copy`, like `u32`) | memcpy, and `a` stays usable |
| `a.clone()` | **heap allocation(s) + copying every byte**, visible in your code |
| `}` (end of scope) | `drop` for every value still owned by a local, in reverse declaration order |

Rust makes the expensive thing (`clone`) look expensive, and the cheap thing (a move) look
cheap. In JavaScript, `const b = a` is always cheap *because* it shares. Rust gets the same
cheapness by **transferring** instead of sharing, and that's what lets it free memory
deterministically without a garbage collector.

**Why `read_new_customer` returns `Customer` (owned):** it *creates* the customer, so
the caller should become its owner. A function that creates a value and returns it is the
most natural ownership transfer there is. Compare with `summary(&self)`, which only *reads*
a customer. That `&` means "let me look, I'll give it back". Lab 07 is about that `&`.

**The reasoning script.** You've used it on five errors now:

1. **Who owns it?**
2. Was ownership **moved**? **Where?** (Assignment? Function argument? `for` loop? Return?)
3. Is this a **borrow**? Shared (`&`) or mutable (`&mut`)?
4. **How long** must the value or reference live, and how long does its owner live?

Then list the fixes, price them, and pick the one that matches what the code *means*.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: predict which of these compile, then check each one inside the
> `add` arm (one at a time, then undo):
>
> ```rust
> // (a)
> let customer = read_new_customer(next_customer_id);
> let id = customer.id;
> customers.push(customer);
> println!("Added customer #{id}");
>
> // (b)
> let customer = read_new_customer(next_customer_id);
> let name = customer.name;
> println!("Adding {name}");
> customers.push(customer);
>
> // (c)
> let id = next_customer_id;
> let customer = read_new_customer(id);
> println!("Next id would be {}", next_id(id));
> customers.push(customer);
> ```
>
> For each one that fails, answer the four questions. Answers are in `solutions.md`.
> (Hint for (b): `customer.name` is a `String`. What does `let name = ...` do to a `String`?
> With your `Drop` impl in place, (b) fails with a different error than it would without it.
> Try it both ways if you're curious.)

> 🟡 **EXPERIMENT 2**: in `read_new_customer`, try using `name` after passing it to
> `Customer::new`:
>
> ```rust
> let customer = Customer::new(id, name, email, phone);
> println!("Created {name}");
> customer
> ```
>
> Before you run it: which line moves `name`? What will the error code be?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1**: rebuild the duplicate-email check around the owned `Customer`.

Your `add` arm now gets a complete, owned `Customer` from `read_new_customer`. Put the
duplicate check back in.

- [ ] `add` still calls `read_new_customer(next_customer_id)` to build the customer.
- [ ] If any customer in `customers` already has the same email, print
      `A customer with email <email> already exists.` and do **not** add it. Use your
      `matches_email` method from Lab 05 for the comparison, so its "never used" warning goes away.
- [ ] A rejected customer does **not** use up an id: the next successful `add` gets the id the
      rejected one had.
- [ ] No `.clone()` anywhere in the `add` arm.
- [ ] With your `Drop` impl still in place, a rejection prints a `[drop]` line straight after
      the message. Add a one-line comment in the code saying **why** it's dropped there.
- [ ] Think about it (and answer in a comment): Lab 05 discussed keeping emails in a separate
      `HashSet<String>` for speed. With the `Customer` built first, why would that design now
      force you to clone every email? (Think: how many owners does each email need?)

Acceptance transcript:

```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Ada Again
Email: ada@example.com
Phone:
A customer with email ada@example.com already exists.
[drop] #2 Ada Again
crm> add
Name: Grace Hopper
Email: grace@example.com
Phone: 555-0199
Added customer #2
```

(Yes, the user now types a phone number before learning the email is taken. That's a real
UX regression, and Lab 07 fixes it with borrowing: you'll check the email *before* building a
customer.)

---

> 🔵 **YOUR TURN 2**: a test fixture that returns ownership, and tests that move customers around.

Tests are a great place to practise ownership, because you can build exactly the situation
you want. Inside your `mod tests`:

- [ ] Write a helper (not a test) `fn sample_customers() -> Vec<Customer>` that returns three
      customers: `#1 Ada Lovelace <ada@example.com> 555-0100`,
      `#2 Grace Hopper <grace@example.com>` (empty phone), `#3 Alan Turing <alan@example.com> 555-0300`.
- [ ] Test `sample_customers_has_three_customers_in_order`: 3 customers, ids 1, 2, 3 in order.
- [ ] Test `pop_gives_ownership_back`: take the **last** customer out of the vec with
      `Vec::pop` (it returns `Option<Customer>`, so `match` on it as in Lab 05). Assert its name
      is `"Alan Turing"`, and that 2 customers remain.
- [ ] Test `moving_a_customer_into_another_vec`: start from `sample_customers()` as `active`,
      create an empty `archived` vec, and **move** Grace from `active` into `archived` (look up
      `Vec::remove` in the docs and read its return type). Assert both lengths and that
      `archived[0].name == "Grace Hopper"`.
- [ ] No `.clone()` in any of it.
- [ ] `cargo test` passes. (With the `Drop` impl still in, run `cargo test -- --nocapture` and
      look at *when* each test's customers get dropped.)

Think about: `sample_customers` creates nine `String`s and three `Customer`s inside a
function. Why aren't they dropped when the function returns?

---

> 🔵 **YOUR TURN 3**: consume a list, and meet `Drop`'s hidden rule.

- [ ] In `mod tests`, write a helper `fn into_names(customers: Vec<Customer>) -> Vec<String>`
      that **consumes** the list and returns every customer's name, **without cloning**. The
      names must be *moved* out of the customers.
- [ ] Write a test `into_names_consumes_the_list` that checks the result for
      `sample_customers()` is `["Ada Lovelace", "Grace Hopper", "Alan Turing"]` (in that order).
- [ ] Run `cargo test` **with your `Drop` impl still in place**. You'll get an error you
      haven't seen before. Read it, answer the four questions, and write a short comment above
      `into_names` explaining it in your own words.
- [ ] Now **delete the `impl Drop for Customer` block** (it was always temporary).
      `cargo test` passes.
- [ ] Answer in a comment: what does the signature `fn into_names(customers: Vec<Customer>)`
      promise the caller, compared with a hypothetical `fn names(customers: &Vec<Customer>)`?

## 💡 Hint

> 💡 **HINT (Drop mini-task)**: the shape is
> `impl Drop for Customer { fn drop(&mut self) { /* println! using self.id and self.name */ } }`.

> 💡 **HINT (Your Turn 1)**: you need a `bool` that you compute by *looking at* the existing
> customers. Looking doesn't need ownership, so iterate over `&customers`, exactly as Lab 05
> did. What changes is *what* you compare against: the email now lives inside `customer`.
> Then one path moves the customer into the list, and the other (`continue`, or an `else`)
> just lets it fall out of scope.

<details><summary>Hint 2 for Your Turn 1 (more specific)</summary>

`matches_email` takes a `&str`, so lend it the new customer's email: `&customer.email`.

Only the success path should run `next_customer_id = next_id(next_customer_id);`. In the
reject path, `customer` is never moved. Where does its scope end?

For the `HashSet` question: the set would need to *own* a `String` with the email, and so
does the `Customer`. One value can't have two owners, so you'd need a second, independent
string, which means a clone.

</details>

> 💡 **HINT (Your Turn 2)**: `vec![a, b, c]` builds a `Vec` from values, moving each one in.
> The function's *return value* is moved out to the caller, along with everything it owns.

<details><summary>Hint 2 for Your Turn 2</summary>

`Vec::remove(index)` returns `T`: the element itself, **owned**, with the rest shifted left.
That's the "take something out of a collection" move. You'll use the same idea for `delete`
in Lab 08.

</details>

> 💡 **HINT (Your Turn 3)**: a `for` loop over a `Vec<Customer>` (no `&`) gives you each
> `Customer` **by value**. You own it, so you can move one of its fields out. The rest of the
> customer is dropped at the end of the iteration.

<details><summary>Hint 2 for Your Turn 3: the error you'll hit</summary>

```text
error[E0509]: cannot move out of type `Customer`, which implements the `Drop` trait
   --> src/main.rs:211:24
    |
211 |             names.push(customer.name);
    |                        ^^^^^^^^^^^^^
    |                        |
    |                        cannot move out of here
    |                        move occurs because `customer.name` has type `String`, which does not implement the `Copy` trait
    |
help: consider cloning the value if the performance cost is acceptable
    |
211 |             names.push(customer.name.clone());
    |                                     ++++++++
```

Think about what `drop(&mut self)` is promised: a **complete** `Customer`, with `self.name`
readable. If you moved `name` out first, what would `drop` print?

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code (answers in `solutions.md`):

1. Draw (on paper) the stack and heap for `let customers: Vec<Customer>` holding two customers.
   How many separate heap allocations are there?
2. What exactly happens, byte by byte, when `customers.push(customer)` runs? What is copied?
   What is *not* copied?
3. Why can't Rust just let both `customer` and `newest` stay valid after `let newest = customer;`?
4. Why is `u32` `Copy` but `String` isn't? Could `Customer` ever be `Copy`?
5. `for c in customers` vs `for c in &customers`: what does each one do to the list?
6. A colleague "fixes" an E0382 by adding `.clone()`. What two questions do you ask them?
7. **Predict:** does this compile? If not, which line fails and why?

   ```rust
   let customer = read_new_customer(1);
   let summary = customer.summary();
   customers.push(customer);
   println!("{summary}");
   ```

8. **Predict:** in what order are these dropped?

   ```rust
   let a = Customer::new(1, String::from("A"), String::new(), String::new());
   let b = Customer::new(2, String::from("B"), String::new(), String::new());
   let list = vec![b];
   let c = Customer::new(3, String::from("C"), String::new(), String::new());
   // end of scope
   ```

Before committing, make sure the temporary code is gone:

- [ ] no `impl Drop for Customer`
- [ ] no `sizes`, `watch_drops` or `shadowing_is_not_dropping` tests
- [ ] no `print_list` function, no `Clone`/`Copy` derive on `Customer`

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit
```bash
git add .
git commit -m "Refactor customer creation around ownership"
git tag lab-06
git push && git push --tags
```

Try `git diff lab-05 lab-06 -- src/main.rs`. The diff is small, but you now know why every
line of it is shaped the way it is.

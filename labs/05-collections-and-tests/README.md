# Lab 05 — Collections & Your First Tests 🧪

> **Phase:** 1 — Rust Foundations · **Builds on:** Lab 04 · **Time:** ~3 hours
> **Your repo before this lab:** tag `lab-04` · **After:** tag `lab-05`

> This lab assumes you completed **Your Turn 1 and 2 in Lab 04** (`has_phone` and
> `matches_email`). If you didn't, copy them from
> [Lab 04's `solutions.md`](../04-structs-and-methods/solutions.md) first.

## 🎯 Goal
Make the CRM useful for one session: type customers in with `add`, see them with `list`, and
count them with `count`, all held in memory. Then prove the core pieces work with your
first unit tests.

## 🧠 What You'll Learn
- `Vec<T>`: creating, `push`, `len`, `is_empty`, iterating with `for`
- Indexing (`v[0]`, which can panic) vs `.get(0)` (which returns an `Option`)
- `Option` with `Some` / `None`, gently (the full story is Lab 12)
- `HashMap` and `HashSet` basics, and when a second collection is (or isn't) worth it
- Writing a small helper (`prompt`) that returns an owned `String`
- Reading **dead-code warnings** as a to-do list
- `#[cfg(test)]`, `mod tests`, `#[test]`, `assert_eq!`, `assert!`, `cargo test`
- What a failing test looks like, `#[should_panic]`, and running a subset of tests

## 🔨 What We're Building
```text
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
crm> count
1 customer
```

The hard-coded `demo` disappears: from now on, customers come from **you**. They only live
until you quit (saving to a file is Lab 21), but that's enough to start using the CRM, and
enough to start **testing** it.

Tests start here, not in some "testing chapter" at the end. From this lab on, every lab adds
tests alongside the code. Writing a test is part of writing a feature.

---

## Step 1 — Retire the demo, and let the compiler make a to-do list

The `demo` command did its job: it was a place to try out structs. Remove it.

> 🟢 **FOLLOW ALONG**

1. Delete the `fn run_demo() { ... }` function.
2. Delete the `"demo" => run_demo(),` arm from the `match`.
3. Delete the `("demo", ...)` row from the table in `print_help`.

Now build:

```bash
cargo build
```

```text
warning: struct `Customer` is never constructed
 --> src/main.rs:6:8
  |
6 | struct Customer {
  |        ^^^^^^^^
  |
  = note: `#[warn(dead_code)]` (part of `#[warn(unused)]`) on by default

warning: associated items `new`, `summary`, `has_phone`, and `matches_email` are never used
  --> src/main.rs:14:8
   |
13 | impl Customer {
   | ------------- associated items in this implementation
14 |     fn new(id: u32, name: String, email: String, phone: String) -> Self {
   |        ^^^
...
23 |     fn summary(&self) -> String {
   |        ^^^^^^^
...
27 |     fn has_phone(&self) -> bool {
   |        ^^^^^^^^^
...
31 |     fn matches_email(&self, email: &str) -> bool {
   |        ^^^^^^^^^^^^^

warning: function `next_id` is never used
  --> src/main.rs:97:4
   |
97 | fn next_id(current: u32) -> u32 {
   |    ^^^^^^^

warning: function `id_stats` is never used
   --> src/main.rs:101:4
    |
101 | fn id_stats(current: u32) -> (u32, u32) {
    |    ^^^^^^^^
```

The compiler knows everything that's no longer reachable from `main`. Treat these warnings as
a **to-do list**:

- `id_stats` was a Lab 02 exercise in tuples, and the CRM doesn't need it. **Delete it.**
- `Customer`, `new`, `summary`, `next_id`: the `add` and `list` commands will use them in a
  moment.
- `has_phone` gets a real job in Step 6, and `matches_email` gets one in Your Turn 2.

A warning-free build is the standard you'll keep for the rest of the course. Warnings that are
"always there" stop being read.

---

## Step 2 — `Vec<Customer>`: somewhere to keep customers

> 🟢 **FOLLOW ALONG**: in `main`, right before `let mut count`, add:

```rust
    let mut customers: Vec<Customer> = Vec::new();
    let mut next_customer_id: u32 = 1;
```

- **`Vec<T>`** is Rust's growable list: the closest thing to a JS array. The `<Customer>` is
  a **type parameter**: this vector holds `Customer`s, and *only* `Customer`s. A `Vec` can't
  mix types the way a JS array can. (Generics are Lab 16, but you can already *use* them.)
- **`Vec::new()`** creates an empty vector. It doesn't allocate anything until the first
  `push`.
- **`mut`**: pushing changes the vector, so the binding has to be mutable. Same for the ID
  counter, which goes up after every `add`.
- **Where it's declared** matters. These two variables live *outside* the loop because they
  must survive from one command to the next, for the whole session. `input`, by contrast, lives
  inside the loop because each command gets a fresh one (Lab 03).

Memory picture (you'll draw this properly in Lab 06):

```text
 stack (main's variables)              heap
┌──────────────────────────┐        ┌───────────┬───────────┬─────┐
│ customers: ptr ──────────┼──────► │ Customer  │ Customer  │ ... │
│            len = 2       │        │ #1        │ #2        │     │
│            capacity = 4  │        └───────────┴───────────┴─────┘
└──────────────────────────┘
```

A `Vec` is three numbers on the stack (where the items are, how many there are, how much room
is reserved) plus a buffer of items on the heap. When the buffer is full, `push` allocates a
bigger one and moves everything over. Keep that "moves everything over" in mind, because it's
the reason for one of the borrow checker's most important rules (Lab 07).

---

## Step 3 — A `prompt` helper

`add` needs to ask three questions. Each one means print a label, flush, read a line, and trim.
That's four steps, three times. Make it a function.

> 🟢 **FOLLOW ALONG**: add below `print_help`:

```rust
fn prompt(label: &str) -> String {
    print!("{label}");
    io::stdout().flush().expect("failed to flush stdout");

    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .expect("failed to read from stdin");
    line.trim().to_string()
}
```

Look closely at the last line, because it answers a question you might have from Lab 03:

- `line.trim()` is a `&str`, a *view* into `line`'s buffer.
- But `line` is a local variable. It's cleaned up when `prompt` returns, buffer and all. A view
  into it can't leave the function, because there'd be nothing left to look at.
- `.to_string()` copies the trimmed text into a **new**, owned `String`, and *that* is what we
  return. The caller owns it from then on.

So the signature `fn prompt(label: &str) -> String` says: *"I borrow your label for a moment,
and I give you back text that's yours to keep."* That's the same shape as `format_customer`
in Lab 02, and the `Customer` that receives this `String` will own it. Lab 06 formalises all
of this. For now, notice that the types already tell the story.

---

## Step 4 — The `add` command

> 🟢 **FOLLOW ALONG**: add this arm to the `match`, above `"quit" | "exit"`:

```rust
            "add" => {
                let name = prompt("Name: ");
                let email = prompt("Email: ");
                let phone = prompt("Phone: ");

                let customer = Customer::new(next_customer_id, name, email, phone);
                customers.push(customer);
                println!("Added customer #{next_customer_id}");
                next_customer_id = next_id(next_customer_id);
            }
```

And add a row to the help table, after `version`:

```rust
        ("add", "Add a customer"),
```

Read it in order:

1. Three owned `String`s come back from `prompt`.
2. They're **handed over** to `Customer::new`, and the new customer now owns them.
3. **`customers.push(customer)`** hands the customer over to the vector. From here on, the
   vector owns it.
4. We print the ID using `next_customer_id`, a `u32` we still have, not `customer.id`. That
   choice is deliberate. Lab 06 opens by asking what would happen if you used `customer.id`
   *after* the `push`.
5. The counter advances through `next_id`, the same function from Lab 02, still the single
   place that knows how IDs advance.

> 🟡 **EXPERIMENT**: remove `mut` from `let mut next_customer_id` and run `cargo check`. You've
> seen this error before. Which lab, and what did it teach?

```text
error[E0384]: cannot assign twice to immutable variable `next_customer_id`
  --> src/main.rs:80:17
   |
41 |     let next_customer_id: u32 = 1;
   |         ---------------- first assignment to `next_customer_id`
...
80 |                 next_customer_id = next_id(next_customer_id);
   |                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ cannot assign twice to immutable variable
   |
help: consider making this binding mutable
   |
41 |     let mut next_customer_id: u32 = 1;
   |         +++
```

(Line numbers depend on exactly how your file is laid out.) Put `mut` back. This is the `mut` that's *really* justified: a
counter that evolves for the whole session.

---

## Step 5 — The `list` command

> 🟢 **FOLLOW ALONG**: add this arm below `add`, and a help row `("list", "List all customers")`
> below the `add` row:

```rust
            "list" => {
                if customers.is_empty() {
                    println!("No customers yet.");
                } else {
                    for customer in &customers {
                        println!("{}", customer.summary());
                    }
                }
            }
```

- **`customers.is_empty()`** is true when there are no items. (`customers.len() == 0` works
  too, but Clippy prefers `is_empty`.)
- **`for customer in &customers`** loops over the vector, giving you each customer in turn.

That **`&`** matters. `&customers` means "let me *look at* each customer". The loop **borrows**
the vector, and the vector still owns its customers afterwards, so `list` can run again and
again. Without the `&`, the loop would *take* the vector and its customers, and they'd be gone
after one `list`. Lab 06 makes you try exactly that and read the error. For now, the rule:
**to read through a collection you want to keep, loop over `&collection`.**

Run it:

```text
crm> list
No customers yet.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
```

---

## Step 6 — Put `has_phone` to work

`cargo build` still warns that `has_phone` is never used. Before deleting it, ask whether
anything *should* use it. Add a customer with no phone (just press Enter at `Phone:`), then
`list`:

```text
#2 Alan Turing <alan@example.com> 
```

There's a trailing space after the `>`. `summary` always appends a space and the phone,
even when there's no phone. That's a small bug, and `has_phone` is exactly the question
`summary` should ask.

> 🟢 **FOLLOW ALONG**: replace `summary` with:

```rust
    fn summary(&self) -> String {
        if self.has_phone() {
            format!("#{} {} <{}> {}", self.id, self.name, self.email, self.phone)
        } else {
            format!("#{} {} <{}>", self.id, self.name, self.email)
        }
    }
```

An `if` expression from Lab 03 picks the format, and `self.has_phone()` calls a method on the
same customer. Customers with a phone print exactly as before.

---

## Step 7 — Indexing vs `.get()`: a first look at `Option`

How do you get *one* item out of a `Vec`? Two ways, with very different failure modes.

> 🟡 **EXPERIMENT**: add a temporary `first` command (above `quit`), then run the CRM and type
> `first` **before adding anyone**. Predict what happens.

```rust
            "first" => println!("{}", customers[0].summary()),
```

```text
crm> first

thread 'main' (441760) panicked at src/main.rs:95:48:
index out of bounds: the len is 0 but the index is 0
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

**`customers[0]` panics** when there's no item 0. The CRM crashes, and the session is gone. In
JS, `customers[0]` would quietly be `undefined`, and the crash would happen somewhere later,
further from the real cause. Rust fails *at* the bad access, which is better. But the program
still dies.

`.get(0)` asks instead of assuming. It returns an **`Option`**: either `Some(customer)` or `None`.

> 🟢 **FOLLOW ALONG**: rewrite the temporary arm:

```rust
            "first" => match customers.get(0) {
                Some(customer) => println!("{}", customer.summary()),
                None => println!("No customers yet."),
            },
```

```text
crm> first
No customers yet.
```

- **`Option<T>`** is how Rust says "maybe a value". There's no `null` or `undefined` in safe
  Rust. A value that might be missing has a *different type*, and you can't use the customer
  inside until you've handled the `None` case. `match` makes you handle both. Leave one out
  and the compiler's exhaustiveness check from Lab 03 stops you.
- **`Some(customer) =>`** is a pattern that unwraps the value and names it.

Now run `cargo clippy`:

```text
warning: accessing first element with `customers.get(0)`
  --> src/main.rs:95:30
   |
95 |             "first" => match customers.get(0) {
   |                              ^^^^^^^^^^^^^^^^ help: try: `customers.first()`
```

`.first()` does the same thing and says it better. Clippy knows the standard library well.

**When to use which:** index with `[i]` only when the index is *guaranteed* valid, for example
because you just checked the length. Use `.get(i)` (or `.first()`, `.last()`) when the item might
not be there. That's the normal case for anything a user typed. In Lab 07, finding a customer
by ID returns `Option<&Customer>` for exactly this reason.

**Delete the temporary `first` arm** before moving on.

> 🟢 **COMMIT** (a natural checkpoint, since the CRM works):

```bash
git add .
git commit -m "Add in-memory customer list"
```

`matches_email` is still unused at this commit. That's expected, because Your Turn 2 uses it.

---

## Step 8 — Your first tests

Right now, "does `summary` work?" is answered by running the CRM, typing a customer and reading
the output. That's slow, it's manual, and you'll stop doing it. **Tests** ask the same questions
automatically, in milliseconds, every time.

Rust has testing built in, with no framework to install. Unit tests usually live **in the same
file** as the code they test, in a module at the bottom.

> 🟢 **FOLLOW ALONG**: add this at the very end of `main.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn ada() -> Customer {
        Customer::new(
            1,
            String::from("Ada Lovelace"),
            String::from("ada@example.com"),
            String::from("555-0100"),
        )
    }

    #[test]
    fn summary_shows_id_name_email_and_phone() {
        assert_eq!(
            ada().summary(),
            "#1 Ada Lovelace <ada@example.com> 555-0100"
        );
    }

    #[test]
    fn summary_leaves_out_a_missing_phone() {
        let customer = Customer::new(
            2,
            String::from("Alan Turing"),
            String::from("alan@example.com"),
            String::new(),
        );
        assert_eq!(customer.summary(), "#2 Alan Turing <alan@example.com>");
    }

    #[test]
    fn next_id_adds_one() {
        assert_eq!(next_id(1), 2);
        assert_eq!(next_id(41), 42);
    }
}
```

Piece by piece:

- **`mod tests { ... }`** declares a **module**, a named scope inside the file. (Modules are
  Lab 13's big topic. Here you just need one.)
- **`#[cfg(test)]`** means "only compile this when testing". `cargo build` and `cargo run`
  skip the whole module, so test code never ends up in your CRM binary.
- **`use super::*;`** imports everything from the parent module (the rest of `main.rs`) into
  the test module, so `Customer` and `next_id` are visible. `super` means "the module above me".
- **`fn ada()`** is a plain helper, not a test (no `#[test]`). Several tests need a sample
  customer, and the helper keeps them short and identical.
- **`#[test]`** marks a function as a test. It takes no arguments and returns nothing. It
  passes if it returns normally, and **fails if it panics**.
- **`assert_eq!(left, right)`** panics if the two values aren't equal, and prints both.
  Comparing a `String` with a `&str` works here for the same reason as `matches_email`.
- **Test names are sentences** about behaviour: `summary_leaves_out_a_missing_phone`. When a
  test fails, its name should tell you what broke without opening the file.

> 🟢 **FOLLOW ALONG**

```bash
cargo test
```

```text
   Compiling rust-crm v0.1.0 (/Users/you/code/rust-crm)
warning: method `matches_email` is never used
  ...
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.17s
     Running unittests src/main.rs (target/debug/deps/rust_crm-dbe73cd13dc85cfa)

running 3 tests
test tests::summary_leaves_out_a_missing_phone ... ok
test tests::summary_shows_id_name_email_and_phone ... ok
test tests::next_id_adds_one ... ok

test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

Tests run **in parallel**, so the order of the `test ... ok` lines changes from run to run.
That's also why tests must never depend on each other. (The `matches_email` warning will go
away in Your Turn 2.)

Notice what `cargo test` did: it compiled `main.rs` *with* the test module included, built a
special test executable, and ran every `#[test]` function. Your `main` never ran.

### Watch a test fail

A test you've never seen fail might not be testing anything.

> 🟡 **EXPERIMENT**: change the expected phone in `summary_shows_id_name_email_and_phone` to
> `555-0101` and run `cargo test`. Predict the output first.

```text
running 3 tests
test tests::summary_shows_id_name_email_and_phone ... FAILED
test tests::next_id_adds_one ... ok
test tests::summary_leaves_out_a_missing_phone ... ok

failures:

---- tests::summary_shows_id_name_email_and_phone stdout ----

thread 'tests::summary_shows_id_name_email_and_phone' (447255) panicked at src/main.rs:154:9:
assertion `left == right` failed
  left: "#1 Ada Lovelace <ada@example.com> 555-0100"
 right: "#1 Ada Lovelace <ada@example.com> 555-0101"
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace


failures:
    tests::summary_shows_id_name_email_and_phone

test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

error: test failed, to rerun pass `--bin rust-crm`
```

`left` is what the code produced and `right` is what the test expected. One failure doesn't stop
the others. Put `555-0100` back.

### Run only some tests

```bash
cargo test summary
```

```text
running 2 tests
test tests::summary_leaves_out_a_missing_phone ... ok
test tests::summary_shows_id_name_email_and_phone ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out; finished in 0.00s
```

The argument is a **filter**: only tests whose name contains `summary` run, and `next_id_adds_one`
is filtered out. That's another reason to give tests descriptive names.

### Testing that something panics

> 🟡 **EXPERIMENT**: Lab 02 showed that `next_id(u32::MAX)` panics in a debug build. You can
> write that down as a test. Add this inside `mod tests`:

```rust
    #[test]
    #[should_panic(expected = "attempt to add with overflow")]
    fn next_id_panics_after_the_last_id() {
        next_id(u32::MAX);
    }
```

`#[should_panic]` flips the rule: this test passes **only if** the function panics, and the
panic message must contain the `expected` text. Run `cargo test`. It passes. Now run:

```bash
cargo test --release
```

```text
running 4 tests
test tests::next_id_adds_one ... ok
test tests::next_id_panics_after_the_last_id - should panic ... FAILED
test tests::summary_leaves_out_a_missing_phone ... ok
test tests::summary_shows_id_name_email_and_phone ... ok

failures:

---- tests::next_id_panics_after_the_last_id stdout ----
note: test did not panic as expected at src/main.rs:179:8
```

In release, overflow wraps instead of panicking (Lab 01's table again), so the test fails. The
test was really testing the *build profile*, not your code. **Delete this experiment test.** A
good test pins down behaviour you *chose*. If you ever want `next_id` to handle the maximum
deliberately, you'd use `checked_add` and test *that*.

> 🟢 **COMMIT**

```bash
git add .
git commit -m "Add first unit tests"
```

---

## Step 9 — `HashMap` and `HashSet`: looking things up by key

A `Vec` is great for "all customers, in order". It's slow for one question the CRM will ask
constantly: **"do we already have this email?"** With a `Vec`, the only way to answer is to
look at every customer, one by one.

Rust's standard library has two key-based collections. Here's a tiny snippet to show the API
(just read it, it doesn't go in the CRM):

```rust
use std::collections::HashMap;

let mut id_by_email: HashMap<String, u32> = HashMap::new();
id_by_email.insert(String::from("ada@example.com"), 1);
id_by_email.insert(String::from("grace@example.com"), 2);

match id_by_email.get("ada@example.com") {
    Some(id) => println!("ada is customer #{id}"),
    None => println!("no such email"),
}
println!("knows alan? {}", id_by_email.contains_key("alan@example.com"));
println!("{} emails indexed", id_by_email.len());
```

```text
ada is customer #1
knows alan? false
2 emails indexed
```

- **`HashMap<K, V>`** maps keys to values, like a JS `Map`. Lookup by key takes roughly the
  same time no matter how many entries there are.
- **`.get(key)`** returns an `Option`, the same "maybe" as `Vec::get`, because the key might
  not be there.
- **`HashSet<T>`** is a `HashMap` with keys only: "is this in the set?" Like a JS `Set`.
- Both need `use std::collections::...;` at the top of the file. Unlike `Vec`, they aren't
  imported automatically.

**Speed isn't free.** A second collection is a second copy of the truth. If you keep emails in
a `HashSet` *and* customers in a `Vec`, every change to one must be mirrored in the other,
forever. Lab 08 adds `delete`, and Lab 07 adds updating an email. Keep that cost in mind when
you choose an approach in Your Turn 2. (You'll use `HashMap` for real when the CRM needs
counting and grouping, in Labs 17 and 18.)

---

## ▶️ Run It
```bash
cargo run
```

Add two customers, one with and one without a phone, then `list` and `quit`.

## ✅ Expected Result
```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> help
Commands:
  help      Show this list
  version   Show the CRM version
  add       Add a customer
  list      List all customers
  quit      Exit the CRM (also: exit)
crm> list
No customers yet.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Alan Turing
Email: alan@example.com
Phone:
Added customer #2
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Alan Turing <alan@example.com>
crm> quit
Goodbye! (5 commands this session)
```

And `cargo test` passes 3 tests (4 if you still have the `should_panic` experiment, which you
should delete).

## 🧠 Understand It

**Ownership flows one way through `add`.** `prompt` creates `String`s and gives them to you.
You give them to `Customer::new`. The customer gets pushed, so you give it to the vector. At
each step there's exactly **one** owner, and the data ends up owned by the `customers` vector,
which lives as long as the session. No copies were made (except `.to_string()` inside `prompt`,
which turns a temporary view into something you can keep). This "one owner, hand-offs are
explicit" model is the heart of Phase 2.

**`Option` replaces `null`.** `.get()` doesn't return "a customer or maybe null". It returns a
different type, `Option<&Customer>`, that you *must* unpack. The compiler won't let you forget
the empty case, and that eliminates the most common bug in programming without slowing you
down. Lab 12 covers `Option` and its sibling `Result` properly.

**Tests are code that runs your code.** A `#[test]` function is ordinary Rust: no special
syntax, no DSL. It fails by panicking, which is exactly what `assert_eq!` does when values
differ. `#[cfg(test)]` keeps it all out of the real binary. Because the test module is a
**child** of your main module, `use super::*;` gives it access to everything, including private
items like `Customer` and `next_id`. Unit tests can test internals. Lab 24's integration tests
can't, and that difference is intentional.

**What makes a good test here?** Each test names one behaviour, uses a tiny fixed input, and
compares against an exact expected value. `summary` and `next_id` are easy to test because
they're **pure**: same input, same output, no keyboard or screen involved. That's a design
lesson that comes back again and again (Lab 20 passes "now" into functions for exactly this
reason): *code that's easy to test is code that separates logic from input/output.* Notice that
you didn't write a test for `add`. It reads from stdin, and that's hard to test. Lab 07 starts
pulling that logic out into a store you *can* test.

**Collections, chosen by question.** `Vec` answers "all of them, in order". `HashMap` answers
"the one with this key". Choose the collection by the questions you'll ask, not by habit.

## 🧪 Experiment
> 🟡 **EXPERIMENT 1**: what does `cargo test` print if you write a `#[test]` function with no
> assertions at all, e.g. one that just builds `ada()`? Does it pass? What does that tell you
> about a test that "passes"?

> 🟡 **EXPERIMENT 2**: in `add`, swap the order: put `println!("Added customer #{next_customer_id}");`
> **before** `customers.push(customer);`. Does anything change? Now, instead, change that
> line to print `customer.id` and put it **after** the `push`. Run `cargo check` and read the
> error, but **don't fix it yet**. Write down your best guess at what it means, then undo the
> change. Lab 06 starts exactly here.

> 🟡 **EXPERIMENT 3**: run the CRM and add a customer with an empty name (just press Enter at
> `Name:`). What happens? Is that a bug? Which lab do you think will deal with it?

Answers are in `solutions.md`.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — The `count` command, test-first**
>
> Add a `count` command that tells you how many customers there are, in correct English.
>
> ```rust
> fn customer_count_label(count: usize) -> String
> ```
>
> - [ ] **Write the test first.** In `mod tests`, add a test for `customer_count_label`
>       covering `0`, `1` and `3`. Run `cargo test` and watch it fail to compile, because the
>       function doesn't exist yet. That's your to-do.
> - [ ] Then write `customer_count_label` so that `0` → `0 customers`, `1` → `1 customer`,
>       `3` → `3 customers` (any number other than 1 is plural)
> - [ ] Its body is a **single `if` expression**
> - [ ] Add a `count` arm to the `match` that prints the label for the current number of
>       customers, and a help row `("count", "Show how many customers there are")` below `list`
> - [ ] `cargo test` passes, and in the CRM: `count` on an empty CRM prints `0 customers`,
>       and after one `add` it prints `1 customer`
>
> Why is the parameter a `usize`? Look at what `customers.len()` returns.

> 🔵 **YOUR TURN 2 — Reject duplicate emails**
>
> Two customers with the same email address is a data problem every CRM has to prevent. Make
> `add` refuse a duplicate.
>
> - [ ] After the user enters the email, and **before** asking for the phone, check whether any
>       existing customer has exactly that email (case-sensitive is fine for now)
> - [ ] If one does, print exactly `A customer with email <email> already exists.` (for example
>       `A customer with email ada@example.com already exists.`), don't ask for the phone,
>       don't add anything, and don't use up an ID
> - [ ] A rejected `add` doesn't count towards the session's command count
> - [ ] Use `matches_email` from Lab 04, so its dead-code warning disappears
> - [ ] Decide between scanning the `Vec` and keeping a `HashSet<String>` of emails, and write
>       one sentence in a code comment justifying your choice (think about Step 9's warning and
>       Labs 07–08)
> - [ ] `cargo clippy` is clean, and `cargo build` has **zero** warnings
>
> ```text
> crm> add
> Name: Ada Again
> Email: ada@example.com
> A customer with email ada@example.com already exists.
> crm> count
> 1 customer
> ```

> 🔵 **YOUR TURN 3 — Test the methods you wrote in Lab 04**
>
> `has_phone` and `matches_email` have no tests. Write them.
>
> - [ ] At least one test that `has_phone` is `true` for a customer with a phone, and one that
>       it's `false` for an empty phone
> - [ ] A test for `matches_email` covering: the exact email (true), a different email (false),
>       and the same email in different **case** (false). That last one documents a decision,
>       so that when Lab 12 changes it, a test will tell you
> - [ ] Use the `ada()` helper where it fits, and give each test a name that's a sentence
> - [ ] Use `assert!` for booleans (look it up: it's `assert_eq!`'s sibling for a single `bool`)
> - [ ] `cargo test` shows **7** passing tests in total

## 💡 Hint
> 💡 **HINT**: Your Turn 1: `if` is an expression (Lab 03), so `if count == 1 { ... } else { ... }`
> can *be* the function body. Both branches must return a `String`. Your Turn 2: you need to
> leave the `add` arm early. Which loop keyword from Lab 03 ends *this* iteration and goes back
> to the prompt, skipping `count += 1`?

<details><summary>Hint 2 (more specific)</summary>

Your Turn 1: `format!("{count} customers")` builds the plural. For the singular,
`String::from("1 customer")` is enough. In the `match`: `customer_count_label(customers.len())`.

Your Turn 2: with a `Vec`, loop over `&customers` and remember in a `let mut duplicate = false;`
whether you found a match, then `break` out of the `for` once you have. `matches_email` takes a
`&str`, and `&email` (a `&String`) is accepted where a `&str` is expected. Then
`if duplicate { println!(...); continue; }`. Careful: the `break` inside the `for` leaves the
**`for`**, not the REPL `loop`. The innermost loop wins.

Your Turn 3: `assert!(expr)` fails if `expr` is `false`. `assert!(!expr)` fails if it's `true`.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why are `customers` and `next_customer_id` declared outside the loop, but `input` inside it?
2. What's the difference between `customers[0]` and `customers.get(0)` when the vector is
   empty? Which would you use for a customer ID the user typed, and why?
3. Why does `prompt` return `line.trim().to_string()` rather than `line.trim()`?
4. What does `#[cfg(test)]` do, and why does the test module need `use super::*;`?
5. A test passes when it ______ and fails when it ______.
6. Name one thing a `HashSet` of emails would make faster, and one new risk it introduces.

Then verify (this is the full end-of-lab check from now on):

```bash
cargo fmt --check && cargo clippy && cargo test
```

## Git Commit
```bash
git add .
git commit -m "Add count command, duplicate email check and more tests"
git tag lab-05
git push && git push --tags
```

Your history for this lab now has three commits: *Add in-memory customer list*, *Add first unit
tests*, and this one. Try `git log --oneline lab-04..lab-05`.

**Phase 1 is done.** You have a working, tested, interactive CRM in one file, written in about
the most straightforward Rust possible. Phase 2 goes back over every line of it and asks
*who owns this?* Some of what felt like magic, like `&customers`, `.to_string()`, and
`next_customer_id` instead of `customer.id`, is about to make complete sense.

**Next:** [Lab 06 — Ownership: Moves, Clones & Drops](../06-ownership/README.md).

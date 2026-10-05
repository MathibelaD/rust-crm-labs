# Lab 04 — Structs & Methods

> **Phase:** 1 — Rust Foundations · **Builds on:** Lab 03 · **Time:** ~2–3 hours
> **Your repo before this lab:** tag `lab-03` · **After:** tag `lab-04`

> This lab assumes you completed **Your Turn 1 and 2 in Lab 03** (build profile in `version`,
> table-driven `print_help`). If you didn't, copy them from
> [Lab 03's `solutions.md`](../03-control-flow-command-loop/solutions.md) first.

## 🎯 Goal
Replace the loose customer variables with a real `Customer` type that has its own constructor
and methods, so the CRM's main record has a name, a shape, and behaviour.

## 🧠 What You'll Learn
- Defining a `struct`, creating values with struct literals, reading fields
- Why the fields are `String` and not `&str` (a first taste of ownership)
- `#[derive(Debug)]`, `{:?}` and `{:#?}`
- `impl` blocks, **associated functions** (`Customer::new`) and `Self`
- **Methods** with `&self`, and `::` vs `.`
- Field init shorthand; `String::from` vs `.to_string()`
- Struct update syntax (and a sneak preview of why Phase 2 exists)

## 🔨 What We're Building
In Lab 02, a customer was four variables that merely *happened* to belong together, and
`format_customer(id, email, name, phone)` with two arguments swapped compiled without a peep.
Now the customer becomes one value:

```rust
#[derive(Debug)]
struct Customer {
    id: u32,
    name: String,
    email: String,
    phone: String,
}
```

with a constructor, `Customer::new(...)`, and a method, `customer.summary()`, that replaces
`format_customer`. The `demo` command builds customers this way. Every entity the CRM ever
gets (Company, Contact, Deal, Lead, Activity, Note, User) starts life exactly like this.

---

## Step 1 — Define the struct

> 🟢 **FOLLOW ALONG**: add this below `const APP_NAME` (above `main`):

```rust
struct Customer {
    id: u32,
    name: String,
    email: String,
    phone: String,
}
```

A **struct** is a named group of named fields, each with a type. It's like a TypeScript
`interface` or `type` for an object, with two big differences:

1. A struct is a real type that exists at run time with a fixed memory layout. It isn't erased
   after type checking.
2. There's no "optional by accident". Every value of `Customer` has **all four** fields,
   always. (Optional fields are explicit, using `Option`, which you'll meet in Lab 05 and use
   for `phone` in Lab 12.)

### Why `String` and not `&str`?

In Lab 02 the customer's details were `&str`: views of text literals baked into the program.
A `Customer` must **own** its data. When you type a customer in Lab 05, the text comes from
`read_line` into a temporary buffer, and the customer has to keep its name after that buffer
is gone. A struct that *borrowed* its name (`name: &str`) would need the compiler's proof that
the borrowed text outlives the customer. That's a *lifetime*, and it's Lab 10's topic.

The rule of thumb for now, explained properly in Lab 06: **structs own their data, so text
fields are `String`.**

---

## Step 2 — Create a value and read its fields

> 🟢 **FOLLOW ALONG**: in `run_demo`, replace Ada's **five** `let` lines and her
> `format_customer`/`println!` lines with a struct literal. Grace's `next_id` call needs Ada's ID,
> which is now a field:

```rust
fn run_demo() {
    let ada = Customer {
        id: 1,
        name: String::from("Ada Lovelace"),
        email: String::from("ada@example.com"),
        phone: String::from("555-0100"),
    };
    println!("Customer #{} is {}", ada.id, ada.name);
    println!("{ada:?}");

    let id = next_id(ada.id);
    // ... Grace's lines and the id_stats lines stay as they are for now
}
```

- A **struct literal** names the type and gives every field a value, in any order.
- **`String::from("Ada Lovelace")`** creates an owned `String` from a `&str` literal. The text
  is copied into a new heap buffer that `ada` owns.
- **`ada.id`** reads a field with a dot, like in JS.
- **`{ada:?}`** asks for *debug* formatting of the whole struct.

> 🟡 **EXPERIMENT**: predict, then `cargo check`.

```text
error[E0277]: `Customer` doesn't implement `Debug`
  --> src/main.rs:83:15
   |
83 |     println!("{ada:?}");
   |               ^^^^^^^ `Customer` cannot be formatted using `{:?}` because it doesn't implement `Debug`
   |
   = help: the trait `Debug` is not implemented for `Customer`
help: consider annotating `Customer` with `#[derive(Debug)]`
   |
 5 + #[derive(Debug)]
 6 | struct Customer {
   |
```

(Your line numbers may differ slightly. That depends on how you wrote Labs 02–03.)

**Read the error.** Rust doesn't know how to print an arbitrary struct, and it won't guess. In
JS, `console.log(obj)` dumps any object. In Rust, the ability to be debug-printed is a
**trait** called `Debug`, a capability a type either has or doesn't. Traits are Lab 15. For now,
read "the trait `Debug` is not implemented" as "this type hasn't been given the ability to
`{:?}`".

---

## Step 3 — `#[derive(Debug)]`

> 🟢 **FOLLOW ALONG**: do what the compiler suggests, directly above `struct Customer`:

```rust
#[derive(Debug)]
struct Customer {
```

`#[derive(Debug)]` is an **attribute** that asks the compiler to *write the `Debug`
implementation for you*, generated from the fields. Run `demo`:

```text
crm> demo
Customer #1 is Ada Lovelace
Customer { id: 1, name: "Ada Lovelace", email: "ada@example.com", phone: "555-0100" }
#2 Grace Hopper <grace@example.com> 555-0199
Next id: 3 (4294967293 ids left)
```

Also look at what the compiler says during the build:

```text
warning: fields `email` and `phone` are never read
  --> src/main.rs:9:5
   |
 6 | struct Customer {
   |        -------- fields in this struct
...
 9 |     email: String,
   |     ^^^^^
10 |     phone: String,
   |     ^^^^^
   |
   = note: `Customer` has a derived impl for the trait `Debug`, but this is intentionally ignored during dead code analysis
```

The compiler tracks which fields your code actually reads. Debug printing doesn't count, since
it's for humans and not program logic. This warning goes away in Step 5, when `summary` uses
every field.

### `{:?}` vs `{:#?}`

`{:?}` prints on one line. `{:#?}` ("alternate" debug) pretty-prints across multiple lines, which
is much easier to read for structs with more than a few fields:

```text
Customer {
    id: 2,
    name: "Grace Hopper",
    email: "grace@example.com",
    phone: "555-0199",
}
```

Debug output is for **developers** (logs, tests, `dbg!`), not for users. User-facing output
gets its own method (Step 5), and in Lab 15, the `Display` trait.

---

## Step 4 — An associated function: `Customer::new`

Writing every field name every time is noisy, and in later labs construction will grow rules
(validation in Lab 12). Give `Customer` a **constructor**.

> 🟢 **FOLLOW ALONG**: add an `impl` block below the struct:

```rust
impl Customer {
    fn new(id: u32, name: String, email: String, phone: String) -> Self {
        Self {
            id,
            name,
            email,
            phone,
        }
    }
}
```

- **`impl Customer { ... }`** holds functions that belong to `Customer`. Unlike a JS/TS class,
  data (`struct`) and behaviour (`impl`) are declared separately. You can even have several
  `impl` blocks for one type.
- **`fn new(...)`** has no `self` parameter, so it's an **associated function**. You call it on
  the *type*: `Customer::new(...)`. It's like a `static` method in TS. `new` is only a naming
  convention, not a keyword. Rust has no built-in constructors.
- **`Self`** (capital S) is an alias for "the type this `impl` is for", here `Customer`.
  `-> Self` and `Self { ... }` mean exactly `-> Customer` and `Customer { ... }`. Use `Self`:
  if the type is renamed (it will be, in Lab 14), the `impl` doesn't need to change.
- **Field init shorthand**: `Self { id, name, email, phone }` means `id: id, name: name, ...`.
  It works when a variable has the same name as the field, just like `{ id, name }` in JS.

> 🟡 **EXPERIMENT**: replace Ada's struct literal with a call that passes text literals
> directly, and predict what happens:

```rust
    let ada = Customer::new(1, "Ada Lovelace", "ada@example.com", "555-0100");
```

```text
error[E0308]: arguments to this function are incorrect
  --> src/main.rs:88:15
   |
88 |     let ada = Customer::new(1, "Ada Lovelace", "ada@example.com", "555-0100");
   |               ^^^^^^^^^^^^^    --------------  -----------------  ---------- expected `String`, found `&str`
   |                                |               |
   |                                |               expected `String`, found `&str`
   |                                expected `String`, found `&str`
   |
note: associated function defined here
  --> src/main.rs:14:8
   |
14 |     fn new(id: u32, name: String, email: String, phone: String) -> Self {
   |        ^^^          ------------  -------------  -------------
help: try using a conversion method
   |
88 |     let ada = Customer::new(1, "Ada Lovelace".to_string(), "ada@example.com", "555-0100");
   |                                              ++++++++++++
```

(The `help` repeats for each argument.) **Read the error.** `new` asks for `String`, owned
text that the new customer will keep. A literal is a `&str`, a view of text that lives in
your program's binary. Rust never converts between them silently, because creating a `String`
**allocates memory**, and Rust wants every allocation to be visible in the code.

Two ways to make an owned `String` from a `&str`:

| | Reads as | Notes |
|---|---|---|
| `String::from("Ada")` | "make a String from this" | explicit about the target type |
| `"Ada".to_string()` | "turn this into a String" | works on anything printable (numbers too: `42.to_string()`) |

For text they do the same thing. Pick whichever reads better. Why both exist, and what they
cost, is Lab 06 material.

> 🟢 **FOLLOW ALONG**: build Ada with `new`:

```rust
    let ada = Customer::new(
        1,
        String::from("Ada Lovelace"),
        String::from("ada@example.com"),
        String::from("555-0100"),
    );
```

The demo prints the same as before. The constructor is now the **one** place that knows how
to build a `Customer`. That's going to matter: in Lab 12 it's where validation goes.

---

## Step 5 — A method: `summary(&self)`

`format_customer` took four separate arguments describing one customer. Now that the customer
*is* one value, formatting belongs **to** it.

> 🟢 **FOLLOW ALONG**: add a method inside `impl Customer`, below `new`:

```rust
    fn summary(&self) -> String {
        format!("#{} {} <{}> {}", self.id, self.name, self.email, self.phone)
    }
```

- **`&self`** as the first parameter makes this a **method**: you call it on a *value* with a
  dot, `ada.summary()`. `self` is the value it was called on (like `this` in JS, but explicit).
- **The `&`** means `summary` *borrows* the customer to read it. It doesn't take ownership and
  it can't modify it. After `ada.summary()`, `ada` is still yours. (The full story of `&self`
  vs `&mut self` vs `self` is Lab 07. Each says something different about what the method
  does to the value.)
- The format string uses `{}` placeholders with arguments, not inline `{self.id}`. Try the
  inline version: the compiler explains why it isn't allowed. (Answer below in Understand It.)

Now finish the switch-over in `run_demo`:

1. Build Grace with `Customer::new`, using `.to_string()` this time so you've used both forms,
   with her ID from `next_id(ada.id)`.
2. Print both customers with `.summary()`.
3. Debug-print `ada` with `{:?}` and `grace` with `{:#?}`.
4. Feed `id_stats` with `grace.id`.
5. **Delete `format_customer`**. Nothing calls it any more, and `summary` replaces it.

> 🟢 **FOLLOW ALONG**: your `run_demo` should now be:

```rust
fn run_demo() {
    let ada = Customer::new(
        1,
        String::from("Ada Lovelace"),
        String::from("ada@example.com"),
        String::from("555-0100"),
    );
    println!("{}", ada.summary());

    let grace = Customer::new(
        next_id(ada.id),
        "Grace Hopper".to_string(),
        "grace@example.com".to_string(),
        "555-0199".to_string(),
    );
    println!("{}", grace.summary());

    println!("{ada:?}");
    println!("{grace:#?}");

    let (next, remaining) = id_stats(grace.id);
    println!("Next id: {next} ({remaining} ids left)");
}
```

### `::` vs `.`

| You write | Because | Example |
|---|---|---|
| `Type::function(...)` | it's an associated function (no `self`): called on the **type** | `Customer::new(...)`, `String::from(...)`, `String::new()` |
| `value.method(...)` | it's a method (`self`, `&self` or `&mut self`): called on a **value** | `ada.summary()`, `input.trim()`, `name.to_string()` |

> 🟡 **EXPERIMENT**: remove `&self` from `summary` (so it's `fn summary() -> String`) and run
> `cargo check`. Predict how many errors you'll get.

```text
error[E0424]: cannot find value `self` in this scope
  --> src/main.rs:24:35
   |
23 |     fn summary() -> String {
   |        ------- this function doesn't have a `self` parameter
24 |         format!("#{} {} <{}> {}", self.id, self.name, self.email, self.phone)
   |                                   ^^^^ `self` value is a keyword only available in methods with a `self` parameter
   |
   = note: a module named `self` exists in another namespace
help: add a `self` receiver parameter to make the associated `fn` a method
   |
23 |     fn summary(&self) -> String {
   |                +++++
```

…four times (once per `self.`), and then, at the call sites:

```text
error[E0599]: no method named `summary` found for struct `Customer` in the current scope
  --> src/main.rs:98:24
   |
 6 | struct Customer {
   | --------------- method `summary` not found for this struct
...
98 |     println!("{}", ada.summary());
   |                        ^^^^^^^ this is an associated function, not a method
```

**Read the errors.** Without a `self` parameter, `summary` is an associated function. Inside
it there's no "current customer", and callers can't use the dot syntax. Unlike JS, there's no
implicit `this`. The receiver is a parameter like any other, and a method has one only if you
declare it. Put `&self` back.

---

## ▶️ Run It
```bash
cargo run
```

Then type `demo` and `quit`.

## ✅ Expected Result
```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> demo
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
Customer { id: 1, name: "Ada Lovelace", email: "ada@example.com", phone: "555-0100" }
Customer {
    id: 2,
    name: "Grace Hopper",
    email: "grace@example.com",
    phone: "555-0199",
}
Next id: 3 (4294967293 ids left)
crm> quit
Goodbye! (1 commands this session)
```

The summary lines are character-for-character what `format_customer` printed in Lab 02. The
refactor changed the structure, not the behaviour. And `cargo build` has **no** warnings:
`summary` reads every field.

## 🧠 Understand It

**Data and behaviour, declared separately.** `struct` says what a customer *is*. `impl` says
what it can *do*. There's no inheritance: types share behaviour through traits (Lab 15)
instead of class hierarchies. That turns out to be one of Rust's best design decisions, but
you'll appreciate it more after Lab 15.

**Receivers are explicit.** `fn new(...)` (no receiver) can't touch an existing customer.
`fn summary(&self)` can read one but not change it. The *signature* tells you what a function
can do to a customer before you read its body. Lab 07 adds `&mut self` (may change it), and
Phase 2 adds `self` (consumes it), and that's when this becomes a superpower.

**Why the inline `{self.id}` isn't allowed.** Inline format arguments only accept plain
identifiers (`{ada}`, `{APP_NAME}`), not expressions like field accesses. The compiler says so:
*"invalid format string: field access isn't supported"* and suggests positional arguments.
That's a deliberate limit that keeps format strings simple.

**Owned fields.** `Customer` owns four pieces of data. The `u32` is stored inline, and each
`String` points to its own heap buffer. When a `Customer` goes away, everything it owns goes
with it, with no garbage collector involved. *When* exactly that happens, and what "goes away"
means, is the opening question of Lab 06.

**Constructors are just functions.** `Customer::new` is an ordinary associated function that
returns `Self`. You can have as many as you like with any names (e.g. `Customer::guest()`).
That flexibility is why Rust doesn't need a `constructor` keyword.

## 🧪 Experiment
> 🟡 **EXPERIMENT 1 — struct update syntax.** Add this to the end of `run_demo` and predict
> whether it compiles:

```rust
    let ada_at_work = Customer {
        email: String::from("ada@analytical.example"),
        ..ada
    };
    println!("{}", ada_at_work.summary());
    println!("{}", ada.summary());
```

`..ada` means "take every field I didn't list from `ada`", like `{ ...ada, email: "..." }` in
JS. Run `cargo check`:

```text
error[E0382]: borrow of partially moved value: `ada`
   --> src/main.rs:119:20
    |
114 |       let ada_at_work = Customer {
    |  _______________________-
115 | |         email: String::from("ada@analytical.example"),
116 | |         ..ada
117 | |     };
    | |_____- value partially moved here
118 |       println!("{}", ada_at_work.summary());
119 |       println!("{}", ada.summary());
    |                      ^^^ value borrowed here after partial move
    |
    = note: partial move occurs because `ada.phone` has type `String`, which does not implement the `Copy` trait
```

**Read the error, and keep the question open.** JS's spread *shares* references, so both
objects point at the same strings. Rust doesn't do that: `name` and `phone` were **moved** out
of `ada` into `ada_at_work`. `ada` no longer owns them, so `ada.summary()` can't read them. What
"moved" means, and why Rust insists on it, is **exactly** what Lab 06 is about. Remember this
error, because you'll be able to explain every word of it a week from now.

Now change the last line to `println!("{}", ada.id);`. It compiles! Why can you still use
`ada.id` but not `ada.name`? (Hint: look at the word `Copy` in the note.) Remove the experiment
lines afterwards.

> 🟡 **EXPERIMENT 2**: in `new`, remove `phone` from `Self { id, name, email, phone }`. What does
> the compiler say? Does that match what you read in Step 1 about "no optional by accident"?

> 🟡 **EXPERIMENT 3**: call `Customer::summary(&ada)` instead of `ada.summary()`. Does it compile?
> What does that tell you about what the dot syntax really is?

Answers are in `solutions.md`.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — `has_phone`**
>
> Not every customer gives a phone number. Add a method that answers "do we have a phone
> number for this customer?"
>
> ```rust
> fn has_phone(&self) -> bool
> ```
>
> - [ ] Returns `true` when the phone is non-empty, and `false` when it's an empty string
> - [ ] Its body is a **single expression**
> - [ ] In `run_demo`, add a third customer, **Alan Turing** (`alan@example.com`), with **no
>       phone** (an empty `String`, created without any text literal), whose ID comes from
>       `next_id(grace.id)`
> - [ ] Print `has_phone` for Ada and for Alan, using the customers' `name` fields in the message
> - [ ] Make `id_stats` use **Alan's** ID now, since he's the newest customer
>
> The end of the `demo` output must be:
>
> ```text
> Ada Lovelace has a phone: true
> Alan Turing has a phone: false
> Next id: 4 (4294967292 ids left)
> ```

> 🔵 **YOUR TURN 2 — `matches_email`**
>
> In Lab 05 you'll refuse to add a customer whose email is already in the CRM. That needs a way
> to ask a customer "is this your email?". Add:
>
> ```rust
> fn matches_email(&self, email: &str) -> bool
> ```
>
> - [ ] Returns `true` only if the customer's email is **exactly** equal to `email` (case
>       matters, for now)
> - [ ] It's a method: it takes `&self` **and** a second parameter
> - [ ] Its body is a single expression, with no `if`
> - [ ] In `run_demo`, ask Ada whether `ada@example.com` and `grace@example.com` are her
>       email. The `demo` output must contain these lines, after the two `has a phone` lines and
>       before the `Next id` line:
>
> ```text
> ada@example.com is Ada's email: true
> grace@example.com is Ada's email: false
> ```
>
> - [ ] `cargo clippy` is clean (watch out: Clippy has opinions about how you compare a
>       `String` with a `&str`)

## 💡 Hint
> 💡 **HINT**: Your Turn 1: `String` has a method that tells you whether it contains any
> characters. Search for it in `rustup doc --std` (look at the `String` page and the `str` page).
> `!` negates a `bool`. Your Turn 2: `==` works between a `String` and a `&str`.

<details><summary>Hint 2 (more specific)</summary>

Your Turn 1: `String::new()` creates an empty `String`. `self.phone.is_empty()` is a `bool`.
What `has_phone` returns is its opposite.

Your Turn 2: inside the method, `self.email` is the customer's `String` and `email` is the
`&str` parameter. Comparisons produce a `bool`, so the comparison itself can be the method's
whole body. You don't need `if ... { true } else { false }`, and Clippy would flag that
(`needless_bool`).

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why are `Customer`'s text fields `String` rather than `&str`?
2. What's the difference between `Customer::new(...)` and `ada.summary()`, in terms of how
   they're declared and how they're called?
3. What does `Self` mean inside `impl Customer`, and why prefer it over writing `Customer`?
4. What does `#[derive(Debug)]` do? Why doesn't Rust just let you print any struct?
5. Why does `Customer::new(1, "Ada", ...)` fail to compile, and what are two ways to fix it?
6. In Experiment 1, why could you still read `ada.id` after `..ada`, but not `ada.name`?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo run
```

## Git Commit
```bash
git add .
git commit -m "Add Customer struct"
git tag lab-04
git push && git push --tags
```

Now try the payoff of tags for the first time:

```bash
git diff lab-03 lab-04
```

That's this whole lab in one view: `format_customer` gone, `Customer` arrived.

**Next:** [Lab 05 — Collections & Your First Tests](../05-collections-and-tests/README.md): you
type customers in, the CRM keeps them in a `Vec`, and you write your first tests.

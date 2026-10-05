# Lab 02 — Variables, Types & Functions

> **Phase:** 1 — Rust Foundations · **Builds on:** Lab 01 · **Time:** ~2–3 hours
> **Your repo before this lab:** tag `lab-01` · **After:** tag `lab-02`

## 🎯 Goal
Give the CRM its first customer: details held in variables, formatted into one line by a
function you write, plus a function that works out the next customer ID.

## 🧠 What You'll Learn
- `let`, immutability by default, and `mut`
- **Shadowing**: reusing a name for a new value (and why it's not the same as `mut`)
- Scalar types: integers (`u32` vs `i64`, and why IDs are unsigned), `bool`, `char`, floats
- `const`
- Functions: parameters, return types, and calling them
- **Expressions vs statements**: why a missing semicolon *returns* a value
- Integer overflow: a compile error, a runtime panic, or silent wrap-around, depending on how you build
- Tuples: grouping values and returning more than one

## 🔨 What We're Building
A hard-coded customer. Every CRM starts with a record, so here it is:

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
Next id: 2
```

It's hard-coded and it lives in loose variables, and that's deliberate. In Lab 03 the program
becomes interactive, in Lab 04 these variables become a `Customer` struct, and in Lab 05 you'll
type customers in yourself. The `format_customer` line format you design here is the format
`list` uses for the rest of Phase 1 and 2.

---

## Step 1 — `let`, and immutability by default

> 🟢 **FOLLOW ALONG**: replace `src/main.rs` with:

```rust
fn main() {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));

    let id: u32 = 1;
    let name = "Ada Lovelace";
    let email = "ada@example.com";
    let phone = "555-0100";

    println!("Customer #{id}: {name}, {email}, {phone}");
}
```

```bash
cargo run
```

```text
Rust CRM v0.1.0
Customer #1: Ada Lovelace, ada@example.com, 555-0100
```

Three things are new:

- **`let` introduces a variable.** `let id: u32 = 1;` says "a variable `id`, of type `u32`,
  with value `1`". The `: u32` is a *type annotation*.
- **Most annotations are optional.** `name`, `email` and `phone` have none. The compiler
  *infers* their type from the value, the same way TypeScript infers `const name = "Ada"`. Rust's
  inference is stronger than TypeScript's, though, because it can also infer from how a
  variable is used *later*.
- **`{id}` inside the format string** is an *inline argument*: it prints the variable `id`.
  It's equivalent to `println!("Customer #{}: ...", id, ...)`. Use whichever reads better.

### Now change the phone number

Customers change their phone numbers. Let's model that.

> 🟡 **EXPERIMENT**: predict first, then run `cargo check`. Add these two lines at the end of `main`:

```rust
    phone = "555-0199";
    println!("Updated phone: {phone}");
```

```bash
cargo check
```

```text
error[E0384]: cannot assign twice to immutable variable `phone`
  --> src/main.rs:11:5
   |
 7 |     let phone = "555-0100";
   |         ----- first assignment to `phone`
...
11 |     phone = "555-0199";
   |     ^^^^^^^^^^^^^^^^^^ cannot assign twice to immutable variable
   |
help: consider making this binding mutable
   |
 7 |     let mut phone = "555-0100";
   |         +++

For more information about this error, try `rustc --explain E0384`.
error: could not compile `rust-crm` (bin "rust-crm") due to 1 previous error
```

**Read the error.** The compiler points at two places: where `phone` got its value (line 7)
and where you tried to give it another one (line 11). In Rust, **variables are immutable
unless you say otherwise.** This isn't JavaScript's `const`, which stops reassignment but
still lets you mutate the object inside. Rust's immutability is *deep*: with an immutable
binding you can't change the value at all, not even "a field of it". That becomes very
important when we get to borrowing in Phase 2.

Try `rustc --explain E0384` in the terminal. Every error code has a longer explanation with
examples.

The `help:` suggests `let mut phone`. Do that and run again:

```text
Rust CRM v0.1.0
Customer #1: Ada Lovelace, ada@example.com, 555-0100
Updated phone: 555-0199
```

`mut` works, but it's a promise to the reader: *"watch out, this changes later."* Use it when a
value really does change over time, like a counter. Rust makes that the exception you opt into,
not the default.

**Remove both experiment lines and put `let phone` back without `mut`.** If you leave an unused
`mut` behind, the compiler warns you (`variable does not need to be mutable`).

---

## Step 2 — Shadowing

Data from users is messy. Suppose the name arrives with stray spaces, as typed input will in
Lab 05.

> 🟢 **FOLLOW ALONG**: change the `name` line to these two lines:

```rust
    let name = "  Ada Lovelace  ";
    let name = name.trim();
```

The second `let` creates a **new variable** that happens to have the same name. It *shadows*
the first one: from this line on, `name` means the trimmed value, and the untrimmed one can no
longer be reached by name.

`.trim()` is a *method* on text: it gives you the text without leading or trailing whitespace.

> 🟡 **EXPERIMENT**: print the value on both sides of the shadowing with `{name:?}`. The `:?` is
> *debug formatting*, which shows quotes and makes whitespace visible:

```rust
    let name = "  Ada Lovelace  ";
    println!("{name:?}");
    let name = name.trim();
    println!("{name:?}");
```

```text
"  Ada Lovelace  "
"Ada Lovelace"
```

Then remove the two `println!` lines again.

### Shadowing vs `mut`

| | `let mut x = ...; x = ...;` | `let x = ...; let x = ...;` |
|---|---|---|
| How many variables? | one, changed in place | two, and the second hides the first |
| Can the type change? | **no** | **yes** |
| Is `x` mutable afterwards? | yes | no (unless the new `let` says `mut`) |
| Typical use | a value that evolves: counters, accumulators | a *transformation pipeline*: raw → trimmed → parsed |

That "can the type change" row is why shadowing exists. A common pattern you'll write in later
labs:

```rust
let id = "42";              // text, as typed by the user
let id: u32 = id.parse()... // the same idea, now a number (Lab 07)
```

You don't need `id_str` and `id_num`, because the old form is simply no longer relevant.

---

## Step 3 — Scalar types, and why IDs are unsigned

Rust has four kinds of *scalar* (single-value) types.

**Integers**: the size and the sign are part of the name:

| Type | Range | In this CRM |
|---|---|---|
| `u8` | 0 to 255 | — |
| `u32` | 0 to 4,294,967,295 | customer IDs (Phase 1–3) |
| `u64` | 0 to ~1.8 × 10¹⁹ | entity IDs from Lab 14 |
| `i32` | −2,147,483,648 to 2,147,483,647 | the default when nothing else is known |
| `i64` | ±9.2 × 10¹⁸ | money in cents (Lab 18), database IDs (Lab 30, because Postgres has no unsigned types) |
| `usize` | pointer-sized (64-bit on your Mac) | lengths and indexes of collections (Lab 05) |

`u` = unsigned (never negative), `i` = signed. JavaScript has one `number` type (a 64-bit
float). Rust makes you choose, and the choice documents intent.

**Why is the ID a `u32`?** Because a customer ID is never negative. Encoding that in the type
means the compiler rejects nonsense for you.

> 🟡 **EXPERIMENT**: change the ID to `let id: u32 = -1;` and run `cargo check`. Predict the
> error before you look.

```text
error[E0600]: cannot apply unary operator `-` to type `u32`
 --> src/main.rs:4:19
  |
4 |     let id: u32 = -1;
  |                   ^^ cannot apply unary operator `-`
  |
  = note: unsigned values cannot be negated
help: you may have meant the maximum value of `u32`
  |
4 -     let id: u32 = -1;
4 +     let id: u32 = u32::MAX;
  |

For more information about this error, try `rustc --explain E0600`.
error: could not compile `rust-crm` (bin "rust-crm") due to 1 previous error
```

A bug that would have been a bad row in a JS app is a compile error here. Put `1` back.

**`bool`**: `true` / `false`. No "truthy" values: `if 1 { }` is a compile error, because
conditions must be actual `bool`s. You'll write your first `-> bool` function in Lab 04.

**`char`**: a single Unicode character in single quotes: `'A'`, `'Å'`, `'🦀'`. A `char` is always
**4 bytes**, because it can hold any Unicode scalar value. Text (`"..."`) is *not* an array of
`char`s; it's UTF-8 bytes. That distinction matters a lot in Lab 09.

**Floats**: `f64` (and `f32`). You won't use them in the CRM. Money must never be a float
(you'll see `0.1 + 0.2` go wrong in Lab 18).

---

## Step 4 — Constants

The banner says "Rust CRM" in a string literal. The app name will be needed in more than one
place (the `version` command arrives in Lab 03), so give it a name.

> 🟢 **FOLLOW ALONG**: at the **top** of `main.rs`, above `fn main`:

```rust
const APP_NAME: &str = "Rust CRM";
```

and change the banner line to:

```rust
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
```

How a `const` differs from `let`:

- It **must** have a type annotation. Constants are part of your program's interface, so Rust
  doesn't infer them.
- It's a compile-time value, so it can be declared outside any function and used anywhere in
  the file.
- Convention is `SCREAMING_SNAKE_CASE`. (Variables and functions use `snake_case`. The compiler
  warns if you don't, try `let customerName = ...;`.)

**`&str`** is the type of a piece of text you're *borrowing* rather than owning. Every string
literal like `"Rust CRM"` is a `&str`. That's all you need for now. What "borrowed" really means
is the subject of Labs 06–09, and it's the most important idea in the course.

---

## Step 5 — Your first function: `format_customer`

Printing a customer is something the CRM will do in many places (a list, a search result,
a confirmation after an update), so it belongs in a function.

> 🟢 **FOLLOW ALONG**: add this **below** `main`. Rust doesn't care about the order of
> functions in a file.

```rust
fn format_customer(id: u32, name: &str, email: &str, phone: &str) -> String {
    format!("#{id} {name} <{email}> {phone}")
}
```

And in `main`, replace the `println!("Customer #{id}: ...")` line with:

```rust
    let line = format_customer(id, name, email, phone);
    println!("{line}");
```

Read the signature left to right:

```text
fn format_customer( id: u32, name: &str, email: &str, phone: &str ) -> String
   ^ name           ^ every parameter MUST have a type                 ^ return type
```

- **Parameter types are mandatory.** Inference stops at function boundaries on purpose: a
  function's signature is a contract, readable without looking at the body (or the callers).
- **`-> String`** is the return type. `String` is text that the function *owns* and hands to
  the caller. You can't return a borrowed `&str` here because the formatted text is brand new
  and *someone* has to own it. (That sentence will make complete sense by Lab 06. For now, the
  pattern is: **take `&str` in, give `String` out**.)
- **`format!`** is `println!`'s sibling: same format syntax, but instead of printing, it
  *returns* the formatted `String`.
- **No `return` and no semicolon** on the `format!` line. Hold that thought until Step 6.

Run it:

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
```

---

## Step 6 — Expressions vs statements: `next_id`

New customers need IDs. The rule is simple, next = current + 1, but it lives in one place, so
when the rule changes (it will, in Lab 07 a store hands out IDs) there's only one place to
change.

> 🟡 **EXPERIMENT**: type this exactly as written, **including the semicolon**. Predict: does it
> compile?

```rust
fn next_id(current: u32) -> u32 {
    current + 1;
}
```

And at the end of `main`:

```rust
    println!("Next id: {}", next_id(id));
```

```bash
cargo check
```

```text
error[E0308]: mismatched types
  --> src/main.rs:22:29
   |
22 | fn next_id(current: u32) -> u32 {
   |    -------                  ^^^ expected `u32`, found `()`
   |    |
   |    implicitly returns `()` as its body has no tail or `return` expression
23 |     current + 1;
   |                - help: remove this semicolon to return this value

For more information about this error, try `rustc --explain E0308`.
error: could not compile `rust-crm` (bin "rust-crm") due to 1 previous error
```

**Read the error carefully. It explains Rust's whole philosophy of blocks.**

- *"expected `u32`, found `()`"*: the function promised a `u32` but produces `()`. `()` is
  pronounced "unit". It's the empty tuple, the value that means "nothing interesting". It's
  roughly `void`/`undefined`, except it's a real value with a real type.
- *"implicitly returns `()` as its body has no tail … expression"*: a block `{ ... }`
  evaluates to its **last expression**, the *tail*. `current + 1;` isn't an expression any
  more. The `;` turned it into a **statement**, which computes the value and throws it away. With
  no tail, the block's value is `()`.
- *"remove this semicolon to return this value"*. Exactly.

> 🟢 **FOLLOW ALONG**: fix it:

```rust
fn next_id(current: u32) -> u32 {
    current + 1
}
```

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
Next id: 2
```

### The mental model

| | Produces a value? | Examples |
|---|---|---|
| **Expression** | yes | `1`, `current + 1`, `format!(...)`, a function call, a whole `{ ... }` block, `if`, `match` |
| **Statement** | no | `let x = ...;`, anything followed by `;` |

The semicolon is an operator: *"evaluate this, discard the result"*. That's why
`format_customer` has no `;` on its last line, since that line is the return value. `return` exists,
but idiomatic Rust uses it only for **early** exits (Clippy flags a `return` on the last line,
as you may have seen in Lab 01).

In JS/TS, `if` is a statement and you need a ternary to get a value. In Rust, `if`, `match` and
plain blocks are all expressions:

```rust
let label = {
    let n = 2;
    n * 10          // ← tail expression: the block's value is 20
};
```

You'll lean on this constantly from Lab 03 on: `let x = if ... { } else { };`, `let y = match ... { };`.

---

## Step 7 — Integer overflow: three different outcomes

A `u32` tops out at 4,294,967,295 (`u32::MAX`). What's `next_id(u32::MAX)`?

> 🟡 **EXPERIMENT**: predict, then add this line at the end of `main` and use `cargo run`:

```rust
    println!("After the last id: {}", next_id(u32::MAX));
```

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
Next id: 2

thread 'main' (389312) panicked at src/main.rs:24:5:
attempt to add with overflow
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

(The number after `'main'` is a thread ID and will differ.) In a **debug** build, Rust checks
every arithmetic operation and **panics** on overflow. A *panic* is a controlled crash: the
program stops with a message saying where and why. Now build the release way:

```bash
cargo run --release
```

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
Next id: 2
After the last id: 0
```

In **release** builds the check is removed for speed and the value **wraps around** to `0`.
Two customers with ID 0 would be a nasty, silent bug. This is the "Integer overflow" row of the
debug-vs-release table from Lab 01.

And a third outcome: when the overflow is visible **at compile time**, the compiler refuses.

> 🟡 **EXPERIMENT**: change the experiment line to `println!("{}", u32::MAX + 1);`. Run
> `cargo check`, then `cargo build`.

`cargo check` passes, but `cargo build` says:

```text
error: this arithmetic operation will overflow
  --> src/main.rs:16:20
   |
16 |     println!("{}", u32::MAX + 1);
   |                    ^^^^^^^^^^^^ attempt to compute `u32::MAX + 1_u32`, which would overflow
   |
   = note: `#[deny(arithmetic_overflow)]` on by default

error: could not compile `rust-crm` (bin "rust-crm") due to 1 previous error
```

That's a rare example of an error `cargo check` doesn't catch: this lint runs during code
generation, which `check` skips.

**Remove the experiment line.** We'll keep `next_id` as it is. Four billion customers is a
problem we'd love to have. But you now know the options for when it matters:

- `current.checked_add(1)` returns "maybe a number": `Some(value)`, or `None` on overflow. That
  "maybe" type is `Option`, gently introduced in Lab 05 and fully covered in Lab 12.
- `current.wrapping_add(1)` / `current.saturating_add(1)` when wrapping or capping is
  genuinely what you want.

---

## Step 8 — Tuples

A **tuple** groups a fixed number of values, possibly of different types, into one value:

```rust
let customer = (1, "Ada Lovelace");     // type: (i32, &str)
println!("{}", customer.0);             // 1   — access by position
let (id, name) = customer;              // destructuring: two new variables
```

Tuples are how a Rust function returns **more than one value** without defining a type for it:
`fn f() -> (u32, u32)` returns two numbers, and the caller destructures them with
`let (a, b) = f();`. You'll write one in Your Turn 2.

You've already met one tuple: `()`, the empty tuple, the "found `()`" from Step 6.

When the pieces have *meanings* (a name, an email…) rather than positions, a tuple gets
unreadable fast (`customer.2` — was that the email or the phone?). That's what structs fix in
Lab 04.

---

## ▶️ Run It
```bash
cargo run
```

## ✅ Expected Result
```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
Next id: 2
```

At this point your `src/main.rs` contains `APP_NAME`, a `main` that declares the customer
variables (with the shadowed `name`), calls `format_customer`, and prints `next_id(id)`, plus
the two functions.

## 🧠 Understand It

**Immutability by default** makes the dangerous thing (mutation) visible. When you read
`let mut`, you know to look for changes. When you read `let`, you know there aren't any. That
local reasoning is what makes Phase 2's borrowing rules workable.

**Function signatures are contracts.** Inference works *inside* a function, never *across*
the signature. Look at only this line:

```rust
fn format_customer(id: u32, name: &str, email: &str, phone: &str) -> String
```

You know what it needs, what it gives back, that it doesn't change its inputs (they're
borrowed, and nothing is `mut`), and that the result is new text the caller now owns. In
Phase 2, signatures also tell you *who owns what*, which is why we'll keep reading them this
carefully.

**The semicolon rule** is the single most common "why won't this compile" moment for people
coming from JS/TS. The model is: blocks have values, the last expression is the value, and `;`
throws a value away. Once that clicks, `if`/`match`-as-expressions feel natural.

**`&str` in, `String` out.** `format_customer` borrows its inputs (it only needs to *read*
them) and returns a newly created, owned `String`. You'll see this shape everywhere in Rust
APIs. Labs 06–09 explain exactly why.

**Overflow** shows a recurring Rust trade-off: correctness checks in debug builds, speed in
release builds, and explicit methods (`checked_*`, `wrapping_*`, `saturating_*`) when you want
a specific behaviour no matter how it's built.

## 🧪 Experiment
> 🟡 **EXPERIMENT 1**: swap two arguments: `format_customer(id, email, name, phone)`. Predict: will
> the compiler catch it? Run `cargo run`.

<details><summary>What happened?</summary>

```text
#1 ada@example.com <Ada Lovelace> 555-0100
```

It compiles and runs, and prints garbage. `name`, `email` and `phone` are all `&str`, so the
types can't tell them apart. Keep this in mind: in Lab 12 you'll create a dedicated `Email`
type, and after that this exact mistake becomes a compile error.

</details>

> 🟡 **EXPERIMENT 2**: change `let id: u32 = 1;` to `let id = "1";`. How many errors do you get,
> and why that many?

> 🟡 **EXPERIMENT 3**: remove the `: u32` annotation entirely (`let id = 1;`). Integer literals
> default to `i32`. So is `id` an `i32` or a `u32` now? Hover over `id` in VS Code
> (rust-analyzer shows the inferred type) and explain how the compiler decided.

> 🟡 **EXPERIMENT 4**: in `next_id`, write `return current + 1;` instead of `current + 1`. Does
> it compile? Run `cargo clippy`. What's the difference between what the compiler thinks and
> what Clippy thinks?

Undo each experiment before the next one. Answers are in `solutions.md`.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — A second customer, using shadowing**
>
> Add Grace Hopper as a second hard-coded customer, **reusing the same four variable names**.
>
> - [ ] Grace's ID is computed with `next_id(...)` from Ada's ID, not typed as a literal `2`
> - [ ] Grace's name is `Grace Hopper`, email `grace@example.com`, phone `555-0199`
> - [ ] You use the variable names `id`, `name`, `email`, `phone` again, with **no `mut`**
>       anywhere in `main`
> - [ ] Grace is printed with `format_customer`, on the line directly after Ada
> - [ ] The existing `Next id:` line stays **last** and now prints `Next id: 3`, without you
>       changing that line at all (make sure you can explain *why* it changed)
>
> Output:
>
> ```text
> Rust CRM v0.1.0
> #1 Ada Lovelace <ada@example.com> 555-0100
> #2 Grace Hopper <grace@example.com> 555-0199
> Next id: 3
> ```

> 🔵 **YOUR TURN 2 — `id_stats`: returning a tuple**
>
> Write a function with exactly this signature:
>
> ```rust
> fn id_stats(current: u32) -> (u32, u32)
> ```
>
> It returns two numbers: **the next ID** after `current`, and **how many IDs are left**
> after `current` before a `u32` runs out.
>
> - [ ] The "next ID" part reuses `next_id`. Don't repeat the `+ 1` logic
> - [ ] The "IDs left" part uses `u32::MAX`, not a typed-out number
> - [ ] The function body is a single expression (no `return`, no `let`)
> - [ ] In `main`, **replace** the `Next id:` line with a call to `id_stats` whose result you
>       **destructure** into two variables, and print exactly:
>
> ```text
> Rust CRM v0.1.0
> #1 Ada Lovelace <ada@example.com> 555-0100
> #2 Grace Hopper <grace@example.com> 555-0199
> Next id: 3 (4294967293 ids left)
> ```
>
> - [ ] `cargo clippy` shows no warnings
> - [ ] Bonus question (answer it, don't code it): can the "IDs left" subtraction ever
>       overflow? Can `id_stats` as a whole ever panic? For which input?

## 💡 Hint
> 💡 **HINT**: Your Turn 1: shadowing isn't limited to transforming a value. `let id = ...;`
> again simply introduces a *new* `id`, and the new value can be computed from the old `id`.

<details><summary>Hint 2 (more specific)</summary>

Your Turn 1: the right-hand side of a `let` is evaluated *before* the new variable exists, so
`let id = next_id(id);` reads the **old** `id` and then shadows it. The `Next id:` line, being
later in the function, sees whichever `id` is in scope at that point.

Your Turn 2: a tuple *expression* is written with parentheses and a comma: `(a, b)`. That's
also the whole function body. In `main`, `let (x, y) = some_function(...);` destructures.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. What's the difference between `let mut x` and writing `let x` twice? When would you choose each?
2. Why must function parameters have type annotations when `let` variables usually don't?
3. In `fn next_id(current: u32) -> u32 { current + 1; }`, what is the value of the block, and what
   is its type?
4. What happens on `u32` overflow in a debug build? In a release build? What would you call to
   detect it explicitly?
5. Why is a customer ID `u32` rather than `i32`?
6. `format_customer` takes `&str` but returns `String`. In one sentence, why can't it return a
   `&str`? (A rough answer is fine, since Phase 2 makes it precise.)

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo run
```

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
Next id: 3 (4294967293 ids left)
```

## Git Commit
```bash
git add .
git commit -m "Add customer formatting function"
git tag lab-02
git push && git push --tags
```

**Next:** [Lab 03 — Control Flow & the Command Loop](../03-control-flow-command-loop/README.md):
the CRM gets a `crm>` prompt and starts listening to you.

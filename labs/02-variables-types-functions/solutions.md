# Lab 02 — Solutions

> 🔴 **SOLUTION**. Only read this after a genuine attempt.

---

## 🔵 Your Turn 1 — A second customer, using shadowing

Add this to `main`, directly after Ada's `println!("{line}");` and **before** the
`Next id:` line:

```rust
    let id = next_id(id);
    let name = "Grace Hopper";
    let email = "grace@example.com";
    let phone = "555-0199";
    println!("{}", format_customer(id, name, email, phone));
```

### Why it works

- `let id = next_id(id);` evaluates the right-hand side **first**, while `id` still means
  Ada's `1`, then introduces a **new** `id` (= 2) that shadows the old one.
- No `mut` is needed because nothing is ever *changed*. Each `let` creates a fresh variable.
  The old values still exist until the end of `main`; they just can't be reached by name any
  more.
- The `Next id:` line was untouched but now prints `3`, because by the time execution reaches
  it, the `id` in scope is Grace's. Shadowing is resolved by **position in the code**: a name
  refers to the nearest `let` above it.
- Calling `format_customer` directly inside `println!` (instead of a `line` variable) is just
  as valid. Use a variable when it helps readability, skip it when it doesn't.

### Would `mut` have been wrong?

Not wrong, just less precise. With `let mut id = 1;` … `id = next_id(id);` you'd also need
`mut` on `name`, `email` and `phone`. That would announce "these variables evolve over time", when
really they're two different customers. When shadowing, each `let` gets its own type too: with
`mut`, all four values would be forced to keep their original types.

(Honestly, re-using variable names for a *different customer* is a sign that these four
values want to be one thing. That thing is the `Customer` struct in Lab 04.)

---

## 🔵 Your Turn 2 — `id_stats`: returning a tuple

```rust
fn id_stats(current: u32) -> (u32, u32) {
    (next_id(current), u32::MAX - current)
}
```

In `main`, the `Next id:` line becomes:

```rust
    let (next, remaining) = id_stats(id);
    println!("Next id: {next} ({remaining} ids left)");
```

### Why it's written this way

- `(a, b)` is a tuple **expression**, and as the last thing in the block it's the return value.
  No `return`, no `;`: the same rule as `next_id`.
- Reusing `next_id` keeps the "how do IDs advance?" rule in **one** place. If the rule changes
  (it will, in Lab 07 the store hands out IDs), `id_stats` follows automatically.
- `let (next, remaining) = ...` is **destructuring**: the pattern on the left has the same shape
  as the value on the right. It's the tuple version of JS's `const [next, remaining] = ...`.
  The alternative, `let stats = id_stats(id);` with `stats.0` / `stats.1`, works but makes the
  reader remember which position means what.
- Inline format arguments (`{next}`) work for plain variable names. They don't work for
  expressions like `{stats.0}` (you'll see that exact error in Lab 04).

### Bonus question

- **`u32::MAX - current`** can never overflow: `current` is at most `u32::MAX`, so the result
  is at least `0`. Subtraction overflows only when the right side is *bigger* than the left.
- **`id_stats` as a whole can panic**, for exactly one input: `id_stats(u32::MAX)`, because
  `next_id(u32::MAX)` computes `u32::MAX + 1`. It panics in a debug build and wraps to `0` in
  release, exactly as in Step 7. A function is only as safe as the functions it calls.

---

## 🧪 Experiment answers

### Experiment 1 — swapped arguments

It compiles and prints `#1 ada@example.com <Ada Lovelace> 555-0100`. Types only protect you
when they're *different*. Three `&str` parameters in a row is a known weak spot. Rust's usual
fix is the **newtype** pattern, a dedicated type like `struct Email(String)`, which you'll
build in Lab 12. After that, passing a name where an `Email` is expected is a compile error.

### Experiment 2 — `let id = "1";`

Two errors, both E0308 `expected u32, found &str`: one at `format_customer(id, ...)` and one at
`next_id(id)`. The compiler reports **every** place where the wrong type is used, not just
the first one. (If you'd done Your Turn 1 already, you'll see the second one at
`next_id(id)` in Grace's `let`.) Notice that the `let` line itself isn't an error: `"1"` is a
perfectly good `&str`. The mistake shows up where the value is *used* as a number.

### Experiment 3 — `let id = 1;` without annotation

`id` is a `u32`. Integer literals only fall back to `i32` when **nothing** else constrains
them. Here, `id` is passed to `format_customer(id: u32, ...)`, so the compiler infers `u32`
from that later use. This is the "inference can look at how a variable is used later" point
from Step 1, and something TypeScript can't do. The annotation is still worth keeping on the
*first* customer ID, because it documents intent where the reader starts.

### Experiment 4 — `return current + 1;`

It compiles: `return` is perfectly legal Rust. But `cargo clippy` warns `unneeded 'return'
statement` (`clippy::needless_return`). The compiler checks **correctness**, Clippy checks
**idiom**. Idiomatic Rust reserves `return` for early exits and lets the tail expression be the
result.

---

## ✅ Checkpoint answers

1. `let mut x` is **one** variable whose value changes, and its type can't change. Two `let x`
   are **two** variables, where the second hides the first and may have a different type. Use
   `mut` for values that evolve (counters, a list you push into). Use shadowing for
   transformations (raw input → trimmed → parsed).
2. Signatures are contracts. They must be readable without the body, and they stop errors in
   one function from leaking inference changes into others. Inside a function, the compiler can
   see all the uses, so annotations are optional.
3. The block's value is `()` (unit), of type `()`. The `;` made `current + 1` a statement, so the
   block has no tail expression.
4. Debug: **panic** ("attempt to add with overflow"). Release: **wraps around** silently.
   Explicitly: `checked_add` (returns `None` on overflow), or `wrapping_add` /
   `saturating_add` when you want that behaviour on purpose.
5. Because an ID can never be negative, the type should make negative IDs impossible. `u32`
   documents that, and the compiler enforces it (as in the `-1` experiment).
6. The formatted text is brand new. Something must **own** it, and a `&str` only *borrows* text
   that someone else owns. The function returns ownership of the new `String` to the caller.

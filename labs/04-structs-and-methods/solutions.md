# Lab 04 — Solutions

> 🔴 **SOLUTION**. Only read this after a genuine attempt.

---

## 🔵 Your Turn 1 — `has_phone`

### The method (inside `impl Customer`)

```rust
    fn has_phone(&self) -> bool {
        !self.phone.is_empty()
    }
```

### In `run_demo` (after the two `{:?}` / `{:#?}` prints)

```rust
    let alan = Customer::new(
        next_id(grace.id),
        "Alan Turing".to_string(),
        "alan@example.com".to_string(),
        String::new(),
    );
    println!("{} has a phone: {}", ada.name, ada.has_phone());
    println!("{} has a phone: {}", alan.name, alan.has_phone());
```

and the `id_stats` line now uses Alan:

```rust
    let (next, remaining) = id_stats(alan.id);
    println!("Next id: {next} ({remaining} ids left)");
```

### Why it's written this way

- **`&self`**: `has_phone` only *reads* the customer, so it borrows it. After calling it you
  still have `ada` and `alan` to use.
- **`is_empty()`** asks the `String` directly. Alternatives such as `self.phone.len() > 0` or
  `self.phone != ""` work too, but `is_empty` states the intent, and Clippy actually suggests
  it over the `len() > 0` version (`clippy::len_zero`).
- **`String::new()`** creates an empty `String` without allocating anything. `String::from("")`
  and `"".to_string()` also work, but `String::new()` says "empty" most clearly, and the task
  asked for no text literal.
- **`ada.name` in `println!`**: positional `{}` arguments can be any expression, including a
  field access, unlike inline `{ada.name}`.

### Design note: what about `"   "`?

With this definition, a phone of three spaces "has a phone". Should it? That's a business-rule
question, not a Rust question. Right now, input is trimmed before it reaches a customer (from
Lab 05 on, `prompt` trims), so whitespace-only phones can't happen in practice. In Lab 12 the
phone becomes `Option<String>`, which is `None` when there's no phone. Then "is there a
phone?" is answered by the **type**, and this question goes away entirely.

---

## 🔵 Your Turn 2 — `matches_email`

### The method

```rust
    fn matches_email(&self, email: &str) -> bool {
        self.email == email
    }
```

### In `run_demo` (after the `has a phone` lines, before `id_stats`)

```rust
    println!(
        "ada@example.com is Ada's email: {}",
        ada.matches_email("ada@example.com")
    );
    println!(
        "grace@example.com is Ada's email: {}",
        ada.matches_email("grace@example.com")
    );
```

### Why it's written this way

- **Two parameters**: `&self` (the customer being asked) plus `email: &str` (the email to
  compare). When you call `ada.matches_email("x")`, `ada` becomes `self` and `"x"` becomes `email`.
- **`email: &str`, not `String`**: the method only needs to *look* at the text. Asking for a
  `String` would force every caller to create an owned copy just to compare it. "Take `&str`
  when you only read text" is the same rule as `format_customer` in Lab 02.
- **`self.email == email`** compares a `String` with a `&str` directly. Rust's standard library
  defines `==` between them (by content, not by address). The comparison already *is* a `bool`,
  so it's the whole body. `if self.email == email { true } else { false }` triggers Clippy's
  `needless_bool`.
- **The Clippy trap**: `self.email == email.to_string()` compiles, but creates a brand-new
  `String` just to compare it and throw it away. Clippy flags it as `clippy::cmp_owned` ("this
  creates an owned instance just for comparison").
- **`self.email` vs `email`**: the parameter has the same name as the field, and that's fine.
  `self.email` is always the field, and plain `email` is always the parameter. Fields are only
  ever reached through `self.`, so there's nothing to guess.

### Full demo output after both Your Turns

```text
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
Ada Lovelace has a phone: true
Alan Turing has a phone: false
ada@example.com is Ada's email: true
grace@example.com is Ada's email: false
Next id: 4 (4294967292 ids left)
```

Both methods carry into Lab 05: `has_phone` gets tested (and put to work inside `summary`), and
`matches_email` powers the duplicate-email check.

---

## 🧪 Experiment answers

### Experiment 1 — struct update syntax

`..ada` **moves** every field you didn't list out of `ada` into `ada_at_work`. For `name` and
`phone` (both `String`), a move means `ada_at_work` now owns those heap buffers and `ada` doesn't.
Rust won't let two owners think they own the same buffer: when they were both cleaned up, the
buffer would be freed twice. So `ada` becomes **partially moved**, and you can no longer use it
as a whole (`ada.summary()` needs every field).

`ada.id` still works because `u32` is **`Copy`**: small, plain values like integers are
*copied*, not moved, so `ada` keeps its own `id`. The note in the error says exactly this:
*"`ada.phone` has type `String`, which does not implement the `Copy` trait"*.

Moves, `Copy`, and why Rust works this way are the subject of Lab 06. If this answer felt like
a lot of new words, that's expected. Come back to it after Lab 06 and it'll read as obvious.

### Experiment 2 — missing field

```text
error[E0063]: missing field `phone` in initializer of `Customer`
  --> src/main.rs:15:9
   |
15 |         Self { id, name, email }
   |         ^^^^ missing `phone`
```

Yes, it's "no optional by accident". Every struct value must initialise every field.

### Experiment 3 — `Customer::summary(&ada)`

It compiles and prints the same thing. Method-call syntax is **sugar**: `ada.summary()` is
`Customer::summary(&ada)`, and the compiler adds the `&` for you because the method takes
`&self`. The "dot" is just a convenient way to pass the first argument. This automatic `&`
(*auto-referencing*) is why you've never had to write `(&ada).summary()`. Lab 07 covers it
properly.

---

## ✅ Checkpoint answers

1. A `Customer` must **own** its data so it can outlive wherever the text came from (soon:
   a `read_line` buffer). A `&str` field would borrow text owned by someone else, which needs
   lifetimes (Lab 10) to prove the borrowed text lives long enough.
2. `new` has no `self` parameter: it's an **associated function**, called on the type with `::`.
   `summary` takes `&self`: it's a **method**, called on a value with `.`.
3. `Self` is the type the `impl` block is for, here `Customer`. It keeps the `impl` correct if
   the type is renamed, and it reads as "this type".
4. It generates an implementation of the `Debug` trait from the fields, which enables `{:?}`
   and `{:#?}`. Rust doesn't print arbitrary types because printing is a capability a type opts
   into. Some types shouldn't be printable at all (secrets, which you'll see in Lab 34), and
   some need custom output.
5. `new` wants owned `String`s, and literals are `&str`. Fix with `String::from("Ada")` or
   `"Ada".to_string()`. Both allocate an owned copy, visibly.
6. `id` is a `u32`, which is `Copy`, so `..ada` copied it and `ada` still has its own. `name`
   is a `String`, which is not `Copy`, so it was **moved** into `ada_at_work`.

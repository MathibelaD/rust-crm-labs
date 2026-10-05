# Lab 01 — Solutions

> 🔴 **SOLUTION**. Only read this after a genuine attempt. Reading a solution you haven't
> struggled with teaches much less than the struggle itself.

---

## 🔵 Your Turn 1 — A package line with a description

### Cargo.toml

```toml
[package]
name = "rust-crm"
version = "0.1.0"
edition = "2024"
description = "A CRM built while learning Rust"

[dependencies]
```

### src/main.rs (temporary version)

```rust
fn main() {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
    println!(
        "Package: {} ({})",
        env!("CARGO_PKG_NAME"),
        env!("CARGO_PKG_DESCRIPTION")
    );
}
```

```text
Rust CRM v0.1.0
Package: rust-crm (A CRM built while learning Rust)
```

### Why it's written this way

- Cargo sets `CARGO_PKG_DESCRIPTION` for every crate it compiles. If `description` is missing
  from `Cargo.toml`, the variable is still defined but **empty**, so the line would print
  `Package: rust-crm ()`. That's different from the misspelled-variable case in Step 12, which
  was a compile error because the variable didn't exist at all.
- Two `{}` placeholders, two arguments, filled in order. You could also name them
  (`"{name} ({desc})", name = env!(...), desc = env!(...)`); for two values, positional is fine.
- `cargo fmt` splits the `println!` over several lines because it's longer than 100 characters,
  rustfmt's default line width. Let it.

Then delete the `Package:` line again. `Cargo.toml` keeps the `description`.

---

## 🔵 Your Turn 2 — Make Clippy complain, then make it happy

There are many valid answers. Here's the one Hint 2 points at.

### Code that triggers a lint

```rust
fn main() {
    println!("Rust CRM v{}", version());
}

fn version() -> &'static str {
    return env!("CARGO_PKG_VERSION");
}
```

(`&'static str` is "a borrowed piece of text that lives for the whole program". String literals
and `env!` results are exactly that. It's fully explained in Labs 09–10, so for now read it as
"text".)

```text
warning: unneeded `return` statement
 --> src/main.rs:6:5
  |
6 |     return env!("CARGO_PKG_VERSION");
  |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  |
  = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.99.0/index.html#needless_return
  = note: `#[warn(clippy::needless_return)]` on by default
help: remove `return`
  |
6 -     return env!("CARGO_PKG_VERSION");
6 +     env!("CARGO_PKG_VERSION")
  |
```

- **Lint:** `clippy::needless_return`
- **Where:** `src/main.rs:6:5`
- **Why it exists:** in Rust a block's *last expression* is its value, so a function ends by
  simply writing the value with no `return` and no semicolon. `return` is for *early* exits. An
  explicit `return` on the last line is noise that makes readers look for an early exit that
  isn't there. (Lab 02 is all about this expression-vs-statement idea.)

### The fix

```rust
fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
```

Note the **missing semicolon**. Add one back (`env!("CARGO_PKG_VERSION");`) and you get a
*compile error*, not a lint, because the function would then return nothing. You'll trigger
exactly that error on purpose in Lab 02.

### Other lints people commonly hit here

| Code | Lint |
|---|---|
| `println!("{}", "text")` | `print_literal` (excluded by the task, since you saw it in Step 11) |
| `let x = 5; let y = x * 1;` | `identity_op` ("this operation has no effect") |
| `fn version() -> &'static str { return env!(...); }` | `needless_return` (above) |

**Why not just turn the lint off?** You can (`#[allow(clippy::needless_return)]`), and very
occasionally that's the right call, with a comment explaining why. But a lint is a reviewer
telling you something. Silencing it without understanding it defeats the point of running
Clippy.

Finally, `src/main.rs` goes back to:

```rust
fn main() {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
}
```

---

## 🧪 Experiment answers

### Bumping the version to 0.2.0

```text
   Compiling rust-crm v0.2.0 (/Users/you/code/rust-crm)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.07s
     Running `target/debug/rust-crm`
Rust CRM v0.2.0
```

Cargo recompiles because `env!` reads the value **at compile time** and bakes it into the
executable. The old binary literally contains the bytes `0.1.0`. Cargo knows its package
metadata is an input to the build, so changing it invalidates the old build. If `env!` worked
at run time (like `process.env` in Node, or Rust's `std::env::var`, which you'll use in
Lab 23), no rebuild would be needed and the value could change without recompiling.

### Deleting `target/`

Everything still works. `cargo run` takes a moment longer because it rebuilds from scratch.
`target/` is a **cache of derived files**: everything in it can be regenerated from `src/` and
`Cargo.toml` (plus `Cargo.lock`). Derived, regenerable, machine-specific and large is the
textbook description of something that does **not** belong in Git, which is why `cargo new`
puts `/target` in `.gitignore`.

### Why is a one-line binary ~450 KB?

There's no runtime in the JVM or Node sense, but the executable still contains:

- the parts of the **standard library** your program uses, compiled in (statically linked):
  formatting machinery for `println!`, I/O, and the panic handler that prints nice messages
  and backtraces;
- **symbols and debug information** (much more of it in the debug build).

The release build is smaller but not tiny, because it still keeps symbol names. In Lab 40 you'll
add `strip = true` and `lto = "thin"` to the release profile and watch the size drop. For a
server binary, a few hundred KB to a few MB is completely normal.

---

## ✅ Checkpoint answers

1. **rustup** manages toolchains (installs, updates, switches Rust versions). **rustc** is the
   compiler. **cargo** is the build tool and package manager that calls rustc for you. To get
   the newest Rust: `rustup update`.
2. `cargo check` stops before generating machine code and linking. That's the slow half of
   compilation. `check` is "not enough" when you need to *run* something (`cargo run`,
   `cargo test`), and occasionally for errors only found during code generation. You'll meet
   one in Lab 02: `u32::MAX + 1` passes `cargo check` but fails `cargo build`.
3. Compile time. Proof: misspelling the variable name was a compile error, and changing
   `Cargo.toml` forced a recompile.
4. `Cargo.toml` and `src/main.rs` obviously, and **`Cargo.lock` too** for an application, so
   every build uses identical dependency versions. Only `target/` is excluded: it's derived,
   regenerable, large and machine-specific.
5. The edition picks a set of language rules and defaults for *this crate*. Editions are how
   Rust makes small breaking changes without breaking existing code. Every compiler supports
   every edition up to its own release, so "Rust 1.99, edition 2024" is a normal combination.
6. So you can name the exact state of the project at the end of each lab.
   `git diff lab-07 lab-08` shows every line the Lab 08 refactor changed, which is perfect for
   reviewing what you learned or comparing with a solution.

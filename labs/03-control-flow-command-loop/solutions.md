# Lab 03 — Solutions

> 🔴 **SOLUTION**. Only read this after a genuine attempt.

---

## 🔵 Your Turn 1 — Show the build profile in `version`

Replace the one-line `"version"` arm with a block:

```rust
            "version" => {
                let profile = if cfg!(debug_assertions) {
                    "debug"
                } else {
                    "release"
                };
                println!(
                    "{APP_NAME} v{} ({profile} build)",
                    env!("CARGO_PKG_VERSION")
                );
            }
```

```text
crm> version
Rust CRM v0.1.0 (debug build)
```

and with `cargo run --release`:

```text
crm> version
Rust CRM v0.1.0 (release build)
```

### Why it's written this way

- **`if` as an expression**: both branches are `&str`, so `profile` is a `&str`. One
  variable, one `println!`. That's the JS ternary `const profile = debug ? "debug" : "release"`
  written the Rust way.
- **`cfg!(debug_assertions)`** is decided at **compile time**. In a release build the
  compiler sees `if false { "debug" } else { "release" }` and simply keeps `"release"`. There's
  no runtime check at all. (`cfg!` belongs to the same family as `env!` from Lab 01: macros that
  bake build information into the binary.)
- **The arm became a block** because it now does two things. A block arm doesn't need a
  trailing comma.
- `cargo fmt` breaks the `if` and the `println!` over several lines. That's rustfmt's
  decision, not a style choice you need to make.

### A common alternative, and why it's weaker

```rust
            "version" => {
                if cfg!(debug_assertions) {
                    println!("{APP_NAME} v{} (debug build)", env!("CARGO_PKG_VERSION"));
                } else {
                    println!("{APP_NAME} v{} (release build)", env!("CARGO_PKG_VERSION"));
                }
            }
```

It works, but the message format is duplicated: change the wording in one branch, forget the
other, and the two builds disagree. Computing *only the part that differs* with an `if`
expression keeps the rest in one place. That's the habit the acceptance criteria were nudging
you towards.

---

## 🔵 Your Turn 2 — A table-driven help screen

```rust
fn print_help() {
    let commands = [
        ("help", "Show this list"),
        ("version", "Show the CRM version"),
        ("demo", "Print the demo customers"),
        ("quit", "Exit the CRM (also: exit)"),
    ];

    println!("Commands:");
    for (name, description) in commands {
        println!("  {name:<10}{description}");
    }
}
```

### Why it's written this way

- **`commands` is an array of tuples**, of type `[(&str, &str); 4]`: a fixed-size list (the
  `4` is part of the type) of `(name, description)` pairs. You didn't have to write that type,
  because the compiler inferred it, including the length. Adding a row changes the length,
  and inference keeps up.
- **`for (name, description) in commands`** destructures each tuple straight in the loop
  header, the same pattern as `let (next, remaining) = ...` in Lab 02.
- **`{name:<10}`** means left-align (`<`) in a field 10 characters wide. `help` becomes
  `help      ` (4 letters + 6 spaces), and two leading spaces in the format string reproduce the
  original indentation exactly. Other alignments are `>` (right) and `^` (centre).
- **Data vs logic**: the knowledge "what commands exist" is now separate from "how help is
  printed". In Lab 05 you add three commands by adding three lines to the array, and the
  formatting can't drift out of alignment.

### Variation: a `const` table

You could lift the table out of the function:

```rust
const COMMANDS: [(&str, &str); 4] = [
    ("help", "Show this list"),
    // ...
];
```

That works too, but a `const` needs its type written out **including the length**, so every
new command means updating the `4` as well. Inside the function, inference handles it. Either
is acceptable for this lab.

### How to confirm "byte-for-byte identical"

Capture the output before and after the refactor and compare:

```bash
printf 'help\nquit\n' | cargo run -q > before.txt    # run this BEFORE refactoring
printf 'help\nquit\n' | cargo run -q > after.txt     # and this after
diff before.txt after.txt && echo identical
rm before.txt after.txt
```

No output from `diff` means no differences. (In Lab 05 you'll make checks like this automatic
with tests.)

---

## 🧪 Experiment answers

### Experiment 1 — no `flush`

You type `help` at an apparently empty line. The `crm> ` only appears *after* you press Enter,
glued to the front of the next output (`crm> Commands:`). Rust's stdout is **line-buffered**:
it sends text to the terminal when it sees a newline. `print!("crm> ")` has no newline, so the
prompt waits in the buffer until the next `println!` pushes everything out. Rust does **not**
flush stdout automatically before reading stdin (C's `stdio` sometimes does), so the explicit
`flush` is required for prompts. You'll write a `prompt()` helper in Lab 05 that does both
steps, so you can't forget.

### Experiment 2 — `input` declared above the loop

```text
crm> help
Commands:
  ...
crm> help
Unknown command: help
help. Type 'help' for a list of commands.
crm> quit
Unknown command: help
help
quit. Type 'help' for a list of commands.
```

`read_line` **appends**. It never clears the buffer. The second read leaves `"help\nhelp\n"` in
`input`, and `trim` only removes whitespace at the **ends**, so the match sees `"help\nhelp"`.
Even `quit` stops working, because the buffer keeps growing (you have to use Ctrl-D to get
out). Two possible fixes:

1. create a fresh `String` each iteration (what the lab does), or
2. call `input.clear()` at the top of each iteration, which reuses the same allocation.

Option 2 is a micro-optimisation that's irrelevant at typing speed. Option 1 makes the bug
impossible, since each iteration *can't* see the previous one's data. Prefer designs that make
bugs impossible over designs that need you to remember something.

### Experiment 3 — `HELP` and `  help  `

`  help  ` works because `trim` strips the spaces. `HELP` is an unknown command, because string
comparison is exact and case-sensitive. That's a **decision**, not a bug: most shells are
case-sensitive too. To accept any case you'd lowercase first, e.g.
`match input.trim().to_lowercase().as_str()`. `to_lowercase` must build a **new** `String`
(lowercasing can even change the length in some languages), and `.as_str()` views it. We're
not doing it, but notice that it costs an allocation per command where `trim()` cost nothing.

### Experiment 4 — catch-all arm first

```text
warning: unreachable pattern
  --> src/main.rs:31:13
   |
27 |             other => {
   |             ----- matches any value
...
31 |             "help" => print_help(),
   |             ^^^^^^ no value can reach this
```

…repeated for every arm below it. It's a *warning*, not an error, because the code is still
well-defined: every input goes to `other`. But the compiler has proven those arms are dead.
Arms are tried top to bottom, and the first match wins, so put specific patterns first and
the catch-all last.

---

## ✅ Checkpoint answers

1. The patterns `"help"` are `&str` and `input` is a `String`, and a `match` needs one type.
   **`String`**: owned, growable text with its own heap buffer. **`&str`**: a borrowed,
   read-only view of text owned by someone else (or baked into the program).
2. A `bool` has exactly two values, so `true` and `false` arms cover everything. A `&str` has
   infinitely many possible values, so only a catch-all can make the `match` exhaustive.
3. `read_line` returns the number of bytes read, and **0 means end of input**. Before we checked
   it, Ctrl-D made every `read_line` return instantly with an empty string, which went to the
   `other` arm, which looped forever.
4. A `while`/`for` can end because its condition fails or its items run out, without any
   `break`. Then there'd be no value to produce. A `loop` can **only** end via `break` (or
   `return`/panic), so the value is always defined.
5. `help` → 1. `<Enter>` → 1 (`continue`). `oops` → 1 (`continue`). `version` → 2. `quit` →
   `break 2`. Output: `Goodbye! (2 commands this session)`.
6. So every iteration starts with an empty buffer. `read_line` appends, so a shared buffer would
   accumulate every previous command (Experiment 2). As a bonus, the `String` is cleaned up
   automatically at the end of each iteration (Lab 06 explains exactly when).

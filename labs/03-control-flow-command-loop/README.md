# Lab 03 — Control Flow & the Command Loop

> **Phase:** 1 — Rust Foundations · **Builds on:** Lab 02 · **Time:** ~2–3 hours
> **Your repo before this lab:** tag `lab-02` · **After:** tag `lab-03`

> This lab assumes you completed **Your Turn 1 and 2 in Lab 02** (Grace Hopper and `id_stats`).
> If you didn't, copy them from [Lab 02's `solutions.md`](../02-variables-types-functions/solutions.md) first.

## 🎯 Goal
Turn the CRM into an interactive shell: a `crm>` prompt that reads commands from the keyboard
(`help`, `version`, `demo`, `quit`) until you leave, then says how many commands you ran.

## 🧠 What You'll Learn
- Reading a line from stdin with `read_line`, and why the prompt needs `flush`
- `match` on text, and why the compiler insists that a `match` covers *every* case
- A first look at `String` vs `&str` (owned text vs a view into text)
- `loop`, `while` and `for`, and when to use each
- `break` **with a value**, and `continue`
- `if` as an expression
- Handling end-of-input (Ctrl-D) correctly

## 🔨 What We're Building
The **REPL** (read–eval–print loop) the CRM lives in until Lab 27:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> help
Commands:
  help      Show this list
  version   Show the CRM version
  demo      Print the demo customers
  quit      Exit the CRM (also: exit)
crm> quit
Goodbye! (1 commands this session)
```

Every feature from here to Lab 26 is a new command in this loop: `add`, `list`, `show`,
`delete`, `search`, `deal move`, `lead convert`… So it's worth building it properly now.

---

## Step 1 — Make room: move the demo into a function

`main` is about to become the command loop. The customer printing from Lab 02 shouldn't
disappear (you'll rebuild it with a struct in Lab 04), so it moves into its own function and
becomes the `demo` command.

> 🟢 **FOLLOW ALONG**

1. Create a new function `fn run_demo() { }` below `main`.
2. **Move** everything in `main` *after the banner line* into `run_demo`: Ada, Grace, and the
   `id_stats` lines. Don't change any of it.
3. Make `main` call it:

```rust
fn main() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    run_demo();
}
```

```bash
cargo run
```

```text
Rust CRM v0.1.0
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
Next id: 3 (4294967293 ids left)
```

The same output as Lab 02. A **refactor** changes structure without changing behaviour, and
"the output didn't change" is how you check it. (In Lab 05 you'll check it with tests
instead of eyeballs.)

---

## Step 2 — Read one line from the keyboard

> 🟢 **FOLLOW ALONG**: add this line at the very top of `main.rs`:

```rust
use std::io::{self, Write};
```

`use` brings names into scope, like `import` in JS. This line imports the `io` module from the
standard library (`std`) as `io`, plus the `Write` **trait**. You need `Write` in scope to call
`.flush()`; traits are Lab 15's topic. For now: "methods from a trait only work when the trait
is imported."

Now replace `main` with:

```rust
fn main() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    print!("crm> ");
    io::stdout().flush().expect("failed to flush stdout");

    let mut input = String::new();
    io::stdin()
        .read_line(&mut input)
        .expect("failed to read from stdin");

    println!("You typed: {input:?}");
}
```

Run it, type `help` and press Enter:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> help
You typed: "help\n"
```

Line by line:

- **`print!`** is `println!` without the newline, so the cursor stays after `crm> `.
- **`io::stdout().flush()`**: output is *buffered*. Rust collects text and sends it to the
  terminal in chunks, usually at each newline. Our prompt has no newline, so without `flush` it
  could sit in the buffer while the program waits for you to type. `flush` means "send it now".
- **`String::new()`** creates an empty, growable, **owned** piece of text. It's owned because
  `read_line` needs somewhere to *write* the characters, and that buffer has to belong to
  someone: our `input` variable.
- **`.read_line(&mut input)`** appends the line you type to `input`. The `&mut` lends `input`
  to `read_line` **mutably**: "you may change this, then give it back". You'll study `&` and
  `&mut` in depth in Lab 07. For now, read `&mut input` as "let read_line write into my buffer".
  Notice that `input` itself had to be `let mut`.
- **`.expect("...")`**: reading can fail in principle (stdin closed, invalid UTF-8). `expect`
  says "if it failed, crash with this message". That's fine for now. Lab 12 replaces crashes
  with proper error handling.
- **`{input:?}`** (debug format) reveals the **`\n`** at the end. `read_line` keeps the newline
  from the Enter key. Remember that, because it's about to matter.

`run_demo` is now unused, so the compiler warns `function run_demo is never used`, and also
about `format_customer`, `next_id` and `id_stats`, since only `run_demo` called them. Dead-code
warnings are *transitive*. That's fine for now; `run_demo` gets used again in Step 4.

---

## Step 3 — `match` on the input

> 🟡 **EXPERIMENT**: predict, then run `cargo check`. Replace the `println!("You typed…")` line
> (and everything after the banner) so `main` looks like this:

```rust
fn main() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    loop {
        print!("crm> ");
        io::stdout().flush().expect("failed to flush stdout");

        let mut input = String::new();
        io::stdin()
            .read_line(&mut input)
            .expect("failed to read from stdin");

        match input {
            "help" => print_help(),
            "quit" => break,
        }
    }

    println!("Goodbye!");
}

fn print_help() {
    println!("Commands:");
    println!("  help      Show this list");
    println!("  quit      Exit the CRM");
}
```

New pieces: **`loop { }`** repeats forever until a `break`. **`match`** compares a value
against *patterns*, top to bottom, and runs the first arm that matches. It's like `switch`
without fall-through, and much more powerful, as you'll see in Lab 11.

```text
error[E0308]: mismatched types
  --> src/main.rs:19:13
   |
18 |         match input {
   |               ----- this expression has type `String`
19 |             "help" => print_help(),
   |             ^^^^^^ expected `String`, found `&str`
   |
help: consider converting the `String` to a `&str` using `.as_str()`
   |
18 |         match input.as_str() {
   |                    +++++++++
```

(The same error repeats for `"quit"`.)

**Read the error.** `input` is a `String`, but `"help"` is a `&str`. They're different types:

```text
String  = text you OWN. It has its own growable buffer on the heap; read_line wrote into it.
&str    = a VIEW of text that lives somewhere else: borrowed, read-only.
          "help" is a &str that points at text baked into your program.
```

Patterns in `match` must have the same type as the value being matched. The suggested fix,
`input.as_str()`, gives you a `&str` view of the `String`'s contents. Apply it and check again:

```text
error[E0004]: non-exhaustive patterns: `&_` not covered
  --> src/main.rs:18:15
   |
18 |         match input.as_str() {
   |               ^^^^^^^^^^^^^^ pattern `&_` not covered
   |
   = note: the matched value is of type `&str`
   = note: `&str` cannot be matched exhaustively, so a wildcard `_` is necessary
help: ensure that all possible cases are being handled by adding a match arm with a wildcard pattern or an explicit pattern as shown
   |
20 ~             "quit" => break,
21 ~             &_ => todo!(),
   |
```

A new error, and an important one. **A `match` must handle every possible value.** There are
infinitely many strings, and we've handled two. In JS, a `switch` with no `default` silently
does nothing. Rust makes you decide what "anything else" means. This *exhaustiveness checking*
becomes one of your best tools in Lab 11, when matching on enums.

> 🟢 **FOLLOW ALONG**: add a catch-all arm. A plain name in a pattern matches anything and
> *binds* the value to that name:

```rust
        match input.as_str() {
            "help" => print_help(),
            "quit" => break,
            other => println!("Unknown command: {other:?}"),
        }
```

Run it and type `help`:

```text
crm> help
Unknown command: "help\n"
```

There's the `\n` from Step 2. `"help\n"` isn't `"help"`. Users also type stray spaces. The fix
is `.trim()`, the same method you used on Ada's name in Lab 02:

```rust
        match input.trim() {
            "help" => print_help(),
            "quit" => break,
            other => println!("Unknown command: {other}. Type 'help' for a list of commands."),
        }
```

`.trim()` returns a `&str` view of the **same** text, minus the whitespace at both ends.
Nothing is copied, it's just a narrower view, and that's also why you no longer need `.as_str()`.
Lab 09 is all about these views (*slices*).

Run it:

```text
crm> help
Commands:
  help      Show this list
  quit      Exit the CRM
crm> hello
Unknown command: hello. Type 'help' for a list of commands.
crm> quit
Goodbye!
```

---

## Step 4 — `demo`, `version`, and end-of-input

> 🟢 **FOLLOW ALONG**: add two arms *above* the `other` arm:

```rust
            "version" => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
            "demo" => run_demo(),
```

Add matching lines to `print_help`:

```rust
fn print_help() {
    println!("Commands:");
    println!("  help      Show this list");
    println!("  version   Show the CRM version");
    println!("  demo      Print the demo customers");
    println!("  quit      Exit the CRM");
}
```

Arm order matters: arms are tried top to bottom, and `other` matches *everything*. Anything
below a catch-all arm is unreachable, and the compiler will warn you if you try.

### What happens at end of input?

> 🟡 **EXPERIMENT**: run `cargo run`, and at the prompt press **Ctrl-D** (on macOS/Linux, that means
> "end of input"). Predict first. Have **Ctrl-C** ready.

```text
crm> Unknown command: . Type 'help' for a list of commands.
crm> Unknown command: . Type 'help' for a list of commands.
crm> Unknown command: . Type 'help' for a list of commands.
crm> Unknown command: . Type 'help' for a list of commands.
...
```

An infinite loop! Press **Ctrl-C** to kill it. Why?

- Ctrl-D closes stdin. Every later `read_line` returns immediately, reads **zero bytes**, and
  leaves `input` empty.
- `"".trim()` is `""`, which falls into `other`, and the loop goes round again, forever.

`read_line` tells you how many bytes it read. On success it returns that count (it's inside
an `Ok(...)`, which `expect` unwraps; more on that in Lab 12). **Zero bytes means end of input.**
This matters beyond the keyboard. When input is piped from a file
(`cargo run < commands.txt`), end-of-file looks exactly the same.

> 🟢 **FOLLOW ALONG**: capture the count and stop on zero:

```rust
        let mut input = String::new();
        let bytes_read = io::stdin()
            .read_line(&mut input)
            .expect("failed to read from stdin");

        if bytes_read == 0 {
            // End of input (Ctrl-D): leave the loop like `quit` would.
            println!();
            break;
        }
```

`println!()` with no arguments prints just a newline, so "Goodbye!" doesn't end up on the same
line as the prompt. Try Ctrl-D again: it now exits cleanly.

**Pressing Enter on an empty line** still says `Unknown command: .`, which is noisy. Add an arm
(above `other`) that does nothing and goes straight back to the prompt:

```rust
            "" => continue,
```

**`continue`** skips the rest of the current loop iteration and starts the next one.
(**`break`** leaves the loop entirely.)

---

## Step 5 — `break` with a value: counting commands

At the end of a session, the CRM should report how many commands you ran. Only real commands
count: not blank lines, not typos, not `quit` itself.

In Rust, **`loop` is an expression**. `break some_value` exits the loop *and* makes
`some_value` the value of the whole `loop` expression.

> 🟢 **FOLLOW ALONG**: here is the complete `main`:

```rust
fn main() {
    println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION"));
    println!("Type 'help' for a list of commands.");

    let mut count: u32 = 0;

    let commands_run = loop {
        print!("crm> ");
        io::stdout().flush().expect("failed to flush stdout");

        let mut input = String::new();
        let bytes_read = io::stdin()
            .read_line(&mut input)
            .expect("failed to read from stdin");

        if bytes_read == 0 {
            // End of input (Ctrl-D): leave the loop like `quit` would.
            println!();
            break count;
        }

        match input.trim() {
            "help" => print_help(),
            "version" => println!("{APP_NAME} v{}", env!("CARGO_PKG_VERSION")),
            "demo" => run_demo(),
            "quit" | "exit" => break count,
            "" => continue,
            other => {
                println!("Unknown command: {other}. Type 'help' for a list of commands.");
                continue;
            }
        }

        count += 1;
    };

    println!("Goodbye! ({commands_run} commands this session)");
}
```

And update the `quit` line in `print_help`:

```rust
    println!("  quit      Exit the CRM (also: exit)");
```

What changed:

- **`let mut count: u32 = 0;`** is a real use of `mut`: a value that evolves.
- **`let commands_run = loop { ... };`** binds the loop's value to a variable. Note the `;`
  after the closing `}`, because this is a `let` statement.
- **`break count`** in both exit paths (Ctrl-D and quit).
- **`"quit" | "exit"`** is an *or-pattern*: one arm, two accepted spellings.
- **`count += 1`** sits *after* the `match`, so it only runs when an arm finishes normally.
  `""` and unknown commands `continue` past it, and `quit` `break`s past it. The control flow
  *is* the counting rule.
- The `other` arm is now a **block** `{ ... }` because it does two things. An arm is either one
  expression followed by a `,`, or a block (the comma after a block is optional).

> 🟡 **EXPERIMENT**: change `"quit" | "exit" => break count,` to just `break,`. Predict the error.

```text
error[E0308]: mismatched types
  --> src/main.rs:30:32
   |
30 |             "quit" | "exit" => break,
   |                                ^^^^^ expected `u32`, found `()`
   |
help: give the `break` a value of the expected type
   |
30 |             "quit" | "exit" => break /* value */,
   |                                      +++++++++++
```

A plain `break` is `break ()`. The other exit says the loop's value is a `u32`, and a loop
can't have two different types depending on how you leave it. The **same** "expected X, found
`()`" from Lab 02's stray semicolon: every way out of an expression must produce the same type.
Put `count` back.

---

## Step 6 — `if` as an expression, and the other loops

You've used `if` as a statement (`if bytes_read == 0 { ... }`). Like `loop` and `match`, `if`
is also an **expression**, so it replaces JS's ternary:

```rust
let word = if count == 1 { "command" } else { "commands" };
```

Both branches must produce the **same type**, for the same reason as `break` above:

```rust
let word = if count == 1 { "command" } else { 2 };
```

```text
error[E0308]: `if` and `else` have incompatible types
 --> src/main.rs:3:51
  |
3 |     let word = if count == 1 { "command" } else { 2 };
  |                                ---------          ^ expected `&str`, found integer
  |                                |
  |                                expected because of this
```

(Snippet only, so don't add it to the CRM.) An `if` *without* `else` has type `()`, so it can
only be used as a statement.

### `loop`, `while`, `for`: which one when?

| Loop | Use it when | Example |
|---|---|---|
| `loop { }` | you'll decide to stop from *inside* (and maybe return a value) | the REPL |
| `while cond { }` | there's a condition to check before each round | `while retries < 3 { ... }` |
| `for x in something { }` | you're going through each item of something | every customer in a list (Lab 05) |

```rust
for id in 1..=3 {            // a range: 1, 2, 3   (1..3 would be 1, 2)
    println!("customer #{id}");
}

let pairs = [("help", "Show this list"), ("quit", "Exit the CRM")];   // an array of tuples
for (name, description) in pairs {                                     // destructuring, like Lab 02
    println!("{name} → {description}");
}
```

Only `loop` can `break` with a value. A `while` or `for` might finish without ever hitting a
`break`, so there'd be no value to give back. `for` loops are what most Rust code uses. Index
variables (`for (let i = 0; ...)`) are rare. You'll use `for` for real in Your Turn 2 and in
Lab 05.

---

## ▶️ Run It
```bash
cargo run
```

Then type `help`, `version`, press Enter on an empty line, `demo`, `helo` (a typo), and `quit`.

## ✅ Expected Result
```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> help
Commands:
  help      Show this list
  version   Show the CRM version
  demo      Print the demo customers
  quit      Exit the CRM (also: exit)
crm> version
Rust CRM v0.1.0
crm>
crm> demo
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Grace Hopper <grace@example.com> 555-0199
Next id: 3 (4294967293 ids left)
crm> helo
Unknown command: helo. Type 'help' for a list of commands.
crm> quit
Goodbye! (3 commands this session)
```

Three commands: `help`, `version`, `demo`. The blank line, the typo and `quit` don't count.
Try it again ending with **Ctrl-D** instead of `quit`: you get a blank line, then `Goodbye!`.

> **Tip:** you can also feed the REPL a script:
> `printf 'help\nversion\nquit\n' | cargo run -q`
> (`-q` hides Cargo's own output). The typed commands won't be echoed, because the terminal
> echoes keystrokes and a pipe has none, but it's a quick way to re-run a session.

## 🧠 Understand It

**`String` vs `&str`, first contact.** `read_line` needs a buffer it can grow, so `input` is a
`String`: owned, heap-allocated, growable. `trim()` doesn't build a new `String`. It returns a
`&str` pointing *into* `input`'s buffer, skipping the whitespace. `match` compares that view
against the `&str` literals. No copies anywhere. You'll draw the memory picture for this in
Lab 06 and master slices in Lab 09. For now, remember: **`String` owns, `&str` looks.**

**Why `input` is created inside the loop.** Each iteration gets a fresh empty `String`. If you
created it once *above* the loop, `read_line` would keep **appending**, so the second command
would arrive as `"help\nversion\n"`. (Try it in the Experiment section.) Creating it inside the
loop also means it's cleaned up automatically at the end of each iteration. Lab 06 explains when
and how.

**Exhaustiveness is a feature.** The `match` forced you to say what happens for unknown input.
In Lab 11, commands become an `enum`. Then, when you add a new command, every `match` that
forgot to handle it becomes a compile error. The compiler will find the places you need to
update.

**Everything is an expression.** Blocks, `if`, `match` and `loop` all produce values, and every
path through them must produce the same type. That's the single rule behind the stray-semicolon
error (Lab 02), the `break` error, and the `if`/`else` error in this lab. Notice the mental
model: *the error messages all say "expected X, found Y" because they're all the same rule.*

**Control flow as specification.** `count += 1` placed after the `match` with `continue`/`break`
skipping it says "only completed commands count" without a single `if`.

## 🧪 Experiment
> 🟡 **EXPERIMENT 1**: comment out the `io::stdout().flush()` line in the loop and run
> `cargo run`. What do you see, and when does `crm> ` show up? Put it back afterwards.

> 🟡 **EXPERIMENT 2**: move `let mut input = String::new();` to just **above** the loop. Run it,
> type `help` and then `help` again. Explain what you see using what you know about `read_line`.
> (Change `{other}` to `{other:?}` temporarily if it helps.) Move it back.

> 🟡 **EXPERIMENT 3**: type `HELP`, then `  help  `. Which ones work and why? Is case-sensitivity
> a bug or a decision? What would you have to change to accept `HELP`?

> 🟡 **EXPERIMENT 4**: move the `other => { ... }` arm to the **top** of the `match`. What does
> the compiler say about the other arms? Move it back.

Answers are in `solutions.md`.

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — Show the build profile in `version`**
>
> In Lab 01 you saw that debug and release builds behave differently (overflow!). When someone
> reports a bug, you'll want to know which one they're running. Make the `version` command
> say so.
>
> - [ ] `cargo run`, then `version`, prints exactly `Rust CRM v0.1.0 (debug build)`
> - [ ] `cargo run --release`, then `version`, prints exactly `Rust CRM v0.1.0 (release build)`
> - [ ] The word `debug`/`release` is chosen with an **`if` used as an expression**, assigned to
>       a variable, not two separate `println!` calls
> - [ ] The startup banner is unchanged (still `Rust CRM v0.1.0`)
> - [ ] `cargo clippy` is clean, and `cargo fmt` is happy with the layout
>
> You need one fact you haven't seen yet: the expression **`cfg!(debug_assertions)`** is a
> `bool` that's `true` in a debug build and `false` in a release build. (It's the same
> setting that turns overflow checks on.)

> 🔵 **YOUR TURN 2 — A table-driven help screen**
>
> `print_help` is a list of hand-aligned `println!` calls. Adding a command means copying a
> line and counting spaces. Refactor it so the commands are **data** and the printing is a
> **loop**.
>
> - [ ] `print_help` contains **one** array of `(name, description)` tuples, one per command
> - [ ] A single `for` loop prints every row, and there's exactly one `println!` inside the loop
> - [ ] Column alignment is done by the format string, not by spaces typed into the names
> - [ ] The output is **byte-for-byte identical** to the current help output (this is a refactor):
>
> ```text
> Commands:
>   help      Show this list
>   version   Show the CRM version
>   demo      Print the demo customers
>   quit      Exit the CRM (also: exit)
> ```
>
> - [ ] Adding a command to the help is now a one-line change (you'll do exactly that in Lab 05)

## 💡 Hint
> 💡 **HINT**: Your Turn 1: `let x = if condition { "a" } else { "b" };` and then use `{x}` in
> the format string. Your Turn 2: look at the `pairs` example in Step 6, then find out how to
> pad a value to a fixed width in a format string (search the `std::fmt` docs for "width").

<details><summary>Hint 2 (more specific)</summary>

Your Turn 1: the arm becomes a block, `"version" => { ... }`, with a `let` and a `println!`
inside. `cargo fmt` will spread the `if` over several lines, and that's fine.

Your Turn 2: `{name:<10}` means "format `name`, left-aligned, padded with spaces to 10
characters". Count the columns in the current help: two spaces, then the name padded to 10,
then the description.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking at the code:
1. Why does `match input { "help" => ... }` fail to compile when `input` is a `String`?
   What's the difference between `String` and `&str` in one sentence each?
2. Why does `match` on a `&str` need a catch-all arm, when a `match` on a `bool` wouldn't?
3. How does the REPL detect end of input, and what went wrong before we handled it?
4. Why can `loop` produce a value with `break`, but `while` and `for` can't?
5. Trace the session `help`, `<Enter>`, `oops`, `version`, `quit`: what's `count` after each
   line, and what does the goodbye message say?
6. Why is `input` declared *inside* the loop?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo run
```

## Git Commit
```bash
git add .
git commit -m "Add interactive command loop"
git tag lab-03
git push && git push --tags
```

**Next:** [Lab 04 — Structs & Methods](../04-structs-and-methods/README.md): Ada and Grace stop
being four loose variables each and become real `Customer` values.

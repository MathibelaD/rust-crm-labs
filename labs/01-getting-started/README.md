# Lab 01 — Getting Started

> **Phase:** 0 — Toolchain & Workflow · **Builds on:** nothing (this is where it starts) · **Time:** ~2 hours
> **Your repo before this lab:** doesn't exist yet · **After:** tag `lab-01`

## 🎯 Goal
Install Rust, create **your** `rust-crm` project with Cargo, make it print a version banner,
and push it to GitHub with your first commit and your first tag.

## 🧠 What You'll Learn
- What `rustup`, `rustc` and `cargo` each do, and what a *toolchain* is
- Installing Rust on macOS, keeping it up to date, and reading the offline docs
- Setting up VS Code with **rust-analyzer**
- What `cargo new` generates, line by line (including the Git repository it creates for you)
- `cargo check` vs `cargo build` vs `cargo run`, debug vs `--release`, the `target/` folder, `Cargo.lock`
- `cargo fmt` (the formatter) and `cargo clippy` (the linter)
- Reading your first compiler errors
- The Git ritual you'll repeat at the end of every lab, and **why each lab gets a tag**

## 🔨 What We're Building
Nothing impressive yet: a program that prints

```text
Rust CRM v0.1.0
```

But the version number comes from `Cargo.toml`, not from a string you typed. The banner
stays in the CRM for the rest of the course, and every lab after this one adds to this
project. By the end of the lab your project is on GitHub, tagged `lab-01`.

### Two repositories, two roles

Before you type anything, get this picture straight. It's how the whole course works.

```text
rust-crm-labs/   ← THE TEACHER. You're reading it now. Instructions, hints, solutions.
                   You never write CRM code in here.

rust-crm/        ← THE STUDENT PROJECT. Yours. You create it in this lab, on your machine
                   and on your GitHub account. Every line in it is typed by you.
```

Keep them in two separate windows: this lab on one side, your editor and terminal on the
other. There's no finished CRM hidden anywhere in this repository. The only CRM that will
ever exist is the one you build.

---

## Step 1 — Know your tools before you install them

Three programs make up a Rust installation. You'll run all three in this lab.

| Tool | What it is | JS/TS analogy (roughly) |
|---|---|---|
| `rustup` | The **toolchain manager**. Installs, updates and switches Rust versions. | `nvm` / `fnm` |
| `rustc` | The **compiler**. Turns `.rs` files into a native executable. | `tsc`, but it produces machine code |
| `cargo` | The **build tool and package manager**. Creates projects, calls `rustc`, downloads dependencies, runs tests. | `npm` + a bundler + a test runner in one |

You'll rarely call `rustc` yourself. Cargo calls it for you with the right flags.

**A toolchain** is one complete, matching set: `rustc` + `cargo` + the standard library +
components like `clippy` and `rustfmt`, all at the same version. There are three release
*channels*:

- **stable**: a new release every six weeks. This course uses stable only.
- **beta**: the next stable, for testing.
- **nightly**: built every night. Some experimental features only exist here. You don't need it.

`rustup` can keep several toolchains installed side by side and pick one per project. You'll
install exactly one: **stable**.

> **Why does this matter?** Rust ships a new stable every six weeks and never breaks code
> that compiled on an older stable within the same *edition*. "Update often" is the normal
> Rust habit, unlike pinning an old Node version for years.

---

## Step 2 — Install the Xcode Command Line Tools

Rust compiles your code itself, but on macOS it hands the final step (*linking* the pieces
into one executable) to Apple's system linker. That linker comes with the Xcode Command Line
Tools, which also give you `git`.

> 🟢 **FOLLOW ALONG**

```bash
xcode-select --install
```

- A dialog opens: click **Install**. It takes a few minutes.
- If it says `command line tools are already installed`, you're done.

Check that git is there:

```bash
git --version
```

```text
git version 2.39.3 (Apple Git-146)
```

(Any version is fine.)

> If you skip this step, Rust may install fine and then fail on your first `cargo build` with
> a `linker 'cc' not found` error. Now you know why.

---

## Step 3 — Install Rust with rustup

The official installer is a shell script from `rustup.rs`. It installs into your **home
directory** (no `sudo`). Nothing goes into system folders.

> 🟢 **FOLLOW ALONG**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

What the flags mean, so you're not piping a mystery into `sh`:

- `--proto '=https'`: only allow HTTPS, never plain HTTP
- `--tlsv1.2`: require modern TLS
- `-sSf`: silent, but still **S**how errors, and **f**ail on HTTP errors instead of piping an error page into `sh`

The installer prints where it'll put things and asks:

```text
1) Proceed with standard installation (default - just press enter)
2) Customize installation
3) Cancel installation
```

Press **Enter** for option 1. That installs the **stable** toolchain with the default profile,
which includes `rustc`, `cargo`, the standard library, `rustfmt`, `clippy` and the offline docs.

Where things go:

```text
~/.rustup/   ← the toolchains themselves (managed by rustup; don't edit)
~/.cargo/    ← cargo's home: ~/.cargo/bin holds the rustc, cargo, rustup commands
```

### Make the commands visible in this terminal

The installer adds `~/.cargo/bin` to your `PATH` by editing your shell startup files (for zsh,
`~/.zshenv`). **New** terminal windows pick that up automatically. The terminal you're in right
now started before the edit, so load it by hand:

> 🟢 **FOLLOW ALONG**

```bash
source "$HOME/.cargo/env"
```

`~/.cargo/env` is a tiny script that adds `~/.cargo/bin` to `PATH` if it isn't there already.

### Verify

```bash
rustc --version
cargo --version
rustup --version
```

```text
rustc 1.99.0 (b940084d7 2026-09-28)
cargo 1.99.0 (5f94df478 2026-08-27)
rustup 1.29.1 (d95a37b6a 2026-08-13)
info: This is the version for the rustup toolchain manager, not the rustc compiler.
info: the currently active `rustc` version is `rustc 1.99.0 (b940084d7 2026-09-28)`
```

Your numbers will be different, and that's fine. This course uses **edition 2024**, which needs
Rust **1.85 or newer**. The labs were verified with Rust 1.99.

> 🟡 **EXPERIMENT**: run `which cargo`. Predict the answer first. (It should be inside your
> home directory. If it's `/opt/homebrew/bin/cargo`, you also have a Homebrew Rust installed,
> which will fight with rustup. Run `brew uninstall rust` and open a new terminal.)

---

## Step 4 — Get to know rustup

You'll only need these occasionally, but you should know they exist.

> 🟢 **FOLLOW ALONG**

```bash
rustup show
```

```text
Default host: aarch64-apple-darwin
rustup home:  /Users/you/.rustup

installed toolchains
--------------------
stable-aarch64-apple-darwin (active, default)

active toolchain
----------------
name: stable-aarch64-apple-darwin
active because: it's the default toolchain
installed targets:
  aarch64-apple-darwin
```

Read it as: *"Your machine is an Apple Silicon Mac (`aarch64-apple-darwin`). You have one
toolchain, stable, and it's the default."* On an Intel Mac you'll see `x86_64-apple-darwin`.

| Command | What it does | When you'll use it |
|---|---|---|
| `rustup update` | Downloads the newest stable (and updates rustup itself) | Every few weeks |
| `rustup doc` | Opens the **offline** documentation in your browser | Any time, even on a plane |
| `rustup doc --book` | Opens *The Rust Programming Language* book offline | Great companion reading |
| `rustup doc --std` | Opens the standard library API docs | Constantly, from Lab 05 on |
| `rustup component list --installed` | Shows installed components (look for `clippy`, `rustfmt`) | When a tool seems missing |
| `rustup toolchain list` | Lists installed toolchains | Rarely |

> 🟢 **FOLLOW ALONG**: run `rustup doc --std` now and type `Vec` into its search box. Leave the
> tab open; you'll be there a lot.

---

## Step 5 — Set up VS Code with rust-analyzer

Any editor works, but this course assumes **VS Code** with the official **rust-analyzer**
extension. rust-analyzer is the Rust *language server*: it runs the compiler's analysis as you
type, so you see errors, types and documentation inline.

> 🟢 **FOLLOW ALONG**

1. Install VS Code from <https://code.visualstudio.com> if you don't have it.
2. Open the Extensions view (`⇧⌘X`), search for **rust-analyzer** and install the one
   published by **The Rust Programming Language** (rust-lang). Don't install the old,
   deprecated extension simply named "Rust".
3. Optional but useful: **Even Better TOML** (syntax highlighting for `Cargo.toml`).
4. Make `code` available in your terminal: open the Command Palette (`⇧⌘P`), run
   **Shell Command: Install 'code' command in PATH**.
5. Turn on format-on-save, and make the editor use Clippy's checks instead of the basic
   ones. Open the Command Palette → **Preferences: Open User Settings (JSON)** and add:

```json
{
  "editor.formatOnSave": true,
  "rust-analyzer.check.command": "clippy"
}
```

You'll see what both of those do in Steps 10 and 11.

> **Note:** rust-analyzer only works when you open the **project folder** (the one containing
> `Cargo.toml`), not a single `.rs` file and not its parent folder. "rust-analyzer isn't doing
> anything" almost always means the wrong folder is open.

---

## Step 6 — Create the project with `cargo new`

Pick a folder for your projects. This course assumes `~/code`, but any folder works. Just
**not** inside `rust-crm-labs`: your CRM is its own repository.

> 🟢 **FOLLOW ALONG**

```bash
mkdir -p ~/code
cd ~/code
cargo new rust-crm
cd rust-crm
```

```text
    Creating binary (application) `rust-crm` package
note: see more `Cargo.toml` keys and their definitions at https://doc.rust-lang.org/cargo/reference/manifest.html
```

"Binary (application)" means a program you can run, with a `main` function. (The other kind
of package is a *library*. You'll add a library to this same package in Lab 13.)

Look at what you got:

```bash
ls -a
```

```text
.		..		.git		.gitignore	Cargo.toml	src
```

```text
rust-crm/
├── .git/          ← cargo new already ran `git init` for you
├── .gitignore     ← contains one line: /target
├── Cargo.toml     ← the manifest: name, version, edition, dependencies
└── src/
    └── main.rs    ← the program's entry point
```

Two things to notice:

1. **`.git/` already exists.** `cargo new` creates a Git repository unless you're already
   inside one (or pass `--vcs none`). Don't run `git init` again.
2. **`.gitignore` contains `/target`.** `target/` is where compiled output goes (Step 9).
   It's large and regenerated on every build, so it never belongs in Git.

Depending on your Git version and settings, the new repository's branch may be called
`master`. GitHub uses `main`, so rename it now, before there are any commits:

```bash
git branch -M main
git status
```

```text
On branch main

No commits yet

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	.gitignore
	Cargo.toml
	src/

nothing added to commit but untracked files present (use "git add" to track)
```

Now open the project in VS Code:

```bash
code .
```

---

## Step 7 — Read Cargo.toml line by line

> 🟢 **FOLLOW ALONG**: open `Cargo.toml`.

```toml
[package]
name = "rust-crm"
version = "0.1.0"
edition = "2024"

[dependencies]
```

| Line | Meaning |
|---|---|
| `[package]` | A TOML *table*: everything below describes this package, up to the next `[...]` header. |
| `name = "rust-crm"` | The package name. It's also the name of the executable (`target/debug/rust-crm`). When Rust code refers to the crate, the `-` becomes `_` (`rust_crm`), because `-` isn't valid in Rust identifiers. You'll see that in Lab 13. |
| `version = "0.1.0"` | Your package's version, in [semantic versioning](https://semver.org) (`MAJOR.MINOR.PATCH`). The banner you write in Step 8 reads this value. |
| `edition = "2024"` | Which **edition** of the language this crate uses. Editions (2015, 2018, 2021, 2024) let Rust make small breaking changes to syntax and defaults without breaking old code: each crate declares its edition, and crates of different editions work together. Edition is **not** the compiler version. Rust 1.99 compiles all four editions. |
| `[dependencies]` | External crates (libraries) from [crates.io](https://crates.io). Empty for now. Your first dependency arrives in Lab 20 with `cargo add`, and that's when you'll learn about versions, features and `cargo tree`. |

Unlike `package.json`, there's no `scripts` section. Cargo's commands (`build`, `run`, `test`,
`fmt`, `clippy`) are the same in every Rust project, so there's nothing to configure.

---

## Step 8 — Write the banner

> 🟢 **FOLLOW ALONG**: here's what `cargo new` put in `src/main.rs`:

```rust
fn main() {
    println!("Hello, world!");
}
```

- `fn main()` is where the program starts. It takes no arguments and returns nothing.
- `println!` prints a line. The `!` means it's a **macro**, not a function. Macros are
  expanded at compile time into ordinary code. `println!` is a macro because it checks your
  format string *at compile time*: the number of `{}` placeholders must match the number of
  arguments, and that's checked before your program runs.
- Statements end with `;`.
- Indentation is four spaces. Nobody argues about it, because `cargo fmt` decides (Step 10).

Replace the whole file with:

```rust
fn main() {
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
}
```

- `{}` is a placeholder. The next argument is formatted into it.
- `env!("CARGO_PKG_VERSION")` is another macro. It reads an **environment variable at compile
  time** and pastes its value into your program as a string literal. Cargo sets
  `CARGO_PKG_VERSION` (and `CARGO_PKG_NAME`, and several others) from `Cargo.toml` whenever it
  calls the compiler.

So this line is effectively compiled as `println!("Rust CRM v{}", "0.1.0");`. The version is
baked into the executable. Bump `version` in `Cargo.toml`, rebuild, and the banner follows
on its own, with one source of truth and nothing to keep in sync by hand.

---

## Step 9 — check, build, run, release

Cargo has three commands you'll use constantly. They do different amounts of work.

```text
cargo check   →  parse + type-check + borrow-check            (no executable produced)
cargo build   →  everything check does + generate machine code + link  → target/debug/rust-crm
cargo run     →  cargo build, then run the executable
```

> 🟢 **FOLLOW ALONG**

```bash
cargo check
```

```text
    Checking rust-crm v0.1.0 (/Users/you/code/rust-crm)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.02s
```

`cargo check` answers *"is my code valid Rust?"* as fast as possible. It skips the slowest part
of compilation, generating machine code. It's the command you'll run hundreds of times: change
something, `cargo check`, read what the compiler says, repeat. Think of it as your conversation
with the compiler.

```bash
cargo build
```

```text
   Compiling rust-crm v0.1.0 (/Users/you/code/rust-crm)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.07s
```

```bash
cargo run
```

```text
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.00s
     Running `target/debug/rust-crm`
Rust CRM v0.1.0
```

Notice that `cargo run` didn't print `Compiling`. Nothing changed since the last build, so Cargo
reused it. Cargo only recompiles what changed.

The executable is a normal native program. You can run it without Cargo:

```bash
./target/debug/rust-crm
```

```text
Rust CRM v0.1.0
```

No runtime, no interpreter, no `node_modules`. Copy that one file to another Mac with the same
CPU type and it runs.

### Debug vs release

```bash
cargo run --release
```

```text
   Compiling rust-crm v0.1.0 (/Users/you/code/rust-crm)
    Finished `release` profile [optimized] target(s) in 0.46s
     Running `target/release/rust-crm`
Rust CRM v0.1.0
```

| | `dev` profile (default) | `release` profile (`--release`) |
|---|---|---|
| Optimisations | none, so it compiles fast | full, so it compiles slower and runs much faster |
| Debug info | yes | no |
| Integer overflow | **panics** (crashes with a message) | wraps around silently |
| Output | `target/debug/` | `target/release/` |
| Use it for | everyday development | benchmarks, shipping (Lab 40) |

The overflow row will make sense in Lab 02, where you'll see it happen.

### What's in `target/` and `Cargo.lock`?

```bash
ls
ls target
```

```text
Cargo.lock	Cargo.toml	src		target
CACHEDIR.TAG	debug		release
```

- **`target/`** holds all build output: the executables, plus intermediate files Cargo reuses
  for incremental builds. It's safe to delete at any time (`cargo clean` does exactly that),
  and the next build regenerates it. That's why `.gitignore` excludes it.
- **`Cargo.lock`** appeared on your first build. It records the **exact** version of every
  dependency that was used, so every machine builds the same thing. Right now it only lists
  your own package. It's the equivalent of `package-lock.json`, and for an **application** like
  this CRM you **commit it**. You'll see it do real work in Lab 20.

---

## Step 10 — `cargo fmt`: never discuss formatting again

`rustfmt` is the official formatter, and `cargo fmt` runs it on your whole project. The Rust
community uses it nearly universally, so Rust code looks the same everywhere.

> 🟡 **EXPERIMENT**: make `main.rs` deliberately ugly and add a second line while you're at it:

```rust
fn main()
{
        println!( "Rust CRM v{}",env!("CARGO_PKG_VERSION") );
  println!("Package: {}",   env!("CARGO_PKG_NAME"));
}
```

(If format-on-save is enabled, VS Code will fix it the moment you save. To watch `cargo fmt`
do it instead, save with `⌘K S`, "save without formatting".)

Ask whether the file is formatted, *without* changing it:

```bash
cargo fmt --check
```

```text
Diff in /Users/you/code/rust-crm/src/main.rs:1:
-fn main()
-{
-        println!( "Rust CRM v{}",env!("CARGO_PKG_VERSION") );
-  println!("Package: {}",   env!("CARGO_PKG_NAME"));
+fn main() {
+    println!("Rust CRM v{}", env!("CARGO_PKG_VERSION"));
+    println!("Package: {}", env!("CARGO_PKG_NAME"));
 }
 
```

`--check` prints the diff and exits with an error code, which makes it useful in CI (Lab 24).
Now fix it for real:

```bash
cargo fmt
cargo run
```

```text
Rust CRM v0.1.0
Package: rust-crm
```

Keep the `Package:` line for now. You'll use it in Your Turn 1.

---

## Step 11 — `cargo clippy`: your code reviewer

Clippy is the official **linter**: hundreds of checks for code that compiles but is
unidiomatic, slower than it needs to be, or likely wrong. Every warning names a lint and links
to an explanation. From now on, every lab ends with `cargo clippy` clean.

> 🟡 **EXPERIMENT**: add this line at the end of `main` and predict whether it compiles:

```rust
    println!("{}", "Type 'help' for a list of commands.");
```

It does compile. `cargo run` prints the line. Now ask Clippy:

```bash
cargo clippy
```

```text
    Checking rust-crm v0.1.0 (/Users/you/code/rust-crm)
warning: literal with an empty format string
 --> src/main.rs:3:20
  |
3 |     println!("{}", "Type 'help' for a list of commands.");
  |                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  |
  = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.99.0/index.html#print_literal
  = note: `#[warn(clippy::print_literal)]` on by default
help: try
  |
3 -     println!("{}", "Type 'help' for a list of commands.");
3 +     println!("Type 'help' for a list of commands.");
  |
```

How to read a Clippy warning (compiler errors use the same layout):

1. **The headline**: `literal with an empty format string`. That's the problem.
2. **The location**: `src/main.rs:3:20` (file, line, column) with the code underlined by `^^^`.
3. **The lint name**: `clippy::print_literal`. Open the link to read *why* it's a lint.
4. **The fix**: `help: try` shows a diff, `-` for the old line and `+` for the new one.

Apply the fix by hand, run `cargo clippy` again and confirm the warning is gone. Then
**delete that line entirely**. The real "Type 'help'" line arrives in Lab 03.

> Because you set `"rust-analyzer.check.command": "clippy"` in Step 5, VS Code now shows Clippy
> warnings as yellow squiggles while you type. Hover one to see the same message.

---

## Step 12 — Your first compiler errors

Compiler errors are information, not punishment. Rust's errors are famously good, so get used
to *reading the whole thing*.

> 🟡 **EXPERIMENT**: misspell the variable name. Predict: compile error or runtime error?

```rust
    println!("Rust CRM v{}", env!("CARGO_PKG_VERSOIN"));
```

```bash
cargo check
```

```text
error: environment variable `CARGO_PKG_VERSOIN` not defined at compile time
 --> src/main.rs:2:30
  |
2 |     println!("Rust CRM v{}", env!("CARGO_PKG_VERSOIN"));
  |                              ^^^^^^^^^^^^^^^^^^^^^^^^^
  |
  = help: there is a similar Cargo environment variable: `CARGO_PKG_VERSION`

error: could not compile `rust-crm` (bin "rust-crm") due to 1 previous error
```

It's a **compile** error, because `env!` runs at compile time. In JavaScript,
`process.env.CARGO_PKG_VERSOIN` would quietly be `undefined` when the program runs. Here the
mistake can't reach a running program. Notice the `help:` line: the compiler suggests the name
you probably meant.

> 🟡 **EXPERIMENT**: fix the name, then remove the argument instead:

```rust
    println!("Rust CRM v{}");
```

```text
error: 1 positional argument in format string, but no arguments were given
 --> src/main.rs:2:25
  |
2 |     println!("Rust CRM v{}");
  |                         ^^
```

That's the "macros check your format string at compile time" from Step 8, happening for real.
Put the argument back.

---

## Step 13 — Create the GitHub repository

Your CRM lives on GitHub from day one. Create an **empty** repository called `rust-crm`. Choose
**one** of the two options below.

### Option A — with the GitHub CLI (`gh`)

> 🟢 **FOLLOW ALONG**

```bash
brew install gh          # if you don't have it (needs Homebrew: https://brew.sh)
gh auth login            # choose GitHub.com → HTTPS → log in with a web browser
gh repo create rust-crm --public --description "A CRM built while learning Rust"
```

`gh` prints the new repository's URL, for example `https://github.com/<you>/rust-crm`. Connect
your local repository to it:

```bash
git remote add origin https://github.com/<you>/rust-crm.git
```

(Replace `<you>` with your GitHub username.) Use `--private` instead of `--public` if you
prefer, since nothing in the course depends on it.

### Option B — on github.com

1. Go to <https://github.com/new>.
2. Repository name: `rust-crm`. Public or private, as you like.
3. **Leave every "Initialize this repository with…" option unchecked**: no README, no
   `.gitignore`, no license. Your local repository already has a `.gitignore` and is about to
   have the first commit. If GitHub creates a commit too, the two histories won't match and
   your first push will be rejected.
4. Click **Create repository**, then in your terminal:

```bash
git remote add origin https://github.com/<you>/rust-crm.git
```

### Check the remote

```bash
git remote -v
```

```text
origin	https://github.com/<you>/rust-crm.git (fetch)
origin	https://github.com/<you>/rust-crm.git (push)
```

Nothing is pushed yet. That happens in **Git Commit** at the end of the lab.

If you've never used Git on this Mac, tell it who you are (this appears on every commit):

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

---

## Step 14 — The Git ritual, and why every lab gets a tag

Every lab in this course ends the same way:

```bash
git add .
git commit -m "<message the lab suggests>"
git tag lab-NN
git push && git push --tags
```

You already know commits. The **tag** is the new part. A tag is a permanent, human-readable
name for one specific commit. `lab-07` will always mean *"my CRM exactly as it was when I
finished Lab 07"*, even after a hundred more commits.

This pays off because the CRM gets **deliberately refactored** several times (the ♻️ labs in
the roadmap). When you finish Lab 08, you'll be able to run:

```bash
git diff lab-07 lab-08            # exactly what the borrow-checker refactor changed
git diff lab-12 lab-13 --stat     # which files the module split touched
git log --oneline lab-05..lab-10  # every commit you made during Phase 2
git checkout lab-04               # time-travel to look at an old version (then: git switch main)
```

Without tags you'd be hunting for commit hashes. With them, your history reads like a
table of contents of how you learned Rust.

Commit more often than once per lab. A commit whenever something works is a good habit, and
some labs suggest two or three. The **tag** goes on the last commit of the lab.

---

## ▶️ Run It
Make sure `src/main.rs` contains the banner line and (for now) the `Package:` line from Step 10,
then:

```bash
cargo fmt --check && cargo clippy && cargo run
```

`&&` runs the next command only if the previous one succeeded, so this one line says "formatted,
lint-clean, and it runs". You'll use a version of it at the end of every lab.

## ✅ Expected Result
```text
    Checking rust-crm v0.1.0 (/Users/you/code/rust-crm)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.05s
   Compiling rust-crm v0.1.0 (/Users/you/code/rust-crm)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.14s
     Running `target/debug/rust-crm`
Rust CRM v0.1.0
Package: rust-crm
```

No output from `cargo fmt --check` means the formatting is already correct, and no warnings
from `cargo clippy` means you're lint-clean. Your paths and timings will differ.

## 🧠 Understand It

**The build pipeline.** When you run `cargo run`, Cargo:

1. reads `Cargo.toml` and resolves dependencies (none yet), writing `Cargo.lock`;
2. calls `rustc` on `src/main.rs`, setting environment variables like `CARGO_PKG_VERSION`;
3. `rustc` expands macros (`println!`, `env!`), type-checks, borrow-checks, optimises (if
   `--release`), and generates machine code;
4. the system linker (from the Xcode tools) produces `target/debug/rust-crm`;
5. Cargo runs it.

`cargo check` stops after the checking part of step 3, which is why it's so fast. Almost
every error you'll meet in this course is caught there.

**Compile time vs run time.** In JS/TS a lot is decided while the program runs. Rust moves as
much as possible to compile time: the version string, the format-string check, the misspelled
variable. That's the habit to build: *if the compiler can catch it, let it.* The whole
ownership system in Phase 2 is that same idea, applied to memory.

**Why `env!` and not a hard-coded `"0.1.0"`?** One source of truth. The version lives in
`Cargo.toml`, the file tools like `cargo publish` and CI read. The banner can't drift out of
date.

**Three layers of feedback.** You now have three tools, and each one catches different things:

| Tool | Catches | Example |
|---|---|---|
| `rustc` (via `cargo check`) | Code that isn't valid Rust | misspelled `env!` variable |
| `cargo clippy` | Valid code that's unidiomatic or suspicious | `println!("{}", "literal")` |
| `cargo fmt` | Inconsistent layout | the ugly `main` from Step 10 |

## 🧪 Experiment
> 🟡 **EXPERIMENT**: change `version = "0.1.0"` to `version = "0.2.0"` in `Cargo.toml`, then run
> `cargo run`. Before you run it, predict: will Cargo recompile even though `main.rs` didn't
> change? What will the banner say?

Run it and compare with your prediction. Then answer: *why* does Cargo have to recompile when
only `Cargo.toml` changed? (Think about *when* `env!` reads its value.) **Set the version back
to `0.1.0` afterwards.**

> 🟡 **EXPERIMENT**: delete the whole `target/` folder (`rm -rf target`, or `cargo clean`) and
> run `cargo run` again. What happens, and what does that tell you about whether `target/`
> belongs in Git?

> 🟡 **EXPERIMENT**: run `ls -lh target/debug/rust-crm target/release/rust-crm`. Both are
> roughly 400–500 KB for a one-line program. Where do you think that size comes from, given
> there's no runtime to bundle? (Answer in `solutions.md`.)

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1 — A package line with a description**
>
> Cargo can describe a package, not just name it. Add a **description** to your package and
> print it next to the package name.
>
> - [ ] `Cargo.toml` has a `description` key in the `[package]` table with the text
>       `A CRM built while learning Rust`
> - [ ] The `Package:` line from Step 10 now prints **exactly**:
>       `Package: rust-crm (A CRM built while learning Rust)`
> - [ ] Neither the name nor the description is typed into `main.rs`; both come from
>       Cargo at compile time
> - [ ] `cargo fmt --check` and `cargo clippy` are both clean
>
> When it works, **delete the `Package:` line from `main.rs`** so the program prints only the
> banner. (Keep the `description` in `Cargo.toml`; it's harmless and useful.) Lab 02 starts
> from a banner-only `main.rs`.

> 🔵 **YOUR TURN 2 — Make Clippy complain, then make it happy**
>
> Learn to *read* Clippy by provoking it on purpose with code you write yourself.
>
> - [ ] Write a small function of your own (for example one that returns the banner text or
>       the version) and call it from `main`, written so that `cargo clippy` reports **at least
>       one warning that isn't `print_literal`**
> - [ ] From the warning, write down: the lint's name, the file/line/column, and one sentence on
>       *why* the lint exists (from the linked page)
> - [ ] Fix the code so `cargo clippy` is clean, **without** turning the lint off
> - [ ] Finally restore `src/main.rs` to exactly the three-line banner program from Step 8
>       and confirm `cargo run` prints only `Rust CRM v0.1.0`

## 💡 Hint
> 💡 **HINT**: For Your Turn 1, look at the list of environment variables Cargo sets when it
> compiles your crate. Search for "Environment variables Cargo sets for crates" in the Cargo
> book (it's in `rustup doc` too: open the Cargo book from the start page).

<details><summary>Hint 2 (more specific)</summary>

Your Turn 1: the variable you want is named like `CARGO_PKG_VERSION` and `CARGO_PKG_NAME`. You
can pass more than one argument to `println!`: one `{}` per argument, in order. If `cargo fmt`
splits your `println!` over several lines, that's fine.

Your Turn 2: a classic Clippy target is a function that ends with `return something;`. Rust
functions return their last expression without `return`, which you'll properly learn in
Lab 02.

</details>

## 🆘 Solution
> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint
Answer without looking back:
1. What's the difference between `rustup`, `rustc` and `cargo`? Which one would you use to get
   the newest Rust?
2. Why is `cargo check` faster than `cargo build`, and when is `check` not enough?
3. `env!("CARGO_PKG_VERSION")`: when is the value read, at compile time or at run time? How do
   you know?
4. Which of these belong in Git: `Cargo.toml`, `Cargo.lock`, `target/`, `src/main.rs`? Why
   is the odd one out excluded?
5. What does `edition = "2024"` mean, and why is it **not** the same thing as the compiler version?
6. Why does every lab end with a tag, and what would `git diff lab-07 lab-08` show you?

Then verify that `src/main.rs` is back to the banner only:

```bash
cargo fmt --check && cargo clippy && cargo run
```

```text
Rust CRM v0.1.0
```

## Git Commit
This is your first commit, so the first push also connects your local `main` branch to
GitHub's (`-u` = "set upstream"). After this, plain `git push` is enough.

```bash
git add .
git status                      # check: Cargo.toml, Cargo.lock, .gitignore, src/main.rs — and NO target/
git commit -m "Initialize Rust CRM"
git push -u origin main
git tag lab-01
git push --tags
```

From Lab 02 on, the ritual is the short version:

```bash
git add .
git commit -m "..."
git tag lab-NN
git push && git push --tags
```

Open `https://github.com/<you>/rust-crm`: you should see your files, one commit, and under
**Tags** (in the branch dropdown, or at `/tags`), `lab-01`.

**Next:** [Lab 02 — Variables, Types & Functions](../02-variables-types-functions/README.md),
where the CRM gets its first customer.

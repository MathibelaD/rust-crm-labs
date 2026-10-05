# Lab 10 — Lifetimes

> **Phase:** 2 — Ownership & Borrowing · **Builds on:** Lab 09 · **Time:** ~4–5 hours
> **Your repo before this lab:** tag `lab-09` · **After:** tag `lab-10`

> This lab assumes you completed **Your Turns 1–3 in Lab 09** (`email_domain`, UTF-8-safe
> `initials`, `page` + `list [page]`). If you skipped any, copy them from
> [Lab 09's solutions.md](../09-slices-and-strings/solutions.md) first.

## 🎯 Goal

Add a `search <term>` command whose results are **borrowed** from the store, and turn the
parser's tuple into a struct that borrows the input line: `ParsedCommand<'a>`. Along the way,
learn to read, write and *explain* every lifetime in your code.

## 🧠 What You'll Learn

- What a lifetime **is**: a region of code during which a borrow must stay valid
- Why annotations *describe* relationships and never change how long anything lives
- The two checks the compiler makes: inside the function, and at every call site
- The three **elision rules**, applied to your own CRM signatures
- Structs that hold references (`ParsedCommand<'a>`) and the `'_` placeholder
- E0106 (missing lifetime specifier), E0597 (does not live long enough), E0716 (temporary
  dropped while borrowed), and how to reason through each
- `'static`: what `&'static str` means, and why `T: 'static` does **not** mean "lives forever"
- A practical rule for choosing **owned vs borrowed** struct fields

## 🔨 What We're Building

```text
crm> search ada
#1 Ada Lovelace <ada@example.com> 555-0100
crm> search EXAMPLE
#1 Ada Lovelace <ada@example.com> 555-0100
#3 Charles Babbage <charles@EXAMPLE.com> 555-0111
```

The interesting part is the signature:

```rust
fn search<'a>(&'a self, term: &str) -> Vec<&'a Customer>
```

By the end of this lab you'll be able to read it out loud: *"the customers in the result are
borrowed from the store, not from the search term, so they stay valid as long as the store is
borrowed, and the term can be thrown away as soon as the call returns."* And you'll know why
getting that sentence wrong produces a compiler error in *someone else's* code.

You've actually been relying on lifetimes since Lab 07. Every `Option<&Customer>` returned by
`find` has one. You just haven't had to write them yet.

---

## Step 1 — The mental model

Forget syntax for a moment. Here are the ideas everything else in this lab rests on.

**1. Values have scopes. References have lifetimes.**
A value (an owner) exists from the `let` that creates it until it's dropped. A reference exists
from where it's created until its **last use**. A lifetime is the region of code where a
borrow is in use, and therefore where the thing it points to must still be alive.

**2. The one rule:** a borrow's lifetime must fit inside the owner's scope.

Here's your own command loop from Lab 09, with both drawn in:

```text
loop {                                                    input's scope
    let mut input = String::new();                        ┐
    io::stdin().read_line(&mut input) ...;                │
    let (command, args) = parse_input(&input);   ┐        │
                                                 │ borrow │
    match command {                              │ of     │
        "show" => match parse_id(&args) { ... }  │ input  │
        ...                                      │        │
    }                                            ┘ last   │
    count += 1;                                    use    │
}                                                         ┘ input dropped
```

The borrow fits inside `input`'s scope, so it compiles. Every lifetime error you'll ever see is
a picture where the bracket on the left sticks out past the bracket on the right.

**3. A lifetime is not a timer, and annotations don't change anything at runtime.**
`'a` doesn't make anything live longer or shorter. Values are dropped where they've always been
dropped (end of scope, or when moved). An annotation like `'a` is a **name for a region**, used to
say how regions *relate*: "the output borrows from this input, so it can't outlive it".

**4. The compiler checks two sides of every signature.**

```text
                 fn email_domain<'a>(email: &'a str) -> Option<&'a str>
                                  ▲                            ▲
   Inside the function:  "do you only return things borrowed from `email`?"  (callee keeps the promise)
   At every call site:   "is the owner of `email` alive wherever you use the result?"  (caller keeps the promise)
```

You've hit both already. Lab 09's **E0515** (`cannot return value referencing local variable
lowered`) was the *inside* check failing: the body tried to return a borrow of something that
wasn't an input. Lab 09's **E0502** after `input.clear()` was the *call-site* check: the result of
`parse_input` was still in use, so `input` was still borrowed.

**5. The caller picks the region; the function only states relationships.**
A lifetime parameter `'a` is like a generic type parameter `T`: the function doesn't choose it.
Each call site gets its own `'a`, as short as possible while still covering every use of the
result. That's why the same `find` can return a borrow that lasts one line in one place and a
whole loop iteration in another.

> If you come from JavaScript: there, an object stays alive as long as *anything* references it,
> and the garbage collector works that out at runtime. Rust flips it around. References must
> never outlive their owner, and the compiler proves that before the program runs. No GC, no
> runtime cost, and no dangling pointers.

---

## Step 2 — You've been using lifetimes all along: elision

`parse_input` returns three references, yet you never wrote a lifetime. Rust inferred them with
three mechanical rules called **lifetime elision**. They only look at the *signature*, never at the
body:

| Rule | What it says |
|---|---|
| **1** | Every reference in the **inputs** that has no lifetime written gets its own, different one. |
| **2** | If there is **exactly one** input lifetime, every reference in the **output** gets it. |
| **3** | If one of the inputs is `&self` or `&mut self`, every reference in the output gets **self's** lifetime. |

If the output contains a reference and none of these rules applies, the compiler stops and asks
you (E0106). That's it. No guessing beyond these three rules.

Here they are applied to your CRM. Left column: what you wrote. Right column: what the compiler
reads.

| You wrote | After elision | Rule |
|---|---|---|
| `fn prompt(label: &str) -> String` | `fn prompt<'a>(label: &'a str) -> String` | 1 (no output reference, nothing more to do) |
| `fn email_domain(email: &str) -> Option<&str>` | `fn email_domain<'a>(email: &'a str) -> Option<&'a str>` | 1, 2 |
| `fn parse_input(input: &str) -> (&str, Vec<&str>)` | `fn parse_input<'a>(input: &'a str) -> (&'a str, Vec<&'a str>)` | 1, 2 |
| `fn parse_id(args: &[&str]) -> Option<u32>` | `fn parse_id<'a, 'b>(args: &'a [&'b str]) -> Option<u32>` | 1 (two input references, two lifetimes) |
| `fn email_exists(&self, email: &str) -> bool` | `fn email_exists<'a, 'b>(&'a self, email: &'b str) -> bool` | 1 |
| `fn find(&self, id: u32) -> Option<&Customer>` | `fn find<'a>(&'a self, id: u32) -> Option<&'a Customer>` | 1, 3 |
| `fn page(&self, page: usize, per_page: usize) -> &[Customer]` | `fn page<'a>(&'a self, ...) -> &'a [Customer]` | 1, 3 |
| `fn find_mut(&mut self, id: u32) -> Option<&mut Customer>` | `fn find_mut<'a>(&'a mut self, id: u32) -> Option<&'a mut Customer>` | 1, 3 |

Read the `find_mut` row as a sentence: "the `&mut Customer` you get back keeps `self` mutably
borrowed for as long as you use it". That's exactly why, in Lab 07, you couldn't call another
store method while holding the result of `find_mut`.

> 🟢 **FOLLOW ALONG**: write out what elision does for `parse_input`:

```rust
fn parse_input<'a>(input: &'a str) -> (&'a str, Vec<&'a str>) {
```

Run `cargo check`. It compiles, and it's the **same function**. Now run `cargo clippy`:

```text
warning: the following explicit lifetimes could be elided: 'a
   --> src/main.rs:114:16
    |
114 | fn parse_input<'a>(input: &'a str) -> (&'a str, Vec<&'a str>) {
    |                ^^          ^^           ^^           ^^
    |
    = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.99.0/index.html#needless_lifetimes
    = note: `#[warn(clippy::needless_lifetimes)]` on by default
help: elide the lifetimes
    |
114 - fn parse_input<'a>(input: &'a str) -> (&'a str, Vec<&'a str>) {
114 + fn parse_input(input: &str) -> (&str, Vec<&str>) {
    |
```

Clippy is telling you that what you wrote is exactly what elision already produces. That's the
real reason most Rust code has so few `'a`s: elision covers the common cases, and you only write
lifetimes when there's something the rules can't know. Put the short form back. We're about to
replace this function anyway.

---

## Step 3 — A struct that borrows: `ParsedCommand<'a>`

The tuple `(&str, Vec<&str>)` works, but `parsed.0` and `parsed.1` don't say much, and the next
lab turns parsing into a typed `Command` enum. Let's give the parse result a name.

> 🟡 **EXPERIMENT**: predict first. Add this struct and function **next to** `parse_input` (keep
> `parse_input` for now), then run `cargo check`.

```rust
/// A command line, split into its name and arguments.
/// Borrows from the input line: nothing is copied.
#[derive(Debug, PartialEq)]
struct ParsedCommand {
    name: &str,
    args: Vec<&str>,
}

fn parse_command(input: &str) -> ParsedCommand {
    let mut words = input.split_whitespace();
    let name = words.next().unwrap_or("");
    let args = words.collect();
    ParsedCommand { name, args }
}
```

```text
error[E0106]: missing lifetime specifier
   --> src/main.rs:116:11
    |
116 |     name: &str,
    |           ^ expected named lifetime parameter
    |
help: consider introducing a named lifetime parameter
    |
115 ~ struct ParsedCommand<'a> {
116 ~     name: &'a str,
    |

error[E0106]: missing lifetime specifier
   --> src/main.rs:117:15
    |
117 |     args: Vec<&str>,
    |               ^ expected named lifetime parameter
    |
help: consider introducing a named lifetime parameter
    |
115 ~ struct ParsedCommand<'a> {
116 |     name: &str,
117 ~     args: Vec<&'a str>,
    |
```

**Read the error.** Why is a lifetime "missing" here but not in `parse_input`?

- **Who owns the text?** Not the struct. `name` and `args` point into somebody else's `String`.
- **How long must it live?** As long as any `ParsedCommand` value exists. That depends on where
  each `ParsedCommand` is created, so it's different every time.
- Elision works on *function signatures* because inputs give it something to copy from. A struct
  definition has no inputs, so there's nothing to infer from. The struct has to **declare** that
  it borrows, as a parameter, exactly like a generic type parameter.

> 🟢 **FOLLOW ALONG**: add the lifetime parameter.

```rust
#[derive(Debug, PartialEq)]
struct ParsedCommand<'a> {
    name: &'a str,
    args: Vec<&'a str>,
}
```

Read `ParsedCommand<'a>` as: *"a parsed command that borrows from some string for the region
`'a`, and so can't be used outside that region."* `'a` becomes part of the type. A
`ParsedCommand<'a>` is to `&'a str` what `Vec<&'a str>` is: a value carrying a borrow inside it.

Now write `parse_command` with the lifetime **spelled out**, so you can see the relationship:

```rust
fn parse_command<'a>(input: &'a str) -> ParsedCommand<'a> {
    let mut words = input.split_whitespace();
    let name = words.next().unwrap_or("");
    let args = words.collect();
    ParsedCommand { name, args }
}
```

"Give me a `&str` valid for `'a`, and I'll give you a `ParsedCommand` that borrows from it for the
same `'a`." `cargo check` passes (with "never used" warnings until we wire it in).

Elision rule 2 applies here too (one input lifetime, one output lifetime), so you can drop `'a`.
But try dropping it **completely**:

```rust
fn parse_command(input: &str) -> ParsedCommand {
```

```text
warning: hiding a lifetime that's elided elsewhere is confusing
   --> src/main.rs:127:25
    |
127 | fn parse_command(input: &str) -> ParsedCommand {
    |                         ^^^^     ^^^^^^^^^^^^^ the same lifetime is hidden here
    |                         |
    |                         the lifetime is elided here
    |
    = help: the same lifetime is referred to in inconsistent ways, making the signature confusing
    = note: `#[warn(mismatched_lifetime_syntaxes)]` on by default
help: use `'_` for type paths
    |
127 | fn parse_command(input: &str) -> ParsedCommand<'_> {
    |                                               ++++
```

It compiles, but with a warning, and the warning makes a good point. With `&str` you can *see*
there's a borrow. With a bare `ParsedCommand` you can't tell, from the signature, that the result
borrows from `input`. `'_` is the **elided lifetime placeholder**. It means "there's a lifetime
here; apply the usual elision rules". So the final, idiomatic signature is:

```rust
fn parse_command(input: &str) -> ParsedCommand<'_> {
```

Read `'_` as "borrowed from the input, as usual". It's short and honest about the borrow.

> 🟢 **FOLLOW ALONG**: switch the loop over and remove `parse_input`.

```rust
        let parsed = parse_command(&input);

        match parsed.name {
```

…and in your arms, `parse_id(&args)` becomes `parse_id(&parsed.args)`, and
`parse_page(&args)` becomes `parse_page(&parsed.args)` (or wherever your `list` arm reads
`args`). Delete `parse_input`, and turn its three
tests into tests for `parse_command`:

```rust
    #[test]
    fn parse_command_splits_name_and_args() {
        let parsed = parse_command("show 42");
        assert_eq!(parsed.name, "show");
        assert_eq!(parsed.args, vec!["42"]);
    }

    #[test]
    fn parse_command_ignores_extra_whitespace() {
        let parsed = parse_command("   list    2   \n");
        assert_eq!(parsed, ParsedCommand { name: "list", args: vec!["2"] });
    }

    #[test]
    fn parse_command_of_blank_line_is_empty() {
        let parsed = parse_command("   \n");
        assert_eq!(parsed.name, "");
        assert!(parsed.args.is_empty());
    }
```

(The second test compares whole structs. That's what `#[derive(PartialEq)]` is for.)

`cargo test` should be green. The memory picture hasn't changed at all from Lab 09:

```text
input: String (owned by the loop body)    s h o w ␣ 4 2 \n
                                          ▲         ▲
parsed: ParsedCommand<'_>                 │         │
  name: &str ─────────────────────────────┘         │
  args: Vec<&str> ─▶ [ &str ────────────────────────┘ ]
```

Commit:

```bash
git add .
git commit -m "Introduce ParsedCommand"
```

---

## Step 4 — When the owner dies too early

Now let's break it in the two most common ways, on purpose.

### E0716: a temporary that dies at the semicolon

Your loop has its own `print!`/`flush`/`read_line` code, while `prompt()` does nearly the same
thing. It's tempting to reuse it.

> 🟡 **EXPERIMENT**: predict, then replace the `let parsed = parse_command(&input);` line with:

```rust
        let parsed = parse_command(&prompt("Command: "));
```

```text
error[E0716]: temporary value dropped while borrowed
   --> src/main.rs:233:37
    |
233 |         let parsed = parse_command(&prompt("Command: "));
    |                                     ^^^^^^^^^^^^^^^^^^^ - temporary value is freed at the end of this statement
    |                                     |
    |                                     creates a temporary value which is freed while still in use
234 |
235 |         match parsed.name {
    |               ----------- borrow later used here
    |
    = note: consider using a `let` binding to create a longer lived value
```

**Reasoning script:**

1. **Who owns it?** `prompt` returns a brand-new `String`. You never gave it a name, so it's a
   **temporary**, and nobody owns it past this statement.
2. **Was it moved?** No, it was borrowed (`&prompt(...)`) and handed to `parse_command`.
3. **Is it a borrow?** Yes: `parsed.name` and `parsed.args` point into that temporary.
4. **How long must it live?** Until `match parsed.name` and the whole match. But temporaries are
   dropped at the **end of the statement**, the `;`.

```text
let parsed = parse_command(&prompt("Command: "));   ← temporary String created...
                                                ▲      ...and dropped here, at the `;`
match parsed.name { ... }                       │   ← parsed still points into it
                                                └── borrow sticks out past the owner
```

The fix is in the note: give the `String` an owner whose scope is long enough.

```rust
        let line = prompt("Command: ");
        let parsed = parse_command(&line);
```

That compiles. **Undo the whole experiment anyway** and go back to `parse_command(&input)`:
`prompt` trims away the information you need for Ctrl-D (end of input) handling.

The lesson generalises: **anything you borrow from has to be stored somewhere first.** A function
call that *returns* a `String` gives you a temporary. If you want to borrow from it beyond the
current statement, bind it with `let`.

### E0597: a borrow that outlives a loop iteration

Suppose you want to show the previous command at the start of each loop iteration. (It's a
throwaway experiment, not a feature.)

> 🟡 **EXPERIMENT**: predict, then add a variable **before** the loop:

```rust
    let mut previous: Option<ParsedCommand> = None;
```

…print it right after parsing:

```rust
        let parsed = parse_command(&input);
        match &previous {
            Some(prev) => println!("(previous command: {})", prev.name),
            None => {}
        }
```

…and store the current command at the very end of the loop body (after `count += 1;`):

```rust
        previous = Some(parsed);
```

```text
error[E0597]: `input` does not live long enough
   --> src/main.rs:234:36
    |
225 |         let mut input = String::new();
    |             --------- binding `input` declared here
...
234 |         let parsed = parse_command(&input);
    |                                    ^^^^^^ borrowed value does not live long enough
235 |         match &previous {
    |               --------- borrow later used here
...
323 |     };
    |     - `input` dropped here while still borrowed
```

Read the three labels: *declared here*, *dropped here*, *borrow later used here*. The last one
points at `match &previous` **above** the line that created the borrow. That only makes sense
once you think in loop iterations:

```text
let mut previous;                    ┐ previous: lives across ALL iterations
loop {                               │
  iteration 1:                       │
    let input = ...;          ┐      │
    parsed = parse(&input);   │      │
    previous = Some(parsed);  │ ◀────┼── previous now borrows iteration 1's input
  }                           ┘ input (iteration 1) dropped
  iteration 2:                       │
    let input = ...;                 │
    match &previous { ... }   ◀──────┼── uses a borrow of iteration 1's input: dangling!
}                                    ┘
```

1. **Who owns it?** Each iteration's `input`, a fresh `String` that's dropped at the end of that
   iteration.
2. **Was it moved?** No.
3. **Is it a borrow?** `previous` holds a `ParsedCommand`, which holds `&str`s into `input`.
4. **How long must it live?** Until the *next* iteration reads `previous`, but `input` is already
   gone by then.

> 🟡 **EXPERIMENT**: the "obvious" fix is to make `input` live longer. Move
> `let mut input = String::new();` above the loop and call `input.clear();` at the start of each
> iteration instead. Predict what happens.

```text
error[E0502]: cannot borrow `input` as mutable because it is also borrowed as immutable
   --> src/main.rs:226:9
    |
226 |         input.clear();
    |         ^^^^^^^^^^^^^ mutable borrow occurs here
...
235 |         let parsed = parse_command(&input);
    |                                    ------ immutable borrow occurs here
236 |         match &previous {
    |               --------- immutable borrow later used here
```

(You'll get a second, identical error for `read_line(&mut input)`.) Now the owner lives long
enough, but the code wants two incompatible things: keep the old text **and** overwrite the
buffer it lives in. No lifetime annotation can fix that, because the problem isn't a missing
annotation. You're asking to keep a view onto data that's about to be replaced.

The right fix is to **own** what you keep. Put `let mut input` back inside the loop, and change
the experiment to store an owned copy of only what you need:

```rust
    let mut previous: Option<String> = None;
    // ...
        match &previous {
            Some(prev) => println!("(previous command: {prev})"),
            None => {}
        }
    // ...
        previous = Some(parsed.name.to_string());
```

It compiles. `to_string()` copies a few bytes, and that copy is exactly what lets the data
survive the end of the iteration. **Now remove the whole `previous` experiment.** It's not a
feature we're keeping.

> **Owned vs borrowed, the first rule:** if data has to outlive the thing it came from, it must
> be **owned**. Borrowing is for looking at something *while its owner is still around*.

---

## Step 5 — `search`: borrowed results

> 🟢 **FOLLOW ALONG**: add this method to `impl CustomerStore`.

```rust
    /// Customers whose name or email contains `term`, ignoring case.
    /// The results borrow from the store, not from `term`.
    fn search<'a>(&'a self, term: &str) -> Vec<&'a Customer> {
        let needle = term.to_lowercase();
        let mut results = Vec::new();
        for customer in &self.customers {
            if customer.name.to_lowercase().contains(&needle)
                || customer.email.to_lowercase().contains(&needle)
            {
                results.push(customer);
            }
        }
        results
    }
```

Read the signature as a contract:

- `&'a self`: the store is borrowed for some region `'a`, chosen by the caller.
- `term: &str` **has no `'a`**. It gets its own anonymous lifetime (rule 1), unrelated to `'a`.
- `Vec<&'a Customer>`: every customer in the result is borrowed from **the store**, for `'a`.

Then check the body keeps that promise:

- `for customer in &self.customers` yields `&Customer`s borrowed from `self`. ✅ Those are what we
  push.
- `needle` is a new, owned `String` (lowercasing allocates). It's a local, and dropped at the end.
  That's fine, because **nothing we return points into it**. Compare Lab 09's E0515, where the
  returned `&str`s *did* point into the lowercased local.
- `term` is only read during the call. It never ends up in the result.

Does it need the explicit `'a`? No: rule 3 gives the output `self`'s lifetime, so
`fn search(&self, term: &str) -> Vec<&Customer>` means exactly the same thing. We keep the
explicit form here because it **documents the decision** that the term is not part of the result.
(Both forms are accepted by Clippy at the time of writing.)

> 🟢 **FOLLOW ALONG**: wire up the command. Put this arm next to `show`.

```rust
            "search" => match parsed.args.as_slice() {
                [term, ..] => {
                    let results = store.search(term);
                    if results.is_empty() {
                        println!("No customers match '{term}'.");
                    }
                    for customer in results {
                        println!("{}", customer.summary());
                    }
                }
                [] => println!("Usage: search <term>"),
            },
```

`as_slice()` turns the `Vec<&str>` into a `&[&str]` so you can use slice patterns on it.
`[term, ..]` means "at least one argument; call the first one `term`". So `search grace hopper`
searches for `grace`. Multi-word search can come later. (Here, `term` is a `&&str`, a reference to
an element of the slice. Deref coercion turns it into `&str` for the call.)

Add the help line, between `show` and `update`:

```rust
    println!("  search <term>  find customers by name or email");
```

> 🟢 **FOLLOW ALONG**: tests. The second one is the interesting one.

```rust
    #[test]
    fn search_matches_name_or_email_ignoring_case() {
        let mut store = CustomerStore::new();
        store.add(String::from("Ada Lovelace"), String::from("ada@example.com"), String::new());
        store.add(String::from("Grace Hopper"), String::from("grace@navy.mil"), String::new());
        store.add(String::from("Alan Turing"), String::from("ADA.fan@bletchley.uk"), String::new());
        let ids: Vec<u32> = store.search("ADA").iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![1, 3]);
        assert!(store.search("NAVY").len() == 1);
        assert!(store.search("nobody").is_empty());
    }

    #[test]
    fn search_results_outlive_the_search_term() {
        let store = store_with(3);
        let results = {
            let term = String::from("customer 2");
            store.search(&term)
        }; // `term` is dropped here
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, 2);
    }
```

(`.iter().map(|c| c.id).collect()` takes the id of every result. Lab 17 covers closures and
iterator chains. `store_with` is the test helper from Lab 09's Your Turn 3.)

Run `cargo test search`. Both pass. The second test *proves* the signature: `term` is dropped
while `results` is still in use, and that's fine, because the results don't borrow from it.

> 🟡 **EXPERIMENT**: over-promise. Predict, then change the signature to tie `term` to `'a` as
> well:
>
> ```rust
>     fn search<'a>(&'a self, term: &'a str) -> Vec<&'a Customer> {
> ```
>
> The body doesn't change at all. Run `cargo test`.

```text
error[E0597]: `term` does not live long enough
   --> src/main.rs:487:26
    |
485 |         let results = {
    |             -------
    |             |
    |             borrow later stored here
    |             variable `results` declared here
486 |             let term = String::from("customer 2");
    |                 ---- binding `term` declared here
487 |             store.search(&term)
    |                          ^^^^^ borrowed value does not live long enough
488 |         }; // `term` is dropped here
    |         - `term` dropped here while still borrowed
```

(Your output may end with an extra `note:`/`help:` about "buffer reuse". It's a generic hint and
doesn't apply here.)

Nothing in the **body** changed, and the body didn't break. The **caller** broke. The new
signature claims "the results may borrow from `term`", and the compiler checks call sites against
the signature only, never against the body. So it now makes every caller keep `term` alive as long
as the results. That's what "annotations describe relationships" means in practice: a wrong
relationship doesn't change what the code *does*, but it changes what callers are *allowed* to do.

Put the signature back to `term: &str`. Then run the CRM and try it out (see ▶️ Run It below).

Commit:

```bash
git add .
git commit -m "Add search command"
```

---

## Step 6 — `'static`

There's one lifetime with a name that you didn't invent: `'static`, the region that lasts **for
the rest of the program**.

You've seen it already. In Lab 09's E0308 experiment the compiler said
`found reference &'static str`. Every string literal has that type:

```rust
let usage: &'static str = "Usage: show <id>";
```

The bytes are inside your compiled binary and they're never freed, so a reference to them is
valid everywhere. The same goes for `const APP_NAME: &str`: in a `const` or `static`, an elided
lifetime is `'static`.

**`'static` references fit anywhere shorter.** In `show` you wrote:

```rust
let domain = email_domain(&customer.email).unwrap_or("(none)");
```

`email_domain` returns `Option<&'x str>`, where `'x` is "while `customer` is borrowed".
`"(none)"` is `&'static str`. Rust accepts it because a reference that's valid *forever* is
certainly valid during `'x`. Longer lifetimes can always be used where shorter ones are expected.

### The misconception: `T: 'static` does not mean "lives forever"

You'll meet `'static` as a **bound** on a type, `T: 'static`, in Lab 25 (`thread::spawn`) and Lab
26 (`tokio::spawn`). It does **not** say the value lives forever. It says:

> **`T: 'static`** — *the type `T` contains no borrows that could expire.* A value of type `T`
> could be kept as long as you like, because it doesn't depend on anyone else's data.

Every **owned** type qualifies: `u32`, `String`, `Vec<Customer>`, `Customer`. Borrows of locals
don't.

> 🟡 **EXPERIMENT**: add this to your `tests` module. Predict which line fails, and for each line
> that compiles, predict when that value is dropped.

```rust
    /// Accepts any value whose type is `'static`.
    fn require_static<T: 'static>(_value: T) {}

    #[test]
    fn static_bound_is_about_borrows_not_time() {
        let name = String::from("Ada Lovelace");
        let customer = Customer::new(1, name.clone(), String::from("ada@example.com"), String::new());
        require_static(APP_NAME); // &'static str
        require_static(customer); // Customer owns all its data
        require_static(name.clone()); // String owns its data
        require_static(&name); // a borrow of a local
    }
```

```text
error[E0597]: `name` does not live long enough
   --> src/main.rs:491:24
    |
487 |         let name = String::from("Ada Lovelace");
    |             ---- binding `name` declared here
...
491 |         require_static(&name); // a borrow of a local
    |         ---------------^^^^^-
    |         |              |
    |         |              borrowed value does not live long enough
    |         argument requires that `name` is borrowed for `'static`
492 |     }
    |     - `name` dropped here while still borrowed
    |
note: requirement that the value outlives `'static` introduced here
   --> src/main.rs:483:26
    |
483 |     fn require_static<T: 'static>(_value: T) {}
    |                          ^^^^^^^
```

Only `&name` fails. And `customer` and the cloned `String` both satisfied
`T: 'static`, then were **dropped immediately**, at the end of `require_static`, where the
`_value` parameter goes out of scope. Satisfying `'static` didn't make them live a nanosecond
longer. It only proved they *could* be kept, because they borrow nothing.

Why would a function demand this? Because it wants to keep the value for an unknown amount of
time. A new thread might run after the current function has returned, so `thread::spawn` can't
accept a closure that borrows your locals. The fix there, as here, is almost never "make it
`'static`". It's usually **"give it owned data"** (`move` a `String` in, or share with `Arc`, Lab 25).

Delete the experiment line `require_static(&name);`, or the whole test. If you keep the rest,
it documents the rule.

> ⚠️ If a compiler suggestion ever tells you to add `'static` to a reference in your *own* struct
> or function, stop and ask the owned-vs-borrowed question first (see 🧠 Understand It). Forcing
> `'static` on a borrow almost always means the data should have been owned.

---

## ▶️ Run It

```bash
cargo run
```

```text
add          (Ada Lovelace, ada@example.com, 555-0100)
add          (Grace Hopper, grace@navy.mil, 555-0199)
add          (Charles Babbage, charles@EXAMPLE.com, 555-0111)
search ada
search EXAMPLE
search NAVY
search zzz
search
search grace hopper
```

## ✅ Expected Result

```text
crm> search ada
#1 Ada Lovelace <ada@example.com> 555-0100
crm> search EXAMPLE
#1 Ada Lovelace <ada@example.com> 555-0100
#3 Charles Babbage <charles@EXAMPLE.com> 555-0111
crm> search NAVY
#2 Grace Hopper <grace@navy.mil> 555-0199
crm> search zzz
No customers match 'zzz'.
crm> search
Usage: search <term>
crm> search grace hopper
#2 Grace Hopper <grace@navy.mil> 555-0199
```

`cargo test` is green, and `cargo clippy` shows no new warnings.

## 🧠 Understand It

### The reasoning script, for lifetimes

Every lifetime error in this lab was answered with the same five questions:

| Question | E0716 (`prompt`) | E0597 (`previous`) | E0597 (`term: &'a str`) |
|---|---|---|---|
| **Who owns it?** | A temporary `String` | `input`, one per iteration | `term`, inside a block |
| **Moved?** | No | No | No |
| **A borrow?** | `parsed` points into it | `previous` points into it | `results` *declared* to point into it |
| **Mutable?** | No | No (but the hoisting fix needed `&mut`) | No |
| **How long must it live?** | Past the `;` | Into the next iteration | As long as `results` |
| **Fix** | Bind it with `let` | Own the data (`String`) | Fix the signature: `term` isn't in the result |

Notice that only one of the three fixes involved writing a lifetime, and that fix was
*removing* one.

### Where lifetimes appear in signatures

```rust
fn search<'a>(&'a self, term: &str) -> Vec<&'a Customer>
//       ^^^^ declare: "there's a region called 'a"
//              ^^^^^^^^ use: self is borrowed for 'a
//                                           ^^^^^^^^^^^^^ use: results are valid for 'a
```

Declaring `<'a>` is like declaring `<T>`: it introduces a name. Using `'a` in two places says
**those two places are connected**. A lifetime that appears only once tells the compiler nothing,
which is why elision handles those for you.

### Owned vs borrowed fields: a practical rule

You now have one struct of each kind:

| | `Customer` | `ParsedCommand<'a>` |
|---|---|---|
| Fields | `String` (owned) | `&'a str` (borrowed) |
| Where the data comes from | Lines typed by the user, which are gone after `add` | The current input line |
| How long it's needed | Until it's deleted: across commands, potentially forever | Within one loop iteration |
| Stored in a collection? | Yes, in `CustomerStore` | No, created and consumed in place |

The rule of thumb:

1. **Default to owned fields** for anything you *store*: entities, stores, anything in a `Vec`
   or `HashMap`, anything kept across loop iterations, threads or requests.
2. **Use borrowed fields for short-lived views** over data owned elsewhere: parsers, search
   results, report rows, iterators. Each is created, used and dropped while the owner sits still.
3. If a struct with a lifetime starts showing up **inside another long-lived struct**, stop. You're
   about to spread `'a` through your whole program. Use owned data or IDs instead. (Lab 14
   tries `Contact { company: &'a Company }` on purpose so you can feel this.)
4. When in doubt, own it. A `String` copy costs a few nanoseconds. A lifetime that leaks into every
   signature costs hours.

### Lifetimes are a compile-time-only concept

Run `cargo build --release` with `search<'a>` and with `search` (elided): the machine code is
identical. Lifetimes don't exist at runtime. There's no counter, no tag, no check. They're proof
obligations the compiler discharges and then throws away. That's how Rust gets memory safety
without a garbage collector, at zero runtime cost.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: the borrow from `search` is real.** In the `search` arm, right after
> `let results = store.search(term);`, add `store.normalize_emails();`. Predict the error before
> you run `cargo check`.

```text
error[E0502]: cannot borrow `store` as mutable because it is also borrowed as immutable
   --> src/main.rs:311:21
    |
310 |                     let results = store.search(term);
    |                                   ----- immutable borrow occurs here
311 |                     store.normalize_emails();
    |                     ^^^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
312 |                     if results.is_empty() {
    |                        ------- immutable borrow later used here
```

You could have predicted this from the **signature alone**: `Vec<&'a Customer>` with `&'a self`
means "the store stays borrowed while you use the results". Move the call after the `for` loop.
Does it compile now? Why? (Remove it afterwards.)

> 🟡 **EXPERIMENT 2: when elision guesses wrong.** Add this method to `CustomerStore` and call it
> once from `main` (e.g. `println!("{}", store.first_email_or("none"));` before the loop):

```rust
    /// The first customer's email, or `fallback` if the store is empty.
    fn first_email_or(&self, fallback: &str) -> &str {
        match self.customers.first() {
            Some(customer) => &customer.email,
            None => fallback,
        }
    }
```

```text
error: lifetime may not live long enough
   --> src/main.rs:103:9
    |
102 |       fn first_email_or(&self, fallback: &str) -> &str {
    |                         -                - let's call the lifetime of this reference `'1`
    |                         |
    |                         let's call the lifetime of this reference `'2`
103 | /         match self.customers.first() {
104 | |             Some(customer) => &customer.email,
105 | |             None => fallback,
106 | |         }
    | |_________^ method was supposed to return data with lifetime `'2` but it is returning data with lifetime `'1`
    |
help: consider introducing a named lifetime parameter and update trait if needed
    |
102 |     fn first_email_or<'a>(&self, fallback: &'a str) -> &'a str {
    |                      ++++                   ++          ++
```

Rule 3 tied the output to `self`, but the body sometimes returns `fallback`. Try the compiler's
`help:` suggestion exactly as written. Does it compile? (It doesn't: now the *other* branch,
`&customer.email`, breaks.) What signature says "the result may come from either one"? Fix it so
it compiles, then remove the method. **Lesson:** compiler suggestions are hypotheses, not answers.
Your reasoning about where the data comes from decides the signature.

> 🟡 **EXPERIMENT 3: two inputs, one region.** Put this in your `tests` module. It picks the
> customer with the longer name:

```rust
    fn longer_name<'a>(a: &'a Customer, b: &'a Customer) -> &'a Customer {
        if b.name.chars().count() > a.name.chars().count() { b } else { a }
    }

    #[test]
    fn longer_name_borrows_from_both() {
        let ada = Customer::new(1, String::from("Ada Lovelace"), String::from("ada@example.com"), String::new());
        let winner;
        {
            let grace = Customer::new(2, String::from("Grace"), String::from("g@navy.mil"), String::new());
            winner = longer_name(&ada, &grace);
        }
        assert_eq!(winner.id, 1);
    }
```

At runtime the winner is `ada`, who is still alive at the `assert_eq!`. Predict whether it
compiles. Then explain the result using only the signature. (Answer in `solutions.md`.)

## 👩🏽‍💻 Your Turn

Three tasks. None of their code appears above. Each comes with a signature to reason about
**before** you type.

### Your Turn 1 — `ParsedCommand::arg`

> 🔵 **YOUR TURN**: add a method that returns one argument by position:
>
> ```rust
> impl<'a> ParsedCommand<'a> {
>     fn arg(&self, index: usize) -> Option</* you decide */>
> }
> ```

The return type is the whole exercise. This test must compile and pass. Paste it into your tests
module as-is:

```rust
    #[test]
    fn arg_outlives_the_parsed_command() {
        let line = String::from("search ada");
        let term = {
            let parsed = parse_command(&line);
            parsed.arg(0)
        }; // `parsed` is dropped here, `line` is still alive
        assert_eq!(term, Some("ada"));
    }
```

- [ ] `arg(0)` is the first argument (not the command name); out-of-range indexes return `None`
      (no panic)
- [ ] The test above compiles and passes **unchanged**
- [ ] The `search` arm uses `parsed.arg(0)` instead of the slice pattern, with the same behaviour
      and the same `Usage: search <term>` message
- [ ] You can explain, in one sentence, what the returned reference borrows from, and why the
      "obvious" signature `-> Option<&str>` fails the test

### Your Turn 2 — `display_name`: a function with two borrowed inputs

> 🔵 **YOUR TURN**: until Lab 12, nothing stops a customer having a blank name. Write a free
> function `display_name` that takes a name and an email (both borrowed) and returns the name, or
> the email if the name is blank (empty or only whitespace). **Borrowed in, borrowed out.** No
> allocation.

- [ ] Start with the signature *without* lifetimes, `fn display_name(name: &str, email: &str) -> &str`,
      and run `cargo check`. Read the error. Which elision rule failed, and why?
- [ ] Fix the signature. Be ready to explain what your annotation promises to callers
- [ ] `display_name("Ada Lovelace", "ada@example.com")` → `"Ada Lovelace"`
- [ ] `display_name("", "ada@example.com")` and `display_name("   ", "ada@example.com")` →
      `"ada@example.com"`
- [ ] Tests for the cases above
- [ ] `delete` uses it: deleting a customer with a blank name prints
      `Deleted customer #4 (noname@navy.mil)`; with a name, the output is unchanged

### Your Turn 3 — `first_by_domain` and a colleague hint on `add`

> 🔵 **YOUR TURN**: when you add a customer whose email domain matches an existing customer, the
> CRM should point it out (they probably work at the same company).

Add this method (the signature is given; the body is yours):

```rust
impl CustomerStore {
    fn first_by_domain<'a>(&'a self, domain: &str) -> Option<&'a Customer>
}
```

- [ ] Returns the first customer (in store order) whose `email_domain` equals `domain`,
      **ignoring ASCII case** (`EXAMPLE.com` matches `example.com`). Use `email_domain` from
      Lab 09. No allocation: look for a `str` method that compares ignoring ASCII case
- [ ] Customers without a domain never match
- [ ] Tests: case-insensitive match, first match wins, no match → `None`
- [ ] In the `add` arm, after a successful add, print a note if **another** customer already
      used that domain:

```text
crm> add
Name: Charles Babbage
Email: charles@EXAMPLE.com
Phone: 555-0111
Added customer #3
Note: #1 Ada Lovelace also uses EXAMPLE.com.
```

  (The domain shown is the **new** customer's, as typed.)
- [ ] No note when the domain is new, when the email has no domain, or when the email is a
      duplicate (that path is unchanged)
- [ ] The new customer must never be reported as its own colleague
- [ ] No `.clone()` of a `Customer`
- [ ] You can explain why `domain: &str` (not `&'a str`) matters for this `add` arm. Try it with
      `&'a str` and read the error you get

Then:

- [ ] `cargo test` passes, `cargo clippy` shows no new warnings

## 💡 Hint

> 💡 **HINT**: for every reference you return, ask "**which owner does this point into?**" Then
> write that owner's lifetime on the return type, and on nothing else. The test in Your Turn 1
> tells you exactly which owner survives.

<details><summary>Hint 2: Your Turn 1</summary>

The `&str`s inside `self.args` have type `&'a str`. They point into the input line, not into the
`ParsedCommand`. If you write `-> Option<&str>`, elision rule 3 ties the result to `&self`, the
`ParsedCommand`, which the test drops. You need to name the *other* lifetime, the one from
`impl<'a> ParsedCommand<'a>`. For the body: `self.args.get(index)` gives `Option<&&'a str>`.
Look at `Option::copied`.

</details>

<details><summary>Hint 3: Your Turn 2</summary>

Two input references means two lifetimes after rule 1, so rule 2 doesn't apply, and there's no
`self` for rule 3. The function can return either input, so the result must be valid for as long
as **both** are. One lifetime name used on both inputs and the output says exactly that.

</details>

<details><summary>Hint 4: Your Turn 3</summary>

Body: loop over `&self.customers`; for each, `email_domain(&customer.email)`, and compare with
`str::eq_ignore_ascii_case`. Edition 2024 lets you write
`if let Some(d) = email_domain(&customer.email) && d.eq_ignore_ascii_case(domain) { ... }`
(a *let chain*), which keeps Clippy happy.

`add` arm: the obvious version keeps the `Option<&Customer>` from `first_by_domain` alive across
`store.add(...)` and gets **E0502**. Look *before* you add (that also solves "never its own
colleague"), but turn what you found into **owned** data (a `String` message built with
`format!`) before calling `store.add`. Then nothing borrows `store` any more.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. In one sentence each: what is a lifetime? What does writing `'a` change at runtime?
2. State the three elision rules. Which one makes `fn find(&self, id: u32) -> Option<&Customer>`
   compile without annotations?
3. Why does `struct ParsedCommand { name: &str }` need a lifetime parameter when
   `fn parse_input(input: &str) -> &str` doesn't?
4. Why doesn't `term` need `'a` in `search`? What would break for callers if it had one?
5. What's the difference between E0597 and E0716? Give a CRM example of each.
6. `String: 'static` is true. Does that mean every `String` lives until the program exits?
   Explain what `T: 'static` actually promises.
7. You're designing `struct Invoice` that will be stored in a `Vec` inside the CRM for weeks.
   Should its `customer_name` field be `String` or `&'a str`? Why?
8. In Your Turn 1, why must `arg` return `Option<&'a str>` rather than `Option<&str>`?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo test
```

## Git Commit

```bash
git add .
git commit -m "Add customer search with borrowed results"
git tag lab-10
git push && git push --tags
```

`git diff lab-09 lab-10 -- src/main.rs` shows every lifetime you wrote, and how few there are.

> 🏁 **Phase 2 is done.** Before Lab 11, try [Challenge A — Duplicate Detection](../../challenges/A-duplicate-detection/README.md).
> It uses everything from Labs 06–10, with a spec and no instructions.

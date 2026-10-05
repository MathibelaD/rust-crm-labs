# Lab 09 — Slices & Strings Properly

> **Phase:** 2 — Ownership & Borrowing · **Builds on:** Lab 08 · **Time:** ~3–4 hours
> **Your repo before this lab:** tag `lab-08` · **After:** tag `lab-09`

## 🎯 Goal

Make the command line understand arguments (`show 3`, `delete 2`, `list 2`) with a parser that
**borrows** the input instead of copying it, and add a few string features (email domain,
initials, pagination) that make you work with `String`, `&str`, UTF-8 and `&[T]` deliberately.

## 🧠 What You'll Learn

- What a `String` and a `&str` are in memory, and why one owns and the other only looks
- String literals: where `"help"` actually lives
- UTF-8: why `name.len()` is not the number of letters, and why `name[0]` doesn't compile
- A **runtime panic** from slicing in the middle of a character (not every bug is a compile error)
- Safe string tools: `chars()`, `char_indices()`, `find()`, `split_whitespace()`, `get()`
- Slices of anything: `&[T]`, slice patterns (`[raw]`, `[]`, `[first, ..]`)
- Deref coercion: why `&String` works where `&str` is expected, and `&Vec<T>` where `&[T]` is
- Why good APIs take `&str` and `&[T]` instead of `&String` and `&Vec<T>`

## 🔨 What We're Building

Right now `show`, `update` and `delete` each need two steps:

```text
crm> show
Customer id: 1
```

Real command lines don't work like that. After this lab:

```text
crm> show 1
#1 Ada Lovelace <ada@example.com> 555-0100
  Domain:   example.com
  Initials: AL
crm> list 2
#6 Linus Torvalds <linus@kernel.org> 555-0123
Page 2 of 2
```

To get there you'll write `parse_input`, a function that splits a line into a command and its
arguments **without allocating a single new string**. Every piece it returns is a *view* into the
line you already read. That's the core idea of this lab: owned data lives in one place, and
everything else borrows a window onto it.

You'll also refactor `CustomerStore::all()` to return `&[Customer]` instead of `&Vec<Customer>`,
and you'll crash your own CRM with a name containing `Å`. On purpose.

> Your code from Lab 08 may differ in small ways from the snippets here (a message's wording,
> where you increment the command counter). Keep your version. What matters is the shape of the
> changes. Line numbers in compiler output will also differ from yours.

---

## Step 1 — What a `String` and a `&str` really are

You've used both since Lab 02. Time to see them properly.

A `String` is a struct with three fields, stored wherever the variable lives (usually the stack).
The text itself lives on the heap:

```text
let input = String::from("show 42");

  stack (owned by `input`)              heap
  ┌──────────────┐
  │ ptr  ────────┼──────────────────▶  s h o w ␣ 4 2
  │ len  = 7     │                     (7 bytes, maybe room for more)
  │ cap  = 7     │
  └──────────────┘
```

A `&str` (a *string slice*) has only two fields, a pointer and a length. It has no capacity
because it can never grow. It doesn't own anything. It's a window onto bytes that **someone else
owns**:

```text
let command: &str = &input[0..4];   // "show"
let arg: &str = &input[5..7];       // "42"

  input: String                     heap
  ┌──────────────┐
  │ ptr  ────────┼──────────────▶  s h o w ␣ 4 2
  │ len  = 7     │                 ▲         ▲
  │ cap  = 7     │                 │         │
  └──────────────┘                 │         │
  command: &str  { ptr ────────────┘, len 4 }│
  arg:     &str  { ptr ──────────────────────┘, len 2 }
```

Nothing was copied. `command` and `arg` are 16 bytes each (two `usize`s), however long the text.

So whenever you see a `&str`, ask the Lab 06 question: **who owns the bytes?**

| `&str` in your CRM | Who owns the bytes? |
|---|---|
| `"help"` in your `match` | Nobody at runtime: it's baked into the compiled binary |
| `APP_NAME` | Same: a literal in the binary |
| `input.trim()` | The `input: String` in your loop |
| `label` in `fn prompt(label: &str)` | Whoever called `prompt` (here: literals like `"Name: "`) |
| `email` in `fn email_exists(&self, email: &str)` | The caller's `String` (`email` in your `add` arm) |

String literals are the interesting case. `"Name: "` is stored in the read-only data section of
your executable. It exists for the whole run of the program, which is why its full type is
`&'static str`. You'll meet `'static` properly in Lab 10.

> 🟢 **FOLLOW ALONG**: add this probe test to your `tests` module. It's temporary.

```rust
    #[test]
    fn explore_strings() {
        let name = String::from("Zoë Ångström");
        println!("len (bytes): {}", name.len());
        println!("chars:       {}", name.chars().count());
        println!("bytes:       {:?}", name.as_bytes());
        for (index, ch) in name.char_indices() {
            println!("byte {index:>2}: {ch}");
        }
    }
```

Run only this test and let it print (tests normally hide output):

```bash
cargo test explore -- --nocapture
```

```text
running 1 test
len (bytes): 15
chars:       12
bytes:       [90, 111, 195, 171, 32, 195, 133, 110, 103, 115, 116, 114, 195, 182, 109]
byte  0: Z
byte  1: o
byte  2: ë
byte  4:  
byte  5: Å
byte  7: n
byte  8: g
byte  9: s
byte 10: t
byte 11: r
byte 12: ö
byte 14: m
test tests::explore_strings ... ok
```

Read that carefully:

- `len()` is **15**, but there are **12** characters. `len()` counts **bytes**.
- `ë` is two bytes (`195, 171`), and so are `Å` (`195, 133`) and `ö` (`195, 182`). Rust strings
  are always valid **UTF-8**: ASCII characters take 1 byte, others take 2, 3 or 4.
- `char_indices()` skips from byte 2 to byte 4, and from 5 to 7. Those gaps are the *middles* of
  characters.

> If you're coming from JavaScript: JS strings are UTF-16, and `"Zoë".length` counts UTF-16
> code units. Rust counts UTF-8 bytes. Neither one counts "letters as a human sees them".

> 🟡 **EXPERIMENT**: predict first. Add this line at the end of `explore_strings`, then run
> `cargo test explore`.

```rust
        let first = name[0];
```

```text
error[E0277]: the type `str` cannot be indexed by `{integer}`
   --> src/main.rs:255:26
    |
255 |         let first = name[0];
    |                          ^ string indices are ranges of `usize`
    |
    = help: the trait `SliceIndex<str>` is not implemented for `{integer}`
    = note: you can use `.chars().nth()` or `.bytes().nth()`
            for more information, see chapter 8 in The Book: <https://doc.rust-lang.org/book/ch08-02-strings.html#indexing-into-strings>
```

**Read the error.** What would `name[0]` even return? The byte `90`? The `char` `'Z'`? And what
about `name[2]`, which is half of `ë`? Rust refuses to guess. A single index into a string isn't
allowed at all. You can ask for a **byte range** (`&name[0..1]`), for bytes (`.bytes()`) or for
chars (`.chars()`), and in each case you say which one you mean. Notice the compiler even tells you
the alternatives. (We'll see in Step 4 that byte ranges have their own trap.)

Delete the `let first` line **and** the whole `explore_strings` test. It was a probe.

---

## Step 2 — A zero-copy command parser

Your loop currently does `match input.trim() { ... }`. We want to split the line into a command
name and a list of arguments. Here's the first decision: what should the function return?

| Option | Return type | Cost |
|---|---|---|
| Owned | `(String, Vec<String>)` | One heap allocation per word, plus copying every byte |
| Borrowed | `(&str, Vec<&str>)` | One `Vec` of small `(ptr, len)` pairs. No text is copied |

The input line already exists and stays alive for the whole loop iteration. Copying it into new
`String`s buys us nothing, so we borrow.

> 🟢 **FOLLOW ALONG**: add this function above `main` (next to `prompt` is a good place).

```rust
/// Splits a raw input line into a command name and its arguments.
/// Nothing is copied: every &str returned points into `input`.
fn parse_input(input: &str) -> (&str, Vec<&str>) {
    let mut words = input.split_whitespace();
    let name = words.next().unwrap_or("");
    let args = words.collect();
    (name, args)
}
```

Line by line:

- `input.split_whitespace()` gives you the words of `input` one at a time, skipping any amount of
  spaces, tabs and the trailing `\n`. Each word is a `&str` pointing into `input`.
  (It's an *iterator*. Iterators get a whole lab, Lab 17. For now: something you can ask for
  "the next item" repeatedly.)
- `words.next()` returns the first word as `Option<&str>`: `Some("show")`, or `None` for an empty
  line. `.unwrap_or("")` means "the value inside, or `""` if there is none". (`Option` has many
  helpers like this, and Lab 12 covers them.)
- `words.collect()` gathers the remaining words. How does it know to build a `Vec<&str>`? From the
  return type. `args` ends up in the tuple, and the tuple's type is fixed by the signature.

Here's what that looks like in memory for the line `"show 42\n"`:

```text
input (owned by your loop):  s h o w ␣ 4 2 \n
                             ▲         ▲
name ────────────────────────┘         │
args: Vec<&str> (heap) [ &str ─────────┘ ]
```

> 🟢 **FOLLOW ALONG**: add tests for it to your `tests` module.

```rust
    #[test]
    fn parse_input_splits_name_and_args() {
        let (name, args) = parse_input("show 42");
        assert_eq!(name, "show");
        assert_eq!(args, vec!["42"]);
    }

    #[test]
    fn parse_input_ignores_extra_whitespace() {
        let (name, args) = parse_input("   list    2   \n");
        assert_eq!(name, "list");
        assert_eq!(args, vec!["2"]);
    }

    #[test]
    fn parse_input_of_blank_line_is_empty() {
        let (name, args) = parse_input("   \n");
        assert_eq!(name, "");
        assert!(args.is_empty());
    }
```

Run `cargo test parse_input`. Three tests should pass. (`cargo check` will warn that `parse_input`
is never used. That's fixed in Step 3.)

Wait. How does Rust know the returned `&str`s point into `input`, and not somewhere else? You never
said so. The short answer is a rule called **lifetime elision**: "one reference in, so every
reference out borrows from it". The full story is Lab 10. For now, notice that the compiler
*did* work it out, and the next experiment shows it holds you to it.

> 🟡 **EXPERIMENT**: commands should be case-insensitive, right? `SHOW 1` should work. Predict
> what happens, then change the first line of `parse_input` to lowercase the input first:

```rust
fn parse_input(input: &str) -> (&str, Vec<&str>) {
    let lowered = input.to_lowercase();
    let mut words = lowered.split_whitespace();
    let name = words.next().unwrap_or("");
    let args = words.collect();
    (name, args)
}
```

```text
error[E0515]: cannot return value referencing local variable `lowered`
   --> src/main.rs:105:5
    |
102 |     let mut words = lowered.split_whitespace();
    |                     ------- `lowered` is borrowed here
...
105 |     (name, args)
    |     ^^^^^^^^^^^^ returns a value referencing data owned by the current function
```

**Read the error** with the usual questions:

1. **Who owns it?** `to_lowercase()` can't lowercase in place (it borrowed `input` read-only, and
   some characters even change byte length when lowercased), so it builds a **new `String`**.
   `lowered` owns it, and `lowered` is a local of `parse_input`.
2. **Was it moved?** No. It stays in `lowered` until the function ends.
3. **Is it a borrow?** `name` and `args` are `&str` views into `lowered`'s heap bytes.
4. **How long must it live?** As long as the caller uses `name` and `args`, so *after*
   `parse_input` returns. But `lowered` is dropped at the closing `}`. The views would point at
   freed memory: a dangling pointer, the classic C bug. Rust rejects it.

The fixes, and what they cost:

- Return owned data: `(String, Vec<String>)`. Works, allocates for every word.
- Let the **caller** own the lowercased `String` and pass `&lowered` in. Then the data outlives
  the function. Works, but every command pays for a copy.
- Don't lowercase at all. Compare case-insensitively where you need it
  (`name.eq_ignore_ascii_case("show")`).

We'll keep commands case-sensitive (lowercase only, like most shells). **Undo the experiment.**
The thing to remember: *a function can only return a borrow of something that outlives the
function call*, which in practice means something that came in through a parameter, or a
`'static` literal.

---

## Step 3 — Commands with inline arguments

Now let's use the parser in the loop. `show`, `update` and `delete` need exactly one argument, a
customer id. That's worth a helper, and the helper teaches the second kind of slice: `&[T]`.

> 🟢 **FOLLOW ALONG**: add this below `parse_input`.

```rust
/// Reads exactly one argument as a customer id.
fn parse_id(args: &[&str]) -> Option<u32> {
    match args {
        [raw] => raw.parse().ok(),
        _ => None,
    }
}
```

What's new here:

- **`&[&str]`** is a *slice of string slices*: a borrowed view of some `&str`s laid out next to
  each other. The caller will have a `Vec<&str>`, but `parse_id` doesn't care whether the items
  live in a `Vec`, an array or anything else contiguous. It only needs to read them.
- **Slice patterns.** `match` can look at the *shape* of a slice. `[raw]` matches a slice of
  exactly one element and binds it to `raw`. `[]` would match an empty slice, and `[first, ..]`
  one or more. Everything else falls to `_`. So `show`, `show 1 2` and `show abc` all get `None`.
- **`raw.parse().ok()`**: `parse()` returns a `Result` (you met it in Lab 07: `Ok(id)` or
  `Err(_)`). `.ok()` turns that into an `Option`, keeping the value and throwing the error away.
  The target type `u32` is inferred from the return type `Option<u32>`.

Two levels of borrowing, drawn:

```text
input: String          s h o w ␣ 4 2 \n
                                 ▲
args: Vec<&str>   [ (ptr, len) ──┘ ]       ← owned by your loop
                    ▲
&args: &[&str]  ────┘ (ptr, len = 1)       ← what parse_id receives
```

> 🟢 **FOLLOW ALONG**: in `main`, parse the line once at the top of the loop body, then match on
> the command name. Replace your `match input.trim() {` line with:

```rust
        let (command, args) = parse_input(&input);

        match command {
```

Your `"" => continue`, `"help"`, `"version"`, `"quit" | "exit"`, `"add"`, `"list"`, `"count"` and
`"normalize"` arms stay exactly as they are. Rewrite the `show` arm so it reads the id from the
arguments instead of prompting:

```rust
            "show" => match parse_id(&args) {
                Some(id) => match store.find(id) {
                    Some(customer) => {
                        println!("{}", customer.summary());
                        if !customer.has_phone() {
                            println!("(no phone on file)");
                        }
                    }
                    None => println!("No customer with id {id}."),
                },
                None => println!("Usage: show <id>"),
            },
```

The body of `Some(customer)` is the one you wrote in Lab 07. Only the source of the id changed,
and the old `Invalid id: …` message is replaced by the usage line.

Look at the two `&`s you just wrote, because neither type matches the parameter exactly:

- `parse_input(&input)`: `&input` is a `&String`, but `parse_input` wants `&str`.
- `parse_id(&args)`: `&args` is a `&Vec<&str>`, but `parse_id` wants `&[&str]`.

Both compile because of **deref coercion**. `String` knows how to act as a `str` (it implements
`Deref<Target = str>`), and `Vec<T>` knows how to act as a `[T]`. When the types don't match,
the compiler is allowed to apply that conversion to a reference automatically. It costs nothing:
it builds a `(ptr, len)` from the `(ptr, len, cap)` it already has.

Also notice that you no longer need `.trim()`. `split_whitespace` ignores the trailing newline
for you.

> 🔵 **YOUR TURN (small)**: convert `update` and `delete` the same way.
>
> - `update 2` finds customer 2 and then runs your existing prompts (`Name (blank to keep): `,
>   `Email (blank to keep): `, `Phone (blank to keep): ` from Lab 07's Your Turn, plus whatever
>   Lab 08 added). Only the id source changes.
> - `delete 2` deletes and prints `Deleted customer #2 (Grace Hopper)` as before.
> - `update` / `delete` with a missing, non-numeric or extra argument print
>   `Usage: update <id>` / `Usage: delete <id>`.
> - The `Customer id: ` prompt is gone from all three commands.

Then update `print_help` so users can discover the new syntax:

```rust
fn print_help() {
    println!("Commands:");
    println!("  add            add a customer");
    println!("  list           list all customers");
    println!("  count          show how many customers there are");
    println!("  show <id>      show one customer");
    println!("  update <id>    update a customer");
    println!("  delete <id>    delete a customer");
    println!("  normalize      lowercase all email addresses");
    println!("  version        show the version");
    println!("  help           show this help");
    println!("  quit           exit the CRM");
}
```

> 🟢 **FOLLOW ALONG**: add a test for `parse_id`. This one also shows that arrays coerce to slices
> (`&["7"]` is a `&[&str; 1]`, an array, which coerces to `&[&str]`):

```rust
    #[test]
    fn parse_id_accepts_exactly_one_number() {
        assert_eq!(parse_id(&["7"]), Some(7));
        assert_eq!(parse_id(&[]), None);
        assert_eq!(parse_id(&["seven"]), None);
        assert_eq!(parse_id(&["7", "8"]), None);
    }
```

> 🟡 **EXPERIMENT**: predict, then try it. Right after `let (command, args) = parse_input(&input);`
> add `input.clear();` (as if you wanted to reuse the buffer early).

```text
error[E0502]: cannot borrow `input` as mutable because it is also borrowed as immutable
   --> src/main.rs:213:9
    |
212 |         let (command, args) = parse_input(&input);
    |                                           ------ immutable borrow occurs here
213 |         input.clear();
    |         ^^^^^^^^^^^^^ mutable borrow occurs here
214 |
215 |         match command {
    |               ------- immutable borrow later used here
```

This is the Lab 07 rule (many readers XOR one writer), but look at *where* the reader is:
`command` is a `&str` returned by a function, and the compiler still knows it's a borrow of
`input`. That's the price and the promise of zero-copy: as long as `command` and `args` are in
use, `input` is frozen. Remove `input.clear();`.

Commit this working state:

```bash
git add .
git commit -m "Add zero-copy command parser"
```

---

## Step 4 — UTF-8, and a panic the compiler can't catch

Let's add initials to `show`. "Ada Lovelace" → "AL". The obvious approach takes the first byte of
each word:

> 🟢 **FOLLOW ALONG**: add this function. It has a bug, and you're writing it anyway.

```rust
/// First letter of each word, uppercased. "Ada Lovelace" -> "AL".
/// FIRST ATTEMPT: slices bytes. Has a bug we're about to find.
fn initials(name: &str) -> String {
    let mut result = String::new();
    for word in name.split_whitespace() {
        result.push_str(&word[0..1]);
    }
    result.to_uppercase()
}
```

And print it in the `show` arm, under the summary:

```rust
                Some(id) => match store.find(id) {
                    Some(customer) => {
                        println!("{}", customer.summary());
                        if !customer.has_phone() {
                            println!("(no phone on file)");
                        }
                        println!("  Initials: {}", initials(&customer.name));
                    }
                    None => println!("No customer with id {id}."),
                },
```

Add two tests:

```rust
    #[test]
    fn initials_of_ascii_name() {
        assert_eq!(initials("Ada Lovelace"), "AL");
    }

    #[test]
    fn initials_of_non_ascii_name() {
        assert_eq!(initials("Zoë Ångström"), "ZÅ");
    }
```

> 🟡 **EXPERIMENT**: predict what `cargo test initials` does. It compiles. Does it pass?

```text
running 2 tests
test tests::initials_of_ascii_name ... ok
test tests::initials_of_non_ascii_name ... FAILED

failures:

---- tests::initials_of_non_ascii_name stdout ----

thread 'tests::initials_of_non_ascii_name' (383789) panicked at src/main.rs:103:30:
end byte index 1 is not a char boundary; it is inside 'Å' (bytes 0..2 of string)
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

(The number in brackets is a thread id, and the line number is wherever `&word[0..1]` sits in your
file. Both will differ.)

Now do it for real. `cargo run`, add a customer with the name `Zoë Ångström`, and `show` them:

```text
crm> add
Name: Zoë Ångström
Email: zoe@example.se
Phone: 
Added customer #2
crm> show 2
#2 Zoë Ångström <zoe@example.se> 
(no phone on file)

thread 'main' (596247) panicked at src/main.rs:120:30:
end byte index 1 is not a char boundary; it is inside 'Å' (bytes 0..2 of string)
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

The whole CRM is gone, along with every customer you'd typed in. One customer with a Scandinavian
name took down the application.

**Why did this compile?** Because the types are fine. `&word[0..1]` asks for bytes 0 to 1 of a
`str`, and the compiler can't know what text `word` will hold at runtime. For `"Ada"` it's
perfectly valid; for `"Ångström"`, byte 1 is the middle of `Å`. What Rust *does* guarantee is that
it will never hand you half a character: a `&str` must always be valid UTF-8, so instead of
producing garbage, it **panics**. That's memory safety, not correctness. Correctness is your job.

Panics like this have a family resemblance. Indexing (`v[i]`, `s[a..b]`) panics when the
runtime data doesn't fit. Every one of those operations has a non-panicking twin that returns an
`Option`:

| Panics on bad data | Returns `Option` instead |
|---|---|
| `&s[0..1]` | `s.get(0..1)` |
| `v[10]` | `v.get(10)` |
| `&v[3..8]` | `v.get(3..8)` |

And for text there are tools that never land in the middle of a character:

| You want | Use |
|---|---|
| The characters | `s.chars()` (yields `char`, each a Unicode *scalar value*, 4 bytes) |
| Characters with byte positions | `s.char_indices()` |
| The position of something | `s.find('@')` (always a char boundary) |
| Words | `s.split_whitespace()`, `s.split(',')` |
| "Is this index safe to slice at?" | `s.is_char_boundary(i)` |

> 🟡 **EXPERIMENT**: in a scratch test, try `assert_eq!("Ångström".get(0..1), None);` and
> `assert_eq!("Ångström".get(0..2), Some("Å"));`. Both pass. `get` is the checked version.

One more honest caveat: a `char` isn't always what a human calls "a letter". `"é"` can be stored
as one `char` (`é`) or as two (`e` + a combining accent), and a flag emoji is two `char`s. Going
from chars to "user-perceived characters" (grapheme clusters) needs the `unicode-segmentation`
crate. For initials in a CRM, `chars()` is the right trade-off.

**Leave the failing test in place.** Fixing `initials` is Your Turn 2. Don't add non-ASCII
customers in the meantime.

---

## Step 5 — Slices of anything: `&[T]`

`CustomerStore::all()` currently returns `&Vec<Customer>`. Think about what that promises the
caller: "here is my `Vec`". The caller can ask for its `capacity()`, and the signature ties the
store to *being* a `Vec` forever. What the caller actually needs is "a run of customers I can read".
That's exactly what `&[Customer]` says.

```text
store.customers: Vec<Customer>        heap
┌──────────────┐
│ ptr  ────────┼──────────────▶  [ Customer #1 | Customer #2 | Customer #3 | (spare) ]
│ len  = 3     │                   ▲
│ cap  = 4     │                   │
└──────────────┘                   │
all(): &[Customer] { ptr ──────────┘, len 3 }
```

A slice reference like this is called a **fat pointer**: a pointer plus a length. `&str` is the
same thing for text. In fact `str` is basically `[u8]` with a "valid UTF-8" guarantee.

> 🟢 **FOLLOW ALONG**: change the return type and nothing else.

```rust
    fn all(&self) -> &[Customer] {
        &self.customers
    }
```

`&self.customers` is a `&Vec<Customer>`, and deref coercion turns it into `&[Customer]` for the
return. Run `cargo check`: your `list` arm (`for customer in store.all()`) compiles unchanged,
because you can loop over a `&[T]` exactly like a `&Vec<T>`.

> 🟡 **EXPERIMENT**: slices can be sliced. Predict what happens with only two customers, then
> temporarily change your `list` loop to show "the first five":

```rust
                for customer in &store.all()[0..5] {
```

Run it, add two customers, then `list`:

```text
crm> list

thread 'main' (390456) panicked at src/main.rs:187:45:
range end index 5 out of range for slice of length 2
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Same family as Step 4: a range that doesn't fit the runtime data. A slice range is only valid if
`start <= end <= len`. You'll write a version that can't panic in Your Turn 3. **Undo the change.**

### Why good APIs take `&str` and `&[T]`

The same reasoning applies to *parameters*. Your `email_exists` already takes `email: &str`.

> 🟡 **EXPERIMENT**: change it to `fn email_exists(&self, email: &String) -> bool` and add this
> test. Predict which line fails.

```rust
    #[test]
    fn email_exists_finds_existing_email() {
        let mut store = CustomerStore::new();
        store.add(String::from("Ada"), String::from("ada@example.com"), String::new());
        assert!(store.email_exists("ada@example.com"));
    }
```

```text
error[E0308]: mismatched types
   --> src/main.rs:329:36
    |
329 |         assert!(store.email_exists("ada@example.com"));
    |                       ------------ ^^^^^^^^^^^^^^^^^ expected `&String`, found `&str`
    |                       |
    |                       arguments to this method are incorrect
    |
    = note: expected reference `&String`
               found reference `&'static str`
```

(Depending on how you wrote the body, you may also get an `E0277` *can't compare `String` with
`&String`* inside `email_exists`.)

A `&String` parameter accepts only a borrowed `String`. A `&str` parameter accepts a borrowed
`String` (via deref coercion), a literal, a slice of a bigger string, and the `&str`s from
`parse_input`. Coercion only goes one way: `&String` → `&str` is free, but `&str` → `&String`
would need a heap allocation, so the compiler won't do it silently. Clippy knows this rule too:
it has a lint (`ptr_arg`) that flags `&String` and `&Vec<T>` parameters.

**Put `email: &str` back.** Keep the test; it's a good one.

> **Rule of thumb:** take the most general borrowed form: `&str` rather than `&String`, and
> `&[T]` rather than `&Vec<T>`. Return owned `String`/`Vec<T>` when you *create* something new
> (`initials` builds new text, so it returns `String`). Return `&str`/`&[T]` when you *point
> into* something that already exists (`parse_input`, `all`).

---

## ▶️ Run It

```bash
cargo run
```

Try the new syntax, including the usage errors:

```text
add
show 1
show
show one
show 1 2
update 2
delete 2
list
frobnicate now
```

## ✅ Expected Result

Your Lab 08 messages may be worded differently. The structure should match:

```text
Rust CRM v0.1.0
Type 'help' for a list of commands.
crm> add
Name: Ada Lovelace
Email: ada@example.com
Phone: 555-0100
Added customer #1
crm> add
Name: Grace Hopper
Email: grace@navy.mil
Phone: 555-0199
Added customer #2
crm> show
Usage: show <id>
crm> show 1
#1 Ada Lovelace <ada@example.com> 555-0100
  Initials: AL
crm> show one
Usage: show <id>
crm> show 1 2
Usage: show <id>
crm> show 7
No customer with id 7.
crm> update
Usage: update <id>
crm> update 2
Name (blank to keep): 
Email (blank to keep): GRACE@navy.mil
Phone (blank to keep): 
Updated customer #2
crm> delete 2
Deleted customer #2 (Grace Hopper)
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
crm> frobnicate now
Unknown command: frobnicate. Type 'help' for a list of commands.
```

Notice the last line: the unknown-command message now shows only the command word, because
`other` binds to `command`, not to the whole line.

`cargo test` should show every test passing **except** `initials_of_non_ascii_name`. That one is
yours to fix.

## 🧠 Understand It

**Owned vs borrowed, in one table.**

| | `String` | `&str` | `Vec<T>` | `&[T]` |
|---|---|---|---|---|
| Fields | ptr, len, cap | ptr, len | ptr, len, cap | ptr, len |
| Owns its data? | yes | no | yes | no |
| Can grow? | yes (`push_str`) | no | yes (`push`) | no |
| Freed when it goes out of scope? | yes | no (the owner frees it) | yes | no |
| Created by | `String::from`, `format!`, `to_string`, `to_lowercase` | `&s[..]`, literals, `split_*`, `trim` | `Vec::new`, `vec![]`, `collect` | `&v[..]`, `&v`, arrays |

**Deref coercion** is the reason `&String → &str` and `&Vec<T> → &[T]` feel invisible. It only
happens where the compiler already knows the target type (a function argument, a typed `let`, a
return value), and only from "owner" to "view". It never allocates.

**Why `parse_input` is cheap.** For `"update 3\n"` it allocates exactly one small buffer, the
`Vec` holding one `(ptr, len)` pair. An owned version would allocate the `Vec` *plus* one `String`
per word and copy every byte. In a REPL nobody will notice the difference. In Lab 27, when the same
idea parses HTTP requests thousands of times a second, it matters, and Rust's web libraries are
built on exactly this "borrow the request buffer" design.

**The borrow is real, even though it's invisible.** The E0502 experiment in Step 3 shows that
the compiler tracks `command` and `args` back to `input`. The next lab gives that tracking a name
(lifetimes) and shows you how to write it down.

**Slice patterns** make argument handling readable: `[raw]`, `[]`, `[first, ..]`,
`[first, second]`. They match on *length and shape*, and the compiler checks they cover every
case when you include a `_` (or the right combination of patterns).

**Bytes, chars and graphemes.** `len()` = bytes. `chars().count()` = Unicode scalar values.
What a human calls "a character" may be several `char`s. Byte ranges are only safe when they
come from something that guarantees boundaries (`find`, `char_indices`, `split_*`), or when you
use `get()`.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1**: in `parse_input`, change the return type to `(String, Vec<String>)` and fix
> the body so it compiles (you'll need `.to_string()` on `name` and on each word). Which call sites
> in `main` break, and why? (Hint: `match command { "help" => ...` compares a `String` with `&str`
> literals.) What did you have to add to make them compile again? Undo it afterwards.

> 🟡 **EXPERIMENT 2**: in a scratch test, print `"Zoë".len()`, `"Zoë".chars().count()` and
> `"Zoë".to_uppercase()`. Then try `"ß".to_uppercase()`. How many `char`s does it return? What does
> that tell you about `to_uppercase()` on a single `char` returning an iterator, not a `char`?

> 🟡 **EXPERIMENT 3**: in `parse_id`, replace the slice pattern with `args.first()`. What type does
> `args.first()` return? (Look at the error or hover it in VS Code: it's `Option<&&str>`.) Why two
> `&`s? Which inputs does the `first()` version accept that the slice-pattern version rejects?

## 👩🏽‍💻 Your Turn

Three tasks. Lab 10 builds on all three, so do them (or copy them from `solutions.md`).

### Your Turn 1 — `email_domain`

> 🔵 **YOUR TURN**: write a free function
> `fn email_domain(email: &str) -> Option<&str>`
> that returns the part of an email address after the `@`, **borrowed from `email`**.

Requirements:

- [ ] Signature exactly `fn email_domain(email: &str) -> Option<&str>`
- [ ] No allocation: don't use `to_string`, `String::from`, `format!` or `to_lowercase` inside it.
      The domain is returned exactly as written (`"EXAMPLE.com"` stays `"EXAMPLE.com"`).
- [ ] `"ada@example.com"` → `Some("example.com")`
- [ ] `"ada.example.com"` (no `@`) → `None`
- [ ] `"ada@"` (nothing after `@`) → `None`
- [ ] `""` → `None`
- [ ] `"zoë@bücher.de"` → `Some("bücher.de")`, and it must never panic
- [ ] Tests for all of the above
- [ ] `show <id>` prints a `Domain:` line just above `Initials:` (after the summary and the
      `(no phone on file)` line, if any). Use `(none)` when there's no domain:

```text
crm> show 1
#1 Ada Lovelace <ada@example.com> 555-0100
  Domain:   example.com
  Initials: AL
crm> show 6
#6 Linus Torvalds <linus> 555-0123
  Domain:   (none)
  Initials: LT
```

(Real email validation comes in Lab 12. This function only splits.)

### Your Turn 2 — UTF-8-safe `initials`

> 🔵 **YOUR TURN**: rewrite `initials` so it works for any name.

- [ ] Signature unchanged: `fn initials(name: &str) -> String`
- [ ] No byte-range slicing (`[..]`) anywhere in it
- [ ] `initials_of_non_ascii_name` passes: `"Zoë Ångström"` → `"ZÅ"`
- [ ] New test: `"grace brewster hopper"` → `"GBH"`
- [ ] New test: `"   "` (only spaces) → `""`
- [ ] `show` on a customer named `Zoë Ångström` prints `Initials: ZÅ` and the CRM keeps running

### Your Turn 3 — Pages: `page()` and `list [page]`

> 🔵 **YOUR TURN**: add pagination to the store and to `list`.

Add a constant at the top of the file:

```rust
const PAGE_SIZE: usize = 5;
```

Then implement:

```rust
impl CustomerStore {
    fn page(&self, page: usize, per_page: usize) -> &[Customer]
}
```

Requirements for `page`:

- [ ] Pages are **1-based**: `page(1, 5)` is customers 1–5 (by position), `page(2, 5)` is 6–10
- [ ] The last page may be partial: with 7 customers, `page(2, 5)` has 2 customers
- [ ] **Never panics.** Out of range returns an empty slice: `page(3, 5)` with 7 customers,
      `page(0, 5)`, `page(1, 0)`, `page(usize::MAX, 5)`, and any page of an empty store
- [ ] Returns a slice of the store's own customers. No `clone`, no new `Vec`
- [ ] Tests for full page, partial page and every out-of-range case above (a small test helper
      `fn store_with(n: u32) -> CustomerStore` that adds `n` customers will save you typing)

Requirements for the `list` command:

- [ ] `list` shows page 1; `list 2` shows page 2, with `PAGE_SIZE` customers per page
- [ ] After the customers, print `Page <n> of <total>`
- [ ] Empty store: `No customers yet.` (as before)
- [ ] Page past the end: `No customers on page <n>.`
- [ ] `list 0`, `list two`, `list 1 2`: `Usage: list [page]`
- [ ] The help line becomes `  list [page]    list customers, 5 per page` (use `PAGE_SIZE` in the
      `println!` rather than typing 5)

With six customers it looks like this:

```text
crm> list
#1 Ada Lovelace <ada@example.com> 555-0100
#2 Zoë Ångström <zoe@example.se> 
#3 Grace Hopper <grace@navy.mil> 555-0199
#4 Alan Turing <alan@bletchley.uk> 555-0142
#5 Katherine Johnson <katherine@nasa.gov> 555-0161
Page 1 of 2
crm> list 2
#6 Linus Torvalds <linus> 555-0123
Page 2 of 2
crm> list 3
No customers on page 3.
crm> list 0
Usage: list [page]
```

Finally:

- [ ] `cargo test` passes (all tests, including the one that failed in Step 4)
- [ ] `cargo clippy` shows no new warnings

## 💡 Hint

> 💡 **HINT**: all three tasks are about getting **positions you're allowed to slice at**. For
> `email_domain`, something in Step 4's tool table gives you a position that is guaranteed to be a
> char boundary. For `initials`, you never need a position at all. For `page`, compute the range
> first, check it, *then* slice.

<details><summary>Hint 2: email_domain</summary>

`email.find('@')` returns `Option<usize>`: the byte index where `@` starts. `@` is ASCII, so it's
exactly one byte, which means `at + 1` is also a char boundary. `&email[at + 1..]` is "from there to
the end". Alternatively, look up `str::split_once` in the docs.

</details>

<details><summary>Hint 3: initials</summary>

`word.chars().next()` gives you `Option<char>`: the first character of the word, however many
bytes it takes. `char::to_uppercase()` returns an *iterator* of `char`s (because `ß` uppercases
to `SS`), so loop over it and `push` each one onto your `String`. Words from `split_whitespace`
are never empty, but `next()` still returns an `Option`, so you have to handle `None`.

</details>

<details><summary>Hint 4: page</summary>

`start = (page - 1) * per_page` (check `page == 0` first, or `page - 1` underflows and panics in
debug builds). If `start >= len`, return `&[]`. Otherwise `end` is the smaller of
`start + per_page` and `len` (`usize::min`). For `usize::MAX`-sized inputs, plain `*` and `+` can
overflow, so look at `saturating_mul` / `saturating_add`. Total pages:
`len.div_ceil(PAGE_SIZE)`.

For `list`, a helper `fn parse_page(args: &[&str]) -> Option<usize>` with slice patterns
(`[]` → page 1, `[raw]` → parse it, anything else → `None`) keeps the arm short.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. Draw a `String` and a `&str` that points into it. Which fields does each have, and why does
   `&str` have no capacity?
2. In `parse_input("delete 3\n")`, how many bytes of text are copied? What *is* allocated?
3. Why does `name[0]` not compile, while `&name[0..1]` compiles but can panic?
4. Name two ways to get the first character of `"Ångström"` that can't panic.
5. Why does `fn all(&self) -> &[Customer]` make a better API than `-> &Vec<Customer>`? What
   conversion lets you return `&self.customers` from it?
6. Why couldn't `parse_input` lowercase the input and still return `&str`s? Give two fixes and
   their costs.
7. `initials` returns `String`, but `email_domain` returns `Option<&str>`. Why the difference?

Then verify:

```bash
cargo fmt --check && cargo clippy && cargo test
```

## Git Commit

```bash
git add .
git commit -m "Parse command arguments with string slices"
git tag lab-09
git push && git push --tags
```

Compare the stages: `git diff lab-08 lab-09 -- src/main.rs` shows every `&str` you introduced.

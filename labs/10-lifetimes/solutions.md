# Lab 10 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. For lifetime exercises, the reasoning
> matters more than the code: make sure you can say **which owner each returned reference points
> into**.

---

## Your Turn 1 — `ParsedCommand::arg`

```rust
impl<'a> ParsedCommand<'a> {
    /// The argument at `index`. The result borrows from the input line,
    /// not from this `ParsedCommand`, so it may outlive it.
    fn arg(&self, index: usize) -> Option<&'a str> {
        self.args.get(index).copied()
    }
}
```

**Why `'a` and not the elided form.** There are two different borrows in play:

```text
line: String              s e a r c h ␣ a d a       ← owner of the text ('a)
                                        ▲
parsed: ParsedCommand<'a>               │            ← a separate value, owned by the block
  args: Vec<&'a str> ─▶ [ &'a str ──────┘ ]
          ▲
&self ────┘  (a borrow of `parsed`, lasting only as long as the method call needs it)
```

If you write `fn arg(&self, index: usize) -> Option<&str>`, elision rule 3 gives the output the
lifetime of **`&self`**, so the compiler treats the result as borrowed from the `ParsedCommand`.
The test drops `parsed` at the end of the block while `term` is still in use:

```text
error[E0597]: `parsed` does not live long enough
   --> src/main.rs:498:13
    |
496 |         let term = {
    |             ---- borrow later stored here
497 |             let parsed = parse_command(&line);
    |                 ------ binding `parsed` declared here
498 |             parsed.arg(0)
    |             ^^^^^^ borrowed value does not live long enough
499 |         }; // `parsed` is dropped here, `line` is still alive
    |         - `parsed` dropped here while still borrowed
```

But the `&str` actually points into `line`, which is still alive. The elided signature
**under-promised**: it was more restrictive than the truth. Writing `Option<&'a str>` names the
real owner, the `'a` the `ParsedCommand` itself was built with, and the test compiles.

This is the one case in this lab where you *must* write a lifetime that elision wouldn't pick:
the output borrows from something other than `self`, and the only way to say so is to use the
struct's own lifetime parameter.

**The body.** `self.args.get(index)` returns `Option<&&'a str>`: a reference to the slot in the
`Vec`, which holds a `&'a str`. `.copied()` copies the inner `&'a str` out of the slot (references
are `Copy`), giving `Option<&'a str>`, with no reference to the `Vec` left over. `get` instead of
`[index]` means an out-of-range index is `None`, not a panic.

**The `search` arm:**

```rust
            "search" => match parsed.arg(0) {
                Some(term) => {
                    let results = store.search(term);
                    if results.is_empty() {
                        println!("No customers match '{term}'.");
                    }
                    for customer in results {
                        println!("{}", customer.summary());
                    }
                }
                None => println!("Usage: search <term>"),
            },
```

Same behaviour as the slice-pattern version: the first argument, extras ignored.

**One-sentence answer:** "`arg` returns a slice of the original input line, so it lives as long as
the line (`'a`), not as long as the `ParsedCommand` that happened to hand it over."

---

## Your Turn 2 — `display_name`

The first attempt:

```text
error[E0106]: missing lifetime specifier
   --> src/main.rs:148:45
    |
148 | fn display_name(name: &str, email: &str) -> &str {
    |                       ----         ----     ^ expected named lifetime parameter
    |
    = help: this function's return type contains a borrowed value, but the signature does not say whether it is borrowed from `name` or `email`
help: consider introducing a named lifetime parameter
    |
148 | fn display_name<'a>(name: &'a str, email: &'a str) -> &'a str {
    |                ++++        ++              ++          ++
```

**Which rule failed?** Rule 1 gave `name` and `email` two different lifetimes. Rule 2 needs
*exactly one* input lifetime, and there are two. Rule 3 needs `self`, and there isn't one. So the
compiler refuses to guess, and the `help:` line says exactly why: it can't tell which input the
output borrows from.

```rust
/// The name to show for a customer: their name, or their email if the name is blank.
fn display_name<'a>(name: &'a str, email: &'a str) -> &'a str {
    if name.trim().is_empty() { email } else { name }
}
```

**What the annotation promises.** One name, `'a`, on all three references means "the result is
valid only in a region where **both** inputs are valid". At each call site, the compiler picks
`'a` as the overlap of the two borrows. The function might return either input (that's decided at
runtime), so the signature has to be safe for both. Here, both come from the same `Customer`, so
the overlap is "while `customer` is alive", and that's plenty.

(This time the compiler's suggestion was right. Compare Experiment 2, where it wasn't.)

**Using it in `delete`:**

```rust
                Some(id) => match store.remove(id) {
                    Some(customer) => {
                        println!(
                            "Deleted customer #{} ({})",
                            customer.id,
                            display_name(&customer.name, &customer.email)
                        )
                    }
                    None => println!("No customer with id {id}."),
                },
```

`customer` is the **owned** `Customer` returned by `remove` (Lab 08). We borrow two of its fields
for one `println!`, and it's dropped at the end of the arm. The borrows end well before that.

**Tests:**

```rust
    #[test]
    fn display_name_prefers_the_name() {
        assert_eq!(display_name("Ada Lovelace", "ada@example.com"), "Ada Lovelace");
    }

    #[test]
    fn display_name_falls_back_to_email() {
        assert_eq!(display_name("", "ada@example.com"), "ada@example.com");
        assert_eq!(display_name("   ", "ada@example.com"), "ada@example.com");
    }
```

---

## Your Turn 3 — `first_by_domain` and the colleague note

```rust
    /// The first customer whose email domain equals `domain`, ignoring ASCII case.
    fn first_by_domain<'a>(&'a self, domain: &str) -> Option<&'a Customer> {
        for customer in &self.customers {
            if let Some(d) = email_domain(&customer.email)
                && d.eq_ignore_ascii_case(domain)
            {
                return Some(customer);
            }
        }
        None
    }
```

- `email_domain` borrows from `customer.email`, which is borrowed from `self`: a borrow of a
  borrow, all inside `'a`.
- `eq_ignore_ascii_case` compares without allocating. Lowercasing both sides would also be
  correct, but it would create two `String`s per customer.
- `if let ... && ...` is a **let chain** (edition 2024): "if this pattern matches *and* this
  condition holds". A nested `if let { if { } }` is also correct, and Clippy suggests collapsing it
  (`collapsible_if`).
- As with `search`, `domain` has no `'a`: the result is never borrowed from it.

**The `add` arm:**

```rust
            "add" => {
                let name = prompt("Name: ");
                let email = prompt("Email: ");
                if store.email_exists(&email) {
                    println!("A customer with email {email} already exists.");
                } else {
                    let phone = prompt("Phone: ");
                    // Look first, while we only need a shared borrow of the store.
                    // The note is an owned String, so it holds no borrow of `store`.
                    let mut note = None;
                    if let Some(domain) = email_domain(&email)
                        && let Some(other) = store.first_by_domain(domain)
                    {
                        note = Some(format!("Note: #{} {} also uses {domain}.", other.id, other.name));
                    }
                    let id = store.add(name, email, phone);
                    println!("Added customer #{id}");
                    if let Some(note) = note {
                        println!("{note}");
                    }
                }
            }
```

**The first attempt most people write** keeps the reference across the `add`:

```rust
                    let colleague = match email_domain(&email) {
                        Some(domain) => store.first_by_domain(domain),
                        None => None,
                    };
                    let id = store.add(name, email, phone);
                    println!("Added customer #{id}");
                    if let Some(other) = colleague {
                        println!("Note: #{} {} uses the same email domain.", other.id, other.name);
                    }
```

```text
error[E0502]: cannot borrow `store` as mutable because it is also borrowed as immutable
   --> src/main.rs:279:30
    |
276 |                         Some(domain) => store.first_by_domain(domain),
    |                                         ----- immutable borrow occurs here
...
279 |                     let id = store.add(name, email, phone);
    |                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
280 |                     println!("Added customer #{id}");
281 |                     if let Some(other) = colleague {
    |                                          --------- immutable borrow later used here
```

Reasoning: `colleague` is `Option<&'a Customer>` with `'a` tied to `store` (the signature says
so). `store.add` needs `&mut store`, and it might push onto the `Vec` and **reallocate** it
(Lab 07's picture), which would leave `colleague` pointing at freed memory. The fix isn't a
lifetime annotation. It's ending the borrow before the mutation, by turning what you need into
owned data (`format!` builds a `String`). Copying out `other.id` (a `u32`, `Copy`) and cloning
`other.name` would work too, but building the whole message is simpler.

**Why `domain: &str` (not `&'a str`) matters here.** `domain` borrows from `email`, and `email`
is **moved** into `store.add(...)` on the next line. With the correct signature, the result of
`first_by_domain` doesn't borrow from `email`, so moving `email` is fine as soon as `domain` is no
longer used. If you over-constrain to `domain: &'a str`, the compiler believes the result might
point into `email` and you get, *in addition* to the E0502 above:

```text
error[E0505]: cannot move out of `email` because it is borrowed
   --> src/main.rs:279:46
    |
268 |                 let email = prompt("Email: ");
    |                     ----- binding `email` declared here
...
275 |                     let colleague = match email_domain(&email) {
    |                                                        ------ borrow of `email` occurs here
...
279 |                     let id = store.add(name, email, phone);
    |                                              ^^^^^ move out of `email` occurs here
280 |                     println!("Added customer #{id}");
281 |                     if let Some(other) = colleague {
    |                                          --------- borrow later used here
```

(It ends with a `help:` suggesting `email.clone()`. That would compile, but it treats the symptom:
the signature is what's wrong.)

Same lesson as `search`'s `term`: an extra `'a` on an input that the result doesn't borrow from
makes life harder for every caller.

**Never its own colleague.** Because we look *before* `store.add`, the new customer isn't in the
store yet, so it can't match itself.

**Test:**

```rust
    #[test]
    fn first_by_domain_ignores_case_and_returns_first_match() {
        let mut store = CustomerStore::new();
        store.add(String::from("Ada"), String::from("ada@example.com"), String::new());
        store.add(String::from("Bob"), String::from("bob@Example.COM"), String::new());
        let found = store.first_by_domain("EXAMPLE.com").map(|c| c.id);
        assert_eq!(found, Some(1));
        assert!(store.first_by_domain("navy.mil").is_none());
    }
```

---

## Experiment answers

**Experiment 1.** After the `for customer in results` loop, `results` has been consumed and never
used again, so the shared borrow of `store` has ended (non-lexical lifetimes, Lab 08), and
`store.normalize_emails()` compiles. The borrow lasts until its **last use**, not until the end
of the block.

**Experiment 2.** The compiler's suggestion `fn first_email_or<'a>(&self, fallback: &'a str) -> &'a str`
fixes the `fallback` branch and breaks the other one:

```text
error: lifetime may not live long enough
   --> src/main.rs:103:31
    |
101 |     fn first_email_or<'a>(&self, fallback: &'a str) -> &'a str {
    |                       --  - let's call the lifetime of this reference `'1`
    |                       |
    |                       lifetime `'a` defined here
102 |         match self.customers.first() {
103 |             Some(customer) => &customer.email,
    |                               ^^^^^^^^^^^^^^^ method was supposed to return data with lifetime `'a` but it is returning data with lifetime `'1`
```

The result can come from **either** `self` or `fallback`, so both must be tied to the output, in
the same way as `display_name`:

```rust
    fn first_email_or<'a>(&'a self, fallback: &'a str) -> &'a str {
```

**Experiment 3.** It does **not** compile:

```text
error[E0597]: `grace` does not live long enough
   --> src/main.rs:610:40
    |
609 |             let grace = Customer::new(2, String::from("Grace"), String::from("g@navy.mil"), String::new());
    |                 ----- binding `grace` declared here
610 |             winner = longer_name(&ada, &grace);
    |                                        ^^^^^^ borrowed value does not live long enough
611 |         }
    |         - `grace` dropped here while still borrowed
612 |         assert_eq!(winner.id, 1);
    |         ------------------------ borrow later used here
```

The compiler never looks at which branch runs. The signature says the result is valid for `'a`,
and `'a` must fit inside **both** borrows, so it's limited to `grace`'s shorter scope. The
`assert_eq!` is outside that. At runtime the winner happens to be `ada`, but the signature allows
`grace`, and the compiler has to accept or reject the code for *every* possible run. Fixes: move
`grace` out of the inner block, or (if it's genuinely meant to work) return something owned, such
as the winner's `id`.

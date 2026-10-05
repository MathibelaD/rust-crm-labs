# Lab 09 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Each solution explains the reasoning;
> your code doesn't have to match line for line. If your tests pass and you can explain your
> choices, you're done.

---

## Step 3 (small Your Turn): `update <id>` and `delete <id>`

Only the source of the id changes. The bodies are the ones you already had in Lab 08 (shown
here as Lab 07 left them; keep any changes Lab 08 made, such as an email-uniqueness check).

```rust
            "update" => match parse_id(&args) {
                Some(id) => match store.find_mut(id) {
                    Some(customer) => {
                        let name = prompt("Name (blank to keep): ");
                        if !name.is_empty() {
                            customer.name = name;
                        }
                        let email = prompt("Email (blank to keep): ");
                        if !email.is_empty() {
                            customer.update_email(email);
                        }
                        let phone = prompt("Phone (blank to keep): ");
                        if !phone.is_empty() {
                            customer.phone = phone;
                        }
                        println!("Updated customer #{id}");
                    }
                    None => println!("No customer with id {id}."),
                },
                None => println!("Usage: update <id>"),
            },
            "delete" => match parse_id(&args) {
                Some(id) => match store.remove(id) {
                    Some(customer) => {
                        println!("Deleted customer #{} ({})", customer.id, customer.name)
                    }
                    None => println!("No customer with id {id}."),
                },
                None => println!("Usage: delete <id>"),
            },
```

**Why it works.** Inside `update`, `customer` is a `&mut Customer` borrowed from `store`, while
`args` (still alive) borrows `input`. These are borrows of *different* owners, so they don't
conflict. `prompt` creates brand-new `String`s and doesn't touch `input`.

---

## Your Turn 1 — `email_domain`

```rust
/// The part of an email address after the '@', borrowed from `email`.
fn email_domain(email: &str) -> Option<&str> {
    match email.find('@') {
        Some(at) => {
            let domain = &email[at + 1..];
            if domain.is_empty() {
                None
            } else {
                Some(domain)
            }
        }
        None => None,
    }
}
```

**Reasoning.**

- `find('@')` returns a byte index that is *guaranteed* to be the start of a character (it found
  a `char` there). `'@'` is ASCII, so it's exactly one byte, and `at + 1` is the start of the next
  character, or the end of the string. Both are valid places to slice, so `&email[at + 1..]`
  can't panic, even for `zoë@bücher.de`.
- `&email[at + 1..]` is a range with no end: "from `at + 1` to the end". It's a view into
  `email`, which is why the return type can be `Option<&str>`. Nothing is copied.
- We can't lowercase the domain here. Lowercasing creates a new `String`, and a function can't
  return a borrow of its own local (the E0515 from Step 2). If a caller needs a case-insensitive
  comparison, it can use `eq_ignore_ascii_case` (you'll do exactly that in Lab 10).

**Alternative.** `split_once` does the find-and-slice for you and returns both halves:

```rust
fn email_domain(email: &str) -> Option<&str> {
    match email.split_once('@') {
        Some((_, domain)) if !domain.is_empty() => Some(domain),
        _ => None,
    }
}
```

(The `if` after the pattern is a *match guard*. Lab 11 covers it.) Both versions split at the
**first** `@`. That's fine for now; Lab 12 rejects addresses with more than one.

**Wiring it into `show`:**

```rust
                    Some(customer) => {
                        println!("{}", customer.summary());
                        if !customer.has_phone() {
                            println!("(no phone on file)");
                        }
                        let domain = email_domain(&customer.email).unwrap_or("(none)");
                        println!("  Domain:   {domain}");
                        println!("  Initials: {}", initials(&customer.name));
                    }
```

`unwrap_or("(none)")` works because both sides are `&str`: the borrowed domain *or* a literal.
If you first wrote a `match` with `Some(domain) => domain, None => "(none)"`, Clippy suggests
exactly this (`manual_unwrap_or`).

**Tests:**

```rust
    #[test]
    fn email_domain_returns_part_after_at() {
        assert_eq!(email_domain("ada@example.com"), Some("example.com"));
    }

    #[test]
    fn email_domain_is_none_without_at_or_domain() {
        assert_eq!(email_domain("ada.example.com"), None);
        assert_eq!(email_domain("ada@"), None);
        assert_eq!(email_domain(""), None);
    }

    #[test]
    fn email_domain_handles_non_ascii() {
        assert_eq!(email_domain("zoë@bücher.de"), Some("bücher.de"));
    }
```

---

## Your Turn 2 — UTF-8-safe `initials`

```rust
/// First letter of each word, uppercased. "Zoë Ångström" -> "ZÅ".
fn initials(name: &str) -> String {
    let mut result = String::new();
    for word in name.split_whitespace() {
        if let Some(first) = word.chars().next() {
            for upper in first.to_uppercase() {
                result.push(upper);
            }
        }
    }
    result
}
```

**Reasoning.**

- `word.chars().next()` asks for the first **character**, not the first byte. However many bytes
  `Å` takes, you get the whole thing as one `char`. There's no byte position anywhere, so there's
  nothing that can land mid-character.
- `if let Some(first) = ... { }` is shorthand for a `match` with one interesting arm and an empty
  `None => {}` arm. If you wrote the full `match`, it's correct, and Clippy will suggest this
  shorter form (`single_match`). Lab 11 covers `if let` properly.
- `char::to_uppercase()` returns an iterator because some characters uppercase to *several*
  characters (`'ß'` → `"SS"`). Looping and pushing handles that correctly.
- We uppercase each `char` as we go instead of calling `result.to_uppercase()` at the end. Both
  work. This version avoids building a second `String`.
- Returning `String` (owned) is right here: the initials are **new text** that didn't exist
  anywhere before, so there's nothing to borrow from. Compare `email_domain`, whose answer is
  already sitting inside its input.

**Tests:**

```rust
    #[test]
    fn initials_uppercases_lowercase_names() {
        assert_eq!(initials("grace brewster hopper"), "GBH");
    }

    #[test]
    fn initials_of_blank_name_is_empty() {
        assert_eq!(initials("   "), "");
    }
```

---

## Your Turn 3 — `page()` and `list [page]`

```rust
const PAGE_SIZE: usize = 5;
```

```rust
    fn page(&self, page: usize, per_page: usize) -> &[Customer] {
        if page == 0 || per_page == 0 {
            return &[];
        }
        let customers = self.all();
        let start = (page - 1).saturating_mul(per_page);
        if start >= customers.len() {
            return &[];
        }
        let end = start.saturating_add(per_page).min(customers.len());
        &customers[start..end]
    }
```

**Reasoning, line by line.**

- `page == 0` is checked first because `page - 1` on a `usize` 0 would underflow (a panic in
  debug builds, as you saw with `u32::MAX + 1` in Lab 02).
- `&[]` is an empty slice. It has no owner to worry about: an empty array literal is a constant,
  so a reference to it is valid for as long as anyone needs, and it coerces to `&[Customer]`.
- `saturating_mul` / `saturating_add` stop at `usize::MAX` instead of overflowing, so
  `page(usize::MAX, 5)` produces a huge `start`, which the next check turns into `&[]`.
- After the checks we know `start < len` and `end <= len`, so `&customers[start..end]` **cannot**
  panic. That's the pattern for safe slicing: prove the range is valid, *then* index.
- It's built on `self.all()`. Since `list` no longer calls `all()`, this also keeps `all()` in use
  (otherwise `cargo check` warns that it's never used). Lab 10 and Challenge A use it too.

A shorter alternative uses the checked `get`, which returns `None` instead of panicking:

```rust
        let start = (page - 1).saturating_mul(per_page);
        let end = start.saturating_add(per_page).min(self.customers.len());
        self.customers.get(start..end).unwrap_or(&[])
```

(When `start > end`, `get` returns `None`.) Both are fine. The first one spells out the reasoning.

**Parsing the page argument:**

```rust
fn parse_page(args: &[&str]) -> Option<usize> {
    match args {
        [] => Some(1),
        [raw] => match raw.parse::<usize>() {
            Ok(0) | Err(_) => None,
            Ok(page) => Some(page),
        },
        _ => None,
    }
}
```

`Ok(0) | Err(_)` combines two patterns with `|`: "zero, or not a number at all". The turbofish
`::<usize>` is needed because the result is matched straight away, before anything fixes its
type.

**The `list` arm:**

```rust
            "list" => match parse_page(&args) {
                Some(page) => {
                    let customers = store.page(page, PAGE_SIZE);
                    if store.len() == 0 {
                        println!("No customers yet.");
                    } else if customers.is_empty() {
                        println!("No customers on page {page}.");
                    } else {
                        for customer in customers {
                            println!("{}", customer.summary());
                        }
                        let pages = store.len().div_ceil(PAGE_SIZE);
                        println!("Page {page} of {pages}");
                    }
                }
                None => println!("Usage: list [page]"),
            },
```

`div_ceil` is "divide, rounding up": 6 customers / 5 per page = 2 pages. If you wrote
`(len + PAGE_SIZE - 1) / PAGE_SIZE`, that's correct too, and Clippy points you to `div_ceil`
(`manual_div_ceil`).

**Help line:**

```rust
    println!("  list [page]    list customers, {PAGE_SIZE} per page");
```

**Tests:**

```rust
    fn store_with(n: u32) -> CustomerStore {
        let mut store = CustomerStore::new();
        for i in 1..=n {
            store.add(format!("Customer {i}"), format!("c{i}@example.com"), String::new());
        }
        store
    }

    #[test]
    fn page_returns_full_and_partial_pages() {
        let store = store_with(7);
        assert_eq!(store.page(1, 5).len(), 5);
        assert_eq!(store.page(2, 5).len(), 2);
        assert_eq!(store.page(2, 5)[0].id, 6);
    }

    #[test]
    fn page_out_of_range_is_empty_not_a_panic() {
        let store = store_with(7);
        assert!(store.page(3, 5).is_empty());
        assert!(store.page(0, 5).is_empty());
        assert!(store.page(1, 0).is_empty());
        assert!(store.page(usize::MAX, 5).is_empty());
        assert!(CustomerStore::new().page(1, 5).is_empty());
    }

    #[test]
    fn parse_page_defaults_to_one() {
        assert_eq!(parse_page(&[]), Some(1));
        assert_eq!(parse_page(&["2"]), Some(2));
        assert_eq!(parse_page(&["0"]), None);
        assert_eq!(parse_page(&["two"]), None);
    }
```

---

## Experiment answers

**Experiment 1 (owned return type).** With `(String, Vec<String>)`:

- `match command { "help" => ... }` fails with E0308 (*expected `String`, found `&str`*): a
  `match` on a `String` can't use string-literal patterns. The fix is `match command.as_str()`,
  which borrows a `&str` from the `String`. You've gone full circle: allocate an owned copy, then
  borrow from it again.
- `parse_id(&args)` fails because `&Vec<String>` becomes `&[String]`, not `&[&str]`. A slice of
  `String`s and a slice of `&str`s have different layouts in memory (24-byte vs 16-byte elements),
  so no coercion exists between them.

Lesson: owned data isn't wrong, but here it cost allocations *and* made every caller more awkward.

**Experiment 2.** `"Zoë".len()` is 4, `chars().count()` is 3, `to_uppercase()` is `"ZOË"`.
`"ß".to_uppercase()` is `"SS"`: one `char` became two. That's why `char::to_uppercase` can't
return a single `char`.

**Experiment 3.** `args.first()` returns `Option<&&str>`: a reference to the first *element* of
the slice, and the element is itself a `&str`. Two layers: a borrow of the `Vec`'s slot, which
holds a borrow of the input. `match args.first() { Some(raw) => raw.parse().ok(), None => None }`
compiles (method calls auto-deref through both `&`s), but it accepts `show 1 2` and silently
ignores the `2`. The slice pattern `[raw]` says "exactly one", which is the behaviour we want.

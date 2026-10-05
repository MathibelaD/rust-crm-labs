# Lab 12 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't have to match line for
> line. If your tests pass and you can explain your choices, you're done.

---

## Your Turn 1 — Validated phone numbers

```rust
/// Blank input means "no phone". Anything else must look like a phone number.
fn parse_phone(input: &str) -> Result<Option<String>, ValidationError> {
    let phone = input.trim();
    if phone.is_empty() {
        return Ok(None);
    }

    let allowed_chars = phone
        .chars()
        .all(|c| c.is_ascii_digit() || matches!(c, ' ' | '+' | '-' | '(' | ')'));
    let digits = phone.chars().filter(|c| c.is_ascii_digit()).count();

    if allowed_chars && digits >= 7 {
        Ok(Some(phone.to_string()))
    } else {
        Err(ValidationError::InvalidPhone(phone.to_string()))
    }
}
```

In `execute`:

```rust
        // Add
            let phone = parse_phone(&prompt("Phone (optional): "))?;

        // Update
            let phone = parse_phone(&prompt("Phone (blank to keep): "))?;
```

Tests:

```rust
    #[test]
    fn blank_phone_means_no_phone() {
        assert_eq!(parse_phone("   "), Ok(None));
    }

    #[test]
    fn valid_phone_is_trimmed() {
        assert_eq!(
            parse_phone(" +1 (555) 010-0100 "),
            Ok(Some(String::from("+1 (555) 010-0100")))
        );
    }

    #[test]
    fn invalid_phones_are_rejected() {
        for input in ["call me", "555-01x0", "12345"] {
            assert_eq!(
                parse_phone(input),
                Err(ValidationError::InvalidPhone(input.to_string()))
            );
        }
    }
```

**Reasoning:**

- **`Result<Option<String>, _>`, read outside-in:** "did parsing succeed?" then "was there a
  phone?". The opposite nesting, `Option<Result<..>>`, would mean "was there input?" then "was it
  valid?", which is a legitimate design too, but then every caller has to unpack two layers
  before using `?`. With `Result` on the outside, `?` peels off the error and leaves the
  `Option`, which is exactly what `Customer.phone` wants. (When you have the other shape, `Option::transpose`
  swaps the two layers.)
- The early `return Ok(None)` makes the blank case obvious and keeps the rest of the function
  about *valid* phones.
- In `update`, `Ok(None)` doubles as "keep the current phone", which is why the existing
  `if phone.is_some() { customer.phone = phone; }` needs no change. The consequence: there's no
  way to *remove* a phone through `update`. If you want that, you'd need a third state ("clear"),
  which is a good example of a case where `Option` isn't enough and a small enum would be
  clearer (`enum PhoneChange { Keep, Clear, Set(String) }`).
- 7 digits is a deliberately loose rule. Real phone validation is hard (country codes,
  extensions); the point is to reject obvious garbage, not to implement E.164.

---

## Your Turn 2 — A colleague note with combinators

```rust
/// "Note: #1 Ada Lovelace also uses example.com." if someone already uses this domain.
fn colleague_note(store: &CustomerStore, email: &Email) -> Option<String> {
    let domain = email_domain(email.as_str())?;
    store
        .first_by_domain(domain)
        .map(|other| format!("Note: #{} {} also uses {domain}.", other.id, other.name))
}
```

(If you did Your Turn 4, the first line is `let domain = email.domain();` and needs no `?`.)

In the `Add` arm:

```rust
            let note = colleague_note(store, &email);
            let id = store.add(name, email, phone)?;
            println!("Added customer #{id}");
            if let Some(note) = note {
                println!("{note}");
            }
```

Test:

```rust
    #[test]
    fn colleague_note_mentions_the_first_colleague() {
        let mut store = CustomerStore::new();
        store.add(String::from("Ada Lovelace"), email("ada@example.com"), None).unwrap();
        assert_eq!(
            colleague_note(&store, &email("bob@EXAMPLE.com")),
            Some(String::from("Note: #1 Ada Lovelace also uses example.com."))
        );
        assert_eq!(colleague_note(&store, &email("grace@navy.mil")), None);
    }
```

**Reasoning:**

- `?` on an `Option` inside a function returning `Option` exits with `None`. `.map(...)` turns
  "maybe a customer" into "maybe a message". No `match`, no `mut`.
- **Why before `store.add`?** Two reasons. Afterwards, the new customer itself would match
  `first_by_domain`, and with an empty store that's the only match. And the ownership one: the
  returned `String` is owned, so `note` holds no borrow of `store`, which leaves `store.add`
  free to take `&mut self`. If `colleague_note` returned `Option<&Customer>` instead, you'd be
  back to Lab 10's E0502.
- `colleague_note(store, &email)`: `store` is already a `&mut CustomerStore` inside `execute`,
  and passing it where a `&CustomerStore` is expected reborrows it as shared for the call.
- Notice the test passes `bob@EXAMPLE.com` but the message says `example.com`: `Email::parse`
  lowercased it.

---

## Your Turn 3 — The error-case test suite

```rust
    #[test]
    fn email_rejects_every_broken_rule() {
        let bad = [
            "",                         // empty
            "ada.example.com",          // no @
            "@example.com",             // nothing before @
            "ada@@example.com",         // two @
            "ada@example",              // no dot in the domain
            "ada lovelace@example.com", // whitespace inside
        ];
        for input in bad {
            assert_eq!(
                Email::parse(input),
                Err(ValidationError::InvalidEmail(input.to_string())),
                "{input:?} should be rejected"
            );
        }
    }

    #[test]
    fn blank_name_is_rejected() {
        assert_eq!(parse_name("   "), Err(ValidationError::EmptyName));
        assert_eq!(parse_name("  Ada "), Ok(String::from("Ada")));
    }

    #[test]
    fn malformed_commands_return_usage_errors() {
        assert!(matches!(parse_command("list 0"), Err(CrmError::Usage("list [page]"))));
        assert!(matches!(parse_command("show"), Err(CrmError::Usage("show <id>"))));
        assert!(matches!(parse_command("delete abc"), Err(CrmError::Usage("delete <id>"))));
        assert!(matches!(parse_command("status 1 vip"), Err(CrmError::Usage(STATUS_USAGE))));
    }

    #[test]
    fn find_by_email_tells_whose_email_it_is() {
        let mut store = CustomerStore::new();
        let ada = store.add(String::from("Ada"), email("ada@example.com"), None).unwrap();
        let grace = store.add(String::from("Grace"), email("grace@example.com"), None).unwrap();

        // Grace taking Ada's email: the owner is someone else, so Update refuses.
        let owner = store.find_by_email(&email("ada@example.com")).map(|c| c.id);
        assert_eq!(owner, Some(ada));
        assert_ne!(owner, Some(grace));

        // Grace re-entering her own email: the owner is Grace, so Update allows it.
        let owner = store.find_by_email(&email("GRACE@example.com")).map(|c| c.id);
        assert_eq!(owner, Some(grace));
    }
```

**Reasoning:**

- **Table-driven tests** keep one assertion per rule without six near-identical functions. The
  third argument to `assert_eq!` makes a failure say *which* row broke. The comments document
  which rule each row exercises.
- **Matching on `&'static str` in a pattern**: `Err(CrmError::Usage("list [page]"))` works
  because a string literal is a valid pattern for a `&str` field. `STATUS_USAGE` works too: a
  `const` can be used as a pattern.
- **Why `Update`'s duplicate rule isn't tested through `execute`**: `Update` calls `prompt`, which
  reads stdin, so a test would hang waiting for input. That's a design smell we'll fix
  properly in Lab 14 (business rules move into a `Crm` type that takes values, not prompts).
  For now, test the building block the rule uses. Pulling the rule into its own function, as
  the hint suggested, is an equally good answer.
- `Ada` and `GRACE@example.com`: re-entering your own email in a different case is still your
  email, because both go through `Email::parse`.

---

## Your Turn 4 (stretch) — `Email::domain`

```rust
impl Email {
    /// The part after the '@'. Can't fail: `Email::parse` guarantees exactly one '@'.
    fn domain(&self) -> &str {
        match self.0.split_once('@') {
            Some((_, domain)) => domain,
            None => unreachable!("a parsed Email always contains '@'"),
        }
    }
}
```

Callers:

```rust
    fn first_by_domain<'a>(&'a self, domain: &str) -> Option<&'a Customer> {
        self.customers
            .iter()
            .find(|c| c.email.domain().eq_ignore_ascii_case(domain))
    }

            // Show arm
            println!("  Domain:   {}", customer.email.domain());
```

**Reasoning:**

- **Why `unreachable!` isn't a TODO here.** A TODO-`unwrap` says "I haven't thought about the
  failure case". This one says "I *have*, and it can't happen, because `Email`'s constructor
  checked it". If it ever fires, it's a bug in `Email::parse` (or someone built an `Email`
  without it, which Lab 13 makes impossible), and a loud crash with that message is the right
  outcome. `.expect("a parsed Email always contains '@'")` on the `Option` is equivalent.
- **Lifetimes, for free.** `fn domain(&self) -> &str` uses elision rule 3 (Lab 10): the result
  borrows from `self`, which is true. It's a slice of the email's own `String`.
- Once nothing calls `email_domain`, the compiler's `dead_code` warning tells you it can go,
  along with the tests for edge cases (`"ada@"`, `""`) that a parsed `Email` can't have. Another
  instance of a type deleting code.
- If you wrote `first_by_domain` with a `for` loop, Clippy's `manual_find` lint suggests the
  `.iter().find(...)` form. Both are fine; iterators get their full treatment in Lab 17.

---

## Experiment answers

**Experiment 4.** `Err(x)?` is a `?` applied to a value that's always `Err`, so it always
returns early, converting `x` with `From` (here `CrmError` → `CrmError`, the identity). Its
type is "whatever the arm needs", so it fits in a `match` that produces `Command`. It works, but
`return Err(...)` says what it means more directly, which is why the lab uses it.

**Experiment 5.** Only the name error appears, because `parse_name(...)?` returns before the
email is even prompted for. `?` is "stop at the first problem", which suits an interactive
prompt. To report every problem you'd have to run all the validations, collect the errors in a
`Vec<ValidationError>`, and only fail at the end. That's what an API form wants (Lab 28).

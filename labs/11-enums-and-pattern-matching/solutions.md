# Lab 11 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't have to match line for
> line. If your tests pass and you can explain your choices, you're done.

---

## Your Turn 1 — Parser tests

```rust
    #[test]
    fn parse_simple_commands() {
        assert_eq!(parse_command("help"), Some(Command::Help));
        assert_eq!(parse_command("version"), Some(Command::Version));
        assert_eq!(parse_command("exit"), Some(Command::Quit));
        assert_eq!(parse_command("  quit  \n"), Some(Command::Quit));
        assert_eq!(parse_command(""), None);
    }

    #[test]
    fn parse_list_defaults_to_page_one() {
        assert_eq!(parse_command("list"), Some(Command::List { page: 1 }));
        assert_eq!(parse_command("list 3"), Some(Command::List { page: 3 }));
    }

    #[test]
    fn parse_rejects_bad_arguments() {
        for input in ["list 0", "list two", "show", "show abc", "status 1 vip", "status x active"] {
            assert!(
                matches!(parse_command(input), Some(Command::Invalid(_))),
                "{input:?} should be invalid"
            );
        }
    }

    #[test]
    fn parse_status_command() {
        assert_eq!(
            parse_command("status 2 ACTIVE"),
            Some(Command::Status {
                id: 2,
                status: CustomerStatus::Active
            })
        );
    }

    #[test]
    fn parse_unknown_command() {
        assert_eq!(parse_command("delte 1"), Some(Command::Unknown("delte")));
    }
```

**Reasoning:**

- `assert_eq!` needs `PartialEq` (to compare) and `Debug` (to print both sides when it fails).
  `Command` derives both, `Option<T>` implements them whenever `T` does, and `CustomerStatus`
  derives them too. That's why the whole `Some(Command::Status { .. })` can be compared in one go.
- For invalid input we only care *which variant* came back, not the exact text, so `matches!`
  with `Command::Invalid(_)` is the right tool. Comparing the full message would make the tests
  break whenever you reword a usage line.
- The loop with an assertion message (`"{input:?} should be invalid"`) gives you one test that
  still tells you **which** input failed. The second argument of `assert!` is a format string.
- Notice `Some(Command::Unknown("delte"))` compiles: the string literal is a `&'static str`,
  which can be used where a `&'a str` is expected for any shorter `'a`.

---

## Your Turn 2 — `count` by status

```rust
impl CustomerStore {
    fn count_by_status(&self, status: CustomerStatus) -> usize {
        let mut n = 0;
        for customer in &self.customers {
            if customer.status == status {
                n += 1;
            }
        }
        n
    }
}
```

In `main`:

```rust
            Command::Count => {
                let n = store.len();
                let noun = if n == 1 { "customer" } else { "customers" };
                println!(
                    "{n} {noun} ({} prospect, {} active, {} churned)",
                    store.count_by_status(CustomerStatus::Prospect),
                    store.count_by_status(CustomerStatus::Active),
                    store.count_by_status(CustomerStatus::Churned),
                );
            }
```

Test:

```rust
    #[test]
    fn count_by_status_counts_each_status() {
        let mut store = CustomerStore::new();
        let id = store.add(String::from("Ada"), String::from("ada@example.com"), String::new());
        store.add(String::from("Grace"), String::from("grace@example.com"), String::new());
        store.find_mut(id).unwrap().status = CustomerStatus::Active;

        assert_eq!(store.count_by_status(CustomerStatus::Prospect), 1);
        assert_eq!(store.count_by_status(CustomerStatus::Active), 1);
        assert_eq!(store.count_by_status(CustomerStatus::Churned), 0);
    }
```

**Reasoning:**

- **`CustomerStatus` by value, not `&CustomerStatus`.** It's `Copy` and one byte. A reference
  would be eight bytes and an extra indirection, to avoid copying one. The rule of thumb from
  Lab 06: small `Copy` types go by value.
- `&self`: counting only reads, so a shared borrow is all we need, and `count` can call it three
  times in a row.
- `.unwrap()` in a test is fine: if `find_mut` returned `None`, the test *should* fail loudly.
  (Lab 12 talks about why `unwrap` in application code is different.)
- If you already know iterators, `self.customers.iter().filter(|c| c.status == status).count()`
  is the one-line version. Lab 17 covers it properly; the loop is perfectly good Rust.
- Calling `count_by_status` three times walks the list three times. For an in-memory CRM with a
  handful of customers, that's nothing, and the code is clearer than a single loop with three
  counters. Lab 32 does this kind of report in SQL.

---

## Your Turn 3 — Status rules with a tuple match

```rust
            Command::Status { id, status } => match store.find_mut(id) {
                Some(customer) => match (customer.status, status) {
                    (current, new) if current == new => {
                        println!("Customer #{id} is already {}.", current.label());
                    }
                    (CustomerStatus::Churned, CustomerStatus::Prospect) => {
                        println!(
                            "A churned customer can't go back to prospect. Use 'active' to win them back."
                        );
                    }
                    (_, new) => {
                        customer.status = new;
                        println!("Customer #{id} is now {}.", new.label());
                    }
                },
                None => println!("No customer with id {id}."),
            },
```

**Reasoning:**

- **Building the tuple copies.** `(customer.status, status)` makes a new tuple of two
  `CustomerStatus` values. Because the type is `Copy`, nothing is moved out of `customer`, and
  the tuple doesn't borrow it either. That's why the last arm can still write
  `customer.status = new` through the `&mut Customer`. With a non-`Copy` field you'd have to
  match on references instead (`(&customer.status, &status)`).
- **Arm order encodes priority.** The guard arm comes first, so `churned → churned` reports
  "already churned" instead of falling into any later rule. The specific
  `(Churned, Prospect)` arm comes before the catch-all.
- **Is the `(_, new)` catch-all a wildcard trap?** It matches on a *pair* of statuses, and its
  meaning really is "any other combination is allowed". If you add a new status, `label` and
  `parse` still force you to think about it. But this rule table **won't** complain, which is a
  trade-off worth knowing about. The alternative is to list all nine combinations explicitly.
  For three states that's tolerable; for a real state machine it's the better design, and Lab 18
  does exactly that with `DealStage::can_transition_to`.
- **Guards don't count for exhaustiveness.** If you'd written only the guard arm and the
  `(Churned, Prospect)` arm, the compiler would reject the match (E0004) even though, in your head,
  "every other case" is obvious. The guard might be false, so the compiler can't count on it.

Run-through:

```text
crm> status 1 active
Customer #1 is now active.
crm> status 1 active
Customer #1 is already active.
crm> status 2 churned
Customer #2 is now churned.
crm> status 2 prospect
A churned customer can't go back to prospect. Use 'active' to win them back.
crm> count
2 customers (0 prospect, 1 active, 1 churned)
```

---

## Experiment answers

**Experiment 2 (`Lead`).** Only `label` fails. `parse` matches on a `&str` with a `_ => None` arm,
so it compiles, but nobody can type `lead`: that's the "producer" side the compiler can't check.
The `status` command doesn't match on statuses at all (it just stores one). After Your Turn 3 the
count is still one, because the rules table ends in a catch-all `(_, new)`.

**Experiment 3 (sizes).** `Command`'s size is set by its biggest variant, `Invalid(String)`
(a `String` is 24 bytes on a 64-bit machine), plus room for the tag. `CustomerStatus` has three
variants and no data, so one byte is plenty. `Option<&Customer>` is 8 bytes, the same as
`&Customer`, because a reference is never null, so Rust stores `None` as the null pointer. This
is called the *niche optimisation*: `Option` around a reference (or a `Box`) costs nothing.

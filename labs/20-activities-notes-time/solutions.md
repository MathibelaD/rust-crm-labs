# Lab 20 — Solutions

> 🔴 **SOLUTION**: read these *after* a genuine attempt. Compare the reasoning, not the characters.

---

## Mini-task: why no `lead` subject?

A lead is **temporary by design**. In Lab 19, `Crm::convert_lead` *removes* the lead from the
repo and consumes it. If a note pointed at `lead:4`, then after conversion that note would
reference a record that no longer exists, a dangling reference expressed as data. The
information belongs to the *company/contact/deal* the lead became.

A comment like this is enough:

```rust
/// Leads are deliberately not subjects: they disappear on conversion (Lab 19),
/// and history must outlive them. Lead notes live in `Lead::notes`.
```

(If you wanted lead history, you'd have to *move* it to the new contact during conversion,
another ownership hand-over. Lab 31 handles this the database way: converted leads are kept
with status `converted` instead of being deleted.)

---

## Mini-task: total call minutes with the enum

```rust
let total: u32 = crm
    .activities
    .iter()
    .filter_map(|activity| match activity.kind {
        ActivityKind::Call { minutes } => Some(minutes),
        _ => None,
    })
    .sum();
```

No type changed: the question is answered *outside* `ActivityKind`, by matching on it.
`match activity.kind { Call { minutes } => .. }` doesn't move anything out of the borrowed
activity, because `minutes` is a `u32` (`Copy`). Matching a non-`Copy` field (like
`Email { subject }`) that way *would* try to move it, and you'd write `match &activity.kind`
instead.

A `_ => None` wildcard is fine here, unlike in Lab 18's transition table: "every other kind
contributes zero call minutes" stays true when a new kind is added.

---

## Your Turn 1 — Meetings need real attendees

```rust
    pub fn log_activity(
        &mut self,
        subject: Subject,
        kind: ActivityKind,
        summary: String,
        occurred_at: DateTime<Utc>,
    ) -> Result<ActivityId, CrmError> {
        self.check_subject(subject)?;
        if let ActivityKind::Meeting { attendees, .. } = &kind
            && let Some(missing) = attendees.iter().find(|&&id| self.contacts.get(id).is_none())
        {
            return Err(CrmError::NotFound {
                entity: "contact",
                id: missing.0,
            });
        }
        let activity = Activity {
            id: self.activities.next_id(),
            subject,
            kind,
            summary,
            occurred_at,
        };
        Ok(self.activities.insert(activity))
    }
```

**Reasoning:**

- **`= &kind`**, not `= kind`. Matching on `kind` by value with a binding (`attendees`) would
  *move* the `Vec` out of `kind`, and then `kind` couldn't go into the `Activity` (E0382, partial
  move, as in Lab 19). Matching on a reference binds `attendees: &Vec<ContactId>`.
- **`iter().find(..)` returns `Option<&ContactId>`**: the first missing one, as the
  requirement says. `|&&id|` peels two layers: `find` passes `&Item`, and `Item` is
  `&ContactId`. Since `ContactId: Copy`, `id` ends up a plain `ContactId`.
- **Let chain** (`if let .. && let ..`): edition 2024 syntax. A nested `if let` inside an
  `if let` is equivalent (and what clippy's `collapsible_if` would ask you to flatten).
- **Validate everything before `next_id()`**: no id is burned on failure (Lab 18 again).

An equally good loop version:

```rust
        if let ActivityKind::Meeting { attendees, .. } = &kind {
            for &contact_id in attendees {
                if self.contacts.get(contact_id).is_none() {
                    return Err(CrmError::NotFound { entity: "contact", id: contact_id.0 });
                }
            }
        }
```

Test (in `history.rs` tests, or wherever your `Crm` tests live; it needs `ContactId` and `Email`):

```rust
    #[test]
    fn meetings_need_existing_attendees() {
        let (mut crm, acme) = crm_with_company();
        let ada = crm
            .add_contact("Ada".to_string(), Email::parse("ada@acme.example").unwrap(), None, None)
            .unwrap();
        let meeting = |attendees| ActivityKind::Meeting { starts_at: at(14, 0), attendees };

        let ok = crm.log_activity(acme, meeting(vec![ada]), "Demo".to_string(), at(15, 0));
        assert!(ok.is_ok());

        let bad = crm.log_activity(acme, meeting(vec![ada, ContactId(99)]), "Demo".to_string(), at(15, 0));
        assert!(matches!(bad, Err(CrmError::NotFound { entity: "contact", id: 99 })));
        assert_eq!(crm.activities.len(), 1);
    }
```

The `meeting` closure builds the variant. Its parameter type (`Vec<ContactId>`) is inferred
from the first call. Small closures like this keep test setups readable.

---

## Your Turn 2 — Recent history in `deal show` / `company show`

```rust
fn print_recent_history(crm: &Crm, subject: Subject) {
    let history = crm.history(subject);
    if history.is_empty() {
        println!("  No history yet.");
        return;
    }
    println!("  Recent history:");
    for item in history.iter().take(5) {
        println!("    {item}");
    }
}
```

At the end of `DealCommand::Show { id }`:

```rust
            print_recent_history(crm, Subject::Deal(id));
```

…and at the end of `CompanyCommand::Show { id }`:

```rust
            print_recent_history(crm, Subject::Company(id));
```

**Why it compiles inside `deal show`:** the handler already holds `deal: &Deal` and
`company: &Company` (shared borrows of `crm`). `print_recent_history` takes `&Crm`, another
**shared** borrow, so any number can coexist. If `print_recent_history` took `&mut Crm`, you'd
get E0502.

**Why `take(5)` on the sorted `Vec`:** `history` is already newest-first, so the first five
*are* the most recent. Building the whole `Vec` to show five items is O(n log n) in the
number of items for that subject. That's fine for a CRM record. (A database version would push
`ORDER BY ... LIMIT 5` into SQL, Lab 32.)

Output, after logging a meeting on company 1:

```text
#1    Acme Corp                prospect   -
Contacts (2):
  #1    Ada Lovelace         ada@acme.example             -            #1
  #2    Charles Babbage      charles@acme.example         -            #1
  Recent history:
    2026-10-07 15:30  meeting at 2026-10-07 14:00 UTC (2 attendees): On-site demo
```

---

## Your Turn 3 — Logging meetings from the CLI

The new arm in `log_activity`:

```rust
        "meeting" => {
            let starts_at = parse_datetime(&prompt("Starts at (YYYY-MM-DD HH:MM, UTC): "))?;
            let attendees =
                parse_contact_ids(&prompt("Attendee contact ids (e.g. 3,5; blank for none): "))?;
            ActivityKind::Meeting {
                starts_at,
                attendees,
            }
        }
```

The parser:

```rust
/// Parses `3, 5,8` into contact ids. Blank input means no ids.
fn parse_contact_ids(input: &str) -> Result<Vec<ContactId>, CrmError> {
    input
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(|part| {
            part.parse().map(ContactId).map_err(|_| {
                ValidationError::InvalidValue {
                    field: "contact id",
                    value: part.to_string(),
                }
                .into()
            })
        })
        .collect()
}
```

**Reasoning, link by link:**

1. `split(',')` yields `&str` slices **borrowing `input`**. No allocation.
2. `map(str::trim)`: a **method path used as a function** (`fn(&str) -> &str`), like
   `HistoryItem::Activity` and `LeadId`. `trim` returns a sub-slice, still borrowing `input`.
3. `filter(|part| !part.is_empty())` drops blanks, so `""` and a trailing `"3,"` both work.
   Blank input yields *no* parts, so `collect()` produces `Ok(vec![])`.
4. `map(|part| ...)` turns each part into `Result<ContactId, CrmError>`.
   `parse().map(ContactId)` wraps the `u64`, and `map_err` replaces the `ParseIntError` with
   our error. How does `.into()` know to produce a `CrmError`? Type inference works
   *backwards* from the function's return type, through `collect()`'s `FromIterator` impl, to
   the error type of each element. If inference ever gives up in a chain like this, spell it
   out with `CrmError::from(..)`.
5. **`collect()` into `Result<Vec<_>, _>`**: `Result` implements `FromIterator`. It
   collects `Ok` values into the `Vec` and **stops at the first `Err`**, returning it. The
   function's return type tells `collect` which container to build. This is the iterator way
   of writing "loop, `?` each element, push".

Only `part.to_string()` allocates, and only on the error path.

Tests (in `commands.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_contact_id_lists() {
        assert_eq!(
            parse_contact_ids(" 3, 5,8 ").unwrap(),
            [ContactId(3), ContactId(5), ContactId(8)]
        );
        assert_eq!(parse_contact_ids("").unwrap(), []);
        assert!(parse_contact_ids("3,x").is_err());
    }

    #[test]
    fn parses_datetimes_as_utc() {
        let parsed = parse_datetime("2026-10-07 14:00").unwrap();
        assert_eq!(parsed.to_rfc3339(), "2026-10-07T14:00:00+00:00");
        assert!(parse_datetime("07/10/2026 2pm").is_err());
    }
}
```

These functions are private (`fn`, not `pub`), yet the tests can call them: a `tests` module
*inside* the file is a child module, and children can see their parent's private items (Lab 13).

A session that exercises all three Your Turns:

```text
crm> Kind (call/email/meeting): Starts at (YYYY-MM-DD HH:MM, UTC): Attendee contact ids (e.g. 3,5; blank for none): Summary: When (YYYY-MM-DD HH:MM, UTC; blank for now): Logged activity #1 on company:1
crm> Kind (call/email/meeting): Starts at (YYYY-MM-DD HH:MM, UTC): Attendee contact ids (e.g. 3,5; blank for none): Summary: When (YYYY-MM-DD HH:MM, UTC; blank for now): Error: contact #7 not found
crm> Kind (call/email/meeting): Starts at (YYYY-MM-DD HH:MM, UTC): Error: invalid date/time (expected YYYY-MM-DD HH:MM): 'next tuesday'
```

> 💡 The attendee check happens in `Crm::log_activity`, *after* all the prompts. That's the
> right place for the rule (the domain owns it), even though the user only finds out at the
> end. Better UX would also validate early in the CLI, *in addition to* the domain check,
> never instead of it.

---

## Experiment answers

**Experiment 2 (hidden clock):** two tests fail:

```text
history::tests::history_only_contains_the_requested_subject --- FAILED
  left: "2026-10-05 14:52  note: About Acme"
 right: "2026-10-05 09:00  note: About Acme"
history::tests::history_is_newest_first_across_activities_and_notes --- FAILED
  left: [2026-10-05T14:52:36.309559Z, 2026-10-05T10:15:00Z, 2026-10-05T09:00:00Z]
 right: [2026-10-05T11:30:00Z, 2026-10-05T10:15:00Z, 2026-10-05T09:00:00Z]
```

You also get `warning: unused variable: now`, the compiler noticing the ignored input.
`notes_and_activities_need_an_existing_subject` and `blank_notes_are_rejected` still pass.
They never look at times. **Worrying, not reassuring:** they'd keep passing even if timestamps
were completely broken. And the `matches!(history[0], HistoryItem::Note(_))` line inside the
newest-first test would *also* still pass, because "now" happens to be later than 11:30, so
the note sorts first by luck. A test that passes for the wrong reason is worse than no test.
Asserting exact values, made possible by injecting `now`, is what catches this.

**Experiment 3 (ties):** with equal timestamps, the **activity comes first**. `merge_history`
chains activities *before* notes, and `sort_by_key` is **stable**: equal keys keep their
original relative order. `sort_unstable_by_key` makes no such promise (it's a bit faster and
doesn't allocate), so the order of ties could differ. If tie order matters to users, make it
explicit, e.g. sort by `(Reverse(item.at()), kind_rank)`, rather than relying on stability as
a hidden rule.

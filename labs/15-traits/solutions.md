# Lab 15 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't need to match exactly.
> If it meets the acceptance criteria and you can explain every line, it's correct.

---

## Your Turn 1 — `Validate` for `Contact`

### The impl (`src/contacts/model.rs`)

```rust
use crate::entity::{Entity, Validate};
use crate::errors::ValidationError;

impl Validate for Contact {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.name.trim().is_empty() {
            return Err(ValidationError::EmptyName);
        }
        if let Some(phone) = &self.phone {
            let allowed = phone
                .chars()
                .all(|ch| ch.is_ascii_digit() || " +-()".contains(ch));
            let has_digit = phone.chars().any(|ch| ch.is_ascii_digit());
            if !allowed || !has_digit {
                return Err(ValidationError::InvalidPhone(phone.clone()));
            }
        }
        Ok(())
    }
}
```

**Why `if let Some(phone) = &self.phone`?** `self` is `&Contact`, so you can't move the `String`
out of `self.phone`. Matching on `&self.phone` (an `&Option<String>`) binds `phone: &String`, a
borrow. `.clone()` only happens on the error path, where you need an owned `String` to put in the
error.

**Why is `""` rejected?** An empty phone would pass the "all characters allowed" check (`all`
on an empty iterator is `true`, since there's nothing to violate it), but fails "has a digit"
(`any` on an empty iterator is `false`). The CLI turns blank input into `None` before it gets
here, so `Some("")` only shows up if some *other* code path builds a contact. That's exactly why
the rule lives on the type.

### Wiring it in

`src/contacts/store.rs`:

```rust
use crate::entity::{Validate, find_by_id};

    pub fn add(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> Result<ContactId, CrmError> {
        if self.email_exists(&email) {
            return Err(CrmError::DuplicateEmail(email.as_str().to_string()));
        }
        let contact = Contact {
            id: ContactId(self.next_id),
            name,
            email,
            phone,
            company_id,
        };
        contact.validate()?;
        self.next_id += 1;
        let id = contact.id;
        self.contacts.push(contact);
        Ok(id)
    }
```

`contact.validate()?` returns `Result<(), ValidationError>` inside a function returning
`Result<_, CrmError>`. The `?` converts using your `From<ValidationError> for CrmError`.

`src/crm.rs`: `add_contact` loses its name and phone checks and keeps only the company check:

```rust
    pub fn add_contact(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> Result<ContactId, CrmError> {
        if let Some(company_id) = company_id
            && self.companies.find(company_id).is_none()
        {
            return Err(CrmError::NotFound {
                entity: "company",
                id: company_id.0,
            });
        }
        self.contacts.add(name, email, phone, company_id)
    }
```

`update_contact`: validate a **copy**, then commit.

```rust
        let contact = self.contacts.find_mut(id).ok_or(CrmError::NotFound {
            entity: "contact",
            id: id.0,
        })?;
        let mut updated = contact.clone();
        if let Some(name) = name {
            updated.name = name;
        }
        if let Some(email) = email {
            updated.email = email;
        }
        if let Some(phone) = phone {
            updated.phone = Some(phone);
        }
        updated.validate()?;
        *contact = updated;
        Ok(())
```

**Ownership walk-through.** `contact` is a `&mut Contact` borrowed from the store.
`contact.clone()` produces an independent owned `Contact`. The new values (`name`, `email`,
`phone`, all owned `Option`s passed in by value) are *moved* into `updated`. If `validate` fails,
`?` returns, `updated` is dropped, and the store never changed. If it passes,
`*contact = updated;` moves `updated` into the slot behind the `&mut`, and the old value that was
there is dropped. This "build, validate, then swap in" pattern is the in-memory version of a
database transaction, and you'll meet the real thing in Lab 31.

(If you mutated `contact` directly and validated afterwards, a bad phone would leave a
half-updated contact in the store. That's the bug the third acceptance criterion catches.)

### Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn contact(name: &str, phone: Option<&str>) -> Contact {
        Contact {
            id: ContactId(1),
            name: name.to_string(),
            email: Email::parse("ada@example.com").unwrap(),
            phone: phone.map(String::from),
            company_id: None,
        }
    }

    #[test]
    fn valid_contact_passes() {
        assert!(contact("Ada", Some("+44 (0)20 555-0100")).validate().is_ok());
        assert!(contact("Ada", None).is_valid());
    }

    #[test]
    fn blank_name_is_rejected() {
        assert_eq!(contact("  ", None).validate(), Err(ValidationError::EmptyName));
    }

    #[test]
    fn bad_phone_is_rejected() {
        for bad in ["call me", "---", ""] {
            assert_eq!(
                contact("Ada", Some(bad)).validate(),
                Err(ValidationError::InvalidPhone(bad.to_string()))
            );
        }
    }
}
```

`contact(...)` is a test helper that builds a `Contact` directly with a struct literal. That's
allowed here because the test module is inside the crate and the fields are `pub`. Note that
`is_valid()` is available although `Contact`'s impl never wrote it (default method).

---

## Your Turn 2 — `Display` for `Contact`

```rust
impl fmt::Display for Contact {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let phone = self.phone.as_deref().unwrap_or("-");
        let company = match self.company_id {
            Some(id) => id.to_string(),
            None => String::from("-"),
        };
        write!(
            f,
            "{:<4} {:<20} {:<24} {:<14} {}",
            self.id, self.name, self.email, phone, company
        )
    }
}
```

Line by line:

- `self.phone.as_deref()` turns `&Option<String>` into `Option<&str>` without cloning, and
  `.unwrap_or("-")` picks a fallback. Both branches are `&str`, so `phone: &str`.
- The company column is the orphan-rule workaround: a `match` producing a `String`. Both arms
  must have the same type, so `"-"` becomes `String::from("-")`. (An alternative that avoids the
  allocation: `match` inside the `write!` with two separate `write!` calls. Not worth it here.)
- `self.id` and `self.email` go straight into padded columns because their `Display` impls use
  `f.pad`. If you used `self.email.as_str()` instead, that's fine too; `&str` pads correctly.
- `write!` (not `f.pad`) for the whole row: we're composing several padded pieces, and the row
  itself is never put in a column.

Test, matching the acceptance criteria exactly:

```rust
    #[test]
    fn display_is_one_table_row() {
        let mut c = contact("Ada Lovelace", Some("555-0100"));
        c.company_id = Some(CompanyId(2));
        assert_eq!(
            c.to_string(),
            "#1   Ada Lovelace         ada@example.com          555-0100       #2"
        );
        c.phone = None;
        c.company_id = None;
        assert_eq!(
            c.to_string(),
            "#1   Ada Lovelace         ada@example.com          -              -"
        );
    }
```

Then the commands (`src/cli/commands.rs`):

```rust
const CONTACT_HEADER: &str =
    "ID   NAME                 EMAIL                    PHONE          COMPANY";

        // contact list
            let contacts = crm.contacts.page(page, PAGE_SIZE);
            if contacts.is_empty() {
                println!("No contacts on page {page}.");
            } else {
                print_table(CONTACT_HEADER, contacts);
            }

        // contact show
            print_table(CONTACT_HEADER, &[contact]);

        // contact search
            if results.is_empty() {
                println!("No contacts match '{term}'.");
            } else {
                print_table(CONTACT_HEADER, &results);
            }

        // company show, after the company row and blank line
            if contacts.is_empty() {
                println!("(no contacts)");
            } else {
                print_table(CONTACT_HEADER, &contacts);
            }
```

Notice that `print_table` accepted three different element types without changes:
`&[Contact]` (from `page`), `&[&Contact]` (from `&[contact]`) and `&Vec<&Contact>` (auto-derefs
to `&[&Contact]`). One generic function, several compiled versions. Lab 16 makes that visible.

Session check:

```text
crm> contact list
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
#2   Grace Hopper         grace@navy.mil           -              -
crm> company show 1
ID   NAME                 STAGE     WEBSITE
#1   Acme Corp            prospect  acme.io

ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
```

---

## Your Turn 3 — a generic `parse_id`

```rust
/// Parses a numeric id into any id type that can be built from a `u64`.
fn parse_id<Id: From<u64>>(arg: Option<&&str>, usage: &'static str) -> Result<Id, CrmError> {
    arg.and_then(|s| s.parse::<u64>().ok())
        .map(Id::from)
        .ok_or(CrmError::Usage(usage))
}
```

Call sites:

```rust
        Some("show") => Ok(CompanyCommand::Show {
            id: parse_id(args.get(1), "company show <id>")?,
        }),
```

**How does the compiler know which `Id`?** Type inference flows *backwards* from where the
value goes. The field `CompanyCommand::Show { id }` has type `CompanyId`, so `parse_id(...)?`
must produce a `CompanyId`, so `Id = CompanyId`, and the bound `CompanyId: From<u64>` is checked
and satisfied. In `company stage`, `let id = parse_id(args.get(1), usage)?;` has no annotation,
but `id` is later used in `CompanyCommand::Stage { id, lifecycle }`, which is enough.

**`.map(Id::from)`** passes the associated function itself as the closure: `Id::from` *is* a
function from `u64` to `Id`. Writing `.map(|n| Id::from(n))` is equivalent; clippy prefers the
short form (`redundant_closure`).

If the compiler can't infer `Id` anywhere (say, `let id = parse_id(args.get(1), "x")?;` and
`id` is only printed), you'd get E0282 "type annotations needed", fixable with
`parse_id::<CompanyId>(...)` (the turbofish) or `let id: CompanyId = ...`.

---

## 🧪 Experiment answers

**Removing `Copy` from `ContactId`.** The first error is at the impl, not at a use:

```text
error[E0277]: the trait bound `ContactId: Copy` is not satisfied
  --> src/contacts/model.rs:33:15
   |
33 |     type Id = ContactId;
   |               ^^^^^^^^^ the trait `Copy` is not implemented for `ContactId`
   |
note: required by a bound in `Entity::Id`
```

Fix that by hand (pretend you dropped the bound) and you'd get a cascade of E0382 "use of moved
value: `id`" in `commands.rs`, wherever an id is passed to a method and then printed or used
again (`crm.update_contact(id, ...)` followed by `println!("Updated contact {id}")`). Ids are
used *constantly* after being passed somewhere. Requiring `Copy` in the trait makes them behave
like the integers they are.

**`write!` instead of `f.pad` in `Lifecycle`.** The round-trip test still passes: `to_string()`
has no width. A test that would catch it:

```rust
    #[test]
    fn lifecycle_respects_width() {
        assert_eq!(format!("[{:<9}]", Lifecycle::Customer), "[customer ]");
    }
```

**Overriding `is_valid`.** It compiles: an implementor may override any default method. The
test `company_validation` still passes because it only asserts `is_valid()` for a *valid*
company. The lesson: a default method is a convenience the trait author offers, but the
implementor has the final say. If a method must never be overridden, it shouldn't be a trait
method; make it a free function or an extension trait with a blanket impl.

---

## Checkpoint notes

1. Rust traits are nominal. A type implements a trait only through an explicit `impl`.
   TypeScript would accept any object with an `id` property.
2. One entity has exactly one id type (decided by the implementor) → associated type.
   `From<T>`: `CompanyId` could reasonably implement `From<u64>` *and* `From<i64>` (Lab 30 will
   need the latter); the caller picks which. That's a parameter.
3. For example: `Eq` → `item.id() == id` in `find_by_id`; `Copy` → returning `self.id` from
   `&self` and reusing ids after passing them; `Hash` → `HashMap<CompanyId, _>` (Lab 17);
   `Debug` → `assert_eq!` on ids.
4. The blanket impl `impl<T, U: From<T>> Into<U> for T` in `std`.
5. `.parse()` uses `FromStr` (your `impl FromStr for Lifecycle`); `?` uses `From` (your Lab 12
   `impl From<ValidationError> for CrmError`).
6. Orphan rule: `Display` and `Option` are both foreign. `CompanyId` is local.
7. A data pointer and a vtable pointer. Every `&dyn Display` has the same size, and the vtable
   tells the program at runtime which `fmt` to call.
8. Width/alignment flags live in the `Formatter`; only `pad` (and friends) apply them.

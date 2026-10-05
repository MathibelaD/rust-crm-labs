# Lab 14 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't have to match line for
> line. If your tests pass and you can explain your choices, you're done.

---

## Step 8 mini-task — `ContactStore`

```rust
use super::{Contact, ContactId, Email};
use crate::companies::CompanyId;

/// All contacts, in memory. Hands out ids; enforces no business rules
/// (those live in `Crm`).
pub struct ContactStore {
    contacts: Vec<Contact>,
    next_id: u64,
}

impl ContactStore {
    pub fn new() -> Self {
        Self {
            contacts: Vec::new(),
            next_id: 1,
        }
    }

    /// Stores a new contact and returns its id. No checks: see `Crm::add_contact`.
    pub fn add(
        &mut self,
        name: String,
        email: Email,
        phone: Option<String>,
        company_id: Option<CompanyId>,
    ) -> ContactId {
        let id = ContactId(self.next_id);
        self.next_id += 1;
        self.contacts.push(Contact::new(id, name, email, phone, company_id));
        id
    }

    pub fn all(&self) -> &[Contact] {
        &self.contacts
    }

    /// One page of contacts (pages start at 1). Empty when out of range.
    pub fn page(&self, page: usize, per_page: usize) -> &[Contact] {
        if page == 0 || per_page == 0 {
            return &[];
        }
        let start = (page - 1).saturating_mul(per_page);
        if start >= self.contacts.len() {
            return &[];
        }
        let end = start.saturating_add(per_page).min(self.contacts.len());
        &self.contacts[start..end]
    }

    pub fn find(&self, id: ContactId) -> Option<&Contact> {
        self.contacts.iter().find(|c| c.id == id)
    }

    pub fn find_mut(&mut self, id: ContactId) -> Option<&mut Contact> {
        self.contacts.iter_mut().find(|c| c.id == id)
    }

    /// Removes a contact and hands it back to the caller.
    pub fn remove(&mut self, id: ContactId) -> Option<Contact> {
        let index = self.contacts.iter().position(|c| c.id == id)?;
        Some(self.contacts.remove(index))
    }

    pub fn email_exists(&self, email: &Email) -> bool {
        self.contacts.iter().any(|c| c.email == *email)
    }

    /// Contacts whose name or email contains `term` (case-insensitive).
    pub fn search<'a>(&'a self, term: &str) -> Vec<&'a Contact> {
        let term = term.to_lowercase();
        let mut results = Vec::new();
        for contact in &self.contacts {
            if contact.name.to_lowercase().contains(&term)
                || contact.email.as_str().contains(&term)
            {
                results.push(contact);
            }
        }
        results
    }

    pub fn len(&self) -> usize {
        self.contacts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.contacts.is_empty()
    }
}

impl Default for ContactStore {
    fn default() -> Self {
        Self::new()
    }
}
```

**Reasoning:**

- `c.id == id` compares two `ContactId`s; that's what `#[derive(PartialEq)]` on the newtype is for.
- `add` returns the id it generated. Ids are `Copy`, so handing one back costs nothing and lets
  the caller (`Crm`) refer to the new record without borrowing the store.
- If you compare this file with `CompanyStore` side by side, you'll see they're the same code
  with different types, plus a few contact-specific methods. Keep that discomfort: Lab 16 turns
  it into one generic `InMemoryRepo<T>`.

---

## Your Turn 1 — Deleting, safely

In `Crm`:

```rust
    /// Removes a contact and hands it back.
    pub fn remove_contact(&mut self, id: ContactId) -> Result<Contact, CrmError> {
        self.contacts.remove(id).ok_or(CrmError::NotFound {
            entity: "contact",
            id: id.0,
        })
    }

    /// Removes a company, but only if nobody works there any more.
    ///
    /// The check lives here, not in `CompanyStore::remove`, because it involves
    /// *two* stores. A store only knows its own records; `Crm` sees both.
    pub fn remove_company(&mut self, id: CompanyId) -> Result<Company, CrmError> {
        self.company(id)?;
        if !self.contacts_of(id).is_empty() {
            return Err(CrmError::HasContacts(id));
        }
        self.companies.remove(id).ok_or(CrmError::NotFound {
            entity: "company",
            id: id.0,
        })
    }
```

In `cli/commands.rs`:

```rust
        CompanyCommand::Delete { id } => {
            let company = crm.remove_company(id)?;
            println!("Deleted company #{} ({})", company.id.0, company.name);
        }
        // ...
        ContactCommand::Delete { id } => {
            let contact = crm.remove_contact(id)?;
            println!("Deleted contact #{} ({})", contact.id.0, contact.name);
        }
```

And the `execute` test gets the two deletes back:

```rust
    #[test]
    fn unknown_ids_are_not_found() {
        let mut crm = Crm::new();
        let commands = [
            Command::Company(CompanyCommand::Show { id: CompanyId(42) }),
            Command::Company(CompanyCommand::Delete { id: CompanyId(42) }),
            Command::Contact(ContactCommand::Show { id: ContactId(42) }),
            Command::Contact(ContactCommand::Update { id: ContactId(42) }),
            Command::Contact(ContactCommand::Delete { id: ContactId(42) }),
        ];
        for command in commands {
            assert!(matches!(
                execute(&mut crm, command),
                Err(CrmError::NotFound { id: 42, .. })
            ));
        }
    }
```

```text
crm> company delete 1
Error: company #1 still has contacts; delete them first
crm> company delete 2
Deleted company #2 (Globex)
```

**Reasoning:**

- **Order of checks.** Existence first, so an unknown id is `NotFound` rather than "has no
  contacts, so... remove nothing?". Then the rule. Only then the mutation. If any check fails,
  nothing has changed. The same check-then-mutate shape as `update_contact`.
- **`self.company(id)?;` as a statement**: the `&Company` it returns is thrown away immediately,
  so the shared borrow ends on that line. That's why `self.companies.remove(id)` (which needs
  `&mut self.companies`) is allowed two lines later.
- **`contacts_of(id).is_empty()`** collects a `Vec` just to ask if it's empty, which is slightly
  wasteful. `self.contacts.all().iter().any(|c| c.company_id == Some(id))` stops at the first
  match. Either is fine at this size; Lab 17 is about exactly these choices.
- **Returning the owned value.** `remove_company` returns `Company`, not `()`. The caller owns
  it now, which is how the CLI can print the name of something that's no longer in the store.
  The record isn't dropped until the `println!` is done with it.
- **Why the rule must not be in the CLI**: in Lab 27 a `DELETE /companies/{id}` endpoint calls
  `crm.remove_company`. If the "has contacts" check were in `commands.rs`, the web API would
  happily orphan contacts. Lab 28 maps `HasContacts` to HTTP 409 Conflict.
- An alternative policy would be "deleting a company un-links its contacts"
  (`company_id = None`). It's a legitimate business choice. Refusing is safer as a default:
  nothing happens that the user didn't explicitly ask for.

---

## Your Turn 2 — Test the rules

```rust
    #[test]
    fn add_contact_rejects_duplicate_email() {
        let (mut crm, _, _) = crm_with_acme_and_ada();
        let result =
            crm.add_contact(String::from("Imposter"), email("ADA@acme.example"), None, None);
        assert!(matches!(result, Err(CrmError::DuplicateEmail(_))));
    }

    #[test]
    fn blank_names_are_rejected() {
        let mut crm = Crm::new();
        assert!(matches!(
            crm.add_company(String::from("   "), None),
            Err(CrmError::Validation(ValidationError::EmptyName))
        ));
        assert!(matches!(
            crm.add_contact(String::from(""), email("x@y.example"), None, None),
            Err(CrmError::Validation(ValidationError::EmptyName))
        ));
    }

    #[test]
    fn contacts_of_only_returns_that_companys_contacts() {
        let (mut crm, acme, ada) = crm_with_acme_and_ada();
        let globex = crm.add_company(String::from("Globex"), None).unwrap();
        crm.add_contact(String::from("Hank"), email("hank@globex.example"), None, Some(globex))
            .unwrap();
        crm.add_contact(String::from("Solo"), email("solo@example.com"), None, None)
            .unwrap();

        let ids: Vec<ContactId> = crm.contacts_of(acme).iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![ada]);
    }

    #[test]
    fn set_lifecycle_changes_the_company() {
        let (mut crm, acme, _) = crm_with_acme_and_ada();
        crm.set_lifecycle(acme, Lifecycle::Customer).unwrap();
        assert_eq!(crm.company(acme).unwrap().lifecycle, Lifecycle::Customer);
    }

    #[test]
    fn set_lifecycle_on_unknown_company_is_not_found() {
        let mut crm = Crm::new();
        assert!(matches!(
            crm.set_lifecycle(CompanyId(7), Lifecycle::Churned),
            Err(CrmError::NotFound { entity: "company", id: 7 })
        ));
    }

    #[test]
    fn update_contact_keeps_fields_that_are_none() {
        let (mut crm, _, ada) = crm_with_acme_and_ada();
        crm.update_contact(ada, None, None, Some(String::from("555-0100")))
            .unwrap();
        let contact = crm.contact(ada).unwrap();
        assert_eq!(contact.name, "Ada");
        assert_eq!(contact.phone.as_deref(), Some("555-0100"));
    }

    #[test]
    fn update_contact_allows_own_email_but_not_someone_elses() {
        let (mut crm, _, ada) = crm_with_acme_and_ada();
        crm.add_contact(String::from("Grace"), email("grace@example.com"), None, None)
            .unwrap();
        assert!(crm.update_contact(ada, None, Some(email("ada@acme.example")), None).is_ok());
        assert!(matches!(
            crm.update_contact(ada, None, Some(email("grace@example.com")), None),
            Err(CrmError::DuplicateEmail(_))
        ));
    }

    #[test]
    fn company_with_contacts_cannot_be_removed() {
        let (mut crm, acme, ada) = crm_with_acme_and_ada();
        assert!(matches!(
            crm.remove_company(acme),
            Err(CrmError::HasContacts(id)) if id == acme
        ));

        crm.remove_contact(ada).unwrap();
        let removed = crm.remove_company(acme).unwrap();
        assert_eq!(removed.name, "Acme");
        assert!(crm.companies.is_empty());
    }

    #[test]
    fn removing_unknown_ids_is_not_found() {
        let mut crm = Crm::new();
        assert!(matches!(
            crm.remove_contact(ContactId(3)),
            Err(CrmError::NotFound { entity: "contact", id: 3 })
        ));
        assert!(matches!(
            crm.remove_company(CompanyId(3)),
            Err(CrmError::NotFound { entity: "company", id: 3 })
        ));
    }
```

**Reasoning:**

- These tests are why the "logic lives in `Crm`" rule pays off **today**: Lab 12 couldn't test
  `update`'s duplicate-email rule because it was tangled up with `prompt`. `Crm::update_contact`
  takes values, so it's a plain function call in a test.
- **`let (mut crm, _, _) = ...`**: tuple destructuring with `_` for the parts you don't need.
  `mut` goes on the binding that needs it.
- **Patterns on struct variants** (`NotFound { entity: "company", id: 7 }`) check every field;
  `NotFound { id: 42, .. }` checks some and ignores the rest.
- **`HasContacts(id) if id == acme`**: a guard inside `matches!`, comparing two `CompanyId`s.
- **`contacts_of(...).iter().map(|c| c.id).collect()`** turns `Vec<&Contact>` into
  `Vec<ContactId>`, which can be compared with `assert_eq!`. Comparing ids rather than whole
  contacts keeps the test focused, and `Contact` doesn't even implement `PartialEq`. (Lab 17
  explains `map` and `collect` properly.)
- "Nothing changed" assertions (`crm.contacts.is_empty()` after a rejected add,
  `crm.companies.is_empty()` only after the successful remove) catch a whole class of bugs where
  a function reports an error **after** half-doing its work.

---

## Your Turn 3 — Break the cycle with `Weak`

```rust
use std::rc::{Rc, Weak};

struct CompanyNode {
    name: String,
    contacts: RefCell<Vec<Rc<ContactNode>>>,
}

struct ContactNode {
    name: String,
    // Weak: a contact refers to its company but doesn't keep it alive.
    // The company "has" its contacts; the contact merely knows where it works.
    company: RefCell<Weak<CompanyNode>>,
}

fn attempt_2b_cycle() {
    println!("--- Attempt 2b: a cycle, broken with Weak ---");
    let globex = Rc::new(CompanyNode {
        name: String::from("Globex"),
        contacts: RefCell::new(Vec::new()),
    });
    let hank = Rc::new(ContactNode {
        name: String::from("Hank"),
        company: RefCell::new(Weak::new()),
    });

    *hank.company.borrow_mut() = Rc::downgrade(&globex);
    globex.contacts.borrow_mut().push(Rc::clone(&hank));

    println!(
        "Globex owners: {} (+{} weak), Hank owners: {}",
        Rc::strong_count(&globex),
        Rc::weak_count(&globex),
        Rc::strong_count(&hank)
    );
    match hank.company.borrow().upgrade() {
        Some(company) => println!("{} works at {}", hank.name, company.name),
        None => println!("{}'s company is gone", hank.name),
    }
    println!("end of attempt_2b_cycle: watch for 'dropped' lines...");
}
```

```text
--- Attempt 2b: a cycle, broken with Weak ---
Globex owners: 1 (+1 weak), Hank owners: 2
Hank works at Globex
end of attempt_2b_cycle: watch for 'dropped' lines...
  dropped company Globex
  dropped contact Hank
(back in main)
```

**Reasoning:**

- **Which direction is weak?** The one that shouldn't keep the other alive. A company owning its
  list of contacts is natural (delete the company node, its contact list goes with it). A contact
  keeping its company alive is not. The usual rule for trees and graphs: **parent → child strong,
  child → parent weak**.
- **The drop sequence.** At the end of the function, `hank` drops first (locals drop in reverse
  order): Hank's count goes 2 → 1 (Globex's list still holds him). Then `globex` drops: count
  1 → 0, so Globex is freed, printing `dropped company Globex`. Freeing Globex drops its
  `contacts` `Vec`, which drops the last `Rc` to Hank, so Hank is freed too. The weak handle
  inside Hank doesn't count, so it never held anything up.
- **`upgrade()` returns `Option<Rc<T>>`**, because by the time you follow a weak link, the target
  may be gone. Sound familiar? It's the same `Option` as an id lookup in Attempt 3. Weak
  references and ids share the same honest truth: *the thing you point at might not exist any
  more.*
- `Rc::strong_count(&globex)` is 1 (only the local `globex`), and `weak_count` is 1 (Hank's link).
  Hank has two strong owners: the local `hank` and Globex's list.

---

## Experiment answers

**Experiment 1.** The same E0308 as in Step 6: `expected CompanyId, found ContactId`. With plain
`u64` ids it would have compiled, and showing contact #2 would have made **company #2** a
customer. That's the bug class newtypes delete.

**Experiment 2.** Build the owned name first, and do the mutation **before** taking the
`&Company` that the rest of the arm uses:

```rust
            let copy_name = format!("{} (copy)", crm.company(id)?.name);
            crm.add_company(copy_name, None)?;
            let company = crm.company(id)?; // the arm continues as before
```

The `&Company` from `crm.company(id)?` only lives inside the `format!` expression. By the time
`add_company` needs `&mut crm`, no shared borrow is alive.

**Experiment 3.** The contact's `company_id` still says `Some(CompanyId(1))`, but
`crm.companies.find(...)` returns `None`, so `print_contact_line` prints the contact without a
company, and `contacts_of(acme)` still returns Ada (it only compares ids). The data is now
inconsistent: a dangling id. That's exactly what `Crm::remove_company` with its `HasContacts`
check prevents, and why the CLI must go through `Crm` rather than the store. (In Lab 30, Postgres
enforces the same rule with `REFERENCES companies(id) ON DELETE RESTRICT`.)

**Experiment 4.** 3 → 2 → 1. Each `drop` releases one handle; the local `acme` keeps the last
one. With the `if` block still in place you get **E0382**: `promote_prospects(&[ada, grace])`
*moves* `ada` and `grace` into an array, and since the compiler can't know whether the `if` ran,
it treats them as possibly moved afterwards.

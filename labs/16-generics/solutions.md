# Lab 16 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't need to match exactly.
> If it meets the acceptance criteria and you can explain every line, it's correct.

---

## In-step Your Turn — `get_mut` and `remove`

```rust
    pub fn get_mut(&mut self, id: T::Id) -> Option<&mut T> {
        self.items.iter_mut().find(|item| item.id() == id)
    }

    pub fn remove(&mut self, id: T::Id) -> Option<T> {
        let index = self.items.iter().position(|item| item.id() == id)?;
        Some(self.items.remove(index))
    }
```

**`get_mut`.** `iter_mut()` yields `&mut T`. `find` returns the first one whose id matches,
wrapped in `Option`. The returned `&mut T` borrows from `&mut self`, so while the caller holds it
the whole repo is exclusively borrowed (Lab 07's rule, now inside a generic). You can't reuse
`find_by_id` here: it takes `&[E]` and returns `&E`, a *shared* borrow. A `find_by_id_mut` would
be the same body with `iter_mut`. Not worth a helper for one call.

**`remove`.** Two phases, on purpose:

1. `position` borrows the vector *shared* to find an index (a plain `usize`, no borrow attached).
   `?` returns `None` early if nothing matched.
2. `Vec::remove(index)` borrows it *mutably*, shifts later items left (keeping order), and returns
   the removed item **by value**. Ownership moves from the vector to the caller.

Trying to do it in one step (find a `&T`, then remove it) fails: you'd be holding a shared borrow
into the vector while mutating it, the E0502 from Lab 08. Converting the borrow into an index first
is the standard way out.

(`swap_remove(index)` is O(1) instead of O(n), but moves the last item into the hole and breaks
insertion order, which `list` relies on.)

---

## Your Turn 1 — `search` on `InMemoryRepo<Contact>`

```rust
    pub fn search(&self, term: &str) -> Vec<&Contact> {
        let term = term.to_lowercase();
        self.all()
            .iter()
            .filter(|c| c.name.to_lowercase().contains(&term) || c.email.as_str().contains(&term))
            .collect()
    }
```

- `let term = term.to_lowercase();` **shadows** the `&str` parameter with an owned, lowercased
  `String`, once, instead of once per contact.
- `self.all().iter()`: `all()` is the public `&[Contact]`; `items` is private to `repo.rs`.
- `c.email.as_str()` needs no lowercasing: an `Email` is lowercase by construction (Lab 12). The
  type's invariant saves work here.
- `collect()` builds a `Vec<&Contact>`. The element type is `&Contact` because `iter()` yields
  references. The return type's lifetime is elided: the borrowed contacts come from `&self`, not
  from `term` (Lab 10's rules: with `&self`, output lifetimes come from `self`).

Tests (in `src/contacts/queries.rs`):

```rust
#[cfg(test)]
mod tests {
    use crate::contacts::Email;
    use crate::crm::Crm;

    #[test]
    fn search_matches_name_or_email_case_insensitively() {
        let mut crm = Crm::new();
        for (name, email) in [("Ada Lovelace", "ada@acme.io"), ("Grace Hopper", "grace@navy.mil")] {
            crm.add_contact(name.into(), Email::parse(email).unwrap(), None, None)
                .unwrap();
        }
        let names = |term: &str| -> Vec<String> {
            crm.contacts.search(term).iter().map(|c| c.name.clone()).collect()
        };
        assert_eq!(names("ADA"), vec!["Ada Lovelace"]);
        assert_eq!(names("navy"), vec!["Grace Hopper"]);
        assert!(names("zzz").is_empty());
    }

    #[test]
    fn email_exists_compares_normalised_emails() {
        let mut crm = Crm::new();
        crm.add_contact("Ada".into(), Email::parse("ada@acme.io").unwrap(), None, None)
            .unwrap();
        assert!(crm.contacts.email_exists(&Email::parse("ADA@acme.io").unwrap()));
        assert!(!crm.contacts.email_exists(&Email::parse("bob@acme.io").unwrap()));
    }
}
```

The `names` closure borrows `crm` and maps results to owned `String`s, so the assertions don't
hold borrows into the CRM. Closures get their full treatment in Lab 17.

---

## Your Turn 2 — prove the repo is generic

```rust
#[cfg(test)]
mod tests {
    use super::*;

    // A tiny entity that exists only for tests: proof that the repo is
    // generic and does not secretly depend on Company or Contact.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    struct NoteId(u64);

    impl From<u64> for NoteId {
        fn from(raw: u64) -> Self {
            NoteId(raw)
        }
    }

    #[derive(Debug)]
    struct Note {
        id: NoteId,
        text: String,
    }

    impl Entity for Note {
        type Id = NoteId;

        fn id(&self) -> NoteId {
            self.id
        }

        fn label(&self) -> String {
            self.text.clone()
        }
    }

    fn repo_with(texts: &[&str]) -> InMemoryRepo<Note> {
        let mut repo = InMemoryRepo::new();
        for text in texts {
            let id = repo.next_id();
            repo.insert(Note {
                id,
                text: text.to_string(),
            });
        }
        repo
    }

    #[test]
    fn ids_start_at_one_and_increase() {
        let mut repo: InMemoryRepo<Note> = InMemoryRepo::default();
        assert_eq!(repo.next_id(), NoteId(1));
        assert_eq!(repo.next_id(), NoteId(2));
    }

    #[test]
    fn insert_then_get() {
        let repo = repo_with(&["call Ada", "email Bob"]);
        assert_eq!(repo.len(), 2);
        assert_eq!(repo.get(NoteId(2)).unwrap().text, "email Bob");
        assert!(repo.get(NoteId(99)).is_none());
    }

    #[test]
    fn get_mut_changes_the_stored_item() {
        let mut repo = repo_with(&["draft"]);
        repo.get_mut(NoteId(1)).unwrap().text.push_str(" v2");
        assert_eq!(repo.get(NoteId(1)).unwrap().label(), "draft v2");
    }

    #[test]
    fn remove_returns_ownership_and_ids_are_not_reused() {
        let mut repo = repo_with(&["a", "b"]);
        let removed = repo.remove(NoteId(1)).unwrap();
        assert_eq!(removed.text, "a");
        assert!(repo.remove(NoteId(1)).is_none());
        assert_eq!(repo.next_id(), NoteId(3));
    }

    #[test]
    fn page_out_of_range_is_empty() {
        let repo = repo_with(&["a", "b", "c"]);
        assert_eq!(repo.page(2, 2).len(), 1);
        assert!(repo.page(5, 2).is_empty());
        assert!(InMemoryRepo::<Note>::new().is_empty());
    }
}
```

**Why this test design matters.** If the repo tests used `Company`, a bug that only shows up for
types *unlike* `Company` could hide, and the tests would break whenever `Company` changes. A
test-only entity is the minimal thing that satisfies the bounds. If it compiles, you've also
proved the bounds are exactly `Entity` (+ `From<u64>` for `next_id`) and nothing CRM-specific
leaked in.

**Details worth noticing:**

- `NoteId` derives exactly the four traits `Entity::Id` demands (`Copy`, `Eq`, `Hash`, `Debug`)
  plus `Clone` (required by `Copy`) and `PartialEq` (required by `Eq`). Remove one and the
  `impl Entity for Note` line fails, as in Lab 15 Step 4.
- `InMemoryRepo::new()` in `repo_with` has no type annotation: the return type
  `InMemoryRepo<Note>` lets the compiler infer `T = Note`.
- `InMemoryRepo::<Note>::new()` is the **turbofish** (`::<>`): where nothing else pins down `T`,
  you name it explicitly.
- `.text.push_str(" v2")` through `get_mut(...).unwrap()` mutates the item *inside* the repo; the
  `&mut Note` is a temporary that ends at the semicolon.
- The removed note is **owned** by the test afterwards (`removed.text` is readable after the repo
  forgot it).

---

## 🧪 Experiment answers

**Experiment 1 (derive Default).** The question to ask before deriving `Default` (or `Clone`,
`Copy`, `PartialEq`...) on a generic type: *does the derive's automatic `T: Trait` bound match
what my fields actually need?* For `Vec<T>` fields, an empty default needs nothing from `T`. And
second: *is the all-zeros/empty value actually a valid state?* Here `next_id: 0` is not.

**Experiment 3 (narrow bounds).** With `next_id` in its own block and `From<u64> for ContactId`
deleted, `get`, `remove`, `page` and the rest work again for contacts. The remaining errors are
exactly the places that *really* convert a `u64` into a `ContactId`:

```text
error[E0277]: the trait bound `ContactId: From<u64>` is not satisfied
  --> src/cli/parser.rs:93:17
   |
93 |             id: parse_id(args.get(1), "contact show <id>")?,
   |                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ unsatisfied trait bound
...
error[E0599]: the method `next_id` exists for struct `InMemoryRepo<Contact>`, but its trait bounds were not satisfied
  --> src/crm.rs:47:31
   |
47 |             id: self.contacts.next_id(),
   |                               ^^^^^^^ private field, not a method
```

(The odd label "private field, not a method" appears because the struct also has a private
*field* called `next_id`. The compiler mentions it in case you meant the field. You didn't.)
Narrow bounds mean errors appear at the code that actually needs the capability, and nowhere else.

---

## Checkpoint notes

1. Their bodies only move, store, borrow and count `T`s, which every type supports. `get` calls
   `id()`, which only `Entity` types have.
2. It would restrict the repo to entities whose id type is literally `u64`. The design accepts
   each entity's own id type, `T::Id`.
3. It permits converting a `u64` into `T::Id` (`T::Id::from(raw)` / `raw.into()`). Only
   `next_id` needs that; putting it on the trait would force every future entity to be
   constructible from a `u64`, including database-minted ids later.
4. The struct's definition requires `T: Entity`, so `InMemoryRepo<T>` isn't a well-formed type
   without it, in any impl.
5. The derive adds `T: Default` (so `Company: Default`, which is false and unneeded), and it would
   initialise `next_id` to 0.
6. Privacy is per module: `items` is private to `crate::repo`, `all()` is public. Inherent methods
   are part of the type, so no import is needed (unlike trait methods).
7. One per `T` that calls it: two (`Company`, `Contact`). `nm -C target/debug/rust-crm | grep`.
   Nothing calls `page` on companies, so that instantiation was never generated.
8. Ids identify records; they don't count them. Never reusing ids is what matters (no stale
   reference can ever point at a different record). Databases behave the same way.

# Lab 17 — Solutions

> 🔴 **SOLUTION**: read this *after* a genuine attempt. Your code doesn't need to match exactly.
> If it meets the acceptance criteria and you can explain every line, it's correct.

---

## Your Turn 1 — `CompanyFilter` and `Crm::list_companies`

`src/companies/filter.rs`:

```rust
//! What `company list` can filter by.

use super::model::{Company, Lifecycle};

/// Criteria for listing companies. `CompanyFilter::default()` matches every company.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CompanyFilter {
    pub lifecycle: Option<Lifecycle>,
    pub search: Option<String>,
}

impl CompanyFilter {
    pub fn matches(&self, company: &Company) -> bool {
        let lifecycle_ok = self.lifecycle.is_none_or(|l| company.lifecycle == l);
        let search_ok = self.search.as_deref().is_none_or(|term| {
            let term = term.to_lowercase();
            company.name.to_lowercase().contains(&term)
                || company
                    .website
                    .as_deref()
                    .is_some_and(|w| w.to_lowercase().contains(&term))
        });
        lifecycle_ok && search_ok
    }
}
```

`src/companies/mod.rs`:

```rust
mod filter;
mod model;

pub use filter::CompanyFilter;
pub use model::{Company, CompanyId, Lifecycle};
```

`src/crm.rs`:

```rust
    /// Companies matching `filter`, oldest first.
    pub fn list_companies(&self, filter: &CompanyFilter) -> Vec<&Company> {
        self.companies.find_where(|c| filter.matches(c))
    }
```

**Reading `is_none_or` and `is_some_and`.** They're `Option` combinators that answer the two
questions a filter keeps asking:

- `opt.is_none_or(|x| p(x))`: "absent, **or** present and satisfying `p`". That's exactly "no
  criterion, or the criterion holds".
- `opt.is_some_and(|x| p(x))`: "present **and** satisfying `p`". A company with no website can't
  match by website.

They're the `Option` versions of `all` and `any`: an `Option` is a collection of zero or one
items. If you wrote `match` expressions like `ContactFilter::matches`, that's equally correct;
compare the two and pick the one you find clearer.

**`self.lifecycle.is_none_or(|l| company.lifecycle == l)`** takes `self.lifecycle` by value. That's
fine because `Option<Lifecycle>` is `Copy` (Lab 15 derived `Copy` on `Lifecycle`), so `self` isn't
affected. `self.search` isn't `Copy` (it owns a `String`), so we call `.as_deref()` first to get an
`Option<&str>`, which borrows.

**The closure passed to `find_where`** captures `filter` (a `&CompanyFilter`) by reference and only
reads it: `Fn`. It's created fresh on each call and lives only during `find_where`.

Tests (in `src/companies/filter.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::companies::CompanyId;

    fn acme() -> Company {
        let mut c = Company::new(CompanyId(1), "Acme Corp".into(), Some("acme.io".into()));
        c.lifecycle = Lifecycle::Customer;
        c
    }

    #[test]
    fn default_filter_matches_everything() {
        assert!(CompanyFilter::default().matches(&acme()));
    }

    #[test]
    fn lifecycle_must_match() {
        let customers = CompanyFilter {
            lifecycle: Some(Lifecycle::Customer),
            ..Default::default()
        };
        let prospects = CompanyFilter {
            lifecycle: Some(Lifecycle::Prospect),
            ..Default::default()
        };
        assert!(customers.matches(&acme()));
        assert!(!prospects.matches(&acme()));
    }

    #[test]
    fn search_looks_at_name_and_website_case_insensitively() {
        let by = |term: &str| CompanyFilter {
            search: Some(term.into()),
            ..Default::default()
        };
        assert!(by("ACME").matches(&acme()));
        assert!(by(".io").matches(&acme()));
        assert!(!by("globex").matches(&acme()));
    }

    #[test]
    fn both_criteria_must_hold() {
        let filter = CompanyFilter {
            lifecycle: Some(Lifecycle::Churned),
            search: Some("acme".into()),
        };
        assert!(!filter.matches(&acme()));
    }
}
```

`by` is a closure that *returns a struct*: a tiny factory. It captures nothing, so it's `Fn` and
could even coerce to a `fn(&str) -> CompanyFilter` pointer.

---

## Your Turn 2 — `company list` flags

`src/cli/parser.rs`:

```rust
use crate::companies::{CompanyFilter, CompanyId, Lifecycle};

#[derive(Debug, PartialEq)]
pub(crate) enum CompanyCommand {
    Add,
    List { filter: CompanyFilter },
    Show { id: CompanyId },
    Stage { id: CompanyId, lifecycle: Lifecycle },
    Delete { id: CompanyId },
}

// in parse_company:
        Some("list") => Ok(CompanyCommand::List {
            filter: parse_company_list(&args[1..])?,
        }),

const COMPANY_LIST_USAGE: &str =
    "company list [--stage <prospect|customer|churned>] [--search <term>]";

fn parse_company_list(args: &[&str]) -> Result<CompanyFilter, CrmError> {
    let mut filter = CompanyFilter::default();
    for (flag, value) in flag_pairs(args, COMPANY_LIST_USAGE)? {
        match flag {
            "--stage" => filter.lifecycle = Some(value.parse()?),
            "--search" => filter.search = Some(value.to_string()),
            _ => return Err(CrmError::Usage(COMPANY_LIST_USAGE)),
        }
    }
    Ok(filter)
}
```

`Some(value.parse()?)` is Lab 15's payoff in one expression: the target type comes from
`filter.lifecycle: Option<Lifecycle>`, `.parse()` runs your `FromStr`, and `?` turns the
`ValidationError` into `CrmError::Validation(...)` via `From`. That's why a bad stage reports the
precise lifecycle message, while a *missing* value fails earlier, in `flag_pairs`, as a usage error.

`src/cli/commands.rs`:

```rust
        CompanyCommand::List { filter } => {
            let companies = crm.list_companies(&filter);
            if companies.is_empty() {
                println!("No companies match.");
            } else {
                print_table(COMPANY_HEADER, &companies);
            }
        }
```

`&companies` is a `&Vec<&Company>`, which derefs to `&[&Company]`; `&Company: Display` through the
blanket impl (Lab 15). `print_table` didn't change at all.

Parser tests:

```rust
    use crate::errors::ValidationError;   // in the test module

    #[test]
    fn company_list_flags() {
        let command = parse_command("company list --search acme --stage customer")
            .unwrap()
            .unwrap();
        let expected = CompanyFilter {
            lifecycle: Some(Lifecycle::Customer),
            search: Some("acme".to_string()),
        };
        assert_eq!(command, Command::Company(CompanyCommand::List { filter: expected }));
    }

    #[test]
    fn company_list_bad_stage_is_a_validation_error() {
        assert!(matches!(
            parse_command("company list --stage won"),
            Err(CrmError::Validation(ValidationError::InvalidLifecycle(_)))
        ));
        assert!(matches!(
            parse_command("company list --stage"),
            Err(CrmError::Usage(_))
        ));
    }
```

`matches!` with a nested pattern checks the *shape* of the error without needing `CrmError:
PartialEq` (which it doesn't implement, and won't, from Lab 21 on).

Session check:

```text
crm> company list --stage customer
ID   NAME                 STAGE     WEBSITE
#2   Globex               customer  globex.com
crm> company list --search INI
ID   NAME                 STAGE     WEBSITE
#3   Initech              churned   initech.com
crm> company list --stage won
Error: invalid lifecycle 'won' (expected prospect, customer or churned)
```

Updated help (the full block, for reference):

```rust
fn print_help() {
    println!("Commands:");
    println!("  company add");
    println!("  company list [--stage <prospect|customer|churned>] [--search <term>]");
    println!("  company show <id> | stage <id> <stage> | delete <id>");
    println!("  contact add");
    println!("  contact list [--company <id>] [--search <term>] [--sort id|name|email] [--page <n>]");
    println!("  contact show <id> | update <id> | delete <id> | search <term>");
    println!("  stats | help | version | quit");
}
```

---

## Your Turn 3 — `stats`

`src/companies/model.rs`:

```rust
impl Lifecycle {
    /// Every stage, in pipeline order.
    pub const ALL: [Lifecycle; 3] = [Lifecycle::Prospect, Lifecycle::Customer, Lifecycle::Churned];
}
```

Rust has no built-in "all variants of this enum". A `const` array is the dependency-free way, and
if you add a variant later, you must remember to add it here (a test that checks
`Lifecycle::ALL.len()` against the number of `match` arms in `Display` is one way to be reminded).

`src/stats.rs`:

```rust
//! Numbers about the whole CRM, computed with iterators.

use std::collections::HashMap;

use crate::companies::Lifecycle;
use crate::crm::Crm;

#[derive(Debug, PartialEq)]
pub struct CrmStats {
    /// Every lifecycle stage in `Lifecycle::ALL` order, including zero counts.
    pub companies_by_lifecycle: Vec<(Lifecycle, usize)>,
    pub contacts_with_company: usize,
    pub contacts_without_company: usize,
    /// Most common email domains first; ties sorted alphabetically.
    pub top_domains: Vec<(String, usize)>,
}

impl Crm {
    pub fn stats(&self, top_n: usize) -> CrmStats {
        let companies_by_lifecycle = Lifecycle::ALL
            .iter()
            .map(|&stage| {
                let count = self
                    .companies
                    .iter()
                    .filter(|c| c.lifecycle == stage)
                    .count();
                (stage, count)
            })
            .collect();

        let (with, without): (Vec<_>, Vec<_>) = self
            .contacts
            .iter()
            .partition(|c| c.company_id.is_some());

        let mut domain_counts: HashMap<&str, usize> = HashMap::new();
        for contact in self.contacts.iter() {
            if let Some((_, domain)) = contact.email.as_str().split_once('@') {
                *domain_counts.entry(domain).or_insert(0) += 1;
            }
        }
        let mut top_domains: Vec<(String, usize)> = domain_counts
            .into_iter()
            .map(|(domain, count)| (domain.to_string(), count))
            .collect();
        top_domains.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        top_domains.truncate(top_n);

        CrmStats {
            companies_by_lifecycle,
            contacts_with_company: with.len(),
            contacts_without_company: without.len(),
            top_domains,
        }
    }
}
```

And `pub mod stats;` in `src/lib.rs`. Walk through each part.

**Companies per stage.** An iterator over the three stages, each mapped to `(stage, count)`.
`|&stage|` is a **pattern** in the closure parameter: `iter()` over an array yields `&Lifecycle`,
and `&stage` destructures the reference so `stage` is a plain `Lifecycle` (allowed because it's
`Copy`). Iterating stages (not companies) guarantees every stage appears, including zeros, in a
fixed order. This is three passes over the companies; for a CRM-sized dataset that's irrelevant,
and Lab 18's pipeline report shows the single-pass version with a `BTreeMap`.

**With / without a company.** `partition` splits one iterator into two collections in a single
pass. The `(Vec<_>, Vec<_>)` annotation is required: `partition` is generic over the collection
type, like `collect`. We only need the lengths; two `filter(..).count()` calls would avoid building
the vectors. Both are fine; `partition` reads as "split into two groups", which is what we mean.

**Domain counts.** The `for` loop with `entry(..).or_insert(0)` is the classic counting idiom:
look up the slot for `domain`, insert `0` if it's new, and get a `&mut usize` to it, all in one
lookup. Note `HashMap<&str, usize>`: the keys **borrow** from the contacts' emails, so counting
allocates nothing per contact. That borrow is why the map can't outlive `self`.

(A purely iterator-based alternative is `fold`:
`self.contacts.iter().filter_map(|c| c.email.as_str().split_once('@')).fold(HashMap::new(), |mut m, (_, d)| { *m.entry(d).or_insert(0) += 1; m })`.
It works; whether it's clearer than the `for` loop is a matter of taste. A `for` loop is not a
failure to use iterators.)

**From map to sorted list: `into_iter` as an ownership move.** `domain_counts.into_iter()`
**consumes** the map, yielding owned `(&str, usize)` pairs; we don't need the map afterwards.
`map` converts each `&str` into an owned `String`, so the result (`CrmStats`) borrows nothing from
the CRM and can be returned freely. A `HashMap` has no order, so we sort:

- `b.1.cmp(&a.1)`: by count, **descending** (`b` before `a` reverses the order)
- `.then_with(|| a.0.cmp(&b.0))`: on a tie, by domain, ascending. `then_with` takes a closure, so
  the second comparison is only computed when the first is `Equal` (laziness again)

`truncate(top_n)` keeps the first `top_n`. (`.into_iter().take(top_n).collect()` would also work.)

The CLI side, in `src/cli/commands.rs`:

```rust
const TOP_DOMAINS: usize = 3;

fn print_stats(crm: &Crm) {
    let stats = crm.stats(TOP_DOMAINS);
    let total_companies: usize = stats.companies_by_lifecycle.iter().map(|(_, n)| n).sum();
    println!("Companies: {total_companies}");
    for (stage, count) in &stats.companies_by_lifecycle {
        println!("  {stage:<10} {count}");
    }
    println!(
        "Contacts: {} ({} with a company, {} without)",
        stats.contacts_with_company + stats.contacts_without_company,
        stats.contacts_with_company,
        stats.contacts_without_company
    );
    if !stats.top_domains.is_empty() {
        println!("Top email domains:");
        for (domain, count) in &stats.top_domains {
            println!("  {domain:<14} {count}");
        }
    }
}
```

plus `Stats` in the `Command` enum, `"stats" => Command::Stats` in `parse_command`, and
`Command::Stats => print_stats(crm),` in `execute`.

- `.map(|(_, n)| n).sum()` sums `&usize`s: `usize` implements `Sum<&usize>` as well as
  `Sum<usize>`, so no `.copied()` is needed. (Lab 18 implements both forms for `Money`, and explains
  why both exist.)
- `for (stage, count) in &stats.companies_by_lifecycle` iterates **by reference** (`&Vec` →
  `iter()`), destructuring each `&(Lifecycle, usize)` into `stage: &Lifecycle, count: &usize`.
  `{stage:<10}` pads because `Lifecycle`'s `Display` uses `f.pad`.

Tests (in `src/stats.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::contacts::Email;

    #[test]
    fn empty_crm_has_zero_everything() {
        let stats = Crm::new().stats(3);
        assert_eq!(
            stats.companies_by_lifecycle,
            vec![
                (Lifecycle::Prospect, 0),
                (Lifecycle::Customer, 0),
                (Lifecycle::Churned, 0)
            ]
        );
        assert_eq!(stats.contacts_with_company, 0);
        assert_eq!(stats.contacts_without_company, 0);
        assert!(stats.top_domains.is_empty());
    }

    #[test]
    fn counts_stages_companies_and_domains() {
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".into(), None).unwrap();
        let globex = crm.add_company("Globex".into(), None).unwrap();
        crm.set_lifecycle(globex, Lifecycle::Customer).unwrap();
        for (name, email, company) in [
            ("Ada", "ada@acme.io", Some(acme)),
            ("Alan", "alan@acme.io", Some(acme)),
            ("Bob", "bob@globex.com", Some(globex)),
            ("Grace", "grace@navy.mil", None),
            ("Zed", "zed@globex.com", None),
        ] {
            crm.add_contact(name.into(), Email::parse(email).unwrap(), None, company)
                .unwrap();
        }

        let stats = crm.stats(2);
        assert_eq!(
            stats.companies_by_lifecycle,
            vec![
                (Lifecycle::Prospect, 1),
                (Lifecycle::Customer, 1),
                (Lifecycle::Churned, 0)
            ]
        );
        assert_eq!(stats.contacts_with_company, 3);
        assert_eq!(stats.contacts_without_company, 2);
        assert_eq!(
            stats.top_domains,
            vec![("acme.io".to_string(), 2), ("globex.com".to_string(), 2)]
        );
    }
}
```

`assert_eq!` on whole `Vec`s of tuples works because `CrmStats` fields are compared element by
element; `Lifecycle: PartialEq + Debug` (derived) makes the tuples comparable and printable. The
`top_n = 2` case also proves the tie-break and the truncation in one assertion.

---

## 🧪 Experiment answers

**Experiment 1 (borrowed sort key).** In `list_contacts`, the vector holds `&'a Contact`
references into the repo. The key closure receives `&&'a Contact` and returns `&'a String`: a
borrow of the **contact**, which lives in the repo and isn't moved by the sort. In
`three_ways_to_iterate`, the vector holds the `Contact`s themselves. The key would borrow from a
slot *inside the vector being sorted*, and `sort_by_key`'s signature (`F: FnMut(&T) -> K`, with
`K` not allowed to borrow from the `&T`) forbids it, because the sort moves elements around while
keys exist. The closure's input lifetime `'1` is shorter than the output lifetime `'2` the sort
needs.

And the first version sorts **case-sensitively** (byte order): `Bob` < `alice` because uppercase
ASCII letters come before lowercase ones. `--sort name` is for humans; `to_lowercase` (or a proper
locale-aware collation, which needs a crate) is the right key.

**Experiment 2 (lowercasing once).** Options, each with a trade-off:

- Normalise in the parser: `filter.search = Some(value.to_lowercase())`, and document "`search`
  must be lowercase". Fast, but the invariant isn't enforced; any other code building a
  `ContactFilter` (Lab 29's HTTP handler) can break it.
- Make `search` a private field with a constructor that lowercases. Enforced, but the struct is
  no longer a plain bag of `pub` fields; struct update syntax stops working outside the module.
- In `list_contacts`, compute `let term = filter.search.as_deref().map(str::to_lowercase);` once,
  and match against it in the closure (moving the logic out of `matches`). Fast, but `matches`
  stops being the single source of truth.

For a CRM with hundreds of contacts, the allocation per contact is irrelevant, and the simple
version wins. This is a "measure first" decision.

**Experiment 3 (`fn` items).** It compiles. A function item like `has_phone` implements all three
`Fn*` traits (and coerces to a `fn(&Contact) -> bool` pointer). A plain function has **no captures**:
there's nothing it could mutate or consume between calls, so it can always be called again, through
any reference. It's the limiting case of a closure.

**Step 5 mini-task.** `2`. `c.company_id` is an `Option<CompanyId>`, exactly the
`Option<B>` that `filter_map`'s closure must return, so the field can be returned directly (it's
`Copy`, so reading it through `&Contact` copies it).

---

## Checkpoint notes

1. `next(&mut self) -> Option<Self::Item>`. Producing the next item changes the iterator's state
   (its position).
2. `let mut it = IntoIterator::into_iter(&contacts); while let Some(c) = it.next() { ... }`. The
   impl for `&Vec<T>`, so `c: &Contact`.
3. Adapters are lazy: `map` built a `Map` struct and nobody called `next` on it. Items flow one at
   a time through the whole chain: item 1 through filter and map, then item 2, and so on.
4. Argument position: the caller chooses the type. Return position: the function chooses a concrete
   type and hides it. In edition 2021, return-position `impl Trait` only captured lifetimes named in
   its bounds, so a borrowed iterator needed `+ '_`; edition 2024 captures all in-scope lifetimes.
5. `struct C<'a> { company_id: &'a CompanyId }` with an `Fn` impl. With `move`:
   `struct C { company_id: CompanyId }` (a copy, since `CompanyId: Copy`).
6. `Fn`; `FnMut`; `FnOnce`. `find_where` (needs `Fn`) accepts only the first. `Iterator::filter`
   (needs `FnMut`) accepts the first two. Neither accepts the third: both call the predicate more
   than once.
7. The closure is returned, so it can't borrow `works_at`'s local `company_id`; `move` makes it
   own a copy. `move` controls *how* captures are taken; `FnOnce` depends on whether the *body*
   consumes them, and this body only reads.
8. When you're done with the collection and want owned items (e.g. to move fields out without
   cloning). The collection is moved into the iterator and is gone afterwards.
9. Paging must happen after filtering and sorting, which the repo knows nothing about. Paging the
   raw storage only worked for the unfiltered, insertion-order list.

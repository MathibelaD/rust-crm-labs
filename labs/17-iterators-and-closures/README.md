# Lab 17 — Iterators & Closures

> **Phase:** 4 — Abstraction · **Builds on:** Lab 16 · **Time:** ~6 hours
> **Your repo before this lab:** tag `lab-16` · **After:** tag `lab-17`

> This lab assumes you completed **Your Turn 3 in Lab 15** (generic `parse_id`) and
> **Your Turns 1–2 in Lab 16** (`InMemoryRepo<Contact>::search`, and the repo test module with a
> test-only `Note` entity and a `repo_with` helper). If you skipped any, copy them from
> [Lab 15's](../15-traits/solutions.md) and [Lab 16's](../16-generics/solutions.md) solutions first.

## 🎯 Goal

Turn `list` into a small query engine:

```text
crm> contact list --company 1 --sort name
crm> contact list --search ada --page 2
crm> company list --stage customer --search acme
crm> stats
```

You'll build it with iterators and closures, and along the way take apart *how* iterators and
closures work: what `for` really does, why `map` without `collect` does nothing, what a closure
is in memory, and why the compiler sometimes says your closure "only implements `FnOnce`".

## 🧠 What You'll Learn

- The `Iterator` trait: one required method (`next`), dozens of free ones
- What a `for` loop desugars to, and why `next` takes `&mut self`
- Writing an iterator **by hand**, then replacing it with `impl Iterator`
- `impl Trait` in **return** position, and how it captures lifetimes (edition 2024 vs 2021)
- **Laziness**: adapters build a pipeline; nothing runs until a consumer pulls
- The everyday adapters (`map`, `filter`, `filter_map`, `enumerate`, `skip`/`take`, `chain`,
  `flat_map`, `inspect`) and consumers (`collect`, `count`, `sum`, `fold`, `any`, `all`, `find`,
  `position`, `max_by_key`, `partition`)
- `iter()` vs `iter_mut()` vs `into_iter()`: three ownership modes
- Closures as **structs that capture their environment**
- `Fn` / `FnMut` / `FnOnce`, explained by what a closure does with its captures, with the real
  errors (E0594, E0507, E0525)
- `move` closures and returning closures (E0373)
- Sorting with `sort_by_key`, `sort_by_cached_key` and `sort_by`

## 🔨 What We're Building

`contact list` currently prints a fixed page of everyone. A CRM user wants "Acme's contacts,
sorted by name" or "everyone whose name or email mentions ada". You'll add:

- `InMemoryRepo::iter()` and `InMemoryRepo::find_where(predicate)`: generic querying for every
  entity
- `ContactFilter` / `ContactSort` (in `src/contacts/filter.rs`) and `CompanyFilter`
  (in `src/companies/filter.rs`), each with a `matches` method
- `Crm::list_contacts(&ContactFilter)` and `Crm::list_companies(&CompanyFilter)`
- flags: `contact list [--company <id>] [--search <term>] [--sort id|name|email] [--page <n>]` and
  `company list [--stage <lifecycle>] [--search <term>]`
- a `stats` command: companies per lifecycle stage, contacts with and without a company, top email
  domains

These pipelines come back in Lab 18's pipeline report and Lab 29's `?search=&sort=&page=` API
parameters.

---

## Step 1 — The `Iterator` trait

(As in every lab, the line numbers in the compiler output shown below come from the reference
solution and will differ from yours. The messages won't.)

You've used iterators since Lab 05 (`for c in &customers`) and called `.iter().filter(..)` a
few times without much explanation. Here's the whole contract, from the standard library:

```rust
pub trait Iterator {
    type Item;

    fn next(&mut self) -> Option<Self::Item>;

    // ... plus about 75 provided methods: map, filter, count, sum, collect, ...
}
```

That's it. **One** required method. An iterator is a value that can hand you the next item, or
`None` when it's finished. Everything else (`map`, `filter`, `sum`...) is a **default method**
(Lab 15) written in terms of `next`.

Three details to absorb now:

- **`type Item`** is an associated type (Lab 15): each iterator yields exactly one item type.
- **`next(&mut self)`** takes `&mut`, because an iterator *changes* as you use it: it has to
  remember where it is. An iterator is a little state machine.
- **`Option<Self::Item>`** is how it says "done". After `None`, well-behaved iterators keep
  returning `None`.

And here's what `for` really is. This:

```rust
for contact in crm.contacts.all() {
    println!("{contact}");
}
```

is shorthand for:

```rust
let mut iter = IntoIterator::into_iter(crm.contacts.all());
while let Some(contact) = iter.next() {
    println!("{contact}");
}
```

`IntoIterator` is "a thing that can be *turned into* an iterator": collections, slices, ranges,
and every iterator itself (trivially). Keep this desugaring in mind; Step 7 uses it to explain
ownership.

---

## Step 2 — Write an iterator by hand

The repo currently exposes `all() -> &[T]`, which tells callers "it's a slice inside a `Vec`".
That's an implementation detail you'll want to hide. In Lab 23 the data may not live in a `Vec`
at all. An iterator hides it. First, write one yourself so there's no magic.

> 🟢 **FOLLOW ALONG**: in `src/repo.rs`, above the `impl ... where T::Id: From<u64>` block:

```rust
/// A hand-written iterator over a repo's items.
pub struct RepoIter<'a, T> {
    items: &'a [T],
    position: usize,
}

impl<'a, T> Iterator for RepoIter<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<Self::Item> {
        let item = self.items.get(self.position)?;
        self.position += 1;
        Some(item)
    }
}
```

and inside `impl<T: Entity> InMemoryRepo<T>`:

```rust
    /// Iterates over every item, oldest first.
    pub fn iter(&self) -> RepoIter<'_, T> {
        RepoIter {
            items: &self.items,
            position: 0,
        }
    }
```

Read the lifetimes with Lab 10 eyes:

- `RepoIter<'a, T>` holds `&'a [T]`: it **borrows** the repo's items for `'a`. While a `RepoIter`
  exists, the repo can't be mutated.
- `type Item = &'a T`: each item is borrowed for the **same** `'a`, from the repo, not from the
  iterator. That's important. `next(&mut self)` borrows the *iterator* only for the call, but the
  item it returns lives as long as the repo borrow. So you can collect items into a `Vec<&T>` and
  keep them after the iterator is gone.
- `self.items.get(self.position)?`: `get` returns `Option<&'a T>`, and `?` returns `None` from
  `next` when we run off the end.
- `iter(&self) -> RepoIter<'_, T>`: `'_` says "the lifetime of `&self`", by elision.

Now test it, in the test module you wrote in Lab 16 Your Turn 2:

```rust
    #[test]
    fn iter_yields_items_in_insertion_order() {
        let repo = repo_with(&["a", "b", "c"]);
        let mut iter = repo.iter();
        assert_eq!(iter.next().map(|n| n.text.as_str()), Some("a"));
        assert_eq!(iter.next().map(|n| n.text.as_str()), Some("b"));
        assert_eq!(iter.next().map(|n| n.text.as_str()), Some("c"));
        assert!(iter.next().is_none());
        assert!(iter.next().is_none());
    }

    #[test]
    fn iter_gets_adapters_for_free() {
        let repo = repo_with(&["call Ada", "email Bob", "call Cy"]);
        let calls: Vec<&str> = repo
            .iter()
            .filter(|n| n.text.starts_with("call"))
            .map(|n| n.text.as_str())
            .collect();
        assert_eq!(calls, vec!["call Ada", "call Cy"]);
    }
```

Run `cargo test repo`. The second test is the point: you wrote **only** `next`, and `filter`,
`map` and `collect` work on `RepoIter`. They're default methods of `Iterator`, exactly like
`is_valid` on your `Validate` trait in Lab 15, just more of them.

---

## Step 3 — Hide the type: `impl Iterator`

Your hand-written iterator does what `std`'s slice iterator already does (the real one is faster:
it uses pointer arithmetic instead of bounds-checked `get`). Swap it in without changing the
callers.

> 🟢 **FOLLOW ALONG**: delete `RepoIter` and its `impl Iterator` entirely, and change `iter` to:

```rust
    /// Iterates over every item, oldest first.
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.items.iter()
    }
```

`cargo test repo`: both tests still pass, untouched.

`impl Iterator<Item = &T>` in **return** position means: "this returns *some* concrete type that
implements `Iterator<Item = &T>`. I'm not telling you which." The caller can use every
`Iterator` method, but can't name or depend on the concrete type (`std::slice::Iter<'_, T>`).
That's what let you swap `RepoIter` out with zero changes at the call sites. Compare Lab 15's
argument position: `fn f(x: impl Display)` lets the **caller** choose the type; `-> impl
Iterator` lets the **function** choose and hide it. Same syntax, opposite direction.

It's still static dispatch: the compiler knows the real type and monomorphizes as usual. No
`Box`, no vtable.

### The hidden lifetime

The returned iterator borrows `self.items`. How does the signature say so? Your crate uses
**edition 2024**, where an `impl Trait` return type automatically **captures every lifetime in
scope**, including the one on `&self`. In older code (edition 2021) you'll often see this written
as `-> impl Iterator<Item = &T> + '_`. Here's why. This tiny standalone snippet (don't add it to
the CRM) returns an iterator whose `Item` doesn't mention any lifetime:

```rust
struct Repo {
    ids: Vec<u64>,
}

impl Repo {
    fn ids(&self) -> impl Iterator<Item = u64> {
        self.ids.iter().copied()
    }
}
```

Compiled as edition 2021 (`rustc --edition 2021`):

```text
error[E0700]: hidden type for `impl Iterator<Item = u64>` captures lifetime that does not appear in bounds
 --> capture.rs:7:9
  |
6 |     fn ids(&self) -> impl Iterator<Item = u64> {
  |            -----     ------------------------- opaque type defined here
  |            |
  |            hidden type `Copied<std::slice::Iter<'_, u64>>` captures the anonymous lifetime defined here
7 |         self.ids.iter().copied()
  |         ^^^^^^^^^^^^^^^^^^^^^^^^
  |
help: add a `use<...>` bound to explicitly capture `'_`
  |
6 |     fn ids(&self) -> impl Iterator<Item = u64> + use<'_> {
  |                                                +++++++++
```

In 2021, the opaque type could only borrow lifetimes that appeared in its bounds; `u64` mentions
none, so you had to add `+ '_` (or the newer `+ use<'_>`). With edition 2024 it compiles as is.
The *borrow* is the same in both editions: the returned iterator keeps `self` borrowed. The
edition only changed whether you have to spell it out.

> 🟡 **EXPERIMENT**: prove that the iterator really holds a borrow. In `contact delete`, try to
> keep an iterator alive across a mutation:

```rust
            let mut everyone = crm.contacts.iter();
            let contact = crm.remove_contact(id)?;
            print_deleted("contact", &contact);
            println!("first contact: {:?}", everyone.next().map(|c| &c.name));
```

```text
error[E0502]: cannot borrow `*crm` as mutable because it is also borrowed as immutable
   --> src/cli/commands.rs:143:27
    |
142 |             let mut everyone = crm.contacts.iter();
    |                                ------------ immutable borrow occurs here
143 |             let contact = crm.remove_contact(id)?;
    |                           ^^^^^^^^^^^^^^^^^^^^^^ mutable borrow occurs here
...
146 |         }
    |         - immutable borrow might be used here, when `everyone` is dropped and runs the destructor for type `impl Iterator<Item = &Contact>`
```

Lab 07's rule, with a twist in the last line. The compiler doesn't know the concrete type behind
`impl Iterator`, so it must assume it *might* have a destructor that touches the borrow. With an
opaque type, the borrow lasts until the variable goes out of scope, not just until its last use.
(Imagine iterating a `Vec` while `remove_contact` shifts its elements: that's exactly the bug this
prevents.) Remove the experiment.

---

## Step 4 — Laziness

> 🟡 **EXPERIMENT**: add a temporary test to the `tests` module in `src/crm.rs`. First a helper
> you'll keep (later steps reuse it):

```rust
    fn sample_crm() -> Crm {
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".into(), None).unwrap();
        for (name, mail, company) in [
            ("Ada Lovelace", "ada@acme.io", Some(acme)),
            ("Grace Hopper", "grace@navy.mil", None),
            ("Alan Turing", "alan@acme.io", Some(acme)),
        ] {
            crm.add_contact(name.into(), email(mail), None, company)
                .unwrap();
        }
        crm
    }
```

(`email(..)` is the `Email::parse(..).unwrap()` helper from your Lab 14 tests; add it if you don't
have one.) Then the experiment. Predict what it prints:

```rust
    #[test]
    fn laziness() {
        let crm = sample_crm();
        crm.contacts.iter().map(|c| {
            println!("visiting {}", c.name);
            c
        });
        println!("done");
    }
```

```bash
cargo test laziness -- --nocapture
```

```text
warning: unused `Map` that must be used
   --> src/crm.rs:163:9
    |
163 | /         crm.contacts.iter().map(|c| {
164 | |             println!("visiting {}", c.name);
165 | |             c
166 | |         });
    | |__________^
    |
    = note: iterators are lazy and do nothing unless consumed
    = note: `#[warn(unused_must_use)]` (part of `#[warn(unused)]`) on by default
...
running 1 test
done
test crm::tests::laziness ... ok
```

No "visiting" at all. `map` didn't visit anything: it **built a value**, a `Map` struct holding
the inner iterator and your closure, and returned it. Nobody called `next` on it, so the closure
never ran. The compiler even warns you (`Iterator` adapters are marked `#[must_use]`).

Now a real pipeline. Replace the body:

```rust
        let crm = sample_crm();
        let at_acme = crm
            .contacts
            .iter()
            .inspect(|c| println!("  looking at {}", c.name))
            .filter(|c| c.email.as_str().ends_with("@acme.io"))
            .map(|c| {
                println!("  mapping {}", c.name);
                c.name.as_str()
            });
        println!("iterator built, nothing visited yet");
        let names: Vec<&str> = at_acme.collect();
        println!("collected {names:?}");
```

Predict the order of the lines first. Then run it:

```text
iterator built, nothing visited yet
  looking at Ada Lovelace
  mapping Ada Lovelace
  looking at Grace Hopper
  looking at Alan Turing
  mapping Alan Turing
collected ["Ada Lovelace", "Alan Turing"]
```

If you expected "look at all three, *then* map two", that's how JavaScript's
`array.filter(...).map(...)` works: each step builds a whole new array. Rust iterators don't.
`collect` calls `next` on the `Map`, which calls `next` on the `Filter`, which calls `next` on
`Inspect`, which calls `next` on the slice iterator: **one item travels the whole pipeline before
the next one starts.** No intermediate `Vec`s are allocated.

Change `at_acme.collect()` to `at_acme.take(1).collect()` and run again:

```text
iterator built, nothing visited yet
  looking at Ada Lovelace
  mapping Ada Lovelace
collected ["Ada Lovelace"]
```

Grace and Alan were never looked at. `take(1)` stops pulling after one item. Laziness isn't just
an optimisation: it's what makes `find`, `any` and `take` short-circuit, and what lets iterators be
infinite (`(1..).map(...)` is fine as long as something stops pulling).

Delete the `laziness` test (keep `sample_crm`).

---

## Step 5 — The vocabulary: adapters and consumers

Every iterator method is one of two kinds:

- **Adapters** take an iterator and return a new iterator. Lazy. Nothing happens yet.
- **Consumers** pull items through and return a final value. This is where work happens.

Here are the ones you'll reach for most, with CRM examples (`contacts` is
`crm.contacts.iter()` unless stated):

| Adapter | Does | CRM example |
|---|---|---|
| `map(f)` | Transform each item | `contacts.map(\|c\| c.name.as_str())` |
| `filter(p)` | Keep items where `p` is true | `contacts.filter(\|c\| c.phone.is_some())` |
| `filter_map(f)` | Transform **and** drop `None`s | `contacts.filter_map(\|c\| c.phone.as_deref())`: only the phones that exist |
| `enumerate()` | Pair with an index `(0, x)` | `contacts.enumerate().map(\|(i, c)\| format!("{}. {}", i + 1, c.name))` |
| `skip(n)` / `take(n)` | Drop / keep the first `n` | `contacts.skip(5).take(5)`: page 2 |
| `chain(other)` | One iterator after another | `a.iter().chain(b.iter())` |
| `flat_map(f)` | Map each item to an iterator and flatten | `companies.flat_map(\|co\| crm.contacts_of(co.id))`: all contacts of these companies |
| `inspect(f)` | Peek at items (debugging) | Step 4 |
| `copied()` / `cloned()` | `&T` → `T` (by `Copy` / `Clone`) | `contacts.map(\|c\| &c.id).copied()` |
| `rev()` | Backwards (needs a double-ended iterator) | `contacts.rev()`: newest first |

| Consumer | Returns | CRM example |
|---|---|---|
| `collect()` | Any collection that implements `FromIterator` (`Vec`, `String`, `HashMap`, `HashSet`, `Result<Vec<_>, E>`...) | `let names: Vec<&str> = ...collect();` |
| `count()` | `usize` | `contacts.filter(\|c\| c.company_id.is_none()).count()` |
| `sum()` | Any type that implements `Sum` | `contacts.map(\|c\| c.name.len()).sum::<usize>()` (Lab 18 makes `Money` summable) |
| `fold(init, f)` | One accumulated value | `contacts.fold(0, \|n, c\| n + c.name.len())` |
| `any(p)` / `all(p)` | `bool`, short-circuits | `contacts.any(\|c\| &c.email == email)`: that's `email_exists` |
| `find(p)` | `Option<Item>`, short-circuits | `find_by_id` from Lab 15 |
| `position(p)` | `Option<usize>` | `InMemoryRepo::remove` from Lab 16 |
| `max_by_key(f)` / `min_by_key(f)` | `Option<Item>` | `contacts.max_by_key(\|c\| c.name.len())`: longest name |
| `partition(p)` | Two collections | Your Turn 3 |
| `for_each(f)` | `()` | Like a `for` loop; prefer `for` unless at the end of a chain |

Two things to notice in that table: you've already been using iterator consumers in code you
wrote (`find`, `position`, `any`), and `collect` decides what to build from the **type you ask
for**. That's why `let names: Vec<&str> = ... .collect();` needs the annotation: `collect` is
generic over its output.

> 🔵 **Mini-task** (predict, then check in a scratch test): what does
> `crm.contacts.iter().filter_map(|c| c.company_id).count()` return for `sample_crm()`? What type
> is `c.company_id` and why does `filter_map` accept it directly?

---

## Step 6 — Closures are structs

You've been writing `|c| c.company_id == Some(company_id)` for a while. What *is* it?

A closure is an **anonymous struct** that the compiler generates for you, holding whatever the
closure body uses from its surroundings (its **captures**), plus an implementation of one or more
of the `Fn*` traits whose method is the closure body. This code:

```rust
let company_id = CompanyId(1);
let works_at_acme = |c: &Contact| c.company_id == Some(company_id);
```

is compiled roughly as:

```rust
// generated by the compiler (conceptually; the real name is unnameable)
struct Closure1<'a> {
    company_id: &'a CompanyId,      // captured by reference
}

impl<'a> Fn(&Contact) -> bool for Closure1<'a> {   // (pseudo-syntax)
    fn call(&self, c: &Contact) -> bool {
        c.company_id == Some(*self.company_id)
    }
}

let works_at_acme = Closure1 { company_id: &company_id };
```

```text
 stack frame of the function
 ┌──────────────────────────────┐
 │ company_id: CompanyId(1)     │◄────────┐
 ├──────────────────────────────┤         │ borrow
 │ works_at_acme: Closure1 {    │         │
 │     company_id: &────────────┼─────────┘
 │ }                            │
 └──────────────────────────────┘
   calling works_at_acme(&c) = Fn::call(&works_at_acme, &c)
```

Consequences:

- **Every closure has its own unique type.** Two closures with identical code are still two
  types. That's why functions accept closures generically (`F: Fn(&T) -> bool`) rather than by a
  concrete type.
- **A closure that captures nothing** is a zero-sized struct, and can even coerce to a plain
  function pointer `fn(&Contact) -> bool`.
- **Captures follow the borrow rules.** A closure that captures `&company_id` is a borrow of
  `company_id`, with a lifetime, exactly like a struct with a reference field (Lab 10).

### How a closure captures, and which `Fn` trait it gets

The compiler captures each variable in the **least powerful way the body allows**: by shared
reference if it only reads, by mutable reference if it mutates, by value if it moves the variable
out. Then it implements the `Fn*` traits that are possible given those captures:

| The body... | Captures | Implements | Can be called |
|---|---|---|---|
| only **reads** its captures | `&T` | `Fn` (and so also `FnMut`, `FnOnce`) | any number of times, even through a shared reference |
| **mutates** a capture | `&mut T` | `FnMut` (and `FnOnce`) | many times, but needs exclusive (`&mut`) access to the closure |
| **moves** a captured value out (gives it away, drops it) | `T` | only `FnOnce` | once: after that, the value it gave away is gone |

The traits form a hierarchy: every `Fn` is also an `FnMut`, and every `FnMut` is also an
`FnOnce`. So there are two perspectives:

- A **function that accepts a closure** chooses a bound. `F: FnOnce` accepts *every* closure but
  may only call it once. `F: Fn` accepts the fewest closures but may call it any number of times,
  from anywhere.
- A **closure** gets the most capable trait its body allows.

You'll now see each row fail in the CRM.

---

## Step 7 — `find_where`: a method that takes a closure

> 🟢 **FOLLOW ALONG**: in `impl<T: Entity> InMemoryRepo<T>`:

```rust
    /// Every item for which `predicate` returns true, oldest first.
    pub fn find_where<F>(&self, predicate: F) -> Vec<&T>
    where
        F: Fn(&T) -> bool,
    {
        self.items.iter().filter(|item| predicate(item)).collect()
    }
```

`F: Fn(&T) -> bool` reads: "`F` is any type callable with a `&T`, returning `bool`, any number of
times, through a shared reference". Each closure you pass gets its own monomorphized copy of
`find_where` (Lab 16), so the call to `predicate` is a direct, inlinable call. Closures passed to
generic functions are zero-cost.

(Why `|item| predicate(item)` and not `.filter(predicate)`? `filter` hands its closure a `&&T`,
a reference to each item the slice iterator yields. Our `predicate` wants `&T`. The little
closure auto-derefs one level. That's also why you saw `&&T` in Lab 16's E0599.)

Use it in `Crm::contacts_of`:

```rust
    pub fn contacts_of(&self, company_id: CompanyId) -> Vec<&Contact> {
        self.contacts.find_where(|c| c.company_id == Some(company_id))
    }
```

The closure only reads `company_id` → it's `Fn` → accepted.

### `FnMut`: a closure that mutates

> 🟡 **EXPERIMENT**: you want to know how many contacts a query checked. Temporarily change
> `contacts_of` to count calls:

```rust
        let mut checked = 0;
        let found = self.contacts.find_where(|c| {
            checked += 1;
            c.company_id == Some(company_id)
        });
        println!("checked {checked} contacts");
        found
```

```text
error[E0594]: cannot assign to `checked`, as it is a captured variable in a `Fn` closure
  --> src/crm.rs:96:13
   |
94 |           let mut checked = 0;
   |               ----------- `checked` declared here, outside the closure
95 |           let found = self.contacts.find_where(|c| {
   |                                     -          --- in this closure
   |  ___________________________________|
   | |
96 | |             checked += 1;
   | |             ^^^^^^^^^^^^ cannot assign
97 | |             c.company_id == Some(company_id)
98 | |         });
   | |__________- expects `Fn` instead of `FnMut`
   |
  ::: src/repo.rs:44:44
   |
44 |       pub fn find_where<F>(&self, predicate: F) -> Vec<&T>
   |                                              - change this to accept `FnMut` instead of `Fn`
```

**Who owns `checked`?** The function. The closure *captures* it by `&mut` because the body
assigns to it, which makes the closure `FnMut`. `find_where` promised (`F: Fn`) that it only needs
to call `predicate` through a shared reference, and a closure that holds a `&mut` can't be called
that way (two shared copies of the closure could both mutate `checked`: aliasing plus mutation,
Lab 07's forbidden combination).

Now replace `self.contacts.find_where(...)` with
`self.contacts.iter().filter(|c| { checked += 1; ... }).collect()`. It compiles, and prints
`checked 3 contacts` (or however many you have) every time a company is shown. `std`'s
`Iterator::filter` takes `P: FnMut(&Self::Item) -> bool`: it calls the predicate one item at a
time, through `&mut`, so mutation is fine.

So which bound is right for `find_where`? The compiler's suggestion ("change this to accept
`FnMut`") would make `find_where` accept *more* closures, and it would work: we call `predicate`
sequentially. We keep `Fn` deliberately. `find_where` is a **query** on a `&self` method: a
predicate that mutates state while answering "does this match?" is a smell, and `Fn` closures can
be shared freely (later, across threads in Lab 25). Either choice is defensible; the important
thing is that it's a *choice*, and the bound documents it. Remove the experiment.

### `FnOnce`: a closure that gives a capture away

> 🟡 **EXPERIMENT**: add this method to `impl Crm` (it reuses `ContactFilter` from Step 9, so
> do this experiment after Step 9 if you're typing along):

```rust
    pub fn contacts_named(&self, term: String) -> Vec<&Contact> {
        let named = move |c: &Contact| {
            let filter = ContactFilter {
                search: Some(term),
                ..Default::default()
            };
            filter.matches(c)
        };
        self.contacts.find_where(named)
    }
```

```text
error[E0525]: expected a closure that implements the `Fn` trait, but this closure only implements `FnOnce`
   --> src/crm.rs:98:21
    |
 98 |         let named = move |c: &Contact| {
    |                     ^^^^^^^^^^^^^^^^^^ this closure implements `FnOnce`, not `Fn`
 99 |             let filter = ContactFilter {
100 |                 search: Some(term),
    |                              ---- closure is `FnOnce` because it moves the variable `term` out of its environment
...
105 |         self.contacts.find_where(named)
    |                       ---------- ----- the requirement to implement `Fn` derives from here
    |                       |
    |                       required by a bound introduced by this call
```

Walk through it:

- **Who owns `term`?** The closure: `move` moved the `String` into the closure struct.
- **What does the body do with it?** `Some(term)` moves it *out* of the closure, into the new
  `ContactFilter`. After the first call, the closure no longer has a `term` to give. So it can only
  be called **once**: `FnOnce`.
- `find_where` needs to call it once per contact. Contradiction.

Now write the same closure **inline**, `self.contacts.find_where(move |c: &Contact| { ... })`, and
the error changes:

```text
error[E0507]: cannot move out of `term`, a captured variable in an `Fn` closure
   --> src/crm.rs:100:30
    |
 97 |     pub fn contacts_named(&self, term: String) -> Vec<&Contact> {
    |                                  ----  ------ move occurs because `term` has type `String`, which does not implement the `Copy` trait
    |                                  |
    |                                  captured outer variable
 98 |         self.contacts.find_where(move |c| {
    |                                  -------- captured by this `Fn` closure
 99 |             let filter = ContactFilter {
100 |                 search: Some(term),
    |                              ^^^^ `term` is moved here
```

Same problem, seen from the other side. Inline, the compiler knows up front the closure *must*
be `Fn`, so it reports the move inside the body as the error. Bound to a variable first, the
compiler infers `FnOnce` from the body and then reports the mismatch at the call.

**The fix is not "add `.clone()`"** (that would compile: `Some(term.clone())` only reads `term`,
so the closure becomes `Fn`, at the cost of one allocation per contact). The fix is to build the
filter **once, outside** the closure, and let the closure *borrow* it:

```rust
        let filter = ContactFilter { search: Some(term), ..Default::default() };
        self.contacts.find_where(|c| filter.matches(c))
```

Move work out of the per-item closure; capture by reference. Delete `contacts_named`; it was only
an experiment.

---

## Step 8 — `move` closures, and returning a closure

"Contacts at company X" is a predicate you'll want in several places. Make a function that
**returns** it.

> 🟢 **FOLLOW ALONG**: create `src/contacts/filter.rs` (it'll grow in Step 9):

```rust
//! What `contact list` can filter and sort by.

use super::model::Contact;
use crate::companies::CompanyId;

/// A predicate for "works at this company".
pub fn works_at(company_id: CompanyId) -> impl Fn(&Contact) -> bool {
    |contact| contact.company_id == Some(company_id)
}
```

Declare it in `src/contacts/mod.rs` with `mod filter;` and
`pub use filter::works_at;`. Then `cargo check`:

```text
error[E0373]: closure may outlive the current function, but it borrows `company_id`, which is owned by the current function
  --> src/contacts/filter.rs:43:5
   |
43 |     |contact| contact.company_id == Some(company_id)
   |     ^^^^^^^^^                            ---------- `company_id` is borrowed here
   |     |
   |     may outlive borrowed value `company_id`
   |
note: closure is returned here
  --> src/contacts/filter.rs:43:5
   |
43 |     |contact| contact.company_id == Some(company_id)
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
help: to force the closure to take ownership of `company_id` (and any other referenced variables), use the `move` keyword
   |
43 |     move |contact| contact.company_id == Some(company_id)
   |     ++++
```

**How long must it live?** The body only reads `company_id`, so the closure captured it **by
reference**, a `&CompanyId` pointing into `works_at`'s stack frame. The closure is returned; the
frame is destroyed. The struct from Step 6 would hold a dangling reference. This is Lab 10's E0597
in closure form.

`move` changes **how** captures are taken: by value, regardless of what the body does. Add it:

```rust
/// A predicate for "works at this company". The closure *owns* its copy of
/// `company_id` (`move`), so it can outlive this function call.
pub fn works_at(company_id: CompanyId) -> impl Fn(&Contact) -> bool {
    move |contact| contact.company_id == Some(company_id)
}
```

Note what `move` does **not** change: the closure is still `Fn`, because the body still only
*reads* its (now owned) `company_id`. `move` decides *how captures get into* the closure;
`Fn`/`FnMut`/`FnOnce` is decided by *what the body does with them*. They're independent. And
because `CompanyId` is `Copy`, "moving" it into the closure copies it; the caller can keep using
its own `company_id`.

Now `contacts_of` reads like a sentence:

```rust
use crate::contacts::{..., works_at};   // in crm.rs

    pub fn contacts_of(&self, company_id: CompanyId) -> Vec<&Contact> {
        self.contacts.find_where(works_at(company_id))
    }
```

You'll meet `move` again in Lab 25: a thread's closure must own everything it uses, for exactly
the reason you just saw.

---

## Step 9 — `ContactFilter`, `ContactSort` and `list_contacts`

> 🟢 **FOLLOW ALONG**: add to `src/contacts/filter.rs`:

```rust
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub enum ContactSort {
    #[default]
    Id,
    Name,
    Email,
}

/// Criteria for listing contacts. `ContactFilter::default()` matches everyone.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ContactFilter {
    pub company: Option<CompanyId>,
    pub search: Option<String>,
    pub sort: ContactSort,
}

impl ContactFilter {
    pub fn matches(&self, contact: &Contact) -> bool {
        let company_ok = match self.company {
            Some(id) => contact.company_id == Some(id),
            None => true,
        };
        let search_ok = match &self.search {
            Some(term) => {
                let term = term.to_lowercase();
                contact.name.to_lowercase().contains(&term)
                    || contact.email.as_str().contains(&term)
            }
            None => true,
        };
        company_ok && search_ok
    }
}
```

and export them: `pub use filter::{ContactFilter, ContactSort, works_at};`.

- **`#[derive(Default)]` on an enum** needs one variant marked `#[default]`. On the struct,
  `Default` fills every field with its default: `None`, `None`, `ContactSort::Id`. "No criteria"
  is the default filter, which matches everyone.
- `PartialEq` and `Debug` are there because the parser's `Command` enum derives them and will
  contain a filter (and so tests can `assert_eq!` parsed commands).
- `None => true` for each criterion: an absent criterion doesn't exclude anyone. The criteria
  combine with AND.

Now the query, in `impl Crm`:

```rust
use crate::contacts::{Contact, ContactFilter, ContactId, ContactSort, Email, works_at};

    /// Contacts matching `filter`, sorted as the filter asks.
    pub fn list_contacts(&self, filter: &ContactFilter) -> Vec<&Contact> {
        let mut contacts = self.contacts.find_where(|c| filter.matches(c));
        match filter.sort {
            ContactSort::Id => contacts.sort_by_key(|c| c.id),
            ContactSort::Name => contacts.sort_by_cached_key(|c| c.name.to_lowercase()),
            ContactSort::Email => contacts.sort_by(|a, b| a.email.as_str().cmp(b.email.as_str())),
        }
        contacts
    }
```

Three sorting methods, three reasons:

- **`sort_by_key(|c| c.id)`**: sort by a key the closure extracts. Needs the key to be `Ord`, which
  is why Lab 15 derived `PartialOrd, Ord` on the ids. The key is `Copy`, so extracting it is free.
- **`sort_by_cached_key(|c| c.name.to_lowercase())`**: the key is a newly allocated `String`.
  `sort_by_key` would call the closure on *every comparison* (≈ n log n allocations);
  `sort_by_cached_key` computes each key once (n allocations) and sorts by the cached keys. Use it
  whenever computing the key is expensive.
- **`sort_by(|a, b| ...)`**: you write the comparison yourself, returning an `Ordering`. The most
  flexible form; useful for multi-key sorts (`a.x.cmp(&b.x).then(a.y.cmp(&b.y))`, Your Turn 3).

All three are **stable**: contacts with equal keys keep their previous (id) order.

Notice what's being sorted: a `Vec<&Contact>`, a vector of **references**. Sorting shuffles 8-byte
pointers; the contacts themselves never move. And the repo's own order is untouched; the next
`contact list` starts from insertion order again.

Add tests to `src/crm.rs`:

```rust
    fn names(contacts: &[&Contact]) -> Vec<String> {
        contacts.iter().map(|c| c.name.clone()).collect()
    }

    #[test]
    fn list_contacts_filters_by_company_and_search() {
        let crm = sample_crm();
        let at_acme = ContactFilter {
            company: Some(CompanyId(1)),
            ..Default::default()
        };
        assert_eq!(names(&crm.list_contacts(&at_acme)), ["Ada Lovelace", "Alan Turing"]);

        let acme_alan = ContactFilter {
            search: Some("ALAN".into()),
            ..at_acme
        };
        assert_eq!(names(&crm.list_contacts(&acme_alan)), ["Alan Turing"]);
    }

    #[test]
    fn list_contacts_sorts() {
        let crm = sample_crm();
        let by = |sort| ContactFilter {
            sort,
            ..Default::default()
        };
        assert_eq!(
            names(&crm.list_contacts(&by(ContactSort::Id))),
            ["Ada Lovelace", "Grace Hopper", "Alan Turing"]
        );
        assert_eq!(
            names(&crm.list_contacts(&by(ContactSort::Name))),
            ["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
        assert_eq!(
            names(&crm.list_contacts(&by(ContactSort::Email))),
            ["Ada Lovelace", "Alan Turing", "Grace Hopper"]
        );
    }
```

`..Default::default()` and `..at_acme` are **struct update syntax**: "the remaining fields come
from this other value". `..at_acme` *moves* the remaining fields out of `at_acme` (its `search`
`Option<String>` would move, if we hadn't overridden it; here only `company` and `sort` are taken,
both `Copy`).

---

## Step 10 — `iter()`, `iter_mut()`, `into_iter()`: three ownership modes

Remember the `for` desugaring from Step 1: `for x in collection` calls
`IntoIterator::into_iter(collection)`. What you get depends on **what you hand to the loop**:

| You write | Calls | Yields | Afterwards, the collection is... |
|---|---|---|---|
| `for c in &contacts` / `contacts.iter()` | `into_iter(&Vec<T>)` | `&T` | untouched, still yours |
| `for c in &mut contacts` / `contacts.iter_mut()` | `into_iter(&mut Vec<T>)` | `&mut T` | still yours, maybe modified |
| `for c in contacts` / `contacts.into_iter()` | `into_iter(Vec<T>)` | `T` (owned) | **gone**: moved into the loop |

It's Lab 06–07 in one table: shared borrow, exclusive borrow, ownership transfer.

> 🟢 **FOLLOW ALONG**: add this test to `src/crm.rs`:

```rust
    #[test]
    fn three_ways_to_iterate() {
        let crm = sample_crm();
        // An owned copy, so we can try all three without touching the CRM.
        let mut contacts: Vec<Contact> = crm.contacts.iter().cloned().collect();

        // 1. iter(): shared borrows (&Contact). `contacts` is untouched.
        let total_name_len: usize = contacts.iter().map(|c| c.name.len()).sum();
        assert_eq!(total_name_len, 35);

        // 2. iter_mut(): exclusive borrows (&mut Contact). We can change items in place.
        for contact in contacts.iter_mut() {
            contact.name = contact.name.to_uppercase();
        }
        assert_eq!(contacts[0].name, "ADA LOVELACE");

        // 3. into_iter(): ownership. Each Contact is moved out, so we can move
        //    its `name` out too: no clone needed.
        let names: Vec<String> = contacts.into_iter().map(|c| c.name).collect();
        assert_eq!(names, ["ADA LOVELACE", "GRACE HOPPER", "ALAN TURING"]);
    }
```

The interesting line is the last one. With `iter()`, `c` would be a `&Contact`, and
`.map(|c| c.name)` would try to move a `String` out from behind a reference (E0507). With
`into_iter()`, each `c` is an owned `Contact`, so taking its `name` and dropping the rest is fine.
**`into_iter` is how you get owned values out of a collection without cloning**, when you no longer
need the collection.

> 🟡 **EXPERIMENT**: add `assert_eq!(contacts.len(), 3);` at the end of the test.

```text
error[E0382]: borrow of moved value: `contacts`
   --> src/crm.rs:180:20
    |
164 |         let mut contacts: Vec<Contact> = crm.contacts.iter().cloned().collect();
    |             ------------ move occurs because `contacts` has type `Vec<contacts::model::Contact>`, which does not implement the `Copy` trait
...
178 |         let names: Vec<String> = contacts.into_iter().map(|c| c.name).collect();
    |                                           ----------- `contacts` moved due to this method call
179 |         assert_eq!(names, ["ADA LOVELACE", "GRACE HOPPER", "ALAN TURING"]);
180 |         assert_eq!(contacts.len(), 3);
    |                    ^^^^^^^^ value borrowed here after move
    |
note: `std::iter::IntoIterator::into_iter` takes ownership of the receiver `self`, which moves `contacts`
```

**Was it moved? Where?** Yes: `into_iter(self)` takes the vector by value. The note even names the
method. Remove the line.

One subtlety you'll meet constantly: `list_contacts` returns a `Vec<&Contact>`. Calling
`into_iter()` on *that* gives you owned... `&Contact`s. You own the vector of references, not the
contacts. Ownership is always about the thing you actually have.

---

## Step 11 — Parsing flags with an iterator

The parser needs to turn `["--company", "1", "--sort", "name"]` into a `ContactFilter`. A flag is
always followed by its value, so walk the arguments with an iterator, pulling **two** items per
step. This is `next()` used directly, the same call a `for` loop makes for you.

> 🟢 **FOLLOW ALONG**: in `src/cli/parser.rs`:

```rust
use crate::contacts::{ContactFilter, ContactId, ContactSort};

/// Splits `--flag value --flag value` into `(flag, value)` pairs.
/// Every flag needs a value; anything else is a usage error.
fn flag_pairs<'a>(
    args: &[&'a str],
    usage: &'static str,
) -> Result<Vec<(&'a str, &'a str)>, CrmError> {
    let mut pairs = Vec::new();
    let mut words = args.iter().copied();
    while let Some(flag) = words.next() {
        if !flag.starts_with("--") {
            return Err(CrmError::Usage(usage));
        }
        let value = words.next().ok_or(CrmError::Usage(usage))?;
        pairs.push((flag, value));
    }
    Ok(pairs)
}

const CONTACT_LIST_USAGE: &str =
    "contact list [--company <id>] [--search <term>] [--sort id|name|email] [--page <n>]";

fn parse_contact_list(args: &[&str]) -> Result<(ContactFilter, usize), CrmError> {
    let usage = CONTACT_LIST_USAGE;
    let mut filter = ContactFilter::default();
    let mut page = 1;
    for (flag, value) in flag_pairs(args, usage)? {
        match flag {
            "--company" => filter.company = Some(parse_id(value)?),
            "--search" => filter.search = Some(value.to_string()),
            "--sort" => {
                filter.sort = match value {
                    "id" => ContactSort::Id,
                    "name" => ContactSort::Name,
                    "email" => ContactSort::Email,
                    _ => return Err(CrmError::Usage(usage)),
                }
            }
            "--page" => {
                page = value
                    .parse::<usize>()
                    .ok()
                    .filter(|&p| p > 0)
                    .ok_or(CrmError::Usage(usage))?
            }
            _ => return Err(CrmError::Usage(usage)),
        }
    }
    Ok((filter, page))
}
```

Points to notice:

- **`while let Some(flag) = words.next()`** is the `for` desugaring written by hand, which lets the
  body call `words.next()` a *second* time to take the value. A `for` loop owns its iterator, so
  you couldn't do that inside one.
- **`args.iter().copied()`**: `iter()` over `&[&str]` yields `&&str`; `copied()` turns each into a
  `&str` (references are `Copy`).
- **Lifetimes**: `flag_pairs<'a>` returns pairs borrowed from the *input line* (`'a`), not from
  `args` the slice. Lab 10's reasoning, applied.
- **Flags in any order, repeated flags**: the last one wins. A flag without a value, a bare word,
  an unknown flag, an unknown sort, or page `0` are all usage errors.
- `parse_id(value)?` reuses your Lab 15 generic `parse_id`; the target type `CompanyId` is
  inferred from `filter.company`. (A bad id reports `parse_id`'s own usage message.)
- The page number goes through `Option`'s **combinators**: `ok()` (Result → Option), `filter`
  (keep only `p > 0`), `ok_or` (back to a Result with our error). Option and Result have their own
  `map`/`filter`/`and_then`: same vocabulary as iterators, for "zero or one" values.

(An alternative is `for pair in args.chunks(2) { match pair { [flag, value] => ..., _ => usage } }`,
using slice patterns. Both are fine; the `next()` version gives a better shape for flags without
values, like a future `--all`.)

Now wire it in. Change the variant:

```rust
pub(crate) enum ContactCommand<'a> {
    Add,
    List { filter: ContactFilter, page: usize },
    // ...
}
```

and in `parse_contact`, replace the two Lab 14 `list` arms (`("list", [])` and
`("list", [page])`) with one:

```rust
        ("list", flags) => {
            let (filter, page) = parse_contact_list(flags)?;
            ContactCommand::List { filter, page }
        }
```

`flags` binds the whole rest of the slice: the `(sub, args)` match already split off `contact`
and `list`, so `flags` is everything after them (Lab 11 slice patterns), possibly empty. The old
positional `contact list 2` becomes a usage error; it's `contact list --page 2` now. Update your
parser tests: the `contact list` assertion in Lab 14's `parse_contact_commands` test
(`List { page: 1 }`) no longer compiles, so delete it, and add these (they need `ContactFilter`
and `ContactSort`, which `use super::*;` brings in from the parser's own imports):

```rust
    #[test]
    fn contact_list_defaults_to_everything_page_one() {
        let command = parse_command("contact list").unwrap().unwrap();
        assert_eq!(
            command,
            Command::Contact(ContactCommand::List {
                filter: ContactFilter::default(),
                page: 1
            })
        );
    }

    #[test]
    fn contact_list_flags_in_any_order() {
        let command = parse_command("contact list --sort name --page 2 --company 3 --search ada")
            .unwrap()
            .unwrap();
        let expected = ContactFilter {
            company: Some(CompanyId(3)),
            search: Some("ada".to_string()),
            sort: ContactSort::Name,
        };
        assert_eq!(
            command,
            Command::Contact(ContactCommand::List { filter: expected, page: 2 })
        );
    }

    #[test]
    fn contact_list_rejects_bad_flags() {
        for bad in [
            "contact list 2",
            "contact list --page",
            "contact list --page 0",
            "contact list --sort phone",
            "contact list --colour red",
        ] {
            assert!(
                matches!(parse_command(bad), Err(CrmError::Usage(_))),
                "{bad} should be a usage error"
            );
        }
    }
```

### Paging after filtering

In `src/cli/commands.rs`:

```rust
        ContactCommand::List { filter, page } => {
            let contacts = crm.list_contacts(&filter);
            let pages = contacts.len().div_ceil(PAGE_SIZE).max(1);
            match contacts.chunks(PAGE_SIZE).nth(page - 1) {
                Some(rows) => {
                    print_table(CONTACT_HEADER, rows);
                    println!("Page {page} of {pages} ({} matching)", contacts.len());
                }
                None if contacts.is_empty() => println!("No contacts match."),
                None => println!("No page {page}: there are only {pages}."),
            }
        }
```

- `chunks(PAGE_SIZE)` is an iterator over sub-slices of up to 5 elements; `nth(page - 1)` skips to
  the one you want (`page` is at least 1; the parser guarantees it). Each chunk is a
  `&[&Contact]`, which `print_table` already accepts.
- `div_ceil` rounds up: 6 contacts / 5 per page = 2 pages.
- `None if contacts.is_empty()` is a **match guard** (Lab 11).

Now `InMemoryRepo::page` is unused. Look at why: paging has to happen **after** filtering and
sorting ("page 2 of Acme's contacts sorted by name"), and the repo can't know about either. Paging
the raw storage was only ever right for "list everything in insertion order". Delete `page` from
`src/repo.rs`, and replace its test from Lab 16 with:

```rust
    #[test]
    fn empty_repo() {
        let repo = InMemoryRepo::<Note>::new();
        assert!(repo.is_empty());
        assert_eq!(repo.iter().count(), 0);
    }
```

Finally, update the `contact list` line of `print_help` to show the new flags, and change
`list [page]` to `list [flags]` in the `CONTACT_USAGE` constant in `parser.rs`.

---

## ▶️ Run It

```bash
cargo fmt && cargo clippy && cargo test
cargo run
```

Create this data (any order of commands, but the ids must come out as shown):

| Companies | Contacts |
|---|---|
| `#1 Acme Corp` (acme.io), `#2 Globex` (globex.com) → `company stage 2 customer`, `#3 Initech` (initech.com) → `company stage 3 churned` | `#1 Ada Lovelace` ada@acme.io 555-0100 company 1 · `#2 Alan Turing` alan@acme.io company 1 · `#3 Grace Hopper` grace@navy.mil · `#4 Bob Smith` bob@globex.com company 2 · `#5 Zoe Adams` zoe@globex.com company 2 · `#6 Carl Sagan` carl@cosmos.org |

Then run the queries below.

## ✅ Expected Result

```text
crm> contact list
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
#2   Alan Turing          alan@acme.io             -              #1
#3   Grace Hopper         grace@navy.mil           -              -
#4   Bob Smith            bob@globex.com           -              #2
#5   Zoe Adams            zoe@globex.com           -              #2
Page 1 of 2 (6 matching)
crm> contact list --sort name --page 2
ID   NAME                 EMAIL                    PHONE          COMPANY
#5   Zoe Adams            zoe@globex.com           -              #2
Page 2 of 2 (6 matching)
crm> contact list --company 1 --sort name
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
#2   Alan Turing          alan@acme.io             -              #1
Page 1 of 1 (2 matching)
crm> contact list --search ada
ID   NAME                 EMAIL                    PHONE          COMPANY
#1   Ada Lovelace         ada@acme.io              555-0100       #1
#5   Zoe Adams            zoe@globex.com           -              #2
Page 1 of 1 (2 matching)
crm> contact list --page 3
No page 3: there are only 2.
crm> contact list --sort phone
Error: usage: contact list [--company <id>] [--search <term>] [--sort id|name|email] [--page <n>]
crm> contact list 2
Error: usage: contact list [--company <id>] [--search <term>] [--sort id|name|email] [--page <n>]
crm> quit
Goodbye! (18 commands this session)
```

(Zoe Ad**a**ms matches `ada`: the search is a substring match on name or email. The count is 18:
the 11 commands that created the data plus the 7 queries; your Lab 14 loop counts rejected
commands too. The `usage:` prefix comes from your Lab 12 `CrmError::Usage` message.)

## 🧠 Understand It

**Iterators are values, not loops.** An adapter chain like `.iter().filter(..).map(..)` builds a
nest of small structs (`Map<Filter<slice::Iter<..>, F1>, F2>`), each holding the one inside it and
its closure. Nothing happens until a consumer calls `next` on the outermost one, which pulls a
single item through the whole chain. That's laziness, and it's why pipelines allocate nothing
except at `collect`.

**Everything is monomorphized.** Each closure is its own type, each adapter is generic over it, and
the compiler generates and inlines one specialised version of the whole chain. In optimised builds
an iterator pipeline typically compiles to the same loop you'd write by hand ("zero-cost
abstraction").

**`impl Trait` hides, generics expose.** `-> impl Iterator<Item = &T>` let you swap `RepoIter` for
`slice::Iter` without touching callers. In argument position, `impl Trait` lets the caller pick; in
return position, the function picks.

**Closures = struct + `Fn*` impl.** Captured variables become fields (by `&`, `&mut`, or value,
whichever is least powerful for the body, unless `move` forces "by value"). What the body does with
them decides the trait: read → `Fn`, mutate → `FnMut`, consume → `FnOnce`. Functions that accept
closures choose the bound; `Fn` is the strictest for callers, `FnOnce` the loosest.

**Three ways to iterate are three ownership modes**: `iter` borrows, `iter_mut` borrows exclusively,
`into_iter` takes ownership. `for x in v` is `into_iter`, which is why it moves `v`.

**Business logic stayed in `Crm`.** The CLI parses flags into a `ContactFilter`, calls
`list_contacts`, and prints. In Lab 29 an HTTP handler will deserialize query parameters into the
same kind of filter and call the same kind of method.

## 🧪 Experiment

> 🟡 **EXPERIMENT 1: a borrowed sort key.** In `list_contacts`, change the `Name` arm to
> `contacts.sort_by_key(|c| &c.name)`. It compiles. Now, in `three_ways_to_iterate`, try
> `contacts.sort_by_key(|c| &c.name);` on the `Vec<Contact>`:

```text
error: lifetime may not live long enough
   --> src/crm.rs:219:34
    |
219 |         contacts.sort_by_key(|c| &c.name);
    |                               -- ^^^^^^^ returning this value requires that `'1` must outlive `'2`
    |                               ||
    |                               |return type of closure is &'2 String
    |                               has type `&'1 contacts::model::Contact`
```

> Why does one compile and the other not? (Think about *what the key borrows from* in each case:
> a `Contact` that lives outside the vector being sorted, or a slot inside it, which the sort is
> about to move.) And why is the first version still not what we want for `--sort name`? (Try two
> contacts named `alice` and `Bob`.) Revert both.

> 🟡 **EXPERIMENT 2: fewer allocations in `matches`.** `ContactFilter::matches` lowercases the
> search term **once per contact**. Run `cargo test` with a `println!` in `matches`, then think: how
> could `list_contacts` lowercase the term once? (Hint: you saw the pattern at the end of Step 7.)
> Is it worth changing the public `ContactFilter` for it? There's no single right answer; write
> down your reasoning.

> 🟡 **EXPERIMENT 3: a function pointer where a closure is expected.** Write
> `fn has_phone(c: &Contact) -> bool { c.phone.is_some() }` (a plain function) in `crm.rs` tests,
> and call `crm.contacts.find_where(has_phone)`. Does it compile? Which trait does a plain `fn` item
> implement, and why can it never be `FnMut`-only or `FnOnce`-only?

## 👩🏽‍💻 Your Turn

> 🔵 **YOUR TURN 1: `CompanyFilter` and `Crm::list_companies`**
>
> Create `src/companies/filter.rs` with:
>
> ```rust
> #[derive(Debug, Clone, Default, PartialEq)]
> pub struct CompanyFilter {
>     pub lifecycle: Option<Lifecycle>,
>     pub search: Option<String>,
> }
>
> impl CompanyFilter {
>     pub fn matches(&self, company: &Company) -> bool { /* you */ }
> }
> ```
>
> and export it from `crate::companies`. Rules: `lifecycle`, when set, must equal the company's
> lifecycle. `search`, when set, must appear case-insensitively in the company's **name or
> website** (a company without a website can still match by name). Both criteria must hold.
>
> Then add `pub fn list_companies(&self, filter: &CompanyFilter) -> Vec<&Company>` to `impl Crm`:
> matching companies in insertion (id) order.

- [ ] `CompanyFilter::default()` matches every company
- [ ] tests: lifecycle match/mismatch; search hits on name (`ACME`), on website (`.io`), and
      misses (`globex`); both criteria set and only one holds → no match
- [ ] `list_companies` uses `find_where`
- [ ] `cargo test` passes

> 🔵 **YOUR TURN 2: `company list` flags**
>
> Support `company list [--stage <prospect|customer|churned>] [--search <term>]`:
> `CompanyCommand::List` becomes `List { filter: CompanyFilter }`, parsed with `flag_pairs`
> (the `("list", [])` arm of `parse_company` becomes `("list", flags)`).
> `--stage` must use your `FromStr for Lifecycle` (Lab 15), so a bad stage reports the lifecycle
> error, not a usage error. Empty results print `No companies match.` Update `help`.

- [ ] `company list --stage customer` prints only customers, as a table
- [ ] `company list --search INI` finds `Initech`
- [ ] `company list --stage won` prints
      `Error: invalid lifecycle 'won' (expected prospect, customer or churned)`
- [ ] `company list --stage` (no value) prints the usage error:
      `company list [--stage <prospect|customer|churned>] [--search <term>]`
- [ ] parser tests for a full command, the bad stage (assert it's
      `CrmError::Validation(ValidationError::InvalidLifecycle(_))`) and the missing value

> 🔵 **YOUR TURN 3: the `stats` command**
>
> Add a `stats` command. The numbers are computed in the library, the CLI only prints them. Create
> `src/stats.rs` (`pub mod stats;` in `lib.rs`) with:
>
> ```rust
> #[derive(Debug, PartialEq)]
> pub struct CrmStats {
>     /// Every lifecycle stage in Prospect, Customer, Churned order, including zero counts.
>     pub companies_by_lifecycle: Vec<(Lifecycle, usize)>,
>     pub contacts_with_company: usize,
>     pub contacts_without_company: usize,
>     /// Most common email domains first; ties sorted alphabetically; at most `top_n`.
>     pub top_domains: Vec<(String, usize)>,
> }
>
> impl Crm {
>     pub fn stats(&self, top_n: usize) -> CrmStats { /* you */ }
> }
> ```
>
> Use iterators for every number (no index loops). The CLI calls `crm.stats(3)` and prints exactly:
>
> ```text
> Companies: 3
>   prospect   1
>   customer   1
>   churned    1
> Contacts: 6 (4 with a company, 2 without)
> Top email domains:
>   acme.io        2
>   globex.com     2
>   cosmos.org     1
> ```
>
> (Stage names padded to 10 characters, domains to 14. Omit the "Top email domains:" block when
> there are no contacts.)

- [ ] an empty CRM reports all three stages with `0`, zero contacts, no domains
- [ ] a test with 2 companies (one moved to customer) and 5 contacts (two `acme.io`, two
      `globex.com`, one other; 3 with a company) checks every field, including that `acme.io`
      comes before `globex.com` on a tie
- [ ] `stats` appears in `help`
- [ ] `cargo clippy` clean, `cargo test` passes

## 💡 Hint

> 💡 **HINT (Your Turn 1)**: `ContactFilter::matches` is your template. Option has helpers that
> express "absent, or satisfies this": look at `Option::is_none_or` and `Option::is_some_and`.

<details><summary>Hint 2 (more specific)</summary>

`self.lifecycle.is_none_or(|l| company.lifecycle == l)` is the first criterion in one line.
For the website: `company.website.as_deref().is_some_and(|w| w.to_lowercase().contains(&term))`.

</details>

> 💡 **HINT (Your Turn 2)**: `parse_contact_list` is your template, and it's shorter: two flags,
> no page. For `--stage`, `value.parse()?` with a `Lifecycle` target does everything.

<details><summary>Hint 2 (more specific)</summary>

`"--stage" => filter.lifecycle = Some(value.parse()?),`. The `?` converts `ValidationError` to
`CrmError` (Lab 15 Step 7), and the type of `filter.lifecycle` tells `parse` what to produce.

</details>

> 💡 **HINT (Your Turn 3)**: one sub-problem per field. Companies per stage: you need the list of
> all stages; add `pub const ALL: [Lifecycle; 3]` to `impl Lifecycle`. With/without company: one
> pass with `partition`, or two `count`s. Domains: count into a `HashMap<&str, usize>`, then turn
> the map into a sorted `Vec`.

<details><summary>Hint 2 (more specific)</summary>

- `Lifecycle::ALL.iter().map(|&stage| (stage, self.companies.iter().filter(|c| c.lifecycle == stage).count())).collect()`
- `email.as_str().split_once('@')` gives `Some((local, domain))`.
- Counting: `*counts.entry(domain).or_insert(0) += 1;` (the entry API gets its full explanation in
  Lab 18).
- `counts.into_iter()` yields owned `(&str, usize)` pairs; `map` them to `(String, usize)`,
  `collect` into a `Vec`, then `sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)))` and
  `truncate(top_n)`.

</details>

## 🆘 Solution

> 🔴 **SOLUTION** (optional): see [`solutions.md`](solutions.md). Make a genuine attempt first.

## ✅ Checkpoint

Answer without looking at the code:

1. What is the one required method of `Iterator`, and why does it take `&mut self`?
2. Write out what `for c in &contacts { ... }` desugars to. Which `IntoIterator` impl does it use,
   and what type is `c`?
3. Why did `crm.contacts.iter().map(|c| ...)` with a `println!` inside print nothing? In
   `filter(..).map(..).collect()`, in what order are items visited?
4. What's the difference between `fn f(x: impl Display)` and `fn f() -> impl Iterator<Item = &T>`?
   Why does edition 2021 code often write `+ '_` on the latter?
5. Draw the struct the compiler generates for `|c: &Contact| c.company_id == Some(company_id)`.
   What changes with `move`?
6. Classify each: a closure that reads a captured `CompanyId`; one that increments a captured
   counter; one that moves a captured `String` into a struct it returns. Which can be passed to
   `find_where`, and which to `Iterator::filter`?
7. Why did `works_at` need `move`, and why does `move` not make the closure `FnOnce`?
8. When would you choose `into_iter()` over `iter()`? What happens to the collection?
9. Why did `InMemoryRepo::page` have to go?

Then verify: `cargo fmt --check && cargo clippy && cargo test`

## Git Commit

Commit the instructor part first, then your Your Turns:

```bash
git add .
git commit -m "Add contact filtering and sorting with iterators"
# ... after Your Turns 1–3:
git add .
git commit -m "Add filtering and sorting with iterators"
git tag lab-17
git push && git push --tags
```

`git log --oneline lab-16..lab-17` shows the two steps of this lab.

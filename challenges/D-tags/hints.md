# Challenge D — Hints

Open one tier at a time, and only after you've been stuck on something for a while. Tier 1 gives
a direction, Tier 2 a design, Tier 3 is close to a solution.

---

## 1. Representing a tag

<details><summary>Tier 1: direction</summary>

You've built this kind of type before. What did `Email` do so that an invalid email address can't
exist anywhere in the program, not even after loading the JSON file?

</details>

<details><summary>Tier 2: design</summary>

A newtype `Tag(String)` with a **private** field, a `Tag::parse(&str) -> Result<Tag, ValidationError>`
that does all of the normalisation, and `as_str()`. Add a `ValidationError::InvalidTag(String)`
variant. For serde, the same pair of attributes `Email` uses (`try_from = "String"`,
`into = "String"`) makes loading go through `parse`. Derive `Ord` too. You'll want tags sorted.

</details>

<details><summary>Tier 3: near-solution</summary>

Normalise in one pass over `raw.trim().to_lowercase().chars()`: map whitespace and `_` to `-`,
reject anything that isn't `[a-z0-9-]`, and skip a `-` when the output is empty or already ends
with `-`. Afterwards pop trailing `-`s, then check `1..=32` length. `is_ascii_lowercase()` and
`is_ascii_digit()` are the right predicates. `is_alphanumeric()` would accept `ï`.

</details>

---

## 2. Where do the tags live?

<details><summary>Tier 1: direction</summary>

Two classic shapes for many-to-many: each entity holds its set of tags, or a separate collection
of (tag, entity) pairs. Think about what each makes easy: filtering a list, counting, deleting an
entity, and what the JSON file looks like.

</details>

<details><summary>Tier 2: design</summary>

For the in-memory, snapshot-persisted `Crm`, a field on each entity is the simplest:
`pub tags: BTreeSet<Tag>` on `Company` and `Contact`. A *set* makes duplicates impossible (that's
your idempotency). A *B-tree* set iterates in sorted order (that's your sorted `{"tags": [...]}`).
Deleting an entity deletes its tags automatically, so counts can't go stale.

The compiler will then complain about every `Company { ... }` / `Contact { ... }` literal. That's
your to-do list (the `new` constructors, lead conversion, maybe tests). Later, the new `tag`
field on `CompanyFilter`/`ContactFilter` does the same to the full filter literals in unit tests
(`src/cli/parser.rs`, `src/companies/filter.rs`): `tag: None` there.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
#[serde(default)]
pub tags: BTreeSet<Tag>,
```

Without `#[serde(default)]`, loading a Lab 29 data file fails with `missing field tags`. With it,
serde uses `BTreeSet::default()` (empty) when the key is absent. In struct literals, write
`tags: Default::default()` (or `BTreeSet::new()`).

</details>

---

## 3. One implementation for companies *and* contacts

<details><summary>Tier 1: direction</summary>

Tagging a company and tagging a contact are the same operation on different repositories. Lab 16
solved "same operation, different entity" once already.

</details>

<details><summary>Tier 2: design</summary>

A small trait, e.g. `Taggable: Entity` with `fn tags_mut(&mut self) -> &mut BTreeSet<Tag>` (and
a `const ENTITY: &'static str` for error messages), implemented by `Company` and `Contact`. Then a
generic helper over `InMemoryRepo<T>` finds the entity and returns its tag set, or `NotFound`.
Building `CrmError::NotFound { entity, id: u64 }` from a generic `T::Id` needs a way to get a
`u64` out of it, so add an `Into<u64>` bound (and implement `From<CompanyId> for u64` etc.).

Two near-identical `Crm` methods per entity type (`tag_company`, `tag_contact`, …) are also
completely acceptable. Choose the trait if you find it clearer, not because it's "more advanced".

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
fn tags_of<T>(repo: &mut InMemoryRepo<T>, id: T::Id) -> Result<&mut BTreeSet<Tag>, CrmError>
where
    T: Taggable,
    T::Id: From<u64> + Into<u64>,
{
    repo.get_mut(id)
        .map(Taggable::tags_mut)
        .ok_or(CrmError::NotFound { entity: T::ENTITY, id: id.into() })
}
```

(`T::Id: From<u64>` is there because `InMemoryRepo`'s `impl` block requires it, see Lab 16.)
`BTreeSet::insert` returns `true` if the value was new, and `remove` returns `true` if it was
there. Return those `bool`s from your `Crm` methods: the handler needs them for 201 vs 200.

</details>

---

## 4. `GET /tags` counts

<details><summary>Tier 1: direction</summary>

You need, per tag, two counters, and the output sorted by tag. Which map type keeps keys sorted?
Which API lets you "insert if missing, then increment"?

</details>

<details><summary>Tier 2: design</summary>

`BTreeMap<&Tag, (usize, usize)>`: keys are *borrowed* from the entities (no cloning while
counting), and the value is `(companies, contacts)`. Walk every company's tags, then every
contact's, with `entry(tag).or_default()`. Convert to an owned output type at the end, when you
clone each tag once.

</details>

<details><summary>Tier 3: near-solution</summary>

```rust
let mut counts: BTreeMap<&Tag, (usize, usize)> = BTreeMap::new();
for tag in self.companies.iter().flat_map(|c| c.tags.iter()) {
    counts.entry(tag).or_default().0 += 1;
}
// same for contacts with .1
```

</details>

---

## 5. HTTP details

<details><summary>Tier 1: direction</summary>

The route has two path parameters. `AppPath<T>` (Lab 28) is generic over `T`. What `T` holds two
values?

</details>

<details><summary>Tier 2: design</summary>

`AppPath((id, raw)): AppPath<(u64, String)>`. The tag segment arrives already percent-decoded
(`Key%20Account` → `"Key Account"`). Parse it with `Tag::parse` and map the error to
`ApiError::Validation(vec![FieldError::new("tag", ...)])`. Write that as one small helper
(`parse_tag`), because the list filters need it too.

For the list filters, add `tag: Option<String>` to `CompanyQuery`/`ContactQuery`, and
`tag: Option<Tag>` to the domain filters. Converting the query into the filter can now fail, so
`From` becomes `TryFrom` with `type Error = ApiError`, and the list handlers start returning
`Result<..., ApiError>`.

</details>

<details><summary>Tier 3: near-solution</summary>

Inside the `TryFrom`: `tag: q.tag.as_deref().map(parse_tag).transpose()?`. That's
`Option<String>` → `Option<&str>` → `Option<Result<Tag, ApiError>>` → `Result<Option<Tag>, ApiError>`
→ `?`. Same `transpose` trick as `convert_lead` in Lab 29.

For the tag-add response, build the sorted `Vec<String>` *inside* the lock block, together with the
`added` flag, then drop the guard, then `persist` (only if `added`), then choose `201` or `200`.

</details>

---

## 6. Proving old files still load

<details><summary>Tier 1: direction</summary>

You don't need a real Lab 29 file in your repo. You need a JSON document *without* `tags` keys.

</details>

<details><summary>Tier 2: design</summary>

In a test, build a `Crm`, serialize it with `serde_json::to_value`, remove the `tags` key from an
entity object (`as_object_mut().unwrap().remove("tags")`), write it to a file in a `tempfile`
directory (Lab 24), and load it with `JsonFileStorage`. Assert the entity's tags are empty.

</details>

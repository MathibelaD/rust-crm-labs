# Challenge D — Reference Design

> Read this **after** finishing. It's one reasonable design with the reasoning behind each
> decision, not the only right answer and not a drop-in implementation. It was compiled and
> tested against the Lab 29 code base (axum 0.8, serde 1); the snippets are the key parts only.

## Overview

```text
src/tags.rs            Tag (newtype), Taggable (trait), TagCount, Crm::{tag_*, untag_*, tag_counts}
src/errors.rs          ValidationError::InvalidTag(String)
src/companies/model.rs Company { ..., #[serde(default)] pub tags: BTreeSet<Tag> }
src/contacts/model.rs  Contact { ..., #[serde(default)] pub tags: BTreeSet<Tag> }
src/companies/filter.rs, src/contacts/filter.rs   + pub tag: Option<Tag>
src/http/tags.rs       routes(), parse_tag(), tag_strings(), handlers, GET /tags
src/http/companies.rs, contacts.rs   query gains tag; responses gain tags
tests/api/tags.rs, tests/tags_persistence.rs, unit tests in src/tags.rs
```

## 1. `Tag`: make the invalid state unrepresentable

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Tag(String);

impl Tag {
    pub fn parse(raw: &str) -> Result<Tag, ValidationError> {
        let invalid = || ValidationError::InvalidTag(raw.to_string());
        let lowered = raw.trim().to_lowercase();
        let mut normalised = String::with_capacity(lowered.len());
        for c in lowered.chars() {
            let c = if c.is_whitespace() || c == '_' { '-' } else { c };
            if !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
                return Err(invalid());
            }
            if c == '-' && (normalised.is_empty() || normalised.ends_with('-')) {
                continue; // no leading dash, no "--"
            }
            normalised.push(c);
        }
        while normalised.ends_with('-') {
            normalised.pop();
        }
        if normalised.is_empty() || normalised.len() > MAX_TAG_LEN {
            return Err(invalid());
        }
        Ok(Tag(normalised))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
// + TryFrom<String> (calls parse), From<Tag> for String, Display
```

**Why:** the private field means the *only* way to get a `Tag` is `parse`, including through
serde (`try_from = "String"`). Every function that takes a `Tag` can rely on it being canonical,
and "nothing else lowercases tags" is enforced by the type system, not by discipline. Deriving
`Ord` on a single-field tuple struct orders by the string, which is what the sorted outputs need.
`len()` counts bytes, which is fine here because only ASCII survives the character check.

## 2. Storage: a `BTreeSet<Tag>` on each entity

```rust
pub struct Company {
    pub id: CompanyId,
    pub name: String,
    pub website: Option<String>,
    pub lifecycle: Lifecycle,
    #[serde(default)]
    pub tags: BTreeSet<Tag>,
}
```

**Why a set on the entity instead of a list of `(Tag, Subject)` pairs?**

| | Set on entity | Separate pair list |
|---|---|---|
| Duplicates | impossible (set) | must check on insert |
| Sorted tags per entity | free (`BTreeSet` iteration order) | must sort |
| Delete entity → tags gone | automatic | must clean up, or counts go stale |
| Filter list by tag | `c.tags.contains(tag)`, O(log n) per entity | scan pairs or build an index |
| Count per tag | walk all entities | walk all pairs |
| Maps to Postgres | **as a join table** `company_tags(company_id, tag)` either way | same |

For a snapshot-persisted in-memory store, the set wins on every row that matters. The pair list
mirrors the eventual SQL schema more literally, but the database will give you joins and
`ON DELETE CASCADE` for free. In memory you'd be reimplementing them.

**`#[serde(default)]` is the backward-compatibility switch.** Without it, every existing data
file fails to load with `missing field "tags"`, a breaking change for your own users. Adding the
field also breaks every `Company { .. }` / `Contact { .. }` struct literal at compile time
(E0063, "missing field `tags`"): in `Company::new`, `Contact::new` and in `Lead::convert`
(`src/leads/conversion.rs`). Fill them with `tags: Default::default()`. Converted leads start
untagged. Leads aren't taggable, so there's nothing to carry over. The new `tag` field on the
filters (section 5) does the same to the few full `CompanyFilter { .. }` / `ContactFilter { .. }`
literals: the CLI parser's unit tests in `src/cli/parser.rs` and a test in
`src/companies/filter.rs`. They get `tag: None`. The CLI itself builds its filters from
`::default()` and has no tag commands, but it must still compile.

## 3. One generic implementation via a trait

```rust
pub trait Taggable: Entity {
    const ENTITY: &'static str;
    fn tags(&self) -> &BTreeSet<Tag>;
    fn tags_mut(&mut self) -> &mut BTreeSet<Tag>;
}
// impl Taggable for Company { const ENTITY: &'static str = "company"; ... }
// impl Taggable for Contact { const ENTITY: &'static str = "contact"; ... }

fn tags_of<T>(repo: &mut InMemoryRepo<T>, id: T::Id) -> Result<&mut BTreeSet<Tag>, CrmError>
where
    T: Taggable,
    T::Id: From<u64> + Into<u64>,
{
    repo.get_mut(id)
        .map(Taggable::tags_mut)
        .ok_or(CrmError::NotFound { entity: T::ENTITY, id: id.into() })
}

impl Crm {
    /// Returns `true` if the tag was new for this company.
    pub fn tag_company(&mut self, id: CompanyId, tag: Tag) -> Result<bool, CrmError> {
        Ok(tags_of(&mut self.companies, id)?.insert(tag))
    }
    /// Returns `true` if the tag was present.
    pub fn untag_company(&mut self, id: CompanyId, tag: &Tag) -> Result<bool, CrmError> {
        Ok(tags_of(&mut self.companies, id)?.remove(tag))
    }
    // tag_contact / untag_contact: identical with self.contacts
}
```

Plus `impl From<CompanyId> for u64` and `impl From<ContactId> for u64`, so `id.into()` works.

**Why:**
- An **associated const** (`ENTITY`) gives each implementor its own error label without an extra
  method call. It's a value attached to the type, not to an instance.
- `tags_of` returns `&mut BTreeSet<Tag>` borrowed from the repo, so the public methods can call
  `insert`/`remove` on it directly. The returned borrow's lifetime is tied to `&mut repo` by
  elision. The `Crm` methods take the tag **by value** in `tag_*` (it gets stored) and **by
  reference** in `untag_*` (only compared). The signatures say what happens to ownership.
- Returning `bool` keeps the domain HTTP-agnostic while giving the handler what it needs for
  201/200 and for "skip the save when nothing changed".
- `.map(Taggable::tags_mut)`: a trait method path used as a function, like `CompanyResponse::from`
  in Lab 29.

## 4. Counting: borrow while counting, clone once at the end

```rust
pub fn tag_counts(&self) -> Vec<TagCount> {
    let mut counts: BTreeMap<&Tag, (usize, usize)> = BTreeMap::new();
    for tag in self.companies.iter().flat_map(|c| c.tags.iter()) {
        counts.entry(tag).or_default().0 += 1;
    }
    for tag in self.contacts.iter().flat_map(|c| c.tags.iter()) {
        counts.entry(tag).or_default().1 += 1;
    }
    counts
        .into_iter()
        .map(|(tag, (companies, contacts))| TagCount { tag: tag.clone(), companies, contacts })
        .collect()
}
```

`BTreeMap` gives the alphabetical order (constraint: "let a data structure do it"). Keys are
`&Tag` borrowed from `self`, so counting allocates nothing per occurrence. `TagCount` owns its
`Tag`, so callers aren't tied to the `Crm`'s lifetime. Tags with zero uses can't appear, because
they only exist inside entities.

## 5. HTTP layer

```rust
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/companies/{id}/tags/{tag}", post(tag_company).delete(untag_company))
        .route("/contacts/{id}/tags/{tag}", post(tag_contact).delete(untag_contact))
        .route("/tags", get(list_tags))
}

/// A tag in the URL is user input like any other: validate it at the boundary.
pub(crate) fn parse_tag(raw: &str) -> Result<Tag, ApiError> {
    Tag::parse(raw).map_err(|e| ApiError::Validation(vec![FieldError::new("tag", e.to_string())]))
}

async fn tag_company(
    State(state): State<AppState>,
    AppPath((id, raw)): AppPath<(u64, String)>,
) -> Result<(StatusCode, Json<TagsResponse>), ApiError> {
    let tag = parse_tag(&raw)?;
    let (added, tags) = {
        let mut crm = state.crm.write().expect("crm lock poisoned");
        let added = crm.tag_company(CompanyId(id), tag)?;
        let company = crm.companies.get(CompanyId(id)).expect("tagged company exists");
        (added, tag_strings(&company.tags))
    };
    if added {
        state.persist().await?;
    }
    let status = if added { StatusCode::CREATED } else { StatusCode::OK };
    Ok((status, Json(TagsResponse { tags })))
}

async fn untag_company(
    State(state): State<AppState>,
    AppPath((id, raw)): AppPath<(u64, String)>,
) -> Result<StatusCode, ApiError> {
    let tag = parse_tag(&raw)?;
    let removed = state
        .crm
        .write()
        .expect("crm lock poisoned")
        .untag_company(CompanyId(id), &tag)?;
    if removed {
        state.persist().await?;
    }
    Ok(StatusCode::NO_CONTENT)
}
```

The list filters: the query gains `pub tag: Option<String>`, and the conversion into the domain
filter becomes fallible:

```rust
impl TryFrom<CompanyQuery> for CompanyFilter {
    type Error = ApiError;

    fn try_from(q: CompanyQuery) -> Result<Self, ApiError> {
        Ok(CompanyFilter {
            lifecycle: q.lifecycle,
            search: q.search,
            tag: q.tag.as_deref().map(parse_tag).transpose()?,
        })
    }
}
// CompanyFilter::matches gains a third condition:
//     && self.tag.as_ref().is_none_or(|t| c.tags.contains(t))
```

…and `CompanyResponse`/`ContactResponse` gain `pub tags: Vec<String>`, filled by a helper
`tag_strings(&c.tags)`, which preserves the set's sorted order.

**Decisions worth defending:**
- **POST for add, with 201 vs 200.** `PUT /companies/{id}/tags/{tag}` (idempotent "make it so")
  would be equally RESTful, and arguably purer. The spec chose POST + idempotent behaviour + a
  status that tells you whether anything changed. Either is fine if documented.
- **DELETE of an absent tag is 204, not 404.** The client's intent ("this entity should not have
  this tag") is satisfied. A 404 would make retries after a timeout fail spuriously. 404 is
  reserved for the *entity* not existing.
- **Invalid tag is 422 even in a query string.** The URL was readable (so not 400), but a value
  in it breaks a rule, and the response carries a `fields` entry the client can show.
- **`parse_tag` is `pub(crate)`** and lives in `http/tags.rs`. It's an HTTP concern (mapping a
  domain error to a field error), shared by the companies and contacts modules.
- **No persistence when nothing changed.** Idempotent repeats are free, and the 200/204 tells the
  client so.

## 6. Tests

`src/tags.rs` unit tests cover the normalisation table (valid and invalid inputs, including
`"naïve"` and 33 characters). `tests/api/tags.rs` (4 tests in the reference run):

```text
tagging_normalises_and_is_idempotent      POST Key%20Account → 201 ["key-account"]; again → 200, one tag
invalid_tag_is_422_and_unknown_entity_is_404
filter_by_tag_and_count                   ?tag=ENTERPRISE filters; /tags counts; DELETE twice → 204, 204; counts update
invalid_tag_filter_is_422                 ?tag=%2F%2F → 422
```

And the backward-compatibility test, `tests/tags_persistence.rs`:

```rust
#[test]
fn data_saved_before_tags_existed_still_loads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("old.json");
    let mut crm = Crm::default();
    crm.add_company(NewCompany { name: "Acme".into(), website: None }).unwrap();
    // Simulate a pre-tags file by stripping the field.
    let mut json = serde_json::to_value(&crm).unwrap();
    json["companies"]["items"][0].as_object_mut().unwrap().remove("tags");
    std::fs::write(&path, json.to_string()).unwrap();

    let loaded = JsonFileStorage::new(&path).load().unwrap();
    assert!(loaded.companies.all()[0].tags.is_empty());
}
```

(The JSON path `["companies"]["items"]` depends on how your `InMemoryRepo` serializes. Adjust
it to your file's shape: open a saved `crm-data.json` and look.)

Reference run: all Lab 29 tests unchanged and passing, plus 2 tag unit tests, 4 tag API tests,
and 1 persistence test. `cargo clippy --all-targets` clean.

## Pitfalls seen in this design

- **Forgetting `#[serde(default)]`.** Everything compiles, and every existing data file fails at
  startup. Only a test like the one above catches it.
- **`is_alphanumeric()` instead of `is_ascii_*`.** `ï` passes, and you get tags that look
  identical but differ in bytes.
- **Normalising in the handler.** It works until the second handler (the query filter) forgets
  to. Normalise in the type.
- **Building the response after `persist().await`** by re-locking. That's correct but it reads the
  state twice, and another request may have changed it in between. Capture what you need inside
  the first lock block.
- **Holding the write guard across `persist().await`.** That doesn't compile (the future isn't
  `Send`, Lab 27), which is the compiler protecting you.

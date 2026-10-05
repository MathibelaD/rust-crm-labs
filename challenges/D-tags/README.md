# 🏁 Challenge D — Tags

> **After:** Lab 29 (end of Phase 8) · **Concepts from:** Phases 4–8 · **Time:** ~4–6 hours
> **Your repo before:** tag `lab-29` · **Suggested branch:** `challenge-d-tags`

There are no steps here. You get a specification, an API contract, constraints and acceptance
criteria. How you get there is up to you. [hints.md](hints.md) has tiered hints, and
[reference.md](reference.md) shows one possible design. Read it **after** you're done.

> Later labs never depend on this challenge. Work on a branch, and merge it if you're happy with
> it. Lab 30 moves companies and contacts to Postgres. If you merged tags, porting them to a
> `tags` table is optional extra practice there.

---

## The feature

Sales teams label accounts and people: `enterprise`, `churn-risk`, `conference-2026`,
`decision-maker`. They want to:

- attach and remove tags on **companies** and **contacts**,
- filter lists by tag (`GET /companies?tag=enterprise`),
- see which tags exist and how often they're used, so the vocabulary doesn't drift into
  `Enterprise`, `enterprise ` and `ENTERPRISE`.

A tag is attached to many entities, and an entity has many tags: a **many-to-many** relationship.
It lives in the in-memory `Crm` and is persisted in the JSON data file like everything else.

## Tag rules (normalisation)

A tag is accepted in a loose form and **stored in one canonical form**:

1. Trim surrounding whitespace, lowercase.
2. Runs of whitespace and `_` become a single `-`. No leading, trailing or doubled `-`.
3. After that, only `a–z`, `0–9` and `-` are allowed. Anything else (`/`, `ä`, `!`, …) makes the
   tag **invalid**. Don't silently strip characters.
4. Length 1–32 after normalising.

| Input | Result |
|---|---|
| `"Enterprise"` | `enterprise` |
| `"  Key Account "` | `key-account` |
| `"VIP__client"` | `vip-client` |
| `"-a--b-"` | `a-b` |
| `""`, `"   "`, `"---"` | invalid (empty) |
| `"naïve"`, `"a/b"` | invalid (character) |
| 33 × `"x"` | invalid (too long) |

Two inputs that normalise to the same tag **are** the same tag: an entity can't carry
`Enterprise` and `enterprise` separately.

## API contract

All bodies are JSON. Errors use the Lab 28 format (`{"error": {"code", "message", "fields"?}}`).
In URLs, a tag is a path segment, so clients percent-encode it (`Key%20Account`).

| Method & path | Success | Errors |
|---|---|---|
| `POST /companies/{id}/tags/{tag}` | **201** `{"tags": [...]}` if the tag was added; **200** with the same body if it was already there | 404 `not_found` (company), 422 `validation_failed` with field `tag` (invalid tag), 400 (non-numeric id) |
| `DELETE /companies/{id}/tags/{tag}` | **204**, also when the company didn't have the tag | 404 (company), 422 (invalid tag) |
| `POST /contacts/{id}/tags/{tag}` | same as companies | same |
| `DELETE /contacts/{id}/tags/{tag}` | same as companies | same |
| `GET /companies?tag=enterprise` | `Page<CompanyResponse>`, only companies with that tag; combinable with the existing `lifecycle`, `search`, `page`, `per_page` | 422 (invalid tag) |
| `GET /contacts?tag=enterprise` | `Page<ContactResponse>`; combinable with `company_id`, `search`, `sort`, pagination | 422 (invalid tag) |
| `GET /tags` | **200**, every tag in use, sorted alphabetically, with usage counts | |

`{"tags": [...]}` is the entity's complete tag list after the operation, **sorted**.

`CompanyResponse` and `ContactResponse` gain a `tags` field (sorted array of strings, `[]` when
none). That's an *additive* change: existing clients ignore it.

`GET /tags` response:

```json
[
  { "tag": "enterprise", "companies": 1, "contacts": 1 },
  { "tag": "smb",        "companies": 1, "contacts": 0 }
]
```

A tag that is no longer attached to anything **does not appear**. Tags exist only through their
use; there is no separate "create tag" endpoint.

Example session (fresh data file; company 1 = Acme, company 2 = Globex, contact 1 = Ada):

```text
POST   /companies/1/tags/Enterprise      → 201 {"tags":["enterprise"]}
POST   /companies/1/tags/enterprise      → 200 {"tags":["enterprise"]}
POST   /companies/1/tags/a%2Fb           → 422 {"error":{"code":"validation_failed","message":"request has invalid fields","fields":[{"field":"tag","message":"invalid tag: a/b"}]}}
POST   /companies/2/tags/smb             → 201 {"tags":["smb"]}
POST   /contacts/1/tags/ENTERPRISE       → 201 {"tags":["enterprise"]}
POST   /contacts/99/tags/vip             → 404 {"error":{"code":"not_found","message":"contact #99 not found"}}
GET    /companies?tag=Enterprise         → 200 {"items":[{"id":1,"name":"Acme",...,"tags":["enterprise"]}],"page":1,"per_page":20,"total":1}
GET    /tags                             → 200 [{"tag":"enterprise","companies":1,"contacts":1},{"tag":"smb","companies":1,"contacts":0}]
DELETE /companies/2/tags/smb             → 204
DELETE /companies/2/tags/smb             → 204
GET    /tags                             → 200 [{"tag":"enterprise","companies":1,"contacts":1}]
```

## Acceptance criteria

- [ ] Every row of the API contract behaves as specified, including status codes.
- [ ] Normalisation follows every row of the rules table, enforced by **one** function or type.
      Nothing else in the codebase lowercases or trims tags.
- [ ] Tagging is **idempotent**: adding an existing tag or removing a missing one changes nothing
      and doesn't fail.
- [ ] Tags survive a restart: they are saved in the JSON data file and loaded again.
- [ ] **A data file written by Lab 29 (with no tags anywhere) still loads**, and every entity
      starts with no tags. Prove it with a test.
- [ ] Deleting a company or contact also removes its tags from `GET /tags` counts.
- [ ] API tests in `tests/api/tags.rs` (added to `tests/api/main.rs`) covering at least:
      normalisation over HTTP, idempotency (201 then 200; 204 twice), invalid tag (422 with field
      `tag`), unknown entity (404), `?tag=` filtering combined with another filter, and
      `GET /tags` counts after adds and removes.
- [ ] Unit tests for normalisation (valid and invalid inputs from the table).
- [ ] All Lab 29 tests still pass, unchanged except where a response now contains `tags`.
- [ ] `cargo fmt --check && cargo clippy --all-targets && cargo test` is clean.

## Constraints

- **No new crates.** Standard library, serde and what you already have.
- **The domain owns the rules.** Normalisation, idempotency and counting live in the domain
  (`Crm` and/or a tags module), not in handlers. Handlers translate between HTTP and domain calls,
  exactly as in Labs 28–29.
- **One canonical representation.** After validation, a tag must be a type that *cannot* hold an
  un-normalised string. A bare `String` passed around is not enough.
- **Don't clone entities** to count or filter tags. Borrow.
- `GET /tags` must be deterministic (same data → same order) without sorting at the end of every
  handler by hand. Let a data structure do it.
- The CLI (`crm-cli`) doesn't need tag commands. It must still compile and work.
- Mutating endpoints persist, just like every other mutation (`state.persist().await?`). Skipping
  the save when nothing changed is allowed and encouraged.

## Concepts you're expected to use

- **Newtype with a private field + validating constructor** (Labs 12–13 `Email`), and serde's
  `try_from`/`into` so the JSON file can't smuggle in an invalid tag (Lab 21)
- **Choosing a collection**: `Vec` vs `HashSet` vs `BTreeSet` / `BTreeMap`, and what each gives you
  for uniqueness and ordering (Labs 05, 17, 18)
- **Backward-compatible serialization**: what serde does when a field is missing, and how to change
  that (Lab 21)
- **Generics and traits** if you want one implementation for companies *and* contacts (Labs 15–16)
- **Iterators**: `flat_map`, `filter`, the entry API (Labs 17–18)
- **Borrowing in queries**: returning references into the `Crm`, converting to DTOs before the lock
  is released (Labs 10, 27–29)
- **The HTTP layer**: path extractors with two parameters, `AppQuery`, `ApiError`, status codes for
  idempotent operations (Labs 28–29)
- **API tests** with the Lab 29 helpers

## Things to think about (not required)

- In a relational database, how would you store this? What does that suggest about "a set of tags
  on each entity" versus "a list of (tag, entity) pairs"? Which would you rather migrate in Lab 30?
- Should `GET /companies?tag=a&tag=b` mean AND or OR? How would you even parse a repeated query
  key? (`serde_urlencoded` doesn't support it into a `Vec`, so look at how axum-extra's `Query`
  differs.)
- Renaming a tag everywhere (`PUT /tags/{old}` → `{new}`): what happens when `new` already exists
  on some entities?
- A limit of, say, 20 tags per entity: which status code, and where does the rule live?

## Done?

```bash
git add .
git commit -m "Add tags to companies and contacts"
git tag challenge-d
git push && git push --tags
```

Then read [reference.md](reference.md) and compare. Different is fine. *Worse for a reason you
can name* is worth a follow-up commit.

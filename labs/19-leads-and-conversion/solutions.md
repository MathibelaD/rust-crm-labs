# Lab 19 — Solutions

> 🔴 **SOLUTION**: read these *after* a genuine attempt. Compare the reasoning, not the characters.

---

## Mini-task: `LeadSource` `Display` and `FromStr`

```rust
impl fmt::Display for LeadSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            LeadSource::Website => "website",
            LeadSource::Referral => "referral",
            LeadSource::Event => "event",
            LeadSource::ColdOutreach => "cold_outreach",
            LeadSource::Other => "other",
        };
        f.pad(label)
    }
}

impl FromStr for LeadSource {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_lowercase().replace('-', "_").as_str() {
            "website" => Ok(LeadSource::Website),
            "referral" => Ok(LeadSource::Referral),
            "event" => Ok(LeadSource::Event),
            "cold_outreach" => Ok(LeadSource::ColdOutreach),
            "other" => Ok(LeadSource::Other),
            _ => Err(ValidationError::InvalidValue {
                field: "lead source",
                value: s.to_string(),
            }),
        }
    }
}
```

- **Normalise, then match.** `trim → to_lowercase → replace('-', "_")` turns `" Cold-Outreach"`
  into `"cold_outreach"`, so the `match` only needs one spelling per variant. Each step returns
  a new `String`, and `.as_str()` borrows the final one for the `match`. That temporary lives
  until the end of the `match` statement, which is long enough (Lab 10's temporary lifetime rule).
- **The error keeps the user's original input** (`s`, not the normalised string), because the
  message should show what they typed.
- `cold_outreach` (snake_case) is the canonical spelling because that's what `serde`'s
  `rename_all = "snake_case"` will produce in Lab 21. Consistent spelling everywhere avoids a
  second mapping table later.

Round-trip test (in `model.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lead_sources_round_trip_through_strings() {
        let all = [
            LeadSource::Website,
            LeadSource::Referral,
            LeadSource::Event,
            LeadSource::ColdOutreach,
            LeadSource::Other,
        ];
        for source in all {
            assert_eq!(source.to_string().parse::<LeadSource>(), Ok(source));
        }
        assert_eq!("Cold-Outreach".parse::<LeadSource>(), Ok(LeadSource::ColdOutreach));
        assert!("billboard".parse::<LeadSource>().is_err());
    }
}
```

---

## Your Turn 1 — Testing `Crm::convert_lead`

```rust
#[cfg(test)]
mod lead_tests {
    use super::*;
    use crate::leads::LeadStatus;

    fn email(s: &str) -> Email {
        Email::parse(s).unwrap()
    }

    /// A CRM with one existing contact (ada@acme.example) and one *new* lead.
    fn crm_with_lead(lead_email: &str) -> (Crm, LeadId) {
        let mut crm = Crm::new();
        let acme = crm.add_company("Acme".to_string(), None).unwrap();
        crm.add_contact("Ada".to_string(), email("ada@acme.example"), None, Some(acme))
            .unwrap();
        let id = crm
            .add_lead(
                "Grace".to_string(),
                email(lead_email),
                Some("Navy Labs".to_string()),
                LeadSource::Referral,
                None,
            )
            .unwrap();
        (crm, id)
    }

    #[test]
    fn converting_a_qualified_lead_creates_records_and_removes_the_lead() {
        let (mut crm, id) = crm_with_lead("grace@navy.example");
        crm.qualify_lead(id).unwrap();

        let summary = crm
            .convert_lead(id, Some(("Pilot".to_string(), Money::from_cents(100_000))))
            .unwrap();

        assert!(crm.leads.get(id).is_none());
        assert_eq!(crm.companies.get(summary.company_id).unwrap().name, "Navy Labs");
        let contact = crm.contacts.get(summary.contact_id).unwrap();
        assert_eq!(contact.company_id, Some(summary.company_id));
        let deal = crm.deals.get(summary.deal_id.unwrap()).unwrap();
        assert_eq!(deal.company_id, summary.company_id);
    }

    #[test]
    fn unqualified_lead_stays_in_the_crm() {
        let (mut crm, id) = crm_with_lead("grace@navy.example");
        let before = crm.lead(id).unwrap().clone();

        let result = crm.convert_lead(id, None);

        assert!(matches!(result, Err(CrmError::LeadNotQualified(lead)) if lead == id));
        assert_eq!(crm.lead(id).unwrap(), &before);
        assert_eq!((crm.companies.len(), crm.contacts.len(), crm.deals.len()), (1, 1, 0));
    }

    #[test]
    fn duplicate_email_blocks_conversion_and_keeps_the_lead() {
        let (mut crm, id) = crm_with_lead("ADA@acme.example");
        crm.qualify_lead(id).unwrap();

        let result = crm.convert_lead(id, None);

        assert!(matches!(result, Err(CrmError::DuplicateEmail(_))));
        assert_eq!(crm.lead(id).unwrap().status, LeadStatus::Qualified);
        assert_eq!((crm.companies.len(), crm.contacts.len()), (1, 1));
    }

    #[test]
    fn invalid_deal_blocks_conversion_and_keeps_the_lead() {
        let (mut crm, id) = crm_with_lead("grace@navy.example");
        crm.qualify_lead(id).unwrap();

        let result = crm.convert_lead(id, Some(("  ".to_string(), Money::ZERO)));

        assert!(matches!(result, Err(CrmError::Validation(_))));
        assert!(crm.leads.get(id).is_some());
        assert!(crm.deals.is_empty());
    }
}
```

**Reasoning:**

- **One setup helper, parameterised by the one thing that varies** (the lead's email). The
  duplicate-email test uses `"ADA@acme.example"` to also check that `Email` normalisation makes
  the comparison case-insensitive. A cheap test of two features at once.
- **`matches!(result, Err(CrmError::LeadNotQualified(lead)) if lead == id)`**: `matches!`
  accepts a **match guard** (`if ...`), so it checks the variant *and* the id. You can't write
  `LeadNotQualified(id)` in the pattern to mean "equal to the variable `id`": a name in a
  pattern always *binds a new variable*. The guard is how you compare against an existing value.
- **`let before = crm.lead(id).unwrap().clone();`**: holding the `&Lead` across
  `crm.convert_lead(..)` (which needs `&mut crm`) would be E0502. Cloning ends the shared borrow.
  This is a legitimate clone: test code needs a snapshot to compare against.
- **Asserting repo sizes** is what proves "nothing half-happened". An error alone doesn't
  prove there were no side effects.

---

## Your Turn 2 — Disqualifying leads

`model.rs`:

```rust
    pub fn disqualify(&mut self) {
        self.status = LeadStatus::Disqualified;
    }
```

`crm.rs`:

```rust
    pub fn disqualify_lead(&mut self, id: LeadId) -> Result<(), CrmError> {
        self.lead_mut(id)?.disqualify();
        Ok(())
    }
```

`parser.rs`: add `Disqualify { id: LeadId }` to `LeadCommand`, `["disqualify", raw] =>
Ok(LeadCommand::Disqualify { id: id(raw)? }),` to `parse_lead`, and update `USAGE`.

`commands.rs`:

```rust
        LeadCommand::Disqualify { id } => {
            crm.disqualify_lead(id)?;
            println!("Lead {id} is disqualified");
        }
```

Tests (added to `lead_tests`):

```rust
    #[test]
    fn disqualified_lead_cannot_be_qualified_or_converted() {
        let (mut crm, id) = crm_with_lead("grace@navy.example");
        crm.disqualify_lead(id).unwrap();

        assert!(matches!(crm.qualify_lead(id), Err(CrmError::LeadDisqualified(_))));
        assert!(matches!(crm.convert_lead(id, None), Err(CrmError::LeadNotQualified(_))));
        assert_eq!(crm.lead(id).unwrap().status, LeadStatus::Disqualified);
    }

    #[test]
    fn unknown_lead_is_not_found() {
        let mut crm = Crm::new();
        assert!(matches!(
            crm.disqualify_lead(LeadId(9)),
            Err(CrmError::NotFound { entity: "lead", id: 9 })
        ));
    }
```

**Why `disqualify` returns `()`:** there's no state from which disqualifying is illegal, so
a `Result` would be noise that every caller has to handle. Signatures should tell the truth:
`qualify` can fail, so it returns `Result`. `disqualify` can't, so it doesn't. The `Crm` method
returns `Result` only because the *lookup* can fail.

Notice that converting a disqualified lead reports `LeadNotQualified`, not `LeadDisqualified`.
`convert` checks one thing ("is it qualified?"). If you'd rather report the more specific error,
match on `self.status` inside `convert` with three arms. That's a reasonable refinement.

---

## Your Turn 3 — `lead list` filters

`src/leads/filter.rs`:

```rust
use super::{Lead, LeadSource, LeadStatus};

/// Which leads `lead list` shows. `None` means "don't filter on this".
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct LeadFilter {
    pub status: Option<LeadStatus>,
    pub source: Option<LeadSource>,
}

impl LeadFilter {
    pub fn matches(&self, lead: &Lead) -> bool {
        self.status.is_none_or(|status| lead.status == status)
            && self.source.is_none_or(|source| lead.source == source)
    }
}
```

In `leads/mod.rs`: `mod filter;` and `pub use filter::LeadFilter;`.

`LeadStatus` `FromStr` (in `model.rs`) has the same shape as `LeadSource`'s, with
`field: "lead status"`.

`crm.rs`:

```rust
    pub fn list_leads(&self, filter: &LeadFilter) -> Vec<&Lead> {
        self.leads.find_where(|lead| filter.matches(lead))
    }
```

`parser.rs`:

```rust
        ["list", flags @ ..] => parse_lead_list(flags),
```

```rust
fn parse_lead_list(flags: &[&str]) -> Result<LeadCommand, CrmError> {
    const USAGE: &str = "lead list [--status <status>] [--source <source>]";
    let mut filter = LeadFilter::default();
    for pair in flags.chunks(2) {
        match pair {
            ["--status", value] => filter.status = Some(value.parse()?),
            ["--source", value] => filter.source = Some(value.parse()?),
            _ => return Err(CrmError::Usage(USAGE)),
        }
    }
    Ok(LeadCommand::List(filter))
}
```

`commands.rs`:

```rust
        LeadCommand::List(filter) => {
            let leads = crm.list_leads(&filter);
            if leads.is_empty() {
                println!("No leads found.");
            }
            for lead in leads {
                println!("{lead}");
            }
        }
```

**Reasoning:**

- **`LeadFilter` is `Copy`**: both fields are `Option<Copy enum>`. Lab 17's `ContactFilter`
  couldn't be, because it holds a `String`.
- **`flags @ ..`** binds "the rest of the slice" to a name. Combined with `chunks(2)`, every
  iteration sees a `&[&str]` of length 2 (or 1 at a dangling end), and the inner `match`
  handles all shapes. A missing value is a length-1 chunk and lands in `_`, so it's a usage error.
- **`value.parse()?`**: the target type comes from the field being assigned
  (`Option<LeadStatus>`), and the `ValidationError` converts to `CrmError::Validation` via
  `From`, giving `Error: invalid lead status: 'hot'`.
- `matches` with **`is_none_or`** reads like the requirement: "no status filter, or the status
  matches".

Tests:

```rust
    #[test]
    fn list_leads_filters_by_status_and_source() {
        let (mut crm, grace) = crm_with_lead("grace@navy.example");
        let linus = crm
            .add_lead("Linus".to_string(), email("linus@kernel.example"), None, LeadSource::Website, None)
            .unwrap();
        crm.qualify_lead(grace).unwrap();

        let ids = |filter: LeadFilter| -> Vec<LeadId> {
            crm.list_leads(&filter).iter().map(|lead| lead.id).collect()
        };
        assert_eq!(ids(LeadFilter::default()), [grace, linus]);
        assert_eq!(ids(LeadFilter { status: Some(LeadStatus::New), source: None }), [linus]);
        assert_eq!(ids(LeadFilter { status: None, source: Some(LeadSource::Referral) }), [grace]);
        assert!(ids(LeadFilter { status: Some(LeadStatus::New), source: Some(LeadSource::Referral) }).is_empty());
    }
```

```rust
    // in parser.rs tests
    #[test]
    fn parses_lead_list_filters() {
        use crate::leads::{LeadSource, LeadStatus};
        let expected = LeadFilter {
            status: Some(LeadStatus::Qualified),
            source: Some(LeadSource::ColdOutreach),
        };
        assert_eq!(
            parse_command("lead list --status qualified --source cold-outreach").unwrap(),
            Some(Command::Lead(LeadCommand::List(expected)))
        );
        assert!(matches!(parse_command("lead list --status"), Err(CrmError::Usage(_))));
        assert!(matches!(parse_command("lead list --status hot"), Err(CrmError::Validation(_))));
    }
```

The `ids` closure **borrows `crm` immutably** for as long as the closure exists. That's fine,
because nothing mutates `crm` after it's created. (Try adding `crm.qualify_lead(linus)` between
two `ids(..)` calls to see E0502.)

---

## Experiment answers

**Experiment 1 (re-insert order):** either (a) make `lead list` sort by id (`leads.sort_by_key(|l| l.id)`), or (b) give `InMemoryRepo` an "insert at the right position"
method. (a) is simpler and keeps `InMemoryRepo` generic. In Postgres, rows have no inherent
order. Every list query needs an explicit `ORDER BY`, so the problem dissolves into "always
sort explicitly", which is (a).

**Experiment 2 (`&self`):** `name: self.name` and `email: self.email` fail with E0507 (cannot
move out of a shared reference), so you'd need `.clone()` for every field. After success, the
`Crm` would have to remember to *delete* the lead. Forget that, and the lead can be
converted twice. The `self` version makes forgetting impossible.

**Experiment 3 (forgetting to put it back):** `warning: unused variable: lead`. The lead is
dropped at the closing `}` of the `Err` arm, when its owner (the `lead` binding) goes out of
scope. The data is simply gone. Silencing the warning with `lead: _` would make the data loss
*silent*.

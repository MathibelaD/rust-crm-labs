# Rust CRM Labs

A hands-on Rust curriculum where you learn the language by building **one real application from
scratch**: a CRM backend, starting from `cargo new` and ending as a deployed, authenticated,
PostgreSQL-backed REST API.

> **This repository is the teacher. It does not contain the CRM.**
> You build the CRM yourself, in your own repository.

```text
rust-crm-labs/          ← THIS repo: instructions, hints, solutions to exercises
rust-crm/               ← YOUR repo: you create it in Lab 01 and write every line
```

---

## Start here

1. Read the [roadmap](roadmap/roadmap.md). It shows every lab, what you'll learn and what it
   adds to the CRM.
2. Open [Lab 01](labs/01-getting-started/README.md) and follow it in a terminal.
3. Keep this repo open in one window and **your** `rust-crm` repo in another.

You're expected to know how to program (e.g. JavaScript/TypeScript). You are **not** expected
to know Rust or systems programming.

---

## Repository layout

```text
rust-crm-labs/
├── README.md                ← you are here
├── roadmap/
│   └── roadmap.md           ← the full curriculum plan
├── labs/
│   ├── README.md            ← index of all labs
│   ├── _TEMPLATE.md         ← the structure every lab follows
│   └── NN-lab-name/
│       ├── README.md        ← the lab itself
│       └── solutions.md     ← 🔴 solutions, kept separate on purpose
└── challenges/
    └── X-challenge-name/
        ├── README.md        ← spec + acceptance criteria only
        ├── hints.md         ← tiered hints
        └── reference.md     ← one possible design (read *after* you've finished)
```

Solutions are in **separate files**, not underneath the exercise, so they can't spoil the
exercise by accident. There's deliberately no "finished CRM" anywhere in this repository.

---

## How each lab works

Every lab has the same sections, in the same order:

| Section | Purpose |
|---|---|
| 🎯 Goal | What we're adding to the CRM |
| 🧠 What You'll Learn | The Rust concepts |
| 🔨 What We're Building | The CRM feature |
| Step 1, Step 2, … | Exact instructions |
| ▶️ Run It | The exact command |
| ✅ Expected Result | What you should see |
| 🧠 Understand It | Why the code works |
| 🧪 Experiment | Break or change something on purpose |
| 👩🏽‍💻 Your Turn | Implement something yourself |
| 💡 Hint | A nudge, not the answer |
| 🆘 Solution | Pointer to `solutions.md` (optional!) |
| ✅ Checkpoint | Prove to yourself that you understood it |
| Git Commit | A meaningful commit message, plus a `lab-NN` tag |

### Instruction markers

These markers matter. They tell you **how** to engage with each block:

| Marker | Meaning | What you do |
|---|---|---|
| 🟢 **FOLLOW ALONG** | Code that teaches a concept | Type it in (typing beats pasting) |
| 🟡 **EXPERIMENT** | A deliberate change | Predict the result first, *then* run it |
| 🔵 **YOUR TURN** | An implementation task | Write it yourself |
| 💡 **HINT** | A clue | Use it after a genuine attempt |
| 🔴 **SOLUTION** | The full answer | Only in `solutions.md` |

### The learning loop

```text
Explanation → Instructor example → Run it → Modify it → Small challenge
→ Independent implementation → Checkpoint → Commit
```

### Reading compiler errors

When a lab gives you code that **won't compile on purpose**, don't fix it straight away. Run
`cargo check`, read the whole message, and answer:

1. **Who owns** this value?
2. Was ownership **moved**? Where?
3. Is this a **borrow**? Shared (`&`) or **mutable** (`&mut`)?
4. **How long** does the reference need to live? How long does the owner live?

Then choose a fix *and explain why it's the right one*. "Add `&` until it compiles" is not the
goal.

---

## Git workflow for your CRM

Commit throughout each lab, not only at the end. At the end of every lab:

```bash
git add .
git commit -m "Add customer search"      # the lab suggests a message
git tag lab-10
git push && git push --tags
```

Your history becomes a record of how you learned. `git diff lab-07 lab-08` shows exactly what a
refactor changed.

---

## Lab index

All 41 labs, the five phase challenges and the capstone are listed in [labs/README.md](labs/README.md).

Every lab's code was compiled and tested in a throwaway copy while the lab was written, so the
compiler errors and outputs you see in the labs are real. Your output may differ in small details
(paths, line numbers, thread ids, timings).

---

## Course website

The course is also published as a website built with [mdBook](https://rust-lang.github.io/mdBook/):
<https://mathibelad.github.io/rust-crm-labs/>

- `SUMMARY.md` sets the sidebar order. When you add a lab or a challenge, add it there too.
- `.github/workflows/pages.yml` rebuilds and publishes the site on every push to `main`.
- To preview locally, install mdBook (`brew install mdbook` or `cargo install mdbook`), then run
  `scripts/build-book.sh` and open `_book/index.html`. Always build through the script: it keeps
  `.git/` and other dotfiles out of the published site.

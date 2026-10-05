# Lab 23 — Solutions

> 🔴 **SOLUTION**: make a genuine attempt first. Each solution explains *why* it's shaped that way.

---

## 🔵 Your Turn 1: `InMemoryStorage`

`src/storage/memory.rs`:

```rust
use super::{Storage, StorageError};
use crate::crm::Crm;

/// Keeps nothing: every session starts empty and saving is a no-op.
/// Useful for demos, experiments and tests that must not touch the disk.
#[derive(Debug, Default, Clone, Copy)]
pub struct InMemoryStorage;

impl Storage for InMemoryStorage {
    fn load(&self) -> Result<Crm, StorageError> {
        Ok(Crm::default())
    }

    fn save(&self, _crm: &Crm) -> Result<(), StorageError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_starts_empty() {
        let crm = InMemoryStorage.load().unwrap();
        assert!(crm.companies.is_empty());
    }

    #[test]
    fn save_keeps_nothing() {
        let storage = InMemoryStorage;
        let mut crm = Crm::new();
        crm.add_company("Acme".into(), None).unwrap();
        storage.save(&crm).unwrap();
        assert!(storage.load().unwrap().companies.is_empty());
    }
}
```

**Reasoning**

- **A unit struct is a type with exactly one value**, also written `InMemoryStorage`. It takes 0
  bytes. `Box::new(InMemoryStorage)` doesn't even allocate (Rust never allocates for zero-sized
  types), but the `Box<dyn Storage>` is still 16 bytes, because the vtable pointer is needed.
- **`Copy` is free and honest**: there's nothing to duplicate. `Default` lets generic code create
  one.
- **`_crm`** silences the unused-parameter warning while keeping the parameter's name meaningful.
  A bare `_` would also work.
- **Why doesn't it keep the last saved CRM?** It could (`RefCell<Option<Crm>>`), but then it's a
  different tool: a *fake* for tests. Keeping `InMemoryStorage` trivially simple makes its
  behaviour obvious from its name. Lab 24 builds the fake separately.
- **`save_keeps_nothing`** documents surprising behaviour *as a test*. If someone later "improves"
  it to remember data, the test forces them to make that decision deliberately.

---

## 🔵 Your Turn 2: the provided method `describe`

In the trait (`src/storage/mod.rs`):

```rust
pub trait Storage {
    fn load(&self) -> Result<Crm, StorageError>;
    fn save(&self, crm: &Crm) -> Result<(), StorageError>;

    /// A short human description, shown in the banner.
    fn describe(&self) -> String {
        String::from("custom storage")
    }
}
```

In `JsonFileStorage`'s impl:

```rust
    fn describe(&self) -> String {
        format!("JSON file {}", self.path.display())
    }
```

In `InMemoryStorage`'s impl:

```rust
    fn describe(&self) -> String {
        String::from("in memory (nothing will be saved)")
    }
```

In `cli::run`, right after the two banner lines:

```rust
    println!("Storage: {}", storage.describe());
```

**Reasoning**

- **Default bodies** make a trait easier to implement and easier to evolve: adding a provided
  method later doesn't break existing implementations. Required methods (`load`, `save`) are the
  ones with no sensible default.
- **Still dyn compatible?** Yes. `describe` takes `&self`, isn't generic and doesn't return `Self`.
  Each type's vtable gets an entry for `describe`, pointing at the override if there is one, or at
  a copy of the default body specialised for that type otherwise. "Has a body" doesn't change
  anything about the vtable. The signature does.
- **Why `String` and not `&str`?** `JsonFileStorage` must *build* its text (`format!`), so there's
  no existing `str` to borrow from. Returning `&'static str` would work for the memory backend but
  not for the file one. An owned `String` fits every implementation.
- **Why `describe` and not `impl Display`?** Requiring `Display` as a supertrait
  (`trait Storage: Display`) would work too. A named method is more explicit about its purpose
  ("for the banner") and doesn't force every backend into one `Display` format.
- **`path.display()`**: a `Path` may not be valid UTF-8, so it isn't `Display` itself.
  `.display()` returns a small wrapper that prints it, replacing invalid bytes.

---

## 🔵 Your Turn 3: test the command line

At the bottom of `src/main.rs`:

```rust
#[cfg(test)]
mod tests {
    use clap::CommandFactory;

    use super::*;

    #[test]
    fn args_definition_is_valid() {
        Args::command().debug_assert();
    }

    // Assumes CRM_DATA_FILE is not set in the environment running the tests.
    #[test]
    fn defaults_to_json_storage_and_crm_data_json() {
        let args = Args::try_parse_from(["rust-crm"]).unwrap();
        assert_eq!(args.storage, StorageKind::Json);
        assert_eq!(args.data_file, PathBuf::from("crm-data.json"));
    }

    #[test]
    fn storage_memory_is_accepted() {
        let args = Args::try_parse_from(["rust-crm", "--storage", "memory"]).unwrap();
        assert_eq!(args.storage, StorageKind::Memory);
    }

    #[test]
    fn unknown_storage_is_rejected() {
        let err = Args::try_parse_from(["rust-crm", "--storage", "sqlite"]).unwrap_err();
        assert_eq!(err.kind(), clap::error::ErrorKind::InvalidValue);
    }

    #[test]
    fn data_file_flag_is_used_by_json_storage() {
        let args = Args::try_parse_from(["rust-crm", "--data-file", "other.json"]).unwrap();
        assert_eq!(build_storage(args).describe(), "JSON file other.json");
    }

    #[test]
    fn memory_storage_describes_itself() {
        let args = Args::try_parse_from(["rust-crm", "--storage", "memory"]).unwrap();
        assert!(build_storage(args).describe().contains("in memory"));
    }
}
```

**Reasoning**

- **The first element is the program name.** `try_parse_from` treats it like `argv[0]` and skips
  it, so every list starts with `"rust-crm"`.
- **`Args::command().debug_assert()`** checks the definition itself: duplicate flags, invalid
  defaults, conflicting names. These are bugs that would otherwise only appear when a user hits
  that path. `CommandFactory` is the trait that provides `command()`, so it must be imported.
- **Testing through `build_storage(...).describe()`** checks the wiring (flag → `PathBuf` →
  `JsonFileStorage`) without inspecting private fields and without touching the disk. Your
  Your Turn 2 method doubles as a test hook.
- **Testing the error *kind*,** not its text. The message format belongs to clap and may change
  between versions. The kind is a stable enum.
- **No environment variables in tests.** The environment belongs to the whole process, and tests
  run on parallel threads. That's exactly why edition 2024 made `set_var` `unsafe`. The one
  consequence (the defaults test assumes `CRM_DATA_FILE` is unset) is documented in a comment.
  If you really need to test env handling, run the binary as a subprocess with
  `std::process::Command::new(...).env("CRM_DATA_FILE", ...)`. A child process gets its own
  environment, so nothing is shared.
- These are **unit tests in a binary crate**. They can see private items like `Args` and
  `build_storage`. Lab 24's `tests/` directory can't, because a binary has no public API. That's one
  more reason to keep `main.rs` small.

---

## 🧪 Experiment answers

**Experiment 1: `println!("{:?}", storage)`.** Error: `` `dyn Storage` doesn't implement `Debug` ``.
The vtable only contains the trait's methods (plus drop/size/align). `Debug::fmt` isn't one of
them, so once the type is erased, there's no way to reach the concrete type's `Debug` impl. Fix:
make `Debug` a **supertrait**, `pub trait Storage: std::fmt::Debug { ... }`. Then every
implementation must be `Debug`, and `Debug::fmt` is included in the vtable. Lab 25 uses exactly
this mechanism with `Send + Sync`.

**Experiment 2: using `args` after `build_storage(args)`.** E0382, borrow of moved value. `args`
was moved into `build_storage`, which moves `args.data_file` (a `PathBuf`) into
`JsonFileStorage`. With `&Args`, `build_storage` would have to `clone()` the path, because
`JsonFileStorage` must *own* its path. Taking `Args` by value says honestly: "I consume the
configuration to build the program", and costs nothing. If `main` needed `args` afterwards, you'd
pull out what you need first (`let data_file = args.data_file.clone();`), or pass `&args` and clone
inside. Either way, the clone becomes visible.

**Experiment 3: `CRM_DATA_FILE=` (empty).**

```text
error: a value is required for '--data-file <DATA_FILE>' but none was supplied
```

clap treats a set-but-empty variable as "the user supplied an empty value", not as "not set". That's
arguably right: an empty path would fail later with a much more confusing error. Rejecting it at
startup with a clear message is the better behaviour.

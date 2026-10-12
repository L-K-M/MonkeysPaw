# Starter prompts

These ten prompts are the first-run library for Monkey's Paw. `code/` and
`writing/` demonstrate folders; the prompt at the root helps you draft new
prompts. Each file stands on its own and has no fixed identity.

The set demonstrates text, multiline and choice fields, both option forms,
defaults, optional fields, descriptions, fields that forget values, implicit
fields, and clipboard/date/time builtins. Clipboard prompts use your current
clipboard as source material. Required fields without defaults need filling.

After editing, adding or removing a prompt, run from the repository root:

```sh
python3 scripts/generate-seeds.py
```

Commit both the Markdown and `Sources/MonkeysPawCore/Domain/SeedCatalog.generated.swift`.
The generator uses only Python's standard library and emits deterministic
Swift with exact UTF-8 bytes. Core tests check file membership and byte equality.
Both desktop apps link Core, so seeds need no separate resource installation.

This root `README.md` is excluded from the catalog and library enumeration
under §5.1. A nested `README.md` would be a prompt; keep documentation here.

`SeedService.seedIfEmpty()` seeds only a library with no eligible prompt files.
README, `.DS_Store`, non-Markdown and ignored files do not block it; malformed
prompts do. Installation is a real first save under §5.2, so each new prompt
gets a fresh ULID and canonical front matter while keeping its body bytes.
Existing destinations are skipped atomically and never overwritten. After a
partial failure or crash, the library is non-empty and the next run seeds
nothing. Onboarding records "seeds offered" separately and checks that no sync
server is configured before calling this service (§11.4).

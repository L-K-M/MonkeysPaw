## 5. Prompt library

### 5.1 Where things live

| What | Where | Synced? |
|---|---|---|
| Prompts | Library folder, default `~/Documents/MonkeysPaw/` (Linux: XDG documents dir). Any folder can be chosen. | By the sync server (§9) or by the user's git / Syncthing / iCloud |
| Settings | macOS `~/Library/Application Support/ch.lkmc.MonkeysPaw/settings.json`; Linux `$XDG_CONFIG_HOME/monkeyspaw/settings.json`. Every app-owned JSON file carries a `version` field and migrates forward on load. | no |
| History | `<data>/history/<prompt-id>/<UTC-timestamp>.md` (`HISTORY_CAP_PER_PROMPT = 50`). Synced prompts also have server revisions. | no |
| Logs | `<data>/logs/monkeyspaw.log` (§12) | no |
| Usage (ranking, last delivery) | `<data>/usage.json` | no |
| Remembered values | `<data>/values.json`, `PRIVATE_FILE_MODE = 0600` | no |
| Sync state | `<data>/sync/state.json` (§9.2) | no |
| Portal restore token | `<data>/portal.json` (§6.3) | no |
| API keys, device token | OS secret store | no |

`<data>` = macOS `~/Library/Application Support/ch.lkmc.MonkeysPaw/`, Linux
`$XDG_DATA_HOME/monkeyspaw/`. Under flatpak both resolve inside
`~/.var/app/ch.lkmc.monkeyspaw/`.

Library rules:

- Every `*.md` file under the library is a prompt. Subfolders are folders.
- Dot-directories and files starting with `_` are ignored, so `.git/` and
  `_drafts/` are skipped. A `README.md` at the root is ignored too.
- A file without front matter is a valid prompt: its title is the filename
  and its body is the whole file.
- With sync enabled, the top-level folders `Groups/` and `Conflicts/` are
  reserved (§9.1).

### 5.2 File format

```markdown
---
id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD
title: Review a diff
description: Correctness-first review of a pasted diff.
tags: [code, review]
favorite: true
fields:
  language:
    type: choice
    options: [Rust, Python, TypeScript]
    default: Rust
  diff:
    type: multiline
    label: Diff
    description: Output of git diff.
---
You are a senior {{language}} engineer. Review this change.

<diff>
{{diff}}
</diff>

Report correctness issues first, then security, then readability.
Cite file:line for every finding. Today is {{date}}.
```

Front matter keys (all optional):

| Key | Type | Meaning |
|---|---|---|
| `id` | ULID string | Stable identity across renames and devices. The app writes it on first save or before first push. While absent, a local id is the SHA-256 of the relative path. That id never leaves the device. When the ULID is written, the state key and `history/<id>/` are migrated in the same step. |
| `title` | string | Shown in lists. Default: filename without extension. |
| `description` | string | One line, shown in the picker preview. |
| `tags` | list of strings | Cross-cutting grouping and `#tag` search. |
| `favorite` | bool | Boosts ranking. This is a per-user preference: for group prompts it is stored locally, not in the shared file (§9.5). |
| `private` | bool | Never sent to an LLM (§12). |
| `fields` | map name → field | Placeholder declarations (§5.3). |
| `format` | integer | File format version. Absent = 1. A file with a higher `format` than the app supports loads read-only with a banner and cannot be delivered. Migrations run forward-only and snapshot the old file into history first. |
| anything else | any | Preserved on save (e.g. Prompty or Dotprompt `model:`). |

Save semantics:

- The app writes front matter in a canonical key order and keeps unknown
  keys. The order is `id, title, description, tags, favorite, private,
  fields, format`, then preserved keys in their original order. The writer
  emits an ordered Yams `Node.mapping`, not an encoder with sorted keys, and a
  round-trip test pins the order.
- ULIDs come from one generator in Core (`Domain/ULID.swift`), used by the
  file writer, the sync client, and the server. The body is written byte-for-byte as edited, including indentation
  and trailing newlines (Copywraith #159 lesson).
- YAML comments inside front matter are not preserved. The README says so.
- Writes are atomic: temp file in the same directory, then rename.
- **Scalar subset.** Front matter is restricted to what both parsers read
  identically: Yams reads YAML 1.1, and Android's snakeyaml-engine reads
  strict YAML 1.2.
  - Booleans are exactly `true` or `false`.
  - The validator rejects YAML 1.1 spellings (`y`, `yes`, `n`, `no`, `on`,
    `off`), octal-style integers (`010`), anchors, and `<<` merge keys.
  - Canonical writing emits `true` and `false` only.

### 5.3 Placeholder grammar

```ebnf
template    = { literal | escape | placeholder } ;
escape      = "\{{" ;                                  (* renders a literal "{{" *)
placeholder = "{{" , ws , name , ws , "}}" ;
name        = ( letter | "_" ) , { letter | digit | "_" | "-" } ;
ws          = { " " | "\t" } ;
literal     = any text that is not an escape or a placeholder ;
```

- **Non-matching braces.** Any `{{…}}` that does not match `placeholder`
  (`{{#if x}}`, `{{ a b }}`) is literal text, and the editor flags it as a
  warning. Pasted Handlebars and Jinja prompts survive untouched.
- **Single-pass rendering.** Values are inserted raw: no HTML escaping and
  no re-scan. A value containing `{{x}}` stays literal.
- **Reuse.** The same name used twice is one field, filled once.
- **Ordering.** Fields appear in order of first use in the body. Declared
  fields that never appear are a validation warning.
- **Names are case-sensitive.** `{{CUSTOMER_NAME}}` (Anthropic Console
  style) is valid.
- **Implicit fields.** An undeclared `{{name}}` is an implicit field:
  `type: text`, `label: name`, `optional: false`, `remember: true`. The
  editor marks it "implicit". It is never a validation issue.

Field declaration (`fields.<name>`):

| Key | Values | Default |
|---|---|---|
| `type` | `text` · `multiline` · `choice` | `text` |
| `label` | string | the name |
| `description` | string, shown under the control | none |
| `default` | string (for `choice`: one option value) | empty |
| `options` | `choice` only: a list of strings, or `{label, value}` maps (a bare string means label = value) | required for `choice` |
| `optional` | bool. An empty optional field renders as empty. | `false`: Deliver stays disabled until the field is filled |
| `remember` | bool. Prefill with the last value used. | `true` |

Built-in values are reserved names with no form control. They resolve when
the form opens (for repeat, at invoke time) and appear in the read-only
preview:

| Name | Value |
|---|---|
| `{{clipboard}}` | Clipboard text when the panel opened. It is read only for prompts that use it, because newer macOS versions may show a paste-privacy prompt on programmatic reads; verify on hardware in M1a. |
| `{{date}}` | Local date, ISO `YYYY-MM-DD` |
| `{{time}}` | Local time `HH:MM` |

Reserved for later, rejected as field names now: `selection`, `cursor`,
`datetime`, `uuid`. These deferred features all keep the grammar
forward-compatible; none of them invalidates a v1 file:

- checkbox fields with on/off text
- `{{#name}}…{{/name}}` optional sections
- `{{> other-prompt}}` includes
- `{{name | lower}}` modifiers
- a `file` field type

Validation produces issue strings and never drops a file silently. The same
validator runs on the desktop, on LLM output, and on the server. It reports:

- an unknown `type`
- a `choice` without options, or with a default that is not an option
- a reserved name declared as a field
- an unbalanced `{{`
- declared-but-unused fields
- invalid YAML: the file is listed with an error badge, not hidden

### 5.4 Index, search, ranking

- **Index.** An in-memory index of every prompt (title, tags, folder,
  description, body), rebuilt on watcher events. A few thousand files load in
  well under a second.
- **Fuzzy matching.** Implemented in Core: subsequence match with bonuses for
  word starts and consecutive runs. Weights: title > tags/folder >
  description > body. A `#tag` token filters.
- **Ranking.** `score = match × (1 + frecency)`, where
  `frecency = Σ 2^(−age_days / 14)` over recorded uses, capped at
  `FRECENCY_CAP = 32`. Favourites get `FAVORITE_BOOST = 1.5`. An empty query
  sorts by frecency, then favourites, then title. Unit-tested with an
  injected clock.

### 5.5 History, external edits, import

- **History.** Before every save the app copies the current file into
  history. Restore is a new save, so history only grows. Every LLM-accepted
  change records provenance in the history entry: model, action, and
  instruction.
- **External edits.** The watcher reloads changed files, debounced by
  `WATCH_DEBOUNCE_MS = 500`. A delete followed by a create within the window
  counts as a modification (editors save that way). Suppose the open
  editor has unsaved changes and the file changes on disk. Saving then
  offers three choices: keep mine (overwrite), take theirs, or save mine as
  a copy. The app never merges silently.
- **Import.** Drop `.md`, `.prompt` (Dotprompt), or `.prompty` files, or a
  folder, onto the library window. Dotprompt `input.schema` and Prompty
  `inputs` map to `fields` where the mapping is lossless. Everything else
  stays as preserved keys. A report lists what was mapped.

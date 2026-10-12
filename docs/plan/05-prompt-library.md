## 5. Prompt library

### 5.1 Where things live

| What | Where | Synced? |
|---|---|---|
| Prompts | Library folder, default `~/Documents/MonkeysPaw/` (Linux: XDG documents dir). Any folder can be chosen. | By the sync server (§9) or by the user's git / Syncthing / iCloud |
| Settings | macOS `~/Library/Application Support/ch.lkmc.MonkeysPaw/settings.json`; Linux `$XDG_CONFIG_HOME/monkeyspaw/settings.json`. Version 1 schema and fail-closed loading below. Every app-owned JSON file carries a `version` field and migrates forward on load. | no |
| History | `<data>/history/<prompt-id>/<UTC-timestamp>-<sequence>.md` (`Limits.historyCapPerPrompt = 50`). Synced prompts also have server revisions. | no |
| Logs | `<data>/logs/monkeyspaw.log` (§12) | no |
| Usage (ranking, last delivery) | `<data>/usage/<identity-key>` (versioned JSON) | no |
| Remembered values | `<data>/values.json`, `PRIVATE_FILE_MODE = 0600` | no |
| Sync state | `<data>/sync/state.json` (§9.2) | no |
| Portal restore token | `<data>/portal.json` (§6.3) | no |
| API keys, device token | OS secret store | no |

`<data>` = macOS `~/Library/Application Support/ch.lkmc.MonkeysPaw/`, Linux
`$XDG_DATA_HOME/monkeyspaw/`. Under flatpak both resolve inside
`~/.var/app/ch.lkmc.monkeyspaw/`.

`SettingsStore` uses a dedicated config-root `FileStore` and sorted-key JSON:
`{"firstRun":{"libraryFolderCompleted":false,"seedsOffered":false,"setupPresented":false},"libraryFolderPath":null,"version":1}`.
`libraryFolderPath` is an absolute POSIX path or null for the platform default,
which composition computes. Paths are preserved verbatim; control characters
are rejected. The document holds only this choice and first-run progress, never
secrets, prompt content or field values. Unknown keys at the root and inside
`firstRun` are retained internally and preserved on rewrite, without becoming
part of the settings API.

Missing settings use defaults. Older versions pass through an ordered chain of
single-version migrations on load, then persist as the current version on the
next successful change; version 1 is the first shipped schema. Future versions,
corrupt documents, unsupported older versions and read failures report typed
`SettingsError` values, use defaults in memory and make the store read-only for
its lifetime. They are never overwritten; recovery requires restoring readable
supported settings and recreating the store. Each update rereads the file to
detect a newer or corrupt document introduced during the session. One NSLock
serializes reads and changes; composition shares one store per config root.
Atomic `FileStore.write` must succeed before the in-memory value changes. Write
failure is retryable and retains both the previous file and in-memory value.
Paths, contents and underlying error bodies are never logged.

Linux composition reads this choice before building its library graph. Folder
switching refuses an in-flight delivery and otherwise dismisses the picker
first. A chosen folder must be an existing readable directory, with no symlink
at the selected root; only the platform default may be created, and it may be
a symlink to a directory, resolved as before. Validation
failure leaves the graph and settings intact. A valid switch replaces only the
library service, index, watcher and picker, keeping the native panel and shared
app-data stores. It retires old callbacks and drops the old picker's session
drafts. The new picker hook is installed before monitoring starts and the index
rebuilds. Startup failure leaves the new graph unavailable, as at launch, and
does not persist the choice. After successful startup, settings are saved; a
save failure keeps the new graph for the session and surfaces `SettingsModel`'s
error. The next launch uses the last successfully persisted choice. This avoids
a second view rebind and watcher restart after a settings write failure.

`ValuesStore` stores version 1 sorted-key JSON in the single `values.json`:
`{"values":{<identity-key>:{<field-name>:<value>}},"version":1}`. Keys use the
same path-hash/ULID identity as usage/history; field names and values are
strings, including empty strings. Every replacement uses `FileStore.writePrivate`
with `PRIVATE_FILE_MODE = 0600` on the temporary file before rename.
`record(identity:values:)` merges supplied fields, last-write-wins per field,
preserving all other fields and identities. An empty supplied map is a no-op.
Missing file or identity reads as an empty map. Corrupt, unsupported or
over-cap state fails with `LibraryError.operationFailed`, without automatic
reset, truncation or pruning; the explicit "Forget all values" recovery action
replaces that state with an empty version-1 document (§5.4). Encoding above
`Limits.valuesFileCapBytes = 1,048,576`
bytes fails before writing. Typed FileStore errors remain typed; other errors
are sanitized, and values are never logged. One NSLock serializes each
read/merge/private-write cycle; composition shares one instance per data root.
Key migration moves the whole field map inside this file, refuses an occupied
destination with `keyedStateConflict`, and supports reversal on library failure.

Library rules:

- Every `*.md` file under the library is a prompt. Subfolders are folders.
- Dot-directories and `_`-prefixed files or directories are ignored, so
  `.git/` and `_drafts/` are skipped. Only exact-case root `README.md` is
  ignored; a nested `README.md` is a prompt. Dot-files remain eligible.
  The `.md` suffix is case-sensitive. Entries sort by relative path UTF-8
  bytes, independent of filesystem enumeration order.
- A file without front matter is a valid prompt: its title is the filename
  and its body is the whole file.
- With sync enabled, the top-level folders `Groups/` and `Conflicts/` are
  reserved (§9.1). Until sync exists they are ordinary folders, including
  in M2b's store APIs.

M2b library paths are relative POSIX paths within the selected root. Reject
absolute/empty paths, empty segments, `.`/`..` segments, backslashes, NUL or
control characters, and paths exceeding `Limits.maxPathBytes` (1,024 UTF-8
bytes). Mutation targets must also obey the prompt/ignored-path rules.
Reads and writes reject symlinked components, and enumeration never follows
symlinks. M5's NFC, segment-length, case-folded clash and reserved-scope
policies are deferred; this slice does not silently normalize local paths.
Relative paths compare, hash and sort as exact UTF-8 bytes end to end,
including native snapshots, watcher coalescing/change sets and picker selection.
Canonically equivalent spellings can identify distinct local files.

`FileStore.create(_:at:)` opens an unguessable same-directory temporary name
with `O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW` and mode `0666`.
The kernel applies the current umask, matching ordinary-write permissions
without reading or changing the process-wide mask. Only temporary-name
`EEXIST` collisions retry, bounded by `Limits.exclusiveCreateAttemptCap = 64`;
other open failures or exhaustion return `FileStoreError.ioFailure`.
All bytes are written through the returned descriptor, handling partial writes
and interrupted calls, then `fsync` completes before `link(2)` publishes the
destination. The temporary name and descriptor are cleaned up on success or
failure. An occupied destination of any kind returns
`FileStoreError.alreadyExists` without changing it; the destination is never
followed, including a dangling symlink. Root and parent checks match `write`,
rejecting symlinked ancestors. This is an atomic exclusive create, not a
reservation probe. The directory entry is not synced, so crash durability is
not promised; existing check-then-act root safety remains unchanged (§4.6).
Filesystems without hard-link support return `ioFailure`; no replacement
fallback is attempted.

`LibraryService.entries()` includes malformed YAML, oversized sources and
non-UTF-8 files as `LibraryEntry` values with error issues. The byte-oriented
`PromptCodec.parseFile(_:filename:)` reports `source.too_large` or
`source.invalid_utf8` without parsing those bytes or fabricating replacement
characters. `PromptCodec.parse(_:filename:)` accepts text only. For invalid
byte input, source and body are empty in the document; the original bytes
remain on disk and can still be snapshotted when a corrected valid draft
replaces them.

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

Path-hash identity does not include the library root: prompts without an `id`
at the same relative path in different libraries share remembered values and
usage history in app data. Assigned ULIDs retain their own identity across
library switches; switching does not rewrite either form of identity.

Save semantics:

- The app writes front matter in a canonical key order and keeps unknown
  keys. The order is `id, title, description, tags, favorite, private,
  fields, format`, then preserved keys in their original order. The writer
  emits an ordered Yams `Node.mapping`, not an encoder with sorted keys, and a
  round-trip test pins the order.
- ULIDs come from one generator in Core (`Domain/ULID.swift`), used by
  `LibraryService`, the later sync client, and the server. The body is written byte-for-byte as edited, including indentation
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
  - These are validator errors, not warnings, so a push fails with `422`
    (§8.4).
  - The subset applies to every front-matter scalar, including preserved
    unknown keys.
  - A boolean key holding a rejected spelling fails closed: `private` reads
    as `true`, and `optional` as `false`.

M2a content API clarifications:

- Front matter starts on the first line with exactly `---`, followed by
  LF or CRLF, and ends at the next line containing exactly `---` (EOF is
  allowed after the closing delimiter). Its body starts after that line's
  terminator. Missing closure and malformed YAML remain invalid documents
  with their original source. An empty/comment-only header is an empty map.
- `Limits.maxPromptBytes` (256 KiB) caps the entire UTF-8 source, before
  YAML or template parsing. Diagnostics carry stable codes, severity and
  locations, without copying source or parser error bodies into messages.
  Positive format integers have no machine-word ceiling; even an unusually
  large future version stays explicitly incompatible and read-only.
  Exact radix conversion combines groups of 8 hexadecimal or 10 octal digits
  in balanced batches of 9-digit decimal chunks. Large products use Karatsuba
  multiplication; chunk products and carries fit checked UInt64 arithmetic.
  This avoids repeated scans of a growing decimal value and retains
  arbitrary-size typed key comparison and exact future format versions
  under the source limit.
- The reviewed Yams 6.2.2 backport is pinned by immutable revision (§3, D3).
  Core opts into `Parser.DuplicateKeyPolicy.deferAnchoredKeys`, which defers
  every comparison involving a key subtree containing an anchor or alias.
  Core retains the parser while checking parsed anchor metadata and rejects
  anchored nodes before descending. No anchored tree reaches later key
  comparison, construction or canonical writing; the parser policy alone
  does not bound those operations. Ordinary duplicate keys still abort YAML
  composition with the existing duplicate error and private recovery state.
  Comparisons involving anchored keys instead reach Core's anchor errors,
  retaining other decoded metadata and exact source/body. Such documents
  remain invalid and cannot render or be written.
- The scalar subset is the intersection of Yams 6.2.2's resolver and the
  YAML 1.2 Core schema, with the lowercase boolean rule above. It also
  rejects binary/sexagesimal numbers, numeric underscores, timestamps,
  legacy `=` value keys, and other scalars whose resolved types differ.
  Plain leading-zero integers (including `08`/`09`) are invalid. Core
  scalar/collection tags are supported; tags without a shared Core-schema
  meaning are errors. Quoted/block strings and explicitly tagged `!!str`
  literals retain their string meaning, including `"on"`, `"010"`, `"<<"`
  and `"="`. Merge keys are identified by tag, not by quoted text. Mapping
  keys must be unique by their typed value, including nested unknown maps.
  These rules follow the [YAML 1.2 Core schema](https://yaml.org/spec/1.2.2/#103-core-schema)
  and its [changes from 1.1](https://yaml.org/spec/1.2.2/ext/changes/).
- A content-only canonical writer retains which optional keys were present,
  orders known keys as above, and keeps declaration, option and unknown-map
  order. It returns text, rejects errors/future versions and never assigns
  an id. A plain file stays plain. Atomic writes, identity assignment and
  migration remain store lifecycle work. Supplied ULIDs are case-insensitive
  using the standard alphabet, 26 characters and 128-bit overflow bound.

M2b save and identity API:

- `save(_:at:expectedStamp:)` calls `PromptCodec.write` and atomically
  replaces the file, creating parents for new files. Error documents and
  future formats are refused; an existing future-format file is protected
  even if the submitted draft uses an older format.
- `create(_:at:)` performs the same validation, canonical writing, first-save
  ULID assignment and reversible keyed-state migration, using
  `FileStore.create` instead of replacement. It never reads or snapshots an
  occupied destination. A failed publication rolls migrations back; an
  occupied library path returns `LibraryError.destinationOccupied`, distinct
  from `FileStoreError.alreadyExists` during keyed-state migration, so seeding
  skips only prompt-publication collisions. New files have no
  prior bytes to snapshot. Seeding is a real first save under §5.2: the
  catalog has no ids, while each installed prompt gets a fresh ULID and
  retains its exact body bytes. Exclusive creates and seeded prompts use
  ordinary-write permissions (`0666 & ~umask`), applied by the kernel without
  reading or changing the process-wide mask. Bytes are written through the
  temporary descriptor and synced before publication, as described in §5.1;
  without a directory sync, this does not promise crash durability.
- `PromptIdentity.local(hash)` is the lowercase pure-Swift SHA-256 of the
  exact relative path bytes and stays on this device. On first save,
  `LibraryService` uses injected `WallClock` and `EntropySource` ports to assign
  a ULID. Its internal `PromptCodec.assigningIdentity(_:to:)` seam adds
  only an absent id, then reparses canonical text. A plain body gains
  `---\nid: <ULID>\n---\n` without changing any body bytes. The public
  content-only writer continues to assign nothing.
- `assignIdentity(to:)` is the explicit pre-push operation. Existing ids
  remain stable on save/restore/move, including when an edited draft omits
  the id. A draft trying to replace an existing id fails with
  `LibraryError.identityMismatch`. Reassigning an assigned file performs
  no write and creates no revision.
- `PromptKeyedStore.migrateKey(from:to:)` moves keyed state before the
  library write. History, usage and M2e's remembered-values store participate
  now. Usage and values are injected through the service initializer.
  Unassigned moves migrate
  path-hash to path-hash; assignment migrates path-hash to ULID. Assigned
  moves change no key. Occupied destination keys fail with
  `keyedStateConflict`, preserving both states rather than merging or
  overwriting. A failed file write reverses completed migrations and
  removes its staged snapshot. Recovery failure is explicit as
  `recoveryRequired`; callers reload before retrying. There is no durable
  cross-root crash transaction in this slice.
- `move(from:to:)` never replaces another file. `delete(at:)` removes only
  the library file and retains history, so restore can resurrect it.

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

The portable grammar uses ASCII letters and digits for names; Unicode
literal text and inserted values are preserved. Escapes consume exactly
`\{{`: in `\\{{x}}`, the first backslash is literal and the second escapes
the opener. There is no nesting: an opener consumes through the next `}}`;
nested/invalid closed content is one literal span with a warning. An opener
with no closing `}}` is an error. Only space and tab surround a name;
newlines and other whitespace make a closed construct literal.

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
the form opens, at use for a fieldless prompt, or at invoke time for repeat,
and appear in the read-only preview:

| Name | Value |
|---|---|
| `{{clipboard}}` | Clipboard text at form open, or at use for a fieldless prompt. It is read only for prompts that use it, because newer macOS versions may show a paste-privacy prompt on programmatic reads; verify on hardware. |
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

M2a resolves ordinary implicit fields with the same defaults as declarations.
Builtins have no controls and cannot be declared or overridden through field
values. Deferred reserved names are errors both when declared and when used
as implicit placeholders. Unused declarations still warn. A missing choice
default means no prefill; an explicitly supplied default must match an option
value. Choice options must be a nonempty list of strings or maps containing
string `label` and `value`; options on other types are errors. Unknown nested
metadata is preserved, including extra declaration/option keys.

Rendering uses a supplied value when present, otherwise the declared default.
An explicit empty value never falls back to a default. Required means nonempty
(values are not trimmed); optional empty choices render empty, and nonempty
choice values must match an option. Warnings alone never block rendering or
content validation. Date/time/clipboard snapshots are supplied by the
Fill service (M2e); these pure APIs never read the clock, time zone or clipboard.

`FillService` samples its injected `WallClock` and local-time-zone source once
at form open, or at use for a fieldless prompt, formats Gregorian date/time
with `en_US_POSIX`, and requests clipboard text only when `.clipboard` appears
in the template. `Clipboard.readText` completes exactly once; nil, empty or
failed clipboard reads resolve to an empty string, so failure never leaves
delivery disabled. The snapshot always completes. GTK reads asynchronously
and returns on the creating GTK context; macOS reads inline on the AppKit UI
thread. A form is immediately interactive; delivery and copy stay disabled until
the snapshot returns through `MainThread`. While waiting, preview either renders
text independent of builtins or names the missing builtin; it updates on snapshot
arrival without resetting typed fields. Builtins never refresh on ordinary field edits.

Forms use `effectiveFields` in body first-use order. For remember-fields,
remembered text wins over a declared default, even when empty; `remember: false`
uses the default. A failed remembered-state read exposes
`rememberedValuesUnavailable` and uses defaults without resetting state.
`preview` returns rendered text or a typed blocking reason (validation issues,
read-only format, missing required value, invalid choice, missing builtin),
without throwing during editing; `render` preserves `PromptRenderer` errors.
Delivered remember-fields are stored verbatim, including empty strings, so the
user's last choice repeats. Non-remembered fields are not recorded.

### 5.4 Index, search, ranking

- **Index.** Core's `PromptIndex` caches every prompt's title, tags, folder,
  description and body in memory, including invalid entries and their issues
  as returned by `LibraryService.entries()`. `rebuild()` replaces the whole
  index, sourcing cached usage events from `UsageStore.useEvents(for:)` for
  each identity. `apply(_:)` drops deleted paths and reloads created/modified
  paths through `load(at:)` and their identities' usage events; it drops
  vanished files, retrying once for a stamp/read conflict to detect deletion
  during a load. Other read/conflict failures, including corrupt usage state,
  are explicit and retain the last completed index and its loaded events.
  A rebuild or batch is published only when all reads succeed; callers must
  surface failures, including an initial rebuild that leaves the index empty.
  `setOnChange` has one owner. Debug builds assert that the previous hook is
  cleared before installing a nonnil replacement; clearing with nil is always
  allowed. Each successful rebuild/apply reads the latest installed callback
  under the lock when its publish finishes, then invokes that captured callback
  once on the caller's thread after unlocking. This is latest-writer-wins at
  publish time. Failures never notify. Models marshal it through `MainThread`.
  `recordUse` deliberately stays quiet even though it changes cached ranking;
  the delivery path refreshes its own results after recording usage.
  Path keys and tie-breaks use exact UTF-8 bytes. A few thousand files load
  in well under a second; M2d measures
  a 3,000-entry in-memory FileStore rebuild; its three-second smoke bound
  gives slower CI hosts headroom, and the measured time is recorded separately.
  Disk performance still depends on the selected filesystem. Watcher-to-index
  composition is proven with fakes; production app wiring is a later platform-UI
  slice, outside M2e's Core presentation models.
- **Fuzzy matching.** All whitespace-separated ordinary terms must be
  subsequences, possibly in different fields. Fields and terms use Unicode
  case folding with the fixed `en_US_POSIX` locale, then NFC; accents remain
  significant. Lengths and positions count normalized Unicode scalars.
  For a term of length `m` in a field of length `n`, maximize
  `raw = m + 2W + C` over alignments. `W` counts matched word starts (position
  zero or following a non-alphanumeric scalar); `C` counts consecutive
  matched pairs. The normalized score is
  `raw / (4m - 1) × (1 + m/n) / 2`, in `(0, 1]`. `4m − 1` is a loose upper
  bound: for alphanumeric terms with `m ≥ 2`, the attainable maximum is
  `max(3m, 2m + 1)`, because word-start and consecutive bonuses cannot peak
  together. Exact contiguous matches of such terms score below 1 by design;
  ordering uses relative scores. The length factor favours short fields.
  Dynamic programming chooses the best alignment rather than the first
  subsequence.
  Field weights are title **4**, each tag/folder **2**, description **1**,
  body **0.5**. Each term takes its highest weighted field score; `match` is
  the average across ordinary terms. Equal field scores prefer the declared
  field order (title, tags, folder, description, body). A `#tag` token is an
  exact tag filter after the same normalization, with no numeric bonus;
  multiple filters all must match, and a bare `#` matches nothing. Queries
  containing only matching filters use `match = 1`.
- **Ranking.** `score = match × (1 + frecency)`, where
  `frecency = Σ 2^(−age_days / Limits.frecencyHalfLifeDays)` over retained
  uses, capped at `Limits.frecencyCap = 32`. The half-life is **14** elapsed
  24-hour days, independent of calendars/DST. Future uses have age zero
  after a backwards clock adjustment. Favourites multiply nonempty-query
  scores by `Limits.favoriteBoost = 1.5`. Empty/whitespace-only queries sort
  by frecency descending, then favourites first, then title; their result
  score is frecency. Other queries sort by score descending. All ties sort
  by title, then relative path, using ascending UTF-8 byte order. Search
  samples the injected `WallClock` once, so cached uses decay on every query.
- **Usage.** `UsageStore` reads/writes the app-data `FileStore` at
  `usage/<identity-key>` (no extension), using the same path-hash/ULID keys
  as history. This is the initial format; `usage.json` never shipped, so no
  migration is needed. Version 1 is deterministic sorted-key JSON:
  `{"events":[Unix seconds as doubles],"version":1}`. Timestamps must be
  finite; events retain recording order. `recordUse(identity:at:)` uses an
  explicit timestamp or the injected `WallClock`, appends, atomically
  replaces the file, and retains the last `Limits.usageEventCap = 1,024`
  events. The service lock serializes each read/append/replace cycle within
  one `UsageStore` instance, preventing lost updates there. Composition must
  share one instance per app-data root, the same single-instance rule as
  `LibraryService`. At one use/day, discarded events are over 73 half-lives old,
  contributing less than `1e-22` each; dense recent bursts already saturate
  the cap of 32. This is a bounded-history approximation, not age-based
  pruning or a guarantee about every possible usage distribution.
  Missing state reads as no events. Corrupt/unsupported state fails with
  `LibraryError.operationFailed`, never resetting recorded uses. FileStore
  errors remain typed; no OS error text is exposed or logged.
  `PromptKeyedStore` migration moves the entire file unchanged and refuses
  occupied destinations with `keyedStateConflict`, permitting the existing
  assignment/move rollback machinery to reverse it. `PromptIndex.recordUse`
  updates its cached events only after persistence succeeds. Neither service
  owns a driver or has a production caller in M2d.

Library switches keep the same app-data values and usage stores. Since
path-hash keys omit the root, equal relative paths without assigned ids share
remembered values and ranking history across libraries; ULID keys remain tied
to their assigned prompts (§5.2).

M2e adds `PickerModel`/`FillModel` with UI-thread intents, immutable view state
and single-owner `onChange` republishing, without platform views or app wiring.
Picker open keeps the query, refreshes from the index and selects the top row.
Index refresh preserves the selected path when it survives. Invalid/read-only
rows stay visible, show issues in preview and cannot deliver. Valid previews
render defaults when possible, otherwise show the template body until use;
mere selection never reads clipboard/remembered text. No-match state carries
the query and create/write/open-folder labels. Edit/library intents are recorded
as data for later wiring; folder availability is a composition-supplied input.
Date/time and any used clipboard builtin share one snapshot at form open or
at use for a fieldless prompt. The clipboard port completes exactly once;
failure resolves to empty text and cannot leave delivery disabled.

Session drafts are keyed by identity and updated on every field edit. Esc from
a form goes back to picker; cancel closes the panel. Esc from picker or a
completed delivery closes it; delivery in progress cannot be dismissed.
Picker dismissal uses the existing `DeliveryService.dismiss` queue, which hides
through its injected `PanelWindow`
and retains §4.6's guarded focus restoration. This prevents a pending show from
reopening a closed picker. Blur hiding belongs to the platform
timer, while a later open retains the same values. Drafts survive closing and
reopening until delivery, an explicit forget action or model release at quit;
delivery clears only that identity's draft. Closed forms and canceled
fieldless snapshot requests ignore late callbacks. Tab/Shift-Tab follow field
order and wrap within the fields.
The picker carries terminal/copy mode into the form's `preferredMode`; explicit
form delivery accepts standard paste, terminal paste or copy-only.

Learning happens after DeliveryService completes, including requested copy and
paste fallback: remember-fields first, then `PromptIndex.recordUse`. The writes
are independent: a failed remember write still attempts `recordUse`, and a
failed usage write retains any successful remember write. Failures do not
cancel the user's delivery, but expose sanitized `rememberedValuesNotSaved` or
`usageNotSaved` warnings. Successful usage persistence updates cached ranking
before the picker refreshes. Models retain no logs of prompt text or values.
Remembered-state reads and learning writes remain synchronous on the model's
UI thread in this Core slice, matching the requested form/store API. The 1 MiB
cap bounds values work; a slow filesystem may still delay UI callbacks. Worker
plumbing and production composition are outside M2e. Merge also retains fields
removed or renamed in a document; `remember: false` prevents prefill/new records
without deleting previous text. All retained fields, including these stale
fields, count against `Limits.valuesFileCapBytes`. No automatic pruning or
reset occurs. "Forget values" calls `ValuesStore.remove(identity:)` through
`FillService.forgetValues(for:)`, removing that prompt's entire map, including
stale fields, and discarding its session draft. Other identities and their
fields stay intact; an absent identity is a no-op. This action reads and
validates the existing document and fails closed on corrupt, unsupported or
over-cap state.

"Forget all values" calls `ValuesStore.removeAll()` through
`FillService.forgetAllValues()`, atomically replacing `values.json` with
`{"values":{},"version":1}` via `writePrivate` at mode 0600 and clearing all
session drafts. Rewriting keeps the versioned format and the existing private
atomic-write contract, including when the file was missing. This is the
documented reset for corrupt, unsupported, over-cap or unreadable regular
files: it deliberately skips reading the previous contents. Rooted FileStore
checks still reject symlinks, nonregular files and an unsafe data root. To
inspect rejected state first, rename the file aside before using the action.
Write failures remain typed and preserve the previous file.

Both intents live on `PickerModel`, ready for the later picker and Settings
controls. After persistence succeeds, a matching open fill form stays open
and resets every field, including fields with `remember: false`, to its
declared default in the held document. Its preview updates with the same builtin
snapshot, field focus and delivery mode; no clipboard write, delivery or usage
learning occurs.
Closing that reset form does not create a new draft until you edit a field,
so the next form open uses current defaults even if the prompt changed.
Failures expose a sanitized persistence error and keep drafts and open fields;
success clears the error and persistence
warnings. Forgetting is rejected while delivery is in progress, so its pending
learning cannot restore the values just cleared. Global forgetting also works
while the panel is closed. A successful forget cancels a fieldless use still
waiting for its builtin snapshot; an open form keeps its pending snapshot.

`ValuesStore.migrateKey(from:to:)` moves the whole field map atomically under
the store lock. Each store operation holds that lock independently;
`LibraryService`'s own lock serializes its migration, library write and rollback
sequence. Reversal moves the current destination map wholesale back to the
source, so records written to the destination between migration and reversal
return with it without loss. A new source-key record in that interval makes
reversal throw `keyedStateConflict`, surfaced by `LibraryService` as
`LibraryError.recoveryRequired`.

### 5.5 History, external edits, import

- **History.** Before every save overwriting an existing file, copy its
  exact previous bytes to `<data>/history/<prompt-id>/`. A new file has
  nothing to snapshot. Unassigned path-hash history keys are transient within
  an operation: assignment migrates them to the ULID key; they are never
  silently inherited across unrelated saves. UTC filenames use
  `yyyyMMdd'T'HHmmss.SSS'Z'-NNNNNN.md`; the six-digit sequence increments
  for collisions within the same millisecond, up to
  `Limits.historySequenceMax` (999,999), then fails explicitly. For example:
  `20261010T130700.123Z-000000.md`. `history(for:)` returns revisions
  newest-first with their timestamps. After a successful write, prune
  oldest-first to `Limits.historyCapPerPrompt` (50); unrelated app-data
  files are untouched. A pruning failure reports `historyMaintenanceFailed`
  after the library write has committed; reload before retrying.
  `restore(_:at:expectedStamp:)` preserves the revision's body bytes, writes
  canonical front matter, and re-injects the current assigned id from the
  history key for pre-id snapshots. Local revisions may restore only to
  their original path; assigned revisions may restore to a different path
  only when no other live entry carries that id. Restore snapshots the
  current file and grows history up to the cap. Invalid/non-UTF-8 snapshots
  are forensic-only: restore refuses them with `PromptWriteError.invalidPrompt`.
  Future formats are refused with `PromptWriteError.unsupportedFormat`.
  LLM provenance belongs to M4 and is absent in M2b.
- **External edits.** M2c's `LibraryWatcher` emits labeled
  `LibraryChangeSet {created, modified, deleted}` after
  `Limits.watchDebounce` (500 ms) of prompt-path quiet. Every prompt-path
  raw event restarts this window; events for non-prompt paths are dropped
  before scheduling. Stale one-shot scheduler callbacks do nothing.
  Repeated events on one prompt path deduplicate. A delete followed by a
  create within the window counts as one modification (editors save that
  way); a create followed by its own
  delete produces no event; delete/create/delete produces a deletion.
  Sets contain only prompt paths under §5.2's policy: exact-case `.md`,
  including dot-files, excluding `_`-prefixed components, dot-directory
  components, and root `README.md`. An empty set is not emitted.
  The raw watcher reports root unavailability on the same ordered callback
  as file events: missing, replaced by a non-directory, or not enumerable.
  It reports once per transition and retains the last good file baseline,
  without deletions caused solely by root loss. `LibraryWatcher` flushes
  earlier pending changes before forwarding health, without debounce.
  Composition stops monitoring, shows the existing unavailable banner and
  keeps the cached index; restoration requires a restart (§11.5).
  A driver started on a missing root still attaches through existing ancestors;
  it emits no initial baseline. Start/stop are explicit and idempotent.
  Suppose the open editor has unsaved changes and the file changes on disk. Saving then
  offers three choices: keep mine (overwrite), take theirs, or save mine as
  a copy. The app never merges silently.
  M2b implements the store contract beneath that future dialog:
  `expectedStamp` compares the caller's load/list stamp with the file now,
  including deletion/recreation, and throws `LibraryError.conflict` on
  mismatch. It checks again after staging history and before replacement.
  Re-read and retry with the new stamp to keep yours; reload to take theirs.
  Omitting the stamp explicitly permits overwriting the version read by the
  save operation. This is optimistic checking, not an OS-level atomic
  compare-and-swap with arbitrary external writers.
  `availablePath(for:)` probes `Name.md`, `Name 2.md`, `Name 3.md`, etc.,
  bounded by `Limits.libraryCopyCandidateCap` (1,000 alternates from
  `Name 2.md` through `Name 1001.md`; `Name.md` itself is uncounted).
  Save a new draft without id at that path for a distinct copy identity.
  The helper does not reserve the name; use `create(_:at:)` when a new file
  must never replace a destination that appeared after the probe.
- **Import.** Drop `.md`, `.prompt` (Dotprompt), or `.prompty` files, or a
  folder, onto the library window. Dotprompt `input.schema` and Prompty
  `inputs` map to `fields` where the mapping is lossless. Everything else
  stays as preserved keys. A report lists what was mapped.

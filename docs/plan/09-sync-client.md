## 9. Sync client

### 9.1 Local layout

```
<library>/                          personal scope: your private prompts, any subfolders
<library>/Groups/<group folder>/    one folder per group you belong to (managed by sync)
<library>/Conflicts/                conflict copies and rescued files; private scope
```

- **Reserved folders.** With sync on, `Groups/` and `Conflicts/` at the top
  level are reserved. If either already exists when sync is enabled, setup
  asks to rename it.
- **Group folders.**
  - Wire scope paths remain capped at 1,024 UTF-8 bytes. Joined library
    paths use the compatible 1,287-byte rooted cap (1,024 + 7 + 255 + 1), including
    `Groups/<255-byte folder>/` (§5.1, §20 E37). Private conflict/rescue
    destinations still fit the 1,024-byte wire cap; their planners safely
    shorten/flatten long source names and retain source mappings.
  - A folder is keyed by `group_id` in sync state. Its name is the group
    name, sanitized: path-validation rules applied, then de-duplicated
    with numbered suffixes starting at ` (2)`. For each candidate, reserve
    its suffix's actual UTF-8 bytes, including multi-digit counters, before
    safely shortening the sanitized stem so the complete folder name stays
    within 255 bytes.
  - A group rename renames the folder.
  - A folder under `Groups/` that maps to no current group, or a file
    sitting loose directly under `Groups/`, is never pushed. It is rescued
    (§9.3, step 1) and removed.
    If it carried a recorded identity, retire that cache entry and request a
    fresh snapshot of its original scope with the API's reset cursor `0`.
    Internal rescue is never inferred as a user deletion of the server head.
    A delta collected before that reset cannot acknowledge it; recollect the
    scope before completing the pass. Keeping the scope key in the reset
    request also lets the server report a concurrent membership removal.
- **Viewer groups are read-only.** Files are written with
  `READONLY_FILE_MODE = 0444` and the editor opens them read-only. When a
  role changes to or from `viewer`, existing files are re-moded and open
  editors switch.
- **Moving a file is a scope change.** Moving a file into, out of, or
  between group folders (in the app or a file manager) requests a `/move`.

### 9.2 State

Version-1 `<data>/sync/state.json` is scoped to one normalized
`(server_url, user_id)` pair and one library root. Server URLs here are
deployment bases, without `/api/v1`; URL input normalization and transport
policy belong to the sync client. Root identity uses an absolute lexical path,
not a symlink-resolving filesystem lookup.

```
version, server_url, user_id, library_root, database_id,
cursors:   scope_key → cursor (opaque string),
groups:    group_id → {name, folder, role},
prompts:   id → {scope_key, path, rev, canonical_hash, origin?, last_error?}
favorites: id → true                    (group prompts only, §9.5)
```

Prompt/favourite keys use `PromptIdentity`: an uppercase ULID, or a lowercase
device-local path SHA-256 before identity assignment (§9.3). Local keys never
cross the wire and migrate with favourites when a ULID is assigned. Prompt
`rev` is zero for an unacknowledged local create and requires a null canonical
hash; acknowledged revisions (≥1) require a non-null full canonical hash.
Sent hashes belong to the pending-operation journal (§20 E9), not this baseline.
This also lets invalid new files retain their sanitized error/fingerprint
without claiming a server baseline.
Pending local paths retain exact safe `FileStore` spellings so a repairable
wire-path error can be recorded; acknowledged paths must be NFC sync paths.

- **Validated, fail closed.** IDs are canonical ULIDs/UUIDs, cursors remain
  opaque nonempty strings, paths are scope-relative NFC sync paths and hashes
  cover the full canonical bytes. A corrupt, unsupported or future-version
  document blocks ordinary edits and sync, preserving library files. Reset
  is an explicit intent. Unknown fields of a supported version survive edits,
  including nested records. Each stored document (`state.json`, `account.json`,
  `binding.json`) is capped at 16 MiB; an oversized write fails before I/O and
  leaves the previous file intact. Failed writes retain the previous memory cache.
- **Atomic and durable.** Private records use the app-data `FileStore`'s
  atomic 0600 writes, followed by checked file and directory flushes through
  `SyncFileOperations`. Its library capability also covers checked durable
  publication, 0444/normal modes, trash and managed directory lifecycle.
  Existing `FileStore` semantics are unchanged. A failure after publication
  reports uncertain durability and blocks further edits pending recovery.
  Retrying a clear must flush the deletion even if the file is already gone.
  Best-effort directory fsync is not a successful sync commit. Scope cursors
  commit only after the journaled pull's files and affected directories are
  on disk (§9.3).
  Version-1 `<data>/sync/apply.json` records the account/root, old and intended
  state, stable operation/copy IDs, exact intended and losing bytes/hashes,
  incarnation baselines and resumable identity migrations before any mutation.
  Recovery blocks ordinary library reads and edits while identity/data may be
  partly migrated, until replay completes or a planner resolves a typed conflict.
  Direct usage/value writes, removals and ordinary key migrations check the same
  recovery gate under their own store locks; in-flight writes finish before
  preparation snapshots their store. Ordinary library reads and edits check
  the recovery gate under the LibraryService lock and fail immediately with
  typed recovery-required. Internal recovery's checked read/hash/mutation
  uses that lock without the ordinary gate; journal, state and keyed-store
  I/O never hold that lock. Explicit replay revalidates and reflushes uncertain
  journal/state records on the same live graph before releasing the permit.
  A replacement journal instance may resume the validated on-disk plan after
  abandoning its predecessor; each graph still serializes one journal.
  The live permit retains the intended state across journal-object replacement.
  If the journal is already absent, recovery verifies that intended state and
  reflushes state and deletion before releasing the permit; a missing intent
  with uncommitted state stays recovery-required until restored or resolved.
  Corrupt/future journals stay blocked until explicitly restored or reset;
  a reset's deletion must be flushed before ordinary access resumes.
  Ordinary begin/finish cannot clear this block, including an existing permit;
  only validated recovery resumption or durable empty recovery releases it.
  Failed recovery reads preserve the durability-uncertain latch while reporting
  their typed error, so a retry still revalidates and reflushes the document.
  Publish exact server bytes, verify the result, flush files and affected
  directories, durably commit state, then durably remove the journal. Replay
  rechecks installed bytes and modes even for completed steps; an uncertain
  post-rename flush cannot acknowledge a cursor. Private raw retention plus
  source/copy/hold metadata survives journal removal under `sync/retained/`.
  Unsupported/forensic rescues retain exact bytes and a typed hold issue;
  valid copies receive the journaled fresh ID before upload. Adoption migrates
  history, usage, values and content-bound provenance without changing ordinary
  editor identity rules. Cooperating writers are serialized; §4.6's documented
  noncooperating-writer/check-then-act limitation remains.
  Untouched migration preparations can replan a rejected publication. A changed
  external keyed record or partially applied identity migration instead reports
  typed recovery-required and retains its journal; it never promises a conflict
  replan that would discard migration. A secondary raw-retention failure preserves
  the original applied effect and displaced bytes in its returned typed error.
  Conflicting retained bytes report permanent invalid-state, never retryable I/O.
- **Connection metadata.** `<data>/sync/account.json` is a version-1 optional
  connection: normalized server URL, user ID, username, device ID/name and a
  local connection UUID. That UUID names `device:<UUID>` in `SecretStore`;
  no password, device token or invite token enters these records.
  The optional `activation` is `inactive` or `enabled`; existing version-1
  connections without it infer enabled only when `account` is non-null.
  Login stages an inactive connection, then enables it after reserved-folder
  preflight and journaled account/root preparation. `cleanup_connections`
  retains local UUID references for failed persisted-token deletion. An
  inactive or signed-out connection never reads an environment token at startup.
  The secret-store envelope is version 1 and binds the token to the normalized
  deployment, user ID and local connection UUID; raw persisted tokens require
  reauthentication. Raw environment tokens must verify the recorded user and
  current device through `/me` before use.
- **Library ownership.** Separate version-1 `<data>/sync/binding.json`
  retains ownership by library root, managed group-folder ownership and an
  upload hold set independently of active state or connection metadata.
  Holds retain local `PromptIdentity` (including path hashes for idless
  files), exact relative path, source account and raw-content hash. Editing
  held content does not authorize upload; explicit inclusion/import releases
  it. Different roots start snapshot/adoption without inferring deletions
  from the previous root. Returning to a root retains its ownership/holds.
- **Account changes.** A different server or user discards active state and
  runs first sync (§9.4). Journal group rescue and hold every prior-account
  private/rescued file, including idless files, before enabling the new account.
  They remain usable locally and are never uploaded automatically to the new
  account. Same-account reauthentication retains queued edits.
- **Sign-out.** Revoke the device token, clear active state and connection
  metadata, and leave library files and non-secret library ownership in place.
  Stop and drain work, durably disable automatic resume, then attempt revocation
  with a five-second deadline. Complete local apply recovery and retain exact
  possibly-sent request facts before clearing state, without retrying a network
  write. Failed recovery keeps its state/journal blocked. Report unconfirmed
  remote revocation, failed secret deletion and failed metadata cleanup explicitly.
- **Personal values and errors.** Group favourite `true` inserts, explicit
  `false` removes, and absent preserves the remembered value. There is no
  group-private overlay. Origin is typed as conflict-of a ULID or rescued;
  it is separate from server write origin and Assistant provenance (§9.6).
  Per-file errors store only a fixed issue code and an operation fingerprint
  of bytes, path, scope and access generation, never an error body. Repairing
  an offending input allows another attempt (§9.6).

### 9.3 One sync pass

A pass runs every `SYNC_INTERVAL = 60 s`, `SYNC_DEBOUNCE = 3 s` after local
saves, and on demand.

1. **Pull.** `POST /sync/pull` with `database_id` and all cursors. Repeat
   until no scope has `has_more`, collecting every page, then apply
   everything together. A move pair split across pages is therefore still
   seen as a pair.
   - **Scope guard.** An item applies to a prompt's state entry only when the
     entry's `scope_key` is the scope the item arrived in. Our own move,
     echoed back as `move_out` from the old scope, therefore finds the
     entry already in the new scope and is a no-op.
   - **`upsert`.**
     - Skip if `rev` ≤ the recorded rev; that also absorbs our own pushes
       echoed back.
     - Clean local file: overwrite it.
     - Dirty local file: follow §9.6.
     - Before writing, check the target path case-insensitively. On a
       collision with another prompt, clash-rename locally (§9.6) and push
       the rename.
     - An upsert whose `path` differs from the recorded path is a remote
       rename or move. The file at the recorded path is removed, but only
       if it carries the item's `id` (otherwise it was already moved or
       replaced locally, and it stays). The server content is then written
       at the new path. If the old file was dirty, the server version still
       takes the new path, and the local edits follow §9.6.
   - **`move_out` / `delete`.**
     - Paired with an `upsert` of the same `id` in another scope of this
       pull, it moves the file between scope folders. It also updates the
       state entry to the upsert's scope and path; the upsert then follows
       its normal rules.
     - Unpaired, it trashes the file at the recorded path. This happens only
       if the file's front-matter `id` matches (otherwise the item is a
       no-op), and a dirty file is rescued first (§9.6).
   - **Snapshot.** Each snapshot is reconciled only against the state
     entries its scope owns. Items are matched by id and canonical hash,
     never by rev order: after a restore, server revs can be lower than
     recorded ones. The `database_id` comparison is made once per pull.
     - An id present on both sides with an identical hash: record the
       snapshot `rev`.
     - An id present on both sides, different content, on a normal resync:
       apply the upsert rules and adopt the snapshot `rev`.
     - Same, but the response's `database_id` differs from the stored one (a
       restore): re-push the local content as an update on the adopted
       `rev`. A 409 falls back to §9.6.
     - A recorded id missing from the snapshot, on a normal resync: a
       deletion. Trash the file if clean; rescue it if dirty.
     - Same, after a `database_id` change: data the restore may have lost.
       Always rescue it; never trash it.
     - Unknown snapshot ids are written.
     - The new `database_id` is stored after every scope is reconciled.
   - **`removed` scopes.**
     - Rescue dirty and unknown files from the folder into
       `Conflicts/rescued-<UTC date>/` and notify ("You were removed from
       <group>; N local files were kept"). Trash the rest.
     - Then drop the scope's cursor, its `groups` entry, and every
       `state.prompts` entry it owned.
   - **Rescue** (here, for stale folders §9.1, and for account changes
     §9.2). A rescued file becomes a new private prompt: the app writes a
     fresh ULID `id:` into it, replacing any old one, before it can be
     pushed.
2. **Detect local changes.**
   - Scan every `*.md` under the library, excluding `.`/`_` entries and the
     root `README.md`. Symlinks are never followed.
   - Match files to state by `id` first, then by path. Same `id` at a
     different path is a rename or move; this runs before anything is
     classified as new or deleted.
   - Group-folder files are compared on their canonical form (§9.5).
   - A file without an `id` that matches no recorded path is new. Files
     arriving with an `id:` (imports, git) keep it.
   - Two live files with the same `id` are a validation issue: the
     lexically first path keeps it, and the other gets a new id.
3. **Push.**
   - **Re-read before sending.** Each file is re-read and re-hashed at push
     time, and the fresh bytes are what is sent.
   - **Ids.** Before a file's first push, the app writes a fresh ULID `id:`.
     In the same step it migrates the state key and the local `history/`
     directory. A path-hash id never leaves the device.
   - **Requests.** Creates and edits use `PUT` with `base_rev`, deletes
     `DELETE`, and scope changes `/move`. A move combined with an edit sends
     `/move` first, then `PUT`; if the `PUT` fails, the move stands and the
     edit retries next pass.
4. **Overwrite safety.** Every write of a server version re-checks the
   local file (read + hash) immediately before replacing it, under a
   per-file lock. An edit made in between is never lost: it becomes a
   conflict.

Errors back off exponentially from `SYNC_BACKOFF_MIN = 5 s` to
`SYNC_BACKOFF_MAX = 10 min`. `401` stops syncing and asks the user to sign
in again.

`SyncStatus` is one of `idle`, `syncing`, `offline`, `needsSignIn`,
`hasConflicts`, `syncError`.

### 9.4 First sync on a device

This covers enabling sync, a second device, and an account change. A first-ever
sign-in adopts/creates the chosen library; a copied library on a second device
still converges. On a previously bound root, the §9.2 account-change hold set
excludes old-account files from creates/adoption until explicit inclusion or
import. New-account snapshot installation must preserve held bytes at an
occupied target and resolve the collision under §9.3 overwrite safety before
publication. Relocating/rescuing a held file migrates its hold; it never
authorizes upload. A fresh library
also authorizes its chosen content for that account.

Y11 must assign ULIDs to idless held files during the account transition using
ordinary identity assignment, migrating each hold with its file. Hold checks
also match the recorded raw-content hash so an unedited rename stays held;
the assigned identity keeps rename plus edit held. Y7 must evaluate holds
before any upload decision, including first-sync creates/adoption.

1. Pull snapshots for all scopes.
2. Match local files to server prompts:
   - by `id` first
   - then by `(scope, path_key)` with identical canonical content, in which
     case the client adopts the server id and rev and writes `id:` into the
     file
3. Push only unmatched files as creates.
4. A create answered with `path_taken` is compared with the `existing`
   prompt in the response:
   - identical canonical content: adopt it
   - different content: clash-rename

A library copied to a second device by git or Syncthing therefore converges
instead of doubling.

### 9.5 Canonical form and per-user data

- **What is stripped.** For group-scope files the canonical form excludes
  `favorite` and `private`, which are personal.
  - On ingest and before push, Core's pure `CanonicalForm.group(bytes,
    filename:)` returns canonical bytes, an optional extracted `favorite`
    and warnings. Absent favourite is `nil`; explicit `false` stays `false`.
    Every present `private` key, including `false`, produces the validation
    warning `metadata.group_private_removed`. Existing content warnings
    remain nonblocking. Invalid content and future formats fail before
    stripping. M6 owns updating `state.favorites` and rewriting the file;
    Core never reads or changes per-user state.
  - Canonical serialization follows §5.2: optional-key presence, typed
    unknown values and nested ordering survive; YAML comments and scalar
    presentation can change (B26). Only top-level personal keys are removed.
    Markdown body UTF-8 bytes, including CRLF, BOMs and trailing newlines,
    remain exact. Canonicalizing the result again returns identical bytes
    and hash, with no extracted favourite or private-key warning.
  - `canonical_hash` is lowercase SHA-256 over the full canonical bytes,
    including `id`, which are also the bytes the server stores. Core reuses
    its pure Swift FIPS 180-4 implementation, already tested against standard
    known-answer and million-byte vectors; no CryptoKit or new dependency
    is needed on Linux. `CanonicalForm.user(bytes, filename:)` validates
    private content but retains the supplied bytes verbatim and hashes those
    exact bytes, including comments, personal keys and id spelling.
  - The server runs the same canonicalizer, so a stray key cannot cause a
    re-push loop.
- **Adoption comparison (B5).** `CanonicalForm.equivalentForAdoption(local,
  server, scope:, filename:)` compares canonical content with `id` removed,
  using exact UTF-8 byte equality. It strips personal keys for group scope
  and retains them for user scope. Empty headers are treated as absent only
  in this comparison, so an id-only server file matches a plain idless local
  file. The body is also compared separately, so body text resembling front
  matter cannot be mistaken for metadata after an empty header is removed.
  Other optional keys, unknown metadata and body bytes still matter.
  Invalid/future inputs fail rather than compare equal. This comparison
  never assigns an id and never substitutes for the stored-byte hash.
- **Remembered values** are never synced.

### 9.6 Conflicts and errors

- **Edit vs edit** (a `409 conflict` on push, or a dirty file on pull):
  - The server version takes the original path.
  - The local version becomes a new private prompt with a new id, at
    `Conflicts/<group folder or "Personal">/<name> (conflict <device>
    <UTC YYYY-MM-DD HHmm>).md` (`CONFLICT_NAME_FORMAT`). It is never placed beside the original,
    where a group folder would push it into the group.
  - Private content carries `x-monkeyspaw-conflict-of: <ULID>` in front
    matter, mirrored as typed state `origin: conflict_of <id>` (§20 E18).
    Rescues instead carry `x-monkeyspaw-rescued: true` and rescued origin.
    Ingest requires a canonical uppercase ULID distinct from the copy's ID,
    and an actual boolean for rescued; false means no rescued origin. A
    conflict marker together with rescued true is invalid. Invalid local markers
    are held raw with `metadata.invalid_type`, never trusted as origin. Canonical
    server bytes with invalid markers are installed exactly with nil origin and
    a fingerprinted per-file error, so one bad marker cannot block the whole pull. Group
    metadata is validated but only private state projects origin. Ordinary
    copies, renames and private sync preserve the keys; clearing them clears
    state origin on ingest. The Conflicts filter uses marker-derived origin,
    never the file name. Copies from another device remain listed anywhere.
  - The resolve view reuses the improve diff (§7.3). The actions are: keep
    server, keep mine (re-push on the new head), or keep both.
- **Dispatch by envelope code.** A `409 conflict`, including on `/move`,
  resolves to the head's scope and path, preserving the losing local version.
  A `409 path_taken` renames the intended destination before retrying a
  transfer; its unrelated `existing` content never implies original ownership.
- **Lost acknowledgements.** Journal exact sent scope/path/full-byte hash,
  bytes and base revision. An identical newer conflict head proves a create,
  edit or move succeeded: adopt it without a copy (§20 E9). For a move this
  comparison uses the server baseline canonicalized for the destination,
  not an accompanying local edit. An unknown moved baseline cannot prove
  success. A newer local re-read stays dirty and is never treated as sent.
  A push acknowledgement does not advance pull cursors.
- **Edit vs delete.**
  - Local edit vs server delete or `410 deleted`: the local version becomes
    a new private prompt with a new id in `Conflicts/`, and the user is
    notified.
  - Local delete vs server edit: the server version is restored.
  - `DELETE` answered with `410` or `404`: success.
- **Path clash** (`409 path_taken`): rename the local file first, to
  `<name> (2).md`, then `(3)` up to `PATH_CLASH_MAX = 20`. Update state,
  then retry. Beyond the cap the file is marked `syncError`.
  Sync naming compares NFC/full-fold `path_key`, independently of editor copy
  names. An incoming server prompt owns its path; relocate a writable local
  occupant with its identity/history intact, or rescue a viewer/unknown
  occupant privately before replanning (§20 E12). Name truncation retains
  whole Unicode characters, the complete conflict timestamp and collision
  suffix. Private destinations fit the 1,024-byte wire cap, even when the
  source uses the 1,287-byte rooted cap. Long rescue hierarchies flatten with
  a stable source-path hash suffix; the journal retains the exact source map.
- **Denied (`403`)** never proves the user is a viewer (§20 E20). Refresh
  memberships. An edit/delete/move restores only an accessible GET head whose
  ID, scope and path match the acknowledged recorded original. Malformed or
  mismatched GET heads are unavailable for restoration. Otherwise
  rescue locally. Creates always rescue locally. Keep any local version
  privately and notify; do not immediately repeat the denied operation.
- **Input errors** (`422`, `404` on update): persist a sanitized issue code
  and a fingerprint of input bytes, path, scope, operation and access generation.
  The same fingerprint is skipped, including after restart. Repair to any
  offending input permits another attempt. A 403 uses the same hold until
  input/access changes. The footer shows "sync errors" and lists the file
  and the fixed reason, never a server error body.
- **No cascades.** A conflict copy is created once per losing local version.
  It has its own private identity and is never compared against the original.
  A conflict of a marked copy retains its root origin rather than pointing at
  another conflict copy. Reuse a current private copy only when regenerating
  it with its own ID/origin yields identical full bytes; this works after
  restart or rename. Reuse requires a conflict-of origin identifying the original;
  rescued true alone cannot identify a source, so equal-bodied rescues stay distinct.
  Recheck that copy through the apply journal before retiring the source. Plan
  every pull's copies together, reserving incoming paths and prior allocations
  and excluding any candidate that the same plan replaces or removes.
  Different versions in the same minute get bounded
  distinct names. Journal the chosen destination and fresh ID once and replay
  those choices. Forensic/unsupported content remains byte-exact with a typed
  upload hold; no marker or ID is injected into invalid bytes (§20 E14).
  Permanent retention records bind raw holds to account/root, destination,
  source, hash, issue and typed origin. Ingest must read those holds before
  duplicate-ID repair or ownership matching; an embedded raw ID never identifies
  a live server head. Held files remain path occupants and are preserved on clashes.
- **Timestamps.** Conflict names use UTC. `{{date}}` and `{{time}}` stay
  local, because they are template values, not records.

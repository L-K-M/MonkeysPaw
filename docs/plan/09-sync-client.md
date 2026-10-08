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
  - A folder is keyed by `group_id` in sync state. Its name is the group
    name, sanitized: path-validation rules applied, then de-duplicated
    with ` (2)`.
  - A group rename renames the folder.
  - A folder under `Groups/` that maps to no current group, or a file
    sitting loose directly under `Groups/`, is never pushed. It is rescued
    (§9.3, step 1) and removed.
- **Viewer groups are read-only.** Files are written with
  `READONLY_FILE_MODE = 0444` and the editor opens them read-only. When a
  role changes to or from `viewer`, existing files are re-moded and open
  editors switch.
- **Moving a file is a scope change.** Moving a file into, out of, or
  between group folders (in the app or a file manager) requests a `/move`.

### 9.2 State

`<data>/sync/state.json` is scoped to one `(server_url, user_id)` pair.

```
version, server_url, user_id, database_id,
cursors:   scope_key → cursor (opaque string),
groups:    group_id → {name, folder, role},
prompts:   id → {scope_key, path, rev, canonical_hash, origin?, last_error?}
favorites: id → true                    (group prompts only, §9.5)
```

- **Atomic and durable.** `state.json` is written atomically. Scope cursors
  are persisted only after the collected pull is applied and its file writes
  are on disk.
- **Account changes.** Signing in with a different server or user discards
  the state and runs first sync (§9.4). Folders that don't match the new
  account's membership are rescued, never pushed into another account's
  groups.
- **Sign-out.** It revokes the device token, clears the state, and leaves
  files in place.

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

This covers enabling sync, a second device, and an account change.

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
  - On ingest and before push, Core's `CanonicalForm.group` lifts
    `favorite` into `state.favorites`. It drops `private` with a validation
    warning, and rewrites the file once in canonical form.
  - `canonical_hash` is the hash of the canonical bytes, which are also the
    bytes the server stores.
  - The server runs the same canonicalizer, so a stray key cannot cause a
    re-push loop.
- **Remembered values** are never synced.

### 9.6 Conflicts and errors

- **Edit vs edit** (a `409 conflict` on push, or a dirty file on pull):
  - The server version takes the original path.
  - The local version becomes a new private prompt with a new id, at
    `Conflicts/<group folder or "Personal">/<name> (conflict <device>
    <UTC YYYY-MM-DD HHmm>).md` (`CONFLICT_NAME_FORMAT`). It is never placed beside the original,
    where a group folder would push it into the group.
  - State marks it `origin: conflict_of <id>`. The Conflicts filter uses
    that flag, never the file name, so renaming a copy keeps it listed.
    Files pulled into `Conflicts/` from other devices are listed too.
  - The resolve view reuses the improve diff (§7.3). The actions are: keep
    server, keep mine (re-push on the new head), or keep both.
- **A `409` on `/move`** resolves to the server's scope and path. The local
  version then follows edit-vs-edit.
- **Create retried after a network drop.** If the `409` head equals what was
  pushed, the create succeeded: adopt it, and make no copy.
- **Edit vs delete.**
  - Local edit vs server delete or `410 deleted`: the local version becomes
    a new private prompt with a new id in `Conflicts/`, and the user is
    notified.
  - Local delete vs server edit: the server version is restored.
  - `DELETE` answered with `410` or `404`: success.
- **Path clash** (`409 path_taken`): rename the local file first, to
  `<name> (2).md`, then `(3)` up to `PATH_CLASH_MAX = 20`. Update state,
  then retry. Beyond the cap the file is marked `syncError`.
- **Denied (`403`)** for a viewer edit, delete, or move: the file is
  restored from `GET /prompts/{id}` at its recorded path (a moved file is
  moved back). Any local edit is kept as a private copy in `Conflicts/`, and
  the user is notified.
- **A `403` on create**, such as a new file dropped into a viewer group's
  folder: the file moves to `Conflicts/` as a private prompt, and the user
  is notified. A `403` is never retried.
- **Not retryable** (`422`, `404` on update): state records `last_error`.
  The file is skipped until its content changes. The footer shows "sync
  errors" and lists the file and the reason.
- **No cascades.** A conflict copy is created once per losing local version.
  It is a new private prompt and is never compared against the original.
- **Timestamps.** Conflict names use UTC. `{{date}}` and `{{time}}` stay
  local, because they are template values, not records.

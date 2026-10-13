## 8. Sync server

### 8.1 Data model

```text
-- every *.id below is a ULID string
meta(singleton PK CHECK(singleton = 1), database_id UNIQUE)
                                         -- random UUID; generated once, rotated by restore
users(id, username UNIQUE, display_name, password_hash,
      account_kind ∈ {member, admin}, created_at, disabled_at NULL)
groups(id, name, created_by, created_at, deleted_at NULL)
memberships(group_id, user_id, role ∈ {owner, editor, viewer}, joined_at, PK(group_id, user_id))
prompts(id ULID PK,                       -- the same id as the file's front matter
        scope ∈ {user, group}, owner_id NULL, group_id NULL,
        path,                             -- validated relative path inside the scope (§8.4)
        path_key,                         -- Core's folded form of path: NFC + Unicode case fold
        content,                          -- group scope: canonical bytes (§9.5); user scope: verbatim
        title,                            -- extracted by Core on write, for listings
        rev INTEGER NOT NULL,             -- per-prompt compare-and-swap counter
        created_by, created_at, updated_by, updated_at, deleted_at NULL,
        CHECK ((scope = 'user'  AND owner_id IS NOT NULL AND group_id IS NULL)
            OR (scope = 'group' AND group_id IS NOT NULL AND owner_id IS NULL)))
prompt_revisions(prompt_id, rev, author_id, scope, owner_id NULL, group_id NULL,
                 path, content, created_at, origin, PK(prompt_id, rev))
changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,
        scope_key,                        -- "user:<id>" or "group:<id>"; INDEX(scope_key, seq)
        scope, owner_id NULL, group_id NULL,
        prompt_id, kind ∈ {upsert, delete, move_out}, path, rev, content NULL, at)
scope_heads(scope_key PK, head_seq)       -- durable high-water mark, raised by change inserts
scope_floors(scope_key PK FK scope_heads, floor_seq)
                                         -- one past the highest purged seq; only ever raised
retired_prompt_ids(prompt_id PK, scope, owner_id NULL, group_id NULL, retired_at)
snapshots(database_id, scope_key, head_seq, manifest BLOB, created_at, expires_at,
          PK(database_id, scope_key, head_seq))
devices(id, user_id, name, token_hash UNIQUE, created_at, last_seen_at, revoked_at NULL)
invites(token_hash PK, group_id NULL, role NULL, created_by, expires_at, consumed_at NULL)
login_account_buckets(username PK, failures, locked_until NULL, updated_at)
login_ip_buckets(ip PK, failures, locked_until NULL, updated_at)
audit_events(id, actor_id, action, target, at)   -- admin and owner actions on accounts and memberships
```

The first migration also runs raw SQL, because Fluent cannot express partial
indexes:

```sql
CREATE UNIQUE INDEX prompts_user_path  ON prompts(owner_id, path_key) WHERE deleted_at IS NULL AND scope = 'user';
CREATE UNIQUE INDEX prompts_group_path ON prompts(group_id, path_key) WHERE deleted_at IS NULL AND scope = 'group';
```

- **Path uniqueness** is per scope, case-insensitive, and
  normalization-insensitive, through `path_key`. SQLite treats NULLs as
  distinct, hence one partial index per scope. Two files that differ only in
  case, or in NFC vs NFD, would overwrite each other on a case-insensitive
  disk (APFS).
- **History.** Every accepted write appends a `prompt_revisions` row, and
  `prompts` holds the materialized head. The desktop's local history (§5.5)
  stays local. The server history is the shared, durable record.
  Revisions retain their event-time scope and path (§19 B14). Foreign keys
  keep authors and owners valid; users are disabled and groups soft-deleted
  rather than removing referenced identities.
- **Constraints.** Revisions are positive, roles and kinds are checked, and
  every scope-bearing record uses the prompt ownership CHECK above.
  Usernames use one lowercase ASCII spelling, 1–64 bytes of `a-z`, `0-9`,
  `_`, `.` or `-`, in both users and account login buckets (§19 B7).
  Account-only invites have no role; group invites require a checked role.
  The database UUID uses uppercase canonical UUID text. Its singleton cannot
  be deleted/replaced; explicit UUID UPDATE remains available for restore.
- **Feed payloads.** Changes are immutable event-time scope/path/rev records.
  An upsert carries its own content; delete and move_out carry no content.
  Feed rows have no foreign key to a prompt or revision, so purging heads
  or pruning revisions cannot invalidate retained events (§19 B16).
- **Frozen snapshots.** A manifest contains frozen prompt payloads ordered
  by id, keyed by database UUID, scope and captured head (§19 B17). Storage
  allows at most 64 MiB per manifest and 256 MiB in total, with a lifetime
  of at most 15 minutes. S14 supplies encoding, expiry cleanup and page
  reauthorization; no read transaction spans HTTP requests. Restore clears
  manifests before rotating the database UUID.
- **One blob column.** `content` is the whole canonical file, so end-to-end
  encryption could be added later as an opaque payload without a schema
  break.
- **Retention.** Change rows and tombstones older than
  `CHANGE_RETENTION_DAYS = 90` are purged, and `scope_floors` is raised in
  the same transaction.
  - `floor_seq` is one past the highest purged seq in the scope. For a
    scope whose every row was purged, that is `head + 1`.
  - The floor is never cleared, so a cursor in a purged gap is always
    detected. Revisions are capped at
  `SERVER_REVISIONS_PER_PROMPT = 200`.
  Retired prompt IDs keep only their last scope and retirement time forever
  after content/history purge (§19 B15). Scope heads and floors cannot be
  lowered or deleted by ordinary SQL; stale detection uses
  `cursor + 1 < floor_seq` (§19 B18).
  Empty scopes may initialize head 0. Nonzero head inserts/raises must name an
  existing change in that scope; floors cannot exceed head + 1, and snapshot
  heads cannot exceed the scope head at materialization.
- **Time.** Every stored timestamp is UTC ISO-8601.

### 8.2 Roles and permissions

| Action | Private prompt | Group `viewer` | Group `editor` | Group `owner` | Admin |
|---|---|---|---|---|---|
| Read, use, sync | owner only | ✓ | ✓ | ✓ | only through memberships, like anyone |
| Create, edit, rename, delete prompts | owner only | ✗ | ✓ | ✓ | as left |
| Move private → group | owner, if `editor`+ in the target | | | | only through memberships |
| Move group → private | | ✗ | prompt creator only | ✓ | only through memberships |
| Move group → group | | ✗ | creator, if `editor`+ in the target | ✓ (+ `editor`+ in the target) | only through memberships |
| List members, see revision authors | | ✓ | ✓ | ✓ | members globally; revision authors only through memberships |
| Invite (`editor`/`viewer` roles), change roles, remove members | | ✗ | ✗ | ✓ | ✓, no self-add or self-elevation |
| Owner-role invites | | | | | admin CLI only |
| Rename group | | ✗ | ✗ | ✓ | ✓ |
| Delete group (prompts are deleted; members lose the scope) | | ✗ | ✗ | ✓ | ✓ |
| Create groups | any user (becomes owner) | | | | ✓ |
| Create, disable or enable users, reset passwords, change account metadata or kind | | | | | ✓ |

- **No read endpoint for admins.** Admins have no endpoint that reads a
  prompt directly, and cannot grant themselves membership (403).
  Creating a new group makes its creator an owner, including an admin; this
  is the bounded exception, not authority to join an existing group (§19 B11).
  Admins may list membership metadata globally. Owner promotion is allowed;
  self-demotion and self-removal are allowed when another owner remains.
  An admin cannot add themselves or raise their own role in an existing group,
  even if they are already a member. Keeping the same role is idempotent.
  - Every successful admin or owner change to accounts and memberships is
    written to `audit_events`.
  - The plan is honest about the limit. An admin who can reset passwords,
    and the operator who owns the database, can ultimately read everything.
    SECURITY.md says so: the permission model protects members from each
    other, not from the operator.
- **Out-of-scope reads return 404, not 403**, so ids don't leak.
- **Viewers writing get 403.**
- **A group always keeps at least one owner.** Removing or demoting the last
  owner returns 403. The service checks current authority and owner count in
  the same serialized write transaction as the membership change (§19 B12).
- **At least one active admin remains.** Disabling or demoting the last
  enabled admin returns `403 forbidden`. Disabled admins do not count. The
  service checks for another enabled admin inside the same write transaction
  as the update, so concurrent removals cannot leave HTTP administration
  without an admin.
- **Group deletion.** One transaction soft-deletes the group, removes its
  memberships, and tombstones all live group prompts. Each newly tombstoned
  prompt gains one revision and an immutable delete event; existing tombstones
  keep their revision and deletion time. Retired IDs are recorded for every
  group prompt, including existing tombstones, and retained events/history and
  relational group identities survive until their retention rules apply
  (§19 B15/B16). The scope immediately disappears from every member's `/me`
  response. Membership inspection and further group operations return 404,
  including for admins. Unrelated scopes are unchanged.
- **Group audit.** Stable actions are `group.create`, `group.rename`,
  `group.delete`, `membership.upsert` and `membership.remove`. Membership
  events identify the affected user in `target` and the group in a nullable
  `group_id` audit column; existing account events leave that column null.
  Creation audits the automatic owner, and deletion audits each membership
  removal. All audit rows commit with their mutations; audit failure rolls
  back the entire operation. No name, role payload, prompt content or
  credentials are recorded.
- **Invite audit.** `invite.create` targets the group for a group invite, or
  the issuing admin for an account-only invite. `invite.consume` targets the
  redeeming user. Group events include `group_id`; tokens and hashes never
  enter audit rows. Registration also records `user.create`, and group
  redemption records `membership.upsert`, attributed to the invite issuer.
  Every audit row commits with the invite and account/membership mutation.
- **Disabled users.** All of their tokens fail with 401. Their prompts and
  memberships are kept. Disable and admin password reset revoke all target
  devices, including the caller's device on a self-reset. Enabling requires a
  fresh login; it does not reactivate revoked devices. Ordinary members receive
  403 for account administration, regardless of their group role. Services
  recheck the enabled admin and calling device inside the write transaction.
- **Account audit.** Stable actions are `user.create`, `user.update`,
  `user.disable`, `user.enable` and `user.reset_password`. Each committed account
  change records only an event id, actor and target ids, and UTC time. A combined
  patch records its metadata, password and enable/disable actions in the same
  transaction as the account and device changes. Unchanged display name,
  account kind or enabled state produces no audit row or success log. Repeated
  disable keeps its original time. A password reset changes the salted hash
  and is audited even when the plaintext password is unchanged. Rejected
  requests write no audit rows; their safe diagnostic uses §12 logging.
  Audit failure rolls back every mutation. A nullable actor represents the
  explicit CLI operator (§19 B12); HTTP always records the authenticated user.

### 8.3 API (v1, JSON, `Authorization: Bearer <device token>`)

| Method and path | Purpose |
|---|---|
| `GET /api/health` | Liveness and version; no auth (Docker healthcheck) |
| `POST /api/v1/auth/login` `{username, password, device_name}` | `200 {device_token, user}`; 401 for bad credentials, 429 when backoff starts or either bucket is locked (§8.5). |
| `POST /api/v1/auth/logout` | Revokes this device's token; `200 {}` |
| `POST /api/v1/auth/register` `{invite_token, username, password, device_name}` | Consumes an invite; group invites join their group with its role, and account-only invites create an ungrouped account. Returns `{device_token, user}`. |
| `POST /api/v1/auth/password` `{current_password, new_password}` | Change own password; revokes all other devices; `200 {}` (B9) |
| `GET /api/v1/me` | `{user, groups, devices}`; caller's own devices only, including revoked devices (B9) |
| `DELETE /api/v1/me/devices/{id}` | Revoke a caller device; `200 {}` (B9) |
| `POST /api/v1/sync/pull` `{database_id, cursors: {scope_key: cursor}}` | Per-scope feed (§8.4). Cursors are opaque strings: a seq, or `snap:…` for an unfinished snapshot. |
| `GET /api/v1/prompts/{id}` | `{id, rev, scope, group_id?, path, content}`, or 404 out of scope or tombstoned (B13) |
| `PUT /api/v1/prompts/{id}` `{base_rev, scope, group_id?, path, content}` | Create (`base_rev: 0`) or update with compare-and-swap. On update, `scope` and `group_id` must equal the current values; scope changes go through `/move`. |
| `DELETE /api/v1/prompts/{id}?base_rev=<n>` | Tombstone, with compare-and-swap |
| `POST /api/v1/prompts/{id}/move` `{base_rev, scope, group_id?, path}` | Atomic scope change: one prompt, new owner (Bitwarden) |
| `GET /api/v1/prompts/{id}/revisions` · `GET …/revisions/{rev}` | History for restore |
| `POST /api/v1/groups` · `PATCH /api/v1/groups/{id}` · `DELETE /api/v1/groups/{id}` | Group lifecycle |
| `POST /api/v1/groups/join` `{invite_token}` | Authenticated existing account consumes a group invite; returns its group name, id and role (B10) |
| `GET /api/v1/groups/{id}/members` · `PUT/DELETE /api/v1/groups/{id}/members/{user_id}` | Member list; role changes and removal (owner or admin; no self-grant) |
| `POST /api/v1/groups/{id}/invites` `{role, expires_in?}` | Single-use invite token, shown once; TTL in seconds, default/max 604,800 (B2/B10) |
| `POST /api/v1/admin/users` · `PATCH /api/v1/admin/users/{id}` · `POST /api/v1/admin/invites` | Admin |

Write responses:

| Outcome | Response | Meaning |
|---|---|---|
| Success | `200 {rev, seq, warnings?}` | For a move, `seq` is the new scope's row. Warnings are issue objects with severity `warning`. |
| Stale `base_rev` | `409 {code: "conflict", head}` | `head` is `{rev, scope, group_id?, path, content}` (B13). |
| Path taken | `409 {code: "path_taken", existing: {id, rev, content}}` | The caller can read the existing prompt, since paths are per scope. |
| Id is tombstoned | `410 {code: "deleted"}` | A stale id can't resurrect a prompt; revival mints a new id (§9.6). |
| Invalid content or path | `422 {issues}` | Core validator errors only. Warnings (e.g. declared-but-unused fields) are returned with a `200` and never block a push. |
| Malformed request/cursor | `400 {code: "malformed_request"}` | Invalid JSON shape or server cursor grammar (B3). |
| Missing/invalid/revoked auth | `401 {code: "unauthorized"}` | Disabled users also receive 401. |
| Denied visible write | `403 {code: "forbidden"}` | Includes viewer writes and disabling or demoting the last active admin. |
| Missing or invisible resource | `404 {code: "not_found"}` | No inaccessible identity or prompt data is returned. |
| Request envelope overflow | `413 {code: "envelope_too_large"}` | HTTP JSON bytes exceed 2 MiB (B3). |
| Login locked | `429 {code: "rate_limited"}` | Required `Retry-After` header: integer seconds, 1–900 (B3/B8). |
| Internal failure | `500 {code: "internal_error"}` | Sanitized; no underlying error text (B3). |
| Expired/restarted frozen snapshot | `409 {code: "snapshot_expired", scopes: [scope_key]}` | The client discards the entire incomplete collected pull and restarts affected scopes without their cursors (B17). |

Each failed API request logs one fixed server-side message. Unexpected failures
use error level and include only the error's type name in `fields.error_type`
as diagnostic metadata; expected failures use debug level. Error descriptions
and request data are never logged; the client keeps the generic `internal_error`
envelope for unexpected failures.

Request and response types live in `MonkeysPawCore/SyncAPI` and are shared by
both sides. Their complete, data-only field descriptions and strict Codable
fixtures pin the JSON Schema 2020-12 contract (B2); see
[`spec/README.md`](../../spec/README.md). All body objects reject additional
properties. JSON keys are snake_case, ULIDs uppercase Crockford, UUIDs
lowercase hyphenated, and timestamps Gregorian UTC with exactly three
fractional digits (`2026-10-12T20:10:56.557Z`). Counters are Int64: `rev` and
successful write `seq` ≥1, create `base_rev` ≥0, delete/move `base_rev` ≥1,
feed `seq` ≥1 and `head` ≥0. Prompt scope is `user` or `group`; the latter requires
`group_id`, and `user` omits it. These values match the database scopes and
feed kinds, with keys `user:<ULID>` and `group:<ULID>` (B2).

The previously unspecified bodies are pinned as follows (B2/B9/B10):

- User metadata is `{id, username, display_name, account_kind, created_at,
  disabled_at}`; display name and disabled time are explicit nullable values.
  Devices expose `{id, name, created_at, last_seen_at, revoked_at, is_current}`;
  last-seen/revoked times are nullable. No password/token hash is exposed.
  `/me` is also the own-device list; `is_current` identifies the calling
  device. Groups include only the caller's current memberships in live
  groups, including for admins. Revoking a missing or another user's device
  returns 404; revoking an already revoked own device returns `200 {}`.
  Revoking the current device or logging out makes subsequent requests 401.
- Admin create takes `{username, password, display_name?, account_kind?}`,
  defaults to member, and returns user metadata. Admin patch takes a nonempty
  subset of `{display_name, password, disabled, account_kind}`. Omitted values
  are unchanged; `display_name: null` clears it; password resets and disable
  revoke every target device per B9. Patch returns the updated user metadata;
  enable preserves prompts and memberships and requires a fresh login.
  Other optional fields reject explicit null. Duplicate canonical usernames
  return the existing `400 malformed_request` envelope; no identity is exposed.
- Group create/rename take `{name}` and return
  `{id, name, created_by, created_at}`; delete returns `{}`. Membership PUT
  takes `{role}` and explicitly adds or changes an existing user. It returns
  `{user_id, username, display_name, role, joined_at}`; list wraps these in
  `{members}` and removal returns `{}`. `/me` and `/groups/join` group metadata
  is `{group_id, name, role}`. Roles are owner/editor/viewer; permission and
  last-owner checks remain transactional server responsibilities. PUT preserves
  an existing member's `joined_at`; re-adding a removed member gets a new time.
  Missing groups, deleted groups, missing target users and missing memberships
  on removal return 404. Non-member, non-admin callers receive 404 for existing
  group reads and writes; visible viewer/editor writes return 403. Admin
  self-add/elevation and last-owner removal/demotion return 403. Group JSON
  bodies use the same streamed 2 MiB envelope cap as account requests.
- Admin invites take `{expires_in?}` for an account-only invite, or
  `{group_id, role, expires_in?}` for a group invite. Responses expose
  `{invite_token, expires_at, group_id?, role?}` once. Account-only invites
  omit both union fields; group invites require both. HTTP invite roles are
  editor/viewer; owner invites remain CLI-only. Tokens use 32 random bytes
  as unpadded base64url, and clients construct the §8.5 join link.
  Closed object branches make these payloads mutually exclusive without
  an additional discriminator: the account branch rejects `group_id`/`role`,
  and the group branch requires both.
- Usernames in every request and response, including login, are 1–64 lowercase
  ASCII letters, digits, dots, underscores or hyphens, beginning with a letter
  or digit. DTOs reject uppercase rather than normalize it; services also
  lowercase defensively, and stored usernames use the same rule for uniqueness
  (B7). Names are 1–255 Unicode scalars and display names 0–255. All password
  fields are at most 72 decoded UTF-8 bytes to avoid bcrypt truncation and
  reject NUL; new passwords require at least 12 scalars (400 otherwise), while
  login/current-password strings are nonempty. Within those DTO bounds,
  unusable supplied passwords fail authentication without accepting a truncated
  prefix.
- PUT additionally accepts optional `origin: edit|llm|restore`, default edit.
  Revision metadata is `{rev, author_id, created_at, origin, scope, group_id?,
  path}`; lists use `{revisions}`. Reading a revision adds `id` and `content`.
  Origin additionally admits server-recorded move/delete. Historical scope
  and path describe that revision, subject to B14 visibility; origin remains
  an operation hint, separate from local assistant provenance (B27).
- Issues are `{code, severity, location?}`. Codes map Core diagnostics, plus
  `prompt.id_mismatch` for a content/URL-id mismatch. Locations discriminate
  `front_matter` with one-based `line`/`column`, `body` with zero-based UTF-8
  `byte_offset`, or `path` with zero-based nullable `segment`. Missing location
  is omitted. A 422 has at least one error; 200 warnings contain only warnings.
  A path location requires `segment`, using explicit null for a global issue;
  optional invite `expires_in` instead permits omission and rejects null.

`MAX_PROMPT_BYTES = 256 KiB` bounds decoded prompt UTF-8, separately from the
2 MiB HTTP request envelope and 16 MiB serialized pull response cap (B3).
DTOs validate wire shape; shared content/path validators still produce the
semantic 422 issues. Every prompt `path`, including move, revision, conflict
head and feed payloads, is nonempty and at most `Limits.maxPathBytes` (1,024
decoded UTF-8 bytes) at the DTO boundary. Full path rules and normalization
remain with `SyncPathValidator` (§8.4). Transport header/body limits are
enforced by later server slices, not by an unbounded Foundation JSON encoder.
Account JSON decoders, including login, collect streamed bodies with a 2 MiB
cap before decoding. Uppercase login usernames and passwords over 72 UTF-8
bytes return 400 `malformed_request` during DTO decoding, before bcrypt,
admission or either backoff bucket is touched. Login checks credentials only
after decoding, returning the same 401 envelope for unknown, disabled and
wrong-password accounts. Its fifth failure and locked requests return 429 with
`Retry-After`; neither response discloses which independent bucket caused the
lock.

### 8.4 Server behaviour

- **Writes are compare-and-swap** in one transaction:
  1. Resolve scope, membership, and role.
  2. Validate the path and content with Core (§8.4 validation).
  3. Check that the front-matter `id` equals the URL id.
  4. Run `UPDATE prompts … SET rev = rev + 1 WHERE id = ? AND rev = ?`.
  5. Append to `prompt_revisions` and `changes`; `seq` comes from
     AUTOINCREMENT inside this transaction.
  6. Commit.
- **Ordering.** SQLite serializes writers, so `seq` values commit in order.
  A reader never sees seq 101 while seq 100 is uncommitted. The server runs
  as one process; v1 supports no replicas, and the README says so.
- **Per-scope feeds.** Every change row belongs to exactly one scope: a
  user's private scope or one group. Visibility follows from membership, so
  no row reaches a non-member and no id leaks. `POST /sync/pull` answers in
  one read transaction:

  ```
  { database_id,
    scopes: [ { key, kind: user|group, group_id?, name?, role?,
                mode: delta|snapshot, head, cursor, has_more,
                items: [ {seq, kind: upsert,   prompt: {id, rev, path, content}}
                       | {seq, kind: delete,   id}
                       | {seq, kind: move_out, id} ] } ],
    removed: [scope_key] }
  ```

  - The response covers every scope the caller can access now.
  - Scopes the client sent that are no longer accessible are listed in
    `removed`: the user left the group, was removed, or the group was
    deleted.
  - `mode: snapshot` returns every live prompt in the scope, and `cursor`
    becomes the scope head. The server picks it when:
    - the client's cursor is absent or 0
    - `cursor + 1 < floor_seq` (B18), so a completed snapshot at the highest
      purged seq does not repeat forever
    - the cursor is above the scope head (a restored database)
    - `database_id` differs from the client's
  - Delta pages return at most `SYNC_PAGE_MAX = 200` emitted items **per
    response**, shared across scopes (B19). A response stops early at
    `SYNC_PAGE_BYTES = 8 MiB` of serialized JSON, including metadata, and
    asserts its final size ≤16 MiB (B3). Fair scope scheduling is deterministic.
    Only safe same-prompt runs in the consumed interval collapse, preserving
    their final kind. The cursor is the highest consumed seq, including empty
    pages, and `has_more` says whether that scope continues (B19).
  - Snapshots page with the same limits, ordered by prompt id.
    - Until the snapshot is complete, `cursor` is opaque `snap:…`, identifying
      a frozen manifest/payload, its captured head and position (B17). It must
      distinguish restarted manifests, rather than rely only on last-id/head.
      Items carry `seq = head`. Every page reauthorizes access; expired or
      restarted manifests use the 409 signaling above, never silently splice
      a new snapshot into already collected pages.
    - The final page sets `cursor` to the head captured on page one.
    - Changes made meanwhile arrive as normal deltas after it.
  - Scope keys are `user:<ULID>` or `group:<ULID>`; private scope metadata has
    only key/kind, while group metadata requires group_id/name/role. The key
    prefix must match kind: `user:` for user and `group:` for group. Group
    keys must agree with group_id. Each response has exactly one private
    scope, unique scope keys, and disjoint, unique removed keys (B2). The
    initial request uses explicit `database_id: null` and `cursors: {}`.
    Cursors are nonempty opaque strings at the DTO boundary; only the server
    parses them and can report malformed/expired ones (B2/B3/B17).
  - Heads are durable high-water marks, independent of retained change rows
    and never reset by retention (B18). A snapshot with head 0 is empty; every
    emitted item has a positive seq (B2/B17/B18).
- **Moves** write `move_out` in the old scope and `upsert` in the new one,
  in one transaction.
- **Deleting a group** deletes its prompts. The group's scope disappears for
  everyone.
- **Path and name validation.** Shared by Core on the client and the server.
  - A `path` is `/`-separated segments. Each segment:
    - is non-empty, and not `.` or `..`
    - if a directory, does not start with `.`: local library enumeration
      ignores dot-directories (§5.1). Dot-prefixed filenames remain eligible.
    - has no `\`, NUL, or control characters
    - does not end in `.` or a space
    - is NFC-normalized and at most 255 bytes
  - The whole path is at most `MAX_PATH_BYTES = 1024`, and ends in `.md`.
  - Private paths may not start with `Groups/`. The check runs on the folded
    `path_key`, so `groups/`, `GROUPS/`, and NFD spellings are all rejected.
    `Conflicts/` is allowed: conflict copies and rescued files are ordinary
    private prompts and sync like any other.
  - The front-matter `id` must be a ULID.
  - Group names become folder names only after the client sanitizes them
    (§9.1). Device names are sanitized before they appear in a file name.
- **Admin CLI** (inside the container), run with
  `docker compose exec monkeyspaw-server monkeyspaw-server …`
  (ManorsAndMenaces precedent):
  - `user add|disable|reset-password`
  - `group add|add-member`
  - `invite create` (any role)
  - `backup <path>`
  - `restore <path>` (rotates `database_id`)

### 8.5 Auth details

- **Passwords.** bcrypt cost `BCRYPT_COST = 12`, stored as a self-describing
  string so a later Argon2id move is a lazy re-hash on login. Minimum length
  `PASSWORD_MIN_LENGTH = 12` Unicode scalars; maximum `PASSWORD_MAX_BYTES = 72`
  UTF-8 bytes, with NUL rejected to avoid C-string truncation. Bcrypt runs on
  the NIO blocking thread pool. Unknown usernames still verify against a
  fixed cost-12 dummy hash; disabled accounts verify before returning 401.
  DTOs reject uppercase usernames before the service's defensive ASCII
  validation and lowercasing; the canonical spelling is used for account lookup
  and uniqueness. Password change verifies the current password, then rechecks
  the session and verified hash inside the transaction that replaces the hash
  and revokes other devices.
- **Device tokens.**
  - 32 random bytes, base64url. The server stores only SHA-256(token) and
    looks tokens up by hash.
  - `last_seen_at` is updated at most every
    `DEVICE_SEEN_UPDATE_INTERVAL = 5 min`.
  - Clients keep the token in the OS secret store.
- **Bootstrap.** On an empty `users` table, the server creates an admin from
  `MONKEYSPAW_ADMIN_USERNAME` and the compose secret file
  `MONKEYSPAW_ADMIN_PASSWORD_FILE`. The username defaults to `admin` and uses
  the same validation and lowercase normalization as login (B7). A direct
  `MONKEYSPAW_ADMIN_PASSWORD` environment value is supported when no file is
  configured. A configured file is authoritative; unreadable/invalid files
  never fall back to the environment value. Remove at most one terminal LF
  or CRLF from a file, preserving password spaces. Secret files must resolve
  to regular files; reads are bounded by a 4 KiB file limit, with oversized
  files reported through a typed bootstrap error. Missing, unreadable, empty
  or invalid credentials fail startup before the listener starts. Creation
  rechecks the empty table inside the write transaction. Once any users exist,
  all bootstrap inputs are ignored without validation or secret-file access,
  including after restart or when every user is disabled. Bootstrap never
  issues a device token, and credential-bearing server descriptions redact
  their values.
- **Invites.** Single-use and hashed at rest. `INVITE_TTL_DAYS = 7` is the
  default and the maximum.
  - The link is `monkeyspaw://join?server=<MONKEYSPAW_PUBLIC_URL>&token=<t>`.
    Pasting the link or the bare token into the app works.
  - Desktop scheme registration: `CFBundleURLTypes` on macOS;
    `MimeType=x-scheme-handler/monkeyspaw` in the `.desktop` file on Linux,
    which routes to the GApplication `open` handler.
  - There is no open registration.
  - Owners and admins may issue editor/viewer group invites; only admins may
    issue account-only invites. HTTP cannot issue owner invites. Issuance
    rechecks the active session, account kind and group authority inside the
    write transaction. Issued invites remain valid until consumed or expired,
    even if their issuer later loses authority; deleted groups cannot be joined.
  - Unknown, expired or consumed tokens return `400 malformed_request`.
    Account-only tokens cannot be used with `/groups/join`. Registration
    creates a member account, its device and any membership while consuming
    the invite in one serialized write. A username collision, device failure
    or audit failure rolls back consumption and every related mutation.
  - Existing-account join retains an existing higher role and `joined_at`,
    or grants the invite role when it is higher. Admins cannot self-add or
    elevate even with an invite (`403 forbidden`); a denied attempt leaves
    the token usable. A deleted group returns 404 without consuming the token.
  - `MONKEYSPAW_PUBLIC_URL`, when set, must be an absolute HTTP(S) URL with a
    host and no credentials or fragment. Server issuance provides a one-time
    link for CLI output; the unchanged HTTP DTO exposes the token and clients
    construct the link. Both query values use percent encoding of everything
    except RFC 3986 unreserved characters, including nested `&`, `+` and `%`.
    Without a public URL, issuance still provides the bare token.
- **Brute force.**
  - Independent canonical-username and canonical-IP buckets live in
    `login_account_buckets` and `login_ip_buckets`, including unknown users.
    Every failed credential check updates both in one transaction. Failures
    one through four return 401. The fifth starts `LOGIN_INITIAL_LOCK = 30 s`
    and returns 429; each failure after the previous lock expires doubles it
    to `LOGIN_MAX_LOCK = 15 min`. Attempts while either bucket is locked do
    no bcrypt work, do not extend locks, and return 429 with `Retry-After`
    rounded up to integer seconds (1–900), using the longer remaining lock.
  - A bucket decays to zero after `LOGIN_DECAY_INTERVAL = 15 min` of quiet
    time measured from its last failure or lock expiry, whichever is later.
    Locked attempts and successful logins do not advance the IP bucket's
    clock. A successful login deletes only the account bucket, atomically
    with device creation; it leaves every IP failure and lock intact. Expired
    locks retain their failure step until decay. State survives restart;
    clock rollback does not clear history or shorten existing locks.
  - Each admitted request performs at most one cost-12 bcrypt verification.
    A process admits at most `LOGIN_CONCURRENT_REQUESTS = 4` login attempts
    and only one for a given account or IP at a time. Busy admission returns
    429 with `Retry-After: 1`, unless a persisted lock requires a longer delay;
    it does not queue or change persistent buckets.
    Bcrypt stays outside the database writer; completion rechecks both locks
    and the enabled account's verified hash before issuing a device token.
  - Volumetric limits sit at the reverse proxy.
  - `MONKEYSPAW_TRUSTED_PROXIES` is a comma-separated list of numeric IPv4/
    IPv6 addresses or CIDRs, empty by default (no trusted peers). Invalid
    configuration fails startup without echoing its values. Only an explicit
    trusted socket peer enables `X-Forwarded-For`: combine repeated fields
    in wire order, walk right to left through trusted hops, and use the first
    untrusted address. Ignore any prefix left of that address. Untrusted
    peers' headers are ignored. A missing, malformed or oversized trusted
    suffix falls back to the socket peer. IPv6 spelling and
    IPv4-mapped IPv6 normalize to one bucket key. Scoped addresses, hostnames,
    ports, brackets and NUL are rejected. Configuration permits at most 64
    entries/4096 bytes; trusted suffix inspection at most 64 hops/8192 bytes.
    Prefixes left of the first untrusted address are neither parsed nor
    counted toward these bounds, so spoofed prefixes cannot select a
    different IP bucket.
- **TLS.** Terminated by Caddy (`tls` profile, site address
  `MONKEYSPAW_PUBLIC_URL`) or the operator's proxy.
  - The server speaks plain HTTP on the compose network only.
  - Without the `tls` profile, the port binds to `127.0.0.1` by default.
  - The desktop client refuses plain `http://` except on loopback and
    private-network addresses, and warns even then.

### 8.6 Deployment (compose + update.sh)

Files at the repo root, in fleet house style (dl-tool is the model):

- **`compose.yaml`.**
  - Service `monkeyspaw-server`:
    - `image: monkeyspaw-server:local` + `pull_policy: build` +
      `build: {context: ., dockerfile: server/Dockerfile}`
    - `${CONFIG_DIR:-./config}/monkeyspaw:/data`
    - port `${MONKEYSPAW_BIND_ADDRESS:-127.0.0.1}:${MONKEYSPAW_PORT:-8790}:8080`
    - healthcheck `monkeyspaw-server healthcheck`, `restart: unless-stopped`,
      `no-new-privileges`
    - effective `user: ${PUID:-1000}:${PGID:-1000}`; the image refuses UID 0
      before starting the server. Prepare the bind directory on the host
      with that ownership and mode 0700. Missing directories fail instead of
      being created by Docker as root; there is no runtime ownership repair.
  - Environment-sourced compose `secrets:` (`admin_password`, read through
    `MONKEYSPAW_ADMIN_PASSWORD_FILE=/run/secrets/admin_password`), so
    `docker inspect` shows paths, not values. The secret file has the effective
    UID/GID and mode 0400. Keep the source `.env` at 0600; Compose secrets do
    not encrypt it or protect the secret from the Docker host operator.
  - Profile `tls`: `caddy:2` on 80/443 with
    `deploy/caddy/Caddyfile.example`. Caddy also runs with `PUID`/`PGID` and
    private host binds under `${CONFIG_DIR:-./config}/caddy/{data,config}`
    for certificates and state. An isolated network namespace allows its
    non-root process to bind 80/443 without added capabilities.
    Its startup guard rejects UID 0 and non-HTTPS public URLs, with umask 077;
    the guard runs only when Caddy starts, not during Compose interpolation.
    The dedicated bridge defaults to `172.30.80.0/29`, with server at
    `172.30.80.2` and Caddy at `172.30.80.3`; trust only the Caddy peer
    (`172.30.80.3/32`), never all private networks. Fixed addresses keep
    Caddy's peer reserved without TLS. If the subnet conflicts, change the
    subnet, both addresses and trusted peer together. Set
    `MONKEYSPAW_PUBLIC_URL` to the bare HTTPS
    origin for the configured domain, with no path, query or fragment.
  - Every tunable is `${VAR:-default}`, documented inline. No `${VAR:?}` in
    profile-gated services (dl-tool lesson).
  - Requires Docker Compose ≥ 2.20.0: this is the minimum supported release,
    including the environment-secret permission fix, `pull_policy: build`
    and `up --wait --wait-timeout`. The v2.20.0 `create.go` also consults
    explicit `bind.create_host_path: false` and uses the Mount API for it
    (verified against upstream release/source, not just schema keys).
    Host directory provisioning remains mandatory; validate missing-path
    refusal on the target Engine/Compose combination and do not replay a
    rendered config as the deployment file.
    YAML/static validation does not prove a container deployment; CI or the
    owner must run both default and TLS configurations on a Docker host.
- **`.env.example`.** `PUID`, `PGID`, `TZ`, `CONFIG_DIR`,
  `MONKEYSPAW_BIND_ADDRESS`, `MONKEYSPAW_PORT`, `MONKEYSPAW_PUBLIC_URL`
  (invite links and the Caddy site), `MONKEYSPAW_ADMIN_USERNAME`,
  `MONKEYSPAW_ADMIN_PASSWORD` (compose mounts it as the secret file read via
  `MONKEYSPAW_ADMIN_PASSWORD_FILE`), `MONKEYSPAW_TRUSTED_PROXIES`,
  `MONKEYSPAW_LOG_LEVEL`, `MONKEYSPAW_PROXY_SUBNET`, `MONKEYSPAW_SERVER_IP`,
  `MONKEYSPAW_CADDY_IP`,
  and a commented `COMPOSE_PROFILES=tls`. Defaults are UID/GID 1000, UTC,
  `./config`, `127.0.0.1:8790`, `http://localhost:8790`, admin user `admin`,
  an empty bootstrap password (must be supplied on an empty database),
  `172.30.80.3/32`, log level `info`, and the bridge addresses above.
  Container paths `/data`, `/run/secrets/admin_password` and listener
  `0.0.0.0:8080` are fixed by this deployment. Stored timestamps remain UTC
  regardless of `TZ`. Run only one server process per database on local disk.
- **`update.sh`.**
  1. `cd` to its own dir; warn on a missing `.env`.
  2. `gh` from PATH or next to the checkout (`../gh`, `../bin/gh`,
     `../gh*/bin/gh`).
  3. Check out the named branch, then `gh repo sync --branch` with a
     `git pull --ff-only` fallback.
  4. Preserve the `tls` profile by inspecting services (configured or
     running `caddy`), not profile-scoped `ps`.
  5. `docker compose pull` (external images only).
  6. `docker compose build --pull`.
  7. `docker compose up -d --remove-orphans --wait --wait-timeout 120`.
  8. `docker image prune -f`.
  9. `docker compose ps`.
  It must be shellcheck-clean and bash 3.2 safe.
- **`server/Dockerfile`.**
  - Build stage `swift:6.4-noble`: `swift build -c release
    --static-swift-stdlib`, with a SwiftPM cache mount.
  - Runtime stage `ubuntu:noble` with `tini`, a non-root `monkeyspaw` user,
    fixed UID/GID 1000, private `/data` owned by it, timezone data, and
    `HEALTHCHECK`. The entrypoint rejects UID 0 and sets umask 077 before
    executing the server; it never changes bind ownership.
  - `ARG VERSION=dev REVISION=unknown CREATED=1970-01-01T00:00:00Z` and OCI
    labels.
- **Migrations.** `serve` migrates first. Migrations are forward-only, and
  `monkeyspaw-server migrate` applies pending migrations and exits nonzero
  on failure. Each migration's DDL, data and applied marker commit in one
  transaction; failures roll back and retries are idempotent.
  `MONKEYSPAW_DATA_DIR` defaults to `/data`; the database is
  `monkeyspaw.db` inside it on local disk. Before any transaction, opening
  the database sets and verifies persistent `journal_mode=WAL`. Every
  checked-out connection sets and verifies `foreign_keys=ON`, a 5-second
  `busy_timeout`, and `synchronous=FULL`. A serial writer gate uses
  `BEGIN IMMEDIATE`; a separate pool serves concurrent, query-only readers.
  Shutdown closes both pools. The process must finish migrating before it
  starts the HTTP listener, and fails startup if initialization or migration
  fails (§19 B6). Schema rollback is transaction rollback on failure;
  successful migrations are forward-only and operator rollback uses a
  stopped-server backup restore, not automatic down migrations.
- **Backups.**
  - `monkeyspaw-server backup /data/backups/<UTC>.db` uses `VACUUM INTO`, a
    consistent online snapshot.
  - `scripts/backup.sh` wraps it through `docker compose exec` and keeps
    `BACKUP_KEEP = 14`.
  - Restores go only through `monkeyspaw-server restore`, which rotates
    `database_id` so every client resnapshots.
  - Never copy a live database file. A Litestream sidecar is documented as
    an option, not shipped.
- **Image publishing.** `release.yml` pushes
  `ghcr.io/l-k-m/monkeyspaw-server:{X.Y.Z, X.Y, latest}` (no `latest` for
  prerelease tags) for `linux/amd64` and `linux/arm64`.
  - arm64 builds on the hosted `ubuntu-24.04-arm` runner, not QEMU.
  - The first publish is private and must be made public.
  - `update.sh` still builds locally: repo-owned images are built, never
    pulled.

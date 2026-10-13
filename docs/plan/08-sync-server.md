## 8. Sync server

### 8.1 Data model

```text
-- every *.id below is a ULID string
meta(database_id)                         -- random UUID; rotated by `monkeyspaw-server restore`
users(id, username UNIQUE, display_name, password_hash,
      account_kind ∈ {member, admin}, created_at, disabled_at NULL)
groups(id, name, created_by, created_at)
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
prompt_revisions(prompt_id, rev, author_id, content, created_at, origin, PK(prompt_id, rev))
changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,
        scope_key,                        -- "user:<id>" or "group:<id>"; INDEX(scope_key, seq)
        prompt_id, kind ∈ {upsert, delete, move_out}, at)
scope_floors(scope_key PK, floor_seq)     -- one past the highest purged seq; only ever raised
devices(id, user_id, name, token_hash UNIQUE, created_at, last_seen_at, revoked_at NULL)
invites(token_hash PK, group_id NULL, role, created_by, expires_at, consumed_at NULL)
login_attempts(username, ip, failures, locked_until, PK(username, ip))
audit_events(id, actor_id, action, target, at)   -- admin and owner actions on accounts and memberships
```

The first migration also runs raw SQL, because Fluent cannot express partial
indexes:

```sql
CREATE UNIQUE INDEX prompts_user_path  ON prompts(owner_id, path_key) WHERE deleted_at IS NULL AND scope = 'user';
CREATE UNIQUE INDEX prompts_group_path ON prompts(group_id, path_key) WHERE deleted_at IS NULL AND scope = 'group';
PRAGMA journal_mode = WAL;   -- persistent; set once
```

- **Path uniqueness** is per scope, case-insensitive, and
  normalization-insensitive, through `path_key`. SQLite treats NULLs as
  distinct, hence one partial index per scope. Two files that differ only in
  case, or in NFC vs NFD, would overwrite each other on a case-insensitive
  disk (APFS).
- **History.** Every accepted write appends a `prompt_revisions` row, and
  `prompts` holds the materialized head. The desktop's local history (§5.5)
  stays local. The server history is the shared, durable record.
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
- **Time.** Every stored timestamp is UTC ISO-8601.

### 8.2 Roles and permissions

| Action | Private prompt | Group `viewer` | Group `editor` | Group `owner` | Admin |
|---|---|---|---|---|---|
| Read, use, sync | owner only | ✓ | ✓ | ✓ | only through memberships, like anyone |
| Create, edit, rename, delete prompts | owner only | ✗ | ✓ | ✓ | as left |
| Move private → group | owner, if `editor`+ in the target | | | | only through memberships |
| Move group → private | | ✗ | prompt creator only | ✓ | only through memberships |
| Move group → group | | ✗ | creator, if `editor`+ in the target | ✓ (+ `editor`+ in the target) | only through memberships |
| List members, see revision authors | | ✓ | ✓ | ✓ | ✓ |
| Invite (`editor`/`viewer` roles), change roles, remove members | | ✗ | ✗ | ✓ | ✓, except on themselves |
| Owner-role invites | | | | | admin CLI only |
| Rename group | | ✗ | ✗ | ✓ | ✓ |
| Delete group (prompts are deleted; members lose the scope) | | ✗ | ✗ | ✓ | ✓ |
| Create groups | any user (becomes owner) | | | | ✓ |
| Create or disable users, reset passwords | | | | | ✓ |

- **No read endpoint for admins.** Admins have no endpoint that reads a
  prompt directly, and cannot grant themselves membership (403).
  - Every admin or owner action on accounts and memberships is written to
    `audit_events`.
  - The plan is honest about the limit. An admin who can reset passwords,
    and the operator who owns the database, can ultimately read everything.
    SECURITY.md says so: the permission model protects members from each
    other, not from the operator.
- **Out-of-scope reads return 404, not 403**, so ids don't leak.
- **Viewers writing get 403.**
- **A group always keeps at least one owner.** Removing or demoting the last
  owner is refused.
- **Disabled users.** All of their tokens fail with 401. Their prompts and
  memberships are kept.

### 8.3 API (v1, JSON, `Authorization: Bearer <device token>`)

| Method and path | Purpose |
|---|---|
| `GET /api/health` | Liveness and version; no auth (Docker healthcheck) |
| `POST /api/v1/auth/login` `{username, password, device_name}` | `{device_token, user}`. Rate-limited (§8.5). |
| `POST /api/v1/auth/logout` | Revokes this device's token; `200 {}` |
| `POST /api/v1/auth/register` `{invite_token, username, password, device_name}` | Consumes an invite and joins its group with its role. Returns `{device_token, user}`. |
| `POST /api/v1/auth/password` `{current_password, new_password}` | Change own password; revokes all other devices; `200 {}` (B9) |
| `GET /api/v1/me` | `{user, groups, devices}`; caller device metadata only (B9) |
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
| Denied visible write | `403 {code: "forbidden"}` | Includes viewer writes. |
| Missing or invisible resource | `404 {code: "not_found"}` | No inaccessible identity or prompt data is returned. |
| Request envelope overflow | `413 {code: "envelope_too_large"}` | HTTP JSON bytes exceed 2 MiB (B3). |
| Login locked | `429 {code: "rate_limited"}` | Required `Retry-After` header: integer seconds, 1–900 (B3/B8). |
| Internal failure | `500 {code: "internal_error"}` | Sanitized; no underlying error text (B3). |
| Expired/restarted frozen snapshot | `409 {code: "snapshot_expired", scopes: [scope_key]}` | The client discards the entire incomplete collected pull and restarts affected scopes without their cursors (B17). |

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
- Admin create takes `{username, password, display_name?, account_kind?}`,
  defaults to member, and returns user metadata. Admin patch takes a nonempty
  subset of `{display_name, password, disabled, account_kind}`. Omitted values
  are unchanged; `display_name: null` clears it; password resets and disable
  revoke devices per B9. Other optional fields reject explicit null.
- Group create/rename take `{name}` and return
  `{id, name, created_by, created_at}`; delete returns `{}`. Membership PUT
  takes `{role}` and explicitly adds or changes an existing user. It returns
  `{user_id, username, display_name, role, joined_at}`; list wraps these in
  `{members}` and removal returns `{}`. `/me` and `/groups/join` group metadata
  is `{group_id, name, role}`. Roles are owner/editor/viewer; permission and
  last-owner checks remain transactional server responsibilities.
- Admin invites take `{expires_in?}` for an account-only invite, or
  `{group_id, role, expires_in?}` for a group invite. Responses expose
  `{invite_token, expires_at, group_id?, role?}` once. Account-only invites
  omit both union fields; group invites require both. HTTP invite roles are
  editor/viewer; owner invites remain CLI-only. Tokens use 32 random bytes
  as unpadded base64url, and clients construct the §8.5 join link.
- Usernames in every request and response, including login, are 1–64 lowercase
  ASCII letters, digits, dots, underscores or hyphens, beginning with a letter
  or digit. DTOs reject uppercase rather than normalize it; stored usernames
  use the same rule for uniqueness (B7). Names are 1–255 Unicode scalars and
  display names 0–255. All password fields are at most 72 decoded UTF-8 bytes
  to avoid bcrypt truncation; new passwords require at least 12 scalars, while
  login/current-password strings are nonempty.
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

`MAX_PROMPT_BYTES = 256 KiB` bounds decoded prompt UTF-8, separately from the
2 MiB HTTP request envelope and 16 MiB serialized pull response cap (B3).
DTOs validate wire shape; shared content/path validators still produce the
semantic 422 issues. Every prompt `path`, including move, revision, conflict
head and feed payloads, is nonempty and at most `Limits.maxPathBytes` (1,024
decoded UTF-8 bytes) at the DTO boundary. Full path rules and normalization
remain with `SyncPathValidator` (§8.4). Transport header/body limits are
enforced by later server slices, not by an unbounded Foundation JSON encoder.

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
    only key/kind, while group metadata requires group_id/name/role. Group
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
  `PASSWORD_MIN_LENGTH = 12`.
- **Device tokens.**
  - 32 random bytes, base64url. The server stores only SHA-256(token) and
    looks tokens up by hash.
  - `last_seen_at` is updated at most every
    `DEVICE_SEEN_UPDATE_INTERVAL = 5 min`.
  - Clients keep the token in the OS secret store.
- **Bootstrap.** On an empty `users` table, the server creates an admin from
  `MONKEYSPAW_ADMIN_USERNAME` and the compose secret file
  `MONKEYSPAW_ADMIN_PASSWORD_FILE`. Once users exist, both are ignored.
- **Invites.** Single-use and hashed at rest. `INVITE_TTL_DAYS = 7` is the
  default and the maximum.
  - The link is `monkeyspaw://join?server=<MONKEYSPAW_PUBLIC_URL>&token=<t>`.
    Pasting the link or the bare token into the app works.
  - Desktop scheme registration: `CFBundleURLTypes` on macOS;
    `MimeType=x-scheme-handler/monkeyspaw` in the `.desktop` file on Linux,
    which routes to the GApplication `open` handler.
  - There is no open registration.
- **Brute force.**
  - Per account and per IP: after `LOGIN_FREE_ATTEMPTS = 5` failures,
    exponential backoff up to `LOGIN_MAX_LOCK = 15 min`, persisted in
    `login_attempts`.
  - Volumetric limits sit at the reverse proxy.
  - The client IP comes from `X-Forwarded-For` only when the peer is in
    `MONKEYSPAW_TRUSTED_PROXIES`.
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
  - Environment-sourced compose `secrets:` (`admin_password`, read through
    `*_FILE`), so `docker inspect` shows paths, not values.
  - Profile `tls`: `caddy:2` on 80/443 with
    `deploy/caddy/Caddyfile.example`.
  - Every tunable is `${VAR:-default}`, documented inline. No `${VAR:?}` in
    profile-gated services (dl-tool lesson).
  - Requires Docker Compose ≥ 2.20, which covers environment-sourced secrets,
    `pull_policy`, and `up --wait`. The README says so.
- **`.env.example`.** `PUID`, `PGID`, `TZ`, `CONFIG_DIR`,
  `MONKEYSPAW_BIND_ADDRESS`, `MONKEYSPAW_PORT`, `MONKEYSPAW_PUBLIC_URL`
  (invite links and the Caddy site), `MONKEYSPAW_ADMIN_USERNAME`,
  `MONKEYSPAW_ADMIN_PASSWORD` (compose mounts it as the secret file read via
  `MONKEYSPAW_ADMIN_PASSWORD_FILE`), `MONKEYSPAW_TRUSTED_PROXIES`,
  `MONKEYSPAW_LOG_LEVEL`, and a commented `COMPOSE_PROFILES=tls`.
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
    `/data` owned by it, and `HEALTHCHECK`.
  - `ARG VERSION=dev REVISION=unknown CREATED=1970-01-01T00:00:00Z` and OCI
    labels.
- **Migrations.** `serve` migrates first. Migrations are forward-only, and
  each runs in a transaction.
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

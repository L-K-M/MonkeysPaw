# Server deployment acceptance

These owner checks complement the [Compose smoke CI gate](../../.github/workflows/ci.yml)
and [§15 M5 acceptance](../plan/15-milestones.md). All checks below are
**NOT RUN**. Record results against the exact deployed commit; static checks
and fake curl tests cannot establish a Docker or HTTPS deployment. `update.sh`
(S19) and backup/restore (S16/S17) must land before their checks can run.
Desktop checks wait for M6 and do not replace the M5 API smoke.

- Commit / image version / CI run:
- Host OS / Docker Engine / Compose version (at least 2.20.0):
- Date / tester:
- HTTPS domain / certificate issuer and expiry (no private keys):
- Result / sanitized failure notes for each row below:

## Fresh host via update.sh: NOT RUN

Use a clean checkout on a Linux Docker host with local disk for SQLite and
no existing Monkey's Paw database. Follow [README hosting](../../README.md#host-the-sync-server)
and [.env.example](../../.env.example). Run one server process per database.

1. Set `umask 077`, copy `.env.example` to `.env`, and confirm mode 0600.
   Edit the file privately to supply a bootstrap admin password. Keep secrets
   out of shell history, argv, logs and this results record. Leave the HTTP
   bind at `127.0.0.1` and `COMPOSE_PROFILES` unset for this first run.
2. Provision `CONFIG_DIR/monkeyspaw` with the configured PUID/PGID ownership
   and mode 0700 (defaults: `sudo install -d -m 0700 -o 1000 -g 1000 ./config/monkeyspaw`).
   Confirm a missing bind directory fails rather than being created by Docker;
   then provision it before continuing. Verify default and overridden non-root
   ownership on a disposable deployment and confirm UID 0 is refused.
3. Run `./update.sh` using its documented branch selection. Confirm nonzero
   failures remain failures, the local server image is built without GTK,
   `docker compose ps` reports a healthy server, and no Caddy service runs.
4. Run `curl --fail --silent --show-error --connect-timeout 5 --max-time 15 http://127.0.0.1:8790/api/health`.
   Require HTTP 200 with `status: ok` and a nonempty version; adjust the port
   if configured. Confirm the HTTP port is unreachable from another host.
5. Record the CI run where `compose-smoke` passed health, bootstrap login,
   private prompt creation/read, snapshot and update/delta. That gate uses
   a disposable database; do not point its script at your working library.

## Real-domain HTTPS and two update re-runs: NOT RUN

1. Point a real domain at this host and permit TCP 80 and TCP/UDP 443.
   Set the bare HTTPS `MONKEYSPAW_PUBLIC_URL` and `COMPOSE_PROFILES=tls`
   privately in `.env`. Keep the server's host publication on loopback.
2. Provision `CONFIG_DIR/caddy/data` and `CONFIG_DIR/caddy/config` with the
   same PUID/PGID and mode 0700. Keep these directories across updates; they
   hold certificate keys and Caddy state. Use only the documented Caddy peer
   in `MONKEYSPAW_TRUSTED_PROXIES`, adjusting all bridge addresses together
   if the subnet conflicts with host routes.
3. Run `docker compose --profile tls config --quiet`, then `./update.sh`.
   Require a healthy server and running Caddy. From another host, request
   `https://YOUR_DOMAIN/api/health` with curl's connection/total deadlines;
   require 200 and a publicly trusted, hostname-matching certificate. Never
   use `--insecure`. Confirm HTTP redirects to HTTPS.
4. Record the certificate fingerprint/expiry and the persistent bind paths,
   then run `./update.sh` twice. After **each** run, require running Caddy,
   a healthy server, trusted HTTPS health and unchanged persistent paths.
   Confirm existing certificate state is reused and no files are lost;
   an ordinary re-run should not request a new certificate unless renewal
   is due. Record both results and any expected renewal.
5. Test running-profile preservation too: remove `COMPOSE_PROFILES=tls`
   from `.env` while Caddy is running, rerun `./update.sh`, and confirm Caddy
   and HTTPS survive. Restore the explicit profile setting afterward.
   Record certificate renewal when due; initial issuance alone is no proof
   of renewal.

## Backup/restore drill: NOT RUN

Use a disposable copy of the deployment with seeded prompts, never the only
working database. Wait for the S16/S17 commands and follow [§8.6](../plan/08-sync-server.md#86-deployment-compose--updatesh).

1. Run an online `monkeyspaw-server backup <path>` through `docker compose exec`
   while making a test write. Keep the consistent snapshot private and verify
   that it is usable. Never copy a live database or its WAL as a backup.
2. Record the current `database_id` and seeded prompt id/rev/path/content
   privately. Make a later edit to distinguish the backup from the live head.
3. Stop serve with `docker compose stop monkeyspaw-server`. Restore with a
   one-shot `docker compose run --rm --no-deps monkeyspaw-server restore <path>`
   using a backup path accessible inside its bind. Do not use `compose exec`
   to restore while serve holds the database open. Require rejected corrupt,
   newer-schema or live-database restores to leave the original data intact.
4. Restart with `docker compose up -d --wait --wait-timeout 120`. Require
   healthy HTTP/HTTPS, restored prompt bytes and a changed `database_id`.
   Pull with the old identity/cursors and require a snapshot, preserving data.
   Record backup date/hash, restored commit, identity rotation and outcome,
   without recording prompt content or credentials in this checklist.

## Desktop login, push and pull after M6: NOT RUN

1. Sign in through Settings: Account to the real HTTPS origin on a desktop.
   Confirm device registration and sync status without logging its token.
2. Create a private prompt on that desktop; sign in on a second device and
   require its initial snapshot to preserve id, revision, path and exact bytes.
3. Edit and rename on the first device. Require the second device's delta to
   preserve the id, advance the revision, update content and remove the old
   path. Repeat after a server update, and after the disposable restore drill;
   database identity rotation must trigger resnapshot without data loss.
4. Record desktop versions, deployed commit and outcomes. The two-user group
   sharing checks remain the separate [§15 M6 acceptance](../plan/15-milestones.md).

## Client filenames after M6: NOT RUN

§8.4 requires client sanitization before group names become local folder
names or device names appear in filenames. M6/M10 now supply the
[automated client proof](m5-acceptance.md#m5-server-acceptance). The checks
below still require native/deployed observations on disposable data; record
the client version, platform and resulting paths without prompt contents.

| Check | Status | Required observation |
|---|---|---|
| Group names | **NOT RUN** | Names with separators, traversal/dot components and Unicode normalize into safe client folder names without leaving or overwriting the library. |
| Device names | **NOT RUN** | A device name containing separators/control characters cannot create an unsafe filename when the client includes it in a local path. |

## Host the sync server

Use Docker Engine on Linux with BuildKit enabled and **Docker Compose
2.20.0 or newer** (`docker compose version`). This minimum includes the
[environment-secret permission fix](https://github.com/docker/compose/releases/tag/v2.20.0),
local image builds and bounded health waits. The server is built from this
checkout as `monkeyspaw-server:local`; Caddy is the external `caddy:2` image.
The owner removed GHCR publication on 2026-10-19; registry distribution is
not provided yet. For a separate versioned local image, run
`scripts/build.sh server-image` from the repository root. It stays in the
active Docker engine's image store; Compose builds its own `:local` image.

Prepare the default deployment from the repository root:

```sh
umask 077
cp .env.example .env
sudo install -d -m 0700 -o 1000 -g 1000 ./config/monkeyspaw
```

Edit the private `.env` before starting. Supply `MONKEYSPAW_ADMIN_PASSWORD`
with at least 12 Unicode scalars and at most 72 UTF-8 bytes. Quote passwords
using Compose's `.env` syntax; use single quotes for literal `$` or `#`.
The username defaults to `admin`. Compose exposes the password to the server
only as `/run/secrets/admin_password`, owned by `PUID`/`PGID` with mode 0400;
`MONKEYSPAW_ADMIN_PASSWORD_FILE` points there. The password is absent from
the server container's environment and `docker inspect`, but remains
plaintext in `.env` and in Compose's secret file. Keep `.env` at 0600 and
keep it out of logs and version control. Bootstrap runs only on an empty
database; editing these values later does not reset an account's password.
Some Compose versions warn that secret UID/GID/mode settings are ignored.
That warning is spurious for this environment-sourced secret, whose file
is created with those settings. File-sourced secrets have different behavior.

```sh
docker compose config --quiet
docker compose up -d --build --wait --wait-timeout 120
curl --fail http://127.0.0.1:8790/api/health
```

The HTTP port defaults to `127.0.0.1:8790`. Every setting and default is in
[.env.example](../../.env.example). `PUID` and `PGID` default to 1000 and set the
effective container user, rather than just environment hints. To use other
IDs, set them in `.env` and provision the host directories with matching
owners and mode 0700. The server entrypoint refuses UID 0. It never changes
host ownership; missing bind directories fail startup. `CONFIG_DIR` defaults
to `./config`; use local disk, not a network filesystem, for SQLite. Mounts
replace the image's `/data`, so its build-time owner cannot fix a host bind.
Stored timestamps remain UTC regardless of `TZ`.
Provision these directories before every fresh deployment; do not use
rendered `docker compose config` output as a replacement deployment file.
Verify missing-path refusal on your actual Engine/Compose combination.

For public HTTPS, point a domain's DNS at this host and allow TCP 80 and
TCP/UDP 443. Set `MONKEYSPAW_PUBLIC_URL=https://prompts.example.com` to your
bare HTTPS origin, with no path, query or fragment, and enable
`COMPOSE_PROFILES=tls` in `.env`. Prepare Caddy's certificate and state directories, using your
chosen `CONFIG_DIR`, `PUID` and `PGID` (defaults shown):

```sh
sudo install -d -m 0700 -o 1000 -g 1000 ./config/caddy/data ./config/caddy/config
docker compose --profile tls config --quiet
docker compose --profile tls up -d --build --wait --wait-timeout 120
curl --fail https://prompts.example.com/api/health
```

Caddy refuses startup with UID 0 or a non-HTTPS public URL. The check runs
only when Caddy starts, so default non-TLS Compose configuration still works.

[Caddyfile.example](../../deploy/caddy/Caddyfile.example) obtains and renews
certificates through [Caddy's automatic HTTPS](https://caddyserver.com/docs/automatic-https).
Caddy runs as the configured UID/GID with no added capabilities; a container
network sysctl permits its non-root listeners on 80/443. Leave the server's
host publication on loopback even with TLS. The dedicated bridge defaults
to `172.30.80.0/29`, Caddy's fixed address to `172.30.80.3`, and the server's
trusted proxies to that peer alone (`172.30.80.3/32`). Caddy
[discards incoming forwarded headers](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#defaults)
before supplying its own. If the subnet overlaps a host or VPN route,
change `MONKEYSPAW_PROXY_SUBNET`, `MONKEYSPAW_SERVER_IP` (default
`172.30.80.2`), `MONKEYSPAW_CADDY_IP` and `MONKEYSPAW_TRUSTED_PROXIES`
together. The server has a fixed address so it cannot take Caddy's peer while
TLS is disabled. Do not attach unrelated containers to
this bridge or trust all private networks. When using your own proxy, trust
only its observed peer address and ensure it strips client-supplied forwarded
headers; set the public URL to the origin your clients use. Never expose
plain HTTP directly to the Internet. Apply any needed volumetric rate limits
at your public ingress; this example Caddyfile does not add a rate limiter.

Run **one server process per database**. Compose is a single-host deployment,
not a replicated service. The server stores prompt content, history and
backups as plaintext SQLite data, with no end-to-end encryption. Encrypt
disks and backups yourself. The host operator can read all prompts; an admin
who resets an account's password can also access that account. API permissions
protect users from each other, not from the operator. Passwords are bcrypt
hashes and device tokens are hashed. Protect Caddy's certificate keys too.
Neither the server nor this Caddyfile enables request access logs; never add
logging of credentials, tokens, prompt bodies or field values.

Take consistent online snapshots with `scripts/backup.sh` or
`monkeyspaw-server backup`, and restore only with the server stopped; restore
rotates the database identity so clients resnapshot (see
[Server backup and restore](#server-backup-and-restore) and
[deployment plan §8.6](../plan/08-sync-server.md#86-deployment-compose--updatesh)).
Never copy a live SQLite database. Keep a verified, private backup before
upgrades; migrations are forward-only.

After preparing `.env` and the host directories above, use the root updater
for a fresh deployment or an upgrade. Install Git and optionally the GitHub
CLI (`gh`); the updater searches PATH, `../gh`, `../bin/gh`, then
`../gh*/bin/gh`. Run from the checkout or invoke its path from any directory:

```sh
./update.sh main
curl --fail http://127.0.0.1:8790/api/health
```

The branch argument defaults to `main`. The updater refuses tracked or
untracked local changes and commits ahead of or diverged from the fetched
`origin` branch; resolve them manually before retrying. It checks out the
named branch and refuses a branch/tag collision that leaves a detached HEAD.
It uses `gh repo sync --branch`, falling back to
`git pull --ff-only origin <branch>` if `gh` is unavailable or sync fails.
It pulls only external images, builds the server with fresh base images,
waits up to 120 seconds for startup health, prunes dangling Docker images,
and shows Compose status. A failure stops later steps and exits nonzero;
completed steps are not rolled back automatically.

For the owner TLS check, configure HTTPS and provision Caddy as above,
then run `./update.sh main` twice and check your HTTPS `/api/health` after
each run. Confirm unprofiled `docker compose ps --services --status running`
still lists `caddy`. Check both persisted `COMPOSE_PROFILES=tls` and Caddy
started only with `--profile tls` (with `COMPOSE_PROFILES` unset in `.env`
and the environment); the updater preserves either by inspecting services.
CI's fake-command tests verify the updater without operating a deployment;
the fresh-host and TLS re-run checks require an owner Docker host.

Deployment validation needs a Docker host: run both Compose configurations,
check default and overridden ownership, confirm UID 0 fails, and exercise
HTTPS certificate issuance, renewal and restart. YAML/static checks on the
implementation host do not prove a real Compose run. CI builds the server
image and checks `/api/health`; the Compose smoke gate and owner HTTPS check
complete runtime verification in subsequent M5 slices.

## Server backup and restore

The server supports one serving process on local SQLite storage, with no
replicas. For a compose deployment, run `scripts/backup.sh` from the checkout
or any other directory. It creates `/data/backups/<UTC timestamp>.db` through
the running server's CLI and keeps the newest 14 successful backups. Set
`BACKUP_KEEP` to a positive integer to change retention. A failed backup
preserves existing backups. To choose a path yourself:

```sh
docker compose exec -T monkeyspaw-server monkeyspaw-server backup /data/backups/manual.db
```

Backup refuses existing paths. Both commands accept `--json` for path and
database identity metadata; restore also reports its previous database's
recovery path. Backups contain plaintext prompts and credential hashes.
Protect the data volume and backup copies; volume encryption and off-host
copies are your responsibility. Never copy a live database file.

Stop the server before restoring a backup that is accessible inside `/data`:

```sh
docker compose stop monkeyspaw-server
docker compose run --rm --no-deps monkeyspaw-server monkeyspaw-server restore /data/backups/20261013T120000Z.db --json
docker compose up -d monkeyspaw-server
```

Start the server only after restore succeeds. Restore refuses a live database,
invalid SQLite files, foreign databases and schemas newer than the binary.
It migrates a staged snapshot and rotates `database_id` before replacement,
so every client resnapshots. The previous database remains at the reported
`monkeyspaw.pre-restore-<UUID>.db` path, outside automatic backup retention;
remove it after verifying the restore. Restore that recovery file through the
same stopped-server procedure if needed. Keep `/data/.monkeyspaw.lock` in
place so serving and maintenance commands share the same lock.

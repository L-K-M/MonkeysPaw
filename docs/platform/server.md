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
   bind at `127.0.0.1` for this first run.
2. Provision `CONFIG_DIR/monkeyspaw` with the configured PUID/PGID ownership
   and mode 0700 (defaults: `sudo install -d -m 0700 -o 1000 -g 1000 ./config/monkeyspaw`).
   Confirm a missing bind directory fails rather than being created by Docker;
   then provision it before continuing. Verify default and overridden non-root
   ownership on a disposable deployment and confirm UID 0 is refused.
3. Run `./update.sh` using its documented branch selection. Confirm nonzero
   failures remain failures, the local server image is built without GTK,
   `docker compose ps` reports only a healthy `monkeyspaw-server` service.
4. Run `curl --fail --silent --show-error --connect-timeout 5 --max-time 15 http://127.0.0.1:8790/api/health`.
   Require HTTP 200 with `status: ok` and a nonempty version; adjust the port
   if configured. Confirm the HTTP port is unreachable from another host.
5. Record the CI run where `compose-smoke` passed health, bootstrap login,
   private prompt creation/read, snapshot and update/delta. That gate uses
   a disposable database; do not point its script at your working library.

## Real-domain HTTPS and two update re-runs: NOT RUN

1. Configure your existing proxy using the
   [Nginx Proxy Manager setup](#nginx-proxy-manager) below. Set the bare HTTPS
   `MONKEYSPAW_PUBLIC_URL` privately in `.env`; keep host HTTP on loopback.
2. Confirm the server shares the proxy's existing Docker network and trusts
   only its stable peer IP. Confirm other peers cannot select a client IP by
   supplying forwarded headers. Retain certificate state in the proxy stack.
3. Run `docker compose config --quiet`, then `./update.sh`.
   Require a healthy server and your running proxy. From another host, request
   `https://YOUR_DOMAIN/api/health` with curl's connection/total deadlines;
   require 200 and a publicly trusted, hostname-matching certificate. Never
   use `--insecure`. Confirm HTTP redirects to HTTPS.
4. Record the certificate fingerprint/expiry and proxy network, then run
   `./update.sh` twice. After **each** run, require a healthy server, trusted
   HTTPS health and the same external network. Confirm the proxy container
   and its certificate state were not replaced by the server update.
5. Record certificate renewal in your proxy when due; initial issuance alone
   is no proof of renewal.

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
checkout as `monkeyspaw-server:local`. Compose runs only that server; use your
existing reverse proxy for HTTPS.
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

### Nginx Proxy Manager

Use the existing Docker network of your Nginx Proxy Manager container on the
same host. This follows NPM's [shared-network setup](https://nginxproxymanager.com/advanced-config/#best-practice-use-a-docker-network)
and keeps the server's host port on loopback. List networks with
`docker network ls`; identify the one attached to the proxy container.

Copy the network override from the repository root. If an override already
exists, merge its network settings instead of replacing it:

```sh
cp -n deploy/nginx-proxy-manager/compose.override.yaml.example compose.override.yaml
```

The root `compose.override.yaml` is ignored by Git and loaded automatically
by Compose, including through `update.sh`. Set these values in your private
`.env`, replacing the network and IP placeholders:

```dotenv
MONKEYSPAW_PUBLIC_URL=https://prompts.example.com
MONKEYSPAW_PROXY_NETWORK=YOUR_NPM_NETWORK
MONKEYSPAW_TRUSTED_PROXIES=YOUR_NPM_IPV4/32
```

Find the proxy's address on that network, replacing both placeholders:

```sh
docker inspect NPM_CONTAINER --format '{{with index .NetworkSettings.Networks "YOUR_NPM_NETWORK"}}{{.IPAddress}}{{end}}'
```

Assign that proxy address statically in its own stack so recreation cannot
change it. Use `/128` for an IPv6 peer. Trust only the proxy's exact address,
never its whole network. NPM must append or replace `X-Forwarded-For` with
the actual client's address; its default configuration appends it. The
server walks trusted hops from the right and ignores spoofed prefixes.

Start the server:

```sh
docker compose config --quiet
docker compose up -d --build --remove-orphans --wait --wait-timeout 120
```

Create an NPM **Proxy Host**:

| Setting | Value |
|---|---|
| Domain Names | Your domain, for example `prompts.example.com` |
| Scheme | `http` |
| Forward Hostname / IP | `monkeyspaw-server` |
| Forward Port | `8080` |
| SSL | Select or request a certificate, then enable **Force SSL** |

The proxy uses Docker DNS and container port `8080`, not the host's
loopback port `8790`. Keep the `monkeyspaw-server` network alias unique.
Point public DNS at NPM and manage public ports and certificates there.
Verify `https://prompts.example.com/api/health` with normal certificate
validation. Apply any needed volumetric rate limits at your public ingress.

For an older bundled-Caddy deployment, remove `COMPOSE_PROFILES=tls`,
`MONKEYSPAW_PROXY_SUBNET`, `MONKEYSPAW_SERVER_IP` and `MONKEYSPAW_CADDY_IP`
from `.env`, and replace the old trusted IP with NPM's peer. The updater's
`--remove-orphans` removes the old Caddy container; its host certificate
directories remain. Configure NPM before relying on public HTTPS again.

### Operations

Run **one server process per database**. Compose is a single-host deployment,
not a replicated service. The server stores prompt content, history and
backups as plaintext SQLite data, with no end-to-end encryption. Encrypt
disks and backups yourself. The host operator can read all prompts; an admin
who resets an account's password can also access that account. API permissions
protect users from each other, not from the operator. Passwords are bcrypt
hashes and device tokens are hashed. Protect your proxy's certificate keys
too. The server does not enable request access logs; configure your proxy
to avoid logging credentials, tokens, prompt bodies or field values.

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
It builds the server with fresh base images,
waits up to 120 seconds for startup health, prunes dangling Docker images,
and shows Compose status. A failure stops later steps and exits nonzero;
completed steps are not rolled back automatically.

For the owner TLS check, configure your existing proxy as above,
then run `./update.sh main` twice and check your HTTPS `/api/health` after
each run. Confirm the server remains on the proxy's external Docker network
and the proxy container and certificate state are unchanged.
CI's fake-command tests verify the updater without operating a deployment;
the fresh-host and TLS re-run checks require an owner Docker host.

Deployment validation needs a Docker host: run the default and proxy-network
configurations, check default and overridden ownership, confirm UID 0 fails, and exercise
HTTPS certificate issuance, renewal and restart. YAML/static checks on the
implementation host do not prove a real Compose run. CI builds the server
image and checks `/api/health`; the Compose smoke gate and owner HTTPS check
complete runtime verification.

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

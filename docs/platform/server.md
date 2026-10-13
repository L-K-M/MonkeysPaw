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
names or device names appear in filenames. M5's server tests do not assert
that client boundary. Use disposable data after M6 supplies it; record the
client version, platform and resulting paths without prompt contents.

| Check | Status | Required observation |
|---|---|---|
| Group names | **NOT RUN** | Names with separators, traversal/dot components and Unicode normalize into safe client folder names without leaving or overwriting the library. |
| Device names | **NOT RUN** | A device name containing separators/control characters cannot create an unsafe filename when the client includes it in a local path. |

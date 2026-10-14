# Monkey's Paw

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Latest release:** v<!-- version -->0.1.0<!-- /version --> · [Download](https://github.com/L-K-M/MonkeysPaw/releases/latest)

Monkey's Paw is a prompt repository for macOS, Linux, and Android.
The desktop apps let you pick a prompt, fill its placeholders, and paste
the result into the text field you were using. Prompts live in Markdown files
with YAML front matter, so you can edit them with your own tools. An optional
LLM assistant will help write and improve prompts, and a self-hosted server
will sync them between devices and share them within groups.

The portable Core format APIs preserve unknown front-matter metadata and
exact body bytes. Canonical writing does not preserve comments inside front
matter. Format and grammar conformance cases live under
[`spec/fixtures/`](spec/fixtures/), documented in [`spec/README.md`](spec/README.md).

**Status:** The desktop picker/fill loop, General and Shortcuts Settings,
onboarding and library recovery, Forget controls, Linux tray, five-category
conformance corpus and release workflow are merged per [PLAN.md](PLAN.md).
The v0.1.0 tag and [owner-run platform checks](docs/platform/m2-acceptance.md)
remain before M2 closes. M3 follows with the Library window, editor, history,
import and first-run tour.

## Install on Linux

On Ubuntu 24.04 or newer, download the `.deb` and its `.deb.sha256` from a
release. Run `sha256sum -c monkeyspaw_<version>_<arch>.deb.sha256` in the download directory,
then install with `sudo apt install ./monkeyspaw_<version>_<arch>.deb` and run
`monkeyspaw`. To build a local package, run
`scripts/build.sh deb`; see the
[packaging requirements](docs/plan/14-repository-packaging-ci-release.md).

Prerelease deb filenames use `~` in place of the version's hyphen. For
`v0.1.0-beta.1` on amd64, download `monkeyspaw_0.1.0~beta.1_amd64.deb`
and its `.deb.sha256`, then run:

```sh
sha256sum -c monkeyspaw_0.1.0~beta.1_amd64.deb.sha256
sudo apt install ./monkeyspaw_0.1.0~beta.1_amd64.deb
```

## Install on macOS

Download `MonkeysPaw-<version>.dmg`, `.zip` and `.sha256` from the
[releases](https://github.com/L-K-M/MonkeysPaw/releases). In the download
directory, run `shasum -a 256 -c MonkeysPaw-<version>.sha256`; both archives
must report **OK**. Open the dmg and drag `MonkeysPaw.app` to Applications.
Builds are ad-hoc signed unless the release says otherwise, and are not
notarized. For Gatekeeper approval and installation checks, see the
[macOS checklist](docs/platform/macos.md). Local packaging uses
`scripts/build.sh mac`; the app-only engine remains at `scripts/build.sh app`.

The [CI and release guide](CICD.md) describes dry runs and cutting a release.

## Install and build on Android

Android API 26 or later is required. The Android app keeps its library on
the device, with seeds, a raw editor and history. Use **Keyboard and tile
setup** to enable the picker keyboard and add the Quick Settings tile.
Switch to the picker while typing in another app to insert a prompt;
fields that need typing open a Copy form, and multi-line text in Termux
offers Copy instead. Where offered, the text-selection action uses selected
text in a prompt. Share text to Monkey's Paw to fill a prompt or start an
unsaved new prompt.

The tile, launcher icon's **Insert prompt** shortcut and
**Monkey's Paw: Insert prompt** widget open pick → fill → **Copy**, then
you paste in your target app. Device checks are still pending; see the
[Android checklist](docs/platform/android.md).

When an Android release is published, download `monkeyspaw-v<full-version>.apk`
and its `.apk.sha256` from this repository's
[releases](https://github.com/L-K-M/MonkeysPaw/releases). In that directory:

```sh
version='<full-version>' # Replace with the release version, including any suffix.
sha256sum -c "monkeyspaw-v${version}.apk.sha256" && adb install -r "monkeyspaw-v${version}.apk"
```

On macOS use `shasum -a 256 -c` for the checksum. `adb` requires SDK
platform-tools and USB debugging; alternatively open the verified APK on the
device and allow installation from that source. Both debug and release builds
share the same app ID and [public signer](docs/decisions/0001-android-zero-secret-signing.md),
so they replace one another. Because the signing key is public, any APK
signed with it installs over the app and keeps its data; the signature does
not establish publisher identity. Install only APKs from this repository's
releases. Uninstalling deletes app-private data.
See the [APK verification and upgrade checklist](docs/platform/android.md#release-apk-verification).

To build locally, install JDK 17 or newer (CI uses 17; 21 also works),
Android SDK `platforms;android-37.0` and `build-tools;36.0.0`.
Set `JAVA_HOME` and `ANDROID_HOME` to those installations, then from the
repository root run `scripts/build.sh android --no-open`. It produces
`dist/monkeyspaw-v<full-version>.apk` and `.apk.sha256`. The complete gate is:

```sh
cd android
./gradlew --max-workers=2 :core:test testDebugUnitTest lintDebug assembleDebug assembleRelease
```

The direct Gradle build writes `android/app/build/outputs/apk/debug/app-debug.apk`
and `android/app/build/outputs/apk/release/app-release.apk` relative to the
repository root. If Google Maven times out, set
`MONKEYSPAW_GOOGLE_MAVEN_URL=https://redirector.gvt1.com/edgedl/android/maven2/`
before building.

## Host the sync server

Use Docker Engine on Linux with BuildKit enabled and **Docker Compose
2.20.0 or newer** (`docker compose version`). This minimum includes the
[environment-secret permission fix](https://github.com/docker/compose/releases/tag/v2.20.0),
local image builds and bounded health waits. The server is built from this
checkout as `monkeyspaw-server:local`; Caddy is the external `caddy:2` image.

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
[.env.example](.env.example). `PUID` and `PGID` default to 1000 and set the
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

[Caddyfile.example](deploy/caddy/Caddyfile.example) obtains and renews
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
[deployment plan §8.6](docs/plan/08-sync-server.md#86-deployment-compose--updatesh)).
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

## Assistant privacy and key storage

Assistant requests go to the provider you configured only when you explicitly
choose an action. Write sends your brief. Review and Improve send the current
template source, including front matter; Improve also sends your instruction
and selected findings. An explicit retry can include the session's previous
messages and your feedback. Requests include the app's system instructions,
output schema and model selection. Providers can read what you send and may
charge for it. Fill values, rendered fill previews and remembered values are
never sent. `private: true` blocks Review and Improve for that prompt; Write
sends only your brief, including while a private prompt is open.

Settings → Assistant → Test connection sends an authenticated model-list
request, without prompt content. Saving, renaming or switching a profile does
not send a provider request. No assistant request runs in the background
without your action.

Keys use macOS Keychain, with no plaintext fallback on macOS. Linux uses
Secret Service through `secret-tool`, or a read-only per-profile environment
override. If `secret-tool` is absent, saved keys use
`<config>/secrets-unencrypted.json`, an atomic file with mode 0600. Settings
labels this tier **unencrypted**: anyone who can read the file can read its
keys; file permissions do not encrypt them. An installed but failing secret
service does not silently create a new plaintext key. Keys are never shown
after saving or stored in provider settings, command arguments or logs.
Prompt content, fill values and provider error bodies are also excluded from
logs. Remembered values stay local in private `values.json` and are not synced.

Android encrypts saved API keys with AES-256-GCM using AndroidKeyStore and
keeps only account names, IVs and ciphertext in a separate app-private secrets
DataStore. Provider settings contain references, never keys. StrongBox is
preferred when available; actual hardware backing depends on your device and
is not established by the **keystore** label. There is no plaintext fallback.
The Android assistant follows the explicit request and privacy rules above,
shows the provider host and model before sending, and shows token usage when
the provider returns it. It has no telemetry or HTTP logging. Real Keystore
and Anthropic/Ollama checks remain **NOT RUN (owner)** in the
[Android assistant checklist](docs/platform/android.md#android-assistant-m11-not-run-owner);
M11 remains open until those checks and the final main CI evidence are recorded.

Sync sends prompts to your configured server, with the operator-access limits
described above. See the [security and privacy plan](docs/plan/12-security-and-privacy.md)
and [assistant owner checklist](docs/platform/assistant.md). Full SECURITY.md
and PRIVACY.md documentation follows in M7.

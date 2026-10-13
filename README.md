# Monkey's Paw

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Latest release:** v<!-- version -->0.1.0<!-- /version --> · [Download](https://github.com/L-K-M/MonkeysPaw/releases/latest)

Monkey's Paw is a prompt repository for macOS and Linux, with Android planned.
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

## Host the sync server

Use Docker Engine on Linux and **Docker Compose 2.20.0 or newer** (`docker
compose version`). This minimum includes the
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

For public HTTPS, point a domain's DNS at this host and allow TCP 80/443.
Set `MONKEYSPAW_PUBLIC_URL=https://prompts.example.com` to your bare HTTPS
origin, with no path, query or fragment, and enable `COMPOSE_PROFILES=tls`
in `.env`. Prepare Caddy's certificate and state directories, using your
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

Use a consistent online snapshot through the planned `monkeyspaw-server
backup` command, and the stopped-server `restore` command, which rotates
the database identity so clients resnapshot ([deployment plan §8.6](docs/plan/08-sync-server.md#86-deployment-compose--updatesh)).
These backup/restore commands and `update.sh` are separate M5 slices; check
that they have landed before using them. Never copy a live SQLite database.
Keep a verified, private backup before upgrades; migrations are forward-only.

Deployment validation needs a Docker host: run both Compose configurations,
check default and overridden ownership, confirm UID 0 fails, and exercise
HTTPS certificate issuance, renewal and restart. YAML/static checks on the
implementation host do not prove a real Compose run. CI builds the server
image and checks `/api/health`; the Compose smoke gate and owner HTTPS check
complete runtime verification in subsequent M5 slices.

The desktop assistant sends your selected content to the configured LLM
provider only on an explicit action; `private: true` blocks assistant use.
Providers see what you send. Keys use macOS Keychain or Linux Secret Service
when available; the Linux file fallback is visibly unencrypted and private
(0600). Sync sends data to your configured server. See the
[security and privacy plan](docs/plan/12-security-and-privacy.md) for the
trust boundaries and storage tiers; full platform documentation follows in M7.

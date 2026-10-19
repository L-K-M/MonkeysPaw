# Security

## Trust boundaries

Your library is ordinary Markdown on your device. The app does not encrypt
prompt files, local history, remembered fields or sync recovery files. Protect
your account, disks and backups. Other software running as you, administrators
and software with access to your library can read or change them. A folder
managed by another sync or backup tool has that tool's exposure too.

An Assistant provider can read the brief or template you explicitly send.
Generated output is parsed and validated; you review changes and choose
**Accept** before they are saved. `private: true` blocks Review and Improve
for that prompt. It does not encrypt the prompt or exclude it from sync.
See [request contents and retention](PRIVACY.md).

The optional sync server operator can read every stored prompt. An admin who
resets your password can sign in as you. API permissions separate users and
group roles; they do not protect you from the operator. Server prompts,
revisions, SQLite journals and backups are plaintext. There is no end-to-end
encryption. Passwords use bcrypt cost 12; device and invite tokens are hashed.

Desktop Account, invite handling, sync status, groups and conflict resolution
are available on main. Automated device-token privacy fixtures passed both
native CI suites. The [desktop sync guide](docs/platform/sync.md) records
automated proof and open checks of deployed servers, signed installations,
real keyrings and physical devices, which remain M6 Y34 work.
Android implements optional server sign-in, invite acceptance only on explicit
consent, groups with viewer read-only access, conflict resolution and
WorkManager background sync. Its device tokens use Keystore-backed AES-GCM;
passwords and invite secrets are not persisted. The server/operator and
no-end-to-end-encryption boundaries above also apply to Android. Physical
acceptance remains open in the [M10 checklist](docs/platform/android.md#android-sync-m10-not-run-owner)
and [milestone record](docs/plan/15-milestones.md).

## Credentials

| Platform or tier | Storage and limits |
|---|---|
| macOS | Keychain, with no plaintext fallback. Access can be denied or locked. The app shares one service item across namespaced credentials. |
| Linux Secret Service | `secret-tool` talks to your Secret Service, such as GNOME Keyring or a compatible KWallet service. The secret is supplied on stdin. An installed but failing service does not silently save a new plaintext copy. |
| Linux environment | Read-only per-profile or device-token override. Clearing a saved credential does not unset your environment. |
| Linux file | If `secret-tool` is absent, `<config>/secrets-unencrypted.json` stores keys and tokens in plaintext with atomic mode-0600 writes. Settings labels this tier **unencrypted**. Permissions restrict access; they do not encrypt the file. Existing file credentials can also be read when a service lookup fails. |
| Android | AES-256-GCM with AndroidKeyStore; a separate app-private DataStore holds account names, IVs and ciphertext/tag. StrongBox is preferred where available. The **keystore** label does not prove hardware backing. There is no plaintext fallback. |

Provider settings hold credential references, not API keys. Changing a saved
provider's kind or origin requires re-entry or explicit Clear. Application
logs exclude credentials, prompt content, field values and raw provider/tool
error bodies. A secret-store failure can require an explicit retry; do not
interpret a failed Clear as successful deletion. See the
[Assistant checks](docs/platform/assistant.md) and [Android checks](docs/platform/android.md).

## Transport, hosting and backups

Assistant endpoints require HTTPS except for literal loopback destinations.
Desktop and Android sync require HTTPS except for localhost, loopback and
literal private IP ranges. An HTTP exception sends credentials and content
without TLS; use HTTPS on networks you do not control. The clients refuse
redirects and do not use browser cookies or ambient credential storage. Keep
normal TLS certificate validation enabled.

Run one server process per SQLite database on local storage. Keep the default
HTTP host binding on loopback; use the documented HTTPS reverse proxy for
remote access. Protect `.env`, Caddy certificate keys, the data volume and
off-host backups. Configure public-ingress rate limiting yourself. Take online
snapshots with the backup command, then restore with the server stopped;
copying a live database is unsafe. See [hosting and recovery](docs/platform/server.md#host-the-sync-server).

## Desktop input and sandbox limits

Delivery writes the clipboard, hides the panel, allows focus to settle and
requests a paste chord. A successful injection call does not prove receipt.
Run **Test paste** and check the actual target. Copy fallback keeps the result
for you to paste. The app sends no Return key to submit text; a target,
especially a terminal, can still interpret newlines in pasted content.

X11 does not isolate same-session input or clipboard access. Another X11
client can observe or inject input and change focus. WM_CLASS terminal hints
are recommendations, not authentication of a target. Wayland focus and portal
delivery depend on compositor capabilities and consent. Giving a native
ydotool daemon access to `/dev/uinput` grants input injection beyond this app.
Session D-Bus actions can be invoked by other processes with access to your
session bus; they are not a secret authentication boundary.

The Flatpak grants **read/write access to your whole home directory**, network,
IPC, Wayland/fallback-X11, Secret Service and an optional tray watcher. Its
filtered bus has no host dconf, native KGlobalAccel, host-spawn or uinput grant.
Delivery uses the portal, then Copy fallback. The home grant is broader than
the chosen library. See [Flatpak permissions and limits](README.linux.md#flatpak).

Invite links are bearer credentials. Opening one stages a destination for
explicit **Accept**; it does not redeem the invite. Linux launcher fallback
can expose the one-use URL in argv, and a browser can retain it in history.
Keep it out of public reports. See [invite exposure](PRIVACY.md#invite-links).

## Downloads and signing

Download artifacts and their checksum files from this repository's
[GitHub Releases](https://github.com/L-K-M/MonkeysPaw/releases).
Checksums detect byte changes relative to the downloaded manifest; they do
not independently authenticate its publisher.

Development desktop builds can be unsigned. The macOS packager signs ad-hoc
by default and can use an already installed signing identity if configured.
The workflow does not provision certificates or notarize the app. An update
or signature change can require new Accessibility or Keychain approval.

Android debug and release APKs share the committed **public signing key** and
app ID. Anyone with that key can sign an APK that updates your installation
and retains its data. The signature does not establish publisher identity.
Changing the signer breaks that upgrade path. See the
[signing decision](docs/decisions/0001-android-zero-secret-signing.md).
The release workflow distributes deb, Flatpak bundle, macOS archives and APK;
Flathub supplies the Flatpak runtime, not this app. No store publication or
additional signing channel is asserted here.

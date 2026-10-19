# Privacy

Monkey's Paw has no telemetry. Your library and remembered field values stay
on your device unless the behavior below sends them or you place files in a
folder managed by another service. This document covers the desktop and
Android features merged into main. Real platform
and privacy checks remain in the [owner checklists](docs/platform/m7-acceptance.md)
and [Android record](docs/platform/android.md).

## Requests and recipients

Recipients of network traffic can see your source IP address and ordinary
connection metadata. Your network, DNS resolver, proxy and operating system
can also observe connection metadata. These are separate from application
telemetry.

| Trigger | Recipient and contents |
|---|---|
| Assistant Write | Your configured provider receives your brief, system instructions, output schema, model and request parameters. |
| Assistant Review or Improve | Your provider receives the current template source, including front matter. Improve also sends your instruction and selected findings. Explicit retries can include the session's previous messages and your feedback. |
| Assistant Test connection | Your provider receives model-list requests, authenticated when a key is configured. They carry no prompt content. |
| Desktop and Android Account and sync | Your configured server receives sign-in/registration credentials and a device name, then a bearer device token for authenticated requests. Enabled sync sends and retrieves prompt source, IDs, paths, revisions and scope/group metadata, and polls in the background. Account, group, invite, conflict and device actions send their corresponding API requests. Android uses WorkManager for background sync. Opening an invite stages review; redemption requires explicit Accept. |
| Desktop automatic updates or Check Now | GitHub receives the fixed release-metadata GET described below. |
| Hosted server health/TLS | The server healthcheck requests its loopback `/api/health` endpoint without credentials. If you enable the optional Caddy HTTPS proxy, Caddy forwards client requests to the server and contacts its certificate services to obtain/renew certificates. Your hosting/proxy tools have their own network and retention policies. |
| View release, Open Folder, Setup links or OS permission/settings actions | The app asks your OS or desktop service to open a page, folder, dialog or settings panel. Your browser handles its own cookies, history and subsequent requests. |
| Linux desktop integration | Local session D-Bus communicates with portals, shortcut services, notifications, the optional tray watcher and Secret Service. Portals receive app/window identity, requested capabilities, shortcut descriptions and consent/session data; paste injectors receive paste key events. Folder/URI opening passes the chosen destination to the desktop. This is local IPC, not a separate Monkey's Paw collection server. |
| Android entry and delivery | Android provides editor metadata, text you explicitly share/select and clipboard access when needed. Insertion goes to the current InputConnection; Copy goes to the system clipboard. The keyboard/tile setup asks Android to show its settings or consent UI. |

Saving, renaming or switching an Assistant profile sends no provider request.
Assistant work starts only from your explicit action. Fill values, rendered
Fill previews and remembered values are not automatically included in an
Assistant request. Text you put into a brief or template is sent as part of
that input. `private: true` blocks Review and Improve; Write sends only your
separately supplied brief, even while a private prompt is open. Providers can
read and charge for requests; their retention policies are outside this app.

Sync does not transmit `values.json`, usage, local history or repeat records.
It does transmit prompt source, so defaults or sensitive text written into a
template are included. The server operator can read it; there is no end-to-end
encryption. Desktop Account, invite handling, sync status, groups and conflict
resolution are available on main. Automated device-token privacy fixtures
passed both native CI suites. The [desktop sync guide](docs/platform/sync.md)
records automated proof and open checks of deployed servers, signed
installations, real keyrings and physical devices, which remain M6 Y34 work.
Android implements optional server sign-in, explicit-consent invite
acceptance, groups with viewer read-only access, conflict resolution and
WorkManager background sync. Its device token is Keystore-encrypted;
passwords and invite secrets are not persisted. Physical and phone/desktop
acceptance remains open in the [M10 checklist](docs/platform/android.md#android-sync-m10-not-run-owner).
No Android desktop-style update checker is claimed. See
[Android usage](README.android.md) and [security boundaries](SECURITY.md).

### Desktop update requests

**Automatic checks default on**, including the first versioned launch when
due. Settings → General → **Automatically check for updates** turns them off.
The app checks stable releases, including when your installed build is a beta:

```text
GET https://api.github.com/repos/L-K-M/MonkeysPaw/releases/latest
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: MonkeysPaw/<full-app-version>
```

GitHub sees your IP and app version. The request has no auth, cookies, body,
prompt, field value, account details or machine/user identifier. The transport
refuses redirects, disables credential/cookie storage and caching, and bounds
the request to 15 seconds and 1 MiB of response data.

The app records the last automatic attempt before sending, limiting automatic
attempts to one per 24 hours across restarts and failures. **Check Now** works
with automatic checks off, while respecting an in-flight request and rate
limits. Disabling automatic checks retires scheduled work and cancels or
ignores its in-flight result; it cannot retract traffic already sent.
Corrupt, future or unreadable update state blocks automatic checks; an explicit
check can report without overwriting that state. Unversioned development and
hosted-test launches do not start automatic update traffic.

The checker downloads release metadata only. **View release** opens a
constructed GitHub release page in your browser. You download and install
updates yourself, including Flatpak bundles.

## Local files and retention

The default desktop library is `~/Documents/MonkeysPaw`, using Linux's XDG
Documents setting where valid. You can choose another library; Flatpak accepts
home-contained paths only. Prompt files are not encrypted by the app.

| Platform | Configuration and app data |
|---|---|
| macOS | `~/Library/Application Support/ch.lkmc.MonkeysPaw/` holds settings, provider metadata and app data. Credentials use Keychain. |
| Native Linux | `$XDG_CONFIG_HOME/monkeyspaw` or `~/.config/monkeyspaw` holds settings/provider metadata and any plaintext secret fallback. `$XDG_DATA_HOME/monkeyspaw` or `~/.local/share/monkeyspaw` holds app data. |
| Flatpak | `~/.var/app/ch.lkmc.monkeyspaw/config/monkeyspaw` and `~/.var/app/ch.lkmc.monkeyspaw/data/monkeyspaw` hold separate sandbox state; native state/secrets are not automatically imported. The manifest nevertheless grants read/write access to the whole home. |
| Android | App-private `filesDir/library`, `filesDir/state` and `filesDir/datastore` hold prompts, local state and settings/encrypted secrets. `allowBackup=false` opts out of Android Auto Backup. Uninstalling removes app-private data. |

| Store | Contents and lifetime |
|---|---|
| Library and `history/` | Prompt source and up to 50 local revisions per prompt. Deleting a prompt retains history; deletion can also leave OS trash or other backups. There is no secure-erasure guarantee. |
| `usage/<identity-key>` | Local use timestamps, capped at the newest 1,024 events per prompt. They affect ranking and Recent. There is no `usage.json`. |
| `values.json` | Plaintext values only for fields marked `remember: true`, including deliberately empty values. Private desktop writes use mode 0600. Values remain until replaced or forgotten. |
| Desktop `last-delivery.json` | One private, atomic mode-0600 record, capped at 1 MiB. Stores root/account binding, prompt identity/path hint, source fingerprint/incarnation, remembered fields, Copy intent and a session-only marker. A new delivery replaces it; Forget/retirement clears it. |
| Desktop `settings.json`, `provider-settings.json`, `provider-state.json` | Preferences, first-run progress, provider references and capability state. Credentials are stored separately using the [key tiers](SECURITY.md#credentials). Android stores non-secret settings/provider state in its settings DataStore. |
| Desktop `update-state.json` | Last automatic attempt, last successful check and rate-limit result/expiry; retained across launches. No browsing or prompt history. |
| Linux `portal.json` and shortcut mechanism state | Private portal restore tokens and shortcut choices, retained for later sessions. Clearing remembered fields does not revoke OS permissions. |
| Desktop and Android `sync/`, `Groups/` and `Conflicts/` | Account/root bindings, cursors, staged operations and recovery copies, plus managed group and conflict files in the library. Android sync records live under `filesDir/state/sync/`; WorkManager state contains non-secret references and counters. Journals and retained recovery files can contain prompt source. Signing out is not a wipe of your library, history, conflicts or backups. |
| Desktop `logs/monkeyspaw.log` | Diagnostics, warning level by default; active file plus four rotations, up to 1 MiB each. macOS also uses unified logging; Linux also uses stderr. OS/external log retention is outside this app. |
| Server database and backups | Plaintext prompts/revisions and account metadata with credential hashes. Maintenance prunes to 200 revisions per prompt and purges eligible changes/tombstones older than 90 days; retained feeds/snapshots and backups can preserve content separately. Retired IDs retain scope/time metadata. The backup helper keeps 14 successful backups by default; other copies and pre-restore recovery files need operator cleanup. See [hosting and backup](docs/platform/server.md#server-backup-and-restore) and the [server specification](docs/plan/08-sync-server.md#81-data-model). |
| Server login backoff buckets | Failed logins store attempted usernames and client IP addresses in separate buckets, with failure counts, update timestamps and lockout deadlines. These buckets have no automatic expiry; a successful login clears only its username bucket. |
| Server audit events | Account, group, membership and invite actions store the actor (user ID or CLI operator), action, target/group IDs and timestamp. These records have no automatic expiry. |

Application diagnostics exclude keys, tokens, passwords, prompt content,
field values, prior clipboard text, invite URLs and raw provider/tool error
bodies. Android has no HTTP logging or telemetry. Server diagnostics use
sanitized events; your reverse proxy, OS or other tools can have their own
logs. Inspect and redact reports before sharing them.

## Forget, repeat and clipboard

**Forget values** removes a prompt's remembered map and session draft and
resets a matching open form to defaults. **Forget all values** replaces the
remembered store with empty state and clears all drafts, including recovery
from an unreadable/corrupt regular values file when it can be replaced.
Desktop Forget also clears matching repeat data; all-values Forget clears
all repeat data. A failed action reports failure and requires retry.
These controls do not remove prompt source/defaults, history, usage, server
copies, OS clipboard history or backups, and are not secure erasure.

Desktop Repeat uses the most recent completed user delivery, including Copy
or paste fallback. Exact non-remembered field values exist only in memory;
they are never persisted in the repeat record. After restart a session-only
record requires reopening the prompt rather than reviving an older delivery.
Date, time and any used clipboard builtin refresh at invocation. Changed,
missing or inaccessible source requires review. Library/account retirement
invalidates repeat and late work; failed durable invalidation prevents a
successful clear or graph replacement from being reported.

Browsing/searching and selecting a prompt do not read the clipboard. Using a
clipboard builtin takes one snapshot per form open or fieldless use; editing
the form reuses it. Delivery and Copy put the result on the system clipboard.
Other apps, clipboard managers or OS clipboard sync can retain it beyond this
app's lifetime. The app does not automatically clear delivered clipboard text.

Desktop **Restore previous clipboard text** defaults off. If enabled, a real
paste can snapshot up to 1 MiB of previous text within 250 ms, then restore
750 ms after the final backend reports sent. Only text is preserved. Failed
capture, changed ownership/revision, a newer copy (even identical text), a new
delivery, self-test, disable or retired graph cancels restoration. Copy and
copy fallback keep the result. Prior text is kept only in memory until restore
or cancellation. The 750 ms delay may be too short for a slow target; a sent
chord does not prove the target consumed it. OS clipboard APIs cannot
atomically exclude a simultaneous external copy. Leave restore off if that
limit is unacceptable.

Android marks copied text sensitive. The picker keyboard reads editor
metadata, not surrounding target text, and hides prompts in password fields.
`IME_FLAG_NO_PERSONALIZED_LEARNING` suppresses usage and remembered-value writes,
including Copy handoff. Shared/selected text and handoff state stay in memory
until you explicitly save a draft or complete an action that may remember
allowed fields. See [Android behavior and limits](README.android.md).

## Invite links

`monkeyspaw://join` links contain the destination server and a one-use bearer.
Opening a link only stages a review in Account; you must choose **Accept** to
redeem it. The app does not log the bearer or full URL. Linux prefers D-Bus
Open, but the launcher fallback necessarily places the URL in argv. Local
process inspection, browser history, clipboard managers and shell history
(if you paste a link into a command) can expose it. This also applies to
Flatpak's exported launcher. Do not publish links or paste them into diagnostic
commands. Browser/OS history and clipboard copies require separate cleanup.

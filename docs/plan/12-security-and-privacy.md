## 12. Security and privacy

| Asset | Protection |
|---|---|
| API keys, device token | OS secret store. Never stored in settings, argv, or logs. `secret-tool` gets the secret on stdin. Types holding secrets have redacted descriptions and reflection output. |
| Synced provider keys | Provider API keys cross the wire only inside the §26 AES-256-GCM document sealed under the per-account `provider-sync:<user>` key; the server stores opaque ciphertext it cannot read. The sync key is generated on one device, entered manually on the others as 43-character base64url, lives in the platform secret store, and is never uploaded, logged, or re-displayed after its one-time reveal. |
| Prompts on the device | Local files. The app sends them only through explicit Assistant inputs (`private: true` blocks Review/Improve), or through enabled sync to the configured server. Android opts out of Auto Backup (§10.6). |
| Prompts on the server | TLS in transit. On disk they are plaintext in SQLite. Volume encryption is the operator's job, and SECURITY.md says so. No end-to-end encryption in v1 (D12). |
| Server accounts | bcrypt 12. Hashed device tokens. Login backoff. Invite-only. Admins cannot read private prompts through the API. |
| Portal restore tokens | Private atomic `portal.json` record, mode 0600; never logged. Replace each returned token immediately after successful Start (§6.3). |
| Remembered values | `values.json` mode 0600, never synced. "Forget values" removes one prompt's map and session draft; "Forget all values" atomically replaces the file (private 0600 temporary, then rename) with empty version-1 state without reading it first, so it also resets a corrupt or unreadable `values.json`, and clears all drafts (§5.4). A matching open form resets to defaults without delivery; failed actions keep drafts and fields. |
| Repeat state | Separate version-1 `<data>/last-delivery.json`, atomic 0600 replacement, 1 MiB cap, never synced. Root/account binding, identity/path hint, source fingerprint, idless incarnation stamp, remembered fields, session-only marker and Copy intent only. Exact non-remembered values stay in session memory; template/rendered text and builtins never enter the record or logs. Restart requires a complete permitted snapshot. Forget/retirement persists a tombstone before success; failure disables repeat and reports unsuccessful clear, requiring a retry before graph replacement (§6.1). |
| Injection surface | Paste follows an explicit delivery or Repeat intent. Session D-Bus actions are callable by other processes with session-bus access. X11 does not isolate input, focus or clipboard from same-session clients. Native GNOME keybinding writes require an explicit action and touch only owned `Monkey's Paw:` rows. Flatpak has no host dconf grant. |
| LLM output | Treated as data: parsed, validated, diffed, applied only on Accept. Never executed. |
| Transport | §7.1 rules for LLM providers. The sync client refuses redirects and requires HTTPS except on loopback and private ranges. |
| Android keyboard | Picker-only: reads only `inputType`, `imeOptions` and connection readiness, never target text. Offers no prompts in text/visible/web or numeric password fields. The system warning at enable time is explained beforehand. |
| Android secrets | AES-256-GCM key in AndroidKeyStore (StrongBox when available); nothing in plain SharedPreferences. |

`IME_FLAG_NO_PERSONALIZED_LEARNING` selects Ephemeral bookkeeping: no usage
or remembered-value writes, including an activity handoff. It does not change
insertion permission. Captured selection/share text and field overrides stay
in memory; capture or preview never persists them. Normal successful delivery
may remember only fields with `remember: true`. Never put capture in logs,
saved state or navigation arguments ([§22 H7/H11](22-m9-m11-decisions.md)).
An IME handoff Intent carries only an opaque one-use token. Prompt, values,
capture and builtin snapshots stay in one process-local slot until consumed or
cancelled; the receiving activity has only a Copy endpoint. Lost process memory
restarts an empty Ephemeral Copy picker, never a former target or draft (§10.4).

`SecretStore` reports `keychain`, `secretService`, `environment` or `file`
to the UI without displaying a stored value. Effective reads follow D9;
persisted reads bypass the read-only environment tier. Writes never edit
environment variables; deletion removes persisted account copies and leaves
the environment untouched ([§19 B23](19-m4-m5-decisions.md)). Secret values,
drafts, resolved connections, HTTP envelopes and assistant errors have redacted
descriptions and reflection output.
Android reports `keystore` and uses redacted `toString` and static typed-error
messages, with no underlying exception cause or provider diagnostic. A storage
tier alone does not establish hardware backing; L8 and owner checks establish
that separately ([§20 J2](20-m6-m8-decisions.md#m11-portable-assistant-contracts)).
Its separate singleton secrets DataStore holds only account/IV/ciphertext-tag
records. GCM authenticates the storage domain, version and exact namespaced
account; account swaps fail. StrongBox preference, restricted fallback and
failure/explicit-Clear behavior follow [§10.6](10-android-client.md#106-storage-and-sync)
and §22 J7. No settings, diagnostic or plaintext file receives a key or secret.
Transient access failures and ambiguous API 26-30 alias lookups report `locked`
and cannot authorize Settings recovery deletion (§7.1, §22 J7).
Persisted provider secrets also carry the destination binding from §7.6;
metadata edits cannot rebind a stored key to another kind or origin.
Environment values are raw operator overrides without destination bindings;
the binding's re-entry gate applies only to persisted secrets.

Explicit provider Clear/Delete/Replace can recover from a failed persisted read
without obtaining the old value. Desktop permits locked/unavailable/readFailed
reads to reach account-level deletion; environment-backed replacement stays
read-only, and cancellation never starts recovery. The driver must preserve
other accounts. Linux can clear an unreadable Secret Service account without a
successful lookup, then remove any readable file copy. An unreadable shared
Keychain or file map still blocks edits rather than deleting unrelated entries.
Readable edits restore the exact opaque old payload on metadata failure.
An unreadable discarded payload cannot be restored: failed metadata publication
retains metadata, removes a replacement and reports typed `writeFailed`.
Failed replacement cleanup reports `secretRollbackFailed`, disables credential
resolution and makes the store instance read-only (§7.1, §22 J9).

On macOS, one generic-password Keychain item uses service
`ch.lkmc.monkeyspaw` and fixed account `secret-map`. Its version-1 JSON
payload maps namespaced accounts to opaque secrets under `entries`; provider
and device-token namespaces remain separate. A process-wide lock serializes
reads and edits, including the hosted-test scope that suppresses legacy
Keychain interaction. Missing items return no secret; locked or denied access
reports `locked`. A corrupt or unsupported payload reports `readFailed`
and blocks all edits without overwriting the item. Unrecognized account keys
are ignored by lookups and preserved with their opaque values during edits;
they do not invalidate an otherwise supported payload. Deleting the last entry
removes the item. If a write's update finds that the item disappeared, it retries
one add and reports any failure without further retries. Delete never recreates
a disappeared item. There is no plaintext fallback on macOS, and no secret or
Security error text is logged. Real ACL and signed-build behavior require
the [macOS owner checks](../platform/macos.md).

For Keychain/Secret Service, scans of repository, config, data, logs and
temporary directories must find zero copies of a saved key. The Linux file
tier instead permits exactly the named atomic 0600 secrets file, visibly
labelled "unencrypted", and zero other copies
([§19 B29](19-m4-m5-decisions.md)). Provider settings contain only a secret
reference; the file fallback is never a settings file.

The integration tests generate a fresh runtime sentinel and save through
`ProviderSettingsService` and the native secret driver in isolated roots.
They scan after Save, successful and failed Test connection with stub HTTP,
graph reconstruction, profile rename, switching away and back, and deletion.
Scans include hidden files and build products and detect raw, base64,
percent-encoded and JSON-escaped keys, including the nested JSON credential
envelope. The Linux strict-tier fixture keeps fake service secrets in memory
on the existing private test bus; it does not prove a desktop's real Secret
Service or consent behavior. The macOS test uses a unique real Keychain item
with interaction suppressed per operation. A locked or unavailable Keychain
skips that integration test; a skip does not satisfy acceptance. Real store
and signed-build checks remain in the [assistant owner checklist](../platform/assistant.md).

The [Privacy document](../../PRIVACY.md#requests-and-recipients) carries the
assistant disclosures required by [§19 B33](19-m4-m5-decisions.md). Write sends
the supplied brief; Review and Improve send the current template source,
including front matter, with Improve's instruction and selected findings.
Explicit retries may send the session transcript and feedback. Requests also
include system instructions, schema and model selection. `private: true`
blocks Review and Improve for that prompt; Write never imports an open
private template. Fill values, rendered fill previews and remembered values
are never sent automatically. Text explicitly included in a brief or template
is part of the request. Test connection sends only a model-list request.
[SECURITY.md](../../SECURITY.md) records trust boundaries and key/signing
limits; [PRIVACY.md](../../PRIVACY.md) records outbound traffic, retention,
Forget, repeat, clipboard restore and E28 invite exposure. GitHub private
vulnerability reporting was disabled at the 2026-10-16 read-only check. The
owner removed that reporting prerequisite on 2026-10-19, recorded in the
[M7 ledger](../platform/m7-acceptance.md#owner-prerequisites); no enablement
or alternative private contact is asserted.

Linux uses `service=ch.lkmc.monkeyspaw` and the namespaced account as
Secret Service attributes, with a `Monkey's Paw: <account>` item label.
The fallback is `<config>/secrets-unencrypted.json`: a version-1 JSON map
labelled `unencrypted`, written through a private 0600 temporary file and
atomic rename. Reads and mutations refuse symlinks, nonregular files,
hardlinks, foreign ownership, insecure file modes and unsupported versions.
Directory descriptors prevent a replaced config ancestor from redirecting
secret I/O. Per-store serialization protects account edits. Before mutations,
an exclusive directory lock protects cleanup of abandoned private
`.secrets-<UUID>` temporaries; contention fails without sweeping a live writer.

An absent `secret-tool` enables file storage. An installed tool's failed
lookup uses an existing file value; a successful empty `search --all`
distinguishes a missing item from a locked match. Without a file value,
locked or inaccessible service reads report `locked` or `unavailable`.
Writes and deletes against an installed but failing or timed-out service
fail with a typed error, without creating a plaintext copy or discarding
the fallback. A successful service write removes that account's file copy;
Clear with an accessible service removes both persisted copies and leaves
overrides untouched. Commands that fail or time out after committing, and
failed file cleanup, attempt restoration of the prior service state; an
inaccessible service can also prevent compensation, so a reported failure
may need an explicit retry or key re-entry.
Removing the tool after saving a service key can leave an older service item
behind a newer file value. Restoring the tool restores service precedence;
re-enter and save the intended key through the unlocked service to replace
that item and remove the plaintext copy. Restore the tool before Clear to
purge service items as well as the file account.
Subprocesses run only on a worker, with the existing two-second tool budget,
discarded stderr and bounded stdin/stdout. Provider override variables stay
in the parent environment and are removed from all spawned tools' environments.
Tool input is capped at 8,191 bytes, below its 8 KiB truncation threshold.

`SECURITY.md` lists what is not protected:

- Providers see what you send.
- The sync server operator can read every prompt on it. So can an admin who
  resets a password. The permission model protects members from each other,
  not from the operator. The provider-settings document is the exception:
  it is AES-256-GCM ciphertext under the device-provisioned sync key, so
  the operator cannot read synced provider keys from it. The operator can
  still withhold or roll back the document; a forged or cross-account
  document fails authentication on the device (§26 S5).
- The Linux file tier is not encrypted.
- Development desktop builds can be unsigned; macOS packaging is ad-hoc by
  default with an optional configured identity and no notarization workflow.
  Updates/signature changes can require Accessibility or Keychain approval.
- Android debug and release share a committed public signer; it establishes
  no publisher identity and permits third-party updates retaining app data.
- Flatpak grants read/write access to the whole home, not just the library.
  It uses isolated app state and filtered portal/Secret Service access, with
  no host dconf, KGlobalAccel, host-spawn or native injection grant.

`PRIVACY.md` lists every outbound request:

- LLM calls and model listing.
- Sync to the server the user configured.
- Server healthcheck to loopback; the operator's HTTPS proxy has its own
  network/retention policy and is not bundled with the server.
- The update check (from M7): an unauthenticated HTTPS GET to
  `https://api.github.com/repos/L-K-M/MonkeysPaw/releases/latest`. GitHub sees
  the source IP and `MonkeysPaw/<full-app-version>` User-Agent, plus fixed
  Accept/API-version headers. No machine/user/account identifier, token,
  prompt, field value, cookie or request body is sent. The shared transport's
  default Assistant URL policy refuses redirects, cookies and credentials;
  one request has a 15-second total deadline and a 1 MiB response cap.
  Automatic checks default on (Q11), disclosed in README/PRIVACY before
  first launch; Settings → General can turn them off. A private atomic
  `<data>/update-state.json` stores the last automatic attempt separately
  from the last successful check, and rate-limit expiry/status. Recording
  the attempt before HTTP enforces at most one automatic attempt per 24
  hours across failures/restarts. Corrupt, unreadable or future state and
  read-only settings block automatic traffic. Check Now is explicit, works
  while automatic checks are off, and respects in-flight/rate limits; it
  may report a result from corrupt state without overwriting that state.
  Disabling retires automatic timers and cancels/ignores automatic work.
  Unversioned development/tests send no update traffic. Only explicit
  View release opens a constructed repository release page in the browser.
  D15 supplies Core; D17/D18 wire native runtimes and D19 owns disclosures.
- OS/desktop integration: local portal, D-Bus, Secret Service, shortcut,
  notification and clipboard calls, plus explicit folder/page/settings
  opening. The browser owns subsequent traffic/cookies/history. Android
  entry and InputConnection/clipboard delivery use OS APIs. These are not
  application telemetry; see the [outbound inventory](../../PRIVACY.md#requests-and-recipients).

Invite links stage review and require Accept before redemption. E28's Linux
launcher fallback exposes the one-use URI in argv; browsers and clipboard
managers can retain it too. Neither an app-log policy nor Forget removes
those external copies. Do not log or publish bearer links (§20 E28).

Clipboard restore remains opt-in, text-only and bounded (§21 G13/G14).
Revision/provider guards skip observed newer copies, including identical
text; OS APIs do not offer atomic exclusion of a simultaneous external copy.
The 750 ms delay can be too short for a slow target. No restore on Copy,
fallback or self-test; prior text stays only in memory until restore/cancel.

Desktop Account, invites, sync status, groups and conflict resolution are
available on main. Automated device-token privacy fixtures passed both native
CI suites. The [desktop sync guide](../platform/sync.md) records automated
proof and open checks of deployed servers, signed installations, real
keyrings and physical devices, which remain M6 Y34 work. Android implements
optional server sign-in, explicit-consent invite acceptance, groups with viewer
read-only access, conflict resolution and WorkManager background sync; Android
sync acceptance remains open in the
[M10 checklist](../platform/android.md#android-sync-m10-not-run-owner). M7's
[owner ledger](../platform/m7-acceptance.md) starts NOT RUN and does not close sync.

**Logging.**

| Component | Sinks | Level control |
|---|---|---|
| Desktop | macOS unified log or Linux stderr, plus `<data>/logs/monkeyspaw.log`: `<ISO-8601 UTC timestamp> <level>: <message>\n`; rotate before exceeding `LOG_FILE_MAX_BYTES = 1 MiB`, retaining the active file plus `.1` through `.4` (`LOG_FILE_KEEP = 5` total) | `warning` by default; `MONKEYSPAW_LOG` accepts case-insensitive `debug`, `info`, `warning`/`warn`, `error`; unknown values keep the default |
| Server | One JSON event per line to stdout (`docker compose logs`), with UTC `at`, `level`, `message` and safe `fields` | `MONKEYSPAW_LOG_LEVEL`: case-insensitive SwiftLog levels (`trace`, `debug`, `info`, `notice`, `warning`/`warn`, `error`, `critical`); default `info`, including unknown values |

- **File diagnostics:** create the logs directory at 0700 and files at 0600;
  append across restarts and serialize records within each sink. Escape CR/LF
  in messages as `\r`/`\n` so each record is one line. Oversized records retain
  a UTF-8 scalar boundary prefix of the message and end with ` [truncated]`
  plus a newline, with the entire record at most 1 MiB. A file failure disables
  that sink for its lifetime, reports one path-free warning to stderr, and
  leaves the other sinks running.
- **Never logged:** keys, tokens, passwords, prompt content, field values,
  provider/tool error bodies.
- **Server diagnostics:** messages use fixed safe text. Framework messages
  containing addresses, paths or errors are reduced to a fixed event name.
  Only validated action names, actor/target ids, HTTP methods/statuses,
  failure codes and bounded ASCII error type names enter `fields`. Type names
  omit reflective private-context addresses; messages never enter `error_type`.
  Arbitrary metadata, error descriptions,
  credential hashes, headers, query strings and request bodies are dropped,
  including at trace level. JSON encoding escapes embedded line breaks; a
  serialized sink keeps concurrent events on separate lines. Logger copies
  retain independent metadata, metadata providers and log levels. Account
  success events describe actual changes and are emitted only after their
  audit transaction commits. Healthcheck configuration failures log the
  configuration type name and a fixed instruction to check
  `MONKEYSPAW_HTTP_PORT` and `MONKEYSPAW_TRUSTED_PROXIES`, never their values.
- **Bug reports:** the `--selftest` output plus the log tail.

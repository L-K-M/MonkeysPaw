## 12. Security and privacy

| Asset | Protection |
|---|---|
| API keys, device token | OS secret store. Never stored in settings, argv, or logs. `secret-tool` gets the secret on stdin. Types holding secrets have redacted descriptions and reflection output. |
| Prompts on the device | Local files. They leave the machine only on an explicit assistant action (and `private: true` blocks that), or through sync to the user's own server. Android opts out of Auto Backup (§10.6). |
| Prompts on the server | TLS in transit. On disk they are plaintext in SQLite. Volume encryption is the operator's job, and SECURITY.md says so. No end-to-end encryption in v1 (D12). |
| Server accounts | bcrypt 12. Hashed device tokens. Login backoff. Invite-only. Admins cannot read private prompts through the API. |
| Portal restore tokens | Private atomic `portal.json` record, mode 0600; never logged. Replace each returned token immediately after successful Start (§6.3). |
| Remembered values | `values.json` mode 0600, never synced. "Forget values" removes one prompt's map and session draft; "Forget all values" atomically replaces the file (private 0600 temporary, then rename) with empty version-1 state without reading it first, so it also resets a corrupt or unreadable `values.json`, and clears all drafts (§5.4). A matching open form resets to defaults without delivery; failed actions keep drafts and fields. |
| Injection surface | Keystrokes are injected only right after a user hotkey and a pick. D-Bus actions are on the session bus (same user). GNOME keybinding writes touch only rows named `Monkey's Paw:`. |
| LLM output | Treated as data: parsed, validated, diffed, applied only on Accept. Never executed. |
| Transport | §7.1 rules for LLM providers. The sync client refuses redirects and requires HTTPS except on loopback and private ranges. |
| Android keyboard | Picker-only: it reads the field only to choose single- or multi-line insertion, never stores or sends what is typed, and offers no prompts in password fields. The system warning at enable time is explained beforehand. |
| Android secrets | AES-256-GCM key in AndroidKeyStore (StrongBox when available); nothing in plain SharedPreferences. |

`SecretStore` reports `keychain`, `secretService`, `environment` or `file`
to the UI without displaying a stored value. Effective reads follow D9;
persisted reads bypass the read-only environment tier. Writes never edit
environment variables; deletion removes persisted account copies and leaves
the environment untouched ([§19 B23](19-m4-m5-decisions.md)). Secret values,
drafts, resolved connections, HTTP envelopes and assistant errors have redacted
descriptions and reflection output.
Persisted provider secrets also carry the destination binding from §7.6;
metadata edits cannot rebind a stored key to another kind or origin.
Environment values are raw operator overrides without destination bindings;
the binding's re-entry gate applies only to persisted secrets.

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

The [README](../../README.md#assistant-privacy-and-key-storage) carries M4's
minimum assistant disclosures ([§19 B33](19-m4-m5-decisions.md)). Write sends
the supplied brief; Review and Improve send the current template source,
including front matter, with Improve's instruction and selected findings.
Explicit retries may send the session transcript and feedback. Requests also
include system instructions, schema and model selection. `private: true`
blocks Review and Improve for that prompt; Write never imports an open
private template. Fill values, rendered fill previews and remembered values
are never sent. Test connection sends only a model-list request. Full
SECURITY.md and PRIVACY.md remain M7 work.

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
  not from the operator.
- The Linux file tier is not encrypted.
- Desktop builds are unsigned or ad-hoc signed unless Q3 changes that, and
  an ad-hoc signature resets Accessibility on each update.

`PRIVACY.md` lists every outbound request:

- LLM calls and model listing.
- Sync to the server the user configured.
- The update check (from M7): GitHub releases, once a day. It can be
  turned off in Settings → General; Q11.
- Nothing else. No telemetry.

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

## 12. Security and privacy

| Asset | Protection |
|---|---|
| API keys, device token | OS secret store. Never stored in settings, argv, or logs. `secret-tool` gets the secret on stdin. Types holding secrets have redacted `description`. |
| Prompts on the device | Local files. They leave the machine only on an explicit assistant action (and `private: true` blocks that), or through sync to the user's own server. Android opts out of Auto Backup (§10.6). |
| Prompts on the server | TLS in transit. On disk they are plaintext in SQLite. Volume encryption is the operator's job, and SECURITY.md says so. No end-to-end encryption in v1 (D12). |
| Server accounts | bcrypt 12. Hashed device tokens. Login backoff. Invite-only. Admins cannot read private prompts through the API. |
| Remembered values | `values.json` mode 0600, never synced, "Forget values" per prompt and globally. |
| Injection surface | Keystrokes are injected only right after a user hotkey and a pick. D-Bus actions are on the session bus (same user). GNOME keybinding writes touch only rows named `Monkey's Paw:`. |
| LLM output | Treated as data: parsed, validated, diffed, applied only on Accept. Never executed. |
| Transport | §7.1 rules for LLM providers. The sync client refuses redirects and requires HTTPS except on loopback and private ranges. |
| Android keyboard | Picker-only: it reads the field only to choose single- or multi-line insertion, never stores or sends what is typed, and offers no prompts in password fields. The system warning at enable time is explained beforehand. |
| Android secrets | AES-256-GCM key in AndroidKeyStore (StrongBox when available); nothing in plain SharedPreferences. |

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
| Desktop | stderr and `<data>/logs/monkeyspaw.log`, rotated at `LOG_FILE_MAX_BYTES = 1 MiB` × `LOG_FILE_KEEP = 5` | `warn` by default, `MONKEYSPAW_LOG=debug` |
| Server | JSON to stdout (`docker compose logs`) | `MONKEYSPAW_LOG_LEVEL` |

- **Never logged:** keys, tokens, passwords, prompt content, field values.
- **Bug reports:** the `--selftest` output plus the log tail.

# M4 assistant owner checks

M4 stays open until these checks have results on macOS and Linux. Run the
Library checks after A11 (acceptance), A15 (macOS Library) and A16 (GTK
Library) are merged; A17's automated secret scans do not depend on those
slices. Use harmless sample content and a disposable library. Record failures
and skipped checks as such; do not attach keys, prompts, filled values,
provider bodies or a sentinel to the evidence.

- Commit / CI run / app artifact:
- OS version / desktop session / date / tester:
- Provider host / model ID (no credentials):
- Storage tier shown in Settings / signed or ad-hoc macOS build:
- Result / issue links / sanitized evidence:

| Platform and provider | Test connection | Write | Review | Improve |
|---|---|---|---|---|
| macOS / Anthropic | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| macOS / local Ollama | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Linux / Anthropic | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Linux / local Ollama | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

For each row, configure a separate profile in Settings → Assistant. Anthropic
uses `https://api.anthropic.com` and your own key and available model. Local
Ollama uses the OpenAI-compatible kind and
`http://localhost:11434/v1`, with a model already installed locally; leave
the key empty unless your local endpoint requires it. Use Test connection to
list models, or enter a model ID manually if listing is unsupported. Confirm
the active provider host and model before every action. Anthropic calls can
incur provider charges.

## Library flows

Run all of these for each of the four rows above:

- [ ] Write: request a reusable template from a harmless brief with one
  declared placeholder. Inspect validation and the full diff; Reject leaves
  disk untouched. Repeat, Accept, reopen the file and compare the saved bytes
  with the preview. Confirm LLM provenance and token usage when provided.
- [ ] Review: review the current editor template, including a harmless unsaved
  edit. Check local placeholder issues, rubric/severity and exact quote
  highlighting. An unmatched quote must be identified without highlighting
  unrelated text. Review does not save the file.
- [ ] Improve: select findings and supply an instruction. Inspect front matter,
  body and placeholder warnings in the diff. Reject changes nothing; Accept
  saves the displayed candidate and preserves identity and unknown metadata.
- [ ] Change the editor buffer or file on disk while a request is pending.
  Acceptance must require a fresh diff. Switch provider or library, close the
  assistant, and cancel a request; old replies must not revive the old session.
- [ ] Explicit retry uses the current snapshot and supplied feedback; no
  action, retry or provider fallback runs just from opening the window.
- [ ] Set `private: true`: Review and Improve are disabled and send no request.
  Write can still use a separately supplied brief without the private template.
- [ ] Put a harmless, distinctive value in the Fill form and in remembered
  values. Inspect a local test endpoint's received request in memory: the
  assistant sends template source, never the rendered preview or those values.
  Do not enable body/header logging for a real key or real personal content.

## Key tiers and profile lifecycle

| Check | macOS | Linux |
|---|---|---|
| Saved key survives quit/relaunch, rename and profile switch | NOT RUN | NOT RUN |
| Keychain / Secret Service shown; no plaintext copies | NOT RUN | NOT RUN |
| Blank key means Keep; stored key never appears in the key field | NOT RUN | NOT RUN |
| Test uses only that draft's account; typed replacement is not saved by Test | NOT RUN | NOT RUN |
| Changing provider kind or origin requires key re-entry or explicit Clear | NOT RUN | NOT RUN |
| Clear + Save and Delete remove the persisted account | NOT RUN | NOT RUN |
| Missing secret-tool: one atomic 0600 unencrypted file and visible warning | N/A | NOT RUN |
| Read-only per-profile environment override and persisted Clear behavior | N/A | NOT RUN |

On macOS, inspect the app's generic-password item in Keychain Access:
service `ch.lkmc.monkeyspaw`, account `secret-map`. Do not display or export
its value. Verify access with the actual release signing configuration and
after an update, including ACL/unlock prompts. There is no plaintext fallback.

On Linux, verify the Secret Service item attributes
`service=ch.lkmc.monkeyspaw` and `account=provider:<profile UUID>` without
revealing its value. Test the file tier in a disposable account or VM where
`secret-tool` is absent. Settings must say **unencrypted** and warn that
read access exposes the key. An installed but locked, denied or failing
service must report failure when saving a new key, without creating plaintext.
Once Secret Service is available, re-enter and Save: that account migrates out
of the file. Other accounts remain intact.

An environment override is read-only and does not copy itself to disk. Clear
deletes persisted copies and disables authentication for that profile without
editing the environment. Restore `secret-tool` before Clear if a service item
could remain from an earlier session (§12). Deleting one profile must preserve
another profile's credential.

## Manual sentinel scan

Use a new synthetic key from a local password generator, with a random UUID
and some of `"`, `\`, `/`, `%`, `+` to exercise escaping. Keep it only in
memory. Use a separate OpenAI-compatible profile against local Ollama for
this test; the sentinel is not a valid paid-provider credential. Never put it
in shell history, argv, environment variables, screenshots or evidence files.

On Linux, use isolated XDG config/data roots, an isolated library, and a
private temporary directory for the launched app. On macOS, use a disposable
OS account: app config/data are in
`~/Library/Application Support/ch.lkmc.MonkeysPaw`, with logs under `logs/`;
the system Keychain belongs to that account. Include its library and actual
temporary directory. Record every root, including the repository checkout
and app log locations. Include any stderr capture and rotated logs.
Run the scan from a terminal that can read every root: macOS folders such as
Documents need Full Disk Access, and the script stops at the first
unreadable location.

Save the sentinel through Settings → Assistant, then run the scan below after
each of: Save, successful/failed Test connection, quit/relaunch, profile rename,
switch away/back, deleting an unrelated profile, and deleting the sentinel
profile. A synthetic Ollama key may not cause a failed Test; use a local stub
that returns HTTP 401 for that step. Keep stub secrets and responses in memory.
Pass existing directory paths in place of the example arguments. The script
asks for the sentinel without echoing it and prints matching paths only.
It lists symlinks without following them; scan any listed target outside
the roots.

```sh
python3 - /path/to/checkout /path/to/config /path/to/data /path/to/logs /path/to/temp <<'PY'
import base64
import getpass
import json
import os
from pathlib import Path
import sys
import urllib.parse

key = getpass.getpass("Synthetic sentinel (hidden): ")
if not key:
    raise SystemExit("A sentinel is required")
variants = {key, base64.b64encode(key.encode()).decode(), urllib.parse.quote(key, safe="")}
escaped = {key}
for _ in range(2):
    following = set()
    for value in escaped:
        plain = json.dumps(value, ensure_ascii=False)[1:-1]
        following.update((plain, plain.replace("/", "\\/")))
    variants.update(following)
    escaped = following
patterns = [value.encode() for value in variants]
overlap = max(map(len, patterns)) - 1
seen, matches = set(), set()
def failed(error):
    raise SystemExit("SCAN ERROR: a directory could not be read")
for argument in sys.argv[1:]:
    root = Path(argument).resolve()
    if not root.is_dir():
        raise SystemExit("SCAN ERROR: a root is missing")
    for directory, dirs, names in os.walk(root, onerror=failed, followlinks=False):
        for entry in dirs + names:
            if (Path(directory) / entry).is_symlink():
                print("SKIPPED symlink:", Path(directory) / entry)
        for name in names:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file() or path in seen:
                continue
            seen.add(path)
            try:
                with path.open("rb") as stream:
                    tail = b""
                    while chunk := stream.read(65536):
                        data = tail + chunk
                        if any(pattern in data for pattern in patterns):
                            matches.add(path)
                            break
                        tail = data[-overlap:]
            except OSError:
                raise SystemExit("SCAN ERROR: a file could not be read")
for path in sorted(matches):
    print("COPY:", path)
print("Matching files:", len(matches))
PY
```

Strict tiers must report **0** matching files at every checkpoint. The file
tier must report **1** while saved, exactly
`<config>/secrets-unencrypted.json`; verify mode 0600, one account entry,
`storage: unencrypted`, and no abandoned `.secrets-*` or other copies. After
Clear/Delete, every tier must report **0**. Record only paths/counts, mode,
tier and pass/fail. Remove the sentinel profile and temporary roots afterward.

## Native controls and desktop behavior: NOT RUN

Record the exact build, platform, input method, screen reader and tester.
Run every applicable row in the linked platform sections with Anthropic and
local Ollama. These are real desktop checks; injected transports and key
events do not establish native provider, IME or accessibility behavior.

| Check | Status | Procedure and detailed result rows |
|---|---|---|
| macOS native Keychain ACL/unlock/update behavior | **NOT RUN** | [Keychain secrets](macos.md#m4-a3-keychain-secrets-not-run) |
| Linux GNOME Keyring/KWallet, locked/unavailable service, environment/file tiers, migration and temporary cleanup | **NOT RUN** | [Secret storage](linux.md#secret-storage-m4-a4-not-run) |
| Assistant Settings: profiles/keys/models/Test, warning, lifetime, keyboard, screen reader and focus | **NOT RUN** | [macOS Assistant Settings](macos.md#m4-a13-assistant-settings-not-run), [Linux Assistant Settings](linux.md#assistant-settings-m4-a14-not-run) |
| Library Assistant: all action/privacy/staleness/acceptance/cancellation rows, real IME, keyboard and screen reader | **NOT RUN** | [macOS Library Assistant](macos.md#m4-library-assistant-flows-73-76-117), [Linux Library Assistant](linux.md#library-assistant-flows-m4-a16-not-run) |

## Automated proof and remaining owner work

[LinuxSecretScanTests](../../Tests/MonkeysPawLinuxTests/LinuxSecretScanTests.swift)
runs in `linux-app` with a required display and private test bus, alongside
the existing atomic-file tests. Its fake `secret-tool` sends stdin to an
in-memory test interface on the existing fake portal bus; it does not emulate
the full libsecret protocol or prove a real desktop service's behavior.
[KeychainSecretScanTests](../../MonkeysPawTests/KeychainSecretScanTests.swift)
runs in `macos-app` against a uniquely named real login-Keychain item with
dialogs suppressed per call. Locked/unavailable Keychain access skips the
lifecycle test and leaves the owner proof pending. Both targets calibrate the
scanner with hidden raw, encoded and nested JSON copies. Neither test sends
a network request to a real provider or prints the runtime sentinel.

All owner rows above are **NOT RUN** until you record an actual run. A green
stub test or a skipped Keychain test does not demonstrate the four real-provider
rows, native ACL behavior or M4 completion.

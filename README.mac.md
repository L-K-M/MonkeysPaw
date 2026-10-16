# macOS

You need macOS 14 or later. Release packaging builds both Apple Silicon and
Intel slices; real installation and delivery remain [owner checks](docs/platform/macos.md).

## Install and open

Download `MonkeysPaw-<version>.dmg`, `MonkeysPaw-<version>.zip` and
`MonkeysPaw-<version>.sha256` from [Releases](https://github.com/L-K-M/MonkeysPaw/releases).
In their directory, replace `<version>` and run:

```sh
shasum -a 256 -c MonkeysPaw-<version>.sha256
```

Both archives must report OK. Open the dmg, drag `MonkeysPaw.app` to
Applications, eject the image and open the installed copy. The packager signs
ad-hoc by default; certificate provisioning and notarization are outside the
workflow. If Gatekeeper blocks a build you trust, use System Settings →
Privacy & Security → **Open Anyway** when offered. Follow the
[installation procedure](docs/platform/macos.md#m2-macos-artifacts-and-installation-not-run).

**Automatic update checks default on at first versioned launch.** GitHub sees
your IP and app version. Settings → General can turn checks off; Check Now
works while off. View release opens your browser. Download, verify, quit the
app and replace the installed copy yourself. Read [Privacy](PRIVACY.md#desktop-update-requests)
and [Security](SECURITY.md#downloads-and-signing) before launch.

## First hotkey and paste

1. Use Setup to grant Accessibility under System Settings → Privacy &
   Security → Accessibility. Add the exact installed app if needed, return
   to Setup and Refresh. An update or signature change may need a new grant.
2. Press and release **Control+Option+P** over a harmless editable field.
   Search, choose a prompt with Return and fill its fields. Return delivers
   from a single-line field; **Cmd+Return** delivers from a multiline field,
   where ordinary Return inserts a newline. Paste uses **Cmd+V**.
3. Use **Option+Return** or Copy for clipboard-only delivery. Escape cancels.
   Run Setup's self-test and check actual text in Safari, Chrome and Terminal;
   the app does not send a Return key to the target.

The app lives in the menu bar. Open Library and Settings there. Library edits
Markdown under `~/Documents/MonkeysPaw` by default; General can choose a folder.
Use [the format guide](docs/plan/05-prompt-library.md) for external edits.

## Repeat and Delivery settings

Settings → Shortcuts lets you assign, clear and verify each action. Repeat
starts unbound. It reuses exact field values from the latest completed
delivery, refreshing date/time and any used clipboard builtin for your
current target. Non-remembered values are session-only; after restart you
must reopen those prompts. Changed or inaccessible source also needs review.
Forget clears the corresponding remembered and repeat state. See
[retention and Forget](PRIVACY.md#forget-repeat-and-clipboard).

Settings → Delivery shows backend/permission status, Test paste and Open Setup.
**Restore previous clipboard text** is off by default. It preserves text only,
with a guarded 750 ms delay that can be too short for slow apps. A newer
observed clipboard copy cancels restore, even if its text is identical; a
simultaneous external copy cannot be atomically excluded by the OS.

## Troubleshooting

If paste fails, the result stays on the clipboard: use Cmd+V yourself. Grant
Accessibility again if needed, then use Test paste to reset failed backends.
The AppleScript fallback may need Automation → System Events permission;
grant it and rerun after a timed-out prompt. Focus, full-screen Spaces,
paste-privacy prompts and Keychain approvals need checks on your Mac.

See [macOS procedures](docs/platform/macos.md#m7-current-desktop-procedures),
[Assistant setup](docs/platform/assistant.md), [hosting](docs/platform/server.md#host-the-sync-server)
and [build/release prerequisites](CICD.md). Desktop Account/invite code on this
branch is from the M6 base awaiting main integration; the dedicated sync guide
and sync acceptance remain Y34/Z27 work.

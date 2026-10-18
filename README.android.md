# Android

You need Android API 26 or later. This guide covers the Android app behavior
already merged into main. Physical-device acceptance remains **NOT RUN
(owner)** in the [Android record](docs/platform/android.md). Sync repository,
background scheduling, Account/status screens, Library groups and role-aware
Library, Editor and Assistant integration are on main. Invite and
conflict-resolution UI integration and phone/desktop acceptance remain
M10 Z27 work. The [desktop sync guide](docs/platform/sync.md) records desktop
setup and proof limits.

## Install or update

Download `monkeyspaw-v<full-version>.apk` and its `.apk.sha256` from this
repository's [Releases](https://github.com/L-K-M/MonkeysPaw/releases) when
available. Replace `<full-version>` including any suffix, then verify:

```sh
sha256sum -c monkeyspaw-v<full-version>.apk.sha256
adb install -r monkeyspaw-v<full-version>.apk
```

On macOS use `shasum -a 256 -c`. `adb` needs SDK platform-tools and USB
debugging. You can instead open the verified APK on your device and allow
installation from that source. See the [signature/upgrade procedure](docs/platform/android.md#release-apk-verification).

Debug and shrunk release APKs share `ch.lkmc.monkeyspaw` and the committed
**public signing key**, so they replace one another. Anyone with that key
can sign an update retaining app data; the signature does not identify the
publisher. Obtain APKs from this repository's releases. Changing the signer
requires reinstalling, and uninstall removes app-private data. Read the
[signing decision](docs/decisions/0001-android-zero-secret-signing.md).

## Pick, fill and insert

Open the app to browse/search the local library, add starter prompts, edit
raw Markdown, inspect fields/preview and restore local history. Seeds are
offered for an eligible empty library without overwriting existing prompts.
Settings → **Keyboard and tile setup** explains the Android keyboard warning
before asking you to enable the picker keyboard. It also helps you select
the picker and add the tile; you can skip steps and reopen setup later.

| Entry | What you do |
|---|---|
| Picker keyboard | Switch to Monkey's Paw while typing in a target app. Pick a prompt and insert through the current InputConnection. For fields needing typing, open the Copy form and paste back yourself. Password fields hide prompts; single-line/Termux multiline or unavailable connections offer Copy instead. The app does not send an Enter/editor action. |
| Quick Settings tile, launcher Insert prompt shortcut or widget | Open pick → fill → Copy, then paste in your target app. A locked tile requires unlock. These entries do not auto-paste or start a target app. |
| Text-selection action, where the target offers it | Use selected text in a prompt. Writable selection can return replacement text; read-only selection offers Copy. The target app controls whether it accepts a replacement. |
| Share text/plain to Monkey's Paw | Choose Fill a prompt or start an unsaved New prompt from the shared text. Fill ends in Copy; New prompt requires explicit Save. |

The picker keyboard is not a typing keyboard and does not read surrounding
target text. It uses editor metadata and connection readiness. The app tries
to return to your previous keyboard after insertion; if switching is
unavailable, use Android's keyboard picker. Check the actual target and clear
harmless terminal test text without executing it. See the
[IME procedures](docs/platform/android.md#m9-ime-insertion-and-switch-back-not-run).

## Privacy and Assistant

Prompt files, remembered fields and history are app-private and are not
encrypted by the app. Android Auto Backup is disabled. Forget values clears
remembered fields/drafts, not prompt source, history or other apps' clipboard
copies. Copy marks text sensitive. Non-remembered capture and handoff data
stay in memory; `IME_FLAG_NO_PERSONALIZED_LEARNING` suppresses usage and
remembered-value writes. Read [Privacy](PRIVACY.md#forget-repeat-and-clipboard).

Settings → Assistant configures Anthropic or an OpenAI-compatible endpoint,
including loopback Ollama. Test connection sends a model-list request;
Write/Review/Improve send explicit inputs only, showing provider host/model
before sending. `private: true` blocks Review/Improve. Fill previews and
remembered values are not automatically sent. Your phone's `localhost` is
the phone; use loopback forwarding or trusted HTTPS for a desktop server.
Saved keys use AndroidKeyStore with no plaintext fallback; hardware backing
depends on your device. See [Assistant disclosures and owner checks](docs/platform/android.md#android-assistant-m11-not-run-owner).

There is no desktop-style automatic GitHub update checker in the merged
Android app. Install verified APK updates yourself. Device Keystore, real
provider, keyboard, clipboard and upgrade checks remain owner-run.

## Build and troubleshoot

For a local APK, install JDK 17+ and SDK `platforms;android-37.0` plus
`build-tools;36.0.0`, set JAVA_HOME/ANDROID_HOME, then run
`scripts/build.sh android --no-open`. CI uses JDK 17; JDK 21 also works locally.
The wrapper gate is `android/gradlew -p android :core:test testDebugUnitTest
lintDebug assembleDebug assembleRelease`. See [CICD.md](CICD.md) for outputs,
version rules and the Google Maven mirror option on the implementation host.

For setup/entry problems, reopen Keyboard and tile setup and check current
Android settings. For target insertion failures, use Copy and paste yourself;
never infer receipt from a successful API call. Preserve the existing
[M8/M9/M11 NOT RUN rows](docs/platform/android.md) when recording device
results. No Android source or acceptance result is changed by this guide.

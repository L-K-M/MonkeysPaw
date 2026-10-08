## 17. Open questions

Each question has a default, and the plan proceeds on it unless the owner
says otherwise.

| # | Question | Default |
|---|---|---|
| Q1 | Linux UI: plain GTK4, or GTK4 + libadwaita styling (GNOME look, foreign on KDE)? | Plain GTK4 |
| Q2 | Default library location: `~/Documents/MonkeysPaw`, or a hidden app-data folder? | `~/Documents/MonkeysPaw` |
| Q3 | macOS signing: unsigned (family default), ad-hoc, or a stable Developer ID identity so Accessibility and Keychain grants survive updates? | A stable signing identity, if available. Paste needs Accessibility, so this matters more here than for other family apps. |
| Q4 | Default picker hotkey `⌃⌥P` (macOS) / `Ctrl+Alt+P` (Linux)? `Ctrl+Alt+E` is the Linux alternative if the JetBrains overlap matters. | `⌃⌥P` / `Ctrl+Alt+P`, re-checked in M1 |
| Q5 | Bundle name `MonkeysPaw.app` with display name "Monkey's Paw" (avoids an apostrophe in paths)? | Yes |
| Q6 | Default Anthropic model `claude-opus-5-5`, or the cheaper `claude-sonnet-5-5`? | `claude-opus-5-5` |
| Q7 | Group move semantics: does moving a prompt into a group transfer it (Bitwarden), or copy it? | Transfer |
| Q8 | Support Ubuntu 22.04 (GTK 4.6, extra shim forks) or 24.04+ only? | 24.04+ |
| Q9 | Server images: amd64 + arm64, or amd64 only? | Both |
| Q10 | Should a group viewer be able to see who edited what (revision authors)? | Yes, read-only |
| Q11 | An in-app update check (Vervellum's GitHub checker), on by default? | Yes, disclosed in PRIVACY.md, can be turned off |
| Q12 | Android signing: the fleet's checked-in key (no CI secrets; anyone with the repo can sign), or a private release key in CI secrets (switching later breaks upgrades)? | The checked-in key, like HalloMiao, recorded as an ADR |
| Q13 | Android distribution: GitHub Releases only (fleet rule), or also Obtainium-friendly naming? | GitHub Releases, with stable asset names that Obtainium can track |

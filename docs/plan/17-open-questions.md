## 17. Open questions

Each question has a default, and the plan proceeds on it unless the owner
says otherwise.

Assistant (M4) and sync server (M5) implementation defaults live in §19.
Where both cover a topic, the §17 answer wins and §19 refines it.

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
| Q14 | M3 conflict timing: when the open prompt changes on disk while you have unsaved edits, show the conflict dialog immediately, or only when you save? | Immediately (event-driven), and again on a stale save. Without unsaved edits the editor reloads silently. §11.7 |
| Q15 | M3 editor: edit the raw file (front matter and body) or structured metadata forms? Is Fields editable? | Raw source in Edit with live validation; Fields is a read-only inspector; Preview uses defaults, never reads the clipboard. §11.7 |
| Q16 | M3 browse scope: which sidebar sections ship before sync? | All, Favourites, Recent (last delivery or copy, from the usage store), folders, tags. Conflicts and groups arrive with sync (M6). Favourite toggling saves `favourite` in front matter through the editor's service (it edits the open editor's text if that prompt has unsaved edits). §11.7 |
| Q17 | M3 unsaved edits: what happens on selection change, close, rename, move, delete, revert, library switch and quit? | Selection change, close, rename, move, delete, revert and quit ask Save / Discard / Cancel and wait for a save in flight. Both desktops refuse library switches while the editor has unsaved edits, a save or file command in flight, a pending decision or queued actions; Settings shows an editor-specific message and keeps the active library. §11.7 |
| Q18 | M3 import mapping: which Dotprompt/Prompty input types map to fields? | `string` → text, `string` with enum → choice, defaults kept; everything else preserved as metadata and reported. Never overwrite; imports land in `Imported/`. §11.7 |
| Q19 | M3 tour: who sees the one-screen tour, and does closing it count? | New installs only, right after the seed step; closing counts as done; upgrades from v0.1.0 are marked done. §11.7 |
| Q20 | M3 rename/move/delete: what can you rename, and where do deleted prompts go? | Rename edits the filename (the title stays in front matter); move targets an existing or new folder; an occupied destination is refused. Delete keeps history; restoring a deleted prompt waits for a later milestone. §11.7 |

## 16. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GNOME Wayland drops ydotool chords silently | High | Paste no-ops | Portal first on GNOME; the self-test verifies real delivery; copy-only fallback; measured in M1c. |
| `@MainActor` / `DispatchQueue.main` in Core hangs the Linux app silently | Medium | Dead UI | Portability rule; Linux CI; injected `MainThread` port; Swift 5 mode for desktop targets. |
| Wayland focus does not return to the target | Medium | Paste lands nowhere | Hide, then settle; text always on the clipboard; notification. |
| GlobalShortcuts portal missing (Ubuntu 24.04 = GNOME 46) | Certain on 24.04 | No portal hotkey | gsettings keybinding + `gapplication action` (proven in Vervellum). |
| KDE portal session goes stale | High | 6-19 s paste stalls | ydotool first on KDE; failure cache; 2 s portal timeout. |
| RemoteDesktop `Notify*` superseded by EIS/libei | Medium (long term) | Portal paste breaks on a future backend | Ladder fallback; watch xdg-desktop-portal releases; a libei shim is a contained addition. |
| macOS TCC grants lost on each update of an ad-hoc build | High | Re-grant Accessibility after every update | Stable signing identity (Q3); detection and explanation in Setup. |
| GTK4 shim grows large | Medium | Slow Linux UI work | Wrap only what §11.1 lists; keep the Linux UI plainer; presentation models hold the logic. |
| Hummingbird minor releases churn (2.27 dropped Swift 6.1) | Medium | Build breaks on upgrade | Pin versions; upgrade deliberately; server tests gate. |
| SwiftPM pulls GTK into the server build | Low | Server image fails | Target layout in §4.4; proven in M0. |
| Sync bugs lose edits | Medium | Data loss | Compare-and-swap; conflict copies instead of overwrites; trash instead of delete; server revisions; the §13.1 scenario suite. |
| Server exposed to the internet without TLS | Medium | Credential theft | Loopback bind by default; `tls` profile; the client refuses public `http://`. |
| Operator can read all prompts | Certain | Privacy expectation mismatch | Stated in SECURITY.md and the README; E2EE deferred with a retrofit path. |
| Kotlin port drifts from the Swift core | Medium | Different renders, sync bugs on one platform | `spec/fixtures/` consumed by both suites; schema drift check; the server validates every upload with the Swift core; the move-together rule (§10.7). |
| Users never enable the Android keyboard | Medium | The fast lane goes unused | Onboarding sets up the keyboard and the tile together; the tile → fill → copy flow is fully usable on its own. |
| Multi-line text into a terminal or single-line field on Android | Medium | Commands run, or newlines vanish | The `inputType` check; Copy instead; never send Enter (§10.4). |
| Checked-in Android signing key | Certain | Anyone can sign an "update"; switching keys breaks upgrades | GitHub Releases only, with SHA-256 files; the owner decides (Q12). |
| Scope creep (web UI, chat, scripting) | Medium | Delay | Non-goals §1; deferred list §15. |

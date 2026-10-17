# M7 acceptance ledger

M7 is open. **Every result and evidence field below starts NOT RUN.** No
hardware, compositor, consent, clipboard-privacy or installed-artifact result
was supplied for D19. Automated tests and candidate-branch runs cannot close
the milestone. D20 records owner results after the implementation is on main.

Use only **PASS**, **FAIL**, **BLOCKED** or **NOT RUN** for results. PASS needs
actual observations and sanitized evidence for that row on its exact main SHA
and artifact. FAIL records an observed mismatch; BLOCKED records an unavailable
required environment/prerequisite; NOT RUN means no attempt. An unsupported
feature needs its accepted platform rule and demonstrated fallback, recorded
as such with evidence. Do not silently drop a required row or add an aggregate
PASS while required evidence is missing.

## Recording a run

Follow the linked procedure. Record the full main SHA and packaged artifact
name, version/build and SHA-256, not just a branch name or a CI run. Include
OS/distro and version, architecture, compositor/session, physical hardware
and keyboard layout, signing identity, portal interfaces/versions/device
capabilities, effective shortcut and paste backends, grant/revocation state,
target application version/field or terminal class, date/tester and evidence.

Duplicate rows for each target, backend, normal/full-screen mode, architecture
or artifact needed by the procedure. Keep source/candidate observations and
published-artifact observations in separate rows; identify a candidate as
candidate in its main-SHA cell until rerun on main. Old M1/M2 results cannot
be inherited without the same procedure and exact-build evidence. Keep all
earlier NOT RUN rows in the OS checklists. This ledger does not close M6 sync,
M8/M9 Android or M11 Assistant acceptance.

Use disposable Unicode/multiline text, check exact target readback once and
confirm the app sent no Return/editor action. Run the same build's self-test
plus a real browser/chat field and terminal on every supported delivery path.
Do not record prompt/field/clipboard contents, credentials, invite URLs,
portal restore/activation tokens or raw error bodies. Record safe outcomes,
versions, hashes, issue references and redacted screenshots only.

## Owner prerequisites

The repository's read-only private-vulnerability-reporting API returned
`enabled: false` on 2026-10-16. The intended confidential route is the
[repository Security tab](https://github.com/L-K-M/MonkeysPaw/security),
**Report a vulnerability**, as described in [SECURITY.md](../../SECURITY.md).
It is unavailable until the owner enables it. No alternate contact is verified.

| Prerequisite | Result | Evidence |
|---|---|---|
| Owner enables GitHub private vulnerability reporting before release and verifies Report a vulnerability is available | NOT RUN | NOT RUN |
| Reconcile D1–D19 onto main and identify final CI/reviewed artifacts before D20 | NOT RUN | NOT RUN |
| Supply installed macOS, native GNOME/KDE Wayland, ordinary X11 and GNOME-/KDE-host Flatpak sessions, plus GNOME/KDE X11 where available | NOT RUN | NOT RUN |
| Record actual signing identities and macOS Accessibility/Keychain approvals; do not assume notarization | NOT RUN | NOT RUN |
| Accept the opt-in clipboard simultaneous-copy/750 ms limits or keep restore off where an absolute guarantee is required | NOT RUN | NOT RUN |
| Review Flatpak whole-home/overrides, working Secret Service and one active installation route | NOT RUN | NOT RUN |
| Verify published assets/checksums and required runtime availability; make first ghcr package public if using that distribution path | NOT RUN | NOT RUN |

## Desktop and Flatpak runs

Each row below carries its own build/session evidence. The linked procedures
define the detailed observations, including failures and accepted fallbacks.

| Run / procedure | Result | Main SHA | Artifact version/build/hash | OS/compositor/session | Hardware/keyboard | Signing | Portal capabilities/backend | Test target | Date/tester | Evidence/issue |
|---|---|---|---|---|---|---|---|---|---|---|
| [macOS: dmg and zip install/signing/permissions](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: self-test and Safari normal/full-screen](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: Chrome normal/full-screen](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: Terminal normal/full-screen/no Return](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: both shortcuts and Repeat/current target/restart/Forget](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: restore off/on/slow target/identical and different copies](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [macOS: General updates and Delivery/VoiceOver/settings lifecycle](macos.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME Wayland native: portal two-action consent and cold/resident activation](gnome.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME Wayland native: self-test/browser/terminal/focus/denial fallback](gnome.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME Wayland native: no-GlobalShortcuts native fallback/both actions](gnome.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME Wayland native: Repeat/restart/Forget and restore off/on/competing copies](gnome.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME Wayland native: General updates and Delivery/Orca/settings lifecycle](gnome.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE Wayland native: native two-action registration/verification/restart](kde.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE Wayland native: portal/native transitions/custom/unbound/multi-chord/races](kde.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE Wayland native: self-test/browser/Konsole/focus and failed-backend fallback](kde.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE Wayland native: Repeat/restart/Forget and restore off/on/competing copies](kde.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE Wayland native: General updates and Delivery/Orca/settings lifecycle](kde.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [Native X11: ordinary WM plus GNOME/KDE X11 available sessions](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [Native X11: self-test/browser/terminal and default/explicit chord/no Return](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [Native X11: two actions/cold activation/Repeat different target](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [Native X11: restore off/on/slow target/competing identical copy](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [Native X11: General updates and Delivery/keyboard/Orca/settings lifecycle](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME-host Flatpak: install/upgrade/exports/permissions/home/state/Secret Service/tray](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME-host Flatpak: cold/resident actions and browser URI staging/no redemption](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME-host Flatpak: two-action portals/self-test/browser/terminal/denial fallback](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME-host Flatpak: Repeat/restart/Forget and restore off/on/competing copies](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [GNOME-host Flatpak: General updates/OpenURI and Delivery/Orca/settings lifecycle](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE-host Flatpak: install/upgrade/exports/permissions/home/state/Secret Service/tray](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE-host Flatpak: cold/resident actions and browser URI staging/no redemption](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE-host Flatpak: two-action portals/self-test/browser/terminal/denial fallback](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE-host Flatpak: Repeat/restart/Forget and restore off/on/competing copies](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| [KDE-host Flatpak: General updates/OpenURI and Delivery/Orca/settings lifecycle](flatpak.md) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

## X11 alias evidence

Run each exact case-insensitive alias independently on native X11. Record the
actual WM_CLASS and terminal version, preferred Ctrl+Shift+V readback,
explicit override and no unintended submission. A missing terminal remains
NOT RUN until attempted, then BLOCKED if unavailable. The CI XTerm smoke uses
a custom paste binding and cannot satisfy these rows. Unknown/lookalike
classes, XTerm/URxvt/st and Wayland/Flatpak use the saved default or explicit
choice, with fallback checked in the Linux procedure.

| Run / procedure | Result | Main SHA | Artifact version/build/hash | OS/compositor/session | Hardware/keyboard | Signing | Portal capabilities/backend | Test target | Date/tester | Evidence/issue |
|---|---|---|---|---|---|---|---|---|---|---|
| `Gnome-terminal`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `gnome-terminal-server`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `konsole`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `Xfce4-terminal`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `mate-terminal`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `Tilix`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `Alacritty`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| `kitty`: [Linux procedure](linux.md#m7-current-desktop-procedures) | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

## Procedure ownership and remaining work

- [macOS](macos.md#m7-current-desktop-procedures), [GNOME](gnome.md#m7-current-desktop-procedures),
  [KDE](kde.md#m7-current-desktop-procedures), [Linux/X11](linux.md#m7-current-desktop-procedures)
  and [Flatpak](flatpak.md) retain detailed procedures and their earlier results.
- D20 collects actual owner runs, follows up verified defects separately and
  reconciles the final main/artifact baseline before milestone closure.
- Desktop Account, invites, sync status, groups and conflict resolution are
  available on main. Automated device-token privacy fixtures passed both
  native CI suites; signed apps, real keyrings, deployed servers and physical
  devices still need owner checks. The [desktop sync guide](sync.md) records
  automated proof and open owner checks. Y34 still owns desktop sync
  privacy/deployed closure; Z27 owns Android sync closure. Android's repository,
  background scheduling and Account/status screens are on main; Library sync,
  group, invite and conflict-resolution UI integration remains pending.
  See [§15](../plan/15-milestones.md) and the existing [server](server.md) and
  [Android](android.md) records. M7's URI staging procedure proves no sync
  transfer or invite redemption acceptance.

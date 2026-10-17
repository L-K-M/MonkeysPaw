# Desktop sync setup and verification

This guide records the merged desktop contract at main
`2685e948c2f0f6288ee523a929abb56a0c0bf70c`. Automated evidence below has
its own exact revisions; it does not complete the owner checks or close M6.
The contracts remain [§9](../plan/09-sync-client.md),
[§12](../plan/12-security-and-privacy.md) and
[M6 decisions](../plan/20-m6-m8-decisions.md#m6-sync-client).

## Set up a disposable verification pair

1. Use two actual desktops, preferably macOS and Linux, two distinct users,
   and a deployed server. Record the evidence fields below before starting.
   Follow the existing [deployment and HTTPS procedure](server.md), including
   its backup/restore drill, rather than using the CI scenario server as a deployment.
2. Sync is optional. Local prompts work without an account. In Settings →
   Account, enter Server address, Username, Password and Device name, then
   explicitly choose **Sign in**. First sign-in adopts matching prompts and
   uploads eligible unmatched files in the chosen library; use disposable content.
   If Account reports reserved `Groups`/`Conflicts` entries, resolve the listed
   collision and sign in again. Only the issued device credential is saved.
   One active connection binds the normalized server and user to the library;
   its saved credential also binds the local connection UUID.
3. Use the deployment base URL, including any deployment prefix. The
   [normalizer](../../Sources/MonkeysPawCore/Sync/SyncServerURL.swift) removes
   trailing slashes, default ports and repeated `/api/v1` suffixes, and normalizes
   scheme/host. It rejects embedded credentials, queries, fragments and unsafe
   prefixes. HTTPS is required except `localhost`, literal loopback addresses,
   literal RFC1918 IPv4 (`10/8`, `172.16/12`, `192.168/16`) and IPv6 ULA (`fc00::/7`).
   DNS resolving to a LAN address grants no HTTP exception; redirects are refused.
   Allowed HTTP is unencrypted, including credentials; invite review displays
   an HTTP warning before acceptance.
4. For a new account, open **Join with an invite**, paste a link, or enter a bare
   token with an explicit server, then **Review invite**. Check the destination
   and current account. Only **Accept with current account** or **Accept and
   create account** redeems it. Opening a `monkeyspaw://join` link merely stages
   it; a different server requires signing in there and reviewing again.
   Inputs and staged invites clear on dismissal/submission as described in the
   [macOS](macos.md#m6-y23-invite-activation-not-run) and
   [Linux](linux.md#invite-activation-m6-y24-not-run) procedures.
5. In Account → Groups, create a group as its owner; add the second user by ID
   or create a one-use viewer/editor invite. Share a disposable group prompt and
   verify both desktops converge. Exercise owner/editor/viewer permissions,
   membership removal and group rename separately. Personal prompts must remain
   invisible to the other user. Group `favorite` is a local account overlay;
   group `private` is stripped with a warning, not a private sharing boundary.
6. Inspect the Library sync footer and Account cleanup messages after every action.
   Use **Sync now** to request a pass; an authentication failure requires sign-in.
   A server/user change holds previous-account files locally until **Include in
   this account**; editing them alone does not authorize upload. **Keep local**
   preserves the hold. A different library root starts fresh adoption without
   inferring deletes from the old root. See [state and binding](../plan/09-sync-client.md#92-state).
7. **Sign out** stops work, disables resume, attempts remote revocation and removes
   persisted device credentials while leaving library files. Record incomplete
   revocation/cleanup and retry; do not equate local sign-out with confirmed remote
   revocation. Linux `MONKEYSPAW_DEVICE_<UUIDHEX>_TOKEN` is a read-only process
   override: persisted deletion cannot remove it from the process, and it cannot
   automatically reactivate a signed-out connection.

Remembered field values, history and repeat state stay local. Prompt sync is
separate from explicit Assistant submission; `private: true` is not a promise
that a personal prompt stays off the configured sync server. Server SQLite
contains plaintext prompts, readable by its operator; v1 has no end-to-end
encryption. HTTPS protects transit; an allowed HTTP address does not.
On Linux, D-Bus Open is preferred, but a launcher fallback can expose the
one-use invite URL in OS argv. This narrow exception does not apply to device
tokens or passwords. Never paste credentials, full invite links, HTTP bodies,
headers or prompt content into verification records.

Account reports the secret tier. macOS uses Keychain without a plaintext
fallback. Linux uses Secret Service when `secret-tool` is installed; a locked
or unavailable service fails writes without silently falling back. With the
tool absent, saved credentials use the explicitly unencrypted file tier
([storage policy](../plan/12-security-and-privacy.md)).

## Scenario inventory and execution owners

The merged corpus has **23 families, 87 variants, 24 JSON files**. Each row owns
every case in its linked file(s); `NN-*` denotes the stable case-ID prefix, not
a selected sample. Family 06 spans two files. Counts are structural inventory,
not a claim that this documentation change executed scenarios.

| §13.1 family | Fixture files (all cases) | IDs | Variants |
|---|---|---|---:|
| 01 Round trip and own echo | [01-round-trip.json](../../spec/fixtures/sync/01-round-trip.json) | `01-*` | 1 |
| 02 Offline conflicts, CAS and lost acknowledgements | [02-offline-conflict.json](../../spec/fixtures/sync/02-offline-conflict.json) | `02-*` | 6 |
| 03 Edit/delete in both directions; 410 | [03-edit-delete.json](../../spec/fixtures/sync/03-edit-delete.json) | `03-*` | 6 |
| 04 Viewer denial and access changes | [04-viewer-denied.json](../../spec/fixtures/sync/04-viewer-denied.json) | `04-*` | 9 |
| 05 Private/group transfers and move plus edit | [05-scope-transfers.json](../../spec/fixtures/sync/05-scope-transfers.json) | `05-*` | 7 |
| 06 Offline member removal, including retention | [06-removed-offline.json](../../spec/fixtures/sync/06-removed-offline.json), [06-removed-retention.json](../../spec/fixtures/sync/06-removed-retention.json) | `06-*` | 2 |
| 07 Added member snapshot | [07-added-member.json](../../spec/fixtures/sync/07-added-member.json) | `07-*` | 2 |
| 08 Snapshot triggers, paging and expiry | [08-snapshot-triggers.json](../../spec/fixtures/sync/08-snapshot-triggers.json) | `08-*` | 7 |
| 09 Paired moves in one pull | [09-paired-move.json](../../spec/fixtures/sync/09-paired-move.json) | `09-*` | 2 |
| 10 Group rename/delete | [10-group-lifecycle.json](../../spec/fixtures/sync/10-group-lifecycle.json) | `10-*` | 3 |
| 11 Exact, case and Unicode path clashes; bounds | [11-path-clashes.json](../../spec/fixtures/sync/11-path-clashes.json) | `11-*` | 5 |
| 12 Hostile paths and local visibility | [12-untrusted-paths.json](../../spec/fixtures/sync/12-untrusted-paths.json) | `12-*` | 10 |
| 13 Copied-library adoption without duplicates | [13-copied-library.json](../../spec/fixtures/sync/13-copied-library.json) | `13-*` | 4 |
| 14 User/server/account switch isolation | [14-account-change.json](../../spec/fixtures/sync/14-account-change.json) | `14-*` | 3 |
| 15 Group favourite without a push loop | [15-group-favourite.json](../../spec/fixtures/sync/15-group-favourite.json) | `15-*` | 1 |
| 16 Invalid content, 422 and no retry loop | [16-invalid-content.json](../../spec/fixtures/sync/16-invalid-content.json) | `16-*` | 2 |
| 17 Process death during apply and replay | [17-crash-apply.json](../../spec/fixtures/sync/17-crash-apply.json) | `17-*` | 4 |
| 18 Rename versus edit | [18-rename-edit.json](../../spec/fixtures/sync/18-rename-edit.json) | `18-*` | 2 |
| 19 Racing moves to different scopes | [19-racing-moves.json](../../spec/fixtures/sync/19-racing-moves.json) | `19-*` | 2 |
| 20 Own move echo and split pages | [20-move-echo-pages.json](../../spec/fixtures/sync/20-move-echo-pages.json) | `20-*` | 3 |
| 21 Remote rename without echo | [21-remote-rename.json](../../spec/fixtures/sync/21-remote-rename.json) | `21-*` | 2 |
| 22 Restore with lower heads | [22-restore-lower-head.json](../../spec/fixtures/sync/22-restore-lower-head.json) | `22-*` | 3 |
| 23 Fully purged quiet scope | [23-quiet-scope-retention.json](../../spec/fixtures/sync/23-quiet-scope-retention.json) | `23-*` | 1 |

The [scenario contract](../../spec/README.md#sync-scenario-contract-version-1)
and [§13.1](../plan/13-testing.md#131-sync-tests) define execution:

- Swift: [SyncScenarioTests.testEverySyncFixtureExecutesAgainstTheRouter](../../server/Tests/MonkeysPawSyncIntegrationTests/SyncScenarioTests.swift)
  owns all 87 through Core and the real Hummingbird router/auth/services/repositories
  on migrated temporary SQLite. The existing server-suite command runs it once
  per selected server job; PR path selection can skip that job.
- Kotlin: [ScenarioRunnerTest](../../android/core/src/syncIntegrationTest/kotlin/ch/lkmc/monkeyspaw/core/integration/ScenarioRunnerTest.kt)
  owns all 87 in `:core:syncIntegrationTest` through the production engine/shared
  OkHttp driver and same-head live server. The mandatory [android-sync CI job](../../.github/workflows/ci.yml)
  uses the existing [wrapper/accounting](../../scripts/android-sync-ci.py), requiring
  successful content and sync ownership. Root content enumeration delegates sync;
  it is not another semantic runner. Unknown/unconsumed cases or checkpoints fail.

Accepted execution receipts are [#265](https://github.com/L-K-M/MonkeysPaw/pull/265)
at `defb11761d609ec01633b44cc5a514696f37f25d`
([code CI 39020533661](https://github.com/L-K-M/MonkeysPaw/actions/runs/39020533661),
[Release 39020533692](https://github.com/L-K-M/MonkeysPaw/actions/runs/39020533692)) and
[#273](https://github.com/L-K-M/MonkeysPaw/pull/273) at
`83d0b4d6308b95d0f02390797bda6aeb5523baef`
([code CI 39025789008](https://github.com/L-K-M/MonkeysPaw/actions/runs/39025789008),
[Release 39025789029](https://github.com/L-K-M/MonkeysPaw/actions/runs/39025789029)).
Both code and Release gates at each accepted revision passed full 87-case/content
accounting. These receipts do not assert success of a later main push CI, Android
connected UI/scheduler acceptance, deployed sharing or physical durability.

## Finite native privacy proof

[#284](https://github.com/L-K-M/MonkeysPaw/pull/284) was accepted at
`7d113907d22d7fb4328458726a661716f7a5c7c6` with
[whole CI 39029649573](https://github.com/L-K-M/MonkeysPaw/actions/runs/39029649573)
successful; main `2685e948` imports that validated test-only delta. The earlier
`f3f3f458` [CI 39026373545](https://github.com/L-K-M/MonkeysPaw/actions/runs/39026373545)
timed out in the whole Linux job despite passing the new tests. Combined scans
corrected that budget regression without increasing the 20-minute gate.

| Native suite | Accepted execution | Boundary and expectation |
|---|---|---|
| [LinuxSecretScanTests](../../Tests/MonkeysPawLinuxTests/LinuxSecretScanTests.swift) | [Linux job 117387873087](https://github.com/L-K-M/MonkeysPaw/actions/runs/39029649573/job/117387873087): whole job 17m39s; all 8 methods passed; device cases 47.821s / 52.008s | Production account/invite services, composition and Linux secret drivers; actual file fallback and native Secret Service driver over a **fake private-bus service**, with deterministic HTTP fakes. |
| [KeychainSecretScanTests](../../MonkeysPawTests/KeychainSecretScanTests.swift) | [Hosted macOS job 117387873251](https://github.com/L-K-M/MonkeysPaw/actions/runs/39029649573/job/117387873251): all 6 methods passed, lifecycle 8.950s, no skip | Production account/invite models/services and real Keychain with per-operation interaction suppression, unique item and stub HTTP. |

Linux retains 14 device checkpoints per tier (28 total), nine runtime sentinels
per checkpoint; macOS retains 11 checkpoints and eight sentinels. They cover
save/activation failure and cleanup/retry, reconstruction, user/server changes,
sign-out and invite/password clearing; Linux also covers the read-only override.
Each checkpoint verifies the unrelated provider and another device account.

Scans include the actual repository (hidden files and `.build`), isolated config,
data, application/fixture logs and owned temporary roots, including both libraries
and the other device's data. Every current and retired known sentinel is included
in one combined traversal at **each** checkpoint, without cross-checkpoint caching.
Strict Secret Service/Keychain expectations are zero matching disk paths. Linux
file-tier matched paths must equal exactly the named `secrets-unencrypted.json`;
every sentinel separately has count 1 while saved or 0 when retired/transient.
The fallback must be a regular atomic file, mode 0600, owned by the effective UID,
with one link and the `unencrypted` label; unrelated credentials remain readable.

The [Linux](../../Tests/MonkeysPawLinuxTests/SecretScanSupport.swift) and
[macOS](../../MonkeysPawTests/SecretScanSupport.swift) scanners retain raw/base64,
percent and nested JSON variants, bounded chunk reads/overlap, required-root
failures and only-vanished-descendant tolerance. Calibration includes every
combined sentinel/encoding, cross-chunk matches, disjoint/overlapping roots,
a non-first-token wrong-file leak and a retired copy in the permitted vault.
An unreadable-root test follows actual OS read capability, including privileged CI.

This proves known-token absence only in those roots/checkpoints. The macOS fixture
log is not process stderr or unified OS logs. It does not prove whole-machine
absence, real desktop libsecret/keyring consent, signed Keychain ACL behavior,
installed browser dispatch, physical devices or power-loss durability.

## Required owner acceptance ledger

All rows start **NOT RUN**. CI cannot mark a physical row PASS. Use disposable
content/accounts and append one evidence record per row/platform; a missing
prerequisite must be recorded as BLOCKED with its reason. Existing platform
ledgers retain their own statuses.

For **each row**, fill: exact main commit; installed artifact SHA-256/version;
OS/build/device and signing/keyring identity; deployed server commit/image digest
and version; user aliases/roles; tester; UTC date; actions/observations; result;
sanitized evidence location. Leave credentials and content out. A PASS applies
only to that recorded combination, not another main, build or platform.

| Initial status | Required owner observation | Procedure / contract | Evidence record |
|---|---|---|---|
| NOT RUN | Two actual desktops/two users share a group prompt through the deployed server; personal isolation, owner/editor/viewer roles, member addition/removal and group rename/delete | [Server desktop procedure](server.md#desktop-login-push-and-pull-after-m6-not-run), families 01/04–07/10 | — |
| NOT RUN | Offline concurrent edits, edit/delete both ways, conflict resolution, rename/edit and every private↔group/group↔group transfer preserve the losing version | [Conflicts and errors](../plan/09-sync-client.md#96-conflicts-and-errors), families 02/03/05/18–21 | — |
| NOT RUN | Restart/reconnect/suspend, interrupted apply recovery and disposable lower-head server restore preserve content without duplicates or false deletes | [Backup/restore drill](server.md#backuprestore-drill-not-run), families 08/13/17/22/23 | — |
| NOT RUN | User/server/account and library-root switches hold old files; unavailable native root disables mutations/deletes; restored root recovers; late replies cannot affect the replacement graph | [Binding](../plan/09-sync-client.md#92-state), [E35](../plan/20-m6-m8-decisions.md#m6-sync-client), [Linux](../../Tests/MonkeysPawLinuxTests/LinuxSyncCompositionTests.swift)/[macOS](../../MonkeysPawTests/MacSyncCompositionTests.swift) seams | — |
| NOT RUN | Sign-out/current-device revoke, failed cleanup/retry and restart disable resume, retain local files and unrelated provider/device credentials; distinguish environment overrides from persisted deletion | [Account/Keychain consent](macos.md#m6-y20-account-settings-not-run), [Linux storage](linux.md#secret-storage-m4-a4-not-run), E23/E25/E26 | — |
| NOT RUN | Installed cold/resident browser and launcher invites open Account once, never redeem before explicit accept, clear inputs on hide/close and reject wrong-server reuse | [macOS invites](macos.md#m6-y23-invite-activation-not-run), [Linux invites](linux.md#invite-activation-m6-y24-not-run) | — |
| NOT RUN | Real Keychain signed-build update/lock/deny/consent and real Linux GNOME Keyring/KWallet/fallback tier visibility and cleanup; no credential disclosure | [macOS store checks](macos.md#m4-a3-keychain-secrets-not-run), [Linux store checks](linux.md#secret-storage-m4-a4-not-run) | — |
| NOT RUN | VoiceOver/Orca, keyboard focus, native drag/diff/viewer file modes and consent remain usable on installed desktops | [macOS accessibility](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run), [Linux accessibility](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run), [GNOME](gnome.md), [KDE](kde.md) | — |

M6 remains open until its scenario/native requirements and deployed owner
acceptance are demonstrated on main. Phone/desktop connected acceptance belongs
to M10; this guide records no Android connected UI or scheduler result.

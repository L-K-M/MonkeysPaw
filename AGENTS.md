# Working on Monkey's Paw

Monkey's Paw is a prompt repository for macOS, Linux, and Android, with an
optional self-hosted sync server. [PLAN.md](PLAN.md) is the specification and
design record; read its index, then the sections relevant to your task.

## Layout (§4.4)

- `Package.swift`, `Sources/MonkeysPawCore/`, and
  `Tests/MonkeysPawCoreTests/`: the shared Swift module, Foundation + Yams
  only. Core contains Domain, Ports, Services, Presentation, Assistant,
  Sync, and SyncAPI; Platform holds portable logging and identity.
- `Sources/CGtk/`, `Sources/MonkeysPawLinux/`, and `Sources/monkeyspaw/`:
  the Linux shim, drivers, app, and entry point, added in M0b.
- `MonkeysPaw.xcodeproj`, `MonkeysPaw/`, and `MonkeysPawTests/`: the native
  macOS app and drivers, added in M0c. Xcode links the local package
  product `MonkeysPawCore`.
- `server/`: a separate SwiftPM package depending on Core. Its library
  lives in `Sources/MonkeysPawServer/`, CLI in
  `Sources/monkeyspaw-server/`, and tests in `Tests/MonkeysPawServerTests/`.
  Server layers are Routes → Services → Repositories; database migrations
  and admin commands arrive in M5.
- `android/`: the future Kotlin core port and native app. `spec/fixtures/`
  and `spec/schema/` will keep the Swift and Kotlin implementations aligned.
- `docs/plan/`: the specification. `docs/platform/`: owner-run checklists.
  Packaging, deployment, seeds, and release scripts follow their milestones.

M0a supplies Core foundations, the server health route and CI. M0b adds the
Linux GTK skeleton. The macOS app starts in M0c; delivery plumbing starts in M1.

## Build and test

Linux uses Swift 6.4; macOS uses Xcode 26.x. Core's tools-version 5.9 keeps
Swift 5 language mode; the server's tools-version 6.0 selects Swift 6 mode
(D15). Commit both `Package.resolved` files.

Run these commands from the repository root:

| Task | Command |
|---|---|
| Build Core without GTK | `swift build --target MonkeysPawCore` |
| Build Linux app | `swift build --product monkeyspaw` |
| Test Core and Linux app | `swift test` |
| Test Linux app with a required display | `dbus-run-session -- xvfb-run -a env MONKEYSPAW_REQUIRE_DISPLAY=1 GSETTINGS_BACKEND=memory GTK_A11Y=none GSK_RENDERER=cairo swift test --filter MonkeysPawLinuxTests` (matches CI) |
| Validate Linux desktop entry | `desktop-file-validate packaging/linux/ch.lkmc.monkeyspaw.desktop` |
| Build server | `swift build --package-path server` |
| Test server | `swift test --package-path server` |
| Run server | `swift run --package-path server monkeyspaw-server serve` |
| Check server health | `swift run --package-path server monkeyspaw-server healthcheck` |
| Build server image | `docker build -f server/Dockerfile .` |

On the Paseo implementation host, use `/home/paseo/.local/bin/swift64`
instead of `swift` for every build/test command. This wrapper supplies
Swift 6.4 and the host's userland sysroot. Docker is unavailable there; the
image job in CI builds and exercises the container.

The lifecycle test skips without a display unless `MONKEYSPAW_REQUIRE_DISPLAY=1`,
which makes a missing display fail. The Core portability job compiles Core and
its tests without GTK; the Linux app job runs both suites. `swift test --filter`
still builds all test targets, so filtering alone cannot isolate Core from GTK.

## Linux GLib main-loop rules

- `DispatchQueue.main` and `@MainActor` never run under a GLib main loop.
  A GTK app gives its main thread to GLib, which does not drain libdispatch's
  main queue. A main-actor hop hangs silently and the window never updates.
  Core hands UI work to the injected `MainThread` port; `GLibMainThread`
  uses `GTK.onMainLoop` and `g_idle_add`.
- Schedule delayed UI work with `GTK.after` (`g_timeout_add_full`), never
  `DispatchQueue.main.asyncAfter`. The destroy notify releases the boxed
  closure even when a timer is removed before it fires.
- Use synchronous top-level `main.swift`, never async `@main`, so Swift
  does not drain a competing main queue. Panel operations stay on this thread.
- Keep `hide_on_close`: GTK owns the window and the panel keeps a borrowed
  pointer. Native close must hide it so the next toggle can reuse it.
- One identity string, `ch.lkmc.monkeyspaw`, is the D-Bus name, `.desktop`
  basename and `StartupWMClass`. All match `AppIdentity.linuxAppID`.
  Desktop action identifiers must match `ActionName` and the registered
  `GSimpleAction` names exactly; a mismatch silently does nothing.
- Keep `--gapplication-service` in the D-Bus service's Exec. Service mode
  avoids an automatic activation before a cold toggle action, and
  `g_application_hold` keeps the process resident with its window hidden.

## Architecture and engineering rules (§4.2)

- Each layer calls only the layer directly below it: Views → Presentation
  models → Services → Domain and Ports. Services see drivers only through
  port protocols. Views render state and forward intents; they never touch
  services, files, clipboard, keys, or HTTP. Presentation models never
  access drivers.
- Core imports Foundation and Yams only. Never import AppKit, SwiftUI,
  Combine, `os`, Security, or CGtk. Never use `URLSession.bytes(for:)`,
  which is absent on Linux. The Linux Core CI job is the portability gate.
- Core never uses `@MainActor` or `DispatchQueue.main`: they do not run
  under GLib's main loop. Inject the `MainThread` port; the Linux driver
  marshals callbacks with `g_idle_add`. The Linux entry point is top-level
  `main.swift` calling `exit(MonkeysPawLinuxApp.main())`, never async `@main`.
- Only `AppDelegate` (macOS) and `LinuxEnvironment` (Linux) construct
  drivers and inject them into services. Views receive presentation models.
- Server routes decode Core DTOs, call one server service, and map typed
  errors to HTTP statuses. Services enforce permissions inside the write
  transaction; repositories own database access (§4.3).
- Mark exactly the API consumed by apps and the server `public`; keep
  other types internal and members private by default. Server tasks use
  Core value types, never share Core class services. `@preconcurrency`
  imports are a temporary escape hatch, never the design (D15).
- Use enums for behavioral modes rather than boolean parameters. File
  format boolean properties remain booleans. Put timings, limits, and
  sizes in Core's `Domain/Limits.swift` or the server's `ServerLimits.swift`.
- Prefer early returns and small comments explaining what and why; leave
  blank lines between logical blocks.
- Subprocesses use argument arrays and resolved absolute executable paths,
  never shell strings. Discard stderr to `/dev/null` or drain it, since an
  undrained pipe blocks at 64 KB. Read stdout before `waitUntilExit`.
  Stdin writes use `try?` for EPIPE. A nonzero exit returns nil; never log
  tool error text.
- Panel/window operations run on the UI thread. Paste injection runs off
  it and is never awaited inline by a view. Hotkeys fire on key release
  with a toggle debounce.
- Preserve §6's delivery order: write the clipboard while the panel still
  has focus, hide for delivery, settle, restore/verify focus, then paste.
  Dismissal restores focus only while our app is frontmost. A tool exiting
  zero does not prove paste worked; cache failed backends for the session.
- Never log keys, tokens, passwords, prompt content, field values, or
  provider/tool error bodies (§12).

## Implementation workflow (§15)

Each milestone lands in small PRs implemented by Codex (`gpt-6.1-sol`,
reasoning effort `max`) from the plan. Devin (`swe-2-max`) reviews each PR
adversarially; the GLM workflow reviews once available. The supervising
agent builds, runs tests, reads the diff against the plan, and rejects
scope creep before merging. A milestone closes only when its acceptance
criteria are demonstrated on main. Owner-run checks requiring hardware
or paid keys are recorded under `docs/platform/`.

Follow explicit task Git instructions over the shared defaults below. For
the M0a implementation, work on the current branch, make logical commits,
and leave pushing and opening the PR to the supervisor.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->

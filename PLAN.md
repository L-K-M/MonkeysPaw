# Monkey's Paw: plan

A prompt repository for macOS, Linux, and Android.

- **Desktop.** Press a global hotkey, pick a prompt, and fill its
  placeholders. The result is pasted into the text field you were typing in.
- **Android.** A picker keyboard and a Quick Settings tile do the same job.
- **LLM assistant.** An LLM can write new prompts, review them, and improve
  them.
- **Sync.** An optional self-hosted server syncs prompts between devices and
  shares them within groups.

Status: plan only; no code yet. This plan is the design record and the
build order. Each milestone is implemented by an AI coding agent, reviewed
by a second agent, and validated before merge (§15).

## How to read this plan

The plan is split into one file per section under [`docs/plan/`](docs/plan/),
so that each file stays reviewable on its own. Section numbers (`§5.3`) are
stable: the file for `§N` starts with `N-`.

| § | Section |
|---|---|
| §1 | [Goals](docs/plan/01-goals.md) |
| §2 | [The core loop](docs/plan/02-the-core-loop.md) |
| §3 | [Decisions](docs/plan/03-decisions.md) |
| §4 | [Architecture](docs/plan/04-architecture.md) |
| §5 | [Prompt library](docs/plan/05-prompt-library.md) |
| §6 | [Delivery: hotkey, panel, focus, paste](docs/plan/06-delivery-hotkey-panel-focus-paste.md) |
| §7 | [LLM assistant](docs/plan/07-llm-assistant.md) |
| §8 | [Sync server](docs/plan/08-sync-server.md) |
| §9 | [Sync client](docs/plan/09-sync-client.md) |
| §10 | [Android client](docs/plan/10-android-client.md) |
| §11 | [User interface](docs/plan/11-user-interface.md) |
| §12 | [Security and privacy](docs/plan/12-security-and-privacy.md) |
| §13 | [Testing](docs/plan/13-testing.md) |
| §14 | [Repository, packaging, CI, release](docs/plan/14-repository-packaging-ci-release.md) |
| §15 | [Milestones](docs/plan/15-milestones.md) |
| §16 | [Risks](docs/plan/16-risks.md) |
| §17 | [Open questions](docs/plan/17-open-questions.md) |
| §18 | [Sources](docs/plan/18-sources.md) |

## Editing rules

- **One topic per file.** Keep the files small: reviewers and agents read
  them one at a time.
- **Change the plan before the code.** A behaviour change lands with its
  plan change in the same PR, or the plan says why it was deferred.
- **Keep section numbers stable.** Cross-references use `§N.M`. Renumbering
  means updating every reference in the same PR.

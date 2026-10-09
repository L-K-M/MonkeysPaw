# Monkey's Paw

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Latest release:** v<!-- version -->0.0.0<!-- /version --> · [Download](https://github.com/L-K-M/MonkeysPaw/releases/latest)

Monkey's Paw is a prompt repository planned for macOS, Linux, and Android.
The desktop apps will let you pick a prompt, fill its placeholders, and paste
the result into the text field you were using. Prompts live in Markdown files
with YAML front matter, so you can edit them with your own tools. An optional
LLM assistant will help write and improve prompts, and a self-hosted server
will sync them between devices and share them within groups.

The portable Core format APIs preserve unknown front-matter metadata and
exact body bytes. Canonical writing does not preserve comments inside front
matter. Format and grammar conformance cases live under
[`spec/fixtures/`](spec/fixtures/), documented in [`spec/README.md`](spec/README.md).

**Status:** Under construction per [PLAN.md](PLAN.md). M0a provides the shared
Core package, the server health endpoint, and build and test infrastructure.

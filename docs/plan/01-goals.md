## 1. Goals

| Goals | Non-goals (v1) |
|---|---|
| Prompts are plain Markdown files in a folder you own, editable in any editor. | Windows, iOS, a web client. |
| Typed placeholders filled in a keyboard-first form. | Typed-trigger auto-expansion that watches every keystroke. |
| Hotkey → pick → fill → paste on macOS, GNOME, KDE, and X11. Copy-only fallback everywhere. | Running prompts against a model and showing the answer (a chat client). |
| LLM write, review, improve. Nothing is applied without a diff and an explicit accept. | Conditionals, loops, or scripts in templates. |
| Optional sync server: personal prompts sync across your devices; group prompts are shared with group members by role. | End-to-end encryption; real-time co-editing; a web admin UI. |
| One Swift core shared by the macOS app, the Linux app, and the server. | A third desktop UI toolkit or a cross-platform UI framework. |
| An Android client with the same format, sync, and assistant: a picker keyboard, plus a tile → fill → copy flow that works in every app. | Accessibility-service auto-paste; the Play Store or F-Droid. |
| L-K-M family conventions for repo, CI, releases, and deployment. | Streaming LLM output. |

Success criteria for v1:

- The owner uses it daily on a Mac, a Linux desktop, and an Android phone.
- A prompt with two fields lands in a browser chat box or a terminal in four
  keystrokes plus typing.
- A prompt edited on one device appears on the other device and for group
  members within one sync interval.

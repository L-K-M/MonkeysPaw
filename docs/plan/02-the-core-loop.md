## 2. The core loop

```
 user types in a chat box ──► hotkey ──► panel: search + list ──► Return
                                                                    │
            ┌──────────────── prompt has fields? ◄──────────────────┘
            │ no                           │ yes
            ▼                              ▼
      render text                fill form: one control per field,
            │                    defaults and last values prefilled,
            │                    live preview ──► Return
            ▼                              │
  DeliveryService: write clipboard (panel still focused)
                 → hide panel → settle → re-focus target (macOS)
                 → inject the paste chord via the session's backend ladder
                 → on failure: text stays on the clipboard + notification
```

1. **Hotkey.** On macOS the app remembers the frontmost app before showing
   the panel. On Linux the compositor gives focus back when the window hides.
2. **Pick.** The search field has focus. Typing filters by fuzzy match on
   title, tags, folder, and body. An empty query lists recent and favourite
   prompts. `↑↓` move, `Return` picks, `Esc` closes and nothing is pasted.
3. **Fill.** Skipped when the prompt has no fields. Otherwise the form shows
   one control per field in order of first appearance, prefilled with the
   default or the value used last time, plus a live preview. `Return` (or
   `Cmd/Ctrl+Return` inside a multi-line field) delivers.
4. **Deliver.** See §6. The result also stays on the clipboard, so a failed
   injection costs one manual paste.
5. **Learn.** Usage and filled values are stored locally. They drive ranking
   and prefill.

Keystroke budget, enforced by presentation-model tests (§13):

| Scenario | Keys |
|---|---|
| Prompt without fields, top of the list | hotkey, `Return` = **2** |
| Prompt with fields, reuse last values | hotkey, `Return`, `Return` = **3** |
| Prompt with fields, change one | hotkey, `Return`, typing, `Return` = **3** + typing |
| Find a rarely used prompt | hotkey, 2-4 letters, `Return`, fill, `Return` |
| Cancel from the picker | `Esc` |
| Leave the fill form | `Esc` returns to the picker with values kept; a second `Esc` closes. Nothing is pasted. |

## 25. Android Expressive design

### 25.1 Direction

One coherent Material 3 product, including its picker keyboard. Use Android
navigation, controls and interaction feedback, with deliberate composition,
typography and alignment. The current navigation/session models remain the
owners of their flows; this is a presentation redesign.

The baseline has no app theme, dark palette or icons. Headers, navigation and
file actions compete in scrolling rows of text buttons. Prompt cards repeat
paths, tags, validation and favourite checkboxes. The IME embeds that entire
browser inside half the display, leaving little space for prompts.

### 25.2 Shared system

- **Color.** Restrained ink/indigo and warm accents inspired by the app icon.
  Android 12+ dynamic colors follow the device. Both fallback palettes support
  light/dark mode and semantic error, warning and success treatment.
- **Type.** System sans-serif; emphasized titles, readable body text and quiet
  metadata. Monospace belongs to source and diff text. Do not disable font scaling.
- **Space.** Shared 4/8/12/16/24/32 dp scale, 48 dp touch targets, comfortable
  list rows and bounded reading widths on large screens. Heights grow with text.
- **Surfaces.** Flat prompt lists and a few tonal groups, not a card per label.
  Rounded connected groups clarify settings and controls; color indicates purpose.
- **Motion.** Native ripple and state feedback; short Compose transitions only
  where they clarify changes. Honor system animation scaling. No decorative motion.
- **Components.** Shared screen/app-bar shell, section headings, setting rows,
  message banners, loading and empty states. Use existing Material 3 APIs and
  the catalog-pinned icon set. No new navigation or data framework is needed.

### 25.3 App surfaces

- **Library.** A clear title, prominent search, concise primary filters and
  an organized browse surface for folders/groups/tags. Rows prioritize title
  and description. Favourite and contextual edit/resolve actions replace dead
  checkbox rows. New prompt is the primary creation action; assistant and
  settings/account entry points remain discoverable.
- **Editor.** Stable back/save chrome, a focused source canvas, proper
   Edit/Preview/Fields/History tabs and contextual file commands. Preserve
   validation, quotes, read-only access, history and all discard/conflict guards.
   Fields opens staged placeholder settings (§11.7); Apply edits the same draft.
- **Fill.** Readable fields and choices, a contained preview, and docked
  Copy/Insert/Done actions. Keep capture assignment and existing completion rules.
- **Settings/account.** Preference-style groups with clear connection, provider,
  keyboard and sync sections. Destructive actions are distinguishable. Secret
  entry keeps its native non-saving field and existing privacy boundaries.
- **Assistant/conflicts.** Consistent app bars, progressive disclosure of drafts
  and diffs, one primary action per state, readable findings and explicit recovery.
- **Setup/seeds/share.** Focused steps and clearly distinguished progress,
  completion, retry and skip paths, using the same components as the rest of the app.

### 25.4 Picker keyboard

The IME remains a picker, not a typing keyboard. Its compact toolbar provides
Search in app and Switch keyboard; it does not show a software-search text
field, app navigation, disabled favourites or full-file metadata. Compact
prompt rows and filters leave room for actual results.

Inline Fill uses the same visual language, with keyboard-sized controls,
bounded preview and reachable Insert/Copy actions. Free-text editing/search
still uses the explicit activity handoff, also reachable from the stable toolbar.
Choice and browse menus use non-focusable popups so the external editor remains
the input target. The IME must not compose exposed menu boxes that require an
activity Back dispatcher, even when their menus are closed. Activity forms keep
the native exposed controls. Password and own-Fill targets show
only the existing protected/switching states. No target-text reads, credentials,
transport, scheduling or new IME effects are introduced.

Keyboard height is bounded and orientation-aware rather than an unbounded
half-display. Content scrolls at large font sizes; navigation-bar insets remain
clear and landscape leaves the target app visible. Fullscreen extraction stays off.

### 25.5 Insets, behavior and verification

Activities own system safe-area padding once; nested app bars do not add it
again. Editable activity screens accommodate the normal IME. Our picker never
adds `imePadding` to itself. Preserve system Back, modal dismissal and current
ViewModel/session state ownership, including held Fill and one-use handoffs.

Verify the complete Android JVM/lint/debug/release gate. Inspect actual app and
IME renders on an isolated emulator: light/dark, ordinary and large fonts,
portrait/landscape and wider displays. Exercise browse, edit/save/discard,
Fill/Copy, setup, account/assistant states and keyboard insertion/switching.
Record untested physical keyboard, TalkBack, OEM and platform cases honestly.
The focused local render/flow evidence is recorded in
[the Android checklist](../platform/android.md#android-expressive-presentation-checks).

References: [Android UI design](https://developer.android.com/design/ui),
[Material 3 Expressive](https://m3.material.io/blog/building-with-m3-expressive),
[Expressive overview](https://blog.google/products-and-platforms/platforms/android/material-3-expressive-android-wearos-launch/)
and [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/).
The Android presentation follows the Expressive design direction through
public APIs available in the current Material 3 dependency.

### 25.6 Refinement pass

The first rendered pass still gives metadata and utility controls too much
weight. Refine composition without changing session or storage contracts:

- Emphasize overview titles, soften search/filter chrome, and align content
  to a shared page gutter. Give prompt descriptions the full reading width;
  keep favourite and file commands in a compact title row and metadata quiet.
- Use a neutral canvas with restrained tonal groups. Preference icons use
  small tonal wells; section labels remain subordinate to row titles.
- Search and filters scroll with the library in one stable layout, preserving
  input focus through software-keyboard resizing and making short windows usable.
- Render keyboard results as compact, inset prompt keys on a tonal keybed.
  Keep Search and Switch distinct, filters scrollable, and 48 dp targets.
- Use proportional text for rendered prompt previews; monospace remains for
  editable source and forensic revisions. Dock and emphasize delivery actions.
- Keep the sync footer concise when there is nothing to resolve. Counts and
  diagnostics remain available in sync details; nonzero problems stay visible.
- Dock assistant actions and show a unified diff on narrow or large-text
  screens. Confirm saved-provider deletion before removing its API key; an
  unsaved profile still discards directly. Account choices select by whole row.
- Keep a concise encryption/outbound-data summary before provider inputs;
  the full existing disclosure opens in a scrollable Data and privacy dialog.

Acceptance is rendered light/dark phone, large-text, landscape and wide-screen
inspection, plus browse/edit/fill and IME insertion, menu and switch-back checks.
The existing JVM, lint, APK and privacy/session gates remain required.

### 25.7 Flow composition

- Inline Fill has one keyboard header naming the selected prompt, with Back,
  activity handoff and Switch. Text-value rows open the existing guarded
  activity handoff; choices remain local non-focusable menus. Remove duplicate
  title/close/handoff chrome from the scrolling form. Insert/Copy stay docked.
- Keep the common All/Favourites/Recent filters concise and Browse reachable
  beside the scrolling filter rail. Browse retains conflicts, folders, groups
  and tags; no filter is removed. Keyboard loading/empty states use compact
  type and spacing so the state and recovery action fit the available panel.
  A new Browse selection resets the chip rail to expose its selected label.
- Empty/filtered recovery views place creation inline instead of floating it
  over recovery controls at large text sizes. Creating in the current folder
  or group keeps the existing destination intent.
- Keep editor tabs below the app bar while source and history scroll. Show
  localized revision/provenance dates and expose selected history semantics.
  Preserve source, restore, validation, unsaved/conflict and read-only guards.

Verify actual inline choices, text handoff, insertion/switching, protected
targets, empty filters and editor navigation at ordinary/large font sizes,
portrait/landscape and a wider viewport. Keep platform gaps explicit.

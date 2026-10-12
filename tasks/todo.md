# Milestone 6 — Polish

Spec: `docs/SPEC.md` §3, §11, §12, §14, §17 item 6. Earlier milestones are in git history.

- [x] `Preferences`: one observable store for every setting, backed by UserDefaults (§12 defaults from §2)
- [x] General: shortcut recorder (re-registers the Carbon hotkey), default calendar, default task list, default event duration, start week on, day starts (new timed slots), play UI sound, go to today after adding, show alerts, updates
- [x] Appearance: menu bar icon (icon only / date / next event title / next event + countdown), color icon, text size (small / normal / large), theme (system / light / dark)
- [x] Events & Tasks: list shows (7 / 14 / 30 / all days), show when events end, show declined events (list only; the grid never dots them), combine identical events, dim past items, show tasks in list, show completed tasks, sort tasks by
- [x] Calendars: calendar checklist by account (Google `selected`), task-list checklist by account (local)
- [x] Shortcuts (§11) not yet handled: ⌘N, ⌘E / ⌘I, ↑ / ↓ selection, Enter opens the selection, ⌘↓ from search to the first result
- [x] Accessibility: labels on every icon-only control, task rows, VoiceOver on the grid (selected state, tasks due)
- [x] Offscreen snapshot mode (`-renderSnapshots <dir>`) to check light/dark and text sizes without taking focus
- [x] Tests for settings-driven logic in Core; build, tests, snapshots

## Review
- `Preferences` holds every §12 setting; changes reload the agenda, redraw the menu bar item, reschedule alerts and re-register the hotkey.
- Fonts go through `Font.ui`, scaled by Text size; the Mini Window grows with it.
- Snapshots (`.build/shots/m6`): popover light/dark × small/normal/large, all five Settings tabs, menu bar glyphs. Rendered in an off-screen non-activating panel.
- Declined events: no grid dot ever (user request); in the list only with Show declined events, drawn ⊘.
- No new Core logic, so no new unit tests; 91 pass.

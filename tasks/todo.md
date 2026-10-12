# Milestone 4 — Natural-language entry and suggestions

Spec: `docs/SPEC.md` §5 (events; the task form is milestone 5), §8.3, §18.4. Earlier milestones are in git history.

## Core (KalendarCore)
- [x] `NLParser`: tokenizer + rules for §5.3 — dates, date ranges, times, time ranges, durations, all day, recurrence (every …, weekdays, other / N, until, for N times), alerts, `/calendar`, `with`, `at`, quoted literals, task prefix; title from what's left; a token map for the UI
- [x] Suggestion trigger for the token being typed: `/…` calendars, `with …` contacts, `at …` places
- [x] Parse → `EventDraft`; live re-parse keeps fields the user edited by hand
- [x] Contacts: People API connections, other contacts, Workspace directory → cache; plus attendees from cached events
- [x] `EventWriter.insert`: optimistic placeholder replaced by Google's copy
- [x] Tests: §5.2 table + a corpus of example sentences in `Tests/KalendarCoreTests/Fixtures`

## UI
- [x] New-event form under the input, live on every keystroke (collapsed / expanded, same fields as the detail popover), Add Event
- [x] Suggestion list under the input: ↑/↓, Enter/Tab accept, Esc dismiss; calendars, contacts (initials, name, email), places (MKLocalSearchCompleter + recent locations)
- [x] × cancels; discard dialog when the form was edited by hand (§8.3)
- [x] Commit: insert, UI sound, clear, back to today after ~2 s; inline error
- [x] Double-click a day: new entry pre-dated to that day
- [ ] Verify by hand: Enter / Tab / ↑↓ in suggestions, Add Event, discard dialog, double-click a day; one real create + edit + delete + undo on the "test" calendar (the milestone 3 check)

## Review

- `swift build -Xswiftc -warnings-as-errors` and `swift test` (72 tests) pass. New tests: the 28-sentence corpus (§5.2 table plus Kalendar's own examples), live title while typing, suggestion triggers, contact matching, `/calendar` and task prefixes, double-click default day, clock readings; People API parsing, contact ranking with event attendees, unique-name matching; insert with a placeholder replaced by Google's copy; the live form keeping hand edits.
- In the running app: contacts synced (1,263 + 379); typing "Coffee tomorrow 3pm at Ritu" showed the form with Apple Maps place suggestions.
- Not verified by hand: keyboard handling in the suggestion list, Add Event, the discard dialog, double-click, and a real create/edit/delete/undo. The automated driver can only reach Kalendar's popover while Kalendar is the active app, and Zoom was frontmost; relaunching to activate Kalendar would keep taking focus from it.

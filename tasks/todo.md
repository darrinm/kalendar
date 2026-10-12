# Milestone 4 — Natural-language entry and suggestions

Spec: `docs/SPEC.md` §5 (events; the task form is milestone 5), §8.3, §18.4. Earlier milestones are in git history.

## Core (KalendarCore)
- [ ] `NLParser`: tokenizer + rules for §5.3 — dates, date ranges, times, time ranges, durations, all day, recurrence (every …, weekdays, other / N, until, for N times), alerts, `/calendar`, `with`, `at`, quoted literals, task prefix; title from what's left; a token map for the UI
- [ ] Suggestion trigger for the token being typed: `/…` calendars, `with …` contacts, `at …` places
- [ ] Parse → `EventDraft`; live re-parse keeps fields the user edited by hand
- [ ] Contacts: People API connections, other contacts, Workspace directory → cache; plus attendees from cached events
- [ ] `EventWriter.insert`: optimistic placeholder replaced by Google's copy
- [ ] Tests: §5.2 table + a corpus of example sentences in `Tests/KalendarCoreTests/Fixtures`

## UI
- [ ] New-event form under the input, live on every keystroke (collapsed / expanded, same fields as the detail popover), Add Event
- [ ] Suggestion list under the input: ↑/↓, Enter/Tab accept, Esc dismiss; calendars, contacts (initials, name, email), places (MKLocalSearchCompleter + recent locations)
- [ ] × cancels; discard dialog when the form was edited by hand (§8.3)
- [ ] Commit: insert, UI sound, clear, back to today after ~2 s; inline error
- [ ] Double-click a day: new entry pre-dated to that day
- [ ] Verify: build, tests, screenshots; one real create + edit + delete + undo on the "test" calendar (the milestone 3 check)

## Review

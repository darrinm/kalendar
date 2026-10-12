# Milestone 3 — Editable detail popover

Spec: `docs/SPEC.md` §6, §6.1, §6.2, §7.1, §8.1, §8.2, §18.2, §18.3 (writes). Earlier milestones are in git history.

## Core (KalendarCore)
- [x] Cache v2: `etag`, `visibility`, reminders (`useDefault`, overrides), `timeZone` on events; calendar `defaultReminders`; sync requests ask for them
- [x] Event API: get, patch (`If-Match`, `sendUpdates`), delete, insert, move
- [x] `EventDraft`: the editable fields of an event; diff against the original → patch body; "All" on a recurring event targets the master and shifts times by the instance's offset
- [x] Recurrence: RRULE ⇄ presets (None, Every Day/Week/Month/Year) and Custom (frequency, interval, weekdays, end never / on date / after N), human summary
- [x] Write queue: persistent, ordered, optimistic cache update; 412 → refetch and report; network failure → retry on next sync; other errors → refetch and report
- [x] Undo delete: patch back to `confirmed` (organizer), else re-insert a copy
- [x] Pending invitations query (§6.2)
- [x] Tests for each of the above

## UI
- [x] Detail popover: inline editing of title, location, all-day, starts/ends, calendar, color, repeat (+ Custom sheet), repeat end, alerts (⊕, max 5), show as, visibility; expanded: time zone, invitees (add by email), notes
- [x] Invitation variant: attendee list, Maybe / Decline / Accept; organizer-only fields read-only
- [x] Save on close; recurring edits ask Only This Event / All / Cancel (Cancel keeps the popover open)
- [x] Delete (⌫ / ⌘⌫ / context menu), recurring dialog, ⌘Z undo
- [x] Context menu: previous/next occurrence, Join, Color ›, Show As ›, Visibility ›, Copy, Duplicate, Delete
- [x] Notifications badge + popover: rows with RSVP buttons, ⋯ Accept/Decline/Maybe All, row click opens the detail
- [x] Inline error text for failed writes
- [ ] Verify: one real edit + undo on a test event (needs event creation, milestone 4)

## Review

- `swift build -Xswiftc -warnings-as-errors` and `swift test` (57 tests) pass. New tests: RRULE parsing, writing, presets (including Google's `FREQ=WEEKLY;BYDAY=MO`) and summaries; patch bodies (changed fields only, all-day switching, series time shift, RSVP); EventWriter against a fake Google (optimistic save then Google's copy, 412 conflict, offline queueing, delete + undo, undo falling back to an insert, invitations not undoable, RSVP, series delete, calendar move, rejected write).
- The v2 migration ran on the real cache; the forced resync filled etags for all 3,703 events.
- Checked in the running app: the editor shows every §6 field with the series rule loaded ("Every Week"); Esc closes it without queuing a write; the invitation badge and Notifications popover (fed a local-only fake row, since no invitations are pending) open below the badge over the grid; the right-click menu has every §7.1 item; the Calendars menu turned the "test" calendar off and on, and a refresh confirmed Google holds the final value.
- Not checked against Google: event edits, RSVP, delete and undo. They are covered by the fake-Google tests; a real edit + undo waits for event creation in milestone 4, so the test runs on an event Kalendar made.
- macOS adds "Ask Siri" to every context menu; the spec omits it, and AppKit doesn't offer a way to remove it.

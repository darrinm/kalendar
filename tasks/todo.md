# Milestone 3 — Editable detail popover

Spec: `docs/SPEC.md` §6, §6.1, §6.2, §7.1, §8.1, §8.2, §18.2, §18.3 (writes). Earlier milestones are in git history.

## Core (KalendarCore)
- [ ] Cache v2: `etag`, `visibility`, reminders (`useDefault`, overrides), `timeZone` on events; calendar `defaultReminders`; sync requests ask for them
- [ ] Event API: get, patch (`If-Match`, `sendUpdates`), delete, insert, move
- [ ] `EventDraft`: the editable fields of an event; diff against the original → patch body; "All" on a recurring event targets the master and shifts times by the instance's offset
- [ ] Recurrence: RRULE ⇄ presets (None, Every Day/Week/Month/Year) and Custom (frequency, interval, weekdays, end never / on date / after N), human summary
- [ ] Write queue: persistent, ordered, optimistic cache update; 412 → refetch and report; network failure → retry on next sync; other errors → refetch and report
- [ ] Undo delete: patch back to `confirmed` (organizer), else re-insert a copy
- [ ] Pending invitations query (§6.2)
- [ ] Tests for each of the above

## UI
- [ ] Detail popover: inline editing of title, location, all-day, starts/ends, calendar, color, repeat (+ Custom sheet), repeat end, alerts (⊕, max 5), show as, visibility; expanded: time zone, invitees (add by email), notes
- [ ] Invitation variant: attendee list, Maybe / Decline / Accept; organizer-only fields read-only
- [ ] Save on close; recurring edits ask Only This Event / All / Cancel (Cancel keeps the popover open)
- [ ] Delete (⌫ / ⌘⌫ / context menu), recurring dialog, ⌘Z undo
- [ ] Context menu: previous/next occurrence, Join, Color ›, Show As ›, Visibility ›, Copy, Duplicate, Delete
- [ ] Notifications badge + popover: rows with RSVP buttons, ⋯ Accept/Decline/Maybe All, row click opens the detail
- [ ] Inline error text for failed writes
- [ ] Verify: build, tests, bundle, screenshots, one real edit + undo on a test event

## Review

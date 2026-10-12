# Milestone 2 — Sync + read-only agenda

Spec: `docs/SPEC.md` §4.2, §4.3, §4.4 (toolbar menus), §9, §11, §18.2, §18.3. Milestone 1 notes are in git history.

## Sync (KalendarCore)
- [x] GRDB cache in `~/Library/Application Support/Kalendar/cache.sqlite`: calendars, event instances, colors, per-calendar sync state
- [x] Calendar API: paged `calendarList`, `colors`, windowed `events.list` (`singleEvents=true`), change stream (`singleEvents=false` + `syncToken`, ids-only full pass), `events.instances`, `calendarList.patch selected`
- [x] Event JSON → `EventInstance` (timed / all-day, attendees, self response, conference URL, colors)
- [x] `SyncEngine`: first sync = window fetch (today −1 y … +1 y) + ids-only pass for the sync token; incremental = change stream → upsert singles, refetch instances for changed series; 410 → full resync; window older than 30 days → full resync
- [x] Sync triggers: popover open, every 60 s while open, every 5 min otherwise, wake, network return, ⇧⌘R; sign-out deletes that account's cache
- [x] Tests: event parsing fixtures, cache queries, sync engine against a scripted transport (first sync, incremental single, incremental series, 410)

## Agenda UI
- [x] Month grid: 6 rows, weekday header (current weekday in accent), today circle, selected-day ring, dots (≤4, calendar/event color, declined dot), adjacent-month days muted, ‹ › navigation
- [x] Agenda list: day sections from today (TODAY/TOMORROW/weekday headers), all-day pills, timed rows (dot, time range, 📹, title, location), past dimmed, Join pill (in progress or ≤15 min), combine identical, declined hidden, "No events" rows; click day scrolls; extends on scroll
- [x] Keyboard: ←/→ month, ⇧←/⇧→ day, ⇧↑/⇧↓ week, ⌘T today (when the input is empty)
- [x] Search: 🔍 / ⌘F, scope menu (Title · Location · Invitees · All), results over the cache, Esc exits
- [x] Toolbar: calendar visibility menu (writes Google `selected`), ⚙ menu (Go to Today, Go to Date…, Refresh All, Settings…, Check for Updates…, Launch at Login, Quit)
- [x] Reset to today on reopen
- [x] Verify: build, tests, bundle, screenshots with real data

## Review

- `swift build -Xswiftc -warnings-as-errors` and `swift test` (35 tests) pass. New tests cover Google event parsing, conference-link detection, path escaping, cache search scopes, and the sync engine against a fake Google: first sync, incremental single and series changes, 410 resync, a calendar removed from Google, a failed sync keeping the cache, calendar visibility writes and their revert, and account deletion.
- Synced against both real accounts: 12 calendars, 3,703 events in the ±1 year window.
- Checked in the running app with screenshots: today's agenda matches the reference app (Columbus Day pill, David / Darrin, Weekly Kick Off, Josh / Darrin, video glyphs); ⌘F search for "kick"; Esc out of search; → to next month; ⇧↓ to next week; ⌘T back to today; clicking an event opens the detail popover to the left while the main popover stays open (the milestone 1 nested-popover check).
- Not checked by hand: the Calendars visibility menu and Go to Date… (both need menu clicks), the list growing on scroll, sync on wake and on network return.
- The detail popover is read-only; milestone 3 makes it editable.

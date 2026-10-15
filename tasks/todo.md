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

## Review: interactive UI test (2026-10-12)

Run against dev builds with cua-driver (AX actions and per-process key events), a few real HID clicks, and real Google writes on the "test" calendar and throwaway "Kalendar test …" tasks. Branch `ui-test-fixes` fixes the bugs below.

### Fixed on `ui-test-fixes`
- **Location suggestions after retyping:** typing `at Tar`, clearing, and typing `at Tar` again showed no suggestions. `PlaceSearch` cancelled the completer but left its `queryFragment` at "Tar", and MKLocalSearchCompleter ignores an unchanged fragment. Clearing now resets the fragment.
- **Esc in a form field:** with focus in the location field, Esc closed the popover and skipped the discard dialog. Only the input field had `.onExitCommand`. The popover's key monitor now sends Esc and ⌘. to `escape()` from any field, except while an input method is composing text.
- **Discard and scope dialogs closed the popover:** when the §8.3 or §8.1 alert took key, the transient popover closed, so Cancel returned to nothing. `popoverShouldClose` now returns false while a modal window is up.
- **End date showed a stale value:** the "ends" DatePicker had `in: d.start...`. When the start moved earlier, NSDatePicker clamped the end to the old start and displayed it (seen as 11/13 7:00 AM while the model held 10/13 8:00 AM); editing the end then would write the clamped value. The picker keeps the range and is rebuilt (`.id(d.start)`) when the start changes. Removing the range instead would let a half-typed end (each segment commits) move the start.
- **Theme had no effect on the popover:** Light turned the Settings window light but the popover stayed dark. An NSPopover takes its appearance from the status item it is shown from. The popover now observes `NSApp.effectiveAppearance` (KVO), which covers a Theme change and, with System, the system switching between light and dark.
- **All-day pills did nothing on click:** they had no tap gesture or context menu, and VoiceOver saw static text. They now open the detail on click and have the event context menu, like timed rows.
- **Unnamed form controls:** the all-day checkbox and the starts, ends, repeat-until, due-date and Go to Date pickers had empty labels, so VoiceOver read them without a name. They now carry their row's name (still visually hidden).

Verified in the running fix build: each case above, plus `swift build -Xswiftc -warnings-as-errors` and 94 tests.

### Passed
- New item: location (↑↓, Tab, Enter accept), contact and `/calendar` suggestions; Esc sequence (hide, clear, close); × with and without hand edits, Cancel and Discard; double-click a day then `Gym 6pm` dates the form that day; `/test … tomorrow 7am` + Enter adds to "test", clears, returns to today after ~2 s; `todo … tomorrow 3pm` shows the task form with "Google Tasks stores dates only"; ▣ | ✓ toggle.
- Keyboard: ↑↓ selection with a multi-day event as one stop; Enter, ⌘E, ⌘I; ⌫ then ⌘Z restores in place; ⌘N; ⌘F, ⌘↓; ⌘T; ← → months; ⇧ arrows by day and week; ⌘R and ⌘3.
- Tasks: circle checkbox complete and uncomplete; task menu Complete, Move to List, Delete.
- Event menu: Color, Show As, Duplicate, Duplicate as Task, Delete.
- Detail: title and time edits reach Google on close; §8.1 on a recurring "test" event: Only This Event changes one instance; All deletes the series.
- Settings: every tab responds; text size applies immediately; menu bar styles including "Kalendar test alert in 4m"; shortcut recorder record, Esc, Reset, then ⌃⌥Space opens the popover; Show declined events adds ⊘ rows and leaves grid dots unchanged.
- Alerts: banner title and "4:51 – 5:21 PM · Room 4, https://zoom.us/j/…"; actions Show Details, Snooze 5 Minutes, Join, Close.
- Sparkle: v0.1.0 → Check for Updates… → Install Update → Install and Relaunch; the app's Info.plist reads 0.1.1 (build 2), notarized.
- VoiceOver: status item "Kalendar, Monday, October 12, 2026" (plus "next: … in 4m" with the countdown style); grid days "Monday, October 5, 2026, 6 events"; task rows "Task, pay office rent, overdue, due Oct 1, 2026"; toolbar Search, Previous month, Next month, View, Calendars, Actions; declined rows start with "Declined".

### Not tested
- **Snooze 5 Minutes and clicking the banner.** Kalendar's banners were presented (usernoted log) but did not appear in Notification Center's AX tree, except once while a persistent Fantastical alert was stacked. No action could be performed on them.
- **Task menu Duplicate as Event.** It always writes to the task account's primary calendar (`AgendaModel.defaultCalendar`, which ignores the Default calendar setting), and events may go only to "test".

### Other findings (not changed)
- Enter with no suggestion list showing adds the item. An early test added an all-day "Coffee" to darrin@massena.com this way; it was deleted within a minute.
- After a delete, the same event stays visible until the next sync when another account also caches that calendar (darrin@playful.software caches darrin@massena.com).
- ⌘T scrolls to today but keeps the old selection, so the next ↓ continues from an off-screen row.
- The app has no icon: `scripts/bundle.sh` copies `Resources/AppIcon.icns` only if present, and the repo has none. Alerts show a blank icon; §8.1 calls for the app icon.
- The event context menu offers Color, Show As and Delete on read-only calendars (Columbus Day on Holidays).
- While another app holds ⌃⌥Space (Fantastical did), recording a shortcut leaves Kalendar's hotkey dead until relaunch, because Kalendar unregisters during recording.
- A release build run with `CFFIXED_USER_HOME` still reads the real `com.massena.kalendar` preferences (cfprefsd ignores it), so it finds the accounts and waits on a keychain prompt. The Sparkle test used `-accounts '()'` instead.

### State after testing
All test events and tasks are deleted; "test" is hidden again; preferences match the pre-test export byte for byte; the global shortcut is ⌃⌥Space.

## Review: bugs and gaps (branch `bugs-and-gaps`)
What happened to each finding above, plus those from the #9 review:
- **Enter with no suggestion list adds the item:** unchanged. Enter adds (§5.4); the Coffee event came from the retype bug fixed in #9.
- **Typed end equal to the start moved the start:** a timed event may now end when it starts (`displayedEnd` moves the start only when the end is earlier). An all-day end, being exclusive, must still be later. Verified: end stepped from 7:00 PM to 6:00 PM, start stayed 6:00 PM.
- **Duplicate as Event ignored the Default calendar:** `AgendaModel.defaultCalendar(account:)` now returns the Default calendar setting when it is writable, then the account's primary. New items and Duplicate as Event share it. Verified with Default calendar = "test": the duplicate landed on "test".
- **No app icon:** `scripts/make-icon.swift` draws `Resources/AppIcon.icns` (accent calendar on navy, macOS grid). Verified in the bundle and on the discard dialog.
- **Read-only calendars offered writes:** the event menu shows only Copy and Duplicate as Task for them; ⌫ does nothing; the detail popover shows every field disabled. Verified on Columbus Day (Holidays).
- **⌘T kept the old selection:** `resetToToday` clears it (also on open and Go to Today). Verified.
- **A deleted event lingered under the second account:** `CalendarCache.deleteEvent` removes the event from every account that caches its calendar. Unit test `testDeleteRemovesEveryAccountsCopy`.
- **Hotkey after recording:** the recorder no longer unregisters the shortcut; presses are ignored while it listens. A second process holding ⌃⌥Space through Carbon did not reproduce the Fantastical failure on the old build either (both apps receive the press), so this change is not proven to fix that case. Check with Fantastical running.
- **`-selfTest` from saved defaults:** read only from the launch arguments. Verified: a `selfTest` key in the defaults no longer starts it.

## Review: menu bar panel and detail popover (#14–#17)
- **#14 Mini Window as a panel.** No arrow: a rounded panel centered under the status item, 6 pt below the menu bar, like Sound and Wi-Fi. Closes on Esc, the status item, a click elsewhere or an app switch; a §8 dialog keeps it open. The status item shows a drawn highlight while open. Pressing the item makes the app resign, which closed the panel before the item's own mouse-up; a close within 0.5 s before that mouse-up now ends the click there.
- **#15 RSVP state.** The current answer is an accent pill with a check and sends nothing when chosen again.
- **#16 Detail in place.** Opening another item reuses the open detail popover (saving the previous item first). Clicks in the panel defer the transient close until the click ends, whether AppKit asks on mouse-down or mouse-up, or a control consumes the mouse-up.
- **#17 Pinned RSVP.** An invitation's Maybe / Decline / Accept and its write error sit in a footer below the scrolling body.
- Verified each in the running app with real clicks; no RSVP was sent and no event was written while testing.

## Meet With (branch `meet-with`)
Google Calendar's "Meet with…": pick people, see their calendars over yours, click a free slot to create a meeting with them.
Decisions (2026-10-14, from the user): a separate window; other people's event titles where their calendar is shared, busy blocks otherwise; a click opens the new-event form filled in.

- [x] Core: `GoogleCalendarAPI.freeBusyRequest` and `FreeBusyResponse` (POST /freeBusy). The `calendar` scope already covers it.
- [x] Core: `Availability` — loads one person's week: `events.list` on their email (titles) through each account, falling back to `freeBusy` (busy blocks), else "not available". Skips their declined and free events.
- [x] Core: `Availability.lanes` — side-by-side layout of overlapping blocks within one person's column.
- [x] Tests: free/busy request and parse, the events → free/busy → unavailable fallback with FakeGoogle, lanes.
- [x] UI: `MeetWithWindowController` + `MeetWithView`: people chips and contact search (cache.allContacts + Contact.matching), week navigation, legend, a 24-hour week grid with one sub-column per person (me first), scrolled to 8 AM.
- [x] UI: hover highlights the 30-minute slot; click opens `EventEditor` (new draft: that slot, default duration, me + the people as attendees, default calendar) in a popover anchored to the slot; Add Event inserts through `EventWriter`.
- [x] Entry: ⚙ menu "Meet With…" ⇧⌘M; the status item's right-click menu too.
- [x] SPEC: new section, §4.4 menu, §11 shortcut.
- [x] Verify: tests, build, the window against real accounts (a colleague's titles and a free/busy-only person), slot click fills the form. Do not add an event with real invitees.

### Review
- Verified against the real accounts: mike@playful.software and kate@playful.software load with titles (their calendars are shared with darrin@playful.software); mikehar@hey.com gets "calendar not shared" and no column. Mike's week matches Google's Meet with view of the same week.
- A click on Thursday 2:00 PM opened the form: 2:00–3:00 PM, darrin@playful.software, 10-minute default alert, me + Mike invited. No event was added.
- Not seen: a person with busy times only (every shared colleague tried exposes titles).

## Video conferencing on events (requested 2026-10-14)
Decision (user): Zoom "whatever Google Calendar is doing" (a meeting per event in the Playful Software Zoom account), plus Google Meet.
- [x] `video` row on the event form: None / Google Meet / Zoom.
- [x] Google Meet through `conferenceData.createRequest`; the writer refetches after the write (Google changes the etag when it attaches the conference). Verified by `-selfTest` against Google: Meet link created, the edit after it saved.
- [x] Zoom: public-client PKCE sign-in through a loopback redirect, `ZoomAccount` (Keychain refresh token, rotation, 401 retry), meeting creation, Settings › Accounts › Video conferencing. Unit-tested.
- [x] Zoom app "Kalendar" registered in the Playful Software Zoom account (2026-10-14): General app, user-managed, development mode; Public Client OAuth on; redirect and allow list `http://127.0.0.1:47823/zoom`; scope `meeting:write:meeting`. Public client ID in `ZoomOAuth.clientID`. Verified: Settings › Connect… signed in through the browser; choosing Zoom on the form created meeting 880 8923 0655 ("Kalendar Zoom test", Oct 15 2:00 PM) and filled the location; choosing None removed it. No event was added.
- [x] Setting Video conferencing › New events (None / Google Meet / Zoom). A new event's Zoom meeting is now created at Add Event, so abandoned or changed forms leave no meeting. Verified with default Zoom: the form opened on Zoom; an event added on "test" got meeting 896 8179 8485 in its location and notes and Kalendar's Join; the event was then deleted and "test" hidden again; the setting was removed afterwards.
- [ ] The Zoom app is in development mode: only users in the Playful Software Zoom account can authorize it. Other users need it published (Production tab, Zoom review).
- [ ] The privacy policy (massena.com/kalendar/privacy) covers Google only; Zoom sends event titles and times to Zoom and keeps a Zoom token in the Keychain.

## Calendar window (branch `calendar-window`)
Decisions (2026-10-14, from the user): Day, Week and Month views; view, edit, create, and drag to move and resize; opened from the ⚙ menu "Open Calendar Window ⌘O" and the status item's menu.

- [x] `TimeGrid` (shared with Meet With): day columns with sub-columns, hours, all-day strip, now line, hover/drag-to-create highlight, block lanes. Blocks can open on click, move by dragging (15-minute steps, across days), and resize from the bottom edge.
- [x] `EventPopover`: an NSPopover at the pointer that saves on close (`EventEditorModel.shouldClose`, §8.1 question included); new-event forms add on Add Event. Meet With uses it too.
- [x] `CalendarWindowController` + model: day/week/month, ‹ › Today, ⌘1/⌘2/⌘3, events from the cache (declined and identical-event settings, calendar colors), refresh after each sync while open.
- [x] Month view: weeks of day cells with up to N event rows and "+k more"; click an event to edit, a day number for that day, empty space to create; drag an event to another day.
- [x] Moves and resizes write through `EventWriter.save`; a repeating event asks (§8.1), and "All" loads the series first. Read-only calendars and invitations don't move.
- [x] SPEC: new section; §4.4 menu, §11 shortcuts. Tests for the pure parts (lanes, move/resize math).
- [x] Verify in the app on the "test" calendar: create, open/edit, move, resize, month drag; then delete the test events.

### Review
- Built the shared `TimeGrid` and `EventPopover`; Meet With moved onto both.
- Verified in the app on darrin@massena.com (Saturday Oct 17, no guests, deleted after): created "Kalendar window test" from a click (Zoom default switched to None first), moved it by dragging (2:00 → 3:00), resized its end (4:00 → 4:30), opened its detail form, dragged it in Month to Oct 24, deleted it from its context menu. Day, Week and Month render the real calendars.
- Found and fixed while testing: a block's gestures sat at the grid's corner (attached after `.offset`); the create gesture took presses meant for blocks (now a layer under them); the window could keep a read-only copy of an identical event (now the writable copy, in the agenda too); other accounts' copies showed the old time after an edit (now updated).
- Not done: Google's "send updates to guests?" choice; Kalendar always notifies guests of an organizer's edit (asked about by the user, 2026-10-14).

## Send update emails to guests (branch `send-updates-choice`, 2026-10-15)
Decision (user): Send / Don't Send / Cancel only; no message (the Calendar API has no message field).
- [x] `EventWriter.save`/`delete` take `notifyGuests`; `Dialogs.notifyGuests` asks for events the user organizes with guests; detail popover save, calendar-window move/resize/delete, context-menu quick edits and Delete ask. Own-only changes (alerts, color, busy/free) ask nothing and email nobody.
- [x] Tests: `sendUpdates` is all / none / none for Send, Don't Send, delete-Don't-Send; `changesWhatGuestsSee`.
- [x] Verified in the app: an event on darrin@massena.com with darrin@playful.software as guest; a drag showed "Send update emails to guests?", Don't Send moved it; Delete showed "Send cancellation emails to guests?", Don't Send deleted it.


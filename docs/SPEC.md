# Kalendar — Implementation Spec

Kalendar is a macOS menu bar app: a small calendar window (the "Mini Window") anchored to a menu bar icon, plus the popovers, menus, and dialogs it opens. There is no full calendar window.

The behavior below was specified on 2026‑09‑21 from observation of an existing menu bar calendar app ("the reference app": settings, popovers, menus, dialogs) and its documentation. Sections tagged **[decision]** are defaults chosen for v1 and can be flipped; sections tagged **[out of scope]** exist in the reference app but are excluded.

**Data source (revised 2026‑10‑10).** Google is the single source of truth. Events come from the **Google Calendar API** and tasks from the **Google Tasks API**. Kalendar does not use EventKit or Apple Reminders. Kalendar delivers its own event alerts (§19). Sections below that described EventKit behavior have been rewritten in Google API terms; §18 lists the API facts that constrain the design.

---

## 1. Product summary

- Lives only in the menu bar (`LSUIElement = true`, no Dock icon).
- Global hotkey **⌃⌥Space** toggles a popover anchored to the status item.
- Popover = natural-language input field + month mini‑calendar + scrolling agenda list + bottom toolbar.
- Reads and writes events through the **Google Calendar API v3** and tasks through the **Google Tasks API v1**, for two Google accounts (`darrin@massena.com`, `darrin@playful.software`). Each account signs in with OAuth. A local cache plus incremental sync (§18.3) keeps the UI instant and readable offline.
- The "On My Mac" local calendar and Apple Reminders are not supported.
- Kalendar schedules and delivers event alerts itself (§19).
- Natural‑language parsing produces a live, editable event preview before commit.

---

## 2. Environment observed

| Item | Value |
|---|---|
| macOS appearance | Dark mode (app must support light too) |
| Accounts | Google `darrin@massena.com` (default calendar), Google `darrin@playful.software` (Workspace domain). The reference app also showed Local Calendar and Reminders; Kalendar drops both. |
| Calendars seen | darrin@massena.com, 3D Car Simulator, 3D Car Simulator Widget, test, darrin@playful.software, Playful Shared Calendar |
| Default task list | Google Tasks default list of the default account (`@default`, usually named "My Tasks"). The reference app's setting was "Darrin's list" in Reminders. |
| Default event duration | 1 hour |
| Week starts | Sunday |
| Day starts / ends | 8:00 AM / 6:00 PM |
| Menu bar icon | shows **Date** (calendar glyph with day number), monochrome, no "upcoming item" text |
| List shows | All Days |
| Show when events end | on |
| Show declined events | off |
| Combine identical events | on |
| Dim items on previous days | off |
| Go to today after adding items | on |
| Sort tasks by | Priority & Due Date in the reference app. Google Tasks has no priority, so Kalendar's default is **Due Date** (§10). |
| Show tasks in calendar views | on; show completed tasks: on |
| Paid tier | **not subscribed** in the reference app → emoji badges, weather in list header, calendar sets, openings, proposals, travel time are all inactive or unusable for this user and are out of scope |

---

## 3. Status item (menu bar icon)

- Template‑style calendar glyph showing today's day number ("21"). Redraw at midnight and on `NSCalendarDayChanged`.
- **Left‑click**: toggle popover.
- **⌥‑click** [out of scope]: the reference app opens the full window; here, no‑op or open Settings.
- Right‑click: small menu — Settings…, Check for Updates…, About, Quit. **[decision]**
- Must coexist with menu bar managers (Bartender/Ice): use a standard `NSStatusItem`; anchor the popover to `statusItem.button`.

---

## 4. Popover window

Observed geometry (from the live Mini Window, at 2× Retina): ~320 pt wide, ~600 pt tall by default; content is one vertical stack. Rendered with a small arrow pointing at the status item.

```
┌──────────────────────────────────────┐
│ [ NL input ……………………………… ]  ˅   🔍   │  ← input row
│  Sep 2026  (3)               ‹  ›    │  ← month title, invitation badge, nav
│  SUN MON TUE WED THU FRI SAT         │
│   30  31   1   2   3   4   5         │  ← 6-row grid, event dots under days
│    …                                 │
│  TODAY 9/21/26            72°/57° ☀  │  ← day header (weather = premium, omit)
│  ● 9:00 – 10:00 AM                   │
│    Team sync                         │
│  ● 11:00 – 11:50 AM  📹              │
│    1:1 with Alex                     │
│  ● 3:00 – 3:50 PM          [ Join ]  │  ← current/next call gets a Join pill
│    Design review                     │
│  TOMORROW 9/22/26                    │
│  …                                   │
│ (≡)   [ New Calendar Set ˅ ]   (⚙)   │  ← bottom toolbar
└──────────────────────────────────────┘
```

Behaviors:
- Opening via hotkey focuses the NL input immediately (empty, blinking caret).
- **Esc** closes the popover if the input is empty; clears the input if not. **[decision]**
- Clicking outside closes it (transient popover) unless "Keep in Front" is on.
- **Detach** (drag the input row out) and **Keep in Front** (⌃⌘A) → v2. **[decision]** v1 is attached‑only.
- On close, if the user navigated away from today, reset to today on next open. **[decision]** This is a fixed behavior, separate from the "Go to today after adding items" setting (§5.4), which only applies after a commit.

### 4.1 Input row
- Placeholder‑less text field; accent‑colored caret (§14).
- `˅` button to the right: opens the **templates** panel. [out of scope — user confirmed they don't use templates; omit the button entirely]
- 🔍 button: switches the field into **search** mode (see §9).
- While text is present an `×` clear button appears between the field and 🔍; it cancels the draft (with the discard dialog in §8.3 if the form was hand‑edited).

### 4.2 Month mini‑calendar
- Title "Sep **2026**" — month in `text`, year in `accent` (§14). Invitation badge (`bad` circle with count of pending invites) next to the title; hidden when zero. Clicking it opens the **Notifications popover** (§6.2). `‹ ›` step months.
- 7 columns SUN…SAT, header for the current weekday in `accent`. Six rows always; leading/trailing days from adjacent months dimmed.
- Today: `accent` filled circle. Selected day (when ≠ today): `accent` ring; the selected row gets a subtle highlight band. While an agenda row on today is selected, today's circle uses the selection color instead of the filled `accent`.
- Under each day: up to 4 small dots, one per event, colored by calendar; a `✓` glyph if a task is due. **[decision]** Declined events get no dot ("Show declined events" is off). **[decision]** cap at 4 dots, then "…".
- Click a day → the agenda list **smooth‑scrolls** (animated, ~0.3 s) so that day's section header lands at the top of the list; the day becomes the selected day. Days with no events still get a header ("No events" placeholder row) so the scroll target always exists. **[decision]** Scrolling the list manually does not change the selected day.
- **Double‑click a day** → starts a new entry pre‑dated to that day (input gets focus, form shows that date).
- Keyboard: `←/→` month, `⇧←/⇧→` day, `⇧↑/⇧↓` week, `⌘T` today.

### 4.3 Agenda list
- Sectioned by day. Header: `TODAY 9/21/26` (`accent`), `TOMORROW 9/22/26`, then weekday + date (`WEDNESDAY 9/23/26`). Weather in the header is premium — omit.
- Row layout: colored dot (calendar color; open circle = tentative/not-accepted; `⊘` = declined) · time range `9:00 – 10:00 AM` (end time shown because "Show when events end" is on) · optional 📹 glyph when a conference URL is detected · title on line 2 · location/URL on line 3 in dimmer text, single‑line, truncated.
- All‑day events are pinned at the top of their day section, directly under the header, as rounded pills filled with the calendar (or event) color, title only, no dot or time (observed: "Columbus Day" in yellow on the US Holidays calendar, 2026‑10‑12).
- An incomplete task whose due date has passed is shown in today's section, with its due date in `wait` above the title (observed in the reference app: "Sep 28 at 9:00 AM" on 10/12). Kalendar shows the date only ("Sep 28"), because Google Tasks stores no time.
- Past events today are dimmed (observed: events before now are grey; current/next are full white).
- The current or next event with a detected conference URL shows an `accent` **Join** pill at the trailing edge; clicking opens the URL. **[decision]** "Current or next" means the event is in progress or starts within 15 minutes; only one row shows the pill at a time. Conference URL sources, in order: the event's `conferenceData.entryPoints` entry with `entryPointType == "video"`, then `hangoutLink`, then a regex match for Zoom (`zoom.us/j/`), Google Meet, Teams, Webex, and FaceTime links in `location` and `description`.
- "List shows: All Days" → list is effectively infinite scroll forward. Load ±N months lazily. **[decision]** initial window: today → +60 days, extend on scroll.
- Combine identical events (same title, start, end, location across calendars) into one row.
- Single‑click a row → selects it and opens the **detail popover** (§6). Double‑click → same. `⌘E` toggles the popover for the selection.
- `⌫` / `⌘⌫` on a selected item → delete flow (§8).

### 4.4 Bottom toolbar
- Left `≡` button (tooltip "Free Mode" on this tier): view menu, observed:
  ```
    Day       ⌘1
    Week      ⌘2
  ✓ Month     ⌘3
    Quarter   ⌘4
  ─────────────
    Tasks     ⌘R
  ```
  **"Month" is the layout described in this spec** (month grid + agenda list) and is the user's only used view. Day/Week/Quarter swap the grid for a timeline/grid layout and are [out of scope]; v1 shows the menu with only **Month ✓** and **Tasks**. Tasks view replaces the list with "All Tasks" (§10); `⌘R` toggles it, `⌘3` returns to Month.
- Center pill `New Calendar Set ˅`: calendar‑set switcher. Observed menu: `All Calendars ⌃1`, `✓ New Calendar Set ⌃2`, —, `Hidden Items…`, `Add Interesting Calendars…`, `Manage Calendars…`. **[decision]** v1 replaces this with a single **calendar visibility** menu: one checkable row per calendar, grouped by account, matching the picker in §7.2. No sets.
- Right `⚙` action menu, observed:
  ```
  Open Full Calendar Window      ⌘O        (omit — no full window)
  Detach Mini Window                       (v2)
  Keep Mini Window in Front      ⌃⌘A       (v2)
  ─────
  Go to Today                    ⌘T
  Go to Date…                    ⇧⌘T       (opens a date-entry popover; NL date accepted)
  ─────
  Delete Item                    ⌘⌫        (disabled with no selection)
  ─────
  Refresh All                    ⇧⌘R
  Print…                         ⌘P        (omit)
  Openings…                      ⇧⌘O       (premium, omit)
  ⚙ Settings…                    ⌘,
  ─────
  Help                                     (omit)
  Contact Support                          (omit)
  ─────
  Quit Completely
  ```
  **[decision]** v1 menu: Go to Today ⌘T · Go to Date… ⇧⌘T · Delete Item ⌘⌫ · — · Refresh All ⇧⌘R · Settings… ⌘, · Check for Updates… (§20) · Launch at Login (checkable) · — · Quit ⌘Q. Detach / Keep in Front return in v2.

---

## 5. New‑item flow (natural language)

Typing anything in the input immediately shows the **new‑item form** below it, updating live on every keystroke. Enter commits; the `×` at the right of the input cancels (with a confirm dialog if the form has been edited by hand, §8.3).

### 5.1 Form — event, collapsed (default)
Observed fields, in order:

```
Title                              [☺+] [▣ | ✓]     ← emoji badge (premium, omit) · event/task toggle
Location (or "Add Location")
all-day   [ ]
starts    9/22/2026   12:00 PM
ends      9/22/2026    1:00 PM
calendar  ● darrin@massena.com
color     None
alert     15 minutes before          ⊕
show as   Busy
          Propose Another Time                      ← premium/scheduling, omit
 ˅                     [ Add Event ]
```

Clicking `˅` expands to the **full form**, which inserts: `time zone` (after ends), `repeat` + `repeat end` (after color), `travel time` (omit), `visibility`, then hairline‑separated sections: ☐ RSVP event link with a grey explainer (omit), **Add Invitees**, ☐ Google Meet with logo (omit v1), Add Attachment… (omit), **Add Notes** text area (`accent` caret when focused). Button becomes `˄`; the form scrolls within the popover, thin scrollbar at the right edge.

**Add Invitees**: clicking turns the row into a text field; typing (`bob`) drops a contact list over the rest of the form — avatar photo or initials, name, email; the same person appears once per email address, with a disambiguator in the name when needed ("Bob Day (gmail)"). First match highlighted with the selection color; Enter/click adds a chip and clears the field for the next invitee. Source: the Google People API for both accounts (§18.4) plus attendee addresses from events in the local cache. Saving writes the event's `attendees` array; new invitees are emailed by Google with `sendUpdates=all`.

Task form — toggle with the `▣ | ✓` segmented button in the form header, or type a `todo`/`task`/`reminder`/`√` prefix. (⌘K is documented as the toggle but **does nothing in the Mini Window** — observed; don't rely on it.)

```
Title                                     [▣ | ✓]
due       [ ] On a day            ← checked + date only when a date was parsed
list      ● My Tasks
Notes
 ˅                     [ Add Task ]
```

Google Tasks stores the due **date** only; the API discards any time (§18.2). The task form therefore has no time field. If the input contains a time (`todo call Bob tomorrow 3pm`), the parser consumes the time token, the form shows the date only, and a grey line under `due` reads "Google Tasks stores dates only". **[decision]** The list picker lists task lists from both accounts, grouped by account.

### 5.2 Live parse behaviors observed
| Input | Result |
|---|---|
| `Lunch with Sam tomorrow at noon at Tartine alert 15 min` | title "Lunch with Sam" (no contact matched "Sam" → kept in title), location "Tartine", 9/22 12:00–1:00 PM, alert 15 min before; mini‑calendar selection jumps to 9/22 |
| `Coffee tomorrow 3pm` | 9/22 3:00–4:00 PM (default 1 h) |
| `Standup every weekday at 9:15am for 15 minutes` | 9:15–9:30 AM, repeat **Custom… "Every week on Monday, Tuesday, Wednesday, Thursday and Friday"**, repeat end Never |
| `/m` | inline **CALENDARS** suggestion list filtered by prefix (shows account name in grey: "darrin@massena.com Google") |
| `with Da` | inline **CONTACTS** list: avatar initials, name, email; fuzzy on first/last name. Same source as Add Invitees (§18.4). |
| `at Top` | inline **LOCATION SUGGESTIONS**: pin icon, place name, address (Apple Maps search); previous locations first |
| trailing `!`, `!!`, `!!!` on a task | priority low/med/high in the reference app. **Not in Kalendar**: Google Tasks has no priority field. `!` is left in the title as typed. |
| `"quoted text"` | literal title, not parsed |
| `ddd` (title only, no date/time) | **all‑day event today**, `show as Free`, alert None, link reads "Propose Another Date"; ✓ toggle → task "ddd" with `due ☐ On a day` unchecked, list My Tasks |

Suggestion popups: appear directly under the input, full popover width, keyboard `↑↓` + Enter/Tab to accept, Esc to dismiss. Accepting `/x` removes the token from the text and sets the calendar; accepting a contact adds an invitee chip and removes `with …`; accepting a location fills the location field and removes `at …`.

The title in the form updates live as the parser strips recognised tokens (e.g. the field showed "Coffee" while "Coffee tomorrow 3pm at Top" was being typed, with "Top" in the location line).

### 5.3 Parser requirements (minimum grammar)
- Dates: `today, tomorrow, tonight, <weekday>, next <weekday>, <month> <d>, <m>/<d>, <m>/<d>/<yyyy>, on <date>`; date ranges `from Aug 9-18`, `Aug 9 to Aug 18`, `until <date>`.
- Times: `3pm, 3:15pm, 15:00, noon, midnight, at <time>, <time>-<time>, from <time> to <time>`, `for <n> (min|minutes|hours|h)`.
- All‑day when no time given; all‑day multi‑day for ranges without times.
- Recurrence: `every day/week/month/year`, `every <weekday>`, `every weekday`, `<weekday>s and <weekday>s`, `every other <unit>`, `every N <unit>s`, `until <date>`, `for N times`.
- `alert <n> (min|hours|days)`, `alert at <time>`; multiple alerts allowed.
- `/calendarPrefix`, `with <contact>`, `at <location>`, `todo|task|reminder|√` prefix, quoted literals, `all day`. (No `!` priority; see §5.2.)
- Test corpus: the §5.2 table plus Kalendar's own example sentences in `Tests/KalendarCoreTests/Fixtures/nl-corpus.json` (written for Kalendar rather than copied from the reference app's documentation).
- Implementation **[decision]**: hand‑written tokenizer + rule parser in Swift (deterministic, offline, instant). `NSDataDetector` can seed date/time spans but does not cover recurrence/duration. LLM parsing is explicitly not used.

### 5.4 Commit
- Enter or **Add Event / Add Task** → `events.insert` / `tasks.insert`, play the UI confirmation sound (setting on), clear the input, close the form, and — because "Go to today after adding items" is on — return the list to today after ~2 s unless the user interacts.
- The new item appears in the list immediately (optimistic insert into the cache). If the write is offline it is queued (§18.3).
- Errors (calendar `accessRole` is `reader` or `freeBusyReader`, API error) → inline `bad` text under the form.

---

## 6. Detail / edit popover (existing item)

Single‑click a list row → the row gets the selection color (§14) and a second popover (~300 pt wide, same `background`) opens **to the left of the Mini Window**, its arrow pointing right at the selected row (observed; it flips to the right side if there's no room). Its height grows with content — an invitation with 11 attendees and long notes ran nearly the full screen height, while a plain event is a compact card ending at the `˅` expander. It is **directly editable** — same layout as the new‑item form, values pre‑filled, no separate "edit mode". Changes save on popover close (Esc/click‑out) **[decision]**; the reference app autosaves the same way.

Collapsed content observed (Workout, weekly):
```
Workout                                     [☺+]
Add Location
all-day    [ ]
starts     9/22/2026   8:00 AM
ends       9/22/2026   9:00 AM
calendar   ● darrin@playful.software
color      None
repeat     Every Week
repeat end Never
alert      10 minutes before                 ⊕
show as    Busy
visibility Public
 ˅
```
Expanded (`˅`) adds: time zone, travel time (omit), Add Invitees, Google Meet toggle (omit), Add Attachment… (omit), Add Notes.

For an **invitation** (observed on an interview invitation in the Mini Window): title, "Add Location", fields (all‑day, starts, ends, calendar, color, travel time, alert ⊕, show as, visibility — note: no repeat rows for a one‑off, and the field set is the collapsed one; no `˅` expander on invitations), then:
- **Attendee list**, one per line, status icon + name/email + role suffix:
  - `ok` circle ✓ = accepted · `bad` circle ✗ = declined · `wait` circle ? = tentative/maybe · `muted` outlined ? = no reply
  - name shown as contact name when matched (e.g. "Alex Kim", with a small Slack glyph when the contact came from Slack) otherwise the email
  - suffix `(organizer)`, `(optional)`, `(me, optional)`; required attendees have no suffix
- "Add Invitees" link
- separator, then **Propose New Time** (with icon) — premium/scheduling, omit
- separator, then **notes body** as plain text with auto‑detected links underlined in `accentInk` (links may be Google‑wrapped `google.com/url?q=` redirectors — unwrap `q=` for display and open the target directly)
- "Add Comment" field (writes the attendee comment on RSVP; **[decision]** omit in v1. The API supports it as `attendees[].comment`, so it can return in v2.)
- bottom button row **Maybe / Decline / Accept** — grey pills, Maybe at leading edge, Decline and Accept trailing.

Accept/Decline/Maybe set `responseStatus` to `tentative` / `declined` / `accepted` on the attendee with `self == true`, via `events.patch` with `sendUpdates=all` so the organizer is notified. `patch` replaces arrays, so the request sends the full `attendees` array with only the user's entry changed. For a recurring event, the response applies to the instance unless the user picks "All" in the §8.1 dialog. After a response the row's dot in the agenda list changes from outlined to filled and the item leaves the Notifications popover (§6.2).

### 6.1 Field editors observed
- **starts / ends date**: click → inline **date picker** popover: "Sep 2026" header with `◂ ● ▸`, 7‑col grid, today in `accent`.
- **time**: click → editable text with `↑↓` stepping (15‑min increments). **[decision]**
- **calendar**: click → menu grouped by account name (grey header) with color dots: `Google › darrin@massena.com ✓, 3D Car Simulator, 3D Car Simulator Widget, test`; `Darrin Massena › darrin@playful.software, Playful Shared Calendar`. Only calendars with `accessRole` `writer` or `owner` are listed. Moving an event to a calendar in the same account uses `events.move`. Moving it to the other account is insert‑then‑delete and is allowed only for events the user organizes. **[decision]**
- **color**: popup `None` (use the calendar's color) plus Google's 11 event colors from `colors.get` (`event` palette), written as `colorId`.
- **alert**: popup `None ✓ · At time of event · 1 minute before · 5 · 10 · 15 · 30 · 45 minutes before · 1 hour · 2 hours before · 1 day · 2 days before · Custom…`; `⊕` adds a second alert row. Alerts are written as `reminders.overrides` with `method: "popup"` and `useDefault: false`; "At time of event" is `minutes: 0`. Google allows at most 5 overrides, so `⊕` is hidden at 5 rows. An event with `useDefault: true` shows the calendar's `defaultReminders` in grey.
- **repeat**: popup `None · Every Day · Every Week · Every Month · Every Year · Custom…`. Written as an RFC 5545 `RRULE` line in the master event's `recurrence` array.
  **Custom…** opens a small sheet: `Frequency: [Weekly ⌃]`, `Every [1] ⌃ week`, weekday toggle strip `S M T W T F S`, `Cancel / OK`. Monthly/yearly variants add day‑of‑month / ordinal controls. After choosing, the form shows the human summary under the field ("Every week on Monday, Tuesday…").
- **repeat end**: `Never · On date… · After N times`.
- **show as**: `Busy · Free`, written as `transparency` `opaque` / `transparent`. **visibility**: `Default · Public · Private · Confidential`, written as `visibility`.
- **all‑day** checkbox hides the time columns.

---

### 6.2 Notifications popover (pending invitations) — observed

Opened by clicking the `bad` count badge beside the month title. A rounded card (~285 pt wide) with an arrow pointing up at the badge, overlaying the calendar grid.

```
            Notifications                    (⋯)
────────────────────────────────────────────────
 (A)  Interview: candidate 1
      From: alex@example.com
      Mon, Sep 21 3:30 PM
 [ Maybe ]                 [ Decline ] [ Accept ]
────────────────────────────────────────────────
 (S)  Planning review
      From: sam@example.com
      Mon, Sep 21 4:00 PM
 [ Maybe ]                 [ Decline ] [ Accept ]
────────────────────────────────────────────────
 (A)  Interview: candidate 2
      From: alex@example.com
      Wed, Sep 23 2:00 PM
 [ Maybe ]                 [ Decline ] [ Accept ]
```

- Header: centered bold "Notifications", trailing `⋯` button. Observed menu (translucent rounded panel, no separators): **Accept All Invitations · Decline All Invitations · Maybe All Invitations**. Each applies the corresponding status to every row and empties the list.
- One row per pending invitation across all visible calendars, sorted by event start. Row: circular avatar with the organizer's initial (contact photo if available), event title (white, 15 pt), `From: <organizer email>` and `<Weekday, Mon d h:mm AM/PM>` in grey.
- Button row: **Maybe** at leading edge, **Decline** and **Accept** grouped at trailing edge; grey pill buttons, no destructive coloring.
- Tapping a button writes the user's `responseStatus` as described in §6 and removes the row with a short animation; the badge count decrements. If the API rejects the write, show an inline error and keep the row.
- Clicking the row body (not a button) closes this popover and opens the event's detail popover (§6 invitation variant) with the same Maybe/Decline/Accept row at the bottom.
- Data source: cached events from today−7 d to +90 d on visible calendars that have an attendee with `self == true` and `responseStatus == "needsAction"`. Events the user organizes are excluded. For a recurring invitation, only the next pending instance is listed. **[decision]** The badge count is this list's count.
- Esc or click-out closes it.

## 7. Menus

### 7.1 Event context menu (right‑click a row) — observed
```
Ask Siri                              (omit)
────
Go to Previous Occurrence             (recurring only)
Go to Next Occurrence
────
Join Zoom Meeting                     (only when a conference link is detected; label names the service)
────
Color            ›
Show As          ›
Visibility       ›
────
[emoji row]                           (premium, omit)
────
Cut                                   (disabled on events the user can't move — invitations)
Copy                                  (disabled likewise)
Duplicate
Duplicate as Task
Create Template                       (omit v1)
Delete
Hide                                  (omit v1)
────
Email Event                           (omit v1)
Email All Invitees                    (omit v1)
```
v1 keeps: Go to Previous/Next Occurrence, Join <Service> Meeting, Color ›, Show As ›, Visibility ›, Copy, Duplicate, Duplicate as Task, Delete. **[decision]** The right‑clicked row gets a thin outline in its calendar color while the menu is open.

### 7.2 Calendar visibility menu (replaces calendar sets) — see §4.4.

### 7.3 Task context menu: Complete/Uncomplete, Move to List ›, Duplicate as Event, Delete. **[decision]** No Priority submenu (Google Tasks has no priority). Move to List uses `tasks.move` with `destinationTasklist` within one account; moving to a list in the other account is insert‑then‑delete.

---

## 8. Dialogs (all observed; replicate as `NSAlert`‑style sheets or centered panels)

### 8.1 Delete a recurring event
Centered panel, app icon, bold title **"You're responding to a repeating event."**, body "Do you want to respond to only this occurrence of the event, or all occurrences?", buttons stacked: **Only This Event** (`accent`, default) / **All** / **Cancel**. Same dialog for edits and RSVPs on a recurring event.

API mapping: **Only This Event** patches or deletes the instance (its `id` is the instance id; deleting it records a cancelled exception). **All** patches or deletes the master event (`recurringEventId`). A time change applied to All shifts the master's `start`/`end` by the same offset the user applied to the instance.

Because the detail popover saves on close (§6), the dialog is shown when the user dismisses the popover and before it closes. Cancel keeps the popover open with the edits intact.

### 8.2 Delete a non‑recurring event
No confirmation in the reference app (undo via ⌘Z). **[decision]** v1: no confirmation, offer Undo via `⌘Z` within the session. Undo is offered only for events the user organizes. It restores the event by patching the deleted (now `status: "cancelled"`) event back to `status: "confirmed"`. If Google rejects that, Undo inserts a copy from the cache as a new event, without re‑sending invitations. Verify the patch behavior in milestone 3. Deleting an invitation the user didn't organize removes it only from the user's calendar; that action has no undo.

### 8.3 Discard a new item
Shown when cancelling a new‑item form that has been edited by hand (not when the only content is the NL text): **"You're about to discard this item."** / "Are you sure you want to close and discard your information? You can't undo this action." / **Cancel** · **Discard** (`accent`, default).

### 8.4 Premium upsell
The reference app shows upsell messages for its paid features. Not applicable.

### 8.5 Accounts and permissions
- **Google sign‑in.** With no account signed in, the popover shows a single row "Sign in with Google" and a button. Sign‑in uses `ASWebAuthenticationSession` (§18.1). Settings › Accounts adds a second account and signs accounts out. Signing out deletes that account's Keychain tokens and all of its cached data (events, tasks, contacts, queued writes); the published privacy policy (massena.com/kalendar/privacy) promises this. If an account's refresh token is revoked or expires, its calendars stay visible from the cache, and a row at the top of the list reads "Sign in again to <email>" with a button.
- **Notifications.** Requested on first launch after sign‑in (`UNUserNotificationCenter.requestAuthorization`). If denied, Settings › General shows "Alerts are off in System Settings" with an "Open System Settings" button.
- **Contacts** come from the Google People API under the same sign‑in (§18.4). Kalendar does not request macOS Contacts access.
- Kalendar needs no privacy usage strings in Info.plist and no hardened‑runtime resource entitlements (no calendars, contacts, reminders, or location).

---

## 9. Search

- 🔍 button or `⌘F` turns the input row into search mode (observed in the Mini Window): the 🔍 icon gains a `˅` and becomes a **scope dropdown** — `Title · Location · Invitees · ✓ All` — the field gets a blue caret, and an `×` button at the trailing edge exits search. The `˅` templates button and the normal input are hidden while in search mode.
- Typing filters live; Enter shows results as the same day‑sectioned agenda list, spanning past and future, matched against the chosen scope (All = title + location + notes + attendee names). Observed result for "Darrin": every event whose title or attendees contained the term, sectioned TODAY / TOMORROW / ….
- Scope selection persists across searches within the session. **[decision]**
- `⌘↓` moves focus from the field to the first result. Esc clears and returns to the normal list.
- **[decision]** search runs over the local cache, which covers −1 year to +1 year (§18.3), filtered in memory. No server‑side `q=` search in v1.

---

## 10. Tasks view (`⌘R` or ≡ › Tasks)

Observed in the reference app: sidebar switches to a plain list titled **"All Tasks"** with a `⊙` menu at the right; each row is a circle checkbox + title; tasks with a due date show a small grey `Sep 28 at 9:00 AM ↻` line above the title (↻ = recurring). No day sections. Sorted by Priority & Due Date. Clicking the circle completes the task (strikes through, then disappears unless "show completed").

Kalendar differences, all caused by the Google Tasks API (§18.2):
- The due line shows the date only (`Sep 28`). No time, no `↻`.
- Sort options are **Due Date** (default; undated tasks last) and **My Order** (the list's `position`). No priority.
- Subtasks (tasks with `parent`) are indented under their parent. **[decision]**
- "All Tasks" merges every task list from both accounts.

Tasks are Google Tasks. Completing writes `status: "completed"`; uncompleting writes `status: "needsAction"`. Task rows also appear inside the agenda list on their due day (setting "Show tasks in calendar views" is on), pinned with the all‑day items, with a circle checkbox instead of a dot.

---

## 11. Keyboard shortcuts (in scope)

| Keys | Action |
|---|---|
| ⌃⌥Space (global, configurable) | Toggle popover |
| ⌘N | Focus NL input for a new event |
| ⌘F | Search |
| ⌘↓ | From search field to first result |
| ⌘T | Go to today |
| ⌘R | Tasks view |
| ⌘3 | Month view (the default layout); ⌘1/⌘2/⌘4 reserved for Day/Week/Quarter (out of scope) |
| ⌘E | Show/hide detail popover for the selection |
| — | Event/task toggle is the segmented button in the form; ⌘K is inert in the Mini Window |
| ⌘I | Same as ⌘E |
| ⌫, ⌘⌫ | Delete selected item |
| ← / → | Previous / next month |
| ⇧← / ⇧→ | Previous / next day |
| ⇧↑ / ⇧↓ | Previous / next week |
| ↑ / ↓ | Move selection in the list |
| Enter | Commit form / open selected item |
| Esc | Dismiss suggestion → clear input → close popover |
| ⌘, | Settings |
| ⇧⌘T | Go to Date… |
| ⇧⌘R | Refresh All (run an incremental sync for every calendar and task list now) |
| ⌘Q | Quit |
| ⌃⌘A | Keep popover in front (v2) |

---

## 12. Settings window (`⌘,`) — v1 subset

Tabs: **General**, **Accounts**, **Appearance**, **Events & Tasks**, **Calendars**.

- General: Launch at login; Global shortcut recorder; Default calendar; Default task list; Default event duration (15/30/45/60/90/120 min); Start week on; Day starts at (**[decision]** the hour a new timed slot starts; "Day ends" is omitted because only the out-of-scope Day and Week views use it); Play UI sound; Go to today after adding items; Show alerts (on); Check for updates automatically (on, §20).
- Accounts: one row per signed‑in Google account (email, "Sign Out"), and an "Add Account…" button (§8.5).
- Appearance: Menu bar icon shows (Icon only / Date / Next event title / Next event + countdown); Use color icon; Text size (Small/Normal/Large); Theme (System/Light/Dark). All four icon options are in v1.
- Events & Tasks: List shows (Next 7 days / 14 / 30 / All days); Show when events end; Show declined events; Combine identical events; Dim items on previous days; Show tasks in list; Show completed tasks; Sort tasks by (Due Date / My Order).
- Calendars: checklist of calendars grouped by account (visibility), and a checklist of Google Tasks lists grouped by account. **[decision]** Calendar visibility here and in the §4.4 menu reads and writes Google's `calendarList` `selected` flag (`calendarList.patch`), so it matches Google Calendar on the web. Task‑list visibility has no Google equivalent and is stored locally.

Persist with `UserDefaults`; the observed values in §2 are the defaults.

---

## 13. Architecture

- **Swift (tools‑version 5.10, matching Kapture), SwiftUI for content, AppKit for the shell** (`NSStatusItem`, `NSPopover`, `NSPanel` for detached mode later, `NSMenu` for context menus).
- Targets macOS 14+.
- **Project layout follows Kapture** (`~/src/kapture`): a SwiftPM package with no Xcode project, an executable target `Kalendar` plus a library target `KalendarCore` for testable non‑UI code, and `scripts/bundle.sh` to assemble, sign and package the `.app` (§20).
- Reused from Kapture: `Keychain.swift` (token storage), GRDB for the SQLite cache, `HotkeyCenter` (Carbon `RegisterEventHotKey`, plus a test fire to detect a shortcut another app already holds, since registration reports success anyway) and launch at login via `SMAppService.mainApp`.
- **Popover risk, prototype in milestone 1.** The detail popover (§6) and Notifications popover (§6.2) are anchored to views inside a transient `NSPopover`. Clicking in a child popover can close the parent. An `LSUIElement` app must call `NSApp.activate` before the input field receives keyboard focus from the hotkey. If `NSPopover` cannot do this, the fallback is a borderless `NSPanel` with a drawn arrow.
- Modules:
  - `GoogleAuth` — OAuth sign‑in per account, Keychain token storage, token refresh (§18.1).
  - `GoogleClient` — typed REST calls for Calendar v3 and Tasks v1 with `URLSession`; retries with exponential backoff on 403 `rateLimitExceeded` / 429 / 5xx. **[decision]** No Google SDK dependency.
  - `SyncEngine` — per‑calendar and per‑task‑list incremental sync, write queue, offline handling (§18.3).
  - `CalendarStore` — reads the local cache; publishes events and tasks for a date range; caches per‑day buckets; handles combine‑identical and calendar visibility.
  - `AlertScheduler` — schedules and delivers event alerts (§19).
  - `NLParser` — pure Swift, `parse(String, referenceDate:, defaults:) -> ParsedItem` with a token map so the UI can highlight consumed spans. Fully unit‑tested against the §5.2 table plus the reference app's example sentences.
  - `Suggestions` — `/` calendars, `with` contacts (People API cache, §18.4), `at` places (`MKLocalSearchCompleter` + recent locations).
  - `ConferenceDetector` — reads `conferenceData` and `hangoutLink`, then falls back to regexes for Zoom/Meet/Teams/Webex/FaceTime (§4.3); feeds the 📹 glyph, the Join pill and the alert's Join action.
  - `UI` — `PopoverRoot`, `InputRow`, `MonthGrid`, `AgendaList`, `ItemForm`, `DetailPopover`, `TasksList`, `SettingsView`.
- State: one `@Observable AppModel` (selectedDate, visibleRange, mode: .list/.tasks/.search, draft: ParsedItem?, selection).
- Undo: `UndoManager` around API saves and deletes (limits in §8.2).

---

## 14. Visual details

Kalendar uses its own palette, not the reference app's. It is the palette of browser-driver-mcp's setup page: a `#00AAFF` blue accent on navy (dark) or near-white (light). Every color is a token in `Sources/Kalendar/Theme.swift`; views use no literal colors and not the system accent.

| Token | Light | Dark | Used for |
|---|---|---|---|
| accent | `#00AAFF` | `#33BBFF` | buttons and CTAs (Add Event, Accept), today's circle, the year in the month title, the current weekday header, the TODAY section header, the Join pill, the text caret, toggles |
| accentInk | `#0077C2` | `#66CCFF` | links in notes, accent-colored text at body size |
| background | `#F6F8FB` | `#0B1119` | popover (arrow included), detail popover, windows |
| card | `#FFFFFF` | `#121A25` | raised surfaces inside the background: the new-item form, suggestion lists, the Notifications card |
| text | `#18202B` | `#E6EDF5` | primary text |
| muted | `#5C6878` | `#93A2B5` | secondary text, past events, dimmed adjacent-month days, toolbar icons |
| line | `#E2E7EE` | `#223042` | hairline separators |
| ok | `#16A34A` | `#4ADE80` | accepted attendee |
| wait | `#B7791F` | `#F0B458` | tentative attendee, overdue task date |
| bad | `#C0392B` | `#F87171` | declined attendee, inline errors, pending-invitation badge |

- Row selection: accent at 20% opacity behind the row, text stays `text`.
- Calendar color dots keep each calendar's own Google color.
- The popover is opaque (`background`), not the translucent system popover material. NSPopover's frame, including the arrow, is painted with `background` so it matches the content.
- Fonts: SF Pro; month title ~26 pt semibold; day numbers 13 pt; list times 12 pt, titles 13 pt, subtitles 11 pt.
- Calendar color dots 8 pt; event dots under days 4 pt.
- Popover corner radius 12 pt; inner cards 10 pt.
- The menu bar icon stays a monochrome template image.

---

## 15. Out of scope (present in the reference app, excluded)

Full calendar window and day/week/month/quarter/year views · calendar sets and location/time auto‑switching · weather · travel time / time‑to‑leave · emoji badges · templates · Openings / Proposals / RSVP links · Google Meet/Zoom/Webex creation (the API supports Meet creation; candidate for v2) · attachments · email event/invitees · Hide items · Siri · Todoist · Apple Reminders · the "On My Mac" local calendar · Focus filters · widgets · printing · vendor account and sync.

---

## 16. Resolved questions

- Detach / Keep in Front: v2 (§4).
- RSVP: in v1 (§6.2).
- Menu bar icon: all four options in v1 (§12).
- Data source: Google Calendar and Google Tasks only (§1).
- Alerts: delivered by Kalendar (§19). The user turns off Calendars for the Google accounts in Internet Accounts to avoid duplicate alerts from Calendar.app.
- Calendar visibility: synced with Google's `calendarList` `selected` flag (§12).
- Tasks view: kept (§10).
- NL grammar: §5.3 is sufficient.
- Bundle ID: `com.massena.kalendar` (§20).
- Contacts: Google People API (§18.4).

---

## 17. Milestones for Claude Code

1. **Shell**: status item, popover (including the nested‑popover prototype, §13), global hotkey, Google sign‑in for both accounts, Settings skeleton, launch at login, Sparkle updater and the release workflow (§20).
2. **Sync + read‑only agenda**: GRDB cache and `SyncEngine` (§18.3), month grid with dots, sectioned list, Join detection, navigation and keyboard shortcuts, search.
3. **Detail popover**: view + inline edit of all §6 fields, pickers, RSVP, invitees, recurring‑edit dialog, delete/undo, context menu, write queue.
4. **NL parser + suggestions**: grammar in §5.3 with tests, live form preview, `/`, `with`, `at` popups, commit.
5. **Tasks + alerts**: Google Tasks in list, Tasks view, task form; `AlertScheduler` (§19).
6. **Polish**: light mode, text sizes, icon options, settings persistence, accessibility labels, VoiceOver on the grid.

---

## 18. Google APIs

### 18.1 Sign‑in
- **Created 2026‑10‑12:** Google Cloud project `kalendar-511416` (organization massena.com). Calendar, Tasks and People APIs enabled. Auth Platform: app name "Kalendar", audience External, the 7 scopes below, test users `darrin@massena.com` and `darrin@playful.software`. OAuth client "Kalendar macOS" (iOS type, bundle ID `com.massena.kalendar`), client ID `592663087020-a63og6tg0r67prkfcp9oa9l5s4qs2l96.apps.googleusercontent.com`, redirect scheme `com.googleusercontent.apps.592663087020-a63og6tg0r67prkfcp9oa9l5s4qs2l96`. Publishing status **In production, unverified** (100‑user lifetime cap; sign‑in shows Google's "unverified app" warning). Branding: home page `https://massena.com/kalendar/`, privacy policy `https://massena.com/kalendar/privacy`, authorized domain `massena.com`. The pages live in `~/src/massena-com/static/kalendar/` and deploy by pushing to master (Cloudflare Pages).
- One Google Cloud project for Kalendar. OAuth client type **iOS** (Google uses this type for native macOS apps), registered with Kalendar's bundle ID. Redirect URI is the reversed client ID scheme (`com.googleusercontent.apps.<id>:/oauth2redirect`). PKCE, no client secret. Sign‑in runs in `ASWebAuthenticationSession`.
- Scopes: `openid`, `email`, `https://www.googleapis.com/auth/calendar` (full scope; `calendarList.patch` needs it), `https://www.googleapis.com/auth/tasks`, `https://www.googleapis.com/auth/contacts.readonly`, `https://www.googleapis.com/auth/contacts.other.readonly`, `https://www.googleapis.com/auth/directory.readonly` (§18.4). All API scopes are classified as sensitive.
- Consent screen: user type External, publishing status **In production**, unverified. Google shows an "unverified app" warning at sign‑in. Do not leave it in Testing: refresh tokens for apps in Testing expire after 7 days.
- `playful.software` is a Workspace domain. Its admin may need to mark the client ID as trusted (Admin console › Security › API controls) before sign‑in succeeds.
- Refresh tokens are stored in the Keychain, one item per account email. Access tokens are kept in memory only.

### 18.2 Data mapping and API limits
Events (Calendar v3):

| Kalendar field | Google field |
|---|---|
| calendar list, colors, write access | `calendarList`: `summary`, `backgroundColor`, `accessRole`, `selected`, `primary`, `defaultReminders` |
| title / location / notes | `summary` / `location` / `description` (HTML allowed; render as text with links) |
| starts / ends, all‑day | `start` / `end` with `dateTime` + `timeZone`, or `date` for all‑day (end date is exclusive) |
| repeat | master event `recurrence` (`RRULE`, `EXDATE`, `RDATE`); instances carry `recurringEventId` |
| alert | `reminders.useDefault`, `reminders.overrides[]` (max 5) |
| show as | `transparency` |
| visibility | `visibility` |
| color | `colorId` (palette from `colors.get`) |
| invitees, RSVP | `attendees[]` with `email`, `displayName`, `self`, `organizer`, `optional`, `responseStatus` |
| conference link | `conferenceData.entryPoints[]`, `hangoutLink` |

Tasks (Tasks v1):
- Fields: `title`, `notes`, `status` (`needsAction` / `completed`), `due`, `completed`, `parent`, `position`, `deleted`, `hidden`.
- `due` is a date only. The API discards the time portion.
- No priority, no recurrence, no reminders. Tasks therefore have no alerts.
- Tasks completed in Google's apps are returned only with `showHidden=true`.

### 18.3 Sync, cache and writes
- Cache: SQLite through GRDB, in `~/Library/Application Support/Kalendar/`. Holds calendar lists, event instances, master recurring events, task lists, tasks, sync tokens, and the write queue.
- **Event sync (built in milestone 2):**
  - First sync of a calendar: instances for the window come from `events.list` with `singleEvents=true`, `timeMin` = today − 1 year, `timeMax` = today + 1 year. Then one pass over every event with `singleEvents=false` and `fields=nextPageToken,nextSyncToken,items(id)` (ids only, so it is cheap) yields the change-stream `syncToken`.
  - Incremental sync reads the change stream (`singleEvents=false` + `syncToken`). A changed single event is upserted, or deleted when `status` is `cancelled`. A changed recurring master, or an exception (`recurringEventId`), refetches that series with `events.instances` over the window and replaces its cached instances. Kalendar never expands recurrence rules itself.
  - HTTP 410 on a `syncToken` discards that calendar's cache and runs a first sync. So does a window more than 30 days stale.
  - Every calendar is synced, including hidden ones, so showing a calendar is instant. `freeBusyReader` calendars are skipped.
- **Task sync:** `tasklists.list`, then `tasks.list` per list with `updatedMin` = last sync time, `showDeleted`, `showHidden`, `showCompleted`.
- **Sync triggers [decision]:** every 60 s while the popover is open, every 5 min otherwise, on popover open, on wake (`NSWorkspace.didWakeNotification`), when the network returns (`NWPathMonitor`), and on ⇧⌘R. No push notifications in v1 (they require a public HTTPS webhook).
- **Writes:** applied to the cache first so the UI updates immediately, then appended to a persistent queue that runs in order. Patches send `If-Match` with the cached `etag`. On 412 (changed elsewhere), Kalendar refetches the item, discards the local change, and shows an inline error. Offline writes wait in the queue; a grey "Offline — changes will sync" row shows at the top of the list.
- Retries: exponential backoff on 403 `rateLimitExceeded`, 429 and 5xx.

### 18.4 Contacts (People API)
- Sources, per account, cached in the local database:
  - `people.connections.list` (saved contacts), `personFields=names,emailAddresses,photos`.
  - `otherContacts.list` (addresses the user has emailed or met with), `readMask=names,emailAddresses,photos`.
  - `people.listDirectoryPeople` (Workspace directory), `readMask=names,emailAddresses,photos`, `sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE`. Only for Workspace accounts (`playful.software`). **[decision]** Included because most invitees in the captured data are coworkers. A personal Gmail account returns an error for this call; Kalendar skips it for that account.
- Both list calls support `requestSyncToken=true`; sync daily and on Refresh All.
- Suggestions are filtered locally from the cache, so typing has no network latency. Kalendar does not use `searchContacts`.
- Photos are fetched from the returned `url` on first display and cached on disk.

---

## 19. Alerts

Kalendar delivers event alerts itself through `UNUserNotificationCenter`.

- **Which alerts:** for each cached event instance on a visible calendar, the effective reminders are `reminders.overrides` with `method: "popup"`, or the calendar's `defaultReminders` with `method: "popup"` when `useDefault` is true. Email reminders are ignored. Events the user has declined get no alerts. All‑day event reminders count back from 00:00 local time on the start date.
- **Scheduling:** `AlertScheduler` schedules alerts that fire in the next 24 hours, at most 64 pending at once **[decision]**, using `UNCalendarNotificationTrigger`. It recomputes after every sync, at midnight, and on wake. Each request's identifier is `<calendarId>|<eventId>|<minutes>`, so rescheduling replaces it and a deleted event's alert is removed. macOS delivers scheduled notifications even if Kalendar is not running, but rescheduling requires Kalendar to be running, so launch at login defaults to on.
- **Content:** title is the event title. Body is the time range and location, for example "3:00 – 3:50 PM · Zoom". Default sound.
- **Actions:** **Join** (only when `ConferenceDetector` finds a URL; opens it), **Snooze 5 Minutes** (schedules a one‑off repeat). Clicking the notification opens the popover with that event's detail popover. **[decision]**
- **On wake:** alerts that fired while the Mac slept are kept if the event has not ended; delivered alerts for ended events are removed.
- **Duplicates:** Google Calendar on the web and on phones sends its own notifications, which Kalendar does not control. On this Mac, Calendar.app also alerts if the Google accounts have Calendars enabled in System Settings › Internet Accounts. The first‑run sign‑in screen tells the user to turn Calendars off there.
- Setting: General › Show alerts (on). Turning it off removes all pending Kalendar alerts.

---

## 20. Auto‑update and releases (copied from Kapture)

Kapture's implementation is the reference: `~/src/kapture/Sources/Kapture/UpdaterController.swift`, `scripts/bundle.sh`, `.github/workflows/release.yml`, `docs/RELEASING.md`.

- **Framework:** Sparkle 2 via SwiftPM (`from: "2.6.0"`; Kapture resolves 2.9.6). Sparkle's standard update UI, no custom delegate.
- **`UpdaterController`:** wraps `SPUStandardUpdaterController`. It creates no updater when `SUPublicEDKey` is empty, so local builds never run an unverified updater; "Check for Updates…" then opens the releases page. **Reference `UpdaterController.shared` in `applicationDidFinishLaunching`.** `shared` is a lazy static; Kapture didn't reference it at launch, so its daily checks didn't start until the menu was first opened (fixed in Kapture's working tree on 2026‑10‑10, not yet committed).
- **UI:** "Check for Updates…" in the ⚙ menu (§4.4) and the status item's right‑click menu (§3), enabled from `updater.canCheckForUpdates`. Settings › General toggle sets `updater.automaticallyChecksForUpdates`, which writes the `SUEnableAutomaticChecks` user default and reschedules the running updater. The toggle is disabled in builds without an updater.
- **Info.plist** (generated by `bundle.sh`): `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks = true`, `SUScheduledCheckInterval = 86400`, `LSUIElement = true`, `LSMinimumSystemVersion = 14.0`, `CFBundleShortVersionString` from the tag, `CFBundleVersion` from the GitHub run number (it only increases, which Sparkle's version comparison needs).
- **Feed [decision]:** `SUFeedURL = https://github.com/darrinm/kalendar/releases/latest/download/appcast.xml`. No Worker or custom domain.
- **Release workflow** (`release.yml`, on a `v*` tag push, `macos-15` runner):
  1. Import the Developer ID certificate into a temporary keychain.
  2. `bundle.sh`: release build with an `@executable_path/../Frameworks` rpath, embed `Sparkle.framework`, write Info.plist, sign inside‑out (Sparkle's XPC services, `Updater.app` and `Autoupdate`, then the framework, then the app) with hardened runtime and timestamp. Only the app gets entitlements.
  3. Verify with `codesign --verify --deep --strict`.
  4. Build `Kalendar.dmg` with an `/Applications` symlink and sign the DMG.
  5. Notarize with `notarytool`, staple, and check with `spctl`.
  6. Sign the DMG with Sparkle's EdDSA `sign_update`. Use the tool under `bin/`, not `old_dsa_scripts/`.
  7. Write a one‑item `appcast.xml` and validate the XML.
  8. `gh release create` with `Kalendar.dmg` and `appcast.xml`.
- **Repo secrets:** `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (same values as Kapture), `SPARKLE_PRIVATE_KEY`, `SPARKLE_PUBLIC_KEY` (a new pair: `generate_keys --account kalendar`, then `generate_keys --account kalendar -x private.key` for CI). Never rotate the Sparkle key after the first release; installed copies only trust the key they shipped with.
- **Bundle ID:** `com.massena.kalendar`. Repo: `darrinm/kalendar`.
- **Entitlements:** none. Kalendar does not need Kapture's `keychain-access-groups` entitlement or provisioning profile, so `bundle.sh` signs without an entitlements file.
- Add Sparkle's MIT license to `THIRD-PARTY-NOTICES.md`.

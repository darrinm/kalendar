# Kalendar

Kalendar is a macOS menu bar calendar for Google Calendar and Google Tasks. It reads and writes
events through the Google Calendar API and tasks through the Google Tasks API. It does not use
EventKit or Apple Reminders. It requires macOS 14 or later.

## Install

Download `Kalendar.dmg` from the [latest release](https://github.com/darrinm/kalendar/releases/latest)
and drag Kalendar to Applications. Releases are signed with Developer ID and notarized. Kalendar
checks for updates daily through Sparkle; **Check for Updates…** is in the ⚙ menu and the menu
bar icon's right-click menu.

On first launch, sign in with one or more Google accounts. Google shows an "unverified app"
warning during sign-in. If Calendar.app also shows these Google accounts, turn Calendars off for
them in System Settings › Internet Accounts, or both apps will deliver alerts.

## Features

- **Menu bar icon** shows the date, an icon, the next event's title, or the next event with a
  countdown. Left-click or **⌃⌥Space** (configurable) opens the Mini Window.
- **Mini Window:** a natural-language input field, a month grid with a dot per event, and an
  agenda list sectioned by day. Tasks appear on their due day. Unanswered invitations have a gray
  title.
- **Natural-language entry:** type "Lunch with Kate tomorrow at noon" and the event form fills in
  as you type. Enter adds it. The form switches between event and task.
- **Detail popover:** edit title, time, calendar, repeat, alerts, guests, location, video link and
  notes. RSVP buttons show your current answer.
- **Join:** the current or next video meeting gets a Join button in the agenda, in its alert, and
  as a "Join <name>" item in the menu bar. Kalendar finds Google Meet, Zoom, Teams, Webex and
  FaceTime links.
- **Video conferencing:** new events can get a Google Meet or Zoom link automatically. Join
  opens Zoom meetings in the Zoom app, or in Zoom's web client if you choose.
- **Calendar window** (⌘O): Day, Week and Month views. Drag an event to move it, drag its bottom
  edge to change its end, and click or drag empty time to create an event.
- **Meet With** (⇧⌘M): add people and see their calendars next to yours for a week. Click or drag
  a free slot to invite them. Calendars not shared with you show busy times only.
- **Tasks view** (⌘R): every Google Tasks list from every account, sorted by due date or by the
  list's order, with subtasks indented.
- **Search** (⌘F) by title, location, invitees, or all fields, over the past and next year.
- **Alerts:** Kalendar delivers its own notifications for events' popup reminders, with Join and
  Snooze 5 Minutes actions.
- **Guest emails:** before changing or deleting an event you organize, Kalendar asks whether to
  email the guests, as Google Calendar does.
- **Multiple accounts**, offline reading from a local cache, and incremental sync.

The full behavior is specified in [docs/SPEC.md](docs/SPEC.md).

## What's new

### 0.1.19 — 2026-10-16
- Join opens Zoom meetings directly in the Zoom app, skipping the browser launcher page, when
  the Zoom app is installed and **Open Zoom meetings in browser** is off. The passcode is kept.
  (#29)

### 0.1.18 — 2026-10-15
- Before you change or delete an event you organize that has guests, Kalendar asks "Send update
  emails to guests?" with Send, Don't Send and Cancel. Changes that affect only you (your alerts,
  color, busy/free) do not ask. (#28)
- New setting **Open Zoom meetings in browser** (Settings › Accounts). Every Join button opens
  Zoom links in Zoom's web client, keeping the passcode. (#27)

### 0.1.17 — 2026-10-14
- **Calendar window** (⌘O) with Day, Week and Month views. Drag events to move them, drag the
  bottom edge to resize them, and click or drag empty time to create an event. (#26)

### 0.1.16 — 2026-10-14
- Meet With leaves a gap between back-to-back events. (#25)

### 0.1.15 — 2026-10-14
- Directory aliases (legacy domains, alternate names) are no longer suggested as contacts. (#24)

### 0.1.14 — 2026-10-14
- Meet With: drag across free time to set the meeting's length. (#23)

### 0.1.13 — 2026-10-14
- **Meet With** (⇧⌘M): see other people's calendars beside yours and invite them to a free slot.
- New events can get a Google Meet or Zoom link automatically (Settings › Accounts). (#22)

### 0.1.12 — 2026-10-14
- The menu bar Join item sits right of the calendar icon and names the meeting: "Join Kate". (#21)

### 0.1.11 — 2026-10-14
- A **Join** item appears in the menu bar for a video meeting in progress or starting within 15
  minutes. (#20)

### 0.1.10 — 2026-10-13
- Invitations you have not answered show a gray title. (#19)
- The release workflow retries stapling. (#18)

### 0.1.9 — 2026-10-12
- The RSVP buttons stay at the bottom of the detail popover. (#17)

### 0.1.8 — 2026-10-12
- The detail popover updates in place when you select another item. (#16)

### 0.1.7 — 2026-10-12
- The RSVP buttons show your current answer. (#15)

### 0.1.6 — 2026-10-12
- The Mini Window opens as a panel under the menu bar with no arrow, like the system's menu bar
  extras. (#14)

### 0.1.5 — 2026-10-12
- The Mini Window is 850 pt tall, giving the agenda list twice the room, and is capped to the
  screen height. (#13)

### 0.1.4 — 2026-10-12
- Settings uses toolbar tabs, and the window sizes to each tab. (#11)
- UI polish: locations without meeting links, accent dialog buttons, account avatars, recently
  completed tasks first. (#12)

### 0.1.3 — 2026-10-12
- Fixes for zero-length events, read-only calendars, deletes of events copied in two accounts,
  and ⌘T selection. New app icon. (#10)

### 0.1.2 — 2026-10-12
- Fixes Esc in form fields, dialogs closing the Mini Window, a stale end date, the Theme setting,
  and clicks on all-day events. (#9)
- Fixes task moves that left the old copy behind: Google requests no longer use the URL cache. (#8)

### 0.1.1 — 2026-10-12
- Task due dates stay on the same day when the time zone changes. The new-task form defaults to
  the account's default list. The Tasks view lists open tasks first. (#7)

### 0.1.0 — 2026-10-12
- First release: menu bar icon and Mini Window, Google sign-in for multiple accounts, sync and
  offline cache, natural-language entry, the detail popover, Google Tasks, alerts, search,
  Settings, and Sparkle updates.

## Build

Requires Xcode and macOS 14 or later.

```sh
swift build
swift test
scripts/bundle.sh          # builds dist/Kalendar.app
open dist/Kalendar.app
```

`bundle.sh` signs a local build with your Apple Development identity. A local build has no Sparkle public key, so its updater is off and **Check for Updates…** opens
the releases page.

## Release

Push a `vX.Y.Z` tag. `.github/workflows/release.yml` builds, signs, notarizes, and publishes the
DMG and the update feed. See [docs/RELEASING.md](docs/RELEASING.md).

## Third-party notices

Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

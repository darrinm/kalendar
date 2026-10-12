# Milestone 5 — Google Tasks and alerts

Spec: `docs/SPEC.md` §5.1 (task form), §7.3, §10, §18.2 (Tasks), §19. Earlier milestones are in git history.

## Tasks
- [x] Cache v5: task lists and tasks; per-list sync time
- [x] Tasks API: tasklists.list, tasks.list (`updatedMin`, `showCompleted`, `showHidden`, `showDeleted`), insert, patch, delete, move; synced with the calendars
- [x] Task writes through the existing write queue (optimistic, offline, rejected → refetch)
- [x] Agenda: tasks on their due day with the all-day items (circle checkbox), overdue incomplete tasks in today with the due date in `wait`, ✓ under grid days with tasks
- [x] Tasks view (⌘R, ≡ › Tasks): all lists merged, Due Date / My Order, subtasks indented, complete / uncomplete, completed shown
- [x] Task form: event/task toggle, `todo`/`task`/`reminder`/`√` prefix, due (date only, "Google Tasks stores dates only" when a time was typed), list picker, notes, Add Task
- [x] Task context menu (§7.3): Complete/Uncomplete, Move to List ›, Duplicate as Event, Delete; event menu's Duplicate as Task
- [x] Tests

## Alerts (§19)
- [x] `AlertScheduler`: effective popup reminders for cached events in the next 24 h (calendar defaults when `useDefault`), not declined, ≤ 64 pending, identifier `<calendarId>|<eventId>|<minutes>`; reschedule after sync, at midnight, on wake
- [x] Content: title, "3:00 – 3:50 PM · Location"; actions Join (with a video link) and Snooze 5 Minutes; click opens the event's detail popover
- [x] Permission after sign-in; Settings › General "Show alerts" removes pending alerts; "Alerts are off in System Settings" with a button
- [x] On wake: delivered alerts for ended events removed
- [x] Tests for alert selection and identifiers
- [x] Verify: build, tests, app checks

## Review
- Tasks: cache v5, sync per list with `updatedMin` (a Tasks API failure is logged and does not fail calendar sync), writes through the event queue (absolute Tasks URLs; `local-` placeholders retargeted when the insert lands). Live: 4 lists, 277 tasks.
- Agenda task rows, overdue in today in `wait`, ✓ under grid days; Tasks view (⌘R / ⌘3) with Due Date / My Order, Show Completed, subtasks indented; task detail popover saves on close; task form with ▣ | ✓ and "Google Tasks stores dates only".
- Alerts: `AlertPlanner` (core, tested) + `AlertScheduler`. Live: permission authorized, 5 alerts planned and 5 pending.
- Tests: 86 passing.
- Not checked by hand (UI driving would take focus): the task rows, Tasks view, task form, notification actions.

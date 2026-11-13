// Event alerts (§19) through UNUserNotificationCenter: the next 24 hours of popup reminders,
// rescheduled after the cache changes, at midnight and on wake. Also one notification per new
// invitation, with Accept / Maybe / Decline (§6.2).
import AppKit
import KalendarCore
import Observation
import UserNotifications

@MainActor
@Observable
final class AlertScheduler: NSObject, UNUserNotificationCenterDelegate {
    /// False when the user turned Kalendar's notifications off in System Settings.
    private(set) var allowedBySystem = true

    @ObservationIgnored private let cache: CalendarCache
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    /// Clicking an alert opens that event's detail popover.
    @ObservationIgnored var openEvent: (EventInstance) -> Void = { _ in }
    /// Accept / Maybe / Decline on an invitation notification: the event and the response.
    @ObservationIgnored var respond: (EventInstance, String) -> Void = { _, _ in }
    /// The number of invitations awaiting a reply, after each cache change: the menu bar badge.
    @ObservationIgnored var invitationCountChanged: (Int) -> Void = { _ in }
    /// The pending invitations' notification identifiers at the last update.
    @ObservationIgnored private var pendingInvitationIDs: Set<String>?
    @ObservationIgnored private var pendingReschedule: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let category = "event"
    static let joinCategory = "eventWithJoin"
    static let invitationCategory = "invitation"
    static let snoozePrefix = "snooze|"
    static let invitationPrefix = "invitation|"
    private static let joinAction = "join"
    private static let snoozeAction = "snooze"
    /// Invitation actions: the response each writes, which is also its identifier, and its title.
    private static let responseActions = [("accepted", "Accept"), ("tentative", "Maybe"), ("declined", "Decline")]
    /// `InvitationNotices.Plan.seen`. "v2": keys with the time they were last pending.
    private static let seenInvitationsKey = "seenInvitations.v2"

    static var enabled: Bool { Preferences.shared.showAlerts }

    init(cache: CalendarCache) {
        self.cache = cache
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 5 Minutes")
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.joinCategory, actions: [join, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.invitationCategory, actions: Self.responseActions.map { id, title in
                UNNotificationAction(identifier: id, title: title, options: id == "declined" ? [.destructive] : [])
            }, intentIdentifiers: []),
        ])
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReschedule() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeEndedAlerts()
                self?.setNeedsReschedule()
            }
        })
    }

    /// Asks for permission once an account is signed in; macOS asks the user only the first time.
    func requestPermission() {
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
            setNeedsReschedule()
        }
    }

    func refreshPermission() async {
        let status = await center.notificationSettings().authorizationStatus
        allowedBySystem = status != .denied
        Log.shell.info("notification permission: \(status.rawValue)")
    }

    /// Coalesces the bursts of cache changes a sync makes into one reschedule and one invitation
    /// update. A reschedule waits for the one already running, so two never interleave their removals
    /// and additions.
    func setNeedsReschedule() {
        let previous = pendingReschedule
        previous?.cancel()
        pendingReschedule = Task {
            await previous?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            updateInvitations()
            await reschedule()
        }
    }

    private func reschedule() async {
        let pending = await center.pendingNotificationRequests()
        // snoozed alerts kept below count against the system's limit of pending requests
        let snoozed = pending.filter { $0.identifier.hasPrefix(Self.snoozePrefix) }.count
        let now = Date()
        let planned = Self.enabled
            ? AlertPlanner.plan(events: (try? AlertPlanner.candidates(in: cache, now: now)) ?? [],
                                calendars: Dictionary(uniqueKeysWithValues: ((try? cache.calendars()) ?? []).map { ($0.key, $0) }),
                                now: now, limit: AlertPlanner.limit - snoozed)
            : []
        let wanted = Set(planned.map(\.identifier))
        // snoozed alerts stay until they fire, unless alerts were turned off
        let stale = pending.map(\.identifier).filter {
            !wanted.contains($0) && (!Self.enabled || !$0.hasPrefix(Self.snoozePrefix))
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        // an add with an existing identifier replaces that request
        for alert in planned {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alert.fireDate)
            let request = UNNotificationRequest(identifier: alert.identifier, content: Self.content(for: alert.event),
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do { try await center.add(request) } catch {
                Log.shell.error("alert not scheduled: \(error.localizedDescription)")
            }
        }
        Log.shell.info("alerts: \(planned.count) scheduled, \(stale.count) removed")
    }

    /// Title: the event's title. Body: "3:00 – 3:50 PM · Zoom" (§19).
    static func content(for event: EventInstance) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = event.summary
        let time = event.allDay ? "All day" : Formatting.timeRange(event.start, event.end)
        // the place without its video link; a location that was only the link names the service
        var place = event.displayLocation
        if place == nil, event.location?.isEmpty == false {
            place = event.conferenceURL.map(ConferenceDetector.serviceName(for:))
        }
        c.body = [time, place].compactMap { $0 }.joined(separator: " · ")
        c.sound = .default
        c.categoryIdentifier = event.conferenceURL == nil ? category : joinCategory
        c.userInfo = userInfo(for: event).merging(["url": event.conferenceURL ?? ""]) { $1 }
        return c
    }

    /// What `didReceive` and `removeEndedAlerts` read back from a notification.
    private static func userInfo(for event: EventInstance) -> [String: Any] {
        ["account": event.account, "calendarId": event.calendarId, "eventId": event.id,
         "end": event.end.timeIntervalSince1970]
    }

    // MARK: Invitations

    /// After the cache changes: reports the count for the badge, posts a notification for each
    /// invitation not seen before, and removes the notifications of invitations no longer pending.
    private func updateInvitations() {
        let pending = (try? cache.pendingInvitations(now: Date())) ?? []
        invitationCountChanged(pending.count)
        let defaults = UserDefaults.standard
        let stored = defaults.dictionary(forKey: Self.seenInvitationsKey) as? [String: [String: Date]] ?? [:]
        let plan = InvitationNotices.plan(pending: pending, seen: stored,
                                          synced: (try? cache.invitationAccountsSynced()) ?? [], now: Date())
        if plan.seen != stored { defaults.set(plan.seen, forKey: Self.seenInvitationsKey) }
        let ids = Set(pending.map(Self.invitationIdentifier))
        // a notification goes stale only when its invitation leaves the pending set
        if pendingInvitationIDs.map({ !$0.isSubset(of: ids) }) ?? true { removeAnsweredInvitations(pending: ids) }
        pendingInvitationIDs = ids
        guard Preferences.shared.notifyInvitations else { return }
        for event in plan.announce {
            let request = UNNotificationRequest(identifier: Self.invitationIdentifier(event),
                                                content: Self.invitationContent(for: event), trigger: nil)
            center.add(request) { error in
                if let error { Log.shell.error("invitation notification not posted: \(error.localizedDescription)") }
            }
        }
        if !plan.announce.isEmpty { Log.shell.info("invitations: \(plan.announce.count) announced") }
    }

    private static func invitationIdentifier(_ event: EventInstance) -> String { invitationPrefix + event.seriesKey }

    /// Removes the delivered notifications of invitations no longer pending: answered, cancelled,
    /// ended, or on a hidden calendar or a signed-out account. `pending` holds notification identifiers.
    private func removeAnsweredInvitations(pending: Set<String>) {
        Task {
            let stale = await center.deliveredNotifications().map(\.request.identifier)
                .filter { $0.hasPrefix(Self.invitationPrefix) && !pending.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// Title: the event's title. Body: "Invitation from kate@example.com" and
    /// "Monday, November 16 at 10:30 AM".
    static func invitationContent(for event: EventInstance) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = event.summary
        let from = event.organizer.map { "Invitation from \($0.displayName ?? $0.email)" } ?? "Invitation"
        let day = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        c.body = from + "\n" + event.start.formatted(event.allDay ? day : day.hour().minute())
        c.sound = .default
        c.categoryIdentifier = invitationCategory
        c.userInfo = userInfo(for: event)
        return c
    }

    /// On wake (§19): alerts delivered while the Mac slept stay unless their event has ended.
    private func removeEndedAlerts() {
        Task {
            let now = Date().timeIntervalSince1970
            let ended = await center.deliveredNotifications().filter {
                ($0.request.content.userInfo["end"] as? Double).map { $0 <= now } ?? false
            }
            center.removeDeliveredNotifications(withIdentifiers: ended.map(\.request.identifier))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let info = request.content.userInfo
        let action = response.actionIdentifier
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let account = info["account"] as? String, calendarId = info["calendarId"] as? String
        let eventId = info["eventId"] as? String
        let content = request.content
        let identifier = request.identifier
        await MainActor.run {
            func event() -> EventInstance? {
                guard let account, let calendarId, let eventId else { return nil }
                return try? cache.event(account: account, calendarId: calendarId, id: eventId)
            }
            switch action {
            case Self.joinAction:
                if let url { Meeting.join(url) }
            case Self.snoozeAction:
                let base = identifier.hasPrefix(Self.snoozePrefix) ? identifier : Self.snoozePrefix + identifier
                center.add(UNNotificationRequest(identifier: base, content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)))
            case let answer where Self.responseActions.contains { $0.0 == answer }:
                if let event = event() { respond(event, answer) }
            case UNNotificationDefaultActionIdentifier:
                if let event = event() { openEvent(event) }
            default:
                break
            }
        }
    }
}

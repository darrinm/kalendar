// Event alerts (§19) through UNUserNotificationCenter: the next 24 hours of popup reminders,
// rescheduled after the cache changes, at midnight and on wake.
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
    @ObservationIgnored private var pendingReschedule: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let category = "event"
    static let joinCategory = "eventWithJoin"
    static let snoozePrefix = "snooze|"
    private static let joinAction = "join"
    private static let snoozeAction = "snooze"

    static var enabled: Bool { UserDefaults.standard.object(forKey: "showAlerts") as? Bool ?? true }

    init(cache: CalendarCache) {
        self.cache = cache
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 5 Minutes")
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.joinCategory, actions: [join, snooze], intentIdentifiers: []),
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

    /// Coalesces the bursts of cache changes a sync makes into one reschedule. A reschedule waits for
    /// the one already running, so two never interleave their removals and additions.
    func setNeedsReschedule() {
        let previous = pendingReschedule
        previous?.cancel()
        pendingReschedule = Task {
            await previous?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
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
        let existing = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        for alert in planned {
            let content = Self.content(for: alert.event)
            // an unchanged request is left alone; re-adding one would reset nothing but costs a call
            if let old = existing[alert.identifier], old.content.title == content.title, old.content.body == content.body,
               old.content.categoryIdentifier == content.categoryIdentifier,
               old.content.userInfo as NSDictionary == content.userInfo as NSDictionary,
               (old.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == alert.fireDate {
                continue
            }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alert.fireDate)
            let request = UNNotificationRequest(identifier: alert.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do { try await center.add(request) } catch {
                Log.shell.error("alert not scheduled: \(error.localizedDescription)")
            }
        }
        let count = await center.pendingNotificationRequests().count
        Log.shell.info("alerts: \(planned.count) planned, \(stale.count) removed, \(count) pending")
    }

    /// Title: the event's title. Body: "3:00 – 3:50 PM · Zoom" (§19).
    static func content(for event: EventInstance) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = event.summary
        let time = event.allDay ? "All day" : Formatting.timeRange(event.start, event.end)
        c.body = [time, event.location].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        c.sound = .default
        c.categoryIdentifier = event.conferenceURL == nil ? category : joinCategory
        c.userInfo = ["account": event.account, "calendarId": event.calendarId, "eventId": event.id,
                      "end": event.end.timeIntervalSince1970, "url": event.conferenceURL ?? ""]
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
        let ids = (info["account"] as? String, info["calendarId"] as? String, info["eventId"] as? String)
        let content = request.content
        let identifier = request.identifier
        await MainActor.run {
            switch action {
            case Self.joinAction:
                if let url { NSWorkspace.shared.open(url) }
            case Self.snoozeAction:
                let base = identifier.hasPrefix(Self.snoozePrefix) ? identifier : Self.snoozePrefix + identifier
                center.add(UNNotificationRequest(identifier: base, content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)))
            case UNNotificationDefaultActionIdentifier:
                if let account = ids.0, let calendarId = ids.1, let eventId = ids.2,
                   let event = try? cache.event(account: account, calendarId: calendarId, id: eventId) {
                    openEvent(event)
                }
            default:
                break
            }
        }
    }
}

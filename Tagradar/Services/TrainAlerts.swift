import CoreLocation
import Foundation
import os
import UserNotifications

/// Local notifications for saved trains: delay changes, cancellations, track changes, arrival and a
/// departure reminder. Everything is judged against the user's trip segment via `TrainSnapshot`.
@MainActor
@Observable
final class TrainAlerts {
    static let categoryID = "train"
    static let showOnMapAction = "showOnMap"
    static let muteAction = "mute"

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var mutedIDs: Set<String>
    private var states: [String: TrainAlertState]
    /// Trains whose alerts the push server has been sending with their Live Activity. Kept across
    /// launches: while the app was suspended the server told the user things this state never saw.
    private var remoteIDs: Set<String>
    private var authorizationLoaded = false

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "se.tagradar.app", category: "Alerts")
    private static let statesKey = "alerts.states"
    private static let mutedKey = "alerts.muted"
    private static let remoteKey = "alerts.remote"
    private static let reminderLead: TimeInterval = 30 * 60

    init() {
        let defaults = SharedStorage.defaults
        if let data = defaults.data(forKey: Self.statesKey),
           let decoded = try? JSONDecoder().decode([String: TrainAlertState].self, from: data) {
            states = decoded
        } else {
            states = [:]
        }
        mutedIDs = Set(defaults.stringArray(forKey: Self.mutedKey) ?? [])
        remoteIDs = Set(defaults.stringArray(forKey: Self.remoteKey) ?? [])
        registerCategories()
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        authorizationLoaded = true
    }

    /// `isAuthorized`, reading the setting first if this launch has not yet (a background launch).
    func loadedAuthorization() async -> Bool {
        if !authorizationLoaded {
            await refreshAuthorization()
        }
        return isAuthorized
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorization()
            return false
        }
    }

    private func registerCategories() {
        let show = UNNotificationAction(identifier: Self.showOnMapAction, title: String(localized: "Show on map"), options: [.foreground])
        let mute = UNNotificationAction(identifier: Self.muteAction, title: String(localized: "Stop alerts for this train"), options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [show, mute], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    // MARK: Evaluation

    /// Compares a refreshed snapshot with what the user was last told and posts what changed.
    /// `position` is only asked for when a notification is actually going out.
    ///
    /// `remote` means the push server sends this train's alerts: the state only advances. The first
    /// pass after the server stops (the activity ended or was dismissed) is silent too, because the
    /// server may have told the user things while the app was suspended; it re-baselines the state.
    func process(
        _ snapshot: TrainSnapshot, names: StationNames, remote: Bool = false, position: () async -> CLLocationCoordinate2D?
    ) async {
        let (alerts, state) = TrainAlertEngine.evaluate(previous: states[snapshot.id], current: snapshot)
        states[snapshot.id] = state
        // Silent the first pass after the server stopped as well. That can drop an alert the app sees
        // first right after the user unfollows, which beats repeating ones the server already sent.
        let silent: Bool
        if remote {
            remoteIDs.insert(snapshot.id)
            silent = true
        } else {
            silent = remoteIDs.remove(snapshot.id) != nil
        }
        persist()
        guard !silent, !alerts.isEmpty, isAuthorized, !mutedIDs.contains(snapshot.id) else { return }
        var imageURL: URL?
        if let coordinate = await position() {
            imageURL = await NotificationMapSnapshot.render(coordinate: coordinate)
        }
        for alert in alerts {
            await post(alert, for: snapshot, names: names, imageURL: imageURL)
        }
    }

    /// Reschedules the "departs soon" reminder so it always reflects the latest time and track.
    func scheduleReminder(for snapshot: TrainSnapshot, names: StationNames) {
        let id = "reminder.\(snapshot.id)"
        guard isAuthorized, !mutedIDs.contains(snapshot.id), snapshot.status == .scheduled || snapshot.status == nil,
              let departure = snapshot.bestDeparture else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let fireDate = departure.addingTimeInterval(-Self.reminderLead)
        guard fireDate.timeIntervalSinceNow > 60 else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(snapshot.displayName) departs soon")
        var body = String(localized: "Leaves \(names.name(snapshot.originSignature)) at \(Format.clock(departure))")
        if let track = snapshot.originTrack {
            body += " · " + String(localized: "Track \(track)")
        }
        if let delay = snapshot.delay, abs(delay) >= 60, let text = Format.delay(delay) {
            body += " (\(text))"
        }
        content.body = body
        decorate(content, for: snapshot)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Drops state and pending reminders for trains that are no longer saved.
    func prune(keeping ids: Set<String>) {
        let stale = Set(states.keys).subtracting(ids)
        guard !stale.isEmpty else { return }
        for id in stale {
            states[id] = nil
        }
        mutedIDs.subtract(stale)
        remoteIDs.subtract(stale)
        persist()
        center.removePendingNotificationRequests(withIdentifiers: stale.map { "reminder.\($0)" })
    }

    /// The app takes this train's alerts back with an up-to-date state, so the next pass speaks.
    func takeOver(_ id: String) {
        remoteIDs.remove(id)
        persist()
    }

    func forget(_ id: String) {
        states[id] = nil
        mutedIDs.remove(id)
        remoteIDs.remove(id)
        persist()
        center.removePendingNotificationRequests(withIdentifiers: ["reminder.\(id)"])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func mute(_ id: String) {
        mutedIDs.insert(id)
        persist()
        center.removePendingNotificationRequests(withIdentifiers: ["reminder.\(id)"])
    }

    func unmute(_ id: String) {
        mutedIDs.remove(id)
        persist()
    }

    // MARK: Posting

    private func post(_ alert: TrainAlertKind, for snapshot: TrainSnapshot, names: StationNames, imageURL: URL?) async {
        let content = UNMutableNotificationContent()
        content.title = snapshot.displayName
        content.subtitle = "\(names.name(snapshot.originSignature)) → \(names.name(snapshot.destinationSignature))"
        content.body = Self.body(for: alert, snapshot: snapshot, names: names)
        decorate(content, for: snapshot)
        if let imageURL, let attachment = try? UNNotificationAttachment(identifier: "map", url: imageURL) {
            content.attachments = [attachment]
        }
        if case .canceled = alert {
            content.sound = .defaultCritical
        }
        let request = UNNotificationRequest(identifier: "\(snapshot.id).\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            logger.error("Could not post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decorate(_ content: UNMutableNotificationContent, for snapshot: TrainSnapshot) {
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = snapshot.id
        content.userInfo = ["url": snapshot.deepLink.absoluteString, "trainID": snapshot.id]
        content.interruptionLevel = .active
    }

    static func body(for alert: TrainAlertKind, snapshot: TrainSnapshot, names: StationNames) -> String {
        switch alert {
        case let .delay(minutes, _):
            var text = String(localized: "Now \(minutes) min late.")
            if snapshot.status == .scheduled, let departure = snapshot.bestDeparture {
                text += " " +
                    String(localized: "New departure \(Format.clock(departure)) from \(names.shortName(snapshot.originSignature)).")
            } else if let next = snapshot.nextStopSignature, let time = snapshot.nextStopExpected ?? snapshot.nextStopPlanned {
                text += " " + String(localized: "Next \(names.shortName(next)) \(Format.clock(time)).")
            } else if let arrival = snapshot.bestArrival {
                text += " " + String(localized: "Arrives \(Format.clock(arrival)).")
            }
            return text
        case .backOnTime:
            if let arrival = snapshot.bestArrival {
                return String(
                    localized: "Back on time. Arrives \(names.shortName(snapshot.destinationSignature)) \(Format.clock(arrival))."
                )
            }
            return String(localized: "Back on time.")
        case .canceled:
            return String(localized: "The train is canceled. Check the operator's app for replacement traffic.")
        case let .trackChanged(from, to):
            return String(localized: "Track changed from \(from) to \(to) at \(names.shortName(snapshot.originSignature)).")
        case let .arrived(delayMinutes):
            let when = Format.clock(snapshot.bestArrival)
            if let delayMinutes, delayMinutes >= 1 {
                return String(localized: "Arrived \(names.shortName(snapshot.destinationSignature)) \(when), \(delayMinutes) min late.")
            }
            return String(localized: "Arrived \(names.shortName(snapshot.destinationSignature)) \(when), on time.")
        }
    }

    private func persist() {
        let defaults = SharedStorage.defaults
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Self.statesKey)
        }
        defaults.set(Array(mutedIDs).sorted(), forKey: Self.mutedKey)
        defaults.set(Array(remoteIDs).sorted(), forKey: Self.remoteKey)
    }
}

extension TrainSnapshot {
    /// "SJ Snabbtåg 537" or "Train 537".
    var displayName: String {
        "\(productName ?? String(localized: "Train")) \(ident)"
    }
}

/// Receives notification taps. Lives outside the main actor because UNUserNotificationCenter calls
/// it on its own queue; it forwards to the app through Sendable closures.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onOpen: @Sendable (URL) -> Void
    private let onMute: @Sendable (String) async -> Void

    init(onOpen: @escaping @Sendable (URL) -> Void, onMute: @escaping @Sendable (String) async -> Void) {
        self.onOpen = onOpen
        self.onMute = onMute
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case TrainAlerts.muteAction:
            if let id = info["trainID"] as? String {
                // Awaited: the action does not open the app, and iOS may suspend it once this returns.
                await onMute(id)
            }
        default:
            if let raw = info["url"] as? String, let url = URL(string: raw) {
                onOpen(url)
            }
        }
    }
}

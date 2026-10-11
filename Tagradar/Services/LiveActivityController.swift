import ActivityKit
import Foundation
import os

/// Starts, updates and ends the Live Activity for followed trains. While the app runs it updates
/// them itself; when a push server is configured it also hands each activity's push token to
/// `ActivityPushRegistrar`, and the server keeps the activity current from then on.
@MainActor
@Observable
final class LiveActivityController {
    typealias Content = ActivityContent<TrainActivityAttributes.ContentState>

    /// What the push server needs to know about a followed train besides its token.
    struct PushPreferences {
        var segment: TripSegment?
        /// The user wants delay, track and arrival alerts for this train.
        var alerts: Bool
    }

    private(set) var followedIDs: Set<String> = []
    /// Set by `AppDependencies`: reads the saved train's stops and the alert settings.
    @ObservationIgnored var pushPreferences: (String) async -> PushPreferences = { _ in PushPreferences(segment: nil, alerts: false) }

    private let registrar: ActivityPushRegistrar
    private let logger = Logger(subsystem: "se.tagradar.app", category: "LiveActivity")
    /// The activity and its latest push token per followed train.
    @ObservationIgnored private var activityIDs: [String: String] = [:]
    @ObservationIgnored private var tokens: [String: Data] = [:]
    @ObservationIgnored private var observers: [String: Task<Void, Never>] = [:]
    /// How long a state stays fresh before the system dims it, when there is no cadence to go by.
    private static let staleAfter: TimeInterval = 20 * 60

    init(registrar: ActivityPushRegistrar = ActivityPushRegistrar()) {
        self.registrar = registrar
        restore()
    }

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Picks up activities that survived an app relaunch.
    func restore() {
        let running = Activity<TrainActivityAttributes>.activities.filter(\.isRunning)
            .map { (trainID: $0.attributes.trainID, activityID: $0.id) }
        followedIDs = Set(running.map(\.trainID))
        registrar.forgetAllExcept(Set(running.map(\.activityID)))
        for activity in running {
            activityIDs[activity.trainID] = activity.activityID
            observe(activityID: activity.activityID, trainID: activity.trainID)
        }
    }

    func isFollowing(_ id: String) -> Bool {
        followedIDs.contains(id)
    }

    /// Whether the push server posts this train's alerts, so the app should not post them as well.
    func serverSendsAlerts(for id: String) -> Bool {
        registrar.sendsAlerts(for: id)
    }

    func follow(_ snapshot: TrainSnapshot, names: StationNames) throws {
        let content = Self.content(for: snapshot, names: names)
        if followedIDs.contains(snapshot.id) {
            Task { await Self.update(id: snapshot.id, content: content) }
            return
        }
        let attributes = TrainActivityAttributes(snapshot: snapshot, names: names)
        let activity: Activity<TrainActivityAttributes>
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: registrar.isEnabled ? .token : nil)
        } catch where registrar.isEnabled {
            // No push entitlement (a free developer team, say): follow without the server.
            logger.error("Push-updated activity refused, following locally: \(error.localizedDescription, privacy: .public)")
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        }
        followedIDs.insert(snapshot.id)
        activityIDs[snapshot.id] = activity.id
        observe(activityID: activity.id, trainID: snapshot.id)
        logger.info("Following train \(snapshot.id, privacy: .public)")
    }

    /// Pushes a refreshed state; ends the activity a while after the train (or the user) has arrived.
    /// Returns true when this call ended a still-running activity: the server then never sends that
    /// arrival or cancellation, so the app has to.
    @discardableResult
    func update(_ snapshot: TrainSnapshot, names: StationNames) async -> Bool {
        let content = Self.content(for: snapshot, names: names)
        switch content.state.status {
        case .arrived, .canceled:
            let endedHere = await Self.end(id: snapshot.id, content: content, dismissal: .after(Self.dismissal(for: content.state)))
            await stopped(snapshot.id)
            return endedHere
        case .scheduled, .enRoute:
            let stillRunning = await Self.update(id: snapshot.id, content: content)
            if stillRunning {
                // Picks up a changed segment or alert setting; a no-op when nothing changed.
                await registerForPushes(snapshot.id)
            } else {
                await stopped(snapshot.id)
            }
            return false
        }
    }

    func unfollow(_ id: String) async {
        _ = await Self.end(id: id, content: nil, dismissal: .immediate)
        await stopped(id)
    }

    func unfollowAll() async {
        for id in followedIDs {
            await unfollow(id)
        }
    }

    /// Forgets a train whose activity ended, here or on the Lock Screen, and tells the server.
    private func stopped(_ trainID: String) async {
        followedIDs.remove(trainID)
        tokens[trainID] = nil
        guard let activityID = activityIDs.removeValue(forKey: trainID) else { return }
        observers.removeValue(forKey: activityID)?.cancel()
        await registrar.unregister(activityID: activityID)
    }

    // MARK: Push tokens

    private enum ActivityEvent: Sendable {
        case token(Data)
        case ended
    }

    private func observe(activityID: String, trainID: String) {
        guard registrar.isEnabled, observers[activityID] == nil else { return }
        // The controller lives as long as the app, so the strong capture is harmless; `stopped` cancels the task.
        observers[activityID] = Task {
            await Self.watch(activityID: activityID) { event in
                await self.handle(event, trainID: trainID)
            }
        }
    }

    private func handle(_ event: ActivityEvent, trainID: String) async {
        switch event {
        case let .token(token):
            tokens[trainID] = token
            await registerForPushes(trainID)
        case .ended:
            await stopped(trainID)
        }
    }

    /// Re-sends a followed train's registration after its alert choice changed outside a refresh.
    func refreshPushRegistration(_ trainID: String) async {
        await registerForPushes(trainID)
    }

    private func registerForPushes(_ trainID: String) async {
        guard let activityID = activityIDs[trainID], tokens[trainID] != nil else { return }
        let preferences = await pushPreferences(trainID)
        // The activity may have ended, or its token rotated, while the preferences loaded; don't
        // register it after its DELETE or overwrite the newer token.
        guard activityIDs[trainID] == activityID, let token = tokens[trainID] else { return }
        await registrar.register(
            activityID: activityID, token: token, trainID: trainID, segment: preferences.segment, alerts: preferences.alerts
        )
    }

    // MARK: Cadence

    /// How long until a train in this state is worth looking at again; nil once it is over. The push
    /// server polls on the same cadence (server/src/contentState.ts).
    nonisolated static func refreshInterval(for state: TrainActivityAttributes.ContentState, now: Date = .now) -> TimeInterval? {
        switch state.status {
        case .arrived, .canceled:
            return nil
        case .enRoute:
            return 60
        case .scheduled:
            let departure = state.expectedDeparture ?? .distantFuture
            let untilDeparture = departure.timeIntervalSince(now)
            if untilDeparture < 45 * 60 {
                return 3 * 60
            }
            return min(max(untilDeparture / 4, 10 * 60), 60 * 60)
        }
    }

    /// When a finished activity leaves the Lock Screen: five minutes after the trip's arrival, or at
    /// once when that has passed already; a cancellation stays a while so it is seen. The push
    /// server ends activities the same way (server/src/tick.ts).
    nonisolated static func dismissal(for state: TrainActivityAttributes.ContentState, now: Date = .now) -> Date {
        switch state.status {
        case .arrived:
            max(now, (state.expectedArrival ?? now).addingTimeInterval(5 * 60))
        case .canceled, .scheduled, .enRoute:
            now.addingTimeInterval(15 * 60)
        }
    }

    /// Content is marked stale a few refresh intervals after it was produced, so the activity can
    /// show "Updated HH:MM" when updates stop arriving.
    private static func content(for snapshot: TrainSnapshot, names: StationNames) -> Content {
        let state = TrainActivityAttributes.ContentState(snapshot: snapshot, names: names)
        let interval = refreshInterval(for: state) ?? staleAfter
        return ActivityContent(state: state, staleDate: .now.addingTimeInterval(max(interval * 3, 5 * 60)))
    }

    // `Activity` is not Sendable, so it is looked up and used within one nonisolated context.

    private nonisolated static func activity(_ activityID: String) -> Activity<TrainActivityAttributes>? {
        Activity<TrainActivityAttributes>.activities.first { $0.id == activityID }
    }

    /// Forwards the activity's push tokens (the current one first; they rotate) until it ends.
    private nonisolated static func watch(activityID: String, onEvent: @escaping @Sendable (ActivityEvent) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                guard let activity = activity(activityID) else { return }
                if let token = activity.pushToken {
                    await onEvent(.token(token))
                }
                for await token in activity.pushTokenUpdates {
                    await onEvent(.token(token))
                }
            }
            group.addTask {
                guard let activity = activity(activityID) else { return }
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    await onEvent(.ended)
                    return
                }
            }
        }
    }

    @discardableResult
    private nonisolated static func update(id: String, content: Content) async -> Bool {
        guard let activity = Activity<TrainActivityAttributes>.activities.first(where: { $0.attributes.trainID == id && $0.isRunning })
        else {
            return false
        }
        await activity.update(content)
        return true
    }

    /// Ends the train's activity; true when it was still running (rather than already ended by the server).
    private nonisolated static func end(id: String, content: Content?, dismissal: ActivityUIDismissalPolicy) async -> Bool {
        // A train followed again after iOS ended its first activity has two; the running one counts.
        let activities = Activity<TrainActivityAttributes>.activities.filter { $0.attributes.trainID == id }
        guard let activity = activities.first(where: \.isRunning) ?? activities.first else {
            return false
        }
        let wasRunning = activity.isRunning
        await activity.end(content, dismissalPolicy: dismissal)
        return wasRunning
    }
}

private extension Activity {
    /// Still on screen and updatable: not ended (it lingers in `activities` until dismissed) or dismissed.
    var isRunning: Bool {
        activityState == .active || activityState == .stale
    }
}

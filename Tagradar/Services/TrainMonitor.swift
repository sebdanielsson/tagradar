import BackgroundTasks
import CoreLocation
import Foundation
import os
import SwiftData
import WidgetKit

/// Periodically refreshes saved and followed trains and fans the result out to Live Activities,
/// notifications and widgets. Runs a 30-second loop while the app is open and a
/// `BGAppRefreshTask` when iOS grants background time (typically every 15 minutes or more).
@MainActor
@Observable
final class TrainMonitor {
    /// The identifier registered in Info.plist (`BGTaskSchedulerPermittedIdentifiers`).
    nonisolated static let backgroundTaskID: String =
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?.first
            ?? "se.tagradar.app.refresh"

    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    private let trains: TrainService
    private let journeys: JourneyStore
    private let stations: StationDirectory
    private let activities: LiveActivityController
    private let alerts: TrainAlerts
    private let settings: AppSettings
    private let modelContainer: ModelContainer
    private var loop: Task<Void, Never>?
    private let logger = Logger(subsystem: "se.tagradar.app", category: "Monitor")
    private static let foregroundInterval: Duration = .seconds(30)

    init(
        trains: TrainService, journeys: JourneyStore, stations: StationDirectory,
        activities: LiveActivityController, alerts: TrainAlerts, settings: AppSettings, modelContainer: ModelContainer
    ) {
        self.trains = trains
        self.journeys = journeys
        self.stations = stations
        self.activities = activities
        self.alerts = alerts
        self.settings = settings
        self.modelContainer = modelContainer
    }

    // MARK: Foreground

    func startForeground() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: Self.foregroundInterval)
            }
        }
    }

    func stopForeground() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Background

    /// Must run before the app finishes launching.
    nonisolated static func register(_ monitor: TrainMonitor) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let boxed = UncheckedSendable(refresh)
            Task { @MainActor in await monitor.handle(boxed.value) }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        // iOS decides the actual time; asking sooner while a train is followed does no harm.
        request.earliestBeginDate = .now.addingTimeInterval(activities.followedIDs.isEmpty ? 15 * 60 : 5 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Could not schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) async {
        scheduleBackgroundRefresh()
        let work = Task { await refreshAll() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
    }

    // MARK: Refresh

    /// One pass over every saved and followed train.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let names = stations.isLoaded ? StationNames(stations: stations.stationsBySignature) : StationNames.loadCached()
        let context = modelContainer.mainContext
        let favorites = (try? context.fetch(FetchDescriptor<FavoriteTrain>(sortBy: [SortDescriptor(\.departureDate)]))) ?? []
        var byID: [String: FavoriteTrain] = [:]
        var snapshots: [TrainSnapshot] = []
        for fav in favorites {
            let snapshot = TrainSnapshot(favorite: fav)
            byID[fav.id] = fav
            if !snapshot.isOver || activities.isFollowing(fav.id) {
                snapshots.append(snapshot)
            }
        }
        for id in activities.followedIDs where byID[id] == nil {
            guard let key = TrainKey(id: id) else { continue }
            var journey = journeys.cached(key)
            if journey == nil {
                journey = try? await journeys.load(key)
            }
            if let journey {
                snapshots.append(TrainSnapshot(journey: journey))
            }
        }
        guard !snapshots.isEmpty else {
            alerts.prune(keeping: [])
            WidgetCenter.shared.reloadAllTimelines()
            lastRefresh = .now
            return
        }

        // A background launch has not read the notification setting yet.
        let authorized = await alerts.loadedAuthorization()
        let alertsOn = settings.alertsEnabled && authorized
        for var snapshot in snapshots {
            guard !Task.isCancelled else { return }
            if let journey = try? await journeys.load(snapshot.key, force: true) {
                snapshot.apply(journey)
                byID[snapshot.id]?.update(from: journey)
            }
            // Asked before the update: an update that ends the activity also ends the server's part.
            var remote = activities.serverSendsAlerts(for: snapshot.id)
            if activities.isFollowing(snapshot.id), await activities.update(snapshot, names: names) {
                // The app ended the activity on arrival or cancellation before the server saw it, and
                // told the server to stop: this alert is the app's to post.
                remote = false
                alerts.takeOver(snapshot.id)
            }
            if byID[snapshot.id] != nil, alertsOn {
                let ident = snapshot.ident
                let trains = trains
                // A followed train's alerts ride on its Live Activity push when the server has it.
                await alerts.process(snapshot, names: names, remote: remote) {
                    guard let position = try? await trains.livePosition(for: ident),
                          let coordinate = position.coordinate else { return nil }
                    return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                alerts.scheduleReminder(for: snapshot, names: names)
            }
        }
        alerts.prune(keeping: Set(byID.keys))
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        lastRefresh = .now
    }

    /// Called right after the user saves a train so the reminder exists without waiting for a refresh.
    func trainSaved(_ favorite: FavoriteTrain, journey: TrainJourney?) {
        guard settings.alertsEnabled, alerts.isAuthorized else { return }
        var snapshot = TrainSnapshot(favorite: favorite)
        if let journey {
            snapshot.apply(journey)
        }
        let names = stations.isLoaded ? StationNames(stations: stations.stationsBySignature) : StationNames.loadCached()
        alerts.scheduleReminder(for: snapshot, names: names)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func trainRemoved(_ id: String) {
        alerts.forget(id)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Wraps a value the compiler cannot prove Sendable for a hop we know is safe (a `BGTask` handed
/// straight to the main actor and never touched again on the calling queue).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) {
        self.value = value
    }
}

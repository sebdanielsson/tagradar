import Foundation
import SwiftData
import TrafikverketKit

/// Composition root. Owns every long-lived service and wires them together.
@MainActor
@Observable
final class AppDependencies {
    let settings: AppSettings
    let apiKeyStore: APIKeyStore
    let client: TrafikverketClient
    let stations: StationDirectory
    let live: LiveTrainStore
    let delays: DelayIndex
    let trains: TrainService
    let journeys: JourneyStore
    let location = LocationManager()
    let speech = SpeechSearch()
    let activities = LiveActivityController()
    let alerts = TrainAlerts()
    let monitor: TrainMonitor
    let modelContainer: ModelContainer
    /// A deep link that arrived from a notification tap; `RootView` consumes it.
    var pendingOpenURL: URL?

    private var started = false

    init() {
        let settings = AppSettings()
        let keyStore = APIKeyStore()
        let client = TrafikverketClient(keyProvider: keyStore)
        self.settings = settings
        apiKeyStore = keyStore
        self.client = client
        stations = StationDirectory(client: client)
        live = LiveTrainStore(client: client, settings: settings)
        delays = DelayIndex(client: client)
        let trains = TrainService(client: client)
        self.trains = trains
        journeys = JourneyStore(service: trains)
        do {
            modelContainer = try SharedStorage.makeModelContainer()
        } catch {
            // Fall back to an in-memory store rather than crashing on a corrupt database.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            modelContainer = try! ModelContainer(for: FavoriteTrain.self, FavoriteStation.self, configurations: config)
        }
        monitor = TrainMonitor(
            trains: trains, journeys: journeys, stations: stations, activities: activities, alerts: alerts,
            settings: settings, modelContainer: modelContainer
        )
        // The push server sends a followed train's alerts only when the app would have: the train is
        // saved, alerts are on and allowed, and the user has not muted it.
        let container = modelContainer
        let alertCenter = alerts
        activities.pushPreferences = { id in
            let favorite = try? container.mainContext.fetch(FetchDescriptor<FavoriteTrain>(predicate: #Predicate { $0.id == id })).first
            let authorized = await alertCenter.loadedAuthorization()
            let alertsOn = favorite != nil && settings.alertsEnabled && authorized && !alertCenter.mutedIDs.contains(id)
            return LiveActivityController.PushPreferences(segment: favorite?.segment, alerts: alertsOn)
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        RailNetwork.shared.preload()
        live.start()
        await stations.load()
        await alerts.refreshAuthorization()
        monitor.startForeground()
    }
}

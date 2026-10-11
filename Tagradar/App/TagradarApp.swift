import SwiftData
import SwiftUI
import UserNotifications

@main
struct TagradarApp: App {
    @State private var dependencies: AppDependencies
    @Environment(\.scenePhase) private var scenePhase
    private let notificationDelegate: NotificationDelegate

    init() {
        let dependencies = AppDependencies()
        _dependencies = State(initialValue: dependencies)
        notificationDelegate = NotificationDelegate(
            onOpen: { url in Task { @MainActor in dependencies.pendingOpenURL = url } },
            onMute: { id in
                await dependencies.alerts.mute(id)
                // The action does not open the app, so tell the server now rather than on the next refresh.
                await dependencies.activities.refreshPushRegistration(id)
            }
        )
        TrainMonitor.register(dependencies.monitor)
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(dependencies.apiKeyStore)
                .environment(dependencies.stations)
                .environment(dependencies.live)
                .environment(dependencies.delays)
                .environment(dependencies.journeys)
                .environment(dependencies.location)
                .environment(dependencies.speech)
                .environment(dependencies.settings)
                .environment(dependencies.activities)
                .environment(dependencies.alerts)
                .environment(dependencies.monitor)
                .task { await dependencies.start() }
        }
        .modelContainer(dependencies.modelContainer)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                dependencies.activities.restore()
                dependencies.monitor.startForeground()
                Task { await dependencies.alerts.refreshAuthorization() }
            case .background:
                dependencies.monitor.stopForeground()
                dependencies.monitor.scheduleBackgroundRefresh()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

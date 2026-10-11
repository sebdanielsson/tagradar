import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(APIKeyStore.self) private var keyStore
    @Environment(LiveTrainStore.self) private var live
    @Environment(StationDirectory.self) private var stations
    @Environment(TrainAlerts.self) private var alerts
    @Environment(LiveActivityController.self) private var activities
    @Environment(TrainMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Map") {
                Picker("Appearance", selection: $settings.mapAppearance) {
                    Text("Standard").tag(AppSettings.MapAppearance.standard)
                    Text("Muted").tag(AppSettings.MapAppearance.muted)
                    Text("Satellite").tag(AppSettings.MapAppearance.hybrid)
                }
                Toggle("Show train numbers", isOn: $settings.showTrainLabels)
                Toggle("Colour trains by delay", isOn: $settings.colorMarkersByDelay)
                Toggle("Show inactive trains", isOn: $settings.showInactiveTrains)
                Toggle("Show stations", isOn: $settings.showStations)
            }

            Section {
                Toggle("Alerts for saved trains", isOn: $settings.alertsEnabled)
                    .onChange(of: settings.alertsEnabled) { _, enabled in
                        guard enabled else { return }
                        Task {
                            if await alerts.requestAuthorization() {
                                await monitor.refreshAll()
                            }
                        }
                    }
                if settings.alertsEnabled, alerts.authorization == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Notifications are off for Tågradar. Turn them on in Settings.", systemImage: "bell.slash")
                    }
                }
                LabeledContent("Live Activities") {
                    Text(activities.isAvailable ? "On" : "Off")
                }
                if !activities.followedIDs.isEmpty {
                    Button("Stop following \(activities.followedIDs.count) trains") {
                        Task { await activities.unfollowAll() }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(Self.notificationsFooter)
            }

            Section {
                NavigationLink {
                    APIKeyView()
                } label: {
                    LabeledContent("API key") {
                        switch keyStore.source {
                        case .none: Text("Missing").foregroundStyle(.red)
                        case .bundled: Text("Built in")
                        case .userProvided: Text("Your key")
                        }
                    }
                }
                LabeledContent("Live connection") {
                    Text(connectionText)
                }
                Button("Reconnect") { live.restart() }
            } header: {
                Text("Trafikverket")
            } footer: {
                Text("Data comes from Trafikverket's open API and is licensed CC0. Tågradar is not affiliated with Trafikverket.")
            }

            Section("Stations") {
                LabeledContent("Cached stations", value: stations.all.count.formatted())
                if let date = stations.lastRefresh {
                    LabeledContent("Last refreshed", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Refresh stations") { Task { await stations.refresh() } }
                    .disabled(stations.isLoading)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Link(destination: URL(string: "https://github.com/sebdanielsson/tagradar")!) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/sebdanielsson/tagradar/issues")!) {
                    Label("Report a problem", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // swiftlint:disable:next line_length
    private static let notificationsFooter: LocalizedStringKey = "Tågradar tells you about delays of five minutes or more, cancellations, track changes and arrival for saved trains, plus a reminder 30 minutes before departure. Set your own stops on a saved train to only hear about changes that affect them. While the app is open it checks every 30 seconds. A followed train's Live Activity is kept up to date by Tågradar's server, which also sends that train's alerts; other alerts and widgets refresh when iOS allows, usually every 15 minutes or more, so they can lag behind."

    private var connectionText: String {
        switch live.state {
        case .idle: String(localized: "Paused")
        case .connecting: String(localized: "Connecting…")
        case .streaming: String(localized: "Streaming")
        case .polling: String(localized: "Polling")
        case let .failed(reason): reason
        }
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

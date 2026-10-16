import MapKit
import SwiftData
import SwiftUI
import TrafikverketKit

/// Departure / arrival board for one station.
struct StationBoardView: View {
    let station: TrainStation
    /// When set (the map card on iPhone), selecting a train goes through this instead of a plain
    /// push, so the map behind can update too — and so the push goes through `MapScreen`, which
    /// mirrors the card's navigation path in a typed shadow. `nil` in the iPad inspector, where
    /// the board pushes trains itself onto the enclosing stack and the map deliberately stays on
    /// the station being read.
    var onSelectTrain: ((TrainKey) -> Void)?

    enum Board: String, CaseIterable, Identifiable {
        case departures, arrivals
        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            self == .departures ? "Departures" : "Arrivals"
        }
    }

    @Environment(AppDependencies.self) private var deps
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query private var favoriteStations: [FavoriteStation]
    @State private var board: Board = .departures
    @State private var rows: [TrainAnnouncement] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        // Only where this board pushes its own trains. Inside the map card `onSelectTrain` is set
        // and pushes go through `MapScreen`, which mirrors the path in a typed shadow — a
        // destination declared here would land on that same stack and let a push slip past it.
        if onSelectTrain == nil {
            content.navigationDestination(for: TrainKey.self) { TrainDetailView(key: $0) }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            Section {
                Picker("Board", selection: $board) {
                    ForEach(Board.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let markdown = station.informationMarkdown {
                Section {
                    Label {
                        Text(Self.attributed(markdown))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                if isLoading, rows.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    let kind = board == .departures ? String(localized: "departures") : String(localized: "arrivals")
                    Text("No \(kind) in the next six hours.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        if let onSelectTrain {
                            Button { onSelectTrain(row.key) } label: {
                                AnnouncementRow(announcement: row)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: row.key) {
                                AnnouncementRow(announcement: row)
                            }
                        }
                    }
                }
            } header: {
                Text("Next six hours")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Separate items so Save outlasts Directions when the bar overflows (see `toolbarOverflow`).
            if station.coordinate != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        openDirections()
                    }
                }
                .toolbarOverflow(.overflowFirst)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isFavorite ? "Saved" : "Save", systemImage: isFavorite ? "star.fill" : "star") {
                    toggleFavorite()
                }
                .tint(isFavorite ? .yellow : nil)
                .sensoryFeedback(.success, trigger: isFavorite)
            }
            .toolbarOverflow(.keepVisible)
        }
        .refreshable { await load() }
        .task(id: board) { await load() }
        .onAppear { settings.addRecentStation(station.locationSignature) }
    }

    /// Renders the sanitised station text with tappable links.
    private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown.strippingHTML)
    }

    private var isFavorite: Bool {
        favoriteStations.contains { $0.signature == station.locationSignature }
    }

    /// Opens Apple Maps with directions to the station from the user's current location, in
    /// whichever mode the user prefers — walking and transit are at least as likely as driving
    /// when the destination is a railway station.
    private func openDirections() {
        guard let coordinate = station.coordinate else { return }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let mapItem = MKMapItem(location: location, address: nil)
        mapItem.name = station.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    private func toggleFavorite() {
        if let existing = favoriteStations.first(where: { $0.signature == station.locationSignature }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(FavoriteStation(signature: station.locationSignature, name: station.name))
        }
        try? modelContext.save()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let start = Date.now.addingTimeInterval(-10 * 60)
            rows = switch board {
            case .departures: try await deps.trains.departures(from: station.locationSignature, start: start)
            case .arrivals: try await deps.trains.arrivals(to: station.locationSignature, start: start)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

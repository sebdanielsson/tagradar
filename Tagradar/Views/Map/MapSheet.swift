import SwiftUI
import TrafikverketKit

/// What the map card is showing on top of its search root.
enum MapSheetRoute: Hashable {
    case train(TrainSelection)
    case station(TrainStation)
}

struct TrainSelection: Hashable {
    var key: TrainKey?
    var liveID: String?
}

/// Search, trains and stations. The persistent bottom card on iPhone, where train and station
/// details push inside it like place cards in Apple Maps; the sidebar on iPad, where the details
/// open in an inspector instead and both lists are shown in full rather than shortened.
struct MapSheet: View {
    /// Where the sheet is being shown. Decided by `MapScreen`, not read from the size class: a
    /// `NavigationSplitView` sidebar column is compact width whatever the device, so the
    /// environment would call the iPad sidebar a phone card.
    enum Style {
        /// The bottom card on iPhone: room for the next few trains and a strip of stations.
        case card
        /// The iPad sidebar: every train the card would have truncated, and a full station list.
        case sidebar
    }

    var style: Style = .card
    /// Owned by `MapScreen`, which mirrors it in a typed shadow (`MapNavigationStack`) so a pop
    /// can restore the map. Nothing inside this stack may append to it directly — every push has
    /// to go through `MapScreen`, or the shadow silently drifts and misdirects the next "back".
    @Binding var path: NavigationPath
    @Binding var detent: PresentationDetent
    var onSelectTrain: (TrainKey) -> Void
    var onSelectStation: (TrainStation) -> Void

    @Environment(AppDependencies.self) private var deps
    @Environment(StationDirectory.self) private var stations
    @Environment(SpeechSearch.self) private var speech
    @Environment(\.openURL) private var openURL

    @State private var query = ""
    @State private var date = Date.now
    @State private var journeys: [TrainJourney] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showSettings = false
    /// Owned here rather than by `NearbyDeparturesCard`, which the sheet swaps out while searching.
    @State private var showLocationDeniedAlert = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: MapSheetRoute.self) { route in
                    switch route {
                    case let .train(selection):
                        TrainDetailView(key: selection.key, liveID: selection.liveID)
                    case let .station(station):
                        StationBoardView(station: station, onSelectTrain: onSelectTrain)
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .alert("Location access is off", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access for Tågradar in Settings to see departures near you.")
        }
        .onChange(of: searchFocused) { _, focused in
            if focused {
                detent = .large
            }
        }
        .onChange(of: speech.transcript) { _, text in
            guard speech.isListening || !text.isEmpty else { return }
            query = text
            if !text.isEmpty {
                detent = .large
            }
        }
        .onChange(of: speech.errorMessage) { _, message in
            if let message {
                searchError = message
            }
        }
        .task(id: query) {
            guard !query.isEmpty else {
                journeys = []
                searchError = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await searchTrains()
        }
        .onChange(of: date) { _, _ in Task { await searchTrains() } }
    }

    // MARK: Root

    private var root: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if query.isEmpty {
                    idleContent
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, MapScreen.sheetTopPadding)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Train number or station", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onSubmit { Task { await searchTrains() } }
                if !query.isEmpty, !speech.isListening {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
                Button {
                    searchFocused = false
                    speech.toggle()
                } label: {
                    Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                        .foregroundStyle(speech.isListening ? Color.red : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: speech.isListening)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(speech.isListening ? "Stop listening" : "Search by voice"))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.fill.tertiary, in: .capsule)
            .onTapGesture { searchFocused = true }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(.fill.tertiary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
        }
    }

    // MARK: Idle content

    @ViewBuilder
    private var idleContent: some View {
        MapTrainsCard(style: style, onSelectTrain: onSelectTrain)
        QuickStationsRow(style: style, onSelectStation: open)
        NearbyDeparturesCard(
            onSelectTrain: onSelectTrain,
            onSelectStation: open,
            showLocationDeniedAlert: $showLocationDeniedAlert
        )
    }

    // MARK: Search results

    private var looksLikeTrainNumber: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
    }

    @ViewBuilder
    private var searchResults: some View {
        if looksLikeTrainNumber {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Trains")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, SwedishTime.timeZone)
                }
                if isSearching, journeys.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                } else if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if journeys.isEmpty {
                    Text("No train \(query.trimmingCharacters(in: .whitespaces)) is announced on \(Format.day(date)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(journeys.enumerated()), id: \.element.id) { index, journey in
                            Button {
                                searchFocused = false
                                onSelectTrain(journey.key)
                            } label: {
                                journeyRow(journey)
                            }
                            .buttonStyle(.plain)
                            if index < journeys.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16))
                }
            }
        }

        let matches = stations.search(query, limit: 20)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stations")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, station in
                        Button {
                            open(station)
                        } label: {
                            HStack {
                                Image(systemName: "building.columns")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(station.name)
                                    Text(station.locationSignature).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if index < matches.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(.fill.quaternary, in: .rect(cornerRadius: 16))
            }
        } else if !looksLikeTrainNumber {
            Text("No station matches \(query).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func journeyRow(_ journey: TrainJourney) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(journey.productName ?? String(localized: "Train")) \(journey.key.ident)")
                    .font(.headline)
                Text("\(stations.name(journey.origin?.signature)) → \(stations.name(journey.destination?.signature))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(Format.clock(journey.scheduledDeparture)) – \(Format.clock(journey.scheduledArrival))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DelayBadge(delay: journey.currentDelay, canceled: journey.isFullyCanceled)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    // MARK: Actions

    private func open(_ station: TrainStation) {
        searchFocused = false
        onSelectStation(station)
    }

    private func searchTrains() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard looksLikeTrainNumber else {
            journeys = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            journeys = try await deps.trains.search(ident: trimmed, on: date)
            searchError = nil
        } catch {
            journeys = []
            searchError = error.localizedDescription
        }
    }
}

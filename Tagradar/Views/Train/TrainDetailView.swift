import SwiftData
import SwiftUI
import TrafikverketKit

/// Everything about one train run: header, live position, every stop with planned /
/// estimated / actual times, deviations and traffic messages.
struct TrainDetailView: View {
    let key: TrainKey?
    var liveID: String?
    var onClose: (() -> Void)?

    @Environment(AppDependencies.self) private var deps
    @Environment(JourneyStore.self) private var journeyStore
    @Environment(LiveTrainStore.self) private var live
    @Environment(StationDirectory.self) private var stations
    @Environment(AppSettings.self) private var settings
    @Environment(AppNavigation.self) private var navigation
    @Environment(LiveActivityController.self) private var activities
    @Environment(TrainMonitor.self) private var monitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var favorites: [FavoriteTrain]

    @State private var journey: TrainJourney?
    @State private var messages: [TrainStationMessage] = []
    @State private var showAllMessages = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var followError: String?

    private var liveTrain: LiveTrain? {
        if let liveID, let t = live.train(id: liveID) {
            return t
        }
        if let key {
            return live.train(for: key)
        }
        return nil
    }

    private var effectiveKey: TrainKey? {
        key ?? liveTrain?.key
    }

    private var favorite: FavoriteTrain? {
        guard let id = effectiveKey?.id else { return nil }
        return favorites.first { $0.id == id }
    }

    var body: some View {
        List {
            if let journey {
                JourneyHeaderSection(journey: journey, liveTrain: liveTrain)
                if let favorite {
                    TripSegmentSection(favorite: favorite, journey: journey) { changed(favorite, journey: journey) }
                }
                if let liveTrain {
                    Section {
                        LivePositionCard(train: liveTrain)
                    }
                }
                if !messages.isEmpty {
                    Section {
                        ForEach(showAllMessages ? messages : Array(messages.prefix(2))) { MessageCard(message: $0) }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        if messages.count > 2 {
                            Button {
                                withAnimation(.snappy) { showAllMessages.toggle() }
                            } label: {
                                Text(showAllMessages ? "Show fewer" : "Show all \(messages.count) messages")
                                    .font(.footnote.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Station messages")
                    }
                }
                Section {
                    StopTimelineView(journey: journey)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    HStack {
                        Text("Stops")
                        Spacer()
                        Text("\(journey.stops.count) stations")
                            .textCase(nil)
                    }
                }
                JourneyFactsSection(journey: journey)
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if let liveTrain, effectiveKey == nil {
                Section {
                    LivePositionCard(train: liveTrain)
                }
                Section {
                    EmptyStateView(
                        systemImage: "shippingbox",
                        title: "No timetable",
                        message: """
                        This train is not advertised for passengers, so Trafikverket publishes no stops for it. \
                        It is most likely a freight or service train.
                        """
                    )
                    .listRowBackground(Color.clear)
                }
            } else if let error {
                Section {
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Could not load",
                        message: LocalizedStringKey(error),
                        actionTitle: "Try again"
                    ) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "No timetable found",
                        message: "Trafikverket has no announcements for this train on the selected day."
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: onClose)
                }
            }
            // Separate items rather than one group so Follow and Save can outlast the rest when the
            // bar overflows (see `toolbarOverflow`). Adjacent items still share one glass background.
            if let journey, canFollow(journey) {
                ToolbarItem(placement: .topBarTrailing) {
                    let following = activities.isFollowing(journey.key.id)
                    Button(following ? "Following" : "Follow", systemImage: "dot.radiowaves.left.and.right") {
                        toggleFollow(journey)
                    }
                    .tint(following ? .accentColor : nil)
                    .symbolEffect(.variableColor.iterative, isActive: following)
                    .sensoryFeedback(.selection, trigger: following)
                }
                .toolbarOverflow(.keepVisible)
            }
            if effectiveKey != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(favorite == nil ? "Save" : "Saved", systemImage: favorite == nil ? "star" : "star.fill") {
                        toggleFavorite()
                    }
                    .tint(favorite == nil ? nil : .yellow)
                    .sensoryFeedback(.success, trigger: favorite != nil)
                }
                .toolbarOverflow(.keepVisible)
            }
            if liveTrain != nil, onClose == nil, sizeClass == .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show on map", systemImage: "map") {
                        if let effectiveKey {
                            navigation.showOnMap(effectiveKey)
                        }
                    }
                }
                .toolbarOverflow(.overflowFirst)
            }
            if let journey {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(for: journey)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .toolbarOverflow(.overflowFirst)
            }
        }
        .refreshable { await load() }
        .task(id: effectiveKey?.id) {
            await load()
            rememberVisit()
            await autoRefresh()
        }
        .alert("Could not start Live Activity", isPresented: Binding(get: { followError != nil }, set: {
            if !$0 {
                followError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(followError ?? "")
        }
    }

    private var title: String {
        if let key = effectiveKey {
            return String(localized: "Train \(key.ident)")
        }
        if let liveTrain {
            return String(localized: "Train \(liveTrain.displayNumber)")
        }
        return String(localized: "Train")
    }

    // MARK: Loading

    private func load() async {
        guard let key = effectiveKey else { return }
        if journey == nil {
            journey = journeyStore.cached(key)
            isLoading = journey == nil
        }
        defer { isLoading = false }
        do {
            let loaded = try await journeyStore.load(key, force: journey != nil)
            journey = loaded
            error = nil
            if let loaded {
                favorite?.update(from: loaded)
                let related = try? await deps.trains.stationMessages(at: loaded.allSignatures)
                messages = related ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Notes the visit so the map card can offer a way back to this run. Deliberately not inside
    /// `load()`, which also runs on every pull and every auto-refresh tick: opening a train is the
    /// event worth remembering, not looking at it for a while. Without a journey there is nothing
    /// to show in a row, so a failed load leaves no trace.
    private func rememberVisit() {
        guard let key = effectiveKey, let journey else { return }
        settings.addRecentTrain(RecentTrain(key: key, journey: journey))
    }

    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            if journey?.status != .arrived {
                await load()
            }
        }
    }

    // MARK: Favorites

    private func toggleFavorite() {
        guard let key = effectiveKey else { return }
        if let favorite {
            let id = favorite.id
            modelContext.delete(favorite)
            try? modelContext.save()
            monitor.trainRemoved(id)
        } else {
            let fav = FavoriteTrain(key: key, journey: journey)
            modelContext.insert(fav)
            try? modelContext.save()
            monitor.trainSaved(fav, journey: journey)
        }
    }

    /// The user changed their boarding or alighting stop: reschedule reminders and refresh the activity.
    private func changed(_ favorite: FavoriteTrain, journey: TrainJourney) {
        try? modelContext.save()
        monitor.trainSaved(favorite, journey: journey)
        if activities.isFollowing(favorite.id) {
            Task { await activities.update(snapshot(for: journey), names: names) }
        }
    }

    // MARK: Live Activity

    private var names: StationNames {
        StationNames(stations: stations.stationsBySignature)
    }

    private func snapshot(for journey: TrainJourney) -> TrainSnapshot {
        TrainSnapshot(journey: journey, segment: favorite?.segment)
    }

    private func canFollow(_ journey: TrainJourney) -> Bool {
        guard activities.isAvailable else { return false }
        let status = snapshot(for: journey).status
        return status == .scheduled || status == .enRoute || activities.isFollowing(journey.key.id)
    }

    private func toggleFollow(_ journey: TrainJourney) {
        if activities.isFollowing(journey.key.id) {
            Task { await activities.unfollow(journey.key.id) }
            return
        }
        do {
            try activities.follow(snapshot(for: journey), names: names)
        } catch {
            followError = error.localizedDescription
        }
    }

    private func shareText(for journey: TrainJourney) -> String {
        var lines: [String] = []
        let product = journey.productName ?? String(localized: "Train")
        lines.append("\(product) \(journey.key.ident) · \(Format.day(journey.key.departureDate))")
        if let o = journey.origin, let d = journey.destination {
            lines.append("\(stations.name(o.signature)) \(Format.clock(o.departure?.advertisedTimeAtLocation)) → "
                + "\(stations.name(d.signature)) \(Format.clock(d.arrival?.advertisedTimeAtLocation))")
        }
        if let delay = Format.delay(journey.currentDelay) {
            lines.append(delay)
        }
        lines.append("tagradar://train/\(journey.key.id)")
        return lines.joined(separator: "\n")
    }
}

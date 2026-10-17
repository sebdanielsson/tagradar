import CoreLocation
import SwiftUI
import TrafikverketKit

/// "Near you": departures or arrivals for the station closest to the user, shown at the bottom of
/// the idle map sheet. Owns its own location fix, board selection and fetch cache.
struct NearbyDeparturesCard: View {
    var onSelectTrain: (TrainKey) -> Void
    var onSelectStation: (TrainStation) -> Void
    /// Raised by this card, but presented by `MapSheet` — an alert attached to a section that the
    /// sheet swaps out while searching would be torn down with it.
    @Binding var showLocationDeniedAlert: Bool

    @Environment(AppDependencies.self) private var deps
    @Environment(StationDirectory.self) private var stations
    @Environment(AppSettings.self) private var settings
    @Environment(LocationManager.self) private var location

    @State private var station: TrainStation?
    @State private var distance: CLLocationDistance?
    /// Departures by default — that's what someone glancing at the sheet on their way out wants;
    /// arrivals mainly matter when picking someone up.
    @State private var board: Board = .departures
    @State private var rows: [TrainAnnouncement] = []
    @State private var isExpanded = false
    @State private var isLoading = false
    @State private var error: String?
    /// Which board the rows on screen belong to, so a plain refresh can keep showing them while
    /// the replacement is in flight and only a board switch blanks the list.
    @State private var loadedBoard: Board?
    /// Bumped by the refresh button. Feeding the tap through `.task(id:)` instead of an unstructured
    /// `Task` is what makes a manual refresh cancellable like any other load.
    @State private var refreshToken = 0
    /// Keyed by board so switching tabs doesn't serve the other tab's rows, and so a `.task`
    /// restart from a push/pop through the sheet's `NavigationStack` — which cancels and reruns
    /// the card's task even though nothing actually changed — can skip the network round trip.
    @State private var cache: [Board: CacheEntry] = [:]

    /// The same two boards the station screen offers, so the segment titles and ordering can never
    /// drift apart between the two places the app shows a board.
    private typealias Board = StationBoardView.Board

    /// Combines every input `load(board:)` depends on so one `.task(id:)` owns all of them — and so
    /// each of them cancels the run in flight instead of racing it. `revision` matters because the
    /// directory is empty on a cold start: the first lookup finds no station at all, and only a
    /// reload once the stations land turns "none nearby" back into a real answer.
    private struct LoadKey: Equatable {
        var authorized: Bool
        var board: Board
        var revision: Int
        var refreshToken: Int
    }

    private struct CacheEntry {
        var station: TrainStation?
        var distance: CLLocationDistance?
        var rows: [TrainAnnouncement]
        var loadedAt: Date
        /// The directory the station was resolved against. `LoadKey` reruns the task when this
        /// changes, but the fast path below would answer from the old directory before the rerun
        /// ever reached `nearest(to:)`, so the entry has to be able to disqualify itself.
        var revision: Int
    }

    /// Rows shown before "Show more"; `maxRows` is fetched up front so expanding is instant.
    private static let previewCount = 3
    /// What "Show more" reveals, counted after the departed runs have been dropped.
    private static let maxRows = 8
    /// Asked of the API, which applies its limit before this card gets to filter anything. A hub
    /// can fill the lookback window below with runs that have already gone, so a limit near
    /// `maxRows` would spend the whole response on them and leave the card looking empty at the
    /// busiest station it will ever be used at. Bounded well above that, not unbounded: this runs
    /// on a location fix, and the six-hour window the query defaults to is a lot of train.
    private static let fetchLimit = 60
    /// The board filters on the advertised time, so this window has to reach back far enough that
    /// a run still standing at the platform on a delay is not read as one that has left. Matches
    /// `StationBoardView`, which asks the same question of a station the user picked by hand.
    private static let lookback: TimeInterval = -10 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !location.isAuthorized {
                permissionRow
            } else {
                stationLink
                Picker("Board", selection: $board) {
                    ForEach(Board.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: board) { isExpanded = false }
                boardContent
            }
        }
        .animation(.easeInOut(duration: 0.25), value: rows)
        .task(
            id: LoadKey(
                authorized: location.isAuthorized,
                board: board,
                revision: stations.revision,
                refreshToken: refreshToken
            )
        ) {
            await load(board: board)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Near you")
                .font(.title3.weight(.semibold))
            Spacer()
            if location.isAuthorized {
                // Only worth a mention once it's stale enough to matter; a fresh load right
                // after a manual refresh would otherwise show a distracting "0 sec ago".
                if !isLoading {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        if let updatedAt = cache[board]?.loadedAt,
                           context.date.timeIntervalSince(updatedAt) >= 60 {
                            Text("Updated \(Format.relative(updatedAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline)
                .rotationEffect(.degrees(isLoading ? 360 : 0))
                .animation(
                    isLoading ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default,
                    value: isLoading
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isLoading)
        .accessibilityLabel(Text("Refresh"))
    }

    @ViewBuilder
    private var stationLink: some View {
        if let station {
            Button {
                onSelectStation(station)
            } label: {
                HStack(spacing: 4) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                    if let text = Format.distance(distance) {
                        // Verbatim: `Format.distance` is already localized, and a bare separator
                        // is nothing to translate — as a `Text` key it would only add "· %@" to
                        // the catalog for every language to leave untouched.
                        Text(verbatim: "· \(text)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var boardContent: some View {
        if isLoading, rows.isEmpty {
            SkeletonRows()
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        } else if rows.isEmpty {
            Text(
                board == .departures
                    ? "No departures nearby right now."
                    : "No arrivals nearby right now."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        } else {
            let visibleRows = isExpanded ? rows : Array(rows.prefix(Self.previewCount))
            VStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        onSelectTrain(row.key)
                    } label: {
                        AnnouncementRow(announcement: row)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if index < visibleRows.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
            if rows.count > Self.previewCount {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show fewer" : "Show more")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    private var permissionRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.tint, in: .circle)
            Text("See departures and arrivals for the station closest to you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Allow location", action: requestAccess)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }

    // MARK: Actions

    private func requestAccess() {
        if location.isDenied {
            showLocationDeniedAlert = true
        } else {
            location.requestAccess()
        }
    }

    /// Every write is gated on cancellation. `.task(id:)` starts the replacement without waiting
    /// for the old run to unwind, so an ungated write here lands *after* its successor has already
    /// taken over — clearing the skeleton mid-fetch, or emptying a board the new run just filled.
    ///
    /// `board` is passed in rather than read from state, so a run that started for Departures still
    /// caches its rows under Departures even if the user has since switched tab.
    private func load(board: Board) async {
        guard location.isAuthorized else { return }
        // A task cancelled before its body first ran still runs it — cancellation is cooperative,
        // not a skip — and everything down to the first await below is synchronous. Without this
        // the cache path could hand its rows to a board the user has already left.
        guard !Task.isCancelled else { return }
        // Claimed before the early return below, so the cache path can't leave the refresh button
        // spinning and disabled with no run left to clear it.
        isLoading = true
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }
        // Deliberately answers without a fresh fix. Skipping a location request and a round trip
        // on a push and pop back through the sheet is the whole point of the cache, and the entry
        // is only good for `pollingInterval` — fifteen seconds, with no setting to raise it. The
        // nearest station cannot change in that time on foot, and a journey that does cross one
        // keeps the card reloading anyway.
        if let cached = cache[board], cached.revision == stations.revision,
           Date.now.timeIntervalSince(cached.loadedAt) < settings.pollingInterval {
            station = cached.station
            distance = cached.distance
            rows = cached.rows
            loadedBoard = board
            error = nil
            return
        }
        // Only a board switch blanks the list: on a refresh the rows on screen are still the right
        // ones, and replacing them with a skeleton would be a step backwards.
        if loadedBoard != board {
            rows = []
        }
        error = nil
        let fix = await location.currentLocation()
        guard !Task.isCancelled else { return }
        // A one-shot request that comes back empty is a location failure, not an empty map: saying
        // no station is near would send the user hunting for a station that is right there.
        guard let fix else {
            clearBoard(error: String(localized: "Could not get your location."))
            return
        }
        guard let nearest = stations.nearest(to: fix) else {
            clearBoard(error: String(localized: "Could not find a station near you."))
            return
        }
        // A cache hit restores the station its rows were loaded for, so an entry from a station the
        // user has since left relabels the card as soon as that board is selected — the other tab
        // is not refreshed just because this one was. Resolving a different station makes every
        // entry that disagrees stale, however young.
        cache = cache.filter { $0.value.station?.id == nearest.id }
        // Rows are otherwise kept through a load so a refresh doesn't blink — but rows belong to
        // the station they were fetched for, and the line below is about to put a different name
        // above them. Dropping them here trades the blink for not captioning one station's
        // platform with another's departures.
        if station?.id != nearest.id {
            rows = []
            loadedBoard = nil
        }
        // Known as soon as we have a location fix, well before the departures/arrivals fetch
        // resolves, so the card can label itself immediately instead of alongside the skeleton.
        station = nearest
        let metres = nearest.coordinate.map { fix.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
        distance = metres
        let start = Date.now.addingTimeInterval(Self.lookback)
        do {
            let fetched = switch board {
            case .departures:
                try await deps.trains.departures(from: nearest.locationSignature, start: start, limit: Self.fetchLimit)
            case .arrivals:
                try await deps.trains.arrivals(to: nearest.locationSignature, start: start, limit: Self.fetchLimit)
            }
            guard !Task.isCancelled else { return }
            // The lookback reaches back past the timetable so a run standing at the platform on a
            // delay survives; it also drags in the runs that genuinely left in those ten minutes,
            // and the query is ordered by advertised time, so unfiltered they take the preview's
            // three rows at a hub. `timeAtLocation` is the API recording that the call actually
            // happened — departure or arrival — so a late train still waiting has none and stays.
            let pending = Array(fetched.filter { !$0.hasDeparted }.prefix(Self.maxRows))
            rows = pending
            loadedBoard = board
            error = nil
            cache[board] = CacheEntry(
                station: nearest, distance: metres, rows: pending, loadedAt: .now, revision: stations.revision
            )
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            loadedBoard = nil
            // Otherwise an expired key or a dead connection is indistinguishable from a platform
            // with nothing scheduled, and the refresh button looks like it does nothing.
            self.error = error.localizedDescription
        }
    }

    /// Drops back to a bare card carrying `error`. Nothing on screen survives: the station name and
    /// distance belong to a fix we no longer trust, and rows under the wrong heading read as the
    /// nearby board rather than the leftovers they are.
    private func clearBoard(error: String) {
        station = nil
        distance = nil
        rows = []
        loadedBoard = nil
        self.error = error
    }

    /// Bypasses the TTL cache so a manual tap always hits the network, even right after a load.
    private func refresh() {
        cache[board] = nil
        refreshToken += 1
    }
}

/// Stand-ins for `AnnouncementRow` while the first fetch for the current board is in flight —
/// matches its layout so the real rows don't visibly reflow in once they arrive.
private struct SkeletonRows: View {
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< 3, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // Verbatim: redacted out of sight, but a plain literal would be extracted into
                    // the string catalog and land on a translator's desk.
                    Text(verbatim: "00:00")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Placeholder station")
                            .font(.body.weight(.medium))
                        Text(verbatim: "Placeholder")
                            .font(.caption)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if index < 2 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .redacted(reason: .placeholder)
        .opacity(isPulsing ? 0.4 : 1)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        // `redacted` blurs the placeholders on screen but leaves them in the accessibility tree,
        // so without this VoiceOver reads out "00:00, Placeholder station" as though it were a
        // departure. One "Loading" in place of the three fake rows says what is actually going on.
        .accessibilityElement(children: .ignore)
        // Not "Loading departures": the same skeleton stands in for the arrivals board.
        .accessibilityLabel(Text("Loading"))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

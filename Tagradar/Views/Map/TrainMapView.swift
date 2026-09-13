import MapKit
import os
import SwiftUI
import TrafikverketKit

/// The MapKit view itself: an annotation for every live train inside the visible region, the
/// selected train's route, and a dot for each station on screen.
struct TrainMapView: View {
    @Binding var camera: MapCameraPosition
    @Binding var visibleRegion: MKCoordinateRegion
    @Binding var selectedTrainID: String?
    var selectedKey: TrainKey?
    var selectedStation: TrainStation?
    var onSelectStation: (TrainStation) -> Void
    var scope: Namespace.ID

    @Environment(LiveTrainStore.self) private var live
    @Environment(JourneyStore.self) private var journeys
    @Environment(StationDirectory.self) private var stations
    @Environment(DelayIndex.self) private var delays
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    /// The trains actually handed to the map. Populated from `live.trains` outside of `body` (see
    /// `refreshDisplayedTrains`) so the nationwide position stream — which can update several times a
    /// second — only triggers a re-render when the filtered, on-screen set actually changes, instead
    /// of on every position update anywhere in Sweden.
    @State private var displayedTrains: [LiveTrain] = []
    /// When `displayedTrains` was last replaced. Markers are dimmed as stale as of this moment, not
    /// as of whenever `body` last ran, so `looksDifferent` knows exactly what is on screen.
    @State private var displayedAt = Date.distantPast
    @State private var refreshTask: Task<Void, Never>?
    /// The selected journey's route, following real track geometry where possible, one entry per
    /// leg between consecutive stops so `routeOverlay` can colour a cancelled leg differently.
    /// Computed once per selection (see `refreshRoute`) rather than on every `body` evaluation —
    /// Dijkstra over the rail network isn't free, and the route never changes while a train just
    /// keeps moving.
    @State private var routeLegs: [[CLLocationCoordinate2D]] = []
    /// The ambient station pins actually handed to the map, resolved outside `body` for the same
    /// reason as `displayedTrains`: `body` re-runs several times a second while positions stream,
    /// and a nationwide `ForEach` over the whole directory would rebuild ~700 annotations — and
    /// re-parse ~700 WKT coordinate strings — every time, almost all of them off-screen.
    @State private var stationLayout = StationLayout()
    /// The map's size in points, needed to judge how far apart the station dots actually look and
    /// how far a train has to move before its marker visibly does.
    @State private var mapSize: CGSize = .zero

    private static let logger = Logger(subsystem: "se.tagradar.app", category: "TrainMapView")

    var body: some View {
        Map(position: $camera, interactionModes: .all, selection: $selectedTrainID, scope: scope) {
            UserAnnotation()
            if let journey = journeys.cached(selectedKey) {
                routeOverlay(for: journey)
            }
            ForEach(stationLayout.pins) { pin in
                Annotation(coordinate: pin.station.clCoordinate, anchor: .center) {
                    Button { onSelectStation(pin.station.station) } label: {
                        // The dot stays small; the frame around it is an invisible tap target,
                        // sized so it can't cover a neighbouring dot (see `StationPins.pins`).
                        // Station annotations are declared before the trains, so a train drawn on
                        // top of one still wins the tap.
                        StationMarker(name: pin.station.station.name)
                            .frame(width: pin.hitSize, height: pin.hitSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                } label: {
                    Text(pin.station.station.name)
                }
                .annotationTitles(.hidden)
            }
            // After the ambient dots, so the larger marker covers this station's own dot in the
            // frame between selecting it and the next refresh dropping that dot.
            if let selectedStation, let coordinate = selectedStation.coordinate {
                Annotation(
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    anchor: .center
                ) {
                    StationMarker(name: selectedStation.name, isSelected: true)
                } label: {
                    Text(selectedStation.name)
                }
                .annotationTitles(.visible)
            }
            ForEach(displayedTrains) { train in
                Annotation(coordinate: train.clCoordinate, anchor: .center) {
                    TrainMarker(
                        train: train,
                        severity: settings.colorMarkersByDelay ? delays.severity(for: train.key) : .unknown,
                        isSelected: train.id == selectedTrainID,
                        showLabel: showLabels,
                        isStale: train.isStale(at: displayedAt),
                        compact: compactMarkers
                    )
                } label: {
                    Text(train.displayNumber)
                }
                .annotationTitles(.hidden)
                .tag(train.id)
            }
        }
        .mapStyle(mapStyle)
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            // This refreshes right away, and a task still sleeping out a zoomed-out interval would
            // otherwise hold off the next live update for that long after zooming in.
            cancelRefresh()
            refreshDisplayedTrains()
            refreshDisplayedStations()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            mapSize = size
            refreshDisplayedStations()
            // A new size is a new scale for `looksDifferent`, so apply it now, not on the next tick.
            refreshDisplayedTrains()
        }
        .onLiveTrainsUpdate(initial: true) {
            scheduleRefresh()
        }
        .onDisappear {
            cancelRefresh()
        }
        .onChange(of: settings.showInactiveTrains) { _, _ in
            refreshDisplayedTrains()
        }
        .onChange(of: selectedKey) { _, _ in
            fitCameraToRouteIfNeeded()
        }
        .onChange(of: journeys.cached(selectedKey)) { _, _ in
            fitCameraToRouteIfNeeded()
        }
        .onChange(of: stationInputs, initial: true) { _, _ in
            refreshDisplayedStations()
        }
        .onChange(of: routeInputs, initial: true) { _, _ in
            // `initial: true` matters: `selectedKey` lives in `MapScreen` and outlives this view,
            // but `routeLegs` doesn't — a size-class change (rotating a Max, iPad Split
            // View) rebuilds the layout and with it a fresh `TrainMapView`, which must redraw the
            // already-selected route even though nothing changed from its own point of view.
            refreshRoute()
        }
    }

    /// Everything `refreshRoute` depends on, so a change to any of it recomputes the route exactly
    /// once: the journey's ordered stops (only their signatures — the journey itself is refreshed
    /// every 30 s with new times, which must not re-stitch an identical line), the station
    /// directory (stop coordinates come from it — a route computed before it finished loading
    /// would be missing stops), and the rail network (straight lines are drawn until it's parsed,
    /// then upgraded to real track).
    private struct RouteInputs: Equatable {
        let stopSignatures: [String]
        let stationsLoaded: Bool
        let networkLoaded: Bool
    }

    private var routeInputs: RouteInputs {
        RouteInputs(
            stopSignatures: stopSignatures,
            stationsLoaded: stations.isLoaded,
            networkLoaded: RailNetwork.shared.isLoaded
        )
    }

    /// Zoomed out over most/all of the country, hundreds of trains can be on screen at once and most
    /// barely move between ticks at that scale, so refreshing as often as the stream flushes (every
    /// ~400 ms) only burns main-thread time without a visible benefit. Zoomed into a city or line,
    /// refresh at full speed.
    private var refreshInterval: Duration {
        let span = visibleRegion.span.latitudeDelta
        return if span > 5 {
            .seconds(3)
        } else if span > 3 {
            .milliseconds(1500)
        } else {
            Self.minRefreshInterval
        }
    }

    private static let minRefreshInterval: Duration = .milliseconds(400)

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            try? await Task.sleep(for: refreshInterval)
            // Before clearing `refreshTask`: a cancelled task's slot may already hold its successor.
            guard !Task.isCancelled else { return }
            refreshTask = nil
            refreshDisplayedTrains()
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Zoomed out this far, trains are drawn as plain dots without a heading.
    private var compactMarkers: Bool {
        visibleRegion.span.latitudeDelta > 5
    }

    /// Everything `refreshDisplayedStations` depends on apart from the camera (which is handled in
    /// `onMapCameraChange`). Read from `body`, so `@Observable` tracks the toggle and the directory
    /// finishing its load.
    private struct StationInputs: Equatable {
        let show: Bool
        let directoryRevision: Int
        let marked: Set<String>
        let networkLoaded: Bool
    }

    private var stationInputs: StationInputs {
        StationInputs(
            show: settings.showStations,
            directoryRevision: stations.revision,
            marked: Set(markedStations.keys),
            networkLoaded: RailNetwork.shared.isLoaded
        )
    }

    /// Stations that already have a marker of their own — the selected station and every stop of
    /// the selected train's route — mapped to the point that marker is drawn at. They get no
    /// ambient dot: one drawn over a stop dot would hide whether that stop is cancelled or already
    /// passed, and one drawn beside it would swallow the taps meant for it.
    private var markedStations: [String: MapMarker] {
        var marked: [String: MapMarker] = [:]
        for signature in stopSignatures {
            marked[signature] = stopAnchor(for: signature).map {
                MapMarker(coordinate: $0, radius: Self.stopDotSize / 2)
            }
        }
        if let station = selectedStation, let coordinate = station.coordinate {
            marked[station.locationSignature] = MapMarker(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                radius: StationMarker.selectedSize / 2
            )
        }
        return marked
    }

    /// The dot drawn for one of the selected train's stops.
    private static let stopDotSize: CGFloat = 10

    private var stopSignatures: [String] {
        journeys.cached(selectedKey)?.stops.map(\.signature) ?? []
    }

    /// Recomputes the ambient station dots for the current camera (see `StationPins`), and only
    /// touches `displayedStations` when the set actually changed, so a camera nudge doesn't
    /// re-render the map. The directory holds every advertised station in the country, of which a
    /// city-level camera shows a few dozen.
    private func refreshDisplayedStations() {
        let marked = markedStations
        let next = settings.showStations
            ? StationPins.layout(
                from: stations.located,
                in: visibleRegion,
                markedElsewhere: marked,
                mapHeight: mapSize.height
            )
            // The dots are off, but the route's own stop dots still need targets that don't cover
            // each other.
            : StationPins.layout(from: [], in: visibleRegion, markedElsewhere: marked, mapHeight: mapSize.height)
        guard next != stationLayout else { return }
        stationLayout = next
    }

    /// Recomputes the on-screen train set and only touches `displayedTrains` (and re-tracks delays)
    /// when it actually changed, so an update elsewhere in the country doesn't re-render this map.
    private func refreshDisplayedTrains() {
        let next = visibleTrains
        guard looksDifferent(next) else { return }
        displayedTrains = next
        displayedAt = .now
        delays.track(next.compactMap(\.key))
    }

    /// Whether handing `next` to the map would change anything on screen. Almost every update moves
    /// some train, but zoomed out a point covers a kilometre or more, so most moves don't show and
    /// re-rendering hundreds of annotations for them is what makes panning stutter. Compared against
    /// what is displayed rather than the previous update, so slow drift still lands once it adds up.
    private func looksDifferent(_ next: [LiveTrain]) -> Bool {
        guard next.count == displayedTrains.count else { return true }
        // Before the first layout there is no scale to judge a move by.
        guard mapSize.width > 0, mapSize.height > 0 else { return next != displayedTrains }
        let latTolerance = visibleRegion.span.latitudeDelta / mapSize.height
        let lonTolerance = visibleRegion.span.longitudeDelta / mapSize.width
        let compact = compactMarkers
        let now = Date.now
        return zip(displayedTrains, next).contains { old, new in
            old.id != new.id
                || abs(old.coordinate.latitude - new.coordinate.latitude) >= latTolerance
                || abs(old.coordinate.longitude - new.coordinate.longitude) >= lonTolerance
                // A compact dot has no heading, but the selected train is always drawn in full.
                || ((!compact || new.id == selectedTrainID) && old.bearing != new.bearing)
                || old.isActive != new.isActive
                // What the marker shows (see `displayedAt`) against what it should show now.
                || old.isStale(at: displayedAt) != new.isStale(at: now)
                || old.key != new.key
                || old.displayNumber != new.displayNumber
        }
    }

    /// Frames the selected train's route when it has no live position to zoom to instead — e.g. a
    /// scheduled or already-arrived train opened from search or favorites. Live trains are already
    /// framed directly wherever they're selected (tapping a marker, `MapScreen.focus(on:)`), so this
    /// only fills the gap the schematic `routeOverlay` would otherwise leave off-screen.
    private func fitCameraToRouteIfNeeded() {
        guard let selectedKey, live.train(for: selectedKey) == nil,
              let journey = journeys.cached(selectedKey) else { return }
        let coordinates = journey.stops.compactMap { stations.station($0.signature)?.coordinate }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let region = MKCoordinateRegion(fitting: coordinates) else { return }
        withAnimation(.smooth) { camera = .region(region) }
    }

    /// One leg of the route between two consecutive stops, coloured red where the train doesn't
    /// actually run it.
    private struct ColoredLeg: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let isCanceled: Bool
    }

    /// Pairs `routeLegs`' geometry with each leg's two stops to decide whether it's cancelled — a
    /// leg is skipped when the train doesn't depart the first stop, or doesn't arrive at the
    /// second, wherever `journey`'s cancellation lands (fully or partly cancelled runs alike).
    private func coloredLegs(for journey: TrainJourney) -> [ColoredLeg] {
        zip(zip(journey.stops, journey.stops.dropFirst()), routeLegs).enumerated().map { index, pair in
            let ((from, to), coordinates) = pair
            let isCanceled = (from.departure?.isCanceled ?? false) || (to.arrival?.isCanceled ?? false)
            return ColoredLeg(id: index, coordinates: coordinates, isCanceled: isCanceled)
        }
    }

    /// The selected train's route (`routeLegs`, following real track where the network covers it)
    /// and a dot per stop.
    @MapContentBuilder
    private func routeOverlay(for journey: TrainJourney) -> some MapContent {
        let points = stopPoints(for: journey)
        ForEach(coloredLegs(for: journey)) { leg in
            if leg.coordinates.count > 1 {
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(
                        leg.isCanceled ? Color.red.opacity(0.75) : Color.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 6])
                    )
            }
        }
        ForEach(points, id: \.0.id) { stop, coordinate in
            Annotation(coordinate: coordinate, anchor: .center) {
                // Tappable like any other station: a stop dot suppresses the ambient dot that
                // would otherwise sit under it, so it has to be the thing that opens the board.
                // Its target is sized alongside the dots' (see `StationPins`), so a stop and a
                // dot never cover each other.
                Button { openStation(stop.signature) } label: {
                    Circle()
                        .fill(stop.isCanceled ? Color.red : (stop.hasPassed ? Color.secondary : Color.accentColor))
                        .frame(width: Self.stopDotSize, height: Self.stopDotSize)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                        .frame(width: hitSize(for: stop.signature), height: hitSize(for: stop.signature))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Station \(stations.name(stop.signature))"))
            } label: {
                Text(stations.shortName(stop.signature))
            }
            .annotationTitles(visibleRegion.span.latitudeDelta < 1.5 ? .visible : .hidden)
        }
    }

    /// The tap target for a stop dot, from the same pass that sizes the ambient dots. Falls back
    /// to the dot's own width before that pass has run.
    private func hitSize(for signature: String) -> CGFloat {
        stationLayout.markerHitSizes[signature] ?? StationPins.minSeparation
    }

    private func openStation(_ signature: String) {
        guard let station = stations.station(signature) else {
            Self.logger.error("No station for signature \(signature, privacy: .public)")
            return
        }
        onSelectStation(station)
    }

    private func stopPoints(for journey: TrainJourney) -> [(TrainStop, CLLocationCoordinate2D)] {
        journey.stops.compactMap { stop in
            stopAnchor(for: stop.signature).map { (stop, $0) }
        }
    }

    /// Where a stop is drawn — its dot and the ends of its route segments: on the track node the
    /// rail network snapped the station to, so the dot sits exactly on the line, and only for a
    /// station the network doesn't cover (or before it has loaded) the directory coordinate.
    private func stopAnchor(for signature: String) -> CLLocationCoordinate2D? {
        if let onTrack = RailNetwork.shared.stationCoordinate(signature) {
            return onTrack
        }
        return stations.station(signature)?.coordinate.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    /// Recomputes `routeLegs` for the currently selected journey: each consecutive stop pair's real
    /// track shape where the bundled network has it, a straight segment otherwise (see
    /// `RailGraph.legs(through:route:)`). Cheap when nothing changed (an unchanged pair hits
    /// `RailNetwork`'s cache), but still only called when `routeInputs` changes — never from `body`.
    private func refreshRoute() {
        let stops = routeInputs.stopSignatures.compactMap { signature in
            stopAnchor(for: signature).map { (signature: signature, coordinate: $0) }
        }
        guard !stops.isEmpty else {
            if !routeLegs.isEmpty {
                routeLegs = []
            }
            return
        }
        routeLegs = RailGraph.legs(through: stops) { RailNetwork.shared.route(from: $0, to: $1) }
    }

    private var mapStyle: MapStyle {
        switch settings.mapAppearance {
        case .standard: .standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .including([.publicTransport]))
        case .muted: .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }

    /// Only labels when zoomed in enough for them to be legible.
    private var showLabels: Bool {
        settings.showTrainLabels && visibleRegion.span.latitudeDelta < 2.2
    }

    /// Ambient trains for the current view, plus the explicitly selected one regardless of the
    /// active/region filters — a train the user searched for or saved shouldn't silently disappear
    /// just because Trafikverket marked it inactive (e.g. it already arrived) or it's off-screen
    /// mid-animation while the camera is still flying to it.
    private var visibleTrains: [LiveTrain] {
        let region = visibleRegion.padded(by: 0.25)
        var result = live.trains.filter { train in
            (settings.showInactiveTrains || train.isActive) && region.contains(train.clCoordinate)
        }
        if let selectedTrainID, !result.contains(where: { $0.id == selectedTrainID }),
           let selected = live.train(id: selectedTrainID) {
            result.append(selected)
        }
        return result
    }
}

/// Runs `action` whenever `LiveTrainStore` merges a batch of positions. A modifier rather than an
/// `onChange` in the caller's `body`: reading `updateCount` there re-renders the whole caller on
/// every flush, several times a second — for `MapScreen` that is the map with all its annotations
/// and the card presented from it. Here only this modifier's body is invalidated.
private struct LiveTrainsUpdateObserver: ViewModifier {
    @Environment(LiveTrainStore.self) private var live
    let initial: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: live.updateCount, initial: initial) { action() }
    }
}

extension View {
    func onLiveTrainsUpdate(initial: Bool = false, perform action: @escaping () -> Void) -> some View {
        modifier(LiveTrainsUpdateObserver(initial: initial, action: action))
    }
}

extension MKCoordinateRegion {
    func padded(by fraction: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min(180, span.latitudeDelta * (1 + fraction)),
                longitudeDelta: min(360, span.longitudeDelta * (1 + fraction))
            )
        )
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(coordinate.latitude - center.latitude) <= span.latitudeDelta / 2
            && abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
    }

    /// A region tightly framing every coordinate, padded so edge stops and their labels aren't
    /// clipped. `nil` if there's nothing to fit.
    init?(fitting coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return nil }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        self.init(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.15),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.15)
            )
        )
    }
}

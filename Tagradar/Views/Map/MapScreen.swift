import MapKit
import os
import SwiftUI
import TrafikverketKit

/// The live map. On iPhone it is Apple Maps-like: full-bleed map, glass controls bottom-right and a
/// persistent bottom card for search, saved trains and details. On iPad the same card is a sidebar
/// beside the map and a selected train or station opens in an inspector on the other side.
struct MapScreen: View {
    @Environment(LiveTrainStore.self) private var live
    @Environment(StationDirectory.self) private var stations
    @Environment(AppNavigation.self) private var navigation
    @Environment(LocationManager.self) private var location
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Camera, selection and the card's trail. Owned by `RootView` so they outlive this view when
    /// the size class changes — see `MapState`.
    @Environment(MapState.self) private var mapState
    @State private var sheetPresented = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Bumped every time a station is focused. Part of the inspector stack's identity, because
    /// the signature alone is not: selecting the same station again after a train was pushed from
    /// its board would otherwise leave that train on screen instead of reopening the board.
    @State private var stationBoardEpoch = 0
    @Namespace private var mapScope

    /// Height of the collapsed card: the search field with breathing room under the grabber.
    static let collapsedSheetHeight: CGFloat = 76
    static let sheetTopPadding: CGFloat = 16
    private static let logger = Logger(subsystem: "se.tagradar.app", category: "MapScreen")

    private var isRegular: Bool {
        sizeClass == .regular
    }

    var body: some View {
        Group {
            if isRegular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task { await centerOnUserAtLaunch() }
        .onChange(of: mapState.selectedTrainID) { _, id in
            Self.logger.debug("selectedTrainID → \(id ?? "nil", privacy: .public)")
            guard let id, let train = live.train(id: id) else { return }
            mapState.selectedStation = nil
            mapState.deferredFocus = nil
            mapState.selectedKey = train.key
            push(.train(TrainSelection(key: train.key, liveID: id)), if: true)
            withAnimation(.smooth) { mapState.camera = cameraFocusing(train.clCoordinate, spanDegrees: 0.45) }
        }
        // `initial: true` because the request can be made before this view exists: `RootView`
        // reads the launch arguments and takes deep links while the onboarding screen is up, so a
        // train asked for without an API key would otherwise wait for the next live update.
        .onChange(of: navigation.pendingMapFocus, initial: true) { _, key in
            guard let key else { return }
            startFreshTrail()
            focus(on: key)
        }
        .onChange(of: navigation.pendingStationSignature, initial: true) { _, signature in
            guard let signature, let station = stations.station(signature) else { return }
            navigation.pendingStationSignature = nil
            startFreshTrail()
            focus(on: station)
        }
        .onChange(of: stations.revision) { _, _ in
            // Same reason as the pending signature above, but for a link that arrived before the
            // station it names was in the directory. `revision` fires for the disk cache and the
            // live refresh alike, where `isLoaded` only ever changes on the first of the two.
            guard let signature = navigation.pendingStationSignature,
                  let station = stations.station(signature) else { return }
            navigation.pendingStationSignature = nil
            startFreshTrail()
            focus(on: station)
        }
        .onLiveTrainsUpdate {
            if let key = navigation.pendingMapFocus {
                startFreshTrail()
                focus(on: key)
            } else if let deferred = mapState.deferredFocus {
                // Our own retry, so the card keeps whatever trail it already had.
                focus(on: deferred.key, pushingPath: deferred.pushesPath)
            } else if let key = mapState.selectedKey, mapState.selectedTrainID == nil, live.train(for: key) != nil {
                // The selected train had no live position when chosen; it just started reporting one.
                focus(on: key)
            }
        }
        .onChange(of: isRegular, initial: true) { _, regular in
            // Selection changes in the regular layout bypass the card's trail (`push` is a no-op
            // there), so when the layout comes back to compact the trail can be behind the map:
            // the card would show whatever it showed before the flip while the map has moved on.
            // Put the current selection on top so the two agree again. Appending rather than
            // resetting keeps "back" returning to what the card was showing; `push` skips the
            // append when that is already the same screen.
            //
            // `initial: true` so a view that starts out compact with a selection already in
            // `mapState` reconciles too. Harmless on a cold launch, where nothing is selected yet.
            guard !regular else { return }
            if let station = mapState.selectedStation {
                push(.station(station), if: true)
            } else if let selection = currentSelection {
                push(.train(selection), if: true)
            }
        }
        .onChange(of: mapState.sheetPath) { _, path in
            Self.logger.debug("sheetPath → \(path.count) items")
            // A shorter path than our shadow copy means the user tapped "back" (pushes already
            // grow both together, so this only fires for a pop). Trim the shadow to match, then
            // restore the map to whatever's now on top — the previous station's board, an earlier
            // train, or nothing at the root.
            guard path.count < mapState.navigationStack.routes.count else {
                if path.count > mapState.navigationStack.routes.count {
                    // Something appended without going through `push`, so the shadow is now
                    // shallower than the real stack and the next "back" would restore the wrong
                    // screen. Nothing does today; this is here so it can't fail silently.
                    Self.logger.error("sheetPath grew to \(path.count) past the shadow's \(mapState.navigationStack.routes.count)")
                }
                return
            }
            mapState.navigationStack.trim(to: path.count)
            restoreSelection()
        }
    }

    private var map: some View {
        @Bindable var mapState = mapState
        return TrainMapView(
            camera: $mapState.camera,
            visibleRegion: $mapState.visibleRegion,
            selectedTrainID: $mapState.selectedTrainID,
            selectedKey: mapState.selectedKey,
            selectedStation: mapState.selectedStation,
            onSelectStation: { focus(on: $0) },
            scope: mapScope
        )
    }

    // MARK: iPhone

    private var compactLayout: some View {
        GeometryReader { geometry in
            compactMap(containerHeight: geometry.size.height)
        }
    }

    /// Bottom padding that keeps the controls just above the card at the current detent.
    private func controlsBottomPadding(containerHeight: CGFloat) -> CGFloat {
        switch mapState.sheetDetent {
        case .medium: containerHeight * 0.55 + 40 // medium ≈ 55 % of the safe-area height
        case .large: containerHeight + 200 // pushed off-screen
        default: Self.collapsedSheetHeight + 16
        }
    }

    private func compactMap(containerHeight: CGFloat) -> some View {
        @Bindable var mapState = mapState
        return map
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    StatusPill()
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                MapControlsCluster(camera: $mapState.camera)
                    .padding(.trailing, 12)
                    .padding(.bottom, controlsBottomPadding(containerHeight: containerHeight))
                    .animation(.smooth(duration: 0.35), value: mapState.sheetDetent)
            }
            .mapScope(mapScope)
            .sheet(isPresented: $sheetPresented) {
                MapSheet(
                    path: $mapState.sheetPath,
                    detent: $mapState.sheetDetent,
                    onSelectTrain: select,
                    onSelectStation: { focus(on: $0) }
                )
                .presentationDetents([.height(Self.collapsedSheetHeight), .medium, .large], selection: $mapState.sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
    }

    // MARK: iPad

    /// Sidebar, map, inspector. The card's search and lists stay on screen beside the map, and a
    /// selected train or station opens alongside it rather than over it. In portrait the sidebar
    /// tucks away and comes back from the glass button in the corner or a swipe from the left edge.
    ///
    /// The sidebar gets constant bindings on purpose: details never push inside it here (they go to
    /// the inspector), and the card's real trail and detent are left alone for the compact layout
    /// to pick up again.
    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MapSheet(
                style: .sidebar,
                path: .constant(NavigationPath()),
                detent: .constant(.medium),
                onSelectTrain: select,
                onSelectStation: { focus(on: $0) }
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
        } detail: {
            map
                .ignoresSafeArea(edges: .top)
                .safeAreaInset(edge: .top, spacing: 0) { regularTopOverlay }
                .mapScope(mapScope)
                // The system bar would only carry the sidebar toggle, and an otherwise empty bar
                // collapses along with it; the toggle lives in the overlay instead.
                .toolbar(.hidden, for: .navigationBar)
        }
        // Attached outside the split view on purpose: inside it, the inspector's toolbar (Close,
        // Follow, Star, Share) is unified into the map column's bar, which is hidden. Out here it
        // is its own column with its own bar.
        .inspector(isPresented: inspectorBinding) {
            inspectorDetail
                .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
        }
        // Binding `columnVisibility` at all opts out of the automatic behaviour: the split view
        // resolves `.automatic` once and writes the concrete value back, after which a rotation
        // leaves the sidebar wherever it was. Landscape has the width for all three columns and
        // portrait does not, so follow the shape of the window the way Mail does.
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isWide in
            withAnimation {
                columnVisibility = isWide ? .all : .detailOnly
            }
        }
    }

    /// What the iPad inspector shows for the current selection. Stations get their board here for
    /// the same reason trains get their detail: on iPad there is no bottom card to push onto, so
    /// without this a tapped station dot would only move the camera.
    @ViewBuilder
    private var inspectorDetail: some View {
        if let station = mapState.selectedStation {
            // Keyed on the station: without this a different station would reuse this stack, so
            // the panel would keep showing a train pushed from the previous station's board.
            NavigationStack {
                // No `onSelectTrain` on purpose: unlike the iPhone card, the inspector is its own
                // navigation stack, so a train pushes on top of the board with a back button and
                // the map keeps showing the station the user is reading about. The trade-off is
                // that this stack is local, so a train opened from here is not in `MapState`: if
                // the size class then goes compact (folding an iPhone Duo, an iPad Split View
                // narrowing), the card reopens the board rather than that train. Routing the
                // selection through `MapScreen` would fix it by moving the map off the station,
                // which is the behaviour this deliberately avoids.
                StationBoardView(station: station)
                    .toolbar {
                        // The inspector has no dismiss chrome of its own, and unlike a train
                        // detail the board has no Close button, so without this the panel can
                        // only be closed by selecting something else.
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close", systemImage: "xmark", action: clearSelection)
                        }
                    }
            }
            .id("\(station.locationSignature)#\(stationBoardEpoch)")
        } else if let selection = currentSelection {
            NavigationStack {
                TrainDetailView(key: selection.key, liveID: selection.liveID, onClose: clearSelection)
            }
        }
    }

    /// Sidebar toggle, status and map controls. Settings lives in the sidebar's header, like on
    /// iPhone.
    private var regularTopOverlay: some View {
        @Bindable var mapState = mapState
        return HStack(alignment: .top, spacing: 12) {
            Button("Sidebar", systemImage: "sidebar.leading") {
                withAnimation {
                    // Tested against `.detailOnly` rather than for it: the split view resolves
                    // `.automatic` and writes the concrete value back before the first tap, but
                    // nothing documents that, and reading it the other way round would make a
                    // stale `.automatic` hide the sidebar instead of showing it.
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            .buttonStyle(.glass)
            .labelStyle(.iconOnly)
            StatusPill()
            Spacer()
            MapControlsCluster(camera: $mapState.camera)
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: Selection plumbing

    private var currentSelection: TrainSelection? {
        if mapState.selectedTrainID == nil, mapState.selectedKey == nil {
            return nil
        }
        return TrainSelection(key: mapState.selectedKey, liveID: mapState.selectedTrainID)
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { currentSelection != nil || mapState.selectedStation != nil }, set: {
            if !$0 {
                clearSelection()
            }
        })
    }

    private func clearSelection() {
        mapState.selectedTrainID = nil
        mapState.selectedKey = nil
        mapState.selectedStation = nil
        mapState.deferredFocus = nil
        startFreshTrail()
    }

    /// Empties the card's navigation trail and its shadow together. Also used when focus arrives
    /// from outside the map (a deep link, or a link from another tab): whatever the card was
    /// showing belongs to an older, unrelated bit of browsing, so "back" shouldn't walk into it.
    /// Runs in the regular size class too, where the card isn't on screen — cheap, and it keeps
    /// the two representations from ever disagreeing.
    private func startFreshTrail() {
        guard !mapState.sheetPath.isEmpty || !mapState.navigationStack.isEmpty else { return }
        mapState.sheetPath = NavigationPath()
        mapState.navigationStack.reset()
    }

    /// Re-applies whatever is now on top of the navigation stack after a "back" tap trimmed it —
    /// restoring the map's selection and camera without pushing anything new onto the
    /// (already-correct) path.
    private func restoreSelection() {
        switch mapState.navigationStack.top {
        case let .station(station):
            focus(on: station, pushingPath: false)
        case let .train(selection):
            if let key = selection.key {
                focus(on: key, pushingPath: false)
            } else {
                // A train with no advertised number (freight or service) has no key to re-focus
                // by, but its live id still selects the marker and re-centres the camera.
                mapState.selectedStation = nil
                mapState.selectedKey = nil
                mapState.selectedTrainID = selection.liveID
            }
        case nil:
            mapState.selectedTrainID = nil
            mapState.selectedKey = nil
            mapState.selectedStation = nil
            mapState.deferredFocus = nil
        }
    }

    /// Appends to the card's navigation trail, keeping `sheetPath` and its typed shadow in
    /// lockstep. Append rather than replace: selecting a train from within an already-open station
    /// board pushes on top of it, so "back" returns to the board instead of all the way to search.
    /// Does nothing in the regular size class (no card), when the caller is restoring a selection
    /// after "back" (`shouldPush` false), or when that screen is already on top.
    private func push(_ route: MapSheetRoute, if shouldPush: Bool) {
        guard shouldPush, !isRegular, mapState.navigationStack.push(route) else { return }
        mapState.sheetPath.append(route)
        mapState.sheetDetent = .medium
    }

    /// Selects a train from a list or search result: zooms to it when it has a live position.
    private func select(_ key: TrainKey) {
        focus(on: key)
    }

    /// Frames the launch camera: `MapState.defaultRegion` shifted clear of the iPhone card, then the
    /// user's surroundings when location access was already granted, at a span that shows the trains
    /// nearby. Never prompts. Each step gives way to anything that moved the camera first — the user
    /// panning, or a deep link focusing a train or station.
    private func centerOnUserAtLaunch() async {
        guard !mapState.didApplyLaunchCamera else { return }
        mapState.didApplyLaunchCamera = true
        guard mapState.camera == .region(MapState.defaultRegion), launchCameraIsUntouched else { return }
        let fallback = cameraFocusing(MapState.defaultRegion.center, spanDegrees: MapState.defaultRegion.span.latitudeDelta)
        mapState.camera = fallback
        guard location.isAuthorized, let fix = await location.currentLocation(),
              mapState.camera == fallback, launchCameraIsUntouched else { return }
        withAnimation(.smooth) {
            mapState.camera = cameraFocusing(fix.coordinate, spanDegrees: Self.launchSpanDegrees)
        }
    }

    /// Nothing has claimed the camera since launch: no pan, no selection, no deep link waiting.
    private var launchCameraIsUntouched: Bool {
        !mapState.camera.positionedByUser
            && mapState.selectedTrainID == nil && mapState.selectedKey == nil && mapState.selectedStation == nil
            && navigation.pendingMapFocus == nil && navigation.pendingStationSignature == nil
    }

    /// Around a city and its commuter lines: a few dozen trains rather than the whole country's.
    private static let launchSpanDegrees: CLLocationDegrees = 1

    /// Frames a coordinate; on iPhone the point is shifted up so the medium-height card does not cover it.
    private func cameraFocusing(_ coordinate: CLLocationCoordinate2D, spanDegrees: CLLocationDegrees) -> MapCameraPosition {
        let offset = isRegular ? 0 : spanDegrees * 0.22
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude - offset, longitude: coordinate.longitude)
        return .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)))
    }

    /// Selects a station: zooms the camera there, marks it on the map, and opens its board — used
    /// by search, quick stations and station deep links alike.
    private func focus(on station: TrainStation, pushingPath: Bool = true) {
        stationBoardEpoch += 1
        mapState.selectedTrainID = nil
        mapState.selectedKey = nil
        mapState.deferredFocus = nil
        mapState.selectedStation = station
        push(.station(station), if: pushingPath)
        if let coordinate = station.coordinate {
            withAnimation(.smooth) {
                mapState.camera = cameraFocusing(
                    CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    spanDegrees: 0.3
                )
            }
        }
    }

    private func focus(on key: TrainKey, pushingPath: Bool = true) {
        navigation.pendingMapFocus = nil
        mapState.deferredFocus = nil
        if let train = live.train(for: key) {
            mapState.selectedStation = nil
            mapState.selectedKey = key
            mapState.selectedTrainID = train.id
            // Pushed here rather than left to `selectedTrainID`'s observer, which can't fire when
            // the id is unchanged (re-selecting the same train) and doesn't know about
            // `pushingPath` (a "back" restore must not push anything).
            push(.train(TrainSelection(key: key, liveID: train.id)), if: pushingPath)
            withAnimation(.smooth) {
                mapState.camera = cameraFocusing(train.clCoordinate, spanDegrees: 0.3)
            }
        } else if live.state.isLive || !live.trains.isEmpty {
            // No live position (yet); still open the timetable.
            mapState.selectedStation = nil
            mapState.selectedKey = key
            mapState.selectedTrainID = nil
            push(.train(TrainSelection(key: key, liveID: nil)), if: pushingPath)
        } else {
            // Live data has not arrived, so whether this train is reporting a position is unknown.
            // Open the timetable anyway — `TrainDetailView` builds it from the key alone, and the
            // saved list is on screen during exactly this window, offline included, so deferring
            // would make a tap do nothing. The camera catches up when positions land; the retry
            // re-pushes the same screen, which `MapNavigationStack` drops.
            mapState.selectedStation = nil
            mapState.selectedKey = key
            mapState.selectedTrainID = nil
            push(.train(TrainSelection(key: key, liveID: nil)), if: pushingPath)
            mapState.deferredFocus = MapState.DeferredFocus(key: key, pushesPath: pushingPath)
        }
    }
}

import MapKit
import SwiftUI
import TrafikverketKit

/// The map's durable state — camera, selection and the bottom card's trail — kept outside
/// `MapScreen` so it never depends on that view keeping its identity.
///
/// `MapScreen` lays itself out differently per size class (a bottom card on iPhone, a sidebar and
/// an inspector on iPad), and a change of horizontal size class — an iPhone Plus or Max rotating
/// to landscape, an iPhone Duo opening or closing — swaps those layouts and rebuilds the views
/// inside them. Owning this object in `RootView` and reading it through the environment, the way
/// `AppNavigation` is, keeps the camera where the user left it and the selected train selected no
/// matter what gets rebuilt underneath.
@MainActor
@Observable
final class MapState {
    /// Where the map opens without a location: Stockholm–Västerås–Örebro. Not the whole country —
    /// nearly every train runs in the south, so a national view draws all of them at once, and
    /// hundreds of annotations are what makes panning and the card sluggish. `MapScreen` re-frames
    /// it at launch so the iPhone card doesn't cover its centre.
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 59.4, longitude: 16.6),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
    )

    var camera: MapCameraPosition = .region(MapState.defaultRegion)
    var visibleRegion: MKCoordinateRegion = MapState.defaultRegion
    /// Set once the launch camera has been decided (see `MapScreen.centerOnUserAtLaunch`), so a
    /// rebuilt `MapScreen` doesn't pull the camera back to the user mid-session. Per window, like
    /// the rest of this state: a new iPad window opens around the user too.
    var didApplyLaunchCamera = false
    var selectedTrainID: String?
    var selectedKey: TrainKey?
    var selectedStation: TrainStation?

    /// The iPhone card's navigation trail and its typed shadow, kept in lockstep with every push —
    /// see `MapNavigationStack`. Preserved across a size-class change too, so folding the device
    /// back to the cover display returns to the board or detail the card was showing.
    var sheetPath = NavigationPath()
    var navigationStack = MapNavigationStack()
    var sheetDetent: PresentationDetent = .medium

    /// A focus request `MapScreen` deferred because live positions hadn't arrived yet. Kept here
    /// rather than in `AppNavigation.pendingMapFocus`, which means "something outside the map
    /// asked for this" and resets the card's trail — a retry of the map's own must not do that.
    var deferredFocus: DeferredFocus?

    struct DeferredFocus {
        let key: TrainKey
        let pushesPath: Bool
    }
}

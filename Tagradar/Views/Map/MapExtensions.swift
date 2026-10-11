import MapKit
import SwiftUI

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

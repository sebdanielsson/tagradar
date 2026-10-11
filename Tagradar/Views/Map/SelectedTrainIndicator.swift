import CoreLocation
import MapKit
import SwiftUI

/// Where the selected train is while it's off-screen (or hidden under the card). Written by
/// `TrainMapView` on every camera frame and live update, read only by `SelectedTrainIndicator`: an
/// object rather than `@State` on the map, so a pan re-renders this one small view, not the map
/// with all its annotations.
@MainActor
@Observable
final class SelectedTrainTracker {
    struct Placement: Equatable {
        /// The train, in the map's coordinate space. Outside `bounds` — often far outside.
        var target: CGPoint
        /// The part of the map nothing covers: not the card, the status pill or the controls.
        var bounds: CGRect
        /// From the middle of `bounds` to the train.
        var distance: CLLocationDistance
        var trainNumber: String
        var color: Color
    }

    /// Everything the placement depends on apart from the camera, which `TrainMapView` reports
    /// frame by frame; a change to any of it re-places the indicator.
    struct Inputs: Equatable {
        let displayedAt: Date
        let selectedTrainID: String?
        let insets: EdgeInsets?
        let mapSize: CGSize
        let severity: DelayIndex.Severity?
    }

    /// `nil` while the selected train is in view, or there is none.
    private(set) var placement: Placement?
    /// The map's camera as of the last frame, for panning back with the zoom, heading and pitch
    /// kept. Not observed: nothing on screen depends on it.
    @ObservationIgnored var camera: MapCamera?

    func update(to placement: Placement?) {
        // Assigning an equal value still notifies observers.
        guard placement != self.placement else { return }
        self.placement = placement
    }

    /// A camera that puts `train` in the middle of the unobscured area, keeping the zoom, heading
    /// and pitch the user chose. `nil` before the map has reported a camera.
    func camera(showing train: LiveTrain, proxy: MapProxy, space: NamedCoordinateSpace, mapSize: CGSize) -> MapCamera? {
        guard let camera else { return nil }
        // The camera's centre is the map's middle; moving it by the train's offset from the middle
        // of the unobscured area lands the train there, card or no card.
        var center = train.clCoordinate
        if let placement {
            let point = CGPoint(
                x: mapSize.width / 2 + placement.target.x - placement.bounds.midX,
                y: mapSize.height / 2 + placement.target.y - placement.bounds.midY
            )
            // `nil` past the horizon of a pitched map; the train itself then goes to the middle.
            center = proxy.convert(point, from: space) ?? center
        }
        return MapCamera(centerCoordinate: center, distance: camera.distance, heading: camera.heading, pitch: camera.pitch)
    }

    /// Places the indicator for `train`, or hides it while the train is in view. In view means
    /// inside `bounds`, the unobscured part of the map: a train under the card is as hard to find
    /// as one off the edge.
    func update(train: LiveTrain, color: Color, proxy: MapProxy, space: NamedCoordinateSpace, bounds: CGRect) {
        // Shrunk by half the selected marker, so a train right at the edge still counts as visible.
        guard bounds.width > 0, bounds.height > 0,
              let target = proxy.convert(train.clCoordinate, to: space),
              !bounds.insetBy(dx: 14, dy: 14).contains(target),
              let middle = proxy.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: space) else {
            update(to: nil)
            return
        }
        let distance = CLLocation(latitude: middle.latitude, longitude: middle.longitude)
            .distance(from: CLLocation(latitude: train.coordinate.latitude, longitude: train.coordinate.longitude))
        update(to: Placement(
            target: target,
            bounds: bounds,
            distance: distance,
            trainNumber: train.displayNumber,
            color: color
        ))
    }
}

/// A glass pill at the edge of the map pointing towards the selected train when it's out of view,
/// with its number and how far away it is. Tapping it brings the train back into view.
struct SelectedTrainIndicator: View {
    let tracker: SelectedTrainTracker
    let action: () -> Void

    @State private var size: CGSize = .zero

    /// Space kept between the pill and the edge of the unobscured area.
    private static let margin: CGFloat = 10

    var body: some View {
        ZStack {
            if let placement = tracker.placement {
                let layout = Self.layout(for: placement, size: size)
                Button(action: action) {
                    label(placement, angle: layout.angle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .position(layout.position)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(Text("Show train \(placement.trainNumber)"))
                .accessibilityValue(Text(verbatim: Self.distance(placement.distance)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: tracker.placement == nil)
    }

    private func label(_ placement: SelectedTrainTracker.Placement, angle: Angle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(angle)
                .frame(width: 24, height: 24)
                .background(placement.color.gradient, in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
            HStack(spacing: 4) {
                Text(placement.trainNumber)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(verbatim: Self.distance(placement.distance))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .contentShape(.capsule)
    }

    /// Where the ray from the middle of the unobscured area to the train leaves it (shrunk by
    /// the pill's own size, so the pill stays whole), and which way the arrow points along it.
    private static func layout(
        for placement: SelectedTrainTracker.Placement,
        size: CGSize
    ) -> (position: CGPoint, angle: Angle) {
        let inner = placement.bounds.insetBy(dx: size.width / 2 + margin, dy: size.height / 2 + margin)
        let center = CGPoint(x: placement.bounds.midX, y: placement.bounds.midY)
        let dx = placement.target.x - center.x
        let dy = placement.target.y - center.y
        // Screen y grows downwards, and the arrow glyph points up at zero rotation.
        let angle = Angle.radians(atan2(dx, -dy))
        guard !inner.isNull, dx != 0 || dy != 0 else { return (center, angle) }
        let scaleX = dx == 0 ? CGFloat.infinity : (inner.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : (inner.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY, 1)
        return (CGPoint(x: center.x + dx * scale, y: center.y + dy * scale), angle)
    }

    /// `850 m` or `14 km` (`500 ft` or `14 mi` where the locale uses miles). The unit is picked
    /// here rather than with `usage: .road`, which in a Swedish region gives Scandinavian miles —
    /// `3 smi` — far too coarse for a train a few kilometres off-screen.
    private static func distance(_ meters: CLLocationDistance) -> String {
        let usesMiles = [Locale.MeasurementSystem.us, .uk].contains(Locale.current.measurementSystem)
        let small: UnitLength = usesMiles ? .feet : .meters
        let large: UnitLength = usesMiles ? .miles : .kilometers
        let length = Measurement(value: meters, unit: UnitLength.meters)
        // Rounded to 50 before the switch, so 990 m reads `1 km` rather than `1000 m`; never below
        // 50, since a train out of view isn't `0 m` away.
        let rounded = max(50, (length.converted(to: small).value / 50).rounded() * 50)
        let threshold = Measurement(value: 1, unit: large).converted(to: small).value
        let isSmall = usesMiles ? meters < 0.1 * 1609.344 : rounded < threshold
        let measurement = if isSmall {
            Measurement(value: rounded, unit: small)
        } else {
            length.converted(to: large)
        }
        let digits = measurement.value < 10 && measurement.unit == large ? 1 : 0
        return measurement.formatted(.measurement(
            width: .abbreviated,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0 ... digits))
        ))
    }
}

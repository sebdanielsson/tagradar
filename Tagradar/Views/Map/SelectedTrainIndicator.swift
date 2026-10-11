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

    /// `nil` while the selected train is in view, or there is none.
    private(set) var placement: Placement?

    func update(to placement: Placement?) {
        // Assigning an equal value still notifies observers.
        guard placement != self.placement else { return }
        self.placement = placement
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

    /// `850 m` or `14 km` (miles where the locale uses them). The unit is picked here rather than
    /// with `usage: .road`, which in a Swedish region gives Scandinavian miles — `3 smi` — far too
    /// coarse for a train a few kilometres off-screen.
    private static func distance(_ meters: CLLocationDistance) -> String {
        let usesMiles = [Locale.MeasurementSystem.us, .uk].contains(Locale.current.measurementSystem)
        let measurement: Measurement<UnitLength> = if usesMiles {
            Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles)
        } else if meters < 1000 {
            Measurement(value: (meters / 50).rounded() * 50, unit: .meters)
        } else {
            Measurement(value: meters, unit: UnitLength.meters).converted(to: .kilometers)
        }
        let digits = measurement.value < 10 && measurement.unit != .meters ? 1 : 0
        return measurement.formatted(.measurement(
            width: .abbreviated,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0 ... digits))
        ))
    }
}

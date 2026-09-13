import SwiftUI

/// Map marker: a coloured disc with a direction chevron and the train number.
struct TrainMarker: View {
    let train: LiveTrain
    let severity: DelayIndex.Severity
    let isSelected: Bool
    let showLabel: Bool
    var compact = false

    private var color: Color {
        train.isActive ? severity.markerColor : .gray
    }

    var body: some View {
        if compact, !isSelected {
            Circle()
                .fill(color.gradient)
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                // No shadow: this is the zoomed-out dot, drawn for hundreds of trains at once, and
                // a shadow per annotation costs an offscreen pass each while the map pans.
                .opacity(train.isStale ? 0.55 : 1)
                .accessibilityLabel(Text("Train \(train.displayNumber)"))
        } else {
            full
        }
    }

    private var full: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: isSelected ? 28 : 20, height: isSelected ? 28 : 20)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.9), lineWidth: isSelected ? 3 : 2)
                    }
                    .shadow(color: .black.opacity(0.25), radius: isSelected ? 6 : 2, y: 1)
                // A side-profile train silhouette doesn't read as "pointing" when rotated to an
                // arbitrary bearing (a 90°/180° turn just looks like a mirrored, sideways train,
                // not a heading). A plain arrow rotates cleanly through the full circle instead;
                // fall back to the stationary train glyph when there's no bearing to show.
                if let bearing = train.bearing {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: isSelected ? 14 : 10, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(Double(bearing)))
                } else {
                    Image(systemName: "train.side.front.car")
                        .font(.system(size: isSelected ? 13 : 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            if showLabel || isSelected {
                Text(train.displayNumber)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .opacity(train.isStale ? 0.55 : 1)
        .animation(.snappy, value: isSelected)
        .accessibilityLabel(Text("Train \(train.displayNumber)"))
    }
}

import SwiftUI

/// Map marker: a coloured disc with a direction chevron and the train number.
struct TrainMarker: View {
    let train: LiveTrain
    let severity: DelayIndex.Severity
    let isSelected: Bool
    let showLabel: Bool
    /// Passed in rather than read from `train.isStale`, which depends on when `body` happens to run:
    /// `TrainMapView` decides when a marker needs replacing, and this has to agree with it.
    let isStale: Bool
    var compact = false
    /// One of the user's saved trains, badged with the same yellow star the saved list uses.
    var isSaved = false
    /// A new value replays the selected marker's sonar pulse — on selection, and whenever the
    /// camera is sent back to it.
    var pulseTrigger = ""

    private var color: Color {
        Self.color(for: train, severity: severity)
    }

    /// The marker's fill, shared with the off-screen indicator so the two match.
    static func color(for train: LiveTrain, severity: DelayIndex.Severity) -> Color {
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
                .overlay(alignment: .topTrailing) {
                    if isSaved {
                        SavedBadge(size: 9).offset(x: 4, y: -4)
                    }
                }
                .opacity(isStale ? 0.55 : 1)
                .accessibilityLabel(accessibilityLabel)
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
                    // A background, so neither the halo nor the pulse moves the label below.
                    .background {
                        if isSelected {
                            Circle()
                                .fill(color.opacity(0.22))
                                .frame(width: 44, height: 44)
                            SonarPulse(color: color, trigger: pulseTrigger)
                        }
                    }
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
            .overlay(alignment: .topTrailing) {
                if isSaved {
                    SavedBadge(size: isSelected ? 14 : 12).offset(x: 5, y: -5)
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
        .opacity(isStale ? 0.55 : 1)
        .animation(.snappy, value: isSelected)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        isSaved ? Text("Saved train \(train.displayNumber)") : Text("Train \(train.displayNumber)")
    }
}

/// A yellow star on a white disc, pinned to a saved train's marker.
private struct SavedBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(.yellow)
            .frame(width: size, height: size)
            .background(.white, in: .circle)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Rings expanding out of the selected marker, so it's easy to spot among the others. Plays a few
/// times and then stops rather than looping: a repeating animation keeps the map redrawing every
/// frame for as long as a train stays selected. Skipped entirely with Reduce Motion, leaving the
/// static halo behind the marker.
private struct SonarPulse: View {
    let color: Color
    let trigger: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 is a ring at the marker's edge, 1 a ring fully expanded and faded out — also the resting
    /// state, so nothing shows before the first pulse or after the last.
    @State private var progress: CGFloat = 1

    private static let pulses = 3
    private static let duration: TimeInterval = 1.6

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
            Circle()
                .strokeBorder(color, lineWidth: 2)
        }
        .frame(width: 28, height: 28)
        .scaleEffect(1 + progress * 2)
        .opacity(1 - progress)
        .allowsHitTesting(false)
        .task(id: trigger) {
            guard !reduceMotion else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { progress = 0 }
            // Let the reset render first; animating in the same update would start from the old,
            // finished value and have nothing to animate.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.duration).repeatCount(Self.pulses, autoreverses: false)) {
                progress = 1
            }
        }
    }
}

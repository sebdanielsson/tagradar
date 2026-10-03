import SwiftUI
import TrafikverketKit

/// Vertical timeline of every stop with planned, estimated and actual times.
struct StopTimelineView: View {
    let journey: TrainJourney
    @Environment(StationDirectory.self) private var stations

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(Array(journey.stops.enumerated()), id: \.element.id) { index, stop in
                StopRow(
                    stop: stop,
                    name: stations.name(stop.signature),
                    isFirst: index == 0,
                    isLast: index == journey.stops.count - 1,
                    isNext: journey.nextStop?.id == stop.id,
                    composition: changedComposition(at: index)
                )
            }
        }
    }
}

extension StopTimelineView {
    /// Car order mostly stays the same along a run, so it is shown only where it differs from the
    /// last stop that had one.
    private func changedComposition(at index: Int) -> [String] {
        let current = journey.stops[index].composition
        let previous = journey.stops[..<index].last { !$0.composition.isEmpty }?.composition
        return current == previous ? [] : current
    }

    /// Column captions, aligned with the time cells in every row.
    private var columnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: StopRow.columnSpacing) {
            Text("Arr").frame(width: StopRow.timeColumnWidth, alignment: .leading)
            Text("Dep").frame(width: StopRow.timeColumnWidth, alignment: .leading)
            Color.clear.frame(width: StopRow.railWidth)
            Text("Station")
            Spacer()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.bottom, 10)
        .accessibilityHidden(true)
    }
}

private struct StopRow: View {
    static let timeColumnWidth: CGFloat = 46
    static let railWidth: CGFloat = 14
    static let columnSpacing: CGFloat = 10
    static let inlineInfoCount = 1

    let stop: TrainStop
    let name: String
    let isFirst: Bool
    let isLast: Bool
    let isNext: Bool
    let composition: [String]
    @State private var expanded = false

    /// Matches the stop circle's plain .secondary fill: a translucent line lets the busy, blurred
    /// map show through unevenly behind the sheet's glass background, which reads as broken dashes
    /// rather than one continuous line even though the shape itself has no gaps.
    private var lineColor: Color {
        stop.hasPassed ? .secondary : .accentColor
    }

    /// Where `rail` sits horizontally, matching the two time columns' widths and spacing it used to
    /// occupy as an `HStack` sibling.
    private static let railXOffset = timeColumnWidth * 2 + columnSpacing * 2

    var body: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            timeCell(stop.arrival)
                .frame(width: Self.timeColumnWidth, alignment: .leading)
            timeCell(stop.departure)
                .frame(width: Self.timeColumnWidth, alignment: .leading)
            Color.clear
                .frame(width: Self.railWidth)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(isNext || isFirst || isLast ? .body.weight(.semibold) : .body)
                        .foregroundStyle(stop.isCanceled ? .secondary : .primary)
                        .strikethrough(stop.isCanceled, color: .red)
                    Spacer()
                    if let track = stop.track {
                        Text("Track \(track)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    DelayBadge(delay: stop.delay, canceled: stop.isCanceled, compact: true)
                    if stop.isPartlyCanceled {
                        Text("Partly canceled").font(.caption2).foregroundStyle(.orange)
                    }
                    if isNext {
                        Text("Next stop").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(composition, id: \.self) { note in
                    Label(note, systemImage: "train.side.middle.car")
                        .labelStyle(.compactIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !stop.deviations.isEmpty || !stop.otherInformation.isEmpty {
                    let visibleInfo = expanded ? stop.otherInformation : Array(stop.otherInformation.prefix(Self.inlineInfoCount))
                    let hidden = stop.otherInformation.count - visibleInfo.count
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(stop.deviations, id: \.self) { dev in
                            Label(dev.description ?? dev.code ?? "", systemImage: "exclamationmark.circle")
                                .labelStyle(.compactIcon)
                                .foregroundStyle(.orange)
                        }
                        ForEach(visibleInfo, id: \.self) { info in
                            Label(info.description ?? info.code ?? "", systemImage: "info.circle")
                                .labelStyle(.compactIcon)
                                .foregroundStyle(.secondary)
                        }
                        if hidden > 0 {
                            Button {
                                withAnimation(.snappy) { expanded = true }
                            } label: {
                                Text("\(hidden) more")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        // Drawn as an overlay, not an HStack sibling: an overlay is proposed the row's already-
        // resolved height, so the rail's bottom segment reliably fills exactly to the next row's
        // top segment. As a sibling competing for space in the same HStack layout pass, it could
        // occasionally resolve a hair short after a scroll-triggered relayout, leaving a visible gap.
        .overlay(alignment: .topLeading) {
            rail.offset(x: Self.railXOffset)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .accessibilityElement(children: .combine)
    }

    /// One column: best-known time on top, timetable time struck through beneath when they differ.
    @ViewBuilder
    private func timeCell(_ announcement: TrainAnnouncement?) -> some View {
        if let announcement {
            let planned = announcement.advertisedTimeAtLocation
            let known = announcement.timeAtLocation ?? announcement.estimatedTimeAtLocation
            let differs = known != nil && known != planned && !announcement.isCanceled
            let isEstimate = !announcement.hasDeparted && (announcement.estimatedTimeIsPreliminary ?? false)
            VStack(alignment: .leading, spacing: 0) {
                if differs, let known {
                    Text(Format.clock(known))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DelayIndex.severity(delay: announcement.delay, canceled: false).color)
                        .italic(isEstimate)
                    Text(Format.clock(planned))
                        .font(.caption)
                        .strikethrough(color: .secondary)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Format.clock(planned))
                        .font(.callout)
                        .strikethrough(announcement.isCanceled, color: .red)
                        .foregroundStyle(announcement.isCanceled ? .secondary : .primary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .opacity(announcement.isPassengerActivity ? 1 : 0.55)
            .accessibilityHint(announcement.isPassengerActivity ? Text("") : Text("Not advertised"))
        } else {
            Text("–")
                .font(.callout)
                .foregroundStyle(.quaternary)
        }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : lineColor)
                .frame(width: 3, height: 8)
            ZStack {
                Circle()
                    .fill(stop.isCanceled ? Color.red.opacity(0.6) : (stop.hasPassed ? Color.secondary : Color.accentColor))
                    .frame(width: isNext ? 14 : 10, height: isNext ? 14 : 10)
                if stop.hasPassed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            Rectangle()
                .fill(isLast ? Color.clear : lineColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
        }
        .frame(width: Self.railWidth)
    }
}

/// Icon and text on one line with tight spacing, unlike the default label style's aligned icon column.
private struct CompactIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactIconLabelStyle {
    static var compactIcon: CompactIconLabelStyle {
        CompactIconLabelStyle()
    }
}

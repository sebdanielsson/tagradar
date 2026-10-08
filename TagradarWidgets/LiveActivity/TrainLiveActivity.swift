import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island for a followed train.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            LockScreenTrainView(context: context)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.attributes.ident, systemImage: "train.side.front.car")
                            .font(.headline)
                        if let product = context.attributes.productName {
                            Text(product).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusBadge(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.attributes.origin(context.state)) → \(context.attributes.destination(context.state))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NextStopLine(attributes: context.attributes, state: context.state)
                    JourneyProgress(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Label(context.attributes.ident, systemImage: "train.side.front.car")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            } compactTrailing: {
                CompactStatus(state: context.state)
            } minimal: {
                Image(systemName: minimalSymbol(context.state))
                    .foregroundStyle(WidgetStyle.statusColor(context.state.status, delay: context.state.delay))
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(WidgetStyle.statusColor(context.state.status, delay: context.state.delay))
        }
    }

    private func minimalSymbol(_ state: TrainActivityAttributes.ContentState) -> String {
        switch state.status {
        case .canceled: "xmark.circle.fill"
        case .arrived: "checkmark.circle.fill"
        default: "train.side.front.car"
        }
    }
}

private struct LockScreenTrainView: View {
    let context: ActivityViewContext<TrainActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(context.attributes.title, systemImage: "train.side.front.car")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(state: context.state)
            }
            Text("\(context.attributes.origin(context.state)) → \(context.attributes.destination(context.state))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            NextStopLine(attributes: context.attributes, state: context.state)
            JourneyProgress(attributes: context.attributes, state: context.state)
            HStack {
                UpcomingStopsLine(state: context.state)
                Spacer(minLength: 0)
                if context.isStale {
                    Text("Updated \(Format.clock(context.state.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
    }
}

private struct StatusBadge: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        switch state.status {
        case .canceled:
            DelayBadge(delay: nil, canceled: true)
        case .arrived:
            Label("Arrived", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .enRoute:
            DelayBadge(delay: state.delay ?? 0)
        case .scheduled:
            if let delay = state.delay, abs(delay) >= 60 {
                DelayBadge(delay: delay)
            } else {
                Label("Scheduled", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CompactStatus: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        let color = WidgetStyle.statusColor(state.status, delay: state.delay)
        switch state.status {
        case .canceled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(color)
        case .arrived:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
        default:
            Text(compactDelay)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var compactDelay: String {
        guard let delay = state.delay else { return Format.clock(state.nextStopExpected ?? state.nextStopPlanned) }
        let minutes = Int((delay / 60).rounded())
        if minutes == 0 {
            return "±0"
        }
        return minutes > 0 ? "+\(minutes)" : "−\(abs(minutes))"
    }
}

private struct NextStopLine: View {
    let attributes: TrainActivityAttributes
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            switch state.status {
            case .canceled:
                Text("The train is canceled.").font(.subheadline)
            case .arrived:
                Text("Arrived \(attributes.destination(state)) \(Format.clock(state.expectedArrival))").font(.subheadline)
            case .enRoute:
                if let next = state.nextStopName {
                    Text("Next").font(.caption).foregroundStyle(.secondary)
                    Text(next).font(.subheadline.weight(.semibold)).lineLimit(1)
                    TimePair(planned: state.nextStopPlanned, expected: state.nextStopExpected, font: .subheadline)
                    TrackChip(track: state.nextStopTrack, compact: true)
                    if let expected = state.nextStopExpected ?? state.nextStopPlanned, expected > .now {
                        // Minute granularity: the Lock Screen does not tick seconds, and it costs less.
                        Text(expected, style: .relative)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .scheduled:
                Text("Departs").font(.caption).foregroundStyle(.secondary)
                TimePair(planned: attributes.scheduledDeparture(state), expected: state.expectedDeparture, font: .subheadline.weight(.semibold))
                TrackChip(track: state.originTrack, compact: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct JourneyProgress: View {
    let attributes: TrainActivityAttributes
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if let leg = state.legInterval, leg.upperBound > .now {
                // Advances by itself until the next stop; the next refresh snaps it to the real position.
                ProgressView(timerInterval: leg, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(WidgetStyle.statusColor(state.status, delay: state.delay))
            } else {
                ProgressView(value: state.status == .arrived ? 1 : state.progress)
                    .tint(WidgetStyle.statusColor(state.status, delay: state.delay))
            }
            if state.status != .canceled {
                HStack(spacing: 3) {
                    Image(systemName: "flag.checkered").font(.caption2)
                    Text(Format.clock(state.expectedArrival ?? attributes.scheduledArrival(state)))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Then Alvesta 17:31 · Hässleholm 18:11", from the state alone.
private struct UpcomingStopsLine: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        if state.status == .enRoute, !state.upcoming.isEmpty {
            let parts = state.upcoming.prefix(2).map { "\($0.name) \(Format.clock($0.expected))" }
            Text("Then \(parts.joined(separator: " · "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

import SwiftUI

/// Origin → destination, product, operator and the headline delay.
struct JourneyHeaderSection: View {
    let journey: TrainJourney
    var liveTrain: LiveTrain?
    @Environment(StationDirectory.self) private var stations

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        if let op = journey.operatorName.map(OperatorName.display), op != title {
                            Text(op).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    statusBadge
                }

                if let stock = journey.rollingStock {
                    RollingStockView(stock: stock)
                }

                HStack(alignment: .top, spacing: 12) {
                    endpoint(
                        title: stations.name(journey.origin?.signature),
                        planned: journey.scheduledDeparture,
                        actual: journey.origin?.departure?.bestKnownTime,
                        canceled: journey.origin?.isCanceled ?? false,
                        alignment: .leading
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    endpoint(
                        title: stations.name(journey.destination?.signature),
                        planned: journey.scheduledArrival,
                        actual: journey.expectedArrival,
                        canceled: journey.destination?.isCanceled ?? false,
                        alignment: .trailing
                    )
                }

                HStack(spacing: 8) {
                    Label(Format.day(journey.key.departureDate), systemImage: "calendar")
                    if let last = journey.latestModified {
                        Label {
                            Text("Updated \(Format.relative(last))")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// Product (or operator, see `TrainJourney.productName`), else the traffic type.
    private var title: String {
        journey.productName ?? journey.typeOfTraffic ?? String(localized: "Train")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch journey.status {
        case .canceled:
            DelayBadge(delay: nil, canceled: true)
        case .arrived:
            Label("Arrived", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .enRoute:
            VStack(alignment: .trailing, spacing: 2) {
                DelayBadge(delay: journey.currentDelay)
                if let next = journey.nextStop {
                    Text("Next: \(stations.shortName(next.signature))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let last = journey.lastReport {
                    Text("Passed \(stations.shortName(last.signature)) \(Format.clock(last.time))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .scheduled:
            if journey.hasPartialCancellation {
                Label("Partly canceled", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if let delay = journey.currentDelay, abs(delay) >= 60 {
                DelayBadge(delay: delay)
            } else {
                Label("Scheduled", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func endpoint(title: String, planned: Date?, actual: Date?, canceled: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Text(Format.clock(planned))
                    .strikethrough(canceled || (actual != nil && actual != planned), color: canceled ? .red : .secondary)
                    .foregroundStyle(canceled || (actual != nil && actual != planned) ? .secondary : .primary)
                if !canceled, let actual, actual != planned {
                    Text(Format.clock(actual))
                        .foregroundStyle(DelayIndex.severity(delay: actual.timeIntervalSince(planned ?? actual), canceled: false).color)
                        .fontWeight(.semibold)
                }
            }
            .font(.body)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

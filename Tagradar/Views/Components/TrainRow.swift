import SwiftUI
import TrafikverketKit

/// One line in a departure board / search result: time, number, destination, track and delay.
struct AnnouncementRow: View {
    let announcement: TrainAnnouncement
    @Environment(StationDirectory.self) private var stations

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.clock(announcement.advertisedTimeAtLocation))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(announcement.isCanceled, color: .red)
                let est = announcement.estimatedTimeAtLocation ?? announcement.timeAtLocation
                if let est, est != announcement.advertisedTimeAtLocation, !announcement.isCanceled {
                    Text(Format.clock(est))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(DelayIndex.severity(delay: announcement.delay, canceled: false).color)
                }
            }
            .frame(minWidth: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(destinationText)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let product = announcement.displayProduct {
                        Text(product)
                    }
                    if let ident = announcement.advertisedTrainIdent {
                        Text(ident).fontWeight(.semibold)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                TrackChip(track: announcement.announcedTrack)
                DelayBadge(delay: announcement.delay, canceled: announcement.isCanceled, compact: true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var destinationText: String {
        let targets = (announcement.activityType == .arrival ? announcement.fromLocation : announcement.toLocation) ?? []
        let names = targets.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map { stations.name($0.locationName) }
        return names.isEmpty ? "–" : names.joined(separator: " / ")
    }
}

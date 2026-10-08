import ActivityKit
import Foundation

/// Live Activity payload for one followed train. The attributes are fixed for the run; the
/// content state is replaced on every refresh.
struct TrainActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Status: String, Codable, Hashable {
            case scheduled, enRoute, arrived, canceled
        }

        var status: Status
        var delaySeconds: Int?
        var nextStopName: String?
        var nextStopPlanned: Date?
        var nextStopExpected: Date?
        var nextStopTrack: String?
        var lastPassedName: String?
        var lastPassedTime: Date?
        var expectedDeparture: Date?
        var expectedArrival: Date?
        var originTrack: String?
        /// The trip's ends — the boarding and alighting stops when the user picked them. Carried in
        /// the state because the attributes are fixed when following starts, and the stops can be
        /// picked or changed after that. Optional so a state from an older build still decodes.
        var originName: String?
        var destinationName: String?
        var scheduledDeparture: Date?
        var scheduledArrival: Date?
        /// 0…1 share of the stops already passed.
        var progress: Double
        var updatedAt: Date
        /// The stops after the next one, so the activity can show what is coming without another update.
        var upcoming: [UpcomingStop] = []

        struct UpcomingStop: Codable, Hashable, Sendable {
            var name: String
            var expected: Date?
            var track: String?
        }

        /// Interval the UI can animate through between refreshes: from the last report to the next
        /// expected stop. Nil when the train is not en route or either end is unknown.
        var legInterval: ClosedRange<Date>? {
            guard status == .enRoute, let from = lastPassedTime, let to = nextStopExpected ?? nextStopPlanned, from < to else {
                return nil
            }
            return from ... to
        }

        var delay: TimeInterval? {
            delaySeconds.map(TimeInterval.init)
        }

        init(snapshot: TrainSnapshot, names: StationNames) {
            status = switch snapshot.status {
            case .canceled: .canceled
            case .arrived: .arrived
            case .enRoute: .enRoute
            case .scheduled, nil: .scheduled
            }
            delaySeconds = snapshot.delay.map { Int($0) }
            nextStopName = snapshot.nextStopSignature.map(names.shortName)
            nextStopPlanned = snapshot.nextStopPlanned
            nextStopExpected = snapshot.nextStopExpected
            nextStopTrack = snapshot.nextStopTrack
            lastPassedName = snapshot.lastPassedSignature.map(names.shortName)
            lastPassedTime = snapshot.lastPassedTime
            expectedDeparture = snapshot.expectedDeparture
            expectedArrival = snapshot.expectedArrival
            originTrack = snapshot.originTrack
            originName = names.name(snapshot.originSignature)
            destinationName = names.name(snapshot.destinationSignature)
            scheduledDeparture = snapshot.scheduledDeparture
            scheduledArrival = snapshot.scheduledArrival
            progress = snapshot.progress
            updatedAt = snapshot.updatedAt ?? .now
            upcoming = snapshot.upcomingStops.prefix(3).map {
                UpcomingStop(name: names.shortName($0.signature), expected: $0.expected, track: $0.track)
            }
        }
    }

    let trainID: String
    let ident: String
    let productName: String?
    let originName: String
    let destinationName: String
    let scheduledDeparture: Date?
    let scheduledArrival: Date?

    init(snapshot: TrainSnapshot, names: StationNames) {
        trainID = snapshot.id
        ident = snapshot.ident
        productName = snapshot.productName
        originName = names.name(snapshot.originSignature)
        destinationName = names.name(snapshot.destinationSignature)
        scheduledDeparture = snapshot.scheduledDeparture
        scheduledArrival = snapshot.scheduledArrival
    }

    var deepLink: URL {
        URL(string: "tagradar://train/\(trainID)")!
    }

    // The trip's ends as they stand now, falling back to those at follow time; see `ContentState.originName`.

    func origin(_ state: ContentState) -> String {
        state.originName ?? originName
    }

    func destination(_ state: ContentState) -> String {
        state.destinationName ?? destinationName
    }

    // A state that names its ends owns their times too, even unknown ones: falling back would show
    // the time of the stop followed with, not the one picked since. Only a state from an older build,
    // which has no names, takes them from the attributes.

    func scheduledDeparture(_ state: ContentState) -> Date? {
        state.originName == nil ? scheduledDeparture : state.scheduledDeparture
    }

    func scheduledArrival(_ state: ContentState) -> Date? {
        state.destinationName == nil ? scheduledArrival : state.scheduledArrival
    }

    var title: String {
        "\(productName ?? String(localized: "Train")) \(ident)"
    }
}

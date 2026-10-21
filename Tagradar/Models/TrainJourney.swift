import Foundation
import TrafikverketKit

/// A full train run assembled from its TrainAnnouncement rows.
struct TrainJourney: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case scheduled
        case enRoute
        case arrived
        case canceled
    }

    let key: TrainKey
    let stops: [TrainStop]
    /// One entry per consecutive pair of `stops`: the signatures the train has passed without
    /// stopping between them, in order. They pin down which line a leg actually takes where the
    /// track network offers a shorter alternative (Norrköping → Södertälje via Katrineholm, not
    /// Nyköping). Trafikverket only publishes a passing row once the train has passed, so this
    /// covers the part of the run already done.
    let passingPoints: [[String]]
    let announcements: [TrainAnnouncement]

    var id: String {
        key.id
    }

    init(key: TrainKey, announcements: [TrainAnnouncement]) {
        self.key = key
        self.announcements = announcements
        stops = Self.buildStops(from: announcements)
        passingPoints = Self.buildPassingPoints(between: stops, from: announcements)
    }

    /// `passingPoints`, except that a leg the train hasn't finished yet continues with `previous`'s
    /// — an earlier run of the same train — where that run had the same pair of stops, so the map
    /// follows the right line ahead of the train too. What this run has already passed stays: the
    /// earlier run's points are appended after the last one both share, and if this run has passed
    /// one the earlier run didn't, it's on another line today and keeps only its own.
    func routePassingPoints(previous: TrainJourney?) -> [[String]] {
        guard let previous else { return passingPoints }
        let leg = { (from: TrainStop, to: TrainStop) in "\(from.signature)|\(to.signature)" }
        var earlier: [String: [String]] = [:]
        for (pair, points) in zip(zip(previous.stops, previous.stops.dropFirst()), previous.passingPoints) where !points.isEmpty {
            earlier[leg(pair.0, pair.1)] = points
        }
        return zip(zip(stops, stops.dropFirst()), passingPoints).map { pair, passed in
            guard !pair.1.hasArrived, let ahead = earlier[leg(pair.0, pair.1)] else { return passed }
            guard let last = passed.last else { return ahead }
            guard let shared = ahead.lastIndex(of: last) else { return passed }
            return passed + ahead[(shared + 1)...]
        }
    }

    // MARK: Derived summary

    private var representative: TrainAnnouncement? {
        announcements.first { $0.activityType == .departure && $0.isPassengerActivity } ?? announcements.first
    }

    /// Latest place the train was reported at, including passing points that are not passenger stops.
    var lastReport: (signature: String, time: Date)? {
        announcements
            .compactMap { row -> (String, Date)? in
                guard let sig = row.locationSignature, let time = row.timeAtLocation else { return nil }
                return (sig, time)
            }
            .max { $0.1 < $1.1 }
    }

    /// Whether the last report came from somewhere other than an advertised stop.
    var lastReportIsPassage: Bool {
        guard let last = lastReport else { return false }
        return !allSignatures.contains(last.signature)
    }

    var productName: String? {
        representative?.displayProduct
    }

    private var product: String? {
        representative?.productInformation?.compactMap(\.description).first
    }

    var operatorName: String? {
        representative?.operator ?? representative?.trainOwner
    }

    /// Vehicle type, for the products the curated table is sure about.
    var rollingStock: RollingStock? {
        RollingStock(product: product, operator: representative?.operator, typeOfTraffic: typeOfTraffic)
    }

    var informationOwner: String? {
        representative?.informationOwner
    }

    var typeOfTraffic: String? {
        representative?.typeOfTraffic?.compactMap(\.description).first
    }

    var webLink: URL? {
        (representative?.webLink ?? representative?.mobileWebLink).flatMap(URL.init(string:))
    }

    var webLinkName: String? {
        representative?.webLinkName
    }

    var operationalTrainNumber: String? {
        representative?.operationalTrainNumber
    }

    var services: [CodeDescription] {
        var seen = Set<String>()
        return announcements.flatMap { $0.service ?? [] }.filter { seen.insert($0.description ?? $0.code ?? "").inserted }
    }

    var origin: TrainStop? {
        stops.first
    }

    var destination: TrainStop? {
        stops.last
    }

    /// Destination signatures as advertised at the origin (what the departure board shows).
    var advertisedDestinationSignatures: [String] {
        (origin?.departure?.toLocation ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.locationName)
    }

    var advertisedOriginSignatures: [String] {
        (destination?.arrival?.fromLocation ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.locationName)
    }

    var status: Status {
        if !stops.isEmpty, stops.allSatisfy(\.isCanceled) {
            return .canceled
        }
        if destination?.hasArrived == true {
            return .arrived
        }
        if stops.contains(where: \.hasPassed) {
            return .enRoute
        }
        return .scheduled
    }

    var isFullyCanceled: Bool {
        status == .canceled
    }

    var hasPartialCancellation: Bool {
        !isFullyCanceled && stops.contains { $0.isCanceled || $0.isPartlyCanceled }
    }

    /// Last stop the train has been reported at.
    var lastPassedStop: TrainStop? {
        stops.last(where: \.hasPassed)
    }

    /// Next stop the train has not yet departed from (or arrived at, for the terminus).
    var nextStop: TrainStop? {
        stops.first { !$0.hasPassed && !$0.isCanceled }
    }

    /// Current delay: taken from the next stop's estimate, else the last reported stop.
    var currentDelay: TimeInterval? {
        if let next = nextStop, let d = next.arrival?.delay ?? next.departure?.delay {
            return d
        }
        return lastPassedStop?.delay
    }

    var scheduledDeparture: Date? {
        origin?.departure?.advertisedTimeAtLocation
    }

    var scheduledArrival: Date? {
        destination?.arrival?.advertisedTimeAtLocation
    }

    var expectedArrival: Date? {
        destination?.arrival?.bestKnownTime
    }

    var latestModified: Date? {
        announcements.compactMap(\.modifiedTime).max()
    }

    var allSignatures: Set<String> {
        Set(stops.map(\.signature))
    }

    // MARK: Building

    /// Stops are the stations with at least one passenger activity (see `isPassengerActivity`). A
    /// missing arrival or departure at such a station is filled from another row when one exists
    /// (e.g. drop-off-only stops), so both columns can be shown; the view renders those muted.
    static func buildStops(from announcements: [TrainAnnouncement]) -> [TrainStop] {
        var byStation: [String: TrainStop] = [:]
        var order: [String] = []
        for a in announcements where a.isPassengerActivity {
            guard let sig = a.locationSignature else { continue }
            if byStation[sig] == nil {
                byStation[sig] = TrainStop(signature: sig)
                order.append(sig)
            }
            switch a.activityType {
            case .arrival: byStation[sig]?.arrival = a
            case .departure: byStation[sig]?.departure = a
            case nil: break
            }
        }
        for a in announcements where !a.isPassengerActivity {
            guard let sig = a.locationSignature, var stop = byStation[sig] else { continue }
            switch a.activityType {
            case .arrival where stop.arrival == nil: stop.arrival = a
            case .departure where stop.departure == nil: stop.departure = a
            default: continue
            }
            byStation[sig] = stop
        }
        return order.compactMap { byStation[$0] }.sorted { lhs, rhs in
            switch (lhs.sortTime, rhs.sortTime) {
            case let (l?, r?): l < r
            case (nil, _?): false
            case (_?, nil): true
            default: false
            }
        }
    }
}

extension TrainJourney {
    /// Assigns every non-passenger row at a station that isn't a stop to the leg whose advertised
    /// departure and arrival times bracket it, strictly — a passing point timed in the same minute
    /// as a stop could sit on either side of it. Within a leg they're ordered by when the train
    /// actually passed, to the second: several often share an advertised minute, and the API
    /// doesn't list those in running order. The odd row published ahead of the train has no such
    /// time yet and goes after them, in timetable order. A cancelled row is left out — it marks
    /// somewhere the train didn't go, e.g. on a diversion — and a point with both an arrival and a
    /// departure row is listed once.
    static func buildPassingPoints(between stops: [TrainStop], from announcements: [TrainAnnouncement]) -> [[String]] {
        let stopSignatures = Set(stops.map(\.signature))
        let passes = announcements.compactMap { row -> (signature: String, row: TrainAnnouncement)? in
            guard !row.isPassengerActivity, !row.isCanceled, let signature = row.locationSignature,
                  !stopSignatures.contains(signature) else { return nil }
            return (signature, row)
        }
        return zip(stops, stops.dropFirst()).map { from, to in
            guard let start = from.departure?.advertisedTimeAtLocation ?? from.arrival?.advertisedTimeAtLocation,
                  let end = to.arrival?.advertisedTimeAtLocation ?? to.departure?.advertisedTimeAtLocation
            else { return [] }
            let inLeg = passes
                .filter { $0.row.advertisedTimeAtLocation.map { $0 > start && $0 < end } ?? false }
                .sorted { lhs, rhs in
                    let passed = (lhs.row.timeAtLocationWithSeconds ?? .distantFuture, rhs.row.timeAtLocationWithSeconds ?? .distantFuture)
                    guard passed.0 == passed.1 else { return passed.0 < passed.1 }
                    return (lhs.row.advertisedTimeAtLocation ?? .distantFuture) < (rhs.row.advertisedTimeAtLocation ?? .distantFuture)
                }
            var leg: [String] = []
            for pass in inLeg where leg.last != pass.signature {
                leg.append(pass.signature)
            }
            return leg
        }
    }
}

extension TrainAnnouncement {
    /// Operators that publish every row unadvertised although their trains carry passengers.
    static let unadvertisedPassengerOperators = ["ATRAIN"]

    /// Whether a passenger can board or alight here. Other unadvertised rows are passing points.
    var isPassengerActivity: Bool {
        (advertised ?? true) || isUnadvertisedPassengerOperator
    }

    /// The product, or for those operators (which publish none) the operator's name.
    var displayProduct: String? {
        if let product = productInformation?.compactMap(\.description).first {
            return product
        }
        return isUnadvertisedPassengerOperator ? `operator`.map(OperatorName.display) : nil
    }

    private var isUnadvertisedPassengerOperator: Bool {
        `operator`.map(Self.unadvertisedPassengerOperators.contains) ?? false
    }
}

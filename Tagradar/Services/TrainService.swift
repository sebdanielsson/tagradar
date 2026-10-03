import Foundation
import TrafikverketKit

/// Timetable queries: whole journeys, station departure boards and traffic messages.
struct TrainService: Sendable {
    let client: TrafikverketClient

    /// Loads every advertised arrival/departure for a train run and assembles the journey.
    func journey(for key: TrainKey) async throws -> TrainJourney? {
        let rows = try await announcements(ident: key.ident, day: key.dateString)
        guard !rows.isEmpty else { return nil }
        return TrainJourney(key: key, announcements: rows)
    }

    /// Finds journeys by train number on a given day. Usually one result, occasionally more
    /// when the same number is reused by different operators.
    func search(ident: String, on date: Date) async throws -> [TrainJourney] {
        let trimmed = ident.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let day = SwedishTime.dateString(date)
        let rows = try await announcements(ident: trimmed, day: day)
        guard !rows.isEmpty else { return [] }
        // Split by operational train number in case two distinct runs share the advertised number.
        let groups = Dictionary(grouping: rows) { $0.operationalTrainNumber ?? "" }
        let key = TrainKey(ident: trimmed, departureDate: date)
        if groups.count <= 1 {
            return [TrainJourney(key: key, announcements: rows)]
        }
        return groups.values.map { TrainJourney(key: key, announcements: $0) }
            .sorted { ($0.scheduledDeparture ?? .distantFuture) < ($1.scheduledDeparture ?? .distantFuture) }
    }

    /// The query behind `journey(for:)`, exposed so a background `URLSession` can run it.
    func journeyQuery(for key: TrainKey) -> Query<TrainAnnouncement> {
        Self.announcementsQuery(ident: key.ident, day: key.dateString)
    }

    /// Assembles a journey from a raw response to `journeyQuery(for:)`.
    static func journey(for key: TrainKey, responseData: Data) throws -> TrainJourney? {
        let result = try TrafikverketClient.decode(responseData, as: TrainAnnouncement.self)
        let rows = result.objects.filter { !($0.deleted ?? false) }
        guard !rows.isEmpty else { return nil }
        return TrainJourney(key: key, announcements: rows)
    }

    private static func announcementsQuery(ident: String, day: String) -> Query<TrainAnnouncement> {
        Query<TrainAnnouncement>()
            .filter(
                .equal("AdvertisedTrainIdent", ident),
                .greaterThanOrEqual("ScheduledDepartureDateTime", "\(day)T00:00:00"),
                .lessThan("ScheduledDepartureDateTime", "\(day)T23:59:59")
            )
            .include(TrainAnnouncement.appFields)
            .orderBy(Sort("AdvertisedTimeAtLocation"))
            .limit(1000)
    }

    private func announcements(ident: String, day: String) async throws -> [TrainAnnouncement] {
        let result = try await client.fetch(Self.announcementsQuery(ident: ident, day: day))
        // Most non-advertised rows are passing points (see `isPassengerActivity`) but carry actual times, so keep them.
        return result.objects.filter { !($0.deleted ?? false) }
    }

    /// The newest active GPS report for an advertised train number, if it is currently reporting.
    func livePosition(for ident: String) async throws -> TrainPosition? {
        let query = Query<TrainPosition>()
            .filter(.equal("Train.AdvertisedTrainNumber", ident), .equal("Status.Active", true))
            .orderBy(Sort("TimeStamp", .descending))
            .limit(1)
        return try await client.fetch(query).objects.first
    }

    /// Departures from a station in a time window.
    func departures(from signature: String, start: Date, hours: Int = 6, limit: Int = 200) async throws -> [TrainAnnouncement] {
        let end = start.addingTimeInterval(TimeInterval(hours) * 3600)
        let query = Query<TrainAnnouncement>()
            .filter(
                .equal("ActivityType", "Avgang"),
                .equal("LocationSignature", signature),
                .passengerActivity,
                .greaterThanOrEqual("AdvertisedTimeAtLocation", date: start),
                .lessThan("AdvertisedTimeAtLocation", date: end)
            )
            .include(TrainAnnouncement.appFields)
            .orderBy(Sort("AdvertisedTimeAtLocation"))
            .limit(limit)
        return try await client.fetch(query).objects.filter { !($0.deleted ?? false) }
    }

    /// Arrivals to a station in a time window.
    func arrivals(to signature: String, start: Date, hours: Int = 6, limit: Int = 200) async throws -> [TrainAnnouncement] {
        let end = start.addingTimeInterval(TimeInterval(hours) * 3600)
        let query = Query<TrainAnnouncement>()
            .filter(
                .equal("ActivityType", "Ankomst"),
                .equal("LocationSignature", signature),
                .passengerActivity,
                .greaterThanOrEqual("AdvertisedTimeAtLocation", date: start),
                .lessThan("AdvertisedTimeAtLocation", date: end)
            )
            .include(TrainAnnouncement.appFields)
            .orderBy(Sort("AdvertisedTimeAtLocation"))
            .limit(limit)
        return try await client.fetch(query).objects.filter { !($0.deleted ?? false) }
    }

    /// Active sign/monitor messages at the given stations, de-duplicated by text.
    /// Monitor texts (the long-form disruption notices) win over announcements and platform signs.
    func stationMessages(at signatures: Set<String>) async throws -> [TrainStationMessage] {
        guard !signatures.isEmpty else { return [] }
        let query = Query<TrainStationMessage>()
            .filter(
                .in("LocationCode", signatures.sorted()),
                .lessThanOrEqual("StartDateTime", "$now"),
                .or([.greaterThanOrEqual("EndDateTime", "$now"), .exists("EndDateTime", false)]),
                .equal("Deleted", false)
            )
            .orderBy(Sort("StartDateTime", .descending))
            .limit(200)
        let rows = try await client.fetch(query).objects.filter(\.isActive)
        let rank: (TrainStationMessage) -> Int = { $0.mediaType == "Monitor" ? 0 : ($0.mediaType == "Utrop" ? 1 : 2) }
        var seen = Set<String>()
        return rows
            .sorted { (rank($0), $1.startDateTime ?? .distantPast) < (rank($1), $0.startDateTime ?? .distantPast) }
            .filter { seen.insert(Self.normalized($0.displayText)).inserted }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

extension Filter {
    /// Server-side `TrainAnnouncement.isPassengerActivity`.
    static let passengerActivity: Filter = .or([
        .equal("Advertised", true),
        .in("Operator", TrainAnnouncement.unadvertisedPassengerOperators),
    ])
}

import Foundation
@testable import Tagradar
import Testing
import TrafikverketKit

@Suite("Journey assembly")
struct TrainJourneyTests {
    private func announcement(
        id: String, type: TrainAnnouncement.ActivityType, station: String, advertised: String,
        estimated: String? = nil, actual: String? = nil, canceled: Bool = false, isAdvertised: Bool? = nil,
        composition: String? = nil, product: String? = "SJ Snabbtåg", operator operatorCode: String? = nil
    ) throws -> TrainAnnouncement {
        var json: [String: Any] = [
            "ActivityId": id,
            "ActivityType": type.rawValue,
            "LocationSignature": station,
            "AdvertisedTimeAtLocation": "2026-09-02T\(advertised):00.000+02:00",
            "AdvertisedTrainIdent": "520",
            "Canceled": canceled,
            "ScheduledDepartureDateTime": "2026-09-02T00:00:00.000+02:00",
            "ToLocation": [["LocationName": "G", "Order": 0, "Priority": 1]],
        ]
        if let product {
            json["ProductInformation"] = [["Code": "PNA047", "Description": product]]
        }
        if let operatorCode {
            json["Operator"] = operatorCode
        }
        if let composition {
            json["TrainComposition"] = [["Code": "TNA001", "Description": composition]]
        }
        if let isAdvertised {
            json["Advertised"] = isAdvertised
        }
        if let estimated {
            json["EstimatedTimeAtLocation"] = "2026-09-02T\(estimated):00.000+02:00"
        }
        if let actual {
            json["TimeAtLocation"] = "2026-09-02T\(actual):00.000+02:00"
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder.trafikverket.decode(TrainAnnouncement.self, from: data)
    }

    private func sampleJourney() throws -> TrainJourney {
        let rows = try [
            announcement(id: "1", type: .departure, station: "Cst", advertised: "06:21", actual: "06:23"),
            announcement(id: "2", type: .arrival, station: "Sö", advertised: "06:38", actual: "06:41"),
            announcement(id: "3", type: .departure, station: "Sö", advertised: "06:40", actual: "06:42"),
            announcement(id: "4", type: .arrival, station: "K", advertised: "07:31", estimated: "07:36"),
            announcement(id: "5", type: .departure, station: "K", advertised: "07:33", estimated: "07:37"),
            announcement(id: "6", type: .arrival, station: "G", advertised: "09:20", estimated: "09:24"),
        ]
        // Shuffle to prove sorting is by time, not input order.
        return TrainJourney(key: TrainKey(ident: "520", departureDate: rows[0].scheduledDepartureDateTime!), announcements: rows.reversed())
    }

    @Test func groupsArrivalsAndDeparturesPerStation() throws {
        let journey = try sampleJourney()
        #expect(journey.stops.map(\.signature) == ["Cst", "Sö", "K", "G"])
        #expect(journey.origin?.isOrigin == true)
        #expect(journey.destination?.isTerminus == true)
        #expect(journey.stops[1].arrival != nil && journey.stops[1].departure != nil)
    }

    @Test func arlandaExpressRowsAreStops() throws {
        /// Arlanda Express publishes every row with Advertised = false and no product.
        func row(_ id: String, _ type: TrainAnnouncement.ActivityType, _ station: String, _ time: String) throws -> TrainAnnouncement {
            try announcement(
                id: id, type: type, station: station, advertised: time, isAdvertised: false, product: nil, operator: "ATRAIN"
            )
        }
        let rows = try [
            row("1", .departure, "Arnn", "06:20"),
            row("2", .arrival, "Arns", "06:22"),
            row("3", .departure, "Arns", "06:22"),
            row("4", .arrival, "Cst", "06:40"),
        ]
        let journey = try TrainJourney(
            key: TrainKey(ident: "7909", departureDate: #require(rows[0].scheduledDepartureDateTime)),
            announcements: rows
        )
        #expect(journey.stops.map(\.signature) == ["Arnn", "Arns", "Cst"])
        #expect(journey.productName == "Arlanda Express")
        #expect(journey.rollingStock == .x3)
    }

    @Test func otherUnadvertisedRunsHaveNoStops() throws {
        // E.g. SJ positioning runs: every row is a passing point.
        let rows = try [
            announcement(id: "1", type: .departure, station: "Av", advertised: "06:20", isAdvertised: false, product: nil, operator: "SJ"),
            announcement(id: "2", type: .arrival, station: "Cst", advertised: "08:20", isAdvertised: false, product: nil, operator: "SJ"),
        ]
        let journey = try TrainJourney(
            key: TrainKey(ident: "502", departureDate: #require(rows[0].scheduledDepartureDateTime)),
            announcements: rows
        )
        #expect(journey.stops.isEmpty)
        // Only operators without products fall back to their name; others keep stored products.
        #expect(journey.productName == nil)
    }

    @Test func passingPointsStayOffAdvertisedRuns() throws {
        let rows = try [
            announcement(id: "1", type: .departure, station: "Cst", advertised: "06:21"),
            announcement(id: "2", type: .departure, station: "Sod", advertised: "06:30", isAdvertised: false),
            announcement(id: "3", type: .arrival, station: "G", advertised: "09:20"),
        ]
        let journey = try TrainJourney(
            key: TrainKey(ident: "520", departureDate: #require(rows[0].scheduledDepartureDateTime)),
            announcements: rows
        )
        #expect(journey.stops.map(\.signature) == ["Cst", "G"])
    }

    @Test func compositionFallsBackToArrivalRow() throws {
        // SJ 30 at Mdn carries the car order on its arrival row only.
        let rows = try [
            announcement(id: "1", type: .arrival, station: "Mdn", advertised: "06:20", composition: "Vagnsordning 15,14,13"),
            announcement(id: "2", type: .departure, station: "Mdn", advertised: "06:25"),
            announcement(id: "3", type: .arrival, station: "Cst", advertised: "06:40", composition: "A"),
            announcement(id: "4", type: .departure, station: "Cst", advertised: "06:45", composition: "B"),
        ]
        let journey = try TrainJourney(
            key: TrainKey(ident: "30", departureDate: #require(rows[0].scheduledDepartureDateTime)),
            announcements: rows
        )
        #expect(journey.stops.map(\.composition) == [["Vagnsordning 15,14,13"], ["B"]])
    }

    @Test func derivesStatusAndDelay() throws {
        let journey = try sampleJourney()
        #expect(journey.status == .enRoute)
        #expect(journey.lastPassedStop?.signature == "Sö")
        #expect(journey.nextStop?.signature == "K")
        #expect(journey.currentDelay == 5 * 60.0)
        #expect(journey.productName == "SJ Snabbtåg")
        #expect(journey.expectedArrival == journey.destination?.arrival?.estimatedTimeAtLocation)
    }

    @Test func fullyCanceledJourney() throws {
        let rows = try [
            announcement(id: "1", type: .departure, station: "Cst", advertised: "06:21", canceled: true),
            announcement(id: "2", type: .arrival, station: "G", advertised: "09:20", canceled: true),
        ]
        let journey = TrainJourney(key: .today("520"), announcements: rows)
        #expect(journey.status == .canceled)
        #expect(journey.isFullyCanceled)
    }

    @Test func trainKeyRoundTrips() {
        let key = TrainKey(ident: " 520 ", departureDate: Date(timeIntervalSince1970: 1_788_000_000))
        #expect(key.ident == "520")
        let restored = TrainKey(id: key.id)
        #expect(restored == key)
        #expect(TrainKey(id: "garbage") == nil)
    }

    @Test func delaySeverityThresholds() {
        #expect(DelayIndex.severity(delay: nil, canceled: false) == .unknown)
        #expect(DelayIndex.severity(delay: 60, canceled: false) == .onTime)
        #expect(DelayIndex.severity(delay: 5 * 60, canceled: false) == .minor)
        #expect(DelayIndex.severity(delay: 20 * 60, canceled: false) == .major)
        #expect(DelayIndex.severity(delay: 0, canceled: true) == .canceled)
    }

    @Test func formatsDelays() {
        #expect(Format.delay(nil) == nil)
        #expect(Format.delay(20) == String(localized: "On time"))
        #expect(Format.delay(5 * 60) == String(localized: "+5 min"))
        #expect(Format.delay(-2 * 60) == String(localized: "−2 min"))
    }
}

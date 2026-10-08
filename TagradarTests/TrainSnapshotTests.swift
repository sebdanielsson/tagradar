import Foundation
@testable import Tagradar
import Testing
import TrafikverketKit

/// Builds a four-stop run Cst → U → Gä → Suc with controllable times.
enum SampleRun {
    static let key = TrainKey(ident: "837", departureDate: TRVDateParserBridge.date(fromDay: "2026-09-05")!)

    static func row(
        _ id: String, _ type: TrainAnnouncement.ActivityType, at station: String, planned: String,
        estimated: String? = nil, actual: String? = nil, track: String = "1", canceled: Bool = false
    ) throws -> TrainAnnouncement {
        var json: [String: Any] = [
            "ActivityId": id,
            "ActivityType": type.rawValue,
            "Advertised": true,
            "LocationSignature": station,
            "AdvertisedTimeAtLocation": "2026-09-05T\(planned):00.000+02:00",
            "AdvertisedTrainIdent": "837",
            "Canceled": canceled,
            "TrackAtLocation": track,
            "ScheduledDepartureDateTime": "2026-09-05T00:00:00.000+02:00",
            "ProductInformation": [["Code": "PNA047", "Description": "SJ Snabbtåg"]],
        ]
        if let estimated {
            json["EstimatedTimeAtLocation"] = "2026-09-05T\(estimated):00.000+02:00"
        }
        if let actual {
            json["TimeAtLocation"] = "2026-09-05T\(actual):00.000+02:00"
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder.trafikverket.decode(TrainAnnouncement.self, from: data)
    }

    /// Origin left 10 min late; the delay is expected to be recovered before Gävle.
    static func lateFromOriginRecoveringLater() throws -> TrainJourney {
        try TrainJourney(key: key, announcements: [
            row("1", .departure, at: "Cst", planned: "10:00", actual: "10:10"),
            row("2", .arrival, at: "U", planned: "10:40", estimated: "10:48"),
            row("3", .departure, at: "U", planned: "10:42", estimated: "10:49"),
            row("4", .arrival, at: "Gä", planned: "11:30", estimated: "11:30"),
            row("5", .departure, at: "Gä", planned: "11:32", estimated: "11:32", track: "3"),
            row("6", .arrival, at: "Suc", planned: "13:00", estimated: "13:00"),
        ])
    }
}

@Suite("Trip segment snapshots")
struct TrainSnapshotTests {
    @Test("Whole run reports the train's own delay and endpoints")
    func wholeRun() throws {
        let snapshot = try TrainSnapshot(journey: SampleRun.lateFromOriginRecoveringLater())
        #expect(snapshot.originSignature == "Cst")
        #expect(snapshot.destinationSignature == "Suc")
        #expect(snapshot.status == .enRoute)
        #expect(snapshot.nextStopSignature == "U")
        #expect(snapshot.delay == 480.0)
    }

    @Test("Boarding at a later station uses that station's departure delay")
    func boardingLater() throws {
        let segment = TripSegment(boarding: "U", alighting: nil)
        let snapshot = try TrainSnapshot(journey: SampleRun.lateFromOriginRecoveringLater(), segment: segment)
        #expect(snapshot.originSignature == "U")
        #expect(snapshot.destinationSignature == "Suc")
        // The user has not boarded yet, so the run counts as scheduled for them.
        #expect(snapshot.status == .scheduled)
        #expect(snapshot.delay == 420.0)
        #expect(snapshot.nextStopSignature == nil)
    }

    @Test("A delay that is recovered before the boarding station is not a delay for the user")
    func recoveredBeforeBoarding() throws {
        let segment = TripSegment(boarding: "Gä", alighting: "Suc")
        let snapshot = try TrainSnapshot(journey: SampleRun.lateFromOriginRecoveringLater(), segment: segment)
        #expect(snapshot.status == .scheduled)
        #expect(snapshot.delay == 0.0)
        #expect(snapshot.originTrack == "3")
        #expect(Format.clock(snapshot.scheduledDeparture) == "11:32")
        #expect(Format.clock(snapshot.scheduledArrival) == "13:00")
    }

    @Test("Reaching the alighting station counts as arrived even though the train continues")
    func arrivedAtAlighting() throws {
        let journey = try TrainJourney(key: SampleRun.key, announcements: [
            SampleRun.row("1", .departure, at: "Cst", planned: "10:00", actual: "10:00"),
            SampleRun.row("2", .arrival, at: "U", planned: "10:40", actual: "10:45"),
            SampleRun.row("3", .departure, at: "U", planned: "10:42", actual: "10:47"),
            SampleRun.row("4", .arrival, at: "Gä", planned: "11:30", estimated: "11:50"),
            SampleRun.row("6", .arrival, at: "Suc", planned: "13:00", estimated: "13:20"),
        ])
        let snapshot = TrainSnapshot(journey: journey, segment: TripSegment(boarding: "Cst", alighting: "U"))
        #expect(snapshot.status == .arrived)
        #expect(snapshot.delay == 300.0)
        #expect(snapshot.progress == 1)
    }

    @Test("The track to show is the boarding stop's until the train is boarded, then the next stop's")
    func trackToShow() {
        // Waiting to board: the track the train leaves the boarding stop from.
        #expect(running(.scheduled).currentTrack == "3")
        // Aboard: the track it pulls in at next.
        #expect(running(.enRoute).currentTrack == "2")
        #expect(running(.arrived).currentTrack == nil)
        #expect(running(.canceled).currentTrack == nil)
        // Nothing reported an arrival, so the run is still `.scheduled` — but it is long over and
        // its track is as old as the rest of it.
        let stale = running(.scheduled, arrivingIn: -6 * 3600)
        #expect(stale.isOver)
        #expect(stale.currentTrack == nil)
    }

    /// A live snapshot around `now`, so the rules that ask whether the trip is over see a trip
    /// that is not. Tracks differ by role: 3 to leave the boarding stop, 2 to pull in at the next.
    private func running(_ status: TrainJourney.Status, arrivingIn seconds: TimeInterval = 3600) -> TrainSnapshot {
        var snapshot = TrainSnapshot(favorite: FavoriteTrain(key: TrainKey(ident: "837", departureDate: .now), journey: nil))
        snapshot.status = status
        snapshot.scheduledArrival = .now.addingTimeInterval(seconds)
        snapshot.originTrack = "3"
        snapshot.nextStopTrack = "2"
        return snapshot
    }

    @Test("A stop it pulls into is quoted by its arrival track, one you board by its departure track")
    func arrivalAndDepartureTracksDiffer() throws {
        // Uppsala takes the train in on 2 and lets it out from 4; at Gävle it is 6 in, 3 out.
        let journey = try TrainJourney(key: SampleRun.key, announcements: [
            SampleRun.row("1", .departure, at: "Cst", planned: "10:00", actual: "10:10"),
            SampleRun.row("2", .arrival, at: "U", planned: "10:40", estimated: "10:48", track: "2"),
            SampleRun.row("3", .departure, at: "U", planned: "10:42", estimated: "10:49", track: "4"),
            SampleRun.row("4", .arrival, at: "Gä", planned: "11:30", estimated: "11:30", track: "6"),
            SampleRun.row("5", .departure, at: "Gä", planned: "11:32", estimated: "11:32", track: "3"),
            SampleRun.row("6", .arrival, at: "Suc", planned: "13:00", estimated: "13:00"),
        ])
        let aboard = TrainSnapshot(journey: journey)
        #expect(aboard.nextStopSignature == "U")
        #expect(aboard.nextStopTrack == "2")
        #expect(aboard.upcomingStops.first?.signature == "Gä")
        #expect(aboard.upcomingStops.first?.track == "6")
        // Boarding at Gävle is the other way round: the platform the train leaves from.
        #expect(TrainSnapshot(journey: journey, segment: TripSegment(boarding: "Gä", alighting: "Suc")).originTrack == "3")
    }

    @Test("Segment with unknown or reversed stations falls back to the whole run")
    func invalidSegment() throws {
        let stops = try SampleRun.lateFromOriginRecoveringLater().stops
        #expect(TripSegment(boarding: "Suc", alighting: "Cst")?.range(in: stops) == 0 ... 3)
        #expect(TripSegment(boarding: "Xyz", alighting: nil)?.range(in: stops) == 0 ... 3)
        #expect(TripSegment(boarding: nil, alighting: nil) == nil)
    }
}

@Suite("Alert rules")
struct TrainAlertEngineTests {
    private func snapshot(
        delayMinutes: Int?,
        status: TrainJourney.Status = .scheduled,
        track: String? = "1",
        canceled: Bool = false
    ) -> TrainSnapshot {
        var s = TrainSnapshot(favorite: FavoriteTrain(key: SampleRun.key, journey: nil))
        s.delay = delayMinutes.map { TimeInterval($0 * 60) }
        s.status = canceled ? .canceled : status
        s.originTrack = track
        return s
    }

    @Test("First sighting never notifies but records the state")
    func firstSighting() {
        let (alerts, state) = TrainAlertEngine.evaluate(previous: nil, current: snapshot(delayMinutes: 12))
        #expect(alerts.isEmpty)
        #expect(state.delayMinutes == 12)
    }

    @Test("Small changes are ignored, five minutes or more notify once")
    func delayThreshold() {
        var (alerts, state) = TrainAlertEngine.evaluate(previous: nil, current: snapshot(delayMinutes: 0))
        (alerts, state) = TrainAlertEngine.evaluate(previous: state, current: snapshot(delayMinutes: 3))
        #expect(alerts.isEmpty)
        #expect(state.delayMinutes == 0, "reference stays at the last notified value")
        (alerts, state) = TrainAlertEngine.evaluate(previous: state, current: snapshot(delayMinutes: 6))
        #expect(alerts == [.delay(minutes: 6, previous: 0)])
        (alerts, state) = TrainAlertEngine.evaluate(previous: state, current: snapshot(delayMinutes: 8))
        #expect(alerts.isEmpty)
        (alerts, _) = TrainAlertEngine.evaluate(previous: state, current: snapshot(delayMinutes: 1))
        #expect(alerts == [.backOnTime])
    }

    @Test("Cancellation, track change and arrival")
    func otherKinds() {
        let (_, initial) = TrainAlertEngine.evaluate(previous: nil, current: snapshot(delayMinutes: 0, track: "1"))
        #expect(TrainAlertEngine.evaluate(previous: initial, current: snapshot(delayMinutes: 0, canceled: true)).alerts == [.canceled])
        #expect(TrainAlertEngine.evaluate(previous: initial, current: snapshot(delayMinutes: 0, track: "7a")).alerts == [.trackChanged(
            from: "1",
            to: "7a"
        )])
        let (arrivedAlerts, arrivedState) = TrainAlertEngine.evaluate(
            previous: initial,
            current: snapshot(delayMinutes: 2, status: .arrived)
        )
        #expect(arrivedAlerts == [.arrived(delayMinutes: 2)])
        // Nothing more once the user's part of the trip is over.
        #expect(TrainAlertEngine.evaluate(previous: arrivedState, current: snapshot(delayMinutes: 30, status: .enRoute)).alerts.isEmpty)
    }

    @Test("Track changes after boarding are not reported")
    func trackAfterBoarding() {
        let (_, initial) = TrainAlertEngine.evaluate(previous: nil, current: snapshot(delayMinutes: 0, status: .enRoute, track: "1"))
        #expect(TrainAlertEngine.evaluate(previous: initial, current: snapshot(delayMinutes: 0, status: .enRoute, track: "2")).alerts
            .isEmpty)
    }
}

@Suite("Live Activity background cadence")
struct ActivityRefreshIntervalTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func state(status: TrainJourney.Status, departureIn: TimeInterval = 0) -> TrainActivityAttributes.ContentState {
        var snapshot = TrainSnapshot(favorite: FavoriteTrain(key: SampleRun.key, journey: nil))
        snapshot.status = status
        snapshot.expectedDeparture = now.addingTimeInterval(departureIn)
        return TrainActivityAttributes.ContentState(snapshot: snapshot, names: .empty)
    }

    private func interval(_ status: TrainJourney.Status, departureIn: TimeInterval = 0) -> TimeInterval? {
        ActivityBackgroundRefresher.interval(for: state(status: status, departureIn: departureIn), now: now)
    }

    @Test("The pre-scheduled horizon covers the trip a minute at a time and stops after arrival")
    func horizon() throws {
        var snapshot = TrainSnapshot(favorite: FavoriteTrain(key: SampleRun.key, journey: nil))
        snapshot.status = .enRoute
        snapshot.expectedDeparture = now.addingTimeInterval(-30 * 60)
        snapshot.expectedArrival = now.addingTimeInterval(40 * 60)
        let dates = ActivityBackgroundRefresher.pollDates(
            for: TrainActivityAttributes.ContentState(snapshot: snapshot, names: .empty),
            now: now
        )
        #expect(dates.first == now.addingTimeInterval(60))
        #expect(dates.count == 65, "40 min to arrival plus 25 min grace, one per minute")
        #expect(try #require(dates.last) <= now.addingTimeInterval(65 * 60))

        var waiting = TrainSnapshot(favorite: FavoriteTrain(key: SampleRun.key, journey: nil))
        waiting.status = .scheduled
        waiting.expectedDeparture = now.addingTimeInterval(2 * 3600)
        waiting.expectedArrival = now.addingTimeInterval(3 * 3600)
        let sparse = ActivityBackgroundRefresher.pollDates(
            for: TrainActivityAttributes.ContentState(snapshot: waiting, names: .empty),
            now: now
        )
        #expect(sparse.first == now.addingTimeInterval(30 * 60), "a quarter of the wait when far away")
        #expect(sparse.count < 120)
        #expect(sparse.count > 60, "still one a minute once the train is running")

        var done = snapshot
        done.status = .arrived
        #expect(ActivityBackgroundRefresher.pollDates(for: TrainActivityAttributes.ContentState(snapshot: done, names: .empty), now: now)
            .isEmpty)
    }

    @Test("Once a minute while running, slower while waiting, off when done")
    func intervals() {
        #expect(interval(.enRoute) == 60)
        #expect(interval(.scheduled, departureIn: 20 * 60) == 180)
        #expect(interval(.scheduled, departureIn: 8 * 3600) == 3600)
        #expect(interval(.scheduled, departureIn: 2 * 3600) == 1800)
        #expect(interval(.arrived) == nil)
        #expect(interval(.canceled) == nil)
    }
}

@Suite("Live Activity trip ends")
struct ActivityTripEndsTests {
    @Test("Stops picked after following reach the activity through the state")
    func segmentPickedAfterFollowing() throws {
        let journey = try SampleRun.lateFromOriginRecoveringLater()
        let attributes = TrainActivityAttributes(snapshot: TrainSnapshot(journey: journey), names: .empty)
        let state = TrainActivityAttributes.ContentState(
            snapshot: TrainSnapshot(journey: journey, segment: TripSegment(boarding: "U", alighting: "Gä")),
            names: .empty
        )
        #expect(attributes.destinationName == "Suc")
        #expect(attributes.origin(state) == "U")
        #expect(attributes.destination(state) == "Gä")
        #expect(Format.clock(attributes.scheduledDeparture(state)) == "10:42")
        #expect(Format.clock(attributes.scheduledArrival(state)) == "11:30")
    }
}

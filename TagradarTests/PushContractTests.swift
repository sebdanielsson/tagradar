import Foundation
@testable import Tagradar
import Testing
import TrafikverketKit

/// Runs the push server's contract fixtures (server/test/fixtures/contract) through the app's own
/// `TrainSnapshot` and `ContentState`, and decodes the server's expected output the way ActivityKit
/// does. If this fails, the server and the app disagree about what an activity should show.
@Suite("Push server contract")
struct PushContractTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "server/test/fixtures/contract")

    static var fixtures: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test("The fixtures are there")
    func fixturesFound() {
        #expect(Self.fixtures.count >= 5)
    }

    @Test("The server's content state matches the app's", arguments: fixtures)
    func contentState(file: String) throws {
        let fixture = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.directory.appending(path: file))) as? [String: Any]
        )
        func json(_ key: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: #require(fixture[key]), options: .fragmentsAllowed)
        }
        let trainID = try #require(fixture["trainId"] as? String)
        let key = try #require(TrainKey(id: trainID))
        let segment = try JSONDecoder().decode(TripSegment?.self, from: json("segment"))
        let rows = try TrafikverketClient.decode(json("response"), as: TrainAnnouncement.self).objects.filter { !($0.deleted ?? false) }
        let stations = try JSONDecoder.trafikverket.decode([TrainStation].self, from: json("stations"))
        let names = StationNames(stations: Dictionary(stations.map { ($0.locationSignature, $0) }, uniquingKeysWith: { a, _ in a }))

        let snapshot = TrainSnapshot(journey: TrainJourney(key: key, announcements: rows), segment: segment)
        let actual = TrainActivityAttributes.ContentState(snapshot: snapshot, names: names)
        // Exactly what ActivityKit does with a push's `content-state`.
        let expected = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: json("expected"))
        #expect(actual == expected)
    }
}

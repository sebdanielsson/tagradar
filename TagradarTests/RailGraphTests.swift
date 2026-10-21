import CoreLocation
@testable import Tagradar
import Testing

/// Small synthetic network, independent of the real bundled data:
///
/// ```
///        A(0) --5-- J(1) --5-- B(2) --4-- C(3)
///          \_____________3_____/
///                (via M)
/// ```
///
/// `A→B` has two paths: 10 via the junction `J`, or 3 direct via `M` — the direct one should
/// always win unless a leg is routed through `J` explicitly. `D(4)` has no edges, so it's
/// reachable by signature but not by track.
enum RailGraphFixture {
    static let a = CLLocationCoordinate2D(latitude: 60.0, longitude: 18.0)
    static let j = CLLocationCoordinate2D(latitude: 60.1, longitude: 18.0)
    static let b = CLLocationCoordinate2D(latitude: 60.2, longitude: 18.0)
    static let c = CLLocationCoordinate2D(latitude: 60.3, longitude: 18.0)
    static let d = CLLocationCoordinate2D(latitude: 61.0, longitude: 18.0)
    static let m = CLLocationCoordinate2D(latitude: 60.15, longitude: 18.05)

    /// Node indices: 0=A, 1=J, 2=B, 3=C, 4=D (isolated).
    static let graph = RailGraph(
        nodeCoordinates: [a, j, b, c, d],
        edges: [
            RailGraph.Edge(points: [a, j], length: 5),
            RailGraph.Edge(points: [j, b], length: 5),
            RailGraph.Edge(points: [a, m, b], length: 3),
            RailGraph.Edge(points: [b, c], length: 4),
        ],
        adjacency: [
            [ // A(0)
                RailGraph.Adjacency(to: 1, edgeIndex: 0, forward: true),
                RailGraph.Adjacency(to: 2, edgeIndex: 2, forward: true),
            ],
            [ // J(1)
                RailGraph.Adjacency(to: 0, edgeIndex: 0, forward: false),
                RailGraph.Adjacency(to: 2, edgeIndex: 1, forward: true),
            ],
            [ // B(2)
                RailGraph.Adjacency(to: 1, edgeIndex: 1, forward: false),
                RailGraph.Adjacency(to: 0, edgeIndex: 2, forward: false),
                RailGraph.Adjacency(to: 3, edgeIndex: 3, forward: true),
            ],
            [ // C(3)
                RailGraph.Adjacency(to: 2, edgeIndex: 3, forward: false),
            ],
            [], // D(4) — isolated
        ],
        stationNode: ["A": 0, "J": 1, "B": 2, "C": 3, "D": 4]
    )
}

/// Three nodes where the direct A–B edge is discovered first (it's listed first in A's adjacency)
/// but the two short hops via X are cheaper. Only a correctly ordered heap pops X before the
/// already-queued B, so this pins the priority queue, not just the relaxation logic.
enum RailGraphDetourFixture {
    static let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
    static let x = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1)
    static let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)

    static let graph = RailGraph(
        nodeCoordinates: [a, x, b],
        edges: [
            RailGraph.Edge(points: [a, b], length: 10),
            RailGraph.Edge(points: [a, x], length: 1),
            RailGraph.Edge(points: [x, b], length: 1),
        ],
        adjacency: [
            [RailGraph.Adjacency(to: 2, edgeIndex: 0, forward: true), RailGraph.Adjacency(to: 1, edgeIndex: 1, forward: true)],
            [RailGraph.Adjacency(to: 0, edgeIndex: 1, forward: false), RailGraph.Adjacency(to: 2, edgeIndex: 2, forward: true)],
            [RailGraph.Adjacency(to: 0, edgeIndex: 0, forward: false), RailGraph.Adjacency(to: 1, edgeIndex: 2, forward: false)],
        ],
        stationNode: ["A": 0, "B": 2]
    )
}

/// A straight line `A–X–B` with two stations on spurs off `X`: `N` 300 m away, as a station
/// snapped to a siding or the other track sits beside the line, and `F` 2 km away. Neither is on
/// the way from `A` to `B`, so routing through either would go out and back.
enum RailGraphSpurFixture {
    static let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
    static let x = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.0)
    static let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)
    static let n = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.0052)
    static let f = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.035)

    static let graph = RailGraph(
        nodeCoordinates: [a, x, b, n, f],
        edges: [
            RailGraph.Edge(points: [a, x], length: 11000),
            RailGraph.Edge(points: [x, b], length: 11000),
            RailGraph.Edge(points: [x, n], length: 300),
            RailGraph.Edge(points: [x, f], length: 2000),
        ],
        adjacency: [
            [RailGraph.Adjacency(to: 1, edgeIndex: 0, forward: true)],
            [
                RailGraph.Adjacency(to: 0, edgeIndex: 0, forward: false),
                RailGraph.Adjacency(to: 2, edgeIndex: 1, forward: true),
                RailGraph.Adjacency(to: 3, edgeIndex: 2, forward: true),
                RailGraph.Adjacency(to: 4, edgeIndex: 3, forward: true),
            ],
            [RailGraph.Adjacency(to: 1, edgeIndex: 1, forward: false)],
            [RailGraph.Adjacency(to: 1, edgeIndex: 2, forward: false)],
            [RailGraph.Adjacency(to: 1, edgeIndex: 3, forward: false)],
        ],
        stationNode: ["A": 0, "B": 2, "N": 3, "F": 4]
    )
}

/// Two parallel lines joined only far to the north, `A–M–B` and `C–S–D`, with station `S` linked
/// straight across to `M` on the other line, as a two-track station is:
///
/// ```
///   B ── D
///   |    |
///   M ~~ S
///   |    |
///   A    C
/// ```
enum RailGraphLinkFixture {
    static let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
    static let m = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.0)
    static let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)
    static let c = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.001)
    static let s = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.001)
    static let d = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.001)

    /// Node indices: 0=A, 1=M, 2=B, 3=C, 4=S, 5=D.
    static let graph = RailGraph(
        nodeCoordinates: [a, m, b, c, s, d],
        edges: [
            RailGraph.Edge(points: [a, m], length: 11100),
            RailGraph.Edge(points: [m, b], length: 11100),
            RailGraph.Edge(points: [c, s], length: 11100),
            RailGraph.Edge(points: [s, d], length: 11100),
            RailGraph.Edge(points: [b, d], length: 60),
        ],
        adjacency: [
            [RailGraph.Adjacency(to: 1, edgeIndex: 0, forward: true)],
            [RailGraph.Adjacency(to: 0, edgeIndex: 0, forward: false), RailGraph.Adjacency(to: 2, edgeIndex: 1, forward: true)],
            [RailGraph.Adjacency(to: 1, edgeIndex: 1, forward: false), RailGraph.Adjacency(to: 5, edgeIndex: 4, forward: true)],
            [RailGraph.Adjacency(to: 4, edgeIndex: 2, forward: true)],
            [RailGraph.Adjacency(to: 3, edgeIndex: 2, forward: false), RailGraph.Adjacency(to: 5, edgeIndex: 3, forward: true)],
            [RailGraph.Adjacency(to: 4, edgeIndex: 3, forward: false), RailGraph.Adjacency(to: 2, edgeIndex: 4, forward: false)],
        ],
        stationNode: ["A": 0, "B": 2, "C": 3, "S": 4, "D": 5],
        links: [4: [RailGraph.Link(to: 1, length: 60)]]
    )
}

private func coordinates(_ route: [CLLocationCoordinate2D]?) -> [[Double]]? {
    route?.map { [$0.latitude, $0.longitude] }
}

@Suite("RailGraph routing")
struct RailGraphTests {
    @Test("Improves on a longer path that was queued first")
    func improvesOnEarlierQueuedPath() {
        let route = RailGraphDetourFixture.graph.route(from: "A", to: "B")
        let expected = [RailGraphDetourFixture.a, RailGraphDetourFixture.x, RailGraphDetourFixture.b]
        #expect(coordinates(route) == coordinates(expected))
    }

    @Test("Picks the shorter direct edge over a longer path through a junction")
    func prefersShortestPath() {
        let route = RailGraphFixture.graph.route(from: "A", to: "B")
        #expect(route?.map(\.latitude) == [RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b].map(\.latitude))
        #expect(route?.map(\.longitude) == [RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b].map(\.longitude))
    }

    @Test("Stitches consecutive edges across a multi-hop route")
    func stitchesMultiHopRoute() {
        let route = RailGraphFixture.graph.route(from: "A", to: "C")
        let expected = [RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b, RailGraphFixture.c]
        #expect(route?.map(\.latitude) == expected.map(\.latitude))
        #expect(route?.map(\.longitude) == expected.map(\.longitude))
    }

    @Test("Reversing the query reverses the polyline instead of duplicating it")
    func reversesPolylineForOppositeDirection() {
        let route = RailGraphFixture.graph.route(from: "B", to: "A")
        let expected = [RailGraphFixture.b, RailGraphFixture.m, RailGraphFixture.a]
        #expect(route?.map(\.latitude) == expected.map(\.latitude))
        #expect(route?.map(\.longitude) == expected.map(\.longitude))
    }

    @Test("A station's coordinate is its track node; unknown signatures have none")
    func stationCoordinate() {
        #expect(coordinates(RailGraphFixture.graph.stationCoordinate("B").map { [$0] }) == coordinates([RailGraphFixture.b]))
        #expect(RailGraphFixture.graph.stationCoordinate("Z") == nil)
    }

    @Test("An unknown station signature has no route")
    func unknownStationReturnsNil() {
        #expect(RailGraphFixture.graph.route(from: "A", to: "Z") == nil)
    }

    @Test("The same station as both ends has no route")
    func sameStationReturnsNil() {
        #expect(RailGraphFixture.graph.route(from: "A", to: "A") == nil)
    }

    @Test("A route can arrive at a station, or leave it, over the station's link to another track")
    func routesOverLinksAtEitherEnd() {
        let graph = RailGraphLinkFixture.graph
        let into = [RailGraphLinkFixture.a, RailGraphLinkFixture.m, RailGraphLinkFixture.s]
        #expect(coordinates(graph.route(from: "A", to: "S")) == coordinates(into))
        #expect(coordinates(graph.route(from: "S", to: "A")) == coordinates(into.reversed()))
        // A route over the link (D→B→M→S) that's longer than the track (D→S) loses to the track.
        #expect(coordinates(graph.route(from: "D", to: "S")) == coordinates([RailGraphLinkFixture.d, RailGraphLinkFixture.s]))
    }

    @Test("A link is never a shortcut through the middle of a route")
    func linksAreNotShortcuts() {
        let expected = [
            RailGraphLinkFixture.a, RailGraphLinkFixture.m, RailGraphLinkFixture.b, RailGraphLinkFixture.d,
            RailGraphLinkFixture.s, RailGraphLinkFixture.c,
        ]
        #expect(coordinates(RailGraphLinkFixture.graph.route(from: "A", to: "C")) == coordinates(expected))
        // From C, the link at S would cut the loop in half if it were taken mid-route.
        #expect(coordinates(RailGraphLinkFixture.graph.route(from: "C", to: "A")) == coordinates(expected.reversed()))
    }

    @Test("A station with no edges is unreachable even though its signature is known")
    func unreachableStationReturnsNil() {
        #expect(RailGraphFixture.graph.route(from: "A", to: "D") == nil)
    }
}

@Suite("Route polyline stitching")
struct RailGraphPolylineTests {
    typealias Stop = (signature: String, coordinate: CLLocationCoordinate2D)

    /// A station's directory coordinate deliberately differs from its track node, as it does for
    /// real stations that snap a few hundred metres off.
    static let aDirectory = CLLocationCoordinate2D(latitude: 60.001, longitude: 18.001)
    static let cDirectory = CLLocationCoordinate2D(latitude: 60.301, longitude: 18.001)
    static let z = CLLocationCoordinate2D(latitude: 62.0, longitude: 20.0)

    private func stitch(_ stops: [Stop]) -> [[Double]]? {
        coordinates(RailGraph.polyline(through: stops, route: RailGraphFixture.graph.route))
    }

    @Test("Consecutive real segments share their joining node exactly once")
    func joinsRealSegmentsWithoutDuplicates() {
        let stops: [Stop] = [("A", Self.aDirectory), ("B", RailGraphFixture.b), ("C", Self.cDirectory)]
        let expected = [RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b, RailGraphFixture.c]
        #expect(stitch(stops) == coordinates(expected))
    }

    @Test("Falls back to the stations' own coordinates when nothing is routable")
    func fallsBackToStraightSegments() {
        let stops: [Stop] = [("Z", Self.z), ("Y", Self.aDirectory)]
        #expect(stitch(stops) == coordinates([Self.z, Self.aDirectory]))
    }

    @Test("A real segment after a fallback starts on its own track node, not the previous point")
    func realSegmentAfterFallbackKeepsItsFirstNode() {
        let stops: [Stop] = [("Z", Self.z), ("A", Self.aDirectory), ("B", RailGraphFixture.b)]
        let expected = [Self.z, Self.aDirectory, RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b]
        #expect(stitch(stops) == coordinates(expected))
    }

    @Test("A stop already anchored on its track node isn't duplicated when its real segment starts")
    func anchoredStopIsNotDuplicated() {
        let stops: [Stop] = [("Z", Self.z), ("A", RailGraphFixture.a), ("B", RailGraphFixture.b)]
        let expected = [Self.z, RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b]
        #expect(stitch(stops) == coordinates(expected))
    }

    @Test("A fallback after a real segment continues from the track node")
    func fallbackAfterRealSegment() {
        let stops: [Stop] = [("A", Self.aDirectory), ("B", RailGraphFixture.b), ("Z", Self.z)]
        let expected = [RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b, Self.z]
        #expect(stitch(stops) == coordinates(expected))
    }

    @Test("Consecutive fallbacks share their joining stop exactly once")
    func consecutiveFallbacks() {
        let y = CLLocationCoordinate2D(latitude: 61.0, longitude: 19.0)
        let stops: [Stop] = [("Z", Self.z), ("Y", y), ("X", Self.aDirectory)]
        #expect(stitch(stops) == coordinates([Self.z, y, Self.aDirectory]))
    }

    @Test("A single stop has no line")
    func singleStopIsEmpty() {
        #expect(stitch([("A", Self.aDirectory)]) == [])
    }
}

@Suite("Route legs")
struct RailGraphLegsTests {
    typealias Stop = (signature: String, coordinate: CLLocationCoordinate2D)

    private func legs(_ stops: [Stop], via: [[String]] = [], graph: RailGraph = RailGraphFixture.graph) -> [[[Double]]] {
        RailGraph.legs(through: stops, via: via, onTrack: graph.stationCoordinate, route: graph.route).map { coordinates($0) ?? [] }
    }

    @Test("One leg per consecutive stop pair, each kept separate rather than merged")
    func oneLegPerPair() {
        let stops: [Stop] = [
            ("A", RailGraphFixture.a), ("B", RailGraphFixture.b), ("C", RailGraphFixture.c),
        ]
        let result = legs(stops)
        #expect(result.count == 2)
        #expect(result[0] == coordinates([RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b]))
        #expect(result[1] == coordinates([RailGraphFixture.b, RailGraphFixture.c]))
    }

    @Test("A leg with no route falls back to a straight line between the two stops")
    func fallsBackToStraightLeg() {
        let z = CLLocationCoordinate2D(latitude: 62.0, longitude: 20.0)
        let stops: [Stop] = [("Z", z), ("A", RailGraphFixture.a)]
        #expect(legs(stops) == [coordinates([z, RailGraphFixture.a]) ?? []])
    }

    @Test("A single stop has no legs")
    func singleStopHasNoLegs() {
        #expect(legs([("A", RailGraphFixture.a)]).isEmpty)
    }

    @Test("A leg is routed through the stations it passes instead of the shortest path")
    func routesThroughPassingPoints() {
        let stops: [Stop] = [("A", RailGraphFixture.a), ("B", RailGraphFixture.b), ("C", RailGraphFixture.c)]
        let result = legs(stops, via: [["J"]])
        #expect(result[0] == coordinates([RailGraphFixture.a, RailGraphFixture.j, RailGraphFixture.b]))
        #expect(result[1] == coordinates([RailGraphFixture.b, RailGraphFixture.c]))
    }

    @Test("A stop with no coordinate merges the legs either side of it, passing points and all")
    func unanchoredStopMergesLegs() {
        let anchors = ["A": RailGraphFixture.a, "B": RailGraphFixture.b, "C": RailGraphFixture.c]
        let result = RailGraph.legs(
            stops: ["A", "Z", "B", "C"], passingPoints: [[], ["J"], []], anchor: { anchors[$0] },
            onTrack: RailGraphFixture.graph.stationCoordinate, route: RailGraphFixture.graph.route
        )
        #expect(result.map { coordinates($0.coordinates) ?? [] } == [
            coordinates([RailGraphFixture.a, RailGraphFixture.j, RailGraphFixture.b]) ?? [],
            coordinates([RailGraphFixture.b, RailGraphFixture.c]) ?? [],
        ])
        // Indices into the stop list, so the merged leg spans the stop it skips.
        #expect(result.map(\.from) == [0, 2])
        #expect(result.map(\.to) == [2, 3])
    }

    @Test("A passing point snapped beside the line doesn't pull the route out to it")
    func ignoresPassingPointsNearTheLine() {
        let stops: [Stop] = [("A", RailGraphSpurFixture.a), ("B", RailGraphSpurFixture.b)]
        let direct = coordinates([RailGraphSpurFixture.a, RailGraphSpurFixture.x, RailGraphSpurFixture.b]) ?? []
        #expect(legs(stops, via: [["N"]], graph: RailGraphSpurFixture.graph) == [direct])
    }

    @Test("A passing point the route would turn back at is dropped, however far off the line")
    func dropsPassingPointsAtDeadEnds() {
        let stops: [Stop] = [("A", RailGraphSpurFixture.a), ("B", RailGraphSpurFixture.b)]
        let direct = coordinates([RailGraphSpurFixture.a, RailGraphSpurFixture.x, RailGraphSpurFixture.b]) ?? []
        #expect(legs(stops, via: [["F"]], graph: RailGraphSpurFixture.graph) == [direct])
    }

    @Test("A passing point just off the line across a link is passed without a spike out to it")
    func trimsSpikeToPassingPoint() {
        // A detour line east of the direct one, with the passing point's node 50 m beside it.
        let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
        let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)
        let east = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1)
        let link = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1009)
        let routes: [String: [CLLocationCoordinate2D]] = ["A|B": [a, b], "A|W": [a, east, link], "W|B": [link, east, b]]
        let result = RailGraph.legs(
            through: [("A", a), ("B", b)], via: [["W"]], onTrack: { $0 == "W" ? link : nil },
            route: { routes["\($0)|\($1)"] }
        )
        #expect(result.map { coordinates($0) ?? [] } == [coordinates([a, east, b]) ?? []])
    }

    @Test("A spike longer than half the heading window is trimmed, not taken for a turn back")
    func trimsLongSpikeBeforeCheckingHeadings() {
        // 120 m out at right angles from a line with vertices 89 m either side of where it leaves:
        // over 200 m either side, the spike alone would read as a reversal.
        let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
        let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)
        let before = CLLocationCoordinate2D(latitude: 59.0992, longitude: 18.1)
        let east = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1)
        let after = CLLocationCoordinate2D(latitude: 59.1008, longitude: 18.1)
        let link = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1021)
        let routes: [String: [CLLocationCoordinate2D]] = [
            "A|B": [a, b], "A|W": [a, before, east, link], "W|B": [link, east, after, b],
        ]
        let result = RailGraph.legs(
            through: [("A", a), ("B", b)], via: [["W"]], onTrack: { $0 == "W" ? link : nil },
            route: { routes["\($0)|\($1)"] }
        )
        #expect(result.map { coordinates($0) ?? [] } == [coordinates([a, before, east, after, b]) ?? []])
    }

    @Test("A passing point the route reverses at is dropped even when it leaves on another track")
    func dropsReversalAcrossParallelTracks() {
        // In along one track to the far point, back out along a parallel one 10 m away.
        let a = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
        let b = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.0)
        let junction = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.0)
        let far = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.05)
        let back = CLLocationCoordinate2D(latitude: 59.1001, longitude: 18.01)
        let routes: [String: [CLLocationCoordinate2D]] = [
            "A|B": [a, junction, b], "A|W": [a, junction, far], "W|B": [far, back, junction, b],
        ]
        let result = RailGraph.legs(
            through: [("A", a), ("B", b)], via: [["W"]], onTrack: { $0 == "W" ? far : nil },
            route: { routes["\($0)|\($1)"] }
        )
        #expect(result.map { coordinates($0) ?? [] } == [coordinates([a, junction, b]) ?? []])
    }

    @Test("Passing points the network can't route to are skipped")
    func skipsUnroutablePassingPoints() {
        let stops: [Stop] = [("A", RailGraphFixture.a), ("B", RailGraphFixture.b)]
        #expect(legs(stops, via: [["Z", "J", "D"]]) == [coordinates([RailGraphFixture.a, RailGraphFixture.j, RailGraphFixture.b]) ?? []])
        #expect(legs(stops, via: [["Z"]]) == [coordinates([RailGraphFixture.a, RailGraphFixture.m, RailGraphFixture.b]) ?? []])
    }
}

@Suite("MinHeap")
struct MinHeapTests {
    @Test("Pops in priority order with duplicates and enough entries to exercise both children")
    func popsSorted() {
        let priorities: [Double] = [7, 3, 9, 1, 3, 8, 2, 6, 5, 1, 4, 0]
        var heap = MinHeap<Int>()
        for (index, priority) in priorities.enumerated() {
            heap.insert(index, priority: priority)
        }
        var popped: [Double] = []
        while let index = heap.popMin() {
            popped.append(priorities[index])
        }
        #expect(popped == priorities.sorted())
        #expect(heap.isEmpty)
    }
}

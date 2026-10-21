import CoreLocation

/// Pure rail network data plus shortest-path search, independent of how it's loaded or cached.
/// Kept separate from `RailNetwork` so it can be constructed directly from a small synthetic
/// graph in tests instead of the real ~7k-node bundle.
struct RailGraph: Sendable {
    struct Edge: Sendable {
        /// Always stored source → destination as laid out by whoever builds the graph;
        /// `Adjacency.forward` says whether a given traversal needs to walk it in that order or
        /// reversed, so the polyline itself is never duplicated for the two directions.
        let points: [CLLocationCoordinate2D]
        let length: CLLocationDistance
    }

    struct Adjacency: Sendable {
        let to: Int
        let edgeIndex: Int
        let forward: Bool
    }

    /// A straight connector from a station's node to another of its tracks (see
    /// `snap_stations.py`). A route may only start or end over one: that lets it arrive at a
    /// multi-track station on whichever track it's on, instead of running on to a crossover and
    /// back to the one track the station's node is on, without links turning into shortcuts
    /// between lines anywhere else.
    struct Link: Sendable {
        let to: Int
        let length: CLLocationDistance
    }

    let nodeCoordinates: [CLLocationCoordinate2D]
    let edges: [Edge]
    let adjacency: [[Adjacency]]
    let stationNode: [String: Int]
    /// Each station node's links.
    let links: [Int: [Link]]

    init(
        nodeCoordinates: [CLLocationCoordinate2D], edges: [Edge], adjacency: [[Adjacency]], stationNode: [String: Int],
        links: [Int: [Link]] = [:]
    ) {
        self.nodeCoordinates = nodeCoordinates
        self.edges = edges
        self.adjacency = adjacency
        self.stationNode = stationNode
        self.links = links
    }

    /// Where a station sits on the track: the graph node it was snapped to, which is where every
    /// route through it starts and ends. `nil` for a signature the network doesn't know.
    func stationCoordinate(_ signature: String) -> CLLocationCoordinate2D? {
        stationNode[signature].map { nodeCoordinates[$0] }
    }

    /// The real-track path between two stations, or `nil` if either signature isn't in the
    /// network, they're the same station, or no path connects them.
    func route(from: String, to: String) -> [CLLocationCoordinate2D]? {
        guard let start = stationNode[from], let goal = stationNode[to], start != goal else { return nil }
        return shortestPath(from: start, to: goal)
    }

    /// Plain Dijkstra with flat, node-indexed arrays for its working state — no hashing for a graph
    /// this small — so the cold-cache worst case (a sparse-stop express flooding most of the
    /// network) stays well under a frame on the main actor. `start`'s links are only taken as the
    /// first step and `goal`'s only as the last.
    private func shortestPath(from start: Int, to goal: Int) -> [CLLocationCoordinate2D]? {
        let count = nodeCoordinates.count
        var distance = [CLLocationDistance](repeating: .infinity, count: count)
        var previousNode = [Int](repeating: -1, count: count)
        // `nil` with a `previousNode` set: reached over a link.
        var previousAdjacency = [Adjacency?](repeating: nil, count: count)
        var visited = [Bool](repeating: false, count: count)
        var heap = MinHeap<Int>()

        distance[start] = 0
        heap.insert(start, priority: 0)
        for link in links[start] ?? [] where link.length < distance[link.to] {
            distance[link.to] = link.length
            previousNode[link.to] = start
            heap.insert(link.to, priority: link.length)
        }
        let intoGoal = Dictionary((links[goal] ?? []).map { ($0.to, $0.length) }, uniquingKeysWith: min)

        while let node = heap.popMin() {
            guard !visited[node] else { continue }
            visited[node] = true
            if node == goal {
                break
            }
            let base = distance[node]
            if let length = intoGoal[node], base + length < distance[goal] {
                distance[goal] = base + length
                previousNode[goal] = node
                previousAdjacency[goal] = nil
                heap.insert(goal, priority: base + length)
            }
            for step in adjacency[node] where !visited[step.to] {
                let candidate = base + edges[step.edgeIndex].length
                if candidate < distance[step.to] {
                    distance[step.to] = candidate
                    previousNode[step.to] = node
                    previousAdjacency[step.to] = step
                    heap.insert(step.to, priority: candidate)
                }
            }
        }
        guard distance[goal] < .infinity else { return nil }

        // Walk the predecessor chain back to `start`, then replay each step forward: an edge in the
        // direction it was actually traversed, a link as a straight hop.
        var steps: [(to: Int, by: Adjacency?)] = []
        var current = goal
        while current != start {
            let previous = previousNode[current]
            guard previous >= 0 else { return nil }
            steps.append((current, previousAdjacency[current]))
            current = previous
        }
        steps.reverse()

        var result = [nodeCoordinates[start]]
        for step in steps {
            guard let edge = step.by else {
                result.append(nodeCoordinates[step.to])
                continue
            }
            let points = edges[edge.edgeIndex].points
            if edge.forward {
                result.append(contentsOf: points.dropFirst())
            } else {
                result.append(contentsOf: points.dropLast().reversed())
            }
        }
        return result
    }
}

extension RailGraph {
    /// Stitches a journey's consecutive stop pairs into one polyline: the real track shape where
    /// `route` knows it, a straight segment between the stops' given coordinates where it doesn't
    /// (foreign station, network not loaded yet, no path). A real segment starts and ends on the
    /// stations' track nodes, so it's appended whole unless the line already ends exactly on its
    /// first point (the previous real segment ended there, or the caller anchored the stop on the
    /// same node) — dropping that point unconditionally would cut the corner off the track.
    static func polyline(
        through stops: [(signature: String, coordinate: CLLocationCoordinate2D)],
        route: (_ from: String, _ to: String) -> [CLLocationCoordinate2D]?
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for (from, to) in zip(stops, stops.dropFirst()) {
            if let real = route(from.signature, to.signature), !real.isEmpty {
                let continues = result.last.map { $0.latitude == real[0].latitude && $0.longitude == real[0].longitude } ?? false
                result.append(contentsOf: continues ? real.dropFirst() : real[...])
            } else {
                if result.isEmpty {
                    result.append(from.coordinate)
                }
                result.append(to.coordinate)
            }
        }
        return result
    }

    /// Same stitching as `polyline(through:route:)`, but keeps each leg as its own array instead of
    /// merging them into one line — so a caller can style individual legs differently, e.g. drawing
    /// a cancelled stretch of the journey in red. `via[i]`, when present, lists the stations leg `i`
    /// passes without stopping (`onTrack` gives their place on the network); the leg is rerouted
    /// through those that are off its shortest path, which can run down a different line than the
    /// train does.
    static func legs(
        through stops: [(signature: String, coordinate: CLLocationCoordinate2D)],
        via: [[String]],
        onTrack: (String) -> CLLocationCoordinate2D?,
        route: (_ from: String, _ to: String) -> [CLLocationCoordinate2D]?
    ) -> [[CLLocationCoordinate2D]] {
        zip(stops, stops.dropFirst()).enumerated().map { index, pair in
            let (from, to) = pair
            let waypoints = index < via.count ? via[index] : []
            if let real = path(from: from.signature, via: waypoints, to: to.signature, onTrack: onTrack, route: route), !real.isEmpty {
                return real
            } else {
                return [from.coordinate, to.coordinate]
            }
        }
    }

    /// One leg of a journey's route: the stops it runs between, by index into the journey's stops,
    /// and its line.
    struct Leg {
        let from: Int
        let to: Int
        let coordinates: [CLLocationCoordinate2D]
    }

    /// `legs(through:via:onTrack:route:)` for a journey's stop signatures and
    /// `TrainJourney.passingPoints`. A stop `anchor` has no coordinate for is left out, so the legs
    /// on either side of it merge into one routed through both legs' passing points.
    static func legs(
        stops signatures: [String],
        passingPoints: [[String]],
        anchor: (String) -> CLLocationCoordinate2D?,
        onTrack: (String) -> CLLocationCoordinate2D?,
        route: (_ from: String, _ to: String) -> [CLLocationCoordinate2D]?
    ) -> [Leg] {
        var anchored: [Int] = []
        var stops: [(signature: String, coordinate: CLLocationCoordinate2D)] = []
        var via: [[String]] = []
        var pending: [String] = []
        for (index, signature) in signatures.enumerated() {
            if let coordinate = anchor(signature) {
                if !stops.isEmpty {
                    via.append(pending)
                }
                stops.append((signature, coordinate))
                anchored.append(index)
                pending = []
            }
            if index < passingPoints.count {
                pending += passingPoints[index]
            }
        }
        let lines = legs(through: stops, via: via, onTrack: onTrack, route: route)
        return zip(zip(anchored, anchored.dropFirst()), lines).map { Leg(from: $0.0, to: $0.1, coordinates: $1) }
    }

    /// How far off a leg's shortest path a passing point has to be before the leg is rerouted
    /// through it. Closer than this it's on the same line — snapped to the other track, a platform
    /// or a stub beside it — and routing through it would only add an out-and-back.
    static let detourThreshold: CLLocationDistance = 1000

    /// How far before and after a waypoint `turnsBack` looks to tell which way the route is going,
    /// so a few metres across a link or along a station's tracks don't count as a turn.
    static let headingWindow: CLLocationDistance = 200

    /// The longest spike to a waypoint's own node — across a link, or into a short stub beside the
    /// line — that's cut out of the line rather than drawn in and straight back out.
    static let maxSpike: CLLocationDistance = 150

    /// The shortest path from `from` to `to`, unless some waypoints lie more than
    /// `detourThreshold` off it: then the path through those, in order. A train never turns back
    /// at a station it passes, so a waypoint the chain reverses at — into a stub and out again, or
    /// in on one of a junction station's tracks and back out on another — is dropped.
    private static func path(
        from: String,
        via: [String],
        to: String,
        onTrack: (String) -> CLLocationCoordinate2D?,
        route: (_ from: String, _ to: String) -> [CLLocationCoordinate2D]?
    ) -> [CLLocationCoordinate2D]? {
        guard let direct = route(from, to) else { return nil }
        var waypoints = via.filter { signature in
            onTrack(signature).map { distance(from: $0, to: direct) > detourThreshold } ?? false
        }
        while !waypoints.isEmpty {
            let ends = [from] + waypoints + [to]
            var segments: [[CLLocationCoordinate2D]] = []
            for (start, end) in zip(ends, ends.dropFirst()) {
                guard let segment = route(start, end), segment.count > 1 else { break }
                segments.append(segment)
            }
            // `from` reaches `to`, so a hop that fails has a waypoint off the connected network.
            if segments.count < ends.count - 1 {
                waypoints.remove(at: min(segments.count, waypoints.count - 1))
                continue
            }
            if let turn = segments.indices.dropLast().first(where: { turnsBack(segments[$0], segments[$0 + 1]) }) {
                waypoints.remove(at: turn)
                continue
            }
            for index in segments.indices.dropLast() {
                let into = segments[index], outOf = segments[index + 1]
                guard into.count > 2, outOf.count > 2, same(into[into.count - 2], outOf[1]), !same(into[into.count - 3], outOf[2]),
                      metres(into[into.count - 1], into[into.count - 2]) <= maxSpike else { continue }
                segments[index].removeLast()
                segments[index + 1].removeFirst()
            }
            // Each segment starts on the point the previous one ended on.
            return segments.dropFirst().reduce(segments[0]) { $0 + $1.dropFirst() }
        }
        return direct
    }

    /// Whether the route heads back the way it came at the point where `into` ends and `outOf`
    /// starts, comparing its heading over `headingWindow` either side.
    private static func turnsBack(_ into: [CLLocationCoordinate2D], _ outOf: [CLLocationCoordinate2D]) -> Bool {
        guard let end = into.last else { return false }
        let back = point(headingWindow, along: into.reversed()), ahead = point(headingWindow, along: outOf)
        let scale = cos(end.latitude * .pi / 180)
        let inward = (x: (end.longitude - back.longitude) * scale, y: end.latitude - back.latitude)
        let outward = (x: (ahead.longitude - end.longitude) * scale, y: ahead.latitude - end.latitude)
        return inward.x * outward.x + inward.y * outward.y < 0
    }

    /// The first point of `line` at least `distance` from its start along it, or its last point.
    /// `line` is never empty: every segment has both its ends.
    private static func point(
        _ distance: CLLocationDistance, along line: some BidirectionalCollection<CLLocationCoordinate2D>
    ) -> CLLocationCoordinate2D {
        var walked: CLLocationDistance = 0
        for (from, to) in zip(line, line.dropFirst()) {
            walked += metres(from, to)
            if walked >= distance {
                return to
            }
        }
        return line.last ?? CLLocationCoordinate2D()
    }

    private static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let scale = cos(a.latitude * .pi / 180)
        return hypot((b.longitude - a.longitude) * scale, b.latitude - a.latitude) * 111_320
    }

    private static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }

    /// Shortest distance from `point` to the polyline `line`, on a local flat projection around
    /// `point` — plenty for comparing against `detourThreshold`.
    private static func distance(from point: CLLocationCoordinate2D, to line: [CLLocationCoordinate2D]) -> CLLocationDistance {
        let metresPerDegree = 111_320.0
        let scale = cos(point.latitude * .pi / 180)
        let projected = line.map {
            (x: ($0.longitude - point.longitude) * scale * metresPerDegree, y: ($0.latitude - point.latitude) * metresPerDegree)
        }
        var nearest = projected.first.map { hypot($0.x, $0.y) } ?? .infinity
        for (a, b) in zip(projected, projected.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / lengthSquared)) : 0
            nearest = min(nearest, hypot(a.x + t * dx, a.y + t * dy))
        }
        return nearest
    }
}

/// Minimal binary min-heap keyed by priority, just enough for Dijkstra over a ~7k node graph.
struct MinHeap<Element> {
    private var items: [(element: Element, priority: CLLocationDistance)] = []

    var isEmpty: Bool {
        items.isEmpty
    }

    mutating func insert(_ element: Element, priority: CLLocationDistance) {
        items.append((element, priority))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].priority < items[parent].priority else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func popMin() -> Element? {
        guard !items.isEmpty else { return nil }
        let root = items[0].element
        items[0] = items[items.count - 1]
        items.removeLast()
        var i = 0
        while true {
            let left = 2 * i + 1, right = 2 * i + 2
            var smallest = i
            if left < items.count, items[left].priority < items[smallest].priority {
                smallest = left
            }
            if right < items.count, items[right].priority < items[smallest].priority {
                smallest = right
            }
            guard smallest != i else { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return root
    }
}

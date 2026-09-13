import Foundation
import os
import TrafikverketKit

/// Keeps the set of live train positions current, preferring Server-Sent Events and
/// falling back to polling when the stream is unavailable.
@MainActor
@Observable
final class LiveTrainStore {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case streaming
        case polling
        case failed(String)

        var isLive: Bool {
            self == .streaming || self == .polling
        }
    }

    private(set) var trains: [LiveTrain] = []
    /// Mirrors `trains.count` as its own property so views that only need the count (e.g. a status
    /// pill) don't take a read dependency on the whole array and re-render on every position update.
    private(set) var trainCount = 0
    private(set) var state: ConnectionState = .idle
    private(set) var lastUpdate: Date?
    private(set) var updateCount = 0

    private var positions: [String: TrainPosition] = [:]
    private var task: Task<Void, Never>?
    private let client: TrafikverketClient
    private let settings: AppSettings
    private let logger = Logger(subsystem: "se.tagradar.app", category: "Live")

    /// Positions older than this are dropped from the map.
    private static let staleAfter: TimeInterval = 15 * 60

    init(client: TrafikverketClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
    }

    func train(id: String) -> LiveTrain? {
        positions[id].flatMap(LiveTrain.init)
    }

    func train(for key: TrainKey) -> LiveTrain? {
        trains.first { $0.key == key }
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        state = .connecting
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        state = .idle
    }

    func restart() {
        stop()
        start()
    }

    private static let fields = [
        "Train", "Position.WGS84", "TimeStamp", "Status", "Bearing", "Speed", "VersionNumber", "ModifiedTime", "Deleted",
    ]

    /// Everything reported in the last 15 minutes.
    private var snapshotQuery: Query<TrainPosition> {
        Query<TrainPosition>()
            .filter(.greaterThan("TimeStamp", "$dateadd(-0.00:15:00)"))
            .include(Self.fields)
            .limit(5000)
    }

    /// The API rejects `$dateadd` together with `sseurl`, so the stream is unfiltered; `limit(1)` keeps
    /// the SSE handshake response tiny. Stale positions are pruned client-side.
    private var streamQuery: Query<TrainPosition> {
        Query<TrainPosition>().include(Self.fields).limit(1)
    }

    /// Incoming SSE events are coalesced so the UI re-renders at most a few times per second,
    /// even during the initial replay burst of several thousand events.
    private var pending: [TrainPosition] = []
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: Duration = .milliseconds(400)

    private func runLoop() async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled {
            do {
                let snapshot = try await client.fetch(snapshotQuery)
                merge(snapshot.objects, replacing: true)
                let url = try await client.liveURL(for: streamQuery)
                state = .streaming
                backoff = 2
                var received = 0
                for try await result in client.events(from: url, as: TrainPosition.self) {
                    enqueue(result.objects)
                    received += result.objects.count
                    if received % 500 == 0 {
                        logger.debug("SSE received \(received) position events")
                    }
                }
                // Stream ended cleanly; reconnect after a short pause.
                flush()
                state = .connecting
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch let error as TrafikverketError where error == .missingAPIKey || error == .invalidAuthentication {
                state = .failed(error.localizedDescription)
                // Wait for the key to change rather than hammering the API.
                try? await Task.sleep(for: .seconds(5))
            } catch {
                logger.warning("SSE failed, polling instead: \(error.localizedDescription, privacy: .public)")
                state = .polling
                await pollFor(duration: max(backoff * 10, 60))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// Polls snapshots for a while before letting the loop retry SSE.
    private func pollFor(duration: TimeInterval) async {
        let deadline = Date.now.addingTimeInterval(duration)
        while !Task.isCancelled, Date.now < deadline {
            do {
                let result = try await client.fetch(snapshotQuery)
                merge(result.objects, replacing: true)
                state = .polling
            } catch let error as TrafikverketError where error == .missingAPIKey || error == .invalidAuthentication {
                state = .failed(error.localizedDescription)
            } catch {
                state = .failed(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(settings.pollingInterval))
        }
    }

    private func enqueue(_ incoming: [TrainPosition]) {
        pending.append(contentsOf: incoming)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        merge(batch)
    }

    private func merge(_ incoming: [TrainPosition], replacing: Bool = false) {
        if replacing {
            positions.removeAll(keepingCapacity: true)
        }
        for p in incoming {
            if p.deleted == true {
                positions.removeValue(forKey: p.id)
                continue
            }
            if let existing = positions[p.id], let ev = existing.versionNumber, let nv = p.versionNumber, nv < ev {
                continue // out-of-order event
            }
            positions[p.id] = p
        }
        prune()
        rebuild()
        lastUpdate = .now
        updateCount += 1
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.staleAfter)
        positions = positions.filter { ($0.value.timeStamp ?? .distantPast) > cutoff }
    }

    private func rebuild() {
        trains = positions.values.compactMap(LiveTrain.init).sorted { $0.id < $1.id }
        // Guarded so an unchanged count doesn't notify the views that observe only this.
        if trainCount != trains.count {
            trainCount = trains.count
        }
    }
}

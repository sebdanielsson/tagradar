import Foundation
import os
import TrafikverketKit

/// Lightweight delay lookup for the trains currently on screen. One batched
/// TrainAnnouncement query fetches the next not-yet-passed stop for each tracked train.
@MainActor
@Observable
final class DelayIndex {
    struct Entry: Hashable, Sendable {
        var delay: TimeInterval?
        var canceled: Bool
        var nextSignature: String?
        var productName: String?
        var destinationSignature: String?
        var updatedAt: Date
    }

    typealias Severity = DelaySeverity

    private(set) var entries: [String: Entry] = [:]
    private var tracked: Set<TrainKey> = []
    private var task: Task<Void, Never>?
    private let client: TrafikverketClient
    private let logger = Logger(subsystem: "se.tagradar.app", category: "Delays")
    private static let refreshInterval: TimeInterval = 45
    private static let batchSize = 120

    init(client: TrafikverketClient) {
        self.client = client
    }

    func entry(for key: TrainKey?) -> Entry? {
        guard let key else { return nil }
        return entries[key.id]
    }

    func severity(for key: TrainKey?) -> Severity {
        guard let entry = entry(for: key) else { return .unknown }
        return Self.severity(delay: entry.delay, canceled: entry.canceled)
    }

    nonisolated static func severity(delay: TimeInterval?, canceled: Bool) -> Severity {
        DelaySeverity.of(delay: delay, canceled: canceled)
    }

    /// Replaces the set of trains to keep delay info for. Debounced; safe to call on every map move.
    func track(_ keys: some Sequence<TrainKey>) {
        let next = Set(keys)
        guard next != tracked else { return }
        tracked = next
        schedule(delay: .milliseconds(600))
    }

    private func schedule(delay: Duration) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await refresh()
            guard !Task.isCancelled else { return }
            schedule(delay: .seconds(Self.refreshInterval))
        }
    }

    func refresh() async {
        let keys = Array(tracked)
        guard !keys.isEmpty else { return }
        // Group by departure day so one query per day suffices.
        let byDay = Dictionary(grouping: keys, by: \.dateString)
        for (day, dayKeys) in byDay {
            for chunk in dayKeys.chunked(into: Self.batchSize) {
                await fetch(day: day, keys: chunk)
            }
        }
    }

    private func fetch(day: String, keys: [TrainKey]) async {
        let idents = keys.map(\.ident)
        let query = Query<TrainAnnouncement>()
            .filter(
                .in("AdvertisedTrainIdent", idents),
                .greaterThanOrEqual("ScheduledDepartureDateTime", "\(day)T00:00:00"),
                .lessThan("ScheduledDepartureDateTime", "\(day)T23:59:59"),
                .passengerActivity,
                .greaterThan("AdvertisedTimeAtLocation", "$dateadd(-0.01:30:00)")
            )
            .include(
                "ActivityId", "ActivityType", "AdvertisedTrainIdent", "AdvertisedTimeAtLocation", "EstimatedTimeAtLocation",
                "TimeAtLocation", "Canceled", "LocationSignature", "ScheduledDepartureDateTime",
                "ProductInformation.Description", "ToLocation.LocationName"
            )
            .orderBy(Sort("AdvertisedTimeAtLocation"))
            .limit(4000)
        do {
            let result = try await client.fetch(query)
            apply(result.objects, keys: keys)
        } catch {
            logger.warning("Delay refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ rows: [TrainAnnouncement], keys: [TrainKey]) {
        let keyByIdent = Dictionary(keys.map { ($0.ident, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped: [String: [TrainAnnouncement]] = [:]
        for row in rows {
            guard let ident = row.advertisedTrainIdent else { continue }
            grouped[ident, default: []].append(row)
        }
        let now = Date.now
        for (ident, key) in keyByIdent {
            let list = grouped[ident] ?? []
            guard !list.isEmpty else {
                entries[key.id] = Entry(
                    delay: nil,
                    canceled: false,
                    nextSignature: nil,
                    productName: nil,
                    destinationSignature: nil,
                    updatedAt: now
                )
                continue
            }
            let upcoming = list.first { $0.timeAtLocation == nil && !$0.isCanceled }
            let lastPassed = list.last { $0.timeAtLocation != nil }
            let reference = upcoming ?? lastPassed
            let allCanceled = list.allSatisfy(\.isCanceled)
            entries[key.id] = Entry(
                delay: reference?.delay,
                canceled: allCanceled,
                nextSignature: upcoming?.locationSignature,
                productName: list.compactMap { $0.productInformation?.first?.description }.first,
                destinationSignature: list.compactMap { $0.toLocation?.first?.locationName }.first,
                updatedAt: now
            )
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

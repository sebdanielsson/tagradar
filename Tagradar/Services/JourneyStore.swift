import Foundation
import TrafikverketKit

/// In-memory cache of loaded journeys so the map, detail view and favorites share one copy
/// and the map can draw a route as soon as the detail has loaded it.
@MainActor
@Observable
final class JourneyStore {
    private struct Entry {
        var journey: TrainJourney?
        var loadedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<TrainJourney?, any Error>] = [:]
    /// The same train number's run the day before, keyed by the run it stands in for: missing
    /// until fetched, `.some(nil)` when the train didn't run that day.
    private var previousRuns: [String: TrainJourney?] = [:]
    private var previousRunsInFlight: Set<String> = []
    private let service: TrainService
    private static let maxAge: TimeInterval = 20

    init(service: TrainService) {
        self.service = service
    }

    /// The last loaded journey for a key, if any, regardless of age.
    func cached(_ key: TrainKey?) -> TrainJourney? {
        guard let key else { return nil }
        return entries[key.id]?.journey
    }

    /// Loads the journey, reusing a fresh cached copy or an in-flight request.
    func load(_ key: TrainKey, force: Bool = false) async throws -> TrainJourney? {
        if !force, let entry = entries[key.id], Date.now.timeIntervalSince(entry.loadedAt) < Self.maxAge {
            return entry.journey
        }
        if let task = inFlight[key.id] {
            return try await task.value
        }
        let service = service
        let task = Task<TrainJourney?, any Error> { try await service.journey(for: key) }
        inFlight[key.id] = task
        defer { inFlight[key.id] = nil }
        let journey = try await task.value
        entries[key.id] = Entry(journey: journey, loadedAt: .now)
        return journey
    }

    /// The same train number's run the day before `key`, once `loadPreviousRun` has fetched it. Its
    /// passing points stand in for the stretch `key`'s run hasn't covered yet (see
    /// `TrainJourney.routePassingPoints(previous:)`).
    func previousRun(_ key: TrainKey?) -> TrainJourney? {
        guard let key else { return nil }
        return previousRuns[key.id].flatMap(\.self)
    }

    /// Fetches `previousRun(_:)` once per run. A past run doesn't change, so it's never refreshed;
    /// a failed fetch isn't cached, so the next call retries.
    func loadPreviousRun(_ key: TrainKey) async {
        guard previousRuns[key.id] == nil, !previousRunsInFlight.contains(key.id),
              let day = SwedishTime.calendar.date(byAdding: .day, value: -1, to: key.departureDate) else { return }
        previousRunsInFlight.insert(key.id)
        defer { previousRunsInFlight.remove(key.id) }
        do {
            let run = try await service.journey(for: TrainKey(ident: key.ident, departureDate: day))
            previousRuns[key.id] = .some(run)
        } catch {
            // Left uncached so the next selection retries.
        }
    }

    func store(_ journey: TrainJourney) {
        entries[journey.key.id] = Entry(journey: journey, loadedAt: .now)
    }
}

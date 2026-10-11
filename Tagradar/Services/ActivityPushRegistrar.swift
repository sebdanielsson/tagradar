import Foundation
import os

/// Tells the push server (`server/`, see docs/live-activity-push.md) which Live Activities to keep
/// current while the app is suspended. The server polls Trafikverket and sends ActivityKit pushes,
/// including the delay, track and arrival alerts for those trains.
///
/// Configured through Info.plist (`TagradarPushServerHost`, `TagradarPushServerSecret`); without them
/// it does nothing, and activities only update while the app runs.
@MainActor
final class ActivityPushRegistrar {
    struct Registration: Codable, Equatable {
        var activityId: String
        var token: String
        var trainId: String
        var bundleId: String
        var environment: String
        var segment: TripSegment?
        var alerts: Bool
    }

    private let baseURL: URL?
    private let secret: String
    private let bundleID: String
    private let environment: String
    private let session: URLSession
    private let logger = Logger(subsystem: "se.tagradar.app", category: "PushRegistrar")
    /// What the server last accepted, by activity ID, and when. Kept across launches: the server goes
    /// on sending a train's alerts while the app is not running, and the app must know that when it
    /// starts again, before any request has gone through.
    private var accepted: [String: Accepted] {
        didSet { SharedStorage.defaults.set(try? JSONEncoder().encode(accepted), forKey: Self.acceptedKey) }
    }

    /// Registrations the server refused, not sent again until the time given.
    private var refused: [String: (registration: Registration, until: Date)] = [:]
    private var queue: Task<Void, Never>?
    private static let refusalBackoff: TimeInterval = 10 * 60
    /// An unchanged registration is sent again after this long, in case the server lost it (a token
    /// APNs rejected, a reset database).
    private static let reconfirmAfter: TimeInterval = 30 * 60
    private static let acceptedKey = "push.accepted"

    private struct Accepted: Codable {
        var registration: Registration
        var at: Date
    }

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        let host = (bundle.object(forInfoDictionaryKey: "TagradarPushServerHost") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        baseURL = host.isEmpty ? nil : URL(string: "https://\(host)")
        secret = bundle.object(forInfoDictionaryKey: "TagradarPushServerSecret") as? String ?? ""
        bundleID = bundle.bundleIdentifier ?? "se.tagradar.app"
        environment = bundle.object(forInfoDictionaryKey: "TagradarAPNsEnvironment") as? String ?? "production"
        self.session = session
        accepted = SharedStorage.defaults.data(forKey: Self.acceptedKey)
            .flatMap { try? JSONDecoder().decode([String: Accepted].self, from: $0) } ?? [:]
    }

    var isEnabled: Bool {
        baseURL != nil && !secret.isEmpty
    }

    /// Whether the server currently sends this train's alerts, so the app should not post them too.
    func sendsAlerts(for trainID: String) -> Bool {
        accepted.values.contains { $0.registration.trainId == trainID && $0.registration.alerts }
    }

    /// Drops what it knows about activities that no longer exist (ended while the app was not running).
    func forgetAllExcept(_ activityIDs: Set<String>) {
        let gone = Set(accepted.keys).subtracting(activityIDs)
        if !gone.isEmpty {
            accepted = accepted.filter { activityIDs.contains($0.key) }
        }
    }

    /// Registers an activity, or updates it when its token, segment or alert choice changed.
    func register(activityID: String, token: Data, trainID: String, segment: TripSegment?, alerts: Bool) async {
        let registration = Registration(
            activityId: activityID,
            token: token.map { String(format: "%02x", $0) }.joined(),
            trainId: trainID,
            bundleId: bundleID,
            environment: environment,
            segment: segment,
            alerts: alerts
        )
        guard let baseURL, isEnabled else { return }
        await serially { [self] in
            if let last = accepted[activityID], last.registration == registration, last.at.timeIntervalSinceNow > -Self.reconfirmAfter {
                return
            }
            if let refused = refused[activityID], refused.registration == registration, refused.until > .now {
                return
            }
            var request = URLRequest(url: baseURL.appending(path: "api/activities"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(registration)
            switch await send(request) {
            case .accepted:
                accepted[activityID] = Accepted(registration: registration, at: .now)
                refused[activityID] = nil
                logger.info("Registered activity for \(trainID, privacy: .public)")
            case .refused:
                // Asking again every refresh will not change the answer (no APNs key for this app yet, or full).
                refused[activityID] = (registration, .now.addingTimeInterval(Self.refusalBackoff))
                // Nor can the app count on an earlier registration: withdraw it, and post the alerts itself
                // once the server confirms. Until then the earlier registration is still being served.
                if accepted[activityID] != nil {
                    var delete = URLRequest(url: baseURL.appending(path: "api/activities/\(activityID)"))
                    delete.httpMethod = "DELETE"
                    if await send(delete) == .accepted {
                        accepted[activityID] = nil
                    }
                }
            case .failed:
                break
            }
        }
    }

    func unregister(activityID: String) async {
        guard let baseURL, isEnabled else { return }
        await serially { [self] in
            accepted[activityID] = nil
            refused[activityID] = nil
            var request = URLRequest(url: baseURL.appending(path: "api/activities/\(activityID)"))
            request.httpMethod = "DELETE"
            // Not retried: the server stops on its own once the run is over.
            _ = await send(request)
        }
    }

    /// Runs requests one after another, so the server sees registrations in the order they were made.
    /// Cancelling the caller (an expiring background task) cancels its request.
    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private enum Outcome {
        case accepted, refused, failed
    }

    private func send(_ request: URLRequest) async -> Outcome {
        var request = request
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200 ... 299:
                return .accepted
            case 408, 429:
                return .failed
            case 400 ... 499, 503:
                logger.error("Push server refused the request: HTTP \(status)")
                return .refused
            default:
                logger.error("Push server answered HTTP \(status)")
                return .failed
            }
        } catch {
            logger.error("Push server unreachable: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}

import Foundation

/// Provides the API key at request time so the app can change it without recreating the client.
public protocol APIKeyProvider: Sendable {
    func apiKey() async -> String?
}

public struct StaticAPIKey: APIKeyProvider {
    public let key: String?
    public init(_ key: String?) {
        self.key = key
    }

    public func apiKey() async -> String? {
        key
    }
}

/// Async client for the Trafikverket Open API (https://api.trafikinfo.trafikverket.se).
public final class TrafikverketClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.trafikinfo.trafikverket.se/v2/data.json")!

    public let endpoint: URL
    public let keyProvider: any APIKeyProvider
    private let session: URLSession
    private let userAgent: String

    public init(
        keyProvider: any APIKeyProvider,
        endpoint: URL = TrafikverketClient.defaultEndpoint,
        session: URLSession = .shared,
        userAgent: String = "Tagradar (+https://github.com/sebdanielsson/tagradar)"
    ) {
        self.keyProvider = keyProvider
        self.endpoint = endpoint
        self.session = session
        self.userAgent = userAgent
    }

    public convenience init(apiKey: String) {
        self.init(keyProvider: StaticAPIKey(apiKey))
    }

    /// Executes a single query and decodes the matching objects.
    public func fetch<Object: TRVObject>(_ query: Query<Object>) async throws -> QueryResult<Object> {
        guard let key = await keyProvider.apiKey(), !key.isEmpty else { throw TrafikverketError.missingAPIKey }
        let body = RequestDocument.render(apiKey: key, queries: [query.renderXML()])
        let data = try await post(body: body)
        return try ResponseEnvelope.decode(data, as: Object.self)
    }

    /// Decodes a response body fetched some other way, such as a recorded fixture.
    public static func decode<Object: TRVObject>(_ data: Data, as type: Object.Type) throws -> QueryResult<Object> {
        try ResponseEnvelope.decode(data, as: type)
    }

    private func makeRequest(body: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 30
        return request
    }

    /// Raw request for callers that compose several queries in one round trip.
    public func post(body: String) async throws -> Data {
        let request = makeRequest(body: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrafikverketError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw TrafikverketError.transport("No HTTP response") }
        switch http.statusCode {
        case 200 ... 299: return data
        case 401: throw TrafikverketError.invalidAuthentication
        default:
            // The API returns its own error body even on non-2xx; surface it when present.
            if let apiMessage = Self.extractErrorMessage(from: data) {
                throw TrafikverketError.api(source: nil, message: apiMessage)
            }
            throw TrafikverketError.http(status: http.statusCode)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = obj["RESPONSE"] as? [String: Any],
              let result = response["RESULT"] as? [[String: Any]] else { return nil }
        for block in result {
            if let err = block["ERROR"] as? [String: Any], let message = err["MESSAGE"] as? String {
                return message
            }
        }
        return nil
    }

    // MARK: Live updates (Server-Sent Events)

    /// Requests an SSE URL for the query and streams decoded objects as they change.
    ///
    /// With `includeSnapshot` the first element yielded is the result of the SSE-URL request itself;
    /// subsequent elements are deltas. Note that the API rejects `$dateadd`/`$now` filters together with
    /// `sseurl`, so callers typically fetch a filtered snapshot separately and stream an unfiltered query.
    /// The stream ends when the task is cancelled or the connection drops (callers should reconnect).
    public func stream<Object: TRVObject>(
        _ query: Query<Object>,
        includeSnapshot: Bool = true
    ) -> AsyncThrowingStream<QueryResult<Object>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initial = try await fetch(query.sseURL(true))
                    if includeSnapshot {
                        continuation.yield(initial)
                    }
                    guard let url = initial.info.sseURL else { throw TrafikverketError.sseUnavailable }
                    for try await result in events(from: url, as: Object.self) {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Step one of a live subscription: asks the API for the SSE URL matching `query`.
    public func liveURL(for query: Query<some TRVObject>) async throws -> URL {
        let result = try await fetch(query.sseURL(true))
        guard let url = result.info.sseURL else { throw TrafikverketError.sseUnavailable }
        return url
    }

    /// Step two: connects to the SSE URL and decodes each event into objects.
    public func events<Object: TRVObject>(
        from url: URL,
        as _: Object.Type
    ) -> AsyncThrowingStream<QueryResult<Object>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sse = SSEConnection(url: url, session: session, userAgent: userAgent)
                    for try await event in sse.events() {
                        try Task.checkCancellation()
                        guard !event.data.isEmpty else { continue }
                        let result = try ResponseEnvelope.decode(Data(event.data.utf8), as: Object.self)
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

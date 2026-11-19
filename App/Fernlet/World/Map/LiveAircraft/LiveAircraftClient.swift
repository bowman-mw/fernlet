import Foundation
import WebScrapingKit

// The one network seam of "Live planes nearby", and the only file that names adsb.lol's API host. It is pinned by name
// in the no-tracking wall's HTTP-client permit set (`NoTrackingBoundaryTests.pinnedWebImporterFiles`), and the wall
// also pins that the ONLY host hardcoded here is `api.adsb.lol` — see Docs/No-Tracking-Wall.md §3.
//
// It takes a `LiveAircraftCell` and nothing finer: the map's centre is snapped to the 0.5° grid before it gets here.
// Reading the answer is pure and lives in `LiveAircraftFeed.swift`; when to ask lives in `LiveAircraftWatch.swift`.

/// Builds and performs the single read-only adsb.lol request for one grid cell (owner 2026-11-19, the live-planes
/// build; Docs/Handoff live-planes report §10).
///
/// **What leaves the device, exhaustively:** one `GET` to `api.adsb.lol` whose path is the cell's centre (two numbers
/// on the 0.5° grid, ending .25 or .75) and the fixed radius of 50 nautical miles; `Accept: application/json` and a
/// `User-Agent` naming the app and its version. No key, account, identifier, query string or body. Plus what any HTTPS
/// request carries: the device's IP address and TLS metadata. No cookie can be sent or stored (the private-tab
/// `EphemeralWebSession`, Docs/No-Tracking-Wall.md §2a).
///
/// **Bounds:** a 10 s idle timeout, a 15 s whole-fetch deadline, a 1 MB response cap enforced while streaming,
/// redirects refused outright (a 3xx is a failed fetch, never a second host), and exactly one request per call:
/// nothing here retries. ``LiveAircraftWatch`` calls it at most every 30 s, under the daily cap of
/// ``LiveAircraftBudget``.
///
/// **Gate:** ``fetch(_:enabled:appVersion:transport:deadlineSeconds:)`` takes the switch's state and returns
/// `.notPermitted` without building a request when it is off; the watch's gate is not the only one.
nonisolated enum LiveAircraftClient {
    /// The point endpoint's base, `/v2/point/{lat}/{lon}/{radius}` (adsb.lol's OpenAPI, read 2026-11-18).
    static let pointEndpoint = "https://api.adsb.lol/v2/point/"

    /// The host the request must resolve to — checked on the built URL as a last guard.
    static let host = "api.adsb.lol"

    /// Idle timeout for the request (seconds without a byte).
    static let idleTimeoutSeconds: TimeInterval = 10

    /// Whole-fetch deadline: connection, headers and body together.
    static let overallDeadlineSeconds: TimeInterval = 15

    /// Response body cap. A busy 50 NM circle (Denver, 2026-11-18) was 71 planes, about 32 KB unzipped.
    static let maxResponseBytes = 1024 * 1024

    /// The request for `cell`, or nil if a URL cannot be formed (unreachable: the path is two grid numbers and a
    /// fixed radius).
    static func pointRequest(for cell: LiveAircraftCell, appVersion: String) -> URLRequest? {
        let path = "\(coordinate(cell.centreLatitude))/\(coordinate(cell.centreLongitude))/\(LiveAircraftCell.radiusNauticalMiles)"
        guard let url = URL(string: pointEndpoint + path), url.host() == host, url.scheme == "https", url.query == nil else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: idleTimeoutSeconds)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent(appVersion: appVersion), forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A grid centre as the path writes it: at most two decimals (every centre ends .25 or .75), no exponent.
    static func coordinate(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = abs(hundredths)
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }

    /// `Fernlet/<version>`: the version reduced to digits and dots, so nothing else can ride in it.
    static func userAgent(appVersion: String) -> String {
        let version = String(appVersion.filter { $0 == "." || ("0"..."9").contains($0) }.prefix(16))
        return "Fernlet/\(version.isEmpty ? "1.0" : version)"
    }

    /// Fetches `cell` once, if and only if `enabled` (the "Live planes nearby" switch) is on.
    static func fetch(
        _ cell: LiveAircraftCell,
        enabled: Bool,
        appVersion: String,
        transport: some LiveAircraftTransporting,
        deadlineSeconds: TimeInterval = overallDeadlineSeconds
    ) async -> LiveAircraftFetchOutcome {
        guard enabled else { return .notPermitted }
        guard deadlineSeconds > 0, let request = pointRequest(for: cell, appVersion: appVersion) else {
            return .failed
        }
        let response: LiveAircraftHTTPResponse
        do {
            response = try await withDeadline(seconds: deadlineSeconds) {
                try await transport.response(for: request, maxBytes: maxResponseBytes)
            }
        } catch {
            return .failed
        }
        return LiveAircraftFeed.outcome(statusCode: response.statusCode, retryAfter: response.retryAfter, body: response.body)
    }

    /// Runs `operation`, failing with ``LiveAircraftTransportError/timedOut`` once `seconds` pass (the same race as
    /// the Open Food Facts client's, which `URLSession`'s cancellation ends promptly).
    static func withDeadline<Value: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LiveAircraftTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LiveAircraftTransportError.timedOut }
            return first
        }
    }
}

/// One HTTP answer, reduced to what the feed reads.
nonisolated struct LiveAircraftHTTPResponse: Equatable, Sendable {
    /// The HTTP status code.
    let statusCode: Int
    /// The `Retry-After` header in seconds, when a 429 carries one.
    let retryAfter: TimeInterval?
    /// The body, at most ``LiveAircraftClient/maxResponseBytes`` long.
    let body: Data
}

/// Why the transport produced no response.
nonisolated enum LiveAircraftTransportError: Error, Equatable, Sendable {
    /// Connection, DNS, TLS or stream failure.
    case network
    /// The idle timeout or the whole-fetch deadline passed.
    case timedOut
    /// The body (declared or streamed) passed the cap.
    case oversize
    /// The response was not HTTP.
    case notHTTP
}

/// The seam between the fetch and the network, so every failure mode is testable offline.
///
/// Production uses ``EphemeralLiveAircraftTransport``; tests substitute a canned one.
nonisolated protocol LiveAircraftTransporting: Sendable {
    /// Performs `request`, returning at most `maxBytes` of body, or throws ``LiveAircraftTransportError``.
    func response(for request: URLRequest, maxBytes: Int) async throws -> LiveAircraftHTTPResponse
}

/// The production transport: `WebScrapingKit`'s private-tab `EphemeralWebSession` — no cookie jar, no cache, no
/// credential store — with every redirect refused and the body capped while it streams.
nonisolated struct EphemeralLiveAircraftTransport: LiveAircraftTransporting {
    /// Creates the stateless transport.
    init() {}

    /// Fetches `request`; see ``LiveAircraftTransporting/response(for:maxBytes:)``.
    func response(for request: URLRequest, maxBytes: Int) async throws -> LiveAircraftHTTPResponse {
        guard maxBytes > 0 else { throw LiveAircraftTransportError.oversize }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await EphemeralWebSession.shared.bytes(for: request, delegate: LiveAircraftRedirectRefusal())
        } catch {
            throw Self.transportError(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw LiveAircraftTransportError.notHTTP }
        guard http.expectedContentLength <= Int64(maxBytes) else { throw LiveAircraftTransportError.oversize }
        var body = Data()
        body.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            // Bounded: at most `maxBytes` bytes, then the stream is abandoned.
            for try await byte in bytes {
                guard body.count < maxBytes else { throw LiveAircraftTransportError.oversize }
                body.append(byte)
            }
        } catch let error as LiveAircraftTransportError {
            throw error
        } catch {
            throw Self.transportError(for: error)
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return LiveAircraftHTTPResponse(statusCode: http.statusCode, retryAfter: retryAfter, body: body)
    }

    /// A URL-loading error as a transport error: a timeout stays a timeout, anything else is "network".
    static func transportError(for error: any Error) -> LiveAircraftTransportError {
        (error as? URLError)?.code == .timedOut ? .timedOut : .network
    }
}

/// A per-task delegate that refuses every redirect, so the fetch can never reach a second host. Stateless, which is
/// why `@unchecked Sendable` is sound (the Open Food Facts client's `OpenFoodFactsRedirectRefusal` shape).
nonisolated final class LiveAircraftRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Creates the stateless delegate; one per task.
    override init() { super.init() }

    /// Refuses the redirect.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

import Foundation
import FernletDomainModel
import WebScrapingKit

// The one network seam of the optional online UPC lookup, and the only file that names Open Food
// Facts' host. It is pinned by name in the no-tracking wall's HTTP-client permit set
// (`NoTrackingBoundaryTests.pinnedWebImporterFiles`), and the wall also pins that the ONLY host
// hardcoded here is `world.openfoodfacts.org` — see Docs/No-Tracking-Wall.md §3.
//
// Everything the lookup does with the answer is pure and lives in `OpenFoodFactsProduct.swift`.

/// Builds and performs the single read-only Open Food Facts product request.
///
/// **What leaves the device, exhaustively:** one `GET` to `world.openfoodfacts.org` whose path is the
/// validated barcode digits and whose query names the fields wanted; `Accept`, `Accept-Language: en`
/// (fixed, so the device's own language list is not sent) and a `User-Agent` naming the app, its
/// version and the project site — Open Food Facts' API policy asks every client to identify itself
/// this way, and it carries no email, account, device identifier or anything about the user. Plus
/// what any HTTPS request carries: the device's IP address and TLS metadata. No cookie can be sent
/// or stored (the private-tab `EphemeralWebSession`, Docs/No-Tracking-Wall.md §2a).
///
/// **Bounds:** a 10 s idle timeout, a 20 s whole-lookup deadline, a 128 KB response cap enforced
/// while streaming, redirects refused outright (a 3xx is a failed lookup — never a second host), and
/// exactly one request per call: nothing here retries. The caller makes one call per explicit tap.
///
/// **Gate:** ``lookUp(_:under:appVersion:transport:deadlineSeconds:)`` re-checks the
/// web-nutrition-lookup consent itself and returns `.notPermitted` without building a request when
/// it is closed — the view's gate is not the only one.
nonisolated enum OpenFoodFactsClient {
    /// The product-read endpoint, pinned to API **v3.4**: the last version that still serves the
    /// classic flat `nutriments` object this parser reads. v3.5 introduced a new nutrition schema
    /// that Open Food Facts' own change log marks "still under active development", and v2 is
    /// deprecated; pinning a minor version is OFF's documented way to keep a stable shape.
    static let productEndpoint = "https://world.openfoodfacts.org/api/v3.4/product/"

    /// The host the request must resolve to — checked on the built URL as a last guard.
    static let host = "world.openfoodfacts.org"

    /// The only fields requested, so the response carries no images, ingredients or tags.
    static let requestedFields = [
        "product_name", "brands", "serving_size", "serving_quantity", "serving_quantity_unit",
        "nutrition_data_per", "no_nutrition_data", "nutriments"
    ]

    /// Idle timeout for the request (seconds without a byte).
    static let idleTimeoutSeconds: TimeInterval = 10

    /// Whole-lookup deadline: connection, headers and body together.
    static let overallDeadlineSeconds: TimeInterval = 20

    /// Response body cap. A field-trimmed product answer is a few KB; the Clif Bar record captured
    /// for the fixtures is 3.5 KB.
    static let maxResponseBytes = 128 * 1024

    /// The request for `barcode`, or `nil` if a URL cannot be formed (unreachable for a validated
    /// code — the path is 8–14 ASCII digits).
    static func productRequest(for barcode: OpenFoodFactsBarcode, appVersion: String) -> URLRequest? {
        guard var components = URLComponents(string: productEndpoint + barcode.lookupCode) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "fields", value: requestedFields.joined(separator: ",")),
            URLQueryItem(name: "product_type", value: "food")
        ]
        guard let url = components.url, url.host() == host, url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: idleTimeoutSeconds)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent(appVersion: appVersion), forHTTPHeaderField: "User-Agent")
        return request
    }

    /// `Fernlet/<version> (fernlet.com)` — Open Food Facts asks for `AppName/Version (contact)`.
    /// The contact is the project site, deliberately never an email address; the version is
    /// reduced to digits and dots so nothing else can ride in it.
    static func userAgent(appVersion: String) -> String {
        let version = String(appVersion.filter { $0 == "." || OpenFoodFactsBarcode.isASCIIDigit($0) }.prefix(16))
        return "Fernlet/\(version.isEmpty ? "1.0" : version) (fernlet.com)"
    }

    /// Looks `barcode` up once, if and only if `settings` permits the web-nutrition lane.
    static func lookUp(
        _ barcode: OpenFoodFactsBarcode,
        under settings: FernletSettings,
        appVersion: String,
        transport: some OpenFoodFactsTransporting,
        deadlineSeconds: TimeInterval = overallDeadlineSeconds
    ) async -> OpenFoodFactsLookupOutcome {
        guard settings.allowsWebNutritionLookup else { return .notPermitted }
        guard deadlineSeconds > 0, let request = productRequest(for: barcode, appVersion: appVersion) else {
            return .failed(.invalidRequest)
        }
        let response: OpenFoodFactsHTTPResponse
        do {
            response = try await withDeadline(seconds: deadlineSeconds) {
                try await transport.response(for: request, maxBytes: maxResponseBytes)
            }
        } catch let error as OpenFoodFactsTransportError {
            return .failed(error.failure)
        } catch {
            return .failed(.network)
        }
        return OpenFoodFactsResponseClassifier.outcome(
            statusCode: response.statusCode, contentType: response.contentType,
            body: response.body, barcode: barcode
        )
    }

    /// Runs `operation`, failing with ``OpenFoodFactsTransportError/timedOut`` once `seconds` pass.
    ///
    /// Two children race; the first to finish decides and the other is cancelled — which cancels
    /// the URL task, since `URLSession`'s async API honours task cancellation.
    static func withDeadline<Value: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw OpenFoodFactsTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OpenFoodFactsTransportError.timedOut }
            return first
        }
    }
}

/// One HTTP answer, reduced to the three things the classifier reads.
nonisolated struct OpenFoodFactsHTTPResponse: Equatable, Sendable {
    /// The HTTP status code.
    let statusCode: Int
    /// The raw `Content-Type` header, or `""`.
    let contentType: String
    /// The body, at most ``OpenFoodFactsClient/maxResponseBytes`` long.
    let body: Data
}

/// Why the transport produced no response.
nonisolated enum OpenFoodFactsTransportError: Error, Equatable, Sendable {
    /// Connection, DNS, TLS or stream failure.
    case network
    /// The idle timeout or the whole-lookup deadline passed.
    case timedOut
    /// The body (declared or streamed) passed the cap.
    case oversize
    /// The response was not HTTP.
    case notHTTP

    /// The lookup failure this transport error is reported as.
    var failure: OpenFoodFactsLookupFailure {
        switch self {
        case .network, .notHTTP: .network
        case .timedOut: .timedOut
        case .oversize: .oversize
        }
    }
}

/// The seam between the lookup and the network, so every failure mode is testable offline.
///
/// Production uses ``EphemeralOpenFoodFactsTransport``; tests substitute a canned one.
nonisolated protocol OpenFoodFactsTransporting: Sendable {
    /// Performs `request`, returning at most `maxBytes` of body, or throws
    /// ``OpenFoodFactsTransportError``.
    func response(for request: URLRequest, maxBytes: Int) async throws -> OpenFoodFactsHTTPResponse
}

/// The production transport: `WebScrapingKit`'s private-tab `EphemeralWebSession` — no cookie jar,
/// no cache, no credential store — with every redirect refused and the body capped while it streams.
nonisolated struct EphemeralOpenFoodFactsTransport: OpenFoodFactsTransporting {
    /// Creates the stateless transport.
    init() {}

    /// Fetches `request`; see ``OpenFoodFactsTransporting/response(for:maxBytes:)``.
    func response(for request: URLRequest, maxBytes: Int) async throws -> OpenFoodFactsHTTPResponse {
        guard maxBytes > 0 else { throw OpenFoodFactsTransportError.oversize }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await EphemeralWebSession.shared.bytes(
                for: request, delegate: OpenFoodFactsRedirectRefusal()
            )
        } catch {
            throw Self.transportError(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenFoodFactsTransportError.notHTTP }
        guard http.expectedContentLength <= Int64(maxBytes) else { throw OpenFoodFactsTransportError.oversize }
        var body = Data()
        body.reserveCapacity(min(maxBytes, 16 * 1024))
        do {
            for try await byte in bytes {
                guard body.count < maxBytes else { throw OpenFoodFactsTransportError.oversize }
                body.append(byte)
            }
        } catch let error as OpenFoodFactsTransportError {
            throw error
        } catch {
            throw Self.transportError(for: error)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return OpenFoodFactsHTTPResponse(statusCode: http.statusCode, contentType: contentType, body: body)
    }

    /// A URL-loading error as a transport error: a timeout stays a timeout, anything else is
    /// "network".
    static func transportError(for error: any Error) -> OpenFoodFactsTransportError {
        (error as? URLError)?.code == .timedOut ? .timedOut : .network
    }
}

/// A per-task delegate that refuses every redirect, so the lookup can never reach a second host —
/// not even an Open Food Facts sibling (the v3 API 302s a non-food product to Open Beauty Facts and
/// friends). The 3xx then stands as the final response, which the classifier reports as a failed
/// lookup. Stateless, which is why `@unchecked Sendable` is sound even though `URLSession` calls it
/// off the main actor — the same shape as the recipe importer's `RedirectValidator`.
nonisolated final class OpenFoodFactsRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

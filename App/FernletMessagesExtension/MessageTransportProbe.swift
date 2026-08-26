import Foundation
import FernletExchange

/// A Phase-0-only data-URL probe. It proves `MSMessage.url` can carry opaque bytes without
/// introducing a server or coupling the extension to Fernlet's repositories. The shared core now
/// owns the production envelope; this remains a deliberately smaller physical-device probe.
nonisolated enum MessageTransportProbe {
    static let maximumPayloadBytes = min(2 * 1024, ExchangeLimits.maxMessageEnvelopeBytes)
    private static let prefix = "data:application/vnd.fernlet.message-probe;base64,"

    static func url(for payload: Data) throws -> URL {
        guard payload.count <= maximumPayloadBytes else { throw MessageTransportProbeError.tooLarge }
        guard let url = URL(string: prefix + payload.base64EncodedString()) else {
            throw MessageTransportProbeError.invalidURL
        }
        return url
    }

    static func payload(from url: URL) throws -> Data {
        let text = url.absoluteString
        guard text.hasPrefix(prefix) else { throw MessageTransportProbeError.invalidURL }
        let encoded = String(text.dropFirst(prefix.count))
        guard encoded.utf8.count <= maximumPayloadBytes * 2,
              let payload = Data(base64Encoded: encoded), payload.count <= maximumPayloadBytes else {
            throw MessageTransportProbeError.invalidPayload
        }
        return payload
    }
}

nonisolated enum MessageTransportProbeError: LocalizedError {
    case invalidURL
    case invalidPayload
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Fernlet couldn't prepare the Messages transport check."
        case .invalidPayload: "Fernlet couldn't read the Messages transport check."
        case .tooLarge: "The Messages transport check is too large."
        }
    }
}

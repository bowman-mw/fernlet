import Compression
import Foundation

/// The version-2 wire form of a Messages card: one JSON document, compressed with raw DEFLATE,
/// framed, and encoded ONCE as base64url inside a `data:` URL.
///
/// **Why it exists.** Version 1 put the packet's JSON inside the envelope's JSON as base64
/// (`packetData`) and then base64-encoded the whole envelope into the URL: two base64 passes, so a
/// packet cost 16/9 of its size, and Apple's 5,000-character `MSMessage.url` carried a packet of
/// only about 2.6 KB. A twelve-step recipe was refused. Version 2 nests the packet as raw JSON in a
/// small document (``ExchangeMessageEnvelope`` builds and reads that document), deflates it, and
/// base64url-encodes the result once — about three times the capacity on realistic recipes, measured
/// by `FernletExchangeTests`.
///
/// **Frame layout** — the bytes the URL's base64url decodes to:
///
///     [magic 0x46 "F"] [frame version 0x02] [document length: UInt16, big-endian] [raw DEFLATE]
///
/// **The inflate bound is the load-bearing part.** DEFLATE reaches about 1,032:1, so a 3.7 KB frame
/// could otherwise claim almost 4 MB of memory in a process Messages hosts. The declared length is
/// checked against ``ExchangeLimits/maxMessageDocumentBytes`` before a byte is inflated, it then
/// becomes the inflater's hard ceiling (the output closure throws the moment the running total would
/// pass it), and the inflated count must equal it exactly — so a stream that was truncated, or that
/// lies about its length in either direction, is refused rather than half-read.
///
/// **Why raw DEFLATE, not LZFSE.** Measured on realistic recipe packets (2026-09-24), DEFLATE came
/// out about a quarter smaller than LZFSE at these sizes — below 4 KB LZFSE falls back to LZVN — and
/// it is the portable choice: Apple Compression's `.zlib` is raw RFC 1951 with no zlib header, which
/// `Inflater(nowrap: true)` reads as-is. `SealedPayloadFraming` in ProximityKit made the same call.
/// The Swift overlay's `OutputFilter` is used on both sides, so this seam needs no unsafe pointer.
///
/// **base64url, unpadded.** `-` and `_` instead of `+` and `/`, and no `=` — every character is
/// URL-unreserved, so no layer that normalises or percent-encodes a URL can change the bytes. The
/// decoder accepts that alphabet and nothing else.
nonisolated enum ExchangeMessageWireV2 {
    /// The version-2 URL prefix. A `data:` URL, like version 1, so no app — Fernlet included —
    /// is ever asked to open it; its body is the base64url text itself.
    static let dataURLPrefix = "data:application/vnd.fernlet.exchange.v2,"
    static let magic: UInt8 = 0x46
    static let frameVersion: UInt8 = 2
    static let headerByteCount = 4
    /// The filter's working buffer. The document is at most 13 KiB, and a small buffer means the
    /// inflate-bomb guard — which reads the running total after every chunk — trips sooner.
    private static let filterBufferBytes = 4_096

    /// Header plus the deflated document. Throws ``ExchangePacketError/tooLarge`` when the document
    /// is past ``ExchangeLimits/maxMessageDocumentBytes`` or the frame past
    /// ``ExchangeLimits/maxMessageFrameBytes`` — the composer's cue that the item needs a file.
    static func frame(document: Data) throws -> Data {
        guard !document.isEmpty else { throw ExchangePacketError.invalidPayload }
        guard document.count <= ExchangeLimits.maxMessageDocumentBytes else { throw ExchangePacketError.tooLarge }
        let body = try deflate(document)
        var frame = Data(capacity: headerByteCount + body.count)
        frame.append(contentsOf: [
            magic, frameVersion,
            UInt8(truncatingIfNeeded: document.count >> 8), UInt8(truncatingIfNeeded: document.count)
        ])
        frame.append(body)
        guard frame.count <= ExchangeLimits.maxMessageFrameBytes else { throw ExchangePacketError.tooLarge }
        return frame
    }

    /// The strict inverse of ``frame(document:)``: header checks, then a bounded inflate.
    static func document(fromFrame frame: Data) throws -> Data {
        guard frame.count > headerByteCount else { throw ExchangePacketError.invalidPayload }
        guard frame.count <= ExchangeLimits.maxMessageFrameBytes else { throw ExchangePacketError.tooLarge }
        let bytes = Data(frame) // normalise a slice's indices to start at zero — after the size check
        guard bytes[0] == magic else { throw ExchangePacketError.invalidPayload }
        guard bytes[1] == frameVersion else { throw ExchangePacketError.unsupportedFormat }
        let declared = Int(bytes[2]) << 8 | Int(bytes[3])
        guard declared > 0 else { throw ExchangePacketError.invalidPayload }
        guard declared <= ExchangeLimits.maxMessageDocumentBytes else { throw ExchangePacketError.tooLarge }
        let document = try inflate(bytes.subdata(in: headerByteCount..<bytes.count), limit: declared)
        guard document.count == declared else { throw ExchangePacketError.invalidPayload }
        return document
    }

    /// Unpadded base64url of `data`.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url, refusing any character outside that alphabet — including the
    /// standard alphabet's `+`, `/` and `=` — so each frame has exactly one spelling.
    static func base64URLDecoded(_ text: String) throws -> Data {
        let maximumCharacters = (ExchangeLimits.maxMessageFrameBytes * 4 + 2) / 3
        guard !text.isEmpty, text.utf8.count <= maximumCharacters,
              text.utf8.allSatisfy(isBase64URLCharacter), text.utf8.count % 4 != 1 else {
            throw ExchangePacketError.invalidMessageURL
        }
        let padding = String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + padding) else { throw ExchangePacketError.invalidMessageURL }
        return data
    }

    private static func isBase64URLCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    /// Raw DEFLATE of the whole document. The output is at most the input plus a few block headers,
    /// and the caller has already bounded the input.
    private static func deflate(_ document: Data) throws -> Data {
        guard !document.isEmpty else { throw ExchangePacketError.invalidPayload }
        var body = Data()
        do {
            let filter = try OutputFilter(.compress, using: .zlib, bufferCapacity: filterBufferBytes) { chunk in
                if let chunk { body.append(chunk) }
            }
            try filter.write(document)
            try filter.finalize()
        } catch {
            throw ExchangePacketError.invalidPayload
        }
        return body
    }

    /// Inflates `body`, refusing to hold more than `limit` bytes: the output closure throws before
    /// appending a chunk that would pass it, which unwinds the filter mid-stream, so at most `limit`
    /// bytes plus one filter buffer are ever resident. A truncated or corrupt stream is refused by
    /// the filter itself (`finalize()` throws on an unterminated stream).
    private static func inflate(_ body: Data, limit: Int) throws -> Data {
        guard limit > 0, !body.isEmpty else { throw ExchangePacketError.invalidPayload }
        var document = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: filterBufferBytes) { chunk in
                guard let chunk else { return }
                guard document.count + chunk.count <= limit else { throw ExchangePacketError.tooLarge }
                document.append(chunk)
            }
            try filter.write(body)
            try filter.finalize()
        } catch ExchangePacketError.tooLarge {
            throw ExchangePacketError.tooLarge
        } catch {
            throw ExchangePacketError.invalidPayload
        }
        return document
    }
}

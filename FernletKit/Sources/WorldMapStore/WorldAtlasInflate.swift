import Compression
import Foundation

/// The atlas pack's one unsafe-pointer seam: raw DEFLATE (RFC 1951, no zlib header) through Apple's
/// Compression framework (`COMPRESSION_ZLIB`, `compression_decode_buffer`), the format
/// Docs/World-Atlas-Pack.md names for every section body.
///
/// Bounded: the destination is exactly `rawLength + 1` bytes, allocated before decoding, so a stream that
/// would expand further (a deflate bomb) stops at that size and is refused, as is one that comes up short.
/// No pointer escapes the closures (Scripts/power-of-10-allowlist.json, R9-UNSAFE).
nonisolated enum WorldAtlasInflate {
    /// The `rawLength` bytes `stored` inflates to, or nil when it is empty, is not raw DEFLATE, or inflates
    /// to any other length.
    static func inflate(_ stored: Data, rawLength: Int) -> [UInt8]? {
        guard !stored.isEmpty, rawLength > 0, rawLength <= WorldAtlasPack.maxRawSectionBytes else { return nil }
        let source = [UInt8](stored)
        var output = [UInt8](repeating: 0, count: rawLength + 1)
        let written = output.withUnsafeMutableBufferPointer { destination -> Int in
            source.withUnsafeBufferPointer { input -> Int in
                guard let to = destination.baseAddress, let from = input.baseAddress else { return 0 }
                return compression_decode_buffer(to, destination.count, from, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == rawLength else { return nil }
        output.removeLast()
        return output
    }
}

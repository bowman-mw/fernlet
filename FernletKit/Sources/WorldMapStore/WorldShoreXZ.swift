import Compression
import Foundation

/// The shore pack's one unsafe-pointer seam: an xz stream (Docs/World-Shore-Pack.md, "A stored tile") through
/// Apple's Compression framework (`COMPRESSION_LZMA`, `compression_decode_buffer`).
///
/// Bounded: the destination is exactly `limit + 1` bytes, allocated before decoding, so a stream that would expand
/// further (a bomb) stops at that size and is refused. No pointer escapes the closures
/// (Scripts/power-of-10-allowlist.json, R9-UNSAFE).
nonisolated enum WorldShoreXZ {
    /// The bytes `stored` decodes to, at most `limit` of them, or nil when it is empty, is not an xz stream, decodes
    /// to nothing, or would decode to more than `limit`.
    static func decode(_ stored: [UInt8], limit: Int) -> [UInt8]? {
        guard !stored.isEmpty, limit > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: limit + 1)
        let written = output.withUnsafeMutableBufferPointer { destination -> Int in
            stored.withUnsafeBufferPointer { input -> Int in
                guard let to = destination.baseAddress, let from = input.baseAddress else { return 0 }
                return compression_decode_buffer(to, destination.count, from, input.count, nil, COMPRESSION_LZMA)
            }
        }
        guard written > 0, written <= limit else { return nil }
        output.removeLast(output.count - written)
        return output
    }
}

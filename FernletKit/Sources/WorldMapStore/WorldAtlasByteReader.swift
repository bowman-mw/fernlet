import Foundation

/// Why a World atlas pack was refused (Docs/World-Atlas-Pack.md). Every case names the section tag it
/// happened in where there is one; the strings are tokens for logs and tests, never display text.
public nonisolated enum WorldAtlasPackError: Error, Equatable, Sendable {
    /// The file is bigger than ``WorldAtlasPack/maxPackBytes``.
    case tooLarge
    /// The first four bytes are not "FWA1".
    case badMagic
    /// The version is not ``WorldAtlasPack/version``.
    case badVersion
    /// The header or section table is cut off, or names no sections or too many.
    case badTable
    /// A tag appears twice in the table.
    case duplicateSection(String)
    /// A section's stored bytes run past the end of the file.
    case sectionOutOfBounds(String)
    /// A section's `rawLength` is zero or over ``WorldAtlasPack/maxRawSectionBytes``.
    case sectionTooLarge(String)
    /// A section's bytes are not raw DEFLATE, or inflate to a length other than its `rawLength`.
    case wrongRawLength(String)
    /// A required section is missing.
    case missingSection(String)
    /// A section's inflated body ends in the middle of a field.
    case truncated(String)
    /// A field holds a value the format does not allow (the second string names the field).
    case malformed(String, String)
}

/// Reads one inflated section body front to back: little-endian integers, length-prefixed strings and
/// zigzag LEB128 varints, each read checked against the end, so a short or damaged body throws
/// ``WorldAtlasPackError`` and never traps.
nonisolated struct AtlasByteReader {
    /// The section's tag, for the errors.
    let tag: String
    private let storage: [UInt8]
    private(set) var index = 0

    /// A reader over `bytes` from section `tag`.
    init(_ bytes: [UInt8], tag: String) {
        storage = bytes
        self.tag = tag
    }

    /// Whether every byte has been read.
    var isAtEnd: Bool { index >= storage.count }

    /// Bytes not yet read.
    var remaining: Int { storage.count - index }

    /// Throws unless every byte has been read (trailing bytes are a malformed section).
    func expectEnd() throws {
        guard isAtEnd else { throw WorldAtlasPackError.malformed(tag, "trailingBytes") }
    }

    /// The next `count` bytes.
    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw WorldAtlasPackError.truncated(tag) }
        let slice = storage[index..<(index + count)]
        index += count
        return slice
    }

    /// The next byte.
    mutating func u8() throws -> UInt8 {
        guard index < storage.count else { throw WorldAtlasPackError.truncated(tag) }
        let value = storage[index]
        index += 1
        return value
    }

    /// The next little-endian `UInt16`.
    mutating func u16() throws -> UInt16 {
        let slice = try bytes(2)
        guard let low = slice.first, let high = slice.last else { throw WorldAtlasPackError.truncated(tag) }
        return UInt16(low) | UInt16(high) << 8
    }

    /// The next little-endian `UInt32`.
    mutating func u32() throws -> UInt32 {
        let slice = try bytes(4)
        guard slice.count == 4 else { throw WorldAtlasPackError.truncated(tag) }
        var value: UInt32 = 0
        for (shift, byte) in zip(stride(from: UInt32(0), to: 32, by: 8), slice) {
            value |= UInt32(byte) << shift
        }
        return value
    }

    /// The next little-endian `Int32`.
    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    /// The next `count` bytes as ASCII letters (a country code), refusing anything else.
    mutating func ascii(_ count: Int, field: String) throws -> String {
        let slice = try bytes(count)
        guard slice.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A || $0 >= 0x61 && $0 <= 0x7A || $0 >= 0x30 && $0 <= 0x39 }),
              let text = String(bytes: slice, encoding: .ascii) else {
            throw WorldAtlasPackError.malformed(tag, field)
        }
        return text
    }

    /// The next `u8 len · bytes` UTF-8 string.
    mutating func shortString(field: String) throws -> String {
        let length = Int(try u8())
        let slice = try bytes(length)
        guard let text = String(bytes: slice, encoding: .utf8) else { throw WorldAtlasPackError.malformed(tag, field) }
        return text
    }

    /// The next zigzag LEB128 varint: at most ten bytes, refusing a longer one or one cut off at the end.
    mutating func zigzag() throws -> Int64 {
        var value: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 70, by: 7) {
            let byte = try u8()
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
            }
        }
        throw WorldAtlasPackError.malformed(tag, "varint")
    }
}

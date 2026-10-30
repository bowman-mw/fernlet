import CryptoKit
import Foundation

/// The bundled World atlas file, opened: its header and section table checked and every section inflated,
/// exactly as Docs/World-Atlas-Pack.md lays it out (`FWA1`, version 1, little-endian, raw DEFLATE bodies).
///
/// It refuses (throwing ``WorldAtlasPackError``, never trapping) a file over ``maxPackBytes``, a wrong magic
/// or version, a table that is cut off or names no sections or more than ``maxSections``, a tag listed twice,
/// a section past the end of the file, a `rawLength` of zero or over ``maxRawSectionBytes``, a body that is not
/// raw DEFLATE or inflates to any other length, and a missing required section (``requiredTags``). What the
/// sections hold is read by ``WorldAtlas``.
public nonisolated struct WorldAtlasPack: Sendable {
    /// The file's first four bytes.
    public static let magic: [UInt8] = Array("FWA1".utf8)
    /// The one format version this reader knows.
    public static let version: UInt16 = 1
    /// The whole file's cap: 6 MiB (the generator refuses to write more, `WorldAtlasPackTests` fails more).
    public static let maxPackBytes = 6_291_456
    /// One section's inflated cap: 64 MiB (the shipped grid's largest section is 6.5 MB).
    public static let maxRawSectionBytes = 67_108_864
    /// The most sections a table may list (the format has ten).
    public static let maxSections = 16
    /// The shipped `WorldAtlas.pack`'s SHA-256, in lowercase hex (generated 2026-10-30 by
    /// `Scripts/world-atlas/build_world_atlas.py`). Regenerating the pack changes it on purpose, in the same
    /// commit.
    public static let expectedSHA256 = "650281bbe4637ec160aca06f7954cf4f783a30df8572d4542e23a69006b456c5"
    /// The sections every pack must carry (`META`, the generator's provenance, is optional).
    public static let requiredTags = ["LAND", "CLIM", "OCEA", "CONT", "SEAS", "CTRY", "URBN", "CITY", "ADM1", "ROAD"]
    /// Bytes in the fixed header (magic, version, section count).
    static let headerBytes = 8
    /// Bytes in one table entry (tag, offset, stored length, raw length).
    static let tableEntryBytes = 16

    /// Every section's inflated body, by tag.
    public let sections: [String: [UInt8]]

    /// The lowercase hex SHA-256 of `data` (what ``expectedSHA256`` pins).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Opens `data`, inflating every section, or throws why it is refused.
    public init(data: Data) throws {
        guard data.count <= Self.maxPackBytes else { throw WorldAtlasPackError.tooLarge }
        let bytes = [UInt8](data)
        let entries = try Self.table(of: bytes)
        var sections: [String: [UInt8]] = [:]
        // Bounded: at most maxSections entries (table(of:) refuses more).
        for entry in entries {
            guard sections[entry.tag] == nil else { throw WorldAtlasPackError.duplicateSection(entry.tag) }
            sections[entry.tag] = try Self.body(of: entry, in: bytes)
        }
        for tag in Self.requiredTags where sections[tag] == nil {
            throw WorldAtlasPackError.missingSection(tag)
        }
        self.sections = sections
    }

    /// The inflated body of the required section `tag`.
    func section(_ tag: String) throws -> [UInt8] {
        guard let body = sections[tag] else { throw WorldAtlasPackError.missingSection(tag) }
        return body
    }

    /// One row of the section table.
    struct TableEntry: Equatable {
        /// The four-letter tag.
        let tag: String
        /// Where the stored bytes start, from the start of the file.
        let offset: Int
        /// How many stored (deflated) bytes.
        let storedLength: Int
        /// How many bytes they inflate to.
        let rawLength: Int
    }

    /// The header checked and the table read.
    static func table(of bytes: [UInt8]) throws -> [TableEntry] {
        guard bytes.count >= headerBytes else { throw WorldAtlasPackError.badTable }
        guard Array(bytes[0..<4]) == magic else { throw WorldAtlasPackError.badMagic }
        var reader = AtlasByteReader(Array(bytes[4..<headerBytes]), tag: "HEAD")
        guard try reader.u16() == version else { throw WorldAtlasPackError.badVersion }
        let count = Int(try reader.u16())
        guard count >= 1, count <= maxSections, bytes.count >= headerBytes + count * tableEntryBytes else {
            throw WorldAtlasPackError.badTable
        }
        var entries: [TableEntry] = []
        // Bounded: count <= maxSections.
        for slot in 0..<count {
            let start = headerBytes + slot * tableEntryBytes
            entries.append(try entry(Array(bytes[start..<(start + tableEntryBytes)])))
        }
        return entries
    }

    /// One 16-byte table row.
    private static func entry(_ row: [UInt8]) throws -> TableEntry {
        var reader = AtlasByteReader(row, tag: "TABL")
        guard let tag = String(bytes: try reader.bytes(4), encoding: .ascii), tag.count == 4 else {
            throw WorldAtlasPackError.badTable
        }
        let offset = Int(try reader.u32()), stored = Int(try reader.u32()), raw = Int(try reader.u32())
        return TableEntry(tag: tag, offset: offset, storedLength: stored, rawLength: raw)
    }

    /// The section's stored bytes, inflated and checked against its `rawLength`.
    private static func body(of entry: TableEntry, in bytes: [UInt8]) throws -> [UInt8] {
        guard entry.offset >= headerBytes, entry.storedLength > 0,
              entry.offset <= bytes.count, entry.storedLength <= bytes.count - entry.offset else {
            throw WorldAtlasPackError.sectionOutOfBounds(entry.tag)
        }
        guard entry.rawLength > 0, entry.rawLength <= maxRawSectionBytes else {
            throw WorldAtlasPackError.sectionTooLarge(entry.tag)
        }
        let stored = Data(bytes[entry.offset..<(entry.offset + entry.storedLength)])
        guard let raw = WorldAtlasInflate.inflate(stored, rawLength: entry.rawLength) else {
            throw WorldAtlasPackError.wrongRawLength(entry.tag)
        }
        return raw
    }
}

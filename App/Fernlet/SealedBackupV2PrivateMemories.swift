import CryptoKit
import FernletDomainModel
import Foundation

// SealedBackupV2PrivateMemories.swift — the private memories (G9-3, owner call M6 = A: "include private
// memories in the encrypted backup now") on the head of the journal's Sealed backup v2 set. Like the
// body tallies they are not a payload of their own: they ride the journal set's head under the frozen
// key `"privateMemories"`, sealed by exactly the journal chunks' content-key path, never plain in
// CloudKit, and follow the journal's switch (no new switch), owner hold, compare-and-swap, spacing and
// deletes.

/// The `"privateMemories"` value on a journal set's head (FROZEN keys): `{"v":1,"memories":[…]}`, each
/// memory a `MemoryNote` under its own frozen keys (`id`, `category`, `text`, `sourceDate`, and
/// `userEdited` only when true), oldest first.
///
/// **Skipped, never failed, when it can't be read.** A build that does not know the `"privateMemories"`
/// key ignores it (it decodes only the keys it knows), so its journal restore is unchanged. And a
/// section whose `v` is not ``formatVersion`` (a newer Fernlet's shape) decodes as an EMPTY section
/// naming that version (``newerVersion``): the journal restores, the section is skipped and logged, and
/// nothing about it fails the restore. The cost, accepted for both cases (the body tallies' rule): such a
/// build's next journal export writes a head without the newer memories, and the newer iPhone's next
/// export puts them back.
///
/// `nonisolated`: a plain value encoded inside the envelope, never crossing into main-actor code.
nonisolated struct SealedBackupPrivateMemories: Codable, Equatable, Sendable {
    /// The shape this build writes and reads.
    static let formatVersion = 1

    /// Every private memory, oldest first (empty for a skipped section).
    var memories: [MemoryNote]
    /// The section's `v` when a newer Fernlet wrote a shape this build does not read; nil for this
    /// build's own shape. Never encoded.
    private(set) var newerVersion: Int?

    /// The frozen keys.
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case memories
    }

    /// Creates the value; `memories` are put oldest first (ties by id).
    init(memories: [MemoryNote]) {
        self.memories = memories.sorted {
            $0.sourceDate != $1.sourceDate ? $0.sourceDate < $1.sourceDate : $0.id.uuidString < $1.id.uuidString
        }
        self.newerVersion = nil
    }

    /// Decodes; a `v` other than ``formatVersion`` gives an empty section naming that version (skipped
    /// by the restore), never an error.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            memories = []
            newerVersion = version
            return
        }
        memories = try container.decode([MemoryNote].self, forKey: .memories)
        newerVersion = nil
    }

    /// Encodes the frozen shape (always this build's version).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(memories, forKey: .memories)
    }
}

/// The head's `"privateMemories"` field alone — what a journal restore reads from the head without
/// decoding its records a second time.
nonisolated struct SealedBackupV2EnvelopePrivateMemories: Decodable, Sendable {
    /// The private memories, or nil when the head carries none.
    var privateMemories: SealedBackupPrivateMemories?

    /// The one frozen key read.
    private enum CodingKeys: String, CodingKey {
        case privateMemories
    }

    /// Decodes the field (absent is nil).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        privateMemories = try container.decodeIfPresent(SealedBackupPrivateMemories.self, forKey: .privateMemories)
    }
}

extension SealedBackupV2Format {
    /// The private memories a head plaintext carries, or nil (a v1 set never carries any). A newer
    /// Fernlet's shape comes back as a skipped section (``SealedBackupPrivateMemories/newerVersion``);
    /// throws a `DecodingError` only when the field is this build's shape and will not decode.
    static func privateMemories(of plaintext: Data) throws -> SealedBackupPrivateMemories? {
        guard !isV1(plaintext) else { return nil }
        return try JSONDecoder().decode(SealedBackupV2EnvelopePrivateMemories.self, from: plaintext).privateMemories
    }
}

/// How the journal's Sealed backup adapter reaches the private memories: the host's two members,
/// wrapped so the adapter never holds a store. Both take the live hub key and both throw — never an
/// empty answer — in a decoy and whenever the memories can't be read or merged right now.
struct SealedBackupPrivateMemoryBridge {
    /// Every private memory now, oldest first; throws when they can't be read right now.
    let export: @MainActor (SymmetricKey) throws -> [MemoryNote]
    /// Merges restored memories into this iPhone's (absent ones added, never a delete); throws when
    /// they were not saved.
    let merge: @MainActor ([MemoryNote], SymmetricKey) throws -> Void
}

extension SealedBackupV2Adapter {
    /// No private memories ride this payload's head (only the journal's carries them).
    func headPrivateMemories(hubKey: SymmetricKey) throws -> SealedBackupPrivateMemories? { nil }

    /// Private memories on this payload's head are not this payload's to keep: they are ignored.
    func restorePrivateMemories(_ section: SealedBackupPrivateMemories, hubKey: SymmetricKey) throws {}
}

import Foundation
import PrivateHealthStore

// SealedBackupV2BodyTallies.swift — the body tallies (bathroom visits and free-meal tags, World
// bodybuilding spec §7, owner's answer 2: "inside the sealed iCloud backup") on the head of the
// journal's Sealed backup v2 set (round 7 piece B2). The tallies are not a payload of their own: they
// ride the journal set's head under the frozen key `"bodyTally"`, so they are sealed by exactly the
// journal chunks' content-key path, never plain in CloudKit, and follow the journal's switch, owner
// hold, compare-and-swap, spacing and deletes.

/// The `"bodyTally"` value on a journal set's head (§5.1, FROZEN keys): `{"v":1,"days":[…]}`, each
/// day a ``BodyDayTally`` under its own frozen keys (`dayKey`, `bathroomVisits`, `freeMealIDs`,
/// `updatedAt`), in day order.
///
/// Versioned on its own, so a later shape is told apart from this one: a `v` other than
/// ``formatVersion`` is a decoding error, which the restore turns into
/// ``SealedBackupV2FormatError/unreadableRecords`` (`needsNewerFernlet`: never dropped, never written
/// over). An earlier build that does not know the `"bodyTally"` key ignores it (it decodes only the
/// keys it knows), so its journal restore is unchanged; its next journal export writes a head without
/// it, and this build's next export puts every tally back.
///
/// `nonisolated`: a plain value encoded inside the envelope, never crossing into main-actor code.
nonisolated struct SealedBackupBodyTallies: Codable, Equatable, Sendable {
    /// The shape this build writes and reads.
    static let formatVersion = 1

    /// Every tally, in day order.
    var days: [BodyDayTally]

    /// The frozen keys.
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case days
    }

    /// Creates the value; `days` are put in day order.
    init(days: [BodyDayTally]) {
        self.days = days.sorted { $0.dayKey < $1.dayKey }
    }

    /// Decodes; a `v` other than ``formatVersion`` throws a `DecodingError` (a newer Fernlet's shape).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "a newer body-tally shape")
        }
        days = try container.decode([BodyDayTally].self, forKey: .days)
    }

    /// Encodes the frozen shape.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(days, forKey: .days)
    }
}

/// The head's `"bodyTally"` field alone — what a journal restore reads from the head without decoding
/// its records a second time.
nonisolated struct SealedBackupV2EnvelopeBodyTally: Decodable, Sendable {
    /// The tallies, or nil when the head carries none.
    var bodyTally: SealedBackupBodyTallies?

    /// The one frozen key read.
    private enum CodingKeys: String, CodingKey {
        case bodyTally
    }

    /// Decodes the field (absent is nil).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bodyTally = try container.decodeIfPresent(SealedBackupBodyTallies.self, forKey: .bodyTally)
    }
}

extension SealedBackupV2Format {
    /// The body tallies a head plaintext carries, or nil (a v1 set never carries any). Throws a
    /// `DecodingError` when the field is there but this build cannot read it.
    static func bodyTallies(of plaintext: Data) throws -> SealedBackupBodyTallies? {
        guard !isV1(plaintext) else { return nil }
        return try JSONDecoder().decode(SealedBackupV2EnvelopeBodyTally.self, from: plaintext).bodyTally
    }
}

/// How the journal's Sealed backup adapter reaches the body tallies (round 7 piece B2): the host's
/// two members, wrapped so the adapter never holds a store. Both throw — never an empty answer — in a
/// decoy and whenever the tallies can't be read or merged right now.
struct SealedBackupBodyTallyBridge {
    /// Every tally now, in day order; throws when they can't be read right now.
    let export: @MainActor () throws -> [BodyDayTally]
    /// Merges restored tallies into this iPhone's (higher count, union of tags, never a delete);
    /// throws when they were not saved.
    let merge: @MainActor ([BodyDayTally]) throws -> Void
}

extension SealedBackupV2Adapter {
    /// No body tallies ride this payload's head (only the journal's carries them).
    func headBodyTallies() throws -> SealedBackupBodyTallies? { nil }

    /// Body tallies on this payload's head are not this payload's to keep: they are ignored.
    func restoreBodyTallies(_ tallies: SealedBackupBodyTallies) throws {}
}

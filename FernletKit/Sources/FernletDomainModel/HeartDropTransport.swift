import Foundation

// Heart dead-drop transport seam (bitchat adoptions Increment 3,
// Docs/Plan-Bitchat-Adoptions-2026-07-25.md).
//
// Lives in FernletDomainModel for the same reason `HeartPayload` does (see HeartSharing.swift):
// this module is a dependency of BOTH ProximityKit (which does all sealing/tag crypto and must
// never import CloudKit) and CloudKitSync (which ferries opaque records and must never reach the
// sealed side). The S3 wall stays intact by construction — the transport sees only
// pseudonymous day tags and ciphertext.

/// An opaque dead-drop record: a rotating pairwise day tag and a sealed blob. The transport
/// neither knows nor can learn who either endpoint is.
public nonisolated struct HeartDropRecord: Sendable, Equatable {
    public let tag: String
    public let payload: Data
    /// Server-assigned name, used only by the WRITER for its own expiry cleanup.
    public let recordName: String

    public init(tag: String, payload: Data, recordName: String) {
        self.tag = tag
        self.payload = payload
        self.recordName = recordName
    }
}

/// Ferry for heart-drop records. Implemented by CloudKitSync over the PUBLIC database (the
/// "no servers the user operates" decision, 2026-06); a future BLE courier or test mock
/// implements the same seam. All calls are best-effort network operations — callers own retry,
/// consent gating, and every byte of crypto.
public nonisolated protocol HeartDropTransporting: Sendable {
    /// Whether an account capable of writing/reading drops is available right now.
    func accountAvailable() async -> Bool
    /// Uploads one sealed drop under `tag`; returns the server record name for later cleanup.
    func upload(tag: String, payload: Data) async throws -> String
    /// Fetches every record whose tag is in `tags` (the caller computes its expected pickup
    /// window — e.g. per-friend tags for the last 7 UTC days).
    func fetch(tags: [String]) async throws -> [HeartDropRecord]
    /// Deletes records THIS user created (expiry cleanup; recipients cannot delete a sender's
    /// records in a public database — they dedup instead).
    func deleteOwnRecords(recordNames: [String]) async throws
}

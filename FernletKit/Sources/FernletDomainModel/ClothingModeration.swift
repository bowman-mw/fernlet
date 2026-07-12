// ClothingModeration.swift
// FernletDomainModel
//
// Value types + pure verdict math for the in-person clothing-shop content-moderation system.
// Wall-safe (no crypto, no sealed types): the append-only report ledger row, its wire-tolerant
// enums, the escalation thresholds, and the deterministic tally functions. The SHA-256 content
// hash itself is computed in ProximityKit (where CryptoKit lives) and handed in as `Data`.
//
// Design (2026-07-11 ban memo): reports key on the transport-VERIFIED reporter/subject signing
// keys and a content hash of the artwork — never the attacker-settable `designerID`. Verdicts are
// LOCAL and per-device over reports the device personally verified; there is no global count.

import Foundation

/// Why a shop item / peer was reported. Stored on the ledger as a raw token so a reason minted by a
/// NEWER build survives on an older client (forward-tolerant, like every other wire enum here).
public nonisolated enum ReportReason: String, Codable, CaseIterable, Sendable, Identifiable {
    case offensive
    case sexual
    case hateful
    case spam
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .offensive: "Offensive or inappropriate"
        case .sexual: "Sexual content"
        case .hateful: "Hateful or harassing"
        case .spam: "Spam or scam"
        case .other: "Something else"
        }
    }
}

/// A ledger row is either a report or its retraction (undo). Freeze-on-unknown + parked token so a
/// future kind can't brick an older decoder.
public nonisolated enum ModerationEntryKind: String, Codable, CaseIterable, Sendable {
    case report
    case retract
}

/// One append-only moderation-log row. `id` is deterministic (`kind:reporterFingerprint:contentHashHex`)
/// so the same reporter reporting the same artwork de-dupes structurally and a retract supersedes its
/// report by a higher `reporterSeq`. Persisted only in a device-local sidecar — never synced.
public nonisolated struct ModerationLedgerEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ModerationEntryKind {
        didSet { unknownKindToken = nil }
    }
    public var unknownKindToken: String? = nil
    /// Transport-verified signing key of the reporter (== this device's own key for local reports).
    public var reporterSigningPublicKey: Data
    /// Transport-verified signing key of the reported designer.
    public var subjectSigningPublicKey: Data
    /// The reported item's id — display/correlation only, NOT the dedup key (a designer can rotate it).
    public var itemID: UUID
    /// SHA-256 over the sanitized artwork (texture + slot) — the stable moderation key across
    /// itemID/name/price/identity rotation. Computed in ProximityKit.
    public var contentHash: Data
    /// Raw `ReportReason` token, kept forward-tolerant.
    public var reasonToken: String
    /// Per-(reporter, contentHash) monotone counter so a retract can supersede its report.
    public var reporterSeq: UInt64
    public var createdAt: Date

    public init(
        id: String,
        kind: ModerationEntryKind,
        reporterSigningPublicKey: Data,
        subjectSigningPublicKey: Data,
        itemID: UUID,
        contentHash: Data,
        reasonToken: String,
        reporterSeq: UInt64,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.reporterSigningPublicKey = reporterSigningPublicKey
        self.subjectSigningPublicKey = subjectSigningPublicKey
        self.itemID = itemID
        self.contentHash = contentHash
        self.reasonToken = reasonToken
        self.reporterSeq = reporterSeq
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let kindSplit = try c.decodeTolerantRequiredEnum(
            ModerationEntryKind.self, forKey: .kind, parkedTokenKey: .unknownKindToken, default: .report)
        kind = kindSplit.value
        unknownKindToken = kindSplit.parkedToken
        reporterSigningPublicKey = try c.decode(Data.self, forKey: .reporterSigningPublicKey)
        subjectSigningPublicKey = try c.decode(Data.self, forKey: .subjectSigningPublicKey)
        itemID = try c.decode(UUID.self, forKey: .itemID)
        contentHash = try c.decode(Data.self, forKey: .contentHash)
        reasonToken = try c.decodeIfPresent(String.self, forKey: .reasonToken) ?? ReportReason.other.rawValue
        reporterSeq = try c.decodeIfPresent(UInt64.self, forKey: .reporterSeq) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// Lowercase hex of a hash, for the deterministic row id.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The deterministic union-merge id for a row.
    public static func rowID(kind: ModerationEntryKind, reporterFingerprint: String, contentHash: Data) -> String {
        "\(kind.rawValue):\(reporterFingerprint):\(hex(contentHash))"
    }

    /// Deterministic bytes a reporter signs (and a receiver re-derives to verify) — pure, no crypto.
    /// Order-stable; both devices produce identical bytes for the same row. `createdAt` is included at
    /// whole-second resolution so a hostile future date is bound into the signature (the receiver may
    /// then clamp the STORED createdAt to receipt time for decay without touching verification).
    public static func canonicalSignedBytes(_ e: ModerationLedgerEntry) -> Data {
        let fields = [
            e.kind.rawValue,
            hex(e.reporterSigningPublicKey),
            hex(e.subjectSigningPublicKey),
            e.itemID.uuidString,
            hex(e.contentHash),
            e.reasonToken,
            String(e.reporterSeq),
            String(Int(e.createdAt.timeIntervalSinceReferenceDate.rounded())),
        ]
        return Data(fields.joined(separator: "\n").utf8)
    }
}

/// Escalation thresholds for the clothing shop (proposed 2026-07-11; tunable). Pure constants.
public nonisolated enum ClothingModerationLimits {
    /// Distinct verified reporters of one artwork before it becomes locally unlistable/hidden.
    public static let itemUnlistableReporters = 2
    /// Distinct reported artworks (each meeting `itemUnlistableReporters`) from one designer before a
    /// store ban.
    public static let designerBanItems = 3
    /// A single reporter counts toward at most this many of a designer's items (anti-Sybil griefing).
    public static let perReporterItemCap = 2
    /// Reports older than this stop counting toward escalation.
    public static let reportDecayDays = 180
    /// How long a designer store ban lasts.
    public static let banDurationDays = 30
}

/// Pure, deterministic verdict math over a set of verified ledger rows. No I/O, no crypto, no clock
/// beyond the `now` passed in. Used by the app-layer moderation store for local enforcement decisions.
public nonisolated enum ModerationEconomy {
    /// Live (non-retracted, non-decayed) rows: a `report` with no later `retract` from the same
    /// reporter for the same content, within the decay window.
    public static func liveReports(_ rows: [ModerationLedgerEntry], now: Date) -> [ModerationLedgerEntry] {
        let cutoff = now.addingTimeInterval(-Double(ClothingModerationLimits.reportDecayDays) * 86_400)
        // Group by (reporter, contentHash); the highest-seq row wins. A retract that wins voids the report.
        var winner: [String: ModerationLedgerEntry] = [:]
        for row in rows {
            let key = "\(hex(row.reporterSigningPublicKey)):\(hex(row.contentHash))"
            if let existing = winner[key], existing.reporterSeq >= row.reporterSeq { continue }
            winner[key] = row
        }
        return winner.values.filter { $0.kind == .report && $0.createdAt >= cutoff }
    }

    /// Distinct verified reporters of one artwork (by content hash) among live rows.
    public static func distinctReporters(ofContentHash contentHash: Data, in rows: [ModerationLedgerEntry], now: Date) -> Int {
        let live = liveReports(rows, now: now).filter { $0.contentHash == contentHash }
        return Set(live.map { hex($0.reporterSigningPublicKey) }).count
    }

    /// Content hashes of a designer's artworks that have crossed the unlistable threshold.
    public static func unlistableContentHashes(ofDesigner subjectKey: Data, in rows: [ModerationLedgerEntry], now: Date) -> Set<Data> {
        let live = liveReports(rows, now: now).filter { $0.subjectSigningPublicKey == subjectKey }
        let byHash = Dictionary(grouping: live, by: { $0.contentHash })
        return Set(byHash.compactMap { hash, reports in
            Set(reports.map { hex($0.reporterSigningPublicKey) }).count >= ClothingModerationLimits.itemUnlistableReporters ? hash : nil
        })
    }

    /// True when a designer should be store-banned: enough distinct artworks over the unlistable
    /// threshold, honoring the per-reporter item cap so a lone griefer can't ban a whole shop.
    public static func shouldBanDesigner(subjectKey: Data, in rows: [ModerationLedgerEntry], now: Date) -> Bool {
        let live = liveReports(rows, now: now).filter { $0.subjectSigningPublicKey == subjectKey }
        let byHash = Dictionary(grouping: live, by: { $0.contentHash })

        // Per-reporter cap: count each reporter toward at most `perReporterItemCap` of this designer's
        // items. Iterate in a DETERMINISTIC order (sorted by content hash) — the greedy cap assignment
        // mutates as it goes, so unsorted `Dictionary` order would let the same evidence ban on one
        // device and spare on another (a Phase-3b convergence + fairness bug).
        var reporterItemCount: [String: Int] = [:]
        var qualifyingHashes = 0
        for (_, reports) in byHash.sorted(by: { hex($0.key) < hex($1.key) }) {
            let reporters = Set(reports.map { hex($0.reporterSigningPublicKey) })
            guard reporters.count >= ClothingModerationLimits.itemUnlistableReporters else { continue }
            // A qualifying item only counts reporters who haven't already hit their per-designer cap.
            var effective = 0
            for reporter in reporters where reporterItemCount[reporter, default: 0] < ClothingModerationLimits.perReporterItemCap {
                reporterItemCount[reporter, default: 0] += 1
                effective += 1
            }
            if effective >= ClothingModerationLimits.itemUnlistableReporters { qualifyingHashes += 1 }
        }
        return qualifyingHashes >= ClothingModerationLimits.designerBanItems
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

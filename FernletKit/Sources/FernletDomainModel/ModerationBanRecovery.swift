// ModerationBanRecovery.swift
// FernletDomainModel
//
// The pure half of lifting a store ban when the people who reported a designer take their reports
// back (tracker §3.5, 2026-09-24; policy note: Docs/Moderation-SelfBan-Recovery-2026-09-23.md).
//
// A ban answers to EVIDENCE — the live reports that stood behind it — and this file decides when
// that evidence has shrunk below the threshold. The one rule everything else hangs off: **only a
// positive withdrawal removes evidence.** A `retract` row from the same reporter for the same artwork,
// with a higher `reporterSeq`, is a withdrawal. An ABSENT row is never one: the moderation ledger is
// exactly what "Delete everything", a reinstall, or a flood-eviction empties, and a banned person
// controls all three. Decay is not one either — it runs off the wall clock, which the banned person
// also controls. So a ban only ever lifts because a reporter said so.
//
// Wall-safe (no crypto, no sealed types): reporter identities arrive as opaque TAGS through a closure,
// derived in ProximityKit (`ModerationBanStore`) from a per-ban salt, so the ban record that outlives
// a wipe never holds another person's signing key.

import Foundation

/// One report that stands behind a store ban: which reporter (as an opaque per-ban tag, never their
/// key), which artwork, and the `reporterSeq` a withdrawal has to beat.
///
/// Persisted inside the ban's keychain record (``ModerationBanRecovery`` decides what it means), so
/// it is deliberately tiny and carries nothing that names a person: the tag is a salted digest of the
/// reporter's key that only lets THIS record recognize the same reporter again.
public nonisolated struct BanEvidence: Codable, Hashable, Sendable {
    /// The reporter, as a salted digest of their signing key (see `ModerationBanStore`).
    public var reporterTag: Data
    /// The reported artwork's content hash (`ModerationContentHash`).
    public var contentHash: Data
    /// The report's `reporterSeq` when it was recorded — a withdrawal must be strictly higher.
    public var reporterSeq: UInt64

    public init(reporterTag: Data, contentHash: Data, reporterSeq: UInt64) {
        self.reporterTag = reporterTag
        self.contentHash = contentHash
        self.reporterSeq = reporterSeq
    }
}

/// Pure decisions for lifting a store ban whose reporters withdrew: which recorded evidence has been
/// positively withdrawn, how evidence merges and stays bounded, and whether what is left still
/// reaches the ban threshold. No I/O, no clock, no crypto.
///
/// The threshold test (``reachesBanThreshold(_:)``) deliberately counts WITHOUT
/// `ClothingModerationLimits.perReporterItemCap`. The capped count
/// (`ModerationEconomy.shouldBanDesigner`) is not monotone — adding reports can LOWER it, because the
/// greedy cap assignment shifts — so "the capped count says no ban" cannot be trusted to mean "less
/// evidence than before". The uncapped count is monotone and never smaller than the capped one, so
/// when it says the threshold is not met, no subset of the evidence meets the capped threshold
/// either. It can only err towards KEEPING a ban, never towards lifting one early.
public nonisolated enum ModerationBanRecovery {
    /// Most evidence rows one ban record keeps (R3). The threshold needs
    /// `designerBanItems × itemUnlistableReporters` (6) of them; the rest is margin so one
    /// withdrawal cannot lift a ban that other reports still carry.
    public static let maxEvidence = 64

    /// The LIVE reports naming `subjectKey` (non-retracted, inside the decay window), as evidence
    /// under `tag`. `excludingReporter`'s own reports are left out — for a self-ban that is the
    /// banned device itself, whose own rows must never count for or against its own ban.
    public static func liveEvidence(
        against subjectKey: Data,
        in rows: [ModerationLedgerEntry],
        excludingReporter excluded: Data?,
        now: Date,
        tag: (Data) -> Data
    ) -> [BanEvidence] {
        ModerationEconomy.liveReports(rows, now: now)
            .filter { $0.subjectSigningPublicKey == subjectKey && $0.reporterSigningPublicKey != excluded }
            .map { BanEvidence(reporterTag: tag($0.reporterSigningPublicKey), contentHash: $0.contentHash,
                               reporterSeq: $0.reporterSeq) }
    }

    /// The recorded evidence a reporter has since POSITIVELY withdrawn: the ledger's winning row for
    /// that reporter and artwork (highest `reporterSeq`) is a `retract`, strictly newer than the seq
    /// the evidence was recorded at. A row that is simply missing is never a withdrawal, and
    /// `excludingReporter`'s rows are ignored entirely (a banned device cannot withdraw on anyone's
    /// behalf, including its own).
    public static func withdrawn(
        _ recorded: [BanEvidence],
        in rows: [ModerationLedgerEntry],
        excludingReporter excluded: Data?,
        tag: (Data) -> Data
    ) -> Set<BanEvidence> {
        guard !recorded.isEmpty else { return [] }
        let recordedKeys = Set(recorded.map(EvidenceKey.init))
        var latest: [EvidenceKey: ModerationLedgerEntry] = [:]
        // Bounded: one pass over the ledger's finite rows.
        for row in rows where row.reporterSigningPublicKey != excluded {
            let key = EvidenceKey(reporterTag: tag(row.reporterSigningPublicKey), contentHash: row.contentHash)
            guard recordedKeys.contains(key) else { continue }
            if let existing = latest[key], existing.reporterSeq >= row.reporterSeq { continue }
            latest[key] = row
        }
        return Set(recorded.filter { evidence in
            guard let winner = latest[EvidenceKey(evidence)] else { return false }   // absence ≠ withdrawal
            return winner.kind == .retract && winner.reporterSeq > evidence.reporterSeq
        })
    }

    /// `base` and `additions` as one evidence set: one entry per (reporter, artwork) at its highest
    /// `reporterSeq`, bounded to ``maxEvidence`` and returned in a canonical order so an unchanged
    /// set compares equal and is never rewritten.
    public static func merged(_ base: [BanEvidence], with additions: [BanEvidence]) -> [BanEvidence] {
        var best: [EvidenceKey: BanEvidence] = [:]
        for evidence in base + additions {
            let key = EvidenceKey(evidence)
            if let existing = best[key], existing.reporterSeq >= evidence.reporterSeq { continue }
            best[key] = evidence
        }
        return canonical(bounded(Array(best.values)))
    }

    /// Whether the evidence still reaches the store-ban threshold: at least
    /// `designerBanItems` artworks each reported by at least `itemUnlistableReporters` distinct
    /// reporters — counted without the per-reporter cap, on purpose (see the type's documentation).
    public static func reachesBanThreshold(_ evidence: [BanEvidence]) -> Bool {
        let reportersPerArtwork = Dictionary(grouping: evidence, by: \.contentHash)
            .mapValues { Set($0.map(\.reporterTag)).count }
        let qualifying = reportersPerArtwork.values.filter {
            $0 >= ClothingModerationLimits.itemUnlistableReporters
        }.count
        return qualifying >= ClothingModerationLimits.designerBanItems
    }

    // MARK: - Internals

    /// The identity of one piece of evidence — the same (reporter, artwork) pair the ledger's own
    /// deterministic row id keys on.
    private struct EvidenceKey: Hashable {
        let reporterTag: Data
        let contentHash: Data

        init(reporterTag: Data, contentHash: Data) {
            self.reporterTag = reporterTag
            self.contentHash = contentHash
        }

        init(_ evidence: BanEvidence) {
            self.init(reporterTag: evidence.reporterTag, contentHash: evidence.contentHash)
        }
    }

    /// Most entries one ARTWORK may hold in a ban record — four times what an artwork needs to
    /// qualify, so a withdrawal or two on one artwork is measured against the reporters who remain.
    public static let maxEvidencePerArtwork = 8

    /// Keeps the evidence a ban actually rests on: artworks ranked by how many reporters they carry
    /// (ties by hash, for determinism), each capped at ``maxEvidencePerArtwork``, taken in rank order
    /// until ``maxEvidence`` is full. A flood of one-reporter artworks — which qualify for nothing —
    /// therefore always yields to the qualifying ones instead of diluting every artwork down to a
    /// single reporter (which is what a per-artwork water-filling does once artworks outnumber slots).
    private static func bounded(_ evidence: [BanEvidence]) -> [BanEvidence] {
        guard evidence.count > maxEvidence else { return evidence }
        // Sort: more reporters first; among equals, the lower hash first.
        let ranked = Dictionary(grouping: evidence, by: \.contentHash)
            .map { (hash: $0.key, entries: canonical($0.value)) }
            .sorted { ($0.entries.count, hexKey($1.hash)) > ($1.entries.count, hexKey($0.hash)) }
        var kept: [BanEvidence] = []
        // R2: bounded by the finite artwork list; R3: `kept` never passes maxEvidence.
        for artwork in ranked where kept.count < maxEvidence {
            kept += artwork.entries.prefix(min(maxEvidencePerArtwork, maxEvidence - kept.count))
        }
        return kept
    }

    /// Artwork, then reporter, then seq — so equal sets are equal arrays.
    private static func canonical(_ evidence: [BanEvidence]) -> [BanEvidence] {
        evidence.sorted {
            (hexKey($0.contentHash), hexKey($0.reporterTag), $0.reporterSeq)
                < (hexKey($1.contentHash), hexKey($1.reporterTag), $1.reporterSeq)
        }
    }

    private static func hexKey(_ data: Data) -> String { ModerationLedgerEntry.hex(data) }
}

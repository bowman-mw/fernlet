// ModerationLedger.swift
// FernletSocial/Moderation
//
// Device-local, append-only store of moderation reports (this device's own reports in Phase 2; peers'
// verified reports arrive in Phase 3). A small JSON sidecar in Application Support, the same home and
// stance as HeartLedger.json — deliberately NEVER in the snapshot: who reported whom is sensitive
// social data and must not follow the user into iCloud. Rows are keyed by a deterministic id so a
// repeat report de-dupes and a retract supersedes its report by a higher `reporterSeq`.

import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import ProximityKit

/// Device-local, append-only store of moderation report rows: this device's own reports and
/// retracts plus peers' one-hop-verified rows.
///
/// The evidence base ``ModerationBanStore/reconcile(rows:localSigningKey:)`` and the shop's
/// hide-reported-items checks read from. Rows carry a deterministic id
/// (`ModerationLedgerEntry.rowID`) so a repeat report de-dupes and a retract supersedes its
/// report via a higher `reporterSeq`; upsert keeps the higher-seq row, making re-delivery
/// idempotent. Persistence is a JSON sidecar in Application Support
/// (`.completeFileProtection`, excluded from iCloud device backups), deliberately NEVER in the synced
/// snapshot or a backup — who reported whom is sensitive social data.
///
/// The file is data of record (the evidence ban reconciliation reads, and what keeps a reported item
/// hidden), so it never fails open to an empty ledger that the next report would write over (bug
/// confirmation 2026-10-15 §4): an undecodable file is moved aside to `ModerationLedger.json.corrupt`
/// before anything is written, rows decode one by one so a single unreadable row costs only itself, and
/// while the file exists but cannot be READ (a locked-device read of the protected file) every save
/// first retries the read — merging the rows recorded since into the file's — and is refused while
/// the read still fails.
///
/// Bounded MAX-MIN FAIRLY, not by age alone (R3): at most `maxRowsPerReporter` rows per reporter
/// fingerprint and `maxRows` overall, and when the total would overflow the per-reporter allowance is
/// lowered uniformly until it fits — so a flooding reporter is drained down to everyone else's level
/// before a quiet reporter loses a single row. That is what keeps a hostile peer from evicting THIS
/// device's own reports, without the ledger ever needing to know its own signing key. The same rule is
/// applied on the way in from disk. `clearAll` is wired from reset-everything.
/// `@MainActor @Observable`: rows drive moderation UI.
@MainActor
@Observable
public final class ModerationLedger {
    /// All stored rows (reports + retracts), oldest first. Bounded by `maxRows` overall and
    /// `maxRowsPerReporter` per reporter — see `bounded` for the fair-eviction rule.
    public private(set) var rows: [ModerationLedgerEntry] = []

    @ObservationIgnored private let file: JSONSidecarFile<PersistedState>
    @ObservationIgnored private let now: () -> Date
    /// True while the sidecar exists but its last read failed: the rows in memory are not the file's,
    /// so writing them would overwrite the real ledger. Cleared by the first read that succeeds.
    @ObservationIgnored private var fileUnread = false

    /// Hard ceiling on the whole ledger.
    static let maxRows = 512

    /// A single reporter fingerprint may hold at most this many rows. Generous for a real user — each
    /// reported artwork costs at most two rows, a report and its retract — and it is `bounded`'s fair
    /// allocation, not this cap, that is load-bearing against a flood. Deliberately not lower: this
    /// cap also applies to the LOCAL user's own rows, and past it their oldest own reports are evicted
    /// (a previously hidden item would reappear in the shop grid), so it must sit well above plausible
    /// real use.
    static let maxRowsPerReporter = 128

    /// A ledger over the rows persisted at `fileURL`, loaded and bounded.
    ///
    /// - Parameters:
    ///   - fileURL: The sidecar file, which the caller always states: there is no default, so no
    ///     ledger silently lands on a process-wide path. Fernlet's store passes ``fileURL(in:)`` of its
    ///     proximity sidecar root; a test passes a file of its own.
    ///   - now: The clock its rows are stamped with.
    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        // Out of iCloud device backups: who reported whom (bug confirmation 2026-10-15 §5).
        self.file = JSONSidecarFile(fileURL: fileURL, excludedFromBackup: true)
        self.now = now
        rows = Self.bounded(readFile() ?? [])
    }

    // MARK: - Local report / retract

    /// Records a LOCAL report by this device (reporter == own key). Idempotent by artwork.
    @discardableResult
    public func recordLocalReport(
        reporterSigningPublicKey: Data, reporterFingerprint: String,
        subjectSigningPublicKey: Data, itemID: UUID, contentHash: Data, reason: String
    ) -> ModerationLedgerEntry {
        let entry = ModerationLedgerEntry(
            id: ModerationLedgerEntry.rowID(kind: .report, reporterFingerprint: reporterFingerprint, contentHash: contentHash),
            kind: .report,
            reporterSigningPublicKey: reporterSigningPublicKey,
            subjectSigningPublicKey: subjectSigningPublicKey,
            itemID: itemID, contentHash: contentHash, reasonToken: reason,
            reporterSeq: nextSeq(reporterFingerprint: reporterFingerprint, contentHash: contentHash),
            createdAt: now())
        upsert(entry)
        return entry
    }

    /// Records a LOCAL retract (undo) that supersedes the matching report.
    @discardableResult
    public func recordLocalRetract(
        reporterSigningPublicKey: Data, reporterFingerprint: String,
        subjectSigningPublicKey: Data, itemID: UUID, contentHash: Data
    ) -> ModerationLedgerEntry {
        let entry = ModerationLedgerEntry(
            id: ModerationLedgerEntry.rowID(kind: .retract, reporterFingerprint: reporterFingerprint, contentHash: contentHash),
            kind: .retract,
            reporterSigningPublicKey: reporterSigningPublicKey,
            subjectSigningPublicKey: subjectSigningPublicKey,
            itemID: itemID, contentHash: contentHash, reasonToken: ReportReason.other.rawValue,
            reporterSeq: nextSeq(reporterFingerprint: reporterFingerprint, contentHash: contentHash),
            createdAt: now())
        upsert(entry)
        return entry
    }

    /// Stores peers' already-verified report rows (from the one-hop relay). Merge de-dupes by the
    /// deterministic id and keeps the higher `reporterSeq`, so re-delivery is idempotent.
    ///
    /// R3: one peer delivery can never contribute more than one wire payload's worth of rows, and the
    /// batch is bounded ONCE at the end — `maxRowsPerReporter` per reporter, `maxRows` overall, evicted
    /// max-min fairly (see `bounded`), so however long a hostile peer keeps delivering it can only ever
    /// drain its own bucket, never anyone else's. Bounding once per batch also means one file write per
    /// envelope instead of one per row; a crash mid-batch loses the whole batch rather than a prefix,
    /// which is safe because peers re-deliver on the next slot commit and merging is idempotent.
    public func ingestForeign(_ entries: [ModerationLedgerEntry]) {
        for entry in entries.prefix(ModerationReportPayload.maxReports) { merge(entry) }
        rows = Self.bounded(rows)
        save()
    }

    // MARK: - Reads

    /// True when this device holds a live (non-retracted) local report for the artwork — used to hide
    /// a reported item from the shop grid and the buy path.
    public func isLocallyReported(contentHash: Data, reporterFingerprint: String) -> Bool {
        let reportID = ModerationLedgerEntry.rowID(kind: .report, reporterFingerprint: reporterFingerprint, contentHash: contentHash)
        guard let report = rows.first(where: { $0.id == reportID }) else { return false }
        let retractID = ModerationLedgerEntry.rowID(kind: .retract, reporterFingerprint: reporterFingerprint, contentHash: contentHash)
        if let retract = rows.first(where: { $0.id == retractID }), retract.reporterSeq > report.reporterSeq {
            return false
        }
        return true
    }

    /// Wipes every row, the on-disk sidecar and its `.corrupt` quarantine (wired from
    /// `FernletStore.resetAll`).
    public func clearAll() {
        rows = []
        file.removeFile()
        // What a wipe leaves is "no ledger", so the next report writes a fresh file.
        fileUnread = false
    }

    // MARK: - Internals

    private func nextSeq(reporterFingerprint: String, contentHash: Data) -> UInt64 {
        let reportID = ModerationLedgerEntry.rowID(kind: .report, reporterFingerprint: reporterFingerprint, contentHash: contentHash)
        let retractID = ModerationLedgerEntry.rowID(kind: .retract, reporterFingerprint: reporterFingerprint, contentHash: contentHash)
        let existing = rows.filter { $0.id == reportID || $0.id == retractID }.map(\.reporterSeq).max()
        return (existing ?? 0) + 1
    }

    private func upsert(_ entry: ModerationLedgerEntry) {
        merge(entry)
        rows = Self.bounded(rows)
        save()
    }

    /// Inserts or supersedes ONE row without bounding or saving, so a batch pays for one bound and one
    /// file write rather than one of each per row. Every caller must bound + save afterwards.
    private func merge(_ entry: ModerationLedgerEntry) {
        if let index = rows.firstIndex(where: { $0.id == entry.id }) {
            // Same deterministic id: keep the higher-seq row (idempotent re-record).
            if entry.reporterSeq >= rows[index].reporterSeq { rows[index] = entry }
        } else {
            rows.append(entry)
        }
    }

    /// Max-min-fair ("water-filling") bound over the whole row set: no reporter keeps more than
    /// ``maxRowsPerReporter``, the total never exceeds ``maxRows``, and when the total would overflow
    /// the per-reporter allowance is lowered UNIFORMLY until it fits. A reporter that floods therefore
    /// gets drained down to everyone else's level before any quieter reporter loses a row — which is
    /// what protects this device's own reports without the ledger knowing its own signing key.
    private static func bounded(_ rows: [ModerationLedgerEntry]) -> [ModerationLedgerEntry] {
        var buckets: [String: [ModerationLedgerEntry]] = [:]
        for row in rows {
            buckets[IdentityService.fingerprint(of: row.reporterSigningPublicKey), default: []].append(row)
        }
        var capped: [String: [ModerationLedgerEntry]] = [:]
        for (key, bucket) in buckets { capped[key] = Array(sortedByAge(bucket).suffix(maxRowsPerReporter)) }
        // R2: bounded by maxRowsPerReporter — `allowance` starts there, strictly decreases, stops at 1.
        var allowance = maxRowsPerReporter
        while allowance > 1, total(of: capped, under: allowance) > maxRows { allowance -= 1 }
        let trimmed = capped.keys.sorted().flatMap { Array((capped[$0] ?? []).suffix(allowance)) }
        return Array(sortedByAge(trimmed).suffix(maxRows))
    }

    /// How many rows survive if every reporter is capped at `allowance` — the water-filling probe.
    private static func total(of buckets: [String: [ModerationLedgerEntry]], under allowance: Int) -> Int {
        buckets.values.reduce(0) { $0 + min($1.count, allowance) }
    }

    /// Oldest-first with the row id as tie-break. Swift's sort is NOT stable, so without the tie-break
    /// two calls over the same set could return different orders and churn every `@Observable` reader.
    private static func sortedByAge(_ rows: [ModerationLedgerEntry]) -> [ModerationLedgerEntry] {
        rows.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Versioned on-disk shape; tolerant of missing keys so older files keep decoding, and of a row
    /// that will not decode, which is dropped alone (`droppedRows` counts it) rather than taking every
    /// report in the file with it (bug confirmation 2026-10-15 §4).
    ///
    /// `nonisolated` so its hand-written `Decodable` conformance stays usable from the
    /// nonisolated ``JSONSidecarFile`` generic (pure data: an `Int` plus nonisolated entries).
    private nonisolated struct PersistedState: Codable {
        var version = 1
        var rows: [ModerationLedgerEntry] = []
        /// Rows the last decode dropped. Never encoded.
        var droppedRows = 0
        /// The persisted keys — `droppedRows` is a decode fact, not part of the file.
        enum CodingKeys: String, CodingKey {
            case version, rows
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            let decoded = try c.decodeIfPresent([LenientSidecarRow<ModerationLedgerEntry>].self, forKey: .rows) ?? []
            rows = decoded.compactMap(\.value)
            droppedRows = decoded.count - rows.count
        }
    }

    /// Reads the sidecar's rows, or nil while the file exists but cannot be read (`fileUnread` then
    /// stays set and every save is refused until a read succeeds). Absent reads as no rows; an
    /// undecodable file is quarantined first and then reads as no rows — or, if the move failed and
    /// the file is still in the way, as unread. Callers bound what it returns.
    ///
    /// R3: the file is external input to this process — it can be larger than ``maxRows`` because a
    /// build with a higher cap wrote it, or because it was tampered with — so `bounded` is applied on
    /// the way IN as well as in `upsert`, and applied identically: the SAME max-min-fair rule, not a
    /// plain oldest-first trim. A flat trim here was its own bug, because a file stuffed with one
    /// reporter's rows would evict every other reporter (including this device's own) at startup.
    /// Without any bound the ledger would stay permanently over its cap: `upsert` only re-bounds when
    /// it writes, and every read that scans `rows` would work over an unbounded array until then.
    private func readFile() -> [ModerationLedgerEntry]? {
        switch file.read() {
        case .absent:
            fileUnread = false
            return []
        case .loaded(let state):
            fileUnread = false
            if state.droppedRows > 0 {
                FernletAuditLog.log("moderationLedger.rowsDropped", context: ["count": String(state.droppedRows)])
            }
            return state.rows
        case .undecodable:
            fileUnread = !file.quarantine()
            return fileUnread ? nil : []
        case .unreadable:
            fileUnread = true
            return nil
        }
    }

    /// Writes the ledger — unless the file has not been read, when the read is retried first and the
    /// rows recorded since are merged INTO the file's (the same keep-the-higher-seq merge a relay batch
    /// takes), so neither side's reports are lost. While the read still fails nothing is written (a
    /// refused save is audited; the rows stay in memory and the next save retries).
    private func save() {
        if fileUnread {
            guard let onDisk = readFile() else {
                FernletAuditLog.log("moderationLedger.saveRefusedUnread", context: ["rows": String(rows.count)])
                return
            }
            let recordedSince = rows
            rows = Self.bounded(onDisk)
            for entry in recordedSince.prefix(Self.maxRows) { merge(entry) }
            rows = Self.bounded(rows)
        }
        var state = PersistedState()
        state.rows = rows
        file.save(state)
    }

    /// This store's file inside a given proximity-sidecar root — the ONE definition of its name, so
    /// the production root and a scoped (per-store) root can never name different files.
    ///
    /// Given a root rather than fixed because it is shared mutable on-disk state that a wipe reaches:
    /// `clearAll()` removes this file, and `FernletStore.resetAll` calls it (device-local moderation reports (who reported whom, and the reported artwork hashes)
    /// must not outlive "Reset everything"). Under the test runner, where XCTest and Swift Testing
    /// suites run in parallel in ONE process, a constant path means any wiping test deletes this for
    /// every concurrently-live store. Unsealed, so — unlike the heart-drop sidecars — the root is the
    /// whole fix and no keychain scoping is needed. See ``ProximityHost/proximitySupportDirectory``.
    public nonisolated static func fileURL(in directory: URL) -> URL {
        JSONSidecarFile<PersistedState>.fileURL(in: directory, name: "ModerationLedger.json")
    }
}

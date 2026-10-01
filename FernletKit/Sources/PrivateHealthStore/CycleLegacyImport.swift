import CryptoKit
import FernletFoundation
import Foundation
import HealthKit

// CycleLegacyImport.swift — moving the pre-record cycle history into sealed records (period-data
// design 2026-09-30, §8): the sealed `MenstrualNarrative` rows (the narrative half) and Fernlet's own
// unmarked Apple Health samples (the sample half), tracked separately, idempotent, re-runnable until
// done.

/// The two persisted markers of the legacy cycle import (§8.2, §8.3): absent = that half is still
/// pending, ``doneValue`` = finished.
///
/// Standard (device-local, non-synced) defaults; injected so tests get an isolated suite. **Set to
/// done by "Delete everything" and by an app-lock reset** (§8.4): a pending sample half would
/// otherwise re-import, at the next Private open, the Apple Health copies the user chose to keep
/// while deleting their Fernlet data. Cleared only by an uninstall. Two short strings, no content.
/// Their keys and value are FROZEN tokens (`LocalizationBoundaryTests`).
///
/// `nonisolated`: two `UserDefaults` reads and writes, safe from any executor.
public nonisolated struct CycleLegacyImportLedger {
    /// The narrative half's marker.
    public static let narrativesKey = "fernlet.cycleRecord.legacyImport.narratives"
    /// The sample half's marker.
    public static let samplesKey = "fernlet.cycleRecord.legacyImport.samples"
    /// The marker value for a finished half.
    public static let doneValue = "done"

    /// Where the markers live.
    private let defaults: UserDefaults

    /// Creates a ledger over `defaults` (standard defaults by default).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the narrative half finished.
    public var isNarrativeHalfDone: Bool { defaults.string(forKey: Self.narrativesKey) == Self.doneValue }
    /// Whether the sample half finished.
    public var isSampleHalfDone: Bool { defaults.string(forKey: Self.samplesKey) == Self.doneValue }

    /// Marks the narrative half finished.
    public func markNarrativeHalfDone() {
        defaults.set(Self.doneValue, forKey: Self.narrativesKey)
    }

    /// Marks the sample half finished.
    public func markSampleHalfDone() {
        defaults.set(Self.doneValue, forKey: Self.samplesKey)
    }

    /// Marks both halves finished — "Delete everything" and the app-lock reset funnel (§8.4, §9.21).
    public func markBothHalvesDone() {
        markNarrativeHalfDone()
        markSampleHalfDone()
    }
}

/// What one legacy-import pass decided, built synchronously after the pass's last await (§8.4): the
/// records to write in ONE merge save, the narrative rows retired in that same save, and what each
/// half's marker may say afterwards.
struct CycleLegacyImportPlan {
    /// Records to upsert: narrative-only ones from the openable narratives, clinical-only ones from
    /// the legacy samples. Reduced by id inside the write.
    var records: [CycleRecord] = []
    /// The openable narratives' row ids, retired in the same save.
    var retiringNarrativeIDs: [UUID] = []
    /// The narrative rows that can never open here.
    var deadNarrativeIDs: [UUID] = []
    /// Whether the narrative half ran to a decision (every row opened or proved dead).
    var narrativeHalfDecided = false
    /// Whether the sample half read its samples cleanly this pass.
    var sampleHalfRead = false
}

extension PeriodTrackerStore {
    /// The most legacy Apple Health samples one pass reads (§8.3 step 2).
    static let maxLegacySamples = 20_000

    /// Runs the legacy import (§8.1) when a half is pending: awaited by the Cycle page AFTER the
    /// drain and BEFORE the load, with the hub key live. A silent no-op while hidden (G2). Held in
    /// ``legacyImportTask`` so "Delete everything" can cancel it (``cancelBackgroundWriters()``); a
    /// second call while one runs waits for it rather than starting another.
    ///
    /// The import and the Sealed backup restore commute (the restore is an id-keyed merge), so
    /// nothing here waits for a restore.
    public func runLegacyImportIfNeeded(contentKey: SymmetricKey) async {
        guard isVisible() else { return }
        if let running = legacyImportTask {
            await running.value
            return
        }
        let epoch = writerEpoch
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLegacyImport(contentKey: contentKey, epoch: epoch)
        }
        legacyImportTask = task
        await task.value
        if writerEpoch == epoch { legacyImportTask = nil }
    }

    /// One pass, in the fixed order of §8.4: (1) the Apple Health reads — the only awaits; (2) the
    /// recheck of visibility, the live key, the writer epoch and cancellation; (3) the narrative
    /// decrypt and (4) the build, synchronously; (5) the same checks again, then ONE merge write
    /// that retires the converted narratives atomically; then the markers.
    func performLegacyImport(contentKey: SymmetricKey, epoch: Int) async {
        let narrativesPending = legacyNarrativesNeedImport()
        let legacySamples = await legacySamplesIfPending()
        guard narrativesPending || legacySamples != nil else { return }
        guard mayWriteAfterAwait(contentKey: contentKey, epoch: epoch) else { return }
        let plan = buildLegacyImportPlan(
            narratives: narrativesPending ? classifyLegacyNarratives(contentKey: contentKey) : nil,
            samples: legacySamples
        )
        guard mayWriteAfterAwait(contentKey: contentKey, epoch: epoch) else { return }
        do {
            _ = try recordStore.upsertMerged(plan.records, retiringNarrativeIDs: plan.retiringNarrativeIDs, contentKey: contentKey)
        } catch {
            FernletAuditLog.log("period.legacyImport.writeFailed", context: ["error": "\(type(of: error))"])
            return
        }
        settleLegacyMarkers(after: plan)
    }

    /// Whether the narrative half has work: its marker is not done, or legacy rows remain (only dead
    /// ones can remain after it is done; re-running re-names them for the card). A count that fails
    /// answers "yes" so the classification can decide.
    private func legacyNarrativesNeedImport() -> Bool {
        guard importLedger.isNarrativeHalfDone else { return true }
        do {
            return try narrativeRepository.narrativeCount() > 0
        } catch {
            FernletAuditLog.log("period.legacyImport.countFailed", context: ["error": "\(type(of: error))"])
            return true
        }
    }

    /// The sample half's read (§8.3 steps 1–2): `nil` — and NO Health call — until every cycle type
    /// has been asked about; `nil` on any read error (the half stays pending). Only unmarked,
    /// Fernlet-authored samples come back.
    private func legacySamplesIfPending() async -> [HKSample]? {
        guard !importLedger.isSampleHalfDone else { return nil }
        guard await healthService.cycleReadAuthorizationDetermined() else { return nil }
        do {
            let samples = try await healthService.loadLegacyFernletCycleSamples(limit: Self.maxLegacySamples)
            return samples.filter { isOwnSample($0) && !CycleHealthSamples.isMarkedMirror($0) }
        } catch {
            FernletAuditLog.log("period.legacyImport.samplesDeferred", context: ["error": "\(type(of: error))"])
            return nil
        }
    }

    /// Every legacy narrative row classified under the key, or `nil` when the walk itself failed.
    private func classifyLegacyNarratives(contentKey: SymmetricKey) -> MenstrualNarrativeClassification? {
        do {
            return try narrativeRepository.classifiedNarratives(contentKey: contentKey)
        } catch {
            FernletAuditLog.log("period.legacyImport.narrativesDeferred", context: ["error": "\(type(of: error))"])
            return nil
        }
    }

    /// Builds the pass's plan (§8.2 step 1–2, §8.3 steps 3–4). A narrative walk with ANY undecided
    /// row converts nothing: the half stops and stays pending.
    private func buildLegacyImportPlan(narratives: MenstrualNarrativeClassification?, samples: [HKSample]?) -> CycleLegacyImportPlan {
        var plan = CycleLegacyImportPlan()
        if let narratives, narratives.transientCount == 0 {
            plan.narrativeHalfDecided = true
            plan.deadNarrativeIDs = narratives.deadIDs
            plan.records += narratives.opened.map(Self.legacyRecord(from:))
            plan.retiringNarrativeIDs = narratives.opened.map(\.id)
        }
        if let samples {
            plan.sampleHalfRead = true
            plan.records += CycleHealthSamples.groupedByRecordID(samples).compactMap { group in
                CycleHealthSamples.clinicalRecord(id: group.id, samples: group.samples, origin: .importedLegacy)
            }
        }
        return plan
    }

    /// The narrative-only record one legacy narrative becomes (§8.2 step 1): its legacy external id
    /// as the record id, the clinical block UNKNOWN, the day's midnight as the time until a clinical
    /// block supplies an exact one. Every clock is the narrative's own, so re-running changes nothing.
    static func legacyRecord(from narrative: MenstrualNarrative) -> CycleRecord {
        CycleRecord(
            id: CycleLegacyIdentity.recordID(forLegacyExternalID: narrative.hkExternalUUID),
            dayKey: narrative.dateKey,
            loggedAt: FernletDate.date(fromDayKey: narrative.dateKey) ?? narrative.createdAt,
            clinical: nil,
            narrative: CycleNarrativeFields(
                note: narrative.note,
                symptomFlags: narrative.symptomFlags,
                customSymptomScales: narrative.customSymptomScales,
                updatedAt: narrative.updatedAt
            ),
            origin: .importedLegacy,
            createdAt: narrative.createdAt,
            updatedAt: narrative.updatedAt
        )
    }

    /// After a clean write: the narrative half is done when every row left is a dead one (§8.2 step
    /// 3 — `narrativeCount() == deadCount`), and those are named for the card; the sample half is
    /// done after a clean read.
    private func settleLegacyMarkers(after plan: CycleLegacyImportPlan) {
        if plan.narrativeHalfDecided {
            unopenableLegacyNarrativeIDs = plan.deadNarrativeIDs
            do {
                if try narrativeRepository.narrativeCount() == plan.deadNarrativeIDs.count {
                    importLedger.markNarrativeHalfDone()
                }
            } catch {
                FernletAuditLog.log("period.legacyImport.countFailed", context: ["error": "\(type(of: error))"])
            }
        }
        if plan.sampleHalfRead { importLedger.markSampleHalfDone() }
    }

    /// "Remove them" on the Cycle page's card (§8.2 step 3): deletes exactly the legacy notes the
    /// last import pass named as unopenable — keyless, ungated, and only on the user's tap.
    ///
    /// - Returns: How many rows were removed.
    public func removeUnopenableLegacyNarratives() throws -> Int {
        let ids = unopenableLegacyNarrativeIDs
        guard !ids.isEmpty else { return 0 }
        let removed = try narrativeRepository.delete(ids: ids)
        unopenableLegacyNarrativeIDs = []
        return removed
    }
}

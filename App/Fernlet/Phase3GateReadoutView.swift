// Phase3GateReadoutView.swift
// Fernlet
//
// The pushed DEBUG screen for the Phase 3 gate readout: the sitting checklist, the six gate rows,
// four explicit controls, and two independent export routes.
//
// SIBLING to the marker-bytes census, never folded into it. The census counts marker bytes and
// writes nothing; this page also reads completion latches, can FETCH from iCloud and DECRYPT three
// sealed manifests on request, can run a media conversion pass, and can clear one latch. Two
// promises, two surfaces, both stated in copy — folding them would put one promise over both, and
// the census's is the stricter.
//
// Not localized, following the census's precedent (CryptoFormatCensus.swift:64-65). Every
// runtime-composed string goes through `Text(verbatim:)` / `SectionLabel(verbatim:)`, never an
// interpolated `LocalizedStringKey`.
//
// DEBUG-ONLY for the reason stated at CryptoFormatCensus.swift:15-21.

#if DEBUG

import CloudKitSync
import FernletFoundation
import FernletLock
import FernletUI
import Foundation
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Phase 3 gate readout — all six gates, readable and exportable from the phone in one sitting.
///
/// It holds NO purchased state: every reading lives on `store.phase3ReadoutSession`, which outlives
/// both this destination push and the Settings sheet's dismissal. That is not tidiness — the
/// sealed-column keyed pass can only be funded by a hub unlock, which means leaving Settings
/// entirely and coming back.
struct Phase3GateReadoutView: View {
    @Environment(FernletStore.self) private var store
    @Environment(FernletLockService.self) private var lockService
    /// The in-flight local scan, held on the SHEET (which outlives each destination push) exactly as
    /// the census's is — a push → pop → push before it returns must re-await the running scan rather
    /// than stacking a second full sweep.
    @Binding var scanTask: Task<Void, Never>?
    /// The shared confirmation glue for the two controls that write.
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    var body: some View {
        List {
            duressRefusalOrContent
        }
        .navigationTitle("Phase 3 gate readout")
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmation($pendingDestructiveAction)
        .task { await runScanIfNeeded() }
    }

    // MARK: - Duress

    /// Under a duress session the WHOLE page renders one refusal and nothing else: no numbers, no
    /// probes, no controls.
    ///
    /// Deliberately blunter than `sealedColumnMigrationCapsuleStatus`'s narrow guard. That guard's
    /// reason is specific to a status line implying hidden sealed entries; this page fetches and
    /// decrypts the real owner's iCloud manifests and prints real per-corpus photo counts — numbers
    /// that contradict an apparently empty decoy are exactly the disclosure duress mode exists to
    /// prevent, and nothing in `CloudKitDataService`, `SealedPhotoCrypto` or `MediaAtRestFormatCensus`
    /// consults duress state on its own.
    @ViewBuilder
    private var duressRefusalOrContent: some View {
        if store.duressSessionActive {
            Section {
                Text(verbatim: "This page is unavailable in this session. It reads and decrypts real"
                    + " backup manifests and prints per-corpus counts, which is exactly what this"
                    + " session must not disclose.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            } header: {
                SectionLabel(verbatim: "Unavailable")
            }
        } else {
            riskSection
            checklistSection
            environmentSection
            gatesSection
            controlsSection
            exportSection
        }
    }

    // MARK: - Sections

    /// What THIS page does that the census next door refuses to do — in words, on screen.
    private var riskSection: some View {
        Section {
            Text(verbatim: "This page reads completion LATCHES, can FETCH from iCloud and DECRYPT"
                + " three sealed manifests on request, can run a media at-rest conversion pass, and"
                + " can clear one latch. The marker-bytes census next door does none of that.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
            Text(verbatim: "It still reads no photo body, opens no photo key, mints nothing, and"
                + " persists nothing of its own — no UserDefaults key, no cache, no stored verdict.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        } header: {
            SectionLabel(verbatim: "What this costs")
        }
    }

    /// The sitting checklist, with every done-state derived from an observation actually taken.
    private var checklistSection: some View {
        Section {
            // R2: bounded by the seven steps.
            ForEach(checklist) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(step.isDone ? "✓" : "○")  \(step.title)")
                        .font(.fernlet(.label))
                        .foregroundStyle(step.isDone ? Color.bark : Color.terracotta)
                        .fernletWrappingText()
                    Text(verbatim: step.detail)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
        } header: {
            SectionLabel(verbatim: "Sitting checklist")
        }
    }

    private var environmentSection: some View {
        Section {
            environmentRow("sealedBackupOwnPhotosEnabled", "\(environment.sealedBackupOwnPhotosEnabled)")
            environmentRow("escrowRouteCommitted (the COMMIT proof)", "\(environment.escrowRouteCommitted)")
            environmentRow("FERNLET_SKIP_SEALED_RESTORE", environment.skipSealedRestoreEnvSet ? "SET — this sitting is invalid" : "not set")
            environmentRow("isLockConfigured", "\(environment.lockConfigured)")
            environmentRow("private hub unlocked", "\(environment.privateHubUnlocked)")
            environmentRow("own-photo pass in flight", "\(environment.ownPhotoBackupPassInFlight)")
            environmentRow("last full-verification pass", environment.lastFullPassCompletedAt.map { $0.ISO8601Format() } ?? "none this process")
            environmentRow("embedded profile (WEAK signal)", "\(environment.hasEmbeddedProvisioningProfile)")
            environmentRow("device", environment.deviceModel)
            environmentRow("system", environment.systemVersion)
            // R2: bounded by the stamp array the fold assembled.
            ForEach(Array(readout.stamps.enumerated()), id: \.offset) { stamp in
                environmentRow("stamp", stamp.element.printed)
            }
            Text(verbatim: Phase3GateEnvironment.cloudKitDatabaseCaveat)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        } header: {
            SectionLabel(verbatim: "Environment")
        }
    }

    private func environmentRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
    }

    private var gatesSection: some View {
        Section {
            // R2: bounded by `Phase3Gate.allCases` (six).
            ForEach(readout.rows) { row in
                gateRowView(row)
            }
        } header: {
            SectionLabel(verbatim: "Gates")
        }
    }

    private func gateRowView(_ row: Phase3GateRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.gate.displayName)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Spacer(minLength: 8)
                Text(verbatim: row.verdict.displayName)
                    .font(.fernlet(.label))
                    .foregroundStyle(row.isDischarged ? Color.bark : Color.terracotta)
            }
            if let reason = row.verdict.reason {
                Text(verbatim: reason)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }
            Text(verbatim: "witnesses: " + row.witnesses.map(\.displayName).joined(separator: ", "))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            evidenceLines(row)
            caveatLines(row)
        }
        .padding(.vertical, 4)
    }

    private func evidenceLines(_ row: Phase3GateRow) -> some View {
        // R2: bounded by the evidence array the fold assembled.
        ForEach(Array(row.evidence.enumerated()), id: \.offset) { line in
            Text(verbatim: line.element)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
    }

    private func caveatLines(_ row: Phase3GateRow) -> some View {
        // R2: bounded by the caveat array the fold assembled.
        ForEach(Array(row.caveats.enumerated()), id: \.offset) { line in
            Text(verbatim: line.element)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section {
            fetchManifestsControl
            bodyProbeControl
            mediaWitnessControl
            sealedColumnResetControl
        } header: {
            SectionLabel(verbatim: "Controls")
        }
    }

    /// Network plus three AES-GCM opens; no writes. Disabled WITH A PRINTED REASON while an
    /// own-photo pass is in flight: a mid-pass fetch returns a torn reading in which a corpus about
    /// to heal reads `minimum == 1` and renders as "not proven" — a false gate failure.
    ///
    /// Deliberately NOT disabled when backup is off: a device that turned it off may still hold
    /// committed manifests, and the preference and the commit ledger print beside the result.
    private var fetchManifestsControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await probeManifests() }
            } label: {
                Text(verbatim: session.manifestProbeInFlight ? "Fetching manifests…" : "Fetch manifests")
                    .font(.fernlet(.label))
            }
            .accessibilityIdentifier("phase3Readout.fetchManifests")
            .disabled(fetchManifestsDisabledReason != nil)
            Text(verbatim: fetchManifestsDisabledReason
                ?? "Three CloudKit fetches and three AES-GCM opens. No writes, no mint, no high-water"
                + " bump. Take one BEFORE Privacy & Data → Retry and one after.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(fetchManifestsDisabledReason == nil ? Color.slate : Color.terracotta)
                .fernletWrappingText()
        }
    }

    private var fetchManifestsDisabledReason: String? {
        if session.manifestProbeInFlight { return "A probe is already running." }
        guard store.ownPhotoBackupPassInFlight else { return nil }
        return "Disabled: an own-photo pass is in flight. A mid-pass fetch returns a torn reading in"
            + " which a corpus about to heal reads minimum 1 and renders as NOT PROVEN — a false gate"
            + " failure. Wait for the pass to finish."
    }

    /// Appears only for a corpus whose manifest did not come back, so the common case pays nothing.
    /// One read-only id enumeration: ids only, no assets, no writes.
    @ViewBuilder
    private var bodyProbeControl: some View {
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        ForEach(corporaNeedingBodyProbe, id: \.rawValue) { corpus in
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { await probeBodies(corpus: corpus) }
                } label: {
                    Text(verbatim: "Probe body records — \(corpus.rawValue)")
                        .font(.fernlet(.label))
                }
                .accessibilityIdentifier("phase3Readout.bodyProbe.\(corpus.rawValue)")
                Text(verbatim: "No manifest came back for this corpus. Zero bodies plus no manifest"
                    + " supports 'never written'; more than zero bodies plus no manifest is blocking"
                    + " — bodies with no commit marker restore nothing.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// A witness, NOT a reset. `performPass()` never touches the latch.
    private var mediaWitnessControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                pendingDestructiveAction = makeMediaWitnessConfirmation()
            } label: {
                Text(verbatim: store.mediaAtRestPassInFlight ? "Media pass running…" : "Fund a media at-rest pass")
                    .font(.fernlet(.label))
            }
            .accessibilityIdentifier("phase3Readout.fundMediaPass")
            .disabled(store.mediaAtRestPassInFlight)
            Text(verbatim: "NO LATCH IS CLEARED. performPass() returns unopenableUnprefixed — the"
                + " plan's own residue evidence — without touching the latch. It WRITES: a pass"
                + " converts anything convertible. On a latched device it should convert nothing;"
                + " if it converts something, that is the finding.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// It ONLY resets. It does not attempt to fund a pass, because it structurally cannot: Settings
    /// is reached from Home, where the hub is always re-locked, so the content-key vend answers nil.
    private var sealedColumnResetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                pendingDestructiveAction = makeReWitnessConfirmation()
            } label: {
                Text(verbatim: "Reset the sealed-column latch (arms the next hub unlock)")
                    .font(.fernlet(.label))
            }
            .accessibilityIdentifier("phase3Readout.resetSealedColumnLatch")
            .disabled(store.sealedColumnMigrationInFlight)
            Text(verbatim: store.sealedColumnMigrationInFlight
                ? "Disabled: a sealed-column run is in flight."
                : "One removeObject. This latch is NOT gate evidence — the gate is census-zero plus a"
                + " clean keyed pass — so clearing it destroys no proof. Then dismiss Settings, open"
                + " the Private tab and unlock: the shipped trigger funds the keyed pass.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(store.sealedColumnMigrationInFlight ? Color.terracotta : Color.slate)
                .fernletWrappingText()
        }
    }

    private func makeMediaWitnessConfirmation() -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Run a media at-rest conversion pass?",
            verbatimMessage: "This WRITES: the pass converts every legacy media blob it can open, in"
                + " place, verify-before-replace. It never clears the completion latch. On a device"
                + " whose latch already stands it should convert nothing — and if it converts"
                + " something, that is the finding, not a failure.",
            confirmLabel: "Run the pass",
            auditEvent: "debug.phase3Readout.mediaWitnessPass"
        ) {
            await store.fundMediaAtRestWitness()
        }
    }

    private func makeReWitnessConfirmation() -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Clear the sealed-column completion latch?",
            verbatimMessage: "This latch MAY NOT COME BACK in this sitting: a device that locks"
                + " mid-pass, or a pass stopped by key revocation, leaves it cleared until a later"
                + " launch runs clean. The pre-reset value of all seven latches is captured into the"
                + " report first. Nothing else is touched, and no data is deleted.",
            confirmLabel: "Clear the latch",
            auditEvent: "debug.phase3Readout.sealedColumnLatchReset"
        ) {
            resetSealedColumnLatch()
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button { copyReport() } label: {
                Label("Copy the report", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("phase3Readout.copyReport")
            Button { emitReportToLog() } label: {
                Label("Emit the report to the audit log", systemImage: "text.append")
            }
            .accessibilityIdentifier("phase3Readout.emitReport")
            Text(verbatim: "Counts and format verdicts only. No file names, no paths, no photo"
                + " identifiers, no captions, nothing decrypted. It DOES say how many photos and"
                + " journal entries this device holds.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text(verbatim: "The pasteboard copy is local-only (it is deliberately not Handoff-synced),"
                + " so the log route is how the report reaches the Mac — the chunks render in full to"
                + " a connected debugger and are selectable from Console.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        } header: {
            SectionLabel(verbatim: "Export")
        }
    }

    // MARK: - Derived

    private var session: Phase3ReadoutSession { store.phase3ReadoutSession }

    private var environment: Phase3GateEnvironment {
        let preferences = StoragePreferencesStore.currentPreferences()
        return Phase3GateEnvironment(
            sealedBackupOwnPhotosEnabled: preferences.sealedBackupOwnPhotosEnabled,
            escrowRouteCommitted: OwnPhotoEscrowCommitLedger().isCommitted,
            skipSealedRestoreEnvSet: ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] == "1",
            lockConfigured: lockService.isLockConfigured,
            privateHubUnlocked: lockService.isUnlocked(for: .privateHub),
            duressSessionActive: store.duressSessionActive,
            ownPhotoBackupPassInFlight: store.ownPhotoBackupPassInFlight,
            lastFullPassCompletedAt: store.ownPhotoBackupLastFullPassCompletedAt,
            hasEmbeddedProvisioningProfile:
                Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? UIDevice.current.model
        )
    }

    private var checklist: [Phase3SittingStep] {
        session.checklist(
            lastFullPassCompletedAt: store.ownPhotoBackupLastFullPassCompletedAt,
            sealedColumnWitness: store.lastSealedColumnPassWitness
        )
    }

    private var readout: Phase3GateReadout {
        Phase3GateReadoutBuilder.readout(from: session.inputs(
            environment: environment,
            ownPhotoDocumentsDirectory: store.photoDocumentsDirectory,
            friendWallSupportDirectory: store.proximitySupportDirectory,
            sealedColumnWitness: store.lastSealedColumnPassWitness,
            sealedColumnPassInFlight: store.sealedColumnMigrationInFlight
        ))
    }

    /// The corpora whose manifest did not come back in the most recent probe — the only ones the
    /// body probe is offered for.
    private var corporaNeedingBodyProbe: [SealedPhotoCorpus] {
        guard let probe = session.manifestProbes.last else { return [] }
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        return SealedPhotoCorpus.allCases.filter { probe.readings[$0] == .noManifestReturned }
    }

    // MARK: - Work

    /// One local scan per sitting, re-awaited rather than restacked.
    ///
    /// The two-part guard is the census's: once readings are in hand the first clause short-circuits;
    /// while a scan is running there are none yet, so the handle stands in for them and a re-push
    /// awaits the scan already underway. The detached scan does not observe cancellation.
    private func runScanIfNeeded() async {
        guard !store.duressSessionActive else { return }
        guard session.censusReadings == nil else { return }
        let scan: Task<Void, Never>
        if let inFlight = scanTask {
            scan = inFlight
        } else {
            let inputs = CryptoFormatCensus.Inputs.production(for: store)
            let started = Task {
                let readings = await CryptoFormatCensus.takeReadings(inputs: inputs)
                let latches = await Task.detached(priority: .utility) {
                    Phase3LatchReadings.take(inputs: inputs)
                }.value
                session.recordScan(census: readings, latches: latches)
            }
            scanTask = started
            scan = started
        }
        await scan.value
        scanTask = nil
    }

    /// Fetches and opens the three corpus manifests.
    ///
    /// It never calls `ensureProvisioned()` — which can mint device keys, promote a legacy key to a
    /// synchronizable escrow row, and migrate key accessibility — and never
    /// `provisionBackupEscrowKeyForSealing()`, which MINTS. A bare `IdentityService()` reaches every
    /// escrow key through pure keychain reads, and an empty candidate set surfaces as a
    /// distinguishable, honest failure rather than a mint.
    private func probeManifests() async {
        guard !session.manifestProbeInFlight else { return }
        guard !store.ownPhotoBackupPassInFlight else {
            session.recordRefusal("Fetch manifests refused: an own-photo pass was in flight.")
            return
        }
        session.setManifestProbeInFlight(true)
        let service = SealedPhotoBackupService(
            cloudDataService: CloudKitDataService(),
            identityService: IdentityService()
        )
        var readings: [SealedPhotoCorpus: SealedPhotoManifestReading] = [:]
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        for corpus in SealedPhotoCorpus.allCases {
            readings[corpus] = await manifestReading(service: service, corpus: corpus)
        }
        session.recordManifests(readings)
        session.setManifestProbeInFlight(false)
        FernletAuditLog.log("debug.phase3Readout.manifestProbe", context: ["corpora": "\(readings.count)"])
    }

    private func manifestReading(
        service: SealedPhotoBackupService,
        corpus: SealedPhotoCorpus
    ) async -> SealedPhotoManifestReading {
        let highWater = SealedBackupGenerationStore().lastSeenPhoto(for: corpus)
        do {
            guard let reading = try await service.manifestFormatReading(corpus: corpus) else {
                return .noManifestReturned
            }
            guard reading.entryCount > 0 else {
                return .vacuousEmptyManifest(generation: reading.generation, deviceHighWater: highWater)
            }
            return .proven(
                minimum: reading.minimumEntryHashVersion,
                entryCount: reading.entryCount,
                unprovenEntries: reading.unprovenEntryCount,
                generation: reading.generation,
                deviceHighWater: highWater
            )
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// One read-only id enumeration for a corpus whose manifest did not come back.
    private func probeBodies(corpus: SealedPhotoCorpus) async {
        do {
            let ids = try await CloudKitDataService().existingSealedPhotoIDs(corpus: corpus)
            session.recordBodyProbe(.counted(ids.count, truncatedAtPageCap: false), for: corpus)
        } catch {
            session.recordBodyProbe(.failed(String(describing: error)), for: corpus)
        }
        FernletAuditLog.log("debug.phase3Readout.bodyProbe", context: ["corpus": corpus.rawValue])
    }

    /// Captures the pre-reset value of ALL SEVEN latches into the readout FIRST, then clears the one.
    private func resetSealedColumnLatch() {
        if let latches = session.latches { session.recordPreResetSnapshot(latches) }
        SealedColumnFormatMigrator.latch().reset()
        session.recordSealedColumnReset()
        session.invalidateCensus()
        scanTask = nil
    }

    /// Logs FIRST, then writes — the probe's nothing-silent ordering.
    ///
    /// `setItems(_:options:)` with `.localOnly: true` is the required spelling: the general
    /// pasteboard is Handoff-synced to every device on the same Apple Account.
    private func copyReport() {
        FernletAuditLog.log("debug.phase3Readout.copied")
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: Phase3GateReportBuilder.text(for: readout)]],
                                      options: [.localOnly: true])
    }

    /// The SECOND egress route, and the reason it exists is a wall: `.localOnly: true` is precisely
    /// what keeps the report off the Mac, and the stated workflow is "paste it into the bug note on
    /// the machine where the Phase 3 decision gets written".
    ///
    /// `FernletAuditLog.log` marks context `.private` — redacted in the wild, rendered in FULL to a
    /// connected debugger, and selectable from Console. Xcode is attached by construction in this
    /// sitting. Each chunk carries its index and total, so a truncated capture is detectable.
    private func emitReportToLog() {
        let chunks = Phase3GateReportBuilder.chunks(for: readout, maxBytes: Self.logChunkByteBudget)
        // R2: bounded by the chunk array, which is bounded by the report's line count.
        for (index, chunk) in chunks.enumerated() {
            FernletAuditLog.log("debug.phase3Readout.reportChunk", context: [
                "i": "\(index + 1)", "n": "\(chunks.count)", "text": chunk
            ])
        }
    }

    /// R2: the per-chunk byte budget for the log egress route. Small enough that the unified log's
    /// own truncation does not eat a chunk, large enough that a report is a handful of lines.
    private static let logChunkByteBudget = 2_048
}

#endif

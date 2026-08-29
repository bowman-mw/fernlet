// Phase3GateReadoutView.swift
// Fernlet
//
// The pushed DEBUG screen for the Phase 3 gate readout: the sitting checklist, the six gate rows,
// four explicit controls, and two independent export routes.
//
// SIBLING to the marker-bytes census, never folded into it. The census counts marker bytes and
// writes nothing; this page also reads completion latches, and can FETCH from iCloud and DECRYPT
// three sealed manifests on request and run a media conversion pass. Two promises, two surfaces,
// both stated in copy — folding them would put one promise over both, and the census's is the
// stricter.
//
// It used to be five controls: a fifth cleared the sealed-column completion latch, to arm the keyed
// migrator pass that was that gate's second witness. The latch, the migrator and its trigger all
// went with `ColumnCrypto`'s legacy read rung, so this page now moves NO latch in either direction
// — nothing here writes a bit a later launch could mistake for one a shipped pass earned.
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
/// readings cost network fetches and a writing pass, and a push → pop → push must not re-buy them.
struct Phase3GateReadoutView: View {
    /// Passed EXPLICITLY, the way every other store-consuming view in the app takes it
    /// (`SettingsSheet`, `PrivacyDataSettingsView`, `HealthAccessSettingsView`, …).
    ///
    /// It used to be `@Environment(FernletStore.self)`, and nothing in the app has ever put a
    /// `FernletStore` in the SwiftUI environment — so the first body pass trapped and the app died
    /// on the push, every time. The app has hit that exact failure once before (`FernletApp`'s note
    /// on pushed destinations evaluating outside the root view's injections). A stored property
    /// converts the whole defect class from a runtime trap into a compile error.
    let store: FernletStore
    @Environment(FernletLockService.self) private var lockService
    /// The in-flight local scan, held on the SHEET (which outlives each destination push) exactly as
    /// the census's is — a push → pop → push before it returns must re-await the running scan rather
    /// than stacking a second full sweep.
    @Binding var scanTask: Task<Void, Never>?
    /// The shared confirmation glue for the one control that writes.
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    var body: some View {
        List {
            duressRefusalOrContent
        }
        .navigationTitle("Phase 3 gate readout")
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmation($pendingDestructiveAction)
        // Keyed on the session's scan fence rather than bare, so an invalidation — a funded media
        // pass, or a scan dropped against a moved fence — re-arms the scan instead of leaving six
        // blank NOT TAKEN rows until the owner happens to navigate away and back.
        .task(id: session.scanGeneration) { await runScanIfNeeded() }
    }

    // MARK: - Duress

    /// Under a duress session the WHOLE page renders one refusal and nothing else: no numbers, no
    /// probes, no controls.
    ///
    /// Deliberately blunt rather than surgical: this page fetches and decrypts the real owner's
    /// iCloud manifests and prints real per-corpus photo counts — numbers that contradict an
    /// apparently empty decoy are exactly the disclosure duress mode exists to prevent, and nothing
    /// in `CloudKitDataService`, `SealedPhotoCrypto` or `MediaAtRestFormatCensus` consults duress
    /// state on its own.
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
                + " three sealed manifests on request, and can run a media at-rest conversion pass."
                + " The marker-bytes census next door does none of that.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
            Text(verbatim: "It still reads no photo body, opens no photo key, mints nothing, moves"
                + " NO completion latch in either direction, and persists nothing of its own — no"
                + " UserDefaults key, no cache, no stored verdict.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text(verbatim: "Three of the six rows below no longer gate anything: the sealed-column,"
                + " app-lock-wrap and heart-drop-sidecar legacy readers are already deleted. Those"
                + " rows are kept because they now count something worse than a backlog — stored"
                + " rows this build can no longer open. Each says so in its own wording.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
            Text(verbatim: "EVERY reading here lives in THIS app launch only. Stopping or re-running"
                + " the app discards the whole sitting, and manifest probe #1 — taken before"
                + " Privacy & Data → Retry — cannot be re-taken afterwards. Do step 1 before you"
                + " buy any reading, and export the report before you stop the app.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
        } header: {
            SectionLabel(verbatim: "What this costs")
        }
    }

    /// The sitting checklist, with every done-state derived from an observation actually taken.
    private var checklistSection: some View {
        Section {
            // R2: bounded by the five steps.
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
            reScanControl
            fetchManifestsControl
            bodyProbeControl
            mediaWitnessControl
        } header: {
            SectionLabel(verbatim: "Controls")
        }
    }

    /// Re-takes the local scan, because a funded media pass invalidates it mid-sitting — that pass
    /// WRITES, and the media row's two halves have to describe one filesystem state.
    private var reScanControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                session.invalidateCensus()
            } label: {
                Text(verbatim: "Re-take the local scan")
                    .font(.fernlet(.label))
            }
            .accessibilityIdentifier("phase3Readout.reScan")
            Text(verbatim: "Free: marker bytes, three latch bits, no writes. The census is dropped"
                + " and re-taken whenever a pass could have changed what it counts, so use this to"
                + " re-pair the two halves of a row rather than reading a stale one.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
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
            Text(verbatim: "NO LATCH IS TOUCHED — not cleared, and not SET. performPass() returns"
                + " unopenableUnprefixed, the plan's own residue evidence, and never reaches"
                + " markComplete(); the run loop that would latch is deliberately not called, so a"
                + " latch this sitting quotes is always one a shipped pass earned. It WRITES: a pass"
                + " converts anything convertible. On a latched device it should convert nothing;"
                + " if it converts something, that is the finding, and the gate refuses.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    private func makeMediaWitnessConfirmation() -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Run a media at-rest conversion pass?",
            verbatimMessage: "This WRITES: the pass converts every legacy media blob it can open, in"
                + " place, verify-before-replace. It never clears the completion latch and never"
                + " sets one — the run loop that would latch is not called, because that latch IS"
                + " the gate. On a device whose latch already stands it should convert nothing — and"
                + " if it converts something, that is the finding, and the gate refuses.",
            confirmLabel: "Run the pass",
            auditEvent: "debug.phase3Readout.mediaWitnessPass"
        ) {
            await store.fundMediaAtRestWitness()
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
        session.checklist(lastFullPassCompletedAt: store.ownPhotoBackupLastFullPassCompletedAt)
    }

    private var readout: Phase3GateReadout {
        Phase3GateReadoutBuilder.readout(from: session.inputs(
            environment: environment,
            ownPhotoDocumentsDirectory: store.photoDocumentsDirectory,
            friendWallSupportDirectory: store.proximitySupportDirectory,
            mediaLaunchPass: mediaLaunchPass,
            sealedPhotoFullPassVerdicts: store.sealedPhotoLastFullPassVerdicts
        ))
    }

    /// The launch media pass's record, so a `latch == false` with no funded witness is never
    /// rendered — or exported — as "no pass has been observed this process" while the store holds
    /// the pass that ran three seconds after launch.
    private var mediaLaunchPass: MediaLaunchPassRecord? {
        guard let latched = store.mediaAtRestLaunchPassLatched,
              let completedAt = store.mediaAtRestLaunchPassCompletedAt else { return nil }
        return MediaLaunchPassRecord(latched: latched, completedAt: completedAt)
    }

    /// The corpora whose manifest did not come back in the most recent probe — the only ones the
    /// body probe is offered for.
    private var corporaNeedingBodyProbe: [SealedPhotoCorpus] {
        guard let probe = session.manifestProbes.last else { return [] }
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        return SealedPhotoCorpus.allCases.filter { probe.readings[$0] == .noManifestReturned }
    }

    // MARK: - Work

    /// One local scan per fence generation, re-awaited rather than restacked.
    ///
    /// The two-part guard is the census's: once readings are in hand the first clause short-circuits;
    /// while a scan is running there are none yet, so the handle stands in for them and a re-push
    /// awaits the scan already underway. The detached scan does not observe cancellation, which is
    /// why a scan that lands against a moved fence is DROPPED by the session rather than stopped —
    /// and why the awaited scan is re-checked afterwards, since the one it awaited may have been the
    /// dropped one.
    private func runScanIfNeeded() async {
        guard !store.duressSessionActive else { return }
        guard session.censusReadings == nil else { return }
        if let inFlight = scanTask {
            await inFlight.value
            guard session.censusReadings == nil else { return }
        }
        let started = Task { await takeScan() }
        scanTask = started
        await started.value
        // Only if it is still OURS: a reset or an invalidation can start a second scan while this
        // one is running, and clearing the handle unconditionally lets a third push stack a third
        // uncancellable full sweep on the utility pool.
        if scanTask == started { scanTask = nil }
    }

    /// The scan itself, stamped at its START and fenced against the session it may outlive.
    ///
    /// Two facts force both halves. `CryptoFormatCensus.takeReadings` is a detached full sweep that
    /// does not observe cancellation, so a scan can outlive the invalidation that fenced it and land
    /// afterwards; and `Phase3Stamp.takenAt` is consumed by the media row as a SAMPLING order proof,
    /// so a landing time would let a census read entirely BEFORE a converting pass claim to postdate
    /// it.
    private func takeScan() async {
        let generation = session.scanGeneration
        let inputs = CryptoFormatCensus.Inputs.production(for: store)
        let startedAt = Date()
        let readings = await CryptoFormatCensus.takeReadings(inputs: inputs)
        let latchesAt = Date()
        let latches = await Task.detached(priority: .utility) {
            Phase3LatchReadings.take()
        }.value
        session.recordScan(census: readings, latches: latches, at: startedAt, latchesAt: latchesAt,
                           generation: generation)
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
        let capturedEpoch = session.epoch
        let service = SealedPhotoBackupService(
            cloudDataService: CloudKitDataService(),
            identityService: IdentityService()
        )
        var readings: [SealedPhotoCorpus: SealedPhotoManifestReading] = [:]
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        for corpus in SealedPhotoCorpus.allCases {
            readings[corpus] = await manifestReading(service: service, corpus: corpus)
        }
        session.recordManifests(readings, epoch: capturedEpoch)
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
            // NEVER `String(describing:)`: a CKError renders its userInfo, and for a multi-record
            // operation that includes a per-item dictionary keyed by CKRecord.ID — and this scheme's
            // sealed-photo record names are built from photo UUIDs. See `Phase3ProbeFailure`.
            return .unreadable(Phase3ProbeFailure.summarize(error))
        }
    }

    /// One read-only id enumeration for a corpus whose manifest did not come back.
    private func probeBodies(corpus: SealedPhotoCorpus) async {
        let capturedEpoch = session.epoch
        do {
            let ids = try await CloudKitDataService().existingSealedPhotoIDs(corpus: corpus)
            session.recordBodyProbe(.counted(ids.count, truncatedAtPageCap: false),
                                    for: corpus, epoch: capturedEpoch)
        } catch {
            session.recordBodyProbe(.failed(Phase3ProbeFailure.summarize(error)),
                                    for: corpus, epoch: capturedEpoch)
        }
        FernletAuditLog.log("debug.phase3Readout.bodyProbe", context: ["corpus": corpus.rawValue])
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
                "i": "\(index + 1)", "n": "\(chunks.count)",
                "bytes": "\(chunk.utf8.count)", "text": chunk
            ])
        }
    }

    /// R2: the per-chunk byte budget for the log egress route.
    ///
    /// Under os_log's documented ~1 024-byte message maximum, with room left for the event name and
    /// the `i`/`n`/`bytes` context: a chunk over that ceiling is truncated by the unified log
    /// itself, and the index/total scheme detects a MISSING chunk but cannot detect one that
    /// arrived half-length. `bytes` is emitted beside every chunk so a short capture is visible
    /// rather than silently complete-looking.
    private static let logChunkByteBudget = 768
}

#endif

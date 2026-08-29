// CryptoFormatCensus.swift
// Fernlet
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md, app side: the ONE place that runs the
// five per-surface format censuses and folds their very different result shapes into one row model
// a DEBUG diagnostic can render side by side.
//
// Nothing here classifies bytes. Every rule about what a marker means lives in the module that owns
// the format (`SealedColumnFormatCensus`, `PendingNarrativeBufferFormatCensus`,
// `MediaAtRestFormatCensus`, `LockWrapFormatCensus`, `HeartDropSidecarFormatCensus`); this file
// only calls them, off the main actor, and translates. That split is deliberate: a second opinion
// about the format would be a second reader to keep in sync with the writer, which is the exact
// drift each of those censuses was written to avoid.
//
// DEBUG-ONLY, and the `#if` below is what makes that true rather than merely intended. The only
// entry point is the Developer-tools row in `SettingsSheet`, itself `#if DEBUG` — but a gated
// caller leaves the callee in the shipping binary, where an aggregator that walks the sealed store,
// both media roots and a keychain row is exactly the kind of surface that should be ABSENT rather
// than unreachable (the house statement of this is on `MockPrivacyCloudDataService`,
// PrivacyDataSettingsView.swift). Compiling it out also means the compiler, not review, enforces
// the gate: a Release caller added later fails to build.

#if DEBUG

import FernletFoundation
import FernletLock
import Foundation
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit

// MARK: - Surfaces

/// The six Class-A cryptographic surfaces the plan's §2 table lists — the ones holding bytes
/// already written to this device.
///
/// Phase 3 has now deleted every one of those legacy readers, which changes what these counts are
/// FOR rather than retiring them: a non-zero legacy count used to mean "a migration still has work
/// to do", and now means "this device holds that many rows no build can open". Counting bytes
/// nothing can read is still the only way to know they are there, and it is what lets each
/// surface's refusal name what it refused.
///
/// Six cases, not five, and that is the point of the type: ``sealedPhotoBackup`` is **uncountable**
/// (see ``CryptoFormatCensus/sealedPhotoBackupRow``), and the plan's exit criterion is "the census
/// reports for all six surfaces". A surface that cannot be counted must still appear and must still
/// say so out loud — dropping it from the list would turn "we cannot look here" into silence, which
/// is the one failure mode a census cannot survive.
///
/// `nonisolated` against the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: this is a
/// plain value read from the detached scan as well as from the view.
nonisolated enum CryptoFormatCensusSurface: String, Sendable, CaseIterable, Identifiable {
    /// `FernletCrypto/ColumnCrypto` — the four sealed Core Data corpora (journal, cycle, intimacy,
    /// worry). The only three-rung ladder (legacy → V2 → V3) and the largest corpus.
    case sealedColumns
    /// `PrivateStoreCore/PendingNarrativeBuffer` — the single locked-state note file.
    case pendingNarrativeBuffer
    /// `PrivateMediaStore/MediaAtRestCrypto` — own photos plus the friend photo wall.
    case mediaAtRest
    /// `FernletLock/FernletLockService` — the one scrypt-wrapped content key in the keychain.
    case lockContentKeyWrap
    /// `ProximityKit/HeartSharing/HeartDropSidecarKey` — the four heart-drop sidecar files.
    case heartDropSidecars
    /// `App/Fernlet/SealedPhotoBackupService` — the iCloud sealed-photo manifest. Present and
    /// uncountable; see ``CryptoFormatCensus/sealedPhotoBackupRow``.
    case sealedPhotoBackup

    var id: String { rawValue }

    /// Plain-English name for the debug row. Not localized, like the rest of the debug tab.
    var displayName: String {
        switch self {
        case .sealedColumns: return "Sealed columns (journal, cycle, intimacy, worry)"
        case .pendingNarrativeBuffer: return "Locked-state note buffer"
        case .mediaAtRest: return "Sealed media at rest (own photos + friend wall)"
        case .lockContentKeyWrap: return "App-lock content-key wrap"
        case .heartDropSidecars: return "Heart-drop sidecars"
        case .sealedPhotoBackup: return "Sealed photo backup (iCloud)"
        }
    }
}

// MARK: - Row model

/// One surface's line in the census: a number if one could honestly be produced, a detail line, and
/// a status saying how much the number is worth.
///
/// ## The invariant this type exists to hold
///
/// **`nil` is never rendered as `0`.** Every per-surface census deliberately types its count as
/// `Int?` for the same reason (`PendingNarrativeBufferFormatCensus.legacyCount`,
/// `LockWrapFormatCensusReport.legacyWrapCount`), and the whole value of that choice is lost the
/// moment an aggregator coalesces it. A `0` in this row means "we looked at that surface and found
/// no definitely-legacy blob"; ``legacyCountText`` renders anything else as an em dash, and
/// ``status`` says why.
///
/// There is deliberately **no whole-device total** on ``CryptoFormatCensusReport``. Summing these
/// numbers would have to do something with the surfaces that have none, and every option is a lie:
/// skipping them under-reports, treating them as zero manufactures the clean reading Phase 3 is
/// gated on. The plan asks for "a number per surface" and that is exactly what this is.
nonisolated struct CryptoFormatCensusRow: Sendable, Equatable, Identifiable {

    /// How much the row's number is worth — the fail-loud half of the model.
    nonisolated enum Status: Sendable, Equatable {
        /// A number, produced from a pass that saw everything it swept.
        case counted
        /// A number, from a pass with blind spots: the count is a LOWER bound. The string says what
        /// the pass could not see (a row cap, an unreadable file, an unlistable directory).
        case countedWithBlindSpots(String)
        /// No number this time. The string says what stopped it — a locked device, a keychain
        /// failure, a store that is not loaded. Retakeable: it is a fact about this reading, not
        /// about the surface.
        case indeterminate(String)
        /// No number, ever, by construction. The string says why the surface has no marker to
        /// count. NOT retakeable — only a format change (Phase 1) makes this surface countable.
        case uncountable(String)
    }

    /// Which surface this row is about.
    let surface: CryptoFormatCensusSurface
    /// The exact count of blobs that are definitely in a legacy format, or `nil` when no number
    /// could be produced. Per-surface meaning is spelled out in ``detail`` — this is the number the
    /// plan's Phase 3 gate watches reach zero for that surface, not a cross-surface unit.
    let definitelyLegacy: Int?
    /// The per-surface breakdown, one short line: buckets, file states, and any upper-bound caveat.
    let detail: String
    /// What the number is worth. See ``Status``.
    let status: Status

    var id: String { surface.rawValue }

    /// The row's heading.
    var displayName: String { surface.displayName }

    /// The number as the UI must print it: the count, or an em dash. **Never `0` for a `nil`.**
    var legacyCountText: String {
        guard let definitelyLegacy else { return "—" }
        return "\(definitelyLegacy)"
    }

    /// Whether this row produced a number at all.
    var hasCount: Bool { definitelyLegacy != nil }

    /// The status's explanation, or `nil` for a clean count — what a diagnostic prints under the
    /// detail line to explain a dash, or a number that is only a lower bound.
    var caveat: String? {
        switch status {
        case .counted:
            return nil
        case let .countedWithBlindSpots(reason), let .indeterminate(reason), let .uncountable(reason):
            return reason
        }
    }
}

/// Every surface's row, in ``CryptoFormatCensusSurface/allCases`` order.
nonisolated struct CryptoFormatCensusReport: Sendable, Equatable {
    /// One row per surface.
    let rows: [CryptoFormatCensusRow]

    /// The plan's Phase-0 exit criterion, as far as code can check it: **every surface reported
    /// something explicit**. It is deliberately NOT "every surface produced a number" — a row that
    /// could not look (or never can) satisfies this by saying so, and the plan's "if any count
    /// cannot be produced, stop" is then a judgement the reader makes from ``rowsWithoutACount``,
    /// with the numbers and the reasons in front of them.
    var allSurfacesReported: Bool {
        Set(rows.map(\.surface)) == Set(CryptoFormatCensusSurface.allCases)
    }

    /// The rows carrying no number — the ones a Phase-3 decision must be taken against, never over.
    var rowsWithoutACount: [CryptoFormatCensusRow] { rows.filter { !$0.hasCount } }
}

// MARK: - The aggregator

/// Runs the five countable per-surface censuses off the main actor and folds them — plus the one
/// uncountable surface — into ``CryptoFormatCensusReport``.
///
/// ## Read-only, and persisting nothing
///
/// Every underlying census is read-only by construction (no decrypt, no keychain mint, no file
/// created), and this layer adds no state of its own: **no `UserDefaults` key, no latch, no
/// cache**. That is a deliberate refusal, not an omission. A latch would be a new persisted surface
/// needing a disposition row in `Docs/PrivacyWipeCoverage.md` (the house wipe wall), and a stored
/// "census: clean" is a claim with a shelf life nobody can see — a restored iOS backup, or any
/// legacy reader still in the dispatch, can make it wrong without the latch noticing. (Until
/// Phase 3 the shelf life was shorter still: `ColumnCrypto.sealPlaintext`'s fail-open could
/// invalidate the reading on the very next write. That branch is closed; the refusal to latch is
/// not.)
///
/// ## Concurrency
///
/// ``takeReadings(inputs:)`` hands the whole scan to `Task.detached(priority: .utility)`, following
/// `FernletStore.migrateAndBindOwnPhotoKey`: the work is blocking file and keychain I/O plus a Core
/// Data `performAndWait`, none of which belongs on the main actor, and only `Sendable` values cross
/// back. The main actor does nothing but assemble row models from the returned readings. It is the
/// ONE spelling of the detached scan and the one place stating its cost — see its own doc for the
/// two honest limits.
nonisolated enum CryptoFormatCensus {

    // MARK: Inputs

    /// Everything the five countable censuses need, injected as one value.
    ///
    /// Injectable in full so tests can census planted fixtures without building a `FernletStore` —
    /// which they must not do casually anyway (see `PhotoDirectoryIsolationTests`: a store on the
    /// process-wide own-photo root has its corpora deleted by any concurrently-running wipe).
    /// ``production`` and ``production(for:)`` are the two shipped spellings.
    ///
    /// `@unchecked Sendable`, for exactly one member: ``sealedStore`` is a
    /// `PrivatePersistenceController`, a class over `NSPersistentContainer` and therefore not
    /// `Sendable` — which is why `PrivateStoreCore` declares its own shared instance
    /// `nonisolated(unsafe)`. The unchecked conformance is sound *here* because of how the
    /// controller is used: ``readAllSurfaces()`` passes it straight to
    /// `SealedColumnFormatCensus.run(controller:)`, whose entire interaction is
    /// `container.newBackgroundContext()` followed by `performAndWait` — Core Data's own
    /// cross-thread contract, on a context created inside the detached task and thrown away when it
    /// returns. Nothing here mutates the controller, touches `viewContext`, or retains anything
    /// past the scan.
    struct Inputs: @unchecked Sendable {
        /// The sealed Core Data stack to census. Production is `PrivatePersistenceController.shared`
        /// — the same instance the four sealed repositories default to (see
        /// `JournalNarrativeRepository.init(controller:defaults:)`), deliberately NOT a second
        /// controller over the same SQLite file.
        let sealedStore: PrivatePersistenceController
        /// The app container's Documents directory — the root of the three own-photo corpora.
        let ownPhotoDocumentsDirectory: URL
        /// The proximity support directory — the friend photo wall's root.
        let friendWallSupportDirectory: URL
        /// The pending-narrative buffer's storage identity. Only its `directory` is read; the
        /// census must never reach for the key half (asking for it would mint one).
        let narrativeScope: PendingNarrativeStorageScope
        /// The keychain service holding the lock's wrapped content key.
        let lockKeychainService: String
        /// The heart-drop root holding the four sidecar files.
        let heartDropDirectory: URL

        init(
            sealedStore: PrivatePersistenceController,
            ownPhotoDocumentsDirectory: URL,
            friendWallSupportDirectory: URL,
            narrativeScope: PendingNarrativeStorageScope,
            lockKeychainService: String,
            heartDropDirectory: URL
        ) {
            self.sealedStore = sealedStore
            self.ownPhotoDocumentsDirectory = ownPhotoDocumentsDirectory
            self.friendWallSupportDirectory = friendWallSupportDirectory
            self.narrativeScope = narrativeScope
            self.lockKeychainService = lockKeychainService
            self.heartDropDirectory = heartDropDirectory
        }

        /// The shipped inputs, resolved from each surface's own production accessor rather than
        /// re-spelled here — the paths and services the app actually reads at run time.
        ///
        /// - Warning: **Intended for use after launch has loaded the sealed store.** Reading this
        ///   touches `PrivatePersistenceController.shared`, which lazily builds its container on
        ///   first access; called early enough (or in a process that never opens the private area)
        ///   it would be the thing that CREATES the store rather than a reading of one. A census
        ///   must never be the reason a persisted surface comes into existence, so the only shipped
        ///   caller is the DEBUG diagnostic's `.task`, which runs long after launch — and that one
        ///   uses ``production(for:)`` anyway.
        static var production: Inputs {
            Inputs(
                sealedStore: .shared,
                ownPhotoDocumentsDirectory: FernletStore.defaultPhotoDocumentsDirectory,
                friendWallSupportDirectory: ProximitySupportLayout.defaultDirectory,
                narrativeScope: .production,
                lockKeychainService: KeychainItem.productionService,
                heartDropDirectory: HeartDropStorageScope.production.directory
            )
        }

        /// The shipped inputs for a LIVE store — the honest spelling when one is in hand.
        ///
        /// Two of the six roots are per-`FernletStore` instance state, not process constants
        /// (`photoDocumentsDirectory` and `proximitySupportDirectory`; see those properties for the
        /// cross-suite wipe race that made them injectable). In production both resolve to exactly
        /// the paths ``production`` names, so the two factories agree on a real device — but a
        /// census taken through the running store censuses the corpora that store is actually
        /// using, which is what a diagnostic on a device should report.
        ///
        /// - Note: the OTHER four members are still re-spelled here rather than read off the live
        ///   services — `narrativeScope: .production` and `lockKeychainService:
        ///   KeychainItem.productionService` in particular. `FernletLockService` resolves its own
        ///   keychain service, and `PendingNarrativeBuffer` its own scope, from those same two
        ///   constants, so the spellings agree today by construction; they are not READ from those
        ///   services, so nothing makes them keep agreeing. A service that starts choosing its scope
        ///   or keychain service dynamically (per-host, per-profile, a test override that leaks into
        ///   a build) would leave this censusing an empty location and reporting its zeros as a
        ///   clean count. If either ever becomes instance state, resolve it here the way the two
        ///   media roots already are, rather than restating the new rule.
        /// - Warning: carries ``production``'s first-touch warning — `sealedStore: .shared` is the
        ///   same lazily-built controller.
        @MainActor
        static func production(for store: FernletStore) -> Inputs {
            Inputs(
                sealedStore: .shared,
                ownPhotoDocumentsDirectory: store.photoDocumentsDirectory,
                friendWallSupportDirectory: store.proximitySupportDirectory,
                narrativeScope: .production,
                lockKeychainService: KeychainItem.productionService,
                heartDropDirectory: store.proximitySupportDirectory
            )
        }

        /// Takes all five countable readings. Blocking: file reads, one keychain read, and a Core
        /// Data scan under `performAndWait`. Call it off the main actor — ``run(inputs:)`` does.
        func readAllSurfaces() -> Readings {
            Readings(
                sealedColumns: SealedColumnOutcome(runningOver: sealedStore),
                pendingNarrative: PendingNarrativeBufferFormatCensus.take(of: narrativeScope),
                media: MediaAtRestFormatCensus(
                    ownPhotoDocumentsDirectory: ownPhotoDocumentsDirectory,
                    friendWallSupportDirectory: friendWallSupportDirectory
                ).run(),
                lockWrap: LockWrapFormatCensus.inspect(service: lockKeychainService),
                heartDrop: HeartDropSidecarFormatCensus.survey(in: heartDropDirectory)
            )
        }
    }

    // MARK: Readings

    /// What the sealed-column census produced.
    ///
    /// A two-case enum rather than `Result<_, any Error>` so the readings stay `Sendable` on the way
    /// back out of the detached task, and so the failure arrives as the text a diagnostic will print
    /// (`SealedColumnFormatCensus.Failure` is `CustomStringConvertible` precisely for this).
    nonisolated enum SealedColumnOutcome: Sendable, Equatable {
        /// The scan ran.
        case counted(SealedColumnFormatCensusResult)
        /// The scan refused to produce a number — a drifted census table, a store that is not
        /// loaded, a dirtied context. Carries the failure's own description.
        case failed(String)

        /// Runs the census, turning any throw into ``failed(_:)``.
        init(runningOver controller: PrivatePersistenceController) {
            do {
                let result = try SealedColumnFormatCensus.run(controller: controller)
                self = .counted(result)
            } catch {
                // Every `SealedColumnFormatCensus.Failure` is a refusal to report a number that
                // would be wrong; carrying its description keeps that refusal legible in the row.
                self = .failed("\(error)")
            }
        }
    }

    /// The five countable readings, exactly as their modules produced them.
    ///
    /// Kept as the underlying result types rather than pre-flattened strings so the mapping to rows
    /// stays a pure function this file's tests can drive directly, one surface at a time.
    nonisolated struct Readings: Sendable, Equatable {
        var sealedColumns: SealedColumnOutcome
        var pendingNarrative: PendingNarrativeBufferFormatCensus
        var media: MediaAtRestFormatCensusReport
        var lockWrap: LockWrapFormatCensusReport
        var heartDrop: HeartDropSidecarFormatCensus.Report

        init(
            sealedColumns: SealedColumnOutcome,
            pendingNarrative: PendingNarrativeBufferFormatCensus,
            media: MediaAtRestFormatCensusReport,
            lockWrap: LockWrapFormatCensusReport,
            heartDrop: HeartDropSidecarFormatCensus.Report
        ) {
            self.sealedColumns = sealedColumns
            self.pendingNarrative = pendingNarrative
            self.media = media
            self.lockWrap = lockWrap
            self.heartDrop = heartDrop
        }
    }

    // MARK: Running

    /// Takes the five countable readings on a detached utility task. The ONE spelling of the scan.
    ///
    /// Exposed as its own step because the Phase 3 gate readout folds the SAME readings differently
    /// (`Phase3GateReadoutBuilder`), and two spellings of the sweep would be two sweeps to keep in
    /// agreement. Nothing about the census's contract changes: no decrypt, no key fetch, no write,
    /// no persisted state.
    ///
    /// Two honest limits, both deliberate:
    /// - The detached task **blocks a cooperative-pool worker** for the length of the scan, exactly
    ///   as the own-photo migration's does. Nothing here is `async`, so there is no suspension point
    ///   to yield at; a thread is the unit of work. That is tolerable because every underlying
    ///   census is BOUNDED by construction — a 20,000-row cap on the sealed scan, 10,000 files per
    ///   media directory, one keychain read, four sidecar `stat`s, four header bytes per file — so
    ///   the block is bounded too. It matches the house precedent; a `DispatchQueue`/thread of its
    ///   own would be the correct escalation if the bounds ever grow.
    /// - It **does not observe cancellation.** `Task.detached` inherits nothing, and none of the
    ///   blocking calls check `Task.isCancelled`, so a cancelled caller stops awaiting while the
    ///   scan runs to completion. Read-only work with no side effects, so the cost of that is CPU,
    ///   not correctness — but a caller that can be navigated away from mid-scan must not simply
    ///   start another one. `SettingsSheet` holds the in-flight task in `@State` and re-awaits it
    ///   rather than stacking a second scan; anything else calling this owes the same.
    static func takeReadings(inputs: Inputs) async -> Readings {
        await Task.detached(priority: .utility) { inputs.readAllSurfaces() }.value
    }

    /// Takes the whole census and returns one row per surface.
    ///
    /// The scan runs on a detached utility task; only the `Sendable` ``Readings`` come back, and the
    /// row assembly (pure string formatting) happens on the caller's actor.
    static func run(inputs: Inputs) async -> CryptoFormatCensusReport {
        report(from: await takeReadings(inputs: inputs))
    }

    /// Folds five readings plus the uncountable surface into the six rows. Pure.
    static func report(from readings: Readings) -> CryptoFormatCensusReport {
        CryptoFormatCensusReport(rows: [
            row(forSealedColumns: readings.sealedColumns),
            row(forPendingNarrative: readings.pendingNarrative),
            row(forMedia: readings.media),
            row(forLockWrap: readings.lockWrap),
            row(forHeartDrop: readings.heartDrop),
            sealedPhotoBackupRow
        ])
    }

    // MARK: Per-surface mapping

    /// `ColumnCrypto`: the unprefixed bucket is the exact Phase-3 gate number; the two marked
    /// buckets are UPPER BOUNDS (a legacy blob's random first nonce byte collides with a marker
    /// ~1/256 per marker), so the detail line prints them with `≤` and never as exact counts.
    static func row(forSealedColumns outcome: SealedColumnOutcome) -> CryptoFormatCensusRow {
        switch outcome {
        case let .counted(result):
            let tally = result.total
            let detail = "legacy \(tally.unprefixed) exact · v3 ≤\(tally.v3Marked) / v2 ≤\(tally.v2Marked) upper bounds"
                + " · empty \(tally.emptyOrNil) · scanned \(result.rowsScanned) of \(result.rowsAvailable) rows"
                + sealedColumnVacuityNote(result)
            return CryptoFormatCensusRow(
                surface: .sealedColumns,
                definitelyLegacy: tally.unprefixed,
                detail: detail,
                status: sealedColumnStatus(result)
            )
        case let .failed(reason):
            return CryptoFormatCensusRow(
                surface: .sealedColumns,
                definitelyLegacy: nil,
                detail: "the sealed store could not be censused",
                status: .indeterminate(reason)
            )
        }
    }

    /// Says out loud when this zero is over an EMPTY corpus — the reading a fresh install and a
    /// just-wiped device both produce.
    ///
    /// It goes in the DETAIL rather than the status deliberately: over an empty corpus the count is
    /// exact, not a lower bound, so `countedWithBlindSpots` would be the wrong word. What was wrong
    /// was the silence. `legacy 0 · scanned 0 of 0 rows` rendered with nothing else beside it, next
    /// to a media row that honestly says "nothing was there to count, which is not a swept-clean
    /// corpus" — and this is the surface Phase 3 deletes a reader on the strength of. `emptyOrNil`
    /// is counted apart from `unprefixed`, so rows whose sealed columns are all nil read as a
    /// healthy row count and are the variant a bare row-count check would miss.
    private static func sealedColumnVacuityNote(_ result: SealedColumnFormatCensusResult) -> String {
        let sealedValues = result.total.total - result.total.emptyOrNil
        guard result.rowsAvailable == 0 || sealedValues == 0 else { return "" }
        return "  [VACUOUS: \(result.rowsAvailable) rows and \(sealedValues) sealed column values —"
            + " nothing was there to count, which is not a swept-clean corpus. A fresh install and a"
            + " just-wiped device both read this way.]"
    }

    /// Truncation and unreadable rows both make the exact count a LOWER bound: the rows the scan
    /// never reached, or could not read, may hold legacy blobs.
    ///
    /// So does the third clause, which is PERMANENT rather than a property of this pass: while any
    /// marked blob exists, the exact-zero the detail line advertises is necessary but not
    /// sufficient. A legacy blob's first nonce byte equals a marker ~1/256 times per marker, and no
    /// byte-only classifier can tell such a blob from a genuinely marked one — so every marked blob
    /// is a blob that COULD be collided legacy, and the row has to say so next to the word "exact"
    /// rather than leaving it to `SealedColumnFormatTally`'s doc comment. A keyed migration pass
    /// used to resolve the sliver by attempting the open; Phase 3 deleted that pass along with the
    /// rungs it reported, so **nothing resolves it now** — the caveat is permanent rather than
    /// pending, and the row must keep saying so.
    private static func sealedColumnStatus(_ result: SealedColumnFormatCensusResult) -> CryptoFormatCensusRow.Status {
        var blindSpots: [String] = []
        if result.truncated {
            blindSpots.append("the \(result.rowCap)-row cap stopped the scan, so \(result.rowsAvailable - result.rowsScanned) rows were never classified")
        }
        let indeterminate = result.total.indeterminate
        if indeterminate > 0 {
            blindSpots.append("\(indeterminate) column values could not be read")
        }
        let marked = result.total.v3Marked + result.total.v2Marked
        if marked > 0 {
            blindSpots.append("0 is necessary, not sufficient — up to \(marked) marked blobs could be collided legacy (a legacy nonce's first byte hits a marker ~1/256)")
        }
        guard blindSpots.isEmpty else {
            return .countedWithBlindSpots(blindSpots.joined(separator: "; ") + " — the count is a lower bound")
        }
        return .counted
    }

    /// `PendingNarrativeBuffer`: one file per scope, so the number is 0 or 1 — or nothing at all
    /// when the file exists and could not be read (a device-locked census), which must never score
    /// as a clean zero.
    static func row(forPendingNarrative census: PendingNarrativeBufferFormatCensus) -> CryptoFormatCensusRow {
        let state: String
        var status = CryptoFormatCensusRow.Status.counted
        switch census.format {
        case .absent: state = "no buffer file (nothing was ever buffered)"
        case .empty: state = "the buffer file is zero bytes"
        case .v2Marked: state = "current format (FNB2 marked)"
        case .legacyUnprefixed: state = "legacy — no FNB2 marker"
        case let .unreadable(reason):
            state = "the buffer file exists but could not be read"
            status = .indeterminate("\(reason) — retake with the device unlocked; this is not a zero")
        }
        return CryptoFormatCensusRow(
            surface: .pendingNarrativeBuffer,
            definitelyLegacy: census.legacyCount,
            detail: "\(census.fileURL.lastPathComponent): \(state)",
            status: status
        )
    }

    /// `MediaAtRestCrypto`: the primary number is the unprefixed bucket — the files the reader would
    /// hand to its legacy branch. The bucket also holds bytes nothing recognises, which a byte-only
    /// classifier cannot separate from a legacy box, so it is an upper bound on true legacy files
    /// and the detail line names it as such. Pre-sealing plaintext JPEGs get their own figure: a
    /// legitimate second legacy generation whose plaintext is on disk.
    ///
    /// The detail line also prints how many of the swept locations were not THERE, because eight
    /// all-zero locations and eight absent ones render identically otherwise, and only one of them
    /// is evidence about a corpus (see ``MediaAtRestFormatLocationCensus/existed``).
    static func row(forMedia report: MediaAtRestFormatCensusReport) -> CryptoFormatCensusRow {
        let tally = report.total
        let detail = "unprefixed legacy-or-unrecognised \(tally.unprefixedLegacyOrUnrecognized)"
            + " · plaintext JPEG \(tally.plaintextJPEG) · v2 marked \(tally.v2Marked)"
            + " · empty \(tally.empty) · examined \(tally.examined) across \(report.locations.count) locations"
            + " · \(report.absentLocationCount) of \(report.locations.count) locations absent"
        return CryptoFormatCensusRow(
            surface: .mediaAtRest,
            definitelyLegacy: tally.unprefixedLegacyOrUnrecognized,
            detail: detail,
            status: mediaStatus(report)
        )
    }

    /// What the media number is worth, in two independent halves.
    ///
    /// **Blind spots** make it a LOWER bound: unreadable files (the locked-device answer),
    /// directories that would not enumerate (each hiding an unknown number of files), a capped
    /// sweep — and a pass whose locations were ALL absent, which counted nothing at all and must
    /// never be shown as a swept-clean corpus (per-location absence stays an honest zero; every
    /// location absent on a device that has been running the app means the census swept roots the
    /// store is not using).
    ///
    /// **Pre-sealing plaintext JPEGs** are not a blind spot and do not bound anything — they are a
    /// SECOND legacy generation, sitting in the clear, which the primary number deliberately does
    /// not include. They are named because they are the one generation still being converted:
    /// Phase 3 deleted `gcmOpen`'s legacy branch, so the primary number now counts bytes NOTHING
    /// opens, while these are healed by the format migrator's remaining arm and by
    /// `MealPhotoStore`'s upgrade-on-read.
    private static func mediaStatus(_ report: MediaAtRestFormatCensusReport) -> CryptoFormatCensusRow.Status {
        let tally = report.total
        var blindSpots: [String] = []
        if tally.indeterminate > 0 { blindSpots.append("\(tally.indeterminate) files unreadable") }
        if tally.unlistableDirectories > 0 {
            blindSpots.append("\(tally.unlistableDirectories) directories would not list (each hides an unknown number of files)")
        }
        if tally.truncated { blindSpots.append("the per-directory cap stopped the sweep") }
        if report.allLocationsAbsent {
            blindSpots.append("none of the \(report.locations.count) swept locations exists — nothing was there to count, which is not a swept-clean corpus")
        }
        var notes: [String] = []
        if !blindSpots.isEmpty {
            notes.append(blindSpots.joined(separator: "; ") + " — the count is a lower bound")
        }
        if tally.plaintextJPEG > 0 {
            notes.append("\(tally.plaintextJPEG) pre-sealing plaintext JPEGs present — a second legacy generation, sealed by the format migrator's plaintext arm and by the meal store's upgrade-on-read")
        }
        guard notes.isEmpty else { return .countedWithBlindSpots(notes.joined(separator: ". ")) }
        return .counted
    }

    /// `FernletLockService`: one wrap per install, so 0 or 1 — and no number at all for an empty
    /// row or a keychain failure. An absent row is a real zero with three legitimate readings (no
    /// lock configured, a Secure-Enclave hard binding, or — on enclave-less hardware — a wrap that
    /// has gone missing); the census does not guess which, and neither does this row.
    static func row(forLockWrap report: LockWrapFormatCensusReport) -> CryptoFormatCensusRow {
        let state: String
        var status = CryptoFormatCensusRow.Status.counted
        switch report.state {
        case .absent:
            state = "no wrap row (no lock configured; the key is enclave-bound;"
                + " or, on enclave-less hardware, a configured lock whose wrap has gone missing — a fault)"
        case .v2Marked: state = "current format (FLW2 marked)"
        case .legacyUnprefixed: state = "legacy — no FLW2 marker"
        case .malformedEmpty:
            state = "the wrap row exists and is EMPTY"
            status = .indeterminate("no first-party writer produces an empty wrap — this is a fault, not a clean zero")
        case let .unreadable(osStatus):
            state = "the keychain refused the read"
            status = .indeterminate("OSStatus \(osStatus) — retake with the device unlocked; this is not a zero")
        }
        return CryptoFormatCensusRow(
            surface: .lockContentKeyWrap,
            definitelyLegacy: report.legacyWrapCount,
            detail: "\(report.account): \(state)",
            status: status
        )
    }

    /// `HeartDropSidecarKey`: four known file names, each classified by its marker. The count is
    /// exact for the names surveyed; an unreadable file makes it a lower bound, and so do files
    /// matching neither marker (a v0 plaintext sidecar, or garbage) — both are counted in the detail
    /// line AND named in the caveat, because both block a "clean" verdict without being legacy. See
    /// ``heartDropStatus(_:)``.
    static func row(forHeartDrop report: HeartDropSidecarFormatCensus.Report) -> CryptoFormatCensusRow {
        let states = report.files
            .map { "\($0.fileName) \($0.state.rawValue)" }
            .joined(separator: " · ")
        let summary = "unsealed-or-unrecognised \(report.unsealedOrUnrecognizedCount)"
            + " · v2 \(report.v2SealedCount) · absent \(report.absentCount)"
        return CryptoFormatCensusRow(
            surface: .heartDropSidecars,
            definitelyLegacy: report.legacySealedCount,
            detail: "\(summary) — \(states)",
            status: heartDropStatus(report)
        )
    }

    /// The sidecar row's verdict, keyed off `Report.isClean` rather than `Report.isConclusive`.
    ///
    /// `isConclusive` asks only "was every file readable" — so a corpus full of files matching
    /// NEITHER marker (a v0 plaintext sidecar awaiting its silent seal-on-load migration, or
    /// garbage) scores a clean count, which is precisely the reading the surface's own census
    /// refuses: those files are unmigrated or unproven, and they are why `isClean` exists as a
    /// stricter question than `isConclusive`. Both facts are named, because they need different
    /// responses — an unreadable file is retakeable after unlock, an unrecognised one is not.
    ///
    /// A non-zero LEGACY count is not a caveat: `isClean` is false there too, but the number is
    /// exact and the row's job is to print it. So the caveat is built from the two blind-spot
    /// buckets and the status falls back to ``CryptoFormatCensusRow/Status/counted`` when neither
    /// is present.
    private static func heartDropStatus(_ report: HeartDropSidecarFormatCensus.Report) -> CryptoFormatCensusRow.Status {
        guard !report.isClean else { return .counted }
        var blindSpots: [String] = []
        if report.unreadableCount > 0 {
            blindSpots.append("\(report.unreadableCount) sidecar files could not be read (retake unlocked)")
        }
        if report.unsealedOrUnrecognizedCount > 0 {
            blindSpots.append("\(report.unsealedOrUnrecognizedCount) match neither marker — a v0 plaintext sidecar or garbage, unmigrated either way")
        }
        guard !blindSpots.isEmpty else { return .counted }
        return .countedWithBlindSpots(blindSpots.joined(separator: "; ") + " — the count is a lower bound")
    }

    // MARK: The surface that cannot be counted

    /// `SealedPhotoBackupService` — **present, and still uncountable.** Static text: no network
    /// call, no CloudKit fetch, and above all no invented number.
    ///
    /// The surface's original problem was the absence of a marker: a manifest entry commits
    /// `contentHash`, an unversioned 32-byte digest, and telling the v2 pre-image from the legacy
    /// one requires the plaintext — so classifying a single entry meant decrypting the sealed
    /// manifest AND pulling that photo's body record from iCloud to hash it, with entries whose body
    /// record has vanished unclassifiable at any price.
    ///
    /// Phase 1 supplied the missing marker — `SealedPhotoManifest.Entry.hashVersion`, decoding as 1
    /// (legacy **or** unproven) when absent, stamped 2 only by a pass that read the plaintext, and
    /// aggregated per corpus by the computed `minimumEntryHashVersion`. That fixes the FUTURE:
    /// every entry written or verified from now on carries its own answer. It changes nothing about
    /// what can be counted TODAY, for two independent reasons. Every entry committed before the
    /// marker existed decodes as 1 whether its digest is legacy or v2, so the number this row could
    /// print is a not-yet-proven count and not a legacy count — and reading even that would mean
    /// fetching and decrypting each corpus's manifest over the network, which no census here does
    /// for any surface. Phase 2.1's device-local completion latch
    /// (`SealedPhotoBackupMigrationLatch`) is not a substitute for the number either, and would
    /// not prove zero anyway: it attests only this device's vouchable entries, is invalidated by
    /// foreign writes, and a full pass skips local photos it cannot read and never heals entries
    /// another device carried forward.
    ///
    /// So this stays the plan's "if any count cannot be produced, stop" case, and the honest
    /// response is to print exactly that. What changed is the EXIT, not the reading: the zero-proof
    /// for this surface is `minimumEntryHashVersion >= 2` across the three corpora after a
    /// full-verification pass has re-committed each manifest, observed on a device — never a census
    /// number (see the plan's §4).
    static let sealedPhotoBackupRow = CryptoFormatCensusRow(
        surface: .sealedPhotoBackup,
        definitelyLegacy: nil,
        detail: "UNAVAILABLE — a marker now exists (`hashVersion` per manifest entry, aggregated by"
            + " `minimumEntryHashVersion`), but it can only answer for entries written or verified since it"
            + " landed: everything committed earlier decodes as the unproven default whatever its digest is,"
            + " and reading even that would mean fetching and decrypting each corpus's sealed manifest from"
            + " iCloud, which this census does not do for any surface.",
        status: .uncountable(
            "An entry is proven — and stamped — only by a full-verification reconcile (turning backup on, or"
            + " Retry). A device-local completion latch now exists (Phase 2.1) but attests only this device's"
            + " vouchable entries and is invalidated by foreign writes — the proof for this surface remains"
            + " `minimumEntryHashVersion >= 2` across the three corpora, read from the manifests on a device;"
            + " it is not a number a census can produce."
            + " That number CAN be read on request from the Phase 3 gate readout next door, at the cost of a"
            + " network fetch and a manifest decrypt per corpus — which is precisely why it is not read here."
        )
    )
}

#endif

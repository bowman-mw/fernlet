// Phase3GateReadout.swift
// Fernlet
//
// Phase 3 of Docs/Plan-Crypto-Standardization-2026-08-27.md, app side: the vocabulary, the
// stamped-observation model, the pure fold from readings + latches + witnesses to six gate rows,
// and the report builder.
//
// Model only — no SwiftUI, no I/O. Everything here is a pure function over values somebody else
// purchased, which is what lets `Phase3GateReadoutTests` drive every rule with hand-built fixtures
// and no FernletStore, no CloudKit and no device.
//
// This is the SIBLING of `CryptoFormatCensus`, not a replacement, and the two promises are
// deliberately different. The census counts marker bytes and writes nothing. This surface also
// reads completion latches, folds witnesses from migrator passes, and renders readings a caller
// bought over the network. Both promises are stated in copy on their own screens.
//
// THREE OF THE SIX GATES HAVE OUTLIVED THEIR DECISION. Phase 3 deleted the sealed-column, lock-wrap
// and heart-drop-sidecar legacy READERS — and, with the sealed-column reader, the keyed migrator
// that was the second witness on that gate, the derived lock-wrap row latch, and the sidecar
// completion latch. A gate exists to license a deletion; those deletions have happened. The three
// rows are therefore kept as CENSUS-ONLY readings and their wording says exactly that: they no
// longer license anything, they report how many stored rows this build can no longer open. That is
// a smaller claim and a more urgent number, and the rows are worth more after the delete than
// before it — a count that used to mean "not yet converted" now means "unreadable data on this
// device". Nothing here was softened into a pass; the verdict vocabulary is unchanged.
//
// DEBUG-ONLY, and the file-scope `#if` is what makes that true rather than merely intended — the
// reason is stated verbatim at CryptoFormatCensus.swift:15-21: a gated caller leaves the callee in
// the shipping binary, and this surface should be ABSENT rather than unreachable. Compiling it out
// also means the compiler, not review, enforces the gate.

#if DEBUG

import CloudKitSync
import FernletFoundation
import FernletLock
import Foundation
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit

// MARK: - Stamps

/// When one observation was taken, and what it was.
///
/// The readout deliberately carries **no single `takenAt`**. A sitting spans minutes: the local
/// scan, a network manifest probe, a healing pass the owner runs from another screen, a second
/// probe, and a media at-rest pass funded from this page. One timestamp over all of that would let
/// a reader months later pair a census figure with a pass that ran after it.
///
/// ## Invariants
/// - A row that folds two observations MUST print both stamps.
/// - A row whose stamps are out of the order the gate requires — a marker census taken BEFORE the
///   media pass it is quoted beside — refuses to discharge rather than silently pairing them.
nonisolated struct Phase3Stamp: Sendable, Equatable {
    /// What was observed, in the readout's own words ("marker census", "media at-rest pass").
    /// Not localized, like the rest of the debug tab.
    let label: String
    /// When the observation landed.
    let takenAt: Date

    /// Creates a stamp.
    init(label: String, takenAt: Date = Date()) {
        self.label = label
        self.takenAt = takenAt
    }

    /// The stamp as the report prints it — ISO-8601 so a reading pasted into a bug note is
    /// unambiguous in any locale.
    var printed: String { "\(label) @ \(takenAt.ISO8601Format())" }
}

// MARK: - The six gates

/// The six Class-A surfaces Phase 3 is gated on, in ``CryptoFormatCensusSurface/allCases`` order so
/// the two debug surfaces read in the same order.
///
/// ## Three of the six no longer gate anything, and the wording says so
///
/// ``sealedColumns``, ``lockContentKeyWrap`` and ``heartDropSidecars`` were read BEFORE their legacy
/// readers were deleted, to license those deletions. The deletions have since landed. Each of the
/// three is now a CENSUS-ONLY row whose ``gateWording`` states plainly that the reader is already
/// gone: the row reports how many stored rows this build can no longer open, and a non-zero count is
/// a more serious finding than it used to be, not a less serious one.
///
/// ## What that costs, stated rather than dropped
///
/// The sealed-column row's second witness was a keyed migrator pass, and it existed for one reason:
/// roughly 1 legacy blob in 256 begins with a byte that collides with a format marker, so a keyless
/// `unprefixed == 0` cannot see it. Opening the value with the real key was the only way to resolve
/// that sliver, and the migrator that did it was deleted along with the reader it fed. **Nothing in
/// the app can resolve the collided sliver any more.** Every sealed-column count this row prints is
/// therefore a LOWER bound on unopenable values, permanently — a genuine loss of resolution, and one
/// that no future sitting can buy back.
///
/// Not localized, like the rest of the debug tab (the house statement is at
/// CryptoFormatCensus.swift:64-65).
nonisolated enum Phase3Gate: String, Sendable, CaseIterable, Identifiable {
    /// `FernletCrypto/ColumnCrypto` — the four sealed Core Data corpora.
    case sealedColumns
    /// `PrivateStoreCore/PendingNarrativeBuffer` — the locked-state note file.
    case pendingNarrativeBuffer
    /// `PrivateMediaStore/MediaAtRestCrypto` — the three-part gate (latch + residues + blind spots).
    case mediaAtRest
    /// `FernletLock/FernletLockService` — the one scrypt-wrapped content key.
    case lockContentKeyWrap
    /// `ProximityKit/HeartSharing/HeartDropSidecarKey` — the per-row sidecar gate.
    case heartDropSidecars
    /// `App/Fernlet/SealedPhotoBackupService` — `minimumEntryHashVersion >= 2` per corpus.
    case sealedPhotoBackup

    var id: String { rawValue }

    /// The gate's heading.
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

    /// The plan's own wording for this surface's gate, quoted rather than paraphrased
    /// (Docs/Plan-Crypto-Standardization-2026-08-27.md §Phase 3, plus §4's sealed-photo exception)
    /// — except on the three surfaces whose reader the plan has already deleted, where the wording
    /// is rewritten to the smaller claim the row can still make. See the type doc.
    var gateWording: String {
        switch self {
        case .sealedColumns:
            return "THE READER IS ALREADY GONE: ColumnCrypto opens V3 only, and the keyed migrator"
                + " that was this gate's second witness went with it. This row licenses no deletion"
                + " — it reports how many stored journal / cycle / intimacy / worry column values"
                + " this build can no longer open. census unprefixed == 0 discharges; any non-zero"
                + " count is that many unopenable rows, and it is a LOWER bound forever: the keyed"
                + " pass that resolved the collided ~1-in-256 marker sliver no longer exists, so"
                + " nothing can tell a marked blob from a collided legacy one. A zero over a corpus"
                + " that holds no sealed values still says nothing about either."
        case .pendingNarrativeBuffer:
            return "census legacyCount == 0; an unreadable buffer is not a zero."
        case .mediaAtRest:
            return "the latch set on a real upgraded device, AND the census's unprefixed count equal"
                + " to that device's audited named residues, AND hasBlindSpots false. A latch alone"
                + " does not discharge it, and neither does a raw census number without the residue"
                + " audit beside it."
        case .lockContentKeyWrap:
            return "THE READER IS ALREADY GONE: FernletLockService unwraps the marked format only,"
                + " and the derived row latch that used to be printed beside this row went with the"
                + " migrator it belonged to. This row licenses no deletion — it reports whether the"
                + " one stored content-key wrap is one this build can still open. The census reading"
                + " 0 discharges, either as a v2Marked row or as an absent row with an EARNED"
                + " reading; a legacy wrap means the app-lock content key is unrecoverable on this"
                + " device. malformedEmpty and unreadable are not zeros."
        case .heartDropSidecars:
            return "THE READER IS ALREADY GONE: the sidecar opener reads the sealed format only, and"
                + " the completion latch that used to be printed beside this row went with the"
                + " migrator. This row licenses no deletion — it reports how many stored sidecars"
                + " this build can no longer open. Zero legacySealed on the three MAIN rows (outbox,"
                + " peer bundles, dedup) discharges; a legacy row is an outbox, peer-bundle or dedup"
                + " file whose contents are now lost to this build. outboxQuarantine is EXCLUDED: no"
                + " reader ever opens the quarantine path."
        case .sealedPhotoBackup:
            return "minimumEntryHashVersion >= 2 across the three corpora, read from the manifests"
                + " at gate time after a full-verification pass. An EMPTY manifest reads 2"
                + " vacuously and does not discharge; == 1 means NOT PROVEN, never 'legacy found'."
        }
    }
}

// MARK: - Witness kinds

/// What KIND of evidence a row folded.
///
/// This is the field `CryptoFormatCensusRow` does not have, and the reason this type exists: the six
/// gates differ in the kind of evidence available to them — a keyless marker count, a persisted
/// completion bit, a converting media pass, a network manifest read — and a row that does not say
/// which kind it rests on will be misread as all of them.
///
/// Two kinds have been retired rather than kept as unreachable cases. `keyedMigratorPass` named a
/// `SealedColumnFormatMigrator` run, and `derivedRowLatch` named the lock-wrap row latch; both types
/// were deleted with the legacy readers they served, so no row can ever fold either kind again. A
/// case nothing can produce is not documentation of a lost capability — it is a label a future
/// caller could attach to evidence it never took. The loss itself is recorded where it belongs, in
/// ``Phase3Gate``'s type doc and in the affected gates' own wording.
nonisolated enum Phase3GateWitness: String, Sendable, CaseIterable {
    /// The keyless marker-bytes census — exact for unprefixed, an upper bound for marked blobs.
    case markerCensus
    /// A persisted `FormatMigrationLatching` completion bit.
    case completionLatch
    /// A `MediaAtRestFormatMigrator.performPass()` result, taken without touching the latch.
    case mediaMigratorPass
    /// A sealed-photo manifest fetched from iCloud and opened — counts and version integers only.
    case manifestProbe
    /// A read-only CloudKit id enumeration for a corpus whose manifest did not come back.
    case bodyProbe

    /// The witness kind's name on the row.
    var displayName: String {
        switch self {
        case .markerCensus: return "marker census (keyless)"
        case .completionLatch: return "completion latch"
        case .mediaMigratorPass: return "media migrator pass"
        case .manifestProbe: return "iCloud manifest probe"
        case .bodyProbe: return "iCloud body-record probe"
        }
    }

    /// What taking this witness COSTS — printed beside the kind, so a reader can tell a free local
    /// read from a network fetch or a pass that writes.
    var riskNote: String {
        switch self {
        case .markerCensus: return "free; reads at most four header bytes per blob, writes nothing"
        case .completionLatch: return "free; one UserDefaults read"
        case .mediaMigratorPass: return "converts anything convertible; never touches the latch"
        case .manifestProbe: return "network fetch plus one AES-GCM open per corpus; no writes"
        case .bodyProbe: return "network query for record ids only; no assets, no writes"
        }
    }
}

// MARK: - Verdicts

/// One gate's verdict — five kinds, because collapsing any two of them licenses a different Phase 3
/// decision than the evidence supports.
///
/// ## The invariant, inherited from ``CryptoFormatCensusRow``
///
/// **Nothing `nil` ever renders as discharged.** ``discharged`` is reachable only when EVERY clause
/// of the gate's wording was affirmatively observed. A clause nobody took is ``notTaken``; a clause
/// taken that could not answer is ``unavailable``; a clause taken that answered against the gate is
/// ``blocked``.
///
/// ``vacuous`` is the fifth kind and it is not a softer ``discharged``. It records that the gate's
/// wording is satisfied because there is nothing for it to be about — an empty manifest carries no
/// entry that could hold a legacy digest; a device that never committed an escrow route has no
/// manifest to read. That is a TRUE statement and a strictly weaker one than the gate's, so the
/// Phase 3 record has to say which one it rests on rather than inferring it.
///
/// There is deliberately **no `allGatesDischarged` Bool and no whole-device rollup**, for the reason
/// ``CryptoFormatCensusReport`` refuses a whole-device total: the six gates differ in kind and unit,
/// and any summary would have to do something with the ones nobody took.
nonisolated enum Phase3GateVerdict: Sendable, Equatable {
    /// Every clause of the gate's wording was affirmatively observed.
    case discharged
    /// The wording is satisfied because there is nothing for it to be about. Carries the reason.
    case vacuous(String)
    /// A clause was observed and it answers against the gate. Carries what blocked it.
    case blocked(String)
    /// A clause nobody took this sitting. Carries what is missing and how to buy it.
    case notTaken(String)
    /// A clause taken that could not answer. Carries the cause — never a zero, never "corrupt".
    case unavailable(String)

    /// The verdict's heading word.
    var displayName: String {
        switch self {
        case .discharged: return "DISCHARGED"
        case .vacuous: return "VACUOUS"
        case .blocked: return "BLOCKED"
        case .notTaken: return "NOT TAKEN"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    /// The reason, or nil for ``discharged``.
    var reason: String? {
        switch self {
        case .discharged: return nil
        case let .vacuous(reason), let .blocked(reason), let .notTaken(reason), let .unavailable(reason):
            return reason
        }
    }
}

// MARK: - Rows

/// One gate's line in the readout: which witnesses it folded, the stamps of the observations it
/// folded, its verdict, and the evidence and caveats exactly as the screen renders them.
nonisolated struct Phase3GateRow: Sendable, Equatable, Identifiable {
    /// Which gate this row is about.
    let gate: Phase3Gate
    /// The kinds of evidence folded — never empty, so a reader can always tell what the row rests on.
    let witnesses: [Phase3GateWitness]
    /// The stamps of the observations folded, in acquisition order.
    let stamps: [Phase3Stamp]
    /// The verdict. See ``Phase3GateVerdict``.
    let verdict: Phase3GateVerdict
    /// The numbers and states, one short line each.
    let evidence: [String]
    /// What the evidence is worth, and what it cannot say.
    let caveats: [String]

    var id: String { gate.rawValue }

    /// Whether this row discharged its gate.
    var isDischarged: Bool { verdict == .discharged }
}

// MARK: - Environment

/// The device and preference context that decides whether the sitting is valid at all.
///
/// Every member is read on the main actor from an accessor that already exists; none of them is the
/// gate, and the row copy says so. The one deliberately WEAK member is
/// ``hasEmbeddedProvisioningProfile``: the entitlement API that would have answered "which CloudKit
/// database does this build talk to" is macOS-only (`SecTaskCreateFromSelf` ships in `MacOSX.sdk`
/// and has no iOS spelling), so the environment question is carried by a permanent caveat on every
/// sealed-photo row, the body-record probe, and an owner checklist line instead of an invented value.
nonisolated struct Phase3GateEnvironment: Sendable, Equatable {
    /// `StoragePreferences.sealedBackupOwnPhotosEnabled` — the same nonisolated static
    /// `OwnPhotoBackupCoordinator` gates on.
    let sealedBackupOwnPhotosEnabled: Bool
    /// `OwnPhotoEscrowCommitLedger().isCommitted` — the COMMIT PROOF, not the preference. This is
    /// what turns "no manifest came back" into a vacuous satisfaction rather than a blocking fact.
    let escrowRouteCommitted: Bool
    /// Whether `FERNLET_SKIP_SEALED_RESTORE=1` is set. The DEBUG guard fronts the UPLOAD path, so a
    /// sitting taken with it set would silently no-op the sealed-photo pass.
    let skipSealedRestoreEnvSet: Bool
    /// `FernletLockService.isLockConfigured` — the property that collapses the wrap row's three-way
    /// absence to two.
    let lockConfigured: Bool
    /// Whether the private hub is unlocked right now.
    let privateHubUnlocked: Bool
    /// Whether a duress session is active. The whole page refuses to render when it is.
    let duressSessionActive: Bool
    /// Whether an own-photo backup pass is running. Fetching mid-pass returns a torn reading.
    let ownPhotoBackupPassInFlight: Bool
    /// When the last own-photo full-verification pass finished, or nil for "none this process".
    let lastFullPassCompletedAt: Date?
    /// Whether an `embedded.mobileprovision` is present — a WEAK install-channel signal, labelled as
    /// such. It does not say which CloudKit database this build reads.
    let hasEmbeddedProvisioningProfile: Bool
    /// `ProcessInfo.processInfo.operatingSystemVersionString`.
    let systemVersion: String
    /// The device model identifier.
    let deviceModel: String

    /// Creates an environment reading.
    init(
        sealedBackupOwnPhotosEnabled: Bool,
        escrowRouteCommitted: Bool,
        skipSealedRestoreEnvSet: Bool,
        lockConfigured: Bool,
        privateHubUnlocked: Bool,
        duressSessionActive: Bool,
        ownPhotoBackupPassInFlight: Bool,
        lastFullPassCompletedAt: Date?,
        hasEmbeddedProvisioningProfile: Bool,
        systemVersion: String,
        deviceModel: String
    ) {
        self.sealedBackupOwnPhotosEnabled = sealedBackupOwnPhotosEnabled
        self.escrowRouteCommitted = escrowRouteCommitted
        self.skipSealedRestoreEnvSet = skipSealedRestoreEnvSet
        self.lockConfigured = lockConfigured
        self.privateHubUnlocked = privateHubUnlocked
        self.duressSessionActive = duressSessionActive
        self.ownPhotoBackupPassInFlight = ownPhotoBackupPassInFlight
        self.lastFullPassCompletedAt = lastFullPassCompletedAt
        self.hasEmbeddedProvisioningProfile = hasEmbeddedProvisioningProfile
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
    }

    /// The PERMANENT caveat that replaces the deleted entitlement reader. It rides every
    /// sealed-photo row because it is the one way that surface produces a false gate failure.
    static let cloudKitDatabaseCaveat =
        "A Debug build signed from Xcode reads the DEVELOPMENT CloudKit database. Manifests written"
        + " by a TestFlight build live in Production and read here as ABSENT — a false gate failure,"
        + " never a pass. Nothing in the app can read which database this build talks to; the"
        + " entitlement API that would answer is macOS-only."
}

// MARK: - Sealed-photo readings

/// One corpus's sealed-photo manifest reading. **Never an `Int?`** — the three ways a naive
/// rendering manufactures a pass each get their own case.
///
/// - An EMPTY manifest legitimately computes `minimumEntryHashVersion == 2`
///   (CloudKitSync/SealedPhotoRecord.swift, "no entries, vacuously no legacy digest"). That is not a
///   proof, so it is ``vacuousEmptyManifest`` and never ``proven``.
/// - A nil return means "no manifest RECORD came back", not "no manifest exists": `records(for:)`
///   appends only `.success` results. That is ``noManifestReturned``.
/// - `SealedBackupError.malformedRecord` covers several distinct causes including a TRANSIENT
///   unreadable `CKAsset`, so a throw is ``unreadable`` carrying its cause — never "corrupt".
///
/// And `minimum == 1` means legacy **or unproven**, so the row prints "not proven", never "legacy
/// entries found".
nonisolated enum SealedPhotoManifestReading: Sendable, Equatable {
    /// A manifest with at least one entry came back and opened.
    case proven(minimum: Int, entryCount: Int, unprovenEntries: Int, generation: Int64, deviceHighWater: Int64)
    /// A manifest came back and opened, and it holds no entries at all.
    case vacuousEmptyManifest(generation: Int64, deviceHighWater: Int64)
    /// No manifest record came back. Not the same as "no manifest exists".
    case noManifestReturned
    /// The fetch or the open threw. Carries the cause verbatim.
    case unreadable(String)
}

/// What a read-only CloudKit body-record probe found for one corpus.
///
/// A three-case enum rather than `Int?` inside a dictionary: `[SealedPhotoCorpus: Int?]` yields
/// `Int??` at every lookup and collides "not probed" with "probed, and there are zero bodies" — and
/// zero bodies is load-bearing, because it is what turns ``SealedPhotoManifestReading/noManifestReturned``
/// into a vacuous satisfaction rather than a blocking fact.
nonisolated enum BodyProbeReading: Sendable, Equatable {
    /// Nobody asked. The common case, and it costs nothing.
    case notProbed
    /// The probe ran.
    ///
    /// - Note: `truncatedAtPageCap` is the typed home for the fact, but the shipping transport
    ///   cannot supply it: `CloudKitDataService.existingSealedPhotoIDs(corpus:)` returns a `Set<UUID>`
    ///   and follows the cursor chain up to a PRIVATE page cap without reporting having reached it.
    ///   The readout's own probe therefore always passes `false` and the row prints every count as a
    ///   LOWER bound regardless — which is the honest reading, and strictly safer than a flag that
    ///   would read "not truncated" for a count that was.
    case counted(Int, truncatedAtPageCap: Bool)
    /// The probe threw. Carries the cause; never rendered as a zero.
    case failed(String)
}

/// One manifest probe: three corpus readings taken together, with the stamp they were taken at.
///
/// Probes are KEPT rather than overwritten. The sitting takes one before Privacy & Data → Retry and
/// one after, and Retry forces `generation` and `deviceHighWater` into agreement — so the second
/// reading structurally cannot show the stale-manifest disagreement the first exists to capture.
nonisolated struct Phase3ManifestProbe: Sendable, Equatable, Identifiable {
    /// When this probe landed.
    let stamp: Phase3Stamp
    /// One reading per corpus. A corpus missing from the dictionary was not probed.
    let readings: [SealedPhotoCorpus: SealedPhotoManifestReading]

    var id: String { stamp.printed }

    /// Creates a probe record.
    init(stamp: Phase3Stamp, readings: [SealedPhotoCorpus: SealedPhotoManifestReading]) {
        self.stamp = stamp
        self.readings = readings
    }
}

// MARK: - Migrator witnesses

/// What one media at-rest pass produced.
///
/// This type is the whole answer to the media gate's two blind spots. `FormatMigrator.run(maxPasses:)`
/// opens `if latch.isComplete { return true }`, so a latched device — exactly the device the gate is
/// read from — never runs another pass through the shipped path and therefore produces no residue
/// evidence at all. ``MediaAtRestFormatMigrator/performPass()`` produces the result WITHOUT touching
/// the latch (`markComplete()` is reached only from `run(maxPasses:)`), which is what makes
/// `unopenableUnprefixed` — the plan's own named residue — available on demand.
///
/// It also turns a bare `latch == false` into a legible three-way state: a pass running now, a pass
/// observed and blocked on named buckets, or no pass observed this process.
nonisolated struct MediaPassWitness: Sendable, Equatable {
    /// When the pass finished.
    let stamp: Phase3Stamp
    /// The pass tally, including `unopenableUnprefixed` and `examined`.
    let result: MediaAtRestFormatMigrationResult
    /// The latch before the pass — captured so a stale latch is visible as a change, not inferred.
    let latchBefore: Bool
    /// The latch after. `performPass()` cannot move it, and the readout runs nothing that can, so
    /// this is an ASSERTION rather than a report: see ``latchMoved``.
    let latchAfter: Bool

    /// Creates a witness.
    init(
        stamp: Phase3Stamp,
        result: MediaAtRestFormatMigrationResult,
        latchBefore: Bool,
        latchAfter: Bool
    ) {
        self.stamp = stamp
        self.result = result
        self.latchBefore = latchBefore
        self.latchAfter = latchAfter
    }

    /// Whether the latch moved across the pass — which it must NEVER do.
    ///
    /// The media latch IS gate part (a), and this instrument is forbidden to set it or clear it: a
    /// latch this page minted from the foreground is a gate the sitting awarded itself, and would
    /// read next launch exactly like one a shipped pass earned. `performPass()` is documented never
    /// to reach `markComplete()`, so a `true` here means that contract broke and the media row
    /// refuses to answer rather than quoting a latch it may have moved.
    var latchMoved: Bool { latchBefore != latchAfter }

    /// The blocking buckets this pass hit, by name. Empty for a clean pass.
    var blockingBuckets: [String] {
        var named: [String] = []
        if result.convertedPlaintext > 0 { named.append("convertedPlaintext \(result.convertedPlaintext)") }
        if result.conversionFailures > 0 { named.append("conversionFailures \(result.conversionFailures)") }
        if result.indeterminate > 0 { named.append("indeterminate \(result.indeterminate)") }
        if result.skippedConcurrentlyModified > 0 {
            named.append("skippedConcurrentlyModified \(result.skippedConcurrentlyModified)")
        }
        if result.abortedNoOwnKey { named.append("abortedNoOwnKey") }
        if result.abortedNoWallKey { named.append("abortedNoWallKey") }
        return named
    }
}

/// What the LAUNCH media pass returned, and when.
///
/// Retained because "no pass has been observed this process" is a claim, and on a device whose
/// launch pass ran and did not latch it is a false one — the record sits on `FernletStore` while the
/// row denies it. `run(maxPasses:)` returns the latch state rather than a tally, so this carries the
/// three-way legibility signal ("a pass ran at <t> and did not latch") and nothing else; the residue
/// numbers are still bought separately with `performPass()`.
nonisolated struct MediaLaunchPassRecord: Sendable, Equatable {
    /// What `run()` returned — whether the launch pass left the latch set.
    let latched: Bool
    /// When it finished.
    let completedAt: Date

    /// Creates a launch-pass record.
    init(latched: Bool, completedAt: Date) {
        self.latched = latched
        self.completedAt = completedAt
    }

    /// The record as the row prints it.
    var printed: String {
        "the launch pass at \(completedAt.ISO8601Format()) ran and returned latched \(latched)"
    }
}

/// A caught error reduced to a BOUNDED classification, because the raw description is the report's
/// only free-text payload and the report is designed to be copied off the device.
///
/// `String(describing:)` of a `CKError` renders its `userInfo`, which for a multi-record operation
/// carries a per-item dictionary keyed by `CKRecord.ID` — and this scheme's sealed-photo record
/// names are built from photo UUIDs. Domain and code cannot carry an identifier; the raw description
/// can, and the redaction contract is stated in ``Phase3GateReportBuilder``.
nonisolated enum Phase3ProbeFailure {
    /// The error as the readout is allowed to retain it: the Swift type, the bridged domain, and the
    /// code. Never `userInfo`, never `localizedDescription`, never the raw description.
    static func summarize(_ error: Error) -> String {
        let bridged = error as NSError
        return "\(type(of: error)) (domain \(bridged.domain), code \(bridged.code))"
    }
}

// MARK: - Latches

/// The three surviving completion bits, taken in one place with one stamp.
///
/// Every bit goes through an accessor that already exists, so no FernletKit module gains a new
/// public surface for this instrument. ``mediaAtRest`` in particular is rendered NOWHERE else in the
/// app — the app never constructs `MediaAtRestFormatMigrationLatch` outside
/// `MediaAtRestFormatMigrator.standard` — and reading it here is what closes the audit's blocker
/// that otherwise needs LLDB and a downloaded app container.
///
/// It used to carry six. Three went with the migrators that owned them when Phase 3 deleted their
/// legacy readers: `SealedColumnMigrationLatch`, `HeartDropSidecarMigrationLatch`, and the derived
/// `LockWrapRowLatch`. Only the last of those was ever an ornament — it re-read the census's own
/// keychain byte and licensed nothing — while the other two recorded a conversion that no longer has
/// anywhere to happen. None of the three is reconstructible here, and a bit invented from the census
/// beside it would be the "quoting the gate to itself" failure the lock-wrap latch was already
/// criticised for, so the three rows that lost them read from the census alone and say so.
///
/// What remains needs no keychain read at all, which is why ``take(defaults:)`` no longer takes the
/// census `Inputs`: the one reader that needed the shared keychain-service spelling is gone.
///
/// There is no `printedLines` any more either. The three bits used to be printed together in one
/// export section, and that section existed for exactly one reason — to preserve the six-bit reading
/// this page destroyed when the owner cleared the sealed-column latch. No control here writes a
/// latch now, so nothing is destroyed and there is nothing to preserve; each surviving bit reaches
/// the export through the row that actually folds it, under that row's own framing.
nonisolated struct Phase3LatchReadings: Sendable, Equatable {
    /// `MediaAtRestFormatMigrationLatch.isComplete` — gate part (a) for the media surface.
    let mediaAtRest: Bool
    /// `OwnPhotoMigrationLatch.isComplete` — an INPUT to the media gate, never a gate of its own.
    let ownPhotoKey: Bool
    /// `SealedPhotoBackupMigrationLatch.isComplete` — explicitly NOT the sealed-photo gate.
    let sealedPhotoBackup: Bool

    /// Creates a latch reading.
    init(
        mediaAtRest: Bool,
        ownPhotoKey: Bool,
        sealedPhotoBackup: Bool
    ) {
        self.mediaAtRest = mediaAtRest
        self.ownPhotoKey = ownPhotoKey
        self.sealedPhotoBackup = sealedPhotoBackup
    }

    /// Takes all three bits.
    ///
    /// Blocking: three `UserDefaults` reads, no keychain and no disk. Call it off the main actor
    /// beside the census scan anyway — it is cheap, and taking it there keeps the latch stamp beside
    /// the census stamp rather than an actor hop away from it.
    static func take(defaults: UserDefaults = .standard) -> Phase3LatchReadings {
        Phase3LatchReadings(
            // Read through the latch TYPE rather than through `Migrator.latch(defaults:)`: this
            // reading is taken off the main actor beside the census scan, and that accessor is
            // `@MainActor` (its migrator is), so the bit would otherwise cost an actor hop for a
            // `UserDefaults` read.
            mediaAtRest: MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete,
            ownPhotoKey: OwnPhotoKeyMigrator.latch(defaults: defaults).isComplete,
            sealedPhotoBackup: SealedPhotoBackupMigrationLatch(defaults: defaults).isComplete
        )
    }

}

// MARK: - The readout

/// Everything the fold needs, as one `Sendable` value.
///
/// A separate input type rather than the `@MainActor @Observable` session itself, so the fold stays
/// a pure function the tests can drive with hand-built fixtures and no store. The session's
/// ``Phase3ReadoutSession/inputs(environment:ownPhotoDocumentsDirectory:friendWallSupportDirectory:mediaLaunchPass:sealedPhotoFullPassVerdicts:)``
/// is the one production spelling.
nonisolated struct Phase3GateReadoutInputs: Sendable {
    /// The device and preference context.
    var environment: Phase3GateEnvironment
    /// Own-photo root — used ONLY to label swept media locations, never retained or printed.
    var ownPhotoDocumentsDirectory: URL
    /// Friend-wall root — same rule.
    var friendWallSupportDirectory: URL
    /// The marker-bytes census readings, or nil when the local scan has not landed.
    var census: CryptoFormatCensus.Readings?
    /// When the census landed.
    var censusStamp: Phase3Stamp?
    /// The three latch bits, or nil when the local scan has not landed.
    var latches: Phase3LatchReadings?
    /// When the latches were read.
    var latchStamp: Phase3Stamp?
    /// Every manifest probe taken this sitting, in acquisition order.
    var manifestProbes: [Phase3ManifestProbe]
    /// Body-record probes, by corpus.
    var bodyProbes: [SealedPhotoCorpus: BodyProbeReading]
    /// The retained media pass, or nil when none was funded this process.
    var mediaWitness: MediaPassWitness?
    /// Whether a media pass is running right now.
    var mediaPassInFlight: Bool
    /// What the LAUNCH media pass returned, so a `latch == false` with no funded witness never
    /// renders as "no pass has been observed this process" while the launch record stands.
    var mediaLaunchPass: MediaLaunchPassRecord?
    /// The last own-photo full-verification pass's per-corpus verdicts — a BY-PRODUCT of a writing
    /// pass, never the gate. Its `examined` bit is the "never looked / examined-none" fact a live
    /// probe structurally cannot produce.
    var sealedPhotoFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]?
    /// The sitting checklist with its derived done-states.
    var checklist: [Phase3SittingStep]
    /// Refusals recorded this sitting (a disabled control the owner pressed, a probe that declined).
    var refusals: [String]

    /// Creates an input set. Every optional defaults to "not taken", so a caller can build the
    /// minimum honest readout without spelling out absences.
    init(
        environment: Phase3GateEnvironment,
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL,
        census: CryptoFormatCensus.Readings? = nil,
        censusStamp: Phase3Stamp? = nil,
        latches: Phase3LatchReadings? = nil,
        latchStamp: Phase3Stamp? = nil,
        manifestProbes: [Phase3ManifestProbe] = [],
        bodyProbes: [SealedPhotoCorpus: BodyProbeReading] = [:],
        mediaWitness: MediaPassWitness? = nil,
        mediaPassInFlight: Bool = false,
        mediaLaunchPass: MediaLaunchPassRecord? = nil,
        sealedPhotoFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]? = nil,
        checklist: [Phase3SittingStep] = [],
        refusals: [String] = []
    ) {
        self.environment = environment
        self.ownPhotoDocumentsDirectory = ownPhotoDocumentsDirectory
        self.friendWallSupportDirectory = friendWallSupportDirectory
        self.census = census
        self.censusStamp = censusStamp
        self.latches = latches
        self.latchStamp = latchStamp
        self.manifestProbes = manifestProbes
        self.bodyProbes = bodyProbes
        self.mediaWitness = mediaWitness
        self.mediaPassInFlight = mediaPassInFlight
        self.mediaLaunchPass = mediaLaunchPass
        self.sealedPhotoFullPassVerdicts = sealedPhotoFullPassVerdicts
        self.checklist = checklist
        self.refusals = refusals
    }
}

/// One sitting's whole reading: every stamp taken, the environment, and six gate rows.
///
/// There is no single `takenAt` — see ``Phase3Stamp``.
///
/// It used to carry a pre-reset latch snapshot too. That existed to preserve the one reading this
/// page could destroy — the sealed-column completion latch, which the page offered a control to
/// clear so the next hub unlock would fund a fresh keyed pass. The latch, the migrator and the
/// control are all gone, so nothing in this sitting writes a latch at all and there is no
/// destroyed reading left to rescue. Keeping the field would have left a report section that no
/// code path can ever fill.
nonisolated struct Phase3GateReadout: Sendable, Equatable {
    /// Every stamp taken this sitting, in acquisition order.
    let stamps: [Phase3Stamp]
    /// The device and preference context.
    let environment: Phase3GateEnvironment
    /// One row per gate, in ``Phase3Gate/allCases`` order.
    let rows: [Phase3GateRow]
    /// The sitting checklist with its derived done-states.
    let checklist: [Phase3SittingStep]
    /// Refusals recorded this sitting.
    let refusals: [String]
    /// The media residue audit, when a census reading was in hand to fold. Rendered in full on the
    /// media row and printed line by line in the export.
    let mediaAudit: MediaResidueAudit?
    /// Every manifest probe, kept rather than overwritten.
    let manifestProbes: [Phase3ManifestProbe]

    /// Creates a readout.
    init(
        stamps: [Phase3Stamp],
        environment: Phase3GateEnvironment,
        rows: [Phase3GateRow],
        checklist: [Phase3SittingStep],
        refusals: [String],
        mediaAudit: MediaResidueAudit?,
        manifestProbes: [Phase3ManifestProbe]
    ) {
        self.stamps = stamps
        self.environment = environment
        self.rows = rows
        self.checklist = checklist
        self.refusals = refusals
        self.mediaAudit = mediaAudit
        self.manifestProbes = manifestProbes
    }

    /// Whether every gate produced a row — the structural check, deliberately NOT "every gate
    /// discharged".
    var allGatesReported: Bool { Set(rows.map(\.gate)) == Set(Phase3Gate.allCases) }

    /// The rows that did not discharge, grouped by verdict kind. The export's trailer names all
    /// four groups, because a skimmed report that listed only the not-taken ones would read as
    /// complete while a row that answered BLOCKING appeared only in the body.
    var rowsNotDischarged: [(kind: String, rows: [Phase3GateRow])] {
        let kinds = ["BLOCKED", "UNAVAILABLE", "VACUOUS", "NOT TAKEN"]
        return kinds.compactMap { kind in
            let matching = rows.filter { !$0.isDischarged && $0.verdict.displayName == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }
}

// MARK: - The fold

/// The pure fold from readings, latches and witnesses to six gate rows.
///
/// One static per gate, each with its string assembly split into small private helpers — the model
/// is `CryptoFormatCensus.row(forMedia:)` + `mediaStatus(_:)`. Nothing here reads the filesystem,
/// the keychain or the network: every value it folds was purchased by somebody else and stamped.
nonisolated enum Phase3GateReadoutBuilder {

    /// Folds one input set into the whole readout: six rows in ``Phase3Gate/allCases`` order.
    ///
    /// When the local scan has not landed, EVERY row says so rather than folding an all-false latch
    /// reading as evidence — an unread latch is not a cleared latch.
    static func readout(from inputs: Phase3GateReadoutInputs) -> Phase3GateReadout {
        guard !inputs.environment.duressSessionActive else { return duressRefusal(inputs.environment) }
        let audit = mediaAudit(from: inputs)
        return Phase3GateReadout(
            stamps: stamps(from: inputs),
            environment: inputs.environment,
            rows: rows(from: inputs, audit: audit),
            checklist: inputs.checklist,
            refusals: inputs.refusals,
            mediaAudit: audit,
            manifestProbes: inputs.manifestProbes
        )
    }

    /// The whole readout under a duress session: six refusals, no stamps, no probes, no audit.
    ///
    /// Enforced HERE, in the pure layer, and not only by the view's `if store.duressSessionActive`.
    /// The model already carries the flag, and a refactor of the view's `@ViewBuilder` — merging the
    /// sections, moving the guard into a subview, wrapping it in a `Group` (a documented trap in
    /// this codebase) — would otherwise let the fold and BOTH export routes assemble real per-corpus
    /// photo counts and real decrypted manifest minima under a decoy session with the suite green.
    static func duressRefusal(_ environment: Phase3GateEnvironment) -> Phase3GateReadout {
        let reason = "a duress session is active. This surface reads and decrypts real backup"
            + " manifests and prints per-corpus counts, which is exactly what this session must not"
            + " disclose — so nothing is folded, and no reading is carried into either export route."
        return Phase3GateReadout(
            stamps: [],
            environment: environment,
            rows: Phase3Gate.allCases.map { notTakenRow($0, reason: reason) },
            checklist: [],
            refusals: [],
            mediaAudit: nil,
            manifestProbes: []
        )
    }

    /// The media residue audit, or nil when neither a census nor a latch reading is in hand.
    private static func mediaAudit(from inputs: Phase3GateReadoutInputs) -> MediaResidueAudit? {
        guard let census = inputs.census, let latches = inputs.latches else { return nil }
        return MediaResidueAudit.take(
            report: census.media,
            ownPhotoDocumentsDirectory: inputs.ownPhotoDocumentsDirectory,
            friendWallSupportDirectory: inputs.friendWallSupportDirectory,
            latches: latches,
            witness: inputs.mediaWitness
        )
    }

    /// Every stamp taken this sitting, in acquisition order.
    private static func stamps(from inputs: Phase3GateReadoutInputs) -> [Phase3Stamp] {
        var taken: [Phase3Stamp] = []
        if let stamp = inputs.censusStamp { taken.append(stamp) }
        if let stamp = inputs.latchStamp { taken.append(stamp) }
        // R2: bounded by the probe cap `Phase3ReadoutSession` enforces.
        for probe in inputs.manifestProbes { taken.append(probe.stamp) }
        if let witness = inputs.mediaWitness { taken.append(witness.stamp) }
        return taken.sorted { $0.takenAt < $1.takenAt }
    }

    /// The six rows, or six honest refusals when the local scan has not landed.
    private static func rows(
        from inputs: Phase3GateReadoutInputs,
        audit: MediaResidueAudit?
    ) -> [Phase3GateRow] {
        guard let census = inputs.census, let latches = inputs.latches else {
            let reason = "the local scan has not landed, so no census reading and no latch bit has"
                + " been taken this process. An unread latch is not a cleared latch."
            return Phase3Gate.allCases.map { notTakenRow($0, reason: reason) }
        }
        return [
            row(forSealedColumns: census.sealedColumns, stamp: inputs.censusStamp),
            row(forPendingNarrative: census.pendingNarrative, stamp: inputs.censusStamp),
            row(forMedia: audit, latches: latches, witness: inputs.mediaWitness,
                passInFlight: inputs.mediaPassInFlight, censusStamp: inputs.censusStamp,
                launchPass: inputs.mediaLaunchPass),
            row(forLockWrap: census.lockWrap,
                lockConfigured: inputs.environment.lockConfigured, stamp: inputs.censusStamp),
            row(forHeartDrop: census.heartDrop, stamp: inputs.censusStamp),
            row(forSealedPhoto: inputs.manifestProbes.last, bodyProbes: inputs.bodyProbes,
                latch: latches.sealedPhotoBackup, environment: inputs.environment,
                fullPassVerdicts: inputs.sealedPhotoFullPassVerdicts)
        ]
    }

    /// A row that took nothing — the shape every gate falls back to before the scan lands.
    static func notTakenRow(_ gate: Phase3Gate, reason: String) -> Phase3GateRow {
        Phase3GateRow(
            gate: gate,
            witnesses: [.markerCensus, .completionLatch],
            stamps: [],
            verdict: .notTaken(reason),
            evidence: [],
            caveats: []
        )
    }

    // MARK: Sealed columns

    /// The sealed-column row, which no longer gates anything and says so.
    ///
    /// It used to fold two witnesses: the keyless marker census, and a FRESH keyed
    /// `SealedColumnFormatMigrator` pass run after a latch reset the owner took here. That second
    /// witness existed to resolve the collided ~1-in-256 marker sliver, and it is gone — the
    /// migrator was deleted along with `ColumnCrypto`'s legacy read rung, which is the very deletion
    /// this row was read to license. Nothing is left to fund, nothing is left to reset, and there is
    /// no ordering left to check, so the row keeps the one reading it can still take honestly.
    ///
    /// The count it prints has changed MEANING rather than importance. Before the delete a non-zero
    /// `unprefixed` meant "not converted yet"; now it means "this many stored values no reader in
    /// this build can open", and no pass exists that could convert them. That is a worse finding
    /// than the one this row used to report, so it still `blocked`s.
    static func row(
        forSealedColumns outcome: CryptoFormatCensus.SealedColumnOutcome,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .sealedColumns,
            witnesses: [.markerCensus],
            stamps: stamp.map { [$0] } ?? [],
            verdict: sealedColumnVerdict(outcome),
            evidence: sealedColumnEvidence(outcome),
            caveats: sealedColumnCaveats(outcome)
        )
    }

    private static func sealedColumnVerdict(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome
    ) -> Phase3GateVerdict {
        guard case let .counted(result) = outcome else {
            guard case let .failed(reason) = outcome else { return .notTaken("no census reading") }
            return .unavailable("the sealed store could not be censused: \(reason). This is not a zero.")
        }
        let unprefixed = result.total.unprefixed
        guard unprefixed == 0 else {
            return .blocked("\(unprefixed) stored column values carry no format marker, and no"
                + " reader in this build can open them — ColumnCrypto reads V3 only, and the"
                + " migrator that could have converted them was deleted with the legacy rung. This"
                + " is a count of unreadable journal / cycle / intimacy / worry text, not a"
                + " conversion backlog.")
        }
        guard !result.truncated else {
            return .unavailable("the marker census stopped at its \(result.rowCap)-row cap after"
                + " \(result.rowsScanned) of \(result.rowsAvailable) rows, so its zero describes a"
                + " SUBSET of the corpus and says nothing about the rows it never reached.")
        }
        return emptyCorpusRefusal(result) ?? .discharged
    }

    /// The `.vacuous` branch: the reading is trivially satisfied over a corpus that holds nothing.
    ///
    /// The census's tally is empty, so `unprefixed == 0` — and a zero over no bytes is not a
    /// statement about bytes. `emptyOrNil` is counted separately from `unprefixed`, so a store with
    /// rows whose sealed columns are all nil reads a healthy non-zero row count and is the variant a
    /// bare `rowsAvailable > 0` floor misses.
    private static func emptyCorpusRefusal(_ result: SealedColumnFormatCensusResult) -> Phase3GateVerdict? {
        let classified = result.total
        let sealedValues = classified.total - classified.emptyOrNil
        if let perColumn = uncoveredColumnRefusal(result), result.rowsAvailable > 0, sealedValues > 0 {
            return perColumn
        }
        guard result.rowsAvailable == 0 || sealedValues == 0 else { return nil }
        return .vacuous("the sealed corpora hold \(result.rowsAvailable) rows and \(sealedValues)"
            + " sealed column values, so this zero is a count over an EMPTY corpus and says nothing"
            + " about whether this build can open a stored value. Read this row on a device that"
            + " actually holds sealed journal / cycle / intimacy / worry text.")
    }

    /// `.vacuous` when some sealed COLUMN contributed no value, even though the store as a whole
    /// did.
    ///
    /// The store-wide floor above is necessary but far too weak: the four sealed entities
    /// (`JournalNarrative`, `MenstrualNarrative`, `IntimacyLog`, `WorryNarrative`) share one
    /// aggregate, so a single journal row satisfies it while three entities have never been written
    /// at all. `ColumnCrypto`'s legacy rung was the read path for EVERY column alike, so a reading
    /// covering one entity says nothing about the other three — and this row's whole remaining job
    /// is to count what the surviving reader cannot open.
    private static func uncoveredColumnRefusal(_ result: SealedColumnFormatCensusResult) -> Phase3GateVerdict? {
        // R2: bounded by the census's column map.
        let uncovered = result.columns
            .filter { $0.value.total - $0.value.emptyOrNil == 0 }
            .keys
            .map(\.description)
            .sorted()
        guard !uncovered.isEmpty else { return nil }
        return .vacuous("\(uncovered.count) sealed column(s) contributed NO value to this reading —"
            + " \(uncovered.joined(separator: ", ")). The census counted the columns that do hold"
            + " values and says nothing about these, yet the deleted legacy rung was the read path"
            + " for all of them alike. Exercise every sealed entity (journal, cycle, intimacy,"
            + " worry) on the device before reading this row.")
    }

    private static func sealedColumnEvidence(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome
    ) -> [String] {
        guard case let .counted(result) = outcome else { return [] }
        let tally = result.total
        return [
            "marker census: legacy \(tally.unprefixed) exact · v3 <=\(tally.v3Marked)"
                + " / v2 <=\(tally.v2Marked) upper bounds · indeterminate \(tally.indeterminate)"
                + " · empty \(tally.emptyOrNil) · scanned \(result.rowsScanned) of \(result.rowsAvailable)"
                + " rows · truncated \(result.truncated)"
        ]
    }

    private static func sealedColumnCaveats(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome
    ) -> [String] {
        var caveats = [
            "THIS ROW LICENSES NOTHING. The legacy read path it was taken to license — ColumnCrypto's"
                + " unprefixed rung — is already deleted, and so is the keyed migrator that was this"
                + " row's second witness. What is left is a count of stored values this build cannot"
                + " open. No control is offered because there is nothing left to fund: no pass can"
                + " convert an unprefixed value once the rung that reads it is gone."
        ]
        if case let .counted(result) = outcome {
            let marked = result.total.v3Marked + result.total.v2Marked
            if marked > 0 {
                caveats.append("Every count here is a LOWER bound, permanently: up to \(marked)"
                    + " marked blobs could be collided legacy values (a legacy nonce's first byte"
                    + " hits a marker ~1/256). Only a keyed pass could ever tell them apart, and the"
                    + " keyed pass is gone — so that sliver is now unresolvable by anything in the"
                    + " app, and a zero above cannot rule it out.")
            }
        }
        return caveats
    }

    // MARK: Pending narrative buffer

    /// The buffer gate: the census reading IS the gate, so the row only applies the rule.
    ///
    /// `.absent` discharges as an EARNED zero — the buffer's drain-and-purge lifecycle makes absence
    /// real evidence, and `saveEntries` can only re-create the file in v2. `.unreadable` is
    /// `.unavailable`, carrying the census's own wording: it is not a zero.
    ///
    /// One witness, not two: Phase 3 deleted this surface's legacy reader and, with it, the format
    /// migrator whose completion latch used to be rendered beside the census. The latch was never
    /// the gate — the census reading was — so its removal takes an ornament, not evidence.
    static func row(
        forPendingNarrative census: PendingNarrativeBufferFormatCensus,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .pendingNarrativeBuffer,
            witnesses: [.markerCensus],
            stamps: stamp.map { [$0] } ?? [],
            verdict: pendingNarrativeVerdict(census),
            evidence: [
                "\(census.fileURL.lastPathComponent): \(pendingNarrativeState(census))",
                "legacyCount: \(census.legacyCount.map(String.init) ?? "—")"
            ],
            caveats: [
                "No control is offered here, and that is a decision rather than a gap: the gate IS"
                    + " the census reading, the reading is already in hand, and resetting the latch"
                    + " would buy no observation."
            ]
        )
    }

    private static func pendingNarrativeVerdict(_ census: PendingNarrativeBufferFormatCensus) -> Phase3GateVerdict {
        guard !census.format.isUnreadable else {
            return .unavailable("the buffer file exists but could not be read — retake with the device"
                + " unlocked; this is not a zero")
        }
        guard let legacyCount = census.legacyCount else {
            return .unavailable("the census produced no number for this surface")
        }
        guard legacyCount == 0 else {
            return .blocked("the buffer file is legacy — no FNB2 marker")
        }
        return .discharged
    }

    private static func pendingNarrativeState(_ census: PendingNarrativeBufferFormatCensus) -> String {
        switch census.format {
        case .absent: return "no buffer file (nothing was ever buffered — an EARNED zero here)"
        case .empty: return "the buffer file is zero bytes"
        case .v2Marked: return "current format (FNB2 marked)"
        case .legacyUnprefixed: return "legacy — no FNB2 marker"
        case let .unreadable(reason): return "the buffer file exists but could not be read (\(reason))"
        }
    }

    // MARK: Media at rest

    /// The three-part media gate: the latch, the residue arithmetic, and the blind spots.
    ///
    /// A `false` latch NEVER stands alone — see ``mediaLatchLine(latch:witness:passInFlight:)``.
    static func row(
        forMedia audit: MediaResidueAudit?,
        latches: Phase3LatchReadings,
        witness: MediaPassWitness?,
        passInFlight: Bool,
        censusStamp: Phase3Stamp?,
        launchPass: MediaLaunchPassRecord? = nil
    ) -> Phase3GateRow {
        var stamps: [Phase3Stamp] = []
        if let censusStamp { stamps.append(censusStamp) }
        if let witness { stamps.append(witness.stamp) }
        return Phase3GateRow(
            gate: .mediaAtRest,
            witnesses: [.markerCensus, .completionLatch, .mediaMigratorPass],
            stamps: stamps,
            verdict: mediaVerdict(audit, latches: latches, witness: witness, passInFlight: passInFlight,
                                  censusStamp: censusStamp, launchPass: launchPass),
            evidence: mediaEvidence(audit, latches: latches, witness: witness,
                                    passInFlight: passInFlight, launchPass: launchPass),
            caveats: mediaCaveats(audit, latches: latches)
        )
    }

    private static func mediaVerdict(
        _ audit: MediaResidueAudit?,
        latches: Phase3LatchReadings,
        witness: MediaPassWitness?,
        passInFlight: Bool,
        censusStamp: Phase3Stamp?,
        launchPass: MediaLaunchPassRecord?
    ) -> Phase3GateVerdict {
        guard let audit else { return .notTaken("no census reading, so there is no residue audit") }
        guard !audit.allLocationsAbsent else {
            return .unavailable("none of the eight swept locations exists — nothing was there to"
                + " count, which is not a swept-clean corpus")
        }
        guard !passInFlight else { return .notTaken("a media pass is running now") }
        guard let unaccounted = audit.unaccountedUnprefixed, let witness else {
            return .notTaken("no media pass was funded this process, so the residue subtraction has"
                + " no K term. Fund one from this screen — performPass() never touches the latch."
                + (launchPass.map { " (\($0.printed).)" } ?? ""))
        }
        if let refusal = mediaPassRefusal(audit, witness: witness, censusStamp: censusStamp) { return refusal }
        guard latches.mediaAtRest else {
            return .blocked("gate part (a) is not satisfied: "
                + mediaLatchLine(latch: false, witness: witness, passInFlight: false, launchPass: launchPass))
        }
        guard !audit.hasBlindSpots else { return .blocked(mediaBlindSpotDescription(audit)) }
        guard unaccounted == 0 else { return mediaUnaccountedVerdict(audit, unaccounted: unaccounted) }
        if let refusal = ownPhotoVacuityRefusal(audit) { return refusal }
        return .discharged
    }

    /// The own-photo corpora, which is where a legacy media byte can actually be.
    ///
    /// `MealPhotos/` is the ONE corpus with a legitimate pre-sealing plaintext generation; the other
    /// three are born sealed. The friend wall is born sealed too, and by
    /// `dispatchUnprefixedWall`'s design an unopenable wall byte is deliberately absent from
    /// `isClean` — so a corpus that is nothing but wall files can satisfy every clause of this gate
    /// while saying nothing whatever about the bytes the gate exists for.
    private static let ownPhotoLabels: [MediaCorpusLabel] =
        [.mealPhotos, .recipePhotos, .progressPhotos, .progressIndex]

    /// `.vacuous` when the sweep found own-photo bytes nowhere.
    ///
    /// Reached only where every other clause would have discharged, so it never masks a stronger
    /// finding — it separates "swept clean" from "there was nothing to sweep".
    private static func ownPhotoVacuityRefusal(_ audit: MediaResidueAudit) -> Phase3GateVerdict? {
        // R2: bounded by `audit.locations`.
        let ownPhotoFiles = audit.locations
            .filter { $0.label.map(Self.ownPhotoLabels.contains) ?? false }
            .reduce(0) { $0 + mediaTallyFileCount($1.tally) }
        guard ownPhotoFiles == 0 else { return nil }
        return .vacuous("every byte this gate examined belongs to the FRIEND WALL: the four"
            + " own-photo locations (\(Self.ownPhotoLabels.map(\.displayName).joined(separator: ", ")))"
            + " hold no files at all. The wall is born sealed and its unopenable bytes are"
            + " deliberately outside `isClean`, while MealPhotos is the one corpus with a legitimate"
            + " pre-sealing plaintext generation — so this reading cannot speak for the bytes the"
            + " gate is about. Read it on a device that has logged a meal photo.")
    }

    /// Every classified file in one location's tally. There is no scalar total on the tally itself,
    /// and the five class counts are the whole of it.
    private static func mediaTallyFileCount(_ tally: MediaAtRestFormatTally) -> Int {
        tally.v2Marked + tally.plaintextJPEG + tally.unprefixedLegacyOrUnrecognized
            + tally.empty + tally.indeterminate
    }

    /// The three ways this row's own inputs disqualify themselves before the latch is even consulted.
    ///
    /// The first is the one that authorizes a false pass. `MediaAtRestFormatMigrationResult.isClean`
    /// requires `convertedPlaintext == 0`, and a converting pass rewrites those
    /// files into the current format — so on the sitting's own prescribed order (fund the pass, then
    /// re-take the census) they vanish from the census's unprefixed bucket and `U − J − K` nets to
    /// zero. The instrument's own copy says "on a latched device it should convert nothing; if it
    /// converts something, that is the finding", and the verdict was swallowing exactly that finding
    /// — certifying gate part (a) on a latch the sitting had just proved stale. Every OTHER device in
    /// that state runs no pass at all, so the one device that healed itself would certify the fleet.
    private static func mediaPassRefusal(
        _ audit: MediaResidueAudit,
        witness: MediaPassWitness,
        censusStamp: Phase3Stamp?
    ) -> Phase3GateVerdict? {
        guard !witness.latchMoved else {
            return .unavailable("the media completion latch MOVED across this pass"
                + " (\(witness.latchBefore) -> \(witness.latchAfter)). performPass() is documented"
                + " never to reach markComplete(), so gate part (a) can no longer be quoted from"
                + " this sitting at all — relaunch and read the latch a shipped pass left.")
        }
        guard witness.result.isClean else {
            return .blocked("the live pass was not clean: \(witness.blockingBuckets.joined(separator: ", "))"
                + (witness.latchBefore
                   ? " — and the latch ALREADY STOOD when it ran, so this is a STALE latch: the pass"
                     + " has now healed this device and the census beside it can no longer show the"
                     + " residue. Other devices in this state run no pass at all."
                   : ""))
        }
        guard audit.locations.allSatisfy({ $0.residueVerdict != .unnamedLocation }) else {
            return .unavailable("the sweep returned a location this audit's vocabulary cannot name,"
                + " so residue B's label-to-location mapping cannot be trusted and the subtraction"
                + " is not a number. Fix MediaCorpusLabel.expectedURLs before reading this gate.")
        }
        guard let censusStamp, censusStamp.takenAt >= witness.stamp.takenAt else {
            return .notTaken("the marker census beside this pass was taken BEFORE it, so U and K do"
                + " not describe one filesystem state. Re-take the local scan.")
        }
        return nil
    }

    /// A negative subtraction is not a blocking count — it is an unanswerable one.
    private static func mediaUnaccountedVerdict(
        _ audit: MediaResidueAudit,
        unaccounted: Int
    ) -> Phase3GateVerdict {
        let terms = "census \(audit.censusUnprefixedTotal) − MeshPhotoCache.json"
            + " \(audit.meshPhotoCacheUnprefixed) − pass unopenableUnprefixed"
            + " \(audit.passUnopenableUnprefixed.map(String.init) ?? "—")"
        guard unaccounted > 0 else {
            return .unavailable("the pass accounted for MORE unprefixed bytes than the census saw"
                + " outside residue B (\(terms) = \(unaccounted)), so the two sweeps did not describe"
                + " one filesystem state. Nothing answered against the gate — retake both.")
        }
        return .blocked("\(unaccounted) unprefixed bytes are unaccounted for after subtracting the"
            + " named residues (\(terms))")
    }

    /// The four-way string a `false` latch is never rendered without.
    static func mediaLatchLine(
        latch: Bool,
        witness: MediaPassWitness?,
        passInFlight: Bool,
        launchPass: MediaLaunchPassRecord? = nil
    ) -> String {
        guard !latch else { return "latch true" }
        guard !passInFlight else { return "latch false — a pass is running now" }
        guard let witness else {
            guard let launchPass else {
                return "latch false — no pass has been observed this process"
            }
            return "latch false — no pass was funded here, but \(launchPass.printed); fund one from"
                + " this screen for the residue tally"
        }
        let buckets = witness.blockingBuckets
        guard !buckets.isEmpty else {
            return "latch false — a pass was observed at \(witness.stamp.printed) and reported no"
                + " blocking bucket; the latch is set only by the run loop, which this instrument"
                + " never runs (it is gate part (a), and this page may neither set nor clear it)"
        }
        return "latch false — a pass was observed at \(witness.stamp.printed) and was blocked on"
            + " \(buckets.joined(separator: ", "))"
    }

    private static func mediaEvidence(
        _ audit: MediaResidueAudit?,
        latches: Phase3LatchReadings,
        witness: MediaPassWitness?,
        passInFlight: Bool,
        launchPass: MediaLaunchPassRecord?
    ) -> [String] {
        var lines = ["(a) " + mediaLatchLine(latch: latches.mediaAtRest, witness: witness,
                                             passInFlight: passInFlight, launchPass: launchPass)]
        lines.append("launch pass: \(launchPass?.printed ?? "none has finished this process")")
        lines.append("ownPhotoKeyMigrationComplete (an INPUT to this gate, never a gate of its own):"
            + " \(latches.ownPhotoKey)")
        guard let audit else { return lines }
        lines.append(contentsOf: audit.printedLocationLines)
        lines.append(contentsOf: audit.printedArithmeticLines)
        lines.append("(c) hasBlindSpots \(audit.hasBlindSpots) — indeterminate \(audit.indeterminate)"
            + " · unlistableDirectories \(audit.unlistableDirectories) · truncated \(audit.truncated)")
        lines.append("allLocationsAbsent (a separate trap): \(audit.allLocationsAbsent)")
        lines.append(contentsOf: mediaWitnessLines(witness))
        return lines
    }

    /// The funded pass's own tally — including, ALWAYS, the buckets that made it unclean.
    ///
    /// `blockingBuckets` used to be reachable only through the latch-false branch of
    /// `mediaLatchLine`, so a latched device printed a bare `isClean false` with no named bucket
    /// beside it — and `convertedPlaintext`, the one a re-taken census erases, appeared on no line
    /// of the row or the export at all.
    private static func mediaWitnessLines(_ witness: MediaPassWitness?) -> [String] {
        guard let witness else { return [] }
        let buckets = witness.blockingBuckets
        return [
            "media pass \(witness.stamp.printed): examined \(witness.result.examined)"
                + " · unopenableUnprefixed \(witness.result.unopenableUnprefixed)"
                + " · refusedPlaintext \(witness.result.refusedPlaintext)"
                + " · alreadyCurrent \(witness.result.alreadyCurrentFormat) · empty \(witness.result.empty)"
                + " · isClean \(witness.result.isClean) · latch \(witness.latchBefore) -> \(witness.latchAfter)",
            "media pass blocking buckets: " + (buckets.isEmpty ? "none" : buckets.joined(separator: ", "))
        ]
    }

    private static func mediaBlindSpotDescription(_ audit: MediaResidueAudit) -> String {
        "the sweep has blind spots, so the count is a LOWER bound: indeterminate \(audit.indeterminate),"
            + " unlistableDirectories \(audit.unlistableDirectories), truncated \(audit.truncated)"
    }

    private static func mediaCaveats(_ audit: MediaResidueAudit?, latches: Phase3LatchReadings) -> [String] {
        var caveats = [
            "An unprefixed byte is NOT blocking: unopenableUnprefixed is deliberately absent from"
                + " the pass's isClean, and since Phase 3 deleted gcmOpen's legacy-read branch every"
                + " unmarked blob lands there by classification alone. No key opens them, so there is"
                + " nothing a pass could do for them beyond counting them."
        ]
        guard let audit else { return caveats }
        if audit.keylessWallSignature {
            caveats.append("Residue C's SHAPE is present: wall photo/thumbnail locations hold plaintext"
                + " JPEGs while the media latch is open — the abortedNoWallKey signature. A plaintext"
                + " JPEG is census class plaintextJPEG, never unprefixed, so it contributes ZERO to"
                + " the arithmetic above.")
        }
        if let disagreement = audit.examinedDisagreementCaveat { caveats.append(disagreement) }
        return caveats
    }

    // MARK: Lock wrap

    /// The wrap row, with the reviewer's earned-absence rule applied — and one witness now, not two.
    ///
    /// `.absent` discharges ONLY alongside `isLockConfigured == false`. The census has no choice but
    /// to print all three absences — it is a keychain-only reader — but the readout holds
    /// `FernletLockService`, and one public property collapses the three-way ambiguity to two.
    /// Discharging over an unresolved absence whose third reading is "a wrap that has gone missing,
    /// which is a fault" would be an unearned zero on the surface whose own doc warns that
    /// collapsing "could not read" into "not there" is what licenses Phase 3 to lock a user out.
    /// That rule is unchanged, and it is the whole of what this row still decides.
    ///
    /// What it no longer decides is a deletion. The legacy wrap reader is already gone, and
    /// `LockWrapRowLatch` — the DERIVED bit this row printed under a "licenses nothing" caveat —
    /// went with the migrator that owned it. The row therefore folds the census alone and reports
    /// whether the one stored content-key wrap is one this build can still open; on this surface a
    /// legacy reading is not a backlog but an app-lock the owner may be unable to pass.
    static func row(
        forLockWrap report: LockWrapFormatCensusReport,
        lockConfigured: Bool,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .lockContentKeyWrap,
            witnesses: [.markerCensus],
            stamps: stamp.map { [$0] } ?? [],
            verdict: lockWrapVerdict(report, lockConfigured: lockConfigured),
            evidence: [
                "\(report.account): \(lockWrapState(report))",
                "legacyWrapCount: \(report.legacyWrapCount.map(String.init) ?? "—")",
                "isLockConfigured: \(lockConfigured)"
            ],
            caveats: lockWrapCaveats()
        )
    }

    private static func lockWrapVerdict(
        _ report: LockWrapFormatCensusReport,
        lockConfigured: Bool
    ) -> Phase3GateVerdict {
        switch report.state {
        case .v2Marked:
            guard report.legacyWrapCount == 0 else { return .blocked("a legacy wrap remains") }
            return .discharged
        case .legacyUnprefixed:
            return .blocked("the wrap row is legacy — no FLW2 marker")
        case .absent:
            guard lockConfigured else {
                return .discharged
            }
            return .notTaken("the wrap row is absent with a lock CONFIGURED. Two honest readings"
                + " remain — the key is enclave-bound, or a configured lock's wrap has gone missing"
                + " (a fault). Name which before this gate discharges.")
        case .malformedEmpty:
            return .unavailable("the wrap row exists and is EMPTY. No first-party writer produces an"
                + " empty wrap — this is a fault, not a clean zero.")
        case let .unreadable(osStatus):
            return .unavailable("the keychain refused the read (OSStatus \(osStatus)) — retake with"
                + " the device unlocked; this is not a zero")
        }
    }

    private static func lockWrapState(_ report: LockWrapFormatCensusReport) -> String {
        switch report.state {
        case .absent:
            return "no wrap row (no lock configured; the key is enclave-bound; or, on enclave-less"
                + " hardware, a configured lock whose wrap has gone missing — a fault)"
        case .v2Marked: return "current format (FLW2 marked)"
        case .legacyUnprefixed: return "legacy — no FLW2 marker"
        case .malformedEmpty: return "the wrap row exists and is EMPTY"
        case let .unreadable(osStatus): return "the keychain refused the read (OSStatus \(osStatus))"
        }
    }

    private static func lockWrapCaveats() -> [String] {
        [
            "THIS ROW LICENSES NOTHING. The legacy wrap reader it was taken to license is already"
                + " deleted; what is left is a report of whether the one stored content-key wrap is"
                + " one this build can still open. A legacy reading here is not a backlog — it is an"
                + " app lock whose content key this build cannot unwrap.",
            "No pass could be funded for this surface even before the delete: the migrator was"
                + " credential-gated by construction (no initializer that did not take the recovered"
                + " content key and the just-derived wrapping key), so the absence of a button here"
                + " has always been a decision rather than a gap — and there is now no migrator to"
                + " offer one for.",
            "The derived row latch is no longer printed. It re-read the same keychain byte through"
                + " the same LockWrapFormatCensus.classify this row uses, so it never licensed"
                + " anything on its own; its one use was that a DISAGREEMENT between the two reads"
                + " meant the keychain's answer had changed between them. That cross-check is gone"
                + " with the latch type, so this row's single reading has no second opinion."
        ]
    }

    // MARK: Heart-drop sidecars

    /// The sidecar reading applied PER ROW, with the quarantine visibly excluded.
    ///
    /// The census already prints every file's state, so the plan's per-row rule is applicable today
    /// — but a reader has to apply "three main rows, quarantine excluded" by eye off a `·`-joined
    /// line, against an aggregate `legacySealedCount` that INCLUDES the quarantine. This applies the
    /// rule and says which files it applied it to. That per-row verdict is unchanged.
    ///
    /// What changed is what the row is FOR. The legacy sidecar reader is already deleted, and
    /// `HeartDropSidecarMigrationLatch` went with the migrator that owned it, so there is no
    /// completion bit left to print and no deletion left to license. A legacy main row is now a
    /// stored outbox, peer-bundle or dedup file this build can no longer open.
    static func row(
        forHeartDrop report: HeartDropSidecarFormatCensus.Report,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .heartDropSidecars,
            witnesses: [.markerCensus],
            stamps: stamp.map { [$0] } ?? [],
            verdict: heartDropVerdict(report),
            evidence: heartDropEvidence(report),
            caveats: [
                "THIS ROW LICENSES NOTHING. The legacy sidecar reader it was taken to license is"
                    + " already deleted, and so is the migrator whose completion latch this row used"
                    + " to print. A legacy main row below is a stored sidecar this build cannot"
                    + " open, not a conversion still owed.",
                "outboxQuarantine is EXCLUDED from the verdict, and the plan's reason is the whole"
                    + " point: no reader ever opens the quarantine path, so a legacy tombstone there"
                    + " is not a reader dependency — folding it into an aggregate would strand the"
                    + " reading forever on bytes whose format cannot matter.",
                "No control is offered, and none is possible: this surface re-surveys the disk on"
                    + " EVERY launch, and there is no longer a pass that could convert what the"
                    + " survey finds."
            ]
        )
    }

    /// The three MAIN sidecars the gate is about. The quarantine is deliberately not here.
    private static let heartDropMainSidecars: [HeartDropSidecarFormatCensus.Sidecar] =
        [.outbox, .peerBundles, .dedup]

    private static func heartDropVerdict(_ report: HeartDropSidecarFormatCensus.Report) -> Phase3GateVerdict {
        var missing: [String] = []
        var unreadable: [String] = []
        var blocking: [String] = []
        // R2: bounded by the three main sidecars.
        for sidecar in heartDropMainSidecars {
            guard let state = report.state(of: sidecar) else {
                missing.append(sidecar.rawValue)
                continue
            }
            switch state {
            case .unreadable: unreadable.append(sidecar.rawValue)
            case .legacySealed, .unsealedOrUnrecognized: blocking.append("\(sidecar.rawValue) \(state.rawValue)")
            case .absent, .v2Sealed, .empty: continue
            }
        }
        guard missing.isEmpty else {
            return .unavailable("the survey carries no reading for \(missing.joined(separator: ", "))")
        }
        guard unreadable.isEmpty else {
            return .unavailable("could not read \(unreadable.joined(separator: ", ")) — retake"
                + " unlocked; this is not a zero")
        }
        guard blocking.isEmpty else { return .blocked(blocking.joined(separator: ", ")) }
        // Positive evidence, not merely "nothing blocking". `.absent` and `.empty` both `continue`
        // above because neither is a legacy byte — but neither is a CURRENT byte either, and a row
        // that was never written cannot demonstrate that the writer stopped emitting `legacyMagic`.
        // Without this arm all-three-absent reached `.discharged`, which is the vacuous reading
        // wearing the discharge's face.
        let sealed = heartDropMainSidecars.filter { report.state(of: $0) == .v2Sealed }
        guard !sealed.isEmpty else {
            return .vacuous("none of the three main sidecars holds a sealed byte — every row read"
                + " absent or empty, so the survey found no heart-drop bytes AT ALL. A zero over no"
                + " bytes is not a corpus this build has been shown to open. Read this row on a"
                + " device that has actually sent or received a heart.")
        }
        return .discharged
    }

    private static func heartDropEvidence(
        _ report: HeartDropSidecarFormatCensus.Report
    ) -> [String] {
        // R2: bounded by `Sidecar.allCases` (four).
        var lines = HeartDropSidecarFormatCensus.Sidecar.allCases.map { sidecar -> String in
            let state = report.state(of: sidecar)?.rawValue ?? "not surveyed"
            let excluded = sidecar == .outboxQuarantine ? "  [EXCLUDED from the verdict]" : ""
            return "\(sidecar.rawValue): \(state)\(excluded)"
        }
        lines.append("aggregate (INCLUDES the quarantine, so it is not the gate): legacySealed"
            + " \(report.legacySealedCount) · v2 \(report.v2SealedCount) · absent \(report.absentCount)"
            + " · unsealedOrUnrecognised \(report.unsealedOrUnrecognizedCount)"
            + " · unreadable \(report.unreadableCount)")
        return lines
    }

    // MARK: Sealed photo backup

    /// The sealed-photo gate, read from the manifests rather than inferred from any latch.
    ///
    /// Discharges only when all three corpora read `.proven` with `minimum >= 2` and `entryCount > 0`.
    /// Each of the three ways a naive rendering manufactures a pass is blocked by its own case — see
    /// ``SealedPhotoManifestReading``.
    static func row(
        forSealedPhoto probe: Phase3ManifestProbe?,
        bodyProbes: [SealedPhotoCorpus: BodyProbeReading],
        latch: Bool,
        environment: Phase3GateEnvironment,
        fullPassVerdicts: [SealedPhotoCorpusFormatVerdict]? = nil
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .sealedPhotoBackup,
            witnesses: [.manifestProbe, .bodyProbe, .completionLatch],
            stamps: probe.map { [$0.stamp] } ?? [],
            verdict: sealedPhotoVerdict(probe, bodyProbes: bodyProbes, environment: environment),
            evidence: sealedPhotoEvidence(probe, bodyProbes: bodyProbes, latch: latch,
                                          environment: environment, fullPassVerdicts: fullPassVerdicts),
            caveats: sealedPhotoCaveats(probe, environment: environment)
        )
    }

    private static func sealedPhotoCaveats(
        _ probe: Phase3ManifestProbe?,
        environment: Phase3GateEnvironment
    ) -> [String] {
        var caveats = [
            Phase3GateEnvironment.cloudKitDatabaseCaveat,
            "minimum == 1 means legacy OR UNPROVEN. The row says NOT PROVEN and never 'legacy"
                + " entries found'; every entry committed before the marker existed decodes as 1"
                + " whatever its digest is.",
            "This reading is meaningless before a full-verification pass: only the rungs that"
                + " read the plaintext stamp version 2. Probe once BEFORE Privacy & Data → Retry"
                + " and once after, and keep both."
        ]
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        let stale = SealedPhotoCorpus.allCases.filter { isStaleManifestReading(probe?.readings[$0]) }
        if !stale.isEmpty {
            caveats.append("STALE MANIFEST: \(stale.map(\.rawValue).joined(separator: ", ")) came back"
                + " carrying a generation BELOW the one this device has already authenticated."
                + " SealedPhotoBackupService.restore would refuse that same record with"
                + " .staleGeneration, so it cannot be shown to be the live manifest.")
        }
        return caveats
    }

    /// Whether a reading's record generation sits BELOW this device's high-water mark.
    ///
    /// `manifestFormatReading` performs no high-water check and says so in its own doc: "a
    /// stale-but-authentic manifest can read >= 2 here while the live one reads 1". The inequality
    /// also has a benign local cause — `mintNextPhoto` burns the number before the write, so one
    /// failed upload leaves the high-water one ahead of a LIVE record — which is exactly why the
    /// verdict this feeds is `.unavailable` ("cannot be shown to be live") and not `.blocked`.
    private static func isStaleManifestReading(_ reading: SealedPhotoManifestReading?) -> Bool {
        switch reading {
        case let .proven(_, _, _, generation, highWater): return generation < highWater
        case let .vacuousEmptyManifest(generation, highWater): return generation < highWater
        case .noManifestReturned, .unreadable, .none: return false
        }
    }

    private static func sealedPhotoVerdict(
        _ probe: Phase3ManifestProbe?,
        bodyProbes: [SealedPhotoCorpus: BodyProbeReading],
        environment: Phase3GateEnvironment
    ) -> Phase3GateVerdict {
        guard let probe else {
            return .notTaken("no manifest probe has been taken this process. It is an explicit"
                + " button because it goes over the network and decrypts three manifests.")
        }
        guard !environment.skipSealedRestoreEnvSet else {
            return .notTaken("FERNLET_SKIP_SEALED_RESTORE=1 is set on this run scheme. That DEBUG"
                + " guard fronts the UPLOAD path as well as the restore, so the full-verification"
                + " pass this gate's wording requires silently no-ops — whatever the manifests"
                + " already in the cloud read, this sitting cannot discharge the gate.")
        }
        var groups: [String: [String]] = [:]
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        for corpus in SealedPhotoCorpus.allCases {
            let outcome = sealedPhotoCorpusOutcome(probe.readings[corpus], corpus: corpus,
                                                   bodyProbe: bodyProbes[corpus] ?? .notProbed,
                                                   environment: environment)
            guard let outcome else { continue }
            groups[outcome.kind, default: []].append(outcome.detail)
        }
        return sealedPhotoFold(groups)
    }

    /// Folds the per-corpus outcomes in a fixed precedence: a definite failure outranks an
    /// unanswerable clause, which outranks a clause nobody took, which outranks a vacuous one.
    private static func sealedPhotoFold(_ groups: [String: [String]]) -> Phase3GateVerdict {
        if let blocked = groups["blocked"] { return .blocked(blocked.joined(separator: "; ")) }
        if let unavailable = groups["unavailable"] { return .unavailable(unavailable.joined(separator: "; ")) }
        if let notTaken = groups["notTaken"] { return .notTaken(notTaken.joined(separator: "; ")) }
        if let vacuous = groups["vacuous"] { return .vacuous(vacuous.joined(separator: "; ")) }
        return .discharged
    }

    private static func sealedPhotoCorpusOutcome(
        _ reading: SealedPhotoManifestReading?,
        corpus: SealedPhotoCorpus,
        bodyProbe: BodyProbeReading,
        environment: Phase3GateEnvironment
    ) -> (kind: String, detail: String)? {
        guard let reading else {
            return ("notTaken", "\(corpus.rawValue): the probe returned no reading for this corpus")
        }
        switch reading {
        case let .proven(minimum, entryCount, _, generation, highWater):
            guard entryCount > 0 else {
                return ("vacuous", "\(corpus.rawValue): a manifest with no entries carries no legacy digest")
            }
            guard generation >= highWater else { return staleGenerationOutcome(corpus, generation, highWater) }
            guard minimum >= 2 else {
                return ("blocked", "\(corpus.rawValue): minimumEntryHashVersion \(minimum) — NOT PROVEN")
            }
            return nil
        case let .vacuousEmptyManifest(generation, highWater):
            guard generation >= highWater else { return staleGenerationOutcome(corpus, generation, highWater) }
            return ("vacuous", "\(corpus.rawValue): empty manifest — no entry exists to carry a legacy digest")
        case .noManifestReturned:
            return sealedPhotoNoManifestOutcome(corpus: corpus, bodyProbe: bodyProbe, environment: environment)
        case let .unreadable(cause):
            return ("unavailable", "\(corpus.rawValue): the manifest could not be read (\(cause)) —"
                + " this is not a zero, and malformedRecord covers several causes including a"
                + " TRANSIENT unreadable CKAsset, so it is never 'corrupt'")
        }
    }

    /// The record that came back is older than one this device has already authenticated.
    ///
    /// `.unavailable`, not `.blocked`: the honest claim is "this cannot be shown to be the live
    /// manifest", because a burned generation from a mint-then-failed-write produces the same
    /// inequality over a record that IS live.
    private static func staleGenerationOutcome(
        _ corpus: SealedPhotoCorpus,
        _ generation: Int64,
        _ highWater: Int64
    ) -> (kind: String, detail: String) {
        ("unavailable", "\(corpus.rawValue): the manifest record that came back carries generation"
            + " \(generation), BELOW the generation \(highWater) this device has already"
            + " authenticated. This reading cannot be shown to be the live manifest — and"
            + " SealedPhotoBackupService.restore would refuse this same record with .staleGeneration,"
            + " so nothing here is a zero. Re-probe after a completed Retry.")
    }

    /// "No manifest record came back" is not "no manifest exists". A committed escrow route makes it
    /// blocking; a route this device never committed makes it a VACUOUS satisfaction with its own
    /// reason, which is the owner's policy call to record rather than the readout's to infer — but
    /// only once the bodies have actually been ENUMERATED. "Zero bodies" is what turns the missing
    /// manifest into a vacuous satisfaction, so a probe nobody took and a probe that threw must not
    /// fold as if the bodies had been looked for and found absent.
    private static func sealedPhotoNoManifestOutcome(
        corpus: SealedPhotoCorpus,
        bodyProbe: BodyProbeReading,
        environment: Phase3GateEnvironment
    ) -> (kind: String, detail: String) {
        if case let .counted(count, _) = bodyProbe, count > 0 {
            return ("blocked", "\(corpus.rawValue): no manifest came back but \(count)+ body records"
                + " exist — bodies with no commit marker restore nothing")
        }
        guard !environment.escrowRouteCommitted else {
            return ("blocked", "\(corpus.rawValue): no manifest record came back over a COMMITTED"
                + " escrow route — which is not the same as no manifest existing")
        }
        switch bodyProbe {
        case .notProbed:
            return ("notTaken", "\(corpus.rawValue): no manifest came back and no body probe was"
                + " taken — 'never written' needs the zero-body reading, which nobody bought")
        case let .failed(cause):
            return ("unavailable", "\(corpus.rawValue): no manifest came back and the body probe"
                + " failed (\(cause)) — this is not a zero")
        case .counted:
            return ("vacuous", "\(corpus.rawValue): no manifest came back, the body probe enumerated"
                + " zero records, and OwnPhotoEscrowCommitLedger says no route was ever committed on"
                + " this device")
        }
    }

    private static func sealedPhotoEvidence(
        _ probe: Phase3ManifestProbe?,
        bodyProbes: [SealedPhotoCorpus: BodyProbeReading],
        latch: Bool,
        environment: Phase3GateEnvironment,
        fullPassVerdicts: [SealedPhotoCorpusFormatVerdict]?
    ) -> [String] {
        var lines = [
            "sealedBackupOwnPhotosEnabled: \(environment.sealedBackupOwnPhotosEnabled)",
            "escrowRouteCommitted (the COMMIT PROOF, not the preference): \(environment.escrowRouteCommitted)",
            "SealedPhotoBackupMigrationLatch (explicitly NOT the Phase-3 gate): \(latch)"
        ]
        lines.append(contentsOf: fullPassVerdictLines(fullPassVerdicts))
        guard let probe else {
            lines.append("manifest probe: not taken this process")
            return lines
        }
        lines.append("manifest probe \(probe.stamp.printed):")
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        for corpus in SealedPhotoCorpus.allCases {
            lines.append("  \(corpus.rawValue): \(sealedPhotoReadingLine(probe.readings[corpus]))")
            lines.append("  \(corpus.rawValue) body probe: \(bodyProbeLine(bodyProbes[corpus] ?? .notProbed))")
        }
        return lines
    }

    /// The last full-verification pass's per-corpus verdicts, under a heading that says what they
    /// are NOT.
    ///
    /// A by-product of a WRITING pass, never the gate: `observedMinima` includes the pre-heal open
    /// AND the outgoing committed value, so a corpus that healed this pass legitimately carries a 1
    /// there while its committed manifest reads 2. What they DO buy is `examined` — the three-way
    /// "never looked / examined-none / examined-with-minima" fact a live probe structurally cannot
    /// produce, and the difference between a vacuous satisfaction that is safe to record and one
    /// hiding an un-swept corpus.
    private static func fullPassVerdictLines(_ verdicts: [SealedPhotoCorpusFormatVerdict]?) -> [String] {
        guard let verdicts else {
            return ["last full pass verdicts (a BY-PRODUCT of a writing pass, not the gate): none"
                + " retained this process"]
        }
        var lines = ["last full pass verdicts (a BY-PRODUCT of a writing pass, not the gate):"]
        // R2: bounded by `SealedPhotoCorpus.allCases` (three).
        for verdict in verdicts {
            lines.append("  \(verdict.corpus.rawValue): examined \(verdict.examined)"
                + " · committed \(verdict.committed) · observedMinima \(verdict.observedMinima)"
                + " · unreadable \(verdict.unreadable) · healedEntries \(verdict.healedEntries)")
        }
        return lines
    }

    /// One corpus reading as the report prints it — the entry count ALWAYS beside the minimum, and
    /// the record generation always beside this device's high-water mark.
    static func sealedPhotoReadingLine(_ reading: SealedPhotoManifestReading?) -> String {
        guard let reading else { return "no reading" }
        switch reading {
        case let .proven(minimum, entryCount, unproven, generation, highWater):
            let disagreement = generation == highWater ? "" : "  [generation and deviceHighWater DISAGREE]"
            return "minimum \(minimum)\(minimum >= 2 ? "" : " (NOT PROVEN)") · entries \(entryCount)"
                + " · unproven \(unproven) · generation \(generation) · deviceHighWater \(highWater)\(disagreement)"
        case let .vacuousEmptyManifest(generation, highWater):
            return "EMPTY manifest — reads minimum 2 vacuously; no entry exists to carry a legacy"
                + " digest · generation \(generation) · deviceHighWater \(highWater)"
        case .noManifestReturned:
            return "no manifest record came back (NOT the same as 'no manifest exists')"
        case let .unreadable(cause):
            return "UNREADABLE: \(cause)"
        }
    }

    /// One body probe as the report prints it. "Not probed" and "probed, zero bodies" never collide.
    ///
    /// Every count is printed as a LOWER bound whatever the flag says, and that is not caution — it
    /// is the honest reading of what the transport can report. `CloudKitDataService` follows the
    /// query's cursor chain up to a PRIVATE `maxQueryPages` cap and does not surface having reached
    /// it, so `truncatedAtPageCap` can only ever be set by a caller that has some other reason to
    /// know. See the type doc on ``BodyProbeReading``.
    static func bodyProbeLine(_ reading: BodyProbeReading) -> String {
        switch reading {
        case .notProbed: return "not probed"
        case let .counted(count, truncated):
            let cap = truncated ? " — the page cap was reached" : ""
            return "\(count) body records (a LOWER bound: the id enumeration follows the cursor chain"
                + " up to a private page cap and does not report reaching it\(cap))"
        case let .failed(cause): return "the probe failed: \(cause)"
        }
    }
}

// MARK: - The report

/// Serialises a readout into plain UTF-8 for the two export routes.
///
/// ## The redaction contract
///
/// The report carries **counts, verdicts, stamps, latch key names and frozen tokens** — and NO media
/// file names, NO filesystem paths, NO photo or manifest-entry identifiers, NO content hashes, NO
/// captions, NO key material, and nothing decrypted from a photo. `Phase3GateReadoutTests` enforces
/// that on BOTH routes rather than trusting it: the log route must not become the leak the
/// pasteboard route is tested against.
///
/// The footnote on screen is written to be TRUE about this and deliberately does not copy the mesh
/// probe's stronger "contains no user content" — `Progress photos: 412` is a fact about the user, and
/// it is the number the gate is about.
///
/// ## Why it appends to a `[String]`
///
/// Never one `"""…"""` template. `Scripts/power-of-10-scan.py` counts every payload line of a
/// multi-line string literal as a code line, so a template would eat its enclosing function's
/// 60-line R4 budget line for line.
nonisolated enum Phase3GateReportBuilder {

    /// The whole report, one element per line.
    static func lines(for readout: Phase3GateReadout) -> [String] {
        var out = headerLines(readout)
        out.append(contentsOf: environmentLines(readout.environment))
        // R2: bounded by `Phase3Gate.allCases` (six).
        for row in readout.rows { out.append(contentsOf: gateLines(row)) }
        out.append(contentsOf: manifestProbeHistoryLines(readout.manifestProbes))
        out.append(contentsOf: mediaArithmeticLines(readout.mediaAudit))
        out.append(contentsOf: checklistLines(readout.checklist))
        out.append(contentsOf: refusalLines(readout.refusals))
        out.append(contentsOf: trailerLines(readout))
        return out
    }

    /// EVERY manifest probe, in acquisition order — not just the one the gate row folds.
    ///
    /// The sitting takes probe #1 before Privacy & Data → Retry precisely because Retry rewrites all
    /// three manifests and forces `generation` and `deviceHighWater` into agreement, so probe #2
    /// structurally cannot show the stale-manifest disagreement probe #1 exists to capture. The
    /// verdict folds `.last`, and the header prints probe #1's LABEL and TIME — so without this
    /// section the report proves two probes were taken while carrying the numbers of only one, and
    /// the unrepeatable reading never leaves memory.
    private static func manifestProbeHistoryLines(_ probes: [Phase3ManifestProbe]) -> [String] {
        guard !probes.isEmpty else { return [] }
        var out = ["", "MANIFEST PROBES, IN ORDER (the gate row folds the LAST; probe #1 cannot be"
            + " re-taken once Retry has run)"]
        // R2: bounded by `Phase3ReadoutSession.maxManifestProbes`.
        for probe in probes {
            out.append("  \(probe.stamp.printed)")
            // R2: bounded by `SealedPhotoCorpus.allCases` (three).
            for corpus in SealedPhotoCorpus.allCases {
                out.append("    \(corpus.rawValue): "
                    + Phase3GateReadoutBuilder.sealedPhotoReadingLine(probe.readings[corpus]))
            }
        }
        return out
    }

    /// The whole report as one string.
    static func text(for readout: Phase3GateReadout) -> String {
        lines(for: readout).joined(separator: "\n")
    }

    /// The report split into indexed chunks for the audit-log egress route.
    ///
    /// Each chunk carries its index and total when logged, so a truncated console capture is
    /// detectable rather than silently short. A single line longer than `maxBytes` travels whole in
    /// its own chunk — splitting mid-line would corrupt a number, which is worse than one long line.
    static func chunks(for readout: Phase3GateReadout, maxBytes: Int) -> [String] {
        // R7: validate at entry. A zero or negative bound would emit one chunk per line forever.
        let bound = max(256, maxBytes)
        var chunks: [String] = []
        // Accumulated as LINES, not as one growing string. A string accumulator tests emptiness on
        // the accumulator itself, so a report's blank separator line landing at a chunk boundary
        // starts a chunk that is still empty and is then overwritten by the next line — silently
        // deleting it from the reassembled report.
        var current: [String] = []
        var currentBytes = 0
        // R2: bounded by the line array `lines(for:)` returns.
        for line in lines(for: readout) {
            let separator = current.isEmpty ? 0 : 1
            if !current.isEmpty, currentBytes + separator + line.utf8.count > bound {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentBytes = 0
            }
            currentBytes += (current.isEmpty ? 0 : 1) + line.utf8.count
            current.append(line)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private static func headerLines(_ readout: Phase3GateReadout) -> [String] {
        var out = [
            "Fernlet Phase 3 gate readout (DEBUG only)",
            "device: \(readout.environment.deviceModel)",
            "system: \(readout.environment.systemVersion)",
            "EVERY reading below lives in ONE app launch. Nothing here is persisted, so stopping or"
                + " re-running the app discards the whole sitting — and manifest probe #1, taken"
                + " before Privacy & Data → Retry, cannot be re-taken on this device afterwards.",
            "stamps, in acquisition order (there is deliberately no single takenAt):"
        ]
        guard !readout.stamps.isEmpty else {
            out.append("  none — nothing has been observed this process")
            return out
        }
        // R2: bounded by the stamp array the fold assembled.
        for stamp in readout.stamps { out.append("  \(stamp.printed)") }
        return out
    }

    private static func environmentLines(_ environment: Phase3GateEnvironment) -> [String] {
        let lastPass = environment.lastFullPassCompletedAt.map { $0.ISO8601Format() } ?? "none this process"
        return [
            "",
            "ENVIRONMENT",
            "  sealedBackupOwnPhotosEnabled: \(environment.sealedBackupOwnPhotosEnabled)",
            "  escrowRouteCommitted: \(environment.escrowRouteCommitted)",
            "  FERNLET_SKIP_SEALED_RESTORE set: \(environment.skipSealedRestoreEnvSet)",
            "  isLockConfigured: \(environment.lockConfigured)",
            "  private hub unlocked: \(environment.privateHubUnlocked)",
            "  own-photo pass in flight: \(environment.ownPhotoBackupPassInFlight)",
            "  last full-verification pass: \(lastPass)",
            "  embedded provisioning profile present (a WEAK signal): \(environment.hasEmbeddedProvisioningProfile)",
            "  \(Phase3GateEnvironment.cloudKitDatabaseCaveat)"
        ]
    }

    private static func gateLines(_ row: Phase3GateRow) -> [String] {
        var out = [
            "",
            "GATE \(row.gate.displayName) — \(row.verdict.displayName)"
        ]
        if let reason = row.verdict.reason { out.append("  reason: \(reason)") }
        out.append("  witnesses: " + row.witnesses.map(\.displayName).joined(separator: ", "))
        out.append("  gate wording: \(row.gate.gateWording)")
        out.append("  stamps folded: " + (row.stamps.isEmpty ? "none" : row.stamps.map(\.printed).joined(separator: " | ")))
        // R2: bounded by the evidence array the fold assembled.
        for line in row.evidence { out.append("  \(line)") }
        // R2: bounded by the caveat array the fold assembled.
        for caveat in row.caveats { out.append("  caveat: \(caveat)") }
        return out
    }

    private static func mediaArithmeticLines(_ audit: MediaResidueAudit?) -> [String] {
        guard let audit else { return [] }
        var out = ["", "MEDIA RESIDUE ARITHMETIC, PRINTED RATHER THAN LEFT TO THE READER"]
        // R2: bounded by the eight swept locations plus four arithmetic lines.
        for line in audit.printedLocationLines { out.append("  \(line)") }
        for line in audit.printedArithmeticLines { out.append("  \(line)") }
        return out
    }

    private static func checklistLines(_ checklist: [Phase3SittingStep]) -> [String] {
        guard !checklist.isEmpty else { return [] }
        var out = ["", "SITTING CHECKLIST (done-states derived from observations actually taken)"]
        // R2: bounded by the seven steps.
        for step in checklist {
            out.append("  [\(step.isDone ? "x" : " ")] \(step.title)")
            out.append("      \(step.detail)")
        }
        return out
    }

    private static func refusalLines(_ refusals: [String]) -> [String] {
        guard !refusals.isEmpty else { return [] }
        var out = ["", "REFUSALS RECORDED THIS SITTING"]
        // R2: bounded by the session's 32-entry cap.
        for refusal in refusals { out.append("  \(refusal)") }
        return out
    }

    /// The trailer names EVERY row that did not discharge, grouped by verdict kind, and leads with
    /// the count. Naming only the not-taken ones would let a skimmed report read as complete while a
    /// row that answered BLOCKING appeared only in the body — exactly the rows a Phase 3 delete must
    /// not step over. A count of non-discharged rows is not a whole-device rollup.
    private static func trailerLines(_ readout: Phase3GateReadout) -> [String] {
        let discharged = readout.rows.filter(\.isDischarged).count
        let total = readout.rows.count
        var out = ["", "TRAILER"]
        guard discharged < total else {
            out.append("  \(discharged) of \(total) gates discharged.")
            return out
        }
        out.append("  \(discharged) of \(total) gates discharged; \(total - discharged) did not — see below.")
        // R2: bounded by the four verdict kinds.
        for group in readout.rowsNotDischarged {
            out.append("  \(group.kind):")
            for row in group.rows {
                out.append("    \(row.gate.displayName) — \(row.verdict.reason ?? "no reason recorded")")
            }
        }
        return out
    }
}

#endif

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
/// probe, a media pass, and a keyed sealed-column pass funded by a hub unlock. One timestamp over
/// all of that would let a reader months later pair a census figure with a pass that ran after it.
///
/// ## Invariants
/// - A row that folds two observations MUST print both stamps.
/// - A row whose stamps are out of the order the gate requires — a marker census taken BEFORE the
///   keyed pass it is quoted beside — renders that ordering as a caveat and refuses to discharge,
///   rather than silently pairing them.
nonisolated struct Phase3Stamp: Sendable, Equatable {
    /// What was observed, in the readout's own words ("marker census", "keyed sealed-column pass").
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
    /// (Docs/Plan-Crypto-Standardization-2026-08-27.md §Phase 3, plus §4's sealed-photo exception).
    var gateWording: String {
        switch self {
        case .sealedColumns:
            return "census unprefixed == 0 on a real upgraded device, AND a FRESH keyed migrator"
                + " pass — run at gate time, after this sitting's latch reset — whose final result"
                + " isClean. That is the second witness that resolves the collided ~1-in-256 marker"
                + " sliver a keyless census can never close; a pass quoted from earlier in the"
                + " process does not discharge it, and neither half means anything over a corpus"
                + " that holds no sealed values."
        case .pendingNarrativeBuffer:
            return "census legacyCount == 0; an unreadable buffer is not a zero."
        case .mediaAtRest:
            return "the latch set on a real upgraded device, AND the census's unprefixed count equal"
                + " to that device's audited named residues, AND hasBlindSpots false. A latch alone"
                + " does not discharge it, and neither does a raw census number without the residue"
                + " audit beside it."
        case .lockContentKeyWrap:
            return "the census reads 0 on a real upgraded device, either as a v2Marked row or as an"
                + " absent row with an EARNED reading. The 2.5 row-latch licenses nothing by itself."
                + " malformedEmpty and unreadable are not zeros."
        case .heartDropSidecars:
            return "zero legacySealed on the three MAIN rows (outbox, peer bundles, dedup)."
                + " outboxQuarantine is EXCLUDED: no reader ever opens the quarantine path."
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
/// completion bit, a keyed migrator pass, a network manifest read — and a row that does not say
/// which kind it rests on will be misread as all of them.
nonisolated enum Phase3GateWitness: String, Sendable, CaseIterable {
    /// The keyless marker-bytes census — exact for unprefixed, an upper bound for marked blobs.
    case markerCensus
    /// A persisted `FormatMigrationLatching` completion bit.
    case completionLatch
    /// A keyed `SealedColumnFormatMigrator` pass, funded by a live per-page content-key vend.
    case keyedMigratorPass
    /// A `MediaAtRestFormatMigrator.performPass()` result, taken without touching the latch.
    case mediaMigratorPass
    /// A sealed-photo manifest fetched from iCloud and opened — counts and version integers only.
    case manifestProbe
    /// A read-only CloudKit id enumeration for a corpus whose manifest did not come back.
    case bodyProbe
    /// A latch DERIVED from the same byte the census row already reads. Licenses nothing.
    case derivedRowLatch

    /// The witness kind's name on the row.
    var displayName: String {
        switch self {
        case .markerCensus: return "marker census (keyless)"
        case .completionLatch: return "completion latch"
        case .keyedMigratorPass: return "keyed migrator pass"
        case .mediaMigratorPass: return "media migrator pass"
        case .manifestProbe: return "iCloud manifest probe"
        case .bodyProbe: return "iCloud body-record probe"
        case .derivedRowLatch: return "derived row latch (not evidence)"
        }
    }

    /// What taking this witness COSTS — printed beside the kind, so a reader can tell a free local
    /// read from a network fetch or a pass that writes.
    var riskNote: String {
        switch self {
        case .markerCensus: return "free; reads at most four header bytes per blob, writes nothing"
        case .completionLatch: return "free; one UserDefaults or keychain read"
        case .keyedMigratorPass: return "converts anything convertible; needs a live hub unlock"
        case .mediaMigratorPass: return "converts anything convertible; never touches the latch"
        case .manifestProbe: return "network fetch plus one AES-GCM open per corpus; no writes"
        case .bodyProbe: return "network query for record ids only; no assets, no writes"
        case .derivedRowLatch: return "free; re-reads the census's own byte, so it licenses nothing"
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

/// What one sealed-column migration trigger produced — the witness `FernletStore` discards today.
///
/// ``revalidation`` is carried SEPARATELY from ``passes`` for one reason: `.confirmed` is the launch
/// path that logs NOTHING (`SealedColumnFormatMigrator.revalidate` returns `.confirmed` before any
/// `FernletAuditLog.log` line) and runs no keyed pass. A witness carrying `.confirmed` with an empty
/// ``passes`` therefore means "the latch was re-confirmed by a KEYLESS census; the collided-marker
/// sliver is unresolved" — a state that is completely invisible in the app today, and one a bare
/// `latch == true` would render as success.
nonisolated struct SealedColumnPassWitness: Sendable, Equatable {
    /// When this witness landed.
    let stamp: Phase3Stamp
    /// The §9 launch revalidation's outcome, or nil when no revalidation ran this trigger.
    let revalidation: SealedColumnFormatMigrator.RevalidationOutcome?
    /// Whether the run left the latch set.
    let latched: Bool
    /// Every keyed pass the run funded, in order. Empty for a revalidation-only or cancelled run.
    let passes: [SealedColumnMigrationResult]

    /// Creates a witness.
    init(
        stamp: Phase3Stamp,
        revalidation: SealedColumnFormatMigrator.RevalidationOutcome?,
        latched: Bool,
        passes: [SealedColumnMigrationResult]
    ) {
        self.stamp = stamp
        self.revalidation = revalidation
        self.latched = latched
        self.passes = passes
    }

    /// Whether this witness carries a KEYED pass — the only kind that resolves the collided sliver.
    var isKeyedWitness: Bool { !passes.isEmpty }

    /// The last pass's result, or nil for a passless witness.
    var finalPass: SealedColumnMigrationResult? { passes.last }

    /// Whether every pass in the run was clean.
    var everyPassClean: Bool { !passes.isEmpty && passes.allSatisfy(\.isClean) }
}

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
        if result.converted > 0 { named.append("converted \(result.converted)") }
        if result.convertedPlaintext > 0 { named.append("convertedPlaintext \(result.convertedPlaintext)") }
        if result.conversionFailures > 0 { named.append("conversionFailures \(result.conversionFailures)") }
        if result.indeterminate > 0 { named.append("indeterminate \(result.indeterminate)") }
        if result.legacyKeySealedOwnFile > 0 { named.append("legacyKeySealedOwnFile \(result.legacyKeySealedOwnFile)") }
        if result.skippedConcurrentlyModified > 0 {
            named.append("skippedConcurrentlyModified \(result.skippedConcurrentlyModified)")
        }
        if result.deferredOwnKeyMigrationIncomplete > 0 {
            named.append("deferredOwnKeyMigrationIncomplete \(result.deferredOwnKeyMigrationIncomplete)")
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

/// The seven completion bits, taken in one place with one stamp.
///
/// Every bit goes through an accessor that already exists, so no FernletKit module gains a new
/// public surface for this instrument. ``mediaAtRest`` in particular is rendered NOWHERE in the app
/// today — the app never constructs `MediaAtRestFormatMigrationLatch` outside
/// `MediaAtRestFormatMigrator.standard` — and reading it here is what closes the audit's blocker
/// that otherwise needs LLDB and a downloaded app container.
///
/// ``lockWrapRow`` is DERIVED and is not gate evidence: it re-reads the same keychain byte through
/// the same `LockWrapFormatCensus.classify` the census row uses, so quoting it as the gate would be
/// quoting the gate to itself (the plan says so in as many words). It is rendered anyway because the
/// two can only disagree if the keychain's answer changed between the reads — which makes a
/// disagreement a genuine signal, and is exactly why both must resolve the service string the same
/// way.
nonisolated struct Phase3LatchReadings: Sendable, Equatable {
    /// `SealedColumnMigrationLatch.isComplete`.
    let sealedColumn: Bool
    /// `PendingNarrativeBufferMigrationLatch.isComplete`.
    let pendingNarrativeBuffer: Bool
    /// `MediaAtRestFormatMigrationLatch.isComplete` — gate part (a) for the media surface.
    let mediaAtRest: Bool
    /// `OwnPhotoMigrationLatch.isComplete` — an INPUT to the media gate, never a seventh gate.
    let ownPhotoKey: Bool
    /// `HeartDropSidecarMigrationLatch.isComplete`.
    let heartDropSidecar: Bool
    /// `SealedPhotoBackupMigrationLatch.isComplete` — explicitly NOT the sealed-photo gate.
    let sealedPhotoBackup: Bool
    /// `LockWrapRowLatch.isComplete` — derived, and not evidence. See the type doc.
    let lockWrapRow: Bool

    /// Creates a latch reading.
    init(
        sealedColumn: Bool,
        pendingNarrativeBuffer: Bool,
        mediaAtRest: Bool,
        ownPhotoKey: Bool,
        heartDropSidecar: Bool,
        sealedPhotoBackup: Bool,
        lockWrapRow: Bool
    ) {
        self.sealedColumn = sealedColumn
        self.pendingNarrativeBuffer = pendingNarrativeBuffer
        self.mediaAtRest = mediaAtRest
        self.ownPhotoKey = ownPhotoKey
        self.heartDropSidecar = heartDropSidecar
        self.sealedPhotoBackup = sealedPhotoBackup
        self.lockWrapRow = lockWrapRow
    }

    /// Takes all seven bits.
    ///
    /// The keychain service is threaded from the SAME ``CryptoFormatCensus/Inputs`` the scan used
    /// rather than re-spelled here. The census's own recorded hazard is the reason: a re-spelled
    /// constant is not READ from the service, so nothing makes the two readers keep agreeing — and
    /// two readers that diverge either agree by making the same mistake or disagree for a reason
    /// that is not a signal.
    ///
    /// Blocking: six `UserDefaults` reads and one keychain read. Call it off the main actor beside
    /// the census scan.
    static func take(inputs: CryptoFormatCensus.Inputs, defaults: UserDefaults = .standard) -> Phase3LatchReadings {
        Phase3LatchReadings(
            sealedColumn: SealedColumnFormatMigrator.latch(defaults: defaults).isComplete,
            // The two `Migrator.latch(defaults:)` accessors for these surfaces are `@MainActor`
            // (their migrators are), and this reading is taken off the main actor beside the census
            // scan. Both latch TYPES are `public nonisolated` with the same `init(defaults:)`, so
            // the bit is read through the type rather than by hopping actors for a `UserDefaults`
            // read — the same spelling `MediaAtRestFormatMigrationLatch` already needs here.
            pendingNarrativeBuffer: PendingNarrativeBufferMigrationLatch(defaults: defaults).isComplete,
            mediaAtRest: MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete,
            ownPhotoKey: OwnPhotoKeyMigrator.latch(defaults: defaults).isComplete,
            heartDropSidecar: HeartDropSidecarMigrationLatch(defaults: defaults).isComplete,
            sealedPhotoBackup: SealedPhotoBackupMigrationLatch(defaults: defaults).isComplete,
            lockWrapRow: LockWrapRowLatch(keychainService: inputs.lockKeychainService).isComplete
        )
    }

    /// The seven bits as report lines, in a fixed order, each naming the latch it came from.
    var printedLines: [String] {
        [
            "sealedColumn: \(sealedColumn)",
            "pendingNarrativeBuffer: \(pendingNarrativeBuffer)",
            "mediaAtRest: \(mediaAtRest)",
            "ownPhotoKey (input, not a gate): \(ownPhotoKey)",
            "heartDropSidecar: \(heartDropSidecar)",
            "sealedPhotoBackup (not the gate): \(sealedPhotoBackup)",
            "lockWrapRow (derived, not evidence): \(lockWrapRow)"
        ]
    }
}

// MARK: - The readout

/// Everything the fold needs, as one `Sendable` value.
///
/// A separate input type rather than the `@MainActor @Observable` session itself, so the fold stays
/// a pure function the tests can drive with hand-built fixtures and no store. The session's
/// ``Phase3ReadoutSession/inputs(environment:ownPhotoDocumentsDirectory:friendWallSupportDirectory:sealedColumnWitness:sealedColumnPassInFlight:)``
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
    /// The seven latch bits, or nil when the local scan has not landed.
    var latches: Phase3LatchReadings?
    /// When the latches were read.
    var latchStamp: Phase3Stamp?
    /// The seven bits as they read BEFORE a reset was taken this sitting, when one was.
    var preResetLatchSnapshot: Phase3LatchReadings?
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
    /// Whether a keyed sealed-column pass was running at any point while the census scan ran.
    ///
    /// Recorded at scan START and again at LANDING, because the render-time flag says nothing about
    /// the window the bytes were read in — and the verdict's own sentence claims it does.
    var censusOverlappedKeyedPass: Bool
    /// The last own-photo full-verification pass's per-corpus verdicts — a BY-PRODUCT of a writing
    /// pass, never the gate. Its `examined` bit is the "never looked / examined-none" fact a live
    /// probe structurally cannot produce.
    var sealedPhotoFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]?
    /// The retained sealed-column witness, or nil when no trigger ran this process.
    var sealedColumnWitness: SealedColumnPassWitness?
    /// Whether a sealed-column run is in flight — a discharge is refused outright while it is.
    var sealedColumnPassInFlight: Bool
    /// When the sealed-column latch was reset this sitting, if it was.
    var sealedColumnResetTakenAt: Date?
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
        preResetLatchSnapshot: Phase3LatchReadings? = nil,
        manifestProbes: [Phase3ManifestProbe] = [],
        bodyProbes: [SealedPhotoCorpus: BodyProbeReading] = [:],
        mediaWitness: MediaPassWitness? = nil,
        mediaPassInFlight: Bool = false,
        mediaLaunchPass: MediaLaunchPassRecord? = nil,
        censusOverlappedKeyedPass: Bool = false,
        sealedPhotoFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]? = nil,
        sealedColumnWitness: SealedColumnPassWitness? = nil,
        sealedColumnPassInFlight: Bool = false,
        sealedColumnResetTakenAt: Date? = nil,
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
        self.preResetLatchSnapshot = preResetLatchSnapshot
        self.manifestProbes = manifestProbes
        self.bodyProbes = bodyProbes
        self.mediaWitness = mediaWitness
        self.mediaPassInFlight = mediaPassInFlight
        self.mediaLaunchPass = mediaLaunchPass
        self.censusOverlappedKeyedPass = censusOverlappedKeyedPass
        self.sealedPhotoFullPassVerdicts = sealedPhotoFullPassVerdicts
        self.sealedColumnWitness = sealedColumnWitness
        self.sealedColumnPassInFlight = sealedColumnPassInFlight
        self.sealedColumnResetTakenAt = sealedColumnResetTakenAt
        self.checklist = checklist
        self.refusals = refusals
    }
}

/// One sitting's whole reading: every stamp taken, the environment, six gate rows, and the
/// pre-reset latch snapshot when a reset was taken.
///
/// There is no single `takenAt` — see ``Phase3Stamp``.
nonisolated struct Phase3GateReadout: Sendable, Equatable {
    /// Every stamp taken this sitting, in acquisition order.
    let stamps: [Phase3Stamp]
    /// The device and preference context.
    let environment: Phase3GateEnvironment
    /// One row per gate, in ``Phase3Gate/allCases`` order.
    let rows: [Phase3GateRow]
    /// The seven bits as they read before the one reset this design offers, when it was taken.
    let preResetLatchSnapshot: Phase3LatchReadings?
    /// When the sealed-column latch was reset this sitting. Carried so the export can say the
    /// pre-reset snapshot was NOT captured, rather than omitting the section and saying nothing.
    let sealedColumnResetTakenAt: Date?
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
        preResetLatchSnapshot: Phase3LatchReadings?,
        sealedColumnResetTakenAt: Date? = nil,
        checklist: [Phase3SittingStep],
        refusals: [String],
        mediaAudit: MediaResidueAudit?,
        manifestProbes: [Phase3ManifestProbe]
    ) {
        self.stamps = stamps
        self.environment = environment
        self.rows = rows
        self.preResetLatchSnapshot = preResetLatchSnapshot
        self.sealedColumnResetTakenAt = sealedColumnResetTakenAt
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
            preResetLatchSnapshot: inputs.preResetLatchSnapshot,
            sealedColumnResetTakenAt: inputs.sealedColumnResetTakenAt,
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
            preResetLatchSnapshot: nil,
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
        if let witness = inputs.sealedColumnWitness { taken.append(witness.stamp) }
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
            row(forSealedColumns: census.sealedColumns, latch: latches.sealedColumn,
                witness: inputs.sealedColumnWitness, censusStamp: inputs.censusStamp,
                passInFlight: inputs.sealedColumnPassInFlight,
                overlappedKeyedPass: inputs.censusOverlappedKeyedPass,
                resetTakenAt: inputs.sealedColumnResetTakenAt),
            row(forPendingNarrative: census.pendingNarrative, latch: latches.pendingNarrativeBuffer,
                stamp: inputs.censusStamp),
            row(forMedia: audit, latches: latches, witness: inputs.mediaWitness,
                passInFlight: inputs.mediaPassInFlight, censusStamp: inputs.censusStamp,
                launchPass: inputs.mediaLaunchPass),
            row(forLockWrap: census.lockWrap, rowLatch: latches.lockWrapRow,
                lockConfigured: inputs.environment.lockConfigured, stamp: inputs.censusStamp),
            row(forHeartDrop: census.heartDrop, latch: latches.heartDropSidecar, stamp: inputs.censusStamp),
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

    /// The sealed-column gate: two witnesses side by side, and a discharge only when BOTH answer.
    ///
    /// Four distinct non-discharges, each named rather than collapsed: no keyed pass ran; a KEYLESS
    /// revalidation confirmed the latch and left the collided sliver unresolved; the hub re-locked
    /// mid-pass (a clean stop, not a witness); and a pass that ran and was not clean.
    static func row(
        forSealedColumns outcome: CryptoFormatCensus.SealedColumnOutcome,
        latch: Bool,
        witness: SealedColumnPassWitness?,
        censusStamp: Phase3Stamp?,
        passInFlight: Bool,
        overlappedKeyedPass: Bool = false,
        resetTakenAt: Date? = nil
    ) -> Phase3GateRow {
        var stamps: [Phase3Stamp] = []
        if let censusStamp { stamps.append(censusStamp) }
        if let witness { stamps.append(witness.stamp) }
        return Phase3GateRow(
            gate: .sealedColumns,
            witnesses: [.markerCensus, .keyedMigratorPass, .completionLatch],
            stamps: stamps,
            verdict: sealedColumnVerdict(outcome, witness: witness, censusStamp: censusStamp,
                                         passInFlight: passInFlight,
                                         overlappedKeyedPass: overlappedKeyedPass,
                                         resetTakenAt: resetTakenAt),
            evidence: sealedColumnEvidence(outcome, latch: latch, witness: witness),
            caveats: sealedColumnCaveats(outcome, witness: witness, censusStamp: censusStamp)
        )
    }

    private static func sealedColumnVerdict(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome,
        witness: SealedColumnPassWitness?,
        censusStamp: Phase3Stamp?,
        passInFlight: Bool,
        overlappedKeyedPass: Bool,
        resetTakenAt: Date?
    ) -> Phase3GateVerdict {
        guard case let .counted(result) = outcome else {
            guard case let .failed(reason) = outcome else { return .notTaken("no census reading") }
            return .unavailable("the sealed store could not be censused: \(reason). This is not a zero.")
        }
        guard !passInFlight, !overlappedKeyedPass else {
            return .notTaken("a keyed pass was writing the corpus while this scan ran, so the marker"
                + " counts are neither the before nor the after state. Re-take the local scan once"
                + " the pass has landed.")
        }
        guard let witness, let final = witness.finalPass else {
            return .notTaken(passlessReason(witness))
        }
        guard !final.stoppedOnlyByKeyRevocation else {
            return .notTaken("the hub re-locked mid-pass — a clean stop, not a witness. Turn Auto-Lock"
                + " off and re-arm the pass.")
        }
        guard final.isClean else { return .blocked(blockingDescription(final)) }
        if let stale = sealedColumnFreshnessRefusal(witness, resetTakenAt: resetTakenAt) { return stale }
        return dischargeSealedColumns(result, witness: witness, censusStamp: censusStamp)
    }

    /// The plan's "a FRESH clean keyed pass run at GATE TIME — never this latch quoted from memory".
    ///
    /// Without this, any keyed witness the process happens to hold discharges the row: a pass run at
    /// the first hub unlock of the day, hours before the sitting, satisfies the ordering rule the
    /// moment the census is re-taken — while proving nothing about the rows written since. Those
    /// rows matter: `ColumnCrypto.sealPlaintext` still fails open to an unprefixed legacy write when
    /// the device binding cannot be read, and ~1 in 256 of those collides with a marker byte and is
    /// invisible to `unprefixed == 0`. Resolving that sliver is the keyed pass's whole job.
    private static func sealedColumnFreshnessRefusal(
        _ witness: SealedColumnPassWitness,
        resetTakenAt: Date?
    ) -> Phase3GateVerdict? {
        guard let resetAt = resetTakenAt else {
            return .notTaken("no latch reset was taken this sitting, so the keyed pass beside this"
                + " census is one the process happened to have — not a pass run at gate time. Reset"
                + " the latch here, dismiss Settings, open the Private tab and unlock (step 7).")
        }
        guard witness.stamp.takenAt > resetAt else {
            return .notTaken("the keyed pass (\(witness.stamp.printed)) predates this sitting's latch"
                + " reset (\(resetAt.ISO8601Format())), so it says nothing about rows written since."
                + " Complete step 7.")
        }
        return nil
    }

    /// Why a witness carries no keyed pass — the state that is completely silent in the app today.
    private static func passlessReason(_ witness: SealedColumnPassWitness?) -> String {
        guard let witness else { return "no keyed pass ran this process" }
        guard witness.revalidation == .confirmed else {
            return "no keyed pass ran this process (revalidation:"
                + " \(witness.revalidation.map { "\($0)" } ?? "none"))"
        }
        return "the latch was re-confirmed by a KEYLESS census at launch; no keyed pass ran, so the"
            + " census's ~1-in-256 collided-marker sliver is unresolved"
    }

    /// The last clause: a marker zero taken AT OR AFTER the pass that could have changed it, over a
    /// corpus that held something to count.
    private static func dischargeSealedColumns(
        _ result: SealedColumnFormatCensusResult,
        witness: SealedColumnPassWitness,
        censusStamp: Phase3Stamp?
    ) -> Phase3GateVerdict {
        let unprefixed = result.total.unprefixed
        guard unprefixed == 0 else {
            return .blocked("the marker census still counts \(unprefixed) unprefixed column values")
        }
        guard !result.truncated else {
            return .unavailable("the marker census stopped at its \(result.rowCap)-row cap after"
                + " \(result.rowsScanned) of \(result.rowsAvailable) rows, so its zero describes a"
                + " SUBSET of the corpus and says nothing about the rows it never reached.")
        }
        guard let censusStamp else { return .notTaken("no census stamp, so the two halves cannot be ordered") }
        guard censusStamp.takenAt >= witness.stamp.takenAt else {
            return .notTaken("the marker census was taken BEFORE the keyed pass beside it, so the"
                + " zero it reports is not a reading of the corpus the pass left. Retake the census.")
        }
        return emptyCorpusRefusal(result) ?? .discharged
    }

    /// The `.vacuous` branch the sealed-column row was missing: both halves are trivially satisfied
    /// over a corpus that holds nothing.
    ///
    /// The census's tally is empty, so `unprefixed == 0`; `SealedColumnMigrationResult.isClean` is
    /// `converted == 0 && blocking == 0 && notAttemptedTotal == 0 && …`, all satisfied by a pass over
    /// zero pages — which also means the per-page content key was never vended, so that "keyed" pass
    /// opened NOTHING and resolved none of the collided-marker sliver it exists for. `emptyOrNil` is
    /// counted separately from `unprefixed`, so a store with rows whose sealed columns are all nil
    /// reads a healthy non-zero row count and is the variant a bare `rowsAvailable > 0` floor misses.
    private static func emptyCorpusRefusal(_ result: SealedColumnFormatCensusResult) -> Phase3GateVerdict? {
        let classified = result.total
        let sealedValues = classified.total - classified.emptyOrNil
        guard result.rowsAvailable == 0 || sealedValues == 0 else { return nil }
        return .vacuous("the sealed corpora hold \(result.rowsAvailable) rows and \(sealedValues)"
            + " sealed column values, so the census's zero and the keyed pass's clean verdict are"
            + " both over an EMPTY corpus. With no page to sweep the pass never vended the content"
            + " key — it opened nothing and resolved none of the ~1-in-256 collided-marker sliver."
            + " Read this gate on a device that actually holds sealed journal / cycle / intimacy /"
            + " worry text.")
    }

    private static func sealedColumnEvidence(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome,
        latch: Bool,
        witness: SealedColumnPassWitness?
    ) -> [String] {
        var lines: [String] = []
        if case let .counted(result) = outcome {
            let tally = result.total
            lines.append("marker census: legacy \(tally.unprefixed) exact · v3 <=\(tally.v3Marked)"
                + " / v2 <=\(tally.v2Marked) upper bounds · indeterminate \(tally.indeterminate)"
                + " · empty \(tally.emptyOrNil) · scanned \(result.rowsScanned) of \(result.rowsAvailable)"
                + " rows · truncated \(result.truncated)")
        }
        lines.append("completion latch: \(latch)")
        lines.append(contentsOf: sealedColumnWitnessLines(witness))
        return lines
    }

    private static func sealedColumnWitnessLines(_ witness: SealedColumnPassWitness?) -> [String] {
        guard let witness else { return ["keyed pass: no trigger ran this process"] }
        var lines = [
            "keyed pass: \(witness.passes.count) pass(es), latched \(witness.latched),"
                + " revalidation \(witness.revalidation.map { "\($0)" } ?? "none")"
        ]
        // R2: bounded by `SealedColumnFormatMigrator.maxMigrationPasses`.
        for (index, pass) in witness.passes.enumerated() {
            lines.append("  pass \(index + 1): converted \(pass.convertedTotal) · blocking"
                + " \(pass.total.blocking) · notAttempted \(pass.notAttemptedTotal)"
                + " · rows \(pass.rowsScanned)/\(pass.rowsAvailable) · truncated \(pass.truncated)"
                + " · abortedNoBinding \(pass.abortedNoBinding) · aborted \(pass.aborted)"
                + " · isClean \(pass.isClean) · madeForwardProgress \(pass.madeForwardProgress)"
                + " · stoppedOnlyByKeyRevocation \(pass.stoppedOnlyByKeyRevocation)")
            lines.append(contentsOf: sealedColumnPerColumnLines(pass))
        }
        return lines
    }

    private static func sealedColumnPerColumnLines(_ pass: SealedColumnMigrationResult) -> [String] {
        // R2: bounded by the census's fixed column table.
        pass.columns.keys.sorted().compactMap { identifier in
            guard let tally = pass.columns[identifier] else { return nil }
            return "    \(identifier): openedV3 \(tally.openedV3) · fromV2 \(tally.convertedFromV2)"
                + " · fromUnprefixed \(tally.convertedFromLegacyUnprefixed)"
                + " · fromCollided \(tally.convertedFromLegacyCollided)"
                + " · indeterminate \(tally.indeterminate) · bindingReadError \(tally.bindingReadError)"
                + " · unopenableUnprefixed \(tally.unopenableUnprefixed)"
                + " · unopenableMarked \(tally.unopenableMarked)"
                + " · skippedConcurrentlyModified \(tally.skippedConcurrentlyModified)"
                + " · clearedDuringReadBack \(tally.clearedDuringReadBack)"
                + " · convertFailures \(tally.convertFailures) · readBackFailed \(tally.readBackFailed)"
        }
    }

    private static func sealedColumnCaveats(
        _ outcome: CryptoFormatCensus.SealedColumnOutcome,
        witness: SealedColumnPassWitness?,
        censusStamp: Phase3Stamp?
    ) -> [String] {
        var caveats = [
            "The keyed pass is the SECOND witness and it cannot be funded from Settings: Settings is"
                + " reached from Home, where the hub is always re-locked, so the content-key vend"
                + " answers nil there. Reset the latch here, dismiss Settings, open the Private tab"
                + " and unlock — the shipped trigger funds the pass ~300 ms after the unlock, and a"
                + " cancelled grace records an EMPTY run (which never displaces a keyed witness)."
        ]
        if case let .counted(result) = outcome {
            let marked = result.total.v3Marked + result.total.v2Marked
            if marked > 0 {
                caveats.append("0 is necessary, not sufficient: up to \(marked) marked blobs could be"
                    + " collided legacy (a legacy nonce's first byte hits a marker ~1/256). Only the"
                    + " keyed pass resolves that sliver.")
            }
        }
        if let witness, let censusStamp, censusStamp.takenAt < witness.stamp.takenAt {
            caveats.append("ORDERING: the census stamp (\(censusStamp.printed)) precedes the keyed-pass"
                + " stamp (\(witness.stamp.printed)). The two halves are NOT paired.")
        }
        caveats.append("Auto-Lock must be off: the key is re-vended per page, so a screen lock ends"
            + " the sweep fail-closed as stoppedOnlyByKeyRevocation.")
        return caveats
    }

    /// Every blocking bucket a sealed-column pass hit, by name.
    private static func blockingDescription(_ pass: SealedColumnMigrationResult) -> String {
        var named: [String] = []
        let folded = pass.total
        if folded.converted > 0 { named.append("converted \(folded.converted)") }
        if folded.indeterminate > 0 { named.append("indeterminate \(folded.indeterminate)") }
        if folded.bindingReadError > 0 { named.append("bindingReadError \(folded.bindingReadError)") }
        if folded.unopenableUnprefixed > 0 { named.append("unopenableUnprefixed \(folded.unopenableUnprefixed)") }
        if folded.unopenableMarked > 0 { named.append("unopenableMarked \(folded.unopenableMarked)") }
        if folded.skippedConcurrentlyModified > 0 {
            named.append("skippedConcurrentlyModified \(folded.skippedConcurrentlyModified)")
        }
        if folded.clearedDuringReadBack > 0 { named.append("clearedDuringReadBack \(folded.clearedDuringReadBack)") }
        if folded.convertFailures > 0 { named.append("convertFailures \(folded.convertFailures)") }
        if folded.readBackFailed > 0 { named.append("readBackFailed \(folded.readBackFailed)") }
        if pass.notAttemptedTotal > 0 { named.append(notAttemptedDescription(pass)) }
        if pass.truncated { named.append("truncated") }
        if pass.abortedNoBinding { named.append("abortedNoBinding") }
        if pass.aborted { named.append("aborted") }
        let joined = named.isEmpty ? "the pass reported isClean == false with no named bucket" : named.joined(separator: ", ")
        return "the keyed pass ran and was not clean: \(joined)"
    }

    private static func notAttemptedDescription(_ pass: SealedColumnMigrationResult) -> String {
        // R2: bounded by `SealedColumnNotAttemptedReason.allCases`.
        let named = SealedColumnNotAttemptedReason.allCases.compactMap { reason -> String? in
            guard let count = pass.notAttempted[reason], count > 0 else { return nil }
            return "\(reason.rawValue) \(count)"
        }
        return "notAttempted(" + named.joined(separator: " ") + ")"
    }

    // MARK: Pending narrative buffer

    /// The buffer gate: the census reading IS the gate, so the row only applies the rule.
    ///
    /// `.absent` discharges as an EARNED zero — the buffer's drain-and-purge lifecycle makes absence
    /// real evidence, and `saveEntries` can only re-create the file in v2. `.unreadable` is
    /// `.unavailable`, carrying the census's own wording: it is not a zero.
    static func row(
        forPendingNarrative census: PendingNarrativeBufferFormatCensus,
        latch: Bool,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .pendingNarrativeBuffer,
            witnesses: [.markerCensus, .completionLatch],
            stamps: stamp.map { [$0] } ?? [],
            verdict: pendingNarrativeVerdict(census),
            evidence: [
                "\(census.fileURL.lastPathComponent): \(pendingNarrativeState(census))",
                "legacyCount: \(census.legacyCount.map(String.init) ?? "—")",
                "completion latch (a launch-pass record, not the gate): \(latch)"
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
        return .discharged
    }

    /// The three ways this row's own inputs disqualify themselves before the latch is even consulted.
    ///
    /// The first is the one that authorizes a false pass. `MediaAtRestFormatMigrationResult.isClean`
    /// requires `converted == 0 && convertedPlaintext == 0`, and a converting pass rewrites those
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
        lines.append("ownPhotoKeyMigrationComplete (an INPUT to this gate, never a seventh gate):"
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
    /// beside it — and `converted` / `convertedPlaintext`, the two that a re-taken census erases,
    /// appeared on no line of the row or the export at all.
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
            "An unprefixed byte in a born-sealed corpus is NOT automatically blocking:"
                + " unopenableUnprefixed is deliberately absent from the pass's isClean, and"
                + " dispatchUnprefixedWall routes an unopenable wall byte straight into it. Those"
                + " bytes were read, every key the legacy branch could pair them with was tried, and"
                + " nothing opens them — so deleting the legacy branch cannot change what a reader gets."
        ]
        guard let audit else { return caveats }
        if audit.keylessWallSignature {
            caveats.append("Residue C's SHAPE is present: wall photo/thumbnail locations hold plaintext"
                + " JPEGs while the media latch is open — the abortedNoWallKey signature. A plaintext"
                + " JPEG is census class plaintextJPEG, never unprefixed, so it contributes ZERO to"
                + " the arithmetic above.")
        }
        if let disagreement = audit.examinedDisagreementCaveat { caveats.append(disagreement) }
        if !latches.ownPhotoKey {
            caveats.append("The own-photo KEY latch is unset, so the format pass defers own-root"
                + " unprefixed candidates (deferredOwnKeyMigrationIncomplete) rather than converting them.")
        }
        return caveats
    }

    // MARK: Lock wrap

    /// The wrap gate, with the reviewer's earned-absence rule applied.
    ///
    /// `.absent` discharges ONLY alongside `isLockConfigured == false`. The census has no choice but
    /// to print all three absences — it is a keychain-only reader — but the readout holds
    /// `FernletLockService`, and one public property collapses the three-way ambiguity to two.
    /// Discharging over an unresolved absence whose third reading is "a wrap that has gone missing,
    /// which is a fault" would be an unearned zero on the surface whose own doc warns that
    /// collapsing "could not read" into "not there" is what licenses Phase 3 to lock a user out.
    static func row(
        forLockWrap report: LockWrapFormatCensusReport,
        rowLatch: Bool,
        lockConfigured: Bool,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .lockContentKeyWrap,
            witnesses: [.markerCensus, .derivedRowLatch],
            stamps: stamp.map { [$0] } ?? [],
            verdict: lockWrapVerdict(report, lockConfigured: lockConfigured),
            evidence: [
                "\(report.account): \(lockWrapState(report))",
                "legacyWrapCount: \(report.legacyWrapCount.map(String.init) ?? "—")",
                "isLockConfigured: \(lockConfigured)",
                "LockWrapRowLatch.isComplete (DERIVED — not evidence): \(rowLatch)"
            ],
            caveats: lockWrapCaveats(report, rowLatch: rowLatch)
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

    private static func lockWrapCaveats(_ report: LockWrapFormatCensusReport, rowLatch: Bool) -> [String] {
        var caveats = [
            "The row latch licenses NOTHING by itself: it re-reads the same keychain byte through the"
                + " same LockWrapFormatCensus.classify this row uses, so quoting it as the gate would"
                + " be quoting the gate to itself. It is printed because the two can only disagree if"
                + " the keychain's answer changed between the reads — which makes a disagreement a"
                + " genuine signal.",
            "No pass can be funded for this surface at all: the migrator is credential-gated by"
                + " construction (no initializer that does not take the recovered content key and the"
                + " just-derived wrapping key), and markComplete()/reset() are documented no-ops on"
                + " this latch — so the absence of a button here is a decision, not a gap."
        ]
        let censusSaysComplete = report.state == .absent || report.state == .v2Marked
        if censusSaysComplete != rowLatch {
            caveats.append("The census row and the derived latch DISAGREE. They read the same byte,"
                + " so the keychain's answer changed between the two reads — retake both.")
        }
        return caveats
    }

    // MARK: Heart-drop sidecars

    /// The sidecar gate applied PER ROW, with the quarantine visibly excluded.
    ///
    /// The census already prints every file's state, so the plan's per-row gate is applicable today
    /// — but a reader has to apply "three main rows, quarantine excluded" by eye off a `·`-joined
    /// line, against an aggregate `legacySealedCount` that INCLUDES the quarantine. This applies the
    /// rule and says which files it applied it to.
    static func row(
        forHeartDrop report: HeartDropSidecarFormatCensus.Report,
        latch: Bool,
        stamp: Phase3Stamp?
    ) -> Phase3GateRow {
        Phase3GateRow(
            gate: .heartDropSidecars,
            witnesses: [.markerCensus, .completionLatch],
            stamps: stamp.map { [$0] } ?? [],
            verdict: heartDropVerdict(report),
            evidence: heartDropEvidence(report, latch: latch),
            caveats: [
                "outboxQuarantine is EXCLUDED from the verdict, and the plan's reason is the whole"
                    + " point: no reader ever opens the quarantine path, so a legacy tombstone there"
                    + " is not a reader dependency — folding it into an aggregate would strand the"
                    + " gate forever on bytes whose format cannot matter.",
                "No control is offered: this surface re-surveys the disk on EVERY launch and"
                    + " self-invalidates when any main row blocks, so resetting the latch buys no"
                    + " observation the next launch would not already produce."
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
        return .discharged
    }

    private static func heartDropEvidence(
        _ report: HeartDropSidecarFormatCensus.Report,
        latch: Bool
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
        lines.append("launch latch (this surface re-surveys every launch anyway): \(latch)")
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
        out.append(contentsOf: preResetLines(readout.preResetLatchSnapshot,
                                             resetTakenAt: readout.sealedColumnResetTakenAt))
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

    private static func preResetLines(
        _ snapshot: Phase3LatchReadings?,
        resetTakenAt: Date?
    ) -> [String] {
        guard let snapshot else {
            // Nothing-silent: the reset dialog promises "the pre-reset value of all seven latches is
            // captured into the report first". An omitted section would let an unkept promise read
            // as an untaken reset.
            guard let resetTakenAt else { return [] }
            return ["", "LATCHES AS THEY READ BEFORE THE RESET TAKEN THIS SITTING",
                    "  NOT CAPTURED — the reset at \(resetTakenAt.ISO8601Format()) was taken before"
                        + " the local scan had landed, so the seven pre-reset bits for this device"
                        + " are gone for this sitting."]
        }
        var out = ["", "LATCHES AS THEY READ BEFORE THE RESET TAKEN THIS SITTING"]
        // R2: bounded by the seven printed bits.
        for line in snapshot.printedLines { out.append("  \(line)") }
        return out
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

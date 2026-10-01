import CloudKitSync
import Foundation

/// The set this install last committed or merged for one payload, as the E2 compare-and-swap
/// remembers it (design 2026-09-30, §4.3): its stamp and the first 8 bytes of its key salt.
///
/// The salt prefix lets E2 recognise its own unchanged head from the record METADATA alone (the
/// generation and salt are plaintext CloudKit fields), so a clean visit decrypts nothing (§4.2 X5).
struct SealedBackupAcceptedHead: Equatable, Sendable {
    /// The accepted set's writer and generation.
    var stamp: SealedBackupHeadStamp
    /// The first 8 bytes of the set's key salt, lowercase hex ("" for a v1 set, which has no salt).
    var saltPrefix: String

    /// Creates an accepted head.
    init(stamp: SealedBackupHeadStamp, saltPrefix: String) {
        self.stamp = stamp
        self.saltPrefix = saltPrefix
    }

    /// The hex prefix ``saltPrefix`` holds for a record's key salt.
    static func saltPrefix(of keySalt: Data) -> String {
        keySalt.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `record`'s metadata (generation and salt prefix) is this accepted head's — the
    /// "unchanged" row of §5.5, decided without opening anything. A set with no salt (a format-v1
    /// record from before per-set salts) never matches: its generation alone cannot tell two sets
    /// apart, so another iPhone's set at the same number would read as accepted (review B1-D-B1-R4).
    func matchesMetadata(of record: SealedBackupRecord) -> Bool {
        !saltPrefix.isEmpty && record.generation == stamp.generation && Self.saltPrefix(of: record.keySalt) == saltPrefix
    }
}

/// The Sealed backup v2 per-payload, per-install bookkeeping (design 2026-09-30, §4.3): the restore
/// marker, the accepted head, the observed foreign head and the in-flight generation, for every payload
/// on v2. One type for all of them; standard defaults, injected so tests get an isolated suite.
///
/// | Payload | Resolved marker (`Bool`) | Accepted head (`String`) | Observed head (`String`) | In-flight generation (`String`) |
/// | --- | --- | --- | --- | --- |
/// | periodData | `fernlet.cycleRecord.periodRestoreResolved` | `fernlet.sealedBackup.periodAcceptedHead` | `fernlet.sealedBackup.periodObservedHead` | `fernlet.sealedBackup.periodInFlight` |
/// | intimacyLogs | `fernlet.intimacyLog.restoreResolved` | `fernlet.sealedBackup.intimacyAcceptedHead` | `fernlet.sealedBackup.intimacyObservedHead` | `fernlet.sealedBackup.intimacyInFlight` |
/// | journalNarratives | `fernlet.journalNarrative.restoreResolved` | `fernlet.sealedBackup.journalAcceptedHead` | `fernlet.sealedBackup.journalObservedHead` | `fernlet.sealedBackup.journalInFlight` |
///
/// The retired `sensitiveNotes` payload is never on v2: its arm answers "nothing recorded" and writes
/// nothing.
///
/// - **Marker.** Unresolved means "this install has not pulled this payload's backup". It resolves
///   only on a restore outcome of `.restored` or `.nothingToRestore`, or when a confirmed "Replace" or
///   "Start a new backup" commits — **never** because sync or the backup is off (R1-BR-2, R2-F4). An
///   absent key is seeded ONCE from the payload's legacy divergence latch (the period's is
///   `fernlet.menstrualNarrative.everStored`, the intimate logs' `fernlet.intimacyLog.everStored`, the
///   journal's `fernlet.journalNarrative.everStored`) and written, so a later write can never seed it
///   again.
///   Clearing writes `false`, never removes the key.
/// - **Accepted head** `"<acceptor>:<writer>:<generation>:<salt8>"`. `acceptor` is this install's
///   writer tag when it was recorded; the value reads as ABSENT when the acceptor is not this
///   install's current tag (or the value does not parse), so one that travelled inside a device backup
///   can never make another iPhone's head look accepted (R1-BR-2). Kept by "Delete everything"
///   (R2-F11).
/// - **Observed head** `"<acceptor>:<writer>:<generation>"`: the foreign head E2 or the restore last
///   found, so Privacy & Data can name it after a relaunch (R2-F13b) and turning the backup off can
///   keep another iPhone's slot (R2-F3). Install-bound like the accepted head; cleared when the head
///   becomes own or accepted, and by "Delete everything".
/// - **In-flight generation** `"<acceptor>:<generation>"`: the highest generation this install's
///   commits ever set out to save, recorded BEFORE each commit's first save (review B1-C-B1-2 /
///   B1-D-B1-R2). E2 counts a head under this install's own writer tag (or a v1 head under its own
///   signing key) as its own only up to the highest of the rollback floor, the accepted head and this
///   value: a head numbered above all three was written by this install AFTER the state it now holds
///   — an iPhone put back from an older device backup of itself (the writer tag and the signing key
///   are ThisDeviceOnly, so they come back with it) — and is merged before anything is exported over
///   it. It is not the rollback floor: a commit that never landed raises nothing a restore checks
///   (R1-BR-4). Install-bound and only ever raised. Nothing clears it but an uninstall: it states
///   only what this install wrote, which no wipe, reset or turn-off makes untrue — and a set that
///   survives a "Delete everything" or turn-off delete must stay this install's own to overwrite,
///   never be merged back (R2-F11).
///
/// Every accessor is an exhaustive `switch` whose arms write their own key constant — never a key
/// returned and written elsewhere — so the persisted-surface wall resolves every key (R2-F16e). No
/// content: install tags, a counter and a salt prefix. Like the divergence latches it travels inside an
/// iCloud or Finder device backup, which is why the reset funnel and the "can't open" check clear it.
@MainActor
struct SealedBackupBookkeeping {
    /// The period restore marker's FROZEN key.
    static let periodRestoreResolvedKey = "fernlet.cycleRecord.periodRestoreResolved"
    /// The period accepted head's FROZEN key.
    static let periodAcceptedHeadKey = "fernlet.sealedBackup.periodAcceptedHead"
    /// The period observed head's FROZEN key.
    static let periodObservedHeadKey = "fernlet.sealedBackup.periodObservedHead"
    /// The period in-flight generation's FROZEN key.
    static let periodInFlightKey = "fernlet.sealedBackup.periodInFlight"
    /// The intimate-log restore marker's FROZEN key (design 2026-09-30, §4.3, unit B2).
    static let intimacyRestoreResolvedKey = "fernlet.intimacyLog.restoreResolved"
    /// The intimate-log accepted head's FROZEN key.
    static let intimacyAcceptedHeadKey = "fernlet.sealedBackup.intimacyAcceptedHead"
    /// The intimate-log observed head's FROZEN key.
    static let intimacyObservedHeadKey = "fernlet.sealedBackup.intimacyObservedHead"
    /// The intimate-log in-flight generation's FROZEN key.
    static let intimacyInFlightKey = "fernlet.sealedBackup.intimacyInFlight"
    /// The journal restore marker's FROZEN key (design 2026-09-30, §4.3, unit B3).
    static let journalRestoreResolvedKey = "fernlet.journalNarrative.restoreResolved"
    /// The journal accepted head's FROZEN key.
    static let journalAcceptedHeadKey = "fernlet.sealedBackup.journalAcceptedHead"
    /// The journal observed head's FROZEN key.
    static let journalObservedHeadKey = "fernlet.sealedBackup.journalObservedHead"
    /// The journal in-flight generation's FROZEN key.
    static let journalInFlightKey = "fernlet.sealedBackup.journalInFlight"

    /// The payloads whose backup runs on the v2 engine in this build, in the order a hub settle asks
    /// for them.
    static let v2Payloads: [SealedBackupPayloadType] = [.periodData, .intimacyLogs, .journalNarratives]

    /// Where the bookkeeping lives.
    let defaults: UserDefaults
    /// The legacy divergence latch per payload, read only while that payload's marker is absent — the
    /// one-time seed (period: `MenstrualNarrativeRepository.hasEverStoredNarrative`; intimate logs:
    /// `IntimacyLogStore.hasEverStoredLog`; journal: `JournalNarrativeRepository.hasEverStoredNarrative`).
    let legacyLatch: @MainActor (SealedBackupPayloadType) -> Bool

    /// Creates the bookkeeping.
    ///
    /// - Parameters:
    ///   - defaults: Where the keys live.
    ///   - legacyLatch: The one-time marker seed's source, per payload.
    init(defaults: UserDefaults, legacyLatch: @escaping @MainActor (SealedBackupPayloadType) -> Bool) {
        self.defaults = defaults
        self.legacyLatch = legacyLatch
    }

    // MARK: - Restore marker

    /// Whether `payload`'s restore is resolved, seeding an absent marker once from the legacy latch.
    func isRestoreResolved(_ payload: SealedBackupPayloadType) -> Bool {
        switch payload {
        case .periodData:
            if let decided = defaults.object(forKey: Self.periodRestoreResolvedKey) as? Bool { return decided }
            let seeded = legacyLatch(payload)
            defaults.set(seeded, forKey: Self.periodRestoreResolvedKey)
            return seeded
        case .intimacyLogs:
            if let decided = defaults.object(forKey: Self.intimacyRestoreResolvedKey) as? Bool { return decided }
            let seeded = legacyLatch(payload)
            defaults.set(seeded, forKey: Self.intimacyRestoreResolvedKey)
            return seeded
        case .journalNarratives:
            if let decided = defaults.object(forKey: Self.journalRestoreResolvedKey) as? Bool { return decided }
            let seeded = legacyLatch(payload)
            defaults.set(seeded, forKey: Self.journalRestoreResolvedKey)
            return seeded
        case .sensitiveNotes:
            return false
        }
    }

    /// Seeds `payload`'s marker from its legacy latch when the key is absent; returns whether it
    /// seeded (the first launch of this build, or the first after an uninstall). A present key is
    /// never touched.
    func seedRestoreMarkerIfAbsent(_ payload: SealedBackupPayloadType) -> Bool {
        switch payload {
        case .periodData:
            guard defaults.object(forKey: Self.periodRestoreResolvedKey) == nil else { return false }
            defaults.set(legacyLatch(payload), forKey: Self.periodRestoreResolvedKey)
            return true
        case .intimacyLogs:
            guard defaults.object(forKey: Self.intimacyRestoreResolvedKey) == nil else { return false }
            defaults.set(legacyLatch(payload), forKey: Self.intimacyRestoreResolvedKey)
            return true
        case .journalNarratives:
            guard defaults.object(forKey: Self.journalRestoreResolvedKey) == nil else { return false }
            defaults.set(legacyLatch(payload), forKey: Self.journalRestoreResolvedKey)
            return true
        case .sensitiveNotes:
            return false
        }
    }

    /// Whether the marker reads `true` right now — the "can't open" check's bookkeeping read. Never
    /// seeds.
    func restoreResolvedIsSet(_ payload: SealedBackupPayloadType) -> Bool {
        switch payload {
        case .periodData: return defaults.object(forKey: Self.periodRestoreResolvedKey) as? Bool == true
        case .intimacyLogs: return defaults.object(forKey: Self.intimacyRestoreResolvedKey) as? Bool == true
        case .journalNarratives: return defaults.object(forKey: Self.journalRestoreResolvedKey) as? Bool == true
        case .sensitiveNotes: return false
        }
    }

    /// Marks `payload`'s restore resolved.
    func markRestoreResolved(_ payload: SealedBackupPayloadType) {
        switch payload {
        case .periodData: defaults.set(true, forKey: Self.periodRestoreResolvedKey)
        case .intimacyLogs: defaults.set(true, forKey: Self.intimacyRestoreResolvedKey)
        case .journalNarratives: defaults.set(true, forKey: Self.journalRestoreResolvedKey)
        case .sensitiveNotes: return
        }
    }

    /// Re-opens `payload`'s restore (writes `false`, so the one-time seed never runs again).
    func reopenRestore(_ payload: SealedBackupPayloadType) {
        switch payload {
        case .periodData: defaults.set(false, forKey: Self.periodRestoreResolvedKey)
        case .intimacyLogs: defaults.set(false, forKey: Self.intimacyRestoreResolvedKey)
        case .journalNarratives: defaults.set(false, forKey: Self.journalRestoreResolvedKey)
        case .sensitiveNotes: return
        }
    }

    // MARK: - Accepted head

    /// The set this install last committed or merged, or nil — also nil when the record was written
    /// by another install (`acceptor` ≠ `installTag`), when it does not parse, or when `installTag`
    /// is nil (the install binding did not answer).
    func acceptedHead(_ payload: SealedBackupPayloadType, installTag: String?) -> SealedBackupAcceptedHead? {
        guard let installTag, let raw = acceptedHeadToken(payload) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == installTag, !parts[1].isEmpty, let generation = Int64(parts[2]) else { return nil }
        return SealedBackupAcceptedHead(stamp: SealedBackupHeadStamp(writer: parts[1], generation: generation), saltPrefix: parts[3])
    }

    /// Whether any accepted-head value is stored for `payload`, whoever recorded it — the "can't
    /// open" check's bookkeeping read.
    func hasAcceptedHeadRecord(_ payload: SealedBackupPayloadType) -> Bool {
        acceptedHeadToken(payload) != nil
    }

    /// Records `head` as the set this install last committed or merged.
    func recordAcceptedHead(_ head: SealedBackupAcceptedHead, _ payload: SealedBackupPayloadType, installTag: String) {
        let token = "\(installTag):\(head.stamp.writer):\(head.stamp.generation):\(head.saltPrefix)"
        switch payload {
        case .periodData: defaults.set(token, forKey: Self.periodAcceptedHeadKey)
        case .intimacyLogs: defaults.set(token, forKey: Self.intimacyAcceptedHeadKey)
        case .journalNarratives: defaults.set(token, forKey: Self.journalAcceptedHeadKey)
        case .sensitiveNotes: return
        }
    }

    /// Forgets `payload`'s accepted head.
    func clearAcceptedHead(_ payload: SealedBackupPayloadType) {
        switch payload {
        case .periodData: defaults.removeObject(forKey: Self.periodAcceptedHeadKey)
        case .intimacyLogs: defaults.removeObject(forKey: Self.intimacyAcceptedHeadKey)
        case .journalNarratives: defaults.removeObject(forKey: Self.journalAcceptedHeadKey)
        case .sensitiveNotes: return
        }
    }

    /// The raw accepted-head value for `payload`.
    private func acceptedHeadToken(_ payload: SealedBackupPayloadType) -> String? {
        switch payload {
        case .periodData: return defaults.string(forKey: Self.periodAcceptedHeadKey)
        case .intimacyLogs: return defaults.string(forKey: Self.intimacyAcceptedHeadKey)
        case .journalNarratives: return defaults.string(forKey: Self.journalAcceptedHeadKey)
        case .sensitiveNotes: return nil
        }
    }

    // MARK: - Observed foreign head

    /// The foreign head this install last observed for `payload`, or nil (also nil when another
    /// install recorded it, or it does not parse).
    func observedHead(_ payload: SealedBackupPayloadType, installTag: String?) -> SealedBackupHeadStamp? {
        guard let installTag, let raw = observedHeadToken(payload) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == installTag, !parts[1].isEmpty, let generation = Int64(parts[2]) else { return nil }
        return SealedBackupHeadStamp(writer: parts[1], generation: generation)
    }

    /// Whether any observed-head value is stored for `payload`, whoever recorded it.
    func hasObservedHeadRecord(_ payload: SealedBackupPayloadType) -> Bool {
        observedHeadToken(payload) != nil
    }

    /// Records `stamp` as the foreign head this install found for `payload`.
    func recordObservedHead(_ stamp: SealedBackupHeadStamp, _ payload: SealedBackupPayloadType, installTag: String) {
        let token = "\(installTag):\(stamp.writer):\(stamp.generation)"
        switch payload {
        case .periodData: defaults.set(token, forKey: Self.periodObservedHeadKey)
        case .intimacyLogs: defaults.set(token, forKey: Self.intimacyObservedHeadKey)
        case .journalNarratives: defaults.set(token, forKey: Self.journalObservedHeadKey)
        case .sensitiveNotes: return
        }
    }

    /// Forgets `payload`'s observed head.
    func clearObservedHead(_ payload: SealedBackupPayloadType) {
        switch payload {
        case .periodData: defaults.removeObject(forKey: Self.periodObservedHeadKey)
        case .intimacyLogs: defaults.removeObject(forKey: Self.intimacyObservedHeadKey)
        case .journalNarratives: defaults.removeObject(forKey: Self.journalObservedHeadKey)
        case .sensitiveNotes: return
        }
    }

    /// "Delete everything"'s leg: every v2 payload's observed head goes (the foreign set it named is
    /// deleted by the same leg). The markers and accepted heads are KEPT (§9, R2-F11).
    func clearObservedHeadsForWipe() {
        for payload in Self.v2Payloads { clearObservedHead(payload) }
    }

    /// The raw observed-head value for `payload`.
    private func observedHeadToken(_ payload: SealedBackupPayloadType) -> String? {
        switch payload {
        case .periodData: return defaults.string(forKey: Self.periodObservedHeadKey)
        case .intimacyLogs: return defaults.string(forKey: Self.intimacyObservedHeadKey)
        case .journalNarratives: return defaults.string(forKey: Self.journalObservedHeadKey)
        case .sensitiveNotes: return nil
        }
    }

    // MARK: - In-flight generation

    /// The generation this install's last commit was about to save for `payload`, or nil — also nil
    /// when another install recorded it, when it does not parse, or when `installTag` is nil.
    func inFlightGeneration(_ payload: SealedBackupPayloadType, installTag: String?) -> Int64? {
        guard let installTag, let raw = inFlightToken(payload) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == installTag, let generation = Int64(parts[1]) else { return nil }
        return generation
    }

    /// Records that this install's commit is about to save a set numbered `generation` (before its
    /// first save) — never lowering what this install already recorded.
    func recordInFlight(_ generation: Int64, _ payload: SealedBackupPayloadType, installTag: String) {
        let highest = max(generation, inFlightGeneration(payload, installTag: installTag) ?? 0)
        let token = "\(installTag):\(highest)"
        switch payload {
        case .periodData: defaults.set(token, forKey: Self.periodInFlightKey)
        case .intimacyLogs: defaults.set(token, forKey: Self.intimacyInFlightKey)
        case .journalNarratives: defaults.set(token, forKey: Self.journalInFlightKey)
        case .sensitiveNotes: return
        }
    }

    /// The raw in-flight value for `payload`.
    private func inFlightToken(_ payload: SealedBackupPayloadType) -> String? {
        switch payload {
        case .periodData: return defaults.string(forKey: Self.periodInFlightKey)
        case .intimacyLogs: return defaults.string(forKey: Self.intimacyInFlightKey)
        case .journalNarratives: return defaults.string(forKey: Self.journalInFlightKey)
        case .sensitiveNotes: return nil
        }
    }

    // MARK: - Exits

    /// The app-lock reset funnel and the "can't open" check (§9): the marker reopens, the accepted and
    /// observed heads go — they spoke for a key or an install state that no longer exists. The
    /// in-flight generation stays: what this install wrote is still true.
    func clearForKeyLoss() {
        for payload in Self.v2Payloads {
            reopenRestore(payload)
            clearAcceptedHead(payload)
            clearObservedHead(payload)
        }
    }

    /// Whether any v2 bookkeeping is recorded (a `true` marker, an accepted head or an observation) —
    /// what the "can't open" check counts as bookkeeping to clear.
    var hasAnyRecord: Bool {
        Self.v2Payloads.contains { restoreResolvedIsSet($0) || hasAcceptedHeadRecord($0) || hasObservedHeadRecord($0) }
    }
}

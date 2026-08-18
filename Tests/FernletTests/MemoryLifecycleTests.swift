// MemoryLifecycleTests.swift
// FernletTests
//
// Regression suite for the 2026-08-17 memory-leak review (Docs/Memory-Leak-Review-2026-08-17.md).
// Every test here pins one retention edge that review found broken — or one lifecycle guarantee
// it found merely asserted in a comment — so it cannot silently regress:
//
//  - ObservationLoop must not PIN its owner across the suspension (the "loop ends on owner
//    dealloc" header was void: a `guard let owner` above the await held the owner, and every slot,
//    coordinator and transport it owns, until a change that could no longer come).
//  - The three proximity managers must deallocate when released, with or without `stop()`.
//  - MeshNetworkManager must free the MC link of every slot it evicts (a zombie link ate one of
//    MC's 8 peer slots and made re-forming a slot with that peer impossible for the search).
//  - PresenceManager must release a discovered peer whose match a re-evaluation dropped, and must
//    run the coordinator's own teardown (ranging + Live Activity anchor) when the MC channel drops.
//  - ProximityRecipeShareManager must run that teardown on every record-drop path.
//  - Photo-wall preferences must shrink with the photo cache (install-lifetime sidecar).
//  - The synced Core Data store must prune un-consumed persistent history when it is loaded
//    without CloudKit mirroring.
//
// No test starts a radio (the unit-test invariant for proximity); every wait uses the deadline +
// minimum-poll-floor helper so a starved main actor cannot time it out spuriously.

@testable import ProximityKit
import CloudKitSync
import CoreData
import CryptoKit
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import Foundation
import MultipeerConnectivity
import Observation
import Testing
@testable import Fernlet

// MARK: - Fixtures

/// A tracked object the observation loop reads. Outlives the loop owner in the pin test so the
/// registrar entry it holds cannot be what releases the owner.
@MainActor
@Observable
private final class TrackedCounter {
    var value = 0
}

/// A minimal owner for ``ObservationLoop``: holds the tracked object and counts change callbacks.
@MainActor
private final class LoopOwner {
    let counter: TrackedCounter
    private(set) var changes = 0
    init(counter: TrackedCounter) { self.counter = counter }
    func noteChange() { changes += 1 }
}

@MainActor
private final class MockLifecycleHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

/// Gives up only once the deadline has passed AND `minimumPolls` observations have been made
/// (wall-clock alone expires while a `@MainActor` suite is starved in a loaded full-suite run).
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    minimumPolls: Int = 400,
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var polls = 0
    while !condition() {
        polls += 1
        if polls >= minimumPolls, clock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func makePeer(name: String = "peer-\(UUID().uuidString.prefix(8))") -> MultipeerPeer {
    MultipeerPeer(
        id: UUID(),
        displayName: name,
        discoveryInfo: nil,
        advertisedFingerprint: nil,
        underlying: MCPeerID(displayName: name)
    )
}

/// A never-begun coordinator over mock transports (mirrors MeshNetworkManagerTests). The ranging
/// mock is created inside — a `@MainActor` type can never be a default-argument value.
@MainActor
private func makeThrowawayCoordinator() -> ProximityCoordinator {
    let identity = IdentityService(keychainService: "test.memory.lifecycle.\(UUID().uuidString)")
    return ProximityCoordinator(
        identity: identity,
        transport: MockMultipeerTransport(),
        ranging: MockRangingProvider(),
        inspector: nil,
        replayCache: ReplayCache(),
        foregroundAnchor: nil,
        displayName: "Local",
        timeoutSeconds: 0
    )
}

// MARK: - ObservationLoop

/// The shared coordinator-state observation loop: it must react to changes, end promptly on
/// cancel, and — the reviewed defect — never keep its owner alive across the suspension.
@MainActor
@Suite(.serialized)
struct ObservationLoopLifecycleTests {

    /// Sanity: the refactored loop still fires `onChange` after a tracked mutation and re-arms.
    @Test func loopReactsToTrackedChangesAndReArms() async {
        let counter = TrackedCounter()
        let owner = LoopOwner(counter: counter)
        let task = ObservationLoop.start(
            on: owner,
            tracking: { _ = $0.counter.value },
            onChange: { $0.noteChange() }
        )
        try? await Task.sleep(for: .milliseconds(20))
        counter.value += 1
        await waitUntil { owner.changes == 1 }
        #expect(owner.changes == 1)
        counter.value += 1
        await waitUntil { owner.changes == 2 }
        #expect(owner.changes == 2, "the loop must re-arm after each change")
        task.cancel()
        _ = await task.value
    }

    /// Cancelling the returned task ends the loop even while it is suspended on a change that
    /// never comes (the AsyncStream continuation is finished from the cancellation handler).
    @Test func cancelEndsASuspendedLoop() async {
        let counter = TrackedCounter()
        let owner = LoopOwner(counter: counter)
        let task = ObservationLoop.start(
            on: owner,
            tracking: { _ = $0.counter.value },
            onChange: { $0.noteChange() }
        )
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        var finished = false
        let watcher = Task { @MainActor in
            _ = await task.value
            finished = true
        }
        await waitUntil { finished }
        #expect(finished, "a cancelled loop must return, not stay parked on its stream")
        watcher.cancel()
    }

    /// THE reviewed defect. The owner's only remaining reference is the loop's; once the caller
    /// drops it, the owner must deallocate even though the tracked object never changes again.
    /// Before the fix a `guard let owner` above the await pinned it for the whole suspension —
    /// which, with no other reference left to mutate anything, was forever.
    @Test func suspendedLoopDoesNotPinItsOwner() async {
        let counter = TrackedCounter()
        weak var weakOwner: LoopOwner?
        var task: Task<Void, Never>?
        do {
            let owner = LoopOwner(counter: counter)
            weakOwner = owner
            task = ObservationLoop.start(
                on: owner,
                tracking: { _ = $0.counter.value },
                onChange: { $0.noteChange() }
            )
            // Let the loop arm its tracking and suspend before the owner goes out of scope.
            try? await Task.sleep(for: .milliseconds(30))
        }
        await waitUntil { weakOwner == nil }
        #expect(weakOwner == nil, "the loop must hold its owner weakly across the suspension")
        task?.cancel()
        if let task { _ = await task.value }
    }
}

// MARK: - Proximity managers deallocate

/// The three proximity managers must release when their last reference goes — with a stopped
/// radio, and (via their `isolated deinit`s) even when the owner forgot `stop()`. Production holds
/// them for the process lifetime; these pins keep that a choice rather than a necessity.
@MainActor
@Suite(.serialized)
struct ProximityManagerDeallocationTests {
    /// Held for the suite: the managers hold the store `unowned`.
    let store = makeTestStore()

    @Test func meshNetworkManagerDeallocatesAfterSlotChurn() async {
        weak var weakManager: MeshNetworkManager?
        do {
            let manager = MeshNetworkManager(store: store)
            weakManager = manager
            let peer = makePeer()
            manager.addSlotForTesting(coordinator: makeThrowawayCoordinator(), peer: peer, fingerprint: nil)
            manager.evictSlotForTesting(peerID: peer.id)
        }
        await waitUntil { weakManager == nil }
        #expect(weakManager == nil, "MeshNetworkManager must not be retained after release")
    }

    @Test func presenceManagerDeallocatesWithoutStop() async {
        let host = MockLifecycleHost()
        let ledger = ProximityHeartLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-lifecycle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json"))
        weak var weakManager: PresenceManager?
        do {
            let manager = PresenceManager(store: host, ledger: ledger)
            weakManager = manager
            manager.activateForTesting()
            // Deliberately no stop(): the isolated deinit must end the owned tasks itself.
        }
        await waitUntil { weakManager == nil }
        #expect(weakManager == nil, "PresenceManager must deallocate even when stop() was skipped")
    }

    @Test func recipeShareManagerDeallocatesWithoutStop() async {
        weak var weakManager: ProximityRecipeShareManager?
        do {
            let manager = ProximityRecipeShareManager(store: store)
            weakManager = manager
            manager.markRunningForTesting()
        }
        await waitUntil { weakManager == nil }
        #expect(weakManager == nil, "ProximityRecipeShareManager must deallocate even when stop() was skipped")
    }
}

// MARK: - MeshNetworkManager: evicted slots free their MC link

@MainActor
@Suite(.serialized)
struct MeshEvictionReleasesTransportLinkTests {
    let store = makeTestStore()

    /// `removeSlot` (timeouts, stale sweep, remote goodbye, session close, transport loss) must
    /// request the per-peer MC kick — before the fix nothing in the eviction chain touched the
    /// MCSession, so the link lingered until the whole search stopped.
    @Test func evictingASlotRequestsTheMultipeerKick() {
        let manager = MeshNetworkManager(store: store)
        var kicked: [UUID] = []
        manager.setDisconnectPeerObserverForTesting { kicked.append($0.id) }
        let peer = makePeer()
        manager.addSlotForTesting(coordinator: makeThrowawayCoordinator(), peer: peer, fingerprint: nil)

        manager.evictSlotForTesting(peerID: peer.id)

        #expect(kicked == [peer.id], "the evicted peer's MC link must be released, not left as a zombie")
        manager.setDisconnectPeerObserverForTesting(nil)
    }
}

// MARK: - PresenceManager: dropped matches and dropped channels release their objects

@MainActor
@Suite(.serialized)
struct PresenceReleaseTests {
    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.memory-lifecycle.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    private func makeLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-lifecycle-presence-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json"))
    }

    private func friendRecord(fingerprint: String, keyAgreementPublicKey: Data) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Friend",
            fingerprint: fingerprint,
            signingPublicKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            keyAgreementPublicKey: keyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: baseDate,
            lastSeenAt: baseDate,
            revokedAt: nil,
            blockedAt: nil
        )
    }

    private func advertisingPeer(tokens: [String]) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: "peer-\(UUID().uuidString.prefix(8))",
            discoveryInfo: ["v": "1", "t": tokens.joined(separator: ",")],
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: "mc-\(UUID().uuidString.prefix(8))")
        )
    }

    /// A roster refresh that drops a matched peer's only match must release the peer object too.
    /// Before the fix only the match bookkeeping was cleared, so a later `lostPeer` (guarded on the
    /// match map) ignored the peer and its entry lived until `stop()`.
    @Test func reevaluationThatDropsAMatchReleasesThePeer() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockLifecycleHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)
        let friendKA = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        host.proximityTrustVault.apply(peers: [friendRecord(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(advertisingPeer(tokens: [token, theirOtherFriendTag]))
        #expect(manager.nearbyFriendFingerprints == ["f00df00df00df00d"])
        #expect(manager.discoveredPeerCountForTesting == 1)

        // The friend is removed from the roster: their tag no longer matches anything.
        host.proximityTrustVault.apply(peers: [], audit: [])
        manager.refreshRoster()

        #expect(manager.nearbyFriendFingerprints.isEmpty)
        #expect(manager.discoveredPeerCountForTesting == 0,
                "a peer whose match was dropped must be released, not orphaned until stop()")
    }

    /// When the MC channel of a live heart connection drops, the manager must run the
    /// coordinator's own teardown (`cancel()` → `end()`), which stops ranging and ends the
    /// foreground anchor's Live Activity. Before the fix the record — the coordinator's only strong
    /// owner — was dropped without `cancel()`, so neither ever stopped.
    @Test func droppedHeartChannelRunsTheCoordinatorTeardown() async throws {
        let host = MockLifecycleHost()
        let (local, localID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: localID) }
        let (friend, friendID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: friendID) }
        let manager = PresenceManager(store: host, ledger: makeLedger())
        host.proximityTrustVault.trust(
            ProximityCoordinator.PeerIdentity(
                id: UUID(),
                displayName: "Aisha Bloom",
                signingPublicKey: friend.localSigningPublicKey,
                keyAgreementPublicKey: friend.localKeyAgreementPublicKey,
                fingerprint: friend.localFingerprint,
                rangingMode: .none,
                firstSeenAt: baseDate
            ),
            mode: .friend
        )

        let anchor = NoopProximityForegroundAnchor()
        let ranging = MockRangingProvider()
        let (coordinator, policy, peer) = try await connectedCoordinator(
            local: local, remote: friend, vault: host.proximityTrustVault, peerName: "Aisha Bloom",
            anchor: anchor, ranging: ranging
        )
        #expect(anchor.isActive, "a connected coordinator has started its foreground anchor")
        let accepted = manager.evaluateConnectedCoordinatorForTesting(coordinator, peer: peer, trustPolicy: policy)
        #expect(accepted)
        #expect(manager.heartConnectionCountForTesting == 1)

        manager.simulateHeartPeerDisconnectForTesting(peer)

        #expect(manager.heartConnectionCountForTesting == 0)
        await waitUntil { !anchor.isActive && ranging.stopCalled }
        #expect(!anchor.isActive, "the dropped connection's Live Activity anchor must be ended")
        #expect(ranging.stopCalled, "the dropped connection's ranging session must be stopped")
    }

    /// Drives a real coordinator to `.connected` over mock transports (mirrors HeartShareTests),
    /// with the anchor and ranging provider injected so their teardown is observable.
    private func connectedCoordinator(
        local: IdentityService,
        remote: IdentityService,
        vault: ProximityTrustVault,
        peerName: String,
        anchor: NoopProximityForegroundAnchor,
        ranging: MockRangingProvider
    ) async throws -> (ProximityCoordinator, FriendSessionTrustPolicy, MultipeerPeer) {
        let transport = MockMultipeerTransport()
        let trustPolicy = FriendSessionTrustPolicy(vault: vault)
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: ranging,
            inspector: nil,
            trustPolicy: trustPolicy,
            replayCache: ReplayCache(),
            foregroundAnchor: anchor,
            displayName: "Local",
            timeoutSeconds: 0
        )
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: peerName,
            discoveryInfo: ["fp": remote.localFingerprint],
            advertisedFingerprint: remote.localFingerprint,
            underlying: MCPeerID(displayName: peerName)
        )
        let intro = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: peerName,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from \(peerName)"),
            payload: Data()
        )
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        await waitUntil { if case .awaitingTapConfirmation = coordinator.state { return true }; return false }
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(intro), from: peer)
        await waitUntil {
            switch coordinator.state {
            case .awaitingUserConfirmation, .connected: return true
            default: return false
            }
        }
        if case .awaitingUserConfirmation = coordinator.state {
            await coordinator.confirmPeerIdentity()
        }
        guard case .connected = coordinator.state else {
            throw LifecycleTestFailure.notConnected(String(describing: coordinator.state))
        }
        return (coordinator, trustPolicy, peer)
    }

    private enum LifecycleTestFailure: Error { case notConnected(String) }
}

// MARK: - ProximityRecipeShareManager: every record drop runs the coordinator teardown

@MainActor
@Suite(.serialized)
struct RecipeShareTeardownTests {
    let store = makeTestStore()

    /// The MC-disconnect removal path must cancel the dropped record's coordinator: `end()` stops
    /// ranging (observable here) and the Live Activity anchor. Before the fix the record was
    /// simply removed and the coordinator freed without ever running its teardown.
    @Test func peerDisconnectCancelsTheDroppedCoordinator() async {
        let manager = ProximityRecipeShareManager(store: store)
        let ranging = MockRangingProvider()
        let peer = makePeer()
        _ = manager.makeRetainedConnectionCoordinatorForTesting(peer: peer, transport: MockMultipeerTransport(), ranging: ranging)
        #expect(manager.connectionCountForTesting == 1)

        manager.multipeerSessionForTesting.onPeerDisconnected?(peer, "Peer disconnected")

        #expect(manager.connectionCountForTesting == 0)
        await waitUntil { ranging.stopCalled }
        #expect(ranging.stopCalled, "removeConnections(matching:) must run the coordinator's teardown")
    }

    /// `stop()` must cancel every live coordinator before dropping the records.
    @Test func stopCancelsLiveCoordinators() async {
        let manager = ProximityRecipeShareManager(store: store)
        let ranging = MockRangingProvider()
        _ = manager.makeRetainedConnectionCoordinatorForTesting(peer: makePeer(), transport: MockMultipeerTransport(), ranging: ranging)
        manager.markRunningForTesting()

        manager.stop()

        #expect(manager.connectionCountForTesting == 0)
        await waitUntil { ranging.stopCalled }
        #expect(ranging.stopCalled, "stop() must run each coordinator's teardown before dropping it")
    }
}

// MARK: - Photo-wall preferences shrink with the cache

@MainActor
@Suite(.serialized)
struct PhotoWallPreferencePruneTests {
    let store = makeTestStore()

    private func makeSessionPhoto(session: FriendPhotoSessionMetadata) -> FriendPhotoPayload {
        FriendPhotoPayload(imageData: Data([0x01]), senderName: "Tester", session: session)
    }

    /// A favorite whose photo has left the cache must not survive in the install-lifetime sidecar:
    /// once the photos are gone, the next shrink site prunes every entry that pointed at them, and
    /// a fresh manager over the same store loads none back.
    @Test func preferencesForEvictedPhotosArePrunedAndNotReloaded() {
        let session = FriendPhotoSessionMetadata(id: UUID(), meshID: nil, meshName: nil, startedAt: Date(), participants: [])
        let first = makeSessionPhoto(session: session)
        let second = makeSessionPhoto(session: session)
        do {
            let manager = MeshNetworkManager(store: store)
            manager.meshPhotos = [first, second]
            let post = FriendPhotoWallPost(id: session.id, session: session, photos: [first, second], coverPhoto: first)
            manager.toggleFavorite(photoID: second.id, in: post)
            #expect(manager.photoWallPreferenceEntryCountForTesting == 1)

            // Both photos leave the cache (session discard / FIFO / delete): the entry must go.
            manager.deletePhoto(first.id)
            #expect(manager.photoWallPreferenceEntryCountForTesting == 1, "the session still has a live photo")
            manager.deletePhoto(second.id)
            #expect(manager.photoWallPreferenceEntryCountForTesting == 0,
                    "no photo of the session remains, so its preference entries must be pruned")
        }
        let reloaded = MeshNetworkManager(store: store)
        #expect(reloaded.photoWallPreferenceEntryCountForTesting == 0,
                "the pruned sidecar must not resurrect entries on the next launch")
    }
}

// MARK: - Local-only persistent history is pruned

/// The synced Core Data store keeps persistent history on so remote-change notifications work,
/// but only a CloudKit mirroring delegate ever consumed it. Loaded WITHOUT mirroring (sync off),
/// the history tables grew for the life of the install; every successful load now prunes them.
@Suite(.serialized)
struct LocalOnlyPersistentHistoryPruneTests {

    private func makeTemporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-lifecycle-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeTemporaryStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func historyCount(in context: NSManagedObjectContext) throws -> Int {
        try context.performAndWait {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
            let result = try context.execute(request) as? NSPersistentHistoryResult
            return (result?.result as? [NSPersistentHistoryTransaction])?.count ?? 0
        }
    }

    /// Control + mechanism: history IS recorded on a local-only on-disk store, and the pruner
    /// removes it (through the DEBUG seam, with an explicit cutoff — the 7-day production window
    /// cannot be waited out in a test and history cannot be backdated).
    @MainActor
    @Test func historyIsRecordedAndThePrunerRemovesIt() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL,
            iCloudAvailable: false
        )
        #expect(controller.activeStoreDescription?.cloudKitContainerOptions == nil)

        let repository = DayRecordRepository(controller: controller)
        let stamp = Date()
        #expect(repository.upsert([
            DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 3), updatedAt: stamp),
            DayRecordUpsert(day: FernletDay(date: "2026-05-02", bottleCount: 5), updatedAt: stamp),
        ]))
        try #require(try historyCount(in: controller.container.viewContext) > 0,
                     "control: a local-only store must record persistent history for the pruner to remove")

        controller.pruneUnconsumedHistoryForTesting(before: Date().addingTimeInterval(1))
        var remaining = -1
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var polls = 0
        repeat {
            polls += 1
            remaining = try historyCount(in: controller.container.viewContext)
            if remaining == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        } while polls < 400 || clock.now < deadline
        #expect(remaining == 0, "the pruner must delete every transaction older than the cutoff")
    }

    /// The LOAD PATH itself prunes: a reload without mirroring (retention overridden to zero
    /// through the DEBUG seam) removes the history the previous session recorded.
    @MainActor
    @Test func reloadWithoutMirroringPrunesRecordedHistory() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL,
            iCloudAvailable: false
        )
        let repository = DayRecordRepository(controller: controller)
        #expect(repository.upsert([
            DayRecordUpsert(day: FernletDay(date: "2026-05-03", bottleCount: 1), updatedAt: Date()),
        ]))
        try #require(try historyCount(in: controller.container.viewContext) > 0)

        controller.localOnlyHistoryRetentionOverrideForTesting = -1  // cutoff one second in the future
        try await controller.reload(with: StoragePreferences(iCloudSyncEnabled: false))
        #expect(controller.activeStoreDescription?.cloudKitContainerOptions == nil)

        var remaining = -1
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var polls = 0
        repeat {
            polls += 1
            remaining = try historyCount(in: controller.container.viewContext)
            if remaining == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        } while polls < 400 || clock.now < deadline
        #expect(remaining == 0, "a local-only load must prune the un-consumed history it finds")
    }
}

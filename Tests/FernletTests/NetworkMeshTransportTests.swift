import Combine
import CryptoKit
import Foundation
import Security
import Testing
@testable import ProximityKit

// MARK: - NetworkMeshTransportTests

// The tier-1 battery for P2's QUIC transport, written against the parts that were deliberately
// factored OUT of the session actor so they could be enumerated here: the link table, the dial
// preference, the heartbeat schedule, the TXT vocabulary, the ephemeral TLS identity, and the
// control-stream framing.
//
// The session actor itself — listener, browser, connections — needs two radios and is covered by
// the runbook's device lanes, not by anything in this file. What IS covered here is every decision
// that actor makes, which is the whole reason those decisions do not live inside it.
//
// **No test in this file sleeps.** Time is a `VirtualClock` a test advances by hand, matching the
// rule the deterministic fabric in Mocks/FakePeerTransport.swift was built around: a scenario either
// completes deterministically or fails visibly, never intermittently under CI load.

/// The link table's five phases, its caps, and its budgets — enumerated rather than sampled.
@MainActor
@Suite(.serialized)
struct MeshLinkTableTests {

    static let alpha = MeshLinkKey("alpha")
    static let beta = MeshLinkKey("beta")

    /// Drives a fresh table into `phase` for ``alpha``, returning both.
    ///
    /// Every phase test starts here so a phase is always reached the way production reaches it —
    /// a table whose fields were poked into place would prove nothing about the transitions.
    static func table(in phase: MeshLinkPhase, clock: VirtualClock) -> MeshLinkTable {
        var table = MeshLinkTable()
        switch phase {
        case .idle:
            return table
        case .dialing:
            _ = table.admitDial(to: alpha, now: clock.now)
        case .backingOff:
            _ = table.admitDial(to: alpha, now: clock.now)
            _ = table.noteDialFailed(alpha, now: clock.now)
        case .connected:
            table.noteReady(alpha, now: clock.now)
        case .exhausted:
            for _ in 0..<MeshLinkTable.maxDialAttempts {
                _ = table.admitDial(to: alpha, now: clock.now)
                _ = table.noteDialFailed(alpha, now: clock.now)
                clock.advance(by: MeshLinkTable.dialRetryDelay)
            }
        }
        return table
    }

    // MARK: Phases

    /// Every phase is reachable exactly as the fixture claims. Without this the matrices below
    /// could all be passing against a table that never left `.idle`.
    @Test func everyPhaseIsReachable() {
        let clock = VirtualClock()
        let phases: [MeshLinkPhase] = [.idle, .dialing, .backingOff, .connected, .exhausted]
        for phase in phases {
            let table = Self.table(in: phase, clock: clock)
            #expect(table.phase(of: Self.alpha) == phase, "fixture did not reach \(phase)")
        }
    }

    /// Only `.dialing` and `.connected` hold a slot. A room full of unreachable advertisements must
    /// not consume the roster cap — that is the difference between a mesh that fills up with peers
    /// it cannot reach and one that keeps trying the ones it can.
    @Test func onlyDialingAndConnectedLinksHoldASlot() {
        let clock = VirtualClock()
        let expected: [MeshLinkPhase: Int] = [
            .idle: 0, .dialing: 1, .backingOff: 0, .connected: 1, .exhausted: 0
        ]
        for (phase, slots) in expected {
            let table = Self.table(in: phase, clock: clock)
            #expect(table.occupiedSlotCount == slots, "\(phase) should hold \(slots) slot(s)")
        }
    }

    // MARK: admitDial

    /// The outbound admission for every phase, exhaustively.
    @Test func dialAdmissionCoversEveryPhase() {
        let clock = VirtualClock()
        let expected: [MeshLinkPhase: MeshLinkAdmission] = [
            .idle: .admit,
            .dialing: .refusedDuplicateTunnel(.dialing),
            .backingOff: .refusedDuplicateTunnel(.backingOff),
            .connected: .refusedDuplicateTunnel(.connected),
            .exhausted: .refusedRetryBudgetSpent
        ]
        for (phase, admission) in expected {
            var table = Self.table(in: phase, clock: clock)
            #expect(table.admitDial(to: Self.alpha, now: clock.now) == admission, "phase \(phase)")
        }
    }

    /// A backing-off link becomes dialable the instant its delay elapses, and not a moment before.
    /// The boundary is the interesting part: a rule written with `<` instead of `<=` would leave a
    /// link waiting for the next poll tick, every retry, forever.
    @Test func aBackingOffLinkIsDialableExactlyWhenItsDelayElapses() {
        let clock = VirtualClock()
        var table = Self.table(in: .backingOff, clock: clock)

        clock.advance(by: .seconds(MeshLinkTable.dialRetryDelaySeconds - 0.001))
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .refusedDuplicateTunnel(.backingOff))
        #expect(table.dueRetries(now: clock.now).isEmpty)

        clock.advance(by: .milliseconds(1))
        #expect(table.dueRetries(now: clock.now) == [Self.alpha])
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .admit)
    }

    /// Exactly ``MeshLinkTable/maxDialAttempts`` attempts, then the budget is spent — and the
    /// outcome names which attempt is next, so a log line cannot drift from the real count.
    @Test func theDialBudgetIsExactlyThreeAttempts() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        var outcomes: [MeshDialOutcome] = []
        for _ in 0..<MeshLinkTable.maxDialAttempts {
            #expect(table.admitDial(to: Self.alpha, now: clock.now) == .admit)
            outcomes.append(table.noteDialFailed(Self.alpha, now: clock.now))
            clock.advance(by: MeshLinkTable.dialRetryDelay)
        }
        #expect(outcomes == [
            .retry(attempt: 2, delay: MeshLinkTable.dialRetryDelay),
            .retry(attempt: 3, delay: MeshLinkTable.dialRetryDelay),
            .giveUp(attempts: 3)
        ])
        #expect(table.phase(of: Self.alpha) == .exhausted)
        #expect(table.dueRetries(now: clock.now).isEmpty, "an exhausted link must not be re-armed")
    }

    /// A duplicate failure callback for a link the table has already given up on — or has never
    /// booked — must not start a new campaign. A retry loop re-armable by a repeated callback is an
    /// unbounded loop with extra steps.
    @Test func aFailureForAnUnbookedLinkDoesNotOpenAFreshBudget() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        #expect(table.noteDialFailed(Self.alpha, now: clock.now) == .giveUp(attempts: 3))
        #expect(table.phase(of: Self.alpha) == .exhausted)
        #expect(table.noteDialFailed(Self.alpha, now: clock.now) == .giveUp(attempts: 3))
    }

    /// Connecting resets the budget, and a later disconnect leaves a full one. The budget is for
    /// *reaching* a peer, not a lifetime quota — charging disconnects to it is how a peer that
    /// reconnects a few times becomes permanently undialable.
    @Test func connectingResetsTheBudgetAndDisconnectingDoesNotSpendIt() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        _ = table.admitDial(to: Self.alpha, now: clock.now)
        _ = table.noteDialFailed(Self.alpha, now: clock.now)
        #expect(table.dialAttempts(for: Self.alpha) == 1)

        table.noteReady(Self.alpha, now: clock.now)
        #expect(table.dialAttempts(for: Self.alpha) == 0)

        table.noteClosed(Self.alpha)
        #expect(table.phase(of: Self.alpha) == .idle)
        #expect(table.dialAttempts(for: Self.alpha) == 0)
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .admit)
    }

    // MARK: Capacity

    /// The eighth link is admitted and the ninth is not — and the refusal says `atCapacity`, not
    /// `duplicate`, because those two send a reader to opposite parts of the code.
    @Test func theNinthSimultaneousLinkIsRefusedAtCapacity() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        for index in 0..<MeshLinkTable.maxConcurrentLinks {
            #expect(table.admitDial(to: MeshLinkKey("peer-\(index)"), now: clock.now) == .admit)
        }
        #expect(table.occupiedSlotCount == MeshLinkTable.maxConcurrentLinks)
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .refusedAtCapacity)
        #expect(
            table.admitInbound(from: Self.alpha, preference: .unranked, now: clock.now)
                == .refusedAtCapacity
        )
    }

    /// Links that are backing off or exhausted free their slots, so a full table of unreachable
    /// peers still admits a reachable one.
    @Test func unreachableLinksDoNotHoldTheRosterCap() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        for index in 0..<MeshLinkTable.maxConcurrentLinks {
            let key = MeshLinkKey("peer-\(index)")
            _ = table.admitDial(to: key, now: clock.now)
            _ = table.noteDialFailed(key, now: clock.now)
        }
        #expect(table.occupiedSlotCount == 0)
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .admit)
    }

    /// An inbound tunnel accepted while this side is mid-dial reuses the slot the dial already
    /// holds, rather than needing a ninth.
    @Test func anAdmittedInboundTunnelReusesTheDialingSlot() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        for index in 0..<(MeshLinkTable.maxConcurrentLinks - 1) {
            _ = table.admitDial(to: MeshLinkKey("peer-\(index)"), now: clock.now)
        }
        _ = table.admitDial(to: Self.alpha, now: clock.now)
        #expect(table.occupiedSlotCount == MeshLinkTable.maxConcurrentLinks)
        #expect(table.admitInbound(from: Self.alpha, preference: .peerDials, now: clock.now) == .admit)
        #expect(table.occupiedSlotCount == MeshLinkTable.maxConcurrentLinks)
        #expect(table.connectedCount == 1)
    }

    // MARK: admitInbound — the full 5 × 3 matrix

    /// Every phase against every preference. Fifteen cells, all of them stated.
    ///
    /// The one that matters is `.dialing`: it is the only row where the preference changes the
    /// answer, and it is the duplicate-tunnel suppression of plan §7.1. Everything else admits
    /// unless a tunnel already exists.
    @Test func inboundAdmissionCoversEveryPhaseAndPreference() {
        let clock = VirtualClock()
        let preferences: [MeshDialPreference] = [.localDials, .peerDials, .unranked]
        let expected: [MeshLinkPhase: [MeshDialPreference: MeshLinkAdmission]] = [
            .idle: [.localDials: .admit, .peerDials: .admit, .unranked: .admit],
            .dialing: [
                .localDials: .refusedDuplicateTunnel(.dialing),
                .peerDials: .admit,
                .unranked: .admit
            ],
            .backingOff: [.localDials: .admit, .peerDials: .admit, .unranked: .admit],
            .connected: [
                .localDials: .refusedDuplicateTunnel(.connected),
                .peerDials: .refusedDuplicateTunnel(.connected),
                .unranked: .refusedDuplicateTunnel(.connected)
            ],
            .exhausted: [.localDials: .admit, .peerDials: .admit, .unranked: .admit]
        ]
        for (phase, row) in expected {
            for preference in preferences {
                var table = Self.table(in: phase, clock: clock)
                let admission = table.admitInbound(
                    from: Self.alpha, preference: preference, now: clock.now
                )
                #expect(admission == row[preference], "phase \(phase) × preference \(preference)")
            }
        }
    }

    /// A spent dial budget refuses a *dial* and admits an *accept*. The budget is about this side
    /// giving up on reaching a peer; a peer that reaches us has answered the question.
    @Test func aSpentBudgetStillAcceptsAnInboundTunnel() {
        let clock = VirtualClock()
        var table = Self.table(in: .exhausted, clock: clock)
        #expect(table.admitDial(to: Self.alpha, now: clock.now) == .refusedRetryBudgetSpent)
        #expect(table.admitInbound(from: Self.alpha, preference: .unranked, now: clock.now) == .admit)
        #expect(table.phase(of: Self.alpha) == .connected)
        #expect(table.dialAttempts(for: Self.alpha) == 0)
    }

    /// **The anti-deadlock property.** For every pair of session ids a real pair of devices could
    /// hold — including the pre-TXT window where one or both sides know nothing — at least one side
    /// of a mutually-dialing pair keeps a tunnel.
    ///
    /// Refusing an inbound tunnel closes the peer's outbound one, so "both refuse" ends with zero
    /// tunnels and a wait for the retry timer: the exact failure the MC tie-break produced once, and
    /// the reason this table consults the ranking at all. Two tunnels is wasteful and self-corrects;
    /// zero does not.
    @Test func aMutuallyDialingPairNeverEndsWithZeroTunnels() {
        let clock = VirtualClock()
        let ids: [String?] = ["aaaa", "zzzz", nil, ""]
        for localID in ids {
            for peerID in ids {
                let local = localID ?? ""
                let remote = peerID ?? ""
                var here = Self.table(in: .dialing, clock: clock)
                var there = Self.table(in: .dialing, clock: clock)
                let hereAdmits = here.admitInbound(
                    from: Self.alpha, localSessionID: local, peerSessionID: peerID, now: clock.now
                ) == .admit
                let thereAdmits = there.admitInbound(
                    from: Self.alpha, localSessionID: remote, peerSessionID: localID, now: clock.now
                ) == .admit
                #expect(
                    hereAdmits || thereAdmits,
                    "both sides refused for local=\(local) peer=\(remote) — that is the deadlock"
                )
            }
        }
    }

    // MARK: Endpoint cache

    /// The cache is bounded oldest-first, and a re-sighting refreshes in place without reordering —
    /// so a long-lived endpoint cannot pin a full cache against newcomers forever.
    @Test func theEndpointCacheIsBoundedOldestFirst() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        for index in 0..<(MeshLinkTable.maxCachedEndpoints + 4) {
            table.remember(Self.record(named: "peer-\(index)", at: clock.now))
        }
        #expect(table.cachedEndpointCount == MeshLinkTable.maxCachedEndpoints)
        #expect(table.cachedEndpoint(MeshLinkKey("peer-0")) == nil, "oldest should have been evicted")
        #expect(table.cachedEndpoint(MeshLinkKey("peer-4")) != nil)

        let firstSurvivor = table.cachedEndpoints.first?.key
        table.remember(Self.record(named: "peer-4", at: clock.now.addingTimeInterval(60)))
        #expect(table.cachedEndpointCount == MeshLinkTable.maxCachedEndpoints, "a refresh must not grow the cache")
        #expect(table.cachedEndpoints.first?.key == firstSurvivor, "a refresh must not reorder eviction")
    }

    /// The cache is what makes a re-dial possible after Bonjour goes quiet: the record survives the
    /// endpoint leaving the browse results as long as something still holds it, and `forget` is the
    /// one call that drops it.
    @Test func forgettingAnEndpointDropsItsLinkStateAndItsCacheEntry() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        table.remember(Self.record(named: "alpha", at: clock.now))
        _ = table.admitDial(to: Self.alpha, now: clock.now)
        #expect(table.cachedEndpoint(Self.alpha) != nil)

        table.forget(Self.alpha)
        #expect(table.cachedEndpoint(Self.alpha) == nil)
        #expect(table.phase(of: Self.alpha) == .idle)
        #expect(table.cachedEndpoints.isEmpty)
    }

    /// Teardown leaves nothing — the privacy constraint, asserted directly rather than inferred.
    @Test func removeAllLeavesNothingBehind() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        table.remember(Self.record(named: "alpha", at: clock.now))
        table.remember(Self.record(named: "beta", at: clock.now))
        _ = table.admitDial(to: Self.alpha, now: clock.now)
        table.noteReady(Self.beta, now: clock.now)

        table.removeAll()
        #expect(table.cachedEndpointCount == 0)
        #expect(table.occupiedSlotCount == 0)
        #expect(table.connectedCount == 0)
        #expect(table.phase(of: Self.alpha) == .idle)
        #expect(table.dueRetries(now: clock.now).isEmpty)
    }

    /// Due retries come back in a deterministic order, so a failure names one combination rather
    /// than a dictionary's iteration order.
    @Test func dueRetriesAreSortedAndOnlyIncludeElapsedBackoffs() {
        let clock = VirtualClock()
        var table = MeshLinkTable()
        for name in ["charlie", "alpha", "beta"] {
            let key = MeshLinkKey(name)
            _ = table.admitDial(to: key, now: clock.now)
            _ = table.noteDialFailed(key, now: clock.now)
        }
        let late = MeshLinkKey("delta")
        clock.advance(by: MeshLinkTable.dialRetryDelay)
        _ = table.admitDial(to: late, now: clock.now)
        _ = table.noteDialFailed(late, now: clock.now)

        #expect(table.dueRetries(now: clock.now) == [MeshLinkKey("alpha"), MeshLinkKey("beta"), MeshLinkKey("charlie")])
    }

    static func record(named name: String, at now: Date) -> MeshEndpointRecord {
        MeshEndpointRecord(
            key: MeshLinkKey(name),
            instanceName: "fernlet-mesh-\(name)",
            advertisement: ["sid": name],
            lastSeenAt: now
        )
    }
}

// MARK: - MeshDialPreferenceTests

/// The ranking that decides which side of a mutually-dialing pair keeps its tunnel, and its
/// agreement with the production tie-break the mesh has already been deadlocked by once.
@Suite(.serialized)
struct MeshDialPreferenceTests {

    static let sessionIDs = ["aaaa", "aaab", "m", "zzzz", "0000", "ffffffff"]

    /// Antisymmetric wherever it ranks. This is the property that makes "both sides refuse"
    /// unreachable from real inputs, so it is asserted over every ordered pair rather than sampled.
    @Test func rankingIsAntisymmetricForDistinctSessionIDs() {
        for local in Self.sessionIDs {
            for peer in Self.sessionIDs where peer != local {
                let here = MeshDialPreference.rank(localSessionID: local, peerSessionID: peer)
                let there = MeshDialPreference.rank(localSessionID: peer, peerSessionID: local)
                #expect(here != .unranked, "\(local) vs \(peer) should rank")
                #expect(
                    (here == .localDials && there == .peerDials) || (here == .peerDials && there == .localDials),
                    "\(local)/\(peer) ranked \(here)/\(there) — not antisymmetric"
                )
            }
        }
    }

    /// The three cases where no ranking exists: absent, empty, and equal. Each is `.unranked`,
    /// which admits — the safe direction.
    @Test func absentEmptyAndEqualSessionIDsAreUnranked() {
        #expect(MeshDialPreference.rank(localSessionID: "aaaa", peerSessionID: nil) == .unranked)
        #expect(MeshDialPreference.rank(localSessionID: "aaaa", peerSessionID: "") == .unranked)
        #expect(MeshDialPreference.rank(localSessionID: "", peerSessionID: "aaaa") == .unranked)
        #expect(MeshDialPreference.rank(localSessionID: "aaaa", peerSessionID: "aaaa") == .unranked)
    }

    /// Where both policies rank, they agree: the transport's `.localDials` is exactly the manager's
    /// "we dial". A divergence here would put the two halves of one decision on opposite sides.
    ///
    /// The two deliberate divergences are asserted too, so they stay deliberate: an absent peer
    /// `sid` makes the manager invite (a redundant invite beats a deadlock) while the transport
    /// declines to rank (a refusal on both sides IS the deadlock), and an equal `sid` is this
    /// process's own echo — the manager refuses to dial itself, the transport has nothing to rank.
    @Test func rankingAgreesWithTheProductionInviteTieBreak() {
        for local in Self.sessionIDs {
            for peer in Self.sessionIDs where peer != local {
                let dials = MeshNetworkManager.shouldInitiateInvite(
                    localSessionID: local, peerSessionID: peer
                )
                let preference = MeshDialPreference.rank(localSessionID: local, peerSessionID: peer)
                #expect(
                    dials == (preference == .localDials),
                    "manager says dial=\(dials) but transport ranked \(preference) for \(local)/\(peer)"
                )
            }
        }
        #expect(MeshNetworkManager.shouldInitiateInvite(localSessionID: "aaaa", peerSessionID: nil))
        #expect(MeshDialPreference.rank(localSessionID: "aaaa", peerSessionID: nil) == .unranked)
        #expect(!MeshNetworkManager.shouldInitiateInvite(localSessionID: "aaaa", peerSessionID: "aaaa"))
        #expect(MeshDialPreference.rank(localSessionID: "aaaa", peerSessionID: "aaaa") == .unranked)
    }
}

// MARK: - MeshHeartbeatScheduleTests

/// The 30 s heartbeat's due times, on a clock the test owns.
@MainActor
@Suite(.serialized)
struct MeshHeartbeatScheduleTests {

    static let alpha = MeshLinkKey("alpha")

    /// Nothing is due before the interval, and the link is due exactly at it.
    @Test func aLinkIsDueExactlyOneIntervalAfterItStarts() {
        let clock = VirtualClock()
        var schedule = MeshHeartbeatSchedule()
        schedule.start(Self.alpha, now: clock.now)

        clock.advance(by: .seconds(MeshHeartbeatSchedule.intervalSeconds - 0.001))
        #expect(schedule.due(now: clock.now).isEmpty)

        clock.advance(by: .milliseconds(1))
        #expect(schedule.due(now: clock.now) == [Self.alpha])
    }

    /// A link stays due until it is beaten, then goes quiet for another interval. A schedule that
    /// re-armed on the *read* would beat a link whose send failed, forever.
    @Test func aLinkStaysDueUntilItIsBeaten() {
        let clock = VirtualClock()
        var schedule = MeshHeartbeatSchedule()
        schedule.start(Self.alpha, now: clock.now)
        clock.advance(by: MeshHeartbeatSchedule.interval)

        #expect(schedule.due(now: clock.now) == [Self.alpha])
        #expect(schedule.due(now: clock.now) == [Self.alpha], "reading must not re-arm")

        schedule.noteSent(Self.alpha, now: clock.now)
        #expect(schedule.due(now: clock.now).isEmpty)
        clock.advance(by: MeshHeartbeatSchedule.interval)
        #expect(schedule.due(now: clock.now) == [Self.alpha])
    }

    /// A poll that runs late fires each passed link exactly once — absolute due times, not a
    /// countdown that has to catch up.
    @Test func aLatePollFiresEachLinkOnce() {
        let clock = VirtualClock()
        var schedule = MeshHeartbeatSchedule()
        schedule.start(MeshLinkKey("alpha"), now: clock.now)
        schedule.start(MeshLinkKey("beta"), now: clock.now)

        clock.advance(by: .seconds(MeshHeartbeatSchedule.intervalSeconds * 5))
        #expect(schedule.due(now: clock.now) == [MeshLinkKey("alpha"), MeshLinkKey("beta")])
    }

    /// Stopped and untracked links stay silent: a send on a stopped link must not resurrect it.
    @Test func stoppedLinksStaySilent() {
        let clock = VirtualClock()
        var schedule = MeshHeartbeatSchedule()
        schedule.start(Self.alpha, now: clock.now)
        schedule.stop(Self.alpha)

        schedule.noteSent(Self.alpha, now: clock.now)
        clock.advance(by: MeshHeartbeatSchedule.interval)
        #expect(schedule.due(now: clock.now).isEmpty)
        #expect(schedule.trackedCount == 0)
    }

    /// Tracking is bounded by the connection cap, and a restart of an already-tracked link replaces
    /// rather than adds — so a reconnect never counts twice against the bound.
    @Test func trackingIsBoundedByTheConnectionCap() {
        let clock = VirtualClock()
        var schedule = MeshHeartbeatSchedule()
        for index in 0..<(MeshHeartbeatSchedule.maxTrackedLinks + 3) {
            schedule.start(MeshLinkKey("peer-\(index)"), now: clock.now)
        }
        #expect(schedule.trackedCount == MeshHeartbeatSchedule.maxTrackedLinks)

        schedule.start(MeshLinkKey("peer-0"), now: clock.now)
        #expect(schedule.trackedCount == MeshHeartbeatSchedule.maxTrackedLinks)

        schedule.removeAll()
        #expect(schedule.trackedCount == 0)
        clock.advance(by: MeshHeartbeatSchedule.interval)
        #expect(schedule.due(now: clock.now).isEmpty)
    }
}

// MARK: - MeshLinkAdvertisementTests

/// The TXT vocabulary: what the QUIC radio publishes, and what it believes.
@Suite(.serialized)
struct MeshLinkAdvertisementTests {

    /// The real advertisement `MeshNetworkManager.currentDiscoveryInfo()` produces for an open mesh.
    static let managerAdvertisement: [String: String] = [
        "v": "1",
        "sid": "6C61CB0E-6B0A-4E29-9A4C-1E1E1F0B4E2A",
        "meshID": "0E0F1A2B-3C4D-5E6F-7A8B-9C0D1E2F3A4B",
        "meshName": "Saturday",
        "memberCount": "3"
    ]

    /// The whole manager advertisement survives a publish/parse round trip unchanged. If `sid` did
    /// not, the tie-break would silently degrade to both-sides-dial with nothing failing.
    @Test func theManagerAdvertisementRoundTripsIntact() {
        let published = MeshLinkAdvertisement.publishedFields(from: Self.managerAdvertisement)
        #expect(published == Self.managerAdvertisement)
        #expect(MeshLinkAdvertisement.advertisement(from: published) == Self.managerAdvertisement)
        #expect(published[MeshLinkAdvertisement.sessionIDKey] != nil)
    }

    /// `fp` is withheld in BOTH directions — not published, and not believed when a peer publishes
    /// it. An asymmetry here is how a peer gets a fingerprint claim into a handle that this build
    /// would never make itself, and the fingerprint gate treats a mismatch as fatal.
    @Test func theFingerprintKeyIsWithheldInBothDirections() {
        var withFingerprint = Self.managerAdvertisement
        withFingerprint["fp"] = "0123456789abcdef"

        #expect(MeshLinkAdvertisement.publishedFields(from: withFingerprint)["fp"] == nil)
        #expect(MeshLinkAdvertisement.advertisement(from: withFingerprint)["fp"] == nil)
        #expect(MeshLinkAdvertisement.publishedFields(from: withFingerprint) == Self.managerAdvertisement)
    }

    /// The DEBUG probe's TXT record carries no `sid` — the hazard recorded for this item. Copying
    /// the probe's advertisement verbatim would leave every peer unrankable, and an unrankable peer
    /// is invited by both sides.
    @Test func theProbeAdvertisementCarriesNoSessionIDAndIsUnrankable() {
        let probeTXT = ["mesh-probe-host": "simulator"]
        let parsed = MeshLinkAdvertisement.advertisement(from: probeTXT)
        #expect(parsed[MeshLinkAdvertisement.sessionIDKey] == nil)
        #expect(
            MeshDialPreference.rank(
                localSessionID: "aaaa",
                peerSessionID: parsed[MeshLinkAdvertisement.sessionIDKey]
            ) == .unranked
        )
    }

    /// `sid` survives the field cap even when a peer floods the record; the cap drops labels, never
    /// the discriminator.
    @Test func theFieldCapNeverDropsTheSessionID() {
        var flooded: [String: String] = ["sid": "keep-me"]
        for index in 0..<40 {
            flooded["k\(index)"] = "v\(index)"
        }
        let parsed = MeshLinkAdvertisement.advertisement(from: flooded)
        #expect(parsed.count == MeshLinkAdvertisement.maxFields)
        #expect(parsed["sid"] == "keep-me")
    }

    /// An over-long value is dropped whole, never truncated. A truncated `sid` still looks like a
    /// `sid` and would rank — deciding the wrong side dials, silently and permanently.
    @Test func anOverlongValueIsDroppedRatherThanTruncated() {
        let long = String(repeating: "x", count: MeshLinkAdvertisement.maxFieldValueLength + 1)
        let parsed = MeshLinkAdvertisement.advertisement(from: ["sid": long, "v": "1"])
        #expect(parsed["sid"] == nil)
        #expect(parsed["v"] == "1")

        let atLimit = String(repeating: "x", count: MeshLinkAdvertisement.maxFieldValueLength)
        #expect(MeshLinkAdvertisement.advertisement(from: ["sid": atLimit])["sid"] == atLimit)
    }

    /// Empty values contribute nothing in either direction — an empty `sid` reads as absent to the
    /// tie-break anyway, and publishing empty keys only widens what a passive scanner sees.
    @Test func emptyValuesAreDropped() {
        let parsed = MeshLinkAdvertisement.publishedFields(from: ["sid": "", "v": "", "meshName": "x"])
        #expect(parsed == ["meshName": "x"])
    }

    /// The instance name is random per session, prefixed, and short enough for Bonjour's 63-byte
    /// instance-name limit. Random is the point: the archived MC peer id it replaces was stable
    /// across launches, so a passive scanner could link sightings of one person.
    @Test func theInstanceNameIsRandomAndBounded() {
        let names = (0..<8).map { _ in MeshLinkAdvertisement.randomInstanceName() }
        #expect(Set(names).count == names.count, "instance names must not repeat")
        for name in names {
            #expect(name.hasPrefix(MeshLinkAdvertisement.instanceNamePrefix))
            #expect(name.utf8.count <= 63)
            #expect(name.lowercased() == name, "the token is a frozen lowercase wire value")
        }
    }
}

// MARK: - NetworkMeshWireTests

/// The control stream's length framing, including the header a hostile peer controls.
@Suite(.serialized)
struct NetworkMeshWireTests {

    /// Round trip over the sizes that matter, including both boundaries.
    @Test func lengthsRoundTripUpToTheCeiling() throws {
        let ceiling = NetworkMeshSession.maxInboundWireBytes
        for length in [1, 2, 127, 128, 255, 256, 65_535, 65_536, ceiling] {
            let header = NetworkMeshWire.header(for: length)
            #expect(header.count == NetworkMeshWire.headerByteCount)
            #expect(try NetworkMeshWire.payloadLength(from: header, ceiling: ceiling) == length)
        }
    }

    /// A zero length, an over-ceiling length, and a short header are all refused BEFORE any payload
    /// byte is read — the length field is the one input that decides how much memory the next read
    /// allocates.
    @Test func implausibleHeadersAreRefusedBeforeAnyPayloadIsRead() {
        let ceiling = NetworkMeshSession.maxInboundWireBytes
        #expect(throws: MeshTransportError.invalidFrameLength) {
            _ = try NetworkMeshWire.payloadLength(from: NetworkMeshWire.header(for: 0), ceiling: ceiling)
        }
        #expect(throws: MeshTransportError.invalidFrameLength) {
            _ = try NetworkMeshWire.payloadLength(
                from: NetworkMeshWire.header(for: ceiling + 1), ceiling: ceiling
            )
        }
        #expect(throws: MeshTransportError.invalidFrameLength) {
            _ = try NetworkMeshWire.payloadLength(from: Data([0x00, 0x01]), ceiling: ceiling)
        }
        #expect(throws: MeshTransportError.invalidFrameLength) {
            _ = try NetworkMeshWire.payloadLength(
                from: Data([0xFF, 0xFF, 0xFF, 0xFF]), ceiling: ceiling
            )
        }
    }

    /// Both transports refuse the same frame. A payload that rides one radio and is dropped by the
    /// other is a bug that only appears once the fleet is mixed.
    @Test func bothTransportsShareOneInboundCeiling() {
        #expect(NetworkMeshSession.maxInboundWireBytes == MeshMultipeerSession.maxInboundWireBytes)
    }

    /// Every failure the transport can raise says something. This is the surface that makes a dead
    /// radio visible instead of silent, so an unnamed case would defeat its own purpose.
    @Test func everyTransportErrorCarriesADiagnostic() {
        let errors: [MeshTransportError] = [
            .tlsIdentityUnavailable, .oversizedFrame(byteCount: 99),
            .invalidFrameLength, .noControlStream, .frameBudgetSpent
        ]
        for error in errors {
            #expect(!error.diagnosticDescription.isEmpty, "\(error) has no diagnostic")
        }
        #expect(MeshTransportError.oversizedFrame(byteCount: 99).diagnosticDescription.contains("99"))
    }
}

// MARK: - EphemeralMeshTLSIdentityTests

/// The per-session self-signed certificate: parseable by the platform, and different every time.
@Suite(.serialized)
struct EphemeralMeshTLSIdentityTests {

    static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    /// The DER this code writes is a certificate the platform parser accepts, carrying the public
    /// key it was built from. That is the only correctness claim worth making: nothing in Fernlet
    /// reads a peer's certificate, so "Security parses it" is exactly what has to hold.
    @Test func theMintedCertificateParsesAndCarriesItsOwnPublicKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        let der = try EphemeralMeshTLSIdentity.selfSignedCertificateDER(
            for: privateKey,
            notBefore: Self.anchor,
            notAfter: Self.anchor.addingTimeInterval(86_400),
            serial: [0x01, 0x02, 0x03, 0x04]
        )
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            Issue.record("Security refused the DER this encoder produced")
            return
        }
        guard let summary = SecCertificateCopySubjectSummary(certificate) else {
            Issue.record("the certificate has no readable subject summary")
            return
        }
        #expect(summary as String == EphemeralMeshTLSIdentity.commonName)

        guard let publicKey = SecCertificateCopyKey(certificate),
              let external = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            Issue.record("the certificate's public key could not be read back")
            return
        }
        #expect(external as Data == privateKey.publicKey.x963Representation)
    }

    /// Two mints share nothing. "Never reused across meshes" is the plan's wording; this is what it
    /// means in bytes.
    @Test func everyMintIsANewIdentity() throws {
        let first = try EphemeralMeshTLSIdentity.mint(now: Self.anchor)
        let second = try EphemeralMeshTLSIdentity.mint(now: Self.anchor)
        #expect(first.certificateDER != second.certificateDER)
        #expect(!first.certificateDER.isEmpty)
    }

    /// A certificate minted with the production validity window is a well-formed trust input —
    /// the shape a TLS stack will hand to its (accept-any) validator.
    @Test func aMintedCertificateIsAWellFormedTrustInput() throws {
        let der = try EphemeralMeshTLSIdentity.selfSignedCertificateDER(
            for: P256.Signing.PrivateKey(),
            notBefore: Self.anchor.addingTimeInterval(-EphemeralMeshTLSIdentity.clockSkewSeconds),
            notAfter: Self.anchor.addingTimeInterval(EphemeralMeshTLSIdentity.lifetimeSeconds),
            serial: EphemeralMeshTLSIdentity.randomSerial()
        )
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            Issue.record("Security refused the DER this encoder produced")
            return
        }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        #expect(trust != nil, "a self-signed certificate must still be a well-formed one")
    }

    /// Serial numbers are positive and bounded — a negative DER integer is a certificate some
    /// parsers reject outright.
    @Test func serialNumbersArePositiveAndBounded() {
        for _ in 0..<32 {
            let serial = EphemeralMeshTLSIdentity.randomSerial()
            #expect(serial.count == EphemeralMeshTLSIdentity.serialByteCount)
            #expect((serial.first ?? 0xFF) < 0x80, "the high bit must be clear so the integer is positive")
        }
    }

    /// The DER primitives: short-form and long-form lengths, and the integer padding rule.
    @Test func theDEREncoderFollowsTheLengthAndIntegerRules() {
        #expect(MeshCertificateDER.length(0) == [0x00])
        #expect(MeshCertificateDER.length(127) == [0x7F])
        #expect(MeshCertificateDER.length(128) == [0x81, 0x80])
        #expect(MeshCertificateDER.length(300) == [0x82, 0x01, 0x2C])

        // High bit set → one padding byte, so the value stays positive.
        #expect(MeshCertificateDER.integer([0x80]) == [0x02, 0x02, 0x00, 0x80])
        // Leading zeros stripped.
        #expect(MeshCertificateDER.integer([0x00, 0x00, 0x2A]) == [0x02, 0x01, 0x2A])
        // All-zero collapses to a single zero rather than nothing.
        #expect(MeshCertificateDER.integer([0x00, 0x00]) == [0x02, 0x01, 0x00])
        #expect(MeshCertificateDER.bitString([0xAB]) == [0x03, 0x02, 0x00, 0xAB])
        #expect(MeshCertificateDER.sequence([0x05, 0x00]) == [0x30, 0x02, 0x05, 0x00])
    }
}

// MARK: - NetworkMeshSessionTests

/// The QUIC session's observable surface: what its channel publishes, and what it leaves behind.
@MainActor
@Suite(.serialized)
struct NetworkMeshSessionTests {

    /// The channel publishes `.idle`, `.connected` and `.disconnected`, and never `.discovered`.
    ///
    /// The parity that matters: `ProximityCoordinator.shouldInviteDiscoveredPeer` is a second,
    /// dormant inviter policy comparing `sessionID < remoteSID` — the OPPOSITE direction to the live
    /// `MeshNetworkManager.shouldInitiateInvite` (`>`). It wakes the moment a conformer emits a
    /// discovered state, and two policies pointing opposite ways means neither side dials.
    @Test func theChannelNeverPublishesADiscoveredState() async throws {
        let session = NetworkMeshSession()
        let peer = PeerHandle(
            id: UUID(), displayHint: "fernlet-mesh-abc", discoveryInfo: ["sid": "aaaa"],
            advertisedFingerprint: nil
        )
        let channel = NetworkPeerChannel(peer: peer, session: session)

        var observed: [PeerTransportState] = []
        let subscription = channel.state.sink { observed.append($0) }
        defer { subscription.cancel() }

        try await channel.startAdvertising(
            serviceType: NetworkMeshSession.friendServiceType, discoveryInfo: [:]
        )
        try await channel.startBrowsing(serviceType: NetworkMeshSession.friendServiceType)
        try await channel.invite(peer)
        channel.notifyConnected()
        channel.receive(Data([0x01]), at: Date())
        channel.notifyDisconnected(reason: "test")
        await channel.disconnect()

        #expect(observed == [.idle, .connected(peer), .disconnected(reason: "test"), .idle])
        for state in observed {
            if case .discovered = state {
                Issue.record("the QUIC channel published .discovered — the dormant opposite-direction policy wakes")
            }
        }
    }

    /// The source itself never constructs a discovered state. The publisher test above can only
    /// cover the paths it drives; this covers the ones nobody has written yet.
    @Test func theTransportSourceNeverConstructsADiscoveredState() throws {
        let path = "FernletKit/Sources/ProximityKit/Transport/NetworkMeshSession.swift"
        let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
        let offenders = source
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return false }
                return line.contains(".discovered(") || line.contains("PeerTransportState.discovered")
            }
            .map { "\(path):\($0.offset + 1)" }
        #expect(
            offenders.isEmpty,
            "the QUIC transport constructs PeerTransportState.discovered at \(offenders) — see the type's docs"
        )
    }

    /// A frame delivered to the channel reaches its inbound publisher with the peer and byte count
    /// the coordinator's size gate reads.
    @Test func inboundFramesCarryTheirPeerAndByteCount() {
        let session = NetworkMeshSession()
        let peer = PeerHandle(
            id: UUID(), displayHint: "fernlet-mesh-abc", discoveryInfo: nil, advertisedFingerprint: nil
        )
        let channel = NetworkPeerChannel(peer: peer, session: session)

        var frames: [InboundPeerFrame] = []
        let subscription = channel.inbound.sink { frames.append($0) }
        defer { subscription.cancel() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        channel.receive(Data(repeating: 0x07, count: 12), at: now)

        #expect(frames.count == 1)
        #expect(frames.first?.peer == peer)
        #expect(frames.first?.bytesReceived == 12)
        #expect(frames.first?.receivedAt == now)
    }

    /// Teardown leaves no peer identities behind. The map exists only to keep one device the same
    /// peer for the life of a session; keeping it past a stop would link two runs of the radio to
    /// one device, which is what the per-session random Bonjour name exists to prevent.
    @Test func stopClearsEverySessionScopedMap() {
        let session = NetworkMeshSession()
        session.stop()
        #expect(session.trackedEndpointCountForTesting == 0)
        #expect(session.linkTableForTesting.occupiedSlotCount == 0)
        #expect(session.linkTableForTesting.cachedEndpointCount == 0)
        #expect(session.connectedPeers.isEmpty)
        #expect(!session.isRunning)
    }

    /// A session identity is minted once per endpoint and both halves are minted together, so a
    /// re-sighting resolves to the same `id` AND the same endpoint key — the property every slot,
    /// QR binding and device cap above the transport depends on.
    @Test func oneIdentityPerEndpointIsMintedOnceAndPairedForever() {
        var map = MeshSessionIdentityMap()
        let key = MeshLinkKey("alpha")
        let first = map.identity(for: key)
        let again = map.identity(for: key)

        #expect(first == again)
        #expect(map.trackedCount == 1)

        let handle = PeerHandle(
            id: first.id, displayHint: "x", discoveryInfo: nil,
            advertisedFingerprint: nil, endpoint: first.endpoint
        )
        #expect(map.key(for: handle) == key)

        let other = map.identity(for: MeshLinkKey("beta"))
        #expect(other.id != first.id)
        #expect(other.endpoint != first.endpoint)
    }

    /// The identity map is bounded oldest-first, and eviction drops BOTH directions — a map where
    /// one direction outlived the other would route a handle to an endpoint that no longer owns it.
    @Test func theIdentityMapIsBoundedAndEvictsBothDirections() {
        var map = MeshSessionIdentityMap()
        let first = map.identity(for: MeshLinkKey("peer-0"))
        let firstHandle = PeerHandle(
            id: first.id, displayHint: "x", discoveryInfo: nil,
            advertisedFingerprint: nil, endpoint: first.endpoint
        )
        for index in 1...MeshSessionIdentityMap.maxTrackedEndpoints {
            _ = map.identity(for: MeshLinkKey("peer-\(index)"))
        }
        #expect(map.trackedCount == MeshSessionIdentityMap.maxTrackedEndpoints)
        #expect(map.key(for: firstHandle) == nil, "the evicted endpoint must not still route")

        map.removeAll()
        #expect(map.trackedCount == 0)
    }
}

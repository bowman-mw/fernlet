import Foundation
import Testing
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshDialPolicyTests

// The exhaustive tier-1 battery for the mesh dial tie-break, written BEFORE the QUIC transport
// exists because the QUIC conformer inherits this decision wholesale.
//
// Two policies are pinned here, and they are NOT the same code:
//
//   * `MeshNetworkManager.shouldInitiateInvite` — the PRODUCTION mesh decision, over the per-launch
//     random `sid` both sides publish in their Bonjour TXT. This is the one that survives a
//     transport swap: it reads `PeerHandle.discoveryInfo["sid"]`, not anything MC-shaped.
//   * `MeshProbeDiscoveryPolicy.allowsOutboundConnection` — the DEBUG feasibility probe's separate
//     copy, over Bonjour service names plus a device/Simulator classification. The probe is the
//     lane the QUIC work is being prototyped on, so its shape is the one a Network.framework
//     conformer is most likely to copy.
//
// The property that matters for both is the same, and it is the one that deadlocked the mesh
// before (see the errno-61 block above `MeshNetworkManager.shouldInitiateInvite`): both peers
// browse AND advertise, so both discover each other, and EXACTLY ONE must dial. Zero strands the
// pair forever; two race and fail one side.
//
// Everything below enumerates a fixed fixture matrix in bounded nested loops — no randomness, no
// clock, no radios — so a regression names the exact combination that broke.

/// The pure half: both dial policies evaluated directly, over the full bounded input matrix.
@Suite(.serialized)
struct MeshDialPolicyTests {

    // MARK: - Fixtures

    /// One side of a simulated discovery pair.
    ///
    /// `txtHasArrived` is deliberately a property of the peer being *looked at*: it models whether
    /// THIS side's Bonjour TXT record has reached the other side yet. An absent record classifies
    /// its owner as `device` (see `MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord:)`), which is
    /// not hypothetical — a Simulator was observed seeing a peer before its TXT arrived, filing it
    /// as `[device]`, and dialling on that basis.
    struct DialSide {
        let serviceName: String
        let isSimulator: Bool
        let txtHasArrived: Bool
    }

    /// Service-name pairs, each already in ascending order so a test can name the expected dialer
    /// without restating `<`. Adjacent, prefix and digit-rollover pairs are included because the
    /// device↔device branch is decided by this comparison ALONE, and near-equal names are where a
    /// comparison that is subtly not a total order shows up.
    static let namePairs: [(lower: String, higher: String)] = [
        ("fernlet-probe-a", "fernlet-probe-z"),
        ("fernlet-probe-a", "fernlet-probe-b"),
        ("fernlet-probe-aaaa", "fernlet-probe-aaab"),
        ("fernlet-probe-a", "fernlet-probe-aa"),
        ("fernlet-probe-0", "fernlet-probe-1")
    ]

    /// Every ordered device/Simulator combination, as (lower-named side, higher-named side), so the
    /// matrix covers "the Simulator holds the lower name" and "the device holds the lower name"
    /// separately — the two orders that a name-only tie-break and a kind-only tie-break disagree on.
    static let kindPairs: [(lowerIsSimulator: Bool, higherIsSimulator: Bool)] = [
        (false, false), (false, true), (true, false), (true, true)
    ]

    /// Whether each side's TXT has reached the other yet: settled, one-way, and the pre-TXT window.
    static let txtArrivals: [(lowerArrived: Bool, higherArrived: Bool)] = [
        (true, true), (false, true), (true, false), (false, false)
    ]

    static let simDialFlags = [false, true]

    // MARK: - Probe policy: totality

    /// Totality, in the only form a `Bool`-returning pure function admits: every classification
    /// combination has a PINNED answer, restated here as a table independent of the implementation.
    /// A future edit that adds a branch has to change this table too.
    @Test func probePolicy_everyClassificationCombinationHasAPinnedAnswer() {
        var checked = 0
        for localIsSimulator in [false, true] {
            for candidateIsSimulator in [false, true] {
                for simDial in Self.simDialFlags {
                    for names in [("fernlet-probe-a", "fernlet-probe-b"), ("fernlet-probe-b", "fernlet-probe-a")] {
                        let local = DialSide(serviceName: names.0, isSimulator: localIsSimulator, txtHasArrived: true)
                        let candidate = DialSide(serviceName: names.1, isSimulator: candidateIsSimulator, txtHasArrived: true)
                        let expected = Self.expectedProbeDecision(
                            localIsSimulator: localIsSimulator,
                            candidateIsSimulator: candidateIsSimulator,
                            localNameSortsLower: names.0 < names.1,
                            simDial: simDial
                        )
                        let context = "localSim=\(localIsSimulator) candidateSim=\(candidateIsSimulator)"
                        #expect(Self.probeDials(from: local, to: candidate, simDial: simDial) == expected,
                                "\(context) names=\(names) flag=\(simDial)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 16, "The classification table must be enumerated exhaustively")
    }

    // MARK: - Probe policy: antisymmetry

    /// The core property, over the settled matrix: evaluate the SAME pair from both sides and count
    /// the dialers. Exactly one, everywhere — except the deliberately refused Simulator pair.
    @Test func probePolicy_settledPairsYieldExactlyOneDialer() {
        var checked = 0
        for names in Self.namePairs {
            #expect(names.lower < names.higher, "test premise: fixture names are in ascending order")
            for kinds in Self.kindPairs {
                for simDial in Self.simDialFlags {
                    let count = Self.settledDialerCount(names: names, kinds: kinds, simDial: simDial)
                    let expected = Self.expectedSettledDialerCount(kinds: kinds, simDial: simDial)
                    #expect(count == expected,
                            "\(names) kinds=\(kinds) flag=\(simDial): expected \(expected) dialer(s), got \(count)")
                    #expect(count < 2, "No settled combination may have both sides dial: \(names) \(kinds)")
                    checked += 2
                }
            }
        }
        #expect(checked == 80, "5 name pairs x 4 classification pairs x 2 flags x 2 sides")
    }

    /// Which side dials, not just how many. Mixed pairs are decided by KIND (the Simulator dials,
    /// because only it can reach the device's address); same-kind pairs are decided by NAME.
    @Test func probePolicy_theSimulatorDialsTheDeviceAndOtherwiseTheLowerNameDials() {
        for names in Self.namePairs {
            let simDialsDevice = Self.probeDials(
                from: DialSide(serviceName: names.higher, isSimulator: true, txtHasArrived: true),
                to: DialSide(serviceName: names.lower, isSimulator: false, txtHasArrived: true),
                simDial: false
            )
            #expect(simDialsDevice, "A Simulator dials a device even from the HIGHER name: \(names)")

            for isSimulator in [false, true] {
                let lower = DialSide(serviceName: names.lower, isSimulator: isSimulator, txtHasArrived: true)
                let higher = DialSide(serviceName: names.higher, isSimulator: isSimulator, txtHasArrived: true)
                #expect(Self.probeDials(from: lower, to: higher, simDial: true),
                        "The lower name dials its same-kind peer: \(names) sim=\(isSimulator)")
                #expect(!Self.probeDials(from: higher, to: lower, simDial: true),
                        "The higher name never dials its same-kind peer: \(names) sim=\(isSimulator)")
            }
        }
    }

    // MARK: - Probe policy: the `<` branch and equal names

    /// The device↔device branch in isolation — the one the device↔Simulator test lane can never
    /// reach, because the TXT marking makes the Simulator the dialer there unconditionally. Until
    /// two physical devices are in the same room, this test is its ONLY coverage.
    @Test func probePolicy_deviceToDeviceIsDecidedByServiceNameOrderAlone() {
        for names in Self.namePairs {
            let lower = DialSide(serviceName: names.lower, isSimulator: false, txtHasArrived: true)
            let higher = DialSide(serviceName: names.higher, isSimulator: false, txtHasArrived: true)
            for simDial in Self.simDialFlags {
                #expect(Self.probeDials(from: lower, to: higher, simDial: simDial),
                        "device↔device: \(names.lower) must dial \(names.higher)")
                #expect(!Self.probeDials(from: higher, to: lower, simDial: simDial),
                        "device↔device: \(names.higher) must not dial \(names.lower)")
            }
        }
    }

    /// The Simulator-dial debug flag is inert outside the Simulator↔Simulator branch. Pinned so a
    /// future widening of the flag cannot silently change a device's behaviour.
    @Test func probePolicy_theSimulatorDialFlagChangesNothingOutsideSimulatorPairs() {
        for names in Self.namePairs {
            for kinds in Self.kindPairs where !(kinds.lowerIsSimulator && kinds.higherIsSimulator) {
                let off = Self.settledDialerCount(names: names, kinds: kinds, simDial: false)
                let on = Self.settledDialerCount(names: names, kinds: kinds, simDial: true)
                #expect(off == on, "The debug flag must not move a non-Simulator pair: \(names) \(kinds)")
            }
        }
    }

    /// Equal service names: refused from both sides, in every classification and under either flag.
    ///
    /// Never "both dial" — that is the property being bought. Refusing is right because a name
    /// collision means the browser is showing us our OWN advertisement (service names are per-launch
    /// random UUIDs), and dialling yourself opens a tunnel to nowhere. Two genuinely distinct peers
    /// colliding on a random UUID is not a case this policy defends, and cannot be: with equal
    /// names there is no value left to break the tie with.
    @Test func probePolicy_identicalServiceNamesAreRefusedFromBothSides() {
        for names in Self.namePairs {
            for kinds in Self.kindPairs {
                for simDial in Self.simDialFlags {
                    let a = DialSide(serviceName: names.lower, isSimulator: kinds.lowerIsSimulator, txtHasArrived: true)
                    let b = DialSide(serviceName: names.lower, isSimulator: kinds.higherIsSimulator, txtHasArrived: true)
                    #expect(!Self.probeDials(from: a, to: b, simDial: simDial),
                            "Equal names must never dial: \(names.lower) \(kinds) flag=\(simDial)")
                    #expect(!Self.probeDials(from: b, to: a, simDial: simDial),
                            "Equal names must never dial (mirror): \(names.lower) \(kinds) flag=\(simDial)")
                }
            }
        }
    }

    /// Self-comparison, and the two other refusals that are not tie-breaks at all: an empty name or
    /// id (an unresolved browse result) and an id already attempted.
    @Test func probePolicy_neverDialsItselfOrAnUnusableCandidate() {
        let usable = DialSide(serviceName: "fernlet-probe-b", isSimulator: false, txtHasArrived: true)
        let itself = DialSide(serviceName: usable.serviceName, isSimulator: false, txtHasArrived: true)
        #expect(!Self.probeDials(from: usable, to: itself, simDial: true), "A peer must never dial itself")

        for names in [("", "fernlet-probe-b"), ("fernlet-probe-b", "")] {
            #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
                localServiceName: names.0,
                candidateServiceName: names.1,
                candidateID: "id",
                attemptedEndpointIDs: [],
                localRunsInSimulator: false,
                candidateRunsInSimulator: false
            ), "An empty service name is not a rankable candidate: \(names)")
        }
        #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-a",
            candidateServiceName: "fernlet-probe-b",
            candidateID: "",
            attemptedEndpointIDs: [],
            localRunsInSimulator: false,
            candidateRunsInSimulator: false
        ), "An empty endpoint id is not a dialable candidate")
        #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-a",
            candidateServiceName: "fernlet-probe-b",
            candidateID: "tried",
            attemptedEndpointIDs: ["tried"],
            localRunsInSimulator: false,
            candidateRunsInSimulator: false
        ), "An already-attempted endpoint must not be re-dialled")
    }

    // MARK: - Probe policy: missing and late TXT

    /// The classification rule itself, reachable now that it takes a TXT dictionary rather than a
    /// `Bonjour.Endpoint` (which has no public initializer). An ABSENT record reads as `device`.
    @Test func probePolicy_anAbsentOrUnrecognizedTXTRecordReadsAsDevice() {
        #expect(MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord: ["mesh-probe-host": "simulator"]))
        #expect(!MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord: [:]),
                "An absent TXT record must read as device — observed on the sim↔sim lane")
        #expect(!MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord: ["mesh-probe-host": "device"]))
        #expect(!MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord: ["mesh-probe-host": "Simulator"]),
                "The TXT value is a frozen lowercase token, not a display string")
        #expect(!MeshProbeDiscoveryPolicy.runsInSimulator(txtRecord: ["host": "simulator"]),
                "A value under another key must not classify the peer")
    }

    /// The safety property that makes the unsettled window survivable: no TXT state can leave a
    /// pair that contains at least one physical device with NOBODY dialling. Double-dialling in the
    /// window is possible and accepted; a deadlock is not.
    @Test func probePolicy_noTXTStateDeadlocksAPairContainingADevice() {
        var checked = 0
        for names in Self.namePairs {
            for kinds in Self.kindPairs where !(kinds.lowerIsSimulator && kinds.higherIsSimulator) {
                for arrival in Self.txtArrivals {
                    let count = Self.dialerCount(names: names, kinds: kinds, arrival: arrival, simDial: false)
                    #expect(count >= 1,
                            "Deadlock: \(names) kinds=\(kinds) txt=\(arrival) left both sides listening")
                    checked += 1
                }
            }
        }
        #expect(checked == 60, "5 name pairs x 3 device-containing classification pairs x 4 TXT states")
    }

    /// Re-classification stability, stated as the property that actually protects the mesh: a TXT
    /// record ARRIVING can only ever withdraw permission to dial, never grant it.
    ///
    /// `device` is the classification that grants the most permission, and it is also what an absent
    /// record reads as, so the pre-TXT window is over-eager rather than under-eager. That is why a
    /// late TXT can turn a double dial into a single dial but can never turn a single dial into a
    /// deadlock: the side that lost permission is never the only side that had it.
    @Test func probePolicy_aLateTXTOnlyEverWithdrawsPermissionToDial() {
        var checked = 0
        for names in Self.namePairs {
            for ordered in [(names.lower, names.higher), (names.higher, names.lower)] {
                for localIsSimulator in [false, true] {
                    for simDial in Self.simDialFlags {
                        let local = DialSide(serviceName: ordered.0, isSimulator: localIsSimulator, txtHasArrived: true)
                        let before = DialSide(serviceName: ordered.1, isSimulator: true, txtHasArrived: false)
                        let after = DialSide(serviceName: ordered.1, isSimulator: true, txtHasArrived: true)
                        let dialsBefore = Self.probeDials(from: local, to: before, simDial: simDial)
                        let dialsAfter = Self.probeDials(from: local, to: after, simDial: simDial)
                        #expect(!dialsAfter || dialsBefore,
                                "A late TXT GRANTED a dial: \(ordered) localSim=\(localIsSimulator) flag=\(simDial)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 40, "5 name pairs x 2 name roles x 2 local kinds x 2 flags")
    }

    /// The Simulator pair, pinned across every TXT state — including the one the loop's sim↔sim
    /// experiment actually hit. With both records settled the pair is refused by default; while one
    /// record is still missing the Simulator that cannot see the marking dials anyway, which is how
    /// a "refused" configuration produced a live Simulator→Simulator tunnel.
    @Test func probePolicy_simulatorPairsDialOnlyBeforeTheirTXTArrivesOrUnderTheDebugFlag() {
        let kinds = (lowerIsSimulator: true, higherIsSimulator: true)
        for names in Self.namePairs {
            for simDial in Self.simDialFlags {
                for arrival in Self.txtArrivals {
                    let count = Self.dialerCount(names: names, kinds: kinds, arrival: arrival, simDial: simDial)
                    let expected = Self.expectedSimulatorPairDialers(arrival: arrival, simDial: simDial)
                    #expect(count == expected,
                            "sim↔sim \(names) txt=\(arrival) flag=\(simDial): expected \(expected), got \(count)")
                }
            }
        }
    }

    // MARK: - Production mesh policy (`sid`)

    /// Session-id fixtures, ascending. The extremes bracket the whole space; the adjacent, rollover
    /// and case-boundary pairs are the near-equal inputs a comparison that is not a total order
    /// fails on. `UUID().uuidString` is uppercase, so the mixed-case pair models a peer that
    /// lower-cases its advertisement — the tie-break must still be a total order across the two.
    static let sessionIDPairs: [(lower: String, higher: String)] = [
        ("00000000-0000-4000-8000-000000000000", "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF"),
        ("A1B2C3D4-0000-4000-8000-000000000000", "A1B2C3D4-0000-4000-8000-000000000001"),
        ("0F000000-0000-4000-8000-000000000000", "10000000-0000-4000-8000-000000000000"),
        ("A0000000-0000-4000-8000-000000000000", "a0000000-0000-4000-8000-000000000000")
    ]

    /// The real session ids a side can hold. A manager always knows its OWN sid (it is a
    /// `UUID().uuidString` minted at init), so only the PEER's value can be missing.
    static let localSessionIDs = [
        "00000000-0000-4000-8000-000000000000",
        "A1B2C3D4-0000-4000-8000-000000000000",
        "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF"
    ]

    /// Antisymmetry over every ordering of two advertisements: exactly one side invites.
    ///
    /// Direction matters and is asserted explicitly: the HIGHER session id dials. It is pinned
    /// rather than left implicit because a second, currently-unreachable spelling of this decision
    /// exists — `ProximityCoordinator.shouldInviteDiscoveredPeer` compares `sessionID < remoteSID`,
    /// the OPPOSITE way — and it wakes up the moment a transport starts emitting
    /// `PeerTransportState.discovered` (no shipping conformer does today). If the QUIC conformer
    /// emits it, the two layers disagree about who dials, and this assertion is where that shows up.
    @Test func sidPolicy_exactlyOneSideInvitesAndItIsTheHigherSessionID() {
        for pair in Self.sessionIDPairs {
            #expect(pair.lower < pair.higher, "test premise: fixture session ids are in ascending order")
            let lowerDials = MeshNetworkManager.shouldInitiateInvite(
                localSessionID: pair.lower, peerSessionID: pair.higher
            )
            let higherDials = MeshNetworkManager.shouldInitiateInvite(
                localSessionID: pair.higher, peerSessionID: pair.lower
            )
            #expect(lowerDials != higherDials, "Exactly one side must invite: \(pair)")
            #expect(higherDials, "The higher session id is the inviter: \(pair)")
        }
    }

    /// Identical session ids refuse on BOTH sides — never both-dial.
    ///
    /// `sid` is a per-launch random UUID, so two advertisements carrying the same one are our own
    /// echo (a stale Bonjour cache of this process, the ghost `PresenceManager` filters by hand),
    /// and refusing is correct. The cost is that a peer replaying our `sid` back at us suppresses
    /// our invite; that is a denial of discovery it could equally achieve by staying silent, not an
    /// authentication bypass. A genuine collision of two v4 UUIDs is not defended, and cannot be —
    /// with equal ids there is no value left to break the tie with.
    @Test func sidPolicy_identicalSessionIDsRefuseOnBothSides() {
        for sessionID in Self.localSessionIDs {
            #expect(!MeshNetworkManager.shouldInitiateInvite(
                localSessionID: sessionID, peerSessionID: sessionID
            ), "An echo of our own session id must never be invited: \(sessionID)")
        }
    }

    /// An unrankable peer is always invited, from either side. Deadlock is strictly worse than a
    /// redundant invite: a mutual invite fails one side with errno 61 and the disconnect-retry path
    /// recovers it, while mutual silence strands the pair permanently.
    @Test func sidPolicy_anUnrankablePeerIsAlwaysInvited() {
        for sessionID in Self.localSessionIDs {
            #expect(MeshNetworkManager.shouldInitiateInvite(localSessionID: sessionID, peerSessionID: nil),
                    "A peer with no advertised sid must be invited: \(sessionID)")
            #expect(MeshNetworkManager.shouldInitiateInvite(localSessionID: sessionID, peerSessionID: ""),
                    "A peer with an empty advertised sid must be invited: \(sessionID)")
        }
    }

    /// The full bounded matrix: three real session ids per side (including the equal diagonal) by
    /// three advertisement states per direction (seen, absent, empty), evaluated from both sides.
    ///
    /// One rule covers all 81 pairings. Both sides seeing a real value: exactly one dials, or zero
    /// when the ids are equal (the self-echo above). Anything degraded on either side: at least one
    /// dials. There is no combination where both sides fall silent on distinct peers.
    @Test func sidPolicy_noPairOfAdvertisementsCanLeaveBothSidesSilent() {
        var checked = 0
        for local in Self.localSessionIDs {
            for remote in Self.localSessionIDs {
                for localSees in Self.advertisementStates(of: remote) {
                    for remoteSees in Self.advertisementStates(of: local) {
                        let localDials = MeshNetworkManager.shouldInitiateInvite(
                            localSessionID: local, peerSessionID: localSees
                        )
                        let remoteDials = MeshNetworkManager.shouldInitiateInvite(
                            localSessionID: remote, peerSessionID: remoteSees
                        )
                        let count = (localDials ? 1 : 0) + (remoteDials ? 1 : 0)
                        let context = "local=\(local) remote=\(remote) sees=(\(localSees ?? "nil"), \(remoteSees ?? "nil"))"
                        if localSees == remote, remoteSees == local {
                            #expect(count == (local == remote ? 0 : 1), "Settled pair must have one dialer: \(context)")
                        } else {
                            #expect(count >= 1, "Degraded advertisement must never deadlock: \(context)")
                        }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 81, "3 local ids x 3 remote ids x 3 advertisement states x 3 advertisement states")
    }

    // MARK: - Helpers

    /// Runs the probe policy from `local` toward `candidate`, classifying the candidate the way a
    /// browser does: a Simulator whose TXT has not arrived yet is indistinguishable from a device.
    static func probeDials(from local: DialSide, to candidate: DialSide, simDial: Bool) -> Bool {
        MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: local.serviceName,
            candidateServiceName: candidate.serviceName,
            candidateID: "id-\(candidate.serviceName)",
            attemptedEndpointIDs: [],
            localRunsInSimulator: local.isSimulator,
            candidateRunsInSimulator: candidate.isSimulator && candidate.txtHasArrived,
            allowsSimulatorToSimulatorDial: simDial
        )
    }

    /// How many of the two sides dial, for one fully-specified pair.
    static func dialerCount(
        names: (lower: String, higher: String),
        kinds: (lowerIsSimulator: Bool, higherIsSimulator: Bool),
        arrival: (lowerArrived: Bool, higherArrived: Bool),
        simDial: Bool
    ) -> Int {
        let lower = DialSide(
            serviceName: names.lower, isSimulator: kinds.lowerIsSimulator, txtHasArrived: arrival.lowerArrived
        )
        let higher = DialSide(
            serviceName: names.higher, isSimulator: kinds.higherIsSimulator, txtHasArrived: arrival.higherArrived
        )
        let lowerDials = probeDials(from: lower, to: higher, simDial: simDial)
        let higherDials = probeDials(from: higher, to: lower, simDial: simDial)
        return (lowerDials ? 1 : 0) + (higherDials ? 1 : 0)
    }

    /// ``dialerCount(names:kinds:arrival:simDial:)`` with both TXT records already delivered.
    static func settledDialerCount(
        names: (lower: String, higher: String),
        kinds: (lowerIsSimulator: Bool, higherIsSimulator: Bool),
        simDial: Bool
    ) -> Int {
        dialerCount(names: names, kinds: kinds, arrival: (true, true), simDial: simDial)
    }

    /// The truth table, restated independently of the implementation.
    static func expectedProbeDecision(
        localIsSimulator: Bool,
        candidateIsSimulator: Bool,
        localNameSortsLower: Bool,
        simDial: Bool
    ) -> Bool {
        if localIsSimulator && candidateIsSimulator { return simDial && localNameSortsLower }
        if localIsSimulator { return true }
        if candidateIsSimulator { return false }
        return localNameSortsLower
    }

    /// Dialer count expected of a settled pair: one everywhere except the refused Simulator pair.
    static func expectedSettledDialerCount(
        kinds: (lowerIsSimulator: Bool, higherIsSimulator: Bool),
        simDial: Bool
    ) -> Int {
        guard kinds.lowerIsSimulator && kinds.higherIsSimulator else { return 1 }
        return simDial ? 1 : 0
    }

    /// Dialer count expected of a Simulator pair in each TXT state. A missing record makes its owner
    /// look like a device, and a Simulator always dials a device — which is how a pair configured to
    /// refuse each other still connects while the records are in flight.
    static func expectedSimulatorPairDialers(
        arrival: (lowerArrived: Bool, higherArrived: Bool),
        simDial: Bool
    ) -> Int {
        switch (arrival.lowerArrived, arrival.higherArrived) {
        case (true, true):   return simDial ? 1 : 0
        case (false, true):  return simDial ? 2 : 1
        case (true, false):  return 1
        case (false, false): return 2
        }
    }

    /// What one side may see of a peer whose real session id is `sessionID`: the value itself, no
    /// `sid` key at all, or an empty one. The last two are the same case to the policy and are kept
    /// apart because they arrive from different causes — an unresolved browse result versus a build
    /// that predates the key.
    static func advertisementStates(of sessionID: String) -> [String?] {
        [sessionID, nil, ""]
    }
}

// MARK: - MeshDialPolicyManagerTests

/// The manager half: the same decision reached through a live `MeshNetworkManager`, over the
/// discovery info it actually advertises.
///
/// Only the DECISION is observable at tier 1. `MeshNetworkManager` owns its `MeshMultipeerSession`
/// outright (`private let meshSession = MeshMultipeerSession()`), so there is no seam to inject a
/// `FakePeerTransport` through and no way to assert that an invite was actually SENT without
/// starting real radios. Whether the manager re-invites a peer whose classification changed after
/// the fact is therefore a transport-level question, and belongs with the QUIC conformer.
@Suite(.serialized) @MainActor
struct MeshDialPolicyManagerTests {
    let store = makeTestStore()

    /// Self-comparison through the real advertisement: a manager shown its own discovery info must
    /// not invite. This is the production shape of the equal-value case — `sid` is per-launch, so
    /// an advertisement carrying ours IS ours.
    @Test func manager_neverInvitesItsOwnAdvertisement() {
        let manager = MeshNetworkManager(store: store)
        let ownAdvertisement = PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: manager.currentDiscoveryInfo(),
            advertisedFingerprint: nil
        )

        #expect(!manager.shouldInitiateInvite(to: ownAdvertisement),
                "A manager must never invite its own echoed advertisement")
    }

    /// The instance method and the pure policy must not drift: the instance is only a reader of
    /// `discoveryInfo["sid"]` in front of the same comparison.
    @Test func manager_agreesWithThePurePolicyOnEveryAdvertisementState() {
        let manager = MeshNetworkManager(store: store)
        let localSessionID = manager.currentDiscoveryInfo()["sid"] ?? ""
        #expect(!localSessionID.isEmpty, "test premise: a manager always advertises a session id")

        let peerStates: [String?] = [
            "00000000-0000-0000-0000-000000000000",
            "ffffffff-ffff-ffff-ffff-ffffffffffff",
            localSessionID,
            nil,
            ""
        ]
        for peerSessionID in peerStates {
            let expected = MeshNetworkManager.shouldInitiateInvite(
                localSessionID: localSessionID, peerSessionID: peerSessionID
            )
            #expect(manager.shouldInitiateInvite(to: Self.peer(sessionID: peerSessionID)) == expected,
                    "Instance and policy disagree for peer sid \(peerSessionID ?? "nil")")
        }
    }

    /// The production analogue of a late TXT record: a peer first seen without an advertisement is
    /// invited (unrankable ⇒ invite), and can stop being the one we invite once its `sid` arrives.
    ///
    /// Same monotone direction as the probe's classification rule — the degraded reading is the
    /// permissive one, so a late advertisement can only ever withdraw our invite, never create a
    /// window where neither side had one.
    @Test func manager_aPeerThatLaterAdvertisesASessionIDCanStopBeingTheOneWeInvite() {
        let manager = MeshNetworkManager(store: store)
        let localSessionID = manager.currentDiscoveryInfo()["sid"] ?? ""
        #expect(!localSessionID.isEmpty, "test premise: a manager always advertises a session id")

        #expect(manager.shouldInitiateInvite(to: Self.peer(sessionID: nil)),
                "An unresolved peer must be invited rather than waited on")

        let higher = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        #expect(localSessionID < higher, "test premise: a lowercase sid sorts above an uppercase one")
        #expect(!manager.shouldInitiateInvite(to: Self.peer(sessionID: higher)),
                "Once the peer's higher sid arrives, it becomes the inviter and we stop")
        #expect(manager.shouldInitiateInvite(to: Self.peer(sessionID: "00000000-0000-0000-0000-000000000000")),
                "A peer whose arriving sid sorts below ours leaves us the inviter")
    }

    /// A peer handle carrying exactly the advertisement under test.
    static func peer(sessionID: String?) -> PeerHandle {
        var info: [String: String] = ["v": "1"]
        if let sessionID { info["sid"] = sessionID }
        return PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: info,
            advertisedFingerprint: nil
        )
    }
}

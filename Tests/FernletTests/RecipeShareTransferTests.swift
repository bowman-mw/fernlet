// RecipeShareTransferTests.swift
// FernletTests
//
// P9 item 3 pass 1 (Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md §17.1): the recipe-share
// radio's PAUSE/RESUME CONTRACT and its SEND PIPELINE as tier-1 values, settled before the bytes
// move to QUIC.
//
// The premise correction these cells encode: the recipe share is not a chunked transfer and never
// was — the payload crosses as one sealed frame — so "preserving pause/resume semantics" means
// preserving the RADIO's pause/resume, the shipped behaviour that closes this Fernlet to a third
// device while a pairing is held and reopens it when the pairing's record is evicted. The two bare
// calls that used to carry it are now one total table (`RecipeShareDiscoveryGate`), and the one that
// a transport swap would most plausibly get wrong — "pause" meaning "stand the connection down" —
// is refused by construction: a discovery pause is accepted in every phase of an exchange and moves
// none of them.
//
// Tier 1: no rig, no radio, no simulator, no clock. The manager cells drive the production helpers
// with `markRunningForTesting` and a MeshMultipeerSession that is never `start()`ed, exactly as
// ProximityRecipeShareCapTests does, so pause/resume toggle a flag and touch no MCNearbyService*.

@testable import ProximityKit
import Foundation
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

private final class RecipeTransferTestHost: ProximityHost {
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

/// A host whose display name the name-bound cells choose.
private final class NamedTransferTestHost: ProximityHost {
    let name: String
    init(name: String) { self.name = name }
    var proximityDisplayName: String { name }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

@MainActor
struct RecipeShareTransferTests {

    // MARK: - The pause/resume table

    /// The contract, written out independently of the implementation and checked over the whole
    /// cross-product of the radio's three facts. A table the production function is re-derived from
    /// would prove nothing, so this one names its expectation per row.
    @Test func discoveryGateAnswersTheWholeCrossProduct() {
        let events: [RecipeShareDiscoveryGate.Event] = [
            .connectionRegistered, .connectionsEvicted,
            .refreshRequested, .transportErrorWhileListening, .stopped
        ]
        var wrong: [String] = []
        for event in events {
            for isRunning in [true, false] {
                for isPaused in [true, false] {
                    for count in [0, 1, 2] {
                        let radio = RecipeShareDiscoveryGate.Radio(
                            isRunning: isRunning, isPaused: isPaused, connectionCount: count
                        )
                        let expected = Self.expectedVerdict(event, isRunning, isPaused, count)
                        let actual = RecipeShareDiscoveryGate.verdict(for: event, radio: radio)
                        if actual != expected {
                            wrong.append("\(event) run=\(isRunning) paused=\(isPaused) n=\(count): \(actual) ≠ \(expected)")
                        }
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "gate rows disagree with the contract:\n\(wrong.joined(separator: "\n"))")
    }

    /// The contract, spelled independently: discovery moves at exactly two moments.
    private static func expectedVerdict(
        _ event: RecipeShareDiscoveryGate.Event,
        _ isRunning: Bool,
        _ isPaused: Bool,
        _ count: Int
    ) -> RecipeShareDiscoveryGate.Verdict {
        switch event {
        case .connectionRegistered:
            return (count > 0 && !isPaused) ? .pause : .unchanged
        case .connectionsEvicted:
            return (count == 0 && isRunning && isPaused) ? .resume : .unchanged
        case .refreshRequested, .transportErrorWhileListening, .stopped:
            return .unchanged
        }
    }

    /// Resume is keyed on RECORD eviction, and a radio that is not running never comes back up: the
    /// two rules the table exists to freeze, asserted on their own so a regression names itself.
    @Test func resumeIsRefusedForAStoppedRadioAndWhileASecondPairingIsHeld() {
        let stopped = RecipeShareDiscoveryGate.Radio(isRunning: false, isPaused: true, connectionCount: 0)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionsEvicted, radio: stopped) == .unchanged)

        let stillPaired = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: true, connectionCount: 1)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionsEvicted, radio: stillPaired) == .unchanged)

        let evicted = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: true, connectionCount: 0)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionsEvicted, radio: evicted) == .resume)
    }

    /// A register while already paused is a no-op, and a register holding nothing is refused rather
    /// than closing a radio with no pairing to protect.
    @Test func pauseIsIdempotentAndNeverClosesARadioHoldingNothing() {
        let alreadyPaused = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: true, connectionCount: 1)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionRegistered, radio: alreadyPaused) == .unchanged)

        let empty = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: false, connectionCount: 0)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionRegistered, radio: empty) == .unchanged)

        let paired = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: false, connectionCount: 1)
        #expect(RecipeShareDiscoveryGate.verdict(for: .connectionRegistered, radio: paired) == .pause)
    }

    // MARK: - The exchange's state table

    /// Every cell of the transition table, including each refusal, by name.
    @Test func exchangeTransitionTableIsExactlyTheDocumentedOne() {
        #expect(Self.applied([.peerVerified]).phase == .verified)
        #expect(Self.applied([.peerVerified, .peerVerified]).phase == .verified)
        #expect(Self.applied([.peerVerified, .sendBegan(wireByteCount: 64)]).phase == .sending)
        #expect(Self.applied([.peerVerified, .sendBegan(wireByteCount: 64), .peerVerified]).phase == .sending)
        #expect(Self.applied([.peerVerified, .sendBegan(wireByteCount: 64), .sendCompleted]).phase == .sent)
        #expect(Self.applied([.peerVerified, .sendBegan(wireByteCount: 64), .sendFailed]).phase == .failed)
        #expect(Self.applied([.peerVerified, .sendBegan(wireByteCount: 64), .cancelled]).phase == .cancelled)
        #expect(Self.applied([.sendFailed]).phase == .failed)
        #expect(Self.applied([.cancelled]).phase == .cancelled)

        // The refusals.
        var connecting = RecipeShareTransfer(recipientID: UUID())
        #expect(connecting.apply(.sendBegan(wireByteCount: 64)) == false)
        #expect(connecting.apply(.sendCompleted) == false)
        #expect(connecting.phase == .connecting)

        var verified = RecipeShareTransfer(recipientID: UUID())
        verified.apply(.peerVerified)
        #expect(verified.apply(.sendCompleted) == false)
        #expect(verified.phase == .verified)

        var sending = Self.applied([.peerVerified, .sendBegan(wireByteCount: 64)])
        #expect(sending.apply(.sendBegan(wireByteCount: 64)) == false)
        #expect(sending.phase == .sending)
    }

    /// Every terminal phase refuses every phase event — a finished share cannot be restarted,
    /// re-completed or re-failed by a late callback.
    @Test func terminalPhasesRefuseEveryPhaseEvent() {
        let terminals: [[RecipeShareTransfer.Event]] = [
            [.peerVerified, .sendBegan(wireByteCount: 64), .sendCompleted],
            [.sendFailed],
            [.cancelled]
        ]
        let events: [RecipeShareTransfer.Event] = [
            .peerVerified, .sendBegan(wireByteCount: 64), .sendCompleted, .sendFailed, .cancelled
        ]
        for path in terminals {
            for event in events {
                var transfer = Self.applied(path)
                let before = transfer.phase
                #expect(transfer.apply(event) == false, "\(before) took \(event)")
                #expect(transfer.phase == before)
            }
        }
    }

    /// **The pass-1 row.** A discovery pause or resume is accepted in every phase, terminal
    /// included, and moves none of them — closing the radio to new peers is not pausing a share in
    /// flight. A pass-2 session that stood the connection down on a pause would break a send that
    /// MultipeerConnectivity keeps alive, and nothing above the transport would say so.
    @Test func discoveryPauseAndResumeNeverMoveTheExchange() {
        let paths: [[RecipeShareTransfer.Event]] = [
            [],
            [.peerVerified],
            [.peerVerified, .sendBegan(wireByteCount: 900_000)],
            [.peerVerified, .sendBegan(wireByteCount: 900_000), .sendCompleted],
            [.sendFailed],
            [.cancelled]
        ]
        for path in paths {
            var transfer = Self.applied(path)
            let phase = transfer.phase
            let bytes = transfer.wireByteCount
            let completions = transfer.completionCount

            // Hoisted: `#expect` expands its argument into a closure over an immutable `$0`, so a
            // mutating call cannot live inside the macro.
            let tookPause = transfer.apply(.discoveryPaused)
            #expect(tookPause)
            #expect(transfer.radioIsQuiet)
            #expect(transfer.phase == phase, "a discovery pause moved \(phase)")
            #expect(transfer.wireByteCount == bytes)
            #expect(transfer.completionCount == completions)

            let tookResume = transfer.apply(.discoveryResumed)
            #expect(tookResume)
            #expect(transfer.radioIsQuiet == false)
            #expect(transfer.phase == phase, "a discovery resume moved \(phase)")
            #expect(transfer.wireByteCount == bytes, "a resume restarted the share's byte count")
            #expect(transfer.completionCount == completions)
        }
    }

    /// The exactly-once oracle, over an exhaustive bounded walk of every event sequence of length
    /// **≤ 4** — the design note's bound. A share completes at most once, and it is `.sent` exactly
    /// when it has.
    ///
    /// The invariant is checked after EVERY event rather than only at the end, so every sequence of
    /// length 1…4 is a checked prefix of one of the 2 401 four-event walks. Checking only the end
    /// state hides a table that passes through an inconsistent one — `.sent` with no completion, or
    /// a completion with the phase somewhere else — and then lands consistent by luck.
    @Test func exchangeCompletesAtMostOnceOverEveryEventSequenceUpToFour() {
        let alphabet: [RecipeShareTransfer.Event] = [
            .peerVerified, .sendBegan(wireByteCount: 4_096), .sendCompleted,
            .sendFailed, .cancelled, .discoveryPaused, .discoveryResumed
        ]
        var violations: [String] = []
        for first in alphabet {
            for second in alphabet {
                for third in alphabet {
                    for fourth in alphabet {
                        let path = [first, second, third, fourth]
                        var transfer = RecipeShareTransfer(recipientID: UUID())
                        for (step, event) in path.enumerated() {
                            transfer.apply(event)
                            let consistent = (transfer.phase == .sent) == (transfer.completionCount == 1)
                            guard transfer.completionCount > 1 || !consistent else { continue }
                            violations.append("\(path.prefix(step + 1)): \(transfer.phase) × \(transfer.completionCount)")
                        }
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.count) prefixes broke the oracle:\n\(violations.prefix(5).joined(separator: "\n"))")
    }

    // MARK: - The route projection (what pass 2 has to build)

    /// A text-only recipe stays on the control stream; a recipe carrying a picture clears the bulk
    /// floor and earns a stream of its own — which is why a QUIC recipe radio needs the
    /// per-transfer-stream acceptor the presence radio deliberately has none of.
    @Test func routeIsUnknownBeforeTheSendAndSplitsAtTheBulkFloor() {
        let fresh = RecipeShareTransfer(recipientID: UUID())
        #expect(fresh.route == nil)

        let text = Self.applied([.peerVerified, .sendBegan(wireByteCount: 4_096)])
        #expect(text.route == .controlStream)

        let withPicture = Self.applied([
            .peerVerified,
            .sendBegan(wireByteCount: ProximityRecipeSharePayload.maxImageBytes)
        ])
        #expect(withPicture.route == .transferStream)
        #expect(ProximityRecipeSharePayload.maxImageBytes > MeshTransferStreamTable.bulkFloorBytes)

        // The floor claim: the recipe cap is above the bulk floor, so the largest honest share is
        // always a transfer-stream payload and the projection can never over-estimate.
        let largest = Self.applied([
            .peerVerified,
            .sendBegan(wireByteCount: ProximityRecipeSharePayload.maxWireBytes)
        ])
        #expect(largest.route == .transferStream)
    }

    // MARK: - The advertised name's byte bound

    /// The regression a naive pass-2 binding ships: `MeshLinkAdvertisement` DROPS an over-long
    /// value rather than truncating it, and a 24-Character name is not a 64-byte one.
    @Test func advertisedNameIsBoundedInBytesNotCharacters() {
        let cjk = String(repeating: "健", count: 24)
        #expect(cjk.utf8.count > RecipeShareAdvertisedName.maxByteCount)
        let publishable = RecipeShareAdvertisedName.publishable(cjk)
        #expect(publishable.isEmpty == false)
        #expect(publishable.utf8.count <= RecipeShareAdvertisedName.maxByteCount)

        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 24)
        let boundedEmoji = RecipeShareAdvertisedName.publishable(emoji)
        #expect(boundedEmoji.utf8.count <= RecipeShareAdvertisedName.maxByteCount)

        // Trimmed on grapheme boundaries: the result survives a UTF-8 round trip unchanged, which a
        // byte-sliced string would not.
        let roundTripped = String(decoding: Array(boundedEmoji.utf8), as: UTF8.self)
        #expect(roundTripped == boundedEmoji)
        #expect(boundedEmoji.contains("\u{FFFD}") == false)

        #expect(RecipeShareAdvertisedName.publishable("Alex") == "Alex")
        #expect(RecipeShareAdvertisedName.publishable("") == "")
        #expect(RecipeShareAdvertisedName.publishable("Ali\u{200B}ce") == "Alice")
        #expect(RecipeShareAdvertisedName.maxByteCount == MeshLinkAdvertisement.maxFieldValueLength)
    }

    /// The bound the mesh advertiser publishes under is the bound this name is held to, so a name
    /// that passes here is publishable by every transport unchanged.
    @Test func everyBoundedNameFitsTheAdvertisementFieldCap() {
        let samples = [
            "Alex", "", "   ", String(repeating: "a", count: 200),
            String(repeating: "健", count: 40), String(repeating: "🇬🇧", count: 30),
            "Ali\u{200B}ce\n\n Bob", String(repeating: "é", count: 50)
        ]
        for sample in samples {
            let name = RecipeShareAdvertisedName.publishable(sample)
            #expect(name.utf8.count <= RecipeShareAdvertisedName.maxByteCount, "\(sample.prefix(8)) overflows")
            #expect(name.count <= ItemNameModeration.maxNameLength)
        }
    }

    // MARK: - The manager's wiring

    /// The production resume path, through the gate helper rather than the old inline condition.
    @Test func managerResumesThroughTheGateOnlyWhenRunningAndPaused() {
        // ML5 (invariant HP0): the host is hoisted into its own `let` so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.multipeerSessionForTesting.pauseDiscovery()
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)

        // Not running: the gate holds the radio closed rather than advertising from a dark manager.
        #expect(manager.applyDiscoveryGateForTesting(.connectionsEvicted) == .unchanged)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)

        manager.markRunningForTesting()
        #expect(manager.applyDiscoveryGateForTesting(.connectionsEvicted) == .resume)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused == false)
    }

    /// The three events that must never move discovery, driven through the production helper.
    @Test func managerRefreshTransportErrorAndStopNeverMoveDiscovery() {
        // ML5 (invariant HP0): the host is hoisted into its own `let` so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        manager.multipeerSessionForTesting.pauseDiscovery()
        for event: RecipeShareDiscoveryGate.Event in [.refreshRequested, .transportErrorWhileListening, .stopped] {
            #expect(manager.applyDiscoveryGateForTesting(event) == .unchanged, "\(event) moved discovery")
            #expect(manager.multipeerSessionForTesting.isDiscoveryPaused, "\(event) reopened a paused radio")
        }
    }

    /// The manager's own copy of the pass-1 row: a gate verdict tells the live exchange the door
    /// moved and leaves its phase alone — and the record it tells was SEEDED from the radio.
    ///
    /// The seed is what makes the resume assertion mean anything. `radioIsQuiet` moves only on gate
    /// transitions, and the ordinary second share to an already-paired peer is minted *between*
    /// them: the pause happened when the pairing formed, and no further event follows. A record
    /// that defaulted to "open" would be wrong for that entire share, and a cell that read `false`
    /// off a value which was false from birth would pass without noticing.
    @Test func managerGateTellsTheExchangeWithoutMovingIt() {
        // ML5 (invariant HP0): the host is hoisted into its own `let` so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()

        manager.beginTransferForTesting(recipientID: UUID())
        #expect(manager.transferForTesting?.radioIsQuiet == false, "an open radio minted a quiet record")

        // The radio is ALREADY standing down at this mint — no gate event will follow it.
        manager.multipeerSessionForTesting.pauseDiscovery()
        manager.beginTransferForTesting(recipientID: UUID())
        #expect(manager.transferForTesting?.radioIsQuiet == true, "the record was not seeded from the radio")

        manager.applyTransferForTesting(.peerVerified)
        manager.applyTransferForTesting(.sendBegan(wireByteCount: 900_000))
        #expect(manager.transferForTesting?.phase == .sending)

        #expect(manager.applyDiscoveryGateForTesting(.connectionsEvicted) == .resume)
        #expect(manager.transferForTesting?.phase == .sending, "a resume moved a share in flight")
        #expect(manager.transferForTesting?.radioIsQuiet == false)
        #expect(manager.transferForTesting?.wireByteCount == 900_000, "a resume restarted the share")
    }

    /// The once-only send start, through the production helper: the second start is refused and the
    /// completion is still counted once.
    @Test func managerRefusesASecondSendStartForOneShare() {
        // ML5 (invariant HP0): the host is hoisted into its own `let` so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.beginTransferForTesting(recipientID: UUID())
        manager.applyTransferForTesting(.peerVerified)
        #expect(manager.applyTransferForTesting(.sendBegan(wireByteCount: 2_048)))
        #expect(manager.applyTransferForTesting(.sendBegan(wireByteCount: 2_048)) == false)
        #expect(manager.applyTransferForTesting(.sendCompleted))
        #expect(manager.applyTransferForTesting(.sendCompleted) == false)
        #expect(manager.transferForTesting?.completionCount == 1)
    }

    /// With no exchange record, an event is not a refusal — a missing record means a teardown ran,
    /// and refusing here would turn that into a silently dropped share.
    @Test func managerWithNoExchangeTakesEveryEvent() {
        // ML5 (invariant HP0): the host is hoisted into its own `let` so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        #expect(manager.transferForTesting == nil)
        #expect(manager.applyTransferForTesting(.sendBegan(wireByteCount: 2_048)))
        #expect(manager.applyTransferForTesting(.sendCompleted))
    }

    /// The one input the byte bound cannot publish: a SINGLE grapheme cluster wider than 64 bytes
    /// (a letter under 40 combining marks — `sanitizedName` strips zero-width and bidi scalars, not
    /// combining ones). Removing that one Character leaves nothing, and an empty `name` is not an
    /// absent one: published as `""` it would reach `moderatedPeerDisplayName` and render as the
    /// placeholder, losing a peer the transport hint could have named. The publisher omits the key
    /// and the receiver falls back on absent and empty alike.
    @Test func anUnpublishableNameIsOmittedAndTheReceiverFallsBackToTheHint() {
        let overWide = "e" + String(repeating: "\u{0301}", count: 40)
        #expect(overWide.count == 1, "the sample is not one grapheme cluster")
        #expect(overWide.utf8.count > RecipeShareAdvertisedName.maxByteCount)
        #expect(RecipeShareAdvertisedName.publishable(overWide).isEmpty, "the bound found something to publish")

        // ML5 (invariant HP0): the host is hoisted so it outlives the manager's `unowned` store.
        let host = NamedTransferTestHost(name: overWide)
        let manager = ProximityRecipeShareManager(store: host)
        let fields = manager.discoveryInfoForTesting
        #expect(fields["name"] == nil, "an empty name went on the air")
        #expect(fields["v"] == "1")
        #expect(fields["mode"] == "recipe")

        // The receive-side half: absent and empty both fall back, a real name does not.
        #expect(RecipeShareAdvertisedName.received(nil, hint: "fernlet-ab12") == "fernlet-ab12")
        #expect(RecipeShareAdvertisedName.received("", hint: "fernlet-ab12") == "fernlet-ab12")
        #expect(RecipeShareAdvertisedName.received("Alex", hint: "fernlet-ab12") == "Alex")
        // What a bare `??` would have rendered instead, and why the fallback is not cosmetic.
        #expect(ItemNameModeration.moderatedPeerDisplayName("") != "fernlet-ab12")
    }

    /// The omission above is for the one input that cannot be published — an ordinary name still
    /// rides the wire and still renders on the other side.
    @Test func anOrdinaryNameStillRidesTheWireAndRenders() {
        // ML5 (invariant HP0): the host is hoisted so it outlives the manager's `unowned` store.
        let host = NamedTransferTestHost(name: "Alex")
        let manager = ProximityRecipeShareManager(store: host)
        #expect(manager.discoveryInfoForTesting["name"] == "Alex")

        let rendered = ItemNameModeration.moderatedPeerDisplayName(
            RecipeShareAdvertisedName.received(manager.discoveryInfoForTesting["name"], hint: "fernlet-ab12")
        )
        #expect(rendered == "Alex")
    }

    /// The advertisement the production builder emits carries a byte-bounded name.
    @Test func managerAdvertisesAByteBoundedName() {
        let host = NamedTransferTestHost(name: String(repeating: "健", count: 40))
        let manager = ProximityRecipeShareManager(store: host)
        let fields = manager.discoveryInfoForTesting
        #expect(fields["v"] == "1")
        #expect(fields["mode"] == "recipe")
        let name = fields["name"] ?? ""
        #expect(name.isEmpty == false)
        #expect(name.utf8.count <= RecipeShareAdvertisedName.maxByteCount)
    }

    // MARK: - Rule-7 needles for pass 2

    /// The gate is the ONLY door to the radio's discovery. Pass 2 swaps the session out; a bare
    /// `pauseDiscovery()` added back beside it would leave the contract with two owners again, and
    /// the table would stop being the contract.
    ///
    /// Counting whole-file occurrences alone does not say that: deleting the call from inside the
    /// gate and adding one back in `registerConnection` keeps the count at 1 while handing the
    /// contract two owners. So the count is paired with CONTAINMENT — every occurrence must sit
    /// inside `applyDiscoveryGate`'s brace-matched body — which is what reddens on a relocation.
    /// (The usual grep-wall caveat stands: `let radio = session; radio.pauseDiscovery()` evades
    /// both halves. The wall is against drift, not against a determined author.)
    @Test func theManagerTouchesDiscoveryThroughTheGateAlone() throws {
        let source = MeshRoutedSourceScan.codeOnly(try Self.managerSource())
        let gateBody = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func applyDiscoveryGate(", in: source),
            "applyDiscoveryGate is gone — the discovery contract has no door"
        )
        for verb in ["session.pauseDiscovery()", "session.resumeDiscovery()"] {
            let whole = Self.occurrences(of: verb, in: source)
            let insideGate = Self.occurrences(of: verb, in: gateBody)
            #expect(whole == 1, "\(verb) is called \(whole) times; the gate is the one door")
            #expect(insideGate == whole, "\(verb) is called outside applyDiscoveryGate's own body")
        }
    }

    /// The advertised name's cap is the byte bound and nothing else: the Character cap it replaced
    /// must not come back beside it.
    @Test func theAdvertisementNameHasNoCharacterCap() throws {
        let source = try Self.managerSource()
        #expect(source.contains("RecipeShareAdvertisedName.publishable(displayName)"))
        #expect(source.contains("displayName.prefix(") == false,
                "a Character cap is back on the advertised name")
    }

    // MARK: - Helpers

    private static func applied(_ events: [RecipeShareTransfer.Event]) -> RecipeShareTransfer {
        var transfer = RecipeShareTransfer(recipientID: UUID())
        for event in events { transfer.apply(event) }
        return transfer
    }

    private static func managerSource() throws -> String {
        let path = "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift"
        return try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}

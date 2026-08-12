// AgeAssuranceTests.swift
//
// The age gates: intimacy tracking at 16+, live-session mesh chat at 13+.
//
// The determination comes from Apple's DeclaredAgeRange framework, but nothing here touches it — the
// app maps the system response to primitives (`lowerBound`/`upperBound`/provenance) at a single seam
// (`AgeAssuranceRequest`) so every rule below is reachable without the entitlement, a signed-in Apple
// Account, or a system prompt.
//
// The rules these pin:
//  - Fail closed. A device that has never asked allows nothing.
//  - A `.below` verdict is FINAL. The manual confirmation cannot reopen it — that is the whole point
//    of asking the system rather than a stepper.
//  - Provenance is asymmetric. A bracket without provenance cannot open a gate, but it still closes
//    one, because the cost of being wrong differs by direction.
//  - The record is device-local. It is never written to the synced settings blob.

import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
@testable import ProximityKit
@testable import Fernlet

// MARK: - The pure rules

struct AgeAssuranceRecordTests {

    private func determined(
        _ lower: Int?, _ upper: Int?, _ provenance: AgeAssuranceProvenance? = .selfDeclared
    ) -> AgeAssuranceRecord {
        AgeAssuranceRecord.unknown.determining(
            lowerBound: lower, upperBound: upper, provenance: provenance, now: .now
        )
    }

    @Test func aDeviceThatNeverAskedAllowsNothing() {
        let record = AgeAssuranceRecord.unknown
        for gate in AgeGate.allCases {
            #expect(!record.allows(gate), "\(gate) must fail closed before any determination")
            #expect(record.verdict(for: gate) == .undetermined)
        }
        #expect(!record.isDetermined)
    }

    @Test func anAdultBracketOpensEveryGate() {
        let record = determined(18, nil)
        for gate in AgeGate.allCases {
            #expect(record.allows(gate))
            #expect(record.verdict(for: gate) == .meets)
        }
    }

    /// The band that motivated the split: old enough to message friends nearby, not old enough for
    /// intimacy tracking.
    @Test func theThirteenToSixteenBandOpensChatButNotIntimacy() {
        let record = determined(13, 16)
        #expect(record.allows(.chat))
        #expect(!record.allows(.intimacy))
        #expect(!record.allows(.adult))
        #expect(record.verdict(for: .chat) == .meets)
        #expect(record.verdict(for: .intimacy) == .below)
    }

    @Test func theSixteenToEighteenBandOpensChatAndIntimacyButNotAdult() {
        let record = determined(16, 18)
        #expect(record.allows(.chat))
        #expect(record.allows(.intimacy))
        #expect(!record.allows(.adult))
    }

    @Test func anUnderThirteenBracketClosesEveryGate() {
        let record = determined(nil, 13)
        for gate in AgeGate.allCases {
            #expect(!record.allows(gate))
            #expect(record.verdict(for: gate) == .below)
        }
    }

    /// Toward opening a gate, weak evidence is not enough: a bracket the system returned without
    /// saying where it came from does not unlock, it falls through to the manual confirmation.
    @Test func aBracketWithoutProvenanceCannotOpenAGate() {
        let record = determined(18, nil, nil)
        for gate in AgeGate.allCases {
            #expect(!record.allows(gate))
            #expect(record.verdict(for: gate) == .undetermined)
        }
        // ...but it IS a determination, which the UI uses to explain why it is still asking.
        #expect(record.isDetermined)
    }

    /// Toward closing one, weak evidence IS enough. Same missing provenance, opposite direction,
    /// opposite answer — deliberately.
    @Test func aBracketWithoutProvenanceStillClosesAGate() {
        let record = determined(13, 16, nil)
        #expect(record.verdict(for: .intimacy) == .below)
        #expect(!record.allows(.intimacy))
        // And it cannot be talked out of, unlike the undetermined direction above.
        #expect(!record.mayOfferSelfAttestation(for: .intimacy))
        #expect(!record.selfAttesting(.intimacy).allows(.intimacy))
    }

    /// A response that says "sharing" but carries no bracket tells us nothing. It must not be read as
    /// evidence of being underage — that would lock a user out over a degenerate system reply.
    @Test func anEmptyBracketIsUndeterminedRatherThanBelow() {
        let record = determined(nil, nil)
        #expect(record.verdict(for: .chat) == .undetermined)
        #expect(record.verdict(for: .intimacy) == .undetermined)
        #expect(!record.isDetermined)
        // Undetermined leaves the manual confirmation available where the gate permits one...
        #expect(record.mayOfferSelfAttestation(for: .intimacy))
        // ...and chat still refuses it, because that is a property of the gate, not of the verdict.
        #expect(!record.mayOfferSelfAttestation(for: .chat))
    }

    // MARK: - The manual confirmation

    @Test func confirmingAGateOpensItButNeverChat() {
        let record = AgeAssuranceRecord.unknown.selfAttesting(.intimacy)
        #expect(record.allows(.intimacy))
        #expect(!record.allows(.adult), "Confirming 16 says nothing about 18")
        // 16 > 13, so the arithmetic would open chat — `allowsSelfAttestation` is what stops it. Chat is
        // reachable only through the system's own answer, by design.
        #expect(!record.allows(.chat), "No manual route into messaging, at any confirmed age")
    }

    @Test func chatRefusesTheManualConfirmationOutright() {
        #expect(!AgeGate.chat.allowsSelfAttestation)
        #expect(!AgeAssuranceRecord.unknown.mayOfferSelfAttestation(for: .chat))
        // Attempting it is a no-op, not a stored-but-ignored claim.
        let attempted = AgeAssuranceRecord.unknown.selfAttesting(.chat)
        #expect(attempted.selfAttestedMinimumAge == nil)
        #expect(!attempted.allows(.chat))
    }

    // MARK: - Guardian communication limits

    /// A restriction the guardian already set closes chat on its own — the age bracket never gets a say.
    @Test func communicationLimitsCloseChatEvenWellAboveTheGate() {
        let record = AgeAssuranceRecord.unknown.determining(
            lowerBound: 18, upperBound: nil, provenance: .confirmed,
            hasCommunicationLimits: true, now: .now
        )
        #expect(!record.allows(.chat))
        #expect(!record.mayOfferSelfAttestation(for: .chat))
        // ...and touch nothing else: the limit is about contacting people, not about a private log.
        #expect(record.allows(.intimacy))
        #expect(record.allows(.adult))
    }

    @Test func communicationLimitsAreClearedWhenTheSystemStopsReportingThem() {
        let limited = AgeAssuranceRecord.unknown.determining(
            lowerBound: 18, upperBound: nil, provenance: .confirmed,
            hasCommunicationLimits: true, now: .now
        )
        let lifted = limited.determining(
            lowerBound: 18, upperBound: nil, provenance: .confirmed,
            hasCommunicationLimits: false, now: .now
        )
        #expect(lifted.allows(.chat), "A lifted restriction must be picked up by a re-check")
    }

    /// A record written before parental controls were read must decode as unrestricted. The flag only
    /// ever closes a gate, so inventing one over a schema change would lock a user out.
    @Test func aRecordWithoutTheParentalControlsKeyDecodesAsUnrestricted() throws {
        let legacy = """
        {"lowerBound":18,"provenance":"confirmed"}
        """
        let decoded = try JSONDecoder().decode(
            AgeAssuranceRecord.self, from: Data(legacy.utf8)
        )
        #expect(!decoded.hasCommunicationLimits)
        #expect(decoded.allows(.chat))
    }

    /// The load-bearing one. If this ever passes in the other direction the gate is decorative.
    @Test func confirmationCannotReopenAGateTheSystemClosed() {
        let below = determined(nil, 13)
        let attempted = below.selfAttesting(.intimacy).selfAttesting(.chat).selfAttesting(.adult)
        for gate in AgeGate.allCases {
            #expect(!attempted.allows(gate), "\(gate) was closed by the system and must stay closed")
        }
        #expect(attempted.selfAttestedMinimumAge == nil, "The claim is refused, not merely ignored")
    }

    @Test func confirmationKeepsTheHighestGateWhenAppliedTwice() {
        let record = AgeAssuranceRecord.unknown.selfAttesting(.intimacy).selfAttesting(.chat)
        #expect(record.selfAttestedMinimumAge == AgeGate.intimacy.minimumAge,
                "Confirming a lower gate afterwards must not walk the floor back down")
    }

    /// Re-asking and learning nothing is not a reason to revoke the user's own standing claim.
    @Test func anUndeterminedRecheckPreservesTheConfirmation() {
        let attested = AgeAssuranceRecord.unknown.selfAttesting(.intimacy)
        let rechecked = attested.undetermined(now: .now)
        #expect(rechecked.allows(.intimacy))
    }

    /// ...but real information from the system supersedes it, in both directions.
    @Test func aDeterminedBracketSupersedesTheConfirmation() {
        let attested = AgeAssuranceRecord.unknown.selfAttesting(.adult)
        let determinedBelow = attested.determining(
            lowerBound: 13, upperBound: 16, provenance: .guardianDeclared, now: .now
        )
        #expect(determinedBelow.selfAttestedMinimumAge == nil)
        #expect(!determinedBelow.allows(.intimacy))
        #expect(determinedBelow.allows(.chat), "The system's own answer still applies")
    }

    /// A stale bracket must not outlive the determination it belonged to — otherwise a user who signs
    /// out of their Apple Account keeps whatever the previous account said.
    @Test func anUndeterminedResultClearsTheStoredBracket() {
        let cleared = determined(18, nil).undetermined(now: .now)
        #expect(!cleared.isDetermined)
        #expect(cleared.lowerBound == nil)
        #expect(!cleared.allows(.chat))
    }

    /// Both shapes the sidecar can hold, since a record never carries a bracket and a confirmation at
    /// once: the bracket supersedes the claim.
    @Test(arguments: [
        AgeAssuranceRecord(
            lowerBound: 16, upperBound: 18, provenance: .confirmed,
            determinedAt: Date(timeIntervalSince1970: 1_780_000_000.25)
        ),
        AgeAssuranceRecord.unknown.selfAttesting(.intimacy),
    ])
    func theRecordSurvivesACodableRoundTrip(record: AgeAssuranceRecord) throws {
        let decoded = try JSONDecoder().decode(
            AgeAssuranceRecord.self, from: try JSONEncoder().encode(record)
        )
        #expect(decoded == record)
    }
}

// MARK: - The store

@MainActor
struct AgeAssuranceStoreTests {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "age-assurance-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func aFreshStoreFailsClosed() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = AgeAssuranceStore(defaults: defaults)
        for gate in AgeGate.allCases {
            #expect(!store.allows(gate))
        }
    }

    @Test func theDeterminationSurvivesANewStoreOnTheSameDevice() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        AgeAssuranceStore(defaults: defaults).applyDetermination(
            lowerBound: 16, upperBound: 18, provenance: .confirmed
        )

        let reloaded = AgeAssuranceStore(defaults: defaults)
        #expect(reloaded.allows(.intimacy))
        #expect(!reloaded.allows(.adult))
    }

    @Test func theConfirmationSurvivesANewStoreOnTheSameDevice() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        AgeAssuranceStore(defaults: defaults).selfAttest(.intimacy)

        #expect(AgeAssuranceStore(defaults: defaults).allows(.intimacy))
    }

    /// A half-read record is not honoured. Re-verifying is a nuisance; acting on a partially-decoded
    /// verdict is a gate failure.
    @Test func anUndecodableRecordFailsClosed() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "ageAssuranceRecord")

        let store = AgeAssuranceStore(defaults: defaults)
        #expect(store.record == .unknown)
        #expect(!store.allows(.chat))
    }

    @Test func clearingReturnsToFailClosed() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = AgeAssuranceStore(defaults: defaults)
        store.applyDetermination(lowerBound: 18, upperBound: nil, provenance: .confirmed)
        #expect(store.allows(.adult))

        store.clear()
        for gate in AgeGate.allCases {
            #expect(!store.allows(gate))
        }
        // And the clear reaches the sidecar, not just the in-memory copy.
        #expect(AgeAssuranceStore(defaults: defaults).record == .unknown)
    }
}

// MARK: - The gates as wired into the app

/// Serialized, and on isolated defaults, for the same reason `DeleteAllDataTests` is: the reset case
/// calls `resetAll()`, which clears the device-local sidecar. Left on `.standard` that clear would race
/// any parallel test that had just seeded its own age record.
@Suite(.serialized) @MainActor
struct AgeGateWiringTests {

    private func makeStore(_ name: String) -> FernletStore {
        FernletStore(
            repository: LocalFernletRepository(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)-\(UUID().uuidString).json")
            ),
            sensitiveVisibilityDefaults: UserDefaults(suiteName: "\(name)-\(UUID().uuidString)") ?? .standard,
            photoDocumentsDirectory: uniquePhotoDirectory()
        )
    }

    /// The intimacy gate reaches the derived visibility that `IntimacyLogStore.isVisible` is wired to,
    /// so a below-gate device never decrypts an intimacy row — the gate is at the decrypt seam, not a
    /// UI `if`.
    @Test func theIntimacyGateReachesTheDerivedVisibility() {
        let store = makeStore("age-gate-intimacy")
        store.settings.intimacyTrackingVisible = true

        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge,
            upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )
        #expect(!store.isIntimateLoggingAllowed)
        #expect(!store.isIntimacyTrackingVisible)
        #expect(!store.sensitiveSurfaceVisibility.intimacy)

        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge, upperBound: nil, provenance: .selfDeclared
        )
        #expect(store.isIntimateLoggingAllowed)
        #expect(store.isIntimacyTrackingVisible)
    }

    /// The intimacy gate is a floor UNDER the user's own preference, not a replacement for it: meeting
    /// the age requirement must not un-hide a feature the user deliberately turned off.
    @Test func meetingTheAgeGateDoesNotOverrideTheUsersOwnChoice() {
        let store = makeStore("age-gate-preference")
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.adult.minimumAge, upperBound: nil, provenance: .confirmed
        )
        store.setIntimacyTrackingVisible(false)

        #expect(store.isIntimateLoggingAllowed)
        #expect(!store.isIntimacyTrackingVisible)
    }

    /// The chat gate is enforced on the SEND side, not only by withholding the capability — a peer
    /// that kept our capabilities from an earlier session could otherwise still be replied to.
    @Test func sendingIsRefusedBelowTheChatGate() {
        let store = makeStore("age-gate-chat-send")
        let manager = store.meshNetworkManager
        var sends = 0
        manager.onTempMessageSendForTesting = { _ in sends += 1 }

        store.ageAssurance.applyDetermination(
            lowerBound: nil, upperBound: AgeGate.chat.minimumAge, provenance: .guardianDeclared
        )
        manager.sendTempMessage("hello")

        #expect(sends == 0)
        #expect(manager.sessionMessages.messages.isEmpty,
                "Not even the local echo — a transcript below the gate must stay empty")
        #expect(!manager.isChatAllowed)
    }

    /// Guardian communication limits reach the transport, not just the copy in Settings: an of-age
    /// account with limits set advertises no `messages` capability and sends nothing.
    @Test func communicationLimitsCloseTheChatTransport() {
        let store = makeStore("age-gate-chat-parental")
        let manager = store.meshNetworkManager
        var sends = 0
        manager.onTempMessageSendForTesting = { _ in sends += 1 }

        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.adult.minimumAge, upperBound: nil,
            provenance: .confirmed, hasCommunicationLimits: true
        )

        #expect(!manager.isChatAllowed)
        #expect(!manager.localCapabilities().contains(ProximityCapability.messages.rawValue))
        manager.sendTempMessage("hello")
        #expect(sends == 0)
        #expect(manager.sessionMessages.messages.isEmpty)
        // The restriction is scoped to contacting people — intimacy is untouched.
        #expect(store.isIntimateLoggingAllowed)
    }

    /// An unwired manager refuses rather than opens. `chatAllowedProvider` is optional, and nil must
    /// mean no.
    @Test func anUnwiredChatProviderFailsClosed() {
        let store = makeStore("age-gate-chat-unwired")
        let manager = store.meshNetworkManager
        manager.chatAllowedProvider = nil

        #expect(!manager.isChatAllowed)
        #expect(!manager.localCapabilities().contains(ProximityCapability.messages.rawValue))
    }

    /// "Delete everything" drops the determination too — a wiped device must not still hold a verdict
    /// about its user.
    @Test func deletingEverythingClearsTheDetermination() {
        let store = makeStore("age-gate-reset")
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.adult.minimumAge, upperBound: nil, provenance: .confirmed
        )
        #expect(store.allowsIntimacyForTesting)

        _ = store.resetAll()

        #expect(store.ageAssurance.record == .unknown)
        #expect(!store.isIntimateLoggingAllowed)
    }
}

private extension FernletStore {
    /// Reads the gate through the same property the app does, named so the reset test above reads as a
    /// before/after rather than two unrelated assertions.
    var allowsIntimacyForTesting: Bool { isIntimateLoggingAllowed }
}

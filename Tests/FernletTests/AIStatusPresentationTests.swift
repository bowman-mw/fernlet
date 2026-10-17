import Foundation
import Testing
import AIContext
import FernletDomainModel
import FernletScoring
@testable import Fernlet

/// A capability provider that names a fixed on-device availability — the fake an incapable iPhone is
/// simulated with.
private struct FakeOnDeviceCapabilityProvider: AIDeviceCapabilityProviding {
    let onDeviceAvailability: OnDeviceModelAvailability
    var capability: AIDeviceCapability {
        AIDeviceCapability(onDeviceFoundationModels: onDeviceAvailability == .available)
    }
}

/// Settings' AI "Today" row and voice line tell the truth on an iPhone that cannot run the on-device
/// model (bug confirmation 2026-10-15, food-ai §7).
///
/// The row showed `effectiveAIStatus.label`, the synced intent overlaid with this device's call
/// counter. The router charges nothing when it falls back for an incapable device, so the counter
/// stayed at zero and the row said "Ready" forever on every iPhone without Apple Intelligence, with
/// the retry note as its voice line. `AIStatusPresentation` puts the device's reason first.
@MainActor
struct AIStatusPresentationTests {
    /// Every reason a device cannot run the model, with what the row then says.
    static let unavailableReasons: [(OnDeviceModelAvailability, AIStatusPresentation)] = [
        (.deviceNotEligible, .notAvailableOnThisIPhone),
        (.appleIntelligenceNotEnabled, .turnOnAppleIntelligence),
        (.modelNotReady, .gettingReady),
        (.unavailable, .notAvailableRightNow)
    ]

    /// The store's row on an incapable iPhone, read through an injected fake provider: the intent and
    /// the untouched counter still say `.ready`, the row does not.
    @Test func anIncapableIPhoneNeverSaysReady() {
        let store = makeTestStore()
        store.settings.aiStatus = .ready
        for (availability, expected) in Self.unavailableReasons {
            store.aiCapabilityProvider = FakeOnDeviceCapabilityProvider(onDeviceAvailability: availability)

            #expect(store.effectiveAIStatus == .ready)
            #expect(store.aiStatusPresentation == expected)
            #expect(store.aiStatusPresentation.voiceLine == .aiUnavailable)
        }
    }

    /// A capable iPhone shows the effective status and its voice line, as before.
    @Test func aCapableIPhoneShowsTheEffectiveStatus() {
        let lines: [(AIStatus, FernletVoice)] = [(.ready, .retryAvailable), (.sleepy, .aiResting), (.resting, .aiResting)]
        for (status, voice) in lines {
            let presentation = AIStatusPresentation(effective: status, availability: .available)
            #expect(presentation == .status(status))
            #expect(presentation.voiceLine == voice)
        }
        let store = makeTestStore()
        store.settings.aiStatus = .ready
        store.aiCapabilityProvider = FakeOnDeviceCapabilityProvider(onDeviceAvailability: .available)
        #expect(store.aiStatusPresentation == .status(.ready))
    }

    /// The person's own "Off" is true on every device, capable or not.
    @Test func offWinsOnEveryDevice() {
        let availabilities: [OnDeviceModelAvailability] = [
            .available, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable
        ]
        for availability in availabilities {
            let presentation = AIStatusPresentation(effective: .off, availability: availability)
            #expect(presentation == .status(.off))
            #expect(presentation.voiceLine == .aiUnavailable)
        }
    }

    /// A provider that knows only the rung never claims a reason it cannot vouch for.
    @Test func aCapabilityOnlyProviderNamesNoReason() {
        let incapable = StaticAIDeviceCapabilityProvider(AIDeviceCapability(onDeviceFoundationModels: false))
        let capable = StaticAIDeviceCapabilityProvider(AIDeviceCapability(onDeviceFoundationModels: true))

        #expect(incapable.onDeviceAvailability == .unavailable)
        #expect(capable.onDeviceAvailability == .available)
    }
}

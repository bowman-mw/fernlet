import Foundation
import Testing
import AIContext
import FernletDomainModel

@Suite struct FernletModelRouterTests {

    private func router(onDevice: Bool, pcc: Bool = false, external: Bool = false) -> FernletModelRouter {
        FernletModelRouter(capabilityProvider: StaticAIDeviceCapabilityProvider(
            AIDeviceCapability(onDeviceFoundationModels: onDevice, privateCloudCompute: pcc, externalProviders: external)
        ))
    }

    // MARK: - Resolution matrix: tier × status × device capability

    @Test func offAlwaysFallsBackRegardlessOfTierOrDevice() {
        for tier in AICapabilityTier.allCases {
            for capable in [true, false] {
                let r = router(onDevice: capable).resolve(tier: tier, effectiveStatus: .off, userInvoked: true)
                #expect(r == .deterministicFallback(.aiOff))
            }
        }
    }

    @Test func restingAlwaysFallsBackRegardlessOfTierOrDevice() {
        for tier in AICapabilityTier.allCases {
            for capable in [true, false] {
                let r = router(onDevice: capable).resolve(tier: tier, effectiveStatus: .resting, userInvoked: true)
                #expect(r == .deterministicFallback(.resting))
            }
        }
    }

    @Test func sleepyFallsBackForNonEssentialButUserInvokedDeepRuns() {
        let capable = router(onDevice: true)
        // Non-essential tiers fall back in the sleepy band.
        #expect(capable.resolve(tier: .light, effectiveStatus: .sleepy, userInvoked: true) == .deterministicFallback(.sleepy))
        #expect(capable.resolve(tier: .standard, effectiveStatus: .sleepy, userInvoked: true) == .deterministicFallback(.sleepy))
        // Deep, not user-invoked → falls back.
        #expect(capable.resolve(tier: .deep, effectiveStatus: .sleepy, userInvoked: false) == .deterministicFallback(.sleepy))
        // Deep, user-invoked → still runs (on-device today).
        #expect(capable.resolve(tier: .deep, effectiveStatus: .sleepy, userInvoked: true) == .destination(.onDeviceFoundationModels))
        // Deep, user-invoked, but no device model → deterministic (incapable).
        #expect(router(onDevice: false).resolve(tier: .deep, effectiveStatus: .sleepy, userInvoked: true) == .deterministicFallback(.deviceIncapable))
    }

    @Test func readyOnCapableDeviceResolvesOnDeviceForEveryTierToday() {
        let capable = router(onDevice: true)
        #expect(capable.resolve(tier: .light, effectiveStatus: .ready, userInvoked: false) == .destination(.onDeviceFoundationModels))
        #expect(capable.resolve(tier: .standard, effectiveStatus: .ready, userInvoked: false) == .destination(.onDeviceFoundationModels))
        // deep falls to on-device today (PCC/BYOK unavailable on this SDK).
        #expect(capable.resolve(tier: .deep, effectiveStatus: .ready, userInvoked: true) == .destination(.onDeviceFoundationModels))
    }

    @Test func readyOnIncapableDeviceFallsBackForEveryTier() {
        let incapable = router(onDevice: false)
        for tier in AICapabilityTier.allCases {
            #expect(incapable.resolve(tier: tier, effectiveStatus: .ready, userInvoked: true) == .deterministicFallback(.deviceIncapable))
        }
    }

    // MARK: - Light never escalates off-device

    @Test func lightNeverEscalatesEvenWhenCloudIsAvailable() {
        // A device where PCC/BYOK are (hypothetically) reachable but the on-device model is NOT.
        let cloudOnly = router(onDevice: false, pcc: true, external: true)
        // Light's ladder is on-device only, so it cannot reach PCC — it falls back rather than egress.
        #expect(cloudOnly.resolve(tier: .light, effectiveStatus: .ready, userInvoked: true) == .deterministicFallback(.deviceIncapable))
        // The ladder itself contains no destination that leaves the device.
        #expect(AICapabilityTier.light.escalationLadder.allSatisfy { !$0.leavesDevice })
        #expect(AICapabilityTier.light.allowsOffDeviceEscalation == false)
        #expect(AICapabilityTier.standard.allowsOffDeviceEscalation == true)
        #expect(AICapabilityTier.deep.allowsOffDeviceEscalation == true)
    }

    // MARK: - Deep falls to on-device today

    @Test func deepPrefersCloudButLandsOnDeviceOnThisSDK() {
        // Preferred order puts cloud first, on-device last.
        #expect(AICapabilityTier.deep.escalationLadder.first == .privateCloudCompute)
        #expect(AICapabilityTier.deep.escalationLadder.last == .onDeviceFoundationModels)
        // With only the on-device model reachable, deep resolves to it.
        #expect(router(onDevice: true).resolve(tier: .deep, effectiveStatus: .ready, userInvoked: true) == .destination(.onDeviceFoundationModels))
    }

    // MARK: - Step-down

    @Test func stepDownWalksTheLadderWhenRungsAreReachable() {
        // A fully-capable device so the cloud rungs are reachable for the walk.
        let full = router(onDevice: true, pcc: true, external: true)
        #expect(full.stepDown(from: .privateCloudCompute, tier: .deep, reason: .error) == .destination(.externalAnthropic))
        #expect(full.stepDown(from: .externalAnthropic, tier: .deep, reason: .timeout) == .destination(.externalOpenAICompatible))
        #expect(full.stepDown(from: .externalOpenAICompatible, tier: .deep, reason: .schemaValidation) == .destination(.onDeviceFoundationModels))
        // Last rung → nothing left.
        #expect(full.stepDown(from: .onDeviceFoundationModels, tier: .deep, reason: .error) == .deterministicFallback(.allRungsExhausted))
    }

    @Test func stepDownSkipsUnreachableRungs() {
        // PCC failed; BYOK not configured; only the on-device model is reachable → skip to it.
        let onlyOnDevice = router(onDevice: true, pcc: false, external: false)
        #expect(onlyOnDevice.stepDown(from: .privateCloudCompute, tier: .deep, reason: .unavailable) == .destination(.onDeviceFoundationModels))
    }

    // MARK: - Content-refusal never steps down

    @Test func contentRefusalTerminatesToFallbackNeverAnotherVendor() {
        let full = router(onDevice: true, pcc: true, external: true)
        #expect(full.stepDown(from: .privateCloudCompute, tier: .deep, reason: .contentRefusal) == .deterministicFallback(.contentRefusal))
        #expect(full.stepDown(from: .externalAnthropic, tier: .deep, reason: .contentRefusal) == .deterministicFallback(.contentRefusal))
    }
}

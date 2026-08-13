import Foundation
import Testing
import AIContext
import FernletDomainModel

/// Tests the routing gate every AI call site funnels through: the (tier × invocation-class) decision,
/// the deterministic-fallback signal, and the exactly-once quota charge at the model-dispatch point.
///
/// Every real call site reaches the model only via `FernletAIGate.dispatch(tier:userInvoked:)`, so
/// exercising the gate across the (tier, userInvoked, effective-status, capability) matrix is the
/// per-call-site routing test — the call-site inventory just fixes each site's `(tier, userInvoked)`.
@Suite struct FernletAIGateTests {

    /// A quota-store spy: counts `recordCall()` (the charge) separately from `currentQuota()` (the
    /// read the router does when deciding), so a test can prove the charge fires exactly once per
    /// dispatch and never on a status read.
    private final class SpyQuotaStore: AICallQuotaStore, @unchecked Sendable {
        private let lock = NSLock()
        private var quota: AICallQuota
        private(set) var recordCallCount = 0
        private(set) var currentQuotaReadCount = 0

        init(_ quota: AICallQuota) { self.quota = quota }

        func currentQuota() -> AICallQuota {
            lock.lock(); defer { lock.unlock() }
            currentQuotaReadCount += 1
            return quota
        }
        @discardableResult func recordCall() -> AICallQuota {
            lock.lock(); defer { lock.unlock() }
            recordCallCount += 1
            quota = quota.recordingCall()
            return quota
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            quota = AICallQuota()
            recordCallCount = 0
        }
    }

    private func makeGate(
        onDevice: Bool,
        pcc: Bool = false,
        external: Bool = false,
        intent: AIStatus,
        count: Int
    ) -> (FernletAIGate, SpyQuotaStore) {
        let key = AICallQuota.dayKey(for: Date())
        let spy = SpyQuotaStore(AICallQuota(dayKey: key, count: count))
        let router = FernletModelRouter(capabilityProvider: StaticAIDeviceCapabilityProvider(
            AIDeviceCapability(onDeviceFoundationModels: onDevice, privateCloudCompute: pcc, externalProviders: external)
        ))
        return (FernletAIGate(router: router, quotaStore: spy, intent: intent), spy)
    }

    // MARK: - Capable + ready → on-device (every tier, either invocation class)

    @Test func capableReadyResolvesOnDeviceAndChargesExactlyOnce() {
        for tier in AICapabilityTier.allCases {
            for userInvoked in [true, false] {
                let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: 0)
                #expect(gate.dispatch(tier: tier, userInvoked: userInvoked) == .onDeviceFoundationModels)
                #expect(spy.recordCallCount == 1)   // exactly one charge per model dispatch
            }
        }
    }

    // MARK: - Incapable device → deterministic (nil), no charge

    @Test func incapableDeviceFallsBackAndDoesNotCharge() {
        for tier in AICapabilityTier.allCases {
            let (gate, spy) = makeGate(onDevice: false, intent: .ready, count: 0)
            #expect(gate.dispatch(tier: tier, userInvoked: true) == nil)
            #expect(spy.recordCallCount == 0)
        }
    }

    // MARK: - Off → deterministic (nil), no charge

    @Test func offFallsBackAndDoesNotCharge() {
        let (gate, spy) = makeGate(onDevice: true, intent: .off, count: 0)
        #expect(gate.dispatch(tier: .standard, userInvoked: true) == nil)
        #expect(spy.recordCallCount == 0)
    }

    // MARK: - Resting (>= 60) → everything falls back, no charge

    @Test func restingFallsBackForEveryTierAndInvocationClass() {
        for tier in AICapabilityTier.allCases {
            for userInvoked in [true, false] {
                let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.restingThreshold)
                #expect(gate.dispatch(tier: tier, userInvoked: userInvoked) == nil)
                #expect(spy.recordCallCount == 0)
            }
        }
    }

    // MARK: - Sleepy (>= 30): ambient falls back, user-invoked runs (the one intended behavior change)

    @Test func sleepyAmbientFallsBackNoCharge() {
        for tier in AICapabilityTier.allCases {
            let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.sleepyThreshold)
            // Ambient/background (day summary, thought bubble, memory work) → deterministic.
            #expect(gate.dispatch(tier: tier, userInvoked: false) == nil)
            #expect(spy.recordCallCount == 0)
        }
    }

    @Test func sleepyUserInvokedRunsOnDeviceAndCharges() {
        // A user tap still runs in the sleepy band regardless of tier — meal resolve is `.standard`.
        for tier in AICapabilityTier.allCases {
            let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.sleepyThreshold)
            #expect(gate.dispatch(tier: tier, userInvoked: true) == .onDeviceFoundationModels)
            #expect(spy.recordCallCount == 1)
        }
    }

    // MARK: - Light (sensitive/memory-adjacent) never leaves the device

    @Test func lightNeverEscalatesEvenWhenCloudReachable() {
        // On-device model absent, but PCC/BYOK "reachable" — light must NOT egress; it falls back.
        let (gate, spy) = makeGate(onDevice: false, pcc: true, external: true, intent: .ready, count: 0)
        #expect(gate.dispatch(tier: .light, userInvoked: false) == nil)
        #expect(spy.recordCallCount == 0)
    }

    // MARK: - The charge is per-dispatch, never per status read / per retry-decode

    @Test func statusReadsDoNotChargeAndDispatchChargesOnce() {
        let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: 0)
        // Reading the effective status (as the settings label does) must never charge a call.
        _ = spy.currentQuota()
        _ = spy.currentQuota()
        #expect(spy.recordCallCount == 0)
        #expect(spy.currentQuotaReadCount == 2)

        // One dispatch → exactly one charge, no matter how many times the model retries/decodes below
        // this point (those happen inside `session.respond`, past the gate — the gate is not re-entered).
        #expect(gate.dispatch(tier: .standard, userInvoked: true) == .onDeviceFoundationModels)
        #expect(spy.recordCallCount == 1)
    }

    // MARK: - Consecutive dispatches walk the budget into sleepy then resting

    @Test func consecutiveDispatchesCrossThresholdsAndThenStop() {
        // Start just below sleepy; ambient dispatches run until the counter reaches the sleepy floor,
        // after which ambient work falls back (and stops charging).
        let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.sleepyThreshold - 1)
        // count == 29: still ready → ambient runs, charges (→ 30).
        #expect(gate.dispatch(tier: .standard, userInvoked: false) == .onDeviceFoundationModels)
        #expect(spy.recordCallCount == 1)
        // count == 30: sleepy → ambient falls back, no further charge.
        #expect(gate.dispatch(tier: .standard, userInvoked: false) == nil)
        #expect(spy.recordCallCount == 1)
        // …but a user tap still runs at the sleepy floor (→ 31).
        #expect(gate.dispatch(tier: .standard, userInvoked: true) == .onDeviceFoundationModels)
        #expect(spy.recordCallCount == 2)
    }

    // MARK: - resolveRoute exposes WHY a task fell back (transient budget vs. persistent incapability)

    /// The share-extension recipe queue leans on this distinction: a `.resting` / `.sleepy` fallback is
    /// transient (clears at midnight) and must be retried tomorrow rather than burning a finite retry
    /// attempt, while `.deviceIncapable` is persistent. If these reasons ever collapse, the queue would
    /// silently drop shared recipes on a heavy-AI day.
    @Test func resolveRouteReportsTransientBudgetFallbackReasons() {
        // Resting → `.resting`, no charge.
        let (resting, restingSpy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.restingThreshold)
        #expect(resting.resolveRoute(tier: .standard, userInvoked: true) == .deterministicFallback(.resting))
        #expect(restingSpy.recordCallCount == 0)

        // Sleepy + ambient → `.sleepy`, no charge.
        let (sleepy, sleepySpy) = makeGate(onDevice: true, intent: .ready, count: AICallQuota.sleepyThreshold)
        #expect(sleepy.resolveRoute(tier: .standard, userInvoked: false) == .deterministicFallback(.sleepy))
        #expect(sleepySpy.recordCallCount == 0)

        // Persistent device incapability → `.deviceIncapable` (NOT a transient budget reason).
        let (incapable, incapableSpy) = makeGate(onDevice: false, intent: .ready, count: 0)
        #expect(incapable.resolveRoute(tier: .standard, userInvoked: true) == .deterministicFallback(.deviceIncapable))
        #expect(incapableSpy.recordCallCount == 0)
    }

    @Test func resolveRouteChargesExactlyOnceOnDestinationLikeDispatch() {
        let (gate, spy) = makeGate(onDevice: true, intent: .ready, count: 0)
        #expect(gate.resolveRoute(tier: .standard, userInvoked: true) == .destination(.onDeviceFoundationModels))
        #expect(spy.recordCallCount == 1)
    }
}

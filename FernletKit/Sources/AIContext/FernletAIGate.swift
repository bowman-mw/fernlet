import Foundation
import FernletDomainModel

/// The single routing entry point every AI call site funnels through. It bundles the three seam
/// pieces built in the provider-seam core — the capability-capped `FernletModelRouter`, the stored
/// user intent (`FernletSettings.aiStatus`), and the device-local `AICallQuotaStore` — into one
/// value the call site can consult right before it would dispatch a model call.
///
/// Placement: `AIContext` (alongside the router and quota contracts), so BOTH the walled
/// `AIProviders` module and the app-target call sites can take a gate without any new dependency
/// edge. The walled module still reaches the counter ONLY through the injected `AICallQuotaStore`
/// protocol — the gate carries the store, it does not expose the concrete app-target type.
///
/// The gate is a pure value carrying the *current* stored intent; the app rebuilds it per call so a
/// mid-session AI-toggle is always reflected. Resolving is settings- and quota-driven and does no
/// I/O beyond the two `UserDefaults`-backed reads the quota store already performs, so it is safe to
/// call on the main thread immediately before an `await` on the model.
public struct FernletAIGate: Sendable {
    /// Resolution order + capability cap (§3.2). Pure/injectable.
    public let router: FernletModelRouter
    /// The device-local daily counter (§3.2). Reached only through the protocol — never the concrete
    /// app-target store — so the counter stays unreachable from the walled module.
    public let quotaStore: AICallQuotaStore
    /// The stored (synced) user intent — `FernletSettings.aiStatus`. Overlaid with the local counter
    /// to derive the effective status; never written back (device A's usage cannot throttle device B).
    public let intent: AIStatus

    public init(router: FernletModelRouter, quotaStore: AICallQuotaStore, intent: AIStatus) {
        self.router = router
        self.quotaStore = quotaStore
        self.intent = intent
    }

    /// Resolve this task and, when a model destination is chosen, charge exactly one call against the
    /// device-local budget.
    ///
    /// Returns the destination to dispatch to (today always `.onDeviceFoundationModels`, the only
    /// reachable rung on this SDK), or `nil` when the router lands on the deterministic fallback —
    /// `.off`, `.resting`, `.sleepy` + ambient, an incapable device, or an exhausted ladder. A `nil`
    /// return means the caller MUST take its existing deterministic path; the gate has already NOT
    /// counted a call.
    ///
    /// The quota is charged exactly ONCE here, at the single dispatch decision — never per retry or
    /// per structured-decode attempt inside `session.respond`, which happen below this point.
    ///
    /// - Parameters:
    ///   - tier: the minimum capability this task needs (§3.1).
    ///   - userInvoked: `true` for an explicit user tap (meal resolve, photo identify, workout
    ///     adjust, recipe/product import); `false` for ambient/background work (day summaries,
    ///     thought bubbles, memory work). In the `.sleepy` band ambient work falls back and
    ///     user-invoked work still runs.
    public func dispatch(tier: AICapabilityTier, userInvoked: Bool) -> AIDestination? {
        let effective = AIStatusOverlay.effectiveStatus(intent: intent, quota: quotaStore.currentQuota())
        switch router.resolve(tier: tier, effectiveStatus: effective, userInvoked: userInvoked) {
        case .destination(let destination):
            // A real model call is about to be made → charge one call against today's budget.
            quotaStore.recordCall()
            return destination
        case .deterministicFallback:
            return nil
        }
    }
}

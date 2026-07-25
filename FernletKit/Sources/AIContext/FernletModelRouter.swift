import Foundation
import FernletDomainModel

/// Why a task landed on the deterministic (non-AI) path instead of a model destination.
public enum AIDeterministicReason: String, Sendable, Equatable {
    /// User turned AI off.
    case aiOff
    /// Daily budget exhausted (`.resting`, ≥60 calls) — everything falls back.
    case resting
    /// Daily budget in the sleepy band (`.sleepy`, ≥30 calls) and this task is ambient/background
    /// rather than user-invoked (an explicit tap still runs in the sleepy band).
    case sleepy
    /// No rung on the tier's ladder is reachable on this device (e.g. no Apple Intelligence).
    case deviceIncapable
    /// Every rung was tried and stepped down; nothing left.
    case allRungsExhausted
    /// A provider issued a content-refusal — a privacy event that terminates to the fallback and is
    /// NEVER re-sent to another vendor.
    case contentRefusal
}

/// The outcome of a routing decision: either a concrete destination to call, or the deterministic
/// fallback with the reason it was chosen.
public enum AIRouteResolution: Sendable, Equatable {
    case destination(AIDestination)
    case deterministicFallback(AIDeterministicReason)
}

/// Why a resolved destination failed, driving the step-down decision.
public enum AIRouteFailureReason: String, Sendable, Equatable {
    case unavailable
    case error
    case timeout
    case schemaValidation
    /// A provider safety refusal. NOT a step-down trigger — it terminates to the deterministic
    /// fallback (re-sending the same health-adjacent data to a different company would leak it
    /// further). Encoded here now so the cloud adapters inherit the rule the moment they land.
    case contentRefusal
}

/// Resolves an AI task to a destination per the Ladder §3.2 resolution order, capped by device
/// capability. Escalation is downward only; the router never promotes a task to a destination the
/// user did not enable, and never sends a `light` payload off the device.
///
/// Pure and settings-driven: it takes the *effective* `AIStatus` (already overlaid with the local
/// quota by the caller via `AIStatusOverlay`), so the router itself never reaches the quota store —
/// which keeps the device-local counter unreachable from the walled `AIProviders` module except
/// through the injected `AICallQuotaStore` seam.
public struct FernletModelRouter: Sendable {
    private let capabilityProvider: AIDeviceCapabilityProviding

    public init(capabilityProvider: AIDeviceCapabilityProviding) {
        self.capabilityProvider = capabilityProvider
    }

    /// Resolve the first destination for `tier`.
    ///
    /// - Parameters:
    ///   - tier: the minimum capability the task needs.
    ///   - effectiveStatus: `AIStatusOverlay.effectiveStatus(intent:quota:)` — stored intent already
    ///     combined with the device-local daily counter.
    ///   - userInvoked: `true` when the user explicitly triggered this task (e.g. tapped "Resolve
    ///     meal", "Adjust workout", "Import recipe"); `false` for ambient/background work (day
    ///     summaries, thought bubbles, memory work). A user-invoked task still runs in the `.sleepy`
    ///     band; ambient work falls back.
    public func resolve(
        tier: AICapabilityTier,
        effectiveStatus: AIStatus,
        userInvoked: Bool
    ) -> AIRouteResolution {
        // 1–3: budget/intent gate (resolution order steps 1–3).
        switch effectiveStatus {
        case .off:
            return .deterministicFallback(.aiOff)
        case .resting:
            return .deterministicFallback(.resting)
        case .sleepy:
            // Ladder §3.2 step 3, made precise: "non-essential" == ambient/background work, which
            // takes the fallback in the sleepy band; anything the user explicitly invoked still runs
            // (regardless of tier). Only the daily budget being fully spent (`.resting`) stops a tap.
            if !userInvoked {
                return .deterministicFallback(.sleepy)
            }
        case .ready:
            break
        }

        // 4: cheapest available rung for the tier, capped by device capability.
        let capability = capabilityProvider.capability
        guard let destination = tier.escalationLadder.first(where: { capability.isAvailable($0) }) else {
            return .deterministicFallback(.deviceIncapable)
        }
        return finalize(destination, tier: tier)
    }

    /// Step down after a resolved destination fails. Returns the next reachable rung below `from` on
    /// the tier's ladder, or the deterministic fallback when the ladder is exhausted.
    ///
    /// A `contentRefusal` is NEVER a step-down: it terminates to the deterministic fallback so the
    /// same data is not re-sent to another provider.
    public func stepDown(
        from destination: AIDestination,
        tier: AICapabilityTier,
        reason: AIRouteFailureReason
    ) -> AIRouteResolution {
        if reason == .contentRefusal {
            return .deterministicFallback(.contentRefusal)
        }
        let ladder = tier.escalationLadder
        guard let index = ladder.firstIndex(of: destination) else {
            return .deterministicFallback(.allRungsExhausted)
        }
        let capability = capabilityProvider.capability
        let next = ladder[(index + 1)...].first(where: { capability.isAvailable($0) })
        guard let next else {
            return .deterministicFallback(.allRungsExhausted)
        }
        return finalize(next, tier: tier)
    }

    /// Enforces the sensitive-work pin at the type boundary: a `light` task can never resolve to a
    /// destination that leaves the device. This is the HARD rule (journal, memory stay on-device)
    /// expressed as an assertion so it survives future ladder edits, not a comment.
    private func finalize(_ destination: AIDestination, tier: AICapabilityTier) -> AIRouteResolution {
        if !tier.allowsOffDeviceEscalation {
            assert(!destination.leavesDevice, "light-tier (sensitive) work must never leave the device: \(destination)")
            if destination.leavesDevice {
                // Fail closed even in release builds where the assert is compiled out.
                return .deterministicFallback(.deviceIncapable)
            }
        }
        return .destination(destination)
    }
}

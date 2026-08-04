import Foundation
import FernletDomainModel

/// The minimum capability an AI task declares.
///
/// The router (``FernletModelRouter``) picks the *cheapest available* destination meeting the tier,
/// never higher than the device capability or the user's configured ceiling.
/// See Docs/AI-Provider-Ladder-2026-07-23.md §3.1. Every call site passes a tier into
/// ``FernletAIGate/dispatch(tier:userInvoked:)``; the tier's ``escalationLadder`` is the ordered rung
/// list the router walks.
///
/// Placement: this and the router/quota contract types live in `AIContext` (not `FernletDomainModel`)
/// because they are AI control-plane concepts that sit alongside the audit log and the typed
/// payloads. `AIContext` already depends on `FernletDomainModel` (for `AIDestination` / `AIStatus` /
/// `FernletSettings`), and both the walled `AIProviders` module and the app-side callers already
/// import `AIContext`, so no new dependency edge is introduced.
public enum AICapabilityTier: String, Codable, Sendable, CaseIterable {
    /// Journal emotion tags, tone wrapper, thought bubbles, diagnostic-language classifier.
    /// On-device ONLY — never escalates off the device.
    case light
    /// Meal decomposition, food selection, workout adjustment, day summary. On-device → PCC (later).
    case standard
    /// Recipe synthesis, workout program personalization. PCC → BYOK (later); on-device + deterministic today.
    case deep

    /// Whether a task at this tier may ever route to a destination that leaves the device.
    ///
    /// `light` is `false`: it is the sensitive-adjacent tier (journal, memory) and is pinned
    /// on-device as a HARD rule, not a default. ``FernletModelRouter`` enforces this at resolution
    /// time with an assertion — a `light` task can never yield a `leavesDevice` destination — so the
    /// pin survives future edits to the ladder rather than living only in a comment.
    public var allowsOffDeviceEscalation: Bool {
        switch self {
        case .light: return false
        case .standard, .deep: return true
        }
    }

    /// The escalation ladder for this tier, cheapest/most-local first. The router walks this list and
    /// takes the first rung the device capability (and, later, the user ceiling) makes available.
    ///
    /// - `light` never leaves the device.
    /// - `standard` prefers on-device, then PCC.
    /// - `deep` prefers PCC → BYOK, and falls back to the on-device model (which is why deep still
    ///   runs on-device today, before any cloud rung exists).
    public var escalationLadder: [AIDestination] {
        switch self {
        case .light:
            return [.onDeviceFoundationModels]
        case .standard:
            return [.onDeviceFoundationModels, .privateCloudCompute]
        case .deep:
            return [.privateCloudCompute, .externalAnthropic, .externalOpenAICompatible, .onDeviceFoundationModels]
        }
    }
}

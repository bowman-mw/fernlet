import Foundation

/// Where an AI call is routed. The floor is on-device Foundation Models; the higher rungs
/// (Apple Private Cloud Compute and user-authorized BYOK providers) are the iOS 27 / cloud tiers
/// described in Docs/AI-Provider-Ladder-2026-07-23.md §2.
///
/// This enum is a `FernletDomainModel` value that lands in the (device-local) AI audit log, so it is
/// a brick-vector site: adding a case needs a CLEAN build (the documented `FernletDomainModel`
/// layout hazard) and any decode from persisted data must ride the `EnumDecodeCompat` freeze/park
/// discipline. Adding a cloud/OHTTP destination here still requires S3 to be fully complete first.
public enum AIDestination: String, Codable, Sendable, CaseIterable {
    /// On-device Apple Foundation Models — the always-available floor. Never leaves the device.
    case onDeviceFoundationModels
    /// The web nutrition search path (chain/packaged-food lookup). Sends the user's meal description
    /// to a search provider; gated by an explicit first-use `FernletSettings` consent decision.
    case webNutritionLookup
    /// Apple Private Cloud Compute — the default deep tier (iOS 27, first-use consent).
    /// Resolves UNAVAILABLE on the installed SDK; see `FernletModelRouter` for the slot-in point.
    case privateCloudCompute
    /// BYOK — Anthropic's native `LanguageModel` package (the default BYOK provider).
    /// Resolves UNAVAILABLE on the installed SDK.
    case externalAnthropic
    /// BYOK — a single custom OpenAI-compatible endpoint (GPT, Kimi, local servers).
    /// Resolves UNAVAILABLE on the installed SDK.
    case externalOpenAICompatible

    /// Whether data crosses the device boundary when a call routes here. The on-device Foundation
    /// model is the only destination that keeps everything local; every other rung egresses (the
    /// web search provider, Apple PCC, or a third-party BYOK provider). This is the type-level fact
    /// the sensitive-work pin (journal/memory → on-device only) is enforced against in the router.
    public var leavesDevice: Bool {
        switch self {
        case .onDeviceFoundationModels:
            return false
        case .webNutritionLookup, .privateCloudCompute, .externalAnthropic, .externalOpenAICompatible:
            return true
        }
    }
}

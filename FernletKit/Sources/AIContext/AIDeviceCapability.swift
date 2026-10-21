import Foundation
import FernletDomainModel

/// A snapshot of which AI rungs the *device* can physically reach, independent of user settings.
///
/// ``FernletModelRouter`` caps every resolution by this — an iPhone-11-class device with no Apple
/// Intelligence gets `onDeviceFoundationModels == false` and lands on the deterministic path
/// (Ladder decision 1). Obtained through the ``AIDeviceCapabilityProviding`` seam so tests and the
/// deterministic-only floor can substitute a fixed value.
public struct AIDeviceCapability: Sendable, Equatable {
    /// The on-device Apple Foundation model is present and available (Apple Intelligence devices).
    public var onDeviceFoundationModels: Bool
    /// Apple Private Cloud Compute is reachable. Always `false` on the installed SDK — the iOS 27
    /// `LanguageModel` / `PrivateCloudComputeLanguageModel` symbols do not exist here yet.
    public var privateCloudCompute: Bool
    /// A user-configured BYOK provider (Anthropic native or a custom OpenAI-compatible endpoint) is
    /// reachable. Always `false` on the installed SDK.
    public var externalProviders: Bool

    /// Creates a snapshot; the cloud rungs default to `false`, matching the installed SDK's reality.
    public init(onDeviceFoundationModels: Bool, privateCloudCompute: Bool = false, externalProviders: Bool = false) {
        self.onDeviceFoundationModels = onDeviceFoundationModels
        self.privateCloudCompute = privateCloudCompute
        self.externalProviders = externalProviders
    }

    /// Whether a specific destination is reachable on this device right now.
    public func isAvailable(_ destination: AIDestination) -> Bool {
        switch destination {
        case .onDeviceFoundationModels:
            return onDeviceFoundationModels
        // `webNutritionLookup` is a distinct, settings-gated web-search path — not a rung on the LLM
        // capability ladder — so device capability does not gate it here.
        case .webNutritionLookup:
            return false
        case .privateCloudCompute:
            return privateCloudCompute
        case .externalAnthropic, .externalOpenAICompatible:
            return externalProviders
        }
    }
}

/// The injectable seam that reports device capability.
///
/// ``FernletModelRouter`` holds one of these and reads it fresh on every resolution. Wrapping the
/// existing `SystemLanguageModel.default.availability` check behind this protocol lets tests
/// simulate a no-Apple-Intelligence device, and lets the cloud rungs slot in later at exactly one
/// place.
public protocol AIDeviceCapabilityProviding: Sendable {
    /// The rungs this device can reach right now.
    var capability: AIDeviceCapability { get }
    /// Whether the on-device model can run right now and, when it cannot, why — what Settings tells
    /// the person. Display only: routing reads ``capability``.
    var onDeviceAvailability: OnDeviceModelAvailability { get }
}

extension AIDeviceCapabilityProviding {
    /// A provider that knows only the rung answers available, or unavailable for an unnamed reason —
    /// never a reason it cannot vouch for.
    public var onDeviceAvailability: OnDeviceModelAvailability {
        capability.onDeviceFoundationModels ? .available : .unavailable
    }
}

/// Whether the on-device model can run on this iPhone right now and, when it cannot, the reason.
///
/// Read through ``AIDeviceCapabilityProviding/onDeviceAvailability``; the app's Settings "Today" row
/// and its voice line show it ahead of the effective `AIStatus`, because the daily counter behind
/// that status never moves on a device that cannot run the model (the router falls back without
/// charging), so the status alone said "Ready" on every iPhone without Apple Intelligence. A display
/// fact only: nothing persists or syncs it, and routing still gates on
/// ``AIDeviceCapability/onDeviceFoundationModels``.
public enum OnDeviceModelAvailability: Sendable, Equatable {
    /// The model is available.
    case available
    /// This iPhone cannot run Apple Intelligence, or the SDK has no on-device model at all.
    case deviceNotEligible
    /// The iPhone is eligible, but Apple Intelligence is turned off.
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is on, but the model is still downloading or otherwise not ready.
    case modelNotReady
    /// The model is ready, but it does not support the language the app is running in, so every AI
    /// call site takes its deterministic path (localization plan §5.1; decided by `AIProviders`'
    /// `OnDeviceModelLanguage`).
    case languageNotSupported
    /// Unavailable for a reason the provider does not name (a capability-only provider, or a reason
    /// newer than this build).
    case unavailable
}

/// A fixed-capability provider for tests and for the deterministic-only floor.
///
/// Wraps a constant ``AIDeviceCapability`` so a router can be built without touching the live
/// `SystemLanguageModel` availability check.
public struct StaticAIDeviceCapabilityProvider: AIDeviceCapabilityProviding {
    public let capability: AIDeviceCapability
    /// Creates a provider that always reports `capability`.
    public init(_ capability: AIDeviceCapability) {
        self.capability = capability
    }
}

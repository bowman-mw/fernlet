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

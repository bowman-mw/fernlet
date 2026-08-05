import Foundation
import AIContext

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The production `AIDeviceCapabilityProviding` — wraps the on-device availability check
/// (`SystemLanguageModel.default.availability`, the probe `FoodSelectionAvailability` delegates to) so
/// the router can gate on real device capability while tests inject a `StaticAIDeviceCapabilityProvider`.
///
/// The Private Cloud Compute and BYOK rungs report `false` here: their symbols
/// (`LanguageModel`, `PrivateCloudComputeLanguageModel`, the vendor packages) are iOS 27 APIs that
/// do NOT exist on the installed SDK. This provider is the single slot-in point — when the iOS 27
/// adapters land, an `#available(iOS 27, *)` check sets `privateCloudCompute` / `externalProviders`
/// here, and nothing else in the router changes.
///
/// A stateless value: the app's AI composition root constructs one and hands it to the router
/// inside `FernletAIGate`, and ``capability`` probes the system model live on every read, so a
/// mid-session Apple Intelligence toggle is always reflected.
public struct SystemLanguageModelCapabilityProvider: AIDeviceCapabilityProviding {
    public init() {}

    /// The device's current rung availability: the on-device Foundation model probed live via
    /// ``isOnDeviceModelAvailable``; Private Cloud Compute and external providers pinned `false`
    /// until their iOS 27 APIs exist.
    public var capability: AIDeviceCapability {
        AIDeviceCapability(
            onDeviceFoundationModels: Self.isOnDeviceModelAvailable,
            // iOS 27 slot-in point: PCC availability resolves here behind `#available(iOS 27, *)`.
            privateCloudCompute: false,
            // BYOK slot-in point: reflects a user-configured Anthropic/custom endpoint on iOS 27.
            externalProviders: false
        )
    }

    /// `true` when the default `SystemLanguageModel` reports `.available` — the canonical
    /// availability probe (``FoodSelectionAvailability`` delegates here); `false` on incapable
    /// hardware or SDKs without `FoundationModels`.
    static var isOnDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }
}

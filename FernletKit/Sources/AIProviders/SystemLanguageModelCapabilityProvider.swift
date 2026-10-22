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
    /// `isOnDeviceModelAvailable` (which includes the app-language gate, ``OnDeviceModelLanguage``);
    /// Private Cloud Compute and external providers pinned `false` until their iOS 27 APIs exist.
    public var capability: AIDeviceCapability {
        AIDeviceCapability(
            onDeviceFoundationModels: Self.isOnDeviceModelAvailable,
            // iOS 27 slot-in point: PCC availability resolves here behind `#available(iOS 27, *)`.
            privateCloudCompute: false,
            // BYOK slot-in point: reflects a user-configured Anthropic/custom endpoint on iOS 27.
            externalProviders: false
        )
    }

    /// The live reason the on-device model can or cannot run, for Settings' "Today" row.
    public var onDeviceAvailability: OnDeviceModelAvailability {
        Self.onDeviceModelAvailability
    }

    /// `true` when the default `SystemLanguageModel` reports `.available` AND supports the app's
    /// language (``OnDeviceModelLanguage``) — the canonical availability probe
    /// (``FoodSelectionAvailability`` delegates here); `false` on incapable hardware, SDKs without
    /// `FoundationModels`, or an app language the model lacks.
    static var isOnDeviceModelAvailable: Bool {
        onDeviceModelAvailability == .available
    }

    /// The model's availability for this app: ``systemModelAvailability``, then the language gate.
    static var onDeviceModelAvailability: OnDeviceModelAvailability {
        availability(model: systemModelAvailability, appLanguageSupported: OnDeviceModelLanguage.supportsAppLanguage)
    }

    /// The language gate over a model availability: a ready model that does not support the app's
    /// language is `.languageNotSupported`; every other answer passes through unchanged. Pure, so a
    /// test can pin it without a model.
    nonisolated static func availability(
        model: OnDeviceModelAvailability, appLanguageSupported: Bool
    ) -> OnDeviceModelAvailability {
        guard model == .available, !appLanguageSupported else { return model }
        return .languageNotSupported
    }

    /// The default `SystemLanguageModel`'s availability, its unavailable reason mapped one to one; an
    /// SDK without `FoundationModels` is a device that cannot run the model.
    static var systemModelAvailability: OnDeviceModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return availability(for: reason)
            }
        }
        #endif
        return .deviceNotEligible
    }

    #if canImport(FoundationModels)
    /// One unavailable reason in the app's vocabulary; a reason newer than this build is `.unavailable`.
    @available(iOS 26.0, *)
    private static func availability(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> OnDeviceModelAvailability {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unavailable
        }
    }
    #endif
}

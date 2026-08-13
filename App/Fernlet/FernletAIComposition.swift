import AIContext
import AIProviders

/// Composition-root factory for the AI provider seam. Its sole job is to construct the concrete
/// `AIDeviceCapabilityProviding` — `SystemLanguageModelCapabilityProvider`, which wraps the on-device
/// `SystemLanguageModel.default.availability` check and is the single slot-in point for the iOS 27
/// PCC/BYOK adapters.
///
/// It lives in its own file ON PURPOSE: naming `SystemLanguageModel…` matches the S3 grep-wall's
/// AI-facing marker, so the type is kept OUT of `FernletStore.swift` (which references many sealed
/// `Private*` stores and must not be treated as an AI prompt builder). This file names no sealed
/// store — it is a clean AI-facing file — so the wall stays satisfied while the store just calls this
/// factory.
enum FernletAIComposition {
    /// The production device-capability provider. Injectable at the store so a test can substitute a
    /// `StaticAIDeviceCapabilityProvider` (incapable device, cloud-reachable, …).
    static func defaultCapabilityProvider() -> AIDeviceCapabilityProviding {
        SystemLanguageModelCapabilityProvider()
    }
}

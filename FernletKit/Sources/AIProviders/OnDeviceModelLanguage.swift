import Foundation
import AIContext
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one place Fernlet decides whether the on-device model may work in the app's language
/// (localization plan §5.1).
///
/// Two conditions, both required: the language is one the app ships — ``FernletLanguage/app`` is a
/// localization the main bundle resolved, so it is app-supported by construction — and the system
/// model lists it (`SystemLanguageModel.supportsLocale`). Until 2026-10-21 `supportedLanguages` was
/// checked nowhere, so an app running in a language the model lacked would have sent it prompts it
/// could not answer well, with nothing to say so.
///
/// It is consulted by ``SystemLanguageModelCapabilityProvider``: an unsupported language reports the
/// on-device model as unavailable (`OnDeviceModelAvailability.languageNotSupported`), so the router
/// lands every call site on its deterministic fallback — the architecture's whole point — and Settings
/// says why. English is always supported: the prompts' own instructions are English.
///
/// What the model is told once it may run is `AIContext`'s ``AIPromptLanguage``, which each payload
/// carries. A stateless namespace; the probe reads the system model live, so a model update is
/// picked up without a relaunch.
public nonisolated enum OnDeviceModelLanguage {
    /// Whether the on-device model may be asked to work in the app's interface language.
    public static var supportsAppLanguage: Bool {
        supports(FernletLanguage.app)
    }

    /// Whether the system model supports `language`; English always, and nothing on an SDK without
    /// `FoundationModels` (where the model is unavailable anyway).
    public static func supports(_ language: FernletLanguage) -> Bool {
        guard language != .english else { return true }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: language.rawValue))
        }
        #endif
        return false
    }

    /// The prompt language for the app right now, or nil when the model cannot work in it — the
    /// gate ``AIPromptLanguage/resolve(appLanguage:modelSupportsLanguage:address:)`` with the live
    /// probe.
    ///
    /// - Parameter address: The effective profile's `sex.termOfAddress` for a prose prompt; nil for
    ///   a catalog prompt.
    public static func promptLanguage(addressing address: TermOfAddress? = nil) -> AIPromptLanguage? {
        AIPromptLanguage.resolve(
            appLanguage: FernletLanguage.app, modelSupportsLanguage: supportsAppLanguage, address: address
        )
    }
}

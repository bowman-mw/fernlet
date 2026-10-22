import SwiftUI
import AIContext
import FernletDomainModel
import FernletScoring

/// What Settings' AI card says about the on-device helper today: the "Today" value and the
/// companion's voice line under the switches.
///
/// It reads the EFFECTIVE status (`FernletStore.effectiveAIStatus`: the synced intent overlaid with this
/// device's daily call counter) and whether this iPhone can run the on-device model
/// (`AIDeviceCapabilityProviding.onDeviceAvailability`). The counter never moves on a device that
/// cannot run the model — the router falls back without charging a call — so until 2026-10-16 the row
/// said "Ready" forever on every iPhone without Apple Intelligence, and because the intent syncs,
/// turning the helper on on one iPhone made an ineligible second one say "Ready" too (bug confirmation
/// 2026-10-15, food-ai §7). Here the device's reason comes first, after the person's own "Off".
///
/// Display only: the synced `AIStatus` tokens, the counter and the routing are untouched.
enum AIStatusPresentation: Equatable {
    /// The effective status as it is: the helper is off, or this iPhone can run it.
    case status(AIStatus)
    /// This iPhone cannot run Apple Intelligence.
    case notAvailableOnThisIPhone
    /// The iPhone is eligible, but Apple Intelligence is turned off in iOS Settings.
    case turnOnAppleIntelligence
    /// Apple Intelligence is on, but the model is still downloading or otherwise getting ready.
    case gettingReady
    /// The model is unavailable for a reason this build does not name.
    case notAvailableRightNow
    /// The model is ready but does not support the language the app is running in.
    case notAvailableInThisLanguage

    /// The presentation for an effective status on a device with the given availability. The person's
    /// own "Off" wins, since it is true on every device; otherwise a device that cannot run the model
    /// says why, and only a device that can shows the effective status.
    init(effective: AIStatus, availability: OnDeviceModelAvailability) {
        guard effective != .off else {
            self = .status(.off)
            return
        }
        switch availability {
        case .available: self = .status(effective)
        case .deviceNotEligible: self = .notAvailableOnThisIPhone
        case .appleIntelligenceNotEnabled: self = .turnOnAppleIntelligence
        case .modelNotReady: self = .gettingReady
        case .unavailable: self = .notAvailableRightNow
        case .languageNotSupported: self = .notAvailableInThisLanguage
        }
    }

    /// The "Today" row's value.
    var label: LocalizedStringKey {
        switch self {
        case .status(.ready): "Ready"
        case .status(.sleepy): "Sleepy"
        case .status(.resting): "Resting"
        case .status(.off): "Off"
        case .notAvailableOnThisIPhone: "Not available on this iPhone"
        case .turnOnAppleIntelligence: "Turn on Apple Intelligence"
        case .gettingReady: "Getting ready"
        case .notAvailableRightNow: "Not available right now"
        case .notAvailableInThisLanguage: "Not available in this language"
        }
    }

    /// The companion's line under the switches: the switched-off copy whenever the helper cannot run
    /// (off, or a device that cannot run it), the resting copy for a spent daily budget, otherwise the
    /// gentle retry note.
    var voiceLine: FernletVoice {
        switch self {
        case .status(.ready): .retryAvailable
        case .status(.sleepy), .status(.resting): .aiResting
        case .status(.off), .notAvailableOnThisIPhone, .turnOnAppleIntelligence, .gettingReady, .notAvailableRightNow,
             .notAvailableInThisLanguage:
            .aiUnavailable
        }
    }
}

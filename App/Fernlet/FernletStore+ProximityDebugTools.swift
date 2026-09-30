import Foundation
import FernletDomainModel

/// The Release clamp on the proximity debug tools (2026-09-29).
///
/// `SettingsModel.showProximityDebugTools` is a synced setting, and the only switch for it lives in
/// the Settings debug tab, which a Release build does not compile. A `true` synced from a DEBUG
/// install would therefore reach a Release build with no way to turn it off, and it gates things
/// that must stay off in normal use: the raw transport diagnostic under the Friends tab's discovery
/// banner, the recipe-share sheet's "Connection details" log (both carry peer identifiers), the
/// connect row's Force distance override, and the Connection Inspector entry point.
///
/// Every render-time gate reads ``proximityDebugToolsEnabled`` rather than the stored field. The
/// stored value is untouched: this is a read clamp, not a migration, so a DEBUG build on the same
/// iCloud account still sees the setting it chose.
extension FernletStore {

    /// Whether the proximity debug tools are on for this build: the stored setting in DEBUG, and
    /// always false in Release.
    var proximityDebugToolsEnabled: Bool {
        #if DEBUG
        settings.showProximityDebugTools
        #else
        false
        #endif
    }
}

import Foundation

/// The World map's two device-only settings (World app plan step 5a; design page answers 4 and 20).
///
/// - **Uncover the map as you go** (on by default): whether precise readings lift the fog. The fog
///   starts on its own from the first open, with no prompt of its own beyond iOS's location prompt.
/// - **Always, low power** (off by default): iOS's visit and significant-change updates fill the fog
///   along the day. Needs the Always permission, asked only when the person turns this on.
///
/// Device-only `UserDefaults`, never in the synced settings: they describe this phone's location
/// behaviour. Both keys are cleared by the delete funnel (``clearAll(in:)``,
/// `PersistedSurfaceWipeBoundaryTests`).
nonisolated enum WorldMapPreferences {
    /// The keys (frozen tokens).
    enum Key {
        static let uncoverAsYouGo = "fernlet.worldMap.uncoverAsYouGo"
        static let alwaysLowPower = "fernlet.worldMap.alwaysLowPower"
    }

    /// Whether the fog lifts as you go (default on).
    static func uncoverAsYouGo(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.uncoverAsYouGo) != nil else { return true }
        return defaults.bool(forKey: Key.uncoverAsYouGo)
    }

    /// Sets "Uncover the map as you go".
    static func setUncoverAsYouGo(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.uncoverAsYouGo)
    }

    /// Whether the low-power Always mode is on (default off).
    static func alwaysLowPower(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.alwaysLowPower)
    }

    /// Sets the low-power Always mode.
    static func setAlwaysLowPower(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.alwaysLowPower)
    }

    /// Removes both settings (the delete funnel), so the next launch starts from the defaults.
    static func clearAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.uncoverAsYouGo)
        defaults.removeObject(forKey: Key.alwaysLowPower)
    }
}

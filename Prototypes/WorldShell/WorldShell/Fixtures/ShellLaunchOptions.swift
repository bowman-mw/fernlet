import Foundation

/// Fixture states set from launch arguments, so a screenshot run can open the shell straight into
/// any state without tapping: `xcrun simctl launch <device> MBO.Fernlet.WorldShell -shellPanel today`.
///
/// Arguments arrive through `UserDefaults`' argument domain, so nothing is stored. Keys:
/// `-shellSpot` (home, gym, trail, noodle, fresh), `-shellRide` (onFoot, bike, car), `-shellDecoy YES`,
/// `-shellPhase` (dawn, day, dusk, night), `-shellState` (thriving … sick), `-shellLevel`
/// (dayOne, month, year), `-shellMap` (appleMuted, plain), `-shellPanel` (today, food, move, log,
/// friends, privacy, settings, wall, customize), `-shellQuickStart YES`, `-shellUnlockPrivate YES`,
/// `-shellWalk YES` (start the walk replay at launch), `-shellOutfit` (glasses …), and
/// `-shellRideSeconds` (with `-shellRide bike`: get off the bike after that many seconds, so the
/// self-logged ride can be screenshotted).
nonisolated struct ShellLaunchOptions: Sendable {
    var spot: FixtureSpot?
    var ride: CompanionRide?
    var decoy = false
    var phase: SkyPhase?
    var state: ShellCompanionState?
    var level: TimeWithFernlet?
    var baseMap: BaseMapKind?
    var panel: PanelKind?
    var quickStart = false
    var unlockPrivate = false
    var walk = false
    var outfit: Outfit?
    var rideSeconds: Double?

    /// Reads the options from `defaults` (the launch arguments, by default).
    init(defaults: UserDefaults = .standard) {
        func value(_ key: String) -> String? { defaults.string(forKey: key) }
        spot = value("shellSpot").flatMap(FixtureSpot.init(rawValue:))
        ride = value("shellRide").flatMap(CompanionRide.init(rawValue:))
        decoy = defaults.bool(forKey: "shellDecoy")
        phase = value("shellPhase").flatMap(SkyPhase.init(rawValue:))
        state = value("shellState").flatMap(ShellCompanionState.init(rawValue:))
        level = value("shellLevel").flatMap(TimeWithFernlet.init(rawValue:))
        baseMap = value("shellMap").flatMap(BaseMapKind.init(rawValue:))
        panel = value("shellPanel").flatMap(PanelKind.init(rawValue:))
        quickStart = defaults.bool(forKey: "shellQuickStart")
        unlockPrivate = defaults.bool(forKey: "shellUnlockPrivate")
        walk = defaults.bool(forKey: "shellWalk")
        outfit = value("shellOutfit").flatMap(Outfit.init(rawValue:))
        rideSeconds = value("shellRideSeconds").flatMap(Double.init)
    }
}

extension WorldShellModel {
    /// Applies the launch options that need the model running (rides, panels, a walk in progress).
    func apply(_ options: ShellLaunchOptions) {
        if let outfit = options.outfit { self.outfit = outfit }
        if let ride = options.ride, ride != .onFoot { changeRide(to: ride) }
        if let seconds = options.rideSeconds, options.ride != nil {
            schedule("launchRide", after: max(1, seconds)) { [weak self] in self?.changeRide(to: .onFoot) }
        }
        if options.walk { startWalk(hike: spot == .trail) }
        panel = options.panel
        quickStartOpen = options.quickStart
        privateUnlocked = options.unlockPrivate
        if options.panel == nil && !options.quickStart && !options.walk { say(nil, for: 5) }
    }
}

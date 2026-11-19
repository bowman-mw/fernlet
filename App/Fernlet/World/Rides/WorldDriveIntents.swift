import AppIntents
import FernletFoundation
import Foundation
import UIKit

/// How a drive hint reached the map.
nonisolated enum WorldDriveSignalOutcome: Equatable, Sendable {
    /// The map's location source heard it.
    case delivered
    /// Background mapping is off, so nothing can start in the background.
    case backgroundMappingOff
    /// No store could be had (the phone locked before Fernlet ran this launch): the drive is found by speed later.
    case unavailable
}

/// Hands a drive hint from Driving Focus or the Start a drive / End a drive actions to the map's location source
/// (owner 2026-11-09, car signals: `WorldLocationSource.hintDrive(_:now:)`). It uses the store already in memory
/// when there is one, so a hint reaches the running map while the phone is locked; with no store and the phone locked,
/// the map's location a locked launch runs before the store (`WorldLockedMapping`, started here when it hasn't been);
/// otherwise it loads the store through the one shared path (`FernletStoreAccess`). Nothing is written; only
/// background mapping's own location runs.
///
/// **A Focus turning off looks like one turning on** (release review 2026-11-18, F15): iOS runs a Focus filter again
/// when its Focus ends, with its parameters at their defaults, and "Map my drive" defaults to on. So a run of the
/// filter that says on within ``focusOffWindow`` of a drive that ended parked is taken for the Focus ending after
/// parking and starts nothing (``passes(_:fromFocus:lastEnd:endedAt:now:)``); the Start a drive action always passes.
@MainActor
enum WorldDriveSignal {
    /// How long after a drive ended parked a Focus filter's "on" is taken for the Focus turning off.
    nonisolated static let focusOffWindow: TimeInterval = 10 * 60

    /// Whether a hint is handed on: always an off, and an on unless it came from the Focus filter (`fromFocus`) no
    /// more than ``focusOffWindow`` after the last drive ended parked (`lastEnd`, `endedAt`).
    nonisolated static func passes(_ on: Bool, fromFocus: Bool, lastEnd: WorldDriveEnd?, endedAt: Date?, now: Date) -> Bool {
        guard on, fromFocus, lastEnd == .parked, let endedAt else { return true }
        let since = now.timeIntervalSince(endedAt)
        return since < 0 || since > focusOffWindow
    }

    /// Hands `on` to `source` when it passes (``passes(_:fromFocus:lastEnd:endedAt:now:)``).
    private static func hand(_ on: Bool, fromFocus: Bool, to source: WorldLocationSource) {
        guard passes(on, fromFocus: fromFocus, lastEnd: source.rides.lastDriveEnd,
                     endedAt: source.rides.lastDriveEndedAt, now: Date()) else { return }
        source.hintDrive(on)
    }

    /// Hands `on` to the map (`fromFocus`: from the Focus filter, not an action); how it went.
    static func post(_ on: Bool, fromFocus: Bool = false) async -> WorldDriveSignalOutcome {
        guard WorldMapPreferences.alwaysLowPower() || WorldMapPreferences.backgroundMappingMarked() else {
            return .backgroundMappingOff
        }
        if let loaded = FernletStoreAccess.shared.loaded {
            loaded.wireWorldRides()
            hand(on, fromFocus: fromFocus, to: loaded.worldLocation)
            return .delivered
        }
        if !UIApplication.shared.isProtectedDataAvailable {
            guard let early = WorldLockedMapping.shared.start() else { return .unavailable }
            hand(on, fromFocus: fromFocus, to: early)
            return .delivered
        }
        do {
            let store = try await FernletStoreAccess.shared.load()
            store.wireWorldRides()
            hand(on, fromFocus: fromFocus, to: store.worldLocation)
            return .delivered
        } catch {
            FernletAuditLog.log("worldMap.cars.hintUnavailable")
            return .unavailable
        }
    }
}

/// Why a drive action couldn't run, as Shortcuts shows it.
nonisolated enum WorldDriveIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// Background mapping is off.
    case backgroundMappingOff

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("worldDrive.intent.backgroundMappingOff",
                                defaultValue: "Turn on Map the world in the background in Fernlet's Settings first.",
                                comment: "Shortcuts: the Start a drive or End a drive action ran with background mapping off")
    }
}

/// Fernlet's Focus filter, "Map my drive" (owner 2026-11-09): added to Driving in Settings › Focus, iOS runs it when
/// that Focus turns on (with CarPlay, a car's Bluetooth or Apple's own driving detection), so the map starts the drive
/// at once. Its switch is on by default, so adding the filter is all it takes; a run with it off ends a quiet drive.
/// iOS may never say the Focus ended, so the hint runs out by itself (`WorldLocationSource.hintLife`). When it does
/// say so it runs the filter with its defaults, which is "on" again: ``WorldDriveSignal`` passes that by after a
/// drive that ended parked.
struct MapMyDriveFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Map my drive"
    static let description: IntentDescription? = IntentDescription("Fernlet maps the road from the start of every drive.")

    @Parameter(title: "Map my drive", default: true)
    var mapsDrive: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Map my drive")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await WorldDriveSignal.post(mapsDrive, fromFocus: true)
        return .result()
    }
}

/// The Start a drive action (Shortcuts app only, no Siri slot; owner 2026-11-09): for an automation such as "When
/// CarPlay connects". It primes the map's drive start and listens a few minutes; with background mapping off it says so.
struct StartDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a drive"
    static let description = IntentDescription("Tells Fernlet you're driving, so it maps the road from the start.")
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await WorldDriveSignal.post(true) != .backgroundMappingOff else { throw WorldDriveIntentError.backgroundMappingOff }
        return .result()
    }
}

/// The End a drive action (Shortcuts app only): for an automation such as "When CarPlay disconnects". A drive whose
/// readings have gone quiet ends there; with background mapping off it says so.
struct EndDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "End a drive"
    static let description = IntentDescription("Tells Fernlet the drive is over.")
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await WorldDriveSignal.post(false) != .backgroundMappingOff else { throw WorldDriveIntentError.backgroundMappingOff }
        return .result()
    }
}

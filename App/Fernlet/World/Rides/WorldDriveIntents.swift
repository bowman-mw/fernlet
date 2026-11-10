import AppIntents
import FernletFoundation
import Foundation

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
/// when there is one, so a hint reaches the running map while the phone is locked, and otherwise loads it through
/// the one shared path (`FernletStoreAccess`), which refuses a locked phone. Nothing is written; only background
/// mapping's own location runs.
@MainActor
enum WorldDriveSignal {
    /// Hands `on` to the map; how it went.
    static func post(_ on: Bool) async -> WorldDriveSignalOutcome {
        guard WorldMapPreferences.alwaysLowPower() else { return .backgroundMappingOff }
        let store: FernletStore
        if let loaded = FernletStoreAccess.shared.loaded {
            store = loaded
        } else {
            do {
                store = try await FernletStoreAccess.shared.load()
            } catch {
                FernletAuditLog.log("worldMap.cars.hintUnavailable")
                return .unavailable
            }
        }
        store.wireWorldRides()
        store.worldLocation.hintDrive(on)
        return .delivered
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
/// iOS may never say the Focus ended, so the hint runs out by itself (`WorldLocationSource.hintLife`).
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
        _ = await WorldDriveSignal.post(mapsDrive)
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

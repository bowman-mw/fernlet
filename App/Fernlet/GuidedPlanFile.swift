import Foundation
import FernletDomainModel
import FernletFoundation

// Today's workout plan on this device (the owner's fix e7, 2026-11-10): "Keep today's plan on the
// device until the day ends, with its edits and approval. Not synced."
//
// The committed plan used to live in memory only, so when iOS closed the app in the background the
// plan's hand edits, its AI adjustment, the intensity it was built with and its approval were gone,
// and the Move card went back to "Suggest". This file is where the plan now waits out the day.
//
// WHERE, AND WHY NOT BEHIND THE APP LOCK. Two precedents hold comparable device-local workout state:
// the guided run (`GuidedWorkoutRunState.json`: the app group, protected until first unlock, because
// the Lock Screen buttons must drive it) and the device-only caches (`FileDeviceDaySummaryStore`,
// `FileDeviceHealthResidueStore`: Application Support, never in a backup, complete file protection).
// The plan takes the stricter one: its own folder in Application Support (not the app group, so no
// extension can read it), excluded from backups, and written with complete file protection, so it is
// encrypted whenever the phone is locked. It is NOT sealed under the app lock's content key. A plan
// carries nothing its own inputs do not: the limits it was built around and the injury note live in
// the settings, and "Anything else?" has always been written into the logged workout's note — all of
// them outside the sealed stores, on the synced side. Sealing the plan would make a copy stricter
// than its sources while the Move card (which must draw before any private section is opened) could
// no longer show it. The app lock's cover hides it like the rest of Move.
//
// NEVER SYNCED: not part of `FernletSnapshot`, a day record, the sealed backup or the export, and in
// the app target, where the walled `CloudKitSync` cannot reach it. KEYED BY THE DAY: a record for
// another day is deleted when it is read. ERASED by "Delete everything" (`FernletStore.resetAll`).
// BOUNDED (R3): at most `maxSessions` sessions of `maxSteps` steps, every text capped, and a file
// larger than `maxBytes` is not read at all.

/// What today's plan was built for: the space and what it owns, the limits, and the hidden
/// exercises. When one of them changes, the sessions not yet started are rebuilt (the owner's fix
/// e4; `FernletStore+GuidedPlanLifetime.swift`).
///
/// Tokens only, sorted, so two bases compare equal exactly when the planner would see the same
/// space, limits and hidden list. A space's name is left out: renaming it changes no plan.
nonisolated struct GuidedPlanBasis: Codable, Equatable {
    /// The active space's id.
    var spaceID: UUID
    /// The space's equipment tokens, sorted.
    var equipment: [String]
    /// The space's "Weights I have", as one comparable line.
    var weights: String
    /// The areas left out entirely, sorted tokens.
    var severe: [String]
    /// The areas trained around, sorted tokens.
    var mild: [String]
    /// Single muscles and movement patterns avoided outright, sorted tokens.
    var avoided: [String]
    /// The hidden exercises' comparison keys, sorted.
    var hidden: [String]

    /// The basis the planner would build from now.
    init(location: WorkoutLocation, limits: InjuryLimits, hiddenKeys: Set<String>) {
        spaceID = location.id
        equipment = (location.ownedEquipment.map(\.rawValue) + location.unknownEquipmentTokens).sorted()
        let owned = location.weights
        weights = "\(owned.unit.rawValue)|\(owned.dumbbells)|\(owned.kettlebells)|\(owned.barWeight ?? -1)|\(owned.platePairs)"
        severe = limits.severeAreas.map(\.rawValue).sorted()
        mild = limits.mildAreas.map(\.rawValue).sorted()
        avoided = (limits.avoidedMuscles.map(\.rawValue) + limits.avoidedMovements.map { "move:\($0.rawValue)" }).sorted()
        hidden = hiddenKeys.sorted()
    }

    /// Whether the space, or what it owns, differs from `other`'s.
    func spaceDiffers(from other: GuidedPlanBasis) -> Bool {
        spaceID != other.spaceID || equipment != other.equipment || weights != other.weights
    }

    /// Whether the limits differ from `other`'s.
    func limitsDiffer(from other: GuidedPlanBasis) -> Bool {
        severe != other.severe || mild != other.mild || avoided != other.avoided
    }
}

/// Why today's plan was rebuilt, for the line the plan pane draws under its header ("Updated for
/// Home."), with the sessions whose hand edits or AI adjustment the rebuild replaced.
nonisolated struct GuidedPlanNotice: Codable, Equatable {
    /// What changed. FROZEN tokens (persisted in today's plan file).
    nonisolated enum Reason: String, Codable {
        /// The active space, or what it owns.
        case space
        /// The limits (the picker, the note, "No longer an issue").
        case limits
        /// The hidden exercises.
        case hidden
    }

    /// What changed.
    var reason: Reason
    /// The stored name of the space the plan is now built for (drawn through `WorkoutLocationNames`).
    var spaceName: String
    /// The frozen names of the sessions whose own changes were replaced, in plan order.
    var replacedSessionNames: [String]
}

/// Today's plan as the file holds it: the plan, what it was built with, and what has happened to it.
nonisolated struct GuidedPlanRecord: Codable, Equatable {
    /// The record shape this build writes. A record of another version is deleted, not migrated:
    /// the plan is one day's, and Suggest builds another.
    static let currentVersion = 1
    /// Most sessions kept (a split day has one or two).
    static let maxSessions = 6
    /// Most steps kept in one session (the full warm-up flow, the lifts with their warm-up sets, the
    /// cool-down).
    static let maxSteps = 160
    /// Most characters kept of a note, a plan text or "Anything else?".
    static let maxText = 6_000

    var version = GuidedPlanRecord.currentVersion
    /// The day the plan is for.
    var dayKey: String
    /// The intensity it was built with (`WorkoutIntensity` token).
    var intensity: String
    /// "Anything else?" as it was typed.
    var context: String
    /// The length chosen on the sheet (`WorkoutSessionLength` token); nil when Workout setup's applied.
    var sessionLength: String?
    /// Whether the plan was approved (saved for later, or started).
    var approved: Bool
    /// The sessions already logged.
    var completedSessionIDs: [UUID]
    /// The sessions edited by hand or adjusted with AI since they were built.
    var editedSessionIDs: [UUID]
    /// What the plan was built for; nil in a record that never recorded one.
    var basis: GuidedPlanBasis?
    /// The "Updated for Home" line, while there is one.
    var notice: GuidedPlanNotice?
    /// The plan itself.
    var plan: StoredPlan

    /// The plan's own fields (`WorkoutProgram.DayPlan`).
    nonisolated struct StoredPlan: Codable, Equatable {
        var splitName: String
        var dayTitle: String
        var droppedSlots: [String]
        var locationName: String
        var recovery: StoredRecovery?
        var sessions: [StoredSession]
    }

    /// The 48-hour guard's decision (`WorkoutRecoveryGuard.Decision`).
    nonisolated struct StoredRecovery: Codable, Equatable {
        var dayIndex: Int
        var movedFrom: Int?
        var overlap: [MuscleGroup]
    }

    /// One session (`WorkoutProgram.SessionSuggestion`), under its own id so a restored plan keeps
    /// its completions and a run in progress still matches its session.
    nonisolated struct StoredSession: Codable, Equatable {
        var id: UUID
        var title: String
        var timeLabel: String
        /// `SessionKind` token.
        var kind: String
        var suggestionID: UUID
        var name: String
        var exercisesText: String
        var notes: String
        var steps: [StoredStep]
    }

    /// One step (`PrescribedExercise`). A plan step never carries a cardio segment (the runner makes
    /// those when it starts), so none is kept.
    nonisolated struct StoredStep: Codable, Equatable {
        var id: UUID
        var name: String
        var sets: Int
        var reps: String
        /// `SlotRole` as a token: "main", "accessory" or "core".
        var role: String
        var fromCatalog: Bool
        var restSecondsOverride: Int?
        var block: SessionBlock
        var holdSeconds: Int?
        var side: ExerciseSide?
        var guidance: StoredGuidance?
    }

    /// A lift's load plan (`LoadGuidance`).
    nonisolated struct StoredGuidance: Codable, Equatable {
        var targetReps: Int
        var prescription: StoredPrescription?
        var equipment: Equipment?
        var unit: LoadUnit
        var askReasonOnOverride: Bool
        var calibration: CalibrationStep?
        var easierSession: Bool
        var compoundsBefore: Int
        var warmUp: Bool
        var harderVariation: String?
        var loads: [Double]?
    }

    /// A lift's weight range (`WeightPrescription`).
    nonisolated struct StoredPrescription: Codable, Equatable {
        var low: Double
        var high: Double
        var suggested: Double
        var step: Double
        var unit: LoadUnit
        var confidence: EstimateConfidence
    }
}

// MARK: - Plan ↔ record

nonisolated extension GuidedPlanRecord.StoredPlan {
    /// `plan` as the file holds it, bounded.
    init(_ plan: WorkoutProgram.DayPlan) {
        splitName = plan.splitName
        dayTitle = plan.dayTitle
        droppedSlots = Array(plan.droppedSlots.prefix(GuidedPlanRecord.maxSteps))
        locationName = plan.locationName
        recovery = plan.recovery.map {
            GuidedPlanRecord.StoredRecovery(dayIndex: $0.dayIndex, movedFrom: $0.movedFrom,
                                            overlap: $0.overlap.sorted { $0.rawValue < $1.rawValue })
        }
        sessions = plan.sessions.prefix(GuidedPlanRecord.maxSessions).map(GuidedPlanRecord.StoredSession.init)
    }

    /// The plan this holds, bounded again on the way out so a hand-edited file cannot grow it.
    var plan: WorkoutProgram.DayPlan {
        WorkoutProgram.DayPlan(
            splitName: splitName, dayTitle: dayTitle,
            sessions: sessions.prefix(GuidedPlanRecord.maxSessions).map(\.session),
            droppedSlots: Array(droppedSlots.prefix(GuidedPlanRecord.maxSteps)), locationName: locationName,
            recovery: recovery.map {
                WorkoutRecoveryGuard.Decision(dayIndex: $0.dayIndex, movedFrom: $0.movedFrom, overlap: Set($0.overlap))
            }
        )
    }
}

nonisolated extension GuidedPlanRecord.StoredSession {
    /// `session` as the file holds it.
    init(_ session: WorkoutProgram.SessionSuggestion) {
        id = session.id
        title = session.title
        timeLabel = session.timeLabel
        kind = session.kind.rawValue
        suggestionID = session.suggestion.id
        name = session.suggestion.name
        exercisesText = String(session.suggestion.exercises.prefix(GuidedPlanRecord.maxText))
        notes = String(session.suggestion.notes.prefix(GuidedPlanRecord.maxText))
        steps = session.exercises.prefix(GuidedPlanRecord.maxSteps).map(GuidedPlanRecord.StoredStep.init)
    }

    /// The session this holds. An unknown kind reads as full body, the run state's own fallback.
    var session: WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            id: id, title: title, timeLabel: timeLabel, kind: SessionKind(rawValue: kind) ?? .fullBody,
            exercises: steps.prefix(GuidedPlanRecord.maxSteps).map(\.step),
            suggestion: WorkoutSuggestion(id: suggestionID, name: name,
                                          exercises: String(exercisesText.prefix(GuidedPlanRecord.maxText)),
                                          notes: String(notes.prefix(GuidedPlanRecord.maxText)))
        )
    }
}

nonisolated extension GuidedPlanRecord.StoredStep {
    /// `step` as the file holds it.
    init(_ step: PrescribedExercise) {
        id = step.id
        name = step.name
        sets = step.sets
        reps = step.reps
        role = Self.token(step.role)
        fromCatalog = step.fromCatalog
        restSecondsOverride = step.restSecondsOverride
        block = step.block
        holdSeconds = step.holdSeconds
        side = step.side
        guidance = step.guidance.map(GuidedPlanRecord.StoredGuidance.init)
    }

    /// The step this holds.
    var step: PrescribedExercise {
        PrescribedExercise(
            id: id, name: name, sets: sets, reps: reps, role: Self.role(role), fromCatalog: fromCatalog,
            restSecondsOverride: restSecondsOverride, block: block, holdSeconds: holdSeconds, side: side,
            guidance: guidance?.guidance
        )
    }

    /// The FROZEN token of a slot role (the run state's own spelling).
    static func token(_ role: SlotRole) -> String {
        switch role {
        case .main: "main"
        case .accessory: "accessory"
        case .core: "core"
        }
    }

    /// The role a token names; an unknown one is accessory work.
    static func role(_ token: String) -> SlotRole {
        switch token {
        case "main": .main
        case "core": .core
        default: .accessory
        }
    }
}

nonisolated extension GuidedPlanRecord.StoredGuidance {
    /// `guidance` as the file holds it.
    init(_ guidance: LoadGuidance) {
        targetReps = guidance.targetReps
        prescription = guidance.prescription.map {
            GuidedPlanRecord.StoredPrescription(low: $0.low, high: $0.high, suggested: $0.suggested, step: $0.step,
                                                unit: $0.unit, confidence: $0.confidence)
        }
        equipment = guidance.equipment
        unit = guidance.unit
        askReasonOnOverride = guidance.askReasonOnOverride
        calibration = guidance.calibration
        easierSession = guidance.easierSession
        compoundsBefore = guidance.compoundsBefore
        warmUp = guidance.warmUp
        harderVariation = guidance.harderVariation
        loads = guidance.loads
    }

    /// The load plan this holds.
    var guidance: LoadGuidance {
        LoadGuidance(
            targetReps: targetReps,
            prescription: prescription.map {
                WeightPrescription(low: $0.low, high: $0.high, suggested: $0.suggested, step: $0.step, unit: $0.unit,
                                   confidence: $0.confidence)
            },
            equipment: equipment, unit: unit, askReasonOnOverride: askReasonOnOverride, calibration: calibration,
            easierSession: easierSession, compoundsBefore: compoundsBefore, warmUp: warmUp,
            harderVariation: harderVariation, loads: loads
        )
    }
}

// MARK: - The file

/// Today's plan file: one JSON record in its own Application Support folder (see this file's header
/// for where and why).
///
/// A missing file is no plan. A file that cannot be READ (the phone is locked) is left alone and
/// tried again; one that reads but cannot be decoded, or is too large, is reported as such so the
/// caller deletes it. Failures are named (`PersistenceFailureAudit`), never swallowed.
nonisolated struct GuidedPlanFile {
    /// What a read found.
    nonisolated enum ReadResult: Equatable {
        /// No file: no plan was kept.
        case missing
        /// The file is there and cannot be read now. Not a "no": retry, and do not overwrite.
        case unreadable
        /// The file reads and is not a plan record this build understands.
        case undecodable
        /// The kept plan.
        case record(GuidedPlanRecord)
    }

    /// The file's name inside its folder.
    static let fileName = "todays-plan.json"
    /// The largest file read (R3): a real plan is a few tens of kilobytes.
    static let maxBytes = 1_000_000

    /// The folder the file lives in.
    let directory: URL

    /// The production file, used by the launch path only (`FernletStore.load`). A store built any
    /// other way keeps no plan file unless a test hands it one.
    static var production: GuidedPlanFile { GuidedPlanFile(directory: defaultDirectory()) }

    /// `<Application Support>/FernletTodaysPlan`, falling back to the temporary directory when
    /// Application Support cannot be resolved (never in practice; still device-local).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FernletTodaysPlan", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Reads the kept plan.
    func read() -> ReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            PersistenceFailureAudit.record("guidedPlan.read.failed", error: error)
            return .unreadable
        }
        guard data.count <= Self.maxBytes else { return .undecodable }
        do {
            return .record(try JSONDecoder().decode(GuidedPlanRecord.self, from: data))
        } catch {
            PersistenceFailureAudit.record("guidedPlan.decode.failed", error: error)
            return .undecodable
        }
    }

    /// Writes `record` in place of whatever was kept. The folder is re-created and re-excluded from
    /// backups first, since a clear or a fresh install may have removed it. False when it did not
    /// reach the disk (the caller writes again at the next change or the next foreground).
    func write(_ record: GuidedPlanRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            PersistenceFailureAudit.record("guidedPlan.write.failed", error: error)
            return false
        }
    }

    /// Deletes the kept plan. True when no file is left (a missing one is already that).
    func clear() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            PersistenceFailureAudit.record("guidedPlan.clear.failed", error: error)
            return false
        }
    }
}

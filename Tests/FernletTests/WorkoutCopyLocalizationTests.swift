// WorkoutCopyLocalizationTests.swift
// FernletTests
//
// Idea 16 (2026-10-20): the workout area's remaining English-only copy moved into the String Catalogs,
// and distance and treadmill speed read in the device's units.
//
// What is pinned here, and why each half needs a test:
//   * The planner's note sentences are String Catalog keys. Reverting one to a bare English literal
//     compiles, passes every other test and reads identically in English, so the note-composing
//     files are held to "no English sentence of their own", and every key they declare must be in the
//     domain catalog.
//   * The planner's NAMES — session titles, split and day names, slot labels, the built-in location
//     names and the plan-text descriptors — are frozen tokens: a guided log is saved under the session
//     name and the rotation matches it, the export carries the split and location names, and the
//     history parser reads the plan text. So they stay byte-identical English, every English literal
//     left in the planner source must be one of them, and each must have a display mapping.
//   * Logs, exports, the AI path and HealthKit read the frozen names, never the display mappings.
//   * Distance and speed are stored in miles and mph as always and convert only at entry and display.
//
// Runs in English, like the rest of the suite: a display mapping's English must equal its token.

import Foundation
import Testing
@testable import FernletDomainModel
@testable import Fernlet

/// The idea-16 localization pins: planner notes through the catalog, frozen planner names with
/// display mappings, frozen paths, and metric distance and speed.
@MainActor
struct WorkoutCopyLocalizationTests {

    static let domainRoot = "FernletKit/Sources/FernletDomainModel/"
    static let domainCatalog = "FernletKit/Sources/FernletDomainModel/Localizable.xcstrings"

    /// The files that compose the planner's session notes: none may hold an English sentence of its own.
    static let noteFiles = [
        "WorkoutProgram+LoadNotes.swift", "WorkoutProgram+Load.swift", "WorkoutRecoveryGuard.swift",
        "WorkoutSessionBudget.swift", "WorkoutPlateau.swift", "WorkoutCalibration.swift",
        "WorkoutLoadEngine+Inventory.swift",
    ]

    /// The files that still hold the planner's frozen English names.
    static let tokenFiles = ["WorkoutProgram.swift", "WorkoutSessionBlocks.swift"]

    /// The files that declare idea 16's keys.
    static let copyFiles = [
        "WorkoutPlannerCopy.swift", "WorkoutPlannerCopy+Load.swift", "WorkoutPlannerCopy+Plateau.swift",
        "WorkoutPlannerNames.swift", "WorkoutPlannerNames+Slots.swift", "WorkoutPlannerNames+Locations.swift",
        "WorkoutPlanLine.swift", "WorkoutProgram.swift", "WorkoutModels.swift",
    ]

    /// The key prefixes idea 16 introduced.
    static let keyPrefixes = [
        "workoutNote.", "workoutSession.", "sessionTime.", "workoutSplitDay.", "trainingSplit.", "workoutSlot.",
        "workoutLocation.", "workoutPlanLine.", "gymEquipment.", "experienceLevel.", "splitSpecificity.",
        "workoutConsistency.", "workoutPlanSource.",
    ]

    /// The session templates' titles, exactly as a guided log is saved under them.
    static let frozenSessionTitles = [
        "Full Body A", "Full Body B", "Full Body C", "Upper", "Lower", "Push", "Pull", "Legs", "Chest", "Back",
        "Shoulders", "Arms", "Chest & Back", "Shoulders & Arms", "Easy cardio", "Intervals", "Steady cardio",
        "Mobility", "Sport conditioning",
    ]

    // MARK: - Notes through the catalog

    /// Every idea-16 key the domain declares is in the domain catalog with an English value.
    @Test func everyPlannerKeyIsInTheDomainCatalog() throws {
        let strings = try Self.catalogStrings(Self.domainCatalog)
        var keys: Set<String> = []
        for file in Self.copyFiles {
            let source = try RepoRoot.source(Self.domainRoot + file)
            keys.formUnion(Self.localizedKeys(in: source).filter { key in Self.keyPrefixes.contains { key.hasPrefix($0) } })
        }
        #expect(keys.count >= 200, "found only \(keys.count) idea-16 keys — the scan broke or the copy moved")
        let missing = keys.filter { !Self.hasEnglish(strings, key: $0) }.sorted()
        #expect(missing.isEmpty, "keys with no English entry in \(Self.domainCatalog): \(missing)")
    }

    /// The note-composing files hold no English sentence of their own: every sentence is a key.
    @Test func theNoteFilesHoldNoEnglishSentenceOfTheirOwn() throws {
        var offenders: [String] = []
        var scanned = 0
        for file in Self.noteFiles {
            let source = try RepoRoot.source(Self.domainRoot + file)
            scanned += source.isEmpty ? 0 : 1
            offenders += Self.bareLiterals(in: source).filter(Self.isWords).map { "\(file): \"\($0)\"" }
        }
        #expect(scanned == Self.noteFiles.count, "a note file read empty")
        #expect(offenders.isEmpty, """
            English sentences outside the String Catalog in the planner's note files. Add a \
            WorkoutPlannerCopy key instead: \(offenders)
            """)
    }

    /// Every English literal left in the planner source is a frozen token with a display mapping.
    @Test func everyEnglishLiteralLeftInThePlannerIsAFrozenToken() throws {
        var unmapped: [String] = []
        var seen = 0
        for file in Self.tokenFiles {
            let words = Self.bareLiterals(in: try RepoRoot.source(Self.domainRoot + file)).filter(Self.isWords)
            seen += words.count
            unmapped += words.filter { !Self.isMappedToken($0) }.map { "\(file): \"\($0)\"" }
        }
        #expect(seen >= 60, "only \(seen) English literals found — the scan broke")
        #expect(unmapped.isEmpty, """
            English literals in the planner that are neither a String Catalog key nor a frozen name \
            with a display mapping (WorkoutSessionNames, WorkoutSlotNames, WorkoutSplitDayNames, \
            TrainingSplit.displayName, WorkoutLocationNames, WorkoutPlanLine): \(unmapped)
            """)
    }

    /// The composed notes read exactly as the planner's English always did.
    @Test func composedNotesKeepTheirEnglish() {
        let moreReps = WorkoutPlannerCopy.moreReps("Bench press", reps: 9)
        #expect(moreReps == "Bench press: 9 reps today, one more than last time.")
        let back = WorkoutPlannerCopy.backToBottom("Bench press", reps: 8, weight: "105 lb")
        #expect(back == "Bench press: back to 8 reps — add weight now (105 lb).")
        let lead = WorkoutPlannerCopy.plateauLead("Bench press", weeks: 3)
        #expect(lead.hasPrefix("Bench press has held steady for 3 weeks. That's normal"))
        let few = WorkoutPlannerCopy.plateauLead("Bench press", weeks: 1)
        #expect(few.hasPrefix("Bench press has held steady for a few sessions."))
        let lightened = WorkoutRecoveryGuard.lightenedNote(lifts: ["Back squat", "Lunge"])
        #expect(lightened == "One set fewer on Back squat, Lunge — those muscles worked hard in the last 48 hours.")
        let ladder = WorkoutPlannerCopy.repLadder(reps: 9, low: 8, high: 12)
        #expect(ladder == "Rep ladder: 9 of 8–12 today. One more rep each time; at 12, add weight.")
        let bottom = WorkoutPlannerCopy.ladderBackTo(reps: 8)
        #expect(bottom == "Back to 8 reps — add weight now, about 2.5–5%.")
        let protein = WorkoutPlannerCopy.proteinFloor
        #expect(protein.hasPrefix("Protein logged over the last two weeks has been under about 1.2 g per kg of body weight a day"))
        #expect(protein.hasSuffix("If you're older or have kidney concerns, check with your doctor before changing how much protein you eat."))
        // G10: a flagged miss's hold is said as what happened alongside it, never as the person's fault.
        let night = WorkoutPlannerCopy.heldAfterFlag("Back squat", shortNight: true)
        #expect(night == "Back squat: the same weight today — last time came after a short night, which can take a little off a session, so it doesn't count as a miss.")
        let light = WorkoutPlannerCopy.heldAfterFlag("Back squat", shortNight: false)
        #expect(light == "Back squat: the same weight today — last time fell on a light day, so it doesn't count as a miss.")
        let unfueled = WorkoutPlannerCopy.heldUnfueled("Back squat")
        #expect(unfueled.hasPrefix("Back squat: the same again today — later sets often come up short in a long session"))
        let skipped = WorkoutProgram.hiddenDropNote(["Hinge", "Core"])
        #expect(skipped == "Skipped Hinge, Core — the only options here are ones you've hidden.")
        let fitted = WorkoutPlannerCopy.budgetFitted(minutes: 30, changes: WorkoutPlannerCopy.budgetShorterWarmUp)
        #expect(fitted == "Fitted to 30 min: shorter warm-up.")
    }

    // MARK: - Exercise names in notes (N8)

    /// A note names an exercise by its display name — the name the plan card draws — and a custom or
    /// typed name as it is, in the order given.
    @Test func notesNameExercisesByTheirDisplayNames() throws {
        var mismatched: [String] = []
        for entry in ExerciseHowToCatalog.allEntries where WorkoutPlannerCopy.exerciseName(entry.name) != entry.displayName {
            mismatched.append(entry.name)
        }
        #expect(mismatched.isEmpty, "note names that are not the display name: \(mismatched)")
        #expect(WorkoutPlannerCopy.exerciseName("My odd lift") == "My odd lift")
        let squat = ExerciseHowToCatalog.displayName(for: "Back squat")
        let bench = ExerciseHowToCatalog.displayName(for: "Bench press")
        let list = WorkoutPlannerCopy.exerciseList(["Back squat", "My odd lift", "Bench press"])
        #expect(list == "\(squat), My odd lift, \(bench)")
        let budget = WorkoutSessionBudget.changeSummary([.accessory("Back squat"), .mainSet("Bench press")])
        #expect(budget == "left out \(squat); fewer sets of \(bench)")
        let lightened = WorkoutRecoveryGuard.lightenedNote(lifts: ["Back squat", "Bench press"])
        #expect(lightened.hasPrefix("One set fewer on \(squat), \(bench) — "))
        let calibration = WorkoutProgram.calibrationNote(kind: .submaximal, lift: "Bench press", sets: [], unit: .lb, addressing: .masculine)
        #expect(calibration.contains(bench))
    }

    /// The note builders draw names through ``WorkoutPlannerCopy/exerciseName(_:)`` and
    /// ``WorkoutPlannerCopy/exerciseList(_:)`` rather than joining or splicing frozen names themselves:
    /// the source pin that keeps a new list from slipping back to English names in another language.
    @Test func theNoteBuildersDrawNamesThroughTheCopyHelpers() throws {
        let drawing = ["WorkoutSessionBudget.swift", "WorkoutRecoveryGuard.swift", "WorkoutProgram+LoadNotes.swift"]
        for file in drawing {
            let source = Self.withoutCommentLines(try RepoRoot.source(Self.domainRoot + file))
            #expect(source.contains("WorkoutPlannerCopy.exercise"), "\(file) no longer draws exercise names")
            #expect(!source.contains(#".joined(separator: ", ")"#), "\(file) joins names itself; use WorkoutPlannerCopy.exerciseList")
        }
    }

    // MARK: - Frozen names

    /// The names a guided log is saved under, the rotation matches and the export carries stay
    /// byte-identical English.
    @Test func frozenPlannerNames() throws {
        let templates: [WorkoutSessionTemplate] = [
            WorkoutSessions.fullBodyA, WorkoutSessions.fullBodyB, WorkoutSessions.fullBodyC, WorkoutSessions.upper,
            WorkoutSessions.lower, WorkoutSessions.push, WorkoutSessions.pull, WorkoutSessions.legs,
            WorkoutSessions.chest, WorkoutSessions.back, WorkoutSessions.shoulders, WorkoutSessions.arms,
            WorkoutSessions.arnoldChestBack, WorkoutSessions.arnoldShouldersArms, WorkoutSessions.easyCardio,
            WorkoutSessions.intervals, WorkoutSessions.longCardio, WorkoutSessions.mobility,
            WorkoutSessions.sportConditioning,
        ]
        let titles = templates.map(\.title)
        #expect(titles == Self.frozenSessionTitles, "session titles are the guided logs' saved names: \(titles)")
        let times = [SessionTime.any, .morning, .midday, .evening].map(\.label)
        #expect(times == ["", "Morning", "Midday", "Evening"], "time labels are part of a saved session name")
        let splits = WorkoutSplitCatalog.all.map { "\($0.id)=\($0.name)" }
        #expect(splits == [
            "daily-move=Daily Movement", "full-body-2=Full Body ×2", "recovery-flow=Recovery Flow",
            "full-body-3=Full Body ×3", "upper-lower-full-3=Upper / Lower / Full", "upper-lower-4=Upper / Lower",
            "ppl-3=Push / Pull / Legs", "cardio-strength-4=Cardio + Strength", "sport-prep=Sport Prep",
            "ppl-ul-5=PPL + Upper / Lower", "ppl-6=Push / Pull / Legs ×2", "bro-5=Bro Split",
            "arnold-6=Arnold Split", "two-a-day=Two-a-Day Strength",
        ], "split names are the export's splitName: \(splits)")
        #expect(WorkoutLocation.fullGym.name == "Full gym")
        #expect(WorkoutLocation.home.name == "Home")
        let presets = LocationTemplate.all.map(\.name)
        #expect(presets == ["Full gym", "Hotel gym", "Apartment gym", "Home setup"], "a saved preset's stored name")
        let rest = WorkoutPlanningService.restDayPlan(locationName: "Full gym")
        let restSession = try #require(rest.sessions.first)
        #expect(rest.splitName == "Rest day")
        #expect(rest.dayTitle == "Rest")
        #expect(restSession.suggestion.name == "Gentle movement")
        #expect(restSession.suggestion.exercises == "Gentle stretching or an easy walk - 10 min")
    }

    /// Every frozen planner name has a display mapping, and in English it draws as its token.
    @Test func everyFrozenNameDrawsThroughItsMapping() {
        var problems: [String] = []
        for name in Self.allSessionNames() + ["Easy full body", "Move", "Rest", "Gentle movement"] {
            let drawn = WorkoutSessionNames.displayed(name)
            if drawn != name { problems.append("session \(name) → \(drawn ?? "nil")") }
        }
        for split in WorkoutSplitCatalog.all {
            if TrainingSplitNames.displayed(id: split.id) != split.name { problems.append("split \(split.id)") }
            for day in split.days where WorkoutSplitDayNames.displayed(day.title) != day.title {
                problems.append("day \(day.title)")
            }
        }
        if TrainingSplit.displayName(forName: "Rest day") != "Rest day" { problems.append("rest day") }
        for template in LocationTemplate.all {
            if template.displayName != template.name { problems.append("location \(template.name)") }
            if WorkoutLocationNames.subtitle(templateID: template.id) != template.subtitle { problems.append("subtitle \(template.id)") }
        }
        if WorkoutLocationNames.displayed("Home") != "Home" { problems.append("location Home") }
        for label in Self.allSlotLabels() where WorkoutSlotNames.drawn(label) != label || !Self.isSlotLabel(label) {
            problems.append("slot \(label)")
        }
        #expect(problems.isEmpty, "frozen names without an English-identical display mapping: \(problems)")
    }

    /// A row the guided flow logged draws its session name through the mapping and saves it back
    /// unchanged; the planner logs and matches the frozen name.
    @Test func guidedRowsKeepTheirFrozenNames() throws {
        let plan = WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: WorkoutSplitCatalog.cardioStrength4, rotationIndex: 0
        )
        let names = plan.sessions.map(\.suggestion.name)
        #expect(names == ["Morning · Easy cardio", "Evening · Upper"], "the logged names: \(names)")
        let session = try #require(plan.sessions.first)
        let logged = session.workout(intensity: .moderate, loggedFromGuidedSession: true)
        #expect(logged.name == "Morning · Easy cardio", "a guided log is saved under the frozen name")
        let drawn = WorkoutSessionNames.drawn(logged.name)
        #expect(logged.displayedName == drawn)
        #expect(session.displayedName == drawn)
        #expect(logged.savedName(editing: logged.displayedName) == logged.name)
        #expect(plan.displayedSplitName == WorkoutSplitCatalog.cardioStrength4.displayName)
        #expect(plan.displayedDayTitle == "Day 1")
        var typed = logged
        typed.loggedFromGuidedSession = nil
        #expect(typed.displayedName == "Morning · Easy cardio", "a hand-logged row draws as stored")
    }

    /// A built-in location draws localized and saves back under its stored name.
    @Test func builtInLocationsKeepTheirStoredNames() throws {
        let gym = WorkoutLocation.fullGym
        #expect(gym.displayedName == "Full gym")
        #expect(gym.savedName(editing: gym.displayedName) == "Full gym")
        #expect(gym.savedName(editing: "Garage") == "Garage")
        let renamed = WorkoutLocation(name: "Garage", ownedEquipment: [])
        #expect(renamed.displayedName == "Garage")
        let encoded = try JSONEncoder().encode(gym)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"name\":\"Full gym\""), "the stored name is unchanged: \(json)")
    }

    /// The plan text stays the frozen format the history parser and the minutes reader read, and
    /// every descriptor the planner writes has a display mapping.
    @Test func planTextStaysFrozenAndEveryDescriptorIsMapped() {
        let stretch = PrescribedExercise(name: "Butterfly stretch", sets: 1, reps: "30 s", role: .accessory,
                                         fromCatalog: true, block: .warmUp, holdSeconds: 30)
        let cool = PrescribedExercise(name: "Butterfly stretch", sets: 1, reps: "45 s", role: .accessory,
                                      fromCatalog: true, block: .coolDown, holdSeconds: 45)
        let text = WorkoutSessionBlocks.planText(for: [stretch, cool])
        #expect(text == "Warm-up stretch flow - 1 min\nCool-down stretches - 1 min")
        #expect(WorkoutProgram.descriptorMinutes(in: "Easy cardio - 20 min") == 20)
        let conditioned: [WorkoutSessionTemplate] = [
            WorkoutSessions.easyCardio, WorkoutSessions.intervals, WorkoutSessions.longCardio, WorkoutSessions.mobility,
        ]
        var lines = conditioned.compactMap(\.conditioning)
        lines += GoalType.allCases.map { WorkoutGoalStyle.style(for: $0, energy: .moderate, sport: "").conditioningLabel }
        lines += [
            WorkoutPlanningService.restDayMovementLine, "Full-body bodyweight circuit - 3 rounds",
            "Warm-up stretch flow - 9 min", "Cool-down stretches - 4 min", "Steady cardio - 30 min",
        ]
        let unmapped = lines.filter { !Self.isPlannerLine($0) }
        #expect(unmapped.isEmpty, "plan lines with no display mapping: \(unmapped)")
        let drawnSame = lines.filter { WorkoutPlanLine.displayed($0) != $0 }
        #expect(drawnSame.isEmpty, "English display differs from the frozen line: \(drawnSame)")
        let sport = WorkoutGoalStyle.style(for: .sportsPrep, energy: .moderate, sport: "basketball").conditioningLabel
        #expect(WorkoutPlanLine.displayed(sport) == sport)
        #expect(WorkoutPlanLine.displayed("Bench press - 3 x 8") == "Bench press - 3 x 8", "a lift line draws as stored")
    }

    /// Logs, exports, the AI path and HealthKit read the frozen names, never a display mapping.
    @Test func theFrozenPathsNeverReadTheDisplayMappings() throws {
        let frozenPaths = [
            "App/Fernlet/FernletStore.swift", "App/Fernlet/TrainerExportBuilder.swift",
            "App/Fernlet/DataExportBuilder.swift", "App/Fernlet/CoachExportPromptBuilder.swift",
            "App/Fernlet/WorkoutLoadContextBuilder.swift", "App/Fernlet/GuidedRunLoadLog.swift",
            "App/Fernlet/WorkoutRecentTrainingBuilder.swift",
            "FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift",
            "FernletKit/Sources/HealthKitGateway/WorkoutHealthKitSync.swift",
            "FernletKit/Sources/HealthKitGateway/HealthKitService.swift",
        ]
        let mappings = [
            "WorkoutSessionNames", "displayedSplitName", "displayedDayTitle", "WorkoutPlanLine", "WorkoutLocationNames",
            "WorkoutSlotNames", "WorkoutMeasurementEntry", "displaySubtitle", "displayedNotes", "completionNoteDisplay",
            ".displayedName", "TrainingSplitNames", "WorkoutSplitDayNames",
        ]
        var offenders: [String] = []
        for path in frozenPaths {
            let code = Self.withoutCommentLines(try RepoRoot.source(path))
            offenders += mappings.filter { code.contains($0) }.map { "\(path) reads \($0)" }
        }
        #expect(offenders.isEmpty, "a frozen path reads a display mapping: \(offenders)")
        let export = try RepoRoot.source("App/Fernlet/TrainerExportBuilder.swift")
        #expect(export.contains("splitName: split.name,"), "the export carries the frozen split name")
        #expect(export.contains("locationName: location.name,"), "the export carries the stored location name")
    }

    // MARK: - Metric distance and speed

    /// A distance typed in kilometres is stored in miles and reads back in kilometres; miles are as before.
    @Test func kilometresRoundTripThroughStoredMiles() throws {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        let stored = try #require(WorkoutMeasurementEntry.miles(fromEntry: "5", imperial: false))
        #expect(abs(stored - 5 / 1.609344) < 0.000_001, "stored in miles: \(stored)")
        #expect(WorkoutMeasurementEntry.entryText(miles: stored, imperial: false, locale: english) == "5")
        #expect(WorkoutMeasurementEntry.distanceText(miles: stored, imperial: false, locale: english) == "5 km")
        let comma = try #require(WorkoutMeasurementEntry.miles(fromEntry: "7,5", imperial: false))
        #expect(WorkoutMeasurementEntry.entryText(miles: comma, imperial: false, locale: german) == "7,5")
        let miles = try #require(WorkoutMeasurementEntry.miles(fromEntry: "3.1", imperial: true))
        #expect(miles == 3.1, "miles are stored as typed")
        #expect(WorkoutMeasurementEntry.entryText(miles: 3.1, imperial: true) == "3.1")
        #expect(WorkoutMeasurementEntry.distanceText(miles: 3.1, imperial: true, locale: english) == "3.1 mi")
        #expect(WorkoutMeasurementEntry.miles(fromEntry: "far", imperial: false) == nil)
    }

    /// A treadmill speed typed in km/h is stored as mph in the line, reopens in km/h, and re-saves the
    /// same line; an imperial line is unchanged.
    @Test func treadmillSpeedRoundTripsThroughStoredMph() throws {
        let english = Locale(identifier: "en_US")
        let walk = try #require(WorkoutExerciseCatalog.search("Treadmill walk").first)
        let entry = WorkoutExerciseEntry(exercise: walk, sets: "", reps: "", weight: "", speed: "9", incline: "2", details: "")
        let written = entry.summaryLine(imperial: false)
        #expect(written == "Treadmill walk 5.59 mph 2% incline", "the line stores mph: \(written)")
        let reopened = try #require(WorkoutSheetRules.exerciseEntries(from: written, imperial: false).first)
        #expect(reopened.speed == "9", "the field reads km/h: \(reopened.speed)")
        #expect(reopened.summaryLine(imperial: false) == written, "re-saving writes the same line")
        let shown = WorkoutMeasurementEntry.displayedSpeeds(in: written, imperial: false, locale: english)
        #expect(shown == "Treadmill walk 9 km/h 2% incline", "drawn in km/h: \(shown)")
        let imperial = entry.summaryLine(imperial: true)
        #expect(imperial == "Treadmill walk 9 mph 2% incline", "an imperial line is written as typed")
        #expect(WorkoutMeasurementEntry.displayedSpeeds(in: imperial, imperial: true) == imperial)
    }

    /// N9 (2026-10-20): distance and speed follow the system's measurement setting, as Apple Fitness
    /// does — the UK reads miles and mph, the US miles, metric kilometres and km/h — while loads keep
    /// pounds for the US system only.
    @Test func theUKReadsMilesAndMph() throws {
        let britain = Locale(identifier: "en_GB")
        #expect(britain.measurementSystem == .uk, "precondition: en_GB is the UK system")
        #expect(WorkoutMeasurementEntry.readsImperial(britain))
        #expect(WorkoutMeasurementEntry.readsImperial(Locale(identifier: "en_US")))
        #expect(!WorkoutMeasurementEntry.readsImperial(Locale(identifier: "de_DE")))
        #expect(!WorkoutMeasurementEntry.readsImperial(Locale(identifier: "en_AU")))
        #expect(!WorkoutMeasurementEntry.readsImperial(Locale(identifier: "fr_CA")))

        // The setting, not the region: a US-region device set to Metric reads kilometres, and one set
        // to the UK system reads miles.
        var metricUS = Locale.Components(identifier: "en_US")
        metricUS.measurementSystem = .metric
        #expect(!WorkoutMeasurementEntry.readsImperial(Locale(components: metricUS)))
        var ukSystem = Locale.Components(identifier: "fr_FR")
        ukSystem.measurementSystem = .uk
        #expect(WorkoutMeasurementEntry.readsImperial(Locale(components: ukSystem)))

        let readsMiles = WorkoutMeasurementEntry.readsImperial(britain)
        #expect(WorkoutMeasurementEntry.distanceText(miles: 3.1, imperial: readsMiles, locale: britain) == "3.1 mi")
        let line = "Treadmill walk 5.5 mph 2% incline"
        #expect(WorkoutMeasurementEntry.displayedSpeeds(in: line, imperial: readsMiles, locale: britain) == line)
        let stored = try #require(WorkoutMeasurementEntry.miles(fromEntry: "3.1", imperial: readsMiles))
        #expect(stored == 3.1, "a UK distance is typed and stored in miles")
        #expect(WorkoutMeasurementEntry.storedSpeed(fromEntry: "5.5", imperial: readsMiles) == "5.5")

        #expect(WorkoutLoadContextBuilder.defaultUnit(for: britain) == .kg, "a UK gym's loads stay in kilograms")
    }

    // MARK: - Helpers

    /// Every session name the split catalog can plan: a title, or a time label and a title.
    static func allSessionNames() -> [String] {
        var names: Set<String> = []
        for split in WorkoutSplitCatalog.all {
            for day in split.days {
                for session in day.sessions {
                    names.insert(session.time.label.isEmpty ? session.title : "\(session.time.label) · \(session.title)")
                }
            }
        }
        return names.sorted()
    }

    /// Every slot label the session templates use.
    static func allSlotLabels() -> [String] {
        var labels: Set<String> = [WorkoutProgram.variantSlotLabel]
        for split in WorkoutSplitCatalog.all {
            for day in split.days {
                for session in day.sessions { labels.formUnion(session.slots.map(\.label)) }
            }
        }
        return labels.sorted()
    }

    static func isSlotLabel(_ label: String) -> Bool {
        WorkoutSlotNames.movementLabel(label) != nil || WorkoutSlotNames.muscleLabel(label) != nil
    }

    /// Whether `line` is a plan-text descriptor ``WorkoutPlanLine`` maps.
    static func isPlannerLine(_ line: String) -> Bool {
        if WorkoutPlanLine.fixedLine(line) != nil { return true }
        guard let range = line.range(of: " - ") else { return false }
        let head = String(line[..<range.lowerBound])
        if head.hasSuffix(WorkoutPlanLine.sportSuffix) { return true }
        return WorkoutPlanLine.timedLine(head, minutes: 1) != nil
    }

    /// Whether an English literal in the planner source is a frozen token with a display mapping.
    static func isMappedToken(_ literal: String) -> Bool {
        WorkoutExerciseCatalog.exercise(named: literal) != nil
            || WorkoutSessionNames.displayTitle(literal) != nil
            || isSlotLabel(literal)
            || WorkoutSplitCatalog.all.contains { $0.name == literal }
            || WorkoutSplitDayNames.displayed(literal) != nil
            || WorkoutLocationNames.displayed(literal) != nil
            || LocationTemplate.all.contains { $0.subtitle == literal }
            || isPlannerLine(literal)
    }

    /// Whether a literal holds two words of letters ("Horizontal push"), i.e. reads as English.
    static func isWords(_ literal: String) -> Bool {
        literal.range(of: "[A-Za-z]+ [A-Za-z]+", options: .regularExpression) != nil
    }

    /// The top-level `strings` table of a catalog.
    static func catalogStrings(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url(path))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    /// Whether `key` carries an English value: a string unit, or a plural block with `one` and `other`.
    static func hasEnglish(_ strings: [String: Any], key: String) -> Bool {
        let english = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any]
        if let unit = english?["stringUnit"] as? [String: Any], unit["value"] is String { return true }
        return LocalizationBoundaryTests.carriesEnglishOneAndOtherPlural(strings, key: key)
    }

    /// The keys of every `String(localized: "<key>"` and `LocalizedStringResource("<key>"` in `source`
    /// (the second is how a line that describes the user is built for `AddressedCopy`).
    static func localizedKeys(in source: String) -> [String] {
        let pattern = #"(?:String\(localized:|LocalizedStringResource\()\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    /// `source` without its whole-line comments.
    static func withoutCommentLines(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The string literals of `source` outside whole-line comments and outside `String(localized:)`
    /// and `LocalizedStringResource(…)` calls (each a catalog entry: the second is how a line that
    /// describes the user is built for `AddressedCopy`), each interpolation replaced by "1".
    static func bareLiterals(in source: String) -> [String] {
        let chars = Array(withoutCommentLines(source))
        let call = Array("String(localized:")
        let resource = Array("LocalizedStringResource(")
        var literals: [String] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "S", index + call.count <= chars.count, Array(chars[index..<(index + call.count)]) == call {
                // `String(` is six characters, so the call's `(` sits at index + 6.
                index = endOfCall(chars, from: index + 6)
                continue
            }
            if chars[index] == "L", index + resource.count <= chars.count,
               Array(chars[index..<(index + resource.count)]) == resource {
                index = endOfCall(chars, from: index + resource.count - 1)
                continue
            }
            if chars[index] == "\"" {
                let end = endOfLiteral(chars, from: index)
                let body = String(chars[(index + 1)..<max(index + 1, end - 1)])
                literals.append(replacingInterpolations(body))
                index = end
                continue
            }
            index += 1
        }
        return literals
    }

    /// Index just past the call whose `(` is at `open`, skipping string literals inside it.
    static func endOfCall(_ chars: [Character], from open: Int) -> Int {
        var depth = 0
        var index = open
        while index < chars.count {
            switch chars[index] {
            case "\"": index = endOfLiteral(chars, from: index); continue
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index + 1 }
            default: break
            }
            index += 1
        }
        return chars.count
    }

    /// Index just past the string literal opening at `start`, skipping escapes and interpolations.
    static func endOfLiteral(_ chars: [Character], from start: Int) -> Int {
        var index = start + 1
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "(" {
                index = endOfInterpolation(chars, from: index + 2)
                continue
            }
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "\"" || chars[index] == "\n" { return index + 1 }
            index += 1
        }
        return chars.count
    }

    /// Index just past the `)` closing an interpolation whose body starts at `start`.
    static func endOfInterpolation(_ chars: [Character], from start: Int) -> Int {
        var depth = 1
        var index = start
        while index < chars.count, depth > 0 {
            if chars[index] == "\"" {
                index += 1
                while index < chars.count, chars[index] != "\"" { index += chars[index] == "\\" ? 2 : 1 }
            } else if chars[index] == "(" {
                depth += 1
            } else if chars[index] == ")" {
                depth -= 1
            }
            index += 1
        }
        return index
    }

    /// `body` with each `\(…)` replaced by "1".
    static func replacingInterpolations(_ body: String) -> String {
        let chars = Array(body)
        var result = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "(" {
                result += "1"
                index = endOfInterpolation(chars, from: index + 2)
                continue
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }
}

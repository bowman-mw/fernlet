import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The bundled exercise how-to text and the display-name lookup (comparison report idea 3).
///
/// Three things are pinned here. Every catalog row has a complete entry whose strings really are in
/// the domain String Catalog. Drawing a name through the lookup never reaches what is stored: the
/// plan text, the logged lines, the progression keys and the history rollup keep the FROZEN catalog
/// name even when the drawn name is a translation. And the how-to sheet is laid out in the reading
/// order VoiceOver follows, behind a labelled control on both of its entry points.
@MainActor
struct ExerciseHowToTests {

    static let domainCatalogPath = "FernletKit/Sources/FernletDomainModel/Localizable.xcstrings"

    /// The bundled catalog's rows, read from the repository rather than the host bundle, so the
    /// coverage check cannot pass against an empty catalog.
    static func catalogRows() throws -> [ExerciseTarget] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/WorkoutExercises.json"))
        return try JSONDecoder().decode([ExerciseTarget].self, from: data)
    }

    /// The domain String Catalog's `strings` table.
    static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url(domainCatalogPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    /// The catalog's English value for `key`, or nil when the key or its `en` unit is missing.
    static func englishValue(_ strings: [String: Any], _ key: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    /// The key stem a frozen name gets: apostrophes dropped, words joined in lower camel case.
    static func keyStem(for name: String) -> String {
        let words = name.replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard let first = words.first else { return "" }
        let rest = words.dropFirst().map { (word: String) -> String in
            word.prefix(1).uppercased() + String(word.dropFirst())
        }
        return first.lowercased() + rest.joined()
    }

    // MARK: - Coverage

    @Test func everyCatalogRowHasThreeToFiveCuesOneMistakeAndOneEasierVersion() throws {
        let rows = try Self.catalogRows()
        #expect(rows.count == 118, "the catalog changed size — write how-to text for any new row")
        for row in rows {
            let entry = try #require(ExerciseHowToCatalog.entry(for: row.name), "\(row.name) has no how-to entry")
            #expect(entry.name == row.name)
            #expect((ExerciseHowToCatalog.minCues...ExerciseHowToCatalog.maxCues).contains(entry.cues.count),
                    "\(row.name) has \(entry.cues.count) cues")
            #expect(entry.cues.allSatisfy { !$0.isEmpty }, "\(row.name) has an empty cue")
            #expect(!entry.mistake.isEmpty, "\(row.name) has no common mistake")
            #expect(!entry.easier.isEmpty, "\(row.name) has no easier version")
        }
        let entries = ExerciseHowToCatalog.allEntries
        #expect(entries.count == rows.count, "an entry exists for a name the catalog does not have, or twice")
        #expect(Set(entries.map(\.name)) == Set(rows.map(\.name)))
        #expect(Set(entries.map(\.keyStem)).count == entries.count, "two entries share a key stem")
    }

    @Test func everyEntrysStringsAreInTheDomainCatalogUnderItsKeyStem() throws {
        let strings = try Self.catalogStrings()
        #expect(!strings.isEmpty, "\(Self.domainCatalogPath) parsed to zero keys")
        for entry in ExerciseHowToCatalog.allEntries {
            #expect(entry.keyStem == Self.keyStem(for: entry.name), "\(entry.name)'s key stem is \(entry.keyStem)")
            let prefix = "exercise.\(entry.keyStem)."
            var expected = [(prefix + "name", entry.displayName)]
            expected += entry.cues.enumerated().map { (prefix + "cue\($0.offset + 1)", $0.element) }
            expected += [(prefix + "mistake", entry.mistake), (prefix + "easier", entry.easier)]
            for (key, value) in expected {
                #expect(Self.englishValue(strings, key) == value,
                        "\(key) is missing from the domain catalog or differs from the code — re-run Scripts/sync-string-catalogs.sh")
            }
            #expect(strings[prefix + "cue\(entry.cues.count + 1)"] == nil, "\(entry.name) has a stray cue key")
        }
        let nameKeys = strings.keys.filter { $0.hasPrefix("exercise.") && $0.hasSuffix(".name") }
        #expect(nameKeys.count == ExerciseHowToCatalog.allEntries.count, "the catalog holds an orphaned exercise name")
    }

    /// The English text keeps to the brief: short imperative cues, and a stretch or a timed hold says
    /// where it is felt and how to breathe. Read from the catalog, which is what a translator gets.
    @Test func cuesAreShortAndStretchesAndHoldsSayWhereItIsFeltAndHowToBreathe() throws {
        let strings = try Self.catalogStrings()
        for row in try Self.catalogRows() {
            let entry = try #require(ExerciseHowToCatalog.entry(for: row.name))
            let cues = entry.cues.indices.compactMap {
                Self.englishValue(strings, "exercise.\(entry.keyStem).cue\($0 + 1)")
            }
            #expect(cues.count == entry.cues.count)
            for cue in cues {
                #expect(cue.split(separator: " ").count <= 12, "\(row.name): '\(cue)' runs past 12 words")
            }
            guard row.modality == .mobility || row.measure == .seconds else { continue }
            let joined = cues.joined(separator: " ").lowercased()
            #expect(joined.contains("feel"), "\(row.name) never says where it is felt")
            #expect(joined.contains("breath"), "\(row.name) never says how to breathe")
        }
    }

    // MARK: - The display lookup

    @Test func theDisplayNameIsTheFrozenNameInEnglishAndOtherNamesDrawAsStored() throws {
        for row in try Self.catalogRows() {
            #expect(ExerciseHowToCatalog.displayName(for: row.name) == row.name)
            #expect(row.displayName == row.name)
        }
        // Exact match only, like StoredWorkoutName: typed text and custom exercises draw as stored.
        #expect(ExerciseHowToCatalog.displayName(for: "bench press") == "bench press")
        #expect(ExerciseHowToCatalog.entry(for: "bench press") == nil)
        #expect(ExerciseHowToCatalog.displayName(for: "Zercher squat") == "Zercher squat")
        #expect(ExerciseHowToCatalog.entry(for: "") == nil)
        #expect(ExerciseHowToCatalog.displayName(for: "") == "")
    }

    @Test func thePlanLineKeepsTheFrozenNameAndOnlyTheDrawnLineUsesTheDisplayName() {
        for entry in ExerciseHowToCatalog.allEntries {
            let step = PrescribedExercise(name: entry.name, sets: 3, reps: "8-12", role: .main, fromCatalog: true)
            #expect(step.line == "\(entry.name) - 3 x 8-12")
            #expect(step.displayLine == "\(entry.displayName) - 3 x 8-12")
            #expect(step.displayName == entry.displayName)
        }
        let hold = PrescribedExercise(name: "Low lunge stretch", sets: 1, reps: "20 s", role: .accessory,
                                      fromCatalog: true, block: .warmUp, holdSeconds: 20, side: .left)
        #expect(hold.line == "Low lunge stretch (left) - 20 s")
        #expect(hold.displayLine == hold.line, "in English the drawn line is the stored one")
        let descriptor = PrescribedExercise(name: "Easy cardio - 20 min", sets: 0, reps: "", role: .accessory,
                                            fromCatalog: false)
        #expect(descriptor.displayLine == "Easy cardio - 20 min")
    }

    // MARK: - Frozen names in logs and exports

    func translatedBench() -> GuidedWorkoutRunState {
        let weight = WeightPrescription(low: 95, high: 110, suggested: 100, step: 5, unit: .lb, confidence: .low)
        let bench = PrescribedExercise(
            name: "Bench press", sets: 3, reps: "8", role: .main, fromCatalog: true,
            guidance: LoadGuidance(targetReps: 8, prescription: weight, equipment: .barbell, unit: .lb)
        )
        let row = PrescribedExercise(name: "Barbell row", sets: 2, reps: "10", role: .accessory, fromCatalog: true)
        let exercises = [(bench, "Press de banca"), (row, "Remo con barra")].map { step, drawn in
            GuidedWorkoutRunState.Exercise(
                id: step.id, name: step.name, sets: step.sets, reps: step.reps, roleRaw: "main",
                fromCatalog: true, restSeconds: 90, blockRaw: step.block.rawValue,
                tracking: GuidedRunLoadLog.tracking(for: step), displayName: drawn
            )
        }
        return GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate",
                                     title: "Push", suggestionExercisesText: "", suggestionNotes: "",
                                     sessionKindRaw: "strength", exercises: exercises)
    }

    /// A run whose drawn names are a translation still logs, and records results under, the frozen
    /// names: the Live Activity shows the drawn one, the log never does.
    @Test func aTranslatedRunDrawsItsDisplayNamesButLogsTheFrozenOnes() throws {
        var state = translatedBench()
        #expect(state.contentState.exerciseName == "Press de banca")
        #expect(state.exercises.map(\.displayedName) == ["Press de banca", "Remo con barra"])
        state.selectWeight(105, forExercise: state.exercises[0].id)
        let log = try #require(GuidedRunLoadLog.log(for: state))
        #expect(log.text.contains("Bench press - 3 x 8 @ 105 lb"))
        #expect(log.text.contains("Barbell row - 2 x 10"))
        #expect(!log.text.contains("Press de banca") && !log.text.contains("Remo con barra"))
        #expect(log.results.map(\.name) == ["Bench press"])

        var moved = state
        moved.exerciseIndex = 1
        #expect(moved.contentState.exerciseName == "Remo con barra")
        // A run persisted before display names existed draws its frozen name.
        var legacy = state
        legacy.exercises[0].displayName = nil
        #expect(legacy.contentState.exerciseName == "Bench press")
    }

    /// The spoken transition names the next exercise as drawn.
    @Test func theSpokenTransitionUsesTheDrawnName() {
        var before = translatedBench()
        before.exercises[0].sets = 1
        var after = before
        after.markSetDone(now: Date())
        let sentence = GuidedRunAnnouncement.spoken(from: before, to: after).map { String(localized: $0.sentence) }
        #expect(sentence?.contains("Remo con barra") == true)
        #expect(sentence?.contains("Barbell row") == false)
    }

    /// A persisted run with no display name still decodes (an older build wrote it), and one with a
    /// display name round-trips it.
    @Test func theRunStatesDisplayNameIsAnOptionalAdditiveField() throws {
        let state = translatedBench()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GuidedWorkoutRunState.self, from: data)
        #expect(decoded.exercises.map(\.displayName) == ["Press de banca", "Remo con barra"])

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exercises = try #require(object["exercises"] as? [[String: Any]])
        object["exercises"] = exercises.map { $0.filter { $0.key != "displayName" } }
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let older = try JSONDecoder().decode(GuidedWorkoutRunState.self, from: stripped)
        #expect(older.exercises.map(\.displayName) == [nil, nil])
        #expect(older.exercises.map(\.displayedName) == ["Bench press", "Barbell row"])
    }

    /// The frozen-name paths never call the display lookup: the log builder, the plan text, the
    /// history rollup and export, the planner, the AI adjuster's prompt and the coach-plan wire.
    @Test func theLoggingExportAndPromptPathsNeverReadTheDisplayLookup() throws {
        let frozenPaths = [
            "App/Fernlet/GuidedRunLoadLog.swift",
            "App/Fernlet/TrainerExportBuilder.swift",
            "App/Fernlet/WorkoutPlanningService.swift",
            "App/Fernlet/WorkoutLoadContextBuilder.swift",
            "FernletKit/Sources/FernletDomainModel/WorkoutSessionBlocks.swift",
            "FernletKit/Sources/FernletDomainModel/CoachPlan.swift",
            "FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift",
        ]
        for path in frozenPaths {
            let source = try RepoRoot.source(path)
            for needle in ["ExerciseHowToCatalog", ".displayedName", ".displayLine"] {
                #expect(!source.contains(needle), "\(path) reads `\(needle)` — logs, exports and prompts keep the frozen name")
            }
        }
    }

    /// Every site that DRAWS an exercise name reads the lookup. In English the display name is the
    /// frozen name, so pointing one back at `name` passes every other test and shows up only on a
    /// translated device.
    @Test func theDrawnExerciseNameSitesReadTheDisplayLookup() throws {
        let sites: [(path: String, needle: String, count: Int, what: String)] = [
            ("App/Fernlet/GuidedWorkout.swift", "Text(verbatim: exercise.displayedName)", 3,
             "the runner's exercise title, its resting Next up and its Up next list"),
            ("App/Fernlet/GuidedTimedRun.swift", "exercise.displayName ?? exercise.name", 1,
             "the runner's Up next rotor entry (through GuidedSegmentWords.upNextName)"),
            ("App/Fernlet/GuidedWorkout.swift", "writtenLines[exercise.id] ?? exercise.displayLine", 1,
             "the runner's Ready list (a planned run's own written line first)"),
            ("App/Fernlet/TaskConfirmations.swift", "\\(exercise.displayedName)", 5, "the spoken transitions"),
            ("App/FernletWidgets/GuidedWorkoutRunState.swift", "exerciseName: currentExercise?.displayedName", 1,
             "the Live Activity and Dynamic Island"),
            ("App/Fernlet/FernletStore.swift", "displayName: pe.displayName", 1, "the name baked into a new run"),
            ("App/Fernlet/GuidedWorkoutEditorSheet.swift", "Text(verbatim: row.displayName)", 1, "the editor's card title"),
            ("App/Fernlet/GuidedWorkoutEditorSheet.swift", "exerciseName: row.displayName", 1, "the editor's move and remove labels"),
            ("App/Fernlet/GuidedWorkoutLoadViews.swift", "previous.displayedName", 1, "the Edit reps for… button"),
            ("App/Fernlet/GuidedWorkoutLoadViews.swift", "Text(verbatim: exercise.displayedName)", 1, "the reps editor's subtitle"),
            ("App/Fernlet/MoveView.swift", "Text(verbatim: exercise.displayName)", 4,
             "the plan rows, the picker's result rows and their Voice Control name"),
            ("App/Fernlet/MoveView.swift", "Text(verbatim: entry.exercise.displayName)", 2, "the Log sheet's added and planned rows"),
            ("App/Fernlet/MoveView.swift", "Remove \\(entry.exercise.displayName)", 2, "their remove labels"),
            ("App/Fernlet/MoveView.swift", "ExerciseHowToCatalog.displayName(for: entry.name)", 2, "the Recent chips"),
            ("App/Fernlet/ExerciseHistoryView.swift", "Text(verbatim: row.displayName)", 1, "the Exercise history rows"),
        ]
        for site in sites {
            let found = try RepoRoot.source(site.path).components(separatedBy: site.needle).count - 1
            #expect(found == site.count,
                    "\(site.path) has `\(site.needle)` \(found) time(s), expected \(site.count): \(site.what). If it moved, re-point this pin.")
        }
    }

    // MARK: - The how-to sheet

    @Test func theSheetsFactsNameTheMainMusclesAndEquipment() throws {
        let rows = try Self.catalogRows()
        let split = try #require(rows.first { $0.name == "Bulgarian split squat" })
        #expect(ExerciseHowToFacts.muscles(of: split) == ["Glutes", "Quads"].formatted(.list(type: .and)))
        #expect(ExerciseHowToFacts.equipment(of: split) == "Dumbbell")
        let goblet = try #require(rows.first { $0.name == "Goblet squat" })
        #expect(ExerciseHowToFacts.equipment(of: goblet)?.contains("Kettlebell") == true)
        let wheel = try #require(rows.first { $0.name == "Ab wheel" })
        #expect(ExerciseHowToFacts.equipment(of: wheel) == nil, "no equipment line rather than 'None'")
    }

    /// VoiceOver reads the sheet in layout order, so the layout order IS the reading order: name,
    /// media slot, facts, the numbered cues, the mistake, the easier version, the safety line. The
    /// headings are `SectionLabel`s (header trait), and both entry points present it from a labelled
    /// button with short Voice Control names.
    @Test func theSheetReadsInOrderBehindALabelledButtonOnBothEntryPoints() throws {
        let sheet = try RepoRoot.source("App/Fernlet/ExerciseHowToSheet.swift")
        let order = [
            "title: Text(verbatim: ExerciseHowToCatalog.displayName(for: exerciseName))",
            "ExerciseDemonstrationSlot(exerciseName: exerciseName, sex: sex)",
            "ExerciseHowToFacts(target:",
            "ExerciseHowToSteps(cues: entry.cues)",
            "ExerciseHowToNote(title: \"Common mistake\"",
            "ExerciseHowToNote(title: \"Easier version\"",
            "ExerciseHowToSafetyLine()",
        ]
        let offsets = order.map { sheet.range(of: $0)?.lowerBound }
        #expect(offsets.allSatisfy { $0 != nil }, "a section of the sheet is missing: \(zip(order, offsets).filter { $0.1 == nil }.map(\.0))")
        let found = offsets.compactMap { $0 }
        #expect(found == found.sorted(), "the sheet's sections are out of reading order")
        #expect(sheet.contains("SectionLabel(\"How to do it\")") && sheet.contains("SectionLabel(title)"))
        #expect(sheet.contains("Text(\"Stop if you feel sharp pain.\")"))
        #expect(sheet.contains(".fernletIconButton(\"How to do \\(ExerciseHowToCatalog.displayName(for: exerciseName))\")"))
        #expect(sheet.contains(".accessibilityInputLabels([Text(\"Info\"), Text(\"How to\")])"))
        #expect(sheet.contains(".uxScreenAnchor(\"sheet.exerciseHowTo\")"))
        for path in ["App/Fernlet/GuidedWorkout.swift", "App/Fernlet/MoveView.swift"] {
            let source = try RepoRoot.source(path)
            #expect(source.contains("ExerciseHowToButton(exerciseName: exercise.name)"), "\(path) lost its how-to button")
            #expect(source.components(separatedBy: ".exerciseHowToSheet($howTo").count - 1 == 1,
                    "\(path) presents the how-to sheet from exactly one place")
            #expect(source.contains(".exerciseHowToSheet($howTo, sex: store.effectiveUserProfile.sex)"),
                    "\(path) must pass the profile's sex, which picks the demonstration's version")
        }
    }

    // MARK: - The es/fr/de drafts stay dormant

    /// The domain catalog carries Spanish, French and German drafts of every exercise string, all
    /// marked `needs_review` and none reviewed yet. They stay out of sight only while the app itself
    /// ships English alone: a package's resource bundle resolves to the language the MAIN bundle
    /// resolved to, so with no non-English entry in any app-target catalog (no `es.lproj`, `fr.lproj`
    /// or `de.lproj` in the app or an extension) and no `CFBundleAllowMixedLocalizations`, a device
    /// set to Spanish still draws the English defaults. Either change turns the drafts on in that
    /// language, unreviewed, beside English everywhere else. Turning a language on app-wide is a later
    /// phase (Docs/Localization-Plan-2026-07-19.md §4): have the drafts reviewed first, then update
    /// this test.
    @Test func theDraftTranslationsStayDormantWhileTheAppShipsOnlyEnglish() throws {
        let catalogs = Self.appFiles { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 6, "found \(catalogs.count) app-target catalogs; the scan lost its root")
        for catalog in catalogs {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
            let strings = json?["strings"] as? [String: Any] ?? [:]
            var languages = Set<String>()
            for case let entry as [String: Any] in strings.values {
                languages.formUnion((entry["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
            }
            let others = languages.subtracting(["en"]).sorted()
            #expect(others.isEmpty, "\(catalog.path) carries \(others): that compiles a lproj into an app bundle and turns the unreviewed exercise drafts on in that language")
        }
        let plists = Self.appFiles { $0.lastPathComponent == "Info.plist" }
        #expect(plists.count >= 4, "found \(plists.count) app-target Info.plists; the scan lost its root")
        for path in plists {
            let data = try Data(contentsOf: path)
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let mixed = plist["CFBundleAllowMixedLocalizations"] != nil
            #expect(!mixed, "\(path.path) sets CFBundleAllowMixedLocalizations, so package bundles follow the device language")
        }
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        #expect(!project.contains("AllowMixedLocalizations"), "a target's build settings allow mixed localizations")
        // What this protects is really there: the drafts are in the domain catalog.
        let domain = try Self.catalogStrings()
        let bench = (domain["exercise.benchPress.name"] as? [String: Any])?["localizations"] as? [String: Any]
        let benchLanguages = Set(bench?.keys.map { $0 } ?? [])
        #expect(benchLanguages.isSuperset(of: ["de", "es", "fr"]), "the exercise drafts are gone from the domain catalog")
    }

    /// The files under `App/` that `matches` accepts, skipping build output, package checkouts and
    /// per-user Xcode state (an `App/build` DerivedData holds other packages' catalogs and plists).
    static func appFiles(_ matches: (URL) -> Bool) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: RepoRoot.url("App"), includingPropertiesForKeys: nil) else {
            return []
        }
        let skipped: Set<String> = ["build", "DerivedData", "SourcePackages", ".build", "xcuserdata"]
        var found: [URL] = []
        while let url = walker.nextObject() as? URL {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
            } else if matches(url) {
                found.append(url)
            }
        }
        return found
    }
}

/// A guided run started from the store bakes in each step's drawn name, and finishing it logs and
/// counts progression under the frozen name even when the drawn name is a translation.
@MainActor
@Suite(.serialized)
struct ExerciseHowToStoreTests {
    private let appGroupDirectory = uniqueAppGroupDirectory()

    @Test func aRunLogsAndProgressesUnderTheFrozenNameWhateverItDraws() throws {
        let store = makeTestStore(appGroupDirectory: appGroupDirectory)
        store.clearGuidedRun()
        let step = PrescribedExercise(name: "Bench press", sets: 1, reps: "5", role: .main, fromCatalog: true)
        let session = WorkoutProgram.SessionSuggestion(
            title: "Quick", timeLabel: "", kind: .strength, exercises: [step],
            suggestion: WorkoutSuggestion(name: "Quick", exercises: step.line, notes: "")
        )
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let plan = WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [session], droppedSlots: [],
                                          locationName: "Test")
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
        #expect(store.startGuidedRun(session) == true)

        let run = try #require(store.guidedRunState)
        #expect(run.exercises.first?.displayName == ExerciseHowToCatalog.displayName(for: "Bench press"))
        // Stand in for a translated device: the drawn name changes, the stored one must not.
        store.editGuidedRun { $0.exercises[0].displayName = "Press de banca" }
        #expect(store.guidedRunState?.contentState.exerciseName == "Press de banca")

        store.guidedMarkSetDone()

        let logged = try #require(store.day.workouts.first { $0.name == "Quick" && $0.loggedFromGuidedSession == true })
        #expect(logged.exercises.contains("Bench press - 1 x 5"))
        #expect(!logged.exercises.contains("Press de banca"))
        #expect(store.settings.workoutProgression["Bench press"] == 1)
        #expect(store.settings.workoutProgression["Press de banca"] == nil)
        let history = FernletStore.rollUpExerciseHistory(days: [store.day]).entries
        #expect(history.map(\.name).contains("Bench press"))
        #expect(!history.map(\.name).contains("Press de banca"))
        store.clearGuidedRun()
    }
}

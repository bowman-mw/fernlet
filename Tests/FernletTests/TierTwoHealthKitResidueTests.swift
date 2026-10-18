//
//  TierTwoHealthKitResidueTests.swift
//  FernletTests
//
//  Tracker §2.6 (2026-10-18): Tier-2 reads HealthKit-stripped days.
//
//  Since 2026-09-23 the storage strip keeps every value read from HealthKit out of the synced rows,
//  and the repositories' post-save Tier-2 refresh reads those rows, so `TierTwoMemoryEngine` stopped
//  seeing Apple Health workouts and sleep, and every day whose only content was HealthKit's. These
//  cells pin the fix: the window the device-local refresh reads is the stripped window with this
//  device's HealthKit residue put back, which is the window as it read before the strip.
//

import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
@testable import LocalPersistence
@testable import Fernlet

/// Pins that a stripped day plus its device-local HealthKit residue gives `TierTwoMemoryEngine` the
/// same inputs, and so the same verdicts, as the day before the strip — and that the app installs the
/// restoring refresh on the Core Data repository it actually saves through.
@MainActor
@Suite(.serialized)
struct TierTwoHealthKitResidueTests {

    // MARK: - Fixtures

    private static let strength = FitnessGoal(type: .strength, goal: "Get stronger", timeframe: "8 weeks",
                                              metric: "sessions")

    /// A workout imported from Apple Health (a Health sample Fernlet did not author).
    private static func importedWorkout(_ name: String) -> Workout {
        Workout(id: UUID(), name: name, type: .cardio, mode: .activity, exercises: "", rpe: nil, notes: "",
                duration: 30, distanceMiles: 2, activeEnergyKcal: 150, healthKitUUID: UUID(), intensity: .light)
    }

    /// A workout the user logged in Fernlet: user-authored, so it stays on the synced row.
    private static func loggedWorkout() -> Workout {
        Workout(name: "Upper", type: .upper, exercises: "DB row 3x10", rpe: 7, notes: "steady", duration: 35,
                intensity: .moderate)
    }

    private static func meal() -> Meal {
        Meal(name: "Oats", mealType: .breakfast, macros: Macros(protein: 12, carbs: 40, fat: 6), quality: .good,
             confidence: "Manual", note: "", source: "Manual")
    }

    /// HealthKit's context for a night of `hours` sleep, with the marker that says the day's sleep
    /// hours are HealthKit's.
    private static func sleepContext(_ hours: Double) -> HealthDailyContext {
        HealthDailyContext(syncedAt: Date(timeIntervalSince1970: 1_790_000_000),
                           body: HealthBodyContext(sleepHours: hours), healthKitSleepLogHours: hours)
    }

    /// Six days as they read BEFORE the strip, the way HealthKit sync and the user built them.
    private static func daysBeforeTheStrip() -> [FernletDay] {
        [
            // User content plus an Apple Health walk and HealthKit's sleep.
            FernletDay(date: "2026-10-01", meals: [meal()], workouts: [importedWorkout("Morning walk")],
                       sleep: SleepLog(hours: 7.5, quality: .ok, note: ""), healthContext: sleepContext(7.5)),
            // Only an Apple Health workout: the strip leaves nothing, so no row is written.
            FernletDay(date: "2026-10-02", workouts: [importedWorkout("Evening run")]),
            // Only HealthKit's sleep: likewise no row.
            FernletDay(date: "2026-10-03", sleep: SleepLog(hours: 6.25, quality: .ok, note: ""),
                       healthContext: sleepContext(6.25)),
            // Only user content.
            FernletDay(date: "2026-10-04", meals: [meal()]),
            // HealthKit's bare sync stamp and nothing else: no logged content, so never a row at all.
            FernletDay(date: "2026-10-05", healthContext: HealthDailyContext(syncedAt: Date(timeIntervalSince1970: 1_790_000_000))),
            // A Fernlet-logged workout and a meal: survives the strip whole.
            FernletDay(date: "2026-10-06", meals: [meal()], workouts: [loggedWorkout()])
        ]
    }

    /// The window a repository built before the strip: every day with logged content, oldest-first.
    private static func windowBeforeTheStrip() -> [(String, FernletDay)] {
        daysBeforeTheStrip().filter(\.hasLoggedContent).map { ($0.date, $0) }
    }

    /// The window a repository builds now (stripped days; a day the strip emptied writes no row), and
    /// the residue this device kept for each day.
    private static func strippedWindowAndResidues() -> ([(String, FernletDay)], [String: DeviceHealthResidue]) {
        let days = daysBeforeTheStrip()
        let rows = days.map { $0.strippingHealthKitValues() }.filter(\.hasLoggedContent).map { ($0.date, $0) }
        var residues: [String: DeviceHealthResidue] = [:]
        for day in days {
            if let residue = day.healthKitResidue { residues[day.date] = residue }
        }
        return (rows, residues)
    }

    /// One day as `TierTwoMemoryEngine` reads it: the fields every category counts.
    private struct EngineInput: Equatable {
        let dateKey: String
        let workoutCount: Int
        let hasSleep: Bool
        let mealCount: Int
        let journalCount: Int
    }

    private static func engineInputs(_ window: [(String, FernletDay)]) -> [EngineInput] {
        window.map { key, day in
            EngineInput(dateKey: key, workoutCount: day.workouts.count, hasSleep: day.sleep != nil,
                        mealCount: day.meals.count, journalCount: day.journals.count)
        }
    }

    /// A verdict without its minted id and date, so two runs of the engine can be compared.
    private struct Verdict: Equatable {
        let category: String
        let state: String
        let evidence: String
        let confidence: String
        let dataWindowDays: Int?
    }

    private static func verdicts(_ window: [(String, FernletDay)]) -> [Verdict] {
        TierTwoMemoryEngine.updateInferences(existing: [], from: window, goals: [strength])
            .map { Verdict(category: $0.category, state: $0.state, evidence: $0.evidence,
                           confidence: $0.confidence, dataWindowDays: $0.dataWindowDays) }
            .sorted { $0.category < $1.category }
    }

    // MARK: - The restored window

    /// The headline cell: the stripped window plus this device's residue gives the engine exactly the
    /// inputs, and so exactly the verdicts, it had before the strip. The stripped window alone does
    /// not — that is the gap this closes.
    @Test func aStrippedWindowPlusItsResidueGivesTheEngineThePreStripInputs() {
        let before = Self.windowBeforeTheStrip()
        let (rows, residues) = Self.strippedWindowAndResidues()
        let restored = TierTwoMemoryStore.deviceWindow(restoringHealthKitTo: rows, from: residues)

        #expect(Self.engineInputs(restored) == Self.engineInputs(before))
        #expect(Self.verdicts(restored) == Self.verdicts(before))
        #expect(!Self.verdicts(before).isEmpty, "precondition: the window is long enough to judge")
        // Without the residue the engine sees two fewer days and one Apple Health walk fewer.
        #expect(Self.engineInputs(rows) != Self.engineInputs(before))
        #expect(Self.verdicts(rows) != Self.verdicts(before))
    }

    /// A residue whose day has no logged content (HealthKit's bare sync stamp) never joins the
    /// window: such a day never had a row before the strip either, and counting it would lower every
    /// rate the engine computes.
    @Test func aResidueDayWithNoLoggedContentStaysOutOfTheWindow() {
        let (rows, residues) = Self.strippedWindowAndResidues()
        #expect(residues["2026-10-05"] != nil, "precondition: the bare stamp is kept on this device")
        let restored = TierTwoMemoryStore.deviceWindow(restoringHealthKitTo: rows, from: residues)
        #expect(!restored.map(\.0).contains("2026-10-05"))
    }

    /// The restored window keeps the repository's bound: the newest `limit` days, oldest-first, the
    /// residue-only days competing for the places like any row.
    @Test func theRestoredWindowKeepsTheNewestDaysOldestFirst() {
        let rows = ["2026-10-02", "2026-10-03", "2026-10-04"].map { ($0, FernletDay(date: $0, meals: [Self.meal()])) }
        let residues = [
            "2026-10-01": DeviceHealthResidue(context: nil, importedWorkouts: [Self.importedWorkout("Old walk")]),
            "2026-10-05": DeviceHealthResidue(context: nil, importedWorkouts: [Self.importedWorkout("New walk")])
        ]
        let restored = TierTwoMemoryStore.deviceWindow(restoringHealthKitTo: rows, from: residues, limit: 3)
        #expect(restored.map(\.0) == ["2026-10-03", "2026-10-04", "2026-10-05"])
        #expect(restored.last?.1.workouts.map(\.name) == ["New walk"])
    }

    /// With no residue on this device (HealthKit off, or another device) the window is the
    /// repository's own, untouched.
    @Test func noResidueLeavesTheRepositoryWindowAsItIs() {
        let (rows, _) = Self.strippedWindowAndResidues()
        let restored = TierTwoMemoryStore.deviceWindow(restoringHealthKitTo: rows, from: [:])
        #expect(Self.engineInputs(restored) == Self.engineInputs(rows))
    }

    // MARK: - The app's wiring

    /// The app installs the restoring refresh on the Core Data repository it saves through, so a save
    /// refreshes the device-local sidecar from Apple Health workouts that exist on this device only —
    /// while the synced rows still carry none of them.
    @Test func aSaveThroughTheAppsRepositoryReadsThisDevicesResidue() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let built = makeTestStoreWithRepositories(date: try #require(FernletDate.date(fromDayKey: "2026-10-06")),
                                                  deviceHealthResidueStore: cache)
        #expect(built.repository.tierTwoRefresher != nil, "the app did not install the Tier-2 refresher")
        for key in ["2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"] {
            let residue = DeviceHealthResidue(context: nil, importedWorkouts: [Self.importedWorkout("Walk \(key)")])
            #expect(cache.record(residue, for: key))
        }
        let today = FernletDay(date: "2026-10-06", meals: [Self.meal()])
        #expect(built.repository.saveSnapshot(FernletSnapshot(
            todayKey: today.date, day: today, settings: FernletSettings(), recentMeals: [], previousJournals: [],
            memories: [], goals: [Self.strength], workshop: WorkshopData()
        )))

        let records = built.repository.loadTierTwoMemories()
        let gap = try #require(records.first { $0.category == "goal_behavior_gap" && $0.active })
        #expect(gap.state == "aligned")
        #expect(gap.evidence == "4/5 days with workouts")
        // The walks stayed on this device: no row was written for any of those days.
        let rows = built.repository.loadAllDays()
        #expect(rows.keys.sorted() == ["2026-10-06"])
        #expect(rows.values.allSatisfy { $0.workouts.isEmpty && $0.healthContext == nil })
    }
}

// OwnerExerciseAdditionsTests.swift
// FernletTests
//
// The owner's additions of 2026-10-27: 22 more exercises (9 of their own and 13 of the suggestions
// they took with them; the rest were already in the catalog) join it as variations, and the names
// the owner uses for exercises the catalog spells differently ("ab roller" for the Ab wheel) find
// them in the picker, without changing what a name-first lookup resolves to.

import Foundation
import Testing
@testable import FernletDomainModel
@testable import Fernlet

@MainActor
struct OwnerExerciseAdditionsTests {

    static let added = [
        "V-up", "Weighted V-up", "Alternating knee tuck", "Tucked toe tap", "Reverse crunch", "Bicycle crunch",
        "Flutter kick", "Heel tap", "Hollow rock", "Plank shoulder tap", "Cable woodchopper",
        "Cable lat pullover", "Single-arm cable row", "Neutral-grip lat pulldown", "T-bar row",
        "Single-arm lat pulldown", "Cable curl",
        "Cable glute kickback", "Hip abduction machine", "Hip adduction machine", "Cable pull-through", "Donkey kick",
    ]

    /// Every addition is a bundled row with its how-to page, and a variation: the planner reaches for
    /// it only where no staple fits, or as a mild injury's supported choice, so the plans people
    /// already follow, and the weight history behind them, stay as they were.
    @Test func everyAdditionIsAVariationWithItsHowTo() throws {
        #expect(Set(Self.added).count == 22)
        for name in Self.added {
            let row = try #require(WorkoutExerciseCatalog.baseExercises.first { $0.name == name }, "\(name) is not bundled")
            #expect(row.variation, "\(name) would compete with the staples")
            #expect(row.modality == .strength && row.inputKind == .strength, "\(name) is not a lifting row")
            #expect(ExerciseHowToCatalog.entry(for: name) != nil, "\(name) has no how-to page")
        }
    }

    /// Without an injury the additions only fill slots that used to drop: across every split, the
    /// location templates and three narrow ones, each experience level and rotation, a plan made with
    /// them either matches the plan made without them or drops fewer slots and keeps every lift it had
    /// (measured 2026-10-27 over 215,460 cases: with no injury, only a Cable curl filling a cable-only
    /// location's empty biceps slot). A full gym's plans never change.
    @Test func withoutAnInjuryTheAdditionsOnlyFillDroppedSlots() {
        let all = WorkoutExerciseCatalog.allExercises
        let before = all.filter { !Self.added.contains($0.name) }
        let lifts = Set(all.filter { $0.modality == .strength && $0.inputKind == .strength }.map(\.name))
        let locations = LocationTemplate.all.map { $0.makeLocation() } + [
            WorkoutLocation(name: "Park", ownedEquipment: []),
            WorkoutLocation(name: "Cable", ownedEquipment: [.cableMachine]),
            WorkoutLocation(name: "Dumbbells", ownedEquipment: [.dumbbells]),
        ]
        var changed = 0
        for split in WorkoutSplitCatalog.all {
            for location in locations {
                for experience in ExperienceLevel.allCases {
                    for rotation in 0..<max(split.days.count, 1) {
                        let profile = WorkoutProfile(trainingDaysPerWeek: 4, experience: experience)
                        let plans = [before, all].map { catalog in
                            WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: location,
                                                   context: "", split: split, rotationIndex: rotation, catalog: catalog)
                        }
                        let old = plans[0].sessions.flatMap(\.exercises).map(\.name)
                        let new = plans[1].sessions.flatMap(\.exercises).map(\.name)
                        guard old != new else { continue }
                        changed += 1
                        let what = "\(split.name), \(location.name), \(experience), day \(rotation)"
                        #expect(location.name != "Full gym", "\(what): \(old) became \(new)")
                        #expect(plans[1].droppedSlots.count < plans[0].droppedSlots.count, "\(what): \(old) became \(new)")
                        #expect(old.filter { lifts.contains($0) && !new.contains($0) }.isEmpty, "\(what): a lift was displaced")
                    }
                }
            }
        }
        #expect(changed > 0, "the cable-only biceps gap is no longer sampled")
    }

    /// A variation is a mild injury's supported choice only where no staple is supported already: a
    /// mild elbow at a full gym keeps the Preacher curl (a machine) rather than trading it for the
    /// Cable curl on the name tie-break, while with only dumbbells and a cable the Cable curl is the
    /// supported choice over the dumbbell Biceps curl.
    @Test func aVariationIsTheSupportedChoiceOnlyWhereNoStapleIsSupported() throws {
        var profile = WorkoutProfile(trainingDaysPerWeek: 4, experience: .beginner)
        profile.injuryAreas = [.elbow: .mild]
        let slot = WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps])
        func pick(at location: WorkoutLocation) -> String? {
            let feasible = WorkoutExerciseCatalog.allExercises.filter {
                WorkoutSafetyFilter.feasible($0, location: location, limits: profile.injuryLimits)
            }
            return WorkoutProgram.bestExercise(for: slot, in: feasible, excluding: [], biasTokens: [],
                                               experience: .beginner, location: location,
                                               limits: profile.injuryLimits)?.name
        }
        #expect(pick(at: .fullGym) == "Preacher curl")
        let hotel = WorkoutLocation(name: "Hotel", ownedEquipment: [.dumbbells, .cableMachine])
        #expect(pick(at: hotel) == "Cable curl")
    }

    /// The owner's own words find the exercise they mean, in any case.
    @Test func theOwnersNamesFindTheExerciseTheyMean() {
        let meant = [
            "ab roller": "Ab wheel", "quad extension": "Leg extension", "hamstring curl": "Leg curl",
            "laying leg raise": "Lying leg raise", "hanging tuck": "Hanging knee raise",
            "alt knee tuck": "Alternating knee tuck", "lat pull over": "Cable lat pullover",
            "mag grip": "Neutral-grip lat pulldown", "machine chest press": "Chest press machine",
        ]
        for (query, name) in meant {
            #expect(WorkoutExerciseCatalog.search(query).map(\.name).contains(name), "\"\(query)\" does not find \(name)")
            #expect(WorkoutExerciseCatalog.search(" \(query.uppercased()) ").map(\.name).contains(name),
                    "\"\(query)\" in capitals does not find \(name)")
        }
    }

    /// Every alias names a bundled exercise and is spelled as a query is compared (lowercase, trimmed),
    /// and none is already an exercise's own name, which would make it a second identity.
    @Test func everyAliasNamesABundledExerciseAndIsNeverAnExercisesName() {
        let names = Set(WorkoutExerciseCatalog.baseExercises.map(\.name))
        let lowercasedNames = Set(names.map { $0.lowercased() })
        for (name, aliases) in WorkoutExerciseCatalog.searchAliases {
            #expect(names.contains(name), "\(name) is not a bundled exercise")
            for alias in aliases {
                #expect(alias == alias.lowercased() && alias == alias.trimmingCharacters(in: .whitespaces), "\(alias)")
                #expect(!lowercasedNames.contains(alias), "\(alias) is an exercise's own name")
                #expect(WorkoutExerciseCatalog.search(alias).contains { $0.name == name }, "\(alias) does not find \(name)")
            }
        }
    }

    /// An alias only adds results after every exercise a query finds directly, so a caller taking the
    /// first result (a Recent chip, a logged line read back) resolves as it did before the aliases.
    @Test func anAliasOnlyAddsResultsAfterTheDirectOnes() throws {
        let tuck = WorkoutExerciseCatalog.search("tuck").map(\.name)
        let direct = try #require(tuck.firstIndex(of: "Alternating knee tuck"))
        let aliased = try #require(tuck.firstIndex(of: "Hanging knee raise"))
        #expect(direct < aliased, "\(tuck)")
        #expect(WorkoutExerciseCatalog.search("Ab wheel").first?.name == "Ab wheel")
        #expect(WorkoutExerciseCatalog.search("Leg curl").first?.name == "Leg curl")
    }
}

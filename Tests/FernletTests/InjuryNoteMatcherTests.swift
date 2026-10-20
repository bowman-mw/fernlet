import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the whole-word reading of the free-text injury note (``InjuryNoteMatcher``).
///
/// The bug it replaced matched substrings: "hip" matched "championship", and the "back" in "getting
/// back into lifting" left out every hinge. The false positives below must name nothing; the true
/// positives must name the area a person meant, plurals included.
@MainActor
struct InjuryNoteMatcherTests {

    // MARK: - False positives

    @Test(arguments: [
        "getting back into lifting",
        "Got back to the gym after a long break",
        "coming back to training slowly",
        "back to back sessions are fine",
        "back in the gym after vacation",
        "back on track this month",
        "just back from vacation",
        "I'm back!",
        "won the championship last year",
        "I love hip hop dance classes",
        "it's neck and neck with my brother",
        "needs a bit of elbow grease",
        "disc golf on weekends",
        "six feet tall, with a 5 foot bar",
        "on my feet all day at work",
        "back squats are my favourite",
        "background, backpack and feedback",
        "chips, ships and hipsters",
    ])
    func idiomsAndLookalikesNameNothing(note: String) {
        let match = InjuryNoteMatcher.match(note)
        #expect(match.areas.isEmpty, "\"\(note)\" named \(match.areas)")
        #expect(match.muscles.isEmpty, "\"\(note)\" named \(match.muscles)")
    }

    /// The headline bug: this note used to leave out every hinge and the lower back.
    @Test func gettingBackIntoLiftingAvoidsNothing() {
        let profile = WorkoutProfile.fromOnboarding(level: "beginner", interests: "", constraints: "getting back into lifting")
        #expect(profile.avoidedMuscles.isEmpty)
        #expect(profile.avoidedMovements.isEmpty)
        #expect(profile.injuryLimits.isEmpty)
        let feasible = WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: .fullGym, profile: profile
        )
        #expect(feasible.contains { $0.name == "Romanian deadlift" })
    }

    @Test func championshipIsNotAHip() {
        #expect(WorkoutProfile.avoidedMuscles(fromConstraintText: "training for a championship").isEmpty)
        #expect(WorkoutProfile.avoidedMovements(fromConstraintText: "training for a championship").isEmpty)
    }

    // MARK: - True positives

    @Test(arguments: [
        ("lower back pain", BodyArea.lowerBack),
        ("tweaked my back last week", BodyArea.lowerBack),
        ("back and knees ache", BodyArea.lowerBack),
        ("herniated disc", BodyArea.lowerBack),
        ("sore knees", BodyArea.knee),
        ("knee surgery in 2024", BodyArea.knee),
        ("hip flexor strain", BodyArea.hip),
        ("rotator cuff", BodyArea.shoulder),
        ("both shoulders click", BodyArea.shoulder),
        ("upper back tightness", BodyArea.upperBack),
        ("stiff neck", BodyArea.neck),
        ("tennis elbow", BodyArea.elbow),
        ("carpal tunnel", BodyArea.wristHand),
        ("sprained ankle", BodyArea.ankleFoot),
    ])
    func injuryWordsNameTheirArea(note: String, area: BodyArea) {
        #expect(InjuryNoteMatcher.match(note).areas.contains(area), "\"\(note)\" missed \(area)")
    }

    @Test func singleMusclesAreNamedAsMuscles() {
        #expect(InjuryNoteMatcher.match("pulled hamstring").muscles == [.hamstrings])
        #expect(InjuryNoteMatcher.match("tight calves").muscles == [.calves])
        #expect(InjuryNoteMatcher.match("pec strain").muscles == [.chest])
        #expect(InjuryNoteMatcher.match("pulled hamstring").areas.isEmpty)
    }

    /// An idiom and a real injury in one note: only the injury counts.
    @Test func idiomsDoNotHideARealInjuryBesideThem() {
        #expect(InjuryNoteMatcher.match("getting back into lifting after knee surgery").areas == [.knee])
        #expect(InjuryNoteMatcher.match("back to back days hurt my back").areas == [.lowerBack])
        #expect(InjuryNoteMatcher.match("back and neck pain").areas == [.lowerBack, .neck])
    }

    /// Onboarding's carry into the avoided sets keeps the old maps for the old words.
    @Test func onboardingStillAvoidsTheNamedAreasWhole() {
        let knees = WorkoutProfile.fromOnboarding(level: "intermediate", interests: "", constraints: "bad knees")
        #expect(knees.avoidedMuscles == [.quads, .hamstrings])
        #expect(knees.avoidedMovements == [.squat, .lunge])
        let back = WorkoutProfile.fromOnboarding(level: "intermediate", interests: "", constraints: "my back hurts")
        #expect(back.avoidedMuscles == [.lowerBack])
        #expect(back.avoidedMovements == [.hinge])
    }

    /// The note is read live: a note typed in the setup sheet (which never touches the avoided sets)
    /// still leaves the area out.
    @Test func theNoteIsReadLiveByThePlanner() {
        let profile = WorkoutProfile(injuryNotes: "sore knees", experience: .intermediate)
        #expect(profile.avoidedMuscles.isEmpty)
        #expect(profile.injuryLimits.severeAreas == [.knee])
        let feasible = WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: .fullGym, profile: profile
        )
        #expect(!feasible.contains { $0.movementPattern == .squat || $0.movementPattern == .lunge })
    }
}

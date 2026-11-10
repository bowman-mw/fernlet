import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins "Anything else?" on the plan sheet, read for today only (the owner's fix e3, 2026-11-10):
/// a body area it names is trained around today on top of the saved limits (never weakening a saved
/// Severe, never written to the profile), a time phrase picks a shorter session unless the person
/// chose a length themselves, the name-word nudge cannot pull in work for a body part the note
/// names, and the plan's note says each thing applied or points to Equipment & limits.
@MainActor
struct WorkoutDayNoteTests {

    // MARK: - Fixtures

    private func plan(
        _ template: WorkoutSessionTemplate, note: String, profile: WorkoutProfile = WorkoutProfile(experience: .intermediate),
        options: WorkoutSessionOptions = WorkoutSessionOptions(), noteMayShorten: Bool = true
    ) -> WorkoutProgram.DayPlan {
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced,
                                  goalFit: [.strength], days: [WorkoutSplitDay(title: "Day", sessions: [template])])
        return WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: profile, location: .fullGym, context: note,
            split: split, rotationIndex: 0, options: options, catalog: WorkoutExerciseCatalog.baseExercises,
            noteMayShorten: noteMayShorten
        )
    }

    private func lifting(_ plan: WorkoutProgram.DayPlan) -> [PrescribedExercise] {
        plan.sessions.flatMap(\.exercises).filter { $0.block == .lifting && $0.fromCatalog }
    }

    private func notes(_ plan: WorkoutProgram.DayPlan) -> String {
        plan.sessions.map(\.suggestion.notes).joined(separator: " · ")
    }

    // MARK: - Reading

    /// The areas come from the injury note's own reader, so its idioms hold here too; a muscle word
    /// stands for its nearest area.
    @Test func theNoteNamesAreasTheWayTheInjuryNoteDoes() {
        #expect(WorkoutDayNote.read("sore left knee").areas == [.knee])
        #expect(WorkoutDayNote.read("Shoulders are a bit tender, lower back too").areas == [.shoulder, .lowerBack])
        #expect(WorkoutDayNote.read("getting back into it").areas.isEmpty)
        #expect(WorkoutDayNote.read("tight hamstring").areas == [.knee])
        #expect(WorkoutDayNote.read("sore calves").areas == [.ankleFoot])
        #expect(WorkoutDayNote.read("pec feels off").areas == [.shoulder])
        #expect(WorkoutDayNote.read("   ") == WorkoutDayNote())
        #expect(WorkoutDayNote.read("anything").hasText)
    }

    /// Time phrases ask for the shortest session; a stated number of minutes for the longest
    /// length that fits it. A number that only reports something is not a limit.
    @Test func timePhrasesAskForAShortSession() {
        for phrase in ["short on time", "Quick one today", "in a hurry", "running late, sorry", "keep it short"] {
            #expect(WorkoutDayNote.read(phrase).length == .min20, "\(phrase)")
        }
        #expect(WorkoutDayNote.read("only 20 minutes").length == .min20)
        #expect(WorkoutDayNote.read("I've only got 30 min").length == .min30)
        #expect(WorkoutDayNote.read("have about 50 minutes").length == .min45)
        #expect(WorkoutDayNote.read("45min, no jumping").length == .min45)
        #expect(WorkoutDayNote.read("just 10 minutes").length == .min20, "nothing is shorter than the shortest")
        #expect(WorkoutDayNote.read("only half an hour").length == .min30)
        #expect(WorkoutDayNote.read("only 90 minutes").length == nil, "longer than every length limits nothing")
        #expect(WorkoutDayNote.read("ran 30 minutes yesterday").length == nil)
        #expect(WorkoutDayNote.read("feeling strong").length == nil)
    }

    /// A word that names a body part never nudges a pick, and a note that reads as a complaint
    /// nudges nothing.
    @Test func theNudgeLeavesOutBodyPartsAndComplaints() {
        #expect(WorkoutDayNote.read("kettlebell please").nudgeWords == ["kettlebell", "please"])
        #expect(WorkoutDayNote.read("more shoulder and back work").nudgeWords == ["more", "and", "work"])
        #expect(WorkoutDayNote.read("my legs are tired").nudgeWords.isEmpty)
        #expect(WorkoutDayNote.read("no barbell today").nudgeWords.isEmpty)
    }

    // MARK: - Limits

    /// "Sore left knee" is the knee at Mild today: the plan a saved mild knee gets, with the note
    /// saying so — and the profile untouched.
    @Test func aSoreKneeIsEasedTodayAndTheNoteSaysSo() throws {
        let profile = WorkoutProfile(experience: .intermediate)
        let noted = plan(WorkoutSessions.lower, note: "sore left knee", profile: profile)
        let saved = plan(WorkoutSessions.lower, note: "", profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild]))
        let plain = plan(WorkoutSessions.lower, note: "", profile: profile)

        #expect(lifting(noted).map(\.line) == lifting(saved).map(\.line))
        #expect(lifting(noted).map(\.line) != lifting(plain).map(\.line), "before e3 the note changed nothing protective")
        #expect(lifting(plain).first?.name == "Back squat")
        #expect(lifting(noted).first?.name == "Leg press")
        #expect(!lifting(noted).contains { $0.name == "Back squat" })
        #expect(notes(noted).contains("Going easy on your knee today."))
        #expect(!notes(noted).contains("Noted:"))
        #expect(!notes(noted).contains("Worked around your noted limits."), "today's own line already names the area")
        #expect(profile.injuryLimits.isEmpty && profile.injuryAreas.isEmpty, "nothing is written to the profile")
    }

    /// A saved Severe is never weakened to today's Mild: the area stays left out, and the note says
    /// it already is.
    @Test func aSavedSevereIsNotWeakened() throws {
        let severe = WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .severe])
        let merged = severe.injuryLimits.applying(WorkoutDayNote.read("sore knee, sore shoulder"))
        #expect(merged.severeAreas == [.knee])
        #expect(merged.mildAreas == [.shoulder])

        let noted = plan(WorkoutSessions.upper, note: "knee is sore", profile: severe)
        let unnoted = plan(WorkoutSessions.upper, note: "", profile: severe)
        #expect(lifting(noted).map(\.line) == lifting(unnoted).map(\.line))
        #expect(notes(noted).contains("Already leaving out work for your knee."))
        #expect(!notes(noted).contains("Going easy on your knee"))
        for step in lifting(noted) {
            let lift = try #require(WorkoutExerciseCatalog.exercise(named: step.name))
            #expect(InjuryLimits(severeAreas: [.knee]).allows(lift), "\(step.name)")
        }
    }

    /// "My shoulder hurts" used to flip the press to a "shoulder press" by its name alone, at full
    /// weight. Now the word pulls nothing in: the plan is exactly a saved mild shoulder's.
    @Test func aSoreShoulderNoLongerPullsAShoulderPressIn() {
        #expect(WorkoutDayNote.read("my shoulder hurts").nudgeWords.isEmpty)
        let noted = plan(WorkoutSessions.upper, note: "my shoulder hurts")
        let saved = plan(WorkoutSessions.upper, note: "",
                         profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.shoulder: .mild]))
        #expect(lifting(noted).map(\.line) == lifting(saved).map(\.line))
        #expect(!lifting(noted).contains { $0.name == "Overhead press" }, "the barbell press is the heavy end, left out")
        #expect(notes(noted).contains("Going easy on your shoulder today."))
    }

    // MARK: - Time

    /// "Short on time" fits the session into the shortest length and says so; a length the person
    /// chose on the sheet stands, and a session already as short is not announced.
    @Test func shortOnTimePicksTheShortestSessionUnlessALengthWasChosen() {
        let goal = GoalType.strength
        let open = plan(WorkoutSessions.lower, note: "")
        let short = plan(WorkoutSessions.lower, note: "short on time")
        let byOption = plan(WorkoutSessions.lower, note: "", options: WorkoutSessionOptions(length: .min20))
        #expect(short.sessions.first?.exercises.map(\.line) == byOption.sessions.first?.exercises.map(\.line))
        let minutes = WorkoutSessionTime.minutes(of: short.sessions.first?.exercises ?? [], goal: goal)
        #expect(minutes < WorkoutSessionTime.minutes(of: open.sessions.first?.exercises ?? [], goal: goal))
        #expect(notes(short).contains("Kept to about 20 minutes, as you asked."))

        let chosen = plan(WorkoutSessions.lower, note: "short on time", options: WorkoutSessionOptions(length: .min45),
                          noteMayShorten: false)
        let fortyFive = plan(WorkoutSessions.lower, note: "", options: WorkoutSessionOptions(length: .min45))
        #expect(chosen.sessions.first?.exercises.map(\.line) == fortyFive.sessions.first?.exercises.map(\.line))
        #expect(!notes(chosen).contains("as you asked"))
        #expect(!notes(chosen).contains("Nothing in your note"), "the time phrase was understood; the chosen length answers it")

        let setup = plan(WorkoutSessions.lower, note: "short on time", options: WorkoutSessionOptions(length: .min30))
        #expect(notes(setup).contains("Kept to about 20 minutes"), "Workout setup's own length gives way to today's note")
        let longer = plan(WorkoutSessions.lower, note: "only 45 minutes", options: WorkoutSessionOptions(length: .min30))
        #expect(!notes(longer).contains("as you asked"), "a note never lengthens the session")
    }

    // MARK: - The note

    /// Nothing the planner could apply: it says so and points to Equipment & limits. An empty note
    /// says nothing at all.
    @Test func nothingApplicablePointsToEquipmentAndLimits() {
        let pointer = "Nothing in your note could be applied to this plan. Lasting limits and equipment are set in Equipment & limits."
        #expect(notes(plan(WorkoutSessions.lower, note: "slept badly, feeling flat")).contains(pointer))
        #expect(notes(plan(WorkoutSessions.lower, note: "me duele la rodilla")).contains(pointer), "another language matches nothing, and says so")
        let empty = notes(plan(WorkoutSessions.lower, note: "  "))
        #expect(!empty.contains("Nothing in your note") && !empty.contains("today."))
    }

    /// Each thing applied gets its own sentence, on the day's first session only.
    @Test func eachThingAppliedHasItsOwnSentence() {
        let both = notes(plan(WorkoutSessions.lower, note: "sore left knee, short on time"))
        #expect(both.contains("Going easy on your knee today. · Kept to about 20 minutes, as you asked."))

        let twoADay = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [.strength], days: [
            WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.upper.at(.morning), WorkoutSessions.lower.at(.evening)]),
        ])
        let day = WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate), location: .fullGym,
            context: "sore knee", split: twoADay, rotationIndex: 0, catalog: WorkoutExerciseCatalog.baseExercises
        )
        #expect(day.sessions.count == 2)
        #expect(day.sessions.first?.suggestion.notes.contains("Going easy on your knee today.") == true)
        #expect(day.sessions.last?.suggestion.notes.contains("Going easy") == false)
        #expect(day.sessions.last?.exercises.contains { $0.name == "Back squat" } == false, "the easing reaches every session")
    }

    /// A wish that matches a lift's name still nudges the pick, and the note names the lift.
    @Test func aMatchingWishNamesTheLiftItPicked() throws {
        let noted = plan(WorkoutSessions.lower, note: "goblet today")
        #expect(lifting(noted).contains { $0.name == "Goblet squat" })
        #expect(notes(noted).contains("Picked to match your note: Goblet squat."))
        #expect(!notes(noted).contains("Nothing in your note"))
    }
}

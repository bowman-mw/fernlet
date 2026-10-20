// WorkoutSportActivityTests.swift
// FernletTests
//
// Pins round 2's R5 (2026-10-20): a finished guided sport session logs the sport named in Workout setup
// as its activity type when Fernlet models it (pickleball, tennis, basketball and so on), and keeps the
// generic type otherwise. Covered: reading the free-text sport (whole words, any case, the first sport
// named, a longer phrase over the word inside it) and the timed log's choice per session kind. No
// activity case was added, so nothing synced changes shape. How Apple Health shows the logged session is
// owed on a device.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct WorkoutSportActivityTests {

    private static func run(kind: String) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate", title: "Sport conditioning",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: kind,
            exercises: [GuidedWorkoutRunState.Exercise(
                name: "Goblet squat", sets: 3, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: 90,
                blockRaw: "lifting"
            )]
        )
    }

    @Test func aNamedSportReadsAsItsOwnActivity() {
        let cases: [(String, WorkoutActivityType)] = [
            ("pickleball", .pickleball), ("Tennis", .tennis), ("table tennis", .tableTennis),
            ("Ping-pong", .tableTennis), ("basketball, soccer", .basketball), ("rock climbing", .climbing),
            ("Brazilian jiu-jitsu", .martialArts), ("trail running", .running), ("  SQUASH!  ", .squash),
        ]
        for (text, expected) in cases {
            let type = WorkoutSportActivity.activityType(forSport: text)
            #expect(type == expected, "\(text)")
        }
    }

    @Test func aSportFernletDoesNotModelReadsAsNone() {
        for text in ["", "   ", "golf", "volleyball", "football", "tennisball", "Fußball"] {
            let type = WorkoutSportActivity.activityType(forSport: text)
            #expect(type == nil, "\(text)")
        }
    }

    @Test func theFirstSportNamedWins() {
        let soccerFirst = WorkoutSportActivity.activityType(forSport: "soccer and some tennis")
        #expect(soccerFirst == .soccer)
        let tennisFirst = WorkoutSportActivity.activityType(forSport: "tennis, then soccer")
        #expect(tennisFirst == .tennis)
    }

    @Test func aGuidedSportSessionLogsItsSport() {
        let sport = Self.run(kind: SessionKind.sport.rawValue)
        let pickleball = GuidedRunTimedLog.activityType(for: sport, sport: "Pickleball")
        #expect(pickleball == .pickleball)
        let unmatched = GuidedRunTimedLog.activityType(for: sport, sport: "golf")
        #expect(unmatched == nil, "the generic type it always had")
        let unnamed = GuidedRunTimedLog.activityType(for: sport)
        #expect(unnamed == nil)
        let strength = GuidedRunTimedLog.activityType(for: Self.run(kind: SessionKind.strength.rawValue), sport: "tennis")
        #expect(strength == nil, "only a sport session reads the sport")
    }
}

// WorkoutSportActivityTests.swift
// FernletTests
//
// Pins round 2's R5 (2026-10-20): a finished guided sport session logs the sport named in Workout setup
// as its activity type when Fernlet models it (pickleball, tennis, volleyball, golf and so on), and keeps
// the generic type otherwise. Covered: reading the free-text sport (whole words, any case, the first sport
// named, a longer phrase over the word inside it), the owner's follow-up picks — the added sports, bare
// "football" by region, and distance sports keeping the generic type — and the timed log's choice per
// session kind. How Apple Health shows the logged session is owed on a device.

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
            ("Brazilian jiu-jitsu", .martialArts), ("  SQUASH!  ", .squash), ("beach volleyball", .volleyball),
            ("golf", .golf), ("Ice hockey", .hockey), ("rugby sevens", .rugby), ("flag football", .americanFootball),
            ("boxing", .boxing), ("wrestling", .wrestling), ("cross-country skiing", .crossCountrySkiing),
            ("skiing", .downhillSkiing), ("snowboarding", .snowboarding), ("skateboarding", .skating),
            ("kitesurfing", .surfing), ("baseball", .baseball), ("softball", .softball), ("lacrosse", .lacrosse),
        ]
        for (text, expected) in cases {
            let type = WorkoutSportActivity.sport(named: text, region: "US")
            #expect(type == expected, "\(text)")
        }
    }

    @Test func aSportFernletDoesNotModelReadsAsNone() {
        for text in ["", "   ", "curling", "cricket", "tennisball", "Fußball", "Australian rules football", "triathlon"] {
            let type = WorkoutSportActivity.sport(named: text, region: "US")
            #expect(type == nil, "\(text)")
        }
        let afterUnmodeled = WorkoutSportActivity.sport(named: "Gaelic football, then soccer", region: "IE")
        #expect(afterUnmodeled == nil, "the first sport named is one Fernlet doesn't model; soccer doesn't stand in")
    }

    @Test func theFirstSportNamedWins() {
        let soccerFirst = WorkoutSportActivity.sport(named: "soccer and some tennis", region: "US")
        #expect(soccerFirst == .soccer)
        let tennisFirst = WorkoutSportActivity.sport(named: "tennis, then soccer", region: "US")
        #expect(tennisFirst == .tennis)
    }

    /// Bare "football" is American football in the US and Canada, soccer elsewhere, and nothing where
    /// it most often means a code Fernlet doesn't model or where the region is unknown. Named codes read
    /// the same everywhere.
    @Test func footballReadsByRegion() {
        let regions: [(String?, WorkoutActivityType?)] = [
            ("US", .americanFootball), ("CA", .americanFootball), ("us", .americanFootball), ("GB", .soccer),
            ("DE", .soccer), ("BR", .soccer), ("AU", nil), ("NZ", nil), ("IE", nil), (nil, nil), ("", nil),
        ]
        for (region, expected) in regions {
            let type = WorkoutSportActivity.sport(named: "Football", region: region)
            let place = region ?? "no region"
            #expect(type == expected, "football in \(place)")
        }
        let soccerInTheUS = WorkoutSportActivity.sport(named: "soccer", region: "US")
        #expect(soccerInTheUS == .soccer)
        let gridironInBritain = WorkoutSportActivity.sport(named: "American football", region: "GB")
        #expect(gridironInBritain == .americanFootball)
        let associationInTheUS = WorkoutSportActivity.sport(named: "association football", region: "US")
        #expect(associationInTheUS == .soccer)
    }

    /// A distance sport is read as its sport but logs as the generic type: the session is gym strength and
    /// conditioning work, not a run (owner's pick, 2026-10-20).
    @Test func aDistanceSportLogsAsTheGenericType() {
        let distance: [(String, WorkoutActivityType)] = [
            ("running", .running), ("trail running", .running), ("marathon", .running), ("cycling", .cycling),
            ("rowing", .rowing), ("hiking", .hiking), ("swimming", .swimmingPool),
            ("open water swimming", .swimmingOpenWater), ("cross country skiing", .crossCountrySkiing),
        ]
        for (text, sport) in distance {
            let read = WorkoutSportActivity.sport(named: text, region: "US")
            let logged = WorkoutSportActivity.activityType(forSport: text, region: "US")
            #expect(read == sport, "\(text) is read as its sport")
            #expect(logged == nil, "\(text) logs as the generic type")
        }
        let runnerFirst = WorkoutSportActivity.activityType(forSport: "running and soccer", region: "US")
        #expect(runnerFirst == nil, "the first sport named is a distance sport")
        let downhill = WorkoutSportActivity.activityType(forSport: "skiing", region: "US")
        #expect(downhill == .downhillSkiing, "downhill skiing is not a distance sport")
    }

    @Test func aGuidedSportSessionLogsItsSport() {
        let sport = Self.run(kind: SessionKind.sport.rawValue)
        let pickleball = GuidedRunTimedLog.activityType(for: sport, sport: "Pickleball", region: "US")
        #expect(pickleball == .pickleball)
        let football = GuidedRunTimedLog.activityType(for: sport, sport: "football", region: "US")
        #expect(football == .americanFootball)
        let running = GuidedRunTimedLog.activityType(for: sport, sport: "running", region: "US")
        #expect(running == nil, "a distance sport keeps the generic type")
        let unmatched = GuidedRunTimedLog.activityType(for: sport, sport: "curling", region: "US")
        #expect(unmatched == nil, "the generic type it always had")
        let unnamed = GuidedRunTimedLog.activityType(for: sport)
        #expect(unnamed == nil)
        let strength = GuidedRunTimedLog.activityType(
            for: Self.run(kind: SessionKind.strength.rawValue), sport: "tennis", region: "US"
        )
        #expect(strength == nil, "only a sport session reads the sport")
    }
}

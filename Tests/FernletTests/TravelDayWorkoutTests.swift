import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletScoring
@testable import Fernlet

/// Pins travel-day workouts (World-Airports-Spec §13), with made-up flights only (a Portland traveller on Cedar
/// Air): the travel-day rule (a flight's date, the next day after one in the air between midnight and 5 am in
/// either airport's time, ending at local midnight), the session flag's travel reason (the load holds, never a
/// stall, the light day's trims), the fixed Travel-day reset, and the week count that leaves a travel day's
/// planned session out.
@MainActor
struct TravelDayWorkoutTests {

    // MARK: - Fixtures

    static let portland = TimeZone(identifier: "America/Los_Angeles") ?? .current
    static let boston = TimeZone(identifier: "America/New_York") ?? .current
    static let london = TimeZone(identifier: "Europe/London") ?? .current
    static let honolulu = TimeZone(identifier: "Pacific/Honolulu") ?? .current

    /// The instant of `y-m-d h:mm` in `zone`.
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, in zone: TimeZone) -> Date {
        WorldTravelDayRule.calendar(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// A made-up Cedar Air flight.
    func flight(_ dep: Date, _ arr: Date?, from: TimeZone = portland, to: TimeZone) -> TravelDayFlight {
        TravelDayFlight(departure: dep, arrival: arr, originZone: from, destinationZone: to)
    }

    // MARK: - The rule

    @Test func aDaytimeFlightMakesOnlyItsOwnDate() {
        // PDX → SEA, 9:00 to 10:00 Portland time.
        let hop = flight(at(2026, 11, 14, 9, in: Self.portland), at(2026, 11, 14, 10, in: Self.portland), to: Self.portland)
        #expect(!WorldTravelDayRule.isOvernight(hop))
        #expect(!WorldTravelDayRule.isLong(hop))
        #expect(WorldTravelDayRule.days(of: hop) == ["2026-11-14": .flightDay])
    }

    @Test func aLongDaytimeFlightIsStillOnlyItsOwnDate() {
        // PDX → HNL, 9:00 Portland to 12:30 Honolulu (5.5 h), never in the air between midnight and 5 am.
        let long = flight(at(2026, 11, 14, 9, in: Self.portland), at(2026, 11, 14, 12, 30, in: Self.honolulu), to: Self.honolulu)
        #expect(WorldTravelDayRule.isLong(long))
        #expect(!WorldTravelDayRule.isOvernight(long))
        #expect(WorldTravelDayRule.days(of: long) == ["2026-11-14": .flightDay])
    }

    @Test func aRedEyeMakesItsDateAndTheNextDay() {
        // PDX → BOS, 22:30 Portland to 7:00 Boston: in the air from midnight to 4:00 Portland time.
        let redEye = flight(at(2026, 11, 13, 22, 30, in: Self.portland), at(2026, 11, 14, 7, in: Self.boston), to: Self.boston)
        #expect(WorldTravelDayRule.isOvernight(redEye))
        #expect(WorldTravelDayRule.days(of: redEye) == ["2026-11-13": .flightDay, "2026-11-14": .afterOvernight])
    }

    @Test func overnightInTheArrivalAirportsTimeCountsToo() {
        // PDX → LHR, 13:00 Portland (21:00 London) to 7:00 London (23:00 Portland): overnight only in London's time.
        let east = flight(at(2026, 11, 13, 13, in: Self.portland), at(2026, 11, 14, 7, in: Self.london), to: Self.london)
        #expect(!WorldTravelDayRule.inAirOvernight(from: east.departure, to: east.arrival ?? east.departure, in: Self.portland))
        #expect(WorldTravelDayRule.isOvernight(east))
        #expect(WorldTravelDayRule.days(of: east)["2026-11-14"] == .afterOvernight)
    }

    @Test func aFlightWithNoArrivalYetIsNeverOvernight() {
        let ticket = flight(at(2026, 11, 13, 23, in: Self.portland), nil, to: Self.portland)
        #expect(!WorldTravelDayRule.isOvernight(ticket))
        #expect(WorldTravelDayRule.days(of: ticket) == ["2026-11-13": .flightDay])
    }

    @Test func theNextDayEndsAtLocalMidnight() {
        let redEye = flight(at(2026, 11, 13, 22, 30, in: Self.portland), at(2026, 11, 14, 7, in: Self.boston), to: Self.boston)
        #expect(WorldTravelDayRule.today("2026-11-13", flights: [redEye]).kind == .flightDay)
        #expect(WorldTravelDayRule.today("2026-11-14", flights: [redEye]).kind == .afterOvernight)
        #expect(WorldTravelDayRule.today("2026-11-15", flights: [redEye]) == .none)
        // The day key turns over at the traveller's own midnight, wherever they landed.
        let lateInBoston = at(2026, 11, 14, 23, 59, in: Self.boston)
        #expect(WorldTravelDayRule.dayKey(lateInBoston, in: Self.boston) == "2026-11-14")
        #expect(WorldTravelDayRule.dayKey(lateInBoston.addingTimeInterval(120), in: Self.boston) == "2026-11-15")
    }

    @Test func aFlightsOwnDateWinsOverAnotherFlightsNextDay() {
        let redEye = flight(at(2026, 11, 13, 22, 30, in: Self.portland), at(2026, 11, 14, 7, in: Self.boston), to: Self.boston)
        let onward = flight(at(2026, 11, 14, 11, in: Self.boston), at(2026, 11, 14, 13, in: Self.boston),
                            from: Self.boston, to: Self.boston)
        let today = WorldTravelDayRule.today("2026-11-14", flights: [redEye, onward])
        #expect(today.kind == .flightDay && today.isTravelDay)
    }

    @Test func longFlightIsAYesNoOfTodaysFlights() {
        let long = flight(at(2026, 11, 14, 9, in: Self.portland), at(2026, 11, 14, 12, 30, in: Self.honolulu), to: Self.honolulu)
        #expect(WorldTravelDayRule.today("2026-11-14", flights: [long]).longFlight)
        let hop = flight(at(2026, 11, 14, 9, in: Self.portland), at(2026, 11, 14, 10, in: Self.portland), to: Self.portland)
        #expect(!WorldTravelDayRule.today("2026-11-14", flights: [hop]).longFlight)
    }

    // MARK: - The flag

    @Test func aTravelDayIsAThirdReasonWithTheLightDaysTrims() throws {
        let travel = try #require(WorkoutSessionFlag.make(sleep: nil, lightDay: false, travelDay: true))
        #expect(travel.travelDay && !travel.lightDay && travel.sleep == nil)
        #expect(WorkoutSessionFlag.make(sleep: nil, lightDay: false, travelDay: false) == nil)
        for lowerBody in [true, false] {
            #expect(travel.trim(lowerBody: lowerBody) == WorkoutSessionFlag(lightDay: true).trim(lowerBody: lowerBody))
        }
    }

    @Test func aMissOnATravelDayHoldsTheLoadAndSaysSo() {
        let engine = WorkoutLoadEngineTests()
        let missed = engine.session(24, 135, reps: [10, 8, 7], target: 10)
        var travelled = engine.session(28, 135, reps: [10, 8, 7], target: 10)
        travelled.flag = WorkoutSessionFlag(travelDay: true)
        let held = engine.plan([missed, travelled])
        #expect((held.change, held.prescription?.suggested) == (.heldAfterFlag, 135))
        #expect(held.previousFlag?.travelDay == true)
    }

    @Test func lowSessionsOnTravelDaysAreNeitherADipNorAStall() {
        let engine = WorkoutLoadEngineTests()
        let low = [42, 44].map { offset -> LiftExposure in
            var tired = engine.session(offset, 125, reps: [6, 6, 6], target: 8)
            tired.flag = WorkoutSessionFlag(travelDay: true)
            return tired
        }
        let history = engine.weekly(6) { 100 + 5 * Double($0) } + low
        #expect(WorkoutPlateau.status(of: history, unit: .lb, today: engine.day(45), profile: engine.knownAge(history)) == nil)
    }

    @Test func theTrendCountsTravelDaysByTheirOwnReason() {
        let points = (0..<10).map { index in
            TrendPoint(date: WorkoutLoadEngineTests.base.addingTimeInterval(Double(index * 3) * 86_400), score: 100,
                       flag: index.isMultiple(of: 2) ? WorkoutSessionFlag(travelDay: true) : nil)
        }
        let reading = WorkoutTrend.reading(of: points, profile: TrendProfile(trainingAge: TrainingAge(weeks: 8)))
        #expect(reading.travelDaySessions == 5 && reading.lightDaySessions == 0 && reading.shortNightSessions == 0)
        #expect(reading.mostlyFlagged)
    }

    @Test func theBuilderFlagsASessionOnATravelDayFromItsDayKeyAlone() throws {
        let date = WorkoutLoadEngineTests.base
        let key = FernletDate.dayKey(for: date)
        let row = FernletDay(date: key, workouts: [
            Workout(name: "Push", type: .upper, exercises: "Bench press 3x8 @100 lb", rpe: nil, notes: "",
                    duration: nil, intensity: .moderate),
        ])
        let lift = WorkoutExerciseCatalog.normalizedName("Bench press")
        let flagged = WorkoutLoadContextBuilder.exposures([(row, date)], travelDays: [key])
        let flag = try #require(flagged.byLift[lift]?.first?.flag)
        #expect(flag.travelDay && !flag.lightDay)
        #expect(WorkoutLoadContextBuilder.exposures([(row, date)]).byLift[lift]?.first?.flag == nil)
    }

    // MARK: - The session

    @Test func theTravelDayResetIsTheApprovedFixedList() throws {
        let plan = WorkoutPlanner.travelDayPlan(locationName: "Hotel room")
        #expect(WorkoutPlanner.isTravelDayPlan(plan))
        let session = try #require(plan.sessions.first)
        #expect(session.suggestion.name == "Travel-day reset")
        #expect(session.suggestion.name == WorkoutFallbackName.travelDayReset.rawValue)
        #expect(session.suggestion.notes == "Lots of sitting today: an easy walk and some stretches for your legs, hips and back.")
        #expect(WorkoutPlanner.travelDayMoveNames == [
            "Easy walk", "Standing calf raise", "Glute bridge", "Low lunge stretch",
            "Figure-four stretch", "Cat-cow", "Thread the needle", "Calf stretch",
        ])
        // Every move is already in the library, under its exact catalog name.
        for name in WorkoutPlanner.travelDayMoveNames + ["Treadmill walk"] {
            #expect(ExerciseHowToCatalog.entry(for: name) != nil, "\(name) has no how-to")
        }
        #expect(GuidedWorkoutAvailability.isGuidable(session))
        // Nothing in it is progressed or becomes a lift's history.
        #expect(session.catalogExerciseNames.isEmpty)
        let steps = session.exercises
        #expect(steps.first?.name == "Easy walk - 25 min")
        #expect(steps.filter { $0.name == "Standing calf raise" }.map { "\($0.sets) x \($0.reps)" } == ["2 x 15"])
        #expect(steps.filter { $0.name == "Glute bridge" }.map { "\($0.sets) x \($0.reps)" } == ["2 x 12"])
        #expect(steps.filter { $0.name == "Low lunge stretch" }.map(\.side) == [.left, .right])
        #expect(steps.filter { $0.name == "Calf stretch" }.allSatisfy { $0.holdSeconds == 30 })
    }

    @Test func theSuggestionIsChosenByTheTravelDayYesNo() {
        let travel = WorkoutPlanner.suggestion(energy: .hard, goal: "strength", context: "", goals: [], travelDay: true)
        #expect(travel.name == "Travel-day reset" && travel.intensity == .light && travel.duration == 40)
        let usual = WorkoutPlanner.suggestion(energy: .light, goal: "strength", context: "", goals: [], travelDay: false)
        #expect(usual.name == WorkoutFallbackName.suggestedLight.rawValue)
    }

    // MARK: - Forgiven

    @Test func aTravelDaysPlannedSessionIsLeftOutOfTheWeek() throws {
        let plan = PlannedWorkout(name: "Full Body A", split: .fullBody, source: .user, notes: "", duration: 55)
        let thursday = FernletDay(date: "2026-11-12", workouts: [plan.completedWorkout])
        let friday = FernletDay(date: "2026-11-13", workouts: [plan.completedWorkout])
        let saturday = FernletDay(date: "2026-11-14", plannedWorkouts: [plan])
        let week = try #require(TravelDayWeekProgress.make(days: [thursday, friday, saturday],
                                                           travelDays: ["2026-11-14"], todayKey: "2026-11-14"))
        #expect((week.done, week.total, week.leftOutDayKeys) == (2, 2, ["2026-11-14"]))
        #expect(TravelDayWeekProgress.isForgiven(saturday, travelDays: ["2026-11-14"], todayKey: "2026-11-14"))
        // Not a travel day, or not yet begun: nothing is left out, and no card is drawn.
        #expect(TravelDayWeekProgress.make(days: [thursday, saturday], travelDays: [], todayKey: "2026-11-14") == nil)
        #expect(!TravelDayWeekProgress.isForgiven(saturday, travelDays: ["2026-11-14"], todayKey: "2026-11-13"))
    }

    @Test func rememberedTravelDaysStayInsideTheLookback() {
        let now = WorkoutLoadEngineTests.base
        let old = FernletDate.dayKey(for: now.addingTimeInterval(-200 * 86_400))
        let recent = FernletDate.dayKey(for: now.addingTimeInterval(-3 * 86_400))
        let far = FernletDate.dayKey(for: now.addingTimeInterval(10 * 86_400))
        #expect(FernletStore.prunedTravelDays([old, recent, far], now: now) == [recent])
    }
}

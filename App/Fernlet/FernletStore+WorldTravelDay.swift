import AIContext
import FernletDomainModel
import FernletFoundation
import FernletScoring
import Foundation
import LocalPersistence
import WorldMapStore

/// Travel-day workouts on the store (World-Airports-Spec §13): the composition root's side of the wall.
///
/// - **Today** (``workoutTravelDay(now:)``): the flights Fernlet knows of are read here, and only two yes/no
///   values leave (travel day, long flight), with which kind of day it is for the Move card's line. A flight is
///   known from a ticket (a trip started today), a calendar flight for today (the passport's upcoming flights),
///   or a flight found by its speed (the passport's flights, or one under way), §13.1.
/// - **Past days** (``workoutTravelDayKeys``): the travel days of the plateau's lookback, as day keys only, for
///   the planner's forgiveness (`WorkoutLoadContextBuilder` turns each into a session flag's yes/no). They are
///   remembered in the map's vault (``travelDaysFile``, sealed under the buffer key like the flight gate's
///   state), so a ticket's day, or a flight later deleted from the passport, is still forgiven. Only the day
///   keys are kept: never a flight, an airport, a time or a place. The planner's own history (light days,
///   short nights) lives on the synced day records; travel stays off them, because a travel day is a passport
///   fact and passport facts never sync outside the passport's sealed backup (§11).
/// - **Never** in a decoy (nothing read, nothing kept) or with "Airports and flights" off.
/// - **Tier-2 memory** (``publishTierTwoTravel(now:)``, owner 2026-11-15): the travel days of the last fortnight
///   reach Tier-2 as day keys, and a travel day's city name (city only, no airport codes, times or coordinates) may
///   enter Tier-2 memory, only while the AI runs on device (``tierTwoMemoryAIRunsOnDevice``). Nothing else
///   travel-related reaches `AIProviders`.
/// - **The plan** (``commitTodaysTravelDayPlan()``, ``liftInsteadOnTravelDay()``): the Travel-day reset as
///   today's plan, and "Lift instead, lighter", the planner's light plan in its place (§13.2).
extension FernletStore {
    /// The remembered travel days: a JSON list of day keys, the device side's purpose and buffer key, bound to
    /// its own context so it never opens as another file.
    static let travelDaysFile = WorldMapVault.File(name: "travel-days.bin",
                                                   purpose: WorldMapVault.File.placesDevice.purpose,
                                                   role: .buffer, context: Data("travelDays".utf8))
    /// How far back travel days are kept and read: the plateau's lookback, which the planner reads sessions over.
    nonisolated static let travelDayLookbackDays = WorkoutPlateau.lookbackDays
    /// The most remembered day keys (a bound: one a day over the lookback, and a little room).
    nonisolated static let maxRememberedTravelDays = WorkoutPlateau.lookbackDays + 8

    /// Today's travel-day answer (§13.1). `.none` in a decoy or with "Airports and flights" off.
    func workoutTravelDay(now: Date = Date()) -> WorkoutTravelDay {
        guard mayKeepWorkoutTravelDays() else { return .none }
        return WorldTravelDayRule.today(FernletDate.dayKey(for: now), flights: worldTravelDayFlights(now: now))
    }

    /// The travel days of the lookback, by day key: the remembered ones and those today's flights make. Empty in
    /// a decoy or with "Airports and flights" off.
    var workoutTravelDayKeys: Set<String> {
        guard mayKeepWorkoutTravelDays() else { return [] }
        let now = Date()
        return Self.prunedTravelDays(rememberedTravelDays().union(travelDaysFromFlights(now: now)), now: now)
    }

    /// Writes today's flights' travel days into the remembered list (the Move page calls this as it opens), so a
    /// day stays forgiven after the ticket ends or the flight leaves the passport.
    func rememberWorkoutTravelDays(now: Date = Date()) {
        defer { publishTierTwoTravel(now: now) }
        guard mayKeepWorkoutTravelDays() else { return }
        let remembered = rememberedTravelDays()
        let kept = Self.prunedTravelDays(remembered.union(travelDaysFromFlights(now: now)), now: now)
        guard kept != remembered else { return }
        do {
            try worldMapVault.write(JSONEncoder().encode(kept.sorted()), to: Self.travelDaysFile)
        } catch {
            FernletAuditLog.log("workout.travelDays.saveDeferred")
        }
    }

    // MARK: Tier-2 memory

    /// How many days back Tier-2's travel snapshot reaches: the engine's 14-day window and a little room.
    nonisolated static let tierTwoTravelLookbackDays = 16

    /// Whether the AI that reads Tier-2 memory runs on this iPhone: the guard rail on city names (orchestrator's
    /// call, 2026-11-15, flagged for the owner). Memory reaches a prompt only through `MemoryAgent` into the
    /// `light` tier, and that tier's ladder is on-device only and pinned by `FernletModelRouter`, which fails closed
    /// on a destination that leaves the device. Read from the tier itself, so a ladder change turns cities off.
    ///
    /// TODO(P2-B): Phase 2's Private Cloud Compute and BYOK destinations must honour this. If memory ever reaches
    /// a `standard` or `deep` task, or the `light` ladder gains an off-device rung, this must read the destination
    /// the memory actually goes to, and a record that names a city must not reach it (re-derive without the city).
    nonisolated static var tierTwoMemoryAIRunsOnDevice: Bool {
        let tier = AICapabilityTier.light
        return !tier.allowsOffDeviceEscalation && tier.escalationLadder.allSatisfy { !$0.leavesDevice }
    }

    /// Publishes this iPhone's travel days into ``tierTwoTravel`` for the Tier-2 refresher: the travel days of the
    /// last ``tierTwoTravelLookbackDays`` (remembered and from today's flights), each with its flight's English
    /// cities where the passport knows them. Publishes none in a decoy or with "Airports and flights" off. Called
    /// when the Move page remembers travel days and when the map loads (launch and each return to the foreground).
    func publishTierTwoTravel(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard mayKeepWorkoutTravelDays(defaults: defaults) else {
            tierTwoTravel.publish(.none)
            return
        }
        let oldest = FernletDate.dayKey(for: now.addingTimeInterval(-Double(Self.tierTwoTravelLookbackDays) * 86_400))
        let today = FernletDate.dayKey(for: now)
        let cities = tierTwoTravelCities(now: now)
        var days: [String: TierTwoTravelDay] = [:]
        for key in workoutTravelDayKeys where key >= oldest && key <= today {
            days[key] = cities[key] ?? TierTwoTravelDay()
        }
        tierTwoTravel.publish(TierTwoTravel(days: days, namesCities: Self.tierTwoMemoryAIRunsOnDevice))
    }

    /// What the Tier-2 refresher reads: the published snapshot, or none once the gate is shut (a decoy started or
    /// "Airports and flights" went off since the last publish).
    func tierTwoTravelForRefresh(defaults: UserDefaults = .standard) -> TierTwoTravel {
        mayKeepWorkoutTravelDays(defaults: defaults) ? tierTwoTravel.snapshot : .none
    }

    /// The English cities of the passport's flown flights in Tier-2's lookback, by the flight's own date (its
    /// departure's date at the departure airport). An airport the bundled list doesn't name gives no city.
    private func tierTwoTravelCities(now: Date) -> [String: TierTwoTravelDay] {
        guard let pack = worldLocation.flights.airportsShelf.pack() else { return [:] }
        let from = now.addingTimeInterval(-Double(Self.tierTwoTravelLookbackDays + 1) * 86_400)
        let flown = worldFog.atlas.book.flights.filter { $0.departure >= from && $0.departure <= now }
        var cities: [String: TierTwoTravelDay] = [:]
        // Bounded: at most `TierTwoTravel.maxDays` flights, the newest.
        for flight in flown.suffix(TierTwoTravel.maxDays) {
            let key = WorldTravelDayRule.dayKey(flight.departure, in: pack.timeZone(iata: flight.from) ?? .current)
            cities[key] = TierTwoTravelDay(fromCity: pack.airport(code: flight.from)?.city(spanish: false),
                                           toCity: pack.airport(code: flight.to)?.city(spanish: false))
        }
        return cities
    }

    /// Whether travel days may be read and kept now: never in a decoy, never with "Airports and flights" off.
    func mayKeepWorkoutTravelDays(defaults: UserDefaults = .standard) -> Bool {
        !duressSessionActive && keepsWorldAirportsAndFlights(defaults: defaults)
    }

    /// The remembered list, or empty when there is none or it can't be read now.
    private func rememberedTravelDays() -> Set<String> {
        do {
            guard let data = try worldMapVault.read(Self.travelDaysFile) else { return [] }
            let keys = try JSONDecoder().decode([String].self, from: data)
            return Set(keys.prefix(Self.maxRememberedTravelDays).filter { FernletDate.date(fromDayKey: $0) != nil })
        } catch {
            FernletAuditLog.log("workout.travelDays.unreadable")
            return []
        }
    }

    /// The travel days the known flights make, by day key.
    private func travelDaysFromFlights(now: Date) -> Set<String> {
        Set(WorldTravelDayRule.days(of: worldTravelDayFlights(now: now)).keys)
    }

    /// `keys` inside the lookback (none in the future past tomorrow), at most ``maxRememberedTravelDays``, newest kept.
    nonisolated static func prunedTravelDays(_ keys: Set<String>, now: Date) -> Set<String> {
        let oldest = FernletDate.dayKey(for: now.addingTimeInterval(-Double(travelDayLookbackDays) * 86_400))
        let newest = FernletDate.dayKey(for: now.addingTimeInterval(86_400))
        let inside = keys.filter { $0 >= oldest && $0 <= newest }.sorted()
        return Set(inside.suffix(maxRememberedTravelDays))
    }

    /// The flights the rule reads (§13.1): the passport's flights and upcoming calendar flights leaving inside the
    /// lookback (or up to two days ahead), a flight under way, and a trip under way by its start. The airports'
    /// zones come from the bundled list, this iPhone's zone where it has none.
    func worldTravelDayFlights(now: Date) -> [TravelDayFlight] {
        let pack = worldLocation.flights.airportsShelf.pack()
        let local = TimeZone.current
        let zone: (String) -> TimeZone = { pack?.timeZone(iata: $0) ?? local }
        let from = now.addingTimeInterval(-Double(Self.travelDayLookbackDays + 2) * 86_400)
        let to = now.addingTimeInterval(2 * 86_400)
        let book = worldFog.atlas.book
        let recent = (book.flights + book.upcomingFlights).filter { $0.departure >= from && $0.departure <= to }
        var flights = recent.suffix(WorldTravelDayRule.maxFlights - 2).map { flight in
            TravelDayFlight(departure: flight.departure, arrival: flight.arrival,
                            originZone: zone(flight.from), destinationZone: zone(flight.to))
        }
        let keeper = worldLocation.flights
        if keeper.isFlying {
            flights.append(TravelDayFlight(departure: keeper.flightDeparted ?? now, arrival: nil,
                                           originZone: local, destinationZone: local))
        }
        if keeper.isOnTrip, let started = keeper.tripStartedAt {
            flights.append(TravelDayFlight(departure: started, arrival: nil, originZone: local, destinationZone: local))
        }
        return flights
    }

    // MARK: Today's plan

    /// Commits the Travel-day reset as today's plan (§13.2) and returns today's plan. A plan already committed
    /// today is kept as it is, and a day marked unwell keeps its rest plan: rest comes first.
    @discardableResult
    func commitTodaysTravelDayPlan() -> WorkoutProgram.DayPlan {
        if let plan = currentGuidedWorkoutPlan { return plan }
        let base = commitTodaysGuidedWorkoutPlan(intensity: .light)
        guard !needsRestToday else { return base }
        replaceGuidedWorkoutPlan(travelDayResetPlan(), replacing: Set(base.sessions.map(\.id)))
        return currentGuidedWorkoutPlan ?? base
    }

    /// The Travel-day reset built for the active space, the limits and the hidden exercises as they are
    /// now. What ``commitTodaysTravelDayPlan()`` commits, and what a change to one of the three rebuilds
    /// today's reset from (the owner's fix e4, `FernletStore+GuidedPlanLifetime.swift`).
    func travelDayResetPlan() -> WorkoutProgram.DayPlan {
        // Through the planner's own pool: limits and hidden exercises apply to the reset too (e2).
        let pool = WorkoutProgram.suggestablePool(
            in: WorkoutExerciseCatalog.allExercises, location: settings.activeWorkoutLocation,
            profile: settings.workoutProfile, preferences: settings.workoutExercisePreferences
        )
        return WorkoutPlanner.travelDayPlan(locationName: settings.activeWorkoutLocation.name, pool: pool,
                                            limits: settings.workoutProfile.injuryLimits)
    }

    /// "Lift instead, lighter" (§13.2): today's Travel-day reset gives way to the planner's light plan (a set
    /// fewer, no warm-up sets and no calibration test). Nil, changing nothing, once any of today's plan is logged.
    @discardableResult
    func liftInsteadOnTravelDay() -> WorkoutProgram.DayPlan? {
        guard let plan = currentGuidedWorkoutPlan, WorkoutPlanner.isTravelDayPlan(plan),
              reworkTodaysGuidedPlan() else { return nil }
        return commitTodaysGuidedWorkoutPlan(intensity: .light)
    }

    /// Whether today's committed plan is the Travel-day reset.
    var isTodaysPlanTravelDayReset: Bool {
        currentGuidedWorkoutPlan.map(WorkoutPlanner.isTravelDayPlan) ?? false
    }
}

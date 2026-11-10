// WorkoutProgram+Fill.swift
// FernletDomainModel
//
// What a lifting session does when its own slots leave it short (the owner's fix s3, 2026-11-10).
//
// A session used to fall back to one unfiltered line, "Full-body bodyweight circuit - 3 rounds", when
// no slot could be filled — push-ups and squats for the person whose severe wrist or knee had just
// emptied the session. Since every bundled exercise records the areas it loads (WorkoutAreaLoads.swift)
// that is no longer rare: a severe wrist empties Upper, Push, Chest, Back, Shoulders and Arms.
//
// Now, when fewer than ``WorkoutProgram/minimumLifts`` safe lifts remain:
// 1. each slot nothing could fill is given a safe lift for another body area, from the SAME filtered,
//    non-hidden pool, in the slot's own role (a main slot stays a main lift), and the session note says
//    so: "Arms day, worked around your elbow". Areas the split trains on its next day, and muscles that
//    worked hard yesterday, are taken last, so the fill does not spend tomorrow's session;
// 2. if that still leaves fewer than three, the lifting is not padded out: the session offers mobility
//    and an easy walk instead and says why in plain words. A severe ankle, knee or hip gets seated
//    mobility and no walk (``InjuryLimits/barsWalking``), and a hidden walk is not offered.
// Nothing here reads outside the filtered pool, so nothing it adds can be unsafe for the person.

import Foundation

extension WorkoutProgram {
    /// The fewest lifts a lifting session is planned with. Below it the session is filled from other
    /// body areas, and below it still the session becomes the mobility offer.
    public static let minimumLifts = 3

    /// The fewest lifts a session with these lifting slots may hold: ``minimumLifts``, or every slot
    /// when the template has fewer (Sport conditioning has two beside its drills).
    public static func minimumLifts(for slots: [WorkoutSlotSpec]) -> Int {
        min(minimumLifts, slots.count)
    }

    /// The frozen catalog name of the walk the offer adds, and the row the limits are asked about.
    static let easyWalkName = "Easy walk"
    /// The frozen head of the seated stretch line ("Seated mobility - 15 min"), which
    /// ``WorkoutTimedSessions`` times and ``WorkoutPlanLine`` draws.
    public static let seatedMobilityHead = "Seated mobility"
    /// The frozen head of the mobility line the offer opens with.
    static let mobilityFlowHead = "Mobility flow"
    /// The offer's lengths in minutes with no time budget: the stretches, then the walk.
    static let offerMobilityMinutes = 15
    /// See ``offerMobilityMinutes``.
    static let offerWalkMinutes = 20
    /// The stretches' length when a time budget is shorter than the whole offer.
    static let offerShortMobilityMinutes = 10

    /// The slots a short session is filled from, one per body area's work, in the order they are
    /// tried when nothing else separates them: the big compound movements first. Each is one of the
    /// session library's own slots, so its label draws through ``WorkoutSlotNames``; its role is the
    /// role of the slot it stands in for.
    static let fillSlots: [WorkoutSlotSpec] = [
        WorkoutSlotSpec(label: "Squat", role: .accessory, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Horizontal push", role: .accessory, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .accessory, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Hinge", role: .accessory, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Vertical push", role: .accessory, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Vertical pull", role: .accessory, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Calves", role: .accessory, movement: .isolation, muscles: [.calves]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Chest isolation", role: .accessory, movement: .isolation, muscles: [.chest]),
        WorkoutSlotSpec(label: "Traps", role: .accessory, movement: .isolation, muscles: [.traps]),
        WorkoutSlotSpec(label: "Forearms / grip", role: .accessory, movement: .isolation, muscles: [.forearms]),
        WorkoutSlotSpec(label: "Core", role: .accessory, muscles: [.abs, .obliques], region: .core),
    ]

    /// A session's lifting picks after the fill.
    struct SessionFill {
        /// The lifting picks in slot order, a fill pick standing where its empty slot was.
        var picks: [SlotPick]
        /// The labels of the template slots a fill pick stands in for.
        var replaced: [String] = []
        /// The labels of the fill picks standing in main slots: main lifts for the time budget.
        var mainLabels: Set<String> = []
    }

    /// `picks` (parallel to `slots`, nil where nothing could fill the slot) with every empty slot
    /// given a safe lift for another body area, when fewer than ``minimumLifts(for:)`` are filled.
    /// A session that already has enough is returned as it is, its empty slots still empty.
    static func filled(
        _ picks: [SlotPick?], slots: [WorkoutSlotSpec], inputs: SlotInputs, used: inout Set<String>
    ) -> SessionFill {
        let kept = picks.compactMap { $0 }
        guard picks.count == slots.count, kept.count < minimumLifts(for: slots) else { return SessionFill(picks: kept) }
        // Another body area: never a slot the session's own template already asks for.
        var candidates = fillSlots.filter { fill in !slots.contains { covers($0, fill) } }
        var result = SessionFill(picks: [])
        for index in slots.indices {
            if let pick = picks[index] {
                result.picks.append(pick)
                continue
            }
            let role: SlotRole = slots[index].role == .main ? .main : .accessory
            guard let fill = fillPick(from: candidates, role: role, inputs: inputs, used: &used) else { continue }
            candidates.removeAll { $0.label == fill.slot.label }
            result.picks.append(fill)
            result.replaced.append(slots[index].label)
            if role == .main { result.mainLabels.insert(fill.slot.label) }
        }
        return result
    }

    /// Whether a template slot already asks for the work a fill slot would add: the same movement
    /// for an overlapping muscle (or, for a slot that names no movement, the same muscles).
    static func covers(_ slot: WorkoutSlotSpec, _ fill: WorkoutSlotSpec) -> Bool {
        slot.movement == fill.movement && !slot.muscles.isDisjoint(with: fill.muscles)
    }

    /// The first fill slot, in ``fillOrder(_:role:inputs:)``, that something in the pool can fill,
    /// prescribed in `role` exactly as a template slot's pick is. Nil when nothing can.
    static func fillPick(
        from candidates: [WorkoutSlotSpec], role: SlotRole, inputs: SlotInputs, used: inout Set<String>
    ) -> SlotPick? {
        for candidate in fillOrder(candidates, role: role, inputs: inputs) {
            var slot = candidate
            slot.role = role
            if let pick = slotPick(for: slot, block: .lifting, inputs: inputs, used: &used) { return pick }
        }
        return nil
    }

    /// The fill slots in the order they are tried: first those for muscles the split is not about to
    /// train (its next day, ``SlotInputs/upcomingMuscles``) and that did not work hard yesterday;
    /// then, for a main slot, a compound movement before an isolation; then the list's own order.
    static func fillOrder(_ candidates: [WorkoutSlotSpec], role: SlotRole, inputs: SlotInputs) -> [WorkoutSlotSpec] {
        let resting = inputs.upcomingMuscles.union(inputs.recentHard)
        let keyed = candidates.enumerated().map { index, slot -> (rest: Int, fit: Int, index: Int, slot: WorkoutSlotSpec) in
            let rest = slot.muscles.isDisjoint(with: resting) ? 0 : 1
            let compound = slot.movement != nil && slot.movement != .isolation
            return (rest, role == .main && !compound ? 1 : 0, index, slot)
        }
        return keyed.sorted { ($0.rest, $0.fit, $0.index) < ($1.rest, $1.fit, $1.index) }.map(\.slot)
    }

    /// The injured areas that emptied `dropped`: for every exercise the location could run and one
    /// of those slots would have taken, the severe or mild areas that left it out. Most-blocking
    /// first, ties in the picker's order, two at most (the note names them). Empty when the slots
    /// were emptied by something else: the space's equipment, or exercises the person hid.
    static func blockingAreas(for dropped: [WorkoutSlotSpec], inputs: SlotInputs) -> [BodyArea] {
        guard !dropped.isEmpty, !inputs.blocked.isEmpty else { return [] }
        var counts: [BodyArea: Int] = [:]
        for exercise in inputs.blocked where dropped.contains(where: { isEligible(exercise, for: $0) }) {
            let areas = inputs.limits.severeAreas(loadedBy: exercise).union(inputs.limits.mildAreas(loadedHardBy: exercise))
            for area in areas { counts[area, default: 0] += 1 }
        }
        let order = BodyArea.allCases
        let ranked = order.indices.filter { counts[order[$0]] != nil }.sorted { lhs, rhs in
            let left = counts[order[lhs]] ?? 0
            let right = counts[order[rhs]] ?? 0
            return left != right ? left > right : lhs < rhs
        }
        return ranked.prefix(2).map { order[$0] }
    }

    /// The note for a filled session: "Arms day, worked around your elbow." when injured areas
    /// emptied its slots (`namesArea`), else that it was filled with what the space allows.
    static func fillNote(
        sessionTitle: String, dropped: [WorkoutSlotSpec], inputs: SlotInputs
    ) -> (text: String, namesArea: Bool) {
        let day = WorkoutSessionNames.drawn(sessionTitle)
        let areas = blockingAreas(for: dropped, inputs: inputs)
        guard !areas.isEmpty else { return (WorkoutPlannerCopy.filledForSpace(day: day), false) }
        return (WorkoutPlannerCopy.filledAround(day: day, areas: WorkoutPlannerCopy.areaList(areas)), true)
    }

    // MARK: - The pool

    /// The exercises the planner may suggest to this person in this space: the location has the
    /// tools, the injury limits allow them, and the person has not hidden them ("Don't suggest
    /// this"). The one pool every surface that picks exercises reads — the day plan, the Mobility
    /// flow and the gentle stretch a run builds, the Travel-day reset — so hidden means hidden
    /// everywhere (the owner's fix e6, 2026-11-10: the stretch sessions used to skip the hidden list).
    public static func suggestablePool(
        in catalog: [ExerciseTarget], location: WorkoutLocation, profile: WorkoutProfile,
        preferences: WorkoutExercisePreferences
    ) -> [ExerciseTarget] {
        let safe = WorkoutSafetyFilter.feasibleExercises(in: catalog, location: location, profile: profile)
        return splitHidden(safe, preferences: preferences).shown
    }

    // MARK: - The mobility offer

    /// What a session offers in place of lifting it cannot safely fill.
    struct MobilityOffer {
        /// The offer's descriptor lines as plan steps, which the runner times when the run starts.
        var steps: [PrescribedExercise]
        /// The note saying what is offered and why.
        var note: String
    }

    /// The offer for a session titled `sessionTitle`: a mobility flow and an easy walk; seated
    /// mobility alone when a severe ankle, knee or hip rules the walk out; the flow alone when the
    /// person hid the walk. Fitted to the session's time budget.
    static func mobilityOffer(sessionTitle: String, inputs: SlotInputs) -> MobilityOffer {
        let day = WorkoutSessionNames.drawn(sessionTitle)
        let budget = inputs.options.length.minutes
        if inputs.limits.barsWalking {
            let minutes = min(offerMobilityMinutes, budget ?? offerMobilityMinutes)
            return MobilityOffer(steps: [offerStep("\(seatedMobilityHead) - \(minutes) min")],
                                 note: WorkoutPlannerCopy.offerSeatedMobility(day: day))
        }
        let whole = offerMobilityMinutes + offerWalkMinutes
        let mobility = (budget ?? whole) < whole ? offerShortMobilityMinutes : offerMobilityMinutes
        let flow = offerStep("\(mobilityFlowHead) - \(mobility) min")
        let walkHidden = inputs.hiddenFeasible.contains { $0.name == easyWalkName }
        let walk = min(offerWalkMinutes, (budget ?? whole) - mobility)
        guard !walkHidden, walk > 0 else {
            return MobilityOffer(steps: [flow], note: WorkoutPlannerCopy.offerMobility(day: day))
        }
        return MobilityOffer(steps: [flow, offerStep("\(easyWalkName) - \(walk) min", block: .cardio)],
                             note: WorkoutPlannerCopy.offerMobilityAndWalk(day: day))
    }

    /// One of the offer's descriptor lines as a plan step (never a catalog exercise: the runner
    /// builds its stretches or its countdown from the line).
    static func offerStep(_ text: String, block: SessionBlock = .lifting) -> PrescribedExercise {
        PrescribedExercise(name: text, sets: 0, reps: "", role: .accessory, fromCatalog: false, block: block)
    }

    /// Whether `session` is the mobility offer: nothing from the catalog, and a mobility line first.
    public static func isMobilityOffer(_ session: SessionSuggestion) -> Bool {
        guard session.kind == .mobility, let first = session.exercises.first, !first.fromCatalog else { return false }
        let head = WorkoutTimedSessions.label(of: first.name)
        return head == seatedMobilityHead || (head == mobilityFlowHead && session.title != WorkoutSessions.mobility.title)
    }

    /// A cardio session's line when its generic cardio would be a walk or a machine the person's
    /// limits rule out: seated mobility for the same minutes (at most ``offerMobilityMinutes`` when
    /// the line names none), with the note saying so. Nil when `line` already names a machine the
    /// pool holds, is not a generic cardio line, or walking is not ruled out.
    static func seatedInsteadOfCardio(_ line: String, inputs: SlotInputs) -> (text: String, note: String)? {
        guard inputs.limits.barsWalking, WorkoutCardioMachines.effort(of: line) != nil else { return nil }
        let named = descriptorMinutes(in: line) ?? offerMobilityMinutes
        let minutes = min(named, offerWalkMinutes)
        return ("\(seatedMobilityHead) - \(minutes) min", WorkoutPlannerCopy.cardioSwappedForSeatedMobility)
    }
}

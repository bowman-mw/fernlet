// WorkoutPlannerCopy+Load.swift
// FernletDomainModel
//
// The load pass's note sentences (``WorkoutProgram/progressNotes(_:)``, the plateau story, the
// calibration brief and the rep ladder), as String Catalog keys (2026-10-20, idea 16). Tone, per the
// owner: plateaus are normal and a lighter day is training too — nothing here ever says "you failed".
// Where a sentence used to splice in an optional " (25 lb)", it is now two whole sentences, so a
// translator never sees half of one.

import Foundation

extension WorkoutPlannerCopy {

    // MARK: - Ordinary progression

    /// The line for lifts that still need a first weight.
    static var newLifts: String {
        String(localized: "workoutNote.load.newLifts",
               defaultValue: "New lifts: pick a weight you could lift about 2 more times than asked — Fernlet learns from there.",
               bundle: .module,
               comment: "Workout session note: some lifts have no weight history yet; how to choose a first weight")
    }

    /// "Bench press: the range now centers on the weights you've been choosing."
    static func recentered(_ name: String) -> String {
        String(localized: "workoutNote.load.recentered",
               defaultValue: "\(name): the range now centers on the weights you've been choosing.", bundle: .module,
               comment: "Workout session note about one lift: its suggested weight range moved to match what the person has been lifting. The argument is the exercise name.")
    }

    /// "Bench press: 9 reps today, one more than last time."
    static func moreReps(_ name: String, reps: Int) -> String {
        String(localized: "workoutNote.load.moreReps",
               defaultValue: "\(name): \(repCount(reps)) today, one more than last time.", bundle: .module,
               comment: "Workout session note about one lift. Arguments: the exercise name, then a number of reps (e.g. '9 reps').")
    }

    /// "Bench press: one more set today."
    static func moreSets(_ name: String) -> String {
        String(localized: "workoutNote.load.moreSets", defaultValue: "\(name): one more set today.", bundle: .module,
               comment: "Workout session note about one lift: one extra set today. The argument is the exercise name.")
    }

    /// "Bench press: up to 105 lb today."
    static func addWeight(_ name: String, weight: String) -> String {
        String(localized: "workoutNote.load.addWeight", defaultValue: "\(name): up to \(weight) today.", bundle: .module,
               comment: "Workout session note about one lift: the weight goes up today. Arguments: the exercise name, then a weight with its unit (e.g. '105 lb').")
    }

    /// "Bench press: back to 8 reps — add weight now (105 lb)."
    static func backToBottom(_ name: String, reps: Int, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.load.backToBottom",
                          defaultValue: "\(name): back to \(repCount(reps)) — add weight now.", bundle: .module,
                          comment: "Workout session note about one lift: the reps reset to the bottom of the range because it is time to add weight. Arguments: the exercise name, then a number of reps (e.g. '8 reps').")
        }
        return String(localized: "workoutNote.load.backToBottomAt",
                      defaultValue: "\(name): back to \(repCount(reps)) — add weight now (\(weight)).", bundle: .module,
                      comment: "Workout session note about one lift: the reps reset to the bottom of the range because it is time to add weight. Arguments: the exercise name, a number of reps (e.g. '8 reps'), and the new weight with its unit.")
    }

    /// "Bench press: a little lighter today (95 lb) to get the reps back."
    static func lighter(_ name: String, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.load.lighter",
                          defaultValue: "\(name): a little lighter today to get the reps back.", bundle: .module,
                          comment: "Workout session note about one lift: a lighter weight today because the reps fell short last time. The argument is the exercise name.")
        }
        return String(localized: "workoutNote.load.lighterAt",
                      defaultValue: "\(name): a little lighter today (\(weight)) to get the reps back.", bundle: .module,
                      comment: "Workout session note about one lift: a lighter weight today because the reps fell short last time. Arguments: the exercise name, then the weight with its unit.")
    }

    /// "Bench press: the same again today — one more session like the last, and it moves on."
    static func confirming(_ name: String) -> String {
        String(localized: "workoutNote.load.confirming",
               defaultValue: "\(name): the same again today — one more session like the last, and it moves on.",
               bundle: .module,
               comment: "Workout session note about one lift for someone past their first months of lifting: progress comes after two good sessions in a row, so today repeats the last one. The argument is the exercise name.")
    }

    /// N7: "If you'd like a harder step for Goblet squat, Bulgarian split squat works the same muscles
    /// — it's the first swap when you edit the plan. Otherwise more reps, then a set, keep it moving."
    static func harderVariation(_ variant: String, lift: String) -> String {
        String(localized: "workoutNote.load.harderVariation",
               defaultValue: "If you'd like a harder step for \(lift), \(variant) works the same muscles — it's the first swap when you edit the plan. Otherwise more reps, then a set, keep it moving.",
               bundle: .module,
               comment: "Workout session note: a lift is at the heaviest weight this place has, so a harder version of it is offered, never required. Arguments: the lift, then the harder exercise.")
    }

    /// The block calendar's line (G2): "Heavier block, week 2 of 4: main lifts are 5 sets of 3 reps —
    /// fewer reps at more weight, then back to volume."
    static func block(_ phase: BlockPhase, week: Int, of weeks: Int, sets: Int, reps: Int) -> String {
        let current = week.formatted()
        let total = weeks.formatted()
        switch phase {
        case .volume:
            return String(localized: "workoutNote.block.volume",
                          defaultValue: "Volume block, week \(current) of \(total): main lifts are \(setCount(sets)) of \(repCount(reps)) — more work at a moderate weight, then a heavier block.",
                          bundle: .module,
                          comment: "Workout session note for a trained strength lifter's planned block. Arguments: the week of the block (digits), the block's length in weeks (digits), a number of sets (e.g. '4 sets'), then a number of reps (e.g. '6 reps').")
        case .heavier:
            return String(localized: "workoutNote.block.heavier",
                          defaultValue: "Heavier block, week \(current) of \(total): main lifts are \(setCount(sets)) of \(repCount(reps)) — fewer reps at more weight, then back to volume.",
                          bundle: .module,
                          comment: "Workout session note for a trained strength lifter's planned block. Arguments: the week of the block (digits), the block's length in weeks (digits), a number of sets (e.g. '5 sets'), then a number of reps (e.g. '3 reps').")
        }
    }

    /// "Bench press: lighter and one set fewer today — a reset, not a step back."
    static func lighterFewerSets(_ name: String) -> String {
        String(localized: "workoutNote.load.lighterFewerSets",
               defaultValue: "\(name): lighter and one set fewer today — a reset, not a step back.", bundle: .module,
               comment: "Workout session note about one lift: a lighter, shorter day after several hard sessions. The argument is the exercise name.")
    }

    /// "Bench press: welcome back — a little lighter to start (95 lb)."
    static func afterBreak(_ name: String, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.load.afterBreak",
                          defaultValue: "\(name): welcome back — a little lighter to start.", bundle: .module,
                          comment: "Workout session note about one lift after a break from training: start a little lighter. The argument is the exercise name.")
        }
        return String(localized: "workoutNote.load.afterBreakAt",
                      defaultValue: "\(name): welcome back — a little lighter to start (\(weight)).", bundle: .module,
                      comment: "Workout session note about one lift after a break from training: start a little lighter. Arguments: the exercise name, then the weight with its unit.")
    }

    /// "Bench press: starting from a fresh estimate (100 lb)."
    static func recalibrated(_ name: String, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.load.recalibrated",
                          defaultValue: "\(name): starting from a fresh estimate.", bundle: .module,
                          comment: "Workout session note about one lift: its weight now comes from a new strength estimate. The argument is the exercise name.")
        }
        return String(localized: "workoutNote.load.recalibratedAt",
                      defaultValue: "\(name): starting from a fresh estimate (\(weight)).", bundle: .module,
                      comment: "Workout session note about one lift: its weight now comes from a new strength estimate. Arguments: the exercise name, then the weight with its unit.")
    }

    /// The lift hurt last time, so its weight holds.
    static func holdForPain(_ name: String) -> String {
        String(localized: "workoutNote.load.holdForPain",
               defaultValue: "\(name): holding steady after it hurt last time. If it still hurts, try a different exercise or check with a professional.",
               bundle: .module,
               comment: "Workout session note about one lift the person reported pain on: the weight stays the same. The argument is the exercise name.")
    }

    /// The equipment has no next load, so the lift adds a rep at the same weight.
    static func holdForEquipment(_ name: String) -> String {
        String(localized: "workoutNote.load.holdForEquipment",
               defaultValue: "\(name): same weight, one more rep — working with the equipment you have.", bundle: .module,
               comment: "Workout session note about one lift: the person's weights can't go up a step, so add a rep instead. The argument is the exercise name.")
    }

    // MARK: - Weights on hand (idea 10)

    /// "Dumbbell press: 25 lb would be a big jump from 20 lb, so add reps first — 13 today."
    static func repsFirstBigJump(_ name: String, next: String, from current: String, reps: Int) -> String {
        String(localized: "workoutNote.load.repsFirstBigJump",
               defaultValue: "\(name): \(next) would be a big jump from \(current), so add reps first — \(reps) today.",
               bundle: .module,
               comment: "Workout session note about one lift: the next weight is too big a step, so reps go up first. Arguments: the exercise name, the next weight, the current weight (both with units), and today's number of reps.")
    }

    /// "Dumbbell press: your next dumbbell is 25 lb, so add reps first — 13 today."
    static func repsFirstNext(_ name: String, nextLoad: String, reps: Int) -> String {
        String(localized: "workoutNote.load.repsFirstNext",
               defaultValue: "\(name): \(nextLoad), so add reps first — \(reps) today.", bundle: .module,
               comment: "Workout session note about one lift. Arguments: the exercise name, a clause naming the next weight the person owns (e.g. 'your next dumbbell is 25 lb'), and today's number of reps.")
    }

    /// "Dumbbell press: 25 lb is your heaviest dumbbell, so more reps instead — 13 today."
    static func repsFirstHeaviest(_ name: String, heaviest: String, reps: Int) -> String {
        String(localized: "workoutNote.load.repsFirstHeaviest",
               defaultValue: "\(name): \(heaviest), so more reps instead — \(reps) today.", bundle: .module,
               comment: "Workout session note about one lift. Arguments: the exercise name, a clause saying the person's heaviest weight is reached (e.g. '25 lb is your heaviest dumbbell'), and today's number of reps.")
    }

    /// "Dumbbell press: one more set today, then up to 25 lb."
    static func setFirstNext(_ name: String, load: String) -> String {
        String(localized: "workoutNote.load.setFirstNext",
               defaultValue: "\(name): one more set today, then up to \(load).", bundle: .module,
               comment: "Workout session note about one lift: an extra set comes before the next weight. Arguments: the exercise name, then the next weight with its unit.")
    }

    /// "Dumbbell press: one more set today — 25 lb is your heaviest dumbbell."
    static func setFirstHeaviest(_ name: String, heaviest: String) -> String {
        String(localized: "workoutNote.load.setFirstHeaviest",
               defaultValue: "\(name): one more set today — \(heaviest).", bundle: .module,
               comment: "Workout session note about one lift. Arguments: the exercise name, then a clause saying the person's heaviest weight is reached (e.g. '25 lb is your heaviest dumbbell').")
    }

    /// "your next dumbbell is 25 lb", by the gear the lift is loaded with.
    static func nextLoad(_ load: String, equipment: Equipment?) -> String {
        switch equipment {
        case .dumbbell:
            String(localized: "workoutNote.load.nextDumbbell", defaultValue: "your next dumbbell is \(load)", bundle: .module,
                   comment: "Clause inside a workout session note, after the exercise name and a colon. The argument is a weight with its unit.")
        case .kettlebell:
            String(localized: "workoutNote.load.nextKettlebell", defaultValue: "your next kettlebell is \(load)", bundle: .module,
                   comment: "Clause inside a workout session note, after the exercise name and a colon. The argument is a weight with its unit.")
        default:
            String(localized: "workoutNote.load.nextBarLoad", defaultValue: "the next load your bar and plates make is \(load)",
                   bundle: .module,
                   comment: "Clause inside a workout session note, after the exercise name and a colon. The argument is a weight with its unit.")
        }
    }

    /// "25 lb is your heaviest dumbbell", by the gear the lift is loaded with.
    static func heaviest(_ load: String, equipment: Equipment?) -> String {
        switch equipment {
        case .dumbbell:
            String(localized: "workoutNote.load.heaviestDumbbell", defaultValue: "\(load) is your heaviest dumbbell", bundle: .module,
                   comment: "Clause inside a workout session note. The argument is a weight with its unit.")
        case .kettlebell:
            String(localized: "workoutNote.load.heaviestKettlebell", defaultValue: "\(load) is your heaviest kettlebell", bundle: .module,
                   comment: "Clause inside a workout session note. The argument is a weight with its unit.")
        default:
            String(localized: "workoutNote.load.heaviestBarLoad", defaultValue: "\(load) is the most your bar and plates make",
                   bundle: .module,
                   comment: "Clause inside a workout session note. The argument is a weight with its unit.")
        }
    }

    // MARK: - The rep ladder (no load history)

    /// The fixed-rep scheme's line.
    static var sameReps: String {
        String(localized: "workoutNote.ladder.sameReps",
               defaultValue: "Same reps as last time — nudge the weight up a little when the last set feels solid.",
               bundle: .module,
               comment: "Workout session note: keep the same reps; add a little weight when it feels easy")
    }

    /// "Back to 8 reps — add weight now, about 2.5–5%."
    static func ladderBackTo(reps: Int) -> String {
        String(localized: "workoutNote.ladder.backTo",
               defaultValue: "Back to \(repCount(reps)) — add weight now, about 2.5–5%.", bundle: .module,
               comment: "Workout session note: the reps reset to the bottom of the range and the weight goes up a little. The argument is a number of reps (e.g. '8 reps').")
    }

    /// "Rep ladder: 9 of 8–12 today. One more rep each time; at 12, add weight."
    static func repLadder(reps: Int, low: Int, high: Int) -> String {
        String(localized: "workoutNote.ladder.climb",
               defaultValue: "Rep ladder: \(reps) of \(low)–\(high) today. One more rep each time; at \(high), add weight.",
               bundle: .module,
               comment: "Workout session note: where today's reps sit in the rep range. Arguments: today's reps, the bottom of the range, the top of the range, and the top again (when to add weight).")
    }
}

// WorkoutPlannerCopy+Plateau.swift
// FernletDomainModel
//
// The plateau story, the rest check, the variation and support-work lines, and the calibration brief,
// as String Catalog keys (2026-10-20, idea 16). The copy says plateaus are normal; it never says "you
// failed".

import Foundation

extension WorkoutPlannerCopy {

    // MARK: - The plateau story

    /// "Bench press has held steady for 3 weeks. That's normal — …", or "for a few sessions" under two
    /// weeks.
    static func plateauLead(_ name: String, weeks: Int) -> String {
        guard weeks >= 2 else {
            return String(localized: "workoutNote.plateau.leadSessions",
                          defaultValue: "\(name) has held steady for a few sessions. That's normal — strength comes in steps, and a pause often means your body wants more recovery.",
                          bundle: .module,
                          comment: "Workout session note opening the plateau story for one lift. The argument is the exercise name.")
        }
        return String(localized: "workoutNote.plateau.leadWeeks",
                      defaultValue: "\(name) has held steady for \(weekCount(weeks)). That's normal — strength comes in steps, and a pause often means your body wants more recovery.",
                      bundle: .module,
                      comment: "Workout session note opening the plateau story for one lift. Arguments: the exercise name, then a number of weeks (e.g. '3 weeks').")
    }

    /// "Today is an easier Bench press session: 2 sets at about 95 lb. An extra rest day instead is
    /// fine too — both count as training."
    static func easierSession(_ name: String, sets: Int, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.plateau.easier",
                          defaultValue: "Today is an easier \(name) session: \(setCount(sets)), lighter than usual. An extra rest day instead is fine too — both count as training.",
                          bundle: .module,
                          comment: "Workout session note: a lighter day for a lift that has stalled. Arguments: the exercise name, then a number of sets (e.g. '2 sets').")
        }
        return String(localized: "workoutNote.plateau.easierAt",
                      defaultValue: "Today is an easier \(name) session: \(setCount(sets)) at about \(weight). An extra rest day instead is fine too — both count as training.",
                      bundle: .module,
                      comment: "Workout session note: a lighter day for a lift that has stalled. Arguments: the exercise name, a number of sets (e.g. '2 sets'), and a weight with its unit.")
    }

    /// The extra rest a stalled lift gets between sets: "+1 min" on a main lift, "+30 s" otherwise.
    static func extraRest(mainLift: Bool) -> String {
        guard mainLift else {
            return String(localized: "workoutNote.plateau.extraRestAccessory", defaultValue: "+30 s", bundle: .module,
                          comment: "Extra rest between sets, inside a workout session note: thirty more seconds")
        }
        return String(localized: "workoutNote.plateau.extraRestMain", defaultValue: "+1 min", bundle: .module,
                      comment: "Extra rest between sets, inside a workout session note: one more minute")
    }

    /// "Bench press goes first today, with a little more rest between sets (+1 min)."
    static func recoverFirst(_ name: String, rest: String) -> String {
        String(localized: "workoutNote.plateau.goesFirst",
               defaultValue: "\(name) goes first today, with a little more rest between sets (\(rest)).", bundle: .module,
               comment: "Workout session note about a stalled lift. Arguments: the exercise name, then the extra rest (e.g. '+1 min').")
    }

    /// "A little more rest between Bench press sets (+1 min)."
    static func supportRest(_ name: String, rest: String) -> String {
        String(localized: "workoutNote.plateau.moreRest",
               defaultValue: "A little more rest between \(name) sets (\(rest)).", bundle: .module,
               comment: "Workout session note about a stalled lift. Arguments: the exercise name, then the extra rest (e.g. '+1 min').")
    }

    /// "Back to Bench press, with a little more rest between sets (+1 min)."
    static func afterVariation(_ name: String, rest: String) -> String {
        String(localized: "workoutNote.plateau.backTo",
               defaultValue: "Back to \(name), with a little more rest between sets (\(rest)).", bundle: .module,
               comment: "Workout session note: a stalled lift returns after a few weeks of a different exercise. Arguments: the exercise name, then the extra rest (e.g. '+1 min').")
    }

    /// The rest check's sleep line. `hours` arrives formatted for the device's locale ("6.5").
    static func sleepLow(hours: String) -> String {
        String(localized: "workoutNote.plateau.sleepLow",
               defaultValue: "Sleep has averaged \(hours) hours these past two weeks. More sleep is often the quickest way through.",
               bundle: .module,
               comment: "Workout session note in the plateau story, said only when sleep ran low. The argument is the average hours of sleep with one decimal, e.g. '6.5'.")
    }

    /// The rest check's protein line.
    static func proteinLow(percent: Int) -> String {
        String(localized: "workoutNote.plateau.proteinLow",
               defaultValue: "Protein has run about \(percent)% of your target lately — a little more helps muscles rebuild.",
               bundle: .module,
               comment: "Workout session note in the plateau story, said only when protein ran low. The argument is a whole percentage of the person's protein target.")
    }

    /// "Goblet squat stands in for Back squat for a few weeks — a fresh angle often gets things moving."
    static func standsIn(_ stand: String, for original: String) -> String {
        String(localized: "workoutNote.plateau.variation",
               defaultValue: "\(stand) stands in for \(original) for a few weeks — a fresh angle often gets things moving.",
               bundle: .module,
               comment: "Workout session note: a different exercise replaces a stalled lift for a few weeks. Arguments: the replacement exercise, then the stalled one.")
    }

    /// "For a few weeks, Close-grip bench press takes an accessory spot to build up the muscles that
    /// help your Bench press."
    static func supportSwap(_ support: String, helping stalled: String) -> String {
        String(localized: "workoutNote.plateau.support",
               defaultValue: "For a few weeks, \(support) takes an accessory spot to build up the muscles that help your \(stalled).",
               bundle: .module,
               comment: "Workout session note: an extra exercise builds the helper muscles of a stalled lift. Arguments: the extra exercise, then the stalled lift.")
    }

    // MARK: - The calibration brief

    /// The note for a calibration session, by kind. `weight` is the key set's load with its unit.
    static func calibration(_ kind: CalibrationKind, lift: String, weight: String) -> String {
        switch kind {
        case .submaximal:
            String(localized: "workoutNote.calibration.submaximal",
                   defaultValue: "Strength check today: \(lift) builds up over a few lighter sets, then one test set at \(weight) — as many good reps as you can, stopping with 1–2 left. Accessories are a set lighter.",
                   bundle: .module,
                   comment: "Workout session note for the monthly strength check. Arguments: the exercise name, then the test set's weight with its unit.")
        case .strengthCheck:
            String(localized: "workoutNote.calibration.strengthCheck",
                   defaultValue: "Quick strength check today: one \(lift) set at \(weight) for as many good reps as you can, stopping with 1–2 left — edit the reps when you're done. Accessories are a set lighter.",
                   bundle: .module,
                   comment: "Workout session note for the quick monthly strength check. Arguments: the exercise name, then the set's weight with its unit.")
        case .oneRepMax:
            String(localized: "workoutNote.calibration.oneRepMax",
                   defaultValue: "Max test today: \(lift) builds up to three single attempts, starting at \(weight). Use a spotter or safety arms, stop if your form breaks, and skip it if you're sore, sick or short on sleep. Miss one and the rest are skipped.",
                   bundle: .module,
                   comment: "Workout session note for an opt-in one-rep-max test. Arguments: the exercise name, then the first attempt's weight with its unit.")
        }
    }
}

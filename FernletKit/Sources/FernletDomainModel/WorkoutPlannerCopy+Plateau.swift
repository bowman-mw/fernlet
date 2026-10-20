// WorkoutPlannerCopy+Plateau.swift
// FernletDomainModel
//
// The trend story — the plateau ladder (a fair retest, a heavier block, a variant beside the lift,
// holding steady), the dip's deload, the slowing and too-early notes and their sleep or light-day
// context — and the calibration brief, as String Catalog keys (2026-10-20). The copy says plateaus are
// normal and a dip happens; it never says "you failed", and a short night is something that came
// before a session, never a fault.

import Foundation

extension WorkoutPlannerCopy {

    // MARK: - The trend story

    /// "Bench press has held steady for 3 weeks. That's normal — strength comes in steps.", or "for a
    /// few sessions" under two weeks.
    static func plateauLead(_ name: String, weeks: Int) -> String {
        guard weeks >= 2 else {
            return String(localized: "workoutNote.plateau.leadSessions",
                          defaultValue: "\(name) has held steady for a few sessions. That's normal — strength comes in steps.",
                          bundle: .module,
                          comment: "Workout session note opening the plateau story for one lift. The argument is the exercise name.")
        }
        return String(localized: "workoutNote.plateau.leadWeeks",
                      defaultValue: "\(name) has held steady for \(weekCount(weeks)). That's normal — strength comes in steps.",
                      bundle: .module,
                      comment: "Workout session note opening the plateau story for one lift. Arguments: the exercise name, then a number of weeks (e.g. '3 weeks').")
    }

    /// The ladder's first step: "Today Bench press goes first, with at least 3 minutes' rest between
    /// sets — a fair retest."
    static func fairRetest(_ name: String) -> String {
        String(localized: "workoutNote.plateau.retest",
               defaultValue: "Today \(name) goes first, with at least 3 minutes' rest between sets — a fair retest.",
               bundle: .module,
               comment: "Workout session note for a lift that has held steady: it moves to the start of the session with longer rest, to give it a fair try. The argument is the exercise name.")
    }

    /// The loading change: "For the next few sessions, Bench press goes a little heavier for fewer
    /// reps — 6 reps at about 145 lb. One more Bench press day a week works too, if you'd like."
    static func heavierBlock(_ name: String, reps: Int, weight: String) -> String {
        String(localized: "workoutNote.plateau.heavierBlock",
               defaultValue: "For the next few sessions, \(name) goes a little heavier for fewer reps — \(repCount(reps)) at about \(weight). One more \(name) day a week works too, if you'd like.",
               bundle: .module,
               comment: "Workout session note for a lift that has held steady: a short block of heavier, lower-rep work. Arguments: the exercise name, a number of reps (e.g. '6 reps'), a weight with its unit, then the exercise name again.")
    }

    /// The loading change on a lift with no load (or no estimate yet): one more set.
    static func extraSet(_ name: String) -> String {
        String(localized: "workoutNote.plateau.extraSet",
               defaultValue: "For the next few sessions, \(name) gets one more set. One more \(name) day a week works too, if you'd like.",
               bundle: .module,
               comment: "Workout session note for a lift that has held steady and takes no added weight: one more set for a while. Both arguments are the exercise name.")
    }

    /// The variant beside the lift: "For a few weeks, Close-grip bench press joins Bench press, which
    /// keeps going with one set fewer — a fresh angle often gets things moving."
    static func variantBeside(_ variant: String, lift: String) -> String {
        String(localized: "workoutNote.plateau.variantBeside",
               defaultValue: "For a few weeks, \(variant) joins \(lift), which keeps going with one set fewer — a fresh angle often gets things moving.",
               bundle: .module,
               comment: "Workout session note: a related exercise is added beside a lift that has held steady; the lift stays in the plan. Arguments: the added exercise, then the lift.")
    }

    /// The ladder's last step, by goal: calm, with options and no push.
    static func holdingSteady(_ name: String, goal: GoalType) -> String {
        switch goal {
        case .strength, .sportsPrep:
            String(localized: "workoutNote.plateau.holdingSteady.strength",
                   defaultValue: "\(name) is holding steady, and steady is fine. Keep training it as it is, try a different rep range for a while, or give another lift the spotlight — whichever suits you.",
                   bundle: .module,
                   comment: "Workout session note for a strength-focused person whose lift has held steady for a long while. The argument is the exercise name.")
        case .wellness, .weightManagement, .mentalHealth, .recovery, .exploring:
            String(localized: "workoutNote.plateau.holdingSteady",
                   defaultValue: "\(name) is holding steady, and that's a good place to be. Keep training it as it is, or change it up whenever you like.",
                   bundle: .module,
                   comment: "Workout session note for a lift that has held steady for a long while, for a person not training mainly for strength. The argument is the exercise name.")
        }
    }

    /// A dip's first line: "Back squat came in a little lower the last two times. That happens, and it
    /// usually passes."
    static func dipLead(_ name: String) -> String {
        String(localized: "workoutNote.plateau.dipLead",
               defaultValue: "\(name) came in a little lower the last two times. That happens, and it usually passes.",
               bundle: .module,
               comment: "Workout session note: a lift's last two sessions were clearly below its usual level. The argument is the exercise name.")
    }

    /// The deload: "Today is a lighter Back squat session: 2 sets at the usual weight, about 185 lb.
    /// That's often all it takes."
    static func deload(_ name: String, sets: Int, weight: String?) -> String {
        guard let weight else {
            return String(localized: "workoutNote.plateau.deload",
                          defaultValue: "Today is a lighter \(name) session: \(setCount(sets)) instead of the usual. That's often all it takes.",
                          bundle: .module,
                          comment: "Workout session note: a lighter session after two lower ones, with fewer sets. Arguments: the exercise name, then a number of sets (e.g. '2 sets').")
        }
        return String(localized: "workoutNote.plateau.deloadAt",
                      defaultValue: "Today is a lighter \(name) session: \(setCount(sets)) at the usual weight, about \(weight). That's often all it takes.",
                      bundle: .module,
                      comment: "Workout session note: a lighter session after two lower ones, with fewer sets and the weight kept. Arguments: the exercise name, a number of sets (e.g. '2 sets'), then a weight with its unit.")
    }

    /// The slowing note: soft, and the plan stays.
    static func slowing(_ name: String) -> String {
        String(localized: "workoutNote.plateau.slowing",
               defaultValue: "\(name) is coming along more slowly now, which is the normal curve as strength builds. Today's plan stays as it is.",
               bundle: .module,
               comment: "Workout session note: a lift is still improving but more slowly than before. The argument is the exercise name.")
    }

    /// Too early to read the trend: half or more of the recent sessions were flagged.
    static func tooEarly(_ name: String) -> String {
        String(localized: "workoutNote.plateau.tooEarly",
               defaultValue: "Many recent \(name) sessions came after a short night or fell on a light day, so it's too early to read how it's going. Today's plan stays as it is.",
               bundle: .module,
               comment: "Workout session note: most recent sessions of a lift followed a short night or were on a light day, so its progress can't be read yet. The argument is the exercise name.")
    }

    /// "3 of the last 8 sessions came after a short night, which can take a little off a session."
    static func shortNightContext(_ count: Int, of window: Int) -> String {
        let flagged = count.formatted()
        return String(localized: "workoutNote.plateau.shortNightContext",
                      defaultValue: "\(flagged) of the last \(sessionCount(window)) came after a short night, which can take a little off a session.",
                      bundle: .module,
                      comment: "Workout session note giving context to a lift's progress. Arguments: a number written as digits (e.g. '3'), then a number of sessions (e.g. '8 sessions').")
    }

    /// "2 of the last 8 sessions fell on a light day, which can take a little off a session."
    static func lightDayContext(_ count: Int, of window: Int) -> String {
        let flagged = count.formatted()
        return String(localized: "workoutNote.plateau.lightDayContext",
                      defaultValue: "\(flagged) of the last \(sessionCount(window)) fell on a light day, which can take a little off a session.",
                      bundle: .module,
                      comment: "Workout session note giving context to a lift's progress: some sessions were on days the person chose or was offered as light. Arguments: a number written as digits (e.g. '2'), then a number of sessions (e.g. '8 sessions').")
    }

    /// The rest check's protein line.
    static func proteinLow(percent: Int) -> String {
        String(localized: "workoutNote.plateau.proteinLow",
               defaultValue: "Protein has run about \(percent)% of your target lately — a little more helps muscles rebuild.",
               bundle: .module,
               comment: "Workout session note in the plateau story, said only when protein ran low. The argument is a whole percentage of the person's protein target.")
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

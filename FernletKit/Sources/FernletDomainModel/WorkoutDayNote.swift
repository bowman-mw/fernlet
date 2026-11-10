// WorkoutDayNote.swift
// FernletDomainModel
//
// "Anything else?" on the plan sheet, read for today only (the owner's fix e3, 2026-11-10).
//
// The text used to do one thing: add a few points to exercises whose name shared a word with it,
// under a note that said "Noted: …". So "sore left knee" protected nothing, "short on time"
// shortened nothing, and "my shoulder hurts" pulled a shoulder press IN. Now the text is read the
// way the saved injury note is read (``InjuryNoteMatcher``), for this one plan:
//
// - **A body area it names is trained around today**: the Mild treatment — the heavy end of the
//   area's work left out, the rest eased, no calibration on it. A muscle word the matcher knows
//   ("hamstring", "calf", "chest") counts as its nearest area, as the saved note's newer words do.
//   The saved limits are only ever added to: an area saved as Severe stays left out, and nothing
//   here is written to the profile.
// - **A time phrase asks for a short session**: "short on time", "quick", "in a hurry" pick the
//   shortest length; "only 30 minutes" picks the longest length that fits. Only when the person did
//   not choose a length on the sheet, and never a longer session than the one already set.
// - **The name-word nudge stays, where it cannot contradict the above**: a word that names a body
//   part never pulls an exercise in, and a note that reads as a complaint ("sore", "tired", "no")
//   nudges nothing at all.
//
// The plan's note then says each thing that was applied, a sentence each (``lines(for:)``), or says
// that nothing could be applied and points to Equipment & limits.
//
// The vocabulary is FROZEN English matching input (the localization wall), exactly as the saved
// injury note's is: a note typed in another language matches nothing here, and the plan says so.

import Foundation

/// What the plan sheet's "Anything else?" asks of today's plan, read from its text.
///
/// Pure and deterministic; bounded by ``InjuryNoteMatcher/maxWords``. Read once per plan
/// (``WorkoutDayNote/Applied``); never stored on the profile.
public nonisolated struct WorkoutDayNote: Equatable, Sendable {
    /// Body areas the note names — each trained around today (Mild). A muscle word counts as its
    /// nearest area (``nearestArea(of:)``).
    public var areas: Set<BodyArea>
    /// The longest the session may run, in minutes, when the note asks for a short one: the number
    /// it gives, or ``shortestMinutes`` for a phrase without one. Nil when it says nothing of time.
    public var minutes: Int?
    /// Words that may nudge the pick toward an exercise whose name shares one. Empty when the note
    /// reads as a complaint; never a word that names a body part.
    public var nudgeWords: Set<String>
    /// True when the text has anything in it at all.
    public var hasText: Bool

    public init(areas: Set<BodyArea> = [], minutes: Int? = nil, nudgeWords: Set<String> = [], hasText: Bool = false) {
        self.areas = areas
        self.minutes = minutes
        self.nudgeWords = nudgeWords
        self.hasText = hasText
    }

    /// The minutes a time phrase without a number asks for: the shortest session length.
    public static let shortestMinutes = 20

    /// What `text` asks for. Empty or blank text asks for nothing.
    public static func read(_ text: String) -> WorkoutDayNote {
        let words = InjuryNoteMatcher.tokens(text)
        guard !words.isEmpty else { return WorkoutDayNote() }
        let match = InjuryNoteMatcher.match(text)
        var areas = match.areas
        for muscle in match.muscles {
            if let area = nearestArea(of: muscle) { areas.insert(area) }
        }
        return WorkoutDayNote(areas: areas, minutes: minutes(in: words), nudgeWords: nudgeWords(in: words), hasText: true)
    }

    /// The area a muscle word stands for today: the area whose work it is (a hamstring loads the
    /// knee's work, a calf the ankle's), or the shoulder for the chest, whose pressing it shares.
    static func nearestArea(of muscle: MuscleGroup) -> BodyArea? {
        if muscle == .chest { return .shoulder }
        return BodyArea.allCases.first { $0.muscles.contains(muscle) }
    }

    // MARK: Time

    /// Phrases that ask for a short session without giving a number, as word sequences.
    static let shortPhrases: [[String]] = [
        ["short", "on", "time"], ["tight", "on", "time"], ["pressed", "for", "time"], ["not", "much", "time"],
        ["little", "time"], ["in", "a", "hurry"], ["in", "a", "rush"], ["running", "late"], ["keep", "it", "short"],
        ["short", "session"], ["short", "workout"], ["quick"], ["quickly"], ["rushed"],
    ]

    /// Words that make a number of minutes a limit ("only 20 minutes", "have 30 min") rather than a
    /// report ("ran 30 minutes yesterday"), when one of them is among the two words before it.
    static let minuteCues: Set<String> = ["only", "just", "have", "got", "under", "max", "maximum", "about", "around"]

    /// The words that follow a number to make it minutes.
    static let minuteWords: Set<String> = ["min", "mins", "minute", "minutes"]

    /// The minutes the note limits the session to, or nil.
    static func minutes(in words: [String]) -> Int? {
        var found: Int?
        for index in words.indices {
            guard let stated = statedMinutes(at: index, in: words) else { continue }
            found = min(found ?? stated, stated)
        }
        if let found { return found }
        let asksForShort = shortPhrases.contains { phrase in
            words.indices.contains { starts(phrase, at: $0, in: words) }
        }
        return asksForShort ? shortestMinutes : nil
    }

    /// The minutes stated at `index` ("20 minutes", "20min", "half an hour"), when a cue word comes
    /// just before or the note opens with them; nil otherwise.
    static func statedMinutes(at index: Int, in words: [String]) -> Int? {
        guard let value = minuteValue(at: index, in: words), value > 0, value <= 600 else { return nil }
        let before = [InjuryNoteMatcher.word(before: index, in: words), InjuryNoteMatcher.word(before: index - 1, in: words)]
        return index == 0 || before.contains(where: minuteCues.contains) ? value : nil
    }

    /// The number of minutes the words at `index` spell, cue or not.
    static func minuteValue(at index: Int, in words: [String]) -> Int? {
        let word = words[index]
        let next = InjuryNoteMatcher.word(after: index, in: words)
        if word == "half", next == "hour" || (next == "an" && InjuryNoteMatcher.word(after: index + 1, in: words) == "hour") {
            return 30
        }
        let digits = word.prefix(while: \.isNumber)
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        let suffix = String(word.dropFirst(digits.count))
        if suffix.isEmpty { return minuteWords.contains(next) ? value : nil }
        return minuteWords.contains(suffix) ? value : nil
    }

    /// Whether `phrase` sits in `words` starting at `index`.
    static func starts(_ phrase: [String], at index: Int, in words: [String]) -> Bool {
        guard index + phrase.count <= words.count else { return false }
        return zip(phrase, words[index..<(index + phrase.count)]).allSatisfy { $0 == $1 }
    }

    /// The session length the note asks for: the longest one that fits its minutes (the shortest
    /// when even that does not), or nil when it gives none or more than every length.
    public var length: WorkoutSessionLength? {
        guard let minutes else { return nil }
        let timed = WorkoutSessionLength.allCases.compactMap { length in length.minutes.map { (length, $0) } }
        guard let longest = timed.map(\.1).max(), minutes <= longest else { return nil }
        let fitting = timed.filter { $0.1 <= minutes }.max { $0.1 < $1.1 }
        return fitting?.0 ?? timed.min { $0.1 < $1.1 }?.0
    }

    // MARK: The name-word nudge

    /// Words that make the note a complaint or a "less of this" rather than a wish: with one of
    /// them, no word of the note pulls an exercise in.
    static let cautionWords: Set<String> = [
        "sore", "hurt", "hurts", "hurting", "pain", "painful", "ache", "aches", "achy", "aching", "tight", "stiff",
        "injured", "injury", "tweaked", "strained", "sprained", "pulled", "tender", "bad", "weak", "tired", "avoid",
        "skip", "no", "not", "without", "less", "rest", "easy", "don", "dont",
    ]

    /// The words of the note that may nudge a pick: three letters or more, none that names a body
    /// part, and none at all when the note carries a caution word.
    static func nudgeWords(in words: [String]) -> Set<String> {
        guard cautionWords.isDisjoint(with: words) else { return [] }
        return Set(words.filter { $0.count >= 3 && $0 != "back" && InjuryNoteMatcher.lookup($0) == nil })
    }
}

extension InjuryLimits {
    /// These limits with today's note laid over them: every area the note names is trained around
    /// today, unless it is already left out — a saved Severe is never weakened.
    public func applying(_ note: WorkoutDayNote) -> InjuryLimits {
        var merged = self
        merged.mildAreas.formUnion(note.areas.subtracting(severeAreas))
        return merged
    }
}

extension WorkoutDayNote {
    /// Today's note laid over one plan's inputs: the limits and the session options the planner
    /// uses, and what it then says in the plan's note.
    ///
    /// Built once at the top of ``WorkoutProgram``'s `dayPlan`.
    public struct Applied: Equatable, Sendable {
        /// The note as read.
        public var note: WorkoutDayNote
        /// The saved limits, before the note.
        public var saved: InjuryLimits
        /// The limits the plan is built with: ``saved`` with the note's areas eased today.
        public var limits: InjuryLimits
        /// The session options the plan is built with: the caller's, with a shorter length when the
        /// note asked for one and may set it.
        public var options: WorkoutSessionOptions
        /// The minutes the note shortened the session to; nil when it changed no length.
        public var shortenedTo: Int?

        /// Reads `context` and lays it over `saved` and `options`. `mayShorten` is false when the
        /// person chose a length for this plan themselves: their choice stands.
        public init(context: String, saved: InjuryLimits, options: WorkoutSessionOptions, mayShorten: Bool) {
            let note = WorkoutDayNote.read(context)
            self.note = note
            self.saved = saved
            self.limits = saved.applying(note)
            var fitted = options
            var shortened: Int?
            if mayShorten, let asked = note.length, let askedMinutes = asked.minutes,
               askedMinutes < (options.length.minutes ?? Int.max) {
                fitted.length = asked
                shortened = askedMinutes
            }
            self.options = fitted
            self.shortenedTo = shortened
        }

        /// Areas the note names that the plan now trains around.
        var easedAreas: [BodyArea] {
            BodyArea.allCases.filter { note.areas.contains($0) && !saved.severeAreas.contains($0) }
        }

        /// Areas the note names that the saved limits already leave out entirely.
        var alreadyLeftOut: [BodyArea] {
            BodyArea.allCases.filter { note.areas.contains($0) && saved.severeAreas.contains($0) }
        }

        /// What the plan's note says about "Anything else?": a sentence for each thing applied — the
        /// areas eased, the areas already left out, the shorter session, the lifts whose names match
        /// a word of it (`matched`, frozen names) — or the pointer to Equipment & limits when the
        /// text asked for nothing the planner could apply. Empty for an empty note.
        public func lines(matched: [String]) -> [String] {
            guard note.hasText else { return [] }
            var lines: [String] = []
            if !easedAreas.isEmpty { lines.append(WorkoutPlannerCopy.dayNoteEasing(WorkoutPlannerCopy.areaList(easedAreas))) }
            if !alreadyLeftOut.isEmpty {
                lines.append(WorkoutPlannerCopy.dayNoteAlreadyLeftOut(WorkoutPlannerCopy.areaList(alreadyLeftOut)))
            }
            if let shortenedTo { lines.append(WorkoutPlannerCopy.dayNoteShortened(minutes: shortenedTo)) }
            if !matched.isEmpty { lines.append(WorkoutPlannerCopy.dayNoteMatched(WorkoutPlannerCopy.exerciseList(matched))) }
            // A time phrase the person's own length choice already answers was understood: silence
            // about it is not "nothing could be applied".
            let understood = !lines.isEmpty || note.minutes != nil
            return understood ? lines : [WorkoutPlannerCopy.dayNoteNothingApplied]
        }

        /// The lifts in `sessions` whose name shares a word with the note's nudge words — the same
        /// test the slot score's bonus uses — as frozen names, in plan order, at most ``maxMatched``.
        public func matchedLifts(in sessions: [WorkoutProgram.SessionSuggestion]) -> [String] {
            guard !note.nudgeWords.isEmpty else { return [] }
            var names: [String] = []
            for session in sessions {
                for name in session.catalogExerciseNames where !names.contains(name) {
                    let words = Set(name.lowercased().split(separator: " ").map(String.init))
                    if !words.isDisjoint(with: note.nudgeWords) { names.append(name) }
                }
            }
            return Array(names.prefix(Self.maxMatched))
        }

        /// The most matched lifts the note names.
        static let maxMatched = 3
    }
}

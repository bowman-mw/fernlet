// InjuryNoteMatcher.swift
// FernletDomainModel
//
// Reads the workout injury note ("Anything else to keep in mind") for body parts, by whole words.
//
// The old reader matched substrings, so "hip" matched "championship" and the "back" in "getting back
// into lifting" left out every hinge. This one splits the note into words and looks each up, with
// simple plurals ("knees", "shoulders"), and it reads "back" the way a person would: "lower back
// pain", "tweaked my back" and "back and knees" name a back; "getting back into lifting", "back to
// back", "back in the gym", "back on track" and "back from vacation" do not. A handful of other
// idioms are skipped the same way ("hip hop", "neck and neck", "elbow grease", "disc golf", "six
// feet tall"). When "back" carries no sign either way it counts — over-avoiding is the safe
// direction.
//
// The vocabulary is FROZEN English matching input (the localization wall): a note written in another
// language matches nothing here, and the structured picker is the way to say it instead.

import Foundation

/// Whole-word, idiom-aware reading of the free-text injury note into body areas and single muscles.
///
/// Pure and deterministic; bounded by ``maxWords``. ``WorkoutProfile/injuryLimits`` treats every
/// area it finds as severe unless the picker names that area.
public nonisolated enum InjuryNoteMatcher {
    /// What a note names.
    public struct Match: Equatable, Sendable {
        /// Body areas the note names.
        public var areas: Set<BodyArea>
        /// Single muscles the note names that no area covers (a hamstring, a calf, the chest).
        public var muscles: Set<MuscleGroup>

        public init(areas: Set<BodyArea> = [], muscles: Set<MuscleGroup> = []) {
            self.areas = areas
            self.muscles = muscles
        }
    }

    /// Words read from one note, at most: a note is a sentence or two, so anything past this is
    /// not a note (Power of 10 rule 2: the scan is bounded).
    static let maxWords = 400

    /// Words that name an area on their own, plural forms included.
    static let areaWords: [String: BodyArea] = [
        "neck": .neck, "cervical": .neck, "whiplash": .neck,
        "shoulder": .shoulder, "rotator": .shoulder, "delt": .shoulder, "deltoid": .shoulder,
        "elbow": .elbow,
        "wrist": .wristHand, "carpal": .wristHand, "thumb": .wristHand, "finger": .wristHand,
        "thoracic": .upperBack, "rhomboid": .upperBack,
        "spine": .lowerBack, "spinal": .lowerBack, "disc": .lowerBack, "disk": .lowerBack,
        "lumbar": .lowerBack, "sciatica": .lowerBack, "sciatic": .lowerBack,
        "hip": .hip, "groin": .hip,
        "knee": .knee, "kneecap": .knee, "acl": .knee, "mcl": .knee, "meniscus": .knee, "patella": .knee,
        "ankle": .ankleFoot, "achilles": .ankleFoot, "plantar": .ankleFoot, "foot": .ankleFoot, "feet": .ankleFoot,
    ]

    /// Words that name a single muscle no area covers.
    static let muscleWords: [String: MuscleGroup] = [
        "hamstring": .hamstrings, "calf": .calves, "calves": .calves,
        "chest": .chest, "pec": .chest, "pectoral": .chest,
    ]

    /// What `note` names. An empty note names nothing.
    public static func match(_ note: String) -> Match {
        let words = tokens(note)
        var found = Match()
        for index in words.indices {
            if words[index] == "back" {
                if let area = backArea(at: index, in: words) { found.areas.insert(area) }
                continue
            }
            guard let hit = lookup(words[index]), !isIdiom(at: index, in: words) else { continue }
            switch hit {
            case .area(let area): found.areas.insert(area)
            case .muscle(let muscle): found.muscles.insert(muscle)
            }
        }
        return found
    }

    /// A vocabulary hit: an area or a single muscle.
    enum Term: Equatable {
        case area(BodyArea)
        case muscle(MuscleGroup)
    }

    /// The note as lowercase words: letters and digits, everything else (spaces, hyphens,
    /// apostrophes, punctuation) a break — so "hip-hop" is two words and "back's" is "back" + "s".
    static func tokens(_ note: String) -> [String] {
        note.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(maxWords)
            .map(String.init)
    }

    /// The term a word names, trying the word and then its singular ("knees" → "knee").
    static func lookup(_ word: String) -> Term? {
        if let found = term(for: word) { return found }
        guard word.count > 3, word.hasSuffix("s") else { return nil }
        return term(for: String(word.dropLast()))
    }

    private static func term(for word: String) -> Term? {
        if let area = areaWords[word] { return .area(area) }
        return muscleWords[word].map(Term.muscle)
    }

    // MARK: Idioms

    /// The word after `index`, or "" at the end.
    static func word(after index: Int, in words: [String]) -> String {
        index + 1 < words.count ? words[index + 1] : ""
    }

    /// The word before `index`, or "" at the start.
    static func word(before index: Int, in words: [String]) -> String {
        index > 0 ? words[index - 1] : ""
    }

    /// Phrases where a body word means something else: "hip hop", "neck and neck", "neck of the
    /// woods", "knee-deep", "elbow grease", "disc golf", "cold shoulder", "off my chest", a height
    /// ("six feet", "5 foot"), "on foot" and "on my feet".
    static func isIdiom(at index: Int, in words: [String]) -> Bool {
        let next = word(after: index, in: words)
        let previous = word(before: index, in: words)
        switch words[index] {
        case "hip": return next == "hop"
        case "neck": return isNeckIdiom(at: index, in: words)
        case "knee": return next == "deep" || next == "jerk"
        case "elbow": return next == "grease" || next == "room"
        case "disc", "disk": return next == "golf"
        case "shoulder": return previous == "cold" || next == "season"
        case "chest": return previous == "my" && word(before: index - 1, in: words) == "off"
        case "foot", "feet": return isFootIdiom(at: index, in: words)
        default: return false
        }
    }

    /// "Neck and neck" (either "neck") and "neck of the woods" — never "back and neck pain".
    static func isNeckIdiom(at index: Int, in words: [String]) -> Bool {
        let neckAndNeckFirst = word(after: index, in: words) == "and" && word(after: index + 1, in: words) == "neck"
        let neckAndNeckSecond = word(before: index, in: words) == "and" && word(before: index - 1, in: words) == "neck"
        let woods = word(after: index, in: words) == "of" && word(after: index + 2, in: words) == "woods"
        return neckAndNeckFirst || neckAndNeckSecond || woods
    }

    /// Number words that make "foot" / "feet" a length.
    static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "square", "few", "couple",
    ]

    /// "Six feet tall", "a 5 foot bar", "on foot", "on my feet", "feet up".
    static func isFootIdiom(at index: Int, in words: [String]) -> Bool {
        let previous = word(before: index, in: words)
        if numberWords.contains(previous) || (!previous.isEmpty && previous.allSatisfy(\.isNumber)) { return true }
        if previous == "on" || word(after: index, in: words) == "up" { return true }
        let possessives: Set<String> = ["my", "your", "our", "their", "his", "her"]
        return possessives.contains(previous) && word(before: index - 1, in: words) == "on"
    }

    // MARK: "Back"

    /// Words before "back" that make it the body part: a possessive, an article, or a description.
    static let backBodyBefore: Set<String> = [
        "my", "his", "her", "your", "their", "our", "the", "a", "bad", "sore", "stiff", "tight", "weak",
        "injured", "hurt", "tweaked", "achy", "aching", "painful", "sprained", "strained", "herniated",
        "pulled", "threw", "wrecked", "tender",
    ]

    /// Words after "back" that make it the body part: what is wrong with it.
    static let backBodyAfter: Set<String> = [
        "pain", "pains", "painful", "injury", "injuries", "injured", "issue", "issues", "problem", "problems",
        "surgery", "spasm", "spasms", "strain", "sprain", "ache", "aches", "aching", "hurts", "hurt",
        "hurting", "is", "was", "has", "trouble", "troubles", "brace", "s", "muscle", "muscles", "condition",
        "flare", "tweak", "stiffness", "tightness", "soreness",
    ]

    /// Words before "back" that make it an adverb: getting back, coming back, easing back in.
    static let backAdverbBefore: Set<String> = [
        "get", "gets", "getting", "got", "gotten", "come", "comes", "coming", "came", "go", "goes", "going",
        "went", "gone", "be", "been", "being", "am", "m", "re", "are", "were", "bounce", "bouncing", "ease",
        "easing", "ramp", "ramping", "build", "building", "work", "working", "head", "heading", "step",
        "stepping", "start", "started", "starting", "make", "made", "cut", "cutting", "scale", "scaling",
        "dial", "dialing", "hold", "holding", "held", "way", "bring", "brought", "fall", "fell", "falling",
        "push", "pushing", "look", "looking",
    ]

    /// Words after "back" that make it an adverb (back to, back into, back in the gym, back on
    /// track) or a training word rather than a body part (a back squat, back day, backstroke).
    static let backAdverbAfter: Set<String> = [
        "to", "into", "in", "on", "from", "after", "at", "off", "up", "home", "then", "when", "again",
        "now", "since", "around", "squat", "squats", "day", "days", "stroke",
    ]

    /// The back area "back" names at `index`, or nil when it is an adverb ("getting back into
    /// lifting", "back to back"). "Upper back" and "mid back" are the upper back; everything else that
    /// names a back is the lower back — and so is a bare "back" with no sign either way.
    static func backArea(at index: Int, in words: [String]) -> BodyArea? {
        let previous = word(before: index, in: words)
        let next = word(after: index, in: words)
        // The second "back" of "back to back" (the first is caught by the "to" after it).
        if previous == "to" && word(before: index - 1, in: words) == "back" { return nil }
        if previous == "upper" || previous == "mid" || previous == "middle" { return .upperBack }
        if previous == "lower" || previous == "low" { return .lowerBack }
        if backBodyBefore.contains(previous) || backBodyAfter.contains(next) { return .lowerBack }
        if backAdverbBefore.contains(previous) || backAdverbAfter.contains(next) { return nil }
        return .lowerBack
    }
}

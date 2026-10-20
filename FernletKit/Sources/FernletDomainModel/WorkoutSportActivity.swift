// WorkoutSportActivity.swift
// FernletDomainModel
//
// Which activity a guided sport session logs as (round 2, R5, 2026-10-20). A "Sport conditioning"
// session used to reach Apple Health as "Other". The lifter names their sport in Workout setup
// (`WorkoutProfile.sport`, free text such as "pickleball" or "basketball, soccer"); when it names a sport
// Fernlet already models (``WorkoutActivityType``), the guided run logs that sport's own type, and
// otherwise the generic one it always had.
//
// No new activity case is added, so nothing synced changes shape. The words matched are FROZEN English
// matching inputs, never display text (the localization wall): a sport typed in another language finds
// no match and keeps the generic type.

import Foundation

/// Reads the sport a lifter named in Workout setup as one of Fernlet's activity types.
public nonisolated enum WorkoutSportActivity {

    /// The words that name each sport, longest phrases first where one contains another ("table
    /// tennis" before "tennis"). FROZEN matching inputs.
    static let phrases: [(phrase: String, type: WorkoutActivityType)] = [
        ("table tennis", .tableTennis), ("ping pong", .tableTennis),
        ("pickleball", .pickleball), ("tennis", .tennis),
        ("basketball", .basketball), ("soccer", .soccer),
        ("badminton", .badminton), ("racquetball", .racquetball), ("squash", .squash),
        ("rock climbing", .climbing), ("bouldering", .climbing), ("climbing", .climbing),
        ("martial arts", .martialArts), ("jiu jitsu", .martialArts), ("bjj", .martialArts),
        ("judo", .martialArts), ("karate", .martialArts), ("taekwondo", .martialArts),
        ("muay thai", .kickboxing), ("kickboxing", .kickboxing),
        ("trail running", .running), ("running", .running), ("marathon", .running),
        ("cycling", .cycling), ("biking", .cycling),
        ("rowing", .rowing), ("hiking", .hiking), ("dance", .dance), ("dancing", .dance),
    ]

    /// The most characters of a sport name read (R3: free text from the settings blob is bounded).
    static let maxCharacters = 200

    /// The activity type the sport named in `text` maps to — the one named first when it names several
    /// ("basketball, soccer" is basketball) — or nil when it names none Fernlet models.
    ///
    /// Whole words only, without case or punctuation: "Tennis!" is tennis, "tennis elbow rehab" is
    /// tennis too, but "tennisball" is nothing.
    public static func activityType(forSport text: String) -> WorkoutActivityType? {
        let words = normalized(text)
        guard words != " " else { return nil }
        var best: (offset: Int, type: WorkoutActivityType)?
        for entry in phrases {
            guard let range = words.range(of: " \(entry.phrase) ") else { continue }
            let offset = words.distance(from: words.startIndex, to: range.lowerBound)
            if let current = best, current.offset <= offset { continue }
            best = (offset, entry.type)
        }
        return best?.type
    }

    /// `text` lowercased, with every run of non-letters as one space and a space at each end, so a
    /// phrase matches as whole words.
    static func normalized(_ text: String) -> String {
        var result = " "
        for character in text.prefix(maxCharacters).lowercased() {
            let letter = character.isLetter
            if letter {
                result.append(character)
            } else if result.last != " " {
                result.append(" ")
            }
        }
        if result.last != " " { result.append(" ") }
        return result
    }
}

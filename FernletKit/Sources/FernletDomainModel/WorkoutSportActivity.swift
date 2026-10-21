// WorkoutSportActivity.swift
// FernletDomainModel
//
// Which activity a guided sport session logs as (round 2, R5, 2026-10-20). A "Sport conditioning"
// session used to reach Apple Health as "Other". The lifter names their sport in Workout setup
// (`WorkoutProfile.sport`, free text such as "pickleball" or "basketball, soccer"); when it names a sport
// Fernlet models (``WorkoutActivityType``), the guided run logs that sport's own type, and otherwise the
// generic one it always had.
//
// The owner's follow-up picks (2026-10-20): the ball, court, combat, snow and board sports Apple Health
// has are activity types of their own; "football" means American football where the person lives in
// the US or Canada and soccer elsewhere; and a distance sport — running, cycling, rowing, hiking,
// swimming, cross-country skiing — keeps the generic type, because the session is gym strength and
// conditioning work, not a run with no distance in it for Fitness to average.
//
// The words matched are FROZEN English matching inputs, never display text (the localization wall): a
// sport typed in another language finds no match and keeps the generic type. The region is a code
// (`Locale.Region.identifier`, "US"), passed in by the app so this stays pure.

import Foundation

/// Reads the sport a lifter named in Workout setup as one of Fernlet's activity types.
public nonisolated enum WorkoutSportActivity {

    /// What a phrase in the setup text names.
    enum Named: Equatable, Sendable {
        /// A sport Fernlet models as an activity type.
        case sport(WorkoutActivityType)
        /// A sport Fernlet does not model, such as Australian rules: read, so that a sport named after
        /// it never stands in for it.
        case unmodeled
        /// Bare "football", whose meaning depends on the region (``football(inRegion:)``).
        case football
    }

    /// The words that name each sport. Where one phrase contains another, the one starting first in the
    /// text wins ("table tennis" over "tennis", "flag football" over "football"). FROZEN matching inputs.
    static let phrases: [(phrase: String, named: Named)] = [
        ("table tennis", .sport(.tableTennis)), ("ping pong", .sport(.tableTennis)),
        ("pickleball", .sport(.pickleball)), ("tennis", .sport(.tennis)),
        ("basketball", .sport(.basketball)), ("soccer", .sport(.soccer)), ("association football", .sport(.soccer)),
        ("american football", .sport(.americanFootball)), ("flag football", .sport(.americanFootball)),
        ("canadian football", .sport(.americanFootball)), ("gridiron", .sport(.americanFootball)),
        ("australian football", .unmodeled), ("australian rules", .unmodeled), ("aussie rules", .unmodeled),
        ("gaelic football", .unmodeled), ("football", .football),
        ("volleyball", .sport(.volleyball)), ("baseball", .sport(.baseball)), ("softball", .sport(.softball)),
        ("hockey", .sport(.hockey)), ("rugby", .sport(.rugby)), ("lacrosse", .sport(.lacrosse)),
        ("golf", .sport(.golf)),
        ("badminton", .sport(.badminton)), ("racquetball", .sport(.racquetball)), ("squash", .sport(.squash)),
        ("rock climbing", .sport(.climbing)), ("bouldering", .sport(.climbing)), ("climbing", .sport(.climbing)),
        ("martial arts", .sport(.martialArts)), ("jiu jitsu", .sport(.martialArts)), ("bjj", .sport(.martialArts)),
        ("mma", .sport(.martialArts)), ("judo", .sport(.martialArts)), ("karate", .sport(.martialArts)),
        ("taekwondo", .sport(.martialArts)), ("muay thai", .sport(.kickboxing)), ("kickboxing", .sport(.kickboxing)),
        ("boxing", .sport(.boxing)), ("wrestling", .sport(.wrestling)),
        ("cross country skiing", .sport(.crossCountrySkiing)), ("cross country ski", .sport(.crossCountrySkiing)),
        ("nordic skiing", .sport(.crossCountrySkiing)), ("skiing", .sport(.downhillSkiing)),
        ("ski", .sport(.downhillSkiing)), ("snowboarding", .sport(.snowboarding)), ("snowboard", .sport(.snowboarding)),
        ("skateboarding", .sport(.skating)), ("rollerblading", .sport(.skating)), ("skating", .sport(.skating)),
        ("windsurfing", .sport(.surfing)), ("kitesurfing", .sport(.surfing)), ("bodyboarding", .sport(.surfing)),
        ("surfing", .sport(.surfing)), ("surf", .sport(.surfing)),
        ("trail running", .sport(.running)), ("running", .sport(.running)), ("marathon", .sport(.running)),
        ("triathlon", .unmodeled), ("cycling", .sport(.cycling)), ("biking", .sport(.cycling)),
        ("rowing", .sport(.rowing)), ("hiking", .sport(.hiking)), ("open water swimming", .sport(.swimmingOpenWater)),
        ("swimming", .sport(.swimmingPool)), ("dance", .sport(.dance)), ("dancing", .sport(.dance)),
    ]

    /// The distance sports: a guided sport session for one of them logs as the generic type
    /// (``activityType(forSport:region:)``), since it is gym work and not the sport itself.
    public static let distanceSports: Set<WorkoutActivityType> = [
        .running, .cycling, .rowing, .hiking, .swimmingPool, .swimmingOpenWater, .crossCountrySkiing,
    ]

    /// Regions where bare "football" means American (or Canadian) football.
    static let gridironRegions: Set<String> = ["US", "CA"]
    /// Regions where bare "football" most often means a code Fernlet does not model (Australian rules,
    /// rugby league, Gaelic football), so it is read as no sport rather than as soccer.
    static let otherFootballRegions: Set<String> = ["AU", "NZ", "IE"]

    /// The most characters of a sport name read (R3: free text from the settings blob is bounded).
    static let maxCharacters = 200

    /// The activity type a guided sport session logs as: the sport `text` names first
    /// (``sport(named:region:)``), unless that is one of the ``distanceSports``; nil keeps the generic type.
    public static func activityType(forSport text: String, region: String?) -> WorkoutActivityType? {
        guard let sport = sport(named: text, region: region), !distanceSports.contains(sport) else { return nil }
        return sport
    }

    /// The sport `text` names first, as an activity type — distance sports included — or nil when the
    /// first sport it names is one Fernlet does not model, or it names none.
    ///
    /// Whole words only, without case or punctuation: "Tennis!" is tennis, "tennis elbow rehab" is
    /// tennis too, but "tennisball" is nothing. Bare "football" reads by `region` (``football(inRegion:)``).
    public static func sport(named text: String, region: String?) -> WorkoutActivityType? {
        let words = normalized(text)
        guard words != " " else { return nil }
        var best: (offset: Int, named: Named)?
        for entry in phrases {
            guard let range = words.range(of: " \(entry.phrase) ") else { continue }
            let offset = words.distance(from: words.startIndex, to: range.lowerBound)
            if let current = best, current.offset <= offset { continue }
            best = (offset, entry.named)
        }
        switch best?.named {
        case .sport(let type): return type
        case .football: return football(inRegion: region)
        case .unmodeled, nil: return nil
        }
    }

    /// What bare "football" means in `region`: American football in the US and Canada, nothing in
    /// Australia, New Zealand and Ireland (where it is most often a code Fernlet does not model), soccer
    /// everywhere else — and nothing when the region is unknown.
    static func football(inRegion region: String?) -> WorkoutActivityType? {
        guard let region = region?.uppercased(), !region.isEmpty else { return nil }
        if gridironRegions.contains(region) { return .americanFootball }
        return otherFootballRegions.contains(region) ? nil : .soccer
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

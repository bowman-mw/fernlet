//
//  SillyStatsCopy.swift
//  Fernlet
//
//  The words of the silly stats: each card's title, big number, comparison and "how it's counted"
//  note, and the line the companion says when it brings the stat up. Nouns agree with their counts
//  through automatic grammar agreement (`^[…](inflect: true)`), which handles "1 Statue of Liberty"
//  and "1.6 Statues of Liberty" alike, so a comparison never reads "1 grand pianos".
//

import Foundation

/// Everything one stat card and its companion mention say.
struct SillyStatText: Equatable {
    var emoji: String
    var title: String
    /// The big number ("0.82 CPD", "1,204 kg").
    var headline: String
    /// The comparison under it ("Laid end to end: 1.6 school buses of banana.").
    var detail: String
    /// What the companion says when it brings this stat up.
    var companionLine: String
    /// How the stat is counted, in one sentence.
    var footnote: String
}

/// The copy for every silly stat, read off a ``SillyStatsTally``.
///
/// Every string is a localized literal at its call site so `Scripts/sync-string-catalogs.sh`
/// extracts it. The one piece of user content is the signature dish's recipe name, shown
/// verbatim.
enum SillyStatsCopy {
    static func text(for kind: SillyStatKind, tally: SillyStatsTally, locale: Locale = .autoupdatingCurrent) -> SillyStatText {
        switch kind {
        case .cookiesPerDay: cookies(tally, locale)
        case .bananasForScale: bananas(tally, locale)
        case .eggonomics: eggs(tally, locale)
        case .pizzaPieChart: pizza(tally, locale)
        case .bathtubIndex: water(tally, locale)
        case .coffeeTower: coffee(tally, locale)
        case .signatureDish: signatureDish(tally, locale)
        case .totalTonnage: tonnage(tally, locale)
        case .moonwalk: moonwalk(tally, locale)
        case .stairwayToSomewhere: stairway(tally, locale)
        case .grandTours: grandTours(tally, locale)
        case .shakespeareSteps: shakespeare(tally, locale)
        case .koalaDays: koala(tally, locale)
        case .dreamCinema: dreams(tally, locale)
        case .flossRope: floss(tally, locale)
        case .brushMarathon: brushing(tally, locale)
        case .showerConcerts: showers(tally, locale)
        case .patsGiven: pats(tally, locale)
        case .gastrotrichLifetimes: gastrotrich(tally, locale)
        }
    }

    // MARK: - Comparison phrases

    /// "1.6 grand pianos", "1 Statue of Liberty", "0.4 giraffes".
    static func phrase(_ comparison: SillyComparison, locale: Locale = .autoupdatingCurrent) -> String {
        let n = comparison.count
        let text: AttributedString
        switch comparison.unit {
        case .dachshund: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) dachshund](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .giraffe: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) giraffe](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .schoolBus: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) school bus](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .statueOfLiberty: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) Statue of Liberty](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .eiffelTower: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) Eiffel Tower](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .burjKhalifa: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) Burj Khalifa](inflect: true)", locale: locale, comment: "Silly stats comparison unit: the world's tallest building")
        case .everest: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) Mount Everest](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .spaceStation: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...2))) trip](inflect: true) to the space station", locale: locale, comment: "Silly stats comparison unit: the height of the International Space Station's orbit")
        case .goldenRetriever: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) golden retriever](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .grandPiano: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) grand piano](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .elephant: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) elephant](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .blueWhale: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...2))) blue whale](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .bucket: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) bucket](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .bathtub: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) bathtub](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .hotTub: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) hot tub](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .sitcomEpisode: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) sitcom episode](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .featureFilm: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) feature film](inflect: true)", locale: locale, comment: "Silly stats comparison unit")
        case .crossCountryFlight: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) flight](inflect: true) from New York to LA", locale: locale, comment: "Silly stats comparison unit: a six-hour flight")
        case .hamlet: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...1))) Hamlet](inflect: true)", locale: locale, comment: "Silly stats comparison unit: the play, about 30,557 words")
        case .completeShakespeare: text = AttributedString(localized: "^[\(n, format: .number.precision(.fractionLength(0...2))) copy](inflect: true) of the complete works of Shakespeare", locale: locale, comment: "Silly stats comparison unit")
        }
        return String(text.characters)
    }

    static func phrase(_ kind: SillyStatKind, _ tally: SillyStatsTally, _ locale: Locale) -> String {
        guard let comparison = SillyStatsEngine.comparison(for: kind, in: tally) else { return "" }
        return phrase(comparison, locale: locale)
    }

    static func inflected(_ text: AttributedString) -> String {
        String(text.characters)
    }

    static func length(_ meters: Double, _ locale: Locale) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
    }

    // MARK: - Food and drink

    private static func cookies(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let cpd = SillyStatsEngine.cookiesPerDay(tally)
        let total = tally.cookieEquivalents
        return SillyStatText(
            emoji: "🍪",
            title: String(localized: "Cookies Per Day", locale: locale, comment: "Silly stat title (CPD)"),
            headline: String(localized: "\(cpd, format: .number.precision(.fractionLength(2))) CPD", locale: locale, comment: "Silly stat headline: cookies per day"),
            detail: inflected(AttributedString(localized: "^[\(total, format: .number.precision(.fractionLength(0...2))) cookie](inflect: true) over ^[\(tally.daysKnown) day](inflect: true).", locale: locale, comment: "Silly stat: lifetime cookie-equivalents over days known")),
            companionLine: String(localized: "Your CPD is \(cpd, format: .number.precision(.fractionLength(2))). Scientists (me) are thrilled.", locale: locale, comment: "Companion line about cookies per day"),
            footnote: String(localized: "Cookies per day, over every day you've had Fernlet. Homemade is always a whole cookie; everything else follows the cookie table.", locale: locale, comment: "Silly stat: how cookies per day is counted"))
    }

    private static func bananas(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.bananasForScale, tally, locale)
        return SillyStatText(
            emoji: "🍌",
            title: String(localized: "Bananas for Scale", locale: locale, comment: "Silly stat title"),
            headline: inflected(AttributedString(localized: "^[\(tally.bananas, format: .number.precision(.fractionLength(0...1))) banana](inflect: true)", locale: locale, comment: "Silly stat headline: bananas eaten")),
            detail: String(localized: "Laid end to end: \(measure) of banana.", locale: locale, comment: "Silly stat: banana length comparison"),
            companionLine: String(localized: "You've eaten \(measure) of banana, end to end. I measured.", locale: locale, comment: "Companion line about bananas"),
            footnote: String(localized: "Bananas eaten, at about 18 cm each.", locale: locale, comment: "Silly stat: how bananas are counted"))
    }

    private static func eggs(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let fraction = SillyStatsEngine.henYearFraction(tally)
        let detail: String
        let line: String
        if fraction < 1 {
            detail = String(localized: "\(fraction, format: .percent.precision(.fractionLength(0...1))) of one hen's whole year of work.", locale: locale, comment: "Silly stat: eggs as a share of a hen's yearly eggs")
            line = String(localized: "You've eaten \(fraction, format: .percent.precision(.fractionLength(0...1))) of a hen's whole year of work. She says you're welcome.", locale: locale, comment: "Companion line about eggs")
        } else {
            detail = inflected(AttributedString(localized: "^[\(fraction, format: .number.precision(.fractionLength(0...1))) hen-year](inflect: true) of work.", locale: locale, comment: "Silly stat: eggs in years of one hen's laying"))
            line = inflected(AttributedString(localized: "You've eaten ^[\(fraction, format: .number.precision(.fractionLength(0...1))) hen-year](inflect: true) of eggs. The hens are unionizing.", locale: locale, comment: "Companion line about eggs"))
        }
        return SillyStatText(
            emoji: "🥚",
            title: String(localized: "Egg-onomics", locale: locale, comment: "Silly stat title (a pun on economics)"),
            headline: inflected(AttributedString(localized: "^[\(tally.eggs, format: .number.precision(.fractionLength(0...1))) egg](inflect: true)", locale: locale, comment: "Silly stat headline: eggs eaten")),
            detail: detail,
            companionLine: line,
            footnote: String(localized: "Eggs eaten, against the 300 or so a hen lays in a year.", locale: locale, comment: "Silly stat: how eggs are counted"))
    }

    private static func pizza(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let pizzas = SillyStatsEngine.pizzas(tally)
        return SillyStatText(
            emoji: "🍕",
            title: String(localized: "Pizza Pie Chart", locale: locale, comment: "Silly stat title"),
            headline: inflected(AttributedString(localized: "^[\(pizzas, format: .number.precision(.fractionLength(0...1))) pizza](inflect: true)", locale: locale, comment: "Silly stat headline: whole pizzas eaten")),
            detail: inflected(AttributedString(localized: "^[\(tally.pizzaSlices, format: .number.precision(.fractionLength(0...1))) slice](inflect: true). The chart is also a pizza.", locale: locale, comment: "Silly stat: pizza slices, beside a pie chart drawn as a pizza")),
            companionLine: inflected(AttributedString(localized: "Lifetime pizza: ^[\(pizzas, format: .number.precision(.fractionLength(0...1))) pizza](inflect: true). I made you a pie chart. It's also a pizza.", locale: locale, comment: "Companion line about pizza")),
            footnote: String(localized: "Slices eaten, eight to a pizza.", locale: locale, comment: "Silly stat: how pizza is counted"))
    }

    private static func water(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.bathtubIndex, tally, locale)
        let volume = Measurement(value: tally.waterLiters, unit: UnitVolume.liters)
            .formatted(.measurement(width: .abbreviated, usage: .liquid, numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
        return SillyStatText(
            emoji: "🛁",
            title: String(localized: "Bathtub Index", locale: locale, comment: "Silly stat title"),
            headline: volume,
            detail: String(localized: "That's \(measure) of water.", locale: locale, comment: "Silly stat: water drunk compared with buckets, bathtubs or hot tubs"),
            companionLine: String(localized: "You've drunk \(measure) of water. Please don't picture it.", locale: locale, comment: "Companion line about water"),
            footnote: String(localized: "Water you've logged, at your bottle size.", locale: locale, comment: "Silly stat: how water is counted"))
    }

    private static func coffee(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.coffeeTower, tally, locale)
        return SillyStatText(
            emoji: "☕️",
            title: String(localized: "Coffee Tower", locale: locale, comment: "Silly stat title"),
            headline: inflected(AttributedString(localized: "^[\(tally.coffeeCups, format: .number.precision(.fractionLength(0...1))) cup](inflect: true)", locale: locale, comment: "Silly stat headline: cups of coffee or tea")),
            detail: String(localized: "Stacked up, your cups stand \(measure) tall.", locale: locale, comment: "Silly stat: stacked cups compared with a height"),
            companionLine: String(localized: "Your coffee tower is \(measure) tall. Please don't climb it.", locale: locale, comment: "Companion line about coffee and tea"),
            footnote: String(localized: "Cups of coffee and tea, stacked at about 12 cm a cup.", locale: locale, comment: "Silly stat: how cups are counted"))
    }

    private static func signatureDish(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let name = tally.signatureDish?.name ?? ""
        let count = tally.signatureDish?.count ?? 0
        return SillyStatText(
            emoji: "🍲",
            title: String(localized: "Signature Dish", locale: locale, comment: "Silly stat title"),
            headline: name,
            detail: inflected(AttributedString(localized: "Made ^[\(count) time](inflect: true). It's your signature dish now.", locale: locale, comment: "Silly stat: how often the top homemade recipe was logged")),
            companionLine: inflected(AttributedString(localized: "\(name), ^[\(count) time](inflect: true). It's your signature dish now. I don't make the rules.", locale: locale, comment: "Companion line about the most-logged homemade recipe; the first value is the recipe's name")),
            footnote: String(localized: "Your most-logged homemade recipe.", locale: locale, comment: "Silly stat: how the signature dish is picked"))
    }
}

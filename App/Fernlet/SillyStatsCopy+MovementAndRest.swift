//
//  SillyStatsCopy+MovementAndRest.swift
//  Fernlet
//
//  The silly stats' copy for movement, sleep, personal care and the companion itself. Split from
//  SillyStatsCopy.swift, which holds the food stats, the comparison phrases and the dispatch.
//

import Foundation

extension SillyStatsCopy {
    // MARK: - Movement

    static func tonnage(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.totalTonnage, tally, locale)
        let mass = Measurement(value: tally.liftedKilograms, unit: UnitMass.kilograms)
            .formatted(.measurement(width: .abbreviated, usage: .personWeight, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
        return SillyStatText(
            emoji: "🏋️",
            title: String(localized: "Total Tonnage", locale: locale, comment: "Silly stat title: total weight lifted"),
            headline: mass,
            detail: String(localized: "That's \(measure), moved one rep at a time.", locale: locale, comment: "Silly stat: lifted weight compared with a heavy thing"),
            companionLine: String(localized: "You've moved \(measure) so far. Gently, I hope.", locale: locale, comment: "Companion line about weight lifted"),
            footnote: String(localized: "Sets × reps × weight in your logged exercises. A line without a weight doesn't add any.", locale: locale, comment: "Silly stat: how weight lifted is counted"))
    }

    static func moonwalk(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let moon = SillyStatsEngine.moonFraction(tally)
        let laps = SillyStatsEngine.earthLaps(tally)
        let distance = length(SillyStatsEngine.footKilometers(tally) * 1_000, locale)
        return SillyStatText(
            emoji: "🌕",
            title: String(localized: "Moonwalk", locale: locale, comment: "Silly stat title: distance on foot compared with a trip to the Moon"),
            headline: String(localized: "\(moon, format: .percent.precision(.fractionLength(1...2))) of the way to the Moon", locale: locale, comment: "Silly stat headline: share of the Earth–Moon distance walked"),
            detail: inflected(AttributedString(localized: "\(distance) on foot — ^[\(laps, format: .number.precision(.fractionLength(2))) lap](inflect: true) around the Earth.", locale: locale, comment: "Silly stat: distance walked and laps of the Earth")),
            companionLine: String(localized: "You're \(moon, format: .percent.precision(.fractionLength(1...2))) of the way to the Moon. Pack snacks.", locale: locale, comment: "Companion line about distance walked"),
            footnote: String(localized: "Distance on foot from your steps, at about 1,300 a kilometer, or from your logged walks and runs.", locale: locale, comment: "Silly stat: how walking distance is counted"))
    }

    static func stairway(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.stairwayToSomewhere, tally, locale)
        return SillyStatText(
            emoji: "🪜",
            title: String(localized: "Stairway to Somewhere", locale: locale, comment: "Silly stat title: height climbed on a stair machine"),
            headline: length(tally.stairMeters, locale),
            detail: String(localized: "That's \(measure), and you never once saw the view.", locale: locale, comment: "Silly stat: height climbed compared with a landmark"),
            companionLine: String(localized: "You've climbed \(measure) without leaving the gym.", locale: locale, comment: "Companion line about stair-machine climbing"),
            footnote: String(localized: "Stair-machine minutes, at about 10 m of climb a minute.", locale: locale, comment: "Silly stat: how climbing height is counted"))
    }

    static func grandTours(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let channel = SillyStatsEngine.channelFraction(tally)
        let tour = SillyStatsEngine.tourFraction(tally)
        let swim = String(localized: "\(channel, format: .percent.precision(.fractionLength(1...2))) of the English Channel", locale: locale, comment: "Silly stat: swim distance as a share of the English Channel")
        let ride = String(localized: "\(tour, format: .percent.precision(.fractionLength(1...2))) of the Tour de France", locale: locale, comment: "Silly stat: ride distance as a share of the Tour de France")
        let showsChannel = SillyStatsEngine.showsChannel(tally)
        let showsTour = SillyStatsEngine.showsTour(tally)
        let detail: String
        if showsChannel && showsTour {
            detail = String(localized: "Swum: \(swim). Ridden: \(ride).", locale: locale, comment: "Silly stat: both swim and ride shares")
        } else if showsChannel {
            detail = String(localized: "Swum so far: \(swim).", locale: locale, comment: "Silly stat: swim share only")
        } else {
            detail = String(localized: "Ridden so far: \(ride).", locale: locale, comment: "Silly stat: ride share only")
        }
        let line = showsChannel
            ? String(localized: "English Channel crossing: \(channel, format: .percent.precision(.fractionLength(1...2))) complete.", locale: locale, comment: "Companion line about swimming")
            : String(localized: "Tour de France: \(tour, format: .percent.precision(.fractionLength(1...2))) ridden. Nobody tell the peloton.", locale: locale, comment: "Companion line about cycling")
        return SillyStatText(
            emoji: "🏊",
            title: String(localized: "Grand Tours", locale: locale, comment: "Silly stat title: swimming and cycling distance against famous routes"),
            headline: showsChannel ? swim : ride,
            detail: detail,
            companionLine: line,
            footnote: String(localized: "Swim and ride distances from your logged workouts.", locale: locale, comment: "Silly stat: how swim and ride distance is counted"))
    }

    /// Furthest from home (Refinements group 12): the distance, and how far that is to the other side of
    /// the world.
    static func furthestFromHome(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let distance = length(tally.furthestFromHomeMeters, locale)
        let share = SillyStatsEngine.antipodeFraction(tally)
        return SillyStatText(
            emoji: "🧭",
            title: String(localized: "Furthest from home", locale: locale, comment: "Silly stat title: the furthest the map has been uncovered from the person's home"),
            headline: distance,
            detail: String(localized: "As the crow flies, \(share, format: .percent.precision(.fractionLength(0...1))) of the way to the other side of the world.", locale: locale, comment: "Silly stat: the furthest distance from home as a share of half the Earth's circumference"),
            companionLine: String(localized: "We've been \(distance) from home. I still knew the way back.", locale: locale, comment: "Companion line about the furthest the person has been from home"),
            footnote: String(localized: "A straight line from your nearest home to the furthest bit of map you've uncovered, worked out on this iPhone.", locale: locale, comment: "Silly stat: how the furthest distance from home is counted"))
    }

    static func shakespeare(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.shakespeareSteps, tally, locale)
        return SillyStatText(
            emoji: "🎭",
            title: String(localized: "Shakespeare Steps", locale: locale, comment: "Silly stat title: steps compared with words Shakespeare wrote"),
            headline: inflected(AttributedString(localized: "^[\(tally.steps) step](inflect: true)", locale: locale, comment: "Silly stat headline: lifetime steps")),
            detail: String(localized: "One step, one word: your feet have written \(measure).", locale: locale, comment: "Silly stat: steps compared with Shakespeare's word counts"),
            companionLine: String(localized: "Your feet have out-written \(measure). One step, one word.", locale: locale, comment: "Companion line about steps"),
            footnote: String(localized: "Lifetime steps, one per word. Hamlet is about 30,557 words.", locale: locale, comment: "Silly stat: how Shakespeare steps are counted"))
    }

    // MARK: - Sleep

    static func koala(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let days = SillyStatsEngine.koalaDays(tally)
        return SillyStatText(
            emoji: "🐨",
            title: String(localized: "Koala Days", locale: locale, comment: "Silly stat title: sleep measured in koala days"),
            headline: inflected(AttributedString(localized: "^[\(days, format: .number.precision(.fractionLength(0...1))) koala day](inflect: true)", locale: locale, comment: "Silly stat headline: total sleep in 20-hour koala days")),
            detail: inflected(AttributedString(localized: "^[\(tally.sleepHours, format: .number.precision(.fractionLength(0))) hour](inflect: true) asleep. A koala sleeps about 20 a day.", locale: locale, comment: "Silly stat: total hours slept")),
            companionLine: inflected(AttributedString(localized: "You've slept ^[\(days, format: .number.precision(.fractionLength(0...1))) koala day](inflect: true). The koalas approve.", locale: locale, comment: "Companion line about sleep")),
            footnote: String(localized: "Hours slept, in koala days of 20 hours.", locale: locale, comment: "Silly stat: how koala days are counted"))
    }

    static func dreams(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let films = SillyStatsEngine.dreamFilms(tally)
        return SillyStatText(
            emoji: "🎬",
            title: String(localized: "Dream Cinema", locale: locale, comment: "Silly stat title: dream sleep measured in films"),
            headline: inflected(AttributedString(localized: "^[\(films, format: .number.precision(.fractionLength(0...1))) feature film](inflect: true)", locale: locale, comment: "Silly stat headline: REM sleep in two-hour films")),
            detail: inflected(AttributedString(localized: "^[\(tally.remMinutes, format: .number.precision(.fractionLength(0))) minute](inflect: true) of dream sleep. None of it had a plot.", locale: locale, comment: "Silly stat: REM sleep minutes")),
            companionLine: inflected(AttributedString(localized: "You've dreamed ^[\(films, format: .number.precision(.fractionLength(0...1))) feature film](inflect: true). Reviews pending.", locale: locale, comment: "Companion line about dream sleep")),
            footnote: String(localized: "REM sleep from Apple Health, in two-hour films.", locale: locale, comment: "Silly stat: how dream films are counted"))
    }

    // MARK: - Personal care

    static func floss(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.flossRope, tally, locale)
        return SillyStatText(
            emoji: "🦷",
            title: String(localized: "Floss Rope", locale: locale, comment: "Silly stat title: floss used, laid end to end"),
            headline: length(Double(tally.flossCount) * SillyStatsEngine.Constant.flossMeters, locale),
            detail: String(localized: "Enough floss to measure \(measure).", locale: locale, comment: "Silly stat: floss length compared with a length"),
            companionLine: String(localized: "That's enough floss to lasso \(measure).", locale: locale, comment: "Companion line about flossing"),
            footnote: String(localized: "Flossing days, at about 45 cm of floss each.", locale: locale, comment: "Silly stat: how floss is counted"))
    }

    static func brushing(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let measure = phrase(.brushMarathon, tally, locale)
        let minutes = Double(tally.brushCount) * SillyStatsEngine.Constant.brushMinutes
        let duration = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
        return SillyStatText(
            emoji: "🪥",
            title: String(localized: "Brush Marathon", locale: locale, comment: "Silly stat title: total time brushing teeth"),
            headline: duration,
            detail: String(localized: "That's \(measure) of brushing.", locale: locale, comment: "Silly stat: brushing time compared with a duration"),
            companionLine: String(localized: "You've brushed your teeth for \(measure). Window seat, I hope.", locale: locale, comment: "Companion line about brushing teeth"),
            footnote: String(localized: "Two minutes per brushing.", locale: locale, comment: "Silly stat: how brushing time is counted"))
    }

    static func showers(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let songs = SillyStatsEngine.showerSongs(tally)
        return SillyStatText(
            emoji: "🚿",
            title: String(localized: "Shower Concerts", locale: locale, comment: "Silly stat title"),
            headline: inflected(AttributedString(localized: "^[\(tally.showerCount) concert](inflect: true)", locale: locale, comment: "Silly stat headline: showers, as concerts")),
            detail: inflected(AttributedString(localized: "About ^[\(songs) song](inflect: true) performed. The acoustics remain incredible.", locale: locale, comment: "Silly stat: songs sung in the shower")),
            companionLine: String(localized: "Shower concerts performed: \(tally.showerCount). Acoustics: incredible.", locale: locale, comment: "Companion line about showers"),
            footnote: String(localized: "Three songs per shower. Assumed, obviously.", locale: locale, comment: "Silly stat: how shower concerts are counted"))
    }

    // MARK: - The companion

    static func pats(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let shine = SillyStatsEngine.furShininessPercent(tally) / 100
        return SillyStatText(
            emoji: "🐾",
            title: String(localized: "Pats Given", locale: locale, comment: "Silly stat title: times the user patted the companion"),
            headline: inflected(AttributedString(localized: "^[\(tally.pats) pat](inflect: true)", locale: locale, comment: "Silly stat headline: lifetime pats")),
            detail: String(localized: "Fur shininess: +\(shine, format: .percent.precision(.fractionLength(0...1))) (estimate).", locale: locale, comment: "Silly stat: a made-up fur shininess figure"),
            companionLine: inflected(AttributedString(localized: "^[\(tally.pats) pat](inflect: true) so far. My fur is \(shine, format: .percent.precision(.fractionLength(0...1))) shinier (estimate).", locale: locale, comment: "Companion line about being patted")),
            footnote: String(localized: "Counted on this iPhone only.", locale: locale, comment: "Silly stat: pats are counted on this device only"))
    }

    static func gastrotrich(_ tally: SillyStatsTally, _ locale: Locale) -> SillyStatText {
        let lifetimes = SillyStatsEngine.gastrotrichLifetimes(tally)
        return SillyStatText(
            emoji: "🦠",
            title: String(localized: "Gastrotrich Lifetimes", locale: locale, comment: "Silly stat title: how long the user has known the companion, in lifetimes of a tiny pond animal"),
            headline: inflected(AttributedString(localized: "^[\(lifetimes, format: .number.precision(.fractionLength(0...1))) lifetime](inflect: true)", locale: locale, comment: "Silly stat headline: gastrotrich lifetimes")),
            detail: inflected(AttributedString(localized: "We've known each other ^[\(tally.daysKnown) day](inflect: true). A gastrotrich, a tiny pond animal, lives about three.", locale: locale, comment: "Silly stat: days known, compared with a gastrotrich's lifespan")),
            companionLine: inflected(AttributedString(localized: "We've been friends for ^[\(lifetimes, format: .number.precision(.fractionLength(0...1))) gastrotrich lifetime](inflect: true). They're tiny and live about three days.", locale: locale, comment: "Companion line about how long the user has had the app")),
            footnote: String(localized: "Days since your first log, in three-day gastrotrich lifetimes.", locale: locale, comment: "Silly stat: how gastrotrich lifetimes are counted"))
    }
}

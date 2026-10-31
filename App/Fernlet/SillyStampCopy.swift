//
//  SillyStampCopy.swift
//  Fernlet
//
//  The words of the stamps: each one's name, the banner that says it was just earned, and the line
//  the companion says about it. The names are original drafts for the owner to rename (design round
//  2026-10-22, answer 17), so nothing borrows a character.
//

import Foundation

/// The copy for every stamp.
///
/// Display text only. A stamp is stored and matched by its stat's frozen token
/// (``SillyStampEntry``), never by its name, so renaming a stamp changes only what is drawn — and,
/// because every string here is a localized literal (extracted by `Scripts/sync-string-catalogs.sh`),
/// a renamed name drops its old translation instead of keeping a stale one.
enum SillyStampCopy {
    /// The stamp's name: "Crumb Goblin", "Small Step".
    static func name(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        switch kind {
        case .cookiesPerDay: String(localized: "Crumb Goblin", locale: locale, comment: "Silly stats stamp name, earned when Cookies Per Day first appears")
        case .bananasForScale: String(localized: "Top Banana", locale: locale, comment: "Silly stats stamp name, earned when Bananas for Scale first appears")
        case .eggonomics: String(localized: "Sunny Side Up", locale: locale, comment: "Silly stats stamp name, earned when Egg-onomics first appears")
        case .pizzaPieChart: String(localized: "Slice of Life", locale: locale, comment: "Silly stats stamp name, earned when Pizza Pie Chart first appears")
        case .bathtubIndex: String(localized: "Rubber Duck", locale: locale, comment: "Silly stats stamp name, earned when Bathtub Index (water drunk) first appears")
        case .coffeeTower: String(localized: "Bean Counter", locale: locale, comment: "Silly stats stamp name, earned when Coffee Tower first appears")
        case .signatureDish: String(localized: "House Special", locale: locale, comment: "Silly stats stamp name, earned when a homemade recipe becomes the Signature Dish")
        case .totalTonnage: String(localized: "Piano Mover", locale: locale, comment: "Silly stats stamp name, earned when Total Tonnage (weight lifted) first appears")
        case .moonwalk: String(localized: "Small Step", locale: locale, comment: "Silly stats stamp name, earned when the walk to the Moon first appears")
        case .stairwayToSomewhere: String(localized: "Up and Up", locale: locale, comment: "Silly stats stamp name, earned when Stairway to Somewhere first appears")
        case .grandTours: String(localized: "Wheels and Waves", locale: locale, comment: "Silly stats stamp name, earned when Grand Tours (swims and rides) first appears")
        case .furthestFromHome: String(localized: "Far Afield", locale: locale, comment: "Silly stats stamp name, earned when Furthest from home first appears (the map uncovered 5 km or more from a home)")
        case .shakespeareSteps: String(localized: "To Step or Not to Step", locale: locale, comment: "Silly stats stamp name, earned when steps reach one Hamlet; a play on Hamlet's famous line")
        case .koalaDays: String(localized: "Eucalyptus Dreams", locale: locale, comment: "Silly stats stamp name, earned when Koala Days (sleep) first appears")
        case .dreamCinema: String(localized: "Opening Night", locale: locale, comment: "Silly stats stamp name, earned when Dream Cinema (dream sleep) first appears")
        case .flossRope: String(localized: "Floss Boss", locale: locale, comment: "Silly stats stamp name, earned when Floss Rope first appears")
        case .brushMarathon: String(localized: "Starting Line", locale: locale, comment: "Silly stats stamp name, earned when Brush Marathon first appears")
        case .showerConcerts: String(localized: "Encore", locale: locale, comment: "Silly stats stamp name, earned when Shower Concerts first appears")
        case .patsGiven: String(localized: "Good Bean", locale: locale, comment: "Silly stats stamp name, earned the first time the companion is petted; 'good bean' is an affectionate nickname")
        case .gastrotrichLifetimes: String(localized: "Outlived a Gastrotrich", locale: locale, comment: "Silly stats stamp name, earned after three days together; a gastrotrich is a tiny creature that lives about three days")
        }
    }

    /// What the companion says when the stamp is earned.
    static func companionLine(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        switch kind {
        case .cookiesPerDay: String(localized: "A cookie! Respect.", locale: locale, comment: "Companion line when the Crumb Goblin stamp is earned (first cookie)")
        case .bananasForScale: String(localized: "A banana! Now I have something to measure with.", locale: locale, comment: "Companion line when the Top Banana stamp is earned (first banana)")
        case .eggonomics: String(localized: "An egg! The hens have been notified.", locale: locale, comment: "Companion line when the Sunny Side Up stamp is earned (first egg)")
        case .pizzaPieChart: String(localized: "Pizza! I've started you a pie chart.", locale: locale, comment: "Companion line when the Slice of Life stamp is earned (first pizza)")
        case .bathtubIndex: String(localized: "Water! I'm filling a very small bathtub.", locale: locale, comment: "Companion line when the Rubber Duck stamp is earned (first water logged)")
        case .coffeeTower: String(localized: "A cup! I'm starting a tower.", locale: locale, comment: "Companion line when the Bean Counter stamp is earned (first coffee or tea)")
        case .signatureDish: String(localized: "Three times! It's a house special now.", locale: locale, comment: "Companion line when the House Special stamp is earned (a homemade recipe logged three times)")
        case .totalTonnage: String(localized: "You lifted things! The pianos are nervous.", locale: locale, comment: "Companion line when the Piano Mover stamp is earned (first weights logged)")
        case .moonwalk: String(localized: "We're a tenth of a percent of the way to the Moon.", locale: locale, comment: "Companion line when the Small Step stamp is earned (walked 0.1% of the way to the Moon)")
        case .stairwayToSomewhere: String(localized: "Stairs! Up and up we go.", locale: locale, comment: "Companion line when the Up and Up stamp is earned (first stair workout)")
        case .grandTours: String(localized: "A grand tour has begun. A small one, so far.", locale: locale, comment: "Companion line when the Wheels and Waves stamp is earned (first stretch of swimming or cycling)")
        case .furthestFromHome: String(localized: "Look how far we came! Home's still where we left it.", locale: locale, comment: "Companion line when the Far Afield stamp is earned (the map uncovered 5 km or more from a home)")
        case .shakespeareSteps: String(localized: "You've walked a whole Hamlet. Bravo.", locale: locale, comment: "Companion line when the To Step or Not to Step stamp is earned (as many steps as Hamlet has words)")
        case .koalaDays: String(localized: "A whole koala day of sleep. Very eucalyptus.", locale: locale, comment: "Companion line when the Eucalyptus Dreams stamp is earned (20 hours of sleep, one koala's day)")
        case .dreamCinema: String(localized: "A feature film of dreams. I'd watch it.", locale: locale, comment: "Companion line when the Opening Night stamp is earned (two hours of dream sleep)")
        case .flossRope: String(localized: "Floss! I'm saving the string.", locale: locale, comment: "Companion line when the Floss Boss stamp is earned (first floss)")
        case .brushMarathon: String(localized: "Teeth, brushed. The marathon begins.", locale: locale, comment: "Companion line when the Starting Line stamp is earned (first tooth brushing)")
        case .showerConcerts: String(localized: "A shower concert! Encore!", locale: locale, comment: "Companion line when the Encore stamp is earned (first shower)")
        case .patsGiven: String(localized: "A pat! I'm counting those, you know.", locale: locale, comment: "Companion line when the Good Bean stamp is earned (first pat)")
        case .gastrotrichLifetimes: String(localized: "Three days! We've outlived a gastrotrich.", locale: locale, comment: "Companion line when the Outlived a Gastrotrich stamp is earned (three days together)")
        }
    }

    /// The banner's first line: "New stamp: Crumb Goblin".
    static func bannerTitle(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        let name = name(for: kind, locale: locale)
        return String(localized: "New stamp: \(name)", locale: locale, comment: "Banner when a silly stats stamp is earned; the value is the stamp's name")
    }

    /// The banner's second line: "Cookies Per Day has begun."
    static func bannerDetail(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        let title = statTitle(for: kind, locale: locale)
        return String(localized: "\(title) has begun.", locale: locale, comment: "Banner line under a new silly stats stamp; the value is the silly stat's title, which just appeared for the first time")
    }

    /// What VoiceOver says when the banner appears: both lines as one sentence pair.
    static func announcement(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        let name = name(for: kind, locale: locale)
        let title = statTitle(for: kind, locale: locale)
        return String(localized: "New stamp: \(name). \(title) has begun.", locale: locale, comment: "Spoken by VoiceOver when a silly stats stamp is earned; the values are the stamp's name and the silly stat's title")
    }

    /// The stat's emoji, drawn at the centre of its stamp.
    static func emoji(for kind: SillyStatKind) -> String {
        SillyStatsCopy.text(for: kind, tally: SillyStatsTally()).emoji
    }

    /// The stat's own title ("Cookies Per Day"), from the stat card's copy.
    static func statTitle(for kind: SillyStatKind, locale: Locale = .autoupdatingCurrent) -> String {
        // The title reads no number, so an empty tally gives the same words as the live one.
        SillyStatsCopy.text(for: kind, tally: SillyStatsTally(), locale: locale).title
    }
}

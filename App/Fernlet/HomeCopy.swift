//
//  HomeCopy.swift
//  Fernlet
//
//  The words Home builds as `String`s rather than as `Text` literals: the companion's thought-bubble
//  lines, the milestones card's summary and coin pill, the quick-log tiles' counts, the Customize
//  sheet's wardrobe count and the photowall's placeholder captions. A `String` built from a bare
//  literal never reaches the string catalog, so each one here is a `String(localized:)` key (the app
//  bundle IS `Bundle.main`, so no `bundle:` argument), with `defaultValue` holding the exact English
//  Home drew before.
//
//  Three shapes recur, and each is there so a translation comes out right rather than merely present:
//    * One whole sentence per case. The mood line used to lowercase the localized mood word and
//      splice it into an English sentence; it is now six sentences, one per `FeelingTag`.
//    * Counts are plural-ruled keys (`%lld` with `one`/`other` authored in the catalog), never two
//      English literals picked by `count == 1`. A count shared by two tiles ("3 logged" on Meals
//      and on Move) is two keys, because the participle agrees with a different noun in Spanish.
//    * Two independent counts in one sentence are two plural-ruled clauses placed by a format key,
//      the same answer the Messages recipe card gives: one key offers a translator one plural rule
//      for two nouns.
//

import Foundation
import FernletDomainModel

/// Home's `String`-typed copy, resolved through the app's string catalog.
///
/// Pure and `static` so a test reads exactly the words the view draws (a view's private computed
/// property cannot be read). Nothing here is a token: no line is persisted, compared or sent, so
/// every one is free to translate. The companion's name is Fern and the product is Fernlet; both
/// stay as written in every language.
///
/// `nonisolated`: pure lookups with no state, so a count phrase can be handed to a view helper as a
/// plain `(Int) -> String` (the app target's default isolation is the main actor).
nonisolated enum HomeCopy {

    // MARK: - Companion thoughts

    /// The thought after today's last journal entry was tagged `tag`.
    ///
    /// One sentence per mood, so a translator can make the mood word agree with the sentence around
    /// it. The old line lowercased the mood chip's own label in code and spliced it into an English
    /// sentence, which no language but English could survive.
    static func journalMoodThought(_ tag: FeelingTag) -> String {
        switch tag {
        case .bright:
            String(localized: "home.thought.journalMood.bright",
                   defaultValue: "You marked today as bright. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Bright. Gentle; the mood is information, not a grade.")
        case .good:
            String(localized: "home.thought.journalMood.good",
                   defaultValue: "You marked today as good. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Good.")
        case .neutral:
            String(localized: "home.thought.journalMood.neutral",
                   defaultValue: "You marked today as neutral. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Neutral.")
        case .quiet:
            String(localized: "home.thought.journalMood.quiet",
                   defaultValue: "You marked today as quiet. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Quiet (a subdued, low-key day).")
        case .tired:
            String(localized: "home.thought.journalMood.tired",
                   defaultValue: "You marked today as tired. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Tired.")
        case .hard:
            String(localized: "home.thought.journalMood.hard",
                   defaultValue: "You marked today as hard. Let that be enough information for now.",
                   comment: "Home companion thought bubble after today's journal mood was set to Hard. Never alarmed; the mood is information, not a grade.")
        }
    }

    /// The thought on a day with nothing logged yet.
    static var emptyDayThought: String {
        String(localized: "home.thought.emptyDay",
               defaultValue: "Start with one small thing. Enough, not everything.",
               comment: "Home companion thought bubble on a day with nothing logged yet. An invitation, never a to-do.")
    }

    /// The thought when nothing more specific applies.
    static var ordinaryDayThought: String {
        String(localized: "home.thought.ordinaryDay",
               defaultValue: "A few ordinary care notes are already here. Keep the day simple.",
               comment: "Home companion thought bubble on an ordinary day that already has a few logs, when no other line applies.")
    }

    /// The four lines a tap on the companion rotates through, in their fixed order.
    static var tapThoughts: [String] {
        [
            String(localized: "home.thought.tap.notices", defaultValue: "Fernlet notices you.",
                   comment: "Home companion thought bubble after a tap on the companion. 'Fernlet' is the app's name; keep it as is."),
            String(localized: "home.thought.tap.checkIn", defaultValue: "A little check-in counts.",
                   comment: "Home companion thought bubble after a tap on the companion."),
            String(localized: "home.thought.tap.stillHere", defaultValue: "Still here with you.",
                   comment: "Home companion thought bubble after a tap on the companion, spoken by the companion."),
            String(localized: "home.thought.tap.smallCare", defaultValue: "Small care is still care.",
                   comment: "Home companion thought bubble after a tap on the companion."),
        ]
    }

    /// The fifth pet in a window: Fern is content and settles in for a while.
    static var settledThought: String {
        String(localized: "home.thought.settled",
               defaultValue: "Fern is soaking up all this love — feeling completely content.",
               comment: "Home companion thought bubble when petting settles the companion. Fern is the companion's name; keep it as is.")
    }

    /// Said at most once while the companion is settled and the petting continues. Warm, never a
    /// refusal: Fern is settled, not locked.
    static var settledAgainLine: String {
        String(localized: "home.thought.settledAgain",
               defaultValue: "Fern is feeling nice and settled — check back in a little while.",
               comment: "Home companion thought bubble when the user keeps petting a settled companion. Warm, never a refusal. Fern is the companion's name.")
    }

    // MARK: - Milestones card

    /// The milestones card's one-line summary, from the kinds of care kept and the coins gifted.
    ///
    /// - Parameters:
    ///   - keptKinds: How many kinds of care have a lifetime count above zero.
    ///   - coins: The milestone coins gifted so far.
    /// - Returns: A warm sentence; never a scoreboard, and the empty case is an invitation.
    static func milestonesSummary(keptKinds: Int, coins: Int) -> String {
        guard keptKinds > 0 else {
            return String(localized: "home.milestones.summary.empty",
                          defaultValue: "Your keepsake shelf is waiting — every bit of care will find a place here.",
                          comment: "Home milestones card, before any care has been kept. A gentle invitation, never a to-do.")
        }
        guard coins > 0 else {
            return String(localized: "home.milestones.summary.allTime",
                          defaultValue: "\(keptKinds) kinds of care kept so far, added up over all time.",
                          comment: "Home milestones card: how many kinds of care (journal, meals, movement, water, breathing, worries) have been kept. Needs a plural variation per language; English says 'One kind of care' for one.")
        }
        let kept = String(localized: "home.milestones.summary.keptSoFar",
                          defaultValue: "\(keptKinds) kinds of care kept so far",
                          comment: "Home milestones card, first half of the summary when coins were gifted: how many kinds of care have been kept. Needs a plural variation per language; English says 'One kind of care kept so far' for one.")
        let gifted = String(localized: "home.milestones.summary.coinsGifted",
                            defaultValue: "\(coins) coins gifted",
                            comment: "Home milestones card, second half of the summary: how many coins milestone gifts have added. Needs a plural variation per language.")
        return String(localized: "home.milestones.summary.keptAndGifted",
                      defaultValue: "\(kept) · \(gifted).",
                      comment: "Home milestones card summary when coins were gifted. The first placeholder is the kinds-of-care clause ('3 kinds of care kept so far'), the second the coins clause ('40 coins gifted'). Reorder or re-punctuate freely.")
    }

    /// The milestones card's coin pill: "40 gifted".
    static func coinsGiftedPill(_ coins: Int) -> String {
        String(localized: "home.milestones.coinsGifted.pill", defaultValue: "\(coins) gifted",
               comment: "Home milestones card: the small pill beside the title counting coins gifted by milestones, beside a star glyph. The noun (coins) is implied. Needs a plural variation per language.")
    }

    // MARK: - Quick-log tiles

    /// The Meals tile's count: "3 logged".
    static func mealsLogged(_ count: Int) -> String {
        String(localized: "home.quickLog.meals.count", defaultValue: "\(count) logged",
               comment: "Home quick-log Meals tile, under the word Meals: how many meals are logged today. The implied noun is meals. Needs a plural variation per language.")
    }

    /// The Move tile's count: "2 logged".
    static func workoutsLogged(_ count: Int) -> String {
        String(localized: "home.quickLog.move.count", defaultValue: "\(count) logged",
               comment: "Home quick-log Move tile, under the word Move: how many workouts are logged today. The implied noun is workouts. Needs a plural variation per language.")
    }

    /// The Water tile's count: "6 bottles".
    static func waterBottles(_ count: Int) -> String {
        String(localized: "home.quickLog.water.count", defaultValue: "\(count) bottles",
               comment: "Home quick-log Water tile: how many bottles of water are logged today. Needs a plural variation per language; English says '1 bottle'.")
    }

    /// The Journal tile's count: "2 entries".
    static func journalEntries(_ count: Int) -> String {
        String(localized: "home.quickLog.journal.count", defaultValue: "\(count) entries",
               comment: "Home quick-log Journal tile: how many journal entries are written today. Needs a plural variation per language; English says '1 entry'.")
    }

    // MARK: - Customize sheet

    /// The Wardrobe row's count of the person's own designed items: "3 items".
    static func wardrobeItemCount(_ count: Int) -> String {
        String(localized: "home.customize.wardrobe.itemCount", defaultValue: "\(count) items",
               comment: "Customize sheet: the Wardrobe row's count of companion items the user designed. Needs a plural variation per language; English says '1 item'.")
    }

    // MARK: - Photowall

    /// The first placeholder polaroid's caption, shown before the wall has seeds of its own.
    static var photowallParkWalk: String {
        String(localized: "home.photowall.caption.parkWalk", defaultValue: "park walk",
               comment: "Home photowall: handwritten lowercase caption on a placeholder polaroid. A walk in a park.")
    }

    /// The second placeholder polaroid's caption.
    static var photowallDinner: String {
        String(localized: "home.photowall.caption.dinner", defaultValue: "dinner",
               comment: "Home photowall: handwritten lowercase caption on a placeholder polaroid. The evening meal.")
    }

    /// "morning": the third placeholder polaroid's caption, and one of the seeded default captions.
    static var photowallMorning: String {
        String(localized: "home.photowall.caption.morning", defaultValue: "morning",
               comment: "Home photowall: handwritten lowercase caption on a polaroid. The early part of the day.")
    }

    /// The fourth placeholder polaroid's caption.
    static var photowallMusic: String {
        String(localized: "home.photowall.caption.music", defaultValue: "music",
               comment: "Home photowall: handwritten lowercase caption on a placeholder polaroid.")
    }

    /// A seeded polaroid's caption as drawn.
    ///
    /// `LaunchPreparationService` seeds the wall with the person's memory categories and, to fill four
    /// tiles, the English defaults "morning", "meal", "movement" and "moment". Those four are mapped
    /// to their keys here by exact match (the `StoredWorkoutName` shape); anything else is the
    /// person's own category and is drawn as it came.
    ///
    /// - Parameter stored: The caption on the seed.
    /// - Returns: The localized default, or `stored` unchanged.
    static func photowallCaption(_ stored: String) -> String {
        switch stored {
        case "morning": photowallMorning
        case "meal":
            String(localized: "home.photowall.caption.meal", defaultValue: "meal",
                   comment: "Home photowall: handwritten lowercase caption on a friend's polaroid when there is no category of the user's own to show.")
        case "movement":
            String(localized: "home.photowall.caption.movement", defaultValue: "movement",
                   comment: "Home photowall: handwritten lowercase caption on a friend's polaroid (exercise, moving the body).")
        case "moment":
            String(localized: "home.photowall.caption.moment", defaultValue: "moment",
                   comment: "Home photowall: handwritten lowercase caption on a friend's polaroid (a small moment in the day).")
        default: stored
        }
    }
}

//
//  MilestonesView.swift
//  Fernlet
//
//  A modest lifetime-milestones surface: warm cumulative counts of care ("You've written 40
//  journal moments") plus the little coin gifts each milestone added. Cumulative ONLY — no rates,
//  no per-week stats, no completion percentages, and never anything "in a row". Counts come from
//  the append-only milestone ledger, so between wipes they can only grow — deleting entries or
//  disabling HealthKit never takes a milestone away. "Delete everything" is the one exception:
//  since 2026-08-20 the wipe clears the ledger too (a dated trail of when you journaled is not
//  a wipe survivor).
//
//  Since design `b2-milestones` draft 2 (2026-10-24) the numbers live in the Stamp book
//  (`StampBookPage`): a framed medal per kind of care on wooden shelves, then the silly stamps and stats.
//  This file keeps the sheet that hosts it, the row model and the copy.
//

import SwiftUI
import FernletDomainModel
import StoreCore
import FernletUI

/// The Stamp book in a sheet: ``StampBookPage`` under the sheet's paper header, “Stamp book”, with Done.
///
/// Milestones, the keepsake shelf and Silly stats are one page since design `b2-milestones` draft 2
/// (approved 2026-10-24). The Today panel pushes the page under its plate; this sheet is the same page
/// for the routed `.milestones` and `.sillyStats` sheets (the stamp banner opens the latter, at the
/// stamps). Its own `NavigationStack`, so the page lays out as it does when pushed.
struct MilestonesView: View {
    var store: FernletStore
    /// Opens at the silly stamps rather than the top.
    var startsAtStamps = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StampBookPage(store: store, startsAtStamps: startsAtStamps)
                .fernletSheetToolbar(title: Text(StampBookTitle.resource), onDone: { dismiss() })
        }
        .fernletSheet()
    }
}

// MARK: - Warm display copy

/// Warm display copy per milestone kind.
///
/// Kept as a tiny model so the row order and phrasing live in one place (and copy stays
/// count-aware without pluralization bugs). Built by ``MilestoneRowModel/rows(counts:worriesLetGo:)``,
/// which also encodes the worry-kind exceptions: worry counts come from the device-local Worry
/// Box rather than the synced ledger, and worries award no coins.
struct MilestoneRowModel {
    let kind: MilestoneEventKind
    let icon: String
    let tint: Color
    let headline: String
    /// Gifts on the shelf for this kind, counted from the COIN ledger's milestone award rows —
    /// the same rows `CoinEconomy.milestoneAwardCoins` sums for the footer (HOME-20's one-source
    /// rule), so a row's gift line can never disagree with the coins summary.
    let giftCount: Int
    /// Raw lifetime count — drives the shelf medallions, empty-vs-filled row styling, and the
    /// mostly-empty header decision. (The sentence in `headline` already folds this in.)
    let count: Int
    /// A short lower-case caption under a Stamp book medal ("journal moments", "worries let go").
    let shelfLabel: String
    /// A gentle "your first … will land here" line for a kind with no count yet.
    let emptyPrompt: String

    /// The ONE icon + tint per milestone kind, for every surface that draws a keepsake — this
    /// screen's rows, the keepsake shelf, and Home's milestones card. It used to be duplicated on
    /// Home, where journal was a moss "book" and workouts terracotta, so the same keepsake changed
    /// glyph and colour one tap later. Exhaustive on purpose: a new `MilestoneEventKind` is a
    /// compile error here rather than an unstyled token on one surface only.
    static func style(for kind: MilestoneEventKind) -> (icon: String, tint: Color) {
        switch kind {
        case .journal: ("book.closed", .journalMedal)
        case .meal: ("fork.knife", .mealMedal)
        case .workout: ("figure.walk", .workoutMedal)
        case .water: ("drop", .waterMedal)
        case .breathing: ("wind", .breathingMedal)
        case .worry: ("archivebox", .worryMedal)
        // NOT a keepsake: `.resetBoundary` is the wipe's own bookkeeping row (see
        // `MilestoneEventKind.resetBoundary`), and it reaches no display path — `rows(counts:
        // worriesLetGo:)` builds from the fixed `order` list below, and Home's shelf iterates
        // `MilestoneEconomy.countedKinds`, both of which exclude it. This arm exists only to keep
        // the switch exhaustive (so a real new kind stays a compile error here); it can never render,
        // and it deliberately does not invent a medallion for "you deleted everything".
        case .resetBoundary: ("circle.dotted", .bark)
        }
    }

    /// Builds the display rows. `giftCounts` is ``giftCounts(in:)``'s coin-ledger derivation —
    /// defaulted empty so callers (and tests) that only care about counts/headlines still build;
    /// a row without a gift entry simply shows no shelf line.
    static func rows(
        counts: [MilestoneEventKind: Int],
        worriesLetGo: Int,
        giftCounts: [MilestoneEventKind: Int] = [:]
    ) -> [MilestoneRowModel] {
        let order: [MilestoneEventKind] = [.journal, .meal, .workout, .water, .breathing, .worry]
        return order.map { kind in
            let (icon, tint) = style(for: kind)
            // Worry counts come from the device-local Worry Box (never the synced ledger), and worries
            // award no coins (a device-local coin award would desync the wallet), so their "gifts" is 0.
            let count = kind == .worry ? worriesLetGo : (counts[kind] ?? 0)
            return MilestoneRowModel(
                kind: kind,
                icon: icon,
                tint: tint,
                headline: headline(kind: kind, count: count),
                giftCount: kind == .worry ? 0 : (giftCounts[kind] ?? 0),
                count: count,
                shelfLabel: MilestonesCopy.shelfLabel(for: kind),
                emptyPrompt: MilestonesCopy.emptyPrompt(for: kind)
            )
        }
    }

    /// Gifts on the shelf per kind, derived from the COIN ledger's counted milestone award rows —
    /// the SAME rows `CoinEconomy.milestoneAwardCoins` sums for the footer, filtered by the same
    /// reset rule the wallet applies (a stale pre-reset award re-synced from an offline device is
    /// excluded by `createdAt`). This is HOME-20's one source: the old per-row figure counted
    /// thresholds crossed on the append-only event ledger, which a reset voids differently, so a
    /// row could claim gifts the coins footer denied. `.resetBoundary` can never appear — award
    /// ids only ever carry counted kinds, and the `countedKinds` guard makes that structural.
    static func giftCounts(in coinEntries: [CoinLedgerEntry]) -> [MilestoneEventKind: Int] {
        let deduped = CoinEconomy.deduplicatedByID(coinEntries)
        let reset = CoinEconomy.latestReset(in: deduped)
        var counts: [MilestoneEventKind: Int] = [:]
        for entry in deduped {
            guard entry.kind == .earn, entry.id.hasPrefix("milestone:") else { continue }
            if let reset, entry.createdAt <= reset.createdAt { continue }
            // Award ids are `milestone:<kind>:<threshold>` (see `MilestoneEconomy.awardID`).
            let parts = entry.id.split(separator: ":")
            guard parts.count == 3,
                  let kind = MilestoneEventKind(rawValue: String(parts[1])),
                  MilestoneEconomy.countedKinds.contains(kind) else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
    }

    /// The row's warm sentence: a gathering line at zero, a "first" line at one, a counted line
    /// after that. The three are separate catalog keys, because "your first journal moment" is a
    /// different sentence from the count, not its singular; the counted key is plural-ruled for the
    /// languages whose plural forms don't stop at one (``MilestonesCopy``).
    private static func headline(kind: MilestoneEventKind, count: Int) -> String {
        // Unreachable by construction, like the `style(for:)` arm above: `rows(counts:worriesLetGo:)`
        // is this function's only caller and it never passes the marker kind. Empty rather than a
        // warm sentence, so a future caller that did reach it would render nothing at all rather
        // than a milestone celebrating a wipe.
        guard kind != .resetBoundary else { return "" }
        switch count {
        case 0: return MilestonesCopy.gatheringHeadline(for: kind)
        case 1: return MilestonesCopy.firstHeadline(for: kind)
        default: return MilestonesCopy.countedHeadline(for: kind, count: count)
        }
    }
}

// MARK: - Milestone copy

/// The milestones screen's `String`-typed copy, resolved through the app's string catalog.
///
/// Every count is a plural-ruled key (`%lld`, `one`/`other` authored in the catalog) rather than
/// two English literals picked by `count == 1`, so a language with more plural forms than English
/// gets them. ``MilestoneEventKind/resetBoundary`` reaches none of these: it is the wipe's
/// bookkeeping row, never a keepsake, and each switch below gives it an empty string only to stay
/// exhaustive.
enum MilestonesCopy {

    /// The keepsake-shelf link's gift count: "4 gifts".
    static func giftCount(_ count: Int) -> String {
        String(localized: "milestones.shelfLink.giftCount", defaultValue: "\(count) gifts",
               comment: "Milestones screen: the Keepsake shelf link's count of milestone gifts. Needs a plural variation per language; English says '1 gift'.")
    }

    /// A row's gift line: "2 gifts on the shelf".
    static func giftsOnShelf(_ count: Int) -> String {
        String(localized: "milestones.row.giftsOnShelf", defaultValue: "\(count) gifts on the shelf",
               comment: "Milestones screen, under a kind of care: how many milestone gifts it has put on the keepsake shelf. Needs a plural variation per language; English says '1 gift on the shelf'.")
    }

    /// The coins footer: "Milestone gifts have added 40 coins to your pouch."
    static func coinsAdded(_ coins: Int) -> String {
        String(localized: "milestones.coins.added",
               defaultValue: "Milestone gifts have added \(coins) coins to your pouch.",
               comment: "Milestones screen and keepsake shelf footer: the coins milestone gifts have added to the user's coin pouch. Needs a plural variation per language.")
    }

    /// The short lower-case label under a Stamp book medal, below its count (design `b2-milestones`,
    /// draft 2). A caption for the tally, so it reads the same at any count.
    static func shelfLabel(for kind: MilestoneEventKind) -> String {
        switch kind {
        case .journal: String(localized: "stampBook.medal.journal", defaultValue: "journal moments",
                              comment: "Stamp book: lowercase caption under the journal medal, below its lifetime count. A tally caption, the same at any count.")
        case .meal: String(localized: "stampBook.medal.meals", defaultValue: "meals noted",
                           comment: "Stamp book: lowercase caption under the meals medal, below its lifetime count. A tally caption, the same at any count.")
        case .workout: String(localized: "stampBook.medal.workouts", defaultValue: "workouts on purpose",
                              comment: "Stamp book: lowercase caption under the workouts medal, below its lifetime count. A tally caption, the same at any count.")
        case .water: String(localized: "stampBook.medal.water", defaultValue: "well-watered days",
                            comment: "Stamp book: lowercase caption under the water medal, below its count of days the water target was met. A tally caption, the same at any count.")
        case .breathing: String(localized: "stampBook.medal.breathing", defaultValue: "breathing breaks",
                                comment: "Stamp book: lowercase caption under the breathing medal, below its count of breathing breaks. A tally caption, the same at any count.")
        case .worry: String(localized: "stampBook.medal.worries", defaultValue: "worries let go",
                            comment: "Stamp book: lowercase caption under the worry medal, below its count of worries let go. A tally caption, the same at any count.")
        case .resetBoundary: ""
        }
    }

    /// The dashed "your first … will land here" line for a kind with nothing yet.
    static func emptyPrompt(for kind: MilestoneEventKind) -> String {
        switch kind {
        case .journal: String(localized: "milestones.empty.journal", defaultValue: "Your first journal moment will land here.",
                              comment: "Milestones screen: a quiet placeholder row before the first journal entry. Never a to-do.")
        case .meal: String(localized: "milestones.empty.meal", defaultValue: "Your first noticed meal will land here.",
                           comment: "Milestones screen: a quiet placeholder row before the first logged meal. Never a to-do.")
        case .workout: String(localized: "milestones.empty.workout", defaultValue: "Your first time moving will land here.",
                              comment: "Milestones screen: a quiet placeholder row before the first logged workout. Never a to-do.")
        case .water: String(localized: "milestones.empty.water", defaultValue: "Your first well-watered day will land here.",
                            comment: "Milestones screen: a quiet placeholder row before the first day the water target was met. Never a to-do.")
        case .breathing: String(localized: "milestones.empty.breathing", defaultValue: "Your first slow-breathing break will land here.",
                                comment: "Milestones screen: a quiet placeholder row before the first finished breathing exercise. Never a to-do.")
        case .worry: String(localized: "milestones.empty.worry", defaultValue: "Your first worry let go will land here.",
                            comment: "Milestones screen: a quiet placeholder row before the first worry released from the Worry Box. Never a to-do.")
        case .resetBoundary: ""
        }
    }

    /// A kind's sentence while its count is zero.
    static func gatheringHeadline(for kind: MilestoneEventKind) -> String {
        switch kind {
        case .journal: String(localized: "milestones.headline.journal.none", defaultValue: "Your journal moments will gather here.",
                              comment: "Milestones: the journal row's sentence before any entry.")
        case .meal: String(localized: "milestones.headline.meal.none", defaultValue: "Meals you notice will gather here.",
                           comment: "Milestones: the meals row's sentence before any logged meal.")
        case .workout: String(localized: "milestones.headline.workout.none", defaultValue: "Times you move will gather here.",
                              comment: "Milestones: the movement row's sentence before any logged workout.")
        case .water: String(localized: "milestones.headline.water.none", defaultValue: "Days you drink enough water will gather here.",
                            comment: "Milestones: the water row's sentence before any well-watered day.")
        case .breathing: String(localized: "milestones.headline.breathing.none", defaultValue: "Breathing breaks will gather here.",
                                comment: "Milestones: the breathing row's sentence before any breathing break.")
        case .worry: String(localized: "milestones.headline.worry.none", defaultValue: "Worries you let go will gather here.",
                            comment: "Milestones: the worries row's sentence before any worry let go.")
        case .resetBoundary: ""
        }
    }

    /// A kind's sentence at exactly one: a "first" line, not the count's singular.
    static func firstHeadline(for kind: MilestoneEventKind) -> String {
        switch kind {
        case .journal: String(localized: "milestones.headline.journal.first", defaultValue: "You've written your first journal moment.",
                              comment: "Milestones: the journal row after exactly one entry. Warm, a memory not a metric.")
        case .meal: String(localized: "milestones.headline.meal.first", defaultValue: "You've noted your first meal.",
                           comment: "Milestones: the meals row after exactly one logged meal.")
        case .workout: String(localized: "milestones.headline.workout.first", defaultValue: "You've moved your body once, on purpose.",
                              comment: "Milestones: the movement row after exactly one logged workout.")
        case .water: String(localized: "milestones.headline.water.first", defaultValue: "You've had one well-watered day.",
                            comment: "Milestones: the water row after exactly one day the water target was met.")
        case .breathing: String(localized: "milestones.headline.breathing.first", defaultValue: "You've taken one slow-breathing break.",
                                comment: "Milestones: the breathing row after exactly one finished breathing exercise.")
        case .worry: String(localized: "milestones.headline.worry.first", defaultValue: "You've let one worry go.",
                            comment: "Milestones: the worries row after exactly one worry released from the Worry Box.")
        case .resetBoundary: ""
        }
    }

    /// A kind's sentence from two up: "You've written 40 journal moments."
    static func countedHeadline(for kind: MilestoneEventKind, count: Int) -> String {
        switch kind {
        case .journal: String(localized: "milestones.headline.journal.count", defaultValue: "You've written \(count) journal moments.",
                              comment: "Milestones: the journal row's lifetime count (2 or more; exactly one has its own sentence). Needs a plural variation per language.")
        case .meal: String(localized: "milestones.headline.meal.count", defaultValue: "You've noted \(count) meals.",
                           comment: "Milestones: the meals row's lifetime count (2 or more). Needs a plural variation per language.")
        case .workout: String(localized: "milestones.headline.workout.count", defaultValue: "You've moved your body \(count) times.",
                              comment: "Milestones: the movement row's lifetime count of workouts (2 or more). Needs a plural variation per language.")
        case .water: String(localized: "milestones.headline.water.count", defaultValue: "You've had \(count) well-watered days.",
                            comment: "Milestones: the water row's lifetime count of days the water target was met (2 or more). Needs a plural variation per language.")
        case .breathing: String(localized: "milestones.headline.breathing.count", defaultValue: "You've taken \(count) slow-breathing breaks.",
                                comment: "Milestones: the breathing row's lifetime count (2 or more). Needs a plural variation per language.")
        case .worry: String(localized: "milestones.headline.worry.count", defaultValue: "You've let \(count) worries go.",
                            comment: "Milestones: the worries row's lifetime count of worries let go (2 or more). Needs a plural variation per language.")
        case .resetBoundary: ""
        }
    }
}

// MARK: - Local shades

// Medallion metals + shelf/coin tones used only by this screen. Kept as private local constants so
// the shared palette isn't touched; each adapts for light + dark via the existing Color(light:dark:).
private extension Color {
    // Journal — soft amethyst.
    static let journalMedal = Color(
        light: Color(red: 0.663, green: 0.608, blue: 0.706),
        dark:  Color(red: 0.541, green: 0.486, blue: 0.596)
    )
    // Meals — warm honey.
    static let mealMedal = Color(
        light: Color(red: 0.788, green: 0.588, blue: 0.290),
        dark:  Color(red: 0.706, green: 0.514, blue: 0.243)
    )
    // Workouts — living green.
    static let workoutMedal = Color(
        light: Color(red: 0.420, green: 0.620, blue: 0.384),
        dark:  Color(red: 0.361, green: 0.529, blue: 0.329)
    )
    // Water — river blue.
    static let waterMedal = Color(
        light: Color(red: 0.549, green: 0.651, blue: 0.714),
        dark:  Color(red: 0.443, green: 0.541, blue: 0.604)
    )
    // Breathing — sage green.
    static let breathingMedal = Color(
        light: Color(red: 0.541, green: 0.678, blue: 0.494),
        dark:  Color(red: 0.451, green: 0.573, blue: 0.408)
    )
    // Worries let go — gilded gold.
    static let worryMedal = Color(
        light: Color(red: 0.831, green: 0.659, blue: 0.263),
        dark:  Color(red: 0.741, green: 0.573, blue: 0.220)
    )
}

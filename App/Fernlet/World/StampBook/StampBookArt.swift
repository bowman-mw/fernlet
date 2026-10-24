import SwiftUI
import FernletDomainModel

/// The Stamp book's pixel art (design `b2-milestones`, draft 2): each kind of care's medal art and disc
/// colour, each silly stat's card icon, and how art sits on a disc.
///
/// The discs keep their light colours in both appearances, like a stamp on a dark page, so art drawn on
/// one stays in the design's ink there: a one-colour ink sprite on a disc takes ink, never the page's
/// cream ink token (which would vanish on gold).
enum StampBookArt {
    /// The medal art and disc fill (`0xRRGGBB`) for a kind of care.
    static func keepsake(for kind: MilestoneEventKind) -> (sprite: WorldSprite, fill: UInt32) {
        switch kind {
        case .journal: (WorldSprites.diary, 0xC9BEDB)
        case .meal: (WorldSprites.onigiri, 0xE6B566)
        case .workout: (WorldSprites.shoe, 0x9FC58D)
        case .water: (WorldSprites.drop, 0xA9C6DA)
        case .breathing: (WorldSprites.breathe, 0xC6DDB8)
        case .worry: (WorldSprites.box, 0xE8CFA6)
        // Never drawn: the wipe's bookkeeping row is no keepsake (``MilestoneRowModel/rows(counts:worriesLetGo:giftCounts:)``).
        case .resetBoundary: (WorldSprites.stampMed, 0xE8CFA6)
        }
    }

    /// A silly stat's icon beside its title: the stamp's art, or the bathtub for the Bathtub Index (the
    /// duck is that stat's stamp).
    static func statIcon(for kind: SillyStatKind) -> WorldSprite {
        kind == .bathtubIndex ? WorldSprites.tub : WorldStampArt.sprite(for: kind)
    }

    /// The tint for `sprite` drawn on a light disc: ink for a one-colour ink sprite, its own colours otherwise.
    static func discTint(for sprite: WorldSprite) -> Color? {
        sprite.isMonoInk ? WorldPalette.rgb(WorldSprite.ink) : nil
    }

    /// The gold of an earned stamp's disc.
    static let stampGold: UInt32 = 0xF2D58A
    /// An unearned stamp's faded silhouette.
    static let silhouette: UInt32 = 0xC9BBA0
}

/// The Stamp book's own copy. Every string resolves through the app's catalog; the counted ones reuse
/// the plural-ruled milestone keys (``MilestonesCopy``).
enum StampBookCopy {
    /// What lands next, under the dashed slot's “Next”: “a breathing break”.
    static func nextLabel(for kind: MilestoneEventKind) -> String {
        switch kind {
        case .journal: String(localized: "stampBook.next.journal", defaultValue: "a journal moment",
                              comment: "Stamp book: under 'Next' on the dashed keepsake slot, the next kind of care to land. Lowercase, a quiet noun phrase.")
        case .meal: String(localized: "stampBook.next.meal", defaultValue: "a noted meal",
                           comment: "Stamp book: under 'Next' on the dashed keepsake slot, the first logged meal. Lowercase noun phrase.")
        case .workout: String(localized: "stampBook.next.workout", defaultValue: "a workout on purpose",
                              comment: "Stamp book: under 'Next' on the dashed keepsake slot, the first logged workout. Lowercase noun phrase.")
        case .water: String(localized: "stampBook.next.water", defaultValue: "a well-watered day",
                            comment: "Stamp book: under 'Next' on the dashed keepsake slot, the first day the water target is met. Lowercase noun phrase.")
        case .breathing: String(localized: "stampBook.next.breathing", defaultValue: "a breathing break",
                                comment: "Stamp book: under 'Next' on the dashed keepsake slot, the first finished breathing exercise. Lowercase noun phrase.")
        case .worry: String(localized: "stampBook.next.worry", defaultValue: "a worry let go",
                            comment: "Stamp book: under 'Next' on the dashed keepsake slot, the first worry released from the Worry Box. Lowercase noun phrase.")
        case .resetBoundary: ""
        }
    }

    /// A medal's one VoiceOver sentence: the warm count, then its gifts when it has any.
    static func medalAccessibility(_ row: MilestoneRowModel) -> String {
        guard row.giftCount > 0 else { return row.headline }
        let gifts = MilestonesCopy.giftsOnShelf(row.giftCount)
        return String(localized: "stampBook.medal.accessibility", defaultValue: "\(row.headline) \(gifts).",
                      comment: "Stamp book, VoiceOver for a keepsake medal: the warm count sentence ('You've written 2 journal moments.'), then its gifts ('1 gift on the shelf').")
    }
}

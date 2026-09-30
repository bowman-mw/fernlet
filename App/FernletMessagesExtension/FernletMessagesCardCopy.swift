//
//  FernletMessagesCardCopy.swift
//  FernletMessagesExtension (also compiled into the Fernlet app target)
//
//  The copy a sent recipe card CARRIES — its captions, its wordmark, its summary line and its three
//  counts — split out of `FernletMessagesCopy` on 2026-09-30, when the app's recipe Share screen
//  started composing the same card the iMessage app inserts ("Send in Messages").
//
//  WHY A SECOND VAULT. The card is built by `FernletMessagesCard`, which both targets compile, so
//  every string it reads must compile in both. `FernletMessagesCopy` is the extension's whole
//  display surface and stays extension-only; this file holds only what the card needs. Keys and
//  default values are unchanged from the extension vault, so the extension's catalog does not move.
//
//  TWO CATALOGS, ONE KEY SET. There is no `bundle:` argument, deliberately, for the reason
//  `FernletMessagesCopy` gives: each process resolves against its own `Bundle.main`. In the
//  extension that is `App/FernletMessagesExtension/Localizable.xcstrings`; in the app it is
//  `App/Fernlet/Localizable.xcstrings`, which `Scripts/sync-string-catalogs.sh` fills with these
//  keys because the file is a member of the app target. A card sent from either place therefore
//  reads in the SENDER's language, as it always has. The three counts carry `one`/`other` plural
//  blocks that `xcstringstool sync` never invents, so they are hand-authored in BOTH catalogs;
//  `LocalizationBoundaryTests.countBearingKeysCarryPluralVariations()` pins both, and
//  `MessagesExtensionBoundaryTests.everyCopyVaultKeyReachedTheCatalog()` pins every key in both.
//
//  Members are COMPUTED, never stored, so the lookup happens at use time under the current locale.
//

import Foundation

/// The sentences and counts a Fernlet recipe card carries, shared by the iMessage app and the app's
/// "Send in Messages" row so both mint byte-identical cards.
enum FernletMessagesCardCopy {

    // MARK: - Counts (plural-ruled in both catalogs)

    static func servingCount(_ count: Int) -> String {
        String(localized: "messages.recipe.servingCount", defaultValue: "\(count) servings",
               comment: "Serving count in a recipe card's subtitle, e.g. '4 servings'. Needs a plural variation per language; English also needs the one-serving form.")
    }

    static func ingredientCount(_ count: Int) -> String {
        String(localized: "messages.recipe.ingredientCount", defaultValue: "\(count) ingredients",
               comment: "Ingredient count in a recipe card's subtitle, e.g. '9 ingredients'. Needs a plural variation per language; English also needs the one-ingredient form.")
    }

    static func stepCount(_ count: Int) -> String {
        String(localized: "messages.recipe.stepCount", defaultValue: "\(count) steps",
               comment: "Step count in a recipe card's subtitle, e.g. '6 steps'. Needs a plural variation per language; English also needs the one-step form.")
    }

    // MARK: - The card

    static func messageSummary(title: String) -> String {
        String(localized: "messages.card.summaryText", defaultValue: "Fernlet: \(title)",
               comment: "The card's accessibility/notification summary — what Messages reads aloud and shows in a notification preview. %@ is the item's own title.")
    }

    static var cardNotesIncluded: String {
        String(localized: "messages.card.notesIncluded", defaultValue: "Notes included",
               comment: "Trailing caption on the sent recipe card, telling the recipient a written note travels with it. Keep it short — Messages truncates this corner hard.")
    }

    static var cardRecipe: String {
        String(localized: "messages.card.recipe", defaultValue: "Fernlet recipe",
               comment: "Trailing caption on a sent recipe card carrying no note. Keep it short — Messages truncates this corner hard.")
    }

    /// The one line on a sent card aimed at a recipient who CANNOT open it (2026-09-30). The card is a
    /// serverless `data:` URL bound to Fernlet's iMessage extension, so on a device without that
    /// extension — no Fernlet, a Fernlet build older than 24, an iPad or a Mac — Messages answers a tap
    /// with its own install sheet, which has nothing to show while Fernlet has no public App Store page.
    /// Messages draws the template layout itself, so this line is EXPECTED to be what that recipient
    /// can read — unverified: it has been seen only on a recipient that has the extension. It does not
    /// fill the sheet. (The owner's "pops up and is blank" report turned out to be something else: a
    /// stale extension registration inside a Messages process that outlived a Fernlet update, fixed by
    /// force-quitting Messages — see the extension's DocC page.) Fernlet users see the line too, hence
    /// the neutral wording.
    static var cardOpensInFernlet: String {
        String(localized: "messages.card.opensInFernlet", defaultValue: "Opens in Fernlet on iPhone",
               comment: "Small line in the lower-right corner of every sent recipe or workout card. Every recipient reads it, including one whose device cannot open the card (no Fernlet, an older Fernlet, an iPad or a Mac), so it says where the card opens, neutrally, without instructions. 'Fernlet' is the product name and must NOT be translated; 'iPhone' is Apple's product name. Keep it short — Messages truncates this corner hard.")
    }

    static var recipeWordmark: String {
        String(localized: "messages.card.wordmark.recipe", defaultValue: "FERNLET RECIPE",
               comment: "Wordmark DRAWN INTO the card artwork the recipient sees in the conversation. Rendered at 28pt into a 1200×630 image, so a much longer translation will not fit; upper case matches the mark. 'Fernlet' is the product name and must not be translated.")
    }
}

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
//  ONE CATALOG, READ FROM BOTH PROCESSES (fix round 2, 2026-09-30). Every string here passes
//  `bundle: catalog`, and `catalog` is the iMessage app's own bundle wherever this file runs: in
//  the extension that is `Bundle.main`; in the app it is the extension bundle the app embeds
//  (`PlugIns/FernletMessagesExtension.appex`). So the card "Send in Messages" composes and the card
//  the iMessage app inserts are read out of ONE catalog,
//  `App/FernletMessagesExtension/Localizable.xcstrings`, the three counts' hand-authored
//  `one`/`other` blocks included. Round 1 let the app read its own `Bundle.main` instead, which
//  needed a second, hand-copied set of the eight keys in `App/Fernlet/Localizable.xcstrings`;
//  until that copy existed the app's card read "1 servings · 1 ingredients · 1 steps" beside the
//  iMessage app's "1 serving · 1 ingredient · 1 step" (review C-F1/L-F1), and after it the two
//  catalogs could part again with every translation. Now there is nothing to copy and nothing to
//  drift. `Scripts/sync-string-catalogs.sh` keeps these keys out of the app catalog (the app target
//  compiles this file, so its build harvests them too), where they would be dead entries a
//  translator still translates.
//
//  The lookup still runs in the SENDER's process, so a card reads in the sender's language as it
//  always has: the app process resolves the extension's localizations against its own language
//  preference. `MessagesRecipeCardParityTests` holds the app's resolved card to the embedded
//  extension bundle's at one of each and at four, and `catalog` to BE that bundle in the app;
//  `MessagesExtensionBoundaryTests.theSharedCardCopyIsReadOnlyFromTheExtensionsCatalog()` holds
//  every string to `bundle: catalog` and the app catalog free of the keys, and
//  `.theSyncScriptKeepsTheCardCopyOutOfTheAppCatalog()` the script's exclusion. The counts' plural
//  blocks are pinned by `LocalizationBoundaryTests.countBearingKeysCarryPluralVariations()`, every
//  key by `MessagesExtensionBoundaryTests.everyCopyVaultKeyReachedTheCatalog()`.
//
//  Members are COMPUTED, never stored, so the lookup happens at use time under the current locale.
//  `catalog` is computed too; `Bundle(url:)` hands back its one cached instance per path.
//

import Foundation

/// The sentences and counts a Fernlet recipe card carries, shared by the iMessage app and the app's
/// "Send in Messages" row so both mint byte-identical cards.
enum FernletMessagesCardCopy {

    // MARK: - The one catalog

    /// The iMessage app's bundle name inside the app's `PlugIns` directory.
    static let embeddedExtensionName = "FernletMessagesExtension.appex"

    /// The bundle every card string is read from: the iMessage app's own, in either process.
    ///
    /// In the extension `Bundle.main` IS the appex, so this is `Bundle.main` and the lookup is the one
    /// the extension has always done. In the app it is the appex the app embeds, so the card the app
    /// composes reads the extension's catalog, not the app's. The `Bundle.main` fallback in the app is
    /// for a build that embeds no iMessage app, which could not send a Fernlet card at all; there
    /// each string reads its English `defaultValue`.
    static var catalog: Bundle {
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let plugIns = Bundle.main.builtInPlugInsURL,
              let embedded = Bundle(url: plugIns.appendingPathComponent(embeddedExtensionName, isDirectory: true)) else {
            return .main
        }
        return embedded
    }

    // MARK: - Counts (plural-ruled in the extension's catalog)

    static func servingCount(_ count: Int) -> String {
        String(localized: "messages.recipe.servingCount", defaultValue: "\(count) servings", bundle: catalog,
               comment: "Serving count in a recipe card's subtitle, e.g. '4 servings'. Needs a plural variation per language; English also needs the one-serving form.")
    }

    static func ingredientCount(_ count: Int) -> String {
        String(localized: "messages.recipe.ingredientCount", defaultValue: "\(count) ingredients", bundle: catalog,
               comment: "Ingredient count in a recipe card's subtitle, e.g. '9 ingredients'. Needs a plural variation per language; English also needs the one-ingredient form.")
    }

    static func stepCount(_ count: Int) -> String {
        String(localized: "messages.recipe.stepCount", defaultValue: "\(count) steps", bundle: catalog,
               comment: "Step count in a recipe card's subtitle, e.g. '6 steps'. Needs a plural variation per language; English also needs the one-step form.")
    }

    // MARK: - The card

    static func messageSummary(title: String) -> String {
        String(localized: "messages.card.summaryText", defaultValue: "Fernlet: \(title)", bundle: catalog,
               comment: "The card's accessibility/notification summary — what Messages reads aloud and shows in a notification preview. %@ is the item's own title.")
    }

    static var cardNotesIncluded: String {
        String(localized: "messages.card.notesIncluded", defaultValue: "Notes included", bundle: catalog,
               comment: "Trailing caption on the sent recipe card, telling the recipient a written note travels with it. Keep it short — Messages truncates this corner hard.")
    }

    static var cardRecipe: String {
        String(localized: "messages.card.recipe", defaultValue: "Fernlet recipe", bundle: catalog,
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
        String(localized: "messages.card.opensInFernlet", defaultValue: "Opens in Fernlet on iPhone", bundle: catalog,
               comment: "Small line in the lower-right corner of every sent recipe or workout card. Every recipient reads it, including one whose device cannot open the card (no Fernlet, an older Fernlet, an iPad or a Mac), so it says where the card opens, neutrally, without instructions. 'Fernlet' is the product name and must NOT be translated; 'iPhone' is Apple's product name. Keep it short — Messages truncates this corner hard.")
    }

    static var recipeWordmark: String {
        String(localized: "messages.card.wordmark.recipe", defaultValue: "FERNLET RECIPE", bundle: catalog,
               comment: "Wordmark DRAWN INTO the card artwork the recipient sees in the conversation. Rendered at 28pt into a 1200×630 image, so a much longer translation will not fit; upper case matches the mark. 'Fernlet' is the product name and must not be translated.")
    }
}

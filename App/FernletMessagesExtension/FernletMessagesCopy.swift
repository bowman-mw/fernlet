//
//  FernletMessagesCopy.swift
//  FernletMessagesExtension
//
//  The Messages extension's copy vault (documentation/test/review pass 2026-08-27, Track 3).
//
//  WHY THIS EXISTS. `FernletMessagesViewController` is the only UIKit view controller Fernlet
//  ships, and until this file every sentence in it was a bare English literal: 57 of them, from
//  the composer title down to the four "couldn't prepare this … for review" failures. None was in
//  any catalog, because the target owned no `Localizable.xcstrings` and had no line in
//  `Scripts/sync-string-catalogs.sh` — so even writing `String(localized:)` at those call sites
//  would have harvested nothing. The strings rendered English, correctly, in every language.
//
//  Nothing caught it. The localization wall's rules A and E read `FernletKit/Sources` only; rule F
//  is a TYPE check over `var`/`func` DECLARATIONS, and UIKit sets its copy by property ASSIGNMENT
//  (`label.text = "…"`), which declares nothing; rule G reads only `LocalizedError` members. Rules
//  H1 and H2 in `LocalizationBoundaryTests` were added with this file and close both halves — H1
//  the assignment shape anywhere, H2 every literal in this target.
//
//  WHY A VAULT rather than 57 inline calls, which is the house default (`FernletLockView` carries
//  68). Two reasons specific to this target:
//    * Power of 10 R4 caps a body at 60 code lines. `String(localized:defaultValue:comment:)` is
//      three or four lines per string, and the composer's render path already branches four ways;
//      inlining would have pushed several bodies over on copy alone.
//    * A UIKit controller reaches its copy from four shapes — property assignment, a
//      `UIButton.Configuration` title, a function argument, and a `MSMessageTemplateLayout`
//      caption. Collected here, the target's whole display surface is one auditable list; spread
//      over those four shapes it is exactly what went unnoticed for a round.
//  `FernletUICopy` and `FernletLockCopy` are the precedent.
//
//  NO `bundle:` ARGUMENT, deliberately. This is app-extension source, not package source: an
//  appex's `Bundle.main` IS its own bundle, so the default lookup already resolves against this
//  target's catalog. `bundle: .module` here would not compile, and `bundle: .main` would be a
//  no-op that reads like a decision.
//
//  Members are COMPUTED, never stored, so the lookup happens at use time under the user's current
//  locale — a stored `static let` would freeze whatever language the extension process launched
//  in, and a Messages extension outlives many foregroundings.
//
//  COUNTS carry plural rules. `servingCount`, `ingredientCount`, `stepCount` and `workoutCount`
//  are hand-authored in the catalog with `one`/`other` variations;
//  `LocalizationBoundaryTests.countBearingKeysCarryPluralVariations()` pins all four, because
//  `xcstringstool sync` preserves a plural block but will never invent one.
//

import Foundation

/// Every sentence the Messages extension shows a person, keyed and catalogued.
///
/// Separators (`" · "`) are NOT here and must not be: they carry no letters, so they are format
/// punctuation rather than copy, and rule H2 ignores them by construction.
enum FernletMessagesCopy {

    // MARK: - Chrome

    static var brand: String {
        String(localized: "messages.brand", defaultValue: "⌁  FERNLET",
               comment: "Wordmark above the composer title. 'Fernlet' is the product name and must NOT be translated; the ⌁ glyph and the two spaces are the mark's fixed typography. Translate only if the product ships under a different name in this language.")
    }

    static var modeRecipes: String {
        String(localized: "messages.mode.recipes", defaultValue: "Recipes",
               comment: "First segment of the two-way picker choosing what kind of Fernlet item to share. Plural noun, as a category name.")
    }

    static var modeWorkouts: String {
        String(localized: "messages.mode.workouts", defaultValue: "Workouts",
               comment: "Second segment of the two-way picker choosing what kind of Fernlet item to share. Plural noun, as a category name.")
    }

    static var searchRecipesPlaceholder: String {
        String(localized: "messages.search.recipesPlaceholder", defaultValue: "Search recipes",
               comment: "Placeholder in the search field while the recipe segment is selected.")
    }

    static var searchWorkoutsPlaceholder: String {
        String(localized: "messages.search.workoutsPlaceholder", defaultValue: "Search workout plans",
               comment: "Placeholder in the search field while the workout segment is selected. 'Workout plans' is the multi-session plan, not a single session.")
    }

    // MARK: - Actions

    static var browseLibrary: String {
        String(localized: "messages.action.browseLibrary", defaultValue: "Browse your library",
               comment: "Button expanding the compact composer, shown before the catalog has loaded and so before the kind of item is known. The two kind-specific forms are messages.action.browseRecipes and messages.action.browseWorkouts.")
    }

    static var browseRecipes: String {
        String(localized: "messages.action.browseRecipes", defaultValue: "Browse your recipes",
               comment: "Button expanding the compact composer to the full recipe list. A whole sentence rather than 'Browse your %@' on purpose: the noun cannot be spliced into a possessive in every language.")
    }

    static var browseWorkouts: String {
        String(localized: "messages.action.browseWorkouts", defaultValue: "Browse your workouts",
               comment: "Button expanding the compact composer to the full workout list. Sibling of messages.action.browseRecipes — see that comment for why the noun is not interpolated.")
    }

    static var share: String {
        String(localized: "messages.action.share", defaultValue: "Share ↗",
               comment: "Button inserting the selected item into the Messages conversation. The ↗ arrow is decorative and may be dropped if it reads badly in this language.")
    }

    static var reviewInFernlet: String {
        String(localized: "messages.action.review", defaultValue: "Review in Fernlet",
               comment: "Button on a RECEIVED item. It opens the Fernlet app to look the item over before saving — it does not save anything by itself, and must not be translated as 'Save' or 'Import'.")
    }

    // MARK: - VoiceOver hints

    static var browseHint: String {
        String(localized: "messages.hint.browse", defaultValue: "Shows the full bounded Fernlet Messages catalog.",
               comment: "VoiceOver hint on the browse button. 'Bounded' is meaningful: the extension can only ever see a capped catalog the app prepared, never the whole library.")
    }

    static var insertHint: String {
        String(localized: "messages.hint.insert", defaultValue: "Adds the selected Fernlet item to this Messages conversation.",
               comment: "VoiceOver hint on the share button. It adds the item to the conversation's draft; it does not send the message.")
    }

    static var reviewHint: String {
        String(localized: "messages.hint.review", defaultValue: "Opens Fernlet to review this item before saving it.",
               comment: "VoiceOver hint on the review button. 'Before saving' is the point — nothing is saved until the person confirms inside the Fernlet app.")
    }

    // MARK: - Composer titles

    static var shareRecipeTitle: String {
        String(localized: "messages.title.shareRecipe", defaultValue: "Share a recipe",
               comment: "Composer heading while the recipe segment is selected and the catalog has loaded.")
    }

    static var shareWorkoutTitle: String {
        String(localized: "messages.title.shareWorkout", defaultValue: "Share a workout",
               comment: "Composer heading while the workout segment is selected and the catalog has loaded.")
    }

    static var shareFernletRecipeTitle: String {
        String(localized: "messages.title.shareFernletRecipe", defaultValue: "Share a Fernlet recipe",
               comment: "Composer heading shown when NO catalog could be read, so the app name is spelled out to explain which app is asking. 'Fernlet' is the product name and must not be translated.")
    }

    static var shareFernletWorkoutTitle: String {
        String(localized: "messages.title.shareFernletWorkout", defaultValue: "Share a Fernlet workout",
               comment: "Workout counterpart of messages.title.shareFernletRecipe, shown when no catalog could be read.")
    }

    // MARK: - Catalog availability

    static var sharedStorageUnavailable: String {
        String(localized: "messages.status.sharedStorageUnavailable", defaultValue: "Fernlet shared storage isn't available.",
               comment: "Shown when the App Group container cannot be resolved at all, so the extension has nowhere to read the catalog from. A device/configuration fault, not something the person did.")
    }

    static var catalogUnreadable: String {
        String(localized: "messages.status.catalogUnreadable", defaultValue: "Fernlet couldn't read your Messages catalog. Open Fernlet and try again.",
               comment: "Shown when the App Group container exists but the catalog file is missing or corrupt. Opening the app rewrites it, which is why the second sentence is the remedy.")
    }

    static var emptyCatalog: String {
        String(localized: "messages.status.emptyCatalog", defaultValue: "Open Fernlet to prepare items for Messages.",
               comment: "Shown when the catalog read fine but holds nothing yet. The app publishes the catalog; the extension never builds one.")
    }

    // MARK: - Catalog cards

    static var selected: String {
        String(localized: "messages.card.selected", defaultValue: "Selected",
               comment: "VoiceOver value spoken for the currently chosen catalog card. Spoken after the card's name, as a state — not a button label.")
    }

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

    static func workoutCount(_ count: Int) -> String {
        String(localized: "messages.workout.sessionCount", defaultValue: "\(count) workouts",
               comment: "Number of sessions in a shared workout plan, e.g. '3 workouts'. Needs a plural variation per language; English also needs the one-workout form.")
    }

    static func recipeSubtitleWithNote(summary: String) -> String {
        String(localized: "messages.recipe.subtitleWithNote", defaultValue: "\(summary) · Note included",
               comment: "Recipe card subtitle when the sender's own note travels with the recipe. %@ is the servings/ingredients/steps summary.")
    }

    static func recipePreviewWithoutNote(summary: String) -> String {
        String(localized: "messages.recipe.previewNoNote", defaultValue: "\(summary) · No recipe note",
               comment: "Preview line for a selected recipe the sender chose NOT to attach a note to. %@ is the servings/ingredients/steps summary.")
    }

    static func recipeNotePreview(note: String) -> String {
        String(localized: "messages.recipe.notePreview", defaultValue: "Note: \(note)",
               comment: "Preview line quoting the sender's recipe note. %@ is the note itself, truncated to 120 characters by the caller.")
    }

    // MARK: - Inserting

    static var chooseRecipe: String {
        String(localized: "messages.status.chooseRecipe", defaultValue: "Choose a recipe to share.",
               comment: "Shown when the share button is pressed with no recipe card selected.")
    }

    static var chooseWorkout: String {
        String(localized: "messages.status.chooseWorkout", defaultValue: "Choose a workout plan to share.",
               comment: "Shown when the share button is pressed with no workout card selected.")
    }

    static var recipeInserted: String {
        String(localized: "messages.status.recipeInserted", defaultValue: "Recipe inserted.",
               comment: "Confirms the recipe card is now in the conversation's draft. It has NOT been sent — the person still presses Messages' own send button.")
    }

    static var workoutInserted: String {
        String(localized: "messages.status.workoutInserted", defaultValue: "Workout plan inserted.",
               comment: "Confirms the workout card is now in the conversation's draft. Not sent yet — see messages.status.recipeInserted.")
    }

    static var recipeTooLarge: String {
        String(localized: "messages.status.recipeTooLarge", defaultValue: "This recipe is too large for a Messages card. Export a Fernlet recipe file instead.",
               comment: "Shown when the recipe will not fit in the envelope a Messages card can carry. 'Export a Fernlet recipe file' names the app's own export, the working alternative.")
    }

    static var workoutTooLarge: String {
        String(localized: "messages.status.workoutTooLarge", defaultValue: "This plan is too large for Messages. Use Export workout plan in Shortcuts or Files.",
               comment: "Shown when the workout plan will not fit in a Messages card. 'Export workout plan' is the name of a Shortcuts action and of the Files export — translate it the same way it is translated there.")
    }

    static var insertFailed: String {
        String(localized: "messages.status.insertFailed", defaultValue: "Fernlet couldn't insert this item.",
               comment: "Shown when Messages itself refused the prepared card. Nothing was added to the conversation.")
    }

    static func messageSummary(title: String) -> String {
        String(localized: "messages.card.summaryText", defaultValue: "Fernlet: \(title)",
               comment: "The card's accessibility/notification summary — what Messages reads aloud and shows in a notification preview. %@ is the item's own title.")
    }

    // MARK: - Message card captions

    static var cardNotesIncluded: String {
        String(localized: "messages.card.notesIncluded", defaultValue: "Notes included",
               comment: "Trailing caption on the sent recipe card, telling the recipient a written note travels with it. Keep it short — Messages truncates this corner hard.")
    }

    static var cardRecipe: String {
        String(localized: "messages.card.recipe", defaultValue: "Fernlet recipe",
               comment: "Trailing caption on a sent recipe card carrying no note. Keep it short — Messages truncates this corner hard.")
    }

    static var cardPlan: String {
        String(localized: "messages.card.plan", defaultValue: "Fernlet plan",
               comment: "Trailing caption on a sent workout card when the sender set no display name of their own. Keep it short — Messages truncates this corner hard.")
    }

    static var recipeWordmark: String {
        String(localized: "messages.card.wordmark.recipe", defaultValue: "FERNLET RECIPE",
               comment: "Wordmark DRAWN INTO the card artwork the recipient sees in the conversation. Rendered at 28pt into a 1200×630 image, so a much longer translation will not fit; upper case matches the mark. 'Fernlet' is the product name and must not be translated.")
    }

    static var workoutWordmark: String {
        String(localized: "messages.card.wordmark.workout", defaultValue: "FERNLET WORKOUT",
               comment: "Workout counterpart of messages.card.wordmark.recipe — same 28pt width limit and the same untranslated product name.")
    }

    // MARK: - Received items

    static var receivedRecipe: String {
        String(localized: "messages.received.recipe", defaultValue: "Fernlet recipe",
               comment: "Status line under the title of a received recipe that carries no note.")
    }

    static var receivedRecipeWithNote: String {
        String(localized: "messages.received.recipeWithNote", defaultValue: "Fernlet recipe · note included",
               comment: "Status line under the title of a received recipe that carries the sender's note.")
    }

    static var receivedWorkoutPlan: String {
        String(localized: "messages.received.workoutPlan", defaultValue: "Fernlet workout plan",
               comment: "Status line under the title of a received workout plan whose sender set no display name.")
    }

    static func receivedWorkoutPlan(from sender: String) -> String {
        String(localized: "messages.received.workoutPlanFrom", defaultValue: "Fernlet workout plan · \(sender)",
               comment: "Status line under the title of a received workout plan. %@ is the sender's chosen display name, which they typed and which is shown verbatim.")
    }

    static func scheduled(dayKey: String) -> String {
        String(localized: "messages.received.scheduled", defaultValue: "Scheduled \(dayKey)",
               comment: "Says which day a received workout plan is proposed to start on. %@ is a calendar day key (ISO yyyy-MM-dd), not a sentence.")
    }

    static var chooseDateInFernlet: String {
        String(localized: "messages.received.chooseDate", defaultValue: "Choose a date in Fernlet",
               comment: "Shown instead of a start day when the sender proposed none, so the recipient picks one in the app.")
    }

    static var invalidTitle: String {
        String(localized: "messages.invalid.title", defaultValue: "This Fernlet item can't be opened",
               comment: "Heading shown for a received card whose payload failed to decode — a corrupted, truncated, or foreign message. Deliberately not alarming: it is almost always a version mismatch.")
    }

    static var invalidStatus: String {
        String(localized: "messages.invalid.status", defaultValue: "The message data is unsupported or invalid.",
               comment: "Status line under messages.invalid.title, naming the two causes: a format this build does not understand, or damaged bytes.")
    }

    static var invalidPreview: String {
        String(localized: "messages.invalid.preview", defaultValue: "No item was saved or imported.",
               comment: "Reassurance under messages.invalid.status. The extension never writes anything on the failure path, and this says so.")
    }

    // MARK: - Handing off to the app

    static var prepareItemFailed: String {
        String(localized: "messages.error.prepareItem", defaultValue: "Fernlet couldn't prepare this item for review.",
               comment: "Shown when the review button is pressed but neither a recipe nor a workout is held — the kind is unknown, hence the generic 'item'.")
    }

    static var prepareRecipeFailed: String {
        String(localized: "messages.error.prepareRecipe", defaultValue: "Fernlet couldn't prepare this recipe for review.",
               comment: "Shown when the received recipe could not be written to the hand-off inbox the app reads. Nothing was saved.")
    }

    static var openRecipeFailed: String {
        String(localized: "messages.error.openRecipe", defaultValue: "Fernlet couldn't open this recipe for review.",
               comment: "Shown when the recipe reached the hand-off inbox but the Fernlet app would not open. Distinct from messages.error.prepareRecipe: here the item IS waiting, and opening the app by hand will find it.")
    }

    static var prepareWorkoutFailed: String {
        String(localized: "messages.error.prepareWorkout", defaultValue: "Fernlet couldn't prepare this workout plan for review.",
               comment: "Workout counterpart of messages.error.prepareRecipe. Nothing was saved.")
    }

    static var openWorkoutFailed: String {
        String(localized: "messages.error.openWorkout", defaultValue: "Fernlet couldn't open this workout plan for review.",
               comment: "Workout counterpart of messages.error.openRecipe — the plan IS waiting in the hand-off inbox.")
    }

    static var openingFernlet: String {
        String(localized: "messages.status.openingFernlet", defaultValue: "Opening Fernlet for review…",
               comment: "Shown while the Fernlet app is being brought to the front. Keep the trailing ellipsis if this language uses one.")
    }

    static var openFernletToReview: String {
        String(localized: "messages.status.openFernletToReview", defaultValue: "Open Fernlet to review this item.",
               comment: "Shown when the system declined to open the Fernlet app, so the person must open it themselves. The item is already waiting in the hand-off inbox.")
    }
}

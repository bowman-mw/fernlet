import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletSocial
import FernletUI

/// The receiving side of a proximity recipe share: review what arrived, then import or decline.
///
/// Presented by ContentView when `ProximityRecipeShareManager` holds a
/// `PendingProximityRecipeShare`. Shows the recipe's kind (local Fernlet recipe vs. saved web
/// recipe), servings/ingredient counts, macros, notes, and the ingredient list and steps (grouped
/// under each part's heading for a multipart recipe, as the import will rebuild it), plus a duplicate
/// warning when a same-named (or same-source) recipe already exists — import then becomes
/// "Import anyway". The source-URL duplicate check uses `RecipeSourceURLMatcher`, the SAME
/// normalized match the import path decides with, so the warning fires for exactly the shares the
/// store will treat as already saved (and importing such a share KEEPS the user's existing copy —
/// see `FernletStore.ProximityRecipeImportOutcome.alreadySaved`). Import goes through
/// `FernletStore.importProximityRecipeShare` (which sanitizes and records provenance by sender
/// fingerprint); both outcomes consume the pending share via `dismissRecipeShare`, and an import
/// failure keeps the sheet up with an inline notice.
///
/// **Import confirms itself** (report B22, 2026-10-20). A landed import swaps the Import bar for the
/// "added" line and plays `done`, holds for a beat, then consumes the share — which is what closes
/// the sheet, since ContentView presents it off the pending queue — and VoiceOver hears the line once
/// the close has settled (``ImportReviewLanding``). A failure plays `failed` and is spoken beside the
/// inline notice. Decline plays nothing.
struct ProximityRecipeShareReviewSheet: View {
    var share: PendingProximityRecipeShare
    var store: FernletStore
    var manager: ProximityRecipeShareManager

    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    /// The "added" line, set when the import landed; the sheet holds it for a beat, then closes.
    @State private var landedLine: String?

    /// World build (`b3-recipe-incoming`, approved 2026-10-24): the sheet frame with Decline where
    /// Cancel goes and the shared recipe's name inside, the summary card with its tags, the details in
    /// framed cards, and Import at the bottom right.
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCard

                        // Hidden once the import landed: the recipe it just added would otherwise
                        // read as a duplicate of itself for the beat the "added" line holds.
                        if landedLine == nil, let duplicateWarning {
                            FernletNotice(text: Text(verbatim: duplicateWarning), tone: .warn) { EmptyView() }
                        }

                        sourceHostField
                        notesField
                        ingredientsField
                        stepsField

                        if let notice {
                            FernletNotice(text: Text(verbatim: notice), tone: .warn) { EmptyView() }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }

                importBar
            }
            .background(WorldPalette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        // A landed import whose sheet goes away early — swiped down, or covered by another root
        // sheet, which would re-queue it — is consumed here, so an imported share never comes back.
        .onDisappear { if landedLine != nil { manager.dismissRecipeShare(share) } }
    }

    /// The sheet's header: Decline in Cancel's place, the recipe's name and who shared it.
    private var header: some View {
        SheetHeader(
            // PEER-SUPPLIED data arriving over the mesh. `Text(verbatim:)` is load-bearing, not
            // stylistic: it guarantees the string is never interpreted as a format key or a catalog
            // lookup, which a peer-controlled value reaching either would make a format-string
            // hazard. Do not "simplify" this to `Text(recipe.title)`.
            title: Text(verbatim: share.payload.recipe.title),
            subtitle: Text("Shared by \(share.senderDisplayName)")
        ) {
            Button("Decline") {
                manager.dismissRecipeShare(share)
                dismiss()
            }
            .font(FernletFramedFont.sheetControl)
            .foregroundStyle(WorldPalette.dim)
            .frame(minHeight: 44)
            .disabled(landedLine != nil)
            .accessibilityIdentifier("recipeShare.review.decline")
        }
    }

    /// The Import button at the bottom right, or — once the import landed — the "added" line in its
    /// place.
    @ViewBuilder
    private var importBar: some View {
        if let landedLine {
            ImportLandedLine(text: landedLine)
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorldPalette.paper)
        } else {
            FernletSheetFooter {
                Button { importShare() } label: {
                    if duplicateWarning == nil { Text("Import") } else { Text("Import anyway") }
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("recipeShare.review.import")
            }
        }
    }

    /// Kind, servings, ingredient count and macros — the at-a-glance card above the details.
    private var summaryCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: recipeKindSprite, scale: 2)
                    Text(recipeKindLabel)
                        .font(FernletFramedFont.rowTitle.weight(.bold))
                        .foregroundStyle(WorldPalette.bark)
                }
                FlowLayout(spacing: 8) {
                    FernletTag(text: Text("Servings \(share.payload.recipe.servings)"))
                    FernletTag(text: Text("Ingredients \(share.payload.recipe.ingredientCount)"))
                }
                if let sharedMacros {
                    RecipeMacroTags(macros: sharedMacros)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The sender's notes, when the payload carries any.
    @ViewBuilder
    private var notesField: some View {
        if let notesText, !notesText.isEmpty {
            RecipeReviewCard(title: "Notes") {
                // Peer-supplied: drawn verbatim, never as a catalog key.
                Text(verbatim: notesText)
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
            }
        }
    }

    /// The source page's HOST for a saved (web) recipe, so the user can judge where the share came
    /// from before importing it. Plain text, deliberately NOT tappable: this is a stranger's URL and
    /// the recipe is not imported yet — naming the host informs the decision, opening it doesn't.
    @ViewBuilder
    private var sourceHostField: some View {
        if let sourceHost {
            RecipeReviewCard(title: "Source") {
                Text(verbatim: sourceHost)
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
            }
        }
    }

    /// The cooking steps exactly as shared (F5) — the sheet previously imported them unseen. A
    /// multipart share shows each part's steps under its heading, numbered from 1 within the part.
    @ViewBuilder
    private var stepsField: some View {
        if !sharedSteps.isEmpty {
            RecipeReviewCard(title: "Steps") {
                VStack(alignment: .leading, spacing: 8) {
                    if let sharedParts {
                        ForEach(Array(sharedParts.enumerated()), id: \.offset) { index, part in
                            if !part.steps.isEmpty {
                                RecipePartHeader(name: part.name, position: index + 1, count: sharedParts.count)
                                stepRows(part.steps)
                            }
                        }
                    } else {
                        stepRows(sharedSteps)
                    }
                }
            }
        }
    }

    /// The ingredient list exactly as shared; a multipart share lists each part's under its heading.
    private var ingredientsField: some View {
        RecipeReviewCard(title: "Ingredients") {
            VStack(alignment: .leading, spacing: 6) {
                if let sharedParts {
                    ForEach(Array(sharedParts.enumerated()), id: \.offset) { index, part in
                        if !part.ingredients.isEmpty {
                            RecipePartHeader(name: part.name, position: index + 1, count: sharedParts.count)
                            ingredientRows(part.ingredients.map(Self.ingredientLine))
                        }
                    }
                } else {
                    ingredientRows(ingredientLines)
                }
            }
        }
    }

    private func stepRows(_ steps: [RecipeStep]) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            Text("\(index + 1). \(step.text)")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
        }
    }

    private func ingredientRows(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text("- \(line)")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
        }
    }

    /// A multipart local share's parts (steps already stripped of their flattening labels), or nil
    /// for a one-part share or a saved web recipe.
    private var sharedParts: [SharedRecipeComponentSlice]? {
        guard case .local = share.payload.recipe.kind else { return nil }
        return share.payload.recipe.local?.componentSlices
    }

    /// One shared ingredient as a readable line: "3 tbsp Olive oil".
    nonisolated private static func ingredientLine(_ ingredient: SharedRecipeIngredient) -> String {
        "\(String(format: "%g", ingredient.quantity)) \(ingredient.unit) \(ingredient.name)"
    }

    /// A key, not a `String`: `Label(String, systemImage:)` draws its title verbatim.
    private var recipeKindLabel: LocalizedStringKey {
        switch share.payload.recipe.kind {
        case .local: "Fernlet recipe"
        case .saved: "Saved web recipe"
        }
    }

    /// The kind's pixel icon: the onigiri for a Fernlet recipe, the page for a saved web recipe.
    private var recipeKindSprite: WorldSprite {
        switch share.payload.recipe.kind {
        case .local: WorldSprites.onigiri
        case .saved: WorldSprites.doc
        }
    }

    private var ingredientLines: [String] {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.ingredients.map(Self.ingredientLine) ?? []
        case .saved:
            share.payload.recipe.saved?.ingredients ?? []
        }
    }

    private var sourceHost: String? {
        guard case .saved = share.payload.recipe.kind,
              let saved = share.payload.recipe.saved,
              let host = URL(string: saved.sourceURLString)?.host() else { return nil }
        return host
    }

    private var sharedSteps: [RecipeStep] {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.steps ?? []
        case .saved:
            share.payload.recipe.saved?.steps ?? []
        }
    }

    private var notesText: String? {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        case .saved:
            share.payload.recipe.saved?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The shared recipe's macros as the World build's coloured tags draw them (`b3-recipe-incoming`),
    /// every figure clamped; nil when the share carries none.
    private var sharedMacros: MacroTotals? {
        let macros: MacroTotals
        switch share.payload.recipe.kind {
        case .local:
            guard let ingredients = share.payload.recipe.local?.ingredients else { return nil }
            macros = MacroTotals(protein: Self.boundedMacroSum(ingredients, \.protein),
                                 carbs: Self.boundedMacroSum(ingredients, \.carbs),
                                 fat: Self.boundedMacroSum(ingredients, \.fat))
        case .saved:
            guard let saved = share.payload.recipe.saved else { return nil }
            macros = MacroTotals(protein: Self.boundedMacro(saved.protein), carbs: Self.boundedMacro(saved.carbs),
                                 fat: Self.boundedMacro(saved.fat))
        }
        guard macros.protein > 0 || macros.carbs > 0 || macros.fat > 0 else { return nil }
        return macros
    }

    /// Sums a peer's per-ingredient macros without trusting them: every term is clamped into
    /// `[0, SharedRecipeLimits.maxMacroGrams]` and the list to `maxIngredients`, so the worst case
    /// (100 * 10_000) cannot overflow the trapping `+` while this sheet is rendering.
    ///
    /// The sheet deliberately does NOT lean on the wire decoder's bounds: a payload can also be
    /// built in-process (tests, the send-side preview), and this view renders before import.
    static func boundedMacroSum(_ ingredients: [SharedRecipeIngredient],
                                _ macro: (SharedRecipeIngredient) -> Int) -> Int {
        ingredients.prefix(SharedRecipeLimits.maxIngredients)
            .reduce(0) { $0 + boundedMacro(macro($1)) }
    }

    /// One displayed macro, clamped the same way ``boundedMacroSum(_:_:)`` clamps its terms.
    static func boundedMacro(_ value: Int) -> Int {
        min(max(value, 0), SharedRecipeLimits.maxMacroGrams)
    }

    private var duplicateWarning: String? {
        let title = share.payload.recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch share.payload.recipe.kind {
        case .local:
            guard store.recipes.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }) else { return nil }
            return String(localized: "recipeShare.review.duplicateName", defaultValue: "You already have a recipe with this name.",
                          comment: "Warning on the shared-recipe import review when one of your recipes has the same name")
        case .saved:
            guard let saved = share.payload.recipe.saved else { return nil }
            // NORMALIZED source match — must agree with the store's duplicate decision, or a URL
            // differing only in host case or a #fragment would dodge this warning while the import
            // still treats it as already saved.
            if store.savedRecipes.contains(where: {
                RecipeSourceURLMatcher.urlsMatch($0.webImport?.sourceURLString ?? "", saved.sourceURLString)
            }) {
                return String(localized: "recipeShare.review.duplicateSource",
                              defaultValue: "You already saved this recipe from the same page — importing keeps your saved copy, photo, and notes.",
                              comment: "Warning on the shared-recipe import review when you already saved a recipe from the same web page")
            }
            if store.savedRecipes.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }) {
                return String(localized: "recipeShare.review.duplicateSavedName",
                              defaultValue: "You already have a saved recipe with this name.",
                              comment: "Warning on the shared-recipe import review when one of your saved web recipes has the same name")
            }
            return nil
        }
    }

    /// Imports the share and hands the outcome to ``ImportReviewLanding``, which plays it, closes a
    /// landed import after its beat (consuming the share is the close) and speaks the line.
    private func importShare() {
        guard landedLine == nil else { return }
        let outcome = Self.outcome {
            try store.importProximityRecipeShare(share.payload, fromFingerprint: share.senderFingerprint)
        }
        switch outcome {
        case .added(let line):
            notice = nil
            landedLine = line
        case .caveat(let line), .failed(let line):
            notice = line
        }
        Task { @MainActor in
            await ImportReviewLanding().answer(outcome) {
                manager.dismissRecipeShare(share)
                dismiss()
            }
        }
    }

    /// What one Import came to: `run` is the store's import, so the outcome — and every cue it
    /// plays — is decided from what the import actually did, after it returned.
    static func outcome(
        of run: () throws -> FernletStore.ProximityRecipeImportOutcome
    ) -> ImportReviewOutcome {
        do {
            switch try run() {
            case .imported(let name):
                return .added(String(
                    localized: "proximityRecipeImport.added",
                    defaultValue: "\u{201C}\(name)\u{201D} added to your recipe book.",
                    comment: "Shown on the nearby recipe review sheet for a moment after Import, before it closes, and spoken once it has. The name is the recipe's, as the friend shared it."))
            case .alreadySaved(let name):
                return .added(String(
                    localized: "proximityRecipeImport.alreadySaved",
                    defaultValue: "\u{201C}\(name)\u{201D} was already in your recipe book. Your saved copy was kept.",
                    comment: "Shown on the nearby recipe review sheet after Import when the same web recipe was already saved, so the existing copy (its photo and notes) was kept; then the sheet closes and the line is spoken."))
            }
        } catch let error as RecipeImportError {
            return .failed(error.message)
        } catch {
            return .failed(RecipeImportError.invalidPayload.message)
        }
    }
}

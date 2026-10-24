//
//  RecipePartsEditor.swift
//  Fernlet
//
//  Multipart recipes (owner decision 2026-09-24): the recipe editor's parts UI. Once a recipe is split,
//  `RecipeSheet` swaps its one ingredient list and one step list for `RecipePartsEditor`, one card per
//  part ("Lemon dressing", then "Salad"). Each card has its own name, ingredient rows and steps, and
//  every rule behind them lives in `RecipePartsDraft`. The row and step editors here are the same ones
//  the one-part editor uses (`RecipeIngredientRows`, `RecipeStepEditorCard`), so a part is never a
//  second, divergent way to edit a recipe.
//

import SwiftUI
import FernletDomainModel

#if canImport(UIKit)
import FernletUI
#endif

/// The ingredient rows of one list: the row being edited (or any blank row) open in the full editor,
/// the rest collapsed to a one-line summary.
///
/// Shared by the one-part editor's ingredient list and every part's. The caller owns what "remove"
/// means (a part's last row resets to blank rather than vanishing).
struct RecipeIngredientRows: View {
    @Binding var ingredients: [ManualRecipeIngredientInput]
    @Binding var expandedId: UUID?
    let store: FernletStore
    let onRemove: (UUID) -> Void

    var body: some View {
        ForEach($ingredients) { $ingredient in
            if expandedId == ingredient.id || ingredient.trimmedName.isEmpty {
                RecipeIngredientEditor(
                    ingredient: $ingredient,
                    catalog: store.foodCatalog,
                    onSaveCustomIngredient: { store.saveCustomIngredient($0) },
                    onCollapse: ingredient.trimmedName.isEmpty ? nil : { expandedId = nil },
                    onRemove: { onRemove(ingredient.id) },
                    rememberedPortions: { store.rememberedPortionGrams(for: $0) }
                )
                .padding(14)
                .modifier(RecipeEditorCardFrame())
            } else {
                CollapsedIngredientRow(
                    ingredient: ingredient,
                    catalog: store.foodCatalog,
                    showCalories: store.settings.showCalories,
                    onExpand: { expandedId = ingredient.id },
                    onRemove: { onRemove(ingredient.id) }
                )
            }
        }
    }
}

/// The label every recipe-editor action button wears ("Add ingredient", "Scan barcode", "Add step",
/// "Add another part"): a pixel icon and the word, full width. The button itself takes
/// `ActionPillButtonStyle(.secondary)`, the framed secondary of `b3-recipe-new`.
struct RecipeEditorActionLabel: View {
    let title: LocalizedStringKey
    /// The pixel icon; nil draws the framed plus.
    var sprite: WorldSprite?

    var body: some View {
        HStack(spacing: 7) {
            if let sprite {
                WorldSpriteView(sprite: sprite, scale: 2)
            } else {
                FernletIcon(.plus, scale: 2)
            }
            Text(title)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The framed card an open ingredient editor, a step and a part sit in (`b3-recipe-new`: "each
/// ingredient is a framed card"): paper in a 2-pt ink frame with the look's solid shadow, or today's
/// cream card without the look.
struct RecipeEditorCardFrame: ViewModifier {
    var radius: CGFloat = FernletFramedLook.cardRadius
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(look?.paper ?? Color.cream, in: shape)
            .overlay(shape.strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: look == nil ? 1 : 2))
            .background { shape.fill(look?.shadow ?? Color.clear).offset(y: 3) }
    }
}

/// A 34-pt pixel-glyph control on a step or part card (move earlier, later, remove), dimmed when it
/// can't act, named by `label` for VoiceOver and Voice Control.
struct RecipeEditorGlyphButton: View {
    let sprite: WorldSprite
    let enabled: Bool
    let label: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WorldSpriteView(sprite: sprite, scale: 2)
                .opacity(enabled ? 1 : 0.3)
                .frame(minWidth: 34, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// One step's editor card: its position, move and remove controls, the text editor, and the optional
/// per-step timer. Shared by the one-part editor's step list and every part's.
///
/// Positions are within the card's own list, so a part's steps count from 1.
struct RecipeStepEditorCard: View {
    @Binding var step: RecipeStep
    /// 0-based position within its list.
    let index: Int
    let count: Int
    let accessibilityIdentifier: String
    /// Moves the step one place: −1 earlier, +1 later.
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Step \(index + 1)")
                    .font(FernletFramedFont.rowDetailBold)
                    .foregroundStyle(WorldPalette.dim)
                Spacer()
                RecipeEditorGlyphButton(sprite: WorldSprites.chevU, enabled: index > 0,
                                        label: Text("Move step \(index + 1) up")) { onMove(-1) }
                RecipeEditorGlyphButton(sprite: WorldSprites.chevD, enabled: index < count - 1,
                                        label: Text("Move step \(index + 1) down")) { onMove(1) }
                RecipeEditorGlyphButton(sprite: WorldSprites.xx, enabled: true,
                                        label: Text("Remove step \(index + 1)")) { onRemove() }
            }
            SheetTextEditor(text: $step.text, placeholder: "what to do in this step", minHeight: 60)
            StepTimerControl(durationSeconds: $step.durationSeconds)
        }
        .padding(14)
        .modifier(RecipeEditorCardFrame())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Everything a part's card can ask the multipart draft to do, already bound to that part.
///
/// The card never edits the draft's structure itself: every structural change goes through
/// ``RecipePartsDraft``, where the caps and collapse rules live.
struct RecipePartEditorActions {
    let move: (Int) -> Void
    let remove: () -> Void
    let addIngredient: () -> Void
    let removeIngredient: (UUID) -> Void
    let scanBarcode: () -> Void
    let addStep: () -> Void
    let removeStep: (UUID) -> Void
    let moveStep: (UUID, Int) -> Void
}

/// One part's card in the multipart editor: its heading (position, name, move and remove controls),
/// its ingredient rows and their actions, and its steps.
struct RecipePartEditorCard: View {
    @Binding var part: RecipeComponentInput
    /// 0-based position in making order.
    let index: Int
    let count: Int
    let store: FernletStore
    @Binding var expandedId: UUID?
    let canAddIngredient: Bool
    let canAddStep: Bool
    let actions: RecipePartEditorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subheading("Ingredients")
            RecipeIngredientRows(ingredients: $part.ingredients, expandedId: $expandedId, store: store,
                                 onRemove: actions.removeIngredient)
            AdaptiveStack(spacing: 8) {
                Button(action: actions.addIngredient) {
                    RecipeEditorActionLabel(title: "Add ingredient")
                }
                .disabled(!canAddIngredient)
                #if canImport(UIKit)
                Button(action: actions.scanBarcode) {
                    RecipeEditorActionLabel(title: "Scan barcode", sprite: WorldSprites.barcode)
                }
                .disabled(!canAddIngredient)
                #endif
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            subheading("Steps (optional)")
            steps
        }
        .padding(14)
        .background(WorldPalette.sage.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WorldPalette.moss, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipeEditor.part.\(index)")
    }

    /// "PART 1 OF 2", the name field, and the move/remove controls.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(Text("Part \(index + 1) of \(count)"))
                Spacer()
                RecipeEditorGlyphButton(sprite: WorldSprites.chevU, enabled: index > 0,
                                        label: Text("Make part \(index + 1) earlier")) { actions.move(-1) }
                RecipeEditorGlyphButton(sprite: WorldSprites.chevD, enabled: index < count - 1,
                                        label: Text("Make part \(index + 1) later")) { actions.move(1) }
                RecipeEditorGlyphButton(sprite: WorldSprites.trash, enabled: true,
                                        label: Text("Remove part \(index + 1)"), action: actions.remove)
            }
            TextField("Name this part, like Dressing", text: nameBinding, prompt: .fieldPrompt("Name this part, like Dressing"))
                .submitLabel(.done)
                .sheetTextInput()
                .accessibilityLabel(Text("Name of part \(index + 1)"))
                .accessibilityIdentifier("recipeEditor.part.\(index).name")
        }
    }

    /// The part's name, capped where it is typed at ``RecipeComponentLimits/maxNameCharacters``.
    private var nameBinding: Binding<String> {
        Binding(
            get: { part.name },
            set: { part.name = String($0.prefix(RecipeComponentLimits.maxNameCharacters)) }
        )
    }

    /// This part's steps, then its "Add step" button.
    private var steps: some View {
        VStack(spacing: 8) {
            ForEach($part.steps) { $step in
                let position = part.steps.firstIndex(where: { $0.id == step.id }) ?? 0
                RecipeStepEditorCard(
                    step: $step, index: position, count: part.steps.count,
                    accessibilityIdentifier: "recipeEditor.part.\(index).step.\(position)",
                    onMove: { actions.moveStep(step.id, $0) },
                    onRemove: { actions.removeStep(step.id) }
                )
            }
            Button(action: actions.addStep) {
                RecipeEditorActionLabel(title: "Add step")
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .disabled(!canAddStep)
            .accessibilityIdentifier("recipeEditor.part.\(index).addStep")
        }
    }

    private func subheading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(FernletFramedFont.rowDetailBold)
            .foregroundStyle(WorldPalette.dim)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The multipart editor: one ``RecipePartEditorCard`` per part in making order, then "Add another part".
///
/// Binds the whole ``RecipePartsDraft``, so every card's actions run the draft's rules. Removing a part
/// goes through `onRemovePart`, because only the host sheet can ask before throwing away typed rows,
/// and only it can take the rows back when one part is left.
struct RecipePartsEditor: View {
    @Binding var draft: RecipePartsDraft
    let store: FernletStore
    @Binding var expandedId: UUID?
    /// The Scan button in a part was tapped; the host opens the scanner aimed at that part.
    let onScanBarcode: (UUID) -> Void
    /// A part's remove control was tapped; the host confirms (when it holds typed rows) and removes.
    let onRemovePart: (UUID) -> Void

    var body: some View {
        VStack(spacing: 14) {
            ForEach($draft.parts) { $part in
                let position = draft.parts.firstIndex(where: { $0.id == part.id }) ?? 0
                RecipePartEditorCard(
                    part: $part, index: position, count: draft.parts.count, store: store,
                    expandedId: $expandedId, canAddIngredient: draft.canAddIngredient,
                    canAddStep: draft.canAddStep, actions: actions(for: part.id)
                )
            }
            Button {
                if draft.addPart() != nil { expandedId = nil }
            } label: {
                RecipeEditorActionLabel(title: "Add another part")
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .disabled(!draft.canAddPart)
            .accessibilityIdentifier("recipeEditor.addPart")
        }
    }

    /// The draft operations for one part, as closures its card can call.
    private func actions(for partID: UUID) -> RecipePartEditorActions {
        RecipePartEditorActions(
            move: { draft.movePart(partID, by: $0) },
            remove: { onRemovePart(partID) },
            addIngredient: {
                if let rowID = draft.addIngredient(to: partID) { expandedId = rowID }
            },
            removeIngredient: { rowID in
                draft.removeIngredient(rowID, from: partID)
                if expandedId == rowID { expandedId = nil }
            },
            scanBarcode: { onScanBarcode(partID) },
            addStep: { draft.addStep(to: partID) },
            removeStep: { draft.removeStep($0, from: partID) },
            moveStep: { draft.moveStep($0, in: partID, by: $1) }
        )
    }
}

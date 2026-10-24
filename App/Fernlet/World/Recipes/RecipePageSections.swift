import FernletDomainModel
import FernletUI
import SwiftUI
import UIKit

// The recipe page's sections in the one design language: `b2-recipe-detail` (draft 3) on top and
// `b3-recipe-notes` (draft 2) at the bottom, one page (approved 2026-10-24). ``RecipeDetailView`` owns
// the data and the actions; these draw them.

/// The page's first card: the photo slot beside the name and its yield (`b2-recipe-detail`, inspired by
/// the owner's "look at stardew valley" note). At accessibility sizes the photo sits above the name.
struct RecipePageHeaderCard<PhotoSlot: View>: View {
    let name: String
    let yieldLine: Text
    @ViewBuilder let photoSlot: () -> PhotoSlot
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        FernletCard {
            layout {
                photoSlot()
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: name)
                        .font(RecipeType.pageTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    yieldLine
                        .font(FernletFramedFont.body.weight(.semibold))
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The 110-pt photo slot: a dashed "Add photo" square with the pixel camera, or the person's own photo
/// with a small framed ✕ to delete it. Either opens the camera or the library (``PhotoCaptureControl``).
struct RecipePhotoSlot: View {
    let photo: UIImage?
    let onCamera: (UIImage) -> Void
    let onLibraryData: (Data) -> Void
    let onLibraryFailed: () -> Void
    let onDelete: () -> Void
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PhotoCaptureControl(onCameraCapture: onCamera, onLibraryPickData: { data, _ in onLibraryData(data) },
                                onLibraryPickFailed: onLibraryFailed, allowsLibraryChoice: true) {
                slotFace
            }
            .accessibilityIdentifier(photo == nil ? "recipeDetail.addPhoto" : "recipeDetail.replacePhoto")
            if photo != nil {
                Button(action: onDelete) {
                    FernletIcon(.close, scale: 2)
                        .frame(width: 28, height: 28)
                        .background(look?.raised ?? Color.cream, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: 8)
                .accessibilityLabel("Delete this recipe photo")
                .accessibilityIdentifier("recipeDetail.deletePhoto")
            }
        }
        .frame(width: 110, height: 110)
    }

    @ViewBuilder private var slotFace: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .accessibilityIgnoresInvertColors()
                .frame(width: 110, height: 110)
                .clipShape(shape)
                .overlay(shape.strokeBorder(look?.ink ?? Color.clear, lineWidth: 2))
        } else {
            VStack(spacing: 6) {
                // At the accessibility sizes the words alone fill the slot; the camera would ride its edge.
                if !dynamicTypeSize.isAccessibilitySize {
                    WorldSpriteView(sprite: WorldSprites.camera, scale: 3)
                }
                Text("Add photo")
                    .font(FernletFramedFont.rowDetail.weight(.bold))
                    .foregroundStyle(look?.link ?? Color.moss)
                    .multilineTextAlignment(.center)
                    // The slot stays 110 pt; at the largest sizes the words shrink rather than cut off.
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 6)
            }
            .frame(width: 110, height: 110)
            .overlay(shape.strokeBorder(look?.ink ?? Color.moss, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            .contentShape(shape)
        }
    }
}

/// "Each serving gives" (`b2-recipe-detail`): one framed tile per macro with its pixel art, "+16g" and
/// its name, then the whole recipe's line and any web-estimate caveat under them.
struct RecipeServingCard: View {
    let perServing: MacroTotals
    var showsCalories = false
    let totalsLine: Text
    var estimateNote: WebImportEstimateNote?
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : (showsCalories ? 4 : 3)
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Each serving gives")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    tile(WorldSprites.drumstick, value: Text("+\(perServing.protein)g"), name: Text("Protein"))
                    tile(WorldSprites.wheat, value: Text("+\(perServing.carbs)g"), name: Text("Carbs"))
                    tile(WorldSprites.fatDrop, value: Text("+\(perServing.fat)g"), name: Text("Fat"))
                    if showsCalories {
                        tile(WorldSprites.stampMed, value: Text("\(perServing.calories)"), name: Text("Calories"))
                    }
                }
                totalsLine
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
                if let estimateNote { estimateNote }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ sprite: WorldSprite, value: Text, name: Text) -> some View {
        VStack(spacing: 2) {
            WorldSpriteView(sprite: sprite, scale: 3)
            value
                .font(FernletFramedFont.button.weight(.bold))
                .foregroundStyle(look?.text ?? Color.bark)
            name
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(look?.dim ?? Color.slate)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        // The frame rule (`ref-frames-recipe`): inside the card the tile keeps its tint, not a frame.
        .fernletFrameRulePiece(.tile, fill: look?.raised ?? Color.cream, cornerRadius: 8)
        .accessibilityElement(children: .combine)
    }
}

/// The page's three secondaries under Start cooking (`b2-recipe-detail`): Log it (the meal-type menu),
/// Share and Edit, each a framed button with its pixel icon.
///
/// Three equal thirds while the widest word fits a third; then the same thirds without the icons (a
/// longer language, "Registrarlo"); then one above the other, as at the accessibility sizes. Never a
/// word cut off inside a button.
struct RecipePageActions: View {
    let onLog: (MealType) -> Void
    let onShare: () -> Void
    let onEdit: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            EqualColumnGrid(columns: 3, horizontalSpacing: 8) { buttons(icons: true) }
            EqualColumnGrid(columns: 3, horizontalSpacing: 8) { buttons(icons: false) }
            VStack(spacing: 8) { buttons(icons: true) }
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
    }

    @ViewBuilder private func buttons(icons: Bool) -> some View {
        RecipeLogMenu(title: Text("Log it"), spokenLabel: Text("Log this recipe"), size: .regular,
                      showsPlus: icons, fillsWidth: true, identifier: "recipeDetail.log", onLog: onLog)
        Button(action: onShare) { label(Text("Share"), sprite: icons ? WorldSprites.share : nil) }
            .accessibilityIdentifier("recipeDetail.share")
        Button(action: onEdit) { label(Text("Edit"), sprite: icons ? WorldSprites.pen : nil) }
            .accessibilityIdentifier("recipeDetail.edit")
    }

    private func label(_ title: Text, sprite: WorldSprite?) -> some View {
        HStack(spacing: 7) {
            if let sprite {
                WorldSpriteView(sprite: sprite, scale: 2)
            }
            title.lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The Steps card (`b3-recipe-notes`): each step's number on a small wooden square beside its words,
/// with a quiet timer tag where the step has a duration (dropped at accessibility sizes).
struct RecipeStepRow: View {
    let number: Int
    let step: RecipeStep
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RecipeStepBadge(number: number)
            Text(step.text)
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.text ?? Color.bark)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Spacer(minLength: 0)
            if let seconds = step.durationSeconds, seconds > 0, !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 5) {
                    WorldSpriteView(sprite: WorldSprites.clock, scale: 2)
                    Text(Duration.seconds(seconds),
                         format: .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                        .font(FernletFramedFont.tag)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                .padding(.top, 4)
            }
        }
        // One element saying the step's number and words; the badge and the timer tag are decoration.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(step.text)")
    }
}

/// The Notes card (`b3-recipe-notes` draft 2, the owner's note: "Notes should be with the rest of the
/// recipe"): the notes as written, with a small Edit that opens them in place. Cancel leaves them as
/// they were; Save hands the typed text back. A recipe with no notes offers "Add notes".
struct RecipeNotesCard: View {
    /// The notes as drawn (``StoredFoodNote/displayedRecipeNotes(_:)``).
    let notes: String
    let onSave: (String) -> Void
    @State private var draft: String?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Notes")
                    Spacer(minLength: 8)
                    if draft == nil { editButton }
                }
                if let draft {
                    editor(draft)
                } else if notes.isEmpty {
                    Text("No notes yet.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                } else {
                    Text(verbatim: notes)
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editButton: some View {
        Button { draft = notes } label: {
            HStack(spacing: 6) {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                if notes.isEmpty { Text("Add notes") } else { Text("Edit") }
            }
        }
        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
        .accessibilityLabel(notes.isEmpty ? Text("Add notes") : Text("Edit notes"))
        .accessibilityIdentifier("recipeDetail.editNotes")
    }

    private func editor(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            SheetTextEditor(text: Binding(get: { draft ?? text }, set: { draft = $0 }),
                            placeholder: "prep notes, substitutions, storage", minHeight: 110)
                .accessibilityIdentifier("recipeDetail.notesEditor")
            HStack(spacing: 10) {
                Button("Cancel") { draft = nil }
                    .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                Button("Save") {
                    onSave(draft ?? text)
                    draft = nil
                }
                .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
                .accessibilityIdentifier("recipeDetail.saveNotes")
            }
        }
    }
}

/// Where a web recipe came from (`b3-recipe-notes`): the pixel globe, the host as a link that opens the
/// page in Fernlet's in-app Safari, and "Re-import from source" beside it.
struct RecipeSourceCard: View {
    let url: URL
    var isReimporting = false
    let onOpen: () -> Void
    /// Nil hides Re-import (a source Safari can't show).
    var onReimport: (() -> Void)?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onOpen) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        WorldSpriteView(sprite: WorldSprites.globe, scale: 2)
                        Text(verbatim: url.host() ?? url.absoluteString)
                            .font(FernletFramedFont.body.weight(.semibold))
                            .underline()
                            .foregroundStyle(look?.link ?? Color.moss)
                            .lineLimit(1)
                        Text("Where this recipe came from")
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recipeDetail.source")
                if let onReimport {
                    Button(action: onReimport) { Text("Re-import from source") }
                        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                        .disabled(isReimporting)
                        .accessibilityIdentifier("recipeDetail.reimport")
                }
            }
        }
    }
}

import FernletDomainModel
import FernletUI
import SwiftUI

/// The pixel pictures on Your spaces' preset cards (`comp-space-add`, approved 2026-10-25): the hotel,
/// the apartment block and the house, copied key for key from the design session's table, and the ink
/// dumbbell for Full gym (the blue button's dumbbell in the design's ink).
nonisolated enum YourSpacesSprites {
    /// The design's palette for the buildings.
    private static let palette: [Character: UInt32] = [
        "k": WorldSprite.ink, "r": 0xB4573E, "w": 0xF2E3C2, "y": 0xF2D58A, "d": 0x7A4B2A, "b": 0x7E9CC4,
        "g": 0x5E844D, "s": 0xA9B4BE,
    ]
    static let hotel = WorldSprite(rows: ["kkkkkkkkk", "kgggggggk", "kkkkkkkkk", "kbbbbbbbk", "kbybyybbk", "kbbbbbbbk",
                                          "kbybbybbk", "kbbbddbbk", "kkkkkkkkk"], palette: palette)
    static let flats = WorldSprite(rows: ["..kkkkk..", "..ksssk..", "kkksssskk", "ksksysksk", "ksksssksk", "ksksysksk",
                                          "ksksssksk", "kssksdksk", "kkkkkkkkk"], palette: palette)
    static let house = WorldSprite(rows: ["....k....", "...krk...", "..krrrk..", ".krrrrrk.", "kkkkkkkkk", ".kwwwwwk.",
                                          ".kywwdwk.", ".kwwwdwk.", ".kkkkkkk."], palette: palette)
    static let dumbbell = WorldSprite(rows: WorldSprites.dumbbell.rows, palette: ["w": WorldSprite.ink])

    /// A preset's picture, by its frozen id.
    static func sprite(forTemplate id: String) -> WorldSprite {
        switch id {
        case "hotel-gym": hotel
        case "apartment-gym": flats
        case "home-setup": house
        default: dumbbell
        }
    }
}

/// Your spaces' second and third steps' top (`comp-space-add`, `comp-space-equip`): the plate's Back to
/// "Your spaces" (VoiceOver "Back to your spaces") and the step's title in Fraunces, on the sheet's paper.
/// Your spaces stays a sheet, so its first step keeps Cancel and Done.
struct YourSpacesStepHeader: View {
    let title: LocalizedStringKey
    /// The title as a word count for the Back's compact rule (the kit's 13 letters).
    let titleText: String
    let onBack: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 12) {
            FernletBackButton(verbatim: String(localized: "Your spaces"), compact: FernletBackButton.isCompact(title: titleText),
                              action: onBack)
                .accessibilityIdentifier("workout.location.back")
            Text(title)
                .font(FernletFramedFont.sheetTitle)
                .foregroundStyle(look?.text ?? WorldPalette.bark)
                .fernletWrappingText()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// One preset on "Start from a preset" (`comp-space-add`): a framed card (2-pt ink, 12-pt corners, a 3-pt
/// shadow, raised paper) with the preset's pixel picture, its name in 17-pt Fraunces and its line.
struct YourSpacesPresetCard: View {
    let template: LocationTemplate
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                WorldSpriteView(sprite: YourSpacesSprites.sprite(forTemplate: template.id), scale: 3)
                    .frame(width: 40, height: 40)
                    .padding(.bottom, 4)
                Text(verbatim: template.displayName)
                    .font(.custom(FernletFontName.frauncesSemiBold, size: 17, relativeTo: .headline))
                    .foregroundStyle(look?.text ?? WorldPalette.bark)
                    .fernletWrappingText()
                Text(verbatim: template.displaySubtitle)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? WorldPalette.dim)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
            .background(look?.raised ?? WorldPalette.paperLight, in: shape)
            .overlay(shape.strokeBorder(look?.ink ?? WorldPalette.ink, lineWidth: 2))
            .background { shape.fill(look?.shadow ?? WorldPalette.ink.opacity(0.22)).offset(y: 3) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workout.location.preset.\(template.id)")
    }
}

/// The equipment step's name chip (`comp-space-equip`): the chip fill in a 2-pt ink frame, a pixel pin,
/// the space's name as a field (tap it to rename), and a pixel pencil after a divider.
struct YourSpacesNameChip: View {
    @Binding var name: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        HStack(spacing: 8) {
            WorldSpriteView(sprite: WorldSprites.pin, scale: 2)
            // Editable, not a label: the model has always had `name`, and the chip is where it's renamed.
            TextField("Location", text: $name, prompt: .fieldPrompt("Location"))
                .font(FernletFramedFont.fieldBold)
                .foregroundStyle(look?.text ?? WorldPalette.bark)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 200, alignment: .leading)
                .accessibilityIdentifier("workout.location.name")
            (look?.ink ?? WorldPalette.ink).frame(width: 2, height: 22)
            WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 8))
        .frame(minHeight: 44)
        .background(WorldPalette.sage, in: shape)
        .overlay(shape.strokeBorder(look?.ink ?? WorldPalette.ink, lineWidth: 2))
    }
}

/// One piece of equipment (`comp-space-equip`): a framed tile with its name and a 22-pt check square;
/// picked, the chip fill with a 2-pt moss ring inside and a white pixel check on moss ink. At least 44 pt.
struct YourSpacesEquipmentTile: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(verbatim: name)
                    .font(.custom(FernletFontName.dmSansBold, size: 14.5, relativeTo: .subheadline))
                    .foregroundStyle(look?.text ?? WorldPalette.bark)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                checkSquare
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? WorldPalette.sage : (look?.raised ?? WorldPalette.paperLight), in: shape)
            .overlay { if isSelected { shape.inset(by: 2).strokeBorder(WorldPalette.moss, lineWidth: 2) } }
            .overlay(shape.strokeBorder(look?.ink ?? WorldPalette.ink, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The 22-pt check square: empty paper, or moss ink with a white pixel check.
    private var checkSquare: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack {
            shape.fill(isSelected ? WorldPalette.mossInk : (look?.paper ?? WorldPalette.paper))
            if isSelected {
                WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: WorldPalette.onAccent)
            }
        }
        .frame(width: 22, height: 22)
        .overlay(shape.strokeBorder(look?.ink ?? WorldPalette.ink, lineWidth: 2))
        .accessibilityHidden(true)
    }
}

/// The equipment step's save bar (`comp-space-equip`): "Save location", a full-width primary button in a
/// bar pinned to the bottom under a 2-pt ink rule.
struct YourSpacesSaveBar: View {
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            Text("Save location").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(look?.paper ?? WorldPalette.paper)
        .overlay(alignment: .top) { (look?.ink ?? WorldPalette.ink).frame(height: 2) }
    }
}

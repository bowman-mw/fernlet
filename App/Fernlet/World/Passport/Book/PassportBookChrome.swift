import FernletUI
import SwiftUI

/// The passport's green cover (World-Passport-Spec §2): `#26492F` in a 3 pt ink border, corners 8 pt at the spine and
/// 16 pt at the outer edge, a darker 11 pt band along the spine, gold stitching down it (5 pt dashes every 11 pt), a
/// light top edge and a solid shadow under it. Decoration.
struct PassportCoverBoard: View {
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, bottomTrailingRadius: 16,
                                           topTrailingRadius: 16)
        ZStack(alignment: .leading) {
            shape.fill(PassportBookPalette.cover)
            PassportBookPalette.coverLow.frame(width: 14)
            Canvas { context, size in
                var stitch = Path()
                stitch.move(to: CGPoint(x: 7, y: 19))
                stitch.addLine(to: CGPoint(x: 7, y: max(size.height - 19, 19)))
                context.stroke(stitch, with: .color(PassportBookPalette.gold.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
            }
            VStack(spacing: 0) {
                PassportBookPalette.coverHigh.frame(height: 6)
                Spacer(minLength: 0)
                PassportBookPalette.coverLow.frame(height: 6)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background(shape.fill(Color(red: 40 / 255, green: 20 / 255, blue: 8 / 255).opacity(0.35)).offset(y: 5))
        .shadow(color: Color(red: 40 / 255, green: 20 / 255, blue: 8 / 255).opacity(0.28), radius: 15, y: 16)
        .accessibilityHidden(true)
    }
}

/// The closed cover's face as the book rises (`ppface`): "PASSPORT" in wide gold capitals, the gold ring with the
/// leaf, "Sprout", and the chip. One VoiceOver element, "Sprout's passport, closed".
struct PassportCoverFace: View {
    var body: some View {
        VStack(spacing: 20) {
            Text(PassportBookCopy.coverWord)
                .font(PassportBookType.coverWord)
                .tracking(6)
            ZStack {
                Circle().strokeBorder(PassportBookPalette.gold, lineWidth: 2).frame(width: 130, height: 130)
                Circle().strokeBorder(PassportBookPalette.gold, lineWidth: 4).frame(width: 118, height: 118)
                WorldSpriteView(sprite: WorldSprites.leaf, scale: 6, tint: PassportBookPalette.gold)
            }
            Text(verbatim: "Sprout")
                .font(PassportBookType.coverName)
            WorldSpriteView(sprite: WorldSprites.stampMed, scale: 3, tint: PassportBookPalette.gold)
        }
        .foregroundStyle(PassportBookPalette.gold)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PassportCoverBoard())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PassportBookCopy.closedBook))
    }
}

/// A page's paper (World-Passport-Spec §2): `#FFF9EA` in a 2 pt ink border (2 pt corners at the spine, 8 pt outside),
/// the faint security print (off with Increase Contrast), the gutter's three-step shade on the spine side, and the
/// stepped page edges on the outer and bottom sides (2 / 3 / 4 / 5 pt, paper2 and edge alternating, then 7 pt ink).
struct PassportPagePaper: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 8,
                                           topTrailingRadius: 8)
        ZStack(alignment: .leading) {
            shape.fill(PassportBookPalette.paper)
            if contrast != .increased { PassportSecurityPrint().clipShape(shape) }
            HStack(spacing: 0) {
                PassportBookPalette.gutter.frame(width: 4)
                PassportBookPalette.gutterMid.frame(width: 4)
                PassportBookPalette.gutterLight.frame(width: 4)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2))
        .background {
            ZStack {
                shape.fill(WorldPalette.ink).offset(x: 7, y: 7)
                shape.fill(PassportBookPalette.edge).offset(x: 5, y: 5)
                shape.fill(PassportBookPalette.paper2).offset(x: 4, y: 4)
                shape.fill(PassportBookPalette.edge).offset(x: 3, y: 3)
                shape.fill(PassportBookPalette.paper2).offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The security print: two wave lines in a 48 × 14 pt tile, moss at 13 % and red at 7 %, tiled over the page.
struct PassportSecurityPrint: View {
    /// The most tiles drawn down or across (a page is far smaller).
    private static let maxTiles = 120

    var body: some View {
        Canvas { context, size in
            let columns = min(Int(size.width / 48) + 1, Self.maxTiles)
            let rows = min(Int(size.height / 14) + 1, Self.maxTiles)
            var moss = Path(), red = Path()
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let origin = CGPoint(x: CGFloat(column) * 48, y: CGFloat(row) * 14)
                    Self.wave(&moss, at: origin, height: 7)
                    Self.wave(&red, at: origin, height: 11)
                }
            }
            context.stroke(moss, with: .color(PassportBookPalette.printMoss), lineWidth: 1)
            context.stroke(red, with: .color(PassportBookPalette.printRed), lineWidth: 1)
        }
    }

    /// One tile's wave: `M0 h Q12 h-6 24 h T48 h`.
    private static func wave(_ path: inout Path, at origin: CGPoint, height: CGFloat) {
        path.move(to: CGPoint(x: origin.x, y: origin.y + height))
        path.addQuadCurve(to: CGPoint(x: origin.x + 24, y: origin.y + height),
                          control: CGPoint(x: origin.x + 12, y: origin.y + height - 6))
        path.addQuadCurve(to: CGPoint(x: origin.x + 48, y: origin.y + height),
                          control: CGPoint(x: origin.x + 36, y: origin.y + height + 6))
    }
}

/// The red ribbon with its forked tail (World-Passport-Spec §2): 18 pt wide in a 2 pt ink frame, `#B3343A`.
struct PassportRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.8))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The framed cream the ✕, the chips and the page bar sit on (`.icci`, `.ppbanner`, `.ppnav`): cream in a 3 pt
/// ink frame, a low inner edge and a solid shadow.
struct PassportCreamPlate: View {
    var radius: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape.fill(PassportBookPalette.cream)
            .overlay(alignment: .bottom) {
                PassportBookPalette.creamLow.frame(height: 3).padding(.horizontal, 3).padding(.bottom, 3)
            }
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background(shape.fill(WorldPalette.ink.opacity(0.4)).offset(y: 3))
    }
}

/// The ✕ top right (World-Passport-Spec §1): a 44 pt cream framed square. VoiceOver "Close the passport"; Voice
/// Control "Close"; Escape presses it.
struct PassportCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WorldSpriteView(sprite: WorldSprites.xx, scale: 2, tint: WorldPalette.iconInk)
                .frame(width: 44, height: 44)
                .background(PassportCreamPlate())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text(PassportBookCopy.close))
        .accessibilityInputLabels([Text(PassportBookCopy.closeShort), Text(PassportBookCopy.close)])
        .accessibilityIdentifier("passport.close")
    }
}

/// A status chip top left (`.ppbanner`): an icon and its words on framed cream ("New stamp · Sea of Japan",
/// "Every stamp found").
struct PassportStatusChip<Icon: View>: View {
    let text: Text
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            text
                .font(PassportBookType.chip)
                .foregroundStyle(PassportBookPalette.onCream)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(EdgeInsets(top: 6, leading: 7, bottom: 8, trailing: 10))
        .frame(minHeight: 44)
        .background(PassportCreamPlate())
    }
}

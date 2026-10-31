import FernletUI
import SwiftUI
import WorldMapStore

/// The boarding pass's type (the mockup's `.apbp`): DM Sans throughout, two steps, as approved (``View/worldPassFont(_:)``): codes 34 (38 at the
/// largest text), labels 11 (14), places 13 (17), facts 15 (19).
nonisolated enum WorldPassType {
    static func code(_ large: Bool) -> Font { .custom(FernletFontName.dmSansBold, size: large ? 38 : 34, relativeTo: .largeTitle) }
    static func label(_ large: Bool) -> Font { .custom(FernletFontName.dmSansBold, size: large ? 14 : 11, relativeTo: .caption2) }
    static func place(_ large: Bool) -> Font { .custom(FernletFontName.dmSansMedium, size: large ? 17 : 13, relativeTo: .footnote) }
    static func fact(_ large: Bool, ticket: Bool) -> Font {
        .custom(FernletFontName.dmSansBold, size: large ? (ticket ? 16 : 19) : 15, relativeTo: .subheadline)
    }
    static func header() -> Font { .custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote) }
}

extension View {
    /// The pass's two-step type (§5, §12): `font` at its approved size, held there; the views pick the larger step
    /// themselves at the accessibility sizes, as the approved largest-text pass draws it.
    func worldPassFont(_ font: Font) -> some View {
        self.font(font).dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// The pass's colours: the passport's paper and text, its green cover for the header band, cream on it.
nonisolated enum WorldPassPalette {
    static let paper = PassportBookPalette.paper
    static let text = PassportBookPalette.text
    static let dim = PassportBookPalette.dim
    static let rule = PassportBookPalette.rule
    static let band = PassportBookPalette.cover
    /// Cream on the green band (#FFF6E2 on #26492F, 9.6:1).
    static let onBand = WorldPalette.rgb(0xFFF6E2)
    /// The dim under the pass and the ticket (`.apdim`).
    static let veil = Color(.sRGB, red: 30 / 255, green: 20 / 255, blue: 10 / 255, opacity: 0.38)
}

/// The paper card every pass is drawn on: a 3-pt ink frame, 12-pt corners, a solid drop shadow.
struct WorldPassFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) { content }
            .background(WorldPassPalette.paper, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { shape.fill(WorldPalette.rgb(0x4A2E1C).opacity(0.35)).offset(y: 4) }
            .foregroundStyle(WorldPassPalette.text)
    }
}

/// The green header band: "BOARDING PASS" and the ✕ (44 pt, cream on green) top right.
struct WorldPassHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(WorldTripCopy.boardingPass)
                .worldPassFont(WorldPassType.header())
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(WorldPassPalette.onBand)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: onClose) {
                WorldSpriteView(sprite: WorldSprites.xx, scale: 2, tint: WorldPassPalette.onBand)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPassPalette.onBand, lineWidth: 2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(verbatim: FernletUICopy.close))
            .accessibilityInputLabels([Text(verbatim: FernletUICopy.close)])
            .accessibilityIdentifier("world.trip.close")
        }
        .padding(.leading, 14)
        .frame(minHeight: 48)
        .background(WorldPassPalette.band)
    }
}

/// One end of the pass: its small label, its big code (or "· · ·" in a dashed box while it waits), and its place.
struct WorldPassStopColumn: View {
    let label: LocalizedStringResource
    /// The code, or nil while it waits.
    let code: String?
    let place: String
    /// The To side reads right to left.
    let trailing: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .worldPassFont(WorldPassType.label(large)).tracking(1.1).textCase(.uppercase)
                .foregroundStyle(WorldPassPalette.dim)
            if let code {
                Text(verbatim: code)
                    .worldPassFont(WorldPassType.code(large)).tracking(1.4)
                    .lineLimit(1).minimumScaleFactor(0.45)
            } else {
                Text(verbatim: "· · ·")
                    .worldPassFont(WorldPassType.code(large)).tracking(3)
                    .foregroundStyle(WorldPassPalette.dim)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPassPalette.rule, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
            }
            Text(verbatim: place)
                .worldPassFont(WorldPassType.place(large))
                .foregroundStyle(WorldPassPalette.dim)
                .multilineTextAlignment(trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// The small jet between From and To (decoration).
struct WorldPassJet: View {
    var body: some View {
        WorldSpriteView(sprite: PassportFlightSprites.jet, scale: 2, tint: WorldPassPalette.text)
            .accessibilityHidden(true)
    }
}

/// The row under the codes: Passenger SPROUT, the date, and Seat "Window" (a joke). Two columns at the largest text
/// on the pass, three on the ticket.
struct WorldPassFacts: View {
    let companion: String
    let date: String
    var isTicket = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading), count: large && !isTicket ? 2 : 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            fact(WorldTripCopy.passenger, Text(verbatim: companion.uppercased()), large)
            fact(WorldTripCopy.date, Text(verbatim: date), large)
            fact(WorldTripCopy.seat, Text(WorldTripCopy.window), large)
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 12, trailing: 14))
    }

    private func fact(_ label: LocalizedStringResource, _ value: Text, _ large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).worldPassFont(WorldPassType.label(large)).tracking(1.1).textCase(.uppercase).foregroundStyle(WorldPassPalette.dim)
            value.worldPassFont(WorldPassType.fact(large, ticket: isTicket)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The barcode (decoration only, hidden from VoiceOver).
struct WorldPassBarcodeView: View {
    var body: some View {
        Canvas { context, _ in
            for bar in WorldPassBarcode.bars() {
                context.fill(Path(CGRect(x: bar.x, y: 0, width: bar.width, height: WorldPassBarcode.height)),
                             with: .color(WorldPassPalette.text))
            }
        }
        .frame(width: WorldPassBarcode.width, height: WorldPassBarcode.height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The dashed stub along the bottom: a top rule in dashes, then what it holds.
struct WorldPassStub<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            .overlay(alignment: .top) {
                WorldPassRule().stroke(WorldPassPalette.rule, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).frame(height: 2)
            }
    }
}

/// A dashed rule across the stub's top: one line through the middle of its frame.
struct WorldPassRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Sprout's boarding pass (§5, screen 6): opened from a found airport's tower, a cream card 16 pt from each side and
/// 112 pt above the bottom (118 at the largest text), over a dim that closes it when tapped. One VoiceOver element
/// for its words ("Sprout's boarding pass. From PDX, Portland, to LHR, London. 2 October 2026."), then its ✕.
struct WorldBoardingPassCard: View {
    let pass: WorldBoardingPass
    let companion: String
    let onClose: () -> Void

    var body: some View {
        WorldPassFrame {
            WorldPassHeader(onClose: onClose)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 6) {
                    WorldPassStopColumn(label: WorldTripCopy.from, code: pass.from?.code,
                                        place: pass.from?.place ?? String(localized: WorldTripCopy.fromFillsIn), trailing: false)
                    WorldPassJet()
                    WorldPassStopColumn(label: WorldTripCopy.to, code: toStop?.code,
                                        place: toStop?.place ?? String(localized: WorldTripCopy.whereverYouLand), trailing: true)
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
                WorldPassFacts(companion: companion, date: WorldTripDates.day(pass.date))
                WorldPassStub {
                    WorldPassBarcodeView()
                    if !pass.landed {
                        Text(verbatim: WorldTripCopy.stub(companion: companion))
                            .worldPassFont(WorldPassType.place(false)).foregroundStyle(WorldPassPalette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("world.trip.pass")
    }

    private var toStop: WorldBoardingPass.Stop? {
        if case .stop(let stop) = pass.to { return stop }
        return nil
    }

    /// The pass in words.
    private var spoken: String {
        let from = pass.from.map { WorldTripCopy.spokenStop(code: $0.code, place: $0.place) } ?? String(localized: WorldTripCopy.fromFillsIn)
        let to = toStop.map { WorldTripCopy.spokenStop(code: $0.code, place: $0.place) }
        return WorldTripCopy.spokenPass(companion: companion, from: from, to: to, date: WorldTripDates.spokenDay(pass.date))
    }
}

/// The pass over Home: the dim and the card at its approved place.
struct WorldBoardingPassOverlay: View {
    let pass: WorldBoardingPass
    let companion: String
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .bottom) {
            WorldPassPalette.veil
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            WorldBoardingPassCard(pass: pass, companion: companion, onClose: onClose)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .padding(.horizontal, 16)
                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 118 : 112)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// The pass's dates, in the app's language: "2 Oct 2026" on the card, "2 October 2026" for VoiceOver.
nonisolated enum WorldTripDates {
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func spokenDay(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year())
    }

    /// The ticket's date with a calendar flight's departure: "31 Oct · 2:05 PM".
    static func day(_ date: Date, departure: Date?) -> String {
        guard let departure else { return day(date) }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) · \(departure.formatted(date: .omitted, time: .shortened))"
    }
}

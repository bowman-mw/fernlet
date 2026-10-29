import FernletUI
import SwiftUI
import WorldMapStore

/// Where the person stands, as the close-up's bottom row reads it (World build round 7, owner-approved
/// 2026-10-26: `ref-comp-home-add`, `ref-comp-home-at`).
nonisolated enum WorldCloseUpPlace: Equatable, Sendable {
    /// Not at a home or the hotel, with a precise reading: "This is home" beside Customize.
    case away(GeoPoint)
    /// At one of the person's homes: "Sprout's house is here · <home>" with Manage.
    case home(name: String)
    /// At the hotel of the stay: "Staying at the <hotel>" with Manage.
    case hotel(name: String)
    /// No precise reading, or a decoy: Customize alone.
    case unknown

    /// Where the person stands now (``at(_:book:decoy:)`` over the map's latest reading and the homes).
    @MainActor
    static func current(store: FernletStore) -> WorldCloseUpPlace {
        at(store.worldLocation.latest, book: store.worldHomes, decoy: store.duressSessionActive)
    }

    /// Where a person reading `fix` stands: at a home or the hotel of `book` by its 120-m reach, else away
    /// when the reading is precise. Unknown with no reading, or in a decoy.
    static func at(_ fix: WorldFix?, book: HomeBook, decoy: Bool) -> WorldCloseUpPlace {
        guard !decoy, let fix, fix.point.isValid else { return .unknown }
        if let base = book.base(near: fix.point) {
            let name = base.label.isEmpty ? WorldHomeCopy.defaultHomeName : base.label
            return base.kind == .home ? .home(name: name) : .hotel(name: name)
        }
        return fix.isPrecise ? .away(fix.point) : .unknown
    }
}

/// The close-up's words for homes (round 7). "Sprout" is the companion's name.
nonisolated enum WorldCloseUpHomeCopy {
    static let thisIsHome = LocalizedStringResource("worldCloseUp.thisIsHome", defaultValue: "This is home",
                                                    comment: "World companion up close: the button that makes where the person stands a home")
    static let manage = LocalizedStringResource("worldCloseUp.manage", defaultValue: "Manage",
                                                comment: "World companion up close, at a home or hotel: opens Settings, Home map, Homes and hotels")

    /// VoiceOver after "This is home, button": "Makes where you are Sprout's home."
    static func thisIsHomeHint(companion: String) -> String {
        String(localized: "worldCloseUp.thisIsHome.hint", defaultValue: "Makes where you are \(companion)'s home.",
               comment: "World companion up close, VoiceOver: after 'This is home, button'; the companion's name, e.g. 'Makes where you are Sprout's home.'")
    }

    /// "Sprout's house is here · Home" (the companion's name, then the home's).
    static func houseHere(companion: String, home: String) -> String {
        String(localized: "worldCloseUp.houseHere", defaultValue: "\(companion)'s house is here · \(home)",
               comment: "World companion up close, at a home: the companion's name, then the home's name, e.g. 'Sprout's house is here · Home'")
    }

    /// "Staying at the Ace" (the hotel's name).
    static func stayingAt(_ hotel: String) -> String {
        String(localized: "worldCloseUp.stayingAt", defaultValue: "Staying at the \(hotel)",
               comment: "World companion up close, at the hotel of a stay: the hotel's name, e.g. 'Staying at the Ace'")
    }
}

/// The close-up's bottom row (`ref-comp-close` with round 7): away from a home, "This is home" (the pixel
/// house) beside Customize; at a home or the hotel, the house or the suitcase and its line with Manage,
/// over Customize; with no precise reading, Customize alone.
struct WorldCloseUpActions: View {
    let place: WorldCloseUpPlace
    /// The companion's name.
    let companion: String
    let onCustomize: () -> Void
    let onThisIsHome: (GeoPoint) -> Void
    let onManage: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch place {
        case .away(let point):
            // Side by side, stacked at the largest text sizes so neither word is cut.
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                thisIsHome(point)
                customize
            }
        case .home(let name):
            VStack(spacing: 10) {
                WorldCloseUpHomeLine(sprite: WorldPlaceSprites.house, scale: 2,
                                     line: WorldCloseUpHomeCopy.houseHere(companion: companion, home: name), onManage: onManage)
                customize
            }
        case .hotel(let name):
            VStack(spacing: 10) {
                WorldCloseUpHomeLine(sprite: WorldPlaceSprites.suitcase, scale: 3, line: WorldCloseUpHomeCopy.stayingAt(name), onManage: onManage)
                customize
            }
        case .unknown:
            customize
        }
    }

    /// "This is home", with the pixel house.
    private func thisIsHome(_ point: GeoPoint) -> some View {
        Button { onThisIsHome(point) } label: {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: WorldPlaceSprites.house, scale: 2).accessibilityHidden(true)
                Text(WorldCloseUpHomeCopy.thisIsHome)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityHint(Text(verbatim: WorldCloseUpHomeCopy.thisIsHomeHint(companion: companion)))
        .accessibilityIdentifier("world.closeUp.thisIsHome")
    }

    /// Customize, as the close-up has always drawn it.
    private var customize: some View {
        Button(action: onCustomize) {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                Text("Customize")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityHint("Change how your companion looks")
        .accessibilityIdentifier("world.closeUp.customize")
    }
}

/// At a home or the hotel (`ref-comp-home-at`): a small house or suitcase, the line, and Manage, which opens
/// Settings › Home map with Homes and hotels. VoiceOver reads the line, then "Manage, button".
struct WorldCloseUpHomeLine: View {
    let sprite: WorldSprite
    let scale: CGFloat
    let line: String
    let onManage: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            WorldSpriteView(sprite: sprite, scale: scale).accessibilityHidden(true)
            Text(verbatim: line)
                .font(.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(WorldPalette.bark)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onManage) { Text(WorldCloseUpHomeCopy.manage) }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityIdentifier("world.closeUp.manage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityElement(children: .contain)
    }
}

/// Settings › Home map in a sheet over the map, from the close-up's Manage (`ref-comp-home-at`): the same
/// page Settings pushes, Homes and hotels among its sections, with Done top right.
struct WorldHomesManageSheet: View {
    var store: FernletStore
    let onDone: () -> Void

    var body: some View {
        HomeMapSettingsView(store: store)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "Home map", onDone: onDone)
            }
            .fernletSheet()
    }
}

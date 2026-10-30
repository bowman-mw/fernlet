import FernletDomainModel
import FernletUI
import SwiftUI

// Page 1's bottom half (World-Passport-Spec §4, mockup `idBody`, `kit-passport.css` `.ppslots`, `.ppslot`,
// `.pprow`, `.pptwo`, `.ppcoins`, `.ppgold`, `.ppathome`, `.ppsw`): what Sprout's wearing, Wardrobe and
// Creation Studio, the shop, This is home and App colors. Every control is a button that says what the page
// should do (``PassportSproutAction``); the page does it.

/// A small caps heading on the page ("What Sprout's wearing", "Shop").
struct PassportSproutHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(PassportSproutFont.caps(11))
            .textCase(.uppercase)
            .tracking(1.3)
            .foregroundStyle(PassportSproutInk.moss)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One framed button on the page (`.ppslot`, `.pprow`): an icon in a 26-pt box, an optional caps label over its
/// value, and whatever trails it (the coins chip, the chevron). 44 pt tall at least, 2-pt ink, 8-pt corners.
struct PassportSproutButtonFace<Icon: View, Trailing: View>: View {
    var label: String?
    let value: String
    var fill: Color = PassportSproutInk.tile
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            icon().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                if let label {
                    Text(verbatim: label)
                        .font(PassportSproutFont.caps(9.5))
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(PassportSproutInk.dim)
                }
                Text(verbatim: value)
                    .font(PassportSproutFont.value(14))
                    .foregroundStyle(PassportSproutInk.text)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Two side by side, or one column at the largest text sizes (`.ppslots`, `.pptwo`).
struct PassportSproutPairs<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: columns), spacing: 6) {
            content()
        }
    }
}

/// What Sprout's wearing: the four slot buttons, two by two, then Wardrobe and Creation Studio.
struct PassportSproutWearing: View {
    let model: PassportSproutModel
    let act: (PassportSproutAction) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 6) {
            PassportSproutHeading(text: PassportSproutCopy.wearingHeader(name: model.name))
            PassportSproutPairs {
                ForEach(model.slots, id: \.slot) { summary in
                    slotButton(summary)
                }
            }
            PassportSproutPairs {
                rowButton(.wardrobe, sprite: WorldSprites.face, title: Text("Wardrobe"), identifier: "wardrobe")
                rowButton(.creationStudio, sprite: WorldSprites.pen, title: Text("Creation Studio"), identifier: "studio")
            }
        }
    }

    /// A slot's button: its piece, its name and what is worn there. VoiceOver: "Body, Pear".
    private func slotButton(_ summary: CustomizeSlotSummary) -> some View {
        let title = String(localized: summary.slot.title)
        return Button { act(.slot(summary.slot)) } label: {
            PassportSproutButtonFace(label: title, value: summary.value) {
                CustomizeSlotIcon(slot: summary.slot, appearance: model.appearance, state: model.state)
            } trailing: { EmptyView() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: summary.value))
        .accessibilityInputLabels([Text(verbatim: title)])
        .accessibilityIdentifier("passport.sprout.slot.\(summary.slot.token)")
    }

    /// Wardrobe or Creation Studio.
    private func rowButton(_ action: PassportSproutAction, sprite: WorldSprite, title: Text, identifier: String) -> some View {
        Button { act(action) } label: {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: sprite, scale: 2).frame(width: 26, height: 26)
                // One line in the narrow two-up buttons ("Creation Studio" shrinks a little rather than wrap).
                title
                    .font(PassportSproutFont.value())
                    .foregroundStyle(PassportSproutInk.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(PassportSproutInk.tile, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("passport.sprout.\(identifier)")
    }
}

/// The shop: Your shop with "3 of 6 listed" and the coins chip, then, for the hour after a session, the gold
/// Friend shops row with its minutes.
struct PassportSproutShop: View {
    let model: PassportSproutModel
    let act: (PassportSproutAction) -> Void

    /// How many items a shop can list.
    static let shopSpots = ClothingShopLimits.maxListedItems

    var body: some View {
        let listed = PassportSproutCopy.listed(model.listed, of: Self.shopSpots)
        VStack(spacing: 6) {
            PassportSproutHeading(text: PassportSproutCopy.shopHeader)
            Button { act(.yourShop) } label: {
                PassportSproutButtonFace(label: PassportSproutCopy.yourShop, value: listed) {
                    WorldSpriteView(sprite: FriendsSprites.bag, scale: 2)
                } trailing: {
                    PassportCoinsChip(coins: model.coins)
                    FernletIcon(.chevron, scale: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: PassportSproutCopy.yourShopSpoken(listed: listed, coins: model.coins)))
            .accessibilityInputLabels([Text(verbatim: PassportSproutCopy.yourShop)])
            .accessibilityIdentifier("passport.sprout.yourShop")
            if let minutes = model.friendShopMinutes {
                friendShops(minutes)
            }
        }
    }

    /// The gold Friend shops row: "Open · 52 min left".
    private func friendShops(_ minutes: Int) -> some View {
        Button { act(.friendShops) } label: {
            PassportSproutButtonFace(label: PassportSproutCopy.friendShops, value: PassportSproutCopy.friendShopsOpen(minutes: minutes),
                                     fill: PassportSproutInk.gold) {
                WorldSpriteView(sprite: FriendsSprites.bag, scale: 2)
            } trailing: {
                FernletIcon(.chevron, scale: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: PassportSproutCopy.friendShopsSpoken(minutes: minutes)))
        // Voice Control: the shops' name, without the countdown that changes by the minute.
        .accessibilityInputLabels([Text(verbatim: PassportSproutCopy.friendShops)])
        .accessibilityIdentifier("passport.sprout.friendShops")
    }
}

/// The coin balance as a chip (`.ppcoins`): the pixel coin and the number. Read by its row.
struct PassportCoinsChip: View {
    let coins: Int

    var body: some View {
        HStack(spacing: 4) {
            WorldSpriteView(sprite: WorldSprites.coin, scale: 2)
            Text(coins, format: .number)
                .font(PassportSproutFont.value(13))
                .foregroundStyle(PassportSproutInk.text)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(PassportSproutInk.chip, in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// The bottom row (`ref-comp-home-add`, `ref-comp-home-at`): away from a home with a precise reading, This is
/// home beside App colors; at a home "Sprout's house is here · Home" with Manage, at the hotel the suitcase and
/// "Staying at the Ace" with Manage, each over App colors; otherwise (no precise reading, a decoy) App colors
/// alone.
struct PassportSproutBottomRow: View {
    let model: PassportSproutModel
    let act: (PassportSproutAction) -> Void

    var body: some View {
        switch model.place {
        case .away:
            PassportSproutPairs {
                thisIsHome
                appColors
            }
        case .home(let name):
            VStack(spacing: 6) {
                WorldCloseUpHomeLine(sprite: WorldPlaceSprites.house, scale: 2,
                                     line: WorldCloseUpHomeCopy.houseHere(companion: model.name, home: name),
                                     onManage: { act(.manageHomes) })
                appColors
            }
        case .hotel(let name):
            VStack(spacing: 6) {
                WorldCloseUpHomeLine(sprite: WorldPlaceSprites.suitcase, scale: 3, line: WorldCloseUpHomeCopy.stayingAt(name),
                                     onManage: { act(.manageHomes) })
                appColors
            }
        case .unknown:
            appColors
        }
    }

    /// This is home, with the pixel house. VoiceOver adds "Makes where you are Sprout's home."
    private var thisIsHome: some View {
        Button { act(.thisIsHome) } label: {
            PassportSproutButtonFace(value: String(localized: WorldCloseUpHomeCopy.thisIsHome)) {
                WorldSpriteView(sprite: WorldPlaceSprites.house, scale: 2)
            } trailing: { EmptyView() }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: WorldCloseUpHomeCopy.thisIsHomeHint(companion: model.name)))
        .accessibilityIdentifier("passport.sprout.thisIsHome")
    }

    /// App colors, with the three colours as one striped swatch.
    private var appColors: some View {
        Button { act(.appColors) } label: {
            PassportSproutButtonFace(value: PassportSproutCopy.appColors) {
                PassportAppColorsSwatch()
            } trailing: { EmptyView() }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("passport.sprout.appColors")
    }
}

/// App colors' swatch (`.ppsw`): paper, wood and accent as three stripes in a 22-pt ink-framed square.
struct PassportAppColorsSwatch: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 0) {
            (look?.paper ?? Color.cream)
            (look?.wood ?? WorldPalette.wood)
            (look?.accent ?? Color.moss)
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityHidden(true)
    }
}

import FernletDomainModel
import FernletUI
import SwiftUI

/// The map intro (design `b1-loc-intro`, approved 2026-10-23; World build step 5c): shown once, before iOS
/// asks, full screen in the panel frame ("The map", the pin, ✕). It says what the map keeps and where, in
/// four rows that match what exists (owner's option A): the fog from today, walks and runs saved on this
/// iPhone so the blue button can start them again, Where you've been sealed in Private, and While Using
/// unless background mapping is turned on.
///
/// **Turn on location** asks iOS for While Using (`b1-loc-prompt`: iOS draws that prompt, with Precise on);
/// **Not now** and ✕ leave Home on its open scene (`b1-home-denied`). Either answers the intro for this
/// iPhone (``WorldMapPreferences/setLocationIntroAnswered(in:)``). Settings → Home map's Location row opens it
/// again while iOS hasn't asked yet.
///
/// VoiceOver reads the title, the four rows (each one element) and the two buttons, in order. At the
/// largest text sizes the page scrolls.
struct WorldLocationIntro: View {
    /// "Turn on location".
    let onTurnOn: () -> Void
    /// "Not now" and ✕.
    let onNotNow: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        WorldPanelFrame(panel: .settings, title: String(localized: WorldLocationIntroCopy.plate), icon: WorldSprites.pin,
                        onClose: onNotNow) {
            ScrollView {
                VStack(spacing: 16) {
                    companion
                    Text(WorldLocationIntroCopy.title)
                        .font(Font.custom(FernletFontName.frauncesSemiBold, size: 27, relativeTo: .title))
                        .foregroundStyle(WorldPalette.bark)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(WorldLocationIntroRow.allCases, id: \.self) { row in
                            WorldLocationIntroRowView(row: row)
                        }
                    }
                    buttons
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
        }
        .accessibilityIdentifier("world.locationIntro")
    }

    /// The thriving companion, large, over its shadow.
    private var companion: some View {
        VStack(spacing: 4) {
            WorldCompanionSprite(state: .thriving,
                                 look: WorldCompanionLook(appearance: .standard, state: .thriving, asleep: false),
                                 pixelScale: dynamicTypeSize.isAccessibilitySize ? 3 : 4)
            Capsule().fill(WorldPalette.ink.opacity(0.22)).frame(width: 64, height: 6)
        }
        .accessibilityHidden(true)
    }

    /// Turn on location (the framed primary) and Not now (moss text).
    private var buttons: some View {
        VStack(spacing: 6) {
            Button(action: onTurnOn) {
                Text(WorldLocationIntroCopy.turnOn).frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("world.locationIntro.turnOn")
            Button(action: onNotNow) {
                Text(WorldLocationIntroCopy.notNow)
                    .font(FernletFramedFont.button)
                    .foregroundStyle(WorldPalette.mossInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("world.locationIntro.notNow")
        }
        .padding(.top, 6)
    }
}

/// The intro's four rows, in the approved order.
nonisolated enum WorldLocationIntroRow: CaseIterable, Sendable {
    case uncovers
    case saved
    case privateHistory
    case whileUsing

    /// The row's pixel icon.
    var sprite: WorldSprite {
        switch self {
        case .uncovers: WorldSprites.leaf
        case .saved: WorldSprites.shoe
        case .privateHistory: WorldSprites.diary
        case .whileUsing: WorldSprites.pin
        }
    }

    /// The row's bold line.
    var title: LocalizedStringResource {
        switch self {
        case .uncovers: WorldLocationIntroCopy.uncovers
        case .saved: WorldLocationIntroCopy.saved
        case .privateHistory: WorldLocationIntroCopy.privateHistory
        case .whileUsing: WorldLocationIntroCopy.whileUsing
        }
    }

    /// The line under it.
    var detail: LocalizedStringResource {
        switch self {
        case .uncovers: WorldLocationIntroCopy.uncoversDetail
        case .saved: WorldLocationIntroCopy.savedDetail
        case .privateHistory: WorldLocationIntroCopy.privateHistoryDetail
        case .whileUsing: WorldLocationIntroCopy.whileUsingDetail
        }
    }
}

/// One intro row: the icon in a 44-pt column, the bold line and the line under it, read as one.
private struct WorldLocationIntroRowView: View {
    let row: WorldLocationIntroRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorldSpriteView(sprite: row.sprite, scale: 3)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .headline))
                    .foregroundStyle(WorldPalette.bark)
                Text(row.detail)
                    .font(Font.custom(FernletFontName.dmSans, size: 15, relativeTo: .subheadline))
                    .foregroundStyle(WorldPalette.dim)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The intro's words (`b1-loc-intro`, approved; Spanish drafts in the lane's file).
nonisolated enum WorldLocationIntroCopy {
    static let plate = LocalizedStringResource("worldLocationIntro.plate", defaultValue: "The map",
                                               comment: "World map intro: the title on its wooden plate (Spanish: El mapa)")
    static let title = LocalizedStringResource("worldLocationIntro.title", defaultValue: "Your companion lives on a map now",
                                               comment: "World map intro: the heading, before iOS asks for location")
    static let uncovers = LocalizedStringResource("worldLocationIntro.uncovers", defaultValue: "It uncovers as you go",
                                                  comment: "World map intro, row 1: the fog lifts where you walk")
    static let uncoversDetail = LocalizedStringResource("worldLocationIntro.uncovers.detail",
                                                        defaultValue: "The fog lifts where you walk, from today. Turn it off in Settings.",
                                                        comment: "World map intro, row 1's line")
    static let saved = LocalizedStringResource("worldLocationIntro.saved", defaultValue: "Walks and runs are saved",
                                               comment: "World map intro, row 2: walk and run lines are kept on the phone")
    static let savedDetail = LocalizedStringResource("worldLocationIntro.saved.detail",
                                                     defaultValue: "On this iPhone, so the blue button can start them again.",
                                                     comment: "World map intro, row 2's line")
    static let privateHistory = LocalizedStringResource("worldLocationIntro.private", defaultValue: "Where you've been stays private",
                                                        comment: "World map intro, row 3: the places timeline is in Private")
    static let privateHistoryDetail = LocalizedStringResource("worldLocationIntro.private.detail",
                                                              defaultValue: "Sealed in Private like your journal. Delete it any time.",
                                                              comment: "World map intro, row 3's line")
    static let whileUsing = LocalizedStringResource("worldLocationIntro.whileUsing", defaultValue: "Only while you use Fernlet",
                                                    comment: "World map intro, row 4: location only while the app is in use")
    static let whileUsingDetail = LocalizedStringResource("worldLocationIntro.whileUsing.detail",
                                                          defaultValue: "Background mapping is a setting, off unless you turn it on.",
                                                          comment: "World map intro, row 4's line")
    static let turnOn = LocalizedStringResource("worldLocationIntro.turnOn", defaultValue: "Turn on location",
                                                comment: "World map intro: the button that asks iOS for location")
    static let notNow = LocalizedStringResource("worldLocationIntro.notNow", defaultValue: "Not now",
                                                comment: "World map intro: leave location off for now")
}

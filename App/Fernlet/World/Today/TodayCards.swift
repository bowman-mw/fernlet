import SwiftUI
import FernletDomainModel
import FernletUI

/// The Today panel's top card (design `b1-today`, draft 2): the companion as it stands on the map, its
/// name and state, and Customize, which opens the same sheet as holding the companion on the map. It
/// replaces Home's companion section and its chip there; the companion itself lives on the map.
struct TodayCompanionCard: View {
    var store: FernletStore
    /// Whether the panel is on screen; off, the sprite's breath stops.
    var isActive: Bool
    let onCustomize: () -> Void
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            // The map's picture of it (W-06a): the same live state, look, pieces and night.
            let now = WorldCompanionLook.current(store: store, at: context.date, night: .map)
            let state = now.state
            let sprite = WorldCompanionSprite(now: now, isActive: isActive)
            FernletCard {
                // At accessibility sizes the row stacks, so the name and Customize never break mid-word.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) { sprite; title }
                        line(state)
                        customize
                    }
                } else {
                    HStack(spacing: 14) {
                        sprite
                        VStack(alignment: .leading, spacing: 3) { title; line(state) }
                        Spacer(minLength: 8)
                        customize
                    }
                }
            }
        }
    }

    /// The companion's name.
    private var title: some View {
        Text(verbatim: name)
            .font(.fernlet(.headerMedium))
            .foregroundStyle(look?.text ?? Color.bark)
            .fernletWrappingText()
    }

    /// Its state, and the other way to customize it.
    private func line(_ state: CompanionState) -> some View {
        Text(verbatim: String(localized: "worldToday.companion.line", defaultValue: "\(state.displayName) · or hold it on the map",
                              comment: "World Today panel, companion card: the companion's state, then how else to customize it (holding it on the map)"))
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
    }

    /// The companion's name (``FernletStore/worldCompanionName``).
    private var name: String {
        store.worldCompanionName
    }

    /// The framed Customize chip.
    @ViewBuilder
    private var customize: some View {
        let chip = Button(action: onCustomize) {
            HStack(spacing: 6) {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                Text("Customize")
            }
                .font(.fernlet(.labelSmall).weight(.semibold))
                .foregroundStyle(look?.text ?? Color.slate)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityHint("Change how your companion looks")
        .accessibilityIdentifier("world.today.customize")
        if let look {
            chip.fernletFramed(look)
        } else {
            chip
        }
    }
}

/// The Today panel's gold hearts card (design `b1-today`, draft 2): shown only while a heart a friend
/// gave in person is gold, with the gold hearts, the lifted care score and when it fades. Display only:
/// the saved day score never changes (`GoldHeartRules`).
struct TodayGoldHeartsCard: View {
    let status: WorldStatus
    /// When the last gold heart fades.
    let until: Date
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gold hearts")
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(look?.text ?? Color.bark)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        ForEach(0..<status.goldHearts, id: \.self) { _ in
                            WorldSpriteView(sprite: WorldSprites.heart, scale: 3, variant: .heart(.gold))
                        }
                    }
                }
                Text(verbatim: String(localized: "worldToday.gold.line",
                            defaultValue: "Time with friends lifts your care score to \(status.livePercent)% until \(until.formatted(date: .omitted, time: .shortened)).",
                            comment: "World Today panel, gold hearts card: the care score a friend's in-person heart lifts it to, and the time the lift ends"))
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("world.today.goldHearts")
    }
}

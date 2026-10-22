import SwiftUI

/// The live-map Home: the map full-bleed, the status bars on top, the photo strip under them, the
/// blue button above the item bar, and one framed panel at a time between them.
struct WorldHomeView: View {
    @State private var model = WorldShellModel(options: ShellLaunchOptions())

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.everyMinute) { timeline in
                let phase = model.phase(at: timeline.date)
                ZStack {
                    WorldMapStack(model: model, phase: phase, creditInset: proxy.safeAreaInsets.bottom + 82)
                    if model.quickStartOpen {
                        Color.clear.contentShape(Rectangle()).onTapGesture { model.quickStartOpen = false }
                    }
                    topHUD(phase: phase, date: timeline.date)
                    if let panel = model.panel {
                        PanelFrame(kind: panel, onClose: { model.panel = nil }) { PanelContent(model: model, kind: panel) }
                            .padding(EdgeInsets(top: 96, leading: 8, bottom: 82, trailing: 8))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    bottomHUD
                }
                .animation(.easeOut(duration: 0.18), value: model.panel)
                .animation(.easeOut(duration: 0.2), value: model.toast)
                .animation(.easeOut(duration: 0.2), value: model.banner)
            }
        }
        .preferredColorScheme(.light)
        .statusBarHidden(false)
    }

    /// The two status bars, the photo strip (or the walk bar) and the banner.
    private func topHUD(phase: SkyPhase, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                StatusBarLeft(careScore: model.careState.careScore, goldHearts: model.level.goldHearts,
                              protein: model.protein, carbs: model.carbs, fat: model.fat, water: model.water) { model.toggle(.today) }
                Spacer()
                StatusBarRight(phase: phase, clock: model.phaseOverride?.sampleClock ?? date.formatted(date: .omitted, time: .shortened),
                               coins: model.level.coins)
            }
            if let replay = model.replay, model.isWalking {
                WalkBar(kilometres: replay.kilometres, hike: replay.kind == .hike) { model.finishWalk() }
            } else if model.level.hasPhotos && model.ride == .onFoot && model.panel == nil {
                PhotoStrip(photos: WorldFixtures.friendPhotos) { model.toggle(.wall) }
            }
            if let banner = model.banner {
                BannerView(banner: banner).frame(maxWidth: .infinity).transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 0, trailing: 10))
    }

    /// The toast, the quick-start card and button, the recentre button, and the item bar.
    private var bottomHUD: some View {
        VStack(spacing: 8) {
            Spacer()
            if model.quickStartOpen && model.quickStartsAvailable {
                QuickStartCard(spot: model.matchedSpot, level: model.level, gentle: model.careState.isGentle,
                               onPick: { model.runQuickStart($0) }, onClose: { model.quickStartOpen = false })
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let toast = model.toast {
                ToastView(toast: toast) { model.undo($0) }.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.panel == nil { mapButtons }
            ItemBar(open: model.panel) { model.toggle($0) }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
    }

    /// Bottom-right, above the bar: "At Riverside Gym", the blue button, and Back to Fernlet.
    private var mapButtons: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer()
            if !model.camera.follows { RecentreButton { model.recentre() } }
            if model.quickStartsAvailable {
                if let spot = model.matchedSpot, !model.quickStartOpen {
                    Text("At \(spot.label)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(FernColors.ink)
                        .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
                        .background(FernColors.gameCream.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FernColors.ink, lineWidth: 2))
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                }
                QuickStartButton(spot: model.matchedSpot, expanded: model.quickStartOpen) { model.quickStartOpen.toggle() }
            }
        }
        .padding(.trailing, 2)
    }
}

/// The body of whichever panel is open.
private struct PanelContent: View {
    let model: WorldShellModel
    let kind: PanelKind

    var body: some View {
        switch kind {
        case .today: TodayPanel(model: model)
        case .food: FoodPanel(model: model)
        case .move: MovePanel(model: model)
        case .log: LogPanel(model: model)
        case .friends: FriendsPanel(model: model)
        case .privacy: PrivatePanel(model: model)
        case .settings: SettingsPanel(model: model)
        case .wall: WallPanel(model: model)
        case .customize: CustomizePanel(model: model)
        }
    }
}

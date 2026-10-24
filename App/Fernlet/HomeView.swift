import ProximityKit
import FernletSocial
import HealthKit
import LocalPersistence
import FernletFoundation
import SwiftUI
import FernletScoring
import PrivateHealthStore
import HealthKitGateway
import AppServices
import StoreCore

#if canImport(UIKit)
import UIKit
import FernletDomainModel
import FernletUI
#endif

/// What a `HomeView` draws (World build, branch `world-ui`).
///
/// The World Home moves Home's cards off the map into panels; drawing them with this same view keeps
/// every card's data and behaviour identical (design page "Same data, new look").
nonisolated enum HomePresentation: Equatable, Sendable {
    /// The whole Home page: header, photo wall and every card in the person's Home order.
    case page
    /// The World Today panel (design `b1-today`, draft 2, in the one design language): the companion
    /// card on top, the gold hearts card while one lasts, then every card in the person's Home order
    /// except the companion (it lives on the map) and Quick log (the Log panel), then Arrange Today.
    case today
    /// Only the Quick log and mood cards: the item bar's Log panel.
    case quickLog

    /// The cards to draw, from the person's Home order.
    func widgets(from order: [HomeWidget]) -> [HomeWidget] {
        switch self {
        case .page: order
        case .today: TodayLayout.shown(order)
        case .quickLog: [.quickLog]
        }
    }
}

/// The Home tab: the companion hero and the user-configurable dashboard feed.
///
/// Renders the header, the photowall strip (friend polaroids + the companion's thought bubble),
/// then one section per entry in `settings.homeWidgets` — companion, today summary/intent, quick
/// log, macros, hygiene, ambient cards, milestones shelf, First Aid door, meal-photo strip, and
/// plain action rows. The companion section owns the pet interaction (tap to pet, governed by
/// `PetInteractionGovernor`'s anti-compulsion pacing; the Customize chip — or the legacy
/// long-press — opens `CompanionCustomizationSheet`) and composes ``CompanionAmbienceLayer``
/// behind it.
///
/// Privacy-relevant detail: `refreshRecentPeriodActivity` uses the app-lifetime HealthKit client,
/// re-checks `allowedHealthCapabilities`, and runs only for initial hydration or an actual cycle
/// setting/log change. Prior-day rows for "Recent bites" are cached per day rollover rather than
/// re-decrypted every render.
struct HomeView: View {
    var store: FernletStore
    var healthKitService: HealthKitService
    /// The user's term of address (the app root sets it from the body profile), for the companion
    /// thought that describes them ("You marked today as tired").
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Binding var activeSheet: FernletSheet?
    @Binding var selectedTab: FernletTab
    @Binding var privateHubSection: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    /// ContentView's Home re-select token, consumed directly as the scroll-to-top token. Home's own
    /// stack pushes nothing (the customization sheet has its own stack), so a re-tap has nothing to
    /// pop; a push added to this stack must adopt `tabReselect` like the other tabs.
    @Binding var tabResetToken: Int
    /// Shared period store, threaded from ContentView for the (opt-in) cycle surfaces.
    var periodStore: PeriodTrackerStore? = nil
    /// Shared body-signals service, threaded from ContentView for the (opt-in) stress surfaces.
    var stressService: StressService? = nil
    /// The root `TabView` retains Home offscreen. Continuous Canvas clocks must pause whenever
    /// another tab or a root sheet covers Home, otherwise they render forever while invisible.
    var isActive: Bool = true
    /// The meal-logged toast, for the ambient cards' one-tap meal chips (forgotten favorites and the
    /// nutrient nudge's "add it"), which log in place and are confirmed like every other meal log.
    var onMealsLogged: MealLogReporter = .none
    /// What this Home draws (World build): the whole page, or only the Quick log and mood cards for
    /// the item bar's Log panel. The same cards either way, so the panels show exactly Home's data.
    var presentation: HomePresentation = .page
    @State private var hasRecentPeriodEvent = false
    @State private var didLoadRecentPeriodActivity = false
    @State private var isCompanionThoughtVisible = true
    @State private var companionTapThought: String?
    @State private var isCompanionSheetPresented = false
    /// Arrange Today, open over the Today panel (World build).
    @State private var isArrangingToday = false
    @State private var companionPetCount = 0
    @State private var companionTapCount = 0
    @State private var isCompanionJumping = false
    /// Gentle pet pacing (Quabble anti-compulsion pattern) — device-local state only.
    @State private var petGovernor = PetInteractionGovernor()
    /// Soft settle-squish shown when petting the already-content companion (no bounce).
    @State private var isCompanionCalmSettling = false
    /// Presentation-only mirror of `petGovernor.isSettled` — drives the droopy-happy "settled"
    /// companion pose during the pet-cooldown window. Set when a pet settles the companion and
    /// re-checked against the governor so the pose fades once the window ends.
    @State private var isCompanionSettled = false
    /// Cached sky snapshot for the ambience layer; nil ⇒ time-of-day tint only.
    @State private var companionAmbient: WeatherAmbient?
    /// The "Recent bites" polaroid the user tapped, presented as a larger dismissible viewer.
    @State private var selectedBite: RecentBite?
    /// The prior six days' rows behind "Recent bites", loaded once per day rollover (see
    /// `reloadPriorDayRows` / `mealPhotosStrip`'s `.task(id:)`) instead of on every `body` pass. Today is
    /// never cached here — it stays live from the observed `store.day`.
    @State private var cachedPriorDays: [FernletDay] = []
    /// Cancel-and-replace handle for the recent-period-activity query (R3: one HealthKit read in
    /// flight, never one per sheet dismissal / visibility flip).
    @State private var periodActivityTask: Task<Void, Never>?
    /// Cancel-and-replace handle for the settled-pose re-sync (R3: one sleeping task, not one per pet).
    @State private var settledResyncTask: Task<Void, Never>?
    /// When the playful beat after the latest pet ends — the companion's `petted` emotion input.
    /// In-memory only: a pet is a touch in this session, not something to remember across launches.
    @State private var playfulUntil: Date?
    /// The companion-feelings settings, read through `@AppStorage` so a change in Settings redraws
    /// the companion at once. Same keys `CompanionEmotionPreferences` reads for the widget.
    @AppStorage(CompanionEmotionPreferences.appetiteCuesKey) private var appetiteCuesEnabled = true
    @AppStorage(CompanionEmotionPreferences.bedtimeMinuteKey) private var bedtimeMinute = CompanionSleepWindow.standard.bedtimeMinute
    @AppStorage(CompanionEmotionPreferences.wakeMinuteKey) private var wakeMinute = CompanionSleepWindow.standard.wakeMinute
    /// The photowall strip's height, scaled with the user's text size — the tiles sit inside it and
    /// the thought bubble sits on top of it, so a fixed height clipped both at accessibility sizes.
    /// 126: FLOW-18 cut this to 92 for the compacted cold open, which shrank the prints to stamps.
    /// The keepsake wall is the warmest thing on Home, so the full-size print is back — but in a
    /// strip 6pt under the original 132, which the (deliberately unclipped) tiles overhang by a
    /// couple of points at each end exactly as they did before.
    @ScaledMetric(relativeTo: .body) private var photowallHeight: CGFloat = 126
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        NavigationStack {
            ScrollView {
                cardStack
                    .padding(20)
                    .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            // In a World panel, the panel's dotted page (the stack paints its own background otherwise).
            .background {
                if presentation == .page { Color.parchment } else { WorldPageBackground().ignoresSafeArea() }
            }
            .navigationTitle("")
        }
        // Today's cards in the one design language; the sheets below keep their own look.
        .fullScreenCover(isPresented: $isArrangingToday) {
            WorldPanelFrame(panel: .today, title: String(localized: "worldToday.arrange.title", defaultValue: "Arrange Today",
                                                         comment: "World Today panel: the title of the card layout editor"),
                            closesWithDone: true, onClose: { isArrangingToday = false }) {
                WorldTodayEditor(store: store)
            }
        }
        .sheet(isPresented: $isCompanionSheetPresented) {
            CompanionCustomizationSheet(
                store: store,
                petCount: $companionPetCount
            )
            // One detent, and it is the full one. This sheet hosts a four-level stack — Customize →
            // slot picker → Wardrobe → Creation Studio → Save item — and the last two pin a bottom
            // action bar ("Next", "Save to closet") to the sheet's edge. At the half detent there is
            // no room left above that bar: the studio's canvas and the save step's shop toggle fall
            // below the fold, directly behind it, so a tap aimed at the toggle lands on Save — which
            // saves the item unlisted and, because the studio exits by dismissing, tears the whole
            // sheet down to Home. Nothing is lost by dropping the half detent: every screen in here
            // draws the companion itself, which is all the half sheet was showing behind it.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
        .task {
            #if DEBUG
            // Test hook: open customization directly (the real entry is a long-press XCUITest can't send).
            if UITestSupport.shouldOpenCustomize { isCompanionSheetPresented = true }
            #endif
            // Restore the settled pose if the app returned during an active cooldown window.
            isCompanionSettled = petGovernor.isSettled
            if !didLoadRecentPeriodActivity {
                didLoadRecentPeriodActivity = true
                await refreshRecentPeriodActivity()
            }
            // A notice, not an action: nothing is lost by missing it, so the stretched window only
            // has to be long enough for the cursor to reach and read it.
            let window = FernletDismissalWindow.system.window(
                standard: .seconds(6),
                assistive: FernletDismissalWindow.assistiveNoticeWindow)
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled with the view's `.task` — the thought goes away with the view.
                return
            }
            withAnimation(.easeInOut(duration: 0.35)) {
                isCompanionThoughtVisible = false
            }
        }
        .task {
            // Ambience sky accents: opt-in (weather prompts) and served from the shared
            // ≤90-min WeatherKitService cache, under its 10-a-day WeatherKit budget. Renders
            // never wait on it — until (unless) it lands, the layer shows
            // the time-of-day tint alone.
            guard store.settings.weatherPromptsEnabled else { return }
            companionAmbient = await WeatherKitService.shared.currentAmbient()
        }
        .onChange(of: activeSheet?.id) { old, new in
            if old == "logPeriod", new == nil { scheduleRecentPeriodActivityRefresh() }
        }
        // Hiding must drop the resident flag immediately, not wait for the next sheet dismiss.
        .onChange(of: store.isPeriodTrackingVisible) { _, _ in
            scheduleRecentPeriodActivityRefresh()
        }
    }

    /// Every section this Home draws, top to bottom.
    private var cardStack: some View {
        VStack(spacing: 16) {
            if presentation == .page {
                homeHeader
                // 3a·AX3: the photowall and thought bubble give way entirely at accessibility
                // sizes — the strip is decorative (hit-testing already disabled), and the grid
                // starting above the tab bar is the promise that matters.
                if !dynamicTypeSize.isAccessibilitySize {
                    photowallStrip
                }
            }
            if presentation == .today { todayHead }
            ForEach(presentation.widgets(from: store.settings.homeWidgets)) { widget in
                homeWidget(widget)
            }
            if presentation == .today { arrangeTodayButton }
        }
    }

    /// The Today panel's top: the companion card, then the gold hearts card while one lasts.
    @ViewBuilder
    private var todayHead: some View {
        TodayCompanionCard(store: store, isActive: isActive) { isCompanionSheetPresented = true }
        if store.goldHeartCount() > 0, let until = store.goldHeartsEnd() {
            TodayGoldHeartsCard(status: WorldStatus.current(store: store, date: Date()), until: until)
        }
    }

    /// The one design language (`b1-language`), set at the app's root for every screen.
    @Environment(\.fernletFramedLook) private var framedLook

    /// Arrange Today, at the bottom of the Today panel: the layout editor (design `b1-today-editor`).
    private var arrangeTodayButton: some View {
        Button { isArrangingToday = true } label: {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: WorldSprites.grip, scale: 2, tint: WorldPalette.mossInk)
                Text("Arrange Today")
                    .font(.fernlet(.label))
                    .foregroundStyle(WorldPalette.mossInk)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("world.today.arrange")
    }

    // MARK: - Milestones entry card

    /// One kind of care the user has kept, as a soft Home-dashboard icon token.
    ///
    /// Stable order + tint per kind so the shelf doesn't reshuffle between renders; built by
    /// `keptKeepsakes(counts:worries:)` from the pre-read ledger values.
    private struct Keepsake: Identifiable {
        let id: MilestoneEventKind
        let icon: String
        let tint: Color
    }

    /// Icon + tint per milestone kind, read from ``MilestoneRowModel/style(for:)`` — the single table
    /// the Milestones page and keepsake shelf draw from too.
    ///
    /// This card used to carry its own copy (journal as a moss "book", workouts terracotta) while the
    /// page rendered journal as an amethyst "book.closed" and workouts green, so the same keepsake
    /// changed glyph and colour one tap after the user saw it.
    private func keepsakeStyle(for kind: MilestoneEventKind) -> (icon: String, tint: Color) {
        MilestoneRowModel.style(for: kind)
    }

    /// The kinds the user has actually kept (count > 0) from the pre-read ledger inputs, one token each,
    /// in enum-declaration order. Iterating the ledger's own `countedKinds` rather than the style table
    /// guarantees coverage of a future kind instead of dropping it — and rather than `allCases`, which
    /// since 2026-08-21 also carries `.resetBoundary`, the wipe's bookkeeping row: never a keepsake, so
    /// it must not reach the shelf even if a count for it ever appeared. Takes the counts + worry total
    /// as arguments so the card can scan each ledger exactly once and share the result with the summary.
    private func keptKeepsakes(counts: [MilestoneEventKind: Int], worries: Int) -> [Keepsake] {
        MilestoneEconomy.countedKinds.compactMap { kind in
            let kept = kind == .worry ? worries > 0 : (counts[kind] ?? 0) > 0
            guard kept else { return nil }
            let style = keepsakeStyle(for: kind)
            return Keepsake(id: kind, icon: style.icon, tint: style.tint)
        }
    }

    /// M1 milestones doorway: the kinds of care kept, using the same soft tinted icon-tile language as
    /// the rest of Home. The dedicated milestone screen still owns the pressed keepsake shelf.
    /// Cumulative-only, never a scoreboard: a warm sentence and a soft coins aside, no streaks, no
    /// percentages, and the empty state is a gentle invitation.
    private var milestonesCard: some View {
        // Read each lifetime ledger ONCE per render and derive the shelf, the summary, and the coin pill
        // from the same values — the ledgers are append-only and only grow, and this card re-renders on
        // every store mutation, so a per-derivation re-scan is avoidable main-thread work.
        let counts = store.milestoneCounts
        let worries = store.lifetimeWorriesLetGo
        let coins = CoinEconomy.milestoneAwardCoins(in: store.coinLedgerService.entries)
        let kept = keptKeepsakes(counts: counts, worries: worries)
        let summary = Self.milestonesSummary(keptKinds: kept.count, coins: coins)
        // A large sheet, not a push (HOME-13): one rule for read-only destinations from Home —
        // they present as sheets, matching Trends, First aid and the gear.
        return Button {
            activeSheet = .milestones
        } label: {
            FernletCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Milestones")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Spacer()
                        if coins > 0 {
                            // Goldenrod-family text on the card's cream with a hairline goldenrod border
                            // — the house coin style (MilestonesView), and the reason it isn't a
                            // goldenrod fill: goldenrod-on-goldenrod-tint drops below the contrast floor
                            // for 12pt text. T1-3: `goldenrodInk` (4.95:1), not plain `goldenrod`
                            // (2.22:1) — the border stays the decorative accent.
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                Text(HomeCopy.coinsGiftedPill(coins)).font(.fernlet(.labelSmall))
                            }
                            .foregroundStyle(Color.goldenrodInk)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Color.goldenrod.opacity(0.4), lineWidth: 1))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.slate)
                    }
                    if !kept.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(kept.prefix(5)) { k in
                                keepsakeTile(k)
                            }
                            if kept.count > 5 {
                                Text("+\(kept.count - 5)")
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.bark.opacity(0.06), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text(summary)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.milestones")
        // Fold the summary into the LABEL, not the hint: an explicit label REPLACES everything the
        // Button gathered from its own content (the visible summary and coin pill included), and a
        // hint is silenced by the system "Speak Hints" setting — so a hint-only summary would leave
        // a VoiceOver user hearing just "Milestones, button".
        //
        // Deliberately NO `.accessibilityElement(children: .ignore)`: on a `Button` that mints a
        // SECOND, traitless element beside the real one, so the card stops announcing as a button
        // and picks up a phantom swipe stop. The Button's own element already collapses its
        // children, which is all `.ignore` was ever wanted for here.
        .accessibilityLabel("Milestones. \(summary)")
        // T2-12: the label above is a whole sentence, and a Voice Control user has to *say* a
        // control's name to tap it. Shortest first — that is the order Voice Control shows them in
        // its numbered overlay — and additive: the spoken label is unchanged.
        .accessibilityInputLabels([Text("Milestones"), Text("Keepsakes")])
    }

    private func keepsakeTile(_ keepsake: Keepsake) -> some View {
        Image(systemName: keepsake.icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(keepsake.tint)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(keepsake.tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(keepsake.tint.opacity(0.20), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// A warm, count-aware one-liner for the milestones card, from already-scanned inputs. Keeps the
    /// keepsake framing: coins are a soft aside, the empty case is gentle — never a to-do. `static` +
    /// pure so the card can compute it from ledger values it already read, without re-scanning. The
    /// words, and their plural rules, are ``HomeCopy/milestonesSummary(keptKinds:coins:)``.
    static func milestonesSummary(keptKinds: Int, coins: Int) -> String {
        HomeCopy.milestonesSummary(keptKinds: keptKinds, coins: coins)
    }

    @ViewBuilder
    private func homeWidget(_ widget: HomeWidget) -> some View {
        switch widget {
        case .companion:
            companionSection
        case .todaySummary:
            todayCard
        case .todayIntent:
            todayIntentPrompt
        case .quickLog:
            quickLog
        case .macros:
            MacroCard(
                totals: store.macroTotals,
                targets: store.nutritionTargets,
                showCalories: store.settings.showCalories,
                fiberIntake: store.micronutrientTotals.fiber
            )
        case .hygiene:
            HygieneCard(store: store, activeSheet: $activeSheet)
        case .ambient:
            AmbientCardsView(
                store: store,
                activeSheet: $activeSheet,
                periodPrediction: homePeriodPrediction,
                stressState: store.settings.stressAwarenessEnabled ? stressService?.assessment?.state : nil,
                onMealsLogged: onMealsLogged
            )
        case .milestones:
            milestonesCard
        case .firstAid:
            firstAidAction
        case .mealPhotos:
            mealPhotosStrip
        case .sillyStats:
            SillyStatsHomeCard(stats: store.sillyStats) { activeSheet = .sillyStats }
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .trends:
            HomeActionWidget(widget: widget) {
                handleHomeWidget(widget)
            }
        }
    }

    private var homeHeader: some View {
        let today = FernletDate.niceDate()
        return HStack(alignment: .top) {
            // Both halves are `Text(verbatim:)` on purpose: "Fernlet" is the product's proper
            // noun and must never be translated, and the subtitle is an already-localized
            // formatted date, which must not be run through a catalog lookup that can't match it.
            // 3a·AX3: the date eyebrow gives way at accessibility sizes.
            ScreenHeader(
                title: Text(verbatim: "Fernlet"),
                // `uppercased(with: .current)`, not the bare `uppercased()`: this is a FORMATTED
                // DATE, already locale-dependent and already final, and Swift's bare form applies
                // the Unicode ROOT case mapping — which turns a Turkish "i" into "I" rather than
                // "İ". `.textCase(.uppercase)` is the fix everywhere the string is still a catalog
                // key, but it returns a `View`, and `ScreenHeader.subtitle` is typed `Text` so the
                // two halves of the header can be decided independently (T2-1).
                subtitle: Text(verbatim: dynamicTypeSize.isAccessibilitySize
                               ? "" : today.uppercased(with: .current)),
                subtitleFirst: true,
                identifier: "screen.home"
            )
            // T2-2: emptying the eyebrow at accessibility sizes takes today's date out of the
            // accessibility tree along with the pixels. Same convention as ``companionThought``, and
            // unconditional because `ScreenHeader` is one combined element either way: at ordinary
            // sizes this is the unabbreviated form of a string the label already carries, and on the
            // rotor a repeat costs nothing, while a branch here would fork the whole header.
            .accessibilityCustomContent("Date", Text(verbatim: today))
            Spacer()
            // The shared header control every other tab uses (58pt cream, stroked). The hand-rolled
            // 44pt 6%-bark circle this replaces was visibly smaller and lighter than its siblings.
            HeaderActionButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
                activeSheet = .settings
            }
            .accessibilityIdentifier("home.settings")
        }
    }

    /// The companion's current line: the thought a tap produced, otherwise the ambient one.
    ///
    /// **The custom-content convention (T2-2).** A view that is never *drawn* never enters the
    /// accessibility tree, so a layout that removes real content at accessibility text sizes removes
    /// it from speech too — for a user running Larger Text *and* VoiceOver, which is a common
    /// pairing. The visual decision stands; the content comes back through
    /// `.accessibilityCustomContent(_:_:)` on the nearest element that owns it — here the companion,
    /// whose line this is. Custom content rather than a longer `.accessibilityLabel`: it is there on
    /// demand and never lengthens the sentence spoken on every landing. The value is runtime text, so
    /// it is passed as `Text(verbatim:)`; a custom-content *label* is authored copy and stays a
    /// `LocalizedStringKey` literal.
    private var companionThought: String {
        companionTapThought ?? ambientThought
    }

    private var photowallStrip: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                let tiles = photowallTiles
                let horizontalInset: CGFloat = 46
                // The full-size prints are taller than the strip and hang out of both ends of it
                // (nothing clips them). Riding 10pt above centre spends that overhang upward, into
                // the header's own margin, instead of down onto the companion's sprout.
                let verticalLift: CGFloat = 10
                let finalIndex = max(tiles.count - 1, 1)

                ZStack {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        PolaroidTile(
                            color: tile.color,
                            // The tiles overlap by design, so at accessibility sizes the four
                            // captions ran into each other ("brigh good note morning"). Only the
                            // front tile (highest zIndex) keeps its caption there.
                            verbatimCaption: showsAllPolaroidCaptions || index == finalIndex ? tile.caption : "",
                            rotation: tile.rotation,
                            imageData: tile.photoID.flatMap { store.meshFeatures.photos.thumbnailData(forPhotoID: $0) },
                            // The original print, restored: at the 57×50 the 92pt strip allowed,
                            // the four tiles stopped overlapping and read as swatches rather than
                            // photos. 104 wide against the 90pt gap between positions is what
                            // gives the wall its hand-placed overlap.
                            imageWidth: 104,
                            imageHeight: 92
                        )
                        .position(
                            x: horizontalInset
                                + (geometry.size.width - horizontalInset * 2)
                                * CGFloat(index) / CGFloat(finalIndex),
                            y: geometry.size.height / 2 - verticalLift
                        )
                        .zIndex(Double(index))
                    }
                }
            }

            ThoughtBubble(text: companionTapThought ?? ambientThought)
                .padding(.bottom, 8)
                .opacity(isCompanionThoughtVisible ? 1 : 0)
                .zIndex(100)
        }
        // Scales with the text size instead of a hard 132: at accessibility sizes the fixed strip
        // clipped the bubble to "Keep t…".
        .frame(height: photowallHeight, alignment: .bottom)
        .padding(.top, 4)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
    }

    /// Below `.accessibility1` every polaroid keeps its caption; above it only the front one does.
    private var showsAllPolaroidCaptions: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    private var photowallTiles: [PhotowallTile] {
        let seeds = store.photowallSeeds
        guard seeds.count == 4 else {
            return [
                PhotowallTile(caption: HomeCopy.photowallParkWalk, rotation: -3, color: .fern.opacity(0.45), photoID: nil),
                PhotowallTile(caption: HomeCopy.photowallDinner,   rotation:  2, color: .goldenrod.opacity(0.45), photoID: nil),
                PhotowallTile(caption: HomeCopy.photowallMorning,  rotation: -1, color: .slate.opacity(0.32), photoID: nil),
                PhotowallTile(caption: HomeCopy.photowallMusic,    rotation:  3, color: .dustyRose.opacity(0.38), photoID: nil),
            ]
        }
        let palette: [Color] = [.fern.opacity(0.45), .goldenrod.opacity(0.45), .slate.opacity(0.32), .dustyRose.opacity(0.38)]
        return seeds.map { seed in
            PhotowallTile(
                // LaunchPreparationService resolves a seed's default caption ("morning", "meal", …)
                // through `photowall.caption.*` when it builds the seed, which is in memory only and
                // rebuilt every launch; a memory category of the person's own draws as it came.
                caption: seed.caption,
                rotation: seed.rotation,
                color: palette[seed.colorIndex % palette.count],
                photoID: seed.photoID
            )
        }
    }

    private var companionSection: some View {
        VStack(spacing: 10) {
            // A 30-second tick re-derives the emotion, so the time-driven ones — sleepy at bedtime,
            // hungry at the hunger onset, the end of the playful beat after a pet — arrive while Home
            // is open. The derivation is a pure function; the tick costs one evaluation.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                companionHero(emotion: companionEmotion(at: context.date))
            }

            companionActions
        }
        .frame(maxWidth: .infinity)
    }

    /// The Home companion's emotion at `date`: the store's inputs plus the three app-only signals
    /// (body signals, the pet, a friend's heart) and the companion-feelings settings.
    private func companionEmotion(at date: Date) -> CompanionEmotion? {
        store.companionEmotion(
            at: date,
            bodySignal: companionBodySignal,
            playfulUntil: playfulUntil,
            appetiteCuesEnabled: appetiteCuesEnabled,
            sleepWindow: CompanionSleepWindow(bedtimeMinute: bedtimeMinute, wakeMinute: wakeMinute)
        )
    }

    /// The interactive companion hero: the figure, its gestures, its accessibility, and the ambience.
    private func companionHero(emotion: CompanionEmotion?) -> some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 132,
            interactionLevel: companionPetCount,
            equippedItems: store.equippedCustomItems,
            emotion: emotion,
            gentleDay: store.isGentleCompanionDay,
            settled: isCompanionSettled,
            pausesAnimation: !isActive
        )
        .scaleEffect(isCompanionCalmSettling ? 0.98 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            interactWithCompanion()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            // B12: a custom long press gets no press feel from the system, so say it was caught.
            FernletFeedback.system.play(.held)
            isCompanionSheetPresented = true
        }
        // The app's one INTERACTIVE companion, and the only render that names itself (T1-10).
        // `children: .ignore` makes the drawing a single element rather than leaving the outer
        // label hoping to land on something — the figure is `Shape`s and decorative images, so
        // without this there is nothing underneath for a label to attach to.
        .accessibilityElement(children: .ignore)
        // Name in the label, CHANGING STATE in the value: a value is re-announced when it
        // changes while the element is focused, so the mood is heard when it moves rather than
        // only on first landing. Built from the two localized display forks ("Okay, feeling
        // sleepy") — never a `rawValue`, which is a frozen cross-process token.
        .accessibilityLabel("Fernlet companion")
        .accessibilityValue(CompanionEmotion.accessibilityValue(state: store.companionState, emotion: emotion))
        // T2-2: the companion's line is only ever *drawn* inside the photowall strip, which the
        // body drops entirely at accessibility text sizes — and which fades to `opacity(0)` after
        // six seconds even at ordinary ones. Both leave it out of the accessibility tree, so the
        // one piece of the companion that speaks in its own voice was unreachable to a screen
        // reader for most of a session. See ``companionThought`` for the convention.
        .accessibilityCustomContent("Thought", Text(verbatim: companionThought))
        // It is a control, and it was never announced as one; the explicit default action makes
        // the VoiceOver activate gesture pet the companion rather than depend on how SwiftUI
        // maps `onTapGesture`.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { interactWithCompanion() }
        // The old hint promised "Press and hold to edit" — a gesture a VoiceOver user cannot
        // make, since a long press is intercepted by the screen reader. The edit path is a
        // named custom action instead, which is the reachable form of the same affordance.
        .accessibilityAction(named: "Edit your companion") { isCompanionSheetPresented = true }
        .accessibilityHint("Double tap to pet.")
        .accessibilityIdentifier("home.companion")
        // 8, down from 14 (FLOW-18): part of the compacted cold open.
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            // Home-only environment layer (time tint + optional sky accents).
            // Composes beneath the companion; decorative only (no hit testing, no
            // accessibility), so petting and the appearance probes are untouched.
            // Full-bleed per the mockup: the wash feathers its own edges, so let it
            // extend a little past the companion's tight bounds to dissolve into the
            // parchment strip rather than stop at the frame.
            CompanionAmbienceLayer(
                phase: .current(),
                ambient: store.settings.weatherPromptsEnabled ? companionAmbient : nil,
                isActive: isActive
            )
            .padding(.horizontal, -FernletMetrics.spaceMd)
            .padding(.vertical, -FernletMetrics.spaceSm)
        }
    }

    /// The row of companion actions under the hero (HOME-22): Customize is a visible door now —
    /// the 0.45s long-press keeps working, but it is no longer the only one — and Body signals
    /// joins it when stress awareness is on. 3d·AX3: the pair unstacks to full-width rows so
    /// "Customize" is never the thing that truncates to make room for its neighbour.
    @ViewBuilder
    private var companionActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { companionActionChips }
        } else {
            // Tucked into the companion's trailing corner rather than centred beneath it: these
            // are quiet doors (the long-press is still the direct one), and a centred pill sat on
            // the hero's own axis, reading as the thing to press. The negative inset lifts the row
            // beside the companion's lower corner — the pill is narrow and hard right, so it rides
            // the empty margin there rather than the creature.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                companionActionChips
            }
            .padding(.top, -14)
        }
    }

    /// The chips themselves, shared by both `companionActions` layouts. Customize is always
    /// visible; Body signals only when the stress opt-in is on — never a conditionally-empty
    /// container, because Customize is unconditional.
    @ViewBuilder
    private var companionActionChips: some View {
        companionChip(systemImage: "pencil", title: Text("Customize")) {
            isCompanionSheetPresented = true
        }
        .accessibilityIdentifier("home.customize")
        .accessibilityHint("Change how your companion looks")
        if store.settings.stressAwarenessEnabled {
            bodySignalsLink
        }
    }

    /// One compact cream companion-action pill (HOME-22) — the shared chrome that makes Customize
    /// and Body signals read as one row of companion actions.
    ///
    /// The drawn pill is ~30pt tall; the *target* is still 44. The visual capsule is painted around
    /// the padded label, and the 44pt frame plus `contentShape` outside it is what a finger hits —
    /// so quieting the chrome never shrinks the tap area (nor the VoiceOver element).
    private func companionChip(systemImage: String, title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    // .caption2 rather than a fixed size: still scales with Dynamic Type.
                    .font(.caption2)
                title
                    .font(.fernlet(.labelSmall))
            }
            .foregroundStyle(Color.slate)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            .background(Color.cream, in: Capsule())
            .overlay(Capsule().stroke(Color.bark.opacity(0.12), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Quiet door to the body-signals explainer (its App Store 1.4.1 not-medical disclaimer + First Aid
    /// invite). Shown only when stress awareness is on, as one of the companion-action pills beside
    /// Customize (HOME-22), and it stays the sole production entry to `StressExplainerSheet`
    /// (setting the top-level `activeSheet` so the sheet's dismiss-then-First-Aid chain keeps working).
    private var bodySignalsLink: some View {
        companionChip(systemImage: "waveform.path.ecg", title: Text("Body signals")) {
            activeSheet = .stressExplainer
        }
        .accessibilityIdentifier("home.stressLine")
        .accessibilityLabel("Body signals — how Fernlet reads this")
        // Voice Control: the chip's drawn title.
        .accessibilityInputLabels([Text("Body signals")])
        .accessibilityHint("Explains how body signals are estimated")
    }

    /// First Aid as its own calm, standalone action (not a status chip): a soft moss-tinted card whose
    /// header opens the First Aid list, over three chips that go STRAIGHT to the tool they name.
    ///
    /// The chips used to be decorative: they looked like capsule buttons, but tapping "Breathe" only
    /// opened the list, where the user tapped "Slow breathing" again. The direct routes already
    /// existed (`.firstAid(.breathing)` and friends), so each chip is now its own target — the header
    /// row keeps `home.firstAid` and the general entry.
    ///
    /// The whole card is still tappable. Moving the padding/background onto this plain wrapper left
    /// its margin — and the gap between the header and the chips — dead, so a tap that landed a few
    /// points off the header did nothing where it used to open First aid. The container carries its
    /// own `contentShape` + tap gesture; the header and the three chips stay real `Button`s, and
    /// SwiftUI hands a tap inside a button's own frame to that button rather than to the enclosing
    /// gesture, so the container only picks up what would otherwise fall through.
    private var firstAidAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                activeSheet = .firstAid(nil)
            } label: {
                HStack(spacing: 12) {
                    firstAidIcon
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First aid")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        // `bark`, not `slate`: on the card's moss wash slate measured 4.28:1.
                        Text("A quiet minute, whenever")
                            .font(.fernlet(.bodySmall))
                            .italic()
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer()
                    firstAidChevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.firstAid")
            // No `children: .ignore` — it would mint a second, traitless element beside the real
            // Button and the header would stop announcing as one. The explicit label already
            // replaces the title/subtitle/chevron the Button collapsed on its own.
            .accessibilityLabel("First aid")
            .accessibilityHint("Opens calm tools: breathing, grounding, and the worry box")

            FlowLayout(spacing: 8) {
                firstAidChip("wind", "Breathe", tool: .breathing)
                firstAidChip("scope", "Ground", tool: .grounding)
                firstAidChip("archivebox", "Worry box", tool: .worryBox)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: framedLook == nil ? 16 : FernletFramedLook.cardRadius, style: .continuous)
                .fill(framedLook?.sage ?? Color.moss.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: framedLook == nil ? 16 : FernletFramedLook.cardRadius, style: .continuous)
                .strokeBorder(framedLook?.ink ?? Color.moss.opacity(0.22), lineWidth: framedLook == nil ? 1 : FernletFramedLook.frameWidth)
        )
        .background {
            if let framedLook {
                RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
                    .fill(framedLook.shadow).offset(y: 3)
            }
        }
        // Padding included: this is what makes the card's margin and the header-to-chips gap open
        // First aid again. Declared on the padded container, so the chips' and the header's own
        // button frames win their taps first.
        .contentShape(Rectangle())
        .onTapGesture { activeSheet = .firstAid(nil) }
    }

    /// The First Aid card's icon: the pixel first-aid tile in the framed look, the moss symbol otherwise.
    @ViewBuilder
    private var firstAidIcon: some View {
        if let framedLook {
            WorldIconTile(sprite: WorldSprites.aid, look: framedLook)
        } else {
            Image(systemName: "heart.circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 34, height: 34)
                .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    /// The First Aid card's chevron: pixel in the framed look.
    @ViewBuilder
    private var firstAidChevron: some View {
        if let framedLook {
            WorldChevron(look: framedLook)
        } else {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.moss)
        }
    }

    /// One chip inside the First Aid card — its own button straight to `tool`.
    private func firstAidChip(_ icon: String, _ label: LocalizedStringKey, tool: FirstAidTool) -> some View {
        Button {
            activeSheet = .firstAid(tool)
        } label: {
            let chip = HStack(spacing: 5) {
                if let framedLook, let pixel = WorldCardIcons.icon(forSymbol: icon) {
                    WorldSpriteView(sprite: pixel.sprite, scale: 2, tint: pixel.tinted ? framedLook.text : nil)
                } else {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(label).font(.fernlet(.labelSmall))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if let framedLook {
                chip.foregroundStyle(framedLook.text).fernletFramed(framedLook)
            } else {
                chip
                    .foregroundStyle(Color.moss)
                    .background(Color.cream, in: Capsule())
                    .overlay(Capsule().stroke(Color.moss.opacity(0.18), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .fernletTapTarget(minWidth: 0)
        .accessibilityLabel(label)
        // The tool's name is interpolated as a `Text`, not a lower-cased `String`: `LocalizedStringKey`
        // has no `.lowercased()`, and case-folding a translated noun is wrong in German anyway. The
        // key stays "Opens %@ straight away" — one sentence a translator can reorder.
        .accessibilityHint("Opens \(Text(label)) straight away")
    }

    /// The recent photographed meals for the strip — any meal with a photo across the last 7 days, newest
    /// first (so the strip doesn't empty out at midnight the way "today only" did). Today comes from the
    /// observed in-memory `store.day` (so a just-photographed meal shows up immediately); the prior six
    /// rows are read from the repository, but only once per day rollover into `cachedPriorDays` — NOT on
    /// every `body` pass. Reads no photo bytes: the polaroids decode their JPEGs lazily as they scroll in.
    private var recentBites: [RecentBite] {
        RecentBites.recent(from: [store.day] + cachedPriorDays, today: Date())
    }

    /// Load the prior six days' rows into `cachedPriorDays`. These are synchronous single-row repository
    /// fetches; driving them from `.task(id: <today's day key>)` runs them exactly once per day rollover
    /// rather than on every Home render, while today's bites stay live off `store.day` in `recentBites`.
    ///
    /// This can run at wall-clock day T+1 while the store is still on T (the rollover and this `task` fire
    /// on independent triggers, in no guaranteed order), in which case offset-1 asks for T — still the
    /// store's "today", so `loadDay` hands back the in-memory row rather than a repository read. Don't
    /// "fix" that by skipping today's key: this cached copy is what keeps T's photographed meals in the
    /// strip once the store swaps `day` to T+1 (the `task` id is already T+1 by then, so it won't re-run).
    /// The transient duplicate it creates is collapsed by day key in `RecentBites.recent`.
    private func reloadPriorDayRows() {
        let today = Date()
        let calendar = Calendar.current
        cachedPriorDays = (1..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return store.loadDay(for: FernletDate.dayKey(for: date))
        }
    }

    /// "Recent bites" (#11): recently photographed meals as free-floating classic polaroids. A horizontal
    /// strip so the tilt/shadow reads as a scrapbook rather than a cramped list-row thumb; an empty state
    /// keeps the widget from being a blank card before the user has snapped anything. Each polaroid taps
    /// through to a larger viewer.
    private var mealPhotosStrip: some View {
        let bites = recentBites
        let rotations: [Double] = [-3, 2, -1.5, 3, -2.5, 1.5]
        let placeholderColors: [Color] = [
            .fern.opacity(0.45),
            .goldenrod.opacity(0.45),
            .slate.opacity(0.32),
            .dustyRose.opacity(0.38)
        ]
        return FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Recent bites")
                if bites.isEmpty {
                    EmptyState(text: "Snap a photo when you log a meal and it'll show up here as a polaroid.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Lazy so only the polaroids scrolled into view decode their (sealed ~1600px) JPEG,
                        // instead of all six firing on Home render — the transient bitmaps add up on the
                        // iPhone-11 floor. The decode itself is off-main (see MealPhotoPolaroid).
                        LazyHStack(spacing: 20) {
                            ForEach(Array(bites.enumerated()), id: \.element.id) { index, bite in
                                #if canImport(UIKit)
                                // The a11y id lives on the Button (a container's identifier overrides its
                                // children), so the tappable polaroid is what tests find.
                                Button {
                                    selectedBite = bite
                                } label: {
                                    MealPhotoPolaroid(
                                        name: bite.name,
                                        rotation: rotations[index % rotations.count],
                                        loadData: { store.mealPhotoData(for: bite.photoID) },
                                        hasSealedData: { store.mealPhotoHasSealedFile(for: bite.photoID) },
                                        placeholderColor: placeholderColors[index % placeholderColors.count]
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.recentBites.polaroid")
                                #endif
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                    }
                    .accessibilityIdentifier("home.recentBites")
                }
            }
        }
        #if canImport(UIKit)
        .sheet(item: $selectedBite) { bite in
            MealPhotoDetailView(
                name: bite.name,
                loggedAt: bite.loggedAt,
                loadData: { store.mealPhotoData(for: bite.photoID) },
                hasSealedData: { store.mealPhotoHasSealedFile(for: bite.photoID) }
            )
        }
        #endif
        // Keyed on today's day key so the six prior-day fetches run once now and once per midnight
        // rollover — never on every body pass. Today's bites remain live from `store.day`.
        .task(id: FernletDate.dayKey(for: Date())) {
            reloadPriorDayRows()
        }
    }

    /// The opt-in body-signal reading as the companion's emotion input: `.tense` for tense or
    /// needs-care, `.calm` for calm, nil otherwise — and always nil unless the person opted in. The
    /// emotion engine keeps the frazzled and calm faces to thriving and okay days, as the old tint
    /// flags did.
    private var companionBodySignal: CompanionBodySignal? {
        Self.companionBodySignal(enabled: store.settings.stressAwarenessEnabled, assessment: stressService?.assessment)
    }

    /// The body-signal reading as the companion's emotion input, for Home and the World map alike.
    static func companionBodySignal(enabled: Bool, assessment: StressAssessment?) -> CompanionBodySignal? {
        guard enabled, let state = assessment?.state else { return nil }
        switch state {
        case .tense, .needsCare: return .tense
        case .calm: return .calm
        case .okay: return nil
        }
    }

    /// How long the companion stays playful after a pet.
    private static let playfulBeat: TimeInterval = 3 * 60

    /// The next-period outlook for the Home ambient bubble, gated by the same opt-in + hide-predictions.
    private var homePeriodPrediction: CyclePrediction? {
        guard store.settings.periodAwareScoringEnabled, !store.settings.hidePredictions else { return nil }
        return periodStore?.prediction
    }

    /// The companion's own line, shared with the World map's bubble (`companionAmbientThought`).
    private var ambientThought: String {
        store.companionAmbientThought(addressing: termOfAddress)
    }

    /// The rotating tap thoughts, in their fixed order. Computed, because each line is a catalog
    /// lookup; it is read on every third pet, never per render.
    private static var companionTapThoughts: [String] { HomeCopy.tapThoughts }

    /// The 5th-pet moment: Fern is visibly content and settles in for a while.
    private static var companionSettledThought: String { HomeCopy.settledThought }
    /// Shown at most once per settled period when petting continues. Warm, never a
    /// refusal — Fern is settled, not "locked".
    private static var companionSettledLine: String { HomeCopy.settledAgainLine }

    private func interactWithCompanion() {
        guard !isCompanionJumping else { return }
        playfulUntil = Date().addingTimeInterval(Self.playfulBeat)
        let response = petGovernor.registerPet()
        if let cue = Self.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }
        // The first pat ever begins Pats Given, and so earns its stamp.
        store.sillyStats.scheduleRetally(store: store)
        switch response {
        case .bounce:
            performPetBounce(settling: false)
        case .settling:
            performPetBounce(settling: true)
        case .calmIdle(let showsSettledLine):
            performCalmIdle(showsSettledLine: showsSettledLine)
        }
        syncCompanionSettled()
    }

    /// What one pet feels like (report B5), felt with the bounce it answers: `logged` on a playful
    /// bounce, one `pace` as the companion settles, and NOTHING while it is settled. The governor
    /// exists to slow compulsive petting, so its settled period is never rewarded with a tap
    /// (report §3.8, rule 9).
    static func petFeedbackEvent(for response: PetInteractionGovernor.Response) -> FernletFeedbackEvent? {
        switch response {
        case .bounce: .logged
        case .settling: .pace
        case .calmIdle: nil
        }
    }

    /// Mirrors the governor's time-based cooldown into the observable `isCompanionSettled` flag so
    /// the droopy-happy pose appears during the settled window and eases out once it ends. When a
    /// window opens, schedules a single re-sync at its end so the pose fades on its own.
    private func syncCompanionSettled() {
        let settled = petGovernor.isSettled
        withAnimation(.easeInOut(duration: 0.5)) {
            isCompanionSettled = settled
        }
        guard settled else { return }
        // R3: cancel-and-replace, so a settled window holds ONE sleeping re-sync no matter how many
        // times the user pets during it (each pet used to add another 10-minute task).
        settledResyncTask?.cancel()
        settledResyncTask = Task {
            do {
                try await Task.sleep(for: .seconds(petGovernor.settleDuration))
            } catch {
                // Superseded by a later pet (or the view went away): that task owns the re-sync now.
                return
            }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    isCompanionSettled = petGovernor.isSettled
                }
            }
        }
    }

    /// The playful pet response: the two-phase bounce plus either the one-time settled
    /// thought (final pet of the window) or the occasional rotating tap thought.
    private func performPetBounce(settling: Bool) {
        isCompanionJumping = true
        companionTapCount += 1
        let tapID = companionTapCount

        withAnimation(.easeInOut(duration: 0.44)) {
            companionPetCount += 1
        }

        Task {
            do {
                try await Task.sleep(for: .milliseconds(440))
            } catch {
                // Abandoned mid-choreography: reopen the tap gate so a cancelled bounce can't leave
                // the companion permanently un-pettable.
                await MainActor.run {
                    guard companionTapCount == tapID else { return }
                    isCompanionJumping = false
                }
                return
            }
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                withAnimation(.easeInOut(duration: 0.46)) {
                    companionPetCount += 1
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(460))
            } catch {
                await MainActor.run {
                    guard companionTapCount == tapID else { return }
                    isCompanionJumping = false
                }
                return
            }
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                isCompanionJumping = false
            }
        }

        let thought: String? = if settling {
            Self.companionSettledThought
        } else if companionTapCount.isMultiple(of: 3) {
            Self.companionTapThoughts[companionTapCount % Self.companionTapThoughts.count]
        } else {
            nil
        }
        showCompanionTapThought(thought, tapID: tapID)
    }

    /// Petting the already-settled companion: a soft settle-squish instead of a bounce
    /// (content, not asleep), no new thought — except the gentle settled line, once.
    private func performCalmIdle(showsSettledLine: Bool) {
        isCompanionJumping = true
        companionTapCount += 1
        let tapID = companionTapCount

        withAnimation(.easeInOut(duration: 0.5)) {
            isCompanionCalmSettling = true
        }
        Task {
            do {
                try await Task.sleep(for: .milliseconds(520))
            } catch {
                // Never leave the tap gate closed on an abandoned settle-squish.
                await MainActor.run { isCompanionJumping = false }
                return
            }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    isCompanionCalmSettling = false
                }
                isCompanionJumping = false
            }
        }

        showCompanionTapThought(showsSettledLine ? Self.companionSettledLine : nil, tapID: tapID)
    }

    /// Shows (or hides) the tap thought in the shared ThoughtBubble, auto-hiding after 4s.
    private func showCompanionTapThought(_ thought: String?, tapID: Int) {
        companionTapThought = thought
        withAnimation(.easeInOut(duration: 0.22)) {
            isCompanionThoughtVisible = thought != nil
        }

        guard thought != nil else { return }
        // Same notice window as the arrival thought above — the bubble says something worth
        // hearing, and four seconds is a glance, not a swipe-and-read.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(4),
            assistive: FernletDismissalWindow.assistiveNoticeWindow)
        Task {
            do {
                try await Task.sleep(for: window)
            } catch {
                // Cancelled: leave the bubble to whatever superseded this tap.
                return
            }
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                withAnimation(.easeInOut(duration: 0.30)) {
                    isCompanionThoughtVisible = false
                }
                companionTapThought = nil
            }
        }
    }

    private var signalThought: String? {
        Self.signalThought(for: store.derivedSignals)
    }

    /// The signal-driven ambient line, or nil when no signal has one. Static so it is testable (the
    /// `AwayHeartsCopy` precedent: a private view computed cannot be).
    ///
    /// Rest comes first. Marking today unwell forces readiness to `"needs rest"` (spec §6a), and on
    /// that day nothing further down — least of all "room to push" — is the thing to say.
    ///
    /// The comparisons read the FROZEN signal tokens (LocalizationBoundaryTests part D pins them);
    /// the lines are display copy, resolved through ``SignalPresentation``.
    static func signalThought(for signals: [DerivedSignalRecord]) -> String? {
        if signals.first(where: { $0.signalName == "intensityReadiness" })?.value == "needs rest" {
            return SignalPresentation.restDayThought
        }
        if let energy = signals.first(where: { $0.signalName == "energyTrend" }) {
            if energy.value == "low" { return SignalPresentation.energyLowThought }
            if energy.value == "rising" { return SignalPresentation.energyRisingThought }
        }
        if let mood = signals.first(where: { $0.signalName == "moodTrend" }) {
            if mood.value == "needs gentleness" { return SignalPresentation.moodGentlenessThought }
            if mood.value == "improving" { return SignalPresentation.moodImprovingThought }
        }
        if let readiness = signals.first(where: { $0.signalName == "intensityReadiness" }) {
            if readiness.value == "ready for hard" { return SignalPresentation.readyForHardThought }
            if readiness.value == "ready for light" { return SignalPresentation.readyForLightThought }
        }
        if let eating = signals.first(where: { $0.signalName == "eatingPattern" }) {
            if eating.value == "light" { return SignalPresentation.eatingLightThought }
        }
        return nil
    }

    private var todayCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    // HOME-28: the card names itself in DM Serif Display 20 — the one in-card
                    // header treatment.
                    Text("Today")
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    todayGoalLine
                }
                if presentation == .today {
                    todayHearts
                } else {
                    HealthBar(state: store.companionState, value: store.score, heartGlow: store.heartGlow)
                }
                unwellRow
            }
            // FLOW-18: the Today card's inner padding halved (16 → 8), countered at the call site
            // so the shared `FernletCard` keeps its 16pt everywhere else. The framed look keeps its
            // own 14/15 pt: halving it put the title against the frame.
            .padding(framedLook == nil ? -FernletMetrics.spaceSm : 0)
        }
    }

    /// The Today panel's care score (design language): Home's date line, then the status plate's
    /// hearts and the score, spoken as the plate speaks it.
    private var todayHearts: some View {
        let status = WorldStatus.current(store: store, date: Date())
        let large = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: FernletDate.niceDate())
                .font(.fernlet(.bodySmall))
                .foregroundStyle(WorldPalette.dim)
            // The score sits beside the hearts, or under them at accessibility sizes.
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                WorldHeartRow(status: status, count: large ? 4 : 6, scale: WorldTheme.pixel.scale(accessibilitySize: large))
                Text(verbatim: String(localized: "worldToday.careScore", defaultValue: "Care score \(status.carePercent)%",
                                      comment: "World Today panel, Today card: the care score beside its hearts"))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(WorldPalette.dim)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorldStatusPlate.spokenCare(status)))
        .accessibilityIdentifier("world.today.hearts")
    }

    /// The trailing goal line on the Today card. The weekday is already in the page header, and
    /// the bare goal name read as a status word ("Wellness") rather than as the user's chosen goal
    /// — so: one labelled line, no duplication. 3a·AX3 drops the "Goal ·" prefix to keep the name
    /// whole beside the card title.
    @ViewBuilder
    private var todayGoalLine: some View {
        let goal = store.settings.selectedGoal.displayName
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: goal)
            } else {
                Text("Goal · \(goal)")
            }
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        // T2-2: dropping the prefix is a layout decision, but spoken alone the goal name is the very
        // status word this line was rewritten to stop sounding like ("Wellness"). The label keeps the
        // qualifier at every text size; the drawn line is untouched.
        .accessibilityLabel("Goal · \(goal)")
    }

    /// The per-day "I'm unwell today" row under the health bar (SETT-15): a day flag belongs on
    /// the day. Dusty rose, never terracotta — being unwell is not an error — and it states what
    /// it changes in one line. Writes through the day-keyed `setSick`, so it clears itself
    /// tomorrow. 5c·AX3: the explanation line stays (it is what makes the row safe to tap); the
    /// glyph is what gives way.
    private var unwellRow: some View {
        let isUnwell = store.isSick(on: store.todayKey)
        return Button {
            // A choice on a custom control: the tick says it took; the check and the wash show it.
            FernletFeedback.system.play(.tick)
            withAnimation(.easeInOut(duration: 0.18)) {
                store.setSick(!isUnwell, on: store.todayKey)
            }
        } label: {
            HStack(spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize {
                    if framedLook != nil {
                        WorldSpriteView(sprite: WorldSprites.bandage, scale: 2)
                    } else {
                        Image(systemName: isUnwell ? "bandage.fill" : "bandage")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.dustyRose)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("I'm unwell today")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    // Bark, not slate: on the row's dusty-rose wash slate measured 4.22:1 (4.36:1
                    // dark) once the day is flagged. The italic serif keeps it the quieter line.
                    Text("Scoring goes gentle until tomorrow")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
                if isUnwell {
                    if let framedLook {
                        WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: framedLook.text)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dustyRose)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                framedLook?.rose ?? Color.dustyRose.opacity(isUnwell ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if let framedLook {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(framedLook.ink, lineWidth: FernletFramedLook.frameWidth)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        // No `children: .ignore`: on a `Button` it mints a second, traitless element beside the
        // real one, and the label and traits below then describe that phantom rather than the
        // control — so the row read as selected/unselected text with no "button" anywhere in it.
        .accessibilityLabel("I'm unwell today. Scoring goes gentle until tomorrow.")
        // T2-12: two sentences is not something anyone should have to say out loud to tap a row.
        .accessibilityInputLabels([Text("Unwell"), Text("I'm unwell today")])
        .accessibilityAddTraits(isUnwell ? [.isSelected] : [])
        .accessibilityIdentifier("home.unwellToday")
    }

    @ViewBuilder
    private var todayIntentPrompt: some View {
        if shouldShowTodayIntentPrompt {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sun.max")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.goldenrod)
                        .frame(width: 34, height: 34)
                        .background(Color.goldenrod.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today's intent")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text("One small care note is still a real note.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer()
                    Button {
                        store.dismissTodayIntent()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 28, height: 28)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    // The 28pt disc keeps its look; the tap area around it grows to 44pt.
                    .fernletIconButton("Dismiss today's intent")
                }
            }
        }
    }

    private var shouldShowTodayIntentPrompt: Bool {
        Calendar.current.component(.hour, from: Date()) >= 14
            && store.hasNoUserLogsToday
            && !store.isTodayIntentDismissed
    }

    /// The quick-log widget: the tile card plus the mood card. Two self-named cards since the
    /// 2026-08-21 redesign (HOME-28) — the external uppercase "Quick log" section label was the
    /// only one of its kind on Home and is retired.
    private var quickLog: some View {
        VStack(spacing: 16) {
            quickLogCard
            moodCard
        }
    }

    private var quickLogCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick log")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    // On the Headings rotor, so VoiceOver can jump down a long Home to the four
                    // common tasks' starting points instead of swiping through every card above.
                    .accessibilityAddTraits(.isHeader)
                // Not lazy: a lazy grid tore down the tiles that larger text pushed off screen,
                // and the audit read their vanished labels as fonts that ignore Dynamic Type.
                EqualColumnGrid(columns: quickLogColumnCount, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, visibility: store.sensitiveSurfaceVisibility)) { item in
                        quickLogTile(item)
                    }
                }
            }
        }
    }

    /// 3a·AX3: three tiles cannot share the width once the noun is accessibility-sized — the grid
    /// goes 2-up, so four of the six tiles stay visible above the fold.
    private var quickLogColumnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 3
    }

    /// The one-tap mood check-in as its own self-named card (HOME-28): "How today felt", with the
    /// six chips wrapping onto two lines so Tired and Hard are never hidden past the card edge.
    private var moodCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How today felt")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .accessibilityAddTraits(.isHeader)
                // One-tap mood check-in: a tag-only journal entry, no writing required. The card
                // provides the name, so the row's own label stays off.
                QuickMoodRow(store: store, showsLabel: false)
            }
        }
    }

    @ViewBuilder
    private func quickLogTile(_ item: FernletShortcut) -> some View {
        let button = QuickLogButton(
            noun: noun(for: item),
            state: stateText(for: item, short: dynamicTypeSize.isAccessibilitySize),
            accessibilityState: stateText(for: item, short: false),
            spokenSynonym: spokenSynonym(for: item),
            systemImage: item.systemImage,
            active: isActive(item)
        ) {
            handleQuickLog(item)
        }
        if item == .water {
            // One-tap water quick-add: "+1 bottle" without opening the sheet (the tile itself
            // still opens the full water sheet, unchanged).
            button.overlay(alignment: .topTrailing) {
                Button {
                    let before = store.day.bottleCount
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.addBottle()
                    }
                    // A7: the digit roll was the only sign the add landed, and at the cap a tap did
                    // nothing at all. Compared, not assumed: the store clamps at its cap.
                    FernletFeedback.system.play(Self.waterQuickAddEvent(before: before, after: store.day.bottleCount))
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.moss)
                        .background(Color.parchment, in: Circle())
                        // The glyph keeps its drawn size; the 44pt frame around it is the target.
                        // At ~27pt this was the app's fastest daily log sitting under the minimum,
                        // right beside a larger button that does something else (opens the sheet).
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a bottle of water")
                // The count it changes is drawn on the tile beside it, a different element, so
                // without a value of its own a double-tap here was followed by silence. VoiceOver
                // re-reads a focused element's value when it changes.
                .accessibilityValue(waterState(short: false))
                // Voice Control: a bare plus glyph beside the Water tile, so the name has to say
                // which plus — and stay apart from the tile's own "Water".
                .accessibilityInputLabels([Text("Add water"), Text("Add bottle")])
                .accessibilityIdentifier("home.water.quickAdd")
            }
        } else {
            button
        }
    }

    /// The tile's noun line (HOME-09: noun over state, one convention for every tile). The six
    /// core tiles carry authored copy — plural where the mockups say so ("Meals") — while the
    /// optional tool tiles fall back to their frozen-token display title, verbatim as before.
    private func noun(for item: FernletShortcut) -> Text {
        switch item {
        case .meal: Text("Meals")
        case .water: Text("Water")
        case .move: Text("Move")
        case .sleep: Text("Sleep")
        case .journal: Text("Journal")
        case .care: Text("Care")
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .breathing, .grounding, .worryBox:
            Text(verbatim: item.title)
        }
    }

    /// A second Voice Control name for a core tile, after its drawn noun. "Move" is also the tab
    /// bar's name, so on Home "Tap Move" gets numbers; "Log workout" goes straight to the tile, and
    /// the rest follow the same "Log …" form so the six are learnable as one set. Tool tiles keep
    /// their drawn title alone.
    private func spokenSynonym(for item: FernletShortcut) -> Text? {
        switch item {
        case .meal: Text("Log meal")
        case .water: Text("Log water")
        case .move: Text("Log workout")
        case .sleep: Text("Log sleep")
        case .journal: Text("Log journal")
        case .care: Text("Log care")
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .breathing, .grounding, .worryBox:
            nil
        }
    }

    /// The tile's state line (HOME-09): a count with its unit ("3 logged", "6 bottles", "2 of 3")
    /// or "none yet" — "3 meal", "6x", bare "Done" and bare "Logged" are all retired. `short` is
    /// the 3a·AX3 form: the bare figure once the text is too large to share a tile with its unit
    /// word. Tool tiles (breathing, grounding, …) have no daily count and return nil.
    private func stateText(for item: FernletShortcut, short: Bool) -> Text? {
        switch item {
        case .meal: countedState(store.day.meals.count, short: short, phrase: HomeCopy.mealsLogged)
        case .water: waterState(short: short)
        case .move: countedState(store.day.workouts.count, short: short, phrase: HomeCopy.workoutsLogged)
        case .sleep: sleepState(short: short)
        case .journal: journalState(short: short)
        case .care: careState(short: short)
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .breathing, .grounding, .worryBox:
            nil
        }
    }

    /// "N logged" — the Meals and Move tiles' shape. Each tile hands in its own plural-ruled phrase
    /// (`HomeCopy`): the words read the same in English, but a translation agrees the participle with
    /// meals on one tile and workouts on the other.
    private func countedState(_ count: Int, short: Bool, phrase: (Int) -> String) -> Text {
        if count == 0 { return Text("none yet") }
        return short ? Text(verbatim: "\(count)") : Text(verbatim: phrase(count))
    }

    /// What Home's one-tap "+1 bottle" feels like: `logged` when the count went up, `limit` when it
    /// could not (the store holds the day at 30). Never a goal cue: reaching the water target feels
    /// like any other bottle (the report's "never" list).
    static func waterQuickAddEvent(before: Int, after: Int) -> FernletFeedbackEvent {
        after > before ? .logged : .limit
    }

    private func waterState(short: Bool) -> Text {
        let count = store.day.bottleCount
        if count == 0 { return Text("none yet") }
        if short { return Text(verbatim: "\(count)") }
        return Text(verbatim: HomeCopy.waterBottles(count))
    }

    /// "7h 20m" from the logged hours; a rare hours-less log states "logged" rather than a figure.
    private func sleepState(short: Bool) -> Text {
        guard let sleep = store.day.sleep else { return Text("none yet") }
        guard let hours = sleep.hours else { return Text("logged") }
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if short || minutes == 0 { return Text("\(wholeHours)h") }
        return Text("\(wholeHours)h \(minutes)m")
    }

    private func journalState(short: Bool) -> Text {
        let count = store.day.journals.count
        if count == 0 { return Text("none yet") }
        if short { return Text(verbatim: "\(count)") }
        return Text(verbatim: HomeCopy.journalEntries(count))
    }

    private func careState(short: Bool) -> Text {
        let progress = store.personalCareProgress()
        if progress.completed == 0 { return Text("none yet") }
        if short { return Text(verbatim: "\(progress.completed)/\(progress.total)") }
        return Text("\(progress.completed) of \(progress.total)")
    }

    private func isActive(_ item: FernletShortcut) -> Bool {
        switch item {
        case .meal:
            !store.day.meals.isEmpty
        case .water:
            store.day.bottleCount > 0
        case .move:
            !store.day.workouts.isEmpty
        case .sleep:
            store.day.sleep != nil
        case .journal:
            !store.day.journals.isEmpty
        case .care:
            store.personalCareProgress().completed > 0
        case .logPeriod:
            hasRecentPeriodEvent
        case .periodTracking:
            store.day.healthContext?.cycle != nil
        case .intimacyTracking:
            store.day.healthContext?.intimate != nil
        case .friends:
            store.memories.contains { $0.category.localizedCaseInsensitiveContains("friend") }
        case .breathing, .grounding, .worryBox:
            false
        }
    }

    private func handleHomeWidget(_ widget: HomeWidget) {
        switch widget {
        case .logFood:
            activeSheet = .meal
        case .recipeBook:
            activeSheet = .recipeBook
        case .newRecipe:
            activeSheet = .recipe
        case .workout:
            activeSheet = .workout
        case .journal:
            activeSheet = .journal
        case .sleep:
            activeSheet = .sleep
        case .water:
            activeSheet = .water
        case .hygiene:
            activeSheet = .hygiene
        case .trends:
            activeSheet = .trends
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos, .sillyStats:
            break
        }
    }

    private func handleQuickLog(_ item: FernletShortcut) {
        switch item {
        case .meal:
            activeSheet = .meal
        case .water:
            activeSheet = .water
        case .move:
            // HOME-10: the Move tile presents the Move tab's own Log workout sheet (kind chips
            // first, walks and rides two taps from Home) instead of the strength-only picker.
            activeSheet = .workout
        case .sleep:
            activeSheet = .sleep
        case .journal:
            activeSheet = .journal
        case .care:
            activeSheet = .hygiene
        case .logPeriod:
            activeSheet = .logPeriod(targetDate: nil, editingRecord: nil)
        case .periodTracking:
            privateHubSection = .cycle
            selectedTab = .personal
        case .intimacyTracking:
            guard store.isIntimateLoggingAllowed else { return }
            privateHubSection = .cycle
            selectedTab = .personal
        case .friends:
            selectedTab = .social
        case .breathing:
            activeSheet = .firstAid(.breathing)
        case .grounding:
            activeSheet = .firstAid(.grounding)
        case .worryBox:
            activeSheet = .firstAid(.worryBox)
        }
    }

    /// Cancel-and-replace trigger for ``refreshRecentPeriodActivity()``.
    ///
    /// Without the single handle, every sheet dismissal and every visibility flip spawned its own
    /// 30-day HealthKit query and the answers landed in COMPLETION order: hiding cycle tracking mid
    /// query set the flag false, then the older query re-latched it true.
    private func scheduleRecentPeriodActivityRefresh() {
        periodActivityTask?.cancel()
        periodActivityTask = Task { await refreshRecentPeriodActivity() }
    }

    private func refreshRecentPeriodActivity() async {
        // Routed through `allowedHealthCapabilities` rather than re-testing the flags by hand, so this
        // inherits BOTH the visibility gate and the existing lock rule from the one place that defines
        // them. Assigns rather than bails so hiding mid-session drops the resident answer to "has this
        // user bled in the last month" instead of leaving it latched.
        guard store.allowedHealthCapabilities(from: [.cycleTracking]).contains(.cycleTracking),
              healthKitService.isCapabilityRequestedAndEnabled(.cycleTracking) else {
            hasRecentPeriodEvent = false
            return
        }
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
        let range = DateInterval(start: start, end: Date())
        let samples = (try? await healthKitService.loadPeriodEvents(in: range)) ?? []
        // Re-check after the await: this task may have been superseded, or the user may have hidden
        // cycle tracking while the query was suspended. A late answer must never re-latch a flag a
        // newer trigger already cleared.
        guard !Task.isCancelled else { return }
        guard store.allowedHealthCapabilities(from: [.cycleTracking]).contains(.cycleTracking),
              healthKitService.isCapabilityRequestedAndEnabled(.cycleTracking) else {
            hasRecentPeriodEvent = false
            return
        }
        hasRecentPeriodEvent = samples.contains { sample in
            (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
        }
    }
}

/// One derived signal expanded for the Trends modal: icon, title, value, explanation, a
/// ``SignalTrendMeter``, the source-field chips, and any nutrient-gap rows.
///
/// All presentation choices (title/icon/color/strength/explanation) come from
/// ``SignalPresentation`` so the row stays a dumb renderer of `DerivedSignalRecord`.
struct SignalDetailRow: View {
    /// The user's term of address, which the readiness values agree with.
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    var signal: DerivedSignalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Decorative — `SignalPresentation.title(for:)` below names the signal. Unhidden it
                // announces the raw SF Symbol name ("face smiling" for the mood trend).
                Image(systemName: SignalPresentation.icon(for: signal.signalName))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(SignalPresentation.color(for: signal.value))
                    .frame(width: 34, height: 34)
                    .background(SignalPresentation.color(for: signal.value).opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(SignalPresentation.title(for: signal.signalName))
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(SignalPresentation.valueLabel(for: signal.value, addressing: termOfAddress))
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(SignalPresentation.color(for: signal.value))
                    Text(SignalPresentation.explanation(for: signal))
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer()
            }

            SignalTrendMeter(value: signal.value)

            FlowLayout(spacing: 6) {
                ForEach(signal.sourceFields, id: \.self) { field in
                    // The engine's raw keys ("journals.tag", "meals.calorieSnapshot") leaked
                    // straight onto the card; these are what the user actually logged.
                    Text(SignalPresentation.sourceLabel(for: field))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.bark.opacity(0.05), in: Capsule())
                }
            }

            if signal.nutrientGaps.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(signal.nutrientGaps.prefix(4)) { gap in
                        HStack {
                            Text(gap.displayedName)
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.bark)
                            Spacer()
                            Text(SignalPresentation.nutrientStatusLabel(gap.status))
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(gap.status == .gap ? Color.terracotta : Color.moss)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}

/// A five-segment strength meter for a signal value string.
///
/// Fill count and color both derive from ``SignalPresentation``, so the meter reads the same
/// literals the signal engine emits.
struct SignalTrendMeter: View {
    var value: String

    private var fillCount: Int {
        SignalPresentation.strength(for: value)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < fillCount ? SignalPresentation.color(for: value) : Color.bark.opacity(0.10))
                    .frame(height: 7)
            }
        }
    }
}

/// Presentation lookup for derived signals: maps the engine's raw `signalName`/value literals to
/// display titles, icons, tint colors, meter strength, and plain-language explanations.
///
/// Pure string matching against the exact literals `DerivedSignalsService` emits — shared by
/// ``SignalDetailRow`` and ``SignalTrendMeter`` so every trends surface styles a signal the same
/// way.
///
/// **The display half of the derived-signal fork.** A signal's `signalName` and `value` are FROZEN
/// English logic tokens (LocalizationBoundaryTests part D: six `==` gates and the AI compare them),
/// so they are never localized and never rewritten. Everything a person reads is mapped here, by
/// exact match on the token, to a catalog key: the titles, the values, the source chips, the
/// explanations and Home's signal-driven thoughts. The tint and meter heuristics
/// (``color(for:)``, ``strength(for:)``) deliberately keep reading the raw token.
enum SignalPresentation {
    /// Display title for a raw signal name (falls back to the raw name for unknown signals).
    static func title(for name: String) -> String {
        switch name {
        case "moodTrend":
            String(localized: "signal.title.moodTrend", defaultValue: "Mood trend",
                   comment: "Trends: title of the signal comparing recent journal moods with earlier ones.")
        case "energyTrend":
            String(localized: "signal.title.energyTrend", defaultValue: "Energy trend",
                   comment: "Trends: title of the signal built from sleep, journal moods and recent workout load.")
        case "eatingPattern":
            String(localized: "signal.title.eatingPattern", defaultValue: "Eating pattern",
                   comment: "Trends: title of the signal about how often and how much the user has been eating.")
        case "progressionTrend":
            String(localized: "signal.title.progressionTrend", defaultValue: "Progression",
                   comment: "Trends: title of the signal comparing newer workout load with earlier workout load.")
        case "intensityReadiness":
            String(localized: "signal.title.intensityReadiness", defaultValue: "Readiness",
                   comment: "Trends: title of the signal saying how hard a workout today could reasonably be.")
        case "micronutrientGaps7Day":
            String(localized: "signal.title.micronutrients7Day", defaultValue: "7-day nutrients",
                   comment: "Trends: title of the vitamin and mineral coverage signal over the last 7 days.")
        case "micronutrientGaps14Day":
            String(localized: "signal.title.micronutrients14Day", defaultValue: "14-day nutrients",
                   comment: "Trends: title of the vitamin and mineral coverage signal over the last 14 days.")
        default: name
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "moodTrend": "face.smiling"
        case "energyTrend": "bolt"
        case "eatingPattern": "fork.knife"
        case "progressionTrend": "chart.line.uptrend.xyaxis"
        case "intensityReadiness": "gauge.with.dots.needle.67percent"
        default: "leaf"
        }
    }

    /// The display label for a signal's value.
    ///
    /// The value is a FROZEN logic token (`DerivedSignalFactory`); this is the separate display half.
    /// Every token the factory can mint maps to a catalog key by exact match, the two counted ones
    /// ("2 possible gaps", "5 covered") through plural-ruled keys, so a translation never has to
    /// touch the token that `FernletStore.needsRestToday`, Home, the gentle offer and the Move tab
    /// compare against. The English values are the Title Case the card always drew (it used to apply
    /// `.capitalized` to the token, which no translation could survive); a token this table does not
    /// know is drawn as it is. `address` is the user's term of address: the readiness values say
    /// the USER is ready (*Lista para algo ligero*), so those agree with them.
    static func valueLabel(for value: String, addressing address: TermOfAddress) -> String {
        stateValueLabel(for: value, addressing: address) ?? countedValueLabel(for: value) ?? value
    }

    /// The display label for a mood, energy or progression token, or nil for any other token.
    private static func stateValueLabel(for value: String, addressing address: TermOfAddress) -> String? {
        switch value {
        case "insufficient data":
            String(localized: "signal.value.insufficientData", defaultValue: "Insufficient Data",
                   comment: "Trends: a signal's value while there are too few logs to read it yet. Title case, like the other signal values.")
        case "needs gentleness":
            String(localized: "signal.value.needsGentleness", defaultValue: "Needs Gentleness",
                   comment: "Trends, Mood trend's value: recent journal moods have been harder. Gentle, never alarming. Title case.")
        case "improving":
            String(localized: "signal.value.improving", defaultValue: "Improving",
                   comment: "Trends, Mood trend's value: recent journal moods are brighter than earlier ones. Title case.")
        case "declining":
            String(localized: "signal.value.declining", defaultValue: "Declining",
                   comment: "Trends, Mood trend's value: recent journal moods are a little lower than earlier ones. Title case.")
        case "steady":
            String(localized: "signal.value.steady", defaultValue: "Steady",
                   comment: "Trends: the value of the Mood trend, Energy trend or Progression signal when nothing has clearly changed. Title case.")
        case "low":
            String(localized: "signal.value.low", defaultValue: "Low",
                   comment: "Trends, Energy trend's value: energy has been low lately. Title case.")
        case "rising":
            String(localized: "signal.value.rising", defaultValue: "Rising",
                   comment: "Trends, Energy trend's value: energy has been building. Title case.")
        case "dipping":
            String(localized: "signal.value.dipping", defaultValue: "Dipping",
                   comment: "Trends, Energy trend's value: energy has dipped a little. Title case.")
        case "building":
            String(localized: "signal.value.building", defaultValue: "Building",
                   comment: "Trends, Progression's value: workout load has been building. Title case.")
        case "deloading":
            String(localized: "signal.value.deloading", defaultValue: "Deloading",
                   comment: "Trends, Progression's value: workout load has eased off (a deload, a lighter stretch of training). Title case.")
        default:
            eatingOrReadinessValueLabel(for: value, addressing: address)
        }
    }

    /// The display label for an eating-pattern or readiness token, or nil for any other token. The
    /// three "ready for" values describe the user and agree with `address`.
    private static func eatingOrReadinessValueLabel(for value: String, addressing address: TermOfAddress) -> String? {
        switch value {
        case "light":
            String(localized: "signal.value.light", defaultValue: "Light",
                   comment: "Trends, Eating pattern's value: the user has been eating lighter than usual. Title case.")
        case "protein-forward":
            String(localized: "signal.value.proteinForward", defaultValue: "Protein-Forward",
                   comment: "Trends, Eating pattern's value: meals have leaned on protein. Title case.")
        case "inconsistent":
            String(localized: "signal.value.inconsistent", defaultValue: "Inconsistent",
                   comment: "Trends, Eating pattern's value: meals have been irregular, with some missed days. Neutral, never a judgement. Title case.")
        case "consistent":
            String(localized: "signal.value.consistent", defaultValue: "Consistent",
                   comment: "Trends, Eating pattern's value: meals have been regular. Title case.")
        case "needs rest":
            String(localized: "signal.value.needsRest", defaultValue: "Needs Rest",
                   comment: "Trends: the readiness value on a day the user marked themselves unwell. Title case, like the other signal values beside it.")
        case "ready for light":
            AddressedCopy.string(LocalizedStringResource("signal.value.readyForLight", defaultValue: "Ready For Light",
                                                         comment: "Trends, Readiness's value: today suits a light workout. Title case."),
                                 addressing: address)
        case "ready for moderate":
            AddressedCopy.string(LocalizedStringResource("signal.value.readyForModerate", defaultValue: "Ready For Moderate",
                                                         comment: "Trends, Readiness's value: today suits a moderate workout. Title case."),
                                 addressing: address)
        case "ready for hard":
            AddressedCopy.string(LocalizedStringResource("signal.value.readyForHard", defaultValue: "Ready For Hard",
                                                         comment: "Trends, Readiness's value: today could take a hard workout, if the user wants one. Title case."),
                                 addressing: address)
        default:
            nil
        }
    }

    /// The display label for a micronutrient signal's counted value — the factory writes
    /// `"\(n) possible gap(s)"` and `"\(n) covered"`, with an English plural inside the token — or nil
    /// for any other value.
    private static func countedValueLabel(for value: String) -> String? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[0]), count >= 0 else { return nil }
        switch parts[1] {
        case "possible gap", "possible gaps":
            return String(localized: "signal.value.possibleGaps", defaultValue: "\(count) Possible Gaps",
                          comment: "Trends, a nutrients signal's value: how many vitamins or minerals look low in recent meals. Needs a plural variation per language; English says '1 Possible Gap'. Title case.")
        case "covered":
            return String(localized: "signal.value.covered", defaultValue: "\(count) Covered",
                          comment: "Trends, a nutrients signal's value: how many vitamins and minerals recent meals cover well. Needs a plural variation per language. Title case.")
        default:
            return nil
        }
    }

    /// A nutrient row's status word under a nutrients signal: "gap" or "covered".
    static func nutrientStatusLabel(_ status: NutrientGapStatus) -> String {
        switch status {
        case .gap:
            String(localized: "signal.nutrient.gap", defaultValue: "gap",
                   comment: "Trends, beside a vitamin or mineral's name: recent meals look low in it. Lowercase status word.")
        case .covered:
            String(localized: "signal.nutrient.covered", defaultValue: "covered",
                   comment: "Trends, beside a vitamin or mineral's name: recent meals cover it well. Lowercase status word.")
        }
    }

    /// Home's ambient line on a rest day — readiness `"needs rest"`, which marking today unwell
    /// forces (spec §6a). Shared by `HomeView.signalThought(for:)` and the launch-time deterministic
    /// companion thought, so the two can never disagree about what an unwell day hears.
    static var restDayThought: String {
        String(localized: "signal.thought.restDay",
               defaultValue: "Today is for resting. Being unwell is reason enough to go slow.",
               comment: "Home companion thought on a day the user marked themselves unwell. Gentle; never suggests exercise.")
    }

    /// Home's line when energy has been low (`energyTrend` "low").
    static var energyLowThought: String {
        String(localized: "signal.thought.energyLow", defaultValue: "Energy has been low lately. Rest counts as care.",
               comment: "Home companion thought when recent energy has been low. Gentle; rest is care, never a failure.")
    }

    /// Home's line when energy has been rising (`energyTrend` "rising").
    static var energyRisingThought: String {
        String(localized: "signal.thought.energyRising", defaultValue: "Something has been building. Notice the upward pull.",
               comment: "Home companion thought when recent energy has been rising.")
    }

    /// Home's line on a run of harder days (`moodTrend` "needs gentleness").
    static var moodGentlenessThought: String {
        String(localized: "signal.thought.moodGentleness", defaultValue: "Some harder days in the window. Notice what is still steady.",
               comment: "Home companion thought after several harder journal moods in recent days. Gentle, never alarming.")
    }

    /// Home's line when the mood trend is improving (`moodTrend` "improving").
    static var moodImprovingThought: String {
        String(localized: "signal.thought.moodImproving", defaultValue: "The mood trend has been moving upward. Quiet progress.",
               comment: "Home companion thought when recent journal moods have been brighter.")
    }

    /// Home's line when readiness allows a hard session (`intensityReadiness` "ready for hard").
    static var readyForHardThought: String {
        String(localized: "signal.thought.readyForHard", defaultValue: "The signals suggest room to push today if you want to.",
               comment: "Home companion thought when today could take a hard workout. An option, never an instruction.")
    }

    /// Home's line when readiness suggests going light (`intensityReadiness` "ready for light").
    static var readyForLightThought: String {
        String(localized: "signal.thought.readyForLight", defaultValue: "Today looks like a day to move gently and restore.",
               comment: "Home companion thought when today suits only light movement.")
    }

    /// Home's line when eating has been lighter (`eatingPattern` "light").
    static var eatingLightThought: String {
        String(localized: "signal.thought.eatingLight", defaultValue: "Nutrition has been lighter lately. One nourishing meal is enough.",
               comment: "Home companion thought when recent meals have been lighter than usual. Gentle; never mentions weight or calories.")
    }

    static func color(for value: String) -> Color {
        let lower = value.lowercased()
        // A rest day reads in calm slate, never the terracotta of "low"/"light": being unwell is not
        // an error or a low score. (Not the unwell row's dusty rose either — that measures ~3.3:1 as
        // small text on parchment; slate holds 4.5:1.)
        if lower == "needs rest" { return .slate }
        if lower.contains("low") || lower.contains("light") || lower.contains("declining") || lower.contains("dipping") || lower.contains("gap") || lower.contains("gentleness") {
            return .terracotta
        }
        if lower.contains("building") || lower.contains("improving") || lower.contains("rising") || lower.contains("hard") || lower.contains("covered") || lower.contains("protein") {
            return .moss
        }
        return .slate
    }

    static func strength(for value: String) -> Int {
        let lower = value.lowercased()
        if lower.contains("insufficient") || lower == "needs rest" { return 1 }
        if lower.contains("low") || lower.contains("light") || lower.contains("gentleness") { return 2 }
        if lower.contains("steady") || lower.contains("consistent") || lower.contains("moderate") { return 3 }
        if lower.contains("building") || lower.contains("improving") || lower.contains("rising") || lower.contains("hard") || lower.contains("protein") { return 5 }
        return 3
    }

    /// Plain-language name for a raw `sourceFields` key. Unknown keys fall back to the key with its
    /// dots opened out, so a signal added later degrades to readable text rather than to code.
    static func sourceLabel(for field: String) -> String {
        switch field {
        case "journals.tag":
            String(localized: "signal.source.journalMoods", defaultValue: "Journal moods",
                   comment: "Trends: a source chip under a signal, naming what it was worked out from — the moods tagged on journal entries.")
        case "sleep", "sleep.hours", "sleep.quality":
            sleepSourceLabel(for: field)
        case "meals.count", "meals.macros", "meals.calorieSnapshot", "meals.micronutrientSnapshot":
            mealSourceLabel(for: field)
        case "workouts.intensity", "workouts.duration", "workouts.rpe":
            workoutSourceLabel(for: field)
        case "body.restingHeartRate":
            String(localized: "signal.source.restingHeartRate", defaultValue: "Resting heart rate",
                   comment: "Trends: a source chip under a signal — resting heart rate read from Apple Health.")
        case "body.heartRateVariability":
            String(localized: "signal.source.heartRateVariability", defaultValue: "Heart rate variability",
                   comment: "Trends: a source chip under a signal — heart rate variability read from Apple Health.")
        case "sickness":
            String(localized: "signal.source.sickness", defaultValue: "Marked unwell",
                   comment: "Trends: the source chip under Readiness on a day the user marked themselves unwell.")
        default: field.replacingOccurrences(of: ".", with: " ")
        }
    }

    /// The source chip for a sleep field.
    private static func sleepSourceLabel(for field: String) -> String {
        switch field {
        case "sleep.hours":
            String(localized: "signal.source.sleepHours", defaultValue: "Sleep hours",
                   comment: "Trends: a source chip under a signal — the hours of sleep the user logged.")
        case "sleep.quality":
            String(localized: "signal.source.sleepQuality", defaultValue: "Sleep quality",
                   comment: "Trends: a source chip under a signal — how well the user said they slept.")
        default:
            String(localized: "signal.source.sleep", defaultValue: "Sleep",
                   comment: "Trends: a source chip under a signal — the user's logged sleep.")
        }
    }

    /// The source chip for a meal field.
    private static func mealSourceLabel(for field: String) -> String {
        switch field {
        case "meals.macros":
            String(localized: "signal.source.mealMacros", defaultValue: "Meal macros",
                   comment: "Trends: a source chip under a signal — the protein, carbs and fat of logged meals.")
        case "meals.calorieSnapshot":
            String(localized: "signal.source.mealEnergy", defaultValue: "Meal energy",
                   comment: "Trends: a source chip under a signal — the calories of logged meals, worded as energy.")
        case "meals.micronutrientSnapshot":
            String(localized: "signal.source.mealNutrients", defaultValue: "Meal nutrients",
                   comment: "Trends: a source chip under a signal — the vitamins and minerals of logged meals.")
        default:
            String(localized: "signal.source.mealCount", defaultValue: "Meal count",
                   comment: "Trends: a source chip under a signal — how many meals were logged.")
        }
    }

    /// The source chip for a workout field.
    private static func workoutSourceLabel(for field: String) -> String {
        switch field {
        case "workouts.duration":
            String(localized: "signal.source.workoutLength", defaultValue: "Workout length",
                   comment: "Trends: a source chip under a signal — how long logged workouts lasted.")
        case "workouts.rpe":
            String(localized: "signal.source.perceivedEffort", defaultValue: "Perceived effort",
                   comment: "Trends: a source chip under a signal — how hard the user said a workout felt.")
        default:
            String(localized: "signal.source.workoutIntensity", defaultValue: "Workout intensity",
                   comment: "Trends: a source chip under a signal — the intensity of logged workouts.")
        }
    }

    static func explanation(for signal: DerivedSignalRecord) -> String {
        switch signal.signalName {
        case "moodTrend":
            return String(localized: "signal.explanation.moodTrend",
                          defaultValue: "Compares recent journal tags against earlier tags in the rolling window.",
                          comment: "Trends: how the Mood trend signal is worked out. Tags are the moods on journal entries.")
        case "energyTrend":
            return String(localized: "signal.explanation.energyTrend",
                          defaultValue: "Combines sleep, journal tags, and recent workout load.",
                          comment: "Trends: how the Energy trend signal is worked out.")
        case "eatingPattern":
            return String(localized: "signal.explanation.eatingPattern",
                          defaultValue: "Looks at meal frequency, recent missed meal days, and protein totals.",
                          comment: "Trends: how the Eating pattern signal is worked out.")
        case "progressionTrend":
            return String(localized: "signal.explanation.progressionTrend",
                          defaultValue: "Compares newer workout load against earlier workout load.",
                          comment: "Trends: how the Progression signal is worked out.")
        case "intensityReadiness" where signal.value == "needs rest":
            return String(localized: "signal.explanation.needsRest",
                          defaultValue: "You marked today as unwell, so readiness rests until tomorrow.",
                          comment: "Trends: why Readiness reads Needs Rest. The unwell mark clears itself at midnight.")
        case "intensityReadiness":
            return String(localized: "signal.explanation.intensityReadiness",
                          defaultValue: "Blends recent energy, training load, hard sessions, and meal coverage.",
                          comment: "Trends: how the Readiness signal is worked out.")
        default:
            return nutrientsExplanation(hasGaps: !signal.nutrientGaps.isEmpty)
        }
    }

    /// How a nutrients signal is worked out, or why it cannot be yet.
    private static func nutrientsExplanation(hasGaps: Bool) -> String {
        guard hasGaps else {
            return String(localized: "signal.explanation.nutrientsNeedData",
                          defaultValue: "Micronutrient coverage needs more meal data.",
                          comment: "Trends: a nutrients signal with too few logged meal details to read yet.")
        }
        return String(localized: "signal.explanation.nutrients",
                      defaultValue: "Tracks covered nutrients and possible gaps from logged meal snapshots.",
                      comment: "Trends: how a nutrients signal is worked out, from the vitamin and mineral details saved with each logged meal.")
    }
}

/// The Trends sheet (`FernletSheet.trends`): every current derived signal as a
/// ``SignalDetailRow``, with an empty-state invitation when there isn't enough logged data.
///
/// Read-only over the signals the store already computed — presenting it never triggers a
/// recompute. Read-only means Done top-right is the whole exit under the 2026-08-21 sheet
/// template: the pinned ``SheetHeader`` carries the title and Done, and there is no bottom bar
/// (the 36pt `ScreenHeader` treatment belongs to tab roots, never sheets).
struct TrendsModal: View {
    @Environment(\.dismiss) private var dismiss
    var signals: [DerivedSignalRecord]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Trends",
                // Was "Prototype only — not production-private": developer copy, shown to
                // users, contradicting the privacy promise the screen is actually keeping.
                subtitle: "Local signals from your logs — worked out on this device.",
                onDone: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if signals.isEmpty {
                        FernletCard { EmptyState(text: "More logs will make trends useful.") }
                    } else {
                        ForEach(signals) { signal in
                            SignalDetailRow(signal: signal)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
    }
}

// FernletCard / SectionLabel / EmptyState moved to FernletUI (FernletPrimitives.swift).

/// The companion's speech bubble: a rounded cream capsule for the ambient/tap thought text.
///
/// Rendered over the photowall strip on Home; the text itself comes from the store's companion
/// thought (AI or deterministic fallback) or a tap reaction.
struct ThoughtBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.bark)
            .multilineTextAlignment(.center)
            // Three lines, then shrink — rather than one line clipped to "Keep t…" the moment the
            // text size grows past the strip's height.
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(maxWidth: 290)
    }
}

/// The twelve-segment care-score bar under the companion, tinted by companion state.
///
/// `value` is the 0–1 wellness score; an optional `heartGlow` appends the golden 24-hour
/// afterglow cap when a friend sent a heart — presentation only, never an input to the score.
/// At accessibility text sizes the bar coarsens to four segments (5c·AX3) — twelve slivers
/// beside 40pt text read as texture, not a value — while VoiceOver keeps the exact percentage.
struct HealthBar: View {
    var state: CompanionState
    var value: Double
    /// Presentation-only warmth from a friend's heart, 0–1, decaying linearly over 24h from
    /// receipt (`HeartGlowMath`). Renders a soft golden cap at the end of the bar — additive,
    /// never numeric, and never an input to the score itself.
    var heartGlow: Double = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 5c·AX3: four segments instead of twelve at accessibility sizes.
    private var segmentCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 12
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < Int((value * Double(segmentCount)).rounded()) ? state.color : Color.bark.opacity(0.12))
                    .frame(height: 8)
            }
            if heartGlow > 0 {
                heartGlowCap
            }
        }
        // The bar draws 8pt tall; the element that names it is 44pt, an invisible overlay centred
        // on it, so finding the score by touch does not mean hitting an 8pt strip. An overlay does
        // not take part in layout, so the card around the bar is unchanged.
        .accessibilityHidden(true)
        .overlay {
            Color.clear
                .frame(height: 44)
                .accessibilityElement()
                .accessibilityLabel(
                    heartGlow > 0
                        ? "Care score \(Int(value * 100)) percent, with a little warmth from a friend"
                        : "Care score \(Int(value * 100)) percent"
                )
        }
    }

    /// The 24h "afterglow" at the end of the bar (good-vibes 10b): two goldenrod/sun heart-bonus
    /// segments wrapped in a soft golden radial glow whose reach and opacity scale with `heartGlow`
    /// (1 just-received → 0 after a day). No number, no earned segment — just warmth that fades.
    private var heartGlowCap: some View {
        let glow = min(max(heartGlow, 0), 1)
        return HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.goldenrod)
                .frame(width: 8, height: 8)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.sun)
                .frame(width: 8, height: 8)
        }
        .padding(.leading, 3)
        .background {
            // Soft radial afterglow — brighter and wider fresh, nearly gone near 24h.
            RadialGradient(
                colors: [Color.sun.opacity(0.15 + 0.55 * glow), Color.sun.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 12 + 8 * glow
            )
            .blur(radius: 2)
            .allowsHitTesting(false)
        }
        .shadow(color: Color.goldenrod.opacity(0.75 * glow), radius: 2 + 3 * glow)
    }
}

/// A plain tappable action row on the Home feed for the simple `HomeWidget` cases (log food,
/// recipe book, workout, journal, sleep, water, hygiene, trends).
///
/// The richer widget cases render bespoke sections in ``HomeView`` instead and return an empty
/// subtitle here.
struct HomeActionWidget: View {
    var widget: HomeWidget
    var action: () -> Void
    /// The World Today panel's framed look, when it is set (pixel icon tile and chevron).
    @Environment(\.fernletFramedLook) private var look

    /// The card's icon: a pixel tile in the framed look, the moss symbol otherwise.
    @ViewBuilder
    private var icon: some View {
        if let look, let pixel = WorldCardIcons.icon(for: widget) {
            WorldIconTile(sprite: pixel.sprite, tinted: pixel.tinted, look: look)
        } else {
            Image(systemName: widget.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 36, height: 36)
                .background(Color.moss.opacity(0.12), in: Circle())
        }
    }

    var body: some View {
        Button(action: action) {
            FernletCard {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 3) {
                        Text(widget.title)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(look?.text ?? Color.bark)
                        actionSubtitle
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(look == nil ? Color.slate : WorldPalette.dim)
                            .fernletWrappingText()
                    }
                    Spacer()
                    if let look {
                        WorldChevron(look: look)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.slate)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The row's one-line subtitle. A `Text` from `LocalizedStringKey` literals, so each is a catalog
    /// key: as a `String` property every subtitle reached `Text`'s verbatim initializer and was never
    /// harvested.
    private var actionSubtitle: Text {
        switch widget {
        case .logFood: Text("Add food to today.")
        case .recipeBook: Text("Open saved recipes.")
        case .newRecipe: Text("Build a recipe.")
        case .workout: Text("Log training or movement.")
        case .journal: Text("Add a short note.")
        case .sleep: Text("Log rest.")
        case .water: Text("Update hydration.")
        case .hygiene: Text("Open care tasks.")
        case .trends: Text("Review local signals.")
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos, .sillyStats:
            Text(verbatim: "")
        }
    }
}

/// One tile in the quick-log grid (HOME-09): icon, then the noun, then the state beneath it —
/// one convention for all six tiles — highlighted moss when today already has that kind of entry.
///
/// Purely presentational; the action closure is supplied by ``HomeView``'s quick-log section.
/// The noun draws in DM Sans Medium 12 (no existing ``FernletTextRole`` carries that face/size
/// pair) with the state in 11pt slate beneath; VoiceOver always reads noun + full-length state,
/// even while 3a·AX3 shortens the drawn state to a bare figure.
struct QuickLogButton: View {
    /// The tile's noun line, resolved `Text` so authored copy localizes and frozen-token display
    /// titles stay verbatim.
    var noun: Text
    /// The state beneath the noun ("3 logged", "none yet"); nil for stateless tool tiles.
    var state: Text?
    /// The full (never AX-shortened) state read to VoiceOver, so every tile reads noun + state
    /// consistently regardless of text size.
    var accessibilityState: Text?
    /// A second Voice Control name after the drawn noun ("Log meal"), or nil for the noun alone.
    var spokenSynonym: Text? = nil
    var systemImage: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                // Wraps rather than shrinking: the grid goes 2-up at accessibility sizes, so a wrap
                // is rare, and a word shrunk to fit is text that stopped tracking the user's size.
                noun
                    .font(.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption))
                    .fixedSize(horizontal: false, vertical: true)
                if let state {
                    // Scaled with `.caption`, not `.caption2`: caption 2 is the same 11pt from
                    // xSmall through Large, so the count did not change at the steps either side of
                    // the default size, and the audit reported it as not tracking Dynamic Type.
                    state
                        .font(.custom(FernletFontName.dmSans, size: 11, relativeTo: .caption))
                        .foregroundStyle(Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                        // The water tile's "+1 bottle" badge changes this in place ("2 bottles" →
                        // "3 bottles"); rolling the digits is the only feedback that the one-tap
                        // add landed.
                        .contentTransition(.numericText())
                }
            }
            .multilineTextAlignment(.center)
            // 56, down from 66 (FLOW-18): the compacted cold open.
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(active ? Color.moss : Color.slate)
            .background(active ? Color.moss.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // No `children: .ignore`: on a `Button` it mints a second, traitless element beside the
        // real one, so all six quick-log tiles would read "Meals, 3 logged" without ever saying
        // "button". `accessibilityLabelText` already replaces the noun/state the Button collapsed.
        .accessibilityLabel(accessibilityLabelText)
        // Voice Control: the label carries the live state ("Meals, 3 logged"), so the name a user
        // would have to say changes with every log. The drawn noun is the name that never moves.
        .accessibilityInputLabels(spokenNames)
    }

    /// The tile's Voice Control names: the drawn noun first, then the synonym when there is one.
    private var spokenNames: [Text] {
        guard let spokenSynonym else { return [noun] }
        return [noun, spokenSynonym]
    }

    /// Noun + full state, comma-joined — the one VoiceOver phrasing every tile shares (HOME-09).
    /// Built with `Text` interpolation (the `+` operator is deprecated-as-error on iOS 26); the
    /// "%@, %@" format key localizes the join while each half keeps its own localization.
    private var accessibilityLabelText: Text {
        guard let accessibilityState else { return noun }
        return Text("\(noun), \(accessibilityState)")
    }
}

/// The "Macros today" card: three ``MacroRing``s (protein/carbs/fat) plus the calorie and fiber
/// footer line.
///
/// Shared by Home, the Food tab and the Journal day detail; `showCalories` honors the user's
/// calories-display setting. `title` exists because the day detail shows a PAST day, where "Macros
/// today" was simply wrong; `fiberIntake` because the footer used to print the fiber *target* in the
/// same place and format the three consumed-vs-goal rings use, so "Fiber 37g" read as intake.
struct MacroCard: View {
    var totals: MacroTotals
    var targets: NutritionTargets
    var showCalories: Bool
    /// Card heading. "Macros today" on Home/Food; pass "Macros" for a day that isn't today.
    /// A `LocalizedStringKey` so both the default and the one override extract into the catalog —
    /// the default's literal lives in the app target, so it is harvested normally.
    var title: LocalizedStringKey = "Macros today"
    /// The day's fiber intake in grams, when the logged meals carry micronutrients. Nil ⇒ the footer
    /// names the value as a target rather than implying it was eaten.
    var fiberIntake: Double? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// World build: in the design language the three macros are framed bars, the status plate's bars
    /// made larger, in place of the rings (b1-language, b1-frame-root, b1-today).
    @Environment(\.fernletFramedLook) private var look
    private var framedBars: Bool { look != nil }

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title)
                if framedBars {
                    MacroBars(totals: totals, targets: targets)
                } else {
                    macroFigures
                }
                HStack {
                    if showCalories {
                        Label("\(totals.calories) / \(targets.calories) cal", systemImage: "flame")
                        Spacer()
                    }
                    if framedBars {
                        HStack(spacing: 8) {
                            WorldSpriteView(sprite: WorldSprites.leaf, scale: 2)
                            Text(verbatim: fiberFooter)
                        }
                    } else {
                        Label(fiberFooter, systemImage: "leaf")
                    }
                }
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            }
        }
    }

    /// The three macro figures. At accessibility text sizes they stay side by side — the 4b·AX3
    /// numeral form is compact by design — while the ring form still becomes a column (side by
    /// side, "114g" overflowed its ring and the three columns fell out of vertical alignment).
    @ViewBuilder
    private var macroFigures: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 14) { macroRings }
        } else {
            AdaptiveStack(spacing: 14, verticalAlignment: .top) { macroRings }
        }
    }

    /// The three rings. Each label and its one-letter accessibility-size initial are catalog keys
    /// resolved here: `MacroRing` takes them as finished `String`s because it also speaks the label
    /// inside a sentence, and a literal handed to its `String` parameter was never harvested.
    @ViewBuilder
    private var macroRings: some View {
        MacroRing(label: String(localized: "macros.protein", defaultValue: "Protein",
                                comment: "Macro ring label under the protein figure (Home, Food and a journal day)."),
                  initial: String(localized: "macros.protein.initial", defaultValue: "P",
                                  comment: "One-letter abbreviation of Protein, shown under the figure at the largest text sizes."),
                  color: .moss, current: totals.protein, goal: targets.protein)
        MacroRing(label: String(localized: "macros.carbs", defaultValue: "Carbs",
                                comment: "Macro ring label under the carbohydrate figure (Home, Food and a journal day)."),
                  initial: String(localized: "macros.carbs.initial", defaultValue: "C",
                                  comment: "One-letter abbreviation of Carbs, shown under the figure at the largest text sizes."),
                  color: .goldenrod, current: totals.carbs, goal: targets.carbs)
        MacroRing(label: String(localized: "macros.fat", defaultValue: "Fat",
                                comment: "Macro ring label under the fat figure (Home, Food and a journal day)."),
                  initial: String(localized: "macros.fat.initial", defaultValue: "F",
                                  comment: "One-letter abbreviation of Fat, shown under the figure at the largest text sizes."),
                  color: .terracotta, current: totals.fat, goal: targets.fat)
    }

    /// Same ceiling and reasoning as `DayMicronutrientBreakdownRow.maxDisplayableAmount`: this
    /// footer renders `store.micronutrientTotals.fiber`, a sum of persisted meal snapshots, and
    /// `Int(_: Double)` traps outside `Int`'s range — on the HOME tab, so a single poisoned row
    /// would crash the app's first screen on render.
    private static let maxDisplayableFiber = 1_000_000_000.0

    private var fiberFooter: String {
        Self.fiberFooterText(intake: fiberIntake, target: targets.fiber)
    }

    /// Pure so the hostile-value case is testable without rendering the card.
    static func fiberFooterText(intake: Double?, target: Int) -> String {
        guard let intake, intake.isFinite else {
            return String(localized: "macros.fiber.target", defaultValue: "Fiber target \(target)g",
                          comment: "Macros card footer when meals carry no fiber details: the daily fiber target in grams, e.g. 'Fiber target 30g'.")
        }
        let grams = Int(min(max(intake, 0), maxDisplayableFiber).rounded())
        return String(localized: "macros.fiber.intake", defaultValue: "Fiber \(grams)g of \(target)g",
                      comment: "Macros card footer: fiber eaten today out of the daily target, in grams, e.g. 'Fiber 18g of 30g'. The first number is what was eaten.")
    }
}

/// The three macros as framed bars (World Today panel, design language): the name, a bar in the one
/// set of data colours in a 2-pt ink frame, and "76 of 93 g". Each row is one VoiceOver element that
/// says the same sentence as Home's ring ("Protein, 76 of 93 grams").
struct MacroBars: View {
    var totals: MacroTotals
    var targets: NutritionTargets

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(String(localized: "macros.protein", defaultValue: "Protein",
                       comment: "Macro ring label under the protein figure (Home, Food and a journal day)."),
                current: totals.protein, goal: targets.protein, colour: WorldPalette.protein)
            row(String(localized: "macros.carbs", defaultValue: "Carbs",
                       comment: "Macro ring label under the carbohydrate figure (Home, Food and a journal day)."),
                current: totals.carbs, goal: targets.carbs, colour: WorldPalette.carbs)
            row(String(localized: "macros.fat", defaultValue: "Fat",
                       comment: "Macro ring label under the fat figure (Home, Food and a journal day)."),
                current: totals.fat, goal: targets.fat, colour: WorldPalette.fat)
        }
    }

    /// One macro: name, framed bar, amount.
    private func row(_ name: String, current: Int, goal: Int, colour: Color) -> some View {
        let fraction = goal > 0 ? min(1, max(0, Double(current) / Double(goal))) : 0
        let amount = String(localized: "macros.bar.amount", defaultValue: "\(current) of \(goal) g",
                            comment: "World Today panel, macro bars: grams eaten of the day's target, after the bar")
        let spoken = String(localized: "macros.bar.a11y", defaultValue: "\(name), \(current) of \(goal) grams",
                            comment: "World Today panel, macro bars, VoiceOver: one macro's name, then grams eaten of the target")
        return HStack(spacing: 10) {
            Text(verbatim: name)
                .font(.fernlet(.body))
                .foregroundStyle(WorldPalette.bark)
                .frame(minWidth: 82, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    WorldPalette.paperShade
                    colour.frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 10)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(verbatim: amount)
                .font(.fernlet(.bodySmall).monospacedDigit())
                .foregroundStyle(WorldPalette.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }
}

/// One macro progress ring: current grams over goal, with the fill clamped into [0, 1].
///
/// Rendered on Home, Food, and Journal via ``MacroCard``; the static `ringProgress` guard exists
/// because a user-typed goal of 0 would otherwise feed `.nan` into `.trim(to:)` and crash the
/// path builder. At accessibility text sizes the donut gives way to a numeral with a one-letter
/// label ("76 / P") — three rings with 40pt values inside them cannot hold a readable ring at
/// that size (4b·AX3), and this applies wherever ``MacroCard`` renders.
struct MacroRing: View {
    /// The macro's name, already resolved ("Protein"): drawn under the ring and spoken inside the
    /// element's sentence.
    var label: String
    /// The one-letter form drawn at accessibility sizes ("P"), resolved by the caller rather than cut
    /// from `label` in code, which would take the first letter of whatever the translation is.
    var initial: String
    var color: Color
    var current: Int
    var goal: Int
    /// Scales the ring with the text inside it, capped so an accessibility size can't hand one ring
    /// the whole card. A hard 68pt frame let "114g" spill outside the circle.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 68
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var clampedRingSize: CGFloat { min(ringSize, 96) }

    var progress: Double { Self.ringProgress(current: current, goal: goal) }

    /// Clamped, finite ring fill. A macro *goal* can now be a user-typed override, so `goal == 0` is
    /// reachable: the naive `current / goal` then yields `+inf` (or `.nan` when `current` is also 0),
    /// and handing `.nan` to `.trim(to:)` crashes SwiftUI's path builder — on Home, Food AND Journal,
    /// which all render this ring. Guard the divide and clamp into `[0, 1]`.
    static func ringProgress(current: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(max(Double(current) / Double(goal), 0), 1)
    }

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibilityFigure
        } else {
            ringFigure
        }
    }

    private var ringFigure: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.bark.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(current)g")
                    .font(.fernlet(.stat))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
            .frame(width: clampedRingSize, height: clampedRingSize)
            Text(label)
                .font(.fernlet(.labelSmall))
            Text("of \(goal)g")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        // One VoiceOver element per macro. The three Texts used to be read as three unrelated
        // fragments ("76g", "Protein", "of 93g").
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(current) of \(goal) grams")
    }

    /// 4b·AX3: the numeral form — the value over a one-letter label in the ring's tint. VoiceOver
    /// still reads the full "Protein 76 of 93 grams" phrasing.
    private var accessibilityFigure: some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(current)")
                .font(.fernlet(.stat))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: initial)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(current) of \(goal) grams")
    }
}

/// The hygiene / personal-care card: completion count, a segment bar, and an inline toggle grid
/// of today's care tasks.
///
/// Task toggles mutate the store directly; the header — title, count and segment bar — is the
/// card's own button and opens the full personal-care sheet.
///
/// **Why the grid is the open-button's sibling and not its child (A5·Q2).** The whole card used to
/// be one `Button` with the eight toggles nested inside it. An AX walk of that build (see
/// `HomeCardsRedesignUITests.testPersonalCareTogglesAreIndividuallyReachableAndOperable`) showed the
/// eight buttons surviving as their own elements, so they were reachable — but they sat inside
/// another button's element and hit region, which is the shape SwiftUI is free to flatten into one
/// element with promoted custom actions, and a `LazyVGrid` has no children to promote at the moment
/// that tree is built. Making the open control its own labelled button removes the question: eight
/// real, individually focusable, individually operable elements, none of them nested in a control
/// that wants the same tap. The same walk showed the toggles carrying no selected state at all —
/// "Floss, button" whether or not it was done — which is what ``taskToggle(_:)`` now fixes.
struct HygieneCard: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    /// The care-tile column floor, scaled against the tile's own type role (`.label` resolves
    /// `relativeTo: .subheadline`) so a task name gets a wider tile at accessibility text sizes
    /// instead of an ellipsis (T2-11). `@ScaledMetric` returns the base value at the default size,
    /// so nothing moves for a user who has not changed their text size.
    @ScaledMetric(relativeTo: .subheadline) private var taskTileMinimum: CGFloat = 120

    /// Clamped for the same reason ``MacroRing`` clamps its ring: past roughly this width the
    /// adaptive grid is already single-column on every screen the app ships to, so letting the
    /// minimum keep growing only pushes the layout around without changing what is drawn.
    private var clampedTaskTileMinimum: CGFloat { min(taskTileMinimum, 240) }

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                openSheetButton
                taskGrid
            }
        }
        // A container, not an element: the header button and the eight toggles stay individually
        // focusable inside it, and Switch Control / VoiceOver get one group to move by.
        .accessibilityElement(children: .contain)
    }

    /// Title, count and segment bar — the card's own control, which opens the personal-care sheet.
    private var openSheetButton: some View {
        let progress = store.personalCareProgress()
        return Button { activeSheet = .hygiene } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // "Personal care", matching the sheet this card opens. The same feature used
                    // to be called Care (tile), Personal care (sheet) and Hygiene (here).
                    SectionLabel("Personal care")
                    Spacer()
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.fernlet(.stat))
                        .foregroundStyle(progress.completed == progress.total ? Color.moss : Color.slate)
                }
                segmentBar
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Spoken rather than combined: the derived label would have been "Personal care, 3/8",
        // and a screen reader reads "3/8" as "three slash eight".
        //
        // `.accessibilityLabel` alone, deliberately — NOT `.accessibilityElement(children: .ignore)`
        // first. A `Button` is already exactly one element, so the label has something to replace;
        // adding `children: .ignore` on top mints a *second*, traitless element beside the button,
        // which the AX walk caught: the card exposed both "Personal care. 2 of 8 done." (Other) and
        // "Personal care, 2/8" (Button) for one control.
        .accessibilityLabel("Personal care. \(progress.completed) of \(progress.total) done.")
        // T2-12: the label is a sentence, so Voice Control gets short things to say instead.
        .accessibilityInputLabels([Text("Personal care"), Text("Care tasks")])
        .accessibilityIdentifier("home.hygiene")
    }

    /// One segment per task, filled when it is done. Decorative: the count beside the title and the
    /// per-task selected state below already carry this, and eight unlabelled slivers would only add
    /// eight stops to a screen reader's path through the card.
    private var segmentBar: some View {
        HStack(spacing: 3) {
            ForEach(store.personalCareTasks) { task in
                RoundedRectangle(cornerRadius: 3)
                    .fill(store.isPersonalCareTaskCompleted(task) ? Color.moss : Color.bark.opacity(0.1))
                    .frame(height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private var taskGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: clampedTaskTileMinimum), spacing: 6)], spacing: 6) {
            ForEach(store.personalCareTasks) { task in
                taskToggle(task)
            }
        }
    }

    /// One care task, as its own control. The completed state rides on `.isSelected` — the house
    /// convention `ChipButtonStyle` already uses — so the toggle announces "selected" when the task
    /// is done rather than reading identically in both states.
    private func taskToggle(_ task: PersonalCareTask) -> some View {
        let isDone = store.isPersonalCareTaskCompleted(task)
        return Button {
            // B11: a check-off landed in place (`logged`); taking one back is just a changed choice.
            FernletFeedback.system.play(isDone ? .tick : .logged)
            store.togglePersonalCareTask(task)
        } label: {
            Label(task.displayLabel, systemImage: task.systemImage)
                .font(.fernlet(.label))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isDone ? Color.moss : Color.slate)
                .background(isDone ? Color.moss.opacity(0.12) : Color.bark.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isDone ? [.isSelected] : [])
        // `task.id` is the frozen persisted token (a `HygieneItem.rawValue` for a built-in), which is
        // exactly what an accessibility identifier is allowed to be: English, stable, never display.
        .accessibilityIdentifier("home.hygiene.task.\(task.id)")
    }
}

/// A titled cream section container used across scroll screens: optional `SectionLabel` header
/// over a rounded, softly shadowed content card.
///
/// The generic content builder keeps it a pure layout primitive; several tabs and the Private hub
/// pages compose their row lists inside it.
struct FernletScrollSection<Content: View>: View {
    /// The header, already resolved to a ``SectionLabel`` so the body never has to re-decide
    /// whether the caller's string was authored copy or a runtime value.
    private let header: SectionLabel?
    @ViewBuilder var content: Content

    /// The localizing initializer — for a heading written here as a literal, which is every
    /// caller but one.
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.header = SectionLabel(title)
        self.content = content()
    }

    /// The non-localizing initializer, for a heading that is already final: user data, a formatted
    /// value, or a domain display property that resolved its own string. Kept under a distinct
    /// label rather than a `String` overload of `init(_:)`, because a same-label `String` overload
    /// wins for a plain literal and would quietly un-localize every other call site.
    init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.header = SectionLabel(verbatim: title)
        self.content = content()
    }

    /// The untitled section. It needs its own initializer now that `title` is no longer a
    /// defaulted optional: a `nil` default beside a `LocalizedStringKey` parameter makes an
    /// unlabelled literal call ambiguous.
    init(@ViewBuilder content: () -> Content) {
        self.header = nil
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                header
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .bark.opacity(0.06), radius: 10, x: 0, y: 4)
        }
    }
}

/// The house hairline divider between rows inside a ``FernletScrollSection`` card.
///
/// A `Divider` tinted to the bark palette with the standard vertical padding, so row lists stay
/// visually consistent across screens.
struct FernletRowDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.bark.opacity(0.08))
            .padding(.vertical, 8)
    }
}

/// One polaroid on the Home photowall strip: caption, rotation, themed fallback color, and an
/// optional friend-photo id to render as the image.
///
/// Mapped from ``PhotowallSeed``s (or the built-in placeholder set when no seeds exist); the id
/// prefers the photo id so a re-seeded wall animates tile identity correctly.
struct PhotowallTile: Identifiable {
    let caption: String
    let rotation: Double
    let color: Color
    let photoID: UUID?

    var id: String {
        photoID?.uuidString ?? caption
    }
}

// MARK: - Styling

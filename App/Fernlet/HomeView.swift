import ProximityKit
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
/// Privacy-relevant detail: `refreshRecentPeriodActivity` owns its own HealthKit client, so it
/// re-checks `allowedHealthCapabilities` itself and drops its resident answer when cycle tracking
/// is hidden mid-session. Prior-day rows for "Recent bites" are cached per day rollover rather
/// than re-decrypted every render.
struct HomeView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var selectedTab: FernletTab
    @Binding var privateHubSection: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    /// Shared period store, threaded from ContentView for the (opt-in) cycle surfaces.
    var periodStore: PeriodTrackerStore? = nil
    /// Shared body-signals service, threaded from ContentView for the (opt-in) stress surfaces.
    var stressService: StressService? = nil
    @State private var hasRecentPeriodEvent = false
    @State private var isCompanionThoughtVisible = true
    @State private var companionTapThought: String?
    @State private var isCompanionSheetPresented = false
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
                VStack(spacing: 16) {
                    homeHeader
                    // 3a·AX3: the photowall and thought bubble give way entirely at accessibility
                    // sizes — the strip is decorative (hit-testing already disabled), and the grid
                    // starting above the tab bar is the promise that matters.
                    if !dynamicTypeSize.isAccessibilitySize {
                        photowallStrip
                    }
                    ForEach(store.settings.homeWidgets) { widget in
                        homeWidget(widget)
                    }
                }
                .padding(20)
                .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
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
            await refreshRecentPeriodActivity()
            do {
                try await Task.sleep(for: .seconds(6))
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
            // ≤30-min WeatherKitService cache, so this costs at most one fetch per half
            // hour. Renders never wait on it — until (unless) it lands, the layer shows
            // the time-of-day tint alone.
            guard store.settings.weatherPromptsEnabled else { return }
            companionAmbient = await WeatherKitService.shared.currentAmbient()
        }
        .onChange(of: activeSheet?.id) { _, new in
            if new == nil { scheduleRecentPeriodActivityRefresh() }
        }
        // Hiding must drop the resident flag immediately, not wait for the next sheet dismiss.
        .onChange(of: store.isPeriodTrackingVisible) { _, _ in
            scheduleRecentPeriodActivityRefresh()
        }
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
                            // Goldenrod text on the card's cream with a hairline goldenrod border — the
                            // house coin style (MilestonesView), and the reason it isn't a goldenrod fill:
                            // goldenrod-on-goldenrod-tint drops below the contrast floor for 12pt text.
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                Text("\(coins) gifted").font(.fernlet(.labelSmall))
                            }
                            .foregroundStyle(Color.goldenrod)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Color.goldenrod.opacity(0.4), lineWidth: 1))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate.opacity(0.65))
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
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("home.milestones")
        // Fold the summary into the LABEL, not the hint: `children: .ignore` drops the visible summary
        // and coin pill from the tree, and a hint is silenced by the system "Speak Hints" setting — so a
        // hint-only summary would leave a VoiceOver user hearing just "Milestones, button".
        .accessibilityLabel("Milestones. \(summary)")
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
    /// pure so the card can compute it from ledger values it already read, without re-scanning.
    static func milestonesSummary(keptKinds: Int, coins: Int) -> String {
        if keptKinds == 0 {
            return "Your keepsake shelf is waiting — every bit of care will find a place here."
        }
        let kindsPhrase = keptKinds == 1 ? "One kind of care" : "\(keptKinds) kinds of care"
        if coins > 0 {
            return "\(kindsPhrase) kept so far · \(coins) coins gifted."
        }
        return "\(kindsPhrase) kept so far, added up over all time."
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
                stressState: store.settings.stressAwarenessEnabled ? stressService?.assessment?.state : nil
            )
        case .milestones:
            milestonesCard
        case .firstAid:
            firstAidAction
        case .mealPhotos:
            mealPhotosStrip
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .trends:
            HomeActionWidget(widget: widget) {
                handleHomeWidget(widget)
            }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .top) {
            // Both halves are `Text(verbatim:)` on purpose: "Fernlet" is the product's proper
            // noun and must never be translated, and the subtitle is an already-localized
            // formatted date, which must not be run through a catalog lookup that can't match it.
            // 3a·AX3: the date eyebrow gives way at accessibility sizes.
            ScreenHeader(
                title: Text(verbatim: "Fernlet"),
                subtitle: Text(verbatim: dynamicTypeSize.isAccessibilitySize ? "" : FernletDate.niceDate().uppercased()),
                subtitleFirst: true,
                identifier: "screen.home"
            )
            Spacer()
            // The shared header control every other tab uses (58pt cream, stroked). The hand-rolled
            // 44pt 6%-bark circle this replaces was visibly smaller and lighter than its siblings.
            HeaderActionButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
                activeSheet = .settings
            }
            .accessibilityIdentifier("home.settings")
        }
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
                            caption: showsAllPolaroidCaptions || index == finalIndex ? tile.caption : "",
                            rotation: tile.rotation,
                            imageData: tile.photoID.flatMap { store.meshNetworkManager.thumbnailData(forPhotoID: $0) },
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
                PhotowallTile(caption: "park walk", rotation: -3, color: .fern.opacity(0.45), photoID: nil),
                PhotowallTile(caption: "dinner",    rotation:  2, color: .goldenrod.opacity(0.45), photoID: nil),
                PhotowallTile(caption: "morning",   rotation: -1, color: .slate.opacity(0.32), photoID: nil),
                PhotowallTile(caption: "music",     rotation:  3, color: .dustyRose.opacity(0.38), photoID: nil),
            ]
        }
        let palette: [Color] = [.fern.opacity(0.45), .goldenrod.opacity(0.45), .slate.opacity(0.32), .dustyRose.opacity(0.38)]
        return seeds.map { seed in
            PhotowallTile(
                caption: seed.caption,
                rotation: seed.rotation,
                color: palette[seed.colorIndex % palette.count],
                photoID: seed.photoID
            )
        }
    }

    private var companionSection: some View {
        VStack(spacing: 10) {
            CompanionView(
                state: store.companionState,
                appearance: store.settings.companionAppearance,
                size: 132,
                interactionLevel: companionPetCount,
                equippedItems: store.equippedCustomItems,
                stressTint: stressTintActive,
                calmTint: calmTintActive,
                settled: isCompanionSettled
            )
            .scaleEffect(isCompanionCalmSettling ? 0.98 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                interactWithCompanion()
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                isCompanionSheetPresented = true
            }
            .accessibilityLabel("Fernlet companion")
            .accessibilityHint("Tap to interact. Press and hold to edit.")
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
                    ambient: store.settings.weatherPromptsEnabled ? companionAmbient : nil
                )
                .padding(.horizontal, -FernletMetrics.spaceMd)
                .padding(.vertical, -FernletMetrics.spaceSm)
            }

            companionActions
        }
        .frame(maxWidth: .infinity)
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
                    Image(systemName: "heart.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 34, height: 34)
                        .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First aid")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text("A quiet minute, whenever")
                            .font(.fernlet(.bodySmall))
                            .italic()
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.moss.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("home.firstAid")
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.moss.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.moss.opacity(0.22), lineWidth: 1)
        )
        // Padding included: this is what makes the card's margin and the header-to-chips gap open
        // First aid again. Declared on the padded container, so the chips' and the header's own
        // button frames win their taps first.
        .contentShape(Rectangle())
        .onTapGesture { activeSheet = .firstAid(nil) }
    }

    /// One chip inside the First Aid card — its own button straight to `tool`.
    private func firstAidChip(_ icon: String, _ label: String, tool: FirstAidTool) -> some View {
        Button {
            activeSheet = .firstAid(tool)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.fernlet(.labelSmall))
            }
            .foregroundStyle(Color.moss)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.cream, in: Capsule())
            .overlay(Capsule().stroke(Color.moss.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fernletTapTarget(minWidth: 0)
        .accessibilityLabel(label)
        .accessibilityHint("Opens \(label.lowercased()) straight away")
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

    /// Presentation-only frazzle flag for the companion. Never overrides the sick/resting
    /// postures (their own care states win), and only ever appears when the user opted in.
    private var stressTintActive: Bool {
        guard store.settings.stressAwarenessEnabled,
              let state = stressService?.assessment?.state,
              state == .tense || state == .needsCare else { return false }
        return store.companionState != .sick && store.companionState != .resting
    }

    /// Presentation-only calm/settled accent for the companion — the positive counterpart to
    /// `stressTintActive`. Shows when opted-in body signals read `.calm`; like the frazzle flag,
    /// it never overrides the sick/resting postures.
    private var calmTintActive: Bool {
        guard store.settings.stressAwarenessEnabled,
              stressService?.assessment?.state == .calm else { return false }
        return store.companionState != .sick && store.companionState != .resting
    }

    /// The next-period outlook for the Home ambient bubble, gated by the same opt-in + hide-predictions.
    private var homePeriodPrediction: CyclePrediction? {
        guard store.settings.periodAwareScoringEnabled, !store.settings.hidePredictions else { return nil }
        return periodStore?.prediction
    }

    private var ambientThought: String {
        if let last = store.day.journals.last {
            return "You marked today as \(last.tag.label.lowercased()). Let that be enough information for now."
        }
        // BEFORE the companion thought, not after it. `companionThought` falls back to a
        // deterministic line ("A few ordinary care notes are already here") that is never nil, so on
        // a fresh install the bubble claimed notes existed while the intent card below said nothing
        // was logged — and this empty-day line was unreachable.
        if hasNoUserLogsToday {
            return "Start with one small thing. Enough, not everything."
        }
        if let thought = store.companionThought {
            return thought
        }
        if let thought = signalThought {
            return thought
        }
        return "A few ordinary care notes are already here. Keep the day simple."
    }

    /// The rotating tap thoughts — a constant table, so it is `static let` rather than a computed
    /// property that rebuilt the literal array on every access (R6: smallest scope, no per-read work).
    private static let companionTapThoughts = [
        "Fernlet notices you.",
        "A little check-in counts.",
        "Still here with you.",
        "Small care is still care."
    ]

    /// The 5th-pet moment: Fern is visibly content and settles in for a while.
    private static let companionSettledThought = "Fern is soaking up all this love — feeling completely content."
    /// Shown at most once per settled period when petting continues. Warm, never a
    /// refusal — Fern is settled, not "locked".
    private static let companionSettledLine = "Fern is feeling nice and settled — check back in a little while."

    private func interactWithCompanion() {
        guard !isCompanionJumping else { return }
        switch petGovernor.registerPet() {
        case .bounce:
            performPetBounce(settling: false)
        case .settling:
            performPetBounce(settling: true)
        case .calmIdle(let showsSettledLine):
            performCalmIdle(showsSettledLine: showsSettledLine)
        }
        syncCompanionSettled()
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
        Task {
            do {
                try await Task.sleep(for: .seconds(4))
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
        let signals = store.derivedSignals
        if let energy = signals.first(where: { $0.signalName == "energyTrend" }) {
            if energy.value == "low" { return "Energy has been low lately. Rest counts as care." }
            if energy.value == "rising" { return "Something has been building. Notice the upward pull." }
        }
        if let mood = signals.first(where: { $0.signalName == "moodTrend" }) {
            if mood.value == "needs gentleness" { return "Some harder days in the window. Notice what is still steady." }
            if mood.value == "improving" { return "The mood trend has been moving upward. Quiet progress." }
        }
        if let readiness = signals.first(where: { $0.signalName == "intensityReadiness" }) {
            if readiness.value == "ready for hard" { return "The signals suggest room to push today if you want to." }
            if readiness.value == "ready for light" { return "Today looks like a day to move gently and restore." }
        }
        if let eating = signals.first(where: { $0.signalName == "eatingPattern" }) {
            if eating.value == "light" { return "Nutrition has been lighter lately. One nourishing meal is enough." }
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
                HealthBar(state: store.companionState, value: store.score, heartGlow: store.heartGlow)
                unwellRow
            }
            // FLOW-18: the Today card's inner padding halved (16 → 8), countered at the call site
            // so the shared `FernletCard` keeps its 16pt everywhere else.
            .padding(-FernletMetrics.spaceSm)
        }
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
    }

    /// The per-day "I'm unwell today" row under the health bar (SETT-15): a day flag belongs on
    /// the day. Dusty rose, never terracotta — being unwell is not an error — and it states what
    /// it changes in one line. Writes through the day-keyed `setSick`, so it clears itself
    /// tomorrow. 5c·AX3: the explanation line stays (it is what makes the row safe to tap); the
    /// glyph is what gives way.
    private var unwellRow: some View {
        let isUnwell = store.isSick(on: store.todayKey)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.setSick(!isUnwell, on: store.todayKey)
            }
        } label: {
            HStack(spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: isUnwell ? "bandage.fill" : "bandage")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dustyRose)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("I'm unwell today")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("Scoring goes gentle until tomorrow")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
                if isUnwell {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dustyRose)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                Color.dustyRose.opacity(isUnwell ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("I'm unwell today. Scoring goes gentle until tomorrow.")
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
            && hasNoUserLogsToday
            && !store.isTodayIntentDismissed
    }

    private var hasNoUserLogsToday: Bool {
        store.day.meals.isEmpty &&
        store.day.workouts.isEmpty &&
        store.day.journals.isEmpty &&
        store.day.sleep == nil &&
        store.day.bottleCount == 0 &&
        store.day.hygiene.isEmpty
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
                LazyVGrid(columns: quickLogColumns, spacing: 8) {
                    ForEach(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, visibility: store.sensitiveSurfaceVisibility)) { item in
                        quickLogTile(item)
                    }
                }
            }
        }
    }

    /// 3a·AX3: three tiles cannot share the width once the noun is accessibility-sized — the grid
    /// goes 2-up, so four of the six tiles stay visible above the fold.
    private var quickLogColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    /// The one-tap mood check-in as its own self-named card (HOME-28): "How today felt", with the
    /// six chips wrapping onto two lines so Tired and Hard are never hidden past the card edge.
    private var moodCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How today felt")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
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
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.addBottle()
                    }
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

    /// The tile's state line (HOME-09): a count with its unit ("3 logged", "6 bottles", "2 of 3")
    /// or "none yet" — "3 meal", "6x", bare "Done" and bare "Logged" are all retired. `short` is
    /// the 3a·AX3 form: the bare figure once the text is too large to share a tile with its unit
    /// word. Tool tiles (breathing, grounding, …) have no daily count and return nil.
    private func stateText(for item: FernletShortcut, short: Bool) -> Text? {
        switch item {
        case .meal: countedState(store.day.meals.count, short: short)
        case .water: waterState(short: short)
        case .move: countedState(store.day.workouts.count, short: short)
        case .sleep: sleepState(short: short)
        case .journal: journalState(short: short)
        case .care: careState(short: short)
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .breathing, .grounding, .worryBox:
            nil
        }
    }

    /// "N logged" — shared by the Meals and Move tiles.
    private func countedState(_ count: Int, short: Bool) -> Text {
        if count == 0 { return Text("none yet") }
        return short ? Text(verbatim: "\(count)") : Text("\(count) logged")
    }

    private func waterState(short: Bool) -> Text {
        let count = store.day.bottleCount
        if count == 0 { return Text("none yet") }
        if short { return Text(verbatim: "\(count)") }
        return count == 1 ? Text("1 bottle") : Text("\(count) bottles")
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
        return count == 1 ? Text("1 entry") : Text("\(count) entries")
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
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos:
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
            activeSheet = .logPeriod(targetDate: nil, editingEntry: nil)
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
        // This owns a SECOND HealthKit client, so it inherits neither the period store's gate nor
        // `allowedHealthCapabilities` — it must check for itself. Without this it queries 30 days of
        // menstrual flow on every Home appearance, every cold launch, and every sheet dismiss, while
        // the user has cycle tracking hidden and while the app is LOCKED, to compute a flag whose only
        // consumer (the `.logPeriod` tile) is filtered out anyway.
        //
        // Routed through `allowedHealthCapabilities` rather than re-testing the flags by hand, so this
        // inherits BOTH the visibility gate and the existing lock rule from the one place that defines
        // them. Assigns rather than bails so hiding mid-session drops the resident answer to "has this
        // user bled in the last month" instead of leaving it latched.
        guard store.allowedHealthCapabilities(from: [.cycleTracking]).contains(.cycleTracking) else {
            hasRecentPeriodEvent = false
            return
        }
        let service = HealthKitService()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
        let range = DateInterval(start: start, end: Date())
        let samples = (try? await service.loadPeriodEvents(in: range)) ?? []
        // Re-check after the await: this task may have been superseded, or the user may have hidden
        // cycle tracking while the query was suspended. A late answer must never re-latch a flag a
        // newer trigger already cleared.
        guard !Task.isCancelled else { return }
        guard store.allowedHealthCapabilities(from: [.cycleTracking]).contains(.cycleTracking) else {
            hasRecentPeriodEvent = false
            return
        }
        hasRecentPeriodEvent = samples.contains { sample in
            (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
        }
    }
}

/// The companion customization sheet (reached by the Customize chip under the hero companion, or
/// the legacy long-press): the template ``SheetHeader`` with the coin balance leading, a live
/// companion preview beside named Wardrobe / Creation Studio rows, and one selector row per slot
/// (body / accessory / clothing / side item).
///
/// Each slot row pushes a picker that combines the built-in item grid + recolor controls with the
/// user's own Wardrobe-designed items for the covered `ItemSlot`s; all writes go through
/// `FernletStore.setCompanionAppearance` / the equip APIs, so the preview and the Home hero stay
/// in lockstep. Wardrobe and Studio stay reachable ONLY through this stack's push wiring
/// (binding-driven with `onExit`) so an environment dismiss can never tear the sheet down.
private struct CompanionCustomizationSheet: View {
    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Raised by a ``CreationStudioView`` pushed anywhere on this stack while it holds unsaved paint.
    /// The studio is a PUSH inside this sheet, so without this a swipe-down from the studio threw the
    /// drawing away with no prompt.
    @State private var isStudioDraftDirty = false
    /// Drives the root-level push into a NEW item's studio (HOME-30). A binding-driven push with
    /// `onExit`, mirroring ``WardrobeView``'s wiring, because the studio must be popped by its
    /// host — its environment `dismiss` from the confirmation step tears the whole sheet down
    /// (see ``CreationStudioView/leaveStudio()``).
    @State private var isDesigningFromRoot = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The template chrome (XCUT-14/XCUT-15): left-aligned Fraunces title with Done as
                // the trailing text button, replacing the centred system title + toolbar Done. The
                // coin balance leads — a balance is information, not an action, so it never takes
                // the slot that dismisses the sheet.
                SheetHeader(
                    title: Text("Customize"),
                    subtitle: Text("Tap a slot to change it."),
                    onDone: { dismiss() }
                ) {
                    coinAccessory
                }
                ScrollView {
                    VStack(spacing: 9) {
                        companionAndLibraryRows
                        bodyRow
                        accessoryRow
                        clothingRow
                        sideItemRow
                        unlockedFooter
                    }
                    .padding(20)
                }
            }
            .background(Color.parchment)
            .tint(Color.moss)
            // The root draws its own SheetHeader; pushed screens (slot pickers, Wardrobe, Studio)
            // keep their system navigation bars and back buttons.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isDesigningFromRoot) {
                CreationStudioView(store: store,
                                   draftIsDirty: $isStudioDraftDirty,
                                   onExit: { isDesigningFromRoot = false })
            }
        }
        .interactiveDismissDisabled(isStudioDraftDirty)
    }

    /// The leading header slot: the wallet, moved here from the Wardrobe's toolbar (HOME-22 /
    /// XCUT-14). 3e·AX3: the balance keeps its slot but drops the coin glyph.
    @ViewBuilder
    private var coinAccessory: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(verbatim: "\(store.coinBalance)")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .accessibilityLabel("\(store.coinBalance) coins")
                .accessibilityIdentifier("customize.coinBalance")
        } else {
            CoinBalancePill(balance: store.coinBalance)
                .accessibilityIdentifier("customize.coinBalance")
        }
    }

    /// The companion preview beside the Wardrobe / Creation Studio rows (HOME-30: both become
    /// named rows at the sheet root, one chevron each). 3e·AX3: the companion stops sharing the
    /// row and sits above them, centred.
    @ViewBuilder
    private var companionAndLibraryRows: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 9) {
                companionPreview.frame(maxWidth: .infinity)
                wardrobeRow
                studioRow
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                companionPreview
                VStack(spacing: 9) {
                    wardrobeRow
                    studioRow
                }
            }
        }
    }

    /// The live 84pt companion preview; every write below refreshes it via the store.
    private var companionPreview: some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 84,
            interactionLevel: petCount,
            equippedItems: store.equippedCustomItems
        )
        .frame(width: 84, height: 84)
    }

    /// The named Wardrobe row: the closet with its item count, one chevron. Carries the
    /// `companion.wardrobe` test token — this is the primary Wardrobe entry now.
    private var wardrobeRow: some View {
        NavigationLink {
            WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
        } label: {
            libraryRowLabel(
                systemImage: "tshirt.fill",
                title: Text("Wardrobe"),
                detail: wardrobeCountText
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.wardrobe")
    }

    private var wardrobeCountText: Text? {
        let count = store.customItems.count
        guard count > 0 else { return nil }
        return count == 1 ? Text("1 item") : Text("\(count) items")
    }

    /// The named Creation Studio row — a straight door to designing a new item.
    private var studioRow: some View {
        Button {
            isDesigningFromRoot = true
        } label: {
            libraryRowLabel(
                systemImage: "paintbrush.pointed.fill",
                title: Text("Creation Studio"),
                detail: nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.studio")
    }

    /// Shared chrome for the Wardrobe / Studio rows: icon tile, title, optional count, one chevron.
    private func libraryRowLabel(systemImage: String, title: Text, detail: Text?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            title
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer(minLength: 8)
            if let detail {
                detail
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.bark.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
    }

    /// The reassurance line closing the sheet root.
    private var unlockedFooter: some View {
        Text("Everything you've unlocked stays unlocked.")
            .font(.fernlet(.bodySmall))
            .italic()
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    // MARK: Selector rows — one per slot, each showing what's equipped and pushing its picker.

    private var bodyRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Body",
                items: CompanionBodyStyle.allCases,
                selection: appearanceBinding(\.bodyStyle),
                colorTitle: "Body color",
                colorSelection: colorPresetBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                customColorHex: appearanceBinding(\.bodyCustomColorHex),
                customColor: customColorBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                isBuiltInEquipped: true,
                customSlots: []
            ) { style in
                Label(style.label, systemImage: bodyStyleIcon(style))
            }
        } label: {
            slotRowLabel(
                slot: "Body",
                value: appearance.bodyStyle.label,
                isEmpty: false
            ) {
                Circle()
                    .fill(appearance.bodyColor.color(for: store.companionState))
            }
        }
        .buttonStyle(.plain)
    }

    private var accessoryRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Accessory",
                items: CompanionAccessory.allCases,
                selection: appearanceBinding(\.accessory),
                colorTitle: "Accessory color",
                colorSelection: colorPresetBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                customColorHex: appearanceBinding(\.accessoryCustomColorHex),
                customColor: customColorBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                isBuiltInEquipped: appearance.accessory != .none,
                customSlots: [.hat, .face]
            ) { accessory in
                Label(accessory.label, systemImage: accessoryIcon(accessory))
            }
        } label: {
            slotRowLabel(
                slot: "Accessory",
                value: rowValue(builtInLabel: appearance.accessory.label, builtInEmpty: appearance.accessory == .none, customSlots: [.hat, .face]),
                isEmpty: appearance.accessory == .none && equippedCustomItem(in: [.hat, .face]) == nil
            ) {
                slotIcon(accessoryIcon(appearance.accessory))
            }
        }
        .buttonStyle(.plain)
    }

    private var clothingRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Clothing",
                items: CompanionClothing.allCases,
                selection: appearanceBinding(\.clothing),
                colorTitle: "Clothing color",
                colorSelection: colorPresetBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                customColorHex: appearanceBinding(\.clothingCustomColorHex),
                customColor: customColorBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                isBuiltInEquipped: appearance.clothing != .none,
                customSlots: [.body]
            ) { clothing in
                Label(clothing.label, systemImage: clothingIcon(clothing))
            }
        } label: {
            slotRowLabel(
                slot: "Clothing",
                value: rowValue(builtInLabel: appearance.clothing.label, builtInEmpty: appearance.clothing == .none, customSlots: [.body]),
                isEmpty: appearance.clothing == .none && equippedCustomItem(in: [.body]) == nil
            ) {
                slotIcon(clothingIcon(appearance.clothing))
            }
        }
        .buttonStyle(.plain)
    }

    private var sideItemRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Side item",
                items: CompanionSideItem.allCases,
                selection: appearanceBinding(\.sideItem),
                colorTitle: "Item color",
                colorSelection: colorPresetBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                customColorHex: appearanceBinding(\.sideItemCustomColorHex),
                customColor: customColorBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                isBuiltInEquipped: appearance.sideItem != .none,
                customSlots: [.heldItem]
            ) { item in
                Label(item.label, systemImage: item.systemImage)
            }
        } label: {
            slotRowLabel(
                slot: "Side item",
                value: rowValue(builtInLabel: appearance.sideItem.label, builtInEmpty: appearance.sideItem == .none, customSlots: [.heldItem]),
                isEmpty: appearance.sideItem == .none && equippedCustomItem(in: [.heldItem]) == nil
            ) {
                slotIcon(appearance.sideItem.systemImage)
            }
        }
        .buttonStyle(.plain)
    }

    /// The value shown on a slot row: the built-in label when a built-in is on; otherwise the name of
    /// an equipped custom item folded into this slot; otherwise the built-in's "None" label.
    private func rowValue(builtInLabel: String, builtInEmpty: Bool, customSlots: [ItemSlot]) -> String {
        if !builtInEmpty { return builtInLabel }
        if let item = equippedCustomItem(in: customSlots) {
            return item.name.isEmpty ? item.slot.label : item.name
        }
        return builtInLabel
    }

    /// The first equipped custom item whose slot is folded into this row, if any.
    private func equippedCustomItem(in slots: [ItemSlot]) -> CustomizationItem? {
        store.equippedCustomItems.first { slots.contains($0.slot) }
    }

    /// The shared selector-row chrome: a small icon/swatch, an uppercase slot label, the current
    /// value right-aligned, and a chevron. `isEmpty` renders the value as a soft italic nudge.
    private func slotRowLabel<Icon: View>(
        slot: String,
        value: String,
        isEmpty: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 12) {
            icon()
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.bark.opacity(0.06))
                )

            Text(slot.uppercased())
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(width: 66, alignment: .leading)

            Spacer(minLength: 8)

            Text(value)
                .font(.fernlet(.body))
                .italic(isEmpty)
                .foregroundStyle(isEmpty ? Color.slate : Color.bark)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.bark.opacity(0.4))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot): \(value)")
    }

    /// A slot swatch built from an SF Symbol, tinted to read as a quiet placeholder.
    private func slotIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15))
            .foregroundStyle(Color.slate.opacity(0.7))
    }

    /// A full-screen picker for one slot: a live companion preview, the built-in item grid + recolor
    /// controls, and — folded into the same picker — the user's custom items for the slot(s) this row
    /// covers. Built-ins keep the swatch/ColorPicker recolor; custom items carry their own painted
    /// colors and so get no color control. Reuses the existing customization card verbatim so all
    /// built-in pick / recolor / custom-color behavior is preserved.
    private func slotPicker<Item: Identifiable & Hashable, LabelContent: View>(
        title: LocalizedStringKey,
        items: [Item],
        selection: Binding<Item>,
        colorTitle: LocalizedStringKey,
        colorSelection: Binding<CompanionAssetColor>,
        customColorHex: Binding<String?>,
        customColor: Binding<Color>,
        isBuiltInEquipped: Bool,
        customSlots: [ItemSlot],
        @ViewBuilder label: @escaping (Item) -> LabelContent
    ) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                pickerPreview

                CompanionCustomizationCard(
                    title: title,
                    items: items,
                    selection: selection,
                    colorTitle: colorTitle,
                    colorSelection: colorSelection,
                    customColorHex: customColorHex,
                    customColor: customColor,
                    state: store.companionState,
                    // Recolor is a built-in-only control: hidden when no built-in is equipped in
                    // this slot (custom items paint their own colors).
                    showsColor: isBuiltInEquipped,
                    label: label
                )

                customItemsSection(for: customSlots)
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A live companion preview shown atop each slot picker, so recolor + equip changes are visible
    /// without leaving the picker.
    private var pickerPreview: some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 96,
            interactionLevel: petCount,
            equippedItems: store.equippedCustomItems
        )
        .frame(width: 96, height: 96)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// The custom-item section folded into a slot picker: the user's own items for the covered
    /// slot(s), each tappable to equip/unequip, plus the standing route into the Wardrobe (which
    /// still owns designing, editing, and recoloring custom items).
    @ViewBuilder
    private func customItemsSection(for slots: [ItemSlot]) -> some View {
        let items = store.customItems.filter { slots.contains($0.slot) }
        if slots.isEmpty {
            EmptyView()
        } else {
            FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Your items")

                if items.isEmpty {
                    Text("Design one in the Wardrobe to fold it in here.")
                        .font(.fernlet(.body))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items) { item in
                        customItemButton(item)
                    }
                }

                // The `companion.wardrobe` test token migrated to the sheet root's Wardrobe row
                // (HOME-30) — this contextual link stays, without the identifier, so a slot picker
                // still routes into designing.
                NavigationLink {
                    WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tshirt.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.moss)
                            .frame(width: 34, height: 34)
                            .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Design & recolor in Wardrobe")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.moss)
                            Text("Open the closet")
                                .font(.fernlet(.bodySmall))
                                .italic()
                                .foregroundStyle(Color.slate)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.moss)
                    }
                }
                .buttonStyle(.plain)
            }
            }
        }
    }

    /// One custom-item row inside a slot picker. Tap to equip; tap the equipped item to unequip.
    private func customItemButton(_ item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        return Button {
            if isEquipped {
                store.unequipCustomSlot(item.slot)
            } else {
                store.equipCustomItem(id: item.id, slot: item.slot)
            }
        } label: {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name.isEmpty ? item.slot.label : item.name)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text(item.slot.label)
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
                if isEquipped {
                    Text("Equipped")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.moss)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.moss.opacity(0.12), in: Capsule())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEquipped ? Color.moss.opacity(0.10) : Color.bark.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name.isEmpty ? item.slot.label : item.name), \(isEquipped ? "equipped" : "not equipped")")
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<CompanionAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: keyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: keyPath] = newValue
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func colorPresetBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<CompanionAssetColor> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: presetKeyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: presetKeyPath] = newValue
                appearance[keyPath: customKeyPath] = nil
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func customColorBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<Color> {
        Binding(
            get: {
                let appearance = store.settings.companionAppearance
                if let hex = appearance[keyPath: customKeyPath], let color = Color(fernletHex: hex) {
                    return color
                }
                return appearance[keyPath: presetKeyPath].color(for: store.companionState)
            },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: customKeyPath] = newValue.fernletHexString
                store.setCompanionAppearance(appearance)
            }
        )
    }

    /// One glyph per body shape. All four used to draw the same "seal", so the icons carried no
    /// information at all and the live preview above was the only cue to what a row would do.
    private func bodyStyleIcon(_ style: CompanionBodyStyle) -> String {
        switch style {
        case .circle: "circle"
        case .softBlob: "oval"
        case .pear: "drop"
        case .puddle: "capsule"
        }
    }

    private func accessoryIcon(_ accessory: CompanionAccessory) -> String {
        switch accessory {
        case .none: "circle.slash"
        case .sprout: "leaf"
        case .flower: "camera.macro"
        case .glasses: "eyeglasses"
        }
    }

    private func clothingIcon(_ clothing: CompanionClothing) -> String {
        switch clothing {
        case .none: "circle.slash"
        case .scarf: "wind"
        case .sleepCap: "moon"
        }
    }

}

private extension Color {
    init?(fernletHex: String) {
        guard let uiColor = UIColor(hex: fernletHex) else { return nil }
        self.init(uiColor)
    }

    var fernletHexString: String? {
        #if canImport(UIKit)
        UIColor(self).hexString
        #else
        nil
        #endif
    }
}

/// The reusable built-in item grid + color controls inside a slot picker: a 2-column grid of
/// selectable items and (optionally) the preset swatches + custom `ColorPicker`.
///
/// Generic over the slot's item type so one card serves body styles, accessories, clothing, and
/// side items; selection and color flow back through the bindings
/// `CompanionCustomizationSheet` builds onto the store.
private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    /// Authored copy ("Body", "Clothing", …), so `LocalizedStringKey`: every caller passes a
    /// literal, and only that type extracts into the string catalog.
    var title: LocalizedStringKey
    var items: [Item]
    @Binding var selection: Item
    var colorTitle: LocalizedStringKey
    @Binding var colorSelection: CompanionAssetColor
    @Binding var customColorHex: String?
    @Binding var customColor: Color
    var state: CompanionState
    /// Whether the built-in recolor control is shown. Off when no built-in is equipped in this slot —
    /// custom items carry their own painted colors and get no color control.
    var showsColor: Bool = true
    @ViewBuilder var label: (Item) -> LabelContent

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        let isSelected = selection.id == item.id
                        Button {
                            selection = item
                        } label: {
                            label(item)
                                .font(.fernlet(.label))
                                // The contrast-safe fill/ink pair, not cream on plain `moss`.
                                .foregroundStyle(isSelected ? Color.onMoss : Color.bark)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    isSelected ? Color.mossFill : Color.bark.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }

                if showsColor {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(colorTitle)
                            Spacer()
                            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                                .labelsHidden()
                        }

                        LazyVGrid(columns: colorColumns, spacing: 6) {
                            ForEach(CompanionAssetColor.allCases) { color in
                                colorButton(for: color)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func colorButton(for color: CompanionAssetColor) -> some View {
        let isSelected = customColorHex == nil && colorSelection == color
        Button {
            colorSelection = color
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.color(for: state))
                    .frame(width: 11, height: 11)
                Text(color.label)
                    .font(.fernlet(.label))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.onMoss : Color.bark)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? Color.mossFill : Color.bark.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One derived signal expanded for the Trends modal: icon, title, value, explanation, a
/// ``SignalTrendMeter``, the source-field chips, and any nutrient-gap rows.
///
/// All presentation choices (title/icon/color/strength/explanation) come from
/// ``SignalPresentation`` so the row stays a dumb renderer of `DerivedSignalRecord`.
struct SignalDetailRow: View {
    var signal: DerivedSignalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: SignalPresentation.icon(for: signal.signalName))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(SignalPresentation.color(for: signal.value))
                    .frame(width: 34, height: 34)
                    .background(SignalPresentation.color(for: signal.value).opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(SignalPresentation.title(for: signal.signalName))
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(signal.value.capitalized)
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
                            Text(gap.nutrientName)
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.bark)
                            Spacer()
                            Text(gap.status == .gap ? "gap" : "covered")
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
enum SignalPresentation {
    /// Display title for a raw signal name (falls back to the raw name for unknown signals).
    static func title(for name: String) -> String {
        switch name {
        case "moodTrend": "Mood trend"
        case "energyTrend": "Energy trend"
        case "eatingPattern": "Eating pattern"
        case "progressionTrend": "Progression"
        case "intensityReadiness": "Readiness"
        case "micronutrientGaps7Day": "7-day nutrients"
        case "micronutrientGaps14Day": "14-day nutrients"
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

    static func color(for value: String) -> Color {
        let lower = value.lowercased()
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
        if lower.contains("insufficient") { return 1 }
        if lower.contains("low") || lower.contains("light") || lower.contains("gentleness") { return 2 }
        if lower.contains("steady") || lower.contains("consistent") || lower.contains("moderate") { return 3 }
        if lower.contains("building") || lower.contains("improving") || lower.contains("rising") || lower.contains("hard") || lower.contains("protein") { return 5 }
        return 3
    }

    /// Plain-language name for a raw `sourceFields` key. Unknown keys fall back to the key with its
    /// dots opened out, so a signal added later degrades to readable text rather than to code.
    static func sourceLabel(for field: String) -> String {
        switch field {
        case "journals.tag": "Journal moods"
        case "sleep": "Sleep"
        case "sleep.hours": "Sleep hours"
        case "sleep.quality": "Sleep quality"
        case "meals.count": "Meal count"
        case "meals.macros": "Meal macros"
        case "meals.calorieSnapshot": "Meal energy"
        case "meals.micronutrientSnapshot": "Meal nutrients"
        case "workouts.intensity": "Workout intensity"
        case "workouts.duration": "Workout length"
        case "workouts.rpe": "Perceived effort"
        case "body.restingHeartRate": "Resting heart rate"
        case "body.heartRateVariability": "Heart rate variability"
        default: field.replacingOccurrences(of: ".", with: " ")
        }
    }

    static func explanation(for signal: DerivedSignalRecord) -> String {
        switch signal.signalName {
        case "moodTrend":
            return "Compares recent journal tags against earlier tags in the rolling window."
        case "energyTrend":
            return "Combines sleep, journal tags, and recent workout load."
        case "eatingPattern":
            return "Looks at meal frequency, recent missed meal days, and protein totals."
        case "progressionTrend":
            return "Compares newer workout load against earlier workout load."
        case "intensityReadiness":
            return "Blends recent energy, training load, hard sessions, and meal coverage."
        default:
            if signal.nutrientGaps.isEmpty {
                return "Micronutrient coverage needs more meal data."
            }
            return "Tracks covered nutrients and possible gaps from logged meal snapshots."
        }
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
        .accessibilityLabel(
            heartGlow > 0
                ? "Care score \(Int(value * 100)) percent, with a little warmth from a friend"
                : "Care score \(Int(value * 100)) percent"
        )
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

    var body: some View {
        Button(action: action) {
            FernletCard {
                HStack(spacing: 12) {
                    Image(systemName: widget.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 36, height: 36)
                        .background(Color.moss.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(widget.title)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text(actionSubtitle)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate.opacity(0.65))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var actionSubtitle: String {
        switch widget {
        case .logFood: "Add food to today."
        case .recipeBook: "Open saved recipes."
        case .newRecipe: "Build a recipe."
        case .workout: "Log training or movement."
        case .journal: "Add a short note."
        case .sleep: "Log rest."
        case .water: "Update hydration."
        case .hygiene: "Open care tasks."
        case .trends: "Review local signals."
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos: ""
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
    var systemImage: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                noun
                    .font(.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let state {
                    state
                        .font(.custom(FernletFontName.dmSans, size: 11, relativeTo: .caption2))
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // The water tile's "+1 bottle" badge changes this in place ("2 bottles" →
                        // "3 bottles"); rolling the digits is the only feedback that the one-tap
                        // add landed.
                        .contentTransition(.numericText())
                }
            }
            // 56, down from 66 (FLOW-18): the compacted cold open.
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(active ? Color.moss : Color.slate)
            .background(active ? Color.moss.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
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

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title)
                macroFigures
                HStack {
                    if showCalories {
                        Label("\(totals.calories) / \(targets.calories) cal", systemImage: "flame")
                        Spacer()
                    }
                    Label(fiberFooter, systemImage: "leaf")
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

    @ViewBuilder
    private var macroRings: some View {
        MacroRing(label: "Protein", color: .moss, current: totals.protein, goal: targets.protein)
        MacroRing(label: "Carbs", color: .goldenrod, current: totals.carbs, goal: targets.carbs)
        MacroRing(label: "Fat", color: .terracotta, current: totals.fat, goal: targets.fat)
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
        guard let intake, intake.isFinite else { return "Fiber target \(target)g" }
        let grams = Int(min(max(intake, 0), maxDisplayableFiber).rounded())
        return "Fiber \(grams)g of \(target)g"
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
    var label: String
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
            Text(verbatim: String(label.prefix(1)))
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
/// Task toggles mutate the store directly; tapping the card body opens the full hygiene sheet.
struct HygieneCard: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    var body: some View {
        Button { activeSheet = .hygiene } label: {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    let progress = store.personalCareProgress()
                    HStack {
                        // "Personal care", matching the sheet this card opens. The same feature used
                        // to be called Care (tile), Personal care (sheet) and Hygiene (here).
                        SectionLabel("Personal care")
                        Spacer()
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.fernlet(.stat))
                            .foregroundStyle(progress.completed == progress.total ? Color.moss : Color.slate)
                    }
                    HStack(spacing: 3) {
                        ForEach(store.personalCareTasks) { task in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(store.isPersonalCareTaskCompleted(task) ? Color.moss : Color.bark.opacity(0.1))
                                .frame(height: 6)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(store.personalCareTasks) { task in
                            Button { store.togglePersonalCareTask(task) } label: {
                                Label(task.displayLabel, systemImage: task.systemImage)
                                    .font(.fernlet(.label))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(store.isPersonalCareTaskCompleted(task) ? Color.moss : Color.slate)
                                    .background(store.isPersonalCareTaskCompleted(task) ? Color.moss.opacity(0.12) : Color.bark.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
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

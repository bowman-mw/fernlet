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
/// `PetInteractionGovernor`'s anti-compulsion pacing; long-press opens
/// ``CompanionCustomizationSheet``) and composes ``CompanionAmbienceLayer`` behind it.
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    homeHeader
                    photowallStrip
                    ForEach(store.settings.homeWidgets) { widget in
                        homeWidget(widget)
                    }
                }
                .padding(20)
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
            .presentationDetents([.medium, .large])
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
            try? await Task.sleep(for: .seconds(6))
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
            if new == nil { Task { await refreshRecentPeriodActivity() } }
        }
        // Hiding must drop the resident flag immediately, not wait for the next sheet dismiss.
        .onChange(of: store.isPeriodTrackingVisible) { _, _ in
            Task { await refreshRecentPeriodActivity() }
        }
    }

    // MARK: - Milestones entry card

    /// One kind of care the user has kept, as a struck-coin token on the shelf.
    ///
    /// Stable order + tint per kind so the shelf doesn't reshuffle between renders; built by
    /// `keptKeepsakes(counts:worries:)` from the pre-read ledger values.
    private struct Keepsake: Identifiable {
        let id: MilestoneEventKind
        let icon: String
        let tint: Color
    }

    /// Icon + tint per milestone kind. Tints are chosen to stay distinct on the parchment shelf rather
    /// than to encode meaning. A kind with no entry here still gets a token (generic seal) — see
    /// `keepsakeStyle(for:)` — so a new `MilestoneEventKind` can't make the shelf silently under-count
    /// against the summary before someone styles it.
    private static let keepsakeStyles: [MilestoneEventKind: (icon: String, tint: Color)] = [
        .journal: ("book", .moss),
        .meal: ("fork.knife", .goldenrod),
        .workout: ("figure.walk", .terracotta),
        .water: ("drop", Color(red: 0.36, green: 0.55, blue: 0.74)),
        .breathing: ("wind", Color(red: 0.53, green: 0.51, blue: 0.72)),
        .worry: ("archivebox", .softTaupe)
    ]

    private func keepsakeStyle(for kind: MilestoneEventKind) -> (icon: String, tint: Color) {
        Self.keepsakeStyles[kind] ?? ("seal", .goldenrod)
    }

    /// The kinds the user has actually kept (count > 0) from the pre-read ledger inputs, one token each,
    /// in enum-declaration order. Iterating `allCases` rather than the style table guarantees coverage of
    /// a future kind instead of dropping it. Takes the counts + worry total as arguments so the card can
    /// scan each ledger exactly once and share the result with the summary.
    private func keptKeepsakes(counts: [MilestoneEventKind: Int], worries: Int) -> [Keepsake] {
        MilestoneEventKind.allCases.compactMap { kind in
            let kept = kind == .worry ? worries > 0 : (counts[kind] ?? 0) > 0
            guard kept else { return nil }
            let style = keepsakeStyle(for: kind)
            return Keepsake(id: kind, icon: style.icon, tint: style.tint)
        }
    }

    /// M1 "keepsake shelf": the kinds of care kept, as struck-coin tokens resting on a shelf ledge —
    /// a keepsake shelf, not another nav row. Always shows on the home feed (even when mostly empty)
    /// and taps through to `MilestonesView`, which owns the behavior — this is a warm doorway to it.
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
        return NavigationLink {
            MilestonesView(store: store)
        } label: {
            FernletCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Milestones")
                            .font(.fernlet(.header))
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
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.bark.opacity(0.14))
                                .frame(height: 3)
                                .offset(y: 2)
                            HStack(spacing: 12) {
                                ForEach(kept.prefix(5)) { k in
                                    PressedMedallion(icon: k.icon, tint: k.tint, diameter: 38)
                                }
                                if kept.count > 5 {
                                    Text("+\(kept.count - 5)")
                                        .font(.fernlet(.labelSmall))
                                        .foregroundStyle(Color.slate)
                                }
                                Spacer(minLength: 0)
                            }
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
            MacroCard(totals: store.macroTotals, targets: store.nutritionTargets, showCalories: store.settings.showCalories)
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
            ScreenHeader(title: "Fernlet", subtitle: FernletDate.niceDate().uppercased(), subtitleFirst: true, identifier: "screen.home")
            Spacer()
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .frame(width: 44, height: 44)
                    .background(Color.bark.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
        }
    }

    private var photowallStrip: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                let tiles = photowallTiles
                let horizontalInset: CGFloat = 46
                let finalIndex = max(tiles.count - 1, 1)

                ZStack {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        PolaroidTile(
                            color: tile.color,
                            caption: tile.caption,
                            rotation: tile.rotation,
                            imageData: tile.photoID.flatMap { store.meshNetworkManager.thumbnailData(forPhotoID: $0) },
                            imageWidth: 104,
                            imageHeight: 92
                        )
                        .position(
                            x: horizontalInset
                                + (geometry.size.width - horizontalInset * 2)
                                * CGFloat(index) / CGFloat(finalIndex),
                            y: geometry.size.height / 2
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
        .frame(height: 132, alignment: .bottom)
        .padding(.top, 4)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
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
            .padding(.vertical, 14)
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

            if store.settings.stressAwarenessEnabled {
                bodySignalsLink
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Quiet door to the body-signals explainer (its App Store 1.4.1 not-medical disclaimer + First Aid
    /// invite). Home is chip-free now, so this is a subtle link — shown only when stress awareness is on —
    /// rather than the old status line, and it stays the sole production entry to `StressExplainerSheet`
    /// (setting the top-level `activeSheet` so the sheet's dismiss-then-First-Aid chain keeps working).
    private var bodySignalsLink: some View {
        Button {
            activeSheet = .stressExplainer
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                Text("Body signals")
                    .font(.fernlet(.labelSmall))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(Color.slate)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.stressLine")
        .accessibilityLabel("Body signals — how Fernlet reads this")
        .accessibilityHint("Explains how body signals are estimated")
    }

    /// First Aid as its own calm, standalone action (not a status chip): a soft moss-tinted card that
    /// opens the First Aid sheet — but now with three chips previewing what's inside, so it reads as an
    /// invitation rather than another unlabelled nav row. One tap on the card still opens the sheet; the
    /// chips are a preview, not separate targets.
    private var firstAidAction: some View {
        Button {
            activeSheet = .firstAid(nil)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "heart.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 34, height: 34)
                        .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First aid")
                            .font(.fernlet(.header))
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
                HStack(spacing: 8) {
                    firstAidChip("wind", "Breathe")
                    firstAidChip("scope", "Ground")
                    firstAidChip("archivebox", "Worry box")
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("home.firstAid")
        .accessibilityLabel("First aid")
        .accessibilityHint("Opens calm tools: breathing, grounding, and the worry box")
    }

    /// A preview chip inside the First Aid card. Decorative — the card is the tap target, so the chips
    /// carry no accessibility of their own (the card's label already names the tools).
    private func firstAidChip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label).font(.fernlet(.labelSmall))
        }
        .foregroundStyle(Color.moss)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.cream, in: Capsule())
        .overlay(Capsule().stroke(Color.moss.opacity(0.18), lineWidth: 1))
        .accessibilityHidden(true)
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
                                        hasSealedData: { store.mealPhotoHasSealedFile(for: bite.photoID) }
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
        if let thought = store.companionThought {
            return thought
        }
        if let thought = signalThought {
            return thought
        }
        if store.day.meals.isEmpty && store.day.workouts.isEmpty {
            return "Start with one small thing. Enough, not everything."
        }
        return "A few ordinary care notes are already here. Keep the day simple."
    }

    private var companionTapThoughts: [String] {
        [
            "Fernlet notices you.",
            "A little check-in counts.",
            "Still here with you.",
            "Small care is still care."
        ]
    }

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
        Task {
            try? await Task.sleep(for: .seconds(petGovernor.settleDuration))
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
            try? await Task.sleep(for: .milliseconds(440))
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                withAnimation(.easeInOut(duration: 0.46)) {
                    companionPetCount += 1
                }
            }
            try? await Task.sleep(for: .milliseconds(460))
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                isCompanionJumping = false
            }
        }

        let thought: String? = if settling {
            Self.companionSettledThought
        } else if companionTapCount.isMultiple(of: 3) {
            companionTapThoughts[companionTapCount % companionTapThoughts.count]
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
            try? await Task.sleep(for: .milliseconds(520))
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
            try? await Task.sleep(for: .seconds(4))
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
                    Text("Today")
                        .font(.fernlet(.header))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(FernletDate.niceDate().components(separatedBy: ",").first ?? "Today")
                            .font(.fernlet(.labelSmall))
                        Text(store.settings.selectedGoal.displayName)
                            .font(.fernlet(.labelSmall))
                    }
                    .foregroundStyle(Color.slate)
                }
                HealthBar(state: store.companionState, value: store.score, heartGlow: store.heartGlow)
            }
        }
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
                            .font(.fernlet(.header))
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
                    .accessibilityLabel("Dismiss today's intent")
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

    private var quickLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Quick log")
            FernletCard {
                VStack(spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, visibility: store.sensitiveSurfaceVisibility)) { item in
                            quickLogTile(item)
                        }
                    }
                    FernletRowDivider()
                    // One-tap mood check-in: a tag-only journal entry, no writing required.
                    QuickMoodRow(store: store)
                }
            }
        }
    }

    @ViewBuilder
    private func quickLogTile(_ item: FernletShortcut) -> some View {
        let button = QuickLogButton(
            title: title(for: item),
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
                        .font(.body)
                        .foregroundStyle(Color.moss)
                        .background(Color.parchment, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("Add a bottle of water")
                .accessibilityIdentifier("home.water.quickAdd")
            }
        } else {
            button
        }
    }

    private func title(for item: FernletShortcut) -> String {
        switch item {
        case .meal:
            store.day.meals.isEmpty ? "Meal" : "\(store.day.meals.count) meal"
        case .water:
            store.day.bottleCount == 0 ? "Water" : "\(store.day.bottleCount)x"
        case .move:
            store.day.workouts.isEmpty ? "Move" : "Done"
        case .sleep:
            store.day.sleep == nil ? "Sleep" : "Logged"
        case .journal:
            "Journal"
        case .care:
            "Care"
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .breathing, .grounding, .worryBox:
            item.title
        }
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
            activeSheet = .quickExercise
        case .sleep:
            activeSheet = .sleep
        case .journal:
            activeSheet = .journal
        case .care:
            activeSheet = .hygiene
        case .logPeriod:
            activeSheet = .logPeriod(targetDate: nil, editingEntry: nil)
        case .periodTracking:
            privateHubSection = .period
            selectedTab = .personal
        case .intimacyTracking:
            guard store.isIntimateLoggingAllowed else { return }
            privateHubSection = .intimacy
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
        hasRecentPeriodEvent = ((try? await service.loadPeriodEvents(in: range)) ?? []).contains { sample in
            (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
        }
    }
}

/// The companion customization sheet (reached by long-pressing the hero companion): a live
/// preview header plus one selector row per slot (body / accessory / clothing / side item).
///
/// Each row pushes a slot picker that combines the built-in item grid + recolor controls with the
/// user's own Wardrobe-designed items for the covered `ItemSlot`s; all writes go through
/// `FernletStore.setCompanionAppearance` / the equip APIs, so the preview and the Home hero stay
/// in lockstep.
private struct CompanionCustomizationSheet: View {
    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                companionHeader

                ScrollView {
                    VStack(spacing: 9) {
                        bodyRow
                        accessoryRow
                        clothingRow
                        sideItemRow
                    }
                    .padding(20)
                }
            }
            .background(Color.parchment)
            .tint(Color.moss)
            .navigationTitle("Fernlet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.moss)
                }
            }
        }
    }

    /// A live preview of the companion next to a calm "Customize" title. Replaces the old
    /// segmented Style/Customization control — the selector rows below carry the structure now.
    private var companionHeader: some View {
        HStack(spacing: 14) {
            CompanionView(
                state: store.companionState,
                appearance: store.settings.companionAppearance,
                size: 84,
                interactionLevel: petCount,
                equippedItems: store.equippedCustomItems
            )
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 3) {
                Text("Customize")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text(hasAnythingOn ? "Tap a slot to change it" : "Nothing on yet — pick a slot")
                    .font(.fernlet(.body))
                    .italic()
                    .foregroundStyle(Color.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(Color.parchment)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.bark.opacity(0.08))
                .frame(height: 1)
        }
    }

    // Is anything at all equipped (beyond the default body)? Drives the header's first-run nudge.
    private var hasAnythingOn: Bool {
        let appearance = store.settings.companionAppearance
        return appearance.accessory != .none
            || appearance.clothing != .none
            || appearance.sideItem != .none
            || !store.equippedCustomItems.isEmpty
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
                Label(style.label, systemImage: "seal")
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
        title: String,
        items: [Item],
        selection: Binding<Item>,
        colorTitle: String,
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

                NavigationLink {
                    WardrobeView(store: store)
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
                .accessibilityIdentifier("companion.wardrobe")
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
/// ``CompanionCustomizationSheet`` builds onto the store.
private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    var title: String
    var items: [Item]
    @Binding var selection: Item
    var colorTitle: String
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
                        Button {
                            selection = item
                        } label: {
                            label(item)
                                .font(.fernlet(.label))
                                .foregroundStyle(selection.id == item.id ? Color.cream : Color.bark)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    selection.id == item.id ? Color.moss : Color.bark.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
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
            .foregroundStyle(isSelected ? Color.cream : Color.bark)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? Color.moss : Color.bark.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
                    Text(field)
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
/// recompute.
struct TrendsModal: View {
    @Environment(\.dismiss) private var dismiss
    var signals: [DerivedSignalRecord]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(
                        title: "Trends",
                        subtitle: "Local signals from your logs. Prototype only — not production-private.",
                        subtitleFirst: false
                    )
                    if signals.isEmpty {
                        FernletCard { EmptyState(text: "More logs will make trends useful.") }
                    } else {
                        ForEach(signals) { signal in
                            SignalDetailRow(signal: signal)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            doneBar
        }
        .background(Color.parchment)
    }

    private var doneBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .padding(20)
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
struct HealthBar: View {
    var state: CompanionState
    var value: Double
    /// Presentation-only warmth from a friend's heart, 0–1, decaying linearly over 24h from
    /// receipt (`HeartGlowMath`). Renders a soft golden cap at the end of the bar — additive,
    /// never numeric, and never an input to the score itself.
    var heartGlow: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < Int((value * 12).rounded()) ? state.color : Color.bark.opacity(0.12))
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
                            .font(.fernlet(.header))
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

/// One tile in the quick-log grid: icon over title, highlighted moss when today already has that
/// kind of entry.
///
/// Purely presentational; the action closure is supplied by ``HomeView``'s quick-log section.
struct QuickLogButton: View {
    var title: String
    var systemImage: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.fernlet(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(active ? Color.moss : Color.slate)
            .background(active ? Color.moss.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// The "Macros today" card: three ``MacroRing``s (protein/carbs/fat) plus the calorie and fiber
/// footer line.
///
/// Shared by Home and the Food tab; `showCalories` honors the user's calories-display setting.
struct MacroCard: View {
    var totals: MacroTotals
    var targets: NutritionTargets
    var showCalories: Bool

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Macros today")
                HStack(spacing: 14) {
                    MacroRing(label: "Protein", color: .moss, current: totals.protein, goal: targets.protein)
                    MacroRing(label: "Carbs", color: .goldenrod, current: totals.carbs, goal: targets.carbs)
                    MacroRing(label: "Fat", color: .terracotta, current: totals.fat, goal: targets.fat)
                }
                HStack {
                    if showCalories {
                        Label("\(totals.calories) / \(targets.calories) cal", systemImage: "flame")
                        Spacer()
                    }
                    Label("Fiber \(targets.fiber)g", systemImage: "leaf")
                }
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            }
        }
    }
}

/// One macro progress ring: current grams over goal, with the fill clamped into [0, 1].
///
/// Rendered on Home, Food, and Journal via ``MacroCard``; the static `ringProgress` guard exists
/// because a user-typed goal of 0 would otherwise feed `.nan` into `.trim(to:)` and crash the
/// path builder.
struct MacroRing: View {
    var label: String
    var color: Color
    var current: Int
    var goal: Int

    var progress: Double { Self.ringProgress(current: current, goal: goal) }

    /// Clamped, finite ring fill. A macro *goal* can now be a user-typed override, so `goal == 0` is
    /// reachable: the naive `current / goal` then yields `+inf` (or `.nan` when `current` is also 0),
    /// and handing `.nan` to `.trim(to:)` crashes SwiftUI's path builder — on Home, Food AND Journal,
    /// which all render this ring. Guard the divide and clamp into `[0, 1]`.
    static func ringProgress(current: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(max(Double(current) / Double(goal), 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.bark.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(current)g")
                    .font(.fernlet(.stat))
            }
            .frame(width: 68, height: 68)
            Text(label)
                .font(.fernlet(.labelSmall))
            Text("of \(goal)g")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
        }
        .frame(maxWidth: .infinity)
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
                        SectionLabel("Hygiene")
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
                                Label(task.label, systemImage: task.systemImage)
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
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionLabel(title)
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

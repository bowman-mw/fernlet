import FernletDomainModel
import FernletScoring
import FernletSocial
import FernletUI
import SwiftUI
import WorldMapStore

/// Page 1 of Sprout's passport, Sprout's own page (World-Passport-Spec §4, `ps-sprout`, `ps-sprout-home`,
/// approved 2026-10-30): laid out like a passport's photo page, holding everything the close-up
/// (`ref-comp-close`) and Customize (`b2-customize`) held, and the shop (`ps-parity`).
///
/// From the top: the header; the photo (Sprout at 4 pt a pixel in its current look; tap to pet, with the
/// close-up's reactions at photo size) with its ghost at map size; the details (Name, Feeling, Shape, Care);
/// Sprout's line in the light bubble; the two machine-readable lines; the four slot buttons, Wardrobe and
/// Creation Studio; Your shop with the coins, and for the hour after a session the gold Friend shops row; This
/// is home (or the home's line with Manage) and App colors.
///
/// **In the book.** The book shows this as page 1's content and wraps the book in a `NavigationStack`: this view
/// fills the paper inside the page's 2-pt border, draws its own insets (``contentInsets``: the gutter on the
/// spine side, room for the page number at the foot), scrolls inside the page when it doesn't fit (the largest
/// text) with a fade at the foot, and pushes its pages with `navigationDestination`. It names its stack
/// "Passport", so each pushed page's Back reads "Passport". The Remember this place sheet (This is home) and
/// Settings › Home map (Manage) are its own sheets. Pass `isStudioDraftDirty` to block the book's close while
/// a Creation Studio pushed from here holds unsaved paint.
///
/// **Decoy.** In a decoy session it shows a fresh passport (§9, ``PassportSproutModel``): petting keeps nothing,
/// as on the close-up.
struct PassportSproutPage: View {
    var store: FernletStore
    /// The opt-in body-signal reading, as the map companion reads it.
    var bodySignal: CompanionBodySignal?
    /// Raised while a Creation Studio pushed from this page holds unsaved paint.
    @Binding var isStudioDraftDirty: Bool
    @State private var route: PassportSproutRoute?
    @State private var peek = CustomizePeek()
    @State private var placeSheet: WorldPlaceSheetMode?
    @State private var managesHomes = false
    @State private var governor = PetInteractionGovernor()
    @State private var reaction = WorldCloseUpReaction.none
    @State private var petCount = 0
    @State private var playfulUntil: Date?
    @State private var showsFade = false
    @State private var library: PassportLibrary
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The page's insets inside the paper (`.pppage` padding): 12 on top and on the outer side, 23 on the spine
    /// side (over the gutter shade), 30 at the foot for the page number.
    static let contentInsets = EdgeInsets(top: 12, leading: 23, bottom: 30, trailing: 12)

    init(store: FernletStore, bodySignal: CompanionBodySignal? = nil, isStudioDraftDirty: Binding<Bool> = .constant(false)) {
        self.store = store
        self.bodySignal = bodySignal
        _isStudioDraftDirty = isStudioDraftDirty
        _library = State(initialValue: PassportLibrary(openAtlas: { [store] in store.worldFog.atlas.openedAtlas }))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = companion(at: context.date)
            let model = makeModel(now: now, date: context.date)
            ScrollView {
                // The page grows with the text to the first accessibility size, then scrolls (§4).
                content(model: model, now: now)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .padding(Self.contentInsets)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 4
            } action: { _, hasMore in
                showsFade = hasMore
            }
            .overlay(alignment: .bottom) { if showsFade { PassportSproutFade() } }
        }
        .navigationTitle(Text(verbatim: PassportSproutCopy.passport))
        .navigationDestination(item: $route, destination: destination)
        .sheet(item: $placeSheet) { mode in
            WorldRememberPlaceSheet(store: store, mode: mode) { placeSheet = nil }
        }
        .sheet(isPresented: $managesHomes) {
            WorldHomesManageSheet(store: store) { managesHomes = false }
        }
    }

    /// The page's contents, top to bottom.
    private func content(model: PassportSproutModel, now: WorldCompanionNow) -> some View {
        VStack(spacing: 10) {
            PassportSproutHeader()
            identity(model: model, now: now)
            PassportSproutLine(text: reaction.line ?? store.companionAmbientThought(addressing: termOfAddress))
            PassportSproutMachineLines(lines: model.machineLines)
            PassportSproutWearing(model: model, act: act)
            PassportSproutShop(model: model, act: act)
            PassportSproutBottomRow(model: model, act: act)
        }
    }

    /// The photo beside the details; the details under it at the largest text sizes.
    private func identity(model: PassportSproutModel, now: WorldCompanionNow) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 11))
        return layout {
            photo(model: model, now: now)
            PassportSproutDetails(model: model)
        }
    }

    /// The photo, tapped to pet. VoiceOver: "Sprout, Thriving. Tap to pet."
    private func photo(model: PassportSproutModel, now: WorldCompanionNow) -> some View {
        var pose = now.pose
        pose.settled = reaction.blushes
        let highContrast = contrast == .increased
        return PassportSproutPhoto(
            grid: WorldCompanionPainter.paint(state: now.state, look: now.look, pose: pose, increasedContrast: highContrast),
            ghost: WorldCompanionPainter.paint(state: now.state, look: now.look, pose: now.pose, increasedContrast: highContrast),
            reaction: reaction, petCount: petCount)
            .contentShape(Rectangle())
            .onTapGesture(perform: pet)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: PassportSproutCopy.photoLabel(name: model.name, state: model.state.displayName)))
            .accessibilityHint(Text(verbatim: PassportSproutCopy.photoHint))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pet() }
            .accessibilityInputLabels([Text(WorldCloseUpCopy.petInputLabel(name: model.name))])
            .accessibilityIdentifier("passport.sprout.photo")
    }

    /// The pushed page for `route`; each names "Passport" as its Back.
    @ViewBuilder
    private func destination(_ route: PassportSproutRoute) -> some View {
        switch route {
        case .slot(let slot):
            CustomizeSlotPage(store: store, slot: slot, peek: $peek, isStudioDraftDirty: $isStudioDraftDirty)
        case .wardrobe:
            WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
        case .creationStudio:
            CreationStudioView(store: store, draftIsDirty: $isStudioDraftDirty, onExit: { self.route = nil })
        case .yourShop:
            YourShopView(store: store)
                .fernletPushedPage("Your shop")
        case .friendShops:
            FriendShopView(store: store, shop: store.meshFeatures.clothingShop)
                .fernletPushedPage("Friend shops")
        case .appColors:
            AppColorsPage(store: store)
        }
    }

    /// Does what a control on the page asked for.
    private func act(_ action: PassportSproutAction) {
        switch action {
        case .pet: pet()
        case .slot(let slot): route = .slot(slot)
        case .wardrobe: route = .wardrobe
        case .creationStudio: route = .creationStudio
        case .yourShop: route = .yourShop
        case .friendShops: route = .friendShops
        case .appColors: route = .appColors
        case .manageHomes: managesHomes = true
        case .thisIsHome:
            // ref-comp-home-add: Home picked, the pin where the person stands; with 2 homes the sheet asks
            // which to replace (ref-home-set).
            guard case .away(let point) = place() else { return }
            placeSheet = WorldCloseUpAfterClose.thisIsHome(point).placeSheet
        }
    }

    /// One pet: paced and cued as the map's pet and the close-up's, then the reaction for the governor's answer.
    private func pet() {
        playfulUntil = Date().addingTimeInterval(3 * 60)
        let response = WorldCompanionPet.register(governor: governor, store: store)
        if let cue = HomeView.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }
        let next = WorldCloseUpReaction.make(for: response)
        petCount += 1
        let id = petCount
        withAnimation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.5)) { reaction = next }
        Task {
            do {
                try await Task.sleep(for: .seconds(WorldCloseUpMotion.reactionHold))
            } catch {
                return
            }
            guard petCount == id else { return }
            withAnimation(.easeOut(duration: 0.3)) { reaction = .none }
        }
    }

    /// Whether the page shows a decoy's fresh passport.
    private var isDecoy: Bool {
        store.duressSessionActive || UITestSupport.passportSproutShowsDecoy
    }

    /// The companion at `date` as the map draws it; in a decoy, as it first looked (Circle, the sprout).
    private func companion(at date: Date) -> WorldCompanionNow {
        let now = WorldCompanionLook.current(store: store, at: date, night: .map, bodySignal: bodySignal, playfulUntil: playfulUntil)
        guard isDecoy else { return now }
        let look = WorldCompanionLook(appearance: .standard, state: now.state, asleep: now.pose.asleep)
        return WorldCompanionNow(state: now.state, look: look, pose: now.pose, emotion: now.emotion)
    }

    /// Where the person stands (the DEBUG harness can stage it).
    private func place() -> WorldCloseUpPlace {
        UITestSupport.passportSproutPlace ?? WorldCloseUpPlace.current(store: store)
    }

    /// The page's model now.
    private func makeModel(now: WorldCompanionNow, date: Date) -> PassportSproutModel {
        let decoy = isDecoy
        let status = WorldStatus.make(score: store.score, goldHearts: decoy ? 0 : store.goldHeartCount(at: date),
                                      macros: store.macroTotals, targets: store.nutritionTargets,
                                      bottles: store.day.bottleCount, bottleTarget: store.settings.hydrationTarget)
        return PassportSproutModel.make(
            name: CustomizeNightCopy.companionName(store), feeling: PassportSproutFeeling.text(of: now), state: now.state,
            appearance: store.settings.companionAppearance, equipped: store.equippedCustomItems, status: status,
            listed: store.listedShopItems.count, coins: store.coinBalance,
            friendShopMinutes: WorldShopButton.minutesLeft(store: store, at: date), place: place(),
            counts: PassportSproutCounts(progress: library.progress(of: store.worldFog.atlas.book)), isDecoy: decoy)
    }
}

/// Where page 1 goes: each pushed page (`b2-slot-picker`, `b2-wardrobe`, `b2-studio`, `b2-shop-editor`,
/// `b2-friend-shop`, App colors).
nonisolated enum PassportSproutRoute: Hashable, Sendable {
    case slot(CustomizeSlot)
    case wardrobe
    case creationStudio
    case yourShop
    case friendShops
    case appColors
}

/// The fade at the foot while there is more of the page below (`.ppfade`): the paper from clear, 46 pt tall.
struct PassportSproutFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: PassportSproutInk.paper.opacity(0), location: 0),
                               .init(color: PassportSproutInk.paper, location: 0.7)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 46)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The Feeling field's words (§4): "Thriving · happy", the state then the feeling in a word; asleep says only
/// that, and with no feeling the state alone. Read from one picture of the companion (``WorldCompanionNow``).
enum PassportSproutFeeling {
    /// The field's text for `now`.
    static func text(of now: WorldCompanionNow) -> String {
        guard let emotion = now.emotion else { return now.state.displayName }
        guard !emotion.hidesTheDay else { return emotion.displayName }
        return PassportSproutCopy.feeling(state: now.state.displayName, word: word(of: now))
    }

    /// The feeling in a word, lower case where the language writes it so ("happy", "contento").
    private static func word(of now: WorldCompanionNow) -> String? {
        switch now.emotion {
        case .happy?: String(localized: "passport.feeling.happy", defaultValue: "happy", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .sad?: String(localized: "passport.feeling.sad", defaultValue: "sad", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .tired?: String(localized: "passport.feeling.tired", defaultValue: "tired", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .sleepy?: String(localized: "passport.feeling.sleepy", defaultValue: "sleepy", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .hungry?: String(localized: "passport.feeling.hungry", defaultValue: "hungry", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .thirsty?: String(localized: "passport.feeling.thirsty", defaultValue: "thirsty", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .loved?: String(localized: "passport.feeling.loved", defaultValue: "loved", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .comforted?: String(localized: "passport.feeling.comforted", defaultValue: "comforted", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .playful?: String(localized: "passport.feeling.playful", defaultValue: "playful", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .calm?: String(localized: "passport.feeling.calm", defaultValue: "calm", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .frazzled?: String(localized: "passport.feeling.frazzled", defaultValue: "a little frazzled", comment: "Sprout's passport, Feeling field: the feeling in a word after the state, lower case mid-phrase")
        case .asleep?, nil: nil
        }
    }
}

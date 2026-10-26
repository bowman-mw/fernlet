//
//  CookingMode.swift
//  Fernlet
//
//  F5 cooking mode (decision §11.6): a full-screen, hands-on cooking flow launched from a recipe's
//  "Cook" action. It opens on a MISE EN PLACE screen (every ingredient + amount, scaled by the F4
//  engine when the cook picks a different yield), then walks one step per screen with an explicit
//  Next/Back pair and a per-step crossfade + progress dots (the GroundingView idiom). A step carrying
//  `durationSeconds` shows a PASSIVE countdown that, on expiry, highlights Next and fires a haptic
//  (plus a quiet chime when the cook turned "Timer sound" on) — it NEVER auto-advances the step. Next
//  and Back tick under the thumb, and finishing the cook plays one `done`. The finish screen offers
//  to log the meal, anchored to the day the cook BEGAN (a long session crossing midnight logs to the
//  start day). No Live Activity / Siri here — that is the next phase.
//

import SwiftUI
import FernletDomainModel
import FoodCatalog
#if canImport(UIKit)
import FernletUI
import UIKit
#endif

// MARK: - Cook availability gate

/// Decides whether a recipe gets a "Cook" action at all.
///
/// Shared by `RecipeDetailView` (which shows/hides the Cook button) so the availability rule lives
/// in one place; UIKit-free so it compiles on every platform slice of the target.
enum CookingModeAvailability {
    /// The "Cook" action shows only when there is something to cook through: authored steps, structured
    /// ingredients, or a web import's free-text ingredient lines (mise-en-place renders those as-is). A
    /// recipe with none of the three (e.g. a bare structured recipe with an empty ingredient list) gets
    /// no Cook action.
    static func canCook(_ recipe: RecipeDefinition) -> Bool {
        if let steps = recipe.steps, !steps.isEmpty { return true }
        if !recipe.ingredients.isEmpty { return true }
        if let lines = recipe.webImport?.ingredientLines, !lines.isEmpty { return true }
        return false
    }
}

/// One structured ingredient line as the recipe page and mise en place draw it: "118 g · Bananas,
/// raw". The amount and the food's name are data (the unit stays its token, as the recipe page shows
/// it); only the stand-in for a food the catalog can no longer resolve is copy, and it used to be an
/// English "Ingredient" in both screens.
enum RecipeIngredientLine {
    /// The line for `ingredient`, naming it `name`, or the localized stand-in when `name` is nil.
    static func text(_ ingredient: RecipeIngredient, name: String?) -> String {
        "\(ingredient.amountText) · \(displayName(name))"
    }

    /// The name an ingredient's compact row shows (World `.ingr` rows): `name`, or the localized
    /// stand-in when the food can't be found.
    static func displayName(_ name: String?) -> String {
        name ?? String(localized: "recipe.ingredient.unresolvedName", defaultValue: "Ingredient",
                       comment: "Stands in for the name of a recipe ingredient whose food can't be found, on the recipe page and in cooking mode")
    }
}

#if canImport(UIKit)

// MARK: - Keep-screen-awake modifier (first use of isIdleTimerDisabled in the app)

/// Keeps the screen awake while `isActive` and the scene is frontmost, restoring the system idle timer
/// on disappear or when the app backgrounds. Scoped tightly to two surfaces: the cooking-mode cover — a
/// cook reading a step shouldn't have the screen dim mid-recipe — and, while a run is live, the guided
/// workout runner (`GuidedWorkoutSheet`), so a phone on a bench does not lock mid-rest and silence the
/// runner's cues. We must never leave the idle timer disabled once they leave or background the app.
/// This is the app's ONLY `isIdleTimerDisabled` writer.
private struct KeepScreenAwakeModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { apply(isActive && scenePhase == .active) }
            .onDisappear { apply(false) }
            .onChange(of: isActive) { _, newValue in apply(newValue && scenePhase == .active) }
            .onChange(of: scenePhase) { _, newPhase in apply(isActive && newPhase == .active) }
    }

    private func apply(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

extension View {
    /// Keeps the screen awake while `active` (and the app is frontmost); restores the idle timer on
    /// disappear/background. A small reusable modifier — the first `isIdleTimerDisabled` use in the app.
    func keepsScreenAwake(_ active: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(isActive: active))
    }
}

// MARK: - Per-step timer editor control (recipe editor)

/// Compact optional-timer control for the recipe editor's Step rows. Edits `durationSeconds` in whole
/// minutes; "no timer" is represented as `nil` (a passive countdown needs a positive window).
struct StepTimerControl: View {
    @Binding var durationSeconds: Int?

    private var minutes: Int { max((durationSeconds ?? 0) / 60, 1) }

    /// World build (`b3-recipe-new`): the pixel clock, then "Add timer", or the minutes on the framed
    /// stepper with a pixel ✕ to take the timer off.
    var body: some View {
        HStack(spacing: 10) {
            WorldSpriteView(sprite: WorldSprites.clock, scale: 2)
            if durationSeconds == nil {
                Button("Add timer") { durationSeconds = 60 }
                    .font(FernletFramedFont.rowDetailBold)
                    .foregroundStyle(WorldPalette.mossInk)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("recipeEditor.step.addTimer")
                Spacer(minLength: 0)
            } else {
                Text("\(minutes) min timer")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                FernletStepper("\(minutes) min timer",
                               value: Binding(get: { minutes }, set: { durationSeconds = max($0, 1) * 60 }),
                               in: 1...240, step: 1)
                Button { durationSeconds = nil } label: {
                    FernletIcon(.close, scale: 2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fernletIconButton("Remove timer")
            }
        }
    }
}

// MARK: - Cooking mode

/// The F5 full-screen cooking flow: mise en place (with F4 "cook for N" scaling) → a one-step-per-
/// screen walker with an explicit Next/Back pair and a passive per-step countdown → a finish screen
/// that offers to log the meal to the day the cook began.
///
/// The World build draws it as a focused flow (``FernletFocusedFlow``; `b3-cook-mise`, `b3-cook-step`,
/// `b3-cook-finish`, approved 2026-10-24): no grabber, the ✕ top right (it was "Close" on the left),
/// the compact ingredient rows of the recipe page, the wooden Start cooking, pixel progress squares,
/// and Log this meal as one meal-type menu.
///
/// Presented as a full-screen cover from `RecipeDetailView` (fresh cook) and the Food-root resume
/// card (`resuming: true`, jumping straight into the walker). Once a run starts, the SHARED
/// `store.cookingRunState` is authoritative — its frozen step snapshot, cursor, and fixed timer
/// window drive the walker, so an advance made from the Live Activity or Siri re-renders this view
/// in step (reconciled from the app group on appear/foreground). Only the "timer fired" flag and its
/// haptic task are local UI state. Keeps the screen awake while frontmost (the app's only
/// `isIdleTimerDisabled` writer, via `KeepScreenAwakeModifier`), and a timer expiry highlights
/// Next + fires a haptic but NEVER auto-advances.
struct CookingModeView: View {
    let store: FernletStore
    let recipe: RecipeDefinition
    /// Logs the finished meal, anchored to the day-key captured at session START. Routed per call site to
    /// the right store method (manual `logRecipe` vs saved/web `logSavedRecipe`), each of which takes a
    /// `date:` day-key so a session crossing midnight still logs to the day the cook began.
    let onLogToDay: (MealType, String) -> Void
    /// True when re-opening an in-progress run after a kill (the Food-root resume card path): skip mise
    /// en place and jump straight into the walker at the run's saved step. The store already holds the
    /// adopted `cookingRunState`, so we must NOT start a fresh run.
    let resuming: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The user's term of address (the app root sets it from the body profile): "I'm ready" and the
    /// timer's "when you're ready" describe the cook, and Spanish agrees them (*lista*).
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    /// The cover's three screens: mise en place, the step walker, and the finish/log screen.
    ///
    /// Local presentation state layered over the shared run — `syncStageWithRun` maps run
    /// transitions (finished, retired) onto it.
    private enum Stage: Equatable { case mise, cooking, finished }

    @State private var stage: Stage
    @State private var cookYield: Int
    @State private var resolvedItems: [UUID: FoodItem] = [:]
    /// Fallback day-key for the mise-ONLY path (a recipe with no steps starts no run). Stamped in
    /// `.onAppear`. When a run exists its `startedDayKey` is authoritative, so a long session that rolls
    /// past midnight still logs to the day the cook began.
    @State private var startDayKey: String?

    // Single per-step passive timer (v1 — no concurrent named timers). The FIXED timer WINDOW lives in
    // the shared `store.cookingRunState` (so the Live Activity renders it); only the "fired" flag +
    // haptic task are local UI state, re-armed from the run's window on every change and on resume.
    @State private var timerFired = false
    @State private var timerTask: Task<Void, Never>?
    /// Drives the "stop cooking?" confirmation in front of Close during an active walk — closing used
    /// to end the run and clear the Live Activity on a single tap.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// Follows the walk: VoiceOver lands on the new step's text every time the cursor moves.
    ///
    /// `.id(stepIndex)` gives the step text a fresh identity on every advance, which tears down the
    /// element the user was focused on. Without this the cursor falls back to the top of the screen
    /// and a wet-handed cook has to swipe past the footer, the progress row and the timer card after
    /// every single Next — on the screen the app designates as the hands-busy one.
    @AccessibilityFocusState private var isStepFocused: Bool

    init(store: FernletStore, recipe: RecipeDefinition, resuming: Bool = false, initialYield: Int? = nil, onLogToDay: @escaping (MealType, String) -> Void) {
        self.store = store
        self.recipe = recipe
        self.resuming = resuming
        self.onLogToDay = onLogToDay
        // Carry the recipe detail's "Cook for N" into mise en place so the cook doesn't re-enter it; clamp
        // to the scaler's range, and fall back to the recipe's base yield when none was passed (or resume).
        _cookYield = State(initialValue: RecipeScaling.clampedYield(initialYield ?? max(recipe.servings, 1)))
        _stage = State(initialValue: resuming ? .cooking : .mise)
    }

    /// The steps the walker renders. While a run is active (including a resume), the AUTHORITATIVE walk is
    /// the run's own frozen snapshot (`store.cookingRunState.steps`) — the cursor, the Live Activity, and
    /// the App-Intent "Next" all advance against it. Rendering `recipe.steps` instead would desync the
    /// text from the cursor if the recipe was edited (same device, or a synced edit) after the run began —
    /// worst case a since-shortened recipe shows "Step 1 of 0" while the run still walks its snapshot.
    /// Before a run exists (the mise screen) there is nothing frozen yet, so fall back to the recipe.
    private var steps: [RecipeStep] {
        if let runSteps = store.cookingRunState?.steps {
            return runSteps.map { RecipeStep(text: $0.text, durationSeconds: $0.durationSeconds) }
        }
        // Making order (a multipart recipe's first part, then the next), exactly what a run will walk.
        return recipe.cookingSteps.map(\.step)
    }

    /// A multipart recipe's parts with the ingredients as mise en place shows them (scaled or not);
    /// fewer than two means a one-part recipe, which renders its plain list.
    private var miseParts: [ResolvedRecipeComponent] {
        RecipePartsLayout.parts(of: recipe, displaying: displayIngredients)
    }
    private var hasSteps: Bool { !steps.isEmpty }
    private var isScalable: Bool { RecipeScaling.isScalable(recipe) }

    /// The current cursor, driven by the shared run so a Live Activity / Siri advance moves the walker.
    /// Falls back to 0 before the run exists (mise) and clamps into range defensively.
    private var stepIndex: Int {
        guard let index = store.cookingRunState?.stepIndex else { return 0 }
        return min(max(index, 0), max(steps.count - 1, 0))
    }

    /// The FIXED per-step timer window from the shared run (nil when no timer is running).
    private var timerStartedAt: Date? { store.cookingRunState?.timerStartedAt }
    private var timerEndsAt: Date? { store.cookingRunState?.timerEndsAt }

    /// Ingredients as shown on the mise screen — scaled to the cook-for yield for structured recipes,
    /// or the stored quantities otherwise. Empty for web imports (they render free-text lines instead).
    private var displayIngredients: [RecipeIngredient] {
        guard isScalable, cookYield != recipe.servings else { return recipe.ingredients }
        return RecipeScaling.scaledIngredients(recipe, forYield: cookYield)
    }

    /// World build: a focused flow (`b3-cook-mise`, `b3-cook-step`, `b3-cook-finish`, approved
    /// 2026-10-24): full screen on dotted parchment with no grabber, the recipe's name (or "Step N of M")
    /// top left and the framed ✕ top right, the stage below and its buttons at the bottom.
    var body: some View {
        FernletFocusedFlow(title: stageTitle, onClose: { closeCooking() }) {
            content
        } footer: {
            footer
        }
        .keepsScreenAwake(true)
        .destructiveConfirmation($pendingDestructiveAction)
        .task(id: recipe.ingredients.map(\.foodItemId)) {
            let ids = recipe.ingredients.map(\.foodItemId)
            guard !ids.isEmpty else { return }
            resolvedItems = Dictionary(
                store.foodCatalog.items(ids: ids).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        .onAppear {
            if startDayKey == nil { startDayKey = store.todayKey }
            // A resume can land after the Live Activity finished the cook while the app was gone; pick
            // that up and re-arm the local haptic to the run's live timer window.
            store.reconcileCookingRunFromAppGroup()
            syncStageWithRun()
            armHaptic(for: store.cookingRunState)
        }
        // The Live Activity "Next" / Siri "next step" advances the shared run in the background; on
        // foreground, reconcile then re-derive stage + haptic so the walker re-renders in step.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            store.reconcileCookingRunFromAppGroup()
            syncStageWithRun()
            armHaptic(for: store.cookingRunState)
        }
        // Discrete run transitions (in-app OR Live Activity, while foregrounded): keep stage + haptic
        // in step. The run changes only on step/timer transitions — never per second — so this is cheap.
        .onChange(of: store.cookingRunState) { _, newRun in
            syncStageWithRun()
            armHaptic(for: newRun)
        }
        .onDisappear { timerTask?.cancel() }
    }

    /// Reflect the shared run's terminal + liveness into the local stage: a run finished from the Live
    /// Activity flips the walker to its finish screen; a run retired out from under an active walk (aged
    /// out, or replaced by another recipe's cook) closes this cover so we never render an empty step.
    private func syncStageWithRun() {
        let run = store.cookingRunState
        if run?.isFinished == true {
            if stage == .cooking { withAnimation(.easeInOut(duration: 0.3)) { stage = .finished } }
        } else if run == nil, stage == .cooking {
            dismiss()
        }
    }

    // MARK: Header

    /// The header's title: the recipe's name, or the step position while walking. `Text`: as a
    /// `String` "Step 3 of 8" was drawn verbatim.
    private var stageTitle: Text {
        switch stage {
        case .mise, .finished: return Text(verbatim: recipe.name)
        case .cooking: return Text("Step \(stepIndex + 1) of \(steps.count)")
        }
    }

    // MARK: Content router

    @ViewBuilder private var content: some View {
        switch stage {
        case .mise: miseEnPlace
        case .cooking: cookingWalker
        case .finished: finishScreen
        }
    }

    /// The bottom row of each stage: the wooden Start cooking, the dots with Back and Next, or Log this
    /// meal with Not now.
    @ViewBuilder private var footer: some View {
        switch stage {
        case .mise:
            Button {
                beginCooking()
            } label: {
                hasSteps ? Text("Start cooking") : Text(AddressedCopy.attributed("I'm ready", addressing: termOfAddress))
            }
            .buttonStyle(RecipeWoodButtonStyle())
            .accessibilityIdentifier("cookingMode.start")
        case .cooking:
            walkerFooter
        case .finished:
            finishFooter
        }
    }

    // MARK: Mise en place

    private var miseEnPlace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mise en place")
                        .font(RecipeType.display(34))
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                    Text("Everything you'll need, laid out before you start.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                    if miseParts.count > 1, let first = miseParts.first?.name {
                        Text("Made in \(miseParts.count) parts. Start with \(first).")
                            .font(FernletFramedFont.body)
                            .foregroundStyle(WorldPalette.bark)
                            .fernletWrappingText()
                    }
                }
                if isScalable { cookForCard }
                FernletCard {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Ingredients")
                        ingredientList
                    }
                    // FernletCard hugs its content when nothing inside stretches, which left this
                    // card visibly narrower than the "Cook for" card above it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// "Cook for [− 2 servings +]" (`b3-cook-mise`), and the scaled note while it differs.
    private var cookForCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Cook for")
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    // Grammar agreement, never an English "s" picked by count.
                    FernletStepper("Cook for",
                                   value: Binding(get: { cookYield }, set: { cookYield = RecipeScaling.clampedYield($0) }),
                                   in: RecipeScaling.yieldRange, step: 1,
                                   display: Text("^[\(cookYield) serving](inflect: true)"))
                        .accessibilityIdentifier("cookingMode.cookForYield")
                }
                if cookYield != recipe.servings {
                    Text("Scaled from ^[\(recipe.servings) serving](inflect: true) — amounts below adjust to match. Logging still records one serving.")
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                }
            }
        }
    }

    @ViewBuilder private var ingredientList: some View {
        if let webImport = recipe.webImport, !webImport.ingredientLines.isEmpty {
            // Web imports have free-text lines and no structured quantities to scale — render as-is.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(webImport.ingredientLines, id: \.self) { line in
                    RecipeIngredientRow(name: line, amount: "")
                }
            }
        } else if miseParts.count > 1 {
            // A multipart recipe lays each part's ingredients out under its own heading.
            RecipePartsIngredientList(parts: miseParts) { ingredientRow($0) }
        } else if !displayIngredients.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayIngredients) { ingredientRow($0) }
            }
        } else {
            Text("No ingredients listed.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
        }
    }

    /// One ingredient as the recipe page's compact row (icon, name, amount); a household amount read
    /// from the curated table keeps its "USDA typical size, estimate" note (F4b fix round 1, finding
    /// s2-L-F4b-DT-2).
    private func ingredientRow(_ ingredient: RecipeIngredient) -> some View {
        let name = resolvedItems[ingredient.foodItemId]?.name
        return RecipeIngredientRow(
            name: RecipeIngredientLine.displayName(name), amount: ingredient.amountText, artName: name,
            note: isTypicalSizeEstimate(ingredient) ? AnyView(RecipeTypicalSizeEstimateNote()) : nil
        ) { EmptyView() }
    }

    /// Whether the line's household amount is a USDA typical size rather than the food's own portion.
    private func isTypicalSizeEstimate(_ ingredient: RecipeIngredient) -> Bool {
        resolvedItems[ingredient.foodItemId].map(ingredient.isTypicalSizeEstimate(using:)) ?? false
    }

    // MARK: Cooking walker

    private var cookingWalker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let step = currentStep {
                    if let part = store.cookingRunState?.currentPart {
                        // Which part of a multipart recipe this step belongs to ("make the dressing
                        // first"). Read as part of the step's own label below, so hidden here.
                        Text("Part \(part.position) of \(part.count) · \(part.name)")
                            .font(FernletFramedFont.noteBold)
                            .foregroundStyle(WorldPalette.mossInk)
                            .fernletWrappingText()
                            .accessibilityHidden(true)
                    }
                    Text(step.text)
                        .font(RecipeType.display(30))
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The step is this screen's heading, so it lands in the Headings rotor,
                        // and it carries its own position: the "Step 3 of 8" in the header is a
                        // separate element the cook would have to go looking for.
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(stepAccessibilityLabel(step))
                        .accessibilityFocused($isStepFocused)
                        .transition(.opacity)
                        .id(stepIndex)

                    if let duration = step.durationSeconds, duration > 0 {
                        stepTimer(duration: duration)
                    }

                    // Mise en place scales ingredient amounts to the cook-for yield, but a step's PROSE
                    // ("add 200 g flour") is authored text we don't rescale — so when cooking at a
                    // different yield, say so once rather than let the step quietly disagree with the
                    // scaled ingredient list. (A substitution fork's steps still name the swapped-out
                    // ingredient for the same reason — a documented, accepted tradeoff.)
                    if isScalable, cookYield != recipe.servings {
                        Text("Amounts written into the steps reflect the original \(recipe.servings)-serving recipe, not the \(cookYield)-serving scale above.")
                            .font(FernletFramedFont.note)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        // Driven from the CURSOR, never from `goNext()`: at the moment the button's action runs, the
        // step view for the new index does not exist yet, so a focus request there lands on nothing.
        // `onChange` also covers the advances this screen does not originate — the Live Activity's
        // Next and Siri's "next step" both move the shared run in the background.
        .onChange(of: stepIndex) { _, _ in isStepFocused = true }
    }

    private var currentStep: RecipeStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    /// The step's VoiceOver label: its position, and for a multipart recipe its part first, because focus
    /// lands on the step text on every advance and would otherwise skip the part banner above it.
    private func stepAccessibilityLabel(_ step: RecipeStep) -> Text {
        guard let part = store.cookingRunState?.currentPart else {
            return Text("Step \(stepIndex + 1) of \(steps.count). \(step.text)")
        }
        return Text("\(part.name), part \(part.position) of \(part.count). Step \(stepIndex + 1) of \(steps.count). \(step.text)")
    }

    /// The step's timer in a framed card (`b3-cook-step`): the big Fraunces time, Start (or Reset once
    /// it runs), the "timer's up" line, and the Timer sound switch.
    private func stepTimer(duration: Int) -> some View {
        FernletCard {
            VStack(spacing: 12) {
                if let started = timerStartedAt, let ends = timerEndsAt, started <= ends {
                    // GuidedWorkout idiom: a fixed window clamps to 0:00 at expiry and stays valid however
                    // long the cook over-runs it — a live `Date()` lower bound would invert past the deadline.
                    Text(timerInterval: started...ends, countsDown: true)
                        .font(FernletFramedFont.bigTime)
                        .monospacedDigit()
                        .foregroundStyle(timerFired ? Color.goldenrod : WorldPalette.bark)
                        .accessibilityIdentifier("cookingMode.stepTimer")
                    if timerFired {
                        AddressedText("Timer's up — tap Next when you're ready. Nothing advances on its own.")
                            .font(FernletFramedFont.note)
                            .foregroundStyle(WorldPalette.dim)
                            .multilineTextAlignment(.center)
                            .fernletWrappingText()
                    }
                    Button { store.cookingClearTimer() } label: { Text("Reset timer").frame(maxWidth: .infinity) }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                } else {
                    FernletBigTime(Text(formattedDuration(duration)))
                    Button { store.cookingStartTimer() } label: {
                        Text("Start \(formattedDuration(duration)) timer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier("cookingMode.startStepTimer")
                }
                // The shortcut to Settings › Sounds & haptics' cooking switch, on the card it changes.
                CookingTimerSoundToggle()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The pixel progress squares, then Back and Next (`b3-cook-step`). Next carries a sun ring once
    /// the step's timer is up; it never advances on its own.
    private var walkerFooter: some View {
        VStack(spacing: 12) {
            progressDots
            AdaptiveStack(spacing: 10) {
                Button { goBack() } label: {
                    secondaryLabel("Back")
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("cookingMode.back")

                Button { goNext() } label: {
                    Group {
                        if stepIndex == steps.count - 1 { Text("Finish") } else { Text("Next") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .overlay {
                    if timerFired {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.goldenrod, lineWidth: 3).padding(-4)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("cookingMode.next")
            }
        }
    }

    /// A dot row reads well only for short recipes; web imports routinely carry 20–40 steps, where a
    /// fixed-size unbounded HStack of dots runs off-screen. Above the threshold fall back to a compact
    /// framed progress bar + "n / total" label that fits any step count.
    private static let maxProgressDots = 12

    @ViewBuilder
    private var progressDots: some View {
        if steps.count <= Self.maxProgressDots {
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Rectangle()
                        .fill(index <= stepIndex ? WorldPalette.moss : WorldPalette.paperLight)
                        .frame(width: 10, height: 10)
                        .overlay(Rectangle().strokeBorder(WorldPalette.ink, lineWidth: 2))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: stepIndex)
            .accessibilityHidden(true)
        } else {
            compactProgressBar
        }
    }

    private var compactProgressBar: some View {
        let total = max(steps.count, 1)
        let fraction = Double(stepIndex + 1) / Double(total)
        return HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(WorldPalette.barEmpty)
                    Rectangle()
                        .fill(WorldPalette.moss)
                        .frame(width: max(6, proxy.size.width * fraction))
                }
                .overlay(Rectangle().strokeBorder(WorldPalette.ink, lineWidth: 2))
            }
            .frame(height: 10)
            Text("\(stepIndex + 1) / \(total)")
                .font(FernletFramedFont.rowDetailBold)
                .foregroundStyle(WorldPalette.dim)
                .monospacedDigit()
        }
        .animation(.easeInOut(duration: 0.35), value: stepIndex)
    }

    // MARK: Finish

    /// "All done." under a gold medal (`b3-cook-finish`), centred in the flow.
    private var finishScreen: some View {
        ScrollView {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(WorldPalette.ink.opacity(0.22)).offset(y: 4)
                    Circle().fill(WorldPalette.rgb(0xF2D58A))
                    Circle().strokeBorder(WorldPalette.ink, lineWidth: 3)
                    WorldSpriteView(sprite: WorldSprites.stampMed, scale: 4)
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                Text("All done.")
                    .font(RecipeType.display(34))
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                Text("Nicely cooked. Want to log \(recipe.name) as a meal?")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 96)
        }
    }

    /// Log this meal as one menu of meal types (owner, 2026-10-24: meal type is one dropdown), then a
    /// quiet Not now.
    private var finishFooter: some View {
        VStack(spacing: 6) {
            Menu {
                ForEach(MealType.allCases) { mealType in
                    Button { logMeal(mealType) } label: { Text(verbatim: mealType.displayName) }
                }
            } label: {
                primaryButtonLabel(Text("Log this meal"))
            }
            .menuStyle(.button)
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("cookingMode.logMeal")
            Button { closeCooking() } label: {
                Text("Not now")
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(WorldPalette.mossInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Shared bits

    /// The primary's word with the dropdown's chevron, full width. A `Text` the caller builds, never
    /// `String` (as `String` the "Start cooking", "Log this meal" and "Back" labels were drawn
    /// verbatim): `Text("…")` extracts like any literal.
    private func primaryButtonLabel(_ title: Text) -> some View {
        HStack(spacing: 8) {
            title
            FernletIcon(.chevronDown, scale: 2, tint: WorldPalette.onAccent)
        }
        .frame(maxWidth: .infinity)
    }

    /// Back's pixel arrow and word, full width.
    private func secondaryLabel(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 7) {
            FernletIcon(.back, scale: 2)
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Navigation

    private func beginCooking() {
        if hasSteps {
            // Start the shared run FIRST (mirrors to the app group + requests the Live Activity), then
            // flip the walker in. The run's cursor drives `stepIndex` from here on.
            store.startCookingRun(recipe, startDayKey: startDayKey ?? store.todayKey)
            withAnimation(.easeInOut(duration: 0.3)) { stage = .cooking }
        } else {
            // Mise-only recipe (ingredients but no steps): a single done screen, per §6.4. No run, no
            // Live Activity — there is nothing to walk. "I'm ready" is this cook's whole walk, so the
            // "All done." screen gets the same one `done` as a walked cook's Finish.
            withAnimation(.easeInOut(duration: 0.3)) { stage = .finished }
            FernletFeedback.system.play(.done)
        }
    }

    private func goNext() {
        // Advance the shared run (clears its timer, advances the cursor, or finishes on the last step).
        // A finish flips `stage` via `syncStageWithRun` on the resulting run change.
        let before = store.cookingRunState
        withAnimation(.easeInOut(duration: 0.3)) { store.cookingAdvanceStep() }
        playWalkerCue(from: before)
    }

    private func goBack() {
        let before = store.cookingRunState
        if stepIndex > 0 {
            withAnimation(.easeInOut(duration: 0.3)) { store.cookingGoBack() }
        } else {
            // Back from the first step leaves the walk and returns to mise en place. Set the stage
            // BEFORE ending the run, so the run→nil change doesn't trip `syncStageWithRun`'s
            // "retired mid-walk" dismiss.
            withAnimation(.easeInOut(duration: 0.3)) { stage = .mise }
            store.endCookingRun()
        }
        playWalkerCue(from: before)
    }

    /// The walker's touch cue for the tap that just moved the run from `before`
    /// (``walkerCue(before:after:)``). Played from the tap, never from the run changing: a Live
    /// Activity or Siri "Next" moves the same run from the background, and a Lock Screen finish is
    /// reconciled later — neither is a tap under the cook's thumb, and a `done` at that reconcile
    /// would arrive minutes late.
    private func playWalkerCue(from before: CookingRunState?) {
        guard let event = Self.walkerCue(before: before, after: store.cookingRunState) else { return }
        FernletFeedback.system.play(event)
    }

    /// What one Next or Back tap plays (sounds-and-haptics Tier B, 2026-10-20): `tick` when the step
    /// moved — a cook with wet hands and their eyes on the bowl feels the page turn — `done` once when
    /// the tap finished the cook, as "All done." appears, and nothing when the tap changed nothing (a
    /// second tap on Finish while the screen crossfades finds the run already finished).
    ///
    /// Leaving the walk for mise en place (Back on the first step ends the run) counts as a move.
    static func walkerCue(before: CookingRunState?, after: CookingRunState?) -> FernletFeedbackEvent? {
        guard let before, !before.isFinished else { return nil }
        if after?.isFinished == true { return .done }
        return after?.stepIndex == before.stepIndex ? nil : .tick
    }

    private func logMeal(_ mealType: MealType) {
        // A run's own `startedDayKey` is authoritative (survives a midnight rollover); the local
        // `startDayKey` is the fallback for the mise-only path that never started a run.
        let day = store.cookingRunState?.startedDayKey ?? startDayKey ?? store.todayKey
        onLogToDay(mealType, day)
        store.endCookingRun()
        dismiss()
    }

    /// Header Close / finish "Not now": end the shared run (clear the app-group file + the Live Activity)
    /// so no orphan resume card or activity lingers, then dismiss.
    ///
    /// Mid-walk it asks first — closing there throws away the cook's place in the steps, which is the
    /// same thing the Move tab's workout runner confirms before doing. Mise en place and the finish
    /// screen have nothing to lose, so they close straight away.
    private func closeCooking() {
        guard stage == .cooking else {
            endRunAndDismiss()
            return
        }
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Stop cooking \(recipe.name)?",
            message: "Your place in the steps is forgotten and the Live Activity is cleared. The recipe itself is untouched.",
            confirmLabel: "Stop cooking",
            auditEvent: "cooking.run.closeConfirmed",
            perform: { endRunAndDismiss() }
        )
    }

    private func endRunAndDismiss() {
        store.endCookingRun()
        dismiss()
    }

    // MARK: Timer

    /// (Re)arm the local haptic + "fired" highlight to the shared run's FIXED timer window. Called on
    /// appear, on every run change, and on foreground — so it works for an in-app start, a Siri "repeat
    /// step", and a resume that lands with a timer already partway through (or already expired).
    private func armHaptic(for run: CookingRunState?) {
        timerTask?.cancel()
        timerTask = nil
        guard let start = run?.timerStartedAt, let end = run?.timerEndsAt, start <= end else {
            timerFired = false
            return
        }
        // The window comes back from the shared app-group run state (written by the app AND by the
        // Live Activity / intent extension), so validate it here like every other timer input:
        // a non-finite end date is "no timer", and the wait is clamped to the editor's own maximum.
        let untilEnd = end.timeIntervalSinceNow
        guard untilEnd.isFinite else {
            timerFired = false
            return
        }
        if untilEnd <= 0 {
            // Resumed after the timer already elapsed: highlight Next, but don't fire a late haptic.
            timerFired = true
            return
        }
        let remaining = min(untilEnd, Self.maxTimerWindowSeconds)
        timerFired = false
        timerTask = Task {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                // Re-armed, or the cover disappeared: the newer arm (or nothing) owns the haptic.
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                timerFired = true
                // A15: the freshness check runs AFTER the sleep too. A `.task` sleep keeps counting
                // while the app is suspended and wakes the moment it resumes, so the check before the
                // sleep alone let a cook who came back minutes later get a buzz for a moment long
                // gone. Next still turns goldenrod — the visual twin — either way.
                guard Self.signalsExpiry(endingAt: end, now: Date()) else { return }
                signalTimerExpiry()
            }
        }
    }

    /// Whether a timer that ended at `end` may still be signalled at `now`: the guided runner's
    /// lateness rule (`GuidedRunCuePlan.isOnTime`, 2 s), so "time's up" means the same thing in the
    /// kitchen as on the bench.
    static func signalsExpiry(endingAt end: Date, now: Date) -> Bool {
        GuidedRunCuePlan.isOnTime(end, now: now)
    }

    /// The longest passive countdown this view will wait out — the same 240-minute ceiling the
    /// recipe editor's ``StepTimerControl`` stepper enforces, applied again to the app-group run
    /// state so an absurd `timerEndsAt` can't schedule an unbounded sleep.
    private static let maxTimerWindowSeconds: TimeInterval = 240 * 60

    /// The timer's expiry, in the channels a cook with their hands in a bowl can receive: the "time's
    /// up" haptic, the quiet chime when "Timer sound" is on, and one spoken sentence — with Next
    /// turning goldenrod and the card's "Timer's up" line as the visual twin.
    ///
    /// The haptic is FernletFeedback's `timerEnded` — the same "time's up" as a rest or a hold running
    /// out (A15), no longer the success pattern, which means "a task you started succeeded". The chime
    /// is the runner's own, behind cooking's own switch (``CookingCuePreferences``, report C1), read
    /// now so a change made mid-cook reaches this timer. The words are the SAME catalog key the card
    /// above already renders — one sentence, one key, translated once: a near-duplicate written for
    /// the announcement could drift from the one on screen and leave a translator guessing which is
    /// authoritative.
    private func signalTimerExpiry() {
        FernletFeedback.system.play(.timerEnded, preferences: CookingCuePreferences.current())
        FernletAnnouncer.system.announce(
            .status,
            LocalizedStringResource("Timer's up — tap Next when you're ready. Nothing advances on its own."),
            addressing: termOfAddress
        )
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#endif

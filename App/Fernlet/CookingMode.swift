//
//  CookingMode.swift
//  Fernlet
//
//  F5 cooking mode (decision §11.6): a full-screen, hands-on cooking flow launched from a recipe's
//  "Cook" action. It opens on a MISE EN PLACE screen (every ingredient + amount, scaled by the F4
//  engine when the cook picks a different yield), then walks one step per screen with an explicit
//  Next/Back pair and a per-step crossfade + progress dots (the GroundingView idiom). A step carrying
//  `durationSeconds` shows a PASSIVE countdown that, on expiry, highlights Next and fires a haptic —
//  it NEVER auto-advances the step. The finish screen offers to log the meal, anchored to the day the
//  cook BEGAN (a long session crossing midnight logs to the start day). No Live Activity / Siri here —
//  that is the next phase.
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

#if canImport(UIKit)

// MARK: - Keep-screen-awake modifier (first use of isIdleTimerDisabled in the app)

/// Keeps the screen awake while `isActive` and the scene is frontmost, restoring the system idle timer
/// on disappear or when the app backgrounds. Scoped tightly to the cooking-mode cover — a cook reading a
/// step shouldn't have the screen dim mid-recipe, but we must never leave the idle timer disabled once
/// they leave or background the app. This is the app's ONLY `isIdleTimerDisabled` writer.
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(Color.slate)
            if durationSeconds == nil {
                Button("Add timer") { durationSeconds = 60 }
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recipeEditor.step.addTimer")
            } else {
                Stepper(
                    "\(minutes) min timer",
                    value: Binding(get: { minutes }, set: { durationSeconds = max($0, 1) * 60 }),
                    in: 1...240
                )
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
                Button { durationSeconds = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.slate.opacity(0.6))
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
        return recipe.steps ?? []
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

    var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.bark.opacity(0.08))
                content
            }
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

    private var header: some View {
        HStack {
            Button { closeCooking() } label: {
                Text("Close")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
            }
            .accessibilityIdentifier("cookingMode.close")
            Spacer()
            Text(stageTitle)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer()
            // Balance the leading "Close" so the title stays centered.
            Text("Close").font(.fernlet(.label)).foregroundStyle(.clear).accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stageTitle: String {
        switch stage {
        case .mise: return recipe.name
        case .cooking: return "Step \(stepIndex + 1) of \(steps.count)"
        case .finished: return recipe.name
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

    // MARK: Mise en place

    private var miseEnPlace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mise en place")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)
                    Text("Everything you'll need, laid out before you start.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }

                if isScalable {
                    FernletCard {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Cook for")
                            Stepper(
                                "\(cookYield) serving\(cookYield == 1 ? "" : "s")",
                                value: Binding(get: { cookYield }, set: { cookYield = RecipeScaling.clampedYield($0) }),
                                in: RecipeScaling.yieldRange
                            )
                            .accessibilityIdentifier("cookingMode.cookForYield")
                            if cookYield != recipe.servings {
                                Text("Scaled from \(recipe.servings) serving\(recipe.servings == 1 ? "" : "s") — amounts below adjust to match. Logging still records one serving.")
                                    .font(.fernlet(.bodySmall))
                                    .foregroundStyle(Color.slate)
                                    .fernletWrappingText()
                            }
                        }
                    }
                }

                FernletCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Ingredients")
                        ingredientList
                    }
                    // FernletCard hugs its content when nothing inside stretches, which left this
                    // card visibly narrower than the "Cook for" card above it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            primaryBar {
                Button {
                    beginCooking()
                } label: {
                    primaryButtonLabel(hasSteps ? "Start cooking" : "I'm ready")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cookingMode.start")
            }
        }
    }

    @ViewBuilder private var ingredientList: some View {
        if let webImport = recipe.webImport, !webImport.ingredientLines.isEmpty {
            // Web imports have free-text lines and no structured quantities to scale — render as-is.
            ForEach(webImport.ingredientLines, id: \.self) { line in
                ingredientRow(line)
            }
        } else if !displayIngredients.isEmpty {
            ForEach(displayIngredients) { ingredient in
                ingredientRow(ingredientLine(ingredient))
            }
        } else {
            Text("No ingredients listed.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
        }
    }

    private func ingredientRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.moss.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
    }

    private func ingredientLine(_ ingredient: RecipeIngredient) -> String {
        let quantity = ingredient.quantity.formatted(.number.precision(.fractionLength(0...1)))
        let name = resolvedItems[ingredient.foodItemId]?.name ?? "Ingredient"
        return "\(quantity) \(ingredient.unit) · \(name)"
    }

    // MARK: Cooking walker

    private var cookingWalker: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let step = currentStep {
                        Text(step.text)
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                                .font(.fernlet(.bodySmall))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(24)
            }
            walkerFooter
        }
    }

    private var currentStep: RecipeStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    private func stepTimer(duration: Int) -> some View {
        FernletCard {
            VStack(spacing: 12) {
                if let started = timerStartedAt, let ends = timerEndsAt, started <= ends {
                    // GuidedWorkout idiom: a fixed window clamps to 0:00 at expiry and stays valid however
                    // long the cook over-runs it — a live `Date()` lower bound would invert past the deadline.
                    // The design system's timer face (DM Sans, monospaced digits) rather than SF
                    // Rounded — this was the app's largest piece of system-font text.
                    Text(timerInterval: started...ends, countsDown: true)
                        .font(.fernletTimer())
                        .foregroundStyle(timerFired ? Color.goldenrod : Color.bark)
                        .accessibilityIdentifier("cookingMode.stepTimer")
                    if timerFired {
                        Text("Timer's up — tap Next when you're ready. Nothing advances on its own.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .multilineTextAlignment(.center)
                            .fernletWrappingText()
                    }
                    Button { store.cookingClearTimer() } label: {
                        Text("Reset timer").font(.fernlet(.labelSmall)).foregroundStyle(Color.moss)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(formattedDuration(duration))
                        .font(.fernletTimer(size: 44))
                        .foregroundStyle(Color.slate)
                    Button { store.cookingStartTimer() } label: {
                        Label("Start \(formattedDuration(duration)) timer", systemImage: "timer")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.onMoss)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.moss, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cookingMode.startStepTimer")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var walkerFooter: some View {
        VStack(spacing: 14) {
            progressDots
            HStack(spacing: 12) {
                Button { goBack() } label: {
                    secondaryLabel("Back", icon: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cookingMode.back")

                Button { goNext() } label: {
                    HStack(spacing: 6) {
                        Text(stepIndex == steps.count - 1 ? "Finish" : "Next")
                        Image(systemName: "chevron.right")
                    }
                    .font(.fernlet(.label))
                    // Each fill carries its own ink: `onGoldenrod` on the timer-fired amber,
                    // `onMoss` on the moss. Cream on goldenrod measured ~2.2:1.
                    .foregroundStyle(timerFired ? Color.onGoldenrod : Color.onMoss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(timerFired ? Color.goldenrod : Color.moss, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cookingMode.next")
            }
        }
        .padding(20)
        .background(Color.parchment)
    }

    /// A dot row reads well only for short recipes; web imports routinely carry 20–40 steps, where a
    /// fixed-size unbounded HStack of dots runs off-screen. Above the threshold fall back to a compact
    /// capsule progress bar + "n / total" label that fits any step count.
    private static let maxProgressDots = 12

    @ViewBuilder
    private var progressDots: some View {
        if steps.count <= Self.maxProgressDots {
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index <= stepIndex ? Color.moss : Color.moss.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: stepIndex)
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
                    Capsule().fill(Color.moss.opacity(0.25))
                    Capsule()
                        .fill(Color.moss)
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text("\(stepIndex + 1) / \(total)")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .monospacedDigit()
        }
        .animation(.easeInOut(duration: 0.35), value: stepIndex)
    }

    // MARK: Finish

    private var finishScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Color.moss)
                Text("All done.")
                    .font(.fernlet(.displayMedium))
                    .foregroundStyle(Color.bark)
                Text("Nicely cooked. Want to log \(recipe.name) as a meal?")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            primaryBar {
                VStack(spacing: 10) {
                    Menu {
                        ForEach(MealType.allCases) { mealType in
                            Button { logMeal(mealType) } label: { Text(verbatim: mealType.displayName) }
                        }
                    } label: {
                        primaryButtonLabel("Log this meal")
                    }
                    .accessibilityIdentifier("cookingMode.logMeal")
                    Button { closeCooking() } label: {
                        Text("Not now")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.slate)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Shared bits

    private func primaryBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(Color.parchment)
    }

    private func primaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
    }

    private func secondaryLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.fernlet(.label))
        .foregroundStyle(Color.moss)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
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
            // Live Activity — there is nothing to walk.
            withAnimation(.easeInOut(duration: 0.3)) { stage = .finished }
        }
    }

    private func goNext() {
        // Advance the shared run (clears its timer, advances the cursor, or finishes on the last step).
        // A finish flips `stage` via `syncStageWithRun` on the resulting run change.
        withAnimation(.easeInOut(duration: 0.3)) { store.cookingAdvanceStep() }
    }

    private func goBack() {
        if stepIndex > 0 {
            withAnimation(.easeInOut(duration: 0.3)) { store.cookingGoBack() }
        } else {
            // Back from the first step leaves the walk and returns to mise en place. Set the stage
            // BEFORE ending the run, so the run→nil change doesn't trip `syncStageWithRun`'s
            // "retired mid-walk" dismiss.
            withAnimation(.easeInOut(duration: 0.3)) { stage = .mise }
            store.endCookingRun()
        }
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
                fireHaptic()
            }
        }
    }

    /// The longest passive countdown this view will wait out — the same 240-minute ceiling the
    /// recipe editor's ``StepTimerControl`` stepper enforces, applied again to the app-group run
    /// state so an absurd `timerEndsAt` can't schedule an unbounded sleep.
    private static let maxTimerWindowSeconds: TimeInterval = 240 * 60

    private func fireHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#endif

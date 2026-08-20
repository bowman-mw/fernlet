// FernletLockGate.swift
// Fernlet
//
// View modifier that gates content behind FernletLock.
// On appear -> if locked, overlay the unlock screen.
// On disappear -> call lock(reason: .viewDisappeared), scrubbing the in-memory content key.
//
// SwiftUI does not fire `.onDisappear` on the underlying gated view when a `.sheet`
// is presented over it, so child sheets can be shown without re-locking the gate.
//
// When Face ID is triggered, iOS briefly transitions the scene to `.inactive` then back
// to `.active`. On page-style TabViews this can fire spurious onDisappear/onAppear events.
// If onDisappear fires while the gate is unlocked (right after biometric succeeds), it would
// re-lock and recreate FernletLockView — triggering Face ID again in a loop. To prevent this,
// re-locking on viewDisappeared is suppressed during and briefly after scene transitions.

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletUI

// MARK: - Gate copy

/// The gate's own copy: its set-up call to action, the reset confirmation, and the two alerts it
/// raises after the fact.
///
/// Resolved against `bundle: .module` for the reason spelled out on ``FernletLockCopy``: a literal
/// written into a SwiftUI view inside a PACKAGE module is harvested into this module's catalog but
/// looked up in `Bundle.main`, so it would render untranslated English forever without anything
/// failing. It lives out here rather than inline because `body(content:)` is a lifecycle wrapper
/// already near the 60-line ceiling (Power of 10 R4), and three of these lines are paragraphs.
///
/// Everything below the call to action is DESTRUCTIVE or reports a loss that already happened. The
/// reset confirmation is the last chance to not destroy the sealed notes; the two alerts are told
/// after the fact and cannot be declined. A translation that reads as routine housekeeping would
/// strip the one warning the user gets. The shared verbs ("Reset app lock", "Cancel", "OK") come
/// from ``FernletLockCopy/Action`` so the same button never drifts between the dialog here and the
/// cards in ``FernletLockView``.
private enum GateCopy {
    /// The not-configured overlay's heading and its button — deliberately the same words twice on
    /// one screen, so one key rather than two that could drift apart.
    static var setUpCallToAction: String {
        String(localized: "lock.gate.setUpCallToAction", defaultValue: "Set up app lock", bundle: .module,
               comment: "Heading and button on the overlay shown when a private screen is opened before any app-lock passcode exists. Both use this one string.")
    }

    /// Title of the confirmation that stands between the user and a destructive reset.
    static var resetConfirmTitle: String {
        String(localized: "lock.reset.confirm.title", defaultValue: "Reset app lock?", bundle: .module,
               comment: "Title of the confirmation dialog for resetting the app lock. Keep it a question — it is the last chance to back out.")
    }

    /// What the reset costs, named before it happens.
    static var resetConfirmMessage: String {
        String(localized: "lock.reset.confirm.message",
               defaultValue: "Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.",
               bundle: .module,
               comment: "Message in the reset confirmation dialog. 'Permanently unreadable' is literal — there is no recovery. The second sentence is the one thing that survives and must stay accurate: the clinical samples in Apple Health are untouched.")
    }

    /// Title of the nothing-silent alert after a reset that could not finish cleanly.
    static var resetRebuildFailedTitle: String {
        String(localized: "lock.reset.rebuildFailed.title", defaultValue: "App lock reset", bundle: .module,
               comment: "Title of the alert shown after the app lock was reset but the sealed store could not be recreated. Statement of fact, not a question.")
    }

    /// What happened, and the one thing the user can do about it.
    static var resetRebuildFailedMessage: String {
        String(localized: "lock.reset.rebuildFailed.message",
               defaultValue: "Your app lock and its notes were destroyed, but the sealed store could not be rebuilt. Please relaunch Fernlet.",
               bundle: .module,
               comment: "Message of the alert shown when the reset destroyed the passcode and the notes but could not recreate the empty sealed store. Both halves are true and neither may be dropped: the data really is gone, and the app needs relaunching. 'Fernlet' is the app's name.")
    }

    /// Title of the one-shot disclosure owed to installs migrated onto hard Secure-Enclave binding.
    static var hardBindingTitle: String {
        String(localized: "lock.hardBinding.title",
               defaultValue: "Your passcode is now tied to this iPhone",
               bundle: .module,
               comment: "Title of the one-time alert telling an existing user that their sealed notes are now bound to this specific iPhone. 'Tied to this iPhone' is the whole point — the passcode alone is no longer enough elsewhere.")
    }

    /// The disclosure itself: a strictly larger loss mode than the one the user originally accepted.
    static var hardBindingMessage: String {
        String(localized: "lock.hardBinding.message",
               defaultValue: "Fernlet moved the key for your sealed journal, cycle, and intimacy notes into this iPhone's Secure Enclave, where it can't be copied off the device. Those notes are now lost if this iPhone is erased, has its Secure Enclave reset, or is restored onto replacement hardware — even with the right passcode. Turn on Sealed backup in Privacy & Data to keep an encrypted copy that survives.",
               bundle: .module,
               comment: "One-time disclosure for users who set their passcode under an older build and have just acquired a larger loss mode. 'Even with the right passcode' is the sentence that must not soften — remembering the passcode does not save the notes on replaced hardware. 'Secure Enclave' is Apple hardware terminology; 'Sealed backup' and 'Privacy & Data' name a setting and a screen in this app, so match how they are translated there.")
    }
}

// MARK: - View modifier

/// View modifier that gates its content behind the Fernlet app lock, overlaying the unlock
/// screen whenever the lock is engaged and re-locking when the gated content disappears.
///
/// This is the enforcement point that ties `FernletLockService` (the keychain-backed lock
/// service in the `FernletLock` module) to the screens that display sealed content: the app
/// applies it via the public `fernletLockGate(scope:active:shouldLockOnDisappear:)` extension on
/// `View`, on screens like the private hub, the lock-related settings screen, and the
/// progress-photo timeline. Its responsibilities:
///
/// - While the service reports `.locked`, a non-dismissible ``FernletLockView`` overlay covers
///   the content; while it reports `.notConfigured`, a setup call-to-action overlay offers
///   ``FernletLockSetupView`` instead.
/// - When the gated view genuinely disappears, it calls `lock(reason: .viewDisappeared)`,
///   which scrubs the in-memory content key — one unlock session never outlives the screen.
///   Child sheets do not trigger `onDisappear` on the covered view, so sheets presented over
///   gated content do not re-lock the gate.
/// - Because iOS bounces the scene through `.inactive`/`.active` while Face ID presents its
///   system dialog (which can fire spurious `onDisappear`/`onAppear` on page-style TabViews),
///   the disappear re-lock is suppressed during scene transitions and for 1.5 s after
///   returning to `.active`; a re-lock requested inside that window is deferred and executed
///   when the window expires, unless the gate has re-appeared. This breaks the
///   re-lock → recreate ``FernletLockView`` → re-prompt Face ID loop.
///
/// The modifier also hosts the destructive "Reset app lock" confirmation dialog that
/// ``FernletLockView`` requests when the service demands a reset. Runs on the main actor
/// (the module's default isolation); all lock-state reads go through the environment-injected
/// `FernletLockService`.
struct FernletLockGateModifier: ViewModifier {
    /// Which locked surface this gate is. An unlock covers exactly one scope, so a gate reveals only
    /// while the unlock in force is ITS unlock — and revokes a foreign one as it appears.
    let scope: FernletLockScope
    /// Whether the gate is enforced; when `false` the content passes through unmodified
    /// and no lifecycle handling (overlays or disappear re-locks) occurs.
    let active: Bool
    /// Consulted at the moment the gated view disappears; returning false skips the viewDisappeared
    /// re-lock entirely (no deferred pending lock either). For the case where the gate is popped back
    /// to an ALSO-GATED, still-visible parent (the progress-photo detail returning to the timeline
    /// strip): one unlock session should cover strip → detail → pop-back, and the parent's own
    /// disappear re-lock still guards the genuine departure. Defaults to always-lock.
    var shouldLockOnDisappear: () -> Bool = { true }
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase

    /// Tracks whether the gated view is the active top-level view.
    /// Set to true on appear; set to false only when the view disappears
    /// AND it isn't just being covered by a child sheet.
    @State private var gateIsActive = false
    /// Presents the ``FernletLockSetupView`` sheet from the not-configured CTA overlay.
    @State private var showSetup = false
    /// Presents the destructive "Reset app lock" confirmation dialog.
    @State private var showReset = false
    /// Presents the nothing-silent alert when ``FernletLockService/reset()`` destroyed the keys and
    /// the rows but could not rebuild the sealed store file. Swallowing that (it used to be
    /// `try?`) would have promised a clean store the app did not deliver.
    @State private var showResetRebuildFailure = false
    /// Presents the one-shot disclosure owed to an EXISTING install that just migrated to the hard
    /// Secure-Enclave binding. Those users consented to "you lose the notes if you forget your
    /// passcode" under an older build and silently acquired a strictly larger loss mode; the setup
    /// sheet they would have read it in never appears again, so the gate says it once here.
    @State private var showHardBindingNotice = false
    /// Suppresses the viewDisappeared re-lock during scene inactive/active transitions
    /// so Face ID presenting its system dialog doesn't cause a spurious re-lock loop.
    @State private var suppressRelock = false
    /// The delayed task that clears ``suppressRelock`` 1.5 s after the scene returns to
    /// `.active`; cancelled and replaced on every subsequent phase change.
    @State private var suppressRelockTask: Task<Void, Never>?
    /// Set when handleDisappear fires while suppressRelock is active; the lock is
    /// executed when the suppression window expires if the gate hasn't re-appeared.
    @State private var pendingRelock = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .onAppear  { handleAppear()  }
                .onDisappear { handleDisappear() }

            // Unlock overlay — non-dismissible, covers the whole gate
            if active && isLocked {
                lockOverlay
                    .zIndex(100)
            }

            // Not-configured CTA overlay
            if active && isNotConfigured {
                setupCTAOverlay
                    .zIndex(100)
            }
        }
        .sheet(isPresented: $showSetup) {
            // Creating the passcode from THIS gate opens THIS surface and no other.
            FernletLockSetupView(grantingScope: scope)
                .environment(lockService)
        }
        .confirmationDialog(
            GateCopy.resetConfirmTitle,
            isPresented: $showReset,
            titleVisibility: .visible
        ) {
            Button(FernletLockCopy.Action.resetAppLock, role: .destructive) { performReset() }
            Button(FernletLockCopy.Action.cancel, role: .cancel) { }
        } message: {
            Text(GateCopy.resetConfirmMessage)
        }
        .alert(GateCopy.resetRebuildFailedTitle, isPresented: $showResetRebuildFailure) {
            Button(FernletLockCopy.Action.ok, role: .cancel) { }
        } message: {
            Text(GateCopy.resetRebuildFailedMessage)
        }
        .alert(GateCopy.hardBindingTitle, isPresented: $showHardBindingNotice) {
            Button(FernletLockCopy.Action.ok, role: .cancel) { lockService.acknowledgeHardBindingNotice() }
        } message: {
            Text(GateCopy.hardBindingMessage)
        }
        .onChange(of: lockService.state) { _, _ in
            // The flip happens inside the unlock that just landed, so the state change is the
            // first moment the flag can be true. Checked here (not only on appear) because the
            // gate does not re-appear after an in-place unlock.
            if lockService.hardBindingNoticePending { showHardBindingNotice = true }
        }
        .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
    }

    // MARK: Scene phase

    /// How long suppression outlives the return to `.active`, so the spurious
    /// `onDisappear`/`onAppear` events a scene transition emits on page-style TabViews settle
    /// before the disappear re-lock is honored again.
    private static let suppressionWindow: Duration = .milliseconds(1500)

    /// Opens the suppression window on `.inactive` and closes it 1.5 s after `.active`, running
    /// any re-lock that was deferred while it was open.
    ///
    /// Extracted from `body(content:)` so the body reads as layout (R4); the state it touches is
    /// the modifier's own, so nothing needs to be passed in.
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .inactive:
            suppressRelockTask?.cancel()
            suppressRelock = true
        case .active:
            // Keep suppression active briefly after returning to foreground so any
            // spurious onDisappear/onAppear lifecycle events from the transition settle.
            suppressRelockTask?.cancel()
            suppressRelockTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: Self.suppressionWindow)
                } catch {
                    // Cancelled — the NEXT phase change owns the window now. Clearing suppression
                    // (or firing the deferred lock) from a task that was asked to stop is exactly
                    // the re-lock-during-a-transition this modifier exists to prevent, so a
                    // cancelled window does nothing at all.
                    return
                }
                suppressRelock = false
                // Execute any deferred lock request if the gate hasn't re-appeared.
                if pendingRelock && !gateIsActive {
                    pendingRelock = false
                    if lockService.isUnlocked(for: scope) {
                        lockService.lock(reason: .viewDisappeared)
                    }
                }
            }
        default:
            break
        }
    }

    /// Performs the destructive reset the confirmation dialog just authorised, surfacing the
    /// nothing-silent alert when the keys and rows went but the sealed store could not be rebuilt.
    private func performReset() {
        do {
            try lockService.reset()
        } catch {
            // The keys and the rows are gone either way; what failed is re-creating the
            // store file, which is the part the user is told about rather than left to
            // discover.
            print("[Fernlet] App-lock reset could not rebuild the sealed store: \(error)")
            FernletAuditLog.log("lock.reset.rebuild.failed")
            showResetRebuildFailure = true
        }
    }

    // MARK: Computed state

    /// Configured, but not unlocked FOR THIS SCOPE — an unlock held by another locked surface reads
    /// as locked here, which is the whole point. Drives the unlock overlay (with or without a
    /// cooldown deadline). `isLocked || isNotConfigured` must stay in step with
    /// ``FernletLockGateOcclusion/overlayIsUp(active:state:scope:)``, the pure mirror other
    /// surfaces consult.
    private var isLocked: Bool {
        guard !isNotConfigured else { return false }
        return !lockService.isUnlocked(for: scope)
    }

    /// True while no passcode has been configured, which drives the setup CTA overlay. Mirrored
    /// by ``FernletLockGateOcclusion/overlayIsUp(active:state:scope:)`` — keep them in step.
    private var isNotConfigured: Bool {
        lockService.state == .notConfigured
    }

    // MARK: Lifecycle

    /// Marks the gate active and cancels any deferred re-lock; the unlock overlay itself
    /// appears reactively via ``isLocked`` (the biometric auto-prompt lives in
    /// ``FernletLockView``'s `onAppear`).
    private func handleAppear() {
        guard active else { return }
        gateIsActive = true
        pendingRelock = false
        // A migration disclosure owed from a previous launch (the app was killed before the alert
        // was acknowledged) is still owed — the flag is keychain-backed for exactly that reason.
        if lockService.hardBindingNoticePending { showHardBindingNotice = true }
        // Revoke — never inherit — an unlock taken out on a different locked surface. Doing this on
        // APPEAR is what makes the guarantee hold: the other surface's disappear re-lock may have
        // been suppressed (covering sheet, camera cover, scene transition) or never fired at all.
        lockService.revokeUnlockOutside(scope)
        // If configured + locked -> the overlay will appear automatically via `isLocked`
        // Nothing else to do here; biometric auto-prompt is inside FernletLockView.onAppear
    }

    /// Re-locks (scrubbing the content key) when the gated view genuinely departs.
    ///
    /// Skips the re-lock when the gate never activated, a biometric unlock is mid-flight,
    /// the service isn't unlocked, or the caller's `shouldLockOnDisappear` vetoes it; defers
    /// the re-lock via ``pendingRelock`` while the scene-transition suppression window is open.
    private func handleDisappear() {
        guard active, gateIsActive else { return }
        gateIsActive = false
        guard !lockService.isPerformingBiometricUnlock else { return }
        // Only ever re-lock OUR OWN unlock. If another surface has already claimed one, locking here
        // would yank it out from under whoever is on screen now.
        guard lockService.isUnlocked(for: scope) else { return }
        guard shouldLockOnDisappear() else { return }
        if suppressRelock {
            // Defer the lock so it fires when the suppression window expires,
            // preventing the view from staying unlocked if the user navigated away.
            pendingRelock = true
        } else {
            lockService.lock(reason: .viewDisappeared)
        }
    }

    // MARK: Overlays

    /// The non-dismissible unlock overlay: a full-bleed parchment backdrop under
    /// ``FernletLockView``, wired to surface the reset confirmation dialog on request.
    @ViewBuilder private var lockOverlay: some View {
        Color.parchment.ignoresSafeArea()
        FernletLockView(
            scope: scope,
            onUnlocked: { },
            onResetRequested: { showReset = true }
        )
        .environment(lockService)
    }

    /// The call-to-action overlay shown when no lock is configured, offering the
    /// ``FernletLockSetupView`` sheet rather than exposing the gated content.
    @ViewBuilder private var setupCTAOverlay: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 88, height: 88)
                    .background(Color.moss.opacity(0.10), in: Circle())

                VStack(spacing: 8) {
                    Text(GateCopy.setUpCallToAction)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(FernletLockCopy.protectsSentence)
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
                .padding(.horizontal, 32)

                Button(GateCopy.setUpCallToAction) { showSetup = true }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.onMoss)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
                    .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 16))

                Spacer()
            }
        }
    }
}

// MARK: - Gate occlusion (for capture friction)

/// The one pure decision other surfaces need from the lock gate: whether
/// `fernletLockGate(scope:active:)` is currently painting an opaque overlay — the unlock screen
/// or the not-configured setup CTA, both full-bleed parchment at `zIndex(100)` — over its
/// content.
///
/// Exists for capture-FRICTION composition: `PrivateHubView` ANDs `!overlayIsUp(...)` into its
/// `captureProtected(surface:isFrontmost:)` flag, so a screenshot of the LOCKED hub — where the
/// once-per-session nudge banner would render invisibly beneath the gate's overlay — never
/// spends the session's nudge. Kept HERE, next to ``FernletLockGateModifier``, because it must
/// mirror the modifier's own overlay conditions (`isLocked` / `isNotConfigured`) exactly; a
/// change to either must change the other, and `CaptureOcclusionGatingTests` pins the truth
/// table.
public enum FernletLockGateOcclusion {
    /// True while a gate for `scope` would overlay its content: the gate is enforced, and
    /// either no credential is configured (the setup CTA covers) or the unlock in force is not
    /// this scope's (the unlock screen covers — including while a DIFFERENT scope holds the
    /// unlock, which reads as locked here).
    ///
    /// - Parameters:
    ///   - active: The gate's `active` flag; an inactive gate (e.g. the UI-test bypass) never
    ///     overlays.
    ///   - state: The lock service's current ``FernletLockState``.
    ///   - scope: The gated surface, matched against the unlock in force.
    /// - Returns: Whether the gate's opaque overlay is above the content right now.
    public static func overlayIsUp(active: Bool, state: FernletLockState, scope: FernletLockScope) -> Bool {
        guard active else { return false }
        if case .notConfigured = state { return true }
        return !state.isUnlocked(for: scope)
    }
}

// MARK: - View extension

public extension View {
    /// Gates the view behind FernletLock, for ONE `scope`, by applying `FernletLockGateModifier`.
    ///
    /// An unlock is granted to a single surface: this gate reveals only while the unlock in force is
    /// its own, revokes a foreign one as it appears, and on disappear scrubs the content key so
    /// every re-entry re-prompts. Two gates that share a `scope` (the progress-photo strip and its
    /// pushed photo detail) share one unlock session; different scopes never do.
    ///
    /// When `active` is false the content passes through unchanged.
    /// `shouldLockOnDisappear` (default always-true) can veto the disappear re-lock when the gate is
    /// popping back to an also-gated, still-visible parent that owns the session's re-lock.
    ///
    /// - Parameters:
    ///   - scope: The locked surface this gate is. No default — a new gated screen must name
    ///     itself rather than silently inherit another surface's unlock.
    ///   - active: Whether the gate is enforced at all; pass `false` to render the content
    ///     ungated (e.g. while a UI-test bypass flag is set).
    ///   - shouldLockOnDisappear: Consulted at the moment the gated view disappears;
    ///     returning `false` skips that re-lock entirely so one unlock session can span a
    ///     push onto — and pop back from — a child screen whose parent is also gated.
    /// - Returns: The content wrapped in the lock gate.
    func fernletLockGate(
        scope: FernletLockScope,
        active: Bool = true,
        shouldLockOnDisappear: @escaping () -> Bool = { true }
    ) -> some View {
        modifier(FernletLockGateModifier(scope: scope, active: active, shouldLockOnDisappear: shouldLockOnDisappear))
    }
}

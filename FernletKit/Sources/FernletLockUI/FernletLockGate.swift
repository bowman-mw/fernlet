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
import FernletLock
import FernletUI

// MARK: - View modifier

/// View modifier that gates its content behind the Fernlet app lock, overlaying the unlock
/// screen whenever the lock is engaged and re-locking when the gated content disappears.
///
/// This is the enforcement point that ties `FernletLockService` (the keychain-backed lock
/// service in the `FernletLock` module) to the screens that display sealed content: the app
/// applies it via the public `fernletLockGate(active:shouldLockOnDisappear:)` extension on
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
            FernletLockSetupView()
                .environment(lockService)
        }
        .confirmationDialog(
            "Reset app lock?",
            isPresented: $showReset,
            titleVisibility: .visible
        ) {
            Button("Reset app lock", role: .destructive) {
                try? lockService.reset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                suppressRelockTask?.cancel()
                suppressRelock = true
            case .active:
                // Keep suppression active briefly after returning to foreground so any
                // spurious onDisappear/onAppear lifecycle events from the transition settle.
                suppressRelockTask?.cancel()
                suppressRelockTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    suppressRelock = false
                    // Execute any deferred lock request if the gate hasn't re-appeared.
                    if pendingRelock && !gateIsActive {
                        pendingRelock = false
                        if case .unlocked = lockService.state {
                            lockService.lock(reason: .viewDisappeared)
                        }
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: Computed state

    /// True while the lock service reports `.locked` (with or without a cooldown deadline),
    /// which drives the unlock overlay.
    private var isLocked: Bool {
        if case .locked = lockService.state { return true }
        return false
    }

    /// True while no passcode has been configured, which drives the setup CTA overlay.
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
        guard case .unlocked = lockService.state else { return }
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
                    Text("Set up app lock")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text("Protect your journal, period, and intimacy history with a private passcode.")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
                .padding(.horizontal, 32)

                Button("Set up app lock") { showSetup = true }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))

                Spacer()
            }
        }
    }
}

// MARK: - View extension

public extension View {
    /// Gates the view behind FernletLock by applying `FernletLockGateModifier`.
    ///
    /// When `active` is false the content passes through unchanged.
    /// On disappear the content key is scrubbed; every re-entry re-prompts.
    /// `shouldLockOnDisappear` (default always-true) can veto the disappear re-lock when the gate is
    /// popping back to an also-gated, still-visible parent that owns the session's re-lock.
    ///
    /// - Parameters:
    ///   - active: Whether the gate is enforced at all; pass `false` to render the content
    ///     ungated (e.g. while a UI-test bypass flag is set).
    ///   - shouldLockOnDisappear: Consulted at the moment the gated view disappears;
    ///     returning `false` skips that re-lock entirely so one unlock session can span a
    ///     push onto — and pop back from — a child screen whose parent is also gated.
    /// - Returns: The content wrapped in the lock gate.
    func fernletLockGate(
        active: Bool = true,
        shouldLockOnDisappear: @escaping () -> Bool = { true }
    ) -> some View {
        modifier(FernletLockGateModifier(active: active, shouldLockOnDisappear: shouldLockOnDisappear))
    }
}

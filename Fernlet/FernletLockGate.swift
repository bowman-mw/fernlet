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

// MARK: - View modifier

struct FernletLockGateModifier: ViewModifier {
    let active: Bool
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase

    // Tracks whether the gated view is the active top-level view.
    // Set to true on appear; set to false only when the view disappears
    // AND it isn't just being covered by a child sheet.
    @State private var gateIsActive = false
    @State private var showSetup = false
    @State private var showReset = false
    // Suppresses the viewDisappeared re-lock during scene inactive/active transitions
    // so Face ID presenting its system dialog doesn't cause a spurious re-lock loop.
    @State private var suppressRelock = false
    @State private var suppressRelockTask: Task<Void, Never>?
    // Set when handleDisappear fires while suppressRelock is active; the lock is
    // executed when the suppression window expires if the gate hasn't re-appeared.
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

    private var isLocked: Bool {
        if case .locked = lockService.state { return true }
        return false
    }

    private var isNotConfigured: Bool {
        lockService.state == .notConfigured
    }

    // MARK: Lifecycle

    private func handleAppear() {
        guard active else { return }
        gateIsActive = true
        pendingRelock = false
        // If configured + locked -> the overlay will appear automatically via `isLocked`
        // Nothing else to do here; biometric auto-prompt is inside FernletLockView.onAppear
    }

    private func handleDisappear() {
        guard active, gateIsActive else { return }
        gateIsActive = false
        guard !lockService.isPerformingBiometricUnlock else { return }
        guard case .unlocked = lockService.state else { return }
        if suppressRelock {
            // Defer the lock so it fires when the suppression window expires,
            // preventing the view from staying unlocked if the user navigated away.
            pendingRelock = true
        } else {
            lockService.lock(reason: .viewDisappeared)
        }
    }

    // MARK: Overlays

    @ViewBuilder private var lockOverlay: some View {
        Color.parchment.ignoresSafeArea()
        FernletLockView(
            onUnlocked: { },
            onResetRequested: { showReset = true }
        )
        .environment(lockService)
    }

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
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)
                    Text("Protect your journal, period, and intimacy history with a private passcode.")
                        .font(.callout.italic())
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
                .padding(.horizontal, 32)

                Button("Set up app lock") { showSetup = true }
                    .buttonStyle(.plain)
                    .font(.headline)
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

extension View {
    /// Gates the view behind FernletLock.
    /// When `active` is false the content passes through unchanged.
    /// On disappear the content key is scrubbed; every re-entry re-prompts.
    func fernletLockGate(active: Bool = true) -> some View {
        modifier(FernletLockGateModifier(active: active))
    }
}

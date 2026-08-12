// CaptureProtectionTests.swift
// FernletTests
//
// Tests for the capture-FRICTION machinery (CaptureProtectionState + captureProtected(surface:)):
// Docs/Design-Capture-Protection-2026-08-10.md. Neither real trigger is drivable from an
// automated iOS test — XCUITest's app.screenshot() does not post
// userDidTakeScreenshotNotification (verified 2026-08-11) and simulator recording does not set
// UIScreen.isCaptured — so these tests exercise the injected seam the design requires:
// construct a state, post the real notifications / flip the override, and assert transitions
// and rendering. The cover-over-each-real-surface half lives in
// FernletUITests/CaptureProtectionUITests (FERNLET_UI_TEST_FORCE_CAPTURE).
// CaptureOcclusionGatingTests additionally pins FernletLockGateOcclusion (FernletLockUI), the
// pure lock-overlay decision PrivateHubView composes into the hub's isFrontmost. NOT unit-
// testable here (no seam): the PrivateHubView/ContentView WIRING of that composition, which
// needs a live store + lock service and real sheet presentation.
//
// Polling follows the wall-clock-deadline + minimum-poll-floor discipline: the notification
// handlers hop through Task { @MainActor }, so state lands a runloop turn after the post.

import Foundation
import SwiftUI
import Testing
import UIKit
import FernletUI
import FernletLock
import FernletLockUI

/// Waits (deadline + 50 ms poll floor) for a main-actor condition to become true; returns the
/// final read so callers can `#expect` on it.
@MainActor
private func pollUntil(
    timeout: TimeInterval = 5,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// Mutable flag box so a test can steer the injected per-screen capture read after the state
/// captured the closure.
@MainActor
private final class CaptureFlagBox {
    /// The value the injected `readScreenIsCaptured` closure reports.
    var value = false
}

/// Records every string the state posts through its injectable VoiceOver-announcement seam —
/// the real accessibility system never reports back what was (or was not) announced.
@MainActor
private final class AnnouncementRecorder {
    /// Announcements in posting order.
    var announcements: [String] = []
}

/// Unit tests for ``CaptureProtectionState``: pulse transitions off the real screenshot
/// notification (including the MainActor hop), per-screen capture re-reads off the real
/// captured-change notification, the once-per-session nudge claim, the test override, and
/// teardown (no retain cycle; observers die with the state).
@Suite(.serialized)
struct CaptureProtectionStateTests {

    /// Tier 1: posting the real `userDidTakeScreenshotNotification` bumps the pulse token once
    /// per post, landing after the documented nonisolated-block → MainActor hop.
    @MainActor
    @Test func screenshotNotificationBumpsThePulse() async throws {
        let state = CaptureProtectionState()
        #expect(state.screenshotPulse == 0)

        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(await pollUntil { state.screenshotPulse == 1 })

        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(await pollUntil { state.screenshotPulse == 2 })
    }

    /// The nudge is once per session, but every surface reacting to the SAME pulse shares it
    /// (the hub under a sheet and the sheet agree); later pulses claim nothing.
    @MainActor
    @Test func nudgeClaimIsOncePerSessionAndSharedWithinOnePulse() async throws {
        let state = CaptureProtectionState()
        #expect(state.nudgePulse == nil)

        #expect(state.claimNudge(for: 1))
        #expect(state.nudgePulse == 1)
        // A second surface reacting to the same pulse also shows the nudge.
        #expect(state.claimNudge(for: 1))
        // Any later pulse this session shows none.
        #expect(!state.claimNudge(for: 2))
        #expect(state.nudgePulse == 1)
    }

    /// Tier 2: a `capturedDidChangeNotification` post makes the state re-read its REGISTERED
    /// screens (through the injected read — the notification's own subject is never trusted),
    /// flipping `isCaptured(on:)` in both directions.
    @MainActor
    @Test func captureChangeReReadsTheRegisteredScreens() async throws {
        let flag = CaptureFlagBox()
        let state = CaptureProtectionState(readScreenIsCaptured: { _ in flag.value })
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "Expected an active window scene in the unit-test host"
        )
        let screen = windowScene.screen

        state.registerScreen(screen)
        #expect(!state.isCaptured(on: screen))
        #expect(!state.isCaptured)

        flag.value = true
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        #expect(await pollUntil { state.isCaptured(on: screen) })
        #expect(state.isCaptured)

        flag.value = false
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        #expect(await pollUntil { !state.isCaptured(on: screen) })
        #expect(!state.isCaptured)
    }

    /// Registration itself re-reads capture state (the at-mount read), so a recording that
    /// started before a surface appeared is covered on arrival without waiting for a post.
    @MainActor
    @Test func registeringAScreenReadsCaptureStateImmediately() async throws {
        let flag = CaptureFlagBox()
        flag.value = true
        let state = CaptureProtectionState(readScreenIsCaptured: { _ in flag.value })
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "Expected an active window scene in the unit-test host"
        )

        state.registerScreen(windowScene.screen)
        #expect(state.isCaptured(on: windowScene.screen))
    }

    /// The test/UI-test override forces the verdict for every screen — including the nil
    /// (pre-resolution) screen — regardless of registration, and clears cleanly.
    @MainActor
    @Test func overrideForcesTheVerdictRegardlessOfScreens() async throws {
        let state = CaptureProtectionState(captureOverride: true)
        #expect(state.isCaptured)
        #expect(state.isCaptured(on: nil))

        state.captureOverride = false
        #expect(!state.isCaptured)
        #expect(!state.isCaptured(on: nil))

        state.captureOverride = nil
        // No screens registered: the aggregate falls back to the live connected-scene read
        // (the unit-test host's screen is not captured).
        #expect(!state.isCaptured)
    }

    /// Pre-resolution conservatism with NOTHING registered: before the first probe ever lands
    /// (a fresh launch that never visited the Private tab has an empty registry), the nil-screen
    /// verdict must still fail toward covering by reading the connected window scenes' screens
    /// live — otherwise the first protected surface mounted during an already-running recording
    /// draws its pre-resolution frames uncovered.
    @MainActor
    @Test func preResolutionFallbackConsultsLiveScenesWhenNothingIsRegistered() async throws {
        let flag = CaptureFlagBox()
        flag.value = true
        let state = CaptureProtectionState(readScreenIsCaptured: { _ in flag.value })
        _ = try #require(
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "Expected an active window scene in the unit-test host"
        )

        // Nothing registered, "recording" running: covered, not leaked.
        #expect(state.isCaptured(on: nil))
        #expect(state.isCaptured)

        flag.value = false
        #expect(!state.isCaptured(on: nil))
        #expect(!state.isCaptured)
    }

    /// The first nudge claim posts the nudge copy as a VoiceOver announcement exactly once —
    /// the only Tier-1 signal a VoiceOver user gets (the blur is purely visual and the banner
    /// is a non-modal overlay VoiceOver never moves to on its own). A second surface sharing
    /// the same pulse shows the banner without double-speaking; a later pulse announces nothing.
    @MainActor
    @Test func firstNudgeClaimPostsExactlyOneVoiceOverAnnouncement() async throws {
        let recorder = AnnouncementRecorder()
        let state = CaptureProtectionState(
            postAccessibilityAnnouncement: { recorder.announcements.append($0) }
        )

        #expect(state.claimNudge(for: 1))
        #expect(recorder.announcements == [CaptureNudgeCopy.spokenAnnouncement])

        // Same pulse, second surface (hub + sheet agree): banner yes, re-announcement no.
        #expect(state.claimNudge(for: 1))
        #expect(recorder.announcements.count == 1)

        // Later pulse: no claim, no announcement.
        #expect(!state.claimNudge(for: 2))
        #expect(recorder.announcements.count == 1)
    }

    /// Releasing the state deallocates it (the `[weak self]` observer captures create no retain
    /// cycle) and its observer bag unregisters, so a later post reaches nothing and cannot crash.
    @MainActor
    @Test func releaseTearsDownObserversWithoutARetainCycle() async throws {
        weak var weakState: CaptureProtectionState?
        autoreleasepool {
            var state: CaptureProtectionState? = CaptureProtectionState()
            weakState = state
            state = nil
        }
        #expect(weakState == nil, "The notification observers must not retain the state")

        // Post after teardown: the removed observers must not fire into a dead object.
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(weakState == nil)
    }
}

/// View-level tests hosting `captureProtected(surface:)` content in a real `UIWindow` with an
/// injected ``CaptureProtectionState``: the Tier-2 cover renders opaque while captured and
/// clears when not (asserted by sampling the rendered center pixel — red content vs the
/// parchment cover), the resign-active snapshot cover paints off `scenePhase`, and the Tier-1
/// pulse is frontmost-gated (asserted through the observable nudge claim, which only a reacting
/// modifier performs).
@Suite(.serialized)
struct CaptureProtectionViewTests {

    /// Hosts a view in a fresh key window; the caller must keep the returned window alive for
    /// the duration of the assertion and hide it afterward.
    @MainActor
    private func makeWindow<Content: View>(_ content: Content) throws -> UIWindow {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "Expected an active window scene for SwiftUI hosting"
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }

    /// Renders the window (forcing a screen update) and samples the center pixel's RGB.
    @MainActor
    private func centerPixel(of window: UIWindow) -> (r: Int, g: Int, b: Int)? {
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(
            x: -CGFloat(cg.width) / 2 + 0.5,
            y: -CGFloat(cg.height) / 2 + 0.5,
            width: CGFloat(cg.width),
            height: CGFloat(cg.height)
        ))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// The pure-red content is unmistakable against the parchment cover.
    @MainActor
    private func isRed(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 200 && pixel.g < 80 && pixel.b < 80
    }

    /// Tier-2 rendering, both directions: the opaque cover replaces the content while the
    /// injected state reports captured, and the content returns the moment it stops.
    @MainActor
    @Test func coverRendersWhileCapturedAndClearsWhenNot() async throws {
        let state = CaptureProtectionState(captureOverride: true)
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest")
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        let covered = try #require(centerPixel(of: window))
        #expect(!isRed(covered), "Captured: the opaque cover must replace the content, got \(covered)")

        state.captureOverride = false
        #expect(await pollUntil {
            guard let pixel = self.centerPixel(of: window) else { return false }
            return self.isRed(pixel)
        }, "Capture ended: the content must return")
    }

    /// Trigger B: with no capture at all, `scenePhase != .active` alone paints the cover — the
    /// app-switcher / Control Center snapshot path, required at every surface because the
    /// background lock covers only the hub (2026-08-11 empirical check).
    @MainActor
    @Test func resignActiveScenePhasePaintsTheSnapshotCover() async throws {
        let state = CaptureProtectionState(captureOverride: false)
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest")
                .environment(state)
                .environment(\.scenePhase, ScenePhase.background)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        let pixel = try #require(centerPixel(of: window))
        #expect(!isRed(pixel), "scenePhase != .active must paint the snapshot cover, got \(pixel)")
    }

    /// `active: false` passes content through untouched even while "captured" — the escape
    /// hatch mirrors `.fernletLockGate(active:)`.
    @MainActor
    @Test func inactiveModifierPassesContentThrough() async throws {
        let state = CaptureProtectionState(captureOverride: true)
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest", active: false)
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        let pixel = try #require(centerPixel(of: window))
        #expect(isRed(pixel), "active: false must render the content unmodified, got \(pixel)")
    }

    /// Frontmost gating, negative half: a surface hosted with `isFrontmost: false` (the hub
    /// while Home is the visible tab — page TabViews keep it alive) must NOT react to a
    /// screenshot pulse, so the session's one nudge is never spent invisibly.
    @MainActor
    @Test func backgroundedSurfaceDoesNotClaimThePulseNudge() async throws {
        let state = CaptureProtectionState()
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest", isFrontmost: false)
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(await pollUntil { state.screenshotPulse == 1 })
        // Give a (wrongly) reacting modifier ample time to claim, then assert none did.
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.nudgePulse == nil, "A non-frontmost surface must not consume the session nudge")
    }

    /// Frontmost gating, positive half: a frontmost, scene-active surface reacts to the pulse
    /// and claims the once-per-session nudge.
    @MainActor
    @Test func frontmostSurfaceClaimsThePulseNudge() async throws {
        let state = CaptureProtectionState()
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest", isFrontmost: true)
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(await pollUntil { state.nudgePulse != nil },
                "A frontmost surface must react to the pulse and claim the nudge")
        #expect(state.nudgePulse == state.screenshotPulse)
    }

    /// Occlusion gating: a surface whose OWN Tier-2 cover is up (active recording) must not
    /// react to a screenshot pulse — the screenshot captured the cover, and the nudge banner
    /// would render invisibly beneath it (zIndex 40 under the cover's 50), silently spending
    /// the once-per-session nudge.
    @MainActor
    @Test func coveredSurfaceDoesNotClaimThePulseNudge() async throws {
        let state = CaptureProtectionState(captureOverride: true)
        let window = try makeWindow(
            Color(red: 1, green: 0, blue: 0)
                .ignoresSafeArea()
                .captureProtected(surface: "viewTest", isFrontmost: true)
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(await pollUntil { state.screenshotPulse == 1 })
        // Give a (wrongly) reacting modifier ample time to claim, then assert none did.
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.nudgePulse == nil,
                "A covered surface must not consume the session nudge beneath its own cover")
    }

    /// The cover's arrival resigns keyboard focus in the surface's own window: the system
    /// keyboard lives in its own window ABOVE the opaque cover, so it stays in recordings and
    /// snapshots (QuickType echoing the typed text) unless focus is dropped when `covered`
    /// flips true.
    @MainActor
    @Test func coverArrivalResignsTheKeyboard() async throws {
        let state = CaptureProtectionState(captureOverride: false)
        let textField = UITextField()
        let window = try makeWindow(
            TextFieldHost(textField: textField)
                .captureProtected(surface: "viewTest")
                .environment(state)
                .environment(\.scenePhase, ScenePhase.active)
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))

        textField.becomeFirstResponder()
        #expect(await pollUntil { textField.isFirstResponder },
                "Precondition: the hosted field must take keyboard focus")

        state.captureOverride = true
        #expect(await pollUntil { !textField.isFirstResponder },
                "The Tier-2 cover's arrival must resign the focused field")
    }
}

/// Hosts a caller-owned plain `UITextField` so a test can drive and observe first-responder
/// status directly (SwiftUI's `FocusState` offers no such seam from outside the view).
private struct TextFieldHost: UIViewRepresentable {
    /// The field under test, owned by the test so it can poll `isFirstResponder`.
    let textField: UITextField

    /// Returns the caller's field as the represented view.
    func makeUIView(context: Context) -> UITextField { textField }

    /// No-op: the field's state is driven by the test, not by SwiftUI updates.
    func updateUIView(_ uiView: UITextField, context: Context) {}
}

/// Truth table for ``FernletLockGateOcclusion/overlayIsUp(active:state:scope:)`` — the pure
/// decision `PrivateHubView` ANDs into its `captureProtected(surface:isFrontmost:)` flag so a
/// screenshot of the LOCKED (or not-yet-configured) hub can never spend the once-per-session
/// nudge beneath the gate's opaque `zIndex(100)` overlay. Must mirror
/// `FernletLockGateModifier`'s own `isLocked` / `isNotConfigured` overlay conditions exactly.
@Suite(.serialized)
struct CaptureOcclusionGatingTests {

    /// Every reachable combination of gate activity, lock state, and unlock scope.
    @MainActor
    @Test func overlayTruthTableMirrorsTheGate() async throws {
        // Inactive gate (the UI-test bypass): never occludes, whatever the lock state.
        #expect(!FernletLockGateOcclusion.overlayIsUp(
            active: false, state: .notConfigured, scope: .privateHub))
        #expect(!FernletLockGateOcclusion.overlayIsUp(
            active: false, state: .locked(cooldownDeadline: nil), scope: .privateHub))

        // Not configured: the setup CTA overlay covers the hub.
        #expect(FernletLockGateOcclusion.overlayIsUp(
            active: true, state: .notConfigured, scope: .privateHub))

        // Locked, with and without a brute-force cooldown: the unlock overlay covers.
        #expect(FernletLockGateOcclusion.overlayIsUp(
            active: true, state: .locked(cooldownDeadline: nil), scope: .privateHub))
        #expect(FernletLockGateOcclusion.overlayIsUp(
            active: true, state: .locked(cooldownDeadline: .distantFuture), scope: .privateHub))

        // Unlocked FOR THIS scope: the hub content is revealed.
        #expect(!FernletLockGateOcclusion.overlayIsUp(
            active: true, state: .unlocked(scope: .privateHub), scope: .privateHub))

        // Unlocked for a DIFFERENT scope reads as locked here — the overlay is up.
        #expect(FernletLockGateOcclusion.overlayIsUp(
            active: true, state: .unlocked(scope: .appLockSettings), scope: .privateHub))
    }
}

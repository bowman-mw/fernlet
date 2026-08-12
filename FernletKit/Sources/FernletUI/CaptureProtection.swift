//
//  CaptureProtection.swift
//  FernletUI
//
//  Screenshot & screen-capture FRICTION for the app's private surfaces (design brief:
//  Docs/Design-Capture-Protection-2026-08-10.md). Two tiers, both ordinary public API:
//
//    Tier 1 — a screenshot *reaction*: `UIApplication.userDidTakeScreenshotNotification`
//             posts AFTER the pixels are captured; the protected surface blurs briefly and
//             shows a calm once-per-session nudge. Pure after-the-fact friction.
//    Tier 2 — a capture *cover*: while `UIScreen.isCaptured` is true (screen recording,
//             AirPlay mirroring, QuickTime/ReplayKit capture) or the scene isn't `.active`
//             (app-switcher / Control Center snapshot), an opaque panel covers the surface.
//
//  THIS IS FRICTION, NOT A SECURITY CONTROL. It cannot prevent a screenshot (Tier 1 reacts
//  after the image already exists in Photos), cannot stop a photograph of the screen, and is
//  aimed at the user's own impulsive self-sharing — never at an attacker. Do not reason about
//  it as a guarantee, cite it as one, or promote it into Verifiability.md §1.
//

import SwiftUI
import UIKit

// MARK: - Observable capture state

/// App-lifetime observable state behind `captureProtected(surface:active:isFrontmost:)` — the
/// single owner of both capture-friction triggers, injected via `.environment(...)` and never
/// self-discovered by the views (that injectability is the whole test seam: neither real trigger
/// can be driven from an automated iOS test, so tests construct one of these and flip it).
///
/// **This is friction, not a guarantee** — see the file header. The state owns exactly two
/// things:
///
/// - ``screenshotPulse``: a monotonically increasing token bumped on every
///   `UIApplication.userDidTakeScreenshotNotification`. The notification is app-wide and posts
///   *after* capture, so views react (blur + nudge) rather than prevent. Frontmost gating is the
///   *modifier's* job — both the outer tab container and the Private hub are page-style
///   `TabView`s that keep offscreen children alive, so the state itself must never assume a
///   pulse belongs to the visible surface.
/// - ``capturedScreenIDs`` / ``isCaptured``: which registered screens are currently being
///   captured (recording, mirroring, ReplayKit). Multi-scene correct: each modifier registers
///   the `UIScreen` of its own window scene (resolved by a `didMoveToWindow` probe — never
///   `UIScreen.main`, which is deprecated and wrong under Stage Manager / Split View), the
///   observer listens with `object: nil`, and every post re-reads the registered screens rather
///   than trusting the notification's subject.
///
/// Lifecycle traps this type already accounts for:
/// - The `NotificationCenter` observer blocks run nonisolated under Swift 6 — they never touch
///   state directly, hopping through `Task { @MainActor [weak self] in … }` first (the
///   `ProtectedSidecar` template).
/// - Both observer tokens are held by a `NotificationObserverBag` whose `deinit` removes them
///   exactly when this state deallocates; the `[weak self]` captures mean the observers never
///   retain the state, so an owner releasing it fully tears it down.
/// - Registration keeps only weak screen references and prunes dead ones on every refresh, so a
///   closed scene cannot pin a stale "captured" verdict.
@MainActor
@Observable
public final class CaptureProtectionState {

    // MARK: Observable state

    /// `ObjectIdentifier`s of the registered screens whose `isCaptured` currently reads true.
    /// Per-screen rather than a single flag so two Fernlet windows (iPad Stage Manager / Split
    /// View) never produce a cross-window false positive: recording window A must not cover
    /// window B. Updated by ``refreshCaptureState()`` on every `capturedDidChangeNotification`
    /// post and on every screen registration (the at-mount read the design requires, so a
    /// recording started on Home already covers the Private tab on arrival).
    public private(set) var capturedScreenIDs: Set<ObjectIdentifier> = []

    /// Monotonically increasing screenshot token: bumped once per
    /// `UIApplication.userDidTakeScreenshotNotification`. Views observe it via `onChange` and
    /// react only while frontmost and scene-active; the state never decides visibility.
    public private(set) var screenshotPulse: Int = 0

    /// The single pulse token that carries the once-per-session nudge, or nil while no protected
    /// surface has reacted to any pulse yet. Set by the FIRST ``claimNudge(for:)`` call — i.e.
    /// by a screenshot taken while a protected surface was actually frontmost. A screenshot on
    /// Home/Food/Move/Social claims nothing, so the session's one nudge is never silently spent
    /// on a screen that showed no nudge.
    public private(set) var nudgePulse: Int? = nil

    /// Test/UI-test override for the capture verdict: non-nil forces every
    /// ``isCaptured(on:)`` answer to that value regardless of registered screens. The seam for
    /// the `FERNLET_UI_TEST_FORCE_CAPTURE` launch flag and the view-level tests — real capture
    /// (`isCaptured`) cannot be driven from automation, so this is the only honest way to render
    /// the cover under test. Never set outside DEBUG hooks or tests.
    public var captureOverride: Bool? = nil

    /// Aggregate capture verdict: the override when one is set, otherwise "any registered screen
    /// is captured". Views that know their own screen should prefer ``isCaptured(on:)`` — this
    /// aggregate exists for pre-resolution frames (a probe that has not landed in a window yet)
    /// and for tests, and it deliberately fails toward covering during that brief window.
    public var isCaptured: Bool { captureOverride ?? !capturedScreenIDs.isEmpty }

    // MARK: Internals

    /// Weak boxes of every screen a `captureProtected` probe has registered, keyed by
    /// `ObjectIdentifier`. Weak so a dismissed scene's screen dies naturally; pruned on refresh.
    @ObservationIgnored private var registeredScreens: [ObjectIdentifier: WeakScreenBox] = [:]
    /// Holds the two `NotificationCenter` observer tokens and removes them when this state is
    /// released. A nonisolated bag rather than a stored array because this module builds in
    /// Swift 6 language mode, where a `@MainActor` class's nonisolated `deinit` may not touch a
    /// non-Sendable stored property — the bag's own (unisolated) `deinit` does the removal
    /// instead, running as part of this object's teardown.
    @ObservationIgnored private let observerBag = NotificationObserverBag()
    /// Reads one screen's captured flag — `{ $0.isCaptured }` in production, injectable so unit
    /// tests can simulate a capture transition (posting `capturedDidChangeNotification` then
    /// asserting the re-read), which real automation cannot trigger.
    @ObservationIgnored private let readScreenIsCaptured: @MainActor (UIScreen) -> Bool

    /// Creates the state and installs both notification observers once.
    ///
    /// - Parameters:
    ///   - captureOverride: Initial ``captureOverride``; pass `true` for the
    ///     `FERNLET_UI_TEST_FORCE_CAPTURE` launch hook, nil in production.
    ///   - readScreenIsCaptured: Test seam for the per-screen captured read; nil (production)
    ///     resolves to `{ $0.isCaptured }` in the init body — deliberately not a default-argument
    ///     value, since `UIScreen.isCaptured` is main-actor state.
    public init(
        captureOverride: Bool? = nil,
        readScreenIsCaptured: (@MainActor (UIScreen) -> Bool)? = nil
    ) {
        self.captureOverride = captureOverride
        self.readScreenIsCaptured = readScreenIsCaptured ?? { $0.isCaptured }
        // The blocks run nonisolated under Swift 6 — never touch state directly; hop first.
        observerBag.hold(NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenshot() }
        })
        // `object: nil`, and every post re-reads OUR registered screens rather than trusting the
        // notification's subject — per-screen state, one observer.
        observerBag.hold(NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshCaptureState() }
        })
    }

    // MARK: Screen registration

    /// Registers the screen a protected surface actually lives on (resolved from its own window
    /// scene by the modifier's probe) and immediately re-reads capture state — the "state read at
    /// mount, not only on notification" requirement, so a recording that started before the
    /// surface appeared covers it on arrival. Idempotent per screen.
    public func registerScreen(_ screen: UIScreen) {
        registeredScreens[ObjectIdentifier(screen)] = WeakScreenBox(screen)
        refreshCaptureState()
    }

    /// The capture verdict for one surface's own screen: the override when set; the per-screen
    /// answer when the probe has resolved; the conservative aggregate (``isCaptured``) while the
    /// screen is still unknown, so the pre-resolution frame of a surface mounted mid-recording
    /// is covered rather than leaked.
    public func isCaptured(on screen: UIScreen?) -> Bool {
        if let captureOverride { return captureOverride }
        guard let screen else { return !capturedScreenIDs.isEmpty }
        return capturedScreenIDs.contains(ObjectIdentifier(screen))
    }

    // MARK: Nudge bookkeeping

    /// Claims the once-per-session nudge for a reacting surface. The FIRST claim wins the session:
    /// every surface reacting to that same pulse also shows the nudge (the hub under a sheet and
    /// the sheet itself blur together and agree), every later pulse shows none. Because only a
    /// frontmost, scene-active modifier calls this, a screenshot taken on an unprotected tab
    /// never consumes the session's nudge.
    public func claimNudge(for pulse: Int) -> Bool {
        if let nudgePulse { return nudgePulse == pulse }
        nudgePulse = pulse
        return true
    }

    // MARK: Trigger handlers

    /// Tier-1 handler: bump the pulse token. Reaction (blur, nudge, frontmost gating) is
    /// entirely the modifier's responsibility.
    private func handleScreenshot() {
        screenshotPulse += 1
    }

    /// Tier-2 handler and mount-time read: prune dead screen boxes, then re-read every
    /// registered screen's captured flag into ``capturedScreenIDs``.
    private func refreshCaptureState() {
        registeredScreens = registeredScreens.filter { $0.value.screen != nil }
        capturedScreenIDs = Set(registeredScreens.compactMap { id, box -> ObjectIdentifier? in
            guard let screen = box.screen, readScreenIsCaptured(screen) else { return nil }
            return id
        })
    }
}

/// Owns `NotificationCenter` block-observer tokens for ``CaptureProtectionState`` and removes
/// them in its own `deinit`. Deliberately `nonisolated`: in Swift 6 language mode a `@MainActor`
/// class's nonisolated `deinit` may not touch a non-Sendable stored token array, so teardown is
/// delegated to this bag, which deallocates (and unregisters) exactly when its owner does.
/// `NotificationCenter.removeObserver` is thread-safe; the tokens are only ever appended from
/// the owner's main-actor init, so there is no concurrent mutation.
private nonisolated final class NotificationObserverBag {
    /// The held observer tokens, removed on deallocation.
    private var tokens: [NSObjectProtocol] = []

    /// Takes ownership of one observer token for the lifetime of the bag.
    func hold(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// A weak `UIScreen` holder for ``CaptureProtectionState``'s registration table, so a departed
/// scene's screen can deallocate instead of being pinned by the table that watches it.
private final class WeakScreenBox {
    /// The registered screen, or nil once its scene has gone away (pruned on the next refresh).
    private(set) weak var screen: UIScreen?
    /// Boxes the given screen weakly.
    init(_ screen: UIScreen) { self.screen = screen }
}

// MARK: - View modifier

/// The capture-friction view modifier behind `captureProtected(surface:active:isFrontmost:)` —
/// a structural sibling of `FernletLockGateModifier`: content wrapped in a `ZStack`, overlays
/// layered with explicit `zIndex`, all state read from the environment-injected
/// ``CaptureProtectionState`` plus `scenePhase`.
///
/// **Friction, not a guarantee** (see the file header). What it draws:
///
/// - **Tier-2 cover** while the surface's own screen is captured (recording / mirroring /
///   ReplayKit) *or* the scene is not `.active` (app-switcher & Control Center snapshots — the
///   `!= .active` form deliberately, because the switcher can be entered without a true
///   background transition). Opaque and whole-surface, never partial: the progress-photo
///   timeline already recorded the lesson that a partial cover leaves captions legible in the
///   snapshot. The covered content is `accessibilityHidden`, and the cover carries its own
///   label, so VoiceOver reading order matches what is visible.
/// - **Tier-1 pulse** on a screenshot taken while this surface is frontmost and scene-active: a
///   ~2 s blur + desaturation of the content (the user knows what they just did; the point is a
///   beat of hesitation, not alarm), plus a calm once-per-session nudge banner claimed through
///   ``CaptureProtectionState/claimNudge(for:)``. The nudge copy must never imply the screenshot
///   was blocked, degraded, or logged — it was none of those, and nothing about it leaves the
///   device.
///
/// Lifecycle traps accounted for:
/// - **Frontmost gating renders from state, never `.onAppear`/`.onDisappear`** — page-style
///   `TabView` lifecycle events are documented unreliable in this codebase (`FernletLockGate`,
///   `ProgressPhotoTimeline`). The hub attachment passes `isFrontmost: selectedTab == .personal`;
///   sheet attachments keep the default `true` because a presented sheet *is* frontmost.
/// - **Face ID bounces the scene through `.inactive`**, so the resign-active cover flashes
///   during every biometric prompt — precedented by `ProgressPhotoTimeline`, and harmless
///   because the modifier is applied INNER to `.fernletLockGate` (the lock overlay draws at
///   `zIndex(100)` in its own stack above this one), so the cover can never occlude the passcode
///   field.
/// - The screen is resolved from the view's **own window scene** via ``CaptureScreenProbe``
///   (never `UIScreen.main`, never `connectedScenes`), keeping two-window iPad states per-window
///   correct.
public struct CaptureProtectedModifier: ViewModifier {
    /// Stable per-surface name (e.g. "privateHub", "journalSheet") suffixed onto the cover's
    /// accessibility identifier (`capture.cover.<surface>`) so UI tests can assert the cover over
    /// one specific surface. No default — like a lock-gate scope, a protected surface must name
    /// itself rather than silently blend into another's assertions.
    let surface: String
    /// Whether protection is enforced; `false` passes content through untouched (the escape
    /// hatch mirroring `.fernletLockGate(active:)`). Note the UX appearance tests do NOT need it:
    /// neither trigger fires under automation (verified 2026-08-11 — `app.screenshot()` posts no
    /// notification), so protection stays active everywhere in DEBUG too.
    let active: Bool
    /// Whether this surface is the visible top-level page. Gates ONLY the Tier-1 pulse — the
    /// Tier-2 cover renders from state regardless, so a recording started elsewhere is already
    /// covering an offscreen hub page when the user swipes to it.
    let isFrontmost: Bool

    /// The injected trigger state; missing injection is a runtime crash by design, matching the
    /// lock gate's convention (sheets re-inject explicitly at every presentation site).
    @Environment(CaptureProtectionState.self) private var captureProtection
    /// Drives the resign-active half of the Tier-2 cover and gates the pulse.
    @Environment(\.scenePhase) private var scenePhase
    /// Honored by skipping the blur/nudge animations; the overlays still appear, because the
    /// nudge text — not the blur's arrival — carries the meaning.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The `UIScreen` this surface actually renders on, reported by ``CaptureScreenProbe``;
    /// nil until the probe lands in a window (during which the conservative aggregate answers).
    @State private var hostScreen: UIScreen?
    /// True while the Tier-1 blur is up (~2 s after a screenshot on this frontmost surface).
    @State private var isPulsing = false
    /// True while the once-per-session nudge banner is showing (~6 s, auto-fades).
    @State private var nudgeVisible = false
    /// Auto-clear task for the blur; cancelled and replaced on every new pulse.
    @State private var pulseClearTask: Task<Void, Never>?
    /// Auto-clear task for the nudge banner; cancelled and replaced on every new claim.
    @State private var nudgeClearTask: Task<Void, Never>?

    public func body(content: Content) -> some View {
        let covered = active && (captureProtection.isCaptured(on: hostScreen) || scenePhase != .active)
        ZStack {
            content
                .blur(radius: isPulsing ? 24 : 0)
                .saturation(isPulsing ? 0.4 : 1)
                .accessibilityHidden(covered)
                .background(CaptureScreenProbe { screen in
                    hostScreen = screen
                    if let screen { captureProtection.registerScreen(screen) }
                })

            if active && nudgeVisible {
                nudgeBanner
                    .zIndex(40)
            }

            if covered {
                cover
                    .zIndex(50)
            }
        }
        .onChange(of: captureProtection.screenshotPulse) { _, pulse in
            guard active, isFrontmost, scenePhase == .active else { return }
            reactToScreenshot(pulse)
        }
    }

    // MARK: Tier 1 — the screenshot pulse

    /// Blurs the surface briefly and, when ``CaptureProtectionState/claimNudge(for:)`` grants it,
    /// shows the once-per-session nudge. Both clear on their own; both animations are skipped
    /// under Reduce Motion. An unclaimed pulse deliberately leaves ``nudgeVisible`` alone — a
    /// second screenshot inside the nudge's display window must not yank the banner mid-read.
    private func reactToScreenshot(_ pulse: Int) {
        setPulsing(true, animation: .easeIn(duration: 0.12))
        pulseClearTask?.cancel()
        pulseClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            setPulsing(false, animation: .easeOut(duration: 0.35))
        }
        if captureProtection.claimNudge(for: pulse) {
            nudgeVisible = true
            nudgeClearTask?.cancel()
            nudgeClearTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    nudgeVisible = false
                } else {
                    withAnimation(.easeOut(duration: 0.35)) { nudgeVisible = false }
                }
            }
        }
    }

    /// Sets the blur state, animated unless Reduce Motion is on.
    private func setPulsing(_ value: Bool, animation: Animation) {
        if reduceMotion {
            isPulsing = value
        } else {
            withAnimation(animation) { isPulsing = value }
        }
    }

    // MARK: Overlays

    /// True while the surface's own screen (or the test override) reports active capture —
    /// chooses the "being recorded" copy over the neutral snapshot copy.
    private var isActivelyCaptured: Bool {
        captureProtection.isCaptured(on: hostScreen)
    }

    /// The cover's one-line explanation. Calm, cause-naming, and careful to claim nothing it
    /// does not do: the recording line names its own trigger and is obviously temporary; the
    /// snapshot line matches the progress-photo precedent ("Hidden").
    private var coverText: String {
        isActivelyCaptured ? "Hidden while your screen is being recorded" : "Hidden"
    }

    /// The Tier-2 opaque cover: full-bleed parchment over the WHOLE surface (never a partial
    /// redaction), a quiet icon, and the cause-naming line. One accessibility element carrying
    /// the explanation, identified as `capture.cover.<surface>` for UI tests.
    private var cover: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: isActivelyCaptured ? "eye.slash" : "lock.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Text(coverText)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                    .padding(.horizontal, 32)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coverText)
        .accessibilityIdentifier("capture.cover.\(surface)")
        .transition(.opacity)
    }

    /// The Tier-1 once-per-session nudge: a small calm card in the voice of the app's existing
    /// per-surface privacy copy. It must never imply the screenshot was blocked, degraded, or
    /// logged (it was none of those, and nothing leaves the device). Not hit-testable, so it can
    /// never eat a save-bar tap; it fades on its own.
    private var nudgeBanner: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("This is your private data — it stays safest on your device.")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Text("A screenshot leaves Fernlet's protection behind.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("capture.nudge.\(surface)")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Window-scene probe

/// An invisible, non-interactive `UIViewRepresentable` that reports the `UIScreen` of the view's
/// **own window scene** upward once it lands in a window (`didMoveToWindow`). This — not
/// `UIScreen.main` (deprecated, and wrong under Stage Manager / Split View) and not
/// `UIApplication.shared.connectedScenes` (cannot tell which window a view is in) — is how a
/// `captureProtected` surface learns which screen's `isCaptured` flag governs it. The callback is
/// deferred one hop so state never mutates mid-view-update.
private struct CaptureScreenProbe: UIViewRepresentable {
    /// Receives the resolved screen (nil when the view left the window hierarchy).
    var onResolve: (UIScreen?) -> Void

    /// Builds the zero-frame probe view.
    func makeUIView(context: Context) -> ProbeView {
        ProbeView(onResolve: onResolve)
    }

    /// Keeps the probe's callback current — the closure captures live view state and is
    /// recreated on every render.
    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onResolve = onResolve
    }

    /// The backing `UIView`: invisible, untouchable, and only alive to override
    /// `didMoveToWindow` — the earliest moment a view can honestly answer "which screen am I
    /// on?".
    final class ProbeView: UIView {
        /// Forwarded to on every window move; kept current by `updateUIView`.
        var onResolve: (UIScreen?) -> Void

        /// Creates the probe with its initial callback; the view never draws or hit-tests.
        init(onResolve: @escaping (UIScreen?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        /// Unsupported — the probe is never decoded from a nib.
        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CaptureScreenProbe.ProbeView does not support NSCoder")
        }

        /// Reports the (possibly nil) screen of the window scene the view just joined or left,
        /// deferred one main-actor hop so SwiftUI state is never mutated during a view update.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let screen = window?.windowScene?.screen
            let callback = onResolve
            Task { @MainActor in callback(screen) }
        }
    }
}

// MARK: - View extension

public extension View {
    /// Applies screenshot & screen-capture **friction** to a private surface — see
    /// ``CaptureProtectedModifier`` and ``CaptureProtectionState`` for the mechanism, and note
    /// the register: this is friction against the user's own casual self-sharing, never a
    /// security control, and must not be described as one.
    ///
    /// Attach at a surface's ROOT — the hub root (inner to `.fernletLockGate`, so the cover can
    /// never occlude the passcode field) or a sheet type's own `body` (one edit per type,
    /// impossible to forget at a new call site, and structurally unable to bleed onto an
    /// out-of-scope screen). Requires a ``CaptureProtectionState`` in the environment; a missing
    /// injection is a runtime crash by the same convention as the lock gate's service.
    ///
    /// - Parameters:
    ///   - surface: Stable name for this surface (e.g. "journalSheet"); becomes the cover's
    ///     accessibility identifier suffix (`capture.cover.<surface>`). No default — a protected
    ///     surface names itself.
    ///   - active: Whether protection is enforced; `false` passes content through unmodified.
    ///   - isFrontmost: Whether this surface is the visible page — gates only the Tier-1
    ///     screenshot pulse (pass `selectedTab == .personal` for the hub; leave `true` for
    ///     sheets, which are frontmost by construction). The Tier-2 cover ignores it and renders
    ///     from state.
    /// - Returns: The content wrapped in the capture-friction overlay stack.
    func captureProtected(
        surface: String,
        active: Bool = true,
        isFrontmost: Bool = true
    ) -> some View {
        modifier(CaptureProtectedModifier(surface: surface, active: active, isFrontmost: isFrontmost))
    }
}

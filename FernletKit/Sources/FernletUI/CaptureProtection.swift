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
/// - The `NotificationCenter` both observers attach to is injectable (production: `.default`,
///   where UIKit actually posts). Tests MUST pass a private center: the two trigger notifications
///   are process-global, `.serialized` orders tests only *within* one suite, and a screenshot post
///   from a concurrently-running sibling suite would otherwise bump an unrelated test's
///   ``screenshotPulse``.
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
    /// by a screenshot taken while a protected surface was actually frontmost AND unoccluded.
    /// The invariant is that the session's one nudge is never silently spent on a screen that
    /// showed no nudge, and THREE gates uphold it: a screenshot on Home/Food/Move/Social claims
    /// nothing (the modifier's `isFrontmost`); one taken while a surface's own Tier-2 cover is
    /// up claims nothing (the modifier skips the reaction — the screenshot captured the cover,
    /// and the banner would draw invisibly beneath it); and one taken on the LOCKED Private hub
    /// or under a covering root sheet claims nothing (the hub's call sites AND the lock-gate
    /// occlusion and the root-sheet slots into `isFrontmost`).
    public private(set) var nudgePulse: Int? = nil

    /// Test/UI-test override for the capture verdict: non-nil forces every
    /// ``isCaptured(on:)`` answer to that value regardless of registered screens. The seam for
    /// the `FERNLET_UI_TEST_FORCE_CAPTURE` launch flag and the view-level tests — real capture
    /// (`isCaptured`) cannot be driven from automation, so this is the only honest way to render
    /// the cover under test. Never set outside DEBUG hooks or tests.
    public var captureOverride: Bool? = nil

    /// Aggregate capture verdict: the override when one is set, otherwise the same conservative
    /// any-screen answer as ``isCaptured(on:)`` with a nil screen — registered captures first,
    /// then a live read of every connected window scene's screen, so the verdict fails toward
    /// covering even before the FIRST surface has registered. Views that know their own screen
    /// should prefer ``isCaptured(on:)``; this aggregate exists for pre-resolution frames (a
    /// probe that has not landed in a window yet) and for tests.
    public var isCaptured: Bool { isCaptured(on: nil) }

    // MARK: Internals

    /// Weak boxes of every screen a `captureProtected` probe has registered, keyed by
    /// `ObjectIdentifier`. Weak so a dismissed scene's screen dies naturally; pruned on refresh.
    @ObservationIgnored private var registeredScreens: [ObjectIdentifier: WeakScreenBox] = [:]
    /// Holds the two `NotificationCenter` observer tokens and removes them from the center they
    /// were registered on when this state is released. A nonisolated bag rather than a stored
    /// array because this module builds in Swift 6 language mode, where a `@MainActor` class's
    /// nonisolated `deinit` may not touch a non-Sendable stored property — the bag's own
    /// (unisolated) `deinit` does the removal instead, running as part of this object's teardown.
    @ObservationIgnored private let observerBag: NotificationObserverBag
    /// Reads one screen's captured flag — `{ $0.isCaptured }` in production, injectable so unit
    /// tests can simulate a capture transition (posting `capturedDidChangeNotification` then
    /// asserting the re-read), which real automation cannot trigger.
    @ObservationIgnored private let readScreenIsCaptured: @MainActor (UIScreen) -> Bool
    /// Posts the once-per-session nudge copy as a VoiceOver announcement — production posts
    /// `AccessibilityNotification.Announcement`; injectable so a unit test can record what was
    /// (and was not) announced, which the real accessibility system never reports back.
    @ObservationIgnored private let postAccessibilityAnnouncement: @MainActor (String) -> Void

    /// Creates the state and installs both notification observers once.
    ///
    /// - Parameters:
    ///   - captureOverride: Initial ``captureOverride``; pass `true` for the
    ///     `FERNLET_UI_TEST_FORCE_CAPTURE` launch hook, nil in production.
    ///   - readScreenIsCaptured: Test seam for the per-screen captured read; nil (production)
    ///     resolves to `{ $0.isCaptured }` in the init body — deliberately not a default-argument
    ///     value, since `UIScreen.isCaptured` is main-actor state.
    ///   - postAccessibilityAnnouncement: Test seam for the VoiceOver nudge announcement; nil
    ///     (production) resolves to posting `AccessibilityNotification.Announcement` in the
    ///     init body.
    ///   - notificationCenter: The center both trigger observers attach to. Defaults to
    ///     `.default`, which is the only center UIKit posts the real notifications on, so
    ///     production must never pass anything else. A test that posts either trigger MUST pass a
    ///     private `NotificationCenter()`: the notifications are process-global, so a post from a
    ///     test running concurrently in another suite would otherwise land in this state.
    public init(
        captureOverride: Bool? = nil,
        readScreenIsCaptured: (@MainActor (UIScreen) -> Bool)? = nil,
        postAccessibilityAnnouncement: (@MainActor (String) -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.captureOverride = captureOverride
        self.readScreenIsCaptured = readScreenIsCaptured ?? { $0.isCaptured }
        self.postAccessibilityAnnouncement = postAccessibilityAnnouncement
            ?? { AccessibilityNotification.Announcement($0).post() }
        self.observerBag = NotificationObserverBag(center: notificationCenter)
        // The blocks run nonisolated under Swift 6 — never touch state directly; hop first.
        observerBag.hold(notificationCenter.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenshot() }
        })
        // `object: nil`, and every post re-reads OUR registered screens rather than trusting the
        // notification's subject — per-screen state, one observer.
        observerBag.hold(notificationCenter.addObserver(
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
    /// answer when the probe has resolved; the conservative any-screen fallback
    /// (``anyKnownScreenIsCaptured()``) while the screen is still unknown. The fallback
    /// consults the LIVE connected window scenes as well as the registry, because before the
    /// first protected surface has ever registered (the outer paged `TabView` instantiates its
    /// pages lazily, so a fresh launch that never visited the Private tab has an empty
    /// registry) the registry alone answers false — and the first surface mounted during an
    /// already-running recording would draw its pre-resolution frames uncovered.
    public func isCaptured(on screen: UIScreen?) -> Bool {
        if let captureOverride { return captureOverride }
        guard let screen else { return anyKnownScreenIsCaptured() }
        return capturedScreenIDs.contains(ObjectIdentifier(screen))
    }

    // MARK: Nudge bookkeeping

    /// Claims the once-per-session nudge for a reacting surface. The FIRST claim wins the
    /// session — and posts ``CaptureNudgeCopy/spokenAnnouncement`` as a VoiceOver announcement
    /// exactly once, so the friction is perceivable without the visual channel (the banner is a
    /// non-modal overlay VoiceOver never moves focus to on its own, and the blur is purely
    /// visual). Every surface reacting to that same pulse also shows the banner (the hub under
    /// a protected sheet and the sheet itself blur together and agree) without re-announcing;
    /// every later pulse shows none. Because only a frontmost, scene-active, UNOCCLUDED
    /// modifier calls this (see ``nudgePulse`` for the three gates), the session's nudge is
    /// never consumed invisibly.
    public func claimNudge(for pulse: Int) -> Bool {
        if let nudgePulse { return nudgePulse == pulse }
        nudgePulse = pulse
        postAccessibilityAnnouncement(CaptureNudgeCopy.spokenAnnouncement)
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

    /// Conservative pre-resolution aggregate: any registered screen currently captured, or —
    /// because the registry can be legitimately empty before the first probe lands — any
    /// connected window scene's screen reporting capture through the injected per-screen read.
    /// The `connectedScenes` enumeration is deliberate here and ONLY here: the design brief
    /// bans it for per-view attribution (it cannot tell which window a view is in), but this is
    /// the opposite question — "is ANY screen captured?" — asked exactly while a view's own
    /// screen is unknown, where over-covering is the correct failure direction.
    private func anyKnownScreenIsCaptured() -> Bool {
        if !capturedScreenIDs.isEmpty { return true }
        for scene in UIApplication.shared.connectedScenes {
            guard let screen = (scene as? UIWindowScene)?.screen else { continue }
            if readScreenIsCaptured(screen) { return true }
        }
        return false
    }
}

/// Owns `NotificationCenter` block-observer tokens for ``CaptureProtectionState`` and removes
/// them in its own `deinit`. Deliberately `nonisolated`: in Swift 6 language mode a `@MainActor`
/// class's nonisolated `deinit` may not touch a non-Sendable stored token array, so teardown is
/// delegated to this bag, which deallocates (and unregisters) exactly when its owner does.
/// `NotificationCenter.removeObserver` is thread-safe; the tokens are only ever appended from
/// the owner's main-actor init, so there is no concurrent mutation.
private nonisolated final class NotificationObserverBag {
    /// The center the held tokens were registered on — removal must target the SAME center the
    /// observer was added to, so this is carried rather than assumed to be `.default` (tests
    /// inject a private center).
    private let center: NotificationCenter
    /// The held observer tokens, removed on deallocation.
    private var tokens: [NSObjectProtocol] = []

    /// Creates a bag that will unregister its tokens from `center`.
    init(center: NotificationCenter) {
        self.center = center
    }

    /// Takes ownership of one observer token for the lifetime of the bag.
    func hold(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
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

// MARK: - Nudge copy

/// The Tier-1 nudge copy, shared by the visual banner and the VoiceOver announcement so the
/// non-visual channel always carries exactly the meaning the visual one does — a VoiceOver user
/// receives no other Tier-1 signal, since the blur is purely visual and the banner is a
/// non-modal overlay that auto-dismisses. Per the design brief's copy rules, this must never
/// imply the screenshot was blocked, degraded, or logged: it was none of those, and nothing
/// about it leaves the device.
public enum CaptureNudgeCopy {
    /// The banner's bolded first line.
    public static let headline = "This is your private data — it stays safest on your device."
    /// The banner's quieter second line.
    public static let detail = "A screenshot leaves Fernlet's protection behind."
    /// The single spoken form: both lines, in reading order.
    public static var spokenAnnouncement: String { "\(headline) \(detail)" }
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
/// - **Tier-1 pulse** on a screenshot taken while this surface is frontmost, scene-active, and
///   NOT under its own Tier-2 cover: a ~2 s blur + desaturation of the content (the user knows
///   what they just did; the point is a beat of hesitation, not alarm), plus a calm
///   once-per-session nudge banner claimed through
///   ``CaptureProtectionState/claimNudge(for:)`` and spoken once via a VoiceOver announcement.
///   The nudge copy (``CaptureNudgeCopy``) must never imply the screenshot was blocked,
///   degraded, or logged — it was none of those, and nothing about it leaves the device. The
///   cover's arrival also resigns keyboard focus in the surface's own window, because the
///   system keyboard renders in a separate window above the cover and its QuickType bar echoes
///   the text being typed.
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
    /// Whether this surface is the visible, UNOCCLUDED top-level page. Gates ONLY the Tier-1
    /// pulse — the Tier-2 cover renders from state regardless, so a recording started elsewhere
    /// is already covering an offscreen hub page when the user swipes to it. Call sites must
    /// compose every opaque occluder they know about into this flag (the hub ANDs
    /// `selectedTab == .personal`, the lock-gate overlay via `FernletLockGateOcclusion`, and
    /// the root-sheet slots): a pulse reacted to beneath an occluder would spend the
    /// once-per-session nudge on a banner nobody can see. The modifier handles the one occluder
    /// it can see itself — its own Tier-2 cover — in the pulse guard.
    let isFrontmost: Bool

    /// The injected trigger state; missing injection is a runtime crash by design, matching the
    /// lock gate's convention (sheets re-inject explicitly at every presentation site).
    @Environment(CaptureProtectionState.self) private var captureProtection
    /// Drives the resign-active half of the Tier-2 cover and gates the pulse.
    @Environment(\.scenePhase) private var scenePhase
    /// Honored by skipping the blur/nudge animations; the overlays still appear, because the
    /// nudge text — not the blur's arrival — carries the meaning.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The `UIScreen` this surface actually renders on, derived from ``CaptureScreenProbe``'s
    /// window report; nil until the probe lands (during which the conservative aggregate
    /// answers).
    @State private var hostScreen: UIScreen?
    /// The `UIWindow` this surface renders in, reported by ``CaptureScreenProbe``; nil until
    /// the probe lands, and nil again once the view leaves the hierarchy (so a dismissed window
    /// is never retained). Held so the cover's arrival can `endEditing` OUR OWN window — the
    /// system keyboard lives in its own window ABOVE the app's, so it stays in recordings and
    /// snapshots even while the opaque cover is up, and its QuickType bar echoes the text being
    /// typed.
    @State private var hostWindow: UIWindow?
    /// True while the Tier-1 blur is up (~2 s after a screenshot on this frontmost surface).
    @State private var isPulsing = false
    /// True while the once-per-session nudge banner is showing (~6 s, auto-fades).
    @State private var nudgeVisible = false
    /// Auto-clear task for the blur; cancelled and replaced on every new pulse.
    @State private var pulseClearTask: Task<Void, Never>?
    /// Auto-clear task for the nudge banner; cancelled and replaced on every new claim.
    @State private var nudgeClearTask: Task<Void, Never>?

    /// Whether the Tier-2 opaque cover is up: protection enforced, and (the surface's own
    /// screen is captured OR the scene is not `.active`). A computed property rather than a
    /// body-local so `onChange(of:)` can watch its transitions for the keyboard resignation and
    /// the pulse guard can consult it.
    private var covered: Bool {
        active && (captureProtection.isCaptured(on: hostScreen) || scenePhase != .active)
    }

    public func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: isPulsing ? 24 : 0)
                .saturation(isPulsing ? 0.4 : 1)
                .accessibilityHidden(covered)
                .background(CaptureScreenProbe { window in
                    hostWindow = window
                    let screen = window?.windowScene?.screen
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
        .onChange(of: covered) { _, isCovered in
            // The cover blocks touches on OUR content, but the system keyboard lives in its own
            // window above this one: it stays visible in recordings, mirroring, and app-switcher
            // snapshots over the opaque cover, keeps accepting taps, and its QuickType bar
            // echoes the sensitive text being typed. Resign focus the moment the cover arrives
            // so the recording contains the panel — not the content, and not the content's
            // keyboard either. The `scenePhase != .active` path rides the same transition,
            // keeping the keyboard out of switcher snapshots too.
            guard isCovered else { return }
            hostWindow?.endEditing(true)
        }
        .onChange(of: captureProtection.screenshotPulse) { _, pulse in
            // `!covered`: while the Tier-2 cover is up the screenshot captured the COVER, not
            // the content, and the nudge banner would render invisibly beneath the opaque cover
            // (zIndex 40 under 50) — reacting would silently spend the once-per-session nudge.
            // Skip the whole reaction; the pulse still bumps for surfaces that ARE visible.
            guard active, isFrontmost, scenePhase == .active, !covered else { return }
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
    /// per-surface privacy copy, its lines shared with the VoiceOver announcement through
    /// ``CaptureNudgeCopy`` (see that type for the copy rules). Not hit-testable, so it can
    /// never eat a save-bar tap; it fades on its own.
    private var nudgeBanner: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text(CaptureNudgeCopy.headline)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Text(CaptureNudgeCopy.detail)
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

/// An invisible, non-interactive `UIViewRepresentable` that reports the view's **own window**
/// upward once it lands in one (`didMoveToWindow`). The modifier derives the window scene's
/// `UIScreen` from it — this, not `UIScreen.main` (deprecated, and wrong under Stage Manager /
/// Split View) and not `UIApplication.shared.connectedScenes` (cannot tell which window a view
/// is in), is how a `captureProtected` surface learns which screen's `isCaptured` flag governs
/// it — and keeps the window itself so the cover's arrival can resign keyboard focus in the
/// window that owns the focused field. The callback is deferred one hop so state never mutates
/// mid-view-update.
private struct CaptureScreenProbe: UIViewRepresentable {
    /// Receives the resolved window (nil when the view left the window hierarchy).
    var onResolve: (UIWindow?) -> Void

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
    /// `didMoveToWindow` — the earliest moment a view can honestly answer "which window (and
    /// therefore which screen) am I in?".
    final class ProbeView: UIView {
        /// Forwarded to on every window move; kept current by `updateUIView`.
        var onResolve: (UIWindow?) -> Void

        /// Creates the probe with its initial callback; the view never draws or hit-tests.
        init(onResolve: @escaping (UIWindow?) -> Void) {
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

        /// Reports the (possibly nil) window the view just joined or left, deferred one
        /// main-actor hop so SwiftUI state is never mutated during a view update.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let window = self.window
            let callback = onResolve
            Task { @MainActor in callback(window) }
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
    ///   - isFrontmost: Whether this surface is the visible, UNOCCLUDED page — gates only the
    ///     Tier-1 screenshot pulse (the hub passes `selectedTab == .personal` ANDed with "no
    ///     lock-gate overlay" and "no covering root sheet"; leave `true` for sheets, which are
    ///     frontmost by construction). The Tier-2 cover ignores it and renders from state. The
    ///     modifier additionally skips the pulse on its own while its Tier-2 cover is up, so
    ///     the once-per-session nudge is never spent beneath an occluder.
    /// - Returns: The content wrapped in the capture-friction overlay stack.
    func captureProtected(
        surface: String,
        active: Bool = true,
        isFrontmost: Bool = true
    ) -> some View {
        modifier(CaptureProtectedModifier(surface: surface, active: active, isFrontmost: isFrontmost))
    }
}

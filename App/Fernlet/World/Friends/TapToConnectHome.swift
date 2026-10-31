import FernletConnections
import FernletUI
import Foundation
import Observation
import ProximityKit
import SwiftUI

// MARK: - TapToConnectCopy

/// The words of meeting someone new by tapping phones on Home (World Friends screens 1, 2 and 8, approved
/// 2026-10-31). The plate, Sprout's "Ooh! Who's that?", the question, Not now and Start hangout are the owner's;
/// the question sheet's two lines under the name are the approved `fr-tap-found` page's; the wait after Start
/// hangout and Sprout's "Maybe another time." are drafts for the owner's review.
nonisolated enum TapToConnectCopy {
    static let plateTitle = LocalizedStringResource(
        "tapToConnect.plate.title", defaultValue: "Someone with Fernlet is close",
        comment: "World Home plate while another phone with Fernlet, also on Home, is within about 3 m (10 ft). Never names them")
    static let plateDetail = LocalizedStringResource(
        "tapToConnect.plate.detail", defaultValue: "Hold your phones together to connect",
        comment: "World Home plate, under 'Someone with Fernlet is close': hold the two phones top to top to meet")
    static let sproutClose = LocalizedStringResource(
        "tapToConnect.sprout.close", defaultValue: "Ooh! Who's that?",
        comment: "World Home, the companion's speech once when another phone with Fernlet comes within about 3 m")
    static let sproutDeclined = LocalizedStringResource(
        "tapToConnect.sprout.declined", defaultValue: "Maybe another time.",
        comment: "World Home, the companion's speech once after the person met by tapping phones said Not now. Gentle; no blame")
    static let notNow = LocalizedStringResource(
        "tapToConnect.notNow", defaultValue: "Not now",
        comment: "Tap-to-connect question sheet, top left: says no to the hangout; nothing more is shared")
    static let start = LocalizedStringResource(
        "tapToConnect.start", defaultValue: "Start hangout",
        comment: "Tap-to-connect question sheet's button: says yes to a hangout with the person whose phone was tapped")
    static let explainer = LocalizedStringResource(
        "tapToConnect.explainer",
        defaultValue: "You're both asked. If you both say yes, a hangout starts: photos, messages and walks together while you're in person.",
        comment: "Tap-to-connect question sheet, under the other person's companion and name")

    /// "Start a hangout with Rae?", the question sheet's title.
    static func question(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("tapToConnect.question", defaultValue: "Start a hangout with \(name)?",
                                comment: "Tap-to-connect question sheet's title; the name the other person appears as")
    }

    /// "The name Rae appears as", under their name.
    static func appearsAs(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("tapToConnect.appearsAs", defaultValue: "The name \(name) appears as",
                                comment: "Tap-to-connect question sheet, under the other person's name: it is the name they chose to appear as")
    }

    /// "Waiting for Rae…", in place of Start hangout once this person said yes.
    static func waiting(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("tapToConnect.waiting", defaultValue: "Waiting for \(name)…",
                                comment: "Tap-to-connect question sheet after Start hangout, until the other person answers; their name")
    }

    /// What VoiceOver says once as the plate appears: its two lines.
    static var plateAnnouncement: String {
        "\(String(localized: plateTitle)). \(String(localized: plateDetail))"
    }
}

// MARK: - TapToConnectLine

/// What Sprout says about a tap on Home, each line once (World Friends §1.2, §1.3), and how long a said line
/// stays Sprout's line (the bubble itself fades after its own notice window), as the discovery lines stand.
nonisolated enum TapToConnectLine: Equatable, Sendable {
    /// "Ooh! Who's that?": the rings just appeared.
    case someoneClose
    /// "Maybe another time.": the other person said Not now.
    case maybeAnotherTime

    /// How long a said line stands before Sprout's usual line returns.
    static let standing = Duration.seconds(20)

    /// The line's words.
    var text: LocalizedStringResource {
        switch self {
        case .someoneClose: TapToConnectCopy.sproutClose
        case .maybeAnotherTime: TapToConnectCopy.sproutDeclined
        }
    }
}

// MARK: - TapToConnectAppearanceGate

/// Whether the rings' appearance is a new one, so Sprout's line and VoiceOver's announcement of the plate come once
/// per appearance and never again as the closeness changes (World Friends §1.2). Rings that blink out at the 3 m
/// edge and back within ``rearmSeconds`` are the same appearance, so jitter at the edge never repeats either.
nonisolated struct TapToConnectAppearanceGate: Equatable, Sendable {
    /// How long the rings must stay gone before their next appearance counts as new.
    static let rearmSeconds: TimeInterval = 10

    /// Whether the rings show now.
    private(set) var isShowing = false
    /// When the rings last went, or nil before they ever showed.
    private var hiddenSince: Date?

    /// Folds in whether the rings show at `date`; true only on the edge that starts a new appearance.
    mutating func observe(showing: Bool, at date: Date) -> Bool {
        guard showing != isShowing else { return false }
        isShowing = showing
        guard showing else {
            hiddenSince = date
            return false
        }
        guard let hiddenSince else { return true }
        return date.timeIntervalSince(hiddenSince) >= Self.rearmSeconds
    }
}

// MARK: - TapToConnectRingStyle

/// How the rings draw (`fr-tap-home` draft 2): three teal rings centred just below the top edge, 300, 430 and
/// 560 pt across at 90 %, 60 % and 35 % opacity as the approved page stills them. They ripple outward, and grow
/// stronger (more opaque, thicker) as the phones come together; with Reduce Motion they stand still at the
/// page's sizes and only their opacity follows the closeness.
nonisolated enum TapToConnectRingStyle {
    /// One ring as it is drawn.
    struct Ring: Equatable, Sendable {
        /// Its radius, in points from the centre.
        let radius: CGFloat
        /// Its opacity, 0 … 1.
        let opacity: Double
        /// Its stroke, in points.
        let lineWidth: CGFloat
    }

    /// The rings' teal (the blue button's and the pin's).
    static let colour = WorldPalette.rgb(0x5FB8C9)
    /// How far below the top edge the rings' centre sits.
    static let centreDrop: CGFloat = 10
    /// The approved page's still radii and opacities, innermost first.
    static let stillRadii: [CGFloat] = [150, 215, 280]
    static let stillOpacities: [Double] = [0.9, 0.6, 0.35]
    /// The ripple: each ring grows from ``innerRadius`` to ``outerRadius`` in ``period`` seconds, a third apart.
    static let innerRadius: CGFloat = 90
    static let outerRadius: CGFloat = 300
    static let period: TimeInterval = 2.4

    /// The closeness as a strength, 0 … 1 (none, or a reading that is not a number, is 0).
    static func strength(_ closeness: Double?) -> Double {
        guard let closeness, closeness.isFinite else { return 0 }
        return min(max(closeness, 0), 1)
    }

    /// How opaque the rings are at `strength`: faint far off, full touching.
    static func level(_ strength: Double) -> Double { 0.4 + 0.6 * min(max(strength, 0), 1) }

    /// How thick the rings are at `strength`: 3 pt far off, 5 pt touching (the page's 4 pt half way).
    static func lineWidth(_ strength: Double) -> CGFloat { 3 + 2 * CGFloat(min(max(strength, 0), 1)) }

    /// The rings at `strength`: rippling at `time` (seconds on any steady clock), or still when `time` is nil.
    static func rings(strength: Double, time: TimeInterval?) -> [Ring] {
        let strongest = Self.level(strength)
        let width = Self.lineWidth(strength)
        guard let time, time.isFinite else {
            return zip(stillRadii, stillOpacities).map { Ring(radius: $0, opacity: $1 * strongest, lineWidth: width) }
        }
        // R2: bounded by the three still rings.
        return stillRadii.indices.map { (index: Int) -> Ring in
            let raw = time / period + Double(index) / Double(stillRadii.count)
            let progress = raw - raw.rounded(.down)
            let fadeIn = min(progress / 0.15, 1)
            return Ring(radius: innerRadius + (outerRadius - innerRadius) * CGFloat(progress),
                        opacity: 0.9 * fadeIn * (1 - progress) * strongest, lineWidth: width)
        }
    }
}

// MARK: - TapToConnectSnapshot

/// What Home draws for the tap at one moment, read off the live presentation, or in DEBUG off a staged scene for
/// screenshots (``TapToConnectStage``), since a simulator has no second phone.
struct TapToConnectSnapshot: Equatable {
    /// 0 far … 1 touching, or nil with nobody within about 3 m.
    var closeness: Double?
    /// The question, once both phones tapped.
    var question: TapToConnectQuestion?
    /// This person said Start hangout and the other has not answered yet.
    var isWaitingForPeer = false

    /// Whether the question sheet is up: the question, or the wait after Start hangout.
    var isQuestionUp: Bool { question != nil || isWaitingForPeer }

    /// The staged scene, or the presentation as it stands.
    static func read(_ presentation: TapToConnectPresentation) -> TapToConnectSnapshot {
        if let staged = TapToConnectStage.current { return staged }
        return TapToConnectSnapshot(closeness: presentation.closeness, question: presentation.question,
                                    isWaitingForPeer: presentation.isWaitingForPeer)
    }
}

extension TapToConnectQuestion {
    /// The name the sheet shows: theirs, or the app's placeholder for someone whose name is not known.
    var shownName: String {
        PeerNameDisplay.shown(displayName, fingerprint: nil, placeholder: .nearby, in: .fernlet)
    }

    /// Whether they gave a name to show (the placeholder never takes "The name … appears as").
    var hasName: Bool { PeerNameDisplay.personName(displayName, fingerprint: nil, in: .fernlet) != nil }

    /// A question with no name and the standard look, for the wait when no question was seen.
    static let unnamed = TapToConnectQuestion(displayName: "", appearance: nil)
}

// MARK: - TapToConnectStage

/// DEBUG `FERNLET_UI_TEST_TAP=close|question|waiting` stands a tap scene in on Home for screenshots: someone
/// within 3 m (the rings and the plate), the question from "Rae", or the wait after Start hangout. Display only:
/// the radio and its answers are untouched, and Release builds read nil.
enum TapToConnectStage {
    #if DEBUG
    /// The staged scene, if any.
    static var current: TapToConnectSnapshot? {
        let rae = TapToConnectQuestion(displayName: "Rae", appearance: nil)
        switch ProcessInfo.processInfo.environment["FERNLET_UI_TEST_TAP"] {
        case "close": return TapToConnectSnapshot(closeness: 0.55)
        case "question": return TapToConnectSnapshot(closeness: 0.95, question: rae)
        case "waiting": return TapToConnectSnapshot(closeness: 0.95, question: rae, isWaitingForPeer: true)
        default: return nil
        }
    }
    #else
    static var current: TapToConnectSnapshot? { nil }
    #endif
}

// MARK: - TapToConnectHomeCue

/// Home's side of the tap, shared by both Homes (the map and the location-off scene): whether the rings and the
/// plate show and how strongly, Sprout's line while it stands, and the question last asked (the wait after Start
/// hangout still names the person, though the rendezvous cleared its question). `WorldMapHome` holds it as
/// `@State`; ``TapToConnectHomeLayer`` drives it and hands it to the plates through the environment.
@MainActor
@Observable
final class TapToConnectHomeCue {
    /// Sprout's line about the tap, while it stands.
    var line: TapToConnectLine?
    /// Whether the rings and the plate show: someone within about 3 m while Home is the front page.
    private(set) var isRinging = false
    /// How strongly the rings draw, 0 … 1.
    private(set) var strength: Double = 0
    /// The question last asked.
    var lastQuestion: TapToConnectQuestion?
    @ObservationIgnored private var gate = TapToConnectAppearanceGate()

    /// Folds in the closeness while Home is or is not the front page at `date`; true when the rings' appearance
    /// is new (Sprout then says "Ooh! Who's that?", and the caller announces the plate). Rings that go take
    /// Sprout's line with them.
    func update(closeness: Double?, isFrontmost: Bool, at date: Date) -> Bool {
        let showing = isFrontmost && closeness != nil
        isRinging = showing
        strength = TapToConnectRingStyle.strength(closeness)
        if !showing, line == .someoneClose { line = nil }
        guard gate.observe(showing: showing, at: date) else { return false }
        line = .someoneClose
        return true
    }
}

// MARK: - TapToConnectHomeLayer

/// Meeting someone new by tapping phones, on both Homes (World Friends §1.2–1.4, screens 1, 2 and 8): it tells the
/// radio when Home is the front page (``FernletStore/setHomeFrontmost(_:)``, the run policy's one Home input),
/// draws the rings over Home, plays the tap's one firm haptic, gives Sprout its lines, and presents the question.
///
/// **What never shows:** a name, a companion or a direction before the tap; the plate and the rings say only that
/// someone with Fernlet is close. **VoiceOver:** the plate is announced once per appearance, not as the closeness
/// changes; the haptic marks the tap; the question sheet takes the focus. **The question** stays up through the
/// wait after Start hangout (no Not now and no swipe then: a yes can't be taken back), and goes when the hangout
/// starts, the other says Not now (Sprout then says "Maybe another time." once), or the radio stops.
struct TapToConnectHomeLayer: ViewModifier {
    let store: FernletStore
    let cue: TapToConnectHomeCue
    /// Whether Home is the front page of an active app with nothing over it: no panel, sheet, passport or other tab.
    let isFrontmost: Bool

    private var presentation: TapToConnectPresentation { store.tapToConnect.presentation }

    func body(content: Content) -> some View {
        let snapshot = TapToConnectSnapshot.read(presentation)
        return content
            .environment(cue)
            .overlay { TapToConnectRings(cue: cue).ignoresSafeArea() }
            .onChange(of: isFrontmost, initial: true) { _, front in frontmostChanged(front) }
            .onDisappear { store.setHomeFrontmost(false) }
            .onChange(of: RingKey(closeness: snapshot.closeness, isFrontmost: isFrontmost), initial: true) { _, key in
                ringsMoved(key)
            }
            .onChange(of: snapshot.question, initial: true) { _, question in
                if let question { cue.lastQuestion = question }
            }
            .onChange(of: snapshot.isWaitingForPeer) { _, waiting in if waiting { announceWaiting() } }
            // §1.2: both phones give one firm haptic at the tap (the phones held together is a hold recognized).
            .fernletFeedback(.held, trigger: presentation.tapCount) { old, new in new > old }
            .onChange(of: presentation.declinedThereCount) { old, new in if new > old { declinedThere() } }
            .task(id: cue.line) { await letLineStand() }
            .sheet(isPresented: questionShown(snapshot)) {
                TapToConnectQuestionSheet(question: snapshot.question ?? cue.lastQuestion ?? .unnamed,
                                          isWaiting: snapshot.isWaitingForPeer) { presentation.answer($0) }
                    .worldDesignLanguage()
                    .interactiveDismissDisabled(snapshot.isWaitingForPeer)
            }
    }

    /// What moves the rings: the closeness, and Home coming to the front or leaving it.
    private struct RingKey: Equatable {
        let closeness: Double?
        let isFrontmost: Bool
    }

    /// Home came to the front or left it: the radio follows, and a line Sprout was saying goes with Home.
    private func frontmostChanged(_ front: Bool) {
        store.setHomeFrontmost(front)
        guard !front else { return }
        cue.line = nil
    }

    /// The rings moved: on a new appearance, the plate is announced once.
    private func ringsMoved(_ key: RingKey) {
        guard cue.update(closeness: key.closeness, isFrontmost: key.isFrontmost, at: Date()) else { return }
        FernletAnnouncer.system.announce(.status, resolved: TapToConnectCopy.plateAnnouncement)
    }

    /// The other person said Not now: Sprout says so once, gently, and VoiceOver hears it.
    private func declinedThere() {
        guard isFrontmost else { return }
        cue.line = .maybeAnotherTime
        FernletAnnouncer.system.announce(.status, resolved: String(localized: TapToConnectCopy.sproutDeclined))
    }

    /// Start hangout was said: VoiceOver hears who it now waits for (the button it pressed is gone).
    private func announceWaiting() {
        guard let question = presentation.question ?? cue.lastQuestion else { return }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: TapToConnectCopy.waiting(question.shownName)))
    }

    /// Lets a said line stand, then gives Sprout its usual line back (a DEBUG stage keeps it for the screenshot).
    private func letLineStand() async {
        guard cue.line != nil, TapToConnectStage.current == nil else { return }
        do {
            try await Task.sleep(for: TapToConnectLine.standing)
        } catch {
            return
        }
        cue.line = nil
    }

    /// The sheet's presentation: up with the question or the wait; a swipe down is Not now (never while waiting,
    /// when the sheet can't be swiped).
    private func questionShown(_ snapshot: TapToConnectSnapshot) -> Binding<Bool> {
        Binding(get: { snapshot.isQuestionUp && isFrontmost },
                set: { shown in if !shown { presentation.answer(false) } })
    }
}

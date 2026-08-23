//
//  FernletDismissalWindow.swift
//  FernletUI
//
//  How long a self-dismissing surface stays (accessibility review 2026-08-22, T2-5).
//
//  Every auto-dismissing toast in the app is budgeted for a *sighted tap*: see it, reach it, tap
//  it. That budget is wrong for someone navigating with an assistive technology. A VoiceOver user
//  has to notice a new overlay exists at all, swipe to it, and double-tap; a Switch Control scan
//  cannot finish a single pass of a populated page in four seconds at the default scan rate. The
//  toast is gone before it could be reached — and with it whatever it offered (an Undo, an
//  Adjust, an "open the other app"), which for a sighted user was the fastest correction path and
//  for an assistive-technology user was never a path at all.
//
//  This is the generalization of the pattern Batch A1 shipped by hand in the Worry Box, where the
//  6-second "Keep it" window guards the PERMANENT deletion of a sealed row and was stretched to 20.
//  Two knobs, because the two honest answers differ: extend the window, or do not auto-dismiss at
//  all (the right answer whenever dismissal REMOVES CONTROLS from the accessibility tree rather
//  than merely hiding a notice).
//
//  It is a value with an injected read, not a free function, for the same reason the announcer is:
//  `UIAccessibility.isVoiceOverRunning` cannot be forced from a unit test, so the branch that only
//  runs for assistive-technology users would otherwise be the one branch nothing ever exercises.
//

import Foundation
import UIKit

/// Decides how long a self-dismissing surface should stay, given whether an assistive technology
/// that needs longer to reach it is running.
///
/// Production callers use ``system``. A test constructs its own with a fixed flag and asserts both
/// branches — including the "never auto-dismiss" one, which is the whole point of the type.
///
/// **Read at the moment of use, never cached.** VoiceOver and Switch Control can both be turned on
/// mid-session (Siri, the accessibility shortcut, a Shortcuts automation), so a window decided at
/// view construction would be the wrong one for the user who turned VoiceOver on ten seconds ago.
///
/// **Concurrency:** main-actor. `UIAccessibility`'s running flags are main-actor state and every
/// caller is a SwiftUI view body or a `@MainActor` task.
public struct FernletDismissalWindow {
    /// The production window, reading the live `UIAccessibility` flags.
    public static let system = FernletDismissalWindow()

    /// The stretched window for a transient surface that carries an ACTION — an Undo, an Adjust,
    /// a link into another app. Matches the Worry Box's hand-tuned 20 s, which the review anchored
    /// to Mail's Undo Send (10–30 s).
    public static let assistiveActionWindow: Duration = .seconds(20)

    /// The stretched window for a transient surface that is text ONLY: nothing is lost by missing
    /// it, so it needs long enough to be found and read, not long enough to be acted on.
    public static let assistiveNoticeWindow: Duration = .seconds(12)

    /// Whether an assistive technology that navigates element-by-element is driving the phone.
    /// Injectable so a test can exercise the assistive branch; `nil` at init resolves to the live
    /// `UIAccessibility` read.
    private let isAssistiveNavigationRunning: @MainActor () -> Bool

    /// Creates a window resolver.
    ///
    /// - Parameter isAssistiveNavigationRunning: Test seam. `nil` (production) resolves in the
    ///   init body to `UIAccessibility.isVoiceOverRunning || .isSwitchControlRunning`. Full
    ///   Keyboard Access has no equivalent public flag, so it is not (and cannot be) consulted.
    public init(isAssistiveNavigationRunning: (@MainActor () -> Bool)? = nil) {
        self.isAssistiveNavigationRunning = isAssistiveNavigationRunning
            ?? { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning }
    }

    /// The dismissal window in force right now, for a surface that always dismisses eventually —
    /// just later when an assistive technology is running.
    ///
    /// Returns a plain `Duration`, never an optional, and that is the point: the caller has already
    /// assigned the state its timer is responsible for clearing, so there must be no branch on
    /// which no timer is created. An optional here invites a `guard … else { return }` that strands
    /// the toast on screen forever, which is a worse outcome than any window length.
    ///
    /// - Parameters:
    ///   - standard: The sighted-tap budget, used whenever no assistive technology is running. The
    ///     visible behaviour for everyone else is unchanged — that is deliberate.
    ///   - assistive: The stretched budget. ``assistiveActionWindow`` when the surface carries
    ///     something to act on, ``assistiveNoticeWindow`` when it is text only.
    public func window(standard: Duration, assistive: Duration) -> Duration {
        isAssistiveNavigationRunning() ? assistive : standard
    }

    /// The window for a surface whose dismissal REMOVES CONTROLS from the accessibility tree
    /// rather than retiring a notice — fading photo-viewer chrome, say. `nil` means *do not
    /// auto-dismiss at all* while an assistive technology is running.
    ///
    /// Separate from ``window(standard:assistive:)`` rather than an optional parameter on it,
    /// because the two policies want opposite handling of a missing answer: here `nil` is a real
    /// instruction the caller must honour by NOT scheduling anything, and a caller that returns
    /// early on it strands nothing (the controls simply stay). Use this ONLY when leaving the
    /// surface up indefinitely is genuinely harmless — not, for instance, when the surface holds a
    /// radio open.
    ///
    /// - Parameter standard: The sighted-tap budget, used when no assistive technology is running.
    public func windowUnlessAssistive(standard: Duration) -> Duration? {
        isAssistiveNavigationRunning() ? nil : standard
    }
}

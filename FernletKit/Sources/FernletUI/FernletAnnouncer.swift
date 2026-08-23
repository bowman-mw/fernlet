//
//  FernletAnnouncer.swift
//  FernletUI
//
//  The app's ONE seam for VoiceOver announcements (accessibility review 2026-08-22, T1-2 / §4.4).
//
//  An announcement is the only channel a blind user has for something that happens without a
//  focus change: a save that failed, an undo window that opened, a cover that dropped. Before
//  this type each surface posted `AccessibilityNotification.Announcement` inline, which meant
//  (a) nothing could assert what was and was not spoken — the accessibility system never reports
//  back — and (b) every site re-decided the localization question on its own. This extracts the
//  injectable seam ``CaptureProtectionState`` already carried and makes it the shared one.
//
//  TWO RULES, both load-bearing:
//
//  1. LOCALIZATION. `AccessibilityNotification.Announcement` takes a plain `String`, so a literal
//     written *here* would be spoken in English forever — this is an SPM module and its catalog
//     (which it does not even have; see the review's §4.0) is only ever consulted through
//     `bundle: .module`. So this file contains ZERO announcement copy, and never will: every
//     entry point takes text the CALLER resolved against the CALLER's own catalog, either as a
//     `LocalizedStringResource` carrying its own bundle or as an already-resolved `String`.
//
//  2. NEVER THE PAYLOAD. An announcement is spoken out loud, into whatever room the phone is in.
//     Sealed content — a journal note, a worry, a cycle narrative, an intimate-activity note —
//     must never be handed to it. Announce the EVENT ("Released.", "Couldn't save that."), never
//     the text the app went to the trouble of encrypting.
//

import SwiftUI
import UIKit

// MARK: - Vocabulary

/// The closed set of announcement kinds from the accessibility review's §4.4 vocabulary.
///
/// The kind is *semantic*, not a priority: it says why the app spoke, so a call site reads
/// honestly and a test can assert "exactly one error was announced and no success was". It is
/// deliberately NOT mapped onto `AttributeScopes.AccessibilityAttributes.AnnouncementPriority`
/// yet — several shipping sites pair an announcement with an `@AccessibilityFocusState` move and
/// were hand-tuned so the failure is spoken exactly once, and raising those to `.high` would
/// change that timing. Mapping it is a deliberate, separately verified change, not a side effect
/// of adopting this type.
///
/// **`.increase` is deliberately absent**, and the review's §4.4 vocabulary does name it (for
/// counter taps). It is left out because an announcement is the wrong mechanism for a counter: the
/// right one is an `.accessibilityValue` on the counter element, which VoiceOver re-reads by itself
/// whenever it changes under the cursor. Speaking as well would say the new count twice to the user
/// who is looking at it and interrupt the one who is not. The real prerequisite is that Fernlet's
/// counters do not carry an `.accessibilityValue` yet — that is the T2-4 / T2-8 work, not this
/// batch — so a `.increase` case today would have no correct call site and would only invite the
/// wrong one. Add it when the values land, if it is still wanted.
public enum FernletAnnouncementKind: String, Sendable, CaseIterable {
    /// Something changed that the user did not cause directly, or a neutral state message.
    case status
    /// A durable write landed — including one that landed with a caveat the user still has to
    /// hear. The distinction from ``status`` is "their data is safe now" versus "here is a fact".
    case success
    /// Something the user asked for did not happen.
    case error
}

/// One announcement exactly as it left a call site: the semantic ``FernletAnnouncementKind`` plus
/// the already-localized sentence that will be spoken.
///
/// Tests record these instead of the bare string so an assertion can be about *what kind of thing*
/// was announced, not only its words.
public struct FernletAnnouncement: Equatable, Sendable {
    /// Why the app spoke.
    public let kind: FernletAnnouncementKind
    /// The sentence VoiceOver will read, already resolved against the caller's catalog.
    public let message: String

    /// Creates an announcement record.
    public init(kind: FernletAnnouncementKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - Announcer

/// The shared VoiceOver announcer: one place that decides how an announcement is posted, and the
/// injection point that makes "was this spoken?" a question a unit test can answer.
///
/// Production callers use ``system``. A test constructs its own with a recording closure and
/// asserts the exact sequence — which is the entire reason the type exists, because the real
/// accessibility system never reports back what it said.
///
/// **Invariants**
///
/// - *No copy lives here.* Every entry point takes caller-resolved text (see the file header).
///   Adding a string literal to this file re-introduces the exact bug the type was extracted to
///   prevent, and nothing would fail to build.
/// - *Never sealed content.* Announce the event, never the encrypted payload — an announcement is
///   audible to everyone in the room, and the surfaces that call this are the ones behind the app
///   lock precisely because their text is private.
/// - *Empty is silent.* An empty sentence is dropped rather than posted: `localizedDescription`
///   can come back empty from a badly-behaved error, and posting "" hands VoiceOver an
///   announcement with nothing in it, which reads as a swallowed interruption.
///
/// **Concurrency:** main-actor, like every announcement API it wraps and like the views that call
/// it. `FernletUI` builds with `defaultIsolation(MainActor.self)`, so the annotation is implicit;
/// it is written out on the stored closure for the same reason ``CaptureProtectionState`` writes
/// out its own seams — the isolation is part of the contract, not an accident of the target.
public struct FernletAnnouncer {
    /// The production announcer: posts through `AccessibilityNotification.Announcement`.
    public static let system = FernletAnnouncer()

    /// Where an announcement actually goes. Injectable so a test can record what was (and was
    /// not) spoken; `nil` at init resolves to the real post.
    private let post: @MainActor (FernletAnnouncement) -> Void

    /// Creates an announcer.
    ///
    /// - Parameter post: Test seam. `nil` (production) resolves in the init body to posting
    ///   `AccessibilityNotification.Announcement` — deliberately not a default-argument value,
    ///   mirroring ``CaptureProtectionState``'s seams, since the real post is main-actor work.
    public init(post: (@MainActor (FernletAnnouncement) -> Void)? = nil) {
        self.post = post ?? { AccessibilityNotification.Announcement($0.message).post() }
    }

    /// Speaks a `LocalizedStringResource`. **App target and app extensions ONLY.**
    ///
    /// This is the preferred form for a call site whose bundle *is* `Bundle.main` — the app and the
    /// two extensions — because the literal is harvested into that target's own catalog and
    /// resolves there. It is the reason the unlabelled overload exists at all: it makes the correct
    /// thing the easy thing, so `announce(.status, "Saved")` localizes instead of freezing.
    ///
    /// **A package module must NOT use this overload.** A `LocalizedStringResource` created inside
    /// an SPM module defaults to `Bundle.main` — the APP's bundle — so it misses the module's own
    /// catalog and is spoken as its own raw key at runtime, with a clean build and no warning
    /// anywhere. Extracting the announcer moved the literal problem out of this file and into the
    /// call sites; it did not remove it. Package callers resolve with their module's copy vault
    /// (`FernletLockCopy`, ``CaptureNudgeCopy``) or `String(localized:bundle:.module)` and pass the
    /// result to ``announce(_:resolved:)``. `FernletAnnouncerTests.packageAnnounceCallsUseTheResolvedLabel`
    /// enforces that mechanically, because nothing else can.
    ///
    /// - Parameters:
    ///   - kind: Why the app is speaking. See ``FernletAnnouncementKind``.
    ///   - text: The sentence to speak. Never sealed content.
    public func announce(_ kind: FernletAnnouncementKind = .status, _ text: LocalizedStringResource) {
        announce(kind, resolved: String(localized: text))
    }

    /// Speaks a sentence the caller has ALREADY resolved.
    ///
    /// For the many sites whose words are not a literal at all — an error's
    /// `localizedDescription`, a status line already rendered on screen, a copy constant a package
    /// module resolved with `bundle: .module`. Passing a bare literal here is the one way to
    /// misuse this type, and it is why the parameter is labelled `resolved:`.
    ///
    /// **This is the only form a package module may use** — see ``announce(_:_:)`` for why.
    ///
    /// - Parameters:
    ///   - kind: Why the app is speaking. See ``FernletAnnouncementKind``.
    ///   - message: The already-localized sentence. Empty is dropped. Never sealed content.
    public func announce(_ kind: FernletAnnouncementKind = .status, resolved message: String) {
        guard !message.isEmpty else { return }
        post(FernletAnnouncement(kind: kind, message: message))
    }
}

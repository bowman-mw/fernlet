//
//  ImportReviewLanding.swift
//  Fernlet
//
//  How the three import review sheets answer their Save (sounds-and-haptics Tier B, 2026-10-20;
//  `Docs/Handoff/Sounds-Haptics-Investigation.md` B22 and §7 "Recipe sharing and the Messages
//  extension"): a recipe a friend handed over nearby, a recipe opened from Messages, and a workout
//  plan opened from Messages.
//
//  Before this file all three closed on success with nothing said — the nearby sheet wrote an
//  "imported" line and dismissed in the same breath, so nobody ever saw it — and the two Messages
//  sheets showed their errors in red without VoiceOver hearing them. This was a confirmation gap
//  before it was a haptic gap, so the confirmation comes first:
//
//  - **It landed** (``ImportReviewOutcome/added(_:)``): the sheet swaps its Save for the "added" line
//    (``ImportLandedLine``) and plays `done` at once; the line stays for ``ImportReviewLanding/beat``,
//    the same 1.2 s the recipe book's URL import holds its own "added" line; then the sheet closes and
//    VoiceOver hears the line once the close has settled (`TaskConfirmation.sheetSettle`), when a
//    sentence can no longer be cut off by the cursor moving.
//  - **It stopped with something to read** (``ImportReviewOutcome/caveat(_:)``): the calendar changed
//    under a workout plan, or the save landed but its review could not be cleared. `caveat`, the line
//    in the sheet, spoken now — the sheet stays up, so nothing is closing over the words.
//  - **It didn't happen** (``ImportReviewOutcome/failed(_:)``): `failed`, the error in the sheet,
//    spoken now.
//
//  A Cancel or a Decline answers nothing and plays nothing. No cue plays before the import itself has
//  returned: the sheets decide the outcome from what the import did, then hand it here.
//

import FernletUI
import SwiftUI

/// What one Save on an import review sheet came to. The associated text is display copy the sheet
/// already resolved; it is shown in the sheet and spoken, never logged.
enum ImportReviewOutcome: Equatable {
    /// The import landed; the line says so ("“Pasta” is in your recipe book.").
    case added(String)
    /// It landed or stopped with something the person needs to read; the sheet stays up.
    case caveat(String)
    /// It didn't happen; the sheet stays up with the error.
    case failed(String)

    /// The haptic this outcome plays: `done`, `caveat` or `failed`, each an outcome-scope event, so
    /// all three still play at the "Fewer" level.
    var event: FernletFeedbackEvent {
        switch self {
        case .added: .done
        case .caveat: .caveat
        case .failed: .failed
        }
    }

    /// The line the sheet shows and VoiceOver hears.
    var line: String {
        switch self {
        case .added(let line), .caveat(let line), .failed(let line): line
        }
    }
}

/// Plays, shows and speaks an ``ImportReviewOutcome``: the shared ending of the import review sheets.
///
/// A value with injected seams, like ``FernletFeedback`` and ``FernletAnnouncer`` themselves, so a
/// test can record the cue, the close and the sentence, in order, with no clock.
///
/// **Concurrency:** main-actor, like the sheets that call it from an unstructured `Task`. The task is
/// unstructured on purpose: the sheet that landed is the view being torn down, and a `.task` on it
/// would be cancelled before the line was spoken.
@MainActor
struct ImportReviewLanding {
    /// How long the "added" line stays before the sheet closes: the recipe book URL import's beat,
    /// long enough to read one short line. Not stretched under VoiceOver — VoiceOver hears the line
    /// after the close instead.
    static let beat: Duration = .seconds(1.2)

    private let feedback: FernletFeedback
    private let announcer: FernletAnnouncer
    private let pause: @MainActor (Duration) async throws -> Void

    /// Creates a landing.
    ///
    /// - Parameters:
    ///   - feedback: Test seam; `nil` (production) resolves in the body to ``FernletFeedback/system``.
    ///   - announcer: Test seam; `nil` resolves to ``FernletAnnouncer/system``.
    ///   - pause: Test seam for the beat and the settle; `nil` sleeps for real.
    init(
        feedback: FernletFeedback? = nil,
        announcer: FernletAnnouncer? = nil,
        pause: (@MainActor (Duration) async throws -> Void)? = nil
    ) {
        self.feedback = feedback ?? .system
        self.announcer = announcer ?? .system
        self.pause = pause ?? { try await Task.sleep(for: $0) }
    }

    /// Answers one Save. The cue plays at once, beside the words the sheet has just put up.
    ///
    /// - Parameters:
    ///   - outcome: What the import came to.
    ///   - close: Closes the sheet. Called only for ``ImportReviewOutcome/added(_:)``, after
    ///     ``beat``; a cancelled pause (the app going away) closes nothing and says nothing.
    func answer(_ outcome: ImportReviewOutcome, close: @MainActor () -> Void) async {
        feedback.play(outcome.event)
        switch outcome {
        case .caveat(let line):
            announcer.announce(.status, resolved: line)
        case .failed(let line):
            announcer.announce(.error, resolved: line)
        case .added(let line):
            do {
                try await pause(Self.beat)
            } catch {
                return
            }
            close()
            do {
                try await pause(TaskConfirmation.sheetSettle)
            } catch {
                return
            }
            announcer.announce(.success, resolved: line)
        }
    }
}

/// The "added" line an import review sheet shows in place of its Save while it holds for
/// ``ImportReviewLanding/beat`` — the `done` haptic's visual twin.
struct ImportLandedLine: View {
    /// The resolved line, already localized by the sheet.
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.moss)
                .accessibilityHidden(true)
            Text(text)
                .fernletWrappingText()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importReview.landed")
    }
}

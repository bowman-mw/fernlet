//
//  CoachPlanPasteSheet.swift
//  Fernlet
//
//  Where a coach plan comes back in: paste the reply, Fernlet reads it, and hands off to the review
//  gate. Nothing is written here — this sheet only decodes.
//

import SwiftUI
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

/// Collects the pasted plan text and decodes it, showing an honest error for anything that isn't a
/// readable plan.
///
/// Uses a plain `TextEditor` plus a system `PasteButton` rather than reading `UIPasteboard`
/// directly: a programmatic clipboard read shows the system's "Fernlet pasted from…" banner and
/// makes the app look like it is helping itself to the clipboard, which is precisely the impression
/// a privacy-first app should not give.
struct CoachPlanPasteSheet: View {
    /// Handed the successfully decoded plan; the presenter opens the review gate with it.
    var onDecoded: (CoachPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: PasteProblem?
    @FocusState private var editorFocused: Bool

    /// What to say about a paste that couldn't be read: a plain sentence with a next step, and the
    /// raw decoding path (if any) kept as a smaller secondary line rather than shown as the error.
    private struct PasteProblem {
        let message: String
        var detail: String?
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                        intro
                        editor
                        if let problem { errorCard(problem) }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)

                // Pinned outside the ScrollView: a long pasted reply used to push "Read plan" several
                // screens below the fold.
                readBar
            }
            .background(Color.parchment)
            .navigationTitle("Paste a plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste the reply")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Paste what your assistant replied with. Fernlet finds the plan inside it — you don't "
                 + "have to trim off the surrounding text. You'll see the whole plan before anything is added.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color.bark)
                .scrollContentBackground(.hidden)
                // Capped, so a multi-screen reply scrolls INSIDE the editor instead of growing the
                // page under it.
                .frame(minHeight: 220, maxHeight: 320)
                .padding(10)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd)
                    .stroke(Color.bark.opacity(0.08), lineWidth: 1))
                .focused($editorFocused)
                .accessibilityIdentifier("coachPaste.editor")
                .accessibilityLabel("Pasted plan")

            #if canImport(UIKit)
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                // PasteButton hands values off the main actor.
                Task { @MainActor in
                    // R3: bound the clipboard where it enters, not after the editor has already laid
                    // out the blob — the same 512 KB limit the decode applies, reported the same way.
                    let bytes = pasted.utf8.count
                    guard bytes <= CoachPlanLimits.maxPastedBytes else {
                        problem = Self.problem(for: .tooLarge(bytes: bytes), pastedText: pasted)
                        return
                    }
                    text = pasted
                    problem = nil
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(Color.moss)
            .accessibilityIdentifier("coachPaste.pasteButton")
            #endif
        }
    }

    private func errorCard(_ problem: PasteProblem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't read that")
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
            Text(problem.message)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = problem.detail {
                // The decoding path, kept as a secondary line: useful when reporting a problem,
                // never the sentence the user is asked to act on.
                Text(detail)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd)
            .stroke(Color.terracotta.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("coachPaste.error")
    }

    /// Turns a decode failure into something a person can act on.
    ///
    /// Two cases earn their own copy. Pasting Fernlet's OWN training summary back is an easy slip —
    /// it is exactly what was just copied — and it used to surface as a decoding path
    /// ("edits → Index 0 → targetID couldn't be read"), which names neither the mistake nor the fix.
    /// And a genuinely malformed plan gets a plain sentence, with that path demoted to a secondary
    /// line.
    private static func problem(for failure: CoachPlanImportFailure, pastedText: String) -> PasteProblem {
        if looksLikeFernletSummary(pastedText) {
            return PasteProblem(
                message: "That looks like your training summary, not a plan — paste the assistant's reply instead."
            )
        }
        switch failure {
        case .malformed(let detail):
            return PasteProblem(
                message: "The plan is missing something Fernlet needs. Ask the assistant to reply with "
                    + "the complete JSON block again.",
                detail: detail
            )
        default:
            return PasteProblem(message: failure.message)
        }
    }

    /// Whether the paste is Fernlet's own export rather than a plan. Keyed on two `About` fields that
    /// only the export bundle carries — a real plan has neither.
    static func looksLikeFernletSummary(_ text: String) -> Bool {
        text.contains("\"neverIncludes\"") || text.contains("\"preparedFor\"")
    }

    /// The pinned bottom bar carrying "Read plan", mirroring the entry sheets' save bar.
    private var readBar: some View {
        Button {
            editorFocused = false
            switch CoachPlanImporter.decode(pastedText: text) {
            case .success(let plan):
                problem = nil
                onDecoded(plan)
                dismiss()
            case .failure(let error):
                problem = Self.problem(for: error, pastedText: text)
            }
        } label: {
            Text("Read plan")
                .font(.fernlet(.label))
                .foregroundStyle(Color.parchment)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(text.isEmpty ? Color.slate.opacity(0.4) : Color.moss,
                            in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .accessibilityIdentifier("coachPaste.read")
        .padding(20)
        .background(Color.parchment)
    }
}

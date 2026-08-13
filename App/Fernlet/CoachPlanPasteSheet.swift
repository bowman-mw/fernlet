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
    @State private var failure: CoachPlanImportFailure?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                    intro
                    editor
                    if let failure { errorCard(failure) }
                    readButton
                }
                .padding(20)
            }
            .background(Color.parchment)
            .scrollDismissesKeyboard(.interactively)
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
                .frame(minHeight: 220)
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
                    text = pasted
                    failure = nil
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(Color.moss)
            .accessibilityIdentifier("coachPaste.pasteButton")
            #endif
        }
    }

    private func errorCard(_ failure: CoachPlanImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't read that")
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracotta)
            Text(failure.message)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd)
            .stroke(Color.terracotta.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("coachPaste.error")
    }

    private var readButton: some View {
        Button {
            editorFocused = false
            switch CoachPlanImporter.decode(pastedText: text) {
            case .success(let plan):
                failure = nil
                onDecoded(plan)
                dismiss()
            case .failure(let error):
                failure = error
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
    }
}

//
//  SafetyReportingView.swift
//  Fernlet
//
//  Always-available "how to report / block" surface (App Store UGC compliance, Guideline 1.2). The
//  actual report + block affordances live where the content is — on shared shop items and on people in
//  the friend list / in-session roster — this screen explains them and states the no-tolerance policy.
//

import SwiftUI

struct SafetyReportingView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(
                    "A kind, safe space",
                    "Fernlet's only shared content is the custom companion clothing friends make and "
                    + "trade in person. Objectionable content and abusive behavior aren't welcome here.")

                section(
                    "Report a shared item",
                    "In a friend's shop, tap the ••• on any item and choose “Report item.” The item is "
                    + "hidden from you right away and its sender is blocked on your device.")

                section(
                    "Report or block a person",
                    "In Friends & Blocks, swipe a person or open their card to Report or Block them. "
                    + "Blocking hides their content from you and yours from them.")

                section(
                    "What happens next",
                    "Reports are handled on your device — there is no server that sees your data. When "
                    + "the same item is reported enough, it can no longer be sold; a maker whose items are "
                    + "repeatedly reported loses their shop for a while.")

                section(
                    "Contact",
                    "For anything a report or block can't resolve, reach the developer, Michael Bowman "
                    + "Olay, through the app's App Store support page.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.parchment)
        .navigationTitle("Safety & reporting")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Text(body)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack { SafetyReportingView() }
}

//
//  SafetyReportingView.swift
//  Fernlet
//
//  Always-available "how to report / block" surface (App Store UGC compliance, Guideline 1.2). The
//  actual report + block affordances live where the content is — on shared shop items and on people in
//  the friend list / in-session roster — this screen explains them and states the no-tolerance policy.
//

import SwiftUI
import FernletUI

/// The static "Safety & reporting" explainer screen (App Store UGC compliance, Guideline 1.2).
///
/// Pure copy, no state: it tells the user where the real report/block affordances live (shop item
/// menus, Friends & Blocks, the in-session roster), states the no-tolerance policy, explains the
/// on-device consequences of a report, and gives a developer contact route. Reached from Settings
/// so the path is always available, even outside any session.
struct SafetyReportingView: View {
    /// The same address the in-app privacy policy publishes. A `mailto:` link, never a web
    /// destination — Fernlet's outbound-destination allowlist is deliberately tiny.
    private static let supportEmail = "fernletapp@gmail.com"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(
                    "A kind, safe space",
                    "Everything friends share with you happens in person: custom companion clothing, "
                    + "the photos you take together, messages during a session, recipes, and the "
                    + "activities you start. Objectionable content and abusive behavior aren't welcome "
                    + "here.")

                section(
                    "Report a shared item",
                    "In a friend's shop, tap the ••• on any item and choose “Report item.” The item is "
                    + "hidden from you right away and its sender is blocked on your device.")

                section(
                    "Report or block a person",
                    "In Friends & Blocks, swipe a person or open their card to Report or Block them. "
                    + "During a session, tap the ••• beside someone in the People list to block them "
                    + "there and then. Blocking hides their content from you and yours from them.")

                section(
                    "Photos, messages and activities",
                    "A photo a friend shared is deleted from your phone with the trash button in the "
                    + "photo viewer, and the whole batch can be discarded at the end of a session. "
                    + "Session messages are never stored — they disappear for everyone when the "
                    + "session ends. Recipes and activities you were sent are removed by deleting "
                    + "them where they appear. To stop someone sending you any of it, block or "
                    + "report them.")

                section(
                    "What happens next",
                    "Reports are handled on your device — there is no server that sees your data. When "
                    + "the same item is reported enough, it can no longer be sold; a maker whose items are "
                    + "repeatedly reported loses their shop for a while.")

                contactSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.parchment)
        .navigationTitle("Safety & reporting")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The developer contact route — a tappable mail link rather than a sentence describing one.
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contact")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Text("For anything a report or block can't resolve, reach the developer, Michael Bowman Olay.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            if let destination = URL(string: "mailto:\(Self.supportEmail)") {
                Link(destination: destination) {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope")
                            .font(.subheadline.weight(.semibold))
                        Text(Self.supportEmail)
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.moss)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("safety.contactEmail")
                .accessibilityLabel("Email the developer at \(Self.supportEmail)")
            }
        }
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

//
//  SafetyReportingView.swift
//  Fernlet
//
//  Always-available "how to report / block" surface (App Store UGC compliance, Guideline 1.2). The
//  actual report + block affordances live where the content is — on shared shop items, on people in
//  the friend list / in-session roster, and (2026-10-15) on each session message and photo, which run
//  the same people-report flow (`PeerReportFlow.swift`) — this screen explains them and states the
//  no-tolerance policy. It opens on the crisis-line card First Aid carries (`CrisisSupportCard`),
//  because Settings search sends "crisis", "help", "988", "suicide", "hotline" and "first aid" here.
//

import SwiftUI
import FernletUI

/// The static "Safety & reporting" explainer screen (App Store UGC compliance, Guideline 1.2).
///
/// Pure copy, no state: it tells the user where the real report/block affordances live (shop item
/// menus, Friends & Blocks, the in-session roster, Report… on a session message or photo), states
/// the no-tolerance policy and the chat's send filter, explains the on-device consequences of a
/// report, and gives a developer contact route (``contactURL``, which the report flow offers too).
/// Reached from Settings so the path is always available, even outside any session.
///
/// It opens on ``CrisisSupportCard`` — the same region-keyed crisis line First Aid shows — because
/// it is where Settings search sends a person who types "crisis", "help", "988", "suicide",
/// "hotline" or "first aid" (bug confirmation 2026-10-15, safety §2b): a search for help must not
/// land on a page whose only contact is a developer's email.
struct SafetyReportingView: View {
    /// The same address the in-app privacy policy publishes. A `mailto:` link, never a web
    /// destination — Fernlet's outbound-destination allowlist is deliberately tiny.
    private static let supportEmail = "fernletapp@gmail.com"

    /// The developer contact route as a `mailto:` URL — this screen's link, and the "Email the
    /// developer" button the report flow offers after a report (`PeerReportFlow.swift`), so the
    /// app names one contact address in one place.
    static var contactURL: URL? { URL(string: "mailto:\(supportEmail)") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CrisisSupportCard(identifierPrefix: "safety.support")

                section(
                    "A kind, safe space",
                    "Everything friends share with you happens in person: custom companion clothing, the photos you take together, messages during a session, recipes, and the activities you start. Objectionable content and abusive behavior aren't welcome here.")

                section(
                    "Report a shared item",
                    "In a friend's shop, tap the ••• on any item and choose “Report item.” The item is hidden from you right away and its sender is blocked on your device.")

                section(
                    "Report or block a person",
                    "In Friends & Blocks, swipe a person or open their card to Report or Block them. During a session, tap the ••• beside someone in the People list to block them there and then. Blocking hides their content from you and yours from them.")

                section(
                    "Report a message or a photo",
                    "During a session, touch and hold a message someone sent and choose “Report…”. Do the same on a photo someone shared when you choose which photos to keep, or tap the flag in the photo viewer. The person is reported and blocked on your phone, their messages are hidden, and a reported photo is deleted from your phone.")

                section(
                    "Photos, messages and activities",
                    "A photo a friend shared is deleted from your phone with the trash button in the photo viewer, and the whole batch can be discarded at the end of a session. Session messages are never stored — they disappear for everyone when the session ends — and Fernlet won't send a message containing words from its short list of slurs. Recipes and activities you were sent are removed by deleting them where they appear. To stop someone sending you any of it, block or report them.")

                section(
                    "What happens next",
                    "Reports are handled on your device — there is no server that sees your data. A report of a person, a message or a photo stays on your phone. Reports of shop items also travel to friends you meet in person, signed by your device, so several people reporting the same item can be counted together; the person you reported is one of the friends who may receive it. They are never uploaded anywhere. When the same item is reported enough, it can no longer be sold; a maker whose items are repeatedly reported loses their shop for a while.")

                contactSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fernletPageBackground()
        // A page in the Settings panel, like the rest of Settings (`b3-safety`).
        .fernletPushedPage("Safety & reporting")
    }

    /// The developer contact route — a tappable mail link rather than a sentence describing one.
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contact")
                .font(FernletFramedFont.rowTitle.weight(.bold))
                .foregroundStyle(Color.bark)
                // This page is where help lives; its section titles are how the Headings rotor
                // finds the developer's address without reading every paragraph above it.
                .accessibilityAddTraits(.isHeader)
            Text("For anything a report or block can't resolve, reach the developer, Michael Bowman Olay.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
            if let destination = Self.contactURL {
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
                // Voice Control: the drawn text is an address nobody should have to dictate.
                .accessibilityInputLabels([Text("Email"), Text("Email the developer"), Text("Contact")])
            }
        }
        .settingsCard()
    }

    /// One titled paragraph. `LocalizedStringKey`, not `String`: a `String` parameter would hand
    /// `Text` the verbatim overload and opt every paragraph out of the catalog.
    private func section(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        // One framed card per titled paragraph (`b3-safety`).
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(FernletFramedFont.rowTitle.weight(.bold))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(FernletFramedFont.body)
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
    }
}

#Preview {
    NavigationStack { SafetyReportingView() }
}

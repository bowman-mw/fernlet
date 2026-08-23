import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI
import ProximityKit

/// The Nearby friends settings page (2026-08-21 redesign, artboard 5b — SETT-29, XCUT-11).
///
/// The six in-person sharing consents used to sit as bare toggles inside the Settings hub's
/// Privacy section; nobody looks under Privacy to change a friends setting. This pushed page
/// (36pt ``ScreenHeader`` idiom — never sheet chrome) orders them by **dependency**: Presence
/// first, because hearts and vibe need it, then vibe, hearts, away delivery, recipe shares,
/// clothing shops. Each row carries its own one-line footnote instead of a shared paragraph.
///
/// Preserved behaviors from the hub (the toggles' semantics are unchanged — every write still
/// routes through the `FernletStore` setters):
/// - Turning hearts ON while presence is off raises the offer-presence alert, since hearts are
///   dead without it.
/// - The away-delivery row keeps its full consent disclosure while ON (the copy lives in
///   ``AwayDeliveryConsentCopy`` — source-pinned by `HeartDropAppWiringTests`), plus the
///   nothing-silent delivery-problem and purge-pending lines with their stable identifiers.
/// - The under-13 chat age gate notice stays beside the sharing consents it explains.
///
/// Dynamic Type (5b·AX3): only Presence keeps its footnote — it is the one with a dependency —
/// and the other five explanations drop; toggles stay on the label's line.
struct NearbyFriendsSettingsView: View {
    @Bindable var store: FernletStore
    /// Hearts require presence: when the user turns hearts ON while presence is off, offer to
    /// enable presence too.
    @State private var offerPresenceForHearts = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Nearby friends",
                    subtitle: "Everything here needs both of you nearby.",
                    identifier: "screen.settings.nearbyFriends"
                )
                consentCard
                if !store.ageAssurance.allows(.chat) {
                    // In-session messaging has no toggle — session membership is its consent gate —
                    // so its 13+ age floor is surfaced here, beside the sharing consents.
                    AgeGateNotice(
                        gate: .chat,
                        featureName: "Messaging friends nearby",
                        ageAssurance: store.ageAssurance
                    )
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Nearby friends")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Turn on Nearby Friends?", isPresented: $offerPresenceForHearts) {
            Button("Turn on") { store.setAllowNearbyPresence(true) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Hearts are sent in person over Nearby Friends. Turn it on so you can see when friends are close by and send them a heart. Fernlet broadcasts only rotating tags your friends can recognize — never your name.")
        }
    }

    /// All six consents in dependency order, one card.
    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            consentRow(
                "Presence",
                footnote: "Lets friends see you're around. Hearts and vibe need this on.",
                keepFootnoteAtAccessibilitySizes: true,
                isOn: Binding(
                    get: { store.settings.allowNearbyPresence },
                    set: { store.setAllowNearbyPresence($0) }
                )
            )
            FernletRowDivider()
            consentRow(
                "Share your vibe",
                footnote: "A mood, never a number.",
                isOn: Binding(
                    get: { store.settings.allowNearbyFriendState },
                    set: { store.setAllowNearbyFriendState($0) }
                )
            )
            FernletRowDivider()
            heartRows
            FernletRowDivider()
            consentRow(
                "Recipe shares",
                footnote: "Hand a recipe over in person.",
                isOn: Binding(
                    get: { store.settings.allowNearbyRecipeShares },
                    set: { store.setAllowNearbyRecipeShares($0) }
                )
            )
            FernletRowDivider()
            consentRow(
                "Clothing shops",
                footnote: "Friends can browse what you've designed.",
                isOn: Binding(
                    get: { store.settings.allowNearbyClothingShares },
                    set: { store.setAllowNearbyClothingShares($0) }
                )
            )
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Hearts and away delivery, with the honesty disclosures the hub carried: the presence hint,
    /// the full away-delivery consent paragraph while ON, and every state where the "on" promise
    /// isn't being kept.
    @ViewBuilder
    private var heartRows: some View {
        consentRow(
            "Hearts",
            footnote: "Small hellos from friends in the room.",
            isOn: heartsBinding
        )
        if store.settings.allowNearbyHearts && !store.settings.allowNearbyPresence {
            Text("Hearts need Presence turned on to work — turn it on above.")
                .font(.fernlet(.bodySmall))
                // Text ink, not the `goldenrod` accent (2.22:1, fails even the 3:1 non-text floor) —
                // this string's whole job is telling the user a privacy feature is silently not
                // working (T1-3).
                .foregroundStyle(Color.goldenrodInk)
                .fernletWrappingText()
        }
        FernletRowDivider()
        consentRow(
            "Deliver hearts later",
            footnote: "Holds a heart until you're next nearby.",
            isOn: Binding(
                get: { store.settings.heartsAwayDelivery },
                set: { store.setHeartsAwayDelivery($0) }
            )
        )
        awayDeliveryDisclosures
    }

    /// The away-delivery consent paragraph (while ON) and the two nothing-silent states: a
    /// delivery problem with its Dismiss, and the purge-pending line after a failed turn-off.
    @ViewBuilder
    private var awayDeliveryDisclosures: some View {
        if store.settings.heartsAwayDelivery {
            Text(AwayDeliveryConsentCopy.disclosure)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if let problem = awayDeliveryProblemText {
                HStack(alignment: .top, spacing: 10) {
                    Text(problem)
                        .font(.fernlet(.bodySmall))
                        // T1-3: text ink, not the `goldenrod` accent (2.22:1).
                        .foregroundStyle(Color.goldenrodInk)
                        // Identifiers sit on the leaves, not the HStack: an identifier on the
                        // container shadows its children for UI tests.
                        .accessibilityIdentifier("settings.heartsAway.problem")
                    Spacer(minLength: 0)
                    Button("Dismiss") {
                        store.heartDropService.acknowledgeDeliveryProblem()
                    }
                    .font(.fernlet(.labelSmall))
                    // T1-3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                    .foregroundStyle(Color.mossInk)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.heartsAway.dismissProblem")
                }
            }
        } else if store.heartsAwayPurgePending {
            // Consent is off but sealed records are still on the public database because the
            // delete didn't go through. Say so rather than let "off" imply they were removed.
            Text("Some hearts Fernlet left in the iCloud drop-off couldn't be removed yet — it'll keep trying while you're online.")
                .font(.fernlet(.bodySmall))
                // T1-3: text ink, not the `goldenrod` accent (2.22:1).
                .foregroundStyle(Color.goldenrodInk)
                .accessibilityIdentifier("settings.heartsAway.purgePending")
        }
    }

    /// Why away hearts aren't being delivered right now, or nil when the drop-off is healthy.
    private var awayDeliveryProblemText: String? {
        AwayHeartsCopy.settingsLine(for: store.heartDropService.deliveryProblem)
    }

    /// Hearts ride the presence radio; enabling them while presence is off offers presence too.
    private var heartsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.allowNearbyHearts },
            set: { newValue in
                store.setAllowNearbyHearts(newValue)
                if newValue && !store.settings.allowNearbyPresence {
                    offerPresenceForHearts = true
                }
            }
        )
    }

    /// One consent toggle with its one-line footnote. At accessibility sizes the footnote drops
    /// unless it carries a dependency the user must know about (5b·AX3: only Presence keeps its
    /// footnote).
    ///
    /// **T2-2.** `keepFootnoteAtAccessibilitySizes` is a *layout* escape hatch, so it does not
    /// cover the accessibility tree: for the five rows that do not set it, the footnote is not
    /// drawn at accessibility sizes and therefore is not spoken either — exactly the Larger Text
    /// × VoiceOver hole. The footnote is re-attached to the toggle as custom content at every
    /// size (harmless when it is also drawn: default-importance custom content is never part of
    /// the spoken utterance, only of the More Content rotor). The toggle's own on/off value is
    /// left alone.
    private func consentRow(
        _ title: LocalizedStringKey,
        footnote: LocalizedStringKey,
        keepFootnoteAtAccessibilitySizes: Bool = false,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            .accessibilityCustomContent("Details", footnote)
            if keepFootnoteAtAccessibilitySizes || !dynamicTypeSize.isAccessibilitySize {
                Text(footnote)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }
}

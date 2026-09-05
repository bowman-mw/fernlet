// RoutedDeliveryHoldBanner.swift
// Fernlet
//
// Network migration P5 item 9 (plan §11): the one user-visible consequence of a routed backpressure
// refusal — "a queue that grows past its cap without telling anyone is the violation, not just the
// growth itself".
//
// It lives in the **app** target on purpose. The app bundle *is* `Bundle.main`, so a bare literal is
// the correct form here and the catalog sync harvests it; a `String` composed inside ProximityKit
// would render verbatim in every language, which is the live defect in all three existing mesh
// failure surfaces. Nothing crosses the module boundary but a frozen cause and a count.
//
// The register is `ConnectView.cacheWarningBanner`'s, deliberately: that is the closest thing the
// product already says to "storage is nearly full", and it is a reviewed, dismissible, accessible
// shape. Nothing here names a peer, reachability or a reunion — that copy is §18.2's and stays the
// owner's.

import SwiftUI
import FernletUI
import ProximityKit

// MARK: - RoutedDeliveryHoldCopy

/// The banner's copy, in ONE place so it can be tested — a view's private computed property cannot
/// be.
///
/// **One sentence pair per cause.** The two causes are different facts and a shared sentence states a
/// falsehood for one of them: `.notPlaced` is content this device is still *keeping* because no
/// stored receipt could place it with a custodian, so a storage sentence ("couldn't be kept") says
/// the opposite of what happened, and "they'll come through another time" is a delivery promise on a
/// device that is leaving.
///
/// **No count is interpolated into any key**, so every literal here is a plain sentence and no plural
/// variation is owed at all. The singular/plural fork is kept because English reads badly without it,
/// not because a wall demands it; the number itself reaches the reader through
/// ``MeshRoutedDeliveryHold/itemCount`` and the audit lines. If the copy should ever carry the count,
/// that key needs a `variations.plural` block **and** an entry in `LocalizationBoundaryTests`'
/// `pluralRuledKeys` at catalog-sync time.
enum RoutedDeliveryHoldCopy {

    /// The banner's accessibility identifier — a **frozen token**, never localized, in the
    /// `friends.*` screen prefix already in use on this surface.
    static let accessibilityIdentifier = "friends.deliveryHold"

    /// The headline for one cause.
    ///
    /// - Parameter cause: The frozen cause the manager published.
    /// - Returns: a `LocalizedStringKey`, never a `String` — `Text(String)` selects the
    ///   `StringProtocol` overload and renders verbatim.
    static func headline(_ cause: MeshRoutedDeliveryHoldCause) -> LocalizedStringKey {
        switch cause {
        case .storeFull: return "Fernlet is holding all it can"
        case .notPlaced: return "Some shared items stayed on this device"
        }
    }

    /// The explainer for one cause, or nil when there is nothing to explain.
    ///
    /// - Parameters:
    ///   - cause: The frozen cause.
    ///   - count: How many items are behind it. Never interpolated into the sentence; it only picks
    ///     the singular or plural form.
    /// - Returns: a `LocalizedStringKey`, or nil for a count of zero.
    static func detail(_ cause: MeshRoutedDeliveryHoldCause, count: Int) -> LocalizedStringKey? {
        guard count > 0 else { return nil }
        switch cause {
        case .storeFull:
            return count == 1
                ? "One shared item couldn't be kept just now. Fernlet makes room as items finish or expire."
                : "Some shared items couldn't be kept just now. Fernlet makes room as items finish or expire."
        case .notPlaced:
            return count == 1
                ? "Fernlet couldn't pass one shared item on before you left. It stays on this device until it expires."
                : "Fernlet couldn't pass some shared items on before you left. They stay on this device until they expire."
        }
    }
}

// MARK: - RoutedDeliveryHoldDismissal

/// Whether a dismissal the reader made earlier still hides the hold in front of them.
///
/// A plain `Bool` would not: the banner sits at a fixed position in `ConnectView`'s stack, so its
/// `@State` survives every change of the hold, and one tap would silence **every** later routed hold
/// for the life of the process — a different cause with different copy included. That is the wall's
/// own failure mode ("a queue that grows past its cap without telling anyone") re-introduced one
/// layer above the manager, and it is the exact mirror of the release rule the manager goes out of
/// its way to build.
///
/// `cacheWarningBanner`'s bare flag is fine for what it guards — one monotone photo count against one
/// cap. A routed hold is transient, recurring and two-valued, so the dismissal is keyed to the FACT:
/// the same cause at the same or a smaller count stays hidden, and a new cause or a grown count is a
/// new thing to say.
///
/// `at` is deliberately not part of the comparison — the manager re-derives the hold (and a fresh
/// instant) on every event, so an instant-sensitive rule would un-dismiss the banner immediately.
enum RoutedDeliveryHoldDismissal {

    /// Whether `hold` is still covered by a previous dismissal.
    ///
    /// - Parameters:
    ///   - hold: The hold the manager is publishing now.
    ///   - dismissed: The hold the reader dismissed, or nil if they have dismissed nothing.
    /// - Returns: `true` only for the same cause at a count that has not grown.
    static func hides(_ hold: MeshRoutedDeliveryHold, dismissed: MeshRoutedDeliveryHold?) -> Bool {
        guard let dismissed else { return false }
        return dismissed.cause == hold.cause && dismissed.itemCount >= hold.itemCount
    }
}

// MARK: - RoutedDeliveryHoldBanner

/// The Friends-tab banner for a routed delivery hold.
///
/// Its own `View` struct rather than a fourth computed property on `ConnectView`, so that body stays
/// inside the 60-line rule and the copy above stays testable. Dismissal is `@State` — **no
/// persistence**, so no `UserDefaults` key and no wipe row, in the `cacheWarningDismissed` idiom —
/// but it stores the dismissed **hold** rather than a bare flag, so a later and genuinely different
/// refusal is not silenced by an earlier tap (``RoutedDeliveryHoldDismissal``).
///
/// Shown out of session on purpose: held custody outlives the session that produced the refusal, and
/// the Friends tab is where a tester goes next.
struct RoutedDeliveryHoldBanner: View {

    /// The manager's published hold, or nil when there is nothing to say.
    let hold: MeshRoutedDeliveryHold?

    /// The hold the reader dismissed, if any. In-memory only, by design.
    @State private var dismissedHold: MeshRoutedDeliveryHold?

    var body: some View {
        if let hold, !RoutedDeliveryHoldDismissal.hides(hold, dismissed: dismissedHold) {
            card(hold)
        }
    }

    /// The banner itself — `ConnectView.cacheWarningBanner`'s structure and palette.
    private func card(_ hold: MeshRoutedDeliveryHold) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(Color.goldenrod)
            VStack(alignment: .leading, spacing: 3) {
                Text(RoutedDeliveryHoldCopy.headline(hold.cause))
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                if let detail = RoutedDeliveryHoldCopy.detail(hold.cause, count: hold.itemCount) {
                    Text(detail)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                dismissedHold = hold
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
            .fernletIconButton("Dismiss storage notice")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.goldenrod.opacity(0.35), lineWidth: 1))
        // NO `.accessibilityElement(children: .combine)`: this card contains the dismiss `Button`,
        // and combining would strip its `.isButton` trait, its direct VoiceOver focus and the label
        // `fernletIconButton` supplies. `cacheWarningBanner` — the banner this one is modelled on,
        // and the only sibling with an interactive child — carries none either; the one that does
        // (`discoveryFailureBanner`) is pure text.
        .accessibilityIdentifier(RoutedDeliveryHoldCopy.accessibilityIdentifier)
    }
}

//
//  FernletPrimitives.swift
//  FernletUI
//
//  The three cross-screen layout primitives that previously lived in the app's
//  HomeView.swift, extracted so package-resident views (lock UI, proximity
//  sheets) can use them. Visuals unchanged.
//

import SwiftUI

/// The standard cream content card: 16pt padding, 18pt continuous corners, and a soft bark-tinted
/// shadow.
///
/// The workhorse container of the redesigned screens — used across more than a dozen files in the
/// app plus the package-resident lock and proximity views, which is why its single-layer shadow is
/// deliberately kept (see the inline note) rather than swapped for `fernletCardShadow()`.
public struct FernletCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(FernletMetrics.spaceMd)   // 16
            .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd, style: .continuous))   // 18
            // Kept as the current single-layer `bark`-tinted shadow (not `fernletCardShadow()`): the
            // two-layer barkShadow token renders differently, and this card primitive is used across 13
            // files — swapping its shadow is a deliberate visual change, not a cleanup.
            .shadow(color: .bark.opacity(0.08), radius: 12, x: 0, y: 5)
    }
}

/// An uppercase, letter-spaced slate caption that titles a section of content.
///
/// Pairs with ``FernletCard`` groups on the Home and hub screens so section headings share one
/// small-label treatment; it is the screen-level sibling of ``SheetField``'s in-sheet caption.
public struct SectionLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.fernlet(.labelSmall))
            .tracking(0.8)
            .foregroundStyle(Color.slate)
    }
}

/// A centered italic placeholder line shown when a list or section has no content yet.
///
/// Used wherever a card would otherwise render empty (no meals logged, no friends nearby, …) so
/// empty sections still read as intentional rather than broken.
public struct EmptyState: View {
    var text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }
}

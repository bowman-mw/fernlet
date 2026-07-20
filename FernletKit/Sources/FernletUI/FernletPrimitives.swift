//
//  FernletPrimitives.swift
//  FernletUI
//
//  The three cross-screen layout primitives that previously lived in the app's
//  HomeView.swift, extracted so package-resident views (lock UI, proximity
//  sheets) can use them. Visuals unchanged.
//

import SwiftUI

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

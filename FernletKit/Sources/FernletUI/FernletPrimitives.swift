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

    /// §4.2 / T2-6. A `FernletCard`'s only boundary at default settings is its shadow — cream on
    /// parchment measures **1.08:1**, so the card edge is, for a low-vision user, not there. A
    /// shadow is also the first thing an OS-level contrast accommodation cannot strengthen. Under
    /// Increase Contrast the card therefore grows a real hairline; at default settings it draws
    /// exactly as it did, which is why the branch is an `if` rather than a variable alpha.
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: FernletMetrics.radiusMd, style: .continuous)   // 18
        return content
            .padding(FernletMetrics.spaceMd)   // 16
            .background(Color.cream, in: shape)
            .overlay {
                if contrast == .increased {
                    // `strokeBorder`, not `stroke`: an inset border keeps the drawn size identical
                    // to the default-contrast card, so turning the accommodation on does not
                    // reflow a single screen.
                    shape.strokeBorder(Color.barkEdge(contrast, normal: 0), lineWidth: 1)
                }
            }
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
    /// Resolved at init so the two initializers can settle the localize-or-not question once,
    /// rather than the body having to branch on which kind of string it was handed.
    private let text: Text

    /// The localizing initializer: a literal written here is extracted into the **calling target's**
    /// string catalog and looked up in `Bundle.main` when the label renders.
    ///
    /// That bundle pairing is only correct for callers inside the app target, which is where all
    /// ~83 of today's call sites live — `Bundle.main` *is* the app bundle, so the key the compiler
    /// harvested and the key SwiftUI looks up are the same key. A caller inside another **package**
    /// module has its literals harvested into that package's own bundle, which `Bundle.main` never
    /// consults; such a caller must resolve the string itself with
    /// `String(localized:bundle:.module)` and hand the result to ``init(verbatim:)``.
    public init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    /// The non-localizing initializer, for text that is *already* final: user data, a formatted
    /// date, a persisted token used as a grouping heading, or a package caller's own
    /// `String(localized:bundle:.module)` result.
    ///
    /// It is deliberately given the `verbatim:` label instead of overloading the unlabeled `_:`
    /// with a `String`. Two same-label overloads would let Swift pick the concrete `String` one for
    /// a plain string literal — `String` is the default type of a literal — and every call site in
    /// the app would go on compiling while quietly no longer localizing, which is exactly the
    /// failure this change exists to remove. A distinct label makes verbatim a decision someone
    /// had to type.
    public init(verbatim text: String) {
        self.text = Text(verbatim: text)
    }

    public var body: some View {
        text
            .font(.fernlet(.labelSmall))
            .tracking(0.8)
            .foregroundStyle(Color.slate)
            // `.textCase` rather than `String.uppercased()`: the transform now runs *after* the
            // lookup, on the translated string, which is the only locale-correct order. German ß
            // has to become SS, French capitals keep their accents, and Turkish i must not become
            // I — none of which a caller-side `.uppercased()` on an English key could ever get
            // right. It is also the only option left: `LocalizedStringKey` has no `.uppercased()`.
            .textCase(.uppercase)
            // A `SectionLabel` marks the start of a group of content within a screen (a card, a
            // list section) rather than the screen itself, so it sits one level under
            // ``ScreenHeader``/``SheetHeader`` on the Headings rotor. 91 call sites light up from
            // this one addition; see `Docs/Accessibility-Review-2026-08-22.md` T1-1.
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
    }
}

/// A centered italic placeholder line shown when a list or section has no content yet, optionally
/// over a soft glyph.
///
/// Used wherever a card would otherwise render empty (no meals logged, no friends nearby, …) so
/// empty sections still read as intentional rather than broken. **Every** empty section should route
/// through this rather than hand-rolling its own line — the friends album, activities list, friend
/// shop and milestones each drew their own with different fonts and spacing, which is what
/// `systemImage:` is here for: an illustrated empty state in the same voice as the plain ones.
public struct EmptyState: View {
    /// Resolved at init, for the same reason as ``SectionLabel``'s: the body should not have to
    /// know whether the line arrived as a catalog key or as finished text.
    private let text: Text
    private let systemImage: String?

    /// The localizing initializer. The literal is harvested into the calling target's string
    /// catalog and looked up in `Bundle.main`, which is correct for the app-target callers that own
    /// every one of today's ~35 call sites. A caller in another package module must resolve its own
    /// string with `String(localized:bundle:.module)` and use ``init(verbatim:systemImage:)`` — a
    /// key harvested into a package bundle is invisible to `Bundle.main` and would silently render
    /// as untranslated English.
    ///
    /// - Parameter systemImage: Optional SF Symbol drawn above the line. An SF Symbol name is a
    ///   token, never display text, so it stays a plain `String` — and it is decorative here
    ///   anyway, hidden from VoiceOver, which reads only `text`.
    public init(text: LocalizedStringKey, systemImage: String? = nil) {
        self.text = Text(text)
        self.systemImage = systemImage
    }

    /// The non-localizing initializer, for a line that is already final — most often one built from
    /// user input ("No one matches \"beans\".") or handed over pre-resolved by a package caller.
    ///
    /// The `verbatim:` label is load-bearing: a same-label `String` overload would win overload
    /// resolution for every plain literal and silently un-localize the whole component. See
    /// ``SectionLabel/init(verbatim:)`` for the full reasoning.
    public init(verbatim text: String, systemImage: String? = nil) {
        self.text = Text(verbatim: text)
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.slate.opacity(0.6))
                    .accessibilityHidden(true)
            }
            text
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 18)
    }
}

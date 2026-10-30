import FernletUI
import SwiftUI

/// What page 1 is handed (World-Passport-Spec §4): the store (Sprout, the wardrobe, the shop, the home), whether this
/// is a decoy session (a fresh Sprout, nothing real), the counts for the machine-readable lines, and how many pages
/// the book has. Page 1 pushes its slot pages onto the book's NavigationStack; their Back reads "Passport".
struct PassportSproutPageContext {
    let store: FernletStore
    let isDecoy: Bool
    let progress: PassportProgress
    let pageCount: Int
}

/// Page 1's slot: a quiet placeholder until `PassportSproutPage` (built by another piece of the lane) takes its
/// place. The book asks for page 1 through ``WorldPassportPresenter/sproutPage(_:)``, so the swap is that one line.
struct PassportSproutPageSlot: View {
    let context: PassportSproutPageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PassportPageHeader(title: Text(PassportBookCopy.coverWord), detail: Text(verbatim: "Fernlet"))
            RoundedRectangle(cornerRadius: 4)
                .fill(WorldPalette.adaptive(light: 0xE2EDD9, dark: 0x2F3B30))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 2))
                .frame(width: 100, height: 122)
                .accessibilityHidden(true)
            Text(verbatim: "Sprout")
                .font(Font.custom(FernletFontName.frauncesSemiBold, size: 23, relativeTo: .title2))
                .foregroundStyle(PassportBookPalette.text)
        }
    }
}

extension WorldPassportPresenter {
    /// Page 1 of the book. The one line the lane swaps when `PassportSproutPage` lands:
    /// `PassportSproutPage(context: context)`.
    @ViewBuilder
    static func sproutPage(_ context: PassportSproutPageContext) -> some View {
        PassportSproutPageSlot(context: context)
    }
}

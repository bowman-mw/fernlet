#if DEBUG
import FernletUI
import SwiftUI

/// DEBUG-only: page 1 of Sprout's passport in a plain book-sized frame, for the round's screenshots (`ps-sprout`,
/// `ps-sprout-home`) while the book is built elsewhere. Opened by `FERNLET_UI_TEST_PASSPORT_SPROUT` through
/// ``PassportSproutHarnessHost``. The frame follows §2's geometry (30 pt from the sides, 108 pt from the top,
/// 644 pt tall; the page 13 / 7 / 14 / 14 pt inside the cover) in plain colours: no stitching, security print,
/// stepped edges or ribbon, which are the book's.
struct PassportSproutHarness: View {
    var store: FernletStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            WorldPalette.page.ignoresSafeArea()
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? WorldPalette.rgb(0x1D3A25) : WorldPalette.rgb(0x26492F))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 3))
                .overlay {
                    NavigationStack {
                        PassportSproutPage(store: store)
                            .toolbar(.hidden, for: .navigationBar)
                            .containerBackground(PassportSproutInk.paper, for: .navigation)
                    }
                    .background(PassportSproutInk.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPalette.ink, lineWidth: 2))
                    .padding(EdgeInsets(top: 7, leading: 13, bottom: 14, trailing: 14))
                }
                .frame(height: 644)
                .padding(.horizontal, 30)
                .padding(.top, 108)
                .ignoresSafeArea()
        }
        .worldDesignLanguage()
    }
}
#endif

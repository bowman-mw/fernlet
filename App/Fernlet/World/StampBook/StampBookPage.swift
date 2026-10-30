import SwiftUI
import FernletDomainModel
import StoreCore
import FernletUI

/// The Stamp book (designs `b2-milestones` and `b2-keepsakes`, draft 2, approved 2026-10-24): Milestones,
/// the keepsake shelf and the silly stats in one page, from the owner's note “Merge this into the stamps
/// view”. Care keepsakes on wooden shelves come first, then the nineteen silly stamps (`b2-stamp-art`),
/// then the silly stats themselves.
///
/// Pushed inside the Today panel from its Milestones and Silly stats cards, and from the stamp banner and
/// the stamp widget (the plate shows ‹ Today and the title; ``StampBookPushHost``), and hosted in a sheet
/// by ``MilestonesView`` for the routed sheets.
///
/// Every figure derives from ONE read of each ledger per render (HOME-20's one-source rule): the medal
/// counts, each medal's gift tag, the header's gift total and the coins line, so no two can disagree.
/// Everything here only adds up: no rates, no streaks, no percentages, and the next keepsake is a quiet
/// dashed slot, never a to-do.
struct StampBookPage: View {
    var store: FernletStore
    /// Scrolls to the silly stamps on appear (the stamp banner's way in).
    var startsAtStamps = false

    /// The stamps card's scroll anchor.
    private static let stampsAnchor = "stampBook.stamps"

    var body: some View {
        let coinEntries = store.coinLedgerService.entries
        let gifts = MilestoneRowModel.giftCounts(in: coinEntries)
        let rows = MilestoneRowModel.rows(counts: store.milestoneCounts, worriesLetGo: store.lifetimeWorriesLetGo,
                                          giftCounts: gifts)
        let coins = CoinEconomy.milestoneAwardCoins(in: coinEntries)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Everything here only adds up. Nothing resets or expires.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                        .padding(.horizontal, 2)
                        // The screen anchor the UI tests wait on, where the Milestones intro lived.
                        .uxScreenAnchor("screen.milestones")
                    StampBookKeepsakesCard(rows: rows, totalGifts: gifts.values.reduce(0, +), totalCoins: coins)
                    SillyStampBookCard(stamps: store.sillyStats.stamps)
                        .id(Self.stampsAnchor)
                    // Sprout's passport (World-Passport-Spec §9): opens on page 2.
                    StampBookPassportRow(store: store)
                    SillyStatsList(stats: store.sillyStats)
                }
                .padding(20)
            }
            .onAppear {
                guard startsAtStamps else { return }
                reader.scrollTo(Self.stampsAnchor, anchor: .top)
            }
        }
        .fernletPageBackground()
        .task { await store.sillyStats.refresh(store: store) }
    }
}

/// The page's title, for the plate of a push and for the sheet's header.
enum StampBookTitle {
    /// "Stamp book".
    static let resource = LocalizedStringResource("stampBook.title", defaultValue: "Stamp book",
                                                  comment: "The Stamp book page's title: milestones, keepsakes, silly stamps and silly stats in one page")
}

/// The Stamp book pushed under the Today panel's plate (‹ Today and the title): from its Milestones
/// and Silly stats cards (at the top), and on a request — the stamp banner's tap or the stamp widget's
/// (owner, 2026-10-24: open Today and push the book, no sheet) — scrolled to the silly stamps.
struct StampBookPushHost: ViewModifier {
    /// Whether the Stamp book is pushed.
    @Binding var isOpen: Bool
    /// Set by ContentView when the banner or the widget asks for the book; taken (cleared) here.
    @Binding var request: Bool
    var store: FernletStore
    /// Whether this push scrolls to the stamps (a request's push); a card's push starts at the top.
    @State private var startsAtStamps = false

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isOpen) {
                StampBookPage(store: store, startsAtStamps: startsAtStamps)
                    .fernletPushedPage(StampBookTitle.resource)
            }
            .onChange(of: request, initial: true) { _, _ in takeRequest() }
            .onChange(of: isOpen) { _, open in
                if !open { startsAtStamps = false }
            }
    }

    /// Pushes the book at its stamps when asked, once.
    private func takeRequest() {
        guard request else { return }
        request = false
        startsAtStamps = true
        isOpen = true
    }
}

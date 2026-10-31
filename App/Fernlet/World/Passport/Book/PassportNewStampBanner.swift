import FernletUI
import SwiftUI
import WorldMapStore

/// The banner for a passport stamp earned just now (World-Passport-Spec §6, `ps-new`), drawn like the approved
/// silly-stamp banner (`b1-stamp-banner`, ``SillyStampBanner``): a paper plate in a 3-pt ink frame with a solid
/// drop shadow, the stamp's own art, "New stamp: Sea of Japan" and "It's in Sprout's passport." Tapping it opens
/// the passport on that stamp's page, where the stamp lands.
///
/// The root shows it in the silly-stamp banner's slot and by its rules (``ContentView``): one banner at a time,
/// never over a root sheet, the disposable camera or while riding along, never while the passport is open, never
/// in a decoy. VoiceOver hears "New stamp, Sea of Japan, 24 October 2026. It's in Sprout's passport." once it
/// settles; it stays for the notice window (the assistive one with VoiceOver or Switch Control), then goes, and
/// the next open of the passport still lands the stamp.
struct PassportNewStampBanner: View {
    let presenter: WorldPassportPresenter
    let store: FernletStore
    let entry: PassportStampEntry
    @State private var library: PassportLibrary
    @State private var hasLanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(presenter: WorldPassportPresenter, store: FernletStore, entry: PassportStampEntry) {
        self.presenter = presenter
        self.store = store
        self.entry = entry
        _library = State(initialValue: PassportLibrary(openAtlas: { [store] in store.worldFog.atlas.openedAtlas },
                                                       seaNeighbours: { [store] in store.worldFog.atlas.seaNeighbours() }))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let settled = hasLanded || reduceMotion
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                stamp
                    .frame(width: 48, height: 48)
                    .scaleEffect(settled ? 1 : 1.4)
                    .opacity(settled ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PassportNewStampCopy.title(name))
                        .font(WorldType.bannerTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                    Text(PassportNewStampCopy.detail(companion: WorldRecenterCopy.companionName(store)))
                        .font(WorldType.bannerDetail)
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { shape.fill(WorldPalette.ink.opacity(0.35)).offset(y: 4) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: announcement))
        .accessibilityHint(Text(PassportNewStampCopy.hint))
        .accessibilityInputLabels([Text(PassportNewStampCopy.title(name)), Text(PassportBookCopy.passport)])
        .accessibilityIdentifier("passportStampBanner")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.5).delay(0.18)) { hasLanded = true }
        }
        .task(id: entry) { await present() }
    }

    /// The stamp's own art, fitted to the banner's 48-pt square.
    @ViewBuilder
    private var stamp: some View {
        if let kind = entry.stampKind {
            PassportStampView(model: PassportStampModel(kind: kind, firstVisit: entry.date), library: library,
                              scale: PassportNewStampCopy.artScale(for: kind))
                .accessibilityHidden(true)
        }
    }

    /// The stamp's name as its page prints it ("Sea of Japan", "Canada").
    private var name: String {
        guard let kind = entry.stampKind else { return "" }
        return library.name(of: kind, onPage: true)
    }

    /// What VoiceOver hears: "New stamp, Sea of Japan, 24 October 2026. It's in Sprout's passport."
    private var announcement: String {
        String(localized: PassportNewStampCopy.announcement(name, on: PassportDates.long(entry.date),
                                                            companion: WorldRecenterCopy.companionName(store)))
    }

    /// The tap: the banner goes and the passport opens on the stamp's page, landing it.
    private func open() {
        presenter.bannerShown()
        presenter.open()
    }

    /// Speaks the banner once a closing sheet has settled, holds it for its window, then lets it go. Cancelled when
    /// the banner is covered first: the stamp stays and the banner comes back when the cover lifts.
    private func present() async {
        let window = FernletDismissalWindow.system.window(standard: .seconds(4),
                                                          assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: TaskConfirmation.sheetSettle)
            FernletAnnouncer.system.announce(.status, resolved: announcement)
            // DEBUG `FERNLET_UI_TEST_HOME_HOOK=new` keeps the banner up for its screenshot; false in Release.
            guard !UITestSupport.homeHookHoldsBanner else { return }
            try await Task.sleep(for: window)
        } catch {
            return
        }
        if presenter.bannerStamp == entry { presenter.bannerShown() }
    }
}

/// The new-stamp banner's words (Spanish drafts in the lane's `r7-explore-ui-es-hook.json`) and its art's size.
nonisolated enum PassportNewStampCopy {
    /// "New stamp: Sea of Japan".
    static func title(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("passport.newStampBanner.title", defaultValue: "New stamp: \(name)",
                                comment: "Home banner when a passport stamp is earned; the stamp's place (Spanish: Sello nuevo: Mar del Japón)")
    }

    /// "It's in Sprout's passport."
    static func detail(companion: String) -> LocalizedStringResource {
        LocalizedStringResource("passport.newStampBanner.detail", defaultValue: "It's in \(companion)'s passport.",
                                comment: "Home banner's second line when a passport stamp is earned; the companion's name (Spanish: Está en el pasaporte de Sprout.)")
    }

    /// "New stamp, Sea of Japan, 24 October 2026. It's in Sprout's passport." (announced, and the banner's label).
    static func announcement(_ name: String, on date: String, companion: String) -> LocalizedStringResource {
        LocalizedStringResource("passport.newStampBanner.spoken", defaultValue: "New stamp, \(name), \(date). It's in \(companion)'s passport.",
                                comment: "VoiceOver: the Home banner for a new passport stamp: the place, the date, then the companion's name")
    }

    /// The banner's VoiceOver hint.
    static let hint = LocalizedStringResource("passport.newStampBanner.hint", defaultValue: "Opens the passport on its page.",
                                              comment: "VoiceOver hint on the Home banner for a new passport stamp")

    /// Points per postmark point (a special's per pixel) that fit the stamp in the banner's 48-pt square: a country's
    /// 56 × 44 postmark at 0.8, a round or hexagonal one at 0.9, a special to 44 pt.
    static func artScale(for kind: PassportStampKind) -> CGFloat {
        switch kind {
        case .country: 0.8
        case .continent, .ocean, .sea: 0.9
        case .special(let allOceans): 44 / CGFloat(max(PassportStampArt.special(allOceans: allOceans).count, 1))
        }
    }
}

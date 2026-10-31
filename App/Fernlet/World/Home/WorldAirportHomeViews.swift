import FernletUI
import SwiftUI
import WorldMapStore

/// An airport banner over Home (World-Airports-Spec §3, §6.3), drawn like the approved stamp banner
/// (`b1-stamp-banner`, ``PassportNewStampBanner``): a paper plate in a 3-pt ink frame with a solid drop shadow, the
/// airport's found tower as its art (until the passport lane's airport stamp art is in), "New stamp: Portland
/// International" or "Landed at Heathrow", and its second line. Tapping it opens the passport. VoiceOver hears both
/// lines once it settles; it stays for the notice window (the assistive one with VoiceOver or Switch Control),
/// then goes. A landing's plays one firm haptic as it first shows (the driver's ``onAppear``).
struct WorldAirportBanner: View {
    let model: WorldAirportBannerModel
    let onOpen: () -> Void
    /// The banner had its window.
    let onShown: () -> Void
    /// The banner appeared (the driver plays a landing's haptic, once).
    let onAppear: () -> Void
    @State private var hasLanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let settled = hasLanded || reduceMotion
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                WorldSpriteView(sprite: WorldAirportSprites.tower(found: true, dark: colorScheme == .dark), scale: 2)
                    .frame(width: 48, height: 48)
                    .scaleEffect(settled ? 1 : 1.4)
                    .opacity(settled ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.title)
                        .font(WorldType.bannerTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                    Text(verbatim: model.detail)
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
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityHint(Text(WorldAirportCopy.bannerHint))
        .accessibilityInputLabels([Text(verbatim: model.title), Text(PassportBookCopy.passport)])
        .accessibilityIdentifier("world.airport.banner")
        .onAppear {
            onAppear()
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.5).delay(0.18)) { hasLanded = true }
        }
        .task(id: model.id) { await present() }
    }

    /// Both lines, as VoiceOver hears them.
    private var spoken: String { WorldAirportCopy.spokenBanner(title: model.title, detail: model.detail) }

    /// Speaks the banner once a closing sheet has settled, holds it for its window, then lets it go. Cancelled when
    /// the banner is covered first: it comes back when the cover lifts.
    private func present() async {
        let window = FernletDismissalWindow.system.window(standard: .seconds(4),
                                                          assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: TaskConfirmation.sheetSettle)
            FernletAnnouncer.system.announce(.status, resolved: spoken)
            // DEBUG `FERNLET_UI_TEST_AIRPORT` keeps the banner up for its screenshot; nil in Release.
            guard UITestSupport.airportHomeScene == nil else { return }
            try await Task.sleep(for: window)
        } catch {
            return
        }
        onShown()
    }
}

/// "At the airport · PDX" (§5; the kit's `.here` tag): DM Sans bold 15 on cream in a 3-pt ink frame with a solid
/// shadow, beside the blue button while the person is inside an airport's grounds (where Home's "Remember this
/// place" chip would sit; an airport is never offered as a place to remember). Static text: "At the airport, PDX".
/// Nothing in a decoy.
struct WorldAirportTag: View {
    let code: String

    var body: some View {
        Text(verbatim: WorldAirportCopy.tag(code: code))
            .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(WorldPalette.bark)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { RoundedRectangle(cornerRadius: 8).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorldAirportCopy.spokenTag(code: code)))
            .accessibilityIdentifier("world.airport.tag")
    }

    /// The code the tag shows: the airport whose grounds hold the person (not flying), when the list names it;
    /// nil in a decoy.
    @MainActor
    static func code(_ store: FernletStore) -> String? {
        guard !store.duressSessionActive else { return nil }
        let flights = store.worldLocation.flights
        guard let token = flights.currentAirport else { return nil }
        return flights.airportsShelf.pack()?.airport(token: token)?.code ?? token
    }
}

/// The layover counter (§5, screen 7; the kit's `XB.notice` with the jet): after a landing, while the person stays
/// inside the grounds, "Layover at Helsinki · 2 h 14 min" over "Since you landed. Fly on, and its stamp says
/// Transit.", counting up by the minute with Home's own minute clock. VoiceOver reads it when it appears and when
/// focused, never every minute. Nothing in a decoy.
struct WorldLayoverPlate: View {
    let store: FernletStore
    /// Home's minute clock.
    let date: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let layover {
            let title = WorldAirportCopy.layover(city: layover.city, minutes: Int(layover.since / 60))
            ViewThatFits(in: .horizontal) {
                plate(title: title).fixedSize()
                plate(title: title).frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 380 : 360)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("world.airport.layover")
            .task(id: layover.token) { await announce(title: title) }
        }
    }

    /// The airport landed at, its city and the time since landing; nil when not on a layover or in a decoy.
    private var layover: (token: String, city: String, since: TimeInterval)? {
        guard !store.duressSessionActive else { return nil }
        let flights = store.worldLocation.flights
        guard let token = flights.layoverAirport, let since = flights.layoverDuration(at: date) else { return nil }
        let city = flights.airportsShelf.pack()?.airport(token: token).map { WorldAirportCopy.city($0) } ?? token
        return (token, city, since)
    }

    /// The framed plate: the jet, the bold line and the line under it, read as one.
    private func plate(title: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            WorldSpriteView(sprite: WorldAirportSprites.rollingJet(tail: 0), scale: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(WorldNoticeType.title)
                Text(WorldAirportCopy.layoverDetail).font(WorldNoticeType.detail)
            }
            .foregroundStyle(WorldPalette.bark)
            .fernletWrappingText()
            .accessibilityElement(children: .combine)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background { RoundedRectangle(cornerRadius: 9).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3) }
    }

    /// Says the counter once as it appears (a landing's own screen), after any sheet has settled.
    private func announce(title: String) async {
        do {
            try await Task.sleep(for: TaskConfirmation.sheetSettle)
        } catch {
            return
        }
        let detail = String(localized: WorldAirportCopy.layoverDetail)
        FernletAnnouncer.system.announce(.status, resolved: WorldAirportCopy.spokenBanner(title: title, detail: detail))
    }
}

/// Sprout's travel look on the map (§5, amended by 18; the mockup's `travel()`): on a trip, inside an airport's
/// grounds, a little suitcase at Sprout's side (`CASE`, 7 × 11 at 3×, its corner at +30, −33 from Sprout's feet)
/// and a sleep mask pushed up on its forehead (`MASK`, 14 × 4 at 3×, at −21, −47), over whatever it wears; the
/// Wardrobe never changes. Decoration, hidden from VoiceOver. Nothing in a decoy.
struct WorldTravelLook: View {
    let store: FernletStore
    /// Where Sprout's feet stand on the screen.
    let point: CGPoint

    var body: some View {
        if !store.duressSessionActive, store.worldLocation.flights.showsTravelLook {
            ZStack(alignment: .topLeading) {
                WorldSpriteView(sprite: WorldAirportSprites.suitcase, scale: 3)
                    .position(x: point.x + 30 + 10.5, y: point.y - 33 + 16.5)
                WorldSpriteView(sprite: WorldAirportSprites.sleepMask, scale: 3)
                    .position(x: point.x - 21 + 21, y: point.y - 47 + 6)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

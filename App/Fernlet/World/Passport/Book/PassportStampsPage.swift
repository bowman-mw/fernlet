import FernletUI
import SwiftUI
import WorldMapStore

/// A stamp page (World-Passport-Spec §6; owner 2026-11-15, denser and hand-stamped): the header with the months it
/// covers, then its stamps in visit order, two across and five down (``PassportStampEntry/perPage``), each pressed
/// by hand (``PassportStampHand``: a seeded turn of up to ±8° and a few points' shift) at 1.5× with its date box.
/// No dashed spaces: on the newest page (unless every stamp is found) the next free spot shows a faint dotted "The
/// next stamp lands here". A fresh passport's page shows the dashed postmark, "No stamps yet" and where stamps come
/// from.
///
/// **Overlaps.** The rows sit closer than the tallest stamp, so a round or hex stamp's foot can rest over the top
/// of the stamp below it. Each row is drawn over the rows below it, so what overlaps is only ever the lower stamp's
/// art under the upper stamp's date box, never a name or a date. Across a row the cells keep the stamps apart.
/// VoiceOver reads the stamps in visit order, row by row.
///
/// `landing` lands with a thump (``PassportLandingStamp``); `wiggle` gives that stamp a small wiggle (a name tapped
/// in the index).
struct PassportStampsPage: View {
    let book: PassportBookModel
    /// Which stamp page, from 0.
    let index: Int
    let library: PassportLibrary
    var landing: PassportStampEntry?
    var wiggle: PassportWiggle?
    /// Whether every stamp is found (no next spot then).
    var full = false
    /// The words' share of a row (a name and a date box), grown with Dynamic Type; the art's share is fixed.
    @ScaledMetric(relativeTo: .caption) private var wordsBand: CGFloat = 32

    /// Stamps across a row.
    static let across = 2
    /// The stamps' scale on a page (a country's 84 × 66 pt, a round or hex stamp's 72 pt).
    static let stampScale: CGFloat = 1.5
    /// The art's share of a row, in points (a round or hex stamp at ``stampScale`` is 72, with a little air).
    static let artBand: CGFloat = 76

    var body: some View {
        let stamps = book.stamps(onStampPage: index)
        VStack(alignment: .leading, spacing: 10) {
            PassportPageHeader(title: Text(PassportBookCopy.stamps), detail: months.map { Text(verbatim: $0) })
            if stamps.isEmpty {
                PassportFreshStamps()
            } else {
                grid(stamps)
            }
        }
    }

    /// The stamps in rows of ``across``, each row over the ones below it, then the next spot where there is room.
    private func grid(_ stamps: [PassportStampEntry]) -> some View {
        let showsNext = !full && book.isNewestStampPage(index) && stamps.count < PassportStampEntry.perPage
        let slots = stamps.map(Optional.some) + (showsNext ? [nil] : [])
        let rows = stride(from: 0, to: slots.count, by: Self.across).map { Array(slots[$0 ..< min($0 + Self.across, slots.count)]) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row, slots in
                HStack(spacing: 4) {
                    ForEach(0 ..< Self.across, id: \.self) { column in
                        slot(column < slots.count ? slots[column] : nil, filled: column < slots.count)
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.artBand + wordsBand)
                    }
                }
                .zIndex(Double(rows.count - row))
            }
        }
    }

    /// One place in a row: a stamp, the next spot (`entry` nil and `filled`), or nothing.
    @ViewBuilder
    private func slot(_ entry: PassportStampEntry?, filled: Bool) -> some View {
        if let entry {
            cell(entry)
        } else if filled {
            PassportNextSpot()
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    /// One stamp: landing, wiggling or still.
    @ViewBuilder
    private func cell(_ entry: PassportStampEntry) -> some View {
        if let landing, PassportStampKey(landing) == PassportStampKey(entry) {
            PassportLandingStamp(entry: entry, library: library)
        } else {
            PassportPlacedStamp(entry: entry, library: library, scale: Self.stampScale, hand: PassportStampHand(entry))
                .modifier(PassportWiggleEffect(trigger: wiggle?.matches(entry) == true ? wiggle?.count ?? 0 : 0))
        }
    }

    /// The months the page covers ("AUG – SEP 2026"), or nil on a fresh page.
    private var months: String? {
        book.dates(onStampPage: index).map { PassportBookDates.months(from: $0.first, to: $0.last) }
    }
}

/// The dotted spot on the newest page where the next stamp lands (`.ppnext`): 120 × 92 pt.
struct PassportNextSpot: View {
    var body: some View {
        Text(PassportPageCopy.nextStamp)
            .font(PassportBookType.next)
            .foregroundStyle(PassportBookPalette.dim)
            .multilineTextAlignment(.center)
            .fernletWrappingText()
            .padding(8)
            .frame(minWidth: 120, minHeight: 92)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(PassportBookPalette.rule, style: StrokeStyle(lineWidth: 2, dash: [2, 3])))
            .accessibilityElement(children: .combine)
    }
}

/// A fresh passport's stamp page (`ps-fresh`): the dashed postmark, "No stamps yet", where stamps come from and
/// that they need location (While Using is enough).
struct PassportFreshStamps: View {
    var body: some View {
        VStack(spacing: 12) {
            PassportPostmark(stamp: nil, shape: .rect, scale: 1.9)
                .accessibilityHidden(true)
            Text(PassportPageCopy.noStamps)
                .font(Font.custom(FernletFontName.frauncesSemiBold, size: 20, relativeTo: .title3))
                .foregroundStyle(PassportBookPalette.text)
                .accessibilityAddTraits(.isHeader)
            Group {
                Text(PassportPageCopy.freshWhere)
                Text(PassportPageCopy.freshLocation)
            }
            .font(Font.custom(FernletFontName.dmSans, size: 14, relativeTo: .subheadline))
            .foregroundStyle(PassportBookPalette.dim)
            .multilineTextAlignment(.center)
            .fernletWrappingText()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 440)
    }
}

/// A new stamp landing (World-Passport-Spec §6, `ps-new`): it thumps down 12 % big and still, then settles to its
/// hand placement (``PassportStampHand``) with a burst of ink pixels (0.4 s) and one firm haptic. Reduce Motion: it fades in. VoiceOver
/// announces "New stamp, Sea of Japan, 24 October 2026".
struct PassportLandingStamp: View {
    let entry: PassportStampEntry
    let library: PassportLibrary
    @State private var settled = false
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PassportPlacedStamp(entry: entry, library: library, scale: PassportStampsPage.stampScale,
                            still: !settled && !reduceMotion, hand: PassportStampHand(entry))
            .scaleEffect(settled || reduceMotion ? 1 : 1.12)
            .opacity(reduceMotion && !settled ? 0 : 1)
            .overlay { if !reduceMotion { PassportInkBurst(active: burst) } }
            .task { await land() }
    }

    /// Thumps, settles, bursts and announces, once.
    private func land() async {
        guard !settled else { return }
        do {
            try await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 800))
        } catch {
            return
        }
        if reduceMotion {
            withAnimation(.easeIn(duration: 0.3)) { settled = true }
        } else {
            FernletFeedback.system.play(.held)
            withAnimation(.spring(duration: 0.4, bounce: 0.25)) { settled = true }
            withAnimation(.easeOut(duration: 0.4)) { burst = true }
        }
        announce()
    }

    private func announce() {
        guard let kind = entry.stampKind else { return }
        let words = String(localized: PassportBookCopy.newStampAnnouncement(library.name(of: kind, onPage: true),
                                                                             on: PassportDates.long(entry.date)))
        FernletAnnouncer.system.announce(.status, resolved: words)
    }
}

/// The ink pixels that fly off a landing stamp (the mockup's `ppland`): six pairs of moss squares that move out and
/// fade over 0.4 s. Decoration.
struct PassportInkBurst: View {
    let active: Bool
    /// The mockup's pixel pairs in its 150 × 172 box: a square's centre and how far it flies.
    private static let pixels: [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] = [
        (18, 40, -10, -6), (132, 40, 10, -6), (14, 128, -10, 6), (136, 128, 10, 6), (75, 18, 0, -9), (75, 150, 0, 9)
    ]

    var body: some View {
        GeometryReader { proxy in
            let sx = proxy.size.width / 150, sy = proxy.size.height / 172
            ForEach(Array(Self.pixels.enumerated()), id: \.offset) { _, pixel in
                let travel: CGFloat = active ? 1.6 : 0
                Rectangle().fill(PassportBookPalette.moss).frame(width: 6, height: 6)
                    .position(x: pixel.x * sx + pixel.dx * travel, y: pixel.y * sy + pixel.dy * travel)
                Rectangle().fill(PassportBookPalette.moss).frame(width: 4, height: 4)
                    .position(x: (pixel.x + pixel.dx) * sx + pixel.dx * travel * 1.5,
                              y: (pixel.y + pixel.dy) * sy + pixel.dy * travel * 1.5)
            }
        }
        .opacity(active ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A stamp to wiggle when it is turned to from the index: its key and a count that moves on each tap.
nonisolated struct PassportWiggle: Equatable, Sendable {
    let kind: PassportStampEntry.Kind
    let token: String
    let count: Int

    /// Whether `entry` is the stamp to wiggle (any trip of a country).
    func matches(_ entry: PassportStampEntry) -> Bool {
        entry.kind == kind && entry.token.uppercased() == token.uppercased()
    }
}

/// A small wiggle (±4°) each time `trigger` moves on; none with Reduce Motion.
struct PassportWiggleEffect: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion || trigger == 0 {
            content
        } else {
            content.phaseAnimator([0.0, -4, 4, -2, 0], trigger: trigger) { view, angle in
                view.rotationEffect(.degrees(angle))
            } animation: { _ in .easeInOut(duration: 0.09) }
        }
    }
}

import FernletUI
import SwiftUI
import WorldMapStore

/// Where the book is in its opening and closing (World-Passport-Spec §1): how far it has risen from Sprout (0 at
/// Sprout, 1 in place), the cover's swing (0 closed, -180 open), the veil's and the bar's strength, and the whole
/// screen's fade (Reduce Motion fades instead of rising and swinging).
nonisolated struct PassportBookMotion: Equatable, Sendable {
    var lift: Double = 0
    var cover: Double = 0
    var veil: Double = 0
    var chrome: Double = 0
    var fade: Double = 1

    /// The book open and still.
    static let open = PassportBookMotion(lift: 1, cover: -180, veil: 1, chrome: 1, fade: 1)
}

/// Moves and scales the book between where Sprout stands (`anchor`, in global coordinates; the screen's centre
/// when nil) and its place: at `lift` 0 it is a small closed book at Sprout, at 1 in place.
struct PassportRiseEffect: ViewModifier {
    let lift: Double
    let anchor: CGPoint?
    let proxy: GeometryProxy

    init(lift: Double, anchor: CGPoint?, in proxy: GeometryProxy) {
        self.lift = lift
        self.anchor = anchor
        self.proxy = proxy
    }

    func body(content: Content) -> some View {
        let frame = proxy.frame(in: .global)
        let target = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let away = 1 - lift
        content
            .scaleEffect(0.18 + 0.82 * lift)
            .offset(x: (target.x - frame.midX) * away, y: (target.y - frame.midY) * away)
    }
}

extension PassportBookScreen {
    // MARK: Opening and closing

    /// The first moment: the page this open starts on, then the rise and the swing (or the fade).
    func start(_ book: PassportBookModel) {
        landing = presenter.landing
        page = presenter.startPage(in: book)
        detail = presenter.demo?.detail
        showsContents = presenter.demo?.opensContents ?? false
        if reduceMotion {
            motion = PassportBookMotion.open
            motion.fade = 0
            withAnimation(.easeInOut(duration: 0.2)) { motion.fade = 1 } completion: { pageFocused = true }
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            motion.lift = 1
            motion.veil = 1
        } completion: {
            withAnimation(.easeInOut(duration: 0.3)) {
                motion.cover = -180
                motion.chrome = 1
            } completion: { pageFocused = true }
        }
    }

    /// The closing: the cover swings shut and the book sinks back to Sprout (or it fades), then it goes.
    func finish() {
        showsContents = false
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { motion.fade = 0 } completion: { presenter.dismiss() }
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            motion.cover = 0
            motion.chrome = 0
        } completion: {
            withAnimation(.easeIn(duration: 0.25)) {
                motion.lift = 0
                motion.veil = 0
            } completion: { presenter.dismiss() }
        }
    }

    // MARK: Turning

    /// One page on (`by` 1) or back (-1); in an A to Z view, the next or previous continent.
    func step(_ by: Int, in book: PassportBookModel) {
        if let detail {
            guard case .continent(let continent) = detail,
                  let position = AtlasContinentOrder.position(of: continent) else { return }
            let next = position + by
            guard AtlasContinentOrder.order.indices.contains(next) else { return }
            stepDetail(.continent(AtlasContinentOrder.order[next]))
            return
        }
        go(to: page + by, in: book)
    }

    /// Turns to page `number`: the pixel curl in four steps (0.3 s) with a light haptic, or a 0.15 s cross-fade
    /// with Reduce Motion. VoiceOver hears the new page.
    func go(to number: Int, in book: PassportBookModel) {
        let target = book.clamped(number)
        guard target != page, turn == nil else { return }
        detail = nil
        pageOnTop = true
        FernletFeedback.system.play(.tick)
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { page = target }
            announce(book)
            return
        }
        turn = PassportTurn(from: page, to: target, step: 1)
        Task { await curl(to: target, in: book) }
    }

    /// The curl's remaining steps, 75 ms apart.
    private func curl(to target: Int, in book: PassportBookModel) async {
        for next in 2 ... 4 {
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                break
            }
            if next < 4 { turn?.step = next } else { turn = nil }
            if next == 2 { page = target }
        }
        page = target
        turn = nil
        announce(book)
    }

    /// "Page 3 of 6, Stamps, 14 August to 21 September".
    private func announce(_ book: PassportBookModel) {
        let name = String(localized: PassportBookCopy.name(of: book.page(at: page)))
        let words: LocalizedStringResource
        if case .stamps(let index) = book.page(at: page), let dates = book.dates(onStampPage: index) {
            words = PassportBookCopy.turned(page, of: book.pageCount, named: name,
                                            from: PassportBookDates.dayMonth(dates.first),
                                            to: PassportBookDates.dayMonth(dates.last))
        } else {
            words = PassportBookCopy.turned(page, of: book.pageCount, named: name)
        }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: words))
    }

    /// A name tapped in the index or the A to Z view: turn to its page and wiggle its stamp.
    func turnFromIndex(to number: Int, kind: PassportStampEntry.Kind, token: String, in book: PassportBookModel) {
        wiggle = PassportWiggle(kind: kind, token: token, count: (wiggle?.count ?? 0) + 1)
        go(to: number, in: book)
    }

    /// Opens an A to Z view inside the book, steps to another, or (nil) goes back to the index.
    func stepDetail(_ next: PassportIndexDetail?) {
        FernletFeedback.system.play(.tick)
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { detail = next }
        } else {
            detail = next
        }
    }

    /// Sideways turns the page (or steps the continent); down, from the top of the page, closes the book.
    func swipe(_ book: PassportBookModel) -> some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let across = value.translation.width, down = value.translation.height
            if abs(across) > 60, abs(across) > abs(down) {
                step(across < 0 ? 1 : -1, in: book)
            } else if down > 120, down > abs(across) * 1.5, pageOnTop {
                requestClose()
            }
        }
    }
}

/// The seven continents in the passport's order, for stepping between their A to Z views.
nonisolated enum AtlasContinentOrder {
    static let order = AtlasContinent.passportOrder

    /// `continent`'s place in ``order``.
    static func position(of continent: AtlasContinent) -> Int? {
        order.firstIndex(of: continent)
    }
}

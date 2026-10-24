//
//  FernletPlateNavigation.swift
//  FernletUI
//
//  Going deeper inside a panel (`b1-frame-push`, draft 2, approved 2026-10-23): a pushed page keeps the
//  panel's wooden plate, which shows a Back naming the page you came from, the pushed page's title, and
//  the panel's ✕. The plate lives outside the panel's NavigationStack, so a pushed page hands it its
//  title and its pop through this model.
//

import FernletDomainModel
import Observation
import SwiftUI
import UIKit

/// The pages pushed inside one title plate, bottom first: what the plate draws and where its Back goes.
///
/// A plate owner (the World panel frame) keeps one in `@State` and puts it in the environment
/// (``EnvironmentValues/fernletPlateNavigation``); each page that calls ``SwiftUI/View/fernletPushedPage(_:)``
/// reports when it appears and when it disappears, nothing else (SwiftUI's `isPresented` is false for a
/// page covered by a push as well as for one popped, so it cannot tell the two apart). From that order:
///
/// - the plate shows the last page that is showing (``top``), and Back names the page recorded under it,
///   or the panel (``topBackTitle``);
/// - a page that disappears while a page under it is showing was popped, and goes;
/// - a page that shows again drops the hidden pages above it (they were popped while it was covered);
/// - a page that disappears with nothing showing under it is covered (a push, a full-screen cover) and
///   stays, unless it is still hidden ``staleAfter`` later when a new page arrives (a pop-to-root's
///   leftovers).
///
/// It holds whichever of a pop's two events SwiftUI sends first, and through an edge swipe that is let go
/// halfway. **Bounded** at ``capacity`` pages; a deeper push drops the oldest record. **Known gap:** a stack
/// opened several pages deep at once (a deep link) records only the page that shows; Back names the panel
/// there, and after an edge swipe reveals the page under it, Back on that page can name the page that was
/// just popped. The plate's own Back is always right: it drops a bottom page the moment it pops it.
@MainActor @Observable
public final class FernletPlateNavigation {
    /// One pushed page.
    public struct Page: Identifiable {
        public let id: UUID
        /// The page's title on the plate, already in the reader's language.
        public var title: String
        /// Pops this page off its stack (its `dismiss`).
        let pop: @MainActor () -> Void
        /// When the page last disappeared; nil while it is on screen.
        var hiddenSince: Date?
    }

    /// The plate's own title: where Back from the first pushed page goes.
    public var rootTitle: String
    /// The recorded pages, bottom first.
    public private(set) var pages: [Page] = []
    /// The close guards of pages holding unsaved work, by page (``setCloseGuard(id:_:)``). Only the
    /// recorded pages' guards are kept, so a popped page's guard goes with it and this stays within
    /// ``capacity``.
    @ObservationIgnored private var closeGuards: [UUID: @MainActor () -> Bool] = [:]
    /// The clock, injectable for tests.
    private let now: () -> Date

    /// The most pages a plate records.
    public static let capacity = 12
    /// How long a page may sit hidden before a new push treats it as gone (a pop-to-root's leftovers).
    public static let staleAfter: TimeInterval = 0.3

    public init(rootTitle: String = "", now: @escaping () -> Date = Date.init) {
        self.rootTitle = rootTitle
        self.now = now
    }

    /// Where the page the plate shows sits in ``pages``: the last one on screen.
    private var topIndex: Int? {
        pages.lastIndex { $0.hiddenSince == nil }
    }

    /// The page the plate shows, or nil when the panel's own page is showing (or a cover hides them all).
    public var top: Page? {
        topIndex.map { pages[$0] }
    }

    /// Where Back on the page showing goes: the page recorded under it, or the panel.
    public var topBackTitle: String {
        guard let index = topIndex, index > 0 else { return rootTitle }
        return pages[index - 1].title
    }

    /// A page appeared: record it, or mark it showing again and drop the popped pages hidden above it.
    public func show(id: UUID, title: String, pop: @escaping @MainActor () -> Void) {
        if let index = pages.firstIndex(where: { $0.id == id }) {
            pages[index].hiddenSince = nil
            pages[index].title = title
            let above = pages[(index + 1)...].filter { $0.hiddenSince == nil }
            pages = Array(pages[...index]) + above
            return
        }
        dropStale()
        pages.append(Page(id: id, title: title, pop: pop, hiddenSince: nil))
        if pages.count > Self.capacity { pages.removeFirst(pages.count - Self.capacity) }
    }

    /// A page disappeared: popped when a page under it is showing (it goes), else covered (it stays).
    public func hide(id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if pages[..<index].contains(where: { $0.hiddenSince == nil }) {
            pages.remove(at: index)
        } else {
            pages[index].hiddenSince = now()
        }
    }

    /// Back on the plate: pops the page showing. A bottom page goes at once, since the page under it may
    /// never have been recorded (a stack opened deep).
    public func popTop() {
        guard let index = topIndex else { return }
        pages[index].pop()
        if index == 0 { pages.remove(at: 0) }
    }

    /// Registers (or with nil, removes) the close guard of a page holding unsaved work: the panel's ✕
    /// asks it before closing the panel (``allowsClose()``). The guard asks the person itself (the
    /// Creation Studio's discard question) and answers false to keep the panel open. A page's guard
    /// is dropped once the page leaves the record.
    public func setCloseGuard(id: UUID, _ closeGuard: (@MainActor () -> Bool)?) {
        let recorded = Set(pages.map(\.id))
        closeGuards = closeGuards.filter { recorded.contains($0.key) }
        closeGuards[id] = closeGuard
    }

    /// Whether the panel's ✕ may close the panel now: the page showing answers through its close guard
    /// when it has one (false: it is asking the person first); every other page lets it close. Only
    /// the page on screen is asked, since only it can show its question.
    public func allowsClose() -> Bool {
        guard let top, let closeGuard = closeGuards[top.id] else { return true }
        return closeGuard()
    }

    /// Drops trailing pages hidden for longer than ``staleAfter``. Bounded by the record's size.
    private func dropStale() {
        let moment = now()
        for _ in 0..<pages.count {
            guard let last = pages.last, let hidden = last.hiddenSince,
                  moment.timeIntervalSince(hidden) > Self.staleAfter else { return }
            pages.removeLast()
        }
    }
}

public extension View {
    /// A page pushed inside a panel (`b1-frame-push`): under a title plate it hides its own navigation
    /// bar and hands the plate its title and Back ("‹ Settings  Appearance  ✕"); swipe from the left
    /// edge still pops it. Outside a plate (a sheet's own stack, the app without the World frame) it is
    /// `.navigationTitle(title)`. Apply it to the destination view, in place of `.navigationTitle`.
    ///
    /// ```swift
    /// .navigationDestination(for: Route.self) { route in page(route).fernletPushedPage(route.title) }
    /// ```
    func fernletPushedPage(_ title: LocalizedStringResource) -> some View {
        modifier(FernletPushedPageModifier(title: AddressedCopy.plain(title)))
    }

    /// ``fernletPushedPage(_:)`` for a title that is runtime data (a recipe's name).
    func fernletPushedPage(verbatim title: String) -> some View {
        modifier(FernletPushedPageModifier(title: title))
    }

    /// Keeps the edge swipe going back on a page that hides its navigation bar and draws its own Back:
    /// a page pushed inside a sheet's own stack (Log meal › Scan a food, Log workout › an exercise's
    /// sets), where no plate manages the stack. UIKit refuses its interactive pop while the bar is
    /// hidden; this installs the shared delegate that allows it whenever there is a page to go back to.
    /// Plate pages (``fernletPushedPage(_:)``) already have it.
    func fernletEdgeSwipeBack() -> some View {
        background { FernletEdgeSwipeBackInstaller().frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

/// Implements ``SwiftUI/View/fernletPushedPage(_:)``: reports the page's appearances to the plate, which
/// works out pushes, pops and covers from their order (``FernletPlateNavigation``).
struct FernletPushedPageModifier: ViewModifier {
    let title: String
    @Environment(\.fernletPlateNavigation) private var plate
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let plate {
            content
                .navigationTitle(Text(verbatim: title))
                .toolbar(.hidden, for: .navigationBar)
                // UIKit refuses the edge swipe while the bar is hidden; this gives it back.
                .fernletEdgeSwipeBack()
                .environment(\.fernletPageTitleOnPlate, true)
                .onAppear { plate.show(id: id, title: title, pop: { [dismiss] in dismiss() }) }
                .onDisappear { plate.hide(id: id) }
        } else {
            content.navigationTitle(Text(verbatim: title))
        }
    }
}

/// The plate's Back (`.pt .bk`, World Review Batch 2's spacing fix): the back arrow and the name of the
/// page it returns to, 7 pt apart, on raised paper in a 3-pt ink frame with 13 pt after the word.
///
/// The word gives way to the arrow alone when the page's own title is long (``isCompact(title:)``) and
/// at accessibility text sizes; VoiceOver always hears "Back to Settings", and Voice Control answers to
/// "Back" or the page's name.
public struct FernletBackButton: View {
    let destination: String
    var compact: Bool
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - destination: The page Back returns to, already in the reader's language.
    ///   - compact: Draw the arrow alone (the current page's title is long).
    public init(verbatim destination: String, compact: Bool = false, action: @escaping () -> Void) {
        self.destination = destination
        self.compact = compact
        self.action = action
    }

    /// Whether a page title is long enough that its Back shows the arrow alone (the kit's 13 letters).
    public static func isCompact(title: String) -> Bool {
        title.count > 13
    }

    public var body: some View {
        let showsWord = !compact && !dynamicTypeSize.isAccessibilitySize
        Button(action: action) {
            HStack(spacing: 7) {
                FernletIcon(.back, scale: 3)
                if showsWord {
                    Text(verbatim: destination).lineLimit(1)
                }
            }
            .font(FernletFramedFont.back)
            .foregroundStyle(look?.text ?? Color.bark)
            .padding(.leading, showsWord ? 10 : 9)
            .padding(.trailing, showsWord ? 13 : 9)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background { plate }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: FernletUICopy.backTo(destination)))
        .accessibilityInputLabels([Text(verbatim: FernletUICopy.back), Text(verbatim: destination)])
        .accessibilityIdentifier("plate.back")
    }

    /// The raised paper and its 3-pt ink frame (no frame without the look).
    @ViewBuilder
    private var plate: some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: 9)
            shape.fill(look.raised).overlay(shape.strokeBorder(look.ink, lineWidth: 3))
        }
    }
}

/// Keeps the edge swipe going back on a page whose navigation bar is hidden. UIKit refuses its
/// interactive pop whenever the bar is hidden, so a pushed page that hands its bar to the plate would
/// lose the swipe; this one shared delegate allows it whenever there is a page to go back to and no
/// transition is already running (the two conditions UIKit's own delegate checks).
final class FernletEdgeSwipeBack: NSObject, UIGestureRecognizerDelegate {
    /// The one delegate every plate-managed stack shares; it lives for the whole run.
    static let shared = FernletEdgeSwipeBack()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation = gestureRecognizer.view?.next as? UINavigationController else { return false }
        return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
    }
}

/// Installs ``FernletEdgeSwipeBack`` on the navigation controller of the page it sits in, each time the
/// page appears.
struct FernletEdgeSwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InstallerController {
        InstallerController()
    }

    func updateUIViewController(_ controller: InstallerController, context: Context) {}

    /// An empty child of the page's hosting controller, there to reach its navigation controller.
    final class InstallerController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            recognizer.delegate = FernletEdgeSwipeBack.shared
            recognizer.isEnabled = true
        }
    }
}

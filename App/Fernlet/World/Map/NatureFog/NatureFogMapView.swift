import SwiftUI
import UIKit
import WorldMapStore

/// What the fog layer shows: where the map looks, what's uncovered, its colours and the motion setting,
/// and Fernlet's camera request, so a glide's end is drawn before the map gets there (map-perf P3).
struct NatureFogScene {
    let viewport: MapViewport
    let clearing: NatureFogClearing
    let palette: NatureFogPalette
    let motion: NatureFogMotion
    /// Where Fernlet last asked the camera to go (following, Back to Sprout); nil when the caller has none.
    var camera: WorldCamera?
    /// The land under the fog (World-Exploration-Spec §1); nil for today's nature fog.
    var terrain: NatureFogTerrain? = nil
}

/// The nature fog on the live map, in the fog's old place in the stack (``WorldGroundLayer``: over the saved
/// trails, under the dotted traces, the night wash, the markers and Sprout). Decoration only: it takes no
/// touches and VoiceOver never reaches it, so clearing is never announced.
struct NatureFogLayer: UIViewRepresentable {
    let scene: NatureFogScene

    func makeUIView(context: Context) -> NatureFogMapView {
        NatureFogMapView(frame: .zero)
    }

    func updateUIView(_ view: NatureFogMapView, context: Context) {
        view.show(scene)
    }
}

/// The fog's cached tiles as Core Animation layers: each tile's ground picture with its growing pieces as
/// nearest-neighbour sprites in depth order, clipped to the tile, so a pan or a pinch only moves and scales
/// tiles and a tile redraws only when a hex in its reach clears (``NatureFogTileBook``). Grass and flowers
/// sway as render-server animations (no redraws), paused while the map moves; a clearing tile crossfades and
/// its blades and leaves scatter on a layer above (``NatureFogMotion``).
final class NatureFogMapView: UIView {
    /// One tile on screen: its clipping container (scaled to the map) and the sprites that sway.
    private struct TileLayers {
        let container: CALayer
        var swaying: [(layer: CALayer, group: Int)]
        var trees: [NatureStandingTree]
    }

    /// A drawn tile kept on screen after a zoom step, with the scale it was drawn at.
    private struct HeldTile {
        let scale: NatureFogScale
        let key: NatureTileKey
        let layers: TileLayers
    }

    /// Where tile space (global points at the book's scale) falls on screen.
    private struct Mapping {
        let originX: Double
        let originY: Double
        let stretchX: Double
        let stretchY: Double

        func screen(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - originX) * stretchX, y: (point.y - originY) * stretchY)
        }
    }

    /// How many scales the map keeps after leaving them.
    static let spareBookLimit = 3
    /// How many tiles a scale left behind keeps (its nearest to where the screen was).
    static let spareTileLimit = 16
    /// How long after a camera request its end keeps the first claim on the painters, in seconds (a glide).
    static let glideWindow = 6.0

    /// The most outgoing tiles kept across quick zoom steps.
    static let outgoingLimit = 96
    /// How far the current scale's tiles may be stretched while the map moves before the fog switches scale
    /// (W-20 allows 0.25–4): a pinch keeps drawing into one scale instead of dropping half-drawn tiles at
    /// every half octave (the owner's zoom artifact, 2026-10-30).
    static let holdRange = 0.6...1.7

    private static let swayKey = "nf.sway"
    /// Core Animation files every transition under `kCATransition`, whatever key it is added with.
    private static let clearKey = kCATransition
    private static let scatterKey = "nf.scatter"

    private var scene: NatureFogScene?
    private var book: NatureFogTileBook?
    private var shown: [NatureTileKey: TileLayers] = [:]
    /// Shown tiles whose picture hasn't arrived: the fog's colour, or clear over the outgoing tiles.
    private var waiting: Set<NatureTileKey> = []
    /// Shown tiles a clearing reached, keeping their old picture until the new one arrives; true to crossfade.
    private var redrawing: [NatureTileKey: Bool] = [:]
    /// The drawn tiles of the scales left behind by zoom steps, newest first, each moved with the map at its
    /// own scale until the new scale's tiles are all in (at most ``outgoingLimit``).
    private var outgoing: [HeldTile] = []
    /// Where the outgoing tiles sit on screen now; a waiting tile they cover all of shows them, not the fog's colour.
    private var outgoingFrames: [CGRect] = []
    /// Whether the map has sat still since it last moved (``settle(now:)``): only then does the fog switch to
    /// the scale that fits exactly.
    private var isSettled = false
    /// The screen's tiles last frame (lowest and highest key): the ring round them is held over on a zoom step.
    private var lastVisible: (low: NatureTileKey, high: NatureTileKey)?
    /// Waiting tiles that show the map rather than fog, because most of their ground is uncovered.
    private var showsMap: Set<NatureTileKey> = []
    private var lastMap: Mapping?
    /// The scales the map just left, most recent first, each keeping its nearest tiles (map-perf P2): zooming
    /// back finds them drawn. At most ``spareBookLimit``, all in the current palette, each holding the tiles
    /// that were on its screen or ``spareTileLimit``, whichever is more, plus the ``NatureFogTileBook/painterCount``
    /// still drawing when it was left.
    private var spareBooks: [NatureFogTileBook] = []
    /// The last camera request, when it came, whether it's still a glide under way (its end lay more than a
    /// screen away when it came, and the map hasn't since come near it or turned away from it: following the
    /// person moves the camera a little at a time and is no glide, and a pan ends one), and how far off its
    /// end was last frame, in tiles (map-perf P3).
    private var heading: (revision: Int, since: CFTimeInterval, gliding: Bool, gap: Double)?
    /// The middle of the screen last frame, in tiles, for which way the map is moving.
    private var lastCentre: CGPoint?
    private let effects = CALayer()
    private var lastViewport: MapViewport?
    private var lastMove: CFTimeInterval = 0
    private var settlePending = false
    /// Writes the audit line when a computed frame is refused (W-20).
    private let rejections = WorldLayerRejections()
    /// Whether grass and flowers sway now.
    private(set) var isSwaying = false
    /// Called once a tile's picture is in place, its crossfade and sway already added and not yet committed
    /// (tests read the animations here: a view outside a window loses them once they're committed).
    var onTileArrived: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        effects.frame = bounds
        layer.addSublayer(effects)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows `next`: moves the tiles with the map, redraws the ones a clearing reaches.
    func show(_ next: NatureFogScene) {
        scene = next
        apply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effects.frame = bounds
        apply()
    }

    private func apply() {
        guard let scene, bounds.width > 0, bounds.height > 0, scene.viewport.isUsable else { return }
        let viewport = scene.viewport, size = bounds.size
        let screenRadius = MercatorHexGrid.radius * viewport.pointsPerUnit(in: size)
        guard let ideal = NatureFogScale.tiles(forScreenRadius: screenRadius) else {
            dropAll()
            book = nil
            return
        }
        let scale = heldScale(screenRadius, viewport: viewport, palette: scene.palette)
            ?? steppedScale(toward: ideal, screenRadius: screenRadius, viewport: viewport, palette: scene.palette)
        let map = Self.mapping(viewport, size: size, scale: scale)
        // W-20: a stretch out of proportion (a skewed viewport, a size mid-change) drops this frame; the tiles
        // keep the last good one.
        guard rejections.note(WorldLayerGuard.accepts(stretchX: map.stretchX, stretchY: map.stretchY), at: .fogStretch) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let change = sync(scale: scale, scene: scene)
        noteMovement(viewport, motion: scene.motion)
        if let change { refresh(change, scene: scene, map: map) }
        lastMap = map
        placeOutgoing(viewport, size: size)
        place(map, size: size)
        CATransaction.commit()
    }

    /// The current book's scale while the map moves and its tiles show at ``holdRange`` of their size, in the
    /// same palette; nil once the map has settled, or past that range.
    private func heldScale(_ screenRadius: Double, viewport: MapViewport, palette: NatureFogPalette) -> NatureFogScale? {
        guard let book, book.palette == palette, !isSettled || viewport != lastViewport else { return nil }
        let shownAt = screenRadius / book.scale.radius
        return Self.holdRange.contains(shownAt) ? book.scale : nil
    }

    /// Mid-pinch, past the hold: the half octave nearest the current scale that brings its tiles back inside
    /// ``holdRange`` (at most `ideal`), so a pinch takes the next scale up or down, the one the still map drew
    /// ahead (``drawNeighbours()``), instead of jumping two at once (the owner's zoom on the phone,
    /// 2026-10-30). Once the map has settled, `ideal`.
    private func steppedScale(toward ideal: NatureFogScale, screenRadius: Double, viewport: MapViewport,
                              palette: NatureFogPalette) -> NatureFogScale {
        guard let book, book.palette == palette, !isSettled || viewport != lastViewport else { return ideal }
        let target = Self.step(of: ideal.radius)
        var step = Self.step(of: book.scale.radius)
        for _ in 0..<8 where step != target {
            step += target > step ? 1 : -1
            if Self.holdRange.contains(screenRadius / Self.radius(ofStep: step)) { break }
        }
        let radius = Self.radius(ofStep: step)
        return step == target ? ideal : NatureFogScale(radius: radius, reduced: radius < NatureFogScale.detailFloor)
    }

    /// The half octave from today's zoom a scale `radius` sits at (``NatureFogScale/tiles(forScreenRadius:)``'s steps).
    private static func step(of radius: Double) -> Int {
        guard radius > 0, radius.isFinite else { return 0 }
        return Int((2 * log2(radius / NatureFogScale.todayRadius)).rounded())
    }

    /// The radius of half-octave `step`, computed as ``NatureFogScale/tiles(forScreenRadius:)`` does, so the
    /// scales match exactly.
    private static func radius(ofStep step: Int) -> Double {
        NatureFogScale.todayRadius * pow(2, Double(step) / 2)
    }

    /// Where tile space at `scale` falls on screen for `viewport`.
    private static func mapping(_ viewport: MapViewport, size: CGSize, scale: NatureFogScale) -> Mapping {
        let perUnit = scale.pointsPerUnit
        return Mapping(originX: viewport.minX * perUnit, originY: viewport.minY * perUnit,
                       stretchX: Double(size.width) / viewport.width / perUnit, stretchY: Double(size.height) / viewport.height / perUnit)
    }

    /// Matches the book to the scene: a new clearing dirties tiles. A new scale or palette brings back the
    /// spare book at that scale or starts a new one, the old tiles staying on screen until the new ones are
    /// in, unless the clearing changed with it (then they go at once, so a decoy session never shows the
    /// history even for a moment); the old book becomes a spare. Fog coming back forgets every spare.
    private func sync(scale: NatureFogScale, scene: NatureFogScene) -> NatureFogChange? {
        if let book, book.scale == scale, book.palette == scene.palette, book.terrain == scene.terrain {
            let change = book.change(to: scene.clearing)
            if change.reset { dropAll() }
            // Fog coming back: the old scale's tiles were drawn from the history and go at once.
            if change.covers {
                dropOutgoing()
                spareBooks.removeAll()
            }
            return change.reset || change.dirty.isEmpty ? nil : change
        }
        let onScreen = Set(shown.keys)
        if let book, book.clearing == scene.clearing { keepOutgoing(scale: book.scale) } else { dropAll() }
        // The spare at the new scale leaves the spares before the old book joins them, so the limit never drops
        // a scale only to make room for one that's leaving.
        let reused = reuse(scale, scene: scene)
        if let book { retire(book, palette: scene.palette, keeping: onScreen) }
        book = reused ?? fresh(scale, scene: scene)
        lastCentre = nil
        return nil
    }

    /// Keeps `old` as a spare scale when the palette stays, drawing nothing more: the tiles that were on
    /// screen (`onScreen`) and the nearest others up to ``spareTileLimit``. A new palette forgets every spare.
    private func retire(_ old: NatureFogTileBook, palette: NatureFogPalette, keeping onScreen: Set<NatureTileKey>) {
        guard old.palette == palette else {
            spareBooks.removeAll()
            return
        }
        old.want([])
        old.evict(around: lastCentre ?? .zero, keeping: onScreen, limit: Self.spareTileLimit)
        spareBooks = Array(([old] + spareBooks.filter { $0 !== old }).prefix(Self.spareBookLimit))
    }

    /// The spare book at `scale`, brought up to the scene's clearing (dropping the tiles a change reached).
    private func reuse(_ scale: NatureFogScale, scene: NatureFogScene) -> NatureFogTileBook? {
        guard let index = spareBooks.firstIndex(where: { $0.scale == scale && $0.palette == scene.palette && $0.terrain == scene.terrain }) else { return nil }
        let spare = spareBooks.remove(at: index)
        _ = spare.change(to: scene.clearing)
        return spare
    }

    /// Once the map sits still and its own tiles are in, the half octaves either side draw the screen into spare
    /// books, so a pinch finds the next scale already drawn (the owner's zoom on the phone, 2026-10-30). The
    /// spares draw from the current clearing and go with any change that fogs cells again.
    private func drawNeighbours() {
        guard isSettled, let book, let scene, waiting.isEmpty, book.isCaughtUp else { return }
        let size = bounds.size, here = Self.step(of: book.scale.radius)
        for step in [here - 1, here + 1] {
            let radius = Self.radius(ofStep: step)
            guard radius >= NatureFogScale.minimumRadius,
                  let map = Self.acceptedMapping(scene.viewport, size: size, scale: NatureFogScale(radius: radius, reduced: false)) else { continue }
            let scale = NatureFogScale(radius: radius, reduced: radius < NatureFogScale.detailFloor)
            let spare = spareBooks.first { $0.scale == scale && $0.palette == scene.palette && $0.terrain == scene.terrain }
                ?? fresh(scale, scene: scene)
            _ = spare.change(to: scene.clearing)
            spareBooks = Array(([spare] + spareBooks.filter { $0 !== spare }).prefix(Self.spareBookLimit))
            let low = NatureFogTileBook.key(at: CGPoint(x: map.originX, y: map.originY))
            let high = NatureFogTileBook.key(at: CGPoint(x: map.originX + Double(size.width) / map.stretchX,
                                                         y: map.originY + Double(size.height) / map.stretchY))
            let centre = CGPoint(x: (map.originX + Double(size.width) / map.stretchX / 2) / NatureFogTileBook.tileSize,
                                 y: (map.originY + Double(size.height) / map.stretchY / 2) / NatureFogTileBook.tileSize)
            spare.want(NatureFogRing.keys(low: low, high: high, centre: centre, motion: .zero, limit: NatureFogTileBook.cacheLimit)
                .filter { (low.x...high.x).contains($0.x) && (low.y...high.y).contains($0.y) })
        }
    }

    /// A new book at `scale` whose tiles reach the screen only while it's the current one.
    private func fresh(_ scale: NatureFogScale, scene: NatureFogScene) -> NatureFogTileBook {
        let next = NatureFogTileBook(scale: scale, palette: scene.palette, clearing: scene.clearing,
                                     pixelScale: min(traitCollection.displayScale, 2), terrain: scene.terrain)
        next.onReady = { [weak self, weak next] tile in
            guard let self, let next, self.book === next else { return }
            self.arrived(tile)
        }
        if let book, book.palette == scene.palette { next.borrowPlaceholders(from: book) }
        return next
    }

    /// Shows the tiles on screen (only the ones the visible rect reaches) and drops the ones that left it, then
    /// asks for them and the ring round them. A tile whose frame fails ``WorldLayerGuard`` keeps its last good
    /// one, or isn't built (W-20). A tile not drawn yet shows the fog's colour, never a wait.
    private func place(_ map: Mapping, size: CGSize) {
        guard let book, map.stretchX > 0, map.stretchY > 0 else { return }
        let low = NatureFogTileBook.key(at: CGPoint(x: map.originX, y: map.originY))
        let high = NatureFogTileBook.key(at: CGPoint(x: map.originX + Double(size.width) / map.stretchX,
                                                     y: map.originY + Double(size.height) / map.stretchY))
        guard high.x >= low.x, high.y >= low.y, high.x - low.x < 12, high.y - low.y < 12 else { return }
        lastVisible = (low, high)
        var visible = Set<NatureTileKey>()
        for x in low.x...high.x {
            for y in low.y...high.y { visible.insert(NatureTileKey(x: x, y: y)) }
        }
        for (key, tile) in shown where !visible.contains(key) {
            tile.container.removeFromSuperlayer()
            forget(key)
        }
        let side = CGSize(width: NatureFogTileBook.tileSize * map.stretchX, height: NatureFogTileBook.tileSize * map.stretchY)
        var rejected = 0
        for key in visible {
            let corner = map.screen(NatureFogTileBook.area(of: key).origin)
            guard WorldLayerGuard.accepts(CGRect(origin: corner, size: side), in: size) else {
                rejected += 1
                continue
            }
            let frame = CGRect(origin: corner, size: side)
            let layers = shown[key] ?? build(key, from: book)
            shown[key] = layers
            if waiting.contains(key) { cover(layers.container, key: key, at: frame, book: book) }
            layers.container.position = corner
            layers.container.transform = CATransform3DMakeScale(map.stretchX, map.stretchY, 1)
        }
        rejections.note(rejected == 0, at: .fogTile)
        prefetch(low: low, high: high, map: map, size: size, book: book)
    }

    /// Asks for the screen's tiles and the ring round them, reaching further the way the map is moving
    /// (``NatureFogRing``), and lets the farthest cached tiles go. While a glide is far from its end, the
    /// end's screen and ring come first and the screen's own tiles after, with no ring: the frames between
    /// show the fog's colour rather than tiles that would scroll away before they're drawn (map-perf P3).
    private func prefetch(low: NatureTileKey, high: NatureTileKey, map: Mapping, size: CGSize, book: NatureFogTileBook) {
        let centre = CGPoint(x: (map.originX + Double(size.width) / map.stretchX / 2) / NatureFogTileBook.tileSize,
                             y: (map.originY + Double(size.height) / map.stretchY / 2) / NatureFogTileBook.tileSize)
        let motion = lastCentre.map { CGVector(dx: centre.x - $0.x, dy: centre.y - $0.y) } ?? .zero
        lastCentre = centre
        let limit = NatureFogTileBook.cacheLimit
        let wanted: [NatureTileKey]
        if let end = glideEnd(from: centre, low: low, high: high, size: size, book: book) {
            let screen = NatureFogRing.keys(low: low, high: high, centre: centre, motion: .zero, limit: limit)
                .filter { (low.x...high.x).contains($0.x) && (low.y...high.y).contains($0.y) }
            let ahead = NatureFogRing.keys(low: end.low, high: end.high, centre: end.centre, motion: .zero, limit: limit)
            wanted = ahead.isEmpty ? NatureFogRing.keys(low: low, high: high, centre: centre, motion: motion, limit: limit)
                : Array((ahead + screen.filter { !ahead.contains($0) }).prefix(limit))
        } else {
            wanted = NatureFogRing.keys(low: low, high: high, centre: centre, motion: motion, limit: limit)
        }
        // A tile showing the fog's colour (nothing older under it) is drawn before the rest.
        let bare = Set(waiting.filter { shown[$0]?.container.backgroundColor != nil })
        book.want(wanted.filter { bare.contains($0) } + wanted.filter { !bare.contains($0) })
        book.evict(around: centre, keeping: Set(wanted))
        if waiting.isEmpty { dropOutgoing() }
    }

    /// The tiles where a glide will end at `book`'s scale, while one is under way: Fernlet asked the camera
    /// to move within ``glideWindow``, to an end more than a screen from where the map was then, and it's
    /// still that far from `centre` (tile units). Nil otherwise, and for an end whose frame or size fails
    /// ``WorldLayerGuard`` (W-20).
    private func glideEnd(from centre: CGPoint, low: NatureTileKey, high: NatureTileKey, size: CGSize,
                          book: NatureFogTileBook) -> (low: NatureTileKey, high: NatureTileKey, centre: CGPoint)? {
        guard let camera = scene?.camera, camera.center.isValid else { return nil }
        let end = MapViewport.around(camera.center, heightMetres: camera.distance * PlainBaseMap.heightPerDistance, size: size)
        guard end.isUsable else { return nil }
        let map = Self.mapping(end, size: size, scale: book.scale)
        guard WorldLayerGuard.accepts(stretchX: map.stretchX, stretchY: map.stretchY) else { return nil }
        let endLow = NatureFogTileBook.key(at: CGPoint(x: map.originX, y: map.originY))
        let endHigh = NatureFogTileBook.key(at: CGPoint(x: map.originX + Double(size.width) / map.stretchX,
                                                        y: map.originY + Double(size.height) / map.stretchY))
        let endCentre = CGPoint(x: (map.originX + Double(size.width) / map.stretchX / 2) / NatureFogTileBook.tileSize,
                                y: (map.originY + Double(size.height) / map.stretchY / 2) / NatureFogTileBook.tileSize)
        let far = abs(endCentre.x - centre.x) > Double(high.x - low.x + 1) || abs(endCentre.y - centre.y) > Double(high.y - low.y + 1)
        let gap = Double(hypot(endCentre.x - centre.x, endCentre.y - centre.y))
        let now = CACurrentMediaTime()
        guard var current = heading, current.revision == camera.revision else {
            heading = (camera.revision, now, far, gap)
            return far ? (endLow, endHigh, endCentre) : nil
        }
        // Near the end, or moving away from it (the person took the map): the glide is over.
        current.gliding = current.gliding && far && gap <= current.gap + 0.05 && now - current.since < Self.glideWindow
        current.gap = gap
        heading = current
        return current.gliding ? (endLow, endHigh, endCentre) : nil
    }

    /// Moves the outgoing tiles with the map, each at its own scale; a scale whose stretch, or a tile whose
    /// frame, is out of proportion goes (W-20).
    private func placeOutgoing(_ viewport: MapViewport, size: CGSize) {
        guard !outgoing.isEmpty else { return }
        var maps: [NatureFogScale: Mapping?] = [:]
        var kept: [HeldTile] = []
        var rejected = 0
        for held in outgoing {
            let map = maps[held.scale] ?? Self.acceptedMapping(viewport, size: size, scale: held.scale)
            maps[held.scale] = map
            let frame = map.map { CGRect(origin: $0.screen(NatureFogTileBook.area(of: held.key).origin),
                                         size: CGSize(width: NatureFogTileBook.tileSize * $0.stretchX,
                                                      height: NatureFogTileBook.tileSize * $0.stretchY)) }
            guard let map, let frame, WorldLayerGuard.accepts(frame, in: size) else {
                rejected += 1
                held.layers.container.removeFromSuperlayer()
                continue
            }
            held.layers.container.position = frame.origin
            held.layers.container.transform = CATransform3DMakeScale(map.stretchX, map.stretchY, 1)
            kept.append(held)
        }
        rejections.note(rejected == 0, at: .fogTile)
        outgoing = kept
        outgoingFrames = kept.map(\.layers.container.frame)
    }

    /// Where tile space at `scale` falls on screen, if its stretch passes ``WorldLayerGuard`` (W-20).
    private static func acceptedMapping(_ viewport: MapViewport, size: CGSize, scale: NatureFogScale) -> Mapping? {
        let map = mapping(viewport, size: size, scale: scale)
        return WorldLayerGuard.accepts(stretchX: map.stretchX, stretchY: map.stretchY) ? map : nil
    }

    /// A waiting tile's look until its picture arrives, never wild fog over the person's own ground (the
    /// owner's zoom on the phone, 2026-10-30): nothing where the outgoing tiles cover all of it; the map where
    /// its ground is uncovered; wild fog (``NatureFogTileBook/placeholder(for:)``, the fog's colour until that's
    /// drawn) where it's fogged; and a tile with both is cut to its fogged hexes (``fogMask(_:book:)``, built
    /// once), or at very small hexes shows whichever covers most of it.
    private func cover(_ container: CALayer, key: NatureTileKey, at frame: CGRect, book: NatureFogTileBook) {
        guard !isCovered(frame) else { return look(container, key: key, fogged: false, book: book) }
        let clear = Self.clearSamples(key, book: book)
        guard clear < 15 else { return look(container, key: key, fogged: false, book: book) }
        guard clear > 1 else {
            container.mask = nil
            return look(container, key: key, fogged: true, book: book)
        }
        if container.mask == nil { container.mask = Self.fogMask(key, book: book) }
        look(container, key: key, fogged: container.mask != nil || clear < 8, book: book)
    }

    /// Shows wild fog over `container`, or nothing (the map, or the outgoing tiles under it).
    private func look(_ container: CALayer, key: NatureTileKey, fogged: Bool, book: NatureFogTileBook) {
        if fogged {
            showsMap.remove(key)
        } else {
            showsMap.insert(key)
            container.mask = nil
        }
        container.backgroundColor = fogged ? book.placeholderColour(for: key) : nil
        container.contents = fogged ? book.placeholder(for: key) : nil
    }

    /// The tile at `key`'s fogged hexes as a mask in its own points; nil at hexes under 5 pt (too many to
    /// cut on the main thread).
    private static func fogMask(_ key: NatureTileKey, book: NatureFogTileBook) -> CALayer? {
        let radius = book.scale.radius
        guard radius >= 5 else { return nil }
        let area = NatureFogTileBook.area(of: key)
        let grower = NatureFogGrower(scale: book.scale, clearing: book.clearing, atlas: book.atlas)
        let path = CGMutablePath()
        for cell in grower.cells(in: area.insetBy(dx: -radius, dy: -radius)) where !book.clearing.isClear(cell) {
            let centre = book.scale.centre(of: cell)
            path.addPath(NatureFogDrawer.hexPath(CGPoint(x: centre.x - area.minX, y: centre.y - area.minY), radius: radius))
        }
        let mask = CAShapeLayer()
        mask.frame = CGRect(x: 0, y: 0, width: NatureFogTileBook.tileSize, height: NatureFogTileBook.tileSize)
        mask.path = path
        mask.fillColor = UIColor.black.cgColor
        return mask
    }

    /// Whether the outgoing tiles cover all of `frame`: its corners and middle each under one of them, so a
    /// gap between them never shows the bare map.
    private func isCovered(_ frame: CGRect) -> Bool {
        let inset = frame.insetBy(dx: 1, dy: 1)
        let probes = [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                      CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY),
                      CGPoint(x: inset.midX, y: inset.midY)]
        return !outgoingFrames.isEmpty && probes.allSatisfy { probe in outgoingFrames.contains { $0.contains(probe) } }
    }

    /// How many of 16 points spread over the tile at `key` fall on uncovered cells.
    private static func clearSamples(_ key: NatureTileKey, book: NatureFogTileBook) -> Int {
        let area = NatureFogTileBook.area(of: key), perUnit = book.scale.pointsPerUnit
        guard perUnit > 0 else { return 0 }
        var clear = 0
        for column in 0..<4 {
            for row in 0..<4 {
                let x = area.minX + (Double(column) + 0.5) * area.width / 4, y = area.minY + (Double(row) + 0.5) * area.height / 4
                if book.clearing.isClear(MercatorHexGrid.cell(x: x / perUnit, y: y / perUnit)) { clear += 1 }
            }
        }
        return clear
    }

    /// After a zoom step: the drawn tiles, and the ring round the screen the old book had drawn (so a zoom out
    /// finds its edges drawn too), join the outgoing ones, newest on top, at most ``outgoingLimit`` (the oldest
    /// scale's go first); the ones still waiting go.
    private func keepOutgoing(scale: NatureFogScale) {
        let drawn = shown.filter { !waiting.contains($0.key) }.map { HeldTile(scale: scale, key: $0.key, layers: $0.value) }
        for key in waiting { shown[key]?.container.removeFromSuperlayer() }
        outgoing = drawn + heldRing(scale: scale) + outgoing
        for held in outgoing.dropFirst(Self.outgoingLimit) { held.layers.container.removeFromSuperlayer() }
        outgoing = Array(outgoing.prefix(Self.outgoingLimit))
        outgoingFrames = []
        shown.removeAll()
        waiting.removeAll()
        showsMap.removeAll()
        redrawing.removeAll()
    }

    /// The old book's drawn tiles in the ring one tile round the last screen, not on screen, as held layers.
    private func heldRing(scale: NatureFogScale) -> [HeldTile] {
        guard let book, let box = lastVisible else { return [] }
        let ring = book.cachedKeys.filter { key in
            shown[key] == nil && (box.low.x - 1...box.high.x + 1).contains(key.x) && (box.low.y - 1...box.high.y + 1).contains(key.y)
        }
        return ring.compactMap { key in
            guard let tile = book.cached(key) else { return nil }
            let container = CALayer()
            container.anchorPoint = .zero
            container.bounds = CGRect(x: 0, y: 0, width: NatureFogTileBook.tileSize, height: NatureFogTileBook.tileSize)
            container.masksToBounds = true
            let swaying = fill(container, with: tile)
            layer.insertSublayer(container, below: effects)
            return HeldTile(scale: scale, key: key, layers: TileLayers(container: container, swaying: swaying, trees: tile.trees))
        }
    }

    /// The layers for the tile at `key`, swaying already if the field is: its picture on top if the book has
    /// it, else a placeholder under everything (under the outgoing tiles too) until the picture arrives;
    /// ``place(_:size:)`` gives it the fog's colour.
    private func build(_ key: NatureTileKey, from book: NatureFogTileBook) -> TileLayers {
        let container = CALayer()
        container.anchorPoint = .zero
        container.bounds = CGRect(x: 0, y: 0, width: NatureFogTileBook.tileSize, height: NatureFogTileBook.tileSize)
        container.masksToBounds = true
        var layers = TileLayers(container: container, swaying: [], trees: [])
        if let tile = book.cached(key) {
            layers.swaying = fill(container, with: tile)
            layers.trees = tile.trees
            layer.insertSublayer(container, below: effects)
        } else {
            waiting.insert(key)
            layer.insertSublayer(container, at: 0)
        }
        if isSwaying { startSway(layers.swaying) }
        return layers
    }

    /// A tile's picture arrived: it replaces the fog's colour, or the old picture (crossfading after a small
    /// clearing, its lifted trees' leaves scattering). Layers only, never SwiftUI state (W-15). A ring tile off
    /// screen only counts towards the still map drawing its neighbours.
    private func arrived(_ tile: NatureFogTile) {
        guard var layers = shown[tile.key] else { return drawNeighbours() }
        let fades = redrawing.removeValue(forKey: tile.key) ?? false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A placeholder sat under everything; its picture goes on top.
        if waiting.remove(tile.key) != nil { layer.insertSublayer(layers.container, below: effects) }
        if fades { layers.container.add(NatureFogMotion.clearing(), forKey: Self.clearKey) }
        let lifted = layers.trees.filter { !tile.trees.contains($0) }
        layers.swaying = fill(layers.container, with: tile)
        layers.trees = tile.trees
        if isSwaying { startSway(layers.swaying) }
        shown[tile.key] = layers
        if fades { scatterLeaves(of: lifted) }
        showsMap.remove(tile.key)
        if waiting.isEmpty { dropOutgoing() }
        onTileArrived?()
        CATransaction.commit()
        drawNeighbours()
    }

    /// Puts `tile`'s picture and sprites into `container` in depth order, replacing what was there; returns
    /// the sprites that sway. Only the pieces that reach the tile get a sprite (W-20).
    private func fill(_ container: CALayer, with tile: NatureFogTile) -> [(layer: CALayer, group: Int)] {
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        container.backgroundColor = nil
        container.contents = nil
        container.mask = nil
        let ground = CALayer()
        ground.frame = container.bounds
        ground.contents = tile.ground
        container.addSublayer(ground)
        guard let book else { return [] }
        let culled = NatureFogTileBook.visible(tile.pieces, in: tile.key)
        rejections.note(culled.rejected == 0, at: .fogPiece)
        var swaying: [(layer: CALayer, group: Int)] = []
        for (piece, frame) in culled.kept {
            guard let sprite = book.atlas.sprite(piece.sprite, look: piece.look) else { continue }
            let sprout = CALayer()
            sprout.contents = sprite.image
            sprout.magnificationFilter = .nearest
            sprout.frame = frame
            container.addSublayer(sprout)
            if let group = piece.swayGroup { swaying.append((sprout, group)) }
        }
        return swaying
    }

    private func dropAll() {
        spareBooks.removeAll()
        for tile in shown.values { tile.container.removeFromSuperlayer() }
        shown.removeAll()
        waiting.removeAll()
        showsMap.removeAll()
        redrawing.removeAll()
        dropOutgoing()
    }

    private func dropOutgoing() {
        for held in outgoing { held.layers.container.removeFromSuperlayer() }
        outgoing.removeAll()
        outgoingFrames = []
    }

    /// A tile that left the screen.
    private func forget(_ key: NatureTileKey) {
        shown[key] = nil
        showsMap.remove(key)
        waiting.remove(key)
        redrawing[key] = nil
    }
}

extension NatureFogMapView {
    /// How many sprites sway now.
    var swayingSpriteCount: Int {
        shown.values.reduce(0) { total, tile in
            total + tile.swaying.filter { $0.layer.animation(forKey: Self.swayKey) != nil }.count
        }
    }

    /// How many blades and leaves are in flight or waiting to be swept.
    var scatteringCount: Int { effects.sublayers?.count ?? 0 }

    /// How many tiles are on screen.
    var shownTileCount: Int { shown.count }

    /// How many tiles on screen still wait for their picture.
    var waitingTileCount: Int { waiting.count }

    /// How many tiles the book holds ready (the screen's and the ring's).
    var cachedTileCount: Int { book?.cachedKeys.count ?? 0 }

    /// Whether a glide's end has the first claim on the painters now.
    var isGliding: Bool { heading?.gliding ?? false }

    /// How many scales the map left are kept, and their tiles.
    var spareTileCounts: [Int] { spareBooks.map(\.cachedKeys.count) }

    /// The share of the screen, sampled on a 12 × 24 grid, where the fog shows nothing of its own: no drawn
    /// tile, no outgoing tile and no fog-coloured placeholder, so the bare map shows where fog may belong (tests).
    var bareScreenShare: Double {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return 0 }
        let covering = shown.filter { !waiting.contains($0.key) || $0.value.container.backgroundColor != nil || showsMap.contains($0.key) }
            .map(\.value.container.frame)
            + outgoingFrames
        var bare = 0
        for column in 0..<12 {
            for row in 0..<24 {
                let point = CGPoint(x: (Double(column) + 0.5) * size.width / 12, y: (Double(row) + 0.5) * size.height / 24)
                if !covering.contains(where: { $0.contains(point) }) { bare += 1 }
            }
        }
        return Double(bare) / (12 * 24)
    }

    /// The share of the screen, sampled the same way, showing a fog-coloured placeholder (tests).
    var placeholderScreenShare: Double {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return 0 }
        let coloured = shown.filter { waiting.contains($0.key) && $0.value.container.backgroundColor != nil }.map(\.value.container.frame)
        var count = 0
        for column in 0..<12 {
            for row in 0..<24 {
                let point = CGPoint(x: (Double(column) + 0.5) * size.width / 12, y: (Double(row) + 0.5) * size.height / 24)
                if coloured.contains(where: { $0.contains(point) }) { count += 1 }
            }
        }
        return Double(count) / (12 * 24)
    }

    /// Waits until the scales either side have drawn the screen (tests).
    func finishDrawingNeighbours() async {
        for spare in spareBooks { await spare.finishDrawing() }
    }

    /// How many waiting tiles show wild fog cut to their fogged hexes (tests).
    var maskedPlaceholderCount: Int { waiting.filter { shown[$0]?.container.mask != nil }.count }

    /// How many waiting tiles show the map because most of their ground is uncovered (tests).
    var mapShowingPlaceholderCount: Int { showsMap.intersection(waiting).count }

    /// The tiles each spare scale holds ready, by radius (tests).
    var spareScales: [Double: Int] {
        Dictionary(spareBooks.map { ($0.scale.radius, $0.cachedKeys.count) }, uniquingKeysWith: max)
    }

    /// How many waiting tiles show the wild-fog placeholder rather than a flat colour (tests).
    var texturedPlaceholderCount: Int {
        waiting.filter { shown[$0]?.container.contents != nil }.count
    }

    /// The radius of the scale the fog's tiles are drawn at now (tests).
    var tileScaleRadius: Double? { book?.scale.radius }

    /// How many of the last scale's tiles are still on screen after a zoom step.
    var outgoingTileCount: Int { outgoing.count }

    /// Waits until every tile asked for has drawn and arrived (tests).
    func finishDrawing() async {
        await book?.finishDrawing()
    }

    /// How many tiles are crossfading after a clearing.
    var fadingTileCount: Int { shown.values.filter { $0.container.animation(forKey: Self.clearKey) != nil }.count }

    /// Pauses the sway while the map moves, and arranges for it to resume once the map sits still.
    private func noteMovement(_ viewport: MapViewport, motion: NatureFogMotion) {
        if !motion.sways { setSway(false) }
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        lastMove = CACurrentMediaTime()
        isSettled = false
        setSway(false)
        scheduleSettle()
    }

    private func scheduleSettle() {
        guard !settlePending else { return }
        settlePending = true
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(NatureFogMotion.settleDelay))
            } catch {
                self?.settlePending = false
                return
            }
            self?.settle()
        }
    }

    /// Once the map has sat still for ``NatureFogMotion/settleDelay``: the fog takes the scale that fits
    /// exactly (held while it moved, ``holdRange``) and the sway resumes (never with Reduce Motion). Sweeps
    /// away finished blades.
    func settle(now: CFTimeInterval = CACurrentMediaTime()) {
        settlePending = false
        sweepEffects()
        guard now - lastMove >= NatureFogMotion.settleDelay - 0.05 else {
            scheduleSettle()
            return
        }
        if !isSettled {
            isSettled = true
            apply()
            drawNeighbours()
        }
        guard let scene, scene.motion.sways else { return }
        setSway(true)
    }

    private func setSway(_ on: Bool) {
        guard on != isSwaying else { return }
        isSwaying = on
        for tile in shown.values {
            if on {
                startSway(tile.swaying)
            } else {
                for item in tile.swaying { item.layer.removeAnimation(forKey: Self.swayKey) }
            }
        }
    }

    private func startSway(_ sprites: [(layer: CALayer, group: Int)]) {
        let phases = (0..<NatureFogMotion.staggers.count).map { NatureFogMotion.sway(group: $0) }
        for item in sprites where phases.indices.contains(item.group) {
            item.layer.add(phases[item.group], forKey: Self.swayKey)
        }
    }

    /// Marks the shown tiles a clearing reached for their new picture, which crossfades from the old one when
    /// only a few changed (``arrived(_:)``), and scatters the cleared hexes' blades now (not with Reduce Motion).
    /// A change that fogs cells again blanks the reached tiles at once instead.
    private func refresh(_ change: NatureFogChange, scene: NatureFogScene, map: Mapping) {
        guard let book else { return }
        let reached = change.dirty.filter { shown[$0] != nil && !waiting.contains($0) }
        guard !change.covers else {
            for key in reached { blank(key, book: book) }
            return
        }
        let animate = reached.count <= 12
        for key in reached { redrawing[key] = animate }
        guard animate, scene.motion.scatters else { return }
        sweepEffects()
        let unit = book.scale.unit * map.stretchX, reach = book.scale.radius * map.stretchX
        let tallest = CGRect(x: 0, y: 0, width: unit, height: unit * 2)
        guard rejections.note(reach.isFinite && WorldLayerGuard.accepts(tallest, in: bounds.size), at: .fogBlade) else { return }
        let blades = [scene.palette.color(.bladeLight), scene.palette.color(.bladeMid)]
        for cell in change.cleared.prefix(NatureFogMotion.maxScattering) {
            let at = NatureFogRules.offset(of: cell), kind = NatureFogRules.ground(at.col, at.row)
            burst(at: map.screen(book.scale.centre(of: cell)), count: kind == .long || kind == .flowers ? 8 : 6,
                  colors: blades, unit: unit, reach: reach)
        }
    }

    /// Puts the shown tile at `key` back to a placeholder until its new picture arrives.
    private func blank(_ key: NatureTileKey, book: NatureFogTileBook) {
        guard var layers = shown[key] else { return }
        layers.container.sublayers?.forEach { $0.removeFromSuperlayer() }
        layers.container.backgroundColor = book.placeholderColour(for: key)
        layers.container.contents = book.placeholder(for: key)
        layers.swaying = []
        layers.trees = []
        shown[key] = layers
        redrawing[key] = nil
        waiting.insert(key)
    }

    /// The leaves of `trees` (lifted by a clearing) scatter where they stand now (not with Reduce Motion).
    private func scatterLeaves(of trees: [NatureStandingTree]) {
        guard !trees.isEmpty, let scene, scene.motion.scatters, let book, let map = lastMap else { return }
        let unit = book.scale.unit * map.stretchX, reach = book.scale.radius * map.stretchX
        let tallest = CGRect(x: 0, y: 0, width: unit, height: unit * 2)
        guard rejections.note(reach.isFinite && WorldLayerGuard.accepts(tallest, in: bounds.size), at: .fogBlade) else { return }
        let leaves = [scene.palette.color(.leafLight), scene.palette.color(.leafMid), scene.palette.color(.leafHighlight)]
        for tree in trees.prefix(NatureFogMotion.maxScattering) {
            burst(at: map.screen(tree.canopy), count: 8, colors: leaves, unit: unit, reach: reach * 1.4)
        }
    }

    /// 6–8 blades (or leaves) flying out about one hex from `point` while they fade.
    private func burst(at point: CGPoint, count: Int, colors: [CGColor], unit: Double, reach: Double) {
        guard !colors.isEmpty, bounds.insetBy(dx: -reach, dy: -reach).contains(point) else { return }
        for (index, flight) in NatureFogMotion.flights.prefix(count).enumerated() {
            let blade = CALayer()
            blade.backgroundColor = colors[index % colors.count]
            blade.bounds = CGRect(x: 0, y: 0, width: unit, height: index % 3 == 0 ? unit * 2 : unit)
            blade.position = point
            blade.opacity = 0
            blade.add(NatureFogMotion.flight(from: point, by: CGPoint(x: flight.x * reach, y: flight.y * reach)), forKey: Self.scatterKey)
            effects.addSublayer(blade)
        }
    }

    /// Removes blades whose flight has ended.
    private func sweepEffects() {
        let landed = (effects.sublayers ?? []).filter { $0.animation(forKey: Self.scatterKey) == nil }
        for blade in landed { blade.removeFromSuperlayer() }
    }
}

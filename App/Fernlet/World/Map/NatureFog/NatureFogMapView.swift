import SwiftUI
import UIKit
import WorldMapStore

/// What the fog layer shows: where the map looks, what's uncovered, its colours and the motion setting.
struct NatureFogScene {
    let viewport: MapViewport
    let clearing: NatureFogClearing
    let palette: NatureFogPalette
    let motion: NatureFogMotion
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
    /// The last scale's tiles after a zoom step, moved with the map until the new scale's are all in.
    private var outgoing: [NatureTileKey: TileLayers] = [:]
    private var outgoingScale: NatureFogScale?
    /// Where the outgoing tiles cover the screen now; a waiting tile wholly inside shows them, not the fog's colour.
    private var outgoingBounds: CGRect?
    private var lastMap: Mapping?
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
        guard let scale = NatureFogScale.tiles(forScreenRadius: MercatorHexGrid.radius * viewport.pointsPerUnit(in: size)) else {
            dropAll()
            book = nil
            return
        }
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

    /// Where tile space at `scale` falls on screen for `viewport`.
    private static func mapping(_ viewport: MapViewport, size: CGSize, scale: NatureFogScale) -> Mapping {
        let perUnit = scale.pointsPerUnit
        return Mapping(originX: viewport.minX * perUnit, originY: viewport.minY * perUnit,
                       stretchX: Double(size.width) / viewport.width / perUnit, stretchY: Double(size.height) / viewport.height / perUnit)
    }

    /// Matches the book to the scene: a new clearing dirties tiles. A new scale or palette starts a new book,
    /// the old tiles staying on screen until the new ones are in, unless the clearing changed with it (then
    /// they go at once, so a decoy session never shows the history even for a moment).
    private func sync(scale: NatureFogScale, scene: NatureFogScene) -> NatureFogChange? {
        if let book, book.scale == scale, book.palette == scene.palette {
            let change = book.change(to: scene.clearing)
            if change.reset { dropAll() }
            // Fog coming back: the old scale's tiles were drawn from the history and go at once.
            if change.covers { dropOutgoing() }
            return change.reset || change.dirty.isEmpty ? nil : change
        }
        if let book, book.clearing == scene.clearing { keepOutgoing(scale: book.scale) } else { dropAll() }
        let next = NatureFogTileBook(scale: scale, palette: scene.palette, clearing: scene.clearing,
                                     pixelScale: min(traitCollection.displayScale, 2))
        next.onReady = { [weak self] tile in self?.arrived(tile) }
        book = next
        lastCentre = nil
        return nil
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
            if waiting.contains(key) { layers.container.backgroundColor = placeholderColor(covering: frame, book: book) }
            layers.container.position = corner
            layers.container.transform = CATransform3DMakeScale(map.stretchX, map.stretchY, 1)
        }
        rejections.note(rejected == 0, at: .fogTile)
        prefetch(low: low, high: high, map: map, size: size, book: book)
    }

    /// Asks for the screen's tiles and the ring round them, reaching further the way the map is moving
    /// (``NatureFogRing``), and lets the farthest cached tiles go.
    private func prefetch(low: NatureTileKey, high: NatureTileKey, map: Mapping, size: CGSize, book: NatureFogTileBook) {
        let centre = CGPoint(x: (map.originX + Double(size.width) / map.stretchX / 2) / NatureFogTileBook.tileSize,
                             y: (map.originY + Double(size.height) / map.stretchY / 2) / NatureFogTileBook.tileSize)
        let motion = lastCentre.map { CGVector(dx: centre.x - $0.x, dy: centre.y - $0.y) } ?? .zero
        lastCentre = centre
        let ring = NatureFogRing.keys(low: low, high: high, centre: centre, motion: motion, limit: NatureFogTileBook.cacheLimit)
        book.want(ring)
        book.evict(around: centre, keeping: Set(ring))
        if waiting.isEmpty { dropOutgoing() }
    }

    /// Moves the old scale's tiles with the map; a stretch or a frame out of proportion drops them (W-20).
    private func placeOutgoing(_ viewport: MapViewport, size: CGSize) {
        guard let old = outgoingScale, !outgoing.isEmpty else { return }
        let map = Self.mapping(viewport, size: size, scale: old)
        guard rejections.note(WorldLayerGuard.accepts(stretchX: map.stretchX, stretchY: map.stretchY), at: .fogStretch) else {
            dropOutgoing()
            return
        }
        let side = CGSize(width: NatureFogTileBook.tileSize * map.stretchX, height: NatureFogTileBook.tileSize * map.stretchY)
        var rejected = 0
        for (key, tile) in outgoing {
            let corner = map.screen(NatureFogTileBook.area(of: key).origin)
            guard WorldLayerGuard.accepts(CGRect(origin: corner, size: side), in: size) else {
                rejected += 1
                tile.container.removeFromSuperlayer()
                outgoing[key] = nil
                continue
            }
            tile.container.position = corner
            tile.container.transform = CATransform3DMakeScale(map.stretchX, map.stretchY, 1)
        }
        rejections.note(rejected == 0, at: .fogTile)
        outgoingBounds = outgoing.values.reduce(nil) { bounds, tile in bounds?.union(tile.container.frame) ?? tile.container.frame }
    }

    /// The fog's colour for a waiting tile at `frame` on screen; none where the outgoing tiles cover all of it.
    private func placeholderColor(covering frame: CGRect, book: NatureFogTileBook) -> CGColor? {
        outgoingBounds?.contains(frame) == true ? nil : book.palette.color(.grassB)
    }

    /// After a zoom step: the drawn tiles stay as the outgoing ones (only one scale's worth is ever kept); the
    /// ones still waiting go.
    private func keepOutgoing(scale: NatureFogScale) {
        if outgoing.isEmpty {
            outgoing = shown.filter { !waiting.contains($0.key) }
            outgoingScale = scale
            for key in waiting { shown[key]?.container.removeFromSuperlayer() }
        } else {
            for tile in shown.values { tile.container.removeFromSuperlayer() }
        }
        shown.removeAll()
        waiting.removeAll()
        redrawing.removeAll()
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
    /// clearing, its lifted trees' leaves scattering). Layers only, never SwiftUI state (W-15).
    private func arrived(_ tile: NatureFogTile) {
        guard var layers = shown[tile.key] else { return }
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
        if waiting.isEmpty { dropOutgoing() }
        onTileArrived?()
        CATransaction.commit()
    }

    /// Puts `tile`'s picture and sprites into `container` in depth order, replacing what was there; returns
    /// the sprites that sway. Only the pieces that reach the tile get a sprite (W-20).
    private func fill(_ container: CALayer, with tile: NatureFogTile) -> [(layer: CALayer, group: Int)] {
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        container.backgroundColor = nil
        let ground = CALayer()
        ground.frame = container.bounds
        ground.contents = tile.ground
        container.addSublayer(ground)
        guard let book else { return [] }
        let culled = NatureFogTileBook.visible(tile.pieces, in: tile.key)
        rejections.note(culled.rejected == 0, at: .fogPiece)
        var swaying: [(layer: CALayer, group: Int)] = []
        for (piece, frame) in culled.kept {
            guard let sprite = book.atlas.sprite(piece.sprite) else { continue }
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
        for tile in shown.values { tile.container.removeFromSuperlayer() }
        shown.removeAll()
        waiting.removeAll()
        redrawing.removeAll()
        dropOutgoing()
    }

    private func dropOutgoing() {
        for tile in outgoing.values { tile.container.removeFromSuperlayer() }
        outgoing.removeAll()
        outgoingScale = nil
        outgoingBounds = nil
    }

    /// A tile that left the screen.
    private func forget(_ key: NatureTileKey) {
        shown[key] = nil
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

    /// Resumes the sway once the map has sat still for ``NatureFogMotion/settleDelay`` (never with Reduce
    /// Motion), and sweeps away finished blades.
    func settle(now: CFTimeInterval = CACurrentMediaTime()) {
        settlePending = false
        sweepEffects()
        guard let scene, scene.motion.sways else { return }
        guard now - lastMove >= NatureFogMotion.settleDelay - 0.05 else {
            scheduleSettle()
            return
        }
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
        layers.container.backgroundColor = book.palette.color(.grassB)
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

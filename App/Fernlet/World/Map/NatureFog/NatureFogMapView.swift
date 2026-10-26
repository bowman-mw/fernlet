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
    private let effects = CALayer()
    private var lastViewport: MapViewport?
    private var lastMove: CFTimeInterval = 0
    private var settlePending = false
    /// Writes the audit line when a computed frame is refused (W-20).
    private let rejections = WorldLayerRejections()
    /// Whether grass and flowers sway now.
    private(set) var isSwaying = false

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
        let perUnit = scale.pointsPerUnit
        let map = Mapping(originX: viewport.minX * perUnit, originY: viewport.minY * perUnit,
                          stretchX: Double(size.width) / viewport.width / perUnit, stretchY: Double(size.height) / viewport.height / perUnit)
        // W-20: a stretch out of proportion (a skewed viewport, a size mid-change) drops this frame; the tiles
        // keep the last good one.
        guard rejections.note(WorldLayerGuard.accepts(stretchX: map.stretchX, stretchY: map.stretchY), at: .fogStretch) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let change = sync(scale: scale, scene: scene)
        noteMovement(viewport, motion: scene.motion)
        if let change { refresh(change, scene: scene, map: map) }
        place(map, size: size)
        CATransaction.commit()
    }

    /// Matches the book to the scene: a new scale or palette starts afresh; a new clearing dirties tiles.
    private func sync(scale: NatureFogScale, scene: NatureFogScene) -> NatureFogChange? {
        if let book, book.scale == scale, book.palette == scene.palette {
            let change = book.change(to: scene.clearing)
            if change.reset { dropAll() }
            return change.reset || change.dirty.isEmpty ? nil : change
        }
        dropAll()
        book = NatureFogTileBook(scale: scale, palette: scene.palette, clearing: scene.clearing,
                                 pixelScale: min(traitCollection.displayScale, 2))
        return nil
    }

    /// Shows the tiles on screen (only the ones the visible rect reaches) and drops the ones that left it. A
    /// tile whose frame fails ``WorldLayerGuard`` keeps its last good one, or isn't built (W-20).
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
            shown[key] = nil
        }
        let side = CGSize(width: NatureFogTileBook.tileSize * map.stretchX, height: NatureFogTileBook.tileSize * map.stretchY)
        var rejected = 0
        for key in visible {
            let corner = map.screen(NatureFogTileBook.area(of: key).origin)
            guard WorldLayerGuard.accepts(CGRect(origin: corner, size: side), in: size) else {
                rejected += 1
                continue
            }
            let layers = shown[key] ?? build(book.tile(key))
            shown[key] = layers
            layers.container.position = corner
            layers.container.transform = CATransform3DMakeScale(map.stretchX, map.stretchY, 1)
        }
        rejections.note(rejected == 0, at: .fogTile)
        book.evict(keeping: visible)
    }

    /// A tile's layers, swaying already if the field is.
    private func build(_ tile: NatureFogTile) -> TileLayers {
        let container = CALayer()
        container.anchorPoint = .zero
        container.bounds = CGRect(x: 0, y: 0, width: NatureFogTileBook.tileSize, height: NatureFogTileBook.tileSize)
        container.masksToBounds = true
        let layers = TileLayers(container: container, swaying: fill(container, with: tile), trees: tile.trees)
        layer.insertSublayer(container, below: effects)
        if isSwaying { startSway(layers.swaying) }
        return layers
    }

    /// Puts `tile`'s picture and sprites into `container` in depth order, replacing what was there; returns
    /// the sprites that sway. Only the pieces that reach the tile get a sprite (W-20).
    private func fill(_ container: CALayer, with tile: NatureFogTile) -> [(layer: CALayer, group: Int)] {
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
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

    /// Redraws the tiles a clearing reached: each crossfades from its old picture (when only a few changed),
    /// and the cleared hexes' blades and the lifted trees' leaves scatter (not with Reduce Motion).
    private func refresh(_ change: NatureFogChange, scene: NatureFogScene, map: Mapping) {
        guard let book else { return }
        let animate = change.dirty.count <= 12
        var lifted = Set<NatureStandingTree>()
        for key in change.dirty {
            guard var layers = shown[key] else { continue }
            let tile = book.tile(key)
            if animate { layers.container.add(NatureFogMotion.clearing(), forKey: Self.clearKey) }
            lifted.formUnion(layers.trees.filter { !tile.trees.contains($0) })
            layers.swaying = fill(layers.container, with: tile)
            layers.trees = tile.trees
            if isSwaying { startSway(layers.swaying) }
            shown[key] = layers
        }
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
        let leaves = [scene.palette.color(.leafLight), scene.palette.color(.leafMid), scene.palette.color(.leafHighlight)]
        for tree in lifted.prefix(NatureFogMotion.maxScattering) {
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

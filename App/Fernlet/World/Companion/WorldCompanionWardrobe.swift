import Foundation
import FernletDomainModel

extension WorldCompanionLook {
    /// The look for `appearance` on a day in `state`, wearing `items` (Creation Studio pieces, each
    /// shrunk to its box when it was drawn bigger, ``WorldItemBox``). `asleep` wears the night's
    /// neutral body colour where the body follows the state, as Home's companion does while it sleeps.
    ///
    /// Colours resolve the way the widget's look does (`WidgetSnapshot.CompanionLook.hex`), so the map,
    /// the close-up and the widget agree: a slot left on Fern keeps the sprout's fern, the flower's soft
    /// rose and the glasses' ink; the scarf follows the state in red, the sleep cap in night blue and a
    /// side item in bark. Main actor: the named colours resolve through the app's colour assets.
    @MainActor
    init(appearance: CompanionAppearance, state: CompanionState, asleep: Bool, items: [CustomizationItem] = []) {
        let named = { (custom: String?, slot: CompanionAssetColor) -> UInt32? in
            Self.value(WidgetSnapshot.CompanionLook.hex(custom: custom, slot: slot))
        }
        let fixedBody = named(appearance.bodyCustomColorHex, appearance.bodyColor)
        let accessory = named(appearance.accessoryCustomColorHex, appearance.accessoryColor)
        let clothing = named(appearance.clothingCustomColorHex, appearance.clothingColor)
        self.init(body: fixedBody ?? (asleep ? Self.nightBody : Self.stateHex(state)),
                  shape: WorldCompanionShape(appearance.bodyStyle),
                  topper: WorldCompanionTopper(appearance.accessory),
                  topperColor: Self.topperColor(accessory),
                  scarf: appearance.clothing == .scarf ? (clothing ?? Self.scarfRed) : nil,
                  cap: appearance.clothing == .sleepCap ? (clothing ?? Self.capBlue) : nil,
                  side: WorldCompanionSide(appearance.sideItem),
                  sideColor: named(appearance.sideItemCustomColorHex, appearance.sideItemColor) ?? Self.bark,
                  items: WorldItemBox.art(for: items))
    }

    /// The topper's colour for a resolved accessory colour: nil when it is the fern every slot starts
    /// on (or follows the state), so the sprout stays fern, the flower soft rose and the glasses ink.
    /// The widget reads the same rule off the same `#72A364`.
    static func topperColor(_ accessory: UInt32?) -> UInt32? {
        accessory == leaf ? nil : accessory
    }
}

extension WorldCompanionShape {
    /// The pixel shape for a body style.
    init(_ style: CompanionBodyStyle) {
        switch style {
        case .circle: self = .circle
        case .softBlob: self = .soft
        case .pear: self = .pear
        case .puddle: self = .puddle
        }
    }
}

extension WorldCompanionTopper {
    /// The pixel topper for an accessory.
    init(_ accessory: CompanionAccessory) {
        switch accessory {
        case .none: self = .none
        case .sprout: self = .sprout
        case .flower: self = .flower
        case .glasses: self = .glasses
        }
    }
}

extension WorldCompanionSide {
    /// The pixel side item for a side item.
    init(_ item: CompanionSideItem) {
        switch item {
        case .none: self = .none
        case .waterBottle: self = .bottle
        case .mug: self = .mug
        case .book: self = .book
        case .dumbbell: self = .dumbbell
        }
    }
}

/// Where each kind of Creation Studio piece sits on the companion (W-07, draft 2, approved by the owner
/// on 2026-10-25), in body coordinates, one square to one sprite pixel: Hat 18 × 11 at (1, −1), Face
/// 16 × 8 at (2, 9), Outfit 18 × 13 at (1, 10), Held item 10 × 12 at (12, 10). They reach past the
/// 20 × 22 body into the 24 × 24 item frame; nothing draws outside it.
///
/// New pieces are drawn at their box's size and worn 1:1. A piece drawn bigger (made before, or bought
/// from a friend on the old Fernlet, whose canvases were 32 × 24, 36 × 16, 48 × 40 and 28 × 28) is
/// shrunk to fit automatically: one scale for both axes, each new square taking the most common colour
/// of the squares it covers when at least a third of them are painted. The stored texture and the wire
/// format never change; the shrinking happens where the piece is drawn.
nonisolated enum WorldItemBox {
    /// A box: its top-left cell in body coordinates and its size in sprite pixels.
    struct Box: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The box for a kind of piece.
    static func box(for slot: ItemSlot) -> Box {
        switch slot {
        case .hat: Box(x: 1, y: -1, width: 18, height: 11)
        case .face: Box(x: 2, y: 9, width: 16, height: 8)
        case .body: Box(x: 1, y: 10, width: 18, height: 13)
        case .heldItem: Box(x: 12, y: 10, width: 10, height: 12)
        }
    }

    /// The order pieces are painted in, back to front: the outfit under a held item, the face piece,
    /// then the hat (as the full companion stacks them).
    static func paintOrder(_ slot: ItemSlot) -> Int {
        switch slot {
        case .body: 1
        case .heldItem: 2
        case .face: 3
        case .hat: 4
        }
    }

    /// Every piece's art in its place, in paint order; a piece with nothing to draw is left out.
    static func art(for items: [CustomizationItem]) -> [WorldCompanionItemArt] {
        items.sorted { paintOrder($0.slot) < paintOrder($1.slot) }.compactMap(art(for:))
    }

    /// One piece's art in its place, shrunk to its box when drawn bigger; nil when it has nothing to draw.
    static func art(for item: CustomizationItem) -> WorldCompanionItemArt? {
        let fitted = fit(item.texture, slot: item.slot)
        let colours = item.texture.palette.map(colour(_:))
        let cells: [UInt32?] = fitted.indices.map { index in
            index >= 0 && index < colours.count ? colours[index] : nil
        }
        guard cells.contains(where: { $0 != nil }) else { return nil }
        return WorldCompanionItemArt(x: fitted.x, y: fitted.y, width: fitted.width, height: fitted.height,
                                     cells: cells, coversHead: item.slot == .hat)
    }

    /// A texture fitted to `slot`'s box: its palette indices (−1 clear), its size and its place.
    struct Fitted: Equatable, Sendable {
        /// The left column, in body coordinates.
        let x: Int
        /// The top row, in body coordinates.
        let y: Int
        let width: Int
        let height: Int
        /// Row-major palette indices into the texture's palette; `ItemGridTexture.transparent` is clear.
        let indices: [Int]
    }

    /// Fits `texture` into `slot`'s box: 1:1 when it fits, else shrunk with one scale for both axes.
    /// A hat sits on the box's bottom edge (on the head), an outfit on its top edge (from the
    /// shoulders); a face piece and a held item sit in the middle. Every piece is centred across.
    static func fit(_ texture: ItemGridTexture, slot: ItemSlot) -> Fitted {
        let box = box(for: slot)
        let source = texture.sanitized()
        guard source.cols > 0, source.rows > 0, source.pixels.count == source.cols * source.rows else {
            return Fitted(x: box.x, y: box.y, width: 0, height: 0, indices: [])
        }
        let scale = min(1, Double(box.width) / Double(source.cols), Double(box.height) / Double(source.rows))
        let width = min(box.width, max(1, Int((Double(source.cols) * scale).rounded())))
        let height = min(box.height, max(1, Int((Double(source.rows) * scale).rounded())))
        let indices = width == source.cols && height == source.rows
            ? source.pixels
            : shrink(source, toWidth: width, height: height)
        let x = box.x + (box.width - width) / 2
        let y: Int = switch slot {
        case .hat: box.y + box.height - height
        case .body: box.y
        case .face, .heldItem: box.y + (box.height - height) / 2
        }
        return Fitted(x: x, y: y, width: width, height: height, indices: indices)
    }

    /// Shrinks `texture` to `width × height`: each new square covers a block of old ones and takes the
    /// most common colour among them when at least a third are painted, else stays clear (ties go to the
    /// colour met first). Bounded by the sanitized texture (64 × 64 at most).
    static func shrink(_ texture: ItemGridTexture, toWidth width: Int, height: Int) -> [Int] {
        var result = [Int](repeating: ItemGridTexture.transparent, count: width * height)
        for y in 0..<height {
            let y0 = y * texture.rows / height, y1 = max(y0 + 1, (y + 1) * texture.rows / height)
            for x in 0..<width {
                let x0 = x * texture.cols / width, x1 = max(x0 + 1, (x + 1) * texture.cols / width)
                result[y * width + x] = dominant(texture, columns: x0..<x1, rows: y0..<y1)
            }
        }
        return result
    }

    /// The most common painted index in a block, when at least a third of it is painted.
    private static func dominant(_ texture: ItemGridTexture, columns: Range<Int>, rows: Range<Int>) -> Int {
        var counts: [Int: Int] = [:]
        var firstSeen: [Int] = []
        for y in rows {
            for x in columns {
                let index = texture.pixels[y * texture.cols + x]
                guard index >= 0, index < texture.palette.count else { continue }
                if counts[index] == nil { firstSeen.append(index) }
                counts[index, default: 0] += 1
            }
        }
        let painted = counts.values.reduce(0, +)
        guard painted > 0, painted * 3 >= columns.count * rows.count else { return ItemGridTexture.transparent }
        var best = ItemGridTexture.transparent, bestCount = 0
        for index in firstSeen where counts[index, default: 0] > bestCount {
            best = index
            bestCount = counts[index, default: 0]
        }
        return best
    }

    /// A palette entry (`RRGGBB`, with or without `#`) as a colour; nil when malformed.
    static func colour(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}

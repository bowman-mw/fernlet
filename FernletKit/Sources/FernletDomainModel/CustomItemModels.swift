// CustomItemModels.swift
// User-designed custom clothing & accessories (the "Animal-Crossing fabric editor" feature).
//
// These types live in the *synced* domain model — not a sealed Private* store. They carry no
// health-sensitive data and provenance is anonymized (see `ItemDesigner`), so they are wall-safe for
// AIProviders/CloudKitSync to import.
//
// Storage: items are persisted in their OWN per-row store (`CustomItemService` →
// `CustomItemRepository`, a Core Data `CustomItemRecord` entity), NOT in the settings/snapshot blob —
// so a growing closet never bloats the frequently-written character/day state and items sync row by
// row. Only the tiny equipped-slot map (`FernletSettings.equippedItemIDsBySlot`, a few UUIDs) stays in
// settings as render state. The pixel grid is palette-indexed (tiny — a 24x20 body texture is < 1 KB
// of JSON), so a single sealed proximity envelope can carry one without chunking (Increment 3).

import Foundation

// MARK: - Slot taxonomy

/// A wearable slot on the companion. Each slot has its own grid dimensions (per-slot grid sizes:
/// hats are small and wide, the body shirt is the largest canvas). On-companion *placement* is a
/// view concern and lives in the renderer, not here.
public nonisolated enum ItemSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case hat
    case face
    case body
    case heldItem

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hat: "Hat"
        case .face: "Face"
        case .body: "Outfit"
        case .heldItem: "Held item"
        }
    }

    /// Designer-canvas width in cells.
    public var gridCols: Int {
        switch self {
        case .hat: 16
        case .face: 18
        case .body: 24
        case .heldItem: 14
        }
    }

    /// Designer-canvas height in cells.
    public var gridRows: Int {
        switch self {
        case .hat: 12
        case .face: 8
        case .body: 20
        case .heldItem: 14
        }
    }

    public var systemImage: String {
        switch self {
        case .hat: "graduationcap"
        case .face: "eyeglasses"
        case .body: "tshirt"
        case .heldItem: "bag"
        }
    }
}

// MARK: - Pixel grid texture

/// A palette-indexed pixel grid. `pixels` has `cols * rows` entries in row-major order; each entry is
/// an index into `palette` (a list of 6-hex-digit `RRGGBB` strings), or `ItemGridTexture.transparent`
/// (-1) for an unpainted/transparent cell.
public nonisolated struct ItemGridTexture: Codable, Equatable, Sendable {
    public static let transparent = -1

    public var cols: Int
    public var rows: Int
    public var palette: [String]
    public var pixels: [Int]

    public init(cols: Int, rows: Int, palette: [String], pixels: [Int]) {
        self.cols = cols
        self.rows = rows
        self.palette = palette
        self.pixels = pixels
    }

    /// A fully-transparent canvas sized for `slot`.
    public static func blank(for slot: ItemSlot, palette: [String]) -> ItemGridTexture {
        ItemGridTexture(
            cols: slot.gridCols,
            rows: slot.gridRows,
            palette: palette,
            pixels: Array(repeating: transparent, count: slot.gridCols * slot.gridRows)
        )
    }

    /// True when no cell is painted (nothing would render).
    public var isBlank: Bool {
        pixels.allSatisfy { $0 < 0 || $0 >= palette.count }
    }

    /// The 6-hex color string at `(x, y)`, or nil if out of bounds / transparent.
    public func hex(x: Int, y: Int) -> String? {
        guard x >= 0, x < cols, y >= 0, y < rows else { return nil }
        let idx = pixels[y * cols + x]
        guard idx >= 0, idx < palette.count else { return nil }
        return palette[idx]
    }

    /// Most palette entries a sanitized texture may keep, and the longest a single hex string may be. A
    /// real clothing grid uses a handful of short "RRGGBB" colors; these bounds are generous for any
    /// legitimate item but stop a hostile peer from smuggling a multi-megabyte `palette` (e.g. 500k long
    /// strings) past the tiny grid-size clamps — the palette was previously copied through unbounded.
    public static let maxPaletteEntries = 4096
    public static let maxPaletteHexLength = 16

    /// Drops malformed data into a safe, render-able shape (used at the wire boundary in Increment 3):
    /// clamps dimensions, bounds the palette, resizes the pixel buffer, and coerces out-of-range indices to
    /// transparent. Cells are copied by `(x, y)` over the overlapping region so a width change keeps rows
    /// aligned (a flat index copy would bleed cells from one row into the next when `cols` shrinks).
    public func sanitized(maxCols: Int = 64, maxRows: Int = 64) -> ItemGridTexture {
        let c = max(0, min(cols, maxCols))
        let r = max(0, min(rows, maxRows))
        // Bound the untrusted palette first; indices into any dropped entry then coerce to transparent below.
        let boundedPalette = palette.prefix(ItemGridTexture.maxPaletteEntries)
            .map { String($0.prefix(ItemGridTexture.maxPaletteHexLength)) }
        var buffer = Array(repeating: ItemGridTexture.transparent, count: c * r)
        // Copy bounds must never exceed the *clamped* non-negative dims (c, r) — clamping against the raw
        // `cols`/`rows` would re-introduce a hostile negative value (e.g. rows == -1 → copyRows == -1 →
        // `0..<(-1)` traps). `cols` still strides the *source* buffer, so a hostile-huge source width
        // (e.g. Int.max) would overflow `y * cols`; we therefore advance the source row offset by *addition*
        // with overflow reporting and `break` the moment it lands past the real `pixels` buffer — every cell
        // beyond the actual data is transparent anyway. A non-positive source width leaves no valid overlap:
        // skip the copy entirely, returning the blank (clamped) grid.
        let copyCols = max(0, min(c, cols))
        let copyRows = max(0, min(r, rows))
        if cols > 0 && copyCols > 0 {
            var rowStart = 0
            for y in 0..<copyRows {
                guard rowStart < pixels.count else { break }
                let remaining = pixels.count - rowStart
                let xLimit = min(copyCols, remaining)
                for x in 0..<xLimit {
                    let idx = pixels[rowStart + x]
                    buffer[y * c + x] = (idx >= 0 && idx < boundedPalette.count) ? idx : ItemGridTexture.transparent
                }
                let (next, overflow) = rowStart.addingReportingOverflow(cols)
                if overflow { break }
                rowStart = next
            }
        }
        return ItemGridTexture(cols: c, rows: r, palette: boundedPalette, pixels: buffer)
    }
}

// MARK: - Item
// Provenance lives in `ItemDesigner` (its own file) — an anonymous designer id only.

/// A single user-designed wearable. Identity is the stable `id`; `texture`/`name` are editable. `price`
/// and `isShareable` are dormant until the shop ships (Increments 2–3).
public nonisolated struct CustomizationItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var slot: ItemSlot
    public var texture: ItemGridTexture
    public var designer: ItemDesigner
    public var createdAt: Date
    /// Whether the owner has marked this item as available in their (in-person) shop.
    public var isShareable: Bool
    /// Coin cost a buyer pays to acquire a copy. Designer-set, bounded; unused until the shop ships.
    public var price: Int

    public init(
        id: UUID = UUID(),
        name: String,
        slot: ItemSlot,
        texture: ItemGridTexture,
        designer: ItemDesigner,
        createdAt: Date = Date(),
        isShareable: Bool = false,
        price: Int = 0
    ) {
        self.id = id
        self.name = name
        self.slot = slot
        self.texture = texture
        self.designer = designer
        self.createdAt = createdAt
        self.isShareable = isShareable
        self.price = price
    }
}

// MARK: - Designer palette

/// The fixed paint palette offered in the Creation Studio. Kept in the domain model so the renderer and
/// the editor agree on the canonical color list. Earthy, on-brand tones plus primaries for expression.
public nonisolated enum ItemDesignPalette {
    public static let hexes: [String] = [
        "2E2A24", // near-black bark
        "6B5B4A", // bark
        "9C8466", // taupe
        "D8C7A8", // cream
        "F4ECDD", // parchment
        "FFFFFF", // white
        "7A8B5A", // moss
        "4C6B3C", // fern
        "C46B5A", // terracotta
        "E0A458", // sun
        "D98AA6", // rose
        "8C6FB0", // plum
        "5B7C99", // slate blue
        "3C5A6B", // deep slate
        "C0392B", // red
        "2D9C6F"  // emerald
    ]
}

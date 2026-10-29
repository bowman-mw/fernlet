// MapWidgetMono.swift
// FernletWidgets
//
// The map widget on the tinted and clear Home Screens (phone test W-11, `ref-tint-map` draft 2 and
// `ref-tint-map-light`, approved): the map is the app's one-colour drawing, and it is punched out under
// Sprout (a clear ring one pixel wider than everything it wears), the plate and the tag, so no line touches
// Sprout or runs under text, and the widget's own ground shows there.

import SwiftUI

// MARK: - Clear ring twin: begin

/// A clear ring round a pixel sprite: its painted cells dilated by one in all eight directions, diagonals
/// included (phone test W-11). The map widget punches Sprout's out of the one-colour map, so no line touches
/// Sprout or shows through its face; the one-colour picture clears a marker's, so no street runs through
/// its outline. The app and the widget each keep this copy, word for word (`WidgetMapTests` holds them equal).
enum MapClearRing {
    /// The most cells a sprite may have.
    static let maxCells = 4_096

    /// `painted` (rows top first, `width` × `height`) dilated by one cell, on a grid one cell larger on
    /// every side: (width + 2) × (height + 2), where input cell (x, y) is output cell (x + 1, y + 1). Empty
    /// for a grid of the wrong size.
    static func ring(painted: [Bool], width: Int, height: Int) -> [Bool] {
        guard width > 0, height > 0, width <= maxCells, height <= maxCells, width * height <= maxCells,
              painted.count == width * height else { return [] }
        let outWidth = width + 2
        var out = [Bool](repeating: false, count: outWidth * (height + 2))
        for y in 0..<height {
            for x in 0..<width where painted[y * width + x] {
                for dy in 0...2 {
                    for dx in 0...2 { out[(y + dy) * outWidth + x + dx] = true }
                }
            }
        }
        return out
    }
}

// MARK: - Clear ring twin: end

/// One place the one-colour map is punched out under: a view's bounds as it reports them, and the shape.
struct MapWidgetHole {
    /// The shape of a hole.
    enum Shape: Equatable {
        /// A rounded rectangle the size of the view (the plate, the tag).
        case rounded(cornerRadius: CGFloat)
        /// Sprout's clear ring, drawn from the companion's grid over the sprite's frame.
        case companion
    }

    /// The view's bounds.
    let bounds: Anchor<CGRect>
    let shape: Shape
}

/// Collects the map widget's holes from the views over the map, in the order they report them.
struct MapWidgetHoles: PreferenceKey {
    static var defaultValue: [MapWidgetHole] { [] }

    static func reduce(value: inout [MapWidgetHole], nextValue: () -> [MapWidgetHole]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's bounds as a hole in the one-colour map (``MapWidgetHoles``).
    func mapWidgetHole(_ shape: MapWidgetHole.Shape) -> some View {
        anchorPreference(key: MapWidgetHoles.self, value: .bounds) { [MapWidgetHole(bounds: $0, shape: shape)] }
    }
}

/// The one-colour map's mask: opaque everywhere but the holes. With no holes (the colour card) it hides
/// nothing.
struct MapWidgetHoleMask: View {
    /// Each hole's rectangle in the mask's own space, and its shape.
    let holes: [(rect: CGRect, shape: MapWidgetHole.Shape)]
    /// Sprout's grid, whose painted cells make its ring.
    let grid: WidgetCompanionGrid
    /// Points per sprite pixel.
    let spriteScale: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            context.blendMode = .destinationOut
            for hole in holes {
                switch hole.shape {
                case .rounded(let radius):
                    context.fill(Path(roundedRect: hole.rect, cornerRadius: radius), with: .color(.black))
                case .companion:
                    context.fill(Self.ring(of: grid, at: hole.rect.origin, scale: spriteScale), with: .color(.black))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Sprout's clear ring (``MapClearRing``) over its 24 × 24 item frame, whose top left is `origin`: every
    /// painted cell (the face's too, so its cut-outs show the widget's ground) and one cell round each.
    static func ring(of grid: WidgetCompanionGrid, at origin: CGPoint, scale: CGFloat) -> Path {
        let width = WidgetCompanionGrid.frameWidth, height = WidgetCompanionGrid.frameHeight
        var painted = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width { painted[y * width + x] = grid.frameColor(x: x, y: y) != nil }
        }
        var path = Path()
        for (index, on) in MapClearRing.ring(painted: painted, width: width, height: height).enumerated() where on {
            let x = index % (width + 2) - 1, y = index / (width + 2) - 1
            path.addRect(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale, width: scale, height: scale))
        }
        return path
    }
}

#!/bin/bash
#
# render-site-companion.sh — draw the website's pixel companion from the app's own painter.
#
# The site's companion (Site/assets/companion/*.svg) is not a redrawing: it is the widget's twin of
# the map's painter (App/FernletWidgets/WidgetPixelCompanion.swift, between the "Twin: begin" and
# "Twin: end" markers), compiled on its own with a small main that paints each state in the default
# look (the sprout, in the state's colour) and writes the 24 × 24 item frame as an SVG, one <rect>
# per run of one colour. Three frames per state: the resting frame, the in-breath frame the hero
# breathes with, and the "settled" face a poke shows.
#
# Run it after the painter changes, then commit the SVG diff. Needs only the Swift toolchain.
#
# Usage:  Scripts/render-site-companion.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAINTER="$ROOT/App/FernletWidgets/WidgetPixelCompanion.swift"
OUT="$ROOT/Site/assets/companion"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

begin=$(grep -n '// MARK: - Twin: begin' "$PAINTER" | cut -d: -f1)
end=$(grep -n '// MARK: - Twin: end' "$PAINTER" | cut -d: -f1)
[ -n "$begin" ] && [ -n "$end" ] || { echo "error: the twin markers are missing from $PAINTER" >&2; exit 1; }

{
  echo 'import Foundation'
  # The widget's mirror of the app's CompanionState: the painter needs only the cases.
  echo 'enum WidgetCompanionState: String, CaseIterable { case thriving, okay, tired, resting, sick }'
  echo 'typealias WidgetCompanionMood = WidgetCompanionState'
  sed -n "${begin},${end}p" "$PAINTER"
  cat <<'SWIFT'
func svg(_ grid: WidgetCompanionGrid) -> String {
    let w = WidgetCompanionGrid.frameWidth, h = WidgetCompanionGrid.frameHeight
    var rects: [String] = []
    for y in 0..<h {
        var x = 0
        while x < w {
            guard let c = grid.frameColor(x: x, y: y) else { x += 1; continue }
            var end = x + 1
            while end < w, grid.frameColor(x: end, y: y) == c { end += 1 }
            rects.append(String(format: "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"1\" fill=\"#%06X\"/>", x, y, end - x, c))
            x = end
        }
    }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\" shape-rendering=\"crispEdges\">"
        + rects.joined() + "</svg>\n"
}
let dir = CommandLine.arguments[1]
let poses = [("", WidgetCompanionPose()), ("-breath", WidgetCompanionPose(breathIn: true)),
             ("-settled", WidgetCompanionPose(settled: true))]
for state in WidgetCompanionState.allCases {
    let look = WidgetPixelLook(body: WidgetPixelLook.stateHex(state))
    for (suffix, pose) in poses {
        let grid = WidgetCompanionPainter.paint(state: state, look: look, pose: pose)
        do {
            try svg(grid).write(toFile: "\(dir)/\(state.rawValue)\(suffix).svg", atomically: true, encoding: .utf8)
        } catch {
            print("error: could not write \(state.rawValue)\(suffix).svg: \(error)")
            exit(1)
        }
    }
}
SWIFT
} > "$WORK/render.swift"

swiftc -O "$WORK/render.swift" -o "$WORK/render"
mkdir -p "$OUT"
"$WORK/render" "$OUT"
echo "wrote $(ls "$OUT"/*.svg | wc -l | tr -d ' ') companion frames to ${OUT#"$ROOT"/}"

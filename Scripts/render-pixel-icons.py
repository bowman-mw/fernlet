#!/usr/bin/env python3
"""Renders Fernlet's pixel marks: the Home Screen app icon, the website's tab and touch icons, and the
Instagram and LinkedIn profile images.

WHY THIS FILE EXISTS. The app went pixel with the World redesign, and on 2026-10-29 the owner picked
pixel marks to match, mixed by place (review page "Fernlet Pixel Icon", options A, C and D):

  * App icon (A) and the site's apple-touch-icon: Sprout at its happiest on parchment, the World page's
    faint dot grid behind it and a soft ground shadow under it. Default, Dark and Tinted variants.
  * Website tab (D): the fern sprig redrawn on the pixel grid, with no background.
  * LinkedIn (D): the same fern, 24-pixel drawing, with no background.
  * Instagram (C): Sprout up close on sage, the face filling the circle and the body running off the
    bottom edge.

THIS FILE IS THE SOURCE OF TRUTH for every one of those images. Never hand-edit the PNGs: change a
drawing here and re-run it.

SOURCES. Sprout is not redrawn: it is read from `Site/assets/companion/thriving.svg`, the 24 x 24
frame `Scripts/render-site-companion.sh` paints with the widget's own painter, so the icon is the same
creature the app draws. The two ferns are drawn below a pixel at a time: FERN_24 for the large sizes
and FERN_16 for the tab, because a 24-pixel drawing cannot shrink to 16 and stay crisp. At 16 an ink
outline would leave one pixel of leaf, so the small fern is solid leaf shapes. Colours are the World
palette (`App/Fernlet/World/Theme/WorldPalette.swift`) and the companion's own inks.

PIXELS STAY PIXELS. Every image is drawn as solid squares at whole-pixel positions, never resampled.
The app icon stays a flat PNG set rather than an Icon Composer file, so Liquid Glass does not soften
the edges. App icon PNGs are 8-bit RGB with no alpha, which App Store Connect requires; the tab icons
and the LinkedIn logo keep their transparency. `favicon.svg` keeps the bark-brown stem in a light
browser and lifts it to a pale wood in a dark one, where brown vanishes on the tab strip.

RUN:   python3 Scripts/render-pixel-icons.py                 # rewrite the app icon set and the site icons
       python3 Scripts/render-pixel-icons.py --social DIR    # also write the Instagram and LinkedIn images
NEEDS: Pillow (python3 -m pip install pillow).
"""

import argparse
import os
import re
import sys

try:
    from PIL import Image, ImageDraw
except ImportError as missing:
    sys.exit(f"render-pixel-icons: {missing}. Install with: python3 -m pip install pillow")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPROUT_SVG = os.path.join(REPO, "Site/assets/companion/thriving.svg")
ICON_SET = os.path.join(REPO, "App/Fernlet/Assets.xcassets/AppIcon.appiconset")
SITE_ASSETS = os.path.join(REPO, "Site/assets")

# --- palette (WorldPalette) ----------------------------------------------------------------------

PAGE = {"light": "#F5EFDF", "dark": "#1C1E1B"}
SAGE = "#E6ECD2"
DOT = {"light": ("#4A2E1C", 18), "dark": ("#FFF1CF", 14)}  # the page's dot grid: ink 7 %, cream 5 %
GROUND_SHADOW = {"light": "#E6DDC8", "dark": "#141513"}
FERN_INKS = {"O": "#3B4427", "D": "#5A7A52", "G": "#8AAD7E", "T": "#4A2E1C"}
DARK_STEM = "#C9A27E"  # the stem on a dark tab strip, where bark brown vanishes

# --- the ferns, a pixel at a time ----------------------------------------------------------------
# O outline, D leaf, G young leaf, T stem. The stem runs corner to corner like the smooth mark's.

FERN_24 = """
........................
........................
...............O...O....
..............OGO.OGO...
..............OGO.OGO...
...........O..OGO..O....
..........OHO.OGO.T.....
.........ODHDO.O.T......
.........ODDDO..T.OOOO..
.........ODDDO.T.OGGGGO.
......O..ODDDOT...OOOO..
.....OHO..ODOTOOOO......
....ODHDO..OTOHDDDOO....
....ODDDO..T.ODDDDDDO...
....ODDDO.T..ODDDDOO....
....ODDDOT....OOOO......
.....ODOTOOOO...........
......OTOHDDDOO.........
......T.ODDDDDDO........
.....T..ODDDDOO.........
....T....OOOO...........
...T....................
........................
........................
"""

FERN_16 = """
..............G.
.......D.....GG.
......DGD...GG..
......DGD..T....
...D..DDD.T.....
..DGD..DDT.DDD..
..DGD...TDDDDDD.
..DDD..T..DDD...
...DD.T.........
....DT..........
....T...........
...T.DDD........
..TDDDDDD.......
.T...DDD........
T...............
................
"""


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def char_grid(art, inks):
    """A drawing's pixels as {(x, y): rgb}; '.' is empty."""
    grid = {}
    for y, row in enumerate(art.strip("\n").split("\n")):
        for x, ch in enumerate(row):
            if ch != ".":
                grid[(x, y)] = hex_rgb(inks[ch])
    return grid


def sprout():
    """Sprout's resting frame, read from the companion SVG the widget painter wrote."""
    with open(SPROUT_SVG, encoding="utf-8") as svg:
        text = svg.read()
    grid = {}
    for x, y, width, colour in re.findall(r'<rect x="(\d+)" y="(\d+)" width="(\d+)" height="1" fill="#([0-9A-F]{6})"', text):
        for i in range(int(width)):
            grid[(int(x) + i, int(y))] = hex_rgb(colour)
    if not grid:
        sys.exit(f"render-pixel-icons: no pixels in {SPROUT_SVG}; run Scripts/render-site-companion.sh")
    return grid


FERN_INKS_24 = dict(FERN_INKS, H="#9BB391")


def greyscale(grid):
    """Tinted icons are greyscale that iOS multiplies by the person's tint; lift the art so it reads light."""
    out = {}
    for key, (r, g, b) in grid.items():
        level = min(255, int(60 + (0.2126 * r + 0.7152 * g + 0.0722 * b) * 1.6))
        out[key] = (level, level, level)
    return out


def paint(image, grid, ox, oy, cell):
    draw = ImageDraw.Draw(image)
    for (x, y), colour in grid.items():
        x0, y0 = ox + x * cell, oy + y * cell
        draw.rectangle([x0, y0, x0 + cell - 1, y0 + cell - 1], fill=colour)


def dot_grid(image, pitch, ox, oy, colour, alpha):
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    dot = max(2, pitch // 5)
    for y in range(oy % pitch, image.size[1], pitch):
        for x in range(ox % pitch, image.size[0], pitch):
            draw.rectangle([x, y, x + dot - 1, y + dot - 1], fill=hex_rgb(colour) + (alpha,))
    image.alpha_composite(layer)


# --- the marks -----------------------------------------------------------------------------------

def sprout_on_parchment(size, mode):
    """Option A: the app icon and the touch icon. Sprout spans about two thirds of the tile."""
    background = "#000000" if mode == "tinted" else PAGE[mode]
    image = Image.new("RGBA", (size, size), hex_rgb(background) + (255,))
    cell = round(size * 40 / 1024)
    ox, oy = int(size / 2 - 12 * cell), int(size / 2 - 12.5 * cell)
    art = sprout()
    if mode == "tinted":
        paint(image, greyscale(art), ox, oy, cell)
        return image
    dot_grid(image, cell * 2, ox, oy, *DOT[mode])
    shade = hex_rgb(GROUND_SHADOW[mode])
    shadow = {(x, 21): shade for x in range(7, 17)}
    shadow.update({(x, 22): shade for x in range(9, 15)})
    paint(image, shadow, ox, oy, cell)
    paint(image, art, ox, oy, cell)
    return image


def sprout_up_close(size):
    """Option C: the Instagram picture. The leaf tip sits a cell and a half below the top; the circle
    crop keeps the leaves, eyes and cheeks and trims only the body's lower sides."""
    image = Image.new("RGBA", (size, size), hex_rgb(SAGE) + (255,))
    cell = round(size * 64 / 1024)
    ox, oy = int(size / 2 - 12 * cell), int(cell * 1.5 - 4 * cell)
    dot_grid(image, cell * 2, ox, oy, "#4A2E1C", 16)
    paint(image, sprout(), ox, oy, cell)
    return image


def fern_alone(size):
    """Option D at 24 pixels, transparent: the LinkedIn logo. The drawing's bounds (x 3-22, y 2-21)
    are centred."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cell = size * 18 // 400
    paint(image, char_grid(FERN_24, FERN_INKS_24), size // 2 - 13 * cell, size // 2 - 12 * cell, cell)
    return image


def tab_fern(scale):
    image = Image.new("RGBA", (16 * scale, 16 * scale), (0, 0, 0, 0))
    paint(image, char_grid(FERN_16, FERN_INKS), 0, 0, scale)
    return image


def tab_fern_svg():
    rects = []
    for y, row in enumerate(FERN_16.strip("\n").split("\n")):
        x = 0
        while x < len(row):
            ch = row[x]
            if ch == ".":
                x += 1
                continue
            end = x
            while end < len(row) and row[end] == ch:
                end += 1
            rects.append(f'<rect class="{ch}" x="{x}" y="{y}" width="{end - x}" height="1"/>')
            x = end
    style = (f".D{{fill:{FERN_INKS['D']}}}.G{{fill:{FERN_INKS['G']}}}.T{{fill:{FERN_INKS['T']}}}"
             f"@media (prefers-color-scheme:dark){{.T{{fill:{DARK_STEM}}}}}")
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">'
            f"<title>Fernlet</title><style>{style}</style>{''.join(rects)}</svg>\n")


def save_rgb(image, path):
    image.convert("RGB").save(path, optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--social", metavar="DIR", help="also write the Instagram and LinkedIn images to DIR")
    args = parser.parse_args()

    for mode, name in (("light", "fernlet-icon-1024.png"), ("dark", "fernlet-icon-dark-1024.png"),
                       ("tinted", "fernlet-icon-tinted-1024.png")):
        save_rgb(sprout_on_parchment(1024, mode), os.path.join(ICON_SET, name))
    save_rgb(sprout_on_parchment(180, "light"), os.path.join(SITE_ASSETS, "apple-touch-icon.png"))
    tab_fern(1).save(os.path.join(SITE_ASSETS, "favicon-16.png"), optimize=True)
    tab_fern(2).save(os.path.join(SITE_ASSETS, "favicon-32.png"), optimize=True)
    with open(os.path.join(SITE_ASSETS, "favicon.svg"), "w", encoding="utf-8") as svg:
        svg.write(tab_fern_svg())
    print("wrote the app icon set and the site's tab and touch icons")

    if args.social:
        os.makedirs(args.social, exist_ok=True)
        save_rgb(sprout_up_close(1080), os.path.join(args.social, "fernlet-instagram-1080.png"))
        fern_alone(400).save(os.path.join(args.social, "fernlet-linkedin-400.png"), optimize=True)
        print(f"wrote the Instagram and LinkedIn images to {args.social}")


if __name__ == "__main__":
    main()

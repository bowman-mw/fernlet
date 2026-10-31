#!/usr/bin/env python3
"""Draft our own airport outlines and render their review cards (World-Airports-Spec §2.1).

Build machine only. For each large airport's token, it:
1. seeds an outline: the hull of its runway ends from OurAirports (public domain), widened about 800 m (the
   spec's auto-draft). The spec's US seed, the Census TIGER/Line "Airport or Airfield" polygon (MTFCC
   K2451), isn't in TIGER 2024's area landmarks, so every draft starts from the runways;
2. or, with --corrections, takes the outline traced by eye on the card (points in card pixels);
3. simplifies it to at most 24 points (at 50 m, coarser only if needed);
4. fetches the open imagery around it (US: USGS National Map imagery, public domain; elsewhere: Sentinel-2
   cloudless 2016 by EOX, CC BY 4.0, "Contains modified Copernicus Sentinel data 2016") into a tile cache,
   and
5. renders a review card (the outline over its picture with numbered points, the runways, a pixel grid for
   tracing, the source and credit) and writes a draft record in airport-outlines.json's shape, with no
   approval, plus the card's geometry so card pixels map back to the ground.

Never OpenStreetMap, Overture, Apple, Google or Bing. Drafts and cards go to --out, OUTSIDE the repo: an
outline joins Scripts/world-atlas/airport-outlines.json only after the owner approves its card, and the
generator refuses one without an approval. The owner OK'd the imagery downloads in chat (2026-10-30).

    python3 -I Scripts/world-atlas/draft_airport_outlines.py --sources ~/Library/Caches/Fernlet/atlas-sources \
        --tokens-file <list outside the repo> --out <folder outside the repo> [--corrections <json>]

--corrections names a JSON file {"TOKEN": [[x, y], ...]} of points traced on that token's card (the pixel
grid's numbers; the title band above the picture is not counted). The card the points were read from must
still be in --out: its geometry maps them back.

Bounds: every loop runs over a finite input (tokens, tiles in a capped box, rings); downloads are capped
per card.
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_world_airports as airports  # noqa: E402
import build_world_atlas as atlas  # noqa: E402

np = atlas.np
Image = atlas.Image
from PIL import ImageDraw, ImageFont  # noqa: E402  (Pillow comes with the atlas generator's import)

AGENT = "FernletAtlasBuild/1.0 (bowman-mw; build-machine data fetch)"
USGS_URL = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/%d/%d/%d"
EOX_URL = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/%d/%d/%d.jpg"
CREDIT = {
    "usgs": "Imagery: USGS The National Map (public domain)",
    "eox": "Imagery: Sentinel-2 cloudless 2016 by EOX IT Services GmbH (CC BY 4.0), "
           "contains modified Copernicus Sentinel data 2016",
}
MAX_ZOOM = {"usgs": 16, "eox": 14}
SEED_MARGIN_METRES = 800.0
PAD_METRES = 1_000.0
MAX_POINTS = 24
MAX_TILES = 64
CARD_MAX_PIXELS = 1400
BAND = 64
GRID = 100


def fetch(url, path):
    """Downloads `url` to `path` once (a file already there is reused)."""
    if os.path.isfile(path):
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    # Bounded: four tries, backing off 2, 4 and 8 s after a dropped connection.
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response, open(path + ".partial", "wb") as handle:
                handle.write(response.read())
            break
        except (OSError, urllib.error.URLError):
            if attempt == 3:
                raise
            time.sleep(2 ** (attempt + 1))
    os.replace(path + ".partial", path)
    time.sleep(0.05)
    return path


def simplified(ring_latlon):
    """The ring at ≤ MAX_POINTS points: Douglas-Peucker at 50 m, doubled until it fits (at most 8 tries)."""
    pts = np.array([[lon, lat] for lat, lon in ring_latlon] + [[ring_latlon[0][1], ring_latlon[0][0]]])
    epsilon = 50.0 / airports.METRES_PER_DEGREE
    for _ in range(8):
        thin = atlas.simplify_closed_ring(pts, epsilon)
        if len(thin) - 1 <= MAX_POINTS:
            return [(round(float(p[1]), 5), round(float(p[0]), 5)) for p in thin[:-1]]
        epsilon *= 2
    raise SystemExit("error: a ring would not simplify to %d points" % MAX_POINTS)


def runway_seed(airport, ends):
    """The runway ends' hull widened about 800 m (the spec's auto-draft), as an open (lat, lon) ring."""
    xy = []
    for lat, lon in ends:
        x, y = airports.local_xy(airport["lat"], airport["lon"], lat, lon)
        for k in range(24):
            angle = 2 * math.pi * k / 24
            xy.append((x + SEED_MARGIN_METRES * math.cos(angle), y + SEED_MARGIN_METRES * math.sin(angle)))
    hull = airports.convex_hull(xy)
    return [airports.local_latlon(airport["lat"], airport["lon"], x, y) for x, y in hull]


# ---------------------------------------------------------------------------------------------------------
# Card geometry: card pixel <-> ground


def tile_xy(lat, lon, zoom):
    """Web Mercator tile coordinates (fractional) of a point."""
    n = 2 ** zoom
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def tile_latlon(x, y, zoom):
    """The point at fractional Web Mercator tile coordinates."""
    n = 2 ** zoom
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lat, lon


def geometry(airport, ring, source):
    """The card's zoom and its top-left corner in tile coordinates, padded 1 km around the outline."""
    lats = [p[0] for p in ring] + [airport["lat"]]
    lons = [p[1] for p in ring] + [airport["lon"]]
    pad_lat = PAD_METRES / airports.METRES_PER_DEGREE
    pad_lon = pad_lat / max(0.1, math.cos(math.radians(airport["lat"])))
    north, south = max(lats) + pad_lat, min(lats) - pad_lat
    west, east = min(lons) - pad_lon, max(lons) + pad_lon
    zoom = MAX_ZOOM[source]
    # Bounded: at most MAX_ZOOM - 8 steps.
    while zoom > 8:
        x0, y0 = tile_xy(north, west, zoom)
        x1, y1 = tile_xy(south, east, zoom)
        if (x1 - x0) * 256 <= CARD_MAX_PIXELS and (y1 - y0) * 256 <= CARD_MAX_PIXELS:
            break
        zoom -= 1
    x0, y0 = tile_xy(north, west, zoom)
    x1, y1 = tile_xy(south, east, zoom)
    return {"zoom": zoom, "x0": x0, "y0": y0, "width": int((x1 - x0) * 256), "height": int((y1 - y0) * 256)}


def to_pixel(geo, lat, lon):
    x, y = tile_xy(lat, lon, geo["zoom"])
    return ((x - geo["x0"]) * 256, (y - geo["y0"]) * 256)


def from_pixel(geo, px, py):
    lat, lon = tile_latlon(geo["x0"] + px / 256.0, geo["y0"] + py / 256.0, geo["zoom"])
    return round(lat, 5), round(lon, 5)


def card(airport, ring, runways, seed, source, geo, sources_dir, out_path):
    """Renders the card: imagery, a 100-pixel grid, runways (white), the outline with numbered points
    (yellow), the reference point (red), the title and the credit."""
    zoom = geo["zoom"]
    tx0, ty0 = int(geo["x0"]), int(geo["y0"])
    tx1 = int(geo["x0"] + geo["width"] / 256.0)
    ty1 = int(geo["y0"] + geo["height"] / 256.0)
    tiles = [(tx, ty) for tx in range(tx0, tx1 + 1) for ty in range(ty0, ty1 + 1)]
    if len(tiles) > MAX_TILES:
        raise SystemExit("error: %s needs %d tiles, over %d" % (airport["ident"], len(tiles), MAX_TILES))
    mosaic = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256))
    for tx, ty in tiles:
        url = USGS_URL % (zoom, ty, tx) if source == "usgs" else EOX_URL % (zoom, ty, tx)
        path = os.path.join(sources_dir, "imagery", source, str(zoom), str(tx), "%d.jpg" % ty)
        fetch(url, path)
        mosaic.paste(Image.open(path).convert("RGB"), ((tx - tx0) * 256, (ty - ty0) * 256))
    left, top = int((geo["x0"] - tx0) * 256), int((geo["y0"] - ty0) * 256)
    picture = mosaic.crop((left, top, left + geo["width"], top + geo["height"]))
    draw = ImageDraw.Draw(picture)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 18)
        small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 12)
    except OSError:
        font = small = ImageFont.load_default()
    for x in range(GRID, geo["width"], GRID):
        draw.line([(x, 0), (x, geo["height"])], fill=(90, 200, 255), width=1)
        draw.text((x + 2, 2), str(x), fill=(90, 200, 255), font=small)
    for y in range(GRID, geo["height"], GRID):
        draw.line([(0, y), (geo["width"], y)], fill=(90, 200, 255), width=1)
        draw.text((2, y + 2), str(y), fill=(90, 200, 255), font=small)
    for a, b in runways:
        draw.line([to_pixel(geo, *a), to_pixel(geo, *b)], fill=(255, 255, 255), width=2)
    poly = [to_pixel(geo, lat, lon) for lat, lon in ring]
    draw.line(poly + poly[:1], fill=(255, 214, 0), width=4, joint="curve")
    for i, (x, y) in enumerate(poly):
        draw.ellipse([x - 5, y - 5, x + 5, y + 5], outline=(255, 214, 0), width=2)
        draw.text((x + 7, y - 7), str(i + 1), fill=(255, 214, 0), font=small)
    cx, cy = to_pixel(geo, airport["lat"], airport["lon"])
    draw.ellipse([cx - 5, cy - 5, cx + 5, cy + 5], fill=(220, 40, 40))
    sheet = Image.new("RGB", (geo["width"], geo["height"] + BAND), (24, 24, 24))
    text = ImageDraw.Draw(sheet)
    code = airport["iata"] or airport["ident"]
    text.text((10, 8), "%s · %s  (%s, %d points)" % (code, airport["name"], seed, len(ring)),
              fill=(255, 255, 255), font=font)
    text.text((10, 38), CREDIT[source], fill=(200, 200, 200), font=small)
    sheet.paste(picture, (0, BAND))
    sheet.save(out_path, optimize=True)


def main(argv):
    parser = argparse.ArgumentParser(description="Draft airport outlines and their review cards.")
    parser.add_argument("--sources", required=True)
    parser.add_argument("--tokens", default="", help="comma-separated tokens")
    parser.add_argument("--tokens-file", default="", help="a file of tokens, one per line (keep it outside the repo)")
    parser.add_argument("--out", required=True, help="a folder OUTSIDE the repo for cards and drafts")
    parser.add_argument("--corrections", default="", help="JSON of outlines traced on the cards, in card pixels")
    args = parser.parse_args(argv)
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    if os.path.abspath(args.out).startswith(repo + os.sep):
        raise SystemExit("error: --out must be outside the repo (drafts ship only once approved)")
    tokens = [t.strip() for t in args.tokens.split(",") if t.strip()]
    if args.tokens_file:
        with open(args.tokens_file, "r", encoding="utf-8") as handle:
            tokens += [line.strip() for line in handle if line.strip() and not line.startswith("#")]
    if not tokens or len(tokens) > 1_500:
        raise SystemExit("error: give 1 to 1,500 tokens")
    corrections = airports.read_json(args.corrections) if args.corrections else {}
    drafts_path = os.path.join(args.out, "drafts.json")
    previous = {}
    if os.path.isfile(drafts_path):
        previous = {d["id"]: d for d in airports.read_json(drafts_path).get("outlines", [])}
    report = airports.Report()
    table = airports.read_source_table(here)
    found = airports.locate_sources(args.sources, table, True, report)
    rows = airports.read_airports(found["ourairports/airports.csv"]["path"], report)
    frozen = {int(k): v for k, v in airports.read_json(os.path.join(here, "airport-tokens.json"))["tokens"].items()}
    by_token = {frozen[a["id"]]: a for a in rows if a["id"] in frozen}
    runway_rows = {}
    for row in airports.read_csv(found["ourairports/runways.csv"]["path"], 400_000):
        runway_rows.setdefault(row["airport_ref"], []).append(row)
    os.makedirs(args.out, exist_ok=True)
    drafts = dict(previous)
    for token in tokens:
        airport = by_token.get(token)
        if airport is None or airport["type"] != "large_airport":
            print("skip %s: not a large airport in the list" % token)
            continue
        mine = runway_rows.get(str(airport["id"]), [])
        runways = []
        for row in mine:
            try:
                runways.append(((float(row["le_latitude_deg"]), float(row["le_longitude_deg"])),
                                (float(row["he_latitude_deg"]), float(row["he_longitude_deg"]))))
            except ValueError:
                continue
        source = "usgs" if airport["country"] == "US" else "eox"
        if token in corrections:
            old = previous.get(token)
            if old is None or "geometry" not in old:
                raise SystemExit("error: %s has corrections but no earlier card to read them against" % token)
            traced = [from_pixel(old["geometry"], x, y) for x, y in corrections[token]]
            if not (4 <= len(traced) <= MAX_POINTS):
                raise SystemExit("error: %s's traced outline has %d points (4 to %d)" % (token, len(traced),
                                                                                         MAX_POINTS))
            ring, seed, geo = traced, "traced by eye", old["geometry"]
        else:
            ends = airports.runway_ends(mine, airport, report)
            if not ends:
                print("skip %s: no runway ends to seed from" % token)
                continue
            ring = simplified(runway_seed(airport, ends))
            seed = "auto-draft from runways"
            geo = geometry(airport, ring, source)
        card_path = os.path.join(args.out, "%s.png" % token)
        card(airport, ring, runways, seed, source, geo, args.sources, card_path)
        drafts[token] = {"id": token, "points": [[lat, lon] for lat, lon in ring], "imagery": CREDIT[source],
                         "imageryDate": "2016" if source == "eox" else "USGS current", "seed": seed,
                         "geometry": geo, "card": os.path.basename(card_path), "reviewer": "", "approved": ""}
        print("%s: %d points (%s), card %s" % (token, len(ring), seed, card_path))
    with open(drafts_path + ".partial", "w", encoding="utf-8") as handle:
        json.dump({"outlines": [drafts[k] for k in sorted(drafts)]}, handle, ensure_ascii=False, indent=1)
    os.replace(drafts_path + ".partial", drafts_path)
    print("%d drafts in %s" % (len(drafts), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

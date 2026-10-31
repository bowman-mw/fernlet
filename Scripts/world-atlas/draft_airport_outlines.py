#!/usr/bin/env python3
"""Draft our own airport outlines and render their review cards (World-Airports-Spec §2.1).

Build machine only. For each large airport's token, it:
1. seeds an outline: by default the hull of its runway ends from OurAirports (public domain), widened about
   800 m (the spec's auto-draft); with --seed public, the published outline instead (owner 2026-10-31): in the
   US the Census TIGER/Line 2015 "Airport or Airfield" polygon (MTFCC K2451, public domain; TIGER 2024's area
   landmarks no longer carry airports), in Europe the CORINE Land Cover 2018 class 124 "Airports" polygon
   (© European Union, Copernicus Land Monitoring Service, EEA; free with that credit), each the one holding
   most of the airport's runway ends, falling back to the runways where neither has one;
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
import urllib.parse
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
HLS_URL = ("https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/%s/default/%s/GoogleMapsCompatible_Level12/"
           "%d/%d/%d.png")
HLS_LAYERS = ("HLS_S30_Nadir_BRDF_Adjusted_Reflectance", "HLS_L30_Nadir_BRDF_Adjusted_Reflectance")
HLS_ZOOM = 12
HLS_PROBES = 40
S2_SEARCH = "https://earth-search.aws.element84.com/v1/search"
S2_CANDIDATES = 8
EARTH_RADIUS = 6378137.0
CREDIT = {
    "usgs": "Imagery: USGS The National Map (public domain)",
    "eox": "Imagery: Sentinel-2 cloudless 2016 by EOX IT Services GmbH (CC BY 4.0), "
           "contains modified Copernicus Sentinel data 2016",
}
MAX_ZOOM = {"usgs": 16, "eox": 14, "hls": 14, "s2": 14}
SEED_MARGIN_METRES = 800.0
PAD_METRES = 1_000.0
MAX_POINTS = 24
MAX_TILES = 64
CARD_MAX_PIXELS = 1400
BAND = 80
GRID = 100
TIGER_YEAR = "2015"
TIGER_URL = "https://www2.census.gov/geo/tiger/TIGER%s/AREALM/tl_%s_%s_arealm.zip"
CORINE_URL = "https://image.discomap.eea.europa.eu/arcgis/rest/services/Corine/CLC2018_WM/MapServer/0/query"
CORINE_REACH_DEGREES = 0.06
SEED_CREDIT = {
    "tiger": "Outline seed: US Census Bureau TIGER/Line 2015 (public domain)",
    "corine": "Outline seed: CORINE Land Cover 2018, © European Union, Copernicus Land Monitoring Service, EEA",
    "runways": "Outline seed: OurAirports runways (public domain)",
    "earlier": "Outline seed: the earlier draft",
}
STATE_FIPS = {
    "AL": "01", "AK": "02", "AZ": "04", "AR": "05", "CA": "06", "CO": "08", "CT": "09", "DE": "10", "DC": "11",
    "FL": "12", "GA": "13", "HI": "15", "ID": "16", "IL": "17", "IN": "18", "IA": "19", "KS": "20", "KY": "21",
    "LA": "22", "ME": "23", "MD": "24", "MA": "25", "MI": "26", "MN": "27", "MS": "28", "MO": "29", "MT": "30",
    "NE": "31", "NV": "32", "NH": "33", "NJ": "34", "NM": "35", "NY": "36", "NC": "37", "ND": "38", "OH": "39",
    "OK": "40", "OR": "41", "PA": "42", "RI": "44", "SC": "45", "SD": "46", "TN": "47", "TX": "48", "UT": "49",
    "VT": "50", "VA": "51", "WA": "53", "WV": "54", "WI": "55", "WY": "56", "PR": "72",
}
CORINE_COUNTRIES = {
    "AL", "AT", "BA", "BE", "BG", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GB", "GR", "HR", "HU",
    "IE", "IS", "IT", "LI", "LT", "LU", "LV", "ME", "MK", "MT", "NL", "NO", "PL", "PT", "RO", "RS", "SE", "SI",
    "SK", "TR", "XK",
}


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
# Published seeds


def ring_inside(ring, lat, lon):
    hit = False
    for (la1, lo1), (la2, lo2) in zip(ring, ring[1:] + ring[:1]):
        if (la1 > lat) != (la2 > lat) and lo1 + (lat - la1) * (lo2 - lo1) / (la2 - la1) > lon:
            hit = not hit
    return hit


def tiger_rings(sources, state, report):
    """The state's TIGER 2015 K2451 (airport or airfield) outer rings, as [(lat, lon)] lists."""
    fips = STATE_FIPS.get(state)
    if fips is None:
        return []
    path = os.path.join(sources, "tiger-arealm", "tl_%s_%s_arealm.zip" % (TIGER_YEAR, fips))
    fetch(TIGER_URL % (TIGER_YEAR, TIGER_YEAR, fips), path)
    rings = []
    for geom, attrs in atlas.read_layer(path, report):
        if str(attrs.get("MTFCC", "")).strip() == "K2451":
            parts = atlas.polygon_rings(geom)
            if parts:
                rings.append([(float(p[1]), float(p[0])) for p in max(parts, key=len)])
    return rings


def corine_rings(sources, token, airport):
    """CORINE 2018 class 124 outer rings within about 6 km of the airport (one cached query per airport)."""
    path = os.path.join(sources, "corine-124", "%s.geojson" % token)
    if not os.path.isfile(path):
        lat, lon, r = airport["lat"], airport["lon"], CORINE_REACH_DEGREES
        query = urllib.parse.urlencode({
            "where": "Code_18='124'", "geometry": "%f,%f,%f,%f" % (lon - 2 * r, lat - r, lon + 2 * r, lat + r),
            "geometryType": "esriGeometryEnvelope", "inSR": "4326", "spatialRel": "esriSpatialRelIntersects",
            "outFields": "Code_18,ID", "returnGeometry": "true", "outSR": "4326", "f": "geojson"})
        fetch(CORINE_URL + "?" + query, path)
    rings = []
    for feature in airports.read_json(path).get("features", [])[:50]:
        geometry_ = feature.get("geometry") or {}
        polygons = geometry_.get("coordinates", [])
        if geometry_.get("type") == "Polygon":
            polygons = [polygons]
        for polygon in polygons[:50]:
            if polygon:
                rings.append([(float(p[1]), float(p[0])) for p in polygon[0]])
    return rings


def best_ring(rings, airport, ends):
    """The ring holding most runway ends (ties: the one holding the airport's point, then the larger), or
    None where none holds a runway end or the point."""
    scored = []
    for ring in rings:
        held = sum(ring_inside(ring, lat, lon) for lat, lon in ends)
        point = ring_inside(ring, airport["lat"], airport["lon"])
        if held or point:
            scored.append((held, point, len(ring), ring))
    return max(scored, key=lambda s: s[:3])[3] if scored else None


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


def hls_days(airport, sources_dir):
    """The five clearest recent HLS days over the airport (NASA GIBS, no copyright restrictions), as
    (layer, day) pairs: every third day back from 2026-10-25 (HLS_PROBES of them), both the Sentinel-2 and the
    Landsat layer, scored on the zoom-12 tile over the airport by its coverage less three times its cloud-bright
    share. A card is the per-pixel median of the five, which takes most cloud out."""
    import datetime
    x, y = tile_xy(airport["lat"], airport["lon"], HLS_ZOOM)
    scored = []
    for step in range(HLS_PROBES):
        day = (datetime.date(2026, 10, 25) - datetime.timedelta(days=3 * step)).isoformat()
        for layer in HLS_LAYERS:
            path = os.path.join(sources_dir, "imagery", "hls", layer, day, str(HLS_ZOOM), str(int(x)),
                                "%d.png" % int(y))
            try:
                fetch(HLS_URL % (layer, day, HLS_ZOOM, int(y), int(x)), path)
                pixels = np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)
            except (OSError, urllib.error.URLError):
                continue
            covered = float((pixels[:, :, 3] > 0).mean())
            bright = float(((pixels[:, :, :3] > 165).all(axis=2) & (pixels[:, :, 3] > 0)).mean())
            if covered > 0.5:
                scored.append((covered - 3 * bright, layer, day))
    scored.sort(reverse=True)
    return [(layer, day) for _, layer, day in scored[:5]]


def s2_scenes(airport, geo, sources_dir, cloud=5):
    """Up to S2_CANDIDATES Sentinel-2 L2A scenes from 2023–2025 (Copernicus, free with "Contains modified
    Copernicus Sentinel data <year>") whose footprint covers the card, least cloudy first, from the open AWS
    copies via Element 84's earth-search catalogue (no login). The answer is cached per airport."""
    west, north = card_lonlat(geo, 0, 0)
    east, south = card_lonlat(geo, geo["width"], geo["height"])
    path = os.path.join(sources_dir, "imagery", "s2", "search-%s%s.json" % (airport["ident"],
                                                                           "" if cloud == 5 else "-%d" % cloud))
    if not os.path.isfile(path):
        body = json.dumps({
            "collections": ["sentinel-2-l2a"], "bbox": [west, south, east, north],
            "datetime": "2023-01-01T00:00:00Z/2025-12-31T23:59:59Z", "query": {"eo:cloud_cover": {"lt": cloud}},
            "sortby": [{"field": "properties.eo:cloud_cover", "direction": "asc"}], "limit": 40}).encode()
        request = urllib.request.Request(S2_SEARCH, data=body, method="POST",
                                         headers={"User-Agent": AGENT, "Content-Type": "application/json"})
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with urllib.request.urlopen(request, timeout=120) as response, open(path + ".partial", "wb") as handle:
            handle.write(response.read())
        os.replace(path + ".partial", path)
    scenes = []
    for feature in airports.read_json(path).get("features", [])[:40]:
        bw, bs, be, bn = feature["bbox"]
        href = feature["assets"].get("visual", {}).get("href", "")
        # Only HTTPS copies: an s3:// asset (an older JPEG 2000 scene) reads back blank without credentials.
        if bw <= west and bs <= south and be >= east and bn >= north and href.startswith("https://"):
            scenes.append({"id": feature["id"], "day": feature["properties"]["datetime"][:10],
                           "href": feature["assets"]["visual"]["href"]})
    return scenes[:S2_CANDIDATES]


def card_lonlat(geo, px, py):
    lat, lon = tile_latlon(geo["x0"] + px / 256.0, geo["y0"] + py / 256.0, geo["zoom"])
    return lon, lat


def s2_picture(geo, sources_dir, token):
    """The card's picture from the first candidate scene that covers it with no empty pixels (a scene's edge
    or a gap), reprojected to the card's Web Mercator grid; the scene chosen is written into `geo`."""
    import site
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.append(user_site)
    import rasterio
    from rasterio.enums import Resampling
    from rasterio.transform import from_bounds
    from rasterio.warp import reproject
    n = 2 ** geo["zoom"]
    span = 2 * math.pi * EARTH_RADIUS
    left = geo["x0"] / n * span - span / 2
    top = span / 2 - geo["y0"] / n * span
    right = (geo["x0"] + geo["width"] / 256.0) / n * span - span / 2
    bottom = span / 2 - (geo["y0"] + geo["height"] / 256.0) / n * span
    for scene in geo["candidates"]:
        # The cache key carries the card's geometry: a card redrawn at another size or place reads afresh.
        key = "%d-%.4f-%.4f-%d-%d" % (geo["zoom"], geo["x0"], geo["y0"], geo["width"], geo["height"])
        cache = os.path.join(sources_dir, "imagery", "s2", "%s-%s-%s.png" % (token, scene["id"], key))
        if os.path.isfile(cache):
            picture = Image.open(cache).convert("RGB")
        else:
            data = np.zeros((3, geo["height"], geo["width"]), dtype=np.uint8)
            target = from_bounds(left, bottom, right, top, geo["width"], geo["height"])
            with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", AWS_NO_SIGN_REQUEST="YES"):
                with rasterio.open(scene["href"]) as src:
                    # Bounded: three bands.
                    for band in range(3):
                        reproject(rasterio.band(src, band + 1), data[band], dst_transform=target,
                                  dst_crs="EPSG:3857", dst_nodata=0, resampling=Resampling.bilinear)
            picture = Image.fromarray(np.transpose(data, (1, 2, 0)).astype(np.uint8), "RGB")
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            picture.save(cache)
        # Empty means no data (0) or nearly black (a blank read gives 0 or 1 in every band).
        empty = float((np.asarray(picture).max(axis=2) <= 1).mean())
        if empty <= 0.01:
            geo["scene"], geo["day"] = scene["id"], scene["day"]
            return picture
    raise SystemExit("error: no Sentinel-2 scene covers %s's card" % token)


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


def credit_for(source, geo):
    """The imagery credit printed on a card and kept in its draft."""
    if source == "s2":
        return "Imagery: Copernicus Sentinel-2 L2A 10 m, %s (contains modified Copernicus Sentinel data %s)" % (
            geo["day"], geo["day"][:4])
    if source == "hls":
        days = sorted(day for _, day in geo["days"])
        extra = ", contains modified Copernicus Sentinel data" if any(l.startswith("HLS_S30") for l, _ in geo["days"]) else ""
        return "Imagery: NASA GIBS, HLS 30 m, median of %d days %s to %s (no copyright restrictions%s)" % (
            len(days), days[0], days[-1], extra)
    return CREDIT[source]


def card(airport, ring, runways, seed, source, geo, sources_dir, out_path, seed_credit="", earlier=None):
    """Renders the card: imagery, a 100-pixel grid, runways (white), an earlier draft to compare (faint
    cyan, dashed), the outline with numbered points (yellow), the reference point (red), the title and the
    credits."""
    zoom = geo["zoom"]
    tx0, ty0 = int(geo["x0"]), int(geo["y0"])
    tx1 = int(geo["x0"] + geo["width"] / 256.0)
    ty1 = int(geo["y0"] + geo["height"] / 256.0)
    tiles = [(tx, ty) for tx in range(tx0, tx1 + 1) for ty in range(ty0, ty1 + 1)]
    if len(tiles) > MAX_TILES:
        raise SystemExit("error: %s needs %d tiles, over %d" % (airport["ident"], len(tiles), MAX_TILES))
    if source == "s2":
        mosaic = s2_picture(geo, sources_dir, os.path.splitext(os.path.basename(out_path))[0])
        tx0, ty0 = geo["x0"], geo["y0"]
    elif source == "hls":
        # Zoom-12 tiles (about 30 m), upscaled to the card's zoom.
        factor = 2 ** (zoom - HLS_ZOOM)
        sx0, sy0, sx1, sy1 = tx0 // factor, ty0 // factor, tx1 // factor, ty1 // factor
        stack = []
        for layer, day in geo["days"]:
            small = Image.new("RGBA", ((sx1 - sx0 + 1) * 256, (sy1 - sy0 + 1) * 256))
            for sx in range(sx0, sx1 + 1):
                for sy in range(sy0, sy1 + 1):
                    path = os.path.join(sources_dir, "imagery", "hls", layer, day, str(HLS_ZOOM), str(sx),
                                        "%d.png" % sy)
                    fetch(HLS_URL % (layer, day, HLS_ZOOM, sy, sx), path)
                    small.paste(Image.open(path).convert("RGBA"), ((sx - sx0) * 256, (sy - sy0) * 256))
            stack.append(np.asarray(small, dtype=np.float32))
        layers = np.stack(stack)
        rgb = np.where(layers[..., 3:4] > 0, layers[..., :3], np.nan)
        median = np.nan_to_num(np.nanmedian(rgb, axis=0), nan=0.0).astype(np.uint8)
        small = Image.fromarray(median, "RGB")
        mosaic = small.resize((small.width * factor, small.height * factor), Image.BICUBIC)
        tx0, ty0 = sx0 * factor, sy0 * factor
    else:
        mosaic = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256))
        for tx, ty in tiles:
            url = USGS_URL % (zoom, ty, tx) if source == "usgs" else EOX_URL % (zoom, ty, tx)
            path = os.path.join(sources_dir, "imagery", source, str(zoom), str(tx), "%d.jpg" % ty)
            fetch(url, path)
            mosaic.paste(Image.open(path).convert("RGB"), ((tx - tx0) * 256, (ty - ty0) * 256))
    left, top = int(round((geo["x0"] - tx0) * 256)), int(round((geo["y0"] - ty0) * 256))
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
    if earlier:
        old = [to_pixel(geo, lat, lon) for lat, lon in earlier]
        # Bounded: one dash per edge pair of a ring of at most MAX_POINTS points.
        for (ax, ay), (bx, by) in zip(old, old[1:] + old[:1]):
            for k in range(0, 10, 2):
                draw.line([(ax + (bx - ax) * k / 10, ay + (by - ay) * k / 10),
                           (ax + (bx - ax) * (k + 1) / 10, ay + (by - ay) * (k + 1) / 10)],
                          fill=(150, 235, 255), width=2)
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
    text.text((10, 38), credit_for(source, geo), fill=(200, 200, 200), font=small)
    if seed_credit:
        text.text((10, 58), seed_credit + ("   (dashed: the earlier by-eye draft)" if earlier else ""),
                  fill=(200, 200, 200), font=small)
    sheet.paste(picture, (0, BAND))
    sheet.save(out_path, optimize=True)


def main(argv):
    parser = argparse.ArgumentParser(description="Draft airport outlines and their review cards.")
    parser.add_argument("--sources", required=True)
    parser.add_argument("--tokens", default="", help="comma-separated tokens")
    parser.add_argument("--tokens-file", default="", help="a file of tokens, one per line (keep it outside the repo)")
    parser.add_argument("--out", required=True, help="a folder OUTSIDE the repo for cards and drafts")
    parser.add_argument("--corrections", default="", help="JSON of outlines traced on the cards, in card pixels")
    parser.add_argument("--imagery", choices=("open", "hls", "s2"), default="open",
                        help="open: USGS (US) or Sentinel-2 cloudless 2016; hls: NASA HLS 30 m, clearest recent day")
    parser.add_argument("--seed", choices=("runways", "public", "earlier"), default="runways",
                        help="runways: the 800 m auto-draft; public: TIGER 2015 (US) or CORINE 2018 (Europe)")
    parser.add_argument("--compare", default="", help="an earlier drafts.json whose outlines are drawn faint")
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
    compare = {}
    if args.compare:
        compare = {d["id"]: d["points"] for d in airports.read_json(args.compare).get("outlines", [])}
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
    tiger_cache = {}
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
        source = args.imagery if args.imagery in ("hls", "s2") else ("usgs" if airport["country"] == "US" else "eox")
        if token in corrections:
            old = previous.get(token)
            if old is None or "geometry" not in old:
                raise SystemExit("error: %s has corrections but no earlier card to read them against" % token)
            traced = [from_pixel(old["geometry"], x, y) for x, y in corrections[token]]
            if not (4 <= len(traced) <= MAX_POINTS):
                raise SystemExit("error: %s's traced outline has %d points (4 to %d)" % (token, len(traced),
                                                                                         MAX_POINTS))
            base = old.get("seedKind", "runways")
            ring, seed, geo = traced, "%s, corrected by eye" % old.get("seedName", "traced"), old["geometry"]
            seed_kind = base
        else:
            ends = airports.runway_ends(mine, airport, report)
            if not ends:
                print("skip %s: no runway ends to seed from" % token)
                continue
            published, seed_kind = None, "runways"
            if args.seed == "earlier" and token in compare:
                published, seed_kind = [tuple(p) for p in compare[token]], "earlier"
            elif args.seed == "public" and airport["country"] == "US":
                state = airport["region"].split("-", 1)[-1]
                if state not in tiger_cache:
                    tiger_cache[state] = tiger_rings(args.sources, state, report)
                published, seed_kind = best_ring(tiger_cache[state], airport, ends), "tiger"
            elif args.seed == "public" and airport["country"] in CORINE_COUNTRIES:
                published, seed_kind = best_ring(corine_rings(args.sources, token, airport), airport, ends), "corine"
            if published is None:
                if args.seed == "public":
                    print("note %s: no published outline holds its runways; seeded from the runways" % token)
                seed_kind = "runways"
                if token in compare:
                    ring, seed = [tuple(p) for p in compare[token]], "traced by eye (no published outline)"
                else:
                    ring, seed = simplified(runway_seed(airport, ends)), "auto-draft from runways"
            else:
                ring = simplified(published)
                seed = {"tiger": "TIGER K2451", "corine": "CORINE 124", "earlier": "earlier by-eye trace"}[seed_kind]
            geo = geometry(airport, ring + (compare.get(token) and [tuple(p) for p in compare[token]] or []), source)
            if source == "s2":
                # The tropics rarely give a scene under 5 % cloud: fall back to 30 %, checked on the card.
                geo["candidates"] = s2_scenes(airport, geo, args.sources) or s2_scenes(airport, geo, args.sources, 30)
                if not geo["candidates"]:
                    print("skip %s: no clear Sentinel-2 scene covers it" % token)
                    continue
            if source == "hls":
                geo["days"] = hls_days(airport, args.sources)
                if not geo["days"]:
                    print("skip %s: no HLS day found" % token)
                    continue
        card_path = os.path.join(args.out, "%s.png" % token)
        earlier = [tuple(p) for p in compare[token]] if token in compare and seed_kind != "runways" else None
        card(airport, ring, runways, seed, source, geo, args.sources, card_path, SEED_CREDIT[seed_kind], earlier)
        drafts[token] = {"id": token, "points": [[lat, lon] for lat, lon in ring], "imagery": credit_for(source, geo),
                         "imageryDate": {"eox": "2016", "usgs": "USGS current", "s2": geo.get("day", "")}.get(
                             source, " to ".join(sorted({d for _, d in geo.get("days", [])})[::4] or [""])),
                         "seed": seed,
                         "seedKind": seed_kind, "seedName": seed.split(",")[0], "seedCredit": SEED_CREDIT[seed_kind],
                         "geometry": geo, "card": os.path.basename(card_path), "reviewer": "", "approved": ""}
        print("%s: %d points (%s), card %s" % (token, len(ring), seed, card_path))
    with open(drafts_path + ".partial", "w", encoding="utf-8") as handle:
        json.dump({"outlines": [drafts[k] for k in sorted(drafts)]}, handle, ensure_ascii=False, indent=1)
    os.replace(drafts_path + ".partial", drafts_path)
    print("%d drafts in %s" % (len(drafts), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

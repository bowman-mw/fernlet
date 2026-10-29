#!/usr/bin/env python3
"""Build Fernlet's bundled World atlas pack from the pinned sources (Docs/World-Atlas-Pack.md).

Build machine only; the app never fetches anything. Fetch the sources first with
Scripts/world-atlas/fetch-sources.sh, then:

    python3 -I Scripts/world-atlas/build_world_atlas.py --sources <dir> \
        --out App/Fernlet/World/Atlas/WorldAtlas.pack [--date 2026-10-29]

Python 3.9 standard library + numpy + Pillow only (no shapely, GDAL or pyshp). The shapefiles are read
straight out of their zips. Same sources and options give the same bytes for one zlib build: nothing in
the pack depends on the clock except the --date string (default "unset").

Bounds: every loop runs over a finite input (records, rings, grid rows, a fixed offset table) or carries
an explicit cap; nothing recurses.
"""

import argparse
import hashlib
import io
import json
import os
import re
import struct
import sys
import zipfile
import zlib


def _import_numpy_and_pillow():
    """numpy and Pillow, from the user's site-packages when `python3 -I` hides it (appended last, so the
    isolation from the working directory and PYTHONPATH still holds)."""
    try:
        import numpy
        from PIL import Image
    except ImportError:
        import site
        user_site = site.getusersitepackages()
        if user_site not in sys.path:
            sys.path.append(user_site)
        try:
            import numpy
            from PIL import Image
        except ImportError as error:
            raise SystemExit("error: the atlas generator needs numpy and Pillow (%s)" % error)
    return numpy, Image


np, Image = _import_numpy_and_pillow()

GENERATOR_VERSION = 1
PACK_VERSION = 1
MAGIC = b"FWA1"
SUB = 16
DEFAULT_ROWS = 1800
SIZE_CAP = 6_291_456
RAW_SECTION_CAP = 64 * 1024 * 1024
SIMPLIFY_DEGREES = 0.001
SCALE = 100_000
FILL_RADIUS = 5
MIN_SEA_CELLS = 3
MAX_SEAS = 250
SEA_CODE_BASE = 6

SOURCE_LICENCES = {
    "ne_10m_land": "public domain (Natural Earth)",
    "ne_10m_minor_islands": "public domain (Natural Earth)",
    "ne_10m_coastline": "public domain (Natural Earth)",
    "ne_10m_geography_marine_polys": "public domain (Natural Earth)",
    "ne_10m_admin_0_countries": "public domain (Natural Earth)",
    "ne_10m_populated_places": "public domain (Natural Earth)",
    "ne_10m_urban_areas": "public domain (Natural Earth)",
    "Beck_KG_V1": "CC BY 4.0 (Beck et al. 2018, Scientific Data 5:180214)",
}
BECK_MEMBER = "Beck_KG_V1_present_0p083.tif"

OCEAN_KEYWORDS = (("pacific", 1), ("atlantic", 2), ("indian", 3), ("arctic", 4), ("southern", 5))
OCEAN_TOKENS = {1: "pacific", 2: "atlantic", 3: "indian", 4: "arctic", 5: "southern"}

# Large gulfs and bays that count as seas of their own (Docs/World-Atlas-Pack.md, OCEA rule 2).
PROMOTED_SEAS = ("Gulf of Mexico", "Hudson Bay", "Bay of Bengal", "Persian Gulf")

# A sea whose water the 0.1° grid cuts off from every ocean keeps this parent (and stays a sea); any other
# cut-off sea is water not joined to the sea (the Caspian) and gets 0. Used only when the flood finds no
# ocean: the flood decides every joined sea.
SEA_PARENT_FALLBACK = {
    "baltic sea": 2, "black sea": 2, "sea of azov": 2, "sea of marmara": 2, "mediterranean sea": 2,
    "white sea": 4, "red sea": 3, "persian gulf": 3, "gulf of mexico": 2, "hudson bay": 4, "bay of bengal": 3,
}

CONTINENT_CODES = {"africa": 1, "antarctica": 2, "asia": 3, "europe": 4, "north america": 5, "oceania": 6,
                   "south america": 7}
# Natural Earth files these under "Seven seas (open ocean)"; the continent each counts toward (UN M49).
SEVEN_SEAS_CONTINENT = {"MV": 3, "IO": 3, "MU": 1, "SC": 1, "SH": 1, "TF": 1, "GS": 7, "HM": 6}
# Features whose ISO_A2_EH is -99, by ADM0_A3, counted as the territory the UN recognises there.
EH_FALLBACK = {"SOL": "SO", "CYN": "CY", "CNM": "CY", "KAB": "KZ"}

LANDMASS_OVERRIDES = (
    "RU: Asia east of 60°E (and across the antimeridian), else Europe",
    "TR: Europe north of the Dardanelles–Marmara–Bosporus line (Thrace), else Asia (Anatolia)",
    "EG: Asia east of the Suez Canal and the Gulf of Suez (Sinai), else Africa",
    "US: Oceania west of 150°W between 15°N and 32°N (Hawaii)",
    "FR: French Guiana South America; Guadeloupe, Martinique North America; Réunion, Mayotte Africa",
    "NL: Caribbean Netherlands North America",
)

UN_MEMBERS = (
    "AF AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BY BE BZ BJ BT BO BA BW BR BN BG BF BI CV KH CM CA CF TD CL "
    "CN CO KM CG CD CR CI HR CU CY CZ KP DK DJ DM DO EC EG SV GQ ER EE SZ ET FJ FI FR GA GM GE DE GH GR GD GT "
    "GN GW GY HT HN HU IS IN ID IR IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MG MW MY MV "
    "ML MT MH MR MU MX FM MC MN ME MA MZ MM NA NR NP NL NZ NI NE NG MK NO OM PK PW PA PG PY PE PH PL PT QA KR "
    "MD RO RU RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SB SO ZA SS ES LK SD SR SE CH SY TJ TH TL TG TO TT "
    "TN TR TM TV UG UA AE GB TZ US UY UZ VU VE VN YE ZM ZW"
).split()
THE_195 = frozenset(UN_MEMBERS) | {"VA", "PS"}
assert len(set(UN_MEMBERS)) == 193 and len(THE_195) == 195, "the 195 table is wrong"

ALPHA2 = re.compile(r"^[A-Z]{2}$")
WIKIDATA = re.compile(r"^Q[0-9]+$")


class Report:
    """What the run found worth telling the owner: notes, unmapped data and the sea list."""

    def __init__(self):
        self.notes = []
        self.unmapped = []
        self.counts = {}
        self.seas = []
        self.sections = []

    def note(self, text):
        self.notes.append(text)

    def unmap(self, text):
        self.unmapped.append(text)


# ---------------------------------------------------------------------------------------------------------
# Sources


def read_source_table(script_dir):
    """The pinned table from fetch-sources.sh: one dict per source (subdir, file, bytes, need, sha, url)."""
    path = os.path.join(script_dir, "fetch-sources.sh")
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    rows = []
    inside = False
    for line in lines:
        if line.startswith("read -r -d '' SOURCES <<'TABLE'"):
            inside = True
            continue
        if inside and line == "TABLE":
            break
        if inside and line.strip():
            parts = line.split("|")
            if len(parts) != 6:
                raise SystemExit("error: bad source table line in fetch-sources.sh: %r" % line)
            rows.append(dict(zip(("subdir", "file", "bytes", "need", "sha", "url"), parts)))
    if len(rows) != 8:
        raise SystemExit("error: fetch-sources.sh lists %d sources, not 8" % len(rows))
    return rows


def sha256_file(path):
    """The file's SHA-256, read in 1 MiB blocks."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def locate_sources(source_dir, table, verify, report):
    """Each present source's path and hash, keyed by subdir. A required one missing, or (with verify) one
    that differs from its pin, stops the run."""
    found = {}
    for row in table:
        path = os.path.join(source_dir, row["subdir"], row["file"])
        if not os.path.isfile(path):
            if row["need"] == "required":
                raise SystemExit("error: missing source %s (run fetch-sources.sh)" % path)
            report.note("optional source %s not present" % row["file"])
            continue
        digest = sha256_file(path)
        if row["sha"] == "UNPINNED":
            report.note("source %s is UNPINNED in fetch-sources.sh (sha256 %s)" % (row["file"], digest))
        elif digest != row["sha"]:
            if verify:
                raise SystemExit("error: %s sha256 %s is not the pinned %s" % (row["file"], digest, row["sha"]))
            report.note("source %s differs from its pin (unverified run)" % row["file"])
        found[row["subdir"]] = {"path": path, "sha256": digest, "file": row["file"], "url": row["url"]}
    return found


# ---------------------------------------------------------------------------------------------------------
# Shapefiles, read straight out of their zips


def zip_member(names, suffix):
    """The one member whose name ends with `suffix` (case-insensitive, macOS resource forks skipped)."""
    hits = [n for n in names if n.lower().endswith(suffix) and "__macosx" not in n.lower()]
    if len(hits) > 1:
        raise SystemExit("error: more than one *%s in a source zip: %s" % (suffix, hits))
    return hits[0] if hits else None


def parse_shp(data):
    """Geometries in record order: None, ("point", x, y) or ("polygon", [rings as (n, 2) float64])."""
    if len(data) < 100 or struct.unpack(">i", data[0:4])[0] != 9994:
        raise SystemExit("error: not a shapefile (.shp header)")
    end = min(len(data), struct.unpack(">i", data[24:28])[0] * 2)
    geoms = []
    pos = 100
    for _ in range((end - 100) // 12 + 1):
        if pos + 8 > end:
            break
        length = struct.unpack(">i", data[pos + 4:pos + 8])[0] * 2
        body = data[pos + 8:pos + 8 + length]
        pos += 8 + length
        if len(body) < 4 or len(body) != length:
            raise SystemExit("error: truncated shapefile record")
        geoms.append(parse_shape(body))
    return geoms


def parse_shape(body):
    """One shapefile record's geometry (points and polygons, with or without Z/M)."""
    shape_type = struct.unpack("<i", body[:4])[0]
    if shape_type == 0:
        return None
    if shape_type in (1, 11, 21):
        x, y = struct.unpack("<dd", body[4:20])
        return ("point", x, y)
    if shape_type not in (5, 15, 25):
        raise SystemExit("error: unsupported shape type %d" % shape_type)
    parts_count, points_count = struct.unpack("<ii", body[36:44])
    parts = np.frombuffer(body, "<i4", parts_count, 44).astype(np.int64)
    points = np.frombuffer(body, "<f8", points_count * 2, 44 + 4 * parts_count).reshape(points_count, 2)
    bounds = list(parts) + [points_count]
    rings = []
    for i in range(parts_count):
        ring = np.array(points[bounds[i]:bounds[i + 1]], dtype=np.float64)
        if len(ring) >= 3:
            rings.append(close_ring(ring))
    return ("polygon", rings)


def close_ring(ring):
    """The ring with its first point repeated at the end when the source left it open."""
    if ring[0, 0] != ring[-1, 0] or ring[0, 1] != ring[-1, 1]:
        return np.vstack([ring, ring[:1]])
    return ring


def parse_dbf(data, encoding, report, label):
    """Records as dicts keyed by upper-case field name (None for a deleted record)."""
    if len(data) < 32:
        raise SystemExit("error: not a dBASE file")
    count = struct.unpack("<I", data[4:8])[0]
    header_len, record_len = struct.unpack("<HH", data[8:12])
    fields = []
    for i in range((header_len - 33) // 32 + 1):
        pos = 32 + 32 * i
        if pos >= header_len or data[pos] == 0x0D:
            break
        name = data[pos:pos + 11].split(b"\0")[0].decode("ascii").upper()
        fields.append((name, chr(data[pos + 11]), data[pos + 16], data[pos + 17]))
    records = []
    fallbacks = 0
    for i in range(count):
        raw = data[header_len + i * record_len:header_len + (i + 1) * record_len]
        if len(raw) < record_len:
            raise SystemExit("error: truncated dBASE record")
        if raw[0:1] == b"*":
            records.append(None)
            continue
        record, fell_back = parse_dbf_record(raw, fields, encoding)
        fallbacks += fell_back
        records.append(record)
    if fallbacks:
        report.note("%s: %d text fields were not %s; read as Latin-1" % (label, fallbacks, encoding))
    return records


def parse_dbf_record(raw, fields, encoding):
    """One record's values and how many text fields needed the Latin-1 fallback."""
    record = {}
    fell_back = 0
    pos = 1
    for name, kind, length, decimals in fields:
        cell = raw[pos:pos + length]
        pos += length
        if kind in ("N", "F"):
            text = cell.strip()
            if not text or text.startswith(b"*"):
                record[name] = None
                continue
            value = float(text)
            record[name] = int(value) if decimals == 0 and value.is_integer() else value
            continue
        try:
            record[name] = cell.decode(encoding).rstrip(" \0")
        except UnicodeDecodeError:
            record[name] = cell.decode("latin-1").rstrip(" \0")
            fell_back += 1
    return record, fell_back


def read_layer(zip_path, report):
    """[(geometry, attributes)] for every live record of the zip's one shapefile."""
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        shp_name = zip_member(names, ".shp")
        dbf_name = zip_member(names, ".dbf")
        if shp_name is None or dbf_name is None:
            raise SystemExit("error: %s holds no .shp/.dbf pair" % zip_path)
        cpg_name = zip_member(names, ".cpg")
        encoding = "utf-8"
        if cpg_name is not None:
            declared = archive.read(cpg_name).decode("ascii", "replace").strip().lower().replace("utf8", "utf-8")
            encoding = declared or "utf-8"
        geoms = parse_shp(archive.read(shp_name))
        records = parse_dbf(archive.read(dbf_name), encoding, report, os.path.basename(zip_path))
    if len(geoms) != len(records):
        raise SystemExit("error: %s has %d shapes but %d records" % (zip_path, len(geoms), len(records)))
    return [(g, r) for g, r in zip(geoms, records) if r is not None]


def text_field(attrs, *names):
    """The first non-empty text among the given fields, stripped."""
    for name in names:
        value = attrs.get(name)
        if value is not None and str(value).strip() and str(value).strip() != "-99":
            return str(value).strip()
    return ""


def polygon_rings(geom):
    """A polygon geometry's rings, or [] for anything else."""
    if geom is None or geom[0] != "polygon":
        return []
    return geom[1]


# ---------------------------------------------------------------------------------------------------------
# Scanline rasterising (even-odd, sampled at cell or sub-cell centres)


def rings_edges(rings):
    """Every edge of the rings as four float64 arrays x0, y0, x1, y1."""
    if not rings:
        empty = np.zeros(0, dtype=np.float64)
        return empty, empty, empty, empty
    starts = np.concatenate([r[:-1] for r in rings])
    ends = np.concatenate([r[1:] for r in rings])
    return starts[:, 0], starts[:, 1], ends[:, 0], ends[:, 1]


def fine_row_span(y0, y1, step, nrows):
    """The first and last sample row each edge crosses (half-open in y, so a vertex counts once)."""
    ymin = np.minimum(y0, y1)
    ymax = np.maximum(y0, y1)
    first = np.floor((90.0 - ymax) / step - 0.5).astype(np.int64) + 1
    last = np.floor((90.0 - ymin) / step - 0.5).astype(np.int64)
    return np.maximum(first, 0), np.minimum(last, nrows - 1)


def parity_rows(edges, first, last, row0, nrows, ncols, step):
    """An (nrows, ncols) bool mask of the sample points inside the rings, rows row0... (even-odd)."""
    x0, y0, x1, y1 = edges
    lo = np.maximum(first, row0)
    hi = np.minimum(last, row0 + nrows - 1)
    span = hi - lo + 1
    keep = span > 0
    x0, y0, x1, y1, lo, span = x0[keep], y0[keep], x1[keep], y1[keep], lo[keep], span[keep]
    total = int(span.sum())
    edge = np.repeat(np.arange(len(span)), span)
    offsets = np.arange(total) - np.repeat(np.cumsum(span) - span, span)
    row = lo[edge] + offsets
    y = 90.0 - (row + 0.5) * step
    x = x0[edge] + (y - y0[edge]) * (x1[edge] - x0[edge]) / (y1[edge] - y0[edge])
    col = np.clip(np.ceil((x + 180.0) / step - 0.5), 0, ncols).astype(np.int64)
    key = (row - row0) * (ncols + 1) + col
    toggles = np.bincount(key, minlength=nrows * (ncols + 1)).reshape(nrows, ncols + 1)
    return (np.cumsum(toggles, axis=1)[:, :ncols] & 1).astype(bool)


class StripRasterizer:
    """One layer's edges bucketed by grid row, so the fine 1/(16·rows/180)° raster is made one row-strip
    (16 sub-rows) at a time and memory stays small."""

    def __init__(self, rings, rows, cols):
        self.cols = cols
        self.step = 180.0 / (rows * SUB)
        x0, y0, x1, y1 = rings_edges(rings)
        first, last = fine_row_span(y0, y1, self.step, rows * SUB)
        keep = first <= last
        self.edges = (x0[keep], y0[keep], x1[keep], y1[keep])
        self.first, self.last = first[keep], last[keep]
        lo_strip = self.first // SUB
        count = self.last // SUB - lo_strip + 1
        edge = np.repeat(np.arange(len(count)), count)
        strip = lo_strip[edge] + (np.arange(int(count.sum())) - np.repeat(np.cumsum(count) - count, count))
        order = np.argsort(strip, kind="stable")
        self.strip_sorted = strip[order]
        self.edge_sorted = edge[order]

    def strip(self, row):
        """The (16, cols·16) land mask of grid row `row`."""
        lo = np.searchsorted(self.strip_sorted, row, "left")
        hi = np.searchsorted(self.strip_sorted, row, "right")
        pick = self.edge_sorted[lo:hi]
        edges = tuple(a[pick] for a in self.edges)
        return parity_rows(edges, self.first[pick], self.last[pick], row * SUB, SUB, self.cols * SUB, self.step)


def raster_cells(rings, rows, cols):
    """(first row, mask) of the grid cells whose centres lie inside the rings, or None."""
    step = 180.0 / rows
    edges = rings_edges(rings)
    first, last = fine_row_span(edges[1], edges[3], step, rows)
    keep = first <= last
    if not keep.any():
        return None
    edges = tuple(a[keep] for a in edges)
    first, last = first[keep], last[keep]
    row0 = int(first.min())
    nrows = int(last.max()) - row0 + 1
    return row0, parity_rows(edges, first, last, row0, nrows, cols, step)


def paint(grid, rings, rows, cols, value, where=None):
    """Writes `value` into `grid` (rows × cols) at every cell centre inside the rings (and `where`)."""
    hit = raster_cells(rings, rows, cols)
    if hit is None:
        return 0
    row0, mask = hit
    if where is not None:
        mask = mask & where[row0:row0 + mask.shape[0]]
    grid[row0:row0 + mask.shape[0]][mask] = value
    return int(mask.sum())


def nearest_fill(values, has, need, radius, rows, cols):
    """`values` with each `need` cell lacking a value given the nearest `has` cell's value within `radius`
    cells (columns wrap round the globe, rows do not; ties go to the first offset in a fixed order)."""
    out = values.copy()
    todo = need & ~has
    offsets = sorted((dy * dy + dx * dx, dy, dx)
                     for dy in range(-radius, radius + 1) for dx in range(-radius, radius + 1)
                     if 0 < dy * dy + dx * dx <= radius * radius)
    for _, dy, dx in offsets:
        if not todo.any():
            break
        shifted_has = np.zeros_like(has)
        shifted_val = np.zeros_like(values)
        rolled_has = np.roll(has, -dx, axis=1)
        rolled_val = np.roll(values, -dx, axis=1)
        if dy >= 0:
            shifted_has[:rows - dy] = rolled_has[dy:]
            shifted_val[:rows - dy] = rolled_val[dy:]
        else:
            shifted_has[-dy:] = rolled_has[:rows + dy]
            shifted_val[-dy:] = rolled_val[:rows + dy]
        hit = todo & shifted_has
        out[hit] = shifted_val[hit]
        todo &= ~hit
    return out, todo


def cell_centres(rows, cols, flat_index):
    """Longitudes and latitudes of the given cells' centres."""
    step = 180.0 / rows
    row = flat_index // cols
    col = flat_index % cols
    return -180.0 + (col + 0.5) * step, 90.0 - (row + 0.5) * step


# ---------------------------------------------------------------------------------------------------------
# LAND


def build_land(land_rings, island_rings, rows, cols, report):
    """The state grid (0 water, 1 land, 2 coast) and the coast cells' 16×16 masks, in index order."""
    land = StripRasterizer(land_rings, rows, cols)
    islands = StripRasterizer(island_rings, rows, cols)
    state = np.zeros((rows, cols), dtype=np.uint8)
    masks = []
    for row in range(rows):
        fine = land.strip(row) | islands.strip(row)
        blocks = fine.reshape(SUB, cols, SUB)
        filled = blocks.sum(axis=(0, 2))
        state[row] = np.where(filled == 0, 0, np.where(filled == SUB * SUB, 1, 2))
        coast = np.nonzero(state[row] == 2)[0]
        if coast.size:
            bits = blocks[:, coast, :].transpose(1, 0, 2).reshape(coast.size, SUB * SUB)
            masks.append(np.packbits(bits, axis=1, bitorder="little").tobytes())
    coast_count = int((state == 2).sum())
    report.counts["coast cells"] = coast_count
    report.counts["land cells"] = int((state == 1).sum())
    body = struct.pack("<IIH", cols, rows, SUB) + state.tobytes() + struct.pack("<I", coast_count)
    return state, body + b"".join(masks)


# ---------------------------------------------------------------------------------------------------------
# CLIM


def read_climate_tif(zip_path):
    """Beck's 1/12° class raster as a uint8 array plus its west, north, x step and y step."""
    with zipfile.ZipFile(zip_path) as archive:
        name = zip_member(archive.namelist(), BECK_MEMBER.lower())
        if name is None:
            raise SystemExit("error: %s holds no %s" % (zip_path, BECK_MEMBER))
        data = archive.read(name)
    image = Image.open(io.BytesIO(data))
    raster = np.array(image)
    if raster.ndim != 2:
        raise SystemExit("error: the climate raster is not single-band")
    height, width = raster.shape
    west, north, step_x, step_y = -180.0, 90.0, 360.0 / width, 180.0 / height
    tags = getattr(image, "tag_v2", {})
    scale = tags.get(33550)
    tie = tags.get(33922)
    if scale is not None and tie is not None and len(scale) >= 2 and len(tie) >= 6:
        step_x, step_y = float(scale[0]), float(scale[1])
        west, north = float(tie[3]) - float(tie[0]) * step_x, float(tie[4]) + float(tie[1]) * step_y
    return raster, west, north, step_x, step_y


def build_climate(zip_path, state, rows, cols, report):
    """The CLIM grid: the majority class of the source cells inside each land or coast cell, else the
    nearest within 5 cells, else 0; 0 on water."""
    raster, west, north, step_x, step_y = read_climate_tif(zip_path)
    step = 180.0 / rows
    valid = (raster >= 1) & (raster <= 30)
    odd = int(((raster != 0) & ~valid).sum())
    if odd:
        report.unmap("climate: %d source cells hold a value outside 1-30 (ignored)" % odd)
    src_row, src_col = np.nonzero(valid)
    lat = north - (src_row + 0.5) * step_y
    lon = west + (src_col + 0.5) * step_x
    row = np.floor((90.0 - lat) / step).astype(np.int64)
    col = np.floor((((lon + 180.0) % 360.0)) / step).astype(np.int64) % cols
    inside = (row >= 0) & (row < rows)
    classes = raster[src_row, src_col].astype(np.int64)[inside]
    key = (row[inside] * cols + col[inside]) * 32 + classes
    unique, counts = np.unique(key, return_counts=True)
    target, cls = unique // 32, unique % 32
    order = np.lexsort((cls, -counts, target))
    target, cls = target[order], cls[order]
    _, first = np.unique(target, return_index=True)
    direct = np.zeros(rows * cols, dtype=np.uint8)
    direct[target[first]] = cls[first].astype(np.uint8)
    direct = direct.reshape(rows, cols)
    filled, missing = nearest_fill(direct, direct > 0, state != 0, FILL_RADIUS, rows, cols)
    report.counts["land/coast cells with no climate"] = int(missing.sum())
    return np.where(state != 0, filled, 0).astype(np.uint8)


# ---------------------------------------------------------------------------------------------------------
# Polygon encoding (Douglas-Peucker at 0.001°, 1e-5° integers, zigzag-LEB128 deltas)


def simplify_closed_ring(points, epsilon):
    """The closed ring thinned by Douglas-Peucker (iterative; the stack never exceeds 2n + 4 pops)."""
    n = len(points)
    if n <= 4:
        return points
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[n - 1] = True
    far = int(np.argmax(np.hypot(points[:, 0] - points[0, 0], points[:, 1] - points[0, 1])))
    if far in (0, n - 1):
        return points[keep]
    keep[far] = True
    stack = [(0, far), (far, n - 1)]
    for _ in range(2 * n + 4):
        if not stack:
            break
        i, j = stack.pop()
        if j - i < 2:
            continue
        a, b, between = points[i], points[j], points[i + 1:j]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = (dx * dx + dy * dy) ** 0.5
        if length == 0.0:
            dist = np.hypot(between[:, 0] - a[0], between[:, 1] - a[1])
        else:
            dist = np.abs(dx * (between[:, 1] - a[1]) - dy * (between[:, 0] - a[0])) / length
        worst = int(np.argmax(dist))
        if dist[worst] > epsilon:
            k = i + 1 + worst
            keep[k] = True
            stack.append((i, k))
            stack.append((k, j))
    return points[keep]


def quantize_ring(points):
    """The ring in 1e-5° integers, repeated points dropped, closed; None when fewer than 4 points remain."""
    q = np.round(points * SCALE).astype(np.int64)
    moved = np.any(np.diff(q, axis=0) != 0, axis=1)
    q = np.concatenate([q[:1], q[1:][moved]])
    if q[0, 0] != q[-1, 0] or q[0, 1] != q[-1, 1]:
        q = np.vstack([q, q[:1]])
    return q if len(q) >= 4 else None


def encoded_rings(rings, report, label):
    """The rings simplified and quantised (closed int64 arrays); rings that vanish are counted."""
    out = []
    dropped = 0
    for ring in rings:
        q = quantize_ring(simplify_closed_ring(ring, SIMPLIFY_DEGREES))
        if q is None:
            dropped += 1
        else:
            out.append(q)
    if dropped:
        report.counts["rings under 0.001° dropped (%s)" % label] = \
            report.counts.get("rings under 0.001° dropped (%s)" % label, 0) + dropped
    return out


def leb128(values):
    """Unsigned LEB128 of each uint64 value (each < 2^35, so at most 5 bytes), concatenated."""
    if values.size == 0:
        return b""
    rest = values.astype(np.uint64)
    out = np.zeros((values.size, 5), dtype=np.uint8)
    present = np.zeros((values.size, 5), dtype=bool)
    alive = np.ones(values.size, dtype=bool)
    for k in range(5):
        low = (rest & np.uint64(0x7F)).astype(np.uint8)
        rest = rest >> np.uint64(7)
        more = rest != 0
        out[:, k] = low | (more.astype(np.uint8) << 7)
        present[:, k] = alive
        alive = more
    if alive.any():
        raise SystemExit("error: a delta does not fit 5 LEB128 bytes")
    return out[present].tobytes()


def encode_ring(q):
    """u32 pointCount · first point i32 lon, i32 lat · zigzag-LEB128 deltas lon, lat."""
    deltas = np.diff(q, axis=0).ravel()
    zigzag = ((deltas << 1) ^ (deltas >> 63)).astype(np.uint64)
    return struct.pack("<Iii", len(q), int(q[0, 0]), int(q[0, 1])) + leb128(zigzag)


def encode_polygon(rings):
    """bbox (4 × i32) · u16 ringCount · rings."""
    if len(rings) > 0xFFFF:
        raise SystemExit("error: a polygon has %d rings, over u16" % len(rings))
    every = np.concatenate(rings)
    lo, hi = every.min(axis=0), every.max(axis=0)
    head = struct.pack("<iiiiH", int(lo[0]), int(lo[1]), int(hi[0]), int(hi[1]), len(rings))
    return head + b"".join(encode_ring(q) for q in rings)


class EdgeSet:
    """A polygon's stored rings as one edge list, for the generator's own even-odd point tests (on the
    same simplified integers the reader decodes)."""

    def __init__(self, rings):
        every = np.concatenate(rings) if rings else np.zeros((0, 2), dtype=np.int64)
        self.bbox = (every[:, 0].min(), every[:, 1].min(), every[:, 0].max(), every[:, 1].max()) \
            if len(every) else (1, 1, 0, 0)
        starts = np.concatenate([q[:-1] for q in rings]).astype(np.float64) if rings else every
        ends = np.concatenate([q[1:] for q in rings]).astype(np.float64) if rings else every
        self.x0, self.y0, self.x1, self.y1 = starts[:, 0], starts[:, 1], ends[:, 0], ends[:, 1]

    def contains(self, x, y):
        """Whether the integer point lies inside (even-odd)."""
        if not (self.bbox[0] <= x <= self.bbox[2] and self.bbox[1] <= y <= self.bbox[3]):
            return False
        cross = (self.y0 > y) != (self.y1 > y)
        if not cross.any():
            return False
        x0, y0, x1, y1 = self.x0[cross], self.y0[cross], self.x1[cross], self.y1[cross]
        at = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
        return bool(int((x < at).sum()) & 1)


# ---------------------------------------------------------------------------------------------------------
# Countries: CTRY and CONT


def country_features(features, report):
    """One dict per admin-0 feature: alpha-2 (or None), sovereign, continent, rings."""
    items = []
    for geom, attrs in features:
        raw = text_field(attrs, "ISO_A2_EH", "ISO_A2").upper()
        a3 = text_field(attrs, "ADM0_A3").upper()
        code = raw if ALPHA2.match(raw) else EH_FALLBACK.get(a3)
        name = text_field(attrs, "ADMIN", "NAME")
        if code is None:
            report.unmap("country %s (%s): no ISO_A2_EH, left out of CTRY" % (name, a3 or "?"))
        elif not ALPHA2.match(raw):
            report.note("country %s (%s) counted as %s" % (name, a3, code))
        continent_name = text_field(attrs, "CONTINENT").lower()
        continent = CONTINENT_CODES.get(continent_name, 0)
        if continent == 0 and code in SEVEN_SEAS_CONTINENT:
            continent = SEVEN_SEAS_CONTINENT[code]
        if continent == 0:
            report.unmap("country %s: continent %r unmapped" % (name, continent_name))
        items.append({"code": code, "own": code is not None and code == raw, "admin": name,
                      "sovereignt": text_field(attrs, "SOVEREIGNT"), "continent": continent,
                      "rings": polygon_rings(geom)})
    home = {}
    for item in items:
        if item["code"] is not None and item["admin"] == item["sovereignt"] and item["admin"] not in home:
            home[item["admin"]] = item["code"]
    for item in items:
        item["sovereign"] = home.get(item["sovereignt"], item["code"])
        if item["code"] is not None and item["sovereignt"] not in home:
            report.unmap("country %s: sovereign %r has no feature of its own; counts as itself"
                         % (item["admin"], item["sovereignt"]))
    return items


def build_ctry(items, report):
    """The CTRY section and its entries (code, sovereign, EdgeSet), sorted by code."""
    groups = {}
    for item in items:
        if item["code"] is not None:
            groups.setdefault(item["code"], []).append(item)
    entries = []
    blobs = []
    ring_total = 0
    for code in sorted(groups):
        members = groups[code]
        primary = next((m for m in members if m["own"]), members[0])
        rings = []
        for member in members:
            rings.extend(encoded_rings(member["rings"], report, "countries"))
        if not rings:
            report.unmap("country %s: no ring survives simplification" % code)
            continue
        flags = 1 if code in THE_195 else 0
        head = struct.pack("<2s2sBB", code.encode("ascii"), primary["sovereign"].encode("ascii"),
                           primary["continent"], flags)
        blobs.append(head + encode_polygon(rings))
        entries.append((code, primary["sovereign"], EdgeSet(rings)))
        ring_total += len(rings)
    report.counts["countries"] = len(entries)
    report.counts["of the 195"] = sum(1 for e in entries if e[0] in THE_195)
    report.counts["country rings"] = ring_total
    missing = sorted(THE_195 - {e[0] for e in entries})
    if missing:
        report.unmap("the 195 with no polygon: %s" % " ".join(missing))
    return struct.pack("<H", len(entries)) + b"".join(blobs), entries


def build_cont(items, state, rows, cols, report):
    """The CONT grid from the country under each land or coast cell (nearest within 5 cells for a coast
    cell whose centre is at sea), with the landmass overrides."""
    owner = np.full((rows, cols), -1, dtype=np.int32)
    for index, item in enumerate(items):
        paint(owner, item["rings"], rows, cols, index, where=owner < 0)
    owner, _ = nearest_fill(owner, owner >= 0, state != 0, FILL_RADIUS, rows, cols)
    continents = np.array([item["continent"] for item in items] + [0], dtype=np.uint8)
    codes = np.array([item["code"] or "" for item in items] + [""])
    flat = owner.ravel()
    flat = np.where(flat < 0, len(items), flat)
    cont = continents[flat].copy()
    cell_codes = codes[flat]
    apply_landmass_overrides(cont, cell_codes, rows, cols)
    cont[state.ravel() == 0] = 0
    report.counts["land/coast cells with no continent"] = int(((state.ravel() != 0) & (cont == 0)).sum())
    return cont.reshape(rows, cols)


def apply_landmass_overrides(cont, cell_codes, rows, cols):
    """Moves the cells of Russia, Turkey, Egypt, the US, France and the Netherlands that lie on another
    landmass to that landmass's continent (LANDMASS_OVERRIDES)."""
    def cells(code):
        index = np.nonzero(cell_codes == code)[0]
        lon, lat = cell_centres(rows, cols, index)
        return index, lon, lat

    index, lon, lat = cells("RU")
    cont[index] = np.where((lon > 60.0) | (lon < 0.0), 3, 4)
    index, lon, lat = cells("TR")
    line = np.interp(lon, [26.15, 26.68, 27.0, 28.0, 29.05], [40.0, 40.40, 40.5, 40.55, 40.6])
    cont[index] = np.where((lon < 29.05) & (lat > line), 4, 3)
    index, lon, lat = cells("EG")
    gulf = np.interp(lat, [27.6, 27.8, 28.3, 29.1, 29.58, 29.95], [34.0, 33.8, 33.33, 32.85, 32.53, 32.55])
    sinai = ((lat >= 29.95) & (lon > 32.34)) | ((lat >= 27.6) & (lat < 29.95) & (lon > gulf))
    cont[index] = np.where(sinai, 3, 1)
    index, lon, lat = cells("US")
    cont[index[(lon < -150.0) & (lat > 15.0) & (lat < 32.0)]] = 6
    index, lon, lat = cells("FR")
    boxes = ((-55.0, -51.0, 2.0, 6.5, 7), (-62.0, -60.5, 14.0, 16.8, 5), (55.0, 56.0, -21.6, -20.7, 1),
             (44.9, 45.4, -13.1, -12.5, 1))
    for west, east, south, north, code in boxes:
        cont[index[(lon >= west) & (lon <= east) & (lat >= south) & (lat <= north)]] = code
    index, lon, lat = cells("NL")
    cont[index[(lon >= -69.0) & (lon <= -62.0) & (lat >= 11.5) & (lat <= 18.5)]] = 5


# ---------------------------------------------------------------------------------------------------------
# OCEA and SEAS


def ocean_code(name):
    """1-5 for an ocean's name, 0 when no keyword matches."""
    lowered = name.lower()
    for keyword, code in OCEAN_KEYWORDS:
        if keyword in lowered:
            return code
    return 0


def sea_groups(features, report):
    """The seas: featurecla `sea` polygons plus the promoted gulfs and bays, merged when they share a name
    or a Wikidata ID. Each group: token, names, rings."""
    promoted = {name.lower(): name for name in PROMOTED_SEAS}
    found = set()
    candidates = []
    for geom, attrs in features:
        kind = text_field(attrs, "FEATURECLA").lower()
        english = text_field(attrs, "NAME_EN", "NAME")
        names = {text_field(attrs, "NAME").lower(), english.lower()}
        hit = sorted(names & set(promoted))
        if kind == "ocean" or (kind != "sea" and not hit):
            continue
        found.update(hit)
        if not english:
            report.unmap("an unnamed sea polygon (ne_id %s) left to the flood" % attrs.get("NE_ID"))
            continue
        candidates.append({"english": english, "wikidata": text_field(attrs, "WIKIDATAID"),
                           "ne_id": attrs.get("NE_ID"), "attrs": attrs, "rings": polygon_rings(geom)})
    for key in sorted(set(promoted) - found):
        report.unmap("promoted sea %r not found in the marine polygons" % promoted[key])
    return merge_sea_candidates(candidates)


def merge_sea_candidates(candidates):
    """Union-find over shared English names and Wikidata IDs; one group per sea, sorted by name."""
    parent = list(range(len(candidates)))

    def root(i):
        for _ in range(len(parent)):
            if parent[i] == i:
                break
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    first_by_key = {}
    for i, cand in enumerate(candidates):
        for key in ("n:" + cand["english"].lower(), "w:" + cand["wikidata"] if cand["wikidata"] else None):
            if key is None:
                continue
            if key in first_by_key:
                parent[root(i)] = root(first_by_key[key])
            else:
                first_by_key[key] = i
    members = {}
    for i in range(len(candidates)):
        members.setdefault(root(i), []).append(candidates[i])
    groups = []
    for group in members.values():
        group.sort(key=lambda c: (c["ne_id"] if isinstance(c["ne_id"], int) else 1 << 62, c["english"]))
        wikidata = next((c["wikidata"] for c in group if WIKIDATA.match(c["wikidata"])), "")
        token = wikidata or "ne:%s" % group[0]["ne_id"]
        lead = group[0]["attrs"]
        english = group[0]["english"]
        groups.append({"token": token, "english": english, "es": text_field(lead, "NAME_ES"),
                       "fr": text_field(lead, "NAME_FR"), "de": text_field(lead, "NAME_DE"),
                       "rings": [r for c in group for r in c["rings"]], "polygons": len(group)})
    groups.sort(key=lambda g: (g["english"].lower(), g["token"]))
    return groups


def flood(label, water, rows, cols):
    """Multi-source breadth-first flood through water and coast cells: every unlabelled one takes the
    label of the nearest labelled cell by water (4-neighbour; columns wrap). Returns each cell's distance
    (-1 where nothing reached). At most rows·cols steps."""
    dist = np.full(rows * cols, -1, dtype=np.int32)
    frontier = np.nonzero(label > 0)[0]
    dist[frontier] = 0
    for step in range(1, rows * cols + 1):
        if frontier.size == 0:
            break
        row, col = frontier // cols, frontier % cols
        up, down = row > 0, row < rows - 1
        near = np.concatenate([frontier[up] - cols, frontier[down] + cols,
                               row * cols + (col - 1) % cols, row * cols + (col + 1) % cols])
        source = np.concatenate([label[frontier[up]], label[frontier[down]], label[frontier], label[frontier]])
        open_cell = water[near] & (label[near] == 0)
        near, source = near[open_cell], source[open_cell]
        if near.size == 0:
            break
        order = np.lexsort((source, near))
        near, source = near[order], source[order]
        near, first = np.unique(near, return_index=True)
        label[near] = source[first]
        dist[near] = step
        frontier = near
    return dist


def label_distances(label, dist, rows, cols, count):
    """All-pairs water distance between labels, from the borders where their flooded regions touch
    (Floyd-Warshall over at most `count` labels)."""
    big = np.int64(1 << 40)
    weight = np.full(count * count, big, dtype=np.int64)
    grid, depth = label.reshape(rows, cols).astype(np.int64), dist.reshape(rows, cols).astype(np.int64)
    pairs = ((grid, np.roll(grid, -1, axis=1), depth, np.roll(depth, -1, axis=1)),
             (grid[:-1], grid[1:], depth[:-1], depth[1:]))
    for a, b, da, db in pairs:
        touch = (a > 0) & (b > 0) & (a != b)
        a, b, w = a[touch], b[touch], (da + db + 1)[touch]
        np.minimum.at(weight, a * count + b, w)
        np.minimum.at(weight, b * count + a, w)
    weight = weight.reshape(count, count)
    np.fill_diagonal(weight, 0)
    for k in range(count):
        weight = np.minimum(weight, weight[:, k:k + 1] + weight[k:k + 1, :])
    return weight, big


def build_oceans(features, state, rows, cols, report):
    """The OCEA grid and the SEAS section (Docs/World-Atlas-Pack.md rules 1-3)."""
    water = (state != 1).ravel()
    label = np.zeros(rows * cols, dtype=np.int32)
    grid = label.reshape(rows, cols)
    where = water.reshape(rows, cols)
    for geom, attrs in features:
        if text_field(attrs, "FEATURECLA").lower() != "ocean":
            continue
        name = text_field(attrs, "NAME_EN", "NAME")
        code = ocean_code(name)
        if code == 0:
            report.unmap("ocean polygon %r matches no ocean; left to the flood" % name)
            continue
        paint(grid, polygon_rings(geom), rows, cols, code, where=where)
    groups = sea_groups(features, report)
    kept = []
    for group in groups:
        group["id"] = SEA_CODE_BASE + len(kept)
        seeds = paint(grid, group["rings"], rows, cols, group["id"], where=where)
        if seeds < MIN_SEA_CELLS:
            grid[grid == group["id"]] = 0
            report.note("sea %s (%s) has %d cells; dropped into its neighbour" % (group["english"],
                                                                                  group["token"], seeds))
            continue
        kept.append(group)
    dist = flood(label, water, rows, cols)
    return finish_seas(kept, label, dist, water, rows, cols, report)


def finish_seas(kept, label, dist, water, rows, cols, report):
    """Parents from the flood, cut-off seas dropped (unless SEA_PARENT_FALLBACK names them), seas
    renumbered 6 + i, and the SEAS bytes."""
    count = SEA_CODE_BASE + len(kept)
    weight, big = label_distances(label, dist, rows, cols, count)
    remap = np.zeros(count, dtype=np.int64)
    remap[1:SEA_CODE_BASE] = np.arange(1, SEA_CODE_BASE)
    final = []
    for group in kept:
        reach = weight[group["id"], 1:SEA_CODE_BASE]
        if reach.min() < big:
            group["parent"] = int(np.argmin(reach)) + 1
        elif group["english"].lower() in SEA_PARENT_FALLBACK:
            group["parent"] = SEA_PARENT_FALLBACK[group["english"].lower()]
            report.note("sea %s reaches no ocean on the grid; parent from the fixed table" % group["english"])
        else:
            report.note("sea %s (%s) is not joined to any ocean; its water stays 0" % (group["english"],
                                                                                     group["token"]))
            continue
        remap[group["id"]] = SEA_CODE_BASE + len(final)
        final.append(group)
    if len(final) > MAX_SEAS:
        raise SystemExit("error: %d seas, over the pack's %d" % (len(final), MAX_SEAS))
    ocea = remap[label].astype(np.uint8)
    blobs = [struct.pack("<H", len(final))]
    for index, group in enumerate(final):
        cells = int((ocea == SEA_CODE_BASE + index).sum())
        report.seas.append((SEA_CODE_BASE + index, group["token"], group["english"],
                            OCEAN_TOKENS[group["parent"]], cells, group["polygons"]))
        blobs.append(short_text(group["token"], report) + struct.pack("<B", group["parent"])
                     + names_blob(group["english"], group["es"], group["fr"], group["de"], report))
    for code, token in OCEAN_TOKENS.items():
        report.counts["ocean cells: %s" % token] = int((ocea == code).sum())
    report.counts["water/coast cells joined to no ocean or sea"] = int((water & (ocea == 0)).sum())
    return ocea.reshape(rows, cols), b"".join(blobs)


def short_text(text, report):
    """u8 length · UTF-8 bytes, cut at a character boundary to 255 bytes (logged)."""
    raw = text.encode("utf-8")
    if len(raw) > 255:
        report.unmap("text cut to 255 bytes: %r" % text[:40])
        raw = raw[:255].decode("utf-8", "ignore").encode("utf-8")
    return struct.pack("<B", len(raw)) + raw


def names_blob(english, spanish, french, german, report):
    """The four names; a translation equal to the English one (or missing) is stored empty."""
    parts = [short_text(english, report)]
    for other in (spanish, french, german):
        parts.append(short_text("" if other == english else other, report))
    return b"".join(parts)


# ---------------------------------------------------------------------------------------------------------
# URBN and CITY


def city_size(population):
    """0 town, 1 city (≥ 100k), 2 large (≥ 1M), 3 mega (≥ 10M)."""
    if population >= 10_000_000:
        return 3
    if population >= 1_000_000:
        return 2
    if population >= 100_000:
        return 1
    return 0


def build_cities(place_features, urban_features, countries, report):
    """The URBN and CITY sections: urban polygons holding a city, and every populated place."""
    urban = []
    for geom, _ in urban_features:
        rings = encoded_rings(polygon_rings(geom), report, "urban areas")
        if rings:
            urban.append((rings, EdgeSet(rings)))
    boxes = np.array([u[1].bbox for u in urban], dtype=np.float64).reshape(-1, 4)
    cities = []
    used = set()
    holding = set()
    for geom, attrs in place_features:
        city = city_record(geom, attrs, used, countries, report)
        if city is None:
            continue
        x, y = city["lon"], city["lat"]
        near = np.nonzero((boxes[:, 0] <= x) & (boxes[:, 2] >= x) & (boxes[:, 1] <= y) & (boxes[:, 3] >= y))[0]
        city["urban"] = next((int(i) for i in near if urban[int(i)][1].contains(x, y)), -1)
        if city["urban"] >= 0:
            holding.add(city["urban"])
        cities.append(city)
    kept = sorted(holding)
    new_index = {old: new for new, old in enumerate(kept)}
    urbn = struct.pack("<I", len(kept)) + b"".join(encode_polygon(urban[i][0]) for i in kept)
    blobs = [struct.pack("<I", len(cities))]
    for city in cities:
        index = new_index.get(city["urban"], -1)
        blobs.append(short_text(city["token"], report) + struct.pack(
            "<2sBIiii", city["country"].encode("ascii"), city_size(city["population"]), city["population"],
            city["lon"], city["lat"], index) + names_blob(*city["names"], report=report))
    report.counts["urban polygons (kept / read)"] = "%d / %d" % (len(kept), len(urban))
    report.counts["cities"] = len(cities)
    report.counts["cities inside an urban polygon"] = sum(1 for c in cities if c["urban"] >= 0)
    return urbn, b"".join(blobs)


def city_record(geom, attrs, used, countries, report):
    """One populated place as a dict, or None (logged) when it has no point or no country."""
    if geom is None or geom[0] != "point":
        report.unmap("a populated place with no point (ne_id %s)" % attrs.get("NE_ID"))
        return None
    lon, lat = int(round(geom[1] * SCALE)), int(round(geom[2] * SCALE))
    name = text_field(attrs, "NAME")
    ne_id = attrs.get("NE_ID")
    token = text_field(attrs, "WIKIDATAID")
    if not WIKIDATA.match(token) or token in used:
        if token in used:
            report.note("city %s shares Wikidata %s; uses its ne_id" % (name, token))
        token = "ne:%s" % ne_id
    if token in used:
        report.unmap("city %s: duplicate token %s, left out" % (name, token))
        return None
    used.add(token)
    country = next((code for code, _, edges in countries if edges.contains(lon, lat)), None)
    if country is None:
        fallback = text_field(attrs, "ISO_A2").upper()
        country = fallback if ALPHA2.match(fallback) else None
        if country is None:
            report.unmap("city %s (%s): in no country's rings and no ISO_A2" % (name, token))
            return None
        report.counts["cities placed by ISO_A2 (outside the simplified rings)"] = \
            report.counts.get("cities placed by ISO_A2 (outside the simplified rings)", 0) + 1
    population = attrs.get("POP_MAX")
    population = max(0, min(int(population), 0xFFFFFFFF)) if isinstance(population, (int, float)) else 0
    names = (name, text_field(attrs, "NAME_ES"), text_field(attrs, "NAME_FR"), text_field(attrs, "NAME_DE"))
    return {"token": token, "country": country, "population": population, "lon": lon, "lat": lat,
            "names": names}


# ---------------------------------------------------------------------------------------------------------
# The pack


def deflate(raw):
    """Raw DEFLATE (RFC 1951, no zlib header), level 9."""
    packer = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    return packer.compress(raw) + packer.flush()


def assemble(sections, report):
    """magic · version · sectionCount · table · bodies."""
    stored = []
    for tag, raw in sections:
        if len(raw) > RAW_SECTION_CAP:
            raise SystemExit("error: section %s is %d bytes raw, over 64 MiB" % (tag, len(raw)))
        stored.append((tag, raw, deflate(raw)))
    offset = 8 + 16 * len(stored)
    head = MAGIC + struct.pack("<HH", PACK_VERSION, len(stored))
    table = b""
    for tag, raw, body in stored:
        table += struct.pack("<4sIII", tag.encode("ascii"), offset, len(body), len(raw))
        report.sections.append((tag, len(raw), len(body)))
        offset += len(body)
    return head + table + b"".join(body for _, _, body in stored)


def meta_json(args, rows, cols, sources):
    """The META section: generator version, date, grid and every source's file, URL, SHA-256, licence."""
    listed = []
    for subdir in sorted(sources):
        info = sources[subdir]
        listed.append({"file": info["file"], "url": info["url"], "sha256": info["sha256"],
                       "licence": SOURCE_LICENCES.get(subdir, "unknown")})
    meta = {"generator": "Scripts/world-atlas/build_world_atlas.py", "generatorVersion": GENERATOR_VERSION,
            "date": args.date, "grid": {"cols": cols, "rows": rows, "sub": SUB},
            "simplifyDegrees": SIMPLIFY_DEGREES, "sources": listed}
    return json.dumps(meta, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def print_summary(report, pack, out_path):
    """Everything the owner reviews: sections, counts, seas, overrides, unmapped data and the hash."""
    print("World atlas pack: %s (%d bytes, cap %d)" % (out_path, len(pack), SIZE_CAP))
    print("sections (raw -> stored bytes):")
    for tag, raw, stored in report.sections:
        print("  %s  %10d -> %9d" % (tag, raw, stored))
    print("counts:")
    for key in sorted(report.counts):
        print("  %s: %s" % (key, report.counts[key]))
    print("seas (%d; code, token, English name, parent ocean, cells, polygons merged):" % len(report.seas))
    for code, token, name, parent, cells, polygons in report.seas:
        print("  %3d  %-14s %-40s %-9s %7d  %d" % (code, token, name, parent, cells, polygons))
    print("landmass overrides (CONT):")
    for line in LANDMASS_OVERRIDES:
        print("  " + line)
    print("notes (%d):" % len(report.notes))
    for line in report.notes:
        print("  " + line)
    print("unmapped data (%d):" % len(report.unmapped))
    for line in report.unmapped:
        print("  " + line)
    print("sha256: %s" % hashlib.sha256(pack).hexdigest())


def parse_args(argv):
    """The command line."""
    parser = argparse.ArgumentParser(description="Build the World atlas pack (Docs/World-Atlas-Pack.md).")
    parser.add_argument("--sources", required=True, help="the directory fetch-sources.sh filled")
    parser.add_argument("--out", required=True, help="where to write the pack")
    parser.add_argument("--date", default="unset", help="the generation date written into META")
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS, help="grid rows (cols = 2 x rows)")
    parser.add_argument("--size-cap", type=int, default=SIZE_CAP, help="refuse a bigger pack (≤ 6 MiB)")
    parser.add_argument("--unverified-sources", action="store_true",
                        help="allow sources that differ from their pins (self-test only)")
    args = parser.parse_args(argv)
    if args.rows < 2 or args.rows > 3600:
        parser.error("--rows must be 2 to 3600")
    if args.size_cap < 1 or args.size_cap > SIZE_CAP:
        parser.error("--size-cap must be 1 to %d" % SIZE_CAP)
    return args


def main(argv):
    """Reads the sources, builds every section, refuses an oversized pack and writes it."""
    args = parse_args(argv)
    report = Report()
    rows, cols = args.rows, args.rows * 2
    table = read_source_table(os.path.dirname(os.path.abspath(__file__)))
    sources = locate_sources(args.sources, table, not args.unverified_sources, report)
    layer = lambda subdir: read_layer(sources[subdir]["path"], report)  # noqa: E731
    land_rings = [r for g, _ in layer("ne_10m_land") for r in polygon_rings(g)]
    island_rings = [r for g, _ in layer("ne_10m_minor_islands") for r in polygon_rings(g)]
    state, land = build_land(land_rings, island_rings, rows, cols, report)
    clim = build_climate(sources["Beck_KG_V1"]["path"], state, rows, cols, report)
    ocea, seas = build_oceans(layer("ne_10m_geography_marine_polys"), state, rows, cols, report)
    items = country_features(layer("ne_10m_admin_0_countries"), report)
    cont = build_cont(items, state, rows, cols, report)
    ctry, countries = build_ctry(items, report)
    urbn, city = build_cities(layer("ne_10m_populated_places"), layer("ne_10m_urban_areas"), countries, report)
    sections = [("LAND", land), ("CLIM", clim.tobytes()), ("OCEA", ocea.tobytes()), ("SEAS", seas),
                ("CONT", cont.tobytes()), ("CTRY", ctry), ("URBN", urbn), ("CITY", city),
                ("META", meta_json(args, rows, cols, sources))]
    pack = assemble(sections, report)
    print_summary(report, pack, args.out)
    if len(pack) > args.size_cap:
        print("error: the pack is %d bytes, over the %d-byte cap; nothing written" % (len(pack), args.size_cap),
              file=sys.stderr)
        return 1
    folder = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(folder, exist_ok=True)
    partial = args.out + ".partial"
    with open(partial, "wb") as handle:
        handle.write(pack)
    os.replace(partial, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

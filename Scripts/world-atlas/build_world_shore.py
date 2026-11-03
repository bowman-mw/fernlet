#!/usr/bin/env python3
"""Builds App/Fernlet/World/Atlas/WorldShore.pack, the fog's land and water (Docs/World-Shore-Pack.md).

The pack is the contract's other half: FernletKit/Sources/WorldMapStore/WorldShoreMask.swift reads it. It is an
ODbL database built from OpenStreetMap data, so this script and its pinned inputs (fetch-shore-sources.sh) are in this
repository, and the pack itself is published as one of its release assets (Scripts/fetch-world-shore.sh).

Run on the build machine only, after fetch-shore-sources.sh. The app never fetches any of this.

Usage: build_world_shore.py [--sources DIR] [--work DIR] [--atlas PACK] [--out PACK] [--workers N] [--pylib DIR]
"""
import argparse
import datetime
import glob
import hashlib
import json
import lzma
import math
import mmap
import multiprocessing as mp
import os
import site
import struct
import sys
import time
import zlib

sys.path.append(site.getusersitepackages())
if "--pylib" in sys.argv:
    sys.path.append(sys.argv[sys.argv.index("--pylib") + 1])
import numpy as np

GENERATOR_VERSION = 1
MAGIC = b"FWS1"
FORMAT_VERSION = 1
TILES = 180 * 360
OVERVIEW_ROWS, OVERVIEW_COLS = 360, 720
SIZE_CAP = 30 * 2**20

COAST_LEVEL = 128
NEAR_WATER = (64, 2, 10_000.0)  # level, its table code, the smallest water kept in square metres (1 ha)
FAR_WATER = (32, 1, 1_000_000.0)  # (100 ha)
# Lake-heavy and lightly peopled (owner, 2026-11-02), except squares holding a place of 100,000 or more.
CUT_COUNTRIES = {"CA", "NO", "SE", "FI", "RU", "CN"}
ALASKA = {"country": "US", "min_lat": 51, "max_lon": -129}
BIG_PLACE_SIZE_CLASS = 1

# Oceans come from the coast; bays, straits and shoals are not water bodies of their own; pools are not map water.
SKIP_SUBTYPES = {"ocean", "human_made", "physical", "spring"}
SKIP_KINDS = {"water/wastewater", "wastewater/sewage", "water/fairway"}
SMALLEST_AREA = NEAR_WATER[2]
META_DTYPE = np.dtype([("x0", "f8"), ("y0", "f8"), ("x1", "f8"), ("y1", "f8"), ("area", "f8"), ("coord", "i8"),
                       ("ring", "i8"), ("rings", "i4"), ("file", "u2")])
# 256 KiB holds the largest tile, and it keeps Apple's decoder from reserving preset 6's 8 MiB window per tile.
XZ_FILTERS = [{"id": lzma.FILTER_LZMA2, "preset": 6, "dict_size": 1 << 18}]


# ---------------------------------------------------------------------------------------------------------
# Painting a polygon into a boolean grid, sampling cell centres, even-odd.


def paint(out, north, west, step, edges):
    x0, y0, x1, y1 = edges
    nrows, ncols = out.shape
    high, low = np.maximum(y0, y1), np.minimum(y0, y1)
    first = np.maximum(np.floor((north - high) / step - 0.5).astype(np.int64) + 1, 0)
    last = np.minimum(np.floor((north - low) / step - 0.5).astype(np.int64), nrows - 1)
    pick = first <= last
    if not pick.any():
        return
    x0, y0, x1, y1, first, last = x0[pick], y0[pick], x1[pick], y1[pick], first[pick], last[pick]
    span = last - first + 1
    edge = np.repeat(np.arange(len(span)), span)
    row = first[edge] + np.arange(int(span.sum())) - np.repeat(np.cumsum(span) - span, span)
    y = north - (row + 0.5) * step
    x = x0[edge] + (y - y0[edge]) * (x1[edge] - x0[edge]) / (y1[edge] - y0[edge])
    # Edges east of the window land on the clip column, so parity past the last real crossing stays right.
    col = np.clip(np.ceil((x - west) / step - 0.5), 0, ncols).astype(np.int64)
    r0, r1, c0, c1 = int(row.min()), int(row.max()), int(col.min()), int(col.max())
    width = c1 - c0 + 1
    toggles = np.bincount((row - r0) * width + (col - c0), minlength=(r1 - r0 + 1) * width).reshape(r1 - r0 + 1, width)
    parity = (np.cumsum(toggles, axis=1) & 1).astype(bool)
    stop = min(c1 + 1, ncols)
    out[r0:r1 + 1, c0:stop] |= parity[:, :stop - c0]


def ring_edges(xy, sizes):
    keep = np.ones(len(xy) - 1, dtype=bool)
    if len(sizes) > 1:
        keep[np.cumsum(sizes)[:-1] - 1] = False
    return xy[:-1, 0][keep], xy[:-1, 1][keep], xy[1:, 0][keep], xy[1:, 1][keep]


# ---------------------------------------------------------------------------------------------------------
# OSM land polygons (a shapefile).


class LandPolygons:
    def __init__(self, shp):
        self.handle = open(shp, "rb")
        self.data = mmap.mmap(self.handle.fileno(), 0, access=mmap.ACCESS_READ)
        self.offsets = np.fromfile(shp[:-4] + ".shx", dtype=">i4", offset=100).reshape(-1, 2)[:, 0].astype(np.int64) * 2

    def boxes(self):
        return np.array([struct.unpack_from("<4d", self.data, int(at) + 12) for at in self.offsets])

    def edges(self, polygon):
        at = int(self.offsets[polygon]) + 8
        nparts, npoints = struct.unpack_from("<2i", self.data, at + 36)
        parts = np.frombuffer(self.data, dtype="<i4", count=nparts, offset=at + 44)
        xy = np.frombuffer(self.data, dtype="<f8", count=npoints * 2, offset=at + 44 + 4 * nparts).reshape(-1, 2)
        sizes = np.diff(np.append(parts, npoints))
        return ring_edges(xy, sizes)


# ---------------------------------------------------------------------------------------------------------
# OSM water, as Overture's base/water GeoParquet: extracted once into flat files under the work folder.


def wkb_polygons(buf):
    order = "<" if buf[0] == 1 else ">"
    kind = struct.unpack_from(order + "I", buf, 1)[0] & 0xFF
    if kind == 3:
        return [wkb_rings(buf, 5, order)[0]]
    if kind != 6:
        return []
    count = struct.unpack_from(order + "I", buf, 5)[0]
    at, out = 9, []
    for _ in range(count):
        rings, at = wkb_rings(buf, at + 5, "<" if buf[at] == 1 else ">")
        out.append(rings)
    return out


def wkb_rings(buf, at, order):
    nrings = struct.unpack_from(order + "I", buf, at)[0]
    at += 4
    rings = []
    for _ in range(nrings):
        n = struct.unpack_from(order + "I", buf, at)[0]
        at += 4
        rings.append(np.frombuffer(buf, dtype=order + "f8", count=n * 2, offset=at).reshape(n, 2))
        at += 16 * n
    return rings, at


def ring_area(ring):
    x, y = ring[:, 0], ring[:, 1]
    raw = abs(float(np.dot(x[:-1], y[1:]) - np.dot(x[1:], y[:-1]))) / 2
    return raw * math.cos(math.radians(float(y.mean()))) * 111320.0 * 110574.0


def extract_group(table, coords, ring_file, offsets, rows, file_index, census):
    subtype, kind = table["subtype"].to_pylist(), table["class"].to_pylist()
    seasonal, level = table["is_intermittent"].to_pylist(), table["level"].to_pylist()
    bbox = table["bbox"].combine_chunks()
    xmin, xmax = bbox.field("xmin").to_numpy(zero_copy_only=False), bbox.field("xmax").to_numpy(zero_copy_only=False)
    ymin, ymax = bbox.field("ymin").to_numpy(zero_copy_only=False), bbox.field("ymax").to_numpy(zero_copy_only=False)
    box_area = (xmax - xmin) * (ymax - ymin) * np.cos(np.radians((ymin + ymax) / 2)) * 111320.0 * 110574.0
    geometry = table["geometry"].combine_chunks()
    for row in np.flatnonzero(box_area >= SMALLEST_AREA):
        key = f"{subtype[row]}/{kind[row]}"
        if subtype[row] in SKIP_SUBTYPES or key in SKIP_KINDS or seasonal[row] or (level[row] or 0) < 0:
            census["skipped"] = census.get("skipped", 0) + 1
            continue
        for rings in wkb_polygons(geometry[int(row)].as_py()):
            if not rings:
                continue
            area = ring_area(rings[0]) - sum(ring_area(r) for r in rings[1:])
            if area < SMALLEST_AREA:
                continue
            sizes = np.array([len(r) for r in rings], dtype=np.int64)
            coords.write(b"".join(np.asarray(r, dtype="<f8").tobytes() for r in rings))
            ring_file.write(sizes.tobytes())
            outer = rings[0]
            rows.append((outer[:, 0].min(), outer[:, 1].min(), outer[:, 0].max(), outer[:, 1].max(), area, offsets[0],
                         offsets[1], len(rings), file_index))
            offsets[0] += int(sizes.sum())
            offsets[1] += len(rings)
            census[key] = census.get(key, 0) + 1


def extract_file(job):
    import pyarrow.parquet as pq
    index, path, outdir = job
    source = pq.ParquetFile(path)
    metas, offsets, census = [], [0, 0], {}
    with open(f"{outdir}/{index}.coords", "wb") as coords, open(f"{outdir}/{index}.rings", "wb") as ring_file:
        for group in range(source.metadata.num_row_groups):
            rows = []
            table = source.read_row_group(group, columns=["geometry", "subtype", "class", "is_intermittent", "level", "bbox"])
            extract_group(table, coords, ring_file, offsets, rows, index, census)
            if rows:
                metas.append(np.array(rows, dtype=META_DTYPE))
    return (np.concatenate(metas) if metas else np.empty(0, dtype=META_DTYPE)), census


class Water:
    def __init__(self, folder):
        self.folder = folder
        self.meta = np.load(f"{folder}/water.meta.npy", mmap_mode="r")
        self.keys = np.load(f"{folder}/water.keys.npy", mmap_mode="r")
        self.ids = np.load(f"{folder}/water.ids.npy", mmap_mode="r")
        self.coords, self.rings = {}, {}

    def edges(self, polygon):
        row = self.meta[polygon]
        file = int(row["file"])
        if file not in self.coords:
            self.coords[file] = np.memmap(f"{self.folder}/{file}.coords", dtype="<f8", mode="r")
            self.rings[file] = np.memmap(f"{self.folder}/{file}.rings", dtype="<i8", mode="r")
        sizes = np.asarray(self.rings[file][int(row["ring"]):int(row["ring"]) + int(row["rings"])])
        start, total = int(row["coord"]), int(sizes.sum())
        xy = np.asarray(self.coords[file][2 * start:2 * (start + total)]).reshape(-1, 2)
        return ring_edges(xy, sizes)

    def in_tile(self, key):
        lo, hi = int(np.searchsorted(self.keys, key, "left")), int(np.searchsorted(self.keys, key, "right"))
        return np.asarray(self.ids[lo:hi])


def prepare_water(parquet_dir, work, workers):
    if os.path.exists(f"{work}/water.keys.npy"):
        print("water already extracted", flush=True)
        return
    files = sorted(glob.glob(f"{parquet_dir}/*.parquet"))
    if not files:
        sys.exit(f"no parquet files in {parquet_dir}: run fetch-shore-sources.sh")
    metas, census = [], {}
    with mp.Pool(workers) as pool:
        for meta, part in pool.imap_unordered(extract_file, [(i, f, work) for i, f in enumerate(files)]):
            metas.append(meta)
            for key, value in part.items():
                census[key] = census.get(key, 0) + value
    meta = np.concatenate(metas)
    # Largest first and a fixed tie order, so a tile's list is the same on every run.
    meta = meta[np.lexsort((meta["coord"], meta["file"], -meta["area"]))]
    np.save(f"{work}/water.meta.npy", meta)
    lon0, lon1 = np.floor(meta["x0"]).astype(np.int64), np.floor(meta["x1"]).astype(np.int64)
    lat0, lat1 = np.floor(meta["y0"]).astype(np.int64), np.floor(meta["y1"]).astype(np.int64)
    single = (lon0 == lon1) & (lat0 == lat1)
    keys, ids = [tile_key(lat0[single], lon0[single])], [np.flatnonzero(single)]
    for polygon in np.flatnonzero(~single):
        grid = tile_key(np.arange(lat0[polygon], lat1[polygon] + 1)[:, None], np.arange(lon0[polygon], lon1[polygon] + 1)[None, :]).ravel()
        keys.append(grid)
        ids.append(np.full(len(grid), polygon, dtype=np.int64))
    keys, ids = np.concatenate(keys), np.concatenate(ids)
    order = np.lexsort((ids, keys))
    np.save(f"{work}/water.ids.npy", ids[order])
    np.save(f"{work}/water.keys.npy", keys[order])
    json.dump(census, open(f"{work}/census.json", "w"), indent=0, sort_keys=True)
    print("water polygons", len(meta), "skipped", census.get("skipped", 0), flush=True)


def tile_key(lat, lon):
    return (lat + 90) * 360 + lon + 180


def tile_index(lat, lon):
    return (89 - lat) * 360 + (lon + 180)


# ---------------------------------------------------------------------------------------------------------
# The plan: which squares get coarser water, read from the shipped atlas so the choice is reproducible.


def atlas_section(data, wanted):
    count = struct.unpack("<H", data[6:8])[0]
    for i in range(count):
        tag, off, stored, _ = struct.unpack("<4sIII", data[8 + i * 16:24 + i * 16])
        if tag == wanted:
            return zlib.decompress(data[off:off + stored], -15)
    sys.exit(f"atlas pack has no {wanted}")


def leb(buf, at):
    value, shift = 0, 0
    while True:
        byte = buf[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return (value >> 1) ^ -(value & 1), at
        shift += 7


def tile_countries(data):
    ctry = atlas_section(data, b"CTRY")
    count, at = struct.unpack_from("<H", ctry, 0)[0], 2
    per_degree = 5
    sample = np.full((180 * per_degree, 360 * per_degree), -1, dtype=np.int16)
    codes = []
    for index in range(count):
        codes.append(ctry[at:at + 2].decode())
        at += 6 + 16
        rings = struct.unpack_from("<H", ctry, at)[0]
        at += 2
        edges = ([], [], [], [])
        for _ in range(rings):
            points = struct.unpack_from("<I", ctry, at)[0]
            lon, lat = struct.unpack_from("<ii", ctry, at + 4)
            at += 12
            xs, ys = [lon], [lat]
            for _ in range(points - 1):
                dx, at = leb(ctry, at)
                dy, at = leb(ctry, at)
                lon, lat = lon + dx, lat + dy
                xs.append(lon)
                ys.append(lat)
            xs, ys = np.array(xs) / 1e5, np.array(ys) / 1e5
            for part, value in zip(edges, (xs[:-1], ys[:-1], xs[1:], ys[1:])):
                part.append(value)
        mask = np.zeros_like(sample, dtype=bool)
        paint(mask, 90.0, -180.0, 1 / per_degree, tuple(np.concatenate(part) for part in edges))
        sample[mask] = index
    result = {}
    for lat in range(-90, 90):
        row = (89 - lat) * per_degree
        for lon in range(-180, 180):
            cell = sample[row:row + per_degree, (lon + 180) * per_degree:(lon + 181) * per_degree].ravel()
            cell = cell[cell >= 0]
            if len(cell):
                result[(lat, lon)] = codes[int(np.bincount(cell).argmax())]
    return result


def big_place_tiles(data):
    city = atlas_section(data, b"CITY")
    count, at = struct.unpack_from("<I", city, 0)[0], 4
    found = set()
    for _ in range(count):
        at += 1 + city[at]
        size_class = city[at + 2]
        at += 2 + 1 + 4
        lon, lat = struct.unpack_from("<ii", city, at)
        at += 8 + 4
        for _ in range(4):
            at += 1 + city[at]
        if size_class >= BIG_PLACE_SIZE_CLASS:
            found.add((lat // 100000, lon // 100000))
    return found


def is_cut(lat, lon, countries, big):
    if (lat, lon) in big:
        return False
    code = countries.get((lat, lon))
    if code in CUT_COUNTRIES:
        return True
    return code == ALASKA["country"] and lat >= ALASKA["min_lat"] and lon < ALASKA["max_lon"]


# ---------------------------------------------------------------------------------------------------------
# One 1-degree tile.


def encode_tile(mask, level):
    """100 cell states (0 none, 1 all, 2 mixed), then a level x level bit mask per mixed cell, as an xz stream."""
    states = bytearray(100)
    bits = []
    for row in range(10):
        for col in range(10):
            cell = mask[row * level:(row + 1) * level, col * level:(col + 1) * level]
            filled = int(cell.sum())
            states[row * 10 + col] = 0 if filled == 0 else 1 if filled == cell.size else 2
            if states[row * 10 + col] == 2:
                bits.append(np.packbits(cell, bitorder="little").tobytes())
    return lzma.compress(bytes(states) + b"".join(bits), format=lzma.FORMAT_XZ, check=lzma.CHECK_NONE, filters=XZ_FILTERS)


WORKER = {}


def init_worker(shp, work):
    WORKER["land"] = LandPolygons(shp)
    WORKER["water"] = Water(work)


def overview_shares(land):
    """Per half-degree cell of this tile (north-west first): how much is land, 0-255."""
    half = land.shape[0] // 2
    return [int(round(float(land[r * half:(r + 1) * half, c * half:(c + 1) * half].mean()) * 255)) for r in (0, 1) for c in (0, 1)]


def build_tile(job):
    lat, lon, land_ids, cut = job
    size = 10 * COAST_LEVEL
    land = np.zeros((size, size), dtype=bool)
    for polygon in land_ids:
        paint(land, lat + 1, lon, 1 / size, WORKER["land"].edges(int(polygon)))
    filled = int(land.sum())
    result = {"lat": lat, "lon": lon, "coast_kind": 0 if filled == 0 else 1 if filled == size * size else 2}
    if result["coast_kind"] == 2:
        result["coast"] = encode_tile(land, COAST_LEVEL)
    level, code, smallest = FAR_WATER if cut else NEAR_WATER
    final = land
    water_ids = WORKER["water"].in_tile(tile_key(lat, lon))
    water_ids = water_ids[np.asarray(WORKER["water"].meta["area"][water_ids]) >= smallest] if len(water_ids) else water_ids
    if filled and len(water_ids):
        cells = 10 * level
        wet = np.zeros((cells, cells), dtype=bool)
        for polygon in water_ids:
            paint(wet, lat + 1, lon, 1 / cells, WORKER["water"].edges(int(polygon)))
        stride = COAST_LEVEL // level
        wet &= land[stride // 2::stride, stride // 2::stride]  # a water cell whose centre lies at sea adds nothing
        if wet.any():
            result["water_code"] = code
            result["water"] = encode_tile(wet, level)
            final = land & ~np.repeat(np.repeat(wet, stride, axis=0), stride, axis=1)
    result["shares"] = overview_shares(final)
    return result


# ---------------------------------------------------------------------------------------------------------
# The pack.


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def raw_deflate(raw):
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    return packer.compress(raw) + packer.flush()


def write_pack(results, out_path, meta):
    coast_kind = np.zeros(TILES, dtype=np.uint8)
    water_code = np.zeros(TILES, dtype=np.uint8)
    overview = np.zeros((OVERVIEW_ROWS, OVERVIEW_COLS), dtype=np.uint8)
    by_index = {}
    for item in results:
        at = tile_index(item["lat"], item["lon"])
        by_index[at] = item
        coast_kind[at] = item["coast_kind"]
        water_code[at] = item.get("water_code", 0)
        row, col = (89 - item["lat"]) * 2, (item["lon"] + 180) * 2
        overview[row:row + 2, col:col + 2] = np.array(item["shares"], dtype=np.uint8).reshape(2, 2)
    bodies = [by_index[i]["coast"] for i in np.flatnonzero(coast_kind == 2)]
    bodies += [by_index[i]["water"] for i in np.flatnonzero(water_code != 0)]
    lengths = np.array([len(b) for b in bodies], dtype="<u4")
    table = raw_deflate(coast_kind.tobytes() + water_code.tobytes() + lengths.tobytes())
    table_raw = TILES * 2 + len(lengths) * 4
    over = raw_deflate(overview.tobytes())
    meta_bytes = json.dumps(meta, indent=1, sort_keys=True).encode()
    header = MAGIC + struct.pack("<HHIIII", FORMAT_VERSION, COAST_LEVEL, len(table), table_raw, len(over), len(meta_bytes))
    blob = header + table + over + meta_bytes + b"".join(bodies)
    if len(blob) > SIZE_CAP:
        sys.exit(f"pack would be {len(blob)} bytes, over the {SIZE_CAP} cap")
    with open(out_path, "wb") as handle:
        handle.write(blob)
    print(f"pack {len(blob)} bytes ({len(blob) / 2**20:.2f} MiB, {len(blob) / 1e6:.2f} MB): {int((coast_kind == 2).sum())} coast tiles, "
          f"{int((water_code == NEAR_WATER[1]).sum())} water at {NEAR_WATER[0]}, {int((water_code == FAR_WATER[1]).sum())} water at {FAR_WATER[0]}; "
          f"table {len(table)}, overview {len(over)}, bodies {int(lengths.sum())}", flush=True)
    print("sha256", sha256(out_path), flush=True)


def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", default=os.path.expanduser("~/Library/Caches/Fernlet/atlas-sources"))
    parser.add_argument("--work", default=os.path.expanduser("~/Library/Caches/Fernlet/shore-work"))
    parser.add_argument("--atlas", default=os.path.join(root, "App/Fernlet/World/Atlas/WorldAtlas.pack"))
    parser.add_argument("--out", default=os.path.join(root, "App/Fernlet/World/Atlas/WorldShore.pack"))
    parser.add_argument("--workers", type=int, default=7)
    parser.add_argument("--pylib", default=None)
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    args = parser.parse_args()
    shp = os.path.join(args.sources, "osm_land_polygons_split/unpacked/land-polygons-split-4326/land_polygons.shp")
    if not os.path.exists(shp):
        sys.exit(f"no {shp}: run fetch-shore-sources.sh")
    os.makedirs(args.work, exist_ok=True)
    started = time.time()
    prepare_water(os.path.join(args.sources, "overture_water_2026-10-21"), args.work, args.workers)
    atlas = open(args.atlas, "rb").read()
    countries, big = tile_countries(atlas), big_place_tiles(atlas)
    land = LandPolygons(shp)
    boxes = land.boxes()
    lat0, lat1 = np.floor(boxes[:, 1]).astype(np.int64), np.ceil(boxes[:, 3]).astype(np.int64)
    lon0, lon1 = np.floor(boxes[:, 0]).astype(np.int64), np.ceil(boxes[:, 2]).astype(np.int64)
    tiles = {}
    for polygon in range(len(boxes)):
        for lat in range(int(lat0[polygon]), max(int(lat1[polygon]), int(lat0[polygon]) + 1)):
            for lon in range(int(lon0[polygon]), max(int(lon1[polygon]), int(lon0[polygon]) + 1)):
                if -90 <= lat < 90 and -180 <= lon < 180:
                    tiles.setdefault((lat, lon), []).append(polygon)
    jobs = [(lat, lon, ids, is_cut(lat, lon, countries, big)) for (lat, lon), ids in sorted(tiles.items())]
    print("tiles", len(jobs), "cut", sum(1 for j in jobs if j[3]), flush=True)
    results = []
    with mp.Pool(args.workers, init_worker, (shp, args.work)) as pool:
        for done, item in enumerate(pool.imap_unordered(build_tile, jobs, chunksize=8), 1):
            results.append(item)
            if done % 5000 == 0:
                print(done, "of", len(jobs), round(time.time() - started), flush=True)
    meta = {
        "generator": GENERATOR_VERSION, "date": args.date,
        "licence": "Open Database License 1.0, https://opendatacommons.org/licenses/odbl/1-0/",
        "attribution": "© OpenStreetMap contributors, https://www.openstreetmap.org/copyright",
        "plan": {"coast": COAST_LEVEL, "near": {"level": NEAR_WATER[0], "smallestSquareMetres": NEAR_WATER[2]},
                 "far": {"level": FAR_WATER[0], "smallestSquareMetres": FAR_WATER[2]},
                 "farCountries": sorted(CUT_COUNTRIES) + ["US north of 51N and west of 129W"], "bigPlaceSizeClass": BIG_PLACE_SIZE_CLASS},
        "sources": ["OpenStreetMap land polygons, osmdata.openstreetmap.de, land-polygons-split-4326, data of 2026-10-31",
                    "OpenStreetMap water through Overture Maps base/water, release 2026-10-21.0"],
    }
    write_pack(results, args.out, meta)
    print("seconds", round(time.time() - started), flush=True)


if __name__ == "__main__":
    main()

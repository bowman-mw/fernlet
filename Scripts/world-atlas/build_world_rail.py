#!/usr/bin/env python3
"""Build Fernlet's bundled rail pack, WorldRail.pack, from the pinned Natural Earth sources
(Docs/World-Rail-Pack.md, Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3, §9: owner's T1 A and F3).

Build machine only; the app never fetches anything. The sources are pinned in two tables:
ne_10m_railroads in Scripts/world-atlas/fetch-rail-sources.sh, ne_10m_roads (its ferry routes) in
Scripts/world-atlas/fetch-sources.sh, the atlas's own table. Fetch them with those scripts, then:

    python3 -I Scripts/world-atlas/build_world_rail.py --sources <dir> \
        --out App/Fernlet/World/Atlas/WorldRail.pack [--date 2026-11-16]

What it keeps:
- every rail line of ne_10m_railroads (FEATURECLA "Railroad"), the world layer only;
- every ferry route: the ne_10m_roads features whose FEATURECLA is "Ferry" (routes and seasonal routes), and the
  rail layer's "Railroad ferry" features (train ferries are boats too).

Each line is thinned by Douglas-Peucker at 0.001° (about 110 m, the atlas's road tolerance), quantised to 1e-5°,
cut where its segments' start points change 1° cell, and indexed by every 1° cell its piece's box touches, so a
"line within N metres of this point" query reads only nearby segments.

Python 3.9 standard library + numpy only. Same sources and options give the same bytes for one zlib build.
Bounds: every loop runs over a finite input or carries an explicit cap; nothing recurses.
"""

import argparse
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_world_atlas as atlas  # noqa: E402  (shapefiles, Douglas-Peucker, LEB128, deflate; same folder)

np = atlas.np

GENERATOR_VERSION = 1
PACK_VERSION = 1
MAGIC = b"FWR1"
SIZE_CAP = 2_097_152
SCALE = 100_000
SIMPLIFY_DEGREES = 0.001
CELL_DEGREES = 1
CELL_COLUMNS = 360
CELL_ROWS = 180
MAX_PIECES = 400_000
MAX_PIECE_POINTS = 65_535
MAX_POINTS = 1_500_000
MAX_CELL_REFS = 2_000_000
MAX_PIECE_CELLS = 1_024
MAX_LINES = 100_000
RAIL_CLASS = "Railroad"
RAIL_FERRY_CLASS = "Railroad ferry"
FERRY_CLASS = "Ferry"

RAIL_SOURCE = "ne_10m_railroads"
ROADS_SOURCE = "ne_10m_roads"
SOURCE_LICENCES = {
    RAIL_SOURCE: "Public domain (Natural Earth)",
    ROADS_SOURCE: "Public domain (Natural Earth)",
}


class Report(atlas.Report):
    """Notes, unmapped data and counts, as the atlas generator keeps them."""


# ---------------------------------------------------------------------------------------------------------
# Sources


def read_table(path, name, expected):
    """One fetch script's pinned TABLE block: a dict per source (subdir, file, bytes, need, sha, url)."""
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    rows, inside = [], False
    for line in lines:
        if line.startswith("read -r -d '' SOURCES <<'TABLE'"):
            inside = True
            continue
        if inside and line == "TABLE":
            break
        if inside and line.strip():
            parts = line.split("|")
            if len(parts) != 6:
                raise SystemExit("error: bad source table line in %s: %r" % (name, line))
            rows.append(dict(zip(("subdir", "file", "bytes", "need", "sha", "url"), parts)))
    if len(rows) != expected:
        raise SystemExit("error: %s lists %d sources, not %d" % (name, len(rows), expected))
    return rows


def source_rows(script_dir):
    """The two rows this pack reads: the rail layer's own pin, and the roads layer's pin from the atlas table."""
    rail = read_table(os.path.join(script_dir, "fetch-rail-sources.sh"), "fetch-rail-sources.sh", 1)
    roads = [row for row in read_table(os.path.join(script_dir, "fetch-sources.sh"), "fetch-sources.sh", 14)
             if row["subdir"] == ROADS_SOURCE]
    if rail[0]["subdir"] != RAIL_SOURCE or len(roads) != 1:
        raise SystemExit("error: the pin tables do not list %s and %s" % (RAIL_SOURCE, ROADS_SOURCE))
    return rail + roads


def locate_sources(source_dir, rows, verify, report):
    """Each source's path and hash, keyed by subdir; a missing one, or (with verify) one that differs from its pin,
    stops the run."""
    found = {}
    for row in rows:
        path = os.path.join(source_dir, row["subdir"], row["file"])
        if not os.path.isfile(path):
            raise SystemExit("error: missing source %s (run the fetch script that pins it)" % path)
        digest = atlas.sha256_file(path)
        if row["sha"] == "UNPINNED":
            report.note("source %s is UNPINNED (sha256 %s)" % (row["file"], digest))
            if verify:
                raise SystemExit("error: %s is UNPINNED; pin it first" % row["file"])
        elif digest != row["sha"]:
            if verify:
                raise SystemExit("error: %s sha256 %s is not the pinned %s" % (row["file"], digest, row["sha"]))
            report.note("source %s differs from its pin (unverified run)" % row["file"])
        found[row["subdir"]] = {"path": path, "sha256": digest, "file": row["file"], "url": row["url"],
                                "subdir": row["subdir"]}
    return found


# ---------------------------------------------------------------------------------------------------------
# Lines


def quantised_lines(geom):
    """A line geometry's parts thinned at SIMPLIFY_DEGREES and quantised to 1e-5° (int64 (n, 2) lon, lat), repeated
    points dropped, each cut where a step jumps more than 180° of longitude (a line across the antimeridian)."""
    out = []
    if not geom or geom[0] != "line":
        return out
    for line in geom[1]:
        q = np.round(atlas.simplify_open_line(line, SIMPLIFY_DEGREES) * SCALE).astype(np.int64)
        moved = np.any(np.diff(q, axis=0) != 0, axis=1)
        q = np.concatenate([q[:1], q[1:][moved]])
        jumps = np.nonzero(np.abs(np.diff(q[:, 0])) > 180 * SCALE)[0]
        start = 0
        for cut in list(jumps) + [len(q) - 1]:
            part = q[start:cut + 1]
            if len(part) >= 2:
                out.append(part)
            start = cut + 1
    return out


def layer_lines(rail_features, road_features, report):
    """(rail lines, ferry lines): quantised parts in source record order."""
    rail, ferry = [], []
    skipped = 0
    for geom, attrs in rail_features:
        kind = atlas.text_field(attrs, "FEATURECLA")
        if kind == RAIL_CLASS:
            rail.extend(quantised_lines(geom))
        elif kind == RAIL_FERRY_CLASS:
            ferry.extend(quantised_lines(geom))
        else:
            skipped += 1
    ferry_routes = 0
    for geom, attrs in road_features:
        if atlas.text_field(attrs, "FEATURECLA") == FERRY_CLASS:
            ferry_routes += 1
            ferry.extend(quantised_lines(geom))
    if skipped:
        report.unmap("%d rail-layer records are neither Railroad nor Railroad ferry; left out" % skipped)
    report.counts["ferry routes from ne_10m_roads"] = ferry_routes
    if len(rail) > MAX_LINES or len(ferry) > MAX_LINES:
        raise SystemExit("error: too many lines (%d rail, %d ferry)" % (len(rail), len(ferry)))
    return rail, ferry


def cell_of(lon, lat):
    """The 1° cell key (row * 360 + column) of a point in 1e-5° integers."""
    row = min(CELL_ROWS - 1, max(0, (int(lat) + 90 * SCALE) // (CELL_DEGREES * SCALE)))
    col = ((int(lon) + 180 * SCALE) // (CELL_DEGREES * SCALE)) % CELL_COLUMNS
    return row * CELL_COLUMNS + col


def pieces_of(line):
    """The line cut into pieces whose segments all start in one cell; neighbouring pieces share their cut point."""
    homes = [cell_of(lon, lat) for lon, lat in line[:-1]]
    out, start = [], 0
    for index in range(1, len(homes) + 1):
        if index == len(homes) or homes[index] != homes[start]:
            out.append(line[start:index + 1])
            start = index
    return out


def split_long(piece):
    """The piece in runs of at most MAX_PIECE_POINTS points (sharing their cut point)."""
    if len(piece) <= MAX_PIECE_POINTS:
        return [piece]
    step = MAX_PIECE_POINTS - 1
    return [piece[i:i + MAX_PIECE_POINTS] for i in range(0, len(piece) - 1, step)]


def piece_cells(piece):
    """Every 1° cell the piece's box touches (pieces never cross the antimeridian: quantised_lines cut there)."""
    lo, hi = piece.min(axis=0), piece.max(axis=0)
    row0 = cell_of(lo[0], lo[1]) // CELL_COLUMNS
    row1 = cell_of(hi[0], hi[1]) // CELL_COLUMNS
    col0 = cell_of(lo[0], lo[1]) % CELL_COLUMNS
    col1 = cell_of(hi[0], hi[1]) % CELL_COLUMNS
    if col1 < col0:
        raise SystemExit("error: a piece crosses the antimeridian")
    count = (row1 - row0 + 1) * (col1 - col0 + 1)
    if count > MAX_PIECE_CELLS:
        raise SystemExit("error: a piece touches %d cells, over %d" % (count, MAX_PIECE_CELLS))
    return [row * CELL_COLUMNS + col for row in range(row0, row1 + 1) for col in range(col0, col1 + 1)]


def layer_pieces(lines):
    """Every line's pieces, sorted by home cell (then source order), so a cell's pieces sit together."""
    keyed = []
    for order, line in enumerate(lines):
        for piece in pieces_of(line):
            for run in split_long(piece):
                keyed.append((cell_of(run[0, 0], run[0, 1]), order, len(keyed), run))
    keyed.sort(key=lambda item: (item[0], item[1], item[2]))
    if len(keyed) > MAX_PIECES:
        raise SystemExit("error: %d pieces, over %d" % (len(keyed), MAX_PIECES))
    return [item[3] for item in keyed]


def build_lines(pieces):
    """A lines section: u32 pieceCount · per piece u16 pointCount · i32 lon · i32 lat · zigzag-LEB128 deltas."""
    out = [struct.pack("<I", len(pieces))]
    total = 0
    for q in pieces:
        deltas = np.diff(q, axis=0).ravel()
        zigzag = ((deltas << 1) ^ (deltas >> 63)).astype(np.uint64)
        out.append(struct.pack("<Hii", len(q), int(q[0, 0]), int(q[0, 1])) + atlas.leb128(zigzag))
        total += len(q)
    if total > MAX_POINTS:
        raise SystemExit("error: %d points, over %d" % (total, MAX_POINTS))
    return b"".join(out), total


def build_index(pieces):
    """An index section: u16 cellCount · per cell, keys ascending: u16 key · u32 refCount · refCount zigzag-LEB128
    deltas of ascending piece numbers (the first from zero)."""
    cells = {}
    for number, piece in enumerate(pieces):
        for key in piece_cells(piece):
            cells.setdefault(key, []).append(number)
    refs = sum(len(v) for v in cells.values())
    if refs > MAX_CELL_REFS:
        raise SystemExit("error: %d cell references, over %d" % (refs, MAX_CELL_REFS))
    out = [struct.pack("<H", len(cells))]
    for key in sorted(cells):
        numbers = np.array(cells[key], dtype=np.int64)
        deltas = np.diff(np.concatenate([[0], numbers]))
        out.append(struct.pack("<HI", key, len(numbers)) + atlas.leb128((deltas << 1).astype(np.uint64)))
    return b"".join(out), len(cells), refs


# ---------------------------------------------------------------------------------------------------------
# Pack


def assemble(sections, report):
    """magic · version · sectionCount · table · bodies (the atlas container with its own magic)."""
    stored = [(tag, raw, atlas.deflate(raw)) for tag, raw in sections]
    offset = 8 + 16 * len(stored)
    head = MAGIC + struct.pack("<HH", PACK_VERSION, len(stored))
    table = b""
    for tag, raw, body in stored:
        table += struct.pack("<4sIII", tag.encode("ascii"), offset, len(body), len(raw))
        report.sections.append((tag, len(raw), len(body)))
        offset += len(body)
    return head + table + b"".join(body for _, _, body in stored)


def meta_json(args, sources, counts):
    listed = [{"file": info["file"], "url": info["url"], "sha256": info["sha256"],
               "licence": SOURCE_LICENCES[info["subdir"]]} for _, info in sorted(sources.items())]
    meta = {"generator": "Scripts/world-atlas/build_world_rail.py", "generatorVersion": GENERATOR_VERSION,
            "date": args.date, "simplifyDegrees": SIMPLIFY_DEGREES, "cellDegrees": CELL_DEGREES,
            "counts": counts, "sources": listed}
    return json.dumps(meta, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Build the World rail pack (Docs/World-Rail-Pack.md).")
    parser.add_argument("--sources", required=True, help="the directory the fetch scripts filled")
    parser.add_argument("--out", required=True, help="where to write the pack")
    parser.add_argument("--date", default="unset", help="the generation date written into META")
    parser.add_argument("--unverified-sources", action="store_true", help="allow unpinned sources (self-test)")
    parser.add_argument("--size-cap", type=int, default=SIZE_CAP, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    report = Report()
    here = os.path.dirname(os.path.abspath(__file__))
    sources = locate_sources(args.sources, source_rows(here), not args.unverified_sources, report)
    rail_features = atlas.read_layer(sources[RAIL_SOURCE]["path"], report)
    road_features = atlas.read_layer(sources[ROADS_SOURCE]["path"], report)
    rail_lines, ferry_lines = layer_lines(rail_features, road_features, report)
    rail_pieces, ferry_pieces = layer_pieces(rail_lines), layer_pieces(ferry_lines)
    rail_raw, rail_points = build_lines(rail_pieces)
    ferry_raw, ferry_points = build_lines(ferry_pieces)
    rail_index, rail_cells, rail_refs = build_index(rail_pieces)
    ferry_index, ferry_cells, ferry_refs = build_index(ferry_pieces)
    counts = {"railLines": len(rail_lines), "railPieces": len(rail_pieces), "railPoints": rail_points,
              "railCells": rail_cells, "ferryLines": len(ferry_lines), "ferryPieces": len(ferry_pieces),
              "ferryPoints": ferry_points, "ferryCells": ferry_cells}
    report.counts.update(counts)
    report.counts["cell references (rail / ferry)"] = "%d / %d" % (rail_refs, ferry_refs)
    sections = [("RAIL", rail_raw), ("RIDX", rail_index), ("FERY", ferry_raw), ("FIDX", ferry_index),
                ("META", meta_json(args, sources, counts))]
    pack = assemble(sections, report)
    print("World rail pack: %s (%d bytes, cap %d)" % (args.out, len(pack), args.size_cap))
    print("sections (raw -> stored bytes):")
    for tag, raw, stored in report.sections:
        print("  %s  %10d -> %9d" % (tag, raw, stored))
    print("counts:")
    for key in sorted(report.counts):
        print("  %s: %s" % (key, report.counts[key]))
    print("notes (%d):" % len(report.notes))
    for line in report.notes:
        print("  " + line)
    print("unmapped data (%d):" % len(report.unmapped))
    for line in report.unmapped[:200]:
        print("  " + line)
    print("sha256: %s" % hashlib.sha256(pack).hexdigest())
    if len(pack) > min(args.size_cap, SIZE_CAP):
        print("error: the pack is %d bytes, over the %d-byte cap; nothing written"
              % (len(pack), min(args.size_cap, SIZE_CAP)), file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out + ".partial", "wb") as handle:
        handle.write(pack)
    os.replace(args.out + ".partial", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

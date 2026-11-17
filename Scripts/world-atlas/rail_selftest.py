#!/usr/bin/env python3
"""Self-test for build_world_rail.py: builds a pack from small synthetic sources, then decodes it with its own
minimal reader (nothing imported from the generator) and checks Docs/World-Rail-Pack.md's rules.

    python3 -I Scripts/world-atlas/rail_selftest.py
    python3 -I Scripts/world-atlas/rail_selftest.py --pack App/Fernlet/World/Atlas/WorldRail.pack

The second form only decodes a built pack and prints a few near-queries (a quick look at the real data).
Every line here is made up for the test. Exit 0 when every check passes.
"""

import hashlib
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import selftest as atlas_selftest  # noqa: E402  (the synthetic shapefile writer; same folder)

GENERATOR = os.path.join(HERE, "build_world_rail.py")
FAILURES = []
PASSES = [0]
METRES_PER_DEGREE = 111_320.0


def check(condition, label):
    if condition:
        PASSES[0] += 1
    else:
        FAILURES.append(label)
        print("FAIL: " + label)


# ---------------------------------------------------------------------------------------------------------
# Fixtures

RAIL_FIELDS = [("FEATURECLA", "C", 20), ("SCALERANK", "N", 4), ("CONTINENT", "C", 20)]
ROAD_FIELDS = [("FEATURECLA", "C", 20), ("TYPE", "C", 20), ("SCALERANK", "N", 4)]


def straight(lon0, lat0, lon1, lat1, steps):
    """A line from (lon0, lat0) to (lon1, lat1) with `steps` points between (thinning drops them)."""
    return [(lon0 + (lon1 - lon0) * i / (steps + 1), lat0 + (lat1 - lat0) * i / (steps + 1)) for i in range(steps + 2)]


RAILS = [
    # A straight line east along 10.5°N from 10.2°E to 13.8°E: crosses three cell borders, thinned to two points.
    ([straight(10.2, 10.5, 13.8, 10.5, 40)], {"FEATURECLA": "Railroad", "SCALERANK": 4}),
    # A zigzag in one cell whose 300 m kinks survive thinning.
    ([[(20.1, 20.1), (20.11, 20.103), (20.12, 20.1), (20.13, 20.103), (20.14, 20.1)]],
     {"FEATURECLA": "Railroad", "SCALERANK": 7}),
    # A train ferry across water: goes into the ferry layer.
    ([[(30.1, 30.1), (30.6, 30.6)]], {"FEATURECLA": "Railroad ferry", "SCALERANK": 6}),
    # A line across the antimeridian: cut there, never one piece round the world.
    ([[(179.5, 65.5), (179.9, 65.6), (-179.9, 65.7), (-179.5, 65.8)]], {"FEATURECLA": "Railroad", "SCALERANK": 6}),
    # A record of no known class: left out.
    ([[(40.1, 40.1), (40.5, 40.5)]], {"FEATURECLA": "", "SCALERANK": 6}),
]
ROADS = [
    # A ferry route, long and diagonal: indexed in every cell its box touches.
    ([[(-5.5, 50.5), (-2.5, 52.5)]], {"FEATURECLA": "Ferry", "TYPE": "Ferry Route", "SCALERANK": 7}),
    # A seasonal ferry.
    ([[(-60.2, -30.2), (-60.4, -30.4)]], {"FEATURECLA": "Ferry", "TYPE": "Ferry, seasonal", "SCALERANK": 8}),
    # A road: never in the pack.
    ([[(0.1, 0.1), (0.9, 0.9)]], {"FEATURECLA": "Road", "TYPE": "Major Highway", "SCALERANK": 3}),
]


def write_sources(folder):
    atlas_selftest.write_layer(folder, "ne_10m_railroads", 3, [s for s, _ in RAILS], RAIL_FIELDS,
                               [a for _, a in RAILS])
    atlas_selftest.write_layer(folder, "ne_10m_roads", 3, [s for s, _ in ROADS], ROAD_FIELDS,
                               [a for _, a in ROADS])


def run(sources, out, *extra):
    args = [sys.executable, "-I", GENERATOR, "--sources", sources, "--out", out, "--date", "2026-11-16",
            "--unverified-sources"] + list(extra)
    return subprocess.run(args, capture_output=True, text=True)


# ---------------------------------------------------------------------------------------------------------
# A minimal reader


class Cursor:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, fmt):
        size = struct.calcsize(fmt)
        values = struct.unpack_from(fmt, self.data, self.pos)
        self.pos += size
        return values

    def zigzag(self):
        value, shift = 0, 0
        for _ in range(10):
            byte = self.data[self.pos]
            self.pos += 1
            value |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                return (value >> 1) ^ -(value & 1)
        raise ValueError("varint")

    def at_end(self):
        return self.pos == len(self.data)


def read_pack(data):
    if data[:4] != b"FWR1":
        raise ValueError("magic")
    version, count = struct.unpack_from("<HH", data, 4)
    if version != 1:
        raise ValueError("version")
    sections = {}
    for slot in range(count):
        tag, offset, stored, raw = struct.unpack_from("<4sIII", data, 8 + 16 * slot)
        body = zlib.decompress(data[offset:offset + stored], -15)
        if len(body) != raw:
            raise ValueError("raw length")
        sections[tag.decode("ascii")] = body
    return sections


def decode_lines(body):
    c = Cursor(body)
    (count,) = c.take("<I")
    pieces = []
    for _ in range(count):
        n, lon, lat = c.take("<Hii")
        points = [(lon, lat)]
        for _ in range(n - 1):
            lon += c.zigzag()
            lat += c.zigzag()
            points.append((lon, lat))
        pieces.append(points)
    assert c.at_end()
    return pieces


def decode_index(body):
    c = Cursor(body)
    (count,) = c.take("<H")
    cells = {}
    last = -1
    for _ in range(count):
        key, refs = c.take("<HI")
        assert key > last
        last = key
        number, numbers = 0, []
        for _ in range(refs):
            number += c.zigzag()
            numbers.append(number)
        cells[key] = numbers
    assert c.at_end()
    return cells


def cell_key(lon, lat):
    row = min(179, max(0, int(math.floor(lat + 90))))
    col = int(math.floor(lon + 180)) % 360
    return row * 360 + col


def near(pieces, cells, lat, lon, metres):
    """Whether a piece passes within `metres` of (lat, lon): the cells the query box touches, then point-to-segment
    distance in a flat local frame (as WorldRail.swift does)."""
    d_lat = metres / METRES_PER_DEGREE
    d_lon = metres / (METRES_PER_DEGREE * max(0.01, math.cos(math.radians(lat))))
    rows = range(int(math.floor(max(-90, lat - d_lat) + 90)), int(math.floor(min(89.999, lat + d_lat) + 90)) + 1)
    kx = METRES_PER_DEGREE * math.cos(math.radians(lat)) / 1e5
    ky = METRES_PER_DEGREE / 1e5
    seen = set()
    for row in rows:
        for col_lon in range(int(math.floor(lon - d_lon)), int(math.floor(lon + d_lon)) + 1):
            key = row * 360 + (col_lon + 180) % 360
            for number in cells.get(key, []):
                if number in seen:
                    continue
                seen.add(number)
                previous = None
                for plon, plat in pieces[number]:
                    dx = ((plon / 1e5 - lon + 540) % 360 - 180) * 1e5 * kx
                    dy = (plat / 1e5 - lat) * 1e5 * ky
                    if previous is not None and segment_distance(previous, (dx, dy)) <= metres:
                        return True
                    previous = (dx, dy)
    return False


def segment_distance(a, b):
    ax, ay = a
    bx, by = b
    vx, vy = bx - ax, by - ay
    length = vx * vx + vy * vy
    t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * vx + ay * vy) / length))
    return math.hypot(ax + t * vx, ay + t * vy)


# ---------------------------------------------------------------------------------------------------------


def check_pack(data):
    sections = read_pack(data)
    check(sorted(sections) == ["FERY", "FIDX", "META", "RAIL", "RIDX"], "the five sections")
    rail, ferry = decode_lines(sections["RAIL"]), decode_lines(sections["FERY"])
    ridx, fidx = decode_index(sections["RIDX"]), decode_index(sections["FIDX"])
    # The straight line is thinned to its two ends: one piece (its one segment starts in one cell), indexed in
    # each of the four cells its box touches.
    straight_pieces = [n for n, p in enumerate(rail) if abs(p[0][1] - 1_050_000) < 10]
    check(len(straight_pieces) == 1 and len(rail[straight_pieces[0]]) == 2,
          "thinning drops a straight line's middle points")
    check(all(straight_pieces and straight_pieces[0] in ridx.get(cell_key(lon + 0.5, 10.5), [])
              for lon in (10, 11, 12, 13)), "a piece is indexed in every cell its box touches")
    # The zigzag's kinks cross no cell border; the antimeridian line is cut into two pieces there.
    check(sum(1 for p in rail if p[0][1] // 100_000 == 65) == 2, "a line across the antimeridian is cut there")
    zig = [p for p in rail if p[0][0] == 2_010_000]
    check(len(zig) == 1 and len(zig[0]) == 5, "kinks bigger than the tolerance survive thinning")
    check(not any(p[0][0] == 4_010_000 for p in rail + ferry), "a record of no known class is left out")
    check(not any(p[0][0] == 10_000 for p in rail + ferry), "a road is never in the pack")
    check(all(max(q[0] for q in p) - min(q[0] for q in p) < 180 * 100_000 for p in rail),
          "no piece crosses the antimeridian")
    check(len(ferry) >= 3, "ferry routes and the train ferry are in the ferry layer")
    for number, piece in enumerate(rail):
        home = cell_key(piece[0][0] / 1e5, piece[0][1] / 1e5)
        check(number in ridx.get(home, []), "piece %d is indexed in its home cell" % number)
    # Near-queries on the synthetic lines.
    check(near(rail, ridx, 10.5, 12.0, 100), "a point on the rail line is near rail")
    check(near(rail, ridx, 10.507, 12.0, 1_000), "780 m off the line is within 1 km")
    check(not near(rail, ridx, 10.507, 12.0, 500), "780 m off the line is not within 500 m")
    check(near(rail, ridx, 10.5, 11.0, 50), "a point on a cell border is near rail")
    check(not near(rail, ridx, 0.0, -140.0, 5_000), "open ocean is not near rail")
    check(near(rail, ridx, 65.55, 179.7, 2_000), "the line's west side of the antimeridian is near rail")
    check(near(rail, ridx, 65.75, -179.7, 2_000), "the line's east side of the antimeridian is near rail")
    check(near(ferry, fidx, 51.5, -4.0, 200), "the middle of a long diagonal ferry route is near a ferry")
    check(near(ferry, fidx, 30.35, 30.35, 100), "the train ferry is a ferry")
    check(not near(rail, ridx, 30.35, 30.35, 1_000), "the train ferry is not rail")
    check(near(ferry, fidx, -30.3, -60.3, 100), "a seasonal ferry is a ferry")
    check(not near(ferry, fidx, 10.5, 12.0, 1_000), "a rail line is not a ferry")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--pack":
        with open(sys.argv[2], "rb") as handle:
            data = handle.read()
        sections = read_pack(data)
        rail, ferry = decode_lines(sections["RAIL"]), decode_lines(sections["FERY"])
        ridx, fidx = decode_index(sections["RIDX"]), decode_index(sections["FIDX"])
        print("sha256", hashlib.sha256(data).hexdigest(), "bytes", len(data))
        print("pieces rail %d ferry %d" % (len(rail), len(ferry)))
        for label, lat, lon in (("Portland Union Station", 45.5289, -122.6767), ("Seattle King St", 47.5983, -122.3297),
                                ("Pacific", 0.0, -140.0), ("Dover-Calais mid", 51.05, 1.58),
                                ("Tsawwassen-Swartz Bay mid", 48.85, -123.27)):
            for metres in (250, 500, 1_000, 2_000, 5_000):
                print("%-28s %5d m  rail %-5s ferry %s" % (label, metres, near(rail, ridx, lat, lon, metres),
                                                          near(ferry, fidx, lat, lon, metres)))
        return 0
    work = tempfile.mkdtemp(prefix="rail-selftest-")
    try:
        sources = os.path.join(work, "sources")
        os.makedirs(sources)
        write_sources(sources)
        out = os.path.join(work, "WorldRail.pack")
        result = run(sources, out)
        check(result.returncode == 0, "the generator runs: " + result.stderr[-400:])
        if result.returncode == 0:
            with open(out, "rb") as handle:
                first = handle.read()
            check_pack(first)
            again = os.path.join(work, "again.pack")
            run(sources, again)
            with open(again, "rb") as handle:
                check(handle.read() == first, "the same sources give the same bytes")
        capped = os.path.join(work, "capped.pack")
        result = run(sources, capped, "--size-cap", "100")
        check(result.returncode != 0 and not os.path.exists(capped), "a pack over the cap is refused, nothing written")
        result = subprocess.run([sys.executable, "-I", GENERATOR, "--sources", sources, "--out", capped],
                                capture_output=True, text=True)
        check(result.returncode != 0 and not os.path.exists(capped), "unpinned synthetic sources are refused")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("rail self-test: %d passed, %d failed" % (PASSES[0], len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())

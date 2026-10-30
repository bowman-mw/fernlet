#!/usr/bin/env python3
"""Self-test for the World atlas generator: `python3 -I Scripts/world-atlas/selftest.py`.

Builds tiny synthetic sources (shapefiles, dBASE tables and a climate GeoTIFF, zipped the way the real
ones are) in a temporary directory, runs build_world_atlas.py on them with a 10° grid (--rows 18), then
decodes the pack with its own minimal reader (nothing imported from the generator) and checks the rules
in Docs/World-Atlas-Pack.md. Prints "selftest: all N checks passed" and exits 0, or names each failure.

The synthetic world (10° cells, 16×16 sub-cells of 0.625°):
  land "L"      lon 0..65, lat -30..30, with a lake hole lon 20..40, lat -10..10 (a "Lake Sea" polygon
                covers the lake, joined to nothing, so it must stay 0)
  land "bay"    lon 100..160, lat -40..40 with a bay cut in from the west (lon 100..130, lat -10..10)
  islands       lon -100..-96, lat 0..4 (Greenland, a territory of Denmark) and lon -50..-46, lat 40..44
                (Denmark)
  oceans        South Atlantic lon -60..0, Indian lon 70..100 (both lat -60..60)
  seas          "Test Sea" in two polygons sharing Q999 (lon -120..-60), "Gulf of Mexico" (a promoted gulf),
                "Tiny Sea" (one cell, dropped into its neighbour)
  countries     ZA = L with a hole that is LS; AU = the bay land; DK, GL; GB, IE, FR; and Crimea where it
                really is: UA's mainland (lon 30..40, lat 46..50) and RU's (lon 37..60, lat 44..60) with Crimea
                (lon 33..36, lat 44.3..46) a separate part of RU sharing two vertices of UA's southern edge, so
                the territory override moves it to UA and stitches it into UA's ring (a second source set without
                that part must stop the run)
  cities        Alpha (Q1, 2M, inside an urban polygon), Beta (ne:123, 50k, no polygon), Gamma (Q3, in LS)
  admin-1       ZA-GT (lon 0..30; its Spanish name equals the English), ZA-WC (lon 30..65, a Spanish name),
                ZA-NC in two pieces (merged), two equal, differently named features sharing AU-BAY (each
                ne:<id>), DK-81 shared by a mainland and an islet a 1,600th its size (the mainland keeps it),
                stand-in codes "-99-X1~" in LS and "DK-X02" (each ne:<id>), DK-84 0.005° across (kept), GL-QE
                whose ADM0_A3 is unknown (placed by ISO_A2), one with no country and one with no name (both left
                out), and plate groups: GB council areas by GEONUNIT, IE counties by code, FR departments by
                REGION_COD, an overseas region and an unlisted region each their own group; Crimea (UA-43) and
                Sevastopol (UA-40) filed under ADM0_A3 RUS (both counted as UA), Kherson (UA-65), and the
                everyday-names rule: "Autonomous Republic of Crimea" is Crimea, "Krasnodar Krai" Krasnodar
                ("Krai de Krasnodar" in Spanish), "Primorsky Krai" (NAME Primor'ye) keeps its Krai, and Camden's
                "Municipio de Camden" is stored empty
  urban areas   Alpha's polygon (kept); one with no city anywhere near (dropped); one 2 km east of Beta,
                inside a town's 5 km reach (kept, holding no point); one 10 km east of Beta (dropped)
  climate       5° pixels: class 7 on lon 0..30, 14 on lon 30..60 (lat -30..30), a 3-to-1 mix of 5 and 9
                in the cell lon 10..20, lat 20..30, nothing east of lon 60
"""

import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib


def _import_numpy_and_pillow():
    """numpy and Pillow, from the user's site-packages when `python3 -I` hides it."""
    try:
        import numpy
        from PIL import Image
    except ImportError:
        import site
        sys.path.append(site.getusersitepackages())
        import numpy
        from PIL import Image
    return numpy, Image


np, Image = _import_numpy_and_pillow()

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR = os.path.join(HERE, "build_world_atlas.py")
ROWS = 18


# ---------------------------------------------------------------------------------------------------------
# Writing synthetic sources


def box(west, south, east, north):
    """A closed clockwise rectangle (shapefile outer-ring order)."""
    return [(west, north), (east, north), (east, south), (west, south), (west, north)]


def shp_bytes(shapes, kind):
    """A .shp and its .shx for polygons (kind 5, lists of rings), polylines (kind 3, lists of lines) or points
    (kind 1, (x, y))."""
    records = []
    for shape in shapes:
        if kind == 1:
            records.append(struct.pack("<idd", 1, shape[0], shape[1]))
            continue
        points = [p for ring in shape for p in ring]
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        parts, at = [], 0
        for ring in shape:
            parts.append(at)
            at += len(ring)
        body = struct.pack("<i4dii", kind, min(xs), min(ys), max(xs), max(ys), len(shape), len(points))
        body += struct.pack("<%di" % len(parts), *parts)
        body += b"".join(struct.pack("<dd", x, y) for x, y in points)
        records.append(body)
    main, index, offset = b"", b"", 50
    for number, body in enumerate(records, 1):
        main += struct.pack(">ii", number, len(body) // 2) + body
        index += struct.pack(">ii", offset, len(body) // 2)
        offset += 4 + len(body) // 2

    def header(length_bytes):
        head = struct.pack(">i5ii", 9994, 0, 0, 0, 0, 0, length_bytes // 2)
        return head + struct.pack("<ii4d4d", 1000, kind, -180.0, -90.0, 180.0, 90.0, 0, 0, 0, 0)

    return header(100 + len(main)) + main, header(100 + len(index)) + index


def dbf_bytes(fields, rows):
    """A dBASE III table. fields: [(name, kind "C"/"N", length)]; rows: dicts (missing = blank)."""
    record_len = 1 + sum(f[2] for f in fields)
    header_len = 32 + 32 * len(fields) + 1
    out = struct.pack("<B3BIHH20x", 3, 126, 10, 29, len(rows), header_len, record_len)
    for name, kind, length in fields:
        out += struct.pack("<11sc4xBB14x", name.encode("ascii"), kind.encode("ascii"), length, 0)
    out += b"\r"
    for row in rows:
        out += b" "
        for name, kind, length in fields:
            value = row.get(name, "")
            raw = str(value).encode("utf-8")
            out += raw.rjust(length) if kind == "N" else raw.ljust(length)
    return out + b"\x1a"


def write_layer(folder, stem, kind, shapes, fields, rows):
    """<folder>/<stem>/<stem>.zip holding the shapefile set, as Natural Earth ships it."""
    shp, shx = shp_bytes(shapes, kind)
    os.makedirs(os.path.join(folder, stem))
    with zipfile.ZipFile(os.path.join(folder, stem, stem + ".zip"), "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(stem + ".shp", shp)
        archive.writestr(stem + ".shx", shx)
        archive.writestr(stem + ".dbf", dbf_bytes(fields, rows))
        archive.writestr(stem + ".cpg", "UTF-8")
        archive.writestr(stem + ".README.html", "synthetic")


def climate_tif(fill):
    """A 72 × 36 (5°) class raster as TIFF bytes."""
    grid = np.zeros((36, 72), dtype=np.uint8)
    if fill:
        lat = 90.0 - (np.arange(36) + 0.5) * 5.0
        lon = -180.0 + (np.arange(72) + 0.5) * 5.0
        band = (lat >= -30) & (lat < 30)
        grid[np.ix_(band, (lon >= 0) & (lon < 30))] = 7
        grid[np.ix_(band, (lon >= 30) & (lon < 60))] = 14
        col = lambda x: int((x + 180) / 5)  # noqa: E731
        row = lambda y: int((90 - y) / 5)  # noqa: E731
        grid[row(27.5), col(12.5)] = 5
        grid[row(27.5), col(17.5)] = 5
        grid[row(22.5), col(12.5)] = 5
        grid[row(22.5), col(17.5)] = 9
    else:
        grid[:, :] = 29
    buffer = io.BytesIO()
    Image.fromarray(grid).save(buffer, format="TIFF")
    return buffer.getvalue()


def write_sources(folder, crimea_in_russia=True):
    """All eleven sources (the coastline too, though only META lists it); without Crimea's part of RU when
    crimea_in_russia is False (the territory override must then stop the run)."""
    l_outer = box(0, -30, 65, 30)
    lake = box(20, -10, 40, 10)[::-1]
    bay_land = [(100, 40), (160, 40), (160, -40), (100, -40), (100, -10), (130, -10), (130, 10), (100, 10),
                (100, 40)]
    gl_island, dk_island = box(-100, 0, -96, 4), box(-50, 40, -46, 44)
    plain = [("FEATURECLA", "C", 20), ("SCALERANK", "N", 4)]
    write_layer(folder, "ne_10m_land", 5, [[l_outer, lake], [bay_land]], plain,
                [{"FEATURECLA": "Land"}, {"FEATURECLA": "Land"}])
    write_layer(folder, "ne_10m_minor_islands", 5, [[gl_island], [dk_island]], plain,
                [{"FEATURECLA": "Minor island"}, {"FEATURECLA": "Minor island"}])
    write_layer(folder, "ne_10m_coastline", 5, [[l_outer]], plain, [{"FEATURECLA": "Coastline"}])
    # A lake over two land cells (30-50°E, 10-20°N) with an island (42-48°E, 12-18°N) in its east cell.
    write_layer(folder, "ne_10m_lakes", 5, [[box(30, 10, 50, 20), box(42, 12, 48, 18)[::-1]]], plain,
                [{"FEATURECLA": "Lake"}])
    marine_fields = [("featurecla", "C", 16), ("name", "C", 40), ("name_en", "C", 40), ("name_es", "C", 40),
                     ("name_fr", "C", 40), ("name_de", "C", 40), ("wikidataid", "C", 12), ("ne_id", "N", 10)]
    marine = [
        (box(-60, -60, 0, 60), {"featurecla": "ocean", "name": "South Atlantic Ocean", "ne_id": 401}),
        (box(70, -60, 100, 60), {"featurecla": "ocean", "name": "INDIAN OCEAN", "ne_id": 402}),
        (box(-120, -60, -90, 60), {"featurecla": "sea", "name": "Test Sea", "name_es": "Mar de Prueba",
                                   "wikidataid": "Q999", "ne_id": 502}),
        (box(-90, -60, -60, 60), {"featurecla": "sea", "name": "Test Sea", "wikidataid": "Q999", "ne_id": 501}),
        (box(-180, 10, -150, 40), {"featurecla": "gulf", "name": "Gulf of Mexico", "ne_id": 600}),
        (box(-140, 50, -130, 60), {"featurecla": "sea", "name": "Tiny Sea", "wikidataid": "Q7", "ne_id": 700}),
        (box(20, -10, 40, 10), {"featurecla": "sea", "name": "Lake Sea", "wikidataid": "Q8", "ne_id": 800}),
        (box(100, -10, 130, 10), {"featurecla": "bay", "name": "Test Bay", "ne_id": 900}),
    ]
    write_layer(folder, "ne_10m_geography_marine_polys", 5, [[m[0]] for m in marine], marine_fields,
                [m[1] for m in marine])
    country_fields = [("ISO_A2_EH", "C", 4), ("ISO_A2", "C", 4), ("ADM0_A3", "C", 4), ("ADMIN", "C", 30),
                      ("SOVEREIGNT", "C", 30), ("CONTINENT", "C", 30), ("NE_ID", "N", 10)]
    countries = [
        ([l_outer, box(45, -25, 55, -15)[::-1]], {"ISO_A2_EH": "ZA", "ADM0_A3": "ZAF", "ADMIN": "South Africa",
                                                  "SOVEREIGNT": "South Africa", "CONTINENT": "Africa"}),
        ([box(45, -25, 55, -15)], {"ISO_A2_EH": "LS", "ADM0_A3": "LSO", "ADMIN": "Lesotho",
                                   "SOVEREIGNT": "Lesotho", "CONTINENT": "Africa"}),
        ([bay_land], {"ISO_A2_EH": "AU", "ADM0_A3": "AUS", "ADMIN": "Australia", "SOVEREIGNT": "Australia",
                      "CONTINENT": "Oceania"}),
        ([dk_island], {"ISO_A2_EH": "DK", "ADM0_A3": "DNK", "ADMIN": "Denmark", "SOVEREIGNT": "Denmark",
                       "CONTINENT": "Europe"}),
        ([gl_island], {"ISO_A2_EH": "GL", "ADM0_A3": "GRL", "ADMIN": "Greenland", "SOVEREIGNT": "Denmark",
                       "CONTINENT": "North America"}),
        ([box(-40, 60, -30, 70)], {"ISO_A2_EH": "GB", "ADM0_A3": "GBR", "ADMIN": "United Kingdom",
                                   "SOVEREIGNT": "United Kingdom", "CONTINENT": "Europe"}),
        ([box(-30, 60, -20, 70)], {"ISO_A2_EH": "IE", "ADM0_A3": "IRL", "ADMIN": "Ireland",
                                   "SOVEREIGNT": "Ireland", "CONTINENT": "Europe"}),
        ([box(-40, 70, -20, 80)], {"ISO_A2_EH": "FR", "ADM0_A3": "FRA", "ADMIN": "France",
                                   "SOVEREIGNT": "France", "CONTINENT": "Europe"}),
        # UA's southern edge runs (40, 46) -> (36, 46) -> (33, 46) -> (30, 46); Crimea's northern edge runs
        # (33, 46) -> (36, 46): the same two vertices, the other way round, as Natural Earth's shared border.
        ([[(30, 50), (40, 50), (40, 46), (36, 46), (33, 46), (30, 46), (30, 50)]],
         {"ISO_A2_EH": "UA", "ADM0_A3": "UKR", "ADMIN": "Ukraine", "SOVEREIGNT": "Ukraine", "CONTINENT": "Europe"}),
        ([box(37, 44, 60, 60)] + ([box(33, 44.3, 36, 46)] if crimea_in_russia else []),
         {"ISO_A2_EH": "RU", "ADM0_A3": "RUS", "ADMIN": "Russia", "SOVEREIGNT": "Russia", "CONTINENT": "Europe"}),
    ]
    write_layer(folder, "ne_10m_admin_0_countries", 5, [c[0] for c in countries], country_fields,
                [c[1] for c in countries])
    write_admin1(folder)
    place_fields = [("NAME", "C", 30), ("NAME_ES", "C", 30), ("NAME_FR", "C", 30), ("NAME_DE", "C", 30),
                    ("WIKIDATAID", "C", 12), ("NE_ID", "N", 10), ("POP_MAX", "N", 10), ("ISO_A2", "C", 4)]
    places = [
        ((10.5, 10.5), {"NAME": "Alpha", "NAME_ES": "Alfa", "NAME_FR": "Alpha", "NAME_DE": "Alpha",
                        "WIKIDATAID": "Q1", "NE_ID": 111, "POP_MAX": 2000000, "ISO_A2": "ZA"}),
        ((12.0, -20.0), {"NAME": "Beta", "NE_ID": 123, "POP_MAX": 50000, "ISO_A2": "ZA"}),
        ((52.0, -20.0), {"NAME": "Gamma", "NAME_DE": "Gammastadt", "WIKIDATAID": "Q3", "NE_ID": 133,
                         "POP_MAX": 150000, "ISO_A2": "LS"}),
    ]
    write_layer(folder, "ne_10m_populated_places", 1, [p[0] for p in places], place_fields, [p[1] for p in places])
    urban_areas = [[box(9, 9, 12, 12)], [box(30, 0, 33, 3)], [box(12.02, -20.02, 12.1, -19.98)],
                   [box(12.1, -20.02, 12.2, -19.98)]]
    write_layer(folder, "ne_10m_urban_areas", 5, urban_areas, [("AREA_SQKM", "N", 10)],
                [{"AREA_SQKM": n} for n in range(1, len(urban_areas) + 1)])
    os.makedirs(os.path.join(folder, "Beck_KG_V1"))
    with zipfile.ZipFile(os.path.join(folder, "Beck_KG_V1", "Beck_KG_V1.zip"), "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Beck_KG_V1_future_0p083.tif", climate_tif(False))
        zf.writestr("Beck_KG_V1_present_0p083.tif", climate_tif(True))
        zf.writestr("legend.txt", "synthetic")
    write_roads(folder)


# The synthetic roads, by record number: 0 and 1 one named route that touches (one road, two lines); 2 the same
# name at another level, with a bend under the tolerance (its own main road, two points); 3 and 4 unnamed, meeting
# where only they do (one road); 5, 6 and 4 meeting at a junction (5 and 6 their own); 7 a minor road, 8 a ferry
# and 9 a track (left out); 10 an expressway of a low rank (a highway); 11 one feature in two parts (one road).
ROAD_FIELDS = [("FEATURECLA", "C", 10), ("TYPE", "C", 20), ("SCALERANK", "N", 4), ("EXPRESSWAY", "N", 2),
               ("PREFIX", "C", 4), ("NAME", "C", 10), ("LABEL", "C", 10), ("LEVEL", "C", 12)]


def write_roads(folder):
    """ne_10m_roads: the twelve pieces above."""
    def road(kind="Major Highway", rank=3, name="", level="", cla="Road", express=0):
        return {"FEATURECLA": cla, "TYPE": kind, "SCALERANK": rank, "EXPRESSWAY": express, "NAME": name,
                "LEVEL": level}
    pieces = [
        ([[(0, 0), (1, 0)]], road(name="5", level="Interstate")),
        ([[(1, 0), (2, 0)]], road(name="5", level="Interstate")),
        ([[(2, 0), (2.5, 0.0001), (3, 0)]], road("Secondary Highway", name="5", level="State")),
        ([[(10, 10), (11, 10)]], road("Road", 4)),
        ([[(11, 10), (12, 10)]], road("Road", 4)),
        ([[(12, 10), (12, 11)]], road("Road", 4)),
        ([[(12, 10), (13, 10)]], road("Road", 4)),
        ([[(20, 20), (21, 20)]], road("Road", 7)),
        ([[(22, 20), (23, 20)]], road("Ferry Route", 3, cla="Ferry")),
        ([[(24, 20), (25, 20)]], road("Track", 3)),
        ([[(30, 30), (31, 30)]], road("Road", 6, express=1)),
        ([[(40, 40), (41, 40)], [(42, 40), (43, 40)]], road()),
    ]
    write_layer(folder, "ne_10m_roads", 3, [p[0] for p in pieces], ROAD_FIELDS, [p[1] for p in pieces])


def write_admin1(folder):
    """The admin-1 states and provinces (see the module docstring)."""
    fields = [("ISO_3166_2", "C", 10), ("ISO_A2", "C", 4), ("ADM0_A3", "C", 4), ("NAME", "C", 40),
              ("NAME_EN", "C", 40), ("NAME_ES", "C", 40), ("NE_ID", "N", 10), ("GEONUNIT", "C", 30),
              ("REGION_COD", "C", 10)]
    rows = [
        ([box(0, -30, 30, 30)], {"ISO_3166_2": "ZA-GT", "ISO_A2": "ZA", "ADM0_A3": "ZAF", "NAME": "Gauteng",
                                 "NAME_ES": "Gauteng", "NE_ID": 11}),
        ([box(30, -30, 65, 30)], {"ISO_3166_2": "ZA-WC", "ISO_A2": "ZA", "ADM0_A3": "ZAF", "NAME": "Wes-Kaap",
                                  "NAME_EN": "Western Cape", "NAME_ES": "Cabo Occidental", "NE_ID": 12}),
        ([box(60, -29, 61, -28)], {"ISO_3166_2": "ZA-NC", "ISO_A2": "ZA", "ADM0_A3": "ZAF",
                                   "NAME": "Northern Cape", "NE_ID": 14}),
        ([box(62, -29, 63, -28)], {"ISO_3166_2": "ZA-NC", "ISO_A2": "ZA", "ADM0_A3": "ZAF",
                                   "NAME": "Northern Cape", "NE_ID": 13}),
        ([box(100, 10, 160, 40)], {"ISO_3166_2": "AU-BAY", "ISO_A2": "AU", "ADM0_A3": "AUS", "NAME": "Bay North",
                                   "NE_ID": 21}),
        ([box(100, -40, 160, -10)], {"ISO_3166_2": "AU-BAY", "ISO_A2": "AU", "ADM0_A3": "AUS",
                                     "NAME": "Bay South", "NE_ID": 22}),
        ([box(45, -25, 55, -15)], {"ISO_3166_2": "-99-X1~", "ISO_A2": "-1", "ADM0_A3": "LSO",
                                   "NAME": "Highlands", "NE_ID": 31}),
        ([box(-50, 40, -49.995, 40.005)], {"ISO_3166_2": "DK-84", "ISO_A2": "DK", "ADM0_A3": "DNK",
                                           "NAME": "Speck", "NE_ID": 41}),
        ([box(-100, 0, -96, 4)], {"ISO_3166_2": "GL-QE", "ISO_A2": "GL", "ADM0_A3": "XXX", "NAME": "Qeqqata",
                                  "NE_ID": 51}),
        ([box(-10, -10, -5, -5)], {"ISO_3166_2": "ZZ-01", "ISO_A2": "-1", "ADM0_A3": "ZZZ", "NAME": "Nowhere",
                                   "NE_ID": 61}),
        ([box(-20, -10, -15, -5)], {"ISO_3166_2": "ZA-X01", "ISO_A2": "ZA", "ADM0_A3": "ZAF", "NAME": "",
                                    "NE_ID": 71}),
        ([box(-30, -10, -25, -5)], {"ISO_3166_2": "DK-X02", "ISO_A2": "DK", "ADM0_A3": "DNK",
                                    "NAME": "Stand-in", "NE_ID": 81}),
        ([box(-50, 30, -46, 34)], {"ISO_3166_2": "DK-81", "ISO_A2": "DK", "ADM0_A3": "DNK", "NAME": "Mainland",
                                   "NE_ID": 92}),
        ([box(-46, 30, -45.9, 30.1)], {"ISO_3166_2": "DK-81", "ISO_A2": "DK", "ADM0_A3": "DNK", "NAME": "Islet",
                                       "NE_ID": 91}),
        # Plate groups: GB by GEONUNIT, IE by each county's own code, FR by REGION_COD (with Natural Earth's
        # stray tab), an overseas region kept as its own group, and a region PLATE_GROUPS does not list.
        ([box(-40, 60, -35, 65)], {"ISO_3166_2": "GB-CMD", "ADM0_A3": "GBR", "NAME": "Camden", "NE_ID": 101,
                                   "NAME_ES": "Municipio de Camden", "GEONUNIT": "England"}),
        ([box(-40, 65, -35, 70)], {"ISO_3166_2": "GB-LDS", "ADM0_A3": "GBR", "NAME": "Leeds", "NE_ID": 102,
                                   "GEONUNIT": "England"}),
        ([box(-35, 60, -30, 70)], {"ISO_3166_2": "GB-GLG", "ADM0_A3": "GBR", "NAME": "Glasgow", "NE_ID": 103,
                                   "GEONUNIT": "Scotland"}),
        ([box(-30, 60, -25, 70)], {"ISO_3166_2": "IE-D", "ADM0_A3": "IRL", "NAME": "Dublin", "NE_ID": 111}),
        ([box(-25, 60, -20, 70)], {"ISO_3166_2": "IE-CO", "ADM0_A3": "IRL", "NAME": "Cork", "NE_ID": 112}),
        ([box(-40, 70, -35, 80)], {"ISO_3166_2": "FR-75", "ADM0_A3": "FRA", "NAME": "Paris", "NE_ID": 121,
                                   "REGION_COD": "FR-IDF\t"}),
        ([box(-35, 70, -30, 80)], {"ISO_3166_2": "FR-971", "ADM0_A3": "FRA", "NAME": "Guadeloupe", "NE_ID": 122,
                                   "REGION_COD": "FR-GUA"}),
        ([box(-30, 70, -20, 80)], {"ISO_3166_2": "FR-99", "ADM0_A3": "FRA", "NAME": "Elsewhere", "NE_ID": 123,
                                   "REGION_COD": "FR-ZZZ"}),
        # Crimea and Sevastopol as Natural Earth files them (ADM0_A3 RUS, ISO_A2 RU, Ukraine's codes).
        ([box(33.6, 44.3, 36, 46)], {"ISO_3166_2": "UA-43", "ISO_A2": "RU", "ADM0_A3": "RUS", "NAME": "Crimea",
                                     "NAME_EN": "Autonomous Republic of Crimea",
                                     "NAME_ES": "República autónoma de Crimea", "NE_ID": 131}),
        ([box(33, 44.3, 33.6, 46)], {"ISO_3166_2": "UA-40", "ISO_A2": "RU", "ADM0_A3": "RUS",
                                     "NAME": "Sevastopol", "NAME_ES": "Sebastopol", "NE_ID": 132}),
        ([box(30, 46, 40, 50)], {"ISO_3166_2": "UA-65", "ISO_A2": "UA", "ADM0_A3": "UKR", "NAME": "Kherson",
                                 "NAME_ES": "Jersón", "NE_ID": 133}),
        ([box(37, 44, 50, 60)], {"ISO_3166_2": "RU-KDA", "ISO_A2": "RU", "ADM0_A3": "RUS", "NAME": "Krasnodar",
                                 "NAME_EN": "Krasnodar Krai", "NAME_ES": "Krai de Krasnodar", "NE_ID": 134}),
        ([box(50, 44, 60, 60)], {"ISO_3166_2": "RU-PRI", "ISO_A2": "RU", "ADM0_A3": "RUS", "NAME": "Primor'ye",
                                 "NAME_EN": "Primorsky Krai", "NAME_ES": "Primorie", "NE_ID": 135}),
    ]
    write_layer(folder, "ne_10m_admin_1_states_provinces", 5, [r[0] for r in rows], fields, [r[1] for r in rows])


# ---------------------------------------------------------------------------------------------------------
# An independent reader


class Cursor:
    """Little-endian reads over one section's bytes."""

    def __init__(self, data):
        self.data, self.at = data, 0

    def take(self, fmt):
        values = struct.unpack_from("<" + fmt, self.data, self.at)
        self.at += struct.calcsize("<" + fmt)
        return values if len(values) > 1 else values[0]

    def raw(self, count):
        out = self.data[self.at:self.at + count]
        self.at += count
        return out

    def text(self):
        return self.raw(self.take("B")).decode("utf-8")

    def varint(self):
        value, shift = 0, 0
        for _ in range(5):
            byte = self.take("B")
            value |= (byte & 0x7F) << shift
            shift += 7
            if byte < 0x80:
                return (value >> 1) ^ -(value & 1)
        raise ValueError("varint over 5 bytes")

    def polygon(self):
        bbox = self.take("iiii")
        rings = []
        for _ in range(self.take("H")):
            count = self.take("I")
            x, y = self.take("ii")
            ring = [(x, y)]
            for _ in range(count - 1):
                x += self.varint()
                y += self.varint()
                ring.append((x, y))
            rings.append(ring)
        return bbox, rings


def read_pack(data):
    """{tag: raw bytes} after checking magic, version, offsets and lengths."""
    assert data[:4] == b"FWA1", "magic"
    version, count = struct.unpack_from("<HH", data, 4)
    assert version == 1, "version"
    sections = {}
    for i in range(count):
        tag, offset, stored, raw_len = struct.unpack_from("<4sIII", data, 8 + 16 * i)
        assert offset + stored <= len(data), "section past the end"
        raw = zlib.decompress(data[offset:offset + stored], -15)
        assert len(raw) == raw_len, "raw length"
        sections[tag.decode("ascii")] = raw
    return sections


def decode(sections):
    """Every section as plain Python structures."""
    land = Cursor(sections["LAND"])
    cols, rows, sub = land.take("IIH")
    state = land.raw(cols * rows)
    coast = [land.raw(32) for _ in range(land.take("I"))]
    seas_cur = Cursor(sections["SEAS"])
    seas = []
    for _ in range(seas_cur.take("H")):
        seas.append({"token": seas_cur.text(), "parent": seas_cur.take("B"),
                     "names": [seas_cur.text() for _ in range(4)]})
    ctry_cur = Cursor(sections["CTRY"])
    countries = {}
    for _ in range(ctry_cur.take("H")):
        code, sovereign, continent, flags = ctry_cur.take("2s2sBB")
        bbox, rings = ctry_cur.polygon()
        countries[code.decode()] = {"sovereign": sovereign.decode(), "continent": continent, "flags": flags,
                                    "rings": rings}
    urbn_cur = Cursor(sections["URBN"])
    urban = [urbn_cur.polygon()[1] for _ in range(urbn_cur.take("I"))]
    city_cur = Cursor(sections["CITY"])
    cities = {}
    for _ in range(city_cur.take("I")):
        token = city_cur.text()
        country, size, population, lon, lat, urban_index = city_cur.take("2sBIiii")
        cities[token] = {"country": country.decode(), "size": size, "population": population, "lon": lon,
                         "lat": lat, "urban": urban_index, "names": [city_cur.text() for _ in range(4)]}
    adm1_cur = Cursor(sections["ADM1"])
    groups = []
    for _ in range(adm1_cur.take("H")):
        groups.append({"token": adm1_cur.text(), "country": adm1_cur.take("2s").decode(),
                       "names": [adm1_cur.text(), adm1_cur.text()]})
    road_cur = Cursor(sections["ROAD"])
    roads = {}
    for _ in range(road_cur.take("I")):
        number, kind, line_count = road_cur.take("IBH")
        lines = []
        for _ in range(line_count):
            count = road_cur.take("H")
            x, y = road_cur.take("ii")
            line = [(x, y)]
            for _ in range(count - 1):
                x += road_cur.varint()
                y += road_cur.varint()
                line.append((x, y))
            lines.append(line)
        roads[number] = {"kind": kind, "lines": lines}
    admin1 = {}
    for _ in range(adm1_cur.take("H")):
        token, country = adm1_cur.text(), adm1_cur.take("2s").decode()
        names = [adm1_cur.text(), adm1_cur.text()]
        group = adm1_cur.take("H")
        admin1[token] = {"country": country, "names": names, "group": None if group == 0xFFFF else groups[group],
                         "rings": adm1_cur.polygon()[1]}
    return {"cols": cols, "rows": rows, "sub": sub, "state": state, "coast": coast, "clim": sections["CLIM"],
            "ocea": sections["OCEA"], "cont": sections["CONT"], "seas": seas, "countries": countries,
            "urban": urban, "cities": cities, "admin1": admin1, "groups": groups, "roads": roads,
            "roads_end": road_cur.at == len(road_cur.data), "ends": (urbn_cur.at == len(urbn_cur.data),
                                                                       adm1_cur.at == len(adm1_cur.data)),
            "meta": json.loads(sections["META"].decode("utf-8"))}


def cell(atlas, lon, lat):
    """Grid index and the point's fractions inside the cell (from its north-west corner)."""
    step = 180.0 / atlas["rows"]
    fy, fx = (90.0 - lat) / step, (lon + 180.0) / step
    row = min(max(int(fy // 1), 0), atlas["rows"] - 1)
    col = int(fx // 1) % atlas["cols"]
    return row * atlas["cols"] + col, fx - int(fx // 1), fy - int(fy // 1)


def is_land(atlas, lon, lat):
    """LAND's answer at a point, through the coast mask when the cell is mixed."""
    index, frac_x, frac_y = cell(atlas, lon, lat)
    kind = atlas["state"][index]
    if kind != 2:
        return kind == 1
    rank = sum(1 for i in range(index) if atlas["state"][i] == 2)
    bit = int(frac_y * 16) * 16 + int(frac_x * 16)
    return bool(atlas["coast"][rank][bit >> 3] >> (bit & 7) & 1)


def inside(rings, lon, lat):
    """Even-odd point test over integer rings."""
    x, y, odd = lon * 1e5, lat * 1e5, False
    for ring in rings:
        for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
            if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
                odd = not odd
    return odd


# ---------------------------------------------------------------------------------------------------------
# The checks


class Checks:
    """Counts passes and collects failures."""

    def __init__(self):
        self.passed, self.failed = 0, []

    def equal(self, label, got, want):
        if got == want:
            self.passed += 1
        else:
            self.failed.append("%s: got %r, want %r" % (label, got, want))


def region_token_of(country, code, english):
    """The generator's region_token, loaded from its file (the one generator function the self-test calls)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("build_world_atlas", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.region_token(country, code, english)


def run_generator(sources, out, *extra):
    """The generator's exit code and output."""
    command = [sys.executable, "-I", GENERATOR, "--sources", sources, "--out", out, "--rows", str(ROWS),
               "--unverified-sources"] + list(extra)
    done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return done.returncode, done.stdout


def check_grids(c, atlas):
    """LAND, CLIM, OCEA and CONT at chosen points."""
    c.equal("grid", (atlas["cols"], atlas["rows"], atlas["sub"]), (36, 18, 16))
    state = lambda lon, lat: atlas["state"][cell(atlas, lon, lat)[0]]  # noqa: E731
    c.equal("land cell", state(10, 5), 1)
    c.equal("lake cell is water", state(25, 5), 0)
    c.equal("ocean cell", state(-30, 5), 0)
    c.equal("coast cell", state(65, 5), 2)
    c.equal("island coast cell", state(-95, 5), 2)
    c.equal("coast bit land (sx 3)", is_land(atlas, 62.2, 5.0), True)
    c.equal("coast bit water (sx 12)", is_land(atlas, 67.8, 5.0), False)
    c.equal("island bit land", is_land(atlas, -98.5, 1.5), True)
    c.equal("island bit water", is_land(atlas, -98.5, 8.5), False)
    c.equal("island bit land (sx 5, low bits first)", is_land(atlas, -96.5, 1.5), True)
    c.equal("island bit water (sx 6, low bits first)", is_land(atlas, -95.9, 1.5), False)
    clim = lambda lon, lat: atlas["clim"][cell(atlas, lon, lat)[0]]  # noqa: E731
    c.equal("climate cell", clim(5, 5), 7)
    c.equal("climate majority 3 to 1", clim(15, 25), 5)
    c.equal("climate second band", clim(45, 5), 14)
    c.equal("climate nearest fill on coast", clim(65, 5), 14)
    c.equal("climate 0 on water", clim(-30, 5), 0)
    c.equal("climate 0 on a lake", clim(25, 5), 0)
    ocea = lambda lon, lat: atlas["ocea"][cell(atlas, lon, lat)[0]]  # noqa: E731
    seas = {s["token"]: 6 + i for i, s in enumerate(atlas["seas"])}
    c.equal("ocean polygon", ocea(-30, 5), 2)
    c.equal("bay joined to the Indian Ocean", ocea(115, 5), 3)
    c.equal("sea polygon takes its sea", ocea(-75, 5), seas.get("Q999"))
    c.equal("island coast cell in the sea", ocea(-95, 5), seas.get("Q999"))
    c.equal("promoted gulf takes its sea", ocea(-165, 25), seas.get("ne:600"))
    c.equal("enclosed lake gets 0", ocea(25, 5), 0)
    c.equal("enclosed lake gets 0 (2)", ocea(35, -5), 0)
    c.equal("land gets 0", ocea(10, 5), 0)
    cont = lambda lon, lat: atlas["cont"][cell(atlas, lon, lat)[0]]  # noqa: E731
    c.equal("continent Africa", cont(10, 5), 1)
    c.equal("continent from the nearest country on a coast cell", cont(65, 5), 1)
    c.equal("continent Oceania", cont(115, 30), 6)
    c.equal("continent 0 at sea", cont(-30, 5), 0)
    c.equal("a lake cell is water", state(35, 15), 0)
    c.equal("a lake keeps its continent", cont(35, 15), 1)
    c.equal("a lake names no ocean or sea", ocea(35, 15), 0)
    c.equal("a lake has no climate", clim(35, 15), 0)
    c.equal("a cell with an island in a lake is coast", state(45, 15), 2)
    c.equal("the island in the lake stays land", is_land(atlas, 45.0, 15.0), True)
    c.equal("the lake around it is water", is_land(atlas, 41.0, 11.0), False)


def check_tables(c, atlas):
    """SEAS, CTRY, URBN, CITY and META."""
    seas = {s["token"]: s for s in atlas["seas"]}
    c.equal("sea tokens", sorted(seas), ["Q999", "ne:600"])
    c.equal("merged sea names", seas.get("Q999", {}).get("names"), ["Test Sea", "", "", ""])
    c.equal("sea parent ocean", seas.get("Q999", {}).get("parent"), 2)
    countries = atlas["countries"]
    c.equal("country codes", sorted(countries), ["AU", "DK", "FR", "GB", "GL", "IE", "LS", "RU", "UA", "ZA"])
    ua, ru = countries.get("UA", {"rings": []})["rings"], countries.get("RU", {"rings": []})["rings"]
    for name, lon, lat in (("Simferopol", 34.1024, 44.9521), ("Sevastopol", 33.52, 44.60), ("Yalta", 34.1663, 44.4952)):
        c.equal("%s is UA (territory override)" % name, (inside(ua, lon, lat), inside(ru, lon, lat)), (True, False))
    c.equal("Crimea is stitched into UA's ring, not a ring of its own", len(ua), 1)
    c.equal("no sliver along the old border: just south of it is UA", inside(ua, 34.5, 45.99), True)
    c.equal("UA's mainland stays UA", inside(ua, 35, 48), True)
    c.equal("RU keeps its mainland", (inside(ru, 40, 50), len(ru)), (True, 1))
    c.equal("point in ZA", inside(countries["ZA"]["rings"], 10, 0), True)
    c.equal("ZA's hole is not ZA", inside(countries["ZA"]["rings"], 50, -20), False)
    c.equal("the hole is LS", inside(countries["LS"]["rings"], 50, -20), True)
    c.equal("lake area still ZA", inside(countries["ZA"]["rings"], 25, 0), True)
    c.equal("territory sovereign", countries["GL"]["sovereign"], "DK")
    c.equal("one of the passport's countries", (countries["ZA"]["flags"], countries["DK"]["flags"], countries["GL"]["flags"]),
            (1, 1, 0))
    c.equal("country continent", countries["GL"]["continent"], 5)
    c.equal("urban polygons kept (one holding Alpha, one in Beta's reach)", len(atlas["urban"]), 2)
    c.equal("the reached polygon holds no city point", inside(atlas["urban"][1], 12.0, -20.0), False)
    c.equal("the reached polygon is the one 2 km from Beta", inside(atlas["urban"][1], 12.05, -20.0), True)
    cities = atlas["cities"]
    c.equal("city tokens", sorted(cities), ["Q1", "Q3", "ne:123"])
    alpha, beta, gamma = cities.get("Q1", {}), cities.get("ne:123", {}), cities.get("Q3", {})
    c.equal("city with a polygon", alpha.get("urban"), 0)
    c.equal("polygon holds the city", inside(atlas["urban"][0], 10.5, 10.5), True)
    c.equal("city without a polygon", beta.get("urban"), -1)
    c.equal("city sizes", (alpha.get("size"), beta.get("size"), gamma.get("size")), (2, 0, 1))
    c.equal("city point", (alpha.get("lon"), alpha.get("lat")), (1050000, 1050000))
    c.equal("city names", alpha.get("names"), ["Alpha", "Alfa", "", ""])
    c.equal("city country in a hole", gamma.get("country"), "LS")
    c.equal("city population", beta.get("population"), 50000)
    c.equal("meta date", atlas["meta"].get("date"), "2026-10-29")
    c.equal("meta sources", len(atlas["meta"].get("sources", [])), 11)
    c.equal("meta admin-1 tolerance", atlas["meta"].get("admin1SimplifyDegrees"), 0.008)


def check_admin1(c, atlas):
    """ADM1: tokens, countries, names, merges, the tiny polygon and the even-odd rings."""
    admin1 = atlas["admin1"]
    c.equal("admin-1 tokens (sorted by country, then token)", list(admin1),
            ["ne:21", "ne:22", "DK-81", "DK-84", "ne:81", "ne:91", "FR-75", "FR-971", "FR-99", "GB-CMD", "GB-GLG",
             "GB-LDS", "GL-QE", "IE-CO", "IE-D", "ne:31", "RU-KDA", "RU-PRI", "UA-40", "UA-43", "UA-65", "ZA-GT",
             "ZA-NC", "ZA-WC"])
    c.equal("sections end where their counts say", atlas["ends"], (True, True))
    get = lambda token: admin1.get(token, {"country": None, "names": None, "rings": []})  # noqa: E731
    c.equal("Spanish equal to English is stored empty", get("ZA-GT")["names"], ["Gauteng", ""])
    c.equal("NAME_EN wins over NAME", get("ZA-WC")["names"], ["Western Cape", "Cabo Occidental"])
    c.equal("pieces sharing a code and a name merge", len(get("ZA-NC")["rings"]), 2)
    c.equal("a shared code with two names names neither", (get("ne:21")["names"], get("ne:22")["names"]),
            (["Bay North", ""], ["Bay South", ""]))
    c.equal("a stand-in code takes ne:<id>", get("ne:31")["country"], "LS")
    c.equal("a shared code stays with a feature that dwarfs the rest", (get("DK-81")["names"], get("ne:91")["names"]),
            (["Mainland", ""], ["Islet", ""]))
    c.equal("an unknown ADM0_A3 falls back to ISO_A2", get("GL-QE")["country"], "GL")
    group = lambda token: (admin1.get(token, {}).get("group") or {}).get("token")  # noqa: E731
    c.equal("GB council areas group by GEONUNIT", (group("GB-CMD"), group("GB-LDS"), group("GB-GLG")),
            ("GB-ENG", "GB-ENG", "GB-SCT"))
    c.equal("a plate group's names", (admin1.get("GB-CMD", {}).get("group") or {}).get("names"),
            ["England", "Inglaterra"])
    c.equal("IE counties group by their own code", (group("IE-D"), group("IE-CO")), ("IE-L", "IE-M"))
    c.equal("FR departments group by REGION_COD, tab stripped", group("FR-75"), "FR-IDF")
    c.equal("an overseas region is its own group", group("FR-971"), None)
    c.equal("an unlisted region is its own group", group("FR-99"), None)
    c.equal("ungrouped countries keep their own entries", group("ZA-GT"), None)
    c.equal("one row per plate group", sorted(g["token"] for g in atlas["groups"]),
            ["FR-IDF", "GB-ENG", "GB-SCT", "IE-L", "IE-M"])
    c.equal("Crimea's admin-1 rows count as UA", (get("UA-43")["country"], get("UA-40")["country"],
                                                   get("UA-65")["country"]), ("UA", "UA", "UA"))
    c.equal("RU's own admin-1 stays RU", get("RU-KDA")["country"], "RU")
    c.equal("an official long form loses its designation", get("UA-43")["names"], ["Crimea", ""])
    c.equal("a trailing designation goes when the rest is the feature's own NAME (Spanish too)",
            get("RU-KDA")["names"], ["Krasnodar", ""])
    c.equal("a trailing designation stays when the rest is not its own name", get("RU-PRI")["names"],
            ["Primorsky Krai", "Primorie"])
    c.equal("a Spanish designation before the English name goes", get("GB-CMD")["names"], ["Camden", ""])
    c.equal("a Spanish name of its own stays", get("UA-65")["names"], ["Kherson", "Jersón"])
    c.equal("a tiny polygon keeps its ring", len(get("DK-84")["rings"]), 1)
    c.equal("point in Gauteng", inside(get("ZA-GT")["rings"], 10, 0), True)
    c.equal("point not in Gauteng", inside(get("ZA-GT")["rings"], 40, 0), False)
    c.equal("point in Western Cape", inside(get("ZA-WC")["rings"], 40, 0), True)


def check_roads(c, atlas):
    """ROAD: which pieces count, how they join into roads, their kinds and lines."""
    roads = atlas["roads"]
    c.equal("road numbers", sorted(roads), [0, 2, 3, 5, 6, 10, 11])
    c.equal("road kinds", [roads[n]["kind"] for n in sorted(roads)], [1, 2, 2, 2, 2, 1, 1])
    c.equal("a named route that touches is one road", len(roads.get(0, {}).get("lines", [])), 2)
    c.equal("unnamed pieces where only two meet join", len(roads.get(3, {}).get("lines", [])), 2)
    c.equal("a feature's parts are one road", len(roads.get(11, {}).get("lines", [])), 2)
    c.equal("a bend under the tolerance goes", roads.get(2, {}).get("lines"), [[(200000, 0), (300000, 0)]])
    c.equal("the section ends where its roads do", atlas["roads_end"], True)


def main():
    """Builds, decodes and checks; exits non-zero on any failure."""
    c = Checks()
    with tempfile.TemporaryDirectory(prefix="world-atlas-selftest-") as work:
        sources = os.path.join(work, "sources")
        os.makedirs(sources)
        write_sources(sources)
        out = os.path.join(work, "out", "WorldAtlas.pack")
        code, log = run_generator(sources, out, "--date", "2026-10-29")
        if code != 0:
            print(log)
            print("selftest: the generator failed (exit %d)" % code)
            return 1
        with open(out, "rb") as handle:
            pack = handle.read()
        atlas = decode(read_pack(pack))
        check_grids(c, atlas)
        check_tables(c, atlas)
        check_admin1(c, atlas)
        check_roads(c, atlas)
        c.equal("summary logs the admin-1 left out", "Nowhere" in log and "left out of ADM1" in log, True)
        c.equal("summary logs the unnamed admin-1", "'' (ne_id 71)" in log, True)
        c.equal("summary logs the unlisted region", "region 'FR-ZZZ' not in PLATE_GROUPS" in log, True)
        c.equal("a region without a code gets a slug token", region_token_of("FR", None, "Côte d'Or Région"),
                "ne:region:FR:cote-d-or-region")
        c.equal("summary names a missing promoted sea", "'Hudson Bay' not found" in log, True)
        c.equal("summary logs the tiny sea", "Tiny Sea" in log and "dropped into its neighbour" in log, True)
        c.equal("summary logs the cut-off sea", "Lake Sea" in log and "not joined" in log, True)
        c.equal("summary prints the hash", "sha256: " + hashlib.sha256(pack).hexdigest() in log, True)
        again = os.path.join(work, "out", "again.pack")
        run_generator(sources, again, "--date", "2026-10-29")
        with open(again, "rb") as handle:
            c.equal("deterministic", handle.read() == pack, True)
        capped = os.path.join(work, "out", "capped.pack")
        code, _ = run_generator(sources, capped, "--size-cap", "100")
        c.equal("over the cap is refused", (code, os.path.exists(capped)), (1, False))
        c.equal("summary logs the territory override",
                "territory override Crimea, RU -> UA (rings moved / stitched): 1 / 1" in log, True)
        no_crimea = os.path.join(work, "no-crimea")
        os.makedirs(no_crimea)
        write_sources(no_crimea, crimea_in_russia=False)
        moved_nothing = os.path.join(work, "out", "no-crimea.pack")
        code, log = run_generator(no_crimea, moved_nothing)
        c.equal("an override that moves nothing stops the run",
                (code, os.path.exists(moved_nothing), "territory override Crimea moved 0 rings" in log), (1, False, True))
    for failure in c.failed:
        print("FAIL " + failure)
    if c.failed:
        print("selftest: %d of %d checks failed" % (len(c.failed), c.passed + len(c.failed)))
        return 1
    print("selftest: all %d checks passed" % c.passed)
    return 0


if __name__ == "__main__":
    sys.exit(main())

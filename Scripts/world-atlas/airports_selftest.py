#!/usr/bin/env python3
"""Self-test for build_world_airports.py: builds a pack from small synthetic sources, then decodes it with its
own minimal reader (nothing imported from the generator) and checks the rules of World-Airports-Spec §1–§2.

    python3 -I Scripts/world-atlas/airports_selftest.py

Every airport, runway, name and zone here is made up for the test (spec data rule); none comes from the owner.
Exit 0 when every check passes.
"""

import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR = os.path.join(HERE, "build_world_airports.py")
FAILURES = []
PASSES = [0]


def check(condition, label):
    if condition:
        PASSES[0] += 1
    else:
        FAILURES.append(label)
        print("FAIL: " + label)


# ---------------------------------------------------------------------------------------------------------
# Fixtures

AIRPORT_FIELDS = ["id", "ident", "type", "name", "latitude_deg", "longitude_deg", "elevation_ft", "continent",
                  "iso_country", "iso_region", "municipality", "scheduled_service", "icao_code", "iata_code",
                  "gps_code", "local_code", "home_link", "wikipedia_link", "keywords"]
RUNWAY_FIELDS = ["id", "airport_ref", "airport_ident", "length_ft", "width_ft", "surface", "lighted", "closed",
                 "le_ident", "le_latitude_deg", "le_longitude_deg", "le_elevation_ft", "le_heading_degT",
                 "le_displaced_threshold_ft", "he_ident", "he_latitude_deg", "he_longitude_deg",
                 "he_elevation_ft", "he_heading_degT", "he_displaced_threshold_ft"]


def csv_text(fields, rows):
    def cell(value):
        value = str(value)
        return '"%s"' % value.replace('"', '""') if any(c in value for c in ',"\n') else value
    lines = [",".join(fields)] + [",".join(cell(row.get(f, "")) for f in fields) for row in rows]
    return "\n".join(lines) + "\n"


def airport(id_, ident, kind, name, lat, lon, country, region, city, iata="", icao=""):
    return {"id": id_, "ident": ident, "type": kind, "name": name, "latitude_deg": lat, "longitude_deg": lon,
            "iso_country": country, "iso_region": region, "municipality": city, "iata_code": iata,
            "icao_code": icao}


AIRPORTS = [
    # A large airport in Florida's Eastern zone, with two runways, Spanish name and served city.
    airport(1, "KFAK", "large_airport", "Fakeville International Airport", 28.0, -81.0, "US", "US-FL",
            "Fakeville", iata="FKV", icao="KFAK"),
    # A medium airport in the Florida panhandle that the airport list puts in Central time.
    airport(2, "KVPS", "medium_airport", "Pine Sands Regional Airport", 30.47, -87.19, "US", "US-FL",
            "Pine Sands", iata="VPS", icao="KVPS"),
    # A medium airport with no runway ends: a 1.5 km circle. No IATA code: token = ident.
    airport(3, "XX-0001", "medium_airport", "Nowhere Aerodrome", 10.0, 10.0, "XX", "XX-01", "Nowhere"),
    # A small airport with an IATA code: a point for arcs only, never unlockable.
    airport(4, "KSML", "small_airport", "Smallton Airport", 29.0, -82.0, "US", "US-FL", "Smallton",
            iata="SML"),
    # A heliport with no IATA: neither.
    airport(5, "KHEL", "heliport", "Rooftop Heliport", 29.5, -82.5, "US", "US-FL", "Rooftop"),
    # A closed airport with an IATA code: left out entirely.
    airport(6, "KOLD", "closed", "Old Field", 27.0, -80.0, "US", "US-FL", "Oldtown", iata="OLD"),
    # A nickname airport (LHR is on the nickname list) in a country with two zone points.
    airport(7, "EGLL", "large_airport", "London Heathrow Airport", 51.47, -0.45, "GB", "GB-ENG", "London",
            iata="LHR", icao="EGLL"),
    # A large airport whose region splits nowhere: the nearest zone point in its country (Zedland's east).
    airport(8, "ZZEA", "large_airport", "East Zed Airport", 5.0, 40.0, "ZZ", "ZZ-E", "Zedeast",
            iata="ZED", icao="ZZEA"),
    # The data error the generator leaves out.
    airport(9, "VE-0526", "medium_airport", "(Misplaced duplicate?)", 12.5, 20.8, "VE", "VE-V", ""),
]

RUNWAYS = [
    {"id": 1, "airport_ref": 1, "airport_ident": "KFAK", "closed": "0", "le_latitude_deg": 27.99,
     "le_longitude_deg": -81.01, "he_latitude_deg": 28.01, "he_longitude_deg": -80.99},
    {"id": 2, "airport_ref": 1, "airport_ident": "KFAK", "closed": "0", "le_latitude_deg": 28.0,
     "le_longitude_deg": -81.02, "he_latitude_deg": 28.0, "he_longitude_deg": -80.98},
    # A closed runway and a runway end 30 km away: both ignored.
    {"id": 3, "airport_ref": 1, "airport_ident": "KFAK", "closed": "1", "le_latitude_deg": 28.2,
     "le_longitude_deg": -81.2, "he_latitude_deg": 28.21, "he_longitude_deg": -81.21},
    {"id": 4, "airport_ref": 1, "airport_ident": "KFAK", "closed": "0", "le_latitude_deg": 28.27,
     "le_longitude_deg": -81.0, "he_latitude_deg": "", "he_longitude_deg": ""},
    {"id": 5, "airport_ref": 2, "airport_ident": "KVPS", "closed": "0", "le_latitude_deg": 30.465,
     "le_longitude_deg": -87.20, "he_latitude_deg": 30.475, "he_longitude_deg": -87.18},
    {"id": 6, "airport_ref": 7, "airport_ident": "EGLL", "closed": "0", "le_latitude_deg": 51.465,
     "le_longitude_deg": -0.49, "he_latitude_deg": 51.465, "he_longitude_deg": -0.43},
    {"id": 7, "airport_ref": 8, "airport_ident": "ZZEA", "closed": "0", "le_latitude_deg": 5.0,
     "le_longitude_deg": 39.99, "he_latitude_deg": 5.0, "he_longitude_deg": 40.01},
]

ZONE_TAB = """# tzdb test table
US\t+404251-0740023\tAmerica/New_York\tEastern
US\t+415100-0873900\tAmerica/Chicago\tCentral
GB\t+513030-0000731\tEurope/London
ZZ\t+0500+01000\tAfrica/Lagos\tZedland west
ZZ\t+0500+04000\tAfrica/Nairobi\tZedland east
XX\t+1000+01000\tAfrica/Ndjamena
"""


def write_sources(folder):
    """The ten sources at the paths fetch-airport-sources.sh names, plus a zone.tab folder."""
    def put(rel, body):
        path = os.path.join(folder, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(body)

    put("ourairports/airports.csv", csv_text(AIRPORT_FIELDS, AIRPORTS))
    put("ourairports/runways.csv", csv_text(RUNWAY_FIELDS, RUNWAYS))
    e = "http://www.wikidata.org/entity/"
    put("wikidata-airports/iata.csv", "item,code\n%sQ1,FKV\n%sQ2,VPS\n%sQ7,LHR\n%sQ8,ZED\n" % (e, e, e, e))
    put("wikidata-airports/icao.csv", "item,code\n%sQ1,KFAK\n" % e)
    put("wikidata-airports/label-es-iata.csv",
        "item,l\n%sQ1,Aeropuerto Internacional de Fakeville\n%sQ2,Pine Sands Regional Airport\n"
        "%sQ7,Aeropuerto de Londres-Heathrow\n" % (e, e, e))
    put("wikidata-airports/label-es-icao.csv", "item,l\n")
    put("wikidata-airports/served.csv", "item,city\n%sQ1,%sQ100\n%sQ1,%sQ101\n%sQ8,%sQ102\n%sQ2,%sQ103\n"
        % (e, e, e, e, e, e, e, e))
    put("wikidata-airports/city-en-iata.csv", "city,l\n%sQ100,Fakeville\n%sQ101,Otherville\n" % (e, e))
    put("wikidata-airports/city-en-icao.csv", "city,l\n%sQ102,Zed State\n%sQ103,Smoke\n" % (e, e))
    put("wikidata-airports/city-es-iata.csv", "city,l\n%sQ100,Villafalsa\n%sQ101,Otravilla\n" % (e, e))
    put("wikidata-airports/city-es-icao.csv", "city,l\n%sQ102,Estado Zed\n%sQ103,Humo\n" % (e, e))
    put("tz/zone.tab", ZONE_TAB)
    put("tz/+VERSION", "2026test\n")


def write_hand(folder, outlines=(), tokens=None):
    os.makedirs(folder, exist_ok=True)
    shutil.copy(os.path.join(HERE, "airlines.json"), os.path.join(folder, "airlines.json"))
    with open(os.path.join(folder, "airport-outlines.json"), "w", encoding="utf-8") as handle:
        json.dump({"outlines": list(outlines)}, handle)
    path = os.path.join(folder, "airport-tokens.json")
    if tokens is None:
        if os.path.exists(path):
            os.remove(path)
    else:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"tokens": tokens}, handle)


def run(sources, hand, out, record=True):
    args = [sys.executable, "-I", GENERATOR, "--sources", sources, "--out", out, "--date", "test",
            "--zoneinfo", os.path.join(sources, "tz"), "--hand-files", hand, "--unverified-sources"]
    if record:
        args.append("--record-tokens")
    return subprocess.run(args, capture_output=True, text=True)


# ---------------------------------------------------------------------------------------------------------
# Minimal reader


class Bytes:
    def __init__(self, data):
        self.data, self.at = data, 0

    def take(self, fmt):
        size = struct.calcsize(fmt)
        values = struct.unpack_from(fmt, self.data, self.at)
        self.at += size
        return values

    def raw(self, count):
        out = self.data[self.at:self.at + count]
        self.at += count
        return out

    def text(self):
        (length,) = self.take("<B")
        return self.raw(length).decode("utf-8")

    def varint(self):
        shift = result = 0
        while True:
            byte = self.data[self.at]
            self.at += 1
            result |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                return (result >> 1) ^ -(result & 1)

    def ring(self):
        count, lon, lat = self.take("<Iii")
        points = [(lat / 1e5, lon / 1e5)]
        for _ in range(count - 1):
            lon += self.varint()
            lat += self.varint()
            points.append((lat / 1e5, lon / 1e5))
        return points


def read_pack(data):
    assert data[:4] == b"FAP1", "magic"
    version, count = struct.unpack_from("<HH", data, 4)
    assert version == 1
    sections = {}
    for slot in range(count):
        tag, offset, stored, raw = struct.unpack_from("<4sIII", data, 8 + 16 * slot)
        body = zlib.decompress(data[offset:offset + stored], -15)
        assert len(body) == raw
        sections[tag.decode()] = body
    return sections


def decode(sections):
    r = Bytes(sections["TZNS"])
    (count,) = r.take("<H")
    zones = [r.text() for _ in range(count)]
    r = Bytes(sections["APTS"])
    (count,) = r.take("<H")
    airports = {}
    for _ in range(count):
        token, iata, ident = r.text(), r.text(), r.text()
        lat, lon = r.take("<ii")
        country = r.raw(2).decode()
        size, zone = r.take("<BH")
        names = [r.text() for _ in range(4)]
        (kind,) = r.take("<B")
        if kind == 0:
            (radius,) = r.take("<H")
            ground = ("circle", radius)
        else:
            ground = ("runways" if kind == 1 else "outline", r.ring())
        airports[token] = {"iata": iata, "ident": ident, "lat": lat / 1e5, "lon": lon / 1e5, "country": country,
                           "size": size, "zone": zones[zone], "name_en": names[0], "name_es": names[1],
                           "city_en": names[2], "city_es": names[3], "ground": ground}
    r = Bytes(sections["PNTS"])
    (count,) = r.take("<H")
    points = {}
    for _ in range(count):
        code = r.raw(3).decode()
        lat, lon, zone, index = r.take("<iiHH")
        points[code] = {"lat": lat / 1e5, "lon": lon / 1e5, "zone": zones[zone], "unlockable": index != 0xFFFF}
    r = Bytes(sections["AIRL"])
    (count,) = r.take("<H")
    airlines = [(r.raw(3).decode(), r.raw(2).decode(), r.text()) for _ in range(count)]
    return airports, points, airlines, json.loads(sections["META"])


def inside(ring, lat, lon):
    hit = False
    for (la1, lo1), (la2, lo2) in zip(ring, ring[1:]):
        if (la1 > lat) != (la2 > lat):
            x = lo1 + (lat - la1) * (lo2 - lo1) / (la2 - la1)
            if x > lon:
                hit = not hit
    return hit


def metres(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


# ---------------------------------------------------------------------------------------------------------


def main():
    work = tempfile.mkdtemp(prefix="airports-selftest-")
    try:
        sources, hand, out = os.path.join(work, "src"), os.path.join(work, "hand"), os.path.join(work, "a.pack")
        write_sources(sources)
        write_hand(hand)
        result = run(sources, hand, out)
        check(result.returncode == 0, "the generator builds the synthetic pack: " + result.stderr[-400:])
        if result.returncode != 0:
            return finish(work)
        with open(out, "rb") as handle:
            data = handle.read()
        airports, points, airlines, meta = decode(read_pack(data))

        # Who is unlockable, who is a point.
        check(sorted(airports) == ["FKV", "LHR", "VPS", "XX-0001", "ZED"],
              "unlockables are the large and medium airports, VE-0526 left out: %s" % sorted(airports))
        check(sorted(points) == ["FKV", "LHR", "SML", "VPS", "ZED"],
              "points are every IATA airport but closed ones: %s" % sorted(points))
        check(points["SML"]["unlockable"] is False and points["FKV"]["unlockable"] is True,
              "a small airport's point is not an unlockable")
        check(airports["XX-0001"]["iata"] == "" and airports["XX-0001"]["ident"] == "XX-0001",
              "an airport with no IATA is keyed by its ident")
        check(airports["FKV"]["size"] == 1 and airports["VPS"]["size"] == 2, "sizes: large 1, medium 2")

        # Names.
        check(airports["FKV"]["name_en"] == "Fakeville International", "English drops 'Airport'")
        check(airports["FKV"]["name_es"] == "Internacional de Fakeville", "Spanish drops 'Aeropuerto'")
        check(airports["VPS"]["name_es"] == "", "a Spanish label that isn't Spanish is left empty")
        check(airports["LHR"]["name_en"] == "Heathrow" and airports["LHR"]["name_es"] == "",
              "a nickname wins in both languages")
        check(airports["FKV"]["city_en"] == "Fakeville" and airports["FKV"]["city_es"] == "Villafalsa",
              "the served city matching the municipality gives the Spanish city")
        check(airports["XX-0001"]["name_en"] == "Nowhere", "'Aerodrome' is dropped too")
        check(airports["ZED"]["city_en"] == "Zedeast" and airports["ZED"]["city_es"] == "",
              "a served place the airport's name doesn't mention (a state) is never taken")
        check(airports["VPS"]["city_en"] == "Pine Sands", "a served city must match or be named in the name")

        # Zones.
        check(airports["FKV"]["zone"] == "America/New_York", "a region table zone (US-FL)")
        check(airports["VPS"]["zone"] == "America/Chicago", "the airport list overrides its region")
        check(airports["ZED"]["zone"] == "Africa/Nairobi", "elsewhere, the nearest zone point in the country")
        check(points["SML"]["zone"] == "America/New_York", "points carry zones too")
        check(meta["tzdata"] == "2026test", "META records the tzdata version")

        # Grounds.
        kind, ring = airports["FKV"]["ground"]
        check(kind == "runways", "runway ends give a runway outline")
        check(all(inside(ring, lat, lon) for lat, lon in ((27.99, -81.01), (28.01, -80.99), (28.0, -81.02),
                                                         (28.0, -80.98), (28.0, -81.0))),
              "the runway outline holds every runway end")
        check(inside(ring, 28.0, -81.02 - 400 / (111320 * math.cos(math.radians(28)))),
              "and ground 400 m beyond a runway end")
        check(not inside(ring, 28.0, -81.02 - 1000 / (111320 * math.cos(math.radians(28)))),
              "but not ground 1 km beyond it")
        check(not inside(ring, 28.2, -81.2) and not inside(ring, 28.27, -81.0),
              "closed runways and far runway ends are ignored")
        check(4 <= len(ring) <= 64, "the outline is simplified (%d points)" % len(ring))
        check(airports["XX-0001"]["ground"] == ("circle", 1500), "no runway ends: a 1.5 km circle")

        # Airlines.
        check(("ACA", "AC", "Air Canada") in airlines, "the airline table carries Air Canada")

        # An approved outline replaces the runway outline; an unapproved one stops the run.
        tokens = json.load(open(os.path.join(hand, "airport-tokens.json")))["tokens"]
        outline = {"id": "FKV", "points": [[27.98, -81.03], [27.98, -80.97], [28.02, -80.97], [28.02, -81.03]],
                   "imagery": "test", "imageryDate": "2026-10-31", "seed": "runways", "reviewer": "owner",
                   "approved": "2026-10-31"}
        write_hand(hand, [outline], tokens)
        result = run(sources, hand, out, record=False)
        check(result.returncode == 0, "an approved outline builds")
        if result.returncode == 0:
            airports2, _, _, _ = decode(read_pack(open(out, "rb").read()))
            check(airports2["FKV"]["ground"][0] == "outline", "the approved outline is used")
        unapproved = dict(outline, approved="")
        write_hand(hand, [unapproved], tokens)
        result = run(sources, hand, out, record=False)
        check(result.returncode != 0 and "approved" in result.stderr, "an unapproved outline stops the run")

        # Tokens stay frozen: a changed IATA code keeps the first token; a new airport needs --record-tokens.
        write_hand(hand, (), tokens)
        AIRPORTS[0]["iata_code"] = "FKX"
        AIRPORTS.append(airport(10, "KNEW", "large_airport", "New Field", 31.0, -84.0, "US", "US-GA", "Newton",
                                iata="NEW"))
        write_sources(sources)
        result = run(sources, hand, out, record=False)
        check(result.returncode != 0 and "--record-tokens" in result.stderr,
              "a new airport without a frozen token stops the run")
        result = run(sources, hand, out, record=True)
        check(result.returncode == 0, "--record-tokens freezes the new airport")
        if result.returncode == 0:
            airports3, points3, _, _ = decode(read_pack(open(out, "rb").read()))
            check("FKV" in airports3 and airports3["FKV"]["iata"] == "FKX",
                  "a renamed airport keeps its frozen token")
            check("NEW" in airports3 and "FKX" in points3, "the new airport and the new code are in")
    finally:
        pass
    return finish(work)


def finish(work):
    shutil.rmtree(work, ignore_errors=True)
    print("%d checks passed, %d failed" % (PASSES[0], len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Build Fernlet's bundled airports pack from the pinned sources (Docs/World-Airports-Pack.md,
World-Airports-Spec §1–§2).

Build machine only; the app never fetches anything. Fetch the sources first with
Scripts/world-atlas/fetch-airport-sources.sh, then:

    python3 -I Scripts/world-atlas/build_world_airports.py --sources <dir> \
        --out App/Fernlet/World/Atlas/WorldAirports.pack [--date 2026-10-31]

What it reads:
- OurAirports airports.csv and runways.csv (public domain): every large and medium airport is an unlockable;
  every IATA-coded airport (any type but closed) is a point an imported flight can draw an arc to;
- Wikidata snapshots (CC0): Spanish airport names and the Spanish and English names of the city each
  serves;
- tzdata's zone.tab (public domain), from this Mac's /usr/share/zoneinfo (or --zoneinfo): each airport's
  IANA zone, by region tables for countries whose regions split cleanly, the nearest zone point in the
  country elsewhere, and a hand list of airports where neither is right;
- the hand-kept files beside this script: airport-tokens.json (the frozen passport token of every
  unlockable), airport-outlines.json (our own approved outlines, §2.1), airlines.json (§9.3).

Python 3.9 standard library + numpy only. Same sources and options give the same bytes for one zlib build.
Bounds: every loop runs over a finite input or carries an explicit cap; nothing recurses.
"""

import argparse
import csv
import hashlib
import json
import math
import os
import struct
import sys
import zoneinfo
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_world_atlas as atlas  # noqa: E402  (numpy, ring encoding, deflate; same folder)

np = atlas.np

GENERATOR_VERSION = 1
PACK_VERSION = 1
MAGIC = b"FAP1"
SIZE_CAP = 1_048_576
SCALE = 100_000
METRES_PER_DEGREE = 111_320.0
RUNWAY_MARGIN_METRES = 500.0
CIRCLE_METRES = 1_500
RUNWAY_REACH_METRES = 8_000.0
SIMPLIFY_METRES = 50.0
CIRCLE_STEPS = 16
MAX_GROUND_POINTS = 64
MAX_AIRPORTS = 20_000
MAX_POINTS = 40_000
NO_ZONE = 0xFFFF
NO_AIRPORT = 0xFFFF
UNLOCKABLE_TYPES = {"large_airport": 1, "medium_airport": 2}
GROUND_CIRCLE, GROUND_RUNWAYS, GROUND_OUTLINE = 0, 1, 2

SOURCE_LICENCES = {
    "ourairports": "Public domain (OurAirports)",
    "wikidata-airports": "CC0 1.0 (Wikidata)",
    "tzdata": "Public domain (tz database)",
}

# Everyday names for airports better known by a nickname than by their long name (spec §1.2). Spanish
# keeps the same proper noun.
NICKNAMES = {
    "LHR": "Heathrow", "LGW": "Gatwick", "STN": "Stansted", "LTN": "Luton", "LCY": "London City",
    "NRT": "Narita", "HND": "Haneda", "KIX": "Kansai", "ORD": "O'Hare", "MDW": "Midway", "JFK": "JFK",
    "LGA": "LaGuardia", "EWR": "Newark", "IAD": "Dulles", "DCA": "Reagan National", "CDG": "Charles de Gaulle",
    "ORY": "Orly", "AMS": "Schiphol", "FCO": "Fiumicino", "CIA": "Ciampino", "MXP": "Malpensa", "LIN": "Linate",
    "ICN": "Incheon", "GMP": "Gimpo", "PVG": "Pudong", "SHA": "Hongqiao", "PKX": "Daxing",
    "DMK": "Don Mueang", "BKK": "Suvarnabhumi", "SAW": "Sabiha Gökçen", "YYZ": "Pearson", "YUL": "Trudeau",
    "GRU": "Guarulhos", "GIG": "Galeão", "SDU": "Santos Dumont", "EZE": "Ezeiza", "AEP": "Aeroparque",
    "MAD": "Barajas", "BCN": "El Prat", "ARN": "Arlanda", "OSL": "Gardermoen", "KEF": "Keflavík",
}

# Countries whose regions (OurAirports iso_region) map to one zone each; airports in a region that splits
# are in ZONE_BY_AIRPORT. Every other country takes the nearest zone.tab point inside it.
ZONE_BY_REGION = {
    "US": {
        "AL": "America/Chicago", "AK": "America/Anchorage", "AZ": "America/Phoenix", "AR": "America/Chicago",
        "CA": "America/Los_Angeles", "CO": "America/Denver", "CT": "America/New_York", "DE": "America/New_York",
        "DC": "America/New_York", "FL": "America/New_York", "GA": "America/New_York", "HI": "Pacific/Honolulu",
        "ID": "America/Boise", "IL": "America/Chicago", "IN": "America/Indiana/Indianapolis",
        "IA": "America/Chicago", "KS": "America/Chicago", "KY": "America/Kentucky/Louisville",
        "LA": "America/Chicago", "ME": "America/New_York", "MD": "America/New_York", "MA": "America/New_York",
        "MI": "America/Detroit", "MN": "America/Chicago", "MS": "America/Chicago", "MO": "America/Chicago",
        "MT": "America/Denver", "NE": "America/Chicago", "NV": "America/Los_Angeles", "NH": "America/New_York",
        "NJ": "America/New_York", "NM": "America/Denver", "NY": "America/New_York", "NC": "America/New_York",
        "ND": "America/Chicago", "OH": "America/New_York", "OK": "America/Chicago", "OR": "America/Los_Angeles",
        "PA": "America/New_York", "RI": "America/New_York", "SC": "America/New_York", "SD": "America/Chicago",
        "TN": "America/Chicago", "TX": "America/Chicago", "UT": "America/Denver", "VT": "America/New_York",
        "VA": "America/New_York", "WA": "America/Los_Angeles", "WV": "America/New_York", "WI": "America/Chicago",
        "WY": "America/Denver",
    },
    "CA": {
        "BC": "America/Vancouver", "AB": "America/Edmonton", "SK": "America/Regina", "MB": "America/Winnipeg",
        "ON": "America/Toronto", "QC": "America/Toronto", "NB": "America/Moncton", "NS": "America/Halifax",
        "PE": "America/Halifax", "NL": "America/St_Johns", "YT": "America/Whitehorse", "NT": "America/Edmonton",
        "NU": "America/Iqaluit",
    },
    "AU": {
        "NSW": "Australia/Sydney", "VIC": "Australia/Melbourne", "QLD": "Australia/Brisbane",
        "SA": "Australia/Adelaide", "WA": "Australia/Perth", "TAS": "Australia/Hobart", "NT": "Australia/Darwin",
        "ACT": "Australia/Sydney",
    },
    "BR": {
        "AC": "America/Rio_Branco", "AL": "America/Maceio", "AP": "America/Belem", "AM": "America/Manaus",
        "BA": "America/Bahia", "CE": "America/Fortaleza", "DF": "America/Sao_Paulo", "ES": "America/Sao_Paulo",
        "GO": "America/Sao_Paulo", "MA": "America/Fortaleza", "MT": "America/Cuiaba",
        "MS": "America/Campo_Grande", "MG": "America/Sao_Paulo", "PA": "America/Belem", "PB": "America/Fortaleza",
        "PR": "America/Sao_Paulo", "PE": "America/Recife", "PI": "America/Fortaleza", "RJ": "America/Sao_Paulo",
        "RN": "America/Fortaleza", "RS": "America/Sao_Paulo", "RO": "America/Porto_Velho",
        "RR": "America/Boa_Vista", "SC": "America/Sao_Paulo", "SP": "America/Sao_Paulo", "SE": "America/Maceio",
        "TO": "America/Araguaina",
    },
}

# Airports in a region that splits between zones (by IATA, else ident).
ZONE_BY_AIRPORT = {
    "PNS": "America/Chicago", "VPS": "America/Chicago", "ECP": "America/Chicago",
    "TYS": "America/New_York", "TRI": "America/New_York", "CHA": "America/New_York",
    "PAH": "America/Chicago", "OWB": "America/Chicago", "BWG": "America/Chicago",
    "EVV": "America/Chicago", "GYY": "America/Chicago",
    "IMT": "America/Menominee", "ESC": "America/Menominee", "IWD": "America/Menominee",
    "MNM": "America/Menominee", "DIK": "America/Denver", "RAP": "America/Denver", "BFF": "America/Denver",
    "GLD": "America/Denver", "ELP": "America/Denver", "LWS": "America/Los_Angeles",
    "COE": "America/Los_Angeles", "ONO": "America/Boise", "ADK": "America/Adak",
    "YYR": "America/Goose_Bay", "YQK": "America/Winnipeg", "YXJ": "America/Dawson_Creek",
    "YDQ": "America/Dawson_Creek", "YYE": "America/Fort_Nelson", "YXC": "America/Edmonton",
    "YLL": "America/Edmonton", "YRT": "America/Rankin_Inlet", "YCB": "America/Cambridge_Bay",
    "BHQ": "Australia/Broken_Hill", "LDH": "Australia/Lord_Howe", "FEN": "America/Noronha",
    "STM": "America/Santarem", "TBT": "America/Eirunepe", "ERN": "America/Eirunepe",
    "CJS": "America/Ciudad_Juarez", "ATU": "America/Adak", "SYA": "America/Adak",
}

# OurAirports rows that are data errors, left out (each checked by hand, 2026-10-31).
DATA_ERRORS = {
    "VE-0526": "a misplaced duplicate of Caracas, placed in Chad",
}


class Report(atlas.Report):
    """Notes, unmapped data and counts, as the atlas generator keeps them."""


# ---------------------------------------------------------------------------------------------------------
# Sources


def read_source_table(script_dir):
    """The pinned table from fetch-airport-sources.sh: one dict per source."""
    path = os.path.join(script_dir, "fetch-airport-sources.sh")
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
                raise SystemExit("error: bad source table line in fetch-airport-sources.sh: %r" % line)
            rows.append(dict(zip(("subdir", "file", "bytes", "need", "sha", "url"), parts)))
    if len(rows) != 12:
        raise SystemExit("error: fetch-airport-sources.sh lists %d sources, not 12" % len(rows))
    return rows


def locate_sources(source_dir, table, verify, report):
    """Each present source's path and hash, keyed by "subdir/file"; a required one missing, or (with verify)
    one that differs from its pin, stops the run."""
    found = {}
    for row in table:
        key = row["subdir"] + "/" + row["file"]
        path = os.path.join(source_dir, row["subdir"], row["file"])
        if not os.path.isfile(path):
            if row["need"] == "required":
                raise SystemExit("error: missing source %s (run fetch-airport-sources.sh)" % path)
            report.note("optional source %s not present" % key)
            continue
        digest = atlas.sha256_file(path)
        if digest != row["sha"]:
            if verify:
                raise SystemExit("error: %s sha256 %s is not the pinned %s" % (key, digest, row["sha"]))
            report.note("source %s differs from its pin (unverified run)" % key)
        found[key] = {"path": path, "sha256": digest, "file": key, "url": row["url"], "subdir": row["subdir"]}
    return found


def read_csv(path, cap):
    """The CSV's rows as dicts (a leading BOM stripped), refusing more than `cap` rows."""
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        rows = []
        for row in csv.DictReader(handle):
            rows.append(row)
            if len(rows) > cap:
                raise SystemExit("error: %s has more than %d rows" % (path, cap))
    return rows


def qid(uri):
    """The Q-id at the end of a Wikidata entity URI."""
    return uri.rsplit("/", 1)[-1]


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


# ---------------------------------------------------------------------------------------------------------
# Time zones


def read_zone_tab(zoneinfo_dir):
    """zone.tab as (country, lat, lon, zone) rows, and tzdata's version."""
    rows = []
    with open(os.path.join(zoneinfo_dir, "zone.tab"), "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            rows.append((parts[0], *iso6709(parts[1]), parts[2]))
    version = "unknown"
    version_path = os.path.join(zoneinfo_dir, "+VERSION")
    if os.path.isfile(version_path):
        with open(version_path, "r", encoding="utf-8") as handle:
            version = handle.read().strip()
    return rows, version


def iso6709(text):
    """zone.tab's ±DDMM±DDDMM or ±DDMMSS±DDDMMSS as decimal (lat, lon)."""
    split = max(text.rfind("+"), text.rfind("-"))
    lat, lon = text[:split], text[split:]

    def part(value, degree_digits):
        sign = -1.0 if value[0] == "-" else 1.0
        digits = value[1:]
        degrees = int(digits[:degree_digits])
        minutes = int(digits[degree_digits:degree_digits + 2])
        seconds = int(digits[degree_digits + 2:degree_digits + 4] or 0)
        return sign * (degrees + minutes / 60.0 + seconds / 3600.0)

    return part(lat, 2), part(lon, 3)


def great_circle_metres(lat1, lon1, lat2, lon2):
    """Haversine distance in metres."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_000.0 * math.asin(min(1.0, math.sqrt(h)))


def zone_for(airport, zones, by_country, report):
    """The airport's IANA zone: the hand list, then its region, then the nearest zone point in its country,
    then the nearest anywhere."""
    code = airport["iata"] or airport["ident"]
    if code in ZONE_BY_AIRPORT:
        return ZONE_BY_AIRPORT[code]
    country = airport["country"]
    region = airport["region"].split("-", 1)[-1]
    if country in ZONE_BY_REGION:
        zone = ZONE_BY_REGION[country].get(region)
        if zone:
            return zone
        report.unmap("no zone for region %s (%s); nearest zone used" % (airport["region"], code))
    candidates = by_country.get(country) or zones
    best = min(candidates, key=lambda z: great_circle_metres(airport["lat"], airport["lon"], z[1], z[2]))
    return best[3]


def offset_hours(zone, cache):
    """The zone's UTC offset on 15 January 2026, in hours (standard time in the north)."""
    if zone not in cache:
        moment = datetime(2026, 1, 15, 12, tzinfo=timezone.utc)
        cache[zone] = moment.astimezone(zoneinfo.ZoneInfo(zone)).utcoffset().total_seconds() / 3600.0
    return cache[zone]


def check_zones(assigned, report):
    """Every zone exists, and no airport's zone is more than three hours from its longitude's sun time
    (logged for review: a wrong zone shows a wrong flight duration)."""
    cache = {}
    odd = 0
    for code, lat, lon, zone in assigned:
        try:
            hours = offset_hours(zone, cache)
        except zoneinfo.ZoneInfoNotFoundError:
            raise SystemExit("error: zone %s (%s) is not in this Mac's tzdata" % (zone, code))
        sun = lon / 15.0
        gap = abs(((hours - sun) + 12) % 24 - 12)
        if gap > 3.0 and abs(lat) < 66:
            odd += 1
            report.note("zone check: %s at %.2f, %.2f is %s (UTC%+.1f), %.1f h from sun time" %
                        (code, lat, lon, zone, hours, gap))
    report.counts["zones more than 3 h from sun time (reviewed list in notes)"] = odd


# ---------------------------------------------------------------------------------------------------------
# Airports and names


def everyday_english(code, name):
    """The nickname, else OurAirports' name without a trailing "Airport"/"Aerodrome"/"Airfield"."""
    if code in NICKNAMES:
        return NICKNAMES[code]
    trimmed = name.strip()
    if " Airport - " in trimmed:
        trimmed = trimmed.split(" - ", 1)[0]
    for suffix in (" International Airport", " Airport", " Aerodrome", " Airfield", " Airstrip"):
        if trimmed.endswith(suffix) and len(trimmed) > len(suffix):
            keep = " International" if suffix == " International Airport" else ""
            return trimmed[: -len(suffix)] + keep
    return trimmed


def everyday_spanish(code, label, english):
    """Wikidata's Spanish label without its leading "Aeropuerto" (spec: "Internacional de Portland");
    empty (the reader falls back to English) when there's none or it says the same."""
    if code in NICKNAMES:
        return ""
    text = (label or "").strip()
    for prefix in ("Aeropuerto ", "Aeródromo ", "Aerodromo "):
        if text.startswith(prefix):
            text = text[len(prefix):]
            if text.startswith("de ") or text.startswith("del "):
                text = text.split(" ", 1)[1]
            break
    else:
        text = ""
    return "" if not text or text == english else text


def load_wikidata(sources):
    """Q-id by IATA and by ICAO, the Spanish label by Q-id, the served cities by Q-id and their labels."""
    def rows(name):
        return read_csv(sources["wikidata-airports/" + name]["path"], 200_000)

    by_iata, by_icao = {}, {}
    for row in rows("iata.csv"):
        by_iata.setdefault(row["code"].strip().upper(), set()).add(qid(row["item"]))
    for row in rows("icao.csv"):
        by_icao.setdefault(row["code"].strip().upper(), set()).add(qid(row["item"]))
    spanish = {}
    for name in ("label-es-iata.csv", "label-es-icao.csv"):
        for row in rows(name):
            spanish.setdefault(qid(row["item"]), row["l"])
    served = {}
    for row in rows("served.csv"):
        served.setdefault(qid(row["item"]), []).append(qid(row["city"]))
    city_en, city_es = {}, {}
    for name in ("city-en-iata.csv", "city-en-icao.csv"):
        for row in rows(name):
            city_en.setdefault(qid(row["city"]), row["l"])
    for name in ("city-es-iata.csv", "city-es-icao.csv"):
        for row in rows(name):
            city_es.setdefault(qid(row["city"]), row["l"])
    return {"iata": by_iata, "icao": by_icao, "es": spanish, "served": served, "city_en": city_en,
            "city_es": city_es}


def wikidata_item(airport, wd):
    """The airport's one Wikidata item, by IATA then ICAO; None when absent or ambiguous."""
    for key, table in ((airport["iata"], wd["iata"]), (airport["icao"], wd["icao"]),
                       (airport["ident"], wd["icao"])):
        if key and key in table and len(table[key]) == 1:
            return next(iter(table[key]))
    return None


def plain_municipality(text):
    """OurAirports' municipality without its qualifiers: "Manchester, Greater Manchester" -> "Manchester",
    "Köln (Cologne)" -> "Köln", "Kuopio / Siilinjärvi" -> "Kuopio"."""
    for mark in (",", " (", " / ", "/"):
        text = text.split(mark, 1)[0]
    return text.strip()


def served_city(item, municipality, airport_name, wd):
    """The Q-id of the city the airport serves: the served city whose English name is the municipality,
    else the one named earliest in the airport's own name ("Naples International Airport" -> Naples,
    "Cologne Bonn Airport" -> Cologne). A served place the name doesn't mention (a state, a district) is
    never taken."""
    cities = sorted(set(wd["served"].get(item, ())))
    for city in cities:
        if wd["city_en"].get(city, "").casefold() == municipality.casefold():
            return city
    folded = airport_name.casefold()
    named = [(folded.find(wd["city_en"][c].casefold()), c) for c in cities
             if wd["city_en"].get(c) and wd["city_en"][c].casefold() in folded]
    return min(named)[1] if named else None


def read_airports(path, report):
    """OurAirports' rows as plain dicts: every airport with a type other than closed."""
    out = []
    for row in read_csv(path, 200_000):
        if row["type"] == "closed":
            continue
        if row["ident"].strip().upper() in DATA_ERRORS:
            report.note("left out %s: %s" % (row["ident"], DATA_ERRORS[row["ident"].strip().upper()]))
            continue
        try:
            lat, lon = float(row["latitude_deg"]), float(row["longitude_deg"])
        except ValueError:
            report.unmap("airport %s has no position" % row["ident"])
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            report.unmap("airport %s is off the globe" % row["ident"])
            continue
        out.append({
            "id": int(row["id"]), "ident": row["ident"].strip().upper(), "type": row["type"],
            "name": row["name"].strip(), "lat": lat, "lon": lon, "country": row["iso_country"].strip().upper(),
            "region": row["iso_region"].strip().upper(), "municipality": row["municipality"].strip(),
            "iata": row["iata_code"].strip().upper(), "icao": row["icao_code"].strip().upper(),
        })
    return out


# ---------------------------------------------------------------------------------------------------------
# Grounds


def local_xy(lat0, lon0, lat, lon):
    """Metres east and north of (lat0, lon0) on a local flat projection (airports are a few km across)."""
    return ((lon - lon0) * math.cos(math.radians(lat0)) * METRES_PER_DEGREE, (lat - lat0) * METRES_PER_DEGREE)


def local_latlon(lat0, lon0, x, y):
    return (lat0 + y / METRES_PER_DEGREE, lon0 + x / (math.cos(math.radians(lat0)) * METRES_PER_DEGREE))


def convex_hull(points):
    """Andrew's monotone chain; counter-clockwise, no repeated last point."""
    pts = sorted(set(points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def runway_ends(runways, airport, report):
    """The airport's open runways' end points within reach of it (a far one is a data error, logged)."""
    ends = []
    for row in runways:
        if row["closed"] == "1":
            continue
        for side in ("le", "he"):
            try:
                lat, lon = float(row[side + "_latitude_deg"]), float(row[side + "_longitude_deg"])
            except ValueError:
                continue
            if great_circle_metres(airport["lat"], airport["lon"], lat, lon) > RUNWAY_REACH_METRES:
                report.unmap("runway end of %s is over 8 km from it; skipped" % airport["ident"])
                continue
            ends.append((lat, lon))
    return ends


def ground_ring(lat0, lon0, points_latlon, margin):
    """The hull of `points_latlon` widened by `margin` metres, simplified at 50 m, as a closed 1e-5° int
    array (lon, lat) for atlas.encode_ring; None when it degenerates."""
    xy = []
    for lat, lon in points_latlon:
        x, y = local_xy(lat0, lon0, lat, lon)
        for k in range(CIRCLE_STEPS):
            angle = 2 * math.pi * k / CIRCLE_STEPS
            xy.append((round(x + margin * math.cos(angle), 1), round(y + margin * math.sin(angle), 1)))
    hull = convex_hull(xy)
    ring = [local_latlon(lat0, lon0, x, y) for x, y in hull]
    ring.append(ring[0])
    as_lonlat = np.array([[lon, lat] for lat, lon in ring], dtype=np.float64)
    epsilon = SIMPLIFY_METRES / METRES_PER_DEGREE
    q = atlas.quantize_ring(atlas.simplify_closed_ring(as_lonlat, epsilon))
    if q is None or len(q) > MAX_GROUND_POINTS:
        return None
    return q


def outline_ring(record):
    """An approved outline's points as a closed 1e-5° int array, checked."""
    points = record["points"]
    if not (4 <= len(points) <= MAX_GROUND_POINTS):
        raise SystemExit("error: outline %s has %d points (4 to %d)" % (record["id"], len(points),
                                                                         MAX_GROUND_POINTS))
    as_lonlat = np.array([[p[1], p[0]] for p in points], dtype=np.float64)
    q = atlas.quantize_ring(as_lonlat)
    if q is None:
        raise SystemExit("error: outline %s is not a ring" % record["id"])
    return q


def load_outlines(path):
    """airport-outlines.json's approved outlines by token; an outline with no approval stops the run."""
    data = read_json(path)
    outlines = {}
    for record in data.get("outlines", []):
        for key in ("id", "points", "imagery", "imageryDate", "reviewer", "approved"):
            if not record.get(key):
                raise SystemExit("error: outline %r has no %s; only approved outlines ship (spec §2.1)" %
                                 (record.get("id"), key))
        if record["id"] in outlines:
            raise SystemExit("error: outline %s is listed twice" % record["id"])
        outlines[record["id"]] = record
    return outlines


# ---------------------------------------------------------------------------------------------------------
# Tokens


def assign_tokens(unlockables, path, record, report):
    """Every unlockable's frozen passport token (spec §1.2): airport-tokens.json maps OurAirports' id to the
    token first given (IATA, else ident). A new airport stops the run unless --record-tokens adds it."""
    data = read_json(path) if os.path.isfile(path) else {"tokens": {}}
    tokens = {int(k): v for k, v in data.get("tokens", {}).items()}
    used = set(tokens.values())
    if len(used) != len(tokens):
        raise SystemExit("error: airport-tokens.json gives one token to two airports")
    added = 0
    for airport in sorted(unlockables, key=lambda a: a["id"]):
        if airport["id"] in tokens:
            airport["token"] = tokens[airport["id"]]
            continue
        if not record:
            raise SystemExit("error: airport %s (id %d) has no frozen token; rerun with --record-tokens" %
                             (airport["ident"], airport["id"]))
        token = airport["iata"] or airport["ident"]
        if token in used:
            token = airport["ident"]
        if token in used or not token.isascii() or len(token) > 16:
            raise SystemExit("error: no free token for %s" % airport["ident"])
        tokens[airport["id"]] = token
        used.add(token)
        airport["token"] = token
        added += 1
    present = {a["id"] for a in unlockables}
    gone = sorted(set(tokens) - present)
    if gone:
        report.note("%d frozen tokens have no airport in this data (kept, never reused): %s" %
                    (len(gone), ", ".join(tokens[i] for i in gone[:20])))
    report.counts["unlockable tokens added this run"] = added
    if record and added:
        body = {"about": data.get("about", "Frozen passport tokens: OurAirports airport id -> token. Never "
                                  "change or reuse one (World-Airports-Spec §1.2)."),
                "tokens": {str(k): tokens[k] for k in sorted(tokens)}}
        with open(path + ".partial", "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False, indent=1, sort_keys=False)
            handle.write("\n")
        os.replace(path + ".partial", path)


# ---------------------------------------------------------------------------------------------------------
# Sections


def text(value, report):
    return atlas.short_text(value, report)


def build_tzns(zone_names):
    """u16 count · short texts."""
    return struct.pack("<H", len(zone_names)) + b"".join(atlas.short_text(z, Report()) for z in zone_names)


def build_apts(unlockables, zone_index, report):
    """u16 count · records sorted by token (see Docs/World-Airports-Pack.md)."""
    out = [struct.pack("<H", len(unlockables))]
    kinds = {GROUND_CIRCLE: 0, GROUND_RUNWAYS: 0, GROUND_OUTLINE: 0}
    for a in unlockables:
        out.append(text(a["token"], report) + text(a["iata"], report) + text(a["ident"], report))
        out.append(struct.pack("<ii", round(a["lat"] * SCALE), round(a["lon"] * SCALE)))
        out.append(a["country"].encode("ascii")[:2].ljust(2, b"?"))
        out.append(struct.pack("<BH", UNLOCKABLE_TYPES[a["type"]], zone_index[a["zone"]]))
        out.append(text(a["name_en"], report) + text(a["name_es"], report) + text(a["city_en"], report)
                   + text(a["city_es"], report))
        kind, ring = a["ground"]
        kinds[kind] += 1
        if kind == GROUND_CIRCLE:
            out.append(struct.pack("<BH", kind, CIRCLE_METRES))
        else:
            out.append(struct.pack("<B", kind) + atlas.encode_ring(ring))
    report.counts["grounds: our outlines"] = kinds[GROUND_OUTLINE]
    report.counts["grounds: runway outlines + 500 m"] = kinds[GROUND_RUNWAYS]
    report.counts["grounds: 1.5 km circles (no runway ends)"] = kinds[GROUND_CIRCLE]
    return b"".join(out)


def build_pnts(points, zone_index, apt_index):
    """u16 count · sorted by IATA: 3 ASCII bytes · i32 lat · i32 lon · 2 ASCII country · u16 zone · u16
    unlockable index."""
    out = [struct.pack("<H", len(points))]
    for p in points:
        out.append(p["iata"].encode("ascii") + struct.pack("<ii", round(p["lat"] * SCALE), round(p["lon"] * SCALE))
                   + p["country"].encode("ascii")[:2].ljust(2, b"?")
                   + struct.pack("<HH", zone_index[p["zone"]], apt_index.get(p["id"], NO_AIRPORT)))
    return b"".join(out)


def build_airl(path, report):
    """u16 count · ICAO (3) · IATA (2) · short text names joined by "|"."""
    rows = read_json(path)["airlines"]
    seen_icao, seen_iata = set(), set()
    out = [struct.pack("<H", len(rows))]
    for icao, iata, names in rows:
        if len(icao) != 3 or len(iata) != 2 or icao in seen_icao or iata in seen_iata:
            raise SystemExit("error: airlines.json row %s/%s is malformed or repeated" % (icao, iata))
        seen_icao.add(icao)
        seen_iata.add(iata)
        out.append(icao.encode("ascii") + iata.encode("ascii") + text(names, report))
    report.counts["airlines"] = len(rows)
    return b"".join(out)


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


def meta_json(args, sources, tz_version):
    listed = [{"file": info["file"], "url": info["url"], "sha256": info["sha256"],
               "licence": SOURCE_LICENCES[info["subdir"]]} for _, info in sorted(sources.items())]
    listed.append({"file": "zone.tab", "url": "tzdata " + tz_version, "sha256": "", "licence":
                   SOURCE_LICENCES["tzdata"]})
    meta = {"generator": "Scripts/world-atlas/build_world_airports.py", "generatorVersion": GENERATOR_VERSION,
            "date": args.date, "tzdata": tz_version, "sources": listed}
    return json.dumps(meta, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# ---------------------------------------------------------------------------------------------------------


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Build the World airports pack (Docs/World-Airports-Pack.md).")
    parser.add_argument("--sources", required=True, help="the directory fetch-airport-sources.sh filled")
    parser.add_argument("--out", required=True, help="where to write the pack")
    parser.add_argument("--date", default="unset", help="the generation date written into META")
    parser.add_argument("--zoneinfo", default="/usr/share/zoneinfo", help="tzdata folder holding zone.tab")
    parser.add_argument("--hand-files", default=None, help="folder of the hand-kept JSON files (self-test)")
    parser.add_argument("--record-tokens", action="store_true", help="freeze tokens for new airports")
    parser.add_argument("--unverified-sources", action="store_true", help="allow unpinned sources (self-test)")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    report = Report()
    here = os.path.dirname(os.path.abspath(__file__))
    hand = args.hand_files or here
    table = read_source_table(here)
    sources = locate_sources(args.sources, table, not args.unverified_sources, report)
    airports = read_airports(sources["ourairports/airports.csv"]["path"], report)
    if len(airports) > 200_000:
        raise SystemExit("error: too many airports")
    runways_by_airport = {}
    for row in read_csv(sources["ourairports/runways.csv"]["path"], 400_000):
        runways_by_airport.setdefault(row["airport_ref"], []).append(row)
    wd = load_wikidata(sources)
    zones, tz_version = read_zone_tab(args.zoneinfo)
    by_country = {}
    for row in zones:
        by_country.setdefault(row[0], []).append(row)
    outlines = load_outlines(os.path.join(hand, "airport-outlines.json"))

    unlockables = [a for a in airports if a["type"] in UNLOCKABLE_TYPES]
    if len(unlockables) > MAX_AIRPORTS:
        raise SystemExit("error: %d unlockables, over %d" % (len(unlockables), MAX_AIRPORTS))
    assign_tokens(unlockables, os.path.join(hand, "airport-tokens.json"), args.record_tokens, report)
    seen_iata = {}
    points = []
    for a in airports:
        if a["iata"]:
            if len(a["iata"]) != 3 or not a["iata"].isalpha() or not a["iata"].isascii():
                report.unmap("IATA code %r of %s is not three letters; skipped" % (a["iata"], a["ident"]))
                a["iata"] = ""
                continue
            if a["iata"] in seen_iata:
                report.unmap("IATA %s is on two airports (%s, %s); the first kept" %
                             (a["iata"], seen_iata[a["iata"]], a["ident"]))
                continue
            seen_iata[a["iata"]] = a["ident"]
            points.append(a)
    if len(points) > MAX_POINTS:
        raise SystemExit("error: %d IATA points, over %d" % (len(points), MAX_POINTS))

    named_es = cities_es = 0
    assigned = []
    point_ids = {p["id"] for p in points}
    for a in airports:
        if a["id"] in point_ids or a["type"] in UNLOCKABLE_TYPES:
            a["zone"] = zone_for(a, zones, by_country, report)
            assigned.append((a["iata"] or a["ident"], a["lat"], a["lon"], a["zone"]))
    check_zones(assigned, report)
    for a in unlockables:
        code = a["iata"] or a["ident"]
        item = wikidata_item(a, wd)
        a["name_en"] = everyday_english(code, a["name"])
        a["name_es"] = everyday_spanish(code, wd["es"].get(item, "") if item else "", a["name_en"])
        town = plain_municipality(a["municipality"])
        city = served_city(item, town, a["name"], wd) if item else None
        a["city_en"] = wd["city_en"].get(city, "") if city else town
        es = wd["city_es"].get(city, "") if city else ""
        a["city_es"] = "" if es == a["city_en"] else es
        named_es += bool(a["name_es"])
        cities_es += bool(a["city_es"])
        if a["token"] in outlines:
            a["ground"] = (GROUND_OUTLINE, outline_ring(outlines[a["token"]]))
            continue
        ends = runway_ends(runways_by_airport.get(str(a["id"]), []), a, report)
        # Near the poles a local flat projection fails (cos(lat) -> 0): those airports keep a circle.
        polar = abs(a["lat"]) > 80
        # The airport's own point joins the hull (OurAirports puts it at a terminal or the field's middle, up to
        # 8 km from a runway end), so its grounds always hold it.
        ends = ends + [(a["lat"], a["lon"])] if ends else ends
        ring = ground_ring(a["lat"], a["lon"], ends, RUNWAY_MARGIN_METRES) if ends and not polar else None
        a["ground"] = (GROUND_RUNWAYS, ring) if ring is not None else (GROUND_CIRCLE, None)
    unknown_outlines = sorted(set(outlines) - {a["token"] for a in unlockables})
    if unknown_outlines:
        raise SystemExit("error: outlines for unknown tokens: %s" % ", ".join(unknown_outlines))

    unlockables.sort(key=lambda a: a["token"])
    points.sort(key=lambda a: a["iata"])
    zone_names = sorted({a["zone"] for a in unlockables} | {p["zone"] for p in points})
    zone_index = {z: i for i, z in enumerate(zone_names)}
    apt_index = {a["id"]: i for i, a in enumerate(unlockables)}
    report.counts["unlockables (large + medium)"] = len(unlockables)
    report.counts["unlockables large"] = sum(a["type"] == "large_airport" for a in unlockables)
    report.counts["unlockables without IATA"] = sum(not a["iata"] for a in unlockables)
    report.counts["IATA points (arcs)"] = len(points)
    report.counts["zones used"] = len(zone_names)
    report.counts["Spanish airport names"] = named_es
    report.counts["Spanish city names"] = cities_es
    sections = [("TZNS", build_tzns(zone_names)), ("APTS", build_apts(unlockables, zone_index, report)),
                ("PNTS", build_pnts(points, zone_index, apt_index)),
                ("AIRL", build_airl(os.path.join(hand, "airlines.json"), report)),
                ("META", meta_json(args, sources, tz_version))]
    pack = assemble(sections, report)
    print("World airports pack: %s (%d bytes, cap %d)" % (args.out, len(pack), SIZE_CAP))
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
    if len(report.unmapped) > 200:
        print("  ... %d more" % (len(report.unmapped) - 200))
    print("sha256: %s" % hashlib.sha256(pack).hexdigest())
    if len(pack) > SIZE_CAP:
        print("error: the pack is %d bytes, over the %d-byte cap; nothing written" % (len(pack), SIZE_CAP),
              file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out + ".partial", "wb") as handle:
        handle.write(pack)
    os.replace(args.out + ".partial", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Re-check FoodCatalog's load-time retype of branded products filed as SR Legacy against FDC itself.

Docs/Ingredient-Search-Deep-Research-2026-09-29.md §5 / §8 F6(2): the committed FoodCatalog.sqlite
types some packaged products `srLegacy`. `BundledRowCorrection.retypingMisfiledBrandedProducts`
(FernletKit/Sources/FoodCatalog/BundledRowCorrection.swift) types them `branded` at load by two
rules: a compact-source `srLegacy` row whose category is not one of SR Legacy's food groups, or one
whose FDC id is in `brandedFDCIDsInSRFoodGroups`. This script proves the two rules pick EXACTLY the
rows FoodData Central's own `food.csv` types `branded_food` — no product missed, no real SR Legacy or
Foundation food retyped — and exits non-zero otherwise.

It reads both rule inputs out of the Swift source (the group-name set and the id set), so the frozen
literals there, not a copy here, are what is checked.

Source: USDA FoodData Central full CSV archive, 2026-04-30 (CC0 1.0 / US public domain), the file the
offline pipeline's manifest pins as `usda_fdc_consumer`. The archive's byte size and SHA-256, and the
`food.csv` member's SHA-256, are checked against FoodDataSource/FoodCatalogSourceManifest.json before
any row is trusted. The member is streamed from the archive, never extracted. No network access.

Usage (from the repo root):
    python3 Scripts/food-catalog/misfiled_branded_audit.py [path/to/FoodData_Central_csv_2026-04-30.zip]
The default path is ~/Downloads/FoodData_Central_csv_2026-04-30.zip.
"""
import csv
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import zipfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOG = os.path.join(REPO, "FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite")
SWIFT = os.path.join(REPO, "FernletKit/Sources/FoodCatalog/BundledRowCorrection.swift")
MANIFEST = os.path.join(REPO, "FoodDataSource/FoodCatalogSourceManifest.json")
DEFAULT_SOURCE = os.path.expanduser("~/Downloads/FoodData_Central_csv_2026-04-30.zip")
MEMBER = "FoodData_Central_csv_2026-04-30/food.csv"
MAX_ROWS = 5_000_000   # food.csv carries ~2.1M rows; a bound, not an expectation
COMPACT_ID = re.compile(r"00000000-0000-5000-8000-(\d{12})")


def manifest_entry():
    manifest = json.load(open(MANIFEST))
    return next(s for s in manifest["sources"] if s["key"] == "usda_fdc_consumer")


def verified_archive(path, entry):
    size = os.path.getsize(path)
    if size != entry["bytes"]:
        sys.exit(f"{path}: {size} bytes, the manifest pins {entry['bytes']}")
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != entry["sha256"]:
        sys.exit(f"{path}: SHA-256 {digest.hexdigest()} is not the manifest's {entry['sha256']}")
    return zipfile.ZipFile(path)


def swift_literal(name):
    source = open(SWIFT).read()
    match = re.search(rf"static let {name}: Set<\w+> = \[(.*?)\]", source, re.S)
    if not match:
        sys.exit(f"{SWIFT}: no `{name}` set literal")
    return match.group(1)


def rule_inputs():
    groups = set(re.findall(r'"([^"]+)"', swift_literal("srLegacyFoodGroups")))
    ids = {int(text) for text in re.findall(r"\d+", swift_literal("brandedFDCIDsInSRFoodGroups"))}
    if len(groups) != 25:
        sys.exit(f"read {len(groups)} SR Legacy food groups from the Swift source, expected 25")
    return groups, ids


def catalog_sr_rows():
    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    rows = {}
    for text, category, size in con.execute("select id, category, serving_size from food where data_type = 'srLegacy'"):
        match = COMPACT_ID.fullmatch(text)
        if match:
            rows[int(match.group(1))] = (category, size)
    return rows


def fdc_types(archive, wanted, entry):
    digest = hashlib.sha256()
    types = {}
    with archive.open(MEMBER) as raw:
        hashing = HashingReader(raw, digest)
        for count, row in enumerate(csv.DictReader(io.TextIOWrapper(hashing, encoding="utf-8"))):
            if count >= MAX_ROWS:
                sys.exit(f"{MEMBER}: more than {MAX_ROWS} rows")
            fdc_id = int(row["fdc_id"])
            if fdc_id in wanted:
                types[fdc_id] = row["data_type"]
        hashing.drain()
    expected = entry["provenance"]["memberSHA256"]["food.csv"]
    if digest.hexdigest() != expected:
        sys.exit(f"{MEMBER}: SHA-256 {digest.hexdigest()} is not the manifest's {expected}")
    return types


class HashingReader(io.RawIOBase):
    """A read-through wrapper that hashes every byte the CSV reader consumes (and the tail it does not)."""

    def __init__(self, raw, digest):
        self.raw, self.digest = raw, digest

    def readable(self):
        return True

    def readinto(self, buffer):
        chunk = self.raw.read(len(buffer))
        self.digest.update(chunk)
        buffer[:len(chunk)] = chunk
        return len(chunk)

    def drain(self):
        for block in iter(lambda: self.raw.read(1 << 20), b""):
            self.digest.update(block)


def main():
    entry = manifest_entry()
    archive = verified_archive(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOURCE, entry)
    groups, frozen_ids = rule_inputs()
    rows = catalog_sr_rows()
    types = fdc_types(archive, set(rows), entry)
    missing = sorted(set(rows) - set(types))
    if missing:
        sys.exit(f"{len(missing)} compact srLegacy rows have no row in food.csv (first: {missing[:5]})")
    by_category = {i for i, (category, _) in rows.items() if category not in groups}
    retyped = by_category | (frozen_ids & set(rows))
    branded = {i for i, kind in types.items() if kind == "branded_food"}
    if frozen_ids - set(rows):
        sys.exit(f"frozen ids with no compact srLegacy row: {sorted(frozen_ids - set(rows))}")
    if retyped != branded:
        sys.exit(f"retype disagrees with FDC: missed {sorted(branded - retyped)}, wrongly retyped {sorted(retyped - branded)}")
    kept = {types[i] for i in set(rows) - retyped}
    if not kept <= {"sr_legacy_food", "foundation_food"}:
        sys.exit(f"rows left srLegacy that FDC types otherwise: {sorted(kept)}")
    rebased = sum(1 for i in retyped if rows[i][1] != 100)
    print(f"OK: {len(retyped)} retyped ({len(by_category)} by category + {len(retyped - by_category)} by FDC id), "
          f"all branded_food in FDC; {len(rows) - len(retyped)} kept srLegacy, all sr_legacy_food/foundation_food; "
          f"{rebased} retyped rows sit on a label serving and are rebased by F2")


if __name__ == "__main__":
    main()

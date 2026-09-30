#!/usr/bin/env python3
"""Regenerate FernletKit/Sources/FoodCatalog/Resources/FoodCatalogSupplement.json.

Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.2 / §8 F6: the build that produced the
committed FoodDataSource/USDAFoodItems.json (and so the committed FoodCatalog.sqlite) dropped EVERY
SR Legacy food whose protein, carbohydrate and fat are all zero — exactly 32 foods, among them
"Salt, table" (173468), "Leavening agents, baking soda" (175040) and "Beverages, water, tap,
drinking" (173647). The catalog binary is never regenerated for a data fix, so the app reads the
restored rows from this small JSON beside it (FoodCatalog's `BundledFoodSupplement`).

What it restores, by rule rather than by hand-picking:
  * an SR Legacy food whose FDC id has no row in the committed catalog, AND
  * whose raw protein (1003), carbohydrate (1005) and fat (1004) are all 0 — the build's drop rule;
    the script refuses to run if those two sets are not identical, AND
  * whose raw energy (1008) is 0. The six distilled spirits (231-295 kcal/100 g, all from alcohol)
    are left out on purpose: Fernlet's nutrition model has no alcohol term, so a 0/0/0 row would
    show 0 kcal for vodka. That leaves 26 foods: salt, baking soda, waters, teas, club soda, a
    calorie-free sports drink and one seasoning mix.

Rows are written in the compact schema the committed USDAFoodItems.json uses and decoded by
`FoodDataCatalog.foodItems(from:)`, so ids (00000000-0000-5000-8000-<fdcId>), brand provenance
("USDA FDC <id>"), rounding and data type follow the same code path as every other SR row. The
per-field mapping (macros to one decimal, micronutrients by FDC nutrient id with zeros omitted,
omega-3 as EPA + DHA, tags by category, portions from the raw `modifier`) is VALIDATED before writing: the same function
must reproduce the committed USDAFoodItems.json record for every one of the 7,761 SR foods the
catalog kept, or the script stops.

Source: USDA FoodData Central SR Legacy, April 2018 JSON (CC0 1.0 / US public domain), the file the
offline pipeline's manifest pins as `usda_sr_validation` — its byte size and SHA-256 are checked
against FoodDataSource/FoodCatalogSourceManifest.json before it is read. No network access.

Usage (from the repo root):
    python3 Scripts/food-catalog/sr_zero_energy_supplement.py [path/to/FoodData_Central_sr_legacy_food_json_2018-04.json]
The default path is ~/Downloads/FoodData_Central_sr_legacy_food_json_2018-04.json.
"""
import collections
import hashlib
import json
import os
import re
import sqlite3
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOG = os.path.join(REPO, "FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite")
COMPACT = os.path.join(REPO, "FoodDataSource/USDAFoodItems.json")
MANIFEST = os.path.join(REPO, "FoodDataSource/FoodCatalogSourceManifest.json")
OUTPUT = os.path.join(REPO, "FernletKit/Sources/FoodCatalog/Resources/FoodCatalogSupplement.json")
DEFAULT_SOURCE = os.path.expanduser("~/Downloads/FoodData_Central_sr_legacy_food_json_2018-04.json")
MAX_SOURCE_BYTES = 300_000_000   # the pinned file is 210,758,826
MAX_FOODS = 10_000               # the pinned file has 7,793
EXPECTED_DROPPED = 32
EXPECTED_RESTORED = 26

PROTEIN, FAT, CARBS, ENERGY = 1003, 1004, 1005, 1008
# Compact key -> FDC nutrient ids, first present wins — the ids
# USDAFoodItemRecord.applyFDCMicronutrients (FernletKit/Sources/FoodCatalog/FoodDataCatalog.swift) reads,
# except omega-3, which the committed compact file states as EPA + DHA (see OMEGA3_SUM).
MICRONUTRIENTS = [
    ("fiber", [1079]), ("sugar", [2000, 1063]), ("saturatedFat", [1258]), ("cholesterol", [1253]),
    ("vitaminA", [1106]), ("vitaminC", [1162]), ("vitaminD", [1114]), ("vitaminE", [1109]),
    ("vitaminK", [1185]), ("vitaminB6", [1175]), ("vitaminB12", [1178]), ("thiamin", [1165]),
    ("riboflavin", [1166]), ("niacin", [1167]), ("folate", [1177]), ("calcium", [1087]),
    ("iron", [1089]), ("magnesium", [1090]), ("phosphorus", [1091]), ("potassium", [1092]),
    ("sodium", [1093]), ("zinc", [1095]),
]
OMEGA3_SUM = (1278, 1272)   # EPA + DHA: reproduces all 7,761 kept rows' `omega3` (validated below)


def verified_source(path):
    manifest = json.load(open(MANIFEST))
    entry = next(s for s in manifest["sources"] if s["key"] == "usda_sr_validation")
    size = os.path.getsize(path)
    if size != entry["bytes"] or size > MAX_SOURCE_BYTES:
        sys.exit(f"{path}: {size} bytes, the manifest pins {entry['bytes']}")
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != entry["sha256"]:
        sys.exit(f"{path}: SHA-256 {digest.hexdigest()} is not the manifest's {entry['sha256']}")
    foods = json.load(open(path))["SRLegacyFoods"]
    if len(foods) > MAX_FOODS or len(foods) != entry["expected"]["foods"]:
        sys.exit(f"{path}: {len(foods)} foods, expected {entry['expected']['foods']}")
    return foods


def amounts(food):
    return {n["nutrient"]["id"]: n.get("amount") for n in food.get("foodNutrients", [])}


def compact_record(food, tags_by_category):
    values = amounts(food)
    record = {
        "fdcId": food["fdcId"], "name": food["description"], "servingSize": 100.0, "servingUnit": "g",
        "protein": round(float(values.get(PROTEIN) or 0), 1),
        "carbs": round(float(values.get(CARBS) or 0), 1),
        "fat": round(float(values.get(FAT) or 0), 1),
        "category": food["foodCategory"]["description"],
    }
    for key, ids in MICRONUTRIENTS:
        value = next((values[i] for i in ids if values.get(i) is not None), None)
        if value:
            record[key] = float(value)
    omega3 = round(sum(values.get(i) or 0 for i in OMEGA3_SUM), 6)
    if omega3:
        record["omega3"] = float(omega3)
    record["tags"] = tags_by_category[record["category"]]
    portions = [  # a raw amount of 0 means one of the measure
        {"amount": float(p.get("amount") or 1), "unit": p["modifier"], "gramWeight": float(p["gramWeight"]),
         "description": p["modifier"]}
        for p in food.get("foodPortions", [])
        if p.get("gramWeight") and p.get("modifier")
    ]
    if portions:
        record["portions"] = portions
    return record


def catalog_fdc_ids():
    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    ids = set()
    for (text,) in con.execute("select id from food"):
        match = re.fullmatch(r"00000000-0000-5000-8000-0*(\d+)", text)
        if match:
            ids.add(int(match.group(1)))
    return ids


def main():
    foods = verified_source(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOURCE)
    present = catalog_fdc_ids()
    compact = {row["fdcId"]: row for row in json.load(open(COMPACT)) if "fdcId" in row}
    by_id = {food["fdcId"]: food for food in foods}
    kept = [by_id[i] for i in by_id if i in present and i in compact]
    tag_votes = collections.defaultdict(collections.Counter)
    for food in kept:
        tag_votes[compact[food["fdcId"]]["category"]][tuple(compact[food["fdcId"]].get("tags", []))] += 1
    tags_by_category = {category: list(votes.most_common(1)[0][0]) for category, votes in tag_votes.items()}
    mismatched = [food["fdcId"] for food in kept if compact_record(food, tags_by_category) != compact[food["fdcId"]]]
    if mismatched:
        sys.exit(f"the mapping does not reproduce {len(mismatched)} kept SR rows (first: {mismatched[:5]})")
    dropped = [food for food in foods if food["fdcId"] not in present]
    all_zero = [food for food in foods if all(not amounts(food).get(n) for n in (PROTEIN, CARBS, FAT))]
    if {f["fdcId"] for f in dropped} != {f["fdcId"] for f in all_zero} or len(dropped) != EXPECTED_DROPPED:
        sys.exit("the dropped SR foods are no longer exactly the zero-macro ones — re-read the report §6.2")
    restored = [f for f in dropped if not amounts(f).get(ENERGY)]
    if len(restored) != EXPECTED_RESTORED:
        sys.exit(f"{len(restored)} zero-energy foods, expected {EXPECTED_RESTORED}")
    rows = [compact_record(food, tags_by_category) for food in sorted(restored, key=lambda f: f["fdcId"])]
    with open(OUTPUT, "w") as handle:
        json.dump(rows, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    print(f"validated the mapping on {len(kept)} kept SR rows; wrote {len(rows)} rows to {OUTPUT}")


if __name__ == "__main__":
    main()

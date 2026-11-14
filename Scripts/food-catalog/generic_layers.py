#!/usr/bin/env python3
"""Regenerate the two bundled generic-food layers that ship BESIDE FoodCatalog.sqlite.

Owner decisions of 2026-11-13 (ROADMAP G1, "Food (decided 11-13)"): the committed base catalog
`FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` holds only 202 of FNDDS 2021-2023's
5,432 survey foods and is never regenerated for a data change, so the rest ship as small,
separately bundled SQLite files in the base's own runtime schema (`FoodCatalogSchema`: the `food`
table plus the contentless `food_fts` FTS5 index over name / category / tags), read by the same
`SQLiteBundledFoodSource` and unioned in by `FoodCatalog.bundled(bundle:)`:

  Resources/FoodCatalogSurvey.sqlite  FNDDS 2021-2023 (USDA FoodData Central 2026-04-30), every
                                      survey food the base does not already ship.
  Resources/FoodCatalogCNF.sqlite     Health Canada's Canadian Nutrient File 2026, the foods that are
                                      Canadian rather than a copy of USDA data Fernlet already ships.

THE FNDDS LAYER, by rule:
  * every `Survey (FNDDS)` food of the schema-v4 preservation artifact (built by
    `catalog_pipeline.py` from the manifest-pinned FDC 2026-04-30 CSV archive; its own
    `source_manifest` row, checked below, pins that archive's SHA-256), EXCEPT
  * the foods whose id the base catalog already serves (the 202 curated survey rows), AND
  * the alcoholic drinks whose protein, carbohydrate and fat are all 0 while energy is not
    (vodka, gin, ...): Fernlet's `Macros` has no alcohol term, so a 0/0/0 row would claim the drink
    is free — the same rule `sr_zero_energy_supplement.py` applies to the SR spirits.
  Ids are the base's own FDC rule (`USDAFoodItemRecord.stableUSDAID` in FoodDataCatalog.swift):
  `00000000-0000-5000-8000-<12-digit FDC id>`, so a saved recipe line resolves the same row whichever
  file serves it, and a base row is never duplicated. Rows mirror the base's 202 curated survey rows:
  brand provenance "USDA FDC <id>", category "Survey (FNDDS) - <WWEIA category>", tags
  usda / survey / fndds / category, source `usda` — but data type `supplementalReference` (the layers'
  search tier, below the base's reference tiers; measured: as `survey` they displaced 238 pinned SR
  answers) and on the SR Legacy basis
  (per 100 g, macros rounded half-up to whole grams, micronutrients per 100 g with true zeros kept).
  Portions are FNDDS's household measures ("1 banana" 126 g -> amount 1, unit "banana"); the
  "Quantity not specified" / "Guideline amount ..." default entries carry no amount and are left out.

THE CNF LAYER, by rule (5,993 foods in the 2026 file):
  * left out: `Food_Source_Code` 0, "Food based on data from USDA: No changes" (3,529) — values
    Fernlet already ships from SR Legacy, or older USDA rows it chose not to ship;
  * left out: `Food_Source_Code` 12, "information from USDA survey files", whose `USDA_NDB_Code`
    names an SR Legacy or FNDDS food Fernlet ships — USDA's numbers with no Canadian change;
  * left out: zero-macro alcoholic drinks, as above;
  * kept: everything else — USDA-derived foods whose nutrients Canada changed, analysed, calculated
    or took from Canadian manufacturers (codes 1, 3, 4, 6, 10), foods USDA has since deleted (11),
    and the Canadian foods (20-37: SNAP-CAN analyses, CNF recipes, traditional foods, ...).
  Names are the English descriptions (French are not used yet). Ids are
  `00000000-0000-5000-8002-<12-digit CNF Food_Code>` — a namespace of their own, beside FDC's 8000
  and the one curated alias's 8001. Source token `canadianNutrientFile` (FoodItemSource), data type
  `supplementalReference` (the layers' tier; as `srLegacy` FoodCatalog's load-time F6 rule would also
  retype every row filed outside an SR food group as branded); brand provenance "CNF <Food_Code>"; category the CNF food group;
  tags the base's own tags for the matching SR food group. Portions come from Measure_Name +
  Measure_Weight_Conversion (user-defined measures only; refuse and yield rows are not servings).
  In the 2026 CSV that column is the measure's weight in grams (every "100 g" measure reads 100), not
  the per-100 g multiplier the older CNF documentation describes.
  Licence: Open Government Licence - Canada; every surface that names a CNF row carries
  "Contains information licensed under the Open Government Licence – Canada."

Both inputs are checked against FoodDataSource/FoodCatalogLayerManifest.json (size + SHA-256) and the
normalizer is validated against every base row before anything is written. Provenance, the rules'
counts and the outputs' SHA-256 are written back into that manifest. No network access. The archives
stay outside Git; the CNF zip is read member by member and never extracted.

Usage (from the repo root):
    python3 -I Scripts/food-catalog/generic_layers.py [ARTIFACT_SQLITE] [CNF_ZIP]
Defaults: $FERNLET_FOOD_ARTIFACT, else the sibling `fernlet-wt-food/.food-catalog-build/FoodCatalog.sqlite`
preservation artifact (pass the path from a worktree), and ~/Downloads/cnf_fcen_all-files-data_2026.zip.
"""
import csv
import decimal
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import unicodedata
import zipfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RESOURCES = os.path.join(REPO, "FernletKit/Sources/FoodCatalog/Resources")
BASE = os.path.join(RESOURCES, "FoodCatalog.sqlite")
SURVEY_OUT = os.path.join(RESOURCES, "FoodCatalogSurvey.sqlite")
CNF_OUT = os.path.join(RESOURCES, "FoodCatalogCNF.sqlite")
MANIFEST = os.path.join(REPO, "FoodDataSource/FoodCatalogLayerManifest.json")
DEFAULT_ARTIFACT = os.environ.get("FERNLET_FOOD_ARTIFACT") or os.path.join(
    os.path.dirname(REPO), "fernlet-wt-food/.food-catalog-build/FoodCatalog.sqlite")
DEFAULT_CNF = os.path.expanduser("~/Downloads/cnf_fcen_all-files-data_2026.zip")
MAX_CNF_MEMBER_BYTES = 64_000_000   # the largest pinned member, Nutrient_Amount.csv, is 21,083,047
MAX_ROWS = 20_000                   # each layer; FNDDS has 5,432 foods and CNF 5,993
SCHEMA_USER_VERSION = 2             # FoodCatalogSchema.userVersion

# Mirrors FoodCatalogSchema (FernletKit/Sources/FoodCatalog/BundledFoodStore.swift); change in lockstep.
CREATE_SQL = [
    """CREATE TABLE food (
    food_id INTEGER PRIMARY KEY,
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    brand_source TEXT,
    serving_size REAL NOT NULL,
    serving_unit TEXT NOT NULL,
    protein INTEGER NOT NULL,
    carbs INTEGER NOT NULL,
    fat INTEGER NOT NULL,
    category TEXT NOT NULL,
    source TEXT NOT NULL,
    data_type TEXT NOT NULL,
    serving_description TEXT,
    verification_policy_days INTEGER NOT NULL,
    is_flagged INTEGER NOT NULL,
    micronutrients TEXT,
    tags TEXT,
    portions TEXT,
    gtin_upc TEXT
)""",
    "CREATE INDEX idx_food_id ON food(id)",
    "CREATE INDEX idx_food_normalized_name ON food(normalized_name)",
    "CREATE INDEX idx_food_gtin_upc ON food(gtin_upc)",
    "CREATE VIRTUAL TABLE food_fts USING fts5(name, category, tags, content='', columnsize=0, tokenize='unicode61')",
]

# Compact key -> FDC nutrient ids (first present wins), as sr_zero_energy_supplement.py and
# USDAFoodItemRecord.applyFDCMicronutrients read them; omega-3 is EPA + DHA like the SR rows.
FDC_MICRONUTRIENTS = [
    ("fiber", ["1079"]), ("sugar", ["2000", "1063"]), ("saturatedFat", ["1258"]), ("cholesterol", ["1253"]),
    ("vitaminA", ["1106"]), ("vitaminC", ["1162"]), ("vitaminD", ["1114"]), ("vitaminE", ["1109"]),
    ("vitaminK", ["1185"]), ("vitaminB6", ["1175"]), ("vitaminB12", ["1178"]), ("thiamin", ["1165"]),
    ("riboflavin", ["1166"]), ("niacin", ["1167"]), ("folate", ["1177"]), ("calcium", ["1087"]),
    ("iron", ["1089"]), ("magnesium", ["1090"]), ("phosphorus", ["1091"]), ("potassium", ["1092"]),
    ("sodium", ["1093"]), ("zinc", ["1095"]),
]
FDC_OMEGA3 = ("1278", "1272")
FDC_MACROS = {"protein": "1003", "carbs": "1005", "fat": "1004", "energy": "1008"}

# The same keys from CNF's nutrient codes (Nutrient_Name.csv): vitamin A as RAE, vitamin D in µg,
# folate as total folacin (FDC 1177's meaning), niacin preformed (FDC 1167's), omega-3 as EPA + DHA.
CNF_MICRONUTRIENTS = [
    ("fiber", ["291"]), ("sugar", ["269"]), ("saturatedFat", ["606"]), ("cholesterol", ["601"]),
    ("vitaminA", ["320"]), ("vitaminC", ["401"]), ("vitaminD", ["328"]), ("vitaminE", ["323"]),
    ("vitaminK", ["430"]), ("vitaminB6", ["415"]), ("vitaminB12", ["418"]), ("thiamin", ["404"]),
    ("riboflavin", ["405"]), ("niacin", ["406"]), ("folate", ["417"]), ("calcium", ["301"]),
    ("iron", ["303"]), ("magnesium", ["304"]), ("phosphorus", ["305"]), ("potassium", ["306"]),
    ("sodium", ["307"]), ("zinc", ["309"]),
]
CNF_OMEGA3 = ("629", "621")
CNF_MACROS = {"protein": "203", "carbs": "205", "fat": "204", "energy": "208"}
CNF_DROPPED_SOURCE = "0"            # "Food based on data from USDA: No changes"
CNF_SURVEY_FILES_SOURCE = "12"      # "Food based on data from USDA: information from USDA survey files"
CNF_SERVING_MEASURE_TYPE = "6"      # "User-defined"; 3 is refuse and 9 is yield
CNF_ID_PREFIX = "00000000-0000-5000-8002-"
FDC_ID_PREFIX = "00000000-0000-5000-8000-"
CNF_SOURCE_TOKEN = "canadianNutrientFile"
# FoodDataType.supplementalReference: the layers' own search tier, below the base's reference tiers.
LAYER_DATA_TYPE = "supplementalReference"
LEADING_AMOUNT = re.compile(r"^(\d+(?:\.\d+)?(?:/\d+)?)\s+(\S.*)$")


def normalized(text):
    """FoodItemSearch.normalized: fold diacritics and case, letters/digits kept, runs of anything else
    one space. Validated against every base row's stored normalized_name in `check_normalizer`."""
    folded = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn").lower()
    spaced = "".join(c if c.isalpha() or c.isnumeric() else " " for c in folded)
    return " ".join(spaced.split())


def check_normalizer(base):
    rows = base.execute("select name, normalized_name from food").fetchall()
    wrong = [name for name, stored in rows if normalized(name) != stored]
    if wrong:
        sys.exit(f"the normalizer disagrees with the base on {len(wrong)} rows (first: {wrong[:3]})")
    return len(rows)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verified(path, pin):
    size = os.path.getsize(path)
    if size != pin["bytes"]:
        sys.exit(f"{path}: {size} bytes, the manifest pins {pin['bytes']}")
    digest = sha256(path)
    if digest != pin["sha256"]:
        sys.exit(f"{path}: SHA-256 {digest} is not the manifest's {pin['sha256']}")
    return path


def half_up(text):
    """Swift's `.rounded()` for a non-negative amount: half away from zero, on the exact source text."""
    if text is None or text == "":
        return 0
    return int(decimal.Decimal(text).quantize(decimal.Decimal(1), rounding=decimal.ROUND_HALF_UP))


def number(text):
    value = float(text)
    return int(value) if value.is_integer() else value


def micronutrients(values, mapping, omega3_ids):
    micros = {}
    for key, ids in mapping:
        text = next((values[i] for i in ids if values.get(i) not in (None, "")), None)
        if text is not None:
            micros[key] = number(text)
    present = [values[i] for i in omega3_ids if values.get(i) not in (None, "")]
    if present:
        micros["omega3"] = number(repr(round(sum(float(v) for v in present), 6)))
    return micros


def is_free_alcohol(values, macro_ids):
    raw = [float(values.get(macro_ids[k]) or 0) for k in ("protein", "carbs", "fat")]
    return not any(raw) and float(values.get(macro_ids["energy"]) or 0) > 0


def portion(description, gram_weight):
    """'1 banana' -> amount 1, unit 'banana'; a fraction or decimal amount is read as one number."""
    match = LEADING_AMOUNT.match(description.strip())
    if not match or gram_weight <= 0:
        return None
    amount_text, unit = match.groups()
    if "/" in amount_text:
        top, bottom = amount_text.split("/")
        amount = int(top) / int(bottom) if int(bottom) else 0
    else:
        amount = float(amount_text)
    if amount <= 0:
        return None
    return {"amount": number(repr(amount)), "description": unit, "gramWeight": number(repr(gram_weight)), "unit": unit}


def row(food_id, name, brand, category, source, data_type, values, mapping, omega3_ids, macro_ids, tags, portions):
    return {
        "id": food_id, "name": name, "brand": brand, "category": category, "source": source,
        "dataType": data_type,
        "protein": half_up(values.get(macro_ids["protein"])),
        "carbs": half_up(values.get(macro_ids["carbs"])),
        "fat": half_up(values.get(macro_ids["fat"])),
        "micros": micronutrients(values, mapping, omega3_ids), "tags": tags, "portions": portions,
    }


# MARK: - FNDDS

def survey_rows(artifact_path, base_ids, report):
    con = sqlite3.connect(f"file:{artifact_path}?mode=ro", uri=True)
    foods = con.execute(
        "select food_id, source_id, display_name, category_name from food "
        "where source_key = 'usda_fdc_consumer' and data_type = 'Survey (FNDDS)' order by cast(source_id as integer)"
    ).fetchall()
    if len(foods) != report["expected"]["Survey (FNDDS)"] or len(foods) > MAX_ROWS:
        sys.exit(f"{len(foods)} FNDDS foods, the manifest expects {report['expected']['Survey (FNDDS)']}")
    values = {}
    for food_id, code, amount in con.execute(
        "select nv.food_id, nv.nutrient_code, nv.amount_text from nutrient_value nv join food f using(food_id) "
        "where f.data_type = 'Survey (FNDDS)' and nv.value_status = 'numeric'"
    ):
        values.setdefault(food_id, {})[code] = amount
    portions = {}
    for food_id, description, grams in con.execute(
        "select p.food_id, p.description, p.gram_weight_text from portion p join food f using(food_id) "
        "where f.data_type = 'Survey (FNDDS)' order by p.food_id, cast(p.sequence_text as integer), p.portion_id"
    ):
        parsed = portion(description or "", float(grams or 0))
        if parsed and parsed not in portions.setdefault(food_id, []):
            portions[food_id].append(parsed)
    rows, already, alcohol = [], 0, []
    for food_id, fdc_id, name, category in foods:
        uuid = FDC_ID_PREFIX + "%012d" % int(fdc_id)
        if uuid in base_ids:
            already += 1
            continue
        food_values = values.get(food_id, {})
        if is_free_alcohol(food_values, FDC_MACROS):
            alcohol.append(name)
            continue
        tags = ["usda", "survey", "fndds", category.lower()]
        rows.append(row(uuid, name, f"USDA FDC {fdc_id}", f"Survey (FNDDS) - {category}", "usda", LAYER_DATA_TYPE,
                        food_values, FDC_MICRONUTRIENTS, FDC_OMEGA3, FDC_MACROS, tags, portions.get(food_id, [])))
    report["counts"] = {"sourceFoods": len(foods), "alreadyInBase": already,
                        "droppedZeroMacroAlcohol": len(alcohol), "written": len(rows)}
    report["droppedZeroMacroAlcohol"] = alcohol
    return rows


# MARK: - CNF

def cnf_tables(zip_path):
    tables = {}
    with zipfile.ZipFile(zip_path) as archive:
        members = {os.path.basename(info.filename): info for info in archive.infolist()}
        for name in ("Food_Name.csv", "Food_Source.csv", "CNF_Food_Group.csv", "Nutrient_Amount.csv",
                     "Measure_Name.csv", "Measure_Weight_Conversion.csv"):
            info = members.get(name)
            if info is None or info.file_size > MAX_CNF_MEMBER_BYTES:
                sys.exit(f"{zip_path}: member {name} missing or over {MAX_CNF_MEMBER_BYTES} bytes")
            text = archive.read(info).decode("utf-8-sig")
            tables[name] = list(csv.DictReader(io.StringIO(text, newline="")))
    return tables


def shipped_usda_codes(artifact_path, shipped_ids):
    """NDB numbers (SR Legacy) and FNDDS food codes of the USDA foods Fernlet ships, keyed without
    leading zeros (CNF writes NDB 1090 as '01090')."""
    con = sqlite3.connect(f"file:{artifact_path}?mode=ro", uri=True)
    codes = set()
    for code, uuid in con.execute(
        "select source_code, legacy_uuid from food where data_type in ('SR Legacy', 'Survey (FNDDS)', 'Foundation')"
    ):
        if code and uuid in shipped_ids:
            codes.add(code.lstrip("0") or "0")
    return codes


def sr_tags_by_group(base):
    votes = {}
    for category, tags in base.execute("select category, tags from food where data_type = 'srLegacy'"):
        votes.setdefault(category.lower(), {}).setdefault(tags, 0)
        votes[category.lower()][tags] += 1
    return {category: json.loads(max(counts, key=counts.get)) for category, counts in votes.items()}


def cnf_portions(tables):
    names = {r["Measure_Code"]: r["Measure_Description_and_Unit_EN"] for r in tables["Measure_Name.csv"]}
    portions = {}
    for r in tables["Measure_Weight_Conversion.csv"]:
        if r["Measure_Type_Code"] != CNF_SERVING_MEASURE_TYPE:
            continue
        parsed = portion(names.get(r["Measure_Code"], ""), round(float(r["Measure_Weight_Conversion"]), 4))
        if parsed and parsed not in portions.setdefault(r["Food_Code"], []):
            portions[r["Food_Code"]].append(parsed)
    return portions


def cnf_rows(tables, shipped_codes, group_tags, report):
    foods = sorted(tables["Food_Name.csv"], key=lambda r: int(r["Food_Code"]))
    if len(foods) != report["expected"]["foods"] or len(foods) > MAX_ROWS:
        sys.exit(f"{len(foods)} CNF foods, the manifest expects {report['expected']['foods']}")
    groups = {r["CNF_Food_Group_Code"]: r["CNF_Food_Group_Description_EN"] for r in tables["CNF_Food_Group.csv"]}
    values = {}
    for r in tables["Nutrient_Amount.csv"]:
        values.setdefault(r["Food_Code"], {})[r["Nutrient_Code"]] = r["Nutrient_Amount"]
    portions = cnf_portions(tables)
    rows, kept_by_source, dropped = [], {}, {"usdaNoChanges": 0, "usdaSurveyFilesShipped": 0, "zeroMacroAlcohol": []}
    for food in foods:
        source, ndb = food["Food_Source_Code"], food["USDA_NDB_Code"].strip().lstrip("0")
        if source == CNF_DROPPED_SOURCE:
            dropped["usdaNoChanges"] += 1
            continue
        if source == CNF_SURVEY_FILES_SOURCE and ndb and ndb in shipped_codes:
            dropped["usdaSurveyFilesShipped"] += 1
            continue
        food_values = values.get(food["Food_Code"], {})
        name = " ".join(food["Food_Description_EN"].split())
        if is_free_alcohol(food_values, CNF_MACROS):
            dropped["zeroMacroAlcohol"].append(name)
            continue
        group = groups.get(food["CNF_Food_Group_Code"], "Canadian Nutrient File")
        tags = group_tags.get(group.lower()) or [w for w in normalized(group).split() if w != "and"]
        rows.append(row(CNF_ID_PREFIX + "%012d" % int(food["Food_Code"]), name, f"CNF {food['Food_Code']}", group,
                        CNF_SOURCE_TOKEN, LAYER_DATA_TYPE, food_values, CNF_MICRONUTRIENTS, CNF_OMEGA3, CNF_MACROS,
                        tags, portions.get(food["Food_Code"], [])))
        kept_by_source[source] = kept_by_source.get(source, 0) + 1
    report["counts"] = {"sourceFoods": len(foods), "droppedUSDANoChanges": dropped["usdaNoChanges"],
                        "droppedUSDASurveyFilesAlreadyShipped": dropped["usdaSurveyFilesShipped"],
                        "droppedZeroMacroAlcohol": len(dropped["zeroMacroAlcohol"]), "written": len(rows),
                        "writtenByFoodSourceCode": dict(sorted(kept_by_source.items(), key=lambda kv: int(kv[0])))}
    report["droppedZeroMacroAlcohol"] = dropped["zeroMacroAlcohol"]
    return rows


# MARK: - Writing

def write_layer(path, rows):
    for suffix in ("", "-journal", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)
    con = sqlite3.connect(path, isolation_level=None)
    con.execute("PRAGMA page_size = 4096")
    con.execute("PRAGMA journal_mode = DELETE")
    con.execute(f"PRAGMA user_version = {SCHEMA_USER_VERSION}")
    for statement in CREATE_SQL:
        con.execute(statement)
    dumps = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    con.execute("BEGIN")
    for offset, r in enumerate(rows, start=1):
        con.execute(
            "INSERT INTO food (food_id, id, name, normalized_name, brand_source, serving_size, serving_unit, "
            "protein, carbs, fat, category, source, data_type, serving_description, verification_policy_days, "
            "is_flagged, micronutrients, tags, portions, gtin_upc) "
            "VALUES (?, ?, ?, ?, ?, 100.0, 'g', ?, ?, ?, ?, ?, ?, NULL, 180, 0, ?, ?, ?, NULL)",
            (offset, r["id"], r["name"], normalized(r["name"]), r["brand"], r["protein"], r["carbs"], r["fat"],
             r["category"], r["source"], r["dataType"], dumps(r["micros"]), dumps(r["tags"]), dumps(r["portions"])),
        )
        con.execute(
            "INSERT INTO food_fts (rowid, name, category, tags) VALUES (?, ?, ?, ?)",
            (offset, normalized(r["name"]), normalized(r["category"]), " ".join(normalized(t) for t in r["tags"])),
        )
    con.execute("COMMIT")
    con.execute("INSERT INTO food_fts(food_fts) VALUES('optimize')")
    con.execute("VACUUM")
    con.close()
    return {"file": os.path.relpath(path, REPO), "rows": len(rows), "bytes": os.path.getsize(path), "sha256": sha256(path)}


def check_ids(rows, base_ids, other_ids):
    ids = [r["id"] for r in rows]
    if len(set(ids)) != len(ids) or set(ids) & base_ids or set(ids) & other_ids:
        sys.exit("a layer id repeats, or collides with the base or the other layer")


def main():
    manifest = json.load(open(MANIFEST))
    survey, cnf = manifest["layers"]["survey"], manifest["layers"]["cnf"]
    artifact = verified(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ARTIFACT, survey["input"])
    archive = verified(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_CNF, cnf["input"])
    base = sqlite3.connect(f"file:{BASE}?mode=ro", uri=True)
    checked = check_normalizer(base)
    base_ids = {i for (i,) in base.execute("select id from food")}
    survey_list = survey_rows(artifact, base_ids, survey)
    shipped = shipped_usda_codes(artifact, base_ids | {r["id"] for r in survey_list})
    cnf_list = cnf_rows(cnf_tables(archive), shipped, sr_tags_by_group(base), cnf)
    check_ids(survey_list, base_ids, {r["id"] for r in cnf_list})
    check_ids(cnf_list, base_ids, {r["id"] for r in survey_list})
    survey["output"] = write_layer(SURVEY_OUT, survey_list)
    cnf["output"] = write_layer(CNF_OUT, cnf_list)
    with open(MANIFEST, "w") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"normalizer agrees with all {checked} base rows")
    print(f"FNDDS: {json.dumps(survey['counts'])} -> {survey['output']['bytes']} bytes")
    print(f"CNF:   {json.dumps(cnf['counts'])} -> {cnf['output']['bytes']} bytes")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Food search Phase 0: the read-only database half of the brand-search baseline.

Opens the bundled base catalog and (when present) the branded On-Demand-Resource catalog READ-ONLY and
writes two things:

1. The panel ORACLE. For every entry of Tests/FoodSearchBaseline/brand-panel.json it counts the rows in
   each database that satisfy the entry's acceptable-row predicate, using the same canonicalisation as
   the Swift probe (FoodSearchBrandBaselineProbeTests.BrandSearchText). With the probe's pool and rank
   numbers this separates three failures: the product is not in the data; the FTS gate or the row cap
   drops it; ranking buries it. It also counts the brand's rows whose NAME lacks the brand (reachable
   today only through brand_source, which neither FTS nor the scorer indexes) and the FTS gate's answer
   for the whole query.

2. The nutrition and identity AUDIT the plan asks for before branded exposure grows: serving basis,
   macro plausibility, micronutrient consistency, barcode integrity (format, check digit, duplicates,
   base/branded disjointness), duplicate identity (what the typeahead collapse key merges across
   brands), brand-field shape (owner versus consumer brand), and the restaurant data type's contents.

Counts are substring/predicate counts, not verified distinct products. Nothing is written to either
database. Output: <out>/audit.json and <out>/audit.md.

    python3 -I Scripts/food-search-baseline/audit.py \
        --base FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite \
        --branded ODRAssets/FoodCatalogBranded.sqlite \
        --panel Tests/FoodSearchBaseline/brand-panel.json --out /abs/out

A missing --branded file is reported as such, never as zero branded coverage.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict

GENERIC_TYPES = {"foundation", "srLegacy", "survey"}
CORPORATE_SUFFIX = re.compile(r"\b(inc|llc|ltd|co|corp|corporation|company|companies|foods?|usa|us|operations|holdings|group|brands?|assn|association)\b")
EXAMPLE_LIMIT = 8
BRAND_SCAN_LIMIT = 200_000
# SQL LIKE sees raw text ("WENDY'S", "jalapeño"), so the pre-filter uses a short canonical prefix that
# survives apostrophes and accents later in the word; the Python predicate does the exact match.
PREFILTER_CHARS = 5
# BundledRowCorrection's frozen inputs (FernletKit/Sources/FoodCatalog/BundledRowCorrection.swift).
COMPACT_SOURCE_PREFIX = "00000000-0000-5000-"
RAW_UNIT_ALIASES = {"GRM": "g", "GM": "g", "MLT": "ml"}


# ---- canonical text (mirrors BrandSearchText in the Swift probe) ----------------------------------

def canonical(text):
    folded = unicodedata.normalize("NFKD", text or "")
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch)).lower()
    folded = folded.replace("'", "").replace("’", "")
    spaced = "".join(ch if ch.isalnum() else " " for ch in folded)
    return " ".join(spaced.split())


def contains_run(run, text):
    return bool(run) and f" {run} " in f" {text} "


def term_matches(term, canonical_name):
    wanted = canonical(term)
    if " " in wanted:
        return f" {wanted}" in f" {canonical_name}"
    return any(word.startswith(wanted) for word in canonical_name.split())


def brand_agrees(predicate, name, brand_source):
    aliases = predicate.get("brand")
    if not aliases:
        return True
    fields = [canonical(brand_source), canonical(name)]
    return any(contains_run(canonical(alias), field) for alias in aliases for field in fields)


def accepts(predicate, name, brand_source, data_type):
    cname = canonical(name)
    if predicate.get("brand") and not brand_agrees(predicate, name, brand_source):
        return False
    if any(not term_matches(t, cname) for t in predicate.get("nameAll", [])):
        return False
    if predicate.get("nameAny") and not any(term_matches(t, cname) for t in predicate["nameAny"]):
        return False
    if any(term_matches(t, cname) for t in predicate.get("nameNone", [])):
        return False
    if predicate.get("dataTypes") and data_type not in predicate["dataTypes"]:
        return False
    return True


# ---- panel oracle --------------------------------------------------------------------------------

def like_key(predicate):
    """A cheap SQL pre-filter: one LIKE term every acceptable row must contain somewhere."""
    if predicate.get("brand"):
        return None  # brand may sit in either column; scan both via the brand pre-filter below
    terms = predicate.get("nameAll") or []
    return canonical(terms[0]).split(" ")[0][:PREFILTER_CHARS] if terms else None


def candidate_rows(db, predicate):
    """Rows that could satisfy the predicate, bounded."""
    cols = "name, brand_source, data_type"
    if predicate.get("brand"):
        clauses, args = [], []
        for alias in predicate["brand"]:
            first = canonical(alias).split(" ")[0][:PREFILTER_CHARS]
            clauses.append("(lower(brand_source) LIKE ? OR lower(name) LIKE ?)")
            args += [f"%{first}%", f"%{first}%"]
        sql = f"SELECT {cols} FROM food WHERE {' OR '.join(clauses)} LIMIT {BRAND_SCAN_LIMIT}"
        return db.execute(sql, args).fetchall()
    key = like_key(predicate)
    if key:
        return db.execute(f"SELECT {cols} FROM food WHERE lower(name) LIKE ? LIMIT {BRAND_SCAN_LIMIT}", [f"%{key}%"]).fetchall()
    terms = predicate.get("nameAny") or []
    key = canonical(terms[0]).split(" ")[0][:PREFILTER_CHARS] if terms else ""
    return db.execute(f"SELECT {cols} FROM food WHERE lower(name) LIKE ? LIMIT {BRAND_SCAN_LIMIT}", [f"%{key}%"]).fetchall()


def fts_count(db, query):
    """The FTS gate for the query's plain tokens (prefix AND), approximating the Swift gate."""
    tokens = [t for t in canonical(query).split() if len(t) >= 1]
    if not tokens:
        return 0
    match = " AND ".join(f'"{t}"*' for t in tokens)
    try:
        return db.execute("SELECT count(*) FROM food_fts WHERE food_fts MATCH ?", [match]).fetchone()[0]
    except sqlite3.Error:
        return -1


def oracle_entry(dbs, entry):
    result = {"id": entry["id"], "query": entry["query"], "split": entry["split"], "intent": entry["intent"],
              "category": entry["category"], "expectNoAcceptable": bool(entry.get("expectNoAcceptable"))}
    predicate = entry.get("accept")
    for label, db in dbs.items():
        row = {"ftsGate": fts_count(db, entry["query"])}
        if predicate:
            rows = candidate_rows(db, predicate)
            acceptable = [r for r in rows if accepts(predicate, r[0], r[1], r[2])]
            row["acceptable"] = len(acceptable)
            row["examples"] = sorted({r[0] for r in acceptable})[:EXAMPLE_LIMIT]
            if predicate.get("brand"):
                brand_rows = [r for r in rows if brand_agrees(predicate, r[0], r[1])]
                in_name = [r for r in brand_rows if brand_agrees({"brand": predicate["brand"]}, r[0], "")]
                row["brandRows"] = len(brand_rows)
                row["brandRowsNameLacksBrand"] = len(brand_rows) - len(in_name)
                row["acceptableNameLacksBrand"] = sum(
                    1 for r in acceptable if not brand_agrees({"brand": predicate["brand"]}, r[0], ""))
        result[label] = row
    return result


# ---- nutrition / identity audit ------------------------------------------------------------------

def gtin_check_digit_ok(code):
    if not code.isdigit() or len(code) not in (8, 12, 13, 14):
        return False
    digits = [int(c) for c in code]
    body, check = digits[:-1], digits[-1]
    total = sum(d * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(body)))
    return (10 - total % 10) % 10 == check


def audit_db(db):
    out = {}
    out["rows"] = db.execute("SELECT count(*) FROM food").fetchone()[0]
    out["byDataType"] = dict(db.execute("SELECT data_type, count(*) FROM food GROUP BY 1").fetchall())
    out["servingUnits"] = dict(Counter(dict(db.execute(
        "SELECT serving_unit, count(*) FROM food GROUP BY 1 ORDER BY 2 DESC LIMIT 12").fetchall())))
    out["serving"] = {
        "nonPositive": db.execute("SELECT count(*) FROM food WHERE serving_size <= 0").fetchone()[0],
        "gramsOver2000": db.execute("SELECT count(*) FROM food WHERE serving_unit IN ('g','ml') AND serving_size > 2000").fetchone()[0],
    }
    out["macros"] = audit_macros(db)
    out["micronutrients"] = audit_micros(db)
    out["barcodes"] = audit_barcodes(db)
    out["identity"] = audit_identity(db)
    out["brandField"] = audit_brand_field(db)
    out["restaurantRows"] = {
        "count": out["byDataType"].get("restaurant", 0),
        "brands": dict(Counter(dict(db.execute(
            "SELECT brand_source, count(*) FROM food WHERE data_type = 'restaurant' GROUP BY 1 ORDER BY 2 DESC LIMIT 12").fetchall()))),
    }
    return out


def load_corrected_serving(food_id, data_type, size, unit):
    """The serving `BundledRowCorrection` hands the app: raw FDC unit codes aliased to g/ml, and the
    compact-source branded set (id prefix 00000000-0000-5000-) rebased to its per-100 g/ml basis."""
    unit = RAW_UNIT_ALIASES.get((unit or "").strip().upper(), unit)
    if data_type in ("branded", "restaurant") and food_id.startswith(COMPACT_SOURCE_PREFIX) and unit in ("g", "ml") and size > 0:
        return 100.0, unit
    return size, unit


def audit_macros(db):
    """Macro grams above the serving's own grams, raw (as stored) and after the load-time correction."""
    raw = corrected = all_zero = negative = 0
    examples = []
    for food_id, name, brand, data_type, size, unit, p, c, f in db.execute(
            "SELECT id, name, brand_source, data_type, serving_size, serving_unit, protein, carbs, fat FROM food"):
        grams = p + c + f
        if p == 0 and c == 0 and f == 0:
            all_zero += 1
        if min(p, c, f) < 0:
            negative += 1
        raw_unit = RAW_UNIT_ALIASES.get((unit or "").strip().upper(), unit)
        if raw_unit == "g" and size > 0 and grams > size * 1.05 + 1:
            raw += 1
        fixed_size, fixed_unit = load_corrected_serving(food_id, data_type, size, unit)
        if fixed_unit == "g" and fixed_size > 0 and grams > fixed_size * 1.05 + 1:
            corrected += 1
            if len(examples) < EXAMPLE_LIMIT:
                examples.append(f"{name} | {brand} | {fixed_size:g} {fixed_unit} | P{p} C{c} F{f}")
    return {"allZero": all_zero, "negative": negative, "gramsExceedServingRaw": raw,
            "gramsExceedServingAfterLoadCorrection": corrected, "afterCorrectionExamples": examples}


def audit_micros(db):
    counts = Counter()
    for (fat, carbs, raw) in db.execute("SELECT fat, carbs, micronutrients FROM food"):
        if not raw:
            counts["missing"] += 1
            continue
        try:
            micro = json.loads(raw)
        except ValueError:
            counts["unparseable"] += 1
            continue
        if (micro.get("sugar") or 0) > carbs + 1:
            counts["sugarExceedsCarbs"] += 1
        if (micro.get("fiber") or 0) > carbs + 1:
            counts["fiberExceedsCarbs"] += 1
        if (micro.get("saturatedFat") or 0) > fat + 1:
            counts["saturatedExceedsFat"] += 1
        if (micro.get("sodium") or 0) > 10_000:
            counts["sodiumOver10g"] += 1
    return dict(counts)


def audit_barcodes(db):
    has_column = any(r[1] == "gtin_upc" for r in db.execute("PRAGMA table_info(food)"))
    if not has_column:
        return {"column": False}
    codes = [r[0] for r in db.execute("SELECT gtin_upc FROM food WHERE gtin_upc IS NOT NULL AND gtin_upc != ''")]
    counts = Counter(codes)
    lengths = Counter(len(c) for c in codes)
    return {
        "column": True,
        "withBarcode": len(codes),
        "lengths": {str(k): v for k, v in sorted(lengths.items())},
        "nonDigit": sum(1 for c in codes if not c.isdigit()),
        "badCheckDigit": sum(1 for c in codes if c.isdigit() and not gtin_check_digit_ok(c)),
        "duplicateCodes": sum(1 for c, n in counts.items() if n > 1),
        "rowsSharingACode": sum(n for n in counts.values() if n > 1),
    }


def audit_identity(db):
    """What a (data_type, normalized_name) collapse key merges across distinct brands."""
    groups = defaultdict(set)
    rows_per_key = Counter()
    nutrition = defaultdict(set)
    for dt, norm, brand, p, c, f, s in db.execute(
            "SELECT data_type, normalized_name, brand_source, protein, carbs, fat, serving_size FROM food"):
        key = (dt, norm)
        groups[key].add(canonical(brand))
        rows_per_key[key] += 1
        nutrition[(dt, norm, canonical(brand))].add((p, c, f, s))
    multi_brand = {k: v for k, v in groups.items() if len(v) > 1}
    same_brand_variants = sum(1 for v in nutrition.values() if len(v) > 1)
    worst = sorted(multi_brand.items(), key=lambda kv: -len(kv[1]))[:EXAMPLE_LIMIT]
    return {
        "collapseKeys": len(groups),
        "keysSpanningBrands": len(multi_brand),
        "rowsUnderKeysSpanningBrands": sum(rows_per_key[k] for k in multi_brand),
        "sameBrandSameNameDifferentNutrition": same_brand_variants,
        "widestKeys": [f"{name} ({dt}): {len(brands)} brands" for (dt, name), brands in worst],
    }


def audit_brand_field(db):
    total = branded_in_name = suffixed = 0
    for name, brand in db.execute("SELECT name, brand_source FROM food WHERE data_type = 'branded'"):
        total += 1
        cb = canonical(brand)
        if not cb:
            continue
        if CORPORATE_SUFFIX.search(cb):
            suffixed += 1
        core = CORPORATE_SUFFIX.sub(" ", cb).split()
        if core and contains_run(core[0], canonical(name)):
            branded_in_name += 1
    distinct = db.execute("SELECT count(DISTINCT brand_source) FROM food WHERE data_type = 'branded'").fetchone()[0]
    return {
        "brandedRows": total,
        "distinctBrandValues": distinct,
        "brandValueHasCorporateSuffix": suffixed,
        "nameCarriesBrandFirstWord": branded_in_name,
    }


def cross_db_barcodes(base, branded):
    base_codes = {r[0] for r in base.execute("SELECT gtin_upc FROM food WHERE gtin_upc IS NOT NULL AND gtin_upc != ''")}
    overlap = sum(1 for (c,) in branded.execute("SELECT gtin_upc FROM food WHERE gtin_upc IS NOT NULL AND gtin_upc != ''") if c in base_codes)
    return {"sharedBetweenBaseAndBranded": overlap}


# ---- report --------------------------------------------------------------------------------------

def markdown(report):
    lines = ["# Food search Phase 0 — database oracle and audit", "",
             f"Branded database available: **{report['brandedAvailable']}**", "",
             "## Panel oracle (acceptable rows in the data)", "",
             "| id | split | intent | base acceptable | base brand rows (name lacks brand) | branded acceptable | branded brand rows (name lacks brand) | FTS gate base / branded |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for e in report["oracle"]:
        b, o = e.get("base", {}), e.get("branded", {})
        def brand_cell(r):
            return f"{r['brandRows']} ({r['brandRowsNameLacksBrand']})" if "brandRows" in r else "—"
        lines.append(f"| {e['id']} | {e['split']} | {e['intent']} | {b.get('acceptable', '—')} | {brand_cell(b)} | "
                     f"{o.get('acceptable', '—')} | {brand_cell(o)} | {b.get('ftsGate', '—')} / {o.get('ftsGate', '—')} |")
    for label, audit in report["audit"].items():
        lines += ["", f"## Audit: {label}", "", "```json", json.dumps(audit, indent=2, sort_keys=True), "```"]
    if "crossDatabase" in report:
        lines += ["", "## Cross-database", "", "```json", json.dumps(report["crossDatabase"], indent=2), "```"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--branded")
    parser.add_argument("--panel", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    def open_ro(path):
        return sqlite3.connect(f"file:{os.path.abspath(path)}?mode=ro", uri=True)

    dbs = {"base": open_ro(args.base)}
    branded_ok = bool(args.branded) and os.path.isfile(args.branded) and os.path.getsize(args.branded) > 0
    if branded_ok:
        dbs["branded"] = open_ro(args.branded)
    else:
        print("audit: branded database not available — branded coverage NOT measured", file=sys.stderr)
    with open(args.panel, encoding="utf-8") as handle:
        panel = json.load(handle)

    report = {
        "brandedAvailable": branded_ok,
        "panelVersion": panel["version"],
        "oracle": [oracle_entry(dbs, e) for e in panel["entries"]],
        "audit": {label: audit_db(db) for label, db in dbs.items()},
    }
    if branded_ok:
        report["crossDatabase"] = cross_db_barcodes(dbs["base"], dbs["branded"])
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "audit.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    with open(os.path.join(args.out, "audit.md"), "w", encoding="utf-8") as handle:
        handle.write(markdown(report))
    print(f"audit: wrote {args.out}/audit.json and audit.md")


if __name__ == "__main__":
    main()

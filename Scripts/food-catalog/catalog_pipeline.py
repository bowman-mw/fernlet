#!/usr/bin/env python3
"""Deterministic offline food-catalog preservation pipeline."""

from __future__ import annotations

from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN, ROUND_HALF_UP
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import unicodedata
import uuid
import zipfile

from xlsx_stream import XLSXError, iter_sheet_rows, workbook_sheets


SCHEMA_VERSION = 4
APPLICATION_ID = 0x4645524E
MAX_MANIFEST_BYTES = 1_000_000
MAX_EVIDENCE_BYTES = 1_000_000
MAX_SOURCE_BYTES = 600_000_000
MAX_ARCHIVE_MEMBERS = 128
MAX_ARCHIVE_MEMBER_BYTES = 2_000_000_000
MAX_ARCHIVE_TOTAL_BYTES = 4_000_000_000
MAX_ARCHIVE_COMPRESSION_RATIO = 128
MAX_CSV_COLUMNS = 64
MAX_CSV_CELL_BYTES = 1_000_000
# The pinned FDC food_nutrient.csv has 27,195,013 data rows; retain bounded review headroom.
MAX_CSV_RECORDS = 30_000_000
MAX_RETAINED_GENERATIONS = 2
MAX_SQL_BATCH_ROWS = 10_000
MAX_FOODS = 100_000
MAX_REFERENCE_ROWS = 100_000
MAX_NUTRIENT_DEFINITIONS = 10_000
MAX_NUTRIENT_VALUES = 2_000_000
MAX_PORTIONS = 200_000
MAX_INGREDIENT_RELATIONS = 100_000
MAX_BRANDED_FDC_RECORDS = 300_000
MAX_BRANDED_FDC_NUTRIENTS = 4_000_000
MAX_BRANDED_FDC_PORTIONS = 100_000
MAX_CURATED_JSON_BYTES = 25_000_000
MAX_JSON_OBJECT_BYTES = 16_000_000
MAX_JSON_DEPTH = 64
MAX_JSON_OBJECT_FIELDS = 128
MAX_JSON_ARRAY_ITEMS = 100_000
JSON_CHUNK_BYTES = 1_000_000
FDC_PREFIX = "FoodData_Central_csv_2026-04-30/"
FDC_ALLOWED_TYPES = ("Survey (FNDDS)", "SR Legacy", "Foundation")
FDC_TYPE_ORDER = {name: index for index, name in enumerate(FDC_ALLOWED_TYPES)}
FDC_RAW_TYPE_MAP = {
    "survey_fndds_food": "Survey (FNDDS)",
    "sr_legacy_food": "SR Legacy",
    "foundation_food": "Foundation",
}
FNDDS_HEADERS = (
    "Food code",
    "Main food description",
    "WWEIA Category number",
    "WWEIA Category description",
    "Seq num",
    "Ingredient code",
    "Ingredient description",
    "Ingredient weight (g)",
    "Retention code",
    "Moisture change\n(%)",
)
COFID_BASE_SHEET = "1.2 Factors"
COFID_NOTES_SHEET = "1.1 Notes"
COFID_DATA_SHEETS = (
    "1.3 Proximates",
    "1.4 Inorganics",
    "1.5 Vitamins",
    "1.6 Vitamin Fractions",
    "1.7 (SFA per 100gFA)",
    "1.8 (SFA per 100gFood)",
    "1.9 (MUFA per 100FA)",
    "1.10 (MUFA per 100gFood)",
    "1.11 (PUFA per 100gFA)",
    "1.12 (PUFA per 100gFood)",
    "1.13 Phytosterols",
    "1.14 Organic Acids",
)
COFID_DUPLICATE_CODE = "13-669"
COFID_ALCOHOL_GROUP_PREFIX = "Q"
BRANDED_FDC_FIELDS = (
    "brand_owner", "brand_name", "subbrand_name", "gtin_upc", "ingredients",
    "not_a_significant_source_of", "serving_size", "serving_size_unit",
    "household_serving_fulltext", "branded_food_category", "data_source",
    "package_weight", "modified_date", "available_date", "market_country",
    "discontinued_date", "preparation_state_code", "trade_channel",
    "short_description", "material_code",
)
BRANDED_FDC_EXCEPTION_STATUS = "legacy_missing_from_pinned_full_fdc"
VALIDATION_TABLES = (
    "source_manifest", "food", "nutrient_definition", "nutrient_value", "food_factor",
    "portion", "food_ingredient", "ingredient_nutrient_value", "fndds_dish",
    "branded_compatibility", "branded_fdc_record", "branded_fdc_nutrient",
    "branded_fdc_portion", "legacy_compatibility", "validation_evidence",
)
CONTENT_HASH_TABLES = {
    "source_manifest": "source_key",
    "food": "food_id",
    "nutrient_definition": "source_key,nutrient_code,source_sheet",
    "nutrient_value": "food_id,nutrient_code,source_sheet,source_value_id",
    "food_factor": "food_id,factor_name",
    "portion": "portion_id",
    "food_ingredient": "relation_id",
    "ingredient_nutrient_value": "ingredient_code,nutrient_code,start_date,end_date",
    "fndds_dish": "food_id",
    "branded_compatibility": "gtin_upc",
    "branded_fdc_record": "fdc_id",
    "branded_fdc_nutrient": "fdc_id,source_value_id",
    "branded_fdc_portion": "fdc_id,source_portion_id",
    "legacy_compatibility": "food_id",
}
NUMERIC_PATTERN = re.compile(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$")
PARENTHESIZED_NUMERIC_PATTERN = re.compile(r"^\([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\)$")


class PipelineError(RuntimeError):
    """A named, fail-closed source-contract or generation failure."""


class PublishedGenerationError(PipelineError):
    """A publish completed, but its post-commit durability confirmation failed."""


# Raise the standard-library parser ceiling to this tool's independently checked cell contract.
# DictReader otherwise rejects valid 128 KiB–1 MiB source cells before our diagnostic runs.
csv.field_size_limit(MAX_CSV_CELL_BYTES)


def _bounded_file_size(path: Path, limit: int, label: str) -> int:
    size = path.stat().st_size
    if size <= 0 or size > limit:
        raise PipelineError(f"{label} size outside 1..{limit}: {size}")
    return size


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1_048_576), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json_sha256(value: object) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def input_contract(manifest: dict) -> dict:
    return {
        "manifestSHA256": canonical_json_sha256(manifest),
        "inputSHA256": {
            entry["key"]: entry["sha256"]
            for entry in sorted(manifest["sources"], key=lambda item: item["key"])
        },
    }


def validate_evidence_contract(evidence: dict, manifest: dict, catalog: Path | None = None) -> None:
    """Validate either a static evidence record or a staged-generation report."""
    if "catalogSchemaVersion" in evidence:
        evidence_version = evidence.get("catalogSchemaVersion")
        evidence_contract = evidence.get("inputContract")
    else:
        evidence_version = evidence.get("schema_version")
        build_stats = evidence.get("build_stats")
        evidence_contract = build_stats.get("input_contract") if isinstance(build_stats, dict) else None
    if evidence_version != SCHEMA_VERSION:
        raise PipelineError("evidence catalog schema version differs from current tooling")
    if evidence_contract != input_contract(manifest):
        raise PipelineError("evidence manifest or input hash contract differs from source manifest")
    if catalog is not None:
        _bounded_file_size(catalog, MAX_ARCHIVE_TOTAL_BYTES, "catalog for evidence validation")
        if evidence.get("output_bytes") != catalog.stat().st_size:
            raise PipelineError("evidence catalog byte count differs from supplied catalog")
        if evidence.get("output_sha256") != sha256_file(catalog):
            raise PipelineError("evidence catalog hash differs from supplied catalog")


def table_content_hashes(connection: sqlite3.Connection) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for table_name, order_by in CONTENT_HASH_TABLES.items():
        digest = hashlib.sha256()
        rows = connection.execute(f"SELECT * FROM {table_name} ORDER BY {order_by}")
        for row in rows:
            payload = json.dumps(list(row), ensure_ascii=False, separators=(",", ":"))
            digest.update(payload.encode("utf-8"))
            digest.update(b"\n")
        hashes[table_name] = digest.hexdigest()
    return hashes


def load_manifest(path: Path) -> dict:
    _bounded_file_size(path, MAX_MANIFEST_BYTES, "manifest")
    try:
        with path.open(encoding="utf-8") as source:
            manifest = json.load(source)
    except json.JSONDecodeError as error:
        raise PipelineError(f"manifest is invalid JSON: {path}") from error
    if not isinstance(manifest, dict):
        raise PipelineError("source manifest root must be an object")
    if manifest.get("manifestVersion") != 1 or manifest.get("catalogSchemaVersion") != SCHEMA_VERSION:
        raise PipelineError("unsupported source-manifest or catalog-schema version")
    sources = manifest.get("sources")
    if not isinstance(sources, list):
        raise PipelineError("source manifest sources must be an array")
    keys = [entry.get("key") for entry in sources if isinstance(entry, dict)]
    if (
        len(keys) != len(sources) or not keys or len(keys) > 16
        or any(not isinstance(key, str) or not key for key in keys) or len(keys) != len(set(keys))
    ):
        raise PipelineError("source manifest has no sources or duplicate keys")
    for entry in sources:
        entry_bytes = entry.get("bytes") if isinstance(entry, dict) else None
        if not isinstance(entry, dict) or not isinstance(entry_bytes, int) or entry_bytes <= 0 or entry_bytes > MAX_SOURCE_BYTES:
            raise PipelineError(f"source manifest has an invalid source size for {entry.get('key')!r}")
        filenames = entry.get("acceptedFilenames")
        if (
            not isinstance(entry.get("sha256"), str) or len(text(entry.get("sha256"))) != 64
            or not isinstance(filenames, list) or not filenames or len(filenames) > 4
            or any(not isinstance(filename, str) or not filename for filename in filenames)
        ):
            raise PipelineError(f"source manifest has an invalid hash or filename set for {entry.get('key')!r}")
    return manifest


def load_evidence(path: Path) -> dict:
    _bounded_file_size(path, MAX_EVIDENCE_BYTES, "evidence")
    try:
        with path.open(encoding="utf-8") as source:
            evidence = json.load(source)
    except json.JSONDecodeError as error:
        raise PipelineError(f"evidence is invalid JSON: {path}") from error
    if not isinstance(evidence, dict) or len(evidence) > MAX_JSON_OBJECT_FIELDS:
        raise PipelineError("evidence root must be a bounded object")
    _validate_json_value(evidence)
    return evidence


def _validate_json_value(value: object, depth: int = 0) -> None:
    if depth > MAX_JSON_DEPTH:
        raise PipelineError(f"JSON nesting exceeds {MAX_JSON_DEPTH}")
    if isinstance(value, str):
        if len(value.encode("utf-8")) > MAX_CSV_CELL_BYTES:
            raise PipelineError(f"JSON string exceeds {MAX_CSV_CELL_BYTES} bytes")
        return
    if isinstance(value, list):
        if len(value) > MAX_JSON_ARRAY_ITEMS:
            raise PipelineError(f"JSON array exceeds {MAX_JSON_ARRAY_ITEMS} items")
        for item in value:
            _validate_json_value(item, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > MAX_JSON_OBJECT_FIELDS:
            raise PipelineError(f"JSON object exceeds {MAX_JSON_OBJECT_FIELDS} fields")
        for key, item in value.items():
            _validate_json_value(key, depth + 1)
            _validate_json_value(item, depth + 1)


def source_entry(manifest: dict, key: str) -> dict:
    matches = [entry for entry in manifest["sources"] if entry.get("key") == key]
    if len(matches) != 1:
        raise PipelineError(f"manifest must contain exactly one source {key!r}")
    return matches[0]


def verify_input(path: Path, entry: dict) -> None:
    if not path.is_file():
        raise PipelineError(f"missing input for {entry['key']}: {path}")
    if path.name not in entry["acceptedFilenames"]:
        raise PipelineError(f"unexpected filename for {entry['key']}: {path.name}")
    size = _bounded_file_size(path, MAX_SOURCE_BYTES, f"source {entry['key']}")
    if size != entry["bytes"]:
        raise PipelineError(f"size mismatch for {entry['key']}: {size} != {entry['bytes']}")
    actual_hash = sha256_file(path)
    if actual_hash != entry["sha256"]:
        raise PipelineError(f"SHA-256 mismatch for {entry['key']}: {actual_hash}")


def normalize_text(value: str | None) -> str:
    folded = unicodedata.normalize("NFKD", value or "").casefold()
    without_marks = "".join(character for character in folded if not unicodedata.combining(character))
    normalized = "".join(character if character.isalnum() else " " for character in without_marks)
    return " ".join(normalized.split())


def text(value) -> str:
    return "" if value is None else str(value).strip()


def raw_text(value) -> str:
    return "" if value is None else str(value)


def value_status(raw: str | None) -> str:
    value = text(raw)
    if not value:
        return "missing"
    if value.casefold() == "tr":
        return "trace"
    if value.casefold() == "n":
        return "present_unknown"
    if NUMERIC_PATTERN.fullmatch(value):
        return "numeric"
    if PARENTHESIZED_NUMERIC_PATTERN.fullmatch(value):
        return "parenthesized_numeric"
    raise PipelineError(f"unrecognized nutrient/factor value: {raw!r}")


def significant_round(value: Decimal, digits: int = 3) -> Decimal:
    if value == 0:
        return value
    quantum = Decimal(1).scaleb(value.copy_abs().adjusted() - digits + 1)
    return value.quantize(quantum, rounding=ROUND_HALF_EVEN)


def excel_numeric_text(raw: str) -> str:
    try:
        rounded = significant_round(Decimal(raw), digits=15)
    except InvalidOperation as error:
        raise PipelineError(f"invalid XLSX numeric value: {raw!r}") from error
    fixed = format(rounded, "f")
    if "." in fixed:
        fixed = fixed.rstrip("0").rstrip(".")
    return "0" if fixed in {"", "-0"} else fixed


def legacy_integer(raw: str | None, status: str) -> int | None:
    if status != "numeric" or raw is None:
        return None
    try:
        return int(Decimal(raw).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    except InvalidOperation as error:
        raise PipelineError(f"invalid numeric compatibility value: {raw!r}") from error


def stable_uuid(stable_id: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://fernlet.app/food/{stable_id}"))


def fdc_uuid(fdc_id: str) -> str:
    numeric = int(fdc_id)
    if numeric < 0 or numeric > 999_999_999_999:
        raise PipelineError(f"FDC id outside UUID contract: {fdc_id}")
    return f"00000000-0000-5000-8000-{numeric:012d}"


def cofid_stable_id(code: str, name: str, description: str, duplicate_codes: set[str]) -> str:
    if code not in duplicate_codes:
        return f"uk_cofid:{code}"
    digest = hashlib.sha256(f"{name}\u241f{description}".encode("utf-8")).hexdigest()[:12]
    return f"uk_cofid:{code}#{digest}"


def _schema_sql() -> str:
    return """
    CREATE TABLE source_manifest (
        source_key TEXT PRIMARY KEY, enabled INTEGER NOT NULL, role TEXT NOT NULL,
        version TEXT NOT NULL, release_date TEXT, input_filename TEXT NOT NULL,
        input_bytes INTEGER NOT NULL, input_sha256 TEXT NOT NULL, license TEXT NOT NULL,
        license_url TEXT NOT NULL, publisher TEXT NOT NULL, attribution TEXT NOT NULL
    );
    CREATE TABLE food (
        food_id INTEGER PRIMARY KEY, stable_id TEXT NOT NULL UNIQUE,
        source_key TEXT NOT NULL REFERENCES source_manifest(source_key), source_version TEXT NOT NULL,
        source_id TEXT NOT NULL, source_code TEXT, legacy_uuid TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL, normalized_name TEXT NOT NULL, description TEXT,
        category_code TEXT, category_name TEXT, data_type TEXT NOT NULL,
        brand_source TEXT, gtin_upc TEXT, source_references TEXT,
        publication_date TEXT, start_date TEXT, end_date TEXT,
        UNIQUE(source_key, source_version, source_id, display_name)
    );
    CREATE INDEX idx_food_stable_id ON food(stable_id);
    CREATE INDEX idx_food_source_identity ON food(source_key, source_version, source_id);
    CREATE INDEX idx_food_normalized_name ON food(normalized_name);
    CREATE INDEX idx_food_gtin_upc ON food(gtin_upc);
    CREATE TABLE nutrient_definition (
        source_key TEXT NOT NULL, nutrient_code TEXT NOT NULL, display_name TEXT NOT NULL,
        unit TEXT, basis TEXT NOT NULL, source_sheet TEXT NOT NULL, source_rank TEXT,
        PRIMARY KEY(source_key, nutrient_code, source_sheet)
    );
    CREATE TABLE nutrient_value (
        food_id INTEGER NOT NULL REFERENCES food(food_id), source_key TEXT NOT NULL,
        nutrient_code TEXT NOT NULL, source_sheet TEXT NOT NULL, source_value_id TEXT NOT NULL,
        amount_text TEXT NOT NULL,
        value_status TEXT NOT NULL CHECK(value_status IN ('numeric','trace','present_unknown','parenthesized_numeric')),
        unit TEXT, basis TEXT NOT NULL, data_points_text TEXT, derivation_id TEXT,
        minimum_text TEXT, maximum_text TEXT, median_text TEXT, loq_text TEXT, footnote TEXT,
        min_year_acquired TEXT, percent_daily_value_text TEXT,
        PRIMARY KEY(food_id, nutrient_code, source_sheet, source_value_id)
    );
    CREATE INDEX idx_nutrient_value_code ON nutrient_value(source_key, nutrient_code);
    CREATE TABLE food_factor (
        food_id INTEGER NOT NULL REFERENCES food(food_id), factor_name TEXT NOT NULL,
        value_text TEXT NOT NULL, value_status TEXT NOT NULL,
        PRIMARY KEY(food_id, factor_name)
    );
    CREATE TABLE portion (
        portion_id INTEGER PRIMARY KEY, food_id INTEGER NOT NULL REFERENCES food(food_id),
        source_portion_id TEXT NOT NULL, sequence_text TEXT, amount_text TEXT,
        raw_unit TEXT, gram_weight_text TEXT, modifier TEXT, description TEXT,
        data_points_text TEXT, footnote TEXT, min_year_acquired TEXT,
        UNIQUE(food_id, source_portion_id)
    );
    CREATE TABLE food_ingredient (
        relation_id INTEGER PRIMARY KEY, food_id INTEGER NOT NULL REFERENCES food(food_id),
        source_relation_id TEXT NOT NULL, sequence_text TEXT NOT NULL,
        ingredient_source_id TEXT, ingredient_code TEXT, ingredient_description TEXT NOT NULL,
        ingredient_weight_text TEXT, retention_code TEXT, amount_text TEXT, raw_unit TEXT,
        portion_code TEXT, portion_description TEXT, moisture_change_percent_text TEXT,
        workbook_ingredient_weight_raw TEXT, workbook_moisture_change_percent_raw TEXT,
        UNIQUE(food_id, source_relation_id)
    );
    CREATE INDEX idx_food_ingredient_sequence ON food_ingredient(food_id, sequence_text);
    CREATE INDEX idx_food_ingredient_code ON food_ingredient(ingredient_code);
    CREATE TABLE ingredient_nutrient_value (
        ingredient_code TEXT NOT NULL, ingredient_description TEXT NOT NULL,
        nutrient_code TEXT NOT NULL, nutrient_value_text TEXT NOT NULL,
        nutrient_value_source TEXT, fdc_id TEXT, derivation_code TEXT,
        sr_addmod_year TEXT, foundation_year_acquired TEXT, start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        PRIMARY KEY(ingredient_code, nutrient_code, start_date, end_date)
    );
    CREATE INDEX idx_ingredient_nutrient_code
        ON ingredient_nutrient_value(ingredient_code, nutrient_code);
    CREATE TABLE fndds_dish (
        food_id INTEGER PRIMARY KEY REFERENCES food(food_id), food_code TEXT NOT NULL UNIQUE,
        main_food_description TEXT NOT NULL, wweia_category_number TEXT NOT NULL,
        wweia_category_description TEXT NOT NULL, moisture_change_percent_raw TEXT NOT NULL,
        moisture_change_percent_canonical TEXT NOT NULL
    );
    CREATE TABLE branded_compatibility (
        gtin_upc TEXT PRIMARY KEY, food_id INTEGER NOT NULL UNIQUE REFERENCES food(food_id),
        shipping_uuid TEXT NOT NULL UNIQUE, enrichment_status TEXT NOT NULL,
        exception_reason TEXT, full_fdc_record_count INTEGER NOT NULL
    );
    CREATE TABLE branded_fdc_record (
        fdc_id TEXT PRIMARY KEY, food_id INTEGER NOT NULL REFERENCES food(food_id),
        gtin_upc TEXT NOT NULL, food_description TEXT NOT NULL, food_category_id TEXT,
        food_publication_date TEXT, brand_owner TEXT, brand_name TEXT, subbrand_name TEXT,
        raw_gtin_upc TEXT, ingredients TEXT, not_a_significant_source_of TEXT,
        serving_size_text TEXT, serving_size_unit TEXT, household_serving_fulltext TEXT,
        branded_food_category TEXT, data_source TEXT, package_weight TEXT, modified_date TEXT,
        available_date TEXT, market_country TEXT, discontinued_date TEXT,
        preparation_state_code TEXT, trade_channel TEXT, short_description TEXT,
        material_code TEXT
    );
    CREATE INDEX idx_branded_fdc_record_food ON branded_fdc_record(food_id, fdc_id);
    CREATE TABLE branded_fdc_nutrient (
        fdc_id TEXT NOT NULL REFERENCES branded_fdc_record(fdc_id), source_value_id TEXT NOT NULL,
        nutrient_id TEXT NOT NULL, amount_text TEXT NOT NULL, data_points_text TEXT,
        derivation_id TEXT, minimum_text TEXT, maximum_text TEXT, median_text TEXT,
        loq_text TEXT, footnote TEXT, min_year_acquired TEXT, percent_daily_value_text TEXT,
        PRIMARY KEY(fdc_id, source_value_id)
    );
    CREATE TABLE branded_fdc_portion (
        fdc_id TEXT NOT NULL REFERENCES branded_fdc_record(fdc_id), source_portion_id TEXT NOT NULL,
        sequence_text TEXT, amount_text TEXT, measure_unit_id TEXT, measure_unit_name TEXT,
        portion_description TEXT, modifier TEXT, gram_weight_text TEXT, data_points_text TEXT,
        footnote TEXT, min_year_acquired TEXT, PRIMARY KEY(fdc_id, source_portion_id)
    );
    CREATE TABLE legacy_compatibility (
        food_id INTEGER PRIMARY KEY REFERENCES food(food_id), legacy_uuid TEXT NOT NULL,
        serving_size_text TEXT NOT NULL, serving_unit TEXT NOT NULL,
        protein_raw TEXT, protein_status TEXT NOT NULL, protein_integer INTEGER,
        carbs_raw TEXT, carbs_status TEXT NOT NULL, carbs_integer INTEGER,
        fat_raw TEXT, fat_status TEXT NOT NULL, fat_integer INTEGER,
        mapping_policy TEXT NOT NULL
    );
    CREATE TABLE validation_evidence (
        evidence_key TEXT PRIMARY KEY, evidence_value TEXT NOT NULL
    );
    CREATE VIRTUAL TABLE food_fts USING fts5(
        display_name, normalized_name, brand_source, ingredient_text, category,
        content='', columnsize=0, tokenize='unicode61'
    );
    """


def create_database(path: Path) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA page_size = 4096")
    connection.execute("PRAGMA journal_mode = DELETE")
    connection.execute(f"PRAGMA application_id = {APPLICATION_ID}")
    connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    connection.execute("PRAGMA foreign_keys = ON")
    connection.executescript(_schema_sql())
    return connection


def insert_source_manifest(connection: sqlite3.Connection, manifest: dict, paths: dict[str, Path]) -> None:
    if len(manifest["sources"]) > 16:
        raise PipelineError("source-manifest row cap exceeded")
    rows = []
    for entry in manifest["sources"]:
        local_path = paths.get(entry["key"])
        filename = local_path.name if local_path is not None else entry["acceptedFilenames"][0]
        rows.append((
            entry["key"], int(entry["enabled"]), entry["role"], entry["version"], entry.get("releaseDate"),
            filename, entry["bytes"], entry["sha256"], entry["license"], entry["licenseURL"],
            entry["publisher"], entry["attribution"],
        ))
    bounded_executemany(connection, "INSERT INTO source_manifest VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)


def bounded_executemany(connection: sqlite3.Connection, sql: str, rows) -> int:
    batch = []
    count = 0
    for row in rows:
        batch.append(row)
        count += 1
        if len(batch) == MAX_SQL_BATCH_ROWS:
            connection.executemany(sql, batch)
            batch.clear()
    if batch:
        connection.executemany(sql, batch)
    return count


def _validate_zip_archive(
    archive: zipfile.ZipFile,
    label: str,
    member_limit: int,
    member_bytes_limit: int,
    total_bytes_limit: int,
    compression_ratio_limit: int,
) -> None:
    members = archive.infolist()
    if not members or len(members) > member_limit:
        raise PipelineError(f"{label} member count exceeds {member_limit}")
    total_bytes = 0
    names: set[str] = set()
    for info in members:
        name = info.filename
        if not name or name in names or name.startswith("/") or ".." in name.split("/"):
            raise PipelineError(f"{label} has an unsafe or duplicate member name: {name!r}")
        names.add(name)
        if info.flag_bits & 0x1:
            raise PipelineError(f"{label} has encrypted member: {name}")
        if info.file_size < 0 or info.file_size > member_bytes_limit:
            raise PipelineError(f"{label} member expansion exceeds {member_bytes_limit}: {name}")
        total_bytes += info.file_size
        if total_bytes > total_bytes_limit:
            raise PipelineError(f"{label} total expansion exceeds {total_bytes_limit}")
        if info.file_size and (info.compress_size <= 0 or info.file_size > info.compress_size * compression_ratio_limit):
            raise PipelineError(f"{label} member compression ratio exceeds {compression_ratio_limit}: {name}")


class _BoundedDictReader(csv.DictReader):
    def __init__(self, source, filename: str):
        self.filename = filename
        self.record_count = 0
        try:
            super().__init__(source)
            fieldnames = self.fieldnames or []
        except csv.Error as error:
            raise PipelineError(f"{filename} CSV header parse failed: {error}") from error
        if len(fieldnames) > MAX_CSV_COLUMNS:
            raise PipelineError(f"{filename} column count exceeds {MAX_CSV_COLUMNS}")
        for fieldname in fieldnames:
            if len(raw_text(fieldname).encode("utf-8")) > MAX_CSV_CELL_BYTES:
                raise PipelineError(f"{filename} header cell exceeds {MAX_CSV_CELL_BYTES} bytes")

    def __next__(self) -> dict:
        try:
            row = super().__next__()
        except csv.Error as error:
            raise PipelineError(f"{self.filename} CSV row parse failed: {error}") from error
        self.record_count += 1
        if self.record_count > MAX_CSV_RECORDS:
            raise PipelineError(f"{self.filename} record count exceeds {MAX_CSV_RECORDS}")
        if None in row:
            raise PipelineError(f"{self.filename} row has more than {MAX_CSV_COLUMNS} columns")
        for value in row.values():
            if len(raw_text(value).encode("utf-8")) > MAX_CSV_CELL_BYTES:
                raise PipelineError(f"{self.filename} cell exceeds {MAX_CSV_CELL_BYTES} bytes")
        return row


def _zip_csv(archive: zipfile.ZipFile, filename: str):
    member = FDC_PREFIX + filename
    if member not in archive.namelist():
        raise PipelineError(f"FDC archive missing required member: {member}")
    source = archive.open(member)
    text_source = io.TextIOWrapper(source, encoding="utf-8-sig", newline="")
    return source, text_source, _BoundedDictReader(text_source, filename)


def _close_csv(source, text_source) -> None:
    text_source.close()
    source.close()


def _require_headers(reader: csv.DictReader, expected: set[str], filename: str) -> None:
    headers = set(reader.fieldnames or [])
    missing = expected - headers
    if missing:
        raise PipelineError(f"{filename} missing columns: {sorted(missing)}")


def _decimal_from_json(value) -> Decimal:
    try:
        return Decimal(str(value))
    except InvalidOperation as error:
        raise PipelineError(f"JSON numeric value is invalid: {value!r}") from error


def iter_json_array(path: Path, array_key: str):
    _bounded_file_size(path, MAX_SOURCE_BYTES, f"JSON fixture {path.name}")
    decoder = json.JSONDecoder(parse_float=Decimal, parse_int=Decimal)
    marker = f'"{array_key}"'
    buffer = ""
    with path.open(encoding="utf-8-sig") as source:
        while True:
            chunk = source.read(JSON_CHUNK_BYTES)
            if not chunk:
                raise PipelineError(f"JSON fixture lacks top-level array {array_key!r}")
            buffer += chunk
            marker_index = buffer.find(marker)
            if marker_index < 0:
                buffer = buffer[-len(marker):]
                continue
            array_index = buffer.find("[", marker_index + len(marker))
            if array_index < 0:
                buffer = buffer[marker_index:]
                continue
            buffer = buffer[array_index + 1:]
            break
        while True:
            buffer = buffer.lstrip()
            if buffer.startswith(","):
                buffer = buffer[1:].lstrip()
            if buffer.startswith("]"):
                return
            if not buffer:
                chunk = source.read(JSON_CHUNK_BYTES)
                if not chunk:
                    raise PipelineError(f"unterminated JSON fixture array {array_key!r}")
                buffer += chunk
                continue
            try:
                value, end = decoder.raw_decode(buffer)
            except json.JSONDecodeError as error:
                if len(buffer.encode("utf-8")) > MAX_JSON_OBJECT_BYTES:
                    raise PipelineError(f"JSON object exceeds {MAX_JSON_OBJECT_BYTES} bytes in {path.name}") from error
                chunk = source.read(JSON_CHUNK_BYTES)
                if not chunk:
                    raise PipelineError(f"invalid JSON fixture {path.name}: {error}") from error
                buffer += chunk
                continue
            if not isinstance(value, dict):
                raise PipelineError(f"{array_key!r} must contain JSON objects")
            _validate_json_value(value)
            yield value
            buffer = buffer[end:]


def load_fndds_workbook(path: Path, expected: dict) -> tuple[dict[tuple[str, str], dict], dict[str, dict], dict]:
    with zipfile.ZipFile(path) as archive:
        sheet_names = [sheet.name for sheet in workbook_sheets(archive)]
    if sheet_names != ["FNDDS Ingredients", "Variable Descriptions"]:
        raise PipelineError(f"unexpected FNDDS sheet contract: {sheet_names}")
    rows = iter_sheet_rows(str(path), "FNDDS Ingredients")
    title_number, title = next(rows)
    header_number, header = next(rows)
    if title_number != 1 or "2021-2023 Food and Nutrient Database" not in text(title[0] if title else None):
        raise PipelineError("FNDDS title/version row does not identify 2021-2023")
    actual_headers = tuple(text(value) for value in header[:len(FNDDS_HEADERS)])
    if header_number != 2 or actual_headers != FNDDS_HEADERS:
        raise PipelineError(f"unexpected FNDDS headers: {actual_headers}")
    relations: dict[tuple[str, str], dict] = {}
    foods: set[str] = set()
    ingredients: set[str] = set()
    dishes: dict[str, dict] = {}
    moisture_by_food: dict[str, str] = {}
    for row_number, values in rows:
        if not any(text(value) for value in values):
            continue
        if len(values) < len(FNDDS_HEADERS):
            values.extend([None] * (len(FNDDS_HEADERS) - len(values)))
        raw_fields = [raw_text(value) for value in values[:len(FNDDS_HEADERS)]]
        fields = [text(value) for value in values[:len(FNDDS_HEADERS)]]
        if any(not field for field in fields):
            raise PipelineError(f"FNDDS row {row_number} has blank required field")
        key = (fields[0], fields[4])
        if key in relations:
            raise PipelineError(f"duplicate FNDDS relation key: {key}")
        raw_ingredient_weight = raw_fields[7]
        raw_moisture = raw_fields[9]
        fields[7] = excel_numeric_text(raw_ingredient_weight)
        fields[9] = excel_numeric_text(raw_moisture)
        relation = {
            "food_code": fields[0], "main_description": fields[1],
            "category_code": fields[2], "category_description": fields[3],
            "sequence": fields[4], "ingredient_code": fields[5],
            "ingredient_description": fields[6], "ingredient_weight": fields[7],
            "ingredient_weight_raw": raw_ingredient_weight, "retention_code": fields[8],
            "moisture": fields[9], "moisture_raw": raw_moisture,
        }
        status = value_status(fields[9])
        if status != "numeric":
            raise PipelineError(f"FNDDS moisture must be numeric at row {row_number}")
        prior_moisture = moisture_by_food.setdefault(fields[0], fields[9])
        if Decimal(prior_moisture) != Decimal(fields[9]):
            raise PipelineError(f"FNDDS food {fields[0]} has inconsistent moisture values")
        dish = {
            "food_code": fields[0], "main_description": fields[1],
            "category_code": fields[2], "category_description": fields[3],
            "moisture": fields[9], "moisture_raw": raw_moisture,
        }
        prior_dish = dishes.setdefault(fields[0], dish)
        if prior_dish != dish:
            raise PipelineError(f"FNDDS dish metadata differs across relations: {fields[0]}")
        if len(relations) >= MAX_INGREDIENT_RELATIONS:
            raise PipelineError("FNDDS ingredient relation cap exceeded")
        relations[key] = relation
        foods.add(fields[0])
        ingredients.add(fields[5])
    if len(relations) != expected["ingredientRows"]:
        raise PipelineError(f"FNDDS row count {len(relations)} != {expected['ingredientRows']}")
    if len(foods) != expected["dishes"] or len(ingredients) != expected["ingredientCodes"]:
        raise PipelineError("FNDDS dish or ingredient-code count mismatch")
    return relations, dishes, {
        "rows": len(relations), "foods": len(foods), "ingredient_codes": len(ingredients),
        "moisture_foods": len(moisture_by_food),
    }


def _load_fdc_subtypes(archive: zipfile.ZipFile, expected: dict) -> tuple[dict[str, dict], dict[str, str]]:
    files = (
        ("survey_fndds_food.csv", "Survey (FNDDS)", "food_code"),
        ("sr_legacy_food.csv", "SR Legacy", "NDB_number"),
        ("foundation_food.csv", "Foundation", "NDB_number"),
    )
    metadata: dict[str, dict] = {}
    survey_code_to_fdc: dict[str, str] = {}
    counts: Counter[str] = Counter()
    for filename, data_type, source_code_column in files:
        source, text_source, reader = _zip_csv(archive, filename)
        _require_headers(reader, {"fdc_id", source_code_column}, filename)
        try:
            for row in reader:
                fdc_id = text(row["fdc_id"])
                if not fdc_id or fdc_id in metadata:
                    raise PipelineError(f"missing or duplicate allowed FDC id in {filename}: {fdc_id!r}")
                record = {
                    "data_type": data_type,
                    "source_code": text(row.get(source_code_column)),
                    "start_date": text(row.get("start_date")),
                    "end_date": text(row.get("end_date")),
                    "wweia_category_code": text(row.get("wweia_category_code")),
                    "footnote": text(row.get("footnote")),
                }
                if len(metadata) >= MAX_FOODS:
                    raise PipelineError("allowed FDC food cap exceeded")
                metadata[fdc_id] = record
                counts[data_type] += 1
                if data_type == "Survey (FNDDS)":
                    food_code = record["source_code"]
                    if not food_code or food_code in survey_code_to_fdc:
                        raise PipelineError(f"missing or duplicate FNDDS food code: {food_code!r}")
                    survey_code_to_fdc[food_code] = fdc_id
        finally:
            _close_csv(source, text_source)
    for data_type in FDC_ALLOWED_TYPES:
        if data_type == "Foundation":
            if counts[data_type] <= 0 or counts[data_type] > expected[data_type]:
                raise PipelineError(f"FDC Foundation companion count is invalid: {counts[data_type]}")
        elif counts[data_type] != expected[data_type]:
            raise PipelineError(f"FDC {data_type} count {counts[data_type]} != {expected[data_type]}")
    return metadata, survey_code_to_fdc


def _load_category_maps(archive: zipfile.ZipFile) -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
    maps: list[dict[str, str]] = []
    contracts = (
        ("food_category.csv", "id", "description"),
        ("wweia_food_category.csv", "wweia_food_category", "wweia_food_category_description"),
        ("measure_unit.csv", "id", "name"),
    )
    for filename, key_column, value_column in contracts:
        source, text_source, reader = _zip_csv(archive, filename)
        _require_headers(reader, {key_column, value_column}, filename)
        try:
            values: dict[str, str] = {}
            for row in reader:
                if len(values) >= MAX_REFERENCE_ROWS:
                    raise PipelineError(f"{filename} reference-row cap exceeded")
                key = text(row[key_column])
                if not key or key in values:
                    raise PipelineError(f"{filename} has blank or duplicate reference key: {key!r}")
                values[key] = text(row[value_column])
            maps.append(values)
        finally:
            _close_csv(source, text_source)
    return maps[0], maps[1], maps[2]


def _load_fdc_food_rows(
    archive: zipfile.ZipFile,
    metadata: dict[str, dict],
    food_categories: dict[str, str],
    wweia_categories: dict[str, str],
    expected: dict,
) -> list[dict]:
    source, text_source, reader = _zip_csv(archive, "food.csv")
    _require_headers(reader, {"fdc_id", "data_type", "description", "food_category_id", "publication_date"}, "food.csv")
    rows: list[dict] = []
    seen: set[str] = set()
    counts: Counter[str] = Counter()
    try:
        for row in reader:
            fdc_id = text(row["fdc_id"])
            row_data_type = FDC_RAW_TYPE_MAP.get(text(row["data_type"]))
            if row_data_type is None:
                continue
            subtype = metadata.get(fdc_id)
            if subtype is None:
                if row_data_type != "Foundation":
                    raise PipelineError(f"{row_data_type} food {fdc_id} lacks its subtype companion row")
                subtype = {
                    "data_type": "Foundation", "source_code": "", "start_date": "",
                    "end_date": "", "wweia_category_code": "", "footnote": "",
                }
            if fdc_id in seen:
                raise PipelineError(f"duplicate allowed food.csv FDC id: {fdc_id}")
            if row_data_type != subtype["data_type"]:
                raise PipelineError(f"FDC type mismatch for {fdc_id}")
            if subtype["data_type"] == "Survey (FNDDS)":
                category_code = subtype["wweia_category_code"]
                category_name = wweia_categories.get(category_code, "")
            else:
                category_code = text(row["food_category_id"])
                category_name = food_categories.get(category_code, subtype["data_type"])
            description = text(row["description"])
            if not description:
                raise PipelineError(f"FDC food {fdc_id} has blank description")
            if len(rows) >= MAX_FOODS:
                raise PipelineError("allowed food.csv food cap exceeded")
            rows.append({
                "fdc_id": fdc_id, "data_type": subtype["data_type"],
                "source_code": subtype["source_code"], "display_name": description,
                "category_code": category_code, "category_name": category_name,
                "publication_date": text(row["publication_date"]),
                "start_date": subtype["start_date"], "end_date": subtype["end_date"],
                "source_references": subtype["footnote"],
            })
            seen.add(fdc_id)
            counts[row_data_type] += 1
    finally:
        _close_csv(source, text_source)
    if not set(metadata).issubset(seen):
        missing = sorted(set(metadata) - seen)[:10]
        raise PipelineError(f"food.csv missing allowed FDC ids: {missing}")
    if dict(counts) != expected:
        raise PipelineError(f"food.csv allowed type counts differ: {dict(counts)} != {expected}")
    return sorted(rows, key=lambda row: (FDC_TYPE_ORDER[row["data_type"]], int(row["fdc_id"])))


def _insert_fdc_foods(connection: sqlite3.Connection, rows: list[dict], version: str) -> tuple[dict[str, int], dict[str, dict]]:
    fdc_to_food: dict[str, int] = {}
    fdc_details: dict[str, dict] = {}
    sql = """
        INSERT INTO food (
            stable_id,source_key,source_version,source_id,source_code,legacy_uuid,
            display_name,normalized_name,description,category_code,category_name,data_type,
            brand_source,gtin_upc,source_references,publication_date,start_date,end_date
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    for row in rows:
        fdc_id = row["fdc_id"]
        stable_id = f"usda_fdc:{fdc_id}"
        connection.execute(sql, (
            stable_id, "usda_fdc_consumer", version, fdc_id, row["source_code"], fdc_uuid(fdc_id),
            row["display_name"], normalize_text(row["display_name"]), None,
            row["category_code"] or None, row["category_name"], row["data_type"],
            f"USDA FDC {fdc_id}", None, row["source_references"] or None,
            row["publication_date"] or None, row["start_date"] or None, row["end_date"] or None,
        ))
        food_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
        fdc_to_food[fdc_id] = food_id
        fdc_details[fdc_id] = {**row, "food_id": food_id}
    return fdc_to_food, fdc_details


def _insert_fndds_dishes(
    connection: sqlite3.Connection,
    dishes: dict[str, dict],
    survey_code_to_fdc: dict[str, str],
    fdc_details: dict[str, dict],
) -> int:
    count = 0
    for food_code, dish in sorted(dishes.items()):
        fdc_id = survey_code_to_fdc.get(food_code)
        details = fdc_details.get(fdc_id or "")
        if details is None:
            raise PipelineError(f"FNDDS dish has no canonical Survey FDC food: {food_code}")
        comparisons = (
            (dish["main_description"], details["display_name"], "main description"),
            (dish["category_code"], details["category_code"], "WWEIA category number"),
            (dish["category_description"], details["category_name"], "WWEIA category description"),
        )
        mismatches = [name for left, right, name in comparisons if left != right]
        if mismatches:
            raise PipelineError(f"FNDDS dish/FDC mismatch {food_code}: {mismatches}")
        connection.execute(
            "INSERT INTO fndds_dish VALUES (?,?,?,?,?,?,?)",
            (
                details["food_id"], food_code, dish["main_description"], dish["category_code"],
                dish["category_description"], dish["moisture_raw"], dish["moisture"],
            ),
        )
        count += 1
    return count


def _load_fdc_nutrients(connection: sqlite3.Connection, archive: zipfile.ZipFile, fdc_to_food: dict[str, int]) -> int:
    source, text_source, reader = _zip_csv(archive, "nutrient.csv")
    _require_headers(reader, {"id", "name", "unit_name", "nutrient_nbr", "rank"}, "nutrient.csv")
    nutrient_units: dict[str, str] = {}
    try:
        definitions = []
        for row in reader:
            nutrient_code = text(row["id"])
            if not nutrient_code or nutrient_code in nutrient_units:
                raise PipelineError(f"nutrient.csv has blank or duplicate nutrient ID: {nutrient_code!r}")
            if len(definitions) >= MAX_NUTRIENT_DEFINITIONS:
                raise PipelineError("nutrient-definition cap exceeded")
            nutrient_units[nutrient_code] = text(row["unit_name"])
            definitions.append((
                "usda_fdc_consumer", nutrient_code, text(row["name"]), text(row["unit_name"]),
                "per_100g", "food_nutrient.csv", text(row["rank"]) or text(row["nutrient_nbr"]),
            ))
        bounded_executemany(connection, "INSERT INTO nutrient_definition VALUES (?,?,?,?,?,?,?)", definitions)
    finally:
        _close_csv(source, text_source)
    source, text_source, reader = _zip_csv(archive, "food_nutrient.csv")
    required = {"id", "fdc_id", "nutrient_id", "amount", "data_points", "derivation_id", "min", "max", "median", "loq", "footnote", "min_year_acquired", "percent_daily_value"}
    _require_headers(reader, required, "food_nutrient.csv")
    insert_sql = """
        INSERT INTO nutrient_value (
            food_id,source_key,nutrient_code,source_sheet,source_value_id,amount_text,value_status,unit,basis,
            data_points_text,derivation_id,minimum_text,maximum_text,median_text,loq_text,footnote,
            min_year_acquired,percent_daily_value_text
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    count = 0
    try:
        for row in reader:
            food_id = fdc_to_food.get(text(row["fdc_id"]))
            if food_id is None:
                continue
            amount = text(row["amount"])
            if value_status(amount) != "numeric":
                raise PipelineError(f"FDC nutrient amount is not numeric for food {row['fdc_id']}")
            nutrient_code = text(row["nutrient_id"])
            if count >= MAX_NUTRIENT_VALUES:
                raise PipelineError("FDC nutrient-value cap exceeded")
            connection.execute(insert_sql, (
                food_id, "usda_fdc_consumer", nutrient_code, "food_nutrient.csv", text(row["id"]), amount,
                "numeric", nutrient_units.get(nutrient_code), "per_100g",
                text(row["data_points"]) or None, text(row["derivation_id"]) or None,
                text(row["min"]) or None, text(row["max"]) or None, text(row["median"]) or None,
                text(row["loq"]) or None,
                text(row["footnote"]) or None, text(row["min_year_acquired"]) or None,
                text(row["percent_daily_value"]) or None,
            ))
            count += 1
    finally:
        _close_csv(source, text_source)
    return count


def _load_fdc_portions(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    fdc_to_food: dict[str, int],
    measure_units: dict[str, str],
) -> tuple[int, dict[str, dict]]:
    source, text_source, reader = _zip_csv(archive, "food_portion.csv")
    required = {"id", "fdc_id", "seq_num", "amount", "measure_unit_id", "portion_description", "modifier", "gram_weight", "data_points", "footnote", "min_year_acquired"}
    _require_headers(reader, required, "food_portion.csv")
    insert_sql = """
        INSERT INTO portion (
            food_id,source_portion_id,sequence_text,amount_text,raw_unit,gram_weight_text,
            modifier,description,data_points_text,footnote,min_year_acquired
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
    """
    count = 0
    survey_portions: dict[str, dict] = {}
    try:
        for row in reader:
            food_id = fdc_to_food.get(text(row["fdc_id"]))
            if food_id is None:
                continue
            portion_id = text(row["id"])
            unit = measure_units.get(text(row["measure_unit_id"]), "")
            if count >= MAX_PORTIONS:
                raise PipelineError("FDC portion cap exceeded")
            connection.execute(insert_sql, (
                food_id, portion_id, text(row["seq_num"]) or None, text(row["amount"]) or None,
                unit or None, text(row["gram_weight"]) or None, text(row["modifier"]) or None,
                text(row["portion_description"]) or None, text(row["data_points"]) or None,
                text(row["footnote"]) or None, text(row["min_year_acquired"]) or None,
            ))
            survey_portions[portion_id] = {
                "fdc_id": text(row["fdc_id"]), "amount": text(row["amount"]),
                "gram_weight": text(row["gram_weight"]), "modifier": text(row["modifier"]),
                "description": text(row["portion_description"]), "unit": unit,
                "measure_unit_id": text(row["measure_unit_id"]),
                "sequence": text(row["seq_num"]),
            }
            count += 1
    finally:
        _close_csv(source, text_source)
    return count, survey_portions


def _relation_mismatches(workbook: dict, fdc: dict) -> list[str]:
    comparisons = (
        ("ingredient_code", workbook["ingredient_code"], fdc["ingredient_code"]),
        ("ingredient_description", workbook["ingredient_description"], fdc["ingredient_description"]),
        ("ingredient_weight", Decimal(workbook["ingredient_weight"]), Decimal(fdc["ingredient_weight"])),
        ("retention_code", workbook["retention_code"], fdc["retention_code"]),
    )
    return [name for name, left, right in comparisons if left != right]


def _load_fdc_ingredients(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    fdc_to_food: dict[str, int],
    fdc_details: dict[str, dict],
    fndds_relations: dict[tuple[str, str], dict],
) -> tuple[int, dict[tuple[str, str], dict]]:
    source, text_source, reader = _zip_csv(archive, "input_food.csv")
    required = {"id", "fdc_id", "fdc_of_input_food", "seq_num", "amount", "sr_code", "sr_description", "unit", "portion_code", "portion_description", "gram_weight", "retention_code"}
    _require_headers(reader, required, "input_food.csv")
    insert_sql = """
        INSERT INTO food_ingredient (
            food_id,source_relation_id,sequence_text,ingredient_source_id,ingredient_code,
            ingredient_description,ingredient_weight_text,retention_code,amount_text,raw_unit,
            portion_code,portion_description,moisture_change_percent_text,
            workbook_ingredient_weight_raw,workbook_moisture_change_percent_raw
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    count = 0
    survey_relations: dict[tuple[str, str], dict] = {}
    try:
        for row in reader:
            parent_fdc_id = text(row["fdc_id"])
            food_id = fdc_to_food.get(parent_fdc_id)
            if food_id is None:
                continue
            details = fdc_details[parent_fdc_id]
            if details["data_type"] != "Survey (FNDDS)":
                continue
            sequence = text(row["seq_num"])
            ingredient_description = text(row["sr_description"])
            ingredient_code = text(row["sr_code"])
            ingredient_source_id = text(row["fdc_of_input_food"])
            moisture = None
            key = (details["source_code"], sequence)
            workbook = fndds_relations.get(key)
            if workbook is None:
                raise PipelineError(f"FNDDS workbook missing FDC relation {key}")
            fdc_relation = {
                "ingredient_code": ingredient_code,
                "ingredient_description": ingredient_description,
                "ingredient_weight": text(row["gram_weight"]),
                "retention_code": text(row["retention_code"]),
            }
            mismatches = _relation_mismatches(workbook, fdc_relation)
            if mismatches:
                raise PipelineError(f"FNDDS/FDC relation mismatch {key}: {mismatches}")
            moisture = workbook["moisture"]
            if count >= MAX_INGREDIENT_RELATIONS:
                raise PipelineError("FDC input-food relation cap exceeded")
            survey_relations[key] = {
                **fdc_relation,
                "id": text(row["id"]), "amount": text(row["amount"]),
                "unit": text(row["unit"]), "portion_code": text(row["portion_code"]),
                "portion_description": text(row["portion_description"]),
                "parent_fdc_id": parent_fdc_id, "moisture": moisture,
            }
            if not ingredient_description:
                ingredient_description = f"FDC input {ingredient_source_id or ingredient_code}"
            connection.execute(insert_sql, (
                food_id, text(row["id"]), sequence, ingredient_source_id or None,
                ingredient_code or None, ingredient_description, text(row["gram_weight"]) or None,
                text(row["retention_code"]) or None, text(row["amount"]) or None,
                text(row["unit"]) or None, text(row["portion_code"]) or None,
                text(row["portion_description"]) or None, moisture,
                workbook["ingredient_weight_raw"], workbook["moisture_raw"],
            ))
            count += 1
    finally:
        _close_csv(source, text_source)
    if set(survey_relations) != set(fndds_relations):
        raise PipelineError("FDC Survey input relation keys do not exactly match FNDDS workbook")
    if count != len(fndds_relations):
        raise PipelineError("FDC Survey input relation count does not exactly match FNDDS workbook")
    return count, survey_relations


def _load_fndds_ingredient_nutrients(connection: sqlite3.Connection, archive: zipfile.ZipFile) -> int:
    source, text_source, reader = _zip_csv(archive, "fndds_ingredient_nutrient_value.csv")
    required = {"ingredient code", "Ingredient description", "Nutrient code", "Nutrient value", "Nutrient value source", "FDC ID", "Derivation code", "SR AddMod year", "Foundation year acquired", "Start date", "End date"}
    _require_headers(reader, required, "fndds_ingredient_nutrient_value.csv")
    sql = "INSERT INTO ingredient_nutrient_value VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    count = 0
    try:
        for row in reader:
            nutrient_value = text(row["Nutrient value"])
            if value_status(nutrient_value) != "numeric":
                raise PipelineError("FNDDS ingredient nutrient value is not numeric")
            start_date = text(row["Start date"])
            end_date = text(row["End date"])
            if not start_date or not end_date:
                raise PipelineError("FNDDS ingredient nutrient date window is missing")
            if count >= MAX_NUTRIENT_VALUES:
                raise PipelineError("FNDDS ingredient nutrient-value cap exceeded")
            connection.execute(sql, (
                text(row["ingredient code"]), text(row["Ingredient description"]),
                text(row["Nutrient code"]), nutrient_value, text(row["Nutrient value source"]) or None,
                text(row["FDC ID"]) or None, text(row["Derivation code"]) or None,
                text(row["SR AddMod year"]) or None, text(row["Foundation year acquired"]) or None,
                start_date, end_date,
            ))
            count += 1
    finally:
        _close_csv(source, text_source)
    return count


def _json_wweia_number(food: dict) -> str:
    for attribute in food.get("foodAttributes") or []:
        if text(attribute.get("name")) == "WWEIA Category number":
            return text(attribute.get("value"))
    return ""


def _json_moisture(food: dict) -> str:
    pattern = re.compile(r"^Moisture change:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))%$")
    values = []
    for attribute in food.get("foodAttributes") or []:
        attribute_type = attribute.get("foodAttributeType") or {}
        raw = text(attribute.get("value"))
        if text(attribute_type.get("name")) != "Adjustments" or "Moisture change" not in raw:
            continue
        match = pattern.fullmatch(raw)
        if match is None:
            raise PipelineError(f"unparseable Survey JSON moisture attribute: {raw!r}")
        values.append(match.group(1))
    if len(values) > 1:
        raise PipelineError("Survey JSON food has multiple moisture attributes")
    return values[0] if values else ""


def _validate_survey_portion_drift_topology(expected: dict, observed: Counter[tuple[str, str, str]]) -> None:
    contract = expected.get("legacyPortionParentDriftTopology")
    if not isinstance(contract, dict):
        raise PipelineError("Survey fixture has no legacy portion-drift topology contract")
    canonical = text(contract.get("canonicalFdcID"))
    fixture_ids = [text(value) for value in contract.get("fixtureFdcIDs", [])]
    portion_ids = [text(value) for value in contract.get("portionIDs", [])]
    if not canonical or not fixture_ids or not portion_ids:
        raise PipelineError("Survey fixture legacy portion-drift topology contract is incomplete")
    expected_topology = Counter({
        (portion_id, fixture_id, canonical): 1
        for portion_id in portion_ids for fixture_id in fixture_ids
    })
    if observed == expected_topology:
        return
    changed = sorted(set(observed) ^ set(expected_topology))[:3]
    multiplicity_changed = [key for key in set(observed) & set(expected_topology) if observed[key] != expected_topology[key]][:3]
    raise PipelineError(
        "Survey legacy portion-drift topology differs; "
        f"changed={changed}, multiplicity_changed={multiplicity_changed}"
    )


def validate_survey_fixture(
    path: Path,
    expected: dict,
    fdc_details: dict[str, dict],
    survey_code_to_fdc: dict[str, str],
    survey_relations: dict[tuple[str, str], dict],
    fndds_relations: dict[tuple[str, str], dict],
    fdc_portions: dict[str, dict],
) -> dict:
    foods = 0
    relations = 0
    fixture_relation_keys: set[tuple[str, str]] = set()
    fixture_fdc_ids: set[str] = set()
    amount_precision_differences = 0
    ingredient_weight_precision_differences = 0
    moisture_foods = 0
    portion_count = 0
    portion_parent_mismatches = 0
    fixture_portion_keys: set[tuple[str, str]] = set()
    portion_parent_topology: Counter[tuple[str, str, str]] = Counter()
    for food in iter_json_array(path, "SurveyFoods"):
        if foods >= MAX_FOODS:
            raise PipelineError("Survey JSON food cap exceeded")
        foods += 1
        fdc_id = text(food.get("fdcId"))
        food_code = text(food.get("foodCode"))
        if fdc_id in fixture_fdc_ids or survey_code_to_fdc.get(food_code) != fdc_id:
            raise PipelineError(f"Survey JSON duplicate/mismatched identity: {fdc_id}/{food_code}")
        fixture_fdc_ids.add(fdc_id)
        details = fdc_details.get(fdc_id)
        if details is None or details["data_type"] != "Survey (FNDDS)":
            raise PipelineError(f"Survey JSON FDC id absent from canonical subset: {fdc_id}")
        category = food.get("wweiaFoodCategory") or {}
        comparisons = (
            (text(food.get("description")), details["display_name"], "description"),
            (_json_wweia_number(food), details["category_code"], "category code"),
            (text(category.get("wweiaFoodCategoryDescription")), details["category_name"], "category description"),
        )
        mismatches = [name for left, right, name in comparisons if left != right]
        if mismatches:
            raise PipelineError(f"Survey JSON/FDC mismatch for {fdc_id}: {mismatches}")
        moisture = _json_moisture(food)
        if moisture:
            moisture_foods += 1
        for item in food.get("inputFoods") or []:
            if relations >= MAX_INGREDIENT_RELATIONS:
                raise PipelineError("Survey JSON relation cap exceeded")
            key = (food_code, text(item.get("sequenceNumber")))
            canonical = survey_relations.get(key)
            workbook = fndds_relations.get(key)
            if canonical is None or workbook is None or key in fixture_relation_keys:
                raise PipelineError(f"Survey JSON relation identity mismatch: {key}")
            json_weight = _decimal_from_json(item.get("ingredientWeight"))
            canonical_weight = Decimal(canonical["ingredient_weight"])
            if json_weight != canonical_weight:
                ingredient_weight_precision_differences += 1
                if Decimal(excel_numeric_text(str(json_weight))) != canonical_weight:
                    raise PipelineError(
                        f"Survey JSON ingredient weight is not the expected 15-significant-digit representation: {key}"
                    )
            comparisons = (
                (text(item.get("id")), canonical["id"], "id"),
                (text(item.get("ingredientCode")), canonical["ingredient_code"], "ingredient code"),
                (text(item.get("ingredientDescription")), canonical["ingredient_description"], "ingredient description"),
                (text(item.get("retentionCode")), canonical["retention_code"], "retention code"),
                (text(item.get("unit")), canonical["unit"], "unit"),
                (text(item.get("portionCode")), canonical["portion_code"], "portion code"),
                (text(item.get("portionDescription")), canonical["portion_description"], "portion description"),
            )
            mismatches = [name for left, right, name in comparisons if left != right]
            if mismatches:
                raise PipelineError(f"Survey JSON/FDC relation mismatch {key}: {mismatches}")
            json_amount_raw = _decimal_from_json(item.get("amount"))
            json_amount = Decimal(excel_numeric_text(str(json_amount_raw)))
            fdc_amount = Decimal(canonical["amount"])
            if json_amount != fdc_amount:
                amount_precision_differences += 1
                if json_amount != significant_round(fdc_amount):
                    raise PipelineError(f"Survey JSON amount is not the expected 3-significant-digit representation: {key}")
            if moisture and Decimal(moisture) != Decimal(workbook["moisture"]):
                raise PipelineError(f"Survey JSON/FNDDS moisture mismatch: {food_code}")
            fixture_relation_keys.add(key)
            relations += 1
        for portion in food.get("foodPortions") or []:
            if portion_count >= MAX_PORTIONS:
                raise PipelineError("Survey JSON portion cap exceeded")
            portion_id = text(portion.get("id"))
            portion_key = (fdc_id, portion_id)
            if portion_key in fixture_portion_keys:
                raise PipelineError(f"Survey JSON duplicate parent-scoped portion identity: {portion_key}")
            fixture_portion_keys.add(portion_key)
            canonical = fdc_portions.get(portion_id)
            if canonical is None:
                raise PipelineError(f"Survey JSON portion absent from FDC CSV: {portion_id}")
            if canonical["fdc_id"] != fdc_id:
                portion_parent_mismatches += 1
                portion_parent_topology[(portion_id, fdc_id, canonical["fdc_id"])] += 1
            measure_unit = portion.get("measureUnit") or {}
            comparisons = (
                (text(portion.get("sequenceNumber")), canonical["sequence"], "sequence"),
                (text(portion.get("amount")), canonical["amount"], "amount"),
                (text(measure_unit.get("id")), canonical["measure_unit_id"], "measure unit"),
                (text(measure_unit.get("name")), canonical["unit"], "measure unit name"),
                (text(portion.get("modifier")), canonical["modifier"], "modifier"),
                (text(portion.get("portionDescription")), canonical["description"], "description"),
            )
            mismatches = [name for left, right, name in comparisons if left != right]
            json_weight = _decimal_from_json(portion.get("gramWeight"))
            if Decimal(excel_numeric_text(str(json_weight))) != Decimal(canonical["gram_weight"]):
                mismatches.append("gram weight")
            if mismatches:
                raise PipelineError(f"Survey JSON/FDC portion mismatch {portion_id}: {mismatches}")
            portion_count += 1
    if foods != expected["foods"] or relations != expected["inputRelations"]:
        raise PipelineError(f"Survey fixture counts differ: foods={foods}, relations={relations}")
    if fixture_relation_keys != set(survey_relations):
        raise PipelineError("Survey fixture relation key set differs from canonical FDC")
    expected_fdc_ids = {fdc_id for fdc_id, details in fdc_details.items() if details["data_type"] == "Survey (FNDDS)"}
    if fixture_fdc_ids != expected_fdc_ids:
        raise PipelineError("Survey fixture food identity set differs from canonical FDC")
    _validate_survey_portion_drift_topology(expected, portion_parent_topology)
    return {
        "foods": foods, "relations": relations, "portions": portion_count,
        "moisture_foods": moisture_foods,
        "amount_precision_differences": amount_precision_differences,
        "ingredient_weight_precision_differences": ingredient_weight_precision_differences,
        "portion_parent_mismatches": portion_parent_mismatches,
    }


def validate_sr_fixture(path: Path, expected: dict, fdc_details: dict[str, dict]) -> dict:
    count = 0
    seen: set[str] = set()
    for food in iter_json_array(path, "SRLegacyFoods"):
        if count >= MAX_FOODS:
            raise PipelineError("SR JSON food cap exceeded")
        count += 1
        fdc_id = text(food.get("fdcId"))
        details = fdc_details.get(fdc_id)
        if fdc_id in seen or details is None or details["data_type"] != "SR Legacy":
            raise PipelineError(f"SR fixture duplicate/unknown FDC id: {fdc_id}")
        if text(food.get("description")) != details["display_name"]:
            raise PipelineError(f"SR fixture description mismatch for {fdc_id}")
        seen.add(fdc_id)
    if count != expected["foods"]:
        raise PipelineError(f"SR fixture count {count} != {expected['foods']}")
    expected_ids = {fdc_id for fdc_id, details in fdc_details.items() if details["data_type"] == "SR Legacy"}
    if seen != expected_ids:
        raise PipelineError("SR fixture identity set differs from canonical FDC")
    return {"foods": count}


def _cofid_basis(sheet_name: str, food_basis: str) -> str:
    if "per 100gFA" in sheet_name or "per 100FA" in sheet_name:
        return "per_100g_fatty_acids"
    return food_basis


def _cofid_food_basis(group: str) -> str:
    if group.startswith(COFID_ALCOHOL_GROUP_PREFIX):
        return "per_100ml_alcoholic_beverage"
    return "per_100g_food"


def _header_unit(header: str) -> str | None:
    match = re.search(r"\(([^()]*)\)\s*$", header)
    return match.group(1) if match is not None else None


def _load_cofid_base(path: Path, expected: dict) -> tuple[list[dict], set[str]]:
    notes = [text(values[0] if values else None) for _, values in iter_sheet_rows(str(path), COFID_NOTES_SHEET)]
    if not any("trace value for a nutrient is represented by Tr" in note for note in notes):
        raise PipelineError("CoFID notes do not define Tr")
    if not any("value is represented by N" in note for note in notes):
        raise PipelineError("CoFID notes do not define N")
    rows = iter_sheet_rows(str(path), COFID_BASE_SHEET)
    header_number, headers = next(rows)
    if header_number != 1 or [text(value) for value in headers[:7]] != [
        "Food Code", "Food Name", "Description", "Group", "Previous", "Main data references", "Footnote"
    ]:
        raise PipelineError("unexpected CoFID Factors identity headers")
    records: list[dict] = []
    code_counts: Counter[str] = Counter()
    for row_number, values in rows:
        code = text(values[0] if len(values) > 0 else None)
        name = text(values[1] if len(values) > 1 else None)
        if not code and not name:
            continue
        if row_number < 4 or not code or not name:
            raise PipelineError(f"invalid CoFID base identity at row {row_number}")
        description = text(values[2] if len(values) > 2 else None)
        record = {
            "code": code, "name": name, "description": description,
            "group": text(values[3] if len(values) > 3 else None),
            "previous": text(values[4] if len(values) > 4 else None),
            "references": text(values[5] if len(values) > 5 else None),
            "footnote": text(values[6] if len(values) > 6 else None),
            "factors": {},
        }
        for index in range(7, min(len(values), len(headers))):
            factor_name = text(headers[index])
            raw = text(values[index])
            if factor_name and raw:
                record["factors"][factor_name] = (raw, value_status(raw))
        if len(records) >= MAX_FOODS:
            raise PipelineError("CoFID food cap exceeded")
        records.append(record)
        code_counts[code] += 1
    duplicate_codes = {code for code, count in code_counts.items() if count > 1}
    if len(records) != expected["foods"]:
        raise PipelineError(f"CoFID food count {len(records)} != {expected['foods']}")
    if duplicate_codes != set(expected["duplicateSourceCodes"]):
        raise PipelineError(f"unexpected CoFID duplicate codes: {sorted(duplicate_codes)}")
    duplicate_names = sorted(record["name"] for record in records if record["code"] == COFID_DUPLICATE_CODE)
    expected_names = ["Aubergine, flesh and skin, roasted in rapeseed oil", "Watercress, raw"]
    if duplicate_names != expected_names:
        raise PipelineError(f"CoFID {COFID_DUPLICATE_CODE} identities changed: {duplicate_names}")
    return records, duplicate_codes


def _insert_cofid_foods(
    connection: sqlite3.Connection,
    records: list[dict],
    duplicate_codes: set[str],
    version: str,
) -> tuple[dict[tuple[str, str], tuple[int, str]], int]:
    identities: dict[tuple[str, str], tuple[int, str]] = {}
    factor_count = 0
    sql = """
        INSERT INTO food (
            stable_id,source_key,source_version,source_id,source_code,legacy_uuid,
            display_name,normalized_name,description,category_code,category_name,data_type,
            brand_source,gtin_upc,source_references,publication_date,start_date,end_date
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    for record in sorted(records, key=lambda item: cofid_stable_id(item["code"], item["name"], item["description"], duplicate_codes)):
        stable_id = cofid_stable_id(record["code"], record["name"], record["description"], duplicate_codes)
        source_id = stable_id.removeprefix("uk_cofid:")
        source_references = " | ".join(value for value in (record["references"], record["footnote"]) if value)
        connection.execute(sql, (
            stable_id, "uk_cofid", version, source_id, record["code"], stable_uuid(stable_id),
            record["name"], normalize_text(record["name"]), record["description"] or None,
            record["group"] or None, record["group"] or "CoFID", "cofid",
            "UK CoFID 2021", None, source_references or None, "2021-03-19", None, None,
        ))
        food_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
        identity = (record["code"], record["name"])
        if identity in identities:
            raise PipelineError(f"duplicate CoFID code/name identity: {identity}")
        identities[identity] = (food_id, _cofid_food_basis(record["group"]))
        for factor_name, (raw, status) in sorted(record["factors"].items()):
            connection.execute("INSERT INTO food_factor VALUES (?,?,?,?)", (food_id, factor_name, raw, status))
            factor_count += 1
    return identities, factor_count


def _load_cofid_nutrients(
    connection: sqlite3.Connection,
    path: Path,
    identities: dict[tuple[str, str], tuple[int, str]],
) -> dict:
    total_values = 0
    trace_values = 0
    unknown_values = 0
    missing_cells = 0
    definition_count = 0
    for sheet_name in COFID_DATA_SHEETS:
        rows = iter_sheet_rows(str(path), sheet_name)
        header_number, header = next(rows)
        code_number, codes = next(rows)
        name_number, names = next(rows)
        if (header_number, code_number, name_number) != (1, 2, 3):
            raise PipelineError(f"unexpected CoFID three-row header in {sheet_name}")
        width = max(len(header), len(codes), len(names))
        definitions: dict[int, tuple[str, str, str | None, str]] = {}
        for index in range(7, width):
            nutrient_code = text(codes[index] if index < len(codes) else None)
            display_name = text(names[index] if index < len(names) else None)
            column_header = text(header[index] if index < len(header) else None)
            if not nutrient_code and not display_name and not column_header:
                continue
            display_name = display_name or column_header
            if not nutrient_code or not display_name:
                raise PipelineError(f"incomplete CoFID nutrient definition {sheet_name} column {index + 1}")
            unit = _header_unit(column_header)
            if definition_count >= MAX_NUTRIENT_DEFINITIONS:
                raise PipelineError("CoFID nutrient-definition cap exceeded")
            definitions[index] = (nutrient_code, display_name, unit)
            connection.execute(
                "INSERT INTO nutrient_definition VALUES (?,?,?,?,?,?,?)",
                ("uk_cofid", nutrient_code, display_name, unit, "source_food_basis", sheet_name, str(index + 1)),
            )
            definition_count += 1
        seen_identities: set[tuple[str, str]] = set()
        for row_number, values in rows:
            code = text(values[0] if len(values) > 0 else None)
            name = text(values[1] if len(values) > 1 else None)
            if not code and not name:
                continue
            identity = (code, name)
            resolved = identities.get(identity)
            if resolved is None or identity in seen_identities:
                raise PipelineError(f"CoFID {sheet_name} unknown/duplicate identity at row {row_number}: {identity}")
            seen_identities.add(identity)
            food_id, food_basis = resolved
            for index, definition in definitions.items():
                raw = text(values[index] if index < len(values) else None)
                status = value_status(raw)
                if status == "missing":
                    missing_cells += 1
                    continue
                nutrient_code, display_name, unit = definition
                basis = _cofid_basis(sheet_name, food_basis)
                if total_values >= MAX_NUTRIENT_VALUES:
                    raise PipelineError("CoFID nutrient-value cap exceeded")
                connection.execute(
                    """
                    INSERT INTO nutrient_value (
                        food_id,source_key,nutrient_code,source_sheet,source_value_id,amount_text,value_status,unit,basis
                    ) VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    (food_id, "uk_cofid", nutrient_code, sheet_name, f"{row_number}:{index + 1}", raw, status, unit, basis),
                )
                total_values += 1
                trace_values += int(status == "trace")
                unknown_values += int(status == "present_unknown")
        if seen_identities != set(identities):
            raise PipelineError(f"CoFID {sheet_name} identity set differs from Factors sheet")
    return {
        "definitions": definition_count, "values": total_values,
        "trace_values": trace_values, "unknown_values": unknown_values,
        "missing_cells": missing_cells,
    }


def _normalized_gtin(raw) -> str:
    digits = "".join(character for character in text(raw) if character.isdigit())
    if len(digits) not in (8, 12, 13, 14):
        raise PipelineError(f"invalid curated GTIN: {raw!r}")
    return digits.zfill(14)


def load_shipping_uuid_map(committed_catalog: Path, expected: dict) -> dict[str, str]:
    if not committed_catalog.is_file():
        raise PipelineError(f"missing committed catalog for compatibility mapping: {committed_catalog}")
    expected_hash = text(expected.get("shippingCatalogSHA256"))
    if expected_hash and sha256_file(committed_catalog) != expected_hash:
        raise PipelineError("committed catalog hash differs from curated branded compatibility contract")
    connection = sqlite3.connect(f"file:{committed_catalog}?mode=ro", uri=True)
    mapping: dict[str, str] = {}
    try:
        rows = connection.execute("SELECT gtin_upc,id FROM food WHERE gtin_upc IS NOT NULL ORDER BY gtin_upc,id")
        for raw_gtin, raw_uuid in rows:
            if len(mapping) >= expected["foods"]:
                raise PipelineError("committed catalog GTIN compatibility mapping exceeds expected count")
            gtin = _normalized_gtin(raw_gtin)
            shipping_uuid = text(raw_uuid)
            if gtin in mapping or not shipping_uuid:
                raise PipelineError(f"committed catalog has duplicate or blank GTIN compatibility mapping: {gtin}")
            mapping[gtin] = shipping_uuid
    except sqlite3.Error as error:
        raise PipelineError(f"cannot read committed catalog compatibility mapping: {error}") from error
    finally:
        connection.close()
    if len(mapping) != expected["foods"] or len(set(mapping.values())) != len(mapping):
        raise PipelineError("committed catalog GTIN-to-UUID mapping is not one-to-one or complete")
    return mapping


def _branded_exceptions(expected: dict, shipping_uuids: dict[str, str]) -> dict[str, str]:
    exceptions: dict[str, str] = {}
    for entry in expected.get("legacyFullFdcExceptions", []):
        gtin = _normalized_gtin(entry.get("gtin"))
        shipping_uuid = text(entry.get("shippingUUID"))
        reason = text(entry.get("reason"))
        if not shipping_uuid or not reason or gtin in exceptions:
            raise PipelineError("invalid curated branded full-FDC exception contract")
        if shipping_uuids.get(gtin) != shipping_uuid:
            raise PipelineError(f"full-FDC exception UUID does not match committed catalog: {gtin}")
        exceptions[gtin] = reason
    return exceptions


def load_curated_branded(
    connection: sqlite3.Connection,
    path: Path,
    expected: dict,
    version: str,
    shipping_uuids: dict[str, str],
) -> dict:
    _bounded_file_size(path, MAX_CURATED_JSON_BYTES, "curated branded JSON")
    with path.open(encoding="utf-8") as source:
        records = json.load(source, parse_float=Decimal, parse_int=Decimal)
    if not isinstance(records, list) or len(records) != expected["foods"] or len(records) > MAX_FOODS:
        raise PipelineError(f"curated branded row count differs: {len(records) if isinstance(records, list) else 'not-array'}")
    _validate_json_value(records)
    nutrient_contract = {
        "protein": ("Protein", "g"), "carbs": ("Carbohydrate", "g"), "fat": ("Fat", "g"),
        "fiber": ("Fibre", "g"), "sugar": ("Sugars", "g"),
        "saturatedFat": ("Saturated fat", "g"), "cholesterol": ("Cholesterol", "mg"),
        "sodium": ("Sodium", "mg"), "calcium": ("Calcium", "mg"), "iron": ("Iron", "mg"),
    }
    connection.executemany(
        "INSERT INTO nutrient_definition VALUES (?,?,?,?,?,?,?)",
        [
            ("usda_branded_curated", code, label, unit, "label_serving", "BrandedCuratedFoodItems.json", str(index))
            for index, (code, (label, unit)) in enumerate(sorted(nutrient_contract.items()), 1)
        ],
    )
    prepared = []
    seen_gtins: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise PipelineError("curated branded JSON contains a non-object")
        gtin = _normalized_gtin(record.get("gtinUpc"))
        if gtin in seen_gtins:
            raise PipelineError(f"duplicate curated branded GTIN: {gtin}")
        seen_gtins.add(gtin)
        name = text(record.get("name"))
        if not name:
            raise PipelineError(f"curated branded GTIN {gtin} has blank name")
        if gtin not in shipping_uuids:
            raise PipelineError(f"curated branded GTIN lacks a committed catalog UUID: {gtin}")
        prepared.append((gtin, name, record))
    if set(seen_gtins) != set(shipping_uuids):
        raise PipelineError("curated branded GTIN allowlist differs from committed catalog mapping")
    food_sql = """
        INSERT INTO food (
            stable_id,source_key,source_version,source_id,source_code,legacy_uuid,
            display_name,normalized_name,description,category_code,category_name,data_type,
            brand_source,gtin_upc,source_references,publication_date,start_date,end_date
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    nutrient_values = 0
    portion_count = 0
    for gtin, name, record in sorted(prepared):
        stable_id = f"usda_branded_curated:{gtin}"
        brand_source = text(record.get("brandSource"))
        category = text(record.get("category")) or "Branded"
        connection.execute(food_sql, (
            stable_id, "usda_branded_curated", version, gtin, gtin, shipping_uuids[gtin],
            name, normalize_text(name), None, None, category, "branded",
            brand_source or None, gtin, "Existing Fernlet category-balanced curated FDC branded tier",
            "2026-04-30", None, None,
        ))
        food_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
        for nutrient_code, (display_name, unit) in sorted(nutrient_contract.items()):
            if nutrient_code not in record:
                continue
            raw = text(record[nutrient_code])
            status = value_status(raw)
            if status != "numeric":
                raise PipelineError(f"curated branded nutrient {nutrient_code} is not numeric")
            connection.execute(
                """
                INSERT INTO nutrient_value (
                    food_id,source_key,nutrient_code,source_sheet,source_value_id,amount_text,value_status,unit,basis
                ) VALUES (?,?,?,?,?,?,?,?,?)
                """,
                (food_id, "usda_branded_curated", nutrient_code, "BrandedCuratedFoodItems.json", nutrient_code, raw, status, unit, "label_serving"),
            )
            nutrient_values += 1
        serving_size = text(record.get("servingSize"))
        serving_unit = text(record.get("servingUnit"))
        if not serving_size or not serving_unit:
            raise PipelineError(f"curated branded GTIN {gtin} lacks serving basis")
        gram_weight = serving_size if normalize_text(serving_unit) in {"g", "gm", "grm", "gram", "grams"} else None
        connection.execute(
            """
            INSERT INTO portion (
                food_id,source_portion_id,sequence_text,amount_text,raw_unit,gram_weight_text,
                modifier,description,data_points_text,footnote,min_year_acquired
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            (food_id, f"curated:{gtin}:serving", "1", serving_size, serving_unit, gram_weight,
             None, "curated label serving", None, None, None),
        )
        portion_count += 1
    return {"foods": len(prepared), "nutrient_values": nutrient_values, "portions": portion_count}


def enrich_curated_branded(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    expected: dict,
    shipping_uuids: dict[str, str],
    measure_units: dict[str, str],
) -> dict:
    selected = dict(connection.execute(
        "SELECT gtin_upc,food_id FROM food WHERE source_key='usda_branded_curated' ORDER BY gtin_upc"
    ))
    if set(selected) != set(shipping_uuids):
        raise PipelineError("curated branded output GTIN set differs from committed catalog mapping")
    exceptions = _branded_exceptions(expected, shipping_uuids)
    raw_records = _insert_branded_fdc_records(connection, archive, selected)
    missing = set(selected) - set(raw_records)
    if missing != set(exceptions):
        raise PipelineError(f"full FDC selected GTIN set differs from approved exceptions: {sorted(missing)}")
    _enrich_branded_fdc_food_rows(connection, archive, raw_records)
    nutrient_count = _insert_branded_fdc_nutrients(connection, archive, raw_records)
    portion_count = _insert_branded_fdc_portions(connection, archive, raw_records, measure_units)
    _insert_branded_compatibility(connection, selected, shipping_uuids, raw_records, exceptions)
    return {
        "selected_gtins": len(selected), "full_fdc_enriched_gtins": len(raw_records),
        "full_fdc_records": sum(raw_records.values()), "full_fdc_nutrients": nutrient_count,
        "full_fdc_portions": portion_count, "legacy_exceptions": sorted(missing),
    }


def _insert_branded_fdc_records(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    selected: dict[str, int],
) -> dict[str, int]:
    source, text_source, reader = _zip_csv(archive, "branded_food.csv")
    _require_headers(reader, {"fdc_id", *BRANDED_FDC_FIELDS}, "branded_food.csv")
    counts: Counter[str] = Counter()
    seen_fdc_ids: set[str] = set()
    total_records = 0
    sql = """
        INSERT INTO branded_fdc_record (
            fdc_id,food_id,gtin_upc,food_description,food_category_id,food_publication_date,
            brand_owner,brand_name,subbrand_name,raw_gtin_upc,ingredients,not_a_significant_source_of,
            serving_size_text,serving_size_unit,household_serving_fulltext,branded_food_category,
            data_source,package_weight,modified_date,available_date,market_country,discontinued_date,
            preparation_state_code,trade_channel,short_description,material_code
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """
    try:
        for row in reader:
            raw_gtin = raw_text(row["gtin_upc"])
            try:
                gtin = _normalized_gtin(raw_gtin)
            except PipelineError:
                continue
            food_id = selected.get(gtin)
            if food_id is None:
                continue
            fdc_id = text(row["fdc_id"])
            if not fdc_id or fdc_id in seen_fdc_ids:
                raise PipelineError(f"duplicate or blank selected full-FDC branded id: {fdc_id!r}")
            if total_records >= MAX_BRANDED_FDC_RECORDS:
                raise PipelineError("selected full-FDC branded record cap exceeded")
            seen_fdc_ids.add(fdc_id)
            values = [raw_text(row[field]) for field in BRANDED_FDC_FIELDS]
            connection.execute(sql, (fdc_id, food_id, gtin, "", None, None, *values))
            counts[gtin] += 1
            total_records += 1
    finally:
        _close_csv(source, text_source)
    return dict(counts)


def _enrich_branded_fdc_food_rows(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    raw_records: dict[str, int],
) -> None:
    selected_fdc_ids = {row[0] for row in connection.execute("SELECT fdc_id FROM branded_fdc_record")}
    source, text_source, reader = _zip_csv(archive, "food.csv")
    _require_headers(reader, {"fdc_id", "data_type", "description", "food_category_id", "publication_date"}, "food.csv")
    found: set[str] = set()
    try:
        for row in reader:
            fdc_id = text(row["fdc_id"])
            if fdc_id not in selected_fdc_ids:
                continue
            if text(row["data_type"]) != "branded_food" or fdc_id in found:
                raise PipelineError(f"selected full-FDC record has invalid food.csv identity: {fdc_id}")
            connection.execute(
                "UPDATE branded_fdc_record SET food_description=?,food_category_id=?,food_publication_date=? WHERE fdc_id=?",
                (raw_text(row["description"]), raw_text(row["food_category_id"]), raw_text(row["publication_date"]), fdc_id),
            )
            found.add(fdc_id)
    finally:
        _close_csv(source, text_source)
    if found != selected_fdc_ids or not raw_records:
        raise PipelineError("selected full-FDC branded records lack matching food.csv rows")


def _insert_branded_fdc_nutrients(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    raw_records: dict[str, int],
) -> int:
    selected_fdc_ids = {row[0] for row in connection.execute("SELECT fdc_id FROM branded_fdc_record")}
    source, text_source, reader = _zip_csv(archive, "food_nutrient.csv")
    required = {"id", "fdc_id", "nutrient_id", "amount", "data_points", "derivation_id", "min", "max", "median", "loq", "footnote", "min_year_acquired", "percent_daily_value"}
    _require_headers(reader, required, "food_nutrient.csv")
    count = 0
    try:
        for row in reader:
            fdc_id = text(row["fdc_id"])
            if fdc_id not in selected_fdc_ids:
                continue
            if count >= MAX_BRANDED_FDC_NUTRIENTS:
                raise PipelineError("selected full-FDC branded nutrient cap exceeded")
            connection.execute(
                "INSERT INTO branded_fdc_nutrient VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(raw_text(row[field]) for field in ("fdc_id", "id", "nutrient_id", "amount", "data_points", "derivation_id", "min", "max", "median", "loq", "footnote", "min_year_acquired", "percent_daily_value")),
            )
            count += 1
    finally:
        _close_csv(source, text_source)
    if count <= 0 or not raw_records:
        raise PipelineError("selected full-FDC branded records have no raw nutrient values")
    return count


def _insert_branded_fdc_portions(
    connection: sqlite3.Connection,
    archive: zipfile.ZipFile,
    raw_records: dict[str, int],
    measure_units: dict[str, str],
) -> int:
    selected_fdc_ids = {row[0] for row in connection.execute("SELECT fdc_id FROM branded_fdc_record")}
    source, text_source, reader = _zip_csv(archive, "food_portion.csv")
    required = {"id", "fdc_id", "seq_num", "amount", "measure_unit_id", "portion_description", "modifier", "gram_weight", "data_points", "footnote", "min_year_acquired"}
    _require_headers(reader, required, "food_portion.csv")
    count = 0
    try:
        for row in reader:
            fdc_id = text(row["fdc_id"])
            if fdc_id not in selected_fdc_ids:
                continue
            if count >= MAX_BRANDED_FDC_PORTIONS:
                raise PipelineError("selected full-FDC branded portion cap exceeded")
            unit_id = raw_text(row["measure_unit_id"])
            connection.execute(
                "INSERT INTO branded_fdc_portion VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    fdc_id, raw_text(row["id"]), raw_text(row["seq_num"]), raw_text(row["amount"]),
                    unit_id, measure_units.get(unit_id), raw_text(row["portion_description"]),
                    raw_text(row["modifier"]), raw_text(row["gram_weight"]), raw_text(row["data_points"]),
                    raw_text(row["footnote"]), raw_text(row["min_year_acquired"]),
                ),
            )
            count += 1
    finally:
        _close_csv(source, text_source)
    return count


def _insert_branded_compatibility(
    connection: sqlite3.Connection,
    selected: dict[str, int],
    shipping_uuids: dict[str, str],
    raw_records: dict[str, int],
    exceptions: dict[str, str],
) -> None:
    rows = []
    for gtin, food_id in sorted(selected.items()):
        record_count = raw_records.get(gtin, 0)
        status = "enriched" if record_count else BRANDED_FDC_EXCEPTION_STATUS
        reason = None if record_count else exceptions.get(gtin)
        if (record_count == 0) != (reason is not None):
            raise PipelineError(f"full-FDC exception contract mismatch for selected GTIN: {gtin}")
        rows.append((gtin, food_id, shipping_uuids[gtin], status, reason, record_count))
    if len({row[0] for row in rows}) != len(rows) or len({row[2] for row in rows}) != len(rows):
        raise PipelineError("GTIN-to-shipping-UUID compatibility mapping is not one-to-one")
    bounded_executemany(connection, "INSERT INTO branded_compatibility VALUES (?,?,?,?,?,?)", rows)


def _macro_contract(source_key: str) -> tuple[str, str, str]:
    if source_key == "usda_fdc_consumer":
        return "1003", "1005", "1004"
    if source_key == "uk_cofid":
        return "PROT", "CHO", "FAT"
    if source_key == "usda_branded_curated":
        return "protein", "carbs", "fat"
    raise PipelineError(f"no compatibility macro contract for {source_key}")


def _macro_value(connection: sqlite3.Connection, food_id: int, code: str) -> tuple[str | None, str]:
    row = connection.execute(
        """
        SELECT amount_text,value_status FROM nutrient_value WHERE food_id=? AND nutrient_code=?
        ORDER BY CASE WHEN source_key='usda_fdc_consumer' THEN CAST(source_value_id AS INTEGER) ELSE 0 END,
                 source_sheet,source_value_id LIMIT 1
        """,
        (food_id, code),
    ).fetchone()
    return (None, "missing") if row is None else (text(row[0]), text(row[1]))


def populate_compatibility(connection: sqlite3.Connection) -> int:
    count = 0
    for food_id, source_key, legacy_uuid in connection.execute(
        "SELECT food_id,source_key,legacy_uuid FROM food ORDER BY food_id"
    ):
        if count >= MAX_FOODS:
            raise PipelineError("legacy compatibility food cap exceeded")
        protein_code, carbs_code, fat_code = _macro_contract(source_key)
        protein_raw, protein_status = _macro_value(connection, food_id, protein_code)
        carbs_raw, carbs_status = _macro_value(connection, food_id, carbs_code)
        fat_raw, fat_status = _macro_value(connection, food_id, fat_code)
        if source_key == "usda_branded_curated":
            portion = connection.execute(
                "SELECT amount_text,raw_unit FROM portion WHERE food_id=? ORDER BY portion_id LIMIT 1",
                (food_id,),
            ).fetchone()
            if portion is None:
                raise PipelineError(f"curated food {food_id} has no serving portion")
            serving_size, serving_unit = text(portion[0]), text(portion[1])
        elif source_key == "uk_cofid":
            serving_size, serving_unit = "100", "g-or-ml-source-basis"
        else:
            serving_size, serving_unit = "100", "g"
        connection.execute(
            "INSERT INTO legacy_compatibility VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                food_id, legacy_uuid, serving_size, serving_unit,
                protein_raw, protein_status, legacy_integer(protein_raw, protein_status),
                carbs_raw, carbs_status, legacy_integer(carbs_raw, carbs_status),
                fat_raw, fat_status, legacy_integer(fat_raw, fat_status),
                "Raw source text/status are authoritative; integers use Decimal ROUND_HALF_UP only for legacy FoodItem compatibility; missing/Tr/N remain NULL.",
            ),
        )
        count += 1
    return count


def populate_fts(connection: sqlite3.Connection) -> int:
    ingredient_text: dict[int, list[str]] = defaultdict(list)
    relation_rows = connection.execute(
        """
        SELECT food_id,ingredient_description FROM food_ingredient
        ORDER BY food_id,CAST(sequence_text AS INTEGER),source_relation_id
        """
    )
    for food_id, description in relation_rows:
        normalized = normalize_text(description)
        if normalized and normalized not in ingredient_text[food_id]:
            ingredient_text[food_id].append(normalized)
    count = 0
    for food_id, display_name, normalized_name, brand_source, category_name in connection.execute(
        "SELECT food_id,display_name,normalized_name,brand_source,category_name FROM food ORDER BY food_id"
    ):
        connection.execute(
            "INSERT INTO food_fts(rowid,display_name,normalized_name,brand_source,ingredient_text,category) VALUES (?,?,?,?,?,?)",
            (
                food_id, normalize_text(display_name), normalized_name,
                normalize_text(brand_source), " ".join(ingredient_text.get(food_id, [])),
                normalize_text(category_name),
            ),
        )
        count += 1
    connection.execute("INSERT INTO food_fts(food_fts) VALUES('optimize')")
    return count


def _evidence(connection: sqlite3.Connection, values: dict[str, object]) -> None:
    if len(values) > 32:
        raise PipelineError("validation-evidence row cap exceeded")
    rows = []
    for key, value in sorted(values.items()):
        payload = json.dumps(value, sort_keys=True, separators=(",", ":"))
        if len(payload.encode("utf-8")) > MAX_EVIDENCE_BYTES:
            raise PipelineError(f"validation evidence exceeds {MAX_EVIDENCE_BYTES} bytes: {key}")
        rows.append((key, payload))
    bounded_executemany(connection, "INSERT INTO validation_evidence VALUES (?,?)", rows)


def _expected_output_contract(manifest: dict) -> dict:
    contract = manifest.get("outputContract")
    if not isinstance(contract, dict):
        raise PipelineError("source manifest has no exact output contract")
    table_counts = contract.get("tableCounts")
    if not isinstance(table_counts, dict) or set(table_counts) != set(VALIDATION_TABLES):
        raise PipelineError("output contract table set differs from validation table set")
    return contract


def _actual_output_contract(connection: sqlite3.Connection) -> dict:
    connection.execute(
        "CREATE VIRTUAL TABLE temp.output_contract_fts_vocab USING fts5vocab(main, food_fts, instance)"
    )
    fts_row_id_count = connection.execute(
        "SELECT COUNT(DISTINCT doc) FROM temp.output_contract_fts_vocab"
    ).fetchone()[0]
    connection.execute("DROP TABLE temp.output_contract_fts_vocab")
    return {
        "tableCounts": {
            table_name: connection.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()[0]
            for table_name in VALIDATION_TABLES
        },
        "foodBySourceAndDataType": [list(row) for row in connection.execute(
            "SELECT source_key,data_type,COUNT(*) FROM food GROUP BY source_key,data_type ORDER BY source_key,data_type"
        )],
        "nutrientDefinitionBySource": [list(row) for row in connection.execute(
            "SELECT source_key,COUNT(*) FROM nutrient_definition GROUP BY source_key ORDER BY source_key"
        )],
        "nutrientValueBySourceStatusBasis": [list(row) for row in connection.execute(
            "SELECT source_key,value_status,basis,COUNT(*) FROM nutrient_value "
            "GROUP BY source_key,value_status,basis ORDER BY source_key,value_status,basis"
        )],
        "foodFactorByStatus": [list(row) for row in connection.execute(
            "SELECT value_status,COUNT(*) FROM food_factor GROUP BY value_status ORDER BY value_status"
        )],
        "portionBySource": [list(row) for row in connection.execute(
            "SELECT food.source_key,COUNT(*) FROM portion JOIN food USING(food_id) "
            "GROUP BY food.source_key ORDER BY food.source_key"
        )],
        "foodIngredientBySource": [list(row) for row in connection.execute(
            "SELECT food.source_key,COUNT(*) FROM food_ingredient JOIN food USING(food_id) "
            "GROUP BY food.source_key ORDER BY food.source_key"
        )],
        "cofidFoodBasis": [list(row) for row in connection.execute(
            "SELECT basis,COUNT(DISTINCT food_id),COUNT(*) FROM nutrient_value "
            "WHERE source_key='uk_cofid' GROUP BY basis ORDER BY basis"
        )],
        "ftsRowIDCount": fts_row_id_count,
    }


def _validate_source_manifest_rows(connection: sqlite3.Connection, manifest: dict) -> None:
    columns = (
        "enabled", "role", "version", "release_date", "input_bytes", "input_sha256", "license",
        "license_url", "publisher", "attribution",
    )
    observed_rows = connection.execute(
        "SELECT source_key,enabled,role,version,release_date,input_filename,input_bytes,input_sha256,"
        "license,license_url,publisher,attribution FROM source_manifest ORDER BY source_key"
    ).fetchall()
    observed = {row[0]: row[1:] for row in observed_rows}
    expected_entries = {entry["key"]: entry for entry in manifest["sources"]}
    if set(observed) != set(expected_entries):
        raise PipelineError("stored source-manifest key set differs from source manifest")
    for key, entry in expected_entries.items():
        row = observed[key]
        filename = text(row[4])
        expected = (
            int(entry["enabled"]), entry["role"], entry["version"], entry.get("releaseDate"),
            entry["bytes"], entry["sha256"], entry["license"], entry["licenseURL"],
            entry["publisher"], entry["attribution"],
        )
        actual = tuple(row[index] for index in (0, 1, 2, 3, 5, 6, 7, 8, 9, 10))
        if actual != expected or filename not in entry["acceptedFilenames"]:
            raise PipelineError(f"stored source-manifest row differs for {key}")


def _stored_validation_evidence(connection: sqlite3.Connection, key: str) -> object:
    row = connection.execute(
        "SELECT evidence_value FROM validation_evidence WHERE evidence_key=?", (key,)
    ).fetchone()
    if row is None:
        raise PipelineError(f"validation evidence is missing {key}")
    try:
        return json.loads(row[0])
    except json.JSONDecodeError as error:
        raise PipelineError(f"validation evidence is invalid JSON for {key}") from error


def _validate_content_hashes(connection: sqlite3.Connection) -> None:
    expected = _stored_validation_evidence(connection, "table_content_sha256")
    actual = table_content_hashes(connection)
    if expected != actual:
        raise PipelineError("table content hash differs from staged generation evidence")


def _validate_source_consistency(connection: sqlite3.Connection) -> None:
    checks = {
        "nutrient food source": "SELECT COUNT(*) FROM nutrient_value JOIN food USING(food_id) WHERE nutrient_value.source_key!=food.source_key",
        "nutrient definition": "SELECT COUNT(*) FROM nutrient_value AS value LEFT JOIN nutrient_definition AS definition ON definition.source_key=value.source_key AND definition.nutrient_code=value.nutrient_code AND definition.source_sheet=value.source_sheet WHERE definition.nutrient_code IS NULL",
        "legacy UUID": "SELECT COUNT(*) FROM legacy_compatibility JOIN food USING(food_id) WHERE legacy_compatibility.legacy_uuid!=food.legacy_uuid",
        "FNDDS dish parent": "SELECT COUNT(*) FROM fndds_dish JOIN food USING(food_id) WHERE food.source_key!='usda_fdc_consumer' OR food.data_type!='Survey (FNDDS)' OR food.source_code!=fndds_dish.food_code",
        "branded raw parent": "SELECT COUNT(*) FROM branded_fdc_record JOIN food USING(food_id) WHERE food.source_key!='usda_branded_curated' OR branded_fdc_record.gtin_upc!=food.gtin_upc",
        "branded compatibility parent": "SELECT COUNT(*) FROM branded_compatibility JOIN food USING(food_id) WHERE branded_compatibility.gtin_upc!=food.gtin_upc OR branded_compatibility.shipping_uuid!=food.legacy_uuid",
    }
    for label, query in checks.items():
        if connection.execute(query).fetchone()[0] != 0:
            raise PipelineError(f"source/table consistency failed: {label}")
    for raw_weight, canonical_weight, raw_moisture, canonical_moisture in connection.execute(
        "SELECT workbook_ingredient_weight_raw,ingredient_weight_text,workbook_moisture_change_percent_raw,moisture_change_percent_text FROM food_ingredient"
    ):
        if excel_numeric_text(raw_weight) != canonical_weight or excel_numeric_text(raw_moisture) != canonical_moisture:
            raise PipelineError("FNDDS raw numeric text differs from its canonical value")
    for raw_moisture, canonical_moisture in connection.execute(
        "SELECT moisture_change_percent_raw,moisture_change_percent_canonical FROM fndds_dish"
    ):
        if excel_numeric_text(raw_moisture) != canonical_moisture:
            raise PipelineError("FNDDS dish raw moisture differs from its canonical value")
    for amount, status in connection.execute("SELECT amount_text,value_status FROM nutrient_value"):
        if value_status(amount) != status:
            raise PipelineError("nutrient raw value status differs from source text")
    for amount, status in connection.execute("SELECT value_text,value_status FROM food_factor"):
        if value_status(amount) != status:
            raise PipelineError("CoFID factor status differs from source text")
    for group, sheet, basis in connection.execute(
        "SELECT food.category_code,nutrient_value.source_sheet,nutrient_value.basis FROM nutrient_value "
        "JOIN food USING(food_id) WHERE nutrient_value.source_key='uk_cofid'"
    ):
        if _cofid_basis(sheet, _cofid_food_basis(group or "")) != basis:
            raise PipelineError("CoFID nutrient basis differs from source food group or sheet")


def _validate_branded_mapping(
    connection: sqlite3.Connection,
    manifest: dict,
    shipping_uuids: dict[str, str] | None,
) -> list[tuple]:
    if shipping_uuids is None:
        raise PipelineError("exact shipping GTIN-to-UUID mapping is required for validation")
    expected = source_entry(manifest, "usda_branded_curated")["expected"]
    rows = connection.execute(
        "SELECT gtin_upc,shipping_uuid,enrichment_status,exception_reason,full_fdc_record_count FROM branded_compatibility ORDER BY gtin_upc"
    ).fetchall()
    observed_mapping = {row[0]: row[1] for row in rows}
    if observed_mapping != shipping_uuids or len(rows) != expected["foods"]:
        raise PipelineError("branded GTIN-to-shipping-UUID mapping differs from committed catalog")
    exceptions = {
        _normalized_gtin(entry["gtin"]): entry["reason"]
        for entry in expected.get("legacyFullFdcExceptions", [])
    }
    record_counts = dict(connection.execute(
        "SELECT gtin_upc,COUNT(*) FROM branded_fdc_record GROUP BY gtin_upc"
    ))
    for gtin, _, status, reason, record_count in rows:
        actual_count = record_counts.get(gtin, 0)
        expected_status = "enriched" if actual_count else BRANDED_FDC_EXCEPTION_STATUS
        expected_reason = None if actual_count else exceptions.get(gtin)
        if (record_count, status, reason) != (actual_count, expected_status, expected_reason):
            raise PipelineError(f"branded compatibility enrichment contract differs for GTIN {gtin}")
    if set(gtin for gtin, count in record_counts.items() if count == 0) or set(exceptions) != {
        gtin for gtin, _, status, _, _ in rows if status == BRANDED_FDC_EXCEPTION_STATUS
    }:
        raise PipelineError("branded legacy exception set differs from source contract")
    return rows


def _validate_fts_row_ids(connection: sqlite3.Connection) -> int:
    connection.execute("CREATE VIRTUAL TABLE temp.food_fts_vocab USING fts5vocab(main, food_fts, instance)")
    fts_ids = {row[0] for row in connection.execute("SELECT DISTINCT doc FROM temp.food_fts_vocab")}
    food_ids = {row[0] for row in connection.execute("SELECT food_id FROM food")}
    if fts_ids != food_ids:
        missing = sorted(food_ids - fts_ids)[:3]
        unexpected = sorted(fts_ids - food_ids)[:3]
        raise PipelineError(f"FTS row-ID set differs: missing={missing}, unexpected={unexpected}")
    return len(fts_ids)


def validate_database(
    path: Path,
    manifest: dict,
    shipping_uuids: dict[str, str] | None = None,
) -> dict:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise PipelineError(f"SQLite integrity_check failed: {integrity}")
        foreign_keys = connection.execute("SELECT * FROM pragma_foreign_key_check LIMIT 6").fetchall()
        if foreign_keys:
            raise PipelineError(f"SQLite foreign_key_check failed: {foreign_keys[:5]}")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        app_id = connection.execute("PRAGMA application_id").fetchone()[0]
        if version != SCHEMA_VERSION or app_id != APPLICATION_ID:
            raise PipelineError(f"SQLite schema identity mismatch: version={version}, application_id={app_id}")
        expected_contract = _expected_output_contract(manifest)
        fts_count = _validate_fts_row_ids(connection)
        actual_contract = _actual_output_contract(connection)
        if actual_contract != expected_contract:
            mismatches = {
                key: {"expected": expected_contract.get(key), "actual": actual_contract.get(key)}
                for key in sorted(set(expected_contract) | set(actual_contract))
                if expected_contract.get(key) != actual_contract.get(key)
            }
            raise PipelineError(
                "exact output table/source/status/basis contract differs from source manifest: "
                + json.dumps(mismatches, sort_keys=True, separators=(",", ":"))
            )
        _validate_source_manifest_rows(connection, manifest)
        if _stored_validation_evidence(connection, "input_contract") != input_contract(manifest):
            raise PipelineError("database manifest or input hash contract differs from source manifest")
        _validate_source_consistency(connection)
        compatibility_rows = _validate_branded_mapping(connection, manifest, shipping_uuids)
        _validate_content_hashes(connection)
        duplicate_code_rows = connection.execute(
            "SELECT stable_id,display_name FROM food WHERE source_key='uk_cofid' AND source_code=? ORDER BY stable_id",
            (COFID_DUPLICATE_CODE,),
        ).fetchall()
        if len(duplicate_code_rows) != 2 or len({row[0] for row in duplicate_code_rows}) != 2:
            raise PipelineError("CoFID duplicate 13-669 was conflated")
        excluded_type_count = connection.execute(
            "SELECT COUNT(*) FROM food WHERE data_type IN ('experimental','sample','subsample','acquisition')"
        ).fetchone()[0]
        if excluded_type_count != 0:
            raise PipelineError("excluded FDC data types reached output")
        return {
            "food_count": actual_contract["tableCounts"]["food"],
            "table_counts": actual_contract["tableCounts"],
            "food_by_source_data_type": actual_contract["foodBySourceAndDataType"],
            "nutrient_by_source_status_basis": actual_contract["nutrientValueBySourceStatusBasis"],
            "branded_compatibility_rows": len(compatibility_rows),
            "fts_row_ids": fts_count,
            "cofid_duplicate_13_669": [list(row) for row in duplicate_code_rows],
            "integrity_check": integrity,
            "foreign_key_violations": 0,
        }
    finally:
        connection.close()


def _validate_output_location(output_dir: Path, committed_catalog: Path) -> Path:
    output_dir = output_dir.resolve()
    committed_catalog = committed_catalog.resolve()
    if output_dir == committed_catalog.parent or committed_catalog.parent in output_dir.parents:
        raise PipelineError("refusing to generate into the committed FoodCatalog resource directory")
    temporary_root = Path(tempfile.gettempdir()).resolve()
    try:
        output_dir.relative_to(temporary_root)
        in_temporary_root = True
    except ValueError:
        in_temporary_root = False
    if output_dir.name != ".food-catalog-build" and not in_temporary_root:
        raise PipelineError("output must be the repo's .food-catalog-build directory or an isolated /tmp directory")
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def published_paths(output_dir: Path) -> tuple[Path, Path]:
    root = output_dir.resolve()
    current = root / "current"
    try:
        generation = current.resolve(strict=True)
    except FileNotFoundError as error:
        raise PipelineError("food-catalog current-generation pointer is missing") from error
    if (
        not generation.is_dir()
        or generation.parent != root
        or not generation.name.startswith(".food-catalog-stage-")
    ):
        raise PipelineError("food-catalog current-generation pointer targets an invalid directory")
    return generation / "FoodCatalog.sqlite", generation / "validation-report.json"


def _new_staging_directory(output_dir: Path) -> Path:
    path = tempfile.mkdtemp(prefix=".food-catalog-stage-", dir=output_dir)
    return Path(path)


def _remove_staging_directory(output_dir: Path, staging: Path) -> None:
    resolved_root = output_dir.resolve()
    resolved_stage = staging.resolve()
    if resolved_stage.parent != resolved_root or not staging.name.startswith(".food-catalog-stage-"):
        raise PipelineError("refusing to remove an invalid food-catalog staging directory")
    shutil.rmtree(staging)


def _write_staged_report(path: Path, report: dict) -> None:
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if len(payload.encode("utf-8")) > MAX_EVIDENCE_BYTES:
        raise PipelineError(f"validation report exceeds {MAX_EVIDENCE_BYTES} bytes")
    with path.open("w", encoding="utf-8") as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _generation_id(database: Path) -> str:
    return f"sha256:{sha256_file(database)}"


def _validate_staged_pair(database: Path, report_path: Path) -> None:
    _bounded_file_size(database, MAX_ARCHIVE_TOTAL_BYTES, "staged catalog")
    report = load_evidence(report_path)
    output_hash = sha256_file(database)
    if report.get("generation_id") != f"sha256:{output_hash}":
        raise PipelineError("staged report generation ID differs from staged database")
    if report.get("output_sha256") != output_hash:
        raise PipelineError("staged report catalog hash differs from staged database")
    if report.get("output_bytes") != database.stat().st_size:
        raise PipelineError("staged report catalog byte count differs from staged database")


def _retire_staged_generations(output_dir: Path, current_generation: Path) -> None:
    """Bound retained output without allowing housekeeping to invalidate a publish."""
    generations = sorted(
        (
            path for path in output_dir.iterdir()
            if path.is_dir() and path.name.startswith(".food-catalog-stage-")
        ),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )
    retained = {current_generation.resolve()}
    for generation in generations:
        resolved_generation = generation.resolve()
        if len(retained) >= MAX_RETAINED_GENERATIONS:
            break
        retained.add(resolved_generation)
    for generation in generations:
        if generation.resolve() in retained:
            continue
        try:
            _remove_staging_directory(output_dir, generation)
        except OSError:
            # The durable current pair is already committed; retry cleanup on a later publish.
            continue


def publish_staged_generation(output_dir: Path, staging: Path, failure_point: str | None = None) -> None:
    database = staging / "FoodCatalog.sqlite"
    report = staging / "validation-report.json"
    _validate_staged_pair(database, report)
    _fsync_file(database)
    _fsync_file(report)
    _fsync_directory(staging)
    if failure_point == "after_staged_report":
        raise PipelineError("injected failure after staged report creation")
    if failure_point == "before_pointer_swap":
        raise PipelineError("injected failure before current-generation pointer swap")
    current = output_dir / "current"
    replacement = output_dir / f".current-{staging.name}"
    if replacement.exists() or replacement.is_symlink():
        raise PipelineError("replacement current-generation pointer already exists")
    os.symlink(staging.name, replacement)
    try:
        _fsync_directory(output_dir)
        os.replace(replacement, current)
    except OSError:
        if replacement.exists() or replacement.is_symlink():
            replacement.unlink()
        raise
    try:
        _fsync_directory(output_dir)
    except OSError as error:
        raise PublishedGenerationError(
            "current-generation pointer changed but its directory fsync failed"
        ) from error
    _retire_staged_generations(output_dir, staging)


def _verify_all_inputs(manifest: dict, paths: dict[str, Path]) -> None:
    required = {
        "usda_fdc_consumer", "usda_fndds_ingredients", "usda_survey_validation",
        "usda_sr_validation", "usda_branded_curated", "uk_cofid",
    }
    if set(paths) != required:
        raise PipelineError(f"input key set differs from required authorized set: {sorted(set(paths))}")
    for key in sorted(required):
        entry = source_entry(manifest, key)
        if entry.get("enabled") is not True:
            raise PipelineError(f"required input is not enabled in manifest: {key}")
        verify_input(paths[key], entry)


def _validate_fdc_archive(archive: zipfile.ZipFile, member_hashes: dict[str, str]) -> None:
    _validate_zip_archive(
        archive, "FDC archive", MAX_ARCHIVE_MEMBERS, MAX_ARCHIVE_MEMBER_BYTES,
        MAX_ARCHIVE_TOTAL_BYTES, MAX_ARCHIVE_COMPRESSION_RATIO,
    )
    names = archive.namelist()
    required = {
        "food.csv", "survey_fndds_food.csv", "sr_legacy_food.csv", "foundation_food.csv",
        "food_category.csv", "wweia_food_category.csv", "measure_unit.csv", "nutrient.csv",
        "food_nutrient.csv", "food_portion.csv", "input_food.csv", "branded_food.csv",
        "fndds_ingredient_nutrient_value.csv",
    }
    missing = sorted(FDC_PREFIX + name for name in required if FDC_PREFIX + name not in names)
    if missing:
        raise PipelineError(f"FDC archive schema signature missing members: {missing}")
    if set(member_hashes) != {"food.csv", "branded_food.csv", "food_nutrient.csv", "food_portion.csv"}:
        raise PipelineError("FDC member-hash contract differs from required preservation members")
    for member_name, expected_hash in sorted(member_hashes.items()):
        digest = hashlib.sha256()
        with archive.open(FDC_PREFIX + member_name) as source:
            for block in iter(lambda: source.read(1_048_576), b""):
                digest.update(block)
        if digest.hexdigest() != expected_hash:
            raise PipelineError(f"FDC member SHA-256 mismatch: {member_name}")


def build_catalog(
    manifest_path: Path,
    fdc_zip: Path,
    fndds_xlsx: Path,
    survey_json: Path,
    sr_json: Path,
    branded_curated_json: Path,
    cofid_xlsx: Path,
    output_dir: Path,
    committed_catalog: Path,
    failure_point: str | None = None,
) -> dict:
    manifest = load_manifest(manifest_path)
    paths = {
        "usda_fdc_consumer": fdc_zip,
        "usda_fndds_ingredients": fndds_xlsx,
        "usda_survey_validation": survey_json,
        "usda_sr_validation": sr_json,
        "usda_branded_curated": branded_curated_json,
        "uk_cofid": cofid_xlsx,
    }
    _verify_all_inputs(manifest, paths)
    output_dir = _validate_output_location(output_dir, committed_catalog)
    branded_entry = source_entry(manifest, "usda_branded_curated")
    shipping_uuids = load_shipping_uuid_map(committed_catalog, branded_entry["expected"])
    fndds_entry = source_entry(manifest, "usda_fndds_ingredients")
    fndds_relations, fndds_dishes, fndds_stats = load_fndds_workbook(fndds_xlsx, fndds_entry["expected"])
    staging = _new_staging_directory(output_dir)
    database = staging / "FoodCatalog.sqlite"
    report_path = staging / "validation-report.json"
    published = False
    connection: sqlite3.Connection | None = None
    connection_is_open = False
    stats: dict[str, object] = {
        "fndds_workbook": fndds_stats,
        "input_contract": input_contract(manifest),
    }
    try:
        connection = create_database(database)
        connection_is_open = True
        insert_source_manifest(connection, manifest, paths)
        with zipfile.ZipFile(fdc_zip) as archive:
            fdc_entry = source_entry(manifest, "usda_fdc_consumer")
            _validate_fdc_archive(archive, fdc_entry["provenance"]["memberSHA256"])
            metadata, survey_code_to_fdc = _load_fdc_subtypes(archive, fdc_entry["expected"])
            food_categories, wweia_categories, measure_units = _load_category_maps(archive)
            fdc_rows = _load_fdc_food_rows(archive, metadata, food_categories, wweia_categories, fdc_entry["expected"])
            fdc_to_food, fdc_details = _insert_fdc_foods(connection, fdc_rows, fdc_entry["version"])
            fndds_dish_count = _insert_fndds_dishes(
                connection, fndds_dishes, survey_code_to_fdc, fdc_details
            )
            nutrient_count = _load_fdc_nutrients(connection, archive, fdc_to_food)
            portion_count, fdc_portions = _load_fdc_portions(connection, archive, fdc_to_food, measure_units)
            ingredient_count, survey_relations = _load_fdc_ingredients(
                connection, archive, fdc_to_food, fdc_details, fndds_relations
            )
            ingredient_nutrient_count = _load_fndds_ingredient_nutrients(connection, archive)
        stats["fdc"] = {
            "foods": len(fdc_to_food), "nutrient_values": nutrient_count,
            "portions": portion_count, "ingredient_relations": ingredient_count,
            "ingredient_nutrient_values": ingredient_nutrient_count, "fndds_dishes": fndds_dish_count,
        }
        stats["survey_validation"] = validate_survey_fixture(
            survey_json, source_entry(manifest, "usda_survey_validation")["expected"],
            fdc_details, survey_code_to_fdc, survey_relations, fndds_relations, fdc_portions,
        )
        stats["sr_validation"] = validate_sr_fixture(
            sr_json, source_entry(manifest, "usda_sr_validation")["expected"], fdc_details
        )
        stats["branded_curated"] = load_curated_branded(
            connection, branded_curated_json, branded_entry["expected"], branded_entry["version"],
            shipping_uuids,
        )
        with zipfile.ZipFile(fdc_zip) as archive:
            stats["branded_full_fdc"] = enrich_curated_branded(
                connection, archive, branded_entry["expected"], shipping_uuids, measure_units
            )
        cofid_entry = source_entry(manifest, "uk_cofid")
        cofid_records, duplicate_codes = _load_cofid_base(cofid_xlsx, cofid_entry["expected"])
        cofid_identities, factor_count = _insert_cofid_foods(
            connection, cofid_records, duplicate_codes, cofid_entry["version"]
        )
        cofid_stats = _load_cofid_nutrients(connection, cofid_xlsx, cofid_identities)
        stats["cofid"] = {"foods": len(cofid_identities), "factors": factor_count, **cofid_stats}
        stats["compatibility_rows"] = populate_compatibility(connection)
        stats["fts_rows"] = populate_fts(connection)
        _evidence(connection, stats)
        _evidence(connection, {"table_content_sha256": table_content_hashes(connection)})
        connection.commit()
        connection.execute("VACUUM")
        connection.close()
        connection_is_open = False
    except (OSError, sqlite3.Error, XLSXError, PipelineError, ValueError) as error:
        if connection_is_open and connection is not None:
            connection.rollback()
            connection.close()
        if not published and staging.exists():
            _remove_staging_directory(output_dir, staging)
        if isinstance(error, PipelineError):
            raise
        raise PipelineError(f"catalog build failed: {error}") from error
    try:
        validation = validate_database(database, manifest, shipping_uuids)
        output_hash = sha256_file(database)
        report = {
            "schema_version": SCHEMA_VERSION,
            "generation_id": f"sha256:{output_hash}",
            "canonical_usda_release": manifest["canonicalUSDARelease"],
            "output_filename": database.name,
            "output_bytes": database.stat().st_size,
            "output_sha256": output_hash,
            "build_stats": stats,
            "validation": validation,
            "committed_catalog_touched": False,
            "excluded_sources": [entry["key"] for entry in manifest["sources"] if not entry["enabled"]],
        }
        _write_staged_report(report_path, report)
        _validate_staged_pair(database, report_path)
        publish_staged_generation(output_dir, staging, failure_point)
        published = True
        return report
    except PublishedGenerationError:
        published = True
        raise
    except (OSError, sqlite3.Error, XLSXError, PipelineError, ValueError) as error:
        if not published and staging.exists():
            _remove_staging_directory(output_dir, staging)
        if isinstance(error, PipelineError):
            raise
        raise PipelineError(f"catalog publication failed: {error}") from error

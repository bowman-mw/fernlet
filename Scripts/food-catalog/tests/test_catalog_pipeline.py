#!/usr/bin/env python3
"""Fast contract tests for the data-only food catalog generator."""

from __future__ import annotations

from decimal import Decimal
import csv
from collections import Counter
import hashlib
import io
from pathlib import Path
import json
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile


SCRIPT_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import catalog_pipeline  # noqa: E402
import xlsx_stream  # noqa: E402
from catalog_pipeline import (  # noqa: E402
    PipelineError,
    cofid_stable_id,
    create_database,
    enrich_curated_branded,
    excel_numeric_text,
    iter_json_array,
    legacy_integer,
    load_curated_branded,
    load_manifest,
    load_shipping_uuid_map,
    normalize_text,
    sha256_file,
    significant_round,
    value_status,
)


class CatalogPipelineTests(unittest.TestCase):
    def test_normalization_is_locale_independent_and_diacritic_insensitive(self) -> None:
        self.assertEqual(normalize_text("  CRÈME—Brûlée  "), "creme brulee")
        self.assertEqual(normalize_text("McDonald's"), "mcdonald s")

    def test_source_sentinels_remain_distinct_from_numeric_zero(self) -> None:
        self.assertEqual(value_status("0"), "numeric")
        self.assertEqual(value_status("Tr"), "trace")
        self.assertEqual(value_status("N"), "present_unknown")
        self.assertEqual(value_status("(0.07)"), "parenthesized_numeric")
        self.assertEqual(value_status(None), "missing")
        with self.assertRaises(PipelineError):
            value_status("not measured")

    def test_legacy_rounding_is_explicit_and_unknowns_stay_null(self) -> None:
        self.assertEqual(legacy_integer("2.5", "numeric"), 3)
        self.assertIsNone(legacy_integer("Tr", "trace"))
        self.assertIsNone(legacy_integer(None, "missing"))

    def test_survey_fixture_precision_rule_is_three_significant_half_even(self) -> None:
        self.assertEqual(significant_round(Decimal("20.25")), Decimal("20.2"))
        self.assertEqual(significant_round(Decimal("1.125")), Decimal("1.12"))
        self.assertEqual(significant_round(Decimal("1025")), Decimal("1.02E+3"))

    def test_excel_binary_tail_is_canonicalized_to_fifteen_significant_digits(self) -> None:
        self.assertEqual(excel_numeric_text("42.661999999999999"), "42.662")

    def test_fndds_workbook_keeps_raw_dish_category_and_numeric_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fndds.xlsx"
            with zipfile.ZipFile(path, "w"):
                pass
            rows = iter([
                (1, ["2021-2023 Food and Nutrient Database"]),
                (2, list(catalog_pipeline.FNDDS_HEADERS)),
                (3, ["11111111", "Fixture dish", "99", "Fixture WWEIA", "1", "22222222",
                     "Fixture ingredient", "42.661999999999999", "1", "5.500000000000001"]),
            ])
            with patch.object(catalog_pipeline, "workbook_sheets", return_value=[
                SimpleNamespace(name="FNDDS Ingredients"), SimpleNamespace(name="Variable Descriptions"),
            ]), patch.object(catalog_pipeline, "iter_sheet_rows", return_value=rows):
                relations, dishes, stats = catalog_pipeline.load_fndds_workbook(path, {
                    "ingredientRows": 1, "dishes": 1, "ingredientCodes": 1,
                })
        relation = relations[("11111111", "1")]
        self.assertEqual(relation["ingredient_weight_raw"], "42.661999999999999")
        self.assertEqual(relation["ingredient_weight"], "42.662")
        self.assertEqual(dishes["11111111"]["category_description"], "Fixture WWEIA")
        self.assertEqual(dishes["11111111"]["moisture_raw"], "5.500000000000001")
        self.assertEqual(stats["moisture_foods"], 1)

    def test_cofid_duplicate_code_gets_deterministic_composite_identity(self) -> None:
        duplicates = {"13-669"}
        aubergine = cofid_stable_id("13-669", "Aubergine", "roasted", duplicates)
        watercress = cofid_stable_id("13-669", "Watercress", "raw", duplicates)
        self.assertNotEqual(aubergine, watercress)
        self.assertEqual(aubergine, cofid_stable_id("13-669", "Aubergine", "roasted", duplicates))
        self.assertEqual(cofid_stable_id("13-145", "Ackee", "", duplicates), "uk_cofid:13-145")

    def test_json_fixture_parser_is_streaming_and_preserves_decimal_text(self) -> None:
        payload = {"Rows": [{"id": index, "amount": 1.125} for index in range(25)]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            rows = list(iter_json_array(path, "Rows"))
        self.assertEqual(len(rows), 25)
        self.assertEqual(rows[0]["amount"], Decimal("1.125"))

    def test_source_manifest_has_pinned_hashes_and_strict_enabled_set(self) -> None:
        manifest = load_manifest(REPOSITORY_ROOT / "FoodDataSource/FoodCatalogSourceManifest.json")
        sources = manifest["sources"]
        self.assertTrue(all(len(source["sha256"]) == 64 for source in sources))
        enabled = {source["key"] for source in sources if source["enabled"]}
        self.assertEqual(enabled, {
            "usda_fdc_consumer", "usda_fndds_ingredients", "usda_survey_validation",
            "usda_sr_validation", "usda_branded_curated", "uk_cofid",
        })
        fdc = next(source for source in sources if source["key"] == "usda_fdc_consumer")
        self.assertEqual(fdc["includeDataTypes"], ["Survey (FNDDS)", "SR Legacy", "Foundation"])
        contract = manifest["outputContract"]
        self.assertEqual(contract["tableCounts"]["branded_fdc_record"], 240_311)
        self.assertEqual(contract["tableCounts"]["branded_fdc_nutrient"], 3_428_087)
        survey = next(source for source in sources if source["key"] == "usda_survey_validation")
        drift = survey["expected"]["legacyPortionParentDriftTopology"]
        self.assertEqual((drift["canonicalFdcID"], len(drift["fixtureFdcIDs"]), drift["portionIDs"]), (
            "2710777", 37, ["312548", "312549", "312550", "312551"],
        ))

    def test_generation_evidence_matches_preservation_contract(self) -> None:
        path = REPOSITORY_ROOT / "FoodDataSource/FoodCatalogGenerationEvidence.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(evidence["output"]["foods"], 66_581)
        self.assertEqual(evidence["output"]["fnddsIngredientRelations"], 18_584)
        self.assertEqual(evidence["preservationChecks"]["cofidTraceValues"], 30_225)
        self.assertEqual(evidence["validationFixtures"]["surveyLegacyPortionParentAssociationDrifts"], 148)
        guard = evidence["committedCatalogGuard"]
        self.assertEqual(guard["sha256Before"], guard["sha256After"])
        self.assertFalse(guard["touched"])

    def test_full_fdc_enrichment_preserves_duplicate_records_and_legacy_exception(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            committed = self._write_committed_catalog(root)
            expected = self._branded_expected(committed)
            shipping = load_shipping_uuid_map(committed, expected)
            curated = self._write_curated_fixture(root)
            archive = self._write_fdc_fixture(root)
            output = root / "preservation.sqlite"
            connection = create_database(output)
            self._insert_test_sources(connection)
            load_curated_branded(connection, curated, expected, "fixture", shipping)
            with zipfile.ZipFile(archive) as source:
                stats = enrich_curated_branded(connection, source, expected, shipping, {"9999": "serving"})
            connection.commit()
            compatibility = connection.execute(
                "SELECT gtin_upc,shipping_uuid,enrichment_status,full_fdc_record_count FROM branded_compatibility ORDER BY gtin_upc"
            ).fetchall()
            self.assertEqual(stats["full_fdc_records"], 2)
            self.assertEqual(stats["legacy_exceptions"], ["00070074649214"])
            self.assertEqual(compatibility[0][1], "UUID-ENRICHED")
            self.assertEqual(compatibility[0][2:], ("enriched", 2))
            self.assertEqual(compatibility[1][1], "UUID-LEGACY")
            self.assertEqual(compatibility[1][2:], ("legacy_missing_from_pinned_full_fdc", 0))
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM branded_fdc_record").fetchone()[0], 2)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM branded_fdc_nutrient").fetchone()[0], 2)
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM branded_fdc_portion").fetchone()[0], 2)
            ingredient_text = connection.execute(
                "SELECT ingredients FROM branded_fdc_record WHERE fdc_id='100'"
            ).fetchone()[0]
            connection.close()
            self.assertEqual(ingredient_text, "WATER, COCOA")

    def test_unapproved_missing_full_fdc_gtin_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            committed = self._write_committed_catalog(root)
            expected = self._branded_expected(committed)
            expected["legacyFullFdcExceptions"] = []
            shipping = load_shipping_uuid_map(committed, expected)
            connection = create_database(root / "preservation.sqlite")
            self._insert_test_sources(connection)
            load_curated_branded(connection, self._write_curated_fixture(root), expected, "fixture", shipping)
            with zipfile.ZipFile(self._write_fdc_fixture(root)) as source:
                with self.assertRaisesRegex(PipelineError, "approved exceptions"):
                    enrich_curated_branded(connection, source, expected, shipping, {"9999": "serving"})
            connection.close()

    def test_cofid_preserves_distinct_food_basis(self) -> None:
        self.assertEqual(catalog_pipeline._cofid_food_basis("QA"), "per_100ml_alcoholic_beverage")
        self.assertEqual(catalog_pipeline._cofid_food_basis("PCA"), "per_100g_food")
        self.assertEqual(catalog_pipeline._cofid_basis("1.3 Proximates", "per_100ml_alcoholic_beverage"), "per_100ml_alcoholic_beverage")
        self.assertEqual(catalog_pipeline._cofid_basis("1.7 (SFA per 100gFA)", "per_100ml_alcoholic_beverage"), "per_100g_fatty_acids")

    def test_exact_validator_rejects_independent_contract_mutations(self) -> None:
        mutations = {
            "gtin mapping": ("UPDATE branded_compatibility SET gtin_upc='00000000000002'", "branded compatibility parent"),
            "FDC ID": ("UPDATE branded_fdc_record SET fdc_id='fixture-fdc-mutated'", "foreign_key_check"),
            "shipping UUID": ("UPDATE branded_compatibility SET shipping_uuid='UUID-MUTATED'", "branded compatibility parent"),
            "source field": ("UPDATE source_manifest SET publisher='Mutated' WHERE source_key='uk_cofid'", "stored source-manifest row"),
            "FNDDS raw numeric": ("UPDATE food_ingredient SET workbook_ingredient_weight_raw='9'", "FNDDS raw numeric"),
            "CoFID basis": ("UPDATE nutrient_value SET basis='per_100g_food' WHERE source_value_id='cofid-q'", "exact output table/source/status/basis"),
            "CoFID sentinel": ("UPDATE nutrient_value SET amount_text='N' WHERE source_value_id='cofid-q'", "nutrient raw value status"),
            "evidence hash": ("UPDATE validation_evidence SET evidence_value='{}' WHERE evidence_key='input_contract'", "database manifest or input hash"),
            "raw branded nutrient": ("UPDATE branded_fdc_nutrient SET amount_text='9.9'", "table content hash"),
            "table count": ("DELETE FROM food_factor", "exact output table/source/status/basis"),
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label, (mutation, expected_error) in mutations.items():
                with self.subTest(label=label):
                    database, manifest, shipping_uuids = self._write_validated_fixture(root, label)
                    connection = sqlite3.connect(database)
                    connection.execute(mutation)
                    connection.commit()
                    connection.close()
                    with self.assertRaisesRegex(PipelineError, expected_error):
                        catalog_pipeline.validate_database(database, manifest, shipping_uuids)

    def test_exact_validator_requires_exact_fts_row_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database, manifest, shipping_uuids = self._write_validated_fixture(Path(directory), "fts")
            connection = sqlite3.connect(database)
            connection.execute("INSERT INTO food_fts(rowid,display_name,normalized_name,brand_source,ingredient_text,category) VALUES (999,'extra','extra','','','')")
            connection.commit()
            connection.close()
            with self.assertRaisesRegex(PipelineError, "FTS row-ID set differs"):
                catalog_pipeline.validate_database(database, manifest, shipping_uuids)

    def test_evidence_and_fndds_drift_contracts_fail_closed(self) -> None:
        manifest = self._validation_manifest()
        evidence = {"catalogSchemaVersion": catalog_pipeline.SCHEMA_VERSION, "inputContract": catalog_pipeline.input_contract(manifest)}
        catalog_pipeline.validate_evidence_contract(evidence, manifest)
        evidence["inputContract"]["inputSHA256"]["uk_cofid"] = "mutated"
        with self.assertRaisesRegex(PipelineError, "evidence manifest or input hash"):
            catalog_pipeline.validate_evidence_contract(evidence, manifest)
        expected = {"legacyPortionParentDriftTopology": {"canonicalFdcID": "canonical", "fixtureFdcIDs": ["fixture"], "portionIDs": ["portion"]}}
        catalog_pipeline._validate_survey_portion_drift_topology(expected, Counter({("portion", "fixture", "canonical"): 1}))
        with self.assertRaisesRegex(PipelineError, "portion-drift topology"):
            catalog_pipeline._validate_survey_portion_drift_topology(expected, Counter({("portion", "other", "canonical"): 1}))

    def test_fdc_member_hash_contract_rejects_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "fdc.zip"
            required = {
                "food.csv", "survey_fndds_food.csv", "sr_legacy_food.csv", "foundation_food.csv",
                "food_category.csv", "wweia_food_category.csv", "measure_unit.csv", "nutrient.csv",
                "food_nutrient.csv", "food_portion.csv", "input_food.csv", "branded_food.csv",
                "fndds_ingredient_nutrient_value.csv",
            }
            payloads = {name: f"fixture:{name}".encode("utf-8") for name in required}
            with zipfile.ZipFile(archive_path, "w") as archive:
                for name, payload in payloads.items():
                    archive.writestr(catalog_pipeline.FDC_PREFIX + name, payload)
            hashes = {name: hashlib.sha256(payloads[name]).hexdigest() for name in (
                "food.csv", "branded_food.csv", "food_nutrient.csv", "food_portion.csv",
            )}
            with zipfile.ZipFile(archive_path) as archive:
                catalog_pipeline._validate_fdc_archive(archive, hashes)
            hashes["food.csv"] = "0" * 64
            with zipfile.ZipFile(archive_path) as archive:
                with self.assertRaisesRegex(PipelineError, "member SHA-256"):
                    catalog_pipeline._validate_fdc_archive(archive, hashes)

    def test_bounded_inputs_reject_oversized_records_before_generation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}", encoding="utf-8")
            with patch.object(catalog_pipeline, "MAX_MANIFEST_BYTES", 1):
                with self.assertRaisesRegex(PipelineError, "manifest size outside"):
                    load_manifest(manifest_path)

            evidence_path = root / "evidence.json"
            evidence_path.write_text("{}", encoding="utf-8")
            with patch.object(catalog_pipeline, "MAX_EVIDENCE_BYTES", 1):
                with self.assertRaisesRegex(PipelineError, "evidence size outside"):
                    catalog_pipeline.load_evidence(evidence_path)

            reader = catalog_pipeline._BoundedDictReader(io.StringIO("field\nlong-value\n"), "rows.csv")
            with patch.object(catalog_pipeline, "MAX_CSV_CELL_BYTES", 4):
                with self.assertRaisesRegex(PipelineError, "cell exceeds"):
                    next(reader)

            large_value = "x" * 150_000
            large_reader = catalog_pipeline._BoundedDictReader(
                io.StringIO(f"field\n{large_value}\n"), "large.csv"
            )
            self.assertEqual(next(large_reader)["field"], large_value)
            oversized_reader = catalog_pipeline._BoundedDictReader(
                io.StringIO(f"field\n{'x' * (catalog_pipeline.MAX_CSV_CELL_BYTES + 1)}\n"), "oversized.csv"
            )
            with self.assertRaisesRegex(PipelineError, "CSV row parse failed"):
                next(oversized_reader)

            record_reader = catalog_pipeline._BoundedDictReader(io.StringIO("field\none\ntwo\n"), "records.csv")
            with patch.object(catalog_pipeline, "MAX_CSV_RECORDS", 1):
                self.assertEqual(next(record_reader)["field"], "one")
                with self.assertRaisesRegex(PipelineError, "record count exceeds"):
                    next(record_reader)

            archive_path = root / "bounded.zip"
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("one.csv", b"x" * 100)
                archive.writestr("two.csv", b"y")
            with zipfile.ZipFile(archive_path) as archive:
                with self.assertRaisesRegex(PipelineError, "member count"):
                    catalog_pipeline._validate_zip_archive(archive, "fixture", 1, 1_000, 2_000, 128)
                with self.assertRaisesRegex(PipelineError, "compression ratio"):
                    catalog_pipeline._validate_zip_archive(archive, "fixture", 3, 1_000, 2_000, 1)

            fixture_path = root / "fixture.json"
            fixture_path.write_text('{"Rows":[{"a":{"b":"value"}}]}', encoding="utf-8")
            with patch.object(catalog_pipeline, "MAX_JSON_DEPTH", 1):
                with self.assertRaisesRegex(PipelineError, "JSON nesting"):
                    list(iter_json_array(fixture_path, "Rows"))

            workbook_path = root / "strings.xlsx"
            with zipfile.ZipFile(workbook_path, "w") as archive:
                archive.writestr(
                    "xl/sharedStrings.xml",
                    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>long value</t></si></sst>',
                )
            with zipfile.ZipFile(workbook_path) as archive:
                with patch.object(xlsx_stream, "MAX_CELL_TEXT_BYTES", 4):
                    with self.assertRaisesRegex(xlsx_stream.XLSXError, "shared string exceeds"):
                        xlsx_stream._shared_strings(archive)

    def test_bounded_sql_batches_and_raw_branded_record_cap(self) -> None:
        calls: list[list[tuple[int]]] = []

        class RecordingConnection:
            def executemany(self, sql: str, rows) -> None:
                calls.append(list(rows))

        with patch.object(catalog_pipeline, "MAX_SQL_BATCH_ROWS", 2):
            count = catalog_pipeline.bounded_executemany(
                RecordingConnection(), "INSERT fixture", [(1,), (2,), (3,)]
            )
        self.assertEqual((count, [len(batch) for batch in calls]), (3, [2, 1]))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            committed = self._write_committed_catalog(root)
            expected = self._branded_expected(committed)
            shipping = load_shipping_uuid_map(committed, expected)
            connection = create_database(root / "preservation.sqlite")
            self._insert_test_sources(connection)
            load_curated_branded(connection, self._write_curated_fixture(root), expected, "fixture", shipping)
            with zipfile.ZipFile(self._write_fdc_fixture(root)) as source:
                with patch.object(catalog_pipeline, "MAX_BRANDED_FDC_RECORDS", 1):
                    with self.assertRaisesRegex(PipelineError, "record cap"):
                        enrich_curated_branded(connection, source, expected, shipping, {"9999": "serving"})
            connection.close()

    def test_staged_publication_failure_injection_preserves_previous_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_dir = root / ".food-catalog-build"
            output_dir.mkdir()
            old_stage = self._write_staged_generation(output_dir, b"old catalog", "old")
            catalog_pipeline.publish_staged_generation(output_dir, old_stage)
            old_catalog, old_report = catalog_pipeline.published_paths(output_dir)
            expected_old = (old_catalog.read_bytes(), old_report.read_bytes())
            old_pointer = (output_dir / "current").readlink()

            build_manifest = {
                "sources": [
                    {"key": "usda_branded_curated", "expected": {}, "sha256": "0" * 64},
                    {"key": "usda_fndds_ingredients", "expected": {}, "sha256": "1" * 64},
                ],
            }
            with patch.object(catalog_pipeline, "load_manifest", return_value=build_manifest), \
                 patch.object(catalog_pipeline, "_verify_all_inputs"), \
                 patch.object(catalog_pipeline, "load_shipping_uuid_map", return_value={}), \
                 patch.object(catalog_pipeline, "load_fndds_workbook", return_value=({}, {}, {})), \
                 patch.object(catalog_pipeline, "create_database", side_effect=sqlite3.Error("injected database failure")):
                with self.assertRaisesRegex(PipelineError, "catalog build failed: injected database failure"):
                    catalog_pipeline.build_catalog(
                        manifest_path=root / "manifest.json",
                        fdc_zip=root / "fdc.zip",
                        fndds_xlsx=root / "fndds.xlsx",
                        survey_json=root / "survey.json",
                        sr_json=root / "sr.json",
                        branded_curated_json=root / "branded.json",
                        cofid_xlsx=root / "cofid.xlsx",
                        output_dir=output_dir,
                        committed_catalog=root / "shipping" / "committed.sqlite",
                    )
            current_catalog, current_report = catalog_pipeline.published_paths(output_dir)
            self.assertEqual((current_catalog.read_bytes(), current_report.read_bytes()), expected_old)
            self.assertEqual((output_dir / "current").readlink(), old_pointer)

            failed_stage = self._write_staged_generation(output_dir, b"new catalog", "failed")
            with self.assertRaisesRegex(PipelineError, "injected failure"):
                catalog_pipeline.publish_staged_generation(output_dir, failed_stage, "before_pointer_swap")
            current_catalog, current_report = catalog_pipeline.published_paths(output_dir)
            self.assertEqual((current_catalog.read_bytes(), current_report.read_bytes()), expected_old)
            self.assertEqual((output_dir / "current").readlink(), old_pointer)
            catalog_pipeline._remove_staging_directory(output_dir, failed_stage)

            report_failure_stage = catalog_pipeline._new_staging_directory(output_dir)
            (report_failure_stage / "FoodCatalog.sqlite").write_bytes(b"unreported catalog")
            with self.assertRaises(FileNotFoundError):
                catalog_pipeline.publish_staged_generation(output_dir, report_failure_stage)
            current_catalog, current_report = catalog_pipeline.published_paths(output_dir)
            self.assertEqual((current_catalog.read_bytes(), current_report.read_bytes()), expected_old)
            catalog_pipeline._remove_staging_directory(output_dir, report_failure_stage)

            after_report_stage = self._write_staged_generation(output_dir, b"after report", "after-report")
            with self.assertRaisesRegex(PipelineError, "after staged report creation"):
                catalog_pipeline.publish_staged_generation(output_dir, after_report_stage, "after_staged_report")
            current_catalog, current_report = catalog_pipeline.published_paths(output_dir)
            self.assertEqual((current_catalog.read_bytes(), current_report.read_bytes()), expected_old)
            catalog_pipeline._remove_staging_directory(output_dir, after_report_stage)

            new_stage = self._write_staged_generation(output_dir, b"new catalog", "new")
            catalog_pipeline.publish_staged_generation(output_dir, new_stage)
            current_catalog, current_report = catalog_pipeline.published_paths(output_dir)
            self.assertEqual(current_catalog.read_bytes(), b"new catalog")
            self.assertIn('"generation_id": "sha256:', current_report.read_text(encoding="utf-8"))
            self.assertEqual(str((output_dir / "current").readlink()), new_stage.name)
            self.assertEqual((old_catalog.read_bytes(), old_report.read_bytes()), expected_old)

    def test_publication_retains_at_most_current_and_one_prior_generation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory) / ".food-catalog-build"
            output_dir.mkdir()
            first = self._write_staged_generation(output_dir, b"first", "first")
            catalog_pipeline.publish_staged_generation(output_dir, first)
            second = self._write_staged_generation(output_dir, b"second", "second")
            catalog_pipeline.publish_staged_generation(output_dir, second)
            third = self._write_staged_generation(output_dir, b"third", "third")
            catalog_pipeline.publish_staged_generation(output_dir, third)
            stages = sorted(output_dir.glob(".food-catalog-stage-*"))
            self.assertEqual(len(stages), catalog_pipeline.MAX_RETAINED_GENERATIONS)
            self.assertFalse(first.exists())
            self.assertTrue(second.exists())
            self.assertTrue(third.exists())

    def test_output_location_accepts_resolved_system_temporary_roots(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_dir = root / "isolated-output"
            committed_catalog = root / "shipping" / "FoodCatalog.sqlite"
            with patch.object(catalog_pipeline.tempfile, "gettempdir", return_value=str(root)):
                self.assertEqual(
                    catalog_pipeline._validate_output_location(output_dir, committed_catalog),
                    output_dir.resolve(),
                )

    def _write_staged_generation(self, output_dir: Path, catalog_bytes: bytes, label: str) -> Path:
        stage = catalog_pipeline._new_staging_directory(output_dir)
        database = stage / "FoodCatalog.sqlite"
        database.write_bytes(catalog_bytes)
        report = {
            "schema_version": catalog_pipeline.SCHEMA_VERSION,
            "generation_id": f"sha256:{hashlib.sha256(catalog_bytes).hexdigest()}",
            "output_filename": database.name,
            "output_bytes": len(catalog_bytes),
            "output_sha256": hashlib.sha256(catalog_bytes).hexdigest(),
            "build_stats": {"label": label},
        }
        catalog_pipeline._write_staged_report(stage / "validation-report.json", report)
        return stage

    def _validation_manifest(self) -> dict:
        def source(key: str, expected: dict) -> dict:
            return {
                "key": key, "enabled": True, "role": "fixture", "version": "fixture",
                "releaseDate": "2026-01-01", "acceptedFilenames": [f"{key}.fixture"],
                "bytes": 1, "sha256": hashlib.sha256(key.encode("utf-8")).hexdigest(),
                "license": "fixture", "licenseURL": "https://example.invalid", "publisher": "Fixture",
                "attribution": "Fixture", "expected": expected,
            }
        return {
            "manifestVersion": 1,
            "catalogSchemaVersion": catalog_pipeline.SCHEMA_VERSION,
            "sources": [
                source("usda_fdc_consumer", {"Survey (FNDDS)": 1, "SR Legacy": 1, "Foundation": 1}),
                source("usda_branded_curated", {"foods": 1, "legacyFullFdcExceptions": []}),
                source("uk_cofid", {"foods": 2, "duplicateSourceCodes": ["13-669"]}),
            ],
            "outputContract": {},
        }

    def _write_validated_fixture(self, root: Path, name: str) -> tuple[Path, dict, dict[str, str]]:
        manifest = self._validation_manifest()
        database = root / f"{name}.sqlite"
        connection = create_database(database)
        catalog_pipeline.insert_source_manifest(connection, manifest, {})
        food_sql = """
            INSERT INTO food (
                stable_id,source_key,source_version,source_id,source_code,legacy_uuid,
                display_name,normalized_name,description,category_code,category_name,data_type,
                brand_source,gtin_upc,source_references,publication_date,start_date,end_date
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        foods = [
            ("usda_fdc:survey", "usda_fdc_consumer", "fixture", "survey", "survey", "UUID-SURVEY", "Survey", "survey", None, "W", "WWEIA", "Survey (FNDDS)", None, None, None, None, None, None),
            ("usda_fdc:sr", "usda_fdc_consumer", "fixture", "sr", "sr", "UUID-SR", "SR", "sr", None, "", "SR", "SR Legacy", None, None, None, None, None, None),
            ("usda_fdc:foundation", "usda_fdc_consumer", "fixture", "foundation", "foundation", "UUID-FOUNDATION", "Foundation", "foundation", None, "", "Foundation", "Foundation", None, None, None, None, None, None),
            ("usda_branded_curated:00000000000001", "usda_branded_curated", "fixture", "00000000000001", "00000000000001", "UUID-BRANDED", "Branded", "branded", None, "", "Branded", "branded", "Fixture", "00000000000001", None, None, None, None),
            ("uk_cofid:13-669#a", "uk_cofid", "fixture", "13-669#a", "13-669", "UUID-COFID-A", "Aubergine, flesh and skin, roasted in rapeseed oil", "aubergine", None, "P", "P", "cofid", None, None, None, None, None, None),
            ("uk_cofid:13-669#b", "uk_cofid", "fixture", "13-669#b", "13-669", "UUID-COFID-B", "Watercress, raw", "watercress", None, "QA", "QA", "cofid", None, None, None, None, None, None),
        ]
        connection.executemany(food_sql, foods)
        food_ids = dict(connection.execute("SELECT stable_id,food_id FROM food"))
        connection.executemany("INSERT INTO nutrient_definition VALUES (?,?,?,?,?,?,?)", [
            ("usda_fdc_consumer", "1003", "Protein", "g", "per_100g", "food_nutrient.csv", "1"),
            ("usda_branded_curated", "protein", "Protein", "g", "label_serving", "BrandedCuratedFoodItems.json", "1"),
            ("uk_cofid", "PROT", "Protein", "g", "source_food_basis", "1.3 Proximates", "8"),
        ])
        connection.executemany("INSERT INTO nutrient_value VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            (food_ids["usda_fdc:survey"], "usda_fdc_consumer", "1003", "food_nutrient.csv", "survey-protein", "1", "numeric", "g", "per_100g", None, None, None, None, None, None, None, None, None),
            (food_ids["usda_branded_curated:00000000000001"], "usda_branded_curated", "protein", "BrandedCuratedFoodItems.json", "branded-protein", "2", "numeric", "g", "label_serving", None, None, None, None, None, None, None, None, None),
            (food_ids["uk_cofid:13-669#a"], "uk_cofid", "PROT", "1.3 Proximates", "cofid-p", "3", "numeric", "g", "per_100g_food", None, None, None, None, None, None, None, None, None),
            (food_ids["uk_cofid:13-669#b"], "uk_cofid", "PROT", "1.3 Proximates", "cofid-q", "Tr", "trace", "g", "per_100ml_alcoholic_beverage", None, None, None, None, None, None, None, None, None),
        ])
        connection.execute("INSERT INTO food_factor VALUES (?,?,?,?)", (food_ids["uk_cofid:13-669#a"], "Factor", "1", "numeric"))
        connection.execute("INSERT INTO portion VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (1, food_ids["usda_branded_curated:00000000000001"], "serving", "1", "1", "g", "1", None, "serving", None, None, None))
        connection.execute("INSERT INTO food_ingredient VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (1, food_ids["usda_fdc:survey"], "relation", "1", "ingredient", "ingredient", "Ingredient", "42.662", "1", "1", "g", None, None, "5.5", "42.661999999999999", "5.500000000000001"))
        connection.execute("INSERT INTO fndds_dish VALUES (?,?,?,?,?,?,?)", (food_ids["usda_fdc:survey"], "survey", "Survey", "W", "WWEIA", "5.500000000000001", "5.5"))
        connection.execute("INSERT INTO branded_compatibility VALUES (?,?,?,?,?,?)", ("00000000000001", food_ids["usda_branded_curated:00000000000001"], "UUID-BRANDED", "enriched", None, 1))
        connection.execute("INSERT INTO branded_fdc_record VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ("fixture-fdc", food_ids["usda_branded_curated:00000000000001"], "00000000000001", "Fixture record", "1", "2026-01-01", "Owner", "Brand", None, "00000000000001", "WATER", None, "1", "g", None, None, None, None, "2026-01-01", "2026-01-01", "US", None, None, None, None, None))
        connection.execute("INSERT INTO branded_fdc_nutrient VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", ("fixture-fdc", "raw-protein", "1003", "2", None, None, None, None, None, None, None, None, None))
        catalog_pipeline.populate_compatibility(connection)
        catalog_pipeline.populate_fts(connection)
        contract = catalog_pipeline._actual_output_contract(connection)
        contract["tableCounts"]["validation_evidence"] = 2
        manifest["outputContract"] = contract
        catalog_pipeline._evidence(connection, {"input_contract": catalog_pipeline.input_contract(manifest)})
        catalog_pipeline._evidence(connection, {"table_content_sha256": catalog_pipeline.table_content_hashes(connection)})
        connection.commit()
        connection.close()
        shipping_uuids = {"00000000000001": "UUID-BRANDED"}
        catalog_pipeline.validate_database(database, manifest, shipping_uuids)
        return database, manifest, shipping_uuids

    def _write_committed_catalog(self, root: Path) -> Path:
        path = root / "committed.sqlite"
        connection = sqlite3.connect(path)
        connection.execute("CREATE TABLE food (gtin_upc TEXT,id TEXT)")
        connection.executemany(
            "INSERT INTO food VALUES (?,?)",
            [("00000000000001", "UUID-ENRICHED"), ("00070074649214", "UUID-LEGACY")],
        )
        connection.commit()
        connection.close()
        return path

    def _branded_expected(self, committed: Path) -> dict:
        return {
            "foods": 2,
            "shippingCatalogSHA256": sha256_file(committed),
            "legacyFullFdcExceptions": [{
                "gtin": "00070074649214", "shippingUUID": "UUID-LEGACY", "reason": "pinned fixture absence",
            }],
        }

    def _write_curated_fixture(self, root: Path) -> Path:
        records = [
            self._curated_record("00000000000001", "Enriched product"),
            self._curated_record("00070074649214", "Legacy product"),
        ]
        path = root / "curated.json"
        path.write_text(json.dumps(records), encoding="utf-8")
        return path

    def _curated_record(self, gtin: str, name: str) -> dict:
        return {
            "name": name, "gtinUpc": gtin, "brandSource": "Fixture brand", "category": "Fixture",
            "servingSize": 10, "servingUnit": "g", "protein": 1, "carbs": 2, "fat": 3,
        }

    def _write_fdc_fixture(self, root: Path) -> Path:
        path = root / "fdc.zip"
        prefix = "FoodData_Central_csv_2026-04-30/"
        with zipfile.ZipFile(path, "w") as archive:
            self._write_csv(archive, prefix + "branded_food.csv", [
                "fdc_id", "brand_owner", "brand_name", "subbrand_name", "gtin_upc", "ingredients",
                "not_a_significant_source_of", "serving_size", "serving_size_unit", "household_serving_fulltext",
                "branded_food_category", "data_source", "package_weight", "modified_date", "available_date",
                "market_country", "discontinued_date", "preparation_state_code", "trade_channel", "short_description", "material_code",
            ], [
                ["100", "Owner", "Brand", "Sub", "00000000000001", "WATER, COCOA", "", "10", "g", "1 serving", "Fixture", "GDSN", "", "2026-01-01", "2026-01-02", "US", "", "", "", "Product", ""],
                ["101", "Owner", "Brand", "Sub", "00000000000001", "WATER, COCOA, SALT", "", "11", "g", "1 serving", "Fixture", "LI", "", "2026-02-01", "2026-02-02", "US", "", "", "", "Product revised", ""],
                ["999", "Owner", "Other", "", "00000000000099", "UNSELECTED", "", "1", "g", "", "Fixture", "GDSN", "", "", "", "US", "", "", "", "", ""],
            ])
            self._write_csv(archive, prefix + "food.csv", ["fdc_id", "data_type", "description", "food_category_id", "publication_date"], [
                ["100", "branded_food", "Enriched source 1", "1", "2026-01-03"],
                ["101", "branded_food", "Enriched source 2", "1", "2026-02-03"],
            ])
            self._write_csv(archive, prefix + "food_nutrient.csv", [
                "id", "fdc_id", "nutrient_id", "amount", "data_points", "derivation_id", "min", "max", "median", "loq", "footnote", "min_year_acquired", "percent_daily_value",
            ], [["1000", "100", "1003", "1.0", "", "", "", "", "", "", "", "", ""], ["1001", "101", "1003", "2.0", "", "", "", "", "", "", "", "", ""]])
            self._write_csv(archive, prefix + "food_portion.csv", [
                "id", "fdc_id", "seq_num", "amount", "measure_unit_id", "portion_description", "modifier", "gram_weight", "data_points", "footnote", "min_year_acquired",
            ], [["500", "100", "1", "1", "9999", "serving", "", "10", "", "", ""], ["501", "101", "1", "1", "9999", "serving", "", "11", "", "", ""]])
        return path

    def _write_csv(self, archive: zipfile.ZipFile, name: str, headers: list[str], rows: list[list[str]]) -> None:
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(headers)
        writer.writerows(rows)
        archive.writestr(name, output.getvalue())

    def _insert_test_sources(self, connection: sqlite3.Connection) -> None:
        connection.executemany(
            "INSERT INTO source_manifest VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                ("usda_branded_curated", 1, "fixture", "fixture", None, "curated.json", 1, "hash", "CC0", "url", "Fixture", "Fixture"),
                ("usda_fdc_consumer", 1, "fixture", "fixture", None, "fdc.zip", 1, "hash", "CC0", "url", "Fixture", "Fixture"),
            ],
        )


if __name__ == "__main__":
    unittest.main()

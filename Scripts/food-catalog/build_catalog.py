#!/usr/bin/env python3
"""CLI for the authorized offline food-catalog rebuild."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from catalog_pipeline import PipelineError, build_catalog


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--fdc-zip", type=Path, required=True)
    parser.add_argument("--fndds-ingredients", type=Path, required=True)
    parser.add_argument("--survey-validation-json", type=Path, required=True)
    parser.add_argument("--sr-validation-json", type=Path, required=True)
    parser.add_argument("--branded-curated-json", type=Path, required=True)
    parser.add_argument("--cofid-xlsx", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--committed-catalog", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        report = build_catalog(
            manifest_path=arguments.manifest,
            fdc_zip=arguments.fdc_zip,
            fndds_xlsx=arguments.fndds_ingredients,
            survey_json=arguments.survey_validation_json,
            sr_json=arguments.sr_validation_json,
            branded_curated_json=arguments.branded_curated_json,
            cofid_xlsx=arguments.cofid_xlsx,
            output_dir=arguments.output_dir,
            committed_catalog=arguments.committed_catalog,
        )
    except PipelineError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

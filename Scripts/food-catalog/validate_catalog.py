#!/usr/bin/env python3
"""Validate a generated local catalog without opening the committed resource."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from catalog_pipeline import (
    PipelineError,
    load_evidence,
    load_manifest,
    load_shipping_uuid_map,
    sha256_file,
    validate_database,
    validate_evidence_contract,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--committed-catalog", type=Path, required=True)
    parser.add_argument("--evidence", type=Path)
    arguments = parser.parse_args()
    try:
        manifest = load_manifest(arguments.manifest)
        branded = next(source for source in manifest["sources"] if source["key"] == "usda_branded_curated")
        shipping_uuids = load_shipping_uuid_map(arguments.committed_catalog, branded["expected"])
        if arguments.evidence is not None:
            evidence = load_evidence(arguments.evidence)
            validate_evidence_contract(evidence, manifest, arguments.catalog)
        validation = validate_database(arguments.catalog, manifest, shipping_uuids)
    except (OSError, PipelineError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    result = {
        "catalog": arguments.catalog.name,
        "bytes": arguments.catalog.stat().st_size,
        "sha256": sha256_file(arguments.catalog),
        "validation": validation,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

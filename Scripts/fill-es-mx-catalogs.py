#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# fill-es-mx-catalogs.py: give every Spanish string an es-MX entry, keeping the ones already written.
#
# iOS does not fall back from es-MX to es key by key. Once a bundle has an es-MX.lproj, a key missing from that
# table is simply missing and draws its English default (measured on the iOS 26.5 simulator, 2026-11-01: 6,313 of
# 7,259 keys). So es-MX has to be complete, and this copies es into es-MX wherever es-MX has nothing yet. A copied
# string reads the same in Mexico and Spain until someone gives it a Mexican wording.
#
# Run it after adding Spanish translations, then replace any Spain-only wording in what it copied
# (Docs/Localization-es-MX.md). LocalizationBoundaryTests fails while a Spanish string has no es-MX entry.
#
# Usage: Scripts/fill-es-mx-catalogs.py

import copy
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def render(node, depth=0):
    """Xcode's own .xcstrings layout, so a fill leaves every other line of the file alone."""
    pad = "  " * depth
    if isinstance(node, dict):
        if not node:
            return "{\n\n" + pad + "}"
        rows = ["  " * (depth + 1) + json.dumps(k, ensure_ascii=False) + " : " + render(v, depth + 1) for k, v in node.items()]
        return "{\n" + ",\n".join(rows) + "\n" + pad + "}"
    if isinstance(node, list):
        rows = ["  " * (depth + 1) + render(v, depth + 1) for v in node]
        return "[\n" + ",\n".join(rows) + "\n" + pad + "]"
    return json.dumps(node, ensure_ascii=False)


def main():
    listed = subprocess.check_output(["git", "-C", ROOT, "ls-files", "*.xcstrings"]).decode().split("\n")
    filled = 0
    for name in filter(None, listed):
        path = os.path.join(ROOT, name)
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
        catalog = json.loads(raw)
        changed = False
        for entry in catalog["strings"].values():
            localizations = entry.get("localizations", {})
            if "es" not in localizations or "es-MX" in localizations:
                continue
            ordered = {}
            for language, value in localizations.items():
                ordered[language] = value
                if language == "es":
                    ordered["es-MX"] = copy.deepcopy(value)
            entry["localizations"] = ordered
            changed = True
            filled += 1
        if changed:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(render(catalog) + ("\n" if raw.endswith("\n") else ""))
    print(f"filled {filled} es-MX entries")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""exercise-animation-catalog.py — build the app's exercise-animation catalog and stills.

The owner approved all 199 exercise animations (package revision r12) on 2026-10-29. The app
carries the engine (App/Fernlet/ExerciseAnimations.bundle) and, from this script:

- App/Fernlet/ExerciseAnimationCatalog.json: one row per exercise, {name, equipment, id, duration,
  hold, stillProgress}. `name` and `equipment` come from the package's catalog.json (they equal
  App/Fernlet/WorkoutExercises.json); `duration` and `hold` from Resources/FernletAnimations/
  movements.json (duration is the demo loop in seconds, not a prescription); `stillProgress` from
  Stills/index.json (0.5 for an animated exercise, 0 for a hold).
- App/Fernlet/ExerciseAnimationStills.bundle/{male,female}/exercise-NNN.png: the 398 generated
  stills, copied byte for byte.

Nothing else from the package comes in: no player, preview page, catalog/approval copies, GIFs or
reference material. The script refuses a package whose files disagree with each other.

Usage:  Scripts/exercise-animation-catalog.py <package dir>
"""
import json
import pathlib
import shutil
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG_OUT = REPO / "App/Fernlet/ExerciseAnimationCatalog.json"
STILLS_OUT = REPO / "App/Fernlet/ExerciseAnimationStills.bundle"
CHARACTERS = ("male", "female")


def normalized(name: str) -> str:
    """WorkoutExerciseCatalog.normalizedName: trimmed, lowercased, single spaces."""
    return " ".join(name.strip().lower().split())


def load(package: pathlib.Path, relative: str):
    return json.loads((package / relative).read_text(encoding="utf-8"))


def stills_progress(index: list) -> dict:
    progress = {}
    for still in index:
        if (still["width"], still["height"], still["view"]) != (640, 480, "exercise"):
            sys.exit(f"unexpected still geometry or camera: {still}")
        previous = progress.setdefault(still["id"], still["progress"])
        if previous != still["progress"]:
            sys.exit(f"the two characters' stills disagree on progress: {still['id']}")
    return progress


def rows(package: pathlib.Path) -> list:
    catalog = load(package, "catalog.json")
    movements = {m["id"]: m for m in load(package, "Resources/FernletAnimations/movements.json")}
    progress = stills_progress(load(package, "Stills/index.json"))
    app = {normalized(e["name"]): e for e in json.loads(
        (REPO / "App/Fernlet/WorkoutExercises.json").read_text(encoding="utf-8"))}
    out = []
    for item in catalog:
        movement = movements[item["id"]]
        mine = app.get(normalized(item["name"]))
        if mine is None or mine["equipment"] != item["equipment"]:
            sys.exit(f"{item['id']} {item['name']!r} does not match WorkoutExercises.json")
        expected = 0 if movement["hold"] else 0.5
        if progress[item["id"]] != expected:
            sys.exit(f"{item['id']} still progress {progress[item['id']]} is not {expected}")
        out.append({"name": mine["name"], "equipment": item["equipment"], "id": item["id"],
                    "duration": movement["duration"], "hold": movement["hold"],
                    "stillProgress": progress[item["id"]]})
    if len(out) != len(app) or len({r["id"] for r in out}) != len(out):
        sys.exit(f"{len(out)} rows for {len(app)} catalog exercises, or a repeated ID")
    return out


def copy_stills(package: pathlib.Path, ids: list) -> None:
    if STILLS_OUT.exists():
        shutil.rmtree(STILLS_OUT)
    for character in CHARACTERS:
        (STILLS_OUT / character).mkdir(parents=True)
        for exercise_id in ids:
            source = package / "Stills" / character / f"{exercise_id}.png"
            shutil.copyfile(source, STILLS_OUT / character / source.name)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    package = pathlib.Path(sys.argv[1]).resolve()
    catalog = rows(package)
    lines = ",\n".join("  " + json.dumps(row, ensure_ascii=False) for row in catalog)
    CATALOG_OUT.write_text("[\n" + lines + "\n]\n", encoding="utf-8")
    copy_stills(package, [row["id"] for row in catalog])
    print(f"{len(catalog)} rows -> {CATALOG_OUT.relative_to(REPO)}; "
          f"{len(catalog) * len(CHARACTERS)} stills -> {STILLS_OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()

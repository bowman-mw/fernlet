#!/usr/bin/env python3
"""wall-clock-suites.py: name the FernletTests suites that hold a real-time deadline.

Why this exists. The nightly full run (.github/workflows/scheduled-report.yml) puts about 9,500 tests
in one process. Swift Testing starts them together, and nearly all of them are main-actor tests, so
every `await` in one test waits behind a slice of every other. On the hosted runner a single test
measured 25 to 47 minutes of wall time that way (run 44340241698, 2026-11-18). Two families of suites
compare the real clock (`Date()`) against a deadline the product is right to keep short:

  mesh   Every mesh envelope ProximityKit 0.2.0 signs expires five minutes later
         (`MeshNetworkManager.meshEnvelopeLifetime`), and `ProximityIdentityEnvelope.verify` reads
         `Date()`. A rig that signs a frame, yields, and pumps it more than five minutes later throws
         `.expired`. About thirty suites failed that way every night from 2026-11-17, the first night
         after the 0.2.0 pin.
  timers `GuidedRunCuePlan.lateTolerance` drops a timed cue more than two seconds late. The two cue
         suites seed a rest that ended half a second ago, so a timer task that waits 1.5 s for the
         main actor plays nothing (red on three of the five nights read). FernletLockScopeTests puts a
         SwiftUI gate in a window and gives its `onAppear` a 100 ms sleep to run, which the same
         queue outlasts on some nights (red on two of the five).

Neither clock can be injected from a test today (see the pull request that added this file for the
proposal). Until one can, the nightly runs these suites in passes of their own with parallel testing
off, where a test's wall time is its own, and skips them in the big pass.

The `mesh` group is read from the tree, not listed, so a new mesh battery joins it unasked: every
top-level type named `Mesh…Tests` in any file under Tests/FernletTests, and every top-level type
named `…Tests` in a file named `Mesh*.swift`. A name that turns out not to be a suite selects
nothing, in either direction, which is harmless here because each pass refuses to pass on zero
tests. The `timers` group is three suites by name.

Usage:
    Scripts/wall-clock-suites.py mesh|timers|all            one suite name per line
    Scripts/wall-clock-suites.py --only mesh|timers|all     as `-only-testing:FernletTests/<Suite>` words
    Scripts/wall-clock-suites.py --skip mesh|timers|all     as `-skip-testing:FernletTests/<Suite>` words
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "Tests" / "FernletTests"
TIMERS = ["FernletLockScopeTests", "GuidedRunCueTests", "GuidedRunSpokenCueTests"]
# A top-level type declaration: column 0, any attributes and modifiers, then the keyword and the name.
DECLARATION = re.compile(
    r"^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|final)\s+)*(?:struct|class|enum|actor)\s+(\w+)"
)
GROUPS = ("mesh", "timers", "all")


def mesh_suites():
    """Every top-level `Mesh…Tests` type in the tree, and every `…Tests` type in a `Mesh*.swift` file."""
    names = set()
    # Bounded: one pass over the test target's finite file list, one pass over each file's lines.
    for path in sorted(TESTS.glob("*.swift")):
        in_mesh_file = path.name.startswith("Mesh")
        for line in path.read_text(encoding="utf-8").splitlines():
            match = DECLARATION.match(line)
            if not match or not match.group(1).endswith("Tests"):
                continue
            if in_mesh_file or match.group(1).startswith("Mesh"):
                names.add(match.group(1))
    return sorted(names)


def suites(group):
    """The suite names of one group, sorted."""
    if group == "mesh":
        return mesh_suites()
    if group == "timers":
        return list(TIMERS)
    return sorted(set(mesh_suites()) | set(TIMERS))


def main(argv):
    """Prints the group's suites, bare or as xcodebuild selector words. Returns the exit status."""
    prefix = ""
    args = list(argv)
    if args and args[0] in ("--only", "--skip"):
        prefix = "-only-testing:FernletTests/" if args[0] == "--only" else "-skip-testing:FernletTests/"
        args = args[1:]
    if len(args) != 1 or args[0] not in GROUPS:
        print(__doc__.split("Usage:")[1], file=sys.stderr)
        return 2
    names = suites(args[0])
    if not names:
        print(f"wall-clock-suites: the {args[0]} group is empty; the tree has moved", file=sys.stderr)
        return 1
    for name in names:
        print(prefix + name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

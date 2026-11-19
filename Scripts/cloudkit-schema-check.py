#!/usr/bin/env python3
"""Compare an exported CloudKit schema with the schema the app needs. Read-only.

Usage: Scripts/cloudkit-schema-check.py <exported.ckdb> [--expected <file.json>]
                                        [--write-merged <out.ckdb>]

<exported.ckdb> is the text file `xcrun cktool export-schema` writes (CloudKit Schema
Language). The expected schema is Docs/CloudKit-Expected-Schema.json unless --expected
names another file. The script reads both files and prints; it never talks to CloudKit
and writes nothing unless --write-merged is given.

--write-merged <out.ckdb> also writes a schema file holding everything in the export plus
everything the check found missing (types, fields, indexes, grants), nothing removed and
nothing retyped. Export DEVELOPMENT, merge, then `xcrun cktool validate-schema` and
`xcrun cktool import-schema` that file into Development, and promote in the Console.

For every record type the app writes it reports:
  MISSING TYPE    the record type is not in the export
  MISSING FIELD   a field the app writes is not on the type
  WRONG TYPE      the field exists with a different data type
  MISSING INDEX   a query the app runs needs an index that is absent, including the
                  QUERYABLE index on recordName ("___recordID") that every
                  list-all-records sweep needs
  MISSING GRANT   a public-database type lacks a permission the app relies on
Legacy types (swept if present, written by no current build) are only checked for the
recordName index, and only when they exist.

Exit status: 0 when nothing is missing or wrong, 1 when something is, 2 on a usage or
parse error. See Docs/CloudKit-Schema-Deploy.md for how to export the schema and what
to do about each finding.
"""
import json
import os
import re
import sys

INDEX_WORDS = ("QUERYABLE", "SEARCHABLE", "SORTABLE")
RECORD_ID = "___recordID"
TYPE_RE = re.compile(r"RECORD\s+TYPE\s+(\"[^\"]+\"|\S+)\s*\((.*?)\)\s*;", re.S)
COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*|--[^\n]*", re.S)


def split_entries(body):
    """The comma-separated entries of one record type, with a multi-permission GRANT kept whole."""
    entries, pending = [], None
    for piece in (p.strip() for p in body.split(",")):
        if not piece:
            continue
        if pending is not None:
            pending = pending + ", " + piece
        elif piece.upper().startswith("GRANT"):
            pending = piece
        else:
            entries.append(piece)
            continue
        if re.search(r"\sTO\s", pending, re.I):
            entries.append(pending)
            pending = None
    if pending is not None:
        entries.append(pending)
    return entries


def parse_exported(text):
    """{type name: {"fields": {name: (data type, set of index words)}, "grants": {role: set}}}."""
    text = COMMENT_RE.sub("", text)
    if "DEFINE SCHEMA" not in text.upper():
        raise ValueError("no DEFINE SCHEMA header; is this a cktool export-schema file?")
    types = {}
    for match in TYPE_RE.finditer(text):
        name = match.group(1).strip('"')
        fields, grants = {}, {}
        for entry in split_entries(match.group(2)):
            words = entry.split()
            if words[0].upper() == "GRANT":
                grant = re.match(r"GRANT\s+(.*?)\s+TO\s+(\S+)", entry, re.I | re.S)
                if grant:
                    role = grant.group(2).strip('"')
                    rights = {r.strip().upper() for r in grant.group(1).split(",")}
                    grants.setdefault(role, set()).update(rights)
                continue
            indexes = {w.upper() for w in words[1:] if w.upper() in INDEX_WORDS}
            data_type = " ".join(w for w in words[1:] if w.upper() not in INDEX_WORDS).upper()
            fields[words[0].strip('"')] = (data_type, indexes)
        types[name] = {"fields": fields, "grants": grants}
    return types


def type_matches(expected, actual):
    """Whether an exported data type satisfies the expected one."""
    if actual == expected:
        return True
    # A numeric field a Debug save created on the fly exports as NUMBER.
    return expected == "INT64" and actual in ("NUMBER", "NUMBER PREFERRED AS INT64")


def check_type(name, spec, exported, problems):
    """Appends one line per gap between an expected record type and the export."""
    tag = " (new: %s)" % spec["added"] if spec.get("added") else ""
    actual = exported.get(name)
    if actual is None:
        problems.append("MISSING TYPE   %s%s, with %d fields" % (name, tag, len(spec["fields"])))
        return
    for field, want in spec["fields"].items():
        field_tag = " (new: %s)" % want["added"] if want.get("added") else ""
        have = actual["fields"].get(field)
        if have is None:
            problems.append("MISSING FIELD  %s.%s %s%s" % (name, field, want["type"], field_tag))
            continue
        if not type_matches(want["type"], have[0]):
            problems.append("WRONG TYPE     %s.%s is %s, expected %s" % (name, field, have[0], want["type"]))
        for index in want.get("indexes", []):
            if index not in have[1]:
                problems.append("MISSING INDEX  %s.%s needs %s" % (name, field, index))
    if spec.get("recordNameQueryable"):
        check_record_name(name, actual, problems)
    for role, rights in spec.get("grants", {}).items():
        for right in rights:
            if right not in actual["grants"].get(role, set()):
                problems.append("MISSING GRANT  %s needs GRANT %s TO \"%s\"" % (name, right, role))


def check_record_name(name, actual, problems):
    """Appends a line when the type lacks the QUERYABLE recordName index."""
    have = actual["fields"].get(RECORD_ID)
    if have is None or "QUERYABLE" not in have[1]:
        problems.append("MISSING INDEX  %s.recordName needs QUERYABLE (\"%s\" REFERENCE QUERYABLE)" % (name, RECORD_ID))


DEFAULT_GRANTS = {"_creator": {"WRITE"}, "_icloud": {"CREATE"}, "_world": {"READ"}}
SYSTEM_FIELD_TYPES = {RECORD_ID: "REFERENCE"}


def merged_schema(expected, exported):
    """The exported schema with every expected type, field, index and grant added."""
    merged = {name: {"fields": dict(t["fields"]), "grants": {r: set(v) for r, v in t["grants"].items()}}
              for name, t in exported.items()}
    for name, spec in expected["recordTypes"].items():
        target = merged.setdefault(name, {"fields": {}, "grants": {r: set(v) for r, v in DEFAULT_GRANTS.items()}})
        for field, want in spec["fields"].items():
            have = target["fields"].get(field, (want["type"], set()))
            target["fields"][field] = (have[0], set(have[1]) | set(want.get("indexes", [])))
        for role, rights in spec.get("grants", {}).items():
            target["grants"].setdefault(role, set()).update(rights)
    queryable = [n for n, spec in expected["recordTypes"].items() if spec.get("recordNameQueryable")]
    queryable += [n for n in expected["legacyRecordTypes"]["names"] if n in merged]
    for name in queryable:
        have = merged[name]["fields"].get(RECORD_ID, (SYSTEM_FIELD_TYPES[RECORD_ID], set()))
        merged[name]["fields"][RECORD_ID] = (have[0], set(have[1]) | {"QUERYABLE"})
    return merged


def render_schema(types):
    """CloudKit Schema Language text for parsed record types."""
    def quoted(name):
        return '"%s"' % name if name.startswith("_") else name
    out = ["DEFINE SCHEMA", ""]
    for name in sorted(types):
        rows = []
        for field in sorted(types[name]["fields"]):
            data_type, indexes = types[name]["fields"][field]
            options = " ".join(w for w in INDEX_WORDS if w in indexes)
            rows.append(("%s %s %s" % (quoted(field), data_type, options)).rstrip())
        for role in sorted(types[name]["grants"]):
            rows.append("GRANT %s TO %s" % (", ".join(sorted(types[name]["grants"][role])), quoted(role)))
        out.append("    RECORD TYPE %s (" % quoted(name))
        out.append(",\n".join("        " + row for row in rows))
        out.append("    );")
        out.append("")
    return "\n".join(out)


def take_option(argv, flag):
    """Removes `flag <value>` from argv; returns the value, None when absent, False when malformed."""
    if flag not in argv:
        return None
    position = argv.index(flag)
    if position + 1 >= len(argv):
        return False
    value = argv[position + 1]
    del argv[position:position + 2]
    return value


def main(argv):
    """Runs the comparison; returns the process exit status."""
    args = list(argv[1:])
    expected_path = take_option(args, "--expected")
    merged_path = take_option(args, "--write-merged")
    if expected_path is False or merged_path is False:
        print(__doc__, file=sys.stderr)
        return 2
    if expected_path is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        expected_path = os.path.join(root, "Docs", "CloudKit-Expected-Schema.json")
    if len(args) != 1 or args[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(expected_path, encoding="utf-8") as handle:
            expected = json.load(handle)
        with open(args[0], encoding="utf-8") as handle:
            exported = parse_exported(handle.read())
    except (OSError, ValueError) as error:
        print("cloudkit-schema-check: %s" % error, file=sys.stderr)
        return 2

    problems = []
    for name, spec in expected["recordTypes"].items():
        check_type(name, spec, exported, problems)
    legacy_present = [n for n in expected["legacyRecordTypes"]["names"] if n in exported]
    for name in legacy_present:
        check_record_name(name, exported[name], problems)

    known = set(expected["recordTypes"]) | set(expected["legacyRecordTypes"]["names"])
    print("Container %s: %d record types in the export, %d expected."
          % (expected["container"], len(exported), len(expected["recordTypes"])))
    flagged = {line.split()[2].split(".")[0].rstrip(",") for line in problems}
    for name in expected["recordTypes"]:
        if name not in flagged:
            print("ok             %s" % name)
    for line in problems:
        print(line)
    if legacy_present:
        print("legacy present %s" % ", ".join(legacy_present))
    extra = sorted(n for n in exported if n not in known)
    if extra:
        print("not expected   %s (in the export, written by no current build; harmless)" % ", ".join(extra))
    if merged_path:
        with open(merged_path, "w", encoding="utf-8") as handle:
            handle.write(render_schema(merged_schema(expected, exported)))
        print("merged schema  written to %s" % merged_path)
    print("RESULT: %s" % ("nothing missing" if not problems else "%d problem(s)" % len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

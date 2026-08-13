#!/usr/bin/env python3
"""Scan Swift sources for type declarations lacking an adjacent /// doc comment.

Usage: Scripts/doc-coverage-scan.py [<root> ...]
With no arguments, scans the four documented roots: FernletKit/Sources, App/Fernlet,
App/FernletWidgets, App/FernletShareExtension (relative to the repo root, which is
resolved from this script's location).

Prints one line per undocumented declaration (path:line:TypeName: decl) and a
TOTAL to stderr; exits 1 if any are found. The enforced baseline is zero — every
struct/class/protocol/enum/actor carries a /// doc comment (see CLAUDE.md,
"Framework documentation").

Heuristic: a declaration is documented if, walking upward past attribute lines
(@...), the nearest preceding line is a /// line or the end of a /** */ block.
Skips lines inside block comments and multiline string literals (approximate,
line-based tracking). Requires an uppercase-or-underscore identifier after the
type keyword so `class func` / `class var` don't match.
"""
import os
import re
import sys

DECL_RE = re.compile(
    r"^\s*(?:@\w[\w.]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|open|internal|package|private|fileprivate|final|indirect|dynamic|nonisolated|distributed)\s+)*"
    r"(?:struct|class|protocol|enum|actor)\s+([A-Z_]\w*)"
)
ATTR_RE = re.compile(r"^\s*@\w")


def scan_file(path):
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    findings = []
    block_comment = 0
    in_multiline_string = False
    code_mask = []  # True if the line is (mostly) code
    for line in lines:
        stripped = line.strip()
        is_code = True
        if in_multiline_string:
            is_code = False
            if '"""' in stripped:
                in_multiline_string = False
        elif block_comment > 0:
            is_code = False
            block_comment += stripped.count("/*") - stripped.count("*/")
            if block_comment < 0:
                block_comment = 0
        else:
            if stripped.startswith("//"):
                is_code = False
            else:
                opens = stripped.count("/*") - stripped.count("*/")
                if opens > 0:
                    block_comment = opens
                if stripped.count('"""') % 2 == 1:
                    in_multiline_string = True
        code_mask.append(is_code)

    for idx, line in enumerate(lines):
        if not code_mask[idx]:
            continue
        m = DECL_RE.match(line)
        if not m:
            continue
        # walk upward past attributes / attribute-argument continuation lines
        j = idx - 1
        while j >= 0:
            prev = lines[j].strip()
            if ATTR_RE.match(prev) or prev.endswith(",") and j > 0 and ATTR_RE.match(lines[j - 1].strip()):
                j -= 1
                continue
            break
        documented = False
        if j >= 0:
            prev = lines[j].strip()
            if prev.startswith("///") or prev.endswith("*/"):
                documented = True
        if not documented:
            findings.append((idx + 1, m.group(1), line.strip()[:100]))
    return findings


def main():
    roots = sys.argv[1:]
    if not roots:
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        roots = [
            os.path.join(repo, d)
            for d in ("FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension")
        ]
    total = 0
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.endswith(".docc") and d != ".git"]
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                for lineno, type_name, text in scan_file(path):
                    print(f"{path}:{lineno}:{type_name}: {text}")
                    total += 1
    print(f"\nTOTAL undocumented type declarations: {total}", file=sys.stderr)
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()

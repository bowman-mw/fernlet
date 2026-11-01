#!/usr/bin/env python3
"""site-asset-versions.py — version every page's stylesheet, script and icon URLs by their content.

GitHub Pages caches the pages for 10 minutes but style.css and the scripts for 4 hours
(`cache-control: max-age=14400`). So after a deploy, a returning visitor can get the new page with
the old stylesheet for hours. On 2026-10-26 the World update rendered with the old CSS on the
owner's laptop: the screenshots overflowed and the companion's two frames stacked. Each reference
therefore carries `?v=<the first 8 hex digits of the file's SHA-256>`. A changed file gets a new
URL, and a new page asks for it.

Usage:  Scripts/site-asset-versions.py          rewrite every reference to the current version
        Scripts/site-asset-versions.py --check  exit 1 if any reference is missing or stale
                                                (the Pages workflow runs this before deploying)
"""
import hashlib
import pathlib
import re
import sys

SITE = pathlib.Path(__file__).resolve().parent.parent / "Site"
# A same-origin stylesheet or script, or a tab or home-screen icon link, with or without a version
# already on it. Browsers keep a favicon for weeks under an unchanged URL (Safari longest), so the
# pixel fern that replaced the old mark in PR #79 never reached returning visitors until its URL moved.
REFERENCE = re.compile(
    r'(?P<attr>href|src)="(?P<path>[^"?#:]+\.(?:css|js))(?:\?v=[0-9a-f]*)?"'
    r'|(?<=rel="icon" )(?P<attr2>href)="(?P<path2>[^"?#:]+\.(?:svg|png))(?:\?v=[0-9a-f]*)?"'
    r'|(?<=rel="apple-touch-icon" )(?P<attr3>href)="(?P<path3>[^"?#:]+\.png)(?:\?v=[0-9a-f]*)?"'
)


def version(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:8]


def resolve(page: pathlib.Path, reference: str) -> pathlib.Path:
    if reference.startswith("/"):
        return SITE / reference.lstrip("/")
    return (page.parent / reference).resolve()


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for page in sorted(SITE.rglob("*.html")):
        text = page.read_text(encoding="utf-8")

        def stamp(match: re.Match) -> str:
            attr = match["attr"] or match["attr2"] or match["attr3"]
            path = match["path"] or match["path2"] or match["path3"]
            target = resolve(page, path)
            if not target.is_file():
                stale.append(f"{page.relative_to(SITE)}: {path} does not exist")
                return match[0]
            return f'{attr}="{path}?v={version(target)}"'

        updated = REFERENCE.sub(stamp, text)
        if updated == text:
            continue
        if check:
            stale.append(f"{page.relative_to(SITE)}: a stylesheet, script or icon reference is not at its current version")
        else:
            page.write_text(updated, encoding="utf-8")
            print(f"updated {page.relative_to(SITE)}")
    for line in stale:
        print(f"::error::{line} — run Scripts/site-asset-versions.py" if check else f"error: {line}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())

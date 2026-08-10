#!/bin/bash
# release-checksum.sh — build a release archive, emit SHA-256 checksums, cut a signed tag.
#
# Part of the verifiability story (Docs/Verifiability.md §2, Docs/Release-Process.md): every
# release gets (1) an annotated, cryptographically SIGNED git tag pinning the exact source, and
# (2) published SHA-256 checksums of the archived products built from that tag, so anyone can
# rebuild the same tag and compare their own build against the owner's baseline.
#
# HONEST LIMIT (do not oversell this): byte-exact verification of the App Store binary is NOT
# possible on iOS. Apple re-signs every submitted build, injects its own DRM/encryption, and may
# transform the binary server-side, so no checksum computed here can match bytes downloaded from
# the store. What this script provides is the SELF-BUILD BASELINE: the signed tag proves which
# source a release came from, the checksums let two independent builders compare their outputs
# for drift, and a user who wants a binary they can fully account for can sideload their own
# build of the tag — the app has no store-only functionality.
#
# Usage:
#   Scripts/release-checksum.sh <version> [--skip-tag] [--skip-archive]
#     <version>        e.g. 1.0.0 — tags as v1.0.0 and names the output directory.
#     --skip-tag       build + checksum only (e.g. re-checksumming an existing tag).
#     --skip-archive   tag only (no Xcode build; useful on a machine without simulators).
#
# Prereqs for signing: a git signing key configured (gpg or ssh):
#   git config user.signingkey <key>  [+ gpg.format ssh if using an SSH key]
# The tag is created with `git tag -s` and will fail loudly if signing is not configured —
# an UNSIGNED release tag defeats the point, so there is no fallback.

set -euo pipefail

usage() { sed -n '17,24p' "$0"; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
shift
SKIP_TAG=0
SKIP_ARCHIVE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tag) SKIP_TAG=1 ;;
    --skip-archive) SKIP_ARCHIVE=1 ;;
    *) echo "unknown option: $arg" >&2; usage ;;
  esac
done

TAG="v${VERSION}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUT_DIR="$REPO_ROOT/build/release-$VERSION"
ARCHIVE_PATH="$OUT_DIR/Fernlet.xcarchive"
CHECKSUM_FILE="$OUT_DIR/SHA256SUMS-$VERSION.txt"

# ── Preconditions ────────────────────────────────────────────────────────────────
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — a release must be cut from a clean, committed tree." >&2
  exit 1
fi
HEAD_SHA="$(git rev-parse HEAD)"

# ── 1. Signed annotated tag ──────────────────────────────────────────────────────
if [ "$SKIP_TAG" -eq 0 ]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG already exists at $(git rev-parse "refs/tags/$TAG^{commit}") — skipping tag creation."
  else
    git tag -s "$TAG" -m "Fernlet $VERSION

Source-pinning release tag (Docs/Release-Process.md). Checksums of the archive
built from this exact commit are published alongside the release.

Commit: $HEAD_SHA"
    echo "created signed tag $TAG at $HEAD_SHA"
  fi
fi

# ── 1b. Tag ↔ HEAD attribution guard (runs on BOTH paths, --skip-tag included) ──
# The checksum file below stamps "tag: $TAG  commit: $HEAD_SHA" as a provenance record, and the
# archive is built from HEAD — so that pairing must be TRUE before anything is hashed. Without
# this, a pre-existing tag at an older commit (HEAD moved on, or the wrong checkout under
# --skip-tag) would publish a checksum file attributing the tag to a commit it does not point
# at — silently corrupting the exact artifact the verifiability story rests on.
TAG_SHA="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")" || {
  echo "error: tag $TAG does not exist — cannot checksum a build attributed to it." >&2
  echo "       (run without --skip-tag to create it, or check out the intended release)" >&2
  exit 1
}
if [ "$TAG_SHA" != "$HEAD_SHA" ]; then
  echo "error: tag $TAG points at $TAG_SHA but HEAD is $HEAD_SHA." >&2
  echo "       Refusing to stamp a false tag/commit pairing into the checksum file." >&2
  echo "       Check out the tagged commit first: git checkout $TAG" >&2
  exit 1
fi
git tag -v "$TAG" || { echo "error: tag $TAG does not verify — aborting." >&2; exit 1; }

# ── 2. Release archive ───────────────────────────────────────────────────────────
if [ "$SKIP_ARCHIVE" -eq 0 ]; then
  mkdir -p "$OUT_DIR"
  echo "archiving Fernlet (Release) → $ARCHIVE_PATH ..."
  xcodebuild archive \
    -scheme Fernlet \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    | tail -5

  # ── 3. Checksums ───────────────────────────────────────────────────────────────
  # Hash every regular file in the archive's Products tree (the .app bundle and any
  # appex/framework payloads), with paths relative to the archive so two builders'
  # lists line up. Sorted for a stable, diffable output.
  {
    echo "# Fernlet $VERSION — SHA-256 checksums of the release archive products"
    echo "# tag: $TAG  commit: $HEAD_SHA"
    echo "# built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion) / $(xcodebuild -version | tr '\n' ' ')"
    echo "# NOTE: iOS App Store binaries are re-signed and transformed by Apple and will NOT"
    echo "# match these hashes. These are the self-build baseline (Docs/Verifiability.md §2)."
    (cd "$ARCHIVE_PATH" && find Products -type f -print0 | sort -z | xargs -0 shasum -a 256)
  } > "$CHECKSUM_FILE"
  echo "wrote $(grep -c '^[0-9a-f]' "$CHECKSUM_FILE") checksums → $CHECKSUM_FILE"
  echo
  echo "Publish $CHECKSUM_FILE with the $TAG release (see Docs/Release-Process.md §4)."
fi

echo "done."

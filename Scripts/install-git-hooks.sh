#!/bin/bash
#
# install-git-hooks.sh — install Fernlet's versioned git hooks (WI-3,
# Docs/Security-Hardening-Plan-2026-06-27.md) by pointing core.hooksPath at the committed
# Scripts/git-hooks directory. Run once per clone. Idempotent.
#
# This installs the pre-push S3 privacy-wall check. Bypass a single push with:
#   SKIP_S3_WALL_CHECK=1 git push
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

chmod +x Scripts/git-hooks/* 2>/dev/null || true
git config core.hooksPath Scripts/git-hooks

echo "Installed git hooks: core.hooksPath -> Scripts/git-hooks"
echo "Active hooks:"
ls -1 Scripts/git-hooks
echo
echo "The pre-push hook runs Scripts/spm-wall-check.sh when wall-relevant files change."
echo "Bypass once with: SKIP_S3_WALL_CHECK=1 git push"

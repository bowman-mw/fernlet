#!/bin/bash
#
# install-git-hooks.sh — install Fernlet's versioned git hooks (WI-3,
# Docs/Security-Hardening-Plan-2026-06-27.md) by pointing core.hooksPath at the committed
# Scripts/git-hooks directory. Run once per clone. Idempotent.
#
# This installs the pre-push hook, whose two build legs are the S3 privacy-wall check
# (Scripts/spm-wall-check.sh) and the Mac-ready set's native-macOS build check
# (Scripts/macos-build-check.sh, plan step A0.6). Bypass one leg for a single push with:
#   SKIP_S3_WALL_CHECK=1 git push       (the S3 wall check)
#   SKIP_MACOS_BUILD_CHECK=1 git push   (the macOS build check)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

chmod +x Scripts/git-hooks/* 2>/dev/null || true

# The value stays RELATIVE. Git resolves a relative core.hooksPath against the root of the
# working tree a hook runs in, so every linked worktree runs its own checkout's hooks and the
# setting survives the clone moving. An absolute path would make every worktree run the
# primary checkout's (possibly stale) hooks.
git config --local core.hooksPath Scripts/git-hooks

# Tools that create linked worktrees can copy an ABSOLUTE core.hooksPath into each worktree's
# own config.worktree, which wins over the shared value above. Clear those copies so every
# worktree falls back to the shared relative value.
COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
for worktree_config in "$COMMON_DIR"/worktrees/*/config.worktree; do
    [ -f "$worktree_config" ] || continue
    if git config --file "$worktree_config" --get core.hooksPath >/dev/null 2>&1; then
        git config --file "$worktree_config" --unset-all core.hooksPath
        echo "Cleared a per-worktree core.hooksPath in ${worktree_config#"$COMMON_DIR"/}"
    fi
done

echo "Installed git hooks: core.hooksPath -> Scripts/git-hooks"
echo "Active hooks:"
ls -1 Scripts/git-hooks
echo
echo "The pre-push hook runs Scripts/spm-wall-check.sh when wall-relevant files change, and"
echo "Scripts/macos-build-check.sh when the Mac-ready set, the manifest or the macOS scripts change."
echo "Bypass one leg once with: SKIP_S3_WALL_CHECK=1 git push, or SKIP_MACOS_BUILD_CHECK=1 git push"

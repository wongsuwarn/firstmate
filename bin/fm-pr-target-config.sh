#!/usr/bin/env bash
# Converge gh's default repository for this firstmate checkout.
#
# gh 2.97.0 records `gh repo set-default origin` as
# remote.origin.gh-resolved=base, and then resolves bare PR creation to origin.
# This script is called by fm-bootstrap.sh's locked mutable path so a clone or
# linked worktree whose repository config lacks that gitignored binding repairs
# itself on its next ordinary session start. Repeated runs are idempotent.
#
# Usage: fm-pr-target-config.sh [--check]
#   With no flag, applies and verifies the origin binding.
#   --check verifies the binding without modifying repository config.
set -u

TARGET=wongsuwarn/firstmate
CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help)
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 1
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
ORIGIN=$(git -C "$ROOT" remote get-url origin 2>/dev/null) || { echo "error: origin remote is required" >&2; exit 1; }
case "$ORIGIN" in
  "https://github.com/$TARGET"|"https://github.com/$TARGET.git"|"git@github.com:$TARGET"|"git@github.com:$TARGET.git"|"ssh://git@github.com/$TARGET"|"ssh://git@github.com/$TARGET.git") ;;
  *) echo "error: origin must be github.com/$TARGET (got $ORIGIN)" >&2; exit 1 ;;
esac
command -v gh >/dev/null 2>&1 || { echo "error: gh is required" >&2; exit 1; }

if [ "$CHECK_ONLY" -eq 0 ]; then
  (cd "$ROOT" && gh repo set-default origin) || { echo "error: gh could not bind origin as its default repository" >&2; exit 1; }
fi
DEFAULT=$(cd "$ROOT" && gh repo set-default --view 2>/dev/null) || { echo "error: gh has no verifiable default repository" >&2; exit 1; }
[ "$DEFAULT" = "$TARGET" ] || { echo "error: gh default repository is $DEFAULT, expected $TARGET" >&2; exit 1; }

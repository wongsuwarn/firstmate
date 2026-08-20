#!/usr/bin/env bash
# Classify directly visible firstmate PR creation with the tracked parser.
set -u

CMD=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || exit 1; CMD=$2; shift 2 ;;
    *) exit 1 ;;
  esac
done
[ -n "$CMD" ] || exit 1

allow_unclassified() {
  printf '%s\n' "[pr-target-classification-unavailable] $1; PR-target classification did not run for this command; allowing it unguarded." >&2
  exit 3
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
POLICY="$SCRIPT_DIR/fm-pr-create-explicit-path-policy.mjs"
command -v node >/dev/null 2>&1 || allow_unclassified "Node is unavailable"
[ -f "$POLICY" ] || allow_unclassified "the policy file is missing"
result=$(node "$POLICY" --classify --command "$CMD" 2>/dev/null) \
  || allow_unclassified "the parser exited abnormally"
case "$result" in
  pr) exit 0 ;;
  not-pr) exit 1 ;;
  *) allow_unclassified "the parser returned an invalid result" ;;
esac

#!/usr/bin/env bash
# Route primary-harness PR checks and report unavailable classification.
set -u

CMD=
CMD_SET=0
CLAUDE_MODE=0
CODEX_MODE=0

allow_unclassified() {
  printf '%s\n' "[pr-target-classification-unavailable] $1; PR-target classification did not run for this command; allowing it unguarded." >&2
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || allow_unclassified "the command argument is missing"; CMD=$2; CMD_SET=1; shift 2 ;;
    --claude) CLAUDE_MODE=1; shift ;;
    --codex) CODEX_MODE=1; shift ;;
    *) exit 0 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  payload=$(cat 2>/dev/null) || allow_unclassified "the hook payload could not be read"
  [ -n "$payload" ] || allow_unclassified "the hook payload is empty"
  command -v jq >/dev/null 2>&1 || allow_unclassified "jq is unavailable"
  CMD=$(printf '%s' "$payload" | jq -er '(.toolInput.command // .tool_input.command) | select(type == "string" and length > 0)' 2>/dev/null) \
    || allow_unclassified "the hook payload does not contain a classifiable command"
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
CHECKER="$SCRIPT_DIR/fm-pr-create-pretool-check.sh"

if [ "$CODEX_MODE" -eq 1 ]; then
  [ -f "$ROOT/AGENTS.md" ] || allow_unclassified "the Codex project marker is missing"
  [ -f "$ROOT/.codex/hooks.json" ] || allow_unclassified "the Codex hook configuration is missing"
  jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-pr-create-hook-dispatch.sh"))' \
    "$ROOT/.codex/hooks.json" >/dev/null 2>&1 || allow_unclassified "Codex hook self-validation failed"
fi
[ -x "$CHECKER" ] || allow_unclassified "the checker is not executable"

checker_args=(--command "$CMD")
[ "$CLAUDE_MODE" -eq 0 ] || checker_args+=(--claude)
output=$("$CHECKER" "${checker_args[@]}")
status=$?
printf '%s' "$output"
case "$status" in
  0|2) exit "$status" ;;
  *) allow_unclassified "the checker exited abnormally" ;;
esac

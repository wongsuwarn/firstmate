#!/usr/bin/env bash
# Scope primary-harness checker failures to directly visible PR creation.
set -u

CMD=
CMD_SET=0
CLAUDE_MODE=0
CODEX_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || exit 0; CMD=$2; CMD_SET=1; shift 2 ;;
    --claude) CLAUDE_MODE=1; shift ;;
    --codex) CODEX_MODE=1; shift ;;
    *) exit 0 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  payload=$(cat 2>/dev/null) || exit 0
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$payload" | jq -er '(.toolInput.command // .tool_input.command) | select(type == "string" and length > 0)' 2>/dev/null) || exit 0
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
CHECKER="$SCRIPT_DIR/fm-pr-create-pretool-check.sh"
VISIBLE="$SCRIPT_DIR/fm-pr-create-visible-check.sh"

fallback() {
  [ -x "$VISIBLE" ] || exit 0
  if [ "$CLAUDE_MODE" -eq 1 ]; then
    exec "$VISIBLE" --command "$CMD" --deny-visible --claude
  fi
  exec "$VISIBLE" --command "$CMD" --deny-visible
}

if [ "$CODEX_MODE" -eq 1 ]; then
  [ -f "$ROOT/AGENTS.md" ] || fallback
  [ -f "$ROOT/.codex/hooks.json" ] || fallback
  jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains("fm-pr-create-hook-dispatch.sh"))' \
    "$ROOT/.codex/hooks.json" >/dev/null 2>&1 || fallback
fi
[ -x "$CHECKER" ] || fallback

checker_args=(--command "$CMD")
[ "$CLAUDE_MODE" -eq 0 ] || checker_args+=(--claude)
output=$("$CHECKER" "${checker_args[@]}")
status=$?
printf '%s' "$output"
case "$status" in
  0|2) exit "$status" ;;
  *) fallback ;;
esac

#!/usr/bin/env bash
# Verify the execution-boundary guard for firstmate-repository PR creation.
#
# The gh and gh-axi shims own the target decision after shell expansion.
# This hook transport refuses every Bash tool call unless those tracked shims
# are the active executable boundary. See docs/pr-target-guard.md.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-pr-create-pretool-check.sh
#   bin/fm-pr-create-pretool-check.sh --command '<cmd>' [--claude]
set -u

TARGET=wongsuwarn/firstmate
CMD=
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-pr-create-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin.
Refuses the shell command unless firstmate's gh and gh-axi execution wrappers
are active on PATH. Exits 0 to allow and 2 to deny.
EOF
}

emit_deny() {
  local detail=$1 escaped
  escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

deny_boundary() {
  emit_deny "[pr-target-boundary-unavailable] cannot verify the PR execution guard; relaunch with PATH=<firstmate>/bin/shims:\$PATH, then pass --repo $TARGET (and --base main) to PR creation."
}

deny_target() {
  emit_deny "[pr-target-required] a firstmate PR must explicitly pass --repo $TARGET (and --base main)."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }; CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null) || deny_boundary
  [ -n "$PAYLOAD" ] || deny_boundary
  command -v jq >/dev/null 2>&1 || deny_boundary
  CMD=$(printf '%s' "$PAYLOAD" | jq -er '(.toolInput.command // .tool_input.command) | select(type == "string" and length > 0)' 2>/dev/null) || deny_boundary
fi
[ -n "$CMD" ] || deny_boundary

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || deny_boundary
WRAPPER="$SCRIPT_DIR/fm-pr-create-wrapper.sh"
[ -x "$WRAPPER" ] || deny_boundary
FM_PR_CREATE_TOOL= FM_PR_CREATE_WRAPPER_INTERNAL=verify "$WRAPPER" >/dev/null 2>&1 || deny_boundary
POLICY="$SCRIPT_DIR/fm-pr-create-explicit-path-policy.mjs"
command -v node >/dev/null 2>&1 || deny_boundary
[ -f "$POLICY" ] || deny_boundary
POLICY_RESULT=$(node "$POLICY" --wrapper "$WRAPPER" --command "$CMD" 2>/dev/null) || deny_boundary
[ "$POLICY_RESULT" = allow ] && exit 0
[ "$POLICY_RESULT" = deny ] || deny_boundary
deny_target

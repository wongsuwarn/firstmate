#!/usr/bin/env bash
# Verify the execution-boundary guard for firstmate-repository PR creation.
#
# The gh and gh-axi shims own the target decision after shell expansion.
# This hook transport only verifies that boundary for visible PR creation.
# See docs/pr-target-guard.md.
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
Refuses visible PR creation unless firstmate's gh and gh-axi execution wrappers
are active on PATH and the command names the required target. Exits 0 to allow
and 2 to deny.
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

allow_unclassified() {
  printf '%s\n' "[pr-target-classification-unavailable] $1; PR-target classification did not run for this command; allowing it unguarded." >&2
  exit 0
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
  PAYLOAD=$(cat 2>/dev/null) || allow_unclassified "the hook payload could not be read"
  [ -n "$PAYLOAD" ] || allow_unclassified "the hook payload is empty"
  command -v jq >/dev/null 2>&1 || allow_unclassified "jq is unavailable"
  CMD=$(printf '%s' "$PAYLOAD" | jq -er '(.toolInput.command // .tool_input.command) | select(type == "string" and length > 0)' 2>/dev/null) \
    || allow_unclassified "the hook payload does not contain a classifiable command"
fi
[ -n "$CMD" ] || allow_unclassified "the command is empty"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
WRAPPER="$SCRIPT_DIR/fm-pr-create-wrapper.sh"
[ -x "$WRAPPER" ] || allow_unclassified "the wrapper is not executable"
VISIBLE="$SCRIPT_DIR/fm-pr-create-visible-check.sh"
[ -x "$VISIBLE" ] || allow_unclassified "the classifier is not executable"
"$VISIBLE" --command "$CMD" >/dev/null
VISIBLE_RESULT=$?
case "$VISIBLE_RESULT" in
  0) ;;
  1) exit 0 ;;
  *) exit 0 ;;
esac
POLICY="$SCRIPT_DIR/fm-pr-create-explicit-path-policy.mjs"
POLICY_RESULT=$(node "$POLICY" --wrapper "$WRAPPER" --command "$CMD" 2>/dev/null) \
  || allow_unclassified "the parser exited abnormally"
case "$POLICY_RESULT" in
  not-pr) exit 0 ;;
  deny) deny_target ;;
  pr-allowed) ;;
  *) allow_unclassified "the parser returned an invalid result" ;;
esac
FM_PR_CREATE_TOOL='' FM_PR_CREATE_WRAPPER_INTERNAL=verify "$WRAPPER" >/dev/null 2>&1 || deny_boundary

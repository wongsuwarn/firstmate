#!/usr/bin/env bash
# Stable PreToolUse transport for firstmate-repository PR target enforcement.
#
# The tracked hook wiring scopes this guard to firstmate checkouts. This script
# forwards the exact shell command to the semantic policy and renders the
# established harness-specific deny responses. See docs/pr-target-guard.md.
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

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
.toolInput.command, or Claude/Codex .tool_input.command).
In a firstmate checkout, refuses gh or gh-axi PR creation unless it passes
--repo wongsuwarn/firstmate explicitly.
Exits 0 to allow and 2 to deny.
EOF
}

emit_deny() {
  local code=$1 reason=$2 escaped
  escaped=$(printf '%s' "[$code] $reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

deny_unclassifiable() {
  emit_deny pr-target-unclassifiable "cannot safely verify the PR target: pass --repo $TARGET (and --base main) in a direct gh or gh-axi pr create command."
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
  PAYLOAD=$(cat 2>/dev/null) || deny_unclassifiable
  [ -n "$PAYLOAD" ] || deny_unclassifiable
  command -v jq >/dev/null 2>&1 || deny_unclassifiable
  CMD=$(printf '%s' "$PAYLOAD" | jq -er '(.toolInput.command // .tool_input.command) | select(type == "string" and length > 0)' 2>/dev/null) || deny_unclassifiable
fi
[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || deny_unclassifiable
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || deny_unclassifiable

POLICY="$ROOT/bin/fm-pr-create-command-policy.mjs"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$POLICY" ]; then
  deny_unclassifiable
fi

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || deny_unclassifiable
[ "$POLICY_OUTPUT" = allow ] && exit 0
TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || deny_unclassifiable
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || deny_unclassifiable
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || deny_unclassifiable

emit_deny "$CODE" "$REASON"

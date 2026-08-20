#!/usr/bin/env bash
# Stable PreToolUse transport for firstmate-repository PR target enforcement.
#
# It scopes the guard to a checkout whose origin is wongsuwarn/firstmate,
# forwards the exact shell command to the semantic policy, and renders the
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
In a wongsuwarn/firstmate checkout, refuses gh or gh-axi PR creation unless it
passes --repo wongsuwarn/firstmate explicitly.
Exits 0 to allow and 2 to deny.
EOF
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
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi
[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
command -v git >/dev/null 2>&1 || exit 0
ORIGIN=$(git -C "$ROOT" remote get-url origin 2>/dev/null) || exit 0
case "$ORIGIN" in
  "https://github.com/$TARGET"|"https://github.com/$TARGET.git"|"git@github.com:$TARGET"|"git@github.com:$TARGET.git"|"ssh://git@github.com/$TARGET"|"ssh://git@github.com/$TARGET.git") ;;
  *) exit 0 ;;
esac

POLICY="$ROOT/bin/fm-pr-create-command-policy.mjs"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$POLICY" ]; then
  case "$CMD" in
    *gh*|*pr*)
      DETAIL="[pr-target-unclassifiable] cannot safely verify the PR target: pass --repo $TARGET (and --base main) in a direct gh or gh-axi pr create command."
      ESCAPED=$(printf '%s' "$DETAIL" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
      [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
      exit 2
      ;;
    *) exit 0 ;;
  esac
fi

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

ESCAPED=$(printf '%s' "[$CODE] $REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2

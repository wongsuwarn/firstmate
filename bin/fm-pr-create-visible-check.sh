#!/usr/bin/env bash
# Classify directly visible firstmate PR creation without requiring the execution wrapper.
set -u

TARGET=wongsuwarn/firstmate
CMD=
DENY_VISIBLE=0
CLAUDE_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || exit 1; CMD=$2; shift 2 ;;
    --deny-visible) DENY_VISIBLE=1; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    *) exit 1 ;;
  esac
done
[ -n "$CMD" ] || exit 1

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
POLICY="$SCRIPT_DIR/fm-pr-create-explicit-path-policy.mjs"
visible=1
if command -v node >/dev/null 2>&1 && [ -f "$POLICY" ]; then
  node "$POLICY" --classify --command "$CMD" >/dev/null 2>&1
  visible=$?
else
  normalized=${CMD//$'\n'/;}
  pattern="(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]+[[:space:]]+)*((command|exec|nohup)[[:space:]]+|env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]+[[:space:]]+)*)?(([^[:space:];&|\"']+/)?(gh|gh-axi)|\"([^\"]*/)?(gh|gh-axi)\"|'([^']*/)?(gh|gh-axi)')[[:space:]]+pr[[:space:]]+create([[:space:];&|]|$)"
  if [[ $normalized =~ $pattern ]]; then visible=0; fi
fi

[ "$visible" -eq 0 ] || { [ "$DENY_VISIBLE" -eq 1 ] && exit 0; exit 1; }
[ "$DENY_VISIBLE" -eq 1 ] || exit 0
detail="[pr-target-boundary-unavailable] cannot verify the PR execution guard; relaunch with PATH=<firstmate>/bin/shims:\$PATH, then pass --repo $TARGET (and --base main) to PR creation."
escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
exit 2

#!/usr/bin/env bash
# Grok Stop-owned watcher auto-arm.
#
# Grok runs Stop hooks synchronously and permits exit 2 to keep the same turn
# working with the hook's stderr as feedback.  This hook therefore owns one
# foreground bin/fm-watch-arm.sh cycle between model turns.  When that cycle
# reports a watcher wake, this hook exits 2 to deliver it and the next Stop
# starts the successor without a model background-task call.  The hook lock
# admits only one home-scoped owner, AFK remains daemon-owned, and linked task
# worktrees stay inert through fm_primary_scope_matches.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$INTEGRATION_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.grok-autoarm.lock"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Do not arm for malformed input or the session-close Stop notification.
# Old Grok payloads did not include reason, so retain their ordinary Stop path.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -se 'length == 1 and (.[0] | type == "object") and ((.[0].reason? // "end_turn") == "end_turn")' >/dev/null 2>&1 || exit 0

# Scope: genuine primary checkout only.
fm_primary_scope_matches "$INTEGRATION_ROOT" "$STATE" || exit 0

# Identity: only the current lock-owning Grok session may supervise this home.
# A demonstrably dead numeric owner is recovered through fm-lock.sh after the
# AFK and need gates, exactly as the Claude Stop auto-arm does.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# AFK hands watcher ownership to the daemon.
[ -e "$STATE/.afk" ] && exit 0

need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# Grok may invoke multiple Stop hooks for one home concurrently.  A single
# foreground owner is the only process allowed to wait for this home's watcher.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

# Preserve X-mode cadence for the watcher exactly as the model-driven arm did.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

OUT=$(mktemp "$STATE/.grok-autoarm-output.XXXXXX") || {
  printf '%s\n' 'firstmate watcher auto-arm FAILED - no output file could be created for the Stop-owned supervision cycle.' >&2
  exit 2
}
trap 'rm -f "$OUT" 2>/dev/null || true; fm_lock_release "$OWNER_LOCK"' EXIT

"$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true

# AFK or completion can happen while the owner waits.
[ -e "$STATE/.afk" ] && exit 0
need_supervision || exit 0

if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null; then
  {
    printf '%s\n' 'firstmate watcher wake - one supervision event needs a handling turn now.'
    grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf '%s\n' 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns the next watcher cycle, so do not run bin/fm-watch-arm.sh after an ordinary wake.'
  } >&2
  exit 2
fi

# fm-watch-arm only exits a successful attached call after it found a live owner
# arm in this watcher's ancestry.  Recheck the watcher before accepting that
# short attach as a safe redundant call rather than the only remaining wait.
if grep -q '^watcher: attached pid=' "$OUT" 2>/dev/null \
  && fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
  exit 0
fi

{
  printf '%s\n' 'firstmate watcher auto-arm FAILED - the Stop-owned supervision cycle ended without a verified live successor.'
  grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
  printf '%s\n' 'Do not launch a manual background arm from this notice; the next Stop retries the automatic mechanism before the turn can end blind.'
} >&2
exit 2

#!/usr/bin/env bash
# Opt-in real-process Grok regression for Stop-owned watcher continuity.
#
# This uses the installed Grok binary, its real Stop-hook lifecycle, a real
# watcher, and a dedicated tmux socket.  It never substitutes a fake harness or
# a fake watcher for the lifecycle under test.
set -u

if [ "${FM_GROK_AUTOARM_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_AUTOARM_LIVE_E2E=1 to run the real Grok Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v grok >/dev/null 2>&1 || fail "grok not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-grok-autoarm-live-$$"
SESSION=grok-autoarm-live
LAB="$ROOT/.grok-autoarm-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
GROK_HOME="$LAB/grok-home"
GROK_VERSION=$(grok --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1200 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {
  local file=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -e "$file" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_live_pid_file() {
  local file=$1 attempts=${2:-240} i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(cat "$file" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && {
      printf '%s\n' "$pid"
      return 0
    }
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
# A candidate run must execute the branch under review, including uncommitted
# tracked edits.  New files are copied explicitly because git diff omits them.
git -C "$ROOT" diff --binary HEAD -- > "$LAB/candidate.patch"
[ ! -s "$LAB/candidate.patch" ] || git -C "$PROJECT" apply --whitespace=nowarn "$LAB/candidate.patch" || fail "could not apply candidate patch"
mkdir -p "$PROJECT/.grok/hooks"
cp "$ROOT/bin/fm-grok-stop-autoarm.sh" "$PROJECT/bin/fm-grok-stop-autoarm.sh"
cp "$ROOT/.grok/hooks/fm-primary-stop-autoarm.json" "$PROJECT/.grok/hooks/fm-primary-stop-autoarm.json"
chmod +x "$PROJECT/bin/fm-grok-stop-autoarm.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$GROK_HOME"
ln -s "$HOME/.grok/auth.json" "$GROK_HOME/auth.json"
printf 'project=fixture\n' > "$HOME_DIR/state/grok-autoarm-e2e.meta"
FM_GROK_SESSIONSTART_ROOT="$HOME_DIR/state/sessionstart-root" python3 - "$PROJECT/.grok/hooks/fm-sessionstart-live-probe.json" <<'PY'
import json
import os
import shlex
import sys
import tempfile

target = sys.argv[1]
root = os.environ["FM_GROK_SESSIONSTART_ROOT"]
command = "bash -lc " + shlex.quote(
    "printf '%s\\n' \"${GROK_WORKSPACE_ROOT:-missing}\" > " + shlex.quote(root)
    + "; printf '%s\\n' FM_GROK_SESSIONSTART_HOOK_MARK"
)
payload = {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": command, "timeout": 10}]}]}}
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(target))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
    handle.write("\n")
os.replace(temporary, target)
PY
# Project hooks become eligible only after Grok records the explicit trust.
# Prime that trust in an isolated one-shot session before measuring SessionStart.
GROK_HOME="$GROK_HOME" grok --trust --always-approve --reasoning-effort low --cwd "$PROJECT" -p 'Reply exactly TRUST_PRIMED.' >/dev/null \
  || fail "Grok $GROK_VERSION could not prime isolated project hook trust"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 GROK_HOME='$GROK_HOME' bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; exec grok --trust --always-approve --reasoning-effort low'"

# Let the real TUI reach its composer before injecting the single test prompt.
sleep 3
wait_for_file "$HOME_DIR/state/sessionstart-root" || fail "Grok $GROK_VERSION did not run the trusted SessionStart hook"
grep -Fqx "$PROJECT/" "$HOME_DIR/state/sessionstart-root" \
  || fail "Grok $GROK_VERSION did not provide GROK_WORKSPACE_ROOT to the SessionStart hook"
PROMPT='This is an isolated watcher-continuity regression. Reply exactly INITIAL_CONTEXT_HIDDEN unless SessionStart hook stdout was added to your model context, in which case reply exactly INITIAL_CONTEXT_VISIBLE. Do not use tools. If Stop-hook feedback arrives later, run no tools and reply exactly WAKE_HANDLED.'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text INITIAL_CONTEXT_HIDDEN || {
  capture >&2
  fail "Grok $GROK_VERSION exposed SessionStart stdout to model context"
}

first_watcher=$(wait_for_live_pid_file "$HOME_DIR/state/.watch.lock/pid") || {
  capture >&2
  fail "Grok $GROK_VERSION did not start a Stop-owned watcher"
}

printf 'done: Grok Stop auto-arm live watcher fire\n' > "$HOME_DIR/state/grok-autoarm-e2e.status"
wait_for_file "$HOME_DIR/state/.watch-cycle-exits.log" || fail "Grok did not write a watcher lifecycle ledger"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Grok Stop-owned watcher did not classify the actionable close"

# The post-wake Stop starts the successor itself.  A different live lock holder
# is the real-process proof that ordinary continuity did not depend on a model
# background arm command or a redundant attach completion.
i=0
second_watcher=
while [ "$i" -lt 240 ]; do
  second_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$second_watcher" ] && [ "$second_watcher" != "$first_watcher" ] \
    && kill -0 "$second_watcher" 2>/dev/null; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$second_watcher" ] || [ "$second_watcher" = "$first_watcher" ] \
  || ! kill -0 "$second_watcher" 2>/dev/null; then
  capture >&2
  fail "Grok did not start and retain a verified Stop-owned successor after the wake"
fi

printf 'ok - %s live E2E kept SessionStart stdout out of model context, started a Stop-owned watcher, delivered an actionable close, and retained a distinct live successor\n' "$GROK_VERSION"

#!/usr/bin/env bash
# Behavior tests for Grok Stop-owned watcher auto-arm.
#
# The hook owns a real fm-watch-arm.sh child between Grok turns.  Tests invoke
# the hook below a bash process named grok so the shared session-lock ancestry
# check remains part of the exercised behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/grok"
FAKE_GROK="$FAKEBIN/grok"

install_fixture() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  chmod +x "$dir/bin/fm-grok-stop-autoarm.sh" "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-watch.sh"
}

make_primary() {
  local dir=$1
  install_fixture "$dir"
  printf '%s\n' "$dir"
}

write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf '%s\n' 'signal: fixture.status done: watched worker finished'
SH
      ;;
    completion)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf '%s\n' 'signal: fixture.status done: watched worker finished'
SH
      ;;
    bare-attach)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 0s)\n' "$$"
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf '%s\n' 'watcher: FAILED - no live watcher with a fresh beacon'
exit 1
SH
      ;;
    fail-then-verified)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
attempt=$(wc -l < "$FM_HOME/state/arm-ran" | tr -d ' ')
if [ "$attempt" -eq 1 ]; then
  printf '%s\n' 'watcher: FAILED - no live watcher with a fresh beacon'
  exit 1
fi
. "$FM_HOME/bin/fm-wake-lib.sh"
watcher_pid=$(cat "$FM_HOME/state/recovery-watcher-pid")
watcher_identity=$(fm_pid_identity "$watcher_pid") || exit 1
watcher_path=$(cd "$FM_HOME/bin" && pwd)/fm-watch.sh
mkdir -p "$FM_HOME/state/.watch.lock"
printf '%s\n' "$watcher_pid" > "$FM_HOME/state/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
printf '%s\n' "$watcher_path" > "$FM_HOME/state/.watch.lock/watcher-path"
printf '%s\n' "$watcher_identity" > "$FM_HOME/state/.watch.lock/pid-identity"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 0s)\n' "$watcher_pid"
SH
      ;;
    *) fail "unknown arm fixture $kind" ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# shellcheck disable=SC2016 # The fake Grok child must expand FM_HOME after its parent writes the lock.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"sessionId":"grok-autoarm-test","reason":"end_turn","stopHookActive":false}' \
    | FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" PATH="$FAKEBIN:$PATH" \
      "$FAKE_GROK" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-grok-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

wait_for_text() {
  local file=$1 needle=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq "$needle" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_primary_actionable_close_rewakes_without_model_arm() {
  local dir out status
  dir=$(make_primary "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable Stop-owned watcher close must block Stop for handling"
  assert_present "$dir/state/arm-ran" "the Stop hook did not start the watcher arm"
  assert_contains "$out" "firstmate watcher wake" "the actionable close did not reach Grok Stop feedback"
  assert_contains "$out" "do not run bin/fm-watch-arm.sh after an ordinary wake" "the feedback left routine continuity to model memory"
  pass "grok auto-arm: actionable close wakes the same session without a model arm call"
}

test_afk_remains_daemon_owned() {
  local dir out status
  dir=$(make_primary "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK Stop hook path must stay quiet"
  [ ! -e "$dir/state/arm-ran" ] || fail "AFK Stop hook armed a parallel Grok watcher"
  [ -z "$out" ] || fail "AFK Stop hook produced feedback: $out"
  pass "grok auto-arm: AFK leaves watcher ownership to the daemon"
}

test_linked_task_worktree_is_inert() {
  local base dir out status
  base="$TMP_ROOT/linked-base"
  make_primary "$base" >/dev/null
  dir="$TMP_ROOT/linked-worktree"
  fm_git_worktree "$base" "$dir" fm/grok-autoarm-linked
  mkdir -p "$dir/state"
  cp -R "$ROOT/bin" "$dir/bin"
  chmod +x "$dir/bin/fm-grok-stop-autoarm.sh" "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-watch.sh"
  write_arm_fixture "$dir" actionable
  : > "$dir/state/task.meta"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a linked task worktree must not own Grok watcher supervision"
  [ ! -e "$dir/state/arm-ran" ] || fail "Grok Stop hook armed in a linked task worktree"
  [ -z "$out" ] || fail "linked task worktree Stop hook produced feedback: $out"
  pass "grok auto-arm: linked task worktree stays inert"
}

test_redundant_attach_keeps_existing_owner_wait() {
  local dir owner_out hook_out status owner_pid watcher_pid
  dir=$(make_primary "$TMP_ROOT/redundant")
  : > "$dir/state/task.meta"
  owner_out="$dir/owner.out"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$dir/bin/fm-watch-arm.sh" >"$owner_out" &
  owner_pid=$!
  wait_for_text "$owner_out" 'watcher: started pid=' || fail "real owner arm did not start: $(cat "$owner_out")"
  watcher_pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  kill -0 "$owner_pid" 2>/dev/null || fail "real owner arm was not live"
  kill -0 "$watcher_pid" 2>/dev/null || fail "real watcher was not live"

  hook_out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a redundant Stop arm must settle behind the existing owner"
  [ -z "$hook_out" ] || fail "redundant Stop arm produced unexpected feedback: $hook_out"
  kill -0 "$owner_pid" 2>/dev/null || fail "redundant Stop arm displaced the live owner wait"
  kill -0 "$watcher_pid" 2>/dev/null || fail "redundant Stop arm displaced the live watcher"
  kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  pass "grok auto-arm: redundant attach exits only behind a verified live owner wait"
}

test_bare_attach_is_not_accepted_as_a_live_wait() {
  local dir out status
  dir=$(make_primary "$TMP_ROOT/bare-attach")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" bare-attach
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an unverified attached line must not settle Grok supervision"
  assert_contains "$out" "without a verified live successor" "bare attached output was accepted as a live wait"
  pass "grok auto-arm: an immediate unverified attach cannot become the only wait"
}

test_failed_successor_retries_and_verifies_recovery() {
  local dir out status watcher_pid
  dir=$(make_primary "$TMP_ROOT/retry-success")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" fail-then-verified
  sleep 60 &
  watcher_pid=$!
  printf '%s\n' "$watcher_pid" > "$dir/state/recovery-watcher-pid"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a failed successor start must recover within the same Stop invocation"
  [ -z "$out" ] || fail "verified successor recovery produced unexpected feedback: $out"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "successor recovery did not retry exactly once"
  kill -0 "$watcher_pid" 2>/dev/null || fail "the verified recovery wait was not live when the hook reported success"
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  pass "grok auto-arm: failed successor retries and verifies recovery in the same invocation"
}

test_exhausted_recovery_stays_loud_and_unverified() {
  local dir out status
  dir=$(make_primary "$TMP_ROOT/retry-exhausted")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "exhausted successor recovery must block with visible failure feedback"
  assert_contains "$out" "exhausted 2 bounded attempts" "exhausted recovery did not report its in-invocation attempts"
  assert_contains "$out" "without a verified live successor" "exhausted recovery appeared watched without verification"
  assert_contains "$out" "supervision remains visibly unwatched" "exhausted recovery did not surface the blind session state"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "exhausted recovery did not consume both bounded attempts"
  pass "grok auto-arm: exhausted recovery remains loud and visibly unwatched"
}

test_completion_does_not_rewake_after_supervision_ends() {
  local dir out status
  dir=$(make_primary "$TMP_ROOT/completion")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" completion
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a completed fleet must let the Stop turn end"
  assert_present "$dir/state/arm-ran" "completion case never started the watcher arm"
  [ -z "$out" ] || fail "completion case unnecessarily blocked Stop: $out"
  pass "grok auto-arm: completion ends cleanly when no supervision remains"
}

test_primary_actionable_close_rewakes_without_model_arm
test_afk_remains_daemon_owned
test_linked_task_worktree_is_inert
test_redundant_attach_keeps_existing_owner_wait
test_bare_attach_is_not_accepted_as_a_live_wait
test_failed_successor_retries_and_verifies_recovery
test_exhausted_recovery_stays_loud_and_unverified
test_completion_does_not_rewake_after_supervision_ends

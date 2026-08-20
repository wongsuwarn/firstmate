#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for firstmate-repository PR target enforcement.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-create-pretool)
trap fm_test_cleanup EXIT
TARGET=wongsuwarn/firstmate

make_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-pr-create-pretool-check.sh" "$ROOT/bin/fm-pr-create-command-policy.mjs" \
    "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-pr-create-pretool-check.sh"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$TARGET.git"
  printf '%s\n' "$dir"
}

FIXTURE=$(make_fixture "$TMP_ROOT/fixture")
CHECK="$FIXTURE/bin/fm-pr-create-pretool-check.sh"

run_entry() {
  local entry=$1 command=$2 out=$3 err=$4
  case "$entry" in
    codex) jq -cn --arg command "$command" '{tool_input:{command:$command}}' | "$CHECK" >"$out" 2>"$err" ;;
    claude) jq -cn --arg command "$command" '{tool_input:{command:$command}}' | "$CHECK" --claude >"$out" 2>"$err" ;;
    grok) jq -cn --arg command "$command" '{toolInput:{command:$command}}' | "$CHECK" >"$out" 2>"$err" ;;
    opencode|pi) "$CHECK" --command "$command" >"$out" 2>"$err" ;;
    *) fail "unknown harness entry: $entry" ;;
  esac
}

expect_entry() {
  local expected entry command out err rc=0
  expected=$1
  entry=$2
  command=$3
  out="$TMP_ROOT/$entry.out"
  err="$TMP_ROOT/$entry.err"
  run_entry "$entry" "$command" "$out" "$err" || rc=$?
  if [ "$expected" = deny ]; then
    [ "$rc" -eq 2 ] || fail "$entry must deny '$command', got $rc"
    assert_grep 'pr-target-' "$err" "$entry deny must include a stable PR-target reason"
    assert_grep '--repo wongsuwarn/firstmate' "$err" "$entry deny must name the exact repair"
    if [ "$entry" = claude ]; then
      [ ! -s "$out" ] || fail "Claude deny must keep stdout empty"
    fi
  else
    [ "$rc" -eq 0 ] || fail "$entry must allow '$command', got $rc: $(cat "$err")"
    [ ! -s "$out" ] && [ ! -s "$err" ] || fail "$entry allow must be silent"
  fi
}

test_guard_matrix() {
  local entry
  for entry in codex claude grok opencode pi; do
    expect_entry deny "$entry" 'gh-axi pr create --title test'
    expect_entry deny "$entry" 'gh pr create --repo kunchenguid/firstmate --title test'
    expect_entry deny "$entry" 'gh pr create --repo wongsuwarn/firstmate --repo kunchenguid/firstmate'
    expect_entry deny "$entry" 'gh pr create --repo wongsuwarn/firstmate; gh-axi pr create --title test'
    expect_entry deny "$entry" "bash -lc 'gh pr create --title test'"
    expect_entry allow "$entry" 'gh-axi pr create --repo wongsuwarn/firstmate --base main --title test'
    expect_entry allow "$entry" "bash -lc 'gh pr create --repo wongsuwarn/firstmate --base main'"
    expect_entry allow "$entry" 'git status --short'
  done
  pass "PR target guard denies bare and wrong-target creation, permits explicit correct target and unrelated commands through every harness transport"
}

test_guard_survives_origin_change() {
  git -C "$FIXTURE" remote set-url origin https://github.com/kunchenguid/firstmate.git
  expect_entry deny codex 'gh pr create --title test'
  expect_entry allow codex 'git status --short'
  pass "PR target guard remains active when the checkout origin changes"
}

test_transport_and_classifier_fail_closed() {
  local broken check out err rc=0
  broken=$(make_fixture "$TMP_ROOT/broken")
  check="$broken/bin/fm-pr-create-pretool-check.sh"
  out="$TMP_ROOT/broken.out"
  err="$TMP_ROOT/broken.err"
  printf '%s' '{' | "$check" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "malformed hook transport must deny, got $rc"
  assert_grep 'pr-target-unclassifiable' "$err" "malformed hook transport deny must name its reason"
  printf '%s\n' 'invalid javascript' > "$broken/bin/fm-pr-create-command-policy.mjs"
  rc=0
  "$check" --command 'git status --short' >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "classifier failure must deny, got $rc"
  assert_grep 'pr-target-unclassifiable' "$err" "classifier failure deny must name its reason"
  pass "PR target hook transport and classifier failures deny unverified commands"
}

test_policy_refuses_ambiguous_pr_create() {
  local out
  out=$(node "$FIXTURE/bin/fm-pr-create-command-policy.mjs" --command "gh pr create 'unterminated" 2>&1) || true
  assert_contains "$out" 'deny	pr-target-unclassifiable' "malformed PR create must refuse rather than allow"
  pass "PR target policy refuses an unclassifiable PR-create command"
}

make_config_fixture() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$dir/bin" "$fakebin"
  cp "$ROOT/bin/fm-pr-target-config.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-pr-target-config.sh"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$TARGET.git"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'repo set-default origin') git config remote.origin.gh-resolved base ;;
  'repo set-default --view') git config --get remote.origin.gh-resolved >/dev/null && printf '%s\n' wongsuwarn/firstmate ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

test_binding_converges_idempotently() {
  local fixture before after
  fixture=$(make_config_fixture "$TMP_ROOT/config")
  before=$(git -C "$fixture" config --get remote.origin.gh-resolved || true)
  [ -z "$before" ] || fail "fixture unexpectedly began bound"
  PATH="$fixture/fakebin:$PATH" "$fixture/bin/fm-pr-target-config.sh" || fail "first binding application failed"
  after=$(git -C "$fixture" config --get remote.origin.gh-resolved)
  [ "$after" = base ] || fail "binding did not write gh's resolved-origin value"
  PATH="$fixture/fakebin:$PATH" "$fixture/bin/fm-pr-target-config.sh" || fail "second binding application was not idempotent"
  PATH="$fixture/fakebin:$PATH" "$fixture/bin/fm-pr-target-config.sh" --check || fail "binding check did not accept converged config"
  pass "PR target binding converges a clone and remains idempotent through its executable interface"
}

test_guard_matrix
test_guard_survives_origin_change
test_transport_and_classifier_fail_closed
test_policy_refuses_ambiguous_pr_create
test_binding_converges_idempotently

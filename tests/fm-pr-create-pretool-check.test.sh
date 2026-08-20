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
  mkdir -p "$dir/bin/shims" "$dir/fakebin"
  cp "$ROOT/bin/fm-pr-create-pretool-check.sh" "$ROOT/bin/fm-pr-create-wrapper.sh" \
    "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/shims/gh" "$ROOT/bin/shims/gh-axi" "$dir/bin/shims/"
  chmod +x "$dir/bin/fm-pr-create-pretool-check.sh" "$dir/bin/fm-pr-create-wrapper.sh" \
    "$dir/bin/shims/gh" "$dir/bin/shims/gh-axi"
  for tool in gh gh-axi; do
    cat > "$dir/fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_GH_LOG:?}"
SH
    chmod +x "$dir/fakebin/$tool"
  done
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$TARGET.git"
  printf '%s\n' "$dir"
}

FIXTURE=$(make_fixture "$TMP_ROOT/fixture")
CHECK="$FIXTURE/bin/fm-pr-create-pretool-check.sh"
GUARD_PATH="$FIXTURE/bin/shims:$FIXTURE/fakebin:$PATH"
NO_SHIM_PATH="$FIXTURE/fakebin:$(dirname "$(command -v node)"):/usr/bin:/bin"
GH_LOG="$TMP_ROOT/gh.log"

run_entry() {
  local entry=$1 command=$2 out=$3 err=$4 checker=${5:-$CHECK} path=${6:-$GUARD_PATH}
  case "$entry" in
    codex) jq -cn --arg command "$command" '{tool_input:{command:$command}}' | env PATH="$path" "$checker" >"$out" 2>"$err" ;;
    claude) jq -cn --arg command "$command" '{tool_input:{command:$command}}' | env PATH="$path" "$checker" --claude >"$out" 2>"$err" ;;
    grok) jq -cn --arg command "$command" '{toolInput:{command:$command}}' | env PATH="$path" "$checker" >"$out" 2>"$err" ;;
    opencode|pi) env PATH="$path" "$checker" --command "$command" >"$out" 2>"$err" ;;
    *) fail "unknown harness entry: $entry" ;;
  esac
}

expect_entry() {
  local expected=$1 entry=$2 command=$3 checker=${4:-$CHECK} path=${5:-$GUARD_PATH} out err rc=0
  out="$TMP_ROOT/$entry.out"
  err="$TMP_ROOT/$entry.err"
  run_entry "$entry" "$command" "$out" "$err" "$checker" "$path" || rc=$?
  if [ "$expected" = deny ] || [ "$expected" = deny-target ]; then
    [ "$rc" -eq 2 ] || fail "$entry must deny an unavailable boundary, got $rc"
    if [ "$expected" = deny-target ]; then
      assert_grep 'pr-target-required' "$err" "$entry deny must include the stable target reason"
    else
      assert_grep 'pr-target-boundary-unavailable' "$err" "$entry deny must include a stable boundary reason"
    fi
    if [ "$entry" = claude ]; then
      [ ! -s "$out" ] || fail "Claude deny must keep stdout empty"
    fi
  else
    [ "$rc" -eq 0 ] || fail "$entry must accept a healthy boundary, got $rc: $(cat "$err")"
    [ ! -s "$out" ] && [ ! -s "$err" ] || fail "$entry healthy-boundary allow must be silent"
  fi
}

run_guarded_shell() {
  local command=$1 rc=0
  : > "$GH_LOG"
  RUN_OUT=$(cd "$FIXTURE" && env PATH="$GUARD_PATH" FM_GH_LOG="$GH_LOG" bash -c "$command" 2>&1) || rc=$?
  return "$rc"
}

expect_shell() {
  local expected=$1 command=$2 rc=0
  run_guarded_shell "$command" || rc=$?
  if [ "$expected" = deny ]; then
    [ "$rc" -eq 2 ] || fail "wrapper must deny '$command', got $rc: $RUN_OUT"
    assert_contains "$RUN_OUT" 'pr-target-required' "wrapper denial must name its stable reason"
  else
    [ "$rc" -eq 0 ] || fail "wrapper must allow '$command', got $rc: $RUN_OUT"
  fi
}

test_wrapper_boundary_matrix() {
  expect_shell deny 'gh pr create --title test'
  expect_shell deny 'gh-axi pr create --title test'
  expect_shell deny 'gh pr create --repo kunchenguid/firstmate --title test'
  expect_shell deny 'gh pr create --repo wongsuwarn/firstmate --title test'
  expect_shell deny 'gh pr create --repo wongsuwarn/firstmate --repo kunchenguid/firstmate'
  expect_shell deny 'gh pr create --repo wongsuwarn/firstmate -R kunchenguid/firstmate'
  expect_shell deny 'gh pr create --repo wongsuwarn/firstmate; gh-axi pr create --title test'
  expect_shell deny "bash -c 'gh pr create --title test'"
  # shellcheck disable=SC2016 # The command must expand G only when the checked shell evaluates it.
  expect_shell deny 'G=gh; "$G" pr create --title test'
  expect_shell deny 'gh pr create --repo'
  expect_shell allow 'gh-axi pr create --repo wongsuwarn/firstmate --base main --title test'
  expect_shell allow "bash -c 'gh pr create --repo wongsuwarn/firstmate --base main'"
  expect_shell allow "echo 'gh pr create documentation'"
  [ ! -s "$GH_LOG" ] || fail "quoted PR documentation text unexpectedly executed gh"
  expect_shell allow 'true # gh pr create'
  [ ! -s "$GH_LOG" ] || fail "commented PR text unexpectedly executed gh"
  expect_shell allow 'git status --short'
  pass "gh and gh-axi wrappers enforce expanded PR arguments without matching quoted text or comments"
}

test_private_verify_mode_preserves_public_command() {
  local rc=0
  env PATH="$GUARD_PATH" FM_PR_CREATE_TOOL= FM_PR_CREATE_WRAPPER_INTERNAL=verify \
    "$FIXTURE/bin/fm-pr-create-wrapper.sh" || rc=$?
  [ "$rc" -eq 0 ] || fail "private wrapper verification mode failed with $rc"
  expect_shell allow 'gh verify'
  [ "$(cat "$GH_LOG")" = 'gh verify' ] || fail "public gh verify did not reach the real executable"
  expect_shell allow 'FM_PR_CREATE_WRAPPER_INTERNAL=verify gh verify'
  [ "$(cat "$GH_LOG")" = 'gh verify' ] || fail "a caller environment shadowed the public gh verify command"
  pass "private boundary verification does not reserve the public gh verify command"
}

test_detectable_top_level_explicit_paths_are_checked() {
  local literal_path=$FIXTURE/fakebin/gh
  expect_entry deny-target codex "$literal_path pr create --title test"
  expect_entry allow codex "$literal_path pr create --repo wongsuwarn/firstmate --base main"
  expect_entry deny-target codex "PATH=$FIXTURE/fakebin:\$PATH gh pr create --title test"
  expect_entry allow codex "PATH=$FIXTURE/fakebin:\$PATH gh pr create --repo wongsuwarn/firstmate --base main"
  pass "detectable top-level literal-path and command-local-PATH PR calls receive target checks"
}

test_all_harness_transports_scope_boundary_enforcement() {
  local entry broken broken_check broken_path
  for entry in codex claude grok opencode pi; do
    expect_entry allow "$entry" 'echo hello' "$CHECK" "$NO_SHIM_PATH"
    expect_entry allow "$entry" 'ls' "$CHECK" "$NO_SHIM_PATH"
    expect_entry deny-target "$entry" 'gh pr create --title test' "$CHECK" "$NO_SHIM_PATH"
    expect_entry allow "$entry" 'gh pr create --repo wongsuwarn/firstmate --base main --title test'
  done
  broken=$(make_fixture "$TMP_ROOT/broken-boundary")
  broken_check="$broken/bin/fm-pr-create-pretool-check.sh"
  chmod -x "$broken/bin/shims/gh"
  broken_path="$broken/bin/shims:$broken/fakebin:$PATH"
  for entry in codex claude grok opencode pi; do
    expect_entry allow "$entry" 'git status --short' "$broken_check" "$broken_path"
    expect_entry deny-target "$entry" 'gh pr create --title test' "$broken_check" "$broken_path"
    expect_entry deny "$entry" 'gh pr create --repo wongsuwarn/firstmate --base main --title test' "$broken_check" "$broken_path"
  done
  pass "every primary harness transport scopes boundary enforcement to visible PR creation"
}

test_guard_survives_origin_change() {
  git -C "$FIXTURE" remote set-url origin https://github.com/kunchenguid/firstmate.git
  expect_shell deny 'gh pr create --title test'
  expect_shell allow 'gh pr create --repo wongsuwarn/firstmate --base main'
  pass "PR target wrapper remains active when the checkout origin changes"
}

test_malformed_transport_leaves_unrelated_commands_alone() {
  local out="$TMP_ROOT/malformed.out" err="$TMP_ROOT/malformed.err" rc=0
  printf '%s' '{' | env PATH="$GUARD_PATH" "$CHECK" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed hook transport must not deny an unknown command, got $rc"
  [ ! -s "$out" ] && [ ! -s "$err" ] || fail "malformed hook transport must remain silent"
  pass "malformed PR-target hook transport leaves unrelated commands alone"
}

test_opencode_adapter_failures_leave_unrelated_commands_alone() {
  local plugin=$ROOT/.opencode/plugins/fm-pr-create-pretool-check.js missing signal out status=0
  missing="$TMP_ROOT/opencode-missing"
  signal="$TMP_ROOT/opencode-signal"
  mkdir -p "$missing/bin" "$signal/bin"
  cat > "$signal/bin/fm-pr-create-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
kill -TERM $$
SH
  chmod +x "$signal/bin/fm-pr-create-pretool-check.sh"
  out=$(PLUGIN="$plugin" MISSING="$missing" SIGNAL="$signal" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?failure=${Date.now()}`);
for (const root of [process.env.MISSING, process.env.SIGNAL]) {
  const hooks = await mod.FmPrCreatePretoolCheck({ worktree: root });
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "git status" } });
}
JS
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode adapter failure test failed: $out"
  [ -z "$out" ] || fail "OpenCode adapter failure test printed output: $out"
  pass "OpenCode leaves unrelated commands alone on checker spawn failure and signal termination"
}

make_pi_adapter_fixture() {
  local repo=$1 mode=$2
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/state"
  git -C "$repo" init -q
  : > "$repo/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-primary-scope.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-primary-scope.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$repo/bin/"
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  if [ "$mode" = signal ]; then
    cat > "$repo/bin/fm-pr-create-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
kill -TERM $$
SH
    chmod +x "$repo/bin/fm-pr-create-pretool-check.sh"
  fi
  chmod +x "$repo/bin/fm-cd-pretool-check.sh" "$repo/bin/fm-arm-pretool-check.sh" "$repo/bin/fm-primary-scope.sh"
}

run_pi_adapter_case() {
  local repo=$1 out status=0
  out=$(PLUGIN="$repo/.pi/extensions/fm-primary-turnend-guard.ts" FM_HOME="$repo" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?failure=${Date.now()}`);
mod.default(pi);
const handler = handlers.get("tool_call");
if (!handler) throw new Error("Pi tool_call handler was not registered");
const result = await handler({ type: "tool_call", toolName: "bash", input: { command: "git status" } });
if (result?.block === true) throw new Error("Pi blocked an unrelated command after PR checker failure");
JS
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi adapter failure test failed: $out"
  [ -z "$out" ] || fail "Pi adapter failure test printed output: $out"
}

test_pi_adapter_failures_leave_unrelated_commands_alone() {
  local missing="$TMP_ROOT/pi-missing" signal="$TMP_ROOT/pi-signal"
  make_pi_adapter_fixture "$missing" missing
  make_pi_adapter_fixture "$signal" signal
  run_pi_adapter_case "$missing"
  run_pi_adapter_case "$signal"
  pass "Pi and pi-signed leave unrelated commands alone on checker spawn failure and signal termination"
}

test_codex_adapter_preconditions_leave_unrelated_commands_alone() {
  local hook fixture payload out status=0
  hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-pretool-check.sh")) | .command' "$ROOT/.codex/hooks.json")
  [ -n "$hook" ] || fail "Codex PR-target hook command is missing"
  payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
  fixture="$TMP_ROOT/codex-precondition"
  mkdir -p "$fixture/.codex" "$fixture/bin"
  : > "$fixture/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$fixture/.codex/hooks.json"
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex missing-checker precondition must allow unrelated commands, got $status: $out"
  [ -z "$out" ] || fail "Codex missing-checker precondition printed output: $out"
  cp "$ROOT/bin/fm-pr-create-pretool-check.sh" "$fixture/bin/"
  chmod +x "$fixture/bin/fm-pr-create-pretool-check.sh"
  printf '%s\n' '{}' > "$fixture/.codex/hooks.json"
  status=0
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex hook self-validation failure must allow unrelated commands, got $status: $out"
  [ -z "$out" ] || fail "Codex hook self-validation failure printed output: $out"
  pass "Codex leaves unrelated commands alone when checker preconditions are unavailable"
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

test_bootstrap_root_override_binds_selected_checkout() {
  local case_dir=$TMP_ROOT/bootstrap-root source_root selected_root fakebin out
  source_root=$case_dir/source
  selected_root=$case_dir/selected
  fakebin=$case_dir/fakebin
  mkdir -p "$source_root" "$selected_root" "$fakebin"
  cp -R "$ROOT/bin" "$source_root/"
  git init -q -b main "$source_root"
  git -C "$source_root" remote add origin "https://github.com/$TARGET.git"
  git init -q -b main "$selected_root"
  git -C "$selected_root" remote add origin "https://github.com/$TARGET.git"
  : > "$selected_root/.fm-secondmate-home"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1-} ${2-}" in
  'auth status') exit 0 ;;
  'repo set-default')
    case "${3-}" in
      origin) git config remote.origin.gh-resolved base ;;
      --view) git config --get remote.origin.gh-resolved >/dev/null && printf '%s\n' wongsuwarn/firstmate ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$selected_root" \
    FM_ROOT_OVERRIDE="$selected_root" "$source_root/bin/fm-bootstrap.sh" 2>&1) \
    || fail "bootstrap with an overridden root failed: $out"
  [ "$(git -C "$selected_root" config --get remote.origin.gh-resolved)" = base ] \
    || fail "bootstrap did not bind the selected checkout"
  [ -z "$(git -C "$source_root" config --get remote.origin.gh-resolved || true)" ] \
    || fail "bootstrap bound its invoking checkout instead of the selected checkout"
  pass "bootstrap root override binds and verifies the selected checkout"
}

test_wrapper_boundary_matrix
test_private_verify_mode_preserves_public_command
test_detectable_top_level_explicit_paths_are_checked
test_all_harness_transports_scope_boundary_enforcement
test_guard_survives_origin_change
test_malformed_transport_leaves_unrelated_commands_alone
test_opencode_adapter_failures_leave_unrelated_commands_alone
test_pi_adapter_failures_leave_unrelated_commands_alone
test_codex_adapter_preconditions_leave_unrelated_commands_alone
test_binding_converges_idempotently
test_bootstrap_root_override_binds_selected_checkout

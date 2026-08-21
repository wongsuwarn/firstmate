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
  # shellcheck disable=SC2153 # ROOT is provided by tests/lib.sh.
  cp "$ROOT/bin/fm-pr-create-pretool-check.sh" "$ROOT/bin/fm-pr-create-hook-dispatch.sh" \
    "$ROOT/bin/fm-pr-create-visible-check.sh" "$ROOT/bin/fm-pr-create-wrapper.sh" \
    "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/shims/gh" "$ROOT/bin/shims/gh-axi" "$dir/bin/shims/"
  chmod +x "$dir/bin/fm-pr-create-pretool-check.sh" "$dir/bin/fm-pr-create-hook-dispatch.sh" \
    "$dir/bin/fm-pr-create-visible-check.sh" "$dir/bin/fm-pr-create-wrapper.sh" \
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
  elif [ "$expected" = warn ]; then
    [ "$rc" -eq 0 ] || fail "$entry must allow an unclassified command, got $rc: $(cat "$err")"
    [ ! -s "$out" ] || fail "$entry unclassified allow must keep stdout empty"
    assert_grep 'pr-target-classification-unavailable' "$err" "$entry unclassified allow omitted its stable diagnostic"
    assert_grep 'classification did not run for this command' "$err" "$entry unclassified allow omitted its consequence"
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
  local literal_path=$FIXTURE/fakebin/gh heredoc
  heredoc="cat <<'EOF'
gh pr create
EOF"
  expect_entry deny-target codex "$literal_path pr create --title test"
  expect_entry allow codex "$literal_path pr create --repo wongsuwarn/firstmate --base main"
  expect_entry deny-target codex "PATH=$FIXTURE/fakebin:\$PATH gh pr create --title test"
  expect_entry allow codex "PATH=$FIXTURE/fakebin:\$PATH gh pr create --repo wongsuwarn/firstmate --base main"
  expect_entry deny-target codex 'sudo gh pr create --title test'
  expect_entry deny-target codex 'timeout 10 gh pr create --title test'
  expect_entry allow codex "$heredoc"
  expect_entry deny-target codex 'gh pr create --repo wongsuwarn/firstmate --base main; /usr/bin/gh pr create --repo wrong/repo --base main'
  pass "detectable top-level literal-path and command-local-PATH PR calls receive target checks"
}

test_unavailable_dependencies_allow_with_diagnostic() {
  local fixture checker heredoc path
  heredoc="cat <<'EOF'
gh pr create
EOF"
  fixture=$(make_fixture "$TMP_ROOT/missing-wrapper")
  checker="$fixture/bin/fm-pr-create-pretool-check.sh"
  path="$fixture/bin/shims:$fixture/fakebin:$PATH"
  chmod -x "$fixture/bin/fm-pr-create-wrapper.sh"
  expect_entry warn codex 'echo hello' "$checker" "$path"
  assert_grep 'wrapper is not executable' "$TMP_ROOT/codex.err" "missing-wrapper diagnostic omitted its prerequisite"
  expect_entry warn codex "$heredoc" "$checker" "$path"
  expect_entry warn codex 'gh pr create --repo wongsuwarn/firstmate --base main' "$checker" "$path"

  fixture=$(make_fixture "$TMP_ROOT/missing-node")
  checker="$fixture/bin/fm-pr-create-pretool-check.sh"
  path="$fixture/bin/shims:$fixture/fakebin:/usr/bin:/bin"
  expect_entry warn codex 'echo hello' "$checker" "$path"
  assert_grep 'Node is unavailable' "$TMP_ROOT/codex.err" "missing-Node diagnostic omitted its prerequisite"
  expect_entry warn codex "$heredoc" "$checker" "$path"
  expect_entry warn codex 'gh pr create --repo wongsuwarn/firstmate --base main' "$checker" "$path"

  fixture=$(make_fixture "$TMP_ROOT/missing-policy")
  checker="$fixture/bin/fm-pr-create-pretool-check.sh"
  path="$fixture/bin/shims:$fixture/fakebin:$PATH"
  rm "$fixture/bin/fm-pr-create-explicit-path-policy.mjs"
  expect_entry warn codex 'echo hello' "$checker" "$path"
  assert_grep 'policy file is missing' "$TMP_ROOT/codex.err" "missing-policy diagnostic omitted its prerequisite"
  expect_entry warn codex "$heredoc" "$checker" "$path"
  expect_entry warn codex 'gh pr create --repo wongsuwarn/firstmate --base main' "$checker" "$path"

  fixture=$(make_fixture "$TMP_ROOT/abnormal-parser")
  checker="$fixture/bin/fm-pr-create-pretool-check.sh"
  path="$fixture/bin/shims:$fixture/fakebin:$PATH"
  printf '%s\n' 'this is not JavaScript' > "$fixture/bin/fm-pr-create-explicit-path-policy.mjs"
  expect_entry warn codex 'echo hello' "$checker" "$path"
  assert_grep 'parser exited abnormally' "$TMP_ROOT/codex.err" "abnormal-parser diagnostic omitted its prerequisite"
  expect_entry warn codex "$heredoc" "$checker" "$path"
  expect_entry warn codex 'gh pr create --repo wongsuwarn/firstmate --base main' "$checker" "$path"
  pass "unavailable parser prerequisites allow commands with a loud diagnostic"
}

test_all_harness_transports_scope_boundary_enforcement() {
  local entry broken broken_check broken_path heredoc
  heredoc="cat <<'EOF'
gh pr create
EOF"
  for entry in codex claude grok opencode pi; do
    expect_entry allow "$entry" 'echo hello' "$CHECK" "$NO_SHIM_PATH"
    expect_entry allow "$entry" 'ls' "$CHECK" "$NO_SHIM_PATH"
    expect_entry deny-target "$entry" 'gh pr create --title test' "$CHECK" "$NO_SHIM_PATH"
    expect_entry allow "$entry" 'gh pr create --repo wongsuwarn/firstmate --base main --title test'
    expect_entry allow "$entry" "$heredoc"
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

test_malformed_transport_allows_with_diagnostic() {
  local out="$TMP_ROOT/malformed.out" err="$TMP_ROOT/malformed.err" rc=0
  printf '%s' '{' | env PATH="$GUARD_PATH" "$CHECK" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed hook transport must not deny an unknown command, got $rc"
  [ ! -s "$out" ] || fail "malformed hook transport must keep stdout empty"
  assert_grep 'pr-target-classification-unavailable' "$err" "malformed hook transport omitted its diagnostic"
  pass "malformed PR-target hook transport allows with a loud diagnostic"
}

make_dispatch_result_fixture() {
  local dir=$1
  mkdir -p "$dir/.codex" "$dir/bin"
  : > "$dir/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cp "$ROOT/bin/fm-pr-create-hook-dispatch.sh" "$dir/bin/"
  cat > "$dir/bin/fm-pr-create-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2-}" in
  *'gh pr create'*)
    printf '%s\n' '{"decision":"deny","reason":"synthetic denial"}'
    case "${FM_TEST_CHECKER_RESULT:?}" in
      abnormal) exit 3 ;;
      deny) exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$dir/bin/fm-pr-create-hook-dispatch.sh" "$dir/bin/fm-pr-create-pretool-check.sh"
}

run_dispatch_result_case() {
  local entry=$1 mode=$2 command=$3 fixture=$4 out=$5 err=$6
  case "$entry" in
    codex)
      jq -cn --arg command "$command" '{tool_input:{command:$command}}' \
        | (cd "$fixture" && env FM_TEST_CHECKER_RESULT="$mode" "$fixture/bin/fm-pr-create-hook-dispatch.sh" --codex) >"$out" 2>"$err"
      ;;
    claude)
      jq -cn --arg command "$command" '{tool_input:{command:$command}}' \
        | env FM_TEST_CHECKER_RESULT="$mode" "$fixture/bin/fm-pr-create-hook-dispatch.sh" --claude >"$out" 2>"$err"
      ;;
    grok)
      jq -cn --arg command "$command" '{toolInput:{command:$command}}' \
        | env FM_TEST_CHECKER_RESULT="$mode" "$fixture/bin/fm-pr-create-hook-dispatch.sh" >"$out" 2>"$err"
      ;;
    opencode|pi)
      env FM_TEST_CHECKER_RESULT="$mode" "$fixture/bin/fm-pr-create-hook-dispatch.sh" \
        --command "$command" >"$out" 2>"$err"
      ;;
  esac
}

test_checker_output_requires_recognized_status() {
  local command entry err fixture mode out rc
  fixture="$TMP_ROOT/dispatch-result"
  make_dispatch_result_fixture "$fixture"
  for entry in codex claude grok opencode pi; do
    for mode in abnormal deny; do
      out="$TMP_ROOT/$entry-$mode.out"
      err="$TMP_ROOT/$entry-$mode.err"
      rc=0
      run_dispatch_result_case "$entry" "$mode" 'git status' "$fixture" "$out" "$err" || rc=$?
      [ "$rc" -eq 0 ] || fail "$entry $mode checker changed an ordinary command result: $rc"
      [ ! -s "$out" ] && [ ! -s "$err" ] || fail "$entry $mode checker changed ordinary command output"

      rc=0
      command='gh pr create --repo wongsuwarn/firstmate --base main'
      run_dispatch_result_case "$entry" "$mode" "$command" "$fixture" "$out" "$err" || rc=$?
      if [ "$mode" = abnormal ]; then
        [ "$rc" -eq 0 ] || fail "$entry abnormal checker must allow, got $rc"
        [ ! -s "$out" ] || fail "$entry abnormal checker replayed an incomplete denial: $(cat "$out")"
        assert_grep 'pr-target-classification-unavailable' "$err" "$entry abnormal checker omitted its diagnostic"
      else
        [ "$rc" -eq 2 ] || fail "$entry completed denial must refuse, got $rc"
        assert_grep 'synthetic denial' "$out" "$entry completed denial output was not replayed"
      fi
    done
  done
  pass "checker output is replayed only for recognized statuses across harnesses"
}

test_opencode_adapter_failures_allow_with_diagnostic() {
  local plugin=$ROOT/.opencode/plugins/fm-pr-create-pretool-check.js missing signal out root status=0
  missing="$TMP_ROOT/opencode-missing"
  signal="$TMP_ROOT/opencode-signal"
  mkdir -p "$missing/bin" "$signal/bin"
  for root in "$missing" "$signal"; do
    cp "$ROOT/bin/fm-pr-create-hook-dispatch.sh" "$ROOT/bin/fm-pr-create-visible-check.sh" \
      "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$root/bin/"
    chmod +x "$root/bin/fm-pr-create-hook-dispatch.sh" "$root/bin/fm-pr-create-visible-check.sh"
  done
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
  for (const command of [
    "git status",
    "cat <<'EOF'\ngh pr create\nEOF",
    "gh pr create --repo wongsuwarn/firstmate --base main",
  ]) {
    await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } });
  }
}
JS
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode adapter failure test failed: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "OpenCode checker failure omitted its diagnostic"
  assert_contains "$out" 'classification did not run for this command' "OpenCode checker failure omitted its consequence"
  pass "OpenCode allows checker failures with a loud diagnostic"
}

test_direct_hook_adapter_failures_allow_with_diagnostic() {
  local adapter command hook mode fixture payload out status
  for mode in missing signal; do
    fixture="$TMP_ROOT/direct-$mode"
    mkdir -p "$fixture/bin"
    cp "$ROOT/bin/fm-pr-create-hook-dispatch.sh" "$ROOT/bin/fm-pr-create-visible-check.sh" \
      "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$fixture/bin/"
    chmod +x "$fixture/bin/fm-pr-create-hook-dispatch.sh" "$fixture/bin/fm-pr-create-visible-check.sh"
    if [ "$mode" = signal ]; then
      cat > "$fixture/bin/fm-pr-create-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
kill -TERM $$
SH
      chmod +x "$fixture/bin/fm-pr-create-pretool-check.sh"
    fi
    for adapter in claude grok; do
      case "$adapter" in
        claude)
          hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-hook-dispatch.sh")) | .command' "$ROOT/.claude/settings.json")
          payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
          status=0
          out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$fixture" bash -c "$hook" 2>&1) || status=$?
          ;;
        grok)
          hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-hook-dispatch.sh")) | .command' "$ROOT/.grok/hooks/fm-pr-create-pretool-check.json")
          payload=$(jq -cn --arg command 'git status' '{toolInput:{command:$command}}')
          status=0
          out=$(printf '%s' "$payload" | GROK_WORKSPACE_ROOT="$fixture" bash -c "$hook" 2>&1) || status=$?
          ;;
      esac
      [ "$status" -eq 0 ] || fail "$adapter $mode checker blocked an unrelated command: $out"
      assert_contains "$out" 'pr-target-classification-unavailable' "$adapter $mode checker failure omitted its diagnostic"
      for command in "cat <<'EOF'
gh pr create
EOF" 'gh pr create --repo wongsuwarn/firstmate --base main'; do
        case "$adapter" in
          claude) payload=$(jq -cn --arg command "$command" '{tool_input:{command:$command}}') ;;
          grok) payload=$(jq -cn --arg command "$command" '{toolInput:{command:$command}}') ;;
        esac
        status=0
        if [ "$adapter" = claude ]; then
          out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$fixture" bash -c "$hook" 2>&1) || status=$?
        else
          out=$(printf '%s' "$payload" | GROK_WORKSPACE_ROOT="$fixture" bash -c "$hook" 2>&1) || status=$?
        fi
        [ "$status" -eq 0 ] || fail "$adapter $mode checker blocked an unclassified command: $out"
        assert_contains "$out" 'pr-target-classification-unavailable' "$adapter $mode checker failure omitted its diagnostic"
      done
    done
  done
  hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-hook-dispatch.sh")) | .command' "$ROOT/.claude/settings.json")
  payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
  status=0
  out=$(printf '%s' "$payload" | env -u CLAUDE_PROJECT_DIR bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Claude missing-root precondition blocked an unrelated command: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Claude missing-root diagnostic is missing"
  hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-hook-dispatch.sh")) | .command' "$ROOT/.grok/hooks/fm-pr-create-pretool-check.json")
  payload=$(jq -cn --arg command 'git status' '{toolInput:{command:$command}}')
  status=0
  out=$(printf '%s' "$payload" | env -u GROK_WORKSPACE_ROOT bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Grok missing-root precondition blocked an unrelated command: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Grok missing-root diagnostic is missing"
  pass "Claude and Grok allow checker failures with a loud diagnostic"
}

make_pi_adapter_fixture() {
  local repo=$1 mode=$2
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/state"
  git -C "$repo" init -q
  : > "$repo/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-primary-scope.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-primary-scope.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$repo/bin/"
  cp "$ROOT/bin/fm-pr-create-hook-dispatch.sh" "$ROOT/bin/fm-pr-create-visible-check.sh" \
    "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$repo/bin/"
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
  chmod +x "$repo/bin/fm-cd-pretool-check.sh" "$repo/bin/fm-arm-pretool-check.sh" \
    "$repo/bin/fm-primary-scope.sh" "$repo/bin/fm-pr-create-hook-dispatch.sh" \
    "$repo/bin/fm-pr-create-visible-check.sh"
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
const heredocResult = await handler({ type: "tool_call", toolName: "bash", input: { command: "cat <<'EOF'\ngh pr create\nEOF" } });
if (heredocResult?.block === true) throw new Error("Pi blocked heredoc content after PR checker failure");
const prResult = await handler({ type: "tool_call", toolName: "bash", input: { command: "gh pr create --repo wongsuwarn/firstmate --base main" } });
if (prResult?.block === true) throw new Error("Pi blocked visible PR creation after PR checker failure");
JS
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi adapter failure test failed: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Pi adapter failure omitted its diagnostic"
}

test_pi_adapter_failures_allow_with_diagnostic() {
  local missing="$TMP_ROOT/pi-missing" signal="$TMP_ROOT/pi-signal"
  make_pi_adapter_fixture "$missing" missing
  make_pi_adapter_fixture "$signal" signal
  run_pi_adapter_case "$missing"
  run_pi_adapter_case "$signal"
  pass "Pi and pi-signed allow checker failures with a loud diagnostic"
}

test_codex_adapter_preconditions_allow_with_diagnostic() {
  local hook fixture missing_dispatch payload out status=0
  hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("fm-pr-create-hook-dispatch.sh")) | .command' "$ROOT/.codex/hooks.json")
  [ -n "$hook" ] || fail "Codex PR-target hook command is missing"
  payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
  fixture="$TMP_ROOT/codex-precondition"
  mkdir -p "$fixture/.codex" "$fixture/bin"
  : > "$fixture/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$fixture/.codex/hooks.json"
  cp "$ROOT/bin/fm-pr-create-hook-dispatch.sh" "$ROOT/bin/fm-pr-create-visible-check.sh" \
    "$ROOT/bin/fm-pr-create-explicit-path-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$fixture/bin/"
  chmod +x "$fixture/bin/fm-pr-create-hook-dispatch.sh" "$fixture/bin/fm-pr-create-visible-check.sh"
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex missing-checker precondition must allow unrelated commands, got $status: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex missing-checker diagnostic is missing"
  payload=$(jq -cn --arg command 'gh pr create --repo wongsuwarn/firstmate --base main' '{tool_input:{command:$command}}')
  status=0
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex missing-checker precondition must allow visible PR creation, got $status: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex missing-checker diagnostic is missing"
  payload=$(jq -cn --arg command "cat <<'EOF'
gh pr create
EOF" '{tool_input:{command:$command}}')
  status=0
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex missing-checker precondition must allow heredoc content, got $status: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex missing-checker diagnostic is missing"
  printf '%s\n' '{}' > "$fixture/.codex/hooks.json"
  payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
  status=0
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex hook self-validation failure must allow unrelated commands, got $status: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex self-validation diagnostic is missing"
  payload=$(jq -cn --arg command 'gh pr create --repo wongsuwarn/firstmate --base main' '{tool_input:{command:$command}}')
  status=0
  out=$(cd "$fixture" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex self-validation failure must allow visible PR creation, got $status: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex self-validation diagnostic is missing"
  missing_dispatch="$TMP_ROOT/codex-missing-dispatch"
  mkdir -p "$missing_dispatch"
  payload=$(jq -cn --arg command 'git status' '{tool_input:{command:$command}}')
  status=0
  out=$(cd "$missing_dispatch" && printf '%s' "$payload" | bash -c "$hook" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "Codex missing dispatcher blocked an unrelated command: $out"
  assert_contains "$out" 'pr-target-classification-unavailable' "Codex missing-dispatch diagnostic is missing"
  pass "Codex allows unavailable preconditions with a loud diagnostic"
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
test_unavailable_dependencies_allow_with_diagnostic
test_all_harness_transports_scope_boundary_enforcement
test_guard_survives_origin_change
test_malformed_transport_allows_with_diagnostic
test_checker_output_requires_recognized_status
test_opencode_adapter_failures_allow_with_diagnostic
test_direct_hook_adapter_failures_allow_with_diagnostic
test_pi_adapter_failures_allow_with_diagnostic
test_codex_adapter_preconditions_allow_with_diagnostic
test_binding_converges_idempotently
test_bootstrap_root_override_binds_selected_checkout

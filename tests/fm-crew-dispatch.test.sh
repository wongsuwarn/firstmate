#!/usr/bin/env bash
# Behavior tests for crew dispatch validation, Mission Control rendering, and
# bounded board edits through the shared request parser.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-dispatch)
DISPATCH="$ROOT/bin/fm-crew-dispatch.sh"
BOARD="$ROOT/bin/fm-mission-control.sh"
REPLY="$ROOT/bin/fm-procevent-board-reply.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects"
CONFIG="$HOME_DIR/config/crew-dispatch.json"
SNAPSHOT="$TMP_ROOT/snapshot.json"
cat > "$SNAPSHOT" <<JSON
{"schema":"fm-fleet-snapshot.v1","generated":"2026-08-10T12:00:00Z","fm_home":"$HOME_DIR",
 "roots":{"state":"$HOME_DIR/state","data":"$HOME_DIR/data","projects":"$HOME_DIR/projects"},
 "backlog":{"present":true,"records":[]},"tasks":[],
 "secondmate_current":{"registry":{"available":true,"complete":true,
   "input_truncated":false,"records_truncated":false,"records":[]},"records":[]}}
JSON

write_dispatch_fixture() {
  cat > "$CONFIG" <<'JSON'
{
  "rules": [
    {
      "when": "visual browser work with a deliberately long task type that must wrap without hiding its assignment at phone width",
      "use": [
        {"harness":"codex","model":"gpt-5.5","effort":"high","provider":"openai"},
        {"harness":"claude","model":"claude-sonnet-5","effort":"xhigh","provider":"anthropic"}
      ],
      "fallback": {"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},
      "independent": true,
      "why": "Browser verification benefits from the isolated visual tool session."
    },
    {
      "when": "small documentation corrections",
      "use": {"harness":"claude","model":"claude-haiku-4-5","effort":"low"}
    }
  ],
  "default": [
    {"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},
    {"harness":"grok","model":"grok-4.5","effort":"high"}
  ],
  "default_fallback": {"harness":"claude","model":"claude-sonnet-5","effort":"high"}
}
JSON
}

capture_request() {  # <path> <wire>
  local path=$1 wire=$2
  {
    printf 'schema=fm-board-delta.v1\nstatus=delta\nsource=board-fixture\nrequests=1\n\n'
    printf 'prompts[1]{received,attempt,prompt}:\n'
    printf '  "2026-08-10T12:00:00Z","fm-board:fixture",'
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$wire"
    printf 'board-delta-end=1\n'
  } > "$path"
}

write_dispatch_fixture
status=$($DISPATCH status "$CONFIG") || fail "a valid multi-rule fixture must have readable status"
[ "$(printf '%s' "$status" | jq -r '.status')" = valid ] \
  || fail "a valid dispatch fixture was not reported valid"
[ "$(printf '%s' "$status" | jq -r '.config.rules | length')" = 2 ] \
  || fail "the status read dropped a dispatch rule"
[ "$(printf '%s' "$status" | jq -r '.config.rules[0].use | length')" = 2 ] \
  || fail "the status read flattened a profile array"
[ "$(printf '%s' "$status" | jq -r '.config.default | length')" = 2 ] \
  || fail "the status read flattened the default profile array"
pass "dispatch status preserves multi-rule and quota-array fixtures"

READ_ONLY="$TMP_ROOT/read-only.html"
CONTROLLED="$TMP_ROOT/controlled.html"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$READ_ONLY" >/dev/null || fail "the view-only board must render dispatch config"
assert_grep '>Dispatch</h2>' "$READ_ONLY" "the System view must carry Dispatch"
assert_grep 'Active and valid' "$READ_ONLY" "the board must state the current validation verdict"
assert_grep '2-profile quota array' "$READ_ONLY" "profile arrays must be labelled as quota arrays"
assert_grep '<dt>Harness</dt><dd>codex</dd>' "$READ_ONLY" "a rule must show its harness"
assert_grep '<dt>Model</dt><dd>gpt-5.5</dd>' "$READ_ONLY" "a rule must show its model"
assert_grep '<dt>Effort</dt><dd>high</dd>' "$READ_ONLY" "a rule must show its effort"
assert_grep '<dt>Provider</dt><dd>openai</dd>' "$READ_ONLY" "a rule must show its provider when set"
assert_grep '>Why this rule exists</summary>' "$READ_ONLY" "a rationale must stay collapsed"
assert_grep '>Raw crew-dispatch.json</summary>' "$READ_ONLY" "raw JSON must be expandable rather than primary"
assert_grep 'Secondmate homes receive this same file when it is pushed.' "$READ_ONLY" \
  "the board must state the inherited-file relationship"
assert_no_grep 'data-intent="dispatch"' "$READ_ONLY" \
  "a board rendered without controls must remain view-only"

FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the controls board must render dispatch editors"
editors=$(grep -o 'data-intent="dispatch"' "$CONTROLLED" | wc -l | tr -d ' ')
[ "$editors" = 3 ] || fail "two rules and the default must each get one bounded editor, got $editors"
assert_grep 'data-dispatch-profile' "$CONTROLLED" "an array editor must identify a selected existing profile"
assert_grep 'data-dispatch-model' "$CONTROLLED" "the bounded editor must expose model"
assert_grep 'data-dispatch-effort' "$CONTROLLED" "the bounded editor must expose effort"
assert_grep 'body.lavish .dispatch-editor{display:none' "$CONTROLLED" \
  "the legacy bridge must not reveal dispatch edits"
pass "dispatch is readable with controls off and bounded editors appear with controls on"

MISSING_HOME="$TMP_ROOT/missing"
mkdir -p "$MISSING_HOME/config" "$MISSING_HOME/state" "$MISSING_HOME/data" "$MISSING_HOME/projects"
missing_status=$($DISPATCH status "$MISSING_HOME/config/crew-dispatch.json") \
  || fail "an absent dispatch file must be a normal status result"
[ "$(printf '%s' "$missing_status" | jq -r '.status')" = absent ] \
  || fail "an absent dispatch file was not reported absent"
FM_CONFIG_OVERRIDE="$MISSING_HOME/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$TMP_ROOT/missing.html" >/dev/null || fail "a board with no dispatch file must render"
assert_grep 'No crew dispatch file is active in this home.' "$TMP_ROOT/missing.html" \
  "the missing-file state must be explicit"
pass "a missing crew dispatch file renders an explicit inactive state"

cp "$CONFIG" "$TMP_ROOT/valid-dispatch.json"
printf '%s\n' '{"rules":[{"when":"broken quota choice","use":[]}]}' > "$CONFIG"
invalid_status=$($DISPATCH status "$CONFIG") || fail "an invalid profile array must still return board status"
[ "$(printf '%s' "$invalid_status" | jq -r '.status')" = invalid ] \
  || fail "an empty profile array was not reported invalid"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --out "$TMP_ROOT/invalid.html" >/dev/null || fail "an invalid dispatch file must still render"
assert_grep 'each rule needs at least one use profile' "$TMP_ROOT/invalid.html" \
  "the board must show the shared validator refusal"
assert_grep '>Raw crew-dispatch.json</summary>' "$TMP_ROOT/invalid.html" \
  "an invalid file must keep raw JSON behind an expandable view"
mv "$TMP_ROOT/valid-dispatch.json" "$CONFIG"
pass "a malformed profile array renders the existing validator refusal without becoming board logic"

VALID_RESULT="$TMP_ROOT/valid.result"
capture_request "$VALID_RESULT" \
  'FM-BOARD-REQUEST {"v":1,"intent":"dispatch","home":"main","scope":"rule","index":0,"profile":1,"when":"visual browser work with a deliberately long task type that must wrap without hiding its assignment at phone width","model":"claude-opus-5","effort":"max","request_id":"dispatch-valid-one"}'
FM_HOME="$HOME_DIR" "$REPLY" apply "$VALID_RESULT" > "$TMP_ROOT/valid.out" \
  || fail "a valid dispatch intent must apply through the board collector"
[ "$(jq -r '.rules[0].use[1].model' "$CONFIG")" = claude-opus-5 ] \
  || fail "the selected array profile model did not change"
[ "$(jq -r '.rules[0].use[0].model' "$CONFIG")" = gpt-5.5 ] \
  || fail "editing one array profile changed its neighbour"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the board must regenerate after a valid edit"
assert_grep 'Assignment updated: claude / claude-opus-5 / max.' "$CONTROLLED" \
  "a successful write must surface the new assignment"
pass "a board dispatch request updates one existing array profile and regenerates confirmation"

BAD_RESULT="$TMP_ROOT/bad.result"
capture_request "$BAD_RESULT" \
  'FM-BOARD-REQUEST {"v":1,"intent":"dispatch","home":"main","scope":"default","index":0,"profile":1,"model":"grok-4.5","effort":"max","request_id":"dispatch-invalid-one"}'
cp "$CONFIG" "$TMP_ROOT/before-invalid.json"
if FM_HOME="$HOME_DIR" "$REPLY" apply "$BAD_RESULT" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
  fail "an effort unsupported by the configured harness must be rejected"
fi
cmp -s "$TMP_ROOT/before-invalid.json" "$CONFIG" \
  || fail "a rejected dispatch candidate changed the source file"
assert_grep 'invalid effort: grok:max' "$TMP_ROOT/bad.err" \
  "the shared dispatch validator must explain an invalid effort"
FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$BOARD" --snapshot "$SNAPSHOT" --no-quota \
  --controls --out "$CONTROLLED" >/dev/null || fail "the board must regenerate after a refused edit"
assert_grep 'Assignment rejected' "$CONTROLLED" "a refused edit must surface a clear rejection"
assert_grep 'Crew dispatch unchanged - invalid effort: grok:max' "$CONTROLLED" \
  "a refused edit must say the file was left unchanged"
pass "an invalid board edit fails closed, leaves the file byte-identical, and renders its refusal"

fm_test_cleanup

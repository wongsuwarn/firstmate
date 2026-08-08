#!/usr/bin/env bash
# Regression tests for the Pi Luna compaction extension without live model calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-luna-compaction)
EXT="$ROOT/.pi/extensions/fm-luna-compaction.ts"

run_cases() {
  local fixture out output_file status
  fixture="$TMP_ROOT/fixture"
  mkdir -p "$fixture/.pi/extensions" "$fixture/node_modules/@earendil-works/pi-coding-agent" "$fixture/node_modules/@earendil-works/pi-ai"
  cp "$EXT" "$fixture/.pi/extensions/fm-luna-compaction.ts"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
  cat >"$fixture/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat >"$fixture/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function convertToLlm(messages) { return messages; }
export function serializeConversation(messages) {
  return messages.map((message) => typeof message.content === "string" ? message.content : JSON.stringify(message.content)).join("\n");
}
export async function compact(...args) { return globalThis.__compact(...args); }
JS
  cat >"$fixture/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  : >"$fixture/node_modules/@earendil-works/pi-ai/index.js"

  output_file="$fixture/output"
  (cd "$fixture" && node --input-type=module) >"$output_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(".pi/extensions/fm-luna-compaction.ts").href}?test=${Date.now()}`);
let handler;
extension.default({ on(name, next) { if (name === "session_before_compact") handler = next; } });
if (!handler) throw new Error("compaction handler was not registered");

const usage = { input: 1000, output: 100, cacheRead: 0, cacheWrite: 0, totalTokens: 1100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const details = { readFiles: ["src/a.ts"], modifiedFiles: ["src/b.ts"] };
const valid = () => "## Goal\nGoal\n## Constraints & Preferences\n- none\n## Progress\n### Done\n- [x] done\n### In Progress\n- [ ] work\n### Blocked\n- none\n## Key Decisions\n- **Decision**: why\n## Next Steps\n1. next\n## Critical Context\n- context\n<read-files>\nsrc/a.ts\n</read-files>\n<modified-files>\nsrc/b.ts\n</modified-files>";
const malformed = "## Goal\nmissing the native summary structure";
const models = {
  luna: { provider: "openai-codex", id: "gpt-5.6-luna", contextWindow: 272000, maxTokens: 128000, reasoning: true },
  sol: { provider: "openai-codex", id: "gpt-5.6-sol", contextWindow: 272000, maxTokens: 128000, reasoning: true },
};
function preparation(overrides = {}) {
  return {
    firstKeptEntryId: "kept",
    messagesToSummarize: [{ role: "user", content: "x".repeat(2000) }],
    turnPrefixMessages: [],
    isSplitTurn: false,
    tokensBefore: 999,
    fileOps: {},
    settings: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 },
    ...overrides,
  };
}
function context(prep, conversationModel = { ...models.sol }) {
  return {
    model: conversationModel,
    modelRegistry: {
      find(_provider, id) { return id === models.luna.id ? models.luna : id === models.sol.id ? models.sol : undefined; },
      async getApiKeyAndHeaders() { return { ok: true, apiKey: "test", headers: { "x-test": "yes" }, env: { TEST: "1" } }; },
    },
  };
}
async function invoke({ prep = preparation(), plan, signal = new AbortController().signal, conversationModel } = {}) {
  const calls = [];
  globalThis.__compact = async (actualPrep, model, apiKey, headers, instructions, actualSignal, thinking, stream, env) => {
    calls.push({ model, actualPrep, apiKey, headers, instructions, actualSignal, thinking, stream, env });
    const next = plan[model.id];
    if (next instanceof Error) throw next;
    return next;
  };
  try {
    return { result: await handler({ preparation: prep, customInstructions: "focus", signal }, context(prep, conversationModel)), calls };
  } catch (error) {
    return { error, calls };
  }
}
function result(summary = valid(), nextUsage = usage, nextDetails = details) {
  return { summary, firstKeptEntryId: "kept", tokensBefore: 999, usage: nextUsage, details: nextDetails };
}

// Luna is the only nested model selected on a safe result. The session model is read-only.
{
  const original = { ...models.sol, id: "captain-selected-model" };
  const run = await invoke({ conversationModel: original, plan: { [models.luna.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.luna.id) throw new Error("safe Luna compaction did not select Luna exactly once");
  if (run.result.compaction.usage !== usage || run.result.compaction.details !== details) throw new Error("native usage or details were not preserved");
  if (run.calls[0].instructions !== "focus" || run.calls[0].thinking !== undefined || run.calls[0].stream !== undefined || run.calls[0].env.TEST !== "1") throw new Error("native compaction arguments were not preserved");
  if (original.id !== "captain-selected-model") throw new Error("the conversation model was changed");
}

// Luna's smaller envelope never receives a request; Sol gets the one fallback attempt.
{
  models.luna.contextWindow = 1000;
  const run = await invoke({ plan: { [models.sol.id]: result() } });
  models.luna.contextWindow = 272000;
  if (run.error || run.calls.map((call) => call.model.id).join() !== models.sol.id) throw new Error("oversize Luna preflight did not use only Sol");
}

for (const [name, luna] of [
  ["malformed", result(malformed)],
  ["visible truncation", result(`${valid()}\n- unfinished...`)],
  ["output-limit truncation", result(valid(), { ...usage, output: 13000 })],
  ["partial usage", result(valid(), { ...usage, input: 10 })],
  ["nested failure", new Error("provider failed")],
]) {
  const run = await invoke({ plan: { [models.luna.id]: luna, [models.sol.id]: result() } });
  if (run.error || run.calls.map((call) => call.model.id).join() !== "gpt-5.6-luna,gpt-5.6-sol") throw new Error(`${name} did not fall back to Sol exactly once`);
}

// A rejected Luna followed by rejected Sol becomes an explicit compaction failure, never a partial accept.
{
  const run = await invoke({ plan: { [models.luna.id]: result(malformed), [models.sol.id]: result(malformed) } });
  if (!run.error || !String(run.error.message).includes("Safe compaction failed") || run.calls.length !== 2) throw new Error("double failure was not surfaced clearly");
}

// Cancellation is not accepted, and cannot become a successful fallback result.
{
  const controller = new AbortController();
  controller.abort();
  const run = await invoke({ signal: controller.signal, plan: { [models.luna.id]: result(), [models.sol.id]: result() } });
  if (!run.error || run.calls.length !== 0 || !String(run.error.message).includes("Safe compaction failed")) throw new Error("cancelled compaction was accepted or called a model");
}

// The documented native split-turn shape is accepted without flattening it.
{
  const split = preparation({ isSplitTurn: true, messagesToSummarize: [], turnPrefixMessages: [{ role: "user", content: "prefix" }] });
  const splitSummary = "No prior history.\n\n---\n\n**Turn Context (split turn):**\n\n## Original Request\nrequest\n## Early Progress\n- progress\n## Context for Suffix\n- suffix\n<read-files>\n</read-files>\n<modified-files>\n</modified-files>";
  const run = await invoke({ prep: split, plan: { [models.luna.id]: result(splitSummary) } });
  if (run.error || run.calls.length !== 1 || run.result.compaction.summary !== splitSummary) throw new Error("native split-turn compaction shape was altered or rejected");
}

console.log("ok");
JS
  status=$?
  out=$(<"$output_file")
  [ "$status" -eq 0 ] || fail "Pi Luna compaction regression failed: $out"
  [ "$out" = "ok" ] || fail "Pi Luna compaction regression emitted unexpected output: $out"
  pass "Pi Luna compaction safely selects Luna, preserves native results, and falls back to Sol"
}

run_cases

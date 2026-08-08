// Safely route only Pi's nested compaction requests to Luna.
//
// Pi's own compact() remains the single owner of prompt construction, split-turn
// handling, file-operation tracking, token accounting, and session semantics.
import {
  compact,
  convertToLlm,
  serializeConversation,
  type CompactionResult,
  type ExtensionAPI,
  type ModelRegistry,
  type SessionBeforeCompactEvent,
} from "@earendil-works/pi-coding-agent";
import type { Model, Usage } from "@earendil-works/pi-ai";

const COMPACTION_MODELS = {
  provider: "openai-codex",
  primary: "gpt-5.6-luna",
  fallback: "gpt-5.6-sol",
} as const;

const COMPACTION_SAFETY_POLICY = {
  disabledValue: "off",
  minimumUsageFraction: 0.5,
  outputCeilingFraction: 0.98,
  requestOverheadTokens: 2048,
  requiredHeadings: [
    "## Goal",
    "## Constraints & Preferences",
    "## Progress",
    "### Done",
    "### In Progress",
    "### Blocked",
    "## Key Decisions",
    "## Next Steps",
    "## Critical Context",
  ],
  requiredSplitHeadings: ["## Original Request", "## Early Progress", "## Context for Suffix"],
} as const;

type CompactionPreparation = SessionBeforeCompactEvent["preparation"];

type CompactionAttempt = {
  result: CompactionResult;
  model: Model<any>;
};

function textTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

function serializedTokens(messages: CompactionPreparation["messagesToSummarize"]): number {
  return textTokens(serializeConversation(convertToLlm(messages)));
}

function maximumOutputTokens(model: Model<any>, preparation: CompactionPreparation, split: boolean): number {
  const fraction = split ? 0.5 : 0.8;
  const modelLimit = model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY;
  return Math.min(Math.floor(fraction * preparation.settings.reserveTokens), modelLimit);
}

function preparedInputTokens(preparation: CompactionPreparation, customInstructions?: string): number {
  const previous = preparation.previousSummary ? textTokens(preparation.previousSummary) : 0;
  const instructions = customInstructions ? textTokens(customInstructions) : 0;
  const history = serializedTokens(preparation.messagesToSummarize) + previous + instructions + COMPACTION_SAFETY_POLICY.requestOverheadTokens;
  if (!preparation.isSplitTurn || preparation.turnPrefixMessages.length === 0) return history;
  return history + serializedTokens(preparation.turnPrefixMessages);
}

function outputEnvelopeTokens(model: Model<any>, preparation: CompactionPreparation): number {
  if (!preparation.isSplitTurn || preparation.turnPrefixMessages.length === 0) {
    return maximumOutputTokens(model, preparation, false);
  }
  const history = preparation.messagesToSummarize.length > 0
    ? maximumOutputTokens(model, preparation, false)
    : 0;
  return history + maximumOutputTokens(model, preparation, true);
}

function modelCanReceivePreparation(
  model: Model<any>,
  preparation: CompactionPreparation,
  conversationModel: Model<any> | undefined,
  customInstructions?: string,
): boolean {
  if (conversationModel && model.contextWindow < conversationModel.contextWindow) return false;
  return preparedInputTokens(preparation, customInstructions) + outputEnvelopeTokens(model, preparation) <= model.contextWindow;
}

function hasAll(text: string, required: readonly string[]): boolean {
  return required.every((heading) => text.includes(heading));
}

function hasCompleteStructure(summary: string, preparation: CompactionPreparation): boolean {
  if (!hasAll(summary, ["<read-files>", "</read-files>", "<modified-files>", "</modified-files>"])) return false;
  if (preparation.isSplitTurn && preparation.turnPrefixMessages.length > 0) {
    const hasHistory = preparation.messagesToSummarize.length > 0;
    return (!hasHistory || hasAll(summary, COMPACTION_SAFETY_POLICY.requiredHeadings))
      && hasAll(summary, COMPACTION_SAFETY_POLICY.requiredSplitHeadings);
  }
  return hasAll(summary, COMPACTION_SAFETY_POLICY.requiredHeadings);
}

function visiblyTruncated(summary: string): boolean {
  const ending = summary.trimEnd();
  return /(?:\.\.\.|…|\[\.\.\.[^\]]*|[:,;])$/.test(ending);
}

function usageSuggestsTruncation(usage: Usage | undefined, model: Model<any>, preparation: CompactionPreparation): boolean {
  if (!usage || usage.output <= 0) return false;
  return usage.output >= outputEnvelopeTokens(model, preparation) * COMPACTION_SAFETY_POLICY.outputCeilingFraction;
}

function usageSuggestsLostInput(usage: Usage | undefined, preparation: CompactionPreparation): boolean {
  if (!usage || usage.input <= 0) return true;
  return usage.input < (preparedInputTokens(preparation) - COMPACTION_SAFETY_POLICY.requestOverheadTokens)
    * COMPACTION_SAFETY_POLICY.minimumUsageFraction;
}

function safeResult(result: CompactionResult, model: Model<any>, preparation: CompactionPreparation): string | undefined {
  if (!result.summary.trim()) return "the summary was empty";
  if (!hasCompleteStructure(result.summary, preparation)) return "the summary was malformed or incomplete";
  if (visiblyTruncated(result.summary)) return "the summary is visibly truncated";
  if (usageSuggestsTruncation(result.usage, model, preparation)) return "the summary reached its output limit";
  if (usageSuggestsLostInput(result.usage, preparation)) return "usage indicates the request received too little prepared history";
  return undefined;
}

async function runCompaction(
  preparation: CompactionPreparation,
  model: Model<any>,
  customInstructions: string | undefined,
  signal: AbortSignal,
  registry: ModelRegistry,
): Promise<CompactionAttempt> {
  if (signal.aborted) throw new Error("compaction was cancelled");
  const auth = await registry.getApiKeyAndHeaders(model);
  if (!auth.ok) throw new Error(auth.error);
  const result = await compact(
    preparation,
    model,
    auth.apiKey,
    requestHeaders(auth.headers),
    customInstructions,
    signal,
    undefined,
    undefined,
    auth.env,
  );
  if (signal.aborted) throw new Error("compaction was cancelled");
  return { result, model };
}

function requestHeaders(headers: Record<string, string | null> | undefined): Record<string, string> | undefined {
  if (!headers) return undefined;
  return Object.fromEntries(Object.entries(headers).filter((entry): entry is [string, string] => entry[1] !== null));
}

function failureMessage(lunaReason: string, solReason: string): string {
  return `Safe compaction failed: Luna was rejected because ${lunaReason}; Sol was rejected because ${solReason}.`;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_before_compact", async (event, ctx) => {
    if (process.env.FM_PI_LUNA_COMPACTION === COMPACTION_SAFETY_POLICY.disabledValue) return;

    const luna = ctx.modelRegistry.find(COMPACTION_MODELS.provider, COMPACTION_MODELS.primary);
    const sol = ctx.modelRegistry.find(COMPACTION_MODELS.provider, COMPACTION_MODELS.fallback);
    if (!luna || !sol) {
      throw new Error("Safe compaction requires both openai-codex/gpt-5.6-luna and openai-codex/gpt-5.6-sol.");
    }

    let lunaReason = "Luna could not safely compact this session";
    if (modelCanReceivePreparation(luna, event.preparation, ctx.model, event.customInstructions)) {
      try {
        const lunaAttempt = await runCompaction(
          event.preparation,
          luna,
          event.customInstructions,
          event.signal,
          ctx.modelRegistry,
        );
        const rejected = safeResult(lunaAttempt.result, lunaAttempt.model, event.preparation);
        if (!rejected) return { compaction: lunaAttempt.result };
        lunaReason = rejected;
      } catch (error) {
        lunaReason = error instanceof Error ? error.message : String(error);
      }
    } else {
      lunaReason = "the prepared request exceeds Luna's supported context/output envelope";
    }

    try {
      if (!modelCanReceivePreparation(sol, event.preparation, ctx.model, event.customInstructions)) {
        throw new Error("the prepared request exceeds Sol's supported context/output envelope");
      }
      const solAttempt = await runCompaction(
        event.preparation,
        sol,
        event.customInstructions,
        event.signal,
        ctx.modelRegistry,
      );
      const rejected = safeResult(solAttempt.result, solAttempt.model, event.preparation);
      if (!rejected) return { compaction: solAttempt.result };
      throw new Error(rejected);
    } catch (error) {
      const solReason = error instanceof Error ? error.message : String(error);
      throw new Error(failureMessage(lunaReason, solReason));
    }
  });
}

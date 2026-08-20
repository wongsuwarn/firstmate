#!/usr/bin/env node
// Semantic policy for firstmate-repository pull-request creation.
//
// A firstmate checkout can carry an upstream remote that gh's repository
// heuristic selects for a bare PR create. This policy permits gh and gh-axi
// PR creation only when the command explicitly targets wongsuwarn/firstmate.
// It reuses the shared shell lexer rather than executing or expanding command
// bytes. See docs/pr-target-guard.md for the complete contract.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const TARGET = "wongsuwarn/firstmate";

const REASONS = {
  "pr-target-required": `a firstmate PR must explicitly name its target: pass --repo ${TARGET} (and --base main).`,
  "pr-target-unclassifiable": `cannot safely verify the PR target: pass --repo ${TARGET} (and --base main) in a direct gh or gh-axi pr create command.`,
};

function basename(value) {
  const trimmed = value.replace(/\\+$/, "");
  const parts = trimmed.split(/[\\/]/);
  return parts.at(-1) || "";
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function isPrCreate(position) {
  if (!position.command || !["gh", "gh-axi"].includes(basename(position.command.value))) return false;
  const argumentsAfterCommand = position.words.slice(position.index + 1);
  return argumentsAfterCommand[0]?.value === "pr" && argumentsAfterCommand[1]?.value === "create";
}

function hasRequiredRepo(position) {
  const argumentsAfterCommand = position.words.slice(position.index + 3);
  let found = false;
  for (let index = 0; index < argumentsAfterCommand.length; index += 1) {
    const word = argumentsAfterCommand[index];
    if (word.value === "--repo") {
      const value = argumentsAfterCommand[index + 1];
      if (!word.literal || !value || !value.literal || value.value !== TARGET) return false;
      found = true;
      index += 1;
      continue;
    }
    if (word.value.startsWith("--repo=")) {
      if (!word.literal || word.value.slice("--repo=".length) !== TARGET) return false;
      found = true;
    }
  }
  return found;
}

function mentionsPrCreate(command) {
  return /(?:^|[\s;'"`|&()])(?:[./A-Za-z0-9_-]*\/)?gh(?:-axi)?[\s]+pr[\s]+create(?:\s|$)/m.test(command);
}

function basenameCommand(position) {
  return basename(position.command?.value || "");
}

function shellPayload(tokens, position) {
  if (!["sh", "bash", "zsh"].includes(basenameCommand(position))) return { payloads: [], unresolved: false };
  for (let index = position.index + 1; index < position.words.length; index += 1) {
    const word = position.words[index];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(word.value)) {
      let payloadIndex = index + 1;
      if (position.words[payloadIndex]?.value === "--") payloadIndex += 1;
      const payload = position.words[payloadIndex];
      if (!payload) return { payloads: [], unresolved: true };
      if (!payload.literal || payload.subs.length > 0) {
        return { payloads: [], unresolved: mentionsPrCreate(payload.value) };
      }
      return { payloads: [payload.value], unresolved: false };
    }
    if (/^[-+]O$/.test(word.value)) {
      index += 1;
      continue;
    }
    if (word.value === "--" || /^[-+]/.test(word.value)) continue;
    return { payloads: [], unresolved: false };
  }
  const payloads = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string") payloads.push(token.heredoc);
    if (token.type !== "redir" || token.fd !== 0 || token.value !== "<<<") continue;
    const payload = tokens[index + 1];
    if (payload?.type === "word" && payload.literal && payload.subs.length === 0) payloads.push(payload.value);
    else if (payload && mentionsPrCreate(payload.value)) return { payloads, unresolved: true };
  }
  return { payloads, unresolved: false };
}

function evalPayload(position) {
  if (basenameCommand(position) !== "eval") return { payloads: [], unresolved: false };
  const words = position.words.slice(position.index + 1);
  if (words.length === 0) return { payloads: [], unresolved: false };
  if (words.some((word) => !word.literal || word.subs.length > 0)) {
    return { payloads: [], unresolved: mentionsPrCreate(words.map((word) => word.value).join(" ")) };
  }
  return { payloads: [words.map((word) => word.value).join(" ")], unresolved: false };
}

function analyze(command, depth = 0) {
  if (depth > 12) return { sawPrCreate: false, result: mentionsPrCreate(command) ? deny("pr-target-unclassifiable") : null };
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return { sawPrCreate: false, result: mentionsPrCreate(command) ? deny("pr-target-unclassifiable") : null };

  const { nodes } = splitProgram(lexed.tokens);
  let sawPrCreate = false;
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    if (isPrCreate(position)) {
      sawPrCreate = true;
      if (position.unresolvedWrapperOption || !hasRequiredRepo(position)) {
        return { sawPrCreate, result: deny("pr-target-required") };
      }
    }

    const payloads = [...position.wrapperPayloads];
    for (const token of tokens) {
      if (token.type === "group") payloads.push(token.content);
      if (token.type !== "word") continue;
      for (const substitution of token.subs) payloads.push(substitution.content);
    }
    const shell = shellPayload(tokens, position);
    const evaluated = evalPayload(position);
    if (shell.unresolved || evaluated.unresolved) {
      return { sawPrCreate, result: deny("pr-target-unclassifiable") };
    }
    payloads.push(...shell.payloads, ...evaluated.payloads);
    for (const payload of payloads) {
      const nested = analyze(payload, depth + 1);
      sawPrCreate ||= nested.sawPrCreate;
      if (nested.result) return { sawPrCreate, result: nested.result };
    }
  }
  if (!sawPrCreate && mentionsPrCreate(command)) {
    return { sawPrCreate, result: deny("pr-target-unclassifiable") };
  }
  return { sawPrCreate, result: null };
}

function decision(command) {
  const analysis = analyze(command);
  return analysis.result || { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === "--command") {
      if (index + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[index + 1];
      result.commandSet = true;
      index += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };

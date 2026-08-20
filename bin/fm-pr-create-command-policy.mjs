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
  for (let index = 0; index < argumentsAfterCommand.length; index += 1) {
    const word = argumentsAfterCommand[index];
    if (word.value === "--repo") {
      const value = argumentsAfterCommand[index + 1];
      return Boolean(value && value.literal && value.value === TARGET);
    }
    if (word.value.startsWith("--repo=")) {
      return word.literal && word.value.slice("--repo=".length) === TARGET;
    }
  }
  return false;
}

function mentionsPrCreate(command) {
  return /(?:^|[\s;|&()])(?:[./A-Za-z0-9_-]*\/)?gh(?:-axi)?[\s]+pr[\s]+create(?:\s|$)/m.test(command);
}

function decision(command) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return mentionsPrCreate(command) ? deny("pr-target-unclassifiable") : { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  let sawPrCreate = false;
  for (const node of nodes) {
    const position = commandPosition(node);
    if (!isPrCreate(position)) continue;
    sawPrCreate = true;
    if (!position.unresolvedWrapperOption && hasRequiredRepo(position)) continue;
    return deny("pr-target-required");
  }
  if (sawPrCreate) return { decision: "allow" };
  // A shell construct the shared classifier intentionally does not model can
  // still carry an accidental PR-create command. Refuse that ambiguity.
  return mentionsPrCreate(command) ? deny("pr-target-unclassifiable") : { decision: "allow" };
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

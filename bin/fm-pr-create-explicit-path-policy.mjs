#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

function basename(value) {
  return value.split(/[\\/]/).at(-1) || "";
}

function isPrCreate(args) {
  let positional = 0;
  let expectValue = false;
  for (const arg of args) {
    if (expectValue) {
      expectValue = false;
      continue;
    }
    if (["--repo", "--hostname", "-R"].includes(arg)) {
      expectValue = true;
      continue;
    }
    if (arg.startsWith("--repo=") || arg.startsWith("--hostname=") || /^-R.+/.test(arg)) continue;
    if (arg === "--" || arg.startsWith("-")) continue;
    positional += 1;
    if (positional === 1 && arg !== "pr") return false;
    if (positional === 2) return arg === "create";
  }
  return false;
}

function visiblePrInvocations(command) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return [];
  const { nodes } = splitProgram(lexed.tokens);
  const invocations = [];
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    const tool = basename(position.command?.value || "");
    if (!["gh", "gh-axi"].includes(tool) || !position.command.literal) continue;
    const words = position.words.slice(position.index);
    const args = words.slice(1).map((word) => word.value);
    if (isPrCreate(args)) invocations.push({ tool, args });
  }
  return invocations;
}

function inspect(command, wrapper) {
  const invocations = visiblePrInvocations(command);
  if (invocations.length === 0) return "not-pr";
  for (const { tool, args } of invocations) {
    const result = spawnSync(wrapper, [tool, ...args], {
      env: { ...process.env, FM_PR_CREATE_TOOL: "", FM_PR_CREATE_WRAPPER_INTERNAL: "check" },
      stdio: "ignore",
    });
    if (result.error || result.status === null) throw result.error || new Error("wrapper check terminated by signal");
    if (result.status === 2) return "deny";
    if (result.status !== 0) throw new Error(`wrapper check exited ${result.status}`);
  }
  return "pr-allowed";
}

function parseArguments(argv) {
  const result = { classify: false, command: "", wrapper: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === "--classify") {
      result.classify = true;
      continue;
    }
    if (!["--command", "--wrapper"].includes(name) || index + 1 >= argv.length) throw new Error(`invalid argument: ${name}`);
    result[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  if (!result.command || (!result.classify && !result.wrapper)) throw new Error("--command and --wrapper are required");
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
    if (args.classify) {
      process.stdout.write(`${visiblePrInvocations(args.command).length > 0 ? "pr" : "not-pr"}\n`);
    } else {
      process.stdout.write(`${inspect(args.command, args.wrapper)}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { inspect, visiblePrInvocations };

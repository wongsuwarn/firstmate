#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

function basename(value) {
  return value.split(/[\\/]/).at(-1) || "";
}

function inspect(command, wrapper) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return "allow";
  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    const tool = basename(position.command?.value || "");
    if (!["gh", "gh-axi"].includes(tool) || !position.command.literal) continue;
    const words = position.words.slice(position.index);
    const result = spawnSync(wrapper, [tool, ...words.slice(1).map((word) => word.value)], {
      env: { ...process.env, FM_PR_CREATE_TOOL: "", FM_PR_CREATE_WRAPPER_INTERNAL: "check" },
      stdio: "ignore",
    });
    if (result.error || result.status === null) throw result.error || new Error("wrapper check terminated by signal");
    if (result.status === 2) return "deny";
    if (result.status !== 0) throw new Error(`wrapper check exited ${result.status}`);
  }
  return "allow";
}

function parseArguments(argv) {
  const result = { command: "", wrapper: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (!["--command", "--wrapper"].includes(name) || index + 1 >= argv.length) throw new Error(`invalid argument: ${name}`);
    result[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  if (!result.command || !result.wrapper) throw new Error("--command and --wrapper are required");
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
    process.stdout.write(`${inspect(args.command, args.wrapper)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { inspect };

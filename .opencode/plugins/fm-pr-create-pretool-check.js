import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout?.trim();
  if (result.code === 0 && root) return root;
  try { return realpathSync(anchor); } catch { return resolve(anchor); }
}

export const FmPrCreatePretoolCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try { return realpathSync(worktree); } catch { return resolve(worktree); }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;
      const result = await runProcess(`${root}/bin/fm-pr-create-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;
      throw new Error(result.stderr.trim() || "denied by the PR target PreToolUse seatbelt");
    },
  };
};

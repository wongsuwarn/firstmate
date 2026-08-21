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
    child.on("error", (error) => resolvePromise({ code: -1, stdout: "", stderr: error.message }));
    child.on("close", (code) => resolvePromise({ code: code ?? -1, stdout, stderr }));
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
      if (input?.tool !== "bash") return;
      if (!root) {
        process.stderr.write("[pr-target-classification-unavailable] the hook root is unavailable; PR-target classification did not run for this command; allowing it unguarded.\n");
        return;
      }
      const command = output?.args?.command;
      if (!command || typeof command !== "string") {
        process.stderr.write("[pr-target-classification-unavailable] the Bash command is invalid; PR-target classification did not run for this command; allowing it unguarded.\n");
        return;
      }
      const result = await runProcess(`${root}/bin/fm-pr-create-hook-dispatch.sh`, ["--command", command]);
      if (![0, 2].includes(result.code)) {
        process.stderr.write("[pr-target-classification-unavailable] the hook dispatcher failed; PR-target classification did not run for this command; allowing it unguarded.\n");
        return;
      }
      if (result.code !== 2) {
        if (result.stderr) process.stderr.write(result.stderr);
        return;
      }
      throw new Error(result.stderr.trim() || "denied by the PR target PreToolUse seatbelt");
    },
  };
};

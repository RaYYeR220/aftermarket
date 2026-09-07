#!/usr/bin/env node
// Launches the on-chain observer CLI (packages/observer) against Base
// mainnet. Building the package first keeps this runnable straight after a
// fresh `pnpm install`, with no separate build step for a judge to remember.
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const observerDir = join(scriptDir, "..", "packages", "observer");
const cliEntry = join(observerDir, "dist", "cli.js");

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", ...options });
    child.on("error", reject);
    child.on("exit", (code) => resolve(code ?? 1));
  });
}

async function main() {
  if (!existsSync(cliEntry)) {
    // pnpm ships as a .cmd/.ps1 shim on Windows, so it needs a shell to resolve.
    const buildExitCode = await run("pnpm", ["--filter", "@aftermarket/observer", "build"], {
      shell: process.platform === "win32",
    });
    if (buildExitCode !== 0) {
      process.exitCode = buildExitCode;
      return;
    }
  }
  const exitCode = await run(process.execPath, [cliEntry, ...process.argv.slice(2)]);
  process.exitCode = exitCode;
}

main().catch((error) => {
  process.stderr.write(`fatal: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

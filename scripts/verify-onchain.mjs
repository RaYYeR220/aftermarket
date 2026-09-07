#!/usr/bin/env node
// Launches the on-chain observer CLI (packages/observer) against Base mainnet.
//
// This is the first command JUDGES.md and README.md ask a reviewer to run, so it has to work from
// a cold `git clone` with nothing but Node and pnpm on the machine. It therefore installs the
// observer's dependencies if they are missing and builds the package if `dist/` is missing,
// printing what it is doing and why, before running the CLI. On a tree that is already installed
// and built it does neither and starts reading Base immediately.
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(scriptDir, "..");
const observerDir = join(repoRoot, "packages", "observer");
const cliEntry = join(observerDir, "dist", "cli.js");
const observerModules = join(observerDir, "node_modules");

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", ...options });
    child.on("error", reject);
    child.on("exit", (code) => resolve(code ?? 1));
  });
}

// pnpm ships as a .cmd/.ps1 shim on Windows, so it needs a shell to resolve.
function pnpm(args) {
  return run("pnpm", args, { cwd: repoRoot, shell: process.platform === "win32" });
}

async function main() {
  if (!existsSync(cliEntry)) {
    if (!existsSync(observerModules)) {
      process.stderr.write(
        "verify:onchain: workspace dependencies are not installed yet - running `pnpm install` first.\n"
          + "               This happens once, takes a few minutes, and needs no key and no wallet.\n\n"
      );
      // Only the observer and its own dependencies - viem and TypeScript. The web app is not
      // needed to read Base, and installing it would triple the wait.
      let installExitCode = await pnpm(["install", "--filter", "@aftermarket/observer..."]);
      if (installExitCode !== 0) {
        process.stderr.write(
          "\nverify:onchain: the filtered install did not take - installing the whole workspace.\n\n"
        );
        installExitCode = await pnpm(["install"]);
      }
      if (installExitCode !== 0) {
        process.stderr.write(
          "\nverify:onchain: `pnpm install` failed. Install pnpm 9 (`corepack enable`) and retry.\n"
        );
        process.exitCode = installExitCode;
        return;
      }
      process.stderr.write("\n");
    }

    process.stderr.write("verify:onchain: building @aftermarket/observer.\n\n");
    const buildExitCode = await pnpm(["--filter", "@aftermarket/observer", "build"]);
    if (buildExitCode !== 0) {
      process.exitCode = buildExitCode;
      return;
    }
    process.stderr.write("\n");
  }

  const exitCode = await run(process.execPath, [cliEntry, ...process.argv.slice(2)]);
  process.exitCode = exitCode;
}

main().catch((error) => {
  process.stderr.write(`fatal: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

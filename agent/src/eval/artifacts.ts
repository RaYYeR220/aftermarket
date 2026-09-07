import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { Abi, Hex } from "viem";

const execFileAsync = promisify(execFile);

/** One compiled contract: the ABI and the creation bytecode needed to deploy it on the fork. */
export interface Artifact {
  readonly abi: Abi;
  readonly bytecode: Hex;
}

/**
 * Walks up from this module until it finds the workspace root.
 *
 * The eval needs the repository layout — `contracts/out` for artifacts — and hard-coding a relative
 * depth would break the moment the build output moved. `pnpm-workspace.yaml` is the one file that
 * only exists at the root.
 */
export async function findRepoRoot(): Promise<string> {
  let directory = dirname(fileURLToPath(import.meta.url));
  for (let depth = 0; depth < 8; depth += 1) {
    try {
      await access(join(directory, "pnpm-workspace.yaml"));
      return directory;
    } catch {
      const parent = dirname(directory);
      if (parent === directory) break;
      directory = parent;
    }
  }
  throw new Error("could not locate the workspace root (no pnpm-workspace.yaml found above this module)");
}

/**
 * Loads the compiled contracts the eval deploys onto its fork.
 *
 * The eval deploys the *same* sources the mainnet contracts were compiled from, straight out of
 * `contracts/out`. That matters: a harness built on a reimplementation of `AutoRepayer` would be
 * scoring a model of the agent rather than the agent. Nothing here writes to the contracts
 * workspace except `forge build`, whose output directory is git-ignored build product.
 */
export class ArtifactLoader {
  private readonly cache = new Map<string, Artifact>();
  private built = false;

  constructor(
    private readonly repoRoot: string,
    private readonly contractsDir = "contracts",
  ) {}

  /** `MockOracle` from `contracts/out/MockOracle.sol/MockOracle.json`, and so on. */
  async load(name: string, file = `${name}.sol`): Promise<Artifact> {
    const key = `${file}/${name}`;
    const cached = this.cache.get(key);
    if (cached) return cached;

    const path = join(this.repoRoot, this.contractsDir, "out", file, `${name}.json`);
    let raw: string;
    try {
      raw = await readFile(path, "utf8");
    } catch {
      await this.build();
      raw = await readFile(path, "utf8").catch(() => {
        throw new Error(
          `missing compiled artifact ${file}/${name}.json. Build the contracts first:\n` +
            `  forge build --root ${join(this.repoRoot, this.contractsDir)}`,
        );
      });
    }

    const parsed = JSON.parse(raw) as { abi?: Abi; bytecode?: { object?: string } };
    const bytecode = parsed.bytecode?.object;
    if (!parsed.abi || !bytecode) throw new Error(`artifact ${file}/${name}.json has no abi or bytecode`);

    const artifact: Artifact = { abi: parsed.abi, bytecode: (bytecode.startsWith("0x") ? bytecode : `0x${bytecode}`) as Hex };
    this.cache.set(key, artifact);
    return artifact;
  }

  /**
   * Compiles the contracts workspace once, on the first missing artifact.
   *
   * `contracts/out` is git-ignored, so a clean checkout has no artifacts at all and the eval would
   * otherwise fail with a puzzle instead of a build. The contracts themselves are never touched.
   */
  private async build(): Promise<void> {
    if (this.built) return;
    this.built = true;
    const root = join(this.repoRoot, this.contractsDir);
    process.stderr.write(`compiling contracts (no artifacts found): forge build --root ${root}\n`);
    try {
      await execFileAsync("forge", ["build", "--root", root], { maxBuffer: 32 * 1024 * 1024 });
    } catch (error) {
      throw new Error(
        `forge build failed. Install Foundry, or build the contracts by hand, then re-run the eval.\n` +
          `${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

/** Absolute path to a file inside the repository. */
export function repoPath(repoRoot: string, ...segments: string[]): string {
  return resolve(repoRoot, ...segments);
}

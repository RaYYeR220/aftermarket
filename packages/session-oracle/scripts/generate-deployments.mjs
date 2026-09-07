#!/usr/bin/env node
// Regenerates src/deployments.generated.ts from contracts/deployments/<chainId>.json.
//
// Runs automatically before `build`, `typecheck` and `test` (see package.json). Never fails the
// build: a missing directory, a missing file, or a malformed record all just get skipped (with a
// warning to stderr), so this package always compiles whether or not any chain has been deployed
// to yet. See src/deployments.ts for the JSON schema this expects and the typed API built on top.

import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(__dirname, "..");
const deploymentsDir = resolve(packageRoot, "../../contracts/deployments");
const outFile = join(packageRoot, "src", "deployments.generated.ts");

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

// Every one of these must be a valid address at the record's top level, or the whole chain is
// dropped from the registry. Mirrors the fixed fields of `ChainDeployment` in ./src/deployments.ts.
const ADDRESS_FIELDS = [
  "tradingCalendar",
  "attesterRegistry",
  "regSGate",
  "sessionRateModel",
  "oracleFactory",
  "swapAdapter",
  "credit",
  "vault",
  "autoRepayer",
  "lens",
  "usdc",
  "negativeControl",
];

/** @returns {Record<number, object>} */
function collectDeployments() {
  /** @type {Record<number, object>} */
  const byChain = {};

  if (!existsSync(deploymentsDir)) {
    console.warn(`[session-oracle] ${deploymentsDir} does not exist yet — generating an empty deployment registry.`);
    return byChain;
  }

  const files = readdirSync(deploymentsDir).filter((file) => /^\d+\.json$/.test(file));
  if (files.length === 0) {
    console.warn(`[session-oracle] no <chainId>.json files in ${deploymentsDir} — generating an empty registry.`);
    return byChain;
  }

  for (const file of files) {
    const chainIdFromFilename = Number.parseInt(file, 10);
    const filePath = join(deploymentsDir, file);
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(filePath, "utf8"));
    } catch (error) {
      console.warn(`[session-oracle] skipping ${filePath}: not valid JSON (${error.message}).`);
      continue;
    }

    const chainId = typeof parsed.chainId === "number" ? parsed.chainId : chainIdFromFilename;
    const issue = validateRecord(parsed);
    if (issue) {
      console.warn(`[session-oracle] skipping ${filePath}: ${issue}`);
      continue;
    }

    byChain[chainId] = {
      chainId,
      network: parsed.network,
      usdc: parsed.usdc,
      tradingCalendar: parsed.tradingCalendar,
      attesterRegistry: parsed.attesterRegistry,
      regSGate: parsed.regSGate,
      sessionRateModel: parsed.sessionRateModel,
      oracleFactory: parsed.oracleFactory,
      swapAdapter: parsed.swapAdapter,
      credit: parsed.credit,
      vault: parsed.vault,
      autoRepayer: parsed.autoRepayer,
      lens: parsed.lens,
      negativeControl: parsed.negativeControl,
      oracles: { ...parsed.oracles },
      morphoMarkets: { ...parsed.morphoMarkets },
    };
  }

  return byChain;
}

/** @returns {string | undefined} A human-readable problem, or undefined if the record is valid. */
function validateRecord(record) {
  if (typeof record !== "object" || record === null) return "not an object";
  if (typeof record.network !== "string" || record.network.length === 0) return 'missing string "network"';

  for (const field of ADDRESS_FIELDS) {
    if (typeof record[field] !== "string" || !ADDRESS_RE.test(record[field])) {
      return `field "${field}" is not a 20-byte hex address`;
    }
  }

  if (typeof record.oracles !== "object" || record.oracles === null || Array.isArray(record.oracles)) {
    return 'missing object "oracles"';
  }
  const oracleSymbols = Object.keys(record.oracles);
  if (oracleSymbols.length === 0) return '"oracles" has no entries';
  for (const symbol of oracleSymbols) {
    if (typeof record.oracles[symbol] !== "string" || !ADDRESS_RE.test(record.oracles[symbol])) {
      return `oracle "${symbol}" is not a 20-byte hex address`;
    }
  }

  if (typeof record.morphoMarkets !== "object" || record.morphoMarkets === null || Array.isArray(record.morphoMarkets)) {
    return 'missing object "morphoMarkets"';
  }
  for (const symbol of Object.keys(record.morphoMarkets)) {
    if (typeof record.morphoMarkets[symbol] !== "string" || !BYTES32_RE.test(record.morphoMarkets[symbol])) {
      return `morpho market id for "${symbol}" is not a 32-byte hex id`;
    }
  }

  return undefined;
}

function render(byChain) {
  const chainIds = Object.keys(byChain)
    .map(Number)
    .sort((a, b) => a - b);

  const entries = chainIds.map((chainId) => `  ${chainId}: ${JSON.stringify(byChain[chainId], null, 2).replace(/\n/g, "\n  ")},`).join("\n");

  const body = chainIds.length > 0 ? `{\n${entries}\n}` : "{}";
  const B = "`"; // backtick, kept out of the template literal below so it never needs escaping

  const header = [
    "/**",
    " * AUTO-GENERATED by " + B + "scripts/generate-deployments.mjs" + B + " — do not edit by hand.",
    " *",
    " * Regenerate with " + B + "pnpm --filter @aftermarket/session-oracle run gen:deployments" + B + ",",
    " * which also runs automatically before " + B + "build" + B + ", " + B + "typecheck" + B + " and " + B + "test" + B + ".",
    " *",
    " * Source: " + B + "contracts/deployments/<chainId>.json" + B + ", one file per chain — see " + B + "src/deployments.ts" + B,
    " * for the schema and the typed registry API built on top of this data.",
    " */",
    "",
    "/**",
    " * Mirrors " + B + "ChainDeployment" + B + " in " + B + "./deployments.ts" + B + ". Duplicated here (rather than",
    " * imported) so this generated file has no dependency on hand-written source — the generator",
    " * only ever needs to emit data shaped like this interface, never to import TypeScript logic.",
    " */",
  ].join("\n");

  const hexType = "`0x${string}`"; // TypeScript template-literal type, built as a plain string so
  // this file's own template literal never has to embed an unescaped `${`.

  return `${header}
interface GeneratedChainDeployment {
  chainId: number;
  network: string;
  usdc: ${hexType};
  tradingCalendar: ${hexType};
  attesterRegistry: ${hexType};
  regSGate: ${hexType};
  sessionRateModel: ${hexType};
  oracleFactory: ${hexType};
  swapAdapter: ${hexType};
  credit: ${hexType};
  vault: ${hexType};
  autoRepayer: ${hexType};
  lens: ${hexType};
  negativeControl: ${hexType};
  /** AftermarketOracle addresses keyed by B20 asset symbol, e.g. "AMZNc". */
  oracles: Readonly<Record<string, ${hexType}>>;
  /** Morpho Blue market ids (bytes32), keyed by the collateral symbol the market was created for. */
  morphoMarkets: Readonly<Record<string, ${hexType}>>;
}

export const DEPLOYMENTS_BY_CHAIN: Readonly<Record<number, GeneratedChainDeployment>> = ${body};
`;
}

const byChain = collectDeployments();
writeFileSync(outFile, render(byChain));
const chainCount = Object.keys(byChain).length;
console.log(
  chainCount > 0
    ? `[session-oracle] wrote ${outFile} with deployments for ${chainCount} chain(s).`
    : `[session-oracle] wrote ${outFile} with an empty deployment registry.`,
);

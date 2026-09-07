import type { Metadata } from "next";

import { appStyles, Bay, Meter, ReadFailure } from "@/components/app";
import { BorrowPanels } from "@/components/app/BorrowPanels";
import { DemoStrip } from "@/components/app/Chrome";
import { Countdown } from "@/components/app/Countdown";
import { Readout } from "@/components/primitives";
import { bpsAsWholePercent, durationHm, usdAuto, UNAVAILABLE } from "@/lib/format";
import { SESSION_PHRASE } from "@/lib/session";
import type { Address } from "viem";

import { readLine, type HoldingSnapshot, type LineSnapshot } from "@/server/line";
import { orderedAssets, readProtocol } from "@/server/protocol";
import { readViewer } from "@/server/viewer";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Borrow & repay",
  description:
    "Post collateral, draw USDC, repay and withdraw, with the session-dependent limit read live from the lens as the amount changes.",
};

/**
 * The four actions, each with the engine's own answer about the exact amount in the field.
 *
 * Every amount is put to the chain before it is put to a wallet: `AftermarketLens.previewDraw` and
 * `previewWithdraw` supply the figures, and the transaction itself is simulated from the same
 * account to settle whether it would go through. A refusal is therefore shown with the typed error
 * the call would actually raise, and its arguments, rather than as a guess about it.
 */
export default async function BorrowScreen() {
  const [data, viewer] = await Promise.all([readProtocol(), readViewer()]);

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The protocol read" error={data.error} />
      </div>
    );
  }

  const protocol = data.value;
  const assets = orderedAssets(protocol);
  const lineData = await readLine(viewer.address, protocol);
  const line = lineData.ok ? lineData.value : null;
  const untilOpen = Math.max(0, protocol.nextOpenUnix - protocol.blockTimestampUnix);
  const idleRaw = protocol.idleUsdcRaw;

  return (
    <div className={appStyles.screen}>
      <Header />
      {viewer.isReference && <DemoStrip referenceLine={viewer.address} />}

      <Bay
        title="What the session currently allows"
        note={`block ${protocol.blockNumber.toString()}`}
        refused={line !== null && !line.priced}
      >
        <div className={appStyles.readouts}>
          <Readout size="lg" label="drawn" value={line === null ? null : usdAuto(line.debtUsdc)} />
          <Readout
            size="lg"
            label={line !== null && !line.priced ? "the engine will act on" : "borrowing power"}
            value={
              line === null
                ? null
                : line.priced
                  ? usdAuto(line.borrowPowerUsdc)
                  : line.limits.borrowPowerUsdc === null
                    ? null
                    : usdAuto(line.limits.borrowPowerUsdc)
            }
          />
          <Readout
            size="lg"
            label="advance rate"
            value={`${bpsAsWholePercent(protocol.advanceBps)} of ${bpsAsWholePercent(protocol.advanceOpenBps)} open`}
          />
          <Readout
            size="lg"
            label="idle in the vault"
            value={protocol.idleUsdc === null ? null : usdAuto(protocol.idleUsdc)}
          />
          <Readout
            size="lg"
            label="next defensible print"
            value={
              <Countdown targetUnix={protocol.nextOpenUnix} initial={durationHm(untilOpen)} passed="the bell" />
            }
          />
        </div>

        {line !== null && line.healthState === "measured" && line.healthBps !== null && (
          <div className={appStyles.stacked}>
            <Meter
              value={line.healthBps}
              limit={10_000}
              valueLabel={`${(line.healthBps / 100).toFixed(1)}% of the seizure threshold`}
              limitLabel="100%"
              direction="above-is-safe"
            />
          </div>
        )}

        <p className={appStyles.explain}>
          {line !== null && !line.priced
            ? `An oracle in this basket will not publish a mark ${SESSION_PHRASE[protocol.session]}. That leg now counts as worth zero rather than blocking the line: the engine still lends against everything it can price${line.limits.borrowPowerUsdc === null ? "" : ` — ${usdAuto(line.limits.borrowPowerUsdc)} of it`}, and will not publish a total for the basket as a whole.`
            : `The advance rate is ${bpsAsWholePercent(protocol.advanceBps)} ${SESSION_PHRASE[protocol.session]}, against ${bpsAsWholePercent(protocol.advanceOpenBps)} between the bells. The difference is gap risk: with the tape shut, nobody can hedge a move that has already happened somewhere else.`}
        </p>
      </Bay>

      <BorrowPanels
        assets={assets.map((asset) => ({
          address: asset.address,
          symbol: asset.symbol,
          underlying: asset.underlying,
          decimals: asset.decimals,
          quoting: asset.refusal === null,
        }))}
        fallbackAddress={viewer.address}
        initial={{
          debt: (line?.debtRaw ?? 0n).toString(),
          idle: idleRaw === null ? null : idleRaw.toString(),
          usdcBalance: text(line?.usdcBalanceRaw ?? null),
          usdcAllowance: text(line?.usdcAllowanceToCredit ?? null),
          posted: assets.map((asset) => text(holdingOf(line, asset.address)?.postedRaw ?? null)),
          wallet: assets.map((asset) => text(holdingOf(line, asset.address)?.walletRaw ?? null)),
          allowance: assets.map((asset) => text(holdingOf(line, asset.address)?.allowanceRaw ?? null)),
        }}
      />

      <Bay title="What cannot be blocked" lede="Two actions have no session, no oracle and no keeper standing in front of them.">
        <div className={appStyles.split}>
          <div>
            <Readout label="always accepted" value="repay" size="lg" />
            <p className={appStyles.explain}>
              A borrower can always cure. Repayment does not read a price, so no oracle state can stop it, and a
              flagged line clears its own flag in the same transaction the moment it is healthy again.
            </p>
          </div>
          <div>
            <Readout label="always accepted" value="post collateral" size="lg" />
            <p className={appStyles.explain}>
              More collateral cannot make a line less safe, so the engine takes it under any session. What it
              will not do is publish what the basket is worth while one of its oracles refuses —{" "}
              {line === null
                ? UNAVAILABLE
                : line.priced
                  ? "and right now every oracle behind this line is answering."
                  : "which is where this basket is right now."}
            </p>
          </div>
        </div>
      </Bay>
    </div>
  );
}

/** `bigint` to the decimal string a client component can receive, or `null` when it was not read. */
function text(value: bigint | null): string | null {
  return value === null ? null : value.toString();
}

/** The server's holding for one collateral asset. */
function holdingOf(line: LineSnapshot | null, asset: Address): HoldingSnapshot | null {
  if (line === null) return null;
  return line.holdings.find((holding) => holding.address.toLowerCase() === asset.toLowerCase()) ?? null;
}

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Borrow &amp; repay</h1>
      <p className={appStyles.headLede}>
        Every amount you type is put to the engine before it is put to your wallet. If the call would revert,
        this screen names the typed error, prints the arguments the contract put inside it, and explains the
        rule behind it — rather than letting your wallet find out for you.
      </p>
    </header>
  );
}

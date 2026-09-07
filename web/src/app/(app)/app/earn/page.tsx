import type { Metadata } from "next";

import { appStyles, AddressLink, Bay, Meter, ReadFailure, SessionLadder } from "@/components/app";
import { DemoStrip } from "@/components/app/Chrome";
import { EarnPanels } from "@/components/app/EarnPanels";
import { Readout } from "@/components/primitives";
import { DEPLOYMENT } from "@/lib/deployment";
import { usdAuto, UNAVAILABLE } from "@/lib/format";
import { SESSION_PHRASE, Session } from "@/lib/session";
import { readLine } from "@/server/line";
import { readProtocol } from "@/server/protocol";
import { readViewer } from "@/server/viewer";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Earn",
  description:
    "The ERC-4626 lender vault: deposit and withdraw USDC, the current supply rate, utilisation, and the closed-market premium read from the rate model rather than asserted.",
};

/**
 * The lender side.
 *
 * The interesting number here is not the headline rate, it is the ladder underneath it. The same
 * utilisation is priced in all six sessions by reading `SessionRateModel.ratePerSecondAt` once per
 * session, so the closed-market premium is a measurement of the deployed contract rather than a
 * claim this page is making about it.
 */
export default async function EarnScreen() {
  const [data, viewer] = await Promise.all([readProtocol(), readViewer()]);

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The vault read" error={data.error} />
      </div>
    );
  }

  const protocol = data.value;
  const lineData = await readLine(viewer.address, protocol);
  const line = lineData.ok ? lineData.value : null;
  const asset = protocol.assets[0] ?? null;
  const supplyApr = asset?.supplyAprPercent ?? null;
  const borrowApr = asset?.borrowAprPercent ?? null;
  const outOnLoan = protocol.totalDebtUsdc;
  const rates = protocol.sessionRates;
  const openRate = rates?.find((rate) => rate.session === Session.REGULAR) ?? null;
  const currentRate = rates?.find((rate) => rate.isCurrent) ?? null;
  const widest = rates === null ? 0 : Math.max(...rates.map((rate) => rate.aprPercent));

  return (
    <div className={appStyles.screen}>
      <Header />
      {viewer.isReference && <DemoStrip referenceLine={viewer.address} />}

      <Bay
        title={protocol.vaultName ?? "The lender vault"}
        note={
          <>
            {protocol.vaultSymbol ?? UNAVAILABLE} · <AddressLink address={DEPLOYMENT.vault} />
          </>
        }
      >
        <div className={appStyles.readouts}>
          <Readout size="lg" label="supply rate now" value={supplyApr === null ? null : `${supplyApr.toFixed(2)}%`} />
          <Readout size="lg" label="borrow rate now" value={borrowApr === null ? null : `${borrowApr.toFixed(2)}%`} />
          <Readout size="lg" label="total supplied" value={usdAuto(protocol.totalSuppliedUsdc)} />
          <Readout size="lg" label="out on loan" value={usdAuto(outOnLoan)} />
          <Readout size="lg" label="idle" value={protocol.idleUsdc === null ? null : usdAuto(protocol.idleUsdc)} />
        </div>

        <div className={appStyles.stacked}>
          <Meter
            value={protocol.utilisation * 100}
            limit={(protocol.kink ?? 0.8) * 100}
            valueLabel={`${(protocol.utilisation * 100).toFixed(1)}% utilisation`}
            limitLabel={protocol.kink === null ? UNAVAILABLE : `${(protocol.kink * 100).toFixed(0)}% kink`}
          />
        </div>

        <p className={appStyles.explain}>
          Utilisation is how much of the supplied USDC is out on loan. Up to the kink the rate rises gently;
          past it the curve steepens hard, which is what keeps a withdrawal possible instead of theoretical.
          One whole share is currently worth {usdAuto(protocol.vaultSharePriceUsdc)}.
        </p>
      </Bay>

      <EarnPanels
        fallbackAddress={viewer.address}
        shareDecimals={protocol.vaultDecimals ?? 6}
        shareSymbol={protocol.vaultSymbol ?? "shares"}
        initial={{
          shares: text(line?.vaultSharesRaw ?? null),
          withdrawable: text(line?.vaultWithdrawableRaw ?? null),
          usdcBalance: text(line?.usdcBalanceRaw ?? null),
          usdcAllowance: text(line?.usdcAllowanceToVault ?? null),
        }}
      />

      <Bay
        title="What a closed market costs"
        lede="The borrow rate is the utilisation curve multiplied by a session factor. It is not a spread this interface has invented: each row below is one call to the deployed rate model, asking it to price this exact utilisation in that session."
        note={rates === null ? UNAVAILABLE : `${rates.length} sessions read`}
      >
        {rates === null ? (
          <p className={appStyles.explain}>
            The rate model did not answer, so the session ladder is {UNAVAILABLE}. The headline rates above come
            from the lens and are unaffected.
          </p>
        ) : (
          <SessionLadder
            entries={rates.map((rate) => ({
              session: rate.session,
              fraction: widest === 0 ? 0 : rate.aprPercent / widest,
              value: `${rate.aprPercent.toFixed(2)}%`,
              isCurrent: rate.isCurrent,
            }))}
            caption={
              openRate === null || currentRate === null
                ? "Each row is the borrow APR the deployed rate model returns for the current utilisation in that session."
                : `Borrowing ${SESSION_PHRASE[currentRate.session]} costs ${currentRate.premium.toFixed(2)}× the open-market rate — ${currentRate.aprPercent.toFixed(2)}% against ${openRate.aprPercent.toFixed(2)}%. A lender is carrying gap risk for the whole closed stretch: the position cannot be hedged, unwound or seized until the bell, and the premium is what pays for that.`
            }
          />
        )}
      </Bay>

      <Bay title="What a lender is actually exposed to">
        <div className={appStyles.split}>
          <div>
            <Readout size="lg" label="the good case" value="the borrower repays" />
            <p className={appStyles.explain}>
              Interest accrues per second at the session rate and lands in the vault as borrowers repay. Share
              price rises; no share is ever minted for yield.
            </p>
          </div>
          <div>
            <Readout size="lg" label="the bad case" value="bad debt is written down" />
            <p className={appStyles.explain}>
              If a seizure leaves a line with debt and no collateral worth taking, the shortfall is written down
              against the vault and every share loses value at once. The protocol never hides that in a reserve
              it does not have; the write-down is an event on the activity feed.
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

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Earn</h1>
      <p className={appStyles.headLede}>
        Lend USDC against tokenized equity collateral. A closed market pays more than an open one, because the
        loan cannot be hedged, unwound or seized until the opening bell — and this screen shows you the exact
        multiple, read from the rate model itself.
      </p>
    </header>
  );
}

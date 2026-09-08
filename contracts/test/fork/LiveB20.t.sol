// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketOracle} from "../../src/AftermarketOracle.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IEligibility} from "../../src/interfaces/IEligibility.sol";
import {Quote, Session, Verdict} from "../../src/libraries/Types.sol";

import {ForkBase} from "./ForkBase.sol";

/// @title  LiveB20Test
/// @notice The whole protocol, deployed into a fork of Base mainnet at the current head and driven
///         against real B20 equity precompiles, real Chainlink aggregators and real Aerodrome pools.
///
/// @dev Run with `base-forge test`, never with stock `forge test`: a B20 token is a Rust precompile
///      inside Base's node, not EVM bytecode, and stock forge halts with `OpcodeNotFound` the moment
///      one of these tests touches `NVDAc.transfer`. See `test/fork/README.md`.
///
///      Everything here is live except two clearly labelled inputs: starting USDC balances, which
///      are seeded into the real USDC contract's storage the way every fork test seeds balances, and
///      one raised B20 `multiplier()` in `test_sweepYield_simulatedMultiplierIncrease`, because no
///      distribution has occurred on any live B20 equity since the 2026-08-24 launch and the sweep
///      path is otherwise unreachable. That same test also re-issues the live Chainlink answer with
///      a fresh `updatedAt` at the next opening bell, because `sweepYield` now refuses to send a
///      market order while the US market is shut and a fork pinned outside those hours has no
///      in-session round to read.
///
///      Two tests re-fork onto a pinned historical block instead of the head, because each asserts a
///      live market condition that has since ended: `test_amznDivergenceFreezesRiskAndSeizureButNot
///      TheCure` needs AMZNc's sources to be apart, and `test_sweepYield_simulatedMultiplierIncrease`
///      needs the US market to be shut. Both conditions held on Labor Day and neither holds now, so
///      both are pinned rather than softened.
contract LiveB20Test is ForkBase {
    /// @notice USDC the lender puts behind the market.
    uint256 internal constant SUPPLY = 1_000_000e6;

    /// @notice USDC spent buying NVDAc collateral through the live pool.
    uint256 internal constant NVDA_BUY = 60_000e6;

    /// @notice USDC spent buying AMZNc collateral through the live pool.
    /// @dev Deliberately small. The AMZNc pool is the thinnest of the six and the point of the test
    ///      is to observe it, not to move it.
    uint256 internal constant AMZN_BUY = 3_000e6;

    /// @notice 2026-09-07 12:27:13 UTC, Labor Day. AMZNc's Chainlink anchor had been frozen since
    ///         Friday's close while the pool kept trading, and the two disagreed by 897 bps against
    ///         a 300 bps band. The same block every `--block` read in JUDGES.md and PROOF.md uses.
    /// @dev Needs an archive endpoint, like the rest of `test/fork`.
    uint256 internal constant BLOCK_AMZN_DIVERGED = 50_997_343;

    /// @notice The same Labor Day block, pinned here for a different live fact about it:
    ///         `TradingCalendar.session()` returned `CLOSED_HOLIDAY`, so there was a shut market for
    ///         `sweepYield` to refuse to send a market order into.
    /// @dev Pinned on 2026-09-08. `test_sweepYield_simulatedMultiplierIncrease` used to read the
    ///      head, which was fine for as long as the head was inside the 89 h 30 m Labor Day closure.
    ///      At 09:30 ET that morning the market reopened, the head stopped being a closed session,
    ///      and the `MarketClosed` assertion below started failing on a protocol that was behaving
    ///      correctly - `sweepYield` reverted `NothingToSweep` instead, because the market was open
    ///      and the multiplier had not moved. The assertion is unchanged; only the block it is made
    ///      at is now fixed, for the same reason `BLOCK_AMZN_DIVERGED` is.
    uint256 internal constant BLOCK_MARKET_CLOSED = BLOCK_AMZN_DIVERGED;

    function setUp() public {
        _forkLatest();
        _deployStack();

        _attest(lender);
        _attest(borrower);
        _attest(borrowerTwo);
        _attest(liquidator);

        console2.log("fork block   ", block.number);
        console2.log("fork unix ts ", block.timestamp);
        console2.log("session      ", _sessionName(calendar.session()));
    }

    /*//////////////////////////////////////////////////////////////
                             1. THE SUPPLY SIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice A lender supplies real USDC to the vault and gets ERC-4626 shares back.
    function test_lenderSuppliesRealUsdcAndReceivesShares() public {
        _seedUsdc(lender, SUPPLY);

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(vault));

        vm.prank(lender);
        uint256 shares = vault.deposit(SUPPLY, lender);

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.balanceOf(lender), shares, "shares not credited to the lender");
        assertEq(IERC20(USDC).balanceOf(address(vault)) - vaultUsdcBefore, SUPPLY, "vault did not receive the USDC");
        assertEq(vault.totalAssets(), SUPPLY, "totalAssets does not match the supply");
        assertEq(vault.convertToAssets(shares), SUPPLY, "share price is not 1:1 on an empty vault");
        assertEq(vault.maxWithdraw(lender), SUPPLY, "idle liquidity should be fully withdrawable");

        console2.log("supplied USDC", SUPPLY);
        console2.log("shares       ", shares);
    }

    /*//////////////////////////////////////////////////////////////
                          2. THE BORROW SIDE, LIVE
    //////////////////////////////////////////////////////////////*/

    /// @notice A borrower posts real NVDAc bought through the live Aerodrome pool and draws real
    ///         USDC, and the drawn amount is exactly the session-adjusted advance rate applied to
    ///         the live oracle mark.
    function test_borrowerDrawsAgainstRealNvdaCollateralAtTheLiveMark() public {
        _supplyLiquidity();

        uint256 collateralAmount = _buyCollateral(NVDA, NVDA_BUY, borrower);
        assertEq(IERC20(NVDA).balanceOf(borrower), collateralAmount, "collateral did not land on the borrower");

        vm.startPrank(borrower);
        credit.openLine();
        credit.depositCollateral(NVDA, collateralAmount);
        vm.stopPrank();

        assertEq(credit.collateral(borrower, NVDA), collateralAmount, "collateral not booked");
        assertEq(_posted(NVDA), collateralAmount, "protocol-wide posted balance not booked");

        AftermarketOracle oracle = oracleOf[NVDA];
        Quote memory q = oracle.peek();
        Session session = calendar.session();

        uint256 expected = _expectedPower(collateralAmount, oracle.markBorrow(), session);
        assertEq(credit.borrowPower(borrower), expected, "borrow power is not the advance rate on the live mark");

        uint256 usdcBefore = IERC20(USDC).balanceOf(borrower);
        vm.prank(borrower);
        credit.draw(expected, borrower);

        assertEq(IERC20(USDC).balanceOf(borrower) - usdcBefore, expected, "draw did not deliver the USDC");
        assertEq(credit.debtOf(borrower), expected, "debt does not equal the drawn amount");

        // The advance rate is a hard ceiling, not a guideline: one more unit is refused.
        vm.prank(borrower);
        vm.expectPartialRevert(IAftermarketCredit.Undercollateralized.selector);
        credit.draw(1, borrower);

        console2.log("NVDAc bought (1e8)  ", collateralAmount);
        console2.log("verdict             ", _verdictName(q.verdict));
        console2.log("anchor USD (1e18)   ", q.anchorPrice);
        console2.log("pool TWAP USD (1e18)", q.poolPrice);
        console2.log("haircut bps         ", q.haircutBps);
        console2.log("advance bps         ", _advanceBps(session));
        console2.log("drawn USDC (1e6)    ", expected);
    }

    /*//////////////////////////////////////////////////////////////
                       3. THE AMZNc CASE - THE HEADLINE
    //////////////////////////////////////////////////////////////*/

    /// @notice The AMZNc market, priced exactly as it stands on Base mainnet right now.
    ///
    /// @dev This is the most important test in the repository. Nothing here is constructed: the AMZN
    ///      Chainlink aggregator last moved at Friday's close and is now more than fifty hours old,
    ///      while the thin AMZNc/USDC Slipstream pool has kept printing all weekend and has walked
    ///      hundreds of basis points away from it. The oracle sees two sources that disagree far
    ///      beyond the weekend band, declines to pick a winner, and refuses to quote.
    ///
    ///      What that refusal does downstream is the entire thesis of the protocol, so each half is
    ///      asserted on its own:
    ///
    ///      - `price()`, `markBorrow()` and `markLiquidate()` revert `SourcesDiverged`;
    ///      - AMZNc adds ZERO borrowing power: an unpriceable asset is credited with nothing, so
    ///        no new risk is ever taken against a price nobody can defend;
    ///      - `quoteSeizure` on AMZNc reverts: the unpriceable asset itself can never be taken;
    ///      - `flag` refuses on the merits, because the collateral that CAN be priced still covers
    ///        the debt - and not because one unpriceable leg vetoed the question;
    ///      - `liquidate` is unreachable: it demands a flag that the priceable basket does not
    ///        justify;
    ///      - `depositCollateral` succeeds: the borrower may always improve their position;
    ///      - `repay` succeeds: the borrower may always cure.
    ///
    ///      The zero-credit rule is the half that changed. Reading the AMZNc oracle inside the
    ///      basket walk and letting its revert propagate made the health of an eight-asset line a
    ///      logical AND over eight independent oracles, so one raw unit of the thinnest listed
    ///      market - or an issuer pausing it around a corporate action - switched off `flag` and
    ///      `liquidate` for the whole position while the debt stayed outstanding. What keeps the
    ///      replacement safe is the asymmetry asserted below: the unpriceable leg is worth nothing
    ///      to the borrower AND cannot be seized by anybody.
    ///
    ///      **This is the one test in this file that is pinned rather than run at head**, and the
    ///      reason is worth stating. The condition it is about - AMZNc's pool disagreeing with its
    ///      frozen anchor by more than the session's band - is a live market state, not a property
    ///      of the code. It held for the whole of the 2026-09-05 close; by Monday evening the gap
    ///      had closed from 897 bps to 145, back inside the 300 bps weekend band, and the oracle
    ///      went back to marking AMZNc. That is the mechanism working, and it also means an
    ///      unpinned assertion here would fail every time the market agreed with itself. A test
    ///      that only passes while a market happens to be dislocated is a test that will one day
    ///      report a fault that is not there, so the block is fixed. For the live gap, run
    ///      `pnpm verify:onchain`; for the same behaviour at other historical blocks, see
    ///      `WeekendReplay`.
    function test_amznDivergenceFreezesRiskAndSeizureButNotTheCure() public {
        _forkAt(BLOCK_AMZN_DIVERGED);
        _deployStack();
        _attest(lender);
        _attest(borrower);
        _attest(borrowerTwo);
        _attest(liquidator);
        console2.log("pinned block ", block.number);

        _supplyLiquidity();

        // The line is opened and drawn against NVDAc first, so that when AMZNc joins the basket
        // there is a live debt to prove `repay` still works against.
        uint256 nvdaAmount = _buyCollateral(NVDA, 40_000e6, borrowerTwo);
        vm.startPrank(borrowerTwo);
        credit.openLine();
        credit.depositCollateral(NVDA, nvdaAmount);
        credit.draw(2_000e6, borrowerTwo);
        vm.stopPrank();
        assertEq(credit.debtOf(borrowerTwo), 2_000e6, "setup draw failed");

        AftermarketOracle amznOracle = oracleOf[AMZN];

        // --- the verdict, straight off mainnet ------------------------------------------------
        Quote memory q = amznOracle.peek();
        console2.log("AMZNc verdict        ", _verdictName(q.verdict));
        console2.log("AMZNc session        ", _sessionName(q.session));
        console2.log("AMZN feed age (s)    ", q.feedAge);
        console2.log("AMZN staleness budget", q.stalenessBudget);
        console2.log("AMZN anchor  (1e18)  ", q.anchorPrice);
        console2.log("AMZNc pool   (1e18)  ", q.poolPrice);
        console2.log("divergence bps       ", q.divergenceBps);
        console2.log("divergence band bps  ", q.divergenceBand);
        console2.log("pool USDC depth(1e18)", q.poolLiquidityUsd);

        // This is a live market condition, so the assertion is written against the session the
        // chain is actually in rather than hard-coding one. `WeekendReplay` pins the same
        // divergence at fixed historical blocks, where it can never drift.
        assertFalse(calendar.isOpen(block.timestamp), "the US market must be shut for this test to mean anything");
        assertEq(q.divergenceBand, _divergenceBands()[uint256(q.session)], "band must be the one for this session");
        if (q.session == Session.CLOSED_WEEKEND) {
            assertEq(q.divergenceBand, WEEKEND_BAND_BPS, "weekend divergence band");
        }
        assertGt(q.feedAge, 50 hours, "the AMZN feed is expected to be stale from Friday's close");
        assertLe(q.feedAge, q.stalenessBudget, "staleness must not be what condemns this market");
        assertGe(q.poolLiquidityUsd, MIN_POOL_LIQUIDITY_USD, "the pool must be deep enough to corroborate");
        assertGt(q.divergenceBps, q.divergenceBand, "the two sources must disagree beyond the band");
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "verdict must be UNTRUSTED_DIVERGENT");

        // --- the oracle refuses to quote ------------------------------------------------------
        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        amznOracle.price();

        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        amznOracle.markBorrow();

        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        amznOracle.markLiquidate();

        // --- posting AMZNc still works: collateral only ever reduces risk ----------------------
        uint256 powerBeforeAmzn = credit.borrowPower(borrowerTwo);

        uint256 amznAmount = _buyCollateral(AMZN, AMZN_BUY, borrowerTwo);
        vm.prank(borrowerTwo);
        credit.depositCollateral(AMZN, amznAmount);
        assertEq(credit.collateral(borrowerTwo, AMZN), amznAmount, "AMZNc deposit must succeed");

        // A second deposit, now that part of the basket is unpriceable, must also succeed.
        uint256 topUp = _buyCollateral(AMZN, 200e6, borrowerTwo);
        vm.prank(borrowerTwo);
        credit.depositCollateral(AMZN, topUp);
        assertEq(credit.collateral(borrowerTwo, AMZN), amznAmount + topUp, "AMZNc top-up must succeed");

        // --- the unpriceable leg is worth exactly nothing -------------------------------------
        // The public views still refuse a partially-priced basket outright, so that an integrator
        // reading a number can never mistake it for a full valuation.
        vm.expectPartialRevert(IAftermarketCredit.UnpricedCollateral.selector);
        credit.borrowPower(borrowerTwo);
        assertFalse(credit.positionOf(borrowerTwo).priced, "positionOf must report the basket as unpriced");

        // The engine's own arithmetic is the thing being pinned, and `draw` is where it is
        // observable: the NVDAc leg alone still supports every dollar of headroom it did before,
        // and the thousands of dollars of AMZNc on top of it bought exactly none.
        uint256 headroom = powerBeforeAmzn - credit.debtOf(borrowerTwo);
        vm.prank(borrowerTwo);
        credit.draw(headroom, borrowerTwo);

        vm.prank(borrowerTwo);
        vm.expectPartialRevert(IAftermarketCredit.Undercollateralized.selector);
        credit.draw(1e6, borrowerTwo);

        // --- and it cannot be taken either ----------------------------------------------------
        // Quoting a seizure of AMZNc reads the optimistic mark directly and still reverts: nobody
        // may ever be paid in collateral at a price the protocol cannot defend.
        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        credit.quoteSeizure(borrowerTwo, AMZN, 100e6);

        // --- the flag refuses on the merits, not on the veto ----------------------------------
        // The NVDAc leg alone still covers the debt, so the line is healthy. That is a real
        // judgement about the collateral the protocol can price, not an oracle refusal.
        vm.expectPartialRevert(IAftermarketCredit.LineHealthy.selector);
        credit.flag(borrowerTwo);

        // And `liquidate` is therefore unreachable: it demands a flag the basket does not justify.
        _seedUsdc(liquidator, 10_000e6);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NotFlagged.selector, borrowerTwo));
        credit.liquidate(borrowerTwo, AMZN, 100e6);

        // Before any of that, against the live gate on real Base mainnet state: an account with no
        // proven jurisdiction cannot be the one the securities are transferred to, whether it names
        // itself or is named by an attested caller. This runs ahead of the `NotFlagged` check
        // above, which is the point - the gate is the first thing `liquidate` consults.
        vm.prank(unattested);
        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, unattested));
        credit.liquidate(borrowerTwo, AMZN, 100e6);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, unattested));
        credit.liquidate(borrowerTwo, AMZN, 100e6, unattested);

        // --- and the borrower can always cure -------------------------------------------------
        _seedUsdc(borrowerTwo, 5_000e6);
        vm.prank(borrowerTwo);
        (uint256 repaidAssets,) = credit.repay(500e6);
        assertEq(repaidAssets, 500e6, "partial repay must succeed");

        vm.prank(borrowerTwo);
        credit.repay(type(uint256).max);
        assertEq(credit.debtOf(borrowerTwo), 0, "full repay must clear the line");

        // Debt cleared, the collateral is unconditionally theirs again - including the AMZNc that
        // nobody can price.
        vm.prank(borrowerTwo);
        credit.withdrawCollateral(AMZN, amznAmount + topUp, borrowerTwo);
        assertEq(credit.collateral(borrowerTwo, AMZN), 0, "a debt-free borrower must never be trapped");
        assertEq(IERC20(AMZN).balanceOf(borrowerTwo), amznAmount + topUp, "AMZNc not returned");
    }

    /*//////////////////////////////////////////////////////////////
                        4. THE ROUND TRIP ENDS WHOLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Draw, repay, withdraw: the borrower ends with their collateral back and the vault
    ///         ends with at least what it started with.
    function test_borrowerRepaysAndWithdrawsEndingWhole() public {
        _supplyLiquidity();

        uint256 collateralAmount = _buyCollateral(NVDA, NVDA_BUY, borrower);
        _approveUsdc(borrower);
        uint256 vaultAssetsBefore = vault.totalAssets();

        vm.startPrank(borrower);
        credit.openLine();
        credit.depositCollateral(NVDA, collateralAmount);
        uint256 drawn = credit.borrowPower(borrower);
        credit.draw(drawn, borrower);
        vm.stopPrank();

        // Withdrawing collateral while the debt is live is refused on its merits, not on a technicality.
        vm.prank(borrower);
        vm.expectPartialRevert(IAftermarketCredit.Undercollateralized.selector);
        credit.withdrawCollateral(NVDA, collateralAmount, borrower);

        vm.startPrank(borrower);
        (uint256 repaid,) = credit.repay(type(uint256).max);
        credit.withdrawCollateral(NVDA, collateralAmount, borrower);
        vm.stopPrank();

        assertEq(repaid, drawn, "repaid amount should equal the draw inside one block");
        assertEq(credit.debtOf(borrower), 0, "debt outstanding");
        assertEq(credit.collateral(borrower, NVDA), 0, "collateral still held");
        assertEq(_posted(NVDA), 0, "protocol-wide posted balance not unwound");
        assertEq(IERC20(NVDA).balanceOf(borrower), collateralAmount, "collateral not returned in full");
        assertEq(credit.assetsOf(borrower).length, 0, "posted-asset list not cleared");
        assertGe(vault.totalAssets(), vaultAssetsBefore, "the vault must not end behind");

        // The lender can leave with everything they put in.
        uint256 lenderShares = vault.balanceOf(lender);
        vm.prank(lender);
        uint256 redeemed = vault.redeem(lenderShares, lender, lender);
        assertGe(redeemed, SUPPLY, "the lender must not end behind");

        console2.log("drawn USDC   ", drawn);
        console2.log("repaid USDC  ", repaid);
        console2.log("redeemed USDC", redeemed);
    }

    /*//////////////////////////////////////////////////////////////
                        5. EVERY MARKET STAYS READABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice `peek()` answers coherently for every configured market and never reverts, including
    ///         for the ones whose `price()` is currently refusing to quote.
    function test_peekIsCoherentForEveryConfiguredAsset() public view {
        Session session = calendar.session();

        console2.log("");
        console2.log("ticker  verdict              feedAge(s)  divBps  band  haircut  anchorUSD  poolUSD");

        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            Quote memory q = oracleOf[asset].peek();

            assertEq(uint256(q.session), uint256(session), "every oracle must agree on the session");
            assertEq(q.stalenessBudget, _stalenessBudgets()[uint256(session)], "staleness budget mismatch");
            assertEq(q.divergenceBand, _divergenceBands()[uint256(session)], "divergence band mismatch");
            assertGt(q.anchorPrice, 0, "a live equity feed must report a positive price");
            assertEq(q.multiplier, 1e18, "no B20 distribution has occurred yet");
            assertLe(q.haircutBps, MAX_HAIRCUT_BPS, "haircut above its own ceiling");

            if (q.markBorrow != 0) {
                assertLe(q.markBorrow, q.markLiquidate, "the pessimistic mark must not exceed the optimistic one");
            }
            if (q.poolLiquidityUsd >= MIN_POOL_LIQUIDITY_USD) {
                assertGt(q.poolPrice, 0, "a deep pool must produce a TWAP");
            }

            console2.log(_peekRow(tickerOf[asset], q));
        }
    }

    /// @dev Split out of the loop so the row builder's locals do not share a stack frame with the
    ///      assertions above it.
    function _peekRow(string memory ticker, Quote memory q) private pure returns (string memory row) {
        row = string.concat(_pad(ticker, 8), _pad(_verdictName(q.verdict), 21));
        row = string.concat(row, _padLeft(vm.toString(q.feedAge), 10), _padLeft(vm.toString(q.divergenceBps), 8));
        row = string.concat(row, _padLeft(vm.toString(q.divergenceBand), 6), _padLeft(vm.toString(q.haircutBps), 9));
        row = string.concat(row, _padLeft(_fixed(q.anchorPrice, 18, 2), 11), _padLeft(_fixed(q.poolPrice, 18, 2), 9));
    }

    /*//////////////////////////////////////////////////////////////
              6. SELF-REPAYING COLLATERAL - ONE SIMULATED INPUT
    //////////////////////////////////////////////////////////////*/

    /// @notice `sweepYield` against a real B20 token and a real Aerodrome pool, driven by a
    ///         SIMULATED multiplier increase.
    ///
    /// @dev THIS IS THE ONE SIMULATED INPUT IN THIS FILE. Every live B20 equity still reports
    ///      `multiplier() == 1e18`, because no dividend or split has been distributed since the
    ///      2026-08-24 launch - the test asserts that against mainnet before touching anything. The
    ///      distribution itself is therefore mocked, by intercepting `multiplier()` on the NVDAc
    ///      precompile and returning 1.05e18. Everything downstream of that single value is real:
    ///      the collateral is real NVDAc bought through the live pool, the slice is computed by the
    ///      production contract, the sale is a real swap through the real Slipstream router against
    ///      the real pool, and the proceeds really do burn debt shares.
    function test_sweepYield_simulatedMultiplierIncrease() public {
        _forkAt(BLOCK_MARKET_CLOSED);
        _deployStack();
        _attest(lender);
        _attest(borrower);
        _attest(borrowerTwo);
        _attest(liquidator);
        console2.log("pinned block ", block.number);

        _supplyLiquidity();

        uint256 collateralAmount = _buyCollateral(NVDA, NVDA_BUY, borrower);

        vm.startPrank(borrower);
        credit.openLine();
        credit.depositCollateral(NVDA, collateralAmount);
        uint256 drawn = credit.borrowPower(borrower);
        credit.draw(drawn, borrower);
        vm.stopPrank();

        // The live fact this test is built on: no distribution has happened yet.
        assertEq(_liveMultiplier(NVDA), 1e18, "a live B20 multiplier is expected to still be exactly 1e18");
        assertEq(credit.multiplierCheckpoint(borrower, NVDA), 1e18, "checkpoint should have recorded the live value");

        // `sweepYield` sends a market order, so it only runs while the US market is open: that is
        // when the gap haircut folded into `markBorrow` - and therefore into the slippage floor
        // derived from it - is zero by construction, and when the pool is at its deepest.
        vm.prank(borrower);
        vm.expectPartialRevert(IAftermarketCredit.MarketClosed.selector);
        credit.sweepYield(borrower, NVDA);
        _openTheMarket();

        // Nothing to sweep while the multiplier has not moved.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, borrower, NVDA));
        credit.sweepYield(borrower, NVDA);

        // ---- SIMULATED INPUT: a 5% distribution on NVDAc -------------------------------------
        uint256 raised = 1.05e18;
        vm.mockCall(NVDA, abi.encodeWithSignature("multiplier()"), abi.encode(raised));
        assertEq(_liveMultiplier(NVDA), raised, "multiplier mock did not take");
        // --------------------------------------------------------------------------------------

        uint256 expectedSold = (collateralAmount * (raised - 1e18)) / raised;
        uint256 mark = oracleOf[NVDA].markBorrow();
        uint256 expectedMinOut = ((((expectedSold * mark) / ORACLE_SCALE) * (BPS - MAX_SLIPPAGE_BPS)) / BPS);

        uint256 debtBefore = credit.debtOf(borrower);
        uint256 vaultBefore = IERC20(USDC).balanceOf(address(vault));

        vm.prank(borrower);
        (uint256 sold, uint256 proceeds, uint256 repaid) = credit.sweepYield(borrower, NVDA);

        assertEq(sold, expectedSold, "the sold slice is not (m - m0) / m of the position");
        assertGe(proceeds, expectedMinOut, "the sale broke the oracle-derived slippage floor");
        assertEq(repaid, proceeds, "with debt outstanding every dollar of proceeds should burn debt");
        assertEq(debtBefore - credit.debtOf(borrower), repaid, "debt did not fall by the repaid amount");
        assertEq(credit.collateral(borrower, NVDA), collateralAmount - sold, "collateral did not fall by the slice");
        assertEq(_posted(NVDA), collateralAmount - sold, "protocol-wide posted balance not reduced");
        assertEq(IERC20(USDC).balanceOf(address(vault)) - vaultBefore, repaid, "proceeds did not reach the vault");
        assertEq(credit.multiplierCheckpoint(borrower, NVDA), raised, "checkpoint not rolled forward");
        assertLt(sold, collateralAmount, "the position must survive its own sweep");

        // A second sweep at the same multiplier has nothing left to sell.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, borrower, NVDA));
        credit.sweepYield(borrower, NVDA);

        console2.log("drawn USDC        ", drawn);
        console2.log("slice sold (1e8)  ", sold);
        console2.log("min out USDC      ", expectedMinOut);
        console2.log("proceeds USDC     ", proceeds);
        console2.log("debt repaid USDC  ", repaid);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Warps to the next real opening bell and re-issues the live Chainlink answer with a
    ///         fresh `updatedAt`, standing in for the print the aggregator publishes at that bell.
    /// @dev SIMULATED INPUT. A fork pinned outside US market hours has no in-session round to read,
    ///      so the *timing* of the print is simulated while its value stays exactly the live one.
    function _openTheMarket() private {
        vm.warp(uint256(calendar.nextOpen(block.timestamp)) + 15 minutes);
        assertTrue(calendar.isOpen(block.timestamp), "the warp must land inside a regular session");

        (uint80 roundId, int256 answer,,,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(roundId + 1, answer, block.timestamp - 60, block.timestamp - 60, roundId + 1)
        );
    }

    function _supplyLiquidity() private {
        _seedUsdc(lender, SUPPLY);
        vm.prank(lender);
        vault.deposit(SUPPLY, lender);
    }

    function _liveMultiplier(address token) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("multiplier()"));
        require(ok && ret.length >= 32, "multiplier() read failed");
        return abi.decode(ret, (uint256));
    }
}

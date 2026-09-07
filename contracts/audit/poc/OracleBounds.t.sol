// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @title  Oracle-manipulation bounds: what the min/max fusion does and does not stop
/// @notice Half of this file is a set of REFUTED attacks - proof that the asymmetric fusion works -
///         and half is the residual edge it leaves open.
contract OracleBoundsTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    function setUp() public {
        _deploy(PRICE_200);
        adapter.setRate(200e6, 1e8);
        usdc.mint(address(adapter), 10_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                          REFUTED: THE FUSION HOLDS
    //////////////////////////////////////////////////////////////*/

    /// @notice REFUTED - `markBorrow` can never be pushed above the Chainlink anchor, at any pool
    ///         price, in any session. `min(anchor, pool) * (1 - haircut) <= anchor` identically, so
    ///         no amount of TWAP manipulation buys the attacker one extra dollar of borrowing power.
    function test_R1_PoolManipulationCannotInflateBorrowPower() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        uint256 anchorMark = uint256(PRICE_200) * 1e10 * 1e16; // WAD price -> Morpho scale

        int24[7] memory ticks = [
            _tickForPriceWad(200.5e18), // +0.25%
            _tickForPriceWad(201e18), // +0.50%
            _tickForPriceWad(201.9e18), // +0.95%, just inside the 200bps band
            _tickForPriceWad(220e18), // +10%
            _tickForPriceWad(400e18), // +100%
            _tickForPriceWad(2000e18), // +900%
            _tickForPriceWad(1e24) // absurd
        ];

        for (uint256 i = 0; i < ticks.length; ++i) {
            pool.setMeanTick(ticks[i], TWAP_WINDOW);
            _currentTick = ticks[i];
            if (oracle.peek().verdict != Verdict.TRUSTED) {
                console2.log("tick rejected outright, verdict:", uint256(oracle.peek().verdict));
                continue;
            }
            uint256 mb = oracle.markBorrow();
            console2.log("poolPrice:", oracle.peek().poolPrice);
            console2.log("  markBorrow:", mb);
            assertLe(mb, anchorMark, "markBorrow never exceeds the anchor");
        }
    }

    /// @notice REFUTED - `markLiquidate` can never be pushed below the anchor either, so a whale
    ///         cannot dump the shallow pool to manufacture a liquidation against a healthy line.
    function test_R2_PoolManipulationCannotDeflateTheSeizureMark() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        uint256 anchorMark = uint256(PRICE_200) * 1e10 * 1e16;

        int24[5] memory ticks = [
            _tickForPriceWad(199.5e18),
            _tickForPriceWad(198.1e18),
            _tickForPriceWad(180e18),
            _tickForPriceWad(100e18),
            _tickForPriceWad(1e18)
        ];

        for (uint256 i = 0; i < ticks.length; ++i) {
            pool.setMeanTick(ticks[i], TWAP_WINDOW);
            _currentTick = ticks[i];
            if (oracle.peek().verdict != Verdict.TRUSTED) continue;
            uint256 ml = oracle.markLiquidate();
            console2.log("poolPrice:", oracle.peek().poolPrice);
            console2.log("  markLiquidate:", ml);
            assertGe(ml, anchorMark, "markLiquidate never falls below the anchor");
        }
    }

    /// @notice REFUTED - a pool with no depth cannot corroborate, and during a regular session the
    ///         oracle simply falls back to the anchor rather than trusting a manipulable print.
    function test_R3_ThinPoolIsIgnoredWhileTheSessionIsOpen() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.mockCall(
            address(usdc), abi.encodeWithSignature("balanceOf(address)", address(pool)), abi.encode(uint256(1e6))
        );
        int24 crazy = _tickForPriceWad(1000e18);
        pool.setMeanTick(crazy, TWAP_WINDOW);

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "still trusted, anchor only");
        assertEq(oracle.markBorrow(), uint256(PRICE_200) * 1e10 * 1e16, "mark is exactly the anchor");
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIRMED: THE RESIDUAL EDGE
    //////////////////////////////////////////////////////////////*/

    /// @notice A-04 - FIXED. Pushing the pool UP to just inside the divergence band used to be a
    ///         one-sided gift to a marginal borrower: it raised `markLiquidate`, and therefore the
    ///         whole seizure threshold, by up to the full band while leaving `markBorrow` pinned to
    ///         the anchor. A line that was flaggable at honest prices stopped being flaggable, and
    ///         the purchase bought no borrowing power at all - so it was pure protection.
    ///
    ///         The pool may now only raise the seizure mark while the anchor is NOT itself printing,
    ///         which is the only case the `max` leg was ever for: a frozen reference that is too
    ///         high, with the pool as the sole live witness. During a regular session the reference
    ///         is live and the seizure mark comes from it.
    function test_A04_PushingThePoolNoLongerBuysProtection() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();

        // Price slips to $161.10: open threshold = 100 * 161.10 * 0.80 = $12,888 < $12,900 debt.
        _setPriceBoth(161_10000000);
        _warpTo(MON_2026_03_02, T_OPEN + 10 minutes);

        (, uint256 honestThreshold) = credit.riskOf(alice);
        console2.log("honest threshold :", honestThreshold);
        console2.log("debt             :", credit.debtOf(alice));
        assertLt(honestThreshold, credit.debtOf(alice), "flaggable at honest prices");

        // The borrower buys the shallow pool up 1.9%, staying inside the 200bps REGULAR band.
        int24 pushed = _tickForPriceWad(164_16 * 1e16); // $164.16 == +1.90%
        pool.setMeanTick(pushed, TWAP_WINDOW);
        _currentTick = pushed;

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "still inside the band, still trusted");
        console2.log("divergenceBps after push :", oracle.peek().divergenceBps);

        (, uint256 pushedThreshold) = credit.riskOf(alice);
        console2.log("pushed threshold :", pushedThreshold);
        assertEq(pushedThreshold, honestThreshold, "the seizure mark no longer follows the pool upward");
        assertLt(pushedThreshold, credit.debtOf(alice), "so the line is still flaggable");

        vm.prank(keeper);
        credit.flag(alice);
        assertTrue(credit.isFlagged(alice), "and the flag lands");

        // The `min` leg is untouched, so the pool can still LOWER borrowing power: that direction is
        // information, and it can only ever be conservative.
        assertEq(oracle.markBorrow(), uint256(161_10000000) * 1e10 * 1e16, "borrow mark pinned to the anchor");
        int24 dumped = _tickForPriceWad(159 * 1e18);
        pool.setMeanTick(dumped, TWAP_WINDOW);
        _currentTick = dumped;
        assertLt(oracle.markBorrow(), uint256(161_10000000) * 1e10 * 1e16, "a pool below the anchor still binds");
    }

    /// @notice A-04, the other half: once the market is shut the pool IS the only live witness, so
    ///         it may still raise the seizure mark. That is the case the `max` leg exists for, and
    ///         removing it would have handed a whale a way to seize on a frozen, too-high anchor.
    function test_A04b_TheMaxLegStillAppliesWhileTheMarketIsShut() public {
        _warpTo(MON_2026_03_02, T_CLOSE - 1 minutes);
        feed.set(feedAnswer, block.timestamp);
        uint256 markWhileOpen = oracle.markLiquidate();

        _warpTo(MON_2026_03_02 + 1, 2 hours); // overnight: the anchor is frozen
        int24 up = _tickForPriceWad(204e18); // +2%, inside the closed band
        pool.setMeanTick(up, TWAP_WINDOW);
        _currentTick = up;

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "inside the band");
        assertGt(oracle.markLiquidate(), markWhileOpen, "a live pool above a frozen anchor still binds");
    }

    /// @notice A-07 - FIXED. `minPoolLiquidityUsd` used to be measured as `loanToken.balanceOf(pool)`
    ///         - the pool's whole USDC balance, not its ACTIVE in-range liquidity. In a
    ///         concentrated-liquidity pool the two are unrelated, so anybody could satisfy the depth
    ///         floor with a single transfer, or for free with an out-of-range single-sided position
    ///         that carries no inventory risk, and thereby promote a pool with no tradeable depth
    ///         into a source the oracle would corroborate against and price off.
    ///
    ///         Depth is now the harmonic mean of the in-range liquidity over the same TWAP window
    ///         whose price is being trusted, converted at the mean tick, capped by the raw balance.
    ///         Liquidity that was never in range during the window never enters the average.
    function test_A07_ABareTransferNoLongerBuysCorroboration() public {
        // Friday's closing print, then Saturday: the pool is the only live witness.
        _warpTo(MON_2026_03_02 + 4, T_CLOSE - 1 minutes);
        feed.set(feedAnswer, block.timestamp);
        _warpTo(MON_2026_03_02 + 5, 12 hours);
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_WEEKEND), "weekend");

        // The pool holds plenty of USDC, but none of it was in range during the window: a
        // single-sided position parked far out of range, or a bare transfer, looks exactly like this.
        pool.setLiquidity(1);
        int24 pushed = _tickForPriceWad(204e18); // +2.0%, inside the closed band
        pool.setMeanTick(pushed, TWAP_WINDOW);
        _currentTick = pushed;

        console2.log("USDC balance held by the pool :", usdc.balanceOf(address(pool)));
        console2.log("depth backing the TWAP        :", oracle.peek().poolLiquidityUsd);
        assertGt(usdc.balanceOf(address(pool)), 25_000e6, "the balance clears the floor on its own");
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_THIN), "the depth behind it does not");
        vm.expectRevert();
        oracle.markLiquidate();

        // Real in-range liquidity is what promotes it, and nothing else.
        pool.setLiquidity(1 << 100);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "real depth corroborates");

        // And the balance is still an independent ceiling: virtual reserves exceed real ones in a
        // concentrated pool, and no swap can take out more of the loan token than the pool holds.
        vm.mockCall(
            address(usdc), abi.encodeWithSignature("balanceOf(address)", address(pool)), abi.encode(uint256(1_000e6))
        );
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_THIN), "an empty pool is still thin");
    }

    /// @notice A-05 - FIXED. `sweepYield` derives `minOut` from `markBorrow`, which is already the
    ///         pessimistic mark: the lower of the two venues AND discounted again by the gap
    ///         haircut. The swap then executes against that same pool, so the floor it enforced was
    ///         `anchor x (1 - divergence) x (1 - haircut) x (1 - budget)` - up to ~24% over a long
    ///         holiday weekend, against a configured budget of 1%.
    ///
    ///         The sweep now only runs while the US market is open, where the haircut is zero by
    ///         construction and the pool is at its deepest. That is also simply the right time to
    ///         send a market order in an equity.
    function test_A05_TheSweepWillNotRunWhereTheFloorIsWide() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();

        nvda.setMultiplier(1.02e18); // a 2% distribution
        assertEq(credit.maxSlippageBps(), 100, "configured budget is 1%");

        // Overnight: Tuesday 02:00 ET. CLOSED_OVERNIGHT, ~10h closed, so the gap haircut is live and
        // the divergence band is at its widest. This is the window the sandwich lived in.
        _warpTo(MON_2026_03_02 + 1, 2 hours);
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_OVERNIGHT), "overnight");

        int24 pushed = _tickForPriceWad(184_20 * 1e16); // $184.20 == -7.9%, inside the closed band
        pool.setMeanTick(pushed, TWAP_WINDOW);
        _currentTick = pushed;
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "inside the band");
        console2.log("haircutBps      :", oracle.peek().haircutBps);
        console2.log("divergenceBps   :", oracle.peek().divergenceBps);
        assertGt(oracle.peek().haircutBps, 0, "the floor is discounted by a live gap haircut");

        adapter.setHaircutBps(1_000);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_OVERNIGHT)
        );
        credit.sweepYield(alice, address(nvda));

        // At the opening bell the haircut is gone, and a venue trying the same 10% fill is refused
        // by the slippage guard rather than sailing through it.
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 30 minutes);
        pool.setMeanTick(_tickForPriceWad(200e18), TWAP_WINDOW);
        assertEq(oracle.peek().haircutBps, 0, "no gap haircut while the market is open");

        // The venue refuses the fill first...
        vm.prank(keeper);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));

        // ...and if it lies about honouring `minOut`, the engine refuses it too.
        adapter.setEnforceMinOut(false);
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.SlippageExceeded.selector);
        credit.sweepYield(alice, address(nvda));
        adapter.setEnforceMinOut(true);

        // Inside the configured budget it goes through, and the realised loss is inside it too.
        adapter.setHaircutBps(50);
        vm.prank(keeper);
        (uint256 sold, uint256 proceeds,) = credit.sweepYield(alice, address(nvda));
        uint256 fair = sold * 200e6 / 1e8;
        console2.log("sold        :", sold);
        console2.log("proceeds    :", proceeds);
        console2.log("loss bps    :", (fair - proceeds) * 10_000 / fair);
        assertLe((fair - proceeds) * 10_000 / fair, credit.maxSlippageBps(), "inside the configured budget");
    }
}

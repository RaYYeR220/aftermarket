// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AftermarketCredit} from "./AftermarketCredit.sol";
import {AftermarketVault} from "./AftermarketVault.sol";
import {AutoRepayer} from "./AutoRepayer.sol";
import {ISessionRateModel} from "./SessionRateModel.sol";
import {IAftermarketCredit} from "./interfaces/IAftermarketCredit.sol";
import {IAftermarketLens} from "./interfaces/IAftermarketLens.sol";
import {IAftermarketOracle} from "./interfaces/IAftermarketOracle.sol";
import {IEligibility} from "./interfaces/IEligibility.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {Quote, Session} from "./libraries/Types.sol";

/// @title  AftermarketLens
/// @notice One call per screen: the aggregate read layer behind Aftermarket's interface.
///
/// @dev ## Why this contract may never revert
///
///      Aftermarket is a protocol whose central claim is that an untrustworthy price is a normal
///      state to be shown honestly rather than an exception to be crashed on. The risk engine
///      expresses that by making `markBorrow` and `markLiquidate` revert, which correctly freezes
///      new borrowing and freezes seizure. But a front end cannot render "the oracle is refusing to
///      quote, here is why, and here is what you can still do" if the call that would tell it so is
///      the call that reverted.
///
///      So the lens inverts the convention: every external read is wrapped, and trust is carried in
///      the returned data (`quoteOk`, `priced`, a `PreviewReason`) instead of in control flow. A
///      caller that wants strictness keeps using the engine's own strict views; a caller that has to
///      draw a screen uses this one and always gets a complete struct.
///
///      Two consequences are worth stating plainly. Values that could not be read come back as zero,
///      which is why every such field is paired with a flag saying whether it means anything. And
///      when the calendar itself is unreachable, the lens reports the *closed*-session risk
///      parameters: a stale screen showing the lower advance rate and the more forgiving seizure
///      threshold understates what a user can borrow rather than overstating it.
///
///      ## No owner, no writable state
///
///      The only storage is the asset list, written once by the constructor and never again.
///      Solidity has no immutable arrays, so a set-once array is the closest available expression of
///      "this contract is configuration, not state". Everything else - the vault, the calendar, the
///      Reg-S gate, the rate model, the per-asset risk policy - is read live from the credit engine
///      on every call, so the lens cannot drift out of date with the protocol it describes.
contract AftermarketLens is IAftermarketLens {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice Scale of an `IAftermarketOracle` mark: `collateralRaw * mark / 1e36 == loanRaw`.
    uint256 internal constant ORACLE_SCALE = 1e36;

    /// @notice Seconds used to annualise the per-second rates the model produces.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Longest ERC-20 symbol the lens will relay, in bytes.
    /// @dev A bound rather than a judgement: it stops a hostile token from making every call that
    ///      lists assets arbitrarily expensive for the node serving it.
    uint256 internal constant MAX_SYMBOL_BYTES = 64;

    /// @notice Number of 32-byte words `AftermarketCredit.assetConfig` returns.
    uint256 internal constant ASSET_CONFIG_WORDS = 9;

    /// @notice The credit engine every other address is derived from.
    AftermarketCredit public immutable credit;

    /// @notice The supply-side vault.
    AftermarketVault public immutable vault;

    /// @notice The trading calendar.
    ITradingCalendar public immutable calendar;

    /// @notice The autonomous repayment agent, consulted for the enrolment flag.
    AutoRepayer public immutable autoRepayer;

    /// @dev Written once, in the constructor. See the contract documentation.
    address[] internal _assets;

    error ZeroAddress();
    error NoAssets();

    /// @dev A single read of the market-wide state, passed down so that a call which renders every
    ///      asset does not re-read the calendar, the vault and the rate model once per asset.
    struct MarketState {
        Session session;
        bool open;
        uint64 nextOpen;
        uint64 lastClose;
        uint256 totalDebt;
        uint256 totalSupplied;
        uint256 utilisation;
        uint256 borrowApr;
        uint256 supplyApr;
    }

    /// @param credit_      The Aftermarket credit engine.
    /// @param autoRepayer_ The autonomous repayment agent.
    /// @param assets_      Collateral assets this lens reports on. Ordering is the display ordering.
    constructor(AftermarketCredit credit_, AutoRepayer autoRepayer_, address[] memory assets_) {
        if (address(credit_) == address(0) || address(autoRepayer_) == address(0)) revert ZeroAddress();
        if (assets_.length == 0) revert NoAssets();

        credit = credit_;
        vault = AftermarketVault(credit_.vault());
        calendar = credit_.calendar();
        autoRepayer = autoRepayer_;

        for (uint256 i; i < assets_.length; ++i) {
            if (assets_[i] == address(0)) revert ZeroAddress();
            _assets.push(assets_[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  ASSETS
    //////////////////////////////////////////////////////////////*/

    /// @notice Collateral assets this lens reports on.
    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @inheritdoc IAftermarketLens
    function assetView(address asset) external view returns (AssetView memory) {
        return _assetView(asset, _market());
    }

    /// @inheritdoc IAftermarketLens
    function assetViews() external view returns (AssetView[] memory views) {
        MarketState memory m = _market();
        address[] memory list = _assets;

        views = new AssetView[](list.length);
        for (uint256 i; i < list.length; ++i) {
            views[i] = _assetView(list[i], m);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                   USER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketLens
    /// @dev An address that has never touched the protocol is not a special case here: it has an
    ///      empty basket, no debt, and a health factor of `type(uint256).max`, which is exactly what
    ///      the engine reports for it too.
    function userView(address user) external view returns (UserView memory v) {
        v.user = user;

        address[] memory list = credit.assetsOf(user);
        v.collateral = list;
        v.amounts = new uint256[](list.length);
        for (uint256 i; i < list.length; ++i) {
            v.amounts[i] = credit.collateral(user, list[i]);
        }

        IAftermarketCredit.Position memory p;
        bool positionOk;
        try credit.positionOf(user) returns (IAftermarketCredit.Position memory got) {
            p = got;
            positionOk = true;
        } catch {}

        if (positionOk) {
            v.debt = p.debtAssets;
            v.priced = p.priced;
            v.borrowPower = p.borrowPower;
            v.seizureThreshold = p.seizureThreshold;
            v.healthBps = _healthBps(p);
            v.graceUntil = p.graceUntil;
            v.flaggedAt = p.flaggedAt;
        }

        (v.eligible, v.country) = _eligibility(user);

        try autoRepayer.isEnrolled(user) returns (bool enrolled) {
            v.autoRepayEnrolled = enrolled;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                                 PROTOCOL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketLens
    function protocolView() external view returns (ProtocolView memory v) {
        MarketState memory m = _market();

        v.session = m.session;
        v.nextOpen = m.nextOpen;
        v.lastClose = m.lastClose;
        v.totalDebt = m.totalDebt;
        v.totalSupplied = m.totalSupplied;
        v.utilisation = m.utilisation;
        v.assets = _assets;

        // One whole share, not one wei of a share: the vault carries a six-decimal offset over USDC,
        // so a wei-denominated price would round to zero and tell a supplier nothing.
        try vault.decimals() returns (uint8 shareDecimals) {
            try vault.convertToAssets(10 ** uint256(shareDecimals)) returns (uint256 price) {
                v.vaultSharePrice = price;
            } catch {}
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                                 PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketLens
    /// @dev Mirrors every check `AftermarketCredit.draw` makes, in the same order, plus the vault's
    ///      idle-liquidity bound. The engine remains the authority; this exists so a user learns
    ///      which condition stops them without paying for a reverted transaction to find out.
    function previewDraw(address user, uint256 amount) external view returns (DrawPreview memory p) {
        IAftermarketCredit.Position memory position;
        bool positionOk;
        try credit.positionOf(user) returns (IAftermarketCredit.Position memory got) {
            position = got;
            positionOk = true;
        } catch {}

        p.debtAfter = position.debtAssets + amount;
        p.borrowPower = position.borrowPower;
        p.healthBps = _projectedHealthBps(position, position.seizureThreshold, p.debtAfter);

        if (amount == 0) return _draw(p, PreviewReason.ZERO_AMOUNT);

        (bool eligible,) = _eligibility(user);
        if (!eligible) return _draw(p, PreviewReason.NOT_ELIGIBLE);

        // When the position could not be read at all, nothing further about the line can be
        // asserted, so the pricing failure is reported ahead of the checks that depend on it.
        if (!positionOk) return _draw(p, PreviewReason.UNPRICED);
        if (position.openedAt == 0) return _draw(p, PreviewReason.LINE_NOT_OPEN);
        if (position.flagged) return _draw(p, PreviewReason.LINE_FLAGGED);
        if (!position.priced) return _draw(p, PreviewReason.UNPRICED);
        if (p.debtAfter > position.borrowPower) return _draw(p, PreviewReason.UNDERCOLLATERALIZED);

        uint256 idle;
        try vault.idleAssets() returns (uint256 got) {
            idle = got;
        } catch {}
        if (amount > idle) return _draw(p, PreviewReason.INSUFFICIENT_LIQUIDITY);

        return _draw(p, PreviewReason.OK);
    }

    /// @inheritdoc IAftermarketLens
    /// @dev Mirrors `AftermarketCredit.withdrawCollateral`, including its most important asymmetry:
    ///      a line with no debt may always take its collateral back, so neither an oracle outage nor
    ///      a change of compliance provider can trap it. That is why the debt-free branch returns
    ///      `OK` before the pricing check is ever reached.
    function previewWithdraw(address user, address asset, uint256 amount)
        external
        view
        returns (WithdrawPreview memory p)
    {
        IAftermarketCredit.Position memory position;
        bool positionOk;
        try credit.positionOf(user) returns (IAftermarketCredit.Position memory got) {
            position = got;
            positionOk = true;
        } catch {}

        p.borrowPowerAfter = position.borrowPower;
        p.seizureThresholdAfter = position.seizureThreshold;
        p.healthBps = _healthBps(position);

        if (amount == 0) return _withdraw(p, PreviewReason.ZERO_AMOUNT);

        uint256 balance = credit.collateral(user, asset);
        if (amount > balance) return _withdraw(p, PreviewReason.INSUFFICIENT_COLLATERAL);

        // The debt-free shortcut below is only sound when the position was actually read. A failed
        // read leaves every field zero, which would otherwise look exactly like "owes nothing" and
        // wave through a withdrawal the engine is about to refuse.
        if (!positionOk) return _withdraw(p, PreviewReason.UNPRICED);

        if (position.debtAssets == 0) {
            p.healthBps = type(uint256).max;
            return _withdraw(p, PreviewReason.OK);
        }
        if (!position.priced) return _withdraw(p, PreviewReason.UNPRICED);

        // Each asset contributes to the two totals independently, so removing one asset's slice is
        // exact rather than an approximation: recompute that asset's term at both balances and swap
        // it in. The rounding therefore matches the engine's own loop wei for wei.
        MarketState memory m = _market();
        IAftermarketCredit.AssetConfig memory c = _config(asset);
        (uint256 powerNow, uint256 thresholdNow, bool ok) = _contribution(c, balance, m.open);
        if (!ok) return _withdraw(p, PreviewReason.UNPRICED);
        (uint256 powerAfter, uint256 thresholdAfter,) = _contribution(c, balance - amount, m.open);

        p.borrowPowerAfter = position.borrowPower - powerNow + powerAfter;
        p.seizureThresholdAfter = position.seizureThreshold - thresholdNow + thresholdAfter;
        p.healthBps = _projectedHealthBps(position, p.seizureThresholdAfter, position.debtAssets);

        if (position.debtAssets > p.borrowPowerAfter) return _withdraw(p, PreviewReason.UNDERCOLLATERALIZED);

        return _withdraw(p, PreviewReason.OK);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: COMPOSITION
    //////////////////////////////////////////////////////////////*/

    function _assetView(address asset, MarketState memory m) internal view returns (AssetView memory v) {
        v.asset = asset;
        v.symbol = _symbolOf(asset);
        v.decimals = _decimalsOf(asset);
        v.borrowApr = m.borrowApr;
        v.supplyApr = m.supplyApr;

        IAftermarketCredit.AssetConfig memory c = _config(asset);
        v.oracle = address(c.oracle);
        v.cap = c.cap;
        v.posted = c.posted;
        v.enabled = c.enabled;
        v.advanceBps = m.open ? c.advanceOpenBps : c.advanceClosedBps;
        v.liqThresholdBps = m.open ? c.liqThresholdOpenBps : c.liqThresholdClosedBps;

        // An unconfigured asset has no oracle, which is the honest answer rather than an error: the
        // UI can list a token the protocol does not accept and say exactly that.
        if (v.oracle.code.length == 0) return v;
        try IAftermarketOracle(v.oracle).peek() returns (Quote memory q) {
            v.quote = q;
            v.quoteOk = true;
        } catch {}
    }

    /// @dev Everything the whole protocol shares, read once per external call.
    function _market() internal view returns (MarketState memory m) {
        // A calendar that cannot answer is treated as a closed market. Closed is the conservative
        // reading: it reports the lower advance rate and the more forgiving seizure threshold, so a
        // screen rendered during a calendar outage understates borrowing power instead of inviting
        // a draw the engine would then refuse.
        m.session = Session.CLOSED_HOLIDAY;
        try calendar.sessionAt(block.timestamp) returns (Session session, uint64 nextOpen, uint64 lastClose) {
            m.session = session;
            m.nextOpen = nextOpen;
            m.lastClose = lastClose;
        } catch {}
        m.open = m.session == Session.REGULAR;

        try credit.totalDebtAssets() returns (uint256 debt) {
            m.totalDebt = debt;
        } catch {}
        try vault.totalAssets() returns (uint256 supplied) {
            m.totalSupplied = supplied;
        } catch {}

        // Computed here rather than delegated to the rate model: it is the same clamped ratio, and
        // the lens must produce it even when the configured model is unreachable.
        m.utilisation = m.totalSupplied == 0 ? 0 : Math.min(WAD, Math.mulDiv(m.totalDebt, WAD, m.totalSupplied));

        address rateModel = address(credit.rateModel());
        if (rateModel.code.length == 0) return m;
        try ISessionRateModel(rateModel).ratePerSecondAt(m.totalDebt, m.totalSupplied, m.session) returns (
            uint256 ratePerSecond
        ) {
            m.borrowApr = ratePerSecond * SECONDS_PER_YEAR;
            // Aftermarket takes no reserve factor, so every unit of borrower interest reaches
            // suppliers and the supply rate is simply the borrow rate scaled by utilisation.
            m.supplyApr = Math.mulDiv(m.borrowApr, m.utilisation, WAD);
        } catch {}
    }

    /// @dev The engine's per-asset terms in `_borrowPower` and `_seizureThreshold`, reproduced for a
    ///      hypothetical balance. `ok` is false when the oracle refuses either mark.
    function _contribution(IAftermarketCredit.AssetConfig memory c, uint256 amount, bool open)
        internal
        view
        returns (uint256 power, uint256 threshold, bool ok)
    {
        if (amount == 0) return (0, 0, true);
        if (address(c.oracle).code.length == 0) return (0, 0, false);

        uint256 markBorrow;
        try c.oracle.markBorrow() returns (uint256 mark) {
            markBorrow = mark;
        } catch {
            return (0, 0, false);
        }

        uint256 markLiquidate;
        try c.oracle.markLiquidate() returns (uint256 mark) {
            markLiquidate = mark;
        } catch {
            return (0, 0, false);
        }

        power = Math.mulDiv(
            Math.mulDiv(amount, markBorrow, ORACLE_SCALE), open ? c.advanceOpenBps : c.advanceClosedBps, BPS
        );
        threshold = Math.mulDiv(
            Math.mulDiv(amount, markLiquidate, ORACLE_SCALE),
            open ? c.liqThresholdOpenBps : c.liqThresholdClosedBps,
            BPS
        );
        ok = true;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: READS
    //////////////////////////////////////////////////////////////*/

    /// @dev The engine's `assetConfig` getter returns the nine members of a fully static struct as
    ///      nine separate values, which is more than the stack can hold alongside a destructuring
    ///      assignment. Because every member is a value type, the getter's return data is
    ///      byte-identical to the ABI encoding of the struct itself, so decoding it in one step is
    ///      both correct and cheaper than nine stack slots. An unconfigured asset simply decodes to
    ///      a zeroed struct.
    function _config(address asset) internal view returns (IAftermarketCredit.AssetConfig memory c) {
        (bool ok, bytes memory ret) =
            address(credit).staticcall(abi.encodeWithSelector(credit.assetConfig.selector, asset));
        if (!ok || ret.length != ASSET_CONFIG_WORDS * 32) return c;

        return abi.decode(ret, (IAftermarketCredit.AssetConfig));
    }

    /// @dev The Reg-S verdict. `IEligibility.check` is documented as total, but the gate is an
    ///      owner-settable address, so the lens does not take that on faith.
    function _eligibility(address user) internal view returns (bool eligible, bytes2 country) {
        address gate = address(credit.eligibility());
        if (gate.code.length == 0) return (false, bytes2(0));

        try IEligibility(gate).check(user) returns (bool ok, bytes2 proven, uint8) {
            return (ok, proven);
        } catch {
            return (false, bytes2(0));
        }
    }

    function _healthBps(IAftermarketCredit.Position memory p) internal pure returns (uint256) {
        if (p.debtAssets == 0) return type(uint256).max;
        if (!p.priced) return 0;
        return Math.mulDiv(p.seizureThreshold, BPS, p.debtAssets);
    }

    function _projectedHealthBps(IAftermarketCredit.Position memory p, uint256 threshold, uint256 debt)
        internal
        pure
        returns (uint256)
    {
        if (debt == 0) return type(uint256).max;
        if (!p.priced) return 0;
        return Math.mulDiv(threshold, BPS, debt);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-20 metadata is optional and inconsistently implemented, and the lens is asked about
    ///      arbitrary addresses including ones with no code at all. A raw `staticcall` with an
    ///      explicit length check is the only read that cannot revert on any of those.
    function _symbolOf(address token) internal view returns (string memory) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (!ok || ret.length < 64) return "";

        // The ABI head is validated by hand before `abi.decode` sees it. The decoder reverts on a
        // malformed offset or an out-of-bounds length, and a lens that can be made to revert by
        // being asked about a hostile token is not a lens.
        uint256 head;
        uint256 length;
        assembly ("memory-safe") {
            head := mload(add(ret, 0x20))
            length := mload(add(ret, 0x40))
        }
        if (head != 0x20 || length > MAX_SYMBOL_BYTES || ret.length < 0x40 + length) return "";

        return abi.decode(ret, (string));
    }

    function _decimalsOf(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length != 32) return 0;

        uint256 value = abi.decode(ret, (uint256));
        // casting to 'uint8' is safe because the branch is only taken when the value already fits
        // forge-lint: disable-next-line(unsafe-typecast)
        return value > type(uint8).max ? 0 : uint8(value);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: RESULTS
    //////////////////////////////////////////////////////////////*/

    function _draw(DrawPreview memory p, PreviewReason reason) internal pure returns (DrawPreview memory) {
        p.ok = reason == PreviewReason.OK;
        p.reason = uint8(reason);
        return p;
    }

    function _withdraw(WithdrawPreview memory p, PreviewReason reason) internal pure returns (WithdrawPreview memory) {
        p.ok = reason == PreviewReason.OK;
        p.reason = uint8(reason);
        return p;
    }
}

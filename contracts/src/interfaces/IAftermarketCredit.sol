// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAftermarketOracle} from "./IAftermarketOracle.sol";
import {Session} from "../libraries/Types.sol";

/// @notice The external surface of the Aftermarket credit engine.
/// @dev Kept in its own file so that `AftermarketVault` can depend on the engine's debt accounting
///      without a circular source import, and so that keepers and the UI have one ABI to compile
///      against that carries the full error and event vocabulary.
interface IAftermarketCredit {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Risk policy for one collateral asset, plus its live posted balance.
    /// @dev The open/closed split is the heart of the protocol. While the US market is open, prices
    ///      are discoverable and a borrower can react, so we advance more and seize sooner. While it
    ///      is closed we advance less (gap risk is real) but we also seize later (the borrower
    ///      cannot trade out of trouble and there is no price anybody would defend).
    struct AssetConfig {
        IAftermarketOracle oracle;
        uint16 advanceOpenBps;
        uint16 advanceClosedBps;
        uint16 liqThresholdOpenBps;
        uint16 liqThresholdClosedBps;
        uint16 liqBonusBps;
        uint128 cap;
        uint128 posted;
        bool enabled;
    }

    /// @notice The owner-settable half of `AssetConfig`; `posted` is protocol accounting and is
    ///         never writable from outside.
    struct AssetParams {
        IAftermarketOracle oracle;
        uint16 advanceOpenBps;
        uint16 advanceClosedBps;
        uint16 liqThresholdOpenBps;
        uint16 liqThresholdClosedBps;
        uint16 liqBonusBps;
        uint128 cap;
        bool enabled;
    }

    /// @notice Everything a front end or keeper needs about one line, in a single non-reverting read.
    /// @dev The basket itself is read separately through `assetsOf` and the public `collateral`
    ///      mapping: keeping two dynamic arrays out of this struct is what lets the engine expose a
    ///      full position view and still fit inside the EIP-170 contract size limit.
    struct Position {
        uint256 debtAssets;
        uint256 debtShares;
        uint256 borrowPower;
        uint256 seizureThreshold;
        uint256 healthFactor;
        bool priced;
        bool flagged;
        uint64 openedAt;
        uint64 flaggedAt;
        uint64 graceUntil;
        bool autoRepayEnabled;
        Session session;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AssetConfigured(address indexed asset, AssetParams params);
    event AssetEnabledSet(address indexed asset, bool enabled);
    event AssetCapSet(address indexed asset, uint128 cap);
    event EligibilitySet(address indexed eligibility);
    event RateModelSet(address indexed rateModel);
    event SwapAdapterSet(address indexed swapAdapter);
    event MaxSlippageSet(uint16 maxSlippageBps);

    event LineOpened(address indexed user, uint64 openedAt);
    event AutoRepaySet(address indexed user, bool enabled);
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount, uint256 balance);
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount, address to);
    event Drawn(address indexed user, address indexed to, uint256 assets, uint256 shares);
    event Repaid(address indexed user, address indexed payer, uint256 assets, uint256 shares);
    event Accrued(uint256 interest, uint256 totalDebtAssets, uint256 ratePerSecond, Session session);

    event LineFlagged(
        address indexed user,
        address indexed keeper,
        uint256 debtAssets,
        uint256 seizureThreshold,
        uint64 graceUntil,
        uint64 nextOpen,
        Session session
    );
    event LineCured(address indexed user, address indexed caller, uint256 debtAssets, uint256 seizureThreshold);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        address indexed collateralAsset,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seized
    );
    event BadDebtRealized(address indexed user, uint256 assets, uint256 shares);
    event YieldSwept(
        address indexed user,
        address indexed asset,
        uint256 fromMultiplier,
        uint256 toMultiplier,
        uint256 sold,
        uint256 proceeds,
        uint256 repaid,
        uint256 surplus
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error Overflow();
    error ZeroAmount();
    error InvalidAssetConfig();
    error InvalidSlippage(uint16 maxSlippageBps);
    error AssetNotEnabled(address asset);
    error AssetCapExceeded(address asset, uint256 posted, uint256 cap);
    error TooManyAssets(uint256 max);
    error LineNotOpen(address user);
    error LineAlreadyOpen(address user);
    error LineIsFlagged(address user);
    error InsufficientCollateral(address asset, uint256 balance, uint256 requested);
    error Undercollateralized(uint256 debtAssets, uint256 borrowPower);
    error NoDebt(address user);
    error NotFlagged(address user);
    error AlreadyFlagged(address user, uint64 graceUntil);
    error GraceNotExpired(uint64 graceUntil);
    error MarketClosed(Session session);
    error LineHealthy(uint256 debtAssets, uint256 seizureThreshold);
    error CloseFactorExceeded(uint256 requested, uint256 maxRepay);
    error NothingToSweep(address user, address asset);
    error AutoRepayDisabled(address user);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    /// @notice A flagged line was not returned to its own advance rate, so the flag stands.
    error CureIncomplete(uint256 debtAssets, uint256 borrowPower);
    /// @notice A public risk view was asked about a basket the engine cannot fully price.
    error UnpricedCollateral(uint256 assets);
    /// @notice `sweepYield` was asked to sell a slice only a stock split could produce.
    error SweepTooLarge(uint256 sold, uint256 cap);
    /// @notice An oracle was installed for an asset or a loan token it does not price.
    error OracleAssetMismatch(address expected, address actual);
    /// @notice The trading calendar cannot answer beyond the horizon its holiday table covers.
    error CalendarHorizon();
    /// @notice `realizeBadDebt` was called on a line that still has collateral worth seizing.
    error LineNotDust(uint256 seizureThreshold, uint256 debtAssets);

    /*//////////////////////////////////////////////////////////////
                            VAULT-FACING VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total USDC owed to the vault by all borrowers, projected to `block.timestamp`.
    function totalDebtAssets() external view returns (uint256);

    /// @notice The ERC-4626 vault that funds this engine.
    function vault() external view returns (address);

    /// @notice Brings the market's debt total up to `block.timestamp`. Permissionless.
    /// @dev Declared here because the vault must close the accrual window *before* it changes the
    ///      market's liquidity; sampling a rate after a deposit lands and applying it backwards
    ///      would reprice history at a utilisation that never prevailed.
    function accrue() external;
}

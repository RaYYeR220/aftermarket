// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Quote, Session} from "../libraries/Types.sol";

/// @notice The read-only aggregate view of Aftermarket, shaped for a front end.
///
/// @dev Every function on the lens is total: it returns a fully populated struct for any input,
///      under any failure of any oracle, calendar or rate model. That is not a convenience, it is
///      the product requirement. Aftermarket's whole thesis is that a price feed being untrustworthy
///      is a normal, expected state that the interface must render honestly - so the one contract
///      whose job is to feed that interface must never be the thing that goes dark when it happens.
///      Trust is reported through explicit flags (`quoteOk`, `priced`) rather than through whether
///      the call succeeded.
interface IAftermarketLens {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice One collateral asset: its identity, its live oracle state and its risk policy.
    struct AssetView {
        /// @dev The collateral token.
        address asset;
        /// @dev ERC-20 symbol, or the empty string when the token does not expose one.
        string symbol;
        /// @dev ERC-20 decimals, or zero when the token does not expose them.
        uint8 decimals;
        /// @dev The oracle configured on the credit engine, or the zero address when unconfigured.
        address oracle;
        /// @dev The oracle's full non-reverting state. Zeroed when `quoteOk` is false.
        Quote quote;
        /// @dev Whether the oracle answered at all.
        bool quoteOk;
        /// @dev Advance rate in force for the current session, bps.
        uint16 advanceBps;
        /// @dev Seizure threshold in force for the current session, bps.
        uint16 liqThresholdBps;
        /// @dev Ceiling on total posted collateral of this asset, raw units.
        uint128 cap;
        /// @dev Collateral of this asset currently posted across every line, raw units.
        uint128 posted;
        /// @dev Whether the engine currently accepts this asset.
        bool enabled;
        /// @dev Borrow rate, WAD per year, at the current utilisation and session.
        uint256 borrowApr;
        /// @dev Supply rate, WAD per year, at the current utilisation and session.
        uint256 supplyApr;
    }

    /// @notice One credit line, everything a borrower's dashboard renders.
    struct UserView {
        /// @dev The account.
        address user;
        /// @dev Collateral assets currently posted.
        address[] collateral;
        /// @dev Raw units posted, index-aligned with `collateral`.
        uint256[] amounts;
        /// @dev USDC owed, projected to `block.timestamp`.
        uint256 debt;
        /// @dev Total debt the basket supports. Zero when `priced` is false.
        uint256 borrowPower;
        /// @dev Debt level at which the line becomes seizable. Zero when `priced` is false.
        uint256 seizureThreshold;
        /// @dev Health in bps of the seizure threshold; 10_000 sits exactly on it. Zero when
        ///      `priced` is false, `type(uint256).max` when there is no debt.
        uint256 healthBps;
        /// @dev Whether every oracle in the basket produced a mark.
        bool priced;
        /// @dev Grace deadline of a flagged line, zero when not flagged.
        uint64 graceUntil;
        /// @dev When the line was flagged, zero when not flagged.
        uint64 flaggedAt;
        /// @dev Whether the Reg-S gate currently admits this account.
        bool eligible;
        /// @dev ISO 3166-1 alpha-2 code proven for the account, empty when unproven.
        bytes2 country;
        /// @dev Whether the account has a live, enabled `AutoRepayer` mandate.
        bool autoRepayEnrolled;
    }

    /// @notice The protocol as a whole.
    struct ProtocolView {
        /// @dev Where the US equity market is right now, per the onchain calendar.
        Session session;
        /// @dev Unix seconds of the next regular open.
        uint64 nextOpen;
        /// @dev Unix seconds of the previous regular close.
        uint64 lastClose;
        /// @dev USDC owed by every borrower, projected to `block.timestamp`.
        uint256 totalDebt;
        /// @dev Vault `totalAssets`: idle USDC plus everything out on loan.
        uint256 totalSupplied;
        /// @dev `totalDebt / totalSupplied`, WAD, clamped to 1e18.
        uint256 utilisation;
        /// @dev USDC per one whole vault share, in USDC units.
        uint256 vaultSharePrice;
        /// @dev Every collateral asset this lens was deployed to cover.
        address[] assets;
    }

    /// @notice Why a previewed action would fail, or `OK` when it would succeed.
    /// @dev The numbering is part of the ABI; append, never reorder.
    enum PreviewReason {
        /// @dev 0: the action would succeed.
        OK,
        /// @dev 1: the engine rejects a zero amount.
        ZERO_AMOUNT,
        /// @dev 2: the Reg-S gate does not admit this account.
        NOT_ELIGIBLE,
        /// @dev 3: the account has never called `openLine`.
        LINE_NOT_OPEN,
        /// @dev 4: the line is flagged and must be cured before it can draw again.
        LINE_FLAGGED,
        /// @dev 5: an oracle in the basket refuses to produce a mark.
        UNPRICED,
        /// @dev 6: the action would leave the debt above the basket's borrowing power.
        UNDERCOLLATERALIZED,
        /// @dev 7: the account has posted less of this asset than it is trying to withdraw.
        INSUFFICIENT_COLLATERAL,
        /// @dev 8: the vault does not hold enough idle USDC to fund the draw.
        INSUFFICIENT_LIQUIDITY
    }

    /// @notice The outcome of a hypothetical `draw`.
    struct DrawPreview {
        bool ok;
        /// @dev A `PreviewReason`.
        uint8 reason;
        /// @dev Debt the line would carry afterwards.
        uint256 debtAfter;
        /// @dev Borrowing power the basket supports right now.
        uint256 borrowPower;
        /// @dev Health the line would have afterwards, bps of the seizure threshold.
        uint256 healthBps;
    }

    /// @notice The outcome of a hypothetical `withdrawCollateral`.
    struct WithdrawPreview {
        bool ok;
        /// @dev A `PreviewReason`.
        uint8 reason;
        /// @dev Borrowing power the basket would support afterwards.
        uint256 borrowPowerAfter;
        /// @dev Seizure threshold the basket would carry afterwards.
        uint256 seizureThresholdAfter;
        /// @dev Health the line would have afterwards, bps of the seizure threshold.
        uint256 healthBps;
    }

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything about one collateral asset. Never reverts.
    function assetView(address asset) external view returns (AssetView memory);

    /// @notice Every configured collateral asset in one call. Never reverts.
    function assetViews() external view returns (AssetView[] memory);

    /// @notice Everything about one credit line. Never reverts.
    function userView(address user) external view returns (UserView memory);

    /// @notice Everything about the protocol. Never reverts.
    function protocolView() external view returns (ProtocolView memory);

    /// @notice What drawing `amount` USDC would do to `user`'s line. Never reverts.
    function previewDraw(address user, uint256 amount) external view returns (DrawPreview memory);

    /// @notice What withdrawing `amount` of `asset` would do to `user`'s line. Never reverts.
    function previewWithdraw(address user, address asset, uint256 amount) external view returns (WithdrawPreview memory);
}

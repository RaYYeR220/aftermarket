// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {Session} from "./libraries/Types.sol";

/// @notice The interest-rate surface consumed by `AftermarketCredit`.
/// @dev Split out so the owner can replace the curve without touching the credit engine, and so the
///      engine can price interest at a session it has *already* read, rather than paying for a
///      second calendar call that could in principle disagree with the first.
interface ISessionRateModel {
    /// @notice Borrow rate per second, WAD, at the calendar current session.
    function ratePerSecond(uint256 totalDebtAssets, uint256 totalAssets) external view returns (uint256);

    /// @notice Borrow rate per second, WAD, at an explicitly supplied session.
    function ratePerSecondAt(uint256 totalDebtAssets, uint256 totalAssets, Session session)
        external
        view
        returns (uint256);

    /// @notice Utilisation, WAD, clamped to 1e18.
    function utilization(uint256 totalDebtAssets, uint256 totalAssets) external pure returns (uint256);

    /// @notice The immutable premium applied to the kinked curve in `session`, WAD.
    function sessionMultiplier(Session session) external view returns (uint256);

    /// @notice The calendar this model prices against.
    function calendar() external view returns (ITradingCalendar);
}

/// @title  SessionRateModel
/// @notice A kinked utilisation curve with a closed-market risk premium.
///
/// @dev Two ideas are stacked here.
///
///      The first is the standard kinked curve: cheap credit while the pool is underused, steeply
///      more expensive past the kink so that suppliers can always exit.
///
///      The second is specific to tokenized equities. When the US market is shut, every open loan
///      carries gap risk that nobody can hedge away: the next real print may be several percent
///      from the last one, and neither the borrower nor a liquidator can do anything about it until
///      the opening bell. Aftermarket deliberately refuses to seize collateral in that window,
///      which means suppliers are the ones carrying the gap. Charging a session premium is how that
///      risk gets paid for instead of socialised. A weekend costs more than an overnight because it
///      is longer; a holiday costs the most because it is longer still and usually sits next to a
///      weekend.
///
///      The contract is pure policy: no storage writes, no owner, no upgrade path. Every parameter
///      is immutable, so a change of policy is a visible redeployment plus a `setRateModel` call on
///      the credit engine rather than a silent write.
contract SessionRateModel is ISessionRateModel {
    uint256 internal constant WAD = 1e18;

    /// @notice Number of entries in the session premium table; mirrors `Session`.
    uint256 public constant SESSION_COUNT = 6;

    /// @inheritdoc ISessionRateModel
    ITradingCalendar public immutable calendar;

    /// @notice Rate floor charged at zero utilisation, per second, WAD.
    uint256 public immutable baseRatePerSecond;
    /// @notice Rate added linearly between zero utilisation and the kink, per second, WAD.
    uint256 public immutable slope1PerSecond;
    /// @notice Rate added linearly between the kink and full utilisation, per second, WAD.
    uint256 public immutable slope2PerSecond;
    /// @notice Utilisation at which the curve steepens, WAD. Strictly between 0 and 1e18.
    uint256 public immutable kink;

    // Solidity has no immutable arrays, so the premium table is unrolled. The order is exactly the
    // declaration order of `Session`.
    uint256 private immutable _mRegular;
    uint256 private immutable _mPre;
    uint256 private immutable _mPost;
    uint256 private immutable _mClosedOvernight;
    uint256 private immutable _mClosedWeekend;
    uint256 private immutable _mClosedHoliday;

    /// @notice Ceiling on `base + slope1 + slope2`, per second, WAD. Roughly 1000% APR.
    /// @dev The curve itself is policy, but an unbounded one is not: `AftermarketCredit._accrue`
    ///      forms `rate * elapsed`, its square and its cube in checked arithmetic, and every
    ///      state-changing entry point in the engine - `repay` included - begins with `_accrue`. A
    ///      model deployed with an absurd slope would therefore brick repayment, which is the one
    ///      thing the design promises can never happen. The engine clamps as well; this bound stops
    ///      the mistake being made in the first place, where it is visible at deployment.
    uint256 public constant MAX_TOTAL_RATE_PER_SECOND = 317_097_919_838;

    /// @notice Ceiling on any session premium, WAD. Ten times the curve.
    uint256 public constant MAX_SESSION_MULTIPLIER = 10e18;

    error ZeroAddress();
    error InvalidKink(uint256 kink);
    error InvalidMultiplier(uint256 index, uint256 multiplier);
    error InvalidRate(uint256 totalRatePerSecond);

    /// @param calendar_          Trading calendar used when the caller does not supply a session.
    /// @param baseRatePerSecond_ Rate floor, per second, WAD.
    /// @param slope1PerSecond_   Slope below the kink, per second, WAD.
    /// @param slope2PerSecond_   Slope above the kink, per second, WAD.
    /// @param kink_              Utilisation at which the curve steepens, WAD.
    /// @param sessionMultipliers Premium per `Session`, WAD, indexed by the enum. Each must be at
    ///                           least 1e18: the session surcharge may never *discount* the curve,
    ///                           because that would make it cheaper to hold risk exactly when the
    ///                           protocol is least able to manage it.
    constructor(
        ITradingCalendar calendar_,
        uint256 baseRatePerSecond_,
        uint256 slope1PerSecond_,
        uint256 slope2PerSecond_,
        uint256 kink_,
        uint256[SESSION_COUNT] memory sessionMultipliers
    ) {
        if (address(calendar_) == address(0)) revert ZeroAddress();
        if (kink_ == 0 || kink_ >= WAD) revert InvalidKink(kink_);

        uint256 totalRate = baseRatePerSecond_ + slope1PerSecond_ + slope2PerSecond_;
        if (totalRate > MAX_TOTAL_RATE_PER_SECOND) revert InvalidRate(totalRate);

        for (uint256 i; i < SESSION_COUNT; ++i) {
            if (sessionMultipliers[i] < WAD || sessionMultipliers[i] > MAX_SESSION_MULTIPLIER) {
                revert InvalidMultiplier(i, sessionMultipliers[i]);
            }
        }

        calendar = calendar_;
        baseRatePerSecond = baseRatePerSecond_;
        slope1PerSecond = slope1PerSecond_;
        slope2PerSecond = slope2PerSecond_;
        kink = kink_;

        _mRegular = sessionMultipliers[0];
        _mPre = sessionMultipliers[1];
        _mPost = sessionMultipliers[2];
        _mClosedOvernight = sessionMultipliers[3];
        _mClosedWeekend = sessionMultipliers[4];
        _mClosedHoliday = sessionMultipliers[5];
    }

    /// @inheritdoc ISessionRateModel
    /// @dev Clamped at 1e18 so that a market carrying realised bad debt (debt above supply) does not
    ///      extrapolate the second slope into an absurd rate and make the position unrepayable.
    function utilization(uint256 totalDebtAssets, uint256 totalAssets) public pure returns (uint256) {
        if (totalDebtAssets == 0 || totalAssets == 0) return 0;
        uint256 u = Math.mulDiv(totalDebtAssets, WAD, totalAssets);
        return u > WAD ? WAD : u;
    }

    /// @notice The kinked curve before the session premium, per second, WAD.
    /// @dev Exposed so a UI can show the market rate and the closed-market surcharge as two separate
    ///      numbers, which is the honest way to present it to a borrower.
    function curveRatePerSecond(uint256 totalDebtAssets, uint256 totalAssets) public view returns (uint256) {
        uint256 u = utilization(totalDebtAssets, totalAssets);
        if (u <= kink) {
            return baseRatePerSecond + Math.mulDiv(slope1PerSecond, u, kink);
        }
        return baseRatePerSecond + slope1PerSecond + Math.mulDiv(slope2PerSecond, u - kink, WAD - kink);
    }

    /// @inheritdoc ISessionRateModel
    function sessionMultiplier(Session session) public view returns (uint256) {
        if (session == Session.REGULAR) return _mRegular;
        if (session == Session.PRE) return _mPre;
        if (session == Session.POST) return _mPost;
        if (session == Session.CLOSED_OVERNIGHT) return _mClosedOvernight;
        if (session == Session.CLOSED_WEEKEND) return _mClosedWeekend;
        return _mClosedHoliday;
    }

    /// @inheritdoc ISessionRateModel
    function ratePerSecondAt(uint256 totalDebtAssets, uint256 totalAssets, Session session)
        public
        view
        returns (uint256)
    {
        return Math.mulDiv(curveRatePerSecond(totalDebtAssets, totalAssets), sessionMultiplier(session), WAD);
    }

    /// @inheritdoc ISessionRateModel
    function ratePerSecond(uint256 totalDebtAssets, uint256 totalAssets) external view returns (uint256) {
        return ratePerSecondAt(totalDebtAssets, totalAssets, calendar.session());
    }
}

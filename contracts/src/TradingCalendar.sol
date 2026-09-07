// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {Session} from "./libraries/Types.sol";

/// @title  TradingCalendar
/// @notice An onchain NYSE/Nasdaq trading calendar: real US Eastern time with real daylight saving,
///         the real 2026 and 2027 exchange holidays, and the real half days.
/// @dev    Four ideas carry the whole contract.
///
///         1. Civil dates come from Howard Hinnant's `days_from_civil` / `civil_from_days` pair,
///            which is exact for every proleptic Gregorian date and costs a handful of divisions.
///            No approximation of month lengths or leap years appears anywhere.
///
///         2. US Eastern time is UTC-5 outside the daylight window and UTC-4 inside it. The window
///            opens on the second Sunday of March at 07:00 UTC and closes on the first Sunday of
///            November at 06:00 UTC. Both boundaries are derived from the civil calendar of the
///            year being queried, so the DST rule is computed rather than tabulated.
///
///         3. Exchange holidays and half days are the only genuinely irregular input, so they are
///            the only thing stored: two bits per calendar day, 128 days to a storage word. A read
///            that scans a long weekend usually touches a single word.
///
///         4. That table is finite, so the calendar has an explicit horizon and fails closed at it.
///            Outside `[SEEDED_FROM_DAY, SEEDED_UNTIL_DAY]` every instant reports
///            `CLOSED_HOLIDAY`, `isOpen` is false, and the day scans answer zero rather than a
///            guess. Defaulting an unseeded day to a normal full session - which is what a bare
///            two-bit table does - is the one failure mode a market calendar must not have: it
///            silently promotes an exchange holiday or a 13:00 half day back into a live trading
///            session, and everything downstream then applies the *open* liquidation threshold and
///            a zero gap haircut to a dead tape. Reporting a permanent closure instead cannot seize
///            anything, cannot price anything, and leaves repayment and collateral top-up - the two
///            paths that never read this contract's scans - working exactly as before.
///
///         The contract has no owner, no admin function and no upgrade path. The constructor seeds
///         the day flags and nothing can change them afterwards, so extending the horizon means
///         deploying a new calendar (and, because both consumers hold it `immutable`, a new oracle
///         set and engine) before `SEEDED_UNTIL_DAY` is reached. The sunset is a published date
///         rather than a silent drift, which is the whole point of making it explicit.
contract TradingCalendar is ITradingCalendar {
    // ---------------------------------------------------------------------------------------------
    // errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Thrown when a query predates the window in which a previous close can exist.
    error TimestampTooEarly(uint256 timestamp);

    // ---------------------------------------------------------------------------------------------
    // session geometry, as seconds from Eastern midnight
    // ---------------------------------------------------------------------------------------------

    uint256 private constant PRE_OPEN = 4 hours; // 04:00 ET
    uint256 private constant REGULAR_OPEN = 9 hours + 30 minutes; // 09:30 ET
    uint256 private constant REGULAR_CLOSE = 16 hours; // 16:00 ET
    uint256 private constant POST_CLOSE = 20 hours; // 20:00 ET
    uint256 private constant EARLY_REGULAR_CLOSE = 13 hours; // 13:00 ET on a half day
    uint256 private constant EARLY_POST_CLOSE = 17 hours; // 17:00 ET on a half day

    // ---------------------------------------------------------------------------------------------
    // Eastern time
    // ---------------------------------------------------------------------------------------------

    uint256 private constant EST_OFFSET = 5 hours; // UTC-5, standard time
    uint256 private constant EDT_OFFSET = 4 hours; // UTC-4, daylight time
    uint256 private constant DST_START_UTC_HOUR = 7 hours; // 02:00 EST on the second Sunday of March
    uint256 private constant DST_END_UTC_HOUR = 6 hours; // 02:00 EDT on the first Sunday of November
    uint256 private constant MARCH = 3;
    uint256 private constant NOVEMBER = 11;

    uint256 private constant SECONDS_PER_DAY = 1 days;
    uint256 private constant SUNDAY = 0;
    uint256 private constant SATURDAY = 6;
    /// @dev Day number 0 is 1970-01-01, a Thursday, which is index 4 in a Sunday-first week.
    uint256 private constant EPOCH_WEEKDAY = 4;

    // ---------------------------------------------------------------------------------------------
    // day flags
    // ---------------------------------------------------------------------------------------------

    uint256 private constant FLAG_NORMAL = 0;
    uint256 private constant FLAG_HOLIDAY = 1;
    uint256 private constant FLAG_EARLY_CLOSE = 2;

    uint256 private constant BITS_PER_DAY = 2;
    uint256 private constant DAYS_PER_WORD = 128; // 256 bits / 2 bits per day
    uint256 private constant DAY_IN_WORD_MASK = DAYS_PER_WORD - 1;
    uint256 private constant FLAG_MASK = 3;

    /// @dev Four consecutive non-trading days is the worst case the exchange produces (a Friday
    ///      holiday, the weekend, or a Monday holiday after a Friday half day). Ten is generous
    ///      headroom and still bounds a read to a handful of iterations.
    uint256 private constant MAX_SCAN_DAYS = 10;

    /// @dev Floor for any query, so the backward scan and the UTC-to-Eastern shift cannot underflow.
    uint256 private constant MIN_TIMESTAMP = MAX_SCAN_DAYS * SECONDS_PER_DAY;

    /// @notice First calendar day the holiday table covers: 2025-12-22.
    /// @dev Days since the unix epoch, matching the constructor's seed values. The table opens a
    ///      week and a half before 2026 so that a backward scan from the first days of January
    ///      still lands on a real previous close rather than falling off the start of the range.
    uint256 public constant SEEDED_FROM_DAY = 20_444;

    /// @notice Last calendar day the holiday table covers: 2027-12-31.
    /// @dev Every instant on a later day is reported as `CLOSED_HOLIDAY`. Publish this date: it is
    ///      the deadline by which a replacement calendar has to be deployed.
    uint256 public constant SEEDED_UNTIL_DAY = 21_183;

    /// @notice Packed exchange-day flags: `dayNumber / 128` selects the word, `dayNumber % 128`
    ///         selects a two-bit slot inside it holding `FLAG_NORMAL`, `FLAG_HOLIDAY` or
    ///         `FLAG_EARLY_CLOSE`. Only days inside `[SEEDED_FROM_DAY, SEEDED_UNTIL_DAY]` are ever
    ///         consulted; outside it the day is closed regardless of what the word holds.
    mapping(uint256 wordIndex => uint256 packedFlags) private _flagWords;

    // ---------------------------------------------------------------------------------------------
    // construction
    // ---------------------------------------------------------------------------------------------

    /// @notice Seeds the 2026 and 2027 NYSE calendar, plus the December 2025 run-in that a backward
    ///         scan from early January needs. Values are day numbers since the unix epoch, sorted
    ///         ascending, taken from the NYSE Group holiday and early-closings calendar.
    /// @dev    The observed-date rules are already baked into these dates: a holiday falling on a
    ///         Saturday is pulled back to the Friday, one falling on a Sunday is pushed to the
    ///         Monday, and the exchange declines to pull New Year's Day back across a year end
    ///         (which is why 2027-12-31 is absent even though 2028-01-01 is a Saturday).
    constructor() {
        uint32[21] memory holidays = [
            uint32(20_447), // 2025-12-25 Thu  Christmas Day
            20_454, //        2026-01-01 Thu  New Year's Day
            20_472, //        2026-01-19 Mon  Martin Luther King, Jr. Day
            20_500, //        2026-02-16 Mon  Washington's Birthday
            20_546, //        2026-04-03 Fri  Good Friday
            20_598, //        2026-05-25 Mon  Memorial Day
            20_623, //        2026-06-19 Fri  Juneteenth National Independence Day
            20_637, //        2026-07-03 Fri  Independence Day, observed (July 4 is a Saturday)
            20_703, //        2026-09-07 Mon  Labor Day
            20_783, //        2026-11-26 Thu  Thanksgiving Day
            20_812, //        2026-12-25 Fri  Christmas Day
            20_819, //        2027-01-01 Fri  New Year's Day
            20_836, //        2027-01-18 Mon  Martin Luther King, Jr. Day
            20_864, //        2027-02-15 Mon  Washington's Birthday
            20_903, //        2027-03-26 Fri  Good Friday
            20_969, //        2027-05-31 Mon  Memorial Day
            20_987, //        2027-06-18 Fri  Juneteenth, observed (June 19 is a Saturday)
            21_004, //        2027-07-05 Mon  Independence Day, observed (July 4 is a Sunday)
            21_067, //        2027-09-06 Mon  Labor Day
            21_147, //        2027-11-25 Thu  Thanksgiving Day
            21_176 //         2027-12-24 Fri  Christmas Day, observed (December 25 is a Saturday)
        ];

        uint32[4] memory earlyCloses = [
            uint32(20_446), // 2025-12-24 Wed  Christmas Eve
            20_784, //         2026-11-27 Fri  day after Thanksgiving
            20_811, //         2026-12-24 Thu  Christmas Eve
            21_148 //          2027-11-26 Fri  day after Thanksgiving
        ];
        // 2027 has no Christmas Eve half day: Christmas is already observed on Friday 2027-12-24 as
        // a full closure, and 2027-12-23 trades a normal session.

        for (uint256 i; i < holidays.length; ++i) {
            _seedDay(holidays[i], FLAG_HOLIDAY);
        }
        for (uint256 i; i < earlyCloses.length; ++i) {
            _seedDay(earlyCloses[i], FLAG_EARLY_CLOSE);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // external view surface
    // ---------------------------------------------------------------------------------------------

    /// @notice Resolves the full market state at an instant: where the exchange is in its daily
    ///         cycle, when the next regular session begins, and when the previous one ended.
    /// @dev    Pure of storage writes and bounded to `MAX_SCAN_DAYS` iterations per direction, so it
    ///         is safe to call from an oracle read on every borrow and every liquidation.
    /// @param  timestamp Unix seconds (UTC).
    /// @return The session in force at `timestamp`, or `CLOSED_HOLIDAY` past the seeded horizon.
    /// @return The unix second of the first regular open strictly after `timestamp`. Strictly after,
    ///         so that a query made at the opening bell reports the following day rather than
    ///         returning its own argument. Zero when no such open exists inside the seeded horizon.
    /// @return The unix second of the most recent regular close at or before `timestamp`: 16:00 ET,
    ///         or 13:00 ET on a half day, skipping weekends and holidays. Zero when there is none
    ///         inside the seeded horizon.
    function sessionAt(uint256 timestamp) external view returns (Session, uint64, uint64) {
        (uint256 dayNumber, uint256 secondOfDay, uint256 dstStart, uint256 dstEnd) = _easternClock(timestamp);
        return (
            _classify(dayNumber, secondOfDay),
            _scanForwardToOpen(timestamp, dayNumber, dstStart, dstEnd),
            _scanBackwardToClose(timestamp, dayNumber, dstStart, dstEnd)
        );
    }

    /// @notice The session in force right now.
    /// @dev    Equivalent to the first return value of `sessionAt(block.timestamp)`, but it skips
    ///         both day scans.
    /// @return The session at `block.timestamp`.
    function session() external view returns (Session) {
        (uint256 dayNumber, uint256 secondOfDay,,) = _easternClock(block.timestamp);
        return _classify(dayNumber, secondOfDay);
    }

    /// @notice Whether a regular session is running, which is the only window in which the exchange
    ///         prints a continuous two-sided market.
    /// @dev    Pre-market and post-market both report false: their prints are too thin to mark
    ///         collateral against.
    /// @param  timestamp Unix seconds (UTC).
    /// @return True between 09:30 ET inclusive and the regular close exclusive on a trading day.
    function isOpen(uint256 timestamp) external view returns (bool) {
        (uint256 dayNumber, uint256 secondOfDay,,) = _easternClock(timestamp);
        return _classify(dayNumber, secondOfDay) == Session.REGULAR;
    }

    /// @notice How long the exchange has been out of its regular session.
    /// @dev    Downstream risk logic sizes its gap haircut on this number, so it keeps counting
    ///         through pre-market and post-market: those sessions do not reopen continuous trading.
    /// @param  timestamp Unix seconds (UTC).
    /// @return Seconds elapsed since the previous regular close, or zero while a regular session is
    ///         running. Past the seeded horizon there is no previous close to measure from and the
    ///         answer saturates, which pins the downstream gap haircut at its cap.
    function closedFor(uint256 timestamp) external view returns (uint256) {
        (uint256 dayNumber, uint256 secondOfDay, uint256 dstStart, uint256 dstEnd) = _easternClock(timestamp);
        if (_classify(dayNumber, secondOfDay) == Session.REGULAR) return 0;
        unchecked {
            return timestamp - _scanBackwardToClose(timestamp, dayNumber, dstStart, dstEnd);
        }
    }

    /// @notice When continuous trading resumes.
    /// @dev    Skips weekends and exchange holidays, so a Friday-evening query lands on Monday and a
    ///         query on the Friday before a Monday holiday lands on Tuesday.
    /// @param  timestamp Unix seconds (UTC).
    /// @return The unix second of the first regular open strictly after `timestamp`, or zero when
    ///         the answer would fall outside the horizon this calendar's holiday table covers.
    function nextOpen(uint256 timestamp) external view returns (uint64) {
        (uint256 dayNumber,, uint256 dstStart, uint256 dstEnd) = _easternClock(timestamp);
        return _scanForwardToOpen(timestamp, dayNumber, dstStart, dstEnd);
    }

    // ---------------------------------------------------------------------------------------------
    // session resolution
    // ---------------------------------------------------------------------------------------------

    /// @dev Maps an Eastern calendar day and time of day onto a session. The three closed variants
    ///      describe the day the query stands on: a Saturday or Sunday is a weekend closure at any
    ///      hour, a flagged weekday is a holiday closure at any hour (the exchange runs no pre- or
    ///      post-market on a holiday), and anything else is the overnight gap of a trading day.
    function _classify(uint256 dayNumber, uint256 secondOfDay) private view returns (Session) {
        // Outside the seeded horizon the table has nothing to say, and "nothing to say" must read
        // as shut rather than as a normal session. This branch is what stops the first unseeded
        // half day from being treated as a full trading day with a live tape.
        if (!_isSeeded(dayNumber)) return Session.CLOSED_HOLIDAY;

        uint256 weekday = _weekday(dayNumber);
        if (weekday == SUNDAY || weekday == SATURDAY) return Session.CLOSED_WEEKEND;

        uint256 flag = _dayFlag(dayNumber);
        if (flag == FLAG_HOLIDAY) return Session.CLOSED_HOLIDAY;

        (uint256 regularClose, uint256 postClose) =
            flag == FLAG_EARLY_CLOSE ? (EARLY_REGULAR_CLOSE, EARLY_POST_CLOSE) : (REGULAR_CLOSE, POST_CLOSE);

        if (secondOfDay < PRE_OPEN || secondOfDay >= postClose) return Session.CLOSED_OVERNIGHT;
        if (secondOfDay < REGULAR_OPEN) return Session.PRE;
        if (secondOfDay < regularClose) return Session.REGULAR;
        return Session.POST;
    }

    /// @dev Walks forward from `dayNumber` to the first trading day whose 09:30 ET open lands
    ///      strictly after `timestamp`, and answers zero when no such day exists inside the seeded
    ///      horizon. Zero is a sentinel, not a timestamp: callers that need a real opening bell -
    ///      `AftermarketCredit.flag`, which sizes the grace deadline off it - must reject it rather
    ///      than fall back on a guess about a year this table does not describe.
    function _scanForwardToOpen(uint256 timestamp, uint256 dayNumber, uint256 dstStart, uint256 dstEnd)
        private
        view
        returns (uint64)
    {
        uint256 scanDay = dayNumber;
        for (uint256 i; i < MAX_SCAN_DAYS; ++i) {
            if (_isTradingDay(scanDay)) {
                uint256 open = _utcFromEastern(scanDay, REGULAR_OPEN, dstStart, dstEnd);
                // casting to 'uint64' is safe because the calendar only ever produces opens within
                // ten days of the queried timestamp, and a uint64 unix second reaches the year
                // 584942417355. The interface fixes the width; the value cannot approach it.
                // forge-lint: disable-next-line(unsafe-typecast)
                if (open > timestamp) return uint64(open);
            }
            unchecked {
                ++scanDay;
            }
        }
        return 0;
    }

    /// @dev Walks backward from `dayNumber` to the most recent trading day whose regular close
    ///      (16:00 ET, or 13:00 ET on a half day) lands at or before `timestamp`. Answers zero when
    ///      there is none inside the seeded horizon, which makes `closedFor` maximal and therefore
    ///      pins the downstream gap haircut at its cap - the conservative direction.
    function _scanBackwardToClose(uint256 timestamp, uint256 dayNumber, uint256 dstStart, uint256 dstEnd)
        private
        view
        returns (uint64)
    {
        uint256 scanDay = dayNumber;
        for (uint256 i; i < MAX_SCAN_DAYS; ++i) {
            if (_isTradingDay(scanDay)) {
                uint256 closeSecond = _dayFlag(scanDay) == FLAG_EARLY_CLOSE ? EARLY_REGULAR_CLOSE : REGULAR_CLOSE;
                uint256 close = _utcFromEastern(scanDay, closeSecond, dstStart, dstEnd);
                // casting to 'uint64' is safe for the same reason as in `_scanForwardToOpen`: the
                // close is within ten days of the queried timestamp.
                // forge-lint: disable-next-line(unsafe-typecast)
                if (close <= timestamp) return uint64(close);
            }
            if (scanDay == 0) break;
            unchecked {
                --scanDay;
            }
        }
        return 0;
    }

    /// @dev A day the exchange trades at all: a seeded weekday that is not a full closure. Half days
    ///      are trading days; they merely close earlier.
    function _isTradingDay(uint256 dayNumber) private view returns (bool) {
        if (!_isSeeded(dayNumber)) return false;
        uint256 weekday = _weekday(dayNumber);
        if (weekday == SUNDAY || weekday == SATURDAY) return false;
        return _dayFlag(dayNumber) != FLAG_HOLIDAY;
    }

    /// @dev Whether the holiday table actually describes this day.
    function _isSeeded(uint256 dayNumber) private pure returns (bool) {
        return dayNumber >= SEEDED_FROM_DAY && dayNumber <= SEEDED_UNTIL_DAY;
    }

    // ---------------------------------------------------------------------------------------------
    // day flag storage
    // ---------------------------------------------------------------------------------------------

    function _seedDay(uint256 dayNumber, uint256 flag) private {
        unchecked {
            _flagWords[dayNumber / DAYS_PER_WORD] |= flag << ((dayNumber & DAY_IN_WORD_MASK) * BITS_PER_DAY);
        }
    }

    function _dayFlag(uint256 dayNumber) private view returns (uint256) {
        unchecked {
            uint256 word = _flagWords[dayNumber / DAYS_PER_WORD];
            return (word >> ((dayNumber & DAY_IN_WORD_MASK) * BITS_PER_DAY)) & FLAG_MASK;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Eastern time
    // ---------------------------------------------------------------------------------------------

    /// @dev Reads the Eastern civil clock at `timestamp` and hands back that year's daylight window
    ///      so callers can convert Eastern wall-clock instants back to UTC without recomputing it.
    ///
    ///      Reusing one year's window across a day scan is safe. A scan spans at most ten days, so
    ///      the only year boundary it can straddle is the turn of the year, and late December and
    ///      early January are standard time under either year's window.
    /// @return dayNumber   Days since 1970-01-01 in Eastern local time.
    /// @return secondOfDay Seconds since Eastern local midnight.
    /// @return dstStart    Unix second at which daylight time begins in the queried year.
    /// @return dstEnd      Unix second at which daylight time ends in the queried year.
    function _easternClock(uint256 timestamp)
        private
        pure
        returns (uint256 dayNumber, uint256 secondOfDay, uint256 dstStart, uint256 dstEnd)
    {
        if (timestamp < MIN_TIMESTAMP) revert TimestampTooEarly(timestamp);
        (dstStart, dstEnd) = _daylightWindow(timestamp);
        unchecked {
            uint256 local = timestamp - _utcOffset(timestamp, dstStart, dstEnd);
            dayNumber = local / SECONDS_PER_DAY;
            secondOfDay = local - dayNumber * SECONDS_PER_DAY;
        }
    }

    /// @dev US daylight saving time runs from 02:00 local on the second Sunday of March to 02:00
    ///      local on the first Sunday of November. Expressed in UTC those are 07:00 (the clock is
    ///      still on UTC-5 when it jumps) and 06:00 (it is still on UTC-4 when it falls back).
    function _daylightWindow(uint256 timestamp) private pure returns (uint256 dstStart, uint256 dstEnd) {
        (uint256 year,,) = _civilFromDays(timestamp / SECONDS_PER_DAY);
        unchecked {
            dstStart = _nthSundayOfMonth(year, MARCH, 2) * SECONDS_PER_DAY + DST_START_UTC_HOUR;
            dstEnd = _nthSundayOfMonth(year, NOVEMBER, 1) * SECONDS_PER_DAY + DST_END_UTC_HOUR;
        }
    }

    function _utcOffset(uint256 timestamp, uint256 dstStart, uint256 dstEnd) private pure returns (uint256) {
        return timestamp >= dstStart && timestamp < dstEnd ? EDT_OFFSET : EST_OFFSET;
    }

    /// @dev Converts an Eastern wall-clock instant back to UTC. Assume standard time first; if the
    ///      resulting instant falls inside the daylight window then the reading was daylight time
    ///      after all, and the correct instant is an hour earlier. The only wall-clock times this
    ///      contract converts are 09:30, 13:00 and 16:00, all far from the 02:00 changeover, so
    ///      neither the spring-forward gap nor the autumn repeat is reachable here.
    function _utcFromEastern(uint256 dayNumber, uint256 secondOfDay, uint256 dstStart, uint256 dstEnd)
        private
        pure
        returns (uint256)
    {
        unchecked {
            uint256 local = dayNumber * SECONDS_PER_DAY + secondOfDay;
            uint256 asStandardTime = local + EST_OFFSET;
            if (asStandardTime >= dstStart && asStandardTime < dstEnd) return local + EDT_OFFSET;
            return asStandardTime;
        }
    }

    /// @dev Day number of the `ordinal`-th Sunday of a month, one-indexed.
    function _nthSundayOfMonth(uint256 year, uint256 month, uint256 ordinal) private pure returns (uint256) {
        unchecked {
            uint256 firstOfMonth = _daysFromCivil(year, month, 1);
            uint256 daysToFirstSunday = (7 - _weekday(firstOfMonth)) % 7;
            return firstOfMonth + daysToFirstSunday + (ordinal - 1) * 7;
        }
    }

    /// @dev Day of week for a day number, 0 = Sunday through 6 = Saturday.
    function _weekday(uint256 dayNumber) private pure returns (uint256) {
        unchecked {
            return (dayNumber + EPOCH_WEEKDAY) % 7;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // civil calendar, after Howard Hinnant's `chrono`-compatible algorithms
    // ---------------------------------------------------------------------------------------------

    /// @dev Days since 1970-01-01 for a proleptic Gregorian date. Exact inverse of
    ///      `_civilFromDays` for every year from 1970 onward.
    ///
    ///      The algorithm shifts the year so that it starts in March, which puts the leap day at the
    ///      end and makes the day-of-year a closed-form expression, then counts whole 400-year eras.
    function _daysFromCivil(uint256 year, uint256 month, uint256 day) private pure returns (uint256) {
        unchecked {
            uint256 shiftedYear = year - (month <= 2 ? 1 : 0);
            uint256 era = shiftedYear / 400;
            uint256 yearOfEra = shiftedYear - era * 400; // [0, 399]
            uint256 dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1; // [0, 365]
            uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear; // [0, 146096]
            return era * 146_097 + dayOfEra - 719_468;
        }
    }

    /// @dev Proleptic Gregorian date for a day number counted from 1970-01-01. Exact inverse of
    ///      `_daysFromCivil`.
    function _civilFromDays(uint256 dayNumber) private pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            uint256 shifted = dayNumber + 719_468; // rebase onto 0000-03-01
            uint256 era = shifted / 146_097;
            uint256 dayOfEra = shifted - era * 146_097; // [0, 146096]
            uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365; // [0, 399]
            uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100); // [0, 365]
            uint256 marchBasedMonth = (5 * dayOfYear + 2) / 153; // [0, 11], 0 = March
            day = dayOfYear - (153 * marchBasedMonth + 2) / 5 + 1; // [1, 31]
            month = marchBasedMonth < 10 ? marchBasedMonth + 3 : marchBasedMonth - 9; // [1, 12]
            year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
        }
    }
}

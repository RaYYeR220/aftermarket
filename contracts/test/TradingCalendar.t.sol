// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {TradingCalendar} from "../src/TradingCalendar.sol";
import {ITradingCalendar} from "../src/interfaces/ITradingCalendar.sol";
import {Session} from "../src/libraries/Types.sol";

/// @notice Every timestamp in this file was derived from the IANA `America/New_York` zone and the
///         published NYSE 2026/2027 holiday and early-closing calendar, then written out as a raw
///         unix second with its Eastern wall-clock reading in the trailing comment. Nothing here is
///         computed by the contract under test, so the suite is a genuine differential check.
contract TradingCalendarTest is Test {
    TradingCalendar internal calendar;

    // 2026-01-01 00:00:00 UTC and 2028-01-01 00:00:00 UTC: the fuzzing window.
    uint256 internal constant YEAR_2026_START = 1_767_225_600;
    uint256 internal constant YEAR_2028_START = 1_830_297_600;

    /// @dev 2027-12-31 09:30:00 ET, the last regular open the seeded holiday table describes.
    uint256 internal constant LAST_SEEDED_OPEN = 1_830_263_400;

    uint256 internal constant WEEKEND_GAP = 65 hours + 30 minutes; // Fri 16:00 ET -> Mon 09:30 ET
    uint256 internal constant LONG_WEEKEND_GAP = 89 hours + 30 minutes; // Fri 16:00 ET -> Tue 09:30 ET

    /// @dev Rolling `keccak256(digest, open, close)` over the 502 NYSE trading days of 2026 and
    ///      2027, seeded from `bytes32(0)`, computed offline from the IANA `America/New_York` zone.
    bytes32 internal constant TRADING_DAY_DIGEST = 0x83ec7fdc3e419a2db6932950f91634a97d3c1d032d4151134a0af31252581f3d;

    function setUp() public {
        calendar = new TradingCalendar();
    }

    // --------------------------------------------------------------------------------------------
    // helpers
    // --------------------------------------------------------------------------------------------

    function _assertSession(uint256 timestamp, Session expected, string memory label) internal view {
        (Session actual,,) = calendar.sessionAt(timestamp);
        assertEq(uint256(actual), uint256(expected), label);
    }

    function _assertNextOpen(uint256 timestamp, uint64 expected, string memory label) internal view {
        assertEq(calendar.nextOpen(timestamp), expected, label);
        (, uint64 fromTuple,) = calendar.sessionAt(timestamp);
        assertEq(fromTuple, expected, string.concat(label, " (tuple)"));
    }

    function _assertLastClose(uint256 timestamp, uint64 expected, string memory label) internal view {
        (,, uint64 lastClose) = calendar.sessionAt(timestamp);
        assertEq(lastClose, expected, label);
    }

    // --------------------------------------------------------------------------------------------
    // session boundaries, to the second
    // --------------------------------------------------------------------------------------------

    /// @dev Wednesday 2026-06-10, a plain full-length session in EDT (UTC-4).
    function test_SessionBoundariesToTheSecond_Edt() public view {
        _assertSession(1_781_078_399, Session.CLOSED_OVERNIGHT, "03:59:59 ET is still overnight");
        _assertSession(1_781_078_400, Session.PRE, "04:00:00 ET opens pre-market");
        _assertSession(1_781_098_199, Session.PRE, "09:29:59 ET is still pre-market");
        _assertSession(1_781_098_200, Session.REGULAR, "09:30:00 ET opens the regular session");
        _assertSession(1_781_121_599, Session.REGULAR, "15:59:59 ET is still regular");
        _assertSession(1_781_121_600, Session.POST, "16:00:00 ET hands over to post");
        _assertSession(1_781_135_999, Session.POST, "19:59:59 ET is still post");
        _assertSession(1_781_136_000, Session.CLOSED_OVERNIGHT, "20:00:00 ET closes the tape");
    }

    /// @dev Wednesday 2027-01-20, a plain full-length session in EST (UTC-5).
    function test_SessionBoundariesToTheSecond_Est() public view {
        _assertSession(1_800_435_599, Session.CLOSED_OVERNIGHT, "03:59:59 ET is still overnight");
        _assertSession(1_800_435_600, Session.PRE, "04:00:00 ET opens pre-market");
        _assertSession(1_800_455_399, Session.PRE, "09:29:59 ET is still pre-market");
        _assertSession(1_800_455_400, Session.REGULAR, "09:30:00 ET opens the regular session");
        _assertSession(1_800_478_799, Session.REGULAR, "15:59:59 ET is still regular");
        _assertSession(1_800_478_800, Session.POST, "16:00:00 ET hands over to post");
        _assertSession(1_800_493_199, Session.POST, "19:59:59 ET is still post");
        _assertSession(1_800_493_200, Session.CLOSED_OVERNIGHT, "20:00:00 ET closes the tape");
    }

    function test_IsOpenTracksTheRegularSessionOnly() public view {
        assertFalse(calendar.isOpen(1_781_098_199), "09:29:59 ET is not open");
        assertTrue(calendar.isOpen(1_781_098_200), "09:30:00 ET is open");
        assertTrue(calendar.isOpen(1_781_121_599), "15:59:59 ET is open");
        assertFalse(calendar.isOpen(1_781_121_600), "16:00:00 ET is not open");
        assertFalse(calendar.isOpen(1_781_078_400), "pre-market is not open");
        assertFalse(calendar.isOpen(1_781_135_999), "post-market is not open");
    }

    // --------------------------------------------------------------------------------------------
    // early closes
    // --------------------------------------------------------------------------------------------

    /// @dev Friday 2026-11-27, the day after Thanksgiving: regular ends 13:00 ET, post ends 17:00 ET.
    function test_EarlyClose_DayAfterThanksgiving2026() public view {
        _assertSession(1_795_802_399, Session.REGULAR, "12:59:59 ET is still regular");
        _assertSession(1_795_802_400, Session.POST, "13:00:00 ET closes the regular session");
        _assertSession(1_795_816_799, Session.POST, "16:59:59 ET is still post");
        _assertSession(1_795_816_800, Session.CLOSED_OVERNIGHT, "17:00:00 ET closes the tape");
        _assertLastClose(1_795_802_400, 1_795_802_400, "13:00 ET is the regular close");
    }

    /// @dev Thursday 2026-12-24, Christmas Eve.
    function test_EarlyClose_ChristmasEve2026() public view {
        _assertSession(1_798_135_199, Session.REGULAR, "12:59:59 ET is still regular");
        _assertSession(1_798_135_200, Session.POST, "13:00:00 ET closes the regular session");
        _assertSession(1_798_149_599, Session.POST, "16:59:59 ET is still post");
        _assertSession(1_798_149_600, Session.CLOSED_OVERNIGHT, "17:00:00 ET closes the tape");
        _assertLastClose(1_798_135_200, 1_798_135_200, "13:00 ET is the regular close");
    }

    /// @dev Friday 2027-11-26, the day after Thanksgiving; 2027 has no Christmas Eve half day
    ///      because Christmas is observed on Friday 2027-12-24 as a full closure.
    function test_EarlyClose_DayAfterThanksgiving2027() public view {
        _assertSession(1_827_251_999, Session.REGULAR, "12:59:59 ET is still regular");
        _assertSession(1_827_252_000, Session.POST, "13:00:00 ET closes the regular session");
        _assertSession(1_827_266_399, Session.POST, "16:59:59 ET is still post");
        _assertSession(1_827_266_400, Session.CLOSED_OVERNIGHT, "17:00:00 ET closes the tape");
        _assertLastClose(1_827_252_000, 1_827_252_000, "13:00 ET is the regular close");
    }

    /// @dev 2027-12-23 is an ordinary Thursday: the half day belongs to the day before Christmas
    ///      only when Christmas itself is not already pulled back onto a Friday.
    function test_NoPhantomEarlyCloseBefore2027ObservedChristmas() public view {
        // 2027-12-23 15:30:00 ET
        _assertSession(1_829_593_800, Session.REGULAR, "2027-12-23 15:30 ET trades a full session");
    }

    // --------------------------------------------------------------------------------------------
    // holidays
    // --------------------------------------------------------------------------------------------

    /// @dev Each entry is 12:00:00 ET on the NYSE full-closure date.
    function test_Holidays2026() public view {
        _assertSession(1_767_286_800, Session.CLOSED_HOLIDAY, "2026-01-01 Thu New Year's Day");
        _assertSession(1_768_842_000, Session.CLOSED_HOLIDAY, "2026-01-19 Mon MLK Jr. Day");
        _assertSession(1_771_261_200, Session.CLOSED_HOLIDAY, "2026-02-16 Mon Washington's Birthday");
        _assertSession(1_775_232_000, Session.CLOSED_HOLIDAY, "2026-04-03 Fri Good Friday");
        _assertSession(1_779_724_800, Session.CLOSED_HOLIDAY, "2026-05-25 Mon Memorial Day");
        _assertSession(1_781_884_800, Session.CLOSED_HOLIDAY, "2026-06-19 Fri Juneteenth");
        _assertSession(1_783_094_400, Session.CLOSED_HOLIDAY, "2026-07-03 Fri Independence Day observed");
        _assertSession(1_788_796_800, Session.CLOSED_HOLIDAY, "2026-09-07 Mon Labor Day");
        _assertSession(1_795_712_400, Session.CLOSED_HOLIDAY, "2026-11-26 Thu Thanksgiving");
        _assertSession(1_798_218_000, Session.CLOSED_HOLIDAY, "2026-12-25 Fri Christmas Day");
    }

    /// @dev Each entry is 12:00:00 ET on the NYSE full-closure date.
    function test_Holidays2027() public view {
        _assertSession(1_798_822_800, Session.CLOSED_HOLIDAY, "2027-01-01 Fri New Year's Day");
        _assertSession(1_800_291_600, Session.CLOSED_HOLIDAY, "2027-01-18 Mon MLK Jr. Day");
        _assertSession(1_802_710_800, Session.CLOSED_HOLIDAY, "2027-02-15 Mon Washington's Birthday");
        _assertSession(1_806_076_800, Session.CLOSED_HOLIDAY, "2027-03-26 Fri Good Friday");
        _assertSession(1_811_779_200, Session.CLOSED_HOLIDAY, "2027-05-31 Mon Memorial Day");
        _assertSession(1_813_334_400, Session.CLOSED_HOLIDAY, "2027-06-18 Fri Juneteenth observed");
        _assertSession(1_814_803_200, Session.CLOSED_HOLIDAY, "2027-07-05 Mon Independence Day observed");
        _assertSession(1_820_246_400, Session.CLOSED_HOLIDAY, "2027-09-06 Mon Labor Day");
        _assertSession(1_827_162_000, Session.CLOSED_HOLIDAY, "2027-11-25 Thu Thanksgiving");
        _assertSession(1_829_667_600, Session.CLOSED_HOLIDAY, "2027-12-24 Fri Christmas Day observed");
    }

    /// @dev Good Friday floats with Easter, so it is worth pinning on its own: Easter 2026 is
    ///      2026-04-05 and Easter 2027 is 2027-03-28. The exchange is shut for the whole day, with
    ///      no pre- or post-market either side of it.
    function test_GoodFridayIsClosedAllDay() public view {
        // 2026-04-03, EDT. 04:30, 12:00 and 18:00 ET.
        _assertSession(1_775_205_000, Session.CLOSED_HOLIDAY, "2026-04-03 04:30 ET");
        _assertSession(1_775_232_000, Session.CLOSED_HOLIDAY, "2026-04-03 12:00 ET");
        _assertSession(1_775_253_600, Session.CLOSED_HOLIDAY, "2026-04-03 18:00 ET");
        // 2027-03-26, EDT. 04:30, 12:00 and 18:00 ET.
        _assertSession(1_806_049_800, Session.CLOSED_HOLIDAY, "2027-03-26 04:30 ET");
        _assertSession(1_806_076_800, Session.CLOSED_HOLIDAY, "2027-03-26 12:00 ET");
        _assertSession(1_806_098_400, Session.CLOSED_HOLIDAY, "2027-03-26 18:00 ET");
        // The Thursday before each Good Friday still trades a full session.
        _assertSession(1_775_159_940, Session.REGULAR, "2026-04-02 15:59 ET trades");
        _assertSession(1_805_990_400, Session.REGULAR, "2027-03-25 12:00 ET trades");
    }

    // --------------------------------------------------------------------------------------------
    // daylight saving time
    // --------------------------------------------------------------------------------------------

    /// @dev 2026 springs forward at 2026-03-08 07:00:00 UTC (02:00 EST becomes 03:00 EDT).
    function test_Dst2026_SpringForward() public view {
        // 06:59:59 UTC is 01:59:59 EST; 07:00:00 UTC is 03:00:00 EDT. Both land on the Sunday.
        _assertSession(1_772_953_199, Session.CLOSED_WEEKEND, "inside the gap, before the jump");
        _assertSession(1_772_953_200, Session.CLOSED_WEEKEND, "inside the gap, after the jump");
        // 2026-03-09 04:00:00 UTC. Under EDT this is Monday 00:00 ET; under EST it would still be
        // Sunday 23:00 ET. The day rolls over an hour earlier in UTC once DST is on.
        _assertSession(1_773_028_800, Session.CLOSED_OVERNIGHT, "Monday has begun in Eastern time");
        // The first EDT open is 13:30 UTC, not 14:30 UTC.
        _assertSession(1_773_062_999, Session.PRE, "2026-03-09 09:29:59 EDT");
        _assertSession(1_773_063_000, Session.REGULAR, "2026-03-09 09:30:00 EDT");
        // The Friday before still opens at 14:30 UTC because it is EST.
        _assertSession(1_772_807_399, Session.PRE, "2026-03-06 09:29:59 EST");
        _assertSession(1_772_807_400, Session.REGULAR, "2026-03-06 09:30:00 EST");
        // Crossing the transition inside a single lookup.
        _assertNextOpen(1_772_902_800, 1_773_063_000, "Sat 2026-03-07 -> Mon 09:30 EDT");
        _assertLastClose(1_772_902_800, 1_772_830_800, "Sat 2026-03-07 -> Fri 16:00 EST");
    }

    /// @dev 2026 falls back at 2026-11-01 06:00:00 UTC (02:00 EDT becomes 01:00 EST).
    function test_Dst2026_FallBack() public view {
        // 01:00-02:00 ET happens twice; both readings are the same Sunday.
        _assertSession(1_793_512_799, Session.CLOSED_WEEKEND, "01:59:59 EDT, first pass");
        _assertSession(1_793_512_800, Session.CLOSED_WEEKEND, "01:00:00 EST, second pass");
        // 2026-11-02 04:00:00 UTC. Under EST this is still Sunday 23:00 ET; under EDT it would have
        // wrongly rolled into Monday.
        _assertSession(1_793_592_000, Session.CLOSED_WEEKEND, "Sunday has not ended in Eastern time");
        // The first EST open is 14:30 UTC, not 13:30 UTC.
        _assertSession(1_793_629_799, Session.PRE, "2026-11-02 09:29:59 EST");
        _assertSession(1_793_629_800, Session.REGULAR, "2026-11-02 09:30:00 EST");
        // The Friday before still runs on EDT.
        _assertSession(1_793_367_000, Session.REGULAR, "2026-10-30 09:30:00 EDT");
        _assertSession(1_793_390_400, Session.POST, "2026-10-30 16:00:00 EDT");
        _assertNextOpen(1_793_462_400, 1_793_629_800, "Sat 2026-10-31 -> Mon 09:30 EST");
        _assertLastClose(1_793_462_400, 1_793_390_400, "Sat 2026-10-31 -> Fri 16:00 EDT");
    }

    /// @dev 2027 springs forward at 2027-03-14 07:00:00 UTC.
    function test_Dst2027_SpringForward() public view {
        _assertSession(1_805_007_599, Session.CLOSED_WEEKEND, "01:59:59 EST, before the jump");
        _assertSession(1_805_007_600, Session.CLOSED_WEEKEND, "03:00:00 EDT, after the jump");
        _assertSession(1_805_083_200, Session.CLOSED_OVERNIGHT, "2027-03-15 00:00 EDT");
        _assertSession(1_805_117_400, Session.REGULAR, "2027-03-15 09:30:00 EDT");
        _assertSession(1_804_861_800, Session.REGULAR, "2027-03-12 09:30:00 EST");
    }

    /// @dev 2027 falls back at 2027-11-07 06:00:00 UTC.
    function test_Dst2027_FallBack() public view {
        _assertSession(1_825_567_199, Session.CLOSED_WEEKEND, "01:59:59 EDT, first pass");
        _assertSession(1_825_567_200, Session.CLOSED_WEEKEND, "01:00:00 EST, second pass");
        _assertSession(1_825_646_400, Session.CLOSED_WEEKEND, "2027-11-07 23:00 EST, still Sunday");
        _assertSession(1_825_684_200, Session.REGULAR, "2027-11-08 09:30:00 EST");
        _assertSession(1_825_421_400, Session.REGULAR, "2027-11-05 09:30:00 EDT");
    }

    // --------------------------------------------------------------------------------------------
    // nextOpen
    // --------------------------------------------------------------------------------------------

    function test_NextOpen_FromMidSession() public view {
        // Wed 2026-06-10 12:00 ET -> Thu 2026-06-11 09:30 ET. The session already running does not
        // count: `nextOpen` is always strictly in the future.
        _assertNextOpen(1_781_107_200, 1_781_184_600, "mid-session rolls to tomorrow");
    }

    function test_NextOpen_FromTheOpeningSecond() public view {
        // Wed 2026-06-10 09:30:00 ET -> Thu 2026-06-11 09:30 ET.
        _assertNextOpen(1_781_098_200, 1_781_184_600, "the opening bell is not its own next open");
    }

    function test_NextOpen_FromFridayEvening() public view {
        // Fri 2026-06-12 21:00 ET -> Mon 2026-06-15 09:30 ET.
        _assertNextOpen(1_781_312_400, 1_781_530_200, "Friday night skips the weekend");
    }

    function test_NextOpen_FromSaturday() public view {
        // Sat 2026-06-13 12:00 ET -> Mon 2026-06-15 09:30 ET.
        _assertNextOpen(1_781_366_400, 1_781_530_200, "Saturday lands on Monday 09:30 ET");
    }

    function test_NextOpen_FromSunday() public view {
        // Sun 2026-06-14 12:00 ET -> Mon 2026-06-15 09:30 ET.
        _assertNextOpen(1_781_452_800, 1_781_530_200, "Sunday lands on Monday 09:30 ET");
    }

    function test_NextOpen_FromAHoliday() public view {
        // Mon 2026-09-07 12:00 ET, Labor Day -> Tue 2026-09-08 09:30 ET.
        _assertNextOpen(1_788_796_800, 1_788_874_200, "Labor Day lands on Tuesday 09:30 ET");
        // Fri 2027-12-24 12:00 ET, observed Christmas -> Mon 2027-12-27 09:30 ET.
        _assertNextOpen(1_829_667_600, 1_829_917_800, "observed Christmas lands on Monday 09:30 ET");
    }

    function test_NextOpen_FromTheEveningBeforeAHoliday() public view {
        // Fri 2026-09-04 21:00 ET, the Friday before Labor Day -> Tue 2026-09-08 09:30 ET.
        _assertNextOpen(1_788_570_000, 1_788_874_200, "Friday before a Monday holiday skips to Tuesday");
        // Fri 2027-01-15 21:00 ET, the Friday before MLK Jr. Day -> Tue 2027-01-19 09:30 ET.
        _assertNextOpen(1_800_064_800, 1_800_369_000, "Friday before MLK Jr. Day skips to Tuesday");
        // Thu 2026-07-02 21:00 ET, before the observed Independence Day -> Mon 2026-07-06 09:30 ET.
        _assertNextOpen(1_783_040_400, 1_783_344_600, "Thursday before a Friday holiday skips to Monday");
        // Thu 2026-12-31 21:00 ET, before New Year's Day 2027 -> Mon 2027-01-04 09:30 ET.
        _assertNextOpen(1_798_768_800, 1_799_073_000, "the turn of the year skips to Monday");
        // Thu 2027-12-23 21:00 ET, before observed Christmas -> Mon 2027-12-27 09:30 ET.
        _assertNextOpen(1_829_613_600, 1_829_917_800, "the Thursday before observed Christmas");
    }

    // --------------------------------------------------------------------------------------------
    // lastClose
    // --------------------------------------------------------------------------------------------

    function test_LastClose_FromMidSession() public view {
        // Wed 2026-06-10 12:00 ET -> Tue 2026-06-09 16:00 ET. A running session has not closed yet.
        _assertLastClose(1_781_107_200, 1_781_035_200, "mid-session reports yesterday's close");
    }

    function test_LastClose_AtTheClosingSecond() public view {
        // Wed 2026-06-10 16:00:00 ET is itself the close.
        _assertLastClose(1_781_121_600, 1_781_121_600, "16:00:00 ET is the close");
        _assertLastClose(1_781_121_599, 1_781_035_200, "15:59:59 ET is still yesterday's close");
    }

    function test_LastClose_FromFridayEvening() public view {
        // Fri 2026-06-12 21:00 ET -> Fri 2026-06-12 16:00 ET.
        _assertLastClose(1_781_312_400, 1_781_294_400, "Friday night reports Friday's close");
    }

    function test_LastClose_FromSaturdayAndSunday() public view {
        _assertLastClose(1_781_366_400, 1_781_294_400, "Saturday reports Friday's close");
        _assertLastClose(1_781_452_800, 1_781_294_400, "Sunday reports Friday's close");
    }

    function test_LastClose_FromAHoliday() public view {
        // Mon 2026-09-07 Labor Day -> Fri 2026-09-04 16:00 ET.
        _assertLastClose(1_788_796_800, 1_788_552_000, "Labor Day reports Friday's close");
        // Fri 2027-12-24 observed Christmas -> Thu 2027-12-23 16:00 ET.
        _assertLastClose(1_829_667_600, 1_829_595_600, "observed Christmas reports Thursday's close");
    }

    function test_LastClose_SkipsBackOverAnEarlyClose() public view {
        // Mon 2026-11-30 09:29:59 ET -> Fri 2026-11-27 13:00 ET, the half day.
        _assertLastClose(1_796_048_999, 1_795_802_400, "the previous close was a 13:00 ET half day");
    }

    // --------------------------------------------------------------------------------------------
    // closedFor
    // --------------------------------------------------------------------------------------------

    function test_ClosedFor_IsZeroWhileTheRegularSessionRuns() public view {
        assertEq(calendar.closedFor(1_781_098_200), 0, "at the bell");
        assertEq(calendar.closedFor(1_781_107_200), 0, "mid-session");
        assertEq(calendar.closedFor(1_781_121_599), 0, "one second before the close");
        assertEq(calendar.closedFor(1_795_802_399), 0, "one second before a 13:00 ET half-day close");
    }

    function test_ClosedFor_AcrossAFullWeekend() public view {
        // Mon 2026-06-15 09:29:59 ET, one second before the bell, measured from Fri 16:00 ET.
        assertEq(calendar.closedFor(1_781_530_199), WEEKEND_GAP - 1, "65.5 hours less one second");
        // Sat 2026-06-13 12:00 ET is 20 hours past Friday's close.
        assertEq(calendar.closedFor(1_781_366_400), 20 hours, "Saturday noon");
    }

    function test_ClosedFor_AcrossALongWeekend() public view {
        // Tue 2026-09-08 09:29:59 ET, one second before the bell after Labor Day.
        uint256 longWeekend = calendar.closedFor(1_788_874_199);
        assertEq(longWeekend, LONG_WEEKEND_GAP - 1, "89.5 hours less one second");
        assertGt(longWeekend, WEEKEND_GAP, "a long weekend is longer than a plain weekend");
        // Mon 2027-12-27 09:29:59 ET after the observed-Christmas Friday closure.
        assertEq(calendar.closedFor(1_829_917_799), LONG_WEEKEND_GAP - 1, "observed Christmas weekend");
    }

    function test_ClosedFor_MeasuresFromTheHalfDayClose() public view {
        // Mon 2026-11-30 09:29:59 ET. Friday closed at 13:00 ET, so the gap is three hours longer.
        assertEq(calendar.closedFor(1_796_048_999), WEEKEND_GAP + 3 hours - 1, "68.5 hours less one second");
    }

    // --------------------------------------------------------------------------------------------
    // session()
    // --------------------------------------------------------------------------------------------

    function test_SessionUsesBlockTimestamp() public {
        vm.warp(1_781_107_200); // Wed 2026-06-10 12:00 ET
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "regular");
        vm.warp(1_781_366_400); // Sat 2026-06-13 12:00 ET
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_WEEKEND), "weekend");
        vm.warp(1_788_796_800); // Mon 2026-09-07 12:00 ET, Labor Day
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_HOLIDAY), "holiday");
    }

    // --------------------------------------------------------------------------------------------
    // interface conformance
    // --------------------------------------------------------------------------------------------

    /// @notice Every consumer reaches the calendar through `ITradingCalendar`, so exercise the whole
    ///         surface across that type rather than the concrete contract.
    function test_ReadsThroughTheInterface() public {
        ITradingCalendar api = ITradingCalendar(address(calendar));

        // Wed 2026-06-10 12:00 ET, mid-session.
        (Session current, uint64 open, uint64 close) = api.sessionAt(1_781_107_200);
        assertEq(uint256(current), uint256(Session.REGULAR), "session");
        assertEq(open, 1_781_184_600, "next open");
        assertEq(close, 1_781_035_200, "last close");
        assertTrue(api.isOpen(1_781_107_200), "isOpen");
        assertEq(api.closedFor(1_781_107_200), 0, "closedFor");
        assertEq(api.nextOpen(1_781_107_200), open, "nextOpen");

        vm.warp(1_781_107_200);
        assertEq(uint256(api.session()), uint256(Session.REGULAR), "session()");
    }

    // --------------------------------------------------------------------------------------------
    // differential table
    // --------------------------------------------------------------------------------------------

    /// @notice Twenty-six independently derived (timestamp, session) pairs spread over both years.
    function test_DifferentialSessionTable() public view {
        _assertSession(1_767_366_000, Session.REGULAR, "2026-01-02 10:00:00 Fri EST");
        _assertSession(1_771_320_600, Session.PRE, "2026-02-17 04:30:00 Tue EST");
        _assertSession(1_773_099_900, Session.POST, "2026-03-09 19:45:00 Mon EDT");
        _assertSession(1_775_159_940, Session.REGULAR, "2026-04-02 15:59:00 Thu EDT");
        _assertSession(1_775_482_200, Session.REGULAR, "2026-04-06 09:30:00 Mon EDT");
        _assertSession(1_779_548_400, Session.CLOSED_WEEKEND, "2026-05-23 11:00:00 Sat EDT");
        _assertSession(1_781_876_700, Session.CLOSED_HOLIDAY, "2026-06-19 09:45:00 Fri EDT Juneteenth");
        _assertSession(1_783_384_200, Session.CLOSED_OVERNIGHT, "2026-07-06 20:30:00 Mon EDT");
        _assertSession(1_786_690_800, Session.CLOSED_OVERNIGHT, "2026-08-14 03:00:00 Fri EDT");
        // The exact instant called out in the brief. 1788545055 is 2026-09-04 18:04:15 UTC, which in
        // EDT is Friday 14:04:15 ET, so the regular session is still running. The instant the brief
        // describes in words, Friday 16:04:15 ET just after the close, is 1788552255 and is POST.
        _assertSession(1_788_545_055, Session.REGULAR, "2026-09-04 14:04:15 Fri EDT");
        _assertSession(1_788_552_255, Session.POST, "2026-09-04 16:04:15 Fri EDT");
        _assertSession(1_788_734_394, Session.CLOSED_WEEKEND, "2026-09-06 18:39:54 Sun EDT");
        _assertSession(1_791_837_000, Session.POST, "2026-10-12 16:30:00 Mon EDT");
        _assertSession(1_795_806_000, Session.POST, "2026-11-27 14:00:00 Fri EST half day");
        _assertSession(1_798_120_800, Session.PRE, "2026-12-24 09:00:00 Thu EST half day");
        _assertSession(1_798_210_800, Session.CLOSED_HOLIDAY, "2026-12-25 10:00:00 Fri EST Christmas");
        _assertSession(1_799_073_000, Session.REGULAR, "2027-01-04 09:30:00 Mon EST");
        _assertSession(1_802_624_400, Session.CLOSED_WEEKEND, "2027-02-14 12:00:00 Sun EST");
        _assertSession(1_806_073_200, Session.CLOSED_HOLIDAY, "2027-03-26 11:00:00 Fri EDT Good Friday");
        _assertSession(1_811_764_800, Session.CLOSED_HOLIDAY, "2027-05-31 08:00:00 Mon EDT Memorial Day");
        _assertSession(1_814_554_800, Session.REGULAR, "2027-07-02 15:00:00 Fri EDT");
        _assertSession(1_818_806_399, Session.POST, "2027-08-20 19:59:59 Fri EDT");
        _assertSession(1_820_224_800, Session.CLOSED_HOLIDAY, "2027-09-06 06:00:00 Mon EDT Labor Day");
        _assertSession(1_827_259_200, Session.POST, "2027-11-26 15:00:00 Fri EST half day");
        _assertSession(1_829_667_600, Session.CLOSED_HOLIDAY, "2027-12-24 12:00:00 Fri EST Christmas");
        // 2027-12-31 is a Friday but not a holiday: New Year's Day 2028 falls on a Saturday and the
        // exchange does not pull the observance back across a year end.
        _assertSession(1_830_276_000, Session.REGULAR, "2027-12-31 13:00:00 Fri EST");
    }

    /// @notice Walks the calendar open by open from the start of 2026 to the end of 2027 and folds
    ///         every (open, close) pair into a rolling keccak digest.
    /// @dev    The expected digest was produced offline from the IANA `America/New_York` zone and
    ///         the published NYSE calendar with the identical folding rule, so a single equality
    ///         pins all 502 trading days, both DST transitions in each year, every holiday and every
    ///         half day to the exact second. Any one wrong value changes the digest.
    function test_EveryTradingDayIn2026And2027() public view {
        bytes32 digest;
        uint256 tradingDays;

        uint64 open = calendar.nextOpen(YEAR_2026_START);
        while (open != 0 && open < YEAR_2028_START) {
            // 21:30 ET the same day is past every close, full or half; `closedFor` measures back to
            // it and, unlike `sessionAt`, needs no forward scan - which matters on the very last
            // seeded day, where there is deliberately no next open to find.
            uint256 evening = uint256(open) + 12 hours;
            // casting to 'uint64' is safe because the close is the same day as `open`
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 close = uint64(evening - calendar.closedFor(evening));

            assertTrue(calendar.isOpen(open), "an open second is a regular session");
            assertFalse(calendar.isOpen(uint256(open) - 1), "the second before an open is shut");
            assertTrue(calendar.isOpen(uint256(close) - 1), "the second before a close is open");
            assertFalse(calendar.isOpen(close), "a close second is no longer open");

            digest = keccak256(abi.encodePacked(digest, open, close));
            ++tradingDays;
            open = calendar.nextOpen(open);
        }

        assertEq(open, 0, "the walk ends at the seeded horizon, not at an unseeded 2028 session");
        assertEq(tradingDays, 502, "2026 and 2027 hold 502 NYSE trading days");
        assertEq(digest, TRADING_DAY_DIGEST, "every open and close matches the reference calendar");
    }

    /// @notice Past the last seeded day the calendar reports a permanent closure rather than
    ///         silently promoting unseeded holidays and half days back into full trading sessions.
    /// @dev    The defect this pins is specific: a bare two-bit flag table reads an unseeded day as
    ///         `FLAG_NORMAL`, so 2028-11-24 - NYSE's 13:00 ET close after Thanksgiving - would have
    ///         read as REGULAR at 13:30 ET, half an hour after the real closing bell, with the OPEN
    ///         liquidation threshold and a zero gap haircut applied to a dead tape.
    function test_HorizonFailsClosed() public view {
        // 2027-12-31 15:00 ET, the last seeded regular session.
        _assertSession(1_830_283_200, Session.REGULAR, "the last seeded session still trades");
        assertTrue(calendar.isOpen(1_830_283_200), "and is open");

        // 2028-11-24 13:30 ET: NYSE's 13:00 close after Thanksgiving, thirty minutes after the real
        // closing bell, on a day no seeded flag describes.
        uint256 unseededHalfDay = 1_858_703_400;
        assertFalse(calendar.isOpen(unseededHalfDay), "an unseeded half day is never open");
        _assertSession(unseededHalfDay, Session.CLOSED_HOLIDAY, "it reads as a closure, not a session");

        // Every hour of the first unseeded week reports a closure and no next open. The sweep
        // starts at midday UTC because 2028-01-01 00:00 UTC is still 2027-12-31 in New York.
        for (uint256 t = YEAR_2028_START + 12 hours; t < YEAR_2028_START + 7 days; t += 1 hours) {
            (Session session, uint64 nextOpen,) = calendar.sessionAt(t);
            assertEq(uint256(session), uint256(Session.CLOSED_HOLIDAY), "past the horizon the market is shut");
            assertFalse(calendar.isOpen(t), "and never open");
            assertEq(nextOpen, 0, "with no opening bell the calendar is willing to promise");
        }

        // Days before the seeded range are treated the same way.
        assertFalse(calendar.isOpen(YEAR_2026_START - 3 days), "unseeded days before the range are shut too");
    }

    // --------------------------------------------------------------------------------------------
    // fuzz
    // --------------------------------------------------------------------------------------------

    function testFuzz_CalendarInvariants(uint256 timestamp) public {
        // The last seeded regular open is 2027-12-31 09:30 ET; from that instant onward there is no
        // further open inside the horizon and `nextOpen` answers zero by design, which
        // `test_HorizonFailsClosed` covers separately.
        timestamp = bound(timestamp, YEAR_2026_START, LAST_SEEDED_OPEN - 1);

        try calendar.sessionAt(timestamp) returns (Session session, uint64 nextOpen, uint64 lastClose) {
            assertGt(uint256(nextOpen), timestamp, "nextOpen is strictly in the future");
            assertLe(uint256(lastClose), timestamp, "lastClose is at or before now");
            assertLt(uint256(lastClose), uint256(nextOpen), "the last close precedes the next open");

            bool open = calendar.isOpen(timestamp);
            assertEq(open, session == Session.REGULAR, "isOpen agrees with the session");

            uint256 elapsed = calendar.closedFor(timestamp);
            if (open) {
                assertEq(elapsed, 0, "an open market has been closed for zero seconds");
            } else {
                assertEq(elapsed, timestamp - uint256(lastClose), "closed time measures from the last close");
            }

            assertEq(calendar.nextOpen(timestamp), nextOpen, "the standalone getter agrees");

            // The next open must itself be a regular session, and the market must be shut one
            // second earlier.
            assertTrue(calendar.isOpen(uint256(nextOpen)), "the next open opens a regular session");
            assertFalse(calendar.isOpen(uint256(nextOpen) - 1), "one second earlier is still shut");

            // The last close must be the first second of a non-regular stretch.
            assertFalse(calendar.isOpen(uint256(lastClose)), "the close itself is not open");
            assertTrue(calendar.isOpen(uint256(lastClose) - 1), "one second earlier was open");
        } catch {
            fail();
        }
    }

    // --------------------------------------------------------------------------------------------
    // gas
    // --------------------------------------------------------------------------------------------

    /// @notice `sessionAt` sits on the hot path of every borrow and every liquidation, so its cost
    ///         is a guarded budget rather than a curiosity. The figures below include the external
    ///         call and the cold storage access on the first probe.
    function test_GasSessionAt() public view {
        uint256[4] memory probes = [
            uint256(1_781_107_200), // mid-session Wednesday
            1_781_452_800, // Sunday, scans across a weekend
            1_788_796_800, // Labor Day, scans across a long weekend
            1_798_768_800 // the Thursday before New Year's Day 2027, the longest real scan
        ];
        for (uint256 i; i < probes.length; ++i) {
            uint256 before = gasleft();
            calendar.sessionAt(probes[i]);
            uint256 used = before - gasleft();
            console2.log("sessionAt gas (call included)", probes[i], used);
            assertLt(used, 20_000, "sessionAt must stay inside its oracle-read budget");
        }
    }
}

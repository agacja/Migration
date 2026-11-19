// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../TwapOracle.t.sol";

contract Verify26_1 is TwapOracleTest {
    uint256 constant BASE = 1_700_000_000;
    address internal ADMIN = makeAddr("engineAdmin");
    AlbPriceOracle internal sma;

    function _day(uint256 d) internal pure returns (uint256) { return BASE + d * 1 days; }

    function _setup() internal {
        _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);
        vm.prank(owner);
        sma = new AlbPriceOracle(owner, ITwapSource(address(source)));
        for (uint256 i = 1; i <= 20; ++i) {
            vm.warp(_day(i));
            sma.poke();
        }
        assertTrue(sma.isHealthy(), "warm at day 20");
        assertEq(sma.distinctDays(), 20);
    }

    function test_fiveDaySuspension() public {
        _setup();
        vm.prank(ADMIN); engine.suspendRoute(address(alb));

        assertEq(source.lastUpdate(), 0, "suspended route reports age 0");
        assertFalse(sma.isHealthy(), "unhealthy at once");
        vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
        sma.safeSpotPrice();
        for (uint256 d = 21; d <= 24; ++d) {
            vm.warp(_day(d));
            vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
            sma.poke();
            assertFalse(sma.isHealthy());
        }

        vm.warp(_day(25));
        vm.prank(owner); engine.unsuspendRoute(address(alb));
        assertFalse(sma.isHealthy(), "no sample yet: lastSampleAt is 5d old > 3d");
        assertTrue(sma.poke());
        emit log_named_uint("distinctDays after day-25 poke", sma.distinctDays());
        emit log_named_uint("count after day-25 poke", sma.count());
        assertEq(sma.distinctDays(), 1, "long gap purges, then records one new sample");
        assertFalse(sma.isHealthy(), "still NotWarm");
        vm.expectRevert(AlbPriceOracle.NotWarm.selector);
        sma.sma20();

        for (uint256 d = 26; d <= 43; ++d) {
            vm.warp(_day(d));
            assertTrue(sma.poke());
            assertFalse(sma.isHealthy(), "not yet");
        }
        vm.warp(_day(44));
        assertTrue(sma.poke());
        assertTrue(sma.isHealthy(), "healthy again on day 44");
    }

    function test_threeDaySuspensionNoDecay() public {
        _setup();
        vm.prank(ADMIN); engine.suspendRoute(address(alb));
        vm.warp(_day(23));
        vm.prank(owner); engine.unsuspendRoute(address(alb));
        assertFalse(sma.isHealthy(), "lastSampleAt 3d old: > MAX_BUFFER_STALENESS + DAY? 3d > 3d is false");
        assertTrue(sma.poke());
        assertEq(sma.distinctDays(), 20);
        assertTrue(sma.isHealthy(), "healthy right after the catch-up poke");
    }

    function test_twentyDaySuspensionPurges() public {
        _setup();
        vm.prank(ADMIN); engine.suspendRoute(address(alb));
        vm.warp(_day(40));
        vm.prank(owner); engine.unsuspendRoute(address(alb));
        assertTrue(sma.poke());
        assertEq(sma.distinctDays(), 1, "purged then one real sample");
        for (uint256 d = 41; d <= 58; ++d) { vm.warp(_day(d)); sma.poke(); assertFalse(sma.isHealthy()); }
        vm.warp(_day(59)); sma.poke();
        assertTrue(sma.isHealthy(), "healthy on day 59 = 40 + 19");
    }
}

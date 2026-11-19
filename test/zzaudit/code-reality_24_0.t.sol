// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TwapOracleTest} from "../TwapOracle.t.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";

contract CodeReality24_0 is TwapOracleTest {
    address internal ADMIN = makeAddr("engineAdmin24_0");

    function test_adminCannotLiftOwnerSuspension() public {
        _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);

        vm.prank(owner); engine.suspendRoute(address(alb));
        assertTrue(engine.routeSuspended(address(alb)), "owner suspended");
        (, bool okS) = engine.tryPriceOf(address(alb));
        assertFalse(okS, "fail closed while suspended");
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        engine.lastObservationAt(address(alb));
        assertEq(source.lastUpdate(), 0, "AlbTwapSource.lastUpdate fails closed");

        vm.prank(ADMIN);
        vm.expectRevert();
        engine.unsuspendRoute(address(alb));
        assertTrue(engine.routeSuspended(address(alb)));
        vm.prank(owner); engine.unsuspendRoute(address(alb));

        assertFalse(engine.routeSuspended(address(alb)), "owner restored service");
        (uint256 p, bool ok) = engine.tryPriceOf(address(alb));
        assertTrue(ok && p > 0, "consumers live after owner restoration");
        assertGt(source.consult(), 0);
        assertGt(source.lastUpdate(), 0);
    }
}

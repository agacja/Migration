// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TwapOracleTest} from "../TwapOracle.t.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {MockV3Pool} from "../MocksV3.sol";

contract Verify25_1 is TwapOracleTest {
    address internal ADMIN = makeAddr("engineAdmin");

    function test_setRouteRestoresService() public {
        MockV3Pool old = _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);
        assertGt(engine.priceOf(address(alb)), 0);

        vm.prank(ADMIN); engine.suspendRoute(address(alb));
        assertTrue(engine.routeSuspended(address(alb)));

        MockV3Pool fresh = new MockV3Pool(address(alb), address(usdc), old.twapTick(), 1e20, 100);
        vm.prank(owner);
        engine.setRoute(address(alb), address(fresh), address(0), address(0));

        assertFalse(engine.routeSuspended(address(alb)));
        (uint256 price, bool ok) = engine.tryPriceOf(address(alb));
        assertTrue(ok);
        assertGt(price, 0);
        assertGt(engine.lastObservationAt(address(alb)), 0);
        assertGt(source.lastUpdate(), 0);
    }
}

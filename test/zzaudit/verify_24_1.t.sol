// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TwapOracleTest} from "../TwapOracle.t.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../../src/oracle/AlbTwapSource.sol";

contract Verify24_1 is TwapOracleTest {
    address internal ADMIN = makeAddr("engineAdmin");

    function test_lowLevelAdminCallCannotResumeOwnerSuspension() public {
        _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);

        vm.prank(owner); engine.suspendRoute(address(alb));
        (, bool okSuspended) = engine.tryPriceOf(address(alb));
        assertFalse(okSuspended, "suspended: consumers fail closed");
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        source.consult();

        vm.prank(ADMIN);
        (bool sent,) = address(engine).call(abi.encodeCall(engine.unsuspendRoute, (address(alb))));
        emit log_named_string("Admin unsuspendRoute", sent ? "SUCCEEDED (Admin-rule violation)" : "reverted (Owner-gated)");
        assertFalse(sent, "admin must not lift an owner suspension");

        (uint256 p, bool okAfter) = engine.tryPriceOf(address(alb));
        assertFalse(okAfter);
        assertEq(p, 0);
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        source.consult();
    }

    function test_adminCannotResumeOwnerSuspension() public {
        _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);
        vm.prank(owner); engine.suspendRoute(address(alb));

        vm.prank(ADMIN);
        vm.expectRevert();
        engine.unsuspendRoute(address(alb));
        assertTrue(engine.routeSuspended(address(alb)), "still suspended");

        vm.prank(owner); engine.unsuspendRoute(address(alb));
        assertGt(engine.priceOf(address(alb)), 0);
    }
}

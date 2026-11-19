// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";

contract CodeReality22_0 is BaseTest {
    uint256 constant T0 = 365 days * 55;

    function _loc() internal returns (LoC loc) {
        loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
    }

    function test_repayZero_dustRegime_forfeitsEverything() public {
        LoC loc = _loc();
        vm.prank(bob); loc.draw(1e8, bob);
        assertEq(alb.balanceOf(carol), 0);
        assertEq(alb.allowance(carol, address(loc)), 0);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.repay(0);
            assertEq(loc.lastAccrual(), uint64(T0 + 2 * i));
        }
        assertEq(loc.drawnAmount(), 1e8, "95 wei of interest forfeited");

        LoC loc2 = _loc();
        vm.warp(T0);
        vm.prank(bob); loc2.draw(1e8, bob);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc2.pokeInterest();
        }

        assertEq(loc2.drawnAmount(), 1e8 + 75, "poke path keeps most dust");
    }

    function test_repayZero_realPrincipal_forfeitBoundedBelowOneWeiPerSettlement() public {
        LoC a = _loc();
        vm.warp(T0);
        vm.prank(bob); a.draw(1e12, bob);
        LoC b = _loc();
        vm.prank(bob); b.draw(1e12, bob);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            a.repay(0);
        }
        vm.warp(T0 + 600);
        b.pokeInterest();

        assertEq(b.drawnAmount(), 1e12 + 951_293);
        assertEq(a.drawnAmount(), 1e12 + 951_000);
        uint256 forfeited = b.drawnAmount() - a.drawnAmount();
        assertLt(forfeited, 300, "forfeit < 1 wei per settlement");
    }
}

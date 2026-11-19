// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";

contract Verify22_1 is BaseTest {
    uint256 constant T0 = 365 days * 55;

    function test_repayZeroIsPermissionlessAndForfeitsDust() public {
        LoC loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob); loc.draw(1e8, bob);
        assertEq(alb.balanceOf(carol), 0);
        assertEq(alb.allowance(carol, address(loc)), 0);

        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.repay(0);
            assertEq(loc.lastAccrual(), uint64(T0 + 2 * i), "clock force-advanced");
        }

        assertEq(loc.drawnAmount(), 1e8, "all dust interest forfeited");
        assertEq(loc.unmintedInterest(), 0);
    }

    function test_pokeSpamDoesNotForfeitDust() public {
        LoC loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob); loc.draw(1e8, bob);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.pokeInterest();
        }
        uint256 ideal = (uint256(1e8) * 500 * 600) / (365 days * 10_000);
        uint256 got = loc.drawnAmount() - 1e8;
        assertGt(got, 0, "poke spam still accrues the dust period (non-forcing)");
        assertLe(got, ideal);
        assertGe(got + 300, ideal, "poke floors lose < 1 wei per realised settlement");
    }

    function test_repayZeroSpamOnRealPrincipalLosesUnderOneWeiPerSettlement() public {
        LoC loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob); loc.draw(1_000_000 ether, bob);
        uint256 n = 300;
        for (uint256 i = 1; i <= n; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.repay(0);
        }
        uint256 ideal = (uint256(1_000_000 ether) * 500 * (2 * n)) / (365 days * 10_000);
        uint256 got = loc.drawnAmount() - 1_000_000 ether;
        assertGe(got + n, ideal, "at most 1 wei lost per settlement");
    }
}

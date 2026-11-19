// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";

contract Impact22_2 is BaseTest {
    uint256 constant T0 = 1_800_000_000;

    function test_strangerRepayZeroForcesSettlement_dustRegime() public {
        vm.warp(T0);
        LoC loc = _createLoC(bob, 1e18, 1e18, 1e18, 500);
        vm.prank(bob);
        loc.draw(1e8, bob);

        assertEq(alb.balanceOf(carol), 0);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.repay(0);
        }
        vm.warp(T0 + 600);
        loc.pokeInterest();

        assertEq(loc.drawnAmount(), 1e8, "forfeited");

        vm.warp(T0 + 600);
        LoC loc2 = _createLoC(bob, 1e18, 1e18, 1e18, 500);
        vm.prank(bob);
        loc2.draw(1e8, bob);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 600 + 2 * i);
            vm.prank(carol);
            loc2.pokeInterest();
        }
        assertEq(loc2.drawnAmount(), 1e8 + 75, "poke spam settles each 8s at 1 wei: 75 of 95 wei survive");
    }

    function test_strangerRepayZeroOnLargePrincipal_subWeiPerSettlement() public {
        vm.warp(T0);
        LoC loc = _createLoC(bob, 10_000_000 ether, 10_000_000 ether, 10_000_000 ether, 500);
        vm.prank(bob);
        loc.draw(1_000_000 ether, bob);
        for (uint256 i = 1; i <= 300; i++) {
            vm.warp(T0 + 2 * i);
            vm.prank(carol);
            loc.repay(0);
        }

        uint256 exact = uint256(1_000_000 ether) * 500 * 600 / (365 days * 10_000);
        uint256 got = loc.drawnAmount() - 1_000_000 ether;

        assertLe(exact > got ? exact - got : 0, 300, "forfeit bounded by 1 wei/settlement");
        emit log_named_uint("exact", exact);
        emit log_named_uint("got", got);
    }
}

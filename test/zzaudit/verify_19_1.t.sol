// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";
import {LoCFactory} from "../../src/loc/LoCFactory.sol";

contract Verify19_1 is BaseTest {
    address internal ADMIN = makeAddr("locAdmin");

    function _setup() internal returns (LoC a, LoC b) {
        a = _createLoC(bob,   100_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        b = _createLoC(alice, 100_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(alice); b.draw(100 ether, alice);
        factory.setAggregateIssuanceCap(factory.totalIssued() + 3_000_000 ether);
        uint256 role = factory.ROLE_ADMIN();
        factory.grantRoles(ADMIN, role);
    }

    function _cycle(LoC a, uint256 n) internal {
        vm.startPrank(bob);
        alb.approve(address(a), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            a.draw(1_000_000 ether, bob);
            a.repay(1_000_000 ether);
            _skip(7 days);
        }
        vm.stopPrank();
    }

    function test_A_reproduce_grossBudgetExhaustedAtZeroDebt() public {
        (LoC a, LoC b) = _setup();
        uint256 supplyBefore = alb.totalSupply();
        _cycle(a, 3);
        assertEq(a.drawnAmount(), 0, "bob holds no debt");
        assertEq(factory.totalIssued(), factory.aggregateIssuanceCap(), "budget exhausted");

        assertEq(alb.totalSupply(), supplyBefore, "burns freed MAX_SUPPLY headroom; cap did not");

        b.pokeInterest();
        assertGt(b.unmintedInterest(), 0, "alice's interest parked");
        vm.prank(alice); vm.expectRevert(LoC.InterestUnpaid.selector); b.draw(1 ether, alice);
    }

    function test_B_adminPauseThenOwnerRaise_unlocksAlice() public {
        (LoC a, LoC b) = _setup();
        _cycle(a, 3);

        vm.prank(ADMIN); factory.setLoCDrawsPaused(address(a), true);
        factory.setAggregateIssuanceCap(factory.aggregateIssuanceCap() + 1_000_000 ether);

        vm.prank(bob); vm.expectRevert(LoC.DrawsArePaused.selector); a.draw(1 ether, bob);

        b.pokeInterest();
        assertEq(b.unmintedInterest(), 0, "alice's interest delivered");
        vm.prank(alice); b.draw(1 ether, alice);
        assertGt(b.drawnAmount(), 100 ether);
    }

    function test_C_ownerNarrowThenRaise_unlocksAlice() public {
        (LoC a, LoC b) = _setup();
        _cycle(a, 3);
        factory.setLoCLimits(address(a), 100_000_000 ether, 0, 0);
        factory.setAggregateIssuanceCap(factory.aggregateIssuanceCap() + 1_000_000 ether);
        vm.prank(bob); vm.expectRevert(LoC.MaxDailyExceeded.selector); a.draw(1 ether, bob);
        b.pokeInterest();
        assertEq(b.unmintedInterest(), 0);
        vm.prank(alice); b.draw(1 ether, alice);
    }

    function test_D_legitRevolvingUseExhaustsOwnBudget() public {
        LoC a = _createLoC(bob, 100_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        factory.setAggregateIssuanceCap(3_000_000 ether);
        _cycle(a, 3);
        vm.prank(bob); vm.expectRevert(LoCFactory.AggregateCapExceeded.selector); a.draw(1 ether, bob);
    }
}

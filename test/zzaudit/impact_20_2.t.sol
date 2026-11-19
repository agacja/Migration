// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {StakingContract} from "../../src/staking/StakingContract.sol";

contract Impact20_2 is BaseTest {
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        govALB.grantRoles(ADMIN, govALB.ROLE_ADMIN());
    }

    function test_esExemptionPreservesGovSharesAndNeedsNoRepair() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        assertEq(staking.sharesOf(alice), 200 ether);

        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        assertFalse(govALB.isHookExempt(alice));
        assertEq(govALB.stakedSharesOf(alice), 100 ether);
        assertEq(staking.sharesOf(alice), 100 ether, "govALB shares preserved");

        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);

        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 200 ether, "both contributions restored");
        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
        assertEq(staking.sharesOf(alice), 200 ether);
    }

    function test_neverOverCounts() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        _stakeGov(alice, 10 ether);
        vm.prank(ADMIN); govALB.setHookExempt(alice, true);
        govALB.setHookExempt(alice, false);
        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 210 ether);
        assertEq(esALB.stakedSharesOf(alice) + govALB.stakedSharesOf(alice), 210 ether);
    }
}

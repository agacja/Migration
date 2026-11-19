// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {StakingContract} from "../../src/staking/StakingContract.sol";

contract Verify20_1 is BaseTest {
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        govALB.grantRoles(ADMIN, govALB.ROLE_ADMIN());
    }

    function test_fixed_esExemptLeavesGovSharesAndRestoreIsExact() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        assertEq(staking.sharesOf(alice), 200 ether);

        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 100 ether, "govALB half must survive an esALB-only exemption");

        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);

        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 200 ether, "restore is exact, no extra sync needed");
    }

    function test_fixed_noOverCountAcrossInterleavedFlips() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        _stakeGov(alice, 10 ether);
        vm.prank(ADMIN); govALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 0);
        vm.expectRevert(StakingContract.HookExemptAccount.selector);
        staking.syncShares(alice);
        govALB.setHookExempt(alice, false);
        esALB.setHookExempt(alice, false);
        uint256 truth = esALB.stakedSharesOf(alice) + govALB.stakedSharesOf(alice);
        assertEq(truth, 210 ether);
        assertEq(staking.sharesOf(alice), truth, "exact, never over-counted");
    }

    function test_fixed_syncNeverCountsExemptToken() public {
        _stakeGov(alice, 100 ether);
        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        _stakeEs(alice, 50 ether);
        assertEq(staking.sharesOf(alice), 100 ether);
        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
    }
}

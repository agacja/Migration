// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {StakingContract} from "../../src/staking/StakingContract.sol";

contract Verify20_0 is BaseTest {
    address internal ADMIN = makeAddr("admin20");

    function setUp() public override {
        super.setUp();
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
    }

    function test_exemptionPreservesOtherTokenShares() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        assertEq(staking.sharesOf(alice), 200 ether);

        vm.prank(ADMIN);
        esALB.setHookExempt(alice, true);

        assertFalse(govALB.isHookExempt(alice));
        assertEq(govALB.stakedSharesOf(alice), 100 ether);
        assertEq(staking.sharesOf(alice), 100 ether, "govALB shares preserved");

        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);

        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 200 ether, "both contributions restored");
        assertEq(esALB.stakedSharesOf(alice) + govALB.stakedSharesOf(alice), 200 ether);

        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
        assertEq(staking.sharesOf(alice), 200 ether);
    }

    function test_noOverCount() public {
        govALB.grantRoles(ADMIN, govALB.ROLE_ADMIN());
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        vm.prank(ADMIN);
        govALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 100 ether);
        _stakeEs(alice, 50 ether);
        assertEq(staking.sharesOf(alice), 150 ether);
        govALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 250 ether);
        uint256 truth = esALB.stakedSharesOf(alice) + govALB.stakedSharesOf(alice);
        assertEq(truth, 250 ether);
        assertLe(staking.sharesOf(alice), truth, "never over-counted");
        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
        assertEq(staking.sharesOf(alice), 250 ether);
    }
}

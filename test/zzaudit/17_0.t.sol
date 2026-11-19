// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Distributor} from "../../src/farm/Distributor.sol";
import {MockHookToken} from "../Distributor.t.sol";

contract Audit17_0 is BaseTest {
    Distributor internal farm;
    address internal ADMIN = makeAddr("farmAdmin");

    function setUp() public override {
        super.setUp();
        farm = new Distributor(DAO, makeAddr("fees"));
        uint256 role = farm.ROLE_ADMIN();
        vm.prank(DAO);
        farm.grantRoles(ADMIN, role);
    }

    /// @dev Pool creation is Admin-level now, so the guarded property changed shape:
    /// an Admin CAN pre-register a planned hook token as a DEPOSIT stake, but the
    /// preemption is CURABLE — the Owner clears the (zero-staked) mark and the hook
    /// pool proceeds. No Admin action permanently forecloses a token's hook future.
    function test_adminDepositPreemptionOfHookPoolIsCurable() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        vm.prank(ADMIN);
        farm.addPool(address(hook), Distributor.PoolKind.DEPOSIT); // the preemption
        vm.prank(DAO);
        vm.expectRevert(Distributor.TokenIsDepositStake.selector);
        farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        vm.prank(DAO);
        farm.clearDepositRegistration(address(hook)); // nothing staked: curable
        vm.prank(DAO);
        farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        assertEq(farm.poolLength(), 2);
    }

    function test_unboundedPoolsDoNotDegradeIntermediaryFlagging() public {
        vm.startPrank(DAO);
        for (uint256 i; i < 300;) {
            farm.addPool(address(uint160(0x1000 + i)), Distributor.PoolKind.DEPOSIT);
            unchecked { ++i; }
        }
        vm.stopPrank();
        assertEq(farm.poolLength(), 300);
        uint256 gasBefore = gasleft();
        vm.prank(DAO);
        farm.setIntermediary(address(0xBEEF), true);
        assertLt(gasBefore - gasleft(), 200_000, "flagging must not scale with pool count");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {MockERC20} from "../Mocks.sol";
import {Distributor} from "../../src/farm/Distributor.sol";

contract Verify16_1 is BaseTest {
    Distributor internal farm;
    MockERC20 internal lp;
    address internal FEES = makeAddr("fees");

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        farm = new Distributor(DAO, FEES);
        lp = new MockERC20("LP", "LP", 18);
    }

    function test_addStreamRejectsCodelessToken() public {
        address ghost = makeAddr("ghost-token");
        vm.prank(DAO);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        vm.prank(DAO);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.addStream(pid, ghost, Distributor.StreamKind.MINT, address(0), address(0), 0);
    }
}

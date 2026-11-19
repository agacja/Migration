// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";

contract CodeReality23_0 is BaseTest {
    function test_startUnstakeGas() public {
        _stakeEs(alice, 100e18);
        vm.startPrank(alice);
        uint256 g0 = gasleft();
        esALB.startUnstake(10e18);
        uint256 used1 = g0 - gasleft();
        g0 = gasleft();
        esALB.startUnstake(10e18);
        uint256 used2 = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("startUnstake #1 call gas (pre-refund)", used1);
        emit log_named_uint("startUnstake #2 call gas (pre-refund)", used2);
        emit log_named_uint("refund cap #1 (used/5, call-level)", used1 / 5);
        emit log_named_uint("refund cap #2 (used/5, call-level)", used2 / 5);
    }
}

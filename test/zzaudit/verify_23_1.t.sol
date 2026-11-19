// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {EscrowedToken} from "../../src/token/EscrowedToken.sol";

contract Verify23_1 is BaseTest {
    function test_custodyFlagUsesNoPersistentToggleAndClosesAfterVestingMoves() public {
        _stakeEs(alice, 1000 ether);

        vm.record();
        vm.prank(alice);
        uint256 g0 = gasleft();
        esALB.startUnstake(100 ether);
        uint256 used = g0 - gasleft();
        (, bytes32[] memory writes) = vm.accesses(address(esALB));

        bool found;
        for (uint256 i = 0; i < writes.length; i++) {
            uint256 n;
            for (uint256 j = 0; j < writes.length; j++) if (writes[j] == writes[i]) n++;
            if (n >= 2 && vm.load(address(esALB), writes[i]) == bytes32(0)) {
                found = true;
                emit log_named_bytes32("custodyOpen slot", writes[i]);
            }
        }
        assertFalse(found, "custody flag must not toggle persistent storage");
        emit log_named_uint("startUnstake gas (incl. toggle)", used);

        esALB.setWhitelisted(alice, true);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotWhitelisted.selector);
        esALB.transfer(address(esALB), 1 ether);

        vm.prank(alice);
        esALB.cancelUnstake(0);
        assertEq(staking.sharesOf(alice), 1000 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotWhitelisted.selector);
        esALB.transfer(address(esALB), 1 ether);
    }
}

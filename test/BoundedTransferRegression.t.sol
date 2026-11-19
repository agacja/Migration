// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {MockERC20} from "./Mocks.sol";

contract HeavyTransferToken is MockERC20 {
    constructor() MockERC20("Heavy", "HVY", 18) {}

    function transfer(address to, uint256 a) public override returns (bool) {
        uint256 g = gasleft();
        while (g - gasleft() < 100_000) {}
        return super.transfer(to, a);
    }
}

contract BoundedTransferRegression is BaseTest {
    function _bank(MockERC20 t) internal {
        staking.registerStream(address(t), 0);
        _stakeEs(alice, 1_000 ether);
        t.mint(address(this), 100 ether);
        t.approve(address(staking), 100 ether);
        staking.notifyReward(address(t), 100 ether);
        _skip(7 days);
    }

    function test_outerGasCannotStarveTheStipendIntoAGlobalFuse() public {
        HeavyTransferToken heavy = new HeavyTransferToken();
        _bank(heavy);
        bytes memory op = abi.encodeCall(esALB.startUnstake, (10 ether));
        uint256 reverted;
        uint256 paid;
        for (uint256 g = 100_000; g <= 900_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok,) = address(esALB).call{gas: g}(op);
            if (ok) {
                assertFalse(staking.autoClaimDisabled(address(heavy)), "starved stipend fused the token");
                assertGt(heavy.balanceOf(alice), 0, "op succeeded without paying");
                ++paid;
            } else {
                ++reverted;
            }
            vm.revertToState(snap);
        }
        assertGt(reverted, 0, "low gas exercised");
        assertGt(paid, 0, "high gas exercised");
    }

    function test_emptyReturnFromCodelessTokenDefers() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        _bank(t);
        vm.etch(address(t), "");

        vm.prank(alice);
        esALB.startUnstake(10 ether);
        assertTrue(staking.autoClaimDisabled(address(t)), "deferred, not paid");
        assertGt(staking.pendingReward(alice, address(t)), 0, "reward still owed");
    }

    function test_standardTokenStillAutoClaims() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        _bank(t);
        vm.prank(alice);
        esALB.startUnstake(10 ether);
        assertFalse(staking.autoClaimDisabled(address(t)));
        assertEq(staking.pendingReward(alice, address(t)), 0);
        assertApproxEqAbs(t.balanceOf(alice), 100 ether, 1e6, "full week paid");
    }
}

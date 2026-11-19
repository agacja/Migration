// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {MockERC20} from "./Mocks.sol";

contract StakingWindowRegression is BaseTest {
    function _albStream()
        internal
        view
        returns (uint64 windowEnd, uint64 lastUpdate, uint128 ratePerSec)
    {
        (, , uint64 we, uint64 lu, , , uint128 rate, ) = staking.streams(address(alb));
        return (we, lu, rate);
    }

    function test_bookingNearWindowEndIsNotCompressed() public {
        _stakeEs(alice, 1_000_000 ether);

        _mintALB(address(this), 2_000_000 ether);
        alb.approve(address(staking), type(uint256).max);
        staking.setNotifier(address(this), true);
        staking.notifyReward(address(alb), 1_000_000 ether);

        (uint64 windowEnd,,) = _albStream();
        uint64 window = staking.defaultSmoothingWindow();

        vm.warp(uint256(windowEnd) - 1);
        staking.notifyReward(address(alb), 1_000_000 ether);

        (uint64 newEnd,, uint128 rate) = _albStream();

        uint256 minSpread = (uint256(window) * staking.MIN_SPREAD_BPS()) / 10_000;
        assertGe(
            uint256(newEnd) - block.timestamp,
            minSpread,
            "window must be extended to honour the minimum spread"
        );

        assertLt(uint256(rate), 1_000_000 ether / 1000, "rate must not collapse to the whole pool per second");
    }

    function test_dustNotificationCannotStretchWindow() public {
        _stakeEs(alice, 1_000_000 ether);
        _mintALB(address(this), 1_000_000 ether);
        alb.approve(address(staking), type(uint256).max);
        staking.setNotifier(address(this), true);
        staking.notifyReward(address(alb), 900_000 ether);

        (uint64 endAfterFirst,,) = _albStream();

        _skip(1 days);
        staking.notifyReward(address(alb), 1);
        (uint64 endAfterDust,,) = _albStream();
        assertEq(endAfterDust, endAfterFirst, "mid-window booking must not push the window out");

        uint64 window = staking.defaultSmoothingWindow();
        vm.warp(uint256(endAfterFirst) - 1);
        staking.notifyReward(address(alb), 1);
        (uint64 endLate,,) = _albStream();
        assertLt(
            uint256(endLate),
            block.timestamp + uint256(window),
            "window must never be restarted at full length by a dust notification"
        );
    }

    function test_notifyRewardBooksAmountReceivedNotRequested() public {
        FeeToken fee = new FeeToken();
        staking.registerStream(address(fee), 7 days);
        staking.setNotifier(address(this), true);
        _stakeEs(alice, 1000 ether);

        fee.mint(address(this), 1000 ether);
        fee.approve(address(staking), type(uint256).max);
        staking.notifyReward(address(fee), 1000 ether);

        assertEq(
            staking.trackedBalance(address(fee)),
            fee.balanceOf(address(staking)),
            "tracked balance must equal what the contract actually holds"
        );
    }
}

contract FeeToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 10;
        super.transferFrom(from, to, amount - fee);
        super.transferFrom(from, address(0xdead), fee);
        return true;
    }
}

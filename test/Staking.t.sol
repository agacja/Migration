// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {LoC} from "../src/loc/LoC.sol";
import {MockERC20} from "./Mocks.sol";

contract StakingTest is BaseTest {
    MockERC20 internal partner;

    function setUp() public override {
        super.setUp();
        partner = new MockERC20("Partner", "PTR", 18);
        staking.registerStream(address(partner), 0);
    }

    function _claim(address user, address token) internal returns (uint256) {
        address[] memory toks = new address[](1);
        toks[0] = token;
        uint256 before = MockERC20(token).balanceOf(user);
        vm.prank(user);
        staking.claim(toks);
        return MockERC20(token).balanceOf(user) - before;
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(staking), amount);
        staking.notifyReward(token, amount);
    }

    function test_esAndGovSharesAreOneToOne() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(bob, 100 ether);
        assertEq(staking.sharesOf(alice), staking.sharesOf(bob), "no govALB multiplier");
        assertEq(staking.totalShares(), 200 ether);
    }

    function test_govAndEsEarnIdentically() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(bob, 100 ether);
        _notify(address(partner), 1000 ether);
        _skip(7 days);
        assertEq(_claim(alice, address(partner)), _claim(bob, address(partner)));
    }

    function test_rewardsSplitProRata() public {
        _stakeEs(alice, 300 ether);
        _stakeEs(bob, 100 ether);
        _notify(address(partner), 400 ether);
        _skip(7 days);

        uint256 a = _claim(alice, address(partner));
        uint256 b = _claim(bob, address(partner));
        assertApproxEqRel(a, 300 ether, 1e12);
        assertApproxEqRel(b, 100 ether, 1e12);
    }

    function test_smoothingSpreadsOverWindow() public {
        _stakeEs(alice, 100 ether);
        _notify(address(partner), 700 ether);

        _skip(1 days);
        uint256 day1 = staking.pendingReward(alice, address(partner));
        assertApproxEqRel(day1, 100 ether, 1e15, "1/7 after one day");

        _skip(6 days);
        assertApproxEqRel(staking.pendingReward(alice, address(partner)), 700 ether, 1e12);
    }

    function test_solvencyAcrossManyOperations() public {
        _stakeEs(alice, 100 ether);
        _stakeEs(bob, 50 ether);
        _notify(address(partner), 300 ether);
        _skip(3 days);
        _stakeEs(carol, 200 ether);
        _notify(address(partner), 100 ether);
        _skip(5 days);

        uint256 total = staking.pendingReward(alice, address(partner))
            + staking.pendingReward(bob, address(partner))
            + staking.pendingReward(carol, address(partner));
        assertLe(total, partner.balanceOf(address(staking)), "insolvent stream");
    }

    function test_allThreeCanFullyClaim() public {
        _stakeEs(alice, 100 ether);
        _stakeEs(bob, 50 ether);
        _notify(address(partner), 300 ether);
        _skip(10 days);
        _claim(alice, address(partner));
        _claim(bob, address(partner));
        assertLe(partner.balanceOf(address(staking)), 1e6, "dust only");
    }

    function test_lateDepositorEarnsNothingRetroactively() public {
        _stakeEs(alice, 100 ether);
        _notify(address(partner), 700 ether);
        _skip(7 days);

        _stakeEs(bob, 100 ether);
        assertEq(staking.pendingReward(bob, address(partner)), 0);
        assertApproxEqRel(staking.pendingReward(alice, address(partner)), 700 ether, 1e12);
    }

    function test_withdrawnUserKeepsBankedRewards() public {
        _stakeEs(alice, 100 ether);
        _notify(address(partner), 700 ether);
        _skip(7 days);

        uint256 owed = staking.pendingReward(alice, address(partner));
        uint256 walletBefore = partner.balanceOf(alice);
        vm.prank(alice);
        esALB.startUnstake(100 ether);
        assertGe(partner.balanceOf(alice) - walletBefore, owed - 1e12, "paid to wallet");
        assertEq(staking.pendingReward(alice, address(partner)), 0, "nothing left banked");
    }

    function test_rewardsWhileZeroSharesAreRecycled() public {
        _notify(address(partner), 700 ether);
        _skip(3 days);

        _stakeEs(alice, 100 ether);
        _notify(address(partner), 1);
        _skip(30 days);

        uint256 claimable = staking.pendingReward(alice, address(partner));
        assertApproxEqRel(claimable, 700 ether, 1e15, "streamed-to-nobody must be recycled");
    }

    function test_notifyRewardIsGated() public {
        partner.mint(alice, 10 ether);
        vm.startPrank(alice);
        partner.approve(address(staking), 10 ether);
        vm.expectRevert(StakingContract.NotNotifier.selector);
        staking.notifyReward(address(partner), 10 ether);
        vm.stopPrank();
    }

    function test_zeroAmountNotifyReverts() public {
        vm.expectRevert(StakingContract.ZeroAmount.selector);
        staking.notifyReward(address(partner), 0);
    }

    function test_escrowTokensAreNotifiersForPenalties() public view {
        assertTrue(staking.isNotifier(address(esALB)));
        assertTrue(staking.isNotifier(address(govALB)));
    }

    function test_unstakePenaltyReachesStakers() public {
        _stakeEs(alice, 1000 ether);
        _stakeEs(bob, 1000 ether);

        vm.prank(alice);
        uint256 idx = esALB.startUnstake(1000 ether);
        _skip(30 days);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);

        _skip(14 days);
        uint256 bobGot = _claim(bob, address(alb));
        assertGt(bobGot, 0, "penalty must flow to remaining stakers");
    }

    function test_syncBooksDirectlyMintedInterest() public {
        _stakeEs(alice, 1_000_000 ether);
        LoC loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob);
        loc.draw(1_000_000 ether, bob);

        _skip(365 days);
        loc.pokeInterest();

        uint256 stranded = alb.balanceOf(address(staking)) - staking.trackedBalance(address(alb));
        assertGt(stranded, 0, "interest arrived unbooked");

        vm.prank(KEEPER);
        staking.sync(address(alb));
        assertEq(alb.balanceOf(address(staking)), staking.trackedBalance(address(alb)));

        _skip(14 days);
        assertGt(staking.pendingReward(alice, address(alb)), 0, "interest now distributable");
    }

    function test_syncIsGated() public {
        vm.expectRevert(StakingContract.NotNotifier.selector);
        vm.prank(alice);
        staking.sync(address(alb));
    }

    function test_syncNoopWhenNothingUnbooked() public {
        staking.sync(address(alb));
        assertEq(staking.trackedBalance(address(alb)), 0);
    }

    function test_rebasePulledIntoAlbStream() public {
        _stakeEs(alice, 1_000_000 ether);
        LoC loc = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 0);
        vm.prank(bob);
        loc.draw(1_000_000 ether, bob);
        assertGt(factory.pendingRebase(), 0);

        _skip(2 hours);
        _stakeEs(carol, 1 ether);
        assertEq(factory.pendingRebase(), 0, "rebase pulled");

        _skip(14 days);
        assertGt(staking.pendingReward(alice, address(alb)), 0);
    }

    function test_minRebasePullIntervalBounded() public {
        vm.expectRevert(StakingContract.BadInterval.selector);
        staking.setMinRebasePullInterval(8 days);
        staking.setMinRebasePullInterval(7 days);
    }

    function test_streamWindowBounded() public {
        vm.expectRevert(StakingContract.BadWindow.selector);
        staking.setStreamWindow(address(partner), 31 days);
        vm.expectRevert(StakingContract.BadWindow.selector);
        staking.setStreamWindow(address(partner), 59 minutes);
    }

    function test_unknownStreamRejected() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        rogue.mint(address(this), 1 ether);
        rogue.approve(address(staking), 1 ether);
        vm.expectRevert(StakingContract.UnknownStream.selector);
        staking.notifyReward(address(rogue), 1 ether);
    }

    function test_hooksOnlyFromEscrowTokens() public {
        vm.expectRevert(StakingContract.NotEscrow.selector);
        vm.prank(alice);
        staking.notifyDeposit(alice, 1000 ether);
    }

    function test_directEthRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        assertFalse(ok, "must reject stray ETH");
    }

    function testFuzz_solvency(uint96 s1, uint96 s2, uint96 reward, uint32 dt) public {
        s1 = uint96(bound(s1, 1 ether, 1e24));
        s2 = uint96(bound(s2, 1 ether, 1e24));
        reward = uint96(bound(reward, 1 ether, 1e24));
        dt = uint32(bound(dt, 1, 30 days));

        _stakeEs(alice, s1);
        _stakeEs(bob, s2);
        _notify(address(partner), reward);
        _skip(dt);

        uint256 total = staking.pendingReward(alice, address(partner))
            + staking.pendingReward(bob, address(partner));
        assertLe(total, partner.balanceOf(address(staking)));
    }
}

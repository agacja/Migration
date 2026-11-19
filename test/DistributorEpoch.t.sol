// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {MockERC20} from "./Mocks.sol";

contract EpochFeeToken is MockERC20 {
    constructor() MockERC20("Taxed reward", "TAX", 6) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _burn(to, amount / 10);
        return ok;
    }
}

contract DistributorEpochTest is Test {
    uint256 internal constant T0 = 1_800_000_000;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal fees = makeAddr("fees");
    address internal admin = makeAddr("admin");
    Distributor internal farm;
    MockERC20 internal lp;
    MockERC20 internal reward;
    uint256 internal pid;
    uint256 internal idx;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
        lp = new MockERC20("LP", "LP", 18);
        reward = new MockERC20("Reward", "RWD", 18);
        farm.grantRoles(admin, farm.ROLE_ADMIN());
        pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        idx = farm.addStream(pid, address(reward), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        lp.mint(alice, 1_000 ether);
        lp.mint(bob, 1_000 ether);
        vm.prank(alice); lp.approve(address(farm), type(uint256).max);
        vm.prank(bob); lp.approve(address(farm), type(uint256).max);
        reward.approve(address(farm), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        reward.mint(address(this), amount);
        farm.fundStream(pid, idx, amount);
    }

    function _start(uint64 length, uint256 budget) internal {
        farm.setStreamEpochLength(pid, idx, length);
        _fund(budget);
        vm.prank(alice); farm.deposit(pid, 100 ether);
    }

    function _claim() internal {
        vm.prank(alice); farm.withdraw(pid, 0);
    }

    function _pending() internal view returns (uint256) {
        (,,, uint256[] memory amounts) = farm.pendingTokens(pid, alice);
        return amounts[idx];
    }

    function test_fixedPeriodUsesBudgetDividedByLengthAndStopsAtEnd() public {
        _start(100, 1_000 ether);
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        assertEq(s.ratePerSec, 10 ether);
        assertEq(s.emissionEnd, T0 + 100);
        (uint64 length, uint64 start, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(length, 100);
        assertEq(start, T0);
        assertEq(budget, 1_000 ether);
        vm.warp(T0 + 40);
        assertEq(_pending(), 400 ether);
        _claim();
        assertEq(reward.balanceOf(alice), 400 ether);
        vm.warp(T0 + 1_000);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
        assertEq(farm.streamInfo(pid, idx).reserve, 0);
        (,,, uint256[] memory rates) = farm.poolRewardsPerSec(pid);
        assertEq(rates[idx], 0);
    }

    function test_midPeriodTopupsQueueWithoutChangingRateOrEnd() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 40);
        _fund(500 ether);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 10 ether);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 100);
        assertEq(farm.streamInfo(pid, idx).reserve, 1_100 ether);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 1_000 ether);
        vm.warp(T0 + 100);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
        assertEq(farm.streamInfo(pid, idx).reserve, 500 ether);
        vm.prank(bob); farm.startStreamEpoch(pid, idx);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 5 ether);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 200);
        vm.warp(T0 + 200);
        _claim();
        assertEq(reward.balanceOf(alice), 1_500 ether);
    }

    function test_cannotRestartOrReconfigureAnUnfinishedEpoch() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 99);
        vm.expectRevert(Distributor.EpochInProgress.selector);
        farm.startStreamEpoch(pid, idx);
        farm.setStreamEpochLength(pid, idx, 200);
        (uint64 len,,,) = farm.streamEpochs(pid, idx);
        assertEq(len, 100);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 100);
        (uint64 pendingLength,) = farm.streamEpochConfig(pid, idx);
        assertEq(pendingLength, 200);
        vm.expectRevert(Distributor.EpochRateIsDerived.selector);
        farm.setStreamRate(pid, idx, 1 ether);
        farm.setStreamActive(pid, idx, false);
        farm.setStreamEpochLength(pid, idx, 300);
        (len,,,) = farm.streamEpochs(pid, idx);
        assertEq(len, 100);
        (pendingLength,) = farm.streamEpochConfig(pid, idx);
        assertEq(pendingLength, 300);
    }

    function test_lateRolloverDoesNotPayForGapOrRebookEarnedRewards() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 50);
        _fund(500 ether);
        vm.warp(T0 + 1_000);
        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 500 ether, "earned but unclaimed funds excluded");
        assertEq(_pending(), 1_000 ether);
        vm.warp(T0 + 1_050);
        _claim();
        assertEq(reward.balanceOf(alice), 1_250 ether);
    }

    function test_fundingAtEndSettlesOldEpochAndStartsFullNewPeriod() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 50);
        _fund(200 ether);
        vm.warp(T0 + 100);
        _fund(300 ether);
        (uint64 length, uint64 start, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(length, 100);
        assertEq(start, T0 + 100);
        assertEq(budget, 500 ether);
        assertEq(_pending(), 1_000 ether);
        vm.warp(T0 + 200);
        _claim();
        assertEq(reward.balanceOf(alice), 1_500 ether);
    }

    function test_conversionFromLegacyRateSettlesBeforeSnapshot() public {
        farm.setStreamRate(pid, idx, 1 ether);
        _fund(1_000 ether);
        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.warp(T0 + 100);
        farm.setStreamEpochLength(pid, idx, 300);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 900 ether);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 3 ether);
        assertEq(_pending(), 100 ether);
        vm.warp(T0 + 400);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
    }

    function test_lengthCanChangeAfterEndWithoutRepricingPreviousRewards() public {
        _start(100, 1_000 ether);
        _fund(600 ether);
        vm.warp(T0 + 100);
        farm.setStreamEpochLength(pid, idx, 200);
        assertEq(_pending(), 1_000 ether);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 3 ether);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 300);
        vm.warp(T0 + 300);
        _claim();
        assertEq(reward.balanceOf(alice), 1_600 ether);
    }

    function test_pauseForfeitsElapsedRewardsWithoutExtendingEpoch() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 20);
        vm.prank(admin); farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 50);
        _fund(500 ether);
        vm.prank(admin);
        vm.expectRevert();
        farm.setStreamActive(pid, idx, true);
        farm.setStreamActive(pid, idx, true);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 100);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 10 ether);
        vm.warp(T0 + 100);
        _claim();
        assertEq(reward.balanceOf(alice), 700 ether);
        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 800 ether, "paused allocation plus queued topup");
    }

    function test_resumingAfterEndCannotEmitAcrossPause() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 20);
        farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 200);
        farm.setStreamActive(pid, idx, true);
        _claim();
        assertEq(reward.balanceOf(alice), 200 ether);
        farm.startStreamEpoch(pid, idx);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 8 ether);
        vm.warp(T0 + 300);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
    }

    function test_fundingPausedStreamWaitsUntilExplicitStart() public {
        farm.setStreamEpochLength(pid, idx, 100);
        farm.setStreamActive(pid, idx, false);
        _fund(1_000 ether);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 0);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.startStreamEpoch(pid, idx);
        vm.warp(T0 + 200);
        farm.setStreamActive(pid, idx, true);
        farm.startStreamEpoch(pid, idx);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 300);
    }

    function test_emptyPoolAllocationRemainsForNextPeriod() public {
        farm.setStreamEpochLength(pid, idx, 100);
        _fund(1_000 ether);
        vm.warp(T0 + 40);
        vm.prank(alice); farm.deposit(pid, 100 ether);
        assertEq(_pending(), 0);
        vm.warp(T0 + 100);
        _claim();
        assertEq(reward.balanceOf(alice), 600 ether);
        assertEq(farm.streamInfo(pid, idx).reserve, 400 ether);
        farm.startStreamEpoch(pid, idx);
        vm.warp(T0 + 200);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
    }

    function test_recoveryCannotTakeCommittedEpochOrAccruedRewards() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 40);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.recoverStreamReserve(pid, idx, bob, type(uint256).max);
        _fund(500 ether);
        farm.recoverStreamReserve(pid, idx, bob, type(uint256).max);
        assertEq(reward.balanceOf(bob), 500 ether, "only queued topup is recoverable");
        assertEq(farm.streamInfo(pid, idx).reserve, 600 ether);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 100);
        vm.warp(T0 + 100);
        _claim();
        assertEq(reward.balanceOf(alice), 1_000 ether);
    }

    function test_pausedRecoveryPreservesFutureCommittedRewards() public {
        _start(100, 1_000 ether);
        vm.warp(T0 + 20);
        farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 60);
        farm.recoverStreamReserve(pid, idx, bob, type(uint256).max);
        assertEq(reward.balanceOf(bob), 400 ether);
        farm.setStreamActive(pid, idx, true);
        vm.warp(T0 + 100);
        _claim();
        assertEq(reward.balanceOf(alice), 600 ether);
        assertEq(farm.streamInfo(pid, idx).reserve, 0);
    }

    function test_unclaimedBalanceAndOtherStreamsAreNotEpochBudget() public {
        _start(100, 1_000 ether);
        uint256 second = farm.addStream(pid, address(reward), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamEpochLength(pid, second, 200);
        reward.mint(address(this), 4_000 ether);
        farm.fundStream(pid, second, 2_000 ether);
        reward.transfer(address(farm), 2_000 ether);
        vm.warp(T0 + 50);
        _fund(500 ether);
        vm.warp(T0 + 100);
        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 500 ether);
        (,, uint256 otherBudget,) = farm.streamEpochs(pid, second);
        assertEq(otherBudget, 2_000 ether);
        vm.warp(T0 + 200);
        _claim();
        assertEq(reward.balanceOf(alice), 3_500 ether);
        assertEq(reward.balanceOf(address(farm)), 2_000 ether);
    }

    function test_rewardBudgetExcludesStakedPrincipalWhenTokensMatch() public {
        uint256 same = farm.addStream(pid, address(lp), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamEpochLength(pid, same, 100);
        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.prank(bob); farm.deposit(pid, 100 ether);
        lp.mint(address(this), 100 ether);
        lp.approve(address(farm), 100 ether);
        farm.fundStream(pid, same, 100 ether);
        (,, uint256 budget,) = farm.streamEpochs(pid, same);
        assertEq(budget, 100 ether);
        vm.warp(T0 + 100);
        vm.prank(alice); farm.withdraw(pid, 100 ether);
        vm.prank(bob); farm.withdraw(pid, 100 ether);
        assertEq(lp.balanceOf(alice), 1_050 ether);
        assertEq(lp.balanceOf(bob), 1_050 ether);
    }

    function test_netFundingAfterTransferTaxAndFeeDeterminesRate() public {
        EpochFeeToken taxed = new EpochFeeToken();
        uint256 taxedIdx = farm.addStream(pid, address(taxed), Distributor.StreamKind.BALANCE, address(0), address(0), 1_000);
        farm.setStreamEpochLength(pid, taxedIdx, 100);
        taxed.mint(address(this), 1_000e6);
        taxed.approve(address(farm), 1_000e6);
        farm.fundStream(pid, taxedIdx, 1_000e6);
        (,, uint256 budget,) = farm.streamEpochs(pid, taxedIdx);
        assertEq(budget, 810e6);
        assertEq(taxed.balanceOf(fees), 90e6);
        assertEq(farm.streamInfo(pid, taxedIdx).ratePerSec, 8_100_000);
        vm.prank(alice); farm.deposit(pid, 1);
        vm.warp(T0 + 100);
        _claim();
        assertEq(taxed.balanceOf(alice), 810e6);
    }

    function test_fractionalRateReleasesWholeBudgetRegardlessOfPokeFrequency() public {
        farm.setStreamEpochLength(pid, idx, 10);
        _fund(7);
        vm.prank(alice); farm.deposit(pid, 1);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 0, "fraction is below one base unit per second");
        for (uint256 i = 1; i <= 10; ++i) {
            vm.warp(T0 + i);
            assertEq(_pending() + reward.balanceOf(alice), 7 * i / 10);
            _claim();
        }
        vm.warp(T0 + 40);
        _claim();
        assertEq(reward.balanceOf(alice), 7);
        assertEq(farm.streamInfo(pid, idx).reserve, 0);
    }

    function test_configurationIsOwnerOnlyAndRejectsInvalidLengthsAndKinds() public {
        vm.prank(alice); vm.expectRevert(); farm.setStreamEpochLength(pid, idx, 100);
        vm.prank(admin); vm.expectRevert(); farm.setStreamEpochLength(pid, idx, 100);
        vm.expectRevert(Distributor.InvalidParams.selector); farm.setStreamEpochLength(pid, idx, 0);
        vm.expectRevert(Distributor.InvalidParams.selector); farm.setStreamEpochLength(pid, idx, 3650 days + 1);
        uint256 mint = farm.addStream(pid, address(reward), Distributor.StreamKind.MINT, address(0), address(0), 0);
        vm.expectRevert(Distributor.WrongStreamKind.selector); farm.setStreamEpochLength(pid, mint, 100);
        farm.setPullSource(true);
        uint256 pull = farm.addStream(pid, address(reward), Distributor.StreamKind.PULL, address(this), address(0), 0);
        farm.setPullTerms(pid, pull, 0, type(uint128).max, type(uint32).max);

        vm.expectRevert(Distributor.MintRightsExceeded.selector); farm.setStreamRate(pid, mint, 3);
        farm.scheduleMintRights(address(reward), 3);
        vm.warp(block.timestamp + farm.MINT_RIGHTS_DELAY());
        farm.applyMintRights(address(reward));
        farm.setStreamRate(pid, mint, 3);
        farm.setStreamRate(pid, pull, 4);
        assertEq(farm.streamInfo(pid, mint).ratePerSec, 3);
        assertEq(farm.streamInfo(pid, pull).ratePerSec, 4);

        farm.setStreamEpochLength(pid, pull, 100);
        vm.expectRevert(Distributor.EpochRateIsDerived.selector); farm.setStreamRate(pid, pull, 5);
        vm.expectRevert(Distributor.UnknownPool.selector); farm.setStreamEpochLength(100, 0, 100);
        vm.expectRevert(Distributor.UnknownStream.selector); farm.setStreamEpochLength(pid, 100, 100);
    }

    function test_emptyOrUnconfiguredEpochCannotStart() public {
        vm.expectRevert(Distributor.InvalidParams.selector); farm.startStreamEpoch(pid, idx);
        farm.setStreamEpochLength(pid, idx, 100);
        vm.expectRevert(Distributor.NothingToDo.selector); farm.startStreamEpoch(pid, idx);
    }

    function test_oversizedBudgetIsBoundedPerPeriodAndQueuesTheExcess() public {
        farm.setStreamEpochLength(pid, idx, 1);
        vm.prank(alice); farm.deposit(pid, 1);
        uint256 cap = type(uint128).max;
        uint256 amount = cap + 1;
        reward.mint(address(this), 2 * amount);
        farm.fundStream(pid, idx, amount);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, type(uint128).max);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, cap, "one period books at most uint128.max per second");
        farm.fundStream(pid, idx, amount);
        vm.warp(T0 + 1);
        assertEq(_pending(), cap, "first period accrues its budget exactly");
        farm.startStreamEpoch(pid, idx);
        (,, budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, cap);
        vm.warp(T0 + 2);
        assertEq(_pending(), 2 * cap, "second period accrues its budget exactly");
        farm.updatePool(pid);
        assertEq(farm.streamInfo(pid, idx).reserve, 2, "the excess stays queued");
    }

    function testFuzz_epochBudgetIsConservedAcrossTopupAndRollover(
        uint128 rawBudget, uint128 rawTopup, uint32 rawLength, uint32 rawElapsed
    ) public {
        uint256 budget = bound(uint256(rawBudget), 1, 1e30);
        uint256 topup = bound(uint256(rawTopup), 1, 1e30);
        uint64 length = uint64(bound(uint256(rawLength), 2, 30 days));
        uint256 elapsed = bound(uint256(rawElapsed), 1, length - 1);
        farm.setStreamEpochLength(pid, idx, length);
        _fund(budget);
        vm.prank(alice); farm.deposit(pid, 1);
        vm.warp(T0 + elapsed);
        _fund(topup);
        assertEq(_pending(), budget * elapsed / length);
        _claim();
        vm.warp(T0 + length);
        farm.startStreamEpoch(pid, idx);
        assertEq(_pending() + reward.balanceOf(alice), budget);
        (,, uint256 nextBudget,) = farm.streamEpochs(pid, idx);
        assertEq(nextBudget, topup);
        vm.warp(T0 + 2 * length + 30);
        _claim();
        assertEq(reward.balanceOf(alice), budget + topup);
        assertEq(farm.streamInfo(pid, idx).reserve, 0);
        assertEq(reward.balanceOf(address(farm)), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {LoC} from "../src/loc/LoC.sol";
import {LoCFactory} from "../src/loc/LoCFactory.sol";
import {ALBToken} from "../src/token/ALBToken.sol";

contract LoCTest is BaseTest {
    LoC internal loc;

    function setUp() public override {
        super.setUp();
        loc = _createLoC(alice, 10_000_000 ether, 100_000 ether, 500_000 ether, 500);
    }

    function test_drawRespectsDailyLimit() public {
        vm.prank(alice);
        loc.draw(100_000 ether, alice);
        vm.expectRevert(LoC.MaxDailyExceeded.selector);
        vm.prank(alice);
        loc.draw(1 ether, alice);
    }

    function test_dustDrawsCannotEvictWindow() public {
        vm.startPrank(alice);
        loc.draw(100_000 ether, alice);
        for (uint256 i; i < 200; ++i) {
            vm.expectRevert(LoC.MaxDailyExceeded.selector);
            loc.draw(1, alice);
        }
        vm.expectRevert(LoC.MaxDailyExceeded.selector);
        loc.draw(1 ether, alice);
        vm.stopPrank();
        assertEq(loc.dailyDrawn(), 100_000 ether);
    }

    function test_zeroDrawRejected() public {
        vm.expectRevert(LoC.ZeroAmount.selector);
        vm.prank(alice);
        loc.draw(0, alice);
    }

    function test_weeklyLimitEnforcedAcrossDays() public {
        vm.startPrank(alice);
        uint256 t = block.timestamp;
        for (uint256 i; i < 5; ++i) {
            loc.draw(100_000 ether, alice);
            t += 1 days;
            vm.warp(t);
        }
        assertEq(loc.weeklyDrawn(), 500_000 ether);
        vm.expectRevert(LoC.MaxWeeklyExceeded.selector);
        loc.draw(1 ether, alice);
        vm.stopPrank();
    }

    function test_windowRollsOffAfterSevenDays() public {
        vm.prank(alice);
        loc.draw(100_000 ether, alice);
        _skip(8 days);
        assertEq(loc.weeklyDrawn(), 0);
        vm.prank(alice);
        loc.draw(100_000 ether, alice);
    }

    function test_maxTotalEnforced() public {
        LoC small = _createLoC(bob, 1000 ether, 1000 ether, 1000 ether, 0);
        vm.prank(bob);
        small.draw(1000 ether, bob);
        vm.expectRevert(LoC.MaxTotalExceeded.selector);
        vm.prank(bob);
        small.draw(1, bob);
    }

    function test_onlyBeneficiaryDraws() public {
        vm.expectRevert(LoC.NotBeneficiary.selector);
        vm.prank(bob);
        loc.draw(1 ether, bob);
    }

    function test_anyoneCanRepayOverpayRejected() public {
        vm.prank(alice);
        loc.draw(1000 ether, bob);

        vm.startPrank(bob);
        alb.approve(address(loc), type(uint256).max);
        vm.expectRevert(LoC.Overpay.selector);
        loc.repay(2000 ether);
        loc.repay(1000 ether);
        vm.stopPrank();
        assertEq(loc.drawnAmount(), 0);
    }

    function test_repayBurnsSupply() public {
        vm.prank(alice);
        loc.draw(1000 ether, alice);
        uint256 supplyBefore = alb.totalSupply();
        vm.startPrank(alice);
        alb.approve(address(loc), 1000 ether);
        loc.repay(1000 ether);
        vm.stopPrank();
        assertEq(alb.totalSupply(), supplyBefore - 1000 ether);
    }

    function test_interestAccruesLinearlyToSink() public {
        LoC big = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob);
        big.draw(1_000_000 ether, bob);

        uint256 sinkBefore = alb.balanceOf(address(staking));
        _skip(365 days);
        big.pokeInterest();

        uint256 accrued = alb.balanceOf(address(staking)) - sinkBefore;
        assertApproxEqRel(accrued, 50_000 ether, 1e12);
        assertApproxEqRel(big.drawnAmount(), 1_050_000 ether, 1e12);
    }

    function test_pokeGriefingDoesNotForfeitInterest() public {
        LoC tiny = _createLoC(bob, 1_000_000 ether, 1_000_000 ether, 1_000_000 ether, 1);
        vm.prank(bob);
        tiny.draw(1000 ether, bob);

        uint256 sinkBefore = alb.balanceOf(address(staking));

        uint256 t = block.timestamp;
        for (uint256 i; i < 200; ++i) {
            t += 2;
            vm.warp(t);
            tiny.pokeInterest();
        }
        _skip(365 days);
        tiny.pokeInterest();

        uint256 accrued = alb.balanceOf(address(staking)) - sinkBefore;

        assertGt(accrued, 0.09 ether);
    }

    function test_interestMayExceedMaxTotalButDrawsThenRevert() public {
        LoC small = _createLoC(bob, 1000 ether, 1000 ether, 1000 ether, 5000);
        vm.prank(bob);
        small.draw(1000 ether, bob);
        _skip(365 days);
        small.pokeInterest();
        assertGt(small.drawnAmount(), 1000 ether, "interest capitalizes past maxTotal");

        vm.expectRevert(LoC.MaxTotalExceeded.selector);
        vm.prank(bob);
        small.draw(1, bob);
    }

    function test_interestOnZeroDebtIsZero() public {
        _skip(365 days);
        loc.pokeInterest();
        assertEq(loc.drawnAmount(), 0);
        assertEq(alb.totalSupply(), 0);
    }

    function test_repayStillAccruesInterest() public {
        LoC big = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob);
        big.draw(1_000_000 ether, bob);

        uint256 sinkBefore = alb.balanceOf(address(staking));
        _skip(365 days);

        vm.startPrank(bob);
        alb.approve(address(big), 1 ether);
        big.repay(1 ether);
        vm.stopPrank();

        uint256 accrued = alb.balanceOf(address(staking)) - sinkBefore;
        assertApproxEqRel(accrued, 50_000 ether, 1e12, "interest must accrue through repay()");
    }

    function test_repayWorksWhenInterestMintIsBlocked() public {
        LoC big = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob);
        big.draw(1_000_000 ether, bob);

        factory.setAggregateIssuanceCap(factory.totalIssued());
        _skip(30 days);

        vm.startPrank(bob);
        alb.approve(address(big), 500_000 ether);
        big.repay(500_000 ether);
        vm.stopPrank();

        uint256 interest = (uint256(1_000_000 ether) * 500 * 30 days) / (365 days * 10_000);
        assertEq(big.drawnAmount(), 1_000_000 ether + interest - 500_000 ether, "interest capitalised, then repaid");
        assertEq(big.unmintedInterest(), interest, "delivery to the sink is parked, not lost");

        factory.setLoCInterestRate(address(big), 0);
        assertEq(big.interestRateBps(), 0);

        factory.setAggregateIssuanceCap(type(uint256).max);
        uint256 sinkBefore = alb.balanceOf(big.interestSink());
        big.pokeInterest();
        assertEq(alb.balanceOf(big.interestSink()) - sinkBefore, interest, "flushed to the sink");
        assertEq(big.unmintedInterest(), 0);
    }

    function test_repayToZeroDuringBlockedMintStillOwesInterest() public {
        LoC big = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob);
        big.draw(1_000_000 ether, bob);
        factory.setAggregateIssuanceCap(factory.totalIssued());
        _skip(365 days);
        _mintALB(bob, 50_000 ether);
        vm.startPrank(bob);
        alb.approve(address(big), 1_050_000 ether);
        vm.expectRevert(LoC.Overpay.selector);
        big.repay(1_050_001 ether);
        big.repay(1_050_000 ether);
        vm.stopPrank();
        assertEq(big.drawnAmount(), 0, "fully repaid INCLUDING the blocked-mint interest");
    }

    function test_rateChangeIsNotRetroactive() public {
        LoC z = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 0);
        vm.prank(bob);
        z.draw(1_000_000 ether, bob);
        _skip(365 days);
        factory.setLoCInterestRate(address(z), 1_000);
        assertEq(z.drawnAmount(), 1_000_000 ether, "nothing charged for the 0% year");
        assertEq(z.lastAccrual(), block.timestamp, "clock settled at the switch");
        _skip(365 days);
        z.pokeInterest();
        assertEq(z.drawnAmount(), 1_100_000 ether, "10% for exactly one year, not two");
    }

    function test_redeemOptionSurvivesBlockedInterestMint() public {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option({amount: 100 ether, strikePrice: 0.5e8, expiry: 0, redeemed: false});
        LoC o = LoC(factory.createLoC(bob, address(staking), 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500, opts));
        vm.prank(bob);
        o.draw(1_000 ether, bob);
        factory.setAggregateIssuanceCap(factory.totalIssued());
        _skip(10 days);
        _warmOracle();

        vm.prank(bob);
        o.redeemOption(0);
        assertGt(o.unmintedInterest(), 0, "interest parked, redemption not bricked");
        assertLt(o.drawnAmount(), 1_000 ether + 2 ether, "debt written down by the grant");
    }

    function test_rebaseFormulaMatchesSpec() public {
        _stakeEs(alice, 30_000_000 ether);
        _mintALB(bob, 70_000_000 ether);
        assertEq(alb.totalSupply(), 100_000_000 ether);

        uint256 mintAmount = 10_000_000 ether;
        LoC big = _createLoC(carol, mintAmount, uint128(mintAmount), uint128(mintAmount), 0);
        vm.prank(carol);
        big.draw(mintAmount, carol);

        uint256 expected = (mintAmount * 3000) / 7000;
        assertApproxEqRel(factory.pendingRebase(), expected, 1e12);
    }

    function test_rebaseCappedAtFiftyPercent() public {
        _stakeEs(alice, 90_000_000 ether);
        _mintALB(bob, 10_000_000 ether);

        uint256 mintAmount = 1_000_000 ether;
        LoC big = _createLoC(carol, mintAmount, uint128(mintAmount), uint128(mintAmount), 0);
        vm.prank(carol);
        big.draw(mintAmount, carol);
        assertApproxEqRel(factory.pendingRebase(), mintAmount, 1e12);
    }

    function test_capCannotExceedMaxCap() public {
        vm.expectRevert(LoCFactory.InvalidParams.selector);
        factory.setPercentageCap(9999);
        factory.setPercentageCap(5000);
    }

    function test_noRebaseWhenNoCommittedSupply() public {
        vm.prank(alice);
        loc.draw(1000 ether, alice);
        assertEq(factory.pendingRebase(), 0);
    }

    function test_locClonesAreNotDirectMinters() public view {
        assertFalse(alb.isMinter(address(loc)), "clones must never hold mint rights");
        assertTrue(alb.isMinter(address(factory)), "factory is the canonical minter");
    }

    function test_onlyFactoryLoCsCanMint() public {
        vm.expectRevert(LoCFactory.NotLoC.selector);
        vm.prank(alice);
        factory.mintWithRebase(alice, 1 ether);

        vm.expectRevert(LoCFactory.NotLoC.selector);
        vm.prank(alice);
        factory.mintNoRebase(alice, 1 ether);
    }

    function test_pullRebaseOnlyByStaking() public {
        _stakeEs(alice, 1_000_000 ether);
        vm.prank(alice);
        loc.draw(1000 ether, alice);
        assertGt(factory.pendingRebase(), 0);

        vm.expectRevert(LoCFactory.NotStaking.selector);
        vm.prank(bob);
        factory.pullRebase();
    }

    function test_aggregateIssuanceTracked() public {
        vm.prank(alice);
        loc.draw(1000 ether, alice);
        assertEq(factory.totalIssued(), 1000 ether);
    }

    function test_aggregateCapEnforced() public {
        factory.setAggregateIssuanceCap(500 ether);
        vm.expectRevert(LoCFactory.AggregateCapExceeded.selector);
        vm.prank(alice);
        loc.draw(1000 ether, alice);
    }

    function _locWithOption(uint256 amount, uint256 strike, uint64 expiry) internal returns (LoC o) {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option({amount: amount, strikePrice: strike, expiry: expiry, redeemed: false});
        return LoC(
            factory.createLoC(bob, address(staking), 1_000_000 ether, 1_000_000 ether, 1_000_000 ether, 0, opts)
        );
    }

    function test_optionBelowStrikeReverts() public {
        LoC o = _locWithOption(1000 ether, 2e8, 0);
        _warmOracle();
        vm.expectRevert(LoC.BelowStrike.selector);
        vm.prank(bob);
        o.redeemOption(0);
    }

    function test_optionMintsWhenAboveStrikeAndDoesNotRebase() public {
        _stakeEs(alice, 1_000_000 ether);
        LoC o = _locWithOption(1000 ether, 1e8, 0);
        twap.setPrice(2e8);
        _warmOracle();

        uint256 rebaseBefore = factory.pendingRebase();
        vm.prank(bob);
        o.redeemOption(0);

        assertEq(alb.balanceOf(bob), 1000 ether);
        assertEq(factory.pendingRebase(), rebaseBefore, "option mints must not rebase");
    }

    function test_optionRetiresDebtFirst() public {
        LoC o = _locWithOption(1000 ether, 1e8, 0);
        twap.setPrice(2e8);
        _warmOracle();

        vm.prank(bob);
        o.draw(600 ether, bob);
        assertEq(o.drawnAmount(), 600 ether);

        vm.prank(bob);
        o.redeemOption(0);
        assertEq(o.drawnAmount(), 0, "debt retired first");

        assertEq(alb.balanceOf(bob), 1000 ether);
    }

    function test_optionCannotBeRedeemedTwice() public {
        LoC o = _locWithOption(1000 ether, 1e8, 0);
        twap.setPrice(2e8);
        _warmOracle();
        vm.startPrank(bob);
        o.redeemOption(0);
        vm.expectRevert(LoC.AlreadyRedeemed.selector);
        o.redeemOption(0);
        vm.stopPrank();
    }

    function test_expiredOptionReverts() public {
        twap.setPrice(2e8);
        _warmOracle();
        LoC o = _locWithOption(1000 ether, 1e8, uint64(vm.getBlockTimestamp() + 1 days));
        _skip(1 days + 1);
        twap.touch();
        vm.expectRevert(LoC.OptionExpired.selector);
        vm.prank(bob);
        o.redeemOption(0);
    }

    function test_optionBlockedWhenOracleUnhealthy() public {
        LoC o = _locWithOption(1000 ether, 1e8, 0);
        twap.setPrice(2e8);
        _warmOracle();

        _skip(10 days);
        vm.expectRevert();
        vm.prank(bob);
        o.redeemOption(0);
    }

    function test_optionsImmutableAfterDeploy() public view {
        assertEq(loc.optionsLength(), 0);
    }

    function testFuzz_drawNeverExceedsWindows(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, 100_000 ether));
        b = uint96(bound(b, 1, 100_000 ether));
        vm.startPrank(alice);
        loc.draw(a, alice);
        if (uint256(a) + b > 100_000 ether) {
            vm.expectRevert(LoC.MaxDailyExceeded.selector);
            loc.draw(b, alice);
        } else {
            loc.draw(b, alice);
            assertLe(loc.dailyDrawn(), 100_000 ether);
        }
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {EscrowedToken} from "../src/token/EscrowedToken.sol";
import {LoC} from "../src/loc/LoC.sol";

contract EscrowStakingAuditFixes is BaseTest {
    uint256 constant T0 = 1_800_000_000;
    address internal attacker = makeAddr("attacker");

    function _newStaking() internal returns (StakingContract s) {
        s = new StakingContract(address(this), IALB(address(alb)), address(esALB), address(govALB), address(weth));
        s.setNotifier(address(this), true);
    }

    function _enableConversion() internal {
        esALB.setConversionDestination(address(govALB), true);
        govALB.setConversionSource(address(esALB), true);
    }

    function test_syncSharesOnUnwiredReplacementReverts() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        StakingContract next = _newStaking();

        vm.prank(attacker);
        vm.expectRevert(StakingContract.EscrowNotWired.selector);
        next.syncShares(alice);
        assertEq(next.totalShares(), 0);

        esALB.setStaking(IStakingContract(address(next)));
        govALB.setStaking(IStakingContract(address(next)));
        next.syncShares(alice);
        assertEq(next.sharesOf(alice), 100 ether);
    }

    function test_splitReplacementCanBeRepairedBySetStakingAgain() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        StakingContract B = _newStaking();
        StakingContract C = _newStaking();

        esALB.setStaking(IStakingContract(address(B)));
        govALB.setStaking(IStakingContract(address(C)));

        _mintALB(address(this), 15 ether);
        alb.approve(address(B), 15 ether);
        B.notifyReward(address(alb), 15 ether);
        assertEq(B.migrationRewards(address(alb)), 15 ether);
        uint256 ownerBefore = alb.balanceOf(address(this));

        esALB.setStaking(IStakingContract(address(C)));
        assertTrue(B.deprecated());
        assertFalse(B.migrationPending());
        assertEq(B.migrationRewards(address(alb)), 0);
        assertEq(B.trackedBalance(address(alb)), 0);
        assertEq(alb.balanceOf(address(this)) - ownerBefore, 15 ether, "queued rewards back to the Owner");

        C.syncShares(alice);
        C.completeMigration();
        assertFalse(C.migrationPending());
        assertEq(C.sharesOf(alice), 100 ether);
    }

    function test_misconfiguredReplacementCanBeLeft() public {
        vm.warp(T0);
        StakingContract B = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), makeAddr("typo"), address(weth)
        );
        esALB.setStaking(IStakingContract(address(B)));
        assertTrue(B.migrationPending());

        StakingContract C = _newStaking();
        esALB.setStaking(IStakingContract(address(C)));
        govALB.setStaking(IStakingContract(address(C)));
        C.completeMigration();
        assertTrue(B.deprecated());
        assertFalse(B.migrationPending());
    }

    function test_conversionDuringWiringGapCountsOnce() public {
        vm.warp(T0);
        _enableConversion();
        _stakeEs(alice, 100 ether);
        _stakeEs(bob, 100 ether);
        StakingContract next = _newStaking();

        govALB.setStaking(IStakingContract(address(next)));

        vm.expectRevert(StakingContract.NothingToDo.selector);
        next.syncShares(alice);

        vm.prank(alice);
        esALB.convertTo(address(govALB), 100 ether);
        assertEq(next.sharesOf(alice), 100 ether, "counted once, via the govALB mint");

        esALB.setStaking(IStakingContract(address(next)));
        next.syncShares(bob);
        next.completeMigration();
        assertEq(next.sharesOf(alice), 100 ether);
        assertEq(next.totalShares(), 200 ether);

        _mintALB(address(this), 300 ether);
        alb.approve(address(next), 300 ether);
        next.notifyReward(address(alb), 300 ether);
        vm.warp(T0 + 8 days);
        assertApproxEqAbs(next.pendingReward(alice, address(alb)), 150 ether, 1e9);
        assertApproxEqAbs(next.pendingReward(bob, address(alb)), 150 ether, 1e9);
    }

    function test_exemptAccountCannotConvertIntoEarningPower() public {
        vm.warp(T0);
        _enableConversion();
        _stakeEs(alice, 100 ether);
        esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.ExemptConversion.selector);
        esALB.convertTo(address(govALB), 100 ether);

        govALB.setHookExempt(alice, true);
        vm.prank(alice);
        esALB.convertTo(address(govALB), 100 ether);
        assertEq(staking.sharesOf(alice), 0);
        assertEq(govALB.balanceOf(alice), 100 ether);
    }

    function test_customSinkInterestRebasesAndStakingSinkDoesNot() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        LoC custom = LoC(factory.createLoC(bob, carol, 1_000_000 ether, 100_000 ether, 500_000 ether, 1000, new LoC.Option[](0)));
        LoC standard = LoC(factory.createLoC(bob, address(0), 1_000_000 ether, 100_000 ether, 500_000 ether, 1000, new LoC.Option[](0)));
        assertEq(standard.interestSink(), address(staking));
        vm.startPrank(bob);
        custom.draw(100 ether, bob);
        standard.draw(100 ether, bob);
        vm.stopPrank();

        vm.warp(T0 + 365 days);
        uint256 r0 = factory.pendingRebase();
        standard.pokeInterest();
        assertGt(standard.totalInterestMinted(), 9 ether);
        assertEq(factory.pendingRebase(), r0, "staking-sink interest mints without a rebase");

        custom.pokeInterest();
        assertGt(custom.totalInterestMinted(), 9 ether);
        assertEq(alb.balanceOf(carol), custom.totalInterestMinted());
        assertGt(factory.pendingRebase(), r0, "custom-sink interest compensates escrow holders");
    }

    function test_defaultSinkFollowsStakingReplacementWithoutRebase() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        LoC standard = LoC(factory.createLoC(bob, address(0), 1_000_000 ether, 100_000 ether, 500_000 ether, 1000, new LoC.Option[](0)));
        vm.prank(bob);
        standard.draw(100 ether, bob);

        StakingContract next = _newStaking();
        esALB.setStaking(IStakingContract(address(next)));
        govALB.setStaking(IStakingContract(address(next)));
        next.syncShares(alice);
        next.completeMigration();
        next.setLoCFactory(ILoCFactoryRebase(address(factory)));
        factory.setStakingContract(address(next));
        assertEq(standard.interestSink(), address(next), "no per-LoC re-point needed");

        vm.warp(T0 + 365 days);
        uint256 r0 = factory.pendingRebase();
        uint256 oldBal = alb.balanceOf(address(staking));
        uint256 nextBal = alb.balanceOf(address(next));
        standard.pokeInterest();
        uint256 interest = standard.totalInterestMinted();
        assertGt(interest, 9 ether);
        assertEq(alb.balanceOf(address(next)) - nextBal, interest, "interest reaches the live instance");
        assertEq(alb.balanceOf(address(staking)), oldBal, "nothing to the retired instance");
        assertEq(factory.pendingRebase(), r0, "and no rebase on top");

        factory.setLoCInterestSink(address(standard), carol);
        assertEq(standard.interestSink(), carol);
        factory.setLoCInterestSink(address(standard), address(0));
        assertEq(standard.interestSink(), address(next));
    }

    function test_claimCannotPrefillUnwiredReplacementThroughRebasePull() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        LoC loc = LoC(factory.createLoC(bob, address(0), 1_000_000 ether, 100_000 ether, 500_000 ether, 1000, new LoC.Option[](0)));
        vm.prank(bob);
        loc.draw(100 ether, bob);
        uint256 pendingRebase = factory.pendingRebase();
        assertGt(pendingRebase, 0);

        StakingContract next = _newStaking();
        next.setLoCFactory(ILoCFactoryRebase(address(factory)));
        factory.setStakingContract(address(next));

        vm.warp(T0 + 2 hours);
        vm.prank(attacker);
        next.claim(new address[](0));
        assertEq(next.trackedBalance(address(alb)), 0, "nothing booked");
        assertEq(factory.pendingRebase(), pendingRebase, "rebase still in the factory");

        esALB.setStaking(IStakingContract(address(next)));
        govALB.setStaking(IStakingContract(address(next)));
        next.syncShares(alice);
        next.completeMigration();

        vm.warp(T0 + 4 hours);
        vm.prank(alice);
        next.claim(new address[](0));
        assertEq(factory.pendingRebase(), 0);
        assertEq(next.trackedBalance(address(alb)), pendingRebase);
    }

    function test_finalizeAndStartUnstakeKeepSharesExact() public {
        vm.warp(T0);
        _stakeEs(alice, 100 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(40 ether);
        assertEq(staking.sharesOf(alice), esALB.stakedSharesOf(alice));
        vm.warp(T0 + 400 days);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);
        assertEq(staking.sharesOf(alice), esALB.stakedSharesOf(alice));
        assertEq(staking.sharesOf(alice), 60 ether);
    }
}

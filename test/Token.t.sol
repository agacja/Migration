// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {EscrowedToken} from "../src/token/EscrowedToken.sol";
import {MockERC20} from "./Mocks.sol";

contract TokenTest is BaseTest {
    function test_maxSupplyMatchesSpec() public view {
        assertEq(alb.MAX_SUPPLY(), 1_051_000_000 ether);
    }

    function test_mintRevertsAboveCap() public {
        vm.prank(DAO);
        alb.addMinter(address(this));
        alb.mint(alice, alb.MAX_SUPPLY());
        vm.expectRevert(ALBToken.MaxSupplyExceeded.selector);
        alb.mint(alice, 1);
    }

    function test_burnFreesCapHeadroom() public {
        vm.prank(DAO);
        alb.addMinter(address(this));
        alb.mint(alice, alb.MAX_SUPPLY());
        vm.prank(alice);
        alb.burn(100 ether);
        alb.mint(bob, 100 ether);
        assertEq(alb.totalSupply(), alb.MAX_SUPPLY());
    }

    function test_onlyMinterCanMint() public {
        vm.expectRevert(ALBToken.NotMinter.selector);
        vm.prank(alice);
        alb.mint(alice, 1 ether);
    }

    function test_revokedMinterCannotMint() public {
        vm.prank(DAO);
        alb.addMinter(alice);
        vm.prank(alice);
        alb.mint(alice, 1 ether);
        vm.prank(DAO);
        alb.revokeMinter(alice);
        vm.expectRevert(ALBToken.NotMinter.selector);
        vm.prank(alice);
        alb.mint(alice, 1 ether);
    }

    function test_renounceOwnershipDisabled() public {
        vm.expectRevert(ALBToken.RenounceDisabled.selector);
        vm.prank(DAO);
        alb.renounceOwnership();
    }

    function test_recoveryGatedOnRecoveryAdmin() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(alb), 5 ether);

        vm.expectRevert(ALBToken.NotRecoveryAdmin.selector);
        vm.prank(DAO);
        alb.recoverERC20(address(stray), DAO, 5 ether);

        vm.prank(RECOVERY);
        alb.recoverERC20(address(stray), DAO, 5 ether);
        assertEq(stray.balanceOf(DAO), 5 ether);
    }

    function test_burnFromRespectsAllowance() public {
        _mintALB(alice, 10 ether);
        vm.expectRevert();
        vm.prank(bob);
        alb.burnFrom(alice, 10 ether);

        vm.prank(alice);
        alb.approve(bob, 10 ether);
        vm.prank(bob);
        alb.burnFrom(alice, 10 ether);
        assertEq(alb.balanceOf(alice), 0);
    }

    function test_startUnstakeDoesNotStakeTheEscrowContract() public {
        _stakeEs(alice, 1000 ether);
        assertEq(staking.totalShares(), 1000 ether);

        vm.prank(alice);
        esALB.startUnstake(400 ether);

        assertEq(staking.sharesOf(alice), 880 ether);
        assertEq(staking.sharesOf(address(esALB)), 0, "escrow contract must hold no shares");
        assertEq(staking.totalShares(), 880 ether);
    }

    function test_govUnstakeHasZeroEarningPower() public {
        _stakeGov(alice, 1000 ether);
        vm.prank(alice);
        govALB.startUnstake(1000 ether);
        assertEq(staking.sharesOf(alice), 0, "govALB earns 0% while unstaking");
        assertEq(staking.sharesOf(address(govALB)), 0);
        assertEq(staking.totalShares(), 0);
    }

    function test_cancelUnstakeRestoresShares() public {
        _stakeEs(alice, 1000 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(400 ether);
        assertEq(staking.sharesOf(alice), 880 ether);
        vm.prank(alice);
        esALB.cancelUnstake(idx);
        assertEq(staking.sharesOf(alice), 1000 ether);
        assertEq(staking.totalShares(), 1000 ether);
    }

    function test_partialShareSnapshottedAcrossParamChange() public {
        _stakeEs(alice, 1000 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(1000 ether);
        assertEq(staking.sharesOf(alice), 700 ether);

        esALB.setRedemptionParams(30 days, 60 days, 8500, 1000);

        _skip(60 days);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);
        assertEq(staking.sharesOf(alice), 0, "no phantom shares left behind");
        assertEq(staking.totalShares(), 0);
    }

    function test_redemptionCurveSnapshottedPerPosition() public {
        _stakeEs(alice, 1000 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(1000 ether);

        esALB.setRedemptionParams(30 days, 180 days, 8500, 7000);

        _skip(60 days);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);

        assertEq(alb.balanceOf(alice), 1000 ether);
    }

    function test_unstakePayoutCurve() public {
        _stakeEs(alice, 1000 ether);
        vm.prank(alice);
        uint256 i0 = esALB.startUnstake(1000 ether);
        _skip(30 days);
        vm.prank(alice);
        esALB.finalizeUnstake(i0);
        assertEq(alb.balanceOf(alice), 850 ether);

        _stakeEs(bob, 1000 ether);
        vm.prank(bob);
        uint256 i1 = esALB.startUnstake(1000 ether);
        _skip(45 days);
        vm.expectEmit(true, false, false, true, address(esALB));
        emit EscrowedToken.UnstakeFinalized(bob, i1, 925 ether, 75 ether);
        vm.prank(bob);
        esALB.finalizeUnstake(i1);
        assertGe(alb.balanceOf(bob), 925 ether, "at least the curve payout");
        assertApproxEqAbs(alb.balanceOf(bob), 925 ether + 150 ether, 1e13, "plus alice's redistributed penalty (accumulator dust)");
    }

    function test_finalizeBeforeMinDurationReverts() public {
        _stakeEs(alice, 100 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(100 ether);
        _skip(29 days);
        vm.expectRevert(EscrowedToken.TooEarly.selector);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);
    }

    function test_cannotFinalizeTwice() public {
        _stakeEs(alice, 100 ether);
        vm.prank(alice);
        uint256 idx = esALB.startUnstake(100 ether);
        _skip(60 days);
        vm.startPrank(alice);
        esALB.finalizeUnstake(idx);
        vm.expectRevert(EscrowedToken.InvalidIndex.selector);
        esALB.finalizeUnstake(idx);
        vm.stopPrank();
    }

    function test_instantRedeemBucketNoRollover() public {
        _stakeEs(alice, 1000 ether);
        _skip(48 hours);

        vm.prank(alice);
        esALB.instantRedeem(20 ether);
        assertEq(alb.balanceOf(alice), 20 ether);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.AmountExceedsAllowance.selector);
        esALB.instantRedeem(1 ether);

        _skip(8 days);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.AmountExceedsAllowance.selector);
        esALB.instantRedeem(40 ether);

        vm.prank(alice);
        esALB.instantRedeem(19.6 ether);
    }

    function test_govInstantRedeemRate() public {
        _stakeGov(alice, 1_000_000 ether);
        _skip(7 days);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.AmountExceedsAllowance.selector);
        govALB.instantRedeem(14_361 ether);

        vm.prank(alice);
        govALB.instantRedeem(14_360 ether);
        assertEq(alb.balanceOf(alice), 14_360 ether);
    }

    function test_escrowBackingInvariantAcrossPaths() public {
        _stakeEs(alice, 1000 ether);
        _stakeEs(bob, 500 ether);

        vm.prank(alice);
        uint256 idx = esALB.startUnstake(600 ether);
        assertGe(alb.balanceOf(address(esALB)), esALB.totalSupply());

        _skip(48 hours);
        vm.prank(bob);
        esALB.instantRedeem(10 ether);
        assertGe(alb.balanceOf(address(esALB)), esALB.totalSupply());

        _skip(40 days);
        vm.prank(alice);
        esALB.finalizeUnstake(idx);
        assertGe(alb.balanceOf(address(esALB)), esALB.totalSupply());
    }

    function test_transfersBlockedBetweenNonWhitelisted() public {
        _stakeEs(alice, 100 ether);
        vm.expectRevert(EscrowedToken.NotWhitelisted.selector);
        vm.prank(alice);
        esALB.transfer(bob, 1 ether);
    }

    function test_transferToWhitelistedMovesStake() public {
        _stakeEs(alice, 100 ether);
        esALB.setWhitelisted(carol, true);
        vm.prank(alice);
        esALB.transfer(carol, 40 ether);
        assertEq(staking.sharesOf(alice), 60 ether);
        assertEq(staking.sharesOf(carol), 40 ether);
        assertEq(staking.totalShares(), 100 ether);
    }

    function test_depositForBlockedBeforeStakingWired() public {
        EsALBHarness fresh = new EsALBHarness(address(this), address(alb));
        _mintALB(address(this), 10 ether);
        alb.approve(address(fresh), 10 ether);
        vm.expectRevert(EscrowedToken.StakingNotSet.selector);
        fresh.depositFor(alice, 10 ether);
    }

    function testFuzz_escrowBackedOneToOne(uint96 deposit, uint96 unstakeAmt) public {
        deposit = uint96(bound(deposit, 1 ether, 1_000_000 ether));
        unstakeAmt = uint96(bound(unstakeAmt, 1, deposit));
        _stakeEs(alice, deposit);
        vm.prank(alice);
        esALB.startUnstake(unstakeAmt);
        assertGe(alb.balanceOf(address(esALB)), esALB.totalSupply());
        assertEq(staking.totalShares(), staking.sharesOf(alice));
    }
}

import {EsALB} from "../src/token/EsALB.sol";
import {IALB} from "../src/interfaces/IALB.sol";

contract EsALBHarness is EsALB {
    constructor(address owner_, address alb_) EsALB(owner_, IALB(alb_)) {}
}

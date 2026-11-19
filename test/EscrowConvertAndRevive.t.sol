// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {EscrowedToken} from "../src/token/EscrowedToken.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {EsALB} from "../src/token/EsALB.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {LoC} from "../src/loc/LoC.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {MockERC20} from "./Mocks.sol";

contract EscrowConvertAndReviveTest is BaseTest {
    function _depositEs(address user, uint256 amt) internal {
        _mintALB(user, amt);
        vm.startPrank(user);
        alb.approve(address(esALB), amt);
        esALB.depositFor(user, amt);
        vm.stopPrank();
    }

    function _wireConversion() internal {
        esALB.setConversionDestination(address(govALB), true);
        govALB.setConversionSource(address(esALB), true);
    }

    function test_convertMovesBalanceBackingAndKeepsShares() public {
        _wireConversion();
        _depositEs(alice, 100 ether);
        uint256 sharesBefore = staking.sharesOf(alice);

        vm.prank(alice);
        esALB.convertTo(address(govALB), 40 ether);

        assertEq(esALB.balanceOf(alice), 60 ether);
        assertEq(govALB.balanceOf(alice), 40 ether);
        assertEq(alb.balanceOf(address(esALB)), 60 ether, "backing left the source");
        assertEq(alb.balanceOf(address(govALB)), 40 ether, "backing arrived at the destination");

        assertEq(staking.sharesOf(alice), sharesBefore);
        assertEq(
            staking.sharesOf(alice),
            esALB.stakedSharesOf(alice) + govALB.stakedSharesOf(alice),
            "share-mirror invariant holds"
        );
    }

    function test_conversionRequiresBothSidesRegistered() public {
        _depositEs(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotConversionPath.selector);
        esALB.convertTo(address(govALB), 1 ether);

        esALB.setConversionDestination(address(govALB), true);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotConversionPath.selector);
        esALB.convertTo(address(govALB), 1 ether);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotConversionPath.selector);
        govALB.convertIn(alice, 1 ether);
    }

    function test_conversionRespectsDestinationCapAtomically() public {
        _wireConversion();
        _depositEs(alice, 100 ether);
        govALB.setSupplyCap(30 ether);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.SupplyCapExceeded.selector);
        esALB.convertTo(address(govALB), 40 ether);
        assertEq(esALB.balanceOf(alice), 100 ether, "nothing moved on a capped conversion");

        vm.prank(alice);
        esALB.convertTo(address(govALB), 30 ether);
        assertEq(govALB.balanceOf(alice), 30 ether);
    }

    function test_conversionConfigIsOwnerOnlyAndChecksUnderlying() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        esALB.setConversionDestination(address(govALB), true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        govALB.setConversionSource(address(esALB), true);

        ALBToken otherAlb = new ALBToken(DAO, RECOVERY);
        EsALB other = new EsALB(address(this), IALB(address(otherAlb)));
        vm.expectRevert(EscrowedToken.InvalidParams.selector);
        esALB.setConversionDestination(address(other), true);
    }

    function test_walletCapBoundsEveryAcquisitionPath() public {
        _wireConversion();
        govALB.setWalletCap(50 ether);
        _depositEs(alice, 200 ether);

        // Mint path (via conversion) up to the cap is fine; past it reverts atomically.
        vm.prank(alice);
        esALB.convertTo(address(govALB), 50 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.WalletCapExceeded.selector);
        esALB.convertTo(address(govALB), 1 ether);
        assertEq(esALB.balanceOf(alice), 150 ether, "failed conversion left source intact");

        // Direct deposit path is capped the same way (give alice loose ALB first).
        _mintALB(alice, 1 ether);
        vm.startPrank(alice);
        alb.approve(address(govALB), 1 ether);
        vm.expectRevert(EscrowedToken.WalletCapExceeded.selector);
        govALB.depositFor(alice, 1 ether);
        vm.stopPrank();
    }

    function test_walletCapCountsVestingCustody() public {
        // The dodge: park the position in startUnstake custody, then acquire more.
        _wireConversion();
        govALB.setWalletCap(50 ether);
        _depositEs(alice, 200 ether);
        vm.startPrank(alice);
        esALB.convertTo(address(govALB), 50 ether);
        govALB.startUnstake(50 ether); // balance 0, locked 50
        vm.stopPrank();
        assertEq(govALB.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(EscrowedToken.WalletCapExceeded.selector);
        esALB.convertTo(address(govALB), 1 ether);

        // Cancelling restores the balance without tripping the cap (sum unchanged).
        vm.prank(alice);
        govALB.cancelUnstake(0);
        assertEq(govALB.balanceOf(alice), 50 ether);
    }

    function test_walletCapConfigAndExemptions() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        govALB.setWalletCap(1 ether);

        // Prospective only: capping below existing holdings confiscates nothing and
        // still allows reductions.
        _wireConversion();
        _depositEs(alice, 200 ether);
        vm.prank(alice);
        esALB.convertTo(address(govALB), 100 ether);
        govALB.setWalletCap(50 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.WalletCapExceeded.selector);
        esALB.convertTo(address(govALB), 1 ether);
        vm.prank(alice);
        govALB.instantRedeem(1 ether); // reducing is always allowed (within the 1.436%/wk bucket)

        // 0 disables.
        govALB.setWalletCap(0);
        vm.prank(alice);
        esALB.convertTo(address(govALB), 10 ether);
    }

    function test_retireClawsBackThenReviveRestarts() public {
        MockERC20 pt = new MockERC20("Partner", "PTN", 18);
        staking.registerStream(address(pt), 0);
        staking.setNotifier(address(this), true);
        _depositEs(alice, 100 ether);
        pt.mint(address(this), 1_000 ether);
        pt.approve(address(staking), type(uint256).max);
        staking.notifyReward(address(pt), 700 ether);

        uint256 balBefore = pt.balanceOf(address(this));
        staking.retireStream(address(pt));
        assertGt(pt.balanceOf(address(this)), balBefore, "unemitted remainder clawed back to Owner");
        vm.expectRevert(StakingContract.StreamRetiredError.selector);
        staking.notifyReward(address(pt), 1 ether);

        staking.reviveStream(address(pt));
        staking.notifyReward(address(pt), 100 ether);

        vm.expectRevert(StakingContract.StreamNotRetired.selector);
        staking.deleteStream(address(pt), address(this));
    }

    function test_reviveIsOwnerOnly() public {
        MockERC20 pt = new MockERC20("Partner", "PTN", 18);
        staking.registerStream(address(pt), 0);
        staking.retireStream(address(pt));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        staking.reviveStream(address(pt));
    }

    function test_interestMintsWithoutRebase() public {
        _depositEs(alice, 100 ether);
        LoC o = LoC(
            factory.createLoC(
                bob, address(staking), 1_000_000 ether, 100_000 ether, 500_000 ether, 500, new LoC.Option[](0)
            )
        );
        vm.prank(bob);
        o.draw(10_000 ether, bob);
        uint256 rebaseAfterDraw = factory.pendingRebase();
        assertGt(rebaseAfterDraw, 0, "principal draws still rebase");

        vm.warp(block.timestamp + 365 days);
        o.pokeInterest();
        assertGt(o.totalInterestMinted(), 0, "interest accrued and minted");
        assertEq(factory.pendingRebase(), rebaseAfterDraw, "interest minted WITHOUT a rebase");
    }
}

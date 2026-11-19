// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {MockERC20} from "./Mocks.sol";
import {MockHookToken} from "./Distributor.t.sol";

contract GasHungryToken is MockERC20 {
    constructor() MockERC20("Gas Hungry", "GAS", 18) {}
    function transfer(address to, uint256 a) public override returns (bool) {
        uint256 target = gasleft() - 160_000;
        while (gasleft() > target) {}
        return super.transfer(to, a);
    }
}

contract DistributorManagerTest is Test {
    uint64 internal constant T0 = 1_700_000_000;

    address internal fees = makeAddr("fees");
    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    Distributor internal farm;
    MockERC20 internal lp;
    MockERC20 internal rwd;
    uint256 internal pid;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
        farm.grantRoles(admin, farm.ROLE_ADMIN());
        lp = new MockERC20("LP", "LP", 18);
        rwd = new MockERC20("Reward", "RWD", 18);
        pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        lp.mint(alice, 1_000 ether);
        vm.prank(alice);
        lp.approve(address(farm), type(uint256).max);
    }

    function _managedBalanceStream() internal returns (uint256 idx) {
        idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);
    }

    function _fund(uint256 idx, uint256 amount) internal {
        rwd.mint(address(this), amount);
        rwd.approve(address(farm), amount);
        farm.fundStream(pid, idx, amount);
    }

    function test_depositRegistrationClearsOnlyWhenEmpty() public {
        // Admin opens a DEPOSIT pool for a future hook token by mistake.
        MockHookToken hook = new MockHookToken(); // hooks dormant until setFarm
        vm.prank(admin);
        uint256 pid2 = farm.addPool(address(hook), Distributor.PoolKind.DEPOSIT);
        vm.expectRevert(Distributor.TokenIsDepositStake.selector);
        farm.addPool(address(hook), Distributor.PoolKind.HOOK);

        // While anything is custodied, the mark cannot be cleared.
        hook.mint(alice, 10 ether);
        vm.startPrank(alice);
        hook.approve(address(farm), 10 ether);
        farm.deposit(pid2, 10 ether);
        vm.stopPrank();
        vm.expectRevert(Distributor.NonZeroStake.selector);
        farm.clearDepositRegistration(address(hook));

        // Drained, the Owner clears it and the hook pool becomes possible.
        vm.prank(alice);
        farm.withdraw(pid2, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.clearDepositRegistration(address(hook));
        farm.clearDepositRegistration(address(hook));
        hook.setFarm(farm); // opt in only now, as a real hook token would
        farm.addPool(address(hook), Distributor.PoolKind.HOOK);
    }

    function _grantMintRights(address token, uint256 v) internal {
        farm.scheduleMintRights(token, v);
        vm.warp(block.timestamp + farm.MINT_RIGHTS_DELAY());
        farm.applyMintRights(token);
    }

    function test_depositsAreNeverFeed() public {
        vm.prank(alice);
        farm.deposit(pid, 100 ether);
        assertEq(lp.balanceOf(address(farm)), 100 ether);
        assertEq(lp.balanceOf(fees), 0);
        (,,,, uint16 feeBP, uint256 interval,) = farm.poolInfo(pid);
        assertEq(feeBP, 0);
        assertEq(interval, 30);
    }

    function test_harvestIntervalIsThirtySeconds() public {
        uint256 idx = _managedBalanceStream();
        farm.setStreamRate(pid, idx, 1 ether);
        _fund(idx, 1_000 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        vm.warp(T0 + 10);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(alice), 0, "locked inside 30s");

        vm.warp(T0 + 31);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(alice), 31 ether, "paid after 30s");
    }

    function test_adminMayAddStreamsStrangerMayNot() public {
        vm.prank(admin);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);
        assertEq(farm.streamManager(pid, idx), manager);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
    }

    function test_managerControlsOwnStream() public {
        uint256 idx = _managedBalanceStream();
        _fund(idx, 700 ether);

        vm.prank(manager);
        farm.setStreamRate(pid, idx, 2 ether);
        vm.prank(manager);
        farm.setStreamRate(pid, idx, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamRate(pid, idx, 3 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamRate(pid, idx, 3 ether);
        vm.prank(admin);
        farm.setStreamRate(pid, idx, 0.5 ether);

        vm.prank(manager);
        farm.setStreamActive(pid, idx, false);
        vm.prank(manager);
        farm.setStreamActive(pid, idx, true);

        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 7 days);
        (uint64 len,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(len, 7 days);
        assertEq(budget, 700 ether);

        vm.prank(manager);
        farm.setStreamManager(pid, idx, stranger);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamActive(pid, idx, false);
        vm.prank(stranger);
        farm.setStreamActive(pid, idx, false);
    }

    function test_managerRecoversOnlyUnvestedReserve() public {
        uint256 idx = _managedBalanceStream();
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 100);
        _fund(idx, 100 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        vm.warp(T0 + 50);
        _fund(idx, 40 ether);
        vm.prank(manager);
        farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);

        assertEq(rwd.balanceOf(manager), 40 ether, "only the queued top-up is recoverable");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.recoverStreamReserve(pid, idx, stranger, 1);
    }

    function test_pullEpochPullsBudgetAtBoundary() public {
        address src = makeAddr("src");
        vm.prank(src);
        farm.setPullSource(true);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);

        rwd.mint(src, 1_000 ether);
        vm.prank(src);
        rwd.approve(address(farm), 100 ether);

        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 100);
        assertEq(rwd.balanceOf(address(farm)), 100 ether, "epoch budget pulled up front");
        assertEq(farm.streamInfo(pid, idx).reserve, 100 ether);

        vm.warp(T0 + 131);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(alice), 100 ether, "whole pulled budget distributed");

        vm.prank(src);
        rwd.approve(address(farm), 60 ether);
        farm.startStreamEpoch(pid, idx);
        assertEq(farm.streamInfo(pid, idx).reserve, 60 ether);
    }

    function test_pullEpochStandingAllowanceDrawsPerEpochBudget() public {
        address src = makeAddr("src");
        vm.prank(src);
        farm.setPullSource(true);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);

        rwd.mint(src, 1_000 ether);
        vm.prank(src);
        rwd.approve(address(farm), type(uint256).max);
        vm.prank(manager);
        farm.setStreamEpochPull(pid, idx, 100 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 100);
        assertEq(farm.streamInfo(pid, idx).reserve, 100 ether, "epoch 1 draws only its budget");
        assertEq(rwd.balanceOf(src), 900 ether, "standing allowance not drained");

        vm.warp(T0 + 100);
        farm.startStreamEpoch(pid, idx);
        assertEq(farm.streamInfo(pid, idx).reserve, 100 ether, "epoch 2 drew the same budget");
        assertEq(rwd.balanceOf(src), 800 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamEpochPull(pid, idx, 1 ether);
        uint256 balIdx = _managedBalanceStream();
        vm.prank(manager);
        vm.expectRevert(Distributor.WrongStreamKind.selector);
        farm.setStreamEpochPull(pid, balIdx, 1 ether);

        rwd.mint(address(this), 1 ether);
        rwd.approve(address(farm), 1 ether);
        vm.expectRevert(Distributor.WrongStreamKind.selector);
        farm.fundStream(pid, idx, 1 ether);
    }

    function test_livePullRealizationsPayTheStreamFee() public {
        address src = makeAddr("src");
        vm.prank(src);
        farm.setPullSource(true);

        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 1000);

        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        rwd.mint(src, 1_000 ether);
        vm.prank(src);
        rwd.approve(address(farm), type(uint256).max);
        vm.prank(manager);
        farm.setStreamRate(pid, idx, 1 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        vm.warp(T0 + 131);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(fees), 13.1 ether, "10% skim on live pulls");
        assertEq(rwd.balanceOf(alice), 117.9 ether, "stakers earn the net");
        assertEq(rwd.balanceOf(src), 1_000 ether - 131 ether);
    }

    function test_pullManagerMayManageManualRate() public {
        address src = makeAddr("src");
        vm.prank(src);
        farm.setPullSource(true);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.prank(manager);
        farm.setStreamRate(pid, idx, 5 ether);
        assertEq(farm.streamInfo(pid, idx).ratePerSec, 5 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamRate(pid, idx, 1 ether);
    }

    function test_fundFeeIsPerStream() public {
        uint256 protocolIdx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        MockERC20 partner = new MockERC20("Partner", "PTN", 18);
        uint256 communityIdx = farm.addStream(pid, address(partner), Distributor.StreamKind.BALANCE, address(0), manager, 1000);

        _fund(protocolIdx, 100 ether);
        assertEq(rwd.balanceOf(fees), 0, "protocol stream funds fee-free");
        assertEq(farm.streamInfo(pid, protocolIdx).reserve, 100 ether);

        partner.mint(address(this), 100 ether);
        partner.approve(address(farm), 100 ether);
        farm.fundStream(pid, communityIdx, 100 ether);
        assertEq(partner.balanceOf(fees), 10 ether, "community stream pays its 10% skim");
        assertEq(farm.streamInfo(pid, communityIdx).reserve, 90 ether);
    }

    function test_fundFeeCapEnforcedAtCreation() public {
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 2001);
    }

    function test_adminAdjustsStreamFeeButManagerCannot() public {
        uint256 idx = _managedBalanceStream();
        vm.prank(admin);
        farm.setStreamFundFee(pid, idx, 500);
        assertEq(farm.streamInfo(pid, idx).fundFeeBps, 500);
        vm.prank(admin);
        farm.setStreamFundFee(pid, idx, 0);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamFundFee(pid, idx, 0);
        vm.prank(admin);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setStreamFundFee(pid, idx, 2001);
    }

    function test_funderFeeCeilingBlocksFrontRun() public {
        uint256 idx = _managedBalanceStream();
        rwd.mint(address(this), 200 ether);
        rwd.approve(address(farm), 200 ether);

        farm.fundStream(pid, idx, 100 ether, 0);
        vm.prank(admin);
        farm.setStreamFundFee(pid, idx, 1000);
        vm.expectRevert(Distributor.FeeTooHigh.selector);
        farm.fundStream(pid, idx, 100 ether, 0);

        farm.fundStream(pid, idx, 100 ether);
        assertEq(rwd.balanceOf(fees), 10 ether);
        assertEq(farm.streamInfo(pid, idx).reserve, 190 ether);
    }

    function test_pullEpochAppliesTheStreamFee() public {
        address src = makeAddr("src");
        vm.prank(src);
        farm.setPullSource(true);

        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 1000);

        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        rwd.mint(src, 100 ether);
        vm.prank(src);
        rwd.approve(address(farm), 100 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 100);
        assertEq(rwd.balanceOf(fees), 10 ether, "epoch pull skimmed");
        assertEq(farm.streamInfo(pid, idx).reserve, 90 ether);
    }

    function test_heavyRewardTokenPaysOnExplicitHarvest() public {
        GasHungryToken heavy = new GasHungryToken();
        uint256 idx = farm.addStream(pid, address(heavy), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(pid, idx, 1 ether);
        heavy.mint(address(this), 1_000 ether);
        heavy.approve(address(farm), 1_000 ether);
        farm.fundStream(pid, idx, 1_000 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        vm.warp(T0 + 100);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(heavy.balanceOf(alice), 100 ether, "heavyweight token paid with full gas");
    }

    function test_heavyRewardTokenDefersInsideHookTransfers() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        uint256 hookPid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        GasHungryToken heavy = new GasHungryToken();
        uint256 idx = farm.addStream(hookPid, address(heavy), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(hookPid, idx, 1 ether);
        heavy.mint(address(this), 1_000 ether);
        heavy.approve(address(farm), 1_000 ether);
        farm.fundStream(hookPid, idx, 1_000 ether);
        hook.mint(alice, 100 ether);

        vm.warp(T0 + 100);

        vm.prank(alice);
        hook.transfer(stranger, 1 ether);
        assertEq(heavy.balanceOf(alice), 0, "capped payout deferred");
        assertGt(farm.rewardLockedUp(hookPid, alice, idx), 0, "locked, not lost");

        vm.warp(T0 + 131);
        uint256[] memory pids = new uint256[](1);
        pids[0] = hookPid;
        vm.prank(alice);
        farm.harvestMany(pids);
        assertGt(heavy.balanceOf(alice), 0, "deferred rewards claimable with full gas");
        assertEq(farm.rewardLockedUp(hookPid, alice, idx), 0);
    }

    function test_mintRightsGateAndTimelock() public {
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.MINT, address(0), address(0), 0);

        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, idx, 1 ether);

        farm.scheduleMintRights(address(rwd), 2 ether);
        vm.expectRevert(Distributor.TimelockNotElapsed.selector);
        farm.applyMintRights(address(rwd));
        vm.warp(block.timestamp + farm.MINT_RIGHTS_DELAY());
        farm.applyMintRights(address(rwd));
        assertEq(farm.mintRights(address(rwd)), 2 ether);

        vm.prank(admin);
        farm.setStreamRate(pid, idx, 2 ether);
        assertEq(farm.mintRateOf(address(rwd)), 2 ether);

        uint256 idx2 = farm.addStream(pid, address(rwd), Distributor.StreamKind.MINT, address(0), address(0), 0);
        vm.prank(admin);
        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, idx2, 1);
        vm.prank(admin);
        farm.setStreamRate(pid, idx, 1 ether);
        vm.prank(admin);
        farm.setStreamRate(pid, idx2, 1 ether);

        farm.setMintRights(address(rwd), 0.5 ether);
        assertEq(farm.mintRights(address(rwd)), 0.5 ether);
        vm.expectRevert(Distributor.TimelockNotElapsed.selector);
        farm.setMintRights(address(rwd), 3 ether);
    }

    function test_replaceStreamSweepsResidualAndRestartsSlot() public {
        uint256 idx = _managedBalanceStream();
        farm.setStreamRate(pid, idx, 1 ether);
        _fund(idx, 100 ether);
        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        vm.warp(T0 + 40);

        MockERC20 rwd2 = new MockERC20("Reward2", "RW2", 18);
        address residualTo = makeAddr("residual");
        farm.replaceStream(
            pid, idx, address(rwd2), Distributor.StreamKind.BALANCE, address(0), manager, 0, residualTo
        );

        assertEq(rwd.balanceOf(residualTo), 100 ether, "reserve + owed swept");

        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        assertEq(s.token, address(rwd2));
        assertEq(s.generation, 1);
        assertEq(s.accPerShare, 0);
        assertEq(s.reserve, 0);

        (,,, uint256[] memory amts) = farm.pendingTokens(pid, alice);
        assertEq(amts[0], 0, "no phantom rewards from the old incarnation");

        farm.setStreamRate(pid, idx, 2 ether);
        rwd2.mint(address(this), 500 ether);
        rwd2.approve(address(farm), 500 ether);
        farm.fundStream(pid, idx, 500 ether);
        vm.warp(T0 + 40 + 50);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(rwd2.balanceOf(alice), 100 ether, "50s at 2/s in the new token");
        assertEq(rwd.balanceOf(alice), 0, "old token was never paid to the staker");
    }

    function test_replaceStreamIsOwnerOnlyAndAdjustsMintAggregate() public {
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.MINT, address(0), address(0), 0);
        _grantMintRights(address(rwd), 1 ether);
        farm.setStreamRate(pid, idx, 1 ether);
        assertEq(farm.mintRateOf(address(rwd)), 1 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.replaceStream(pid, idx, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0, fees);

        MockERC20 rwd2 = new MockERC20("Reward2", "RW2", 18);
        farm.replaceStream(pid, idx, address(rwd2), Distributor.StreamKind.BALANCE, address(0), address(0), 0, fees);
        assertEq(farm.mintRateOf(address(rwd)), 0, "replaced MINT stream releases its rights budget");
    }
}

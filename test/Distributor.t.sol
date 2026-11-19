// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {MockERC20} from "./Mocks.sol";

contract MockHookToken is ERC20 {
    Distributor public distributor;
    function name() public pure override returns (string memory) { return "Hook"; }
    function symbol() public pure override returns (string memory) { return "HOOK"; }
    function setFarm(Distributor f) external { distributor = f; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (address(distributor) == address(0)) return;
        if (from != address(0)) distributor.notifyUnstake(from, amount);
        if (to != address(0)) distributor.notifyStake(to, amount);
    }
}

contract MockBrickableToken is MockERC20 {
    bool public bricked;
    constructor() MockERC20("Brick", "BRK", 18) {}
    function setBricked(bool b) external { bricked = b; }
    function transfer(address to, uint256 a) public override returns (bool) {
        require(!bricked, "bricked");
        return super.transfer(to, a);
    }
}

contract DistributorTest is BaseTest {
    Distributor internal farm;
    MockERC20 internal lp;
    MockERC20 internal rwd;
    address internal FEES = makeAddr("fees");
    address internal SOURCE = makeAddr("source");

    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public override {
        super.setUp();
        farm = new Distributor(DAO, FEES);
        lp = new MockERC20("LP", "LP", 18);
        rwd = new MockERC20("Reward", "RWD", 18);
        lp.mint(alice, 1_000 ether);
        lp.mint(bob, 1_000 ether);
        vm.prank(alice); lp.approve(address(farm), type(uint256).max);
        vm.prank(bob);   lp.approve(address(farm), type(uint256).max);
    }

    function _pool() internal returns (uint256 pid) {
        vm.prank(DAO);
        pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
    }

    function _grantMintRights(address token, uint256 v) internal {
        vm.prank(DAO); farm.scheduleMintRights(token, v);
        vm.warp(block.timestamp + 2 days);
        vm.prank(DAO); farm.applyMintRights(token);
    }

    function _balanceStream(uint256 pid, uint128 rate, uint256 fundAmt) internal returns (uint256 idx) {
        vm.prank(DAO);
        idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(DAO);
        farm.setStreamRate(pid, idx, rate);
        rwd.mint(address(this), fundAmt);
        rwd.approve(address(farm), fundAmt);
        farm.fundStream(pid, idx, fundAmt);
    }

    function test_mintStreamStopsAtCapWithoutBricking() public {
        uint256 pid = _pool();
        vm.prank(DAO);
        uint256 idx = farm.addStream(pid, address(alb), Distributor.StreamKind.MINT, address(0), address(0), 0);
        vm.prank(DAO);
        alb.addMinter(address(farm));
        _grantMintRights(address(alb), 1 ether);
        vm.prank(DAO);
        farm.setStreamRate(pid, idx, 1 ether);

        vm.prank(alice);
        farm.deposit(pid, 100 ether);

        uint256 cap = alb.MAX_SUPPLY();
        _mintALB(carol, cap - alb.totalSupply() - 10 ether);
        assertEq(cap - alb.totalSupply(), 10 ether, "10 ALB headroom");

        uint256 t = block.timestamp + 100;
        vm.warp(t);

        vm.prank(alice);
        farm.withdraw(pid, 50 ether);
        assertEq(alb.balanceOf(alice), 10 ether, "clamped to remaining cap, not reverted");
        assertEq(alb.totalSupply(), cap, "cap exactly reached");

        t += 1000; vm.warp(t);
        vm.prank(alice); farm.deposit(pid, 50 ether);
        vm.prank(bob);   farm.deposit(pid, 100 ether);
        uint256[] memory pids = new uint256[](1); pids[0] = pid;
        vm.prank(alice); farm.harvestMany(pids);
        vm.prank(alice); farm.withdraw(pid, 100 ether);
        assertEq(alb.balanceOf(alice), 10 ether, "no further ALB can exist; nothing reverted");
        assertEq(lp.balanceOf(alice), 1_000 ether, "principal fully recoverable");
    }

    function test_pullStreamStopsWhenSourceDry() public {
        uint256 pid = _pool();
        vm.prank(SOURCE); farm.setPullSource(true);
        vm.prank(DAO);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, SOURCE, address(0), 0);
        vm.prank(SOURCE);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.prank(DAO);
        farm.setStreamRate(pid, idx, 1 ether);
        rwd.mint(SOURCE, 30 ether);
        vm.prank(SOURCE); rwd.approve(address(farm), type(uint256).max);

        vm.warp(T0);
        vm.prank(alice); farm.deposit(pid, 100 ether);

        vm.warp(T0 + 100);
        vm.prank(alice); farm.withdraw(pid, 0);
        assertEq(rwd.balanceOf(alice), 30 ether, "pulled exactly what the source had");
        assertEq(rwd.balanceOf(SOURCE), 0);

        vm.warp(T0 + 200);
        vm.prank(alice); farm.withdraw(pid, 0);
        assertEq(rwd.balanceOf(alice), 30 ether, "nothing pulled while dry; no revert");

        rwd.mint(SOURCE, 1_000 ether);
        vm.warp(T0 + 210);
        vm.prank(alice); farm.withdraw(pid, 100 ether);
        assertEq(rwd.balanceOf(alice), 40 ether, "30 pulled earlier + 10s after refill; dry gap forfeited");
        assertEq(lp.balanceOf(alice), 1_000 ether, "principal fully returned");
    }

    function test_balanceStreamFeeSkimAndBudgetIsHardBound() public {
        uint256 pid = _pool();

        vm.prank(DAO);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 1000);
        vm.prank(DAO);
        farm.setStreamRate(pid, idx, 1 ether);
        rwd.mint(address(this), 100 ether);
        rwd.approve(address(farm), 100 ether);
        farm.fundStream(pid, idx, 100 ether);

        assertEq(rwd.balanceOf(FEES), 10 ether, "fee skimmed to recipient");
        (,,,,,,, uint256 reserve,) = _stream(pid, idx);
        assertEq(reserve, 90 ether, "net funded to reserve");

        vm.prank(alice); farm.deposit(pid, 100 ether);
        uint256 t = block.timestamp + 10_000; vm.warp(t);

        vm.prank(alice); farm.withdraw(pid, 100 ether);
        assertEq(rwd.balanceOf(alice), 90 ether, "paid exactly the net budget, not a wei more");
        assertEq(rwd.balanceOf(address(farm)), 0, "farm holds nothing it did not owe");
    }

    function test_balanceStreamFundingOnlyExtendsNeverAccelerates() public {
        vm.warp(T0);
        uint256 pid = _pool();
        uint256 idx = _balanceStream(pid, 1 ether, 50 ether);
        (,,,,,, uint64 end1,,) = _stream(pid, idx);
        assertEq(end1, T0 + 50, "50 tokens at 1/s = 50s");

        rwd.mint(bob, 25 ether);
        vm.prank(bob); rwd.approve(address(farm), 25 ether);
        vm.prank(bob); farm.fundStream(pid, idx, 25 ether);
        (,,,,, uint128 rate, uint64 end2,,) = _stream(pid, idx);
        assertEq(rate, 1 ether, "rate untouched by funding");
        assertEq(end2, T0 + 75, "end extended, not rate raised");
    }

    function test_hookPoolTracksTransfersAndIntermediariesAreTransparent() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        vm.prank(DAO);
        uint256 pid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        address router = makeAddr("router");
        vm.prank(DAO); farm.setIntermediary(router, true);

        hook.mint(alice, 100 ether);
        (uint256 aAmt,,,) = farm.userInfo(pid, alice);
        assertEq(aAmt, 100 ether, "stake mirrors wallet with no deposit");
        assertEq(farm.poolTotalLp(pid), 100 ether);

        vm.prank(alice); hook.transfer(router, 60 ether);
        (uint256 rAmt,,,) = farm.userInfo(pid, router);
        assertEq(rAmt, 0, "intermediary is transparent");
        assertEq(farm.poolTotalLp(pid), 40 ether, "stake left alice, parked nowhere");

        vm.prank(router); hook.transfer(bob, 60 ether);
        (uint256 bAmt,,,) = farm.userInfo(pid, bob);
        assertEq(bAmt, 60 ether, "stake follows beneficial ownership");
        assertEq(farm.poolTotalLp(pid), 100 ether);

        vm.prank(alice);
        vm.expectRevert(Distributor.WrongPoolKind.selector);
        farm.deposit(pid, 1);
    }

    function test_hookUnstakeClampsAndSyncStakeBootstraps() public {
        MockHookToken hook = new MockHookToken();
        hook.mint(alice, 100 ether);
        hook.setFarm(farm);
        vm.prank(DAO);
        uint256 pid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);

        vm.prank(alice); hook.transfer(bob, 30 ether);
        (uint256 aAmt,,,) = farm.userInfo(pid, alice);
        assertEq(aAmt, 0, "clamped at zero, transfer succeeded");
        (uint256 bAmt,,,) = farm.userInfo(pid, bob);
        assertEq(bAmt, 30 ether, "receiver credited normally");

        farm.syncStake(pid, alice);
        (aAmt,,,) = farm.userInfo(pid, alice);
        assertEq(aAmt, 70 ether, "bootstrapped to exactly the wallet balance");
        assertEq(farm.poolTotalLp(pid), 100 ether);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.syncStake(pid, alice);
    }

    function test_hookTokenAndRewardTokenAreMutuallyExclusive() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        vm.prank(DAO);
        uint256 hpid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        uint256 dpid = _pool();

        vm.prank(DAO);
        vm.expectRevert(Distributor.HookTokenCannotBeReward.selector);
        farm.addStream(dpid, address(hook), Distributor.StreamKind.BALANCE, address(0), address(0), 0);

        vm.prank(DAO);
        farm.addStream(hpid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(DAO);
        vm.expectRevert(Distributor.RewardTokenCannotBeHook.selector);
        farm.addPool(address(rwd), Distributor.PoolKind.HOOK);
    }

    function test_emergencyWithdrawWorksEvenWhenRewardTokenIsBricked() public {
        MockBrickableToken brick = new MockBrickableToken();
        uint256 pid = _pool();
        vm.prank(DAO);
        uint256 idx = farm.addStream(pid, address(brick), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(DAO); farm.setStreamRate(pid, idx, 1 ether);
        brick.mint(address(this), 1_000 ether);
        brick.approve(address(farm), 1_000 ether);
        farm.fundStream(pid, idx, 1_000 ether);

        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.warp(block.timestamp + 100);
        brick.setBricked(true);

        vm.prank(alice);
        farm.withdraw(pid, 50 ether);
        assertEq(lp.balanceOf(alice), 950 ether, "principal out despite bricked reward token");
        assertEq(farm.rewardLockedUp(pid, alice, idx), 100 ether, "reward deferred, not lost");
        assertEq(brick.balanceOf(alice), 0);

        vm.prank(alice); farm.emergencyWithdraw(pid);
        assertEq(lp.balanceOf(alice), 1_000 ether, "principal recovered");
        (uint256 amt,,,) = farm.userInfo(pid, alice);
        assertEq(amt, 0);
        assertEq(farm.rewardDebt(pid, alice, idx), 0, "state finalised, not left dangling");
        assertEq(farm.poolTotalLp(pid), 0);

        brick.setBricked(false);
        vm.prank(alice); farm.deposit(pid, 1 ether);
        assertEq(brick.balanceOf(alice), 0, "lockup was zeroed by emergencyWithdraw; nothing owed");
    }

    function test_harvestLockupHoldsThenReleases() public {
        vm.warp(T0);
        uint256 pid = _pool();
        _balanceStream(pid, 1 ether, 200_000 ether);
        vm.prank(alice); farm.deposit(pid, 100 ether);

        vm.warp(T0 + 10);
        assertFalse(farm.canHarvest(pid, alice));
        vm.prank(alice); farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(alice), 0, "locked, not paid");
        assertEq(farm.rewardLockedUp(pid, alice, 0), 10 ether, "accrued into lockup");
        (,,, uint256[] memory amts) = farm.pendingTokens(pid, alice);
        assertEq(amts[0], 10 ether, "legacy view includes lockup");

        vm.warp(T0 + 40);
        assertTrue(farm.canHarvest(pid, alice));
        vm.prank(alice); farm.deposit(pid, 0);
        assertEq(rwd.balanceOf(alice), 40 ether, "lockup + fresh accrual paid");
        assertEq(farm.rewardLockedUp(pid, alice, 0), 0);
    }

    function test_principalGuardStakeXEarnX() public {
        uint256 pid = _pool();
        vm.prank(DAO);
        uint256 idx = farm.addStream(pid, address(lp), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(DAO); farm.setStreamRate(pid, idx, 1 ether);
        lp.mint(address(this), 10 ether);
        lp.approve(address(farm), 10 ether);
        farm.fundStream(pid, idx, 10 ether);

        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.prank(bob);   farm.deposit(pid, 100 ether);
        vm.warp(block.timestamp + 1_000);

        vm.prank(alice); farm.withdraw(pid, 100 ether);

        assertEq(lp.balanceOf(alice), 1_000 ether + 5 ether);

        assertGe(lp.balanceOf(address(farm)), 100 ether, "bob's deposit never paid out as reward");
        vm.prank(bob); farm.withdraw(pid, 100 ether);
        assertEq(lp.balanceOf(bob), 1_000 ether + 5 ether);
    }

    function test_multipleStreamsPerPoolAndLegacyViewShape() public {
        uint256 pid = _pool();
        _balanceStream(pid, 2 ether, 1_000 ether);
        MockERC20 usdcR = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(DAO);
        uint256 i1 = farm.addStream(pid, address(usdcR), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(DAO); farm.setStreamRate(pid, i1, 1e6);
        usdcR.mint(address(this), 1_000e6); usdcR.approve(address(farm), 1_000e6);
        farm.fundStream(pid, i1, 1_000e6);

        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.warp(block.timestamp + 10);

        (address[] memory addrs, string[] memory syms, uint256[] memory decs, uint256[] memory amts) =
            farm.pendingTokens(pid, alice);
        assertEq(addrs.length, 2);
        assertEq(syms[0], "RWD");  assertEq(decs[0], 18); assertEq(amts[0], 20 ether);
        assertEq(syms[1], "USDC"); assertEq(decs[1], 6);  assertEq(amts[1], 10e6);

        (,,, uint256[] memory rps) = farm.poolRewardsPerSec(pid);
        assertEq(rps[0], 2 ether); assertEq(rps[1], 1e6);

        vm.warp(block.timestamp + 30);
        vm.prank(alice); farm.withdraw(pid, 0);
        assertEq(rwd.balanceOf(alice), 80 ether);
        assertEq(usdcR.balanceOf(alice), 40e6);
    }

    function test_deactivatedStreamNeverAccruesAcrossThePause() public {
        vm.warp(T0);
        uint256 pid = _pool();
        uint256 idx = _balanceStream(pid, 1 ether, 1_000 ether);
        vm.prank(alice); farm.deposit(pid, 100 ether);

        vm.warp(T0 + 10);
        vm.prank(DAO); farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 1_000);
        vm.prank(DAO); farm.setStreamActive(pid, idx, true);
        vm.warp(T0 + 1_005);
        vm.prank(alice); farm.withdraw(pid, 0);
        assertEq(rwd.balanceOf(alice), 15 ether, "10s before + 5s after; nothing for the pause");

        (,,,,,, uint64 end,,) = _stream(pid, idx);
        assertEq(end, T0 + 1_000 + 990, "reactivation re-derived the end from remaining reserve");
    }

    function _stream(uint256 pid, uint256 idx) internal view returns (
        address token, Distributor.StreamKind kind, bool active, uint64 lastUpdate,
        address source, uint128 rate, uint64 end, uint256 reserve, uint256 acc
    ) {
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        return (s.token, s.kind, s.active, s.lastUpdate, s.source, s.ratePerSec, s.emissionEnd, s.reserve, s.accPerShare);
    }
}

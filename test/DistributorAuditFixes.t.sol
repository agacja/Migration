// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {MockERC20} from "./Mocks.sol";
import {MockHookToken, MockBrickableToken} from "./Distributor.t.sol";
import {FarmEsToken} from "./FarmEscrow.t.sol";

contract HostileBalanceToken is MockERC20 {
    bool public hostile;
    constructor() MockERC20("Rugged", "RUG", 18) {}
    function setHostile(bool h) external { hostile = h; }
    function balanceOf(address a) public view override returns (uint256) {
        if (hostile) {
            assembly { for {} 1 {} {} }
        }
        return super.balanceOf(a);
    }
}

contract TrickyToken is MockERC20 {
    address public farm;
    bool public failFarmRead;
    bool public poisonOnPull;
    bool public poisoned;
    address public blocked;
    constructor() MockERC20("Tricky", "TRK", 18) {}
    function setFarm(address f) external { farm = f; }
    function setFailFarmRead(bool b) external { failFarmRead = b; }
    function setPoisonOnPull(bool b) external { poisonOnPull = b; poisoned = false; }
    function setBlocked(address a) external { blocked = a; }
    function balanceOf(address a) public view override returns (uint256) {
        if (a == farm && (failFarmRead || poisoned)) revert("unreadable");
        return super.balanceOf(a);
    }
    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        if (poisonOnPull && to == farm) poisoned = true;
        return super.transferFrom(from, to, amt);
    }
    function transfer(address to, uint256 amt) public override returns (bool) {
        require(to != blocked, "blocked");
        return super.transfer(to, amt);
    }
}

contract DistributorAuditFixesTest is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    address internal fees = makeAddr("fees");
    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal src = makeAddr("partnerTreasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal griefer = makeAddr("griefer");

    Distributor internal farm;
    MockERC20 internal lp;
    MockERC20 internal rwd;
    uint256 internal pid;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
        farm.grantRoles(admin, farm.ROLE_ADMIN());
        lp = new MockERC20("LP", "LP", 18);
        rwd = new MockERC20("RWD", "RWD", 18);
        pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        lp.mint(alice, 1_000 ether);
        vm.prank(alice);
        lp.approve(address(farm), type(uint256).max);
        rwd.approve(address(farm), type(uint256).max);
        rwd.mint(griefer, 1 ether);
        vm.prank(griefer);
        rwd.approve(address(farm), type(uint256).max);
    }

    function _stake(address user, uint256 amt) internal {
        vm.prank(user);
        farm.deposit(pid, amt);
    }

    function _consentingSource(uint256 bal) internal {
        rwd.mint(src, bal);
        vm.startPrank(src);
        farm.setPullSource(true);
        rwd.approve(address(farm), type(uint256).max);
        vm.stopPrank();
    }

    function test_H01_pullBindingIsAdminLevelAndInertUntilTerms() public {
        _consentingSource(10_000 ether);
        _stake(alice, 100 ether);
        // Binding no longer needs the Owner: since the per-stream terms fix, a bound
        // stream is fail-closed until the SOURCE accepts terms for that incarnation
        // (see R3T03) — the source's acceptance is the real consent, so binding sits
        // with Admin and an Admin bind moves nothing by itself.
        vm.prank(admin);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, admin, 0);
        vm.prank(admin);
        farm.setStreamRate(pid, idx, 1 ether);
        vm.warp(T0 + 100);
        farm.updatePool(pid);
        assertEq(rwd.balanceOf(src), 10_000 ether, "no terms, no draw");

        // And nobody, Admin included, can bind a source that never consented at all.
        vm.prank(admin);
        vm.expectRevert(Distributor.PullSourceNotConsented.selector);
        farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, makeAddr("stranger"), admin, 0);
    }

    function test_H01_managerRecoveryOfPullReserveGoesBackToSource() public {
        _consentingSource(10_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);

        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, idx, 0);
        farm.setStreamEpochLength(pid, idx, 1);
        farm.setStreamActive(pid, idx, false);
        vm.stopPrank();
        assertEq(rwd.balanceOf(src), 0, "pulled into the reserve");

        vm.warp(T0 + 1);
        vm.expectEmit(true, true, false, true, address(farm));
        emit Distributor.StreamReserveRecovered(pid, idx, src, 10_000 ether);
        vm.prank(manager);
        farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);

        assertEq(rwd.balanceOf(manager), 0, "manager never chooses the destination");
        assertEq(rwd.balanceOf(src), 10_000 ether, "the source got its funds back");
    }

    function test_H01_ownerRecoveryOfPullReserveAlsoGoesToSource() public {
        _consentingSource(500 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, address(0), 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        farm.setStreamEpochLength(pid, idx, 100);
        vm.warp(T0 + 100);
        farm.recoverStreamReserve(pid, idx, address(0xdead), type(uint256).max);
        assertEq(rwd.balanceOf(src), 500 ether);
        assertEq(rwd.balanceOf(address(0xdead)), 0);
    }

    function _farmEscrow() internal returns (FarmEsToken esc, uint256 epid, uint256 ridx, MockERC20 und) {
        und = new MockERC20("Partner Token", "PTN", 18);
        esc = new FarmEsToken(address(this), IALB(address(und)));
        esc.setStaking(IStakingContract(address(farm)));
        epid = farm.addPool(address(esc), Distributor.PoolKind.HOOK);
        farm.addStream(epid, address(und), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        ridx = farm.addStream(epid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(epid, ridx, 1 ether);
        rwd.mint(address(this), 1_000_000 ether);
        farm.fundStream(epid, ridx, 1_000_000 ether);
    }

    function _escDeposit(FarmEsToken esc, MockERC20 und, address user, uint256 amt) internal {
        und.mint(user, amt);
        vm.startPrank(user);
        und.approve(address(esc), amt);
        esc.depositFor(user, amt);
        vm.stopPrank();
    }

    function test_M01_vestingCustodyCannotBeSyncedIn() public {
        (FarmEsToken esc, uint256 epid, uint256 ridx, MockERC20 und) = _farmEscrow();
        _escDeposit(esc, und, alice, 100 ether);
        _escDeposit(esc, und, bob, 100 ether);
        vm.prank(bob);
        esc.startUnstake(100 ether);
        assertEq(esc.balanceOf(address(esc)), 100 ether, "vesting custody");
        assertEq(farm.poolTotalLp(epid), 170 ether);

        vm.prank(griefer);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.syncStake(epid, address(esc));
        assertEq(farm.poolTotalLp(epid), 170 ether, "no phantom stake");

        vm.warp(T0 + 100);
        uint256[] memory pids = new uint256[](1);
        pids[0] = epid;
        vm.prank(alice);
        farm.harvestMany(pids);
        assertApproxEqAbs(rwd.balanceOf(alice), uint256(100 ether) * 100 / 170, 1e6, "fair share");
        ridx;
    }

    function test_M01_syncStakeHonoursTheEscrowsExemptions() public {
        (FarmEsToken esc, uint256 epid,, MockERC20 und) = _farmEscrow();
        _escDeposit(esc, und, carol, 100 ether);
        esc.setHookExempt(carol, true);
        (uint256 amt,,,) = farm.userInfo(epid, carol);
        assertEq(amt, 0);
        vm.prank(griefer);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.syncStake(epid, carol);
    }

    function _hostileBalanceStream(uint256 onPid, HostileBalanceToken rug) internal returns (uint256 idx) {
        idx = farm.addStream(onPid, address(rug), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(onPid, idx, 1 ether);
        rug.mint(address(this), 1_000 ether);
        rug.approve(address(farm), type(uint256).max);
        farm.fundStream(onPid, idx, 1_000 ether);
    }

    function test_M02_hostileBalanceOfCannotFreezeHookTransfers() public {
        HostileBalanceToken rug = new HostileBalanceToken();
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        uint256 hpid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        uint256 idx = _hostileBalanceStream(hpid, rug);
        hook.mint(alice, 100 ether);
        hook.mint(bob, 100 ether);

        vm.warp(T0 + 100);
        rug.setHostile(true);

        vm.prank(alice);
        (bool ok,) = address(hook).call{gas: 1_000_000}(abi.encodeCall(hook.transfer, (bob, 1 ether)));
        assertTrue(ok, "both sides defer within the 150k stipend each");
        assertGt(farm.rewardLockedUp(hpid, alice, idx), 0, "alice's payout deferred, not lost");
        assertGt(farm.rewardLockedUp(hpid, bob, idx), 0, "bob's payout deferred, not lost");
    }

    function test_M02_withdrawSurvivesTwoHostileStreams() public {
        HostileBalanceToken rug = new HostileBalanceToken();
        MockERC20 honest = new MockERC20("Honest", "HON", 18);
        uint256 honestIdx = farm.addStream(pid, address(honest), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(pid, honestIdx, 1 ether);
        honest.mint(address(this), 1_000 ether);
        honest.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, honestIdx, 1_000 ether);
        _hostileBalanceStream(pid, rug);
        _hostileBalanceStream(pid, rug);
        _stake(alice, 100 ether);

        vm.warp(T0 + 100);
        rug.setHostile(true);

        vm.prank(alice);
        (bool ok,) = address(farm).call{gas: 3_000_000}(abi.encodeCall(farm.withdraw, (pid, 100 ether)));
        assertTrue(ok, "each hostile stream costs at most its 1M stipend");
        assertEq(lp.balanceOf(alice), 1_000 ether, "principal back");
        assertEq(honest.balanceOf(alice), 100 ether, "honest stream still paid");
    }

    function _livePullTricky(TrickyToken t, uint16 feeBps) internal returns (uint256 idx) {
        t.setFarm(address(farm));
        t.mint(src, 1_000 ether);
        vm.startPrank(src);
        farm.setPullSource(true);
        t.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        idx = farm.addStream(pid, address(t), Distributor.StreamKind.PULL, src, address(0), feeBps);
        vm.prank(src);
        farm.setPullTerms(pid, idx, feeBps, type(uint128).max, type(uint32).max);
        farm.setStreamRate(pid, idx, 1 ether);
        _stake(alice, 100 ether);
    }

    function test_M02_unreadableBalanceBeforeRealisesNothing() public {
        TrickyToken t = new TrickyToken();
        uint256 idx = _livePullTricky(t, 0);
        t.setFailFarmRead(true);
        vm.warp(T0 + 100);
        farm.updatePool(pid);
        assertEq(t.balanceOf(src), 1_000 ether, "no pull attempted");
        assertEq(farm.streamInfo(pid, idx).accPerShare, 0, "nothing booked");
    }

    function test_M02_unreadableBalanceAfterNeverInflates() public {
        TrickyToken t = new TrickyToken();
        uint256 idx = _livePullTricky(t, 0);
        t.setPoisonOnPull(true);
        vm.warp(T0 + 100);
        farm.updatePool(pid);
        assertEq(t.balanceOf(src), 900 ether);
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        assertEq(s.accPerShare, 0, "an unmeasured arrival books nothing");
        assertEq(s.owed, 0);
    }

    function test_M02_liveFeeTransferFailureDoesNotRevertAccrual() public {
        TrickyToken t = new TrickyToken();
        _livePullTricky(t, 1000);
        t.setBlocked(fees);
        vm.warp(T0 + 100);
        vm.expectEmit(true, false, false, true, address(farm));
        emit Distributor.FeeTransferFailed(address(t), 10 ether);
        vm.prank(alice);
        farm.deposit(pid, 0);
        assertEq(t.balanceOf(alice), 100 ether, "the untaken fee stays with stakers");
        assertEq(t.balanceOf(fees), 0);
    }

    function test_M02_epochPullFeeFailureStaysBooked() public {
        TrickyToken t = new TrickyToken();
        t.setFarm(address(farm));
        t.mint(src, 100 ether);
        vm.startPrank(src);
        farm.setPullSource(true);
        t.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        uint256 idx = farm.addStream(pid, address(t), Distributor.StreamKind.PULL, src, address(0), 1000);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        t.setBlocked(fees);
        farm.setStreamEpochLength(pid, idx, 100);
        assertEq(farm.streamInfo(pid, idx).reserve, 100 ether, "epoch started; fee left in the budget");
    }

    function test_M02_strictDeltaReadRevertsInsteadOfInflating() public {
        TrickyToken t = new TrickyToken();
        t.setFarm(address(farm));
        uint256 idx = farm.addStream(pid, address(t), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        t.mint(address(this), 100 ether);
        t.approve(address(farm), type(uint256).max);
        t.setFailFarmRead(true);
        vm.expectRevert(Distributor.BalanceReadFailed.selector);
        farm.fundStream(pid, idx, 100 ether);
    }

    function _mintStreams() internal returns (uint256 a, uint256 b) {
        a = farm.addStream(pid, address(rwd), Distributor.StreamKind.MINT, address(0), manager, 0);
        b = farm.addStream(pid, address(rwd), Distributor.StreamKind.MINT, address(0), address(0), 0);
        farm.scheduleMintRights(address(rwd), 10 ether);
        vm.warp(T0 + 2 days);
        farm.applyMintRights(address(rwd));
        farm.setStreamRate(pid, a, 5 ether);
        farm.setStreamRate(pid, b, 5 ether);
    }

    function test_M03_decreasesAlwaysPassNarrowedRights() public {
        (uint256 a, uint256 b) = _mintStreams();
        farm.setMintRights(address(rwd), 3 ether);
        farm.setStreamRate(pid, a, 0);
        vm.prank(admin);
        farm.setStreamRate(pid, b, 2 ether);
        assertEq(farm.mintRateOf(address(rwd)), 2 ether);
        vm.prank(admin);
        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, a, 2 ether);
        vm.prank(admin);
        farm.setStreamRate(pid, a, 1 ether);
        assertEq(farm.mintRateOf(address(rwd)), 3 ether);
    }

    function test_M03_onlyOwnerResumesAMintStream() public {
        (uint256 a,) = _mintStreams();
        vm.prank(manager);
        farm.setStreamActive(pid, a, false);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamActive(pid, a, true);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        farm.setStreamActive(pid, a, true);
        farm.setStreamActive(pid, a, true);
        assertTrue(farm.streamInfo(pid, a).active);
    }

    function test_L01_deadTokenSlotIsRecycled() public {
        MockBrickableToken dead = new MockBrickableToken();
        uint256 idx = farm.addStream(pid, address(dead), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(pid, idx, 1 ether);
        dead.mint(address(this), 100 ether);
        dead.approve(address(farm), 100 ether);
        farm.fundStream(pid, idx, 100 ether);
        _stake(alice, 100 ether);
        vm.warp(T0 + 50);
        dead.setBricked(true);

        MockERC20 fresh = new MockERC20("Fresh", "FRS", 18);
        vm.expectEmit(true, true, false, true, address(farm));
        emit Distributor.StreamReplaced(pid, idx, address(dead), address(fresh), Distributor.StreamKind.BALANCE, 0);
        farm.replaceStream(pid, idx, address(fresh), Distributor.StreamKind.BALANCE, address(0), address(0), 0, fees);
        assertEq(farm.streamInfo(pid, idx).token, address(fresh), "slot recycled");
        assertEq(dead.balanceOf(address(farm)), 100 ether, "unsendable residual stays unbooked");
    }

    function test_L02_feeAboveSourceCeilingSkipsThePull() public {
        _consentingSource(1_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 500);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochPull(pid, idx, 100 ether);

        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 7 days);
        assertEq(rwd.balanceOf(src), 1_000 ether);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 0);

        vm.expectRevert(Distributor.FeeTooHigh.selector);
        farm.startStreamEpoch(pid, idx);

        vm.prank(src);
        farm.setPullTerms(pid, idx, 500, type(uint128).max, type(uint32).max);
        farm.startStreamEpoch(pid, idx);
        assertEq(rwd.balanceOf(fees), 5 ether, "agreed 5%");

        vm.warp(T0 + 7 days);
        vm.startPrank(admin);
        farm.setStreamFundFee(pid, idx, 2000);
        vm.expectRevert(Distributor.FeeTooHigh.selector);
        farm.startStreamEpoch(pid, idx);
        vm.stopPrank();
        assertEq(rwd.balanceOf(fees), 5 ether, "no skim above the ceiling");
        assertEq(rwd.balanceOf(src), 900 ether);
    }

    function test_L02_termsAreBoundedAndSetOnlyByTheStreamsSource() public {
        _consentingSource(1_000 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        uint256 bal = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);

        vm.prank(src);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setPullTerms(pid, idx, 2001, type(uint128).max, type(uint32).max);
        vm.prank(griefer);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setPullTerms(pid, idx, 100, type(uint128).max, type(uint32).max);
        vm.prank(manager);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setPullTerms(pid, idx, 100, type(uint128).max, type(uint32).max);
        vm.prank(src);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setPullTerms(pid, bal, 100, type(uint128).max, type(uint32).max);

        vm.prank(src);
        farm.setPullTerms(pid, idx, 2000, 3 ether, 1 days);
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        assertEq(s.pullMaxFeeBps, 2000);
        assertEq(s.pullMaxPerSec, 3 ether);
        assertEq(s.pullMaxWindow, 1 days);

        vm.prank(src);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.setPullTerms(pid, idx, 0, 1 ether, 0);
    }

    function test_R3T03_streamDrawsNothingUntilItsSourceSetsTerms() public {
        _consentingSource(1_000 ether);
        _stake(alice, 100 ether);
        uint256 live = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        uint256 epoch = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, epoch, 1);
        vm.startPrank(manager);
        farm.setStreamRate(pid, live, 1 ether);
        farm.setStreamEpochLength(pid, epoch, 1);
        vm.stopPrank();
        vm.warp(T0 + 100);
        farm.updatePool(pid);
        assertEq(rwd.balanceOf(src), 1_000 ether, "no terms, no draw");
        (,,, uint256[] memory amounts) = farm.pendingTokens(pid, alice);
        assertEq(amounts[live], 0, "and the view projects nothing");

        vm.prank(src);
        farm.setPullTerms(pid, live, 0, 1 ether, 1 days);
        farm.replaceStream(pid, live, address(rwd), Distributor.StreamKind.PULL, src, manager, 0, fees);
        vm.prank(manager);
        farm.setStreamRate(pid, live, 1 ether);
        vm.warp(T0 + 200);
        farm.updatePool(pid);
        assertEq(rwd.balanceOf(src), 1_000 ether, "the new incarnation has no terms yet");
    }

    function test_R3T01_managerChosenLengthCannotExceedTheSourcesWindow() public {
        _consentingSource(1_000_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, 1 ether, 1 hours);
        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, idx, 0);
        farm.setStreamEpochLength(pid, idx, 1_000_000);
        vm.stopPrank();
        assertEq(rwd.balanceOf(src), 1_000_000 ether - 3_600 ether, "one window of pace, not the treasury");
    }

    function test_R3T02_feeChangeAccruesFirst() public {
        _consentingSource(1_000_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.prank(manager);
        farm.setStreamRate(pid, idx, 1 ether);

        vm.warp(T0 + 1 days);
        vm.startPrank(admin);
        farm.setStreamFundFee(pid, idx, 1);
        farm.updatePool(pid);
        farm.setStreamFundFee(pid, idx, 0);
        vm.stopPrank();
        assertEq(farm.streamInfo(pid, idx).owed, 86_400 ether, "the day was accrued at the old fee");
    }

    function test_R3T04_creditEarnedAtNoFeeDoesNotShieldLaterPulls() public {
        _consentingSource(1_000 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        vm.startPrank(manager);
        farm.setStreamEpochLength(pid, idx, 1);
        vm.warp(T0 + 5);
        farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);
        vm.stopPrank();
        assertEq(farm.streamInfo(pid, idx).pullFeeCredit, 0, "no fee was ever paid on it");

        vm.prank(admin);
        farm.setStreamFundFee(pid, idx, 1000);
        vm.warp(T0 + 10);
        farm.startStreamEpoch(pid, idx);
        assertEq(rwd.balanceOf(fees), 100 ether, "the 10% fee applies");
    }

    function test_PM04_feeAcceptedOnOneStreamDoesNotCoverAnother() public {
        _consentingSource(1_000 ether);
        _stake(alice, 100 ether);
        uint256 x = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 1000);
        uint256 y = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, y, 1);
        vm.prank(src);
        farm.setPullTerms(pid, x, 1000, type(uint128).max, type(uint32).max);
        vm.prank(src);
        farm.setPullTerms(pid, y, 0, type(uint128).max, type(uint32).max);
        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, y, 100 ether);
        farm.setStreamEpochLength(pid, y, 7 days);
        vm.stopPrank();
        assertEq(rwd.balanceOf(src), 900 ether);
        assertEq(rwd.balanceOf(fees), 0);

        vm.warp(T0 + 7 days);
        vm.startPrank(admin);
        farm.setStreamFundFee(pid, y, 1000);
        vm.expectRevert(Distributor.FeeTooHigh.selector);
        farm.startStreamEpoch(pid, y);
        vm.stopPrank();
        assertEq(rwd.balanceOf(fees), 0, "Y was never opted in");
        assertEq(rwd.balanceOf(src), 900 ether);
    }

    function test_PM01_adminCannotOpenADustPeriodBySkippingTheDraw() public {
        _consentingSource(10_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, idx, 1_000 ether);
        farm.setStreamEpochMinBudget(pid, idx, 500 ether);
        farm.setStreamEpochLength(pid, idx, 30 days);
        vm.stopPrank();
        assertEq(rwd.balanceOf(src), 9_000 ether);

        vm.warp(T0 + 10 days);
        vm.prank(admin);
        farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 10 days + 1 hours);
        vm.prank(manager);
        farm.setStreamActive(pid, idx, true);

        vm.warp(T0 + 30 days);
        vm.startPrank(admin);
        farm.setStreamFundFee(pid, idx, 1);
        vm.expectRevert(Distributor.FeeTooHigh.selector);
        farm.startStreamEpoch(pid, idx);
        farm.setStreamFundFee(pid, idx, 0);
        vm.stopPrank();

        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertGt(budget, 1_000 ether);
        assertEq(rwd.balanceOf(src), 8_000 ether);
    }

    function test_PM02_recoveredReserveIsRepulledFeeFree() public {
        _consentingSource(1_000 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 500);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 500, type(uint128).max, type(uint32).max);

        for (uint256 i; i < 5; ++i) {
            vm.warp(T0 + 10 * i);
            vm.startPrank(manager);
            if (i == 0) farm.setStreamEpochLength(pid, idx, 1);
            else farm.startStreamEpoch(pid, idx);
            vm.warp(T0 + 10 * i + 5);
            farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);
            vm.stopPrank();
        }
        assertEq(rwd.balanceOf(fees), 50 ether, "the fee was taken once, not once per cycle");
        assertEq(rwd.balanceOf(src), 950 ether);
        assertEq(rwd.balanceOf(manager), 0);
    }

    function _pulledThenReturned(uint16 feeBps) internal returns (uint256 idx) {
        _consentingSource(1_000 ether);
        idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, feeBps);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 2000, type(uint128).max, type(uint32).max);
        vm.startPrank(manager);
        farm.setStreamEpochLength(pid, idx, 1);
        vm.warp(T0 + 5);
        farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);
        vm.stopPrank();
    }

    function test_R4T01_feeDipAndRestoreKeepsTheCredit() public {
        uint256 idx = _pulledThenReturned(1000);
        assertEq(rwd.balanceOf(fees), 100 ether);
        assertEq(farm.streamInfo(pid, idx).pullFeeCredit, 100 ether, "the fee value that came back");

        vm.startPrank(admin);
        farm.setStreamFundFee(pid, idx, 0);
        farm.setStreamFundFee(pid, idx, 1000);
        vm.stopPrank();
        assertEq(farm.streamInfo(pid, idx).pullFeeCredit, 100 ether, "untouched by the excursion");

        vm.warp(T0 + 10);
        farm.startStreamEpoch(pid, idx);
        assertEq(rwd.balanceOf(fees), 100 ether, "the source is not charged twice");
        assertEq(farm.streamInfo(pid, idx).reserve, 900 ether);
    }

    function test_R4T01_feeRaiseAboveCeilingAndRestoreKeepsTheCredit() public {
        uint256 idx = _pulledThenReturned(500);
        assertEq(farm.streamInfo(pid, idx).pullFeeCredit, 50 ether);
        vm.startPrank(admin);
        farm.setStreamFundFee(pid, idx, 2000);
        farm.setStreamFundFee(pid, idx, 500);
        vm.stopPrank();
        vm.warp(T0 + 10);
        farm.startStreamEpoch(pid, idx);
        assertEq(rwd.balanceOf(fees), 50 ether);
    }

    function test_R4T01_partialReturnCreditsProRata() public {
        _consentingSource(1_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 1000);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 100);

        vm.warp(T0 + 50);
        vm.prank(manager);
        farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 100);
        vm.prank(manager);
        farm.recoverStreamReserve(pid, idx, manager, type(uint256).max);
        assertEq(rwd.balanceOf(src), 450 ether, "the unemitted half returns");
        assertEq(farm.streamInfo(pid, idx).pullFeeCredit, 50 ether, "with half of the fee value");
    }

    function test_R4T02_pendingMatchesWhatAccrualCredits() public {
        _consentingSource(1_000_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 2000);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 2000, type(uint128).max, type(uint32).max);
        vm.prank(manager);
        farm.setStreamRate(pid, idx, 1 ether);

        vm.warp(T0 + 1 days);
        (,,, uint256[] memory amounts) = farm.pendingTokens(pid, alice);
        (,,, uint256[] memory rates) = farm.poolRewardsPerSec(pid);
        farm.updatePool(pid);
        assertEq(amounts[idx], 69_120 ether, "86,400 less the 20% fee");
        assertEq(farm.streamInfo(pid, idx).owed, amounts[idx], "projection == accrual");
        assertEq(rates[idx], 0.8 ether);

        vm.prank(src);
        farm.setPullTerms(pid, idx, 1000, type(uint128).max, type(uint32).max);
        vm.warp(T0 + 2 days);
        (,,, amounts) = farm.pendingTokens(pid, alice);
        (,,, rates) = farm.poolRewardsPerSec(pid);
        uint256 before = rwd.balanceOf(src);
        vm.recordLogs();
        farm.updatePool(pid);
        assertEq(vm.getRecordedLogs().length, 0, "a blocked stream is silent");
        assertEq(amounts[idx], 69_120 ether, "only what was already credited");
        assertEq(rates[idx], 0);
        assertEq(rwd.balanceOf(src), before);
    }

    function test_PM03_sourcePaceBoundLimitsEpochAndLivePulls() public {
        _consentingSource(10_000 ether);
        _stake(alice, 100 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, 1 ether, 1 days);

        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, idx, 0);
        farm.setStreamEpochLength(pid, idx, 1);
        vm.stopPrank();
        assertEq(rwd.balanceOf(src), 9_999 ether, "one second of pace, not the whole treasury");

        uint256 live = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, live, 0, 1 ether, 1 days);
        vm.prank(manager);
        farm.setStreamRate(pid, live, 1_000 ether);
        uint256 before = rwd.balanceOf(src);
        vm.warp(T0 + 100);
        farm.updatePool(pid);
        assertEq(before - rwd.balanceOf(src), 100 ether, "100 seconds at the source's pace");
    }

    function test_L03_narrowingCancelsThePendingIncrease() public {
        farm.scheduleMintRights(address(rwd), 100 ether);
        farm.setMintRights(address(rwd), 0);
        (, uint64 at) = farm.pendingMintRights(address(rwd));
        assertEq(at, 0, "cleared");
        vm.warp(T0 + 2 days);
        vm.expectRevert(Distributor.NothingScheduled.selector);
        farm.applyMintRights(address(rwd));
    }

    function test_L03_matureScheduleExpiresAfterTheWindow() public {
        farm.scheduleMintRights(address(rwd), 100 ether);
        vm.warp(T0 + 2 days + 14 days + 1);
        vm.expectRevert(Distributor.ScheduleExpired.selector);
        farm.applyMintRights(address(rwd));

        vm.warp(T0 + 30 days);
        farm.scheduleMintRights(address(rwd), 100 ether);
        vm.warp(T0 + 30 days + 2 days + 14 days);
        farm.applyMintRights(address(rwd));
        assertEq(farm.mintRights(address(rwd)), 100 ether);
    }

    function test_L03_adminCanCancelAPendingIncreaseInstantly() public {
        farm.scheduleMintRights(address(rwd), 100 ether);
        vm.prank(admin);
        farm.cancelMintRights(address(rwd));
        (, uint64 at) = farm.pendingMintRights(address(rwd));
        assertEq(at, 0, "cancelled at admin speed");
        vm.warp(T0 + 2 days);
        vm.expectRevert(Distributor.NothingScheduled.selector);
        farm.applyMintRights(address(rwd));
        vm.expectRevert(Distributor.NothingScheduled.selector);
        farm.cancelMintRights(address(rwd));
    }

    function _managedEpochStream(uint64 length, uint256 minBudget) internal returns (uint256 idx) {
        idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);
        vm.startPrank(manager);
        farm.setStreamEpochMinBudget(pid, idx, minBudget);
        farm.setStreamEpochLength(pid, idx, length);
        vm.stopPrank();
    }

    function test_R01_dustFundingQueuesBelowMinBudget() public {
        uint256 idx = _managedEpochStream(7 days, 100 ether);
        _stake(alice, 100 ether);
        rwd.mint(address(this), 1_400 ether);
        farm.fundStream(pid, idx, 700 ether);

        vm.warp(T0 + 7 days);
        vm.prank(griefer);
        farm.fundStream(pid, idx, 1);
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 7 days, "no dust period");
        vm.prank(griefer);
        vm.expectRevert(Distributor.BudgetBelowMinimum.selector);
        farm.startStreamEpoch(pid, idx);

        vm.warp(T0 + 7 days + 1 hours);
        farm.fundStream(pid, idx, 700 ether);
        (, uint64 start, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(start, T0 + 7 days + 1 hours);
        assertEq(budget, 700 ether + 1);
    }

    function test_R01_pullDustViaSourceSeedIsRejected() public {
        vm.startPrank(src);
        farm.setPullSource(true);
        rwd.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        rwd.mint(src, 700 ether);
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.PULL, src, manager, 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.startPrank(manager);
        farm.setStreamEpochPull(pid, idx, 700 ether);
        farm.setStreamEpochMinBudget(pid, idx, 100 ether);
        farm.setStreamEpochLength(pid, idx, 7 days);
        vm.stopPrank();
        _stake(alice, 100 ether);

        vm.warp(T0 + 7 days);
        vm.prank(griefer);
        rwd.transfer(src, 1);
        vm.prank(griefer);
        vm.expectRevert(Distributor.BudgetBelowMinimum.selector);
        farm.startStreamEpoch(pid, idx);
        vm.warp(T0 + 7 days);
        assertEq(rwd.balanceOf(src), 1);

        rwd.mint(src, 700 ether);
        vm.prank(griefer);
        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 700 ether);
    }

    function test_R01_operatorsMayStartBelowMinBudget() public {
        uint256 idx = _managedEpochStream(100, 100 ether);
        rwd.mint(address(this), 1);
        farm.fundStream(pid, idx, 1);
        vm.prank(griefer);
        vm.expectRevert(Distributor.BudgetBelowMinimum.selector);
        farm.startStreamEpoch(pid, idx);
        vm.prank(manager);
        farm.startStreamEpoch(pid, idx);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 1);
    }

    function test_R01_penaltyInflowBelowMinBudgetQueues() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        uint256 hpid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        uint256 idx = farm.addStream(hpid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);
        vm.startPrank(manager);
        farm.setStreamEpochMinBudget(hpid, idx, 100 ether);
        farm.setStreamEpochLength(hpid, idx, 100);
        vm.stopPrank();
        rwd.mint(address(hook), 300 ether);
        vm.startPrank(address(hook));
        rwd.approve(address(farm), type(uint256).max);
        farm.notifyReward(address(rwd), 1);
        (,, uint256 budget,) = farm.streamEpochs(hpid, idx);
        assertEq(budget, 0);
        farm.notifyReward(address(rwd), 200 ether);
        vm.stopPrank();
        (,, budget,) = farm.streamEpochs(hpid, idx);
        assertEq(budget, 200 ether + 1);
    }

    function test_R01_legacyPreseedNoLongerAutoStartsADustPeriod() public {
        uint256 idx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), manager, 0);
        vm.prank(manager);
        farm.setStreamEpochMinBudget(pid, idx, 100 ether);
        vm.prank(griefer);
        farm.fundStream(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 7 days);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 0);
        rwd.mint(address(this), 700 ether);
        farm.fundStream(pid, idx, 700 ether);
        (,, budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 700 ether + 1);
    }

    function test_R02_lengthQueuedMidEpochBeatsThePermissionlessStart() public {
        uint256 idx = _managedEpochStream(30 days, 1);
        _stake(alice, 100 ether);
        rwd.mint(address(this), 3_000 ether);
        farm.fundStream(pid, idx, 1_000 ether);
        farm.fundStream(pid, idx, 2_000 ether);

        vm.warp(T0 + 10 days);
        vm.expectEmit(true, true, false, true, address(farm));
        emit Distributor.StreamEpochLengthQueued(pid, idx, 7 days);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 7 days);
        (uint64 len,,,) = farm.streamEpochs(pid, idx);
        assertEq(len, 30 days, "running period untouched");
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 30 days);

        vm.warp(T0 + 30 days);
        vm.prank(griefer);
        farm.startStreamEpoch(pid, idx);
        (len,,,) = farm.streamEpochs(pid, idx);
        assertEq(len, 7 days, "queued length applied at the next start");
        assertEq(farm.streamInfo(pid, idx).emissionEnd, T0 + 37 days);
        assertEq(farm.streamInfo(pid, idx).epochLength, 7 days, "slot mirror in sync");
    }

    function test_R04_roundingNeverPaysMoreThanWasDebited() public {
        MockERC20 r = new MockERC20("R", "R", 18);
        lp.mint(bob, 1);
        lp.mint(carol, 1);
        vm.prank(bob); lp.approve(address(farm), type(uint256).max);
        vm.prank(carol); lp.approve(address(farm), type(uint256).max);
        uint256 idx = farm.addStream(pid, address(r), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        r.mint(address(this), 900);
        r.approve(address(farm), 900);
        farm.setStreamEpochLength(pid, idx, 100);
        farm.fundStream(pid, idx, 900);
        _stake(alice, 10);

        vm.warp(T0 + 31);
        vm.prank(alice); farm.withdraw(pid, 10);
        _stake(bob, 1);
        _stake(carol, 1);
        assertEq(farm.rewardDebt(pid, bob, idx), 28, "debt rounds up");

        vm.warp(T0 + 62);
        vm.prank(bob); farm.withdraw(pid, 0);
        vm.prank(carol); farm.withdraw(pid, 0);
        assertEq(r.balanceOf(bob), 139, "never above the exact 139.5");
        assertEq(r.balanceOf(carol), 139);
        uint256 held = r.balanceOf(address(farm));
        assertLe(farm.streamInfo(pid, idx).reserve, held, "reserve never overstates holdings");

        farm.setStreamActive(pid, idx, false);
        vm.warp(T0 + 100);
        farm.recoverStreamReserve(pid, idx, fees, type(uint256).max);
        assertEq(r.balanceOf(fees), 342);
    }

    function test_R04_recoverClampsToFreeBalanceAndNeverTakesPrincipal() public {
        uint256 idx = farm.addStream(pid, address(lp), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        _stake(alice, 100 ether);
        lp.mint(address(this), 50 ether);
        lp.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, idx, 50 ether);
        lp.burn(address(farm), 20 ether);
        farm.recoverStreamReserve(pid, idx, fees, type(uint256).max);
        assertEq(lp.balanceOf(fees), 30 ether, "clamped to held minus principal");
        vm.prank(alice);
        farm.withdraw(pid, 100 ether);
        assertEq(lp.balanceOf(alice), 1_000 ether, "principal intact");
    }

    function test_G2_packedStakeAmountIsBounded() public {
        lp.mint(bob, uint256(1) << 192);
        vm.startPrank(bob);
        lp.approve(address(farm), type(uint256).max);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        farm.deposit(pid, uint256(1) << 192);
        farm.deposit(pid, (uint256(1) << 192) - 1);
        vm.stopPrank();
        (uint256 amt,,,) = farm.userInfo(pid, bob);
        assertEq(amt, (uint256(1) << 192) - 1);
    }

    function test_G1_epochLengthMirrorFollowsEveryWriter() public {
        uint256 idx = _managedEpochStream(100, 0);
        assertEq(farm.streamInfo(pid, idx).epochLength, 100);
        rwd.mint(address(this), 1);
        farm.fundStream(pid, idx, 1);
        vm.prank(manager);
        farm.setStreamEpochLength(pid, idx, 50);
        assertEq(farm.streamInfo(pid, idx).epochLength, 100);
        vm.warp(T0 + 100);
        rwd.mint(address(this), 1 ether);
        farm.fundStream(pid, idx, 1 ether);
        assertEq(farm.streamInfo(pid, idx).epochLength, 50);
        farm.replaceStream(pid, idx, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0, fees);
        assertEq(farm.streamInfo(pid, idx).epochLength, 0, "replacement returns to manual mode");
        farm.setStreamRate(pid, idx, 1);
    }
}

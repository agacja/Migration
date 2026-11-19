// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {EscrowedToken} from "../src/token/EscrowedToken.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {MockERC20} from "./Mocks.sol";

contract FarmEsToken is EscrowedToken {
    constructor(address owner_, IALB underlying_)
        EscrowedToken(owner_, underlying_, 30 days, 60 days, 8500, 7000, 20_000, 48 hours)
    {}

    function name() public pure override returns (string memory) { return "Farm Escrowed Token"; }
    function symbol() public pure override returns (string memory) { return "fesT"; }
    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256(bytes("Farm Escrowed Token"));
    }

    function depositFor(address to, uint256 amount) external {
        _depositFor(to, amount);
    }
}

contract FarmEscrowTest is Test {
    uint64 internal constant T0 = 1_700_000_000;

    address internal fees = makeAddr("fees");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Distributor internal farm;
    MockERC20 internal underlying;
    MockERC20 internal rwd;
    FarmEsToken internal esc;
    uint256 internal pid;
    uint256 internal penaltyIdx;
    uint256 internal rwdIdx;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
        underlying = new MockERC20("Partner Token", "PTN", 18);
        rwd = new MockERC20("Reward", "RWD", 18);
        esc = new FarmEsToken(address(this), IALB(address(underlying)));

        esc.setStaking(IStakingContract(address(farm)));
        pid = farm.addPool(address(esc), Distributor.PoolKind.HOOK);
        penaltyIdx = farm.addStream(pid, address(underlying), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(pid, penaltyIdx, 0.01 ether);
        rwdIdx = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamRate(pid, rwdIdx, 1 ether);
        rwd.mint(address(this), 1_000_000 ether);
        rwd.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, rwdIdx, 1_000_000 ether);
    }

    function _deposit(address user, uint256 amt) internal {
        underlying.mint(user, amt);
        vm.startPrank(user);
        underlying.approve(address(esc), amt);
        esc.depositFor(user, amt);
        vm.stopPrank();
    }

    function _stake(address user) internal view returns (uint256 amt) {
        (amt,,,) = farm.userInfo(pid, user);
    }

    function test_probeOnlyPassesForTheBoundFarm() public {
        Distributor other = new Distributor(address(this), fees);
        vm.expectRevert(Distributor.NotHookToken.selector);
        other.addPool(address(esc), Distributor.PoolKind.HOOK);
    }

    function test_depositMirrorsIntoFarmStake() public {
        _deposit(alice, 100 ether);
        assertEq(_stake(alice), 100 ether, "mint hook mirrored into farm stake");
        assertEq(farm.poolTotalLp(pid), 100 ether);
    }

    function test_fullLifecycleMirrorsStakedShares() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);

        vm.warp(T0 + 100);
        uint256[] memory pids = new uint256[](1);
        pids[0] = pid;
        vm.prank(alice);
        farm.harvestMany(pids);
        assertEq(rwd.balanceOf(alice), 50 ether, "half the emission");

        vm.prank(alice);
        esc.startUnstake(100 ether);
        assertEq(_stake(alice), 70 ether, "partial power mirrored");
        assertEq(esc.stakedSharesOf(alice), 70 ether, "farm stake == stakedSharesOf");

        vm.prank(alice);
        esc.cancelUnstake(0);
        assertEq(_stake(alice), 100 ether);

        vm.prank(alice);
        esc.instantRedeem(2 ether);
        assertEq(_stake(alice), 98 ether);
        assertEq(underlying.balanceOf(alice), 2 ether);
    }

    function test_syncStakeCannotStripVestingPartialPower() public {
        _deposit(alice, 100 ether);
        vm.prank(alice);
        esc.startUnstake(100 ether);
        assertEq(esc.balanceOf(alice), 0, "balance moved to custody");
        assertEq(_stake(alice), 70 ether, "partial power live");

        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.syncStake(pid, alice);
    }

    function test_finalizePenaltyFundsTheUnderlyingStream() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        vm.prank(alice);
        esc.startUnstake(100 ether);

        vm.warp(T0 + 30 days);
        (,,, uint256 reserveBefore,) = _streamSlim(penaltyIdx);
        vm.prank(alice);
        esc.finalizeUnstake(0);
        assertEq(underlying.balanceOf(alice), 85 ether, "85% at the floor");
        (,,, uint256 reserveAfter,) = _streamSlim(penaltyIdx);
        assertEq(reserveAfter - reserveBefore, 15 ether, "penalty credited to the pool's stream");
        assertEq(_stake(alice), 0, "position fully unmirrored");
    }

    function test_penaltySinkBypassesRedistribution() public {
        address treasury = makeAddr("treasury");
        esc.setPenaltySink(treasury);
        _deposit(alice, 100 ether);
        vm.prank(alice);
        esc.startUnstake(100 ether);

        vm.warp(T0 + 30 days);
        (,,, uint256 reserveBefore,) = _streamSlim(penaltyIdx);
        vm.prank(alice);
        esc.finalizeUnstake(0);
        assertEq(underlying.balanceOf(alice), 85 ether);
        assertEq(underlying.balanceOf(treasury), 15 ether, "penalty routed to the sink");
        (,,, uint256 reserveAfter,) = _streamSlim(penaltyIdx);
        assertEq(reserveAfter, reserveBefore, "no notifyReward interaction");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        esc.setPenaltySink(address(0));
        vm.expectRevert(EscrowedToken.InvalidParams.selector);
        esc.setPenaltySink(address(esc));
        esc.setPenaltySink(address(0));
    }

    function test_notifyRewardOnlyFromHookTokens() public {
        underlying.mint(address(this), 1 ether);
        underlying.approve(address(farm), 1 ether);
        vm.expectRevert(Distributor.NotHookToken.selector);
        farm.notifyReward(address(underlying), 1 ether);
    }

    function _streamSlim(uint256 idx)
        internal
        view
        returns (address token, uint128 rate, uint64 end, uint256 reserve, uint256 acc)
    {
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        return (s.token, s.ratePerSec, s.emissionEnd, s.reserve, s.accPerShare);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {MockERC20} from "./Mocks.sol";

contract PausableRewardToken is MockERC20 {
    bool public paused;
    constructor() MockERC20("Pausable", "PSE", 18) {}
    function setPaused(bool p) external { paused = p; }
    function transfer(address to, uint256 a) public override returns (bool) {
        require(!paused, "paused");
        return super.transfer(to, a);
    }
}

contract DistributorReviewFixesTest is Test {
    uint256 internal constant T0 = 1_800_000_000;

    address internal fees = makeAddr("fees");
    address internal partner = makeAddr("partner");
    address internal alice = makeAddr("alice");
    address internal sink = makeAddr("sink");
    Distributor internal farm;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
    }

    function _pool(MockERC20 stake, uint256 amount) internal returns (uint256 pid) {
        pid = farm.addPool(address(stake), Distributor.PoolKind.DEPOSIT);
        stake.mint(alice, amount);
        vm.startPrank(alice);
        stake.approve(address(farm), type(uint256).max);
        farm.deposit(pid, amount);
        vm.stopPrank();
    }

    function test_absurdRewardSupplyCannotBrickThePool() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 ptok = new MockERC20("Partner", "PTK", 18);
        uint256 pid = _pool(usdc, 1_000_000e6);
        uint256 idx = farm.addStream(pid, address(ptok), Distributor.StreamKind.BALANCE, address(0), partner, 0);

        uint256 huge = uint256(1) << 255;
        ptok.mint(partner, huge);
        vm.startPrank(partner);
        ptok.approve(address(farm), type(uint256).max);
        farm.setStreamEpochLength(pid, idx, 1 days);
        farm.fundStream(pid, idx, huge);
        vm.stopPrank();

        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, uint256(type(uint128).max) * 1 days, "period budget is bounded");

        vm.warp(T0 + 1 days);
        farm.updatePool(pid);
        assertEq(farm.streamInfo(pid, idx).reserve, huge - budget, "excess stays queued in the reserve");
        vm.prank(alice);
        farm.withdraw(pid, 1_000_000e6);
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "principal exits");
        farm.setStreamActive(pid, idx, false);
    }

    function test_lowDecimalsRewardAccruesUnderFrequentUpdates() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        uint256 pid = _pool(lp, 1_000_000 ether);
        uint256 idx = farm.addStream(pid, address(usdc), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.setStreamEpochLength(pid, idx, 7 days);
        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, idx, 50_000e6);

        for (uint256 i = 1; i <= 300; ++i) {
            vm.warp(T0 + 2 * i);
            farm.updatePool(pid);
        }
        (,,, uint256[] memory amounts) = farm.pendingTokens(pid, alice);
        uint256 expected = uint256(50_000e6) * 600 / 7 days;
        assertApproxEqAbs(amounts[idx], expected, 1, "every update credits its share");
        assertGt(expected, 49e6);
    }

    function test_failedResidualSweepIsBookedAndRetryable() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        PausableRewardToken old = new PausableRewardToken();
        MockERC20 next = new MockERC20("Next", "NXT", 18);
        uint256 pid = _pool(lp, 100 ether);
        uint256 idx = farm.addStream(pid, address(old), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        old.mint(address(this), 1_000 ether);
        old.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, idx, 1_000 ether);

        old.setPaused(true);
        farm.replaceStream(pid, idx, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        assertEq(farm.unsweptResidual(address(old)), 1_000 ether, "booked, not stranded");
        assertEq(old.balanceOf(sink), 0);

        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.sweepResidual(address(old), sink, type(uint256).max);
        assertEq(farm.unsweptResidual(address(old)), 1_000 ether);

        old.setPaused(false);
        vm.prank(alice);
        vm.expectRevert();
        farm.sweepResidual(address(old), alice, type(uint256).max);
        farm.sweepResidual(address(old), sink, type(uint256).max);
        assertEq(old.balanceOf(sink), 1_000 ether);
        assertEq(farm.unsweptResidual(address(old)), 0);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.sweepResidual(address(old), sink, type(uint256).max);
    }
}

contract RuggableToken is ERC20 {
    address public farm;
    uint256 public inflateBy;
    bool public burnOnArrival;
    uint256 public lastArrival;

    function name() public pure override returns (string memory) { return "Partner"; }
    function symbol() public pure override returns (string memory) { return "PTN"; }

    function rug(address farm_, uint256 inflateBy_, bool burn_) external {
        farm = farm_;
        inflateBy = inflateBy_;
        burnOnArrival = burn_;
    }

    function _arrive(address to) internal {
        if (to != farm) return;
        if (burnOnArrival) { assembly { for {} 1 {} {} } }
        lastArrival = block.timestamp;
    }

    function balanceOf(address a) public view override returns (uint256) {
        uint256 real = super.balanceOf(a);
        if (inflateBy != 0 && a == farm && lastArrival == block.timestamp) return real + inflateBy;
        return real;
    }

    function mint(address to, uint256 amount) external {
        _arrive(to);
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        _arrive(to);
        return super.transferFrom(from, to, amt);
    }
}

contract HeavyRegistry {
    uint256 public burn;
    function setBurn(uint256 b) external { burn = b; }
    function check(address, address, uint256) external view returns (bool) {
        uint256 n = burn;
        if (n != 0) {
            uint256 g = gasleft();
            while (g - gasleft() < n) {}
        }
        return true;
    }
}

contract HeavyHonestToken is ERC20 {
    uint256 public tfBurn;
    address public registry;

    function name() public pure override returns (string memory) { return "Heavy"; }
    function symbol() public pure override returns (string memory) { return "HVY"; }
    function setBurn(uint256 tf) external { tfBurn = tf; }
    function setRegistry(address r) external { registry = r; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        uint256 n = tfBurn;
        if (n != 0) {
            uint256 g = gasleft();
            while (g - gasleft() < n) {}
        }
        address r = registry;
        if (r != address(0)) require(HeavyRegistry(r).check(from, to, amt), "restricted");
        return super.transferFrom(from, to, amt);
    }
}

contract ForwardingProxy {
    bytes32 internal constant IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    constructor(address impl) { assembly { sstore(IMPL, impl) } }
    fallback() external payable {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), sload(IMPL), 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract DistributorAccrualIoFixesTest is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    address internal fees = makeAddr("fees");
    address internal admin = makeAddr("admin");
    address internal src = makeAddr("src");
    address internal alice = makeAddr("alice");
    address internal sink = makeAddr("sink");
    Distributor internal farm;
    MockERC20 internal lp;
    uint256 internal pid;

    function setUp() public {
        vm.warp(T0);
        farm = new Distributor(address(this), fees);
        farm.grantRoles(admin, farm.ROLE_ADMIN());
        lp = new MockERC20("LP", "LP", 18);
        pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        lp.mint(alice, 200 ether);
        vm.startPrank(alice);
        lp.approve(address(farm), type(uint256).max);
        farm.deposit(pid, 200 ether);
        vm.stopPrank();
    }

    function _livePull(RuggableToken t) internal returns (uint256 idx) {
        t.mint(src, 1_000_000 ether);
        vm.startPrank(src);
        farm.setPullSource(true);
        t.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        idx = farm.addStream(pid, address(t), Distributor.StreamKind.PULL, src, address(0), 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        farm.setStreamRate(pid, idx, 1 ether);
    }

    function _liveMint(RuggableToken t) internal returns (uint256 idx) {
        farm.scheduleMintRights(address(t), 1 ether);
        vm.warp(T0 + 2 days);
        farm.applyMintRights(address(t));
        idx = farm.addStream(pid, address(t), Distributor.StreamKind.MINT, address(0), address(0), 0);
        farm.setStreamRate(pid, idx, 1 ether);
    }

    function test_lyingBalanceDeltaIsClampedToWhatWasAskedFor_pull() public {
        RuggableToken t = new RuggableToken();
        uint256 idx = _livePull(t);
        t.rug(address(farm), type(uint256).max / 4, false);

        vm.warp(T0 + 100);
        farm.updatePool(pid);
        Distributor.Stream memory s = farm.streamInfo(pid, idx);
        assertEq(s.owed, 100 ether, "booked what was asked for, not what the token claims");

        vm.prank(alice);
        farm.withdraw(pid, 200 ether);
        assertEq(lp.balanceOf(alice), 200 ether, "principal exits");
        vm.prank(admin);
        farm.setStreamActive(pid, idx, false);
    }

    function test_lyingBalanceDeltaIsClampedToWhatWasAskedFor_mint() public {
        RuggableToken t = new RuggableToken();
        uint256 idx = _liveMint(t);
        t.rug(address(farm), type(uint256).max / 4, false);

        vm.warp(T0 + 2 days + 100);
        farm.updatePool(pid);
        assertEq(farm.streamInfo(pid, idx).owed, 100 ether);
        vm.prank(admin);
        farm.setStreamActive(pid, idx, false);
    }

    function test_lyingBalanceDeltaIsClampedOnAnEpochPull() public {
        RuggableToken t = new RuggableToken();
        t.mint(src, 1_000 ether);
        vm.startPrank(src);
        farm.setPullSource(true);
        t.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        uint256 idx = farm.addStream(pid, address(t), Distributor.StreamKind.PULL, src, address(0), 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        farm.setStreamEpochMinBudget(pid, idx, 1);
        farm.setStreamEpochPull(pid, idx, 100 ether);
        t.rug(address(farm), 1e30, false);
        farm.setStreamEpochLength(pid, idx, 7 days);
        (,, uint256 budget,) = farm.streamEpochs(pid, idx);
        assertEq(budget, 100 ether, "the period's budget is what was pulled");
    }

    function test_gasBurningRealiseCannotStarveWithdrawOrTheStopLever() public {
        RuggableToken a = new RuggableToken();
        RuggableToken b = new RuggableToken();
        uint256 ia = _livePull(a);
        uint256 ib = _livePull(b);
        a.rug(address(farm), 0, true);
        b.rug(address(farm), 0, true);

        vm.warp(T0 + 100);
        vm.prank(admin);
        (bool ok,) = address(farm).call{gas: 2_000_000}(abi.encodeCall(farm.setStreamActive, (pid, ia, false)));
        assertTrue(ok, "pause fits in 2M gas");
        vm.prank(alice);
        (ok,) = address(farm).call{gas: TX_GAS_CAP}(abi.encodeCall(farm.withdraw, (pid, 200 ether)));
        assertTrue(ok, "withdraw fits under the per-transaction cap");
        assertEq(lp.balanceOf(alice), 200 ether);
        assertEq(farm.streamInfo(pid, ib).owed, 0, "a burned call realises nothing");
    }

    function _assertNoForfeitWindow(HeavyHonestToken t, uint256 lo, uint256 hi) internal {
        t.mint(src, 1_000_000 ether);
        vm.startPrank(src);
        farm.setPullSource(true);
        t.approve(address(farm), type(uint256).max);
        vm.stopPrank();
        uint256 idx = farm.addStream(pid, address(t), Distributor.StreamKind.PULL, src, address(0), 0);
        vm.prank(src);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        farm.setStreamRate(pid, idx, 1 ether);

        vm.warp(T0 + 100);
        bytes memory op = abi.encodeCall(farm.updatePool, (pid));
        uint256 completed;
        uint256 reverted;
        for (uint256 g = lo; g <= hi; g += 500) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(farm).call{gas: g}(op);
            if (ok) {
                assertEq(farm.streamInfo(pid, idx).owed, 100 ether, "accrual completed without the pull");
                ++completed;
            } else {
                ++reverted;
            }
            vm.revertToState(snap);
        }
        assertGt(completed, 0, "high gas exercised");
        assertGt(reverted, 0, "low gas exercised");
    }

    function test_underSuppliedGasCannotForfeitAnInterval_flatToken() public {
        HeavyHonestToken t = new HeavyHonestToken();
        t.setBurn(250_000);
        _assertNoForfeitWindow(t, 30_000, 700_000);
    }

    function test_underSuppliedGasCannotForfeitAnInterval_proxiedToken() public {
        HeavyHonestToken t = HeavyHonestToken(address(new ForwardingProxy(address(new HeavyHonestToken()))));
        t.setBurn(250_000);
        _assertNoForfeitWindow(t, 30_000, 700_000);
    }

    function test_underSuppliedGasCannotForfeitAnInterval_threeFrames() public {
        HeavyHonestToken t = HeavyHonestToken(address(new ForwardingProxy(address(new HeavyHonestToken()))));
        HeavyRegistry r = HeavyRegistry(address(new ForwardingProxy(address(new HeavyRegistry()))));
        r.setBurn(150_000);
        t.setRegistry(address(r));
        _assertNoForfeitWindow(t, 30_000, 700_000);
    }

    function test_residualIsBookedOnceAndSweptInParts() public {
        PausableRewardToken x = new PausableRewardToken();
        MockERC20 next = new MockERC20("Next", "NXT", 18);
        uint256 a = farm.addStream(pid, address(x), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        uint256 b = farm.addStream(pid, address(x), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        x.mint(address(this), 200 ether);
        x.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, a, 100 ether);
        farm.fundStream(pid, b, 100 ether);

        vm.prank(address(farm));
        x.transfer(address(0xdead), 100 ether);
        x.setPaused(true);
        farm.replaceStream(pid, a, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        farm.replaceStream(pid, b, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        assertEq(farm.unsweptResidual(address(x)), 100 ether, "the same balance is not booked twice");

        x.setPaused(false);
        farm.sweepResidual(address(x), sink, 40 ether);
        assertEq(x.balanceOf(sink), 40 ether);
        assertEq(farm.unsweptResidual(address(x)), 60 ether);
        farm.sweepResidual(address(x), sink, type(uint256).max);
        assertEq(x.balanceOf(sink), 100 ether);
        assertEq(farm.unsweptResidual(address(x)), 0);
    }

    function test_farmIsRejectedAsResidualRecipient() public {
        PausableRewardToken x = new PausableRewardToken();
        MockERC20 next = new MockERC20("Next", "NXT", 18);
        uint256 a = farm.addStream(pid, address(x), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        x.mint(address(this), 100 ether);
        x.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, a, 100 ether);

        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.replaceStream(
            pid, a, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, address(farm)
        );
        x.setPaused(true);
        farm.replaceStream(pid, a, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        x.setPaused(false);
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.sweepResidual(address(x), address(farm), type(uint256).max);
        assertEq(farm.unsweptResidual(address(x)), 100 ether, "still on the book");
    }

    function test_partialSweepWritesOffMissingBalance() public {
        PausableRewardToken x = new PausableRewardToken();
        MockERC20 next = new MockERC20("Next", "NXT", 18);
        uint256 a = farm.addStream(pid, address(x), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        x.mint(address(this), 1_500 ether);
        x.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, a, 1_000 ether);
        x.setPaused(true);
        farm.replaceStream(pid, a, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        assertEq(farm.unsweptResidual(address(x)), 1_000 ether);

        x.setPaused(false);
        vm.prank(address(farm));
        x.transfer(address(0xdead), 500 ether);
        farm.sweepResidual(address(x), sink, 500 ether);
        assertEq(farm.unsweptResidual(address(x)), 0, "no claim is kept on missing balance");

        uint256 b = farm.addStream(pid, address(x), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.fundStream(pid, b, 500 ether);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.sweepResidual(address(x), sink, type(uint256).max);
        assertEq(x.balanceOf(address(farm)), 500 ether);
    }

    function test_missingBalanceIsNotBookedAsResidual() public {
        MockERC20 rwd = new MockERC20("RWD", "RWD", 18);
        MockERC20 next = new MockERC20("Next", "NXT", 18);
        uint256 a = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        rwd.mint(address(this), 150 ether);
        rwd.approve(address(farm), type(uint256).max);
        farm.fundStream(pid, a, 100 ether);

        vm.prank(address(farm));
        rwd.transfer(address(0xdead), 10 ether);

        farm.replaceStream(pid, a, address(next), Distributor.StreamKind.BALANCE, address(0), address(0), 0, sink);
        assertEq(rwd.balanceOf(sink), 90 ether, "what the farm held was swept");
        assertEq(farm.unsweptResidual(address(rwd)), 0, "the missing part is not booked");

        uint256 b = farm.addStream(pid, address(rwd), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        farm.fundStream(pid, b, 50 ether);
        vm.expectRevert(Distributor.NothingToDo.selector);
        farm.sweepResidual(address(rwd), sink, type(uint256).max);
        assertEq(rwd.balanceOf(address(farm)), 50 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BunniFeeDistributor} from "../src/fees/BunniFeeDistributor.sol";
import {BunniKey, IUniswapV3PoolLite} from "../src/interfaces/IBunniHub.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {MockERC20} from "./Mocks.sol";
import {MockBunniPool, MockBunniHub} from "./MocksBunni.sol";

contract BunniFeeDistributorTest is Test {
    uint256 constant DELAY = 7 days;

    MockERC20 t0;
    MockERC20 t1;
    MockBunniPool pool;
    MockBunniHub hub;
    StakingContract farm;
    BunniFeeDistributor dist;

    BunniKey key;
    BunniKey key2;
    bytes32 kh;

    address admin = makeAddr("admin");
    address referrer = makeAddr("referrer");
    address attributor = makeAddr("attributor");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");
    address treasury = makeAddr("treasury");

    function setUp() public {
        t0 = new MockERC20("Wrapped Ether", "WETH", 18);
        t1 = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockBunniPool(address(t0), address(t1));
        pool.setPosition(1e18, 0, 0, 0, 0);

        key = BunniKey({pool: IUniswapV3PoolLite(address(pool)), tickLower: -100, tickUpper: 100});
        key2 = BunniKey({pool: IUniswapV3PoolLite(address(pool)), tickLower: -200, tickUpper: 200});
        kh = keccak256(abi.encode(key.pool, key.tickLower, key.tickUpper));

        hub = new MockBunniHub();
        hub.setProtocolFee(1e18);

        dist = new BunniFeeDistributor(address(this), address(hub), admin, attributor, 6000, 3000, 1000);
        hub.transferOwnership(address(dist));

        farm = _newFarm(address(t1), address(t0));
        farm.setNotifier(address(dist), true);

        _exec(
            keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key, address(farm))),
            abi.encodeCall(dist.setFeeFarm, (key, address(farm)))
        );
        _exec(
            keccak256(abi.encode(dist.setReferrer.selector, "setReferrer", kh, referrer)),
            abi.encodeCall(dist.setReferrer, (kh, referrer))
        );
    }

    function _newFarm(address alb, address weth) internal returns (StakingContract) {
        return new StakingContract(address(this), IALB(alb), makeAddr("esALB"), makeAddr("govALB"), weth);
    }

    function _exec(bytes32 id, bytes memory data) internal {
        dist.queueAction(id);
        vm.warp(block.timestamp + DELAY);
        (bool ok, bytes memory ret) = address(dist).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _accrue(uint128 a0, uint128 a1) internal {
        if (a0 > 0) t0.mint(address(pool), a0);
        if (a1 > 0) t1.mint(address(pool), a1);
        pool.addOwed(a0, a1);
    }

    function _keys() internal view returns (BunniKey[] memory ks) {
        ks = new BunniKey[](1);
        ks[0] = key;
    }

    function _claim() internal {
        vm.prank(keeper);
        dist.claim(_keys());
    }

    function _stream(address token) internal view returns (uint64 windowEnd, uint128 ratePerSec) {
        (, , windowEnd, , , , ratePerSec, ) = farm.streams(token);
    }

    struct Split {
        uint256 bounty;
        uint256 lp;
        uint256 protocol;
        uint256 ref;
    }

    function _split(uint256 amount, uint16 bountyPct) internal pure returns (Split memory s) {
        s.bounty = (amount * bountyPct) / 10_000;
        uint256 rem = amount - s.bounty;
        s.lp = (rem * 6000) / 10_000;
        s.protocol = (rem * 3000) / 10_000;
        s.ref = rem - s.lp - s.protocol;
    }

    function test_claimMeasuresAndSplitsExactly() public {
        _accrue(1000e18, 500e6);

        Split memory s0 = _split(1000e18, 25);
        Split memory s1 = _split(500e6, 25);

        vm.expectEmit(true, true, true, true);
        emit BunniFeeDistributor.LpNotified(kh, address(farm), address(t0), s0.lp);
        _claim();

        assertEq(t0.balanceOf(keeper), s0.bounty, "bounty0");
        assertEq(t1.balanceOf(keeper), s1.bounty, "bounty1");
        assertEq(t0.balanceOf(admin), s0.protocol, "protocol0");
        assertEq(t1.balanceOf(admin), s1.protocol, "protocol1");
        assertEq(t0.balanceOf(referrer), s0.ref, "ref0");
        assertEq(t1.balanceOf(referrer), s1.ref, "ref1");

        assertEq(t0.balanceOf(address(farm)), s0.lp, "farm0");
        assertEq(t1.balanceOf(address(farm)), s1.lp, "farm1");
        assertEq(farm.trackedBalance(address(t0)), s0.lp);
        (uint64 windowEnd, uint128 rate) = _stream(address(t0));
        assertEq(windowEnd, block.timestamp + 7 days, "fresh 7d window");
        assertEq(rate, s0.lp / 7 days, "rate over the window");

        assertEq(dist.lpPending(kh, address(t0)), 0);
        assertEq(dist.lpPendingTotal(address(t0)), 0);
        assertEq(dist.unattributed(address(t0)), 0);
        assertEq(dist.unattributed(address(t1)), 0);
        assertEq(t0.balanceOf(address(dist)), 0, "dist holds nothing");
        assertEq(t0.balanceOf(address(hub)), 0);
        assertEq(pool.owed0(), 0);
        assertEq(pool.owed1(), 0);
        assertEq(t0.allowance(address(dist), address(farm)), 0, "no lingering allowance");
    }

    function test_repeatedClaimsRaiseTheCurrentWindowRate() public {
        _accrue(100e18, 0);
        _claim();
        (uint64 end1, uint128 rate1) = _stream(address(t0));

        vm.warp(block.timestamp + 1 hours);
        _accrue(40e18, 0);
        _claim();
        (uint64 end2, uint128 rate2) = _stream(address(t0));

        vm.warp(block.timestamp + 1 hours);
        _accrue(7, 0);
        _claim();

        assertEq(end2, end1, "same window");
        assertGt(rate2, rate1, "rate raised for the rest of the window");
        uint256 expected = _split(100e18, 25).lp + _split(40e18, 25).lp + _split(7, 25).lp;
        assertEq(t0.balanceOf(address(farm)), expected);
        assertEq(dist.lpPending(kh, address(t0)), 0);
    }

    function test_claimSkipsUnregisteredKeyWithoutReverting() public {
        _accrue(100e18, 0);
        BunniKey[] memory ks = new BunniKey[](2);
        ks[0] = key2;
        ks[1] = key;

        bytes32 kh2 = keccak256(abi.encode(key2.pool, key2.tickLower, key2.tickUpper));
        vm.expectEmit(true, false, false, true);
        emit BunniFeeDistributor.ClaimSkipped(kh2, "fee farm not set");

        vm.prank(keeper);
        dist.claim(ks);

        assertEq(pool.owed0(), 0);
        assertEq(t0.balanceOf(keeper), _split(100e18, 25).bounty);
    }

    function test_claimSkipsZeroLiquidity() public {
        _accrue(100e18, 0);
        pool.setPosition(0, 0, 0, 100e18, 0);

        vm.expectEmit(true, false, false, true);
        emit BunniFeeDistributor.ClaimSkipped(kh, "no liquidity");
        _claim();

        assertEq(pool.owed0(), 100e18, "nothing collected");
        assertEq(t0.balanceOf(keeper), 0);
    }

    function test_claimSkipsWhenNothingOwed() public {
        vm.expectEmit(true, false, false, true);
        emit BunniFeeDistributor.ClaimSkipped(kh, "no fees");
        _claim();
    }

    function test_thirdPartyCompoundIsBookedAsUnattributed() public {
        _accrue(1000e18, 500e6);

        vm.prank(attacker);
        hub.compound(key);
        assertEq(t0.balanceOf(address(hub)), 500e18);

        vm.expectEmit(true, false, false, true);
        emit BunniFeeDistributor.SurplusBooked(address(t0), 500e18);
        _claim();

        Split memory s0 = _split(500e18, 25);
        assertEq(t0.balanceOf(keeper), s0.bounty);
        assertEq(t0.balanceOf(admin), s0.protocol);
        assertEq(t0.balanceOf(referrer), s0.ref);
        assertEq(t0.balanceOf(address(farm)), s0.lp);

        assertEq(dist.unattributed(address(t0)), 500e18);
        assertEq(dist.unattributed(address(t1)), 250e6);
        assertEq(t0.balanceOf(address(dist)), 500e18);
        assertEq(t0.balanceOf(address(hub)), 0);
    }

    function test_otherKeysSurplusIsNotPaidToClaimedKey() public {
        t0.mint(address(hub), 100e18);
        _accrue(10e18, 0);
        _claim();

        Split memory s0 = _split(10e18, 25);
        assertEq(t0.balanceOf(keeper), s0.bounty);
        assertEq(t0.balanceOf(address(farm)), s0.lp);
        assertEq(dist.unattributed(address(t0)), 100e18);
    }

    function test_attributeRunsSplitWithoutBounty() public {
        _accrue(1000e18, 500e6);
        vm.prank(attacker);
        hub.compound(key);
        _claim();

        uint256 adminBefore = t0.balanceOf(admin);
        uint256 refBefore = t0.balanceOf(referrer);
        uint256 farmBefore0 = t0.balanceOf(address(farm));
        uint256 farmBefore1 = t1.balanceOf(address(farm));

        vm.expectEmit(true, true, false, true);
        emit BunniFeeDistributor.SurplusAttributed(kh, address(t0), address(t1), 500e18, 250e6, attributor);
        vm.prank(attributor);
        dist.attribute(key, 500e18, 250e6);

        assertEq(dist.unattributed(address(t0)), 0);
        assertEq(dist.unattributed(address(t1)), 0);
        assertEq(t0.balanceOf(attributor), 0, "no bounty on attribution");
        assertEq(t0.balanceOf(admin) - adminBefore, 150e18);
        assertEq(t0.balanceOf(referrer) - refBefore, 50e18);

        assertEq(t0.balanceOf(address(farm)) - farmBefore0, 300e18);
        assertEq(t1.balanceOf(address(farm)) - farmBefore1, 150e6);
        assertEq(dist.lpPending(kh, address(t0)), 0);
        assertEq(t0.balanceOf(address(dist)), 0);
    }

    function test_attributeBoundsAndAccess() public {
        t0.mint(address(hub), 10e18);
        address[] memory toks = new address[](1);
        toks[0] = address(t0);
        dist.forceClaim(toks);
        assertEq(dist.unattributed(address(t0)), 10e18);

        vm.prank(attacker);
        vm.expectRevert(BunniFeeDistributor.NotAttributor.selector);
        dist.attribute(key, 1e18, 0);

        vm.prank(attributor);
        vm.expectRevert(BunniFeeDistributor.ExceedsUnattributed.selector);
        dist.attribute(key, 10e18 + 1, 0);

        vm.prank(attributor);
        vm.expectRevert(BunniFeeDistributor.FarmNotSet.selector);
        dist.attribute(key2, 1e18, 0);

        vm.prank(attributor);
        vm.expectRevert(BunniFeeDistributor.ZeroAmount.selector);
        dist.attribute(key, 0, 0);

        dist.attribute(key, 10e18, 0);
        assertEq(dist.unattributed(address(t0)), 0);
    }

    function test_farmRejectingNotifierDefersThenFlows() public {
        farm.setNotifier(address(dist), false);
        _accrue(1000e18, 0);
        Split memory s = _split(1000e18, 25);

        vm.expectEmit(true, true, false, true);
        emit BunniFeeDistributor.LpDeferred(kh, address(t0), s.lp, s.lp);
        _claim();

        assertEq(t0.balanceOf(address(farm)), 0, "farm got nothing");
        assertEq(dist.lpPending(kh, address(t0)), s.lp);
        assertEq(dist.lpPendingTotal(address(t0)), s.lp);
        assertEq(t0.balanceOf(address(dist)), s.lp, "share is held here");

        assertEq(t0.balanceOf(admin), s.protocol);
        assertEq(t0.balanceOf(keeper), s.bounty);

        farm.setNotifier(address(dist), true);
        _accrue(200e18, 0);
        _claim();

        uint256 total = s.lp + _split(200e18, 25).lp;
        assertEq(t0.balanceOf(address(farm)), total, "pending rolled into the next push");
        assertEq(dist.lpPending(kh, address(t0)), 0);
        assertEq(dist.lpPendingTotal(address(t0)), 0);
        assertEq(t0.balanceOf(address(dist)), 0);
    }

    function test_unregisteredStreamDefersOnlyThatToken() public {
        StakingContract farm2 = _newFarm(address(new MockERC20("ALB", "ALB", 18)), address(t0));
        farm2.setNotifier(address(dist), true);
        _exec(
            keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key, address(farm2))),
            abi.encodeCall(dist.setFeeFarm, (key, address(farm2)))
        );

        _accrue(100e18, 50e6);
        _claim();

        assertEq(t0.balanceOf(address(farm2)), _split(100e18, 25).lp);
        assertEq(t1.balanceOf(address(farm2)), 0);
        assertEq(dist.lpPending(kh, address(t1)), _split(50e6, 25).lp);

        farm2.registerStream(address(t1), 0);
        _accrue(0, 10e6);
        _claim();
        assertEq(t1.balanceOf(address(farm2)), _split(50e6, 25).lp + _split(10e6, 25).lp);
        assertEq(dist.lpPending(kh, address(t1)), 0);
    }

    function test_notifyFarmIsSelfOnly() public {
        vm.expectRevert(BunniFeeDistributor.SelfOnly.selector);
        dist.notifyFarm(address(farm), address(t0), 1);
    }

    function test_recoverTokensOnlyTouchesStrayBalance() public {
        t0.mint(address(hub), 100e18);
        farm.setNotifier(address(dist), false);
        _accrue(10e18, 0);
        _claim();
        t0.mint(address(dist), 7e18);

        uint256 reserved = dist.unattributed(address(t0)) + dist.lpPendingTotal(address(t0));
        assertEq(reserved, 100e18 + _split(10e18, 25).lp);
        assertEq(dist.recoverable(address(t0)), 7e18);

        address[] memory toks = new address[](1);
        toks[0] = address(t0);
        _exec(
            keccak256(abi.encode(dist.recoverTokens.selector, "recoverTokens", toks, treasury)),
            abi.encodeCall(dist.recoverTokens, (toks, treasury))
        );

        assertEq(t0.balanceOf(treasury), 7e18);
        assertEq(t0.balanceOf(address(dist)), reserved, "ledgered balance untouched");
        assertEq(dist.recoverable(address(t0)), 0);
    }

    function test_releaseUnattributed() public {
        t0.mint(address(hub), 100e18);
        address[] memory toks = new address[](1);
        toks[0] = address(t0);
        dist.forceClaim(toks);

        _exec(
            keccak256(
                abi.encode(dist.releaseUnattributed.selector, "releaseUnattributed", address(t0), 60e18, treasury)
            ),
            abi.encodeCall(dist.releaseUnattributed, (address(t0), 60e18, treasury))
        );
        assertEq(t0.balanceOf(treasury), 60e18);
        assertEq(dist.unattributed(address(t0)), 40e18);

        dist.queueAction(
            keccak256(
                abi.encode(dist.releaseUnattributed.selector, "releaseUnattributed", address(t0), 41e18, treasury)
            )
        );
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BunniFeeDistributor.ExceedsUnattributed.selector);
        dist.releaseUnattributed(address(t0), 41e18, treasury);
    }

    function test_forceClaimBooksHubBalance() public {
        t0.mint(address(hub), 5e18);
        address[] memory toks = new address[](2);
        toks[0] = address(t0);
        toks[1] = address(t1);

        vm.prank(attacker);
        dist.forceClaim(toks);

        assertEq(dist.unattributed(address(t0)), 5e18);
        assertEq(dist.unattributed(address(t1)), 0);
        assertEq(t0.balanceOf(address(hub)), 0);
    }

    function test_measurementFollowsHubProtocolFee() public {
        _exec(
            keccak256(abi.encode(dist.setHubProtocolFee.selector, "setHubProtocolFee", uint256(5e17))),
            abi.encodeCall(dist.setHubProtocolFee, (5e17))
        );
        assertEq(hub.protocolFee(), 5e17);

        _accrue(1000e18, 0);
        _claim();

        Split memory s = _split(500e18, 25);
        assertEq(t0.balanceOf(keeper), s.bounty);
        assertEq(t0.balanceOf(admin), s.protocol);
        assertEq(t0.balanceOf(address(farm)), s.lp);
        assertEq(t0.balanceOf(address(pool)), 500e18, "re-added share back in the position");
        assertEq(dist.unattributed(address(t0)), 0);
    }

    function test_setFeeFarmRejectsNonContract() public {
        dist.queueAction(keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key2, treasury)));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BunniFeeDistributor.NotAContract.selector);
        dist.setFeeFarm(key2, treasury);
    }

    function test_setFeeFarmCanUnset() public {
        _exec(
            keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key, address(0))),
            abi.encodeCall(dist.setFeeFarm, (key, address(0)))
        );
        assertEq(dist.feeFarms(kh), address(0));
    }

    function test_adminFunctionsAreOwnerAndTimelockGated() public {
        vm.prank(attacker);
        vm.expectRevert();
        dist.queueAction(bytes32(uint256(1)));

        vm.expectRevert(BunniFeeDistributor.NotQueued.selector);
        dist.setBountyPct(100);

        bytes32 id = keccak256(abi.encode(dist.setBountyPct.selector, "setBountyPct", uint16(100)));
        dist.queueAction(id);
        vm.expectRevert(BunniFeeDistributor.NotReady.selector);
        dist.setBountyPct(100);

        vm.warp(block.timestamp + DELAY);
        dist.setBountyPct(100);
        assertEq(dist.bountyPct(), 100);
    }

    function test_pendingFeesUsesLiveFeeGrowth() public {
        pool.setPosition(1e18, 0, 0, 5, 7);
        pool.setFeeGrowthGlobal(2 << 128, 1 << 128);
        pool.setTick(0);

        (,, uint256 p0, uint256 p1, uint256 b0,) = dist.pendingFees(key);
        assertEq(p0, 5 + 2e18);
        assertEq(p1, 7 + 1e18);
        assertEq(b0, (uint256(5 + 2e18) * 25) / 10_000);

        pool.setTick(200);
        (,, p0, p1,,) = dist.pendingFees(key);
        assertEq(p0, 5);
        assertEq(p1, 7);
    }

    function test_cancelActionBlocksExecution() public {
        bytes32 id = keccak256(abi.encode(dist.setBountyPct.selector, "setBountyPct", uint16(100)));
        dist.queueAction(id);
        dist.cancelAction(id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BunniFeeDistributor.NotQueued.selector);
        dist.setBountyPct(100);
    }
    function test_PartialOrNoopFarmCannotClearPendingOrKeepAllowance() public {
        PartialFeeFarm feeFarm = new PartialFeeFarm();
        _exec(
            keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key, address(feeFarm))),
            abi.encodeCall(dist.setFeeFarm, (key, address(feeFarm)))
        );
        _accrue(1000 ether, 0);
        _claim();
        uint256 pending = dist.lpPending(kh, address(t0));
        assertGt(pending, 0);
        assertEq(t0.allowance(address(dist), address(feeFarm)), 0);
        feeFarm.setPortion(50);
        vm.prank(attacker);
        dist.retryLp(key);
        assertEq(dist.lpPending(kh, address(t0)), pending);
        assertEq(dist.lpPendingTotal(address(t0)), pending);
        assertEq(t0.balanceOf(address(feeFarm)), 0);
        assertEq(t0.allowance(address(dist), address(feeFarm)), 0);
        feeFarm.setPortion(100);
        vm.prank(attacker);
        dist.retryLp(key);
        assertEq(dist.lpPending(kh, address(t0)), 0);
        assertEq(dist.lpPendingTotal(address(t0)), 0);
        assertEq(t0.balanceOf(address(feeFarm)), pending);
        assertEq(t0.allowance(address(dist), address(feeFarm)), 0);
    }

    function test_RetryRequiresRegisteredFarm() public {
        vm.expectRevert(BunniFeeDistributor.FarmNotSet.selector);
        dist.retryLp(key2);
    }
}

contract PartialFeeFarm {
    uint256 public portion;
    function setPortion(uint256 value) external { portion = value; }
    function notifyReward(address token, uint256 amount) external {
        MockERC20(token).transferFrom(msg.sender, address(this), amount * portion / 100);
    }
}

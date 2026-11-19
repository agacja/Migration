// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";
import {MockBunniPool, MockBunniHub} from "./MocksBunni.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {AlbPriceOracle} from "../src/oracle/AlbPriceOracle.sol";
import {StakingContract, ILoCFactoryRebase} from "../src/staking/StakingContract.sol";
import {BunniFeeDistributor} from "../src/fees/BunniFeeDistributor.sol";
import {BunniKey, IUniswapV3PoolLite} from "../src/interfaces/IBunniHub.sol";
import {Distributor} from "../src/farm/Distributor.sol";

contract Audit20260929POL is BaseTest {
    function _swap(uint256 input, uint256 output, bool buy) internal view returns (POLHolder.Action[] memory a) {
        a = new POLHolder.Action[](1);
        address tokenIn = buy ? address(alb) : address(wsteth);
        address tokenOut = buy ? address(wsteth) : address(alb);
        a[0] = POLHolder.Action(
            address(router),
            abi.encodeCall(MockRouter.swap, (tokenIn, input, tokenOut, output)),
            tokenIn,
            address(router),
            input
        );
    }

    function test_NewPrincipalCannotBeHarvestedAsOldYield() public {
        LoC line = _createLoC(address(pol), 1_000_000 ether, 1_000_000 ether, 1_000_000 ether, 0);
        pol.setLoC(ILoC(address(line)));
        pol.setRates(1 ether, 0);
        pol.setDrawLimits(1_000_000 ether, 1_000_000 ether, 1_000_000 ether);
        pol.setAllowedAsset(address(wsteth), true);
        pol.setAssetEntry(address(wsteth), 10_000, 100, POLHolder.RewardMode.COMPOUNDING);
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        assetOracle.setPrice(address(wsteth), 1e8);
        vm.prank(DAO);
        alb.addMinter(address(router));
        POLHolder.Action[] memory empty = new POLHolder.Action[](0);

        _skip(100);
        twap.touch();
        POLHolder.Action[] memory buy = _swap(100 ether, 100 ether, true);
        vm.prank(KEEPER);
        pol.maintain(empty, buy);

        assetOracle.setPrice(address(wsteth), 2e8);
        _skip(200);
        twap.touch();
        buy = _swap(200 ether, 100 ether, true);
        vm.prank(KEEPER);
        pol.maintain(empty, buy);
        assertEq(wsteth.balanceOf(address(pol)), 200 ether);
        (,,, uint128 basis,) = pol.asset(address(wsteth));
        assertEq(basis, 1.5e8);

        POLHolder.Action[] memory harvest = _swap(100 ether, 200 ether, false);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(harvest, empty);
        harvest = _swap(50 ether, 100 ether, false);
        vm.prank(KEEPER);
        pol.maintain(harvest, empty);
        assertEq(wsteth.balanceOf(address(pol)), 150 ether);
        assertEq(line.drawnAmount(), 200 ether);
        assertEq(wsteth.balanceOf(address(pol)) * 2, 300 ether);
    }

    function test_OptionDeadlinePausesWhileTwentySamplesRebuild() public {
        _warmOracle();
        assertTrue(oracle.isHealthy());
        LoC.Option[] memory options = new LoC.Option[](1);
        options[0] = LoC.Option(100 ether, 1e8, uint64(vm.getBlockTimestamp() + 6 days), false);
        LoC line = LoC(factory.createLoC(alice, address(staking), 0, 0, 0, 0, options));
        _skip(4 days);
        twap.touch();
        oracle.poke();
        assertEq(oracle.distinctDays(), 1);
        assertFalse(oracle.isHealthy());
        vm.expectRevert(AlbPriceOracle.NotWarm.selector);
        oracle.sma20();
        vm.prank(alice);
        vm.expectRevert(LoC.OracleUnhealthy.selector);
        line.redeemOption(0);
        for (uint256 i; i < 18; ++i) {
            _skip(1 days);
            twap.touch();
            oracle.poke();
        }
        assertFalse(oracle.isHealthy());
        _skip(1 days);
        twap.touch();
        oracle.poke();
        assertTrue(oracle.isHealthy());
        assertGt(line.effectiveOptionExpiry(0), vm.getBlockTimestamp());
        vm.prank(alice);
        line.redeemOption(0);
        assertEq(alb.balanceOf(alice), 100 ether);
    }
}

contract Audit20260929Fees is Test {
    function test_DeferredLpRetriesWithoutNewFees() public {
        _retryScenario(false, false);
    }

    function test_DeferredLpRetriesAfterPositionCloses() public {
        _retryScenario(true, false);
    }

    function test_DeferredLpRetryIsPermissionless() public {
        _retryScenario(true, true);
    }

    function _retryScenario(bool closed, bool explicitRetry) internal {
        vm.warp(1_800_000_000);
        MockERC20 t0 = new MockERC20("A", "A", 18);
        MockERC20 t1 = new MockERC20("B", "B", 18);
        MockBunniPool pool = new MockBunniPool(address(t0), address(t1));
        pool.setPosition(1e18, 0, 0, 0, 0);
        MockBunniHub hub = new MockBunniHub();
        hub.setProtocolFee(1e18);
        BunniFeeDistributor dist =
            new BunniFeeDistributor(address(this), address(hub), address(0xA), address(this), 10_000, 0, 0);
        hub.transferOwnership(address(dist));
        StakingContract farm =
            new StakingContract(address(this), IALB(address(t0)), address(0xE), address(0xF), address(t1));
        BunniKey memory key = BunniKey(IUniswapV3PoolLite(address(pool)), -100, 100);
        bytes32 kh = keccak256(abi.encode(key.pool, key.tickLower, key.tickUpper));
        dist.queueAction(keccak256(abi.encode(dist.setFeeFarm.selector, "setFeeFarm", key, address(farm))));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        dist.setFeeFarm(key, address(farm));
        t0.mint(address(pool), 100 ether);
        pool.addOwed(100 ether, 0);
        BunniKey[] memory keys = new BunniKey[](1);
        keys[0] = key;
        dist.claim(keys);
        uint256 deferred = dist.lpPending(kh, address(t0));
        assertGt(deferred, 0);

        farm.setNotifier(address(dist), true);
        if (closed) pool.setPosition(0, 0, 0, 0, 0);
        vm.prank(address(0xBEEF));
        if (explicitRetry) dist.retryLp(key);
        else dist.claim(keys);
        assertEq(dist.lpPending(kh, address(t0)), 0);
        assertEq(t0.balanceOf(address(farm)), deferred);
        assertEq(t0.allowance(address(dist), address(farm)), 0);
    }
}

contract Audit20260929Epoch is Test {
    function test_ZeroMinimumRejectsPublicDustEpochStarts() public {
        vm.warp(1_800_000_000);
        MockERC20 stake = new MockERC20("S", "S", 18);
        MockERC20 reward = new MockERC20("R", "R", 18);
        Distributor farm = new Distributor(address(this), address(0xF));
        uint256 pid = farm.addPool(address(stake), Distributor.PoolKind.DEPOSIT);
        uint256 index =
            farm.addStream(pid, address(reward), Distributor.StreamKind.BALANCE, address(0), address(this), 0);
        farm.setStreamEpochLength(pid, index, 7 days);
        address attacker = address(0xBAD);
        reward.mint(attacker, 1);
        vm.startPrank(attacker);
        reward.approve(address(farm), 1);
        farm.fundStream(pid, index, 1);
        vm.expectRevert(Distributor.BudgetBelowMinimum.selector);
        farm.startStreamEpoch(pid, index);
        vm.stopPrank();
        (,, uint256 initialBudget,) = farm.streamEpochs(pid, index);
        assertEq(initialBudget, 0);
        reward.mint(address(this), 700 ether);
        reward.approve(address(farm), 700 ether);
        farm.fundStream(pid, index, 700 ether);
        (,, uint256 budget,) = farm.streamEpochs(pid, index);
        assertEq(budget, 700 ether + 1);
        assertGt(farm.streamInfo(pid, index).ratePerSec, 0);
        vm.expectRevert(Distributor.EpochInProgress.selector);
        farm.startStreamEpoch(pid, index);
    }
}

contract AuditReturnToken {
    uint256 public length;
    uint256 public word;
    bool public fails;

    function configure(uint256 len, uint256 value, bool fail) external {
        (length, word, fails) = (len, value, fail);
    }

    fallback() external {
        uint256 len = length;
        uint256 value = word;
        bool fail = fails;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, value)
            if fail { revert(p, len) }
            return(p, len)
        }
    }
}

contract AuditStakingHarness is StakingContract {
    constructor(address a, address b) StakingContract(msg.sender, IALB(a), address(0xE), address(0xF), b) {}

    function transferProbe(address token, address to, uint256 amount, uint256 stipend, uint256 padding)
        external
        returns (bool ok, uint256 beforePtr, uint256 afterPtr, uint256 zero, bytes32 beforeHash, bytes32 afterHash)
    {
        bytes memory sentinel = new bytes(padding);
        if (padding != 0) sentinel[padding - 1] = 0xA5;
        beforeHash = keccak256(sentinel);
        assembly ("memory-safe") {
            beforePtr := mload(0x40)
        }
        ok = _tryTransfer(token, to, amount, stipend);
        assembly ("memory-safe") {
            afterPtr := mload(0x40)
            zero := mload(0x60)
        }
        afterHash = keccak256(sentinel);
    }

    function pullProbe() external {
        _maybePullRebase();
    }

    function measureCurrent(address token) external returns (uint256 used) {
        uint256 g = gasleft();
        require(_tryTransfer(token, address(0xBEEF), 123, 150_000));
        used = g - gasleft();
    }

    function measureSavedPointer(address token) external returns (uint256 used) {
        uint256 g0 = gasleft();
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x14, 0xBEEF)
            mstore(0x34, 123)
            mstore(0x00, 0xa9059cbb000000000000000000000000)
            let g := gas()
            ok := call(150000, token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), ok)) { ok := lt(or(iszero(extcodesize(token)), returndatasize()), ok) }
            if iszero(or(ok, gt(g, add(150000, add(div(150000, 63), 3000))))) { revert(0, 0) }
            mstore(0x40, m)
        }
        require(ok);
        used = g0 - gasleft();
    }

    function measureFreePointer(address token) external returns (uint256 used) {
        uint256 g0 = gasleft();
        bool ok;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0xa9059cbb))
            mstore(add(p, 4), 0xBEEF)
            mstore(add(p, 36), 123)
            let g := gas()
            ok := call(150000, token, 0, p, 68, 0, 32)
            ok :=
                and(
                    ok,
                    or(
                        and(gt(returndatasize(), 31), eq(mload(0), 1)),
                        and(iszero(returndatasize()), gt(extcodesize(token), 0))
                    )
                )
            if iszero(or(ok, gt(g, add(150000, add(div(150000, 63), 3000))))) { revert(0, 0) }
        }
        require(ok);
        used = g0 - gasleft();
    }

    function measureAbi(address token) external returns (uint256 used) {
        uint256 g0 = gasleft();
        (bool ok, bytes memory result) =
            token.call{gas: 150_000}(abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), 123));
        if (!ok && g0 <= uint256(150_000) + uint256(150_000) / 63 + 3000) revert();
        require(
            ok
                && (result.length == 0 ? token.code.length != 0 : result.length >= 32 && abi.decode(result, (uint256)) == 1)
        );
        used = g0 - gasleft();
    }
}

contract AuditRebaseFactory {
    MockERC20 immutable token;
    uint256 public pendingAmount = 100 ether;
    uint256 public pulls;
    bool public shortPending;

    constructor(MockERC20 t) {
        token = t;
    }

    function setShortPending(bool s) external {
        shortPending = s;
    }

    function pendingRebase() external view returns (uint256) {
        if (shortPending) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(1, 31)
            }
        }
        return pendingAmount;
    }

    function pullRebase() external returns (uint256 amount) {
        amount = pendingAmount;
        pendingAmount = 0;
        ++pulls;
        token.transfer(msg.sender, amount);
    }
}

contract AuditGasBombFactory {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

contract Audit20260929Assembly is Test {
    AuditStakingHarness harness;
    AuditReturnToken token;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);

        harness = new AuditStakingHarness(address(a), address(b));
        token = new AuditReturnToken();
    }

    function testFuzz_ReturnShapesAndMemory(
        uint16 len,
        uint256 word,
        bool fails,
        uint16 padding,
        address to,
        uint256 amount
    ) public {
        uint256 length = bound(len, 0, 128);
        token.configure(length, word, fails);
        (bool ok, uint256 beforePtr, uint256 afterPtr, uint256 zero, bytes32 beforeHash, bytes32 afterHash) =
            harness.transferProbe(address(token), to, amount, 150_000, bound(padding, 0, 4096));
        assertEq(ok, !fails && (length == 0 || (length >= 32 && word == 1)));
        assertEq(beforePtr, afterPtr);
        assertEq(zero, 0);
        assertEq(beforeHash, afterHash);
    }

    function test_ReturnTrueAndCodelessTarget() public {
        token.configure(32, 1, false);
        (bool ok,,,,,) = harness.transferProbe(address(token), address(this), 123, 150_000, 100);
        assertTrue(ok);
        (ok,,,,,) = harness.transferProbe(address(0x1234), address(this), 123, 150_000, 100);
        assertFalse(ok);
    }

    function test_AllShortTrueLookingReturnsAreRejected() public {
        for (uint256 length = 1; length < 32; ++length) {
            token.configure(length, uint256(1) << (8 * (32 - length)), false);
            (bool shortOk,,,,,) = harness.transferProbe(address(token), address(this), 123, 150_000, 100);
            assertFalse(shortOk);
        }
        token.configure(8192, 1, false);
        (bool ok,,,,,) = harness.transferProbe(address(token), address(this), 123, 150_000, 100);
        assertTrue(ok);
    }

    function test_CalldataTransfersExactAmount() public {
        MockERC20 realToken = new MockERC20("R", "R", 18);
        realToken.mint(address(harness), 123);
        (bool ok,,,,,) = harness.transferProbe(address(realToken), address(0xBEEF), 123, 150_000, 128);
        assertTrue(ok);
        assertEq(realToken.balanceOf(address(0xBEEF)), 123);
        assertEq(realToken.balanceOf(address(harness)), 0);
    }

    function test_RebaseSelectorsShortDataAndBooking() public {
        assertEq(ILoCFactoryRebase.pendingRebase.selector, bytes4(0x8f7b565b));
        assertEq(ILoCFactoryRebase.pullRebase.selector, bytes4(0xd1a4da54));
        MockERC20 a = MockERC20(address(harness.alb()));
        AuditRebaseFactory factory = new AuditRebaseFactory(a);
        a.mint(address(factory), 100 ether);
        harness.setLoCFactory(ILoCFactoryRebase(address(factory)));
        vm.prank(address(0xE));
        harness.notifyDeposit(address(this), 1 ether);
        vm.warp(1_800_000_000);
        factory.setShortPending(true);
        harness.pullProbe();
        assertEq(factory.pulls(), 0);
        factory.setShortPending(false);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        harness.pullProbe();
        assertEq(factory.pulls(), 1);
        assertEq(harness.trackedBalance(address(a)), 100 ether);
        assertEq(a.balanceOf(address(harness)), 100 ether);
    }

    function test_GasBurningFactoryDoesNotBlockHook() public {
        vm.prank(address(0xE));
        harness.notifyDeposit(address(this), 1 ether);
        harness.setLoCFactory(ILoCFactoryRebase(address(new AuditGasBombFactory())));
        vm.warp(1_800_000_000);
        vm.prank(address(0xE));
        (bool ok,) =
            address(harness).call{gas: 500_000}(abi.encodeCall(harness.notifyDeposit, (address(0xA11CE), 1 ether)));
        assertTrue(ok);
        assertEq(harness.sharesOf(address(0xA11CE)), 1 ether);
    }

    function test_GasComparisonWarmSuccessfulCall() public {
        token.configure(32, 1, false);
        harness.measureCurrent(address(token));
        emit log_named_uint("current scratch", harness.measureCurrent(address(token)));
        emit log_named_uint("explicit saved pointer", harness.measureSavedPointer(address(token)));
        emit log_named_uint("free pointer calldata", harness.measureFreePointer(address(token)));
        emit log_named_uint("Solidity ABI allocation", harness.measureAbi(address(token)));
    }
}

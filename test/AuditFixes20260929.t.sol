// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {AuditStakingHarness} from "./Audit20260929.t.sol";
import {MockERC20} from "./Mocks.sol";
import {POLBasis} from "../src/pol/POLBasis.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {StakingContract, ILoCFactoryRebase} from "../src/staking/StakingContract.sol";

contract POLBasisRegressionTest is Test {
    mapping(address => POLHolder.AssetEntry) internal assets;
    mapping(address => uint256) internal recorded;
    mapping(address => uint256) internal principal;
    address internal constant TOKEN = address(1);

    function _checkpoint(uint256 balance, uint256 price) internal {
        address[] memory tokens = new address[](1);
        uint256[] memory balances = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        tokens[0] = TOKEN;
        balances[0] = balance;
        prices[0] = price;
        POLBasis.checkpoint(tokens, balances, prices, assets, recorded, principal);
    }

    function testFuzz_InflowPreservesPrincipal(uint96 oldBalance, uint96 added, uint64 oldPrice, uint64 price) public {
        vm.assume(oldBalance != 0 && added != 0 && oldPrice != 0 && price != 0);
        assets[TOKEN] = POLHolder.AssetEntry(10_000, 100, POLHolder.RewardMode.COMPOUNDING, 0, true);
        _checkpoint(oldBalance, oldPrice);
        uint256 total = uint256(oldBalance) + added;
        _checkpoint(total, price);
        uint256 basis = assets[TOKEN].lastRecordedPrice;
        uint256 cost = uint256(oldBalance) * oldPrice + uint256(added) * price;
        assertEq(principal[TOKEN], cost);
        assertGe(total * basis, cost);
        assertLt(total * basis - cost, total);
        _checkpoint(total / 2, price / 2);
        assertGe(assets[TOKEN].lastRecordedPrice, basis);
        assertEq(recorded[TOKEN], total / 2);
    }

    function testFuzz_HarvestAndDonationPreserveExactPrincipal(
        uint96 balance,
        uint64 oldPrice,
        uint64 gain,
        uint96 gift
    ) public {
        vm.assume(balance > 1 && oldPrice != 0 && gain != 0);
        assets[TOKEN] = POLHolder.AssetEntry(10_000, 100, POLHolder.RewardMode.COMPOUNDING, 0, true);
        _checkpoint(balance, oldPrice);
        uint256 price = uint256(oldPrice) + gain;
        uint256 oldYield = uint256(balance) * gain / price;
        address[] memory tokens = new address[](1);
        uint256[] memory balances = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        tokens[0] = TOKEN;
        balances[0] = uint256(balance) + gift;
        prices[0] = price;
        uint256[] memory yields = POLBasis.prepareHarvest(tokens, balances, prices, 1, assets, recorded, principal);
        assertEq(yields[0], oldYield, "donation cannot reduce a prepared harvest");
        uint256 cost = uint256(balance) * oldPrice + uint256(gift) * price;
        assertEq(principal[TOKEN], cost);
        uint256[] memory afterBalances = new uint256[](1);
        afterBalances[0] = balances[0] - oldYield / 2;
        POLBasis.settleHarvest(tokens, balances, afterBalances, prices, yields, assets, recorded, principal);
        assertEq(principal[TOKEN], cost, "partial harvest retains principal");
        yields = POLBasis.prepareHarvest(tokens, afterBalances, prices, 1, assets, recorded, principal);
        assertEq(yields[0], oldYield - oldYield / 2);
        balances[0] = afterBalances[0];
        afterBalances[0] -= yields[0];
        POLBasis.settleHarvest(tokens, balances, afterBalances, prices, yields, assets, recorded, principal);
        assertEq(principal[TOKEN], cost, "full harvest retains principal");
        assertGe(afterBalances[0] * price, cost);
        assertLt(afterBalances[0] * price - cost, price);
    }

    function test_ZeroBalanceAndUnpricedInflowResetBasis() public {
        assets[TOKEN] = POLHolder.AssetEntry(10_000, 100, POLHolder.RewardMode.COMPOUNDING, 0, true);
        _checkpoint(100, 100);
        _checkpoint(200, 0);
        assertEq(assets[TOKEN].lastRecordedPrice, 0);
        _checkpoint(200, 200);
        assertEq(assets[TOKEN].lastRecordedPrice, 200);
        _checkpoint(0, 200);
        assertEq(assets[TOKEN].lastRecordedPrice, 0);
        _checkpoint(100, 50);
        assertEq(assets[TOKEN].lastRecordedPrice, 50);
    }
}

contract OptionClockRegressionTest is BaseTest {
    function _option(uint64 expiry) internal returns (LoC line) {
        LoC.Option[] memory options = new LoC.Option[](1);
        options[0] = LoC.Option(100 ether, 1e8, expiry, false);
        line = LoC(factory.createLoC(alice, address(staking), 0, 0, 0, 0, options));
    }

    function test_InitialWarmupDoesNotConsumeOptionLifetime() public {
        uint256 clock = oracle.optionClock();
        LoC line = _option(uint64(vm.getBlockTimestamp() + 1 days));
        _warmOracle();
        assertEq(oracle.optionClock(), clock);
        assertEq(line.effectiveOptionExpiry(0), vm.getBlockTimestamp() + 1 days);
        _skip(12 hours);
        twap.touch();
        assertEq(oracle.optionClock(), clock + 12 hours);
        vm.prank(alice);
        line.redeemOption(0);
        assertEq(alb.balanceOf(alice), 100 ether);
    }

    function test_ExpiredOptionStaysExpiredAcrossOutageAndRecovery() public {
        _warmOracle();
        LoC line = _option(uint64(vm.getBlockTimestamp() + 1 days));
        _skip(4 days);
        twap.touch();
        oracle.poke();
        uint256 stopped = oracle.optionClock();
        vm.prank(alice);
        vm.expectRevert(LoC.OptionExpired.selector);
        line.redeemOption(0);
        for (uint256 i; i < 19; ++i) {
            _skip(1 days);
            twap.touch();
            oracle.poke();
            assertEq(oracle.optionClock(), stopped);
        }
        assertTrue(oracle.isHealthy());
        assertLt(line.effectiveOptionExpiry(0), vm.getBlockTimestamp());
        vm.prank(alice);
        vm.expectRevert(LoC.OptionExpired.selector);
        line.redeemOption(0);
    }

    function test_PurgeFreezesClockAndOptionsCreatedMidRecoveryGetFullLifetime() public {
        _warmOracle();
        _skip(12 hours);
        uint256 before = oracle.optionClock();
        vm.prank(DAO);
        oracle.setTwapSource(ITwapSource(address(twap)), true);
        _skip(5 days);
        assertEq(oracle.optionClock(), before);
        LoC line = _option(uint64(vm.getBlockTimestamp() + 2 days));
        _warmOracle();
        assertEq(oracle.optionClock(), before);
        assertEq(line.effectiveOptionExpiry(0), vm.getBlockTimestamp() + 2 days);
        _skip(1 hours);
        assertEq(oracle.optionClock(), before + 1 hours);
    }

    function test_StaleClockCapsAtBucketDeadlineAndCannotMoveBackwards() public {
        _skip(11 hours);
        _warmOracle();
        uint256 before = oracle.optionClock();
        uint256 freshUntil = uint256(oracle.lastSampleAt()) + 3 days;
        uint256 activeRemainder = freshUntil - vm.getBlockTimestamp();
        _skip(30 days);
        assertEq(oracle.optionClock(), before + activeRemainder);
        twap.touch();
        oracle.poke();
        assertEq(oracle.optionClock(), before + activeRemainder);
        _skip(1 days);
        twap.touch();
        oracle.poke();
        assertEq(oracle.optionClock(), before + activeRemainder);
    }

    function test_RedemptionCanWriteFinalRecoverySample() public {
        LoC line = _option(0);
        for (uint256 i; i < 19; ++i) {
            _skip(1 days);
            twap.touch();
            oracle.poke();
        }
        assertEq(line.effectiveOptionExpiry(0), 0);
        _skip(1 days);
        twap.touch();
        vm.prank(alice);
        line.redeemOption(0);
        assertEq(oracle.distinctDays(), 20);
        assertEq(alb.balanceOf(alice), 100 ether);
    }
}

contract PullGasBombFactory {
    function pendingRebase() external pure returns (uint256) {
        return 1;
    }

    function pullRebase() external pure returns (uint256) {
        assembly {
            invalid()
        }
    }
}

contract RebaseCapRegressionTest is Test {
    AuditStakingHarness internal harness;

    function setUp() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        harness = new AuditStakingHarness(address(a), address(b));
        vm.prank(address(0xE));
        harness.notifyDeposit(address(this), 1 ether);
        harness.setLoCFactory(ILoCFactoryRebase(address(new PullGasBombFactory())));
        vm.warp(1_800_000_000);
    }

    function test_GasBurningPullDoesNotBlockHook() public {
        vm.prank(address(0xE));
        (bool ok,) =
            address(harness).call{gas: 600_000}(abi.encodeCall(harness.notifyDeposit, (address(0xA11CE), 1 ether)));
        assertTrue(ok);
        assertEq(harness.sharesOf(address(0xA11CE)), 1 ether);
        assertEq(harness.trackedBalance(address(harness.alb())), 0);
    }

    function test_InsufficientOuterGasCannotAdvanceRetryTimestamp() public {
        uint64 before = harness.lastRebasePullAt();
        (bool ok, bytes memory reason) = address(harness).call{gas: 200_000}(abi.encodeCall(harness.pullProbe, ()));
        assertFalse(ok);
        assertEq(bytes4(reason), StakingContract.InsufficientRebaseGas.selector);
        assertEq(harness.lastRebasePullAt(), before);
    }
}

contract RealRebaseCapRegressionTest is BaseTest {
    uint256 internal expectedPending;

    function setUp() public override {
        super.setUp();
        _stakeEs(alice, 1_000_000 ether);
        LoC line = _createLoC(bob, 1_000_000 ether, 1_000_000 ether, 1_000_000 ether, 0);
        vm.prank(bob);
        line.draw(1_000_000 ether, bob);
        expectedPending = factory.pendingRebase();
    }

    function test_ColdFactoryAndTokenFitPullCap() public {
        assertGt(expectedPending, 0);
        vm.prank(address(staking));
        uint256 gasBefore = gasleft();
        uint256 received = factory.pullRebase{gas: 100_000}();
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("cold production factory pull (including caller)", used);
        assertEq(received, expectedPending);
        assertEq(alb.balanceOf(address(staking)), expectedPending);
        assertEq(factory.pendingRebase(), 0);
        assertLt(used, 100_000);
    }
}

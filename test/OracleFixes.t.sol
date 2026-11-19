// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {MockERC20} from "./Mocks.sol";
import {MockV3Pool} from "./MocksV3.sol";
import {UniV3TwapOracle} from "../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../src/oracle/AlbTwapSource.sol";
import {AlbPriceOracle, ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {LoC} from "../src/loc/LoC.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract OracleRatioHarness is UniV3TwapOracle {
    constructor(address usdc_, address weth_)
        UniV3TwapOracle(msg.sender, usdc_, weth_, new address[](0)) {}

    function ratio(int24 tick, bool inverse) external pure returns (uint256, int256) {
        return _ratioAtSqrtPrice(TickMath.getSqrtRatioAtTick(tick), inverse);
    }
}

contract OracleFixes is BaseTest {
    function _option(uint256 strike) internal returns (LoC line) {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option(100 ether, strike, 0, false);
        line = LoC(factory.createLoC(bob, address(staking), 0, 0, 0, 0, opts));
    }

    function _tickFor(uint256 num, uint256 den) internal pure returns (int24) {
        uint256 target = FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        int24 lo = TickMath.MIN_TICK + 1;
        int24 hi = TickMath.MAX_TICK - 1;
        while (lo < hi) {
            int24 mid = lo + (hi - lo) / 2;
            if (TickMath.getSqrtRatioAtTick(mid) < target) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    function _poolAtPrice(address token, uint256 usd8) internal returns (MockV3Pool p) {
        int24 tick = token < address(usdc) ? _tickFor(usd8, 1e20) : _tickFor(1e20, usd8);
        return new MockV3Pool(token, address(usdc), tick, 1e20, 100);
    }

    function _engine() internal returns (UniV3TwapOracle engine) {
        address[] memory none = new address[](0);
        engine = new UniV3TwapOracle(address(this), address(usdc), address(weth), none);
    }

    function _wireRealSource() internal returns (UniV3TwapOracle engine, MockV3Pool p) {
        engine = _engine();
        p = _poolAtPrice(address(alb), 1e8);
        engine.setRoute(address(alb), address(p), address(0), address(0));
        AlbTwapSource s = new AlbTwapSource(engine, address(alb));
        vm.prank(DAO); oracle.setTwapSource(ITwapSource(address(s)), true);
        for (uint256 i; i < 20;) {
            _skip(1 days);
            oracle.poke();
            unchecked { ++i; }
        }
        assertTrue(oracle.isHealthy());
    }

    function _expectedAfterGap(uint256 anchor, uint256 price, uint256 gapDays, uint256 idx)
        internal
        pure
        returns (uint256 cur)
    {
        cur = gapDays < 20 ? anchor : price;
        for (uint256 k; k <= idx;) {
            uint256 band = (cur * 1000) / 10_000;
            uint256 up = cur + band;
            uint256 down = cur > band ? cur - band : 0;
            cur = price > up ? up : (price < down ? down : price);
            unchecked { ++k; }
        }
    }

    function test_O1_longGapRequiresFreshWindowAndBlocksOldStrike() public {
        _warmOracle();
        LoC line = _option(0.7e8);
        twap.setPrice(0.5e8);
        _skip(10 days); twap.touch(); oracle.poke();
        assertEq(oracle.count(), 1);

        assertEq(oracle.buffer(0), 0.9e8);
        for (uint256 i = 1; i < 20;) {
            assertFalse(oracle.isHealthy(), "missing days cannot restore warmth");
            vm.expectRevert(AlbPriceOracle.NotWarm.selector); oracle.sma20();
            vm.prank(bob); vm.expectRevert(LoC.OracleUnhealthy.selector); line.redeemOption(0);
            _skip(1 days); twap.touch(); oracle.poke();
            unchecked { ++i; }
        }
        assertTrue(oracle.isHealthy());

        assertEq(oracle.sma20(), 56085155);
        for (uint256 i; i < 20;) {
            assertEq(oracle.buffer(i), _expectedAfterGap(1e8, 0.5e8, 10, i), "only post-gap samples");
            unchecked { ++i; }
        }
        vm.prank(bob); vm.expectRevert(LoC.BelowStrike.selector); line.redeemOption(0);
        assertEq(alb.balanceOf(bob), 0);
        LoC eligible = _option(0.4e8);
        vm.prank(bob); eligible.redeemOption(0);
        assertEq(alb.balanceOf(bob), 100 ether, "valid grants still redeem after recovery");
    }

    function testFuzz_O1_longGapCannotReviveStaleMembership(uint8 rawGap) public {
        uint256 gap = bound(uint256(rawGap), 4, 40);
        _warmOracle();
        _skip(gap * 1 days); twap.setPrice(0.5e8); oracle.poke();
        uint256 sum;
        for (uint256 i = 1; i <= 20;) {
            assertEq(oracle.count(), i);
            assertEq(oracle.distinctDays(), i);
            assertEq(oracle.isHealthy(), i == 20);
            for (uint256 j; j < 20;) {
                assertEq(oracle.buffer(j), j < i ? _expectedAfterGap(1e8, 0.5e8, gap, j) : 0);
                unchecked { ++j; }
            }
            sum += _expectedAfterGap(1e8, 0.5e8, gap, i - 1);
            if (i < 20) { _skip(1 days); twap.touch(); oracle.poke(); }
            unchecked { ++i; }
        }
        assertEq(oracle.sma20(), sum / 20);
    }

    function test_O2_healthyDespiteExpiredEngineHeartbeatAndOptionStillMints() public {
        (UniV3TwapOracle engine, MockV3Pool p) = _wireRealSource();
        LoC line = _option(0.9e8);
        p.freezeObservations();
        _skip(2 hours);
        vm.expectRevert(UniV3TwapOracle.StaleObservation.selector);
        oracle.safeSpotPrice();
        (, bool available) = engine.tryPriceOf(address(alb));
        assertFalse(available);
        assertTrue(oracle.isHealthy(), "6h adapter-age gate ignores 1h engine heartbeat");
        vm.prank(bob); line.redeemOption(0);
        assertEq(alb.balanceOf(bob), 100 ether, "option mints with engine explicitly stale");
    }

    function test_O2_healthyDespiteFailedLiquidityCheckAndOptionStillMints() public {
        (UniV3TwapOracle engine, MockV3Pool p) = _wireRealSource();
        LoC line = _option(0.9e8);
        p.setTwaLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        oracle.safeSpotPrice();
        (, bool available) = engine.tryPriceOf(address(alb));
        assertFalse(available);
        assertTrue(oracle.isHealthy());
        vm.prank(bob); line.redeemOption(0);
        assertEq(alb.balanceOf(bob), 100 ether);
    }

    function test_CONTROL_explicitRouteSuspensionStopsOptionRedemption() public {
        (UniV3TwapOracle engine,) = _wireRealSource();
        LoC line = _option(0.9e8);
        engine.suspendRoute(address(alb));
        assertFalse(oracle.isHealthy());
        vm.prank(bob); vm.expectRevert(LoC.OracleUnhealthy.selector);
        line.redeemOption(0);
    }

    function test_CONTROL_largeGapPurgesRatherThanUsingStaleMembership() public {
        _warmOracle();
        _skip(20 days); twap.touch(); oracle.poke();
        assertEq(oracle.count(), 1);
        assertEq(oracle.distinctDays(), 1);
        assertFalse(oracle.isHealthy());
        vm.expectRevert(AlbPriceOracle.NotWarm.selector); oracle.sma20();
    }

    function _preciseUsd8(int24 tick, address token) internal view returns (uint256) {
        uint256 s = TickMath.getSqrtRatioAtTick(tick);

        uint256 ratioX192 = s * s;
        return token < address(usdc)
            ? FullMath.mulDiv(ratioX192, 1e20, uint256(1) << 192)
            : FullMath.mulDiv(uint256(1) << 192, 1e20, ratioX192);
    }

    function test_O3_lowPricedAssetRetainsUsdPrecision() public {
        UniV3TwapOracle engine = _engine();
        MockV3Pool p = _poolAtPrice(address(alb), 199);
        engine.setRoute(address(alb), address(p), address(0), address(0));
        uint256 expected = _preciseUsd8(p.twapTick(), address(alb));
        uint256 reported = engine.priceOf(address(alb));
        assertApproxEqAbs(expected, 199, 1);
        assertEq(reported, expected, "fractional USDC units survive USD normalization");
        emit log_named_uint("full-precision quote, 8dp", expected);
        emit log_named_uint("reported quote, 8dp", reported);
    }

    function test_O3_nonzeroRepresentablePriceWorksBelowOneMicroDollar() public {
        UniV3TwapOracle engine = _engine();
        MockV3Pool p = _poolAtPrice(address(alb), 50);
        engine.setRoute(address(alb), address(p), address(0), address(0));
        assertApproxEqAbs(_preciseUsd8(p.twapTick(), address(alb)), 50, 1);
        uint256 expected = _preciseUsd8(p.twapTick(), address(alb));
        assertEq(engine.priceOf(address(alb)), expected);
        (uint256 reported, bool ok) = engine.tryPriceOf(address(alb));
        assertTrue(ok);
        assertEq(reported, expected);
    }

    function test_O3_twoHopRouteRetainsUsdPrecision() public {
        UniV3TwapOracle engine = _engine();
        MockV3Pool first = new MockV3Pool(address(alb), address(weth), 0, 1e20, 100);
        MockV3Pool second = _poolAtPrice(address(weth), 199);
        engine.setRoute(address(alb), address(first), address(second), address(weth));
        assertApproxEqAbs(_preciseUsd8(second.twapTick(), address(weth)), 199, 1);
        assertEq(engine.priceOf(address(alb)), _preciseUsd8(second.twapTick(), address(weth)));
    }

    function _referenceQuote(int24 tick, bool inverse) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtRatioAtTick(tick);

        uint256 n = s < (1 << 128) ? s * s : FullMath.mulDiv(s, s, 1 << 64);
        uint256 d = s < (1 << 128) ? uint256(1) << 192 : uint256(1) << 128;
        return inverse ? FullMath.mulDiv(d, 1e20, n) : FullMath.mulDiv(n, 1e20, d);
    }

    function testFuzz_O3_singleHopMatchesScaledReference(int24 rawTick, bool inverse) public {
        int24 tick = int24(bound(int256(rawTick), -600000, 887272));
        address token = inverse ? address(type(uint160).max) : address(1);
        UniV3TwapOracle engine = _engine();
        MockV3Pool p = new MockV3Pool(token, address(usdc), tick, 1e20, 100);
        engine.setRoute(token, address(p), address(0), address(0));
        uint256 expected = _referenceQuote(tick, inverse);
        if (expected == 0) {
            vm.expectRevert(UniV3TwapOracle.InvalidPrice.selector); engine.priceOf(token);
        } else {
            assertApproxEqAbs(engine.priceOf(token), expected, expected / 1e30 + 1);
        }
    }

    function test_O3_tinyPriceWorksInBothTokenOrders() public {
        UniV3TwapOracle engine = _engine();
        address[2] memory tokens = [address(1), address(type(uint160).max)];
        for (uint256 i; i < 2;) {
            MockV3Pool p = _poolAtPrice(tokens[i], 50);
            engine.setRoute(tokens[i], address(p), address(0), address(0));
            assertEq(engine.priceOf(tokens[i]), _referenceQuote(p.twapTick(), tokens[i] > address(usdc)));
            unchecked { ++i; }
        }
    }

    function test_O3_twoHopPreservesFractionalIntermediateUnits() public {
        UniV3TwapOracle engine = _engine();
        address token = address(1);
        address mid = address(type(uint160).max);
        MockV3Pool a = new MockV3Pool(token, mid, -600000, 1e20, 100);
        MockV3Pool b = new MockV3Pool(mid, address(usdc), -600000, 1e20, 100);
        engine.setRoute(token, address(a), address(b), mid);
        assertApproxEqAbs(engine.priceOf(token), 1e20, 1);
    }

    function test_O3_twoHopExtremeReciprocalRatiosRemainRepresentable() public {
        UniV3TwapOracle engine = _engine();
        address token = address(type(uint160).max);
        address mid = address(1);
        MockV3Pool a = new MockV3Pool(token, mid, TickMath.MAX_TICK, 1e20, 100);
        MockV3Pool b = new MockV3Pool(mid, address(usdc), TickMath.MAX_TICK, 1e20, 100);
        engine.setRoute(token, address(a), address(b), mid);
        assertApproxEqAbs(engine.priceOf(token), 1e20, 1);
    }

    function test_O3_unrepresentableRouteOverflowReturnsUnavailable() public {
        UniV3TwapOracle engine = _engine();
        address token = address(1);
        address mid = address(2);
        MockV3Pool a = new MockV3Pool(token, mid, TickMath.MAX_TICK, 1e20, 100);
        MockV3Pool b = new MockV3Pool(mid, address(usdc), TickMath.MAX_TICK, 1e20, 100);
        engine.setRoute(token, address(a), address(b), mid);
        (, bool ok) = engine.tryPriceOf(token);
        assertFalse(ok, "an overflowing USD quote must fail closed");
    }

    function test_O3_largeTwoHopQuoteNormalizesBeforeOverflow() public {
        UniV3TwapOracle engine = _engine();
        address token = address(1);
        address mid = address(2);
        MockV3Pool a = new MockV3Pool(token, mid, 650000, 1e20, 100);
        MockV3Pool b = new MockV3Pool(mid, address(usdc), 650000, 1e20, 100);
        engine.setRoute(token, address(a), address(b), mid);
        uint256 expected = 28540391188463646292531848966543732632579636353335388517002283916687424507304;
        assertApproxEqAbs(engine.priceOf(token), expected, expected / 1e30);
    }

    function test_O3_unrepresentableRouteUnderflowReturnsUnavailable() public {
        UniV3TwapOracle engine = _engine();
        address token = address(1);
        address mid = address(2);
        MockV3Pool a = new MockV3Pool(token, mid, -600000, 1e20, 100);
        MockV3Pool b = new MockV3Pool(mid, address(usdc), -600000, 1e20, 100);
        engine.setRoute(token, address(a), address(b), mid);
        vm.expectRevert(UniV3TwapOracle.InvalidPrice.selector); engine.priceOf(token);
    }

    function test_O3_ratioNormalizationHandlesBothTickEndpoints() public {
        OracleRatioHarness harness = new OracleRatioHarness(address(usdc), address(weth));
        for (uint256 i; i < 4;) {
            int24 tick = i < 2 ? TickMath.MIN_TICK : TickMath.MAX_TICK;
            (uint256 significand, int256 exponent) = harness.ratio(tick, i % 2 == 0);
            assertGe(significand, uint256(1) << 126);
            assertLt(significand, uint256(1) << 128);
            assertGe(exponent, -255);
            assertLe(exponent, 0);
            unchecked { ++i; }
        }
        (uint256 actual, int256 scale) = harness.ratio(TickMath.MIN_TICK, true);
        uint256 s = TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK);
        assertEq(scale, 0);
        assertEq(actual, (uint256(1) << 192) / (s * s));
    }
}

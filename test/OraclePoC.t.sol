// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {UniV3TwapOracle} from "../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../src/oracle/AlbTwapSource.sol";
import {AlbPriceOracle, ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {MockERC20} from "./Mocks.sol";
import {MockV3Pool, MockV3Factory} from "./MocksV3.sol";

contract OraclePoCTest is Test {
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal griefer = makeAddr("griefer");

    MockERC20 internal alb;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV3Factory internal factory;
    UniV3TwapOracle internal engine;
    AlbTwapSource internal source;
    AlbPriceOracle internal sma;
    MockV3Pool internal pool;

    function _tickFor(uint256 num, uint256 den) internal pure returns (int24) {
        uint256 targetSqrtX96 = FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        int24 lo = TickMath.MIN_TICK + 1;
        int24 hi = TickMath.MAX_TICK - 1;
        while (lo < hi) {
            int24 mid = lo + (hi - lo) / 2;
            if (uint256(TickMath.getSqrtRatioAtTick(mid)) < targetSqrtX96) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    function _tickForPrice(uint256 usdPrice8dp) internal view returns (int24) {
        uint256 usdcPerAlbScaled = (usdPrice8dp * 1e6) / 1e8;
        if (address(alb) < address(usdc)) return _tickFor(usdcPerAlbScaled, 1e18);
        return _tickFor(1e18, usdcPerAlbScaled);
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        alb = new MockERC20("AlienBase", "ALB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        factory = new MockV3Factory();
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        vm.prank(owner);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), factories);
        source = new AlbTwapSource(engine, address(alb));

        int24 tick = _tickForPrice(1e8);
        pool = new MockV3Pool(address(alb), address(usdc), tick, 1e20, 100);
        factory.setPool(address(alb), address(usdc), 500, address(pool));
        vm.prank(owner);
        engine.setRoute(address(alb), address(pool), address(0), address(0));

        vm.prank(owner);
        sma = new AlbPriceOracle(owner, ITwapSource(address(source)));
    }

    function _warm() internal {
        uint256 t = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            t += 1 days;
            vm.warp(t);
            sma.poke();
        }
        assertTrue(sma.isHealthy(), "precondition: oracle warm and healthy");
    }

    function _skewSpot() internal {
        int24 twapTick = _tickForPrice(1e8);
        int24 spotTick = _tickForPrice(2e8);
        pool.setTicks(twapTick, spotTick);
    }

    function _unskewSpot() internal {
        int24 twapTick = _tickForPrice(1e8);
        pool.setTicks(twapTick, twapTick);
    }

    function test_FIXED_longOutageRequiresFreshWindow() public {
        _warm();
        uint256 t = block.timestamp;
        for (uint256 d; d < 4; ++d) {
            t += 1 days;
            vm.warp(t);
            _skewSpot();
            vm.expectRevert(UniV3TwapOracle.TwapDeviationTooHigh.selector);
            sma.poke();
            _unskewSpot();
            vm.warp(t);
        }
        assertFalse(sma.isHealthy());
        sma.poke();
        assertEq(sma.count(), 1);
        assertEq(sma.distinctDays(), 1);
        for (uint256 i = 1; i < 20; ++i) {
            assertFalse(sma.isHealthy());
            t += 1 days;
            vm.warp(t);
            sma.poke();
        }
        assertTrue(sma.isHealthy());
    }

    function test_FIXED_gapRecoveryCannotRetainPreCrashPrices() public {
        _warm();
        uint256 anchor = sma.buffer((uint256(sma.head()) + 19) % 20);
        uint256 t = block.timestamp + 10 days;
        pool.setTicks(_tickForPrice(0.5e8), _tickForPrice(0.5e8));
        vm.warp(t);
        sma.poke();
        assertEq(sma.count(), 1);

        assertEq(sma.buffer(0), anchor - anchor / 10);
        for (uint256 i = 1; i < 20; ++i) {
            assertFalse(sma.isHealthy());
            vm.expectRevert(AlbPriceOracle.NotWarm.selector); sma.sma20();
            t += 1 days;
            vm.warp(t);
            sma.poke();
        }
        assertTrue(sma.isHealthy());

        assertApproxEqRel(sma.sma20(), 0.56085e8, 0.001e18);
        for (uint256 i; i < 20; ++i) assertLe(sma.buffer(i), anchor - anchor / 10);
        for (uint256 i = 6; i < 20; ++i) assertApproxEqRel(sma.buffer(i), 0.5e8, 0.001e18);
    }

    function test_FIXED_longGapPurgesAWrappedRing() public {
        _warm();
        uint256 t = block.timestamp;
        pool.setTicks(_tickForPrice(1.2e8), _tickForPrice(1.2e8));
        for (uint256 i; i < 2; ++i) { t += 1 days; vm.warp(t); sma.poke(); }
        assertEq(sma.head(), 2);
        vm.warp(t + 5 days);
        sma.poke();
        assertEq(sma.count(), 1);
        assertEq(sma.head(), 1);
        assertApproxEqRel(sma.buffer(0), 1.2e8, 0.001e18);
        for (uint256 i = 1; i < 20; ++i) assertEq(sma.buffer(i), 0);
    }

    function test_FIXED_gapWiderThanTheWindowStillPurges() public {
        _warm();
        vm.warp(block.timestamp + 400 days);
        sma.poke();

        assertEq(sma.distinctDays(), 1, "a 400-day gap keeps nothing");
        assertFalse(sma.isHealthy());
    }

    function test_DEFECT_grieferPinsTheDailySamplingMoment() public {
        uint256 dayStart = (block.timestamp / 1 days) * 1 days;

        vm.warp(dayStart + 1 days - 60);
        vm.prank(griefer);
        assertTrue(sma.poke(), "griefer takes the sample");
        uint64 pinnedTs = sma.lastSampleTs();

        for (uint256 d = 1; d <= 3; ++d) {
            vm.warp(dayStart + d * 1 days + 300);
            vm.prank(keeper);
            assertFalse(sma.poke(), "keeper cron silently no-ops: <23h since griefer's sample");
            assertEq(sma.lastSampleTs(), pinnedTs, "no sample written");

            vm.warp(dayStart + d * 1 days + 1 days - 60);
            vm.prank(griefer);
            assertTrue(sma.poke(), "griefer keeps control of the sample moment");
            pinnedTs = sma.lastSampleTs();
        }
    }

    function test_DEFECT_countDivergesFromDistinctDays() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 7; ++i) {
            t += 3 days;
            vm.warp(t);
            sma.poke();
        }
        uint256 c = sma.count();
        uint256 dd = sma.distinctDays();
        assertGt(c, dd, "count outruns distinctDays via forward-fill");
        emit log_named_uint("count (slots filled)", c);
        emit log_named_uint("distinctDays (real observations)", dd);

        if (dd < 20) {
            vm.expectRevert(AlbPriceOracle.NotWarm.selector);
            sma.sma20();
        }

        sma.safeSpotPrice();
    }

    function test_FIXED_abandonedPoolIsRejectedNotPricedAsFresh() public {
        assertGt(engine.twapPrice(address(alb)), 0, "live pool prices fine");

        pool.freezeObservations();
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(UniV3TwapOracle.StaleObservation.selector);
        engine.twapPrice(address(alb));

        (uint256 p, bool ok) = engine.tryPriceOf(address(alb));
        assertFalse(ok, "unavailable, not confidently wrong");
        assertEq(p, 0);
        assertTrue(engine.isStale(address(alb)), "a year of no trades now reads as stale");

        assertEq(block.timestamp - source.lastUpdate(), 365 days, "adapter reports the true age");
        vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
        sma.poke();
    }

    function test_FIXED_darkPoolCollapsesTwapOntoSpotAndLiquidityOntoInstantaneous() public {
        pool.freezeObservations();
        vm.warp(block.timestamp + 2 * 3600);
        pool.setTicks(_tickForPrice(1e8), _tickForPrice(50e8));
        pool.setLiquidity(type(uint128).max);

        uint32[] memory ago = new uint32[](2);
        ago[0] = 3600;
        ago[1] = 0;
        (int56[] memory tc, uint160[] memory spl) = pool.observe(ago);

        int24 mean = int24((tc[1] - tc[0]) / int56(uint56(3600)));
        assertEq(mean, pool.spotTick(), "mean tick collapsed onto spot");

        uint256 twaLiq = (uint256(3600) << 128) / uint256(spl[1] - spl[0]);
        assertApproxEqRel(twaLiq, uint256(pool.liquidity()), 0.001e18, "twa liquidity == instantaneous");

        vm.expectRevert(UniV3TwapOracle.StaleObservation.selector);
        engine.twapPrice(address(alb));
    }

    function test_FIXED_heartbeatCannotBeWidenedPastTheAveragingWindow() public {
        vm.startPrank(owner);
        engine.setTwapPeriod(3600);
        vm.expectRevert(UniV3TwapOracle.InvalidTwapPeriod.selector);
        engine.setMaxObservationAge(3601);
        engine.setMaxObservationAge(3600);

        engine.setTwapPeriod(600);
        vm.stopPrank();
        assertEq(engine.maxObservationAge(), 600, "heartbeat clamped to the new window");
    }

    function test_CONTROL_branchAAtMaxTickDoesNotOverflow() public pure {
        uint256 s = uint256(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK));
        uint256 priceX128 = FullMath.mulDiv(s, s, 1 << 64);
        assertLt(priceX128, type(uint256).max, "priceX128 fits");
        uint256 amountOut = FullMath.mulDiv(priceX128, 1e18, 1 << 128);
        assertGt(amountOut, 0);
    }

    function test_CONTROL_happyPathStaysHealthy() public {
        _warm();
        assertApproxEqRel(sma.sma20(), 1e8, 0.01e18);
        assertApproxEqRel(sma.safeSpotPrice(), 1e8, 0.01e18);
    }

    function test_CONTROL_shortGapForwardFillsAndSurvives() public {
        _warm();
        vm.warp(block.timestamp + 3 days);
        sma.poke();
        assertTrue(sma.isHealthy(), "a 3-day gap is tolerated");
    }
}

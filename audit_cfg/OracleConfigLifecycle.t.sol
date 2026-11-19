// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {UniV3TwapOracle} from "../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../src/oracle/AlbTwapSource.sol";
import {AlbPriceOracle, ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {MockERC20, MockTwapSource} from "../test/Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../test/MocksV3.sol";

contract OracleConfigLifecycleTest is Test {
    address internal owner = makeAddr("owner");

    MockERC20 internal alb;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV3Factory internal v3factory;
    UniV3TwapOracle internal engine;
    AlbTwapSource internal source;

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

    function setUp() public {
        vm.warp(1_700_000_000);
        alb = new MockERC20("AlienBase", "ALB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        v3factory = new MockV3Factory();
        address[] memory fs = new address[](1);
        fs[0] = address(v3factory);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), fs);
        source = new AlbTwapSource(engine, address(alb));
    }

    function _pool(uint256 usdPrice8dp) internal returns (MockV3Pool pool) {
        uint256 usdcPerAlbScaled = (usdPrice8dp * 1e6) / 1e8;
        int24 tick = address(alb) < address(usdc)
            ? _tickFor(usdcPerAlbScaled, 1e18)
            : _tickFor(1e18, usdcPerAlbScaled);
        pool = new MockV3Pool(address(alb), address(usdc), tick, 1e20, 100);
    }

    function _bind(MockV3Pool pool) internal {
        vm.prank(owner);
        engine.setRoute(address(alb), address(pool), address(0), address(0));
    }

    function _warm(AlbPriceOracle o) internal {
        uint256 t = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            t += 1 days;
            vm.warp(t);
            o.poke();
        }
    }

    // =========================================================================
    // PoC 1: LoC.redeemOption's "poke() blocks redemption while the source is
    // dark" guarantee is false. poke() early-returns when today's sample exists,
    // and isHealthy() carries NO live-source signal (AlbTwapSource.lastUpdate()
    // is block.timestamp, so AlbPriceOracle's MAX_TWAP_STALENESS leg is vacuous).
    // =========================================================================
    function test_PoC1_healthGateSaysHealthyWhileEngineIsDark() public {
        MockV3Pool pool = _pool(1e8);
        _bind(pool);
        AlbPriceOracle o = new AlbPriceOracle(owner, ITwapSource(address(source)));
        _warm(o);
        assertTrue(o.isHealthy());
        uint256 smaBefore = o.sma20();

        // Engine goes dark mid-day: pool stops qualifying (cardinality / liquidity /
        // spot-deviation are all equivalent here). Owner clearRoute(alb) is identical.
        pool.setCardinality(2);
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        source.consult();
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        o.spotPrice();
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        o.safeSpotPrice();

        // These are EXACTLY the three lines LoC.redeemOption:256-258 executes.
        assertFalse(o.poke(), "poke() no-ops: today's sample already written");
        assertTrue(o.isHealthy(), "isHealthy() TRUE with a completely dead price engine");
        assertEq(o.sma20(), smaBefore, "sma20() still gates the strike -> mint proceeds");
    }

    /// The same hole, reached by an OWNER route migration rather than a pool failure.
    function test_PoC1b_clearRouteDoesNotStopRedemptionUntilNextUtcDay() public {
        MockV3Pool pool = _pool(1e8);
        _bind(pool);
        AlbPriceOracle o = new AlbPriceOracle(owner, ITwapSource(address(source)));
        _warm(o);

        vm.prank(owner);
        engine.clearRoute(address(alb)); // e.g. step 1 of a two-tx pool migration
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        source.consult();

        assertFalse(o.poke());
        assertTrue(o.isHealthy(), "unrouted ALB still reports HEALTHY");
        assertGt(o.sma20(), 0);

        // Only the next UTC day boundary closes it (poke() then reverts, and LoC's
        // unguarded poke() propagates).
        vm.warp((block.timestamp / 1 days) * 1 days + 1 days + 1);
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        o.poke();
    }

    // =========================================================================
    // PoC 2: setTwapSource(_, purge=true) zeroes `count`, which silently disables
    // safeSpotPrice()'s MAX_SPOT_RATIO sanity band for the whole 20-day re-warm.
    // POLHolder consumes safeSpotPrice() UNGUARDED at 654 / 770 / 850 / 1349.
    // =========================================================================
    function test_PoC2_purgeDisablesSafeSpotPriceSanityBandFor20Days() public {
        MockV3Pool pool = _pool(1e8); // $1
        _bind(pool);
        AlbPriceOracle o = new AlbPriceOracle(owner, ITwapSource(address(source)));
        _warm(o);
        assertEq(o.count(), 20);

        // While warm, a 100x read is rejected by the ratio band.
        MockV3Pool crazy = _pool(100e8);
        _bind(crazy);
        vm.expectRevert(AlbPriceOracle.UnhealthyOracle.selector);
        o.safeSpotPrice();

        // Owner re-points the SMA oracle at a fresh (identical) adapter with purge=true.
        _bind(pool);
        AlbTwapSource fresh = new AlbTwapSource(engine, address(alb));
        vm.prank(owner);
        o.setTwapSource(ITwapSource(address(fresh)), true);
        assertEq(o.count(), 0, "purge resets count");

        // The very same 100x read now sails through: count < SAMPLES skips lines 119-128.
        _bind(crazy);
        uint256 p = o.safeSpotPrice();
        assertApproxEqRel(p, 100e8, 0.02e18, "unsanitised 100x spot accepted after purge");
    }

    // =========================================================================
    // PoC 3: an owner route change is an INSTANT step change in every price the
    // system reads - no smoothing on safeSpotPrice()/priceOf(), and it is the
    // value POLHolder compares against its cross-tx `lastRecordedPrice` snapshot.
    // =========================================================================
    function test_PoC3_routeChangeStepsThePriceInstantly() public {
        MockV3Pool a = _pool(1e8);
        _bind(a);
        uint256 before_ = engine.priceOf(address(alb));

        MockV3Pool b = _pool(2e8);
        _bind(b);
        uint256 after_ = engine.priceOf(address(alb));

        assertApproxEqRel(after_, before_ * 2, 0.02e18, "one setRoute tx doubles the price");
        // POLHolder._executeHarvest (1234-1243) reads this as 100% "yield":
        // yieldAmount = bal * (px - last) / px = bal/2 -> authorises selling HALF the position.
        uint256 bal = 1_000_000e18;
        uint256 yieldAmount = (bal * (after_ - before_)) / after_;
        assertApproxEqRel(yieldAmount, bal / 2, 0.03e18);
    }

    // =========================================================================
    // PoC 4: the per-sample clamp is TWO-SIDED, contradicting the documented
    // rationale at AlbPriceOracle.sol:37-43 ("Only the up direction is clamped
    // ... Downward moves pass through unclamped so a genuine crash is reflected
    // promptly"). Code: lines 212-215 clamp `down` as well.
    // =========================================================================
    function test_PoC4_downwardClampExtendsTheObsoleteStrikeWindow() public {
        MockTwapSource m = new MockTwapSource(1e8, 8);
        AlbPriceOracle o = new AlbPriceOracle(owner, ITwapSource(address(m)));
        {
            uint256 w = block.timestamp;
            for (uint256 i; i < 20; ++i) {
                w += 1 days;
                vm.warp(w);
                m.touch();
                o.poke();
            }
        }
        assertEq(o.sma20(), 1e8);

        // ALB crashes 90%: $1.00 -> $0.10.
        m.setPrice(1e7);

        uint256 strike = 0.9e8; // an option struck at $0.90
        uint256 daysClamped;
        uint256 t = block.timestamp;
        for (uint256 i; i < 30; ++i) {
            t += 1 days;
            vm.warp(t);
            m.touch();
            o.poke();
            if (o.sma20() < strike) {
                daysClamped = i + 1;
                break;
            }
        }
        assertEq(daysClamped, 7, "clamped: 7 days of redemption at an obsolete strike");

        // Unclamped reference: the same crash, samples written raw.
        uint256 sum = 20 * 1e8;
        uint256 daysRaw;
        for (uint256 i = 1; i <= 30; ++i) {
            sum = sum - 1e8 + 1e7;
            if (sum / 20 < strike) {
                daysRaw = i;
                break;
            }
        }
        assertEq(daysRaw, 3, "unclamped (as documented): 3 days");
    }

    // =========================================================================
    // PoC 5: setMinLiquidity(0) turns off the "load-bearing anti-JIT check" for
    // EVERY pool at once, with no lower bound (unlike setTwapPeriod/setMaxDeviation).
    // =========================================================================
    function test_PoC5_setMinLiquidityZeroDisablesAntiJit() public {
        MockV3Pool pool = _pool(1e8);
        _bind(pool);
        pool.setLiquidity(type(uint128).max);
        pool.setTwaLiquidity(1); // classic JIT shape
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));

        vm.prank(owner);
        engine.setMinLiquidity(0); // accepted: no bound check
        assertApproxEqRel(engine.twapPrice(address(alb)), 1e8, 0.01e18, "JIT pool now prices");

        // And a per-pool floor of zero is unrepresentable: 0 means "fall back to global".
        vm.prank(owner);
        engine.setMinLiquidity(1e18);
        vm.prank(owner);
        engine.setPoolMinLiquidity(address(pool), 0);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));
    }

    // =========================================================================
    // PoC 6: decimals() agreement (POLHolder:276) does not imply UNIT agreement.
    // IAssetOracle.priceOf = USD per 1e18 BASE UNITS; AlbPriceOracle.safeSpotPrice/
    // sma20 = USD per WHOLE token (UniV3TwapOracle.twapPrice:174-177 multiplies by
    // 10**decimalsOf(token)). They coincide only because ALB happens to be 18dp.
    // =========================================================================
    function test_PoC6_twapPriceAndPriceOfDivergeForNon18dpTokens() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        int24 tick = address(six) < address(usdc) ? _tickFor(1e6, 1e6) : _tickFor(1e6, 1e6);
        MockV3Pool p6 = new MockV3Pool(address(six), address(usdc), tick, 1e20, 100);
        vm.prank(owner);
        engine.setRoute(address(six), address(p6), address(0), address(0));

        uint256 per1e18 = engine.priceOf(address(six));   // POLHolder / IAssetOracle unit
        uint256 perWhole = engine.twapPrice(address(six)); // AlbTwapSource / ITwapSource unit
        assertEq(per1e18 / perWhole, 1e12, "same oracle, same decimals(), 1e12x different unit");
        assertEq(engine.decimals(), 8);
    }
}

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

contract TwapOracleTest is Test {
    address internal owner = makeAddr("owner");

    MockERC20 internal alb;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV3Factory internal factory;
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

        factory = new MockV3Factory();
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        vm.prank(owner);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), factories);
        source = new AlbTwapSource(engine, address(alb));
    }

    function _makeAlbUsdcPool(uint256 usdPrice8dp) internal returns (MockV3Pool pool) {
        uint256 usdcPerAlbScaled = (usdPrice8dp * 1e6) / 1e8;
        int24 tick;
        if (address(alb) < address(usdc)) {
            tick = _tickFor(usdcPerAlbScaled, 1e18);
        } else {
            tick = _tickFor(1e18, usdcPerAlbScaled);
        }
        pool = new MockV3Pool(address(alb), address(usdc), tick, 1e20, 100);
        factory.setPool(address(alb), address(usdc), 500, address(pool));
        vm.prank(owner);
        engine.setRoute(address(alb), address(pool), address(0), address(0));
    }

    function test_pricesAlbAgainstUsdcNumeraire() public {
        _makeAlbUsdcPool(1e8);
        uint256 p = engine.twapPrice(address(alb));
        assertApproxEqRel(p, 1e8, 0.01e18, "1 ALB should read ~$1.00");
    }

    function test_pricesAtNonUnitValue() public {
        _makeAlbUsdcPool(250e8);
        assertApproxEqRel(engine.twapPrice(address(alb)), 250e8, 0.01e18);
    }

    function test_usdcIsTheNumeraire() public view {
        assertEq(engine.priceOf(address(usdc)), 1e12 * 1e8);
    }

    function test_priceOfFollowsPolHolderConvention() public {
        _makeAlbUsdcPool(2e8);
        uint256 per1e18 = engine.priceOf(address(alb));
        uint256 valueOf5Alb = (5e18 * per1e18) / 1e18;
        assertApproxEqRel(valueOf5Alb, 10e8, 0.01e18, "5 ALB at $2 == $10");
    }

    function test_spotVsTwapDeviationRejected() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        int24 base = pool.twapTick();

        pool.setTicks(base, base + 20000);
        vm.expectRevert(UniV3TwapOracle.TwapDeviationTooHigh.selector);
        engine.twapPrice(address(alb));
        assertTrue(engine.isStale(address(alb)), "unavailable price must report stale");
    }

    function test_thinPoolRejectedOnRead() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        pool.setLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));
    }

    function test_jitLiquiditySpikeRejected() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        pool.setLiquidity(type(uint128).max);
        pool.setTwaLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));
    }

    function test_lowCardinalityRejectedOnRead() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        pool.setCardinality(2);
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        engine.twapPrice(address(alb));
    }

    function test_routeBindingIsOwnerOnly() public {
        MockV3Pool pool = new MockV3Pool(address(alb), address(usdc), 0, 1e20, 100);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        engine.setRoute(address(alb), address(pool), address(0), address(0));
    }

    function test_routeRejectsPoolWithWrongTokens() public {
        MockV3Pool wrong = new MockV3Pool(address(weth), address(usdc), 0, 1e20, 100);
        vm.prank(owner);
        vm.expectRevert(UniV3TwapOracle.PoolTokenMismatch.selector);
        engine.setRoute(address(alb), address(wrong), address(0), address(0));
    }

    function test_ownerCanClearAndRepointRoute() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        pool.setLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));

        vm.prank(owner);
        engine.clearRoute(address(alb));
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        engine.twapPrice(address(alb));

        MockV3Pool healthy = new MockV3Pool(address(alb), address(usdc), pool.twapTick(), 1e20, 100);
        vm.prank(owner);
        engine.setRoute(address(alb), address(healthy), address(0), address(0));
        assertApproxEqRel(engine.twapPrice(address(alb)), 1e8, 0.01e18);
    }

    function test_pinnedPoolRevalidatedOnEveryRead() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        assertApproxEqRel(engine.twapPrice(address(alb)), 1e8, 0.01e18);

        pool.setLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        engine.twapPrice(address(alb));

        pool.setLiquidity(1e20);
        pool.setCardinality(2);
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        engine.twapPrice(address(alb));
    }

    function test_unconfiguredRouteReverts() public {
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        engine.twapPrice(address(alb));
        assertTrue(engine.isStale(address(alb)));
        (uint256 p, bool ok) = engine.tryPriceOf(address(alb));
        assertEq(p, 0);
        assertFalse(ok);
    }

    function test_deepestPoolWins() public {
        MockV3Pool shallow = _makeAlbUsdcPool(1e8);
        shallow.setLiquidity(2e18);

        int24 tick = shallow.twapTick();
        MockV3Pool deep = new MockV3Pool(address(alb), address(usdc), tick, 9e20, 100);
        factory.setPool(address(alb), address(usdc), 3000, address(deep));

        assertEq(engine.suggestPool(address(alb), address(usdc)), address(deep));
    }

    function test_tryPriceOfMatchesPriceOf() public {
        _makeAlbUsdcPool(3e8);
        (uint256 p, bool ok) = engine.tryPriceOf(address(alb));
        assertTrue(ok);
        assertEq(p, engine.priceOf(address(alb)));
    }

    function test_onlyOwnerConfigures() public {
        vm.expectRevert();
        engine.setTwapPeriod(600);
        vm.prank(owner);
        engine.setTwapPeriod(600);
        assertEq(engine.twapPeriod(), 600);
    }

    function test_twapPeriodBounded() public {
        vm.startPrank(owner);
        vm.expectRevert(UniV3TwapOracle.InvalidTwapPeriod.selector);
        engine.setTwapPeriod(59);
        vm.expectRevert(UniV3TwapOracle.InvalidTwapPeriod.selector);
        engine.setTwapPeriod(86401);
        vm.stopPrank();
    }

    function test_routesThroughWethWhenNoDirectPool() public {
        int24 albWethTick = address(alb) < address(weth)
            ? _tickFor(1e15, 1e18)
            : _tickFor(1e18, 1e15);
        MockV3Pool albWeth = new MockV3Pool(address(alb), address(weth), albWethTick, 1e20, 100);
        factory.setPool(address(alb), address(weth), 500, address(albWeth));

        uint256 usdcPerWeth = 2000e6;
        int24 wethUsdcTick = address(weth) < address(usdc)
            ? _tickFor(usdcPerWeth, 1e18)
            : _tickFor(1e18, usdcPerWeth);
        MockV3Pool wethUsdc = new MockV3Pool(address(weth), address(usdc), wethUsdcTick, 1e20, 100);
        factory.setPool(address(weth), address(usdc), 500, address(wethUsdc));
        vm.prank(owner);
        engine.setRoute(address(alb), address(albWeth), address(wethUsdc), address(weth));

        assertApproxEqRel(engine.twapPrice(address(alb)), 2e8, 0.02e18, "ALB via WETH hop == $2");
    }

    function test_sourceFeedsSmaBuffer() public {
        _makeAlbUsdcPool(1e8);

        vm.prank(owner);
        AlbPriceOracle smaOracle = new AlbPriceOracle(owner, ITwapSource(address(source)));
        assertEq(smaOracle.decimals(), 8, "SMA oracle inherits the TWAP source decimals");

        uint256 t = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            t += 1 days;
            vm.warp(t);
            smaOracle.poke();
        }
        assertTrue(smaOracle.isHealthy(), "20 daily TWAP samples => warm and healthy");
        assertApproxEqRel(smaOracle.sma20(), 1e8, 0.01e18);
        assertApproxEqRel(smaOracle.safeSpotPrice(), 1e8, 0.01e18);
    }

    function test_sourceIsCurrentWhileLiveAndCanBeUnavailable() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        assertEq(source.lastUpdate(), block.timestamp, "a trading pool is current");

        pool.setLiquidity(1);
        vm.expectRevert(UniV3TwapOracle.InsufficientLiquidity.selector);
        source.consult();
    }

    function test_sourceReportsRealAgeWhenThePoolGoesDark() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        pool.freezeObservations();
        vm.warp(block.timestamp + 3 days);

        assertEq(block.timestamp - source.lastUpdate(), 3 days, "reports the true age");
        vm.expectRevert(UniV3TwapOracle.StaleObservation.selector);
        source.consult();
    }

    function test_smaPokeRevertsWhenTwapUnavailable() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        vm.prank(owner);
        AlbPriceOracle smaOracle = new AlbPriceOracle(owner, ITwapSource(address(source)));

        pool.setCardinality(2);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(UniV3TwapOracle.InsufficientObservations.selector);
        smaOracle.poke();
    }

    function test_rogueDeepPoolCannotHijackPricing() public {
        _makeAlbUsdcPool(1e8);
        MockV3Pool rogue = new MockV3Pool(address(alb), address(usdc), 60000, type(uint128).max, 100);
        factory.setPool(address(alb), address(usdc), 10000, address(rogue));

        assertEq(engine.suggestPool(address(alb), address(usdc)), address(rogue));

        assertApproxEqRel(engine.twapPrice(address(alb)), 1e8, 0.01e18);
    }
}

contract TwapOracleAdminLeverTest is TwapOracleTest {
    address internal ADMIN = makeAddr("engineAdmin");

    function test_ownerRePinClearsASuspension() public {
        MockV3Pool pool = _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);
        vm.prank(ADMIN); engine.suspendRoute(address(alb));
        (, bool ok) = engine.tryPriceOf(address(alb));
        assertFalse(ok);

        vm.prank(owner); engine.setRoute(address(alb), address(pool), address(0), address(0));
        assertFalse(engine.routeSuspended(address(alb)), "suspension lifted by the re-pin");
        assertGt(engine.priceOf(address(alb)), 0);
    }

    function test_adminSuspendsRouteAndOnlyOwnerResumesOrClears() public {
        _makeAlbUsdcPool(1e8);
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(ADMIN, role);
        assertGt(engine.priceOf(address(alb)), 0);

        vm.prank(ADMIN); engine.suspendRoute(address(alb));
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        engine.priceOf(address(alb));
        (, bool ok) = engine.tryPriceOf(address(alb));
        assertFalse(ok, "consumers fail closed while suspended");

        vm.prank(ADMIN);
        vm.expectRevert();
        engine.unsuspendRoute(address(alb));
        vm.prank(owner); engine.unsuspendRoute(address(alb));
        assertGt(engine.priceOf(address(alb)), 0, "service restored without a re-pin");

        vm.prank(ADMIN);
        vm.expectRevert();
        engine.clearRoute(address(alb));
        vm.prank(ADMIN);
        vm.expectRevert(UniV3TwapOracle.RouteNotConfigured.selector);
        engine.suspendRoute(makeAddr("unrouted"));
    }
}

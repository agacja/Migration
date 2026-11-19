// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../../src/oracle/AlbTwapSource.sol";
import {AlbPriceOracle, ITwapSource} from "../../src/oracle/AlbPriceOracle.sol";
import {MockERC20} from "../Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../MocksV3.sol";

contract CodeReality26_0 is Test {
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");

    MockERC20 internal alb;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV3Factory internal factory;
    UniV3TwapOracle internal engine;
    AlbTwapSource internal source;
    AlbPriceOracle internal sma;
    MockV3Pool internal pool;

    uint256 internal constant T0 = 1_700_000_000;

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
        vm.warp(T0);
        alb = new MockERC20("AlienBase", "ALB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        factory = new MockV3Factory();
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), factories);
        source = new AlbTwapSource(engine, address(alb));
        int24 tick = _tickForPrice(1e8);
        pool = new MockV3Pool(address(alb), address(usdc), tick, 1e20, 100);
        factory.setPool(address(alb), address(usdc), 500, address(pool));
        vm.prank(owner);
        engine.setRoute(address(alb), address(pool), address(0), address(0));
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner);
        engine.grantRoles(admin, role);
        sma = new AlbPriceOracle(owner, ITwapSource(address(source)));
    }

    function _warm() internal returns (uint256 t) {
        for (uint256 d = 1; d <= 20; ++d) {
            t = T0 + d * 1 days;
            vm.warp(t);
            vm.prank(keeper);
            sma.poke();
        }
        assertEq(sma.distinctDays(), 20);
        assertEq(sma.count(), 20);
        assertTrue(sma.isHealthy(), "warm");
    }

    function test_fiveDaySuspensionRequiresFreshWindow() public {
        _warm();
        vm.prank(admin);
        engine.suspendRoute(address(alb));

        assertEq(source.lastUpdate(), 0, "suspended -> lastUpdate 0");
        assertFalse(sma.isHealthy(), "unhealthy immediately");
        vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
        sma.safeSpotPrice();

        for (uint256 d = 21; d <= 24; ++d) {
            vm.warp(T0 + d * 1 days);
            vm.prank(keeper);
            vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
            sma.poke();
        }

        vm.warp(T0 + 25 days);
        vm.prank(owner);
        engine.unsuspendRoute(address(alb));
        vm.prank(keeper);
        assertTrue(sma.poke());
        assertEq(sma.distinctDays(), 1, "long gap resets warmth");
        assertEq(sma.count(), 1, "purged old samples, wrote one");
        assertFalse(sma.isHealthy(), "still NotWarm on day 25");
        vm.expectRevert(AlbPriceOracle.NotWarm.selector);
        sma.sma20();

        for (uint256 d = 26; d <= 43; ++d) {
            vm.warp(T0 + d * 1 days);
            vm.prank(keeper);
            sma.poke();
            assertFalse(sma.isHealthy(), "unhealthy through day 43");
        }
        vm.warp(T0 + 44 days);
        vm.prank(keeper);
        sma.poke();
        assertTrue(sma.isHealthy(), "healthy on day 44 after 20 fresh samples");
        sma.sma20();
    }

    function test_threeDaySuspensionNoWarmthLoss() public {
        _warm();
        vm.prank(admin);
        engine.suspendRoute(address(alb));
        vm.warp(T0 + 23 days + 1 hours);
        vm.prank(owner);
        engine.unsuspendRoute(address(alb));
        assertFalse(sma.isHealthy(), "buffer stale before poke");
        vm.prank(keeper);
        sma.poke();
        assertEq(sma.distinctDays(), 20);
        assertEq(sma.count(), 20);
        assertTrue(sma.isHealthy(), "g=3: no decay");
    }

    function test_twentyDaySuspensionCostsThirtyNineDays() public {
        _warm();
        vm.prank(admin);
        engine.suspendRoute(address(alb));
        vm.warp(T0 + 40 days);
        vm.prank(owner);
        engine.unsuspendRoute(address(alb));
        vm.prank(keeper);
        sma.poke();
        assertEq(sma.distinctDays(), 1, "purged");
        for (uint256 d = 41; d <= 58; ++d) {
            vm.warp(T0 + d * 1 days);
            vm.prank(keeper);
            sma.poke();
            assertFalse(sma.isHealthy());
        }
        vm.warp(T0 + 59 days);
        vm.prank(keeper);
        sma.poke();
        assertTrue(sma.isHealthy(), "healthy on day 59 = 20 + 39");
    }

    function test_sourceReplacementCannotAvoidLongGapPurge() public {
        _warm();
        vm.prank(admin);
        engine.suspendRoute(address(alb));
        vm.warp(T0 + 30 days);
        vm.prank(owner);
        engine.unsuspendRoute(address(alb));
        AlbTwapSource fresh = new AlbTwapSource(engine, address(alb));
        vm.prank(owner);
        sma.setTwapSource(ITwapSource(address(fresh)), false);
        assertEq(sma.lastSampleAt(), uint64(((T0 + 20 days) / 1 days) * 1 days), "lastSampleAt untouched");
        vm.prank(keeper);
        sma.poke();
        assertEq(sma.distinctDays(), 1, "long gap still resets warmth");
        assertFalse(sma.isHealthy());
    }
}

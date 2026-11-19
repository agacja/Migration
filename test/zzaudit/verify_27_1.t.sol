// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {MockERC20} from "../Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../MocksV3.sol";

contract Verify27_1 is Test {
    address internal owner = makeAddr("owner");
    address internal ADMIN = makeAddr("engineAdmin");
    MockERC20 internal alb;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockV3Factory internal factory;
    UniV3TwapOracle internal engine;
    MockV3Pool internal albWeth;
    MockV3Pool internal wethUsdc;

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

        int24 albWethTick = address(alb) < address(weth) ? _tickFor(1e15, 1e18) : _tickFor(1e18, 1e15);
        albWeth = new MockV3Pool(address(alb), address(weth), albWethTick, 1e20, 100);
        factory.setPool(address(alb), address(weth), 500, address(albWeth));

        uint256 usdcPerWeth = 2000e6;
        int24 wethUsdcTick = address(weth) < address(usdc) ? _tickFor(usdcPerWeth, 1e18) : _tickFor(1e18, usdcPerWeth);
        wethUsdc = new MockV3Pool(address(weth), address(usdc), wethUsdcTick, 1e20, 100);
        factory.setPool(address(weth), address(usdc), 500, address(wethUsdc));

        vm.startPrank(owner);
        engine.setRoute(address(weth), address(wethUsdc), address(0), address(0));
        engine.setRoute(address(alb), address(albWeth), address(wethUsdc), address(weth));
        vm.stopPrank();

        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner);
        engine.grantRoles(ADMIN, role);
    }

    function test_suspendingIntermediateDoesNotDarkTwoHopRoutes() public {
        (, bool okW0) = engine.tryPriceOf(address(weth));
        (, bool okA0) = engine.tryPriceOf(address(alb));
        assertTrue(okW0 && okA0, "both priced before");

        vm.prank(ADMIN);
        engine.suspendRoute(address(weth));

        (, bool okW) = engine.tryPriceOf(address(weth));
        assertFalse(okW, "WETH dark");
        (uint256 pA, bool okA) = engine.tryPriceOf(address(alb));

        assertTrue(okA, "ALB still priced via the suspended-asset's pool");
        assertApproxEqRel(pA, 2e8, 0.02e18);

        assertGt(engine.lastObservationAt(address(alb)), 0);
    }

    function test_adminCanDarkAlbByEnumerating() public {
        vm.startPrank(ADMIN);
        engine.suspendRoute(address(weth));
        engine.suspendRoute(address(alb));
        vm.stopPrank();
        (, bool okA) = engine.tryPriceOf(address(alb));
        assertFalse(okA);
    }
}

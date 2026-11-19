// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {MockERC20} from "../Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../MocksV3.sol";

contract CodeReality27_0 is Test {
    address owner = address(0xA11CE);
    address admin = address(0xAD1);
    MockERC20 alb; MockERC20 usdc; MockERC20 weth;
    UniV3TwapOracle engine;
    MockV3Pool albWeth; MockV3Pool wethUsdc;

    function setUp() public {
        vm.warp(1_700_000_000);
        alb = new MockERC20("AlienBase", "ALB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockV3Factory factory = new MockV3Factory();
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), factories);

        albWeth = new MockV3Pool(address(alb), address(weth), 0, 1e20, 100);
        wethUsdc = new MockV3Pool(address(weth), address(usdc), 0, 1e20, 100);

        vm.startPrank(owner);
        engine.grantRoles(admin, engine.ROLE_ADMIN());
        engine.setRoute(address(weth), address(wethUsdc), address(0), address(0));
        engine.setRoute(address(alb), address(albWeth), address(wethUsdc), address(weth));
        vm.stopPrank();
    }

    function test_suspendingIntermediateDoesNotDarkTwoHopRoutes() public {
        (, bool okW0) = engine.tryPriceOf(address(weth));
        (, bool okA0) = engine.tryPriceOf(address(alb));
        assertTrue(okW0, "weth prices pre");
        assertTrue(okA0, "alb prices pre");

        vm.prank(admin);
        engine.suspendRoute(address(weth));

        (, bool okW1) = engine.tryPriceOf(address(weth));
        assertFalse(okW1, "weth dark");

        (uint256 albPx, bool okA1) = engine.tryPriceOf(address(alb));
        assertTrue(okA1, "BAD: alb still prices through suspended-pool route");
        assertGt(albPx, 0);
        assertEq(engine.priceOf(address(alb)), albPx);

        assertGt(engine.lastObservationAt(address(alb)), 0);

        vm.prank(admin);
        vm.expectRevert();
        engine.setPoolMinLiquidity(address(wethUsdc), type(uint128).max);

        vm.prank(owner);
        engine.setPoolMinLiquidity(address(wethUsdc), type(uint128).max);
        (, bool okA2) = engine.tryPriceOf(address(alb));
        assertFalse(okA2, "owner per-pool floor darks alb");
    }
}

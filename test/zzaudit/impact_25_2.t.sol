// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniV3TwapOracle} from "../../src/oracle/UniV3TwapOracle.sol";
import {MockERC20} from "../Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../MocksV3.sol";

contract Impact25_2 is Test {
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    UniV3TwapOracle internal engine;
    MockERC20 internal alb; MockERC20 internal usdc; MockERC20 internal weth;
    MockV3Factory internal factory;

    function setUp() public {
        vm.warp(1_700_000_000);
        alb = new MockERC20("ALB", "ALB", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        factory = new MockV3Factory();
        address[] memory fs = new address[](1); fs[0] = address(factory);
        engine = new UniV3TwapOracle(owner, address(usdc), address(weth), fs);
        MockV3Pool pool = new MockV3Pool(address(alb), address(usdc), 0, 1e20, 100);
        factory.setPool(address(alb), address(usdc), 500, address(pool));
        vm.prank(owner); engine.setRoute(address(alb), address(pool), address(0), address(0));
        uint256 role = engine.ROLE_ADMIN();
        vm.prank(owner); engine.grantRoles(admin, role);
    }

    function test_workingTree_setRouteClearsSuspension() public {
        vm.prank(admin); engine.suspendRoute(address(alb));
        assertTrue(engine.routeSuspended(address(alb)));
        (, bool okDark) = engine.tryPriceOf(address(alb));
        assertFalse(okDark, "suspended must be dark");

        MockV3Pool fresh = new MockV3Pool(address(alb), address(usdc), 0, 1e20, 100);
        vm.prank(owner); engine.setRoute(address(alb), address(fresh), address(0), address(0));
        assertFalse(engine.routeSuspended(address(alb)), "re-pin must lift the suspension");
        (uint256 p, bool ok) = engine.tryPriceOf(address(alb));
        assertTrue(ok, "re-pinned route must price");
        assertGt(p, 0);
    }
}

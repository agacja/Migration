// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter, MockAssetOracle} from "./Mocks.sol";

contract OracleBlinder {
    MockAssetOracle public immutable oracle;

    constructor(MockAssetOracle o) { oracle = o; }

    function blind(address token, bool stale) external { oracle.setStale(token, stale); }
}

contract POLPricingEpochRegression is BaseTest {
    LoC internal polLoC;
    OracleBlinder internal blinder;
    POLHolder.Action[] internal noActions;
    uint128 internal constant RATE = 1 ether;

    function setUp() public override {
        super.setUp();
        polLoC = _createLoC(address(pol), 100_000_000 ether, 10_000_000 ether, 50_000_000 ether, 0);
        pol.setLoC(ILoC(address(polLoC)));
        pol.setRates(RATE, 0);
        pol.setDrawLimits(10_000_000 ether, 50_000_000 ether, 100_000_000 ether);
        pol.setAllowedAsset(address(usdc), true);
        pol.setAllowedAsset(address(wsteth), true);
        pol.setAssetEntry(address(usdc), 5000, 100, POLHolder.RewardMode.OUTRIGHT);
        pol.setAssetEntry(address(wsteth), 5000, 100, POLHolder.RewardMode.COMPOUNDING);
        pol.setStable(address(usdc), true);
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        blinder = new OracleBlinder(assetOracle);
        pol.setSwapTarget(address(blinder), true);
        pol.setActionPermission(address(blinder), OracleBlinder.blind.selector, address(0), true);
        vm.prank(DAO);
        alb.addMinter(address(router));
        _warmOracle();
        pol.setRates(0, 0);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        pol.setRates(RATE, 0);
    }

    function _swap(address tIn, uint256 aIn, address tOut, uint256 aOut)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.swap, (tIn, aIn, tOut, aOut));
        a.approveToken = tIn; a.approveSpender = address(router); a.approveAmount = aIn;
    }

    function _steal(address t, uint256 amt, address to)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.steal, (t, amt, to));
        a.approveToken = t; a.approveSpender = address(router); a.approveAmount = amt;
    }

    function _setStale(address t, bool s) internal view returns (POLHolder.Action memory a) {
        a.target = address(blinder);
        a.data = abi.encodeCall(OracleBlinder.blind, (t, s));
    }

    function _retiredPosition() internal returns (MockERC20 retired) {
        retired = new MockERC20("Retired", "RET", 18);
        assetOracle.setPrice(address(retired), 100e8);
        pol.setAllowedAsset(address(retired), true);
        pol.setAssetEntry(address(retired), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        retired.mint(address(pol), 10_000 ether);
    }

    function _deployDraw() internal {
        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 half = drawAmount / 2;
        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), half, address(usdc), half / 1e12);
        acts[1] = _swap(address(alb), drawAmount - half, address(wsteth), half / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, acts);
    }

    function _authorizeBurn(uint256 total, uint128 daily, uint128 maxPrice) internal {
        uint64 exp = uint64(block.timestamp + 30 days);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(total, daily, maxPrice, exp);
        pol.authorizeBurn(total, daily, maxPrice, exp, pol.burnNonce());
    }

    function test_burnCannotDrainAnAssetItBlindsMidLeg() public {
        MockERC20 retired = _retiredPosition();
        _deployDraw();
        _authorizeBurn(1_000_000e8, 1_000e8, 10e8);
        _skip(1 days);
        twap.touch();

        uint256 dust = wsteth.balanceOf(address(pol)) / 1000;
        POLHolder.Action[] memory acts = new POLHolder.Action[](3);
        acts[0] = _steal(address(retired), 10_000 ether, bob);
        acts[1] = _setStale(address(retired), true);
        acts[2] = _swap(address(wsteth), dust, address(alb), (dust * 3000e8) / 1e8);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.BudgetExhausted.selector);
        pol.executeBurn(acts);

        assertEq(retired.balanceOf(bob), 0, "position not extractable by blinding its own price");
        assertEq(retired.balanceOf(address(pol)), 10_000 ether, "position retained");
    }

    function test_rebalanceCannotDrainAnAssetItBlindsMidLeg() public {
        MockERC20 retired = _retiredPosition();

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _steal(address(retired), 10_000 ether, bob);
        acts[1] = _setStale(address(retired), true);

        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(7 hours);
        twap.touch();

        vm.prank(KEEPER);
        vm.expectRevert();
        pol.executeRebalance(acts);

        assertEq(retired.balanceOf(bob), 0, "rebalance leg holds the same line");
    }

    function test_yeetCannotManufactureGainByRevealingAPrice() public {
        MockERC20 retired = _retiredPosition();

        MockERC20 q = new MockERC20("Quiet", "Q", 18);
        assetOracle.setPrice(address(q), 100e8);
        pol.setAllowedAsset(address(q), true);
        pol.setAssetEntry(address(q), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        q.mint(address(pol), 10_000 ether);
        assetOracle.setStale(address(q), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _steal(address(retired), 10_000 ether, bob);
        acts[1] = _setStale(address(q), false);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(retired), keccak256(abi.encode(acts)), 900_000e8, uint64(block.timestamp + 1 days)
        );

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeYeet(address(retired), acts);

        assertEq(retired.balanceOf(bob), 0, "no sale against a gain that never entered");
        assertEq(q.balanceOf(address(pol)), 10_000 ether, "Q never moved");
    }

    function _stableOnly() internal returns (MockERC20 usdt) {
        usdt = new MockERC20("Tether", "USDT", 6);
        assetOracle.setPrice(address(usdt), 1e8 * 1e12);
        pol.setStable(address(usdt), true);
        usdt.mint(address(pol), 900_000e6);
    }

    function test_maintainSwapLegCannotManufactureGainByRevealingAPrice() public {
        MockERC20 q = _retiredPosition();
        MockERC20 usdt = _stableOnly();
        assetOracle.setStale(address(q), true);

        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 half = drawAmount / 2;

        POLHolder.Action[] memory acts = new POLHolder.Action[](4);
        acts[0] = _swap(address(alb), half, address(usdc), half / 1e12);
        acts[1] = _swap(address(alb), drawAmount - half, address(wsteth), half / 3000);
        acts[2] = _steal(address(usdt), 900_000e6, bob);
        acts[3] = _setStale(address(q), false);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);

        assertEq(usdt.balanceOf(bob), 0, "stable-only token not extractable against a phantom gain");
        assertEq(q.balanceOf(address(pol)), 10_000 ether, "Q never moved");
    }

    function test_rebalanceCannotManufactureGainByRevealingAPrice() public {
        MockERC20 q = _retiredPosition();
        assetOracle.setStale(address(q), true);
        _deployDraw();
        uint256 wst = wsteth.balanceOf(address(pol));
        assertGt(wst, 0);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _steal(address(wsteth), wst, bob);
        acts[1] = _setStale(address(q), false);

        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(7 hours);
        twap.touch();

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeRebalance(acts);

        assertEq(wsteth.balanceOf(bob), 0, "targeted position not extractable against a phantom gain");
        assertEq(q.balanceOf(address(pol)), 10_000 ether, "Q never moved");
    }

    function test_maintainRevertsIfAStableOnlyTokenIsDarkAtEntry() public {
        MockERC20 usdt = _stableOnly();
        assetOracle.setStale(address(usdt), true);
        _skip(1 hours);
        twap.touch();
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(alb), uint256(RATE) * 1 hours, address(wsteth), 1);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.maintain(noActions, acts);
    }

    function test_CONTROL_honestYeetStillLiquidates() public {
        MockERC20 retired = _retiredPosition();
        assetOracle.setStale(address(retired), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(retired), 10_000 ether, address(usdc), 900_000e6);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(retired), keccak256(abi.encode(acts)), 900_000e8, uint64(block.timestamp + 1 days)
        );
        vm.prank(KEEPER);
        pol.executeYeet(address(retired), acts);

        assertEq(retired.balanceOf(address(pol)), 0, "honest yeet still liquidates");
    }

    function test_CONTROL_honestBurnStillExecutes() public {
        _deployDraw();
        _authorizeBurn(10_000_000e8, 10_000_000e8, 10e8);
        _skip(1 days);
        twap.touch();

        uint256 sell = wsteth.balanceOf(address(pol)) / 2;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);

        uint256 drawn = polLoC.drawnAmount();
        vm.prank(KEEPER);
        pol.executeBurn(acts);
        assertLt(polLoC.drawnAmount(), drawn, "honest burn still repays debt");
    }
}

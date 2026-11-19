// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

contract POLLenientPricingRegression is BaseTest {
    LoC internal polLoC;
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

    function test_retiredDarkOracleAssetCannotBeDrained() public {
        MockERC20 retired = new MockERC20("Retired", "RET", 18);
        assetOracle.setPrice(address(retired), 100e8);
        pol.setAllowedAsset(address(retired), true);
        pol.setAssetEntry(address(retired), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        retired.mint(address(pol), 10_000 ether);

        assetOracle.setStale(address(retired), true);

        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 half = drawAmount / 2;

        POLHolder.Action[] memory acts = new POLHolder.Action[](3);

        acts[0] = _swap(address(alb), half, address(usdc), half / 1e12);
        acts[1] = _swap(address(alb), drawAmount - half, address(wsteth), half / 3000);

        acts[2] = _steal(address(retired), 10_000 ether, bob);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);

        assertEq(retired.balanceOf(bob), 0, "retired position frozen while unpriceable");
        assertEq(retired.balanceOf(address(pol)), 10_000 ether);
    }

    function test_retiredDarkOracleAssetIsStillYeetable() public {
        MockERC20 retired = new MockERC20("Retired", "RET", 18);
        assetOracle.setPrice(address(retired), 100e8);
        pol.setAllowedAsset(address(retired), true);
        pol.setAssetEntry(address(retired), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        retired.mint(address(pol), 10_000 ether);
        assetOracle.setStale(address(retired), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(retired), 10_000 ether, address(usdc), 900_000e6);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(retired), keccak256(abi.encode(acts)), 900_000e8, uint64(block.timestamp + 1 days)
        );
        vm.prank(KEEPER);
        pol.executeYeet(address(retired), acts);

        assertEq(retired.balanceOf(address(pol)), 0, "yeet still liquidates a dark-oracle position");
    }
}

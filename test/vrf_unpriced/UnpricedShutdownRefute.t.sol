// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "../ActionPermissionSetup.sol";

import {BaseTest} from "../Base.t.sol";
import {POLHolder} from "../../src/pol/POLHolder.sol";
import {POLHolderNoGuard} from "./POLHolderNoGuard.sol";
import {LoC} from "../../src/loc/LoC.sol";
import {ILoC} from "../../src/interfaces/ILoC.sol";
import {IALB} from "../../src/interfaces/IALB.sol";
import {IAlbPriceOracle} from "../../src/interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../../src/interfaces/IAssetOracle.sol";
import {MockERC20, MockRouter} from "../Mocks.sol";

contract UnpricedShutdownRefute is BaseTest {
    LoC internal polLoC;
    POLHolder.Action[] internal noActions;
    uint128 internal constant RATE = 1 ether;
    MockERC20 internal dai;

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

        dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);
    }

    function _swap(address tIn, uint256 aIn, address tOut, uint256 aOut)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.swap, (tIn, aIn, tOut, aOut));
        a.approveToken = tIn; a.approveSpender = address(router); a.approveAmount = aIn;
    }

    function _balancedSwaps(uint256 d) internal view returns (POLHolder.Action[] memory acts) {
        uint256 h = d / 2;
        acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), h, address(usdc), h / 1e12);
        acts[1] = _swap(address(alb), d - h, address(wsteth), h / 3000);
    }

    function _maintain(uint256 e) internal {
        _skip(e); twap.touch();
        vm.prank(KEEPER);
        pol.maintain(noActions, _balancedSwaps(uint256(RATE) * e));
    }

    function test_shutdownStillExecutesWhileAnOracleIsDark() public {
        _maintain(2 hours);
        assetOracle.setStale(address(wsteth), true);

        uint256 uBal = usdc.balanceOf(address(pol));
        assertGt(uBal, 0);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(usdc), uBal, address(dai), uBal * 1e12);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));
        vm.prank(KEEPER);
        pol.executeEmergencyShutdown(acts);

        assertEq(usdc.balanceOf(address(pol)), 0, "priced asset fully liquidated");
        assertEq(dai.balanceOf(address(pol)), uBal * 1e12, "proceeds landed in stables");
    }

    function test_withoutGuardOperatorDrainsDarkOracleAssetForFree() public {
        POLHolderNoGuard ng = new POLHolderNoGuard(
            address(this),
            IALB(address(alb)),
            IAlbPriceOracle(address(oracle)),
            IAssetOracle(address(assetOracle))
        );
        ng.grantRoles(POL_ADMIN, ng.ROLE_ADMIN());
        ng.grantRoles(KEEPER, ng.ROLE_OPERATOR());
        LoC l2 = _createLoC(address(ng), 100_000_000 ether, 10_000_000 ether, 50_000_000 ether, 0);
        ng.setLoC(ILoC(address(l2)));
        ng.setDrawLimits(10_000_000 ether, 50_000_000 ether, 100_000_000 ether);
        ng.setAllowedAsset(address(usdc), true);
        ng.setAllowedAsset(address(wsteth), true);
        ng.setAssetEntry(address(usdc), 5000, 100, POLHolderNoGuard.RewardMode.OUTRIGHT);
        ng.setAssetEntry(address(wsteth), 5000, 100, POLHolderNoGuard.RewardMode.COMPOUNDING);
        ng.setStable(address(usdc), true);
        ng.setStable(address(dai), true);
        ng.setSwapTarget(address(router), true);

        wsteth.mint(address(ng), 1000 ether);
        usdc.mint(address(ng), 1_000_000e6);

        assetOracle.setStale(address(wsteth), true);

        POLHolderNoGuard.Action[] memory acts = new POLHolderNoGuard.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.swap, (address(wsteth), 1000 ether, address(dai), 1));
        acts[0].approveToken = address(wsteth);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = 1000 ether;

        vm.prank(POL_ADMIN);
        ng.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));
        vm.prank(KEEPER);
        ng.executeEmergencyShutdown(acts);

        assertEq(wsteth.balanceOf(address(ng)), 0, "$3M walked out for 1 wei");
    }

    function test_realContractStopsBothHonestAndDishonestUnpricedSale() public {
        _maintain(2 hours);
        wsteth.mint(address(pol), 1000 ether);
        assetOracle.setStale(address(wsteth), true);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory theft = new POLHolder.Action[](1);
        theft[0] = _swap(address(wsteth), bal, address(dai), 1);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(theft);

        POLHolder.Action[] memory honest = new POLHolder.Action[](1);
        honest[0] = _swap(address(wsteth), bal, address(dai), bal * 3000);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(honest);
    }

    function test_yeetMovesTheDarkOracleAssetWithAdminFloor() public {
        _maintain(2 hours);
        wsteth.mint(address(pol), 1000 ether);
        assetOracle.setStale(address(wsteth), true);

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(dai), bal * 3000);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth),
            keccak256(abi.encode(acts)),
            uint128((bal * 3000) / 1e10),
            uint64(block.timestamp + 2 days)
        );
        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);
        assertEq(wsteth.balanceOf(address(pol)), 0, "dark-oracle asset liquidated via yeet");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../test/Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "../test/Mocks.sol";

contract ExtraPoC is BaseTest {
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
        pol.setSwapTarget(address(router), true);
        dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);
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

    function _maintain(uint256 e) internal returns (uint256 d) {
        _skip(e); twap.touch();
        d = uint256(RATE) * e;
        uint256 h = d / 2;
        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), h, address(usdc), h / 1e12);
        acts[1] = _swap(address(alb), d - h, address(wsteth), h / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, acts);
    }

    /// CONTROL for the shutdown finding: the identical call succeeds when the
    /// asset is priceable, so `_requireUnpricedNotDrained` is the sole blocker.
    function test_control_shutdownLiquidatesPricedAsset() public {
        _maintain(2 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(dai), bal * 3000);
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));
        vm.prank(KEEPER);
        pol.executeEmergencyShutdown(acts);
        assertEq(wsteth.balanceOf(address(pol)), 0);
    }

    /// executeYeet IS still usable on a dark-oracle asset (the only remaining route).
    function test_yeetStillWorksOnDarkOracleAsset() public {
        _maintain(2 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        assetOracle.setStale(address(wsteth), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(dai), bal * 3000);
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), keccak256(abi.encode(acts)), 1e8, uint64(block.timestamp + 1 days));
        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);
        assertEq(wsteth.balanceOf(address(pol)), 0, "yeet works when shutdown does not");
    }

    /// 1 wei donation after a completed yeet permanently blocks removeAsset.
    function test_dustDonationBlocksRemoveAssetForever() public {
        _maintain(2 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(dai), bal * 3000);
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), keccak256(abi.encode(acts)), 1e8, uint64(block.timestamp + 1 days));
        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);

        // Griefer donates 1 wei.
        wsteth.mint(address(pol), 1);
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.removeAsset(address(wsteth));
    }
}

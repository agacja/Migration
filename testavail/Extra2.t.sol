// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../test/Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "../test/Mocks.sol";

contract Extra2PoC is BaseTest {
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
    function _steal(address t, uint256 amt, address to)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.steal, (t, amt, to));
        a.approveToken = t; a.approveSpender = address(router); a.approveAmount = amt;
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

    /// WORKAROUND CHECK: does dual-listing the dead stable as a zero-weight portfolio
    /// entry unblock the draw leg and allow a wind-down?
    function test_workaround_listDeadStableAsZeroWeightAsset() public {
        dai.mint(address(pol), 500_000 ether);
        _maintain(1 hours);
        assetOracle.setStale(address(dai), true);

        _skip(1 hours); twap.touch();
        uint256 d = uint256(RATE) * 1 hours;
        POLHolder.Action[] memory sw = new POLHolder.Action[](2);
        sw[0] = _swap(address(alb), d / 2, address(usdc), (d / 2) / 1e12);
        sw[1] = _swap(address(alb), d - d / 2, address(wsteth), (d / 2) / 3000);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.maintain(noActions, sw);

        // Owner lists it as a zero-weight portfolio entry.
        pol.setAllowedAsset(address(dai), true);
        pol.setAssetEntry(address(dai), 0, 0, POLHolder.RewardMode.OUTRIGHT);

        // Draw leg is unblocked (_stableOnlyValue skips portfolio entries; _assetPrice is
        // lenient at targetBps == 0).
        _skip(1 hours); twap.touch();
        d = uint256(RATE) * 2 hours; // two hours accrued since the last SUCCESSFUL maintain
        POLHolder.Action[] memory sw2 = new POLHolder.Action[](2);
        sw2[0] = _swap(address(alb), d / 2, address(usdc), (d / 2) / 1e12);
        sw2[1] = _swap(address(alb), d - d / 2, address(wsteth), (d / 2) / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, sw2);
    }

    /// CRITICAL: executeBurn has no price-independent balance floor and
    /// _grossOutflowValue prices every stable / retired entry with _priceOrZero,
    /// so an unpriceable stable is FREE to route out during a burn.
    function test_burnDrainsUnpricedStableForFree() public {
        dai.mint(address(pol), 500_000 ether); // $500,000 stable buffer
        _maintain(2 hours);

        uint64 exp = uint64(block.timestamp + 30 days);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(1_000_000e8, 1000e8, 10e8, exp);
        pol.authorizeBurn(1_000_000e8, 1000e8, 10e8, exp, pol.burnNonce());
        _skip(1 days); twap.touch();

        // DAI's feed is dark (depeg blows the sanity band / route removed / TWAP deviation).
        assetOracle.setStale(address(dai), true);

        uint256 usd = 100e8;
        uint256 sell = (usd * 1e18) / 3000e8; // $100 of wstETH, an honest token sale
        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);
        acts[1] = _steal(address(dai), 500_000 ether, bob);

        // CLOSED mid-session by the _requireUnpricedNotDrained call added to _runBurnActions.
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeBurn(acts);
        assertEq(dai.balanceOf(bob), 0);
    }
}

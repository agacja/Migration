// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

contract POLValueInvariants is BaseTest {
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

    function _swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.swap, (tokenIn, amountIn, tokenOut, amountOut));
        a.approveToken = tokenIn;
        a.approveSpender = address(router);
        a.approveAmount = amountIn;
    }

    function _steal(address token, uint256 amount, address to)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.steal, (token, amount, to));
        a.approveToken = token;
        a.approveSpender = address(router);
        a.approveAmount = amount;
    }

    function _balancedSwaps(uint256 drawAmount) internal view returns (POLHolder.Action[] memory acts) {
        uint256 halfAlb = drawAmount / 2;
        acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), halfAlb, address(usdc), halfAlb / 1e12);
        acts[1] = _swap(address(alb), drawAmount - halfAlb, address(wsteth), halfAlb / 3000);
    }

    function _maintain(uint256 elapsed) internal returns (uint256 drawAmount) {
        _skip(elapsed);
        twap.touch();
        drawAmount = uint256(RATE) * elapsed;
        POLHolder.Action[] memory swaps = _balancedSwaps(drawAmount);
        vm.prank(KEEPER);
        pol.maintain(noActions, swaps);
    }

    function test_regression_burnBudgetGriefedToZero() public {
        _maintain(2 hours);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(10_000_000e8, 24_000e8, 10e8, uint64(block.timestamp + 30 days));
        pol.authorizeBurn(10_000_000e8, 24_000e8, 10e8, uint64(block.timestamp + 30 days), pol.burnNonce());

        for (uint256 i; i < 20; ++i) {
            _skip(1 hours);
            twap.touch();
            vm.prank(KEEPER);
            vm.expectRevert(POLHolder.NoOpExecution.selector);
            pol.executeBurn(noActions);
        }
        (,,,, uint128 spent,,,) = pol.burn();
        assertEq(spent, 0, "nothing burned");

        _skip(1 hours);
        twap.touch();
        uint256 usd = 2000e8;
        uint256 sell = (usd * 1e18) / 3000e8;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);
        vm.prank(KEEPER);
        pol.executeBurn(acts);
        (,,,, uint128 spent2,,,) = pol.burn();
        assertGe(spent2, (usd * 999) / 1000, "accrued budget preserved across the no-op attempts");
    }

    function test_regression_shutdownChurnDrainsUnbounded() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);

        _maintain(4 hours);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 24 hours));

        uint256 startValue = _trackedUsd();
        for (uint256 round; round < 5; ++round) {
            uint256 wst = wsteth.balanceOf(address(pol));
            uint256 fairDai = (wst * 3000e8) / 1e8;
            POLHolder.Action[] memory sell = new POLHolder.Action[](1);
            sell[0] = _swap(address(wsteth), wst, address(dai), (fairDai * 9700) / 10_000);
            vm.prank(KEEPER);
            pol.executeEmergencyShutdown(sell);

            uint256 daiBal = dai.balanceOf(address(pol));
            POLHolder.Action[] memory buy = new POLHolder.Action[](1);
            buy[0] = _swap(address(dai), daiBal, address(wsteth), (daiBal * 1e8) / 3000e8);
            vm.prank(KEEPER);
            vm.expectRevert(POLHolder.ToleranceBreach.selector);
            pol.executeEmergencyShutdown(buy);
        }
        uint256 endValue = _trackedUsd() + (dai.balanceOf(address(pol)) * 1e8) / 1e18;

        assertGe(endValue, (startValue * 96) / 100, "no unbounded bleed: the loop cannot cycle");
    }

    function test_regression_rewardsClaimedDuringHarvestAreStealable() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), 1000 ether));
        acts[1] = _steal(address(rwd), 1000 ether, bob);

        _skip(1 hours);
        twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(acts, noActions);

        assertEq(rwd.balanceOf(bob), 0, "harvest cannot be routed out without producing ALB");
    }

    function test_regression_drawnAlbSiphonedUsingRewardInflow() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        _maintain(1 hours);

        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 half = drawAmount / 2;
        uint256 rwdIn = (drawAmount * 1e8) / 5e8;

        POLHolder.Action[] memory acts = new POLHolder.Action[](4);

        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), rwdIn));

        acts[1] = _swap(address(rwd), rwdIn / 2, address(usdc), half / 1e12);
        acts[2] = _swap(address(rwd), rwdIn - rwdIn / 2, address(wsteth), half / 3000);

        acts[3] = _steal(address(alb), drawAmount, bob);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.maintain(noActions, acts);

        assertEq(alb.balanceOf(bob), 0, "drawn ALB stays put");
    }

    function test_regression_burnDcaBudgetBypassedByRewardInflow() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        _maintain(4 hours);

        vm.prank(POL_ADMIN);
        pol.proposeBurn(10_000_000e8, 1000e8, 10e8, uint64(block.timestamp + 30 days));
        pol.authorizeBurn(10_000_000e8, 1000e8, 10e8, uint64(block.timestamp + 30 days), pol.burnNonce());
        _skip(1 days);
        twap.touch();

        uint256 usd6000 = 6000e8;
        uint256 wstSell = (usd6000 * 1e18) / 3000e8;
        uint256 rwdIn = (5000e8 * 1e18) / 5e8;

        POLHolder.Action[] memory acts = new POLHolder.Action[](3);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), rwdIn));
        acts[1] = _swap(address(rwd), rwdIn, address(usdc), 5000e6);
        acts[2] = _swap(address(wsteth), wstSell, address(alb), 6000 ether);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.executeBurn(acts);

        (,,,, uint128 spent,,,) = pol.burn();
        assertEq(spent, 0, "nothing liquidated past the DCA budget");
    }

    function _trackedUsd() internal view returns (uint256) {
        return (usdc.balanceOf(address(pol)) * 1e12 * 1e8) / 1e18
            + (wsteth.balanceOf(address(pol)) * 3000e8) / 1e18;
    }

    function test_regression_yeetFloorMetByStaleAssetProceeds() public {
        MockERC20 xyz = new MockERC20("Stale", "XYZ", 18);
        assetOracle.setPrice(address(xyz), 1e8);
        pol.setStable(address(xyz), true);
        xyz.mint(address(pol), 100_000 ether);

        _maintain(4 hours);

        uint256 wst = wsteth.balanceOf(address(pol));
        uint256 wstUsd = (wst * 3000e8) / 1e18;
        assertGt(wstUsd, 0);

        assetOracle.setStale(address(xyz), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _steal(address(wsteth), wst, bob);
        acts[1] = _swap(address(xyz), 100_000 ether, address(usdc), 100_000e6);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth), keccak256(abi.encode(acts)), uint128(wstUsd), uint64(block.timestamp + 1 days)
        );

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeYeet(address(wsteth), acts);

        assertEq(wsteth.balanceOf(bob), 0, "yeeted position cannot be taken");
    }

    function test_regression_rebalanceLosesHalfPercentOfWholePortfolio() public {
        _maintain(4 hours);
        uint256 before_ = _trackedUsd();

        uint256 lossUsd = (before_ * 49) / 10_000;
        uint256 wstIn = (lossUsd * 1e18) / 3000e8;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), wstIn, address(usdc), 1);

        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(6 hours);
        twap.touch();

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeRebalance(acts);

        assertGe(_trackedUsd(), before_ - (lossUsd / 100), "portfolio intact");
    }
}

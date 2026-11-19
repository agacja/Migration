// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

contract POLAuditRegression is BaseTest {
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

    function test_regression_operatorStealsFreshlyClaimedRewards() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), 1000 ether));

        acts[1].target = address(router);
        acts[1].data = abi.encodeCall(MockRouter.steal, (address(rwd), 1000 ether, bob));
        acts[1].approveToken = address(rwd);
        acts[1].approveSpender = address(router);
        acts[1].approveAmount = 1000 ether;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(acts, noActions);

        assertEq(rwd.balanceOf(bob), 0, "harvest cannot be routed out");
    }

    function test_regression_operatorStealsRewardsInExecuteBurn() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);
        rwd.mint(address(pol), 1000 ether);

        vm.prank(POL_ADMIN);

        pol.proposeBurn(1_000_000e8, 1_000_000e8, type(uint128).max, uint64(block.timestamp + 30 days));

        pol.authorizeBurn(1_000_000e8, 1_000_000e8, type(uint128).max, uint64(block.timestamp + 30 days), pol.burnNonce());
        _skip(1 hours);
        twap.touch();

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(rwd), 1000 ether, bob));
        acts[0].approveToken = address(rwd);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = 1000 ether;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.executeBurn(acts);

        assertEq(rwd.balanceOf(bob), 0, "reward stash untouchable outside harvest");
    }

    function test_regression_oneWeiRewardDonationBricksMaintain() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        rwd.mint(address(pol), 1);

        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 halfAlb = drawAmount / 2;
        POLHolder.Action[] memory swaps = new POLHolder.Action[](2);
        swaps[0] = _mkSwap(address(alb), halfAlb, address(usdc), halfAlb / 1e12);
        swaps[1] = _mkSwap(address(alb), drawAmount - halfAlb, address(wsteth), halfAlb / 3000);

        vm.prank(KEEPER);
        pol.maintain(noActions, swaps);
        assertEq(rwd.balanceOf(address(pol)), 1, "dust retained, maintain unaffected");
    }

    function test_regression_donationRevivesDeadOracleAsset() public {
        MockERC20 dead = new MockERC20("Dead", "DEAD", 18);
        assetOracle.setPrice(address(dead), 1e8);
        pol.setAllowedAsset(address(dead), true);
        pol.setAssetEntry(address(dead), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        assetOracle.setStale(address(dead), true);

        _maintainOnce(1 hours);

        dead.mint(address(pol), 1);
        _skip(1 hours);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * 1 hours;
        uint256 halfAlb = drawAmount / 2;
        POLHolder.Action[] memory swaps = new POLHolder.Action[](2);
        swaps[0] = _mkSwap(address(alb), halfAlb, address(usdc), halfAlb / 1e12);
        swaps[1] = _mkSwap(address(alb), drawAmount - halfAlb, address(wsteth), halfAlb / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, swaps);
        assertEq(dead.balanceOf(address(pol)), 1, "dust retained, maintain unaffected");
    }

    function test_regression_shutdownDrainsStalePricedStable() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        MockERC20 frax = new MockERC20("Frax", "FRAX", 18);
        assetOracle.setPrice(address(dai), 1e8);
        assetOracle.setPrice(address(frax), 1e8);
        pol.setStable(address(dai), true);
        pol.setStable(address(frax), true);

        _maintainOnce(1 hours);
        frax.mint(address(pol), 500_000 ether);
        uint256 wst = wsteth.balanceOf(address(pol));

        assetOracle.setStale(address(frax), true);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(uint128((wst * 3000) / 1e18 * 1e8), type(uint128).max, uint64(block.timestamp + 24 hours));

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);

        acts[0] = _mkSwap(address(wsteth), wst, address(dai), (wst * 3000));

        acts[1].target = address(router);
        acts[1].data = abi.encodeCall(MockRouter.steal, (address(frax), 500_000 ether, bob));
        acts[1].approveToken = address(frax);
        acts[1].approveSpender = address(router);
        acts[1].approveAmount = 500_000 ether;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);

        assertEq(frax.balanceOf(bob), 0, "stable buffer intact");
        assertEq(frax.balanceOf(address(pol)), 500_000 ether);
    }

    function _mkSwap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.swap, (tokenIn, amountIn, tokenOut, amountOut));
        a.approveToken = tokenIn;
        a.approveSpender = address(router);
        a.approveAmount = amountIn;
    }

    function _maintainOnce(uint256 elapsed) internal {
        _skip(elapsed);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * elapsed;
        uint256 halfAlb = drawAmount / 2;
        POLHolder.Action[] memory swaps = new POLHolder.Action[](2);
        swaps[0] = _mkSwap(address(alb), halfAlb, address(usdc), halfAlb / 1e12);
        swaps[1] = _mkSwap(address(alb), drawAmount - halfAlb, address(wsteth), halfAlb / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, swaps);
    }
}

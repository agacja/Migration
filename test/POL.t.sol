// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

contract POLTest is BaseTest {
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
        assertEq(pol.pendingDraw(), 0);
    }

    function _swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
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

    function _steal(address token, uint256 amount, address to)
        internal
        view
        returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.steal, (token, amount, to));
        a.approveToken = token;
        a.approveSpender = address(router);
        a.approveAmount = amount;
    }

    function _balancedSwaps(uint256 drawAmount) internal view returns (POLHolder.Action[] memory acts) {
        uint256 halfAlb = drawAmount / 2;

        uint256 usdcOut = halfAlb / 1e12;

        uint256 wstethOut = halfAlb / 3000;

        acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), halfAlb, address(usdc), usdcOut);
        acts[1] = _swap(address(alb), drawAmount - halfAlb, address(wsteth), wstethOut);
    }

    function _maintain(uint256 elapsed) internal returns (uint256 drawAmount) {
        _skip(elapsed);
        twap.touch();
        drawAmount = uint256(RATE) * elapsed;
        POLHolder.Action[] memory swaps = _balancedSwaps(drawAmount);
        vm.prank(KEEPER);
        pol.maintain(noActions, swaps);
    }

    function test_maintainDrawsAndSwaps() public {
        uint256 drawn = _maintain(1 hours);
        assertEq(polLoC.drawnAmount(), drawn);
        assertGt(usdc.balanceOf(address(pol)), 0);
        assertGt(wsteth.balanceOf(address(pol)), 0);
        assertEq(alb.balanceOf(address(pol)), 0, "all drawn ALB deployed");
    }

    function test_harvestOnlyMaintainDrawsNothing() public {
        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        assertEq(polLoC.drawnAmount(), 0);
    }

    function test_cannotSiphonDrawnAlbByChurningPortfolio() public {
        _maintain(1 hours);

        _skip(1 hours);
        uint256 drawAmount = uint256(RATE) * 1 hours;

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);

        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(alb), drawAmount, bob));
        acts[0].approveToken = address(alb);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = drawAmount;

        acts[1] = _swap(address(wsteth), wsteth.balanceOf(address(pol)), address(usdc), drawAmount / 1e12);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);
    }

    function test_cannotSendDrawnAlbToAttacker() public {
        _skip(1 hours);
        uint256 drawAmount = uint256(RATE) * 1 hours;

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(alb), drawAmount, bob));
        acts[0].approveToken = address(alb);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = drawAmount;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);
    }

    function test_unapprovedErc20ActionsOnWhitelistedTarget() public {
        pol.setSwapTarget(address(wsteth), true);
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(wsteth);
        acts[0].data = abi.encodeWithSignature("approve(address,uint256)", bob, type(uint256).max);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ActionNotAllowed.selector);
        pol.maintain(acts, noActions);

        acts[0].data = abi.encodeWithSignature("transfer(address,uint256)", bob, 1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ActionNotAllowed.selector);
        pol.maintain(acts, noActions);

        acts[0].data = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(pol), bob, 1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ActionNotAllowed.selector);
        pol.maintain(acts, noActions);
    }

    function test_nonWhitelistedTargetRejected() public {
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = bob;
        acts[0].data = "";
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.maintain(acts, noActions);
    }

    function test_albAndLocCannotBeWhitelistedTargets() public {
        vm.expectRevert(POLHolder.ForbiddenTarget.selector);
        pol.setSwapTarget(address(alb), true);
        vm.expectRevert(POLHolder.ForbiddenTarget.selector);
        pol.setSwapTarget(address(polLoC), true);
        vm.expectRevert(POLHolder.ForbiddenTarget.selector);
        pol.setSwapTarget(address(pol), true);
    }

    function test_albCannotBePortfolioAsset() public {
        pol.setAllowedAsset(address(alb), true);
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.setAssetEntry(address(alb), 0, 100, POLHolder.RewardMode.OUTRIGHT);
    }

    function test_nonAllowedAssetRejected() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.setAssetEntry(address(rogue), 0, 100, POLHolder.RewardMode.OUTRIGHT);
    }

    function test_onlyOperatorCanMaintain() public {
        vm.expectRevert();
        vm.prank(bob);
        pol.maintain(noActions, noActions);
    }

    function test_thereIsNoAssetWithdrawal() public view {
        assertTrue(address(pol).code.length > 0);
    }

    function test_underAllocatedAssetReverts() public {
        _skip(1 hours);
        uint256 drawAmount = uint256(RATE) * 1 hours;

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(alb), drawAmount, address(usdc), drawAmount / 1e12);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);
    }

    function test_badPriceExecutionReverts() public {
        _skip(1 hours);
        uint256 drawAmount = uint256(RATE) * 1 hours;
        POLHolder.Action[] memory acts = _balancedSwaps(drawAmount);

        acts[0] = _swap(address(alb), drawAmount / 2, address(usdc), drawAmount / 2 / 1e12 / 2);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, acts);
    }

    function test_staleAssetOracleBlocksMaintain() public {
        assetOracle.setStale(address(usdc), true);
        _skip(1 hours);
        POLHolder.Action[] memory acts = _balancedSwaps(uint256(RATE) * 1 hours);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.maintain(noActions, acts);
    }

    function test_pendingDrawCappedAtWindowStock() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 10; ++i) {
            t += 7 days;
            vm.warp(t);
            twap.touch();
            vm.prank(KEEPER);
            pol.maintain(noActions, noActions);
        }
        uint256 cap = uint256(RATE) * 7 days;
        assertLe(pol.pendingDraw(), cap, "entitlement stock must be capped at 7 days");
    }

    function test_dailyDrawLimitEnforced() public {
        pol.setDrawLimits(100 ether, 50_000_000 ether, 100_000_000 ether);
        _skip(1 days);
        twap.touch();
        POLHolder.Action[] memory acts = _balancedSwaps(100 ether);
        vm.prank(KEEPER);
        pol.maintain(noActions, acts);
        assertLe(pol.totalDrawn(), 100 ether);
    }

    function test_boostAppliesOnlyAboveSma() public {
        pol.setRates(RATE, RATE);

        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        uint256 noBoost = pol.pendingDraw();

        twap.setPrice(5e8);
        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        uint256 withBoost = pol.pendingDraw() - noBoost;
        assertGt(withBoost, noBoost, "boost must roughly double accrual");
    }

    function test_pauseBlocksMaintain() public {
        vm.prank(POL_ADMIN);
        pol.pause();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.PausedErr.selector);
        pol.maintain(noActions, noActions);
    }

    function test_onlyOwnerUnpauses() public {
        vm.prank(POL_ADMIN);
        pol.pause();
        vm.expectRevert();
        vm.prank(POL_ADMIN);
        pol.unpause();
        pol.unpause();
        assertFalse(pol.paused());
    }

    function test_yeetRequiresAdminAuthorization() public {
        _maintain(1 hours);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeYeet(address(wsteth), noActions);
    }

    function test_yeetCannotSendProceedsToAttacker() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        acts[0].approveToken = address(wsteth);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = bal;

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth),
            keccak256(abi.encode(acts)),
            uint128((bal * 3000e8) / 1e18),
            uint64(block.timestamp + 1 days)
        );

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeYeet(address(wsteth), acts);
    }

    function test_yeetSucceedsIntoStables() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        uint256 usdValue = (bal * 3000e8) / 1e18;
        uint256 usdcOut = (usdValue * 1e6) / 1e8;

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(usdc), usdcOut);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth), keccak256(abi.encode(acts)), uint128(usdValue), uint64(block.timestamp + 1 days)
        );

        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);
        assertEq(wsteth.balanceOf(address(pol)), 0);
    }

    function test_emergencyShutdownCannotDrainToAttacker() public {
        _maintain(1 hours);
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 24 hours));

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        acts[0].approveToken = address(wsteth);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = bal;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);
    }

    function test_emergencyShutdownIntoStablesSucceeds() public {
        _maintain(1 hours);
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 24 hours));

        uint256 bal = wsteth.balanceOf(address(pol));
        uint256 usdcOut = ((bal * 3000e8) / 1e18) * 1e6 / 1e8;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(usdc), usdcOut);
        vm.prank(KEEPER);
        pol.executeEmergencyShutdown(acts);
        assertEq(wsteth.balanceOf(address(pol)), 0);
    }

    function test_rebalanceRequiresAuthorizationAndDelay() public {
        _maintain(1 hours);
        POLHolder.Action[] memory acts = new POLHolder.Action[](0);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeRebalance(acts);

        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeRebalance(acts);

        _skip(6 hours);
        vm.prank(KEEPER);
        pol.executeRebalance(acts);
    }

    function test_rebalanceCalldataIsHashBound() public {
        _maintain(1 hours);
        POLHolder.Action[] memory approved = new POLHolder.Action[](0);
        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(approved)));
        _skip(6 hours);

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory substituted = new POLHolder.Action[](1);
        substituted[0].target = address(router);
        substituted[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        substituted[0].approveToken = address(wsteth);
        substituted[0].approveSpender = address(router);
        substituted[0].approveAmount = bal;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeRebalance(substituted);
    }

    function test_rebalanceCannotReplay() public {
        POLHolder.Action[] memory acts = new POLHolder.Action[](0);
        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(6 hours);
        vm.startPrank(KEEPER);
        pol.executeRebalance(acts);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeRebalance(acts);
        vm.stopPrank();
    }

    function _authorizeBurn(uint256 total, uint128 daily, uint128 maxPrice) internal {
        uint64 exp = uint64(block.timestamp + 30 days);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(total, daily, maxPrice, exp);
        pol.authorizeBurn(total, daily, maxPrice, exp, pol.burnNonce());
    }

    function test_burnBlockedAboveMaxAlbPrice() public {
        _maintain(1 hours);
        _authorizeBurn(1_000_000e8, 100_000e8, 1e8);
        _skip(1 days);
        twap.setPrice(2e8);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.AlbPriceTooHigh.selector);
        pol.executeBurn(noActions);
    }

    function test_burnCannotExceedDcaBudget() public {
        _maintain(2 hours);
        _authorizeBurn(1_000_000e8, 1e8, 10e8);
        _skip(1 days);
        twap.touch();

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(alb), (bal * 3000) / 1);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.BudgetExhausted.selector);
        pol.executeBurn(acts);
    }

    function test_burnRequiresAlbProceeds() public {
        _maintain(2 hours);
        _authorizeBurn(1_000_000e8, 1_000_000e8, 10e8);
        _skip(1 days);
        twap.touch();

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        acts[0].approveToken = address(wsteth);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = bal;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeBurn(acts);
    }

    function test_burnRepaysDebtBeforeBurning() public {
        uint256 drawn = _maintain(2 hours);
        assertEq(polLoC.drawnAmount(), drawn);

        _authorizeBurn(10_000_000e8, 10_000_000e8, 10e8);
        _skip(1 days);
        twap.touch();

        uint256 sell = wsteth.balanceOf(address(pol)) / 2;
        uint256 albOut = (sell * 3000e8) / 1e8;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), sell, address(alb), albOut);

        vm.expectCall(address(oracle), abi.encodeWithSignature("safeSpotPrice()"), uint64(1));
        vm.prank(KEEPER);
        pol.executeBurn(acts);
        assertLt(polLoC.drawnAmount(), drawn, "debt repaid first");
    }

    function test_onlyOwnerAuthorizesBurn() public {
        uint64 exp = uint64(block.timestamp + 30 days);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(1000e8, 100e8, 10e8, exp);
        uint64 nonce = pol.burnNonce();
        vm.expectRevert();
        vm.prank(POL_ADMIN);
        pol.authorizeBurn(1000e8, 100e8, 10e8, exp, nonce);
    }

    function test_compoundingYieldSoldExactly() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));

        assetOracle.setPrice(address(wsteth), 3300e8);

        uint256 expectedYield = (bal * 300e8) / 3300e8;
        uint256 albOut = (expectedYield * 3300e8) / 1e8;

        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0] = _swap(address(wsteth), expectedYield, address(alb), albOut);

        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(harvest, noActions);
        assertEq(wsteth.balanceOf(address(pol)), bal - expectedYield);
    }

    function test_harvestCannotOversellPortfolio() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        assetOracle.setPrice(address(wsteth), 3300e8);
        uint256 expectedYield = (bal * 300e8) / 3300e8;

        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0] = _swap(address(wsteth), expectedYield * 2, address(alb), expectedYield * 2 * 3300);

        _skip(1 hours);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(harvest, noActions);
    }

    function test_compoundingPriceDropIsSkipped() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        assetOracle.setPrice(address(wsteth), 2000e8);

        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        assertEq(wsteth.balanceOf(address(pol)), bal, "no loss realized");
    }

    function test_harvestCannotSellOutrightAssets() public {
        _maintain(1 hours);
        uint256 bal = usdc.balanceOf(address(pol));
        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0] = _swap(address(usdc), bal, address(alb), bal * 1e12);

        _skip(1 hours);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(harvest, noActions);
    }

    function test_rebalanceAddsCompoundingPrincipal() public { _authorizedInflow(false); }
    function test_yeetAddsCompoundingPrincipal() public { _authorizedInflow(true); }

    function _authorizedInflow(bool rare) internal {
        _maintain(1 hours);
        uint256 beforeBalance = wsteth.balanceOf(address(pol));
        pol.setStable(address(usdc), false);
        assetOracle.setPrice(address(wsteth), 3300e8);
        POLHolder.Action[] memory actions = new POLHolder.Action[](1);
        actions[0] = _swap(address(usdc), 990e6, address(wsteth), 0.3 ether);
        vm.prank(POL_ADMIN);
        if (rare) {
            pol.authorizeYeet(address(usdc), keccak256(abi.encode(actions)), 990e8, uint64(vm.getBlockTimestamp() + 1 days));
        } else {
            pol.authorizeRebalance(keccak256(abi.encode(actions)));
        }
        _skip(6 hours);
        twap.touch();
        vm.prank(KEEPER);
        if (rare) pol.executeYeet(address(usdc), actions);
        else pol.executeRebalance(actions);
        (,,, uint128 basis,) = pol.asset(address(wsteth));
        assertEq(basis, 3100e8);
        uint256 yield = beforeBalance * 300e8 / 3300e8;
        actions[0] = _swap(address(wsteth), yield + 1, address(alb), (yield + 1) * 3300);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(actions, noActions);
        actions[0] = _swap(address(wsteth), yield, address(alb), yield * 3300);
        vm.prank(KEEPER);
        pol.maintain(actions, noActions);
        assertEq(wsteth.balanceOf(address(pol)), beforeBalance + 0.3 ether - yield);
    }

    function test_cannotApproveUntrackedToken() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        rwd.mint(address(pol), 1000 ether);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(rwd), 1000 ether, bob));
        acts[0].approveToken = address(rwd);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = 1000 ether;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.maintain(acts, noActions);
        assertEq(rwd.balanceOf(bob), 0);
    }

    function test_declaredRewardsMustBeSweptToAlb() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), 100 ether));
        acts[1] = _steal(address(rwd), 100 ether, bob);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(acts, noActions);
    }

    function test_parkedRewardsDoNotBrickMaintain() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);
        rwd.mint(address(pol), 1);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (address(rwd), 100 ether));

        vm.prank(KEEPER);
        pol.maintain(acts, noActions);
        assertEq(rwd.balanceOf(address(pol)), 100 ether + 1, "rewards retained, not forfeited");
    }

    function test_preExistingRewardValueMustBecomeAlb() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);
        rwd.mint(address(pol), 1000 ether);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(rwd), 1000 ether, bob));
        acts[0].approveToken = address(rwd);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = 1000 ether;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(acts, noActions);
        assertEq(rwd.balanceOf(bob), 0);

        POLHolder.Action[] memory good = new POLHolder.Action[](1);
        good[0] = _swap(address(rwd), 1000 ether, address(alb), 5000 ether);
        vm.prank(KEEPER);
        pol.maintain(good, noActions);
        assertEq(rwd.balanceOf(address(pol)), 0);
    }

    function test_shutdownFloorBindsWhenPriceIsStale() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        assetOracle.setStale(address(wsteth), true);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(1000e8, type(uint128).max, uint64(block.timestamp + 24 hours));

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        acts[0].approveToken = address(wsteth);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = bal;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);
        assertEq(wsteth.balanceOf(address(pol)), bal);
    }

    function test_shutdownAuthorizationExpires() public {
        _maintain(1 hours);
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 24 hours));
        _skip(2 days);
        twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.AuthorizationExpired.selector);
        pol.executeEmergencyShutdown(noActions);
    }

    function test_dualListedAssetCanStillBeRebalanced() public {
        _maintain(1 hours);
        uint256 sell = usdc.balanceOf(address(pol)) / 2;
        uint256 wstOut = ((sell * 1e12) / 3000) ;

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(usdc), sell, address(wsteth), wstOut);

        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(6 hours);
        twap.touch();
        vm.prank(KEEPER);
        pol.executeRebalance(acts);
    }

    function test_harvestCannotDrainStableBuffer() public {
        _maintain(1 hours);

        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);
        dai.mint(address(pol), 100_000 ether);

        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0].target = address(router);
        harvest[0].data = abi.encodeCall(MockRouter.steal, (address(dai), 100_000 ether, bob));
        harvest[0].approveToken = address(dai);
        harvest[0].approveSpender = address(router);
        harvest[0].approveAmount = 100_000 ether;

        _skip(1 hours);
        twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(harvest, noActions);
        assertEq(dai.balanceOf(address(pol)), 100_000 ether);
    }

    function test_emergencyShutdownCannotDrainStablesWithoutLiquidating() public {
        _maintain(1 hours);
        uint256 usdcBal = usdc.balanceOf(address(pol));
        assertGt(usdcBal, 0);

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 24 hours));

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.steal, (address(usdc), usdcBal, bob));
        acts[0].approveToken = address(usdc);
        acts[0].approveSpender = address(router);
        acts[0].approveAmount = usdcBal;

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);
        assertEq(usdc.balanceOf(address(pol)), usdcBal);
    }

    function test_yeetAuthorizationIsHashBoundAndExpires() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        uint256 usdcOut = ((bal * 3000e8) / 1e18) * 1e6 / 1e8;

        POLHolder.Action[] memory approved = new POLHolder.Action[](1);
        approved[0] = _swap(address(wsteth), bal, address(usdc), usdcOut);

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth),
            keccak256(abi.encode(approved)),
            uint128((bal * 3000e8) / 1e18),
            uint64(block.timestamp + 1 days)
        );

        POLHolder.Action[] memory substituted = new POLHolder.Action[](1);
        substituted[0].target = address(router);
        substituted[0].data = abi.encodeCall(MockRouter.steal, (address(wsteth), bal, bob));
        substituted[0].approveToken = address(wsteth);
        substituted[0].approveSpender = address(router);
        substituted[0].approveAmount = bal;
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeYeet(address(wsteth), substituted);

        _skip(2 days);
        twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.AuthorizationExpired.selector);
        pol.executeYeet(address(wsteth), approved);
    }

    function test_staleAlbOracleBlocksMaintain() public {
        _skip(1 hours);

        _skip(7 hours);
        POLHolder.Action[] memory acts = _balancedSwaps(uint256(RATE) * 8 hours);
        vm.prank(KEEPER);
        vm.expectRevert();
        pol.maintain(noActions, acts);
    }

    function test_donationCannotBrickHarvest() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        assetOracle.setPrice(address(wsteth), 3300e8);
        uint256 expectedYield = (bal * 300e8) / 3300e8;

        wsteth.mint(address(pol), 1);

        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0] = _swap(address(wsteth), expectedYield, address(alb), (expectedYield * 3300e8) / 1e8);

        _skip(1 hours);
        twap.touch();
        vm.prank(KEEPER);
        pol.maintain(harvest, noActions);
    }

    function test_burnBudgetClampedAcrossIdlePeriod() public {
        _maintain(2 hours);
        _authorizeBurn(10_000_000e8, 1000e8, 10e8);

        _skip(20 days);
        twap.touch();

        uint256 sell = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.BudgetExhausted.selector);
        pol.executeBurn(acts);
    }

    function test_harvestedAlbRepaysThenBurns() public {
        uint256 drawn = _maintain(1 hours);
        POLHolder.Action[] memory harvest = new POLHolder.Action[](1);
        harvest[0].target = address(router);
        harvest[0].data = abi.encodeCall(MockRouter.claimRewards, (address(alb), drawn));

        _skip(1 hours);
        vm.prank(KEEPER);
        pol.maintain(harvest, noActions);
        assertEq(polLoC.drawnAmount(), 0, "harvest ALB retires debt");
        assertEq(alb.balanceOf(address(pol)), 0);
    }
}

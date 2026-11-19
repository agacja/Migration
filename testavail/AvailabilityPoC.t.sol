// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../test/Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "../test/Mocks.sol";

contract AvailabilityPoC is BaseTest {
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
        pol.setSwapTarget(address(router), true);
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

    function _balancedSwaps(uint256 d) internal view returns (POLHolder.Action[] memory acts) {
        uint256 h = d / 2;
        acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), h, address(usdc), h / 1e12);
        acts[1] = _swap(address(alb), d - h, address(wsteth), h / 3000);
    }

    function _maintain(uint256 e) internal returns (uint256 d) {
        _skip(e); twap.touch();
        d = uint256(RATE) * e;
        vm.prank(KEEPER);
        pol.maintain(noActions, _balancedSwaps(d));
    }

    // ==================================================================
    // PoC 1: maxBurnWindow clamp is defeated by the proportional lastExec
    // advance. N sequential calls in ONE block each replay the full clamped
    // budget, so an idle backlog is dumped at a single, operator-chosen price.
    // ==================================================================
    function test_burnWindowClampReplayedInOneBlock() public {
        _maintain(2 hours);
        wsteth.mint(address(pol), 1000 ether); // $3,000,000 of POL

        uint64 exp = uint64(block.timestamp + 60 days);
        vm.prank(POL_ADMIN);
        pol.proposeBurn(10_000_000e8, 1000e8, 10e8, exp); // $1,000/day DCA
        pol.authorizeBurn(10_000_000e8, 1000e8, 10e8, exp, pol.burnNonce());

        // Program sits idle for 20 days (holiday / thin liquidity / paused keeper).
        _skip(20 days);
        twap.touch();

        // maxBurnWindow is 2 days => the documented per-call ceiling is $2,000.
        uint256 usdPerCall = 2000e8;
        uint256 sell = (usdPerCall * 1e18) / 3000e8; // wstETH units

        // One block, ten sequential calls: no warp between them.
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 i; i < 10; ++i) {
            POLHolder.Action[] memory acts = new POLHolder.Action[](1);
            acts[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);
            vm.prank(KEEPER);
            pol.executeBurn(acts);
        }
        assertEq(vm.getBlockTimestamp(), t0, "all in one block");

        (,,,, uint128 spent,,,) = pol.burn();
        emit log_named_uint("spent (USD 8dp)", spent);
        // ~$20,000 = ten times the documented $2,000 per-call window ceiling, one block.
        assertApproxEqAbs(uint256(spent), 20_000e8, 1e4, "20d of DCA budget dumped in one block");

        // The 11th call finally stops: the whole 20-day backlog is now consumed.
        POLHolder.Action[] memory a2 = new POLHolder.Action[](1);
        a2[0] = _swap(address(wsteth), sell, address(alb), (sell * 3000e8) / 1e8);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.BudgetExhausted.selector);
        pol.executeBurn(a2);
    }

    // ==================================================================
    // PoC 5: a reward token whose oracle dies can never be disposed of.
    // ==================================================================
    function test_rewardTokenWithDeadOracleIsStranded() public {
        MockERC20 rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);
        rwd.mint(address(pol), 10_000 ether); // $50,000 of accrued yield

        // Selling it works while the feed is live.
        POLHolder.Action[] memory h = new POLHolder.Action[](1);
        h[0] = _swap(address(rwd), 1 ether, address(alb), 5 ether);
        _skip(1 hours); twap.touch();
        vm.prank(KEEPER);
        pol.maintain(h, noActions);

        // Feed dies.
        assetOracle.setStale(address(rwd), true);

        _skip(1 hours); twap.touch();
        POLHolder.Action[] memory h2 = new POLHolder.Action[](1);
        h2[0] = _swap(address(rwd), 9_999 ether, address(alb), 49_995 ether);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.maintain(h2, noActions);

        // De-listing is allowed (no balance check) but makes it strictly worse: the
        // approve allowlist now rejects it in EVERY leg, and re-listing is impossible.
        pol.setRewardToken(address(rwd), false);
        _skip(1 hours); twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.maintain(h2, noActions);

        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.setRewardToken(address(rwd), true);

        assertEq(rwd.balanceOf(address(pol)), 9_999 ether, "$50k stranded forever");
    }

    // ==================================================================
    // PoC 6: a healthy, fully-priced pure stable can never be redeployed
    // into the portfolio — no leg permits a pure-stable balance to fall
    // except executeBurn (which only converts it to ALB and destroys it).
    // ==================================================================
    function test_pureStableCannotBeRedeployedIntoPortfolio() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8); // perfectly healthy feed
        pol.setStable(address(dai), true);
        dai.mint(address(pol), 300_000 ether); // proceeds of an earlier yeet

        _maintain(1 hours);

        // Buy wstETH with the idle stable buffer via the Admin-authorised rebalance.
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(dai), 300_000 ether, address(wsteth), 100 ether); // $300k -> $300k
        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(6 hours); twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeRebalance(acts);

        // The maintain swap leg cannot do it either: the extra wstETH blows the
        // per-asset proportion band that is scaled to the drawn ALB.
        _skip(1 hours); twap.touch();
        uint256 d = uint256(RATE) * 1 hours;
        POLHolder.Action[] memory sw = new POLHolder.Action[](3);
        sw[0] = _swap(address(alb), d / 2, address(usdc), (d / 2) / 1e12);
        sw[1] = _swap(address(alb), d - d / 2, address(wsteth), (d / 2) / 3000);
        sw[2] = _swap(address(dai), 300_000 ether, address(wsteth), 100 ether);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(noActions, sw);

        assertEq(dai.balanceOf(address(pol)), 300_000 ether, "stable buffer is trapped");
    }

    // ==================================================================
    // PoC 2: ONE stale stable oracle bricks the whole maintain draw leg,
    // and every de-listing / rotation route is closed.
    // ==================================================================
    function test_staleStableBricksDrawLegAndCannotBeDelisted() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);
        dai.mint(address(pol), 500_000 ether); // proceeds of an earlier yeet

        _maintain(1 hours); // works while the feed is live

        // The feed dies (route removed, TWAP deviation, depeg blowing the sanity band).
        assetOracle.setStale(address(dai), true);

        // (1) harvest-only maintain still works (lenient _stableOnlyValueEmergency)...
        _skip(1 hours); twap.touch();
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);

        // (2) ...but ANY maintain that draws + deploys now reverts: _runSwapLeg values
        //     stables with the STRICT _stableOnlyValue().
        _skip(1 hours); twap.touch();
        POLHolder.Action[] memory sw = _balancedSwaps(uint256(RATE) * 1 hours);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.StaleAssetOracle.selector);
        pol.maintain(noActions, sw);

        // (3) The documented remedy is blocked: the new zero-balance rule.
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.setStable(address(dai), false);

        // (4) It cannot be yeeted: authorizeYeet requires a portfolio entry.
        vm.prank(POL_ADMIN);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.authorizeYeet(address(dai), bytes32(uint256(1)), 0, uint64(block.timestamp + 1 days));

        // (5) It cannot be sold in a rebalance: _requireStableBalancesNotDrained forbids
        //     ANY pure-stable balance decrease.
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(dai), 500_000 ether, address(usdc), 500_000e6);
        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(acts)));
        _skip(6 hours); twap.touch();
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeRebalance(acts);

        // (6) It cannot be sold in an emergency shutdown either.
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);
    }

    // ==================================================================
    // PoC 3: _requireUnpricedNotDrained freezes exactly the asset the
    // emergency shutdown exists to liquidate.
    // ==================================================================
    function test_shutdownCannotLiquidateUnpricedAsset() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        assetOracle.setPrice(address(dai), 1e8);
        pol.setStable(address(dai), true);

        _maintain(2 hours);

        // wstETH's oracle goes dark — the §9.2 "oracle stress" scenario.
        assetOracle.setStale(address(wsteth), true);

        uint256 bal = wsteth.balanceOf(address(pol));
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        // Honest liquidation at the last known fair price into a pre-authorized stable.
        acts[0] = _swap(address(wsteth), bal, address(dai), (bal * 3000));

        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 hours));
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.executeEmergencyShutdown(acts);
    }

    // ==================================================================
    // PoC 4: revokeYeet can be made to revert permanently, so an unwanted
    // yeet authorization cannot be withdrawn.
    // ==================================================================
    function test_revokeYeetBricksAfterOwnerReallocates() public {
        // Admin authorizes a yeet of wstETH (5000 bps) -> its weight is zeroed.
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), bytes32(uint256(1)), 0, uint64(block.timestamp + 2 days));
        (,,, uint16 prior,) = pol.yeetAuth(address(wsteth));
        assertEq(prior, 5000);

        // Owner reallocates the freed 5000 bps to USDC (total = 10000, valid).
        pol.setAssetEntry(address(usdc), 10000, 100, POLHolder.RewardMode.OUTRIGHT);

        // Admin thinks better of the yeet — revoke now reverts and the auth is stuck live.
        vm.prank(POL_ADMIN);
        vm.expectRevert(POLHolder.PortfolioWeightsInvalid.selector);
        pol.revokeYeet(address(wsteth));

        // Owner cannot revoke it either (same code path).
        vm.expectRevert(POLHolder.PortfolioWeightsInvalid.selector);
        pol.revokeYeet(address(wsteth));

        // pause() does not help: executeYeet has no whenNotPaused.
        pol.pause();
        (bytes32 h,,,,) = pol.yeetAuth(address(wsteth));
        assertEq(h, bytes32(uint256(1)), "authorization still live while paused");
    }
}

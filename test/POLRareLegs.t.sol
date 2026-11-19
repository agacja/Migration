// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {POLHolderRareLegs} from "../src/pol/POLHolderRareLegs.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockRouter} from "./Mocks.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract POLRareLegsTest is BaseTest {
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

    function _maintain(uint256 elapsed) internal {
        _skip(elapsed);
        twap.touch();
        uint256 drawAmount = uint256(RATE) * elapsed;
        uint256 halfAlb = drawAmount / 2;
        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _swap(address(alb), halfAlb, address(usdc), halfAlb / 1e12);
        acts[1] = _swap(address(alb), drawAmount - halfAlb, address(wsteth), halfAlb / 3000);
        vm.prank(KEEPER);
        pol.maintain(noActions, acts);
    }

    function _legs() internal view returns (POLHolderRareLegs legs) {
        legs = POLHolderRareLegs(vm.computeCreateAddress(address(pol), 1));
        assertGt(address(legs).code.length, 0, "companion deployed");
    }

    function test_companionRefusesDirectCalls() public {
        POLHolderRareLegs legs = _legs();
        POLHolderRareLegs.Action[] memory acts;
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.executeYeet(address(wsteth), acts);
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.executeEmergencyShutdown(acts);
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.setStable(address(usdc), false);
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.armEmergencyShutdown(1, 1, uint64(block.timestamp + 1 days));

        assertEq(vm.load(address(legs), bytes32(uint256(6))), bytes32(0), "portfolio length 0");
        assertEq(pol.rareLegs(), address(legs), "POLHolder exposes its companion");
    }

    function test_companionSharesImmutables() public view {
        POLHolderRareLegs legs = _legs();
        assertEq(address(legs.alb()), address(pol.alb()));
        assertEq(address(legs.albOracle()), address(pol.albOracle()));
        assertEq(address(legs.assetOracle()), address(pol.assetOracle()));
    }

    function test_delegatedSettersWriteToPOLHolderStorage() public {
        POLHolderRareLegs legs = _legs();
        assertEq(pol.portfolio(0), address(usdc));
        assertTrue(pol.isStable(address(usdc)));
        (uint16 targetBps,,,, bool exists) = pol.asset(address(usdc));
        assertEq(targetBps, 5000);
        assertTrue(exists);

        bytes32 slot = keccak256(abi.encode(address(usdc), uint256(7)));
        assertEq(vm.load(address(legs), slot), bytes32(0), "companion storage untouched");

        pol.setAssetEntry(address(usdc), 4000, 100, POLHolder.RewardMode.OUTRIGHT);
        (targetBps,,,,) = pol.asset(address(usdc));
        assertEq(targetBps, 4000);

        pol.setAssetEntry(address(usdc), 0, 100, POLHolder.RewardMode.OUTRIGHT);
        pol.removeAsset(address(usdc));
        (,,,, exists) = pol.asset(address(usdc));
        assertFalse(exists);
    }

    function test_delegatedEventsEmitFromPOLHolder() public {
        vm.expectEmit(true, true, true, true, address(pol));
        emit POLHolder.StableSet(address(wsteth), true);
        pol.setStable(address(wsteth), true);

        vm.expectEmit(true, true, true, true, address(pol));
        emit POLHolder.EmergencyShutdownArmed();
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, 1 ether, uint64(block.timestamp + 1 days));

        vm.expectEmit(true, true, true, true, address(pol));
        emit POLHolder.EmergencyShutdownDisarmed();
        vm.prank(POL_ADMIN);
        pol.disarmEmergencyShutdown();

        vm.expectEmit(true, true, true, true, address(pol));
        emit POLHolder.YeetAuthorized(address(wsteth));
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), bytes32(0), 1, uint64(block.timestamp + 1 days));

        vm.expectEmit(true, true, true, true, address(pol));
        emit POLHolder.YeetRevoked(address(wsteth));
        vm.prank(POL_ADMIN);
        pol.revokeYeet(address(wsteth));
    }

    function test_yeetExecutedEventEmitsFromPOLHolder() public {
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

        vm.expectEmit(true, false, false, false, address(pol));
        emit POLHolder.YeetExecuted(address(wsteth), 0, 0);
        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);
    }

    function test_authCheckPrecedesDelegation() public {
        POLHolder.Action[] memory acts;

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pol.executeYeet(address(wsteth), acts);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pol.executeEmergencyShutdown(acts);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pol.setAssetEntry(address(usdc), 1, 1, POLHolder.RewardMode.OUTRIGHT);
        vm.prank(alice);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.revokeYeet(address(wsteth));
    }

    function test_delegatedRevertsBubbleExactSelectors() public {
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.setAssetEntry(address(usdc), 10_001, 100, POLHolder.RewardMode.OUTRIGHT);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.setAssetEntry(address(legacyALB), 100, 100, POLHolder.RewardMode.OUTRIGHT);
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.setRewardToken(address(alb), true);
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.setStable(address(0), true);
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.removeAsset(address(usdc));

        vm.prank(POL_ADMIN);
        vm.expectRevert(POLHolder.InvalidParams.selector);
        pol.armEmergencyShutdown(0, 0, uint64(block.timestamp + 1 days));
        vm.prank(POL_ADMIN);
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.authorizeYeet(address(legacyALB), bytes32(0), 1, uint64(block.timestamp + 1 days));

        POLHolder.Action[] memory acts;
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), keccak256(abi.encode(acts)), 1, uint64(block.timestamp + 1 days));
        _skip(2 days);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.AuthorizationExpired.selector);
        pol.executeYeet(address(wsteth), acts);
    }

    function test_reentrancyLockReleasedAfterDelegatedLeg() public {
        _maintain(1 hours);
        uint256 bal = wsteth.balanceOf(address(pol));
        uint256 usdValue = (bal * 3000e8) / 1e18;
        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        acts[0] = _swap(address(wsteth), bal, address(usdc), (usdValue * 1e6) / 1e8);
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(
            address(wsteth), keccak256(abi.encode(acts)), uint128(usdValue), uint64(block.timestamp + 1 days)
        );
        vm.prank(KEEPER);
        pol.executeYeet(address(wsteth), acts);

        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(KEEPER);
        pol.executeEmergencyShutdown(noActions);
        vm.prank(KEEPER);
        pol.maintain(noActions, noActions);
    }
}

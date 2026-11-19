// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "../ActionPermissionSetup.sol";

import {BaseTest} from "../Base.t.sol";
import {POLHolder} from "../../src/pol/POLHolder.sol";
import {LoC} from "../../src/loc/LoC.sol";
import {ILoC} from "../../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "../Mocks.sol";

contract RevokeYeetRefute is BaseTest {
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

    function _arm() internal returns (bytes32 h, uint64 exp) {
        h = keccak256("liquidate-wsteth");
        exp = uint64(block.timestamp + 2 days);
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), h, 1, exp);

        pol.setAssetEntry(address(usdc), 10_000, 100, POLHolder.RewardMode.OUTRIGHT);
    }

    function test_A_revokeYeetRevertsAfterReallocation() public {
        _arm();
        vm.prank(POL_ADMIN);
        vm.expectRevert(POLHolder.PortfolioWeightsInvalid.selector);
        pol.revokeYeet(address(wsteth));

        vm.expectRevert(POLHolder.PortfolioWeightsInvalid.selector);
        pol.revokeYeet(address(wsteth));
    }

    function test_B_adminNeutralizesInOneCallByReArming() public {
        (bytes32 h,) = _arm();

        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), bytes32(0), type(uint128).max, uint64(block.timestamp + 1));

        (bytes32 nh,,,,) = pol.yeetAuth(address(wsteth));
        assertTrue(nh != h, "old hash overwritten");

        POLHolder.Action[] memory acts = new POLHolder.Action[](0);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NotAuthorized.selector);
        pol.executeYeet(address(wsteth), acts);

        _skip(2);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.AuthorizationExpired.selector);
        pol.executeYeet(address(wsteth), acts);
    }

    function test_C_ownerRevokesOperatorRole() public {
        _arm();
        pol.revokeRoles(KEEPER, pol.ROLE_OPERATOR());
        POLHolder.Action[] memory acts = new POLHolder.Action[](0);
        vm.prank(KEEPER);
        vm.expectRevert();
        pol.executeYeet(address(wsteth), acts);
    }

    function test_D_ownerCannotRestoreWeightByAnyRouteWhileSumIsFull() public {
        _arm();
        vm.expectRevert(POLHolder.PortfolioWeightsInvalid.selector);
        pol.setAssetEntry(address(wsteth), 5000, 100, POLHolder.RewardMode.COMPOUNDING);
    }

    function test_E_revokeWorksWithoutReallocation() public {
        bytes32 h = keccak256("liquidate-wsteth");
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(wsteth), h, 1, uint64(block.timestamp + 2 days));
        (,,, uint16 prior,) = pol.yeetAuth(address(wsteth));
        assertEq(prior, 5000);
        vm.prank(POL_ADMIN);
        pol.revokeYeet(address(wsteth));
        (uint16 tbps,,,,) = pol.asset(address(wsteth));
        assertEq(tbps, 5000, "weight restored");
        (bytes32 nh,,,,) = pol.yeetAuth(address(wsteth));
        assertEq(nh, bytes32(0), "auth deleted");
    }
}

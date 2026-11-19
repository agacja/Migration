// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {POLHolderRareLegs} from "../src/pol/POLHolderRareLegs.sol";
import {FeeConverter} from "../src/fees/FeeConverter.sol";
import {ActionPermissions} from "../src/utils/ActionPermissions.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";

contract ApprovalAliasToken is MockERC20 {
    constructor() MockERC20("Alias", "ALIAS", 18) {}

    function setPermission(address spender, uint256 amount) external {
        _approve(msg.sender, spender, amount);
    }

    function multicall(bytes[] calldata calls) external {
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(this).delegatecall(calls[i]);
            require(ok);
        }
    }

    function ping() external pure returns (bool) {
        return true;
    }

    fallback() external {
        _approve(msg.sender, address(0xBAD), type(uint256).max);
    }
}

contract ZeroSelectorTarget {
    uint256 public calls;

    fallback() external {
        require(msg.sig == bytes4(0) && msg.data.length == 4);
        ++calls;
    }
}

contract ActionPermissionsTest is BaseTest {
    ApprovalAliasToken internal token;
    FeeConverter internal converter;
    MockERC20 internal feeWeth;
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public override {
        super.setUp();
        token = new ApprovalAliasToken();
        feeWeth = new MockERC20("Wrapped Ether", "WETH", 18);
        assetOracle.setPrice(address(feeWeth), 1e8);
        assetOracle.setPrice(address(token), 1e8);
        assetOracle.setPrice(address(weth), 1e8);
        assetOracle.setPrice(address(alb), 1e8);
        pol.setLoC(ILoC(address(_createLoC(address(pol), 1_000_000 ether, 0, 0, 0))));
        pol.setAllowedAsset(address(token), true);
        pol.setAssetEntry(address(token), 10_000, 100, POLHolder.RewardMode.OUTRIGHT);
        pol.setSwapTarget(address(token), true);
        token.mint(address(pol), 100 ether);
        converter = new FeeConverter(
            address(this),
            IALB(address(alb)),
            address(feeWeth),
            IStakingContract(address(staking)),
            IAssetOracle(address(assetOracle))
        );
        converter.grantRoles(KEEPER, converter.ROLE_OPERATOR());
        converter.setSwapTarget(address(token), true);
        token.mint(address(converter), 100 ether);
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        ActionPermissionSetup.allowRouter(address(converter), address(router));
        vm.prank(DAO);
        alb.addMinter(address(router));
        _warmOracle();
    }

    function _inputs() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(token);
    }

    function _polActions(bytes memory data) internal view returns (POLHolder.Action[] memory a) {
        a = new POLHolder.Action[](1);
        a[0].target = address(token);
        a[0].data = data;
    }

    function _feeActions(bytes memory data) internal view returns (FeeConverter.Action[] memory a) {
        a = new FeeConverter.Action[](1);
        a[0].target = address(token);
        a[0].data = data;
    }

    function _blocked(bytes memory data, bytes4 reason) internal {
        vm.prank(KEEPER);
        vm.expectRevert(reason);
        pol.maintain(_polActions(data), new POLHolder.Action[](0));
        vm.prank(KEEPER);
        vm.expectRevert(reason);
        converter.convertToWeth(_inputs(), _feeActions(data));
        assertEq(token.allowance(address(pol), ATTACKER), 0);
        assertEq(token.allowance(address(converter), ATTACKER), 0);
        assertEq(token.balanceOf(address(pol)), 100 ether);
        assertEq(token.balanceOf(address(converter)), 100 ether);
    }

    function _alias() internal view returns (bytes memory) {
        return abi.encodeCall(token.setPermission, (ATTACKER, type(uint256).max));
    }

    function _allowPing(bool allowed) internal {
        pol.setActionPermission(address(token), token.ping.selector, address(0), allowed);
        converter.setActionPermission(address(token), token.ping.selector, address(0), allowed);
    }

    function _ping() internal {
        bytes memory data = abi.encodeCall(token.ping, ());
        vm.prank(KEEPER);
        pol.maintain(_polActions(data), new POLHolder.Action[](0));
        vm.prank(KEEPER);
        converter.convertToWeth(_inputs(), _feeActions(data));
    }

    function test_approvalAliasBlockedOnWhitelistedToken() public {
        _blocked(_alias(), ActionPermissions.ActionNotAllowed.selector);
    }

    function test_nestedApprovalBlockedOnWhitelistedToken() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(token.approve, (ATTACKER, type(uint256).max));
        _blocked(abi.encodeCall(token.multicall, (calls)), ActionPermissions.ActionNotAllowed.selector);
    }

    function test_shortCalldataBlocked() public {
        _blocked(hex"", ActionPermissions.InvalidActionData.selector);
        _blocked(hex"01", ActionPermissions.InvalidActionData.selector);
        _blocked(hex"0102", ActionPermissions.InvalidActionData.selector);
        _blocked(hex"010203", ActionPermissions.InvalidActionData.selector);
    }

    function testFuzz_unapprovedSelectorBlocked(bytes4 selector) public {
        _blocked(
            abi.encodePacked(selector, abi.encode(ATTACKER, type(uint256).max)),
            ActionPermissions.ActionNotAllowed.selector
        );
    }

    function test_permissionDoesNotEnableOtherMethodsOrTargets() public {
        _allowPing(true);
        _ping();
        _blocked(_alias(), ActionPermissions.ActionNotAllowed.selector);
        _blocked(
            abi.encodeCall(MockRouter.swap, (address(token), 0, address(weth), 0)),
            ActionPermissions.ActionNotAllowed.selector
        );
    }

    function test_ownerCanRevokeOneMethod() public {
        _allowPing(true);
        _ping();
        _allowPing(false);
        _blocked(abi.encodeCall(token.ping, ()), ActionPermissions.ActionNotAllowed.selector);
    }

    function test_targetReenableDoesNotRestoreOldPermissions() public {
        _allowPing(true);
        _ping();
        pol.setSwapTarget(address(token), false);
        converter.setSwapTarget(address(token), false);
        _blocked(abi.encodeCall(token.ping, ()), POLHolder.NotWhitelisted.selector);
        pol.setSwapTarget(address(token), true);
        converter.setSwapTarget(address(token), true);
        _blocked(abi.encodeCall(token.ping, ()), ActionPermissions.ActionNotAllowed.selector);
        _allowPing(true);
        _ping();
    }

    function test_duplicateTargetEnablePreservesPermissions() public {
        _allowPing(true);
        pol.setSwapTarget(address(token), true);
        converter.setSwapTarget(address(token), true);
        _ping();
    }

    function test_onlyOwnerCanSetPermissions() public {
        vm.prank(KEEPER);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        pol.setActionPermission(address(token), token.setPermission.selector, address(0), true);
        vm.prank(KEEPER);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        converter.setActionPermission(address(token), token.setPermission.selector, address(0), true);
        POLHolderRareLegs legs = POLHolderRareLegs(pol.rareLegs());
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.setActionPermission(address(token), token.setPermission.selector, address(0), true);
        vm.expectRevert(POLHolderRareLegs.NotAuthorized.selector);
        legs.setSwapTarget(address(token), true);
    }

    function test_codelessTargetsRejected() public {
        vm.expectRevert(ActionPermissions.InvalidActionTarget.selector);
        pol.setSwapTarget(ATTACKER, true);
        vm.expectRevert(ActionPermissions.InvalidActionTarget.selector);
        converter.setSwapTarget(ATTACKER, true);
    }

    function test_permissionRequiresWhitelistedTargetAndSpender() public {
        vm.expectRevert(POLHolder.NotWhitelisted.selector);
        pol.setActionPermission(ATTACKER, token.ping.selector, address(0), true);
        vm.expectRevert(FeeConverter.NotWhitelisted.selector);
        converter.setActionPermission(address(token), token.ping.selector, ATTACKER, true);
    }

    function test_explicitZeroSelectorWorksButShortCalldataStillFails() public {
        ZeroSelectorTarget target = new ZeroSelectorTarget();
        pol.setSwapTarget(address(target), true);
        converter.setSwapTarget(address(target), true);
        pol.setActionPermission(address(target), bytes4(0), address(0), true);
        converter.setActionPermission(address(target), bytes4(0), address(0), true);
        POLHolder.Action[] memory p = _polActions(hex"00000000");
        p[0].target = address(target);
        FeeConverter.Action[] memory f = _feeActions(hex"00000000");
        f[0].target = address(target);
        vm.prank(KEEPER);
        pol.maintain(p, new POLHolder.Action[](0));
        vm.prank(KEEPER);
        converter.convertToWeth(_inputs(), f);
        assertEq(target.calls(), 2);
        p[0].data = hex"00";
        f[0].data = hex"00";
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidActionData.selector);
        pol.maintain(p, new POLHolder.Action[](0));
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidActionData.selector);
        converter.convertToWeth(_inputs(), f);
        assertEq(target.calls(), 2);
    }

    function test_targetBytecodeChangeRejected() public {
        FeeConverter.Action[] memory a = _feeSwap(10 ether);
        vm.etch(address(router), hex"00");
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionCodeChanged.selector);
        converter.convertToWeth(_inputs(), a);
        assertEq(token.allowance(address(converter), address(router)), 0);
    }

    function _feeSwap(uint256 amount) internal view returns (FeeConverter.Action[] memory a) {
        a = new FeeConverter.Action[](1);
        a[0] = FeeConverter.Action(
            address(router),
            abi.encodeCall(MockRouter.swap, (address(token), amount, address(feeWeth), amount)),
            address(token),
            address(router),
            amount
        );
    }

    function test_repeatedAutomationWithChangingAmountsNeedsNoOwnerCall() public {
        for (uint256 i = 1; i <= 2; ++i) {
            vm.prank(KEEPER);
            converter.convertToWeth(_inputs(), _feeSwap(i * 10 ether));
            assertEq(token.allowance(address(converter), address(router)), 0);
            POLHolder.Action[] memory a = new POLHolder.Action[](1);
            a[0].target = address(router);
            a[0].data = abi.encodeCall(MockRouter.claimRewards, (address(alb), i * 1 ether));
            vm.prank(KEEPER);
            pol.maintain(a, new POLHolder.Action[](0));
        }
        assertEq(token.balanceOf(address(converter)), 70 ether);
        assertEq(feeWeth.balanceOf(address(converter)), 30 ether);
    }

    function test_unapprovedActionRevertsEntireBatch() public {
        FeeConverter.Action[] memory f = new FeeConverter.Action[](2);
        f[0] = _feeSwap(10 ether)[0];
        f[1] = _feeActions(_alias())[0];
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        converter.convertToWeth(_inputs(), f);
        assertEq(token.balanceOf(address(converter)), 100 ether);
        assertEq(feeWeth.balanceOf(address(converter)), 0);
        assertEq(token.allowance(address(converter), address(router)), 0);

        uint256 supply = alb.totalSupply();
        POLHolder.Action[] memory p = new POLHolder.Action[](2);
        p[0].target = address(router);
        p[0].data = abi.encodeCall(MockRouter.claimRewards, (address(alb), 10 ether));
        p[1] = _polActions(_alias())[0];
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        pol.maintain(p, new POLHolder.Action[](0));
        assertEq(alb.totalSupply(), supply);
        assertEq(token.allowance(address(pol), ATTACKER), 0);
    }

    function test_permissionsCannotLeakBetweenHolders() public {
        converter.setActionPermission(address(token), token.ping.selector, address(0), true);
        bytes memory data = abi.encodeCall(token.ping, ());
        vm.prank(KEEPER);
        converter.convertToWeth(_inputs(), _feeActions(data));
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        pol.maintain(_polActions(data), new POLHolder.Action[](0));
    }

    function test_spenderMustMatchGrantedMethod() public {
        MockRouter other = new MockRouter();
        converter.setSwapTarget(address(other), true);
        FeeConverter.Action[] memory a = _feeSwap(10 ether);
        a[0].approveSpender = address(other);
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidApproval.selector);
        converter.convertToWeth(_inputs(), a);
        assertEq(token.allowance(address(converter), address(other)), 0);
    }

    function test_spenderRevocationCannotBeUndoneByReenable() public {
        MockRouter spender = new MockRouter();
        converter.setSwapTarget(address(spender), true);
        converter.setActionPermission(address(router), MockRouter.swap.selector, address(spender), true);
        converter.setSwapTarget(address(spender), false);
        converter.setSwapTarget(address(spender), true);
        FeeConverter.Action[] memory a = _feeSwap(10 ether);
        a[0].approveSpender = address(spender);
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidApproval.selector);
        converter.convertToWeth(_inputs(), a);
    }

    function test_spenderBytecodeChangeRejectedBeforeApproval() public {
        MockRouter spender = new MockRouter();
        converter.setSwapTarget(address(spender), true);
        converter.setActionPermission(address(router), MockRouter.swap.selector, address(spender), true);
        vm.etch(address(spender), hex"00");
        FeeConverter.Action[] memory a = _feeSwap(10 ether);
        a[0].approveSpender = address(spender);
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionCodeChanged.selector);
        converter.convertToWeth(_inputs(), a);
        assertEq(token.allowance(address(converter), address(spender)), 0);
    }

    function test_undeclaredApprovalFieldsRejected() public {
        _allowPing(true);
        FeeConverter.Action[] memory a = _feeActions(abi.encodeCall(token.ping, ()));
        a[0].approveSpender = address(router);
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidApproval.selector);
        converter.convertToWeth(_inputs(), a);
        a[0].approveSpender = address(0);
        a[0].approveAmount = 1;
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidApproval.selector);
        converter.convertToWeth(_inputs(), a);
    }

    function test_noApprovalPermissionCannotGrantAllowance() public {
        _allowPing(true);
        FeeConverter.Action[] memory a = _feeActions(abi.encodeCall(token.ping, ()));
        a[0].approveToken = address(token);
        a[0].approveSpender = address(router);
        a[0].approveAmount = 1;
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.InvalidApproval.selector);
        converter.convertToWeth(_inputs(), a);
    }

    function test_delegatedYeetRejectsApprovalAlias() public {
        POLHolder.Action[] memory a = _polActions(_alias());
        vm.prank(POL_ADMIN);
        pol.authorizeYeet(address(token), keccak256(abi.encode(a)), 1, uint64(block.timestamp + 1 days));
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        pol.executeYeet(address(token), a);
        assertEq(token.allowance(address(pol), ATTACKER), 0);
    }

    function test_delegatedShutdownRejectsApprovalAlias() public {
        vm.prank(POL_ADMIN);
        pol.armEmergencyShutdown(0, type(uint128).max, uint64(block.timestamp + 1 days));
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        pol.executeEmergencyShutdown(_polActions(_alias()));
        assertEq(token.allowance(address(pol), ATTACKER), 0);
    }

    function test_rebalanceRejectsApprovalAlias() public {
        POLHolder.Action[] memory a = _polActions(_alias());
        vm.prank(POL_ADMIN);
        pol.authorizeRebalance(keccak256(abi.encode(a)));
        _skip(6 hours);
        vm.prank(KEEPER);
        vm.expectRevert(ActionPermissions.ActionNotAllowed.selector);
        pol.executeRebalance(a);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {Test} from "forge-std/Test.sol";
import {FeeConverter} from "../src/fees/FeeConverter.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";
import {MockERC20, MockAssetOracle, MockRouter} from "./Mocks.sol";

contract FeeConverterTest is Test {
    ALBToken internal alb;
    MockERC20 internal weth;
    MockERC20 internal feeTok;
    MockAssetOracle internal oracle;
    StakingContract internal staking;
    MockRouter internal router;
    FeeConverter internal conv;

    address internal constant KEEPER = address(0xCAFE);
    address internal constant ATTACKER = address(0xBAD);

    uint256 internal constant WETH_PX = 2000e8;
    uint256 internal constant FEE_PX = 1e8;
    uint256 internal constant ALB_PX = 1e7;

    function setUp() public {
        alb = new ALBToken(address(this), address(this));
        alb.addMinter(address(this));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        feeTok = new MockERC20("Fee Token", "FEE", 18);
        oracle = new MockAssetOracle(8);
        router = new MockRouter();

        alb.addMinter(address(router));

        staking = new StakingContract(
            address(this), IALB(address(alb)), address(0xE5), address(0x60), address(weth)
        );

        conv = new FeeConverter(
            address(this),
            IALB(address(alb)),
            address(weth),
            IStakingContract(address(staking)),
            IAssetOracle(address(oracle))
        );
        conv.grantRoles(KEEPER, conv.ROLE_OPERATOR());
        ActionPermissionSetup.allowRouter(address(conv), address(router));
        staking.setNotifier(address(conv), true);

        oracle.setPrice(address(weth), WETH_PX);
        oracle.setPrice(address(feeTok), FEE_PX);
        oracle.setPrice(address(alb), ALB_PX);
    }

    function _swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (FeeConverter.Action memory)
    {
        return FeeConverter.Action({
            target: address(router),
            data: abi.encodeWithSelector(MockRouter.swap.selector, tokenIn, amountIn, tokenOut, amountOut),
            approveToken: tokenIn,
            approveSpender: address(router),
            approveAmount: amountIn
        });
    }

    function _one(FeeConverter.Action memory a) internal pure returns (FeeConverter.Action[] memory arr) {
        arr = new FeeConverter.Action[](1);
        arr[0] = a;
    }

    function _tokens(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }

    function test_convertToWethHappyPath() public {
        feeTok.mint(address(conv), 1000e18);

        vm.prank(KEEPER);
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 1000e18, address(weth), 0.5e18)));

        assertEq(weth.balanceOf(address(conv)), 0.5e18);
        assertEq(feeTok.balanceOf(address(conv)), 0);

        assertEq(feeTok.allowance(address(conv), address(router)), 0);
    }

    function test_convertToleranceEnforced() public {
        feeTok.mint(address(conv), 1000e18);

        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.ToleranceBreach.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 1000e18, address(weth), 0.49e18)));

        vm.prank(KEEPER);
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 1000e18, address(weth), 0.495e18)));
        assertEq(weth.balanceOf(address(conv)), 0.495e18);
    }

    function test_convertRejectsAlbAndWethAsInputs() public {
        vm.startPrank(KEEPER);
        vm.expectRevert(FeeConverter.ForbiddenToken.selector);
        conv.convertToWeth(_tokens(address(alb)), _one(_swap(address(feeTok), 1, address(weth), 1)));
        vm.expectRevert(FeeConverter.ForbiddenToken.selector);
        conv.convertToWeth(_tokens(address(weth)), _one(_swap(address(feeTok), 1, address(weth), 1)));
        vm.stopPrank();
    }

    function test_convertApprovalRestrictedToDeclaredTokens() public {
        alb.mint(address(conv), 100e18);
        feeTok.mint(address(conv), 100e18);

        FeeConverter.Action memory a = _swap(address(alb), 100e18, address(weth), 1e18);
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NotWhitelisted.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(a));
    }

    function test_convertStealIsCaughtByValueInvariant() public {
        feeTok.mint(address(conv), 1000e18);
        FeeConverter.Action memory a = FeeConverter.Action({
            target: address(router),
            data: abi.encodeWithSelector(MockRouter.steal.selector, address(feeTok), 1000e18, ATTACKER),
            approveToken: address(feeTok),
            approveSpender: address(router),
            approveAmount: 1000e18
        });
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.ToleranceBreach.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(a));
    }

    function test_convertStaleOracleBlocks() public {
        feeTok.mint(address(conv), 1000e18);
        oracle.setStale(address(feeTok), true);
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.StaleAssetOracle.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 1000e18, address(weth), 0.5e18)));
    }

    function test_distributeSplitsBurnAndStreams() public {
        conv.setBurnBps(2000);
        alb.mint(address(conv), 100e18);
        weth.mint(address(conv), 1e18);
        uint256 supplyBefore = alb.totalSupply();

        vm.prank(KEEPER);
        conv.distribute();

        assertEq(alb.totalSupply(), supplyBefore - 20e18);
        assertEq(staking.trackedBalance(address(alb)), 80e18);

        assertEq(conv.wethBurnBudget(), 0.2e18);
        assertEq(staking.trackedBalance(address(weth)), 0.8e18);
        assertEq(weth.balanceOf(address(conv)), 0.2e18);
        assertEq(alb.balanceOf(address(conv)), 0);
    }

    function test_distributeZeroBurnStreamsEverything() public {
        alb.mint(address(conv), 100e18);
        weth.mint(address(conv), 1e18);
        vm.prank(KEEPER);
        conv.distribute();
        assertEq(staking.trackedBalance(address(alb)), 100e18);
        assertEq(staking.trackedBalance(address(weth)), 1e18);
        assertEq(conv.wethBurnBudget(), 0);
    }

    function test_distributeEmptyReverts() public {
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NothingToDo.selector);
        conv.distribute();
    }

    function test_distributeDoesNotRestreamEarmarkedWeth() public {
        conv.setBurnBps(2000);
        weth.mint(address(conv), 1e18);
        vm.prank(KEEPER);
        conv.distribute();
        assertEq(conv.wethBurnBudget(), 0.2e18);

        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NothingToDo.selector);
        conv.distribute();
        assertEq(conv.wethBurnBudget(), 0.2e18);
    }

    function _armBudget() internal returns (uint256 budget) {
        conv.setBurnBps(2000);
        weth.mint(address(conv), 1e18);
        vm.prank(KEEPER);
        conv.distribute();
        budget = conv.wethBurnBudget();
    }

    function test_buybackAndBurnHappyPath() public {
        uint256 budget = _armBudget();
        uint256 supplyBefore = alb.totalSupply();

        vm.prank(KEEPER);
        conv.buybackAndBurn(_one(_swap(address(weth), budget, address(alb), 4000e18)));

        assertEq(conv.wethBurnBudget(), 0);
        assertEq(alb.balanceOf(address(conv)), 0);

        assertEq(alb.totalSupply(), supplyBefore);
        assertEq(weth.balanceOf(address(conv)), 0);
    }

    function test_buybackBudgetEnforced() public {
        _armBudget();

        weth.mint(address(conv), 0.3e18);
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.BudgetExceeded.selector);
        conv.buybackAndBurn(_one(_swap(address(weth), 0.5e18, address(alb), 10000e18)));
    }

    function test_buybackToleranceEnforced() public {
        uint256 budget = _armBudget();

        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.ToleranceBreach.selector);
        conv.buybackAndBurn(_one(_swap(address(weth), budget, address(alb), 3800e18)));
    }

    function test_buybackOnlyApprovesWeth() public {
        _armBudget();
        feeTok.mint(address(conv), 100e18);
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NotWhitelisted.selector);
        conv.buybackAndBurn(_one(_swap(address(feeTok), 100e18, address(alb), 1000e18)));
    }

    function test_buybackWithNoBudgetReverts() public {
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NothingToDo.selector);
        conv.buybackAndBurn(_one(_swap(address(weth), 1, address(alb), 1)));
    }

    function test_unapprovedActionBlocked() public {
        feeTok.mint(address(conv), 100e18);
        FeeConverter.Action memory a = FeeConverter.Action({
            target: address(router),
            data: abi.encodeWithSelector(bytes4(0xa9059cbb), ATTACKER, 100e18),
            approveToken: address(feeTok),
            approveSpender: address(router),
            approveAmount: 100e18
        });
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.ActionNotAllowed.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(a));
    }

    function test_unwhitelistedTargetBlocked() public {
        feeTok.mint(address(conv), 100e18);
        FeeConverter.Action memory a = _swap(address(feeTok), 100e18, address(weth), 0.05e18);
        a.target = ATTACKER;
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.NotWhitelisted.selector);
        conv.convertToWeth(_tokens(address(feeTok)), _one(a));
    }

    function test_coreContractsCannotBeSwapTargets() public {
        vm.expectRevert(FeeConverter.ForbiddenTarget.selector);
        conv.setSwapTarget(address(alb), true);
        vm.expectRevert(FeeConverter.ForbiddenTarget.selector);
        conv.setSwapTarget(address(weth), true);
        vm.expectRevert(FeeConverter.ForbiddenTarget.selector);
        conv.setSwapTarget(address(staking), true);
    }

    function test_operatorGating() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        conv.distribute();
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 1, address(weth), 1)));
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        conv.buybackAndBurn(_one(_swap(address(weth), 1, address(alb), 1)));
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        conv.setBurnBps(100);
        vm.stopPrank();
    }

    function test_recoverGuardsAlbAndWeth() public {
        feeTok.mint(address(conv), 100e18);
        vm.expectRevert(FeeConverter.ForbiddenToken.selector);
        conv.recoverERC20(address(alb), address(this), 1);
        vm.expectRevert(FeeConverter.ForbiddenToken.selector);
        conv.recoverERC20(address(weth), address(this), 1);

        conv.recoverERC20(address(feeTok), address(this), 100e18);
        assertEq(feeTok.balanceOf(address(this)), 100e18);
    }

    function test_configBounds() public {
        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setToleranceBps(1001);
        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setBurnBps(10_001);
        conv.setToleranceBps(1000);
        conv.setBurnBps(10_000);
    }

    function test_endToEndWeeklyCycle() public {
        conv.setBurnBps(1000);

        feeTok.mint(address(conv), 2000e18);
        alb.mint(address(conv), 50e18);
        uint256 supplyBefore = alb.totalSupply();

        vm.startPrank(KEEPER);
        conv.convertToWeth(_tokens(address(feeTok)), _one(_swap(address(feeTok), 2000e18, address(weth), 1e18)));
        conv.distribute();

        conv.buybackAndBurn(_one(_swap(address(weth), 0.1e18, address(alb), 2000e18)));
        vm.stopPrank();

        assertEq(staking.trackedBalance(address(alb)), 45e18);
        assertEq(alb.totalSupply(), supplyBefore - 5e18);

        assertEq(staking.trackedBalance(address(weth)), 0.9e18);
        assertEq(conv.wethBurnBudget(), 0);
        assertEq(weth.balanceOf(address(conv)), 0);
    }
}

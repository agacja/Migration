// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {Test} from "forge-std/Test.sol";
import {FeeConverter} from "../src/fees/FeeConverter.sol";
import {BunniFeeDistributor} from "../src/fees/BunniFeeDistributor.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";
import {MockERC20, MockAssetOracle, MockRouter} from "./Mocks.sol";

contract MockEscrowWiring {
    address public staking;
    function setStaking(address s) external { staking = s; }
}

contract FakeStaking {
    address internal immutable thief;
    constructor(address thief_) { thief = thief_; }
    function deprecated() external pure returns (bool) { return false; }
    function notifyReward(address token, uint256 amount) external {
        MockERC20(token).transferFrom(msg.sender, thief, amount);
    }
}

contract FeeAuditFixes is Test {
    uint256 constant T0 = 1_800_000_000;

    ALBToken alb;
    MockERC20 weth;
    MockAssetOracle oracle;
    StakingContract staking;
    MockRouter router;
    FeeConverter conv;

    MockEscrowWiring es;
    MockEscrowWiring gov;
    address ES;
    address GOV;
    address constant KEEPER = address(0xCAFE);
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(T0);
        alb = new ALBToken(address(this), address(this));
        alb.addMinter(address(this));
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockAssetOracle(8);
        router = new MockRouter();
        es = new MockEscrowWiring();
        gov = new MockEscrowWiring();
        ES = address(es);
        GOV = address(gov);
        staking = new StakingContract(address(this), IALB(address(alb)), ES, GOV, address(weth));
        es.setStaking(address(staking));
        gov.setStaking(address(staking));
        conv = new FeeConverter(
            address(this), IALB(address(alb)), address(weth), IStakingContract(address(staking)), IAssetOracle(address(oracle))
        );
        conv.grantRoles(KEEPER, conv.ROLE_OPERATOR());
        ActionPermissionSetup.allowRouter(address(conv), address(router));
        staking.setNotifier(address(conv), true);
        oracle.setPrice(address(weth), 2000e8);
        oracle.setPrice(address(alb), 1e7);
    }

    function test_distributeRefusesDeprecatedStakingAndFollowsReplacement() public {
        vm.prank(ES);
        staking.notifyDeposit(alice, 100e18);
        vm.prank(ES);
        staking.deprecate();

        weth.mint(address(conv), 10e18);
        vm.prank(KEEPER);
        vm.expectRevert(FeeConverter.StakingDeprecated.selector);
        conv.distribute();

        StakingContract next = new StakingContract(address(this), IALB(address(alb)), ES, GOV, address(weth));
        next.setNotifier(address(conv), true);

        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setStaking(IStakingContract(address(next)));
        es.setStaking(address(next));
        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setStaking(IStakingContract(address(next)));
        gov.setStaking(address(next));
        conv.setStaking(IStakingContract(address(next)));

        vm.prank(KEEPER);
        conv.distribute();
        assertEq(weth.balanceOf(address(next)), 10e18);
        assertEq(weth.balanceOf(address(staking)), 0);
        assertEq(weth.allowance(address(conv), address(next)), 0, "no allowance persists");
    }

    function test_setStakingRejectsAnythingTheEscrowsDoNotPointAt() public {
        address thief = makeAddr("thief");
        FakeStaking fake = new FakeStaking(thief);
        conv.setBurnBps(5000);
        weth.mint(address(conv), 10e18);
        alb.mint(address(conv), 1000e18);
        vm.prank(KEEPER);
        conv.distribute();

        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setStaking(IStakingContract(address(fake)));
        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setStaking(IStakingContract(address(router)));
        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.setStaking(IStakingContract(makeAddr("eoa")));
        vm.prank(KEEPER);
        vm.expectRevert();
        conv.setStaking(IStakingContract(address(staking)));

        assertEq(address(conv.staking()), address(staking));
        assertEq(weth.balanceOf(thief), 0);
        assertEq(alb.balanceOf(thief), 0);
    }

    function test_burnOnlyDistributeProceedsWhileStakingDeprecated() public {
        conv.setBurnBps(10_000);
        vm.prank(ES);
        staking.deprecate();
        alb.mint(address(conv), 100e18);
        weth.mint(address(conv), 4e18);
        uint256 supply = alb.totalSupply();

        vm.prank(KEEPER);
        conv.distribute();
        assertEq(alb.totalSupply(), supply - 100e18, "ALB burned");
        assertEq(conv.wethBurnBudget(), 4e18, "WETH earmarked");
        assertEq(weth.balanceOf(address(staking)), 0);
    }

    function test_releasedBurnBudgetStreamsOnNextDistribute() public {
        conv.setBurnBps(5000);
        weth.mint(address(conv), 2e18);
        vm.prank(KEEPER);
        conv.distribute();
        assertEq(conv.wethBurnBudget(), 1e18);
        oracle.setStale(address(alb), true);

        vm.expectRevert(FeeConverter.InvalidParams.selector);
        conv.releaseBurnBudget(1e18 + 1);
        vm.prank(KEEPER);
        vm.expectRevert();
        conv.releaseBurnBudget(1e18);

        conv.setBurnBps(0);
        conv.releaseBurnBudget(1e18);
        assertEq(conv.wethBurnBudget(), 0);
        vm.prank(KEEPER);
        conv.distribute();
        assertEq(weth.balanceOf(address(staking)), 2e18);
        assertEq(weth.balanceOf(address(conv)), 0);
    }

    function test_bunniFeeDistributorOwnershipCannotBeRenounced() public {
        BunniFeeDistributor dist =
            new BunniFeeDistributor(address(this), makeAddr("hub"), makeAddr("admin"), address(0), 6000, 3000, 1000);
        vm.expectRevert("BunniFeeDistributor: ownership required");
        dist.renounceOwnership();
        assertEq(dist.owner(), address(this));
    }
}

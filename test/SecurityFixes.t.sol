// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {StakingContract, ILoCFactoryRebase} from "../src/staking/StakingContract.sol";
import {BunniWrapperVault, IBunniToken, IBunniGauge, IBunniValuator}
    from "../src/wrappers/BunniWrapperVault.sol";

contract AuditGauge {
    MockERC20 public immutable lp;
    MockERC20 public immutable reward;
    mapping(address => uint256) public earned;
    bool public duplicateReward;
    constructor(MockERC20 l, MockERC20 r) { lp = l; reward = r; }
    function deposit(uint256 amount) external { lp.transferFrom(msg.sender, address(this), amount); }
    function withdraw(uint256 amount) external { lp.transfer(msg.sender, amount); }
    function accrue(address user, uint256 amount) external { earned[user] += amount; }
    function setDuplicateReward(bool enabled) external { duplicateReward = enabled; }
    function reward_tokens(uint256 i) external view returns (address) {
        return (i == 0 || (i == 1 && duplicateReward)) ? address(reward) : address(0);
    }
    function claim_rewards(address user) external {
        uint256 amount = earned[user];
        earned[user] = 0;
        reward.mint(user, amount);
    }
}

contract AuditValuator {
    function pricePerShare(address) external pure returns (uint256) { return 1e8; }
}

contract SecurityFixes is BaseTest {
    function tryReenterPol() external {
        POLHolder.Action[] memory none = new POLHolder.Action[](0);
        (bool ok, bytes memory reason) = address(pol).call(abi.encodeCall(pol.maintain, (none, none)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("Reentrancy()"));
    }

    function test_polTransientGuardBlocksCallbacksOnBaseAndReleases() public {
        vm.chainId(8453);
        _burnFixture(100e8, uint128(86400e8));
        pol.grantRoles(address(this), pol.ROLE_OPERATOR());
        pol.setSwapTarget(address(this), true);
        pol.setActionPermission(address(this), this.tryReenterPol.selector, address(0), true);
        _skip(1); twap.touch();
        POLHolder.Action[] memory actions = new POLHolder.Action[](2);
        actions[0] = POLHolder.Action(address(this), abi.encodeCall(this.tryReenterPol, ()), address(0), address(0), 0);
        actions[1] = _swapToAlb(500000)[0];
        vm.prank(KEEPER); pol.executeBurn(actions);
        vm.prank(KEEPER); pol.executeBurn(_swapToAlb(500000));
        assertEq(vm.load(address(pol), bytes32(uint256(0x8000000000ab143c06))), bytes32(0), "no persistent lock writes");
    }

    function _replacement() internal returns (StakingContract next) {
        next = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), address(govALB), address(weth)
        );
        next.setNotifier(address(this), true);
    }

    function test_migrationQueuesRewardsUntilAllHoldersAreBootstrapped() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(bob, 100 ether);
        StakingContract next = _replacement();
        esALB.setStaking(IStakingContract(address(next)));
        next.syncShares(alice);
        vm.expectRevert(StakingContract.MigrationIncomplete.selector);
        next.completeMigration();
        govALB.setStaking(IStakingContract(address(next)));
        _mintALB(address(this), 700 ether);
        alb.approve(address(next), 700 ether);
        next.notifyReward(address(alb), 700 ether);
        assertEq(next.migrationRewards(address(alb)), 700 ether);
        _skip(7 days);
        assertEq(next.pendingReward(alice, address(alb)), 0, "no bootstrap head start");
        next.syncShares(bob);
        next.completeMigration();
        assertFalse(next.migrationPending());
        assertEq(next.migrationRewards(address(alb)), 0);
        assertEq(next.trackedBalance(address(alb)), 700 ether);
        _skip(7 days);
        address[] memory tokens = new address[](1);
        tokens[0] = address(alb);
        vm.prank(alice); next.claim(tokens);
        vm.prank(bob); next.claim(tokens);
        assertApproxEqAbs(alb.balanceOf(alice), 350 ether, 1e6);
        assertApproxEqAbs(alb.balanceOf(bob), 350 ether, 1e6);
    }

    function test_migrationAllowsEarlyExitsAndQueuesPenalties() public {
        _stakeEs(alice, 100 ether);
        _stakeEs(bob, 100 ether);
        vm.prank(alice); uint256 index = esALB.startUnstake(100 ether);
        StakingContract next = _replacement();
        esALB.setStaking(IStakingContract(address(next)));
        govALB.setStaking(IStakingContract(address(next)));
        next.syncShares(alice);
        _skip(30 days);
        vm.prank(alice); esALB.finalizeUnstake(index);
        assertEq(next.sharesOf(alice), 0);
        uint256 penalty = next.migrationRewards(address(alb));
        assertGt(penalty, 0);
        assertEq(next.pendingReward(bob, address(alb)), 0);
        next.syncShares(bob);
        next.completeMigration();
        _skip(7 days);
        assertApproxEqAbs(next.pendingReward(bob, address(alb)), penalty, 1e6);
    }

    function test_migrationRejectsFundedReplacementAndPreservesOldWiring() public {
        StakingContract next = _replacement();
        _mintALB(address(this), 1 ether);
        alb.approve(address(next), 1 ether);
        next.notifyReward(address(alb), 1 ether);
        vm.expectRevert(StakingContract.MigrationRequiresEmptyInstance.selector);
        esALB.setStaking(IStakingContract(address(next)));
        assertEq(address(esALB.staking()), address(staking));
        assertFalse(staking.deprecated(), "failed wiring rolls back deprecation");
        vm.expectRevert(StakingContract.NotEscrow.selector);
        staking.deprecate();
        vm.expectRevert(StakingContract.NotEscrow.selector);
        next.beginMigration();
    }

    function test_exemptVestingCanBeUnexemptedBeforeCancel() public {
        uint256 index = _vestThenExempt();
        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 170 ether);
        vm.prank(alice); esALB.cancelUnstake(index);
        assertEq(staking.sharesOf(alice), 200 ether);
    }

    function test_vestingStartedWhileExemptRestoresOnlyLiquidShares() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        esALB.setHookExempt(alice, true);
        vm.prank(alice); uint256 index = esALB.startUnstake(100 ether);
        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 100 ether);
        vm.prank(alice); esALB.cancelUnstake(index);
        assertEq(staking.sharesOf(alice), 200 ether);
    }

    function testFuzz_splitBurnCannotCreateBudget(uint64 rawFirst) public {
        _burnFixture(100e8, uint128(86400e8));
        _skip(1);
        twap.touch();
        uint256 first = bound(uint256(rawFirst), 1, 999999);
        vm.startPrank(KEEPER);
        pol.executeBurn(_swapToAlb(first));
        vm.expectRevert(POLHolder.BudgetExhausted.selector);
        pol.executeBurn(_swapToAlb(1000001 - first));
        pol.executeBurn(_swapToAlb(1000000 - first));
        pol.executeBurn(_swapToAlb(1));
        vm.stopPrank();
        (,,,, uint128 spent,,,) = pol.burn();
        assertEq(spent, 1e8);
        assertEq(pol.burnBudget(), 0);
        assertEq(usdc.balanceOf(address(pol)), 9999e6);
    }

    function test_fractionalBurnAccrualSurvivesZeroBudgetCalls() public {
        _burnFixture(100e8, uint128(1));
        POLHolder.Action[] memory none = new POLHolder.Action[](0);
        for (uint256 i; i < 3;) {
            _skip(6 hours);
            twap.touch();
            vm.prank(KEEPER); pol.executeBurn(none);
            assertEq(pol.burnRemainder(), (i + 1) * 6 hours);
            unchecked { ++i; }
        }
        _skip(6 hours);
        twap.touch();

        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.NoOpExecution.selector);
        pol.executeBurn(none);
        assertEq(pol.burnRemainder(), 18 hours, "failed execution preserves prior accrual");
    }

    function test_cancelAndReauthorizeResetCarriedBurnBudget() public {
        _burnFixture(100e8, uint128(86400e8));
        _skip(1); twap.touch();
        vm.prank(KEEPER); pol.executeBurn(_swapToAlb(500000));
        assertEq(pol.burnBudget(), 0.5e8);
        pol.cancelBurn();
        assertEq(pol.burnBudget(), 0);
        assertEq(pol.burnRemainder(), 0);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(POL_ADMIN); pol.proposeBurn(100e8, uint128(86400e8), 2e8, expiry);
        pol.authorizeBurn(100e8, uint128(86400e8), 2e8, expiry, pol.burnNonce());
        vm.prank(KEEPER); pol.executeBurn(_swapToAlb(500000));
        (,,,, uint128 spent,,,) = pol.burn();
        assertEq(spent, 0, "new authorization starts with no inherited budget");
    }

    function test_polListsAreBoundedAndRemovalFreesCapacity() public {
        address first;
        for (uint256 i; i < 32;) {
            MockERC20 token = new MockERC20("Asset", "A", 18);
            address t = address(token);
            if (i == 0) first = t;
            pol.setAllowedAsset(t, true);
            pol.setAssetEntry(t, 0, 0, POLHolder.RewardMode.OUTRIGHT);
            if (i < 16) {
                assetOracle.setPrice(t, 1e8);
                pol.setStable(t, true);
                pol.setRewardToken(t, true);
            }
            unchecked { ++i; }
        }
        pol.setAllowedAsset(address(usdc), true);
        vm.expectRevert(POLHolder.ListLimitReached.selector);
        pol.setAssetEntry(address(usdc), 0, 0, POLHolder.RewardMode.OUTRIGHT);
        vm.expectRevert(POLHolder.ListLimitReached.selector);
        pol.setStable(address(usdc), true);
        vm.expectRevert(POLHolder.ListLimitReached.selector);
        pol.setRewardToken(address(usdc), true);

        pol.setAssetEntry(first, 0, 100, POLHolder.RewardMode.OUTRIGHT);
        pol.setStable(first, true);
        pol.setRewardToken(first, true);
        pol.removeAsset(first);
        pol.setStable(first, false);
        pol.setRewardToken(first, false);
        pol.setAssetEntry(address(usdc), 0, 0, POLHolder.RewardMode.OUTRIGHT);
        pol.setStable(address(usdc), true);
        pol.setRewardToken(address(usdc), true);
        assertEq(pol.portfolio(31), address(usdc));
        assertEq(pol.stableList(15), address(usdc));
        assertEq(pol.rewardList(15), address(usdc));
    }

    function test_wrapperDeduplicatesAndProtectsPrincipalDuringRecovery() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        MockERC20 reward = new MockERC20("Reward", "R", 18);
        AuditGauge gauge = new AuditGauge(lp, reward);
        BunniWrapperVault vault = new BunniWrapperVault(
            address(this), "Wrapper", "W", IBunniToken(address(lp)),
            IBunniGauge(address(gauge)), IBunniValuator(address(new AuditValuator()))
        );
        vault.setDepositor(address(this));
        gauge.setDuplicateReward(true);
        gauge.accrue(address(vault), 100 ether);
        (address[] memory tokens, uint256[] memory amounts) = vault.harvest("");
        assertEq(tokens.length, 1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 100 ether);
        MockERC20 unlisted = new MockERC20("Unlisted", "U", 18);
        unlisted.mint(address(vault), 12 ether);
        vm.prank(bob); vm.expectRevert(); vault.recoverReward(address(unlisted));
        vault.recoverReward(address(unlisted));
        assertEq(unlisted.balanceOf(address(this)), 12 ether);
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector); vault.recoverReward(address(lp));
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector); vault.recoverReward(address(gauge));
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector); vault.recoverReward(address(vault));
    }
    function _vestThenExempt() internal returns (uint256 index) {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        vm.prank(alice);
        index = esALB.startUnstake(100 ether);
        assertEq(staking.sharesOf(alice), 170 ether);
        esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 100 ether);
    }

    function test_cancelExemptVestingPreservesOtherTokenShares() public {
        uint256 index = _vestThenExempt();
        vm.prank(alice);
        esALB.cancelUnstake(index);
        assertEq(govALB.stakedSharesOf(alice), 100 ether);
        assertEq(staking.sharesOf(alice), 100 ether, "govALB shares preserved");
        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
        assertEq(staking.sharesOf(alice), 100 ether);
    }

    function test_finalizeExemptVestingPreservesOtherTokenShares() public {
        uint256 index = _vestThenExempt();
        _skip(60 days);
        vm.prank(alice);
        esALB.finalizeUnstake(index);
        assertEq(govALB.stakedSharesOf(alice), 100 ether);
        assertEq(staking.sharesOf(alice), 100 ether, "govALB shares preserved");
    }

    function _swapToAlb(uint256 usdcUnits) internal view returns (POLHolder.Action[] memory acts) {
        acts = new POLHolder.Action[](1);
        acts[0] = POLHolder.Action({
            target: address(router),
            data: abi.encodeCall(MockRouter.swap, (address(usdc), usdcUnits, address(alb), usdcUnits * 1e12)),
            approveToken: address(usdc),
            approveSpender: address(router),
            approveAmount: usdcUnits
        });
    }

    function _burnFixture(uint256 total, uint128 daily) internal returns (uint64 start) {
        pol.setAllowedAsset(address(usdc), true);
        pol.setAssetEntry(address(usdc), 10000, 0, POLHolder.RewardMode.OUTRIGHT);
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        vm.prank(DAO);
        alb.addMinter(address(router));
        usdc.mint(address(pol), 10000e6);
        start = uint64(vm.getBlockTimestamp());
        uint64 expiry = start + 30 days;
        vm.prank(POL_ADMIN);
        pol.proposeBurn(total, daily, 2e8, expiry);
        pol.authorizeBurn(total, daily, 2e8, expiry, pol.burnNonce());
    }

    function test_subsecondBurnsConsumeBudgetExactlyOnce() public {
        uint64 start = _burnFixture(100e8, uint128(86400e8));
        _skip(1);
        twap.touch();
        POLHolder.Action[] memory acts = _swapToAlb(500000);
        vm.startPrank(KEEPER);
        for (uint256 i; i < 10; ++i) pol.executeBurn(acts);
        vm.stopPrank();
        (,,,, uint128 spent, uint64 lastExec,,) = pol.burn();
        assertEq(spent, 1e8, "only the accrued $1 can be spent");
        assertEq(pol.burnBudget(), 0);
        assertEq(lastExec, start + 1, "clock accounts for accrued time");
    }

    function test_longIdleBurnRespectsWindowBudget() public {
        _burnFixture(10000e8, uint128(1000e8));
        _skip(20 days);
        twap.touch();
        POLHolder.Action[] memory acts = _swapToAlb(2000e6);
        vm.startPrank(KEEPER);
        pol.executeBurn(acts);
        pol.executeBurn(acts);
        vm.stopPrank();
        (,,,, uint128 spent,,,) = pol.burn();
        assertEq(spent, 2000e8, "two-day cap can be spent only once");
    }

    function test_repayThenBurnPaysAccruedInterestFirst() public {
        LoC line = _createLoC(address(pol), 1000 ether, 1000 ether, 1000 ether, 1000);
        pol.setLoC(ILoC(address(line)));
        vm.prank(address(pol));
        line.draw(100 ether, bob);
        _skip(365 days);
        twap.touch();
        _mintALB(address(pol), 110 ether);
        POLHolder.Action[] memory none = new POLHolder.Action[](0);
        vm.prank(KEEPER);
        pol.maintain(none, none);
        assertEq(alb.balanceOf(address(pol)), 0);
        assertEq(line.drawnAmount(), 0, "principal and accrued interest repaid");
        assertEq(line.totalInterestMinted(), 10 ether);
    }

    function test_deprecatedStakingFreezesMembership() public {
        _stakeEs(alice, 100 ether);
        _mintALB(address(this), 700 ether);
        alb.approve(address(staking), 700 ether);
        staking.notifyReward(address(alb), 700 ether);
        StakingContract replacement = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), address(govALB), address(weth)
        );
        esALB.setStaking(IStakingContract(address(replacement)));
        govALB.setStaking(IStakingContract(address(replacement)));
        staking.setLoCFactory(ILoCFactoryRebase(address(0)));
        factory.setStakingContract(address(replacement));

        _stakeEs(bob, 9900 ether);
        vm.expectRevert(StakingContract.StakingDeprecated.selector);
        staking.syncShares(bob);
        assertEq(staking.sharesOf(bob), 0);
        assertEq(staking.sharesOf(alice), 100 ether);
        replacement.syncShares(alice);
        replacement.completeMigration();
        _skip(7 days);
        address[] memory tokens = new address[](1);
        tokens[0] = address(alb);
        vm.prank(bob);
        staking.claim(tokens);
        assertEq(alb.balanceOf(bob), 0, "new stakers cannot claim old rewards");
        vm.prank(alice);
        staking.claim(tokens);
        assertApproxEqAbs(alb.balanceOf(alice), 700 ether, 1e6);
    }

    function test_externalGaugeClaimsAreForwardedByHarvest() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        MockERC20 reward = new MockERC20("Reward", "R", 18);
        AuditGauge gauge = new AuditGauge(lp, reward);
        AuditValuator valuator = new AuditValuator();
        BunniWrapperVault vault = new BunniWrapperVault(
            address(this), "Wrapper", "W", IBunniToken(address(lp)),
            IBunniGauge(address(gauge)), IBunniValuator(address(valuator))
        );
        vault.setDepositor(address(this));
        lp.mint(address(this), 1 ether);
        lp.approve(address(vault), 1 ether);
        vault.deposit(abi.encode(1 ether));
        gauge.accrue(address(vault), 100 ether);
        vm.prank(bob);
        gauge.claim_rewards(address(vault));
        (, uint256[] memory amounts) = vault.harvest("");
        assertEq(amounts[0], 100 ether);
        assertEq(reward.balanceOf(address(vault)), 0);
        gauge.accrue(address(vault), 10 ether);
        vault.harvest("");
        assertEq(reward.balanceOf(address(this)), 110 ether);
        assertEq(reward.balanceOf(address(vault)), 0, "no stranded rewards");
        vault.withdraw(1 ether, "");
        assertEq(lp.balanceOf(address(this)), 1 ether, "principal remains fully backed");
    }
}

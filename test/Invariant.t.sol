// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {EsALB} from "../src/token/EsALB.sol";
import {GovALB} from "../src/token/GovALB.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {LoCFactory} from "../src/loc/LoCFactory.sol";
import {MigrationContract} from "../src/migration/MigrationContract.sol";
import {MockERC20, MockLegacyEsALB} from "./Mocks.sol";

contract Harness is BaseTest {
    LoC public loc;

    function init() external {
        loc = _createLoC(alice, 5_000_000 ether, 100_000 ether, 500_000 ether, 500);
    }

    function albC() external view returns (ALBToken) { return alb; }
    function esC() external view returns (EsALB) { return esALB; }
    function govC() external view returns (GovALB) { return govALB; }
    function stakingC() external view returns (StakingContract) { return staking; }
    function factoryC() external view returns (LoCFactory) { return factory; }
    function migrationC() external view returns (MigrationContract) { return migration; }
    function legacyAlbC() external view returns (MockERC20) { return legacyALB; }
    function legacyEsC() external view returns (MockLegacyEsALB) { return legacyEsALB; }
    function actorsC() external view returns (address, address, address) { return (alice, bob, carol); }

    function mintLegacyALB(address to, uint256 amt) external { legacyALB.mint(to, amt); }
    function mintLegacyEsALB(address to, uint256 amt) external { legacyEsALB.mint(to, amt); }
}

contract Handler is Test {
    Harness internal h;
    ALBToken internal alb;
    EsALB internal es;
    GovALB internal gov;
    MigrationContract internal migration;
    MockERC20 internal legacyALB;
    MockLegacyEsALB internal legacyEs;
    LoC internal loc;
    address[3] internal actors;

    uint256 public ghostMigrated;

    constructor(Harness h_) {
        h = h_;
        alb = h_.albC();
        es = h_.esC();
        gov = h_.govC();
        migration = h_.migrationC();
        legacyALB = h_.legacyAlbC();
        legacyEs = h_.legacyEsC();
        loc = h_.loc();
        (actors[0], actors[1], actors[2]) = h_.actorsC();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function migrateALB(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        amount = uint96(bound(amount, 1, 1e24));
        h.mintLegacyALB(a, amount);
        vm.startPrank(a);
        legacyALB.approve(address(migration), amount);
        migration.migrateALB(amount);
        vm.stopPrank();
        ghostMigrated += amount;
    }

    function migrateEsALB(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        amount = uint96(bound(amount, 1, 1e24));
        h.mintLegacyEsALB(a, amount);
        vm.startPrank(a);
        legacyEs.approve(address(migration), amount);
        migration.migrateEsALB(amount);
        vm.stopPrank();
        ghostMigrated += amount;
    }

    function stakeEs(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        uint256 bal = alb.balanceOf(a);
        if (bal == 0) return;
        amount = uint96(bound(amount, 1, bal));
        vm.startPrank(a);
        alb.approve(address(es), amount);
        es.depositFor(a, amount);
        vm.stopPrank();
    }

    function stakeGov(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        uint256 bal = alb.balanceOf(a);
        if (bal == 0) return;
        amount = uint96(bound(amount, 1, bal));
        vm.startPrank(a);
        alb.approve(address(gov), amount);
        gov.depositFor(a, amount);
        vm.stopPrank();
    }

    function startUnstake(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        uint256 bal = es.balanceOf(a);
        if (bal == 0) return;
        amount = uint96(bound(amount, 1, bal));
        vm.prank(a);
        es.startUnstake(amount);
    }

    function finalizeUnstake(uint256 seed, uint256 idx) external {
        address a = _actor(seed);
        uint256 n = es.positionsOf(a).length;
        if (n == 0) return;
        idx = bound(idx, 0, n - 1);
        if (es.positionsOf(a)[idx].esAmount == 0) return;
        if (block.timestamp < es.positionsOf(a)[idx].minUnlockAt) return;
        vm.prank(a);
        es.finalizeUnstake(idx);
    }

    function cancelUnstake(uint256 seed, uint256 idx) external {
        address a = _actor(seed);
        uint256 n = es.positionsOf(a).length;
        if (n == 0) return;
        idx = bound(idx, 0, n - 1);
        if (es.positionsOf(a)[idx].esAmount == 0) return;
        vm.prank(a);
        es.cancelUnstake(idx);
    }

    function instantRedeem(uint256 seed, uint96 amount) external {
        address a = _actor(seed);
        uint256 allowed = es.previewInstantAllowance(a);
        if (allowed == 0) return;
        if (es.balanceOf(a) < allowed) allowed = es.balanceOf(a);
        if (allowed == 0) return;
        amount = uint96(bound(amount, 1, allowed));
        vm.prank(a);
        es.instantRedeem(amount);
    }

    function draw(uint96 amount) external {
        amount = uint96(bound(amount, 1, 100_000 ether));
        if (loc.dailyDrawn() + amount > loc.maxDaily()) return;
        if (loc.weeklyDrawn() + amount > loc.maxWeekly()) return;
        if (loc.drawnAmount() + amount > loc.maxTotal()) return;
        vm.prank(loc.beneficiary());
        loc.draw(amount, loc.beneficiary());
    }

    function repay(uint96 amount) external {
        address a = loc.beneficiary();
        uint256 debt = loc.drawnAmount();
        uint256 bal = alb.balanceOf(a);
        uint256 max = debt < bal ? debt : bal;
        if (max == 0) return;
        amount = uint96(bound(amount, 1, max));
        vm.startPrank(a);
        alb.approve(address(loc), amount);
        loc.repay(amount);
        vm.stopPrank();
    }

    function pokeInterest() external {
        loc.pokeInterest();
    }

    function claimAlb(uint256 seed) external {
        address[] memory toks = new address[](1);
        toks[0] = address(alb);
        vm.prank(_actor(seed));
        h.stakingC().claim(toks);
    }

    function warp(uint32 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1 hours, 20 days));
    }
}

contract InvariantTest is Test {
    Harness internal h;
    Handler internal handler;
    LoC internal loc;

    function setUp() public {
        h = new Harness();
        h.setUp();
        h.init();
        loc = h.loc();

        handler = new Handler(h);
        targetContract(address(handler));
    }

    function invariant_supplyUnderCap() public view {
        assertLe(h.albC().totalSupply(), h.albC().MAX_SUPPLY());
    }

    function invariant_escrowFullyBacked() public view {
        assertGe(h.albC().balanceOf(address(h.esC())), h.esC().totalSupply());
        assertGe(h.albC().balanceOf(address(h.govC())), h.govC().totalSupply());
    }

    function invariant_escrowContractsHoldNoShares() public view {
        StakingContract s = h.stakingC();
        assertEq(s.sharesOf(address(h.esC())), 0);
        assertEq(s.sharesOf(address(h.govC())), 0);
    }

    function invariant_sharesReconcile() public view {
        StakingContract s = h.stakingC();
        (address a, address b, address c) = h.actorsC();
        assertEq(s.totalShares(), s.sharesOf(a) + s.sharesOf(b) + s.sharesOf(c));
    }

    function invariant_migrationOneToOne() public view {
        MigrationContract m = h.migrationC();
        assertEq(m.totalLegacyALBLocked() + m.totalLegacyEsALBLocked(), handler.ghostMigrated());
    }

    function invariant_principalUnderMaxTotal() public view {
        assertLe(loc.totalPrincipalMinted(), loc.maxTotal());
    }

    function invariant_drawWindowsRespectLimits() public view {
        assertLe(loc.dailyDrawn(), loc.maxDaily());
        assertLe(loc.weeklyDrawn(), loc.maxWeekly());
    }

    function invariant_issuanceAccountingCloses() public view {
        assertEq(
            h.factoryC().totalIssued(),
            loc.totalPrincipalMinted() + loc.totalInterestMinted() + loc.totalOptionMinted()
        );
    }

    function invariant_stakingSolvent() public view {
        StakingContract s = h.stakingC();
        (address a, address b, address c) = h.actorsC();
        uint256 owed = s.pendingReward(a, address(h.albC()))
            + s.pendingReward(b, address(h.albC()))
            + s.pendingReward(c, address(h.albC()));
        assertLe(owed, h.albC().balanceOf(address(s)));
    }
}

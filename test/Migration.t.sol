// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {MigrationContract} from "../src/migration/MigrationContract.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {AlbPriceOracle} from "../src/oracle/AlbPriceOracle.sol";

contract MigrationTest is BaseTest {
    function test_migrateAlbOneToOne() public {
        legacyALB.mint(alice, 1000 ether);
        vm.startPrank(alice);
        legacyALB.approve(address(migration), 1000 ether);
        migration.migrateALB(1000 ether);
        vm.stopPrank();

        assertEq(alb.balanceOf(alice), 1000 ether);
        assertEq(legacyALB.balanceOf(alice), 0);
        assertEq(legacyALB.balanceOf(address(migration)), 1000 ether, "legacy locked forever");
        assertEq(migration.totalLegacyALBLocked(), 1000 ether);
    }

    function test_migrateEsAlbGivesEsAlbAndAutoStakes() public {
        legacyEsALB.mint(alice, 500 ether);
        vm.startPrank(alice);
        legacyEsALB.approve(address(migration), 500 ether);
        migration.migrateEsALB(500 ether);
        vm.stopPrank();

        assertEq(esALB.balanceOf(alice), 500 ether);
        assertEq(staking.sharesOf(alice), 500 ether, "auto-staked on mint");
        assertEq(migration.totalLegacyEsALBLocked(), 500 ether);
        assertGe(alb.balanceOf(address(esALB)), esALB.totalSupply(), "1:1 backed");
    }

    function test_issuanceInvariantHolds() public {
        legacyALB.mint(alice, 300 ether);
        legacyEsALB.mint(bob, 700 ether);

        vm.startPrank(alice);
        legacyALB.approve(address(migration), 300 ether);
        migration.migrateALB(300 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        legacyEsALB.approve(address(migration), 700 ether);
        migration.migrateEsALB(700 ether);
        vm.stopPrank();

        assertEq(
            alb.totalSupply(),
            migration.totalLegacyALBLocked() + migration.totalLegacyEsALBLocked()
        );
    }

    function test_migrationHasNoAdminFunctions() public {
        (bool ok,) = address(migration).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "must have no owner()");
        (ok,) = address(migration).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "must have no pause()");
        (ok,) = address(migration).call(abi.encodeWithSignature("recoverERC20(address,address,uint256)"));
        assertFalse(ok, "must have no sweep");
    }

    function test_killSwitchIsMinterRevocation() public {
        vm.prank(DAO);
        alb.revokeMinter(address(migration));

        legacyALB.mint(alice, 100 ether);
        vm.startPrank(alice);
        legacyALB.approve(address(migration), 100 ether);
        vm.expectRevert(ALBToken.NotMinter.selector);
        migration.migrateALB(100 ether);
        vm.stopPrank();
    }

    function test_migrationIsPermanent() public {
        _skip(3650 days);
        legacyALB.mint(alice, 1 ether);
        vm.startPrank(alice);
        legacyALB.approve(address(migration), 1 ether);
        migration.migrateALB(1 ether);
        vm.stopPrank();
        assertEq(alb.balanceOf(alice), 1 ether);
    }

    function testFuzz_migrationNeverOverMints(uint96 albAmt, uint96 esAmt) public {
        albAmt = uint96(bound(albAmt, 1, 1e24));
        esAmt = uint96(bound(esAmt, 1, 1e24));

        legacyALB.mint(alice, albAmt);
        legacyEsALB.mint(alice, esAmt);
        vm.startPrank(alice);
        legacyALB.approve(address(migration), albAmt);
        migration.migrateALB(albAmt);
        legacyEsALB.approve(address(migration), esAmt);
        migration.migrateEsALB(esAmt);
        vm.stopPrank();

        assertEq(alb.totalSupply(), uint256(albAmt) + uint256(esAmt));
        assertEq(alb.balanceOf(alice), albAmt);
        assertEq(esALB.balanceOf(alice), esAmt);
    }
}

contract OracleTest is BaseTest {
    function test_smaRevertsBeforeWarm() public {
        vm.expectRevert(AlbPriceOracle.NotWarm.selector);
        oracle.sma20();
        assertFalse(oracle.isHealthy());
    }

    function test_smaAveragesTwentySamples() public {
        _warmOracle();
        assertEq(oracle.sma20(), 1e8);
        assertTrue(oracle.isHealthy());
    }

    function test_onePokePerDay() public {
        twap.touch();
        assertTrue(oracle.poke());
        assertFalse(oracle.poke(), "same day is a no-op");
        _skip(1 days);
        twap.touch();
        assertTrue(oracle.poke());
    }

    function test_staleTwapBlocksSampling() public {
        _skip(7 hours);
        vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
        oracle.poke();
    }

    function test_staleBufferIsUnhealthy() public {
        _warmOracle();
        assertTrue(oracle.isHealthy());
        _skip(5 days);
        twap.touch();
        assertFalse(oracle.isHealthy(), "stale buffer must fail health check");
    }

    function test_sampleDeviationIsClamped() public {
        _warmOracle();
        twap.setPrice(3e8);
        _skip(1 days);
        twap.touch();
        oracle.poke();

        assertLt(oracle.sma20(), 1.01e8, "single poke must not jump the SMA");
    }

    function test_smaTracksRisingPriceOverTime() public {
        _warmOracle();
        twap.setPrice(3e8);

        uint256 t = block.timestamp;
        for (uint256 i; i < 40; ++i) {
            t += 1 days;
            vm.warp(t);
            twap.touch();
            oracle.poke();
        }
        assertEq(oracle.sma20(), 3e8, "buffer fully rolled over at the new level");
    }

    function test_longGapInvalidatesBufferInsteadOfForwardFilling() public {
        _warmOracle();
        assertEq(oracle.sma20(), 1e8);

        _skip(25 days);
        twap.setPrice(0.2e8);
        twap.touch();
        oracle.poke();

        assertFalse(oracle.isHealthy(), "a long outage must leave the oracle unhealthy");
        vm.expectRevert(AlbPriceOracle.NotWarm.selector);
        oracle.sma20();
    }

    function test_warmthRequiresDistinctSampledDays() public {
        oracle.poke();

        _skip(3 days);
        twap.touch();
        oracle.poke();
        assertGt(oracle.count(), oracle.distinctDays(), "fill wrote more slots than days sampled");
        assertFalse(oracle.isHealthy(), "slots filled must not imply warm");
        assertLt(oracle.distinctDays(), 20);
    }

    function test_calendarBoundaryCannotDoubleSample() public {
        _warmOracle();

        uint256 dayStart = ((block.timestamp / 1 days) + 1) * 1 days;
        vm.warp(dayStart + 1 days - 1);
        twap.touch();
        assertTrue(oracle.poke(), "first sample lands");
        uint64 tsAfterFirst = oracle.lastSampleTs();

        vm.warp(dayStart + 1 days + 1);
        twap.touch();
        assertFalse(oracle.poke(), "second sample two seconds later must be rejected");
        assertEq(oracle.lastSampleTs(), tsAfterFirst, "no sample written");
    }

    function test_movesAreClampedInBothDirections() public {
        _warmOracle();

        twap.setPrice(10e8);
        _skip(1 days);
        twap.touch();
        oracle.poke();
        assertLt(oracle.sma20(), 1.01e8, "upward spike must be clamped");

        twap.setPrice(0.1e8);
        _skip(1 days);
        twap.touch();
        oracle.poke();
        assertGt(oracle.sma20(), 0.9e8, "downward crash must also be clamped per sample");
    }

    function test_safeSpotPriceRejectsBrokenFeedBothWays() public {
        _warmOracle();
        assertEq(oracle.safeSpotPrice(), 1e8);

        twap.setPrice(1);
        vm.expectRevert(AlbPriceOracle.UnhealthyOracle.selector);
        oracle.safeSpotPrice();

        twap.setPrice(1000e8);
        vm.expectRevert(AlbPriceOracle.UnhealthyOracle.selector);
        oracle.safeSpotPrice();
    }

    function test_safeSpotPriceRejectsStaleAndZero() public {
        _warmOracle();
        _skip(7 hours);
        vm.expectRevert(AlbPriceOracle.StaleTwap.selector);
        oracle.safeSpotPrice();

        twap.setPrice(0);
        vm.expectRevert(AlbPriceOracle.InvalidPrice.selector);
        oracle.safeSpotPrice();
    }

    function test_decimalsAreImmutable() public view {
        assertEq(oracle.decimals(), ORACLE_DEC);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";

contract Verify21_1 is BaseTest {
    function test_optionGrantRemainsQueuedBehindParkedInterest() public {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option({amount: 1600 ether, strikePrice: 1e8, expiry: 0, redeemed: false});
        LoC o = LoC(
            factory.createLoC(bob, address(staking), 10_000 ether, 10_000 ether, 10_000 ether, 5000, opts)
        );
        vm.prank(bob);
        o.draw(1000 ether, bob);

        factory.setAggregateIssuanceCap(factory.totalIssued() + 100 ether);

        _skip(365 days);
        _warmOracle();

        o.pokeInterest();
        uint256 parked = o.unmintedInterest();
        emit log_named_uint("parked interest", parked);
        assertGt(parked, 100 ether, "owed exceeds headroom -> flush deferred");

        vm.prank(bob);
        vm.expectRevert(LoC.InterestUnpaid.selector);
        o.draw(1, bob);

        uint256 drawn = o.drawnAmount();
        uint256 expectedGrant = 1600 ether - drawn;
        emit log_named_uint("drawn (incl capitalised interest)", drawn);
        emit log_named_uint("expected grant", expectedGrant);
        assertLe(expectedGrant, 100 ether, "grant fits in headroom");

        uint256 bobBefore = alb.balanceOf(bob);
        uint256 issuedBefore = factory.totalIssued();
        vm.prank(bob);
        o.redeemOption(0);

        assertEq(alb.balanceOf(bob) - bobBefore, 0, "grant queued behind interest");
        assertEq(o.unmintedGrant(), expectedGrant);
        assertEq(factory.totalIssued(), issuedBefore, "headroom preserved");
        assertEq(o.unmintedInterest(), parked, "sink's interest still parked");
        assertEq(o.drawnAmount(), 0, "debt (incl. capitalised interest) written off by the option");

        uint256 sinkBefore = alb.balanceOf(o.interestSink());
        o.pokeInterest();
        assertEq(alb.balanceOf(o.interestSink()), sinkBefore, "interest still undeliverable");
        assertEq(o.unmintedInterest(), parked);
        assertLt(factory.aggregateIssuanceCap() - factory.totalIssued(), parked, "remaining headroom < owed");

        factory.setAggregateIssuanceCap(0);
        o.pokeInterest();
        assertEq(o.unmintedInterest(), 0);
        assertEq(o.unmintedGrant(), 0);
        assertEq(alb.balanceOf(bob) - bobBefore, expectedGrant);
        assertEq(alb.balanceOf(o.interestSink()) - sinkBefore, parked, "sink eventually receives all interest");
    }

    function test_otherLoCDrawConsumesHeadroomWhileInterestParked() public {
        LoC a = _createLoC(bob, 10_000 ether, 10_000 ether, 10_000 ether, 5000);
        LoC b = _createLoC(carol, 10_000 ether, 10_000 ether, 10_000 ether, 0);
        vm.prank(bob);
        a.draw(1000 ether, bob);
        factory.setAggregateIssuanceCap(factory.totalIssued() + 100 ether);
        _skip(365 days);
        a.pokeInterest();
        uint256 parked = a.unmintedInterest();
        assertGt(parked, 100 ether);

        vm.prank(carol);
        b.draw(100 ether, carol);
        assertEq(factory.aggregateIssuanceCap() - factory.totalIssued(), 0, "headroom gone to LoC B's principal");
        assertEq(a.unmintedInterest(), parked, "LoC A's sink interest still parked");
    }
}

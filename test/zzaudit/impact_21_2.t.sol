// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {LoC} from "../../src/loc/LoC.sol";

contract Impact21_2 is BaseTest {
    function test_optionGrantWaitsForParkedInterest() public {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option({amount: 1590 ether, strikePrice: 0.5e8, expiry: 0, redeemed: false});
        LoC o = LoC(factory.createLoC(bob, address(staking), 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 5000, opts));
        vm.prank(bob);
        o.draw(1000 ether, bob);

        factory.setAggregateIssuanceCap(factory.totalIssued() + 100 ether);
        _skip(365 days);
        o.pokeInterest();
        uint256 parked = o.unmintedInterest();
        assertEq(parked, 500 ether, "interest parked");
        assertEq(o.drawnAmount(), 1500 ether);

        vm.expectRevert(LoC.InterestUnpaid.selector);
        vm.prank(bob);
        o.draw(1, bob);

        _warmOracle();
        o.pokeInterest();
        parked = o.unmintedInterest();
        assertGt(parked, 500 ether);
        uint256 sinkBefore = alb.balanceOf(o.interestSink());
        uint256 bobBefore = alb.balanceOf(bob);
        uint256 issuedBefore = factory.totalIssued();
        uint256 expectedGrant = 1590 ether - o.drawnAmount();
        assertGt(expectedGrant, 0);
        assertLt(expectedGrant, factory.aggregateIssuanceCap() - issuedBefore, "grant fits in headroom");

        vm.prank(bob);
        o.redeemOption(0);

        uint256 grantMinted = alb.balanceOf(bob) - bobBefore;
        emit log_named_uint("grant minted to bob", grantMinted);
        emit log_named_uint("unmintedInterest after", o.unmintedInterest());
        emit log_named_uint("sink delta", alb.balanceOf(o.interestSink()) - sinkBefore);
        emit log_named_uint("headroom left", factory.aggregateIssuanceCap() - factory.totalIssued());
        emit log_named_uint("issued delta", factory.totalIssued() - issuedBefore);

        assertEq(grantMinted, 0, "grant cannot bypass parked interest");
        assertEq(o.unmintedGrant(), expectedGrant);
        assertEq(factory.totalIssued(), issuedBefore);
        assertEq(o.unmintedInterest(), parked, "interest still parked");
        assertEq(alb.balanceOf(o.interestSink()) - sinkBefore, 0, "sink received nothing");
        factory.setAggregateIssuanceCap(0);
        o.pokeInterest();
        assertEq(o.unmintedInterest(), 0);
        assertEq(o.unmintedGrant(), 0);
        assertEq(alb.balanceOf(bob) - bobBefore, expectedGrant);
        assertEq(alb.balanceOf(o.interestSink()) - sinkBefore, parked);
    }
}

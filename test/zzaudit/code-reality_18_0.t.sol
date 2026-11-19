// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Distributor} from "../../src/farm/Distributor.sol";
import {MockERC20} from "../Mocks.sol";

contract GasBurnToken18 is MockERC20 {
    bool public burn;
    constructor() MockERC20("Burn", "BRN", 18) {}
    function setBurn(bool b) external { burn = b; }
    function transfer(address to, uint256 a) public override returns (bool) {
        if (burn) { uint256 x; while (true) { x = uint256(keccak256(abi.encode(x))); } }
        return super.transfer(to, a);
    }
}

contract CodeReality18_0 is BaseTest {
    Distributor internal farm;
    MockERC20 internal lp;
    address internal FEES = makeAddr("fees");
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public override {
        super.setUp();
        farm = new Distributor(DAO, FEES);
        lp = new MockERC20("LP", "LP", 18);
        lp.mint(alice, 1_000 ether);
        vm.prank(alice); lp.approve(address(farm), type(uint256).max);
    }

    function test_noFuse_repeatedStipendBurnEvenAfterOwnerPausesStream() public {
        vm.warp(T0);
        vm.prank(DAO);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        GasBurnToken18[8] memory toks;
        for (uint256 i; i < 8; ++i) {
            toks[i] = new GasBurnToken18();
            vm.prank(DAO);
            uint256 idx = farm.addStream(pid, address(toks[i]), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
            vm.prank(DAO); farm.setStreamRate(pid, idx, 1 ether);
            toks[i].mint(address(this), 1_000 ether);
            toks[i].approve(address(farm), 1_000 ether);
            farm.fundStream(pid, idx, 1_000 ether);
        }
        vm.prank(alice); farm.deposit(pid, 100 ether);
        vm.warp(T0 + 100);

        vm.prank(alice);
        uint256 g0 = gasleft(); farm.withdraw(pid, 1 ether); g0 -= gasleft();
        vm.prank(alice);
        uint256 gb = gasleft(); farm.withdraw(pid, 1 ether); gb -= gasleft();

        vm.warp(T0 + 200);
        for (uint256 i; i < 8; ++i) toks[i].setBurn(true);

        vm.prank(alice);
        uint256 g1 = gasleft(); farm.withdraw(pid, 1 ether); g1 -= gasleft();
        assertGt(farm.rewardLockedUp(pid, alice, 0), 0, "locked up");

        for (uint256 i; i < 8; ++i) { vm.prank(DAO); farm.setStreamActive(pid, i, false); }
        vm.warp(T0 + 300);

        vm.prank(alice);
        uint256 g2 = gasleft(); farm.withdraw(pid, 1 ether); g2 -= gasleft();
        vm.prank(alice);
        uint256 g3 = gasleft(); farm.withdraw(pid, 1 ether); g3 -= gasleft();

        emit log_named_uint("gas healthy touch (8 real payouts)", g0);
        emit log_named_uint("gas no-payout touch", gb);
        emit log_named_uint("gas touch1 (burn)", g1);
        emit log_named_uint("gas touch2 (burn, all streams paused)", g2);
        emit log_named_uint("gas touch3 (burn, all streams paused)", g3);

        assertGt(g2, gb + 8 * 140_000, "repeat touch still burns 8 stipends");
        assertGt(g3, gb + 8 * 140_000, "and again, forever");
    }
}

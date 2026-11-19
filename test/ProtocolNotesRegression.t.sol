// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {EscrowedToken} from "../src/token/EscrowedToken.sol";
import {GovALB} from "../src/token/GovALB.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {MockERC20} from "./Mocks.sol";
import {MockHookToken, MockBrickableToken} from "./Distributor.t.sol";
import {ILoCFactoryRebase} from "../src/staking/StakingContract.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {LoC} from "../src/loc/LoC.sol";

contract ProtocolNotesRegression is BaseTest {
    MockERC20 internal partner;
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        partner = new MockERC20("Partner", "PTR", 18);
        staking.registerStream(address(partner), 0);
        staking.grantRoles(ADMIN, staking.ROLE_ADMIN());
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(staking), amount);
        staking.notifyReward(token, amount);
    }

    function test_instantRedeemBaseIncludesTokensInUnstaking() public {
        _stakeEs(alice, 1_000 ether);
        vm.prank(alice);
        esALB.startUnstake(400 ether);
        _skip(48 hours);

        assertEq(esALB.previewInstantAllowance(alice), 20 ether, "base = liquid + in-unstaking");
        vm.prank(alice);
        esALB.instantRedeem(20 ether);
        assertEq(esALB.balanceOf(alice), 580 ether);
    }

    function test_govALBSupplyCapEnforcedInsideMint() public {
        GovALB capped = new GovALB(address(this), IALB(address(alb)), 1_000 ether);
        StakingContract st = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), address(capped), address(weth)
        );
        capped.setStaking(IStakingContract(address(st)));
        _mintALB(alice, 2_000 ether);
        vm.startPrank(alice);
        alb.approve(address(capped), type(uint256).max);
        capped.depositFor(alice, 1_000 ether);
        vm.expectRevert(EscrowedToken.SupplyCapExceeded.selector);
        capped.depositFor(alice, 1);
        vm.stopPrank();

        vm.expectRevert(EscrowedToken.InvalidParams.selector);
        capped.setSupplyCap(999 ether);
        capped.setSupplyCap(1_500 ether);
        vm.prank(alice);
        capped.depositFor(alice, 500 ether);
        assertEq(capped.totalSupply(), 1_500 ether);

        capped.grantRoles(ADMIN, capped.ROLE_ADMIN());
        vm.prank(ADMIN);
        vm.expectRevert();
        capped.setSupplyCap(0);
    }

    function test_adminCanExemptABondingModuleFromTheStakingHook() public {
        address bonding = makeAddr("bonding");
        _stakeEs(alice, 1_000 ether);
        assertEq(staking.sharesOf(alice), 1_000 ether);

        vm.prank(ADMIN);
        esALB.setHookExempt(bonding, true);
        esALB.setWhitelisted(bonding, true);

        vm.prank(alice);
        esALB.transfer(bonding, 400 ether);
        assertEq(staking.sharesOf(alice), 600 ether, "holder debited");
        assertEq(staking.sharesOf(bonding), 0, "custodian earns nothing");

        vm.prank(ADMIN);
        vm.expectRevert();
        esALB.setHookExempt(bonding, false);
        vm.expectRevert(EscrowedToken.InvalidParams.selector);
        esALB.setHookExempt(address(staking), false);
    }

    function test_stakingContractSwapIsACleanDeprecationWithBootstrap() public {
        _stakeEs(alice, 1_000 ether);
        vm.prank(alice);
        esALB.startUnstake(200 ether);
        assertEq(staking.sharesOf(alice), 940 ether);
        assertEq(esALB.stakedSharesOf(alice), 940 ether, "escrow reports the same truth");
        _notify(address(partner), 700 ether);
        _skip(7 days);

        StakingContract next = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), address(govALB), address(weth)
        );
        esALB.setStaking(IStakingContract(address(next)));
        govALB.setStaking(IStakingContract(address(next)));
        assertFalse(esALB.isHookExempt(address(staking)), "old contract no longer a custodian");
        assertTrue(esALB.isHookExempt(address(next)));

        address[] memory toks = new address[](1); toks[0] = address(partner);
        vm.prank(alice);
        staking.claim(toks);
        assertApproxEqRel(partner.balanceOf(alice), 700 ether, 0.001e18, "nothing stranded on the old contract");

        assertEq(next.sharesOf(alice), 0);
        next.syncShares(alice);
        assertEq(next.sharesOf(alice), 940 ether, "bootstrapped from stakedSharesOf");
        vm.expectRevert(StakingContract.NothingToDo.selector);
        next.syncShares(alice);

        vm.expectRevert(StakingContract.NothingToDo.selector);
        next.syncShares(address(esALB));

        next.completeMigration();

        esALB.setWhitelisted(bob, true);
        vm.prank(alice);
        esALB.transfer(bob, 100 ether);
        assertEq(next.sharesOf(alice), 840 ether);
        assertEq(next.sharesOf(bob), 100 ether);
    }

    function test_shareChangesAutoClaimAndAFailingRewardTokenDefersInsteadOfBricking() public {
        _stakeEs(alice, 1_000 ether);
        _notify(address(partner), 700 ether);
        _skip(7 days);
        assertGt(staking.pendingReward(alice, address(partner)), 0);

        esALB.setWhitelisted(bob, true);
        vm.prank(alice);
        esALB.transfer(bob, 1 ether);
        assertApproxEqRel(partner.balanceOf(alice), 700 ether, 0.001e18, "auto-claimed on transfer");
        assertEq(staking.pendingReward(alice, address(partner)), 0);

        _notify(address(partner), 100 ether);
        _skip(7 days);
        vm.mockCallRevert(address(partner), abi.encodeWithSelector(bytes4(0xa9059cbb)), "paused");
        vm.prank(alice);
        esALB.transfer(bob, 1 ether);
        vm.clearMockedCalls();
        assertApproxEqRel(staking.pendingReward(alice, address(partner)), 100 ether, 0.005e18, "deferred, still claimable (bob now holds 1/1000)");
    }

    function test_retireStreamRecoversUnemittedAndKeepsEarnedClaimable() public {
        _stakeEs(alice, 1_000 ether);
        _notify(address(partner), 700 ether);
        _skip(3 days + 12 hours);

        uint256 before = partner.balanceOf(address(this));
        vm.prank(ADMIN);
        staking.retireStream(address(partner));
        uint256 recovered = partner.balanceOf(address(this)) - before;
        assertApproxEqRel(recovered, 350 ether, 0.001e18, "un-emitted half pulled");

        address[] memory toks = new address[](1); toks[0] = address(partner);
        vm.prank(alice);
        staking.claim(toks);
        assertApproxEqRel(partner.balanceOf(alice), 350 ether, 0.001e18, "earned half claimable");

        partner.mint(address(this), 1 ether); partner.approve(address(staking), 1 ether);
        vm.expectRevert(StakingContract.StreamRetiredError.selector);
        staking.notifyReward(address(partner), 1 ether);
        vm.expectRevert(StakingContract.GraceNotElapsed.selector);
        staking.deleteStream(address(partner), DAO);
        vm.prank(ADMIN);
        vm.expectRevert();
        staking.deleteStream(address(partner), DAO);

        _skip(90 days);
        staking.deleteStream(address(partner), DAO);
        assertEq(staking.streamList(0) == address(partner) ? 1 : 0, 0, "gone from the hot loop");
    }

    function test_depositAfterRetirementEarnsNothingFromTheRetiredStream() public {
        _stakeEs(alice, 1_000 ether);
        _notify(address(partner), 700 ether);
        _skip(7 days);
        vm.prank(ADMIN);
        staking.retireStream(address(partner));

        _stakeEs(bob, 10_000 ether);
        _skip(30 days);
        assertEq(staking.pendingReward(bob, address(partner)), 0, "no phantom rewards");

        assertApproxEqRel(staking.pendingReward(alice, address(partner)) + partner.balanceOf(alice), 700 ether, 0.001e18);
    }

    function test_adminRoleSplitOnStaking() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        vm.prank(ADMIN);
        vm.expectRevert();
        staking.registerStream(address(t), 0);
        staking.registerStream(address(t), 0);
        vm.prank(ADMIN);
        staking.setNotifier(bob, true);
        vm.prank(ADMIN);
        vm.expectRevert(StakingContract.CoreNotifier.selector);
        staking.setNotifier(address(esALB), false);
        vm.prank(ADMIN);
        vm.expectRevert();
        staking.setMinRebasePullInterval(1 hours);
        vm.prank(bob);
        vm.expectRevert();
        staking.registerStream(address(t), 0);
    }
}

contract AdminBoundaryRegression is BaseTest {
    MockERC20 internal partner;
    Distributor internal farm;
    address internal ADMIN = makeAddr("admin");
    address internal FEES = makeAddr("fees");

    function setUp() public override {
        super.setUp();
        partner = new MockERC20("Partner", "PTR", 18);
        staking.registerStream(address(partner), 0);
        staking.grantRoles(ADMIN, staking.ROLE_ADMIN());
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        farm = new Distributor(address(this), FEES);
        farm.grantRoles(ADMIN, farm.ROLE_ADMIN());
    }

    function test_adminMintPowerIsBoundedByTimelockedRights() public {
        MockERC20 junk = new MockERC20("J", "J", 18);
        vm.prank(DAO); alb.addMinter(address(farm));
        // Pool creation is Admin-level: an empty pool earns nothing, every value path
        // (MintRights, PULL binding/terms, funded reserves) keeps its own gate.
        vm.prank(ADMIN);
        uint256 pid = farm.addPool(address(junk), Distributor.PoolKind.DEPOSIT);

        vm.prank(ADMIN);
        uint256 idx = farm.addStream(pid, address(alb), Distributor.StreamKind.MINT, address(0), address(0), 0);
        vm.prank(ADMIN);
        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, idx, 1);
        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, idx, 1);
        farm.scheduleMintRights(address(alb), 1 ether);
        vm.expectRevert(Distributor.TimelockNotElapsed.selector);
        farm.applyMintRights(address(alb));
        vm.warp(block.timestamp + farm.MINT_RIGHTS_DELAY());
        farm.applyMintRights(address(alb));
        vm.prank(ADMIN);
        farm.setStreamRate(pid, idx, 1 ether);
        vm.prank(ADMIN);
        vm.expectRevert(Distributor.MintRightsExceeded.selector);
        farm.setStreamRate(pid, idx, 1 ether + 1);
        uint256 b = farm.addStream(pid, address(partner), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(ADMIN);
        vm.expectRevert();
        farm.setStreamRate(pid, b, 1 ether);
        farm.setStreamRate(pid, b, 1 ether);
        vm.prank(ADMIN);
        farm.setStreamRate(pid, b, 0.5 ether);
        vm.prank(ADMIN);
        vm.expectRevert();
        farm.setStreamRate(pid, b, 0.6 ether);
    }

    function test_pullStreamRequiresTheSourcesConsentAndStopsOnRevoke() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        lp.mint(alice, 1_000 ether);
        vm.prank(alice); lp.approve(address(farm), type(uint256).max);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);

        vm.expectRevert(Distributor.PullSourceNotConsented.selector);
        farm.addStream(pid, address(lp), Distributor.StreamKind.PULL, alice, address(0), 0);

        vm.prank(alice); farm.setPullSource(true);
        uint256 idx = farm.addStream(pid, address(lp), Distributor.StreamKind.PULL, alice, address(0), 0);
        vm.prank(alice);
        farm.setPullTerms(pid, idx, 0, type(uint128).max, type(uint32).max);
        vm.prank(ADMIN);
        vm.expectRevert();
        farm.setStreamRate(pid, idx, 1 ether);
        farm.setStreamRate(pid, idx, 1 ether);
        lp.mint(bob, 10 ether); vm.prank(bob); lp.approve(address(farm), 10 ether);
        vm.prank(bob); farm.deposit(pid, 10 ether);

        vm.prank(alice); farm.setPullSource(false);
        vm.warp(block.timestamp + 100);
        vm.prank(bob); farm.withdraw(pid, 0);
        assertEq(lp.balanceOf(alice), 1_000 ether, "nothing pulled after revoke");
    }

    function test_flaggingAnIntermediaryStripsItsHookStake() public {
        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        uint256 pid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        hook.mint(alice, 100 ether);
        assertEq(farm.poolTotalLp(pid), 100 ether);
        vm.prank(ADMIN); farm.setIntermediary(alice, true);
        (uint256 amt,,,) = farm.userInfo(pid, alice);
        assertEq(amt, 0, "stake stripped when flagged");
        assertEq(farm.poolTotalLp(pid), 0, "totalStaked not inflated");
    }

    function test_coreStreamsCannotBeRetiredAndRecoveryGoesToOwner() public {
        vm.prank(ADMIN);
        vm.expectRevert(StakingContract.CoreStream.selector);
        staking.retireStream(address(alb));
        vm.prank(ADMIN);
        vm.expectRevert(StakingContract.CoreStream.selector);
        staking.retireStream(address(weth));

        partner.mint(address(this), 100 ether); partner.approve(address(staking), 100 ether);
        staking.notifyReward(address(partner), 100 ether);
        uint256 before = partner.balanceOf(address(this));
        vm.prank(ADMIN); staking.retireStream(address(partner));
        assertGt(partner.balanceOf(address(this)) - before, 0, "un-emitted remainder to Owner");
        assertEq(partner.balanceOf(ADMIN), 0, "never to the caller");
    }

    function test_deletedStreamCannotBeReRegistered() public {
        vm.prank(ADMIN); staking.retireStream(address(partner));
        _skip(91 days);
        staking.deleteStream(address(partner), address(this));
        vm.expectRevert(StakingContract.StreamIsDeleted.selector);
        staking.registerStream(address(partner), 0);
    }

    function test_exemptingStripsSharesAndUnexemptingRestoresThem() public {
        _stakeEs(alice, 1_000 ether);
        assertEq(staking.sharesOf(alice), 1_000 ether);
        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 0, "exempt => zero shares");

        vm.prank(alice); esALB.startUnstake(400 ether);
        assertEq(staking.sharesOf(alice), 0, "no partial share for an exempt account");
        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 600 ether, "restored to what the position implies");
        assertEq(esALB.stakedSharesOf(alice), 600 ether);
    }

    function test_plainTransferToEscrowIsRefused() public {
        _stakeEs(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(EscrowedToken.NotWhitelisted.selector);
        esALB.transfer(address(esALB), 100 ether);
        vm.prank(alice); esALB.startUnstake(100 ether);
        assertEq(esALB.balanceOf(address(esALB)), 100 ether);
    }
}

contract ShareAccountingInvariant is BaseTest {
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        esALB.setWhitelisted(bob, true);
    }

    function _check(address u, string memory path) internal view {
        assertEq(staking.sharesOf(u), esALB.stakedSharesOf(u), path);
    }

    function test_sharesMirrorPositionAfterEveryPath() public {
        _stakeEs(alice, 1_000 ether);
        _check(alice, "after mint");

        vm.prank(alice); esALB.transfer(bob, 100 ether);
        _check(alice, "after transfer (from)"); _check(bob, "after transfer (to)");

        vm.prank(alice); uint256 i0 = esALB.startUnstake(400 ether);
        _check(alice, "after startUnstake");
        assertEq(staking.sharesOf(alice), 500 ether + 280 ether, "500 liquid + 70% of 400");

        _skip(48 hours);
        uint256 alw = esALB.previewInstantAllowance(alice);
        assertEq(alw, (900 ether * 2) / 100, "2% of the WHOLE 900 position incl. unstaking");
        vm.prank(alice); esALB.instantRedeem(alw);
        _check(alice, "after instantRedeem");

        vm.prank(alice); esALB.cancelUnstake(i0);
        _check(alice, "after cancelUnstake");

        vm.prank(alice); uint256 i1 = esALB.startUnstake(200 ether);
        _check(alice, "after second startUnstake");
        _skip(60 days);
        vm.prank(alice); esALB.finalizeUnstake(i1);
        _check(alice, "after finalizeUnstake");

        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 0, "exempt => 0");
        esALB.setHookExempt(alice, false);
        _check(alice, "after un-exempt");
    }

    function testFuzz_sharesMirrorPositionUnderRandomSequences(uint256 seed) public {
        _stakeEs(alice, 10_000 ether);
        uint256[] memory open = new uint256[](0);
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            uint256 bal = esALB.balanceOf(alice);
            if (op == 0 && bal > 1 ether) {
                vm.prank(alice); esALB.transfer(bob, (r >> 8) % (bal / 2) + 1);
            } else if (op == 1 && bal > 1 ether) {
                vm.prank(alice); uint256 idx = esALB.startUnstake((r >> 8) % (bal / 2) + 1);
                uint256[] memory n = new uint256[](open.length + 1);
                for (uint256 k; k < open.length; ++k) n[k] = open[k];
                n[open.length] = idx; open = n;
            } else if (op == 2 && open.length != 0) {
                uint256 which = (r >> 8) % open.length;
                vm.prank(alice); esALB.cancelUnstake(open[which]);
                open[which] = open[open.length - 1];
                assembly { mstore(open, sub(mload(open), 1)) }
            } else if (op == 3 && open.length != 0) {
                _skip(60 days);
                uint256 which = (r >> 8) % open.length;
                vm.prank(alice); esALB.finalizeUnstake(open[which]);
                open[which] = open[open.length - 1];
                assembly { mstore(open, sub(mload(open), 1)) }
            } else if (op == 4) {
                _skip(48 hours);
                uint256 alw = esALB.previewInstantAllowance(alice);
                uint256 amt = alw < bal ? alw : bal;
                if (amt != 0) { vm.prank(alice); esALB.instantRedeem(amt); }
            } else {
                _skip(1 days);
            }
            assertEq(staking.sharesOf(alice), esALB.stakedSharesOf(alice), "invariant after step");
        }
    }
}

contract MockMalformedReturnToken is MockERC20 {
    bool public malformed;
    constructor() MockERC20("Bad", "BAD", 18) {}
    function setMalformed(bool m) external { malformed = m; }
    function transfer(address to, uint256 a) public override returns (bool) {
        if (malformed) {
            assembly { mstore(0, 2) return(0, 32) }
        }
        return super.transfer(to, a);
    }
}

contract SecondPassRegression is BaseTest {
    MockERC20 internal partner;
    Distributor internal farm;
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        partner = new MockERC20("Partner", "PTR", 18);
        staking.registerStream(address(partner), 0);
        staking.grantRoles(ADMIN, staking.ROLE_ADMIN());
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        farm = new Distributor(address(this), makeAddr("fees"));
        farm.grantRoles(ADMIN, farm.ROLE_ADMIN());
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(staking), amount);
        staking.notifyReward(token, amount);
    }

    function test_malformedReturnDataDefersInsteadOfBrickingTheHook() public {
        MockMalformedReturnToken bad = new MockMalformedReturnToken();
        staking.registerStream(address(bad), 0);
        _stakeEs(alice, 1_000 ether);
        bad.mint(address(this), 100 ether); bad.approve(address(staking), 100 ether);
        staking.notifyReward(address(bad), 100 ether);
        _skip(7 days);
        bad.setMalformed(true);

        vm.prank(alice); esALB.startUnstake(100 ether);
        assertTrue(staking.autoClaimDisabled(address(bad)), "fused after one deferral");
        assertGt(staking.pendingReward(alice, address(bad)), 0, "still owed");

        vm.prank(alice); esALB.startUnstake(100 ether);

        bad.setMalformed(false);
        address[] memory toks = new address[](1); toks[0] = address(bad);
        vm.prank(alice); staking.claim(toks);
        assertFalse(staking.autoClaimDisabled(address(bad)), "re-armed by a successful claim");
        assertGt(bad.balanceOf(alice), 0);
    }

    function test_streamListIsBounded() public {
        vm.expectRevert(StakingContract.NotAContract.selector);
        staking.registerStream(makeAddr("eoa"), 0);

        uint256 have;
        for (;; ++have) {
            (bool ok, bytes memory d) = address(staking).staticcall(abi.encodeWithSignature("streamList(uint256)", have));
            if (!ok || d.length == 0) break;
        }
        for (uint256 i = have; i < staking.MAX_STREAMS(); ++i) {
            staking.registerStream(address(new MockERC20("x", "x", 18)), 0);
        }
        MockERC20 extra = new MockERC20("y", "y", 18);
        vm.expectRevert(StakingContract.TooManyStreams.selector);
        staking.registerStream(address(extra), 0);
    }

    function test_neverEmittedStreamDeletesWithoutGrace() public {
        MockERC20 t = new MockERC20("t", "t", 18);
        staking.registerStream(address(t), 0);
        vm.prank(ADMIN); staking.retireStream(address(t));
        staking.deleteStream(address(t), address(this));
    }

    function test_drawSettlesDustClockAndRefusesWhileInterestUnpaid() public {
        LoC big = _createLoC(bob, 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500);
        vm.prank(bob); big.draw(1 wei, bob);
        _skip(30 days);
        big.pokeInterest();
        uint64 beforeClock = big.lastAccrual();
        vm.prank(bob); big.draw(1_000_000 ether, bob);
        assertEq(big.lastAccrual(), uint64(block.timestamp), "dust period settled before the new principal");
        assertGt(big.lastAccrual(), beforeClock);
        _skip(1 days);
        big.pokeInterest();
        uint256 owed = (uint256(1_000_000 ether + 1) * 500 * 1 days) / (365 days * 10_000);
        assertApproxEqAbs(big.drawnAmount(), 1_000_000 ether + 1 + owed, 1, "charged for one day at the new principal, not 31");

        factory.setAggregateIssuanceCap(factory.totalIssued());
        _skip(30 days);
        big.pokeInterest();
        assertGt(big.unmintedInterest(), 0);
        vm.prank(bob);
        vm.expectRevert(LoC.InterestUnpaid.selector);
        big.draw(1 ether, bob);
        _mintALB(bob, 10 ether);
        vm.startPrank(bob); alb.approve(address(big), 10 ether); big.repay(10 ether); vm.stopPrank();
    }

    function test_resumeAndGrantAreOwnerOnly() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        uint256 idx = farm.addStream(pid, address(partner), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        vm.prank(ADMIN); farm.setStreamActive(pid, idx, false);
        vm.prank(ADMIN); vm.expectRevert(); farm.setStreamActive(pid, idx, true);
        farm.setStreamActive(pid, idx, true);
        vm.prank(ADMIN); farm.setDepositsPaused(true);
        vm.prank(ADMIN); vm.expectRevert(); farm.setDepositsPaused(false);
        farm.setDepositsPaused(false);
    }
}

contract MockShortReturnToken is MockERC20 {
    uint256 public retSize;
    constructor() MockERC20("Short", "SHT", 18) {}
    function setRetSize(uint256 s) external { retSize = s; }
    function transfer(address to, uint256 a) public override returns (bool) {
        uint256 s = retSize;
        if (s != 0 && s < 32) {
            assembly { mstore(0, 1) return(sub(32, s), s) }
        }
        return super.transfer(to, a);
    }
}

contract MockShortFactory {
    fallback() external { assembly { return(0, 1) } }
}

contract ThirdPassRegression is BaseTest {
    MockERC20 internal partner;
    Distributor internal farm;
    address internal ADMIN = makeAddr("admin");

    function setUp() public override {
        super.setUp();
        partner = new MockERC20("Partner", "PTR", 18);
        staking.registerStream(address(partner), 0);
        staking.grantRoles(ADMIN, staking.ROLE_ADMIN());
        esALB.grantRoles(ADMIN, esALB.ROLE_ADMIN());
        farm = new Distributor(address(this), makeAddr("fees"));
        farm.grantRoles(ADMIN, farm.ROLE_ADMIN());
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).approve(address(staking), amount);
        staking.notifyReward(token, amount);
    }

    function test_shortReturnDefersInsteadOfHaltingTheEscrowHook() public {
        MockShortReturnToken short = new MockShortReturnToken();
        staking.registerStream(address(short), 0);
        _stakeEs(alice, 1_000 ether);
        short.mint(address(this), 100 ether); short.approve(address(staking), 100 ether);
        staking.notifyReward(address(short), 100 ether);
        _skip(7 days);

        uint256[3] memory sizes = [uint256(1), 31, 16];
        for (uint256 i; i < 3; ++i) {
            if (i != 0) {
                short.mint(address(this), 100 ether); short.approve(address(staking), 100 ether);
                staking.notifyReward(address(short), 100 ether);
                _skip(7 days);
            }
            short.setRetSize(sizes[i]);
            uint256 held = short.balanceOf(alice);
            vm.prank(alice); esALB.startUnstake(10 ether);
            assertTrue(staking.autoClaimDisabled(address(short)), "fused after the deferral");
            assertEq(short.balanceOf(alice), held, "nothing paid on a malformed return");
            assertGt(staking.pendingReward(alice, address(short)), 0, "still owed");

            short.setRetSize(0);
            address[] memory toks = new address[](1); toks[0] = address(short);
            vm.prank(alice); staking.claim(toks);
            assertFalse(staking.autoClaimDisabled(address(short)));
        }
        assertGt(short.balanceOf(alice), 0);

        short.mint(address(this), 100 ether); short.approve(address(staking), 100 ether);
        staking.notifyReward(address(short), 100 ether);
        _skip(7 days);
        short.setRetSize(32);
        uint256 before = short.balanceOf(alice);
        vm.prank(alice); esALB.startUnstake(10 ether);
        assertGt(short.balanceOf(alice), before, "32-byte true pays");
        assertFalse(staking.autoClaimDisabled(address(short)));
    }

    function test_shortReturnRewardDoesNotHaltFarmWithdrawOrHookTransfer() public {
        MockShortReturnToken short = new MockShortReturnToken();
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        uint256 idx = farm.addStream(pid, address(short), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        short.mint(address(this), 1_000 ether); short.approve(address(farm), 1_000 ether);
        farm.fundStream(pid, idx, 1_000 ether);
        farm.setStreamRate(pid, idx, 1 ether);
        lp.mint(alice, 10 ether);
        vm.startPrank(alice); lp.approve(address(farm), 10 ether); farm.deposit(pid, 10 ether); vm.stopPrank();

        MockHookToken hook = new MockHookToken();
        hook.setFarm(farm);
        uint256 hpid = farm.addPool(address(hook), Distributor.PoolKind.HOOK);
        uint256 hidx = farm.addStream(hpid, address(short), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        short.mint(address(this), 1_000 ether); short.approve(address(farm), 1_000 ether);
        farm.fundStream(hpid, hidx, 1_000 ether);
        farm.setStreamRate(hpid, hidx, 1 ether);
        hook.mint(bob, 5 ether);
        _skip(100);

        short.setRetSize(1);
        vm.prank(alice); farm.withdraw(pid, 10 ether);
        assertEq(lp.balanceOf(alice), 10 ether, "principal never hostage to a reward token");
        assertEq(short.balanceOf(alice), 0);
        vm.prank(bob); hook.transfer(carol, 1 ether);
        assertEq(hook.balanceOf(carol), 1 ether);

        short.setRetSize(0);
        uint256[] memory pids = new uint256[](1); pids[0] = pid;
        vm.prank(alice); farm.harvestMany(pids);
        assertApproxEqRel(short.balanceOf(alice), 100 ether, 0.01e18, "re-locked remainder paid once healthy");
    }

    function test_adminCannotFlashDrainAFundedReserveByRateSpike() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        uint256 idx = farm.addStream(pid, address(partner), Distributor.StreamKind.BALANCE, address(0), address(0), 0);
        partner.mint(address(this), 1_000 ether); partner.approve(address(farm), 1_000 ether);
        farm.fundStream(pid, idx, 1_000 ether);
        farm.setStreamRate(pid, idx, 0.001 ether);
        lp.mint(ADMIN, 9_900 ether);
        vm.startPrank(ADMIN);
        lp.approve(address(farm), 9_900 ether); farm.deposit(pid, 9_900 ether);
        vm.expectRevert();
        farm.setStreamRate(pid, idx, 1_000 ether);
        farm.setStreamRate(pid, idx, 0.0005 ether);
        vm.stopPrank();
        _skip(1);
        vm.prank(ADMIN); farm.withdraw(pid, 9_900 ether);
        assertLt(partner.balanceOf(ADMIN), 0.001 ether, "one second at the slowed rate, not the reserve");
    }

    function test_revertingStreamCanBeRetiredDeletedAndRecovered() public {
        MockBrickableToken brick = new MockBrickableToken();
        staking.registerStream(address(brick), 1 hours);
        _stakeEs(alice, 1_000 ether);
        brick.mint(address(this), 100 ether); brick.approve(address(staking), 100 ether);
        staking.notifyReward(address(brick), 100 ether);
        _skip(30 minutes);
        brick.setBricked(true);

        vm.prank(ADMIN); staking.retireStream(address(brick));
        uint256 tracked = staking.trackedBalance(address(brick));
        assertApproxEqRel(tracked, 100 ether, 0.01e18, "unemitted half stays tracked here");
        assertEq(brick.balanceOf(address(this)), 0);

        vm.expectRevert(StakingContract.UnknownStream.selector);
        staking.sweepDeletedStream(address(brick), address(this));
        _skip(90 days);
        staking.deleteStream(address(brick), address(this));
        assertTrue(staking.isDeletedStream(address(brick)));
        assertEq(brick.balanceOf(address(this)), 0);

        brick.setBricked(false);
        vm.prank(ADMIN); vm.expectRevert(); staking.sweepDeletedStream(address(brick), ADMIN);
        staking.sweepDeletedStream(address(brick), address(this));
        assertEq(brick.balanceOf(address(this)), 100 ether, "recovered once the token works again");
    }

    function test_exemptionOnOneEscrowLeavesTheOtherEscrowsShares() public {
        _stakeEs(alice, 100 ether);
        _stakeGov(alice, 100 ether);
        assertEq(staking.sharesOf(alice), 200 ether);
        vm.prank(ADMIN); esALB.setHookExempt(alice, true);
        assertEq(staking.sharesOf(alice), 100 ether, "only esALB's shares stripped");
        vm.expectRevert(StakingContract.NothingToDo.selector);
        staking.syncShares(alice);
        _stakeGov(alice, 50 ether);
        assertEq(staking.sharesOf(alice), 150 ether, "govALB keeps earning while esALB is exempt");
        esALB.setHookExempt(alice, false);
        assertEq(staking.sharesOf(alice), 250 ether);
    }

    function test_codelessOrShortFactoryCannotFreezeTheHooks() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(StakingContract.NotAContract.selector);
        staking.setLoCFactory(ILoCFactoryRebase(eoa));
        MockShortFactory shortF = new MockShortFactory();
        staking.setLoCFactory(ILoCFactoryRebase(address(shortF)));
        _stakeEs(alice, 100 ether);
        _skip(1 days);
        vm.prank(alice); esALB.startUnstake(10 ether);
        staking.setLoCFactory(ILoCFactoryRebase(address(0)));
    }

    function test_addStreamRejectsCodelessToken() public {
        MockERC20 lp = new MockERC20("LP", "LP", 18);
        uint256 pid = farm.addPool(address(lp), Distributor.PoolKind.DEPOSIT);
        address eoa = makeAddr("eoa");
        vm.expectRevert(Distributor.InvalidParams.selector);
        farm.addStream(pid, eoa, Distributor.StreamKind.MINT, address(0), address(0), 0);
    }

    function test_poolListIsUnboundedAndFlaggingWalksOnlyHookPools() public {
        for (uint256 i; i < 300; ++i) {
            farm.addPool(address(new MockERC20("x", "x", 18)), Distributor.PoolKind.DEPOSIT);
        }
        assertEq(farm.hookPids().length, 0, "no hook pools registered");
        uint256 gasBefore = gasleft();
        farm.setIntermediary(address(0xBEEF), true);
        assertLt(gasBefore - gasleft(), 200_000, "flagging must not scale with pool count");
    }

    function test_optionGrantWaitsBehindParkedInterest() public {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option({amount: 2_000 ether, strikePrice: 0.5e8, expiry: 0, redeemed: false});
        LoC o = LoC(factory.createLoC(bob, address(staking), 10_000_000 ether, 1_000_000 ether, 1_000_000 ether, 500, opts));
        vm.prank(bob); o.draw(1_000 ether, bob);
        factory.setAggregateIssuanceCap(factory.totalIssued());
        _skip(10 days);
        _warmOracle();
        uint256 balBefore = alb.balanceOf(bob);

        vm.prank(bob); o.redeemOption(0);
        uint256 interest = o.unmintedInterest();
        uint256 grant = o.unmintedGrant();
        assertGt(interest, 0);
        assertEq(o.drawnAmount(), 0, "debt written off");
        assertApproxEqRel(grant, 1_000 ether, 0.01e18, "residual grant parked, not minted");
        assertEq(alb.balanceOf(bob), balBefore, "nothing minted ahead of the sink");

        factory.setAggregateIssuanceCap(factory.totalIssued() + interest + interest / 2);
        o.pokeInterest();
        assertEq(o.unmintedInterest(), 0, "interest flushed first");
        assertEq(o.unmintedGrant(), grant, "grant still parked");
        assertEq(alb.balanceOf(bob), balBefore);

        factory.setAggregateIssuanceCap(0);
        o.pokeInterest();
        assertEq(o.unmintedGrant(), 0);
        assertEq(alb.balanceOf(bob), balBefore + grant, "grant delivered once there is room");
    }
}

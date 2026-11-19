// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";
import {AlbPriceOracle} from "../src/oracle/AlbPriceOracle.sol";
import {LoC} from "../src/loc/LoC.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {POLHolderRareLegs} from "../src/pol/POLHolderRareLegs.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {BunniWrapperVault, IBunniToken, IBunniGauge, IBunniValuator, IGaugeMinter}
    from "../src/wrappers/BunniWrapperVault.sol";

contract RegressionListingGauge {
    MockERC20 public immutable lp;
    address[] internal _rewards;
    mapping(address => mapping(address => uint256)) public earned;

    constructor(MockERC20 l) { lp = l; }

    function add_reward(address token) external { _rewards.push(token); }

    function reward_tokens(uint256 i) external view returns (address) {
        return i < _rewards.length ? _rewards[i] : address(0);
    }

    function deposit(uint256 amount) external { lp.transferFrom(msg.sender, address(this), amount); }
    function withdraw(uint256 amount) external { lp.transfer(msg.sender, amount); }
    function accrue(address token, address user, uint256 amount) external { earned[token][user] += amount; }

    function claim_rewards(address user) external {
        for (uint256 i; i < _rewards.length; ++i) {
            address t = _rewards[i];
            uint256 a = earned[t][user];
            if (a != 0) {
                earned[t][user] = 0;
                MockERC20(t).mint(user, a);
            }
        }
    }
}

contract RegressionMinter {
    MockERC20 public immutable token;
    mapping(address => uint256) public owed;

    constructor(MockERC20 t) { token = t; }

    function accrue(address staker, uint256 a) external { owed[staker] += a; }

    function mint(address) external {
        uint256 a = owed[msg.sender];
        owed[msg.sender] = 0;
        token.mint(msg.sender, a);
    }
}

contract RegressionValuator {
    function pricePerShare(address) external pure returns (uint256) { return 1e8; }
}

contract OraclePolWrapperRegression is BaseTest {
    uint256 internal constant T0 = 1_800_000_000;

    function _at(uint256 day) internal {
        vm.warp(T0 + day * 1 days);
    }

    function _pokeDays(uint256 from, uint256 to) internal {
        for (uint256 d = from; d <= to;) {
            _at(d);
            twap.touch();
            oracle.poke();
            unchecked { ++d; }
        }
    }

    function _option(uint256 strike) internal returns (LoC line) {
        LoC.Option[] memory opts = new LoC.Option[](1);
        opts[0] = LoC.Option(100 ether, strike, 0, false);
        line = LoC(factory.createLoC(bob, address(staking), 0, 0, 0, 0, opts));
    }

    function test_O1_shortGapPurgeClampsFirstReadToRetainedAnchor() public {
        _pokeDays(1, 20);
        LoC line = _option(2e8);

        _at(24);
        twap.setPrice(5e8);
        oracle.poke();
        assertEq(oracle.count(), 1, "history purged");
        assertEq(oracle.distinctDays(), 1, "20-day re-warm kept");
        assertEq(oracle.buffer(0), 1.1e8, "clamped to +10% of the retained anchor");

        twap.setPrice(1e8);
        _pokeDays(25, 43);
        assertEq(vm.getBlockTimestamp(), T0 + 43 days);
        assertTrue(oracle.isHealthy());
        assertEq(oracle.sma20(), 1.005e8, "one +10% sample in twenty");

        vm.prank(bob);
        vm.expectRevert(LoC.BelowStrike.selector);
        line.redeemOption(0);
        assertEq(alb.balanceOf(bob), 0);
    }

    function test_O1_shortGapPurgeClampsDownwardRead() public {
        _pokeDays(1, 20);
        _at(30);
        twap.setPrice(0.01e8);
        oracle.poke();
        assertEq(oracle.buffer(0), 0.9e8);
    }

    function test_O1_windowWideGapStartsFromRawRead() public {
        _pokeDays(1, 20);
        _at(40);
        twap.setPrice(3e8);
        oracle.poke();
        assertEq(oracle.count(), 1);
        assertEq(oracle.buffer(0), 3e8);
    }

    function test_O1_ownerPurgeStartsFromRawRead() public {
        _pokeDays(1, 20);
        vm.prank(DAO);
        oracle.setTwapSource(twap, true);
        _at(21);
        twap.setPrice(3e8);
        oracle.poke();
        assertEq(oracle.buffer(0), 3e8);
    }

    function test_O1_bufferSumExactAcrossAnchoredPurge() public {
        _pokeDays(1, 20);
        _at(26);
        twap.setPrice(2e8);
        oracle.poke();
        _pokeDays(27, 33);
        uint256 sum;
        for (uint256 i; i < 20; ++i) sum += oracle.buffer(i);
        assertEq(oracle.bufferSum(), sum);
    }

    function _vault()
        internal
        returns (BunniWrapperVault vault, RegressionListingGauge gauge, MockERC20 lp, RegressionMinter minter, MockERC20 primary)
    {
        lp = new MockERC20("BunniLP", "BLP", 18);
        primary = new MockERC20("Primary", "P", 18);
        gauge = new RegressionListingGauge(lp);
        minter = new RegressionMinter(primary);
        vault = new BunniWrapperVault(
            address(this), "W", "W", IBunniToken(address(lp)), IBunniGauge(address(gauge)),
            IBunniValuator(address(new RegressionValuator()))
        );
        vault.setDepositor(address(this));
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(primary));
        lp.mint(address(this), 10 ether);
        lp.approve(address(vault), 10 ether);
        vault.deposit(abi.encode(10 ether));
    }

    function test_W1_protectedGaugeListingsAreSkippedAndPrimaryStillMints() public {
        (BunniWrapperVault vault, RegressionListingGauge gauge, MockERC20 lp, RegressionMinter minter, MockERC20 primary) =
            _vault();
        MockERC20 extra = new MockERC20("Extra", "X", 18);
        gauge.add_reward(address(lp));
        gauge.add_reward(address(gauge));
        gauge.add_reward(address(vault));
        gauge.add_reward(address(extra));

        lp.mint(address(vault), 3 ether);
        gauge.accrue(address(extra), address(vault), 2 ether);
        minter.accrue(address(vault), 50 ether);

        (address[] memory tokens, uint256[] memory amounts) = vault.harvest("");
        assertEq(tokens.length, 2, "only extra + primary");
        assertEq(tokens[0], address(extra));
        assertEq(amounts[0], 2 ether);
        assertEq(tokens[1], address(primary));
        assertEq(amounts[1], 50 ether);
        assertEq(primary.balanceOf(address(this)), 50 ether, "Minter emission delivered");
        assertEq(lp.balanceOf(address(vault)), 3 ether, "protected LP never forwarded");
        assertEq(lp.balanceOf(address(this)), 0);

        vault.withdraw(10 ether, "");
        assertEq(lp.balanceOf(address(this)), 10 ether, "principal fully backed");
    }

    function test_W1_setGaugeMinterRejectsProtectedPrimary() public {
        (BunniWrapperVault vault, RegressionListingGauge gauge, MockERC20 lp, RegressionMinter minter,) = _vault();
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector);
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(lp));
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector);
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(gauge));
        vm.expectRevert(BunniWrapperVault.ProtectedToken.selector);
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(vault));
        vault.setGaugeMinter(IGaugeMinter(address(0)), address(0));
        assertEq(vault.primaryRewardToken(), address(0));
    }

    function _dust() internal view returns (uint256) {
        return POLHolderRareLegs(pol.rareLegs()).DUST_VALUE();
    }

    function test_P1_dustValueIsOneOracleUnit() public view {
        assertEq(_dust(), 1e8);
    }

    function test_P1_pricedDustStableCanBeDelisted_capacityFreed() public {
        address first;
        for (uint256 i; i < 16; ++i) {
            MockERC20 t = new MockERC20("S", "S", 6);
            if (i == 0) first = address(t);
            assetOracle.setPrice(address(t), 1e20);
            pol.setStable(address(t), true);
        }
        MockERC20(first).mint(address(pol), 1e6);
        pol.setStable(first, false);
        assertFalse(pol.isStable(first));

        MockERC20 replacement = new MockERC20("N", "N", 6);
        assetOracle.setPrice(address(replacement), 1e20);
        pol.setStable(address(replacement), true);
        assertEq(pol.stableList(15), address(replacement));
    }

    function test_P1_stableAboveDustStillBlocked() public {
        MockERC20 t = new MockERC20("S", "S", 6);
        assetOracle.setPrice(address(t), 1e20);
        pol.setStable(address(t), true);
        MockERC20(address(t)).mint(address(pol), 1e6 + 1);
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.setStable(address(t), false);
    }

    function test_P1_unpriceableDustStillRequiresZeroBalance() public {
        MockERC20 t = new MockERC20("S", "S", 6);
        assetOracle.setPrice(address(t), 1e20);
        pol.setStable(address(t), true);
        MockERC20(address(t)).mint(address(pol), 1);
        assetOracle.setStale(address(t), true);
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.setStable(address(t), false);
        assetOracle.setStale(address(t), false);
        assetOracle.setPrice(address(t), 0);
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.setStable(address(t), false);
    }

    function test_P1_retiredAssetWithDustCanBeRemoved_capacityFreed() public {
        address retired;
        for (uint256 i; i < 32; ++i) {
            MockERC20 t = new MockERC20("A", "A", 18);
            if (i == 0) retired = address(t);
            assetOracle.setPrice(address(t), 3000e8);
            pol.setAllowedAsset(address(t), true);
            pol.setAssetEntry(address(t), 0, 0, POLHolder.RewardMode.OUTRIGHT);
        }
        MockERC20(retired).mint(address(pol), 1);
        pol.removeAsset(retired);
        (,,,, bool exists) = pol.asset(retired);
        assertFalse(exists);

        MockERC20 next = new MockERC20("N", "N", 18);
        pol.setAllowedAsset(address(next), true);
        pol.setAssetEntry(address(next), 0, 0, POLHolder.RewardMode.OUTRIGHT);
        assertEq(pol.portfolio(31), address(next));
    }

    function test_P1_retiredAssetAboveDustStillBlocked() public {
        pol.setAllowedAsset(address(wsteth), true);
        pol.setAssetEntry(address(wsteth), 0, 0, POLHolder.RewardMode.OUTRIGHT);
        wsteth.mint(address(pol), 0.001 ether);
        vm.expectRevert(POLHolder.NonZeroBalance.selector);
        pol.removeAsset(address(wsteth));
    }

    function _rewardSale(MockERC20 r, uint256 amountIn, uint256 albOut)
        internal
        view
        returns (POLHolder.Action memory)
    {
        return POLHolder.Action({
            target: address(router),
            data: abi.encodeCall(MockRouter.swap, (address(r), amountIn, address(alb), albOut)),
            approveToken: address(r),
            approveSpender: address(router),
            approveAmount: amountIn
        });
    }

    function _harvestFixture() internal returns (MockERC20 r) {
        vm.warp(T0);
        twap.touch();
        r = new MockERC20("R", "R", 18);
        assetOracle.setPrice(address(r), 1e8);
        pol.setRewardToken(address(r), true);
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        vm.prank(DAO);
        alb.addMinter(address(router));
        LoC line = _createLoC(address(pol), 1000 ether, 1000 ether, 1000 ether, 0);
        pol.setLoC(ILoC(address(line)));
        r.mint(address(pol), 3 ether);
    }

    function test_G2_everyOutflowOfACachedRewardIsValued() public {
        MockERC20 r = _harvestFixture();
        POLHolder.Action[] memory acts = new POLHolder.Action[](3);
        for (uint256 i; i < 3; ++i) acts[i] = _rewardSale(r, 1 ether, 1 ether);

        acts[2] = _rewardSale(r, 1 ether, 0);
        POLHolder.Action[] memory none = new POLHolder.Action[](0);
        vm.prank(KEEPER);
        vm.expectRevert(POLHolder.ToleranceBreach.selector);
        pol.maintain(acts, none);
        vm.warp(T0);
        assertEq(vm.getBlockTimestamp(), T0);

        acts[2] = _rewardSale(r, 1 ether, 1 ether);
        vm.prank(KEEPER);
        pol.maintain(acts, none);
        assertEq(r.balanceOf(address(pol)), 0);
    }
}

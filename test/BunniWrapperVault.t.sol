// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./Mocks.sol";
import {
    BunniWrapperVault,
    IBunniToken,
    IBunniGauge,
    IBunniValuator,
    IGaugeMinter
} from "../src/wrappers/BunniWrapperVault.sol";

contract WrapperGaugeMock {
    MockERC20 internal immutable lp;
    address[] internal rewards;

    constructor(MockERC20 token) {
        lp = token;
    }

    function addReward(address token) external {
        rewards.push(token);
    }

    function reward_tokens(uint256 index) external view returns (address) {
        return index < rewards.length ? rewards[index] : address(0);
    }

    function deposit(uint256 amount) external {
        lp.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        lp.transfer(msg.sender, amount);
    }

    function claim_rewards(address) external {}
}

contract WrapperValuatorMock {
    function pricePerShare(address) external pure returns (uint256) {
        return 1e8;
    }
}

contract WrapperMinterMock {
    bool internal failing;

    function setFailing() external {
        failing = true;
    }

    function mint(address) external view {
        require(!failing);
    }
}

abstract contract WrapperGasBase is Test {
    MockERC20 internal lp;
    MockERC20 internal primary;
    WrapperGaugeMock internal gauge;
    WrapperMinterMock internal minter;
    BunniWrapperVault internal vault;
    address[] internal expected;

    function rewardCount() internal pure virtual returns (uint256);

    function includePrimary() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        lp = new MockERC20("LP", "LP", 18);
        gauge = new WrapperGaugeMock(lp);
        minter = new WrapperMinterMock();
        primary = new MockERC20("Primary", "P", 18);
        vault = new BunniWrapperVault(
            address(this),
            "Wrapped",
            "W",
            IBunniToken(address(lp)),
            IBunniGauge(address(gauge)),
            IBunniValuator(address(new WrapperValuatorMock()))
        );
        vault.setDepositor(address(this));
        for (uint256 i; i < rewardCount(); ++i) {
            MockERC20 token = new MockERC20("Reward", "R", 18);
            gauge.addReward(address(token));
            token.mint(address(vault), 1 ether);
            expected.push(address(token));
        }
        if (includePrimary()) {
            vault.setGaugeMinter(IGaugeMinter(address(minter)), address(primary));
            primary.mint(address(vault), 2 ether);
            expected.push(address(primary));
        }
    }

    function testGas_Harvest() public {
        uint256 beforeGas = gasleft();
        (address[] memory tokens, uint256[] memory amounts) = vault.harvest("");
        emit log_named_uint("harvest", beforeGas - gasleft());
        assertEq(tokens, expected);
        assertEq(amounts.length, expected.length);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = tokens[i] == address(primary) ? 2 ether : 1 ether;
            assertEq(amounts[i], amount);
            assertEq(MockERC20(tokens[i]).balanceOf(address(this)), amount);
            assertEq(MockERC20(tokens[i]).balanceOf(address(vault)), 0);
        }
    }
}

contract WrapperNoRewardsTest is WrapperGasBase {
    function rewardCount() internal pure override returns (uint256) {
        return 0;
    }

    function testFuzz_DepositWithdrawPreservesBacking(uint96 amount, uint96 donation) public {
        lp.mint(address(this), amount);
        lp.mint(address(vault), donation);
        lp.approve(address(vault), amount);
        assertEq(vault.deposit(abi.encode(amount)), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(lp.balanceOf(address(gauge)), amount);
        assertEq(lp.allowance(address(vault), address(gauge)), 0);
        assertEq(vault.withdraw(amount, ""), amount);
        assertEq(vault.totalSupply(), 0);
        assertEq(lp.balanceOf(address(this)), amount);
        assertEq(lp.balanceOf(address(vault)), donation);
    }

    function testFuzz_ConstructorRejectsMissingDependency(uint8 missing) public {
        missing %= 4;
        IBunniValuator valuator = vault.valuator();
        vm.expectRevert(BunniWrapperVault.ZeroAddress.selector);
        new BunniWrapperVault(
            missing == 0 ? address(0) : address(this),
            "W",
            "W",
            IBunniToken(missing == 1 ? address(0) : address(lp)),
            IBunniGauge(missing == 2 ? address(0) : address(gauge)),
            IBunniValuator(missing == 3 ? address(0) : address(valuator))
        );
    }

    function test_NonDepositorCannotUseVault() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(BunniWrapperVault.NotDepositor.selector);
        vault.deposit(abi.encode(1));
        vm.expectRevert(BunniWrapperVault.NotDepositor.selector);
        vault.withdraw(1, "");
        vm.expectRevert(BunniWrapperVault.NotDepositor.selector);
        vault.harvest("");
        vm.stopPrank();
    }

    function test_PrimaryListedTwiceStillPaidOnce() public {
        gauge.addReward(address(primary));
        gauge.addReward(address(primary));
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(primary));
        primary.mint(address(vault), 7 ether);
        (address[] memory tokens, uint256[] memory amounts) = vault.harvest("");
        assertEq(tokens.length, 1);
        assertEq(amounts.length, 1);
        assertEq(tokens[0], address(primary));
        assertEq(amounts[0], 7 ether);
        assertEq(primary.balanceOf(address(this)), 7 ether);
    }

    function test_FailedMinterStillForwardsExistingRewards() public {
        vault.setGaugeMinter(IGaugeMinter(address(minter)), address(primary));
        primary.mint(address(vault), 3 ether);
        minter.setFailing();
        (address[] memory tokens, uint256[] memory amounts) = vault.harvest("");
        assertEq(tokens.length, 1);
        assertEq(amounts[0], 3 ether);
        assertEq(primary.balanceOf(address(this)), 3 ether);
    }
}

contract WrapperOneRewardTest is WrapperGasBase {
    function rewardCount() internal pure override returns (uint256) {
        return 1;
    }
}

contract WrapperAllRewardsTest is WrapperGasBase {
    function rewardCount() internal pure override returns (uint256) {
        return 8;
    }

    function includePrimary() internal pure override returns (bool) {
        return true;
    }
}

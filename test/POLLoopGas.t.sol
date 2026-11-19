// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

abstract contract POLLoopGasBase is BaseTest {
    address[] internal tokens;
    POLHolder.Action[] internal empty;

    function portfolioSize() internal pure virtual returns (uint256);

    function rewardSize() internal pure virtual returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        pol.setLoC(ILoC(address(_createLoC(address(pol), 1_000_000 ether, 0, 0, 0))));
        ActionPermissionSetup.allowRouter(address(pol), address(router));
        vm.prank(DAO);
        alb.addMinter(address(router));
        _warmOracle();
        uint256 n = portfolioSize();
        for (uint256 i; i < n; ++i) {
            MockERC20 token = new MockERC20("Asset", "A", 18);
            tokens.push(address(token));
            pol.setAllowedAsset(address(token), true);
            uint16 weight = uint16(i + 1 == n ? 10_000 - (10_000 / n) * i : 10_000 / n);
            pol.setAssetEntry(address(token), weight, 100, POLHolder.RewardMode.COMPOUNDING);
            token.mint(address(pol), 1_000 ether);
            assetOracle.setPrice(address(token), 1e8);
        }
        for (uint256 i; i < n / 2; ++i) {
            MockERC20 token = new MockERC20("Stable", "S", 18);
            pol.setStable(address(token), true);
            token.mint(address(pol), 1_000 ether);
            assetOracle.setPrice(address(token), 1e8);
        }
        for (uint256 i; i < rewardSize(); ++i) {
            MockERC20 token = new MockERC20("Reward", "R", 18);
            assetOracle.setPrice(address(token), 1e8);
            pol.setRewardToken(address(token), true);
            token.mint(address(pol), 1_000 ether);
        }
        vm.prank(KEEPER);
        pol.maintain(empty, empty);
        for (uint256 i; i < n; ++i) {
            assetOracle.setPrice(tokens[i], 2e8);
        }
    }

    function testGas_NoActions() public {
        vm.prank(KEEPER);
        uint256 beforeGas = gasleft();
        pol.maintain(empty, empty);
        emit log_named_uint("maintain no actions", beforeGas - gasleft());
    }

    function testGas_Harvest() public {
        uint256 n = tokens.length;
        POLHolder.Action[] memory actions = new POLHolder.Action[](n);
        for (uint256 i; i < n; ++i) {
            actions[i] = POLHolder.Action({
                target: address(router),
                data: abi.encodeCall(MockRouter.swap, (tokens[i], 500 ether, address(alb), 1_000 ether)),
                approveToken: tokens[i],
                approveSpender: address(router),
                approveAmount: 500 ether
            });
        }
        vm.prank(KEEPER);
        uint256 beforeGas = gasleft();
        pol.maintain(actions, empty);
        emit log_named_uint("maintain harvest", beforeGas - gasleft());
        for (uint256 i; i < n; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(pol)), 500 ether);
            (,,, uint128 basis,) = pol.asset(tokens[i]);
            assertEq(basis, 2e8);
        }
        assertEq(alb.balanceOf(address(pol)), 0);
    }
}

contract POLLoopGas2Test is POLLoopGasBase {
    function portfolioSize() internal pure override returns (uint256) {
        return 2;
    }
}

contract POLLoopGas8Test is POLLoopGasBase {
    function portfolioSize() internal pure override returns (uint256) {
        return 8;
    }
}

contract POLLoopGas32Test is POLLoopGasBase {
    function portfolioSize() internal pure override returns (uint256) {
        return 32;
    }
}

contract POLLoopGas2Rewards16Test is POLLoopGasBase {
    function portfolioSize() internal pure override returns (uint256) {
        return 2;
    }

    function rewardSize() internal pure override returns (uint256) {
        return 16;
    }
}

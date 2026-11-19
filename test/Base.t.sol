// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {EsALB} from "../src/token/EsALB.sol";
import {GovALB} from "../src/token/GovALB.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {LoCFactory} from "../src/loc/LoCFactory.sol";
import {LoC} from "../src/loc/LoC.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {MigrationContract, ILegacyALB, ILegacyEsALB, IEsALB} from "../src/migration/MigrationContract.sol";
import {AlbPriceOracle, ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IEscrowedToken} from "../src/interfaces/IEscrowedToken.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IAlbPriceOracle} from "../src/interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";
import {ILoCFactoryRebase} from "../src/staking/StakingContract.sol";
import {
    MockERC20, MockLegacyEsALB, MockTwapSource, MockAssetOracle, MockWETH, MockRouter
} from "./Mocks.sol";

abstract contract BaseTest is Test {
    address internal DAO = makeAddr("dao");
    address internal RECOVERY = makeAddr("recovery");
    address internal POL_ADMIN = makeAddr("polAdmin");
    address internal KEEPER = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    ALBToken internal alb;
    EsALB internal esALB;
    GovALB internal govALB;
    StakingContract internal staking;
    LoCFactory internal factory;
    POLHolder internal pol;
    MigrationContract internal migration;
    AlbPriceOracle internal oracle;

    MockERC20 internal legacyALB;
    MockLegacyEsALB internal legacyEsALB;
    MockTwapSource internal twap;
    MockAssetOracle internal assetOracle;
    MockWETH internal weth;
    MockRouter internal router;

    MockERC20 internal usdc;
    MockERC20 internal wsteth;

    uint8 internal constant ORACLE_DEC = 8;

    function setUp() public virtual {
        vm.warp(365 days * 55);

        legacyALB = new MockERC20("Legacy ALB", "ALB-old", 18);
        legacyEsALB = new MockLegacyEsALB(legacyALB);
        twap = new MockTwapSource(1e8, ORACLE_DEC);
        assetOracle = new MockAssetOracle(ORACLE_DEC);
        weth = new MockWETH();
        router = new MockRouter();

        alb = new ALBToken(DAO, RECOVERY);
        oracle = new AlbPriceOracle(DAO, ITwapSource(address(twap)));

        esALB = new EsALB(address(this), IALB(address(alb)));
        govALB = new GovALB(address(this), IALB(address(alb)), 0);
        staking = new StakingContract(
            address(this), IALB(address(alb)), address(esALB), address(govALB), address(weth)
        );
        esALB.setStaking(IStakingContract(address(staking)));
        govALB.setStaking(IStakingContract(address(staking)));

        factory = new LoCFactory(
            address(this),
            IALB(address(alb)),
            IEscrowedToken(address(esALB)),
            IEscrowedToken(address(govALB)),
            address(oracle)
        );
        factory.setStakingContract(address(staking));
        staking.setLoCFactory(ILoCFactoryRebase(address(factory)));
        staking.setNotifier(KEEPER, true);
        staking.setNotifier(address(this), true);

        migration = new MigrationContract(
            ILegacyALB(address(legacyALB)),
            ILegacyEsALB(address(legacyEsALB)),
            IALB(address(alb)),
            IEsALB(address(esALB))
        );

        pol = new POLHolder(
            address(this),
            IALB(address(alb)),
            IAlbPriceOracle(address(oracle)),
            IAssetOracle(address(assetOracle))
        );
        pol.grantRoles(POL_ADMIN, pol.ROLE_ADMIN());
        pol.grantRoles(KEEPER, pol.ROLE_OPERATOR());

        vm.startPrank(DAO);
        alb.addMinter(address(factory));
        alb.addMinter(address(migration));
        vm.stopPrank();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        assetOracle.setPrice(address(usdc), 1e8 * 1e12);
        assetOracle.setPrice(address(wsteth), 3000e8);
    }

    // vm.getBlockTimestamp() avoids via-IR caching block.timestamp across warps.
    function _skip(uint256 d) internal {
        vm.warp(vm.getBlockTimestamp() + d);
    }

    function _warmOracle() internal {
        uint256 t = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            t += 1 days;
            vm.warp(t);
            twap.touch();
            oracle.poke();
        }
    }

    function _mintALB(address to, uint256 amount) internal {
        vm.prank(DAO);
        alb.addMinter(address(this));
        alb.mint(to, amount);
        vm.prank(DAO);
        alb.revokeMinter(address(this));
    }

    function _stakeEs(address user, uint256 amount) internal {
        _mintALB(user, amount);
        vm.startPrank(user);
        alb.approve(address(esALB), amount);
        esALB.depositFor(user, amount);
        vm.stopPrank();
    }

    function _stakeGov(address user, uint256 amount) internal {
        _mintALB(user, amount);
        vm.startPrank(user);
        alb.approve(address(govALB), amount);
        govALB.depositFor(user, amount);
        vm.stopPrank();
    }

    function _createLoC(
        address beneficiary,
        uint256 maxTotal,
        uint128 maxDaily,
        uint128 maxWeekly,
        uint64 rateBps
    ) internal returns (LoC loc) {
        LoC.Option[] memory none = new LoC.Option[](0);
        return LoC(
            factory.createLoC(beneficiary, address(staking), maxTotal, maxDaily, maxWeekly, rateBps, none)
        );
    }
}

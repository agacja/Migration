// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ALBToken} from "../src/token/ALBToken.sol";
import {EsALB} from "../src/token/EsALB.sol";
import {GovALB} from "../src/token/GovALB.sol";
import {StakingContract} from "../src/staking/StakingContract.sol";
import {LoCFactory} from "../src/loc/LoCFactory.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {Distributor} from "../src/farm/Distributor.sol";
import {
    MigrationContract,
    ILegacyALB,
    ILegacyEsALB,
    IEsALB
} from "../src/migration/MigrationContract.sol";
import {AlbPriceOracle, ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {UniV3TwapOracle} from "../src/oracle/UniV3TwapOracle.sol";
import {AlbTwapSource} from "../src/oracle/AlbTwapSource.sol";
import {IALB} from "../src/interfaces/IALB.sol";
import {IEscrowedToken} from "../src/interfaces/IEscrowedToken.sol";
import {IStakingContract} from "../src/interfaces/IStakingContract.sol";
import {IAlbPriceOracle} from "../src/interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";

/// @notice Deploy migration contracts and transfer ownership to the timelock.
contract DeployScript is Script {
    struct Config {
        address timelock;
        address recoveryAdmin;
        address polAdmin;
        address feeRecipient;
        address keeper;
        address weth;
        address usdc;
        address[] v3Factories;
        address legacyALB;
        address legacyEsALB;
    }

    struct Deployment {
        ALBToken alb;
        UniV3TwapOracle twapEngine;
        AlbTwapSource albTwapSource;
        AlbPriceOracle oracle;
        EsALB esALB;
        GovALB govALB;
        StakingContract staking;
        LoCFactory factory;
        MigrationContract migration;
        POLHolder pol;
        Distributor farm;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = _configFromEnv();

        address deployer = msg.sender;
        vm.startBroadcast();
        d = deploy(c, deployer);
        vm.stopBroadcast();
        _log(d);
    }

    function deploy(Config memory c, address deployer) public returns (Deployment memory d) {
        d.alb = new ALBToken(c.timelock, c.recoveryAdmin);

        d.twapEngine = new UniV3TwapOracle(deployer, c.usdc, c.weth, c.v3Factories);
        d.twapEngine.grantRoles(c.polAdmin, d.twapEngine.ROLE_ADMIN());
        d.albTwapSource = new AlbTwapSource(d.twapEngine, address(d.alb));
        d.oracle = new AlbPriceOracle(c.timelock, ITwapSource(address(d.albTwapSource)));

        d.esALB = new EsALB(deployer, IALB(address(d.alb)));
        d.govALB = new GovALB(deployer, IALB(address(d.alb)), uint128(vm.envOr("GOVALB_SUPPLY_CAP", uint256(0))));
        d.staking = new StakingContract(
            deployer, IALB(address(d.alb)), address(d.esALB), address(d.govALB), c.weth
        );
        d.esALB.setStaking(IStakingContract(address(d.staking)));
        d.govALB.setStaking(IStakingContract(address(d.staking)));

        d.esALB.grantRoles(c.polAdmin, d.esALB.ROLE_ADMIN());
        d.govALB.grantRoles(c.polAdmin, d.govALB.ROLE_ADMIN());
        d.staking.grantRoles(c.polAdmin, d.staking.ROLE_ADMIN());

        d.factory = new LoCFactory(
            deployer,
            IALB(address(d.alb)),
            IEscrowedToken(address(d.esALB)),
            IEscrowedToken(address(d.govALB)),
            address(d.oracle)
        );
        d.factory.setStakingContract(address(d.staking));
        d.factory.grantRoles(c.polAdmin, d.factory.ROLE_ADMIN());

        d.migration = new MigrationContract(
            ILegacyALB(c.legacyALB),
            ILegacyEsALB(c.legacyEsALB),
            IALB(address(d.alb)),
            IEsALB(address(d.esALB))
        );

        d.pol = new POLHolder(
            deployer,
            IALB(address(d.alb)),
            IAlbPriceOracle(address(d.oracle)),
            IAssetOracle(address(d.twapEngine))
        );
        d.pol.grantRoles(c.polAdmin, d.pol.ROLE_ADMIN());
        d.pol.grantRoles(c.keeper, d.pol.ROLE_OPERATOR());

        d.farm = new Distributor(deployer, c.feeRecipient);
        d.farm.grantRoles(c.polAdmin, d.farm.ROLE_ADMIN());

        d.twapEngine.transferOwnership(c.timelock);
        d.esALB.transferOwnership(c.timelock);
        d.govALB.transferOwnership(c.timelock);
        d.staking.transferOwnership(c.timelock);
        d.factory.transferOwnership(c.timelock);
        d.pol.transferOwnership(c.timelock);
        d.farm.transferOwnership(c.timelock);

        // Timelock must configure minters, rebase/notifier wiring, the LoC and POL.
        // Pin oracle routes and whitelist the bridge on legacy esALB.
        // Keep legacy redemption settings unchanged.
    }

    function _configFromEnv() internal view returns (Config memory c) {
        c.timelock = vm.envAddress("TIMELOCK");
        c.recoveryAdmin = vm.envAddress("RECOVERY_ADMIN");
        c.polAdmin = vm.envAddress("POL_ADMIN");
        c.keeper = vm.envAddress("KEEPER");
        c.feeRecipient = vm.envOr("FEE_RECIPIENT", c.timelock);
        c.weth = vm.envOr("WETH", address(0x4200000000000000000000000000000000000006));
        c.usdc = vm.envOr("USDC", address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
        c.v3Factories = vm.envAddress("V3_FACTORIES", ",");
        c.legacyALB = vm.envAddress("LEGACY_ALB");
        c.legacyEsALB = vm.envAddress("LEGACY_ESALB");
    }

    function _log(Deployment memory d) internal pure {
        console2.log("ALBToken           ", address(d.alb));
        console2.log("UniV3TwapOracle  ", address(d.twapEngine));
        console2.log("AlbTwapSource    ", address(d.albTwapSource));
        console2.log("AlbPriceOracle   ", address(d.oracle));
        console2.log("EsALB         ", address(d.esALB));
        console2.log("GovALB           ", address(d.govALB));
        console2.log("StakingContract  ", address(d.staking));
        console2.log("LoCFactory       ", address(d.factory));
        console2.log("MigrationContract", address(d.migration));
        console2.log("POLHolder        ", address(d.pol));
    }
}

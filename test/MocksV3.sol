// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "v3-core/libraries/TickMath.sol";

contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public twapTick;
    int24 public spotTick;
    uint128 public liquidity;
    uint16 public cardinality;

    uint32 internal _frozenObsTs;

    constructor(address tokenA, address tokenB, int24 tick_, uint128 liquidity_, uint16 cardinality_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        twapTick = tick_;
        spotTick = tick_;
        liquidity = liquidity_;
        cardinality = cardinality_;
    }

    function freezeObservations() external { _frozenObsTs = uint32(block.timestamp); }

    function touchObservation() external { _frozenObsTs = 0; }

    function lastObservationTs() public view returns (uint32) {
        return _frozenObsTs == 0 ? uint32(block.timestamp) : _frozenObsTs;
    }

    function observations(uint256)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized)
    {
        uint32 ts = lastObservationTs();
        return (ts, int56(int256(uint256(ts)) * int256(twapTick)), 0, true);
    }

    function setTicks(int24 twap_, int24 spot_) external {
        twapTick = twap_;
        spotTick = spot_;
    }

    function setLiquidity(uint128 l) external { liquidity = l; }
    function setCardinality(uint16 c) external { cardinality = c; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(spotTick), spotTick, 0, cardinality, cardinality, 0, true);
    }

    uint128 public twaLiquidityOverride;

    function setTwaLiquidity(uint128 l) external { twaLiquidityOverride = l; }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityX128)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityX128 = new uint160[](secondsAgos.length);

        uint256 effLiq = twaLiquidityOverride != 0 ? twaLiquidityOverride : liquidity;
        if (effLiq == 0) effLiq = 1;
        uint256 instLiq = liquidity == 0 ? 1 : liquidity;
        uint256 lastObs = uint256(lastObservationTs());

        for (uint256 i; i < secondsAgos.length; ++i) {
            uint256 t = block.timestamp - secondsAgos[i];
            if (t <= lastObs) {
                tickCumulatives[i] = int56(int256(t) * int256(twapTick));
                secondsPerLiquidityX128[i] = uint160((t << 128) / effLiq);
            } else {
                uint256 dt = t - lastObs;
                tickCumulatives[i] =
                    int56(int256(lastObs) * int256(twapTick) + int256(dt) * int256(spotTick));
                secondsPerLiquidityX128[i] =
                    uint160((lastObs << 128) / effLiq + ((dt << 128) / instLiq));
            }
        }
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) internal _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[keccak256(abi.encodePacked(t0, t1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[keccak256(abi.encodePacked(t0, t1, fee))];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Key hash: keccak256(abi.encode(pool, tickLower, tickUpper)).
struct BunniKey {
    IUniswapV3PoolLite pool;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Subset of the Uniswap V3 pool surface the fee distributor reads.
interface IUniswapV3PoolLite {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

/// @notice BunniHubA methods; the fee distributor must own the hub.
interface IBunniHub {
    /// @notice Collect fees, retain protocolFee in the hub and compound the remainder.
    function compoundSkim(BunniKey calldata key)
        external
        returns (uint128 addedLiquidity, uint256 amount0, uint256 amount1);
    /// @notice Transfers the hub's entire balance of each token to `recipient`.
    function sweepTokens(address[] calldata tokenList, address recipient) external;
    /// @notice WAD-scaled share of collected fees the hub retains (1e18 = keep everything).
    function setProtocolFee(uint256 value) external;
    function protocolFee() external view returns (uint256);
    function transferOwnership(address newOwner) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice USD price per 1e18 asset base units, scaled by decimals().
/// @dev Value = amount * priceOf(asset) / 1e18, regardless of token decimals.
interface IAssetOracle {
    function priceOf(address asset) external view returns (uint256);
    /// @notice Returns price and availability in one call.
    function tryPriceOf(address asset) external view returns (uint256 price, bool ok);
    function decimals() external view returns (uint8);
    function isStale(address asset) external view returns (bool);
}

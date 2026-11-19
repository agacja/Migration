// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAlbPriceOracle {
    /// @notice Unvalidated ALB/USD quote in oracle decimals.
    function spotPrice() external view returns (uint256);

    /// @notice ALB/USD quote with freshness and price checks; reverts on invalid data.
    function safeSpotPrice() external view returns (uint256);

    /// @notice 20-day SMA of ALB price in USD (oracle decimals). Reverts if not yet warm.
    function sma20() external view returns (uint256);

    /// @notice True when the 20-sample history and underlying TWAP are fresh.
    function isHealthy() external view returns (bool);

    /// @notice Clock excluding time while the daily SMA history is stale or rebuilding.
    function optionClock() external view returns (uint256);

    /// @notice Price decimals (fixed at deployment; the TWAP source must match).
    function decimals() external view returns (uint8);

    /// @notice Best-effort daily snapshot. May no-op if a sample for today already exists.
    /// @return updated true if a new sample was written
    function poke() external returns (bool updated);
}

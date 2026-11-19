// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ERC20 and oracle adapter for wrapped yield positions.
interface IWrapperVault {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Descriptive: the underlying logical asset (e.g. the Bunni LP token).
    function underlying() external view returns (address);

    /// @notice Pull a position from msg.sender and mint shares.
    function deposit(bytes calldata data) external returns (uint256 shares);

    /// @notice Burn shares and return the underlying position to msg.sender.
    function withdraw(uint256 shares, bytes calldata data) external returns (uint256);

    /// @notice Claim accrued rewards. Returns reward tokens and amounts forwarded in this call.
    function harvest(bytes calldata data) external returns (address[] memory rewardTokens, uint256[] memory amounts);

    /// @notice Price of one share in the wrapper's numéraire (oracle decimals).
    function pricePerShare() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IEscrowedToken {
    function staking() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    /// @notice Liquid balance plus shares from active unstaking positions.
    function stakedSharesOf(address account) external view returns (uint256);
    /// @notice Whether balance changes bypass staking hooks.
    function isHookExempt(address account) external view returns (bool);
}

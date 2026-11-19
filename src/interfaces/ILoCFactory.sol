// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILoCFactory {
    /// @notice Mint a LoC draw or interest and queue the corresponding staking rebase.
    function mintWithRebase(address to, uint256 amount) external;

    /// @notice Mint option proceeds without a staking rebase.
    function mintNoRebase(address to, uint256 amount) external;

    /// @notice Called by the StakingContract to pull accrued rebase ALB.
    function pullRebase() external returns (uint256 amount);

    function stakingContract() external view returns (address);

    /// @notice Whether the caller is a LoC deployed by this factory.
    function isLoC(address candidate) external view returns (bool);
}

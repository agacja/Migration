// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IStakingContract {
    /// @notice Called by an escrow before replacing this staking instance. Membership freezes.
    function deprecate() external;
    /// @notice Called by a migrating escrow to pause emission until the owner finishes bootstrap.
    function beginMigration() external;
    function notifyDeposit(address user, uint256 amount) external;
    function notifyWithdraw(address user, uint256 amount) external;
    function notifyReward(address token, uint256 amount) external;
    /// @notice Book untracked rewards. Notifier-only.
    function sync(address token) external;
    function shareOf(address user) external view returns (uint256);
    function totalShares() external view returns (uint256);
}

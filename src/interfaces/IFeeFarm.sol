// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Pulls reward tokens from the authorized notifier and books the amount received.
interface IFeeFarm {
    function notifyReward(address token, uint256 amount) external;
}

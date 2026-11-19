// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILoC {
    function pokeInterest() external;
    function draw(uint256 amount, address to) external;
    function repay(uint256 amount) external;
    function drawnAmount() external view returns (uint256);
}

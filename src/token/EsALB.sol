// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowedToken} from "./EscrowedToken.sol";
import {IALB} from "../interfaces/IALB.sol";

/// @notice Escrowed ALB with a 30–60 day exit period.
contract EsALB is EscrowedToken {
    constructor(address owner_, IALB underlying_)
        EscrowedToken(
            owner_,
            underlying_,
            30 days,
            60 days,
            8500,
            7000,
            20_000,             // 2% per epoch (PPM: 20_000 / 1_000_000)
            48 hours
        )
    {}

    function name() public pure override returns (string memory) {
        return "Escrowed Alien Base Token";
    }

    function symbol() public pure override returns (string memory) {
        return "esALB";
    }

    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256(bytes("Escrowed Alien Base Token"));
    }

    /// @notice Pull ALB and mint esALB 1:1 to the recipient.
    function depositFor(address to, uint256 amount) external {
        _depositFor(to, amount);
    }
}

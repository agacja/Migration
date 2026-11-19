// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowedToken} from "./EscrowedToken.sol";
import {IALB} from "../interfaces/IALB.sol";

contract GovALB is EscrowedToken {
    /// @param initialCap Supply cap; zero means uncapped.
    constructor(address owner_, IALB underlying_, uint128 initialCap)
        EscrowedToken(
            owner_,
            underlying_,
            2 * 365 days,
            2 * 365 days,
            10000,
            0,

            14_360,
            7 days
        )
    {
        supplyCap = initialCap;
        if (initialCap != 0) emit SupplyCapSet(initialCap);
    }

    function name() public pure override returns (string memory) {
        return "Governance Alien Base Token";
    }

    function symbol() public pure override returns (string memory) {
        return "govALB";
    }

    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256(bytes("Governance Alien Base Token"));
    }

    function depositFor(address to, uint256 amount) external {
        _depositFor(to, amount);
    }
}

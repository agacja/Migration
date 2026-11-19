// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IALB} from "../interfaces/IALB.sol";

/// @notice Legacy esALB is transferred into permanent custody without redemption.
interface ILegacyEsALB {
    function balanceOf(address user) external view returns (uint256);
}

interface ILegacyALB {
    function balanceOf(address user) external view returns (uint256);
}

interface IEsALB {
    function depositFor(address to, uint256 amount) external;
}

contract MigrationContract is ReentrancyGuardTransient {
    ILegacyALB     public immutable legacyALB;
    ILegacyEsALB   public immutable legacyEsALB;
    IALB        public immutable newALB;
    IEsALB      public immutable newEsALB;

    uint256 public totalLegacyALBLocked;
    uint256 public totalLegacyEsALBLocked;

    error ZeroAmount();

    event MigratedALB(address indexed user, uint256 amount);
    event MigratedEsALB(address indexed user, uint256 amount);

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    constructor(
        ILegacyALB legacyALB_,
        ILegacyEsALB legacyEsALB_,
        IALB newALB_,
        IEsALB newEsALB_
    ) {
        legacyALB = legacyALB_;
        legacyEsALB = legacyEsALB_;
        newALB = newALB_;
        newEsALB = newEsALB_;
    }

    /// @notice Migrate legacy ALB 1:1; the legacy tokens remain locked here.
    function migrateALB(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(address(legacyALB), msg.sender, address(this), amount);
        unchecked {
            totalLegacyALBLocked += amount;
        }
        newALB.mint(msg.sender, amount);
        emit MigratedALB(msg.sender, amount);
    }

    /// @notice Lock legacy esALB and mint fully backed newEsALB 1:1 to the user.
    function migrateEsALB(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address _self = address(this);

        SafeTransferLib.safeTransferFrom(address(legacyEsALB), msg.sender, _self, amount);
        unchecked {
            totalLegacyEsALBLocked += amount;
        }

        IALB _newALB = newALB;
        address _newEsAddr = address(newEsALB);
        _newALB.mint(_self, amount);
        SafeTransferLib.safeApprove(address(_newALB), _newEsAddr, amount);
        newEsALB.depositFor(msg.sender, amount);
        SafeTransferLib.safeApprove(address(_newALB), _newEsAddr, 0);

        emit MigratedEsALB(msg.sender, amount);
    }
}

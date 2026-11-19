// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library ActionPermissions {
    struct Permission {
        bytes32 codeHash;
        bytes32 spenderCodeHash;
        address spender;
        uint48 targetEpoch;
        uint48 spenderEpoch;
    }

    struct Store {
        mapping(address => uint48) epochs;
        mapping(address => mapping(bytes4 => Permission)) permissions;
    }

    event ActionPermissionSet(address indexed target, bytes4 indexed selector, address spender, bool allowed);

    error InvalidActionData();
    error ActionNotAllowed();
    error InvalidActionTarget();
    error ActionCodeChanged();
    error InvalidApproval();

    function invalidate(Store storage self, address target) internal {
        ++self.epochs[target];
    }

    function set(Store storage self, address target, bytes4 selector, address spender, bool allowed) public {
        if (allowed) {
            if (target.code.length == 0 || (spender != address(0) && spender.code.length == 0)) {
                revert InvalidActionTarget();
            }
            self.permissions[target][selector] = Permission({
                codeHash: target.codehash,
                spenderCodeHash: spender == address(0) ? bytes32(0) : spender.codehash,
                spender: spender,
                targetEpoch: self.epochs[target],
                spenderEpoch: self.epochs[spender]
            });
        } else {
            delete self.permissions[target][selector];
        }
        emit ActionPermissionSet(target, selector, spender, allowed);
    }

    function check(
        Store storage self,
        address target,
        bytes calldata data,
        address token,
        address spender,
        uint256 amount
    ) public view {
        if (data.length < 4) revert InvalidActionData();
        Permission storage p = self.permissions[target][bytes4(data[:4])];
        if (p.codeHash == bytes32(0) || p.targetEpoch != self.epochs[target]) revert ActionNotAllowed();
        if (p.codeHash != target.codehash) revert ActionCodeChanged();
        if (token == address(0)) {
            if (spender != address(0) || amount != 0) revert InvalidApproval();
        } else {
            if (spender == address(0) || spender != p.spender || p.spenderEpoch != self.epochs[spender]) {
                revert InvalidApproval();
            }
            if (p.spenderCodeHash != spender.codehash) revert ActionCodeChanged();
        }
    }
}

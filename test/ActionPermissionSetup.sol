// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockRouter} from "./Mocks.sol";

interface IActionPermissionAdmin {
    function setSwapTarget(address target, bool allowed) external;
    function setActionPermission(address target, bytes4 selector, address spender, bool allowed) external;
}

library ActionPermissionSetup {
    function allowRouter(address holder, address router) internal {
        IActionPermissionAdmin admin = IActionPermissionAdmin(holder);
        admin.setSwapTarget(router, true);
        admin.setActionPermission(router, MockRouter.swap.selector, router, true);
        admin.setActionPermission(router, MockRouter.claimRewards.selector, address(0), true);
        admin.setActionPermission(router, MockRouter.steal.selector, router, true);
    }
}

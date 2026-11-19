// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BunniKey} from "../src/interfaces/IBunniHub.sol";

contract MockBunniPool {
    address public token0;
    address public token1;

    uint128 public posLiquidity;
    uint256 public fgLast0;
    uint256 public fgLast1;
    uint128 public owed0;
    uint128 public owed1;

    int24 public tick;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    mapping(int24 => uint256) public outside0;
    mapping(int24 => uint256) public outside1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setPosition(uint128 liquidity, uint256 f0, uint256 f1, uint128 o0, uint128 o1) external {
        posLiquidity = liquidity;
        fgLast0 = f0;
        fgLast1 = f1;
        owed0 = o0;
        owed1 = o1;
    }

    function addOwed(uint128 a0, uint128 a1) external {
        owed0 += a0;
        owed1 += a1;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setFeeGrowthGlobal(uint256 g0, uint256 g1) external {
        feeGrowthGlobal0X128 = g0;
        feeGrowthGlobal1X128 = g1;
    }

    function setTickOutside(int24 t, uint256 o0, uint256 o1) external {
        outside0[t] = o0;
        outside1[t] = o1;
    }

    function positions(bytes32) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (posLiquidity, fgLast0, fgLast1, owed0, owed1);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, tick, 0, 0, 0, 0, true);
    }

    function ticks(int24 t) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, 0, outside0[t], outside1[t], 0, 0, 0, true);
    }

    function burn(int24, int24, uint128) external view returns (uint256, uint256) {
        require(posLiquidity > 0, "NP");
        return (0, 0);
    }

    function collect(address recipient, int24, int24, uint128 req0, uint128 req1)
        external
        returns (uint128 a0, uint128 a1)
    {
        a0 = req0 > owed0 ? owed0 : req0;
        a1 = req1 > owed1 ? owed1 : req1;
        owed0 -= a0;
        owed1 -= a1;
        if (a0 > 0) SafeTransferLib.safeTransfer(token0, recipient, a0);
        if (a1 > 0) SafeTransferLib.safeTransfer(token1, recipient, a1);
    }
}

contract MockBunniHub {
    uint256 internal constant WAD = 1e18;

    address public owner;
    uint256 public protocolFee;
    uint16 public compoundBps = 5000;

    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function setProtocolFee(uint256 value) external onlyOwner {
        require(value <= WAD, "MAX");
        protocolFee = value;
    }

    function setCompoundBps(uint16 bps) external {
        compoundBps = bps;
    }

    function compoundSkim(BunniKey calldata key) external onlyOwner returns (uint128, uint256, uint256) {
        return _collect(key, 10_000);
    }

    function compound(BunniKey calldata key) external returns (uint128, uint256, uint256) {
        return _collect(key, compoundBps);
    }

    function _collect(BunniKey calldata key, uint16 bps) internal returns (uint128, uint256 a0, uint256 a1) {
        MockBunniPool pool = MockBunniPool(address(key.pool));
        pool.burn(key.tickLower, key.tickUpper, 0);
        (,,, uint128 o0, uint128 o1) = pool.positions(bytes32(0));

        uint128 r0 = uint128((uint256(o0) * bps) / 10_000);
        uint128 r1 = uint128((uint256(o1) * bps) / 10_000);
        (uint128 c0, uint128 c1) = pool.collect(address(this), key.tickLower, key.tickUpper, r0, r1);
        a0 = c0;
        a1 = c1;

        uint256 keep0 = (a0 * protocolFee) / WAD;
        uint256 keep1 = (a1 * protocolFee) / WAD;
        if (a0 > keep0) SafeTransferLib.safeTransfer(pool.token0(), address(pool), a0 - keep0);
        if (a1 > keep1) SafeTransferLib.safeTransfer(pool.token1(), address(pool), a1 - keep1);
        return (0, a0, a1);
    }

    function sweepTokens(address[] calldata list, address recipient) external onlyOwner {
        for (uint256 i; i < list.length; ++i) {
            SafeTransferLib.safeTransfer(list[i], recipient, SafeTransferLib.balanceOf(list[i], address(this)));
        }
    }
}

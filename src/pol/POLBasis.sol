// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {POLHolder} from "./POLHolder.sol";

library POLBasis {
    error PriceOverflow();

    function checkpoint(
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory prices,
        mapping(address => POLHolder.AssetEntry) storage assets,
        mapping(address => uint256) storage recordedBalances,
        mapping(address => uint256) storage principal
    ) external {
        _checkpoint(tokens, balances, prices, assets, recordedBalances, principal);
    }

    function prepareHarvest(
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory prices,
        uint256 portfolioLength,
        mapping(address => POLHolder.AssetEntry) storage assets,
        mapping(address => uint256) storage recordedBalances,
        mapping(address => uint256) storage principal
    ) external returns (uint256[] memory yields) {
        _checkpoint(tokens, balances, prices, assets, recordedBalances, principal);
        yields = new uint256[](portfolioLength);
        for (uint256 i; i < portfolioLength; ++i) {
            uint256 price = prices[i];
            if (price == 0) continue;
            uint256 principalShares = FixedPointMathLib.divUp(principal[tokens[i]], price);
            if (balances[i] > principalShares) yields[i] = balances[i] - principalShares;
        }
    }

    function settleHarvest(
        address[] memory tokens,
        uint256[] memory beforeBalances,
        uint256[] memory afterBalances,
        uint256[] memory prices,
        uint256[] memory yields,
        mapping(address => POLHolder.AssetEntry) storage assets,
        mapping(address => uint256) storage recordedBalances,
        mapping(address => uint256) storage principal
    ) external returns (uint256 value) {
        for (uint256 i; i < yields.length; ++i) {
            uint256 beforeBalance = beforeBalances[i];
            uint256 afterBalance = afterBalances[i];
            if (afterBalance >= beforeBalance) continue;
            uint256 sold = beforeBalance - afterBalance;
            if (sold > yields[i]) revert POLHolder.ToleranceBreach();
            value += FixedPointMathLib.fullMulDiv(sold, prices[i], 1e18);
            // Harvest removes yield; the remaining shares retain all principal.
            recordedBalances[tokens[i]] = afterBalance;
        }
        _checkpoint(tokens, afterBalances, prices, assets, recordedBalances, principal);
    }

    function _checkpoint(
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory prices,
        mapping(address => POLHolder.AssetEntry) storage assets,
        mapping(address => uint256) storage recordedBalances,
        mapping(address => uint256) storage principal
    ) private {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            POLHolder.AssetEntry storage entry = assets[token];
            if (!entry.exists || entry.rewardMode != POLHolder.RewardMode.COMPOUNDING) continue;
            uint256 balance = balances[i];
            uint256 previous = recordedBalances[token];
            uint256 cost = principal[token];
            uint256 price = prices[i];
            if (balance == 0) cost = 0;
            else if (previous == 0 || cost == 0) cost = balance * price;
            else if (balance > previous) cost = price == 0 ? 0 : cost + (balance - previous) * price;
            else if (balance < previous) cost = FixedPointMathLib.fullMulDivUp(cost, balance, previous);
            uint256 basis = balance == 0 ? 0 : FixedPointMathLib.divUp(cost, balance);
            if (basis > type(uint128).max) revert PriceOverflow();
            if (basis != entry.lastRecordedPrice) entry.lastRecordedPrice = uint128(basis);
            if (balance != previous) recordedBalances[token] = balance;
            if (cost != principal[token]) principal[token] = cost;
        }
    }
}

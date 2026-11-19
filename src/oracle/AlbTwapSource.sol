// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITwapSource} from "./AlbPriceOracle.sol";
import {UniV3TwapOracle} from "./UniV3TwapOracle.sol";

contract AlbTwapSource is ITwapSource {
    UniV3TwapOracle public immutable engine;
    address public immutable alb;
    uint8 public immutable DECIMALS;

    error ZeroAddress();

    constructor(UniV3TwapOracle engine_, address alb_) {
        if (address(engine_) == address(0) || alb_ == address(0)) revert ZeroAddress();
        engine = engine_;
        alb = alb_;
        DECIMALS = engine_.PRICE_DECIMALS();
    }

    /// @notice ALB price in USD at `DECIMALS`, per whole ALB.
    function consult() external view returns (uint256) {
        return engine.twapPrice(alb);
    }

    /// @notice Latest route observation timestamp; returns zero if the route is unreadable.
    function lastUpdate() external view returns (uint256) {
        try engine.lastObservationAt(alb) returns (uint256 ts) {
            return ts;
        } catch {
            return 0;
        }
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }
}

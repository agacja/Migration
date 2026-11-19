// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {IAlbPriceOracle} from "../interfaces/IAlbPriceOracle.sol";

/// @notice Generic source of a manipulation-resistant ALB spot price (e.g. a 1h Uniswap V3 TWAP).
interface ITwapSource {
    function consult() external view returns (uint256);
    function lastUpdate() external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract AlbPriceOracle is IAlbPriceOracle, Ownable {
    uint256 public constant SAMPLES = 20;
    uint256 public constant DAY = 1 days;
    uint256 public constant MAX_TWAP_STALENESS = 6 hours;
    uint256 public constant MAX_BUFFER_STALENESS = 2 days;

    uint256 public constant MAX_SAMPLE_DEVIATION_BPS = 1000;
    uint256 public constant MAX_FORWARD_FILL = 3;
    uint256 public constant MIN_SAMPLE_INTERVAL = 23 hours;

    uint256 public constant MAX_SPOT_RATIO = 10;
    uint8 public immutable DECIMALS;

    ITwapSource public twap;

    uint128[SAMPLES] public buffer;
    uint8 public count;
    uint8 public head;
    uint256 public bufferSum;
    uint64 public lastSampleAt;
    uint64 public lastSampleTs;
    uint16 public distinctDays;
    uint64 private _optionTime;
    uint64 private _optionTimeUpdatedAt;

    event TwapSourceSet(address source);
    event Sampled(uint256 indexed dayBucket, uint256 price);
    event SampleClamped(uint256 rawPrice, uint256 clampedPrice);
    event GapForwardFilled(uint256 daysFilled);
    event BufferPurged();

    error StaleTwap();
    error NotWarm();
    error DecimalsMismatch();
    error PriceOverflow();
    error InvalidPrice();
    error UnhealthyOracle();

    constructor(address owner_, ITwapSource twap_) {
        if (owner_ == address(0) || address(twap_) == address(0)) revert InvalidPrice();
        _initializeOwner(owner_);
        twap = twap_;
        DECIMALS = twap_.decimals();
        _optionTime = uint64(block.timestamp);
        _optionTimeUpdatedAt = uint64(block.timestamp);
        emit TwapSourceSet(address(twap_));
    }

    function renounceOwnership() public payable override onlyOwner {
        revert("AlbPriceOracle: ownership required");
    }

    /// @param purge Clear samples and restart the 20-sample warm-up.
    function setTwapSource(ITwapSource newSource, bool purge) external onlyOwner {
        if (newSource.decimals() != DECIMALS) revert DecimalsMismatch();
        twap = newSource;
        if (purge) {
            _checkpointOptionTime();
            _purge();
            emit BufferPurged();
        }
        emit TwapSourceSet(address(newSource));
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    /// @notice Unvalidated quote; use safeSpotPrice for valuation.
    function spotPrice() external view returns (uint256) {
        return twap.consult();
    }

    /// @notice Quote with freshness and price bounds.
    function safeSpotPrice() external view returns (uint256 p) {
        ITwapSource _t = twap;
        unchecked {
            if (block.timestamp - _t.lastUpdate() > MAX_TWAP_STALENESS) revert StaleTwap();
        }
        p = _t.consult();
        if (p == 0) revert InvalidPrice();
        uint256 _c = count;
        if (_c != 0) {
            uint256 avg = _partialAvg(_c);
            if (avg != 0) {
                if (p > avg * MAX_SPOT_RATIO) revert UnhealthyOracle();
                if (p * MAX_SPOT_RATIO < avg) revert UnhealthyOracle();
            }
        }
    }

    /// @notice Cached-SMA health; does not validate the live quote.
    function isHealthy() public view returns (bool) {
        if (distinctDays < SAMPLES) return false;
        unchecked {
            if (block.timestamp - uint256(lastSampleAt) > MAX_BUFFER_STALENESS + DAY) return false;
            if (block.timestamp - twap.lastUpdate() > MAX_TWAP_STALENESS) return false;
        }
        return true;
    }

    function sma20() external view returns (uint256) {
        if (distinctDays < SAMPLES || count < SAMPLES) revert NotWarm();
        return _sma20();
    }

    function optionClock() public view returns (uint256 clock) {
        clock = _optionTime;
        if (distinctDays < SAMPLES || count < SAMPLES) return clock;
        uint256 until = uint256(lastSampleAt) + MAX_BUFFER_STALENESS + DAY;
        if (until > block.timestamp) until = block.timestamp;
        uint256 last = _optionTimeUpdatedAt;
        if (until > last) clock += until - last;
    }

    function _checkpointOptionTime() internal {
        _optionTime = uint64(optionClock());
        _optionTimeUpdatedAt = uint64(block.timestamp);
    }

    function _partialAvg(uint256 filled) internal view returns (uint256) {
        unchecked { return bufferSum / filled; }
    }

    function _sma20() internal view returns (uint256) {
        unchecked {
            return bufferSum / SAMPLES;
        }
    }

    function _purge() internal {
        for (uint256 i; i < SAMPLES;) {
            buffer[i] = 0;
            unchecked { ++i; }
        }
        count = 0;
        head = 0;
        bufferSum = 0;
        lastSampleAt = 0;
        lastSampleTs = 0;
        distinctDays = 0;
    }

    function poke() external returns (bool updated) {
        uint64 today;
        unchecked {
            today = uint64((block.timestamp / DAY) * DAY);
        }
        if (today <= lastSampleAt) return false;
        uint64 _lastTs = lastSampleTs;
        if (_lastTs != 0) {
            unchecked {
                if (block.timestamp - uint256(_lastTs) < MIN_SAMPLE_INTERVAL) return false;
            }
        }
        ITwapSource _twap = twap;
        unchecked {
            if (block.timestamp - _twap.lastUpdate() > MAX_TWAP_STALENESS) revert StaleTwap();
        }

        uint256 price = _twap.consult();
        if (price == 0) revert InvalidPrice();
        if (price > type(uint128).max) revert PriceOverflow();
        _checkpointOptionTime();

        uint64 _last = lastSampleAt;
        uint256 anchor;
        if (_last != 0) {
            uint256 gap;
            unchecked { gap = (uint256(today) - uint256(_last)) / DAY; }
            if (gap > MAX_FORWARD_FILL) {
                if (gap < SAMPLES && count != 0) {
                    anchor = buffer[(uint256(head) + SAMPLES - 1) % SAMPLES];
                }
                _purge();
                emit BufferPurged();
                _last = 0;
            }
        }

        uint8 _head = head;
        uint8 _count = count;
        uint256 writes = 1;
        if (_last != 0) {
            unchecked { writes = (uint256(today) - uint256(_last)) / DAY; }
            if (writes > 1) emit GapForwardFilled(writes - 1);
        }

        uint256 cur = _count == 0 ? anchor : uint256(buffer[(uint256(_head) + SAMPLES - 1) % SAMPLES]);
        if (cur == 0) cur = price;
        uint256 _sum = bufferSum;
        for (uint256 i; i < writes;) {
            unchecked {
                uint256 band = (cur * MAX_SAMPLE_DEVIATION_BPS) / 10_000;
                uint256 up = cur + band;
                uint256 down = cur > band ? cur - band : 0;
                cur = price > up ? up : (price < down ? down : price);
                _sum = _sum - uint256(buffer[_head]) + cur;
                buffer[_head] = uint128(cur);
                _head = uint8((uint256(_head) + 1) % SAMPLES);
                if (_count < SAMPLES) ++_count;
                ++i;
            }
        }
        head = _head;
        count = _count;
        bufferSum = _sum;
        lastSampleAt = today;
        lastSampleTs = uint64(block.timestamp);
        if (distinctDays < SAMPLES) {
            unchecked { distinctDays = uint16(distinctDays + 1); }
        }

        if (cur != price) emit SampleClamped(price, cur);

        emit Sampled(today, cur);
        return true;
    }
}

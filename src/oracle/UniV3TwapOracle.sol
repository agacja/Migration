// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IAssetOracle} from "../interfaces/IAssetOracle.sol";

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function observe(uint32[] calldata secondsAgos)
        external view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function observations(uint256 index)
        external view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract UniV3TwapOracle is IAssetOracle, OwnableRoles {
    /// @notice May suspend routes; route and pricing configuration require Owner.
    uint256 public constant ROLE_ADMIN = 1 << 0;
    mapping(address => bool) public routeSuspended;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    uint8 public constant PRICE_DECIMALS = 8;
    address public immutable usdc;
    address public immutable weth;
    uint256 internal immutable _usdcUnit;

    struct Route {
        address poolA;
        address poolB;
        address intermediate;
        bool configured;
    }
    mapping(address => Route) public routes;

    mapping(address => uint128) public poolMinLiquidity;

    EnumerableSetLib.AddressSet private _factories;
    uint24[] public feeTierPreference;

    uint32 public twapPeriod = 1 hours;
    uint24 public maxDeviationBps = 500;
    uint16 public minObservationCardinality = 10;
    uint128 public minLiquidity = 1e18;

    /// @notice Maximum observation age; prevents pricing from fully extrapolated pool data.
    uint32 public maxObservationAge = 1 hours;

    event RouteSet(address indexed asset, address poolA, address poolB, address intermediate);
    event RouteCleared(address indexed asset);
    event RouteSuspended(address indexed asset, bool suspended);
    event PoolMinLiquiditySet(address indexed pool, uint128 minLiq);
    event FactoryAdded(address indexed factory);
    event FactoryRemoved(address indexed factory);
    event TwapPeriodSet(uint32 period);
    event MaxDeviationSet(uint24 bps);
    event FeeTierPreferenceSet(uint24[] feeTiers);
    event MinObservationCardinalitySet(uint16 cardinality);
    event MinLiquiditySet(uint128 liquidity);
    event MaxObservationAgeSet(uint32 age);

    error InvalidTwapPeriod();
    error InvalidDeviation();
    error PoolNotFound();
    error RouteNotConfigured();
    error PoolTokenMismatch();
    error TwapDeviationTooHigh();
    error InvalidPrice();
    error InsufficientObservations();
    error InsufficientLiquidity();
    error StaleObservation();
    error FactoryAlreadyRegistered();
    error FactoryNotRegistered();
    error ZeroAddress();

    constructor(address owner_, address usdc_, address weth_, address[] memory initialFactories) {
        if (owner_ == address(0) || usdc_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        usdc = usdc_;
        weth = weth_;
        _usdcUnit = 10 ** _decimalsOf(usdc_);

        uint256 n = initialFactories.length;
        for (uint256 i; i < n;) {
            _addFactory(initialFactories[i]);
            unchecked { ++i; }
        }
        feeTierPreference = [uint24(500), 3000, 10000];
    }

    function decimals() external pure returns (uint8) {
        return PRICE_DECIMALS;
    }

    function priceOf(address asset) external view returns (uint256) {
        return _priceOf(asset);
    }

    function tryPriceOf(address asset) external view returns (uint256 price, bool ok) {
        try this.priceOf(asset) returns (uint256 p) {
            return (p, p != 0);
        } catch {
            return (0, false);
        }
    }

    function isStale(address asset) external view returns (bool) {
        try this.priceOf(asset) returns (uint256 p) {
            return p == 0;
        } catch {
            return true;
        }
    }

    function twapPrice(address token) external view returns (uint256) {
        uint256 per1e18 = _priceOf(token);
        return FullMath.mulDiv(per1e18, 10 ** _decimalsOf(token), 1e18);
    }

    function setRoute(address asset, address poolA, address poolB, address intermediate)
        external
        onlyOwner
    {
        if (asset == address(0) || poolA == address(0)) revert ZeroAddress();
        if (poolB == address(0)) {
            _requirePoolHolds(poolA, asset, usdc);
            intermediate = address(0);
        } else {
            if (intermediate == address(0)) revert ZeroAddress();
            _requirePoolHolds(poolA, asset, intermediate);
            _requirePoolHolds(poolB, intermediate, usdc);
        }
        routes[asset] = Route({poolA: poolA, poolB: poolB, intermediate: intermediate, configured: true});

        if (routeSuspended[asset]) {
            delete routeSuspended[asset];
            emit RouteSuspended(asset, false);
        }
        emit RouteSet(asset, poolA, poolB, intermediate);
    }

    function clearRoute(address asset) external onlyOwner {
        delete routes[asset];
        delete routeSuspended[asset];
        emit RouteCleared(asset);
    }

    /// @notice Suspend pricing while retaining the pinned route.
    function suspendRoute(address asset) external onlyOwnerOrRoles(ROLE_ADMIN) {
        if (!routes[asset].configured) revert RouteNotConfigured();
        routeSuspended[asset] = true;
        emit RouteSuspended(asset, true);
    }

    function unsuspendRoute(address asset) external onlyOwner {
        routeSuspended[asset] = false;
        emit RouteSuspended(asset, false);
    }

    function setPoolMinLiquidity(address pool, uint128 minLiq) external onlyOwner {
        poolMinLiquidity[pool] = minLiq;
        emit PoolMinLiquiditySet(pool, minLiq);
    }

    function _requirePoolHolds(address pool, address tokenA, address tokenB) internal view {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (IUniswapV3Pool(pool).token0() != t0 || IUniswapV3Pool(pool).token1() != t1) {
            revert PoolTokenMismatch();
        }
    }

    function renounceOwnership() public payable override onlyOwner {
        revert("UniV3TwapOracle: ownership required");
    }

    function addFactory(address factory) external onlyOwner {
        _addFactory(factory);
    }

    function _addFactory(address factory) internal {
        if (factory == address(0)) revert ZeroAddress();
        if (!_factories.add(factory)) revert FactoryAlreadyRegistered();
        emit FactoryAdded(factory);
    }

    function removeFactory(address factory) external onlyOwner {
        if (!_factories.remove(factory)) revert FactoryNotRegistered();
        emit FactoryRemoved(factory);
    }

    function factoriesLength() external view returns (uint256) {
        return _factories.length();
    }

    function allFactories() external view returns (address[] memory) {
        return _factories.values();
    }

    function setTwapPeriod(uint32 period) external onlyOwner {
        if (period < 60 || period > 86400) revert InvalidTwapPeriod();
        twapPeriod = period;
        emit TwapPeriodSet(period);

        if (maxObservationAge > period) {
            maxObservationAge = period;
            emit MaxObservationAgeSet(period);
        }
    }

    function setMaxDeviation(uint24 bps) external onlyOwner {
        if (bps == 0 || bps > 5000) revert InvalidDeviation();
        maxDeviationBps = bps;
        emit MaxDeviationSet(bps);
    }

    function setFeeTierPreference(uint24[] calldata feeTiers) external onlyOwner {
        delete feeTierPreference;
        uint256 n = feeTiers.length;
        for (uint256 i; i < n;) {
            feeTierPreference.push(feeTiers[i]);
            unchecked { ++i; }
        }
        emit FeeTierPreferenceSet(feeTiers);
    }

    function setMinObservationCardinality(uint16 cardinality) external onlyOwner {
        if (cardinality < 2) revert InvalidTwapPeriod();
        minObservationCardinality = cardinality;
        emit MinObservationCardinalitySet(cardinality);
    }

    function setMinLiquidity(uint128 liquidity_) external onlyOwner {
        minLiquidity = liquidity_;
        emit MinLiquiditySet(liquidity_);
    }

    /// @param age Maximum observation age, capped at twapPeriod.
    function setMaxObservationAge(uint32 age) external onlyOwner {
        if (age < 60 || age > twapPeriod) revert InvalidTwapPeriod();
        maxObservationAge = age;
        emit MaxObservationAgeSet(age);
    }

    function suggestPool(address tokenA, address tokenB) public view returns (address best) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        uint16 minCard = minObservationCardinality;
        uint128 bestLiq;

        address[] memory factoriesArr = _factories.values();
        uint24[] memory tiers = feeTierPreference;
        uint256 fLen = factoriesArr.length;
        uint256 tLen = tiers.length;

        for (uint256 f; f < fLen;) {
            IUniswapV3Factory factory = IUniswapV3Factory(factoriesArr[f]);
            for (uint256 t; t < tLen;) {
                address candidate = factory.getPool(t0, t1, tiers[t]);
                if (candidate != address(0)) {
                    IUniswapV3Pool p = IUniswapV3Pool(candidate);
                    (,,, uint16 cardinality,,,) = p.slot0();
                    if (cardinality >= minCard) {
                        uint128 liq = p.liquidity();
                        if (liq > bestLiq) {
                            bestLiq = liq;
                            best = candidate;
                        }
                    }
                }
                unchecked { ++t; }
            }
            unchecked { ++f; }
        }
    }

    function suggestRoute(address asset)
        external
        view
        returns (address poolA, address poolB, address intermediate)
    {
        poolA = suggestPool(asset, usdc);
        if (poolA != address(0)) return (poolA, address(0), address(0));
        return (suggestPool(asset, weth), suggestPool(weth, usdc), weth);
    }

    function _priceOf(address asset) internal view returns (uint256) {
        if (asset == usdc) {
            return FullMath.mulDiv(1e18, 10 ** PRICE_DECIMALS, _usdcUnit);
        }

        Route memory r = routes[asset];
        if (!r.configured || routeSuspended[asset]) revert RouteNotConfigured();

        address quote = r.poolB == address(0) ? usdc : r.intermediate;
        (uint256 significand, int256 exponent) = _twapRatio(r.poolA, asset, quote);
        if (r.poolB != address(0)) {
            (uint256 next, int256 nextExponent) = _twapRatio(r.poolB, r.intermediate, usdc);

            significand *= next;
            exponent += nextExponent;
            uint256 shift = FixedPointMathLib.log2(significand) - 127;
            significand >>= shift;
            exponent += int256(shift);
        }

        uint256 scaled = significand * (1e18 * 10 ** PRICE_DECIMALS);
        uint256 price;
        if (exponent <= 0) {
            price = (scaled / _usdcUnit) >> uint256(-exponent);
        } else {
            price = FullMath.mulDiv(scaled, uint256(1) << uint256(exponent), _usdcUnit);
        }
        if (price == 0) revert InvalidPrice();
        return price;
    }

    function _twapRatio(address pool, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 significand, int256 exponent)
    {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        _requirePoolHolds(pool, tokenIn, tokenOut);

        (uint160 sqrtSpot,, uint16 obsIndex, uint16 cardinality,,,) = p.slot0();
        if (cardinality < minObservationCardinality) revert InsufficientObservations();
        _requireLiveObservations(p, obsIndex);

        uint32 period = twapPeriod;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqX128) = p.observe(secondsAgos);
        uint160 splDelta;
        unchecked { splDelta = secondsPerLiqX128[1] - secondsPerLiqX128[0]; }
        if (splDelta == 0) revert InsufficientLiquidity();
        uint256 twaLiquidity = (uint256(period) << 128) / uint256(splDelta);
        uint128 liqFloor = poolMinLiquidity[pool];
        if (liqFloor == 0) liqFloor = minLiquidity;
        if (twaLiquidity < liqFloor) revert InsufficientLiquidity();

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int24(delta / int56(uint56(period)));
        if (delta < 0 && (delta % int56(uint56(period)) != 0)) meanTick--;
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(meanTick);

        if (_deviationBps(sqrtSpot, sqrtTwap) > maxDeviationBps) revert TwapDeviationTooHigh();

        return _ratioAtSqrtPrice(sqrtTwap, tokenIn > tokenOut);
    }

    /// @dev significand * 2^exponent, retaining at least 126 significant bits.
    function _ratioAtSqrtPrice(uint160 sqrtTwap, bool inverse)
        internal pure returns (uint256 significand, int256 exponent)
    {
        uint256 numerator;
        uint256 denominator;
        if (uint256(sqrtTwap) >= (1 << 128)) {
            numerator = FullMath.mulDiv(uint256(sqrtTwap), uint256(sqrtTwap), 1 << 64);
            denominator = 1 << 128;
        } else {
            numerator = uint256(sqrtTwap) * uint256(sqrtTwap);
            denominator = 1 << 192;
        }
        if (inverse) (numerator, denominator) = (denominator, numerator);

        uint256 denominatorBits = 127 + FixedPointMathLib.log2(denominator);
        uint256 numeratorBits = FixedPointMathLib.log2(numerator);
        uint256 shift = denominatorBits > numeratorBits ? denominatorBits - numeratorBits : 0;
        significand = FullMath.mulDiv(numerator, uint256(1) << shift, denominator);
        exponent = -int256(shift);
    }

    /// @dev Require a recent observation; uint32 timestamps wrap as in Uniswap.
    function _requireLiveObservations(IUniswapV3Pool p, uint16 obsIndex) internal view {
        (uint32 newestTs,,, bool initialized) = p.observations(uint256(obsIndex));
        if (!initialized) revert InsufficientObservations();
        uint32 age;
        unchecked { age = uint32(block.timestamp) - newestTs; }
        if (age > maxObservationAge) revert StaleObservation();
    }

    /// @notice Route observation timestamp for adapter freshness checks.
    function lastObservationAt(address asset) external view returns (uint256) {
        if (asset == usdc) return block.timestamp;
        Route memory r = routes[asset];
        if (!r.configured || routeSuspended[asset]) revert RouteNotConfigured();

        uint256 oldest = _newestObservationTs(r.poolA);
        if (r.poolB != address(0)) {
            uint256 b = _newestObservationTs(r.poolB);
            if (b < oldest) oldest = b;
        }
        return oldest;
    }

    function _newestObservationTs(address pool) internal view returns (uint256) {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (,, uint16 obsIndex,,,,) = p.slot0();
        (uint32 ts,,, bool initialized) = p.observations(uint256(obsIndex));
        if (!initialized) return 0;

        uint32 age;
        unchecked { age = uint32(block.timestamp) - ts; }
        return block.timestamp - uint256(age);
    }

    function _deviationBps(uint160 sqrtA, uint160 sqrtB) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(uint256(sqrtA), uint256(sqrtA), 1 << 96);
        uint256 b = FullMath.mulDiv(uint256(sqrtB), uint256(sqrtB), 1 << 96);
        if (b == 0) return type(uint256).max;
        uint256 diff = a > b ? a - b : b - a;
        return FullMath.mulDiv(diff, 10_000, b);
    }

    function _decimalsOf(address token) internal view returns (uint8 d) {
        assembly ("memory-safe") {
            d := 18
            mstore(0x00, 0x313ce567)
            let ok := staticcall(gas(), token, 0x1c, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) {
                d := mload(0x00)
                if gt(d, 0xff) { revert(0x00, 0x00) }
            }
        }
    }
}

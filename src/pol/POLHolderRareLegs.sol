// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ActionPermissions} from "../utils/ActionPermissions.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {POLHolder} from "./POLHolder.sol";
import {POLBasis} from "./POLBasis.sol";
import {IALB} from "../interfaces/IALB.sol";
import {ILoC} from "../interfaces/ILoC.sol";
import {IAlbPriceOracle} from "../interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../interfaces/IAssetOracle.sol";

// Storage order must match POLHolder.
contract POLHolderRareLegs {
    uint256 public constant ROLE_ADMIN = 1 << 0;
    uint256 public constant ROLE_OPERATOR = 1 << 1;
    uint256 public constant MAX_PORTFOLIO_ASSETS = 32;
    uint256 public constant MAX_STABLES = 16;
    uint256 public constant MAX_REWARD_TOKENS = 16;

    IALB public immutable alb;
    IAlbPriceOracle public immutable albOracle;
    IAssetOracle public immutable assetOracle;
    uint256 public immutable DUST_VALUE;

    ILoC internal loc; // set-once (LoC beneficiary must be this contract)
    bool internal paused;
    uint16 internal globalToleranceBps = 50;
    uint16 internal perAssetToleranceBps = 100;
    uint16 internal emergencyToleranceBps = 300;
    uint8 internal _drawHead;
    uint8 internal _drawCount;

    uint128 internal baseRatePerSec;
    uint128 internal boostRatePerSec;

    uint128 internal pendingDraw;
    uint64 internal lastMaintainAt;
    uint64 internal maxPendingWindow = 7 days;

    uint128 internal maxDailyDraw;
    uint128 internal maxWeeklyDraw;

    uint128 internal maxTotalDraw; // lifetime cumulative cap (conservative mirror of LoC.maxTotal)
    uint128 internal totalDrawn;

    /// @notice Caps how much unexecuted burn budget can accrue across an idle period.
    uint64 internal maxBurnWindow = 2 days;
    /// @notice Nonce binding authorization to a specific burn proposal.
    uint64 internal burnNonce;

    address[] internal portfolio;
    mapping(address => POLHolder.AssetEntry) internal asset;

    mapping(address => bool) internal isSwapTarget;
    mapping(address => bool) internal isAllowedAsset;
    address[] internal rewardList;
    mapping(address => bool) internal isRewardToken;

    address[] internal stableList;
    mapping(address => bool) internal isStable;

    struct DrawSample { uint64 ts; uint192 amount; }
    DrawSample[8] internal _drawWindow;

    struct BurnProposal {
        uint256 amountTotal;   // total USD value of POL to convert & remove
        uint128 dailyRate;     // USD value per day
        uint128 maxAlbPrice;
        uint64  expiry;
        uint128 spent;         // USD value actually sold so far
        uint64  lastExec;
        uint64  nonce;
        bool    active;
    }
    BurnProposal internal burn;
    BurnProposal internal pendingBurn;

    struct RebalanceAuth {
        bytes32 actionsHash;
        uint64 executableAt;
        uint64 expiry;
        bool   used;
    }
    RebalanceAuth internal rebalanceAuth;
    uint64 public constant REBALANCE_DELAY = 6 hours;
    uint64 public constant REBALANCE_VALIDITY = 24 hours;

    struct YeetAuth {
        bytes32 actionsHash;
        uint128 minValueOut;   // USD (assetOracle decimals) that must land in the tracked set
        uint64  expiry;
        uint16  priorTargetBps;
        bool    used;
    }
    mapping(address => YeetAuth) internal yeetAuth;

    struct ShutdownAuth {
        uint128 minStableGain;   // per-call floor, in USD
        uint128 maxLiquidate;
        uint128 liquidated;
        uint64  expiry;
        bool    armed;
    }
    ShutdownAuth internal shutdownAuth;
    uint128 internal burnBudget;
    uint32 internal burnRemainder;
    mapping(address => uint256) internal _basisBalances;
    mapping(address => uint256) internal _basisPrincipal;
    ActionPermissions.Store internal _actionPermissions;
    uint64 public constant MAX_SHUTDOWN_WINDOW = 48 hours;

    struct Action {
        address target;
        bytes   data;
        address approveToken;
        address approveSpender;
        uint256 approveAmount;
    }

    enum Leg { HARVEST, GENERAL }

    event LoCSet(address indexed loc);
    event RatesUpdated(uint128 base, uint128 boost);
    event LimitsUpdated(uint128 daily, uint128 weekly, uint128 total);
    event TolerancesUpdated(uint16 global_, uint16 perAsset, uint16 emergency);
    event AssetSet(address indexed asset, uint16 targetBps, uint16 toleranceBps, POLHolder.RewardMode mode);
    event AssetRemoved(address indexed asset);
    event SwapTargetSet(address indexed target, bool allowed);
    event ActionPermissionSet(address indexed target, bytes4 indexed selector, address spender, bool allowed);
    event StableSet(address indexed token, bool allowed);
    event RewardTokenSet(address indexed token, bool allowed);
    event Maintained(uint256 drawn, uint256 valueIn, uint256 valueGained);
    event Harvested(uint256 albRepaid, uint256 albBurned);
    event BurnProposed(uint256 amountTotal, uint128 dailyRate, uint128 maxAlbPrice, uint64 expiry, uint64 nonce);
    event BurnAuthorized(uint256 amountTotal, uint128 dailyRate, uint128 maxAlbPrice, uint64 expiry, uint64 nonce);
    event BurnCancelled();
    event BurnExecuted(uint256 valueSold, uint256 albAcquired, uint256 burned, uint256 repaid);
    event RebalanceAuthorized(bytes32 actionsHash, uint64 executableAt, uint64 expiry);
    event RebalanceCancelled();
    event Rebalanced();
    event Paused(bool state);
    event YeetAuthorized(address indexed asset);
    event YeetRevoked(address indexed asset);
    event YeetExecuted(address indexed asset, uint256 valueSold, uint256 valueReceived);
    event EmergencyShutdownArmed();
    event EmergencyShutdownDisarmed();
    event EmergencyShutdownExecuted(uint256 valueLiquidated, uint256 stableGained);
    event PendingWindowSet(uint64 window);
    event OracleStaleWarning();

    error NotWhitelisted();
    error ForbiddenTarget();
    error InvalidActionData();
    error ActionNotAllowed();
    error PausedErr();
    error ToleranceBreach();
    error StaleAssetOracle();
    error PortfolioWeightsInvalid();
    error CallFailed();
    error AlbPriceTooHigh();
    error BurnInactive();
    error BurnExpired();
    error NotAuthorized();
    error AuthorizationExpired();
    error LoCAlreadySet();
    error LoCNotSet();
    error InvalidParams();
    error DecimalsMismatch();
    error NonZeroBalance();
    error BudgetExhausted();
    error NoOpExecution();
    error ListLimitReached();

    address private immutable __self;

    modifier onlyDelegated() {
        if (address(this) == __self) revert NotAuthorized();
        _;
    }

    constructor(IALB alb_, IAlbPriceOracle albOracle_, IAssetOracle assetOracle_) {
        alb = alb_;
        albOracle = albOracle_;
        assetOracle = assetOracle_;
        DUST_VALUE = 10 ** assetOracle_.decimals();
        __self = address(this);
    }

    function setSwapTarget(address target, bool allowed) external onlyDelegated {
        if (allowed && _forbiddenTarget(target)) revert ForbiddenTarget();
        if (allowed && target.code.length == 0) revert ActionPermissions.InvalidActionTarget();
        if (isSwapTarget[target] != allowed) ActionPermissions.invalidate(_actionPermissions, target);
        isSwapTarget[target] = allowed;
        emit SwapTargetSet(target, allowed);
    }

    function setActionPermission(address target, bytes4 selector, address spender, bool allowed) external onlyDelegated {
        if (allowed && (!isSwapTarget[target] || (spender != address(0) && !isSwapTarget[spender]))) {
            revert NotWhitelisted();
        }
        if (allowed && _forbiddenTarget(target)) revert ForbiddenTarget();
        ActionPermissions.set(_actionPermissions, target, selector, spender, allowed);
    }

    function setRewardToken(address token, bool allowed) external onlyDelegated {
        if (allowed && (token == address(alb) || token == address(0))) revert InvalidParams();
        if (allowed == isRewardToken[token]) return;
        if (allowed) {
            if (rewardList.length >= MAX_REWARD_TOKENS) revert ListLimitReached();
            (, bool ok) = assetOracle.tryPriceOf(token);
            if (!ok) revert StaleAssetOracle();
        }
        isRewardToken[token] = allowed;
        if (allowed) {
            rewardList.push(token);
        } else {
            uint256 n = rewardList.length;
            for (uint256 i; i < n;) {
                if (rewardList[i] == token) {
                    rewardList[i] = rewardList[n - 1];
                    rewardList.pop();
                    break;
                }
                unchecked { ++i; }
            }
        }
        emit RewardTokenSet(token, allowed);
    }

    function setStable(address token, bool allowed) external onlyDelegated {
        if (allowed && (token == address(alb) || token == address(0))) revert InvalidParams();
        if (allowed == isStable[token]) return;
        if (!allowed && !asset[token].exists && !_isDelistable(token)) revert NonZeroBalance();
        isStable[token] = allowed;
        if (allowed) {
            if (stableList.length >= MAX_STABLES) revert ListLimitReached();
            stableList.push(token);
        } else {
            uint256 n = stableList.length;
            for (uint256 i; i < n;) {
                if (stableList[i] == token) {
                    stableList[i] = stableList[n - 1];
                    stableList.pop();
                    break;
                }
                unchecked { ++i; }
            }
        }
        emit StableSet(token, allowed);
    }

    function setAssetEntry(address tok, uint16 targetBps, uint16 toleranceBps, POLHolder.RewardMode mode) external onlyDelegated {
        if (!isAllowedAsset[tok]) revert NotWhitelisted();
        if (tok == address(alb) || tok == address(0)) revert InvalidParams();
        if (targetBps > 10_000 || toleranceBps > 5000) revert InvalidParams();
        POLHolder.AssetEntry storage e = asset[tok];
        if (!e.exists) {
            if (portfolio.length >= MAX_PORTFOLIO_ASSETS) revert ListLimitReached();
            portfolio.push(tok);
            e.exists = true;
        }
        e.targetBps = targetBps;
        e.toleranceBps = toleranceBps;
        if (e.rewardMode != mode) {
            e.lastRecordedPrice = 0;
            delete _basisBalances[tok];
            delete _basisPrincipal[tok];
        }
        e.rewardMode = mode;

        _validatePortfolioWeights();
        emit AssetSet(tok, targetBps, toleranceBps, mode);
    }

    function removeAsset(address tok) external onlyDelegated {
        POLHolder.AssetEntry storage e = asset[tok];
        if (!e.exists || e.targetBps != 0) revert InvalidParams();
        if (!isStable[tok] && !_isDelistable(tok)) revert NonZeroBalance();
        uint256 n = portfolio.length;
        for (uint256 i; i < n;) {
            if (portfolio[i] == tok) {
                portfolio[i] = portfolio[n - 1];
                portfolio.pop();
                break;
            }
            unchecked { ++i; }
        }
        delete asset[tok];
        delete _basisBalances[tok];
        delete _basisPrincipal[tok];
        emit AssetRemoved(tok);
    }

    function authorizeYeet(address tok, bytes32 actionsHash, uint128 minValueOut, uint64 expiry)
        external
        onlyDelegated
    {
        if (expiry <= block.timestamp) revert InvalidParams();
        if (minValueOut == 0) revert InvalidParams();
        POLHolder.AssetEntry storage e = asset[tok];

        if (!e.exists) revert NotWhitelisted();
        yeetAuth[tok] = YeetAuth({
            actionsHash: actionsHash,
            minValueOut: minValueOut,
            expiry: expiry,
            priorTargetBps: e.targetBps,
            used: false
        });
        e.targetBps = 0;
        emit YeetAuthorized(tok);
    }

    function revokeYeet(address tok) external onlyDelegated {
        YeetAuth memory ya = yeetAuth[tok];
        if (!ya.used && ya.expiry != 0) {
            POLHolder.AssetEntry storage e = asset[tok];
            if (e.exists && e.targetBps == 0) {
                e.targetBps = ya.priorTargetBps;
                _validatePortfolioWeights();
            }
        }
        delete yeetAuth[tok];
        emit YeetRevoked(tok);
    }

    function armEmergencyShutdown(uint128 minStableGain, uint128 maxLiquidate, uint64 expiry)
        external
        onlyDelegated
    {
        if (expiry <= block.timestamp || maxLiquidate == 0) revert InvalidParams();
        unchecked {
            if (expiry - block.timestamp > MAX_SHUTDOWN_WINDOW) revert InvalidParams();
        }
        shutdownAuth = ShutdownAuth({
            minStableGain: minStableGain,
            maxLiquidate: maxLiquidate,
            liquidated: 0,
            expiry: expiry,
            armed: true
        });
        emit EmergencyShutdownArmed();
    }

    function disarmEmergencyShutdown() external onlyDelegated {
        delete shutdownAuth;
        emit EmergencyShutdownDisarmed();
    }

    function executeYeet(address tok, Action[] calldata actions) external onlyDelegated {
        YeetAuth storage ya = yeetAuth[tok];
        if (ya.used || ya.expiry == 0) revert NotAuthorized();
        if (block.timestamp > ya.expiry) revert AuthorizationExpired();
        if (keccak256(abi.encode(actions)) != ya.actionsHash) revert NotAuthorized();
        uint128 minValueOut = ya.minValueOut;
        ya.used = true;

        uint256 px = _priceOrZero(tok);
        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        (uint256[] memory pxPre,) = _lenientPricesAtEntry(toks);
        uint256 balBefore = _balanceOf(tok);
        uint256 restBefore = _valueExcluding(toks, pre, tok, pxPre);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _checkpointBasis(toks, pre, pxPre);
        _executeActions(actions, Leg.GENERAL);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireRewardBalancesNotDrained(rewardPre);

        uint256[] memory post = _balances(toks);
        _checkpointBasis(toks, post, pxPre);
        _requireOnlyTokenDecreased(toks, pre, post, tok);

        uint256 balAfter = _balanceOf(tok);
        uint256 soldUnits = balBefore > balAfter ? balBefore - balAfter : 0;
        uint256 valueSold;
        unchecked { valueSold = (soldUnits * px) / 1e18; }

        // Reuse entry prices after external calls.
        uint256 restAfter = _valueExcluding(toks, post, tok, pxPre);
        uint256 gained = restAfter > restBefore ? restAfter - restBefore : 0;
        if (gained < minValueOut) revert ToleranceBreach();
        uint256 minGain;
        unchecked { minGain = valueSold - (valueSold * emergencyToleranceBps) / 10_000; }
        if (gained < minGain) revert ToleranceBreach();

        emit YeetExecuted(tok, valueSold, gained);
    }

    function executeEmergencyShutdown(Action[] calldata actions) external onlyDelegated {
        ShutdownAuth storage sa = shutdownAuth;
        if (!sa.armed) revert NotAuthorized();
        if (block.timestamp > sa.expiry) revert AuthorizationExpired();

        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        (uint256[] memory pxPre, bool[] memory pricedPre) = _lenientPricesAtEntry(toks);
        uint256 pfBefore = _portfolioValueEmergency(toks, pre, pxPre);
        uint256 stableBefore = _stableOnlyValueEmergency(toks, pre, pxPre);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _checkpointBasis(toks, pre, pxPre);
        _executeActions(actions, Leg.GENERAL);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireRewardBalancesNotDrained(rewardPre);

        uint256[] memory post = _balances(toks);
        _checkpointBasis(toks, post, pxPre);
        _requireStableBalancesNotDrained(toks, pre, post);
        _requireUnpricedNotDrained(pre, post, pricedPre);

        uint256 pfAfter = _portfolioValueEmergency(toks, post, pxPre);
        uint256 stableAfter = _stableOnlyValueEmergency(toks, post, pxPre);
        if (pfAfter > pfBefore) revert ToleranceBreach();

        uint256 liquidated;
        unchecked { liquidated = pfBefore - pfAfter; }
        uint256 stableGained = stableAfter > stableBefore ? stableAfter - stableBefore : 0;
        uint256 maxLoss;
        unchecked { maxLoss = (liquidated * emergencyToleranceBps) / 10_000; }
        if (pfAfter + stableAfter + maxLoss < pfBefore + stableBefore) revert ToleranceBreach();
        uint256 minGain;
        unchecked { minGain = liquidated - maxLoss; }
        if (stableGained < minGain) revert ToleranceBreach();
        if (stableGained < sa.minStableGain) revert ToleranceBreach();
        uint256 cum = uint256(sa.liquidated) + liquidated;
        if (cum > sa.maxLiquidate) revert BudgetExhausted();
        sa.liquidated = uint128(cum);

        emit EmergencyShutdownExecuted(liquidated, stableGained);
    }

    function _validatePortfolioWeights() internal view {
        if (_activeWeightSum() > 10_000) revert PortfolioWeightsInvalid();
    }

    function _activeWeightSum() internal view returns (uint256 sum) {
        uint256 n = portfolio.length;
        for (uint256 i; i < n;) {
            unchecked {
                sum += asset[portfolio[i]].targetBps;
                ++i;
            }
        }
    }

    function _forbiddenTarget(address target) internal view returns (bool) {
        return target == address(alb)
            || target == address(loc)
            || target == address(albOracle)
            || target == address(assetOracle)
            || target == address(this);
    }

    function _runAction(Action calldata a, Leg leg) internal returns (uint256 pulled) {
        if (!isSwapTarget[a.target]) revert NotWhitelisted();
        if (_forbiddenTarget(a.target)) revert ForbiddenTarget();
        ActionPermissions.check(_actionPermissions, a.target, a.data, a.approveToken, a.approveSpender, a.approveAmount);

        address tok = a.approveToken;
        if (tok != address(0)) {
            bool tracked = tok == address(alb) || asset[tok].exists || isStable[tok];
            if (!tracked && !(leg == Leg.HARVEST && isRewardToken[tok])) revert NotWhitelisted();
            if (!isSwapTarget[a.approveSpender]) revert NotWhitelisted();
            SafeTransferLib.safeApprove(tok, a.approveSpender, a.approveAmount);
        }

        (bool ok,) = a.target.call(a.data);
        if (!ok) revert CallFailed();

        if (tok != address(0)) {
            uint256 left = _allowance(tok, a.approveSpender);
            unchecked { pulled = a.approveAmount > left ? a.approveAmount - left : 0; }
            SafeTransferLib.safeApprove(tok, a.approveSpender, 0);
        }
    }

    function _executeActions(Action[] calldata actions, Leg leg) internal {
        uint256 n = actions.length;
        for (uint256 i; i < n;) {
            _runAction(actions[i], leg);
            unchecked { ++i; }
        }
    }

    function _isDelistable(address tok) internal view returns (bool) {
        uint256 bal = _balanceOf(tok);
        if (bal == 0) return true;
        (uint256 p, bool ok) = assetOracle.tryPriceOf(tok);
        if (!ok || p == 0) return false;
        return FixedPointMathLib.fullMulDiv(bal, p, 1e18) <= DUST_VALUE;
    }

    function _priceOrZero(address tok) internal view returns (uint256) {
        (uint256 p, bool ok) = assetOracle.tryPriceOf(tok);
        return ok ? p : 0;
    }

    function _trackedTokens() internal view returns (address[] memory toks) {
        address[] memory pf = portfolio;
        address[] memory st = stableList;
        uint256 np = pf.length;
        uint256 ns = st.length;
        toks = new address[](np + ns);
        for (uint256 i; i < np;) {
            toks[i] = pf[i];
            unchecked { ++i; }
        }
        uint256 k = np;
        for (uint256 j; j < ns;) {
            address tok = st[j];
            if (!asset[tok].exists) {
                toks[k] = tok;
                unchecked { ++k; }
            }
            unchecked { ++j; }
        }

        assembly ("memory-safe") {
            mstore(toks, k)
        }
    }

    function _checkpointBasis(address[] memory tokens, uint256[] memory balances, uint256[] memory prices) internal {
        POLBasis.checkpoint(tokens, balances, prices, asset, _basisBalances, _basisPrincipal);
    }

    function _balances(address[] memory toks) internal view returns (uint256[] memory bals) {
        uint256 n = toks.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = _balanceOf(toks[i]);
            unchecked { ++i; }
        }
    }

    function _portfolioValueEmergency(
        address[] memory toks,
        uint256[] memory bals,
        uint256[] memory px
    )
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            if (asset[tok].exists) {
                unchecked { total += (bals[i] * px[i]) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _stableOnlyValueEmergency(
        address[] memory toks,
        uint256[] memory bals,
        uint256[] memory px
    )
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            if (!asset[tok].exists) {
                unchecked { total += (bals[i] * px[i]) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _valueExcluding(
        address[] memory toks,
        uint256[] memory bals,
        address skip,
        uint256[] memory px
    )
        internal
        pure
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            if (toks[i] != skip) {
                unchecked { total += (bals[i] * px[i]) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _requireStableBalancesNotDrained(address[] memory toks, uint256[] memory pre, uint256[] memory post)
        internal
        view
    {
        uint256 n = toks.length;
        for (uint256 i; i < n && i < pre.length;) {
            address tok = toks[i];
            if (!asset[tok].exists && post[i] < pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _lenientPricesAtEntry(address[] memory toks)
        internal view returns (uint256[] memory px, bool[] memory priced)
    {
        uint256 n = toks.length;
        px = new uint256[](n);
        priced = new bool[](n);
        for (uint256 i; i < n;) {
            (uint256 p, bool ok) = assetOracle.tryPriceOf(toks[i]);
            if (ok) px[i] = p;
            priced[i] = ok;
            unchecked { ++i; }
        }
    }

    function _requireUnpricedNotDrained(
        uint256[] memory pre,
        uint256[] memory post,
        bool[] memory pricedPre
    ) internal pure {
        uint256 n = pre.length;
        for (uint256 i; i < n;) {
            if (!pricedPre[i] && post[i] < pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _requireOnlyTokenDecreased(
        address[] memory toks,
        uint256[] memory pre,
        uint256[] memory post,
        address allowed
    ) internal pure {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            if (toks[i] != allowed && post[i] < pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _rewardBalances() internal view returns (uint256[] memory bals) {
        address[] memory rewards = rewardList;
        uint256 n = rewards.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = _balanceOf(rewards[i]);
            unchecked { ++i; }
        }
    }

    function _requireRewardBalancesNotDrained(uint256[] memory pre) internal view {
        address[] memory rewards = rewardList;
        uint256 n = rewards.length;
        for (uint256 i; i < n && i < pre.length;) {
            if (_balanceOf(rewards[i]) < pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _balanceOf(address tok) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(tok, address(this));
    }

    function _allowance(address tok, address spender) internal view returns (uint256 amt) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0xdd62ed3e))
            mstore(add(m, 0x04), address())
            mstore(add(m, 0x24), shr(96, shl(96, spender)))
            let ok := staticcall(gas(), tok, m, 0x44, 0x00, 0x20)
            if iszero(and(ok, gt(returndatasize(), 0x1f))) {
                mstore(0x00, 0x3204506f)
                revert(0x1c, 0x04)
            }
            amt := mload(0x00)
        }
    }
}

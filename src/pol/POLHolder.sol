// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ActionPermissions} from "../utils/ActionPermissions.sol";
import {POLBasis} from "./POLBasis.sol";
import {IALB} from "../interfaces/IALB.sol";
import {ILoC} from "../interfaces/ILoC.sol";
import {IAlbPriceOracle} from "../interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../interfaces/IAssetOracle.sol";
import {POLHolderRareLegs} from "./POLHolderRareLegs.sol";

contract POLHolder is OwnableRoles, ReentrancyGuardTransient {
    uint256 public constant ROLE_ADMIN = 1 << 0;
    uint256 public constant ROLE_OPERATOR = 1 << 1;
    uint256 public constant MAX_PORTFOLIO_ASSETS = 32;
    uint256 public constant MAX_STABLES = 16;
    uint256 public constant MAX_REWARD_TOKENS = 16;

    IALB public immutable alb;
    IAlbPriceOracle public immutable albOracle;
    IAssetOracle public immutable assetOracle;
    address internal immutable _rareLegs;

    /// @notice Delegatecall target for portfolio administration, yeet and shutdown.
    function rareLegs() external view returns (address) {
        return _rareLegs;
    }

    ILoC public loc; // set-once (LoC beneficiary must be this contract)
    bool public paused;
    uint16 public globalToleranceBps = 50;
    uint16 public perAssetToleranceBps = 100;
    uint16 public emergencyToleranceBps = 300;
    uint8 internal _drawHead;
    uint8 internal _drawCount;

    uint128 public baseRatePerSec;
    uint128 public boostRatePerSec;

    uint128 public pendingDraw;
    uint64 public lastMaintainAt;
    uint64 public maxPendingWindow = 7 days;

    uint128 public maxDailyDraw;
    uint128 public maxWeeklyDraw;

    uint128 public maxTotalDraw; // lifetime cumulative cap (conservative mirror of LoC.maxTotal)
    uint128 public totalDrawn;

    /// @notice Caps how much unexecuted burn budget can accrue across an idle period.
    uint64 public maxBurnWindow = 2 days;
    /// @notice Nonce binding authorization to a specific burn proposal.
    uint64 public burnNonce;

    enum RewardMode { OUTRIGHT, COMPOUNDING }
    struct AssetEntry {
        uint16 targetBps;
        uint16 toleranceBps;
        RewardMode rewardMode;
        uint128 lastRecordedPrice;
        bool exists;
    }
    address[] public portfolio;
    mapping(address => AssetEntry) public asset;

    mapping(address => bool) public isSwapTarget;
    mapping(address => bool) public isAllowedAsset;
    address[] public rewardList;
    mapping(address => bool) public isRewardToken;

    address[] public stableList;
    mapping(address => bool) public isStable;

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
    BurnProposal public burn;
    BurnProposal public pendingBurn;

    struct RebalanceAuth {
        bytes32 actionsHash;
        uint64 executableAt;
        uint64 expiry;
        bool   used;
    }
    RebalanceAuth public rebalanceAuth;
    uint64 public constant REBALANCE_DELAY = 6 hours;
    uint64 public constant REBALANCE_VALIDITY = 24 hours;

    struct YeetAuth {
        bytes32 actionsHash;
        uint128 minValueOut;   // USD (assetOracle decimals) that must land in the tracked set
        uint64  expiry;
        uint16  priorTargetBps;
        bool    used;
    }
    mapping(address => YeetAuth) public yeetAuth;

    struct ShutdownAuth {
        uint128 minStableGain;   // per-call floor, in USD
        uint128 maxLiquidate;
        uint128 liquidated;
        uint64  expiry;
        bool    armed;
    }
    ShutdownAuth public shutdownAuth;
    /// @notice Available USD burn budget, with sub-unit accrual retained as / 1 days.
    uint128 public burnBudget;
    uint32 public burnRemainder;
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
    event AssetSet(address indexed asset, uint16 targetBps, uint16 toleranceBps, RewardMode mode);
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

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedErr();
        _;
    }

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner() && !hasAnyRole(msg.sender, ROLE_ADMIN)) revert NotAuthorized();
        _;
    }

    constructor(
        address owner_,
        IALB alb_,
        IAlbPriceOracle albOracle_,
        IAssetOracle assetOracle_
    ) {
        _initializeOwner(owner_);
        alb = alb_;
        albOracle = albOracle_;
        assetOracle = assetOracle_;
        if (albOracle_.decimals() != assetOracle_.decimals()) revert DecimalsMismatch();
        lastMaintainAt = uint64(block.timestamp);
        _rareLegs = address(new POLHolderRareLegs(alb_, albOracle_, assetOracle_));
    }

    function setLoC(ILoC loc_) external onlyOwner {
        if (address(loc) != address(0)) revert LoCAlreadySet();
        if (address(loc_) == address(0)) revert InvalidParams();
        loc = loc_;
        emit LoCSet(address(loc_));
    }

    function setRates(uint128 base, uint128 boost) external onlyOwner {
        baseRatePerSec = base;
        boostRatePerSec = boost;
        emit RatesUpdated(base, boost);
    }

    function setDrawLimits(uint128 daily, uint128 weekly, uint128 total) external onlyOwner {
        if (daily > weekly) revert InvalidParams();
        maxDailyDraw = daily;
        maxWeeklyDraw = weekly;
        maxTotalDraw = total;
        emit LimitsUpdated(daily, weekly, total);
    }

    function setTolerances(uint16 global_, uint16 perAsset, uint16 emergency) external onlyOwner {
        if (global_ > 2000 || perAsset > 5000 || emergency > 5000) revert InvalidParams();
        globalToleranceBps = global_;
        perAssetToleranceBps = perAsset;
        emergencyToleranceBps = emergency;
        emit TolerancesUpdated(global_, perAsset, emergency);
    }

    function setPendingWindow(uint64 window) external onlyOwner {
        if (window < 1 days || window > 30 days) revert InvalidParams();
        maxPendingWindow = window;
        emit PendingWindowSet(window);
    }

    function setMaxBurnWindow(uint64 window) external onlyOwner {
        if (window < 1 days || window > 30 days) revert InvalidParams();
        maxBurnWindow = window;
    }

    function setSwapTarget(address target, bool allowed) external onlyOwner {
        (target, allowed);
        _delegateRare();
    }

    function setActionPermission(address target, bytes4 selector, address spender, bool allowed) external onlyOwner {
        (target, selector, spender, allowed);
        _delegateRare();
    }

    function actionPermission(address target, bytes4 selector)
        external view returns (ActionPermissions.Permission memory)
    {
        return _actionPermissions.permissions[target][selector];
    }

    function setAllowedAsset(address token, bool allowed) external onlyOwner {
        isAllowedAsset[token] = allowed;
    }

    function setRewardToken(address token, bool allowed) external onlyOwner {
        (token, allowed);
        _delegateRare();
    }

    function setStable(address token, bool allowed) external onlyOwner {
        (token, allowed);
        _delegateRare();
    }

    function setAssetEntry(address tok, uint16 targetBps, uint16 toleranceBps, RewardMode mode)
        external
        onlyOwner
    {
        (tok, targetBps, toleranceBps, mode);
        _delegateRare();
    }

    function removeAsset(address tok) external onlyOwner {
        (tok);
        _delegateRare();
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

    function pause() external onlyAdminOrOwner {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    function authorizeRebalance(bytes32 actionsHash) external onlyRoles(ROLE_ADMIN) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 exec;
        uint64 exp;
        unchecked {
            exec = nowTs + REBALANCE_DELAY;
            exp = exec + REBALANCE_VALIDITY;
        }
        rebalanceAuth = RebalanceAuth({
            actionsHash: actionsHash,
            executableAt: exec,
            expiry: exp,
            used: false
        });
        emit RebalanceAuthorized(actionsHash, exec, exp);
    }

    function cancelRebalance() external onlyAdminOrOwner {
        delete rebalanceAuth;
        emit RebalanceCancelled();
    }

    function authorizeYeet(address tok, bytes32 actionsHash, uint128 minValueOut, uint64 expiry)
        external
        onlyRoles(ROLE_ADMIN)
    {
        (tok, actionsHash, minValueOut, expiry);
        _delegateRare();
    }

    function revokeYeet(address tok) external onlyAdminOrOwner {
        (tok);
        _delegateRare();
    }

    function armEmergencyShutdown(uint128 minStableGain, uint128 maxLiquidate, uint64 expiry)
        external
        onlyRoles(ROLE_ADMIN)
    {
        (minStableGain, maxLiquidate, expiry);
        _delegateRare();
    }

    function disarmEmergencyShutdown() external onlyAdminOrOwner {
        _delegateRare();
    }

    function proposeBurn(uint256 amountTotal, uint128 dailyRate, uint128 maxAlbPrice, uint64 expiry)
        external
        onlyRoles(ROLE_ADMIN)
    {
        if (expiry <= block.timestamp || amountTotal == 0 || amountTotal > type(uint128).max) {
            revert InvalidParams();
        }
        if (dailyRate == 0) revert InvalidParams();
        uint64 n;
        unchecked { n = ++burnNonce; }
        pendingBurn = BurnProposal({
            amountTotal: amountTotal,
            dailyRate: dailyRate,
            maxAlbPrice: maxAlbPrice,
            expiry: expiry,
            spent: 0,
            lastExec: uint64(block.timestamp),
            nonce: n,
            active: false
        });
        emit BurnProposed(amountTotal, dailyRate, maxAlbPrice, expiry, n);
    }

    function authorizeBurn(
        uint256 amountTotal,
        uint128 dailyRate,
        uint128 maxAlbPrice,
        uint64 expiry,
        uint64 nonce
    ) external onlyOwner {
        BurnProposal memory p = pendingBurn;
        if (p.expiry <= block.timestamp || p.amountTotal == 0) revert InvalidParams();
        if (
            p.amountTotal != amountTotal || p.dailyRate != dailyRate || p.maxAlbPrice != maxAlbPrice
                || p.expiry != expiry || p.nonce != nonce
        ) revert NotAuthorized();
        p.lastExec = uint64(block.timestamp);
        p.active = true;
        burn = p;
        burnBudget = 0;
        burnRemainder = 0;
        delete pendingBurn;
        emit BurnAuthorized(amountTotal, dailyRate, maxAlbPrice, expiry, nonce);
    }

    function cancelBurn() external onlyAdminOrOwner {
        burn.active = false;
        burnBudget = 0;
        burnRemainder = 0;
        delete pendingBurn;
        emit BurnCancelled();
    }

    function maintain(
        Action[] calldata harvestActions,
        Action[] calldata swapActions
    ) external onlyRoles(ROLE_OPERATOR) nonReentrant whenNotPaused {
        if (address(loc) == address(0)) revert LoCNotSet();
        uint256 activeSum;
        if (swapActions.length != 0) activeSum = _activeWeightSum();

        _executeHarvest(harvestActions);

        _accruePending();
        uint256 drawable = pendingDraw;
        if (drawable != 0) {
            (uint256 daily, uint256 weekly) = _drawnWindows();
            uint256 dailyAvail = maxDailyDraw > daily ? maxDailyDraw - daily : 0;
            uint256 weeklyAvail = maxWeeklyDraw > weekly ? maxWeeklyDraw - weekly : 0;
            uint256 totalAvail = maxTotalDraw > totalDrawn ? maxTotalDraw - totalDrawn : 0;
            if (drawable > dailyAvail) drawable = dailyAvail;
            if (drawable > weeklyAvail) drawable = weeklyAvail;
            if (drawable > totalAvail) drawable = totalAvail;
        }

        uint256 drawn;
        uint256 valueIn;
        uint256 valueGained;

        if (drawable != 0 && swapActions.length != 0) {
            if (activeSum == 0) revert PortfolioWeightsInvalid();
            drawn = drawable;
            loc.draw(drawn, address(this));
            unchecked {
                totalDrawn += uint128(drawn);
                pendingDraw -= uint128(drawn);
            }
            _recordDraw(drawn);

            valueIn = (drawn * albOracle.safeSpotPrice()) / 1e18;

            (valueGained) = _runSwapLeg(swapActions, valueIn, activeSum);
        }

        emit Maintained(drawn, valueIn, valueGained);
    }

    function _runSwapLeg(
        Action[] calldata swapActions,
        uint256 valueIn,
        uint256 activeSum
    ) internal returns (uint256 valueGained) {
        address[] memory pf = portfolio;
        uint256 n = pf.length;
        uint256[] memory before_ = new uint256[](n);
        bool[] memory pricedPre = new bool[](n);
        // Use entry prices for both valuations.
        uint256[] memory pxPre = new uint256[](n);
        uint256 trackedBefore;
        for (uint256 i; i < n;) {
            address tok = pf[i];
            uint256 bal = _balanceOf(tok);
            before_[i] = bal;
            (uint256 p, bool ok) = assetOracle.tryPriceOf(tok);
            pricedPre[i] = ok;
            if (ok) pxPre[i] = p;

            if (!ok && asset[tok].targetBps != 0) revert StaleAssetOracle();
            if (bal != 0) {
                unchecked { trackedBefore += (bal * pxPre[i]) / 1e18; }
            }
            unchecked { ++i; }
        }
        (address[] memory st, uint256[] memory stPx) = _stableOnlyEntry();
        trackedBefore += _stableOnlyValueAt(st, stPx);
        uint256[] memory rewardPre = _rewardBalances();
        _checkpointBasis(pf, before_, pxPre);
        _executeSwapActions(swapActions);
        uint256 trackedAfter;
        for (uint256 i; i < n;) {
            address tok = pf[i];
            AssetEntry memory e = asset[tok];
            uint256 bal = _balanceOf(tok);
            uint256 px = pxPre[i];
            if (bal != 0) {
                unchecked { trackedAfter += (bal * px) / 1e18; }
            }
            if (!pricedPre[i] && bal < before_[i]) revert ToleranceBreach();
            if (e.targetBps != 0) {
                uint256 expected = (valueIn * e.targetBps) / activeSum;
                if (expected != 0) {
                    uint256 v;
                    if (bal > before_[i]) {
                        unchecked { v = ((bal - before_[i]) * px) / 1e18; }
                    }
                    uint256 tol = e.toleranceBps == 0 ? perAssetToleranceBps : e.toleranceBps;
                    uint256 maxDev = (expected * tol) / 10_000;
                    uint256 lower = expected > maxDev ? expected - maxDev : 0;
                    if (v < lower || v > expected + maxDev) revert ToleranceBreach();
                }
            }
            before_[i] = bal;
            unchecked { ++i; }
        }
        _checkpointBasis(pf, before_, pxPre);
        trackedAfter += _stableOnlyValueAt(st, stPx);
        _requireRewardBalancesNotDrained(rewardPre);
        uint256 minGain;
        unchecked {
            minGain = valueIn - (valueIn * globalToleranceBps) / 10_000;
        }
        if (trackedAfter < trackedBefore + minGain) revert ToleranceBreach();
        unchecked { valueGained = trackedAfter - trackedBefore; }
    }

    function pokeOracle() external {
        albOracle.poke();
    }

    function executeBurn(Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant whenNotPaused {
        BurnProposal storage b = burn;
        if (!b.active) revert BurnInactive();
        if (block.timestamp > b.expiry) revert BurnExpired();
        uint256 albPrice = albOracle.safeSpotPrice();
        if (albPrice > b.maxAlbPrice) revert AlbPriceTooHigh();
        (uint256 budget, uint256 remainder) = _accrueBurnBudget(b);
        if (budget == 0) {
            (burnBudget, burnRemainder) = (0, uint32(remainder));
            return;
        }
        (uint256 valueSold, uint256 acquired) = _runBurnActions(actions, budget, albPrice);
        if (valueSold == 0) revert NoOpExecution();
        (uint256 repaid, uint256 burned) = _repayThenBurn(acquired);
        b.spent += uint128(valueSold);
        (burnBudget, burnRemainder) = (uint128(budget - valueSold), uint32(remainder));
        if (b.spent >= b.amountTotal) b.active = false;

        emit BurnExecuted(valueSold, acquired, burned, repaid);
    }

    function _accrueBurnBudget(BurnProposal storage b)
        internal
        returns (uint256 budget, uint256 remainder)
    {
        uint256 elapsed = block.timestamp - b.lastExec;
        uint256 window = maxBurnWindow;
        if (elapsed > window) elapsed = window;
        uint256 numerator = uint256(b.dailyRate) * elapsed + burnRemainder;
        budget = uint256(burnBudget) + numerator / 1 days;
        uint256 cap = uint256(b.dailyRate) * window / 1 days;
        uint256 remaining = b.amountTotal - b.spent;
        if (cap > remaining) cap = remaining;
        if (budget >= cap) {
            budget = cap;
        } else {
            remainder = numerator % 1 days;
        }
        b.lastExec = uint64(block.timestamp);
    }

    function _runBurnActions(Action[] calldata actions, uint256 budget, uint256 albPrice)
        internal
        returns (uint256 valueSold, uint256 acquired)
    {
        IALB _alb = alb;
        uint256 albBefore = _alb.balanceOf(address(this));
        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        (uint256[] memory pxPre, bool[] memory pricedPre) = _assetPricesAtEntry(toks);
        uint256[] memory rewardPre = _rewardBalances();

        _checkpointBasis(toks, pre, pxPre);
        _executeActions(actions, Leg.GENERAL);
        uint256[] memory post = _balances(toks);
        _checkpointBasis(toks, post, pxPre);
        valueSold = _grossOutflowValue(pre, post, pxPre);
        if (valueSold > budget) revert BudgetExhausted();
        _requireRewardBalancesNotDrained(rewardPre);

        _requireUnpricedNotDrained(pre, post, pricedPre);
        uint256 albAfter = _alb.balanceOf(address(this));
        if (albAfter < albBefore) revert ToleranceBreach();
        acquired = albAfter - albBefore;

        uint256 albValue = (acquired * albPrice) / 1e18;
        uint256 minAlbValue;
        unchecked {
            minAlbValue = valueSold - (valueSold * globalToleranceBps) / 10_000;
        }
        if (albValue < minAlbValue) revert ToleranceBreach();
    }

    function executeRebalance(Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant whenNotPaused {
        RebalanceAuth storage a = rebalanceAuth;
        if (a.used || a.executableAt == 0) revert NotAuthorized();
        if (block.timestamp < a.executableAt) revert NotAuthorized();
        if (block.timestamp > a.expiry) revert AuthorizationExpired();
        if (keccak256(abi.encode(actions)) != a.actionsHash) revert NotAuthorized();
        a.used = true;

        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        (uint256[] memory pxPre, bool[] memory pricedPre) = _assetPricesAtEntry(toks);
        // Use the same entry prices before and after external calls.
        uint256 trackedBefore = _valueExcluding(toks, pre, address(0), pxPre);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _checkpointBasis(toks, pre, pxPre);
        _executeActions(actions, Leg.GENERAL);
        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireRewardBalancesNotDrained(rewardPre);

        uint256[] memory post = _balances(toks);
        _checkpointBasis(toks, post, pxPre);
        _requireStableBalancesNotDrained(toks, pre, post);
        uint256 trackedAfter = _valueExcluding(toks, post, address(0), pxPre);
        _requireUnpricedNotDrained(pre, post, pricedPre);
        uint256 valueOut = _grossOutflowValue(pre, post, pxPre);
        uint256 maxLoss;
        unchecked { maxLoss = (valueOut * globalToleranceBps) / 10_000; }
        if (trackedAfter + maxLoss < trackedBefore) revert ToleranceBreach();

        emit Rebalanced();
    }

    function executeYeet(address tok, Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant {
        (tok, actions);
        _delegateRare();
    }

    function executeEmergencyShutdown(Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant {
        (actions);
        _delegateRare();
    }

    /// @dev Delegate with revert propagation; return normally so modifier cleanup runs.
    function _delegateRare() internal {
        address impl = _rareLegs;
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, 0, calldatasize())
            if iszero(delegatecall(gas(), impl, m, calldatasize(), 0, 0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
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

    function _executeSwapActions(Action[] calldata actions) internal {
        address[] memory toks = _trackedTokens();
        uint256 m = toks.length;
        uint256 n = actions.length;
        uint256[] memory snap = new uint256[](m);
        address _alb = address(alb);
        for (uint256 i; i < n;) {
            bool spendsAlb = actions[i].approveToken == _alb;
            if (!spendsAlb) {
                for (uint256 j; j < m;) {
                    snap[j] = _balanceOf(toks[j]);
                    unchecked { ++j; }
                }
            }
            _runAction(actions[i], Leg.GENERAL);
            if (!spendsAlb) {
                for (uint256 j; j < m;) {
                    if (_balanceOf(toks[j]) > snap[j]) revert ToleranceBreach();
                    unchecked { ++j; }
                }
            }
            unchecked { ++i; }
        }
    }

    function _executeActions(Action[] calldata actions, Leg leg) internal {
        uint256 n = actions.length;
        for (uint256 i; i < n;) {
            _runAction(actions[i], leg);
            unchecked { ++i; }
        }
    }

    function _executeHarvestActions(Action[] calldata actions)
        internal
        returns (uint256 outflowValue)
    {
        uint256 n = actions.length;
        if (n == 0) return 0;
        address[] memory rewards = rewardList;
        uint256 r = rewards.length;
        if (r == 0) {
            _executeActions(actions, Leg.HARVEST);
            return 0;
        }
        uint256[] memory pre = new uint256[](r);
        uint256[] memory px = new uint256[](r);
        for (uint256 i; i < n;) {
            for (uint256 j; j < r;) {
                pre[j] = _balanceOf(rewards[j]);
                unchecked { ++j; }
            }

            uint256 pulled = _runAction(actions[i], Leg.HARVEST);
            address pulledTok = actions[i].approveToken;

            for (uint256 j; j < r;) {
                address rtok = rewards[j];
                uint256 post = _balanceOf(rtok);
                uint256 left;
                unchecked { left = post < pre[j] ? pre[j] - post : 0; }
                if (rtok == pulledTok && pulled > left) left = pulled;
                if (left != 0) {
                    uint256 p = px[j];
                    if (p == 0) {
                        p = _freshPrice(rtok);
                        px[j] = p;
                    }
                    unchecked { outflowValue += (left * p) / 1e18; }
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    function _executeHarvest(Action[] calldata harvestActions) internal {
        try albOracle.poke() returns (bool) {} catch {
            emit OracleStaleWarning();
        }

        address[] memory toks = _trackedTokens();
        uint256 n = portfolio.length;
        uint256[] memory preBal = _balances(toks);
        uint256 actualYieldValue;
        uint256[] memory basisPrices = new uint256[](toks.length);
        for (uint256 i; i < n; ++i) {
            AssetEntry storage e = asset[toks[i]];
            if (e.rewardMode == RewardMode.COMPOUNDING && e.targetBps != 0) {
                basisPrices[i] = _freshPrice(toks[i]);
            }
        }
        uint256[] memory yields = POLBasis.prepareHarvest(
            toks, preBal, basisPrices, n, asset, _basisBalances, _basisPrincipal
        );

        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory stablePx = _lenientPricesFrom(toks, n);
        uint256 stableBefore = _valueFrom(toks, preBal, stablePx, n);
        uint256 rewardOutflowValue = _executeHarvestActions(harvestActions);

        uint256[] memory postBal = _balances(toks);
        _requireStableBalancesNotDrained(toks, preBal, postBal);
        if (_valueFrom(toks, postBal, stablePx, n) < stableBefore) {
            revert ToleranceBreach();
        }
        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();

        actualYieldValue = POLBasis.settleHarvest(
            toks, preBal, postBal, basisPrices, yields, asset, _basisBalances, _basisPrincipal
        );
        uint256 albDelta;
        unchecked {
            uint256 albNow = alb.balanceOf(address(this));
            albDelta = albNow > albBefore ? albNow - albBefore : 0;
        }

        actualYieldValue += rewardOutflowValue;
        if (actualYieldValue != 0) {
            uint256 albValue = (albDelta * albOracle.safeSpotPrice()) / 1e18;
            uint256 minValue;
            unchecked {
                minValue = actualYieldValue - (actualYieldValue * globalToleranceBps) / 10_000;
            }
            if (albValue < minValue) revert ToleranceBreach();
        }

        uint256 albBal = alb.balanceOf(address(this));
        if (albBal != 0) {
            (uint256 repaid, uint256 burned) = _repayThenBurn(albBal);
            emit Harvested(repaid, burned);
        }
    }

    function _repayThenBurn(uint256 amount) internal returns (uint256 repaid, uint256 burned) {
        if (amount == 0) return (0, 0);
        IALB _alb = alb;
        ILoC _loc = loc;
        if (address(_loc) != address(0)) _loc.pokeInterest();
        uint256 outstanding = address(_loc) != address(0) ? _loc.drawnAmount() : 0;
        repaid = amount > outstanding ? outstanding : amount;
        if (repaid != 0) {
            _alb.approve(address(_loc), repaid);
            _loc.repay(repaid);
            _alb.approve(address(_loc), 0);
        }
        unchecked { burned = amount - repaid; }
        if (burned != 0) {
            _alb.burn(burned);
        }
    }

    function _accruePending() internal {
        uint64 last = lastMaintainAt;
        uint256 elapsed;
        unchecked { elapsed = block.timestamp - last; }
        uint64 _maxWindow = maxPendingWindow;
        if (elapsed > _maxWindow) elapsed = _maxWindow;

        bool boost;
        IAlbPriceOracle _o = albOracle;
        if (_o.isHealthy()) {
            try _o.safeSpotPrice() returns (uint256 spot) {
                boost = spot > _o.sma20();
            } catch {
                emit OracleStaleWarning();
            }
        } else {
            emit OracleStaleWarning();
        }
        uint256 rate;
        unchecked {
            rate = uint256(baseRatePerSec) + (boost ? boostRatePerSec : 0);
        }
        uint256 np = uint256(pendingDraw) + rate * elapsed;
        uint256 cap;
        unchecked {
            cap = (uint256(baseRatePerSec) + uint256(boostRatePerSec)) * uint256(_maxWindow);
        }
        if (np > cap) np = cap;
        if (np > type(uint128).max) np = type(uint128).max;
        pendingDraw = uint128(np);
        lastMaintainAt = uint64(block.timestamp);
    }

    function _recordDraw(uint256 amount) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint8 head = _drawHead;
        uint8 count_ = _drawCount;
        uint8 windowLen = uint8(_drawWindow.length);

        if (count_ != 0) {
            uint8 prev;
            unchecked { prev = uint8((uint256(head) + windowLen - 1) % windowLen); }
            DrawSample memory last = _drawWindow[prev];
            if (uint256(last.ts) / 1 days == uint256(nowTs) / 1 days) {
                _drawWindow[prev] = DrawSample({ts: nowTs, amount: last.amount + uint192(amount)});
                return;
            }
        }

        _drawWindow[head] = DrawSample({ts: nowTs, amount: uint192(amount)});
        unchecked {
            _drawHead = uint8((uint256(head) + 1) % windowLen);
        }
        if (count_ < windowLen) {
            unchecked { _drawCount = count_ + 1; }
        }
    }

    function _drawnWindows() internal view returns (uint256 daily, uint256 weekly) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 dailyCutoff;
        uint64 weeklyCutoff;
        unchecked {
            dailyCutoff = nowTs > 1 days ? nowTs - 1 days : 0;
            weeklyCutoff = nowTs > 7 days ? nowTs - 7 days : 0;
        }
        uint256 n = _drawCount;
        for (uint256 i; i < n;) {
            DrawSample memory s = _drawWindow[i];
            if (s.ts > weeklyCutoff) {
                unchecked { weekly += s.amount; }
                if (s.ts > dailyCutoff) {
                    unchecked { daily += s.amount; }
                }
            }
            unchecked { ++i; }
        }
    }

    function _freshPrice(address tok) internal view returns (uint256) {
        (uint256 p, bool ok) = assetOracle.tryPriceOf(tok);
        if (!ok) revert StaleAssetOracle();
        return p;
    }

    function _priceOrZero(address tok) internal view returns (uint256) {
        (uint256 p, bool ok) = assetOracle.tryPriceOf(tok);
        return ok ? p : 0;
    }

    function _assetPrice(address tok) internal view returns (uint256) {
        if (asset[tok].targetBps == 0) return _priceOrZero(tok);
        return _freshPrice(tok);
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

    function _valueFrom(
        address[] memory toks,
        uint256[] memory bals,
        uint256[] memory px,
        uint256 from
    )
        internal
        pure
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i = from; i < n;) {
            unchecked { total += (bals[i] * px[i]) / 1e18; }
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

    function _stableOnlyEntry() internal view returns (address[] memory st, uint256[] memory px) {
        st = stableList;
        uint256 n = st.length;
        px = new uint256[](n);
        for (uint256 i; i < n;) {
            address tok = st[i];
            if (!asset[tok].exists) px[i] = _freshPrice(tok);
            unchecked { ++i; }
        }
    }

    function _stableOnlyValueAt(address[] memory st, uint256[] memory px)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = st.length;
        for (uint256 i; i < n;) {
            address tok = st[i];
            if (!asset[tok].exists) {
                uint256 bal = _balanceOf(tok);
                if (bal != 0) {
                    unchecked { total += (bal * px[i]) / 1e18; }
                }
            }
            unchecked { ++i; }
        }
    }

    function _grossOutflowValue(uint256[] memory pre, uint256[] memory post, uint256[] memory px)
        internal
        pure
        returns (uint256 total)
    {
        uint256 n = pre.length;
        for (uint256 i; i < n;) {
            if (post[i] < pre[i]) {
                unchecked { total += ((pre[i] - post[i]) * px[i]) / 1e18; }
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

    function _assetPricesAtEntry(address[] memory toks)
        internal view returns (uint256[] memory px, bool[] memory priced)
    {
        uint256 n = toks.length;
        px = new uint256[](n);
        priced = new bool[](n);
        for (uint256 i; i < n;) {
            (uint256 p, bool ok) = assetOracle.tryPriceOf(toks[i]);
            if (!ok && asset[toks[i]].targetBps != 0) revert StaleAssetOracle();
            if (ok) px[i] = p;
            priced[i] = ok;
            unchecked { ++i; }
        }
    }

    function _lenientPricesFrom(address[] memory toks, uint256 from)
        internal
        view
        returns (uint256[] memory px)
    {
        uint256 n = toks.length;
        px = new uint256[](n);
        for (uint256 i = from; i < n;) {
            px[i] = _priceOrZero(toks[i]);
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

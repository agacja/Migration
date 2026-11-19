// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IALB} from "../../src/interfaces/IALB.sol";
import {ILoC} from "../../src/interfaces/ILoC.sol";
import {IAlbPriceOracle} from "../../src/interfaces/IAlbPriceOracle.sol";
import {IAssetOracle} from "../../src/interfaces/IAssetOracle.sol";

contract POLHolderNoGuard is OwnableRoles, ReentrancyGuardTransient {
    uint256 public constant ROLE_ADMIN = 1 << 0;
    uint256 public constant ROLE_OPERATOR = 1 << 1;

    IALB public immutable alb;
    IAlbPriceOracle public immutable albOracle;
    IAssetOracle public immutable assetOracle;

    ILoC public loc;
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

    uint128 public maxTotalDraw;
    uint128 public totalDrawn;

    uint64 public maxBurnWindow = 2 days;
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
        uint256 amountTotal;
        uint128 dailyRate;
        uint128 maxAlbPrice;
        uint64  expiry;
        uint128 spent;
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
        uint128 minValueOut;
        uint64  expiry;
        uint16  priorTargetBps;
        bool    used;
    }
    mapping(address => YeetAuth) public yeetAuth;

    struct ShutdownAuth {
        uint128 minStableGain;
        uint128 maxLiquidate;
        uint128 liquidated;
        uint64  expiry;
        bool    armed;
    }
    ShutdownAuth public shutdownAuth;
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
    error ForbiddenSelector();
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
        if (allowed && _forbiddenTarget(target)) revert ForbiddenTarget();
        isSwapTarget[target] = allowed;
        emit SwapTargetSet(target, allowed);
    }

    function setAllowedAsset(address token, bool allowed) external onlyOwner {
        isAllowedAsset[token] = allowed;
    }

    function setRewardToken(address token, bool allowed) external onlyOwner {
        if (allowed && (token == address(alb) || token == address(0))) revert InvalidParams();
        if (allowed == isRewardToken[token]) return;
        if (allowed) {
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

    function setStable(address token, bool allowed) external onlyOwner {
        if (allowed && (token == address(alb) || token == address(0))) revert InvalidParams();
        if (allowed == isStable[token]) return;
        if (!allowed && !asset[token].exists && _balanceOf(token) != 0) revert NonZeroBalance();
        isStable[token] = allowed;
        if (allowed) {
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

    function setAssetEntry(address tok, uint16 targetBps, uint16 toleranceBps, RewardMode mode) external onlyOwner {
        if (!isAllowedAsset[tok]) revert NotWhitelisted();

        if (tok == address(alb) || tok == address(0)) revert InvalidParams();
        if (targetBps > 10_000 || toleranceBps > 5000) revert InvalidParams();
        AssetEntry storage e = asset[tok];
        if (!e.exists) {
            portfolio.push(tok);
            e.exists = true;
        }
        e.targetBps = targetBps;
        e.toleranceBps = toleranceBps;
        e.rewardMode = mode;

        _validatePortfolioWeights();
        emit AssetSet(tok, targetBps, toleranceBps, mode);
    }

    function removeAsset(address tok) external onlyOwner {
        AssetEntry storage e = asset[tok];
        if (!e.exists || e.targetBps != 0) revert InvalidParams();
        if (_balanceOf(tok) != 0 && !isStable[tok]) revert NonZeroBalance();
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
        emit AssetRemoved(tok);
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
        if (expiry <= block.timestamp) revert InvalidParams();
        AssetEntry storage e = asset[tok];

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

    function revokeYeet(address tok) external onlyAdminOrOwner {
        YeetAuth memory ya = yeetAuth[tok];
        if (!ya.used && ya.expiry != 0) {
            AssetEntry storage e = asset[tok];
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
        onlyRoles(ROLE_ADMIN)
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

    function disarmEmergencyShutdown() external onlyAdminOrOwner {
        delete shutdownAuth;
        emit EmergencyShutdownDisarmed();
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
        delete pendingBurn;
        emit BurnAuthorized(amountTotal, dailyRate, maxAlbPrice, expiry, nonce);
    }

    function cancelBurn() external onlyAdminOrOwner {
        burn.active = false;
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

            (valueGained) = _runSwapLeg(swapActions, valueIn, activeSum, drawn);
        }

        emit Maintained(drawn, valueIn, valueGained);
    }

    function _runSwapLeg(
        Action[] calldata swapActions,
        uint256 valueIn,
        uint256 activeSum,
        uint256 drawn
    ) internal returns (uint256 valueGained) {
        address[] memory pf = portfolio;
        uint256 n = pf.length;

        uint256[] memory before_ = new uint256[](n);
        uint256 trackedBefore;
        for (uint256 i; i < n;) {
            address tok = pf[i];
            uint256 bal = _balanceOf(tok);
            before_[i] = bal;
            if (bal != 0) {
                unchecked { trackedBefore += (bal * _assetPrice(tok)) / 1e18; }
            }
            unchecked { ++i; }
        }
        trackedBefore += _stableOnlyValue();

        uint256 albBefore = alb.balanceOf(address(this));

        uint256[] memory rewardPre = _rewardBalances();

        _executeActions(swapActions, Leg.GENERAL);

        uint256 trackedAfter;
        for (uint256 i; i < n;) {
            address tok = pf[i];
            AssetEntry memory e = asset[tok];
            uint256 bal = _balanceOf(tok);
            uint256 px;
            if (bal != 0) {
                px = _assetPrice(tok);
                unchecked { trackedAfter += (bal * px) / 1e18; }
            }

            if (bal < before_[i]) {
                if ((bal != 0 ? px : _assetPrice(tok)) == 0) revert ToleranceBreach();
            }
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
            unchecked { ++i; }
        }
        trackedAfter += _stableOnlyValue();

        _requireRewardBalancesUnchanged(rewardPre);

        unchecked {
            if (albBefore > drawn && alb.balanceOf(address(this)) < albBefore - drawn) {
                revert ToleranceBreach();
            }
        }

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
        if (albOracle.safeSpotPrice() > b.maxAlbPrice) revert AlbPriceTooHigh();

        uint256 elapsed;
        unchecked { elapsed = block.timestamp - b.lastExec; }
        uint64 _window = maxBurnWindow;
        if (elapsed > _window) elapsed = _window;

        uint256 dailyRate = b.dailyRate;
        uint256 budget;
        unchecked { budget = (dailyRate * elapsed) / 1 days; }
        uint256 remaining;
        unchecked { remaining = b.amountTotal - b.spent; }
        if (budget > remaining) budget = remaining;
        if (budget == 0) return;

        (uint256 valueSold, uint256 acquired) = _runBurnActions(actions, budget);

        if (valueSold == 0) revert NoOpExecution();

        (uint256 repaid, uint256 burned) = _repayThenBurn(acquired);

        b.spent += uint128(valueSold);

        uint256 consumed = (elapsed * valueSold) / budget;
        if (consumed > elapsed) consumed = elapsed;
        unchecked { b.lastExec = uint64(b.lastExec + consumed); }
        if (b.spent >= b.amountTotal) b.active = false;

        emit BurnExecuted(valueSold, acquired, burned, repaid);
    }

    function _runBurnActions(Action[] calldata actions, uint256 budget)
        internal
        returns (uint256 valueSold, uint256 acquired)
    {
        IALB _alb = alb;
        uint256 albBefore = _alb.balanceOf(address(this));
        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        uint256[] memory rewardPre = _rewardBalances();

        _executeActions(actions, Leg.GENERAL);

        valueSold = _grossOutflowValue(toks, pre);
        if (valueSold > budget) revert BudgetExhausted();
        _requireRewardBalancesUnchanged(rewardPre);

        _requireUnpricedNotDrained(toks, pre, _balances(toks));

        uint256 albAfter = _alb.balanceOf(address(this));
        if (albAfter < albBefore) revert ToleranceBreach();
        acquired = albAfter - albBefore;

        uint256 albValue = (acquired * albOracle.safeSpotPrice()) / 1e18;
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
        uint256 trackedBefore = _valueOfStrict(toks, pre);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _executeActions(actions, Leg.GENERAL);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireStableBalancesNotDrained(toks, pre);
        _requireRewardBalancesUnchanged(rewardPre);

        uint256[] memory post = _balances(toks);
        uint256 trackedAfter = _valueOfStrict(toks, post);

        _requireUnpricedNotDrained(toks, pre, post);

        uint256 valueOut = _grossOutflowValue(toks, pre);
        uint256 maxLoss;
        unchecked { maxLoss = (valueOut * globalToleranceBps) / 10_000; }
        if (trackedAfter + maxLoss < trackedBefore) revert ToleranceBreach();

        emit Rebalanced();
    }

    function executeYeet(address tok, Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant {
        YeetAuth storage ya = yeetAuth[tok];
        if (ya.used || ya.expiry == 0) revert NotAuthorized();
        if (block.timestamp > ya.expiry) revert AuthorizationExpired();
        if (keccak256(abi.encode(actions)) != ya.actionsHash) revert NotAuthorized();
        uint128 minValueOut = ya.minValueOut;
        ya.used = true;

        uint256 px = _priceOrZero(tok);
        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        uint256 balBefore = _balanceOf(tok);

        uint256 restBefore = _valueExcluding(toks, pre, tok);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _executeActions(actions, Leg.GENERAL);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireRewardBalancesUnchanged(rewardPre);

        uint256[] memory post = _balances(toks);

        _requireOnlyTokenDecreased(toks, pre, post, tok);

        uint256 balAfter = _balanceOf(tok);
        uint256 soldUnits = balBefore > balAfter ? balBefore - balAfter : 0;
        uint256 valueSold;
        unchecked { valueSold = (soldUnits * px) / 1e18; }

        uint256 restAfter = _valueExcluding(toks, post, tok);
        uint256 gained = restAfter > restBefore ? restAfter - restBefore : 0;

        if (gained < minValueOut) revert ToleranceBreach();
        uint256 minGain;
        unchecked { minGain = valueSold - (valueSold * emergencyToleranceBps) / 10_000; }
        if (gained < minGain) revert ToleranceBreach();

        emit YeetExecuted(tok, valueSold, gained);
    }

    function executeEmergencyShutdown(Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant {
        ShutdownAuth storage sa = shutdownAuth;
        if (!sa.armed) revert NotAuthorized();
        if (block.timestamp > sa.expiry) revert AuthorizationExpired();

        address[] memory toks = _trackedTokens();
        uint256[] memory pre = _balances(toks);
        uint256 pfBefore = _portfolioValueEmergency(toks, pre);
        uint256 stableBefore = _stableOnlyValueEmergency(toks, pre);
        uint256 albBefore = alb.balanceOf(address(this));
        uint256[] memory rewardPre = _rewardBalances();

        _executeActions(actions, Leg.GENERAL);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        _requireRewardBalancesUnchanged(rewardPre);

        uint256[] memory post = _balances(toks);

        _requireStableBalancesNotDrained(toks, pre);
        _requireUnpricedNotDrained(toks, pre, post);

        uint256 pfAfter = _portfolioValueEmergency(toks, post);
        uint256 stableAfter = _stableOnlyValueEmergency(toks, post);

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

    function _forbiddenTarget(address target) internal view returns (bool) {
        return target == address(alb)
            || target == address(loc)
            || target == address(albOracle)
            || target == address(assetOracle)
            || target == address(this);
    }

    function _forbiddenSelector(bytes calldata data) internal pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 sel = bytes4(data[0:4]);
        return sel == 0x095ea7b3
            || sel == 0xa9059cbb
            || sel == 0x23b872dd
            || sel == 0xd505accf
            || sel == 0x8fcbaf0c
            || sel == 0x39509351
            || sel == 0xa457c2d7;
    }

    function _runAction(Action calldata a, Leg leg) internal {
        if (!isSwapTarget[a.target]) revert NotWhitelisted();
        if (_forbiddenTarget(a.target)) revert ForbiddenTarget();
        if (_forbiddenSelector(a.data)) revert ForbiddenSelector();

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

    function _executeHarvestActions(Action[] calldata actions)
        internal
        returns (uint256 outflowValue)
    {
        address[] memory rewards = rewardList;
        uint256 r = rewards.length;
        uint256 n = actions.length;
        if (r == 0) {
            _executeActions(actions, Leg.HARVEST);
            return 0;
        }

        uint256[] memory pre = new uint256[](r);
        for (uint256 i; i < n;) {
            for (uint256 j; j < r;) {
                pre[j] = _balanceOf(rewards[j]);
                unchecked { ++j; }
            }

            _runAction(actions[i], Leg.HARVEST);

            for (uint256 j; j < r;) {
                uint256 post = _balanceOf(rewards[j]);
                if (post < pre[j]) {
                    unchecked {
                        outflowValue += ((pre[j] - post) * _freshPrice(rewards[j])) / 1e18;
                    }
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    struct CompoundingSnapshot {
        address asset;
        uint256 preBalance;
        uint256 yieldAmount;
        uint128 newPrice;
    }

    function _executeHarvest(Action[] calldata harvestActions) internal {
        try albOracle.poke() returns (bool) {} catch {
            emit OracleStaleWarning();
        }

        address[] memory pf = portfolio;
        uint256 n = pf.length;
        CompoundingSnapshot[] memory snaps = new CompoundingSnapshot[](n);
        uint256[] memory preBal = new uint256[](n);
        uint256 nSnaps;
        uint256 actualYieldValue;

        for (uint256 i; i < n;) {
            address tok = pf[i];
            uint256 bal = _balanceOf(tok);
            preBal[i] = bal;

            AssetEntry storage e = asset[tok];

            if (e.rewardMode == RewardMode.COMPOUNDING && e.targetBps != 0) {
                uint256 px = _freshPrice(tok);

                if (px > type(uint128).max) revert InvalidParams();
                uint128 last = e.lastRecordedPrice;
                if (last == 0) {
                    e.lastRecordedPrice = uint128(px);
                } else if (px > last) {
                    uint256 yieldAmount;
                    unchecked { yieldAmount = (bal * (px - last)) / px; }
                    if (yieldAmount > bal) yieldAmount = bal;
                    if (yieldAmount != 0) {
                        snaps[nSnaps] = CompoundingSnapshot({
                            asset: tok,
                            preBalance: bal,
                            yieldAmount: yieldAmount,
                            newPrice: uint128(px)
                        });
                        unchecked { ++nSnaps; }
                    } else {
                        e.lastRecordedPrice = uint128(px);
                    }
                }
            }
            unchecked { ++i; }
        }

        uint256 albBefore = alb.balanceOf(address(this));

        address[] memory toks = _trackedTokens();
        uint256[] memory stablePre = _balances(toks);
        uint256 stableBefore = _stableOnlyValueEmergency(toks, stablePre);

        uint256 rewardOutflowValue = _executeHarvestActions(harvestActions);

        _requireStableBalancesNotDrained(toks, stablePre);
        if (_stableOnlyValueEmergency(toks, _balances(toks)) < stableBefore) revert ToleranceBreach();
        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();

        for (uint256 i; i < n;) {
            address tok = pf[i];
            uint256 post = _balanceOf(tok);
            uint256 pre = preBal[i];
            uint256 expectedSale;
            uint128 newPx;
            for (uint256 j; j < nSnaps;) {
                if (snaps[j].asset == tok) {
                    expectedSale = snaps[j].yieldAmount;
                    newPx = snaps[j].newPrice;
                    break;
                }
                unchecked { ++j; }
            }
            uint256 sold = pre > post ? pre - post : 0;
            if (expectedSale == 0) {
                if (sold != 0) revert ToleranceBreach();
            } else {
                if (sold > expectedSale) revert ToleranceBreach();
                if (sold != 0) {
                    unchecked {
                        actualYieldValue += (sold * uint256(newPx)) / 1e18;

                        if (sold == expectedSale) {
                            asset[tok].lastRecordedPrice = newPx;
                        } else {
                            uint256 lastPx = asset[tok].lastRecordedPrice;
                            uint256 adv = pre > sold
                                ? (pre * lastPx) / (pre - sold)
                                : uint256(newPx);
                            if (adv > newPx) adv = newPx;
                            asset[tok].lastRecordedPrice = uint128(adv);
                        }
                    }
                }
            }
            unchecked { ++i; }
        }

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

    function _balances(address[] memory toks) internal view returns (uint256[] memory bals) {
        uint256 n = toks.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = _balanceOf(toks[i]);
            unchecked { ++i; }
        }
    }

    function _valueOfStrict(address[] memory toks, uint256[] memory bals)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            uint256 bal = bals[i];

            if (bal != 0) {
                unchecked { total += (bal * _assetPrice(toks[i])) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _portfolioValueEmergency(address[] memory toks, uint256[] memory bals)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            if (asset[tok].exists) {
                unchecked { total += (bals[i] * _priceOrZero(tok)) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _stableOnlyValueEmergency(address[] memory toks, uint256[] memory bals)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            if (!asset[tok].exists) {
                unchecked { total += (bals[i] * _priceOrZero(tok)) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _valueExcluding(address[] memory toks, uint256[] memory bals, address skip)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            if (tok != skip) {
                unchecked { total += (bals[i] * _priceOrZero(tok)) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _stableOnlyValue() internal view returns (uint256 total) {
        address[] memory st = stableList;
        uint256 n = st.length;
        for (uint256 i; i < n;) {
            address tok = st[i];
            if (!asset[tok].exists) {
                uint256 bal = _balanceOf(tok);
                if (bal != 0) {
                    unchecked { total += (bal * _freshPrice(tok)) / 1e18; }
                }
            }
            unchecked { ++i; }
        }
    }

    function _grossOutflowValue(address[] memory toks, uint256[] memory pre)
        internal
        view
        returns (uint256 total)
    {
        uint256 n = toks.length;
        for (uint256 i; i < n;) {
            address tok = toks[i];
            uint256 post = _balanceOf(tok);
            if (post < pre[i]) {
                unchecked { total += ((pre[i] - post) * _assetPrice(tok)) / 1e18; }
            }
            unchecked { ++i; }
        }
    }

    function _requireStableBalancesNotDrained(address[] memory toks, uint256[] memory pre)
        internal
        view
    {
        uint256 n = toks.length;
        for (uint256 i; i < n && i < pre.length;) {
            address tok = toks[i];
            if (!asset[tok].exists && _balanceOf(tok) < pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _requireUnpricedNotDrained(
        address[] memory toks,
        uint256[] memory pre,
        uint256[] memory post
    ) internal view {
        toks; pre; post;
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

    function _requireRewardBalancesUnchanged(uint256[] memory pre) internal view {
        address[] memory rewards = rewardList;
        uint256 n = rewards.length;
        for (uint256 i; i < n && i < pre.length;) {
            if (_balanceOf(rewards[i]) != pre[i]) revert ToleranceBreach();
            unchecked { ++i; }
        }
    }

    function _balanceOf(address tok) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(tok, address(this));
    }
}

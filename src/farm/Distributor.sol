// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {DistributorIO, DistributorLogic} from "./DistributorLogic.sol";

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

contract Distributor is OwnableRoles, ReentrancyGuardTransient {
    uint256 public constant ROLE_ADMIN = 1 << 0;

    using SafeTransferLib for address;

    uint256 public constant MAX_STREAMS_PER_POOL = DistributorIO.MAX_STREAMS_PER_POOL;
    /// @notice Fixed for every pool; the legacy per-pool parameter is retired.
    uint64 public constant HARVEST_INTERVAL = 30 seconds;
    uint16 public constant MAXIMUM_FUND_FEE_BPS = 2000;
    /// @notice Delay before a scheduled MintRights INCREASE may be applied.
    uint64 public constant MINT_RIGHTS_DELAY = DistributorIO.MINT_RIGHTS_DELAY;
    uint64 public constant MINT_RIGHTS_WINDOW = DistributorIO.MINT_RIGHTS_WINDOW;
    uint256 public constant PAYOUT_GAS_CAP = DistributorIO.PAYOUT_GAS_CAP;
    uint256 public constant HARVEST_PAYOUT_GAS = DistributorIO.HARVEST_PAYOUT_GAS;
    uint256 public constant VIEW_GAS_CAP = DistributorIO.VIEW_GAS_CAP;

    enum PoolKind { DEPOSIT, HOOK }
    enum StreamKind { MINT, PULL, BALANCE }

    struct PoolInfo {
        address stakeToken;
        PoolKind kind;
        uint256 totalStaked;
    }

    struct Stream {
        address token;
        StreamKind kind;
        bool active;
        uint64 lastUpdate;
        uint16 fundFeeBps;
        address source;
        uint128 ratePerSec;
        uint64 emissionEnd;
        uint32 generation;
        uint32 epochLength;
        uint256 reserve;
        uint256 accPerShare;
        uint256 owed;
        uint16 pullMaxFeeBps;
        uint128 pullMaxPerSec;
        uint32 pullMaxWindow;
        uint256 pullFeeCredit;
        uint256 pullFeePaid;
        uint256 pullNet;
    }

    struct UserInfo {
        uint192 amount;
        uint64 nextHarvestUntil;
    }

    /// @notice Fixed-period budget; top-ups wait for the next epoch.
    struct StreamEpoch {
        uint64 length;
        uint64 start;
        uint256 budget;
        /// @dev Maximum source pull per epoch; zero uses the available balance and allowance.
        uint256 pullAmount;
    }

    struct EpochConfig {
        uint64 pendingLength;
        uint192 minBudget;
    }

    PoolInfo[] internal _pools;
    mapping(uint256 => Stream[]) internal _streams;
    mapping(uint256 => mapping(address => UserInfo)) internal _users;
    /// @dev Hook pools used to reconcile intermediary shares.
    uint256[] internal _hookPids;

    /// @dev pid => user => stream index.
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public rewardDebt;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public rewardLockedUp;

    mapping(address => uint256) public totalStakedOf;
    mapping(address => uint256) public unsweptResidual;

    /// @dev token => pid + 1 (0 = not a hook token). One hook pool per token.
    mapping(address => uint256) public hookPoolOf;
    /// @dev Deposit pool count per token; DEPOSIT and HOOK registration are mutually exclusive.
    mapping(address => uint256) public depositPoolsOf;
    /// @notice Only the source can authorize or revoke PULL funding.
    mapping(address => bool) public isPullSource;
    mapping(address => bool) public isIntermediary;

    mapping(address => bool) public isRewardToken;

    address public feeRecipient;
    bool public depositsPaused;

    mapping(uint256 => mapping(uint256 => StreamEpoch)) public streamEpochs;

    mapping(uint256 => mapping(uint256 => address)) public streamManager;

    /// @notice Stream generation; replacement invalidates debt and locked rewards from older generations.
    mapping(uint256 => mapping(address => mapping(uint256 => uint32))) public userStreamGen;

    /// @notice Aggregate MINT rate cap per token; increases are timelocked.
    mapping(address => uint256) public mintRights;
    /// @notice Current aggregate configured MINT rate per token.
    mapping(address => uint256) public mintRateOf;

    struct PendingRights {
        uint192 value;
        uint64 executableAt;
    }
    mapping(address => PendingRights) public pendingMintRights;

    mapping(uint256 => mapping(uint256 => EpochConfig)) public streamEpochConfig;

    event PoolAdded(uint256 indexed pid, address indexed stakeToken, PoolKind kind);
    event DepositRegistrationCleared(address indexed token);
    event StreamAdded(
        uint256 indexed pid, uint256 indexed index, address indexed token, StreamKind kind, address source, address manager, uint16 fundFeeBps
    );
    event StreamManagerSet(uint256 indexed pid, uint256 indexed index, address manager);
    event StreamFundFeeSet(uint256 indexed pid, uint256 indexed index, uint16 fundFeeBps);
    event StreamReplaced(
        uint256 indexed pid, uint256 indexed index, address oldToken, address newToken, StreamKind kind, uint256 residualSwept
    );
    event ResidualSwept(address indexed token, address indexed to, uint256 amount);
    event MintRightsScheduled(address indexed token, uint256 value, uint64 executableAt);
    event MintRightsScheduleCancelled(address indexed token);
    event MintRightsSet(address indexed token, uint256 value);
    event StreamRateSet(uint256 indexed pid, uint256 indexed index, uint128 ratePerSec, uint64 emissionEnd);
    event StreamActiveSet(uint256 indexed pid, uint256 indexed index, bool active);
    event StreamFunded(uint256 indexed pid, uint256 indexed index, address indexed from, uint256 net, uint256 fee, uint64 emissionEnd);
    event StreamReserveRecovered(uint256 indexed pid, uint256 indexed index, address to, uint256 amount);
    event StreamEpochLengthSet(uint256 indexed pid, uint256 indexed index, uint64 length);
    event StreamEpochLengthQueued(uint256 indexed pid, uint256 indexed index, uint64 length);
    event StreamEpochPullSet(uint256 indexed pid, uint256 indexed index, uint256 amount);
    event StreamEpochMinBudgetSet(uint256 indexed pid, uint256 indexed index, uint256 minBudget);
    event StreamEpochStarted(
        uint256 indexed pid, uint256 indexed index, uint256 budget, uint128 ratePerSec, uint64 emissionEnd
    );
    /// @dev Unfunded MINT/PULL rewards are forfeited.
    event StreamShortfall(uint256 indexed pid, uint256 indexed index, uint256 wanted, uint256 got);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, address indexed token, uint256 amount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, address indexed token, uint256 amount);
    event StakeSynced(uint256 indexed pid, address indexed user, uint256 previous, uint256 current);
    event IntermediarySet(address indexed account, bool allowed);
    event PullSourceSet(address indexed source, bool consented);
    event PullTermsSet(
        uint256 indexed pid,
        uint256 indexed index,
        address indexed source,
        uint16 maxFeeBps,
        uint128 maxPerSec,
        uint32 maxWindow
    );
    event FeeTransferFailed(address indexed token, uint256 amount);
    event StakeStripped(uint256 indexed pid, address indexed account, uint256 amount);
    event RewardDeferred(uint256 indexed pid, address indexed user, address indexed token, uint256 amount);
    event FeeRecipientSet(address indexed recipient);
    event DepositsPaused(bool paused);
    event RewardShortfall(address indexed token, address indexed user, uint256 owed, uint256 paid);

    error ZeroAddress();
    error UnknownPool();
    error UnknownStream();
    error StreamCapReached();
    error InvalidParams();
    error WrongPoolKind();
    error WrongStreamKind();
    error NotHookToken();
    error TokenAlreadyPooled();
    error HookTokenCannotBeReward();
    error RewardTokenCannotBeHook();
    error InsufficientStake();
    error DepositsArePaused();
    error NothingToDo();
    error PullSourceNotConsented();
    error TokenIsDepositStake();
    error EpochInProgress();
    error EpochRateIsDerived();
    error MintRightsExceeded();
    error FeeTooHigh();
    error NothingScheduled();
    error TimelockNotElapsed();
    error ScheduleExpired();
    error BudgetBelowMinimum();
    error NonZeroStake();
    error BalanceReadFailed();

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    constructor(address owner_, address feeRecipient_) {
        if (owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        feeRecipient = feeRecipient_;
    }

    function renounceOwnership() public payable override onlyOwner {
        revert("Distributor: ownership required");
    }

    function poolLength() external view returns (uint256) {
        return _pools.length;
    }

    /// @notice Legacy tuple; allocation, timestamp, and accumulator fields return zero.
    function poolInfo(uint256 pid)
        external
        view
        returns (
            address lpToken,
            uint256 allocPoint,
            uint256 lastRewardTimestamp,
            uint256 accAlbPerShare,
            uint16 depositFeeBP,
            uint256 harvestInterval,
            uint256 totalLp
        )
    {
        PoolInfo storage p = _pools[pid];
        return (p.stakeToken, 0, 0, 0, 0, HARVEST_INTERVAL, p.totalStaked);
    }

    /// @notice Legacy tuple; read rewardDebt and rewardLockedUp per stream.
    function userInfo(uint256 pid, address user)
        external
        view
        returns (uint256 amount, uint256 rewardDebt_, uint256 rewardLockedUp_, uint256 nextHarvestUntil)
    {
        UserInfo storage u = _users[pid][user];
        return (u.amount, 0, 0, u.nextHarvestUntil);
    }

    function poolTotalLp(uint256 pid) external view returns (uint256) {
        return _pools[pid].totalStaked;
    }

    function canHarvest(uint256 pid, address user) public view returns (bool) {
        return block.timestamp >= _users[pid][user].nextHarvestUntil;
    }

    /// @notice One entry per stream. Includes locked-up rewards.
    function pendingTokens(uint256 pid, address user)
        external
        view
        returns (address[] memory addresses, string[] memory symbols, uint256[] memory decimals, uint256[] memory amounts)
    {
        if (pid >= _pools.length) revert UnknownPool();
        bytes memory out = DistributorLogic.pendingTokens(
            _streams[pid],
            streamEpochs[pid],
            rewardDebt[pid][user],
            rewardLockedUp[pid][user],
            userStreamGen[pid][user],
            _users[pid][user].amount,
            _pools[pid].totalStaked
        );
        (addresses, symbols, decimals, amounts);
        assembly ("memory-safe") { return(add(out, 0x20), mload(out)) }
    }

    /// @notice Rates rounded to base units; zero when inactive or expired.
    function poolRewardsPerSec(uint256 pid)
        external
        view
        returns (address[] memory addresses, string[] memory symbols, uint256[] memory decimals, uint256[] memory rewardsPerSec)
    {
        if (pid >= _pools.length) revert UnknownPool();
        bytes memory out = DistributorLogic.poolRewardsPerSec(_streams[pid]);
        (addresses, symbols, decimals, rewardsPerSec);
        assembly ("memory-safe") { return(add(out, 0x20), mload(out)) }
    }

    function poolKind(uint256 pid) external view returns (PoolKind) {
        return _pools[pid].kind;
    }

    function streamLength(uint256 pid) external view returns (uint256) {
        return _streams[pid].length;
    }

    function streamInfo(uint256 pid, uint256 index) external view returns (Stream memory) {
        bytes memory out = DistributorLogic.streamInfo(_streams[pid], index);
        assembly ("memory-safe") { return(add(out, 0x20), mload(out)) }
    }

    /// @notice Create a staking venue. Admin-level: an empty pool earns nothing (value
    /// only attaches through streams, which carry their own gates — MintRights, PULL
    /// binding and source terms, funded reserves), HOOK registration requires the
    /// token's own distributor() opt-in, and the once-irreversible DEPOSIT/HOOK
    /// exclusion mark is now clearable by the Owner (clearDepositRegistration) — so
    /// community farms open at ops speed instead of timelock speed.
    function addPool(address stakeToken, PoolKind kind)
        external
        onlyOwnerOrRoles(ROLE_ADMIN)
        returns (uint256 pid)
    {
        pid = DistributorLogic.addPool(_pools, _hookPids, hookPoolOf, depositPoolsOf, isRewardToken, stakeToken, kind);
    }

    /// @notice Clear a token's DEPOSIT-stake registration so it may later become a HOOK
    /// token. Only while NOTHING of it is custodied: a hook token's transfers revert
    /// inside this farm's custody flows (reentrancy guard), so a DEPOSIT pool of a hook
    /// token would strand principal — the zero-staked requirement is what makes clearing
    /// safe (its old pools remain registered but any future deposit into them reverts
    /// atomically at the token's own hook). After clearing, `depositPoolsOf` is an
    /// exclusion flag, not an exact pool count.
    function clearDepositRegistration(address token) external onlyOwner {
        DistributorLogic.clearDepositRegistration(totalStakedOf, depositPoolsOf, token);
    }

    function setIntermediary(address account, bool allowed) external nonReentrant {
        if (allowed) _checkOwnerOrRoles(ROLE_ADMIN);
        else _checkOwner();
        if (account == address(0)) revert ZeroAddress();
        if (allowed && !isIntermediary[account]) {
            uint256 n = _hookPids.length;
            for (uint256 i; i < n;) {
                uint256 pid = _hookPids[i];
                uint256 amt = _users[pid][account].amount;
                if (amt != 0) {
                    _updatePool(pid);
                    _settle(pid, account, amt, 0, true);
                    _users[pid][account].amount = 0;
                    _pools[pid].totalStaked -= amt;
                    emit StakeStripped(pid, account, amt);
                }
                unchecked { ++i; }
            }
        }
        isIntermediary[account] = allowed;
        emit IntermediarySet(account, allowed);
    }

    function setPullSource(bool consented) external {
        isPullSource[msg.sender] = consented;
        emit PullSourceSet(msg.sender, consented);
    }

    function setPullTerms(uint256 pid, uint256 index, uint16 maxFeeBps, uint128 maxPerSec, uint32 maxWindow)
        external
        nonReentrant
    {
        Stream storage s = _stream(pid, index);
        if (s.kind != StreamKind.PULL || s.source != msg.sender) revert InvalidParams();
        _updatePool(pid);
        DistributorLogic.applyPullTerms(pid, index, s, maxFeeBps, maxPerSec, maxWindow);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setDepositsPaused(bool paused_) external {
        if (paused_) _checkOwnerOrRoles(ROLE_ADMIN);
        else _checkOwner();
        depositsPaused = paused_;
        emit DepositsPaused(paused_);
    }

    function _checkOwnerOrManager(uint256 pid, uint256 index) internal view {
        if (msg.sender != streamManager[pid][index]) _checkOwner();
    }

    function _isStreamOperator(uint256 pid, uint256 index) internal view returns (bool) {
        return msg.sender == owner() || hasAnyRole(msg.sender, ROLE_ADMIN) || msg.sender == streamManager[pid][index];
    }

    function addStream(uint256 pid, address token, StreamKind kind, address source, address manager, uint16 fundFeeBps_)
        external
        onlyOwnerOrRoles(ROLE_ADMIN)
        nonReentrant
        returns (uint256 index)
    {
        if (pid >= _pools.length) revert UnknownPool();
        _validateStreamConfig(token, kind, source, fundFeeBps_);
        _updatePool(pid);
        index = DistributorLogic.addStream(_streams[pid], pid, token, kind, source, manager, fundFeeBps_);
        isRewardToken[token] = true;
        if (manager != address(0)) streamManager[pid][index] = manager;
    }

    function _validateStreamConfig(address token, StreamKind kind, address source, uint16 fundFeeBps_) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert InvalidParams();
        if (hookPoolOf[token] != 0) revert HookTokenCannotBeReward();
        if (fundFeeBps_ > MAXIMUM_FUND_FEE_BPS) revert InvalidParams();
        if (kind == StreamKind.PULL) {
            // Binding is inert: a stream draws NOTHING until its source accepts terms
            // for this exact incarnation (setPullTerms, fail-closed). The source's
            // per-stream acceptance is the real consent, so binding sits with Admin.
            if (source == address(0)) revert ZeroAddress();
            if (!isPullSource[source]) revert PullSourceNotConsented();
        }
    }

    function setStreamFundFee(uint256 pid, uint256 index, uint16 fundFeeBps_)
        external
        onlyOwnerOrRoles(ROLE_ADMIN)
        nonReentrant
    {
        Stream storage s = _stream(pid, index);
        _updatePool(pid);
        DistributorLogic.applyFundFee(pid, index, s, fundFeeBps_);
    }

    /// @notice Owner may reassign; a manager may hand over (or renounce) their own stream.
    function setStreamManager(uint256 pid, uint256 index, address manager) external nonReentrant {
        _stream(pid, index);
        _checkOwnerOrManager(pid, index);
        streamManager[pid][index] = manager;
        emit StreamManagerSet(pid, index, manager);
    }

    function replaceStream(
        uint256 pid,
        uint256 index,
        address token,
        StreamKind kind,
        address source,
        address manager,
        uint16 fundFeeBps_,
        address residualTo
    ) external onlyOwner nonReentrant {
        if (residualTo == address(0)) revert ZeroAddress();
        Stream storage s = _stream(pid, index);
        _validateStreamConfig(token, kind, source, fundFeeBps_);
        _updatePool(pid);
        delete streamEpochs[pid][index];
        delete streamEpochConfig[pid][index];
        streamManager[pid][index] = manager;
        isRewardToken[token] = true;
        DistributorLogic.replaceStream(
            pid, index, s, token, kind, source, fundFeeBps_, residualTo, mintRateOf, totalStakedOf, unsweptResidual
        );
    }

    function sweepResidual(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        DistributorLogic.sweepResidual(unsweptResidual, totalStakedOf, token, to, amount);
    }

    function setMintRights(address token, uint256 value) external onlyOwner {
        DistributorLogic.setMintRights(mintRights, pendingMintRights, token, value);
    }

    function scheduleMintRights(address token, uint256 value) external onlyOwner {
        DistributorLogic.scheduleMintRights(pendingMintRights, token, value);
    }

    /// @notice Enact a matured rights schedule. Under timelock ownership this is the
    /// second of two timelock rounds; MINT_RIGHTS_WINDOW (14 days) is sized so it never
    /// races a 7-day minDelay even when the rounds run fully serially.
    function applyMintRights(address token) external onlyOwner {
        DistributorLogic.applyMintRights(mintRights, pendingMintRights, token);
    }

    /// @notice Cancel a pending rights schedule. Admin-level: cancelling only narrows,
    /// and it is the instant emergency lever against a mistaken or hostile schedule —
    /// necessary because under timelock ownership every Owner response takes minDelay.
    function cancelMintRights(address token) external {
        _checkOwnerOrRoles(ROLE_ADMIN);
        DistributorLogic.cancelMintRights(pendingMintRights, token);
    }

    function setStreamRate(uint256 pid, uint256 index, uint128 ratePerSec) external nonReentrant {
        Stream storage s = _stream(pid, index);
        if (s.epochLength != 0) revert EpochRateIsDerived();
        if (s.kind == StreamKind.MINT) {
            _checkOwnerOrRoles(ROLE_ADMIN);
            uint256 old = s.ratePerSec;
            uint256 agg = mintRateOf[s.token] - old + ratePerSec;
            if (ratePerSec > old && agg > mintRights[s.token]) revert MintRightsExceeded();
            mintRateOf[s.token] = agg;
        } else if (msg.sender != streamManager[pid][index]) {
            if (s.kind != StreamKind.BALANCE || ratePerSec >= s.ratePerSec) _checkOwner();
            else _checkOwnerOrRoles(ROLE_ADMIN);
        }
        _updatePool(pid);
        DistributorLogic.applyRate(pid, index, s, ratePerSec);
    }

    function setStreamEpochLength(uint256 pid, uint256 index, uint64 length) external nonReentrant {
        Stream storage s = _stream(pid, index);
        _checkOwnerOrManager(pid, index);
        _updatePool(pid);
        bool tryStart = DistributorLogic.setEpochLength(
            pid, index, s, streamEpochs[pid][index], streamEpochConfig[pid][index], length
        );
        if (tryStart) _tryStartStreamEpoch(pid, index);
    }

    /// @notice Source pull cap for subsequent epochs; zero uses the available balance and allowance.
    function setStreamEpochPull(uint256 pid, uint256 index, uint256 amount) external nonReentrant {
        Stream storage s = _stream(pid, index);
        _checkOwnerOrManager(pid, index);
        if (s.kind != StreamKind.PULL) revert WrongStreamKind();
        streamEpochs[pid][index].pullAmount = amount;
        emit StreamEpochPullSet(pid, index, amount);
    }

    function setStreamEpochMinBudget(uint256 pid, uint256 index, uint256 minBudget) external nonReentrant {
        Stream storage s = _stream(pid, index);
        _checkOwnerOrManager(pid, index);
        if (s.kind == StreamKind.MINT) revert WrongStreamKind();
        streamEpochConfig[pid][index].minBudget = SafeCastLib.toUint192(minBudget);
        emit StreamEpochMinBudgetSet(pid, index, minBudget);
    }

    function startStreamEpoch(uint256 pid, uint256 index) external nonReentrant {
        Stream storage s = _stream(pid, index);
        _updatePool(pid);
        _startStreamEpoch(pid, index, s, !_isStreamOperator(pid, index));
    }

    function setStreamActive(uint256 pid, uint256 index, bool active) external nonReentrant {
        Stream storage s = _stream(pid, index);
        if (active && s.kind == StreamKind.MINT) {
            _checkOwner();
        } else if (msg.sender != streamManager[pid][index]) {
            if (active) _checkOwner();
            else _checkOwnerOrRoles(ROLE_ADMIN);
        }
        _updatePool(pid);
        DistributorLogic.applyActive(pid, index, s, active);
    }

    function recoverStreamReserve(uint256 pid, uint256 index, address to, uint256 amount)
        external
        nonReentrant
    {
        Stream storage s = _stream(pid, index);
        _checkOwnerOrManager(pid, index);
        _updatePool(pid);
        DistributorLogic.recoverReserve(pid, index, s, streamEpochs[pid][index], totalStakedOf, to, amount);
    }

    function fundStream(uint256 pid, uint256 index, uint256 amount) external nonReentrant {
        _fundStream(pid, index, amount, MAXIMUM_FUND_FEE_BPS);
    }

    /// @notice Fund only if the stream fee is at most maxFeeBps.
    function fundStream(uint256 pid, uint256 index, uint256 amount, uint16 maxFeeBps) external nonReentrant {
        _fundStream(pid, index, amount, maxFeeBps);
    }

    function _fundStream(uint256 pid, uint256 index, uint256 amount, uint16 maxFeeBps) internal {
        Stream storage s = _stream(pid, index);
        if (s.fundFeeBps > maxFeeBps) revert FeeTooHigh();

        if (s.kind != StreamKind.BALANCE) revert WrongStreamKind();
        if (amount == 0) revert NothingToDo();

        _updatePool(pid);

        address t = s.token;
        uint256 before = _selfBalanceStrict(t);
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = _selfBalanceStrict(t) - before;

        uint256 fee = (received * s.fundFeeBps) / 10_000;
        uint256 net = received - fee;
        if (fee != 0) t.safeTransfer(feeRecipient, fee);

        s.reserve += net;
        if (s.epochLength == 0) {
            DistributorIO.recomputeEnd(s);
        } else if (_autoStartDue(pid, index, s, net)) {
            _startStreamEpoch(pid, index, s, false);
        }
        emit StreamFunded(pid, index, msg.sender, net, fee, s.emissionEnd);
    }

    function _autoStartDue(uint256 pid, uint256 index, Stream storage s, uint256 added) internal view returns (bool) {
        uint256 minimum = streamEpochConfig[pid][index].minBudget;
        return s.active && block.timestamp >= s.emissionEnd && added != 0
            && s.reserve >= minimum && (minimum != 0 || _isStreamOperator(pid, index));
    }

    function depositWithPermit(uint256 pid, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        if (pid >= _pools.length) revert UnknownPool();

        try IERC20Permit(_pools[pid].stakeToken).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _deposit(pid, amount);
    }

    /// @notice Deposit 0 to harvest, as in the legacy contract.
    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        if (pid >= _pools.length) revert UnknownPool();
        _deposit(pid, amount);
    }

    function _deposit(uint256 pid, uint256 amount) internal {
        if (depositsPaused) revert DepositsArePaused();
        PoolInfo storage p = _pools[pid];
        if (p.kind != PoolKind.DEPOSIT) revert WrongPoolKind();

        _updatePool(pid);

        UserInfo storage u = _users[pid][msg.sender];
        uint256 cur = u.amount;
        uint256 received;

        if (amount != 0) {
            address stake = p.stakeToken;
            uint256 before = _selfBalanceStrict(stake);
            stake.safeTransferFrom(msg.sender, address(this), amount);

            received = _selfBalanceStrict(stake) - before;

            p.totalStaked += received;
            totalStakedOf[stake] += received;
        }

        _settle(pid, msg.sender, cur, cur + received, false);
        u.amount = SafeCastLib.toUint192(cur + received);
        emit Deposit(msg.sender, pid, received);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        if (pid >= _pools.length) revert UnknownPool();
        PoolInfo storage p = _pools[pid];
        if (p.kind != PoolKind.DEPOSIT) revert WrongPoolKind();

        UserInfo storage u = _users[pid][msg.sender];
        uint256 cur = u.amount;
        if (amount > cur) revert InsufficientStake();

        _updatePool(pid);

        uint256 next = cur - amount;
        _settle(pid, msg.sender, cur, next, false);
        u.amount = uint192(next);

        if (amount != 0) {
            address stake = p.stakeToken;
            p.totalStaked -= amount;
            totalStakedOf[stake] -= amount;
            stake.safeTransfer(msg.sender, amount);
        }
        emit Withdraw(msg.sender, pid, amount);
    }

    function emergencyWithdraw(uint256 pid) external nonReentrant {
        DistributorLogic.emergencyWithdraw(
            _pools, _users, _streams, rewardDebt, rewardLockedUp, totalStakedOf, pid
        );
    }

    function harvestMany(uint256[] calldata pids) external nonReentrant {
        for (uint256 i; i < pids.length;) {
            uint256 pid = pids[i];
            if (pid >= _pools.length) revert UnknownPool();
            _updatePool(pid);
            uint256 cur = _users[pid][msg.sender].amount;
            _settle(pid, msg.sender, cur, cur, false);
            unchecked { ++i; }
        }
    }

    function _hookPid() internal view returns (uint256 pid) {
        uint256 slot = hookPoolOf[msg.sender];
        if (slot == 0) revert NotHookToken();
        unchecked { pid = slot - 1; }
    }

    /// @notice Called by the registered token when `user` gains `amount` of it.
    function notifyStake(address user, uint256 amount) external nonReentrant {
        _notifyStake(_hookPid(), user, amount);
    }

    function notifyUnstake(address user, uint256 amount) external nonReentrant {
        _notifyUnstake(_hookPid(), user, amount);
    }

    function notifyDeposit(address user, uint256 amount) external nonReentrant {
        _notifyStake(_hookPid(), user, amount);
    }

    function notifyWithdraw(address user, uint256 amount) external nonReentrant {
        _notifyUnstake(_hookPid(), user, amount);
    }

    /// @notice Pull escrow penalties into the matching BALANCE stream without a funding fee.
    /// @dev Register the stream before enabling early exits.
    function notifyReward(address token, uint256 amount) external nonReentrant {
        uint256 pid = _hookPid();
        if (amount == 0) revert NothingToDo();
        Stream[] storage ss = _streams[pid];
        uint256 n = ss.length;
        uint256 idx = type(uint256).max;
        for (uint256 i; i < n;) {
            Stream storage c = ss[i];
            if (c.token == token && c.kind == StreamKind.BALANCE) { idx = i; break; }
            unchecked { ++i; }
        }
        if (idx == type(uint256).max) revert UnknownStream();
        Stream storage st = ss[idx];

        _updatePool(pid);

        uint256 before = _selfBalanceStrict(token);
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = _selfBalanceStrict(token) - before;

        st.reserve += received;
        if (st.epochLength == 0) {
            DistributorIO.recomputeEnd(st);
        } else if (_autoStartDue(pid, idx, st, received)) {
            _startStreamEpoch(pid, idx, st, false);
        }
        emit StreamFunded(pid, idx, msg.sender, received, 0, st.emissionEnd);
    }

    function _notifyStake(uint256 pid, address user, uint256 amount) internal {
        if (isIntermediary[user] || user == address(0) || user == address(this) || amount == 0) return;

        _updatePool(pid);
        UserInfo storage u = _users[pid][user];
        uint256 cur = u.amount;
        uint256 next = cur + amount;
        _settle(pid, user, cur, next, true);
        u.amount = SafeCastLib.toUint192(next);
        _pools[pid].totalStaked += amount;
    }

    function _notifyUnstake(uint256 pid, address user, uint256 amount) internal {
        if (isIntermediary[user] || user == address(0) || user == address(this) || amount == 0) return;

        _updatePool(pid);
        UserInfo storage u = _users[pid][user];
        uint256 cur = u.amount;
        uint256 dec = amount > cur ? cur : amount;
        if (dec == 0) return;
        uint256 next = cur - dec;
        _settle(pid, user, cur, next, true);
        u.amount = uint192(next);
        _pools[pid].totalStaked -= dec;
    }

    function syncStake(uint256 pid, address user) external nonReentrant {
        if (pid >= _pools.length) revert UnknownPool();
        PoolInfo storage p = _pools[pid];
        if (p.kind != PoolKind.HOOK) revert WrongPoolKind();
        if (isIntermediary[user] || user == address(0) || user == address(this)) revert InvalidParams();

        _updatePool(pid);
        UserInfo storage u = _users[pid][user];
        uint256 cur = u.amount;
        uint256 real = _hookGroundTruth(p.stakeToken, user);
        if (real == cur) revert NothingToDo();

        _settle(pid, user, cur, real, true);
        u.amount = SafeCastLib.toUint192(real);
        p.totalStaked = p.totalStaked - cur + real;
        emit StakeSynced(pid, user, cur, real);
    }

    function _hookGroundTruth(address token, address user) internal view returns (uint256) {
        (bool ok, uint256 v) = DistributorIO.read1(token, DistributorIO.SEL_IS_HOOK_EXEMPT, user, VIEW_GAS_CAP);
        if (ok && v != 0) return 0;
        (ok, v) = DistributorIO.read1(token, DistributorIO.SEL_STAKED_SHARES_OF, user, VIEW_GAS_CAP);
        if (ok) return v;
        (ok, v) = DistributorIO.read1(token, DistributorIO.SEL_BALANCE_OF, user, VIEW_GAS_CAP);
        if (!ok) revert BalanceReadFailed();
        return v;
    }

    function updatePool(uint256 pid) external nonReentrant {
        if (pid >= _pools.length) revert UnknownPool();
        _updatePool(pid);
    }

    /// @notice Update all pools; use the ranged overload for large pool lists.
    function massUpdatePools() external nonReentrant {
        uint256 n = _pools.length;
        for (uint256 i; i < n;) {
            _updatePool(i);
            unchecked { ++i; }
        }
    }

    /// @notice Update pools [start, end); `end` is clamped to the pool count.
    function massUpdatePools(uint256 start, uint256 end) external nonReentrant {
        uint256 n = _pools.length;
        if (end > n) end = n;
        for (uint256 i = start; i < end;) {
            _updatePool(i);
            unchecked { ++i; }
        }
    }

    /// @notice Pids of all HOOK pools (the set setIntermediary walks).
    function hookPids() external view returns (uint256[] memory) {
        return _hookPids;
    }

    function _updatePool(uint256 pid) internal {
        PoolInfo storage p = _pools[pid];
        Stream[] storage ss = _streams[pid];
        uint256 n = ss.length;
        if (n == 0) return;

        uint256 supply = p.totalStaked;
        uint64 nowTs = uint64(block.timestamp);

        for (uint256 i; i < n;) {
            Stream storage s = ss[i];
            if (nowTs > s.lastUpdate && s.active) {
                uint256 want = DistributorIO.wanted(s, streamEpochs[pid][i]);
                if (want != 0 && supply != 0) {
                    bool reserveBacked = s.kind == StreamKind.BALANCE || s.epochLength != 0;
                    uint256 got = reserveBacked ? want : _realise(s, want);
                    if (!reserveBacked && s.kind == StreamKind.PULL) {
                        unchecked { want -= (want * s.fundFeeBps) / 10_000; }
                    }
                    if (got < want) emit StreamShortfall(pid, i, want, got);
                    if (got != 0) {
                        if (reserveBacked) s.reserve -= got;
                        s.owed += got;
                        s.accPerShare += FixedPointMathLib.fullMulDiv(got, DistributorIO.ACC_PRECISION, supply);
                    }
                }

                s.lastUpdate = nowTs;
            }
            unchecked { ++i; }
        }
    }

    function _realise(Stream storage s, uint256 want) internal returns (uint256 got) {
        address t = s.token;
        StreamKind kind = s.kind;

        if (kind == StreamKind.BALANCE) return want;

        (bool ok, uint256 before) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, address(this), VIEW_GAS_CAP);
        if (!ok) return 0;

        if (kind == StreamKind.MINT) {
            uint256 cap = _readUint(t, DistributorIO.SEL_MAX_SUPPLY);
            if (cap != 0) {
                uint256 ts = _readUint(t, DistributorIO.SEL_TOTAL_SUPPLY);
                uint256 remaining = cap > ts ? cap - ts : 0;
                if (want > remaining) want = remaining;
            }
            if (want == 0) return 0;
            DistributorIO.tryMint(t, address(this), want, DistributorIO.REALISE_GAS_CAP);
        } else {
            address src = s.source;
            if (!isPullSource[src]) return 0;
            uint256 avail;
            (ok, avail) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, src, VIEW_GAS_CAP);
            if (!ok) return 0;
            uint256 allowance_ = DistributorIO.allowance(t, src);
            if (allowance_ < avail) avail = allowance_;
            if (want > avail) want = avail;
            if (want == 0) return 0;
            DistributorIO.tryTransferFrom(t, src, address(this), want, DistributorIO.REALISE_GAS_CAP);
        }

        uint256 afterBal;
        (ok, afterBal) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, address(this), VIEW_GAS_CAP);
        if (!ok || afterBal <= before) return 0;
        got = afterBal - before;
        if (got > want) got = want;

        if (kind == StreamKind.PULL) {
            uint256 fee = (got * s.fundFeeBps) / 10_000;
            if (fee != 0) {
                if (DistributorIO.tryTransfer(t, feeRecipient, fee, PAYOUT_GAS_CAP)) got -= fee;
                else emit FeeTransferFailed(t, fee);
            }
        }
    }

    /// @dev Return zero on failure or invalid return length.
    function _readUint(address target, bytes4 sel) internal view returns (uint256 v) {
        (, v) = DistributorIO.read0(target, sel, VIEW_GAS_CAP);
    }

    function _selfBalanceStrict(address token) internal view returns (uint256 bal) {
        bool ok;
        (ok, bal) = DistributorIO.read1(token, DistributorIO.SEL_BALANCE_OF, address(this), gasleft());
        if (!ok) revert BalanceReadFailed();
    }

    function _settle(uint256 pid, address user, uint256 oldAmount, uint256 newAmount, bool cappedPayout) internal {
        UserInfo storage u = _users[pid][user];
        Stream[] storage ss = _streams[pid];
        uint256 n = ss.length;

        if (u.nextHarvestUntil == 0) u.nextHarvestUntil = uint64(block.timestamp) + HARVEST_INTERVAL;
        uint256 budget;
        if (block.timestamp >= u.nextHarvestUntil) budget = cappedPayout ? PAYOUT_GAS_CAP : HARVEST_PAYOUT_GAS;
        bool paidAny;

        for (uint256 i; i < n;) {
            if (_settleStream(pid, user, i, ss[i], oldAmount, newAmount, budget)) paidAny = true;
            unchecked { ++i; }
        }

        if (paidAny) u.nextHarvestUntil = uint64(block.timestamp) + HARVEST_INTERVAL;
    }

    function _settleStream(
        uint256 pid,
        address user,
        uint256 i,
        Stream storage s,
        uint256 oldAmount,
        uint256 newAmount,
        uint256 budget
    ) internal returns (bool paidSome) {
        uint32 gen = s.generation;
        bool stale = gen != 0 && userStreamGen[pid][user][i] != gen;
        if (stale) {
            if (rewardLockedUp[pid][user][i] != 0) rewardLockedUp[pid][user][i] = 0;
            userStreamGen[pid][user][i] = gen;
        }

        uint256 acc = s.accPerShare;
        uint256 pending;
        if (oldAmount != 0) {
            uint256 gross = FixedPointMathLib.fullMulDiv(oldAmount, acc, DistributorIO.ACC_PRECISION);
            uint256 debt = stale ? 0 : rewardDebt[pid][user][i];
            if (gross > debt) pending = gross - debt;
        }
        rewardDebt[pid][user][i] = FixedPointMathLib.fullMulDivUp(newAmount, acc, DistributorIO.ACC_PRECISION);

        if (budget != 0) {
            uint256 total = pending + rewardLockedUp[pid][user][i];
            if (total != 0) {
                address t = s.token;
                uint256 paid = DistributorIO.payReward(t, user, total, budget, totalStakedOf);

                rewardLockedUp[pid][user][i] = total - paid;
                if (paid != 0) {
                    uint256 owed = s.owed;
                    s.owed = owed > paid ? owed - paid : 0;
                    emit Harvest(user, pid, t, paid);
                    paidSome = true;
                }
                if (paid != total) emit RewardDeferred(pid, user, t, total - paid);
            }
        } else if (pending != 0) {
            rewardLockedUp[pid][user][i] += pending;
            emit RewardLockedUp(user, pid, s.token, pending);
        }
    }

    function _startStreamEpoch(uint256 pid, uint256 index, Stream storage s, bool enforceMin) internal {
        DistributorLogic.startEpoch(
            pid,
            index,
            s,
            streamEpochs[pid][index],
            streamEpochConfig[pid][index],
            isPullSource,
            feeRecipient,
            enforceMin
        );
    }

    function _tryStartStreamEpoch(uint256 pid, uint256 index) internal {
        try this.selfStartStreamEpoch(pid, index) {} catch {}
    }

    /// @notice Self-call target so a best-effort epoch start can revert cleanly in isolation.
    function selfStartStreamEpoch(uint256 pid, uint256 index) external {
        if (msg.sender != address(this)) revert InvalidParams();
        Stream storage s = _stream(pid, index);
        _startStreamEpoch(pid, index, s, true);
    }

    function _stream(uint256 pid, uint256 index) internal view returns (Stream storage s) {
        if (pid >= _pools.length) revert UnknownPool();
        Stream[] storage ss = _streams[pid];
        if (index >= ss.length) revert UnknownStream();
        s = ss[index];
    }
}

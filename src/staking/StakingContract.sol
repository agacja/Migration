// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IALB} from "../interfaces/IALB.sol";
import {IStakingContract} from "../interfaces/IStakingContract.sol";
import {IEscrowedToken} from "../interfaces/IEscrowedToken.sol";

interface ILoCFactoryRebase {
    function pullRebase() external returns (uint256 amount);
    function pendingRebase() external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Equal-weight reward distribution across esALB and govALB shares.
contract StakingContract is IStakingContract, OwnableRoles, ReentrancyGuardTransient {
    /// @notice Stream administration; factory wiring and deletion require Owner.
    uint256 public constant ROLE_ADMIN = 1 << 0;
    /// @notice A retired stream stays claimable this long before Owner may delete it.
    uint64 public constant RETIRE_GRACE = 90 days;
    /// @notice Gas limit for reward transfers inside share hooks.
    uint256 public constant AUTO_CLAIM_GAS = 150_000;
    uint256 public constant REBASE_READ_GAS = 25_000;
    uint256 public constant REBASE_PULL_GAS = 100_000;
    /// @notice Maximum streams processed on each share change.
    uint256 public constant MAX_STREAMS = 16;

    address public immutable esALB;
    address public immutable govALB;
    IALB public immutable alb;
    /// @notice Canonical wrapped-native token (WETH9 at 0x4200...0006 on Base).
    IWETH public immutable weth;
    ILoCFactoryRebase public locFactory;

    uint256 public constant ACC_PRECISION = 1e30;

    /// @notice Minimum distribution time as a fraction of the stream window.
    uint64 public constant MIN_SPREAD_BPS = 2500;

    struct Stream {
        uint256 accumulator;
        bool   exists;
        uint64 windowEnd;
        uint64 lastUpdate;
        uint32 window;
        uint64 retiredAt;
        uint128 ratePerSec;
        uint128 carry;
    }

    mapping(address => Stream) public streams;
    address[] public streamList;
    /// @dev Deleted tokens cannot be registered again; old user debt remains stored.
    mapping(address => bool) public isDeletedStream;
    /// @dev Skip failed auto-claims until a manual claim succeeds.
    mapping(address => bool) public autoClaimDisabled;

    /// @notice MasterChef-V2 reward debt floor: rewardDebt[token][user].
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @notice Accrued rewards awaiting claim.
    mapping(address => mapping(address => uint256)) public pending;

    /// @notice Booked token balance; sync credits only the excess.
    mapping(address => uint256) public trackedBalance;

    /// @notice Accounts authorized to notify or sync rewards.
    mapping(address => bool) public isNotifier;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint64 public defaultSmoothingWindow = 7 days;
    uint64 public minRebasePullInterval = 1 hours;
    uint64 public lastRebasePullAt;
    bool public deprecated;
    bool public migrationPending;
    mapping(address => uint256) public migrationRewards;

    event StreamRegistered(address indexed token, uint64 window);
    event StreamWindowSet(address indexed token, uint64 window);
    event NotifiedReward(address indexed token, uint256 amount);
    event Synced(address indexed token, uint256 amount);
    event EthRewardWrapped(uint256 amount);
    event Banked(address indexed user, address indexed token, uint256 amount);
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event DefaultSmoothingSet(uint64 window);
    event MinRebasePullIntervalSet(uint64 interval);
    event LoCFactorySet(address factory);
    event NotifierSet(address indexed notifier, bool allowed);
    event StreamRetired(address indexed token, address indexed to, uint256 unemittedRecovered);
    event StreamRevived(address indexed token);
    event StreamDeleted(address indexed token, address indexed to, uint256 unclaimedSwept);
    event SweepFailed(address indexed token, address indexed to, uint256 amount);
    event DeletedStreamSwept(address indexed token, address indexed to, uint256 amount);
    event AutoClaimed(address indexed user, address indexed token, uint256 amount);
    event AutoClaimDeferred(address indexed user, address indexed token, uint256 amount);
    event SharesSynced(address indexed user, uint256 previous, uint256 current);
    event Deprecated();
    event MigrationStarted();
    event MigrationCompleted();
    event MigrationAborted();
    event MigrationRewardQueued(address indexed token, uint256 amount);

    error NotEscrow();
    error NotNotifier();
    error UnknownStream();
    error BadWindow();
    error BadInterval();
    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error OnlyWethReceiver();
    error StreamRetiredError();
    error StreamNotRetired();
    error GraceNotElapsed();
    error HookExemptAccount();
    error NothingToDo();
    error CoreStream();
    error StreamIsDeleted();
    error TooManyStreams();
    error NotAContract();
    error CoreNotifier();
    error StreamExists();
    error StakingDeprecated();
    error MigrationIncomplete();
    error MigrationNotPending();
    error MigrationRequiresEmptyInstance();
    error EscrowNotWired();
    error InsufficientRebaseGas();

    function renounceOwnership() public payable override onlyOwner {
        revert("StakingContract: ownership required");
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    constructor(address owner_, IALB alb_, address esALB_, address govALB_, address weth_) {
        if (address(alb_) == address(0) || esALB_ == address(0) || govALB_ == address(0) || weth_ == address(0)) {
            revert ZeroAddress();
        }
        _initializeOwner(owner_);
        alb = alb_;
        esALB = esALB_;
        govALB = govALB_;
        weth = IWETH(weth_);

        isNotifier[esALB_] = true;
        isNotifier[govALB_] = true;
        emit NotifierSet(esALB_, true);
        emit NotifierSet(govALB_, true);

        _registerStream(address(alb_), 7 days);
        _registerStream(weth_, 7 days);
    }

    function setLoCFactory(ILoCFactoryRebase factory) external onlyOwner {
        if (address(factory) != address(0) && address(factory).code.length == 0) revert NotAContract();
        locFactory = factory;
        emit LoCFactorySet(address(factory));
    }

    function setNotifier(address notifier, bool allowed) external onlyOwnerOrRoles(ROLE_ADMIN) {
        if (!allowed && (notifier == esALB || notifier == govALB)) revert CoreNotifier();
        isNotifier[notifier] = allowed;
        emit NotifierSet(notifier, allowed);
    }

    function setDefaultSmoothingWindow(uint64 window) external onlyOwnerOrRoles(ROLE_ADMIN) {
        if (window < 1 hours || window > 30 days) revert BadWindow();
        defaultSmoothingWindow = window;
        emit DefaultSmoothingSet(window);
    }

    function setMinRebasePullInterval(uint64 interval) external onlyOwner {
        if (interval > 7 days) revert BadInterval();
        minRebasePullInterval = interval;
        emit MinRebasePullIntervalSet(interval);
    }

    /// @param window Zero selects defaultSmoothingWindow.
    function registerStream(address token, uint64 window) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (window == 0) window = defaultSmoothingWindow;
        if (window < 1 hours || window > 30 days) revert BadWindow();
        _registerStream(token, window);
    }

    /// @notice Retire a non-core stream; return unemitted funds to Owner and preserve claims.
    function retireStream(address token) external onlyOwnerOrRoles(ROLE_ADMIN) nonReentrant {
        if (migrationPending) revert MigrationIncomplete();
        if (token == address(alb) || token == address(weth)) revert CoreStream();
        address to = owner();
        Stream storage s = streams[token];
        if (!s.exists) revert UnknownStream();
        if (s.retiredAt != 0) revert StreamRetiredError();

        _advanceAccumulator(s);
        uint64 nowTs = uint64(block.timestamp);
        uint256 unemitted = uint256(s.carry);
        if (s.windowEnd > nowTs) {
            unchecked { unemitted += uint256(s.ratePerSec) * (s.windowEnd - nowTs); }
        }
        s.ratePerSec = 0;
        s.carry = 0;
        s.windowEnd = nowTs;
        s.lastUpdate = nowTs;
        s.retiredAt = nowTs;

        if (unemitted != 0) {
            if (_tryTransfer(token, to, unemitted, 0)) {
                uint256 tracked = trackedBalance[token];
                trackedBalance[token] = tracked > unemitted ? tracked - unemitted : 0;
            } else {
                emit SweepFailed(token, to, unemitted);
                unemitted = 0;
            }
        }
        emit StreamRetired(token, to, unemitted);
    }

    /// @notice Reactivate a retired stream, preserving claims; previously recovered funds must be re-funded.
    function reviveStream(address token) external onlyOwner {
        Stream storage s = streams[token];
        if (!s.exists) revert UnknownStream();
        if (s.retiredAt == 0) revert StreamNotRetired();
        uint64 nowTs = uint64(block.timestamp);
        s.retiredAt = 0;
        s.windowEnd = nowTs;
        s.lastUpdate = nowTs;
        emit StreamRevived(token);
    }

    /// @notice Delete after RETIRE_GRACE and sweep remaining rewards to the recipient.
    function deleteStream(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Stream storage s = streams[token];
        if (!s.exists) revert UnknownStream();
        if (s.retiredAt == 0) revert StreamNotRetired();

        bool neverEmitted = s.accumulator == 0 && trackedBalance[token] == 0;
        if (!neverEmitted && block.timestamp < uint256(s.retiredAt) + RETIRE_GRACE) revert GraceNotElapsed();

        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            if (streamList[i] == token) {
                streamList[i] = streamList[n - 1];
                streamList.pop();
                break;
            }
            unchecked { ++i; }
        }
        uint256 swept = trackedBalance[token];
        trackedBalance[token] = 0;
        delete streams[token];
        isDeletedStream[token] = true;

        if (swept != 0 && !_tryTransfer(token, to, swept, 0)) {
            emit SweepFailed(token, to, swept);
            swept = 0;
        }
        emit StreamDeleted(token, to, swept);
    }

    /// @notice Recover remaining funds from a deleted non-core stream.
    function sweepDeletedStream(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (!isDeletedStream[token]) revert UnknownStream();
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal == 0) revert ZeroAmount();
        SafeTransferLib.safeTransfer(token, to, bal);
        emit DeletedStreamSwept(token, to, bal);
    }

    function setStreamWindow(address token, uint64 window) external onlyOwnerOrRoles(ROLE_ADMIN) {
        if (window < 1 hours || window > 30 days) revert BadWindow();
        Stream storage s = streams[token];
        if (!s.exists) revert UnknownStream();
        if (s.retiredAt != 0) revert StreamRetiredError();
        s.window = uint32(window);
        emit StreamWindowSet(token, window);
    }

    function _registerStream(address token, uint64 window) internal {
        if (isDeletedStream[token]) revert StreamIsDeleted();
        if (streamList.length >= MAX_STREAMS) revert TooManyStreams();
        if (token.code.length == 0) revert NotAContract();
        Stream storage s = streams[token];
        if (s.exists) revert StreamExists();
        uint64 nowTs = uint64(block.timestamp);
        s.exists = true;
        s.windowEnd = nowTs;
        s.lastUpdate = nowTs;
        s.window = uint32(window);
        streamList.push(token);
        emit StreamRegistered(token, window);
    }

    modifier onlyEscrow() {
        if (msg.sender != esALB && msg.sender != govALB) revert NotEscrow();
        _;
    }

    modifier onlyNotifier() {
        if (!isNotifier[msg.sender]) revert NotNotifier();
        _;
    }

    function deprecate() external onlyEscrow nonReentrant {
        if (migrationPending) _abortMigration();
        if (!deprecated) {
            deprecated = true;
            emit Deprecated();
        }
    }

    /// @notice Queue rewards until the replacement finishes share migration.
    function beginMigration() external onlyEscrow nonReentrant {
        if (deprecated) revert StakingDeprecated();
        if (migrationPending) return;
        if (totalShares != 0) revert MigrationRequiresEmptyInstance();
        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            if (trackedBalance[streamList[i]] != 0) revert MigrationRequiresEmptyInstance();
            unchecked { ++i; }
        }
        migrationPending = true;
        emit MigrationStarted();
    }

    /// @notice Finish migration after synchronizing holders and wiring both escrows.
    function completeMigration() external onlyOwner nonReentrant {
        if (!migrationPending) revert MigrationNotPending();
        if (IEscrowedToken(esALB).staking() != address(this)
            || IEscrowedToken(govALB).staking() != address(this)) revert MigrationIncomplete();
        migrationPending = false;
        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            address token = streamList[i];
            uint256 queued = migrationRewards[token];
            if (queued != 0) {
                delete migrationRewards[token];
                trackedBalance[token] -= queued;
                _bookReward(token, queued);
            }
            unchecked { ++i; }
        }
        emit MigrationCompleted();
    }

    function _abortMigration() internal {
        migrationPending = false;
        address to = owner();
        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            address token = streamList[i];
            uint256 queued = migrationRewards[token];
            if (queued != 0) {
                if (_tryTransfer(token, to, queued, 0)) {
                    delete migrationRewards[token];
                    trackedBalance[token] -= queued;
                } else {
                    emit SweepFailed(token, to, queued);
                }
            }
            unchecked { ++i; }
        }
        emit MigrationAborted();
    }

    function notifyDeposit(address user, uint256 amount) external onlyEscrow nonReentrant {
        if (deprecated) return;
        _maybePullRebase();
        uint256 cur = sharesOf[user];
        uint256 next;
        unchecked { next = cur + amount; }

        _settleAndRefresh(user, cur, next);
        sharesOf[user] = next;
        unchecked { totalShares += amount; }
        _autoClaim(user);
    }

    function notifyWithdraw(address user, uint256 amount) external onlyEscrow nonReentrant {
        if (deprecated) return;
        _maybePullRebase();
        uint256 cur = sharesOf[user];
        uint256 dec = amount > cur ? cur : amount;
        uint256 next;
        unchecked { next = cur - dec; }
        _settleAndRefresh(user, cur, next);
        sharesOf[user] = next;
        unchecked { totalShares -= dec; }
        _autoClaim(user);
    }

    /// @notice Synchronize shares from both escrows, excluding exempt balances.
    function syncShares(address user) external nonReentrant {
        if (deprecated) revert StakingDeprecated();
        if (user == address(0)) revert ZeroAddress();
        bool wiredEs = IEscrowedToken(esALB).staking() == address(this);
        bool wiredGov = IEscrowedToken(govALB).staking() == address(this);
        if (!wiredEs && !wiredGov) revert EscrowNotWired();

        bool exEs = !wiredEs || IEscrowedToken(esALB).isHookExempt(user);
        bool exGov = !wiredGov || IEscrowedToken(govALB).isHookExempt(user);
        if (exEs && exGov) revert HookExemptAccount();
        _maybePullRebase();
        uint256 cur = sharesOf[user];
        uint256 truth = (exEs ? 0 : IEscrowedToken(esALB).stakedSharesOf(user))
            + (exGov ? 0 : IEscrowedToken(govALB).stakedSharesOf(user));
        if (truth == cur) revert NothingToDo();
        _settleAndRefresh(user, cur, truth);
        sharesOf[user] = truth;
        totalShares = totalShares - cur + truth;
        emit SharesSynced(user, cur, truth);
        _autoClaim(user);
    }

    function _tryTransfer(address token, address to, uint256 amount, uint256 stipend) internal returns (bool ok) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
            let g := gas()
            let capped := stipend
            if iszero(stipend) { stipend := g }
            ok := call(stipend, token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), ok)) {
                ok := lt(or(iszero(extcodesize(token)), returndatasize()), ok)
            }
            if capped {
                if iszero(or(ok, gt(g, add(capped, add(div(capped, 63), 3000))))) { revert(0x00, 0x00) }
            }
            mstore(0x40, m)
        }
    }

    function _autoClaim(address user) internal {
        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            address token = streamList[i];
            uint256 amount = pending[token][user];
            if (amount != 0 && !autoClaimDisabled[token]) {
                uint256 tracked = trackedBalance[token];
                pending[token][user] = 0;
                trackedBalance[token] = tracked > amount ? tracked - amount : 0;
                if (_tryTransfer(token, user, amount, AUTO_CLAIM_GAS)) {
                    emit AutoClaimed(user, token, amount);
                } else {
                    pending[token][user] = amount;
                    trackedBalance[token] = tracked;
                    autoClaimDisabled[token] = true;
                    emit AutoClaimDeferred(user, token, amount);
                }
            }
            unchecked { ++i; }
        }
    }

    function notifyReward(address token, uint256 amount) external onlyNotifier nonReentrant {
        if (!streams[token].exists) revert UnknownStream();
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received;
        unchecked { received = SafeTransferLib.balanceOf(token, address(this)) - before; }
        _bookReward(token, received);
    }

    /// @notice Wrap native rewards as WETH and credit the stream.
    function notifyEthReward() external payable onlyNotifier nonReentrant {
        uint256 value = msg.value;
        IWETH _weth = weth;
        _weth.deposit{value: value}();
        _bookReward(address(_weth), value);
        emit EthRewardWrapped(value);
    }

    /// @notice Credit untracked tokens to their stream.
    function sync(address token) external onlyNotifier nonReentrant {
        if (!streams[token].exists) revert UnknownStream();
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 tracked = trackedBalance[token];
        if (bal <= tracked) return;
        uint256 delta;
        unchecked { delta = bal - tracked; }
        _bookReward(token, delta);
        emit Synced(token, delta);
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert OnlyWethReceiver();
    }

    function _bookReward(address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        Stream storage s = streams[token];
        if (!s.exists) revert UnknownStream();
        if (s.retiredAt != 0) revert StreamRetiredError();

        if (migrationPending) {
            migrationRewards[token] += amount;
            trackedBalance[token] += amount;
            emit MigrationRewardQueued(token, amount);
            return;
        }
        _advanceAccumulator(s);

        uint64 nowTs = uint64(block.timestamp);
        uint256 leftover;
        uint64 windowEnd_ = s.windowEnd;
        if (nowTs < windowEnd_) {
            unchecked {
                leftover = uint256(s.ratePerSec) * (windowEnd_ - nowTs);
            }
        }
        uint256 newPool;
        unchecked {
            newPool = leftover + amount + uint256(s.carry);
        }

        uint64 window = s.window;
        uint64 remaining;
        if (nowTs >= windowEnd_) {
            remaining = window;
        } else {
            unchecked { remaining = windowEnd_ - nowTs; }
        }
        uint64 minSpread;
        unchecked { minSpread = uint64((uint256(window) * MIN_SPREAD_BPS) / 10_000); }
        if (minSpread == 0) minSpread = 1;
        if (remaining < minSpread) remaining = minSpread;
        unchecked { s.windowEnd = nowTs + remaining; }

        uint256 rate = newPool / remaining;
        if (rate > type(uint128).max) revert AmountTooLarge();
        s.ratePerSec = uint128(rate);
        s.lastUpdate = nowTs;
        unchecked {
            s.carry = uint128(newPool - rate * uint256(remaining));
        }
        unchecked {
            trackedBalance[token] += amount;
        }

        emit NotifiedReward(token, amount);
    }

    function claim(address[] calldata tokens) external nonReentrant {
        _maybePullRebase();
        _settleAccrual(msg.sender);

        uint256 n = tokens.length;
        for (uint256 i; i < n;) {
            address token = tokens[i];
            if (!streams[token].exists) revert UnknownStream();
            uint256 amount = pending[token][msg.sender];
            if (amount != 0) {
                pending[token][msg.sender] = 0;
                uint256 tracked = trackedBalance[token];
                trackedBalance[token] = tracked > amount ? tracked - amount : 0;
                SafeTransferLib.safeTransfer(token, msg.sender, amount);
                if (autoClaimDisabled[token]) autoClaimDisabled[token] = false;
                emit Claimed(msg.sender, token, amount);
            }
            unchecked { ++i; }
        }
    }

    function pendingReward(address user, address token) external view returns (uint256) {
        Stream storage s = streams[token];
        if (!s.exists) return 0;
        uint256 acc = s.accumulator;
        uint256 _total = totalShares;
        if (_total != 0) {
            uint64 nowTs = uint64(block.timestamp);
            uint64 last = s.lastUpdate;
            if (last < nowTs) {
                uint64 endTs = nowTs > s.windowEnd ? s.windowEnd : nowTs;
                if (endTs > last) {
                    unchecked {
                        uint256 elapsed = endTs - last;
                        acc += (uint256(s.ratePerSec) * elapsed * ACC_PRECISION) / _total;
                    }
                }
            }
        }
        uint256 owed = FixedPointMathLib.fullMulDiv(sharesOf[user], acc, ACC_PRECISION);
        uint256 already = rewardDebt[token][user];
        uint256 fresh;
        unchecked {
            fresh = owed > already ? owed - already : 0;
        }
        return pending[token][user] + fresh;
    }

    function _advanceAccumulator(Stream storage s) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = s.lastUpdate;
        if (nowTs <= last) return;
        uint64 endTs = nowTs > s.windowEnd ? s.windowEnd : nowTs;

        if (endTs > last) {
            uint256 _total = totalShares;
            unchecked {
                uint256 emitted = uint256(s.ratePerSec) * (endTs - last);
                if (_total != 0) {
                    s.accumulator += (emitted * ACC_PRECISION) / _total;
                } else if (emitted != 0) {
                    uint256 newCarry = uint256(s.carry) + emitted;
                    s.carry = newCarry > type(uint128).max ? type(uint128).max : uint128(newCarry);
                }
            }
            s.lastUpdate = nowTs;
        }
    }

    function _settleAccrual(address user) internal {
        uint256 n = streamList.length;
        if (n == 0) return;
        uint256 cur = sharesOf[user];

        for (uint256 i; i < n;) {
            address token = streamList[i];
            Stream storage s = streams[token];

            _advanceAccumulator(s);
            uint256 acc = s.accumulator;

            if (cur != 0 && acc != 0) {
                uint256 owed = FixedPointMathLib.fullMulDiv(cur, acc, ACC_PRECISION);
                uint256 already = rewardDebt[token][user];
                if (owed > already) {
                    unchecked {
                        uint256 banked = owed - already;
                        pending[token][user] += banked;
                        emit Banked(user, token, banked);
                    }
                }
                rewardDebt[token][user] = owed;
            }

            unchecked { ++i; }
        }
    }

    function _settleAndRefresh(address user, uint256 oldShares, uint256 newShares) internal {
        uint256 n = streamList.length;
        for (uint256 i; i < n;) {
            address token = streamList[i];
            Stream storage s = streams[token];

            _advanceAccumulator(s);
            uint256 acc = s.accumulator;

            if (acc != 0) {
                if (oldShares != 0) {
                    uint256 owed = FixedPointMathLib.fullMulDiv(oldShares, acc, ACC_PRECISION);
                    uint256 already = rewardDebt[token][user];
                    if (owed > already) {
                        unchecked {
                            uint256 banked = owed - already;
                            pending[token][user] += banked;
                            emit Banked(user, token, banked);
                        }
                    }
                }
                rewardDebt[token][user] = FixedPointMathLib.fullMulDiv(newShares, acc, ACC_PRECISION);
            }

            unchecked { ++i; }
        }
    }

    function _maybePullRebase() internal {
        if (deprecated || migrationPending || totalShares == 0) return;
        ILoCFactoryRebase _f = locFactory;
        if (address(_f) == address(0)) return;
        unchecked {
            if (block.timestamp < uint256(lastRebasePullAt) + uint256(minRebasePullInterval)) return;
        }
        if (gasleft() < REBASE_READ_GAS + REBASE_PULL_GAS + 200_000) revert InsufficientRebaseGas();
        lastRebasePullAt = uint64(block.timestamp);
        uint256 amount;
        bytes4 pendingSelector = ILoCFactoryRebase.pendingRebase.selector;
        bytes4 pullSelector = ILoCFactoryRebase.pullRebase.selector;
        assembly ("memory-safe") {
            mstore(0x00, pendingSelector)
            let ok := staticcall(REBASE_READ_GAS, _f, 0x00, 0x04, 0x00, 0x20)
            if and(and(ok, gt(returndatasize(), 0x1f)), iszero(iszero(mload(0x00)))) {
                mstore(0x00, pullSelector)
                ok := call(REBASE_PULL_GAS, _f, 0, 0x00, 0x04, 0x00, 0x20)
                if and(ok, gt(returndatasize(), 0x1f)) { amount := mload(0x00) }
            }
        }
        if (amount != 0) _bookReward(address(alb), amount);
    }

    function shareOf(address user) external view returns (uint256) {
        return sharesOf[user];
    }

    function streamsLength() external view returns (uint256) {
        return streamList.length;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BunniKey, IBunniHub, IUniswapV3PoolLite} from "../interfaces/IBunniHub.sol";
import {IFeeFarm} from "../interfaces/IFeeFarm.sol";

/// @notice Collects Bunni fees and splits them among LPs, the protocol, referrers and callers.
contract BunniFeeDistributor is Ownable, ReentrancyGuardTransient {
    uint16 public constant ALLOCATION_DENOMINATOR = 10_000;
    uint16 public constant BOUNTY_DENOMINATOR = 10_000;
    uint16 public constant MAX_BOUNTY_PCT = 300;
    uint40 public constant TIMELOCK_DELAY_DEFAULT = 7 days;
    uint256 private constant Q128 = 2 ** 128;

    event FeesDistributed(
        bytes32 indexed keyHash,
        address token0,
        address token1,
        uint256 total0,
        uint256 total1,
        uint256 bounty0,
        uint256 bounty1,
        uint256 lp0,
        uint256 lp1,
        uint256 protocol0,
        uint256 protocol1,
        uint256 ref0,
        uint256 ref1,
        bool attributed
    );
    event ClaimSkipped(bytes32 indexed keyHash, string reason);
    event SurplusBooked(address indexed token, uint256 amount);
    event SurplusAttributed(
        bytes32 indexed keyHash, address token0, address token1, uint256 amount0, uint256 amount1, address indexed by
    );
    event SurplusReleased(address indexed token, uint256 amount, address indexed to);
    event LpNotified(bytes32 indexed keyHash, address indexed farm, address indexed token, uint256 amount);
    event LpDeferred(bytes32 indexed keyHash, address indexed token, uint256 added, uint256 pending);
    event TokensRecovered(address indexed token, uint256 amount, address indexed to);

    event AllocationUpdated(uint16 lp, uint16 protocol, uint16 referrer);
    event ReferrerSet(bytes32 indexed keyHash, address referrer);
    event FeeFarmSet(bytes32 indexed keyHash, address farm);
    event AdminSet(address newAdmin);
    event AttributorSet(address attributor);
    event BountyPctUpdated(uint16 newPct);
    event HubOwnershipTransferred(address newOwner);
    event HubProtocolFeeSet(uint256 value);
    event TimelockQueued(bytes32 indexed actionId, uint40 executeAfter);
    event TimelockExecuted(bytes32 indexed actionId);
    event TimelockCancelled(bytes32 indexed actionId);
    event TimelockDelayUpdated(uint40 newDelay);

    error ZeroAddress();
    error ZeroAmount();
    error NotAttributor();
    error FarmNotSet();
    error NotAContract();
    error ExceedsUnattributed();
    error SelfOnly();
    error AlreadyQueued();
    error NotQueued();
    error NotReady();
    error BadAllocation();
    error BountyTooHigh();
    error BadDelay();
    error IncompleteFarmTransfer();

    IBunniHub public immutable bunniHub;

    struct Alloc {
        uint16 lp;
        uint16 protocol;
        uint16 referrer;
    }

    Alloc public allocations;

    address public protocolAdmin;
    /// @notice May call attribute(). Expected to be an ops key driven by the hub's Compound/PayProtocolFee events.
    address public attributor;
    uint16 public bountyPct = 25;

    /// @notice keyHash => farm that receives the LP share via notifyReward
    mapping(bytes32 => address) public feeFarms;
    mapping(bytes32 => address) public referrers;

    /// @notice token => amount swept from the hub that has not been measured for any key
    mapping(address => uint256) public unattributed;
    /// @notice keyHash => token => LP share held here because the farm rejected notifyReward
    mapping(bytes32 => mapping(address => uint256)) public lpPending;
    /// @notice token => sum of lpPending over all keys
    mapping(address => uint256) public lpPendingTotal;

    uint40 public timelockDelay = TIMELOCK_DELAY_DEFAULT;
    mapping(bytes32 => uint40) public queuedAt;

    /// @param owner_ Owner; expected to be the canonical timelock
    /// @param bunniHub_ BunniHubA this contract will own
    /// @param protocolAdmin_ Receives the protocol share (and the referrer share when no referrer is set)
    /// @param attributor_ Address allowed to call attribute(); may be zero
    /// @param lpPct LP share in basis points
    /// @param protocolPct Protocol share in basis points
    /// @param refPct Referrer share in basis points
    constructor(
        address owner_,
        address bunniHub_,
        address protocolAdmin_,
        address attributor_,
        uint16 lpPct,
        uint16 protocolPct,
        uint16 refPct
    ) {
        if (owner_ == address(0) || bunniHub_ == address(0) || protocolAdmin_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        bunniHub = IBunniHub(bunniHub_);
        protocolAdmin = protocolAdmin_;
        attributor = attributor_;
        _setAllocations(lpPct, protocolPct, refPct);
    }

    function renounceOwnership() public payable override onlyOwner {
        revert("BunniFeeDistributor: ownership required");
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    function getKeyHash(BunniKey calldata key) external pure returns (bytes32) {
        return _keyHash(key);
    }

    function canExecuteAction(bytes32 actionId) external view returns (bool) {
        uint40 q = queuedAt[actionId];
        if (q == 0) return false;
        unchecked {
            return block.timestamp >= q + timelockDelay;
        }
    }

    /// @notice Balance of `token` held here that is not reserved by a ledger
    function recoverable(address token) public view returns (uint256) {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 reserved = unattributed[token] + lpPendingTotal[token];
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice Estimated fees owed by the position; actual distribution uses measured receipts.
    function pendingFees(BunniKey calldata key)
        external
        view
        returns (address token0, address token1, uint256 pending0, uint256 pending1, uint256 bounty0, uint256 bounty1)
    {
        token0 = key.pool.token0();
        token1 = key.pool.token1();

        (uint128 liquidity, uint256 fgLast0, uint256 fgLast1, uint128 owed0, uint128 owed1) =
            key.pool.positions(_positionKey(key));
        pending0 = owed0;
        pending1 = owed1;

        if (liquidity > 0) {
            (uint256 inside0, uint256 inside1) = _feeGrowthInside(key);
            uint256 delta0;
            uint256 delta1;
            unchecked {
                delta0 = inside0 - fgLast0;
                delta1 = inside1 - fgLast1;
            }
            pending0 += FixedPointMathLib.fullMulDiv(delta0, liquidity, Q128);
            pending1 += FixedPointMathLib.fullMulDiv(delta1, liquidity, Q128);
        }

        bounty0 = (pending0 * bountyPct) / BOUNTY_DENOMINATOR;
        bounty1 = (pending1 * bountyPct) / BOUNTY_DENOMINATOR;
    }

    /// @notice Collects and distributes fees for each key. Keys that cannot be processed are skipped with an event.
    function claim(BunniKey[] calldata keys) external nonReentrant {
        uint16 bounty = bountyPct;
        uint256 len = keys.length;
        for (uint256 i; i < len;) {
            _claimKey(keys[i], bounty);
            unchecked {
                ++i;
            }
        }
    }

    function retryLp(BunniKey calldata key) external nonReentrant {
        bytes32 kh = _keyHash(key);
        address farm = feeFarms[kh];
        if (farm == address(0)) revert FarmNotSet();
        _retryLp(key, kh, farm);
    }

    function _retryLp(BunniKey calldata key, bytes32 kh, address farm) internal {
        _notifyLp(kh, farm, key.pool.token0(), 0);
        _notifyLp(kh, farm, key.pool.token1(), 0);
    }

    function _claimKey(BunniKey calldata key, uint16 bounty) internal {
        bytes32 kh = _keyHash(key);
        address farm = feeFarms[kh];
        if (farm == address(0)) {
            emit ClaimSkipped(kh, "fee farm not set");
            return;
        }

        // compoundSkim pokes the position; a zero-liquidity poke reverts in the pool
        (uint128 liquidity,,,,) = key.pool.positions(_positionKey(key));
        if (liquidity == 0) {
            _retryLp(key, kh, farm);
            emit ClaimSkipped(kh, "no liquidity");
            return;
        }

        address t0 = key.pool.token0();
        address t1 = key.pool.token1();

        (uint256 earned0, uint256 earned1) = _collect(key, t0, t1);
        if (earned0 == 0 && earned1 == 0) {
            _retryLp(key, kh, farm);
            emit ClaimSkipped(kh, "no fees");
            return;
        }

        _distribute(kh, farm, t0, t1, earned0, earned1, bounty, msg.sender, false);
    }

    function _collect(BunniKey calldata key, address t0, address t1)
        internal
        returns (uint256 earned0, uint256 earned1)
    {
        address hub = address(bunniHub);
        uint256 pre0 = SafeTransferLib.balanceOf(t0, hub);
        uint256 pre1 = SafeTransferLib.balanceOf(t1, hub);

        bunniHub.compoundSkim(key);

        uint256 post0 = SafeTransferLib.balanceOf(t0, hub);
        uint256 post1 = SafeTransferLib.balanceOf(t1, hub);
        earned0 = post0 > pre0 ? post0 - pre0 : 0;
        earned1 = post1 > pre1 ? post1 - pre1 : 0;

        (uint256 recv0, uint256 recv1) = _sweepPair(t0, t1, post0, post1);
        earned0 = _book(t0, earned0, recv0);
        earned1 = _book(t1, earned1, recv1);
    }

    function _sweepPair(address t0, address t1, uint256 hubBal0, uint256 hubBal1)
        internal
        returns (uint256 recv0, uint256 recv1)
    {
        uint256 n = (hubBal0 > 0 ? 1 : 0) + (hubBal1 > 0 ? 1 : 0);
        if (n == 0) return (0, 0);

        address[] memory list = new address[](n);
        uint256 i;
        if (hubBal0 > 0) list[i++] = t0;
        if (hubBal1 > 0) list[i] = t1;

        uint256 self0 = SafeTransferLib.balanceOf(t0, address(this));
        uint256 self1 = SafeTransferLib.balanceOf(t1, address(this));
        bunniHub.sweepTokens(list, address(this));
        recv0 = SafeTransferLib.balanceOf(t0, address(this)) - self0;
        recv1 = SafeTransferLib.balanceOf(t1, address(this)) - self1;
    }

    function _book(address token, uint256 earned, uint256 received) internal returns (uint256) {
        if (earned > received) earned = received;
        uint256 surplus = received - earned;
        if (surplus > 0) {
            unattributed[token] += surplus;
            emit SurplusBooked(token, surplus);
        }
        return earned;
    }

    function _distribute(
        bytes32 kh,
        address farm,
        address t0,
        address t1,
        uint256 amount0,
        uint256 amount1,
        uint16 bounty,
        address bountyTo,
        bool attributed
    ) internal {
        uint256 bounty0;
        uint256 bounty1;
        if (bounty > 0) {
            bounty0 = (amount0 * bounty) / BOUNTY_DENOMINATOR;
            bounty1 = (amount1 * bounty) / BOUNTY_DENOMINATOR;
            _transfer(t0, bountyTo, bounty0);
            _transfer(t1, bountyTo, bounty1);
        }

        Alloc memory alloc = allocations;
        (uint256 lp0, uint256 protocol0, uint256 ref0) = _calculateAllocations(amount0 - bounty0, alloc);
        (uint256 lp1, uint256 protocol1, uint256 ref1) = _calculateAllocations(amount1 - bounty1, alloc);

        _notifyLp(kh, farm, t0, lp0);
        _notifyLp(kh, farm, t1, lp1);

        address admin = protocolAdmin;
        _transfer(t0, admin, protocol0);
        _transfer(t1, admin, protocol1);

        address ref = referrers[kh];
        if (ref == address(0)) ref = admin;
        _transfer(t0, ref, ref0);
        _transfer(t1, ref, ref1);

        emit FeesDistributed(
            kh, t0, t1, amount0, amount1, bounty0, bounty1, lp0, lp1, protocol0, protocol1, ref0, ref1, attributed
        );
    }

    /// @dev Failed delivery leaves the full amount in lpPending.
    function _notifyLp(bytes32 kh, address farm, address token, uint256 amount) internal {
        uint256 prev = lpPending[kh][token];
        uint256 total = amount + prev;
        if (total == 0) return;

        uint256 newPending;
        try this.notifyFarm(farm, token, total) {
            emit LpNotified(kh, farm, token, total);
        } catch {
            newPending = total;
            emit LpDeferred(kh, token, amount, total);
        }

        if (newPending != prev) {
            lpPending[kh][token] = newPending;
            lpPendingTotal[token] = lpPendingTotal[token] - prev + newPending;
        }
    }

    /// @notice Isolated farm delivery; approval and transfer revert together on failure.
    function notifyFarm(address farm, address token, uint256 amount) external {
        if (msg.sender != address(this)) revert SelfOnly();
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeApproveWithRetry(token, farm, amount);
        IFeeFarm(farm).notifyReward(token, amount);
        SafeTransferLib.safeApprove(token, farm, 0);
        uint256 after_ = SafeTransferLib.balanceOf(token, address(this));
        if (after_ > before || before - after_ != amount) revert IncompleteFarmTransfer();
    }

    /// @notice Assign unattributed funds to a key and distribute without a caller bounty.
    function attribute(BunniKey calldata key, uint256 amount0, uint256 amount1) external nonReentrant {
        if (msg.sender != attributor && msg.sender != owner()) revert NotAttributor();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        bytes32 kh = _keyHash(key);
        address farm = feeFarms[kh];
        if (farm == address(0)) revert FarmNotSet();

        address t0 = key.pool.token0();
        address t1 = key.pool.token1();
        if (amount0 > unattributed[t0] || amount1 > unattributed[t1]) revert ExceedsUnattributed();
        unattributed[t0] -= amount0;
        unattributed[t1] -= amount1;

        emit SurplusAttributed(kh, t0, t1, amount0, amount1, msg.sender);
        _distribute(kh, farm, t0, t1, amount0, amount1, 0, address(0), true);
    }

    /// @notice Sweeps hub balances into this contract as unattributed surplus.
    function forceClaim(address[] calldata tokens) external nonReentrant {
        address hub = address(bunniHub);
        address[] memory one = new address[](1);
        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (SafeTransferLib.balanceOf(token, hub) > 0) {
                one[0] = token;
                uint256 pre = SafeTransferLib.balanceOf(token, address(this));
                bunniHub.sweepTokens(one, address(this));
                uint256 got = SafeTransferLib.balanceOf(token, address(this)) - pre;
                if (got > 0) {
                    unattributed[token] += got;
                    emit SurplusBooked(token, got);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Queues an admin action. `actionId` = keccak256(abi.encode(selector, "<functionName>", args...)).
    function queueAction(bytes32 actionId) external onlyOwner {
        if (queuedAt[actionId] != 0) revert AlreadyQueued();
        queuedAt[actionId] = uint40(block.timestamp);
        uint40 executeAfter;
        unchecked {
            executeAfter = uint40(block.timestamp) + timelockDelay;
        }
        emit TimelockQueued(actionId, executeAfter);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        if (queuedAt[actionId] == 0) revert NotQueued();
        delete queuedAt[actionId];
        emit TimelockCancelled(actionId);
    }

    function _timelockExecute(bytes32 actionId) internal {
        uint40 q = queuedAt[actionId];
        if (q == 0) revert NotQueued();
        uint40 readyTime;
        unchecked {
            readyTime = q + timelockDelay;
        }
        if (block.timestamp < readyTime) revert NotReady();
        delete queuedAt[actionId];
        emit TimelockExecuted(actionId);
    }

    function setPercentages(uint16 lpPct, uint16 protocolPct, uint16 refPct) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setPercentages", lpPct, protocolPct, refPct)));
        _setAllocations(lpPct, protocolPct, refPct);
        emit AllocationUpdated(lpPct, protocolPct, refPct);
    }

    function setReferrer(bytes32 keyHash_, address referrer_) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setReferrer", keyHash_, referrer_)));
        referrers[keyHash_] = referrer_;
        emit ReferrerSet(keyHash_, referrer_);
    }

    /// @notice Set the LP fee farm; zero unregisters it.
    function setFeeFarm(BunniKey calldata key, address farm) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setFeeFarm", key, farm)));
        if (farm != address(0) && farm.code.length == 0) revert NotAContract();
        bytes32 kh = _keyHash(key);
        feeFarms[kh] = farm;
        emit FeeFarmSet(kh, farm);
    }

    function setAdmin(address newAdmin) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setAdmin", newAdmin)));
        if (newAdmin == address(0)) revert ZeroAddress();
        protocolAdmin = newAdmin;
        emit AdminSet(newAdmin);
    }

    function setAttributor(address newAttributor) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setAttributor", newAttributor)));
        attributor = newAttributor;
        emit AttributorSet(newAttributor);
    }

    function setBountyPct(uint16 newPct) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setBountyPct", newPct)));
        if (newPct > MAX_BOUNTY_PCT) revert BountyTooHigh();
        bountyPct = newPct;
        emit BountyPctUpdated(newPct);
    }

    function updateTimelockDelay(uint40 newDelay) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "updateTimelockDelay", newDelay)));
        if (newDelay < 1 days || newDelay > 30 days) revert BadDelay();
        timelockDelay = newDelay;
        emit TimelockDelayUpdated(newDelay);
    }

    /// @notice Sets the hub's protocol fee (WAD). 1e18 makes compoundSkim retain everything it collects.
    function setHubProtocolFee(uint256 value) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "setHubProtocolFee", value)));
        bunniHub.setProtocolFee(value);
        emit HubProtocolFeeSet(value);
    }

    function transferBunniOwnership(address newOwner) external onlyOwner {
        _timelockExecute(keccak256(abi.encode(msg.sig, "transferBunniOwnership", newOwner)));
        if (newOwner == address(0)) revert ZeroAddress();
        bunniHub.transferOwnership(newOwner);
        emit HubOwnershipTransferred(newOwner);
    }

    /// @notice Recovers balance that no ledger accounts for (stray transfers).
    function recoverTokens(address[] calldata tokens, address to) external onlyOwner nonReentrant {
        _timelockExecute(keccak256(abi.encode(msg.sig, "recoverTokens", tokens, to)));
        if (to == address(0)) revert ZeroAddress();
        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            uint256 amount = recoverable(tokens[i]);
            if (amount > 0) {
                SafeTransferLib.safeTransfer(tokens[i], to, amount);
                emit TokensRecovered(tokens[i], amount, to);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Explicitly releases unattributed balance (e.g. fees from keys that have no farm).
    function releaseUnattributed(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        _timelockExecute(keccak256(abi.encode(msg.sig, "releaseUnattributed", token, amount, to)));
        if (to == address(0)) revert ZeroAddress();
        if (amount > unattributed[token]) revert ExceedsUnattributed();
        unattributed[token] -= amount;
        SafeTransferLib.safeTransfer(token, to, amount);
        emit SurplusReleased(token, amount, to);
    }

    function _keyHash(BunniKey calldata key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key.pool, key.tickLower, key.tickUpper));
    }

    function _positionKey(BunniKey calldata key) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(bunniHub), key.tickLower, key.tickUpper));
    }

    /// @dev Uniswap V3 Tick.getFeeGrowthInside, computed from public pool state. Wraps by design.
    function _feeGrowthInside(BunniKey calldata key) internal view returns (uint256 inside0, uint256 inside1) {
        IUniswapV3PoolLite pool = key.pool;
        (, int24 tick,,,,,) = pool.slot0();
        uint256 global0 = pool.feeGrowthGlobal0X128();
        uint256 global1 = pool.feeGrowthGlobal1X128();
        (,, uint256 lowerOut0, uint256 lowerOut1,,,,) = pool.ticks(key.tickLower);
        (,, uint256 upperOut0, uint256 upperOut1,,,,) = pool.ticks(key.tickUpper);

        unchecked {
            uint256 below0 = tick >= key.tickLower ? lowerOut0 : global0 - lowerOut0;
            uint256 below1 = tick >= key.tickLower ? lowerOut1 : global1 - lowerOut1;
            uint256 above0 = tick < key.tickUpper ? upperOut0 : global0 - upperOut0;
            uint256 above1 = tick < key.tickUpper ? upperOut1 : global1 - upperOut1;
            inside0 = global0 - below0 - above0;
            inside1 = global1 - below1 - above1;
        }
    }

    function _setAllocations(uint16 lpPct, uint16 protocolPct, uint16 refPct) internal {
        if (uint256(lpPct) + uint256(protocolPct) + uint256(refPct) != ALLOCATION_DENOMINATOR) revert BadAllocation();
        allocations = Alloc(lpPct, protocolPct, refPct);
    }

    function _calculateAllocations(uint256 amount, Alloc memory alloc)
        internal
        pure
        returns (uint256 lp, uint256 protocol, uint256 referrer)
    {
        lp = (amount * alloc.lp) / ALLOCATION_DENOMINATOR;
        protocol = (amount * alloc.protocol) / ALLOCATION_DENOMINATOR;
        referrer = amount - lp - protocol;
    }

    function _transfer(address token, address to, uint256 amount) internal {
        if (amount > 0) SafeTransferLib.safeTransfer(token, to, amount);
    }
}

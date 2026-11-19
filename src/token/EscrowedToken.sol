// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IALB} from "../interfaces/IALB.sol";
import {IStakingContract} from "../interfaces/IStakingContract.sol";

abstract contract EscrowedToken is ERC20, OwnableRoles, ReentrancyGuardTransient {
    /// @notice Admin manages exemptions; economic parameters require Owner.
    uint256 public constant ROLE_ADMIN = 1 << 0;

    IALB public immutable underlying;
    IStakingContract public staking;
    uint64 public immutable epochStart;

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_PPM = 1_000_000;

    uint64 public minDuration;
    uint64 public maxDuration;
    uint16 public minRedeemBps;
    uint16 public partialStakeBps;
    uint32 public freeRedeemPpmPerTick;
    uint64 public freeRedeemCooldown;

    struct VestingPosition {
        uint128 esAmount;
        uint128 partialShare;

        uint64  startedAt;
        uint64  minUnlockAt;
        uint64  maxUnlockAt;
        uint16  minRedeemBpsAtStart;
    }
    mapping(address => VestingPosition[]) internal _positions;
    mapping(address => uint128) public lockedInVesting;
    struct RedeemBucket {
        uint128 allowance;
        uint64 accruedAt;
    }
    mapping(address => RedeemBucket) internal _bucket;
    /// @notice Cached sum of shares from active unstaking positions.
    mapping(address => uint128) public livePartialShares;
    mapping(address => bool)    public isWhitelisted;
    /// @dev Internal vesting custody moves suppress hooks; the net share change is sent once.
    bool transient internal _custodyOpen;
    /// @notice Custodians excluded from staking hooks.
    mapping(address => bool)    public isHookExempt;
    /// @notice Supply cap enforced in _mint; zero means uncapped.
    uint128 public supplyCap;
    /// @notice Per-wallet position cap enforced on every acquisition (mint, conversion,
    /// transfer-in); zero disables. Counts balance PLUS vesting custody (_redeemBase), so
    /// parking tokens in startUnstake cannot dodge it. Hook-exempt custodians are outside
    /// the cap (their shares are stripped; they are not governance actors). Prospective
    /// only: lowering it never confiscates — over-cap wallets just cannot acquire more.
    uint128 public walletCap;

    /// @notice Direct penalty recipient; required when the underlying token cannot be a reward stream.
    address public penaltySink;

    /// @notice Allowed conversion destinations with the same underlying and a harder lock.
    mapping(address => bool) public isConversionDestination;
    /// @notice Escrow tokens allowed to convert into this one.
    mapping(address => bool) public isConversionSource;

    event StakingSet(address indexed staking);
    event WhitelistSet(address indexed addr, bool allowed);
    event HookExemptSet(address indexed addr, bool exempt);
    event SupplyCapSet(uint128 cap);
    event WalletCapSet(uint128 cap);
    event UnstakeStarted(address indexed user, uint256 index, uint256 esAmount);
    event UnstakeFinalized(address indexed user, uint256 index, uint256 albOut, uint256 penalty);
    event UnstakeCancelled(address indexed user, uint256 index);
    event InstantRedeem(address indexed user, uint256 esAmount, uint256 albOut);
    event RedemptionParamsUpdated();
    event InstantRedeemParamsUpdated();
    event PenaltySinkSet(address indexed sink);
    event ConversionDestinationSet(address indexed dest, bool allowed);
    event ConversionSourceSet(address indexed source, bool allowed);
    event ConvertedOut(address indexed user, address indexed dest, uint256 amount);
    event ConvertedIn(address indexed user, address indexed source, uint256 amount);

    error NotWhitelisted();
    error NothingToVest();
    error InvalidIndex();
    error TooEarly();
    error AmountExceedsAllowance();
    error InvalidParams();
    error StakingNotSet();
    error SupplyCapExceeded();
    error WalletCapExceeded();
    error SameStaking();
    error NotConversionPath();
    error ExemptConversion();

    function renounceOwnership() public payable override onlyOwner {
        revert("EscrowedToken: ownership required");
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    constructor(
        address owner_,
        IALB underlying_,
        uint64 minDuration_,
        uint64 maxDuration_,
        uint16 minRedeemBps_,
        uint16 partialStakeBps_,
        uint32 freeRedeemPpmPerTick_,
        uint64 freeRedeemCooldown_
    ) {
        if (owner_ == address(0) || address(underlying_) == address(0)) revert InvalidParams();
        _initializeOwner(owner_);
        underlying = underlying_;

        if (minDuration_ > maxDuration_) revert InvalidParams();
        if (minRedeemBps_ > MAX_BPS || partialStakeBps_ > MAX_BPS) revert InvalidParams();
        if (freeRedeemPpmPerTick_ > MAX_PPM || freeRedeemCooldown_ == 0) revert InvalidParams();

        minDuration = minDuration_;
        maxDuration = maxDuration_;
        minRedeemBps = minRedeemBps_;
        partialStakeBps = partialStakeBps_;
        freeRedeemPpmPerTick = freeRedeemPpmPerTick_;
        freeRedeemCooldown = freeRedeemCooldown_;
        epochStart = uint64(block.timestamp);

        isWhitelisted[address(this)] = true;
        isHookExempt[address(this)] = true;
    }

    /// @notice Replace staking; old rewards stay claimable, new shares require bootstrap.
    function setStaking(IStakingContract staking_) external onlyOwner nonReentrant {
        if (address(staking_).code.length == 0) revert InvalidParams();
        IStakingContract old = staking;
        if (address(old) == address(staking_)) revert SameStaking();
        if (address(old) != address(0)) {
            old.deprecate();
            staking_.beginMigration();
            isWhitelisted[address(old)] = false;
            isHookExempt[address(old)] = false;
        }
        staking = staking_;
        isWhitelisted[address(staking_)] = true;
        isHookExempt[address(staking_)] = true;
        emit StakingSet(address(staking_));
    }

    /// @notice Admin-level on both sides: whitelisting cannot move or take balances —
    /// worst case it opens a transfer route, which removal closes again — and the
    /// load-bearing entries (this contract, the staking contract) are removal-guarded.
    function setWhitelisted(address addr, bool allowed) external onlyOwnerOrRoles(ROLE_ADMIN) {
        if (!allowed && (addr == address(this) || addr == address(staking))) revert InvalidParams();
        isWhitelisted[addr] = allowed;
        emit WhitelistSet(addr, allowed);
    }

    /// @notice Update hook exemption and reconcile shares; custody accounts stay exempt.
    function setHookExempt(address addr, bool exempt) external nonReentrant {
        if (exempt) _checkOwnerOrRoles(ROLE_ADMIN);
        else _checkOwner();
        if (addr == address(0)) revert InvalidParams();
        if (!exempt && (addr == address(this) || addr == address(staking))) revert InvalidParams();
        if (isHookExempt[addr] == exempt) return;
        IStakingContract _s = staking;
        if (exempt) {
            isHookExempt[addr] = true;

            uint256 held = _stakedSharesOf(addr);
            if (address(_s) != address(0) && held != 0) _s.notifyWithdraw(addr, held);
        } else {
            isHookExempt[addr] = false;
            uint256 implied = _stakedSharesOf(addr);
            if (address(_s) != address(0) && implied != 0) _s.notifyDeposit(addr, implied);
        }
        emit HookExemptSet(addr, exempt);
    }

    function freeRedeemAllowance(address user) external view returns (uint128) { return _bucket[user].allowance; }
    function lastFreeAccrualAt(address user) external view returns (uint64) { return _bucket[user].accruedAt; }

    /// @notice Direct penalties to sink; zero restores reward redistribution.
    function setPenaltySink(address sink) external onlyOwner {
        if (sink == address(this)) revert InvalidParams();
        penaltySink = sink;
        emit PenaltySinkSet(sink);
    }

    /// @notice Supply cap; zero disables it. Must cover the current supply.
    /// @notice Per-wallet cap; zero disables. Prospective-only (see `walletCap`).
    function setWalletCap(uint128 cap) external onlyOwner {
        walletCap = cap;
        emit WalletCapSet(cap);
    }

    function setSupplyCap(uint128 cap) external onlyOwner {
        if (cap != 0 && cap < totalSupply()) revert InvalidParams();
        supplyCap = cap;
        emit SupplyCapSet(cap);
    }

    /// @notice Allow a harder-lock destination; it must also register this token as a source.
    function setConversionDestination(address dest, bool allowed) external onlyOwner {
        if (allowed) {
            if (dest == address(this)) revert InvalidParams();
            if (address(EscrowedToken(dest).underlying()) != address(underlying)) revert InvalidParams();
        }
        isConversionDestination[dest] = allowed;
        emit ConversionDestinationSet(dest, allowed);
    }

    /// @notice Allow `source` (a softer-lock escrow) to convert into this token.
    function setConversionSource(address source, bool allowed) external onlyOwner {
        if (allowed && source == address(this)) revert InvalidParams();
        isConversionSource[source] = allowed;
        emit ConversionSourceSet(source, allowed);
    }

    function setRedemptionParams(
        uint64 minDuration_,
        uint64 maxDuration_,
        uint16 minRedeemBps_,
        uint16 partialStakeBps_
    ) external onlyOwner {
        if (minDuration_ > maxDuration_) revert InvalidParams();
        if (minRedeemBps_ > MAX_BPS || partialStakeBps_ > MAX_BPS) revert InvalidParams();
        minDuration = minDuration_;
        maxDuration = maxDuration_;
        minRedeemBps = minRedeemBps_;
        partialStakeBps = partialStakeBps_;
        emit RedemptionParamsUpdated();
    }

    function setInstantRedeemParams(uint32 ppmPerTick, uint64 cooldown) external onlyOwner {
        if (ppmPerTick > MAX_PPM || cooldown == 0) revert InvalidParams();
        freeRedeemPpmPerTick = ppmPerTick;
        freeRedeemCooldown = cooldown;
        emit InstantRedeemParamsUpdated();
    }

    function _depositFor(address to, uint256 amount) internal {
        if (address(staking) == address(0)) revert StakingNotSet();
        SafeTransferLib.safeTransferFrom(address(underlying), msg.sender, address(this), amount);
        _mint(to, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (from == address(0) || to == address(0)) return;

        if (to == address(this) && !_custodyOpen) revert NotWhitelisted();
        if (!isWhitelisted[from] && !isWhitelisted[to]) revert NotWhitelisted();
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // Custody moves (startUnstake/cancel) keep balance+locked constant, so skipping
        // them cannot leak past the wallet cap.
        if (_custodyOpen) return;
        uint128 wCap = walletCap;
        if (wCap != 0 && to != address(0) && !isHookExempt[to] && _redeemBase(to) > wCap) {
            revert WalletCapExceeded();
        }
        IStakingContract _s = staking;
        if (address(_s) == address(0)) return;

        if (from != address(0) && !isHookExempt[from]) _s.notifyWithdraw(from, amount);
        if (to != address(0) && !isHookExempt[to]) _s.notifyDeposit(to, amount);
    }

    function _mint(address to, uint256 amount) internal override {
        uint256 cap = supplyCap;
        if (cap != 0 && totalSupply() + amount > cap) revert SupplyCapExceeded();
        super._mint(to, amount);
    }

    function startUnstake(uint256 esAmount) external nonReentrant returns (uint256 index) {
        if (esAmount == 0) revert NothingToVest();

        _custodyOpen = true;
        _transfer(msg.sender, address(this), esAmount);
        _custodyOpen = false;

        uint256 partialShare;
        bool exempt = isHookExempt[msg.sender];

        if (!exempt) {
            unchecked {
                partialShare = (esAmount * partialStakeBps) / MAX_BPS;
            }
        }

        VestingPosition[] storage arr = _positions[msg.sender];
        index = arr.length;
        uint64 nowTs = uint64(block.timestamp);
        arr.push(VestingPosition({
            esAmount: uint128(esAmount),
            partialShare: uint128(partialShare),
            startedAt: nowTs,
            minUnlockAt: nowTs + minDuration,
            maxUnlockAt: nowTs + maxDuration,
            minRedeemBpsAtStart: minRedeemBps
        }));
        unchecked {
            lockedInVesting[msg.sender] += uint128(esAmount);
            livePartialShares[msg.sender] += uint128(partialShare);
        }

        if (!exempt) staking.notifyWithdraw(msg.sender, esAmount - partialShare);

        emit UnstakeStarted(msg.sender, index, esAmount);
    }

    function finalizeUnstake(uint256 index) external nonReentrant {
        VestingPosition[] storage arr = _positions[msg.sender];
        if (index >= arr.length) revert InvalidIndex();
        VestingPosition memory p = arr[index];
        if (p.esAmount == 0) revert InvalidIndex();

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < p.minUnlockAt) revert TooEarly();

        uint256 payoutBps;
        if (nowTs >= p.maxUnlockAt) {
            payoutBps = MAX_BPS;
        } else {
            unchecked {
                uint256 num = (MAX_BPS - uint256(p.minRedeemBpsAtStart)) * (nowTs - p.minUnlockAt);
                uint256 den = uint256(p.maxUnlockAt) - uint256(p.minUnlockAt);
                payoutBps = uint256(p.minRedeemBpsAtStart) + (num / den);
            }
        }

        uint256 esAmount = p.esAmount;
        uint256 albOut;
        uint256 penalty;
        unchecked {
            albOut  = (esAmount * payoutBps) / MAX_BPS;
            penalty = esAmount - albOut;
        }

        delete arr[index];
        unchecked {
            lockedInVesting[msg.sender] -= uint128(esAmount);
            livePartialShares[msg.sender] -= p.partialShare;
        }
        _custodyOpen = true;
        _burn(address(this), esAmount);
        _custodyOpen = false;

        if (p.partialShare != 0 && !isHookExempt[msg.sender]) {
            staking.notifyWithdraw(msg.sender, p.partialShare);
        }

        if (albOut != 0) SafeTransferLib.safeTransfer(address(underlying), msg.sender, albOut);

        if (penalty != 0) {
            address sink = penaltySink;
            if (sink != address(0)) {
                SafeTransferLib.safeTransfer(address(underlying), sink, penalty);
            } else {
                address _u = address(underlying);
                IStakingContract _s = staking;
                SafeTransferLib.safeApprove(_u, address(_s), penalty);
                _s.notifyReward(_u, penalty);
                SafeTransferLib.safeApprove(_u, address(_s), 0);
            }
        }

        emit UnstakeFinalized(msg.sender, index, albOut, penalty);
    }

    function cancelUnstake(uint256 index) external nonReentrant {
        VestingPosition[] storage arr = _positions[msg.sender];
        if (index >= arr.length) revert InvalidIndex();
        VestingPosition memory p = arr[index];
        if (p.esAmount == 0) revert InvalidIndex();

        delete arr[index];
        unchecked {
            lockedInVesting[msg.sender] -= p.esAmount;
            livePartialShares[msg.sender] -= p.partialShare;
        }

        _custodyOpen = true;
        _transfer(address(this), msg.sender, p.esAmount);
        _custodyOpen = false;
        if (!isHookExempt[msg.sender]) staking.notifyDeposit(msg.sender, p.esAmount - p.partialShare);

        emit UnstakeCancelled(msg.sender, index);
    }

    function instantRedeem(uint256 esAmount) external nonReentrant {
        _accrueInstantAllowance(msg.sender);
        RedeemBucket storage b = _bucket[msg.sender];
        uint128 alw = b.allowance;
        if (esAmount > alw) revert AmountExceedsAllowance();
        unchecked {
            b.allowance = alw - uint128(esAmount);
        }

        _burn(msg.sender, esAmount);
        SafeTransferLib.safeTransfer(address(underlying), msg.sender, esAmount);

        emit InstantRedeem(msg.sender, esAmount, esAmount);
    }

    /// @notice Convert 1:1 into an authorized harder-lock escrow, subject to its supply cap.
    function convertTo(address dest, uint256 amount) external nonReentrant {
        if (!isConversionDestination[dest]) revert NotConversionPath();
        if (amount == 0) revert InvalidParams();
        if (isHookExempt[msg.sender] && !EscrowedToken(dest).isHookExempt(msg.sender)) revert ExemptConversion();

        _burn(msg.sender, amount);
        SafeTransferLib.safeTransfer(address(underlying), dest, amount);
        EscrowedToken(dest).convertIn(msg.sender, amount);

        emit ConvertedOut(msg.sender, dest, amount);
    }

    /// @notice Mint a conversion after the registered source transfers the backing.
    function convertIn(address user, uint256 amount) external nonReentrant {
        if (!isConversionSource[msg.sender]) revert NotConversionPath();
        if (address(staking) == address(0)) revert StakingNotSet();

        _mint(user, amount);
        emit ConvertedIn(user, msg.sender, amount);
    }

    function _accrueInstantAllowance(address user) internal {
        uint64 cooldown = freeRedeemCooldown;
        uint64 currentEpochStart = _currentEpochStart(cooldown);
        RedeemBucket storage b = _bucket[user];
        if (b.accruedAt >= currentEpochStart) return;

        uint256 perTick;
        unchecked {
            perTick = (_redeemBase(user) * uint256(freeRedeemPpmPerTick)) / MAX_PPM;
        }

        _bucket[user] = RedeemBucket({allowance: uint128(perTick), accruedAt: currentEpochStart});
    }

    function _currentEpochStart(uint64 cooldown) internal view returns (uint64) {
        uint64 _epoch = epochStart;
        unchecked {
            return _epoch + uint64(((block.timestamp - _epoch) / cooldown) * cooldown);
        }
    }

    function previewInstantAllowance(address user) external view returns (uint256) {
        uint64 currentEpochStart = _currentEpochStart(freeRedeemCooldown);
        RedeemBucket storage b = _bucket[user];
        if (b.accruedAt >= currentEpochStart) return b.allowance;
        unchecked {
            return (_redeemBase(user) * uint256(freeRedeemPpmPerTick)) / MAX_PPM;
        }
    }

    function _redeemBase(address user) internal view returns (uint256) {
        return balanceOf(user) + uint256(lockedInVesting[user]);
    }

    /// @notice Staking consumer address used by the Distributor hook-registration check.
    function distributor() external view returns (address) {
        return address(staking);
    }

    /// @notice Liquid balance plus cached shares from active unstaking positions.
    function stakedSharesOf(address user) external view returns (uint256) {
        return _stakedSharesOf(user);
    }

    function _stakedSharesOf(address user) internal view returns (uint256) {
        return balanceOf(user) + uint256(livePartialShares[user]);
    }

    function positionsOf(address user) external view returns (VestingPosition[] memory) {
        return _positions[user];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MetadataReaderLib} from "solady/utils/MetadataReaderLib.sol";
import {Distributor} from "./Distributor.sol";

library DistributorIO {
    uint256 internal constant ACC_PRECISION = 1e27;
    uint256 internal constant MAX_EMISSION_DURATION = 3650 days;
    uint64 internal constant PERMANENT = type(uint64).max;
    uint256 internal constant MAX_STREAMS_PER_POOL = 8;
    uint256 internal constant PAYOUT_GAS_CAP = 150_000;
    uint256 internal constant HARVEST_PAYOUT_GAS = 1_000_000;
    uint256 internal constant VIEW_GAS_CAP = 100_000;
    uint256 internal constant REALISE_GAS_CAP = 300_000;
    uint64 internal constant MINT_RIGHTS_DELAY = 2 days;
    // Sized for a timelock-owned farm with a 7-day minDelay: the second timelock
    // round (applyMintRights) can be scheduled AFTER the first executes and still
    // land ~9 days before the schedule expires.
    uint64 internal constant MINT_RIGHTS_WINDOW = 14 days;

    bytes4 internal constant SEL_BALANCE_OF = 0x70a08231;
    bytes4 internal constant SEL_ALLOWANCE = 0xdd62ed3e;
    bytes4 internal constant SEL_TOTAL_SUPPLY = 0x18160ddd;
    bytes4 internal constant SEL_MAX_SUPPLY = 0x32cb6b0c;
    bytes4 internal constant SEL_DISTRIBUTOR = 0xbfe10928;
    bytes4 internal constant SEL_STAKED_SHARES_OF = 0x16bf1055;
    bytes4 internal constant SEL_IS_HOOK_EXEMPT = 0x8074c6d3;

    function wanted(Distributor.Stream storage s, Distributor.StreamEpoch storage epoch)
        internal
        view
        returns (uint256)
    {
        if (!s.active) return 0;
        uint256 end = s.emissionEnd;
        uint256 to = block.timestamp < end ? block.timestamp : end;
        uint256 last = s.lastUpdate;
        if (to <= last) return 0;
        uint256 want;
        bool epochMode = s.epochLength != 0;
        if (epochMode) {
            // Cumulative rounding preserves fractional rates across updates.
            uint256 start = epoch.start;
            uint256 length = epoch.length;
            uint256 budget = epoch.budget;
            want = FixedPointMathLib.fullMulDiv(budget, to - start, length)
                - FixedPointMathLib.fullMulDiv(budget, last - start, length);
        } else {
            want = (to - last) * s.ratePerSec;
            if (s.kind == Distributor.StreamKind.PULL) {
                uint256 pace = s.fundFeeBps > s.pullMaxFeeBps ? 0 : (to - last) * s.pullMaxPerSec;
                if (want > pace) want = pace;
            }
        }

        if (want > s.reserve && (s.kind == Distributor.StreamKind.BALANCE || epochMode)) want = s.reserve;
        return want;
    }

    function recomputeEnd(Distributor.Stream storage s) internal {
        uint256 rate = s.ratePerSec;
        if (rate == 0) {
            s.emissionEnd = uint64(block.timestamp);
            return;
        }
        uint256 dur = s.reserve / rate;
        if (dur > MAX_EMISSION_DURATION) dur = MAX_EMISSION_DURATION;
        s.emissionEnd = uint64(block.timestamp + dur);
    }

    function setEpochLength(Distributor.Stream storage s, Distributor.StreamEpoch storage epoch, uint64 length)
        internal
    {
        epoch.length = length;
        s.epochLength = uint32(length);
    }

    function tryTransferFrom(address token, address from, address to, uint256 amount, uint256 gasCap)
        internal
        returns (bool ok)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            let g := gas()
            mstore(0x60, amount)
            mstore(0x40, to)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom(address,address,uint256)
            ok := call(gasCap, token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), ok)) {
                ok := lt(or(iszero(extcodesize(token)), returndatasize()), ok)
            }
            if iszero(or(ok, gt(g, add(gasCap, add(div(gasCap, 63), 3000))))) { revert(0x00, 0x00) }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    function tryMint(address token, address to, uint256 amount, uint256 gasCap) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            let g := gas()
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0x40c10f19000000000000000000000000)
            if iszero(
                or(call(gasCap, token, 0, 0x10, 0x44, 0x00, 0x00), gt(g, add(gasCap, add(div(gasCap, 63), 3000))))
            ) { revert(0x00, 0x00) }
            mstore(0x40, m)
        }
    }

    function payReward(
        address token,
        address to,
        uint256 amount,
        uint256 budget,
        mapping(address => uint256) storage totalStakedOf
    ) internal returns (uint256 paid) {
        uint256 g0 = gasleft();
        (bool ok, uint256 bal) = read1(token, SEL_BALANCE_OF, address(this), budget);
        uint256 spent = g0 - gasleft();
        uint256 locked = totalStakedOf[token];
        uint256 available = ok && bal > locked ? bal - locked : 0;
        if (amount > available) {
            emit Distributor.RewardShortfall(token, to, amount, available);
            amount = available;
        }
        if (amount == 0) return 0;
        return tryTransfer(token, to, amount, budget > spent ? budget - spent : 0) ? amount : 0;
    }

    function tryTransfer(address token, address to, uint256 amount, uint256 gasCap) internal returns (bool ok) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
            ok := call(gasCap, token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), ok)) {
                ok := lt(or(iszero(extcodesize(token)), returndatasize()), ok)
            }
            mstore(0x40, m)
        }
    }

    function allowance(address token, address owner_) internal view returns (uint256 a) {
        (, a) = read2(token, SEL_ALLOWANCE, owner_, address(this), DistributorIO.VIEW_GAS_CAP);
    }

    function read0(address target, bytes4 sel, uint256 gasCap) internal view returns (bool ok, uint256 v) {
        assembly ("memory-safe") {
            mstore(0x00, sel)
            ok := staticcall(gasCap, target, 0x00, 0x04, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            v := mul(mload(0x00), ok)
        }
    }

    function read1(address target, bytes4 sel, address arg, uint256 gasCap)
        internal
        view
        returns (bool ok, uint256 v)
    {
        assembly ("memory-safe") {
            mstore(0x00, sel)
            mstore(0x04, shr(96, shl(96, arg)))
            ok := staticcall(gasCap, target, 0x00, 0x24, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            v := mul(mload(0x00), ok)
        }
    }

    function read2(address target, bytes4 sel, address a, address b, uint256 gasCap)
        internal
        view
        returns (bool ok, uint256 v)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel)
            mstore(add(m, 0x04), shr(96, shl(96, a)))
            mstore(add(m, 0x24), shr(96, shl(96, b)))
            ok := staticcall(gasCap, target, m, 0x44, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            v := mul(mload(0x00), ok)
        }
    }
}

library DistributorLogic {
    using SafeTransferLib for address;

    uint256 private constant MAX_FEE_BPS = 2000;

    function startEpoch(
        uint256 pid,
        uint256 index,
        Distributor.Stream storage s,
        Distributor.StreamEpoch storage epoch,
        Distributor.EpochConfig storage cfg,
        mapping(address => bool) storage isPullSource,
        address feeRecipient,
        bool enforceMin
    ) external {
        if (s.kind == Distributor.StreamKind.MINT) revert Distributor.WrongStreamKind();
        if (epoch.length == 0 || !s.active) revert Distributor.InvalidParams();
        if (epoch.budget != 0 && block.timestamp < s.emissionEnd) revert Distributor.EpochInProgress();

        uint64 pending = cfg.pendingLength;
        if (pending != 0) {
            DistributorIO.setEpochLength(s, epoch, pending);
            cfg.pendingLength = 0;
            emit Distributor.StreamEpochLengthSet(pid, index, pending);
        }
        uint256 length = epoch.length;

        if (s.kind == Distributor.StreamKind.PULL) {
            _pullEpochBudget(s, epoch, isPullSource, feeRecipient);
        }

        uint256 budget = s.reserve;
        if (budget == 0) revert Distributor.NothingToDo();
        if (enforceMin && (cfg.minBudget == 0 || budget < cfg.minBudget)) {
            revert Distributor.BudgetBelowMinimum();
        }
        if (block.timestamp > type(uint64).max - length) revert Distributor.InvalidParams();
        uint256 cap = uint256(type(uint128).max) * length;
        if (budget > cap) budget = cap;
        uint128 shown = uint128(budget / length);
        epoch.start = uint64(block.timestamp);
        epoch.budget = budget;
        s.lastUpdate = uint64(block.timestamp);
        s.ratePerSec = shown;
        s.emissionEnd = uint64(block.timestamp + length);
        emit Distributor.StreamEpochStarted(pid, index, budget, shown, s.emissionEnd);
    }

    function _pullEpochBudget(
        Distributor.Stream storage s,
        Distributor.StreamEpoch storage epoch,
        mapping(address => bool) storage isPullSource,
        address feeRecipient
    ) private {
        address src = s.source;
        if (!isPullSource[src]) return;
        uint256 feeBps = s.fundFeeBps;
        if (feeBps > s.pullMaxFeeBps) revert Distributor.FeeTooHigh();
        address t = s.token;
        uint256 cap_ = DistributorIO.VIEW_GAS_CAP;
        (bool ok, uint256 avail) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, src, cap_);
        if (!ok) return;
        uint256 allowance_ = DistributorIO.allowance(t, src);
        if (allowance_ < avail) avail = allowance_;
        uint256 cap = epoch.pullAmount;
        if (cap != 0 && avail > cap) avail = cap;
        cap = s.pullMaxWindow;
        if (cap > epoch.length) cap = epoch.length;
        cap *= s.pullMaxPerSec;
        if (avail > cap) avail = cap;
        if (avail == 0) return;

        uint256 before;
        (ok, before) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, address(this), cap_);
        if (!ok) return;
        DistributorIO.tryTransferFrom(t, src, address(this), avail, DistributorIO.REALISE_GAS_CAP);
        uint256 afterBal;
        (ok, afterBal) = DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, address(this), cap_);
        if (!ok || afterBal <= before) return;
        uint256 received = afterBal - before;
        if (received > avail) received = avail;
        uint256 fee = (received * feeBps) / 10_000;
        uint256 credit = s.pullFeeCredit;
        if (credit > fee) credit = fee;
        fee -= credit;
        if (fee != 0 && !DistributorIO.tryTransfer(t, feeRecipient, fee, DistributorIO.PAYOUT_GAS_CAP)) {
            emit Distributor.FeeTransferFailed(t, fee);
            fee = 0;
            credit = 0;
        }
        if (credit != 0) s.pullFeeCredit -= credit;
        received -= fee;
        s.reserve += received;
        s.pullFeePaid += fee + credit;
        s.pullNet += received;
    }

    function applyRate(uint256 pid, uint256 index, Distributor.Stream storage s, uint128 ratePerSec) external {
        s.ratePerSec = ratePerSec;
        if (s.kind == Distributor.StreamKind.BALANCE) DistributorIO.recomputeEnd(s);
        emit Distributor.StreamRateSet(pid, index, ratePerSec, s.emissionEnd);
    }

    function applyActive(uint256 pid, uint256 index, Distributor.Stream storage s, bool active) external {
        s.active = active;
        if (active) {
            s.lastUpdate = uint64(block.timestamp);

            if (s.kind == Distributor.StreamKind.BALANCE && s.epochLength == 0) DistributorIO.recomputeEnd(s);
        }
        emit Distributor.StreamActiveSet(pid, index, active);
    }

    function applyPullTerms(
        uint256 pid,
        uint256 index,
        Distributor.Stream storage s,
        uint16 maxFeeBps,
        uint128 maxPerSec,
        uint32 maxWindow
    ) external {
        if (maxFeeBps > MAX_FEE_BPS) revert Distributor.InvalidParams();
        if (maxPerSec != 0 && maxWindow == 0) revert Distributor.InvalidParams();
        (s.pullMaxFeeBps, s.pullMaxPerSec, s.pullMaxWindow) = (maxFeeBps, maxPerSec, maxWindow);
        emit Distributor.PullTermsSet(pid, index, msg.sender, maxFeeBps, maxPerSec, maxWindow);
    }

    function applyFundFee(uint256 pid, uint256 index, Distributor.Stream storage s, uint16 feeBps) external {
        if (feeBps > MAX_FEE_BPS) revert Distributor.InvalidParams();
        s.fundFeeBps = feeBps;
        emit Distributor.StreamFundFeeSet(pid, index, feeBps);
    }

    function setEpochLength(
        uint256 pid,
        uint256 index,
        Distributor.Stream storage s,
        Distributor.StreamEpoch storage epoch,
        Distributor.EpochConfig storage cfg,
        uint64 length
    ) external returns (bool tryStart) {
        if (s.kind == Distributor.StreamKind.MINT) revert Distributor.WrongStreamKind();
        if (length == 0 || length > DistributorIO.MAX_EMISSION_DURATION) revert Distributor.InvalidParams();
        if (epoch.budget != 0 && block.timestamp < s.emissionEnd) {
            cfg.pendingLength = length;
            emit Distributor.StreamEpochLengthQueued(pid, index, length);
            return false;
        }
        DistributorIO.setEpochLength(s, epoch, length);
        cfg.pendingLength = 0;
        epoch.start = 0;
        epoch.budget = 0;
        s.ratePerSec = 0;
        s.emissionEnd = uint64(block.timestamp);
        emit Distributor.StreamEpochLengthSet(pid, index, length);
        return s.active && (s.reserve != 0 || s.kind == Distributor.StreamKind.PULL);
    }

    function addStream(
        Distributor.Stream[] storage ss,
        uint256 pid,
        address token,
        Distributor.StreamKind kind,
        address source,
        address manager,
        uint16 fundFeeBps_
    ) external returns (uint256 index) {
        if (ss.length >= DistributorIO.MAX_STREAMS_PER_POOL) revert Distributor.StreamCapReached();
        ss.push(Distributor.Stream({
            token: token,
            kind: kind,
            active: true,
            lastUpdate: uint64(block.timestamp),
            fundFeeBps: fundFeeBps_,
            source: kind == Distributor.StreamKind.PULL ? source : address(0),
            ratePerSec: 0,
            emissionEnd: kind == Distributor.StreamKind.BALANCE ? uint64(block.timestamp) : DistributorIO.PERMANENT,
            generation: 0,
            epochLength: 0,
            reserve: 0,
            accPerShare: 0,
            owed: 0,
            pullMaxFeeBps: 0,
            pullMaxPerSec: 0,
            pullMaxWindow: 0,
            pullFeeCredit: 0,
            pullFeePaid: 0,
            pullNet: 0
        }));
        index = ss.length - 1;
        emit Distributor.StreamAdded(pid, index, token, kind, source, manager, fundFeeBps_);
    }

    function replaceStream(
        uint256 pid,
        uint256 index,
        Distributor.Stream storage s,
        address token,
        Distributor.StreamKind kind,
        address source,
        uint16 fundFeeBps_,
        address residualTo,
        mapping(address => uint256) storage mintRateOf,
        mapping(address => uint256) storage totalStakedOf,
        mapping(address => uint256) storage unsweptResidual
    ) external {
        if (residualTo == address(this)) revert Distributor.InvalidParams();
        address oldToken = s.token;
        if (s.kind == Distributor.StreamKind.MINT) {
            mintRateOf[oldToken] -= s.ratePerSec;
        }

        uint256 residual = s.reserve + s.owed;

        uint32 gen = s.generation + 1;
        s.token = token;
        s.kind = kind;
        s.active = true;
        s.lastUpdate = uint64(block.timestamp);
        s.fundFeeBps = fundFeeBps_;
        s.source = kind == Distributor.StreamKind.PULL ? source : address(0);
        s.ratePerSec = 0;
        s.emissionEnd = kind == Distributor.StreamKind.BALANCE ? uint64(block.timestamp) : DistributorIO.PERMANENT;
        s.generation = gen;
        s.epochLength = 0;
        s.reserve = 0;
        s.accPerShare = 0;
        s.owed = 0;
        s.pullMaxFeeBps = 0;
        s.pullMaxPerSec = 0;
        s.pullMaxWindow = 0;
        s.pullFeeCredit = 0;
        s.pullFeePaid = 0;
        s.pullNet = 0;

        if (residual != 0) {
            (bool ok, uint256 bal) = DistributorIO.read1(
                oldToken, DistributorIO.SEL_BALANCE_OF, address(this), DistributorIO.VIEW_GAS_CAP
            );
            if (ok) {
                uint256 locked = totalStakedOf[oldToken] + unsweptResidual[oldToken];
                uint256 free = bal > locked ? bal - locked : 0;
                if (residual > free) residual = free;
            }
        }
        if (residual != 0) {
            uint256 wanted = residual;
            residual = DistributorIO.payReward(
                oldToken, residualTo, residual, DistributorIO.HARVEST_PAYOUT_GAS, totalStakedOf
            );
            if (residual != wanted) unsweptResidual[oldToken] += wanted - residual;
        }
        emit Distributor.StreamReplaced(pid, index, oldToken, token, kind, residual);
    }

    function sweepResidual(
        mapping(address => uint256) storage unsweptResidual,
        mapping(address => uint256) storage totalStakedOf,
        address token,
        address to,
        uint256 amount
    ) external {
        if (to == address(this)) revert Distributor.InvalidParams();
        uint256 owed = unsweptResidual[token];
        (bool ok, uint256 bal) =
            DistributorIO.read1(token, DistributorIO.SEL_BALANCE_OF, address(this), DistributorIO.VIEW_GAS_CAP);
        if (ok) {
            uint256 locked = totalStakedOf[token];
            uint256 free = bal > locked ? bal - locked : 0;
            if (owed > free) owed = free;
        }
        if (amount > owed) amount = owed;
        uint256 paid;
        if (amount != 0) {
            paid = DistributorIO.payReward(token, to, amount, DistributorIO.HARVEST_PAYOUT_GAS, totalStakedOf);
        }
        if (paid == 0) revert Distributor.NothingToDo();
        unsweptResidual[token] = owed - paid;
        emit Distributor.ResidualSwept(token, to, paid);
    }

    function recoverReserve(
        uint256 pid,
        uint256 index,
        Distributor.Stream storage s,
        Distributor.StreamEpoch storage epoch,
        mapping(address => uint256) storage totalStakedOf,
        address to,
        uint256 amount
    ) external {
        if (s.kind == Distributor.StreamKind.MINT) revert Distributor.WrongStreamKind();
        if (s.kind == Distributor.StreamKind.PULL) to = s.source;
        else if (to == address(0)) revert Distributor.ZeroAddress();
        uint256 available = s.reserve;
        if (epoch.budget != 0 && block.timestamp < s.emissionEnd) {
            uint256 vested = FixedPointMathLib.fullMulDiv(epoch.budget, block.timestamp - epoch.start, epoch.length);
            available -= epoch.budget - vested;
        }
        address t = s.token;
        (bool ok, uint256 bal) =
            DistributorIO.read1(t, DistributorIO.SEL_BALANCE_OF, address(this), DistributorIO.VIEW_GAS_CAP);
        uint256 locked = totalStakedOf[t];
        uint256 free = ok && bal > locked ? bal - locked : 0;
        if (available > free) available = free;
        if (amount > available) amount = available;
        if (amount == 0) revert Distributor.NothingToDo();
        s.reserve -= amount;
        if (s.kind == Distributor.StreamKind.BALANCE && s.epochLength == 0) DistributorIO.recomputeEnd(s);
        if (s.kind == Distributor.StreamKind.PULL) {
            uint256 net = s.pullNet;
            if (net != 0) {
                uint256 part = amount < net ? amount : net;
                uint256 paid = s.pullFeePaid;
                uint256 back = FixedPointMathLib.fullMulDiv(paid, part, net);
                s.pullFeeCredit += back;
                s.pullFeePaid = paid - back;
                s.pullNet = net - part;
            }
        }
        t.safeTransfer(to, amount);
        emit Distributor.StreamReserveRecovered(pid, index, to, amount);
    }

    function addPool(
        Distributor.PoolInfo[] storage pools,
        uint256[] storage hookPids,
        mapping(address => uint256) storage hookPoolOf,
        mapping(address => uint256) storage depositPoolsOf,
        mapping(address => bool) storage isRewardToken,
        address stakeToken,
        Distributor.PoolKind kind
    ) external returns (uint256 pid) {
        if (stakeToken == address(0)) revert Distributor.ZeroAddress();

        if (kind == Distributor.PoolKind.HOOK) {
            if (hookPoolOf[stakeToken] != 0) revert Distributor.TokenAlreadyPooled();
            if (isRewardToken[stakeToken]) revert Distributor.RewardTokenCannotBeHook();
            if (depositPoolsOf[stakeToken] != 0) revert Distributor.TokenIsDepositStake();
            (bool ok, uint256 v) =
                DistributorIO.read0(stakeToken, DistributorIO.SEL_DISTRIBUTOR, DistributorIO.VIEW_GAS_CAP);
            if (!ok || v != uint256(uint160(address(this)))) revert Distributor.NotHookToken();
        } else {
            if (hookPoolOf[stakeToken] != 0) revert Distributor.TokenAlreadyPooled();
            depositPoolsOf[stakeToken] += 1;
        }

        pools.push(Distributor.PoolInfo({stakeToken: stakeToken, kind: kind, totalStaked: 0}));
        pid = pools.length - 1;
        if (kind == Distributor.PoolKind.HOOK) {
            hookPoolOf[stakeToken] = pid + 1;
            hookPids.push(pid);
        }

        emit Distributor.PoolAdded(pid, stakeToken, kind);
    }

    function setMintRights(
        mapping(address => uint256) storage mintRights,
        mapping(address => Distributor.PendingRights) storage pendingMintRights,
        address token,
        uint256 value
    ) external {
        if (value > mintRights[token]) revert Distributor.TimelockNotElapsed();
        mintRights[token] = value;
        if (pendingMintRights[token].executableAt != 0) {
            delete pendingMintRights[token];
            emit Distributor.MintRightsScheduleCancelled(token);
        }
        emit Distributor.MintRightsSet(token, value);
    }

    function scheduleMintRights(
        mapping(address => Distributor.PendingRights) storage pendingMintRights,
        address token,
        uint256 value
    ) external {
        if (value > type(uint192).max) revert Distributor.InvalidParams();
        uint64 at = uint64(block.timestamp) + DistributorIO.MINT_RIGHTS_DELAY;
        pendingMintRights[token] = Distributor.PendingRights({value: uint192(value), executableAt: at});
        emit Distributor.MintRightsScheduled(token, value, at);
    }

    function applyMintRights(
        mapping(address => uint256) storage mintRights,
        mapping(address => Distributor.PendingRights) storage pendingMintRights,
        address token
    ) external {
        Distributor.PendingRights memory p = pendingMintRights[token];
        if (p.executableAt == 0) revert Distributor.NothingScheduled();
        if (block.timestamp < p.executableAt) revert Distributor.TimelockNotElapsed();
        if (block.timestamp > uint256(p.executableAt) + DistributorIO.MINT_RIGHTS_WINDOW) {
            revert Distributor.ScheduleExpired();
        }
        delete pendingMintRights[token];
        mintRights[token] = p.value;
        emit Distributor.MintRightsSet(token, p.value);
    }

    function emergencyWithdraw(
        Distributor.PoolInfo[] storage pools,
        mapping(uint256 => mapping(address => Distributor.UserInfo)) storage users,
        mapping(uint256 => Distributor.Stream[]) storage streams,
        mapping(uint256 => mapping(address => mapping(uint256 => uint256))) storage rewardDebt,
        mapping(uint256 => mapping(address => mapping(uint256 => uint256))) storage rewardLockedUp,
        mapping(address => uint256) storage totalStakedOf,
        uint256 pid
    ) external {
        if (pid >= pools.length) revert Distributor.UnknownPool();
        Distributor.PoolInfo storage p = pools[pid];
        Distributor.UserInfo storage u = users[pid][msg.sender];

        uint256 amt = u.amount;
        if (amt == 0) revert Distributor.NothingToDo();

        u.amount = 0;
        u.nextHarvestUntil = 0;
        uint256 n = streams[pid].length;
        for (uint256 i; i < n;) {
            rewardDebt[pid][msg.sender][i] = 0;
            rewardLockedUp[pid][msg.sender][i] = 0;
            unchecked { ++i; }
        }
        p.totalStaked -= amt;

        if (p.kind == Distributor.PoolKind.DEPOSIT) {
            address stake = p.stakeToken;
            totalStakedOf[stake] -= amt;
            SafeTransferLib.safeTransfer(stake, msg.sender, amt);
        }
        emit Distributor.EmergencyWithdraw(msg.sender, pid, amt);
    }

    function clearDepositRegistration(
        mapping(address => uint256) storage totalStakedOf,
        mapping(address => uint256) storage depositPoolsOf,
        address token
    ) external {
        if (totalStakedOf[token] != 0) revert Distributor.NonZeroStake();
        depositPoolsOf[token] = 0;
        emit Distributor.DepositRegistrationCleared(token);
    }

    function cancelMintRights(
        mapping(address => Distributor.PendingRights) storage pendingMintRights,
        address token
    ) external {
        if (pendingMintRights[token].executableAt == 0) revert Distributor.NothingScheduled();
        delete pendingMintRights[token];
        emit Distributor.MintRightsScheduleCancelled(token);
    }

    function streamInfo(Distributor.Stream[] storage ss, uint256 index) external view returns (bytes memory) {
        Distributor.Stream memory m = ss[index];
        return abi.encode(m);
    }

    function pendingTokens(
        Distributor.Stream[] storage ss,
        mapping(uint256 => Distributor.StreamEpoch) storage epochs,
        mapping(uint256 => uint256) storage debts,
        mapping(uint256 => uint256) storage locks,
        mapping(uint256 => uint32) storage gens,
        uint256 amt,
        uint256 supply
    ) external view returns (bytes memory) {
        uint256 n = ss.length;
        address[] memory addresses = new address[](n);
        string[] memory symbols = new string[](n);
        uint256[] memory decimals = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);

        for (uint256 i; i < n;) {
            Distributor.Stream storage s = ss[i];
            address t = s.token;
            addresses[i] = t;
            symbols[i] = MetadataReaderLib.readSymbol(t);
            decimals[i] = MetadataReaderLib.readDecimals(t);

            uint256 acc = s.accPerShare;
            if (supply != 0) {
                uint256 want = _livePullNet(s, DistributorIO.wanted(s, epochs[i]));
                if (want != 0) {
                    acc += FixedPointMathLib.fullMulDiv(want, DistributorIO.ACC_PRECISION, supply);
                }
            }
            uint256 gross = FixedPointMathLib.fullMulDiv(amt, acc, DistributorIO.ACC_PRECISION);
            uint256 debt;
            uint256 locked;
            uint32 gen = s.generation;
            if (gen == 0 || gens[i] == gen) {
                debt = debts[i];
                locked = locks[i];
            }

            amounts[i] = (gross > debt ? gross - debt : 0) + locked;
            unchecked { ++i; }
        }
        return abi.encode(addresses, symbols, decimals, amounts);
    }

    function _livePullNet(Distributor.Stream storage s, uint256 amount) private view returns (uint256) {
        if (s.kind != Distributor.StreamKind.PULL || s.epochLength != 0) return amount;
        return amount - (amount * s.fundFeeBps) / 10_000;
    }

    function poolRewardsPerSec(Distributor.Stream[] storage ss) external view returns (bytes memory) {
        uint256 n = ss.length;
        address[] memory addresses = new address[](n);
        string[] memory symbols = new string[](n);
        uint256[] memory decimals = new uint256[](n);
        uint256[] memory rewardsPerSec = new uint256[](n);
        for (uint256 i; i < n;) {
            Distributor.Stream storage s = ss[i];
            addresses[i] = s.token;
            symbols[i] = MetadataReaderLib.readSymbol(s.token);
            decimals[i] = MetadataReaderLib.readDecimals(s.token);
            bool live = s.active && block.timestamp < s.emissionEnd;
            uint256 rate = live ? s.ratePerSec : 0;
            if (s.kind == Distributor.StreamKind.PULL && s.epochLength == 0) {
                if (rate > s.pullMaxPerSec) rate = s.pullMaxPerSec;
                if (s.fundFeeBps > s.pullMaxFeeBps) rate = 0;
            }
            rewardsPerSec[i] = _livePullNet(s, rate);
            unchecked { ++i; }
        }
        return abi.encode(addresses, symbols, decimals, rewardsPerSec);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IALB} from "../interfaces/IALB.sol";
import {ILoCFactory} from "../interfaces/ILoCFactory.sol";
import {IAlbPriceOracle} from "../interfaces/IAlbPriceOracle.sol";

contract LoC is Initializable, ReentrancyGuardTransient {
    ILoCFactory public factory;
    IALB public alb;
    IAlbPriceOracle public priceOracle;

    address public beneficiary;
    address internal _interestSink;

    uint256 public maxTotal;
    uint128 public maxDaily;
    uint128 public maxWeekly;

    uint256 public drawnAmount;

    uint256 public totalPrincipalMinted;
    uint256 public totalInterestMinted;
    uint256 public totalOptionMinted;
    uint256 public totalDebtWrittenOff;

    uint64  public interestRateBps;
    uint64  public lastAccrual;
    /// @notice Pauses draws; repayments and option redemptions remain available.
    bool    public drawsPaused;
    uint8 internal _drawHead;
    uint8 internal _drawCount;
    /// @notice Interest included in debt but awaiting mint to the sink.
    uint256 public unmintedInterest;
    /// @notice Unminted option grants, paid after pending interest.
    uint256 public unmintedGrant;

    struct DrawSample {
        uint64  ts;
        uint192 amount;
    }
    /// @dev A seven-day window spans at most eight UTC day buckets.
    DrawSample[8] internal _drawWindow;

    struct Option {
        uint256 amount;
        uint256 strikePrice;
        uint64  expiry;
        bool    redeemed;
    }
    Option[] public options;
    uint64 public optionClockOffset;

    event Drawn(address indexed to, uint256 amount, uint256 newDrawn);
    event Repaid(address indexed payer, uint256 amount, uint256 newDrawn);
    event InterestAccrued(uint256 amount, uint256 newDrawn);
    event DrawsPaused(bool paused);
    event InterestMinted(uint256 amount);
    event InterestMintDeferred(uint256 outstanding);
    event GrantMinted(uint256 amount);
    event GrantMintDeferred(uint256 amount);
    event ParametersUpdated();
    event OptionRedeemed(uint256 indexed index, uint256 amount, uint256 debtRetired, uint256 minted);

    error NotBeneficiary();
    error NotFactory();
    error ZeroAmount();
    error DrawsArePaused();
    error InterestUnpaid();
    error MaxTotalExceeded();
    error MaxDailyExceeded();
    error MaxWeeklyExceeded();
    error Overpay();
    error AlreadyRedeemed();
    error BelowStrike();
    error OptionExpired();
    error OracleUnhealthy();
    error InvalidIndex();

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert NotFactory();
        _;
    }

    struct InitParams {
        address factory;
        address alb;
        address priceOracle;
        address beneficiary;
        address interestSink;
        uint256 maxTotal;
        uint128 maxDaily;
        uint128 maxWeekly;
        uint64  interestRateBps;
        Option[] options;
    }

    constructor() {
        _disableInitializers();
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    function initialize(InitParams calldata p) external initializer {
        factory = ILoCFactory(p.factory);
        alb = IALB(p.alb);
        priceOracle = IAlbPriceOracle(p.priceOracle);
        beneficiary = p.beneficiary;
        _interestSink = p.interestSink;
        maxTotal = p.maxTotal;
        maxDaily = p.maxDaily;
        maxWeekly = p.maxWeekly;
        interestRateBps = p.interestRateBps;
        lastAccrual = uint64(block.timestamp);

        uint256 n = p.options.length;
        if (n != 0) optionClockOffset = uint64(block.timestamp - priceOracle.optionClock());
        for (uint256 i; i < n;) {
            options.push(p.options[i]);
            unchecked { ++i; }
        }
    }

    function setLimits(uint256 newMaxTotal, uint128 newMaxDaily, uint128 newMaxWeekly) external onlyFactory {
        pokeInterest();
        maxTotal = newMaxTotal;
        maxDaily = newMaxDaily;
        maxWeekly = newMaxWeekly;
        emit ParametersUpdated();
    }

    function setInterestRate(uint64 newRateBps) external onlyFactory {
        _accrue(true);
        _flushInterest();
        interestRateBps = newRateBps;
        emit ParametersUpdated();
    }

    function setDrawsPaused(bool paused) external onlyFactory {
        drawsPaused = paused;
        emit DrawsPaused(paused);
    }

    function setInterestSink(address newSink) external onlyFactory {
        pokeInterest();
        _interestSink = newSink;
        emit ParametersUpdated();
    }

    function interestSink() public view returns (address sink) {
        sink = _interestSink;
        if (sink == address(0)) sink = factory.stakingContract();
    }

    function draw(uint256 amount, address to) external onlyBeneficiary nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (drawsPaused) revert DrawsArePaused();

        _accrue(true);
        _flushInterest();

        if (unmintedInterest != 0) revert InterestUnpaid();
        uint256 _drawn = drawnAmount;

        if (amount > maxTotal || _drawn > maxTotal - amount) revert MaxTotalExceeded();

        (uint256 daily, uint256 weekly) = _drawWindows();
        if (daily + amount > maxDaily) revert MaxDailyExceeded();
        if (weekly + amount > maxWeekly) revert MaxWeeklyExceeded();

        unchecked {
            drawnAmount = _drawn + amount;
            totalPrincipalMinted += amount;
        }
        _recordDraw(amount);

        factory.mintWithRebase(to, amount);

        emit Drawn(to, amount, drawnAmount);
    }

    function repay(uint256 amount) external nonReentrant {
        _accrue(true);
        _flushInterest();
        uint256 _drawn = drawnAmount;
        if (amount > _drawn) revert Overpay();
        alb.burnFrom(msg.sender, amount);
        unchecked {
            drawnAmount = _drawn - amount;
        }
        emit Repaid(msg.sender, amount, drawnAmount);
    }

    /// @notice Capitalise interest; mint failures defer delivery to the sink.
    function pokeInterest() public {
        _accrue(false);
        _flushInterest();
    }

    /// @dev forceAdvance settles the old rate through now, including sub-unit interest.
    function _accrue(bool forceAdvance) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = lastAccrual;
        if (nowTs == last) return;
        uint256 _drawn = drawnAmount;
        uint64 rate = interestRateBps;
        if (_drawn == 0 || rate == 0) {
            lastAccrual = nowTs;
            return;
        }
        uint256 interest;
        unchecked {
            interest = (_drawn * rate * (nowTs - last)) / (365 days * 10_000);
        }
        if (interest == 0) {
            if (forceAdvance) lastAccrual = nowTs;
            return;
        }
        lastAccrual = nowTs;
        unchecked {
            drawnAmount = _drawn + interest;
            unmintedInterest += interest;
        }
        emit InterestAccrued(interest, drawnAmount);
    }

    function _flushInterest() internal {
        uint256 owed = unmintedInterest;
        if (owed != 0) {
            ILoCFactory f = factory;
            address live = f.stakingContract();
            address sink = _interestSink;
            if (sink == address(0)) sink = live;
            function(address, uint256) external mintFn = sink == live ? f.mintNoRebase : f.mintWithRebase;
            try mintFn(sink, owed) {
                unmintedInterest = 0;
                unchecked { totalInterestMinted += owed; }
                emit InterestMinted(owed);
            } catch {
                emit InterestMintDeferred(owed);
                return;
            }
        }
        uint256 grant = unmintedGrant;
        if (grant == 0) return;

        try factory.mintNoRebase(beneficiary, grant) {
            unmintedGrant = 0;
            emit GrantMinted(grant);
        } catch {
            emit GrantMintDeferred(grant);
        }
    }

    function optionsLength() external view returns (uint256) {
        return options.length;
    }

    function effectiveOptionExpiry(uint256 index) external view returns (uint256) {
        uint256 expiry = options[index].expiry;
        if (expiry == 0) return 0;
        return expiry + block.timestamp - (priceOracle.optionClock() + optionClockOffset);
    }

    function redeemOption(uint256 index) external onlyBeneficiary nonReentrant {
        if (index >= options.length) revert InvalidIndex();
        Option storage opt = options[index];
        if (opt.redeemed) revert AlreadyRedeemed();
        uint64 _exp = opt.expiry;
        IAlbPriceOracle _oracle = priceOracle;
        if (_exp != 0 && _oracle.optionClock() + optionClockOffset > _exp) revert OptionExpired();
        try _oracle.poke() returns (bool) {} catch {}
        if (!_oracle.isHealthy()) revert OracleUnhealthy();
        if (_oracle.sma20() < opt.strikePrice) revert BelowStrike();

        opt.redeemed = true;
        _accrue(true);

        uint256 fullGrant = opt.amount;
        uint256 _drawn = drawnAmount;
        uint256 debtRetired = fullGrant > _drawn ? _drawn : fullGrant;
        uint256 grant;
        unchecked {
            if (debtRetired != 0) {
                drawnAmount = _drawn - debtRetired;
                totalDebtWrittenOff += debtRetired;
                grant = fullGrant - debtRetired;
            } else {
                grant = fullGrant;
            }
        }

        if (grant != 0) {
            unchecked {
                totalOptionMinted += grant;
                unmintedGrant += grant;
            }
        }
        _flushInterest();

        emit OptionRedeemed(index, fullGrant, debtRetired, grant);
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

    function _drawWindows() internal view returns (uint256 daily, uint256 weekly) {
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

    function dailyDrawn() external view returns (uint256 daily) {
        (daily, ) = _drawWindows();
    }

    function weeklyDrawn() external view returns (uint256 weekly) {
        (, weekly) = _drawWindows();
    }
}

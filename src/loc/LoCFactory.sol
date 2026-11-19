// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IALB} from "../interfaces/IALB.sol";
import {IEscrowedToken} from "../interfaces/IEscrowedToken.sol";
import {ILoCFactory} from "../interfaces/ILoCFactory.sol";
import {LoC} from "./LoC.sol";

interface ILoCPausable {
    function setDrawsPaused(bool paused) external;
}

contract LoCFactory is OwnableRoles, ILoCFactory {
    /// @notice Admin may pause draws; only Owner may resume or change credit terms.
    uint256 public constant ROLE_ADMIN = 1 << 0;
    IALB public immutable alb;
    IEscrowedToken public immutable esALB;
    IEscrowedToken public immutable govALB;
    address public immutable locImplementation;

    address public stakingContract;
    address public immutable priceOracle;
    uint16 public constant MAX_CAP = 5000;
    uint16 public esALBpercentageCap = 5000;
    uint256 public pendingRebase;
    uint256 public totalIssued;
    uint256 public totalRebaseMinted;
    uint256 public aggregateIssuanceCap;

    address[] public allLoCs;
    mapping(address => bool) public override isLoC;

    event LoCCreated(address indexed loc, address indexed beneficiary, uint256 maxTotal);
    event Rebased(uint256 mintAmount, uint256 rebaseAmount);
    event RebasePulled(uint256 amount);
    event PercentageCapSet(uint16 newCap);
    event StakingContractSet(address staking);
    event AggregateCapSet(uint256 cap);

    error NotLoC();
    error NotStaking();
    error InvalidParams();
    error AggregateCapExceeded();

    constructor(
        address owner_,
        IALB alb_,
        IEscrowedToken esALB_,
        IEscrowedToken govALB_,
        address priceOracle_
    ) {
        if (priceOracle_ == address(0)) revert InvalidParams();
        _initializeOwner(owner_);
        alb = alb_;
        esALB = esALB_;
        govALB = govALB_;
        priceOracle = priceOracle_;
        locImplementation = address(new LoC());
    }

    function setStakingContract(address staking) external onlyOwner {
        if (staking == address(0)) revert InvalidParams();
        stakingContract = staking;
        emit StakingContractSet(staking);
    }

    function setPercentageCap(uint16 newCap) external onlyOwner {
        if (newCap > MAX_CAP) revert InvalidParams();
        esALBpercentageCap = newCap;
        emit PercentageCapSet(newCap);
    }

    function setAggregateIssuanceCap(uint256 cap) external onlyOwner {
        aggregateIssuanceCap = cap;
        emit AggregateCapSet(cap);
    }

    /// @param interestSink pass address(0) to use the StakingContract default.
    function createLoC(
        address beneficiary,
        address interestSink,
        uint256 maxTotal,
        uint128 maxDaily,
        uint128 maxWeekly,
        uint64 interestRateBps,
        LoC.Option[] calldata initialOptions
    ) external onlyOwner returns (address loc) {
        if (beneficiary == address(0)) revert InvalidParams();
        if (maxDaily > maxWeekly) revert InvalidParams();
        if (interestSink == address(0) && stakingContract == address(0)) revert InvalidParams();

        loc = LibClone.clone(locImplementation);
        LoC.InitParams memory p = LoC.InitParams({
            factory: address(this),
            alb: address(alb),
            priceOracle: priceOracle,
            beneficiary: beneficiary,
            interestSink: interestSink,
            maxTotal: maxTotal,
            maxDaily: maxDaily,
            maxWeekly: maxWeekly,
            interestRateBps: interestRateBps,
            options: initialOptions
        });
        LoC(loc).initialize(p);

        allLoCs.push(loc);
        isLoC[loc] = true;

        emit LoCCreated(loc, beneficiary, maxTotal);
    }

    /// @notice Adjust limits on an existing LoC (Owner-timelocked off-chain).
    function setLoCLimits(address loc, uint256 newMaxTotal, uint128 newMaxDaily, uint128 newMaxWeekly) external onlyOwner {
        if (!isLoC[loc]) revert NotLoC();
        if (newMaxDaily > newMaxWeekly) revert InvalidParams();
        LoC(loc).setLimits(newMaxTotal, newMaxDaily, newMaxWeekly);
    }

    function setLoCInterestRate(address loc, uint64 newRateBps) external onlyOwner {
        if (!isLoC[loc]) revert NotLoC();
        LoC(loc).setInterestRate(newRateBps);
    }

    /// @notice Freeze a LoC's draws. Admin may pause; only Owner may resume.
    function setLoCDrawsPaused(address loc, bool paused) external {
        if (paused) _checkOwnerOrRoles(ROLE_ADMIN);
        else _checkOwner();
        if (!isLoC[loc]) revert NotLoC();
        ILoCPausable(loc).setDrawsPaused(paused);
    }

    function setLoCInterestSink(address loc, address newSink) external onlyOwner {
        if (!isLoC[loc]) revert NotLoC();
        LoC(loc).setInterestSink(newSink);
    }

    modifier onlyLoC() {
        if (!isLoC[msg.sender]) revert NotLoC();
        _;
    }

    function mintWithRebase(address to, uint256 amount) external override onlyLoC {
        if (amount == 0) return;
        _checkAggregate(amount);

        IALB _alb = alb;
        uint256 sTotal = _alb.totalSupply();
        uint256 sEs;
        unchecked {
            sEs = esALB.totalSupply() + govALB.totalSupply();
        }

        uint256 rebase;
        if (sEs != 0 && sTotal != 0) {
            uint256 pWad;
            unchecked {
                pWad = (sEs * 1e18) / sTotal;
            }
            uint256 capWad;
            unchecked {
                capWad = uint256(esALBpercentageCap) * 1e14; // bps → WAD
            }
            uint256 effWad = pWad > capWad ? capWad : pWad;
            if (effWad != 0) {
                rebase = (amount * effWad) / (1e18 - effWad);
            }
        }

        if (rebase != 0) {
            _alb.mint(address(this), rebase);
            unchecked {
                pendingRebase += rebase;
                totalRebaseMinted += rebase;
            }
        }
        _alb.mint(to, amount);
        emit Rebased(amount, rebase);
    }

    /// @notice Option-redemption mint: no rebase.
    function mintNoRebase(address to, uint256 amount) external override onlyLoC {
        if (amount == 0) return;
        _checkAggregate(amount);
        alb.mint(to, amount);
    }

    function _checkAggregate(uint256 amount) internal {
        uint256 issued = totalIssued + amount;
        uint256 cap = aggregateIssuanceCap;
        if (cap != 0 && issued > cap) revert AggregateCapExceeded();
        totalIssued = issued;
    }

    function pullRebase() external override returns (uint256 amount) {
        address _staking = stakingContract;
        if (msg.sender != _staking) revert NotStaking();
        amount = pendingRebase;
        if (amount == 0) return 0;
        pendingRebase = 0;
        SafeTransferLib.safeTransfer(address(alb), _staking, amount);
        emit RebasePulled(amount);
    }

    function locsLength() external view returns (uint256) {
        return allLoCs.length;
    }
}

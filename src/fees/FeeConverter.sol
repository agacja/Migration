// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ActionPermissions} from "../utils/ActionPermissions.sol";
import {IALB} from "../interfaces/IALB.sol";
import {IStakingContract} from "../interfaces/IStakingContract.sol";
import {IAssetOracle} from "../interfaces/IAssetOracle.sol";

interface IStakingWiring {
    function deprecated() external view returns (bool);
    function esALB() external view returns (address);
    function govALB() external view returns (address);
}

interface IEscrowStaking {
    function staking() external view returns (address);
}

/// @notice Converts protocol fees to WETH, distributes rewards and funds ALB buybacks.
contract FeeConverter is OwnableRoles, ReentrancyGuardTransient {
    uint256 public constant ROLE_OPERATOR = 1 << 1;

    uint256 public constant MAX_BPS = 10_000;
    /// @notice Cap on the tolerated swap value loss (10%).
    uint16 public constant MAX_TOLERANCE_BPS = 1000;

    IALB public immutable alb;
    address public immutable weth;
    IStakingContract public staking;
    IAssetOracle public immutable assetOracle;

    mapping(address => bool) public isSwapTarget;

    /// @notice Max value loss on a swap leg vs the oracle, in bps of the value spent.
    uint16 public toleranceBps = 100;
    /// @notice Burn allocation in basis points; ALB burns directly and WETH funds buybacks.
    uint16 public burnBps;

    /// @notice WETH held here that is earmarked for buybackAndBurn and must not be streamed.
    uint256 public wethBurnBudget;
    ActionPermissions.Store internal _actionPermissions;

    struct Action {
        address target;
        bytes   data;
        address approveToken;
        address approveSpender;
        uint256 approveAmount;
    }

    event SwapTargetSet(address indexed target, bool allowed);
    event ActionPermissionSet(address indexed target, bytes4 indexed selector, address spender, bool allowed);
    event ToleranceSet(uint16 bps);
    event BurnBpsSet(uint16 bps);
    event ConvertedToWeth(uint256 valueOut, uint256 wethGained);
    event Distributed(uint256 albBurned, uint256 albStreamed, uint256 wethEarmarked, uint256 wethStreamed);
    event BoughtBackAndBurned(uint256 wethSpent, uint256 albBurned);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event StakingSet(address indexed staking);
    event BurnBudgetReleased(uint256 amount);

    error NotWhitelisted();
    error ForbiddenTarget();
    error InvalidActionData();
    error ActionNotAllowed();
    error ForbiddenToken();
    error ToleranceBreach();
    error StaleAssetOracle();
    error BudgetExceeded();
    error CallFailed();
    error InvalidParams();
    error NothingToDo();
    error StakingDeprecated();

    constructor(
        address owner_,
        IALB alb_,
        address weth_,
        IStakingContract staking_,
        IAssetOracle assetOracle_
    ) {
        if (
            owner_ == address(0) || address(alb_) == address(0) || weth_ == address(0)
                || address(staking_) == address(0) || address(assetOracle_) == address(0)
        ) revert InvalidParams();
        _initializeOwner(owner_);
        alb = alb_;
        weth = weth_;
        staking = staking_;
        assetOracle = assetOracle_;
    }

    function renounceOwnership() public payable override onlyOwner {
        revert("FeeConverter: ownership required");
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    function setSwapTarget(address target, bool allowed) external onlyOwner {
        if (allowed && _forbiddenTarget(target)) revert ForbiddenTarget();
        if (allowed && target.code.length == 0) revert ActionPermissions.InvalidActionTarget();
        if (isSwapTarget[target] != allowed) ActionPermissions.invalidate(_actionPermissions, target);
        isSwapTarget[target] = allowed;
        emit SwapTargetSet(target, allowed);
    }

    function setActionPermission(address target, bytes4 selector, address spender, bool allowed) external onlyOwner {
        if (allowed && (!isSwapTarget[target] || (spender != address(0) && !isSwapTarget[spender]))) {
            revert NotWhitelisted();
        }
        if (allowed && _forbiddenTarget(target)) revert ForbiddenTarget();
        ActionPermissions.set(_actionPermissions, target, selector, spender, allowed);
    }

    function actionPermission(address target, bytes4 selector)
        external view returns (ActionPermissions.Permission memory)
    {
        return _actionPermissions.permissions[target][selector];
    }

    function setToleranceBps(uint16 bps) external onlyOwner {
        if (bps > MAX_TOLERANCE_BPS) revert InvalidParams();
        toleranceBps = bps;
        emit ToleranceSet(bps);
    }

    function setStaking(IStakingContract staking_) external onlyOwner {
        if (isSwapTarget[address(staking_)]) revert InvalidParams();
        IStakingWiring cur = IStakingWiring(address(staking));
        if (
            IEscrowStaking(cur.esALB()).staking() != address(staking_)
                || IEscrowStaking(cur.govALB()).staking() != address(staking_)
        ) revert InvalidParams();
        staking = staking_;
        emit StakingSet(address(staking_));
    }

    function releaseBurnBudget(uint256 amount) external onlyOwner {
        uint256 budget = wethBurnBudget;
        if (amount == 0 || amount > budget) revert InvalidParams();
        unchecked { wethBurnBudget = budget - amount; }
        emit BurnBudgetReleased(amount);
    }

    function setBurnBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidParams();
        burnBps = bps;
        emit BurnBpsSet(bps);
    }

    /// @notice Recover fee tokens other than ALB and WETH.
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(alb) || token == weth) revert ForbiddenToken();
        if (to == address(0)) revert InvalidParams();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Recovered(token, to, amount);
    }

    /// @notice Swap the declared fee tokens to WETH under the oracle value limit.
    /// @param tokensIn Tokens permitted for spending; excludes ALB and WETH.
    function convertToWeth(address[] calldata tokensIn, Action[] calldata actions)
        external
        onlyRoles(ROLE_OPERATOR)
        nonReentrant
    {
        uint256 n = tokensIn.length;
        if (n == 0 || actions.length == 0) revert NothingToDo();

        uint256[] memory pre = new uint256[](n);
        uint256[] memory px = new uint256[](n);
        for (uint256 i; i < n;) {
            address tok = tokensIn[i];
            if (tok == address(alb) || tok == weth) revert ForbiddenToken();
            px[i] = _freshPrice(tok);
            pre[i] = SafeTransferLib.balanceOf(tok, address(this));
            unchecked { ++i; }
        }
        uint256 wethPx = _freshPrice(weth);
        uint256 wethBefore = SafeTransferLib.balanceOf(weth, address(this));
        uint256 albBefore = alb.balanceOf(address(this));

        _executeActions(actions, tokensIn);

        if (alb.balanceOf(address(this)) < albBefore) revert ToleranceBreach();
        uint256 wethAfter = SafeTransferLib.balanceOf(weth, address(this));
        if (wethAfter < wethBefore) revert ToleranceBreach();

        uint256 valueOut;
        for (uint256 i; i < n;) {
            uint256 post = SafeTransferLib.balanceOf(tokensIn[i], address(this));
            if (post < pre[i]) valueOut += ((pre[i] - post) * px[i]) / 1e18;
            unchecked { ++i; }
        }

        uint256 gained;
        unchecked { gained = wethAfter - wethBefore; }
        uint256 gainedValue = (gained * wethPx) / 1e18;
        uint256 minValue = valueOut - (valueOut * toleranceBps) / MAX_BPS;
        if (gainedValue < minValue) revert ToleranceBreach();

        emit ConvertedToWeth(valueOut, gained);
    }

    /// @notice Split ALB and WETH between staking rewards and the burn allocation.
    function distribute() external onlyRoles(ROLE_OPERATOR) nonReentrant {
        uint16 _burnBps = burnBps;

        uint256 albBal = alb.balanceOf(address(this));
        uint256 albBurn;
        uint256 albStream;
        if (albBal != 0) {
            albBurn = (albBal * _burnBps) / MAX_BPS;
            unchecked { albStream = albBal - albBurn; }
            if (albBurn != 0) alb.burn(albBurn);
            if (albStream != 0) _notifyStream(address(alb), albStream);
        }

        uint256 budget = wethBurnBudget;
        uint256 wethBal = SafeTransferLib.balanceOf(weth, address(this));

        uint256 avail;
        unchecked { avail = wethBal - budget; }
        uint256 wethEarmark;
        uint256 wethStream;
        if (avail != 0) {
            wethEarmark = (avail * _burnBps) / MAX_BPS;
            unchecked { wethStream = avail - wethEarmark; }
            if (wethEarmark != 0) wethBurnBudget = budget + wethEarmark;
            if (wethStream != 0) _notifyStream(weth, wethStream);
        }

        if (albBal == 0 && avail == 0) revert NothingToDo();
        emit Distributed(albBurn, albStream, wethEarmark, wethStream);
    }

    function _notifyStream(address token, uint256 amount) internal {
        IStakingContract _staking = staking;
        if (IStakingWiring(address(_staking)).deprecated()) revert StakingDeprecated();
        SafeTransferLib.safeApprove(token, address(_staking), amount);
        _staking.notifyReward(token, amount);
    }

    /// @notice Spend the WETH burn budget on ALB and burn the proceeds.
    function buybackAndBurn(Action[] calldata actions) external onlyRoles(ROLE_OPERATOR) nonReentrant {
        uint256 budget = wethBurnBudget;
        if (budget == 0 || actions.length == 0) revert NothingToDo();

        uint256 wethPx = _freshPrice(weth);
        uint256 albPx = _freshPrice(address(alb));
        uint256 wethBefore = SafeTransferLib.balanceOf(weth, address(this));
        uint256 albBefore = alb.balanceOf(address(this));

        address[] memory allowed = new address[](1);
        allowed[0] = weth;
        _executeActions(actions, allowed);

        uint256 wethAfter = SafeTransferLib.balanceOf(weth, address(this));
        if (wethAfter > wethBefore) wethAfter = wethBefore;
        uint256 spent;
        unchecked { spent = wethBefore - wethAfter; }
        if (spent > budget) revert BudgetExceeded();

        uint256 albAfter = alb.balanceOf(address(this));
        if (albAfter < albBefore) revert ToleranceBreach();
        uint256 acquired;
        unchecked { acquired = albAfter - albBefore; }

        uint256 acquiredValue = (acquired * albPx) / 1e18;
        uint256 spentValue = (spent * wethPx) / 1e18;
        uint256 minValue = spentValue - (spentValue * toleranceBps) / MAX_BPS;
        if (acquiredValue < minValue) revert ToleranceBreach();
        if (spent == 0 && acquired == 0) revert NothingToDo();

        unchecked { wethBurnBudget = budget - spent; }
        if (acquired != 0) alb.burn(acquired);

        emit BoughtBackAndBurned(spent, acquired);
    }

    function _forbiddenTarget(address target) internal view returns (bool) {
        return target == address(alb)
            || target == weth
            || target == address(staking)
            || target == address(assetOracle)
            || target == address(this);
    }

    function _executeActions(Action[] calldata actions, address[] memory allowedApprovals) internal {
        uint256 n = actions.length;
        for (uint256 i; i < n;) {
            _runAction(actions[i], allowedApprovals);
            unchecked { ++i; }
        }
    }

    function _runAction(Action calldata a, address[] memory allowedApprovals) internal {
        if (!isSwapTarget[a.target]) revert NotWhitelisted();
        if (_forbiddenTarget(a.target)) revert ForbiddenTarget();
        ActionPermissions.check(_actionPermissions, a.target, a.data, a.approveToken, a.approveSpender, a.approveAmount);

        address tok = a.approveToken;
        if (tok != address(0)) {
            bool ok_;
            uint256 m = allowedApprovals.length;
            for (uint256 i; i < m;) {
                if (allowedApprovals[i] == tok) { ok_ = true; break; }
                unchecked { ++i; }
            }
            if (!ok_) revert NotWhitelisted();
            if (!isSwapTarget[a.approveSpender]) revert NotWhitelisted();
            SafeTransferLib.safeApprove(tok, a.approveSpender, a.approveAmount);
        }

        (bool ok,) = a.target.call(a.data);
        if (!ok) revert CallFailed();

        if (tok != address(0)) SafeTransferLib.safeApprove(tok, a.approveSpender, 0);
    }

    function _freshPrice(address tok) internal view returns (uint256 p) {
        bool ok;
        (p, ok) = assetOracle.tryPriceOf(tok);
        if (!ok || p == 0) revert StaleAssetOracle();
    }
}

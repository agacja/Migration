// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IWrapperVault} from "../interfaces/IWrapperVault.sol";

/// @notice Minimal external surfaces of the Bunni LP token + gauge we need to interact with.
interface IBunniToken {
    function balanceOf(address) external view returns (uint256);
}

interface IBunniGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    /// @dev Claim to the vault, which forwards rewards to its depositor.
    function claim_rewards(address addr) external;
    function reward_tokens(uint256 i) external view returns (address);
}

/// @dev Primary gauge rewards require the staker to call Minter.mint.
interface IGaugeMinter {
    function mint(address gauge) external;
}

interface IBunniValuator {
    /// @notice Price of one bunni-token in the chosen numéraire (oracle decimals).
    function pricePerShare(address bunniToken) external view returns (uint256);
}

/// @notice Gauge-staked Bunni shares with reward forwarding and external valuation.
contract BunniWrapperVault is ERC20, Ownable, ReentrancyGuardTransient, IWrapperVault {
    IBunniToken public immutable bunniToken;
    IBunniGauge public immutable gauge;
    IBunniValuator public valuator;
    address public depositor;
    /// @notice Optional minter for primary gauge rewards.
    IGaugeMinter public gaugeMinter;
    address public primaryRewardToken;
    string private _name;
    string private _symbol;

    /// @dev Curve-lineage gauges define MAX_REWARDS = 8.
    uint256 internal constant MAX_REWARD_TOKENS = 8;

    event ValuatorSet(address valuator);
    event DepositorSet(address depositor);
    event Deposit(address indexed to, uint256 amount, uint256 shares);
    event Withdraw(address indexed from, uint256 shares, uint256 amount);
    event Harvest(address indexed caller);
    event GaugeMinterSet(address minter, address primaryRewardToken);
    event RewardRecovered(address indexed token, uint256 amount);

    error NotDepositor();
    error ZeroAddress();
    error ProtectedToken();

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }

    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        IBunniToken bunniToken_,
        IBunniGauge gauge_,
        IBunniValuator valuator_
    ) {
        if (
            owner_ == address(0) || address(bunniToken_) == address(0)
                || address(gauge_) == address(0) || address(valuator_) == address(0)
        ) revert ZeroAddress();
        _initializeOwner(owner_);
        bunniToken = bunniToken_;
        gauge = gauge_;
        valuator = valuator_;
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }

    function totalSupply() public view override(ERC20, IWrapperVault) returns (uint256) {
        return super.totalSupply();
    }

    function balanceOf(address account) public view override(ERC20, IWrapperVault) returns (uint256) {
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 amount) public override(ERC20, IWrapperVault) returns (bool) {
        return super.transfer(to, amount);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IWrapperVault) returns (bool) {
        return super.approve(spender, amount);
    }

    function setValuator(IBunniValuator v) external onlyOwner {
        if (address(v) == address(0)) revert ZeroAddress();
        valuator = v;
        emit ValuatorSet(address(v));
    }

    /// @notice Set the trusted primary-reward minter.
    function setGaugeMinter(IGaugeMinter minter, address primaryToken) external onlyOwner {
        if ((address(minter) == address(0)) != (primaryToken == address(0))) revert ZeroAddress();
        if (primaryToken != address(0)) _checkRewardToken(primaryToken);
        gaugeMinter = minter;
        primaryRewardToken = primaryToken;
        emit GaugeMinterSet(address(minter), primaryToken);
    }

    function setDepositor(address d) external onlyOwner {
        depositor = d;
        emit DepositorSet(d);
    }

    modifier onlyDepositor() {
        if (msg.sender != depositor) revert NotDepositor();
        _;
    }

    /// @notice Recover delisted rewards to the depositor; principal is excluded.
    function recoverReward(address token) external onlyOwner nonReentrant {
        _checkRewardToken(token);
        address to = depositor;
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = _balanceOf(token, address(this));
        if (amount != 0) SafeTransferLib.safeTransfer(token, to, amount);
        emit RewardRecovered(token, amount);
    }

    function _checkRewardToken(address token) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (_isProtected(token)) revert ProtectedToken();
    }

    function _isProtected(address token) internal view returns (bool) {
        return token == address(bunniToken) || token == address(gauge) || token == address(this);
    }

    function underlying() external view returns (address) {
        return address(bunniToken);
    }

    function deposit(bytes calldata data) external nonReentrant onlyDepositor returns (uint256 shares) {
        uint256 amount = abi.decode(data, (uint256));
        SafeTransferLib.safeTransferFrom(address(bunniToken), msg.sender, address(this), amount);

        SafeTransferLib.safeApprove(address(bunniToken), address(gauge), amount);
        gauge.deposit(amount);
        SafeTransferLib.safeApprove(address(bunniToken), address(gauge), 0);

        shares = amount;
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares, bytes calldata  ) external nonReentrant onlyDepositor returns (uint256 amount) {
        _burn(msg.sender, shares);
        amount = shares;
        gauge.withdraw(amount);
        SafeTransferLib.safeTransfer(address(bunniToken), msg.sender, amount);
        emit Withdraw(msg.sender, shares, amount);
    }

    /// @notice Forward claimed and existing rewards to the depositor.
    function harvest(bytes calldata  ) external nonReentrant onlyDepositor returns (
        address[] memory rewardTokens,
        uint256[] memory amounts
    ) {
        rewardTokens = new address[](MAX_REWARD_TOKENS + 1);
        IBunniGauge _gauge = gauge;

        uint256 used;
        for (uint256 i; i < MAX_REWARD_TOKENS;) {
            address rt;
            try _gauge.reward_tokens(i) returns (address t) {
                rt = t;
            } catch {
                break;
            }
            if (rt == address(0)) break;
            unchecked { ++i; }
            if (_isProtected(rt)) continue;
            bool listed;
            for (uint256 j; j < used;) {
                if (rewardTokens[j] == rt) { listed = true; break; }
                unchecked { ++j; }
            }
            if (!listed) { rewardTokens[used] = rt; unchecked { ++used; } }
        }
        address primary = primaryRewardToken;
        if (primary != address(0)) {
            bool listed;
            for (uint256 i; i < used;) {
                if (rewardTokens[i] == primary) { listed = true; break; }
                unchecked { ++i; }
            }
            if (!listed) { rewardTokens[used] = primary; unchecked { ++used; } }
        }

        address _self = address(this);
        _gauge.claim_rewards(_self);

        IGaugeMinter _m = gaugeMinter;
        if (address(_m) != address(0)) {
            try _m.mint(address(_gauge)) {} catch {}
        }
        amounts = new uint256[](used);
        for (uint256 i; i < used;) {
            uint256 amount = _balanceOf(rewardTokens[i], _self);
            amounts[i] = amount;
            if (amount != 0) {
                SafeTransferLib.safeTransfer(rewardTokens[i], msg.sender, amount);
            }
            unchecked { ++i; }
        }

        assembly ("memory-safe") {
            mstore(rewardTokens, used)
        }

        emit Harvest(msg.sender);
    }

    function pricePerShare() external view returns (uint256) {
        return valuator.pricePerShare(address(bunniToken));
    }

    function _balanceOf(address tok, address who) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(tok, who);
    }
}

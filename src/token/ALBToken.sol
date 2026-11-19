// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract ALBToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1_051_000_000 ether;

    mapping(address => bool) public isMinter;

    address public recoveryAdmin;

    event MinterAdded(address indexed minter);
    event MinterRevoked(address indexed minter);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveryAdminSet(address indexed admin);

    error NotMinter();
    error NotRecoveryAdmin();
    error MaxSupplyExceeded();
    error RenounceDisabled();

    constructor(address owner_, address recoveryAdmin_) {
        _initializeOwner(owner_);
        recoveryAdmin = recoveryAdmin_;
        emit RecoveryAdminSet(recoveryAdmin_);
    }

    function name() public pure override returns (string memory) {
        return "Alien Base Token";
    }

    function symbol() public pure override returns (string memory) {
        return "ALB";
    }

    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256(bytes("Alien Base Token"));
    }

    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    function addMinter(address minter) external onlyOwner {
        isMinter[minter] = true;
        emit MinterAdded(minter);
    }

    function revokeMinter(address minter) external onlyOwner {
        isMinter[minter] = false;
        emit MinterRevoked(minter);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) internal override {
        uint256 remaining;
        unchecked {
            remaining = MAX_SUPPLY - totalSupply();
        }
        if (amount > remaining) revert MaxSupplyExceeded();
        super._mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    function setRecoveryAdmin(address admin) external onlyOwner {
        recoveryAdmin = admin;
        emit RecoveryAdminSet(admin);
    }

    function recoverERC20(address token, address to, uint256 amount) external {
        if (msg.sender != recoveryAdmin) revert NotRecoveryAdmin();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Recovered(token, to, amount);
    }
}

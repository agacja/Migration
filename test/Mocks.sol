// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ITwapSource} from "../src/oracle/AlbPriceOracle.sol";
import {IAssetOracle} from "../src/interfaces/IAssetOracle.sol";

contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public view override returns (uint8) { return _decimals; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockLegacyEsALB is ERC20 {
    MockERC20 public immutable legacyALB;

    constructor(MockERC20 legacyALB_) { legacyALB = legacyALB_; }

    function name() public pure override returns (string memory) { return "Legacy esALB"; }
    function symbol() public pure override returns (string memory) { return "esALB-old"; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockTwapSource is ITwapSource {
    uint256 public price;
    uint256 public updatedAt;
    uint8 public immutable dec;

    constructor(uint256 price_, uint8 dec_) {
        price = price_;
        dec = dec_;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 p) external { price = p; updatedAt = block.timestamp; }
    function touch() external { updatedAt = block.timestamp; }
    function consult() external view returns (uint256) { return price; }
    function lastUpdate() external view returns (uint256) { return updatedAt; }
    function decimals() external view returns (uint8) { return dec; }
}

contract MockAssetOracle is IAssetOracle {
    mapping(address => uint256) internal _price;
    mapping(address => bool) internal _stale;
    uint8 public immutable dec;

    constructor(uint8 dec_) { dec = dec_; }

    function setPrice(address a, uint256 p) external { _price[a] = p; }
    function setStale(address a, bool s) external { _stale[a] = s; }
    function priceOf(address a) external view returns (uint256) { return _price[a]; }
    function tryPriceOf(address a) external view returns (uint256, bool) {
        if (_stale[a]) return (0, false);
        return (_price[a], _price[a] != 0);
    }
    function decimals() external view returns (uint8) { return dec; }
    function isStale(address a) external view returns (bool) { return _stale[a]; }
}

contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) { return "Wrapped Ether"; }
    function symbol() public pure override returns (string memory) { return "WETH"; }

    function deposit() external payable { _mint(msg.sender, msg.value); }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: send failed");
    }

    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MockRouter {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }

    function steal(address token, uint256 amount, address to) external {
        MockERC20(token).transferFrom(msg.sender, to, amount);
    }

    function claimRewards(address token, uint256 amount) external {
        MockERC20(token).mint(msg.sender, amount);
    }
}

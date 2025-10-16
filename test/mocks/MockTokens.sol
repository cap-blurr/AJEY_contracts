// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

contract MockERC20 is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _customDecimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// Simplified aToken that just mirrors balance when minting via supply
contract MockAToken is ERC20 {
    address public pool;
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function setPool(address p) external {
        pool = p;
    }

    function mint(address to, uint256 amt) external {
        require(msg.sender == pool, "only pool");
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external {
        require(msg.sender == pool, "only pool");
        _burn(from, amt);
    }
}

// Minimal WETH implementation for testing fallback path
contract MockWETH is ERC20, IWETH {
    constructor() ERC20("Mock WETH", "WETH") {}

    // Accept direct ETH sends and treat as deposit
    receive() external payable {
        deposit();
    }

    function deposit() public payable override {
        require(msg.value > 0, "no ETH");
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH send fail");
    }
}


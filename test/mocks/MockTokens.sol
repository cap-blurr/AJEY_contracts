// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _customDecimals;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _customDecimals = d; }
    function decimals() public view override returns (uint8) { return _customDecimals; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// Simplified aToken that just mirrors balance when minting via supply
contract MockAToken is ERC20 {
    address public pool;
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function setPool(address p) external { pool = p; }
    function mint(address to, uint256 amt) external { require(msg.sender == pool, "only pool"); _mint(to, amt); }
    function burn(address from, uint256 amt) external { require(msg.sender == pool, "only pool"); _burn(from, amt); }
}



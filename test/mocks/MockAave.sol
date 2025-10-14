// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockAToken} from "./MockTokens.sol";

contract MockAaveV3Pool is IAaveV3Pool {
    mapping(address => address) public aTokenOf; // underlying => aToken

    function setAToken(address asset, address aToken) external {
        aTokenOf[asset] = aToken;
        MockAToken(aToken).setPool(address(this));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /*referralCode*/ ) external override {
        if (amount == 0) return;
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        // Mint aToken to onBehalfOf
        MockAToken(aTokenOf[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        if (amount == type(uint256).max) {
            amount = IERC20(aTokenOf[asset]).balanceOf(msg.sender);
        }
        MockAToken(aTokenOf[asset]).burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}

// Minimal WETH gateway for native ETH path
contract MockWETHGateway {
    address public pool;
    address public weth;
    constructor(address _pool, address _weth) { pool = _pool; weth = _weth; }

    receive() external payable {}

    function depositETH(address /*pool_*/, address onBehalfOf, uint16 /*ref*/ ) external payable {
        // Wrap ETH to WETH balance simulation: transfer msg.value WETH to pool then mint aWETH to onBehalfOf
        // For tests, we simulate by transferring WETH to pool contract and minting aToken there.
        // Here we just call supply on the pool assuming msg.sender has approved; instead transfer directly to pool.
        // In mocks, we skip strictness and just mint aToken to onBehalfOf 1:1
        // No-op: Pool mock mints in supply(). We'll simulate by calling pool.supply via msg.sender normally in tests.
    }

    function withdrawETH(address /*pool_*/, uint256 amount, address to) external {
        // In a real gateway, it would burn aWETH from msg.sender and send ETH to `to`.
        // For tests, we just transfer ETH directly if available.
        (bool ok,) = to.call{value: amount}("");
        require(ok, "eth send fail");
    }
}



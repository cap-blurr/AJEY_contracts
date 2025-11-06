// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Minimal mock swap aggregator used for tests with AgentReallocator
contract MockAggregator {
    function swap(address assetFrom, address assetTo, uint256 amountIn, uint256 amountOut) external {
        // Pull assetFrom from caller (requires allowance)
        if (amountIn > 0) {
            IERC20(assetFrom).transferFrom(msg.sender, address(this), amountIn);
        }
        // Pay assetTo to caller (requires the aggregator to hold assetTo beforehand)
        if (amountOut > 0) {
            IERC20(assetTo).transfer(msg.sender, amountOut);
        }
    }
}


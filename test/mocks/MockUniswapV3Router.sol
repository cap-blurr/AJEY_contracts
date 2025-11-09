// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Router} from "../../src/interfaces/IUniswapV3Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUniswapV3Router is IUniswapV3Router {
    using SafeERC20 for IERC20;

    uint256 public lastAmountIn;
    uint256 public lastAmountOut;

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        if (params.amountIn > 0) {
            IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        }
        // 1:1 mock swap output
        uint256 output = params.amountIn;
        require(output >= params.amountOutMinimum, "min out");
        if (output > 0) {
            IERC20(params.tokenOut).safeTransfer(msg.sender, output);
        }
        lastAmountIn = params.amountIn;
        lastAmountOut = output;
        return output;
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniswapV3QuoterV2
/// @notice Minimal interface for Uniswap V3 Quoter V2
interface IUniswapV3QuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns a quote for a swap of exact input amount for a single pool
    /// @return amountOut The amount of `tokenOut` that would be received
    /// @return sqrtPriceX96After The sqrt price after the swap
    /// @return initializedTicksCrossed The number of initialized ticks crossed during the swap
    /// @return gasEstimate The estimated gas used for the swap
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}



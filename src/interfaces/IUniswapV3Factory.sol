// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniswapV3Factory
/// @notice Minimal interface for Uniswap V3 Factory
interface IUniswapV3Factory {
    /// @notice Returns the pool address for a given pair of tokens and fee
    /// @param tokenA The first token
    /// @param tokenB The second token
    /// @param fee The fee tier
    /// @return pool The pool address
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniswapV3Pool
/// @notice Minimal interface for Uniswap V3 Pool (for quoting)
interface IUniswapV3Pool {
    /// @notice The pool's current price and tick
    /// @return sqrtPriceX96 The current price
    /// @return tick The current tick
    /// @return observationIndex The current observation index
    /// @return observationCardinality The current observation cardinality
    /// @return observationCardinalityNext The next observation cardinality
    /// @return feeProtocol The protocol fee
    /// @return unlocked Whether the pool is unlocked
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

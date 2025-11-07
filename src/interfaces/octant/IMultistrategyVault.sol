// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMultistrategyVault (Octant v2 core)
/// @notice Minimal interface used by the agent to allocate and rebalance
interface IMultistrategyVault {
    // ERC-4626 surface (subset as needed)
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    // Strategy management
    function addStrategy(address newStrategy_, bool addToQueue_) external;
    function updateMaxDebtForStrategy(address strategy_, uint256 newMaxDebt_) external;
    function updateDebt(address strategy_, uint256 targetDebt_, uint256 maxLoss_) external returns (uint256);
}


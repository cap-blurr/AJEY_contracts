// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPaymentSplitter (Octant v2 core)
/// @notice Minimal interface for Octant's PaymentSplitter
interface IPaymentSplitter {
    // One-time initializer with payees and proportional shares
    function initialize(address[] calldata payees, uint256[] calldata shares_) external;

    // ERC20 release
    function release(address token, address account) external;

    // Views
    function totalShares() external view returns (uint256);
    function shares(address account) external view returns (uint256);
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategyPermit
/// @notice Minimal interface for EIP-2612 permit on Octant TokenizedStrategy share tokens
interface IStrategyPermit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}


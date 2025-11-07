// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMultistrategyVaultFactory (Octant v2 core)
/// @notice Minimal factory interface to deploy a new MSV
interface IMultistrategyVaultFactory {
    function deployNewVault(
        address asset,
        string memory name_,
        string memory symbol_,
        address roleManager,
        uint256 profitMaxUnlockTime
    ) external returns (address);
}


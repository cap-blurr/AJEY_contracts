// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDonationSplitter {
    /// @notice Account and split newly received strategy shares already held by the splitter
    /// @param token Strategy share token address (the strategy contract)
    /// @param amount Amount of newly received shares to account
    function receiveShares(address token, uint256 amount) external;
}



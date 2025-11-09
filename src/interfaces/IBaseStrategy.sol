// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBaseStrategy
/// @notice Interface for Octant Yield-Donating Strategies
interface IBaseStrategy {
    /// @notice Reports profits/losses and triggers donation minting
    /// @return profit The profit amount (if any) since last report
    /// @return loss The loss amount (if any) since last report
    function report() external returns (uint256 profit, uint256 loss);

    /// @notice Deposit assets and receive strategy shares
    /// @param assets Amount to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraw assets by burning shares
    /// @param assets Amount to withdraw
    /// @param receiver Address to receive assets
    /// @param owner Address whose shares to burn
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Returns the total assets under management
    function totalAssets() external view returns (uint256);

    /// @notice Returns the underlying asset
    function asset() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {AjeyVault} from "../core/AjeyVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title YDS_AaveUSDC
/// @notice Yield-Donating Strategy for USDC via AjeyVault
/// @dev Wraps AjeyVault to donate yield while preserving principal
contract YDS_AaveUSDC is BaseStrategy {
    using SafeERC20 for IERC20;

    AjeyVault public immutable ajeyVault;

    /// @notice Constructor
    /// @param _ajeyVault The AjeyVault to wrap
    /// @param _donationAddress Address to receive donation shares
    /// @param _admin Admin address
    constructor(AjeyVault _ajeyVault, address _donationAddress, address _admin)
        BaseStrategy(_ajeyVault.asset(), _donationAddress, "YDS Aave USDC", "ydsAaveUSDC")
    {
        ajeyVault = _ajeyVault;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(MANAGEMENT_ROLE, _admin);

        // Approve vault for max
        IERC20(asset).forceApprove(address(ajeyVault), type(uint256).max);
    }

    /// @notice Deploy funds to AjeyVault
    /// @param amount Amount to deploy
    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;
        ajeyVault.deposit(amount, address(this));
        emit FundsDeployed(amount);
    }

    /// @notice Free funds from AjeyVault
    /// @param amount Amount to free
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        ajeyVault.withdraw(amount, address(this), address(this));
        emit FundsFreed(amount);
    }

    /// @notice Report total assets including those in AjeyVault
    /// @return Total assets under management
    function _harvestAndReport() internal view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 invested = ajeyVault.maxWithdraw(address(this));
        return idle + invested;
    }

    /// @notice Add a keeper
    /// @param keeper Address to grant keeper role
    function addKeeper(address keeper) external onlyRole(MANAGEMENT_ROLE) {
        _grantRole(KEEPER_ROLE, keeper);
    }

    /// @notice Remove a keeper
    /// @param keeper Address to revoke keeper role
    function removeKeeper(address keeper) external onlyRole(MANAGEMENT_ROLE) {
        _revokeRole(KEEPER_ROLE, keeper);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {AjeyVault} from "../core/AjeyVault.sol";

/// @title AaveYieldDonatingStrategy
/// @notice Yield-Donating Strategy that deploys a single asset into a single AjeyVault (Aave) and donates profit on report()
/// @dev This strategy strictly adheres to Octant's single-source invariant: it interacts with only one external source (AjeyVault).
///      Cross-asset swaps and multi-venue orchestration must be handled at the periphery (e.g., Orchestrator/Reallocator).
contract AaveYieldDonatingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Target AjeyVault (must have the same asset as this strategy)
    AjeyVault public vault;
    /// @notice Emitted when the target vault is updated
    /// @param vault New vault address
    event VaultUpdated(address indexed vault);

    /// @param _asset The underlying asset for this strategy (must equal vault.asset())
    /// @param _donationAddress Address which receives minted donation shares on profit (e.g., DonationSplitter)
    /// @param _name ERC20 name for the strategy share token
    /// @param _symbol ERC20 symbol for the strategy share token
    /// @param _vault The AjeyVault that holds the same asset and supplies to Aave
    /// @param _admin Address to grant DEFAULT_ADMIN, KEEPER, and MANAGEMENT roles
    constructor(
        address _asset,
        address _donationAddress,
        string memory _name,
        string memory _symbol,
        address payable _vault,
        address _admin
    ) BaseStrategy(_asset, _donationAddress, _name, _symbol) {
        require(_vault != address(0), "vault=0");
        require(AjeyVault(_vault).asset() == _asset, "asset mismatch");
        vault = AjeyVault(_vault);

        // Grant roles to admin
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(MANAGEMENT_ROLE, _admin);

        // Approve max allowance for vault deposits
        IERC20(_asset).forceApprove(_vault, type(uint256).max);

        emit VaultUpdated(_vault);
    }

    /// @notice Set a new AjeyVault (must share the same asset)
    /// @dev Updates infinite approval to the new vault
    /// @param _vault New vault address
    function setVault(address payable _vault) external onlyRole(MANAGEMENT_ROLE) {
        require(_vault != address(0), "vault=0");
        require(AjeyVault(_vault).asset() == address(asset), "asset mismatch");
        vault = AjeyVault(_vault);
        IERC20(address(asset)).forceApprove(_vault, type(uint256).max);
        emit VaultUpdated(_vault);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Deploy funds by depositing the asset directly into the vault
    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;
        vault.deposit(amount, address(this));
        emit FundsDeployed(amount);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Free funds by withdrawing the asset directly from the vault
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        vault.withdraw(amount, address(this), address(this));
        emit FundsFreed(amount);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Total assets equals idle asset balance plus vault's maxWithdrawable for this strategy
    function _harvestAndReport() internal view override returns (uint256) {
        uint256 idle = IERC20(address(asset)).balanceOf(address(this));
        if (address(vault) == address(0)) return idle;
        uint256 redeemable = vault.maxWithdraw(address(this));
        return idle + redeemable;
    }
}


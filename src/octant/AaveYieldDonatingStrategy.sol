// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "@octant-core/core/BaseStrategy.sol";
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

    /// @param _asset Underlying asset
    /// @param _name Strategy name
    /// @param _management Management address
    /// @param _keeper Keeper address
    /// @param _emergencyAdmin Emergency admin address
    /// @param _donationAddress Donation destination (e.g., PaymentSplitter)
    /// @param _enableBurning Whether to allow burning router shares on loss
    /// @param _tokenizedStrategyImpl TokenizedStrategy implementation address
    /// @param _vault The AjeyVault that holds the same asset and supplies to Aave
    constructor(
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyImpl,
        address payable _vault
    )
        BaseStrategy(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyImpl
        )
    {
        require(_vault != address(0), "vault=0");
        require(AjeyVault(_vault).asset() == _asset, "asset mismatch");
        vault = AjeyVault(_vault);

        // Approve max allowance for vault deposits
        IERC20(_asset).forceApprove(_vault, type(uint256).max);

        emit VaultUpdated(_vault);
    }

    /// @notice Set a new AjeyVault (must share the same asset)
    /// @dev Updates infinite approval to the new vault
    /// @param _vault New vault address
    function setVault(address payable _vault) external onlyManagement {
        require(_vault != address(0), "vault=0");
        // 'asset' is ERC20 internal immutable in Octant BaseStrategy
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
    }

    /// @inheritdoc BaseStrategy
    /// @dev Free funds by withdrawing the asset directly from the vault
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        vault.withdraw(amount, address(this), address(this));
    }

    /// @inheritdoc BaseStrategy
    /// @dev Total assets equals idle asset balance plus vault's maxWithdrawable for this strategy
    function _harvestAndReport() internal override returns (uint256) {
        uint256 idle = IERC20(address(asset)).balanceOf(address(this));
        if (address(vault) == address(0)) return idle;
        uint256 redeemable = vault.maxWithdraw(address(this));
        return idle + redeemable;
    }
}


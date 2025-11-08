// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDonationSplitter} from "../interfaces/octant/IDonationSplitter.sol";

/// @title BaseStrategy
/// @notice Minimal implementation of Octant's Yield-Donating Strategy base
/// @dev This is a simplified version for the hackathon - production should use official Octant contracts
abstract contract BaseStrategy is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");

    // Core state
    IERC20 public immutable asset;
    address public immutable donationAddress;
    uint256 public lastTotalAssets;

    // Events
    event Reported(uint256 profit, uint256 loss, uint256 donationShares);
    event FundsDeployed(uint256 amount);
    event FundsFreed(uint256 amount);

    /// @notice Constructor
    /// @param _asset The underlying asset
    /// @param _donationAddress Address to receive donation shares
    /// @param _name Strategy name
    /// @param _symbol Strategy symbol
    constructor(address _asset, address _donationAddress, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
    {
        require(_asset != address(0), "asset=0");
        require(_donationAddress != address(0), "donation=0");

        asset = IERC20(_asset);
        donationAddress = _donationAddress;

        // Set up initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
        _grantRole(MANAGEMENT_ROLE, msg.sender);
    }

    /// @notice Deposit assets and receive strategy shares
    /// @param assets Amount to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");

        // Calculate shares (1:1 initially, then based on totalAssets/totalSupply)
        if (totalSupply() == 0) {
            shares = assets;
        } else {
            shares = (assets * totalSupply()) / totalAssets();
        }

        // Transfer assets from depositor
        asset.safeTransferFrom(msg.sender, address(this), assets);

        // Deploy funds to underlying strategy
        _deployFunds(assets);

        // Mint shares to receiver
        _mint(receiver, shares);

        return shares;
    }

    /// @notice Withdraw assets by burning shares
    /// @param assets Amount to withdraw
    /// @param receiver Address to receive assets
    /// @param owner Address whose shares to burn
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256 shares) {
        // Calculate shares needed (ROUND UP to avoid under-burning)
        uint256 _totalSupply = totalSupply();
        uint256 _totalAssets = totalAssets();
        shares = (assets * _totalSupply + (_totalAssets - 1)) / _totalAssets;

        // Check allowance if not owner
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "insufficient allowance");
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        // Burn shares
        _burn(owner, shares);

        // Free funds from strategy
        _freeFunds(assets);

        // Transfer assets to receiver
        asset.safeTransfer(receiver, assets);

        return shares;
    }

    /// @notice Report profits/losses and mint donation shares
    /// @dev Only callable by keepers
    /// @return profit Amount of profit
    /// @return loss Amount of loss
    function report() external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 profit, uint256 loss) {
        uint256 currentAssets = totalAssets();
        uint256 lastAssets = lastTotalAssets;

        // First report guard: initialize baseline, do not donate principal
        if (lastAssets == 0) {
            lastTotalAssets = currentAssets;
            return (0, 0);
        }

        if (currentAssets > lastAssets) {
            profit = currentAssets - lastAssets;

            // Mint donation shares for profit based on lastAssets baseline
            if (profit > 0 && totalSupply() > 0) {
                uint256 donationShares = (profit * totalSupply()) / lastAssets;
                if (donationShares > 0) {
                    _mint(donationAddress, donationShares);
                    // Auto-account the newly minted shares in the splitter
                    // Ignore failures so report() cannot be bricked by a misconfigured splitter
                    try IDonationSplitter(donationAddress).receiveShares(address(this), donationShares) {} catch {}
                    emit Reported(profit, 0, donationShares);
                }
            }
        } else if (currentAssets < lastAssets) {
            loss = lastAssets - currentAssets;

            // Burn donation shares first on loss based on lastAssets baseline
            uint256 sharesToBurn = (loss * totalSupply()) / lastAssets;
            uint256 donationBalance = balanceOf(donationAddress);

            if (sharesToBurn > 0 && donationBalance > 0) {
                uint256 burnAmount = sharesToBurn > donationBalance ? donationBalance : sharesToBurn;
                _burn(donationAddress, burnAmount);
                emit Reported(0, loss, burnAmount);
            }
        }

        lastTotalAssets = currentAssets;

        return (profit, loss);
    }

    /// @notice Get total assets under management
    /// @return Total assets
    function totalAssets() public view returns (uint256) {
        return _harvestAndReport();
    }

    // Abstract functions to be implemented by strategies

    /// @notice Deploy funds to the underlying yield source
    /// @param amount Amount to deploy
    function _deployFunds(uint256 amount) internal virtual;

    /// @notice Free funds from the underlying yield source
    /// @param amount Amount to free
    function _freeFunds(uint256 amount) internal virtual;

    /// @notice Harvest yield and report total assets
    /// @return Total assets under management
    function _harvestAndReport() internal view virtual returns (uint256);

    // =========================================================
    // Octant-compatible external hooks (non-restrictive)
    // These wrappers expose the internal hooks using the names
    // expected by Octant's TokenizedStrategy lifecycle.
    // =========================================================

    /// @notice Deploy funds to the underlying yield source
    /// @dev Exposes the internal _deployFunds hook for compatibility
    /// @param _amount Amount to deploy
    function deployFunds(uint256 _amount) external {
        _deployFunds(_amount);
    }

    /// @notice Free funds from the underlying yield source
    /// @dev Exposes the internal _freeFunds hook for compatibility
    /// @param _amount Amount to free
    function freeFunds(uint256 _amount) external {
        _freeFunds(_amount);
    }

    /// @notice Harvest and return total assets under management
    /// @dev Exposes the internal _harvestAndReport hook for compatibility
    /// @return Total assets in base units
    function harvestAndReport() external view returns (uint256) {
        return _harvestAndReport();
    }
}

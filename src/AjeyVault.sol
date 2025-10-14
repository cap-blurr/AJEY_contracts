// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IETHGateway} from "./interfaces/IETHGateway.sol";

/// @title AjeyVault
/// @notice ERC-4626 vault that supplies assets to Aave V3 and maintains fee checkpointing.
/// @dev aTokens are held by this vault. Agents can trigger supply/withdraw and fee settlement.
contract AjeyVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- Config ---
    address public treasury;
    uint16 public feeBps; // fee on yield, in basis points
    IAaveV3Pool public aavePool;
    IERC20 public immutable UNDERLYING;
    IERC20 public immutable A_TOKEN; // informational transparency; vault holds this after supply

    // ETH convenience mode via Aave WETH Gateway
    IETHGateway public ethGateway; // optional
    bool public ethMode; // when true, depositETH/withdrawETH enabled

    // --- Accounting ---
    uint256 public lastCheckpointAssets;
    uint256 public lastRebaseTimestamp;

    // --- Events (subset + custom) ---
    event SuppliedToAave(address indexed asset, uint256 amount, address indexed agent);
    event WithdrawnFromAave(address indexed asset, uint256 amount, address indexed agent);
    event PerformanceFeeTaken(address indexed treasury, uint256 feeAssets, uint256 feeShares);
    event ParamsUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);

    constructor(IERC20 asset_, IERC20 aToken_, address treasury_, uint16 feeBps_, IAaveV3Pool aavePool_, address admin)
        ERC20(
            string.concat("Ajey ", IERC20Metadata(address(asset_)).symbol(), " Vault Share"),
            string.concat("aJ-", IERC20Metadata(address(asset_)).symbol())
        )
        ERC4626(asset_)
    {
        require(treasury_ != address(0), "treasury=0");
        require(address(aavePool_) != address(0), "pool=0");
        require(feeBps_ <= 1500, "fee too high");

        UNDERLYING = asset_;
        A_TOKEN = aToken_;
        treasury = treasury_;
        feeBps = feeBps_;
        aavePool = aavePool_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        lastRebaseTimestamp = block.timestamp;

        // one-time max approval for Pool to pull underlying for supply
        UNDERLYING.forceApprove(address(aavePool), type(uint256).max);
    }

    // --- Admin ---
    function setParams(address treasury_, uint16 feeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        require(feeBps_ <= 1500, "fee too high");
        emit ParamsUpdated("feeBps", feeBps, feeBps_);
        emit ParamsUpdated("treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
        feeBps = feeBps_;
    }

    function addAgent(address agent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(AGENT_ROLE, agent);
    }

    function removeAgent(address agent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(AGENT_ROLE, agent);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- ERC-4626 Overrides ---
    function totalAssets() public view override returns (uint256) {
        // aToken balance + idle underlying
        uint256 idle = UNDERLYING.balanceOf(address(this));
        uint256 aBal = A_TOKEN.balanceOf(address(this));
        return idle + aBal;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        // Ensure liquidity, pull from Aave if needed
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle < assets) {
            uint256 toPull = assets - idle;
            aavePool.withdraw(address(UNDERLYING), toPull, address(this));
        }
        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        // Preview needed assets and ensure liquidity
        assets = previewRedeem(shares);
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle < assets) {
            uint256 toPull = assets - idle;
            aavePool.withdraw(address(UNDERLYING), toPull, address(this));
        }
        assets = super.redeem(shares, receiver, owner);
    }

    // --- Agent-only Aave ops ---
    function supplyToAave(uint256 amount) external whenNotPaused onlyRole(AGENT_ROLE) {
        if (amount == 0) return;
        aavePool.supply(address(UNDERLYING), amount, address(this), 0);
        emit SuppliedToAave(address(UNDERLYING), amount, msg.sender);
    }

    function withdrawFromAave(uint256 amount) external whenNotPaused onlyRole(AGENT_ROLE) {
        if (amount == 0) return;
        uint256 withdrawn = aavePool.withdraw(address(UNDERLYING), amount, address(this));
        emit WithdrawnFromAave(address(UNDERLYING), withdrawn, msg.sender);
    }

    // --- Fees & Checkpointing ---
    /// @notice Computes gain vs checkpoint and mints fee shares to treasury. Updates checkpoint and timestamp.
    function rebaseAndTakeFees() external whenNotPaused onlyRole(AGENT_ROLE) {
        uint256 currentAssets = totalAssets();
        uint256 checkpoint = lastCheckpointAssets;
        if (checkpoint == 0) {
            lastCheckpointAssets = currentAssets;
            lastRebaseTimestamp = block.timestamp;
            return;
        }

        if (currentAssets > checkpoint && feeBps > 0) {
            uint256 grossGain = currentAssets - checkpoint;
            uint256 feeAssets = (grossGain * feeBps) / 10_000;
            if (feeAssets > 0) {
                // Mint fee shares equivalent to feeAssets to treasury
                uint256 sharesForFee = convertToShares(feeAssets);
                if (sharesForFee > 0) {
                    _mint(treasury, sharesForFee);
                    emit PerformanceFeeTaken(treasury, feeAssets, sharesForFee);
                }
            }
        }

        lastCheckpointAssets = totalAssets(); // after mint
        lastRebaseTimestamp = block.timestamp;
    }

    // --- Views ---
    function aTokenBalance() external view returns (uint256) {
        return A_TOKEN.balanceOf(address(this));
    }

    function idleUnderlying() external view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    // --- ETH Convenience (Gateway) ---
    function setEthGateway(address gateway, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ethGateway = IETHGateway(gateway);
        ethMode = enabled;
        if (enabled && gateway != address(0)) {
            // Approve gateway to pull aTokens if needed for withdrawETH flows
            A_TOKEN.forceApprove(gateway, type(uint256).max);
        }
    }

    /// @notice Deposit native ETH via Aave WETH Gateway and mint shares to receiver.
    function depositEth(address receiver) external payable whenNotPaused nonReentrant returns (uint256 shares) {
        require(ethMode && address(ethGateway) != address(0), "ETH disabled");
        uint256 assets = msg.value;
        require(assets > 0, "no ETH");

        // Preview shares and supply ETH directly to Aave; Vault receives aWETH
        shares = previewDeposit(assets);
        ethGateway.depositEth{value: assets}(address(aavePool), address(this), 0);

        // Mint shares representing the newly managed assets
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem shares for native ETH via WETH Gateway, sending ETH to receiver.
    function withdrawEth(uint256 assets, address receiver, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(ethMode && address(ethGateway) != address(0), "ETH disabled");
        require(assets > 0, "zero assets");

        // Determine shares and spend allowance if called by a spender
        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares from owner first, then withdraw ETH from Aave via Gateway to receiver
        _burn(owner, shares);
        // aToken approval to gateway set in setEthGateway; perform ETH withdrawal
        ethGateway.withdrawEth(address(aavePool), assets, receiver);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }
}


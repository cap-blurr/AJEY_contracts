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

import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title AjeyVault
/// @notice ERC-4626 vault that supplies assets to Aave V3 with performance fees
/// @dev Enhanced to work seamlessly with YDS strategies
contract AjeyVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    // --- Config ---
    address public treasury;
    uint16 public feeBps; // fee on yield, in basis points
    IAaveV3Pool public aavePool;
    IERC20 public immutable UNDERLYING;
    IERC20 public immutable A_TOKEN;

    // ETH convenience mode
    IWETHGateway public ethGateway;
    bool public ethMode;

    /// @notice Auto-supply toggle: when enabled, deposits auto-supply any post-deposit idle to Aave
    bool public autoSupply;
    /// @notice Whether public deposits are enabled. If false, only addresses with STRATEGY_ROLE may deposit.
    bool public publicDepositsEnabled;

    // --- Accounting ---
    uint256 public lastCheckpointAssets;
    uint256 public lastCheckpointTimestamp;

    // --- Events ---
    event SuppliedToAave(address indexed asset, uint256 amount, address indexed agent);
    event WithdrawnFromAave(address indexed asset, uint256 amount, address indexed agent);
    event PerformanceFeeTaken(address indexed treasury, uint256 feeAssets, uint256 feeShares);
    event ParamsUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    event Checkpointed(uint256 assets, uint256 timestamp);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    /// @notice Emitted when public deposit mode is updated
    /// @param enabled New status for public deposits
    event PublicDepositsUpdated(bool enabled);

    /// @notice Constructor
    /// @param asset_ Underlying asset
    /// @param aToken_ Aave aToken
    /// @param treasury_ Fee recipient
    /// @param feeBps_ Performance fee in basis points
    /// @param aavePool_ Aave V3 pool
    /// @param admin Admin address
    constructor(IERC20 asset_, IERC20 aToken_, address treasury_, uint16 feeBps_, IAaveV3Pool aavePool_, address admin)
        ERC20(
            string.concat("Ajey ", IERC20Metadata(address(asset_)).symbol(), " Vault"),
            string.concat("ajV-", IERC20Metadata(address(asset_)).symbol())
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
        _grantRole(AGENT_ROLE, admin);

        lastCheckpointTimestamp = block.timestamp;

        // Max approval for Aave
        UNDERLYING.forceApprove(address(aavePool), type(uint256).max);

        // Default to public deposits enabled to preserve existing behavior.
        publicDepositsEnabled = true;
    }

    // --- Admin Functions ---

    /// @notice Update fee parameters
    /// @param treasury_ New treasury address
    /// @param feeBps_ New fee in basis points
    function setParams(address treasury_, uint16 feeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        require(feeBps_ <= 1500, "fee too high");
        emit ParamsUpdated("feeBps", feeBps, feeBps_);
        emit ParamsUpdated("treasury", uint256(uint160(treasury)), uint256(uint160(treasury_)));
        treasury = treasury_;
        feeBps = feeBps_;
    }

    /// @notice Enable or disable auto-supply of idle underlying to Aave after deposits
    /// @dev When enabled, after an ERC-4626 deposit/mint the contract supplies any idle underlying to Aave.
    ///      This does not affect allocation decisions; strategies and MSV still control which vault receives funds.
    /// @param enabled True to enable, false to disable
    function setAutoSupply(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        autoSupply = enabled;
    }

    /// @notice Enable or disable public deposits
    /// @dev If disabled, only callers holding STRATEGY_ROLE may deposit/mint
    /// @param enabled True to allow anyone to deposit/mint; false to restrict to strategies
    function setPublicDepositsEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        publicDepositsEnabled = enabled;
        emit PublicDepositsUpdated(enabled);
    }

    /// @notice Add a strategy that can interact with this vault
    /// @param strategy Strategy address
    function addStrategy(address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(STRATEGY_ROLE, strategy);
        emit StrategyAdded(strategy);
    }

    /// @notice Remove a strategy
    /// @param strategy Strategy address
    function removeStrategy(address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(STRATEGY_ROLE, strategy);
        emit StrategyRemoved(strategy);
    }

    /// @notice Add an agent
    /// @param agent Agent address
    function addAgent(address agent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(AGENT_ROLE, agent);
    }

    /// @notice Remove an agent
    /// @param agent Agent address
    function removeAgent(address agent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(AGENT_ROLE, agent);
    }

    /// @notice Pause the vault
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the vault
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- ERC-4626 Overrides ---

    /// @notice Total assets under management
    /// @return Total assets (idle + supplied to Aave)
    function totalAssets() public view override returns (uint256) {
        uint256 idle = UNDERLYING.balanceOf(address(this));
        uint256 aBal = A_TOKEN.balanceOf(address(this));
        return idle + aBal;
    }

    /// @notice Deposit assets for shares
    /// @param assets Amount to deposit
    /// @param receiver Share recipient
    /// @return shares Shares minted
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        // Gate deposits if public deposits are disabled
        require(publicDepositsEnabled || hasRole(STRATEGY_ROLE, msg.sender), "strategy only");
        shares = super.deposit(assets, receiver);
        if (autoSupply) {
            uint256 idle = UNDERLYING.balanceOf(address(this));
            if (idle > 0) {
                aavePool.supply(address(UNDERLYING), idle, address(this), 0);
            }
        }
    }

    /// @notice Mint shares for assets
    /// @param shares Shares to mint
    /// @param receiver Share recipient
    /// @return assets Assets required
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.mint(shares, receiver);
        if (autoSupply) {
            uint256 idle = UNDERLYING.balanceOf(address(this));
            if (idle > 0) {
                aavePool.supply(address(UNDERLYING), idle, address(this), 0);
            }
        }
    }

    /// @notice Withdraw assets by burning shares
    /// @param assets Assets to withdraw
    /// @param receiver Asset recipient
    /// @param owner Share owner
    /// @return shares Shares burned
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        // Ensure liquidity
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle < assets) {
            uint256 toPull = assets - idle;
            uint256 received = aavePool.withdraw(address(UNDERLYING), toPull, address(this));
            require(received >= toPull, "Insufficient Aave withdrawal");
        }
        shares = super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem shares for assets
    /// @param shares Shares to redeem
    /// @param receiver Asset recipient
    /// @param owner Share owner
    /// @return assets Assets returned
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        assets = previewRedeem(shares);
        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle < assets) {
            uint256 toPull = assets - idle;
            uint256 received = aavePool.withdraw(address(UNDERLYING), toPull, address(this));
            require(received >= toPull, "Insufficient Aave withdrawal");
        }
        assets = super.redeem(shares, receiver, owner);
    }

    // --- Agent Operations ---

    /// @notice Supply assets to Aave
    /// @param amount Amount to supply
    function supplyToAave(uint256 amount) external whenNotPaused onlyRole(AGENT_ROLE) {
        if (amount == 0) return;
        aavePool.supply(address(UNDERLYING), amount, address(this), 0);
        emit SuppliedToAave(address(UNDERLYING), amount, msg.sender);
    }

    /// @notice Withdraw from Aave
    /// @param amount Amount to withdraw
    function withdrawFromAave(uint256 amount) external whenNotPaused onlyRole(AGENT_ROLE) {
        if (amount == 0) return;
        uint256 withdrawn = aavePool.withdraw(address(UNDERLYING), amount, address(this));
        emit WithdrawnFromAave(address(UNDERLYING), withdrawn, msg.sender);
    }

    // --- Fee Management ---

    /// @notice Take performance fees on yield
    function takeFees() public whenNotPaused onlyRole(AGENT_ROLE) {
        uint256 currentAssets = totalAssets();
        uint256 prevCheckpointAssets = lastCheckpointAssets;

        if (prevCheckpointAssets == 0) {
            lastCheckpointAssets = currentAssets;
            lastCheckpointTimestamp = block.timestamp;
            emit Checkpointed(currentAssets, block.timestamp);
            return;
        }

        if (currentAssets > prevCheckpointAssets && feeBps > 0) {
            uint256 grossGain = currentAssets - prevCheckpointAssets;
            uint256 feeAssets = (grossGain * feeBps) / 10_000;

            if (feeAssets > 0) {
                uint256 sharesForFee = convertToShares(feeAssets);
                if (sharesForFee > 0) {
                    _mint(treasury, sharesForFee);
                    emit PerformanceFeeTaken(treasury, feeAssets, sharesForFee);
                }
            }
        }

        lastCheckpointAssets = currentAssets;
        lastCheckpointTimestamp = block.timestamp;
    }

    /// @notice Update checkpoint without taking fees
    function checkpoint() public whenNotPaused onlyRole(AGENT_ROLE) {
        uint256 assetsNow = totalAssets();
        lastCheckpointAssets = assetsNow;
        lastCheckpointTimestamp = block.timestamp;
        emit Checkpointed(assetsNow, block.timestamp);
    }

    // --- View Functions ---

    /// @notice Get aToken balance
    /// @return Balance of aTokens
    function aTokenBalance() external view returns (uint256) {
        return A_TOKEN.balanceOf(address(this));
    }

    /// @notice Get idle underlying balance
    /// @return Idle balance
    function idleUnderlying() external view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    // --- ETH Support ---

    /// @notice Configure ETH gateway
    /// @param gateway Gateway address
    /// @param enabled Whether to enable
    function setEthGateway(address gateway, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) {
            try IWETH(address(UNDERLYING)).deposit{value: 0}() {}
            catch {
                revert("UNDERLYING not WETH");
            }
        }
        ethGateway = IWETHGateway(gateway);
        ethMode = enabled;
        if (enabled && gateway != address(0)) {
            A_TOKEN.forceApprove(gateway, type(uint256).max);
        }
    }

    /// @notice Deposit ETH directly
    /// @param receiver Share recipient
    /// @return shares Shares minted
    function depositEth(address receiver) external payable whenNotPaused nonReentrant returns (uint256 shares) {
        require(ethMode, "ETH disabled");
        uint256 assets = msg.value;
        require(assets > 0, "no ETH");

        shares = previewDeposit(assets);
        IWETH(address(UNDERLYING)).deposit{value: assets}();
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        // Mirror ERC-4626 deposit behavior: auto-supply any idle to Aave if enabled
        if (autoSupply) {
            uint256 idle = UNDERLYING.balanceOf(address(this));
            if (idle > 0) {
                aavePool.supply(address(UNDERLYING), idle, address(this), 0);
            }
        }
    }

    /// @notice Withdraw ETH directly
    /// @param assets Amount to withdraw
    /// @param receiver ETH recipient
    /// @param owner Share owner
    /// @return shares Shares burned
    function withdrawEth(uint256 assets, address receiver, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(ethMode, "ETH disabled");
        require(assets > 0, "zero assets");

        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);

        uint256 idle = UNDERLYING.balanceOf(address(this));
        if (idle < assets) {
            uint256 toPull = assets - idle;
            uint256 received = aavePool.withdraw(address(UNDERLYING), toPull, address(this));
            require(received >= toPull, "Insufficient Aave withdrawal");
        }

        IWETH(address(UNDERLYING)).withdraw(assets);
        // Forward all available gas to the receiver to reduce risk of unexpected failures
        (bool ok,) = payable(receiver).call{value: assets}("");
        require(ok, "ETH send failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    receive() external payable {}
}

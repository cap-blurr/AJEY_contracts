// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";
import {IUniswapV3Router} from "../interfaces/IUniswapV3Router.sol";
import {IStrategyPermit} from "../interfaces/IStrategyPermit.sol";

/// @title AgentOrchestrator
/// @notice Orchestrates all agent operations across YDS strategies and vaults
/// @dev Central control point for the AI agent to manage allocations and harvesting
contract AgentOrchestrator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // Core components
    IUniswapV3Router public immutable uniswapRouter;
    uint24 public immutable defaultPoolFee; // default pool fee used for direct token→token swaps

    // Donation profiles
    enum Profile {
        Balanced,
        MaxHumanitarian,
        MaxCrypto
    }

    // Strategy registry per profile per asset: profile => (asset => strategy)
    mapping(Profile => mapping(address => address)) public strategyOf;

    // Track all strategies per profile for scheduled harvesting
    mapping(Profile => address[]) public strategiesByProfile;
    mapping(Profile => mapping(address => bool)) public isStrategyRegistered;

    // Configuration
    uint256 public constant SLIPPAGE_TOLERANCE = 9500; // 95% (5% slippage) - informative default, callers pass minOut

    // Events
    event StrategySet(Profile indexed profile, address indexed asset, address indexed strategy);
    event Deposited(
        Profile indexed profile,
        address indexed from,
        address indexed assetIn,
        address assetTarget,
        uint256 amountIn,
        uint256 sharesOut,
        address receiver
    );
    event Withdrawn(
        Profile indexed profile,
        address indexed owner,
        address indexed assetStrategy,
        address assetOut,
        uint256 assetsBurned,
        uint256 amountOut,
        address receiver
    );
    event Reallocated(
        Profile indexed profile,
        address indexed owner,
        address indexed sourceAsset,
        address targetAsset,
        uint256 sharesMoved,
        uint256 amountSwapped
    );
    event YieldHarvested(address strategy, uint256 profit, uint256 loss);

    /// @notice Constructor
    /// @param _admin Admin address
    /// @param _agent Agent address
    /// @param _uniswapRouter Uniswap V3 router address
    /// @param _defaultPoolFee Default Uniswap V3 pool fee (e.g., 3000 for 0.3%)
    constructor(address _admin, address _agent, address _uniswapRouter, uint24 _defaultPoolFee) {
        require(_uniswapRouter != address(0), "router=0");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AGENT_ROLE, _agent);

        uniswapRouter = IUniswapV3Router(_uniswapRouter);
        defaultPoolFee = _defaultPoolFee;
    }

    /// @notice Register a YDS strategy for a given (profile, asset)
    /// @param profile Donation profile
    /// @param asset ERC20 asset address
    /// @param strategy Strategy address handling the asset
    function setStrategy(Profile profile, address asset, address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(asset != address(0) && strategy != address(0), "bad addr");
        require(IBaseStrategy(strategy).asset() == asset, "mismatch");
        strategyOf[profile][asset] = strategy;
        if (!isStrategyRegistered[profile][strategy]) {
            isStrategyRegistered[profile][strategy] = true;
            strategiesByProfile[profile].push(strategy);
        }
        emit StrategySet(profile, asset, strategy);
    }

    /// @notice Harvest yield from all strategies
    function harvestAll() external onlyRole(AGENT_ROLE) {
        // Iterate all profiles and their registered strategies
        for (uint256 p = 0; p < 3; p++) {
            Profile profile = Profile(p);
            address[] storage list = strategiesByProfile[profile];
            uint256 len = list.length;
            for (uint256 i = 0; i < len; i++) {
                _harvestStrategy(list[i]);
            }
        }
    }

    /// @notice Harvest yield from all strategies in a specific profile
    function harvestProfile(Profile profile) external onlyRole(AGENT_ROLE) {
        address[] storage list = strategiesByProfile[profile];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            _harvestStrategy(list[i]);
        }
    }

    /// @notice Harvest yield from a specific strategy
    /// @param strategy Strategy address
    function harvestStrategy(address strategy) external onlyRole(AGENT_ROLE) {
        _harvestStrategy(strategy);
    }

    /// @notice Internal harvest function
    /// @param strategy Strategy to harvest
    function _harvestStrategy(address strategy) internal {
        if (strategy == address(0)) return;

        (uint256 profit, uint256 loss) = IBaseStrategy(strategy).report();
        emit YieldHarvested(strategy, profit, loss);
    }

    /// @notice Deposit ERC20 on behalf of a user, optionally swap to target asset, then deposit into the (profile, targetAsset) strategy
    /// @param profile Donation profile to route into
    /// @param from The user whose tokens are being deposited
    /// @param inputAsset The asset provided by the user
    /// @param amountIn Amount of inputAsset to deposit
    /// @param targetAsset The strategy's asset to deposit into
    /// @param minAmountOut Minimum amount after swap (if inputAsset != targetAsset)
    /// @param receiver Receiver of the strategy shares
    /// @return sharesOut Strategy shares minted to receiver
    function depositERC20(
        Profile profile,
        address from,
        address inputAsset,
        uint256 amountIn,
        address targetAsset,
        uint256 minAmountOut,
        address receiver
    ) external onlyRole(AGENT_ROLE) nonReentrant returns (uint256 sharesOut) {
        require(from != address(0) && receiver != address(0), "bad addr");
        require(amountIn > 0, "zero amount");
        address strategy = strategyOf[profile][targetAsset];
        require(strategy != address(0), "no target strategy");

        // Pull tokens from user
        IERC20(inputAsset).safeTransferFrom(from, address(this), amountIn);

        uint256 amountToDeposit;
        if (inputAsset == targetAsset) {
            amountToDeposit = amountIn;
        } else {
            // Approve router and perform direct pool swap
            IERC20(inputAsset).forceApprove(address(uniswapRouter), amountIn);
            IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: inputAsset,
                tokenOut: targetAsset,
                fee: defaultPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });
            amountToDeposit = uniswapRouter.exactInputSingle{value: 0}(params);
        }

        // Approve strategy to pull funds and deposit for receiver
        IERC20(targetAsset).forceApprove(strategy, amountToDeposit);
        sharesOut = IBaseStrategy(strategy).deposit(amountToDeposit, receiver);

        emit Deposited(profile, from, inputAsset, targetAsset, amountIn, sharesOut, receiver);
    }

    /// @notice Withdraw from a (profile, asset) strategy on behalf of a user to a desired asset (optional swap), transfer to receiver
    /// @param profile Donation profile of the strategy
    /// @param owner The owner of the strategy shares (must have approved this contract to burn shares)
    /// @param strategyAsset The asset handled by the source strategy
    /// @param assets Amount of strategyAsset to withdraw from the strategy
    /// @param outputAsset The asset to send to the receiver
    /// @param minAmountOut Minimum amount after swap (if strategyAsset != outputAsset)
    /// @param receiver Recipient of the output asset
    /// @return amountOut Final output amount sent to receiver
    function withdrawERC20(
        Profile profile,
        address owner,
        address strategyAsset,
        uint256 assets,
        address outputAsset,
        uint256 minAmountOut,
        address receiver
    ) external onlyRole(AGENT_ROLE) nonReentrant returns (uint256 amountOut) {
        require(owner != address(0) && receiver != address(0), "bad addr");
        require(assets > 0, "zero assets");
        address strategy = strategyOf[profile][strategyAsset];
        require(strategy != address(0), "no strategy");

        // Withdraw underlying to this contract (burns owner's shares internally)
        IBaseStrategy(strategy).withdraw(assets, address(this), owner);

        if (strategyAsset == outputAsset) {
            amountOut = assets;
            IERC20(outputAsset).safeTransfer(receiver, amountOut);
        } else {
            // Swap
            IERC20(strategyAsset).forceApprove(address(uniswapRouter), assets);
            IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: strategyAsset,
                tokenOut: outputAsset,
                fee: defaultPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: assets,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });
            amountOut = uniswapRouter.exactInputSingle{value: 0}(params);
            IERC20(outputAsset).safeTransfer(receiver, amountOut);
        }

        emit Withdrawn(profile, owner, strategyAsset, outputAsset, assets, amountOut, receiver);
    }

    /// @notice Reallocate a user's position across assets within the same profile
    /// @dev Sequence: report() -> compute assets from shares -> withdraw -> swap -> deposit
    /// @param profile Donation profile
    /// @param owner Position owner
    /// @param sourceAsset Source strategy asset
    /// @param targetAsset Target strategy asset
    /// @param shares Amount of source strategy shares to migrate
    /// @param minAmountOut Minimum amount expected after the swap
    function reallocate(
        Profile profile,
        address owner,
        address sourceAsset,
        address targetAsset,
        uint256 shares,
        uint256 minAmountOut
    ) external onlyRole(AGENT_ROLE) nonReentrant {
        require(owner != address(0), "owner=0");
        require(sourceAsset != address(0) && targetAsset != address(0), "asset=0");
        require(sourceAsset != targetAsset, "same asset");
        require(shares > 0, "zero shares");

        address sourceStrategy = strategyOf[profile][sourceAsset];
        address targetStrategy = strategyOf[profile][targetAsset];
        require(sourceStrategy != address(0) && targetStrategy != address(0), "no strategy");

        // 1) Realize P/L for correct donation accrual
        try IBaseStrategy(sourceStrategy).report() {} catch {}

        // 2) Compute assets equivalent for the share amount
        uint256 totalAssets = IBaseStrategy(sourceStrategy).totalAssets();
        uint256 totalSupply = IERC20(sourceStrategy).totalSupply();
        require(totalSupply > 0, "empty source");
        uint256 assetsFrom = (shares * totalAssets) / totalSupply;
        require(assetsFrom > 0, "zero assetsFrom");

        // 3) Withdraw underlying from source (burn owner's shares)
        IBaseStrategy(sourceStrategy).withdraw(assetsFrom, address(this), owner);

        // 4) Swap sourceAsset -> targetAsset if needed
        uint256 amountToDeposit;
        if (sourceAsset == targetAsset) {
            amountToDeposit = assetsFrom;
        } else {
            IERC20(sourceAsset).forceApprove(address(uniswapRouter), assetsFrom);
            IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
                tokenIn: sourceAsset,
                tokenOut: targetAsset,
                fee: defaultPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: assetsFrom,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });
            amountToDeposit = uniswapRouter.exactInputSingle{value: 0}(params);
        }

        // 5) Deposit into target strategy for owner
        IERC20(targetAsset).forceApprove(targetStrategy, amountToDeposit);
        IBaseStrategy(targetStrategy).deposit(amountToDeposit, owner);

        emit Reallocated(profile, owner, sourceAsset, targetAsset, shares, amountToDeposit);
    }

    /// @notice EIP-2612 permit for strategy share token, enabling this orchestrator to manage shares
    /// @param strategy Strategy address (share token)
    /// @param owner Owner granting approval
    /// @param value Allowance value
    /// @param deadline Permit deadline
    /// @param v Sig v
    /// @param r Sig r
    /// @param s Sig s
    function permitShares(
        address strategy,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(AGENT_ROLE) {
        IStrategyPermit(strategy).permit(owner, address(this), value, deadline, v, r, s);
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
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";
import {IUniswapV3Router} from "../interfaces/IUniswapV3Router.sol";
import {AjeyVault} from "../core/AjeyVault.sol";
import {YDS_AaveWETH} from "./YDS_AaveWETH.sol";
import {YDS_AaveUSDC} from "./YDS_AaveUSDC.sol";

/// @title AgentOrchestrator
/// @notice Orchestrates all agent operations across YDS strategies and vaults
/// @dev Central control point for the AI agent to manage allocations and harvesting
contract AgentOrchestrator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // Core components
    IUniswapV3Router public immutable uniswapRouter;
    address public immutable weth;
    address public immutable usdc;

    // Strategies
    address public ydsWETH;
    address public ydsUSDC;

    // Configuration
    uint24 public constant POOL_FEE = 3000; // 0.3% fee tier
    uint256 public constant SLIPPAGE_TOLERANCE = 9500; // 95% (5% slippage)

    // Events
    event StrategiesUpdated(address ydsWETH, address ydsUSDC);
    event Reallocated(address from, address to, uint256 amount);
    event YieldHarvested(address strategy, uint256 profit, uint256 loss);
    event AaveSupplyTriggered(address vault, uint256 amount);
    event AaveWithdrawTriggered(address vault, uint256 amount);

    /// @notice Constructor
    /// @param _admin Admin address
    /// @param _agent Agent address
    /// @param _uniswapRouter Uniswap V3 router address
    /// @param _weth WETH address
    /// @param _usdc USDC address
    constructor(address _admin, address _agent, address _uniswapRouter, address _weth, address _usdc) {
        require(_uniswapRouter != address(0), "router=0");
        require(_weth != address(0), "weth=0");
        require(_usdc != address(0), "usdc=0");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AGENT_ROLE, _agent);

        uniswapRouter = IUniswapV3Router(_uniswapRouter);
        weth = _weth;
        usdc = _usdc;
    }

    /// @notice Set YDS strategy addresses
    /// @param _ydsWETH WETH YDS address
    /// @param _ydsUSDC USDC YDS address
    function setStrategies(address _ydsWETH, address _ydsUSDC) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ydsWETH = _ydsWETH;
        ydsUSDC = _ydsUSDC;
        emit StrategiesUpdated(_ydsWETH, _ydsUSDC);
    }

    /// @notice Reallocate funds between WETH and USDC strategies
    /// @param fromWETH True if moving from WETH to USDC, false for opposite
    /// @param amount Amount to reallocate (in source asset)
    /// @param minAmountOut Minimum amount to receive (slippage protection)
    function reallocate(bool fromWETH, uint256 amount, uint256 minAmountOut)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
    {
        require(amount > 0, "zero amount");

        address fromStrategy = fromWETH ? ydsWETH : ydsUSDC;
        address toStrategy = fromWETH ? ydsUSDC : ydsWETH;
        address fromAsset = fromWETH ? weth : usdc;
        address toAsset = fromWETH ? usdc : weth;

        // Withdraw from source strategy
        uint256 shares = _calculateSharesForAssets(fromStrategy, amount);
        IBaseStrategy(fromStrategy).withdraw(amount, address(this), fromStrategy);

        // Swap assets via Uniswap V3
        IERC20(fromAsset).forceApprove(address(uniswapRouter), amount);

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: fromAsset,
            tokenOut: toAsset,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);

        // Deposit into target strategy
        IERC20(toAsset).forceApprove(toStrategy, amountOut);
        IBaseStrategy(toStrategy).deposit(amountOut, toStrategy);

        emit Reallocated(fromStrategy, toStrategy, amount);
    }

    /// @notice Trigger Aave supply for a specific vault
    /// @param isWETH True for WETH vault, false for USDC
    /// @param amount Amount to supply
    function triggerAaveSupply(bool isWETH, uint256 amount) external onlyRole(AGENT_ROLE) {
        address strategy = isWETH ? ydsWETH : ydsUSDC;
        address payable vaultAddr = payable(
            isWETH ? YDS_AaveWETH(strategy).ajeyVault() : YDS_AaveUSDC(strategy).ajeyVault()
        );
        AjeyVault vault = AjeyVault(vaultAddr);

        vault.supplyToAave(amount);
        emit AaveSupplyTriggered(address(vault), amount);
    }

    /// @notice Trigger Aave withdrawal for a specific vault
    /// @param isWETH True for WETH vault, false for USDC
    /// @param amount Amount to withdraw
    function triggerAaveWithdraw(bool isWETH, uint256 amount) external onlyRole(AGENT_ROLE) {
        address strategy = isWETH ? ydsWETH : ydsUSDC;
        address payable vaultAddr = payable(
            isWETH ? YDS_AaveWETH(strategy).ajeyVault() : YDS_AaveUSDC(strategy).ajeyVault()
        );
        AjeyVault vault = AjeyVault(vaultAddr);

        vault.withdrawFromAave(amount);
        emit AaveWithdrawTriggered(address(vault), amount);
    }

    /// @notice Harvest yield from all strategies
    function harvestAll() external onlyRole(AGENT_ROLE) {
        _harvestStrategy(ydsWETH);
        _harvestStrategy(ydsUSDC);
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

    /// @notice Calculate shares needed for a given asset amount
    /// @param strategy Strategy address
    /// @param assets Asset amount
    /// @return shares Share amount
    function _calculateSharesForAssets(address strategy, uint256 assets) internal view returns (uint256) {
        uint256 totalAssets = IBaseStrategy(strategy).totalAssets();
        uint256 totalSupply = IERC20(strategy).totalSupply();

        if (totalSupply == 0) return assets;
        return (assets * totalSupply) / totalAssets;
    }

    /// @notice Emergency withdraw from strategies
    /// @param strategy Strategy address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address strategy, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IBaseStrategy(strategy).withdraw(amount, msg.sender, strategy);
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

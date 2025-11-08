// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {AjeyVault} from "../core/AjeyVault.sol";
import {IUniswapV3Router} from "../interfaces/IUniswapV3Router.sol";
import {IUniswapV3QuoterV2} from "../interfaces/IUniswapV3QuoterV2.sol";

/// @title CrossAssetAaveStrategy
/// @notice Cross-asset YDS that holds baseAsset shares but deploys into a target AjeyVault (different asset)
/// @dev Swaps baseAsset -> targetAsset on deploy; targetAsset -> baseAsset on free. Values portfolio in baseAsset.
contract CrossAssetAaveStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // External components
    IUniswapV3Router public immutable uniswapRouter;
    IUniswapV3QuoterV2 public quoter;

    // Target AjeyVault (holds targetAsset and supplies to Aave)
    AjeyVault public targetVault;

    // Swap parameters
    uint24 public poolFee; // Uniswap V3 pool fee between baseAsset and targetAsset
    uint256 public slippageBps; // max slippage in basis points for swaps

    // Pricing: base per target in 1e18 (management-updated; use TWAP off-chain)
    uint256 public basePerTarget1e18; // how many baseAsset units per 1 targetAsset
    uint256 public lastPriceUpdate; // timestamp of last price update
    uint256 public constant MAX_PRICE_AGE = 1 hours; // maximum allowed price age
    uint256 public maxPriceDeviationBps = 11000; // 10% max step change (ratio vs previous) in bps (10000 = 1.0x)

    // Swap safety controls
    bool public swapsPaused; // allow emergency pause
    uint256 public maxSwapBaseAmount; // max base amount per single swap action
    uint256 public maxSwapTargetAmount; // max target amount per single swap action

    event TargetMarketUpdated(address targetVault, uint24 poolFee, uint256 slippageBps);
    event PricingUpdated(uint256 basePerTarget1e18);
    event SwapsPaused(bool paused);
    event SwapLimitsUpdated(uint256 maxSwapBaseAmount, uint256 maxSwapTargetAmount);
    event PriceLimitsUpdated(uint256 maxPriceDeviationBps);
    event QuoterUpdated(address quoter);

    /// @param _baseAsset The MSV base asset held by the strategy holders
    /// @param _donationAddress Donation address to receive minted shares on profit
    /// @param _name ERC20 name
    /// @param _symbol ERC20 symbol
    /// @param _uniswapRouter Uniswap V3 router
    /// @param _admin Management/keeper admin
    constructor(
        address _baseAsset,
        address _donationAddress,
        string memory _name,
        string memory _symbol,
        address _uniswapRouter,
        address _admin
    ) BaseStrategy(_baseAsset, _donationAddress, _name, _symbol) {
        require(_uniswapRouter != address(0), "router=0");
        uniswapRouter = IUniswapV3Router(_uniswapRouter);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(MANAGEMENT_ROLE, _admin);

        // defaults (no hard limits until configured)
        maxSwapBaseAmount = type(uint256).max;
        maxSwapTargetAmount = type(uint256).max;
    }

    /// @notice Set Uniswap V3 QuoterV2 address
    function setQuoter(address _quoter) external onlyRole(MANAGEMENT_ROLE) {
        require(_quoter != address(0), "quoter=0");
        quoter = IUniswapV3QuoterV2(_quoter);
        emit QuoterUpdated(_quoter);
    }

    /// @notice Set target AjeyVault and swap parameters
    /// @param _targetVault AjeyVault that holds the target asset and supplies to Aave
    /// @param _poolFee Uniswap V3 pool fee between base and target
    /// @param _slippageBps Max slippage in bps for swaps
    function setTargetMarket(AjeyVault _targetVault, uint24 _poolFee, uint256 _slippageBps)
        external
        onlyRole(MANAGEMENT_ROLE)
    {
        require(address(_targetVault) != address(0), "vault=0");
        require(_slippageBps <= 10_000, "bad slippage");
        targetVault = _targetVault;
        poolFee = _poolFee;
        slippageBps = _slippageBps;

        // Approvals
        IERC20 assetToken = IERC20(asset);
        assetToken.forceApprove(address(uniswapRouter), type(uint256).max);
        IERC20 targetToken = IERC20(_targetVault.asset());
        targetToken.forceApprove(address(uniswapRouter), type(uint256).max);
        targetToken.forceApprove(address(_targetVault), type(uint256).max);

        emit TargetMarketUpdated(address(_targetVault), _poolFee, _slippageBps);
    }

    /// @notice Update price used to value targetAsset in baseAsset
    /// @param _basePerTarget1e18 base units per 1 target unit, scaled by 1e18
    function setPrice(uint256 _basePerTarget1e18) external onlyRole(KEEPER_ROLE) {
        require(_basePerTarget1e18 > 0, "price=0");
        if (basePerTarget1e18 > 0) {
            // ratio = max(new/old, old/new) in bps, must be <= maxPriceDeviationBps
            uint256 a = _basePerTarget1e18 > basePerTarget1e18
                ? (_basePerTarget1e18 * 10000) / basePerTarget1e18
                : (basePerTarget1e18 * 10000) / _basePerTarget1e18;
            require(a <= maxPriceDeviationBps, "price deviation too large");
        }
        basePerTarget1e18 = _basePerTarget1e18;
        lastPriceUpdate = block.timestamp;
        emit PricingUpdated(_basePerTarget1e18);
    }

    /// @notice Pause swaps in emergency
    function pauseSwaps() external onlyRole(MANAGEMENT_ROLE) {
        swapsPaused = true;
        emit SwapsPaused(true);
    }

    /// @notice Unpause swaps
    function unpauseSwaps() external onlyRole(MANAGEMENT_ROLE) {
        swapsPaused = false;
        emit SwapsPaused(false);
    }

    /// @notice Configure per-tx swap limits
    function setSwapLimits(uint256 _maxSwapBaseAmount, uint256 _maxSwapTargetAmount)
        external
        onlyRole(MANAGEMENT_ROLE)
    {
        maxSwapBaseAmount = _maxSwapBaseAmount;
        maxSwapTargetAmount = _maxSwapTargetAmount;
        emit SwapLimitsUpdated(_maxSwapBaseAmount, _maxSwapTargetAmount);
    }

    /// @notice Configure allowed price step deviation (ratio in bps vs previous)
    function setMaxPriceDeviationBps(uint256 _maxPriceDeviationBps) external onlyRole(MANAGEMENT_ROLE) {
        require(_maxPriceDeviationBps >= 10000, "bad deviation");
        require(_maxPriceDeviationBps <= 20000, "too large");
        maxPriceDeviationBps = _maxPriceDeviationBps;
        emit PriceLimitsUpdated(_maxPriceDeviationBps);
    }

    /// @notice Emergency withdraw of target asset without swapping
    function emergencyWithdrawTarget(uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(targetVault) != address(0), "vault unset");
        require(recipient != address(0), "recipient=0");
        targetVault.withdraw(amount, recipient, address(this));
    }

    function _requireSwapsActive() internal view {
        require(!swapsPaused, "swaps paused");
    }

    function _validatePriceFreshness() internal view {
        require(basePerTarget1e18 > 0, "price unset");
        require(block.timestamp - lastPriceUpdate <= MAX_PRICE_AGE, "stale price");
    }

    /// @dev Swap helper base->target
    function swapBaseToTarget(uint256 amountBase) internal returns (uint256 amountOut) {
        if (amountBase == 0) return 0;
        address tokenIn = address(asset);
        address tokenOut = targetVault.asset();

        uint256 minOut;
        if (address(quoter) != address(0)) {
            // Quote expected output
            try quoter.quoteExactInputSingle(
                IUniswapV3QuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: poolFee,
                    amountIn: amountBase,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 quotedOut, uint160, uint32, uint256) {
                require(quotedOut > 0, "quote=0");
                // Sanity-check quoted price against configured basePerTarget
                // impliedBasePerTarget = baseIn / targetOut (scaled 1e18)
                uint256 impliedBasePerTarget = (amountBase * 1e18) / quotedOut;
                uint256 ratio = impliedBasePerTarget > basePerTarget1e18
                    ? (impliedBasePerTarget * 10000) / basePerTarget1e18
                    : (basePerTarget1e18 * 10000) / impliedBasePerTarget;
                require(ratio <= maxPriceDeviationBps, "quoter deviation too large");
                minOut = (quotedOut * (10_000 - slippageBps)) / 10_000;
            } catch {
                // Fallback: compute minOut via configured price (basePerTarget)
                // targetOut ~= baseIn / price
                minOut = (amountBase * (10_000 - slippageBps) * 1e18) / (10_000 * basePerTarget1e18);
            }
        } else {
            // Quoter unset: fallback to configured price
            minOut = (amountBase * (10_000 - slippageBps) * 1e18) / (10_000 * basePerTarget1e18);
        }

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountBase,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        amountOut = uniswapRouter.exactInputSingle{value: 0}(params);
    }

    /// @dev Swap helper target->base
    function swapTargetToBase(uint256 amountTarget) internal returns (uint256 amountOut) {
        if (amountTarget == 0) return 0;
        address tokenIn = targetVault.asset();
        address tokenOut = address(asset);

        uint256 minOut;
        if (address(quoter) != address(0)) {
            // Quote expected output
            try quoter.quoteExactInputSingle(
                IUniswapV3QuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: poolFee,
                    amountIn: amountTarget,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 quotedOut, uint160, uint32, uint256) {
                require(quotedOut > 0, "quote=0");
                // impliedBasePerTarget = baseOut / targetIn (scaled 1e18)
                uint256 impliedBasePerTarget = (quotedOut * 1e18) / amountTarget;
                uint256 ratio = impliedBasePerTarget > basePerTarget1e18
                    ? (impliedBasePerTarget * 10000) / basePerTarget1e18
                    : (basePerTarget1e18 * 10000) / impliedBasePerTarget;
                require(ratio <= maxPriceDeviationBps, "quoter deviation too large");
                minOut = (quotedOut * (10_000 - slippageBps)) / 10_000;
            } catch {
                // Fallback: baseOut ~= targetIn * price
                minOut = (amountTarget * basePerTarget1e18 * (10_000 - slippageBps)) / (10_000 * 1e18);
            }
        } else {
            // Quoter unset: fallback to configured price
            minOut = (amountTarget * basePerTarget1e18 * (10_000 - slippageBps)) / (10_000 * 1e18);
        }

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountTarget,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        amountOut = uniswapRouter.exactInputSingle{value: 0}(params);
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;
        require(address(targetVault) != address(0), "vault unset");
        _requireSwapsActive();
        _validatePriceFreshness();
        require(amount <= maxSwapBaseAmount, "exceeds base limit");

        // Swap base -> target, deposit target into AjeyVault
        uint256 targetReceived = swapBaseToTarget(amount);
        if (targetReceived > 0) {
            require(targetReceived <= maxSwapTargetAmount, "exceeds target limit");
            IERC20(targetVault.asset()).forceApprove(address(targetVault), targetReceived);
            targetVault.deposit(targetReceived, address(this));
            emit FundsDeployed(amount);
        }
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        require(address(targetVault) != address(0), "vault unset");
        _requireSwapsActive();
        _validatePriceFreshness();
        require(amount <= maxSwapBaseAmount, "exceeds base limit");

        // Compute how much target to withdraw to realize `amount` base
        // Use pricing: base = target * basePerTarget1e18
        uint256 targetNeeded = (amount * 1e18 + basePerTarget1e18 - 1) / basePerTarget1e18; // ceil div
        require(targetNeeded <= maxSwapTargetAmount, "exceeds target limit");

        if (targetNeeded > 0) {
            targetVault.withdraw(targetNeeded, address(this), address(this));
            uint256 baseOut = swapTargetToBase(IERC20(targetVault.asset()).balanceOf(address(this)));
            // Transfer base to self; Base held idle for withdraw()
            emit FundsFreed(baseOut);
        }
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256) {
        uint256 idleBase = IERC20(asset).balanceOf(address(this));
        if (address(targetVault) == address(0)) return idleBase;

        // Get investable target amount valued in base using manager-updated price
        uint256 targetRedeemable = targetVault.maxWithdraw(address(this));
        uint256 targetAsBase = (targetRedeemable * basePerTarget1e18) / 1e18;
        return idleBase + targetAsBase;
    }
}


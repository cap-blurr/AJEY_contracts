// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";

/// @title AgentReallocator
/// @notice Orchestrates migrations between vaults and YDS strategies with optional swaps
/// @dev Enhanced to support both direct vault migrations and YDS strategy reallocation
contract AgentReallocator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // Whitelisted swap aggregators
    mapping(address => bool) public isAggregator;

    // Whitelisted strategies for direct reallocation
    mapping(address => bool) public isStrategy;

    // Events
    event AggregatorUpdated(address indexed aggregator, bool allowed);
    event StrategyUpdated(address indexed strategy, bool allowed);
    event Migrated(
        address indexed owner,
        address indexed receiver,
        address indexed sourceVault,
        address targetVault,
        address assetFrom,
        address assetTo,
        uint256 sharesIn,
        uint256 assetsFrom,
        uint256 assetsTo,
        uint256 targetSharesOut
    );
    event StrategyReallocated(address indexed fromStrategy, address indexed toStrategy, uint256 amount);

    /// @notice Constructor
    /// @param admin Admin address
    /// @param agent Agent address
    constructor(address admin, address agent) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE, agent);
    }

    /// @notice Set aggregator whitelist status
    /// @param aggregator Aggregator address
    /// @param allowed Whether allowed
    function setAggregator(address aggregator, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isAggregator[aggregator] = allowed;
        emit AggregatorUpdated(aggregator, allowed);
    }

    /// @notice Set strategy whitelist status
    /// @param strategy Strategy address
    /// @param allowed Whether allowed
    function setStrategy(address strategy, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isStrategy[strategy] = allowed;
        emit StrategyUpdated(strategy, allowed);
    }

    /// @notice Migrate between ERC-4626 vaults with optional swap
    /// @param owner Share owner
    /// @param receiver Share recipient
    /// @param sourceVault Source vault
    /// @param targetVault Target vault
    /// @param shares Shares to migrate
    /// @param aggregator Swap aggregator (0 for no swap)
    /// @param swapCalldata Swap calldata
    /// @param minAmountOut Minimum output
    /// @param deadline Deadline timestamp
    /// @return targetSharesOut Shares received
    function migrateShares(
        address owner,
        address receiver,
        address sourceVault,
        address targetVault,
        uint256 shares,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 targetSharesOut) {
        require(receiver == owner, "receiver!=owner");
        require(msg.sender == owner || hasRole(AGENT_ROLE, msg.sender), "not owner/agent");
        require(block.timestamp <= deadline, "expired");
        require(owner != address(0) && receiver != address(0), "bad addr");
        require(sourceVault != address(0) && targetVault != address(0), "bad vault");
        require(sourceVault != targetVault, "same vault");
        require(shares > 0, "zero shares");

        address assetFrom = IERC4626(sourceVault).asset();
        address assetTo = IERC4626(targetVault).asset();

        // Redeem from source
        uint256 assetsFrom = IERC4626(sourceVault).redeem(shares, address(this), owner);

        uint256 amountToDeposit;
        if (assetFrom == assetTo) {
            amountToDeposit = assetsFrom;
        } else {
            amountToDeposit = _swapAssets(assetFrom, assetTo, assetsFrom, aggregator, swapCalldata, minAmountOut);
        }

        // Deposit to target
        IERC20(assetTo).forceApprove(targetVault, amountToDeposit);
        targetSharesOut = IERC4626(targetVault).deposit(amountToDeposit, receiver);

        emit Migrated(
            owner,
            receiver,
            sourceVault,
            targetVault,
            assetFrom,
            assetTo,
            shares,
            assetsFrom,
            amountToDeposit,
            targetSharesOut
        );
    }

    /// @notice Reallocate between YDS strategies
    /// @param fromStrategy Source strategy
    /// @param toStrategy Target strategy
    /// @param amount Amount to reallocate
    function reallocateStrategies(address fromStrategy, address toStrategy, uint256 amount)
        external
        onlyRole(AGENT_ROLE)
        nonReentrant
    {
        require(isStrategy[fromStrategy], "from not whitelisted");
        require(isStrategy[toStrategy], "to not whitelisted");
        require(amount > 0, "zero amount");

        // Strategies must have same underlying for direct reallocation
        address assetFrom = IBaseStrategy(fromStrategy).asset();
        address assetTo = IBaseStrategy(toStrategy).asset();
        require(assetFrom == assetTo, "asset mismatch");

        // Withdraw from source strategy
        IBaseStrategy(fromStrategy).withdraw(amount, address(this), fromStrategy);

        // Deposit to target strategy
        IERC20(assetFrom).forceApprove(toStrategy, amount);
        IBaseStrategy(toStrategy).deposit(amount, toStrategy);

        emit StrategyReallocated(fromStrategy, toStrategy, amount);
    }

    /// @notice Internal swap function
    /// @param assetFrom Source asset
    /// @param assetTo Target asset
    /// @param amountIn Input amount
    /// @param aggregator Aggregator address
    /// @param swapCalldata Swap calldata
    /// @param minAmountOut Minimum output
    /// @return amountOut Output amount
    function _swapAssets(
        address assetFrom,
        address assetTo,
        uint256 amountIn,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        require(isAggregator[aggregator], "agg not allowed");

        IERC20(assetFrom).forceApprove(aggregator, amountIn);

        uint256 balBefore = IERC20(assetTo).balanceOf(address(this));
        (bool ok, bytes memory ret) = aggregator.call(swapCalldata);
        require(ok, _getRevertMsg(ret));

        uint256 balAfter = IERC20(assetTo).balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        require(received >= minAmountOut, "slippage");

        IERC20(assetFrom).forceApprove(aggregator, 0);

        return received;
    }

    /// @notice Extract revert message
    /// @param returnData Return data
    /// @return Revert message
    function _getRevertMsg(bytes memory returnData) private pure returns (string memory) {
        if (returnData.length < 68) return "swap failed";
        if (returnData.length > 1000) return "swap failed: data too long";
        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }
}

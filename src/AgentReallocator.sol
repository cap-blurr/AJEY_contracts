// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

/// @title AgentReallocator
/// @notice Orchestrates user opt-in migrations between single-asset ERC-4626 vaults with an optional swap in-between.
/// @dev This contract never holds user funds long-term; assets are redeemed from the source vault into this contract,
///      swapped (if needed), then deposited into the target vault in a single call. The caller must have sufficient
///      allowance of source vault shares for this contract to redeem on their behalf.
contract AgentReallocator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // Optional whitelist for swap aggregators (e.g., ParaSwap Augustus)
    mapping(address => bool) public isAggregator;

    event AggregatorUpdated(address indexed aggregator, bool allowed);
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

    constructor(address admin, address agent) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE, agent);
    }

    /// @notice Admin: set or unset an allowed swap aggregator.
    function setAggregator(address aggregator, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isAggregator[aggregator] = allowed;
        emit AggregatorUpdated(aggregator, allowed);
    }

    /// @notice Migrate a user's position from one single-asset ERC-4626 vault to another, optionally swapping assets.
    /// @param owner The user whose shares are being migrated. Must have approved this contract to spend `shares`.
    /// @param receiver The recipient of target vault shares (usually same as owner).
    /// @param sourceVault ERC-4626 source vault address.
    /// @param targetVault ERC-4626 target vault address.
    /// @param shares Number of source vault shares to migrate (burned in redeem).
    /// @param aggregator Whitelisted swap aggregator (set address(0) to skip swap if assets match).
    /// @param swapCalldata Encoded aggregator call data.
    /// @param minAmountOut Minimum amount of target asset to receive from swap (slippage control).
    /// @param deadline Unix timestamp after which the call reverts.
    /// @return targetSharesOut Shares minted in the target vault to `receiver`.
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
        // Security: only the owner or an authorized agent can initiate, and funds must return to the owner
        require(receiver == owner, "receiver!=owner");
        require(msg.sender == owner || hasRole(AGENT_ROLE, msg.sender), "not owner/agent");
        require(block.timestamp <= deadline, "expired");
        require(owner != address(0) && receiver != address(0), "bad addr");
        require(sourceVault != address(0) && targetVault != address(0), "bad vault");
        require(sourceVault != targetVault, "same vault");
        require(shares > 0, "zero shares");

        address assetFrom = IERC4626(sourceVault).asset();
        address assetTo = IERC4626(targetVault).asset();

        // Redeem source shares to this contract (requires owner -> this allowance on shares)
        uint256 assetsFrom = IERC4626(sourceVault).redeem(shares, address(this), owner);

        uint256 amountToDeposit;
        if (assetFrom == assetTo) {
            amountToDeposit = assetsFrom;
        } else {
            amountToDeposit = _swapAssets(assetFrom, assetTo, assetsFrom, aggregator, swapCalldata, minAmountOut);
        }

        // Deposit into target vault for receiver
        IERC20(assetTo).forceApprove(targetVault, 0);
        IERC20(assetTo).forceApprove(targetVault, amountToDeposit);
        targetSharesOut = IERC4626(targetVault).deposit(amountToDeposit, receiver);
        IERC20(assetTo).forceApprove(targetVault, 0);

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

    function _swapAssets(
        address assetFrom,
        address assetTo,
        uint256 amountIn,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        require(isAggregator[aggregator], "agg not allowed");
        IERC20(assetFrom).forceApprove(aggregator, 0);
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

    function _getRevertMsg(bytes memory returnData) private pure returns (string memory) {
        if (returnData.length < 68) return "swap failed";
        if (returnData.length > 1000) return "swap failed: data too long";
        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }
}


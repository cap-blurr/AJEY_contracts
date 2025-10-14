// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title RebasingWrapper
/// @notice Wraps AjeyVault shares into rebasing units for UX. Maintains a global index updated by Agent.
contract RebasingWrapper is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    IERC4626 public immutable VAULT; // underlying ERC-4626 (AjeyVault)

    // Global index: units -> shares mapping uses index with 18 decimals scaling
    uint256 public rebasingIndex; // unitsPerShare scaled by 1e18

    // Accounting for estimates
    uint256 public lastRebaseAssets;
    uint256 public lastRebaseTimestamp;

    event Rebased(uint256 newIndex, uint256 gainAssets, uint256 feeAssets, uint256 timestamp);

    constructor(IERC4626 vault_, address admin) ERC20("Ajey Rebasing Unit", "aJ-RU") {
        VAULT = vault_;
        rebasingIndex = 1e18; // 1 unit = 1 share initially
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // --- User I/O ---
    function wrapDeposit(uint256 assets, address receiver) external nonReentrant returns (uint256 units) {
        // Pull assets from user and approve vault
        IERC20 asset = IERC20(VAULT.asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(VAULT), assets);
        uint256 shares = VAULT.deposit(assets, address(this));
        units = _sharesToUnits(shares);
        _mint(receiver, units);
    }

    function wrapRedeem(uint256 units, address receiver) external nonReentrant returns (uint256 assets) {
        _burn(msg.sender, units);
        uint256 shares = _unitsToShares(units);
        assets = VAULT.redeem(shares, receiver, address(this));
    }

    // --- Rebase (Agent) ---
    /// @notice Update index to reflect share value growth (net of fees already applied in vault).
    function rebase() external onlyRole(AGENT_ROLE) {
        // The vault has canonical share accounting; here we reflect growth into units by increasing index
        uint256 totalShares = VAULT.totalSupply();
        if (totalShares == 0) {
            lastRebaseAssets = VAULT.totalAssets();
            lastRebaseTimestamp = block.timestamp;
            return;
        }

        uint256 currentAssets = VAULT.totalAssets();
        uint256 previous = lastRebaseAssets;
        if (previous == 0) previous = currentAssets;

        if (currentAssets > previous) {
            // Growth ratio on assets maps to growth in shares price; reflect proportionally in index
            // newIndex = index * currentAssets / previous
            rebasingIndex = (rebasingIndex * currentAssets) / previous;
        }

        lastRebaseAssets = currentAssets;
        lastRebaseTimestamp = block.timestamp;
        emit Rebased(rebasingIndex, currentAssets > previous ? (currentAssets - previous) : 0, 0, block.timestamp);
    }

    // --- Views ---
    function underlyingSharesOf(address user) external view returns (uint256) {
        return _unitsToShares(balanceOf(user));
    }

    function estimateUserEarnings(address user, uint256 horizonSeconds) external view returns (uint256, uint256) {
        // naive estimate: use last delta rate
        if (lastRebaseTimestamp == 0) return (0, block.timestamp);
        if (VAULT.totalSupply() == 0) return (0, block.timestamp);
        uint256 lastAssets = lastRebaseAssets;
        uint256 nowAssets = VAULT.totalAssets();
        if (nowAssets <= lastAssets) return (0, block.timestamp);

        uint256 delta = nowAssets - lastAssets;
        uint256 dt = block.timestamp - lastRebaseTimestamp;
        if (dt == 0) return (0, block.timestamp);

        uint256 ratePerSec = (delta * 1e18) / dt; // assets/sec (scaled)
        uint256 projected = (ratePerSec * horizonSeconds) / 1e18;

        // user share of assets proportional to units
        uint256 userShares = _unitsToShares(balanceOf(user));
        uint256 totalShares = VAULT.totalSupply();
        if (totalShares == 0) return (0, block.timestamp);
        uint256 userProjected = (projected * userShares) / totalShares;
        return (userProjected, lastRebaseTimestamp);
    }

    function currentApy() external view returns (uint256 apyBps, uint256 sampleSeconds) {
        if (lastRebaseTimestamp == 0) return (0, 0);
        uint256 dt = block.timestamp - lastRebaseTimestamp;
        if (dt == 0) return (0, 0);
        uint256 lastAssets = lastRebaseAssets;
        uint256 nowAssets = VAULT.totalAssets();
        if (nowAssets <= lastAssets || nowAssets == 0) return (0, dt);
        uint256 rate = ((nowAssets - lastAssets) * 1e18) / dt; // assets/sec
        // approximate APY on assets
        uint256 yearly = (rate * 365 days) / 1e18;
        apyBps = (yearly * 10_000) / nowAssets;
        sampleSeconds = dt;
    }

    // --- Internal --- 
    function _sharesToUnits(uint256 shares) internal view returns (uint256) {
        return (shares * rebasingIndex) / 1e18;
    }

    function _unitsToShares(uint256 units) internal view returns (uint256) {
        return (units * 1e18) / rebasingIndex;
    }
}



// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBaseStrategy} from "../../src/interfaces/IBaseStrategy.sol";

/// @notice Very simple ERC20 share token strategy used for orchestrator tests
contract MockSimpleStrategy is ERC20, IBaseStrategy {
    using SafeERC20 for IERC20;

    address public immutable underlying;

    uint256 public mockProfit;
    uint256 public mockLoss;

    constructor(address _underlying, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        underlying = _underlying;
    }

    function setReport(uint256 profit, uint256 loss) external {
        mockProfit = profit;
        mockLoss = loss;
    }

    function report() external returns (uint256 profit, uint256 loss) {
        return (mockProfit, mockLoss);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets > 0) {
            IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets);
        }
        _mint(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        // 1:1 asset-to-share mapping in mock
        uint256 sharesToBurn = assets;
        if (sharesToBurn > 0) {
            _burn(owner, sharesToBurn);
            IERC20(underlying).safeTransfer(receiver, assets);
        }
        return sharesToBurn;
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function asset() external view returns (address) {
        return underlying;
    }
}


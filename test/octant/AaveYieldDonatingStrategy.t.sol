// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AjeyVault} from "../../src/core/AjeyVault.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {AaveYieldDonatingStrategy} from "../../src/octant/AaveYieldDonatingStrategy.sol";
import {MockERC20, MockAToken} from "../mocks/MockTokens.sol";
import {MockAaveV3Pool} from "../mocks/MockAave.sol";
import {YieldDonatingTokenizedStrategy} from "@octant-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract AaveYieldDonatingStrategyTest is Test {
    address internal admin = address(0xA11CE);
    address internal keeper = address(0xA93A);
    address internal emergency = address(0xE911);
    address internal donation = address(0xD00D);
    address internal treasury = address(0xFEE5);

    MockERC20 internal assetToken;
    MockAToken internal aToken;
    MockAaveV3Pool internal pool;
    AjeyVault internal vault;
    address internal tokenizedImpl;

    function setUp() public {
        assetToken = new MockERC20("Mock DAI", "DAI", 18);
        aToken = new MockAToken("Mock aDAI", "aDAI");
        pool = new MockAaveV3Pool();
        pool.setAToken(address(assetToken), address(aToken));
        vault = new AjeyVault(
            IERC20(address(assetToken)), IERC20(address(aToken)), treasury, 500, IAaveV3Pool(address(pool)), admin
        );
        tokenizedImpl = address(new YieldDonatingTokenizedStrategy());
    }

    function _deployStrategy(address vlt) internal returns (AaveYieldDonatingStrategy strat) {
        strat = new AaveYieldDonatingStrategy(
            address(assetToken), "AaveYDS", admin, keeper, emergency, donation, false, tokenizedImpl, payable(vlt)
        );
    }

    function test_Constructor_SetsVaultAndAllowance() public {
        AaveYieldDonatingStrategy strat = _deployStrategy(address(vault));
        assertEq(address(strat.vault()), address(vault));
        // Allowance to vault should be max
        assertEq(IERC20(address(assetToken)).allowance(address(strat), address(vault)), type(uint256).max);
    }

    function test_Constructor_Revert_AssetMismatch() public {
        // Create another vault with different asset
        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 6);
        MockAToken aUsdc = new MockAToken("Mock aUSDC", "aUSDC");
        pool.setAToken(address(usdc), address(aUsdc));
        AjeyVault wrongVault = new AjeyVault(
            IERC20(address(usdc)), IERC20(address(aUsdc)), treasury, 500, IAaveV3Pool(address(pool)), admin
        );
        vm.expectRevert(bytes("asset mismatch"));
        _deployStrategy(address(wrongVault));
    }

    function test_SetVault_OnlyManagement_UpdatesApproval() public {
        AaveYieldDonatingStrategy strat = _deployStrategy(address(vault));

        // New vault with same asset
        AjeyVault newVault = new AjeyVault(
            IERC20(address(assetToken)), IERC20(address(aToken)), treasury, 500, IAaveV3Pool(address(pool)), admin
        );

        vm.prank(admin);
        strat.setVault(payable(address(newVault)));
        assertEq(address(strat.vault()), address(newVault));
        assertEq(IERC20(address(assetToken)).allowance(address(strat), address(newVault)), type(uint256).max);
    }
}


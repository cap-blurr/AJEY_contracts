// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AjeyVault} from "../src/AjeyVault.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IWETHGateway} from "../src/interfaces/IWETHGateway.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockERC20, MockAToken, MockWETH} from "./mocks/MockTokens.sol";
import {MockAaveV3Pool, MockWETHGateway} from "./mocks/MockAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AjeyVaultTest is Test {
    address internal admin = address(0xA11CE);
    address internal user = address(0xBEEF);
    address internal agent = address(0xA93A);
    address internal treasury = address(0xFEE5);

    MockERC20 internal usdc;
    MockAToken internal aUsdc;
    MockAaveV3Pool internal pool;
    AjeyVault internal vault;

    // WETH fallback test fixtures
    MockWETH internal weth;
    MockAToken internal aWeth;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        aUsdc = new MockAToken("Mock aUSDC", "aUSDC");
        pool = new MockAaveV3Pool();
        pool.setAToken(address(usdc), address(aUsdc));

        vault = new AjeyVault(
            IERC20(address(usdc)), IERC20(address(aUsdc)), treasury, 1000, IAaveV3Pool(address(pool)), admin
        );
        vm.prank(admin);
        vault.addAgent(agent);

        // WETH fixtures for ETH tests
        weth = new MockWETH();
        aWeth = new MockAToken("Mock aWETH", "aWETH");
        pool.setAToken(address(weth), address(aWeth));
    }

    function test_Deposit_MintShares() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000); // 1 USDC (6dp)
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500_000, user);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);
        assertEq(usdc.balanceOf(address(vault)), 500_000);
    }

    function test_DepositEth_FallbackWrapsAndSupplies_WhenNoGateway() public {
        // Deploy a new vault configured for WETH underlying
        AjeyVault wethVault = new AjeyVault(
            IERC20(address(weth)), IERC20(address(aWeth)), treasury, 1000, IAaveV3Pool(address(pool)), admin
        );
        vm.prank(admin);
        wethVault.addAgent(agent);

        // Enable ETH mode without gateway
        vm.prank(admin);
        wethVault.setEthGateway(address(0), true);

        // User deposits native ETH
        vm.deal(user, 5 ether);
        vm.prank(user);
        uint256 shares = wethVault.depositEth{value: 2 ether}(user);
        assertEq(wethVault.balanceOf(user), shares);

        // Shares minted
        assertGt(shares, 0);
        assertEq(wethVault.balanceOf(user), shares);
        // aWETH minted to vault (supplied to pool)
        assertEq(aWeth.balanceOf(address(wethVault)), 2 ether);
        // No idle WETH remains since we supply immediately
        assertEq(weth.balanceOf(address(wethVault)), 0);
    }

    function test_WithdrawEth_FallbackUnwraps_WhenNoGateway() public {
        // New WETH vault as above
        AjeyVault wethVault = new AjeyVault(
            IERC20(address(weth)), IERC20(address(aWeth)), treasury, 1000, IAaveV3Pool(address(pool)), admin
        );
        vm.prank(admin);
        wethVault.addAgent(agent);
        vm.prank(admin);
        wethVault.setEthGateway(address(0), true);

        // Deposit 2 ETH
        vm.deal(user, 5 ether);
        vm.prank(user);
        uint256 shares = wethVault.depositEth{value: 2 ether}(user);

        // Redeem 1 ETH via withdrawEth
        uint256 balBefore = user.balance;
        vm.prank(user);
        uint256 burned = wethVault.withdrawEth(1 ether, user, user);
        assertGt(burned, 0);
        assertEq(user.balance, balBefore + 1 ether);
        // aToken balance reduced accordingly
        assertEq(aWeth.balanceOf(address(wethVault)), 1 ether);
    }

    function test_DepositEth_UsesGateway_WhenConfigured() public {
        // New WETH vault
        AjeyVault wethVault = new AjeyVault(
            IERC20(address(weth)), IERC20(address(aWeth)), treasury, 1000, IAaveV3Pool(address(pool)), admin
        );
        vm.prank(admin);
        wethVault.addAgent(agent);

        // Configure mock gateway and enable
        MockWETHGateway gw = new MockWETHGateway(address(pool), address(weth));
        vm.prank(admin);
        wethVault.setEthGateway(address(gw), true);

        // Deposit via gateway path
        vm.deal(user, 3 ether);
        vm.prank(user);
        uint256 shares = wethVault.depositEth{value: 1 ether}(user);
        assertEq(wethVault.balanceOf(user), shares);
        assertGt(shares, 0);
        assertEq(wethVault.balanceOf(user), shares);
        // In mock gateway, we don't actually route to pool, so just assert no revert and shares minted
    }

    function test_AgentSupplyToAave_MintsAToken() public {
        // deposit first
        vm.startPrank(user);
        usdc.mint(user, 2_000_000);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000, user);
        vm.stopPrank();

        // supply to aave
        vm.prank(agent);
        vault.supplyToAave(1_000_000);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(aUsdc.balanceOf(address(vault)), 1_000_000);
    }

    function test_Withdraw_PullsFromAaveIfNeeded() public {
        // deposit and supply
        vm.startPrank(user);
        usdc.mint(user, 2_000_000);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1_000_000, user);
        assertEq(vault.balanceOf(user), shares);
        vm.stopPrank();

        vm.prank(agent);
        vault.supplyToAave(1_000_000);

        // withdraw half assets - should pull from aave
        vm.prank(user);
        uint256 burned = vault.withdraw(500_000, user, user);
        assertGt(burned, 0);
        // user started with 2_000_000; after deposit 1_000_000, had 1_000_000 left;
        // withdrew 500_000 now, so should be 1_500_000
        assertEq(usdc.balanceOf(user), 1_500_000);
        assertEq(aUsdc.balanceOf(address(vault)), 500_000);
    }

    function test_RebaseAndTakeFees_MintsFeeShares() public {
        // deposit and supply
        vm.startPrank(user);
        usdc.mint(user, 2_000_000);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000, user);
        vm.stopPrank();
        vm.prank(agent);
        vault.supplyToAave(1_000_000);

        // first rebase sets checkpoint baseline
        vm.prank(agent);
        vault.rebaseAndTakeFees();

        // simulate yield by minting aToken to vault (only pool can mint)
        vm.prank(address(pool));
        aUsdc.mint(address(vault), 100_000);

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(agent);
        vault.rebaseAndTakeFees();
        uint256 supplyAfter = vault.totalSupply();

        assertGt(supplyAfter, supplyBefore);
        assertGt(vault.balanceOf(treasury), 0);
    }

    function test_Roles_OnlyAgentCanSupplyWithdraw() public {
        vm.expectRevert();
        vault.supplyToAave(1);
        vm.expectRevert();
        vault.withdrawFromAave(1);
    }

    function test_PauseBlocksStateChanging() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(100_000, user);
        vm.stopPrank();

        vm.prank(admin);
        vault.unpause();
    }

    function test_SetParams_RevertOnZeroTreasury() public {
        vm.prank(admin);
        vm.expectRevert(bytes("treasury=0"));
        vault.setParams(address(0), 100);
    }

    function test_SetParams_RevertOnHighFee() public {
        vm.prank(admin);
        vm.expectRevert(bytes("fee too high"));
        vault.setParams(treasury, 2000);
    }

    function test_SetParams_UpdatesValues() public {
        address newTreasury = address(0x1234);
        vm.prank(admin);
        vault.setParams(newTreasury, 500);
        // direct assertions
        assertEq(vault.treasury(), newTreasury);
        assertEq(vault.feeBps(), 500);
    }

    function test_SupplyToAave_ZeroAmount_NoEffect() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000, user);
        vm.stopPrank();

        uint256 idleBefore = usdc.balanceOf(address(vault));
        vm.prank(agent);
        vault.supplyToAave(0);
        uint256 idleAfter = usdc.balanceOf(address(vault));
        assertEq(idleAfter, idleBefore);
    }

    function test_WithdrawFromAave_ZeroAmount_NoEffect() public {
        vm.prank(agent);
        vault.withdrawFromAave(0);
        // nothing to assert except absence of revert; ensure balances unchanged
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
    }

    function test_Withdraw_NoPoolCallWhenIdleEnough() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000, user);
        vm.stopPrank();

        // idle covers withdrawal, aToken stays 0
        vm.prank(user);
        vault.withdraw(400_000, user, user);
        assertEq(aUsdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 600_000);
    }

    function test_MintByShares_Path() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(vault), type(uint256).max);
        uint256 assetsForShares = vault.mint(300_000, user);
        vm.stopPrank();

        assertGt(assetsForShares, 0);
        assertEq(vault.balanceOf(user), 300_000);
        assertEq(usdc.balanceOf(address(vault)), assetsForShares);
    }

    function test_Redeem_Path() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500_000, user);
        vm.stopPrank();

        vm.prank(user);
        uint256 assets = vault.redeem(shares / 2, user, user);
        assertGt(assets, 0);
        assertEq(vault.balanceOf(user), shares - (shares / 2));
    }

    function test_PauseBlocksAgentOps() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.supplyToAave(1);
        vm.prank(agent);
        vm.expectRevert();
        vault.withdrawFromAave(1);
        vm.prank(admin);
        vault.unpause();
    }

    function test_RemoveAgentBlocksOps() public {
        vm.prank(admin);
        vault.removeAgent(agent);
        vm.prank(agent);
        vm.expectRevert();
        vault.supplyToAave(1);
    }
}


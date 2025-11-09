// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentOrchestrator} from "../../src/octant/AgentOrchestrator.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {MockSimpleStrategy} from "../mocks/MockSimpleStrategy.sol";
import {MockUniswapV3Router} from "../mocks/MockUniswapV3Router.sol";
import {MockPermitToken} from "../mocks/MockPermitToken.sol";

contract AgentOrchestratorTest is Test {
    address internal admin = address(0xA11CE);
    address internal agent = address(0xA93A);
    address internal user = address(0xBEEF);
    address internal receiver = address(0xF00D);

    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockSimpleStrategy internal stratUsdc;
    MockSimpleStrategy internal stratDai;
    MockUniswapV3Router internal router;
    AgentOrchestrator internal orch;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        dai = new MockERC20("Mock DAI", "DAI", 18);
        stratUsdc = new MockSimpleStrategy(address(usdc), "sUSDC", "sUSDC");
        stratDai = new MockSimpleStrategy(address(dai), "sDAI", "sDAI");
        router = new MockUniswapV3Router();
        orch = new AgentOrchestrator(admin, agent, address(router), 3000);

        // Register strategies under Balanced profile
        vm.prank(admin);
        orch.setStrategy(AgentOrchestrator.Profile.Balanced, address(usdc), address(stratUsdc));
        vm.prank(admin);
        orch.setStrategy(AgentOrchestrator.Profile.Balanced, address(dai), address(stratDai));

        // Seed user balances
        usdc.mint(user, 10_000_000);
        dai.mint(user, 1_000 ether);
    }

    function test_SetStrategy_StoresMapping() public {
        assertEq(orch.strategyOf(AgentOrchestrator.Profile.Balanced, address(usdc)), address(stratUsdc));
        assertEq(orch.strategyOf(AgentOrchestrator.Profile.Balanced, address(dai)), address(stratDai));
    }

    function test_DepositERC20_SameAsset_MintsShares() public {
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(orch), type(uint256).max);
        vm.stopPrank();

        vm.prank(agent);
        uint256 shares = orch.depositERC20(
            AgentOrchestrator.Profile.Balanced, user, address(usdc), 1_000_000, address(usdc), 0, receiver
        );

        assertGt(shares, 0);
        assertEq(IERC20(address(stratUsdc)).balanceOf(receiver), shares);
        assertEq(usdc.balanceOf(address(stratUsdc)), 1_000_000);
    }

    function test_DepositERC20_WithSwap_UsesRouter() public {
        // Router must hold DAI to pay out
        dai.mint(address(router), 5_000_000e12); // 5,000,000 DAI wei equivalent to 5_000_000 USDC 1:1

        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(orch), type(uint256).max);
        vm.stopPrank();

        vm.prank(agent);
        uint256 shares = orch.depositERC20(
            AgentOrchestrator.Profile.Balanced, user, address(usdc), 2_000_000, address(dai), 1, receiver
        );
        assertGt(shares, 0);
        assertEq(IERC20(address(stratDai)).balanceOf(receiver), shares);
        assertEq(dai.balanceOf(address(stratDai)), 2_000_000);
    }

    function _userDepositToDai(uint256 amt) internal returns (uint256 shares) {
        // Seed router with DAI for swap so deposit path can convert USDC->DAI
        dai.mint(address(router), amt);
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(orch), type(uint256).max);
        vm.stopPrank();
        vm.prank(agent);
        shares = orch.depositERC20(AgentOrchestrator.Profile.Balanced, user, address(usdc), amt, address(dai), 1, user);
    }

    function test_WithdrawERC20_SameAsset() public {
        // Directly deposit to USDC strategy for user
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(stratUsdc), type(uint256).max);
        MockSimpleStrategy(address(stratUsdc)).deposit(3_000_000, user);
        vm.stopPrank();

        // Withdraw underlying USDC to receiver
        vm.prank(agent);
        uint256 out = orch.withdrawERC20(
            AgentOrchestrator.Profile.Balanced, user, address(usdc), 1_500_000, address(usdc), 0, receiver
        );
        assertEq(out, 1_500_000);
        assertEq(usdc.balanceOf(receiver), 1_500_000);
    }

    function test_WithdrawERC20_WithSwap() public {
        // Give user shares in DAI strategy via orchestrator
        _userDepositToDai(2_000_000);
        // Router must hold USDC to pay out after swap
        usdc.mint(address(router), 2_000_000);

        vm.prank(agent);
        uint256 out = orch.withdrawERC20(
            AgentOrchestrator.Profile.Balanced, user, address(dai), 1_000_000, address(usdc), 1, receiver
        );
        assertEq(out, 1_000_000);
        assertEq(usdc.balanceOf(receiver), 1_000_000);
    }

    function test_Reallocate_CrossAsset() public {
        // Create initial DAI position for user
        uint256 initialShares = _userDepositToDai(1_000_000);
        assertEq(IERC20(address(stratDai)).balanceOf(user), initialShares);

        // Router must hold USDC to pay swap result
        usdc.mint(address(router), 1_000_000);

        vm.prank(agent);
        orch.reallocate(AgentOrchestrator.Profile.Balanced, user, address(dai), address(usdc), initialShares / 2, 1);

        // User should have some USDC strategy shares after reallocation
        assertGt(IERC20(address(stratUsdc)).balanceOf(user), 0);
    }

    function test_HarvestStrategy_EmitsEvent() public {
        stratDai.setReport(333, 0);
        vm.expectEmit(true, true, true, true);
        emit AgentOrchestrator.YieldHarvested(address(stratDai), 333, 0);
        vm.prank(agent);
        orch.harvestStrategy(address(stratDai));
    }

    function test_PermitShares_CallsPermit() public {
        MockPermitToken token = new MockPermitToken();
        vm.prank(agent);
        orch.permitShares(address(token), user, 123, block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));
        assertTrue(token.wasCalled());
        assertEq(token.lastOwner(), user);
        assertEq(token.lastSpender(), address(orch));
        assertEq(token.lastValue(), 123);
    }

    function test_RoleRequired_ForAgentCalls() public {
        vm.expectRevert();
        orch.harvestAll();
        vm.expectRevert();
        orch.depositERC20(AgentOrchestrator.Profile.Balanced, user, address(usdc), 1, address(usdc), 0, receiver);
    }
}


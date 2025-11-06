// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

import {AjeyVault} from "../src/AjeyVault.sol";
import {AgentReallocator} from "../src/AgentReallocator.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";

import {MockERC20, MockAToken} from "./mocks/MockTokens.sol";
import {MockAaveV3Pool} from "./mocks/MockAave.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract AgentReallocatorTest is Test {
    address internal admin = address(0xA11CE);
    address internal user = address(0xBEEF);
    address internal receiver = address(0xF00D);
    address internal treasury = address(0xFEE5);

    MockERC20 internal usdc;
    MockAToken internal aUsdc;
    MockAaveV3Pool internal pool;
    AjeyVault internal v1;
    AjeyVault internal v2;

    AgentReallocator internal realloc;
    MockAggregator internal aggregator;

    function setUp() public {
        // Underlyings
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        aUsdc = new MockAToken("Mock aUSDC", "aUSDC");
        pool = new MockAaveV3Pool();
        pool.setAToken(address(usdc), address(aUsdc));

        // Two vaults with same underlying
        v1 = new AjeyVault(
            IERC20(address(usdc)), IERC20(address(aUsdc)), treasury, 500, IAaveV3Pool(address(pool)), admin
        );
        v2 = new AjeyVault(
            IERC20(address(usdc)), IERC20(address(aUsdc)), treasury, 500, IAaveV3Pool(address(pool)), admin
        );

        // Reallocator and aggregator
        realloc = new AgentReallocator(admin, admin);
        aggregator = new MockAggregator();

        // Seed user with USDC and deposit into v1
        vm.startPrank(user);
        usdc.mint(user, 10_000_000); // 10 USDC (6dp)
        usdc.approve(address(v1), type(uint256).max);
        v1.deposit(5_000_000, user); // 5 USDC
        vm.stopPrank();
    }

    function test_Construct_SetsRoles() public {
        // Admin has DEFAULT_ADMIN_ROLE and AGENT_ROLE at construction (covered by internal grant)
        // We check by calling an admin-only function
        vm.prank(admin);
        realloc.setAggregator(address(aggregator), true);
    }

    function test_Migrate_SameAsset_NoSwap() public {
        // Approve reallocator to spend user's v1 shares
        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        vm.stopPrank();

        // Move all shares from v1 to v2 without swap
        uint256 userShares = IERC20(address(v1)).balanceOf(user);
        vm.prank(user);
        uint256 outShares = realloc.migrateShares(
            user,
            user,
            address(v1),
            address(v2),
            userShares,
            address(0), // aggregator
            bytes(""),
            0,
            block.timestamp + 1 days
        );

        assertGt(outShares, 0);
        assertEq(IERC20(address(v1)).balanceOf(user), 0);
        assertEq(IERC20(address(v2)).balanceOf(user), outShares);
    }

    function test_Migrate_WithSwap_UsesAggregatorAndSlippage() public {
        // Prepare a second underlying and vault to simulate cross-asset migration
        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        MockAToken aDai = new MockAToken("Mock aDAI", "aDAI");
        MockAaveV3Pool pool2 = new MockAaveV3Pool();
        pool2.setAToken(address(dai), address(aDai));
        AjeyVault vDst = new AjeyVault(
            IERC20(address(dai)), IERC20(address(aDai)), treasury, 500, IAaveV3Pool(address(pool2)), admin
        );

        // Whitelist aggregator
        vm.prank(admin);
        realloc.setAggregator(address(aggregator), true);

        // Seed aggregator with DAI to pay out swap
        dai.mint(address(aggregator), 1_000 ether);

        // Approve reallocator to spend user's v1 shares
        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        vm.stopPrank();

        // Encode aggregator call: swap(usdc, dai, amountIn, amountOut)
        uint256 shares = IERC20(address(v1)).balanceOf(user) / 2;
        uint256 assetsFrom = v1.previewRedeem(shares);
        bytes memory data = abi.encodeWithSelector(
            MockAggregator.swap.selector,
            address(usdc),
            address(dai),
            assetsFrom,
            assetsFrom // 1:1 for test
        );

        vm.prank(user);
        uint256 outShares = realloc.migrateShares(
            user,
            user,
            address(v1),
            address(vDst),
            shares,
            address(aggregator),
            data,
            assetsFrom, // minAmountOut
            block.timestamp + 1 days
        );

        assertGt(outShares, 0);
        assertEq(IERC20(address(vDst)).balanceOf(user), outShares);
    }

    function test_Revert_ExpiredDeadline() public {
        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        vm.expectRevert(bytes("expired"));
        realloc.migrateShares(user, user, address(v1), address(v2), 1, address(0), bytes(""), 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_Revert_AggregatorNotAllowed() public {
        // Set up cross-asset target vault so swap path is taken
        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        MockAToken aDai = new MockAToken("Mock aDAI", "aDAI");
        MockAaveV3Pool pool2 = new MockAaveV3Pool();
        pool2.setAToken(address(dai), address(aDai));
        AjeyVault vDst = new AjeyVault(
            IERC20(address(dai)), IERC20(address(aDai)), treasury, 500, IAaveV3Pool(address(pool2)), admin
        );

        // Do NOT whitelist aggregator
        // realloc.setAggregator(address(aggregator), true); // intentionally omitted

        // Approve reallocator to spend user's v1 shares
        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        // Expect revert due to aggregator not allowed
        vm.expectRevert(bytes("agg not allowed"));
        realloc.migrateShares(
            user, user, address(v1), address(vDst), 1, address(aggregator), bytes(""), 0, block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_Revert_Slippage() public {
        // Setup cross-asset as before
        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        MockAToken aDai = new MockAToken("Mock aDAI", "aDAI");
        MockAaveV3Pool pool2 = new MockAaveV3Pool();
        pool2.setAToken(address(dai), address(aDai));
        AjeyVault vDst = new AjeyVault(
            IERC20(address(dai)), IERC20(address(aDai)), treasury, 500, IAaveV3Pool(address(pool2)), admin
        );

        vm.prank(admin);
        realloc.setAggregator(address(aggregator), true);

        // Seed aggregator with too little DAI to force slippage revert
        dai.mint(address(aggregator), 1 ether);

        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        uint256 shares = 1000;
        uint256 assetsFrom = v1.previewRedeem(shares);
        bytes memory data =
            abi.encodeWithSelector(MockAggregator.swap.selector, address(usdc), address(dai), assetsFrom, 1); // will return 1
        vm.expectRevert(bytes("slippage"));
        realloc.migrateShares(
            user, user, address(v1), address(vDst), shares, address(aggregator), data, assetsFrom, block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_ApprovalsCleared_AfterSwap() public {
        // Cross-asset again
        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        MockAToken aDai = new MockAToken("Mock aDAI", "aDAI");
        MockAaveV3Pool pool2 = new MockAaveV3Pool();
        pool2.setAToken(address(dai), address(aDai));
        AjeyVault vDst = new AjeyVault(
            IERC20(address(dai)), IERC20(address(aDai)), treasury, 500, IAaveV3Pool(address(pool2)), admin
        );

        vm.prank(admin);
        realloc.setAggregator(address(aggregator), true);
        dai.mint(address(aggregator), 1_000 ether);

        vm.startPrank(user);
        IERC20(address(v1)).approve(address(realloc), type(uint256).max);
        uint256 shares = 500;
        uint256 assetsFrom = v1.previewRedeem(shares);
        bytes memory data =
            abi.encodeWithSelector(MockAggregator.swap.selector, address(usdc), address(dai), assetsFrom, assetsFrom);
        vm.stopPrank();

        // Before: 0 allowance
        assertEq(IERC20(address(usdc)).allowance(address(realloc), address(aggregator)), 0);

        // Execute migration
        vm.prank(user);
        realloc.migrateShares(
            user, user, address(v1), address(vDst), shares, address(aggregator), data, 0, block.timestamp + 1
        );

        // After: approval should be cleared back to 0
        assertEq(IERC20(address(usdc)).allowance(address(realloc), address(aggregator)), 0);
    }
}


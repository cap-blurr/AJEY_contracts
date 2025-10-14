// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebasingWrapper} from "../src/RebasingWrapper.sol";
import {AjeyVault} from "../src/AjeyVault.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {MockERC20, MockAToken} from "./mocks/MockTokens.sol";
import {MockAaveV3Pool} from "./mocks/MockAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RebasingWrapperTest is Test {
    address internal admin = address(0xA11CE);
    address internal user = address(0xBEEF);
    address internal agent = address(0xA93A);
    address internal treasury = address(0xFEE5);

    MockERC20 internal usdc;
    MockAToken internal aUsdc;
    MockAaveV3Pool internal pool;
    AjeyVault internal vault;
    RebasingWrapper internal wrapper;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        aUsdc = new MockAToken("Mock aUSDC", "aUSDC");
        pool = new MockAaveV3Pool();
        pool.setAToken(address(usdc), address(aUsdc));

        vault = new AjeyVault(
            IERC20(address(usdc)), IERC20(address(aUsdc)), treasury, 1000, IAaveV3Pool(address(pool)), admin
        );
        wrapper = new RebasingWrapper(vault, admin);

        vm.prank(admin);
        vault.addAgent(agent);
        // Avoid prank being consumed by AGENT_ROLE() argument evaluation
        bytes32 role = wrapper.AGENT_ROLE();
        vm.prank(admin);
        wrapper.grantRole(role, agent);
    }

    function test_WrapDeposit_MintsUnits() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        uint256 units = wrapper.wrapDeposit(500_000, user);
        vm.stopPrank();

        assertGt(units, 0);
        assertEq(wrapper.balanceOf(user), units);
        // wrapper should hold shares
        assertGt(vault.balanceOf(address(wrapper)), 0);
    }

    function test_Rebase_IncreasesIndex() public {
        // deposit to vault via wrapper and supply to aave to simulate yield
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.wrapDeposit(1_000_000, user);
        vm.stopPrank();

        vm.prank(agent);
        vault.supplyToAave(1_000_000);

        // first rebase sets baseline
        vm.prank(agent);
        wrapper.rebase();

        // simulate yield by minting aToken as the pool, then rebase again
        vm.prank(address(pool));
        aUsdc.mint(address(vault), 100_000);

        uint256 idxBefore = wrapper.rebasingIndex();
        vm.prank(agent);
        wrapper.rebase();
        uint256 idxAfter = wrapper.rebasingIndex();
        assertGt(idxAfter, idxBefore);
    }

    function test_WrapRedeem_BurnsUnitsAndReturnsAssets() public {
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        uint256 units = wrapper.wrapDeposit(600_000, user);
        vm.stopPrank();

        // withdraw via wrapper
        vm.prank(user);
        uint256 assets = wrapper.wrapRedeem(units / 2, user);
        assertGt(assets, 0);
        assertGt(usdc.balanceOf(user), 0);
    }

    function test_EstimateAndAPYViews_DoNotRevert() public {
        // baseline
        vm.startPrank(user);
        usdc.mint(user, 1_000_000);
        usdc.approve(address(wrapper), type(uint256).max);
        wrapper.wrapDeposit(1_000_000, user);
        vm.stopPrank();

        vm.prank(agent);
        wrapper.rebase();

        // simulate yield
        vm.prank(address(pool));
        aUsdc.mint(address(vault), 50_000);

        // second rebase
        vm.prank(agent);
        wrapper.rebase();

        // advance time so sample window > 0
        skip(1 hours);
        (uint256 est,) = wrapper.estimateUserEarnings(user, 1 days);
        (uint256 apyBps, uint256 sample) = wrapper.currentApy();
        assertGt(sample, 0);
        // Not asserting specific numbers; just ensure sane outputs
        assertTrue(est >= 0);
        assertTrue(apyBps >= 0);
    }
}


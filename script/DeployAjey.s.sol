// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AjeyVault} from "../src/core/AjeyVault.sol";
import {AgentReallocator} from "../src/core/AgentReallocator.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";

contract DeployAjey is Script {
    function run() external {
        // Optional PRIVATE_KEY; if not provided, Foundry will use the default broadcaster
        uint256 privKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address broadcaster = privKey != 0 ? vm.addr(privKey) : address(0);
        if (privKey != 0) vm.startBroadcast(privKey);
        else vm.startBroadcast();

        // Required envs
        address asset = vm.envAddress("ASSET");
        address aToken = vm.envAddress("ATOKEN");
        address pool = vm.envAddress("AAVE_POOL");
        address treasury = vm.envAddress("TREASURY");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));

        // Admin/Agent
        address admin = vm.envOr("ADMIN", broadcaster);
        require(admin != address(0), "ADMIN not set and no PRIVATE_KEY");
        address agent = vm.envOr("AGENT", address(0));

        // Deploy AjeyVault
        AjeyVault vault = new AjeyVault(IERC20(asset), IERC20(aToken), treasury, feeBps, IAaveV3Pool(pool), admin);

        // Optionally enable native ETH. If ETH_GATEWAY is zero and ENABLE_ETH=true,
        // the vault will use local WETH wrap/unwrap fallback.
        address ethGateway = vm.envOr("ETH_GATEWAY", address(0));
        bool enableEth = vm.envOr("ENABLE_ETH", false);
        if (enableEth) {
            // Only the admin can call setEthGateway; ensure broadcaster is admin
            if (admin == (broadcaster == address(0) ? admin : broadcaster)) {
                vault.setEthGateway(ethGateway, true);
                if (ethGateway == address(0)) {
                    console2.log("ETH mode enabled without gateway (using local WETH fallback)");
                }
            } else {
                console2.log("WARN: Skipping setEthGateway - broadcaster != admin");
            }
        }

        // Grant AGENT_ROLE if agent provided and broadcaster is admin
        if (agent != address(0)) {
            if (admin == (broadcaster == address(0) ? admin : broadcaster)) {
                vault.addAgent(agent);
            } else {
                console2.log("WARN: Skipping addAgent - broadcaster != admin");
            }
        }

        // --- Deploy AgentReallocator ---
        address reallocAdmin = vm.envOr("REALLOCATOR_ADMIN", admin);
        address reallocAgent = vm.envOr("REALLOCATOR_AGENT", agent);
        require(reallocAdmin != address(0), "realloc admin=0");
        require(reallocAgent != address(0), "realloc agent=0");
        AgentReallocator reallocator = new AgentReallocator(reallocAdmin, reallocAgent);

        // Optionally whitelist a default aggregator
        address aggregator = vm.envOr("AGGREGATOR", address(0));
        bool allowAggregator = vm.envOr("ALLOW_AGGREGATOR", false);
        if (allowAggregator && aggregator != address(0)) {
            if (reallocAdmin == (broadcaster == address(0) ? reallocAdmin : broadcaster)) {
                reallocator.setAggregator(aggregator, true);
            } else {
                console2.log("WARN: Skipping setAggregator - broadcaster != realloc admin");
            }
        }

        console2.log("AjeyVault", address(vault));
        console2.log("AgentReallocator", address(reallocator));
        console2.log("Admin", admin);
        if (agent != address(0)) console2.log("Agent", agent);

        vm.stopBroadcast();
    }
}


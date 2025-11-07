// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {AgentReallocator} from "../src/core/AgentReallocator.sol";

contract DeployReallocator is Script {
    function run() external {
        uint256 privKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address broadcaster = privKey != 0 ? vm.addr(privKey) : address(0);
        if (privKey != 0) vm.startBroadcast(privKey);
        else vm.startBroadcast();

        address admin = vm.envOr("REALLOCATOR_ADMIN", broadcaster);
        address reallocAgent = vm.envOr("REALLOCATOR_AGENT", address(0));
        require(admin != address(0), "admin=0");
        require(reallocAgent != address(0), "agent=0");
        AgentReallocator reallocator = new AgentReallocator(admin, reallocAgent);

        // Optional: whitelist a default aggregator if provided
        address aggregator = vm.envOr("AGGREGATOR", address(0));
        bool allowAggregator = vm.envOr("ALLOW_AGGREGATOR", false);
        if (allowAggregator && aggregator != address(0)) {
            if (admin == (broadcaster == address(0) ? admin : broadcaster)) {
                reallocator.setAggregator(aggregator, true);
            } else {
                console2.log("WARN: Skipping setAggregator - broadcaster != admin");
            }
        }

        console2.log("AgentReallocator", address(reallocator));
        console2.log("Reallocator Admin", admin);
        console2.log("Reallocator Agent", reallocAgent);

        vm.stopBroadcast();
    }
}


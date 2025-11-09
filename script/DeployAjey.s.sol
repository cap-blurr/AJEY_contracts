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
        if (privKey != 0) vm.startBroadcast(privKey);
        else vm.startBroadcast();

        // Required envs (shared)
        address pool = vm.envAddress("AAVE_POOL");
        address treasury = vm.envAddress("TREASURY");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));

        // Admin/Agent
        address admin = vm.envOr("ADMIN", tx.origin);
        require(admin != address(0), "ADMIN not set");
        address agent = vm.envOr("AGENT", address(0));

        // Global toggles
        address ethGateway = vm.envOr("ETH_GATEWAY", address(0));
        bool enableEth = vm.envOr("ENABLE_ETH", false);
        address wethAsset = vm.envOr("WETH_ASSET", address(0)); // optional: identify which asset should enable ETH mode
        bool autoSupply = vm.envOr("AUTO_SUPPLY", false);
        bool publicDeposits = vm.envOr("PUBLIC_DEPOSITS", false); // default false: only strategies may deposit

        // MULTI-ASSET DEPLOY: If ASSETS/ATOKENS CSV provided, deploy for each pair; else fallback to single asset mode
        if (_hasEnv("ASSETS")) {
            address[] memory assets = _parseAddresses(vm.envString("ASSETS"));
            address[] memory aTokens = _parseAddresses(vm.envString("ATOKENS"));
            require(assets.length == aTokens.length && assets.length > 0, "bad ASSETS/ATOKENS");

            for (uint256 i = 0; i < assets.length; i++) {
                address asset = assets[i];
                address aToken = aTokens[i];

                // Deploy AjeyVault
                AjeyVault vault =
                    new AjeyVault(IERC20(asset), IERC20(aToken), treasury, feeBps, IAaveV3Pool(pool), admin);

                // Optionally enable native ETH for the WETH asset; fallback to local WETH if gateway unset
                if (enableEth && (wethAsset != address(0) && asset == wethAsset)) {
                    if (admin == tx.origin) {
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
                    if (admin == tx.origin) {
                        vault.addAgent(agent);
                    } else {
                        console2.log("WARN: Skipping addAgent - broadcaster != admin");
                    }
                }

                // Optionally enable auto-supply of idle underlying to Aave
                if (autoSupply) {
                    if (admin == tx.origin) {
                        vault.setAutoSupply(true);
                    } else {
                        console2.log("WARN: Skipping setAutoSupply - broadcaster != admin");
                    }
                }

                // Set public deposits mode on each vault
                if (admin == tx.origin) {
                    vault.setPublicDepositsEnabled(publicDeposits);
                    console2.log("PublicDepositsEnabled", publicDeposits);
                } else {
                    console2.log("WARN: Skipping setPublicDepositsEnabled - broadcaster != admin");
                }

                console2.log("AjeyVault", address(vault));
                console2.log("  ASSET", asset);
                console2.log("  ATOKEN", aToken);
            }
        } else {
            // SINGLE-ASSET DEPLOY (backward compatibility)
            address asset = vm.envAddress("ASSET");
            address aToken = vm.envAddress("ATOKEN");

            AjeyVault vault = new AjeyVault(IERC20(asset), IERC20(aToken), treasury, feeBps, IAaveV3Pool(pool), admin);

            if (enableEth && (wethAsset != address(0) && asset == wethAsset)) {
                if (admin == tx.origin) {
                    vault.setEthGateway(ethGateway, true);
                    if (ethGateway == address(0)) {
                        console2.log("ETH mode enabled without gateway (using local WETH fallback)");
                    }
                } else {
                    console2.log("WARN: Skipping setEthGateway - broadcaster != admin");
                }
            }

            if (agent != address(0)) {
                if (admin == tx.origin) {
                    vault.addAgent(agent);
                } else {
                    console2.log("WARN: Skipping addAgent - broadcaster != admin");
                }
            }

            if (autoSupply) {
                if (admin == tx.origin) {
                    vault.setAutoSupply(true);
                } else {
                    console2.log("WARN: Skipping setAutoSupply - broadcaster != admin");
                }
            }

            if (admin == tx.origin) {
                vault.setPublicDepositsEnabled(publicDeposits);
                console2.log("PublicDepositsEnabled", publicDeposits);
            } else {
                console2.log("WARN: Skipping setPublicDepositsEnabled - broadcaster != admin");
            }

            console2.log("AjeyVault", address(vault));
            console2.log("  ASSET", asset);
            console2.log("  ATOKEN", aToken);
        }

        // --- Reallocator handling ---
        // Prefer using a single pre-deployed AgentReallocator across assets.
        // If REALLOCATOR_ADDRESS is provided, we log and use that. Otherwise,
        // optionally deploy a new one only when DEPLOY_REALLOCATOR=true.
        address reallocatorAddr = vm.envOr("REALLOCATOR_ADDRESS", address(0));
        bool deployReallocator = vm.envOr("DEPLOY_REALLOCATOR", false);
        AgentReallocator reallocator;
        if (reallocatorAddr != address(0)) {
            console2.log("AgentReallocator (existing)", reallocatorAddr);
        } else if (deployReallocator) {
            address reallocAdmin = vm.envOr("REALLOCATOR_ADMIN", admin);
            address reallocAgent = vm.envOr("REALLOCATOR_AGENT", agent);
            require(reallocAdmin != address(0), "realloc admin=0");
            require(reallocAgent != address(0), "realloc agent=0");
            reallocator = new AgentReallocator(reallocAdmin, reallocAgent);
            reallocatorAddr = address(reallocator);
            console2.log("AgentReallocator (deployed)", reallocatorAddr);

            // Optionally whitelist a default aggregator
            address aggregator = vm.envOr("AGGREGATOR", address(0));
            bool allowAggregator = vm.envOr("ALLOW_AGGREGATOR", false);
            if (allowAggregator && aggregator != address(0)) {
                if (reallocAdmin == tx.origin) {
                    reallocator.setAggregator(aggregator, true);
                } else {
                    console2.log("WARN: Skipping setAggregator - broadcaster != realloc admin");
                }
            }
        } else {
            console2.log("AgentReallocator", "not set (provide REALLOCATOR_ADDRESS or set DEPLOY_REALLOCATOR=true)");
        }

        if (reallocatorAddr != address(0)) console2.log("AgentReallocator", reallocatorAddr);
        console2.log("Admin", admin);
        if (agent != address(0)) console2.log("Agent", agent);

        vm.stopBroadcast();
    }

    // Helpers
    function _hasEnv(string memory key) internal view returns (bool) {
        try vm.envString(key) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        string[] memory parts = _split(csv, ",");
        address[] memory addrs = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            addrs[i] = vm.parseAddress(parts[i]);
        }
        return addrs;
    }

    function _split(string memory s, string memory delim) internal pure returns (string[] memory) {
        bytes memory strBytes = bytes(s);
        bytes memory delimBytes = bytes(delim);
        require(delimBytes.length == 1, "1-char delim");
        uint256 partsCount = 1;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == delimBytes[0]) partsCount++;
        }
        string[] memory parts = new string[](partsCount);
        uint256 last = 0;
        uint256 p = 0;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == delimBytes[0]) {
                parts[p++] = _substring(s, last, i);
                last = i + 1;
            }
        }
        parts[p] = _substring(s, last, strBytes.length);
        return parts;
    }

    function _substring(string memory s, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(s);
        require(end >= start && end <= strBytes.length, "bad indexes");
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }
}


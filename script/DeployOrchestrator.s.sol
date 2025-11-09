// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {AgentOrchestrator} from "../src/octant/AgentOrchestrator.sol";

contract DeployOrchestrator is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        address admin = vm.envOr("ADMIN", tx.origin);
        address agent = vm.envAddress("AGENT");
        address uniswapRouter = vm.envAddress("UNISWAP_ROUTER");
        uint24 defaultPoolFee = uint24(vm.envUint("DEFAULT_POOL_FEE"));
        require(admin != address(0) && agent != address(0), "admin/agent=0");
        require(uniswapRouter != address(0), "router=0");
        require(defaultPoolFee > 0, "pool fee=0");

        AgentOrchestrator orch = new AgentOrchestrator(admin, agent, uniswapRouter, defaultPoolFee);
        console2.log("AgentOrchestrator", address(orch));

        // Optionally set strategies for Balanced
        _setStrategies(orch, AgentOrchestrator.Profile.Balanced, "BAL_ASSETS", "BAL_STRATEGIES");
        // Optionally set strategies for MaxHumanitarian
        _setStrategies(orch, AgentOrchestrator.Profile.MaxHumanitarian, "HUM_ASSETS", "HUM_STRATEGIES");
        // Optionally set strategies for MaxCrypto
        _setStrategies(orch, AgentOrchestrator.Profile.MaxCrypto, "CRYPTO_ASSETS", "CRYPTO_STRATEGIES");

        vm.stopBroadcast();
    }

    function _setStrategies(
        AgentOrchestrator orch,
        AgentOrchestrator.Profile profile,
        string memory assetsEnv,
        string memory strategiesEnv
    ) internal {
        // If envs are unset, skip
        if (!_hasEnv(assetsEnv) || !_hasEnv(strategiesEnv)) {
            return;
        }
        address[] memory assets = _parseAddresses(vm.envString(assetsEnv));
        address[] memory strategies = _parseAddresses(vm.envString(strategiesEnv));
        require(assets.length == strategies.length, "len mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            orch.setStrategy(profile, assets[i], strategies[i]);
            console2.log("SetStrategy", uint8(profile), assets[i], strategies[i]);
        }
    }

    function _hasEnv(string memory key) internal view returns (bool) {
        // Foundry does not expose a native "has" for strings; try-catch pattern
        // If missing, envString will revert; catching means missing
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


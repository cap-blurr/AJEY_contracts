// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {AjeyVault} from "../src/core/AjeyVault.sol";

/// @title GrantStrategyRoles
/// @notice Grants STRATEGY_ROLE on a target AjeyVault to a list of strategy addresses
/// @dev Env:
///  - PRIVATE_KEY (optional)
///  - TARGET_VAULT (AjeyVault address)
///  - STRATEGIES (CSV of strategy addresses)
contract GrantStrategyRoles is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        address payable vaultAddr = payable(vm.envAddress("TARGET_VAULT"));
        string memory strategiesCsv = vm.envString("STRATEGIES");
        address[] memory strategies = _parseAddresses(strategiesCsv);

        require(vaultAddr != address(0), "vault=0");
        require(strategies.length > 0, "no strategies");

        AjeyVault vault = AjeyVault(vaultAddr);
        for (uint256 i = 0; i < strategies.length; i++) {
            vault.addStrategy(strategies[i]);
            console2.log("Granted STRATEGY_ROLE to", strategies[i]);
        }

        vm.stopBroadcast();
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


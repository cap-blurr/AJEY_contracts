// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Import Octant PaymentSplitter implementation
import {PaymentSplitter} from "@octant-core/core/PaymentSplitter.sol";

/// @title DeployPaymentSplitter
/// @notice Deploys an Octant PaymentSplitter and initializes it once with payees and shares
/// @dev Env:
///  - PRIVATE_KEY: broadcaster key (optional)
///  - PAYEES: comma-separated addresses (e.g., 0xabc,...)
///  - SHARES: comma-separated uint256s (same length as PAYEES)
contract DeployPaymentSplitter is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        // Read array inputs from env
        string memory payeesCsv = vm.envString("PAYEES");
        string memory sharesCsv = vm.envString("SHARES");
        address[] memory payees = _parseAddresses(payeesCsv);
        uint256[] memory shares = _parseUints(sharesCsv);
        require(payees.length == shares.length && payees.length > 0, "bad inputs");

        PaymentSplitter ps = new PaymentSplitter();
        ps.initialize(payees, shares);

        console2.log("PaymentSplitter", address(ps));
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

    function _parseUints(string memory csv) internal pure returns (uint256[] memory) {
        string[] memory parts = _split(csv, ",");
        uint256[] memory nums = new uint256[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            nums[i] = vm.parseUint(parts[i]);
        }
        return nums;
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


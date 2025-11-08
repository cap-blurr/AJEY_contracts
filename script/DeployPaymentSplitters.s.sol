// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PaymentSplitter} from "@octant-core/core/PaymentSplitter.sol";

/// @title DeployPaymentSplitters
/// @notice Deploys and initializes three Octant PaymentSplitter instances (Balanced, MaxHumanitarian, MaxCrypto)
/// @dev Edit the payees/shares arrays below before running: forge script -vvvv script/DeployPaymentSplitters.s.sol --broadcast
contract DeployPaymentSplitters is Script {
    function run() external {
        vm.startBroadcast();

        // ------------------------------
        // Balanced profile
        // ------------------------------
        address[] memory balancedPayees = new address[](3);
        uint256[] memory balancedShares = new uint256[](3);
        // TODO: replace with real addresses
        balancedPayees[0] = address(0x1111111111111111111111111111111111111111);
        balancedPayees[1] = address(0x2222222222222222222222222222222222222222);
        balancedPayees[2] = address(0x3333333333333333333333333333333333333333);
        // Shares are unitless; proportions determined by totalShares
        balancedShares[0] = 40;
        balancedShares[1] = 30;
        balancedShares[2] = 30;

        PaymentSplitter balanced = new PaymentSplitter();
        balanced.initialize(balancedPayees, balancedShares);
        console2.log("Balanced PaymentSplitter:", address(balanced));

        // ------------------------------
        // MaxHumanitarian profile
        // ------------------------------
        address[] memory humPayees = new address[](3);
        uint256[] memory humShares = new uint256[](3);
        // TODO: replace with real addresses
        humPayees[0] = address(0x1111111111111111111111111111111111111111);
        humPayees[1] = address(0x2222222222222222222222222222222222222222);
        humPayees[2] = address(0x3333333333333333333333333333333333333333);
        humShares[0] = 70;
        humShares[1] = 20;
        humShares[2] = 10;

        PaymentSplitter maxHumanitarian = new PaymentSplitter();
        maxHumanitarian.initialize(humPayees, humShares);
        console2.log("MaxHumanitarian PaymentSplitter:", address(maxHumanitarian));

        // ------------------------------
        // MaxCrypto profile
        // ------------------------------
        address[] memory cryptoPayees = new address[](3);
        uint256[] memory cryptoShares = new uint256[](3);
        // TODO: replace with real addresses
        cryptoPayees[0] = address(0x3333333333333333333333333333333333333333);
        cryptoPayees[1] = address(0x1111111111111111111111111111111111111111);
        cryptoPayees[2] = address(0x2222222222222222222222222222222222222222);
        cryptoShares[0] = 70;
        cryptoShares[1] = 20;
        cryptoShares[2] = 10;

        PaymentSplitter maxCrypto = new PaymentSplitter();
        maxCrypto.initialize(cryptoPayees, cryptoShares);
        console2.log("MaxCrypto PaymentSplitter:", address(maxCrypto));

        vm.stopBroadcast();
    }
}


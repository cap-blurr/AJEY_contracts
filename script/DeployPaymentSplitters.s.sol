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
        // Balanced profile (Crypto 40%, Humanitarian 30%, Hygiene 30%)
        // ------------------------------
        address[] memory balancedPayees = new address[](3);
        uint256[] memory balancedShares = new uint256[](3);
        // Crypto public goods - Web3Afrika (ref: https://www.web3afrika.com/about)
        balancedPayees[0] = address(0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766);
        // Humanitarian - SaveTheChildren UK
        balancedPayees[1] = address(0x82657beC713AbA72A68D3cD903BE5930CC45dec3);
        // Hygiene - The Water Project (WASH Kenya)
        balancedPayees[2] = address(0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd);
        // Shares are unitless; proportions determined by totalShares
        balancedShares[0] = 40;
        balancedShares[1] = 30;
        balancedShares[2] = 30;

        PaymentSplitter balanced = new PaymentSplitter();
        balanced.initialize(balancedPayees, balancedShares);
        console2.log("Balanced PaymentSplitter:", address(balanced));

        // ------------------------------
        // Humanitarian Maxi (Humanitarian 40%, Hygiene 40%, Crypto 20%)
        // ------------------------------
        address[] memory humPayees = new address[](3);
        uint256[] memory humShares = new uint256[](3);
        // Humanitarian - SaveTheChildren UK
        humPayees[0] = address(0x82657beC713AbA72A68D3cD903BE5930CC45dec3);
        // Hygiene - The Water Project (WASH Kenya)
        humPayees[1] = address(0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd);
        // Crypto public goods - Web3Afrika
        humPayees[2] = address(0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766);
        humShares[0] = 40;
        humShares[1] = 40;
        humShares[2] = 20;

        PaymentSplitter maxHumanitarian = new PaymentSplitter();
        maxHumanitarian.initialize(humPayees, humShares);
        console2.log("MaxHumanitarian PaymentSplitter:", address(maxHumanitarian));

        // ------------------------------
        // Crypto Maxi (Crypto 60%, Humanitarian 20%, Hygiene 20%)
        // ------------------------------
        address[] memory cryptoPayees = new address[](3);
        uint256[] memory cryptoShares = new uint256[](3);
        // Crypto public goods - Web3Afrika
        cryptoPayees[0] = address(0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766);
        // Humanitarian - SaveTheChildren UK
        cryptoPayees[1] = address(0x82657beC713AbA72A68D3cD903BE5930CC45dec3);
        // Hygiene - The Water Project (WASH Kenya)
        cryptoPayees[2] = address(0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd);
        cryptoShares[0] = 60;
        cryptoShares[1] = 20;
        cryptoShares[2] = 20;

        PaymentSplitter maxCrypto = new PaymentSplitter();
        maxCrypto.initialize(cryptoPayees, cryptoShares);
        console2.log("MaxCrypto PaymentSplitter:", address(maxCrypto));

        vm.stopBroadcast();
    }
}


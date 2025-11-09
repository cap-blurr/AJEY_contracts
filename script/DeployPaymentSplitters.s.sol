// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {PaymentSplitterFactory} from "@octant-core/factories/PaymentSplitterFactory.sol";

contract DeployPaymentSplitters is Script {
    function run() external {
        vm.startBroadcast();

        PaymentSplitterFactory factory = new PaymentSplitterFactory();

        // Balanced (40/30/30)
        address[] memory balancedPayees = new address[](3);
        uint256[] memory balancedShares = new uint256[](3);
        string[] memory balancedNames = new string[](3);
        balancedPayees[0] = 0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766; // Web3Afrika
        balancedPayees[1] = 0x82657beC713AbA72A68D3cD903BE5930CC45dec3; // SaveTheChildren UK
        balancedPayees[2] = 0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd; // TheWaterProject
        balancedShares[0] = 40;
        balancedShares[1] = 30;
        balancedShares[2] = 30;
        balancedNames[0] = "Web3Afrika";
        balancedNames[1] = "SaveTheChildren";
        balancedNames[2] = "TheWaterProject";
        address balanced = factory.createPaymentSplitter(balancedPayees, balancedNames, balancedShares);
        console2.log("Balanced PaymentSplitter:", balanced);

        // Humanitarian Maxi (40/40/20)
        address[] memory humPayees = new address[](3);
        uint256[] memory humShares = new uint256[](3);
        string[] memory humNames = new string[](3);
        humPayees[0] = 0x82657beC713AbA72A68D3cD903BE5930CC45dec3; // SaveTheChildren
        humPayees[1] = 0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd; // TheWaterProject
        humPayees[2] = 0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766; // Web3Afrika
        humShares[0] = 40;
        humShares[1] = 40;
        humShares[2] = 20;
        humNames[0] = "SaveTheChildren";
        humNames[1] = "TheWaterProject";
        humNames[2] = "Web3Afrika";
        address maxHumanitarian = factory.createPaymentSplitter(humPayees, humNames, humShares);
        console2.log("MaxHumanitarian PaymentSplitter:", maxHumanitarian);

        // Crypto Maxi (60/20/20)
        address[] memory cryptoPayees = new address[](3);
        uint256[] memory cryptoShares = new uint256[](3);
        string[] memory cryptoNames = new string[](3);
        cryptoPayees[0] = 0x4BaF3334dF86FB791A6DF6Cf4210C685ab6A1766; // Web3Afrika
        cryptoPayees[1] = 0x82657beC713AbA72A68D3cD903BE5930CC45dec3; // SaveTheChildren
        cryptoPayees[2] = 0xA0B0Bf2D837E87d2f4338bFa579bFACd1133cFBd; // TheWaterProject
        cryptoShares[0] = 60;
        cryptoShares[1] = 20;
        cryptoShares[2] = 20;
        cryptoNames[0] = "Web3Afrika";
        cryptoNames[1] = "SaveTheChildren";
        cryptoNames[2] = "TheWaterProject";
        address maxCrypto = factory.createPaymentSplitter(cryptoPayees, cryptoNames, cryptoShares);
        console2.log("MaxCrypto PaymentSplitter:", maxCrypto);

        vm.stopBroadcast();
    }
}

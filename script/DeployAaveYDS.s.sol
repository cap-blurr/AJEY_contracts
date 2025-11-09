// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {AaveYieldDonatingStrategy} from "../src/octant/AaveYieldDonatingStrategy.sol";

/// @title DeployAaveYDS
/// @notice Deploys an AaveYieldDonatingStrategy wired to a specific AjeyVault and donation address (PaymentSplitter)
/// @dev Env:
///  - PRIVATE_KEY (optional)
///  - ASSET
///  - NAME
///  - MANAGEMENT
///  - KEEPER
///  - EMERGENCY_ADMIN
///  - DONATION_ADDRESS (e.g., PaymentSplitter for selected profile)
///  - ENABLE_BURNING (bool; e.g., false)
///  - TOKENIZED_STRATEGY_IMPL (YieldDonatingTokenizedStrategy implementation address from octant-v2-core)
///  - VAULT (AjeyVault address for same ASSET)
contract DeployAaveYDS is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        address asset = vm.envAddress("ASSET");
        string memory name = vm.envString("NAME");
        address management = vm.envAddress("MANAGEMENT");
        address keeper = vm.envAddress("KEEPER");
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        bool enableBurning = vm.envOr("ENABLE_BURNING", false);
        address tokenizedStrategyImpl = vm.envAddress("TOKENIZED_STRATEGY_IMPL");
        address payable vault = payable(vm.envAddress("VAULT"));

        require(asset != address(0), "asset=0");
        require(bytes(name).length > 0, "name empty");
        require(management != address(0), "management=0");
        require(keeper != address(0), "keeper=0");
        require(emergencyAdmin != address(0), "emergencyAdmin=0");
        require(donationAddress != address(0), "donation=0");
        require(tokenizedStrategyImpl != address(0), "impl=0");
        require(vault != address(0), "vault=0");

        AaveYieldDonatingStrategy strat = new AaveYieldDonatingStrategy(
            asset,
            name,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            enableBurning,
            tokenizedStrategyImpl,
            vault
        );

        console2.log("AaveYieldDonatingStrategy", address(strat));
        vm.stopBroadcast();
    }
}


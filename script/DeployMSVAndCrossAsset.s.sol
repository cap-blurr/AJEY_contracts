// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMultistrategyVaultFactory} from "../src/interfaces/octant/IMultistrategyVaultFactory.sol";
import {IMultistrategyVault} from "../src/interfaces/octant/IMultistrategyVault.sol";
import {CrossAssetAaveStrategy} from "../src/octant/CrossAssetAaveStrategy.sol";
import {AjeyVault} from "../src/core/AjeyVault.sol";

/// @title DeployMSVAndCrossAsset
/// @notice Script to deploy an MSV (via factory), a CrossAsset strategy, and wire roles/allocations
/// @dev Uses env vars:
///  - MSV_FACTORY: address of Octant MultistrategyVaultFactory
///  - BASE_ASSET: ERC20 base asset for MSV (e.g., WETH)
///  - ROLE_MANAGER: address with MSV role manager privileges
///  - PROFIT_UNLOCK: uint256 profit max unlock time
///  - STRAT_ADMIN: management/keeper admin address for the strategy
///  - DONATION_ADDRESS: donation address (e.g., PaymentSplitter)
///  - UNISWAP_ROUTER: Uniswap V3 router
///  - AJV_TARGET: target AjeyVault for the strategy
///  - POOL_FEE: uint24 fee tier
///  - SLIPPAGE_BPS: uint256 slippage bps
///  - START_DEBT: uint256 initial target debt
contract DeployMSVAndCrossAsset is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        address factory = vm.envAddress("MSV_FACTORY");
        address baseAsset = vm.envAddress("BASE_ASSET");
        address roleManager = vm.envAddress("ROLE_MANAGER");
        uint256 profitUnlock = vm.envUint("PROFIT_UNLOCK");

        address stratAdmin = vm.envAddress("STRAT_ADMIN");
        address donation = vm.envAddress("DONATION_ADDRESS");
        address uni = vm.envAddress("UNISWAP_ROUTER");
        address payable ajvTarget = payable(vm.envAddress("AJV_TARGET"));
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
        uint256 slippage = vm.envUint("SLIPPAGE_BPS");
        uint256 startDebt = vm.envUint("START_DEBT");

        require(factory != address(0), "factory=0");
        require(baseAsset != address(0), "asset=0");
        require(roleManager != address(0), "roleMgr=0");
        require(stratAdmin != address(0), "stratAdmin=0");
        require(donation != address(0), "donation=0");
        require(uni != address(0), "uni=0");
        require(ajvTarget != address(0), "ajv=0");

        // 1) Deploy MSV via factory
        address msv = IMultistrategyVaultFactory(factory)
            .deployNewVault(baseAsset, "Ajey MSV", "ajMSV", roleManager, profitUnlock);
        console2.log("MSV", msv);

        // 2) Deploy CrossAssetAaveStrategy for this MSV base asset
        CrossAssetAaveStrategy strat =
            new CrossAssetAaveStrategy(baseAsset, donation, "Ajey CrossAsset Strategy", "ajCAS", uni, stratAdmin);
        console2.log("CrossAsset Strategy", address(strat));

        // 3) Configure target AjeyVault + swap params
        strat.setTargetMarket(AjeyVault(ajvTarget), poolFee, slippage);
        // NOTE: keeper should set a fresh price via strat.setPrice(...) after deploy

        // 4) Register strategy in MSV and set caps
        IMultistrategyVault(msv).addStrategy(address(strat), true);
        IMultistrategyVault(msv).updateMaxDebtForStrategy(address(strat), type(uint256).max);

        // 5) Seed initial allocation (optional)
        if (startDebt > 0) {
            IMultistrategyVault(msv).updateDebt(address(strat), startDebt, 0);
        }

        vm.stopBroadcast();
    }
}


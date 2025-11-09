// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {AaveYieldDonatingStrategy} from "../src/octant/AaveYieldDonatingStrategy.sol";
import {AjeyVault} from "../src/core/AjeyVault.sol";
import {AgentOrchestrator} from "../src/octant/AgentOrchestrator.sol";

// Minimal interface to call TokenizedStrategy admin functions via the proxy (strategy)
interface ITokenizedStrategyAdmin {
    function setKeeper(address _keeper) external;
    function management() external view returns (address);
}

/// @title DeployAaveYDS
/// @notice Deploys an AaveYieldDonatingStrategy wired to a specific AjeyVault and donation address (PaymentSplitter)
/// @dev Env:
///  - PRIVATE_KEY (optional)
///  - SINGLE DEPLOY MODE:
///     - ASSET
///     - NAME
///     - MANAGEMENT
///     - KEEPER
///     - EMERGENCY_ADMIN
///     - DONATION_ADDRESS (e.g., PaymentSplitter for selected profile)
///     - ENABLE_BURNING (bool; e.g., false)
///     - TOKENIZED_STRATEGY_IMPL (YieldDonatingTokenizedStrategy implementation address from octant-v2-core)
///     - VAULT (AjeyVault address for same ASSET)
///  - MULTI DEPLOY MODE (deploy all 12: 4 assets × 3 profiles):
///     - ASSETS (CSV of asset addresses)
///     - VAULTS (CSV of AjeyVault addresses; aligned with ASSETS)
///     - MANAGEMENT, KEEPER, EMERGENCY_ADMIN
///     - ENABLE_BURNING (bool; e.g., false)
///     - TOKENIZED_STRATEGY_IMPL
///     - DONATION_BALANCED (PaymentSplitter for Balanced)
///     - DONATION_HUMANITARIAN (PaymentSplitter for Humanitarian Maxi)
///     - DONATION_CRYPTO (PaymentSplitter for Crypto Maxi)
///     - GRANT_STRATEGY_ROLE (bool; if true and broadcaster is vault admin, grant STRATEGY_ROLE on each vault)
contract DeployAaveYDS is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        // MULTI MODE if ASSETS present; otherwise fall back to single deploy
        if (_hasEnv("ASSETS")) {
            _deployMulti();
        } else {
            _deploySingle();
        }
    }

    function _deploySingle() internal {
        address broadcaster = tx.origin;

        address asset = vm.envAddress("ASSET");
        string memory name = vm.envString("NAME");
        address management = vm.envAddress("MANAGEMENT");
        address keeper = vm.envAddress("KEEPER");
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        bool enableBurning = vm.envOr("ENABLE_BURNING", false);
        address tokenizedStrategyImpl = vm.envAddress("TOKENIZED_STRATEGY_IMPL");
        address payable vaultAddr = payable(vm.envAddress("VAULT"));
        bool grantRole = vm.envOr("GRANT_STRATEGY_ROLE", false);
        // Optional: orchestrator and mapping/keeper configuration
        address orchestrator = vm.envOr("ORCHESTRATOR", address(0));
        bool mapInOrchestrator = vm.envOr("MAP_IN_ORCHESTRATOR", false);
        bool setKeeperToOrchestrator = vm.envOr("SET_KEEPER", false);

        _requireCommon(management, keeper, emergencyAdmin, donationAddress, tokenizedStrategyImpl, vaultAddr);
        require(vaultAddr.code.length > 0, "vault not a contract");
        require(asset != address(0), "asset=0");
        require(bytes(name).length > 0, "name empty");
        // Verify vault underlying matches provided asset
        address vaultAsset = AjeyVault(vaultAddr).asset();
        require(vaultAsset == asset, "vault asset mismatch");

        AaveYieldDonatingStrategy strat = new AaveYieldDonatingStrategy(
            asset,
            name,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            enableBurning,
            tokenizedStrategyImpl,
            vaultAddr
        );
        console2.log("Strategy deployed");
        console2.log("address", address(strat));
        console2.log("asset", asset);
        console2.log(name);

        if (grantRole) {
            AjeyVault vault = AjeyVault(vaultAddr);
            // Grant STRATEGY_ROLE only if broadcaster is vault admin
            if (vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), broadcaster)) {
                vault.addStrategy(address(strat));
                console2.log("Granted STRATEGY_ROLE to", address(strat));
            } else {
                console2.log("WARN: Skipping addStrategy - broadcaster is not vault admin");
            }
        }

        // Optionally set keeper to orchestrator (requires broadcaster == management)
        if (setKeeperToOrchestrator && orchestrator != address(0)) {
            address currentMgmt = ITokenizedStrategyAdmin(address(strat)).management();
            if (currentMgmt == broadcaster) {
                ITokenizedStrategyAdmin(address(strat)).setKeeper(orchestrator);
                console2.log("Keeper set to orchestrator for", address(strat));
            } else {
                console2.log("WARN: Skipping setKeeper - broadcaster != strategy management");
            }
        }

        // Optionally map into orchestrator (requires broadcaster == orchestrator admin)
        if (mapInOrchestrator && orchestrator != address(0)) {
            AgentOrchestrator orch = AgentOrchestrator(orchestrator);
            // We cannot introspect admin easily without role check; call will revert if not admin
            try orch.setStrategy(AgentOrchestrator.Profile.Balanced, asset, address(strat)) {
                console2.log("Mapped single strategy (Balanced) into orchestrator");
            } catch {
                console2.log("NOTE: setStrategy not executed in single mode; use multi mode or run DeployOrchestrator");
            }
        }

        vm.stopBroadcast();
    }

    function _deployMulti() internal {
        address broadcaster = tx.origin;

        address[] memory assets = _parseAddresses(vm.envString("ASSETS"));
        address[] memory vaults = _parseAddresses(vm.envString("VAULTS"));
        require(assets.length == vaults.length && assets.length > 0, "bad ASSETS/VAULTS");

        address management = vm.envAddress("MANAGEMENT");
        address keeper = vm.envAddress("KEEPER");
        address emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        bool enableBurning = vm.envOr("ENABLE_BURNING", false);
        address tokenizedStrategyImpl = vm.envAddress("TOKENIZED_STRATEGY_IMPL");
        address donationBalanced = vm.envAddress("DONATION_BALANCED");
        address donationHumanitarian = vm.envAddress("DONATION_HUMANITARIAN");
        address donationCrypto = vm.envAddress("DONATION_CRYPTO");
        bool grantRole = vm.envOr("GRANT_STRATEGY_ROLE", false);
        address orchestrator = vm.envOr("ORCHESTRATOR", address(0));
        bool mapInOrchestrator = vm.envOr("MAP_IN_ORCHESTRATOR", false);
        bool setKeeperToOrchestrator = vm.envOr("SET_KEEPER", false);

        _requireCommon(management, keeper, emergencyAdmin, address(0x1), tokenizedStrategyImpl, payable(vaults[0]));
        require(
            donationBalanced != address(0) && donationHumanitarian != address(0) && donationCrypto != address(0),
            "donation addr=0"
        );

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            address payable vaultAddr = payable(vaults[i]);
            require(asset != address(0) && vaultAddr != address(0), "asset/vault=0");
            require(vaultAddr.code.length > 0, "vault not a contract");
            // Verify vault underlying matches ASSETS[i]
            address vaultAsset = AjeyVault(vaultAddr).asset();
            require(vaultAsset == asset, "vault asset mismatch");

            // Balanced
            AaveYieldDonatingStrategy sBal = new AaveYieldDonatingStrategy(
                asset,
                _mkName("Ajey Strategy (Balanced)", i),
                management,
                keeper,
                emergencyAdmin,
                donationBalanced,
                enableBurning,
                tokenizedStrategyImpl,
                vaultAddr
            );
            console2.log("Strategy Balanced deployed");
            console2.log("address", address(sBal));
            console2.log("asset", asset);
            console2.log("vault", vaultAddr);

            // Humanitarian Maxi
            AaveYieldDonatingStrategy sHum = new AaveYieldDonatingStrategy(
                asset,
                _mkName("Ajey Strategy (Humanitarian Maxi)", i),
                management,
                keeper,
                emergencyAdmin,
                donationHumanitarian,
                enableBurning,
                tokenizedStrategyImpl,
                vaultAddr
            );
            console2.log("Strategy Humanitarian deployed");
            console2.log("address", address(sHum));
            console2.log("asset", asset);
            console2.log("vault", vaultAddr);

            // Crypto Maxi
            AaveYieldDonatingStrategy sCry = new AaveYieldDonatingStrategy(
                asset,
                _mkName("Ajey Strategy (Crypto Maxi)", i),
                management,
                keeper,
                emergencyAdmin,
                donationCrypto,
                enableBurning,
                tokenizedStrategyImpl,
                vaultAddr
            );
            console2.log("Strategy Crypto deployed");
            console2.log("address", address(sCry));
            console2.log("asset", asset);
            console2.log("vault", vaultAddr);

            if (grantRole) {
                AjeyVault vault = AjeyVault(vaultAddr);
                if (vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), broadcaster)) {
                    vault.addStrategy(address(sBal));
                    vault.addStrategy(address(sHum));
                    vault.addStrategy(address(sCry));
                    console2.log("Granted STRATEGY_ROLE to trio for vault");
                    console2.log("vault", vaultAddr);
                } else {
                    console2.log("WARN: Skipping addStrategy trio - broadcaster is not vault admin");
                }
            }

            // Optionally set keeper to orchestrator (requires broadcaster == management)
            if (setKeeperToOrchestrator && orchestrator != address(0)) {
                // Balanced
                if (ITokenizedStrategyAdmin(address(sBal)).management() == broadcaster) {
                    ITokenizedStrategyAdmin(address(sBal)).setKeeper(orchestrator);
                    console2.log("Keeper set to orchestrator for", address(sBal));
                } else {
                    console2.log("WARN: Skipping setKeeper (Balanced) - broadcaster != management");
                }
                // Humanitarian
                if (ITokenizedStrategyAdmin(address(sHum)).management() == broadcaster) {
                    ITokenizedStrategyAdmin(address(sHum)).setKeeper(orchestrator);
                    console2.log("Keeper set to orchestrator for", address(sHum));
                } else {
                    console2.log("WARN: Skipping setKeeper (Humanitarian) - broadcaster != management");
                }
                // Crypto
                if (ITokenizedStrategyAdmin(address(sCry)).management() == broadcaster) {
                    ITokenizedStrategyAdmin(address(sCry)).setKeeper(orchestrator);
                    console2.log("Keeper set to orchestrator for", address(sCry));
                } else {
                    console2.log("WARN: Skipping setKeeper (Crypto) - broadcaster != management");
                }
            }

            // Optionally map all three strategies into orchestrator (requires orchestrator admin)
            if (mapInOrchestrator && orchestrator != address(0)) {
                AgentOrchestrator orch = AgentOrchestrator(orchestrator);
                try orch.setStrategy(AgentOrchestrator.Profile.Balanced, asset, address(sBal)) {
                    console2.log("Mapped Balanced into orchestrator");
                } catch {
                    console2.log("WARN: setStrategy (Balanced) failed - ensure broadcaster is orchestrator admin");
                }
                try orch.setStrategy(AgentOrchestrator.Profile.MaxHumanitarian, asset, address(sHum)) {
                    console2.log("Mapped Humanitarian into orchestrator");
                } catch {
                    console2.log("WARN: setStrategy (Humanitarian) failed - ensure broadcaster is orchestrator admin");
                }
                try orch.setStrategy(AgentOrchestrator.Profile.MaxCrypto, asset, address(sCry)) {
                    console2.log("Mapped Crypto into orchestrator");
                } catch {
                    console2.log("WARN: setStrategy (Crypto) failed - ensure broadcaster is orchestrator admin");
                }
            }
        }
    }

    function _mkName(string memory base, uint256 idx) internal pure returns (string memory) {
        // Simple suffix with index to make names unique if desired
        return string(abi.encodePacked(base, " #", _toString(idx)));
    }

    function _toString(uint256 v) internal pure returns (string memory str) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = v;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }

    function _requireCommon(
        address management,
        address keeper,
        address emergencyAdmin,
        address donationAddress, // can be placeholder in multi
        address tokenizedStrategyImpl,
        address payable vault
    ) internal pure {
        require(management != address(0), "management=0");
        require(keeper != address(0), "keeper=0");
        require(emergencyAdmin != address(0), "emergencyAdmin=0");
        if (donationAddress != address(0)) {
            require(donationAddress != address(0), "donation=0");
        }
        require(tokenizedStrategyImpl != address(0), "impl=0");
        require(vault != address(0), "vault=0");
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


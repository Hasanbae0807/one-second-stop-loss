// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GuardianVault} from "../src/GuardianVault.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Base Sepolia deployments (chain 84532).
///
///         Step 1 — origin contracts:
///           forge script script/DeployBaseSepolia.s.sol --broadcast \
///             --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_KEY
///         Step 3 — the vault (needs the StopLossReactive address from the
///         Lasna deployment, step 2 in DeployLasna.s.sol):
///           DEPLOY_VAULT=1 REACTIVE_ADDR=0x... forge script \
///             script/DeployBaseSepolia.s.sol --broadcast \
///             --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_KEY
contract DeployBaseSepolia is Script {
    /// @notice Reactive Network Callback Proxy on Base Sepolia.
    address internal constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        vm.startBroadcast();
        if (vm.envOr("DEPLOY_VAULT", uint256(0)) == 1) {
            GuardianVault vault = new GuardianVault(CALLBACK_PROXY, vm.envAddress("REACTIVE_ADDR"));
            console.log("guardian_vault:", address(vault));
        } else {
            MockERC20 token = new MockERC20("Mock Token", "MOCK");
            PriceOracle oracle = new PriceOracle();
            console.log("mock_token:", address(token));
            console.log("price_oracle:", address(oracle));
        }
        vm.stopBroadcast();
    }
}
